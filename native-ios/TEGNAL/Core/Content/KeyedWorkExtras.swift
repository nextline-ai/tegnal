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

/// A work's tag on an account-based catalog, as the website spells it, with the account's vote.
struct WorkTagVote: Identifiable, Hashable, Sendable {
    /// `namespace:name` as the website writes it, with spaces.
    let tag: String
    /// 1 voted up, -1 voted down, 0 not voted.
    var vote: Int
    var id: String { tag }
    var namespace: String { tag.split(separator: ":", maxSplits: 1).count == 2 ? String(tag.split(separator: ":", maxSplits: 1)[0]) : "" }
    var name: String { String(tag.split(separator: ":", maxSplits: 1).last ?? "") }
    /// The namespace as the app's searches write it.
    var localNamespace: String { namespace == "parody" ? "series" : namespace == "other" ? "tag" : namespace }
}

/// What an account-based catalog asks for a work's archive, and what the account holds.
struct WorkArchiveOffer: Hashable, Sendable {
    struct Option: Identifiable, Hashable, Sendable {
        /// The website's name for the kind of archive: the original files or resized ones.
        let kind: String
        /// The label of the website's own button, sent back with the request.
        let button: String
        let cost: String
        let size: String
        let available: Bool
        var id: String { kind }
        var isOriginal: Bool { kind == "org" }
    }
    var funds: String?
    var options: [Option] = []
}

/// One of the account's settings profiles on a website that keeps several.
struct SiteSettingsProfile: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let selected: Bool
}

