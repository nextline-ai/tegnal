import Foundation

/// Text the curriculum carries in each app language, keyed "en", "ko" and "ja".
typealias StudyText = [String: String]

extension Dictionary where Key == String, Value == String {
    /// The wording for the app language, or English where a translation is missing.
    func resolved(_ language: String = L10n.language) -> String { self[language] ?? self["en"] ?? "" }
}

/// A tag the curriculum teaches: the server's own tag name, how it is called in each language and what it means.
struct StudyTag: Codable, Hashable, Identifiable, Sendable {
    let name: String
    var ko: String?
    var ja: String?
    var note: StudyText
    var confusable: [String]?
    var id: String { name }
    /// The tag as prompts write it: words apart, except emoticons such as `^_^`, which stay whole.
    var english: String { StudyPrompt.words(name) }
    /// The name in the app language; English reads the tag itself.
    func title(_ language: String = L10n.language) -> String {
        switch language {
        case "ko": return ko ?? english
        case "ja": return ja ?? english
        default: return english
        }
    }
}

/// Tags that answer one question about a picture, such as how long the hair is.
struct StudyGroup: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: StudyText
    /// The group's tags rarely apply to one picture together, so the others make fair wrong answers.
    var exclusive: Bool
    /// False where a tag cannot be told by looking at the picture; such tags are asked by meaning only.
    var visual: Bool
    var tags: [StudyTag]
    private enum CodingKeys: String, CodingKey { case id, title, exclusive, visual, tags }
    init(id: String, title: StudyText, exclusive: Bool = false, visual: Bool = true, tags: [StudyTag]) {
        self.id = id; self.title = title; self.exclusive = exclusive; self.visual = visual; self.tags = tags
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(StudyText.self, forKey: .title)
        exclusive = try values.decodeIfPresent(Bool.self, forKey: .exclusive) ?? false
        visual = try values.decodeIfPresent(Bool.self, forKey: .visual) ?? true
        tags = try values.decode([StudyTag].self, forKey: .tags)
    }
}

struct StudyUnit: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var title: StudyText
    var summary: StudyText
    var groups: [StudyGroup]
    var tags: [StudyTag] { groups.flatMap(\.tags) }
    /// Symbols are chosen in the app, so the curriculum file stays the same on every platform.
    var symbol: String {
        switch id {
        case "count": return "person.2"
        case "framing": return "crop"
        case "angle": return "camera"
        case "pose": return "figure.stand"
        case "expression": return "face.smiling"
        case "hair": return "comb"
        case "face": return "eye"
        case "body": return "pawprint"
        case "outfit": return "tshirt"
        case "legwear": return "shoe"
        case "accessory": return "eyeglasses"
        case "scene": return "mountain.2"
        case "light": return "sun.max"
        case "style": return "paintbrush.pointed"
        case "meta": return "doc.text"
        default: return "tag"
        }
    }
}

/// The tags the app teaches without asking a server, in the order they are learned.
struct StudyCurriculum: Codable, Sendable {
    var version: Int
    var units: [StudyUnit]
    private let index: [String: Place]
    struct Place: Hashable, Sendable { let unit: Int; let group: Int; let tag: Int }
    private enum CodingKeys: String, CodingKey { case version, units }

    init(version: Int = 1, units: [StudyUnit]) {
        self.version = version; self.units = units; index = Self.index(units)
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decode(Int.self, forKey: .version), units: try values.decode([StudyUnit].self, forKey: .units))
    }
    private static func index(_ units: [StudyUnit]) -> [String: Place] {
        var places: [String: Place] = [:]
        for (u, unit) in units.enumerated() {
            for (g, group) in unit.groups.enumerated() {
                for (t, tag) in group.tags.enumerated() where places[tag.name] == nil { places[tag.name] = Place(unit: u, group: g, tag: t) }
            }
        }
        return places
    }

    var tags: [StudyTag] { units.flatMap(\.tags) }
    var count: Int { index.count }
    func contains(_ name: String) -> Bool { index[name] != nil }
    func tag(_ name: String) -> StudyTag? { index[name].map { units[$0.unit].groups[$0.group].tags[$0.tag] } }
    func group(of name: String) -> StudyGroup? { index[name].map { units[$0.unit].groups[$0.group] } }
    func unit(of name: String) -> StudyUnit? { index[name].map { units[$0.unit] } }
    func unit(_ id: String) -> StudyUnit? { units.first { $0.id == id } }
    /// The tags of a post that the curriculum teaches, in curriculum order.
    func taught(in post: BooruPost) -> [StudyTag] {
        post.tags.compactMap { name in index[name].map { ($0, name) } }
            .sorted { ($0.0.unit, $0.0.group, $0.0.tag) < ($1.0.unit, $1.0.group, $1.0.tag) }
            .compactMap { tag($0.1) }
    }

    static let empty = StudyCurriculum(units: [])
    /// The curriculum shipped with the app; empty only if the file is missing or unreadable.
    static let bundled: StudyCurriculum = {
        guard let url = Bundle.main.url(forResource: "TagStudy", withExtension: "json"), let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(StudyCurriculum.self, from: data)) ?? .empty
    }()
}

