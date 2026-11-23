import CryptoKit
import GRDB
import XCTest
@testable import TEGNAL

/// The AI lab: its script files, its rules for opening cards, and its money.
@MainActor
final class LabTests: XCTestCase {
    private var course: LabCourse { LabCourse.bundled }

    private func store() -> LabStore {
        LabStore(course: .bundled, shop: .bundled, diagnosis: .bundled, records: LabMemoryRecords(), edition: LabEdition.bundled)
    }

    // MARK: - Script files

    func testTheBundledCourseHasFifteenEpisodesInFourSeasons() {
        XCTAssertEqual(course.seasons.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(course.episodes.map(\.id), (1...15).map { String(format: "ep%02d", $0) })
        XCTAssertEqual(course.episodes.map(\.number), Array(1...15), "An episode's number matches its place in the deck")
        let colors = course.info.cardColors ?? []
        XCTAssertEqual(colors, ["1F4D3A", "2B2F77", "6B1F2A", "6E4A12", "0F4C5C"], "The system sheet's card colours, without 먹")
        // Cards take the colours in turn by number: card 6 comes round to the first again.
        XCTAssertEqual(course.episodes.prefix(6).map(course.color), ["1F4D3A", "2B2F77", "6B1F2A", "6E4A12", "0F4C5C", "1F4D3A"])
    }

    func testEveryEpisodeHasOneRightChoiceTrapsWithTheirFailsAndThreeUses() {
        for episode in course.episodes {
            XCTAssertEqual(episode.choices.filter(\.isRight).count, 1, episode.id)
            for choice in episode.choices where !choice.isRight {
                XCTAssertNotNil(choice.fail, "\(episode.id): a trap needs its 망작")
            }
            XCTAssertFalse(episode.disaster.ask.isEmpty || episode.disaster.reply.isEmpty || episode.disaster.verdict.isEmpty, episode.id)
            XCTAssertFalse(episode.card.line.isEmpty, episode.id)
            XCTAssertEqual(episode.card.uses.count, 3, episode.id)
            XCTAssertGreaterThan(episode.impact, 0, episode.id)
            XCTAssertGreaterThan(episode.reward, 0, episode.id)
        }
        let ids = course.fails.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Every 망작 has its own id")
    }

    /// Bigger differences come first: no card adds more than a card before it.
    func testImpactGoesDownTheDeckAndEveryCardTakesTheRateToOneHundred() {
        let impacts = course.episodes.map(\.impact)
        XCTAssertEqual(impacts, impacts.sorted(by: >), "Cards are ordered by how much difference they make")
        XCTAssertEqual(course.top, 100)
    }

    /// Each tool must be finishable with what its file gives it, and the course keeps every rule an imported course is held to.
    func testTheBundledCourseKeepsTheCourseRules() {
        XCTAssertEqual(course.problems(), [])
    }

    func testTextCanBeOneStringLinesOrPerLanguage() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(LabText.self, from: Data(#""한 줄""#.utf8)).resolved("en"), "한 줄", "Plain text shows in every language until translated")
        XCTAssertEqual(try decoder.decode(LabText.self, from: Data(#"["첫 줄", "둘째 줄"]"#.utf8)).resolved("ko"), "첫 줄\n둘째 줄")
        let both = try decoder.decode(LabText.self, from: Data(#"{"ko": "안녕", "en": ["Hello", "there"]}"#.utf8))
        XCTAssertEqual(both.resolved("en"), "Hello\nthere")
        XCTAssertEqual(both.resolved("ja"), "안녕")
        let option = try decoder.decode([LabOption].self, from: Data(#"["짧게", {"label": "길게", "line": "한 줄 더"}]"#.utf8))
        XCTAssertEqual(option.map { $0.label.text }, ["짧게", "길게"])
        XCTAssertEqual(option[1].line?.text, "한 줄 더")
    }

    // MARK: - Opening cards

    /// Cards open one at a time, in deck order, season after season.
    func testCardsOpenOneAtATimeInDeckOrder() {
        let store = store()
        for episode in course.episodes {
            XCTAssertEqual(store.openCards.map(\.id), [episode.id], "Only the next card is open")
            XCTAssertEqual(store.next?.id, episode.id)
            store.engrave(episode, failsHung: 0)
        }
        XCTAssertTrue(store.openCards.isEmpty)
        XCTAssertNil(store.next)
    }

    func testTheRateClimbsByEachCardsImpactAndPlayingAgainChangesNothing() {
        let store = store()
        XCTAssertEqual(store.rate, course.base)
        let first = store.engrave(course.episode("ep01")!, failsHung: 2)
        XCTAssertEqual(first.before, course.base)
        XCTAssertEqual(first.after, course.base + course.episode("ep01")!.impact)
        XCTAssertEqual(first.cardReward, course.episode("ep01")!.reward)
        XCTAssertEqual(first.failReward, 2 * course.info.rewards.fail)
        let again = store.engrave(course.episode("ep01")!, failsHung: 0)
        XCTAssertFalse(again.first)
        XCTAssertEqual(again.cardReward, 0)
        XCTAssertEqual(again.after, first.after)
    }

    func testCheatSheetSectionsOpenWithCardsOneAndFour() {
        let store = store()
        let edition = try! XCTUnwrap(store.edition)
        XCTAssertEqual(edition.sections.compactMap(\.opens), ["ep01", "ep04"])
        XCTAssertFalse(store.editionWaiting, "Nothing is readable before card 001")
        XCTAssertEqual(store.read(), 0)
        store.engrave(course.episode("ep01")!, failsHung: 0)
        XCTAssertTrue(store.editionWaiting)
        XCTAssertEqual(store.read(), edition.reward ?? course.info.rewards.edition)
        XCTAssertFalse(store.editionWaiting)
        XCTAssertEqual(store.read(), 0, "An edition pays once")
    }

    /// A downloaded edition is used only when TEGNAL's key signed exactly those bytes.
    func testADownloadedEditionMustBeSigned() throws {
        let key = P256.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(XCTUnwrap(LabEdition.bundled))
        func envelope(_ bytes: Data, _ signature: Data) -> Data {
            try! JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(), "signature": signature.base64EncodedString()])
        }
        let signature = try key.signature(for: payload).derRepresentation
        XCTAssertEqual(try LabSheetSource.open(envelope(payload, signature), key: key.publicKey).id, LabEdition.bundled?.id)
        var changed = payload
        changed[changed.count / 2] ^= 0x01
        XCTAssertThrowsError(try LabSheetSource.open(envelope(changed, signature), key: key.publicKey), "Changed bytes are refused")
        XCTAssertThrowsError(try LabSheetSource.open(envelope(payload, signature), key: P256.Signing.PrivateKey().publicKey), "Another key is refused")
    }

    // MARK: - Money

    func testFailsPayOnceAndTheBalanceIsIncomeLessPurchases() {
        let store = store()
        let fail = course.fails[0]
        XCTAssertTrue(store.hang(fail))
        XCTAssertFalse(store.hang(fail))
        XCTAssertEqual(store.balance, course.info.rewards.fail)
    }

    /// The first purchase can be made when season 1 ends, and all cards together buy most, not all, of what lasts.
    func testPricesFollowTheAgreedRules() {
        let shop = LabShop.bundled
        let seasonOne = course.seasons[0].episodes.compactMap(course.episode).reduce(0) { $0 + $1.reward }
        let cheapest = shop.items.filter { !$0.isRepeat && !$0.isSoon }.compactMap(\.price).min() ?? .max
        XCTAssertGreaterThanOrEqual(seasonOne, cheapest, "Season 1 pays for a first purchase")
        let cards = course.episodes.reduce(0) { $0 + $1.reward }
        let share = Double(cards) / Double(shop.permanentTotal)
        XCTAssertTrue((0.6...0.7).contains(share), "All cards buy \(Int(share * 100))% of the permanent goods")
    }

    func testBuyingTheTagCourseAndItsLessonsPayingAfterwards() {
        let store = store()
        let item = try! XCTUnwrap(store.shop.item(LabStore.tagCourse))
        XCTAssertEqual(store.canBuy(item), .short(item.price!))
        for id in ["ep01", "ep02", "ep03", "ep04"] { store.engrave(course.episode(id)!, failsHung: 0) }
        store.count(lessons: 5, of: LabStore.tagCourse)
        XCTAssertEqual(store.buy(item), .bought)
        XCTAssertTrue(store.ownsTagCourse)
        XCTAssertEqual(store.canBuy(item), .owned)
        let after = store.balance
        store.count(lessons: 8, of: LabStore.tagCourse)
        XCTAssertEqual(store.balance, after + 3 * course.info.rewards.courseLesson, "Only lessons finished after buying pay")
    }

    func testALearnerWhoStudiedTagsBeforeKeepsTheCourseFree() {
        let store = store()
        store.grandfather(lessons: 12, xp: 300)
        XCTAssertTrue(store.ownsTagCourse)
        XCTAssertEqual(store.spent, 0)
        let fresh = self.store()
        fresh.grandfather(lessons: 0, xp: 0)
        XCTAssertFalse(fresh.ownsTagCourse)
    }

    func testItemsNotOnSaleCannotBeBought() {
        let store = store()
        let soon = try! XCTUnwrap(store.shop.items.first(where: \.isSoon))
        XCTAssertEqual(store.canBuy(soon), .unavailable)
    }

    // MARK: - Diagnosis

    func testTheDiagnosisPicksTheTypeMostAnswersPointTo() throws {
        let diagnosis = try XCTUnwrap(LabDiagnosis.bundled)
        XCTAssertEqual(diagnosis.result([1, 1, 2, 1])?.id, diagnosis.fallback, "No weak spot gives the fallback")
        XCTAssertEqual(diagnosis.result([0, 1, 2, 1])?.id, "default")
        XCTAssertEqual(diagnosis.result([0, 0, 0, 0])?.id, "role", "A tie goes to the type listed first")
        for type in diagnosis.types {
            XCTAssertTrue(type.episodes.allSatisfy { course.episode($0) != nil }, type.id)
        }
    }

    // MARK: - Saving

    /// Records are kept in the image database, so sync and backups carry them; reading them back gives the same progress.
    func testProgressIsSavedInTheImageDatabaseAndReadBack() throws {
        let booru = try BooruStore()
        let first = LabStore(course: .bundled, shop: .bundled, diagnosis: .bundled, records: LabDatabaseRecords(database: booru.database), edition: nil)
        first.engrave(course.episode("ep01")!, failsHung: 0)
        first.hang(course.fails[0])
        first.diagnose(try XCTUnwrap(first.diagnosis?.types.first))
        let second = LabStore(course: .bundled, shop: .bundled, diagnosis: .bundled, records: LabDatabaseRecords(database: booru.database), edition: nil)
        XCTAssertTrue(second.earned(course.episode("ep01")!))
        XCTAssertTrue(second.hung(course.fails[0]))
        XCTAssertEqual(second.progress.type, first.progress.type)
        XCTAssertEqual(second.progress, first.progress)
        let rows = try booru.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lab_records") }
        XCTAssertEqual(rows, 4, "A card, a 망작, the type and the greeting")
    }

    /// Two devices' records merge to the larger count and the earlier time, so nothing earned is lost.
    func testSyncedLabRecordsMergeWithoutLosingAnything() throws {
        let booru = try BooruStore()
        let records = LabDatabaseRecords(database: booru.database)
        try records.replace(with: [LabRecord(key: "card:ep01", value: 1, at: Date(timeIntervalSince1970: 200)),
                                   LabRecord(key: "purchase:course.tags", value: 1, text: "{\"price\":600}", at: Date(timeIntervalSince1970: 300))])
        let adapter = LibrarySyncAdapter(manga: try .inMemory(), booru: booru, mangaDefaults: UserDefaults(suiteName: UUID().uuidString)!, booruDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let snapshot = try adapter.snapshot()
        XCTAssertNotNil(snapshot.values.first { $0.table == "booru.lab_records" && $0.values["key"]?.string == "card:ep01" }, "Lab records are part of the sync snapshot")
        func change(_ values: [String: SyncValue]) -> LibrarySyncChange {
            LibrarySyncChange(row: LibrarySyncRow(table: "booru.lab_records", values: values), timestamp: 1, device: "other", deleted: false)
        }
        try adapter.apply([
            "a": change(["key": .text("card:ep01"), "value": .integer(1), "text": .null, "at": .real(100)]),
            "b": change(["key": .text("card:ep02"), "value": .integer(1), "text": .null, "at": .real(400)]),
            "c": change(["key": .text("purchase:course.tags"), "value": .integer(0), "text": .null, "at": .real(500)])
        ])
        let merged = LabProgress(records: try records.all())
        XCTAssertEqual(merged.cards["ep01"]?.timeIntervalSince1970, 100, "The earlier engraving time is kept")
        XCTAssertNotNil(merged.cards["ep02"], "A card engraved on the other device arrives")
        XCTAssertEqual(merged.purchases["course.tags"]?.count, 1, "A purchase is not undone by an older record")
        XCTAssertEqual(merged.purchases["course.tags"]?.price, 600)
    }

    func testLabRecordsGoIntoBackupsAndComeBack() throws {
        let source = try BooruStore()
        try LabDatabaseRecords(database: source.database).replace(with: [LabRecord(key: "card:ep03", value: 1, at: Date(timeIntervalSince1970: 50))])
        let backup = try BooruBackup.decode(source.exportBackup().encoded())
        XCTAssertEqual(backup.lab?.map(\.key), ["card:ep03"])
        let target = try BooruStore()
        try target.restoreBackup(backup)
        XCTAssertNotNil(LabProgress(records: try LabDatabaseRecords(database: target.database).all()).cards["ep03"])
    }

    // MARK: - Course files and the 코스 tab

    /// A small deck course in one file, as the 코스 tab imports it: one season of two episodes.
    static func courseFile(id: String = "maker.prompt-basics", edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        func episode(_ id: String, _ number: Int) -> [String: Any] {
            ["id": id, "number": number, "title": "제목 \(number)", "impact": 10, "reward": 999,
             "disaster": ["ask": "질문", "reply": "답", "verdict": "판정", "question": "어떻게 할까요?"],
             "choices": [["text": "맞는 길", "right": true, "verdict": "좋아요"],
                         ["text": "함정", "verdict": "아쉬워요", "fail": ["id": "\(id)-trap", "name": "망작", "reply": "엉망인 답"]]],
             "tool": ["kind": "stamps", "title": "도장", "stamps": ["맞음", "틀림"], "items": [["text": "문장", "answer": 0]]],
             "card": ["line": "새길 문장", "uses": ["하나", "둘", "셋"]]]
        }
        var top: [String: Any] = ["format": "tegnal-lab-course", "version": 1, "id": id, "title": "프롬프트 기초", "gauge": "실력", "base": 20,
                                  "cardColors": ["1F4D3A", "2B2F77"],
                                  "seasons": [["number": 1, "title": "첫 시즌", "order": "fixed", "episodes": ["a1", "a2"]]],
                                  "episodes": [episode("a1", 1), episode("a2", 2)]]
        edit(&top)
        return try! JSONSerialization.data(withJSONObject: top)
    }

    func testACourseFileDecodesAsAnImportedDeckCourse() throws {
        let imported = try XCTUnwrap(LabCourseFile.decode(Self.courseFile()).deck)
        XCTAssertTrue(imported.imported)
        XCTAssertEqual(imported.id, "maker.prompt-basics")
        XCTAssertEqual(imported.episodes.map(\.id), ["a1", "a2"])
        XCTAssertEqual(imported.top, 40)
        XCTAssertEqual(imported.info.rewards.fail, 0, "Rewards may be left out")
    }

    func testCourseFilesAreRefusedRatherThanCleaned() {
        func refused(_ data: Data, _ expected: LabCourseFileError? = nil, _ message: String = "") {
            XCTAssertThrowsError(try LabCourseFile.decode(data), message) { if let expected { XCTAssertEqual($0 as? LabCourseFileError, expected, message) } }
        }
        refused(Data("[]".utf8), .notCourse)
        refused(Self.courseFile { $0["format"] = "tegnal-addon" }, .notCourse)
        refused(Self.courseFile { $0["version"] = 2 }, .newer)
        refused(Self.courseFile { $0["engine"] = "flashcards" }, .newer, "An engine this app does not know asks for an update")
        refused(Self.courseFile { top in
            var episodes = top["episodes"] as! [[String: Any]]
            episodes[0]["tool"] = ["kind": "hologram", "title": "새 도구"]
            top["episodes"] = episodes
        }, .newer, "So does a tool it does not know")
        refused(Data(count: LabCourseFile.maximumBytes + 1), .tooLarge)
        refused(Self.courseFile(id: LearningCourse.labID), .invalid("id"), "The app's own course ids are taken")
        refused(Self.courseFile(id: "Bad ID"), .invalid("id"))
        refused(Self.courseFile { $0["title"] = "숨은\u{202E}글자" }, nil, "Direction overrides are refused")
        refused(Self.courseFile { $0["seasons"] = [["number": 1, "title": "시즌", "order": "fixed", "episodes": ["a1"]]] }, .invalid("episodes"), "Every episode sits in a season")
        refused(Self.courseFile { top in
            var episodes = top["episodes"] as! [[String: Any]]
            episodes[0]["choices"] = [["text": "함정뿐", "verdict": "판정"], ["text": "또 함정", "verdict": "판정"]]
            top["episodes"] = episodes
        }, nil, "An episode needs a right choice and every trap its 망작")
        refused(Self.courseFile { top in
            var episodes = top["episodes"] as! [[String: Any]]
            episodes[1]["tool"] = ["kind": "stamps", "title": "도장", "stamps": ["하나"], "items": [["text": "문장", "answer": 3]]]
            top["episodes"] = episodes
        }, .invalid("episodes.a2.tool.stamps"), "A tool that cannot be passed is refused")
    }

    /// An imported course keeps its records under its own id and pays nothing; the AI lab's money is untouched by it.
    func testAnImportedCourseKeepsItsOwnRecordsAndPaysNothing() throws {
        let store = store()
        let imported = try XCTUnwrap(LabCourseFile.decode(Self.courseFile()).deck)
        store.show(course: imported)
        XCTAssertEqual(store.next?.id, "a1")
        XCTAssertEqual(store.rate, 20)
        let engraving = store.engrave(imported.episodes[0], failsHung: 1)
        XCTAssertTrue(store.hang(imported.fails[0]))
        XCTAssertEqual(engraving.cardReward, 0)
        XCTAssertEqual(engraving.failReward, 0)
        XCTAssertEqual(store.failReward, 0)
        XCTAssertEqual(store.rate, 30)
        XCTAssertEqual(store.balance, 0, "Nothing in an imported course pays")
        XCTAssertNotNil(store.progress.cards["maker.prompt-basics/a1"])
        XCTAssertNotNil(store.progress.fails["maker.prompt-basics/a1-trap"])
        XCTAssertFalse(store.offersDiagnosis, "Card No. 000 is the AI lab's")

        store.show(course: course)
        XCTAssertEqual(store.next?.id, "ep01", "The AI lab's deck is as it was")
        XCTAssertEqual(store.rate, course.base)
        XCTAssertTrue(store.offersDiagnosis)
    }

    func testTheCatalogKeepsImportedCoursesAndRemovesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = LearningCourses(folder: folder)
        XCTAssertEqual(catalog.all.map(\.id), [LearningCourse.labID, LearningCourse.tagsID])
        let data = Self.courseFile()
        try catalog.add(data: data)
        try catalog.add(data: data)
        XCTAssertEqual(catalog.all.map(\.id), [LearningCourse.labID, LearningCourse.tagsID, "maker.prompt-basics"], "The same course again replaces it")
        XCTAssertEqual(catalog.course("maker.prompt-basics")?.engine, .deck)
        XCTAssertEqual(LearningCourses(folder: folder).imported.map(\.id), ["maker.prompt-basics"], "Kept for the next launch")
        catalog.remove("maker.prompt-basics")
        XCTAssertEqual(LearningCourses(folder: folder).imported.count, 0)
        XCTAssertThrowsError(try catalog.add(data: Self.courseFile(id: LearningCourse.labID)), "A bundled course's id is never taken")
    }

    /// Course files kept in the local docs (packed with `scripts/pack_course.py`) import as they are.
    func testTheSampleCoursesInTheDocsFolderPass() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/edu/courses")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == LabCourseFile.fileExtension } ?? []
        try XCTSkipIf(files.isEmpty, "The samples are local only")
        for url in files { XCTAssertNoThrow(try LabCourseFile.decode(LabCourseFile.data(url)), url.lastPathComponent) }
    }

    /// A course on the 2D AI course's engine: its own path, under ids of its own, with its own tags in the curriculum.
    static func tagsCourseFile(edit: (inout [String: Any]) -> Void = { _ in }) -> Data {
        var top: [String: Any] = [
            "format": "tegnal-lab-course", "version": 1, "engine": "tags", "id": "maker.backgrounds",
            "title": ["ko": "배경과 장소"], "summary": ["ko": "배경을 배웁니다"], "color": "2F9E6E", "symbol": "mountain.2",
            "groups": [["id": "places", "title": ["ko": "장소"], "tags": [["name": "lighthouse", "ko": "등대", "note": ["ko": "바닷가의 등대"]]]]],
            "sections": [["id": "one", "title": ["ko": "첫 구간"], "summary": ["ko": "요약"], "color": "2F9E6E", "lessons": [
                ["id": "intro", "kind": "concept", "symbol": "book", "title": ["ko": "소개"], "steps": [
                    ["card": ["title": ["ko": "안녕"], "body": ["ko": "배경 이야기"]]],
                    ["ask": ["question": ["ko": "질문"], "choices": [["ko": "가"], ["ko": "나"]], "answer": 0, "why": ["ko": "이유"]]]
                ]],
                ["id": "tags", "kind": "tags", "symbol": "tag", "title": ["ko": "태그"], "tags": ["lighthouse", "long_hair"]]
            ]]]
        ]
        edit(&top)
        return try! JSONSerialization.data(withJSONObject: top)
    }

    func testACourseOnTheTagsEngineBringsAPathAndTagsOfItsOwn() throws {
        let course = try LabCourseFile.decode(Self.tagsCourseFile())
        XCTAssertEqual(course.engine, .tags)
        let lessons = try XCTUnwrap(course.lessons)
        XCTAssertEqual(lessons.path.lessons.map(\.id), ["course:maker.backgrounds:intro", "course:maker.backgrounds:tags"])
        XCTAssertEqual(lessons.title["en"], "배경과 장소", "Korean-only text is shown in English too")
        let model = StudyModeModel(course: lessons)
        XCTAssertFalse(model.isMain)
        XCTAssertEqual(model.curriculum.tag("lighthouse")?.title("ko"), "등대")
        XCTAssertNotNil(model.curriculum.tag("long_hair"), "The app's own tags stay")
        XCTAssertTrue(StudyModeModel().isMain)

        XCTAssertThrowsError(try LabCourseFile.decode(Self.tagsCourseFile { top in
            var sections = top["sections"] as! [[String: Any]]
            var lessons = sections[0]["lessons"] as! [[String: Any]]
            lessons[0]["steps"] = [["card": ["title": ["ko": "가자"], "body": ["ko": "생성기"], "action": "generator"]]]
            sections[0]["lessons"] = lessons; top["sections"] = sections
        }), "Cards in course files only tell: they open nothing")
        XCTAssertThrowsError(try LabCourseFile.decode(Self.tagsCourseFile { top in
            var sections = top["sections"] as! [[String: Any]]
            var lessons = sections[0]["lessons"] as! [[String: Any]]
            lessons[1]["tags"] = ["lighthouse", "not_a_known_tag_anywhere"]
            sections[0]["lessons"] = lessons; top["sections"] = sections
        }), "Every tag of a tags lesson needs a meaning")
        XCTAssertThrowsError(try LabCourseFile.decode(Self.tagsCourseFile { top in
            var sections = top["sections"] as! [[String: Any]]
            var lessons = sections[0]["lessons"] as! [[String: Any]]
            lessons[0]["steps"] = [["match": ["pairs": []]]]
            sections[0]["lessons"] = lessons; top["sections"] = sections
        })) { XCTAssertEqual($0 as? LabCourseFileError, .newer, "A step this app does not know asks for an update") }
    }

    /// A course for a newer app is kept, named and waiting; once the app can read it, it opens like any other.
    func testACourseForANewerAppWaitsInTheCatalog() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = LearningCourses(folder: folder)
        XCTAssertThrowsError(try catalog.add(data: Self.courseFile { $0["engine"] = "flashcards"; $0["title"] = "미래 코스" })) {
            XCTAssertEqual($0 as? LabCourseFileError, .newer)
        }
        XCTAssertEqual(catalog.waiting, [WaitingCourse(id: "maker.prompt-basics", title: "미래 코스")])
        XCTAssertNil(catalog.course("maker.prompt-basics"))
        XCTAssertEqual(LearningCourses(folder: folder).waiting.map(\.id), ["maker.prompt-basics"], "Kept for after the update")
        try catalog.add(data: Self.courseFile())
        XCTAssertTrue(catalog.waiting.isEmpty)
        XCTAssertNotNil(catalog.course("maker.prompt-basics"))
    }

    /// The card that finishes a season says so, once.
    func testTheCardThatFinishesASeasonSaysSo() {
        let store = store()
        let season = course.seasons[0]
        for id in season.episodes.dropLast() { XCTAssertNil(store.engrave(course.episode(id)!, failsHung: 0).season) }
        let last = course.episode(season.episodes.last!)!
        XCTAssertEqual(store.engrave(last, failsHung: 0).season, season.number)
        XCTAssertNil(store.engrave(last, failsHung: 0).season, "Playing it again finishes nothing new")
    }
}
