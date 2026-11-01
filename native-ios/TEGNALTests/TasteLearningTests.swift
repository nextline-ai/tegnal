import XCTest
import GRDB
@testable import TEGNAL

final class TasteLearningTests: XCTestCase {
    private let source = "https://a.example"
    private let now = Date(timeIntervalSince1970: 1792033200)
    private var counter = 0
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
    private func event(_ kind: TasteEvent.Kind, _ id: Int64, tags: [String] = [], days: Double = 1, context: DiscoveryContext = .init(origin: .feed, session: "s"),
                       dwell: TasteDwell? = nil, signal: TasteSignal? = nil) -> TasteEvent {
        counter += 1
        var value = TasteEvent(kind: kind, item: .init(source: source, id: id, tags: tags), context: context, dwell: dwell, signal: signal?.rawValue)
        value.id = "event-\(counter)"; value.at = daysAgo(days).timeIntervalSince1970
        return value
    }
    private func learning(_ events: [TasteEvent], library: [String: RecapWorkInfo] = [:], control: TasteControl = .init()) -> TasteLearning {
        TasteLearning(index: RecapIndex(events: events, control: control, mode: .booru, library: library), control: control, now: now)
    }
    private func weight(_ model: TasteLearning, _ tag: String) -> Double { model.tags[TasteControl.tagKey(source: source, tag: tag)]?.weight ?? 0 }
    private func candidate(_ id: Int64, tags: [String], score: Double = 0.2) -> TasteRecommendation {
        .init(item: .init(source: source, id: id, tags: tags), post: nil, gallery: nil, reason: .init(source: source, name: tags[0]), score: score, rankingTags: Set(tags))
    }

    // MARK: Learning

    func testRecentSavesOutweighOldOnes() {
        let model = learning([event(.save, 1, tags: ["new"], days: 2), event(.save, 2, tags: ["old"], days: 400)])
        XCTAssertGreaterThan(weight(model, "new"), weight(model, "old") * 20)
    }
    func testASaveLosesHalfItsPullEveryHalfLife() {
        let model = learning([event(.save, 1, tags: ["a"], days: 0), event(.save, 2, tags: ["b"], days: TasteLearning.halfLife)])
        XCTAssertEqual(weight(model, "b") / weight(model, "a"), 0.5, accuracy: 0.001)
    }
    func testFinishedAndLongViewsTeachButGlancesDoNot() {
        let model = learning([
            event(.open, 1, tags: ["read"], dwell: .init(seconds: 240, pages: 30, finished: true)),
            event(.open, 2, tags: ["glance"], dwell: .init(seconds: 8, pages: 1)),
            event(.open, 3, tags: ["opened"])
        ])
        XCTAssertGreaterThan(weight(model, "read"), 0.8)
        XCTAssertEqual(weight(model, "glance"), 0)
        XCTAssertEqual(weight(model, "opened"), 0)
    }
    func testImportedLibrariesCountLessThanDeliberateSaves() {
        let model = learning([event(.imported, 1, tags: ["imported"]), event(.save, 2, tags: ["chosen"], context: .init(origin: .search, query: "chosen", session: "s"))])
        XCTAssertGreaterThan(weight(model, "chosen"), weight(model, "imported") * 3)
    }
    func testRemovingAWorkTakesItsEvidenceBack() {
        let model = learning([event(.save, 1, tags: ["a"], days: 1), event(.remove, 1, tags: ["a"], days: 1)])
        XCTAssertLessThan(weight(model, "a"), 0.05)
        XCTAssertTrue(model.ranked().isEmpty)
    }
    func testExcludedTagsAreNeverLearned() {
        var control = TasteControl(); control.setAnalysisExcluded(["blocked"], mode: .booru)
        XCTAssertEqual(weight(learning([event(.save, 1, tags: ["blocked", "fine"])], control: control), "blocked"), 0)
    }

    // MARK: Seen and dismissed

