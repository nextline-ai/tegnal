import XCTest
import GRDB
@testable import TEGNAL

final class TasteRecapTests: XCTestCase {
    private let zone = "Asia/Seoul"
    private lazy var control: TasteControl = { var value = TasteControl(); value.timeZone = zone; return value }()
    /// 15 Oct 2026 12:00 in Seoul: October is the open month, September the last complete one.
    private let now = Date(timeIntervalSince1970: 1792033200)
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value }
    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private var counter = 0
    private func event(_ kind: TasteEvent.Kind, _ id: Int64, tags: [String] = [], at: Date, source: String = "https://a.example",
                       context: DiscoveryContext = .init(origin: .feed, session: "s"), dwell: TasteDwell? = nil) -> TasteEvent {
        counter += 1
        var value = TasteEvent(kind: kind, item: .init(source: source, id: id, tags: tags), context: context, dwell: dwell)
        value.id = "event-\(counter)"; value.at = at.timeIntervalSince1970; value.epoch = control.epoch
        return value
    }
    private func index(_ events: [TasteEvent], library: [String: RecapWorkInfo] = [:], control custom: TasteControl? = nil) -> RecapIndex {
        RecapIndex(events: events, control: custom ?? control, mode: .booru, library: library)
    }
    private func september(_ events: [TasteEvent], library: [String: RecapWorkInfo] = [:]) throws -> TasteRecap {
        try XCTUnwrap(index(events, library: library).recap(period: .month, offset: -1, now: now))
    }
    private func info(_ ids: ClosedRange<Int64>, source: String = "https://a.example", artist: String? = nil, savedAt: Date? = nil) -> [String: RecapWorkInfo] {
        Dictionary(uniqueKeysWithValues: ids.map { (source + "#" + String($0), RecapWorkInfo(artists: artist.map { [$0] } ?? [], savedAt: savedAt)) })
    }

    // MARK: Viewing time

    func testViewingSessionCountsForegroundTimeAndCapsIdlePages() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var session = TasteViewingSession()
        session.resume(at: start)
        session.show(0, at: start)
        session.show(1, at: start.addingTimeInterval(30))
        session.pause(at: start.addingTimeInterval(40))
        // Time while covered or in the background never counts.
        session.resume(at: start.addingTimeInterval(4000))
        session.show(2, isLast: true, at: start.addingTimeInterval(4010))
        // A device left on the table stops at the idle limit.
        let dwell = try XCTUnwrap(session.finish(at: start.addingTimeInterval(9000)))
        XCTAssertEqual(dwell.seconds, 30 + 10 + 10 + TasteViewingSession.idleLimit)
        XCTAssertEqual(dwell.pages, 3)
        XCTAssertTrue(dwell.finished)
    }
    func testViewingSessionIgnoresGlancesAndResetsAfterFinishing() {
        let start = Date(timeIntervalSince1970: 1000)
        var session = TasteViewingSession()
        session.resume(at: start)
        XCTAssertNil(session.finish(at: start.addingTimeInterval(TasteViewingSession.minimum - 1)))
        XCTAssertEqual(session.seconds, 0)
        XCTAssertNil(session.finish(at: start.addingTimeInterval(500)))
    }
    func testDwellIsOptionalOnTheWireSoOlderPeersAndDigestsStayCompatible() throws {
        let plain = event(.open, 1, at: now)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("dwell"))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        legacy["dwell"] = nil
        XCTAssertNil(try JSONDecoder().decode(TasteEvent.self, from: JSONSerialization.data(withJSONObject: legacy)).dwell)
        let timed = event(.open, 1, at: now, dwell: .init(seconds: 90, pages: 4, finished: true))
        XCTAssertEqual(try JSONDecoder().decode(TasteEvent.self, from: JSONEncoder().encode(timed)).dwell, timed.dwell)
    }
    func testDwellRespectsPausedAnalysisAndEachViewingIsSeparate() throws {
        let store = try AppDatabase.inMemory().tasteStore
        let item = TasteItem(source: "s", id: 1, tags: ["a"])
        try store.database.write { db in
            try TasteStore.recordDwell(.init(seconds: 10), item: item, context: .unknown, db: db)
            try TasteStore.recordDwell(.init(seconds: 20), item: item, context: .unknown, db: db)
        }
        XCTAssertEqual(try store.events().compactMap(\.dwell?.seconds).sorted(), [10, 20])
        var paused = try store.control(); paused.enabled = false
        try store.setControl(paused)
        try store.database.write { try TasteStore.recordDwell(.init(seconds: 30), item: item, context: .unknown, db: $0) }
        XCTAssertEqual(try store.events().count, 2)
    }

    // MARK: Counting

    func testTotalsCompareWithPreviousPeriodAndCountDistinctWorks() throws {
        let recap = try september([
            event(.save, 1, tags: ["a"], at: date(8, 10)),
            event(.save, 2, tags: ["a"], at: date(9, 3)),
            event(.save, 2, tags: ["a"], at: date(9, 4)),
            event(.save, 3, tags: ["a"], at: date(9, 4)),
            event(.open, 3, at: date(9, 5)),
            event(.open, 4, at: date(9, 6)),
            event(.open, 9, at: date(10, 2)),
            event(.search, 0, tags: ["a"], at: date(9, 6), context: .init(origin: .search, query: "a", session: "q1")),
            event(.search, 0, tags: ["b"], at: date(9, 6), context: .init(origin: .search, query: "b", session: "q1")),
            event(.search, 0, tags: ["c"], at: date(9, 7), context: .init(origin: .search, query: "c", session: "q2"))
        ])
        XCTAssertEqual(recap.saves, 2); XCTAssertEqual(recap.previousSaves, 1)
        XCTAssertEqual(recap.opens, 2); XCTAssertEqual(recap.searches, 2)
        XCTAssertTrue(recap.isComplete)
        XCTAssertEqual(recap.activeDays, 4)
        XCTAssertEqual(recap.longestStreak, 4)
        XCTAssertEqual(recap.days.count, 30)
    }
    func testPeriodBoundariesFollowTheAnalysisTimeZone() throws {
        let lastMinute = date(9, 30, hour: 23), firstMinute = date(10, 1, hour: 0)
        let recap = try september([event(.save, 1, tags: ["a"], at: lastMinute), event(.save, 2, tags: ["a"], at: firstMinute)])
        XCTAssertEqual(recap.saves, 1)
        XCTAssertEqual(recap.hours[23], 1)
    }
    func testImportsAndSeedsAreHistoryNotActivity() throws {
        let recap = try september([event(.imported, 1, tags: ["a"], at: date(9, 2)), event(.seed, 2, tags: ["a"], at: Date(timeIntervalSince1970: 0)), event(.save, 3, tags: ["a"], at: date(9, 2))])
        XCTAssertEqual(recap.saves, 1)
        XCTAssertFalse(recap.tags[0].isNew)
    }
    func testViewingTimeAddsUpAndAnOpenWithItsDwellIsOneVisit() throws {
        let context = DiscoveryContext(origin: .feed, session: "one")
        let recap = try september([
            event(.save, 1, tags: ["a"], at: date(9, 2), context: context),
            event(.open, 1, at: date(9, 2), context: context),
            event(.open, 1, at: date(9, 2), context: context, dwell: .init(seconds: 200, pages: 12, finished: true)),
            event(.open, 1, at: date(9, 3), context: context, dwell: .init(seconds: 100, pages: 3))
        ], library: info(1...1))
        XCTAssertEqual(recap.seconds, 300); XCTAssertEqual(recap.pages, 15); XCTAssertEqual(recap.finished, 1)
        XCTAssertEqual(recap.opens, 1)
        XCTAssertEqual(recap.revisited?.opens, 2)
        XCTAssertEqual(recap.hours.reduce(0, +), 2)
    }

    func testASingleLongVisitIsNotComingBack() throws {
        let recap = try september([
            event(.save, 1, tags: ["a"], at: date(9, 2)),
            event(.open, 1, at: date(9, 2), dwell: .init(seconds: 1800, pages: 40))
        ], library: info(1...1))
        XCTAssertNil(recap.revisited)
    }

    // MARK: Tags

    func testSameTagAcrossSourcesIsOneChartEntryAttributedToItsLargestSource() throws {
        let recap = try september([
            event(.save, 1, tags: ["sky"], at: date(9, 2), source: "https://a.example"),
            event(.save, 2, tags: ["sky"], at: date(9, 3), source: "https://b.example"),
            event(.save, 3, tags: ["sky"], at: date(9, 4), source: "https://b.example")
        ])
        XCTAssertEqual(recap.tags.count, 1)
        XCTAssertEqual(recap.tags[0].count, 3)
        XCTAssertEqual(recap.tags[0].source, "https://b.example")
    }
    func testChartMovementComparesRankWithPreviousPeriod() throws {
        var events: [TasteEvent] = []
        for id in 1...3 { events.append(event(.save, Int64(id), tags: ["old"], at: date(8, 2))) }
        for id in 4...4 { events.append(event(.save, Int64(id), tags: ["climber"], at: date(8, 2))) }
        for id in 10...12 { events.append(event(.save, Int64(id), tags: ["climber"], at: date(9, 2))) }
        for id in 13...14 { events.append(event(.save, Int64(id), tags: ["old"], at: date(9, 2))) }
        events.append(event(.save, 15, tags: ["fresh"], at: date(9, 2)))
        let recap = try september(events)
        XCTAssertEqual(recap.tags.map(\.name), ["climber", "old", "fresh"])
        XCTAssertEqual(recap.tags[0].movement, 1)
        XCTAssertEqual(recap.tags[1].movement, -1)
        XCTAssertNil(recap.tags[2].movement)
        XCTAssertTrue(recap.tags[2].isNew)
    }
    func testChartExcludesAnalysisExclusionsAndPeopleAreNotTags() throws {
        var custom = control
        custom.setAnalysisExcluded(["hidden_tag"], mode: .booru)
        let events = [event(.save, 1, tags: ["hidden_tag", "sky", "mira"], at: date(9, 2))]
        let recap = try XCTUnwrap(index(events, library: info(1...1, artist: "mira"), control: custom).recap(period: .month, offset: -1, now: now))
        XCTAssertEqual(recap.tags.map(\.name), ["sky"])
        XCTAssertEqual(recap.people.first?.name, "mira")
        XCTAssertEqual(recap.people.first?.role, .artist)
    }
    func testAnonymousCreditsNeverBecomeTheArtistOfTheIssue() throws {
        let recap = try september([event(.save, 1, tags: ["sky"], at: date(9, 2))], library: info(1...1, artist: "anonymous"))
        XCTAssertTrue(recap.people.isEmpty)
    }
    func testSignatureFindsWhatSetThePeriodApartFromAnEverywhereTag() throws {
        var events: [TasteEvent] = []
        for id in 1...30 { events.append(event(.save, Int64(id), tags: ["scenery", "forest"], at: date(5, 3))) }
        for id in 31...36 { events.append(event(.save, Int64(id), tags: ["scenery", "aurora"], at: date(9, 3))) }
        let recap = try september(events)
        XCTAssertEqual(recap.tags.first?.name, "aurora", "ties break by name; both appear six times")
        XCTAssertEqual(recap.signature?.name, "aurora")
    }

    // MARK: Highlights

    func testHiddenPreferenceNeedsFiveWorksAcrossThreeSessionsWithoutASearch() throws {
        var events = (1...5).map { event(.save, Int64($0), tags: ["top", "quiet"], at: date(9, $0), context: .init(origin: .search, query: "top", session: "s\($0 % 3)")) }
        events += (6...9).map { event(.save, Int64($0), tags: ["top"], at: date(9, $0), context: .init(origin: .search, query: "top", session: "t")) }
        XCTAssertEqual(try september(events).highlights.first?.kind, .hidden)
        XCTAssertEqual(try september(events).highlights.first?.tag.name, "quiet")
        let searched = events + [event(.search, 0, tags: ["quiet"], at: date(8, 1), context: .init(origin: .search, query: "quiet", session: "x"))]
        XCTAssertNotEqual(try september(searched).highlights.first?.kind, .hidden)
    }
    func testComebackNeedsRealHistoryAndASilentPreviousPeriod() throws {
        var events = (1...3).map { event(.save, Int64($0), tags: ["old_love"], at: date(4, 2)) }
        events += (4...7).map { event(.save, Int64($0), tags: ["main"], at: date(8, 2)) }
        events += (8...9).map { event(.save, Int64($0), tags: ["old_love", "main"], at: date(9, 2)) }
        events += (10...12).map { event(.save, Int64($0), tags: ["main"], at: date(9, 3)) }
        let recap = try september(events)
        XCTAssertEqual(recap.highlights.first?.kind, .comeback)
        XCTAssertEqual(recap.highlights.first?.tag.name, "old_love")
    }
    func testNewcomersAndRisersRankBehindRarerPatterns() throws {
        var events = (1...2).map { event(.save, Int64($0), tags: ["riser"], at: date(8, 2)) }
        events += (3...7).map { event(.save, Int64($0), tags: ["riser"], at: date(9, 2)) }
        events += (8...10).map { event(.save, Int64($0), tags: ["brand_new"], at: date(9, 2)) }
        XCTAssertEqual(try september(events).highlights.map(\.kind), [.newcomer, .rising])
    }

    // MARK: Works

    func testDisplayedWorksComeOnlyFromTheVisibleLibrary() throws {
        let recap = try september([event(.save, 1, tags: ["a"], at: date(9, 2)), event(.save, 2, tags: ["a"], at: date(9, 2))], library: info(2...2))
        XCTAssertEqual(recap.saves, 2, "hidden works still count")
        XCTAssertEqual(recap.saved.map(\.item.id), [2], "but are never shown")
    }
    func testCoverIsTheWorkMostLikeThePeriod() throws {
        let events = [
            event(.save, 1, tags: ["a", "b"], at: date(9, 2)), event(.save, 2, tags: ["a", "b"], at: date(9, 2)),
            event(.save, 3, tags: ["a", "rare"], at: date(9, 2)), event(.save, 4, tags: ["a", "b"], at: date(9, 2)), event(.save, 5, tags: ["other"], at: date(9, 2))
        ]
        XCTAssertNotEqual(try september(events, library: info(1...5)).cover?.item.id, 5)
        XCTAssertNotEqual(try september(events, library: info(1...5)).cover?.item.id, 3)
    }
    func testRediscoveryOffersOldUnopenedWorksMatchingCurrentTaste() throws {
        let old = date(1, 5), events = [
            event(.save, 1, tags: ["sky"], at: date(9, 2)),
            event(.save, 10, tags: ["sky"], at: old),                     // match
            event(.save, 11, tags: ["sea"], at: old),                     // different taste
            event(.save, 12, tags: ["sky"], at: old),                     // opened recently
            event(.open, 12, at: date(9, 1)),
            event(.save, 13, tags: ["sky"], at: old),                     // removed
            event(.remove, 13, at: date(2, 1)),
            event(.save, 14, tags: ["sky"], at: date(9, 1))               // saved this month
        ]
        let recap = try september(events, library: info(1...14, savedAt: old))
        XCTAssertEqual(recap.rediscover.map(\.item.id), [10])
        XCTAssertTrue(try XCTUnwrap(index(events, library: info(1...14, savedAt: old)).recap(period: .month, offset: -1, now: now, rediscovers: false)).rediscover.isEmpty)
    }

    // MARK: Persona

    func testPersonaComesFromMeasuredBehaviorAndShowsItsEvidence() throws {
        let night = (1...6).map { event(.save, Int64($0), tags: ["a\($0)"], at: date(9, $0 + 3, hour: 23), context: .init(origin: .search, query: "a\($0)", session: "s\($0)")) }
        let persona = try XCTUnwrap(try september(night).persona)
        XCTAssertEqual(persona.rhythm, .midnight); XCTAssertEqual(persona.style, .hunter)
        XCTAssertTrue(persona.traits.contains { $0.key.contains("after 10 PM") && $0.arguments == ["100"] })
        XCTAssertTrue(persona.traits.contains { $0.key.contains("searches") && $0.arguments == ["100"] })
    }
    func testPersonaWaitsForEnoughActivityAndCuratorIsSelective() throws {
        XCTAssertNil(try september((1...2).map { event(.save, Int64($0), tags: ["a"], at: date(9, 2)) }).persona)
        var events = (1...20).map { event(.open, Int64($0), at: date(9, 2 + $0 % 5, hour: 14)) }
        events += (1...2).map { event(.save, Int64($0), tags: ["a"], at: date(9, 5, hour: 14)) }
        XCTAssertEqual(try september(events).persona?.style, .curator)
    }
    func testEveryPersonaAndPaletteMoodIsLocalized() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "ko", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let keys = RecapPersona.Rhythm.allCases.map { "persona.rhythm." + $0.rawValue } + RecapPersona.Style.allCases.flatMap { ["persona.style." + $0.rawValue, "persona.summary." + $0.rawValue] }
            + ["ember", "amber", "honey", "moss", "lagoon", "deepSea", "twilight", "iris", "peony", "ink", "ash", "paper"].map { "palette." + $0 }
        for key in keys { XCTAssertNotEqual(bundle.localizedString(forKey: key, value: key, table: nil), key) }
    }

    // MARK: Pages and issues

    func testStoryOnlyIncludesPagesWithSomethingTrueToSay() throws {
        let quiet = try september([])
        XCTAssertEqual(RecapPage.pages(for: quiet), [.cover])
        let single = try september([event(.save, 1, tags: ["a"], at: date(9, 2))], library: info(1...1))
        XCTAssertEqual(RecapPage.pages(for: single), [.cover, .numbers, .chart, .palette, .next])
        let week = try XCTUnwrap(index([event(.save, 1, tags: ["a"], at: date(10, 13)), event(.save, 2, tags: ["a"], at: date(10, 14))], library: info(1...2, artist: "mira")).recap(period: .week, offset: 0, now: now))
        XCTAssertFalse(RecapPage.pages(for: week).contains(.person))
        XCTAssertFalse(RecapPage.pages(for: week).contains(.palette))
        XCTAssertFalse(week.isComplete)
    }
    func testIssuesSkipSilentMonthsAndNumberFromTheFirst() throws {
        let issues = index([event(.save, 1, tags: ["a"], at: date(6, 2)), event(.open, 2, at: date(8, 2)), event(.save, 3, tags: ["a"], at: date(10, 2))]).issues(now: now)
        XCTAssertEqual(issues.map(\.issue), [3, 2, 1])
        XCTAssertEqual(issues.map(\.offset), [0, -2, -4])
        XCTAssertTrue(index([]).issues(now: now).isEmpty)
    }
    func testYearCarriesTwelveMonthsWithTheirBusiest() throws {
        let recap = try XCTUnwrap(index((1...4).map { event(.save, Int64($0), tags: ["a"], at: date($0 == 1 ? 3 : 7, 2)) }).yearly(offset: 0, now: now))
        XCTAssertEqual(recap.months.count, 12)
        XCTAssertEqual(recap.months.map(\.saves)[2], 1)
        XCTAssertEqual(recap.months.map(\.saves)[6], 3)
        XCTAssertTrue(RecapPage.pages(for: recap).contains(.year))
    }
    func testSampleIssuesRunThroughTheRealBuilderInBothModes() throws {
        for mode in [TasteMode.booru, .comics] {
            let sample = try XCTUnwrap(TasteRecap.sample(mode: mode, now: now, timeZone: zone))
            XCTAssertTrue(sample.isSample); XCTAssertEqual(sample.saves, 46)
            XCTAssertNotNil(sample.persona); XCTAssertFalse(sample.rediscover.isEmpty)
            XCTAssertGreaterThanOrEqual(RecapPage.pages(for: sample).count, 10)
        }
    }

    // MARK: Text

    func testTagTextDropsSearchSyntaxAndDurationReads() {
        XCTAssertEqual(RecapText.tag("female:big_hat"), "big hat")
        XCTAssertEqual(RecapText.tag("blue_sky"), "blue sky")
        XCTAssertFalse(RecapText.duration(30).isEmpty)
        XCTAssertNotEqual(RecapText.duration(3600), RecapText.duration(3660))
    }
    func testPercentSentencesFormatInEveryLanguage() {
        let original = L10n.appLanguage
        defer { L10n.appLanguage = original }
        for language in ["en", "ko", "ja"] {
            L10n.appLanguage = language
            XCTAssertTrue(RecapLine("%@%% of saves came from your searches", "62").text.contains("62%"), language)
            XCTAssertTrue(RecapLine("You kept %@ of %@ works you opened", "3", "20").text.contains("20"), language)
        }
    }

    // MARK: Palette

    func testPaletteIsMeasuredFromColorNotFromMargins() throws {
        let blue = RecapColor(red: 0.1, green: 0.25, blue: 0.85), white = RecapColor(red: 1, green: 1, blue: 1)
        let palette = try XCTUnwrap(RecapPalette.extract(Array(repeating: white, count: 700) + Array(repeating: blue, count: 300)))
        XCTAssertEqual(palette.swatches.count, 5)
        XCTAssertGreaterThan(palette.swatches[0].blue, palette.swatches[0].red * 2)
        XCTAssertEqual(palette.mood, "deepSea")
        XCTAssertNil(RecapPalette.extract([]), "without covers the caller keeps its seeded colors")
        XCTAssertNil(RecapPalette.extract(Array(repeating: RecapColor(red: 0, green: 0, blue: 0), count: 20)))
    }
    func testStageColorsStayLegibleForAnyArtwork() throws {
        for color in [RecapColor(red: 1, green: 1, blue: 0.9), .init(red: 0.12, green: 0.12, blue: 0.12), .init(red: 1, green: 0, blue: 0), .init(red: 0.5, green: 0.5, blue: 0.5)] {
            let palette = try XCTUnwrap(RecapPalette.extract(Array(repeating: color, count: 50)))
            let lead = palette.swatches.max { $0.hsb.saturation * $0.hsb.brightness < $1.hsb.saturation * $1.hsb.brightness }!
            XCTAssertLessThan(lead.with(brightness: 0.13).luminance, 0.14)
        }
    }
    func testSeededPaletteIsStableAndColorRoundTrips() {
        XCTAssertEqual(RecapPalette.seeded("sky"), RecapPalette.seeded("sky"))
        XCTAssertNotEqual(RecapPalette.seeded("sky"), RecapPalette.seeded("sea"))
        let color = RecapColor(red: 0.2, green: 0.6, blue: 0.4), value = color.hsb
        let back = RecapColor(hue: value.hue, saturation: value.saturation, brightness: value.brightness)
        XCTAssertEqual(back.red, color.red, accuracy: 0.001); XCTAssertEqual(back.blue, color.blue, accuracy: 0.001)
    }
    func testDeletingAnalysisAlsoDeletesMeasuredRecapColors() throws {
        let store = try AppDatabase.inMemory().tasteStore
        try store.metadata(RecapPalette.seeded("x"), key: "recap.palette.booru:month:1")
        var next = try store.control(); next.epoch = UUID().uuidString
        try store.setControl(next)
        XCTAssertNil(try store.metadata(RecapPalette.self, key: "recap.palette.booru:month:1"))
    }

    // MARK: Scale

    func testAYearOfHeavyUseStaysFastEnoughForAShelf() throws {
        var events: [TasteEvent] = [], library: [String: RecapWorkInfo] = [:]
        for id in 1...30000 {
            let tags = (0..<12).map { "tag\((id &* ($0 + 3)) % 400)" }, at = date(1, 1).addingTimeInterval(Double(id) * 900)
            events.append(event(.save, Int64(id), tags: tags, at: at))
            events.append(event(.open, Int64(id), tags: tags, at: at))
            library["https://a.example#\(id)"] = .init(artists: ["artist\(id % 50)"], savedAt: at)
        }
        let start = Date()
        let index = index(events, library: library)
        let issues = index.issues(now: now)
        _ = index.recap(period: .month, offset: -1, now: now)
        let elapsed = Date().timeIntervalSince(start)
        print("Recap index and \(issues.count) issues from \(events.count) events: \(elapsed)s")
        XCTAssertLessThan(elapsed, 8)
    }
}
