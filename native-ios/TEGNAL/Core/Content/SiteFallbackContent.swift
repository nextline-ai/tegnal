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
    private let lock = NSLock()
    /// The website each work in this session was read from, so its pages load there too.
    private nonisolated(unsafe) var serving: [Int64: String] = [:]
    /// The website a saved work came from, tried before the other connected websites.
    private nonisolated(unsafe) var origins: [Int64: String] = [:]

    init(primary: any ContentProviding = MangaContentSource.shared,
         sourceFor: @escaping SourceFor = { SiteContent.for($0) },
         sites: @escaping @Sendable () -> (active: String, all: [String]) = { (ComicSites.active, ComicSites.all) },
         memory: WorkSiteMemory = .shared) {
        self.primary = primary
        self.sourceFor = sourceFor
        self.sites = sites
        self.memory = memory
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

    func gallery(_ id: Int64, preferring preferred: String?) async throws -> NativeGallery {
        let order = candidates(for: id, preferring: preferred)
        guard !order.isEmpty else { return try await primary.gallery(id) }
        var firstError: Error?
        for site in order {
            try Task.checkCancellation()
            do {
                let gallery = try await source(for: site).gallery(id)
                record(id, site: site, afterFailure: firstError != nil)
                return gallery
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                guard ContentError.allowsOtherSite(error) else { throw firstError ?? error }
                firstError = firstError ?? error
            }
        }
        throw firstError ?? ContentError.galleryNotFound
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
