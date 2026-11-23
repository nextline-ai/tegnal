import CryptoKit
import Foundation

// MARK: - The file

/// An add-on: a data file, made by anyone, that the learner downloads and opens in the app.
///
/// Add-ons are data only. They carry no code, no web content and no addresses, and nothing in them is
/// run, fetched or opened. Every part is checked before it is shown, the file is kept in the app as the
/// checked copy (not as the file itself), and what an add-on adds stays apart from the learner's own
/// settings, so turning it off or removing it leaves everything as it was.
struct Addon: Codable, Equatable, Sendable {
    static let format = "tegnal-addon"
    static let schemaVersion = 1
    static let maximumBytes = 8 * 1024 * 1024
    static let fileExtension = "tegnaladdon"

    var format = Addon.format
    var schemaVersion = Addon.schemaVersion
    /// Lowercase letters, digits, dots, hyphens and underscores, such as `studio.night-owl.ko-tags`.
    var id: String
    /// Digits and dots, such as `1.2.0`.
    var version: String
    /// The mode it works in. Comics and image add-ons are kept, listed and applied apart.
    var mode: AddonMode
    var name: StudyText
    var author: String
    var summary: StudyText?
    var contents: AddonContents

    var title: String { name.addonResolved() }
}

/// The mode an add-on belongs to. Comics add-ons bring tag translations and comics search tags; image add-ons
/// bring tag translations, image blacklist rules and challenges.
/// Learning courses are not add-ons: they are imported in learning mode's 코스 tab (`LearningCourses`).
enum AddonMode: String, Codable, CaseIterable, Sendable {
    case comics, images

    init(_ mode: AppMode) { self = mode == .manga ? .comics : .images }
    init(_ mode: TasteMode) { self = mode == .comics ? .comics : .images }

    var title: String { L10n.text(self == .comics ? "Comics Mode" : "Image Mode") }
}

/// What an add-on brings. One file may bring several of these together, such as translations with the search tags that use them.
struct AddonContents: Codable, Equatable, Sendable {
    var tagTranslations: AddonTranslations?
    var searchTags: AddonSearchTags?
    var challenges: [ChallengeDefinition]?

    static let keys: Set<String> = ["tagTranslations", "searchTags", "challenges"]
    var kinds: [AddonKind] {
        var kinds: [AddonKind] = []
        if tagTranslations != nil { kinds.append(.translations) }
        if searchTags != nil { kinds.append(.searchTags) }
        if challenges != nil { kinds.append(.challenges) }
        return kinds
    }
}

enum AddonKind: String, CaseIterable, Sendable {
    case translations, searchTags, challenges
    var title: String {
        switch self {
        case .translations: return L10n.text("Tag Translations")
        case .searchTags: return L10n.text("Default and Excluded Tags")
        case .challenges: return L10n.text("Challenge Roulette")
        }
    }
    var symbol: String {
        switch self {
        case .translations: return "character.bubble"
        case .searchTags: return "line.3.horizontal.decrease.circle"
        case .challenges: return "dice"
        }
    }
}

/// Tag names shown in another wording. Each tag has exactly one translation; applied, it is shown in place of the tag.
/// Searches still use the tag itself.
struct AddonTranslations: Codable, Equatable, Sendable {
    /// The language of the translations: `en`, `ko` or `ja`. Shown to the learner; translations apply in every app language.
    var language: String
    /// Tag, as servers write it (`long_hair`, `female:glasses`), to the words shown for it.
    var entries: [String: String]
}

/// Tags added to searches and tags hidden from them.
struct AddonSearchTags: Codable, Equatable, Sendable {
    struct Comics: Codable, Equatable, Sendable {
        /// Added to every comics search, like the Default Tags setting.
        var include: [String]?
        /// Hidden from every comics search, like the Default Excluded Tags setting. Written without a minus sign.
        var exclude: [String]?
    }
    struct Images: Codable, Equatable, Sendable {
        /// Rules that hide images on every server, written like blacklist lines.
        var exclude: [String]?
    }
    var comics: Comics?
    var images: Images?
}

// MARK: - Errors

