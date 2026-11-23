import Foundation
import GRDB
import Observation

// MARK: - The path

/// One stop on the learning path: an idea explained from nothing, a handful of new tags, or a prompt to put together.
struct StudyPathLesson: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case concept, tags, boss }
    /// Something told before anything is asked.
    struct Card: Codable, Hashable, Sendable {
        let title: StudyText
        let body: StudyText
        /// Prompt text shown as it would be typed.
        var code: String?
        /// An SF Symbol standing in until the card has a drawing of its own.
        var symbol: String?
        /// How the guide stands while telling it: `wave`, `cheer`, `think`, `sad`, `read`, `close-up` or `full-body`.
        var pose: String?
        /// A thing to do from the card: `civitai` opens the account page, `key` the API key sheet, `generator` the generator with the card's code as its prompt.
        var action: String?
    }
    struct Ask: Codable, Hashable, Sendable {
        let question: StudyText
        let choices: [StudyText]
        let answer: Int
        let why: StudyText
        /// True when the choices are prompt text, set in a fixed-width face.
        var code: Bool?
    }
    /// A picture described in words, to be ordered as a prompt from a bank of tags.
    struct Build: Codable, Hashable, Sendable {
        let brief: StudyText
        /// The tags the prompt needs, as servers write them.
        let answer: [String]
        /// Tags that do not belong, offered beside the right ones.
        let extras: [String]
    }
    /// Things to put in the order they happen. `items` is the right order.
    struct Order: Codable, Hashable, Sendable {
        let brief: StudyText
        let items: [StudyText]
        let why: StudyText
    }
    /// Things to drop into one of two buckets, one at a time.
    struct Sort: Codable, Hashable, Sendable {
        struct Item: Codable, Hashable, Sendable {
            let text: StudyText
            /// True when it belongs in the right-hand bucket.
            let right: Bool
        }
        let brief: StudyText
        let left: StudyText
        let right: StudyText
        let items: [Item]
        let why: StudyText
    }
    /// A step is exactly one of a card, a question, a prompt to build, things to order or things to sort.
    struct Step: Codable, Hashable, Sendable {
        var card: Card?
        var ask: Ask?
        var build: Build?
        var order: Order?
        var sort: Sort?
    }
    let id: String
    let kind: Kind
    let symbol: String
    let title: StudyText
    var summary: StudyText?
    /// The tags a `tags` lesson teaches, as servers write them.
    var tags: [String]?
    /// What a `concept` or `boss` lesson shows, in order.
    var steps: [Step]?
}

struct StudyPathSection: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: StudyText
    let summary: StudyText
    /// The section's colour, as six hexadecimal digits.
    let color: String
    var lessons: [StudyPathLesson] = []
}

struct StudyPath: Codable, Sendable {
    var version = 2
    var sections: [StudyPathSection] = []

    static let bundled: StudyPath = {
        guard let url = Bundle.main.url(forResource: "StudyPath", withExtension: "json"), let data = try? Data(contentsOf: url) else { return .init() }
        return (try? JSONDecoder().decode(StudyPath.self, from: data)) ?? .init()
    }()

    var lessons: [StudyPathLesson] { sections.flatMap(\.lessons) }

    /// The lesson the learner is on: the first one not finished from where the placement test put them, then the
    /// first one not finished anywhere. Nil once every lesson is done. `placed` counts the lessons the test passed by.
    func current(_ records: [String: StudyLessonRecord], placed: Int = 0) -> StudyPathLesson? {
        let all = lessons
        return all.dropFirst(min(max(0, placed), all.count)).first { records[$0.id] == nil } ?? all.first { records[$0.id] == nil }
    }

    /// A lesson opens once every lesson before it is finished, or once the placement test has passed it by.
    func isOpen(_ lesson: StudyPathLesson, _ records: [String: StudyLessonRecord], placed: Int = 0) -> Bool {
        records[lesson.id] != nil || current(records, placed: placed)?.id == lesson.id || isSkipped(lesson, records, placed: placed)
    }

    /// True for a lesson the placement test passed by that has not been played since.
    func isSkipped(_ lesson: StudyPathLesson, _ records: [String: StudyLessonRecord], placed: Int) -> Bool {
        records[lesson.id] == nil && lessons.prefix(max(0, placed)).contains { $0.id == lesson.id }
    }
}

