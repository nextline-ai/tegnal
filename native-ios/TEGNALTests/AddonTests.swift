import XCTest
import CryptoKit
import GRDB
@testable import TEGNAL

final class AddonTests: XCTestCase {
    override func tearDown() {
        AddonRuntime.shared.apply(AddonEffects())
        super.tearDown()
    }

    // MARK: - Files

    private func file(_ contents: [String: Any], extra: [String: Any] = [:], id: String = "maker.sample-pack", version: String = "1.0.0", mode: String = "images") -> Data {
        var top: [String: Any] = ["format": "tegnal-addon", "schemaVersion": 1, "id": id, "version": version, "mode": mode,
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
        func search(_ value: [String: Any]) -> Data { file(["searchTags": value], mode: value["images"] == nil ? "comics" : "images") }
        XCTAssertNoThrow(try Addon.decode(search(["comics": ["include": ["language:korean"], "exclude": ["tag:gore", "female:guro"]]])))
        XCTAssertNoThrow(try Addon.decode(search(["images": ["exclude": ["gore", "blood -scenery", "rating:explicit", "artist:someone"]]])))
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
        let (addon, digest) = try Addon.decode(file(Self.translations.merging(["challenges": [challenge], "searchTags": ["images": ["exclude": ["blood"]]]]) { $1 }))
        try store.install(addon, digest: digest)
        AddonRuntime.shared.reload(booru)

        XCTAssertEqual(AddonRuntime.shared.translation("long_hair", mode: .images), "긴 머리")
        XCTAssertEqual(AddonRuntime.shared.translation("Long Hair", mode: .images), "긴 머리")
        XCTAssertEqual(AddonRuntime.shared.translation("female:glasses", mode: .images), "안경")
        XCTAssertEqual(AddonRuntime.shared.translation("tag:long_hair", mode: .images), "긴 머리", "A namespaced tag falls back to its name")
        XCTAssertNil(AddonRuntime.shared.translation("short_hair", mode: .images))
        XCTAssertNil(AddonRuntime.shared.translation("long_hair", mode: .comics), "An image add-on never renames comics tags")
        XCTAssertEqual(AddonRuntime.shared.effects.enabledCount(.images), 1)
        XCTAssertEqual(AddonRuntime.shared.effects.enabledCount(.comics), 0)
        let group = ArtworkTagGroup.make(tags: ["long_hair"], mode: .images).first?.tags.first
        XCTAssertNil(ArtworkTagGroup.make(tags: ["long_hair"], mode: .comics).first?.tags.first?.original)
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
        XCTAssertNil(AddonRuntime.shared.translation("long_hair", mode: .images))
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
        XCTAssertEqual(effects.translation("long_hair", mode: .images), "장발")
    }

    func testTheSampleAddonsInTheDocsFolderPass() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/addons")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == Addon.fileExtension } ?? []
        try XCTSkipIf(files.isEmpty, "The samples are local only")
        for url in files { XCTAssertNoThrow(try Addon.read(url), url.lastPathComponent) }
    }

    // MARK: - Official add-ons

    private func listing(_ data: Data, id: String = "maker.sample-pack", version: String = "1.0.0") -> [String: Any] {
        ["id": id, "version": version, "mode": "images", "grade": "recommended", "name": ["en": "Sample Pack"], "author": "TEGNAL", "kinds": ["translations"],
         "size": data.count, "sha256": Addon.digest(data)]
    }

    private func signed(_ object: [String: Any], key: P256.Signing.PrivateKey) throws -> (Data, Data) {
        let data = try JSONSerialization.data(withJSONObject: object)
        return (data, try key.signature(for: data).derRepresentation)
    }

