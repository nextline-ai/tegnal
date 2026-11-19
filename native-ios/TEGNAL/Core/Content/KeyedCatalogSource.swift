import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Page loads on one website, paced like a person browsing quickly: a few at once, then one at a
/// steady interval. Bursts of page loads are what get an address banned on keyed catalogs; images
/// and the details endpoint are not paced here.
actor PagePacer {
    static let shared = ContentPreferences.isIsolated ? PagePacer(burst: 1_000, interval: .milliseconds(1)) : PagePacer()
    private let burst: Double
    private let interval: Duration
    private var buckets: [String: (tokens: Double, updated: ContinuousClock.Instant)] = [:]

    init(burst: Int = 5, interval: Duration = .milliseconds(800)) {
        self.burst = Double(max(1, burst))
        self.interval = interval
    }

    func wait(host: String) async throws {
        while true {
            let now = ContinuousClock.now
            var bucket = buckets[host] ?? (burst, now)
            bucket.tokens = min(burst, bucket.tokens + (now - bucket.updated) / interval)
            bucket.updated = now
            if bucket.tokens >= 1 {
                bucket.tokens -= 1
                buckets[host] = bucket
                return
            }
            buckets[host] = bucket
            try await Task.sleep(for: interval * (1 - bucket.tokens))
        }
    }
}

