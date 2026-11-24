import Foundation
import GRDB
import Observation

/// Everything a learner has done in the lab. Stored as rows of `lab_records` (see `LabRecords.swift`).
struct LabProgress: Codable, Equatable, Sendable {
    /// Engraved cards, by episode id (`<course>/<episode>` for an imported course, see `LabStore.key`), with when each was engraved.
    var cards: [String: Date] = [:]
    /// 망작 hung in the gallery, by fail id (namespaced like cards).
    var fails: [String: Date] = [:]
    /// The 보석 each card and 망작 paid when it was earned, by the same ids. Kept so that a later change to the amounts in the
    /// course files never moves a balance already earned. Missing for records written before amounts were kept: those count
    /// at the course's present amount.
    var cardGems: [String: Int] = [:]
    var failGems: [String: Int] = [:]
    /// The 보석 each finished season of the AI lab paid, by season number.
    var seasonGems: [String: Int] = [:]
    /// The 보석 2D AI 배우기 paid, by record key: `lesson:<course>/<lesson>` (finished), `stars:<course>/<lesson>` (three stars) and
    /// `section:<course>/<section>` (every lesson finished). Each pays once; resetting the course's progress takes nothing back.
    var coursePaid: [String: Int] = [:]
    /// Cheat-sheet editions read, by edition id, with what each paid.
    var editions: [String: Int] = [:]
    /// The newest edition the learner has looked at, so a newer one can be pointed out.
    var seenEdition: String?
    /// What was bought, by shop item id.
    var purchases: [String: LabPurchase] = [:]
    /// The diagnosis type on card No. 000, once the check has been taken.
    var type: String?
    var diagnosed: Date?
    /// True once the welcome check has been offered, taken or skipped.
    var greeted = false
    /// True once a learner who studied 2D AI 배우기 before it was sold has been told the course now opens from the shop.
    var legacyNoticed = false
    /// How many times each deck course was finished and started over, by course id. Each round keeps its cards and 망작 under
    /// keys of its own (`LabStore.key`), so earlier rounds stay in the records: what they paid stays paid, and a sync can never
    /// bring an old round's cards back into the new one.
    var rounds: [String: Int] = [:]
}

struct LabPurchase: Codable, Equatable, Sendable {
    /// What it cost, so a later price change does not move the balance.
    var price: Int
    var count: Int
    var date: Date
    /// Tickets each purchase brought, for ticket goods.
    var each: Int? = nil
}

/// What settling 2D AI 배우기 paid, by kind, for the treasure chest a lesson opens.
struct LabTagPayout: Hashable, Sendable {
    var lesson = 0
    var stars = 0
    var section = 0
    var total: Int { lesson + stars + section }
}

/// What a card's engraving added, for the reward screen.
struct LabEngraving: Equatable, Sendable {
    var before: Int
    var after: Int
    var cardReward: Int
    var failReward: Int
    var failsHung: Int
    var failsLeft: Int
    var first: Bool
    /// The number of the season this card finished, the first time it was finished.
    var season: Int? = nil
    /// What finishing that season paid.
    var seasonReward = 0
    var total: Int { cardReward + failReward + seasonReward }
}

