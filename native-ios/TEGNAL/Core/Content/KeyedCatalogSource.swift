import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

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
    }
    private struct Detail {
        var perPage: Int
        var entries: [Int: Entry]
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
    private var site = ""
    private var feeds: [GalleryQuery: Feed] = [:]
    private var details: [Int64: Detail] = [:]
    private var popular: ([Int64], Date)?
    private nonisolated(unsafe) let previews = NSCache<NSString, Preview>()
    private nonisolated(unsafe) let sheets = NSCache<NSURL, NSData>()

    static let allCategories: Set<String> = ["doujinshi", "manga", "artistcg", "gamecg", "western", "non-h", "imageset", "cosplay", "photo", "misc"]
    private static let visualCategories: Set<String> = ["artistcg", "gamecg", "imageset"]
    private static let categoryBits = ["misc": 1, "doujinshi": 2, "manga": 4, "artistcg": 8, "gamecg": 16, "imageset": 32,
                                       "cosplay": 64, "photo": 128, "non-h": 256, "western": 512]
    private static let searchLimit = 200

    init(transport: ContentTransport, keys: GalleryKeys = .shared) {
        self.transport = transport
        self.keys = keys
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
            feeds.removeAll(); details.removeAll(); popular = nil
            previews.removeAllObjects(); sheets.removeAllObjects()
        }
    }

    // MARK: Listing

    func list(_ query: GalleryQuery, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        try prepare(site)
        let selected = try Self.selectedCategories(query)
        if query.sort != .latest { return try await popularList(query, selected: selected, offset: offset, count: count, site: site) }
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
        let url = try Self.searchURL(query, site: site, categories: lane.categories, language: lane.language, next: lane.next)
        let text = try await page(url, site: site)
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
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("type:") && !$0.hasPrefix("-type:") }
        let wanted = terms.filter { !$0.hasPrefix("-") } + (query.artist.map { ["artist:" + $0.replacingOccurrences(of: " ", with: "_")] } ?? [])
        let excluded = terms.filter { $0.hasPrefix("-") }.joined(separator: " ")
        let matches = ids.filter { id in
            guard let work = cachedPreview(id) else { return true }
            if !work.type.isEmpty && !selected.contains(work.type) { return false }
            if query.language != "all" && work.language != query.language
                && !(query.allowsLanguageExceptions && Self.visualCategories.contains(work.type)) { return false }
            if !excluded.isEmpty && work.isExcluded(by: excluded) { return false }
            return wanted.allSatisfy { work.isExcluded(by: $0) }
        }
        return GalleryBatch(ids: Array(matches.dropFirst(offset).prefix(count)), hasMore: matches.count > offset + count)
    }

    private func page(_ url: URL, site: String) async throws -> String {
        let data: Data
        do { (data, _) = try await transport.get(url, limit: 3_000_000) }
        catch ContentError.unavailable(let status) where (300..<400).contains(status) { throw ContentError.signInRequired }
        try prepare(site)
        let text = String(decoding: data, as: UTF8.self)
        if Self.asksForSignIn(text) || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 64 { throw ContentError.signInRequired }
        return text
    }

    // MARK: Works

    func gallery(_ id: Int64, site: String) async throws -> NativeGallery {
        try prepare(site)
        guard id > 0 else { throw ContentError.invalidQuery }
        let key = try await key(for: id, site: site)
        let items = try await metadata([Link(id: id, key: key)], site: site)
        guard let item = items.first(where: { Self.number($0["gid"]) == id }), item["error"] == nil,
              let (preview, fileCount) = Self.work(from: item, site: site) else { throw ContentError.galleryNotFound }
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
        return NativeGallery(id: id, title: preview.title, artists: preview.artists, language: preview.language,
                             type: preview.type, tags: preview.tags, pages: pages)
    }

    /// The key comes from a link already seen, or from searching the number.
    func key(for id: Int64, site: String) async throws -> String {
        if let key = keys.key(for: id) { return key }
        guard var components = URLComponents(string: site) else { throw ContentError.invalidQuery }
        components.queryItems = [URLQueryItem(name: "f_search", value: "gid:\(id)")]
        guard let url = components.url else { throw ContentError.invalidQuery }
        let links = Self.links(in: try await page(url, site: site))
        keys.remember(links.map { ($0.id, $0.key) })
        guard let link = links.first(where: { $0.id == id }) else { throw ContentError.galleryNotFound }
        return link.key
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
        let entries = Self.entries(in: text, galleryID: id)
        guard !entries.isEmpty else { throw ContentError.galleryNotFound }
        let perPage = page == 0 ? entries.count : (details[id]?.perPage ?? entries.count)
        if details.count >= 64, let oldest = details.min(by: { $0.value.created < $1.value.created })?.key { details[oldest] = nil }
        let detail = Detail(perPage: max(1, perPage), entries: entries)
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
            do { return try await fetch(shown.url, galleryID: galleryID, limit: 24_000_000, site: site) }
            catch {
                try Task.checkCancellation()
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
        let (data, response) = try await transport.get(url, limit: limit, galleryID: galleryID)
        try prepare(site)
        guard response.mimeType?.hasPrefix("image/") != false, data.count > 32 else { throw ContentError.unsupportedFormat }
        return data
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
        var found: [Int64: NativeGallery] = [:]
        let missing = links.filter { link in
            if let cached = cachedPreview(link.id) { found[link.id] = cached; return false }
            return true
        }
        for start in stride(from: 0, to: missing.count, by: 25) {
            guard let items = try? await metadata(Array(missing[start..<min(missing.count, start + 25)]), site: site) else { continue }
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

    // MARK: Account favorites

    /// One page of the signed-in account's favorites, newest first.
    func favorites(after next: String?, site: String) async throws -> (ids: [Int64], next: String?) {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        guard var components = URLComponents(string: site + "favorites.php") else { throw ContentError.invalidQuery }
        if let next { components.queryItems = [URLQueryItem(name: "next", value: next)] }
        guard let url = components.url else { throw ContentError.invalidQuery }
        let text = try await page(url, site: site)
        let links = Self.links(in: text)
        keys.remember(links.map { ($0.id, $0.key) })
        _ = await previews(for: links, site: site)
        let cursor = Self.nextCursor(in: text)
        return (links.map(\.id), links.isEmpty || cursor == next ? nil : cursor)
    }

    func setFavorite(_ id: Int64, saved: Bool, site: String) async throws {
        try prepare(site)
        guard SiteAccount.isSignedIn else { throw ContentError.signInRequired }
        let key = try await key(for: id, site: site)
        guard var components = URLComponents(string: site + "gallerypopups.php") else { throw ContentError.invalidQuery }
        components.queryItems = [URLQueryItem(name: "gid", value: String(id)), URLQueryItem(name: "t", value: key), URLQueryItem(name: "act", value: "addfav")]
        guard let url = components.url else { throw ContentError.invalidQuery }
        let form = saved ? "favcat=0&favnote=&apply=Add+to+Favorites&update=1" : "favcat=favdel&favnote=&update=1"
        let (data, _) = try await transport.post(url, body: Data(form.utf8), contentType: "application/x-www-form-urlencoded", limit: 1_000_000)
        try prepare(site)
        if Self.asksForSignIn(String(decoding: data, as: UTF8.self)) { throw ContentError.signInRequired }
    }

    // MARK: Page shapes

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

    nonisolated static func nextCursor(in text: String) -> String? {
        guard let tag = text.range(of: #"<a\b[^>]*\bid="unext"[^>]*>"#, options: .regularExpression),
              let href = attribute("href", in: String(text[tag])),
              let value = URLComponents(string: decode(href))?.queryItems?.first(where: { $0.name == "next" })?.value,
              value.range(of: #"^[0-9A-Za-z_-]{1,40}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private nonisolated static let entryPattern = try! NSRegularExpression(
        pattern: #"<a\b[^>]*\bhref="[^"]*/s/([0-9a-f]{10})/([0-9]{1,10})-([0-9]{1,5})"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])

    /// Page links on a work's page, by zero-based page index, with each page's preview.
    nonisolated static func entries(in text: String, galleryID: Int64) -> [Int: Entry] {
        let source = text as NSString
        var result: [Int: Entry] = [:]
        for match in entryPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard Int64(source.substring(with: match.range(at: 2))) == galleryID,
                  let number = Int(source.substring(with: match.range(at: 3))), number >= 1 else { continue }
            let body = source.substring(with: match.range(at: 4))
            var name = String(number)
            if let title = attribute("title", in: body), let colon = title.range(of: ": ") { name = decode(String(title[colon.upperBound...])) }
            result[number - 1] = Entry(key: source.substring(with: match.range(at: 1)), name: name, thumb: thumb(in: body))
        }
        return result
    }

    private nonisolated static func thumb(in body: String) -> Thumb? {
        if let style = attribute("style", in: body),
           let size = style.range(of: #"width:\s*([0-9]+)px;\s*height:\s*([0-9]+)px"#, options: .regularExpression),
           let sheet = style.range(of: #"url\(([^)]+)\)\s*(-?[0-9]+)px"#, options: .regularExpression) {
            let numbers = String(style[size]).split { !$0.isNumber }.compactMap { Int($0) }
            let declaration = String(style[sheet])
            guard numbers.count == 2, let open = declaration.firstIndex(of: "("), let close = declaration.firstIndex(of: ")"),
                  let url = URL(string: decode(String(declaration[declaration.index(after: open)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")))),
                  let offset = Int(declaration[declaration.index(after: close)...].trimmingCharacters(in: .whitespaces).dropLast(2)),
                  safeMediaURL(url) else { return nil }
            return Thumb(url: url, crop: CGRect(x: -offset, y: 0, width: numbers[0], height: numbers[1]))
        }
        if let image = body.range(of: #"<img\b[^>]*>"#, options: .regularExpression),
           let value = attribute("src", in: String(body[image])), let url = URL(string: decode(value)), safeMediaURL(url) {
            return Thumb(url: url, crop: nil)
        }
        return nil
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
        return ShownImage(url: url, reload: reload)
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
        if categories != allCategories {
            let shown = categories.reduce(0) { $0 | (categoryBits[$1] ?? 0) }
            items.append(URLQueryItem(name: "f_cats", value: String(1023 & ~shown)))
        }
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
        let work = NativeGallery(id: id, title: NativeGallery.decodeEntities(title), artists: tags.filter { $0.0 == "artist" }.map(\.1),
                                 language: language, type: category == "asianporn" ? "photo" : category,
                                 tags: tags.filter { $0.0 != "language" && $0.0 != "artist" }.map { localNamespace($0.0) + ":" + $0.1 }, pages: pages)
        return (work, max(0, min(10_000, Int(number(item["filecount"]) ?? 0))))
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
