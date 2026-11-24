import CryptoKit
import GRDB
import XCTest
@testable import TEGNAL

/// The AI lab: its script files, its rules for opening cards, and its money.
@MainActor
final class LabTests: XCTestCase {
    private var course: LabCourse { LabCourse.bundled }

    /// The shop list as it is published: its source, `docs/live/shop.json` (local only). Nil in a checkout without it.
    static let liveShop: LabShop? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/live/shop.json")
        return (try? Data(contentsOf: url)).flatMap { try? LabShop.decode($0) }
    }()

    /// A small list shaped like the published one, for checkouts without it.
    static let fixtureShop = """
        {"format": "tegnal-lab-shop", "schemaVersion": 1, "currency": {"ko": "보석", "en": "Gems"}, "sections": [
          {"title": "코스", "items": [{"id": "course.tags", "kind": "course", "course": "2d-ai", "name": "2D AI 배우기", "price": 500}]},
          {"title": "도구", "items": [{"id": "feature.prompt-analyzer", "kind": "feature", "feature": "prompt-analyzer", "name": "프롬프트 분석기", "price": 200, "requires": "course.tags"}]},
          {"title": "생성권", "items": [{"id": "tickets.10", "kind": "ticket", "count": 10, "name": "생성권 10장", "price": 100, "repeat": true, "requires": "course.tags", "soon": true}]}
        ]}
        """

    /// The published list where it is checked out, else the small one.
    static let shop: LabShop = liveShop ?? (try! LabShop.decode(Data(fixtureShop.utf8)))

    private func store() -> LabStore {
        LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: LabMemoryRecords(), edition: LabEdition.bundled)
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

    /// What every bundled course pays when finished: the AI lab's cards, 망작 and seasons, and 2D AI 배우기's lessons, three-star
    /// lessons and sections. Cheat-sheet editions are left out: they keep coming.
    private var labPayout: Int {
        course.episodes.reduce(0) { $0 + $1.reward } + course.fails.count * course.info.rewards.fail + course.seasons.count * course.info.rewards.season
    }
    private var tagPayout: Int {
        let rates = course.info.rewards, path = StudyPath.bundled
        return path.lessons.count * (rates.courseLesson + rates.courseStars) + path.sections.count * rates.courseSection
    }

    /// The rules in `docs/features/gem-economy.md`, for every course there is.
    func testPricesFollowTheAgreedRules() throws {
        guard let shop = Self.liveShop else { throw XCTSkip("docs/live/shop.json, the list these rules are checked on, is local only") }
        // Season 1's cards and its season pay for the first course, without a single 망작.
        let seasonOne = course.seasons[0].episodes.compactMap(course.episode).reduce(0) { $0 + $1.reward } + course.info.rewards.season
        let course2D = try XCTUnwrap(shop.item(LabStore.tagCourse)?.price)
        XCTAssertGreaterThanOrEqual(seasonOne, course2D, "Season 1 pays for 2D AI 배우기")
        // A bought course pays back several times its price.
        XCTAssertGreaterThanOrEqual(tagPayout, 4 * course2D, "2D AI 배우기 pays back \(tagPayout) for \(course2D)")
        // Everything that lasts costs 50–70% of what all courses pay; the rest is left for tickets.
        let share = Double(shop.permanentTotal) / Double(labPayout + tagPayout)
        XCTAssertTrue((0.5...0.7).contains(share), "What lasts costs \(Int(share * 100))% of all courses")
        XCTAssertLessThan(labPayout, shop.permanentTotal, "The free course alone does not buy everything")
        // What the app sells offline costs what the published list asks.
        for item in LabShop.builtIn.items {
            XCTAssertEqual(item.price, shop.item(item.id)?.price, "\(item.id): the app's offline price matches docs/live/shop.json")
            XCTAssertTrue(item.supported, item.id)
        }
    }

    /// Offline, with no list ever read, the course the app carries and the prompt analyzer can still be bought.
    func testTheAppsOwnGoodsCanBeBoughtOffline() async throws {
        let store = LabStore(course: .bundled, shop: nil, diagnosis: .bundled, records: LabMemoryRecords(), edition: nil)
        var market = AddonMarket(base: AddonMarket.liveBase, publicKey: P256.Signing.PrivateKey().publicKey)
        market.fetch = { _, _ in throw AddonMarketError.offline }
        await store.refreshShop(market: market)
        XCTAssertEqual(store.shopState, .failed)
        for episode in course.episodes.prefix(4) { store.engrave(episode, failsHung: 0) }
        XCTAssertEqual(store.buy(try XCTUnwrap(store.shop.item(LabStore.tagCourse))), .bought)
        for episode in course.episodes.dropFirst(4).prefix(2) { store.engrave(episode, failsHung: 0) }
        XCTAssertEqual(store.buy(try XCTUnwrap(store.shop.item(LabFeature.promptAnalyzer.item))), .bought)
        XCTAssertTrue(store.unlocked(.promptAnalyzer))
        XCTAssertEqual(store.progress.purchases[LabFeature.promptAnalyzer.item]?.price, 200)
    }

    /// What a card, a 망작 or a season paid stays paid when the course files change their amounts later.
    func testAmountsPaidAreKeptWhenTheFilesChangeLater() throws {
        let records = LabMemoryRecords()
        let first = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        var last: LabEngraving?
        for id in ["ep01", "ep02", "ep03", "ep04"] { last = first.engrave(course.episode(id)!, failsHung: 0) }
        XCTAssertEqual(last?.seasonReward, course.info.rewards.season, "The card that finishes a season pays for it")
        first.hang(course.fails[0])
        let balance = first.balance
        XCTAssertEqual(try records.all().first { $0.key == "card:ep01" }?.value, course.episode("ep01")!.reward)

        var info = course.info
        info.rewards = LabRewards(fail: 2, edition: 2, season: 2, courseLesson: 2)
        let cheaper = LabCourse(info: info, episodes: course.episodes.map { var episode = $0; episode.reward = 3; return episode })
        let later = LabStore(course: cheaper, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        XCTAssertEqual(later.balance, balance, "Nothing already earned moves")
        later.engrave(cheaper.episode("ep05")!, failsHung: 0)
        XCTAssertEqual(later.balance, balance + 3, "What is earned from now on pays the new amount")
    }

    /// A card written before amounts were kept (value 1) counts at the course's present amount.
    func testOlderRecordsCountAtThePresentAmount() {
        let progress = LabProgress(records: [LabRecord(key: "card:ep01", value: 1, at: Date(timeIntervalSince1970: 10))])
        XCTAssertNil(progress.cardGems["ep01"])
        let store = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: { let r = LabMemoryRecords(); try? r.replace(with: progress.records); return r }(), edition: nil)
        XCTAssertEqual(store.balance, course.episode("ep01")!.reward)
    }

    func testSeasonOneBuysTheTagCourseAndItsTicketsWaitForIt() throws {
        let store = store()
        let item = try XCTUnwrap(store.shop.item(LabStore.tagCourse))
        XCTAssertEqual(store.canBuy(item), .short(item.price!))
        for id in ["ep01", "ep02", "ep03", "ep04"] { store.engrave(course.episode(id)!, failsHung: 0) }
        var tickets = try XCTUnwrap(store.shop.items.first { $0.kind == "ticket" })
        XCTAssertEqual(tickets.requires, LabStore.tagCourse)
        tickets.soon = false
        XCTAssertEqual(store.canBuy(tickets), .needs(LabStore.tagCourse), "Tickets are for the generator 2D AI 배우기 opens")
        XCTAssertEqual(store.buy(item), .bought)
        XCTAssertTrue(store.ownsTagCourse)
        XCTAssertEqual(store.canBuy(item), .owned)
        XCTAssertNotEqual(store.canBuy(tickets), .needs(LabStore.tagCourse))
    }

    /// A 2D AI 배우기 lesson pays the first time it is finished, again the first time it gets three stars, and a section pays once
    /// all its lessons are finished. Playing again, resetting the course's progress or an imported course's lesson pays nothing.
    func testTagLessonsStarsAndSectionsPayOnce() throws {
        let booru = try BooruStore()
        let store = store()
        let rates = course.info.rewards, section = try XCTUnwrap(StudyPath.bundled.sections.first)
        let ids = section.lessons.map(\.id)
        try booru.studyStore.earn(10, lesson: ids[0], stars: 2)
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, rates.courseLesson)
        try booru.studyStore.earn(10, lesson: ids[0], stars: 2)
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, 0, "Playing a lesson again pays nothing")
        try booru.studyStore.earn(10, lesson: ids[0], stars: 3)
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, rates.courseStars, "Three stars pay once")
        for id in ids.dropFirst() { try booru.studyStore.earn(10, lesson: id, stars: 1) }
        let last = store.settleTagCourse(in: booru.studyStore)
        XCTAssertEqual(last, LabTagPayout(lesson: (ids.count - 1) * rates.courseLesson, stars: 0, section: rates.courseSection), "The section pays when its last lesson is done")
        try booru.studyStore.earn(10, lesson: "course:other:one", stars: 3)
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, 0, "An imported course's lesson pays nothing")
        let balance = store.balance
        try booru.studyStore.reset()
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, 0)
        XCTAssertEqual(store.balance, balance, "Resetting the course takes nothing back")
    }

    /// A finished 2D AI 배우기 starts over from its first lesson: earlier rounds keep what they paid, and a later round pays a quarter
    /// under keys of its own, so another device reads the same round back.
    func testAFinishedTagCourseStartsOverAndPaysAQuarter() throws {
        let booru = try BooruStore()
        let records = LabMemoryRecords()
        let store = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        let rates = course.info.rewards, lessons = StudyPath.bundled.lessons
        try booru.studyStore.earn(10, lesson: lessons[0].id, stars: 3)
        store.startTagCourseOver(in: booru.studyStore)
        XCTAssertEqual(store.tagRound, 0, "Only a finished course starts over")
        for lesson in lessons { try booru.studyStore.earn(10, lesson: lesson.id, stars: 3) }
        store.settleTagCourse(in: booru.studyStore)
        XCTAssertTrue(LabStore.tagCourseFinished(try booru.studyStore.lessons()))
        let balance = store.balance
        store.startTagCourseOver(in: booru.studyStore)
        XCTAssertEqual(store.tagRound, 1)
        XCTAssertTrue(try booru.studyStore.lessons(round: 1).isEmpty, "The path starts again")
        XCTAssertEqual(try booru.studyStore.lessons().count, lessons.count, "The first round stays in the records")
        XCTAssertEqual(store.balance, balance, "What was earned stays")

        try booru.studyStore.earn(10, lesson: lessons[0].id, stars: 3, round: store.tagRound)
        try booru.studyStore.earn(10, lesson: "course:other:one", stars: 3, round: store.tagRound)
        XCTAssertNotNil(try booru.studyStore.lessons(round: 1)["course:other:one"], "An imported course's lessons have no rounds")
        let paid = store.settleTagCourse(in: booru.studyStore)
        XCTAssertEqual(paid, LabTagPayout(lesson: LabStore.share(rates.courseLesson, round: 1), stars: LabStore.share(rates.courseStars, round: 1), section: 0))
        XCTAssertEqual(store.settleTagCourse(in: booru.studyStore).total, 0, "Each round pays once")
        XCTAssertEqual(store.tagCoursePaid.lessons, lessons.count, "The kept-lessons count is the first round's")

        let synced = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        XCTAssertEqual(synced.tagRound, 1)
        XCTAssertEqual(synced.balance, store.balance)
    }

    /// 2D AI 배우기 came before the lab and was free. Its progress stays and pays, but the course must be bought to go on; the
    /// learner is told once.
    func testProgressFromBeforeTheCourseWasSoldPaysButDoesNotOpenIt() throws {
        let booru = try BooruStore()
        let store = store()
        XCTAssertFalse(store.owesLegacyNotice, "Nothing to tell someone who never studied it")
        for id in StudyPath.bundled.lessons.prefix(6).map(\.id) { try booru.studyStore.earn(10, lesson: id, stars: 3) }
        XCTAssertGreaterThan(store.settleTagCourse(in: booru.studyStore).total, 0)
        XCTAssertFalse(store.ownsTagCourse)
        XCTAssertEqual(store.tagCoursePaid.lessons, 6)
        XCTAssertTrue(store.owesLegacyNotice)
        store.noticeLegacy()
        XCTAssertFalse(store.owesLegacyNotice)
        XCTAssertEqual(store.spent, 0)
    }

    func testItemsNotOnSaleCannotBeBought() {
        let store = store()
        let soon = try! XCTUnwrap(store.shop.items.first(where: \.isSoon))
        XCTAssertEqual(store.canBuy(soon), .unavailable)
    }

    // MARK: - The shop from the server

    /// A list signed with a key made for the test, in the envelope the server publishes.
    private func signed(_ json: String, key: P256.Signing.PrivateKey) throws -> Data {
        let payload = Data(json.utf8)
        let signature = try key.signature(for: payload).derRepresentation
        return try JSONEncoder().encode(["payload": payload.base64EncodedString(), "signature": signature.base64EncodedString()])
    }

    func testTheShopListIsReadOnlyWhenTEGNALSignedIt() throws {
        let key = P256.Signing.PrivateKey(), other = P256.Signing.PrivateKey()
        let (shop, payload) = try LabShopSource.open(signed(Self.fixtureShop, key: key), key: key.publicKey)
        XCTAssertEqual(shop.items.map(\.id), ["course.tags", "feature.prompt-analyzer", "tickets.10"])
        XCTAssertEqual(payload, Data(Self.fixtureShop.utf8), "What is kept is the list's own bytes")
        XCTAssertThrowsError(try LabShopSource.open(signed(Self.fixtureShop, key: other), key: key.publicKey)) { XCTAssertEqual($0 as? LabShopError, .unsigned) }
        let newer = Self.fixtureShop.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        XCTAssertThrowsError(try LabShopSource.open(signed(newer, key: key), key: key.publicKey)) { XCTAssertEqual($0 as? LabShopError, .newer, "A list for a later app asks for an update") }
        XCTAssertThrowsError(try LabShop.decode(Data(#"{"format": "tegnal-addon-catalog", "schemaVersion": 1}"#.utf8)))
    }

    func testTheStoreShowsTheListItReadAndKeepsItWhenTheServerFails() async throws {
        let key = P256.Signing.PrivateKey()
        let store = LabStore(course: .bundled, shop: nil, diagnosis: .bundled, records: LabMemoryRecords(), edition: nil)
        XCTAssertEqual(store.shopState, .loading)
        XCTAssertEqual(store.shop.items.map(\.id), ["course.tags", "feature.prompt-analyzer"], "Before the list is read, only the goods the app carries")
        let file = try signed(Self.fixtureShop, key: key)
        var market = AddonMarket(base: AddonMarket.liveBase, publicKey: key.publicKey)
        market.fetch = { _, _ in file }
        await store.refreshShop(market: market)
        XCTAssertEqual(store.shopState, .ready)
        XCTAssertNotNil(store.shop.item("feature.prompt-analyzer"))
        market.fetch = { _, _ in throw AddonMarketError.offline }
        await store.refreshShop(market: market)
        XCTAssertEqual(store.shopState, .ready, "A list already read stays when the server cannot be reached")
        XCTAssertNotNil(store.shop.item("course.tags"))
        let newer = try signed(Self.fixtureShop.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"), key: key)
        market.fetch = { _, _ in newer }
        await store.refreshShop(market: market)
        XCTAssertEqual(store.shopState, .newer)
        XCTAssertEqual(store.shop.items.map(\.id), LabShop.builtIn.items.map(\.id), "An old list is not sold from once a newer one is out; the app's own goods are")
    }

    /// Goods of a kind, a version or a feature this app does not know are shown, and ask for an update instead of a price.
    func testGoodsThisAppDoesNotKnowAskForAnUpdate() throws {
        let json = """
            {"format": "tegnal-lab-shop", "schemaVersion": 1, "currency": "보석", "sections": [{"title": "새 상품", "items": [
              {"id": "sticker.cat", "kind": "sticker", "name": "고양이 스티커", "price": 10, "sticker": {"shape": "round"}},
              {"id": "feature.prompt-analyzer", "kind": "feature", "version": 2, "feature": "prompt-analyzer", "name": "새 분석기", "price": 10},
              {"id": "feature.voice", "kind": "feature", "feature": "voice", "name": "음성", "price": 10},
              {"id": "feature.other", "kind": "feature", "feature": "prompt-analyzer", "name": "다른 ID", "price": 10},
              {"id": "home.broken", "kind": "home", "name": "파일 없는 홈", "price": 10},
              {"id": "BAD ID", "kind": "feature", "name": "모양이 틀림"},
              {"id": "tickets.5", "kind": "ticket", "count": 5, "name": "생성권", "price": 10, "repeat": true}
            ]}]}
            """
        let shop = try LabShop.decode(Data(json.utf8))
        XCTAssertEqual(shop.items.map(\.id), ["sticker.cat", "feature.prompt-analyzer", "feature.voice", "feature.other", "home.broken", "tickets.5"],
                       "An item not shaped like one is left out; the others stay")
        let store = LabStore(course: .bundled, shop: shop, diagnosis: .bundled, records: LabMemoryRecords(), edition: nil)
        for id in ["sticker.cat", "feature.prompt-analyzer", "feature.voice", "feature.other", "home.broken"] {
            XCTAssertFalse(shop.item(id)!.supported, id)
            XCTAssertEqual(store.canBuy(shop.item(id)!), .update, id)
        }
        XCTAssertTrue(shop.item("tickets.5")!.supported)
    }

    /// What `docs/live/publish_live.py` signs opens with the key the app carries (local only).
    func testTheSignedListsInTheDocsFolderOpenWithTheLiveKey() throws {
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/live/dist/v1")
        guard let shop = try? Data(contentsOf: dist.appendingPathComponent("lab/shop.json")) else { throw XCTSkip("docs/live/dist is local only") }
        let (list, _) = try LabShopSource.open(shop, key: AddonMarket.live.publicKey)
        XCTAssertNotNil(list.item(LabStore.tagCourse))
        XCTAssertTrue(list.items.allSatisfy(\.supported), "Everything published is something this app knows")
        if let notice = try? Data(contentsOf: dist.appendingPathComponent("app/notice.json")) {
            XCTAssertNoThrow(try AppNotice.decode(LabSigned.payload(notice, key: AddonMarket.live.publicKey, limit: AppNotice.maximumBytes)))
        }
    }

    /// An item's picture is a file the list names exactly, small enough; anything else is left out and its symbol shows.
    func testAnItemsPictureIsReadOnlyWhenItIsAProperFile() throws {
        func item(_ image: String) throws -> LabShopItem {
            try JSONDecoder().decode(LabShopItem.self, from: Data(#"{"id": "home.dusk", "kind": "home", "name": "노을", "soon": true, "image": \#(image)}"#.utf8))
        }
        let good = try item(#"{"path": "goods/home.dusk/0123abcd-card.jpg", "size": 1000, "sha256": "\#(String(repeating: "a", count: 64))"}"#)
        XCTAssertEqual(good.image?.path, "goods/home.dusk/0123abcd-card.jpg")
        XCTAssertNil(try item(#"{"path": "../x.jpg", "size": 1000, "sha256": "\#(String(repeating: "a", count: 64))"}"#).image)
        XCTAssertNil(try item(#"{"path": "goods/a.jpg", "size": 3000000, "sha256": "\#(String(repeating: "a", count: 64))"}"#).image, "Larger than 2 MB")
        XCTAssertNil(try item(#""goods/a.jpg""#).image, "A local path is only for the source list")
        XCTAssertTrue(try item(#""goods/a.jpg""#).supported, "A picture never stops an item from being sold")
    }

    /// The prompt analyzer is sold for 보석 once 2D AI 배우기 is owned, and stays open from the records alone.
    func testThePromptAnalyzerNeedsTheTagCourseAndStaysOpenWithoutTheList() throws {
        let records = LabMemoryRecords()
        let store = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        let analyzer = try XCTUnwrap(store.shop.item(LabFeature.promptAnalyzer.item))
        XCTAssertEqual(analyzer.requires, LabStore.tagCourse)
        XCTAssertFalse(store.unlocked(.promptAnalyzer))
        XCTAssertEqual(store.canBuy(analyzer), .needs(LabStore.tagCourse))
        for episode in course.episodes { store.engrave(episode, failsHung: 0) }
        XCTAssertEqual(store.buy(store.shop.item(LabStore.tagCourse)!), .bought)
        XCTAssertEqual(store.buy(analyzer), .bought)
        XCTAssertTrue(store.unlocked(.promptAnalyzer))
        XCTAssertEqual(store.canBuy(analyzer), .owned)
        let later = LabStore(course: .bundled, shop: nil, diagnosis: .bundled, records: records, edition: nil)
        XCTAssertTrue(later.unlocked(.promptAnalyzer), "What was bought opens without the shop list")
    }

    func testTicketsCountWhatEachPurchaseBrought() throws {
        let store = store()
        var tickets = try XCTUnwrap(store.shop.items.first { $0.kind == "ticket" })
        tickets.soon = false
        tickets.count = 10
        for episode in course.episodes { store.engrave(episode, failsHung: 0) }
        store.buy(store.shop.item(LabStore.tagCourse)!)
        XCTAssertEqual(store.buy(tickets), .bought)
        XCTAssertEqual(store.buy(tickets), .bought)
        XCTAssertEqual(store.tickets, 20)
        XCTAssertEqual(LabProgress(records: store.progress.records).purchases[tickets.id]?.each, 10, "Kept in the records")
    }

    /// A finished course can be started over: an empty deck and gallery and the rate at its start, every amount at a quarter,
    /// and nothing earned before taken back. Earlier rounds stay in the records, so a sync cannot bring their cards back.
    func testAFinishedCourseStartsOverAndPaysAQuarter() throws {
        let records = LabMemoryRecords()
        let store = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        store.startOver()
        XCTAssertEqual(store.round, 0, "Only a finished course starts over")
        for episode in course.episodes { store.engrave(episode, failsHung: 0) }
        store.hang(course.fails[0])
        XCTAssertTrue(store.finished)
        let balance = store.balance, sheet = try XCTUnwrap(LabEdition.bundled).sections.filter(store.opened).count
        store.startOver()
        XCTAssertEqual(store.round, 1)
        XCTAssertFalse(store.finished)
        XCTAssertEqual(store.rate, course.base, "The rate starts again")
        XCTAssertEqual(store.next?.id, course.episodes[0].id)
        XCTAssertFalse(store.hung(course.fails[0]), "The gallery starts empty")
        XCTAssertEqual(store.balance, balance, "What was earned stays")
        XCTAssertEqual(try XCTUnwrap(LabEdition.bundled).sections.filter(store.opened).count, sheet, "The cheat sheet stays open")

        let first = store.engrave(course.episodes[0], failsHung: 1)
        XCTAssertEqual(first.cardReward, Int((Double(course.episodes[0].reward) / 4).rounded()))
        XCTAssertEqual(store.failReward, Int((Double(course.info.rewards.fail) / 4).rounded()))
        XCTAssertTrue(store.hang(course.fails[0]))
        XCTAssertEqual(store.balance, balance + first.cardReward + store.failReward)

        // Read back, as on another device after a sync: the new round, and nothing of the old one in its deck.
        let synced = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: records, edition: nil)
        XCTAssertEqual(synced.round, 1)
        XCTAssertEqual(synced.earnedIDs, [course.episodes[0].id])
        XCTAssertEqual(synced.balance, store.balance)
    }

    /// A course bought in the shop keeps its records under its own id like an imported one, but pays like the AI lab.
    func testACourseFromTheShopPays() throws {
        let store = store()
        var official = try XCTUnwrap(LabCourseFile.decode(Self.courseFile { $0["rewards"] = ["fail": 20, "season": 100] }).deck)
        official.official = true
        store.show(course: official)
        XCTAssertTrue(store.pays)
        let first = store.engrave(official.episodes[0], failsHung: 0)
        XCTAssertEqual(first.cardReward, 999)
        XCTAssertTrue(store.hang(official.fails[0]))
        let second = store.engrave(official.episodes[1], failsHung: 0)
        XCTAssertEqual(second.seasonReward, 100, "Its season pays too")
        XCTAssertEqual(store.balance, 999 * 2 + 20 + 100)
        XCTAssertEqual(LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: { let r = LabMemoryRecords(); try? r.replace(with: store.progress.records); return r }(), edition: nil).balance,
                       store.balance, "Read back from the records")
        XCTAssertNil(store.progress.seasonGems["1"], "The AI lab's season 1 is untouched")
    }

    func testTheCatalogKeepsCoursesFromTheShopApartFromImportedOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = LearningCourses(folder: folder)
        try catalog.add(data: Self.courseFile())
        let course = try catalog.addOfficial(data: Self.courseFile(), item: "course.prompt-basics")
        XCTAssertTrue(course.official)
        XCTAssertEqual(course.item, "course.prompt-basics")
        XCTAssertTrue(course.deck?.official ?? false)
        XCTAssertEqual(catalog.all.map(\.id), [LearningCourse.labID, LearningCourse.tagsID, "maker.prompt-basics"], "The official copy replaces the imported one")
        XCTAssertTrue(catalog.has(item: "course.prompt-basics"))
        XCTAssertThrowsError(try catalog.add(data: Self.courseFile()), "A file cannot take an official course's id") {
            XCTAssertEqual($0 as? LabCourseFileError, .reserved)
        }
        let reread = LearningCourses(folder: folder)
        XCTAssertEqual(reread.official.map(\.item), ["course.prompt-basics"])
        XCTAssertTrue(reread.imported.isEmpty)
    }

    /// Goods are downloaded only as exactly the files the signed list names.
    func testGoodsAreCheckedAgainstTheList() async throws {
        let data = Data("film".utf8)
        let file = LabShopFile(path: "goods/home.test/loop.mp4", size: data.count, sha256: LabCourseFile.digest(data))
        let goods = LabGoods()
        goods.market.fetch = { url, _ in
            XCTAssertEqual(url.absoluteString, "https://addons.nextline.work/v1/goods/home.test/loop.mp4")
            return data
        }
        let downloaded = try await goods.download(file)
        XCTAssertEqual(downloaded, data)
        goods.market.fetch = { _, _ in Data("fake".utf8) }
        do { _ = try await goods.download(file); XCTFail("A different file is refused") } catch { XCTAssertEqual(error as? AddonMarketError, .damaged) }
        for path in ["../etc/passwd", "/goods/a", "goods//a", "goods/한글", ""] {
            XCTAssertFalse(LabShopFile(path: path, size: 1, sha256: file.sha256).valid, path)
        }
    }

    func testHomeScenesAreKeptAndChosen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let (savedRoot, savedDefaults) = (HomeScenes.root, HomeScenes.defaults)
        HomeScenes.root = root; HomeScenes.defaults = defaults
        defer { HomeScenes.root = savedRoot; HomeScenes.defaults = savedDefaults; try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ data: Data) -> LabShopFile { LabShopFile(path: "goods/home.test/" + name, size: data.count, sha256: LabCourseFile.digest(data)) }
        let films = ["intro": Data("intro".utf8), "loop": Data("loop".utf8), "still": Data("still".utf8)]
        let home = LabShopHome(intro: file("intro.mp4", films["intro"]!), loop: file("loop.mp4", films["loop"]!), still: file("still.jpg", films["still"]!),
                               theme: nil, palette: ["sky": "102030"])
        XCTAssertTrue(home.valid)
        XCTAssertFalse(HomeScenes.has("home.test", home))
        try HomeScenes.keep("home.test", home: home, files: films)
        XCTAssertTrue(HomeScenes.has("home.test", home))
        XCTAssertNil(HomeScenes.url("loop"), "Kept is not chosen")
        HomeScenes.choose("home.test")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(HomeScenes.url("loop"))), films["loop"])
        XCTAssertNil(HomeScenes.url("theme"), "No music of its own: the app's plays")
        XCTAssertEqual(HomeScenes.color("sky"), 0x102030)
        XCTAssertNil(HomeScenes.color("ground"))
        var newer = home
        newer.loop = file("loop.mp4", Data("loop 2".utf8))
        XCTAssertFalse(HomeScenes.has("home.test", newer), "A new version of a file is downloaded again")
        HomeScenes.choose(nil)
        XCTAssertNil(HomeScenes.url("loop"))
    }

    // MARK: - Update notice

    func testAnUpdateNoticeShowsOnlyOnOlderBuildsAndARecommendedOneCanBePutOff() throws {
        let json = """
            {"format": "tegnal-app-notice", "schemaVersion": 1, "id": "n1", "level": "recommended", "title": "업데이트", "message": "새 버전",
             "ios": {"below": 50, "url": "https://apps.apple.com/app/id6825935560"}}
            """
        let notice = try AppNotice.decode(Data(json.utf8))
        XCTAssertTrue(notice.applies(to: 49))
        XCTAssertFalse(notice.applies(to: 50))
        XCTAssertThrowsError(try AppNotice.decode(Data(json.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2").utf8)))
        XCTAssertThrowsError(try AppNotice.decode(Data(json.replacingOccurrences(of: "recommended", with: "someday").utf8)))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let old = AppNotices(defaults: defaults, build: 49) { Data() }
        old.show(notice)
        XCTAssertEqual(old.current, notice)
        old.putOff()
        XCTAssertNil(old.current)
        old.show(notice)
        XCTAssertNil(old.current, "Put off once, not shown again")
        var urgent = notice
        urgent.id = "n2"; urgent.level = .required
        old.show(urgent)
        old.putOff()
        XCTAssertEqual(old.current, urgent, "A required notice cannot be put off")
        let current = AppNotices(defaults: defaults, build: 50) { Data() }
        current.show(urgent)
        XCTAssertNil(current.current, "Builds that are new enough see nothing")
        var android = urgent
        android.ios = nil
        old.show(android)
        XCTAssertNil(old.current, "A notice for the other platform only")
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
        let first = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: LabDatabaseRecords(database: booru.database), edition: nil)
        first.engrave(course.episode("ep01")!, failsHung: 0)
        first.hang(course.fails[0])
        first.diagnose(try XCTUnwrap(first.diagnosis?.types.first))
        let second = LabStore(course: .bundled, shop: Self.shop, diagnosis: .bundled, records: LabDatabaseRecords(database: booru.database), edition: nil)
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

    func testMarkdownDetailsReadAsHeadingsListsQuotesAndCode() {
        let blocks = LabMarkdown.blocks("첫 줄\n이어서\n\n### 제목\n1. 하나\n- 점\n> 인용\n---\n```\n코드 한 줄\n```")
        XCTAssertEqual(blocks, [.paragraph("첫 줄 이어서"), .heading(3, "제목"), .numbered("1", "하나"), .bullet("점"), .quote("인용"), .rule, .code("코드 한 줄")])
        let inline = LabMarkdown.inline("**굵게** [링크](https://example.com)")
        XCTAssertEqual(String(inline.characters), "굵게 링크")
        XCTAssertTrue(inline.runs.allSatisfy { $0.link == nil }, "Links keep only their words")
    }

    /// The bundled sheet's rows name icons from the set both apps draw, and their colours are six hex digits.
    func testTheBundledCheatSheetRowsUseTheSharedIcons() throws {
        let shared: Set<String> = ["doc.text", "doc.richtext", "chevron.left.forwardslash.chevron.right", "terminal", "magnifyingglass",
                                   "bubble.left.and.bubble.right", "photo", "film", "music.note", "mic", "safari", "globe", "chart.bar", "book",
                                   "pencil", "paintbrush", "lightbulb", "briefcase", "cart", "envelope", "calendar", "person.2", "wand.and.stars", "sparkles"]
        for name in shared { XCTAssertNotNil(UIImage(systemName: name), name) }
        for row in try XCTUnwrap(LabEdition.bundled).sections.flatMap(\.rows) {
            if let symbol = row.symbol { XCTAssertTrue(shared.contains(symbol), symbol) }
            for hex in [row.color, row.labelColor].compactMap({ $0 }) { XCTAssertTrue(hex.count == 6 && hex.allSatisfy(\.isHexDigit), hex) }
        }
    }

    func testACheatSheetAlertTellsOnlyAnEditionDatedAfterTheNewestKnown() throws {
        let bundled = try XCTUnwrap(LabEdition.bundled)
        var later = bundled; later.date = "2099-01-01"; later.id = "2099-01-01"
        var correction = bundled; correction.id = bundled.id
        XCTAssertTrue(LabSheetAlerts.news(later, known: bundled.date), "A later edition is news")
        XCTAssertFalse(LabSheetAlerts.news(correction, known: bundled.date), "A same-day correction is not")
        XCTAssertFalse(LabSheetAlerts.news(bundled, known: "2099-01-01"), "Nor is anything older than what was told")
    }
}
