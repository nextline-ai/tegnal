import XCTest
import GRDB
@testable import TEGNAL

final class StudyTests: XCTestCase {
    // MARK: - Sync and backup

    func testStudyProgressTravelsBetweenDevicesAndADayKeepsItsLargerCount() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) } }
        func adapter() throws -> LibrarySyncAdapter {
            func defaults() -> UserDefaults { let name = "study-sync-tests-" + UUID().uuidString; suites.append(name); return UserDefaults(suiteName: name)! }
            return LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults(), booruDefaults: defaults())
        }
        let a = try adapter(), b = try adapter()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try a.booru.studyStore.answer("cowboy_shot", right: true, now: now)
        try a.booru.studyStore.answer("cowboy_shot", right: true, now: now.addingTimeInterval(60))
        try a.booru.studyStore.save(.init(name: "cowboy_shot", count: 9, category: 0, wiki: nil, related: [], fetched: now, complete: true), address: "example.org")
        try b.booru.studyStore.answer("smile", right: false, now: now)
        for _ in 0..<4 { try b.booru.studyStore.answer("smile", right: true, now: now) }
        let rows = try a.snapshot().values.filter { $0.table.hasPrefix("booru.study_") }
        XCTAssertEqual(Set(rows.map(\.table)), ["booru.study_progress", "booru.study_days"], "What servers said about tags stays on the device")
        try b.apply(Dictionary(uniqueKeysWithValues: rows.map { ($0.key, LibrarySyncChange(row: $0, timestamp: 100, device: "A", deleted: false)) }))
        let progress = try b.booru.studyStore.progress()
        XCTAssertEqual(progress["cowboy_shot"]?.step, 2)
        XCTAssertEqual(progress["cowboy_shot"]?.correct, 2)
        XCTAssertEqual(progress["smile"]?.correct, 4, "Tags the other device never studied are untouched")
        let day = try XCTUnwrap(b.booru.studyStore.days().first)
        XCTAssertEqual(day.answered, 5, "The day studied more keeps its count")
        XCTAssertEqual(day.correct, 4)
        XCTAssertNil(try b.booru.studyStore.info("cowboy_shot", address: "example.org"))

        // A row no version could have written is left out without failing the rest.
        let bad = LibrarySyncRow(table: "booru.study_progress", values: ["tag": .text("smile"), "step": .integer(99), "due": .real(0), "correct": .integer(0), "wrong": .integer(0), "seen": .real(0)])
        try b.apply([bad.key: .init(row: bad, timestamp: 200, device: "A", deleted: false)])
        XCTAssertEqual(try b.booru.studyStore.progress()["smile"]?.correct, 4)

        let gone = try XCTUnwrap(rows.first { $0.table == "booru.study_progress" })
        try b.apply([gone.key: .init(row: gone, timestamp: 300, device: "A", deleted: true)])
        XCTAssertNil(try b.booru.studyStore.progress()["cowboy_shot"], "A reset on one device reaches the others")
    }

    func testBackupCarriesStudyProgressAndMergesWithoutUndoingLaterAnswers() throws {
        let source = try BooruStore(), destination = try BooruStore()
        let early = Date(timeIntervalSince1970: 1_800_000_000), late = early.addingTimeInterval(86_400)
        try source.studyStore.answer("cowboy_shot", right: true, now: early)
        try source.studyStore.answer("smile", right: true, now: late)
        try destination.studyStore.answer("cowboy_shot", right: false, now: late)
        try destination.studyStore.answer("smile", right: false, now: early)
        let backup = try BooruBackup.decode(source.exportBackup().encoded())
        XCTAssertEqual(backup.study?.progress.map(\.tag), ["cowboy_shot", "smile"])
        XCTAssertEqual(backup.study?.progress.first?.seen, early.timeIntervalSince1970, "Times are written as seconds since 1970")
        try destination.restoreBackup(backup)
        let progress = try destination.studyStore.progress()
        XCTAssertEqual(progress["cowboy_shot"]?.wrong, 1, "The later answer on this device stays")
        XCTAssertEqual(progress["cowboy_shot"]?.correct, 0)
        XCTAssertEqual(progress["smile"]?.correct, 1, "The backup's later answer replaces the earlier one here")
        XCTAssertEqual(try destination.studyStore.days().count, 2)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: source.exportBackup().encoded()) as? [String: Any])
        json["study"] = nil
        XCTAssertNil(try BooruBackup.decode(JSONSerialization.data(withJSONObject: json)).study, "Backups from before tag study still read")
        var invalid = backup; invalid.study?.progress[0].step = 99
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertNil(try BooruStore().exportBackup().study, "An unused feature adds nothing to the backup")
    }

    private func seedGame(_ store: BooruStore, day: String, xp: Int, answered: Int = 0, lesson: (String, Int, Int, Double)? = nil, award: (String, Double, Int)? = nil, stat: (String, Int)? = nil) throws {
        try store.database.write { db in
            try db.execute(sql: "INSERT INTO study_days (day, answered, correct, xp) VALUES (?, ?, 0, ?) ON CONFLICT(day) DO UPDATE SET answered = excluded.answered, xp = excluded.xp", arguments: [day, answered, xp])
            if let lesson { try db.execute(sql: "INSERT INTO study_lessons (lesson, stars, runs, finished) VALUES (?, ?, ?, ?)", arguments: [lesson.0, lesson.1, lesson.2, lesson.3]) }
            if let award { try db.execute(sql: "INSERT INTO study_awards (id, earned, seen) VALUES (?, ?, ?)", arguments: [award.0, award.1, award.2]) }
            if let stat { try db.execute(sql: "INSERT INTO study_stats (name, value) VALUES (?, ?)", arguments: [stat.0, stat.1]) }
        }
    }
    private func awards(_ store: BooruStore) throws -> [Row] { try store.database.read { try Row.fetchAll($0, sql: "SELECT * FROM study_awards ORDER BY id") } }

    func testLearningModeTravelsBetweenDevicesAndMergesByTheirRules() throws {
        var suites: [String] = []
        defer { suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) } }
        func adapter() throws -> LibrarySyncAdapter {
            func defaults() -> UserDefaults { let name = "study-game-sync-" + UUID().uuidString; suites.append(name); return UserDefaults(suiteName: name)! }
            return LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults(), booruDefaults: defaults())
        }
        let a = try adapter(), b = try adapter()
        try seedGame(a.booru, day: "2026-11-01", xp: 40, answered: 3, lesson: ("l1", 3, 2, 500), award: ("first", 100, 0), stat: ("best", 9))
        try seedGame(a.booru, day: "2026-11-02", xp: 5)
        try seedGame(b.booru, day: "2026-11-01", xp: 70, answered: 1, lesson: ("l1", 1, 5, 900), award: ("first", 300, 1), stat: ("best", 4))
        let rows = try a.snapshot().values.filter { $0.table.hasPrefix("booru.study_") }
        XCTAssertEqual(Set(rows.map(\.table)), ["booru.study_days", "booru.study_lessons", "booru.study_awards", "booru.study_stats"])
        try b.apply(Dictionary(uniqueKeysWithValues: rows.map { ($0.key, LibrarySyncChange(row: $0, timestamp: 100, device: "A", deleted: false)) }))
        let days = Dictionary(uniqueKeysWithValues: try b.booru.studyStore.days().map { ($0.day, $0) })
        XCTAssertEqual(days["2026-11-01"]?.xp, 70, "The larger experience of a day stays")
        XCTAssertEqual(days["2026-11-01"]?.answered, 3)
        XCTAssertEqual(days["2026-11-02"]?.xp, 5, "A day only the other device studied arrives with its experience")
        let lesson = try b.booru.database.read { try Row.fetchOne($0, sql: "SELECT * FROM study_lessons WHERE lesson = 'l1'") }
        XCTAssertEqual(lesson?["stars"] as Int?, 3)
        XCTAssertEqual(lesson?["runs"] as Int?, 5)
        XCTAssertEqual(lesson?["finished"] as Double?, 900)
        let award = try XCTUnwrap(awards(b.booru).first)
        XCTAssertEqual(award["earned"] as Double?, 100, "The earlier time stays")
        XCTAssertEqual(award["seen"] as Int?, 1)
        XCTAssertEqual(try b.booru.database.read { try Int.fetchOne($0, sql: "SELECT value FROM study_stats WHERE name = 'best'") }, 9)

        // A badge that arrives new is not celebrated again, and one seen here stays seen.
        let fresh = LibrarySyncRow(table: "booru.study_awards", values: ["id": .text("second"), "earned": .real(50), "seen": .integer(0)])
        try b.apply([fresh.key: .init(row: fresh, timestamp: 200, device: "A", deleted: false)])
        XCTAssertEqual(try awards(b.booru).map { $0["seen"] as Int }, [1, 1])
        let unseen = LibrarySyncRow(table: "booru.study_awards", values: ["id": .text("first"), "earned": .real(400), "seen": .integer(0)])
        try b.apply([unseen.key: .init(row: unseen, timestamp: 300, device: "A", deleted: false)])
        XCTAssertEqual(try awards(b.booru).first?["seen"] as Int?, 1)
        XCTAssertEqual(try awards(b.booru).first?["earned"] as Double?, 100)

        // A row from an older device has no experience column; the day keeps its own.
        let old = LibrarySyncRow(table: "booru.study_days", values: ["day": .text("2026-11-01"), "answered": .integer(1), "correct": .integer(0)])
        try b.apply([old.key: .init(row: old, timestamp: 400, device: "A", deleted: false)])
        XCTAssertEqual(try b.booru.studyStore.days().first { $0.day == "2026-11-01" }?.xp, 70)

        // Reset is carried like study_progress: removals reach the other device.
        var ledger = LibrarySyncLedger()
        ledger.capture(try a.snapshot(), device: "A", now: 1000)
        try a.booru.studyStore.reset()
        ledger.capture(try a.snapshot(), device: "A", now: 2000)
        let removals = ledger.changes.filter { $0.value.deleted && $0.value.row.table.hasPrefix("booru.study_") }
        XCTAssertEqual(Set(removals.values.map(\.row.table)), ["booru.study_days", "booru.study_lessons", "booru.study_awards", "booru.study_stats"])
        try b.apply(removals)
        // "second" reached this device by a row of its own that the other device never held, so only "first" is removed.
        XCTAssertEqual(try awards(b.booru).map { $0["id"] as String }, ["second"])
        XCTAssertTrue(try b.booru.studyStore.days().isEmpty)
        XCTAssertEqual(try b.booru.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM study_lessons") }, 0)
        XCTAssertEqual(try b.booru.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM study_stats") }, 0)
    }

    func testBackupCarriesLearningModeAndOlderBackupsStillRestore() throws {
        let source = try BooruStore(), destination = try BooruStore()
        try seedGame(source, day: "2026-11-01", xp: 40, answered: 3, lesson: ("l1", 3, 2, 500), award: ("first", 100, 0), stat: ("best", 9))
        try seedGame(destination, day: "2026-11-01", xp: 70, answered: 1, lesson: ("l1", 1, 5, 900), award: ("first", 300, 1), stat: ("best", 4))
        try seedGame(destination, day: "2026-11-03", xp: 8)
        let backup = try BooruBackup.decode(source.exportBackup().encoded())
        XCTAssertEqual(backup.study?.days.first?.xp, 40)
        XCTAssertEqual(backup.study?.lessons?.map(\.lesson), ["l1"])
        XCTAssertEqual(backup.study?.awards?.map(\.id), ["first"])
        XCTAssertEqual(backup.study?.stats, ["best": 9])
        try destination.restoreBackup(backup)
        try destination.restoreBackup(backup)
        let days = Dictionary(uniqueKeysWithValues: try destination.studyStore.days().map { ($0.day, $0) })
        XCTAssertEqual(days["2026-11-01"]?.xp, 70)
        XCTAssertEqual(days["2026-11-03"]?.xp, 8)
        let lesson = try destination.database.read { try Row.fetchOne($0, sql: "SELECT * FROM study_lessons") }
        XCTAssertEqual(lesson?["stars"] as Int?, 3)
        XCTAssertEqual(lesson?["runs"] as Int?, 5)
        XCTAssertEqual(lesson?["finished"] as Double?, 900)
        XCTAssertEqual(try awards(destination).first?["earned"] as Double?, 100)
        XCTAssertEqual(try destination.database.read { try Int.fetchOne($0, sql: "SELECT value FROM study_stats") }, 9)

        // Into an empty library the badge arrives seen.
        let fresh = try BooruStore()
        try fresh.restoreBackup(backup)
        XCTAssertEqual(try awards(fresh).first?["seen"] as Int?, 1)
        XCTAssertEqual(try fresh.studyStore.days().first?.xp, 40)

        // A backup from before learning mode has neither the new lists nor a day's experience.
        let old = try BooruStore()
        try old.studyStore.answer("smile", right: true, now: Date(timeIntervalSince1970: 1_800_000_000))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old.exportBackup().encoded()) as? [String: Any])
        var study = try XCTUnwrap(json["study"] as? [String: Any])
        for key in ["lessons", "awards", "stats"] { study[key] = nil }
        study["days"] = (try XCTUnwrap(study["days"] as? [[String: Any]])).map { var day = $0; day["xp"] = nil; return day }
        json["study"] = study
        let decoded = try BooruBackup.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.study?.lessons)
        XCTAssertEqual(decoded.study?.days.first?.xp, 0)
        let target = try BooruStore()
        try target.restoreBackup(decoded)
        XCTAssertEqual(try target.studyStore.days().first?.answered, 1)
        XCTAssertEqual(try target.studyStore.progress()["smile"]?.correct, 1)
        XCTAssertTrue(try awards(target).isEmpty)
        // Learning mode alone is enough to make a backup carry something.
        let only = try BooruStore()
        try seedGame(only, day: "2026-11-01", xp: 0, award: ("first", 1, 1))
        XCTAssertNotNil(try only.exportBackup().study)
    }

    /// Asks a real server whether every taught tag exists there. Opt-in: it needs the network and a reachable server.
    func testLiveServerKnowsEveryCurriculumTag() async throws {
        guard ProcessInfo.processInfo.environment["TEGNAL_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in public network verification") }
        let server = BooruServer.presets[0]
        let names = StudyCurriculum.bundled.tags.map(\.name)
        let found = try await BooruClient.shared.tags(server: server, names: names)
        let counts = Dictionary(found.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = names.filter { counts[$0] == nil }
        let rare = names.filter { (counts[$0]?.count ?? 0) > 0 && (counts[$0]?.count ?? 0) < 1_000 }.map { "\($0)=\(counts[$0]!.count)" }
        let empty = names.filter { counts[$0]?.count == 0 }
        let otherKinds = names.filter { counts[$0].map { ![0, 5].contains($0.category) } ?? false }.map { "\($0):\(counts[$0]!.category)" }
        let report = "STUDY-LIVE found=\(found.count)/\(names.count)\nMISSING: \(missing.joined(separator: " "))\nEMPTY: \(empty.joined(separator: " "))\nRARE: \(rare.joined(separator: " "))\nKINDS: \(otherKinds.joined(separator: " "))"
        print(report)
        try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("study-live.txt"), atomically: true, encoding: .utf8)
        let wiki = try await BooruClient.shared.wiki(server: server, tag: "cowboy_shot")
        XCTAssertFalse(wiki?.body.isEmpty ?? true)
        let related = try await BooruClient.shared.relatedTags(server: server, tag: "cowboy_shot")
        XCTAssertFalse(related.isEmpty)
        let page = try await BooruClient.shared.posts(server: server, query: "cowboy_shot", page: 3)
        XCTAssertFalse(page.posts.isEmpty, "A single tag a few pages in is within an anonymous search")
        XCTAssertTrue(missing.isEmpty && empty.isEmpty, report)
    }

    // MARK: - Curriculum file

    func testBundledCurriculumHasAtLeastTwelveUnitsAndFourHundredTags() {
        let curriculum = StudyCurriculum.bundled
        XCTAssertGreaterThanOrEqual(curriculum.units.count, 12)
        XCTAssertGreaterThanOrEqual(curriculum.tags.count, 400)
        XCTAssertEqual(curriculum.count, curriculum.tags.count, "Every tag name appears once, so the index holds as many tags as the file")
    }

    func testBundledTagNamesAreUniqueLowercaseAndFreeOfSpacesAndCommas() {
        let names = StudyCurriculum.bundled.tags.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Duplicated: " + Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }.keys.sorted().joined(separator: ", "))
        XCTAssertEqual(names.filter { $0 != $0.lowercased() }, [])
        XCTAssertEqual(names.filter { $0.isEmpty || $0.contains(" ") || $0.contains(",") }, [])
    }

    func testEveryBundledTagHasKoreanJapaneseAndANoteInAllThreeLanguages() {
        var problems: [String] = []
        for tag in StudyCurriculum.bundled.tags {
            if (tag.ko ?? "").isEmpty { problems.append(tag.name + " ko") }
            if (tag.ja ?? "").isEmpty { problems.append(tag.name + " ja") }
            for language in ["en", "ko", "ja"] where (tag.note[language] ?? "").isEmpty { problems.append(tag.name + " note." + language) }
        }
        XCTAssertEqual(problems, [])
    }

    func testEveryBundledGroupAndUnitHasTitlesInAllThreeLanguagesAndGroupIDsAreUnique() {
        var problems: [String] = []
        var groupIDs: [String] = []
        for unit in StudyCurriculum.bundled.units {
            for language in ["en", "ko", "ja"] {
                if (unit.title[language] ?? "").isEmpty { problems.append(unit.id + " title." + language) }
                if (unit.summary[language] ?? "").isEmpty { problems.append(unit.id + " summary." + language) }
            }
            for group in unit.groups {
                groupIDs.append(group.id)
                for language in ["en", "ko", "ja"] where (group.title[language] ?? "").isEmpty { problems.append(group.id + " title." + language) }
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertEqual(groupIDs.count, Set(groupIDs).count)
        XCTAssertEqual(Set(StudyCurriculum.bundled.units.map(\.id)).count, StudyCurriculum.bundled.units.count, "Unit ids are unique")
    }

    func testEveryConfusableNamesAnotherTagInTheCurriculum() {
        let curriculum = StudyCurriculum.bundled
        var problems: [String] = []
        for tag in curriculum.tags {
            for other in tag.confusable ?? [] {
                if other == tag.name { problems.append(tag.name + " names itself") }
                else if !curriculum.contains(other) { problems.append(tag.name + " -> " + other + " is not taught") }
            }
        }
        XCTAssertEqual(problems, [])
    }

    func testCurriculumLookupsAgreeOnTagGroupAndUnitForEveryBundledTag() {
        let curriculum = StudyCurriculum.bundled
        var problems: [String] = []
        for unit in curriculum.units {
            XCTAssertEqual(curriculum.unit(unit.id)?.id, unit.id)
            for group in unit.groups {
                for tag in group.tags {
                    if !curriculum.contains(tag.name) { problems.append(tag.name + " contains") }
                    if curriculum.tag(tag.name) != tag { problems.append(tag.name + " tag") }
                    if curriculum.group(of: tag.name)?.id != group.id { problems.append(tag.name + " group") }
                    if curriculum.unit(of: tag.name)?.id != unit.id { problems.append(tag.name + " unit") }
                }
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertFalse(curriculum.contains("definitely_not_a_study_tag"))
        XCTAssertNil(curriculum.tag("definitely_not_a_study_tag"))
        XCTAssertNil(curriculum.group(of: "definitely_not_a_study_tag"))
        XCTAssertNil(curriculum.unit(of: "definitely_not_a_study_tag"))
    }

    func testTaughtListsAPostsCurriculumTagsInCurriculumOrderAndSkipsOthers() throws {
        let curriculum = StudyCurriculum.bundled
        let all = curriculum.tags
        let first = try XCTUnwrap(all.first), middle = all[all.count / 2], last = try XCTUnwrap(all.last)
        let tagged = post(1, [last.name, "definitely_not_a_study_tag", first.name, middle.name])
        XCTAssertEqual(curriculum.taught(in: tagged).map(\.name), [first.name, middle.name, last.name])
        XCTAssertEqual(curriculum.taught(in: post(2, ["definitely_not_a_study_tag"])), [])
    }

    // MARK: - StudyProgress

    func testRightAnswersMoveOneStepUpAndScheduleTheNextAskingByTheStepInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var progress = StudyProgress(tag: "solo")
        for step in 1...StudyProgress.lastStep {
            progress = progress.answered(true, now: now)
            XCTAssertEqual(progress.step, step)
            XCTAssertEqual(progress.due, now.addingTimeInterval(StudyProgress.intervals[step] * 86_400))
            XCTAssertEqual(progress.seen, now)
            XCTAssertEqual(progress.correct, step)
        }
        let beyond = progress.answered(true, now: now)
        XCTAssertEqual(beyond.step, StudyProgress.lastStep, "The step stops at the last one")
        XCTAssertEqual(beyond.due, now.addingTimeInterval(StudyProgress.intervals[StudyProgress.lastStep] * 86_400))
        XCTAssertEqual(beyond.correct, StudyProgress.lastStep + 1)
    }

    func testAWrongAnswerReturnsToStepZeroAndAsksAgainInTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var progress = StudyProgress(tag: "solo", step: 5, due: now.addingTimeInterval(86_400), correct: 5)
        progress = progress.answered(false, now: now)
        XCTAssertEqual(progress.step, 0)
        XCTAssertEqual(progress.due, now.addingTimeInterval(600))
        XCTAssertEqual(progress.wrong, 1)
        XCTAssertEqual(progress.correct, 5)
        XCTAssertEqual(progress.seen, now)
    }

    func testLearnedNewAndDueFollowTheStepCountsAndDueDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(StudyProgress(tag: "a", step: StudyProgress.learnedStep - 1).isLearned)
        XCTAssertTrue(StudyProgress(tag: "a", step: StudyProgress.learnedStep).isLearned)
        XCTAssertTrue(StudyProgress(tag: "a", step: StudyProgress.lastStep).isLearned)
        let fresh = StudyProgress(tag: "a")
        XCTAssertTrue(fresh.isNew)
        XCTAssertFalse(fresh.isDue(now), "A tag never asked is new, not due, even though its due date is long past")
        XCTAssertFalse(fresh.answered(true, now: now).isNew)
        XCTAssertFalse(StudyProgress(tag: "a", wrong: 1).isNew)
        XCTAssertTrue(StudyProgress(tag: "a", due: now.addingTimeInterval(-1), correct: 1).isDue(now))
        XCTAssertTrue(StudyProgress(tag: "a", due: now, correct: 1).isDue(now))
        XCTAssertFalse(StudyProgress(tag: "a", due: now.addingTimeInterval(1), correct: 1).isDue(now))
    }

    // MARK: - StudyStore

    @MainActor func testAnswerWritesProgressAndAddsToTheDaysRowAndBothReadBack() throws {
        let study = try BooruStore().studyStore
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try study.answer("solo", right: true, now: now, calendar: utc)
        XCTAssertEqual(first.step, 1)
        try study.answer("solo", right: false, now: now.addingTimeInterval(60), calendar: utc)
        try study.answer("1girl", right: true, now: now.addingTimeInterval(120), calendar: utc)
        let progress = try study.progress()
        XCTAssertEqual(Set(progress.keys), ["solo", "1girl"])
        XCTAssertEqual(progress["solo"]?.step, 0)
        XCTAssertEqual(progress["solo"]?.correct, 1)
        XCTAssertEqual(progress["solo"]?.wrong, 1)
        XCTAssertEqual(progress["solo"]?.due, now.addingTimeInterval(660))
        XCTAssertEqual(progress["1girl"]?.step, 1)
        XCTAssertEqual(progress["1girl"]?.due, now.addingTimeInterval(120 + 86_400))
        let days = try study.days()
        XCTAssertEqual(days, [StudyDay(day: StudyDay.key(now, calendar: utc), answered: 3, correct: 2)])
    }

    @MainActor func testDaysAreReadNewestFirstAndAnswersOnADifferentDayAreSeparateRows() throws {
        let study = try BooruStore().studyStore
        let day1 = date(2026, 3, 8), day2 = date(2026, 3, 9)
        try study.answer("solo", right: true, now: day1, calendar: utc)
        try study.answer("solo", right: false, now: day2, calendar: utc)
        XCTAssertEqual(try study.days().map(\.day), ["2026-03-09", "2026-03-08"])
        XCTAssertEqual(try study.days().map(\.correct), [0, 1])
    }

    @MainActor func testResetClearsProgressAndDaysButKeepsTheCachedTagInfo() throws {
        let study = try BooruStore().studyStore
        try study.answer("solo", right: true, now: date(2026, 3, 8), calendar: utc)
        try study.save(tagInfo("solo", count: 12), address: "https://a.example")
        try study.reset()
        XCTAssertTrue(try study.progress().isEmpty)
        XCTAssertTrue(try study.days().isEmpty)
        XCTAssertEqual(try study.info("solo", address: "https://a.example")?.count, 12)
    }

    @MainActor func testTagInfoCacheIsKeyedByAddressAndCountsListOnlyThatAddressesKnownCounts() throws {
        let study = try BooruStore().studyStore
        let info = tagInfo("solo", count: 12)
        try study.save(info, address: "https://a.example")
        try study.save(tagInfo("1girl", count: 7), address: "https://a.example")
        try study.save(tagInfo("hug", count: nil), address: "https://a.example")
        try study.save(tagInfo("solo", count: 99), address: "https://b.example")
        XCTAssertEqual(try study.info("solo", address: "https://a.example"), info)
        XCTAssertEqual(try study.info("solo", address: "https://b.example")?.count, 99)
        XCTAssertNil(try study.info("1girl", address: "https://b.example"))
        XCTAssertNil(try study.info("unknown", address: "https://a.example"))
        XCTAssertEqual(try study.counts(address: "https://a.example"), ["solo": 12, "1girl": 7])
        XCTAssertEqual(try study.counts(address: "https://b.example"), ["solo": 99])
        XCTAssertEqual(try study.counts(address: "https://c.example"), [:])
        // Saving again for the same name replaces the earlier answer.
        try study.save(tagInfo("solo", count: 13), address: "https://a.example")
        XCTAssertEqual(try study.info("solo", address: "https://a.example")?.count, 13)
    }

    @MainActor func testDeletingAServerRemovesThatAddressesCachedTagInfoAndLeavesAnotherAddressAlone() throws {
        let store = try BooruStore()
        let first = BooruServer(id: "study-first", name: "First", baseURL: URL(string: "https://first.example")!, engine: .danbooru)
        let second = BooruServer(id: "study-second", name: "Second", baseURL: URL(string: "https://second.example")!, engine: .danbooru)
        try store.saveServer(first)
        try store.saveServer(second)
        let study = store.studyStore
        try study.save(tagInfo("solo", count: 1), address: first.canonicalAddress)
        try study.save(tagInfo("solo", count: 2), address: second.canonicalAddress)
        try study.answer("solo", right: true, now: date(2026, 3, 8), calendar: utc)
        try store.deleteServer(first)
        XCTAssertNil(try study.info("solo", address: first.canonicalAddress))
        XCTAssertEqual(try study.info("solo", address: second.canonicalAddress)?.count, 2)
        XCTAssertEqual(try study.progress().count, 1, "What was learned belongs to the tag, not to a server")
    }

    // MARK: - StudySummary

    func testSummaryCountsTotalStartedLearnedAndDueOnlyForCurriculumTags() {
        let now = date(2026, 3, 10, hour: 12)
        let curriculum = roundCurriculum
        let progress: [String: StudyProgress] = [
            "t1": StudyProgress(tag: "t1", step: 4, due: now.addingTimeInterval(86_400), correct: 4),   // learned, not due
            "t2": StudyProgress(tag: "t2", step: 1, due: now.addingTimeInterval(-60), correct: 1),      // started and due
            "t3": StudyProgress(tag: "t3", step: 0, due: now.addingTimeInterval(600), wrong: 1),        // started
            "t4": StudyProgress(tag: "t4"),                                                              // new
            "w1": StudyProgress(tag: "w1", step: 6, due: now.addingTimeInterval(-10), correct: 7),      // learned and due
            "outside": StudyProgress(tag: "outside", step: 6, due: now.addingTimeInterval(-10), correct: 7)
        ]
        let summary = StudySummary(curriculum: curriculum, progress: progress, days: [], now: now, calendar: utc)
        XCTAssertEqual(summary.total, 11)
        XCTAssertEqual(summary.started, 4)
        XCTAssertEqual(summary.learned, 2)
        XCTAssertEqual(summary.due, 2)
        XCTAssertEqual(summary.streak, 0)
    }

    func testSummaryReportsTodaysAnswersAndRightAnswers() {
        let now = date(2026, 3, 10, hour: 12)
        let days = [StudyDay(day: "2026-03-10", answered: 5, correct: 3), StudyDay(day: "2026-03-09", answered: 9, correct: 9)]
        let summary = StudySummary(curriculum: roundCurriculum, progress: [:], days: days, now: now, calendar: utc)
        XCTAssertEqual(summary.today, 5)
        XCTAssertEqual(summary.todayCorrect, 3)
        let quiet = StudySummary(curriculum: roundCurriculum, progress: [:], days: [days[1]], now: now, calendar: utc)
        XCTAssertEqual(quiet.today, 0)
        XCTAssertEqual(quiet.todayCorrect, 0)
    }

    func testStreakCountsConsecutiveDaysEndingToday() {
        let now = date(2026, 3, 10, hour: 12)
        let days = [StudyDay(day: "2026-03-10", answered: 1, correct: 1), StudyDay(day: "2026-03-09", answered: 4, correct: 2),
                    StudyDay(day: "2026-03-08", answered: 2, correct: 0), StudyDay(day: "2026-03-06", answered: 8, correct: 8)]
        XCTAssertEqual(StudySummary(curriculum: roundCurriculum, progress: [:], days: days, now: now, calendar: utc).streak, 3)
    }

    func testStreakStillCountsWhenTodayHasNoAnswersYetButYesterdayDoes() {
        let now = date(2026, 3, 10, hour: 12)
        let days = [StudyDay(day: "2026-03-09", answered: 4, correct: 2), StudyDay(day: "2026-03-08", answered: 2, correct: 0)]
        XCTAssertEqual(StudySummary(curriculum: roundCurriculum, progress: [:], days: days, now: now, calendar: utc).streak, 2)
        // A row with nothing answered is not a day of study.
        let empty = [StudyDay(day: "2026-03-10", answered: 0, correct: 0)] + days
        XCTAssertEqual(StudySummary(curriculum: roundCurriculum, progress: [:], days: empty, now: now, calendar: utc).streak, 2)
    }

    func testStreakIsZeroAfterAGapOfMoreThanOneDay() {
        let now = date(2026, 3, 10, hour: 12)
        let days = [StudyDay(day: "2026-03-08", answered: 4, correct: 2), StudyDay(day: "2026-03-07", answered: 2, correct: 0)]
        XCTAssertEqual(StudySummary(curriculum: roundCurriculum, progress: [:], days: days, now: now, calendar: utc).streak, 0)
        XCTAssertEqual(StudySummary(curriculum: roundCurriculum, progress: [:], days: [], now: now, calendar: utc).streak, 0)
    }

    func testStreakFollowsTheCalendarsTimeZoneNotUTC() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-03-10 20:00 UTC is already 2026-03-11 in Tokyo.
        let now = date(2026, 3, 10, hour: 20)
        let days = [StudyDay(day: "2026-03-11", answered: 1, correct: 1), StudyDay(day: "2026-03-10", answered: 1, correct: 1)]
        let summary = StudySummary(curriculum: roundCurriculum, progress: [:], days: days, now: now, calendar: tokyo)
        XCTAssertEqual(summary.today, 1)
        XCTAssertEqual(summary.streak, 2)
    }

    // MARK: - StudyEngine.round

    func testReviewReturnsOnlyDueTagsLongestOverdueFirst() {
        let now = date(2026, 3, 10, hour: 12)
        let progress: [String: StudyProgress] = [
            "t1": due("t1", now, daysAgo: 1), "t3": due("t3", now, daysAgo: 3), "t5": due("t5", now, daysAgo: 5),
            "t2": StudyProgress(tag: "t2", step: 2, due: now.addingTimeInterval(86_400), correct: 2),
            "w1": due("w1", now, daysAgo: 2)
        ]
        var generator = SplitMix64(seed: 1)
        let round = roundEngine.round(.review, progress: progress, now: now, using: &generator).map(\.name)
        XCTAssertEqual(round, ["t5", "t3", "w1", "t1"])
        var other = SplitMix64(seed: 1)
        XCTAssertEqual(roundEngine.round(.review, progress: progress, count: 2, now: now, using: &other).map(\.name), ["t5", "t3"])
        var none = SplitMix64(seed: 1)
        XCTAssertEqual(roundEngine.round(.review, progress: [:], now: now, using: &none), [], "Nothing is due before anything is asked")
    }

    func testTodayPutsDueTagsFirstAndLeavesRoomForThreeNewTagsInCurriculumOrder() {
        let now = date(2026, 3, 10, hour: 12)
        // Four tags are due, longest overdue first: t4, t2, t3, t1. The rest are new.
        let progress: [String: StudyProgress] = [
            "t1": due("t1", now, daysAgo: 1), "t2": due("t2", now, daysAgo: 8), "t3": due("t3", now, daysAgo: 2), "t4": due("t4", now, daysAgo: 9)
        ]
        var generator = SplitMix64(seed: 7)
        let round = roundEngine.round(.today, progress: progress, count: 5, now: now, using: &generator).map(\.name)
        XCTAssertEqual(round, ["t4", "t2", "t5", "t6", "t7"], "Two due tags and the three new tags that are always given room")
        var wide = SplitMix64(seed: 7)
        let more = roundEngine.round(.today, progress: progress, count: 10, now: now, using: &wide).map(\.name)
        XCTAssertEqual(more, ["t4", "t2", "t3", "t1", "t5", "t6", "t7", "t8", "w1", "w2"], "Due first, then new tags in curriculum order, never more than the count")
    }

    func testTodayNeverReturnsMoreThanTheCountAndHasNoDuplicates() {
        let now = date(2026, 3, 10, hour: 12)
        var progress: [String: StudyProgress] = [:]
        for index in 1...8 { progress["t\(index)"] = due("t\(index)", now, daysAgo: index) }
        for count in [1, 2, 3, 4, 8, 20] {
            var generator = SplitMix64(seed: UInt64(count))
            let round = roundEngine.round(.today, progress: progress, count: count, now: now, using: &generator).map(\.name)
            XCTAssertLessThanOrEqual(round.count, count)
            XCTAssertEqual(round.count, Set(round).count)
        }
        var generator = SplitMix64(seed: 3)
        let all = roundEngine.round(.today, progress: progress, count: 4, now: now, using: &generator).map(\.name)
        XCTAssertEqual(all, ["t8", "w1", "w2", "w3"], "One due tag keeps three places for new ones")
    }

    func testTodayWithNothingDueOrNewIsEmpty() {
        let now = date(2026, 3, 10, hour: 12)
        var progress: [String: StudyProgress] = [:]
        for tag in roundCurriculum.tags { progress[tag.name] = StudyProgress(tag: tag.name, step: 2, due: now.addingTimeInterval(86_400), correct: 2) }
        var generator = SplitMix64(seed: 3)
        XCTAssertEqual(roundEngine.round(.today, progress: progress, now: now, using: &generator), [])
    }

    func testUnitRoundHoldsOnlyThatUnitsTagsAndFillsUpWithSeenTagsLeastKnownFirst() {
        let now = date(2026, 3, 10, hour: 12)
        let future = now.addingTimeInterval(86_400)
        // t3 to t8 are new and come first in curriculum order; the seen ones follow, least known first.
        let progress: [String: StudyProgress] = [
            "t1": StudyProgress(tag: "t1", step: 3, due: future, correct: 3),
            "t2": StudyProgress(tag: "t2", step: 1, due: future, correct: 1),
            "w1": StudyProgress(tag: "w1", step: 0, due: future, correct: 1)
        ]
        for seed: UInt64 in 0..<20 {
            var generator = SplitMix64(seed: seed)
            let round = roundEngine.round(.unit("r1"), progress: progress, count: 8, now: now, using: &generator).map(\.name)
            XCTAssertEqual(round, ["t3", "t4", "t5", "t6", "t7", "t8", "t2", "t1"], "seed \(seed)")
        }
        var generator = SplitMix64(seed: 1)
        let wide = roundEngine.round(.unit("r1"), progress: progress, count: 20, now: now, using: &generator).map(\.name)
        XCTAssertEqual(wide, ["t3", "t4", "t5", "t6", "t7", "t8", "t2", "t1"], "The other unit's tags never join")
        var unknown = SplitMix64(seed: 1)
        XCTAssertEqual(roundEngine.round(.unit("nothing"), progress: progress, now: now, using: &unknown), [])
    }

    func testUnitRoundWithEverythingSeenAsksTheLeastKnownTagsFirst() {
        let now = date(2026, 3, 10, hour: 12)
        let future = now.addingTimeInterval(86_400)
        var progress: [String: StudyProgress] = [:]
        let steps = ["w1": 4, "w2": 1, "w3": 3]
        for (name, step) in steps { progress[name] = StudyProgress(tag: name, step: step, due: future, correct: 1) }
        for seed: UInt64 in 0..<20 {
            var generator = SplitMix64(seed: seed)
            XCTAssertEqual(roundEngine.round(.unit("r2"), progress: progress, count: 3, now: now, using: &generator).map(\.name), ["w2", "w3", "w1"], "seed \(seed)")
            var short = SplitMix64(seed: seed)
            XCTAssertEqual(roundEngine.round(.unit("r2"), progress: progress, count: 2, now: now, using: &short).map(\.name), ["w2", "w3"], "seed \(seed)")
        }
    }

    func testTagsScopeKeepsOnlyCurriculumTagsWithoutDuplicatesInTheGivenOrder() {
        let now = date(2026, 3, 10, hour: 12)
        var generator = SplitMix64(seed: 5)
        let round = roundEngine.round(.tags(["w2", "not_taught", "t1", "w2", "t1", "t5"]), progress: [:], now: now, using: &generator).map(\.name)
        XCTAssertEqual(round, ["w2", "t1", "t5"])
    }

    // MARK: - StudyEngine.usable / teaches / distractors

    func testVideosAnimatedRemovedAndPicturelessPostsAreNotUsable() {
        XCTAssertTrue(StudyEngine.usable(post(1, ["solo"])))
        XCTAssertFalse(StudyEngine.usable(post(2, ["solo"], ext: "mp4")))
        XCTAssertFalse(StudyEngine.usable(post(3, ["solo"], ext: "gif")))
        XCTAssertFalse(StudyEngine.usable(post(4, ["solo", "animated"])))
        var removed = post(5, ["solo"]); removed.isDeleted = true
        XCTAssertFalse(StudyEngine.usable(removed))
        var banned = post(6, ["solo"]); banned.isBanned = true
        XCTAssertFalse(StudyEngine.usable(banned))
        var bare = post(7, ["solo"]); bare.previewURL = nil; bare.sampleURL = nil; bare.fileURL = nil
        XCTAssertFalse(StudyEngine.usable(bare))
        var sampleOnly = post(8, ["solo"]); sampleOnly.previewURL = nil
        XCTAssertTrue(StudyEngine.usable(sampleOnly))
    }

    func testAnExclusiveGroupTeachesNeitherTagWhenAPostCarriesTwoOfItsTagsButANonExclusiveGroupTeachesBoth() {
        let engine = tinyEngine
        let s1 = tinyTag("s1"), s2 = tinyTag("s2"), m1 = tinyTag("m1"), m2 = tinyTag("m2")
        let shots = post(1, ["s1", "s2", "m1"])
        XCTAssertFalse(engine.teaches(shots, s1))
        XCTAssertFalse(engine.teaches(shots, s2))
        XCTAssertTrue(engine.teaches(post(2, ["s1", "m1"]), s1), "Tags of other groups do not matter")
        let misc = post(3, ["m1", "m2"])
        XCTAssertTrue(engine.teaches(misc, m1))
        XCTAssertTrue(engine.teaches(misc, m2))
        XCTAssertFalse(engine.teaches(post(4, ["m2"]), m1), "A picture without the tag teaches nothing")
        XCTAssertTrue(engine.teaches(post(5, ["stray"]), StudyTag(name: "stray", note: [:])), "A tag without a group is taught by any picture that carries it")
    }

    func testDistractorsNeverIncludeTheTagOrExcludedNamesHaveNoDuplicatesAndTakeConfusableTagsFirst() {
        let engine = tinyEngine
        let s1 = engine.curriculum.tag("s1")!
        XCTAssertEqual(s1.confusable, ["m1"])
        for seed: UInt64 in 0..<30 {
            var generator = SplitMix64(seed: seed)
            let wrong = engine.distractors(for: s1, count: 3, excluding: ["s2"], using: &generator).map(\.name)
            XCTAssertEqual(wrong.count, 3, "seed \(seed)")
            XCTAssertEqual(wrong.count, Set(wrong).count)
            XCTAssertFalse(wrong.contains("s1"))
            XCTAssertFalse(wrong.contains("s2"))
            XCTAssertEqual(wrong.first, "m1", "The confusable tag comes before tags of the same group")
            XCTAssertEqual(Set(wrong.dropFirst()).subtracting(["s3", "s4"]), [], "Then tags answering the same question: \(wrong)")
        }
    }

    func testDistractorsFillUpFromTheUnitAndThenTheWholeCurriculumAndStopWhenItRunsOut() {
        let engine = tinyEngine
        let s1 = engine.curriculum.tag("s1")!
        var generator = SplitMix64(seed: 11)
        let many = engine.distractors(for: s1, count: 9, using: &generator).map(\.name)
        XCTAssertEqual(many.count, 9)
        XCTAssertEqual(many.count, Set(many).count)
        XCTAssertFalse(many.contains("s1"))
        var every = SplitMix64(seed: 11)
        let all = engine.distractors(for: s1, count: 100, using: &every).map(\.name)
        XCTAssertEqual(Set(all), Set(engine.curriculum.tags.map(\.name)).subtracting(["s1"]), "Nothing else is left to offer")
        var excluded = SplitMix64(seed: 11)
        let none = engine.distractors(for: s1, count: 3, excluding: Set(engine.curriculum.tags.map(\.name)), using: &excluded)
        XCTAssertEqual(none, [])
    }

    // MARK: - StudyEngine.question

    func testAnEmptyPoolOrANonVisualGroupAsksByMeaning() {
        let engine = tinyEngine
        for seed: UInt64 in 0..<25 {
            var generator = SplitMix64(seed: seed)
            let empty = engine.question(for: tinyTag("s1"), pool: [], using: &generator)
            XCTAssertEqual(empty?.kind, .meaningToTag, "seed \(seed)")
            XCTAssertEqual(empty?.choices[empty?.answer ?? 0].name, "s1")
            XCTAssertTrue(empty?.posts.isEmpty == true)
            // Even with pictures that carry the tag, a tag that cannot be told by looking is asked by meaning.
            let pool = [post(1, ["x1"]), post(2, ["x1", "m1"]), post(3, ["s2"]), post(4, ["s3"]), post(5, ["s4"])]
            let abstract = engine.question(for: tinyTag("x1"), pool: pool, using: &generator)
            XCTAssertEqual(abstract?.kind, .meaningToTag, "seed \(seed)")
            XCTAssertEqual(abstract?.choices[abstract?.answer ?? 0].name, "x1")
            XCTAssertTrue(abstract?.posts.isEmpty == true)
        }
    }

    func testAPictureQuestionShowsAnExampleAndOffersTheTagAmongChoicesNotOnThePost() throws {
        let engine = tinyEngine
        let shown = post(1, ["s1", "m1", "scenery"])
        for seed: UInt64 in 0..<40 {
            var generator = SplitMix64(seed: seed)
            let question = try XCTUnwrap(engine.question(for: tinyTag("s1"), pool: [shown], kinds: [.pictureToTag, .meaningToTag], using: &generator))
            XCTAssertEqual(question.kind, .pictureToTag, "seed \(seed)")
            XCTAssertEqual(question.posts, [shown])
            XCTAssertEqual(question.choices[question.answer].name, "s1")
            XCTAssertGreaterThanOrEqual(question.choices.count, 3)
            XCTAssertEqual(question.choices.count, Set(question.choices.map(\.name)).count)
            XCTAssertEqual(question.choiceCount, question.choices.count)
            for (index, choice) in question.choices.enumerated() where index != question.answer {
                XCTAssertFalse(shown.tags.contains(choice.name), "\(choice.name) is on the shown picture")
            }
        }
    }

    func testAPictureWithTwoTagsOfAnExclusiveGroupIsNotUsedAsAnExample() throws {
        var generator = SplitMix64(seed: 2)
        let question = try XCTUnwrap(tinyEngine.question(for: tinyTag("s1"), pool: [post(1, ["s1", "s2"])], kinds: [.pictureToTag, .meaningToTag], using: &generator))
        XCTAssertEqual(question.kind, .meaningToTag)
    }

    func testAPictureChoiceQuestionOffersTheTagsPictureAmongThreeThatCarryNeighbouringTagsOnly() throws {
        let engine = tinyEngine
        let pool = [post(1, ["s1", "m1"]), post(2, ["s2"]), post(3, ["s3", "m2"]), post(4, ["s4"]), post(5, ["m3"])]
        let siblings: Set<String> = ["s2", "s3", "s4"]
        var found = false
        for seed: UInt64 in 0..<200 {
            var generator = SplitMix64(seed: seed)
            let question = try XCTUnwrap(engine.question(for: tinyTag("s1"), pool: pool, kinds: [.tagToPicture, .meaningToTag], using: &generator))
            guard question.kind == .tagToPicture else { XCTAssertEqual(question.kind, .meaningToTag); continue }
            found = true
            XCTAssertEqual(question.posts.count, 4)
            XCTAssertEqual(question.choiceCount, 4)
            XCTAssertEqual(Set(question.posts.map(\.id)).count, 4)
            XCTAssertTrue(question.posts[question.answer].tags.contains("s1"))
            for (index, shown) in question.posts.enumerated() where index != question.answer {
                XCTAssertFalse(shown.tags.contains("s1"))
                XCTAssertFalse(siblings.isDisjoint(with: shown.tags), "Each wrong picture carries another tag of the group")
            }
            XCTAssertTrue(question.choices.isEmpty)
            break
        }
        XCTAssertTrue(found, "No seed of 200 produced a picture-choice question")
    }

    func testAPictureChoiceQuestionIsNotAskedWithoutThreeWrongPicturesWithNeighbouringTags() throws {
        let pool = [post(1, ["s1"]), post(2, ["s2"]), post(3, ["m1"]), post(4, ["scenery"])]
        for seed: UInt64 in 0..<60 {
            var generator = SplitMix64(seed: seed)
            let question = try XCTUnwrap(tinyEngine.question(for: tinyTag("s1"), pool: pool, kinds: [.tagToPicture, .meaningToTag], using: &generator))
            XCTAssertEqual(question.kind, .meaningToTag, "seed \(seed)")
        }
    }

    func testNoQuestionIsMadeWhenTheAllowedKindsCannotBeAsked() {
        var generator = SplitMix64(seed: 4)
        XCTAssertNil(tinyEngine.question(for: tinyTag("s1"), pool: [], kinds: [.pictureToTag, .tagToPicture], using: &generator))
    }

    // MARK: - StudyPrompt

    func testWordsTurnUnderscoresIntoSpacesButKeepEmoticonsAndPunctuationTags() {
        XCTAssertEqual(StudyPrompt.words("long_hair"), "long hair")
        XCTAssertEqual(StudyPrompt.words("looking_at_viewer"), "looking at viewer")
        XCTAssertEqual(StudyPrompt.words("1girl"), "1girl")
        for keep in ["^_^", ">_<", ":d", "!"] { XCTAssertEqual(StudyPrompt.words(keep), keep) }
    }

    func testOrderedGivesHeadcountThenCharactersThenSeriesThenGeneralTagsAndLeavesOutBookkeeping() {
        var tagged = post(1, ["smile", "artist_x", "vocaloid", "hatsune_miku", "solo", "1girl", "absurdres", "translated",
                              "meta_x", "cat5", "scenery", "smile", "highres"])
        tagged.artists = ["artist_x"]
        tagged.metadataTags = ["meta_x"]
        tagged.tagCategories = ["hatsune_miku": 4, "vocaloid": 3, "cat5": 5, "artist_x": 1]
        XCTAssertEqual(StudyPrompt.ordered(tagged), ["solo", "1girl", "hatsune_miku", "vocaloid", "smile", "scenery"])
        XCTAssertEqual(StudyPrompt.ordered(tagged, artists: true), ["solo", "1girl", "hatsune_miku", "vocaloid", "artist_x", "smile", "scenery"])
    }

    func testPromptTextWritesNaturalEscapedAndRawTagStyles() {
        let tags = ["long_hair", "^_^", "bow_(weapon)", "blue_eyes"]
        XCTAssertEqual(StudyPrompt.text(tags, style: .natural), "long hair, ^_^, bow (weapon), blue eyes")
        XCTAssertEqual(StudyPrompt.text(tags, style: .escaped), "long hair, ^_^, bow \\(weapon\\), blue eyes")
        XCTAssertEqual(StudyPrompt.text(tags, style: .tags), "long_hair ^_^ bow_(weapon) blue_eyes")
        XCTAssertEqual(StudyPrompt.text([], style: .natural), "")
    }

    // MARK: - StudyDText

    func testBlocksReadHeadingsBulletsAndWrappedParagraphsAndDropEmbeddedPostsTablesAndExpandMarks() {
        let text = """
        h4. Title
        Some wrapped
        text here.
        h4#anchor. Second
        * one
        ** two
        !post #1
        * !post #1
        [table]
        [tr][td]x[/td][/tr]
        [/table]
        [expand=More]
        Hidden words
        [/expand]
        """
        XCTAssertEqual(describe(StudyDText.blocks(text)), ["h:Title", "p:Some wrapped text here.", "h:Second", "b1:one", "b2:two", "p:Hidden words"])
    }

    func testBlocksSeparateParagraphsAtBlankLinesAndTolerateWindowsLineEndings() {
        XCTAssertEqual(describe(StudyDText.blocks("first line\r\nsecond line\r\n\r\nnext")), ["p:first line second line", "p:next"])
        XCTAssertEqual(describe(StudyDText.blocks("[table]a[/table]\nafter")), ["p:after"])
        XCTAssertEqual(describe(StudyDText.blocks("")), [])
    }

    func testInlineTurnsTagLinksIntoLinksTheReaderCanOpen() throws {
        let plain = StudyDText.inline("see [[cowboy shot]] now")
        XCTAssertEqual(String(plain.characters), "see cowboy shot now")
        XCTAssertEqual(links(plain).map(\.text), ["cowboy shot"])
        XCTAssertEqual(links(plain).map(\.tag), ["cowboy_shot"])

        let labelled = StudyDText.inline("[[cowboy_shot|a framing]] and [[watercolor (medium)|]]")
        XCTAssertEqual(String(labelled.characters), "a framing and watercolor")
        XCTAssertEqual(links(labelled).map(\.text), ["a framing", "watercolor"])
        XCTAssertEqual(links(labelled).map(\.tag), ["cowboy_shot", "watercolor_(medium)"])
    }

    func testInlineMarksBoldStronglyEmphasizedAndShowsOnlyTheLabelOfAnOrdinaryLink() throws {
        let bold = StudyDText.inline("a [b]bold[/b] word")
        XCTAssertEqual(String(bold.characters), "a bold word")
        let run = try XCTUnwrap(bold.runs.first { String(bold[$0.range].characters) == "bold" })
        XCTAssertEqual(run.inlinePresentationIntent, InlinePresentationIntent.stronglyEmphasized)
        let other = try XCTUnwrap(bold.runs.first { String(bold[$0.range].characters).contains("word") })
        XCTAssertNil(other.inlinePresentationIntent)

        let external = StudyDText.inline("see \"label\":https://example.org now")
        XCTAssertEqual(String(external.characters), "see label now")
        XCTAssertTrue(links(external).isEmpty, "An outside address is not opened from the reader")
    }

    func testPlainJoinsHeadingsBulletsAndParagraphsIntoCopyableLines() {
        XCTAssertEqual(StudyDText.plain("h4. Head\n* item\ntext [[a b]]"), "Head\n• item\ntext a b")
    }

    func testTagLinksRoundTripAndAnOrdinaryAddressIsNotATag() throws {
        for name in ["cowboy_shot", "watercolor_(medium)", "^_^"] {
            let url = try XCTUnwrap(StudyDText.link(name))
            XCTAssertEqual(StudyDText.tag(from: url), name)
        }
        XCTAssertNil(StudyDText.tag(from: URL(string: "https://example.org")!))
        XCTAssertEqual(StudyDText.tagName(" Cowboy Shot "), "cowboy_shot")
    }

    // MARK: - BooruClient

    func testDanbooruTagsRequestsTheSortedCommaJoinedNamesWithAnOnlyFieldList() async throws {
        let client = mocked { request in self.tagsReply(request) }
        let found = try await client.tags(server: dan, names: ["b", "a", "a", "with space", "with,comma"])
        let request = try XCTUnwrap(StudyURLProtocol.requests.first)
        XCTAssertEqual(StudyURLProtocol.requests.count, 1)
        XCTAssertTrue(request.url!.path.hasSuffix("/tags.json"))
        XCTAssertEqual(query(request)["search[name_comma]"], "a,b")
        let only = try XCTUnwrap(query(request)["only"])
        XCTAssertTrue(only.contains("name") && only.contains("post_count") && only.contains("category"))
        XCTAssertEqual(found.map(\.name).sorted(), ["a", "b"])
        XCTAssertEqual(found.first { $0.name == "b" }?.count, 2)
    }

    func testTagsAreAskedInSeveralRequestsWhenThereAreMoreThanOneBatch() async throws {
        let client = mocked { request in self.tagsReply(request) }
        let names = (0..<(BooruClient.tagBatch * 2 + 5)).map { String(format: "tag%04d", $0) }
        let found = try await client.tags(server: dan, names: names)
        XCTAssertEqual(StudyURLProtocol.requests.count, 3)
        for request in StudyURLProtocol.requests {
            XCTAssertLessThanOrEqual(try XCTUnwrap(query(request)["search[name_comma]"]).split(separator: ",").count, BooruClient.tagBatch)
        }
        XCTAssertEqual(Set(found.map(\.name)), Set(names))
        let empty = try await client.tags(server: dan, names: [])
        XCTAssertEqual(empty, [])
        XCTAssertEqual(StudyURLProtocol.requests.count, 3, "Nothing to ask means no request")
    }

    func testTagsTheServerAnswersWithoutBeingAskedAreDropped() async throws {
        let client = mocked { _ in (200, #"[{"name":"a","post_count":5,"category":0},{"name":"intruder","post_count":9,"category":0},{"name":"b","post_count":3,"category":4}]"#) }
        let found = try await client.tags(server: dan, names: ["a", "b"])
        XCTAssertEqual(found.map(\.name), ["a", "b"])
        XCTAssertEqual(found.map(\.category), [0, 4])
    }

    func testGelbooruTagsUseTheDapiTagPageWithSpaceJoinedNames() async throws {
        let client = mocked { _ in (200, #"{"tag":[{"name":"a","count":3,"type":0},{"name":"b","count":4,"type":4},{"name":"other","count":1,"type":0}]}"#) }
        let website = BooruServer(id: "test-gel-site", name: "Gel", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        let found = try await client.tags(server: website, names: ["b", "a"])
        let request = try XCTUnwrap(StudyURLProtocol.requests.first)
        XCTAssertTrue(request.url!.path.hasSuffix("index.php"))
        XCTAssertEqual(query(request)["page"], "dapi")
        XCTAssertEqual(query(request)["s"], "tag")
        XCTAssertEqual(query(request)["names"], "a b")
        XCTAssertEqual(found.map(\.name), ["a", "b"])
        XCTAssertEqual(found.map(\.count), [3, 4])
    }

    func testOlderGelbooruServersAreAskedForOneTagAtATimeBecauseTheyIgnoreSeveralNames() async throws {
        let client = mocked { _ in (200, #"<?xml version="1.0" encoding="UTF-8"?><tags type="array"><tag type="0" count="362090" name="cowboy_shot" ambiguous="false" id="155086"/></tags>"#) }
        let found = try await client.tags(server: gelbooru, names: ["cowboy_shot"])
        let request = try XCTUnwrap(StudyURLProtocol.requests.first)
        XCTAssertEqual(query(request)["name"], "cowboy_shot")
        XCTAssertNil(query(request)["names"])
        XCTAssertEqual(found.map(\.count), [362090])
        do { _ = try await client.tags(server: gelbooru, names: ["a", "b"]); XCTFail("Several names cannot be asked at once") }
        catch { guard case BooruError.unsupported = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(StudyURLProtocol.requests.count, 1, "No request is sent for a lookup the server cannot answer")
    }

    func testMoebooruTagsAreUnsupportedAndSendNoRequest() async {
        let client = mocked { _ in (200, "[]") }
        do { _ = try await client.tags(server: moebooru, names: ["a"]); XCTFail("Expected unsupported") }
        catch { XCTAssertTrue(isUnsupported(error), "\(error)") }
        XCTAssertTrue(StudyURLProtocol.requests.isEmpty)
    }

    func testWikiRequestsTheTitleSearchAndReadsTheTitleBodyAndOtherNames() async throws {
        let client = mocked { _ in (200, #"[{"title":"cowboy_shot","body":"line one\r\nline two","other_names":["カウボーイショット","","牛仔镜头"],"is_deleted":false}]"#) }
        let wiki = try await client.wiki(server: dan, tag: "cowboy_shot")
        let request = try XCTUnwrap(StudyURLProtocol.requests.first)
        XCTAssertTrue(request.url!.path.hasSuffix("/wiki_pages.json"))
        XCTAssertEqual(query(request)["search[title]"], "cowboy_shot")
        XCTAssertEqual(wiki?.title, "cowboy_shot")
        XCTAssertEqual(wiki?.body, "line one\nline two")
        XCTAssertEqual(wiki?.otherNames, ["カウボーイショット", "牛仔镜头"], "Other names are kept, empty ones are not")
    }

    func testWikiIsNilForAnEmptyAnswerAndForADeletedPage() async throws {
        let empty = mocked { _ in (200, "[]") }
        let none = try await empty.wiki(server: dan, tag: "nothing")
        XCTAssertNil(none)
        let deleted = mocked { _ in (200, #"[{"title":"gone","body":"text","other_names":[],"is_deleted":true}]"#) }
        let gone = try await deleted.wiki(server: dan, tag: "gone")
        XCTAssertNil(gone)
        let later = mocked { _ in (200, #"[{"title":"gone","body":"old","is_deleted":true},{"title":"kept","body":"new","is_deleted":false}]"#) }
        let kept = try await later.wiki(server: dan, tag: "kept")
        XCTAssertEqual(kept?.title, "kept")
    }

    func testRelatedTagsRequestTheQueryReadNameCategoryCountAndFrequencyAndLeaveOutTheAskedTag() async throws {
        let body = #"{"query":"cowboy_shot","related_tags":[{"tag":{"name":"cowboy_shot","category":0,"post_count":100},"frequency":1.0},{"tag":{"name":"smile","category":0,"post_count":500},"frequency":0.4},{"tag":{"name":"hatsune_miku","category":4,"post_count":9000},"frequency":0.25}]}"#
        let client = mocked { _ in (200, body) }
        let related = try await client.relatedTags(server: dan, tag: "cowboy_shot")
        let request = try XCTUnwrap(StudyURLProtocol.requests.first)
        XCTAssertTrue(request.url!.path.hasSuffix("/related_tag.json"))
        XCTAssertEqual(query(request)["query"], "cowboy_shot")
        XCTAssertEqual(related, [StudyRelatedTag(name: "smile", category: 0, count: 500, frequency: 0.4),
                                 StudyRelatedTag(name: "hatsune_miku", category: 4, count: 9000, frequency: 0.25)])
    }

    func testWikiAndRelatedTagsAreUnsupportedOnServersThatAreNotDanbooru() async {
        let client = mocked { _ in (200, "[]") }
        for server in [gelbooru, moebooru] {
            do { _ = try await client.wiki(server: server, tag: "a"); XCTFail("Expected unsupported") }
            catch { XCTAssertTrue(isUnsupported(error), "\(error)") }
            do { _ = try await client.relatedTags(server: server, tag: "a"); XCTFail("Expected unsupported") }
            catch { XCTAssertTrue(isUnsupported(error), "\(error)") }
        }
        XCTAssertTrue(StudyURLProtocol.requests.isEmpty)
    }

    func testAProviderWithoutTagPagesThrowsUnsupportedByDefault() async {
        let source = StudyFakeSource()
        do { _ = try await source.tags(server: dan, names: ["a"]); XCTFail("Expected unsupported") } catch { XCTAssertTrue(isUnsupported(error)) }
        do { _ = try await source.wiki(server: dan, tag: "a"); XCTFail("Expected unsupported") } catch { XCTAssertTrue(isUnsupported(error)) }
        do { _ = try await source.relatedTags(server: dan, tag: "a"); XCTFail("Expected unsupported") } catch { XCTAssertTrue(isUnsupported(error)) }
    }

    func testSuggestionsStillReturnAtMostTwelveByDefaultAndHonourAnExplicitLimit() throws {
        let rows = (0..<30).map { #"{"name":"tag\#($0)","post_count":\#($0),"category":0}"# }.joined(separator: ",")
        let data = Data("[\(rows)]".utf8)
        XCTAssertEqual(try BooruDecoder.suggestions(data, server: dan).count, 12)
        XCTAssertEqual(try BooruDecoder.suggestions(data, server: dan, limit: 30).count, 30)
        XCTAssertEqual(try BooruDecoder.suggestions(data, server: dan, limit: 5).count, 5)
        let names = Data((0..<20).map { "\"n\($0)\"" }.joined(separator: ",").wrapped("[", "]").utf8)
        XCTAssertEqual(try BooruDecoder.suggestions(names, server: dan).count, 12)
        XCTAssertEqual(try BooruDecoder.suggestions(names, server: dan, limit: 20).count, 20)
    }

    // MARK: - StudyLookup.shown

    @MainActor func testShownDropsBlacklistedUnusableAndRemovedPostsAndKeepsTheRest() throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        try store.setBlacklist("hidden_tag", serverID: dan.id)
        var removed = post(5, ["solo"]); removed.isBanned = true
        var bare = post(6, ["solo"]); bare.previewURL = nil; bare.sampleURL = nil; bare.fileURL = nil
        let posts = [post(1, ["solo"]), post(2, ["solo", "hidden_tag"]), post(3, ["solo"], ext: "mp4"), post(4, ["solo", "animated"]), removed, bare, post(7, ["1girl"])]
        XCTAssertEqual(StudyLookup.shown(posts, store: store).map(\.postID), [1, 7])
    }

    @MainActor func testShownAppliesEachServersOwnBlacklist() throws {
        let store = try BooruStore()
        let other = BooruServer(id: "study-other", name: "Other", baseURL: URL(string: "https://other.example")!, engine: .danbooru)
        try store.saveServer(dan)
        try store.saveServer(other)
        try store.setBlacklist("solo", serverID: dan.id)
        let posts = [post(1, ["solo"]), BooruFixtureSource.post(2, server: other, tags: ["solo"])]
        XCTAssertEqual(StudyLookup.shown(posts, store: store).map(\.id), [other.id + ":2"])
    }

    @MainActor func testShownKeepsOnlySafebooruPostsInSafeMode() throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        if !store.servers.contains(where: \.isSafebooru) { try store.saveServer(.safebooru()) }
        let safe = try XCTUnwrap(store.servers.first(where: \.isSafebooru))
        let posts = [post(1, ["solo"]), BooruFixtureSource.post(2, server: safe, tags: ["solo"])]
        XCTAssertEqual(StudyLookup.shown(posts, store: store).count, 2)
        store.safeMode = true
        XCTAssertEqual(StudyLookup.shown(posts, store: store).map(\.serverID), [safe.id])
    }

    // MARK: - StudySession

    @MainActor func testASessionAsksRecordsEachAnswerAndFinishesWithResultsAndTheRightCount() async throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        try store.setSelectedServers([dan.id])
        let session = StudySession(scope: .tags(["s1", "s2"]), store: store, source: StudyFakeSource(), engine: tinyEngine)
        XCTAssertEqual(session.phase, .loading)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        let first = try XCTUnwrap(session.question)
        XCTAssertEqual(first.tag.name, "s1")
        XCTAssertEqual(session.tags.map(\.name), ["s1", "s2"])

        session.choose(first.answer)
        XCTAssertEqual(session.phase, .answered(first.answer))
        XCTAssertEqual(session.results.map(\.right), [true])
        let stored = try store.studyStore.progress()
        XCTAssertEqual(stored["s1"]?.step, 1)
        XCTAssertEqual(stored["s1"]?.correct, 1)
        let days = try store.studyStore.days()
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.answered, 1)
        XCTAssertEqual(days.first?.correct, 1)
        session.choose(0)
        XCTAssertEqual(session.results.count, 1, "An answered question cannot be answered again")

        await session.advance()
        XCTAssertEqual(session.phase, .asking)
        let second = try XCTUnwrap(session.question)
        XCTAssertEqual(second.tag.name, "s2")
        let wrong = (second.answer + 1) % second.choiceCount
        session.choose(wrong)
        XCTAssertEqual(session.phase, .answered(wrong))
        XCTAssertEqual(try store.studyStore.progress()["s2"]?.wrong, 1)
        XCTAssertEqual(try store.studyStore.days().first?.answered, 2)
        XCTAssertEqual(try store.studyStore.days().first?.correct, 1)

        await session.advance()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertNil(session.question)
        XCTAssertEqual(session.results.map(\.tag.name), ["s1", "s2"])
        XCTAssertEqual(session.results.map(\.right), [true, false])
        XCTAssertEqual(session.rightCount, 1)
    }

    @MainActor func testASessionAsksByMeaningWhenTheServerCannotBeReadAndSaysItHadNoPictures() async throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        try store.setSelectedServers([dan.id])
        let session = StudySession(scope: .tags(["s1", "s2"]), store: store, source: StudyFakeSource(failing: true), engine: tinyEngine)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(session.question?.kind, .meaningToTag)
        XCTAssertTrue(session.withoutPictures)
        let question = try XCTUnwrap(session.question)
        XCTAssertEqual(question.choices[question.answer].name, "s1")
        session.choose(question.answer)
        await session.advance()
        XCTAssertEqual(session.question?.kind, .meaningToTag)
    }

    @MainActor func testASessionWithoutAChosenServerAsksByMeaningWithoutClaimingPicturesWereMissing() async throws {
        let store = try BooruStore()
        XCTAssertTrue(store.selectedServers.isEmpty)
        let session = StudySession(scope: .tags(["s1"]), store: store, source: StudyFakeSource(), engine: tinyEngine)
        await session.start()
        XCTAssertEqual(session.question?.kind, .meaningToTag)
        XCTAssertFalse(session.withoutPictures)
    }

    @MainActor func testASessionThatDoesNotRecordWritesNothing() async throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        try store.setSelectedServers([dan.id])
        let session = StudySession(scope: .tags(["s1", "s2"]), store: store, source: StudyFakeSource(), engine: tinyEngine, records: false)
        await session.start()
        session.choose(try XCTUnwrap(session.question).answer)
        await session.advance()
        session.choose(try XCTUnwrap(session.question).answer)
        await session.advance()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.rightCount, 2)
        XCTAssertTrue(try store.studyStore.progress().isEmpty)
        XCTAssertTrue(try store.studyStore.days().isEmpty)
    }

    @MainActor func testASessionWithNoTagsToStudyFinishesAtOnce() async throws {
        let store = try BooruStore()
        let session = StudySession(scope: .tags(["not_taught"]), store: store, source: StudyFakeSource(), engine: tinyEngine)
        await session.start()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertNil(session.question)
        XCTAssertEqual(session.results, [])
    }

    // MARK: - Fixtures

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func due(_ tag: String, _ now: Date, daysAgo: Int) -> StudyProgress {
        StudyProgress(tag: tag, step: 1, due: now.addingTimeInterval(Double(-daysAgo) * 86_400), correct: 1)
    }

    private func tagInfo(_ name: String, count: Int?) -> StudyTagInfo {
        StudyTagInfo(name: name, count: count, category: 0,
                     wiki: StudyWiki(title: name, body: "body", otherNames: ["x"]),
                     related: [StudyRelatedTag(name: "other", category: 0, count: 3, frequency: 0.5)],
                     fetched: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()), complete: true)
    }

    private var dan: BooruServer { .init(id: "test-dan", name: "Test", baseURL: URL(string: "https://example.com/booru")!, engine: .danbooru) }
    private var gelbooru: BooruServer { .init(id: "test-gel", name: "Gel", baseURL: URL(string: "https://gel.example.com")!, engine: .gelbooru) }
    private var moebooru: BooruServer { .init(id: "test-moe", name: "Moe", baseURL: URL(string: "https://moe.example.com")!, engine: .moebooru) }

    private func post(_ id: Int64, _ tags: [String], ext: String = "png") -> BooruPost {
        var value = BooruFixtureSource.post(id, server: dan, tags: tags)
        value.fileExtension = ext
        return value
    }

    private func plainTag(_ name: String, confusable: [String]? = nil) -> StudyTag {
        StudyTag(name: name, ko: name, ja: name, note: ["en": name], confusable: confusable)
    }

    /// Eight tags in one unit and three in another, for choosing rounds.
    private var roundCurriculum: StudyCurriculum {
        StudyCurriculum(units: [
            StudyUnit(id: "r1", title: ["en": "R1"], summary: ["en": ""], groups: [
                StudyGroup(id: "r1.a", title: ["en": "A"], tags: (1...8).map { plainTag("t\($0)") })
            ]),
            StudyUnit(id: "r2", title: ["en": "R2"], summary: ["en": ""], groups: [
                StudyGroup(id: "r2.a", title: ["en": "B"], tags: (1...3).map { plainTag("w\($0)") })
            ])
        ])
    }
    private var roundEngine: StudyEngine { StudyEngine(curriculum: roundCurriculum) }

    /// An exclusive group, a loose group and an abstract group, for building questions.
    private var tinyCurriculum: StudyCurriculum {
        StudyCurriculum(units: [
            StudyUnit(id: "u1", title: ["en": "U1"], summary: ["en": ""], groups: [
                StudyGroup(id: "g1", title: ["en": "Shot"], exclusive: true, tags: [plainTag("s1", confusable: ["m1"]), plainTag("s2"), plainTag("s3"), plainTag("s4")]),
                StudyGroup(id: "g2", title: ["en": "Misc"], tags: [plainTag("m1"), plainTag("m2"), plainTag("m3")])
            ]),
            StudyUnit(id: "u2", title: ["en": "U2"], summary: ["en": ""], groups: [
                StudyGroup(id: "g3", title: ["en": "Meaning"], exclusive: true, visual: false, tags: [plainTag("x1"), plainTag("x2"), plainTag("x3"), plainTag("x4")])
            ])
        ])
    }
    private var tinyEngine: StudyEngine { StudyEngine(curriculum: tinyCurriculum) }
    private func tinyTag(_ name: String) -> StudyTag { tinyCurriculum.tag(name) ?? plainTag(name) }

    private func describe(_ blocks: [StudyDText.Block]) -> [String] {
        blocks.map { block in
            switch block {
            case .heading(let value): return "h:" + value
            case .paragraph(let value): return "p:" + String(value.characters)
            case .bullet(let depth, let value): return "b\(depth):" + String(value.characters)
            }
        }
    }

    private func links(_ text: AttributedString) -> [(text: String, tag: String?)] {
        text.runs.compactMap { run in run.link.map { (text: String(text[run.range].characters), tag: StudyDText.tag(from: $0)) } }
    }

    func testTagInfoIsKeptOnceCompleteAndAskedAgainWhenAPageDidNotAnswer() async throws {
        let store = try BooruStore()
        try store.saveServer(dan); try store.setSelectedServers([dan.id])
        let source = StudyInfoSource()
        let first = await StudyLookup.info("cowboy_shot", store: store, source: source)
        XCTAssertEqual(first?.count, 362_090)
        XCTAssertEqual(first?.wiki?.otherNames, ["カウボーイショット"])
        XCTAssertEqual(first?.related.map(\.name), ["upper_body"])
        XCTAssertEqual(first?.complete, true)
        _ = await StudyLookup.info("cowboy_shot", store: store, source: source)
        let calls = await source.calls
        XCTAssertEqual(calls, 3, "A complete, recent answer is not asked for again")

        await source.failWiki(true)
        let partial = await StudyLookup.info("smile", store: store, source: source)
        XCTAssertEqual(partial?.count, 362_090)
        XCTAssertNil(partial?.wiki)
        XCTAssertEqual(partial?.complete, false, "A page that did not answer is asked for again next time")
        await source.failWiki(false)
        let retried = await StudyLookup.info("smile", store: store, source: source)
        XCTAssertNotNil(retried?.wiki)
        XCTAssertEqual(retried?.complete, true)

        let counts = await StudyLookup.counts(["cowboy_shot", "smile", "grin"], store: store, source: source)
        XCTAssertEqual(counts["grin"], 362_090, "Counts of a whole unit are read together and kept")
        XCTAssertNotNil(try store.studyStore.info("cowboy_shot", address: dan.canonicalAddress)?.wiki, "Reading counts keeps the pages already known")
        XCTAssertEqual(try store.studyStore.info("grin", address: dan.canonicalAddress)?.complete, false)

        await source.omit("no_such_tag")
        let before = await source.calls
        let unknown = await StudyLookup.counts(["no_such_tag"], store: store, source: source)
        XCTAssertEqual(unknown["no_such_tag"], 0, "A tag the server leaves out has no posts there")
        _ = await StudyLookup.counts(["no_such_tag"], store: store, source: source)
        let after = await source.calls
        XCTAssertEqual(after, before + 1, "A tag the server does not know is not asked for every time")
    }

    private func isUnsupported(_ error: Error) -> Bool {
        if case BooruError.unsupported = error { return true }
        return false
    }

    // MARK: HTTP stub

    private func mocked(_ handler: @escaping (URLRequest) -> (Int, String)) -> BooruClient {
        StudyURLProtocol.reset(handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StudyURLProtocol.self]
        return BooruClient(session: URLSession(configuration: config))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }

    /// Answers a Danbooru tag search with one row per asked name, each with a count of its position.
    private func tagsReply(_ request: URLRequest) -> (Int, String) {
        let asked = (query(request)["search[name_comma]"] ?? "").split(separator: ",").map(String.init)
        let rows = asked.enumerated().map { ["name": $1, "post_count": $0 + 1, "category": 0] as [String: Any] }
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return (200, String(decoding: data, as: UTF8.self))
    }
}

private extension String {
    func wrapped(_ open: String, _ close: String) -> String { open + self + close }
}

/// A small deterministic generator, so that a seed always gives the same round.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private final class StudyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> (Int, String))?
    private static var stored: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    static func reset(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }
        storedHandler = handler; stored = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.stored.append(request)
        let handler = Self.storedHandler
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (500, "")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers every tag with a few still pictures that carry only that tag, immediately.
private actor StudyFakeSource: BooruProviding {
    let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        if failing { throw URLError(.notConnectedToInternet) }
        let base = Int64(query.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 100_000 }) * 10
        return .init(posts: (0..<5).map { BooruFixtureSource.post(base + Int64($0), server: server, tags: [query]) }, hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}

/// Answers tag lookups at once and counts them; the tag page can be made to fail.
private actor StudyInfoSource: BooruProviding {
    private(set) var calls = 0
    private var wikiFails = false
    func failWiki(_ value: Bool) { wikiFails = value }
    private var omitted: Set<String> = []
    func omit(_ name: String) { omitted.insert(name) }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
    func tags(server: BooruServer, names: [String]) async throws -> [BooruTag] {
        calls += 1
        return names.filter { !omitted.contains($0) }.map { BooruTag(name: $0, count: 362_090, category: 0) }
    }
    func wiki(server: BooruServer, tag: String) async throws -> StudyWiki? {
        calls += 1
        if wikiFails { throw URLError(.timedOut) }
        return StudyWiki(title: tag, body: "A page.", otherNames: ["カウボーイショット"])
    }
    func relatedTags(server: BooruServer, tag: String) async throws -> [StudyRelatedTag] {
        calls += 1
        return [.init(name: "upper_body", category: 0, count: 10, frequency: 0.4)]
    }
}
