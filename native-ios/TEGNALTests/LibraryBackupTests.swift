import XCTest
import GRDB
@testable import TEGNAL

final class LibraryBackupTests: XCTestCase {
    private func populated() throws -> (AppDatabase, BooruStore, ChallengeDefinition) {
        let comics = try AppDatabase.inMemory(), images = try BooruStore()
        let folder = try comics.createFolder(name: "Reading", color: 0xFF123456, sourceGroupId: 42)
        _ = try comics.upsertWork(galleryId: 1234, folderId: folder.id, title: "Comic", artists: "Artist", tags: "tag:test")
        try comics.setNote(galleryId: 1234, note: "Keep this note")
        try comics.setThumbPage(galleryId: 1234, page: 3)
        _ = try comics.addFavoriteArtist(name: "Artist")
        try comics.recordSearch("saved query"); try comics.toggleSavedSearch("favorite query")
        try comics.dbWriter.write { db in
            try db.execute(sql: "UPDATE works SET thumb_path = '/private/local-cache.jpg' WHERE gallery_id = 1234")
            try db.execute(sql: "UPDATE artists SET note = 'Artist note' WHERE name = 'Artist'")
        }
        let server = BooruServer.presets[0]
        try images.saveServer(server)
        let imageFolder = try images.saveFolder(name: "References")
        try images.setFolderColor(imageFolder, color: 0xFFABCDEF)
        try images.saveFavorite(BooruFixtureSource.post(72, server: server), folderID: imageFolder)
        try images.recordSearch("scenery", serverID: server.id)
        try images.toggleTag("scenery", serverID: server.id, kind: "tag")
        try images.setBlacklist("gore", serverID: server.id)
        let game = ChallengeDefinition.croquis()
        try ChallengeStore(images).save(game)
        return (comics, images, game)
    }