extension StudyPathLesson.Ask {
    /// The same question with its choices in a new order.
    func shuffled<G: RandomNumberGenerator>(using generator: inout G) -> StudyPathLesson.Ask {
        let order = Array(choices.indices).shuffled(using: &generator)
        return .init(question: question, choices: order.map { choices[$0] }, answer: order.firstIndex(of: answer) ?? answer, why: why, code: code)
    }
}

// MARK: - Game state

struct StudyLessonRecord: Hashable, Sendable {
    let lesson: String
    /// One to three: three for a round without a mistake.
    var stars: Int
    var runs: Int
}

/// The numbers the game shows: experience, level, today's goal.
struct StudyGame: Equatable, Sendable {
    static let levelSize = 100
    static let goals = [10, 20, 30, 50]
    static let defaultGoal = 20
    var xp = 0
    var today = 0
    var goal = StudyGame.defaultGoal
    var level: Int { xp / Self.levelSize + 1 }
    /// How far into the current level, from zero to one.
    var levelProgress: Double { Double(xp % Self.levelSize) / Double(Self.levelSize) }
    var goalProgress: Double { goal <= 0 ? 1 : min(1, Double(today) / Double(goal)) }
    var goalMet: Bool { today >= goal }

    init() {}
    init(days: [StudyDay], goal: Int, now: Date = .now, calendar: Calendar = .current) {
        xp = days.reduce(0) { $0 + $1.xp }
        today = days.first { $0.day == StudyDay.key(now, calendar: calendar) }?.xp ?? 0
        self.goal = goal
    }

    /// What a finished round earns: more for no mistakes and for a long run of right answers.
    static func earned(mistakes: Int, bestCombo: Int) -> Int { 10 + (mistakes == 0 ? 5 : 0) + (bestCombo >= 5 ? 3 : 0) }
    static func stars(mistakes: Int) -> Int { mistakes == 0 ? 3 : mistakes <= 2 ? 2 : 1 }
}

extension StudyStore {
    static func migrateGame(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE study_lessons (lesson TEXT PRIMARY KEY NOT NULL, stars INTEGER NOT NULL, runs INTEGER NOT NULL, finished DOUBLE NOT NULL);
            ALTER TABLE study_days ADD COLUMN xp INTEGER NOT NULL DEFAULT 0;
            """)
    }

    func lessons() throws -> [String: StudyLessonRecord] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT lesson, stars, runs FROM study_lessons").map {
                ($0["lesson"] as String, StudyLessonRecord(lesson: $0["lesson"], stars: $0["stars"], runs: $0["runs"]))
            })
        }
    }

    /// Adds experience to a day, and marks a lesson finished when one is named. The best stars are kept.
    func earn(_ xp: Int, lesson: String? = nil, stars: Int = 0, now: Date = .now, calendar: Calendar = .current) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO study_days (day, answered, correct, xp) VALUES (?, 0, 0, ?)
                ON CONFLICT(day) DO UPDATE SET xp = xp + excluded.xp
                """, arguments: [StudyDay.key(now, calendar: calendar), max(0, xp)])
            guard let lesson else { return }
            try db.execute(sql: """
                INSERT INTO study_lessons (lesson, stars, runs, finished) VALUES (?, ?, 1, ?)
                ON CONFLICT(lesson) DO UPDATE SET stars = MAX(stars, excluded.stars), runs = runs + 1, finished = excluded.finished
                """, arguments: [lesson, min(3, max(1, stars)), now.timeIntervalSince1970])
        }
    }
}

/// What the learner had before a lesson paid out.
struct StudyStanding: Equatable, Sendable {
    var xp = 0
    var today = 0
    /// False when this lesson is the day's first study, which is what moves the streak.
    var studiedToday = true
}

/// What a finished lesson is worth celebrating beyond its own results.
/// What a lesson paid in 보석, and the balance before it: the treasure chest's contents.
struct StudyGemReward: Hashable, Sendable {
    var paid: LabTagPayout
    var before: Int
    var after: Int { before + paid.total }
}

enum StudyMilestone: Hashable, Sendable {
    /// 보석 paid by the lesson, opened from a treasure chest. Shown first.
    case gems(StudyGemReward)
    case streak(Int)
    case goal(Int)
    case level(Int)
    /// A badge earned by this lesson.
    case award(StudyAward)

