import Foundation
import CryptoKit

/// A numeric catalog with JSON search results and an embedded page manifest.
/// Only endpoint shapes and response fields identify this protocol.
actor DocumentCatalogSource {
    private let transport: ContentTransport
    private var site = ""
    private struct ResultRow {
        let id: Int64
        let views: Int64
    }
    private struct FilterLane {
        let visual: Bool
        var pending: [ResultRow] = []
        var nextID: Int64?
        var nextViews: Int64?
        var more = true
    }
    private static let visualCategories: Set<Int> = [3, 4, 6]
    private struct Feed {
        var lanes: [FilterLane] = []
        var ids: [Int64] = []
        var nextID: Int64?
        var nextViews: Int64?
        var more = true
        var started = false
        let offset: Int
        let created = Date()
    }
    private var feeds: [GalleryQuery: Feed] = [:]
    private var documents: [Int64: (NativeGallery, Date)] = [:]
    private final class Preview {
        let gallery: NativeGallery
        init(_ gallery: NativeGallery) { self.gallery = gallery }
    }
    private nonisolated(unsafe) let previews = NSCache<NSString, Preview>()

    init(transport: ContentTransport) {
        self.transport = transport
        previews.countLimit = 512
    }

    nonisolated func cachedPreview(_ id: Int64) -> NativeGallery? {
        previews.object(forKey: "\(MangaUrls.home)#\(id)" as NSString)?.gallery
    }

    private func prepare(_ requestedSite: String) throws {
        guard requestedSite == MangaUrls.home else { throw CancellationError() }
        if site != requestedSite {
            site = requestedSite
            feeds.removeAll(); documents.removeAll(); previews.removeAllObjects()
        }
    }

    func gallery(_ id: Int64, site: String, force: Bool = false) async throws -> NativeGallery {
        try prepare(site)
        if !force, let cached = documents[id], Date().timeIntervalSince(cached.1) < 180 { return cached.0 }
        guard id > 0, let url = URL(string: "\(site)r/\(id)") else { throw ContentError.invalidQuery }
        let (data, _) = try await transport.get(url, limit: 4_000_000)
        try Task.checkCancellation()
        try prepare(site)
        let gallery = try Self.parseGallery(data, id: id, site: site)
        MangaUrls.registerMedia(gallery.pages.flatMap { [$0.imageURL, $0.thumbnailURL].compactMap { $0 } }, site: site)
        if documents.count >= 128, let oldest = documents.min(by: { $0.value.1 < $1.value.1 })?.key { documents[oldest] = nil }
        documents[id] = (gallery, Date())
        previews.setObject(Preview(gallery), forKey: "\(site)#\(id)" as NSString)
        return gallery
    }

    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool, site: String) async throws -> Data {
        try prepare(site)
        var current = page
        if let cached = documents[galleryID]?.0, let index = page.index, cached.pages.indices.contains(index) {
            current = cached.pages[index]
        }
        for attempt in 0..<2 {
            // A missing thumbnail must never silently download a reader-sized image.
            let candidate = thumbnail ? current.thumbnailURL : current.imageURL
            if attempt > 0 || current.sourceSite != site || candidate.map(Self.expired) != false {
                let document = try await gallery(galleryID, site: site, force: true)
                guard let index = page.index, document.pages.indices.contains(index) else { throw ContentError.invalidResponse }
                current = document.pages[index]
            }
            guard let url = thumbnail ? current.thumbnailURL : current.imageURL else { throw ContentError.invalidResponse }
            do {
                let (data, response) = try await transport.get(url, limit: thumbnail ? 2_000_000 : 24_000_000, galleryID: galleryID)
                try prepare(site)
                guard response.mimeType?.hasPrefix("image/") == true, data.count > 32 else { throw ContentError.unsupportedFormat }
                return data
            } catch ContentError.unavailable(let status) where attempt == 0 && [403, 404, 410].contains(status) {
                continue
            }
        }
        throw ContentError.invalidResponse
    }

    func list(_ query: GalleryQuery, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        try prepare(site)
        if query.language != "all", query.allowsLanguageExceptions { return try await listIncludingVisualCollections(query, offset: offset, count: count, site: site) }
        var feed = feeds[query] ?? Feed(offset: offset)
        if offset < feed.offset || offset > feed.offset + feed.ids.count || Date().timeIntervalSince(feed.created) > 300 {
            feed = Feed(offset: offset)
        }
        let target = offset - feed.offset + count
        var requests = 0
        while feed.ids.count < target && feed.more {
            try Task.checkCancellation()
            guard requests < 4 else { throw ContentError.invalidResponse }
            let url = try Self.searchURL(query, site: site, offset: feed.started ? nil : offset,
                                         nextID: feed.nextID, nextViews: feed.nextViews)
            let (data, _) = try await transport.get(url, limit: 2_000_000)
            try prepare(site)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 100 else { throw ContentError.invalidResponse }
            let oldCursor = feed.nextID
            var seen = Set(feed.ids)
            for row in rows {
                guard let id = (row["id"] as? NSNumber)?.int64Value, id > 0 else { throw ContentError.invalidResponse }
                guard (row["blocked"] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
                if seen.insert(id).inserted { feed.ids.append(id) }
                if let preview = Self.preview(row, site: site) {
                    previews.setObject(Preview(preview), forKey: "\(site)#\(id)" as NSString)
                }
            }
            feed.nextID = (rows.last?["id"] as? NSNumber)?.int64Value
            feed.nextViews = query.sort == .latest ? nil : (rows.last?["views"] as? NSNumber)?.int64Value
            feed.more = rows.count == 50 && feed.nextID != oldCursor
            feed.started = true
            requests += 1
        }
        try prepare(site)
        if feeds.count >= 16, feeds[query] == nil, let oldest = feeds.min(by: { $0.value.created < $1.value.created })?.key { feeds[oldest] = nil }
        feeds[query] = feed
        let start = offset - feed.offset
        return GalleryBatch(ids: Array(feed.ids.dropFirst(start).prefix(count)), hasMore: feed.more || feed.ids.count > start + count)
    }

    private func listIncludingVisualCollections(_ query: GalleryQuery, offset: Int, count: Int, site: String) async throws -> GalleryBatch {
        var feed = feeds[query] ?? Feed(offset: 0)
        if offset < feed.offset || Date().timeIntervalSince(feed.created) > 300 { feed = Feed(offset: 0) }
        if feed.lanes.isEmpty { feed.lanes = [FilterLane(visual: false), FilterLane(visual: true)] }
        let target = offset + count
        let selected = try Self.selectedCategories(query)
        var seen = Set(feed.ids), requests = 0
        while feed.ids.count < target {
            for index in feed.lanes.indices where feed.lanes[index].pending.isEmpty && feed.lanes[index].more {
                let categories = feed.lanes[index].visual ? selected.intersection(Self.visualCategories) : selected.subtracting(Self.visualCategories)
                if categories.isEmpty { feed.lanes[index].more = false; continue }
                guard requests < 20 else { break }
                var remote = query
                if feed.lanes[index].visual { remote.language = "all" }
                let oldCursor = feed.lanes[index].nextID
                let url = try Self.searchURL(remote, site: site, nextID: oldCursor, nextViews: feed.lanes[index].nextViews, restrictCategories: categories)
                let (data, _) = try await transport.get(url, limit: 2_000_000)
                try prepare(site)
                guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 100 else { throw ContentError.invalidResponse }
                for row in rows {
                    guard let id = (row["id"] as? NSNumber)?.int64Value, id > 0 else { throw ContentError.invalidResponse }
                    guard (row["blocked"] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
                    let category = (row["category"] as? NSNumber)?.intValue ?? 0
                    guard categories.contains(category) else { continue }
                    feed.lanes[index].pending.append(.init(id: id, views: (row["views"] as? NSNumber)?.int64Value ?? 0))
                    if let preview = Self.preview(row, site: site) { previews.setObject(Preview(preview), forKey: "\(site)#\(id)" as NSString) }
                }
                feed.lanes[index].nextID = (rows.last?["id"] as? NSNumber)?.int64Value
                feed.lanes[index].nextViews = query.sort == .latest ? nil : (rows.last?["views"] as? NSNumber)?.int64Value
                feed.lanes[index].more = rows.count == 50 && feed.lanes[index].nextID != oldCursor
                requests += 1
            }
            // A lane must have a head or be exhausted before merging the next rank.
            if feed.lanes.contains(where: { $0.pending.isEmpty && $0.more }) {
                if requests >= 20 { break }
                continue
            }
            let available = feed.lanes.indices.filter { !feed.lanes[$0].pending.isEmpty }
            guard let selected = available.max(by: { a, b in
                let first = feed.lanes[a].pending[0], second = feed.lanes[b].pending[0]
                return query.sort == .latest || first.views == second.views ? first.id < second.id : first.views < second.views
            }) else { break }
            let next = feed.lanes[selected].pending.removeFirst()
            if seen.insert(next.id).inserted { feed.ids.append(next.id) }
        }
        try prepare(site)
        feed.more = feed.lanes.contains { $0.more || !$0.pending.isEmpty }
        if feeds.count >= 16, feeds[query] == nil, let oldest = feeds.min(by: { $0.value.created < $1.value.created })?.key { feeds[oldest] = nil }
        feeds[query] = feed
        return .init(ids: Array(feed.ids.dropFirst(offset).prefix(count)), hasMore: feed.more || feed.ids.count > target)
    }

    func suggestions(_ token: String, site: String) async throws -> [TagSuggestion] {
        try prepare(site)
        guard let context = TagCompletionContext(token) else { return [] }
        var components = URLComponents(string: site + "ajax/search-tags")!
        components.queryItems = [URLQueryItem(name: "search", value: Self.remoteTerm(context.token))]
        let (data, _) = try await transport.get(components.url!, limit: 64_000)
        try prepare(site)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [String], values.count <= 100 else { throw ContentError.invalidResponse }
        return values.compactMap { value in
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let namespace = Self.localNamespace(parts[0])
            guard TagSuggestion.namespaces.contains(namespace) else { return nil }
            return TagSuggestion(namespace: namespace, name: parts[1], count: nil)
        }
    }

    nonisolated static func searchURL(_ query: GalleryQuery, site: String, offset: Int? = nil,
                                      nextID: Int64? = nil, nextViews: Int64? = nil, now: Date = .now, restrictCategories: Set<Int>? = nil) throws -> URL {
        guard var components = URLComponents(string: site + "ajax/search") else { throw ContentError.invalidQuery }
        var terms = query.text.split(whereSeparator: \.isWhitespace).map { remoteTerm(String($0)) }
        if query.language != "all" { terms.append("language:" + query.language) }
        if let artist = query.artist { terms.append("artist:" + artist.replacingOccurrences(of: " ", with: "_")) }
        var categories = try selectedCategories(query)
        if let restrictCategories { categories.formIntersection(restrictCategories) }
        terms.removeAll { $0.hasPrefix("type:") || $0.hasPrefix("-type:") }
        var items = [URLQueryItem(name: "search", value: terms.joined(separator: " ")),
                     URLQueryItem(name: "sort", value: query.sort == .latest ? "id_desc" : "popular")]
        if categories.count != 11 { items.append(.init(name: "categories", value: categories.sorted().map(String.init).joined(separator: ","))) }
        if query.sort != .latest {
            let days = query.sort == .today ? 1 : query.sort == .week ? 7 : query.sort == .month ? 30 : 365
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            items.append(.init(name: "start-date", value: formatter.string(from: now.addingTimeInterval(-Double(days) * 86400))))
        }
        if let nextID {
            items.append(.init(name: nextViews == nil ? "next-id" : "next-views-id", value: String(nextID)))
            if let nextViews { items.append(.init(name: "next-views", value: String(nextViews))) }
        } else if let offset, offset > 0 {
            guard offset <= 5000 else { throw ContentError.invalidQuery }
            items.append(.init(name: "offset", value: String(offset)))
        }
        components.queryItems = items
        guard let url = components.url else { throw ContentError.invalidQuery }
        return url
    }

    private nonisolated static func selectedCategories(_ query: GalleryQuery) throws -> Set<Int> {
        let terms = query.text.split(whereSeparator: \.isWhitespace).map(String.init)
        var categories = terms.contains(where: { $0.hasPrefix("type:") }) ? Set<Int>() : Set(1...11)
        for term in terms where term.hasPrefix("type:") || term.hasPrefix("-type:") {
            let name = String(term.split(separator: ":", maxSplits: 1).last ?? "")
            guard let category = categoryNames.first(where: { $0.value == name })?.key else { throw ContentError.invalidQuery }
            if term.hasPrefix("-") { categories.remove(category) } else { categories.insert(category) }
        }
        return categories
    }

    nonisolated static func parseGallery(_ data: Data, id: Int64, site: String) throws -> NativeGallery {
        let object = try embeddedObject(data, named: "gallery")
        guard (object["id"] as? NSNumber)?.int64Value == id,
              let files = object["files"] as? [[String: Any]], !files.isEmpty, files.count <= 10_000 else { throw ContentError.invalidResponse }
        guard (object["blocked"] as? NSNumber)?.intValue ?? 0 == 0 else { throw ContentError.unavailable(403) }
        let pages = try files.enumerated().map { index, file -> GalleryPage in
            try Task.checkCancellation()
            guard let image = file["image"] as? [String: Any], let value = image["url"] as? String,
                  let url = URL(string: value), safeMediaURL(url), let name = file["name"] as? String else { throw ContentError.unsupportedFormat }
            let preview = (file["thumbnail"] as? [String: Any])?["url"] as? String
            let thumbnail = preview.flatMap(URL.init(string:)).flatMap { safeMediaURL($0) ? $0 : nil }
            let identity = file["id"] as? String ?? "\(id):\(index):\(name)"
            let hash = SHA256.hash(data: Data((site + "#" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
            return GalleryPage(hash: hash, name: name, width: (image["width"] as? NSNumber)?.intValue ?? 0,
                               height: (image["height"] as? NSNumber)?.intValue ?? 0, hasAVIF: false,
                               imageURL: url, thumbnailURL: thumbnail, index: index, sourceSite: site)
        }
        return metadata(object, id: id, pages: pages)
    }

    /// Extract one JSON object, respecting quoted braces and escaped quotes.
    nonisolated static func embeddedObject(_ data: Data, named name: String) throws -> [String: Any] {
        guard data.count <= 4_000_000, let text = String(data: data, encoding: .utf8),
              let assignment = text.range(of: #"\b(?:const|let|var)\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*\{"#, options: .regularExpression) else { throw ContentError.unsupportedFormat }
        let start = text.index(before: assignment.upperBound)
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    guard let json = String(text[start...index]).data(using: .utf8),
                          let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ContentError.invalidResponse }
                    return object
                }
            }
        }
        throw ContentError.invalidResponse
    }

    private nonisolated static func preview(_ object: [String: Any], site: String) -> NativeGallery? {
        guard let id = (object["id"] as? NSNumber)?.int64Value, id > 0,
              let base = MangaUrls.preferences.string(forKey: "manga.resolved_preview_base"),
              let ext = object["thumb_extension"] as? String, ["jpg", "jpeg", "png", "webp", "avif"].contains(ext),
              let url = URL(string: "\(base)/\(id / 1_000_000)/\((id % 1_000_000) / 1000)/\(id % 1000).\(ext)"), safeMediaURL(url) else { return nil }
        let hash = SHA256.hash(data: Data((site + "#preview:\(id)").utf8)).map { String(format: "%02x", $0) }.joined()
        let page = GalleryPage(hash: hash, name: "preview", width: 0, height: 0, hasAVIF: false,
                               imageURL: url, thumbnailURL: url, index: 0, sourceSite: site)
        return metadata(object, id: id, pages: [page])
    }

    private nonisolated static let categoryNames = [1: "doujinshi", 2: "manga", 3: "artistcg", 4: "gamecg", 5: "western",
                                                   6: "imageset", 7: "non-h", 8: "cosplay", 9: "photo", 10: "misc", 11: "private"]

    private nonisolated static func metadata(_ object: [String: Any], id: Int64, pages: [GalleryPage]) -> NativeGallery {
        let pairs = (object["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? [String] }.filter { $0.count == 2 }
        let japanese = (object["title_jpn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = japanese?.isEmpty == false ? japanese! : object["title"] as? String ?? "\(id)"
        let category = (object["category"] as? NSNumber)?.intValue ?? 0
        return NativeGallery(id: id, title: NativeGallery.decodeEntities(title), artists: pairs.filter { $0[0] == "artist" }.map { $0[1] },
            language: pairs.first { $0[0] == "language" }?[1] ?? "", type: categoryNames[category] ?? "",
            tags: pairs.filter { $0[0] != "language" && $0[0] != "artist" }.map { localNamespace($0[0]) + ":" + $0[1] }, pages: pages)
    }

    nonisolated static func safeMediaURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal") else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 { return false }
        return true
    }

    private nonisolated static func expired(_ url: URL) -> Bool {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "expires" })?.value,
              let timestamp = Double(value) else { return false }
        return timestamp < Date().timeIntervalSince1970 + 30
    }
    private nonisolated static func localNamespace(_ namespace: String) -> String {
        namespace == "parody" ? "series" : namespace == "other" ? "tag" : namespace
    }
    private nonisolated static func remoteTerm(_ term: String) -> String {
        let negative = term.hasPrefix("-") ? "-" : ""
        let value = term.hasPrefix("-") ? String(term.dropFirst()) : term
        if value.hasPrefix("series:") { return negative + "parody:" + value.dropFirst(7) }
        if value.hasPrefix("tag:") { return negative + "other:" + value.dropFirst(4) }
        return term
    }
}