enum AddonError: LocalizedError, Equatable {
    case tooLarge, notAddon, newerFormat, unknownContent(String), empty, invalid(String), otherMode(AddonMode)
    var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.text("This add-on file is too large.")
        case .notAddon: return L10n.text("This file is not a TEGNAL add-on.")
        case .newerFormat: return L10n.text("This add-on needs a newer version of TEGNAL.")
        // Learning tracks left add-ons for learning mode's own course files.
        case .unknownContent("learningTrack"): return L10n.text("addon.trackMoved")
        case .unknownContent(let key): return L10n.text("This add-on contains something TEGNAL does not support: %@", key)
        case .empty: return L10n.text("This add-on contains nothing to add.")
        case .invalid(let field): return L10n.text("This add-on was not added because a part of it is not allowed: %@", field)
        case .otherMode(let mode):
            return L10n.text(mode == .comics ? "This add-on is for Comics Mode. Open it from Settings → Add-ons in Comics Mode." : "This add-on is for Image Mode. Open it from Settings → Add-ons in Image Mode.")
        }
    }
}

// MARK: - Reading and checking

extension Addon {
    /// Reads a file the learner picked. Nothing in it is used until `validate()` has passed.
    static func read(_ url: URL) throws -> (addon: Addon, digest: String) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw AddonError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Read one byte past the limit, so that a file that grew after its size was checked is still refused.
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> (addon: Addon, digest: String) {
        guard data.count <= maximumBytes else { throw AddonError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any] else { throw AddonError.notAddon }
        guard top["format"] as? String == format else { throw AddonError.notAddon }
        guard let schema = top["schemaVersion"] as? Int, schema >= 1 else { throw AddonError.notAddon }
        guard schema <= schemaVersion else { throw AddonError.newerFormat }
        // Anything not understood is refused rather than skipped, so that what is shown is all the file does.
        let known: Set<String> = ["format", "schemaVersion", "id", "version", "mode", "name", "author", "summary", "contents"]
        if let extra = Set(top.keys).subtracting(known).sorted().first { throw AddonError.unknownContent(extra) }
        guard let contents = top["contents"] as? [String: Any] else { throw AddonError.empty }
        if let extra = Set(contents.keys).subtracting(AddonContents.keys).sorted().first { throw AddonError.unknownContent(extra) }
        // Text written in Korean or Japanese only is shown in English too, rather than left blank.
        var filled = top
        for key in ["name", "summary"] { if let text = filled[key] { filled[key] = Self.fillEnglish(text, depth: 0) } }
        let addon: Addon
        do {
            let normalized = try JSONSerialization.data(withJSONObject: filled)
            addon = try JSONDecoder().decode(Addon.self, from: normalized)
        } catch { throw AddonError.invalid(Self.describe(error)) }
        try addon.validate()
        return (addon, digest(data))
    }

