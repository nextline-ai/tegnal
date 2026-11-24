import Foundation

/// Text in a lab script. A script may write it as one string, as a list of lines, or per language
/// (`{"ko": …, "en": …}`, each a string or a list of lines). Plain text is the script's own language and is shown in every language
/// until a translation is added.
struct LabText: Decodable, Hashable, Sendable, ExpressibleByStringLiteral {
    var values: [String: String]

    init(_ text: String) { values = ["ko": text] }
    init(stringLiteral value: String) { self.init(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { values = ["ko": text]; return }
        if let lines = try? container.decode([String].self) { values = ["ko": lines.joined(separator: "\n")]; return }
        let map = try container.decode([String: LabLines].self)
        values = map.mapValues(\.text)
    }

    /// The wording for the app language; untranslated text falls back to the script's own.
    func resolved(_ language: String = L10n.language) -> String {
        values[language] ?? values["ko"] ?? values["en"] ?? values.values.first ?? ""
    }
    var text: String { resolved() }
    var isEmpty: Bool { values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// One language's text: a string, or lines to be joined.
private struct LabLines: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let lines = try? container.decode([String].self) { text = lines.joined(separator: "\n") } else { text = try container.decode(String.self) }
    }
}

// MARK: - The course

/// A deck course: its seasons and the episodes in them. The AI lab is the bundled one (`AILab/course.json` beside
/// `AILab/episodes/<id>.json`); others are imported from one-file course files (`LabCourseFile`) and play on the same deck.
struct LabCourse: Sendable {
    let info: LabCourseInfo
    let episodes: [LabEpisode]
    /// Imported by the learner from a course file. Such a course pays no 보석, has no cheat sheet or diagnosis of its own,
    /// and keeps its records under its own id (`LabStore.key`).
    var imported = false
    /// Sold in the shop and downloaded from TEGNAL (`LabGoods`): kept under its own id like an imported course, but it pays 보석.
    var official = false

    var id: String { info.id }

    var seasons: [LabSeason] { info.seasons }
    var title: String { info.title.text }
    /// The rate a learner starts at, before any card.
    var base: Int { info.base }
    /// The highest the rate can go: every card engraved.
    var top: Int { base + episodes.reduce(0) { $0 + $1.impact } }

    func episode(_ id: String) -> LabEpisode? { episodes.first { $0.id == id } }
    func season(of episode: LabEpisode) -> LabSeason? { seasons.first { $0.episodes.contains(episode.id) } }
    /// Every trap of every episode, in deck order.
    var fails: [LabFail] { episodes.flatMap(\.fails) }

    /// The course bundled with the app.
    static let bundled: LabCourse = {
        do { return try load(Bundle.main.url(forResource: "AILab", withExtension: nil)!) } catch {
            assertionFailure("AILab course: \(error)")
            return LabCourse(info: LabCourseInfo.empty, episodes: [])
        }
    }()

    /// Reads a course folder: `course.json` and the episode files its seasons name, in that order.
    static func load(_ folder: URL) throws -> LabCourse {
        let decoder = JSONDecoder()
        let info = try decoder.decode(LabCourseInfo.self, from: Data(contentsOf: folder.appending(path: "course.json")))
        var episodes: [LabEpisode] = []
        for id in info.seasons.flatMap(\.episodes) {
            let url = folder.appending(path: "episodes/\(id).json")
            do { episodes.append(try decoder.decode(LabEpisode.self, from: Data(contentsOf: url))) }
            catch { throw LabCourseError.episode(id, String(describing: error)) }
        }
        return LabCourse(info: info, episodes: episodes)
    }
}

enum LabCourseError: Error, CustomStringConvertible {
    case episode(String, String)
    var description: String {
        switch self { case .episode(let id, let detail): return "episodes/\(id).json: \(detail)" }
    }
}

struct LabCourseInfo: Decodable, Sendable {
    var id: String
    var title: LabText
    var gauge: LabText
    var base: Int
    var rewards: LabRewards
    var seasons: [LabSeason]
    /// The colours engraved cards take, six hexadecimal digits each, used in turn down the deck: card 1 the first, card 6 the first again.
    var cardColors: [String]?

    static let empty = LabCourseInfo(id: "", title: "", gauge: "", base: 0, rewards: .none, seasons: [])

    init(id: String, title: LabText, gauge: LabText, base: Int, rewards: LabRewards, seasons: [LabSeason], cardColors: [String]? = nil) {
        (self.id, self.title, self.gauge, self.base, self.rewards, self.seasons, self.cardColors) = (id, title, gauge, base, rewards, seasons, cardColors)
    }