    /// The milestones a lesson reached, in the order they are shown.
    static func reached(before: StudyStanding, earned: Int, goal: Int, streak: Int) -> [StudyMilestone] {
        guard earned > 0 else { return [] }
        var found: [StudyMilestone] = []
        if !before.studiedToday, streak > 0 { found.append(.streak(streak)) }
        if before.today < goal, before.today + earned >= goal { found.append(.goal(goal)) }
        let level = (before.xp + earned) / StudyGame.levelSize + 1
        if level > before.xp / StudyGame.levelSize + 1 { found.append(.level(level)) }
        return found
    }
}

// MARK: - The picture server

/// Learning mode reads pictures from one server. With no server added it is Safebooru; otherwise the learner chooses.
enum StudyServer {
    static let key = "study.server"

    /// The servers that can be chosen: the learner's own, and Safebooru when it is not among them.
    static func choices(_ store: BooruStore) -> [BooruServer] {
        let own = store.selectableServers
        return own.contains(where: \.isSafebooru) ? own : own + [fallback]
    }
    static let fallback = BooruServer(id: "safebooru", name: "Safebooru", baseURL: URL(string: "https://" + BooruServer.safebooruHost)!, engine: .gelbooru)

    /// The one to suggest: Danbooru when it is there, since the tags taught are written its way.
    static func recommended(_ servers: [BooruServer]) -> BooruServer {
        servers.first { $0.engine == .danbooru && (($0.baseURL.host ?? "") == "donmai.us" || ($0.baseURL.host ?? "").hasSuffix(".donmai.us")) }
            ?? servers.first { $0.engine == .danbooru } ?? servers.first(where: \.isSafebooru) ?? servers.first ?? fallback
    }

    static func current(_ store: BooruStore, defaults: UserDefaults) -> BooruServer {
        let servers = choices(store)
        if let id = defaults.string(forKey: key), let chosen = servers.first(where: { $0.id == id }) { return chosen }
        return store.selectableServers.isEmpty ? fallback : recommended(servers)
    }

    /// True while a learner with servers of their own has not said which one to learn from.
    static func needsChoice(_ store: BooruStore, defaults: UserDefaults) -> Bool {
        guard !store.selectableServers.isEmpty else { return false }
        guard let id = defaults.string(forKey: key) else { return true }
        return !choices(store).contains { $0.id == id }
    }
}

// MARK: - A lesson being played

/// One thing shown in a lesson.
struct StudyStep: Identifiable, Sendable {
    enum Kind: Sendable {
        case card(StudyPathLesson.Card)
        /// A new tag shown with pictures before it is asked.
        case teach(StudyTag, [BooruPost])
        case quiz(StudyQuestion)
        case ask(StudyPathLesson.Ask)
        /// Tags to pair with what they mean.
        case match([StudyTag])
        case build(StudyPathLesson.Build)
        case order(StudyPathLesson.Order)
        case sort(StudyPathLesson.Sort)
        /// A picture and four tags, one of which the picture does not carry: the answer.
        case odd(BooruPost, [StudyTag], Int)
        /// A tag to type from memory, as a prompt is typed. A picture is shown when there is a fair one.
        case spell(StudyTag, BooruPost?)
    }
    let id = UUID()
    let kind: Kind
    /// Asked again because it was missed the first time.
    var again = false
    /// Cards and new tags are read, not answered.
    var isAsked: Bool { if case .card = kind { return false }; if case .teach = kind { return false }; return true }
}

enum StudyLessonPlan: Hashable, Sendable {
    case lesson(StudyPathLesson)
    /// Tags that are due again, with no lesson to finish.
    case review
    /// The tags missed most often, asked again whether or not they are due.
    case weak
    /// The short test, taken at the start, that finds where on the path a learner who already knows some of this begins.
    case placement
    var lesson: StudyPathLesson? { if case .lesson(let lesson) = self { return lesson }; return nil }
}

@MainActor @Observable
final class StudyLessonSession: Identifiable {
    enum Phase: Equatable { case loading, asking, feedback(Bool), finished }
    static let reviewSize = 8

