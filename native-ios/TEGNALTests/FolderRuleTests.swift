import XCTest
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
        try database.setWork(galleryId: 1, folderID: favorites.id!, included: true)
        try save(2)
        try save(3, language: "japanese")
        let korean = try database.createFolder(name: "Korean")
        try database.addMatchingWorks(WorkQuery("language:korean"), toFolder: korean.id!)
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

    func testRuleKeepsTheDefaultSaveFolderAlongsideItsOwn() throws {
        let favorites = try database.createFolder(name: "Favorites")
        ReaderPreferences.defaults.set(Int(favorites.id!), forKey: LibrarySavePreferences.defaultFolderKey)
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        try save(1)
        XCTAssertEqual(try folderNames(1), ["Favorites", "Korean"])
    }

    func testRuleRunsWhenTagsArriveButNeverRefilesAWorkTakenOut() throws {
        let korean = try database.createFolder(name: "Korean")
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "")
        _ = try database.upsertWork(galleryId: 1, folderId: try database.defaultSaveFolder().id)
        XCTAssertEqual(try folderNames(1), ["미분류"])
        _ = try database.upsertWork(galleryId: 1, language: "korean", tags: "tag:full color")
        XCTAssertEqual(try folderNames(1), ["Korean"])

        let other = try database.createFolder(name: "Other")
        try database.setWork(galleryId: 1, folderID: other.id!, included: true)
        try database.setWork(galleryId: 1, folderID: korean.id!, included: false)
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

    func testAWorkAlwaysKeepsOneFolder() throws {
        try save(1)
        let only = try database.folderIDs(galleryId: 1)[0]
        try database.setWork(galleryId: 1, folderID: only, included: false)
        XCTAssertEqual(try database.folderIDs(galleryId: 1), [only])
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
        try database.setWork(galleryId: 1, folderID: second.id!, included: true)
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
        try database.saveFolderRule(folderID: korean.id!, query: "language:korean", excluded: "tag:spoiler")
        let backup = try MangaBackup.capture(database)
        try backup.validate()
        let restored = AppEnvironment.preview()
        try restored.database.dbWriter.write { try backup.restore(in: $0) }
        let rules = try restored.database.folderRules()
        XCTAssertEqual(rules.map(\.rule.query), ["language:korean"])
        XCTAssertEqual(rules.map(\.rule.excluded), ["tag:spoiler"])
        XCTAssertEqual(rules.map(\.folder.name), ["Korean"])
    }

    func testArtistQueriesAreRecognized() {
        XCTAssertTrue(ArtistBrowsing.matches("artist:some_artist"))
        XCTAssertFalse(ArtistBrowsing.matches("artist:a female:b"))
        XCTAssertFalse(ArtistBrowsing.matches("language:korean"))
    }

    func testAddingToAFolderDoesNotChangeNotifications() {
        XCTAssertNil(WorkSaveFeedback(.removed(.comics), galleryID: 1).galleryID)
        XCTAssertEqual(WorkSaveFeedback(.added(.comics), galleryID: 1).galleryID, 1)
        XCTAssertNil(WorkSaveFeedback(.added(.booru), galleryID: 1).galleryID)
    }
}
