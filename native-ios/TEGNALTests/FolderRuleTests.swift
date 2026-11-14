import XCTest
import SwiftUI
import GRDB
@testable import TEGNAL

@MainActor final class FolderRuleTests: XCTestCase {
    private var env: AppEnvironment!
    private var database: AppDatabase { env.database }

    override func setUp() {
        super.setUp()
        env = AppEnvironment.preview()
        clearPreferences()
    }

    private func clearPreferences() {
        for key in [LibrarySavePreferences.defaultFolderKey, LibrarySavePreferences.legacyDefaultFolderKey, LibrarySavePreferences.rulesEnabledKey] {
            ReaderPreferences.defaults.removeObject(forKey: key)
        }
    }

    private func setDefaultFolder(_ folder: Folder) throws {
        ReaderPreferences.defaults.set(try database.identity(ofFolder: folder.id!), forKey: LibrarySavePreferences.defaultFolderKey)
    }

    private func rule(_ query: String, excluded: String = "", everyFolder: Bool = false) -> FolderRule {
        FolderRule(folder: "", query: query, excluded: excluded, includesOtherFolders: everyFolder ? true : nil)
    }

    override func tearDown() {
        clearPreferences()
        super.tearDown()
    }

    private func gallery(_ id: Int64, language: String = "korean", tags: [String] = ["female:sole female", "tag:full color"]) -> NativeGallery {
        NativeGallery(id: id, title: "Work \(id)", artists: ["Some Artist"], language: language, type: "manga", tags: tags, pages: [])
    }

    private func save(_ id: Int64, language: String = "korean", tags: [String] = ["female:sole female", "tag:full color"]) throws {
        _ = try database.upsertWork(galleryId: id, folderId: try database.defaultSaveFolder().id, title: "Work \(id)", artists: "Some Artist",
                                    language: language, type: "manga", tags: tags.joined(separator: ", "))
    }

    private func ids(_ query: String) throws -> [Int64] {
        try database.listWorks(query: query).map(\.galleryId).sorted()
    }

    private func folderNames(_ id: Int64) throws -> Set<String> {
        let folders = try database.listFolders()
        return Set(try database.folderIDs(galleryId: id).compactMap { folder in folders.first { $0.id == folder }?.name })
    }

    func testSearchReadsFieldsExactlyAndHonorsExclusions() throws {
        try save(1)
        try save(2, language: "japanese", tags: ["female:sole female"])
        try save(3, language: "english", tags: ["female:sole dickgirl"])
        XCTAssertEqual(try ids("language:korean"), [1])
        XCTAssertEqual(try ids("female:sole_female"), [1, 2])
        XCTAssertEqual(try ids("female:sole"), [], "A field value matches one whole tag")
        XCTAssertEqual(try ids("female:sole_female -language:japanese"), [1])
        XCTAssertEqual(try ids("female:sole_female language:japanese"), [2])
        XCTAssertEqual(try ids("sole"), [1, 2, 3], "A plain word still searches every field")
        XCTAssertEqual(try ids("artist:some_artist"), [1, 2, 3])
        XCTAssertEqual(try ids("100%"), [])
    }

    func testExclusionsAloneDoNotCountAsAQuery() throws {
        try save(1)
        XCTAssertTrue(WorkQuery("", excluding: "language:korean").isEmpty)
        XCTAssertEqual(try database.matchingWorkCount(rule("", excluded: "language:japanese")), 0)
    }

    func testFolderFilledFromATagKeepsOtherFoldersAndLeavesUnfiled() throws {
        let favorites = try database.createFolder(name: "Favorites")
        try save(1)
        try database.addWork(galleryId: 1, folderID: favorites.id!)
        try save(2)
        try save(3, language: "japanese")
        let korean = try database.createFolder(name: "Korean")
        XCTAssertEqual(try database.matchingWorkCount(rule("language:korean")), 1)
        XCTAssertEqual(try database.matchingWorkCount(rule("language:korean", everyFolder: true)), 2)
        try database.addMatchingWorks(rule("language:korean", everyFolder: true), toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Favorites", "Korean"])
        XCTAssertEqual(try folderNames(2), ["Korean"])
        XCTAssertEqual(try folderNames(3), ["미분류"])
    }

    func testRuleAppliesToNewSavesAndRespectsItsExclusions() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler")
        try save(1)
        try save(2, tags: ["tag:spoiler"])
        try save(3, language: "japanese")
        XCTAssertEqual(try folderNames(1), ["Korean"])
        XCTAssertEqual(try folderNames(2), ["미분류"])
        XCTAssertEqual(try folderNames(3), ["미분류"])
    }

