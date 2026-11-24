import XCTest
@testable import TEGNAL

/// Settings' pages, search and the Apple Intelligence assistant's checks on what the model asks for.
@MainActor final class SettingsCatalogTests: XCTestCase {
    private var language = ""
    override func setUp() { super.setUp(); language = L10n.appLanguage }
    override func tearDown() { L10n.appLanguage = language; super.tearDown() }

    private func environment() throws -> (AppEnvironment, () -> Void) {
        let name = "settings-catalog-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let env = AppEnvironment(database: try .inMemory(), browserPreferences: defaults)
        return (env, { defaults.removePersistentDomain(forName: name) })
    }

    func testEachModeListsEverySettingOnceAndEveryPageHasSomethingToFind() {
        for booru in [false, true] {
            let items = SettingsCatalog.items(booru: booru)
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "ids are unique, booru: \(booru)")
            for category in SettingsCategory.allCases {
                XCTAssertTrue(items.contains { $0.category == category && $0.listed }, "\(category) has a setting search finds, booru: \(booru)")
            }
        }
        XCTAssertEqual(Set(SettingsCategory.groups.joined() + [.addons]), Set(SettingsCategory.allCases), "every page is on the top level once; Add-ons sits with the website")
        XCTAssertEqual(SettingsCategory.groups.joined().count + 1, SettingsCategory.allCases.count)
        XCTAssertEqual(SettingsCategory.groups.first?.first, .browsing, "what changes the most comes first")
    }

    func testSearchMatchesTitlesPagesAndKeywordsInTheAppLanguage() {
        L10n.appLanguage = "en"
        let comics = SettingsCatalog.items(booru: false)
        XCTAssertEqual(SettingsCatalog.search("right to left", in: comics).first?.id, "reader.rtl")
        XCTAssertTrue(SettingsCatalog.search("dark", in: comics).contains { $0.id == "appearance.theme" }, "keywords find the theme")
        XCTAssertTrue(SettingsCatalog.search("viewer", in: comics).allSatisfy { $0.category == .viewer || $0.title.localizedCaseInsensitiveContains("viewer") })
        XCTAssertTrue(SettingsCatalog.search("   ", in: comics).isEmpty)
        XCTAssertFalse(SettingsCatalog.search("default tags", in: comics).contains { ["search.showHiddenTags", "search.stopRequiringTags"].contains($0.id) }, "assistant-only controls stay out of search")
        XCTAssertTrue(SettingsCatalog.search("block", in: comics).contains { $0.id == "search.hideTags" })
        XCTAssertTrue(SettingsCatalog.search("blacklist", in: SettingsCatalog.items(booru: true)).contains { $0.id == "browse.blacklist" })

        L10n.appLanguage = "ko"
        let korean = SettingsCatalog.items(booru: false)
        XCTAssertTrue(SettingsCatalog.search("오른쪽", in: korean).contains { $0.id == "reader.rtl" })
        XCTAssertTrue(SettingsCatalog.search("화면테마", in: korean).contains { $0.id == "appearance.theme" }, "words typed without the title's spaces match")
        XCTAssertTrue(SettingsCatalog.search("right to left", in: korean).contains { $0.id == "reader.rtl" }, "English titles match in every language")
    }

    func testControlsAcceptOnlyValuesTheyAllow() {
        let items = Dictionary(uniqueKeysWithValues: SettingsCatalog.items(booru: false).map { ($0.id, $0) })
        let rtl = try! XCTUnwrap(items["reader.rtl"]?.control)
        XCTAssertEqual(rtl.normalized("TRUE"), "on")
        XCTAssertEqual(rtl.normalized(" off "), "off")
        XCTAssertNil(rtl.normalized("maybe"))
        let mode = try! XCTUnwrap(items["reader.mode"]?.control)
        XCTAssertEqual(mode.normalized("Continuous"), "continuous")
        XCTAssertNil(mode.normalized("sideways"))
        let dimming = try! XCTUnwrap(items["reader.dimming"]?.control)
        XCTAssertEqual(dimming.normalized("30"), "30")
        XCTAssertNil(dimming.normalized("90"))
        let excluded = try! XCTUnwrap(items["search.hideTags"]?.control)
        XCTAssertEqual(excluded.normalized(" -male:males_only, artist:someone "), "male:males_only artist:someone")
        XCTAssertNil(excluded.normalized(" , "))
    }

    func testAssistantAppliesOnlyListedAllowedChangesAndUndoRestoresThem() throws {
        let (env, cleanUp) = try environment()
        defer { cleanUp() }
        env.gridColumns = 0
        env.defaultExcludedTags = "tag:a"
        let items = SettingsCatalog.items(booru: false).filter { $0.control != nil }
        let plan = SettingsAssistant.Plan(changes: [
            ("appearance.thumbnailSize", "5"),
            ("appearance.thumbnailSize", "2"),
            ("search.hideTags", "male:males_only tag:a"),
            ("unknown.setting", "on"),
            ("reader.mode", "sideways"),
            ("appearance.noSpacing", env.removesGridPadding ? "on" : "off"),
        ], reply: "Done", open: "viewer")
        let result = SettingsAssistant.apply(plan, items: items, env: env)
        XCTAssertEqual(env.gridColumns, 2, "a setting named twice keeps the last value")
        XCTAssertEqual(env.defaultExcludedTags, "tag:a male:males_only", "tags join the list once")
        XCTAssertEqual(result.changes.map(\.itemID), ["appearance.thumbnailSize", "search.hideTags"], "unknown ids, disallowed values and unchanged settings are skipped")
        XCTAssertEqual(result.changes.first?.previous, "0")
        XCTAssertNil(result.open, "a page is offered only when nothing could change")

        let remove = SettingsAssistant.apply(.init(changes: [("search.showHiddenTags", "tag:a")]), items: items, env: env)
        XCTAssertEqual(env.defaultExcludedTags, "male:males_only")
        XCTAssertEqual(remove.changes.count, 1)

        for change in (result.changes + remove.changes).reversed() { items.first { $0.id == change.itemID }?.control?.set(env, change.previous) }
        XCTAssertEqual(env.gridColumns, 0)
        XCTAssertEqual(env.defaultExcludedTags, "tag:a")

        let nothing = SettingsAssistant.apply(.init(changes: [], open: "privacy"), items: items, env: env)
        XCTAssertEqual(nothing.open, .privacy)
        XCTAssertNil(SettingsAssistant.apply(.init(open: "elsewhere"), items: items, env: env).open)
    }

    func testTagsKeepTheSpellingTheRequestWroteThemIn() {
        let items = SettingsCatalog.items(booru: false)
        XCTAssertEqual(SettingsAssistant.requestTags("male:males_only 태그가 붙은 작품은 숨겨 줘"), ["male:males_only"])
        XCTAssertEqual(SettingsAssistant.requestTags("Hide “artist:some_one” and big_breasts, please."), ["artist:some_one", "big_breasts"])
        XCTAssertEqual(SettingsAssistant.requestTags("Set it to 10:30 or : nothing"), ["10:30"])
        let masked = SettingsAssistant.maskingTags("Hide male:males_only and big_breasts, then show male:males_only")
        XCTAssertEqual(masked.request, "Hide TAG1 and TAG2, then show TAG1")
        XCTAssertEqual(masked.tags, ["male:males_only", "big_breasts"])
        let plan = SettingsAssistant.unmaskingTags(masked.tags, in: .init(changes: [("search.hideTags", "TAG2"), ("search.showHiddenTags", "male"), ("reader.rtl", "on")], reply: "Hid TAG2."), items: items)
        XCTAssertEqual(plan.reply, "Hid big_breasts.")
        XCTAssertEqual(plan.changes.map(\.value), ["big_breasts", "male:males_only big_breasts", "on"], "named tags come back; a value without one takes the request's tags; other settings pass through")
        let plain = SettingsAssistant.unmaskingTags([], in: .init(changes: [("search.hideTags", "spoilers")]), items: items)
        XCTAssertEqual(plain.changes.first?.value, "spoilers", "a request without written tags keeps the model's")
    }

    func testCatalogTellsTheModelEachSettingsValuesAndCurrentValue() throws {
        let (env, cleanUp) = try environment()
        defer { cleanUp() }
        env.appTheme = .light
        let text = SettingsAssistant.catalog(SettingsCatalog.items(booru: false), env: env)
        let theme = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("appearance.theme |") })
        XCTAssertTrue(theme.contains("dark/light/system"))
        XCTAssertTrue(theme.hasSuffix("now: light"))
        env.defaultExcludedTags = "secret:one secret:two"
        let excluded = try XCTUnwrap(SettingsAssistant.catalog(SettingsCatalog.items(booru: false), env: env).split(separator: "\n").first { $0.hasPrefix("search.hideTags |") })
        XCTAssertTrue(excluded.hasSuffix("now: 2 tags"), "the user's own tags never reach the model")
        XCTAssertFalse(text.contains("browse.recent |"), "pages without a control are not offered to the model")
    }
}

