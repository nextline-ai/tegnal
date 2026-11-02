import Foundation

enum ContentError: LocalizedError {
    case invalidResponse, unsupportedFormat, tooLarge, unavailable(Int), invalidQuery, galleryNotFound, tooManySearchTerms(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L10n.text("Unable to read the response. Please try again shortly.")
        case .unsupportedFormat: return L10n.text("The service format has changed or this image is unsupported.")
        case .tooLarge: return L10n.text("The requested data is too large. Narrow your search.")
        case .galleryNotFound, .unavailable(404): return L10n.text("This work was removed or could not be found.")
        case .unavailable(403): return L10n.text("The image server declined the request. Try again shortly.")
        case .unavailable: return L10n.text("Unable to connect to the server. Try again shortly.")
        case .invalidQuery: return L10n.text("Check your search. Separate terms with spaces and join words within a tag with underscores.")
        case .tooManySearchTerms(let limit): return L10n.text("Use up to %@ search terms, including default and excluded tags.", String(limit))
        }
    }

    static var initialConnectionHelp: String {
        L10n.text("Depending on the website and network, a VPN or HTTPS bypass may help or block connections. If it’s on, turn it off; if it’s off, turn it on, then try again.")
    }

    static func withConnectionHelp(_ message: String, for error: Error) -> String {
        guard let error = error as? URLError else { return message }
        switch error.code {
        case .secureConnectionFailed, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return message + "\n\n" + initialConnectionHelp
        default: return message
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? ContentError { return error.localizedDescription }
        if let error = error as? URLError, error.code == .notConnectedToInternet {
            return L10n.text("Check your internet connection.")
        }
        return withConnectionHelp(L10n.text("Unable to load. Check your connection and try again."), for: error)
    }
}

struct GalleryPage: Codable, Sendable, Hashable {
    let hash: String
    let name: String
    let width: Int
    let height: Int
    let hasAVIF: Bool
    var imageURL: URL? = nil
    var thumbnailURL: URL? = nil
    var index: Int? = nil
    var sourceSite: String? = nil
}

/// One language of a work. Each language is a gallery with its own number.
struct GalleryVersion: Codable, Sendable, Hashable, Identifiable {
    let id: Int64
    let language: String
    let localName: String?
    var displayName: String { localName?.isEmpty == false ? localName! : language.capitalized }
}