    /// Gives every text in the app languages an English wording, taken from Korean or Japanese where English is missing.
    private static func fillEnglish(_ value: Any, depth: Int) -> Any {
        guard depth < 24 else { return value }
        if var object = value as? [String: Any] {
            let languages: Set<String> = ["en", "ko", "ja"]
            if !object.isEmpty, Set(object.keys).isSubset(of: languages), object.values.allSatisfy({ $0 is String }) {
                if object["en"] == nil, let other = (object["ko"] ?? object["ja"]) { object["en"] = other }
                return object
            }
            for (key, inner) in object { object[key] = fillEnglish(inner, depth: depth + 1) }
            return object
        }
        if let array = value as? [Any] { return array.map { fillEnglish($0, depth: depth + 1) } }
        return value
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return L10n.text("File") }
        let path: [CodingKey]
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
        @unknown default: path = []
        }
        let text = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return text.isEmpty ? L10n.text("File") : text
    }

    static let limits = (translations: 100_000, searchTags: 500, challenges: 50)

    func validate() throws {
        func require(_ value: Bool, _ field: String) throws { if !value { throw AddonError.invalid(field) } }
        try require(format == Self.format && schemaVersion >= 1 && schemaVersion <= Self.schemaVersion, "format")
        try require(AddonCheck.identifier(id), "id")
        try require(AddonCheck.version(version), "version")
        // A comics add-on cannot reach image servers or challenges, and an image add-on cannot reach comics searches.
        switch mode {
        case .comics:
            try require(contents.challenges == nil, "challenges")
            try require(contents.searchTags?.images == nil, "searchTags.images")
        case .images:
            try require(contents.searchTags?.comics == nil, "searchTags.comics")
        }
        try require(AddonCheck.text(name, max: 80), "name")
        try require(AddonCheck.line(author, max: 80), "author")
        if let summary { try require(AddonCheck.text(summary, max: 600, multiline: true), "summary") }
        let kinds = contents.kinds
        guard !kinds.isEmpty else { throw AddonError.empty }

        if let translations = contents.tagTranslations {
            try require(["en", "ko", "ja"].contains(translations.language), "tagTranslations.language")
            try require(!translations.entries.isEmpty && translations.entries.count <= Self.limits.translations, "tagTranslations.entries")
            var seen = Set<String>()
            for (tag, words) in translations.entries {
                let key = AddonCheck.tagKey(tag)
                try require(AddonCheck.tag(key, namespaced: true), "tagTranslations: " + AddonCheck.preview(tag))
                try require(AddonCheck.line(words, max: 80), "tagTranslations: " + AddonCheck.preview(tag))
                // One tag, one translation: `Long_Hair` and `long hair` are the same tag.
                try require(seen.insert(key).inserted, "tagTranslations: " + AddonCheck.preview(tag))
            }
        }

        if let search = contents.searchTags {
            let lists = [("searchTags.comics.include", search.comics?.include), ("searchTags.comics.exclude", search.comics?.exclude)]
            for (field, list) in lists {
                guard let list else { continue }
                try require(list.count <= Self.limits.searchTags, field)
                for term in list { try require(AddonCheck.comicsTerm(term), field + ": " + AddonCheck.preview(term)) }
            }
            if let rules = search.images?.exclude {
                try require(rules.count <= Self.limits.searchTags, "searchTags.images.exclude")
                for rule in rules { try require(AddonCheck.imageRule(rule), "searchTags.images.exclude: " + AddonCheck.preview(rule)) }
            }
            let total = (search.comics?.include?.count ?? 0) + (search.comics?.exclude?.count ?? 0) + (search.images?.exclude?.count ?? 0)
            try require(total > 0, "searchTags")
        }

        if let games = contents.challenges {
            try require(!games.isEmpty && games.count <= Self.limits.challenges, "challenges")
            try require(Set(games.map(\.id)).count == games.count, "challenges")
            for game in games {
                try require(AddonCheck.identifier(game.id, max: 48), "challenges: " + AddonCheck.preview(game.id))
                do { try game.validate() } catch { throw AddonError.invalid("challenges: " + AddonCheck.preview(game.title)) }
                try require(AddonCheck.challengeText(game), "challenges: " + AddonCheck.preview(game.title))
            }
        }
    }
}

// MARK: - Rules for every piece of text

