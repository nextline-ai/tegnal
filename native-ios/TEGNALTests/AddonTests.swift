import XCTest
import GRDB
@testable import TEGNAL

final class AddonTests: XCTestCase {
    override func tearDown() {
        AddonRuntime.shared.apply(AddonEffects())
        super.tearDown()
    }

    // MARK: - Files

    private func file(_ contents: [String: Any], extra: [String: Any] = [:], id: String = "maker.sample-pack", version: String = "1.0.0") -> Data {
        var top: [String: Any] = ["format": "tegnal-addon", "schemaVersion": 1, "id": id, "version": version,
                                  "name": ["en": "Sample Pack", "ko": "샘플 팩"], "author": "Maker", "contents": contents]
        for (key, value) in extra { top[key] = value }
        return try! JSONSerialization.data(withJSONObject: top)
    }

    private static let translations: [String: Any] = ["tagTranslations": ["language": "ko", "entries": ["long_hair": "긴 머리", "female:glasses": "안경"]]]

    private static let track: [String: Any] = ["learningTrack": [
        "title": ["ko": "배경 트랙"], "summary": ["ko": "배경을 배웁니다"], "color": "2F9E6E", "symbol": "mountain.2",
        "groups": [["id": "places", "title": ["ko": "장소"], "tags": [["name": "lighthouse", "ko": "등대", "note": ["ko": "바닷가의 등대"]]]]],
        "sections": [["id": "one", "title": ["ko": "첫 구간"], "summary": ["ko": "요약"], "color": "2F9E6E", "lessons": [
            ["id": "intro", "kind": "concept", "symbol": "book", "title": ["ko": "소개"], "steps": [
                ["card": ["title": ["ko": "안녕"], "body": ["ko": "배경 이야기"]]],
                ["ask": ["question": ["ko": "질문"], "choices": [["ko": "가"], ["ko": "나"]], "answer": 0, "why": ["ko": "이유"]]]
            ]],
            ["id": "tags", "kind": "tags", "symbol": "tag", "title": ["ko": "태그"], "tags": ["lighthouse", "long_hair"]]
        ]]]
    ]]

    func testAValidFileDecodesWithItsFingerprintAndFillsInEnglish() throws {
        let data = file(Self.translations.merging(Self.track) { $1 })
        let (addon, digest) = try Addon.decode(data)
        XCTAssertEqual(addon.id, "maker.sample-pack")
        XCTAssertEqual(addon.contents.kinds, [.translations, .track])
        XCTAssertEqual(digest, Addon.digest(data))
        XCTAssertEqual(digest.count, 64)
        // Text written in Korean only gets an English wording too, so that it is never blank.
        XCTAssertEqual(addon.contents.learningTrack?.title["en"], "배경 트랙")
        XCTAssertEqual(addon.contents.learningTrack?.sections.first?.lessons.first?.steps?.first?.card?.title["en"], "안녕")
    }

    func testFilesThatAreNotAddonsOrAreNewerAreRefused() {
        XCTAssertThrowsError(try Addon.decode(Data("[]".utf8))) { XCTAssertEqual($0 as? AddonError, .notAddon) }
        XCTAssertThrowsError(try Addon.decode(Data(#"{"format":"tegnal-challenges"}"#.utf8))) { XCTAssertEqual($0 as? AddonError, .notAddon) }
        var newer = try! JSONSerialization.jsonObject(with: file(Self.translations)) as! [String: Any]
        newer["schemaVersion"] = 2
        XCTAssertThrowsError(try Addon.decode(try! JSONSerialization.data(withJSONObject: newer))) { XCTAssertEqual($0 as? AddonError, .newerFormat) }
        XCTAssertThrowsError(try Addon.decode(Data(count: Addon.maximumBytes + 1))) { XCTAssertEqual($0 as? AddonError, .tooLarge) }
        XCTAssertThrowsError(try Addon.decode(file([:]))) { XCTAssertEqual($0 as? AddonError, .empty) }
    }

    func testAnythingNotUnderstoodIsRefusedRatherThanSkipped() {
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, extra: ["script": "alert(1)"]))) { XCTAssertEqual($0 as? AddonError, .unknownContent("script")) }
        XCTAssertThrowsError(try Addon.decode(file(Self.translations.merging(["themes": [:]]) { $1 }))) { XCTAssertEqual($0 as? AddonError, .unknownContent("themes")) }
    }