    func testSingleDocumentRestoresBothModesAndChallengesAndIsIdempotent() throws {
        let (source, sourceImages, game) = try populated()
        let url = try LibraryBackup.export(database: source, images: sourceImages)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "tegnal-backup.json")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/private/local-cache.jpg"))
        let backup = try LibraryBackupImport.read(url)
        let destination = try AppDatabase.inMemory(), images = try BooruStore()
        _ = try destination.createFolder(name: "Reading", color: 0xFF000000)
        _ = try destination.upsertWork(galleryId: 9999, title: "Keep local")
        try backup.restore(database: destination, images: images)
        try backup.restore(database: destination, images: images)
        try images.refresh()
        let work = try XCTUnwrap(destination.getWork(galleryId: 1234))
        XCTAssertEqual(work.note, "Keep this note")
        XCTAssertEqual(work.thumbPage, 3)
        XCTAssertEqual(work.folders.map(\.name), ["Reading"])
        XCTAssertEqual(work.folders.first?.color, 0xFF123456)
        XCTAssertEqual(work.folders.first?.sourceGroupId, 42)
        XCTAssertNotNil(try destination.getWork(galleryId: 9999))
        XCTAssertEqual(try destination.listFolders().filter { $0.name == "Reading" }.count, 1)
        XCTAssertEqual(try destination.searchHistory(), ["saved query"])
        XCTAssertEqual(try destination.savedSearches(), ["favorite query"])
        XCTAssertEqual(try destination.dbWriter.read { try String.fetchOne($0, sql: "SELECT note FROM artists WHERE name = 'Artist'") }, "Artist note")
        XCTAssertEqual(images.favoriteIDs.count, 1)
        XCTAssertEqual(images.folders().first?.color, 0xFFABCDEF)
        XCTAssertEqual(images.blacklist(serverID: images.servers[0].id), "gore")
        XCTAssertEqual(try ChallengeStore(images).definitions(), [game])
    }

    func testOlderSeparateBackupsRestoreOnlyTheirOwnMode() throws {
        let (_, sourceImages, _) = try populated()
        // The actual pre-unification shape has no format, history or saved-search fields.
        let oldComics = Data(#"""
        {"version":2,"exported_at":"2026-01-01T00:00:00Z",
         "folders":[{"id":5,"name":"Reading","color":4279383126,"sort_order":0,"legacy_group_id":42}],
         "works":[{"gallery_id":1234,"title":"Comic","artists":"Artist","note":"Old note","bookmarked_at":"2026-01-01T00:00:00Z","folders":["Reading"],"thumb_page":3}],
         "artists":[{"name":"Artist","kind":0,"note":"Artist note"}]}
        """#.utf8)
        let destination = try AppDatabase.inMemory(), images = try BooruStore()
        try LibraryBackupImport.decode(oldComics).restore(database: destination, images: images)
        XCTAssertEqual(try destination.getWork(galleryId: 1234)?.note, "Old note")
        XCTAssertEqual(try destination.getWork(galleryId: 1234)?.folders.first?.sourceGroupId, 42)
        XCTAssertTrue(images.servers.isEmpty)
        let oldImages = String(decoding: try sourceImages.exportBackup().encoded(), as: UTF8.self)
            .replacingOccurrences(of: "tegnal-image-library", with: "number-memo-image-library")
        let legacyImages = try LibraryBackupImport.decode(Data(oldImages.utf8))
        try legacyImages.restore(database: destination, images: images)
        try images.refresh()
        XCTAssertNotNil(try destination.getWork(galleryId: 1234))
        XCTAssertEqual(images.favoriteIDs.count, 1)
    }

    func testUnifiedExportRemovesEmbeddedMediaAndUsesIndependentFiles() throws {
        let (source, sourceImages, _) = try populated()
        var post = BooruFixtureSource.post(73, server: sourceImages.servers[0])
        post.previewURL = URL(string: "data:image/png;base64,dGVzdA==")
        post.sampleURL = URL(fileURLWithPath: "/private/image-cache.jpg")
        try sourceImages.saveFavorite(post)
        let first = try LibraryBackup.export(database: source, images: sourceImages)
        let second = try LibraryBackup.export(database: source, images: sourceImages)
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, second.lastPathComponent)
        let data = try Data(contentsOf: first)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("data:image"))
        XCTAssertFalse(json.contains("image-cache.jpg"))
        let restored = try XCTUnwrap(LibraryBackupImport.decode(data).images?.favorites.first { $0.post.postID == 73 })
        XCTAssertNil(restored.post.previewURL)
        XCTAssertNil(restored.post.sampleURL)
        XCTAssertEqual(restored.post.fileURL, post.fileURL)
    }

    func testInvalidImageSectionCannotModifyTheComicsLibrary() throws {
        let (source, sourceImages, _) = try populated()
        var value = try LibraryBackup.capture(database: source, images: sourceImages)
        value.images.favorites[0].folderID = "missing"
        XCTAssertThrowsError(try LibraryBackupImport.decode(JSONEncoder().encode(value)))
        let destination = try AppDatabase.inMemory(), images = try BooruStore()
        XCTAssertThrowsError(try LibraryBackupImport(comics: value.comics, images: value.images).restore(database: destination, images: images))
        XCTAssertTrue(try destination.listWorks().isEmpty)
        XCTAssertTrue(images.servers.isEmpty)
    }

    func testDatabaseWriteFailureRollsBackBothLibraries() throws {
        let (source, sourceImages, _) = try populated()
        let backup = try LibraryBackupImport.decode(LibraryBackup.capture(database: source, images: sourceImages).encoded())
        let destination = try AppDatabase.inMemory(), images = try BooruStore()
        try images.database.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_favorite BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT, 'restore test'); END")
        }
        XCTAssertThrowsError(try backup.restore(database: destination, images: images))
        XCTAssertTrue(try destination.listWorks().isEmpty)
        XCTAssertFalse(try destination.listFolders().contains { $0.name == "Reading" })
        XCTAssertEqual(try images.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM servers") }, 0)
    }

    func testRestoredLibrariesPropagateTogetherThroughICloudRows() throws {
        let (source, sourceImages, _) = try populated()
        let backup = try LibraryBackupImport.decode(LibraryBackup.capture(database: source, images: sourceImages).encoded())
        let name = "backup-sync-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let local = LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults, booruDefaults: defaults)
        let peer = LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults, booruDefaults: defaults)
        var ledger = LibrarySyncLedger()
        ledger.capture(try local.snapshot(), device: "local", now: 1)
        try backup.restore(database: local.manga, images: local.booru)
        ledger.capture(try local.snapshot(), device: "local", now: 2)
        try peer.apply(ledger.changes)
        try peer.booru.refresh()
        XCTAssertEqual(try peer.manga.getWork(galleryId: 1234)?.note, "Keep this note")
        XCTAssertEqual(peer.booru.favoriteIDs.count, 1)
        XCTAssertEqual(try ChallengeStore(peer.booru).definitions().count, 1)
        XCTAssertEqual(try peer.manga.listFolders().first { $0.name == "Reading" }?.color, 0xFF123456)
    }

    func testRejectsUnsupportedVersionsDuplicateWorksAndUnknownFolders() throws {
        let (source, sourceImages, _) = try populated()
        let original = try LibraryBackup.capture(database: source, images: sourceImages)
        var value = original; value.version = 999
        XCTAssertThrowsError(try LibraryBackupImport.decode(JSONEncoder().encode(value)))
        value = original; value.comics.works.append(value.comics.works[0])
        XCTAssertThrowsError(try LibraryBackupImport.decode(JSONEncoder().encode(value)))
        value = original; value.comics.works[0].folders = ["missing"]
        XCTAssertThrowsError(try LibraryBackupImport.decode(JSONEncoder().encode(value)))
        XCTAssertThrowsError(try LibraryBackupImport.decode(Data("{}".utf8)))
    }
}
