import XCTest
import GRDB
@testable import TEGNAL

final class LibraryBackupTests: XCTestCase {
    func testClassificationAndDuplicateReviewPreserveDifferentLanguagesFoldersAndNotes() throws {
        let database = try AppDatabase.inMemory()
        let a = try database.createFolder(name: "A"), b = try database.createFolder(name: "B")
        _ = try database.upsertWork(galleryId: 101, folderId: a.id, title: "Same Title", artists: "Author", language: "japanese", type: "manga")
        _ = try database.upsertWork(galleryId: 102, folderId: b.id, title: "Same Title", artists: "Author", language: "japanese", type: "manga")
        _ = try database.upsertWork(galleryId: 103, title: "Same Title", artists: "Author", language: "english", type: "manga")
        _ = try database.upsertWork(galleryId: 101, title: "Same Title")
        try database.setNote(galleryId: 101, note: "First note"); try database.setNote(galleryId: 102, note: "Second note")
        let works = try database.listWorks()
        XCTAssertEqual(works.count, 3, "Saving the same number must update its existing record")
        let groups = LibraryMaintenance.classification(works: works, posts: [], criterion: .language)
        XCTAssertEqual(groups.first { $0.name == "japanese" }?.count, 2)
        let candidates = LibraryMaintenance.duplicates(works: works, posts: [])
        XCTAssertEqual(candidates.count, 1); XCTAssertEqual(candidates[0].count, 2)
        try LibraryMaintenance.mergeComics(candidates[0], keeping: 101, database: database)
        let kept = try XCTUnwrap(database.getWork(galleryId: 101))
        XCTAssertEqual(Set(kept.folders.map(\.name)), ["A", "B"])
        XCTAssertTrue(kept.note?.contains("First note") == true); XCTAssertTrue(kept.note?.contains("Second note") == true)
        XCTAssertNil(try database.getWork(galleryId: 102)); XCTAssertNotNil(try database.getWork(galleryId: 103))
        var p = BooruFixtureSource.post(1, server: BooruServer.presets[0]), q = BooruFixtureSource.post(2, server: BooruServer.presets[1])
        p.fileURL = URL(string: "https://a.example/0123456789abcdef0123456789abcdef.jpg")
        q.fileURL = URL(string: "https://b.example/0123456789abcdef0123456789abcdef.jpg")
        XCTAssertEqual(LibraryMaintenance.duplicates(works: [], posts: [p, q]).first?.count, 2)
    }

    @MainActor func testNativeTagReorderAndRepeatedHoldsToggleEveryCategoryWithoutMixingKinds() throws {
        let database = try AppDatabase.inMemory(), images = try BooruStore()
        let suite = "native-tag-reorder-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let model = SavedCollectionsModel(database: database, booru: images, preferences: preferences)
        for index in 0..<7 { model.save("tag_\(index)", kind: .tag) }
        model.reorder(.tag, from: IndexSet(integer: 0), to: 5)
        XCTAssertEqual(model.names(.tag), ["tag_1", "tag_2", "tag_3", "tag_4", "tag_0", "tag_5", "tag_6"])
        for kind in [SavedCollectionKind.artist, .language, .female, .series] {
            model.toggle("sample", kind: kind); XCTAssertEqual(model.names(kind), ["sample"])
            model.toggle("sample", kind: kind); XCTAssertTrue(model.names(kind).isEmpty)
        }
        XCTAssertEqual(model.names(.tag).count, 7)
        let server = BooruServer.presets[0]; try images.saveServer(server)
        let image = SavedCollectionsModel(database: database, booru: images, server: server, preferences: preferences)
        image.toggle("sample", kind: .female); XCTAssertEqual(image.names(.female), ["sample"])
        image.toggle("sample", kind: .female); XCTAssertTrue(image.names(.female).isEmpty)
        XCTAssertNil(model.error); XCTAssertNil(image.error)
    }