/// What a server knows about a tag: how many posts carry it and what kind of tag it is.
struct StudyRelatedTag: Codable, Hashable, Identifiable, Sendable {
    let name: String
    var category: Int
    var count: Int
    /// The share of the asked tag's posts that also carry this one, from 0 to 1.
    var frequency: Double
    var id: String { name }
}

/// A server's own page about a tag, kept as the server wrote it.
struct StudyWiki: Codable, Hashable, Sendable {
    var title: String
    var body: String
    /// Other names for the tag, often in Japanese, Chinese or Korean.
    var otherNames: [String]
}

/// Everything read from a server about one tag, kept on the device until it goes stale.
struct StudyTagInfo: Codable, Hashable, Sendable {
    var name: String
    var count: Int?
    var category: Int?
    var wiki: StudyWiki?
    var related: [StudyRelatedTag]
    var fetched: Date
    /// False while only the post count is known, read together with a whole unit's counts.
    var complete: Bool
    static let lifetime: TimeInterval = 14 * 86_400
    var isStale: Bool { Date().timeIntervalSince(fetched) > Self.lifetime }
}

/// How well one tag is known. A right answer moves it up a step and a wrong one starts it over.
struct StudyProgress: Codable, Hashable, Identifiable, Sendable {
    let tag: String
    var step: Int = 0
    var due: Date = .distantPast
    var correct: Int = 0
    var wrong: Int = 0
    var seen: Date = .distantPast
    var id: String { tag }
    static let lastStep = 6
    /// Days until the tag is asked again after reaching each step.
    static let intervals: [Double] = [0, 1, 2, 4, 8, 16, 32]
    static let learnedStep = 4
    var isLearned: Bool { step >= Self.learnedStep }
    var isNew: Bool { correct + wrong == 0 }
    func isDue(_ now: Date) -> Bool { !isNew && due <= now }
    /// The progress after one more answer.
    func answered(_ right: Bool, now: Date) -> StudyProgress {
        var next = self
        next.seen = now
        if right {
            next.correct += 1
            next.step = min(Self.lastStep, step + 1)
            next.due = now.addingTimeInterval(Self.intervals[next.step] * 86_400)
        } else {
            next.wrong += 1
            next.step = 0
            next.due = now.addingTimeInterval(600)
        }
        return next
    }
}

/// One day's answers, for the streak and the day's total.
struct StudyDay: Codable, Hashable, Identifiable, Sendable {
    /// The local calendar day as `yyyy-MM-dd`.
    let day: String
    var answered: Int = 0
    var correct: Int = 0
    /// Experience earned that day in learning mode.
    var xp: Int = 0
    /// A day counts towards a streak when anything was studied on it.
    var isStudied: Bool { answered > 0 || xp > 0 }
    var id: String { day }
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum StudyQuestionKind: String, Codable, CaseIterable, Sendable {
    /// A picture is shown; choose the tag it carries.
    case pictureToTag
    /// A tag is shown; choose the picture that carries it.
    case tagToPicture
    /// A meaning is shown; choose the tag.
    case meaningToTag
}

struct StudyQuestion: Identifiable, Hashable, Sendable {
    let id = UUID()
    let kind: StudyQuestionKind
    let tag: StudyTag
    /// The tags offered; pictures are offered instead when `kind` is `.tagToPicture`.
    var choices: [StudyTag] = []
    /// One picture for `.pictureToTag`, or one per choice for `.tagToPicture`.
    var posts: [BooruPost] = []
    let answer: Int
    var choiceCount: Int { kind == .tagToPicture ? posts.count : choices.count }
}

extension StudyQuestion {
    /// How answer choices share lines: two neighbours no longer than `limit` characters sit side by side, anything longer keeps its own line.
    static func rows(_ lengths: [Int], limit: Int) -> [[Int]] {
        var rows: [[Int]] = [], index = 0
        while index < lengths.count {
            if index + 1 < lengths.count, lengths[index] <= limit, lengths[index + 1] <= limit { rows.append([index, index + 1]); index += 2 }
            else { rows.append([index]); index += 1 }
        }
        return rows
    }
}