    let id = UUID()
    let plan: StudyLessonPlan
    private(set) var steps: [StudyStep] = []
    private(set) var index = 0
    private(set) var phase = Phase.loading
    private(set) var combo = 0
    private(set) var bestCombo = 0
    private(set) var mistakes = 0
    private(set) var asked = 0
    private(set) var earned = 0
    /// The 보석 this lesson paid — a 2D AI 배우기 lesson finished, or finished with three stars, for the first time, and the
    /// section it finished — with the balance before, for the treasure chest after the results. Nil when it paid nothing.
    private(set) var gems: StudyGemReward?
    private(set) var stars = 0
    /// Pictures that fit the prompts built in this lesson, by the build's brief.
    private(set) var builtPictures: [StudyPathLesson.Build: BooruPost] = [:]
    /// The tags met in this lesson, for the summary at its end.
    private(set) var tags: [StudyTag] = []
    /// Where the learner stood before this lesson paid out, so that its end can celebrate what changed.
    private(set) var before = StudyStanding()
    /// The section each placement question checks, by the question's step.
    private var checks: [UUID: Int] = [:]
    /// The section the placement test stopped at: the first one whose question was missed.
    private(set) var stoppedAt: Int?
    /// How many lessons the placement test passed by.
    private(set) var placed = 0
    var isPlacement: Bool { plan == .placement }

    private let store: BooruStore
    let source: any BooruProviding
    let server: BooruServer
    private let engine: StudyEngine
    private var generator = SystemRandomNumberGenerator()

    init(plan: StudyLessonPlan, store: BooruStore, source: any BooruProviding, server: BooruServer, engine: StudyEngine = .init()) {
        self.plan = plan; self.store = store; self.source = source; self.server = server; self.engine = engine
    }

    var step: StudyStep? { steps.indices.contains(index) ? steps[index] : nil }
    /// From zero to one, counting a missed step's second asking as part of the lesson.
    var progress: Double { steps.isEmpty ? 0 : Double(index + (phase == .feedback(true) || phase == .feedback(false) ? 1 : 0)) / Double(steps.count) }

    func start() async {
        guard steps.isEmpty, phase == .loading else { return }
        before.studiedToday = ((try? store.studyStore.days()) ?? []).first { $0.day == StudyDay.key(.now) }?.isStudied ?? false
        switch plan {
        case .placement:
            for question in StudyPlacement.questions(.bundled, curriculum: engine.curriculum, using: &generator) {
                let step = StudyStep(kind: .ask(question.ask))
                checks[step.id] = question.section
                steps.append(step)
            }
        case .review:
            let progress = (try? store.studyStore.progress()) ?? [:]
            tags = engine.round(.review, progress: progress, count: Self.reviewSize, now: .now, using: &generator)
            let pool = await pictures(tags)
            steps = questions(tags, pool: pool, twice: false)
            if tags.count >= 4 { steps.insert(.init(kind: .match(Array(tags.prefix(4)))), at: steps.count / 2) }
            if let odd = odd(tags, pool: pool) { steps.append(odd) }
            // Typing is the last and hardest recall, kept for tags already answered right a few times.
            for tag in tags.filter({ (progress[$0.name]?.step ?? 0) >= 2 }).shuffled(using: &generator).prefix(2) { steps.append(spell(tag, pool: pool)) }
        case .weak:
            let progress = (try? store.studyStore.progress()) ?? [:]
            tags = Self.weakest(progress, curriculum: engine.curriculum, count: Self.reviewSize)
            let pool = await pictures(tags)
            steps = questions(tags, pool: pool, twice: false)
            if tags.count >= 4 { steps.insert(.init(kind: .match(Array(tags.prefix(4)))), at: steps.count / 2) }
            steps += questions(tags.shuffled(using: &generator), pool: pool, twice: true)
        case .lesson(let lesson):
            switch lesson.kind {
            case .tags:
                tags = (lesson.tags ?? []).compactMap(engine.curriculum.tag)
                let pool = await pictures(tags)
                // Each new tag is shown, then asked at once; then all of them are mixed and asked again.
                for tag in tags {
                    steps.append(.init(kind: .teach(tag, Array(pool.filter { engine.teaches($0, tag) }.prefix(3)))))
                    if let question = engine.question(for: tag, pool: pool, using: &generator) { steps.append(.init(kind: .quiz(familiar(question)))) }
                }
                if tags.count >= 4 { steps.append(.init(kind: .match(Array(tags.shuffled(using: &generator).prefix(4))))) }
                if let odd = odd(tags, pool: pool) { steps.append(odd) }
                steps += questions(tags.shuffled(using: &generator), pool: pool, twice: true)
                // The lesson ends with one of its tags typed out, the way a prompt is written.
                if let tag = tags.randomElement(using: &generator) { steps.append(spell(tag, pool: pool)) }
            case .concept, .boss:
                for step in lesson.steps ?? [] {
                    if let card = step.card { steps.append(.init(kind: .card(card))) }
                    if let ask = step.ask { steps.append(.init(kind: .ask(ask.shuffled(using: &generator)))) }
                    if let build = step.build { steps.append(.init(kind: .build(build))) }
                    if let order = step.order { steps.append(.init(kind: .order(order))) }
                    if let sort = step.sort { steps.append(.init(kind: .sort(sort))) }
                }
                let builds = (lesson.steps ?? []).compactMap(\.build)
                tags = Array(Set(builds.flatMap(\.answer))).sorted().compactMap(engine.curriculum.tag)
                await picture(builds)
            }
        }
        if steps.isEmpty { finish() } else { phase = .asking }
    }