    func testOnlyACatalogSignedWithTheKeyIsReadAndBadEntriesAreLeftOut() throws {
        let key = P256.Signing.PrivateKey(), other = P256.Signing.PrivateKey()
        let addon = file(Self.translations)
        var broken = listing(addon, id: "maker.broken"); broken["sha256"] = "XYZ"
        let catalog: [String: Any] = ["format": "tegnal-addon-catalog", "schemaVersion": 1,
                                      "addons": [listing(addon), listing(addon), broken, ["id": 5], listing(addon, id: "maker.later").merging(["schemaVersion": 9]) { $1 }]]
        let (data, signature) = try signed(catalog, key: key)
        let read = try AddonMarket.verify(data, signature: signature, key: key.publicKey)
        XCTAssertEqual(read.addons.map(\.id), ["maker.sample-pack", "maker.later"], "Duplicates and broken entries are left out")
        XCTAssertEqual(read.addons.last.map { AddonListingState($0, installed: nil) }, .unsupported)

        XCTAssertThrowsError(try AddonMarket.verify(data, signature: signature, key: other.publicKey)) { XCTAssertEqual($0 as? AddonMarketError, .unsigned) }
        var tampered = data; tampered[tampered.count - 2] ^= 1
        XCTAssertThrowsError(try AddonMarket.verify(tampered, signature: signature, key: key.publicKey)) { XCTAssertEqual($0 as? AddonMarketError, .unsigned) }
        XCTAssertThrowsError(try AddonMarket.verify(data, signature: Data("nope".utf8), key: key.publicKey)) { XCTAssertEqual($0 as? AddonMarketError, .unsigned) }
    }

    func testADownloadIsInstalledOnlyWhenItMatchesTheCatalog() async throws {
        let key = P256.Signing.PrivateKey()
        let addon = file(Self.translations)
        let (data, signature) = try signed(["format": "tegnal-addon-catalog", "schemaVersion": 1, "addons": [listing(addon)]], key: key)
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": signature.base64EncodedString()])
        var served: [String: Data] = ["catalog.json": envelope, "files/maker.sample-pack/1.0.0.tegnaladdon": addon]
        let base = URL(string: "https://addons.invalid/v1/")!
        let market = { (files: [String: Data]) in
            AddonMarket(base: base, publicKey: key.publicKey, fetch: { url, limit in
                let path = String(url.absoluteString.dropFirst(base.absoluteString.count))
                guard let data = files[path] else { throw AddonMarketError.server(404) }
                guard data.count <= limit else { throw AddonMarketError.damaged }
                return data
            })
        }
        let catalog = try await market(served).catalog()
        let entry = try XCTUnwrap(catalog.addons.first)
        let (read, digest) = try await market(served).download(entry)
        XCTAssertEqual(read.id, "maker.sample-pack")
        XCTAssertEqual(digest, entry.sha256)

        var changed = addon; changed[changed.count - 3] = UInt8(ascii: " ")
        served["files/maker.sample-pack/1.0.0.tegnaladdon"] = changed
        do { _ = try await market(served).download(entry); XCTFail("A changed file must be refused") }
        catch { XCTAssertEqual(error as? AddonMarketError, .damaged) }

        // A file signed into the catalog under another add-on's name is refused too.
        var renamed = entry; renamed.id = "maker.other"
        XCTAssertThrowsError(try AddonMarket.check(addon, against: renamed)) { XCTAssertEqual($0 as? AddonMarketError, .damaged) }
    }

    func testOfficialCopiesAreMarkedAndAFileCopyIsNot() throws {
        let store = AddonStore(try BooruStore())
        let data = file(Self.translations)
        let official = try Addon.decode(data)
        try store.install(official.addon, digest: official.digest, official: true)
        let entry = try JSONDecoder().decode(AddonListing.self, from: JSONSerialization.data(withJSONObject: listing(data)))
        XCTAssertEqual(try store.installed().first?.official, true)
        XCTAssertEqual(AddonListingState(entry, installed: try store.installed().first), .installed)

        var newer = entry; newer.version = "1.1.0"; newer.sha256 = String(repeating: "a", count: 64)
        XCTAssertEqual(AddonListingState(newer, installed: try store.installed().first), .update)

        let copy = try Addon.decode(file(Self.translations, extra: ["summary": ["en": "Edited"]]))
        try store.install(copy.addon, digest: copy.digest)
        XCTAssertEqual(try store.installed().first?.official, false, "A file opened by hand replaces the official mark")
        XCTAssertEqual(AddonListingState(entry, installed: try store.installed().first), .fromFile)
        XCTAssertEqual(AddonListingState(entry, installed: nil), .get)
    }

