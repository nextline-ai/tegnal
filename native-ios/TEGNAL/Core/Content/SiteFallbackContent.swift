import Foundation

/// Which connected websites no longer carry a work. Every connected website numbers works the same
/// way, so a work deleted on one may still open on another. The checked website is always asked
/// first, unless it has already said it no longer has the work; switching websites to use what
/// another one offers then opens works there.
final class WorkSiteMemory: @unchecked Sendable {
    static let shared: WorkSiteMemory = {
        guard !ContentPreferences.isIsolated else { return WorkSiteMemory(file: nil) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The list of where works last opened made them stay there after switching websites.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("work-sites.plist"))
        return WorkSiteMemory(file: folder.appendingPathComponent("work-missing-sites.plist"))
    }()
    private let lock = NSLock()
    private let file: URL?
    private let limit: Int
    private var missing: [Int64: Set<String>] = [:]
    private var order: [Int64] = []
    private var loaded = false
    private var saving = false

    init(file: URL?, limit: Int = 20_000) {
        self.file = file
        self.limit = limit
    }

    /// The websites that said they no longer have the work.
    func missingSites(for id: Int64) -> Set<String> { lock.withLock { loadIfNeeded(); return missing[id] ?? [] } }

    /// Works some website no longer has.
    var count: Int { lock.withLock { loadIfNeeded(); return missing.count } }

    /// Notes that [site] answered it no longer has the work.
    func markMissing(_ id: Int64, on site: String) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            guard missing[id]?.contains(site) != true else { return false }
            if missing[id] == nil { order.append(id) }
            missing[id, default: []].insert(site)
            if order.count > limit {
                let dropped = order.prefix(order.count - limit * 9 / 10)
                for id in dropped { missing[id] = nil }
                order.removeFirst(dropped.count)
            }
            return true
        }
        if changed { scheduleSave() }
    }

    /// Notes that [site] carries the work again.
    func markFound(_ id: Int64, on site: String) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            guard missing[id]?.remove(site) != nil else { return false }
            if missing[id]?.isEmpty == true {
                missing[id] = nil
                order.removeAll { $0 == id }
            }
            return true
        }
        if changed { scheduleSave() }
    }

    /// Forgets what [site] said, as when the website is removed.
    func forget(site: String) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            var changed = false
            for (id, sites) in missing where sites.contains(site) {
                changed = true
                if sites.count == 1 { missing[id] = nil } else { missing[id]?.remove(site) }
            }
            order.removeAll { missing[$0] == nil }
            return changed
        }
        if changed { scheduleSave() }
    }

    func removeAll() {
        lock.withLock { missing.removeAll(); order.removeAll(); loaded = true }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let rows = try? PropertyListDecoder().decode([[String]].self, from: data) else { return }
        for row in rows where row.count == 2 {
            guard let id = Int64(row[0]), id > 0, !row[1].isEmpty else { continue }
            if missing[id] == nil { order.append(id) }
            missing[id, default: []].insert(row[1])
        }
    }

    private func scheduleSave() {
        guard let file else { return }
        let start = lock.withLock { () -> Bool in
            guard !saving else { return false }
            saving = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            let rows = lock.withLock { () -> [[String]] in
                saving = false
                return order.flatMap { id in (missing[id] ?? []).sorted().map { [String(id), $0] } }
            }
            guard let data = try? PropertyListEncoder().encode(rows) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            AppStorage.excludeFromBackup(file)
        }
    }
}

/// Opens works from whichever connected website still carries them, so saved works never need
/// the checked website switched by hand. Lists and searches stay on the checked website.
final class SiteFallbackContent: ContentProviding, WorkExtrasProviding, @unchecked Sendable {
    typealias SourceFor = @Sendable (String) -> any ContentProviding
    static let shared = SiteFallbackContent()

