import Foundation

/// Which connected website last opened a work after the checked one could not. Every connected
/// website numbers works the same way, so a work missing on one may still open on another; once it
/// does, it opens there first from then on.
final class WorkSiteMemory: @unchecked Sendable {
    static let shared = WorkSiteMemory(file: ContentPreferences.isIsolated ? nil : WorkSiteMemory.defaultFile)
    private static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("work-sites.plist")
    }
    private let lock = NSLock()
    private let file: URL?
    private let limit: Int
    private var sites: [Int64: String] = [:]
    private var order: [Int64] = []
    private var loaded = false
    private var saving = false

    init(file: URL?, limit: Int = 20_000) {
        self.file = file
        self.limit = limit
    }

    func site(for id: Int64) -> String? { lock.withLock { loadIfNeeded(); return sites[id] } }

    var count: Int { lock.withLock { loadIfNeeded(); return sites.count } }

    /// Remembers the website that opened a work, or forgets it when [site] is nil.
    func remember(_ id: Int64, site: String?) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            guard sites[id] != site else { return false }
            if let site {
                if sites[id] == nil { order.append(id) }
                sites[id] = site
            } else {
                sites[id] = nil
                order.removeAll { $0 == id }
            }
            if order.count > limit {
                let dropped = order.prefix(order.count - limit * 9 / 10)
                for id in dropped { sites[id] = nil }
                order.removeFirst(dropped.count)
            }
            return true
        }
        if changed { scheduleSave() }
    }

    /// Forgets every work remembered on [site], as when the website is removed.
    func forget(site: String) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            let before = sites.count
            sites = sites.filter { $0.value != site }
            order.removeAll { sites[$0] == nil }
            return sites.count != before
        }
        if changed { scheduleSave() }
    }

    func removeAll() {
        lock.withLock { sites.removeAll(); order.removeAll(); loaded = true }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let rows = try? PropertyListDecoder().decode([[String]].self, from: data) else { return }
        for row in rows where row.count == 2 {
            guard let id = Int64(row[0]), id > 0, !row[1].isEmpty, sites[id] == nil else { continue }
            sites[id] = row[1]
            order.append(id)
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
                return order.compactMap { id in sites[id].map { [String(id), $0] } }
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

    /// Websites to try for a work, in order: where it last opened after the checked website could
    /// not, the checked website, then the other connected websites.
    func candidates(for id: Int64, preferring preferred: String? = nil) -> [String] {
        let (active, all) = sites()
        var order: [String] = []
        func add(_ site: String?) {
            guard let site, !site.isEmpty, all.contains(site) || site == active, !order.contains(site) else { return }
            order.append(site)
        }
        add(memory.site(for: id))
        add(preferred)
        add(active)
        add(lock.withLock { origins[id] })
        for site in all { add(site) }
        return order
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
                record(id, site: site, afterFailure: firstError != nil)
                return gallery
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
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

    private func record(_ id: Int64, site: String, afterFailure: Bool) {
        let active = sites().active
        lock.withLock {
            if serving.count > 4096 { serving.removeAll() }
            serving[id] = site
        }
        let remembered = memory.site(for: id)
        if site == active {
            // The checked website carries it again; it no longer needs a detour.
            if remembered != nil { memory.remember(id, site: nil) }
        } else if afterFailure, remembered != site {
            memory.remember(id, site: site)
        }
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

    /// Ratings, comments and torrents come from the website the work was read from.
    private func extrasSource(for id: Int64) -> (any WorkExtrasProviding)? {
        let site = lock.withLock { serving[id] } ?? sites().active
        return source(for: site) as? any WorkExtrasProviding
    }

    func extras(_ id: Int64) async throws -> WorkExtras? { try await extrasSource(for: id)?.extras(id) }
    func allComments(_ id: Int64) async throws -> [WorkComment] { try await extrasSource(for: id)?.allComments(id) ?? [] }
    func torrents(_ id: Int64) async throws -> [WorkTorrent] { try await extrasSource(for: id)?.torrents(id) ?? [] }
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
        if let site = lock.withLock({ serving[id] }) ?? memory.site(for: id), site != sites().active,
           let cached = sourceFor(site).cachedGallery(id) { return cached }
        return primary.cachedGallery(id)
    }

    func cachedPreview(_ id: Int64) -> NativeGallery? {
        if let site = lock.withLock({ serving[id] }) ?? memory.site(for: id), site != sites().active,
           let cached = sourceFor(site).cachedPreview(id) { return cached }
        return primary.cachedPreview(id)
    }
}
