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

    /// Each tool must be finishable with what its file gives it.
    func testEveryToolCanBePassed() {
        for episode in course.episodes {
            let tool = episode.tool
            switch tool.kind {
            case .switches:
                let controls = tool.controls ?? []
                XCTAssertFalse(controls.isEmpty, episode.id)
                let passing = (tool.results ?? []).filter { $0.pass == true }
                XCTAssertTrue(tool.compose != nil || passing.count >= (tool.need ?? 1), "\(episode.id): not enough passing results")
                for result in tool.results ?? [] {
                    XCTAssertEqual(result.when.count, controls.count, "\(episode.id): a result names every switch")
                    for (index, value) in result.when.enumerated() where value >= 0 {
                        XCTAssertTrue(controls[index].options.indices.contains(value), "\(episode.id): result points past a switch's positions")
                    }
                }
                if tool.compose != nil {
                    XCTAssertTrue(controls.allSatisfy { $0.options.allSatisfy { $0.line != nil } }, "\(episode.id): composed answers need a line for every position")
                }
            case .chips:
                let chips = tool.chips ?? []
                if tool.mode == "toggle" {
                    XCTAssertGreaterThanOrEqual(chips.filter { $0.line != nil }.count, tool.need ?? 1, episode.id)
                } else {
                    XCTAssertTrue(chips.contains { $0.pass == true }, "\(episode.id): one chip passes")
                    XCTAssertTrue(chips.allSatisfy { !($0.replies ?? []).isEmpty }, "\(episode.id): every chip answers")
                }
            case .stamps:
                let labels = tool.stamps ?? []
                XCTAssertEqual(labels.count, 2, episode.id)
                XCTAssertTrue((tool.items ?? []).allSatisfy { labels.indices.contains($0.answer) }, episode.id)
                XCTAssertFalse((tool.items ?? []).isEmpty, episode.id)
            case .marks:
                XCTAssertTrue((tool.pieces ?? []).contains(where: \.isTarget), episode.id)
                XCTAssertTrue(["cut", "flag", "mask"].contains(tool.style ?? "cut"), episode.id)
                if tool.style == "mask" { XCTAssertTrue((tool.pieces ?? []).filter(\.isTarget).allSatisfy { $0.swap != nil }, episode.id) }
            case .equip:
                let gear = Set((tool.gear ?? []).map(\.id))
                XCTAssertFalse((tool.missions ?? []).isEmpty, episode.id)
                for mission in tool.missions ?? [] { XCTAssertTrue(Set(mission.needs).isSubset(of: gear), "\(episode.id): a mission needs gear that is not there") }
            case .rot:
                XCTAssertGreaterThanOrEqual((tool.replies ?? []).count, tool.minRetries ?? 2, episode.id)
                XCTAssertNotNil(tool.fresh, episode.id)
            }
        }
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
}