/// The checks every value from an add-on passes. Text is refused, not cleaned, so that what is shown before
/// installing is exactly what is installed.
enum AddonCheck {
    static func identifier(_ value: String, max: Int = 48) -> Bool {
        guard (3...max).contains(value.count), let first = value.unicodeScalars.first, first.isASCIILowerOrDigit else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCIILowerOrDigit || $0 == "." || $0 == "-" || $0 == "_" }
    }

    static func version(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Compares `1.10` above `1.9`.
    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }, b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// One line of plain text, or several when `multiline`. Control characters, invisible formatting
    /// and direction overrides (which can make text read differently from what it is) are refused.
    static func line(_ value: String, max: Int, multiline: Bool = false) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= max else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            if scalar == "\n" { return multiline }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: return false
            // Joiners keep emoji whole; every other invisible format mark is refused.
            case .format: return scalar.value == 0x200D
            default: return true
            }
        }
    }

    /// Text in the app languages. English or at least one language must be present, and only `en`, `ko` and `ja` are read.
    static func text(_ value: StudyText, max: Int, multiline: Bool = false) -> Bool {
        !value.isEmpty && value.keys.allSatisfy { ["en", "ko", "ja"].contains($0) } && value.values.allSatisfy { line($0, max: max, multiline: multiline) }
    }

    static func color(_ value: String) -> Bool { value.count == 6 && value.allSatisfy(\.isHexDigit) }

    /// A system symbol name: letters, digits and dots.
    static func symbol(_ value: String) -> Bool {
        (1...60).contains(value.count) && value.unicodeScalars.allSatisfy { $0.isASCIILowerOrDigit || $0 == "." }
    }

    /// The form a tag is matched in: lowercase, with underscores for spaces.
    static func tagKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }

    /// One tag as servers write it. No spaces, search operators or wildcards, so that it can never widen or rewrite a search.
    static func tag(_ value: String, namespaced: Bool) -> Bool {
        guard line(value, max: 128), !value.contains(where: \.isWhitespace) else { return false }
        guard let first = value.first, !"-~*{}".contains(first) else { return false }
        if value.contains("*") || value.contains("{") || value.contains("}") || value.contains("\"") || value.contains(",") { return false }
        if !namespaced, value.hasSuffix(":") { return false }
        if namespaced, let colon = value.firstIndex(of: ":"), value[value.index(after: colon)...].isEmpty { return false }
        return true
    }

    static let comicsNamespaces: Set<String> = ["tag", "female", "male", "mixed", "other", "artist", "group", "parody", "character", "language", "type", "cosplayer", "series"]

    /// A term for comics searches. A namespace, when there is one, is one the comics searches already know.
    static func comicsTerm(_ value: String) -> Bool {
        guard tag(value, namespaced: true), !value.hasPrefix("-") else { return false }
        guard let colon = value.firstIndex(of: ":") else { return true }
        return comicsNamespaces.contains(String(value[..<colon]).lowercased())
    }

    static let ratings: Set<String> = ["g", "s", "q", "e", "general", "sensitive", "questionable", "explicit", "safe"]

    /// One line of an image blacklist: up to eight terms, all of which must match for an image to be hidden.
    /// Terms are tags, `rating:` and `artist:`, and terms after the first may start with a minus sign.
    static func imageRule(_ value: String) -> Bool {
        guard line(value, max: 400) else { return false }
        let terms = value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...8).contains(terms.count), !terms[0].hasPrefix("#") else { return false }
        for (index, raw) in terms.enumerated() {
            let negative = raw.hasPrefix("-")
            if negative && index == 0 { return false }
            let term = negative ? String(raw.dropFirst()) : raw
            if term.hasPrefix("rating:") {
                guard ratings.contains(String(term.dropFirst(7))) else { return false }
            } else if term.hasPrefix("artist:") {
                guard tag(String(term.dropFirst(7)), namespaced: false) else { return false }
            } else if term.hasPrefix("id:") {
                return false
            } else if !tag(term, namespaced: false) { return false }
        }
        return true
    }

    /// Every text a challenge shows, held to the same rules as the rest of the add-on.
    static func challengeText(_ game: ChallengeDefinition) -> Bool {
        var lines = [game.title, game.template] + (game.reels + game.groups).flatMap { [$0.title] + $0.options.map(\.text) }
        lines += game.endings.map(\.title)
        let long = [game.detail] + (game.helpPages ?? []).flatMap { [$0.title, $0.body] } + game.endings.map(\.detail)
        return lines.allSatisfy { line($0, max: 4000) }
            && long.allSatisfy { $0.isEmpty || line($0, max: 16000, multiline: true) }
            && game.endings.allSatisfy { $0.badge.isEmpty || line($0.badge, max: 40) }
    }

    /// A short, safe excerpt of a value for an error message.
    static func preview(_ value: String) -> String {
        let shown = String(value.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory { case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: return false; default: return true }
        }.prefix(40).map(Character.init))
        return shown.isEmpty ? "?" : shown
    }
}

private extension Unicode.Scalar {
    var isASCIILowerOrDigit: Bool { ("a"..."z").contains(self) || ("0"..."9").contains(self) }
}

extension Dictionary where Key == String, Value == String {
    /// Like `resolved`, falling back to any language the add-on was written in.
    func addonResolved(_ language: String = L10n.language) -> String {
        self[language] ?? self["en"] ?? ["ko", "ja"].compactMap { self[$0] }.first ?? ""
    }
}