/// A numeric catalog whose works open with their number plus a short key: an
/// HTML listing with a cursor, page links per work, and a JSON endpoint for
/// details. Only page shapes and response fields identify this protocol.
actor KeyedCatalogSource {
    struct Link: Equatable, Sendable {
        let id: Int64
        let key: String
    }
    /// A page preview: its own image, or one tile of a sheet of previews.
    struct Thumb: Equatable, Sendable {
        let url: URL
        let crop: CGRect?
    }
    struct Entry: Equatable, Sendable {
        let key: String
        let name: String
        let thumb: Thumb?
    }
    struct ShownImage: Equatable, Sendable {
        let url: URL
        let reload: String?
        /// The page's original file, which a signed-in account may load instead.
        var original: URL? = nil
    }
    private struct Detail {
        var perPage: Int
        var entries: [Int: Entry]
        var extras: WorkExtras? = nil
        var apiKey: KeyedWorkPage.APIKey? = nil
        let created = Date()
    }
    private struct Lane {
        let categories: Set<String>
        let language: String?
        var next: String?
        var more = true
        var pending: [Int64] = []
    }
    private struct Feed {
        var lanes: [Lane]
        var ids: [Int64] = []
        let created = Date()
    }
    private final class Preview {
        let gallery: NativeGallery
        init(_ gallery: NativeGallery) { self.gallery = gallery }
    }

    private let transport: ContentTransport
    private let keys: GalleryKeys
    private let pacer: PagePacer
    private var site = ""
    private var feeds: [GalleryQuery: Feed] = [:]
    private var details: [Int64: Detail] = [:]
    private var popular: ([Int64], Date)?
    private struct Toplist { var ids: [Int64] = []; var page = 0; var more = true; let created = Date() }
    private var toplists: [Int: Toplist] = [:]
    private nonisolated(unsafe) let previews = NSCache<NSString, Preview>()
    private nonisolated(unsafe) let sheets = NSCache<NSURL, NSData>()

    static let allCategories: Set<String> = ["doujinshi", "manga", "artistcg", "gamecg", "western", "non-h", "imageset", "cosplay", "photo", "misc"]
    private static let visualCategories: Set<String> = ["artistcg", "gamecg", "imageset"]
    private static let categoryBits = ["misc": 1, "doujinshi": 2, "manga": 4, "artistcg": 8, "gamecg": 16, "imageset": 32,
                                       "cosplay": 64, "photo": 128, "non-h": 256, "western": 512]
    private static let searchLimit = 200

    init(transport: ContentTransport, keys: GalleryKeys = .shared, pacer: PagePacer = .shared) {
        self.transport = transport
        self.keys = keys
        self.pacer = pacer
        previews.countLimit = 512
        sheets.countLimit = 24
        sheets.totalCostLimit = 24 * 1024 * 1024
    }

    nonisolated func cachedPreview(_ id: Int64) -> NativeGallery? {
        previews.object(forKey: "\(MangaUrls.home)#\(id)" as NSString)?.gallery
    }

    private func prepare(_ requestedSite: String) throws {
        guard requestedSite == MangaUrls.home else { throw CancellationError() }
        if site != requestedSite {
            site = requestedSite
            feeds.removeAll(); details.removeAll(); popular = nil; toplists.removeAll()
            previews.removeAllObjects(); sheets.removeAllObjects()
        }
    }

    // MARK: Listing

    func list(_ query: GalleryQuery, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        try prepare(site)
        let selected = try Self.selectedCategories(query)
        if let toplist = query.sort.toplist { return try await toplistList(query, selected: selected, toplist: toplist, offset: offset, count: count, site: site) }
        if query.sort != .latest && query.sort != .watched { return try await popularList(query, selected: selected, offset: offset, count: count, site: site) }
        var feed = feeds[query] ?? Feed(lanes: Self.lanes(query, selected: selected))
        if Date().timeIntervalSince(feed.created) > 300 { feed = Feed(lanes: Self.lanes(query, selected: selected)) }
        let exclusions = DocumentCatalogSource.exclusions(query)
        let target = offset + count
        var seen = Set(feed.ids), requests = 0
        while feed.ids.count < target {
            for index in feed.lanes.indices where feed.lanes[index].pending.isEmpty && feed.lanes[index].more {
                guard requests < 8 else { break }
                try await fill(&feed.lanes[index], query: query, exclusions: exclusions, site: site)
                requests += 1
            }
            // Every lane needs a head or must be exhausted before the newest one is taken.
            if feed.lanes.contains(where: { $0.pending.isEmpty && $0.more }) {
                if requests >= 8 { break }
                continue
            }
            let available = feed.lanes.indices.filter { !feed.lanes[$0].pending.isEmpty }
            guard let newest = available.max(by: { feed.lanes[$0].pending[0] < feed.lanes[$1].pending[0] }) else { break }
            let next = feed.lanes[newest].pending.removeFirst()
            if seen.insert(next).inserted { feed.ids.append(next) }
        }
        try prepare(site)
        let more = feed.lanes.contains { $0.more || !$0.pending.isEmpty }
        // Heavy exclusions show what was found rather than an error.
        if feed.ids.count <= offset && more && requests >= 8 { throw ContentError.invalidResponse }
        if feeds.count >= 16, feeds[query] == nil, let oldest = feeds.min(by: { $0.value.created < $1.value.created })?.key { feeds[oldest] = nil }
        feeds[query] = feed
        return GalleryBatch(ids: Array(feed.ids.dropFirst(offset).prefix(count)), hasMore: more || feed.ids.count > target)
    }

    /// A language with visual collections in every language reads two lanes, merged newest first.
    private static func lanes(_ query: GalleryQuery, selected: Set<String>) -> [Lane] {
        let language = query.language == "all" ? nil : query.language
        guard language != nil, query.allowsLanguageExceptions else { return [Lane(categories: selected, language: language)] }
        return [Lane(categories: selected.subtracting(visualCategories), language: language),
                Lane(categories: selected.intersection(visualCategories), language: nil)].filter { !$0.categories.isEmpty }
    }

    private func fill(_ lane: inout Lane, query: GalleryQuery, exclusions: String, site: String) async throws {
        // Watched tags list the same way as the front page, from their own page.
        let base = query.sort == .watched ? site + "watched" : site
        let url = try Self.searchURL(query, site: base, categories: lane.categories, language: lane.language, next: lane.next)
        let text = try await page(url, site: site)
        MangaUrls.noteKeyedNavigation(text, site: site)
        let links = Self.links(in: text)
        keys.remember(links.map { ($0.id, $0.key) })
        let next = Self.nextCursor(in: text)
        lane.more = !links.isEmpty && next != nil && next != lane.next
        lane.next = next
        let found = await previews(for: links, site: site)
        for link in links {
            if let preview = found[link.id] {
                if !preview.type.isEmpty && !lane.categories.contains(preview.type) { continue }
                if !exclusions.isEmpty && preview.isExcluded(by: exclusions) { continue }
            }
            lane.pending.append(link.id)
        }
    }

    /// The site ranks only what is popular right now, so the search narrows it here.
    private func popularList(_ query: GalleryQuery, selected: Set<String>, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        let ids: [Int64]
        if let (cached, date) = popular, Date().timeIntervalSince(date) < 300 { ids = cached }
        else {
            guard let url = URL(string: site + "popular") else { throw ContentError.invalidQuery }
            let links = Self.links(in: try await page(url, site: site))
            keys.remember(links.map { ($0.id, $0.key) })
            _ = await previews(for: links, site: site)
            ids = links.map(\.id)
            popular = (ids, Date())
        }
        let matching = ids.filter { self.matches($0, query: query, selected: selected) }
        return GalleryBatch(ids: Array(matching.dropFirst(offset).prefix(count)), hasMore: matching.count > offset + count)
    }

    /// Rankings the site lists itself narrow to the search here, from each work's details.
    private func matches(_ id: Int64, query: GalleryQuery, selected: Set<String>) -> Bool {
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("type:") && !$0.hasPrefix("-type:") }
        let wanted = terms.filter { !$0.hasPrefix("-") } + (query.artist.map { ["artist:" + $0.replacingOccurrences(of: " ", with: "_")] } ?? [])
        let excluded = terms.filter { $0.hasPrefix("-") }.joined(separator: " ")
        guard let work = cachedPreview(id) else { return true }
        if !work.type.isEmpty && !selected.contains(work.type) { return false }
        if query.language != "all" && work.language != query.language
            && !(query.allowsLanguageExceptions && Self.visualCategories.contains(work.type)) { return false }
        if !excluded.isEmpty && work.isExcluded(by: excluded) { return false }
        return wanted.allSatisfy { work.isExcluded(by: $0) }
    }

    /// A toplist pages through the site's ranking, a few pages per request at most.
    private func toplistList(_ query: GalleryQuery, selected: Set<String>, toplist: Int, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        var list = toplists[toplist] ?? Toplist()
        if Date().timeIntervalSince(list.created) > 1800 { list = Toplist() }
        var requests = 0
        func found() -> [Int64] { list.ids.filter { matches($0, query: query, selected: selected) } }
        while list.more, requests < 4, found().count < offset + count {
            guard var components = URLComponents(string: site + "toplist.php") else { throw ContentError.invalidQuery }
            components.queryItems = [URLQueryItem(name: "tl", value: String(toplist)), URLQueryItem(name: "p", value: String(list.page))]
            guard let url = components.url else { throw ContentError.invalidQuery }
            let links = Self.links(in: try await page(url, site: site))
            keys.remember(links.map { ($0.id, $0.key) })
            _ = await previews(for: links, site: site)
            let known = Set(list.ids)
            let added = links.map(\.id).filter { !known.contains($0) }
            list.ids += added
            list.page += 1
            list.more = !added.isEmpty && list.page < 200
            requests += 1
        }
        toplists[toplist] = list
        let matched = found()
        return GalleryBatch(ids: Array(matched.dropFirst(offset).prefix(count)), hasMore: matched.count > offset + count || list.more)
    }

    private func page(_ url: URL, site: String, retried: Bool = false) async throws -> String {
        let host = URL(string: site)?.host?.lowercased()
        if let host { try await pacer.wait(host: host) }
        try prepare(site)
        let access = host.flatMap { SiteAccount.siteCookie(SiteAccount.accessCookie, host: $0) }
        let data: Data
        do { (data, _) = try await transport.get(url, limit: 3_000_000) }
        catch ContentError.unavailable(let status) where (300..<400).contains(status) { throw ContentError.signInRequired }
        try prepare(site)
        let text = String(decoding: data, as: UTF8.self)
        if let error = Self.pageError(text) {
            guard error == .signInRequired, let host else { throw error }
            // A members-only catalog shows its wall, or nothing, to a request that came without the
            // access it hands out with that same answer: the next request carries it.
            let handedOut = SiteAccount.siteCookie(SiteAccount.accessCookie, host: host)
            if !retried, let handedOut, handedOut != access { return try await page(url, site: site, retried: true) }
            // A refused access cookie is dropped, so the next request is handed a fresh one.
            if Self.isRestrictedNotice(text) { SiteAccount.forget(SiteAccount.accessCookie, host: host, refused: access) }
            if SiteAccount.refusesAccess(host: host) { throw ContentError.accessDenied }
            throw error
        }
        return text
    }

    /// What a page says instead of the listing or work it was asked for.
    nonisolated static func pageError(_ text: String) -> ContentError? {
        // These notices are whole pages of their own; a listing that merely names them in a title is not one.
        if text.utf8.count < 10_000 {
            let lowered = text.lowercased()
            if lowered.contains("temporarily banned") || lowered.contains("ban expires in") { return .temporarilyBlocked }
            if lowered.contains("exceeded your image viewing limits") || lowered.contains("you have reached the image limit") { return .imageLimit }
        }
        // A wrong or stale key, or a page that no longer exists, is answered with one short line.
        if text.utf8.count < 1_024 {
            let lowered = text.lowercased()
            if ["key missing", "invalid page", "keep trying", "gallery not found"].contains(where: lowered.contains) { return .galleryNotFound }
        }
        if isRestrictedNotice(text) || asksForSignIn(text) || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 64 { return .signInRequired }
        return nil
    }

    /// The wall a members-only catalog shows an account whose access cookie it does not accept.
    nonisolated static func isRestrictedNotice(_ text: String) -> Bool {
        guard text.utf8.count < 10_000 else { return false }
        let lowered = text.lowercased()
        return lowered.contains("kokomade.") || (lowered.contains("access to ") && lowered.contains(" is restricted"))
    }

    // MARK: Works

    func gallery(_ id: Int64, site: String) async throws -> NativeGallery {
        try prepare(site)
        guard id > 0 else { throw ContentError.invalidQuery }
        let (key, item) = try await detailsRow(id, site: site)
        guard let (preview, fileCount) = Self.work(from: item, site: site) else { throw ContentError.galleryNotFound }
        previews.setObject(Preview(preview), forKey: "\(site)#\(id)" as NSString)
        let detail = try await detailPage(id, key: key, page: 0, site: site)
        let cover = preview.pages.first?.thumbnailURL
        let pages = (0..<fileCount).map { index -> GalleryPage in
            let entry = detail.entries[index]
            return GalleryPage(hash: Self.pageHash(site: site, id: id, index: index), name: entry?.name ?? String(index + 1),
                               width: Int(entry?.thumb?.crop?.width ?? 0), height: Int(entry?.thumb?.crop?.height ?? 0), hasAVIF: false,
                               imageURL: nil, thumbnailURL: index == 0 ? cover : entry?.thumb.flatMap(Self.encoded),
                               index: index, sourceSite: site)
        }
        var work = NativeGallery(id: id, title: preview.title, artists: preview.artists, language: preview.language,
                                 type: preview.type, tags: preview.tags, pages: pages)
        work.uploader = preview.uploader
        return work
    }

    /// A work's details row with the key the site accepted for it. A remembered key the site no
    /// longer accepts, such as one another website handed over, is looked up again once.
    private func detailsRow(_ id: Int64, site: String) async throws -> (key: String, item: [String: Any]) {
        let remembered = keys.key(for: id) != nil
        var key = try await key(for: id, site: site)
        var item = try await metadata([Link(id: id, key: key)], site: site).first { Self.number($0["gid"]) == id }
        if remembered, item == nil || item?["error"] != nil {
            keys.forget(id)
            key = try await self.key(for: id, site: site)
            item = try await metadata([Link(id: id, key: key)], site: site).first { Self.number($0["gid"]) == id }
        }
        guard let item, item["error"] == nil else { throw ContentError.galleryNotFound }
        return (key, item)
    }

    /// A work as a list card shows it: title, tags, cover and page count from the details endpoint,
    /// never from the work's own page. Cards asking at the same moment share one details request,
    /// so a list that lost its cached details costs a request per 25 works, not a page load per card.
    func preview(_ id: Int64, site: String) async throws -> NativeGallery {
        try prepare(site)
        guard id > 0 else { throw ContentError.invalidQuery }
        if let cached = cachedPreview(id) { return cached }
        let remembered = keys.key(for: id) != nil
        let key = try await key(for: id, site: site)
        if let cached = cachedPreview(id) { return cached }
        let batch: PreviewBatch
        if let open = openBatch, open.site == site, open.links.count < 25 { batch = open }
        else {
            batch = PreviewBatch(site: site)
            openBatch = batch
            batch.task = Task { [weak self] in
                // Cards of one screen ask within moments of each other.
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return .failure(CancellationError()) }
                return await self.send(batch)
            }
        }
        if !batch.links.contains(where: { $0.id == id }) { batch.links.append(Link(id: id, key: key)) }
        let found = try await batch.task.value.get()
        try Task.checkCancellation()
        try prepare(site)
        if let work = found[id] { return work }
        // A key remembered from elsewhere may be one the site doesn't accept.
        guard remembered else { throw ContentError.galleryNotFound }
        let (_, item) = try await detailsRow(id, site: site)
        guard let (work, _) = Self.work(from: item, site: site) else { throw ContentError.galleryNotFound }
        previews.setObject(Preview(work), forKey: "\(site)#\(id)" as NSString)
        return work
    }

    private final class PreviewBatch: @unchecked Sendable {
        let site: String
        var links: [Link] = []
        var task: Task<Result<[Int64: NativeGallery], Error>, Never>!
        init(site: String) { self.site = site }
    }
    private var openBatch: PreviewBatch?
    /// Websites that wouldn't send original files lately, until when.
    private var originalsRefusedUntil: [String: Date] = [:]

    private func send(_ batch: PreviewBatch) async -> Result<[Int64: NativeGallery], Error> {
        if openBatch === batch { openBatch = nil }
        do { return .success(try await loadPreviews(batch.links, site: batch.site, throwing: true)) }
        catch { return .failure(error) }
    }

    /// The key comes from a link already seen, or from searching the number.
    func key(for id: Int64, site: String) async throws -> String {
        if let key = keys.key(for: id) { return key }
        guard let url = Self.keySearchURL(id, site: site) else { throw ContentError.invalidQuery }
        let links = Self.links(in: try await page(url, site: site))
        keys.remember(links.map { ($0.id, $0.key) })
        guard let link = links.first(where: { $0.id == id }) else { throw ContentError.galleryNotFound }
        return link.key
    }

    /// A search for one number. A signed-in account's own filters (hidden languages, uploaders and
    /// tags, and categories left out by default) apply to searches too, so they are switched off
    /// here and every category is asked for: otherwise a work the account filters would never be found.
    nonisolated static func keySearchURL(_ id: Int64, site: String) -> URL? {
        guard id > 0, var components = URLComponents(string: site) else { return nil }
        components.queryItems = [URLQueryItem(name: "f_search", value: "gid:\(id)"), URLQueryItem(name: "f_cats", value: "0"),
                                 URLQueryItem(name: "advsearch", value: "1"), URLQueryItem(name: "f_sfl", value: "on"),
                                 URLQueryItem(name: "f_sfu", value: "on"), URLQueryItem(name: "f_sft", value: "on")]
        return components.url
    }

    private func detailPage(_ id: Int64, key: String, page: Int, site: String) async throws -> Detail {
        if var cached = details[id], Date().timeIntervalSince(cached.created) < 1800 {
            if page == 0 || cached.entries.keys.contains(page * cached.perPage) { return cached }
            guard let url = URL(string: "\(site)g/\(id)/\(key)/?p=\(page)") else { throw ContentError.invalidQuery }
            let entries = Self.entries(in: try await self.page(url, site: site), galleryID: id)
            cached.entries.merge(entries) { _, new in new }
            details[id] = cached
            return cached
        }
        guard let url = URL(string: "\(site)g/\(id)/\(key)/" + (page > 0 ? "?p=\(page)" : "")) else { throw ContentError.invalidQuery }
        let text = try await self.page(url, site: site)
        var entries = Self.entries(in: text, galleryID: id)
        var perPage = page == 0 ? entries.count : (details[id]?.perPage ?? entries.count)
        // An account set to read in the multi-page viewer gets links into it instead of page links;
        // the viewer's own page lists every page's key at once.
        if entries.isEmpty, Self.linksToViewer(text, galleryID: id, key: key), let viewer = URL(string: "\(site)mpv/\(id)/\(key)/") {
            entries = Self.viewerEntries(in: try await self.page(viewer, site: site), previews: Self.viewerPreviews(in: text, galleryID: id))
            perPage = entries.count
        }
        guard !entries.isEmpty else { throw ContentError.galleryNotFound }
        if details.count >= 64, let oldest = details.min(by: { $0.value.created < $1.value.created })?.key { details[oldest] = nil }
        var detail = Detail(perPage: max(1, perPage), entries: entries)
        if page == 0 {
            detail.extras = KeyedWorkPage.extras(from: text)
            detail.apiKey = KeyedWorkPage.apiKey(in: text)
        }
        details[id] = detail
        return detail
    }

    private func entry(_ id: Int64, index: Int, site: String, refresh: Bool) async throws -> Entry {
        if refresh { details[id] = nil }
        let key = try await key(for: id, site: site)
        var detail = try await detailPage(id, key: key, page: 0, site: site)
        if let entry = detail.entries[index] { return entry }
        detail = try await detailPage(id, key: key, page: index / detail.perPage, site: site)
        guard let entry = detail.entries[index] else { throw ContentError.invalidResponse }
        return entry
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool, site: String) async throws -> Data {
        try prepare(site)
        let index = page.index ?? 0
        if thumbnail {
            if let url = page.thumbnailURL, Self.thumb(from: url)?.crop == nil { return try await fetch(url, galleryID: galleryID, limit: 2_000_000, site: site) }
            for attempt in 0..<2 {
                let entry = try await entry(galleryID, index: index, site: site, refresh: attempt > 0)
                guard let thumb = entry.thumb else { throw ContentError.invalidResponse }
                do { return try await preview(thumb, galleryID: galleryID, site: site) }
                catch ContentError.unavailable(let status) where attempt == 0 && [403, 404, 410].contains(status) { continue }
            }
            throw ContentError.invalidResponse
        }
        // A cover from a search row is all a preview carries; the reader asks for real pages.
        let entry = try await entry(galleryID, index: index, site: site, refresh: false)
        var reload: String?
        for attempt in 0..<3 {
            guard var components = URLComponents(string: "\(site)s/\(entry.key)/\(galleryID)-\(index + 1)") else { throw ContentError.invalidQuery }
            if let reload { components.queryItems = [URLQueryItem(name: "nl", value: reload)] }
            guard let url = components.url, let shown = Self.shownImage(in: try await self.page(url, site: site)) else { throw ContentError.unsupportedFormat }
            if Self.isLimitNotice(shown.url) { throw ContentError.imageLimit }
            if let original = shown.original, let host = URL(string: site)?.host?.lowercased(), Self.loadsOriginals(host: host),
               SiteAccount.isSignedIn, (originalsRefusedUntil[host] ?? .distantPast) < Date() {
                do { return try await fetch(original, galleryID: galleryID, limit: 64_000_000, site: site) }
                catch {
                    try Task.checkCancellation()
                    if let notice = error as? ContentError, [.imageLimit, .accessDenied, .temporarilyBlocked].contains(notice) { throw notice }
                    // The website keeps originals for GP the account may not have, or for quieter hours:
                    // the page shown in their place serves meanwhile.
                    originalsRefusedUntil[host] = Date().addingTimeInterval(600)
                }
            }
            do { return try await fetch(shown.url, galleryID: galleryID, limit: 24_000_000, site: site) }
            catch {
                try Task.checkCancellation()
                // A notice in place of the image is the site's answer, not one host's failure.
                if let notice = error as? ContentError, [.imageLimit, .signInRequired, .accessDenied, .temporarilyBlocked].contains(notice) { throw notice }
                // Another volunteer host serves the same image when this one fails.
                guard attempt < 2, let next = shown.reload, next != reload else { throw error }
                reload = next
            }
        }
        throw ContentError.invalidResponse
    }

    private func fetch(_ url: URL, galleryID: Int64, limit: Int, site: String) async throws -> Data {
        guard Self.safeMediaURL(url) else { throw ContentError.unsupportedFormat }
        MangaUrls.registerMedia([url], site: site)
        let host = URL(string: site)?.host?.lowercased()
        let access = host.flatMap { SiteAccount.siteCookie(SiteAccount.accessCookie, host: $0) }
        let (data, response) = try await transport.get(url, limit: limit, galleryID: galleryID)
        try prepare(site)
        if let notice = Self.textNotice(data, mimeType: response.mimeType) { throw notice }
        guard response.mimeType?.hasPrefix("image/") != false, data.count > 32 else { throw ContentError.unsupportedFormat }
        if let notice = Self.imageNotice(data, url: response.url ?? url) {
            // The wall means the access cookie lapsed; a fresh one is handed out on the next page.
            if notice == .signInRequired, let host {
                SiteAccount.forget(SiteAccount.accessCookie, host: host, refused: access)
                if SiteAccount.refusesAccess(host: host) { throw ContentError.accessDenied }
            }
            throw notice
        }
        return data
    }

    /// Image hosts answer in words when the account's allowance ran out or the network is banned,
    /// served where the image was expected. Only those two are read from such an answer.
    nonisolated static func textNotice(_ data: Data, mimeType: String?) -> ContentError? {
        guard data.count < 10_000, mimeType?.lowercased().hasPrefix("image/") != true else { return nil }
        let notice = pageError(String(decoding: data, as: UTF8.self))
        return notice == .imageLimit || notice == .temporarilyBlocked ? notice : nil
    }

    /// The site's own notices served where an image was expected, so they are never shown, cached or
    /// saved as a page: the bandwidth notice, and the wall a members-only catalog shows an account it
    /// no longer lets in. Known by address, or by size and digest.
    nonisolated static func imageNotice(_ data: Data, url: URL) -> ContentError? {
        if isLimitNotice(url) { return .imageLimit }
        let notices = [28_658: ("f54b887b017694dc25eb1a1404f71981885f8ed9", ContentError.imageLimit),
                       144_844: ("e48ed350e902a51581246d2a764fa7827e8e6988", ContentError.signInRequired)]
        guard let notice = notices[data.count] else { return nil }
        return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() == notice.0 ? notice.1 : nil
    }

    private func preview(_ thumb: Thumb, galleryID: Int64, site: String) async throws -> Data {
        guard let crop = thumb.crop else { return try await fetch(thumb.url, galleryID: galleryID, limit: 2_000_000, site: site) }
        let sheet: Data
        if let cached = sheets.object(forKey: thumb.url as NSURL) { sheet = cached as Data }
        else {
            sheet = try await fetch(thumb.url, galleryID: galleryID, limit: 6_000_000, site: site)
            sheets.setObject(sheet as NSData, forKey: thumb.url as NSURL, cost: sheet.count)
        }
        return try Self.cropped(sheet, to: crop)
    }

    /// Cuts one page preview out of a sheet of previews.
    nonisolated static func cropped(_ data: Data, to crop: CGRect) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ContentError.unsupportedFormat }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let area = crop.intersection(bounds)
        guard !area.isNull, area.width >= 1, area.height >= 1, let tile = image.cropping(to: area) else { throw ContentError.unsupportedFormat }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ContentError.unsupportedFormat }
        CGImageDestinationAddImage(destination, tile, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ContentError.unsupportedFormat }
        return output as Data
    }

    // MARK: Details endpoint

    /// Search rows only carry links, so their details come from the JSON endpoint in batches.
    private func previews(for links: [Link], site: String) async -> [Int64: NativeGallery] {
        (try? await loadPreviews(links, site: site, throwing: false)) ?? [:]
    }

    /// Details for works, 25 to a request. A failed request is asked once more after a moment;
    /// when it still fails, [throwing] decides whether the works it held are skipped or the failure is reported.
    private func loadPreviews(_ links: [Link], site: String, throwing: Bool) async throws -> [Int64: NativeGallery] {
        var found: [Int64: NativeGallery] = [:]
        let missing = links.filter { link in
            if let cached = cachedPreview(link.id) { found[link.id] = cached; return false }
            return true
        }
        for start in stride(from: 0, to: missing.count, by: 25) {
            let chunk = Array(missing[start..<min(missing.count, start + 25)])
            let items: [[String: Any]]
            do {
                do { items = try await metadata(chunk, site: site) }
                catch let error where !(error is CancellationError) {
                    try await Task.sleep(for: .seconds(1))
                    try prepare(site)
                    items = try await metadata(chunk, site: site)
                }
            } catch {
                if throwing || error is CancellationError { throw error }
                continue
            }
            for item in items {
                guard let id = Self.number(item["gid"]), item["error"] == nil, let (work, _) = Self.work(from: item, site: site) else { continue }
                previews.setObject(Preview(work), forKey: "\(site)#\(id)" as NSString)
                found[id] = work
            }
        }
        return found
    }

    private func metadata(_ links: [Link], site: String) async throws -> [[String: Any]] {
        let object = try await api(["method": "gdata", "gidlist": links.map { [$0.id, $0.key] as [Any] }, "namespace": 1], site: site)
        guard let items = object["gmetadata"] as? [[String: Any]], items.count <= 25 else { throw ContentError.invalidResponse }
        for item in items { if let thumb = (item["thumb"] as? String).flatMap(URL.init(string:)) { MangaUrls.registerMedia([thumb], site: site) } }
        return items
    }

    private func api(_ body: [String: Any], site: String) async throws -> [String: Any] {
        guard let url = MangaUrls.keyedAPI else { throw ContentError.invalidResponse }
        let request = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await transport.post(url, body: request, contentType: "application/json", limit: 2_000_000)
        try prepare(site)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ContentError.invalidResponse }
        return object
    }

    func suggestions(_ token: String, site: String) async throws -> [TagSuggestion] {
        try prepare(site)
        guard let context = TagCompletionContext(token) else { return [] }
        let parts = context.token.split(separator: ":", maxSplits: 1).map(String.init)
        let namespace = parts.count == 2 ? parts[0] : nil
        let term = parts.last!.replacingOccurrences(of: "_", with: " ")
        let remote = namespace.map { ($0 == "series" ? "parody" : $0 == "tag" ? "other" : $0) + ":" + term } ?? term
        let object = try await api(["method": "tagsuggest", "text": remote], site: site)
        let rows = (object["tags"] as? [String: [String: Any]] ?? [:]).sorted { (Int($0.key) ?? .max) < (Int($1.key) ?? .max) }.map(\.value)
        var seen = Set<String>()
        return rows.compactMap { row in
            // A spelling the site folds into another tag suggests that tag instead.
            guard let space = (row["mns"] ?? row["ns"]) as? String, let name = (row["mtn"] ?? row["tn"]) as? String,
                  !name.isEmpty, name.count <= 120 else { return nil }
            let local = Self.localNamespace(space)
            guard TagSuggestion.namespaces.contains(local), namespace == nil || namespace == local else { return nil }
            let item = TagSuggestion(namespace: local, name: name, count: nil)
            return seen.insert(item.id).inserted ? item : nil
        }.prefix(20).map { $0 }
    }

    // MARK: Ratings and comments

    func extras(_ id: Int64, site: String) async throws -> WorkExtras {
        try prepare(site)
        let key = try await key(for: id, site: site)
        var detail = try await detailPage(id, key: key, page: 0, site: site)
        if detail.extras == nil {
            // A page cached by a later page's request lacks what only the first page says.
            details[id] = nil
            detail = try await detailPage(id, key: key, page: 0, site: site)
        }
        return detail.extras ?? WorkExtras()
    }

    func allComments(_ id: Int64, site: String) async throws -> [WorkComment] {
        try prepare(site)
        let key = try await key(for: id, site: site)
        guard let url = URL(string: "\(site)g/\(id)/\(key)/?hc=1") else { throw ContentError.invalidQuery }
        return KeyedWorkPage.comments(from: try await page(url, site: site))
    }

    func rate(_ id: Int64, halfStars: Int, site: String) async throws -> (average: Double, count: Int) {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard (1...10).contains(halfStars) else { throw ContentError.invalidQuery }
        let key = try await key(for: id, site: site)
        var detail = try await detailPage(id, key: key, page: 0, site: site)
        if detail.apiKey == nil { details[id] = nil; detail = try await detailPage(id, key: key, page: 0, site: site) }
        guard let credentials = detail.apiKey else { throw ContentError.signInRequired }
        let object = try await api(["method": "rategallery", "apiuid": credentials.uid, "apikey": credentials.key, "gid": id, "token": key, "rating": halfStars], site: site)
        guard let average = (object["rating_avg"] as? NSNumber)?.doubleValue else { throw ContentError.invalidResponse }
        let count = (object["rating_cnt"] as? NSNumber)?.intValue ?? 0
        if var cached = details[id], var extras = cached.extras {
            extras.rating = average; extras.ratingCount = count
            cached.extras = extras
            details[id] = cached
        }
        return (average, count)
    }

    // MARK: Tags, comments, archives and settings profiles

    func voteTag(_ id: Int64, tag: String, vote: Int, site: String) async throws -> [WorkTagVote] {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard vote == 1 || vote == -1, !tag.isEmpty, tag.count <= 200 else { throw ContentError.invalidQuery }
        let key = try await key(for: id, site: site)
        var detail = try await detailPage(id, key: key, page: 0, site: site)
        if detail.apiKey == nil { details[id] = nil; detail = try await detailPage(id, key: key, page: 0, site: site) }
        guard let credentials = detail.apiKey else { throw ContentError.signInRequired }
        let object = try await api(["method": "taggallery", "apiuid": credentials.uid, "apikey": credentials.key, "gid": id, "token": key,
                                    "tags": tag, "vote": vote], site: site)
        if let message = object["error"] as? String, !message.isEmpty { throw SiteMessage(text: message) }
        let votes = KeyedWorkPage.tagVotes(from: object["tagpane"] as? String ?? "")
        guard !votes.isEmpty else { throw ContentError.invalidResponse }
        details[id]?.extras?.tagVotes = votes
        return votes
    }

    /// The website takes a comment of at least ten bytes, and joins it to the account's own comment
    /// when that one is the last.
    func postComment(_ id: Int64, text: String, site: String) async throws -> [WorkComment] {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count >= 10 else { throw SiteMessage(text: L10n.text("A comment is too short.")) }
        guard text.utf8.count <= 10_000 else { throw ContentError.invalidQuery }
        let key = try await key(for: id, site: site)
        guard let url = URL(string: "\(site)g/\(id)/\(key)/"), let host = URL(string: site)?.host?.lowercased() else { throw ContentError.invalidQuery }
        try await pacer.wait(host: host)
        let (data, _) = try await transport.post(url, body: Data(("commenttext_new=" + Self.formEncoded(text)).utf8),
                                                 contentType: "application/x-www-form-urlencoded", limit: 3_000_000)
        try prepare(site)
        let page = String(decoding: data, as: UTF8.self)
        if Self.asksForSignIn(page) { throw ContentError.signInRequired }
        if let error = Self.pageError(page), error != .signInRequired { throw error }
        details[id] = nil
        let probe = Self.commentProbe(text)
        func posted(_ comments: [WorkComment]) -> Bool { comments.contains { Self.commentProbe($0.text).contains(probe) } }
        var comments = KeyedWorkPage.comments(from: page)
        if posted(comments) { return comments }
        // A long conversation shows only part of itself on the work's page.
        comments = try await allComments(id, site: site)
        if posted(comments) { return comments }
        throw SiteMessage(text: KeyedWorkPage.firstCapture(#"<p class="br">(.*?)</p>"#, in: page).map { KeyedWorkPage.plain($0) }
                          ?? L10n.text("The website didn’t take the comment. Try again later."))
    }

    private nonisolated static func commentProbe(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace }.prefix(40))
    }

    private func archiverURL(_ id: Int64, site: String) async throws -> URL {
        let extras = try await extras(id, site: site)
        // The work page names its archive page; only a page on the connected website is followed.
        if let named = extras.archiveURL, named.host?.lowercased() == URL(string: site)?.host?.lowercased() { return named }
        let key = try await key(for: id, site: site)
        var components = URLComponents(string: site + "archiver.php")
        components?.queryItems = [URLQueryItem(name: "gid", value: String(id)), URLQueryItem(name: "token", value: key)]
        guard let url = components?.url else { throw ContentError.invalidQuery }
        return url
    }

    func archiveOffer(_ id: Int64, site: String) async throws -> WorkArchiveOffer {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        let offer = KeyedWorkPage.archiveOffer(from: try await page(try await archiverURL(id, site: site), site: site))
        guard !offer.options.isEmpty else { throw ContentError.unsupportedFormat }
        return offer
    }

    func archiveDownloadURL(_ id: Int64, option: WorkArchiveOffer.Option, site: String) async throws -> URL {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard ["org", "res"].contains(option.kind), option.available else { throw ContentError.invalidQuery }
        let url = try await archiverURL(id, site: site)
        if let host = url.host?.lowercased() { try await pacer.wait(host: host) }
        let form = "dltype=" + Self.formEncoded(option.kind) + "&dlcheck=" + Self.formEncoded(option.button)
        let (data, _) = try await transport.post(url, body: Data(form.utf8), contentType: "application/x-www-form-urlencoded", limit: 1_000_000)
        try prepare(site)
        let page = String(decoding: data, as: UTF8.self)
        if Self.asksForSignIn(page) { throw ContentError.signInRequired }
        guard let address = KeyedWorkPage.archiveDownloadURL(from: page) else {
            throw SiteMessage(text: KeyedWorkPage.message(in: page) ?? L10n.text("The website didn’t prepare the archive. Try again later."))
        }
        guard Self.safeMediaURL(address) else { throw ContentError.unsupportedFormat }
        MangaUrls.registerMedia([address], site: site)
        return address
    }

    /// The account's settings profiles, which one the app uses checked.
    func settingsProfiles(site: String) async throws -> [SiteSettingsProfile] {
        try prepare(site)
        guard SiteAccount.isSignedIn, let url = URL(string: site + "uconfig.php") else { throw ContentError.signInRequired }
        return KeyedWorkPage.settingsProfiles(from: try await page(url, site: site))
    }

    /// Reads the website with one of the account's settings profiles from now on.
    func useSettingsProfile(_ profile: Int, site: String) throws {
        try prepare(site)
        guard (1...9999).contains(profile), let host = URL(string: site)?.host?.lowercased() else { throw ContentError.invalidQuery }
        SiteAccount.setSiteCookie(Self.profileCookie, value: String(profile), host: host)
        // Lists and work pages read with the other profile may look different.
        feeds.removeAll(); details.removeAll(); toplists.removeAll(); popular = nil
    }

    /// The cookie the website reads the chosen settings profile from.
    nonisolated static let profileCookie = "sp"

    // MARK: Account favorites

    /// One page of the signed-in account's favorites, newest first, from one category or all.
    func favorites(after next: String?, category: Int? = nil, site: String) async throws -> (ids: [Int64], next: String?) {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard var components = URLComponents(string: site + "favorites.php") else { throw ContentError.invalidQuery }
        var items: [URLQueryItem] = []
        if let category, (0...9).contains(category) { items.append(URLQueryItem(name: "favcat", value: String(category))) }
        if let next { items.append(URLQueryItem(name: "next", value: next)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw ContentError.invalidQuery }
        let text = try await page(url, site: site)
        let links = Self.links(in: text)
        keys.remember(links.map { ($0.id, $0.key) })
        _ = await previews(for: links, site: site)
        let cursor = Self.nextCursor(in: text)
        return (links.map(\.id), links.isEmpty || cursor == next ? nil : cursor)
    }

    /// How many images the account has viewed against its allowance, when the site shows it.
    func imageAllowance(site: String) async throws -> (used: Int, limit: Int)? {
        try prepare(site)
        guard SiteAccount.isSignedIn, let url = URL(string: site + "home.php") else { return nil }
        let text: String
        do { text = try await page(url, site: site) }
        catch ContentError.unavailable(404) { return nil }
        return Self.imageAllowance(in: text)
    }

    nonisolated static func imageAllowance(in text: String) -> (used: Int, limit: Int)? {
        guard let used = KeyedWorkPage.firstCapture(#"currently at\s*<strong>([0-9,]+)</strong>"#, in: text),
              let limit = KeyedWorkPage.firstCapture(#"limit of\s*<strong>([0-9,]+)</strong>"#, in: text),
              let usedValue = Int(used.replacingOccurrences(of: ",", with: "")),
              let limitValue = Int(limit.replacingOccurrences(of: ",", with: "")), limitValue > 0 else { return nil }
        return (usedValue, limitValue)
    }

    /// The account's favorites categories with their names and how many works each holds.
    func favoriteCategories(site: String) async throws -> [FavoriteCategory] {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard let url = URL(string: site + "favorites.php") else { throw ContentError.invalidQuery }
        let categories = Self.favoriteCategories(in: try await page(url, site: site))
        guard !categories.isEmpty else { throw ContentError.unsupportedFormat }
        return categories
    }

    func setFavorite(_ id: Int64, saved: Bool, category: Int = 0, site: String) async throws {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        let key = try await key(for: id, site: site)
        guard var components = URLComponents(string: site + "gallerypopups.php") else { throw ContentError.invalidQuery }
        components.queryItems = [URLQueryItem(name: "gid", value: String(id)), URLQueryItem(name: "t", value: key), URLQueryItem(name: "act", value: "addfav")]
        guard let url = components.url else { throw ContentError.invalidQuery }
        // The form sends the note along, so a work that is already a favorite keeps the note written
        // for it; a work its page showed as no favorite has none to keep.
        var note = ""
        if saved, details[id]?.extras.map({ $0.favoriteCategory != nil }) ?? true {
            note = Self.favoriteNote(in: try await page(url, site: site)) ?? ""
        }
        // The form's own submit button names the change; removing sends the button its page shows for it.
        let form = saved ? "favcat=\(min(9, max(0, category)))&favnote=\(Self.formEncoded(note))&apply=Add+to+Favorites&update=1"
            : "favcat=favdel&favnote=&apply=Apply+Changes&update=1"
        if let host = URL(string: site)?.host?.lowercased() { try await pacer.wait(host: host) }
        let (data, _) = try await transport.post(url, body: Data(form.utf8), contentType: "application/x-www-form-urlencoded", limit: 1_000_000)
        try prepare(site)
        // The work page read before the change shows the old favorite.
        details[id]?.extras = nil
        let text = String(decoding: data, as: UTF8.self)
        if Self.asksForSignIn(text) || text.contains("Failed login redirect setup") { throw ContentError.signInRequired }
        // A wrong key, a removed work or a ban is answered in a few words instead of with the change.
        if let error = Self.pageError(text), error != .signInRequired { throw error }
    }

    /// The note the account wrote for a favorite, from the favorites form.
    nonisolated static func favoriteNote(in html: String) -> String? {
        KeyedWorkPage.firstCapture(#"<textarea\b[^>]*\bname="favnote"[^>]*>(.*?)</textarea>"#, in: html).map { NativeGallery.decodeEntities($0) }
    }

    /// A form value, with only unreserved ASCII left as is.
    nonisolated static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._* ")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: " ", with: "+")
    }

    // MARK: Page shapes

    /// Category rows at the top of the favorites page: each names its number in its link, then
    /// shows its count, its icon and its name.
    nonisolated static func favoriteCategories(in text: String) -> [FavoriteCategory] {
        guard let regex = try? NSRegularExpression(pattern: #"<div class="fp(?: [^"]*)?"[^>]*favcat=([0-9])[^>]*>"#) else { return [] }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result: [FavoriteCategory] = []
        for (index, match) in matches.enumerated() {
            guard let number = Int(source.substring(with: match.range(at: 1))), !result.contains(where: { $0.id == number }) else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : min(source.length, start + 800)
            let body = source.substring(with: NSRange(location: start, length: max(0, end - start)))
            let texts = KeyedWorkPage.texts(inDivs: body)
            let count = texts.first.flatMap { Int($0.replacingOccurrences(of: ",", with: "")) } ?? 0
            // The last row runs on into the "show all" button after it, so the name is the first text after the count.
            let name = texts.dropFirst().first { !$0.isEmpty && Int($0.replacingOccurrences(of: ",", with: "")) == nil } ?? ""
            result.append(FavoriteCategory(id: number, name: name.isEmpty ? "\(number)" : name, count: count))
        }
        return result.sorted { $0.id < $1.id }
    }

    private nonisolated static let linkPattern = try! NSRegularExpression(pattern: #"/g/([0-9]{1,10})/([0-9a-f]{10})(?![0-9a-f])"#)

    /// Work links in page order, each once.
    nonisolated static func links(in text: String) -> [Link] {
        let source = text as NSString
        var seen = Set<Int64>()
        return linkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let id = Int64(source.substring(with: match.range(at: 1))), id > 0, seen.insert(id).inserted else { return nil }
            return Link(id: id, key: source.substring(with: match.range(at: 2)))
        }
    }

    private nonisolated static let viewerAddressPattern = try! NSRegularExpression(pattern: #"/mpv/([0-9]{1,10})/([0-9a-f]{10})(?![0-9a-f])"#)
    private nonisolated static let pageAddressPattern = try! NSRegularExpression(pattern: #"/s/[0-9a-f]{10}/([0-9]{1,10})-([0-9]{1,5})(?![0-9])"#)

    /// Links into the multi-page viewer, which name the work's number and key like its own link.
    nonisolated static func viewerLinks(in text: String) -> [Link] {
        let source = text as NSString
        var seen = Set<Int64>()
        return viewerAddressPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let id = Int64(source.substring(with: match.range(at: 1))), id > 0, seen.insert(id).inserted else { return nil }
            return Link(id: id, key: source.substring(with: match.range(at: 2)))
        }
    }

    /// Links to one page of a work: the work's number and the page, from 1. The key in them is the page's, not the work's.
    nonisolated static func pageLinks(in text: String) -> [(id: Int64, page: Int)] {
        let source = text as NSString
        return pageAddressPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let id = Int64(source.substring(with: match.range(at: 1))), id > 0,
                  let page = Int(source.substring(with: match.range(at: 2))), page >= 1 else { return nil }
            return (id, page)
        }
    }

    nonisolated static func nextCursor(in text: String) -> String? {
        guard let tag = text.range(of: #"<a\b[^>]*\bid="unext"[^>]*>"#, options: .regularExpression),
              let href = attribute("href", in: String(text[tag])),
              let value = URLComponents(string: decode(href))?.queryItems?.first(where: { $0.name == "next" })?.value,
              value.range(of: #"^[0-9A-Za-z_-]{1,40}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private nonisolated static let entryPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*\bhref="([^"]*)/s/([0-9a-f]{10})/([0-9]{1,10})-([0-9]{1,5})"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])

    /// Page links on a work's page, by zero-based page index, with each page's preview.
    nonisolated static func entries(in text: String, galleryID: Int64) -> [Int: Entry] {
        let source = text as NSString
        var result: [Int: Entry] = [:]
        for match in entryPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard Int64(source.substring(with: match.range(at: 3))) == galleryID,
                  let number = Int(source.substring(with: match.range(at: 4))), number >= 1 else { continue }
            let body = source.substring(with: match.range(at: 5))
            var name = String(number)
            if let title = attribute("title", in: body), let colon = title.range(of: ": ") { name = decode(String(title[colon.upperBound...])) }
            // The page link beside a preview says which site a preview starting at the root belongs to.
            let base = URL(string: decode(source.substring(with: match.range(at: 1)))).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
            result[number - 1] = Entry(key: source.substring(with: match.range(at: 2)), name: name, thumb: thumb(in: body, base: base))
        }
        return result
    }

    /// A preview address, resolved against the page link beside it when it starts at the site's root.
    private nonisolated static func mediaURL(_ value: String, base: URL?) -> URL? {
        let address = decode(value).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        let relative = address.hasPrefix("/") && !address.hasPrefix("//")
        guard let url = relative ? base.flatMap({ URL(string: address, relativeTo: $0)?.absoluteURL }) : URL(string: address), safeMediaURL(url) else { return nil }
        return url
    }

    private nonisolated static func thumb(in body: String, base: URL? = nil) -> Thumb? {
        if let style = attribute("style", in: body),
           let size = style.range(of: #"width:\s*([0-9]+)px;\s*height:\s*([0-9]+)px"#, options: .regularExpression),
           let sheet = style.range(of: #"url\(([^)]+)\)\s*(-?[0-9]+)px"#, options: .regularExpression) {
            let numbers = String(style[size]).split { !$0.isNumber }.compactMap { Int($0) }
            let declaration = String(style[sheet])
            guard numbers.count == 2, let open = declaration.firstIndex(of: "("), let close = declaration.firstIndex(of: ")"),
                  let url = mediaURL(String(declaration[declaration.index(after: open)..<close]), base: base),
                  let offset = Int(declaration[declaration.index(after: close)...].trimmingCharacters(in: .whitespaces).dropLast(2)) else { return nil }
            return Thumb(url: url, crop: CGRect(x: -offset, y: 0, width: numbers[0], height: numbers[1]))
        }
        if let image = body.range(of: #"<img\b[^>]*>"#, options: .regularExpression),
           let value = attribute("src", in: String(body[image])), let url = mediaURL(value, base: base) {
            return Thumb(url: url, crop: nil)
        }
        // Large previews are whole images drawn as a background with no offset into a sheet.
        if let style = attribute("style", in: body), let declaration = style.range(of: #"url\(([^)]+)\)"#, options: .regularExpression) {
            if let url = mediaURL(String(style[declaration].dropFirst(4).dropLast()), base: base) { return Thumb(url: url, crop: nil) }
        }
        return nil
    }

    private nonisolated static let viewerLinkPattern = try! NSRegularExpression(pattern: #"/mpv/([0-9]{1,10})/([0-9a-f]{10})/"#)

    /// Whether a work's page links its pages into the multi-page viewer rather than to each page.
    nonisolated static func linksToViewer(_ text: String, galleryID: Int64, key: String) -> Bool {
        let source = text as NSString
        return viewerLinkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).contains {
            Int64(source.substring(with: $0.range(at: 1))) == galleryID && source.substring(with: $0.range(at: 2)) == key
        }
    }

    private nonisolated static let viewerPreviewPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*\bhref="([^"]*)/mpv/([0-9]{1,10})/[0-9a-f]{10}/#page([0-9]{1,5})"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])

    /// The previews a work's page shows beside its links into the multi-page viewer, by zero-based page index.
    nonisolated static func viewerPreviews(in text: String, galleryID: Int64) -> [Int: Thumb] {
        let source = text as NSString
        var result: [Int: Thumb] = [:]
        for match in viewerPreviewPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard Int64(source.substring(with: match.range(at: 2))) == galleryID,
                  let number = Int(source.substring(with: match.range(at: 3))), number >= 1 else { continue }
            let base = URL(string: decode(source.substring(with: match.range(at: 1)))).flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
            if let thumb = thumb(in: source.substring(with: match.range(at: 4)), base: base) { result[number - 1] = thumb }
        }
        return result
    }

    /// Every page of a work from the multi-page viewer's list: each page's key, file name and preview, in page order.
    /// A page whose listed preview is not a plain address takes the one its work page showed, when it showed one.
    nonisolated static func viewerEntries(in text: String, previews: [Int: Thumb] = [:]) -> [Int: Entry] {
        guard let start = text.range(of: #"\bimagelist\s*=\s*\["#, options: .regularExpression) else { return [:] }
        let open = text.index(before: start.upperBound)
        var depth = 0, quoted = false, escaped = false, close: String.Index?
        for index in text[open...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "[" || character == "{" { depth += 1 }
            else if character == "]" || character == "}" {
                depth -= 1
                if depth == 0 { close = index; break }
            }
        }
        guard let close, let data = String(text[open...close]).data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], items.count <= 10_000 else { return [:] }
        var result: [Int: Entry] = [:]
        for (index, item) in items.enumerated() {
            guard let key = item["k"] as? String, GalleryKeys.isKey(key) else { continue }
            let name = (item["n"] as? String).map(decode).flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
            let listed = (item["t"] as? String).flatMap(URL.init(string:)).flatMap { safeMediaURL($0) ? Thumb(url: $0, crop: nil) : nil }
            result[index] = Entry(key: key, name: name, thumb: listed ?? previews[index])
        }
        return result
    }

    /// A tile of a preview sheet travels as the sheet's address plus its rectangle.
    nonisolated static func encoded(_ thumb: Thumb) -> URL? {
        guard let crop = thumb.crop, var components = URLComponents(url: thumb.url, resolvingAgainstBaseURL: false) else { return thumb.url }
        components.fragment = "crop=\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))"
        return components.url
    }

    nonisolated static func thumb(from url: URL) -> Thumb? {
        guard let fragment = url.fragment, fragment.hasPrefix("crop=") else { return Thumb(url: url, crop: nil) }
        let values = fragment.dropFirst(5).split(separator: ",").compactMap { Int($0) }
        guard values.count == 4, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.url.map { Thumb(url: $0, crop: CGRect(x: values[0], y: values[1], width: values[2], height: values[3])) }
    }

    nonisolated static func shownImage(in text: String) -> ShownImage? {
        guard let tag = text.range(of: #"<img\b[^>]*\bid="img"[^>]*>"#, options: .regularExpression),
              let value = attribute("src", in: String(text[tag])), let url = URL(string: decode(value)) else { return nil }
        var reload: String?
        if let call = text.range(of: #"nl\('([0-9A-Za-z_-]{1,64})'\)"#, options: .regularExpression) {
            reload = String(text[call].dropFirst(4).dropLast(2))
        }
        // Shown only to signed-in accounts, and only when the original is larger than the page shown.
        let original = KeyedWorkPage.firstCapture(#"<a\b[^>]*\bhref="([^"]*fullimg[^"]*)""#, in: text)
            .flatMap { URL(string: decode($0)) }.flatMap { $0.scheme == "https" ? $0 : nil }
        return ShownImage(url: url, reload: reload, original: original)
    }

    private static let originalsKey = "manga.originalImageSites"

    /// Whether the reader loads each page's original file on [host], for a signed-in account.
    nonisolated static func loadsOriginals(host: String) -> Bool {
        (ContentPreferences.defaults.stringArray(forKey: originalsKey) ?? []).contains(host)
    }

    nonisolated static func setLoadsOriginals(_ loads: Bool, host: String) {
        var hosts = Set(ContentPreferences.defaults.stringArray(forKey: originalsKey) ?? [])
        if loads { hosts.insert(host) } else { hosts.remove(host) }
        ContentPreferences.defaults.set(hosts.sorted(), forKey: originalsKey)
    }

    /// When an account's image allowance runs out, the site shows a fixed notice image instead.
    nonisolated static func isLimitNotice(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("509")
    }

    nonisolated static func asksForSignIn(_ text: String) -> Bool {
        text.range(of: #"<input\b[^>]*\btype="password""#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: #"\b"# + name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
        return String(tag[range].dropFirst(name.count + 2).dropLast())
    }

    private nonisolated static func decode(_ text: String) -> String { NativeGallery.decodeEntities(text) }

    // MARK: Search and metadata

    nonisolated static func searchURL(_ query: GalleryQuery, site: String, categories: Set<String>, language: String?, next: String?) throws -> URL {
        guard var components = URLComponents(string: site) else { throw ContentError.invalidQuery }
        let tokens = query.text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("type:") && !$0.hasPrefix("-type:") }
        guard tokens.count <= GalleryQuery.maximumSearchTerms, tokens.allSatisfy({ $0.count <= 120 && !$0.contains("\"") }) else { throw ContentError.invalidQuery }
        var terms = tokens.filter { !$0.hasPrefix("-") }.map(remoteTerm)
        if let language { terms.append(remoteTerm("language:" + language)) }
        if let artist = query.artist { terms.append(remoteTerm("artist:" + artist.replacingOccurrences(of: " ", with: "_"))) }
        // Exclusions go along while the search box has room; the rest are checked on the results.
        for exclusion in tokens.filter({ $0.hasPrefix("-") }).map(remoteTerm) {
            let joined = (terms + [exclusion]).joined(separator: " ")
            if joined.count <= searchLimit { terms.append(exclusion) }
        }
        var items: [URLQueryItem] = []
        if !terms.isEmpty { items.append(URLQueryItem(name: "f_search", value: terms.joined(separator: " "))) }
        // Always sent, so the categories picked here win over those an account leaves out by default.
        let shown = categories.reduce(0) { $0 | (categoryBits[$1] ?? 0) }
        items.append(URLQueryItem(name: "f_cats", value: String(1023 & ~shown)))
        if let next { items.append(URLQueryItem(name: "next", value: next)) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw ContentError.invalidQuery }
        return url
    }

    /// The app writes tags with underscores; the site matches a whole tag when it is quoted and closed with `$`.
    nonisolated static func remoteTerm(_ term: String) -> String {
        let excluded = term.hasPrefix("-")
        let body = excluded ? String(term.dropFirst()) : term
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        let prefix = excluded ? "-" : ""
        if parts.count == 2, !parts[1].isEmpty {
            let namespace = parts[0] == "series" ? "parody" : parts[0] == "tag" ? "other" : parts[0]
            return prefix + namespace + ":\"" + parts[1].replacingOccurrences(of: "_", with: " ") + "$\""
        }
        let words = body.replacingOccurrences(of: "_", with: " ")
        return prefix + (words.contains(" ") ? "\"" + words + "\"" : words)
    }

    private nonisolated static func localNamespace(_ namespace: String) -> String {
        namespace == "parody" ? "series" : namespace == "other" ? "tag" : namespace
    }

    nonisolated static func selectedCategories(_ query: GalleryQuery) throws -> Set<String> {
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        var selected = terms.contains(where: { $0.hasPrefix("type:") }) ? Set<String>() : allCategories
        for term in terms where term.hasPrefix("type:") || term.hasPrefix("-type:") {
            let name = GalleryCategory.key(String(term.split(separator: ":", maxSplits: 1).last ?? ""))
            guard allCategories.contains(name) else { throw ContentError.invalidQuery }
            if term.hasPrefix("-") { selected.remove(name) } else { selected.insert(name) }
        }
        return selected
    }

    /// A details row as a work with its cover as the only page, plus how many pages the work has.
    nonisolated static func work(from item: [String: Any], site: String) -> (NativeGallery, Int)? {
        guard let id = number(item["gid"]), id > 0 else { return nil }
        if let key = item["token"] as? String { GalleryKeys.shared.remember(id, key: key) }
        let tags = (item["tags"] as? [String] ?? []).map { tag -> (String, String) in
            let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : ("other", tag)
        }
        let languages = tags.filter { $0.0 == "language" }.map(\.1)
        let language = languages.first { !["translated", "rewrite"].contains($0) } ?? ""
        let category = GalleryCategory.key(item["category"] as? String ?? "")
        let title = DocumentCatalogSource.title(item, id: id, language: language, translated: languages.contains("translated"))
        var pages: [GalleryPage] = []
        if let value = item["thumb"] as? String, let cover = URL(string: value), safeMediaURL(cover) {
            pages = [GalleryPage(hash: pageHash(site: site, id: id, index: -1), name: "cover", width: 0, height: 0, hasAVIF: false,
                                 imageURL: cover, thumbnailURL: cover, index: 0, sourceSite: site)]
        }
        var work = NativeGallery(id: id, title: NativeGallery.decodeEntities(title), artists: tags.filter { $0.0 == "artist" }.map(\.1),
                                 language: language, type: category == "asianporn" ? "photo" : category,
                                 tags: tags.filter { $0.0 != "language" && $0.0 != "artist" }.map { localNamespace($0.0) + ":" + $0.1 }, pages: pages)
        let fileCount = max(0, min(10_000, Int(number(item["filecount"]) ?? 0)))
        work.pageCount = fileCount
        work.uploader = (item["uploader"] as? String).map(NativeGallery.decodeEntities).flatMap { $0.isEmpty ? nil : $0 }
        return (work, fileCount)
    }

    private nonisolated static func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value ?? (value as? String).flatMap { Int64($0) }
    }

    private nonisolated static func pageHash(site: String, id: Int64, index: Int) -> String {
        SHA256.hash(data: Data("\(site)#keyed:\(id):\(index)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Volunteer image hosts use their own ports, but never addresses inside the device's network.
    nonisolated static func safeMediaURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), host.contains("."),
              !host.contains(":"), host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              host.split(separator: ".").compactMap({ Int($0) }).count != 4 else { return false }
        return url.port.map { $0 == 443 || (1024...65535).contains($0) } ?? true
    }
}