    @MainActor func testSavedCollectionsKeepModesServersOrderingAndNewKindsSeparateThroughBackup() throws {
        let database = try AppDatabase.inMemory(), booru = try BooruStore()
        let first = BooruServer.presets[0], second = BooruServer.presets[1]
        try booru.saveServer(first); try booru.saveServer(second)
        let suite = "saved-collections-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manga = SavedCollectionsModel(database: database, booru: booru, preferences: preferences)
        let image = SavedCollectionsModel(database: database, booru: booru, server: first, preferences: preferences)
        let other = SavedCollectionsModel(database: database, booru: booru, server: second, preferences: preferences)
        _ = try database.addFavoriteArtist(name: "legacy", kind: 0)
        _ = try database.addFavoriteArtist(name: "legacy", kind: 1)
        try manga.refresh()
        XCTAssertEqual(manga.names(.artist), ["legacy"])
        XCTAssertEqual(manga.names(.group), ["legacy"])
        for index in 0..<7 { manga.save("tag_\(index)", kind: .tag); image.save("tag_\(index)", kind: .tag) }
        other.save("other_server", kind: .tag)
        manga.save("series:sample", kind: .series)
        image.save("source_series", kind: .series)
        manga.save("sample artist", kind: .artist); manga.save("sample_artist", kind: .artist)
        XCTAssertEqual(manga.names(.artist), ["legacy", "sample_artist"], "Holding an existing tag must not remove or duplicate it")
        XCTAssertEqual(manga.names(.series), ["sample"])
        XCTAssertEqual(image.names(.series), ["source_series"])
        XCTAssertEqual(other.names(.tag), ["other_server"])
        XCTAssertNil(manga.error); XCTAssertNil(image.error); XCTAssertNil(other.error)
        manga.move("tag_6", to: "tag_0", kind: .tag)
        image.move("tag_4", to: "tag_0", kind: .tag)
        XCTAssertEqual(SavedCollectionOrdering.preview(manga.names(.tag)), ["tag_6", "tag_0", "tag_1", "tag_2", "tag_3"])
        XCTAssertEqual(image.names(.tag).first, "tag_4")
        XCTAssertEqual(other.names(.tag).first, "other_server")
        let reopened = SavedCollectionsModel(database: database, booru: booru, preferences: preferences)
        try reopened.refresh()
        XCTAssertEqual(reopened.names(.tag), manga.names(.tag))
        XCTAssertEqual(SavedCollectionOrdering.preview(Array(0..<4).map(String.init)).count, 4)
        XCTAssertFalse(SavedCollectionOrdering.showsMore(4)); XCTAssertTrue(SavedCollectionOrdering.showsMore(5))
        XCTAssertTrue(SavedCollectionOrdering.showsMore(6))
        XCTAssertEqual(SavedCollectionOrdering.resolve(["new", "kept"], preferred: ["deleted", "kept", "kept"]), ["kept", "new"])
        XCTAssertEqual(manga.query(.init(kind: .series, name: "sample")), "series:sample")
        XCTAssertEqual(image.query(.init(kind: .series, name: "source_series")), "source_series")
        manga.remove("legacy", kind: .artist)
        XCTAssertEqual(manga.names(.group), ["legacy"], "Removing an artist must preserve the same name saved as a different kind")
        let url = try LibraryBackup.export(database: database, images: booru)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let restoredDatabase = try AppDatabase.inMemory(), restoredImages = try BooruStore()
        try LibraryBackupImport.read(url).restore(database: restoredDatabase, images: restoredImages)
        try restoredImages.refresh()
        XCTAssertTrue(try restoredDatabase.listArtists().contains { $0.kind == SavedCollectionKind.series.mangaKind && $0.name == "sample" })
        XCTAssertEqual(restoredImages.savedTags(serverID: first.id, kind: "series"), ["source_series"])
        XCTAssertEqual(restoredImages.savedTags(serverID: second.id), ["other_server"])
    }


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
