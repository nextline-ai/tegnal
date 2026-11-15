import Foundation

/// A comment under a work on a catalog that keeps them.
struct WorkComment: Identifiable, Hashable, Sendable {
    let id: Int
    let author: String
    let posted: Date?
    let score: Int?
    let text: String
    /// The uploader's own note, shown first and never scored.
    var isUploader: Bool { id == 0 }
}

/// A torrent a catalog offers for a work.
struct WorkTorrent: Identifiable, Hashable, Sendable {
    var id: String { url.absoluteString }
    let name: String
    let url: URL
    let size: String?
    let seeds: Int?
    let peers: Int?
    let downloads: Int?
    let posted: String?
    let uploader: String?
    let hash: String?
    var magnet: URL? {
        guard let hash else { return nil }
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [URLQueryItem(name: "xt", value: "urn:btih:" + hash), URLQueryItem(name: "dn", value: name)]
        return components.url
    }
}

/// What a work's page on an account-based catalog says besides its pages: how it is rated, how
/// often it is kept, who uploaded it, and the conversation under it.
struct WorkExtras: Hashable, Sendable {
    var rating: Double?
    var ratingCount: Int?
    var favorited: Int?
    var posted: Date?
    var uploader: String?
    var fileSize: String?
    var length: Int?
    var parentID: Int64?
    /// The account's favorites category holding this work, from 0, when it is a favorite.
    var favoriteCategory: Int?
    var favoriteName: String?
    var torrentCount = 0
    var torrentsURL: URL?
    var comments: [WorkComment] = []
    /// The page shows only the newest comments until asked for all of them.
    var hasMoreComments = false
    /// The signed-in account's key for rating, kept only in memory.
    var canRate = false
}

/// Reads the shapes these pages share. Only page structure is matched, never a site's name.
enum KeyedWorkPage {
    struct APIKey: Hashable, Sendable {
        let uid: Int
        let key: String
    }