    func testIdentifiersVersionsAndHiddenCharactersAreChecked() {
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, id: "Bad Id")))
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, id: "../escape")))
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, version: "1.0-beta")))
        // A direction override can make a name read as something else.
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, extra: ["author": "Mak\u{202E}er"])))
        XCTAssertThrowsError(try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["long_hair": "긴\u{0007}머리"]]])))
        XCTAssertThrowsError(try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["long_hair": "두 줄\n번역"]]])))
        XCTAssertThrowsError(try Addon.decode(file(["tagTranslations": ["language": "fr", "entries": ["long_hair": "x"]]])))
        // Emoji joined with a zero-width joiner stay allowed.
        XCTAssertNoThrow(try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["family": "👨‍👩‍👧"]]])))
        XCTAssertEqual(AddonCheck.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(AddonCheck.compare("2", "2.0.0"), .orderedSame)
    }

    func testOneTagHasOneTranslation() {
        XCTAssertThrowsError(try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["Long_Hair": "긴 머리", "long hair": "장발"]]])))
        XCTAssertThrowsError(try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["hair*": "x"]]])))
    }

    func testSearchTagsCannotWidenOrRewriteASearch() {
        func search(_ value: [String: Any]) -> Data { file(["searchTags": value]) }
        XCTAssertNoThrow(try Addon.decode(search(["comics": ["include": ["language:korean"], "exclude": ["tag:gore", "female:guro"]], "images": ["exclude": ["gore", "blood -scenery", "rating:explicit", "artist:someone"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["comics": ["include": ["two words"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["comics": ["include": ["-gore"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["comics": ["include": ["\"quoted\""]]])))
        XCTAssertThrowsError(try Addon.decode(search(["comics": ["include": ["unknown:space"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["images": ["exclude": ["-scenery"]]])), "A rule starting with a minus would hide everything else")
        XCTAssertThrowsError(try Addon.decode(search(["images": ["exclude": ["a*b*c*d"]]])), "No wildcards")
        XCTAssertThrowsError(try Addon.decode(search(["images": ["exclude": ["id:123"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["images": ["exclude": ["rating:whatever"]]])))
        XCTAssertThrowsError(try Addon.decode(search(["comics": ["include": []]])), "Nothing to add")
    }

    func testTrackCardsCannotOpenAnythingAndTagLessonsNeedMeanings() {
        var track = Self.track["learningTrack"] as! [String: Any]
        var sections = track["sections"] as! [[String: Any]]
        var lessons = sections[0]["lessons"] as! [[String: Any]]
        var withAction = lessons
        withAction[0]["steps"] = [["card": ["title": ["en": "Go"], "body": ["en": "Spend"], "code": "1girl", "action": "generator"]]]
        sections[0]["lessons"] = withAction; track["sections"] = sections
        XCTAssertThrowsError(try Addon.decode(file(["learningTrack": track])), "Cards in add-ons only tell")

        lessons[1]["tags"] = ["lighthouse", "not_a_known_tag_anywhere"]
        sections[0]["lessons"] = lessons; track["sections"] = sections
        XCTAssertThrowsError(try Addon.decode(file(["learningTrack": track])), "Every tag needs a meaning")
    }

    func testChallengesFollowTheChallengeRulesAndTheAddonTextRules() throws {
        var game = ChallengeDefinition.croquis(); game.id = "sketch"
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(game))
        XCTAssertNoThrow(try Addon.decode(file(["challenges": [encoded]])))
        var hidden = game; hidden.title = "Sketch\u{2066}"
        XCTAssertThrowsError(try Addon.decode(file(["challenges": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(hidden))]])))
        var tagged = game; tagged.reels[0].options[0].tags = ["rating:explicit"]
        XCTAssertThrowsError(try Addon.decode(file(["challenges": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(tagged))]])))
    }

    // MARK: - Store and effects

    func testInstallingTurningOffAndRemovingTakesEverythingBack() throws {
        let booru = try BooruStore()
        let store = AddonStore(booru)
        var game = ChallengeDefinition.croquis(); game.id = "sketch"
        let challenge = try JSONSerialization.jsonObject(with: JSONEncoder().encode(game))
        let (addon, digest) = try Addon.decode(file(Self.translations.merging(["challenges": [challenge], "searchTags": ["comics": ["exclude": ["tag:gore"]], "images": ["exclude": ["blood"]]]]) { $1 }))
        try store.install(addon, digest: digest)
        AddonRuntime.shared.reload(booru)

        XCTAssertEqual(AddonRuntime.shared.translation("long_hair"), "긴 머리")
        XCTAssertEqual(AddonRuntime.shared.translation("Long Hair"), "긴 머리")
        XCTAssertEqual(AddonRuntime.shared.translation("female:glasses"), "안경")
        XCTAssertEqual(AddonRuntime.shared.translation("tag:long_hair"), "긴 머리", "A namespaced tag falls back to its name")
        XCTAssertNil(AddonRuntime.shared.translation("short_hair"))
        let group = ArtworkTagGroup.make(tags: ["long_hair"]).first?.tags.first
        XCTAssertEqual(group?.name, "긴 머리")
        XCTAssertEqual(group?.query, "long_hair", "Searches still use the tag itself")
        XCTAssertEqual(group?.original, "long hair")

        try booru.setBlacklist("spoilers", serverID: "s")
        XCTAssertEqual(booru.filteringBlacklist(serverID: "s"), "spoilers\nblood")
        XCTAssertEqual(booru.blacklist(serverID: "s"), "spoilers", "The learner's own list never holds an add-on's rules")

        let challenges = ChallengeStore(booru)
        XCTAssertEqual(try challenges.definitions().map(\.id), ["addon:maker.sample-pack:sketch"])

        try store.setEnabled(addon.id, false)
        AddonRuntime.shared.reload(booru)
        XCTAssertNil(AddonRuntime.shared.translation("long_hair"))
        XCTAssertEqual(booru.filteringBlacklist(serverID: "s"), "spoilers")
        XCTAssertEqual(try challenges.definitions(), [], "A challenge of an add-on that is off is hidden")

        try store.setEnabled(addon.id, true)
        XCTAssertEqual(try challenges.definitions().count, 1)
        try store.remove(addon.id)
        AddonRuntime.shared.reload(booru)
        XCTAssertEqual(try store.installed(), [])
        XCTAssertEqual(try booru.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM challenges") }, 0)
        XCTAssertTrue(AddonRuntime.shared.effects.enabledIDs.isEmpty)
    }

    func testAnUpdateKeepsTheOnOffChoiceAndDropsChallengesItNoLongerHas() throws {
        let booru = try BooruStore()
        let store = AddonStore(booru)
        var first = ChallengeDefinition.croquis(); first.id = "first"
        var second = first; second.id = "second"
        let encode = { (game: ChallengeDefinition) in try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) }
        let old = try Addon.decode(file(["challenges": [try encode(first), try encode(second)]]))
        try store.install(old.addon, digest: old.digest)
        try store.setEnabled(old.addon.id, false)
        let new = try Addon.decode(file(["challenges": [try encode(second)]], version: "1.1"))
        try store.install(new.addon, digest: new.digest)
        let installed = try store.installed()
        XCTAssertEqual(installed.map(\.addon.version), ["1.1"])
        XCTAssertEqual(installed.first?.enabled, false)
        XCTAssertEqual(try booru.database.read { try String.fetchAll($0, sql: "SELECT id FROM challenges") }, ["addon:maker.sample-pack:second"])
    }

    func testTracksBecomePathsOfTheirOwnWithTheirTagsInTheCurriculum() throws {
        let (addon, _) = try Addon.decode(file(Self.track))
        let effects = AddonEffects([InstalledAddon(addon: addon, enabled: true, installed: .now, digest: "")])
        let track = try XCTUnwrap(effects.tracks.first)
        XCTAssertEqual(track.path.lessons.map(\.id), ["addon:maker.sample-pack:intro", "addon:maker.sample-pack:tags"])
        XCTAssertFalse(StudyPath.bundled.lessons.contains { $0.id.hasPrefix("addon:") })
        let curriculum = StudyCurriculum(version: 1, units: StudyCurriculum.bundled.units + [try XCTUnwrap(track.unit)])
        XCTAssertEqual(curriculum.tag("lighthouse")?.title("ko"), "등대")
        XCTAssertNotNil(curriculum.tag("long_hair"), "The app's own tags stay")
        let records = Dictionary(uniqueKeysWithValues: track.path.lessons.map { ($0.id, StudyLessonRecord(lesson: $0.id, stars: 3, runs: 1)) })
        XCTAssertTrue(track.complete(records))
        XCTAssertFalse(track.complete([:]))
        XCTAssertTrue(AddonEffects([InstalledAddon(addon: addon, enabled: false, installed: .now, digest: "")]).tracks.isEmpty)
    }

    func testLaterAddonsWinWhenTwoTranslateTheSameTag() throws {
        let first = try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["long_hair": "긴 머리"]]], id: "maker.first")).addon
        let second = try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["long_hair": "장발"]]], id: "maker.second")).addon
        let effects = AddonEffects([InstalledAddon(addon: second, enabled: true, installed: Date(timeIntervalSince1970: 2), digest: ""),
                                    InstalledAddon(addon: first, enabled: true, installed: Date(timeIntervalSince1970: 1), digest: "")])
        XCTAssertEqual(effects.translation("long_hair"), "장발")
    }

    func testTheSampleAddonsInTheDocsFolderPass() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/addons")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == Addon.fileExtension } ?? []
        try XCTSkipIf(files.isEmpty, "The samples are local only")
        for url in files { XCTAssertNoThrow(try Addon.read(url), url.lastPathComponent) }
    }
}
