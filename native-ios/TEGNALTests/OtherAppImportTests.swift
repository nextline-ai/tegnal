import XCTest
import GRDB
@testable import TEGNAL

@MainActor final class OtherAppImportTests: XCTestCase {
    private var env: AppEnvironment!
    private var database: AppDatabase { env.database }
    private var cleanup: [URL] = []

    override func setUp() {
        super.setUp()
        env = AppEnvironment.preview()
    }

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        super.tearDown()
    }

    private func temporary(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
        cleanup.append(url)
        return url
    }

    // MARK: Viewer database export

    private func viewerExport() throws -> URL {
        let url = temporary(".db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            let columns = "GID INTEGER PRIMARY KEY, TOKEN TEXT, TITLE TEXT, TITLE_JPN TEXT, THUMB TEXT, CATEGORY INTEGER, POSTED TEXT, UPLOADER TEXT, RATING REAL, SIMPLE_LANGUAGE TEXT"
            try db.execute(sql: "CREATE TABLE LOCAL_FAVORITES (\(columns), TIME INTEGER)")
            try db.execute(sql: "CREATE TABLE DOWNLOADS (\(columns), STATE INTEGER, LEGACY INTEGER, TIME INTEGER, LABEL TEXT)")
            try db.execute(sql: "CREATE TABLE DOWNLOAD_LABELS (_id INTEGER PRIMARY KEY, LABEL TEXT, TIME INTEGER)")
            try db.execute(sql: "CREATE TABLE HISTORY (\(columns), MODE INTEGER, TIME INTEGER)")
            try db.execute(sql: "INSERT INTO LOCAL_FAVORITES VALUES (2000001, '0123456789', 'First &amp; Last', NULL, NULL, 2, '2024-01-02 03:04', 'u', 4.5, 'KO', 1700000000000)")
            try db.execute(sql: "INSERT INTO LOCAL_FAVORITES VALUES (2000002, 'not-a-key', NULL, 'Second', NULL, 512, NULL, NULL, 0, NULL, 1700000001000)")
            try db.execute(sql: "INSERT INTO LOCAL_FAVORITES VALUES (0, NULL, 'Broken', NULL, NULL, 2, NULL, NULL, 0, NULL, 0)")
            try db.execute(sql: "INSERT INTO DOWNLOAD_LABELS VALUES (1, 'Later', 0)")
            try db.execute(sql: "INSERT INTO DOWNLOADS VALUES (2000003, 'abcdefabcd', 'Third', NULL, NULL, 4, NULL, NULL, 0, 'EN', 3, 0, 1700000002000, 'Later')")
            try db.execute(sql: "INSERT INTO DOWNLOADS VALUES (2000001, '0123456789', 'First', NULL, NULL, 2, NULL, NULL, 0, 'KO', 3, 0, 1700000003000, NULL)")
            try db.execute(sql: "INSERT INTO HISTORY VALUES (2000004, 'fedcbafedc', 'Read once', NULL, NULL, 8, NULL, NULL, 0, NULL, 0, 1700000004000)")
        }
        return url
    }

    func testViewerDatabaseExportBecomesFoldersAndHistory() throws {
        let library = try OtherAppImport.readDatabase(at: try viewerExport().path)
        XCTAssertEqual(library.format, .viewerDatabase)
        XCTAssertEqual(library.shelves.map(\.name), [L10n.text("Favorites"), L10n.text("Downloads"), "Later"])
        XCTAssertEqual(library.shelves[0].entries.map(\.id), [2000002, 2000001])
        XCTAssertEqual(library.skipped, 1)
        let first = try XCTUnwrap(library.shelves[0].entries.first { $0.id == 2000001 })
        XCTAssertEqual(first.key, "0123456789")
        XCTAssertEqual(first.title, "First & Last")
        XCTAssertEqual(first.type, "doujinshi")
        XCTAssertEqual(first.language, "korean")
        XCTAssertNotNil(first.publishedAt)
        let second = try XCTUnwrap(library.shelves[0].entries.first { $0.id == 2000002 })
        XCTAssertNil(second.key)
        XCTAssertEqual(second.title, "Second")
        XCTAssertEqual(second.type, "western")
        XCTAssertEqual(library.history.map(\.id), [2000004])
        XCTAssertEqual(library.workCount, 3)

        let result = try database.importOtherApp(library, options: .init())
        XCTAssertEqual(result, OtherAppImportResult(added: 3, existing: 0, folders: 3))
        XCTAssertNil(try database.getWork(galleryId: 2000004))
        XCTAssertEqual(try database.getWork(galleryId: 2000001)?.title, "First & Last")
        XCTAssertEqual(try database.getWork(galleryId: 2000001)?.metadataSource, "remote")
        XCTAssertEqual(GalleryKeys.shared.key(for: 2000003), "abcdefabcd")
        let later = try XCTUnwrap(database.listFolders().first { $0.name == "Later" }?.id)
        XCTAssertEqual(try database.galleryIDs(inFolder: later), [2000003])

        // Importing again adds nothing new; history comes in only when asked for, in its own folder.
        let again = try database.importOtherApp(library, options: .init(includeHistory: true))
        XCTAssertEqual(again, OtherAppImportResult(added: 1, existing: 3, folders: 1))
        let history = try XCTUnwrap(database.listFolders().first { $0.name == L10n.text("Reading History") }?.id)
        XCTAssertEqual(try database.galleryIDs(inFolder: history), [2000004])
    }

    func testOtherDatabasesPointToTheirOwnImports() throws {
        let url = temporary(".db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE BookmarkArticle (Id INTEGER)") }
        XCTAssertThrowsError(try OtherAppImport.readDatabase(at: url.path)) { XCTAssertEqual($0 as? OtherAppImportError, .mangaViewerDatabase) }
        let image = temporary(".db")
        try DatabaseQueue(path: image.path).write { try $0.execute(sql: "CREATE TABLE BooruItem (id INTEGER)") }
        XCTAssertThrowsError(try OtherAppImport.readDatabase(at: image.path)) { XCTAssertEqual($0 as? OtherAppImportError, .imageAppBackup) }
    }

    func testAViewersOwnDatabasesAreRecognizedByWhatTheyHold() throws {
        // Whatever the file is called, a bookmark backup is known by its bookmark table.
        let bookmarks = temporary(".backup")
        try DatabaseQueue(path: bookmarks.path).write { try $0.execute(sql: "CREATE TABLE BookmarkArticle (Id INTEGER)") }
        XCTAssertEqual(try ViewerDatabase.recognize(bookmarks), .bookmarks)
        // Any other database, and any file that is not one, goes on to the other readers.
        let other = temporary(".db")
        try DatabaseQueue(path: other.path).write { try $0.execute(sql: "CREATE TABLE Unrelated (id INTEGER)") }
        XCTAssertNil(try ViewerDatabase.recognize(other))
        let text = temporary(".txt")
        try Data("not a database".utf8).write(to: text)
        XCTAssertNil(try ViewerDatabase.recognize(text))
    }

    // MARK: App data export

    func testAppDataExportHistoryKeepsTagsAndKeys() throws {
        let body: [String: Any] = [
            "gid": 3000001, "token": "1111111111", "title": "Exported", "category": "Artist CG", "language": "Japanese",
            "galleryUrl": "https://catalog.example/g/3000001/1111111111/", "publishTime": "2023-05-06 07:08",
            "tags": ["artist": [["tagData": ["namespace": "artist", "_key": "someone"]]],
                     "parody": [["tagData": ["namespace": "parody", "_key": "original"]]],
                     "female": [["tagData": ["namespace": "female", "_key": "glasses"]]]],
        ]
        let rows: [[String: Any]] = [
            ["gid": 3000001, "jsonBody": String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self), "lastReadTime": "2024-02-03 04:05:06.000"],
            ["gid": 3000002, "jsonBody": "not json", "lastReadTime": ""],
        ]
        let records: [[String: Any]] = [
            ["id": -1, "shareCode": "", "identificationCode": "", "type": 4, "version": "1.0.0", "config": "[]", "ctime": 0],
            ["id": -1, "shareCode": "", "identificationCode": "", "type": 5, "version": "1.0.0",
             "config": String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self), "ctime": 0],
        ]
        let library = try OtherAppImport.parse(JSONSerialization.data(withJSONObject: records))
        XCTAssertEqual(library.format, .settingsExport)
        XCTAssertEqual(library.workCount, 0)
        XCTAssertEqual(library.skipped, 1)
        let entry = try XCTUnwrap(library.history.first)
        XCTAssertEqual(entry.id, 3000001)
        XCTAssertEqual(entry.key, "1111111111")
        XCTAssertEqual(entry.type, "artistcg")
        XCTAssertEqual(entry.language, "japanese")
        XCTAssertEqual(entry.artists, ["someone"])
        XCTAssertEqual(Set(entry.tags), ["series:original", "female:glasses"])
        XCTAssertNotNil(entry.savedAt)

        let result = try database.importOtherApp(library, options: .init(includeHistory: true))
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(try database.getWork(galleryId: 3000001)?.artists, "someone")
    }

    // MARK: Download folders

    func testDownloadFolderManifestsAreFound() throws {
        let root = temporary("")
        let folder = root.appendingPathComponent("Downloads/3000005", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "gid": "3000005", "host": "Keyed", "token": "2222222222", "title": "Downloaded", "category": "Asian Porn",
            "language": "Korean", "uploader": "u", "postedDate": 700_000_000.0, "rating": 4,
            "pages": [1, "1.jpg"],
            "tags": [["rawNamespace": "female", "contents": [["rawNamespace": "female", "text": "maid", "isVotedUp": false, "isVotedDown": false]]],
                     ["rawNamespace": "language", "contents": [["rawNamespace": "language", "text": "translated", "isVotedUp": false, "isVotedDown": false]]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("Downloads/.queue.json"))
        let library = try OtherAppImport.readDownloadFolder(root)
        XCTAssertEqual(library.format, .downloadFolder)
        let entry = try XCTUnwrap(library.shelves.first?.entries.first)
        XCTAssertEqual(entry.id, 3000005)
        XCTAssertEqual(entry.key, "2222222222")
        XCTAssertEqual(entry.type, "photo")
        XCTAssertEqual(entry.language, "korean")
        XCTAssertEqual(entry.tags, ["female:maid"])
        XCTAssertNotNil(entry.publishedAt)
    }

    // MARK: Manga reader backup

    private func field(_ number: Int, _ wire: Int) -> [UInt8] { varint(UInt64(number << 3 | wire)) }
    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7F); value >>= 7; if value != 0 { byte |= 0x80 }; bytes.append(byte) } while value != 0
        return bytes
    }
    private func text(_ number: Int, _ value: String) -> [UInt8] { message(number, Array(value.utf8)) }
    private func message(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { field(number, 2) + varint(UInt64(bytes.count)) + bytes }
    private func number(_ number: Int, _ value: UInt64) -> [UInt8] { field(number, 0) + varint(value) }

    private func gzip(_ bytes: [UInt8]) throws -> Data {
        let deflated = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
        let size = UInt32(bytes.count)
        return Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]) + deflated + Data([0, 0, 0, 0]) + Data([UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)])
    }

    func testReaderBackupKeepsOnlyCatalogWorksByCategory() throws {
        let keyed = number(1, 6902) + text(2, "/g/4000001/3333333333/") + text(3, "Keyed work") + text(4, "Artist A") + text(5, "Artist A")
            + number(13, 1_700_000_000_000) + number(17, 1) + number(100, 1)
        let indexed = number(1, 77) + text(2, "/galleries/4000002.html") + text(3, "Indexed work")
            + message(17, varint(2)) // packed categories
        let ordinary = number(1, 55) + text(2, "/manga/some-series-123456.html") + text(3, "Not a catalog work")
        let removed = number(1, 6902) + text(2, "/g/4000003/4444444444/") + number(100, 0)
        let backup = message(1, keyed) + message(1, indexed) + message(1, ordinary) + message(1, removed)
            + message(2, text(1, "Reading") + number(2, 1)) + message(2, text(1, "Done") + number(2, 2))
            + message(101, text(1, "Source") + number(2, 6902))
        let library = try OtherAppImport.parse(gzip(backup), connectedHosts: [])
        XCTAssertEqual(library.format, .readerBackup)
        XCTAssertEqual(library.shelves.map(\.name), ["Reading", "Done"])
        XCTAssertEqual(library.shelves[0].entries.first?.id, 4000001)
        XCTAssertEqual(library.shelves[0].entries.first?.key, "3333333333")
        XCTAssertEqual(library.shelves[0].entries.first?.artists, ["Artist A"])
        XCTAssertEqual(library.shelves[1].entries.first?.id, 4000002)
        XCTAssertEqual(library.skipped, 1)
        XCTAssertEqual(library.workCount, 2)
    }

    func testReaderBackupReadsTitledAddressesOnlyFromTheIndexedSource() throws {
        let titled = number(1, 9001) + text(2, "/doujinshi/some-title-4000010.html") + text(3, "Titled")
        let elsewhere = number(1, 9002) + text(2, "/doujinshi/some-title-4000011.html") + text(3, "Elsewhere")
        let backup = message(1, titled) + message(1, elsewhere)
            + message(101, text(1, "Index Source") + number(2, 9001)) + message(101, text(1, "Other Source") + number(2, 9002))
        let library = try OtherAppImport.readerBackup(Data(backup), indexedSourceDigests: [OtherAppImport.digest("index source")])
        XCTAssertEqual(library.shelves.first?.entries.map(\.id), [4000010])
        XCTAssertEqual(library.skipped, 1)
        XCTAssertFalse(OtherAppImport.isIndexedSource("Index Source"))
    }

    // MARK: Link lists and bookmarks

    func testBrowserBookmarksKeepFoldersAndIgnoreOtherLinks() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Toolbar</H3>
            <DL><p>
                <DT><A HREF="https://catalog.example/g/5000001/5555555555/" ADD_DATE="1700000000">One</A>
                <DT><H3 ADD_DATE="1700000000">Comics &amp; more</H3>
                <DL><p>
                    <DT><A HREF="https://index.example/galleries/5000002.html" ADD_DATE="1700000001">Two</A>
                    <DT><A HREF="https://news.example/story-5000003.html" ADD_DATE="1700000002">Unrelated</A>
                    <DT><A HREF="https://connected.example/some-title-5000004.html">Connected</A>
                </DL><p>
            </DL><p>
        </DL><p>
        """
        let library = try OtherAppImport.parse(Data(html.utf8), connectedHosts: ["connected.example"])
        XCTAssertEqual(library.format, .linkList)
        XCTAssertEqual(library.shelves.map(\.name), [nil, "Comics & more"])
        XCTAssertEqual(library.shelves[0].entries.map(\.id), [5000001])
        XCTAssertEqual(library.shelves[0].entries.first?.key, "5555555555")
        XCTAssertEqual(library.shelves[1].entries.map(\.id), [5000002, 5000004])
    }

    func testPlainListsOfNumbersAndLinks() throws {
        let numbers = try OtherAppImport.parse(Data("6000001\n6000002, 6000003\n".utf8), connectedHosts: [])
        XCTAssertEqual(numbers.shelves.first?.entries.map(\.id), [6000001, 6000002, 6000003])
        let mixed = try OtherAppImport.parse(Data("see https://index.example/reader/6000004.html and 12345 words".utf8), connectedHosts: [])
        XCTAssertEqual(mixed.shelves.first?.entries.map(\.id), [6000004])
        XCTAssertThrowsError(try OtherAppImport.parse(Data("hello world 2024".utf8), connectedHosts: []))
    }

    // MARK: Image apps

    func testImageBookmarkExportFindsServersFromPostPages() throws {
        let export: [String: Any] = ["version": 1, "date": "2024-01-01T00:00:00.000", "data": [
            ["id": 1, "booruId": 1, "createdAt": "2024-01-02T03:04:05.000", "sourceUrl": "https://img.example/posts/101",
             "thumbnailUrl": "https://cdn.img.example/p/101.jpg", "sampleUrl": "https://cdn.img.example/s/101.jpg",
             "originalUrl": "https://cdn.img.example/o/101.png", "width": 800.0, "height": 600.0, "tags": ["a", "b"], "format": "png", "postId": 101],
            ["id": 2, "booruId": 2, "createdAt": "2024-01-02T03:04:05.000", "sourceUrl": "https://pics.example/index.php?page=post&s=view&id=202",
             "originalUrl": "https://pics.example/images/202.jpg", "tags": ["c"]],
            ["id": 3, "booruId": 3, "createdAt": "2024-01-02T03:04:05.000", "sourceUrl": "https://wall.example/post/show/303/some-tags",
             "originalUrl": "https://wall.example/image/303.jpg", "tags": []],
            ["id": 4, "booruId": 4, "createdAt": "", "sourceUrl": "https://elsewhere.example/art/404", "originalUrl": "https://elsewhere.example/404.jpg"],
        ]]
        let backup = try XCTUnwrap(try AnimeBoxesBackup.parseBookmarks(JSONSerialization.data(withJSONObject: export)))
        XCTAssertEqual(backup.source, .bookmarkExport)
        XCTAssertEqual(backup.servers.map(\.engine), [.danbooru, .gelbooru, .moebooru])
        XCTAssertEqual(backup.favorites.map(\.post.postID), [101, 202, 303])
        XCTAssertEqual(backup.favorites[0].post.width, 800)
        XCTAssertEqual(backup.favorites[0].post.fileExtension, "png")
        XCTAssertEqual(backup.skippedFavorites, 1)

        let store = try BooruStore()
        let result = try store.importAnimeBoxes(backup, options: .init())
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.serversAdded, 3)
        var options = AnimeBoxesImportOptions(); options.folderID = AnimeBoxesBackup.importedFolderID
        let again = try store.importAnimeBoxes(backup, options: options)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.duplicates, 3)
    }

    func testImageAppDatabaseFavoritesTagsAndSearches() throws {
        let url = temporary(".db")
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "CREATE TABLE BooruItem (id INTEGER PRIMARY KEY, thumbnailURL TEXT, sampleURL TEXT, fileURL TEXT, postURL TEXT, mediaType TEXT, isSnatched INTEGER, isFavourite INTEGER)")
            try db.execute(sql: "CREATE TABLE Tag (id INTEGER PRIMARY KEY, name TEXT, tagType TEXT, updatedAt INTEGER)")
            try db.execute(sql: "CREATE TABLE ImageTag (tagID INTEGER, booruItemID INTEGER)")
            try db.execute(sql: "CREATE TABLE SearchHistory (id INTEGER PRIMARY KEY, booruType TEXT, booruName TEXT, searchText TEXT, isFavourite INTEGER, timestamp TEXT)")
            try db.execute(sql: "INSERT INTO BooruItem VALUES (1, 'https://img.example/t/1.jpg', NULL, 'https://img.example/o/1.jpg', 'https://img.example/posts/11', 'image', 0, 1)")
            try db.execute(sql: "INSERT INTO BooruItem VALUES (2, NULL, NULL, 'https://img.example/o/2.jpg', 'https://img.example/posts/12', 'image', 1, 0)")
            try db.execute(sql: "INSERT INTO Tag VALUES (1, 'blue_sky', NULL, NULL)")
            try db.execute(sql: "INSERT INTO ImageTag VALUES (1, 1)")
            try db.execute(sql: "INSERT INTO SearchHistory VALUES (1, 'danbooru', 'x', 'blue_sky', 1, '2024-01-01 00:00:00')")
        }
        let backup = try AnimeBoxesBackup.readDatabase(at: url.path)
        XCTAssertEqual(backup.source, .imageAppDatabase)
        XCTAssertEqual(backup.favorites.map(\.post.postID), [11])
        XCTAssertEqual(backup.favorites.first?.post.tags, ["blue_sky"])
        XCTAssertEqual(backup.history.first?.text, "blue_sky")
        XCTAssertEqual(backup.history.first?.starred, true)
    }
}