    func testFillingAFolderLeavesWorksInOtherFoldersByDefault() throws {
        let favorites = try database.createFolder(name: "Favorites")
        try save(1)
        try database.addWork(galleryId: 1, folderID: favorites.id!)
        try save(2)
        let korean = try database.createFolder(name: "Korean")
        try database.addMatchingWorks(rule("language:korean"), toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Favorites"])
        XCTAssertEqual(try folderNames(2), ["Korean"])
    }

    func testRuleFilesWorksFromTheDefaultSaveFolderAndKeepsThemThere() throws {
        let inbox = try database.createFolder(name: "Inbox")
        try setDefaultFolder(inbox)
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Inbox", "Korean"])
        _ = try database.upsertWork(galleryId: 2, folderId: try database.listFolders().first { $0.name == "미분류" }?.id, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(2), ["Korean"], "Unfiled stays a target when another folder is the default")
    }

    func testRuleLeavesOtherFoldersAloneUnlessItIncludesThem() throws {
        let favorites = try database.createFolder(name: "Favorites")
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        _ = try database.upsertWork(galleryId: 1, folderId: favorites.id, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(1), ["Favorites"])

        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "", includesOtherFolders: true)
        _ = try database.upsertWork(galleryId: 2, folderId: favorites.id, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(2), ["Favorites", "Korean"])
    }

    func testFillingAFolderTakesWorksFromTheDefaultSaveFolderButNotAnother() throws {
        let inbox = try database.createFolder(name: "Inbox"), kept = try database.createFolder(name: "Kept")
        try setDefaultFolder(inbox)
        try save(1)
        try save(2)
        try database.addWork(galleryId: 2, folderID: kept.id!)
        let korean = try database.createFolder(name: "Korean")
        XCTAssertEqual(try database.matchingWorkCount(rule("language:korean")), 1)
        try database.addMatchingWorks(rule("language:korean"), toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Inbox", "Korean"])
        XCTAssertEqual(try folderNames(2), ["Inbox", "Kept"], "A work also placed in another folder was already sorted")
    }

    func testMovingRuleTakesANewSaveOutOfTheDefaultSaveFolder() throws {
        let inbox = try database.createFolder(name: "Inbox")
        try setDefaultFolder(inbox)
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "", keepsOriginal: false)
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Korean"], "A moving rule leaves no copy in the folder the work landed in")
        try save(2, language: "japanese")
        XCTAssertEqual(try folderNames(2), ["Inbox"])
    }