    func testThePublishedCatalogInTheDocsFolderVerifiesWithTheAppKey() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/addons/market/dist/v1")
        let data = try? Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        try XCTSkipIf(data == nil, "The published catalog is local only")
        let catalog = try AddonMarket.open(try XCTUnwrap(data), key: AddonMarket.live.publicKey)
        XCTAssertFalse(catalog.addons.isEmpty)
        for entry in catalog.addons {
            XCTAssertNoThrow(try AddonMarket.check(try Data(contentsOf: folder.appendingPathComponent(entry.path)), against: entry), entry.id)
        }
    }

    // MARK: - Modes and grades

    func testComicsAndImageAddonsStayApart() throws {
        XCTAssertThrowsError(try Addon.decode(file(Self.translations, mode: "both"))) { XCTAssertEqual($0 as? AddonError, .invalid("mode")) }
        var noMode = try JSONSerialization.jsonObject(with: file(Self.translations)) as! [String: Any]
        noMode["mode"] = nil
        XCTAssertThrowsError(try Addon.decode(JSONSerialization.data(withJSONObject: noMode))) { XCTAssertEqual($0 as? AddonError, .invalid("mode")) }
        XCTAssertThrowsError(try Addon.decode(file(Self.track, mode: "comics"))) { XCTAssertEqual($0 as? AddonError, .invalid("learningTrack")) }
        var game = ChallengeDefinition.croquis(); game.id = "sketch"
        XCTAssertThrowsError(try Addon.decode(file(["challenges": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(game))]], mode: "comics"))) {
            XCTAssertEqual($0 as? AddonError, .invalid("challenges"))
        }
        XCTAssertThrowsError(try Addon.decode(file(["searchTags": ["images": ["exclude": ["gore"]]]], mode: "comics"))) { XCTAssertEqual($0 as? AddonError, .invalid("searchTags.images")) }
        XCTAssertThrowsError(try Addon.decode(file(["searchTags": ["comics": ["exclude": ["tag:gore"]]]]))) { XCTAssertEqual($0 as? AddonError, .invalid("searchTags.comics")) }

        let comics = try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["character:reimu_hakurei": "하쿠레이 레이무"]], "searchTags": ["comics": ["exclude": ["female:guro"]]]],
                                           id: "maker.comics", mode: "comics")).addon
        let images = try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": ["reimu_hakurei": "레이무"]]], id: "maker.images")).addon
        let effects = AddonEffects([InstalledAddon(addon: comics, enabled: true, installed: .now, digest: ""), InstalledAddon(addon: images, enabled: true, installed: .now, digest: "")])
        XCTAssertEqual(effects.translation("character:reimu hakurei", mode: .comics), "하쿠레이 레이무")
        XCTAssertEqual(effects.translation("reimu_hakurei", mode: .images), "레이무")
        XCTAssertNil(effects.translation("hakurei", mode: .comics))
        XCTAssertEqual(effects.comicsExclude, ["female:guro"])
        XCTAssertEqual(effects.enabledCount(.comics), 1)
        XCTAssertEqual(effects.enabledCount(.images), 1)
        XCTAssertEqual(AddonMode(AppMode.manga), .comics)
        XCTAssertEqual(AddonMode(TasteMode.booru), .images)
    }

    func testCatalogEntriesCarryTheirModeAndGrade() throws {
        let data = file(Self.translations)
        var entry = try JSONDecoder().decode(AddonListing.self, from: JSONSerialization.data(withJSONObject: listing(data)))
        XCTAssertEqual(entry.addonGrade, .recommended)
        entry.grade = "unheard-of"
        XCTAssertEqual(entry.addonGrade, .optional, "An unknown grade is shown as optional")
        entry.grade = nil
        XCTAssertEqual(entry.addonGrade, .optional)
        XCTAssertEqual(AddonGrade.allCases, [.recommended, .suggested, .optional], "The list shows grades in this order")
        XCTAssertNoThrow(try AddonMarket.check(data, against: entry))
        entry.mode = .comics
        XCTAssertThrowsError(try AddonMarket.check(data, against: entry), "A file must be for the mode the list names") { XCTAssertEqual($0 as? AddonMarketError, .damaged) }
        var missing = listing(data); missing["mode"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(AddonListing.self, from: JSONSerialization.data(withJSONObject: missing)), "An entry with no mode is left out")
    }

    // MARK: - Comics tag names and searches

    private func comicsTranslations() throws -> AddonEffects {
        let addon = try Addon.decode(file(["tagTranslations": ["language": "ko", "entries": [
            "character:teitoku": "제독", "tag:big_breasts": "큰 가슴", "tag:glasses": "안경", "series:kantai_collection": "함대 컬렉션", "nakadashi": "질내 사정"
        ]]], id: "maker.comics", mode: "comics")).addon
        return AddonEffects([InstalledAddon(addon: addon, enabled: true, installed: .now, digest: "")])
    }

    func testFemaleAndMaleTagsUseTheirGeneralTranslation() throws {
        let effects = try comicsTranslations()
        XCTAssertEqual(effects.translation("female:big breasts", mode: .comics), "큰 가슴", "female: falls back to the tag: name")
        XCTAssertEqual(effects.translation("male:glasses", mode: .comics), "안경")
        XCTAssertEqual(effects.translation("mixed:big_breasts", mode: .comics), "큰 가슴")
        XCTAssertEqual(effects.translation("big breasts", mode: .comics), "큰 가슴", "A tag with no namespace finds its tag: name")
        XCTAssertEqual(effects.translation("female:nakadashi", mode: .comics), "질내 사정", "A translation with no namespace still serves")
        XCTAssertNil(effects.translation("character:glasses", mode: .comics), "Only general namespaces borrow the tag: name")
        XCTAssertEqual(effects.translation("character:teitoku", mode: .comics), "제독")
    }

    func testTranslatedNamesAreSuggestedAndSearchedAsTheirTags() throws {
        let effects = try comicsTranslations()
        XCTAssertEqual(effects.tags(matching: "제", mode: .comics).map(\.tag), ["character:teitoku"])
        XCTAssertEqual(effects.tags(matching: "가슴", mode: .comics).map(\.tag), ["tag:big_breasts"], "Korean words match inside a name too")
        XCTAssertEqual(effects.tags(matching: "함대", mode: .comics).first?.words, "함대 컬렉션")
        XCTAssertTrue(effects.tags(matching: "제", mode: .images).isEmpty, "Comics names are not suggested in Image Mode")

        XCTAssertEqual(effects.searchQuery("제독 -안경", mode: .comics), "character:teitoku -tag:glasses")
        XCTAssertEqual(effects.searchQuery("큰 가슴 함대 컬렉션 english", mode: .comics), "tag:big_breasts series:kantai_collection english", "Names of several words are found")
        XCTAssertEqual(effects.searchQuery("glasses", mode: .comics), "glasses", "English searches stay as typed")
        XCTAssertEqual(effects.searchQuery("모르는말", mode: .comics), "모르는말")
        XCTAssertEqual(effects.searchQuery("제독", mode: .images), "제독")

        let completion = try XCTUnwrap(AddonSearchCompletion("language:korean -제"))
        XCTAssertTrue(completion.excluded)
        XCTAssertEqual(completion.term, "제")
        XCTAssertEqual(completion.inserting("character:teitoku"), "language:korean -character:teitoku ")
        XCTAssertNil(AddonSearchCompletion("제독 "))
    }

    /// The official Korean comics names, as published, name the tags a work page shows, gender tags included.
    func testTheOfficialComicsNamesReachTheWorkPage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/addons/market/official/comics-tags-ko.tegnaladdon")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path), "The official files are local only")
        let (addon, digest) = try Addon.read(url)
        XCTAssertFalse(addon.contents.tagTranslations!.entries.keys.contains { $0.split(separator: ":").count > 2 }, "No key carries two namespaces")
        AddonRuntime.shared.apply(AddonEffects([InstalledAddon(addon: addon, enabled: true, installed: .now, digest: digest)]))
        let tags = ArtworkTagGroup.make(tags: ["female:big breasts", "male:sole male", "character:reimu hakurei", "series:touhou project", "tag:full color"], mode: .comics)
            .flatMap(\.tags)
        for tag in tags { XCTAssertNotNil(tag.original, tag.query + " is shown in Korean") }
        XCTAssertEqual(AddonRuntime.shared.effects.tags(matching: "거유", mode: .comics).first?.tag, "female:big_breasts", "A gender tag is suggested with its own namespace")
    }
}