    static func extras(from html: String) -> WorkExtras {
        var extras = WorkExtras()
        for (label, value) in detailRows(html) {
            let text = plain(value)
            switch label.lowercased() {
            case "posted": extras.posted = postedDate(text)
            case "parent": extras.parentID = firstCapture(#"/g/([0-9]{1,10})/"#, in: value).flatMap { Int64($0) }
            case "file size": extras.fileSize = text.isEmpty ? nil : text
            case "length": extras.length = firstCapture(#"([0-9][0-9,]*)"#, in: text).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
            case "favorited": extras.favorited = favoritedCount(text)
            default: break
            }
        }
        if let label = firstCapture(#"id="rating_label"[^>]*>([^<]*)<"#, in: html),
           let value = firstCapture(#"([0-9]+(?:\.[0-9]+)?)"#, in: label), let rating = Double(value), (0...5).contains(rating) {
            extras.rating = rating
        }
        if let count = firstCapture(#"id="rating_count"[^>]*>([0-9,]+)<"#, in: html) {
            extras.ratingCount = Int(count.replacingOccurrences(of: ",", with: ""))
        }
        if let uploader = firstCapture(#"<div id="gdn"[^>]*>(.*?)</div>"#, in: html) {
            let name = plain(uploader)
            extras.uploader = name.isEmpty ? nil : name
        }
        if let count = firstCapture(#">\s*Torrent Download\s*\(\s*([0-9]+)\s*\)"#, in: html) { extras.torrentCount = Int(count) ?? 0 }
        if let address = firstCapture(#"['"]([^'"]*gallerytorrents\.php\?[^'"]*)['"]"#, in: html) {
            extras.torrentsURL = URL(string: NativeGallery.decodeEntities(address))
        }
        let favorite = favoriteState(html)
        extras.favoriteCategory = favorite.category
        extras.favoriteName = favorite.name
        extras.comments = comments(from: html)
        extras.hasMoreComments = html.range(of: #"[?&]hc=1"#, options: .regularExpression) != nil
        extras.canRate = apiKey(in: html) != nil
        return extras
    }

    /// The signed-in account's id and key the page hands its own scripts for rating.
    static func apiKey(in html: String) -> APIKey? {
        guard let uid = firstCapture(#"\bvar\s+apiuid\s*=\s*([0-9]{1,12})\s*;"#, in: html).flatMap(Int.init), uid > 0,
              let key = firstCapture(#"\bvar\s+apikey\s*=\s*"([0-9a-f]{8,64})"\s*;"#, in: html) else { return nil }
        return APIKey(uid: uid, key: key)
    }

    /// The favorites category shown on the page: its number from the icon, and its name from the link.
    static func favoriteState(_ html: String) -> (category: Int?, name: String?) {
        guard let link = firstCapture(#"<a\b[^>]*\bid="favoritelink"[^>]*>(.*?)</a>"#, in: html) else { return (nil, nil) }
        let name = plain(link)
        guard let block = firstCapture(#"<div id="fav"[^>]*>(.*?)</div>\s*</div>"#, in: html) ?? firstCapture(#"<div id="fav"[^>]*>(.*?)</div>"#, in: html),
              let offset = firstCapture(#"background-position\s*:\s*0(?:px)?\s+-([0-9]+)px"#, in: block).flatMap(Int.init),
              offset >= 2, (offset - 2) % 19 == 0, (offset - 2) / 19 <= 9 else { return (nil, nil) }
        return ((offset - 2) / 19, name.isEmpty ? nil : name)
    }

    static func comments(from html: String) -> [WorkComment] {
        let blocks = html.components(separatedBy: #"<div class="c1">"#).dropFirst()
        var result: [WorkComment] = []
        var seen = Set<Int>()
        for block in blocks {
            guard let idText = firstCapture(#"<div class="c6"[^>]*\bid="comment_([0-9]{1,10})""#, in: block), let id = Int(idText),
                  seen.insert(id).inserted,
                  let body = firstCapture(#"<div class="c6"[^>]*>(.*?)</div>"#, in: block) else { continue }
            let header = firstCapture(#"<div class="c3"[^>]*>(.*?)</div>"#, in: block) ?? ""
            let author = firstCapture(#"<a\b[^>]*>([^<]+)</a>"#, in: header).map { plain($0) }
                ?? plain(header.components(separatedBy: "by:").last ?? "")
            let posted = firstCapture(#"Posted on\s+(.+?)\s+by"#, in: plain(header)).flatMap(commentDate)
            let score = firstCapture(#"id="comment_score_[0-9]+"[^>]*>\s*([+-]?[0-9]+)\s*<"#, in: block).flatMap { Int($0.replacingOccurrences(of: "+", with: "")) }
            let text = plain(body, keepsLines: true)
            guard !text.isEmpty else { continue }
            result.append(WorkComment(id: id, author: author.isEmpty ? "?" : author, posted: posted, score: id == 0 ? nil : score, text: text))
        }
        return result
    }

    static func torrents(from html: String) -> [WorkTorrent] {
        let forms = html.components(separatedBy: "<form").dropFirst()
        var result: [WorkTorrent] = []
        var seen = Set<String>()
        for form in forms {
            guard let match = firstMatch(#"<a\b[^>]*\bhref="([^"]+\.torrent[^"]*)"[^>]*>([^<]+)</a>"#, in: form),
                  let url = URL(string: NativeGallery.decodeEntities(match[0])), url.scheme == "https",
                  seen.insert(url.absoluteString).inserted else { continue }
            func field(_ name: String) -> String? {
                firstCapture(name + #":\s*</span>\s*(?:<span[^>]*>)?\s*([^<]+?)\s*<"#, in: form).map { plain($0) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let hash = firstCapture(#"([0-9a-fA-F]{40})"#, in: url.path)?.lowercased()
            result.append(WorkTorrent(name: plain(match[1]), url: url, size: field("Size"),
                                      seeds: field("Seeds").flatMap { Int($0) }, peers: field("Peers").flatMap { Int($0) },
                                      downloads: field("Downloads").flatMap { Int($0) }, posted: field("Posted"),
                                      uploader: field("Uploader"), hash: hash))
        }
        return result
    }

    // MARK: Helpers

    private static func detailRows(_ html: String) -> [(String, String)] {
        guard let regex = try? NSRegularExpression(pattern: #"<td class="gdt1"[^>]*>\s*([^<:]+?)\s*:\s*</td>\s*<td class="gdt2"[^>]*>(.*?)</td>"#,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length)).map {
            (source.substring(with: $0.range(at: 1)), source.substring(with: $0.range(at: 2)))
        }
    }

    private static func favoritedCount(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("never") { return 0 }
        if lowered.hasPrefix("once") { return 1 }
        return firstCapture(#"([0-9][0-9,]*)"#, in: text).flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
    }

    private static let utc = TimeZone(identifier: "UTC")!

    static func postedDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func commentDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        let value = text.replacingOccurrences(of: " UTC", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        for format in ["dd MMMM yyyy, HH:mm", "d MMMM yyyy, HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Text without markup; line breaks stay when asked, other whitespace runs fold to one space.
    static func plain(_ html: String, keepsLines: Bool = false) -> String {
        var text = html
        if keepsLines { text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]) }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = NativeGallery.decodeEntities(text).replacingOccurrences(of: "\u{00A0}", with: " ")
        if keepsLines {
            return text.components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text of each innermost `div`, in order.
    static func texts(inDivs html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<div\b[^>]*>([^<]*)</div>"#, options: [.caseInsensitive]) else { return [] }
        let source = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: source.length)).map { plain(source.substring(with: $0.range(at: 1))) }
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? { firstMatch(pattern, in: text)?.first }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }
}

/// One of the account's favorites categories on a catalog that keeps them.
struct FavoriteCategory: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let count: Int
}

/// Catalogs that keep ratings, comments and torrents for their works.
protocol WorkExtrasProviding: Sendable {
    /// Nil when the website keeps none of this for its works.
    func extras(_ id: Int64) async throws -> WorkExtras?
    func allComments(_ id: Int64) async throws -> [WorkComment]
    func torrents(_ id: Int64) async throws -> [WorkTorrent]
    /// Rates a work from 1 to 10 half-stars; returns the new average and count.
    func rate(_ id: Int64, halfStars: Int) async throws -> (average: Double, count: Int)
}