    func testCopyingRuleKeepsANewSaveWhereItLanded() throws {
        let inbox = try database.createFolder(name: "Inbox")
        try setDefaultFolder(inbox)
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "", keepsOriginal: true)
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Inbox", "Korean"])
        XCTAssertTrue(FolderRule(folder: "", query: "x").copies, "Rules saved before the choice keep copying")
    }

    func testFirstMovingRuleInFolderOrderTakesTheWorkAndCopiesStillApply() throws {
        let korean = try database.createFolder(name: "Korean"), color = try database.createFolder(name: "Color"), all = try database.createFolder(name: "Everything")
        try database.saveFolderRule(folderID: color.id!, query: "tag:full_color", excluded: "", keepsOriginal: false)
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "", keepsOriginal: false)
        try database.saveFolderRule(folderID: all.id!, query: "language:korean", excluded: "", keepsOriginal: true)
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Korean", "Everything"], "Korean comes before Color in folder order; a copying rule adds too")
    }

    func testFillingWithAMovingRuleTakesWorksOutOfTheFoldersItLooksIn() throws {
        let favorites = try database.createFolder(name: "Favorites"), kept = try database.createFolder(name: "Kept")
        try save(1)
        try database.addWork(galleryId: 1, folderID: favorites.id!)
        try save(2)
        try database.addWork(galleryId: 2, folderID: kept.id!)
        try save(3)
        let korean = try database.createFolder(name: "Korean")
        let favoritesID = try database.identity(ofFolder: favorites.id!)
        var moving = FolderRule(folder: try database.identity(ofFolder: korean.id!), query: "language:korean", sources: [favoritesID], keepsOriginal: false)
        XCTAssertEqual(try database.matchingWorkCount(moving), 1)
        XCTAssertEqual(try database.matchingWorkCountElsewhere(moving), 2, "Kept and Unfiled match but are not looked in")
        try database.addMatchingWorks(moving, toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Korean"])
        XCTAssertEqual(try folderNames(2), ["Kept"])
        XCTAssertEqual(try folderNames(3), ["미분류"])
        moving.includesOtherFolders = true
        XCTAssertEqual(try database.matchingWorkCountElsewhere(moving), 0)
        try database.addMatchingWorks(moving, toFolder: korean.id!)
        XCTAssertEqual(try folderNames(2), ["Korean"])
        XCTAssertEqual(try folderNames(3), ["Korean"])
    }

    func testEveryRuleSeesAWorkArrivingInUnfiled() throws {
        let korean = try database.createFolder(name: "Korean"), color = try database.createFolder(name: "Color")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        try database.saveFolderRule(folderID: color.id!, query: "tag:full_color", excluded: "")
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Korean", "Color"])
    }

    func testRulesSavedBeforeTheOptionStillLoadAsUnfiledOnly() throws {
        let saved = #"[{"id":"old","folder":"unsorted","query":"language:korean","excluded":""}]"#
        let rules = try JSONDecoder().decode([FolderRule].self, from: Data(saved.utf8))
        XCTAssertEqual(rules.map(\.query), ["language:korean"])
        XCTAssertNil(rules[0].includesOtherFolders)
    }

    func testViewerImportFilesOnlyWorksArrivingUnfiled() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        try database.upsertCatalogBatch([1, 2].map { CatalogWork(id: $0, language: "korean", tags: "tag:full color") })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("rules_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
            CREATE TABLE BookmarkGroup (Id INTEGER PRIMARY KEY, Name TEXT, Description TEXT, Color INTEGER, Gorder INTEGER);
            CREATE TABLE BookmarkArticle (Id INTEGER PRIMARY KEY, Article TEXT, DateTime TEXT, GroupId INTEGER);
            INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (1, 'violet_default', 1), (2, 'Kept', 2);
            INSERT INTO BookmarkArticle (Id, Article, GroupId, DateTime) VALUES (1, '1', 1, '2024-01-01'), (2, '2', 2, '2024-01-02');
            """)
        }
        _ = try MangaViewerImportService(appDb: database).importUserDb(path: path)
        XCTAssertEqual(try folderNames(1), ["Korean"])
        XCTAssertEqual(try folderNames(2), ["Kept"])
    }

    func testCatalogTagsRunRulesOnlyWhereTheyWereMissing() throws {
        let kept = try database.createFolder(name: "Kept"), korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        let unfiled = try database.defaultSaveFolder().id
        _ = try database.upsertWork(galleryId: 1, folderId: unfiled)
        _ = try database.upsertWork(galleryId: 2, folderId: kept.id)
        _ = try database.upsertWork(galleryId: 3, folderId: unfiled)
        _ = try database.upsertWork(galleryId: 4, folderId: unfiled, language: "japanese", tags: "tag:old")
        let catalog = { (id: Int64) in CatalogWork(id: id, language: "korean", tags: "tag:full color") }

        XCTAssertEqual(try database.applyCatalogBatchToWorks([catalog(1), catalog(2), catalog(4)]), 3)
        XCTAssertEqual(try folderNames(1), ["Korean"])
        XCTAssertEqual(try folderNames(2), ["Kept"])
        XCTAssertEqual(try folderNames(4), ["미분류"], "A work that already had tags was classified when they arrived")

        try database.upsertCatalogBatch([catalog(3)])
        try database.applyCatalogToWorks()
        XCTAssertEqual(try folderNames(3), ["Korean"])
    }

    func testMergingDuplicatesLeavesUnfiledWhenARealFolderCameAlong() throws {
        let kept = try database.createFolder(name: "Kept")
        _ = try database.upsertWork(galleryId: 1, folderId: try database.defaultSaveFolder().id, title: "Same", artists: "Author", language: "korean", type: "manga")
        _ = try database.upsertWork(galleryId: 2, folderId: kept.id, title: "Same", artists: "Author", language: "korean", type: "manga")
        let group = try XCTUnwrap(LibraryMaintenance.duplicates(works: database.listWorks(), posts: []).first)
        try LibraryMaintenance.mergeComics(group, keeping: try XCTUnwrap(database.getWork(galleryId: 1)?.id), database: database)
        XCTAssertEqual(try folderNames(1), ["Kept"])
    }

    func testAWorkInTwoFoldersIsNotADuplicate() throws {
        let first = try database.createFolder(name: "First"), second = try database.createFolder(name: "Second")
        _ = try database.upsertWork(galleryId: 1, folderId: first.id, title: "Same", artists: "Author", language: "korean", type: "manga")
        try database.addWork(galleryId: 1, folderID: second.id!)
        XCTAssertTrue(LibraryMaintenance.duplicates(works: try database.listWorks(), posts: []).isEmpty)
    }

    func testRuleRunsWhenTagsArriveButNeverRefilesAWorkTakenOut() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        _ = try database.upsertWork(galleryId: 1, folderId: try database.defaultSaveFolder().id)
        XCTAssertEqual(try folderNames(1), ["미분류"])
        _ = try database.upsertWork(galleryId: 1, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(1), ["Korean"])

        let other = try database.createFolder(name: "Other")
        try database.moveWorkToFolder(galleryId: 1, targetFolderId: other.id!, currentFolderId: korean.id!)
        _ = try database.upsertWork(galleryId: 1, language: "korean", tags: "tag:full color, tag:more")
        XCTAssertEqual(try folderNames(1), ["Other"])
    }

    func testDisabledRulesAndDeletedFoldersDoNothing() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        ReaderPreferences.defaults.set(false, forKey: LibrarySavePreferences.rulesEnabledKey)
        try save(1)
        XCTAssertEqual(try folderNames(1), ["미분류"])

        ReaderPreferences.defaults.set(true, forKey: LibrarySavePreferences.rulesEnabledKey)
        try database.deleteFolder(id: korean.id!)
        try save(2)
        XCTAssertEqual(try folderNames(2), ["미분류"])
        XCTAssertTrue(try database.folderRules().isEmpty)
    }

    func testDefaultSaveFolderFallsBackAfterDeletion() throws {
        let favorites = try database.createFolder(name: "Favorites")
        try setDefaultFolder(favorites)
        XCTAssertEqual(try database.defaultSaveFolder().name, "Favorites")
        try database.deleteFolder(id: favorites.id!)
        XCTAssertEqual(try database.defaultSaveFolder().name, "미분류")
    }

    func testRemovedBookmarkReturnsToItsFoldersAndNote() throws {
        let first = try database.createFolder(name: "First"), second = try database.createFolder(name: "Second")
        try setDefaultFolder(first)
        XCTAssertEqual(try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env), .added(.comics))
        try database.addWork(galleryId: 1, folderID: second.id!)
        try database.setNote(galleryId: 1, note: "Keep")
        ReaderPreferences.defaults.removeObject(forKey: LibrarySavePreferences.defaultFolderKey)

        XCTAssertEqual(try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env), .removed(.comics))
        XCTAssertEqual(try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env), .added(.comics))
        XCTAssertEqual(try folderNames(1), ["First", "Second"])
        XCTAssertEqual(try database.getWork(galleryId: 1)?.note, "Keep")
    }

    func testRemovedBookmarkSkipsAFolderDeletedSince() throws {
        let first = try database.createFolder(name: "First")
        try setDefaultFolder(first)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        try database.deleteFolder(id: first.id!)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        XCTAssertEqual(try folderNames(1), ["미분류"])
    }

    func testBackupCarriesRules() throws {
        let korean = try database.createFolder(name: "Korean")
        let favorites = try database.createFolder(name: "Favorites"), off = try database.createFolder(name: "Off")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler", includesOtherFolders: true)
        try database.saveFolderRule(folderID: off.id!, query: "tag:old", excluded: "", sources: [database.identity(ofFolder: favorites.id!)], isEnabled: false)
        let backup = try MangaBackup.capture(database)
        try backup.validate()
        let restored = AppEnvironment.preview()
        try restored.database.dbWriter.write { try backup.restore(in: $0) }
        let rules = try restored.database.folderRules()
        XCTAssertEqual(rules.map(\.rule.query), ["language:korean", "tag:old"])
        XCTAssertEqual(rules.map(\.rule.excluded), ["tag:spoiler", ""])
        XCTAssertEqual(rules.map(\.rule.includesOtherFolders), [true, nil])
        XCTAssertEqual(rules.map(\.folder.name), ["Korean", "Off"])
        XCTAssertEqual(rules.map(\.rule.isActive), [true, false])
        let source = try XCTUnwrap(restored.database.listFolders().first { $0.name == "Favorites" })
        XCTAssertEqual(rules[1].rule.sources, [try restored.database.identity(ofFolder: source.id!)])
    }

    func testArtistQueriesAreRecognized() {
        XCTAssertTrue(ArtistBrowsing.matches("artist:some_artist"))
        XCTAssertFalse(ArtistBrowsing.matches("artist:a female:b"))
        XCTAssertFalse(ArtistBrowsing.matches("language:korean"))
    }

    func testChangingFolderLeavesFoldersARuleAdded() throws {
        let korean = try database.createFolder(name: "Korean"), other = try database.createFolder(name: "Other")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        let favorites = try database.createFolder(name: "Favorites")
        try setDefaultFolder(favorites)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        try database.moveWorkToFolder(galleryId: 1, targetFolderId: other.id!, currentFolderId: env.savedFolders[1])
        XCTAssertEqual(try folderNames(1), ["Other", "Korean"])
    }

    func testAFolderIsMarkedOnlyWhileItsRuleIsOn() throws {
        let korean = try database.createFolder(name: "Korean")
        XCTAssertEqual(try database.listFolders().first { $0.id == korean.id }?.displayName, "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler")
        var listed = try XCTUnwrap(database.listFolders().first { $0.id == korean.id })
        XCTAssertEqual(listed.displayName, "Korean\u{00A0}✦")
        XCTAssertEqual(listed.plainName, "Korean")
        XCTAssertEqual(listed.name, "Korean", "The mark never enters the stored name")

        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler", isEnabled: false)
        listed = try XCTUnwrap(database.listFolders().first { $0.id == korean.id })
        XCTAssertEqual(listed.displayName, "Korean")
        XCTAssertEqual(try database.rule(forFolder: database.identity(ofFolder: korean.id!))?.excluded, "tag:spoiler", "Turning a rule off keeps its tags")
        try save(1)
        XCTAssertEqual(try folderNames(1), ["미분류"])
    }

    func testARuleReadsExactlyTheFoldersItLists() throws {
        let inbox = try database.createFolder(name: "Inbox"), other = try database.createFolder(name: "Other"), korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "", sources: [database.identity(ofFolder: inbox.id!)])
        _ = try database.upsertWork(galleryId: 1, folderId: inbox.id, language: "korean", tags: "tag:full color")
        _ = try database.upsertWork(galleryId: 2, folderId: other.id, language: "korean", tags: "tag:full color")
        try save(3)
        XCTAssertEqual(try folderNames(1), ["Inbox", "Korean"])
        XCTAssertEqual(try folderNames(2), ["Other"])
        XCTAssertEqual(try folderNames(3), ["미분류"], "Unfiled is only read when it is on the list")
        let listed = try XCTUnwrap(database.rule(forFolder: database.identity(ofFolder: korean.id!)))
        XCTAssertEqual(try database.matchingWorkCount(listed), 1)
        XCTAssertTrue(try database.defaultRuleSources().contains("unsorted"))
    }

    func testAMarkedChoiceShowsWhichFoldersAreSmart() throws {
        let korean = try database.createFolder(name: "Korean"), plain = try database.createFolder(name: "Plain")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        let choices = try database.folderChoices()
        XCTAssertTrue(try XCTUnwrap(choices.first { $0.id == (try? database.identity(ofFolder: korean.id!)) }).name.hasSuffix("✦"))
        XCTAssertFalse(try XCTUnwrap(choices.first { $0.id == (try? database.identity(ofFolder: plain.id!)) }).name.hasSuffix("✦"))
        XCTAssertEqual(choices.filter { !$0.canBeSmart }.map(\.id), ["unsorted"])
    }

    func testAWorkMovedByHandStaysInAFolderItDoesNotFit() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        try save(1, language: "japanese")
        try database.moveWorkToFolder(galleryId: 1, targetFolderId: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Korean"])
        try database.fill(database.rule(forFolder: database.identity(ofFolder: korean.id!))!)
        _ = try database.upsertWork(galleryId: 1, language: "japanese", tags: "tag:more")
        XCTAssertEqual(try folderNames(1), ["Korean"], "Rules only ever add, so a person's choice stands")
    }

    func testRulesSharingOneRowSplitIntoARowPerFolder() throws {
        let korean = try database.createFolder(name: "Korean"), color = try database.createFolder(name: "Color")
        let first = try database.identity(ofFolder: korean.id!), second = try database.identity(ofFolder: color.id!)
        let saved = """
        [{"id":"a","folder":"\(first)","query":"language:korean","excluded":"tag:a","includesOtherFolders":true},
         {"id":"b","folder":"\(second)","query":"tag:color","excluded":""},
         {"id":"c","folder":"\(first)","query":"tag:later","excluded":""}]
        """
        try database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO library_order VALUES ('folder_rules', ?)", arguments: [Data(saved.utf8)])
            try AppDatabase.adoptLegacyFolderRules(db)
        }
        XCTAssertEqual(try database.smartRules().map(\.query), ["language:korean", "tag:color"])
        XCTAssertEqual(try database.rule(forFolder: first)?.includesOtherFolders, true)
        XCTAssertNil(try database.dbWriter.read { try Data.fetchOne($0, sql: "SELECT value FROM library_order WHERE key = 'folder_rules'") })
    }

    func testAnOlderDefaultFolderChoiceMovesToItsIdentity() throws {
        let inbox = try database.createFolder(name: "Inbox")
        ReaderPreferences.defaults.set(Int(inbox.id!), forKey: LibrarySavePreferences.legacyDefaultFolderKey)
        _ = try database.identity(ofFolder: inbox.id!)
        XCTAssertEqual(try database.defaultSaveFolder().name, "Inbox")
        XCTAssertEqual(ReaderPreferences.defaults.string(forKey: LibrarySavePreferences.defaultFolderKey), try database.identity(ofFolder: inbox.id!))
        XCTAssertNil(ReaderPreferences.defaults.object(forKey: LibrarySavePreferences.legacyDefaultFolderKey))
    }

    private func images() throws -> (store: BooruStore, server: BooruServer, site: String) {
        let store = try BooruStore(), server = BooruServer.presets[0]
        try store.saveServer(server)
        return (store, server, "site:" + server.canonicalAddress)
    }

    func testImageRulesFileNewFavoritesAndLeaveChoicesAlone() throws {
        let (store, server, site) = try images()
        let scenery = try store.saveFolder(name: "Scenery"), kept = try store.saveFolder(name: "Kept")
        try store.saveRule(FolderRule(folder: scenery, query: "mountain", excluded: "night"))
        XCTAssertEqual(store.folders().first { $0.id == scenery }?.displayName, "Scenery\u{00A0}✦")
        XCTAssertEqual(store.folders().first { $0.id == scenery }?.plainName, "Scenery")

        let matching = BooruFixtureSource.post(1, server: server, tags: ["Mountain", "river"])
        let refused = BooruFixtureSource.post(2, server: server, tags: ["mountain", "night"])
        let chosen = BooruFixtureSource.post(3, server: server, tags: ["mountain"])
        let toggled = BooruFixtureSource.post(4, server: server, tags: ["mountain"])
        try store.saveFavorite(matching)
        try store.saveFavorite(refused)
        try store.saveFavorite(chosen, folderID: kept)
        try store.toggleFavorite(toggled)
        XCTAssertEqual(store.folderID(for: matching), scenery)
        XCTAssertEqual(store.folderID(for: refused), site)
        XCTAssertEqual(store.folderID(for: chosen), kept, "A folder a person picks is never overruled")
        XCTAssertEqual(store.folderID(for: toggled), scenery)

        try store.moveFavorites([matching], folderID: kept)
        try store.saveFavorite(matching)
        XCTAssertEqual(store.folderID(for: matching), kept, "A moved image stays moved when its metadata refreshes")
    }

    func testImageRulesReadChosenFoldersAndFillSavedFavorites() throws {
        let (store, server, site) = try images()
        let inbox = try store.saveFolder(name: "Inbox"), kept = try store.saveFolder(name: "Kept"), scenery = try store.saveFolder(name: "Scenery")
        let inInbox = BooruFixtureSource.post(1, server: server, tags: ["mountain"])
        let inKept = BooruFixtureSource.post(2, server: server, tags: ["mountain"])
        let inSite = BooruFixtureSource.post(3, server: server, tags: ["mountain"])
        try store.saveFavorite(inInbox, folderID: inbox)
        try store.saveFavorite(inKept, folderID: kept)
        try store.saveFavorite(inSite)

        var rule = FolderRule(folder: scenery, query: "mountain", sources: [inbox])
        XCTAssertEqual(try store.matchingCount(rule), 1)
        rule.sources = nil
        XCTAssertEqual(try store.matchingCount(rule), 1, "By default only where favorites land")
        XCTAssertEqual(try store.defaultRuleSources(), [site])
        rule.includesOtherFolders = true
        XCTAssertEqual(try store.matchingCount(rule), 3)
        rule.includesOtherFolders = nil
        rule.sources = [inbox]
        try store.saveRule(rule)
        try store.fill(rule)
        XCTAssertEqual(store.folderID(for: inInbox), scenery)
        XCTAssertEqual(store.folderID(for: inKept), kept)
        XCTAssertEqual(store.folderID(for: inSite), site)

        try store.saveRule(FolderRule(folder: scenery, query: "mountain", isEnabled: false))
        XCTAssertEqual(store.folders().first { $0.id == scenery }?.displayName, "Scenery", "The mark goes with the rule")
        let next = BooruFixtureSource.post(4, server: server, tags: ["mountain"])
        try store.saveFavorite(next)
        XCTAssertEqual(store.folderID(for: next), site)

        try store.deleteFolder(scenery)
        XCTAssertTrue(try store.smartRules().isEmpty)
    }

    func testImageImportsAndBackupsCarrySmartFolders() throws {
        let (store, server, _) = try images()
        let scenery = try store.saveFolder(name: "Scenery")
        try store.saveRule(FolderRule(folder: scenery, query: "scenery", excluded: "night", isEnabled: false))
        try store.saveFavorite(BooruFixtureSource.post(1, server: server))
        let backup = try BooruBackup.decode(store.exportBackup().encoded())
        let restored = try BooruStore()
        try restored.restoreBackup(backup)
        XCTAssertEqual(try restored.rule(forFolder: scenery), FolderRule(folder: scenery, query: "scenery", excluded: "night", isEnabled: false))

        var older = try JSONSerialization.jsonObject(with: store.exportBackup().encoded()) as! [String: Any]
        older.removeValue(forKey: "folderRules")
        XCTAssertNil(try BooruBackup.decode(JSONSerialization.data(withJSONObject: older)).folderRules)
    }

    func testFlowLayoutBreaksLinesAsIfReservedWidthWereUsed() {
        func height(reserved: CGFloat) -> CGFloat {
            let view = FlowLayout(spacing: 0) {
                FlowProbe(width: 60, reserved: reserved)
                FlowProbe(width: 30, reserved: 0)
            }
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 100, height: 500)).height
        }
        XCTAssertEqual(height(reserved: 0), 20)
        XCTAssertEqual(height(reserved: 20), 40)
    }

    func testAddingToAFolderDoesNotChangeNotifications() {
        XCTAssertNil(WorkSaveFeedback(.removed(.comics), galleryID: 1).galleryID)
        XCTAssertEqual(WorkSaveFeedback(.added(.comics), galleryID: 1).galleryID, 1)
        XCTAssertEqual(WorkSaveFeedback(.added(.comics), galleryID: 1, folder: "A").message, L10n.text("Saved to folder '%@'", "A"))
        XCTAssertNil(WorkSaveFeedback(.added(.booru), galleryID: 1).galleryID)
    }
}

private extension AppDatabase {
    func saveFolderRule(folderID: Int64, query: String, excluded: String, includesOtherFolders: Bool? = nil, sources: [String]? = nil, isEnabled: Bool? = nil, keepsOriginal: Bool? = nil) throws {
        try saveRule(FolderRule(folder: identity(ofFolder: folderID), query: query, excluded: excluded, isEnabled: isEnabled, sources: sources, includesOtherFolders: includesOtherFolders, keepsOriginal: keepsOriginal))
    }
}

private struct FlowProbe: View {
    let width: CGFloat
    let reserved: CGFloat
    var body: some View {
        Color.clear.frame(width: width, height: 20).layoutValue(key: FlowReservedWidth.self, value: reserved)
    }
}