    private let primary: any ContentProviding
    private let sourceFor: SourceFor
    private let sites: @Sendable () -> (active: String, all: [String])
    private let memory: WorkSiteMemory
    private let blocksBulkReading: @Sendable (String) -> Bool
    private let lock = NSLock()
    /// The website each work in this session was read from, so its pages load there too.
    private nonisolated(unsafe) var serving: [Int64: String] = [:]
    /// The website a saved work came from, tried before the other connected websites.
    private nonisolated(unsafe) var origins: [Int64: String] = [:]
    /// Works a fill read from a website that blocks bulk reading, until the fill asks.
    private nonisolated(unsafe) var blockingReads = Set<Int64>()

    init(primary: any ContentProviding = MangaContentSource.shared,
         sourceFor: @escaping SourceFor = { SiteContent.for($0) },
         sites: @escaping @Sendable () -> (active: String, all: [String]) = { (ComicSites.active, ComicSites.all) },
         memory: WorkSiteMemory = .shared,
         blocksBulkReading: @escaping @Sendable (String) -> Bool = { CoverFillGuard.blocksBulkReading($0) }) {
        self.primary = primary
        self.sourceFor = sourceFor
        self.sites = sites
        self.memory = memory
        self.blocksBulkReading = blocksBulkReading
    }

    /// Names the website a saved work came from, so it is tried right after the checked website.
    func prefer(_ site: String?, for id: Int64) {
        guard let site, !site.isEmpty else { return }
        lock.withLock {
            if origins.count > 4096 { origins.removeAll() }
            origins[id] = site
        }
    }

    /// Websites to try for a work, in order: the checked website, the one named for it, the one it
    /// was saved from, then the other connected websites. Websites that said they no longer have
    /// it go last, in case they carry it again.
    func candidates(for id: Int64, preferring preferred: String? = nil) -> [String] {
        let (active, all) = sites()
        var order: [String] = []
        func add(_ site: String?) {
            guard let site, !site.isEmpty, all.contains(site) || site == active, !order.contains(site) else { return }
            order.append(site)
        }
        add(active)
        add(preferred)
        add(lock.withLock { origins[id] })
        for site in all { add(site) }
        let missing = memory.missingSites(for: id)
        return order.filter { !missing.contains($0) } + order.filter(missing.contains)
    }

    /// The website a work was last read from in this session, when it is not the checked one.
    func servingSite(for id: Int64) -> String? {
        let site = lock.withLock { serving[id] }
        return site == sites().active ? nil : site
    }

    private func source(for site: String) -> any ContentProviding {
        site == sites().active ? primary : sourceFor(site)
    }

    func gallery(_ id: Int64) async throws -> NativeGallery { try await gallery(id, preferring: nil) }

    func preview(_ id: Int64) async throws -> NativeGallery { try await preview(id, preferring: nil) }

    /// `inBulk` reads for a background fill. Websites that block bulk reading are read last, and
    /// only for a work every other connected website says it no longer has; a work the others
    /// could not be asked about is left for later.
    func gallery(_ id: Int64, preferring preferred: String?, inBulk: Bool = false) async throws -> NativeGallery {
        try await read(id, preferring: preferred, inBulk: inBulk) { try await $0.gallery(id) }
    }

    /// A work as a card or a fill needs it, from the same websites in the same order as `gallery`.
    func preview(_ id: Int64, preferring preferred: String?, inBulk: Bool = false) async throws -> NativeGallery {
        try await read(id, preferring: preferred, inBulk: inBulk) { try await $0.preview(id) }
    }

    private func read(_ id: Int64, preferring preferred: String?, inBulk: Bool,
                      _ body: (any ContentProviding) async throws -> NativeGallery) async throws -> NativeGallery {
        let order = candidates(for: id, preferring: preferred)
        guard !order.isEmpty else { return try await body(primary) }
        let skipped = inBulk ? CoverFillGuard.skipped(among: sites().all, blocks: blocksBulkReading) : []
        let others = order.filter { !skipped.contains($0) }, last = order.filter(skipped.contains)
        var firstError: Error?
        var missingElsewhere = true
        for site in others + last {
            try Task.checkCancellation()
            let blocking = inBulk && blocksBulkReading(site)
            if skipped.contains(site) {
                // Not missing: the other websites could not be read, and this one may carry it.
                guard missingElsewhere else { throw CoverFillGuard.LeftForBlockingSite() }
            }
            if blocking { _ = lock.withLock { blockingReads.insert(id) } }
            do {
                let gallery = try await body(source(for: site))
                record(id, site: site)
                return gallery
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if ContentError.isMissingWork(error) { memory.markMissing(id, on: site) }
                guard ContentError.allowsOtherSite(error) else { throw firstError ?? error }
                // A website that stopped answering this device is not asked again in a fill.
                if blocking, ContentError.refusesDevice(error) { throw error }
                firstError = firstError ?? error
                if !ContentError.isMissingWork(error) { missingElsewhere = false }
            }
        }
        throw firstError ?? ContentError.galleryNotFound
    }