    /// `rewards` may be left out, as in an imported course, which pays nothing anyway.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(LabText.self, forKey: .title)
        gauge = try container.decode(LabText.self, forKey: .gauge)
        base = try container.decode(Int.self, forKey: .base)
        rewards = try container.decodeIfPresent(LabRewards.self, forKey: .rewards) ?? .none
        seasons = try container.decode([LabSeason].self, forKey: .seasons)
        cardColors = try container.decodeIfPresent([String].self, forKey: .cardColors)
    }
    private enum Keys: String, CodingKey { case id, title, gauge, base, rewards, seasons, cardColors }
}

/// What the lab pays in 보석, apart from each card's own amount. The `course…` amounts are what 2D AI 배우기 pays.
struct LabRewards: Decodable, Sendable {
    /// Each trap pressed for the first time, once its 망작 is hung in the gallery.
    var fail: Int
    /// Each new cheat-sheet edition read, unless the edition says otherwise.
    var edition: Int
    /// Each season of cards finished.
    var season: Int = 0
    /// Each lesson of 2D AI 배우기 finished for the first time.
    var courseLesson: Int
    /// Each of its lessons finished with three stars for the first time.
    var courseStars: Int = 0
    /// Each of its sections with every lesson finished.
    var courseSection: Int = 0

    static let none = LabRewards(fail: 0, edition: 0, courseLesson: 0)

    init(fail: Int, edition: Int, season: Int = 0, courseLesson: Int, courseStars: Int = 0, courseSection: Int = 0) {
        (self.fail, self.edition, self.season, self.courseLesson, self.courseStars, self.courseSection) = (fail, edition, season, courseLesson, courseStars, courseSection)
    }

    /// Amounts left out pay nothing, so older course files still read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        func amount(_ key: Keys) throws -> Int { try container.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        self.init(fail: try amount(.fail), edition: try amount(.edition), season: try amount(.season), courseLesson: try amount(.courseLesson),
                  courseStars: try amount(.courseStars), courseSection: try amount(.courseSection))
    }
    private enum Keys: String, CodingKey { case fail, edition, season, courseLesson, courseStars, courseSection }
}

struct LabSeason: Decodable, Hashable, Sendable, Identifiable {
    var number: Int
    var title: LabText
    var summary: LabText?
    /// `fixed`: one card after another. `free`: any open card in any order.
    var order: String
    /// The season that must be finished before this one opens.
    var opensAfter: Int?
    var episodes: [String]
    var id: Int { number }
    var free: Bool { order == "free" }
}

// MARK: - An episode

/// One three-minute episode: a disaster, a choice with traps, a hands-on tool, and the line engraved on its card.
struct LabEpisode: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var number: Int
    /// A short name for the card, such as "뇌 스위치", shown beside its number.
    var name: LabText?
    var title: LabText
    var teaser: LabText?
    /// How many points of the rate its card adds. Bigger for what makes a bigger difference.
    var impact: Int
    /// 보석 paid when its card is engraved.
    var reward: Int
    var disaster: LabDisaster
    var choices: [LabChoice]
    var tool: LabTool
    var card: LabCardText

    /// `No. 001`.
    var serial: String { String(format: "No. %03d", number) }
    /// `001`.
    var digits: String { String(format: "%03d", number) }
    var fails: [LabFail] {
        choices.enumerated().compactMap { index, choice in
            choice.fail.map { LabFail(id: $0.id ?? "\(id)-\(index + 1)", episode: id, name: $0.name, reply: $0.reply, choice: choice.text) }
        }
    }
}

struct LabDisaster: Decodable, Hashable, Sendable {
    /// What the learner asked the AI.
    var ask: LabText
    /// What the AI answered.
    var reply: LabText
    /// The line that sums up the disaster, in the content voice.
    var verdict: LabText
    /// What the learner is asked to do next, above the choices.
    var question: LabText
}

struct LabChoice: Decodable, Hashable, Sendable {
    var text: LabText
    var right: Bool?
    var verdict: LabText
    var why: LabText?
    var fail: LabFailText?
    var isRight: Bool { right ?? false }
}

struct LabFailText: Decodable, Hashable, Sendable {
    var id: String?
    var name: LabText
    var reply: LabText
}

/// A 망작: what a trap produced, hung in the gallery once the trap is pressed.
struct LabFail: Hashable, Sendable, Identifiable {
    var id: String
    var episode: String
    var name: LabText
    var reply: LabText
    /// The trap that made it.
    var choice: LabText
}

struct LabCardText: Decodable, Hashable, Sendable {
    /// The line engraved on the card.
    var line: LabText
    /// Its back: how to use it, three lines.
    var uses: [LabText]
    /// Text to copy and paste into an AI app.
    var copy: LabText?
}

// MARK: - The tool