/// An answer the website gave in its own words, shown as it is.
struct SiteMessage: LocalizedError, Equatable, Sendable {
    let text: String
    var errorDescription: String? { text }
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
    var comments: [WorkComment] = []
    /// The page shows only the newest comments until asked for all of them.
    var hasMoreComments = false
    /// The signed-in account's key for rating, kept only in memory.
    var canRate = false
    /// The work's tags with the account's votes, when the page lets the account vote.
    var tagVotes: [WorkTagVote] = []
    /// Whether the page offers the account a comment form.
    var canComment = false
    /// The work's archive page, when the page links one.
    var archiveURL: URL?
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
        let favorite = favoriteState(html)
        extras.favoriteCategory = favorite.category
        extras.favoriteName = favorite.name
        extras.comments = comments(from: html)
        extras.hasMoreComments = html.range(of: #"[?&]hc=1"#, options: .regularExpression) != nil
        extras.canRate = apiKey(in: html) != nil
        extras.tagVotes = tagVotes(from: html)
        extras.canComment = html.range(of: #"name="commenttext_new""#) != nil
        if let address = firstCapture(#"['"]([^'"]*archiver\.php\?[^'"]*)['"]"#, in: html) {
            extras.archiveURL = URL(string: NativeGallery.decodeEntities(address))
        }
        return extras
    }

    private static let tagLinkPattern = try! NSRegularExpression(pattern: #"<a\b[^>]*\bid="ta_([^"]+)"[^>]*>"#)

    /// The tags of a work's tag pane, each with the account's vote: the page marks a tag voted up
    /// or down on its link.
    static func tagVotes(from html: String) -> [WorkTagVote] {
        let source = html as NSString
        var seen = Set<String>()
        return tagLinkPattern.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let link = source.substring(with: match.range)
            // The menu call names the tag with its spaces; the link's own id writes them as underscores.
            let named = firstCapture(#"toggle_tagmenu\(\s*[0-9]+\s*,\s*'([^']+)'"#, in: link).map(NativeGallery.decodeEntities)
            let tag = (named ?? source.substring(with: match.range(at: 1)).replacingOccurrences(of: "_", with: " ")).trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, tag.count <= 200, seen.insert(tag).inserted else { return nil }
            let classes = firstCapture(#"\bclass="([^"]*)""#, in: link)?.split(separator: " ").map(String.init) ?? []
            return WorkTagVote(tag: tag, vote: classes.contains("tup") ? 1 : classes.contains("tdn") ? -1 : 0)
        }
    }

    /// The archives a work's archive page offers for download, with their cost and size, and the
    /// account's funds. A greyed-out offer the page marks unavailable.
    static func archiveOffer(from html: String) -> WorkArchiveOffer {
        var offer = WorkArchiveOffer()
        if let funds = firstCapture(#"Current Funds:\s*</p>\s*<p>(.*?)</p>"#, in: html) {
            let text = plain(funds).replacingOccurrences(of: "[?]", with: "")
            if let match = firstMatch(#"([0-9][0-9,]*)\s*GP.*?([0-9][0-9,]*)\s*Credits"#, in: text) {
                offer.funds = "\(match[0]) GP · \(match[1]) Credits"
            }
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"Download Cost:(.*?)</div>\s*<form\b[^>]*>(.*?)</form>\s*<p>\s*Estimated Size:(.*?)</p>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return offer }
        let source = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            let form = source.substring(with: match.range(at: 2))
            guard let kind = firstCapture(#"name="dltype"[^>]*value="([a-z]+)""#, in: form),
                  let button = firstCapture(#"name="dlcheck"[^>]*value="([^"]+)""#, in: form) else { continue }
            let cost = plain(source.substring(with: match.range(at: 1)))
            let size = plain(source.substring(with: match.range(at: 3)))
            offer.options.append(.init(kind: kind, button: NativeGallery.decodeEntities(button), cost: cost, size: size,
                                       available: !cost.isEmpty && cost.uppercased() != "N/A" && !form.contains("disabled")))
        }
        return offer
    }

    /// Where the archive the page just prepared downloads from.
    static func archiveDownloadURL(from html: String) -> URL? {
        guard let address = firstCapture(#"document\.location\s*=\s*"([^"]+)""#, in: html).map(NativeGallery.decodeEntities),
              var components = URLComponents(string: address) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "start", value: "1")]
        return components.url
    }

    /// A page's own short message, as an answer that took no action gives it.
    static func message(in html: String) -> String? {
        let body = firstCapture(#"<div id="db"[^>]*>(.*)</div>"#, in: html) ?? firstCapture(#"<body[^>]*>(.*)</body>"#, in: html) ?? html
        let text = plain(body.replacingOccurrences(of: #"<h1\b.*?</h1>"#, with: "", options: [.regularExpression, .caseInsensitive]))
        return (1...400).contains(text.count) ? text : nil
    }

    /// The account's settings profiles from the website's settings page.
    static func settingsProfiles(from html: String) -> [SiteSettingsProfile] {
        guard let select = firstCapture(#"<select\b[^>]*name="profile_set"[^>]*>(.*?)</select>"#, in: html),
              let regex = try? NSRegularExpression(pattern: #"<option\b([^>]*)>([^<]*)</option>"#, options: [.caseInsensitive]) else { return [] }
        let source = select as NSString
        return regex.matches(in: select, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let attributes = source.substring(with: match.range(at: 1))
            guard let value = firstCapture(#"value="([0-9]{1,4})""#, in: attributes).flatMap(Int.init) else { return nil }
            let name = plain(source.substring(with: match.range(at: 2)))
            return SiteSettingsProfile(id: value, name: name.isEmpty ? String(value) : name, selected: attributes.contains("selected"))
        }
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

    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
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

/// Catalogs that keep ratings and comments for their works.
protocol WorkExtrasProviding: Sendable {
    /// Nil when the website keeps none of this for its works.
    func extras(_ id: Int64) async throws -> WorkExtras?
    func allComments(_ id: Int64) async throws -> [WorkComment]
    /// Rates a work from 1 to 10 half-stars; returns the new average and count.
    func rate(_ id: Int64, halfStars: Int) async throws -> (average: Double, count: Int)
    /// Votes a tag of a work up (1) or down (-1); voting against the account's vote withdraws it.
    /// Returns the work's tags with the votes as they now stand.
    func voteTag(_ id: Int64, tag: String, vote: Int) async throws -> [WorkTagVote]
    /// Posts a comment under a work and returns the comments as they now stand.
    func postComment(_ id: Int64, text: String) async throws -> [WorkComment]
    /// What the website asks for the work's archives.
    func archiveOffer(_ id: Int64) async throws -> WorkArchiveOffer
    /// Has the website prepare an archive, charging what the offer showed; returns where it downloads from.
    func archiveDownloadURL(_ id: Int64, option: WorkArchiveOffer.Option) async throws -> URL
}

extension WorkExtrasProviding {
    func voteTag(_ id: Int64, tag: String, vote: Int) async throws -> [WorkTagVote] { throw ContentError.unsupportedFormat }
    func postComment(_ id: Int64, text: String) async throws -> [WorkComment] { throw ContentError.unsupportedFormat }
    func archiveOffer(_ id: Int64) async throws -> WorkArchiveOffer { throw ContentError.unsupportedFormat }
    func archiveDownloadURL(_ id: Int64, option: WorkArchiveOffer.Option) async throws -> URL { throw ContentError.unsupportedFormat }
}
