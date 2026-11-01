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
        ReaderPreferences.defaults.removeObject(forKey: LibrarySavePreferences.defaultFolderKey)
        ReaderPreferences.defaults.removeObject(forKey: LibrarySavePreferences.rulesEnabledKey)
    }

    override func tearDown() {
        ReaderPreferences.defaults.removeObject(forKey: LibrarySavePreferences.defaultFolderKey)
        ReaderPreferences.defaults.removeObject(forKey: LibrarySavePreferences.rulesEnabledKey)
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
        XCTAssertEqual(try database.matchingWorkCount(WorkQuery("", excluding: "language:japanese")), 0)
    }

    func testFolderFilledFromATagKeepsOtherFoldersAndLeavesUnfiled() throws {
        let favorites = try database.createFolder(name: "Favorites")
        try save(1)
        try database.addWork(galleryId: 1, folderID: favorites.id!)
        try save(2)
        try save(3, language: "japanese")
        let korean = try database.createFolder(name: "Korean")
        XCTAssertEqual(try database.matchingWorkCount(WorkQuery("language:korean")), 1)
        XCTAssertEqual(try database.matchingWorkCount(WorkQuery("language:korean"), includingOtherFolders: true), 2)
        try database.addMatchingWorks(WorkQuery("language:korean"), toFolder: korean.id!, includingOtherFolders: true)
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
        try database.addMatchingWorks(WorkQuery("language:korean"), toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Favorites"])
        XCTAssertEqual(try folderNames(2), ["Korean"])
    }

    func testRuleFilesWorksFromTheDefaultSaveFolderAndKeepsThemThere() throws {
        let inbox = try database.createFolder(name: "Inbox")
        ReaderPreferences.defaults.set(Int(inbox.id!), forKey: LibrarySavePreferences.defaultFolderKey)
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

        let rule = try XCTUnwrap(database.folderRules().first?.rule)
        try database.saveFolderRule(id: rule.id, folderID: korean.id!, query: rule.query, excluded: "", includesOtherFolders: true)
        _ = try database.upsertWork(galleryId: 2, folderId: favorites.id, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(2), ["Favorites", "Korean"])
    }

    func testFillingAFolderTakesWorksFromTheDefaultSaveFolderButNotAnother() throws {
        let inbox = try database.createFolder(name: "Inbox"), kept = try database.createFolder(name: "Kept")
        ReaderPreferences.defaults.set(Int(inbox.id!), forKey: LibrarySavePreferences.defaultFolderKey)
        try save(1)
        try save(2)
        try database.addWork(galleryId: 2, folderID: kept.id!)
        let korean = try database.createFolder(name: "Korean")
        XCTAssertEqual(try database.matchingWorkCount(WorkQuery("language:korean")), 1)
        try database.addMatchingWorks(WorkQuery("language:korean"), toFolder: korean.id!)
        XCTAssertEqual(try folderNames(1), ["Inbox", "Korean"])
        XCTAssertEqual(try folderNames(2), ["Inbox", "Kept"], "A work also placed in another folder was already sorted")
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
        try LibraryMaintenance.mergeComics(group, keeping: 1, database: database)
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
        ReaderPreferences.defaults.set(Int(favorites.id!), forKey: LibrarySavePreferences.defaultFolderKey)
        XCTAssertEqual(try database.defaultSaveFolder().name, "Favorites")
        try database.deleteFolder(id: favorites.id!)
        XCTAssertEqual(try database.defaultSaveFolder().name, "미분류")
    }

    func testRemovedBookmarkReturnsToItsFoldersAndNote() throws {
        let first = try database.createFolder(name: "First"), second = try database.createFolder(name: "Second")
        ReaderPreferences.defaults.set(Int(first.id!), forKey: LibrarySavePreferences.defaultFolderKey)
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
        ReaderPreferences.defaults.set(Int(first.id!), forKey: LibrarySavePreferences.defaultFolderKey)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        try database.deleteFolder(id: first.id!)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        XCTAssertEqual(try folderNames(1), ["미분류"])
    }

    func testBackupCarriesRules() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler", includesOtherFolders: true)
        let backup = try MangaBackup.capture(database)
        try backup.validate()
        let restored = AppEnvironment.preview()
        try restored.database.dbWriter.write { try backup.restore(in: $0) }
        let rules = try restored.database.folderRules()
        XCTAssertEqual(rules.map(\.rule.query), ["language:korean"])
        XCTAssertEqual(rules.map(\.rule.excluded), ["tag:spoiler"])
        XCTAssertEqual(rules.map(\.rule.includesOtherFolders), [true])
        XCTAssertEqual(rules.map(\.folder.name), ["Korean"])
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
        ReaderPreferences.defaults.set(Int(favorites.id!), forKey: LibrarySavePreferences.defaultFolderKey)
        _ = try ContentBookmarkAction.toggle(id: 1, gallery: gallery(1), env: env)
        try database.moveWorkToFolder(galleryId: 1, targetFolderId: other.id!, currentFolderId: env.savedFolders[1])
        XCTAssertEqual(try folderNames(1), ["Other", "Korean"])
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

private struct FlowProbe: View {
    let width: CGFloat
    let reserved: CGFloat
    var body: some View {
        Color.clear.frame(width: width, height: 20).layoutValue(key: FlowReservedWidth.self, value: reserved)
    }
}