/// The hands-on part of an episode. One shape for every kind; each kind reads the fields it needs.
struct LabTool: Decodable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable, CaseIterable { case switches, chips, stamps, marks, equip, rot }

    var kind: Kind
    var title: LabText
    var hint: LabText?
    /// The name of the measure the gauge shows.
    var gauge: LabText?
    /// The question in the fake prompt box, where the tool has one.
    var prompt: LabText?
    /// How many different passing results it takes (switches), or how many chips (chips in toggle mode).
    var need: Int?

    // switches
    var controls: [LabControl]?
    var results: [LabResult]?
    var compose: LabCompose?

    // chips
    var mode: String?
    var chips: [LabChip]?
    var head: LabText?

    // stamps
    var stamps: [LabText]?
    var items: [LabStampItem]?
    var summary: LabText?

    // marks
    var style: String?
    var pieces: [LabPiece]?
    var before: LabText?
    var middle: LabText?
    var after: LabText?
    var wrong: LabText?

    // equip
    var core: LabText?
    var gear: [LabGear]?
    var missions: [LabMission]?

    // rot
    var retry: LabText?
    var replies: [LabText]?
    var reset: LabText?
    var carry: LabText?
    var fresh: LabText?
    var minRetries: Int?
}

struct LabControl: Decodable, Hashable, Sendable {
    var label: LabText
    var options: [LabOption]
    /// True when nothing is chosen at first, as for questions the AI asks.
    var unset: Bool?
}

/// A switch position: a label, and for composed answers the line it adds.
struct LabOption: Decodable, Hashable, Sendable {
    var label: LabText
    var line: LabText?
    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: Keys.self), container.contains(.label) {
            label = try container.decode(LabText.self, forKey: .label)
            line = try container.decodeIfPresent(LabText.self, forKey: .line)
        } else {
            label = try LabText(from: decoder)
            line = nil
        }
    }
    private enum Keys: String, CodingKey { case label, line }
}

/// What the AI answers for one setting of the switches. `-1` in `when` matches any position, and an unset one.
struct LabResult: Decodable, Hashable, Sendable {
    var when: [Int]
    var meta: LabText?
    var score: Int
    var pass: Bool?
    var reply: LabText
    var note: LabText?
    func matches(_ picks: [Int?]) -> Bool {
        guard when.count == picks.count else { return false }
        return zip(when, picks).allSatisfy { want, pick in want == -1 || want == pick }
    }
}

/// The answer put together from each switch's line, once every switch is set.
struct LabCompose: Decodable, Hashable, Sendable {
    var meta: LabText?
    var head: LabText?
    var tail: LabText?
    var score: Int
}

struct LabChip: Decodable, Hashable, Sendable {
    var label: LabText
    /// What gets attached to the prompt, such as an example.
    var attach: LabText?
    /// The AI's inner voice before it answers.
    var think: LabText?
    /// One answer per press; the last repeats.
    var replies: [LabText]?
    var score: Int?
    var pass: Bool?
    /// In toggle mode, the line the chip adds to the composed card.
    var line: LabText?
}

struct LabStampItem: Decodable, Hashable, Sendable {
    var text: LabText
    /// The index of the right stamp.
    var answer: Int
    var reveal: LabText?
}

struct LabPiece: Decodable, Hashable, Sendable {
    var text: LabText
    var target: Bool?
    /// What a masked piece reads as.
    var swap: LabText?
    /// Why a flagged piece is made up.
    var why: LabText?
    var isTarget: Bool { target ?? false }
}

struct LabGear: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var label: LabText
    var symbol: String?
    /// For gear that solves nothing: what happens when it is fitted.
    var miss: LabText?
}

struct LabMission: Decodable, Hashable, Sendable {
    var text: LabText
    var needs: [String]
    var before: LabText
    var after: LabText
}

// MARK: - The diagnosis

/// The one-minute habit check that makes card No. 000.
struct LabDiagnosis: Decodable, Sendable {
    var title: LabText
    var intro: LabText?
    var questions: [Question]
    var types: [LabType]
    var fallback: String

    struct Question: Decodable, Sendable { var text: LabText; var options: [Answer] }
    struct Answer: Decodable, Sendable { var text: LabText; var type: String? }

    func type(_ id: String?) -> LabType? { types.first { $0.id == id } }

    /// The type the answers point to most; ties go to the type listed first. No weak spot at all gives the fallback.
    func result(_ answers: [Int]) -> LabType? {
        var counts: [String: Int] = [:]
        for (question, answer) in zip(questions, answers) where question.options.indices.contains(answer) {
            if let type = question.options[answer].type { counts[type, default: 0] += 1 }
        }
        let best = types.filter { counts[$0.id] != nil }.max { a, b in
            let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
            if ca != cb { return ca < cb }
            return (types.firstIndex(of: a) ?? 0) > (types.firstIndex(of: b) ?? 0)
        }
        return best ?? type(fallback)
    }

    static let bundled: LabDiagnosis? = {
        guard let url = Bundle.main.url(forResource: "diagnosis", withExtension: "json", subdirectory: "AILab"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LabDiagnosis.self, from: data)
    }()
}

struct LabType: Decodable, Hashable, Sendable, Identifiable {
    var id: String
    var name: LabText
    var line: LabText
    var episodes: [String]
}
