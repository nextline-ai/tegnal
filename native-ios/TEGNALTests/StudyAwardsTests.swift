import XCTest
import GRDB
@testable import TEGNAL

final class StudyAwardsTests: XCTestCase {
    // MARK: - The badges

    func testThereAreThirtyNineBadgesForTheBundledPathWithUniqueIDsAndTheFamiliesInOrder() {
        let path = StudyPath.bundled
        let all = StudyAward.all(path)
        XCTAssertEqual(all.count, 39)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "Ids repeat")
        func goals(_ family: StudyAward.Family) -> [Int] { all.filter { $0.family == family }.map(\.goal) }
        XCTAssertEqual(all.filter { $0.family == .lessons }.map(\.id), ["lessons-1", "lessons-10", "lessons-30", "lessons-all"])
        XCTAssertEqual(goals(.lessons), [1, 10, 30, path.lessons.count])
        XCTAssertEqual(goals(.streak), [3, 7, 14, 30])
        XCTAssertEqual(goals(.tags), [10, 50, 150, 300])
        XCTAssertEqual(goals(.perfect), [1, 10, 25])
        XCTAssertEqual(goals(.combo), [5, 10, 20])
        XCTAssertEqual(goals(.xp), [100, 500, 2000])
        XCTAssertEqual(all.filter { $0.family == .studio }.map(\.id), ["studio-key", "studio-1", "studio-3", "studio-10", "studio-50"])
        XCTAssertEqual(goals(.speed), [10, 20])
        XCTAssertEqual(all.filter { $0.family == .sections }.count, path.sections.filter { !$0.lessons.isEmpty }.count)
        let order = StudyAward.Family.allCases
        XCTAssertEqual(all.map(\.family).map { order.firstIndex(of: $0)! }, all.map(\.family).map { order.firstIndex(of: $0)! }.sorted(), "A family's badges sit together in family order")
        for award in all { XCTAssertGreaterThan(award.goal, 0, award.id); XCTAssertFalse(award.symbol.isEmpty, award.id) }
    }

    func testEachSectionWithLessonsHasOneBadgeCarryingItsColourTitleAndLessonCount() {
        let path = StudyPath.bundled
        let sections = StudyAward.all(path).filter { $0.family == .sections }
        XCTAssertEqual(sections.map(\.id), path.sections.filter { !$0.lessons.isEmpty }.map { "section-" + $0.id })
        for (award, section) in zip(sections, path.sections.filter { !$0.lessons.isEmpty }) {
            XCTAssertEqual(award.section, section.id)
            XCTAssertEqual(award.goal, section.lessons.count, section.id)
            XCTAssertEqual(award.color, section.color)
            XCTAssertEqual(award.sectionTitle, section.title)
        }
    }

    func testTheStudioBadgeForAdvancedSettingsAsksForTheAdvancedPictureCount() {
        XCTAssertEqual(StudyAward.advancedPictures, 3)
        XCTAssertEqual(StudyAward.all(StudyPath.bundled).first { $0.id == "studio-3" }?.goal, StudyAward.advancedPictures)
    }

    func testTheGraduateBadgeFollowsThePathLengthAndEmptySectionsGetNoBadge() {
        let path = StudyAwardsTests.path
        let all = StudyAward.all(path)
        XCTAssertEqual(all.first { $0.id == "lessons-all" }?.goal, 5)
        XCTAssertEqual(all.filter { $0.family == .sections }.map(\.id), ["section-a", "section-b"], "The empty section has no badge")
        XCTAssertEqual(StudyAward.all(StudyPath()).first { $0.id == "lessons-all" }?.goal, 1, "Never a goal of zero")
        XCTAssertEqual(StudyAward.all(StudyPath()).count, 39 - StudyPath.bundled.sections.filter { !$0.lessons.isEmpty }.count)
    }

    // MARK: - Facts

    private static func lesson(_ id: String) -> StudyPathLesson {
        StudyPathLesson(id: id, kind: .tags, symbol: "tag", title: ["en": id], tags: ["t1"])
    }
    /// Section a has three lessons, b has two, and c none.
    private static let path = StudyPath(version: 3, sections: [
        StudyPathSection(id: "a", title: ["en": "A"], summary: ["en": ""], color: "112233", lessons: ["a1", "a2", "a3"].map(lesson)),
        StudyPathSection(id: "b", title: ["en": "B"], summary: ["en": ""], color: "445566", lessons: ["b1", "b2"].map(lesson)),
        StudyPathSection(id: "c", title: ["en": "C"], summary: ["en": ""], color: "778899")])

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private var now: Date { utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))! }
    private func day(_ offset: Int, xp: Int = 0, answered: Int = 1) -> StudyDay {
        StudyDay(day: StudyDay.key(utc.date(byAdding: .day, value: -offset, to: now)!, calendar: utc), answered: answered, xp: xp)
    }
    private func facts(records: [String: StudyLessonRecord] = [:], days: [StudyDay] = [], progress: [String: StudyProgress] = [:], stats: [String: Int] = [:]) -> StudyFacts {
        StudyFacts(path: Self.path, records: records, days: days, progress: progress, stats: stats, now: now, calendar: utc)
    }
    private func record(_ id: String, stars: Int = 1) -> StudyLessonRecord { StudyLessonRecord(lesson: id, stars: stars, runs: 1) }
    private func award(_ id: String) -> StudyAward { StudyAward.all(Self.path).first { $0.id == id }! }

    func testFactsOfNothingAreZero() {
        let none = facts()
        XCTAssertEqual(StudyFacts(), StudyFacts())
        XCTAssertEqual([none.streak, none.learned, none.perfect, none.combo, none.xp, none.pictures, none.speed], [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(none.lessons, 0)
        XCTAssertFalse(none.key)
        for award in StudyAward.all(Self.path) { XCTAssertFalse(none.has(award), award.id); XCTAssertEqual(none.progress(award), 0, award.id) }
    }

    func testFactsCountOnlyFinishedLessonsThatAreInThePathAndPerSection() {
        let found = facts(records: ["a1": record("a1"), "a3": record("a3"), "b2": record("b2"), "gone": record("gone", stars: 3)])
        XCTAssertEqual(found.lessons, 3, "A lesson that left the path is not counted")
        XCTAssertEqual(found.sections, ["a": 2, "b": 1, "c": 0])
        XCTAssertEqual(found.perfect, 1, "Three stars count wherever the lesson is")
        XCTAssertEqual(found.value(for: award("section-a")), 2)
        XCTAssertEqual(found.value(for: award("section-b")), 1)
        XCTAssertFalse(found.has(award("section-a")))
        XCTAssertEqual(found.progress(award("section-a")), 2.0 / 3.0, accuracy: 1e-9)
        let everything = facts(records: Dictionary(uniqueKeysWithValues: ["a1", "a2", "a3", "b1", "b2"].map { ($0, record($0)) }))
        XCTAssertTrue(everything.has(award("section-a")))
        XCTAssertTrue(everything.has(award("section-b")))
        XCTAssertTrue(everything.has(award("lessons-all")))
        XCTAssertFalse(everything.has(award("lessons-10")))
        XCTAssertEqual(everything.progress(award("lessons-all")), 1)
    }

    func testPerfectCountsThreeStarLessonsOnly() {
        let found = facts(records: ["a1": record("a1", stars: 3), "a2": record("a2", stars: 2), "a3": record("a3", stars: 3), "b1": record("b1", stars: 1)])
        XCTAssertEqual(found.perfect, 2)
        XCTAssertEqual(found.value(for: award("perfect-1")), 2)
        XCTAssertTrue(found.has(award("perfect-1")))
        XCTAssertFalse(found.has(award("perfect-10")))
    }

    func testTheStreakIsTheLongerOfTheDaysRunAndTheStoredCounter() {
        let run = [day(0), day(1), day(2)]
        XCTAssertEqual(facts(days: run).streak, 3)
        XCTAssertEqual(facts(days: run, stats: [StudyCounter.streak: 5]).streak, 5, "A best run survives a missed day")
        XCTAssertEqual(facts(days: run, stats: [StudyCounter.streak: 1]).streak, 3)
        XCTAssertEqual(facts(days: [day(0), day(2)]).streak, 1, "A gap ends the run")
        XCTAssertEqual(facts(days: [day(1), day(2)]).streak, 2, "Yesterday still counts before today's study")
        XCTAssertEqual(facts(days: [], stats: [StudyCounter.streak: 7]).streak, 7)
        XCTAssertTrue(facts(days: run).has(award("streak-3")))
        XCTAssertFalse(facts(days: run).has(award("streak-7")))
    }

    func testLearnedCountsTagsAtTheLearnedStepAndXPSumsEveryDay() {
        let progress = ["t1": StudyProgress(tag: "t1", step: StudyProgress.learnedStep), "t2": StudyProgress(tag: "t2", step: StudyProgress.learnedStep - 1),
                        "t3": StudyProgress(tag: "t3", step: StudyProgress.lastStep)]
        let found = facts(days: [day(0, xp: 60), day(1, xp: 45), day(5, xp: 0)], progress: progress)
        XCTAssertEqual(found.learned, 2)
        XCTAssertEqual(found.xp, 105)
        XCTAssertTrue(found.has(award("xp-100")))
        XCTAssertFalse(found.has(award("xp-500")))
        XCTAssertFalse(found.has(award("tags-10")))
        XCTAssertEqual(found.progress(award("tags-10")), 0.2, accuracy: 1e-9)
    }

    func testCountersFeedComboPicturesSpeedAndTheKey() {
        let found = facts(stats: [StudyCounter.combo: 12, StudyCounter.pictures: 3, StudyCounter.speed: 10, StudyCounter.key: 1])
        XCTAssertEqual(found.combo, 12)
        XCTAssertEqual(found.pictures, 3)
        XCTAssertEqual(found.speed, 10)
        XCTAssertTrue(found.key)
        XCTAssertTrue(found.has(award("combo-10")))
        XCTAssertFalse(found.has(award("combo-20")))
        XCTAssertTrue(found.has(award("studio-key")))
        XCTAssertTrue(found.has(award("studio-1")))
        XCTAssertTrue(found.has(award("studio-3")))
        XCTAssertFalse(found.has(award("studio-10")))
        XCTAssertTrue(found.has(award("speed-10")))
        XCTAssertFalse(found.has(award("speed-20")))
        XCTAssertEqual(found.value(for: award("studio-key")), 1)
        XCTAssertEqual(facts(stats: [StudyCounter.pictures: 9]).value(for: award("studio-key")), 0, "Pictures do not stand in for the key")
        XCTAssertFalse(facts(stats: [StudyCounter.pictures: 9]).has(award("studio-key")))
        XCTAssertFalse(facts(stats: [StudyCounter.key: 0]).key)
    }

    func testProgressStopsAtOneAndAZeroGoalIsAlwaysDone() {
        let found = facts(stats: [StudyCounter.combo: 500])
        XCTAssertEqual(found.progress(award("combo-5")), 1)
        let free = StudyAward(id: "x", family: .xp, metal: .bronze, symbol: "x", title: "x", detail: "x", goal: 0)
        XCTAssertEqual(StudyFacts().progress(free), 1)
    }

    // MARK: - The store

    @MainActor func testGrantingRecordsABadgeOnceKeepsItsFirstDateAndMarkingSeenSticks() throws {
        let study = try BooruStore().studyStore
        XCTAssertTrue(try study.awards().isEmpty)
        let early = Date(timeIntervalSince1970: 1_000_000), late = Date(timeIntervalSince1970: 2_000_000)
        try study.grant(["a", "b"], now: early)
        try study.grant([], now: late)
        try study.grant(["a", "c"], seen: true, now: late)
        let found = try study.awards()
        XCTAssertEqual(Set(found.keys), ["a", "b", "c"])
        XCTAssertEqual(found["a"]?.earned, early, "An earlier date is not overwritten")
        XCTAssertEqual(found["a"]?.seen, false, "Nor is its seen flag")
        XCTAssertEqual(found["c"]?.earned, late)
        XCTAssertEqual(found["c"]?.seen, true)
        try study.markSeen(["a", "missing"])
        try study.markSeen([])
        XCTAssertEqual(try study.awards()["a"]?.seen, true)
        XCTAssertEqual(try study.awards()["b"]?.seen, false)
        XCTAssertNil(try study.awards()["missing"])
    }

    @MainActor func testRaisingACounterSetsItAndNeverLowersIt() throws {
        let study = try BooruStore().studyStore
        XCTAssertTrue(try study.stats().isEmpty)
        try study.raise("combo", to: 5)
        try study.raise("combo", to: 3)
        XCTAssertEqual(try study.stats()["combo"], 5)
        try study.raise("combo", to: 9)
        try study.raise("speed", to: 0)
        XCTAssertEqual(try study.stats(), ["combo": 9, "speed": 0])
    }

    @MainActor func testResetClearsBadgesAndCountersToo() throws {
        let study = try BooruStore().studyStore
        try study.grant(["a"])
        try study.raise("combo", to: 5)
        try study.earn(10, lesson: "a1", stars: 3)
        try study.reset()
        XCTAssertTrue(try study.awards().isEmpty)
        XCTAssertTrue(try study.stats().isEmpty)
        XCTAssertTrue(try study.lessons().isEmpty)
        XCTAssertTrue(try study.days().isEmpty)
    }

    @MainActor func testTheAwardTablesSurviveAReopenedDatabaseFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("awards-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("a.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("study") { try StudyStore.migrate($0) }
        migrator.registerMigration("game") { try StudyStore.migrateGame($0) }
        migrator.registerMigration("awards") { try StudyStore.migrateAwards($0) }
        try migrator.migrate(queue)
        let study = StudyStore(database: queue)
        try study.grant(["x"], now: Date(timeIntervalSince1970: 5))
        try study.raise("speed", to: 4)
        try migrator.migrate(queue)
        XCTAssertEqual(try study.awards()["x"]?.earned, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try study.stats()["speed"], 4)
    }

    // MARK: - Refresh

    @MainActor private func generation(key: String = "", pictures: Int = 0) throws -> GenerationStore {
        let name = "awards-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("awards-gen-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = GenerationStore(folder: folder, defaults: defaults, key: key, saveKey: { _ in true })
        for number in 0..<pictures { try store.add(Data([0x89, 0x50, 0x4E, 0x47, UInt8(number)]), prompt: "p\(number)", settings: GenerationSettings()) }
        return store
    }

    @MainActor func testRefreshWithNothingDoneGrantsNothing() throws {
        let store = try BooruStore()
        XCTAssertEqual(StudyAwards.refresh(store, path: Self.path, generation: try generation()), [])
        XCTAssertTrue(try store.studyStore.awards().isEmpty)
    }

    @MainActor func testRefreshGrantsWhatTheFactsEarnedAndReturnsTheUnseenOnesInGalleryOrderUntilTheyAreMarkedSeen() throws {
        let store = try BooruStore()
        try store.studyStore.earn(120, lesson: "a1", stars: 3)
        let gallery = StudyAward.all(Self.path).map(\.id)
        let first = StudyAwards.refresh(store, path: Self.path, generation: try generation())
        XCTAssertEqual(first.map(\.id), ["lessons-1", "perfect-1", "xp-100"])
        XCTAssertEqual(first.map(\.id), first.map(\.id).sorted { gallery.firstIndex(of: $0)! < gallery.firstIndex(of: $1)! })
        XCTAssertEqual(Set(try store.studyStore.awards().keys), ["lessons-1", "perfect-1", "xp-100"])

        let again = StudyAwards.refresh(store, path: Self.path, generation: try generation())
        XCTAssertEqual(again.map(\.id), first.map(\.id), "Still unseen")

        try store.studyStore.markSeen(["lessons-1", "xp-100"])
        XCTAssertEqual(StudyAwards.refresh(store, path: Self.path, generation: try generation()).map(\.id), ["perfect-1"])
        try store.studyStore.markSeen(["perfect-1"])
        XCTAssertEqual(StudyAwards.refresh(store, path: Self.path, generation: try generation()), [])
        XCTAssertEqual(Set(try store.studyStore.awards().keys), ["lessons-1", "perfect-1", "xp-100"], "Nothing is granted twice")
    }

    @MainActor func testRefreshReadsTheGeneratorsPicturesAndKeyIntoCounters() throws {
        let store = try BooruStore()
        let earned = StudyAwards.refresh(store, path: Self.path, generation: try generation(key: "secret", pictures: 3))
        XCTAssertEqual(earned.map(\.id), ["studio-key", "studio-1", "studio-3"])
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.pictures], 3)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.key], 1)

        // Pictures deleted later do not take a badge or its counter back.
        XCTAssertEqual(StudyAwards.refresh(store, path: Self.path, generation: try generation()).map(\.id), ["studio-key", "studio-1", "studio-3"])
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.pictures], 3)
        XCTAssertEqual(Set(try store.studyStore.awards().keys), ["studio-key", "studio-1", "studio-3"])
    }

    @MainActor func testRefreshKeepsALongestStreakAndCompletesASectionBadge() throws {
        let store = try BooruStore()
        for id in ["a1", "a2", "a3"] { try store.studyStore.earn(10, lesson: id, stars: 1) }
        let earned = StudyAwards.refresh(store, path: Self.path, generation: try generation())
        XCTAssertTrue(earned.contains { $0.id == "section-a" })
        XCTAssertFalse(earned.contains { $0.id == "section-b" })
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.streak], 1)
        XCTAssertEqual(StudyAwards.facts(store, path: Self.path).sections["a"], 3)
    }

    // MARK: - Speed round

    private var curriculum: StudyCurriculum {
        StudyCurriculum(units: [StudyUnit(id: "u", title: ["en": "U"], summary: ["en": ""], groups: [
            StudyGroup(id: "g", title: ["en": "G"], tags: (1...6).map { StudyTag(name: "s\($0)", ko: "s\($0)", ja: "s\($0)", note: ["en": "s\($0)"]) })])])
    }

    @MainActor private func met(_ store: BooruStore, _ names: [String]) throws {
        for name in names { try store.studyStore.answer(name, right: true) }
    }

    @MainActor func testTheSpeedRoundAsksOnlyTagsAlreadyAnsweredAndNeedsFourOfThem() throws {
        let store = try BooruStore()
        try met(store, ["s1", "s2", "s3"])
        let few = StudySpeedRound(store: store, curriculum: curriculum)
        XCTAssertEqual(few.tags.map(\.name), ["s1", "s2", "s3"])
        XCTAssertFalse(few.canPlay)
        few.start()
        XCTAssertEqual(few.phase, .ready, "Three tags cannot offer four answers")
        XCTAssertNil(few.question)

        try store.studyStore.answer("s4", right: false)
        let four = StudySpeedRound(store: store, curriculum: curriculum)
        XCTAssertEqual(four.tags.map(\.name), ["s1", "s2", "s3", "s4"], "A wrong answer is an answer too")
        XCTAssertTrue(four.canPlay)
        XCTAssertEqual(StudySpeedRound.met([:], curriculum: curriculum), [])
        XCTAssertEqual(StudySpeedRound.met(["s5": StudyProgress(tag: "s5"), "x": StudyProgress(tag: "x", correct: 1)], curriculum: curriculum), [], "A new tag and an untaught tag are not met")
    }

    @MainActor func testTheRewardIsTheScoreCappedAtTwentyAndNeverNegative() {
        XCTAssertEqual(StudySpeedRound.reward(0), 0)
        XCTAssertEqual(StudySpeedRound.reward(7), 7)
        XCTAssertEqual(StudySpeedRound.reward(20), 20)
        XCTAssertEqual(StudySpeedRound.reward(35), 20)
        XCTAssertEqual(StudySpeedRound.reward(-4), 0)
    }

    @MainActor private func playing(_ store: BooruStore) throws -> StudySpeedRound {
        try met(store, ["s1", "s2", "s3", "s4", "s5"])
        let round = StudySpeedRound(store: store, curriculum: curriculum)
        round.start()
        return round
    }

    @MainActor func testStartingAsksAFirstQuestionWithFourChoicesAndTheRightAnswerAmongThem() throws {
        let round = try playing(try BooruStore())
        XCTAssertEqual(round.phase, .playing)
        let question = try XCTUnwrap(round.question)
        XCTAssertEqual(question.choices.count, 4)
        XCTAssertEqual(Set(question.choices.map(\.name)).count, 4)
        XCTAssertEqual(question.choices[question.answer], question.tag)
        XCTAssertEqual(question.kind, .meaningToTag)
        XCTAssertGreaterThan(round.ends, Date())
        let phase = round.phase
        round.start()
        XCTAssertEqual(round.phase, phase, "Starting again changes nothing")
    }

    @MainActor func testARightAnswerRaisesScoreAndComboAndAWrongOneResetsTheComboAndASecondAnswerIsIgnored() throws {
        let round = try playing(try BooruStore())
        var question = try XCTUnwrap(round.question)
        XCTAssertTrue(round.answer(question.answer))
        XCTAssertEqual(round.score, 1)
        XCTAssertEqual(round.combo, 1)
        XCTAssertEqual(round.last, true)
        XCTAssertFalse(round.answer(question.answer), "A second answer before next() is ignored")
        XCTAssertEqual(round.score, 1)
        XCTAssertEqual(round.asked, 1)
        round.next()
        XCTAssertNil(round.last)
        question = try XCTUnwrap(round.question)
        XCTAssertTrue(round.answer(question.answer))
        round.next()
        XCTAssertEqual(round.combo, 2)
        question = try XCTUnwrap(round.question)
        XCTAssertFalse(round.answer((question.answer + 1) % 4))
        XCTAssertEqual(round.combo, 0)
        XCTAssertEqual(round.bestCombo, 2)
        XCTAssertEqual(round.score, 2)
        XCTAssertEqual(round.asked, 3)
        XCTAssertEqual(round.last, false)
        round.answer(question.answer)
        XCTAssertEqual(round.score, 2, "Still ignored after a wrong answer")
    }

    @MainActor func testNextNeverAsksTheSameTagTwiceInARow() throws {
        let round = try playing(try BooruStore())
        var previous = try XCTUnwrap(round.question).tag
        for _ in 0..<30 {
            round.answer(round.question!.answer); round.next()
            let now = try XCTUnwrap(round.question).tag
            XCTAssertNotEqual(now, previous)
            previous = now
        }
    }

    @MainActor func testAnswersAndFinishDoNothingOutsideARound() throws {
        let store = try BooruStore()
        try met(store, ["s1", "s2", "s3", "s4"])
        let round = StudySpeedRound(store: store, curriculum: curriculum)
        XCTAssertFalse(round.answer(0))
        round.finish()
        XCTAssertEqual(round.phase, .ready)
        XCTAssertTrue(try store.studyStore.stats().isEmpty)
        round.start(); round.answer(round.question!.answer); round.finish()
        let earned = round.earned
        round.finish()
        XCTAssertFalse(round.answer(0), "Nothing is answered after the end")
        XCTAssertEqual(round.earned, earned)
        XCTAssertEqual(try store.studyStore.days().first { $0.day == StudyDay.key(.now) }?.xp, 1, "Finishing twice pays once")
    }

    @MainActor func testFinishingEarnsTheRewardOnTodayRaisesBothCountersAndFlagsARecordOnlyWhenTheBestIsBeaten() throws {
        let store = try BooruStore()
        let round = try playing(store)
        for _ in 0..<6 { round.answer(round.question!.answer); round.next() }
        round.answer((round.question!.answer + 1) % 4); round.next()
        round.answer(round.question!.answer); round.next()
        round.finish()
        XCTAssertEqual(round.phase, .finished)
        XCTAssertEqual(round.score, 7)
        XCTAssertEqual(round.earned, 7)
        XCTAssertTrue(round.record, "The first round with a score beats a best of nothing")
        XCTAssertEqual(try store.studyStore.days().first { $0.day == StudyDay.key(.now) }?.xp, 7)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.speed], 7)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], 6)

        // A tie is not a record.
        let tie = StudySpeedRound(store: store, curriculum: curriculum)
        XCTAssertEqual(tie.best, 7)
        tie.start()
        for _ in 0..<7 { tie.answer(tie.question!.answer); tie.next() }
        tie.finish()
        XCTAssertFalse(tie.record)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.speed], 7)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], 7, "The longer run raises the combo counter")

        let weaker = StudySpeedRound(store: store, curriculum: curriculum)
        weaker.start()
        weaker.answer(weaker.question!.answer); weaker.next()
        weaker.finish()
        XCTAssertFalse(weaker.record)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.speed], 7, "A counter never goes down")
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], 7)

        let better = StudySpeedRound(store: store, curriculum: curriculum)
        better.start()
        for _ in 0..<9 { better.answer(better.question!.answer); better.next() }
        better.finish()
        XCTAssertTrue(better.record)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.speed], 9)
    }

    @MainActor func testARoundWithNoRightAnswerEarnsNothingAndIsNoRecord() throws {
        let store = try BooruStore()
        let round = try playing(store)
        round.answer((round.question!.answer + 1) % 4); round.next()
        round.finish()
        XCTAssertEqual(round.earned, 0)
        XCTAssertFalse(round.record)
        XCTAssertEqual(try store.studyStore.days().first { $0.day == StudyDay.key(.now) }?.xp, 0, "No experience for a round that earned none")
    }

    @MainActor func testAScoreAboveTwentyPaysTwentyAndTheCounterKeepsTheScore() throws {
        let store = try BooruStore()
        let round = try playing(store)
        for _ in 0..<25 { round.answer(round.question!.answer); round.next() }
        round.finish()
        XCTAssertEqual(round.score, 25)
        XCTAssertEqual(round.earned, 20)
        XCTAssertEqual(try store.studyStore.days().first { $0.day == StudyDay.key(.now) }?.xp, 20)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.speed], 25)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], 25)
    }
}