    /// Whether a fill's last read of a work went to a website that blocks bulk reading, so the
    /// next read waits longer. Asking forgets it.
    func tookBlockingRead(_ id: Int64) -> Bool {
        lock.withLock { blockingReads.remove(id) != nil }
    }

    private func record(_ id: Int64, site: String) {
        lock.withLock {
            if serving.count > 4096 { serving.removeAll() }
            serving[id] = site
        }
        // A website that carries the work again is asked in its turn from now on.
        memory.markFound(id, on: site)
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        try await source(for: imageSite(page, galleryID: galleryID)).image(page, galleryID: galleryID, thumbnail: thumbnail)
    }

    /// Pages load from the website their work was read from.
    private func imageSite(_ page: GalleryPage, galleryID: Int64) -> String {
        let (active, all) = sites()
        if let home = page.sourceSite, let host = URL(string: home)?.host?.lowercased(), host == active || all.contains(host) { return host }
        if let site = lock.withLock({ serving[galleryID] }) { return site }
        return active
    }

    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        try await primary.list(query, offset: offset, count: count)
    }

    /// Ratings and comments come from the website the work was read from.
    private func extrasSource(for id: Int64) -> (any WorkExtrasProviding)? {
        let site = lock.withLock { serving[id] } ?? sites().active
        return source(for: site) as? any WorkExtrasProviding
    }

    func extras(_ id: Int64) async throws -> WorkExtras? { try await extrasSource(for: id)?.extras(id) }
    func allComments(_ id: Int64) async throws -> [WorkComment] { try await extrasSource(for: id)?.allComments(id) ?? [] }
    func rate(_ id: Int64, halfStars: Int) async throws -> (average: Double, count: Int) {
        guard let source = extrasSource(for: id) else { throw ContentError.unsupportedFormat }
        return try await source.rate(id, halfStars: halfStars)
    }
    func voteTag(_ id: Int64, tag: String, vote: Int) async throws -> [WorkTagVote] {
        guard let source = extrasSource(for: id) else { throw ContentError.unsupportedFormat }
        return try await source.voteTag(id, tag: tag, vote: vote)
    }
    func postComment(_ id: Int64, text: String) async throws -> [WorkComment] {
        guard let source = extrasSource(for: id) else { throw ContentError.unsupportedFormat }
        return try await source.postComment(id, text: text)
    }
    func archiveOffer(_ id: Int64) async throws -> WorkArchiveOffer {
        guard let source = extrasSource(for: id) else { throw ContentError.unsupportedFormat }
        return try await source.archiveOffer(id)
    }
    func archiveDownloadURL(_ id: Int64, option: WorkArchiveOffer.Option) async throws -> URL {
        guard let source = extrasSource(for: id) else { throw ContentError.unsupportedFormat }
        return try await source.archiveDownloadURL(id, option: option)
    }

    func suggestions(for token: String) async throws -> [TagSuggestion] {
        try await primary.suggestions(for: token)
    }

    func cachedGallery(_ id: Int64) -> NativeGallery? {
        if let site = lock.withLock({ serving[id] }) ?? candidates(for: id).first, site != sites().active,
           let cached = sourceFor(site).cachedGallery(id) { return cached }
        return primary.cachedGallery(id)
    }

    func cachedPreview(_ id: Int64) -> NativeGallery? {
        if let site = lock.withLock({ serving[id] }) ?? candidates(for: id).first, site != sites().active,
           let cached = sourceFor(site).cachedPreview(id) { return cached }
        return primary.cachedPreview(id)
    }
}