/// Learning mode's records and money: every deck course's cards and 망작, the shop's purchases, the cheat sheet and the diagnosis.
/// One shared store, saved after every change. `course` is the deck on screen. 보석, the one currency of learning mode, is paid by
/// the AI lab (`main`) and by the courses bought in its shop; imported courses pay nothing.
@MainActor @Observable
final class LabStore {
    static let shared = LabStore()
    static let tagCourse = "course.tags"
    /// Times are kept to the whole second, so they read back from the database exactly as written.
    nonisolated static var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()) }

    /// The bundled AI lab: what pays, and what the cheat sheet and diagnosis belong to.
    let main: LabCourse
    /// The deck course on screen: the AI lab, or one the learner imported.
    private(set) var course: LabCourse
    /// What the shop sells: the list last read from TEGNAL's server, or, until one is read, the few goods the app carries
    /// (`LabShop.builtIn`: the 2D course and the prompt analyzer, so they can be bought offline).
    private(set) var shop: LabShop
    private(set) var shopState: ShopState
    let diagnosis: LabDiagnosis?
    private(set) var progress: LabProgress
    /// The cheat-sheet edition shown: the newest of the bundled, saved and downloaded copies.
    private(set) var edition: LabEdition?
    /// Where the records are kept: the image database once it is reached, so they travel in iCloud sync and backups.
    private var records: LabRecordStore

    /// Where the shop list stands. `newer`: the server's list is for a later app.
    enum ShopState: Equatable { case loading, ready, failed, newer }

    init(course: LabCourse = .bundled, shop: LabShop? = LabShopSource.saved(), diagnosis: LabDiagnosis? = .bundled, records: LabRecordStore = LabMemoryRecords(), edition: LabEdition? = LabEdition.newest()) {
        self.main = course
        self.course = course
        // Until a list from the server is read, the goods the app carries are for sale.
        self.shop = shop ?? .builtIn
        shopState = shop == nil ? .loading : .ready
        self.diagnosis = diagnosis
        self.records = records
        self.edition = edition
        progress = LabProgress(records: (try? records.all()) ?? [])
    }

    /// Reads the records from the image database. Called when the app starts, before anything asks what is owned.
    func attach(_ database: DatabaseQueue) {
        records = LabDatabaseRecords(database: database)
        reload()
        #if DEBUG
        applyTestArguments()
        #endif
    }

    /// Reads the records again, as after a sync or a restored backup.
    func reload() {
        let next = LabProgress(records: (try? records.all()) ?? [])
        if next != progress { progress = next }
    }

    private func save() {
        do { try records.replace(with: progress.records) } catch { assertionFailure("Lab records could not be saved: \(error)") }
    }

    /// Reads the shop list from TEGNAL's server. A list that cannot be read keeps the last one; a list for a later app hides it.
    func refreshShop(market: AddonMarket = .live) async {
        do {
            let fresh = try await LabShopSource.fetch(market: market)
            shop = fresh
            shopState = .ready
        } catch LabShopError.newer {
            // An old list is not sold from once a newer one is out; the goods the app carries still are.
            shop = .builtIn
            shopState = .newer
        } catch {
            if shopState != .ready { shopState = .failed }
        }
    }

    /// Uses a list read elsewhere, as in tests.
    func use(_ shop: LabShop) {
        self.shop = shop
        shopState = .ready
    }

    /// Shows another deck course. Its cards, 망작 and rate are read from now on; the money stays the AI lab's.
    func show(course: LabCourse) {
        guard course.id != self.course.id || course.episodes.count != self.course.episodes.count else { return }
        self.course = course
    }

    /// Where a card or 망작 of the course on screen is recorded. The AI lab keeps its plain ids, as it always has; an imported
    /// course's are put under its id, so two courses never meet; a course started over puts the round in front (`r1/…`).
    func key(_ id: String) -> String { Self.key(id, in: course, round: round) }
    nonisolated static func key(_ id: String, in course: LabCourse, round: Int = 0) -> String {
        let base = course.imported ? course.id + "/" + id : id
        return round > 0 ? "r\(round)/" + base : base
    }

    // MARK: Starting over

    /// How many times the course on screen was finished and started over.
    var round: Int { progress.rounds[course.id] ?? 0 }
    func round(of course: LabCourse) -> Int { progress.rounds[course.id] ?? 0 }
    /// Every card of the course on screen engraved in this round.
    var finished: Bool { !course.episodes.isEmpty && course.episodes.allSatisfy(earned) }
    /// A round after the first pays a quarter of every amount (user, 2026-11-25).
    static let replayShare = 4
    func paid(_ amount: Int) -> Int { Self.share(amount, round: round) }
    nonisolated static func share(_ amount: Int, round: Int) -> Int { round > 0 ? Int((Double(amount) / Double(replayShare)).rounded()) : amount }

    /// Starts a finished course over: an empty deck and gallery and the rate back at its start. What earlier rounds paid stays;
    /// the cheat sheet and the diagnosis stay as they are.
    func startOver() {
        guard finished else { return }
        progress.rounds[course.id] = round + 1
        save()
    }
    /// True when the course on screen pays 보석: the AI lab, and the courses bought in the shop.
    var pays: Bool { !course.imported || course.official }

    // MARK: Cards

    enum CardState: Equatable { case earned, open, locked }

    func earned(_ episode: LabEpisode) -> Bool { progress.cards[key(episode.id)] != nil }

    /// A season opens once the season it waits for is finished.
    func opened(_ season: LabSeason) -> Bool {
        guard let after = season.opensAfter, let previous = course.seasons.first(where: { $0.number == after }) else { return true }
        return complete(previous)
    }

    func complete(_ season: LabSeason) -> Bool { season.episodes.allSatisfy { progress.cards[key($0)] != nil } }

    func state(_ episode: LabEpisode) -> CardState {
        if earned(episode) { return .earned }
        guard let season = course.season(of: episode), opened(season) else { return .locked }
        if season.free { return .open }
        // In a fixed season only the first card not yet engraved is open.
        let first = season.episodes.first { progress.cards[key($0)] == nil }
        return first == episode.id ? .open : .locked
    }

    /// The card the deck offers next: the first open one in deck order.
    var next: LabEpisode? { course.episodes.first { state($0) == .open } }
    var earnedCards: [LabEpisode] { course.episodes.filter(earned) }
    /// The ids of the course's engraved episodes, as the deck tracks them.
    var earnedIDs: Set<String> { Set(earnedCards.map(\.id)) }
    /// When a card of the course on screen was engraved.
    func engraved(_ episode: LabEpisode) -> Date? { progress.cards[key(episode.id)] }
    /// Card No. 000 and the welcome check belong to the AI lab.
    var offersDiagnosis: Bool { !course.imported && diagnosis != nil }
    /// The episodes still open to pick, more than one once the free seasons are reached.
    var openCards: [LabEpisode] { course.episodes.filter { state($0) == .open } }

    /// The course's rate (the AI lab's AI 성능 인출률): the base plus every engraved card's share. It never goes down.
    var rate: Int { course.base + earnedCards.reduce(0) { $0 + $1.impact } }

    /// Engraves an episode's card. Playing an engraved card again changes nothing but its fails.
    @discardableResult
    func engrave(_ episode: LabEpisode, failsHung: Int) -> LabEngraving {
        let before = rate
        let first = progress.cards[key(episode.id)] == nil
        let pays = self.pays
        if first {
            progress.cards[key(episode.id)] = LabStore.now
            if pays { progress.cardGems[key(episode.id)] = paid(episode.reward) }
            save()
        }
        let left = episode.fails.filter { progress.fails[key($0.id)] == nil }.count
        let finished = course.season(of: episode).flatMap { first && complete($0) ? $0.number : nil }
        var seasonReward = 0
        if let finished, pays, course.info.rewards.season > 0, progress.seasonGems[key(String(finished))] == nil {
            seasonReward = paid(course.info.rewards.season)
            progress.seasonGems[key(String(finished))] = seasonReward
            save()
        }
        return LabEngraving(before: before, after: rate, cardReward: first && pays ? paid(episode.reward) : 0, failReward: failsHung * failReward,
                            failsHung: failsHung, failsLeft: left, first: first, season: finished, seasonReward: seasonReward)
    }

    // MARK: 망작

    func hung(_ fail: LabFail) -> Bool { progress.fails[key(fail.id)] != nil }

    /// What hanging one 망작 pays in the course on screen: nothing in an imported course.
    var failReward: Int { pays ? paid(course.info.rewards.fail) : 0 }

    /// Hangs a 망작 in the gallery. True the first time, when it also pays.
    @discardableResult
    func hang(_ fail: LabFail) -> Bool {
        guard progress.fails[key(fail.id)] == nil else { return false }
        progress.fails[key(fail.id)] = LabStore.now
        if failReward > 0 { progress.failGems[key(fail.id)] = failReward }
        save()
        return true
    }

    /// The gallery number of a 망작: its place among every trap of the course, from 1.
    func number(_ fail: LabFail) -> Int { (course.fails.firstIndex { $0.id == fail.id } ?? 0) + 1 }

    // MARK: Cheat sheet

    /// Whether a section of the sheet is open: the AI lab card it waits for has been engraved.
    func opened(_ section: LabSheetSection) -> Bool {
        guard let card = section.opens else { return true }
        return progress.cards[card] != nil
    }

    /// True when an edition newer than the last one looked at is waiting, and the learner can read part of it.
    var editionWaiting: Bool {
        guard let edition, edition.sections.contains(where: opened) else { return false }
        return progress.seenEdition != edition.id
    }

    /// Marks the shown edition as looked at. Reading an edition for the first time pays once, when at least one section is open.
    @discardableResult
    func read() -> Int {
        guard let edition, edition.sections.contains(where: opened) else { return 0 }
        progress.seenEdition = edition.id
        var paid = 0
        if progress.editions[edition.id] == nil {
            paid = edition.reward ?? main.info.rewards.edition
            progress.editions[edition.id] = paid
        }
        save()
        return paid
    }

    func show(_ edition: LabEdition) {
        if let current = self.edition, current.date > edition.date { return }
        self.edition = edition
    }

    // MARK: 보석

    /// What has been earned, each at the amount it paid when earned: the AI lab's cards, 망작 and seasons, cheat-sheet editions,
    /// and 2D AI 배우기's lessons, three-star lessons and sections. Imported courses pay nothing.
    var income: Int {
        let cards = main.episodes.filter { progress.cards[$0.id] != nil }.reduce(0) { $0 + (progress.cardGems[$1.id] ?? $1.reward) }
        let fails = main.fails.filter { progress.fails[$0.id] != nil }.reduce(0) { $0 + (progress.failGems[$1.id] ?? main.info.rewards.fail) }
        let seasons = main.seasons.filter { $0.episodes.allSatisfy { progress.cards[$0] != nil } }
            .reduce(0) { $0 + (progress.seasonGems[String($1.number)] ?? main.info.rewards.season) }
        let editions = progress.editions.values.reduce(0, +)
        // The courses bought in the shop keep theirs under `<course>/…`; an imported course's records there never hold an amount.
        func namespaced(_ paid: [String: Int]) -> Int { paid.filter { $0.key.contains("/") }.values.reduce(0, +) }
        let official = namespaced(progress.cardGems) + namespaced(progress.failGems) + namespaced(progress.seasonGems)
        return cards + fails + seasons + editions + official + progress.coursePaid.values.reduce(0, +)
    }
    var spent: Int { progress.purchases.values.reduce(0) { $0 + $1.price * $1.count } }
    var balance: Int { income - spent }

    func owns(_ id: String) -> Bool { (progress.purchases[id]?.count ?? 0) > 0 }
    var ownsTagCourse: Bool { owns(Self.tagCourse) }
    /// True once the feature's key was bought (`feature.<id>`). Needs no shop list: the record says it.
    func unlocked(_ feature: LabFeature) -> Bool { owns(feature.item) }
    /// Tickets bought. Nothing spends them yet: drawing with them needs TEGNAL's own generation server (`docs/features/live-shop.md` §5).
    var tickets: Int { progress.purchases.values.reduce(0) { $0 + $1.count * ($1.each ?? 0) } }

    /// `needs`: another item (by id) must be owned first. `update`: this app does not know the item; a newer one does.
    enum BuyResult: Equatable { case bought, owned, short(Int), needs(String), unavailable, update }

    func canBuy(_ item: LabShopItem) -> BuyResult {
        guard item.supported else { return .update }
        guard !item.isSoon, let price = item.price else { return .unavailable }
        if owns(item.id), !item.isRepeat { return .owned }
        if let needed = item.requires, !owns(needed) { return .needs(needed) }
        return balance >= price ? .bought : .short(price - balance)
    }

    @discardableResult
    func buy(_ item: LabShopItem) -> BuyResult {
        let result = canBuy(item)
        guard result == .bought, let price = item.price else { return result }
        var entry = progress.purchases[item.id] ?? LabPurchase(price: price, count: 0, date: LabStore.now)
        entry.count += 1
        entry.date = LabStore.now
        if item.kind == "ticket" { entry.each = item.count }
        progress.purchases[item.id] = entry
        save()
        return .bought
    }

    // MARK: 2D AI 배우기

    /// Pays what 2D AI 배우기's finished lessons, three-star lessons and finished sections have not paid yet, and returns the
    /// 보석 paid now. Progress from before the course was sold pays the same way, once; the course must still be bought to go on.
    /// Lessons of imported courses (`course:<id>:…`) are not on the bundled path, so they pay nothing.
    /// A round after the first (`tagRound`) pays a quarter, under keys of its own (`lesson:course.tags/r1/<lesson>`).
    @discardableResult
    func settleTagCourse(in studyStore: StudyStore, path: StudyPath = .bundled) -> LabTagPayout {
        let round = tagRound
        guard let records = try? studyStore.lessons(round: round) else { return LabTagPayout() }
        let rates = main.info.rewards
        var paid = LabTagPayout()
        func pay(_ kind: String, _ id: String, _ full: Int) {
            let key = "\(kind):\(Self.tagCourse)/" + StudyStore.lessonKey(id, round: round)
            let amount = Self.share(full, round: round)
            guard amount > 0, progress.coursePaid[key] == nil else { return }
            progress.coursePaid[key] = amount
            switch kind {
            case "lesson": paid.lesson += amount
            case "stars": paid.stars += amount
            default: paid.section += amount
            }
        }
        for section in path.sections {
            for lesson in section.lessons {
                guard let record = records[lesson.id] else { continue }
                pay("lesson", lesson.id, rates.courseLesson)
                if record.stars >= 3 { pay("stars", lesson.id, rates.courseStars) }
            }
            if !section.lessons.isEmpty, section.lessons.allSatisfy({ records[$0.id] != nil }) { pay("section", section.id, rates.courseSection) }
        }
        if paid.total > 0 { save() }
        return paid
    }

    /// What 2D AI 배우기 has paid so far, and for how many lessons of its first round.
    var tagCoursePaid: (gems: Int, lessons: Int) {
        let prefix = ":" + Self.tagCourse + "/"
        let entries = progress.coursePaid.filter { $0.key.contains(prefix) }
        let lesson = "lesson" + prefix
        let first = entries.keys.filter { $0.hasPrefix(lesson) && StudyStore.lessonRound(String($0.dropFirst(lesson.count))).round == 0 }
        return (entries.values.reduce(0, +), first.count)
    }

    /// How many times 2D AI 배우기 was finished and started over.
    var tagRound: Int { progress.rounds[Self.tagCourse] ?? 0 }

    /// True when every lesson on 2D AI 배우기's path is finished in the round being played.
    static func tagCourseFinished(_ records: [String: StudyLessonRecord], path: StudyPath = .bundled) -> Bool {
        let lessons = path.lessons
        return !lessons.isEmpty && lessons.allSatisfy { records[$0.id] != nil }
    }

    /// Starts a finished 2D AI 배우기 over: the path back at its first lesson, paying a quarter. What earlier rounds paid stays,
    /// and so do experience, badges and what each tag has learned.
    func startTagCourseOver(in studyStore: StudyStore, path: StudyPath = .bundled) {
        guard Self.tagCourseFinished((try? studyStore.lessons(round: tagRound)) ?? [:], path: path) else { return }
        progress.rounds[Self.tagCourse] = tagRound + 1
        save()
    }

    /// True when a learner who studied 2D AI 배우기 before it was sold should be told it now opens from the shop.
    var owesLegacyNotice: Bool { !progress.legacyNoticed && !ownsTagCourse && tagCoursePaid.gems > 0 }

    func noticeLegacy() {
        guard !progress.legacyNoticed else { return }
        progress.legacyNoticed = true
        save()
    }

    // MARK: Diagnosis

    var type: LabType? { diagnosis?.type(progress.type) }

    func diagnose(_ type: LabType) {
        progress.type = type.id
        progress.diagnosed = LabStore.now
        progress.greeted = true
        save()
    }

    func greeted() {
        guard !progress.greeted else { return }
        progress.greeted = true
        save()
    }

    /// Starts learning mode's records over: every course's cards, the gallery, money and purchases. 2D AI 배우기's progress stays in
    /// its own store, so it pays again on the next visit.
    func reset() {
        progress = LabProgress()
        save()
        HomeScenes.choose(nil)
    }

    #if DEBUG
    /// Test arguments: `--lab-reset` starts over; `--lab-seed=<episode>` engraves every card before that episode;
    /// `--lab-fails=<n>` hangs the first n 망작; `--lab-greeted` skips the welcome check; `--lab-income=<n>` adds 보석.
    private func applyTestArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? { arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
        if arguments.contains("--lab-reset") { progress = LabProgress() }
        if let target = value("--lab-seed") {
            for episode in main.episodes.prefix(while: { $0.id != target }) where progress.cards[episode.id] == nil {
                progress.cards[episode.id] = LabStore.now
            }
        }
        if let count = value("--lab-fails").flatMap(Int.init) {
            for fail in main.fails.prefix(count) where progress.fails[fail.id] == nil { progress.fails[fail.id] = LabStore.now }
        }
        if arguments.contains("--lab-greeted") || arguments.contains(where: { $0.hasPrefix("--lab-seed=") }) { progress.greeted = true; progress.legacyNoticed = true }
        if let extra = value("--lab-income").flatMap(Int.init) { progress.editions["test-income"] = extra }
        // `--lab-own=<item>` owns a shop item, as if it had been bought (repeatable).
        for argument in arguments where argument.hasPrefix("--lab-own=") {
            let id = String(argument.dropFirst(10))
            if progress.purchases[id] == nil { progress.purchases[id] = LabPurchase(price: 0, count: 1, date: LabStore.now) }
        }
        // The tag course's own UI tests enter it from the library, as a learner who owns it.
        if arguments.contains("--study-ui-test"), progress.purchases[Self.tagCourse] == nil {
            progress.purchases[Self.tagCourse] = LabPurchase(price: 0, count: 1, date: LabStore.now)
            progress.legacyNoticed = true
            save()
        }
        if arguments.contains(where: { $0.hasPrefix("--lab-") }) { save() }
    }
    #endif
}