    private func questions(_ tags: [StudyTag], pool: [BooruPost], twice: Bool) -> [StudyStep] {
        var used = Set<String>()
        return tags.compactMap { tag in
            // A second asking prefers a picture not shown the first time.
            let fresh = pool.filter { !used.contains($0.id) }
            let question = engine.question(for: tag, pool: twice ? fresh : pool, using: &generator) ?? engine.question(for: tag, pool: pool, using: &generator)
            question?.posts.forEach { used.insert($0.id) }
            return question.map { StudyStep(kind: .quiz(familiar($0))) }
        }
    }

    /// The tags answered wrong most often, worst first. A tag never missed is not weak.
    static func weakest(_ progress: [String: StudyProgress], curriculum: StudyCurriculum, count: Int) -> [StudyTag] {
        progress.values.filter { $0.wrong > 0 }
            .sorted { first, second in
                // By the share of answers missed, then by how many, then by name so that the order is steady.
                let left = first.wrong * (second.correct + second.wrong), right = second.wrong * (first.correct + first.wrong)
                if left != right { return left > right }
                return first.wrong != second.wrong ? first.wrong > second.wrong : first.tag < second.tag
            }
            .compactMap { curriculum.tag($0.tag) }.prefix(count).map { $0 }
    }

    /// A picture with three tags it carries and one of the lesson's tags it does not. Nil when no picture gives a fair one.
    private func odd(_ tags: [StudyTag], pool: [BooruPost]) -> StudyStep? {
        for post in pool.shuffled(using: &generator) {
            let carried = Set(post.tags)
            var shown = tags.filter { carried.contains($0.name) }.shuffled(using: &generator)
            for name in post.tags.shuffled(using: &generator) where shown.count < 3 {
                if let tag = engine.curriculum.tag(name), !shown.contains(tag), engine.curriculum.group(of: name)?.visual ?? true { shown.append(tag) }
            }
            guard shown.count >= 3 else { continue }
            // A tag from a group the picture already answers (its hair is long, so not short) is surely absent;
            // any other missing tag may only have been left off by whoever tagged the picture.
            let absent = tags.filter { !carried.contains($0.name) }
            let sure = absent.filter { tag in (engine.curriculum.group(of: tag.name)?.tags ?? []).contains { carried.contains($0.name) } }
            guard let missing = (sure.isEmpty ? absent : sure).randomElement(using: &generator) else { continue }
            let choices = (Array(shown.prefix(3)) + [missing]).shuffled(using: &generator)
            return StudyStep(kind: .odd(post, choices, choices.firstIndex(of: missing) ?? 0))
        }
        return nil
    }

    private func spell(_ tag: StudyTag, pool: [BooruPost]) -> StudyStep {
        let visual = engine.curriculum.group(of: tag.name)?.visual ?? true
        return StudyStep(kind: .spell(tag, visual ? pool.filter { engine.teaches($0, tag) }.randomElement(using: &generator) : nil))
    }