/// The real on-device model, where this Mac or device runs Apple Intelligence; skipped elsewhere.
@MainActor final class SettingsAssistantModelTests: XCTestCase {
    func testOnDeviceModelTurnsRequestsIntoAllowedChanges() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), SettingsAssistant.isAvailable else { throw XCTSkip("Apple Intelligence is not available here") }
        let language = L10n.appLanguage
        defer { L10n.appLanguage = language }
        let name = "settings-model-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let env = AppEnvironment(database: try .inMemory(), browserPreferences: defaults)
        let items = SettingsCatalog.items(booru: false).filter { $0.control != nil }
        let cases: [(language: String, request: String, expected: [String: String])] = [
            ("en", "Make the grid 2 columns and use the light theme", ["appearance.thumbnailSize": "2", "appearance.theme": "light"]),
            ("ko", "웹툰처럼 세로로 쭉 스크롤해서 보고 싶어", ["reader.mode": "continuous"]),
            ("ko", "화면 꺼지지 않게 해 줘", ["reader.keepAwake": "on"]),
            ("ja", "右から左に読みたい", ["reader.rtl": "on"]),
            ("ko", "male:males_only 태그가 붙은 작품은 탐색에서 안 보이게 해 줘", ["search.hideTags": "male:males_only"]),
            ("en", "Dim the screen by 30 percent while reading", ["reader.dimming": "30"]),
            ("en", "What's the weather like today?", [:]),
            ("ko", "썸네일을 2열로 크게 보여 줘", ["appearance.thumbnailSize": "2"]),
        ]
        for test in cases {
            L10n.appLanguage = test.language
            let masked = SettingsAssistant.maskingTags(test.request)
            let plan = SettingsAssistant.unmaskingTags(masked.tags, in: try await SettingsModel.plan(request: masked.request, items: items, env: env, history: ""), items: items)
            print("[settings model]", test.request, "→", plan.changes, plan.reply, plan.open ?? "-")
            for (id, value) in test.expected {
                let item = try XCTUnwrap(items.first { $0.id == id })
                XCTAssertTrue(plan.changes.contains { $0.id == id && item.control?.normalized($0.value) == value }, "\(test.request) sets \(id) to \(value)")
            }
            if test.expected.isEmpty { XCTAssertTrue(plan.changes.isEmpty, "\(test.request) changes nothing") }
        }
        #else
        throw XCTSkip("FoundationModels is not in this SDK")
        #endif
    }
}