    func testViewedWorksAreSeenButSignalsAreNot() {
        let model = learning([event(.open, 1, tags: ["a"]), event(.open, 2, tags: ["a"], signal: .dismissed)])
        XCTAssertEqual(model.seen, [source + "#1"])
        XCTAssertEqual(model.dismissed, [source + "#2"])
    }
    func testUndoRestoresAWorkAndItsTags() {
        let events = [event(.save, 9, tags: ["a"], days: 3), event(.open, 1, tags: ["a"], days: 1, signal: .dismissed), event(.open, 1, tags: ["a"], days: 0.5, signal: .restored)]
        let model = learning(events)
        XCTAssertTrue(model.dismissed.isEmpty)
        let plain = learning([events[0]]).personalize(candidate(5, tags: ["a"]))
        XCTAssertEqual(model.personalize(candidate(5, tags: ["a"])).score, plain.score, accuracy: 0.01)
    }
    func testDismissingTeachesAgainstItsTags() {
        let base = [event(.save, 9, tags: ["kept"], days: 3)]
        let dismissed = base + (1...4).map { event(.open, Int64($0), tags: ["unwanted"], signal: .dismissed) }
        XCTAssertLessThan(learning(dismissed).personalize(candidate(5, tags: ["unwanted"])).score, learning(base).personalize(candidate(5, tags: ["unwanted"])).score)
    }
    func testFeedbackIsNotActivityInTheRecap() throws {
        var control = TasteControl(); control.timeZone = "Asia/Seoul"
        var feedback = event(.open, 1, tags: ["a"], days: 1, signal: .dismissed), save = event(.save, 2, tags: ["a"], days: 1)
        feedback.epoch = control.epoch; save.epoch = control.epoch
        let recap = try XCTUnwrap(RecapIndex(events: [feedback, save], control: control, mode: .booru, library: [:]).recap(period: .month, offset: 0, now: now))
        XCTAssertEqual(recap.opens, 0); XCTAssertEqual(recap.saves, 1)
    }
    func testSignalsSurviveTheWireAndOldEventsStillDecode() throws {
        let store = try AppDatabase.inMemory().tasteStore
        try store.record(signal: .dismissed, item: .init(source: source, id: 1, tags: ["a"]))
        let saved = try XCTUnwrap(store.events().first)
        XCTAssertEqual(saved.signal, "dismissed"); XCTAssertEqual(saved.kind, .open)
        XCTAssertFalse(saved.context.organic, "older peers must not read feedback as organic interest")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event(.open, 1)), as: UTF8.self).contains("signal"))
        var paused = try store.control(); paused.enabled = false
        try store.setControl(paused)
        try store.record(signal: .dismissed, item: .init(source: source, id: 2, tags: ["a"]))
        XCTAssertEqual(try store.events().count, 1)
    }

    // MARK: Steering

    func testBoostsSteerScoreAndSurviveControlCoding() throws {
        var control = TasteControl()
        let key = TasteControl.tagKey(source: source, tag: "a")
        control.setBoost(1, key: key); control.discoveryLevel = 2
        let decoded = try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(control))
        XCTAssertEqual(decoded.boost(key), 1); XCTAssertEqual(decoded.discoveryLevel, 2)
        XCTAssertNil(try JSONDecoder().decode(TasteControl.self, from: JSONEncoder().encode(TasteControl())).tasteBoosts)
        let events = [event(.save, 1, tags: ["a"])]
        let more = learning(events, control: control).personalize(candidate(5, tags: ["a"])).score
        var reduced = TasteControl(); reduced.setBoost(-1, key: key)
        XCTAssertGreaterThan(more, learning(events).personalize(candidate(5, tags: ["a"])).score)
        XCTAssertLessThan(learning(events, control: reduced).personalize(candidate(5, tags: ["a"])).score, learning(events).personalize(candidate(5, tags: ["a"])).score)
        control.setBoost(0, key: key)
        XCTAssertNil(control.tasteBoosts?[key])
    }
    @MainActor func testDeletingAnalysisAlsoForgetsSteering() {
        let env = AppEnvironment.preview()
        env.taste.change { $0.setBoost(1, key: "s\na"); $0.discoveryLevel = 2 }
        env.taste.reset()
        XCTAssertNil(env.taste.control.tasteBoosts); XCTAssertNil(env.taste.control.discoveryLevel)
    }
    func testAdventureFavorsUnknownTagsAndFamiliarFavorsKnownOnes() {
        let events = [event(.save, 1, tags: ["known"])]
        func score(_ level: Int) -> Double {
            var control = TasteControl(); control.discoveryLevel = level
            return learning(events, control: control).personalize(candidate(5, tags: ["strange", "unseen"])).score
        }
        XCTAssertLessThan(score(0), score(1)); XCTAssertLessThan(score(1), score(2))
        XCTAssertEqual([0, 1, 2].map { level -> Int in var control = TasteControl(); control.discoveryLevel = level; return learning(events, control: control).discoverySlots }, [1, 3, 5])
    }
    func testNovelWorksTakeTheDiscoverySlots() {
        let familiar = (1...12).map { var item = candidate(Int64($0), tags: ["a"], score: 1); item.novel = false; return item }
        let novel = (20...28).map { var item = candidate(Int64($0), tags: ["b"], score: 0.1); item.novel = true; return item }
        let mixed = RecommendationService.mix(familiar + novel, limit: 10, discoverySlots: 5)
        XCTAssertEqual(mixed.filter(\.novel).count, 5)
        XCTAssertEqual(RecommendationService.mix(familiar + novel, limit: 10, discoverySlots: 1).filter(\.novel).count, 1)
    }

    // MARK: Explanations

    func testExplanationsCiteWhatActuallyHappened() {
        let hidden = TasteTag(source: source, name: "quiet", hidden: 5, sessions: ["a", "b", "c"])
        var candidate = TasteRecommendation(item: .init(source: source, id: 7, tags: ["quiet"]), post: nil, gallery: nil, reason: hidden, score: 0.2, rankingTags: ["quiet"])
        let model = learning([event(.save, 1, tags: ["quiet"], days: 90)])
        XCTAssertEqual(model.personalize(candidate).why, .hidden("quiet"))
        candidate = self.candidate(7, tags: ["sky"])
        XCTAssertEqual(learning((1...4).map { event(.save, Int64($0), tags: ["sky"], days: 3) }).personalize(candidate).why, .recent("sky"))
        XCTAssertEqual(learning((1...4).map { event(.save, Int64($0), tags: ["sky"], days: 200) }).personalize(candidate).why, .taste("sky"))
        XCTAssertEqual(model.personalize(candidate, why: .popular).why, .popular)
    }
    func testArtistsAreCreditedAndNotCountedAsTheirOwnTag() {
        let library = Dictionary(uniqueKeysWithValues: (1...4).map { (source + "#\($0)", RecapWorkInfo(artists: ["mira"])) })
        let model = learning((1...4).map { event(.save, Int64($0), tags: ["mira", "sky"]) }, library: library)
        let result = model.personalize(candidate(9, tags: ["mira", "sky"]))
        XCTAssertEqual(result.why, .person("mira", .artist, 4))
        XCTAssertEqual(result.factors.filter { $0.name == "mira" }.count, 1)
        XCTAssertEqual(model.people.first?.query, "mira")
        XCTAssertFalse(model.ranked().contains { $0.name == "mira" })
    }
    func testNoReasonIsEverInventedForColdStart() {
        XCTAssertEqual(learning([]).personalize(candidate(1, tags: ["sky"], score: 0), why: .popular).why, .popular)
        XCTAssertTrue(learning([]).shelves(sources: [source], tags: [], offset: 0).isEmpty)
    }

    // MARK: Shelves

    func testShelvesComeFromDifferentReasonsAndRotate() {
        var events: [TasteEvent] = []
        for id in 1...6 { events.append(event(.save, Int64(id), tags: ["old_love", "old_friend"], days: 300)) }
        for id in 10...14 { events.append(event(.save, Int64(id), tags: ["rain", "umbrella"], days: 3)) }
        for id in 20...24 { events.append(event(.save, Int64(id), tags: ["snow"], days: 4)) }
        let library = Dictionary(uniqueKeysWithValues: (10...24).map { (source + "#\($0)", RecapWorkInfo(artists: ["mira"])) })
        let model = learning(events, library: library)
        let shelves = model.shelves(sources: [source], tags: [], offset: 0)
        XCTAssertEqual(Set(shelves.map(\.kind)).count, shelves.count)
        XCTAssertTrue(shelves.map(\.kind).contains(.recent)); XCTAssertTrue(shelves.map(\.kind).contains(.person))
        XCTAssertTrue(shelves.map(\.kind).contains(.comeback)); XCTAssertTrue(shelves.map(\.kind).contains(.pair))
        XCTAssertNotEqual(shelves.map(\.id), model.shelves(sources: [source], tags: [], offset: 1).map(\.id))
        XCTAssertTrue(model.shelves(sources: ["https://other.example"], tags: [], offset: 0).isEmpty, "servers never borrow each other's taste")
    }
    func testAnEverywhereTagNeverBecomesAPairOrThread() {
        var events: [TasteEvent] = []
        for id in 1...10 { events.append(event(.save, Int64(id), tags: ["scenery", "rain", "umbrella"], days: 3)) }
        for id in 11...30 { events.append(event(.save, Int64(id), tags: ["scenery", "snow"], days: 3)) }
        let model = learning(events)
        XCTAssertFalse(model.recentTags.contains { $0.name == "scenery" })
        XCTAssertFalse(model.pairs.contains { $0.first.name == "scenery" || $0.second.name == "scenery" })
        XCTAssertTrue(model.pairs.contains { Set([$0.first.name, $0.second.name]) == ["rain", "umbrella"] })
    }
    func testMutedTagsLeaveSeedsShelvesAndThreads() {
        var control = TasteControl()
        control.setBoost(-1, key: TasteControl.tagKey(source: source, tag: "rain"))
        let model = learning((1...5).map { event(.save, Int64($0), tags: ["rain"], days: 3) }, control: control)
        XCTAssertTrue(model.isMuted(.init(source: source, name: "rain")))
        XCTAssertFalse(model.recentTags.contains { $0.name == "rain" })
        XCTAssertLessThan(model.seedWeight(.init(source: source, name: "rain")), 0)
    }
    func testPersonQueriesUseEachSitesSyntax() {
        XCTAssertEqual(TasteLearnedPerson(source: MangaUrls.source, name: "mira sato", role: .artist, weight: 1).query, "artist:mira_sato")
        XCTAssertEqual(TasteLearnedPerson(source: MangaUrls.source, name: "sky atlas", role: .series, weight: 1).query, "series:sky_atlas")
        XCTAssertEqual(TasteLearnedPerson(source: source, name: "mira_sato", role: .artist, weight: 1).query, "mira_sato")
    }

    // MARK: Retrieval

    @MainActor func testPairSeedsRequireBothTagsAndDismissedWorksStayAway() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let address = server.canonicalAddress
        let snapshot = TasteSnapshot(tags: [TasteTag(source: address, name: "rain", general: 5)], saves: 5, opens: 0, searches: 0, activity: [:], digest: "x", period: nil)
        let events = (1...3).map { id -> TasteEvent in
            var value = event(.save, Int64(id), tags: ["rain"]); value.item.source = address; return value
        }
        var dismissed = event(.open, 203, tags: ["rain", "umbrella"], signal: .dismissed); dismissed.item.source = address
        let model = learning(events + [dismissed])
        let source = PairTasteSource()
        let result = try await RecommendationService.load(mode: .booru, snapshot: snapshot, report: nil, env: env, language: "all", booruSource: source, learning: model,
            seedOverride: [address: [TasteTag(source: address, name: "rain umbrella", general: 1)]], whyOverride: .pair("rain", "umbrella"))
        XCTAssertEqual(result.items.map(\.item.id), [201])
        XCTAssertEqual(result.items.first?.why, .pair("rain", "umbrella"))
        let queries = await source.queries
        XCTAssertEqual(queries.count, 1)
        XCTAssertTrue(queries[0].contains("rain umbrella"))
    }
    @MainActor func testColdStartOpensWithPopularWorksAndExplainsWhy() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let feed = TasteFeedState(source: server.canonicalAddress, booruSource: PairTasteSource())
        feed.refresh(mode: .booru, env: env, language: "all")
        await feed.waitForRefresh()
        XCTAssertTrue(feed.starter)
        XCTAssertFalse(feed.results.items.isEmpty)
        XCTAssertTrue(feed.results.items.allSatisfy { $0.why == .popular })
    }
    @MainActor func testDismissRemovesAtOnceAndUndoRestoresTheSamePlace() async throws {
        let env = AppEnvironment.preview(), server = BooruServer.presets[0]
        try env.booru.saveServer(server); try env.booru.select(server)
        let feed = TasteFeedState(source: server.canonicalAddress, booruSource: PairTasteSource())
        feed.refresh(mode: .booru, env: env, language: "all")
        await feed.waitForRefresh()
        let order = feed.results.items.map(\.id), target = try XCTUnwrap(feed.results.items.dropFirst().first)
        feed.dismiss(target, mode: .booru, env: env)
        XCTAssertFalse(feed.results.items.contains { $0.id == target.id })
        XCTAssertEqual(feed.lastDismissed?.id, target.id)
        XCTAssertEqual(try env.booru.tasteStore.events().filter { $0.signal == "dismissed" }.count, 1)
        feed.undoDismiss(mode: .booru, env: env)
        XCTAssertEqual(feed.results.items.map(\.id), order)
        XCTAssertNil(feed.lastDismissed)
        XCTAssertEqual(try env.booru.tasteStore.events().filter { $0.signal == "restored" }.count, 1)
    }
}

private actor PairTasteSource: BooruProviding {
    var queries: [String] = []
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        queries.append(query)
        guard page == 0 else { return .init(posts: [], hasMore: false) }
        return .init(posts: [
            BooruFixtureSource.post(201, server: server, tags: ["rain", "umbrella"]),
            BooruFixtureSource.post(202, server: server, tags: ["rain"]),
            BooruFixtureSource.post(203, server: server, tags: ["rain", "umbrella"]),
            BooruFixtureSource.post(204, server: server, tags: ["rain", "lake"]),
            BooruFixtureSource.post(205, server: server, tags: ["rain", "street"])
        ], hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