    /// Whether a typed tag is the one asked for. Spaces and underscores are the same thing, and case does not matter.
    static func spelled(_ typed: String, _ tag: StudyTag) -> Bool {
        func plain(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "_", with: " ").split(separator: " ").joined(separator: " ")
        }
        return !plain(typed).isEmpty && plain(typed) == plain(tag.name)
    }

    /// The same question offering, beside the right tag, tags the learner has met: the lesson's own before any other.
    /// A tag the picture also carries is never offered as a wrong answer.
    private func familiar(_ question: StudyQuestion) -> StudyQuestion {
        guard question.kind != .tagToPicture, question.choices.count > 1 else { return question }
        let shown = Set(question.posts.first?.tags ?? [])
        let fair: (StudyTag) -> Bool = { $0.name != question.tag.name && !shown.contains($0.name) }
        var wrong = tags.filter(fair).shuffled(using: &generator)
        for tag in question.choices where fair(tag) && !wrong.contains(tag) { wrong.append(tag) }
        var choices = Array(wrong.prefix(question.choices.count - 1)) + [question.tag]
        choices.shuffle(using: &generator)
        return StudyQuestion(kind: question.kind, tag: question.tag, choices: choices, posts: question.posts, answer: choices.firstIndex(of: question.tag) ?? 0)
    }

    /// Example pictures for every tag of the lesson, read side by side so that the wait is one request long.
    private func pictures(_ tags: [StudyTag]) async -> [BooruPost] {
        let visual = tags.filter { engine.curriculum.group(of: $0.name)?.visual ?? true }
        let server = server, store = store, source = source
        var pool: [BooruPost] = [], seen = Set<String>()
        await withTaskGroup(of: [BooruPost].self) { group in
            for tag in visual { group.addTask { await StudyLookup.examples(tag.name, server: server, store: store, source: source) } }
            for await posts in group { for post in posts where seen.insert(post.id).inserted { pool.append(post) } }
        }
        return pool
    }

    /// A picture carrying every tag of a built prompt, to show what the prompt asks for.
    private func picture(_ builds: [StudyPathLesson.Build]) async {
        for build in builds {
            // The least common tag narrows the search most; headcount tags are on nearly every picture.
            guard let query = build.answer.last(where: { !StudyPrompt.leading.contains($0) }) ?? build.answer.last else { continue }
            let posts = await StudyLookup.examples(query, server: server, store: store, source: source)
            let wanted = Set(build.answer)
            if let fit = posts.first(where: { wanted.isSubset(of: Set($0.tags)) }) { builtPictures[build] = fit }
        }
    }

    /// Whether a prompt built from a bank of tags is right: the tags asked for and no others, with the headcount first.
    static func judge(_ chosen: [String], _ build: StudyPathLesson.Build) -> Bool {
        guard Set(chosen) == Set(build.answer), chosen.count == build.answer.count else { return false }
        let firstOther = chosen.firstIndex { !StudyPrompt.leading.contains($0) } ?? chosen.count
        return !chosen[firstOther...].contains { StudyPrompt.leading.contains($0) }
    }

    /// Whether things were put in their right order. Items that read the same may swap places.
    static func judge(_ chosen: [StudyText], _ order: StudyPathLesson.Order) -> Bool { chosen == order.items }

    /// Moves past a card or a new tag.
    func proceed() {
        guard phase == .asking, let step, !step.isAsked else { return }
        advance()
    }

    /// Records an answer. `tag` names the tag asked about, so that its review date moves.
    func answer(_ right: Bool, tag: String? = nil) {
        guard phase == .asking, let step, step.isAsked else { return }
        asked += 1
        if right { combo += 1; bestCombo = max(bestCombo, combo) } else { combo = 0; mistakes += 1 }
        if isPlacement {
            // The test stops at the first section it finds unknown; nothing is asked again and no tag is scheduled.
            if !right, stoppedAt == nil { stoppedAt = checks[step.id] }
            phase = .feedback(right)
            return
        }
        if !step.again {
            if let tag { try? store.studyStore.answer(tag, right: right) }
            // A missed step comes back once, at the end.
            if !right { steps.append(StudyStep(kind: step.kind, again: true)) }
        }
        phase = .feedback(right)
    }

    func next() {
        guard case .feedback = phase else { return }
        advance()
    }

    private func advance() {
        index += 1
        if index >= steps.count || (isPlacement && stoppedAt != nil) { finish() } else { phase = .asking }
    }

    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        if isPlacement {
            // The test earns no experience; it only says where the path begins.
            placed = StudyPlacement.skipped(.bundled, stoppedAt: stoppedAt)
            if placed > 0 { try? store.studyStore.raise(StudyPlacement.counter, to: placed) }
            return
        }
        guard asked > 0 || plan.lesson != nil else { return }
        stars = StudyGame.stars(mistakes: mistakes)
        earned = StudyGame.earned(mistakes: mistakes, bestCombo: bestCombo)
        let days = (try? store.studyStore.days()) ?? []
        before.xp = days.reduce(0) { $0 + $1.xp }
        before.today = days.first { $0.day == StudyDay.key(.now) }?.xp ?? 0
        try? store.studyStore.raise(StudyCounter.combo, to: bestCombo)
        try? store.studyStore.earn(earned, lesson: plan.lesson?.id, stars: stars)
        if plan.lesson != nil {
            let before = LabStore.shared.balance
            let paid = LabStore.shared.settleTagCourse(in: store.studyStore)
            if paid.total > 0 { gems = StudyGemReward(paid: paid, before: before) }
        }
    }
}