struct NativeGallery: Codable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let artists: [String]
    let language: String
    let type: String
    let tags: [String]
    let pages: [GalleryPage]
    /// Optional so works downloaded before these were read still decode.
    var versions: [GalleryVersion]? = nil
    var relatedIDs: [Int64]? = nil

    /// The other languages of this work, with the given language first.
    func otherVersions(preferring language: String) -> [GalleryVersion] {
        let others = (versions ?? []).filter { $0.id != id }
        return others.filter { $0.language == language } + others.filter { $0.language != language }
    }

    /// The version to offer someone who wants this language, unless this already is it.
    func suggestedVersion(for language: String) -> GalleryVersion? {
        guard self.language.lowercased() != language.lowercased() else { return nil }
        return otherVersions(preferring: language).first { $0.language.lowercased() == language.lowercased() }
    }

    /// Default exclusions only reach searches, so works reached another way check them here.
    func isExcluded(by terms: String) -> Bool {
        func normal(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "_", with: " ") }
        let labels = Set((tags + artists.map { "artist:" + $0 } + ["language:" + language, "type:" + type]).map(normal))
        let names = Set(labels.compactMap { $0.split(separator: ":", maxSplits: 1).last.map(String.init) })
        return terms.split { $0.isWhitespace || $0 == "," }.contains { token in
            let term = normal(String(token.drop { $0 == "-" }))
            guard !term.isEmpty else { return false }
            return term.contains(":") ? labels.contains(term) : names.contains(term) || normal(title).contains(term)
        }
    }

    static func parse(_ data: Data, id: Int64) throws -> NativeGallery {
        try Task.checkCancellation()
        guard id > 0, data.count <= 4_000_000, var text = String(data: data, encoding: .utf8) else {
            throw ContentError.invalidResponse
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^var\s+galleryinfo\s*=\s*"#
        guard let match = text.range(of: prefix, options: .regularExpression) else { throw ContentError.unsupportedFormat }
        text.removeSubrange(match)
        if text.hasSuffix(";") { text.removeLast() }
        guard let jsonData = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let files = json["files"] as? [[String: Any]], !files.isEmpty, files.count <= 10_000 else {
            throw ContentError.invalidResponse
        }
        let pages = try files.enumerated().map { index, file -> GalleryPage in
            if index % 32 == 0 { try Task.checkCancellation() }
            guard let hash = file["hash"] as? String,
                  validPageHash(hash),
                  let name = file["name"] as? String, !name.isEmpty else { throw ContentError.unsupportedFormat }
            return GalleryPage(hash: hash, name: name,
                               width: (file["width"] as? NSNumber)?.intValue ?? 0,
                               height: (file["height"] as? NSNumber)?.intValue ?? 0,
                               hasAVIF: (file["hasavif"] as? NSNumber)?.boolValue ?? false, index: index, sourceSite: MangaUrls.home)
        }
        try Task.checkCancellation()
        let japanese = (json["japanese_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = japanese?.isEmpty == false ? japanese! : (json["title"] as? String ?? L10n.text("Work %@", String(describing: id)))
        return NativeGallery(id: id, title: decodeEntities(title),
                             artists: (json["artists"] as? [[String: Any]] ?? []).compactMap { $0["artist"] as? String },
                             language: json["language"] as? String ?? "", type: json["type"] as? String ?? "",
                             tags: Self.parseCredits(json) + Self.parseTags(json["tags"]), pages: pages,
                             versions: Self.parseVersions(json["languages"]), relatedIDs: Self.parseRelatedIDs(json["related"]))
    }

    static func parseVersions(_ value: Any?) -> [GalleryVersion] {
        var seen = Set<Int64>()
        return (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = galleryID(item["galleryid"]), let language = item["name"] as? String, !language.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return GalleryVersion(id: id, language: language, localName: item["language_localname"] as? String)
        }
    }

    static func parseRelatedIDs(_ value: Any?) -> [Int64] {
        var seen = Set<Int64>()
        return Array((value as? [Any] ?? []).compactMap { galleryID($0) }.filter { seen.insert($0).inserted }.prefix(12))
    }

    private static func galleryID(_ value: Any?) -> Int64? {
        let id = (value as? NSNumber)?.int64Value ?? (value as? String).flatMap { Int64($0) }
        return id.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func validPageHash(_ hash: String) -> Bool {
        let bytes = hash.utf8
        return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func parseTags(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).flatMap { item -> [String] in
            guard let tag = item["tag"] as? String else { return [] }
            let namespaces = ["female", "male"].filter { flag(item[$0]) }
            return (namespaces.isEmpty ? ["tag"] : namespaces).map { $0 + ":" + tag }
        }
    }

    /// Groups, series and characters come in their own lists, so they read as namespaced tags.
    static func parseCredits(_ json: [String: Any]) -> [String] {
        [("groups", "group", "group"), ("parodys", "parody", "series"), ("characters", "character", "character")].flatMap { list, key, namespace in
            (json[list] as? [[String: Any]] ?? []).compactMap { $0[key] as? String }.filter { !$0.isEmpty }.map { namespace + ":" + $0 }
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return ["1", "true"].contains((value as? String ?? "").lowercased())
    }

    private static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
    private static let entityRegex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        let source = input as NSString
        var result = input
        for match in entityRegex.matches(in: input, range: NSRange(location: 0, length: source.length)).reversed() {
            let token = source.substring(with: match.range(at: 1))
            var replacement = namedEntities[token]
            if token.hasPrefix("#") {
                let hex = token.hasPrefix("#x")
                if let code = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) {
                    replacement = String(scalar)
                }
            }
            if let replacement, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }
}

struct GalleryQuery: Hashable, Sendable {
    static let maximumSearchTerms = 64
    var language = "korean"
    var artist: String? = nil
    var text = ""
    var sort = GallerySort.latest
    var allowsLanguageExceptions = false

    func applyingDefaults(tags: String, excluded: String) -> Self {
        var result = self
        let explicit = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let includes = tags.split(whereSeparator: \.isWhitespace).map(String.init)
        let excludes = excluded.split(whereSeparator: \.isWhitespace).map { "-" + $0.drop(while: { $0 == "-" }) }
        var seen = Set<String>()
        result.text = (explicit + includes + excludes).filter { seen.insert($0).inserted }.joined(separator: " ")
        return result
    }
}

extension GalleryQuery {
    /// Narrows to one category unless the search already names one or the site lacks it.
    func filtered(to category: String) -> Self {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard GalleryCategory.available.contains(category), !terms.contains(where: { $0.hasPrefix("type:") }) else { return self }
        var result = self
        result.text = (terms + ["type:" + category]).joined(separator: " ")
        return result
    }
}

/// Work categories as the comics protocols name them.
enum GalleryCategory {
    private static let common = ["doujinshi", "manga", "artistcg", "gamecg", "imageset"]
    /// What the connected site can filter by. Until its protocol is known, only categories every protocol has.
    static var available: [String] {
        guard MangaUrls.hasResolvedBackend else { return common }
        return MangaUrls.backend == .document ? common + ["western", "non-h", "cosplay", "photo", "misc"] : common + ["anime"]
    }

    /// One spelling per category, whichever way a site or an imported catalog wrote it.
    static func key(_ type: String) -> String {
        type.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    static func title(_ type: String) -> String {
        switch key(type) {
        case "doujinshi": return L10n.text("Doujinshi")
        case "manga": return L10n.text("Manga")
        case "artistcg": return L10n.text("Artist CG")
        case "gamecg": return L10n.text("Game CG")
        case "imageset": return L10n.text("Image Set")
        case "anime": return L10n.text("Anime")
        case "western": return L10n.text("Western")
        case "non-h": return L10n.text("Non-H")
        case "cosplay": return L10n.text("Cosplay")
        case "photo": return L10n.text("Photo")
        case "misc": return L10n.text("Misc")
        case "private": return L10n.text("Private")
        default: return type.capitalized
        }
    }
}

/// Turns a work's related numbers into what is worth showing beside it.
enum RelatedWorks {
    static func load(for gallery: NativeGallery, source: any ContentProviding, hidden: Set<Int64>, excluded: String) async -> [Int64] {
        let related = gallery.relatedIDs ?? []
        let loaded = await withTaskGroup(of: (Int, NativeGallery?).self) { group in
            for (index, id) in related.enumerated() { group.addTask { (index, try? await source.gallery(id)) } }
            var results: [(Int, NativeGallery)] = []
            for await (index, work) in group { if let work { results.append((index, work)) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return select(loaded, for: gallery, hidden: hidden, excluded: excluded)
    }

    /// Keeps the site's order, drops other languages of works already shown,
    /// and prefers the language of the work being read.
    static func select(_ works: [NativeGallery], for gallery: NativeGallery, hidden: Set<Int64>, excluded: String) -> [Int64] {
        var seen = Set([gallery.id] + (gallery.versions ?? []).map(\.id))
        return works.compactMap { work in
            let family = Set([work.id] + (work.versions ?? []).map(\.id))
            guard seen.isDisjoint(with: family), !work.isExcluded(by: excluded) else { return nil }
            seen.formUnion(family)
            let shown = work.suggestedVersion(for: gallery.language)?.id ?? work.id
            return hidden.contains(work.id) || hidden.contains(shown) ? nil : shown
        }
    }
}

enum GallerySort: String, CaseIterable, Identifiable, Sendable {
    case latest, today, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .latest: return L10n.text("Latest")
        case .today: return L10n.text("Popular Today")
        case .week: return L10n.text("Popular This Week")
        case .month: return L10n.text("Popular This Month")
        case .year: return L10n.text("Popular This Year")
        }
    }
}

/// Artists open in every language until a person picks one, and that choice stays.
enum ArtistBrowsing {
    static let preferenceKey = "manga.artistLanguage"
    static var language: String {
        get { ReaderPreferences.defaults.string(forKey: preferenceKey) ?? "all" }
        set { ReaderPreferences.defaults.set(newValue, forKey: preferenceKey) }
    }
    static func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.count == 1 && terms[0].lowercased().hasPrefix("artist:")
    }
}

struct GalleryBatch: Sendable {
    let ids: [Int64]
    let hasMore: Bool
}

protocol ContentProviding: Sendable {
    func suggestions(for token: String) async throws -> [TagSuggestion]
    func gallery(_ id: Int64) async throws -> NativeGallery
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data
    func cachedGallery(_ id: Int64) -> NativeGallery?
    func cachedPreview(_ id: Int64) -> NativeGallery?
}

extension ContentProviding {
    func cachedGallery(_ id: Int64) -> NativeGallery? { nil }
    func cachedPreview(_ id: Int64) -> NativeGallery? { cachedGallery(id) }
}

enum ContentRoute: Hashable {
    case discoveredGallery(Int64, DiscoveryContext)
    case discoveredReader(Int64, Int, DiscoveryContext)
    case gallery(Int64)
    case reader(Int64, Int)
    case artist(String)
    case query(String)

    /// Rebuild saved native links after the configured server's protocol is known.
    static func configuredURL(_ url: URL) -> URL {
        let address: String
        switch initial(url.absoluteString) {
        case .reader(let id, let page): address = MangaUrls.readerUrl(for: id, page: page)
        case .gallery(let id): address = MangaUrls.galleryUrl(for: id)
        case .artist(let name): address = MangaUrls.artistAllUrl(for: name)
        default: return url
        }
        return URL(string: address) ?? url
    }

    static func initial(_ raw: String) -> ContentRoute? {
        guard let url = URL(string: raw), url.scheme == "https",
              !MangaUrls.configuredHost.isEmpty, url.host?.lowercased() == MangaUrls.configuredHost else { return nil }
        if let id = GalleryIDParser.parse(raw).first {
            if url.path.hasPrefix("/reader/") || (url.path.hasPrefix("/r/") && url.fragment != nil) {
                return .reader(id, max(1, Int(url.fragment ?? "1") ?? 1))
            }
            return .gallery(id)
        }
        if let search = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "search" })?.value,
           !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .query(search)
        }
        if url.path.hasPrefix("/artist/"), url.lastPathComponent.hasSuffix("-all.html") {
            return .artist(String(url.lastPathComponent.dropLast("-all.html".count)))
        }
        return nil
    }
}


extension ContentProviding {
    func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
}

struct TagSuggestion: Identifiable, Equatable, Sendable {
    let namespace: String
    let name: String
    let count: Int?
    var id: String { token }
    var token: String { namespace + ":" + name.replacingOccurrences(of: " ", with: "_") }
    static let namespaces: Set<String> = ["female", "male", "tag", "artist", "group", "series", "character", "language", "type"]
    static func parse(_ data: Data) throws -> [Self] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]], rows.count <= 100 else { throw ContentError.invalidResponse }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row.count == 3, let name = row[0] as? String, !name.isEmpty, name.count <= 120,
                  name.rangeOfCharacter(from: .newlines) == nil,
                  let count = row[1] as? Int, count >= 0, let namespace = row[2] as? String,
                  namespaces.contains(namespace) else { return nil }
            let item = Self(namespace: namespace, name: name, count: count)
            return seen.insert(item.id).inserted ? item : nil
        }
    }
}

struct TagCompletionContext: Equatable {
    let prefix: String
    let excluded: Bool
    let token: String
    init?(_ input: String) {
        guard !input.isEmpty, input.last?.isWhitespace == false,
              let tail = input.split(whereSeparator: \.isWhitespace).last else { return nil }
        prefix = String(input.dropLast(tail.count))
        excluded = tail.hasPrefix("-")
        token = String(excluded ? tail.dropFirst() : tail[...]).lowercased()
        let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count <= 2, token.count <= 120,
              pieces.count == 1 || TagSuggestion.namespaces.contains(String(pieces[0])),
              let term = pieces.last, term.count >= 2, term.count <= 64,
              !term.allSatisfy({ $0.isNumber }), !term.contains("/"), !term.contains("\"") else { return nil }
    }
    func inserting(_ suggestion: TagSuggestion) -> String { prefix + (excluded ? "-" : "") + suggestion.token + " " }
}
