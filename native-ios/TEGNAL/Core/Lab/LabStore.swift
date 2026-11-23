import Foundation
import GRDB
import Observation

/// Everything a learner has done in the lab. Stored as rows of `lab_records` (see `LabRecords.swift`).
struct LabProgress: Codable, Equatable, Sendable {
    /// Engraved cards, by episode id (`<course>/<episode>` for an imported course, see `LabStore.key`), with when each was engraved.
    var cards: [String: Date] = [:]
    /// 망작 hung in the gallery, by fail id (namespaced like cards).
    var fails: [String: Date] = [:]
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
    /// True once a learner who already had tag-study progress was given that course.
    var grandfathered = false
}

struct LabPurchase: Codable, Equatable, Sendable {
    /// What it cost, so a later price change does not move the balance.
    var price: Int
    var count: Int
    var date: Date
    /// For a course: how many of its lessons were finished when it was bought. Only lessons after that pay.
    var baseline: Int?
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
    var total: Int { cardReward + failReward }
}

/// Learning mode's records and money: every deck course's cards and 망작, the shop's purchases, the cheat sheet and the diagnosis.
/// One shared store, saved after every change. `course` is the deck on screen; the AI lab (`main`) alone pays 연구비.
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
    let shop: LabShop
    let diagnosis: LabDiagnosis?
    private(set) var progress: LabProgress
    /// The cheat-sheet edition shown: the newest of the bundled, saved and downloaded copies.
    private(set) var edition: LabEdition?
    /// Lessons of bought courses finished so far, by course id. Read from the courses' own stores.
    private(set) var courseLessons: [String: Int] = [:]
    /// Where the records are kept: the image database once it is reached, so they travel in iCloud sync and backups.
    private var records: LabRecordStore

    init(course: LabCourse = .bundled, shop: LabShop = .bundled, diagnosis: LabDiagnosis? = .bundled, records: LabRecordStore = LabMemoryRecords(), edition: LabEdition? = LabEdition.newest()) {
        self.main = course
        self.course = course
        self.shop = shop
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

    /// Shows another deck course. Its cards, 망작 and rate are read from now on; the money stays the AI lab's.
    func show(course: LabCourse) {
        guard course.id != self.course.id || course.episodes.count != self.course.episodes.count else { return }
        self.course = course
    }

    /// Where a card or 망작 of the course on screen is recorded. The AI lab keeps its plain ids, as it always has; an imported
    /// course's are put under its id, so two courses never meet.
    func key(_ id: String) -> String { Self.key(id, in: course) }
    nonisolated static func key(_ id: String, in course: LabCourse) -> String { course.imported ? course.id + "/" + id : id }

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
        if first { progress.cards[key(episode.id)] = LabStore.now; save() }
        let left = episode.fails.filter { progress.fails[key($0.id)] == nil }.count
        let pays = !course.imported
        let finished = course.season(of: episode).flatMap { first && complete($0) ? $0.number : nil }
        return LabEngraving(before: before, after: rate, cardReward: first && pays ? episode.reward : 0, failReward: pays ? failsHung * course.info.rewards.fail : 0,
                            failsHung: failsHung, failsLeft: left, first: first, season: finished)
    }

    // MARK: 망작

    func hung(_ fail: LabFail) -> Bool { progress.fails[key(fail.id)] != nil }

    /// What hanging one 망작 pays in the course on screen: nothing in an imported course.
    var failReward: Int { course.imported ? 0 : course.info.rewards.fail }

    /// Hangs a 망작 in the gallery. True the first time, when it also pays.
    @discardableResult
    func hang(_ fail: LabFail) -> Bool {
        guard progress.fails[key(fail.id)] == nil else { return false }
        progress.fails[key(fail.id)] = LabStore.now
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

    // MARK: 연구비

    /// Only the AI lab pays: its cards, its 망작, cheat-sheet editions and lessons of bought courses. Imported courses pay nothing.
    var income: Int {
        let cards = main.episodes.filter { progress.cards[$0.id] != nil }.reduce(0) { $0 + $1.reward }
        let fails = main.fails.filter { progress.fails[$0.id] != nil }.count * main.info.rewards.fail
        let editions = progress.editions.values.reduce(0, +)
        let courses = progress.purchases.reduce(0) { total, entry in
            guard let baseline = entry.value.baseline, let done = courseLessons[entry.key] else { return total }
            return total + max(0, done - baseline) * main.info.rewards.courseLesson
        }
        return cards + fails + editions + courses
    }
    var spent: Int { progress.purchases.values.reduce(0) { $0 + $1.price * $1.count } }
    var balance: Int { income - spent }

    func owns(_ id: String) -> Bool { (progress.purchases[id]?.count ?? 0) > 0 }
    var ownsTagCourse: Bool { owns(Self.tagCourse) }

    enum BuyResult: Equatable { case bought, owned, short(Int), unavailable }

    func canBuy(_ item: LabShopItem) -> BuyResult {
        guard !item.isSoon, let price = item.price else { return .unavailable }
        if owns(item.id), !item.isRepeat { return .owned }
        return balance >= price ? .bought : .short(price - balance)
    }

    @discardableResult
    func buy(_ item: LabShopItem) -> BuyResult {
        let result = canBuy(item)
        guard result == .bought, let price = item.price else { return result }
        var entry = progress.purchases[item.id] ?? LabPurchase(price: price, count: 0, date: LabStore.now)
        entry.count += 1
        entry.date = LabStore.now
        if item.kind == "course" { entry.baseline = courseLessons[item.id] ?? 0 }
        progress.purchases[item.id] = entry
        save()
        return .bought
    }

    /// Tells the store how many lessons of a course are finished, so its lessons can pay.
    func count(lessons: Int, of course: String) {
        if courseLessons[course] != lessons { courseLessons[course] = lessons }
    }

    /// A learner who studied tags before the lab came keeps the course, free, and is paid only for lessons after this.
    func grandfather(lessons: Int, xp: Int) {
        guard !progress.grandfathered else { return }
        progress.grandfathered = true
        if (lessons > 0 || xp > 0), progress.purchases[Self.tagCourse] == nil {
            progress.purchases[Self.tagCourse] = LabPurchase(price: 0, count: 1, date: LabStore.now, baseline: lessons)
        }
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

    /// Starts learning mode's records over: every course's cards, the gallery, money and purchases. A course given to an earlier learner is given again on the next visit.
    func reset() {
        progress = LabProgress()
        save()
    }

    #if DEBUG
    /// Test arguments: `--lab-reset` starts over; `--lab-seed=<episode>` engraves every card before that episode;
    /// `--lab-fails=<n>` hangs the first n 망작; `--lab-greeted` skips the welcome check; `--lab-income=<n>` adds 연구비.
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
        if arguments.contains("--lab-greeted") || arguments.contains(where: { $0.hasPrefix("--lab-seed=") }) { progress.greeted = true; progress.grandfathered = true }
        if let extra = value("--lab-income").flatMap(Int.init) { progress.editions["test-income"] = extra }
        // The tag course's own UI tests enter it from the library, as a learner who owns it.
        if arguments.contains("--study-ui-test"), progress.purchases[Self.tagCourse] == nil {
            progress.purchases[Self.tagCourse] = LabPurchase(price: 0, count: 1, date: LabStore.now, baseline: 0)
            progress.grandfathered = true
            save()
        }
        if arguments.contains(where: { $0.hasPrefix("--lab-") }) { save() }
    }
    #endif
}