// MARK: - Placement

/// The short test a learner can take when learning mode first opens: one question for each section, in the path's
/// order, ending at the first one missed. The lessons before that section are passed by: open, but not finished.
enum StudyPlacement {
    /// The counter (in `study_stats`) holding how many lessons at the start of the main path the test passed by.
    /// Counters only go up, travel in sync and backups, and are cleared by a reset.
    static let counter = "placed"
    /// Set on this device once the welcome has been gone through; cleared when progress is reset.
    static let welcomedKey = "study.welcomed"

    struct Question: Sendable {
        /// The section of the path the question checks.
        let section: Int
        let ask: StudyPathLesson.Ask
    }

    /// One question for each section: one of the section's own questions, or, for a section that only teaches tags,
    /// which of a lesson's tags a meaning names, with the lesson's other tags as the wrong answers.
    static func questions<G: RandomNumberGenerator>(_ path: StudyPath, curriculum: StudyCurriculum, language: String = L10n.language,
                                                    using generator: inout G) -> [Question] {
        path.sections.enumerated().compactMap { index, section in
            let asks = section.lessons.flatMap { ($0.steps ?? []).compactMap(\.ask) }
            if let ask = asks.randomElement(using: &generator) { return Question(section: index, ask: ask.shuffled(using: &generator)) }
            let taught = section.lessons.filter { $0.kind == .tags }.map { ($0.tags ?? []).compactMap(curriculum.tag) }.filter { $0.count >= 2 }
            guard let tags = taught.randomElement(using: &generator), let tag = tags.randomElement(using: &generator) else { return nil }
            let choices = ([tag] + tags.filter { $0 != tag }.shuffled(using: &generator).prefix(3)).shuffled(using: &generator)
            // Tags are never translated in a question; what they mean is, as in a match step.
            let meaning = language == "en" ? tag.note.resolved(language) : tag.title(language)
            let ask = StudyPathLesson.Ask(question: ["en": L10n.text("Which tag fits “%@”?", meaning)],
                                          choices: choices.map { ["en": $0.english] },
                                          answer: choices.firstIndex(of: tag) ?? 0,
                                          why: ["en": "`\(tag.english)` · " + tag.note.resolved(language)], code: true)
            return Question(section: index, ask: ask)
        }
    }

    /// How many lessons come before the section the test stopped at. With nothing missed the learner begins at the last section.
    static func skipped(_ path: StudyPath, stoppedAt section: Int?) -> Int {
        guard !path.sections.isEmpty else { return 0 }
        let target = min(section ?? path.sections.count - 1, path.sections.count - 1)
        return path.sections.prefix(max(0, target)).reduce(0) { $0 + $1.lessons.count }
    }

    /// The section the learner begins at after passing `placed` lessons by.
    static func section(_ path: StudyPath, placed: Int) -> StudyPathSection? {
        guard placed > 0 else { return path.sections.first }
        var count = 0
        for section in path.sections {
            if count >= placed { return section }
            count += section.lessons.count
        }
        return path.sections.last
    }

    /// True while learning mode should greet the learner: never welcomed on this device, and nothing played or placed yet.
    static func needsWelcome(records: [String: StudyLessonRecord], xp: Int, placed: Int, defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: welcomedKey) && records.isEmpty && xp == 0 && placed == 0
    }
}
