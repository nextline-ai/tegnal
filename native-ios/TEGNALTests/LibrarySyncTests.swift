import XCTest
import GRDB
@testable import TEGNAL

final class LibrarySyncTests: XCTestCase {
    @MainActor func testBackfillRepairsMovedFilesAndDownloadsMissingReadyThumbnails() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let thumbs = root.appendingPathComponent("new-container/thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        for id: Int64 in [1001, 1002, 1003, 1004] {
            _ = try db.upsertWork(galleryId: id, title: "Preserved title", tags: "tag:sample", bookmarkedAt: "2026-10-23T00:00:00Z")
        }
        let valid = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.8))
        let recovered = thumbs.appendingPathComponent("native_1001.jpg")
        try valid.write(to: recovered)
        try db.setThumb(galleryId: 1001, status: "ready", path: root.appendingPathComponent("old-container/thumbs/native_1001.jpg").path)
        try db.setThumb(galleryId: 1002, status: "ready", path: root.appendingPathComponent("missing.jpg").path)
        try db.setThumb(galleryId: 1003, status: "ready")
        let corrupt = thumbs.appendingPathComponent("corrupt.jpg")
        try Data("not an image".utf8).write(to: corrupt)
        try db.setThumb(galleryId: 1004, status: "ready", path: corrupt.path)
        let source = BackfillFixtureSource()
        let actor = CoverQueueActor(database: db, thumbsDir: thumbs, source: source, allowsBackfill: { true }, delay: .zero)
        let state = CoverQueueState()
        await actor.start(state: state)
        XCTAssertEqual(state.processed, 3); XCTAssertEqual(state.failed, 0); XCTAssertEqual(state.remaining, 0)
        XCTAssertNil(state.error)
        XCTAssertEqual(try db.getWork(galleryId: 1001)?.thumbPath, recovered.path)
        let requests = await source.requests
        XCTAssertEqual(requests, [1004, 1003, 1002], "Recovered local files do not require another network request")
        for id: Int64 in [1001, 1002, 1003, 1004] {
            let work = try XCTUnwrap(db.getWork(galleryId: id))
            XCTAssertTrue(work.hasThumb)
            let path = try XCTUnwrap(work.thumbPath)
            let displayed = await LocalThumbnailCache.shared.load(forPath: path)
            XCTAssertNotNil(displayed, "A completed item must be decodable by the actual saved-card cache")
        }
        XCTAssertEqual(try db.countNeedingFill(), 0)
    }

    @MainActor func testBackfillNeverCountsAnAbsentOrUndecodableCoverAsComplete() async throws {
        for kind in [BackfillFixtureSource.Failure.emptyGallery, .invalidImage] {
            let db = try AppDatabase.inMemory()
            _ = try db.upsertWork(galleryId: 1234)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let actor = CoverQueueActor(database: db, thumbsDir: root, source: BackfillFixtureSource(failure: kind), allowsBackfill: { true }, delay: .zero)
            let state = CoverQueueState()
            await actor.start(state: state)
            XCTAssertFalse(state.isRunning); XCTAssertEqual(state.processed, 0)
            XCTAssertEqual(state.failed, 1); XCTAssertEqual(state.remaining, 1)
            XCTAssertEqual(try db.getWork(galleryId: 1234)?.thumbStatus, "failed")
            XCTAssertFalse(try XCTUnwrap(db.getWork(galleryId: 1234)).hasThumb)
            XCTAssertEqual(try db.countNeedingFill(), 1)
        }
    }

    @MainActor func testAStoredCoverDoesNotHideUnfilledTitleOrTags() async throws {
        for failure in [BackfillFixtureSource.Failure.emptyTitle, .emptyTags] {
            let db = try AppDatabase.inMemory()
            _ = try db.upsertWork(galleryId: 1234)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let actor = CoverQueueActor(database: db, thumbsDir: root, source: BackfillFixtureSource(failure: failure), allowsBackfill: { true }, delay: .zero)
            let state = CoverQueueState()
            await actor.start(state: state)
            XCTAssertEqual(state.processed, 0); XCTAssertEqual(state.failed, 1); XCTAssertEqual(state.remaining, 1)
            XCTAssertTrue(try XCTUnwrap(db.getWork(galleryId: 1234)).hasThumb, "Keep the successfully saved cover while retrying metadata")
        }
    }

    @MainActor func testAutomaticBackfillRunsWhileImageModeIsSelected() async throws {
        guard CoverQueuePolicy.allowsBackfill else { throw XCTSkip("Backfill is paused by the device power/thermal policy") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldAddress = UserDefaults.standard.object(forKey: "manga.site_address")
        defer { UserDefaults.standard.set(oldAddress, forKey: "manga.site_address") }
        let suite = "backfill-mode-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 1234)
        let source = BackfillFixtureSource()
        let actor = CoverQueueActor(database: db, thumbsDir: root, source: source, allowsBackfill: { true }, delay: .zero)
        let env = AppEnvironment(database: db, browserPreferences: defaults, booru: try BooruStore(), coverQueue: actor)
        env.mode = .booru
        XCTAssertTrue(env.verifySite(input: "comics.example"))
        env.setCoverQueueActive(true)
        env.startCoverQueue()
        for _ in 0..<150 {
            if env.coverQueueState.processed > 0 && !env.coverQueueState.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(env.coverQueueState.processed, 1)
        XCTAssertTrue(try XCTUnwrap(db.getWork(galleryId: 1234)).hasThumb)
        env.setCoverQueueActive(false)
    }

    @MainActor func testHeatBannerThresholdAndDismissalAreSharedByModes() throws {
        let env = AppEnvironment.preview(), state = env.coverQueueState
        state.isRunning = true; state.total = 99
        XCTAssertFalse(state.showsHeatBanner)
        state.total = 100
        XCTAssertTrue(state.showsHeatBanner)
        state.heatWarningDismissed = true
        env.mode = .manga; XCTAssertFalse(env.coverQueueState.showsHeatBanner)
        env.mode = .booru; XCTAssertFalse(env.coverQueueState.showsHeatBanner)
        XCTAssertTrue(state.isRunning, "Dismissing the notice does not stop filling")
        state.heatWarningDismissed = false; state.isRunning = false
        XCTAssertFalse(state.showsHeatBanner)
    }

    func testMissingSharedContainerIsCreatedBeforeOpeningBothDatabases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appendingPathComponent("Group Containers/new-group", isDirectory: true)
        let fallback = root.appendingPathComponent("Application Support/tegnal", isDirectory: true)
        let resolved = try AppStorage.resolveContainerURL(group: group, fallback: fallback)
        XCTAssertEqual(resolved, group)
        let path = resolved.appendingPathComponent("memo.sqlite").path
        let database = try AppDatabase.open(at: path)
        _ = try database.upsertWork(galleryId: 12345, title: "Saved work")
        let server = BooruServer.presets[0]
        try BooruStore(path: resolved.appendingPathComponent("booru.sqlite").path).saveServer(server)
        XCTAssertEqual(try AppDatabase.open(at: path).getWork(galleryId: 12345)?.title, "Saved work")
        XCTAssertEqual(try BooruStore(path: resolved.appendingPathComponent("booru.sqlite").path).servers, [server])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: resolved.path).contains { $0.hasPrefix(".storage-check-") })
    }

    func testUnavailableGroupUsesPersistentApplicationSupportWithoutRemovingExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unavailable = root.appendingPathComponent("unavailable-group")
        let marker = Data("Preserve existing content".utf8)
        try marker.write(to: unavailable)
        let fallback = root.appendingPathComponent("Application Support/tegnal", isDirectory: true)
        let resolved = try AppStorage.resolveContainerURL(group: unavailable, fallback: fallback)
        XCTAssertEqual(resolved, fallback)
        let path = resolved.appendingPathComponent("memo.sqlite").path
        _ = try AppDatabase.open(at: path).upsertWork(galleryId: 54321, title: "App-local work")
        XCTAssertEqual(try AppStorage.resolveContainerURL(group: unavailable, fallback: fallback), resolved)
        XCTAssertEqual(try AppDatabase.open(at: path).getWork(galleryId: 54321)?.title, "App-local work")
        XCTAssertEqual(try Data(contentsOf: unavailable), marker)
        XCTAssertEqual(try AppStorage.resolveContainerURL(group: nil, fallback: fallback), fallback)
        XCTAssertThrowsError(try AppStorage.resolveContainerURL(group: unavailable, fallback: unavailable))
    }

    func testFillQueueUsesRecentSaveDatesAndNewestInsertionForTiesAcrossBatches() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 9000, title: "Older save", bookmarkedAt: "2026-01-01T00:00:00Z")
        for id: Int64 in [4000, 2000, 6000] {
            _ = try db.upsertWork(galleryId: id, title: "Imported together", bookmarkedAt: "2026-10-01T00:00:00Z")
        }
        _ = try db.upsertWork(galleryId: 1000, title: "Newest save", bookmarkedAt: "2026-10-23T00:00:00Z")
        let first = try db.worksNeedingFill(limit: 2).map(\.galleryId)
        XCTAssertEqual(first, [1000, 6000])
        let second = try db.worksNeedingFill(limit: 2, exclude: Set(first)).map(\.galleryId)
        XCTAssertEqual(second, [2000, 4000])
        XCTAssertEqual(try db.worksNeedingFill(exclude: Set(first + second)).map(\.galleryId), [9000])
        // Retrying a failed cover must keep its original save priority.
        try db.setThumb(galleryId: 9000, status: "failed")
        XCTAssertEqual(try db.worksNeedingFill().map(\.galleryId), [1000, 6000, 2000, 4000, 9000])
    }

    func testHistoricalImportedFolderSyncNormalizesMetadataWithoutLosingIdentity() throws {
        let source = try adapter(), destination = try adapter()
        _ = try source.manga.createFolder(name: "Imported folder", sourceGroupId: 42)
        var row = try XCTUnwrap(source.snapshot().values.first { $0.table == "manga.folders" && $0.values["name"]?.string == "Imported folder" })
        row.values["legacy_group_id"] = row.values.removeValue(forKey: "source_group_id")
        let change = LibrarySyncChange(row: row, timestamp: 100, device: "historical", deleted: false)
        let changes = [row.key: change]
        try destination.apply(changes)
        let restored = try XCTUnwrap(destination.manga.listFolders().first { $0.name == "Imported folder" })
        XCTAssertEqual(restored.sourceGroupId, 42)
        let normalized = try XCTUnwrap(LibrarySyncAdapter.mediaFreeChanges(changes)[row.key])
        XCTAssertEqual(normalized.row.values["source_group_id"]?.integer, 42)
        XCTAssertNil(normalized.row.values["legacy_group_id"])
        XCTAssertEqual(normalized.timestamp, change.timestamp)
        XCTAssertEqual(normalized.row.key, row.key)
    }

    private var suites: [String] = []
    override func tearDown() { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }; suites = [] }
    @MainActor func testCloudContainerAccessIsRecheckedAndDisabledRequestsAreDiscarded() async throws {
        let name = "cloud-access-" + UUID().uuidString; suites.append(name)
        let resolver = CloudAccessFixture()
        let sync = LibraryCloudSync(defaults: UserDefaults(suiteName: name)!, resolveContainer: { await resolver.resolve() })
        let first = await sync.availableContainer()
        XCTAssertNotNil(first)
        await resolver.setAvailable(false)
        let unavailable = await sync.availableContainer()
        XCTAssertNil(unavailable)
        await resolver.setAvailable(true)
        let task = Task { await sync.availableContainer() }
        // Suspend the resolver while the setting is switched off and on again.
        try await Task.sleep(for: .milliseconds(20))
        sync.enabled = false; sync.enabled = true
        let stale = await task.value
        XCTAssertNil(stale)
        let fresh = await sync.availableContainer()
        XCTAssertNotNil(fresh)
        sync.enabled = false
        let disabled = await sync.availableContainer()
        XCTAssertNil(disabled)
    }

    private func adapter() throws -> LibrarySyncAdapter {
        func defaults() -> UserDefaults {
            let name = "library-sync-tests-" + UUID().uuidString; suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        return LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults(), booruDefaults: defaults())
    }
    private func exchange(_ a: LibrarySyncAdapter, _ b: LibrarySyncAdapter, _ la: inout LibrarySyncLedger, _ lb: inout LibrarySyncLedger) throws {
        la.capture(try a.snapshot(), device: "A"); lb.capture(try b.snapshot(), device: "B")
        la.merge(lb.changes); lb.merge(la.changes)
        try a.apply(la.changes); try b.apply(lb.changes)
        la.baseline = try a.snapshot(); lb.baseline = try b.snapshot()
    }
    @MainActor func testSnapshotCacheReusesIdleLibraryAndIncludesEditsAndPreferences() throws {
        let adapter = try adapter(), cache = LibrarySyncSnapshotCache()
        _ = try cache.snapshot(adapter)
        let first = try cache.snapshot(adapter)
        let warmedCount = cache.snapshotCount
        XCTAssertEqual(try cache.snapshot(adapter), first)
        XCTAssertEqual(cache.snapshotCount, warmedCount)
        _ = try adapter.manga.upsertWork(galleryId: 123, title: "New work")
        let edited = try cache.snapshot(adapter)
        XCTAssertTrue(edited.values.contains { $0.table == "manga.works" && $0.values["gallery_id"] == .integer(123) })
        adapter.mangaDefaults.set("ko", forKey: "app.language")
        let preferences = try cache.snapshot(adapter)
        XCTAssertTrue(preferences.values.contains { $0.table == "preferences.manga" && $0.values["key"] == .text("app.language") })
        try adapter.manga.deleteWork(galleryId: 123)
        XCTAssertFalse(try cache.snapshot(adapter).values.contains { $0.table == "manga.works" })
    }
    @MainActor func testSnapshotCacheDetectsExternalDatabaseConnectionWrites() throws {
        let original = try adapter(), cache = LibrarySyncSnapshotCache()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite").path
        let manga = try AppDatabase.open(at: path)
        _ = try manga.upsertWork(galleryId: 456, title: "Before")
        let adapter = LibrarySyncAdapter(manga: manga, booru: original.booru, mangaDefaults: original.mangaDefaults, booruDefaults: original.booruDefaults)
        _ = try cache.snapshot(adapter); _ = try cache.snapshot(adapter)
        let external = try DatabaseQueue(path: path)
        try external.write { try $0.execute(sql: "UPDATE works SET title = 'Shared edit' WHERE gallery_id = 456") }
        let row = try XCTUnwrap(cache.snapshot(adapter).values.first { $0.table == "manga.works" })
        XCTAssertEqual(row.values["title"], .text("Shared edit"))
    }
    func testLegacyCloudImportRepairPropagatesToAnotherDevice() throws {
        let a = try adapter(), b = try adapter()
        let backup = try AnimeBoxesBackup.parse(BooruUITestSupport.importFixture)
        var options = AnimeBoxesImportOptions(); options.folderID = "anime-boxes"
        _ = try a.booru.importAnimeBoxes(backup, options: options)
        var original = LibrarySyncLedger(), repaired = LibrarySyncLedger()
        original.capture(try a.snapshot(), device: "old-device")
        repaired.merge(original.changes)
        try b.apply(repaired.changes)
        repaired.baseline = try b.snapshot()
        try b.booru.organizeLegacyImports()
        repaired.capture(try b.snapshot(), device: "new-device")
        try a.apply(repaired.changes)
        for library in [a.booru, b.booru] {
            try library.refresh()
            for server in backup.servers {
                let local = try XCTUnwrap(library.servers.first { $0.canonicalAddress == server.canonicalAddress })
                XCTAssertEqual(library.favorites(serverIDs: [local.id], folderID: "site:" + server.canonicalAddress).count, 1)
            }
            XCTAssertFalse(library.folders().contains { $0.id == "anime-boxes" })
        }
    }

    func testCloudSnapshotExcludesEmbeddedMediaAndPreservesSiteFolderAcrossDevices() throws {
        let a = try adapter(), b = try adapter(), server = BooruServer.presets[0]
        try a.booru.saveServer(server)
        var post = BooruFixtureSource.post(42, server: server)
        post.previewURL = URL(string: "data:image/png;base64," + String(repeating: "A", count: 100_000))
        post.sampleURL = URL(fileURLWithPath: "/private/local-image.jpg")
        post.fileURL = URL(string: "https://example.com/image.jpg")
        try a.booru.saveFavorite(post)
        let snapshot = try a.snapshot()
        let row = try XCTUnwrap(snapshot.values.first { $0.table == "booru.favorites" })
        let payload = try XCTUnwrap(row.values["payload"]?.data)
        let saved = try JSONDecoder().decode(BooruPost.self, from: payload)
        XCTAssertNil(saved.previewURL); XCTAssertNil(saved.sampleURL)
        XCTAssertEqual(saved.fileURL, post.fileURL)
        XCTAssertLessThan(payload.count, 5000)
        var oldRow = row
        oldRow.values["payload"] = .blob(try JSONEncoder().encode(post))
        let oldChange = LibrarySyncChange(row: oldRow, timestamp: 123, device: "old", deleted: false)
        let cleaned = try XCTUnwrap(LibrarySyncAdapter.mediaFreeChanges([oldRow.key: oldChange])[oldRow.key])
        XCTAssertEqual(cleaned.timestamp, 123)
        XCTAssertEqual(cleaned.row.key, oldRow.key)
        XCTAssertNil(try JSONDecoder().decode(BooruPost.self, from: XCTUnwrap(cleaned.row.values["payload"]?.data)).previewURL)
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try b.booru.refresh()
        let restored = try XCTUnwrap(b.booru.favorites(serverIDs: b.booru.servers.map(\.id)).first)
        XCTAssertEqual(b.booru.folderID(for: restored), "site:" + server.canonicalAddress)
        XCTAssertEqual(b.booru.folders().first { $0.id == "site:" + server.canonicalAddress }?.color,
                       a.booru.folders().first { $0.id == "site:" + server.canonicalAddress }?.color)
    }

    @MainActor func testReloadDoesNotTurnAbsentDefaultsIntoLocalEdits() throws {
        let a = try adapter()
        let env = AppEnvironment(database: a.manga, browserPreferences: a.mangaDefaults, booru: a.booru)
        env.reloadSyncedPreferences()
        for key in LibrarySyncAdapter.commonPreferences { XCTAssertNil(a.mangaDefaults.object(forKey: key), key) }
    }

    @MainActor func testPreferencesConnectionAndResetSyncWithoutDeviceSettings() throws {
        let a = try adapter(), b = try adapter()
        a.mangaDefaults.set(true, forKey: "site_verified")
        a.mangaDefaults.set("ja", forKey: "app.language")
        a.mangaDefaults.set(false, forKey: LibraryCloudSync.enabledKey)
        a.booruDefaults.set("en", forKey: "reader.translationLanguage")
        a.booruDefaults.set(5, forKey: "grid_columns")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        XCTAssertTrue(b.mangaDefaults.bool(forKey: "site_verified"))
        XCTAssertEqual(b.mangaDefaults.string(forKey: "app.language"), "ja")
        XCTAssertEqual(b.booruDefaults.string(forKey: "reader.translationLanguage"), "en")
        XCTAssertNil(b.mangaDefaults.object(forKey: LibraryCloudSync.enabledKey))
        XCTAssertNil(b.booruDefaults.object(forKey: "grid_columns"))
        a.mangaDefaults.removeObject(forKey: "app.language")
        try exchange(a, b, &la, &lb)
        XCTAssertNil(b.mangaDefaults.object(forKey: "app.language"))
    }

    func testComicsFolderRenameColorAndOrderConvergeAcrossDevices() throws {
        let a = try adapter(), b = try adapter()
        let first = try XCTUnwrap(a.manga.createFolder(name: "First").id)
        let second = try XCTUnwrap(a.manga.createFolder(name: "Second").id)
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try a.manga.renameFolder(id: first, name: "Renamed")
        try a.manga.setFolderColor(id: first, color: 0xFF123456)
        try a.manga.reorderFolders([second, first])
        try exchange(a, b, &la, &lb)
        let names = try b.manga.listFolders().map(\.name)
        XCTAssertEqual(Array(names.prefix(2)), ["Second", "Renamed"])
        XCTAssertEqual(try b.manga.listFolders().first { $0.name == "Renamed" }?.color, 0xFF123456)
        let before = lb.changes
        lb.capture(try b.snapshot(), device: "B")
        XCTAssertEqual(lb.changes, before)
    }

    func testPersistedLedgerRejectsStalePeerAfterOfflineDeleteAndRestart() throws {
        let a = try adapter(), b = try adapter()
        _ = try a.manga.upsertWork(galleryId: 42, title: "Saved")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        let stale = lb.changes
        try a.manga.deleteWork(galleryId: 42)
        la.capture(try a.snapshot(), device: "A")
        let data = try JSONEncoder().encode(la)
        la = try JSONDecoder().decode(LibrarySyncLedger.self, from: data)
        la.merge(stale)
        try a.apply(la.changes)
        XCTAssertNil(try a.manga.getWork(galleryId: 42))
        lb.merge(la.changes); try b.apply(lb.changes)
        XCTAssertNil(try b.manga.getWork(galleryId: 42))
    }

    func testCorruptPeerDoesNotBlockHealthyCloudDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try adapter(); _ = try a.manga.upsertWork(galleryId: 42)
        var ledger = LibrarySyncLedger(); ledger.capture(try a.snapshot(), device: "A")
        try CloudLibraryFiles.write(JSONEncoder().encode(LibrarySyncDocument(changes: ledger.changes)), to: root.appendingPathComponent("library-healthy.json"))
        try Data("interrupted".utf8).write(to: root.appendingPathComponent("library-broken.json"))
        let result = try CloudLibraryFiles.readState(in: root)
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.unreadableFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library-broken.json").path))
        XCTAssertThrowsError(try CloudLibraryFiles.read(in: root))
        let b = try adapter(); try b.apply(result.documents[0].changes)
        XCTAssertNotNil(try b.manga.getWork(galleryId: 42))
    }

    func testEmptyDefaultDeletionSyncsAndConcurrentFavoritesAreProtected() throws {
        let a = try adapter(), b = try adapter()
        try a.booru.database.write { try BooruStore.ensureUnsorted(in: $0) }
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try a.manga.deleteFolder(id: try XCTUnwrap(a.manga.listFolders().first?.id))
        try a.booru.deleteFolder("unsorted")
        try exchange(a, b, &la, &lb)
        XCTAssertTrue(try b.manga.listFolders().isEmpty)
        XCTAssertTrue(b.booru.folders().isEmpty)

        let server = BooruServer.presets[0]
        try b.booru.saveServer(server)
        try b.booru.database.write { try BooruStore.ensureUnsorted(in: $0) }
        let post = BooruFixtureSource.post(83, server: server)
        try b.booru.saveFavorite(post, folderID: "unsorted")
        try b.apply(la.changes)
        XCTAssertTrue(b.booru.isFavorite(post))
        XCTAssertEqual(b.booru.folderID(for: post), "unsorted")
        XCTAssertTrue(b.booru.folders().contains { $0.id == "unsorted" })
    }

    func testConcurrentFolderRemovalKeepsNewlySavedWorks() throws {
        let a = try adapter(), b = try adapter()
        let folder = try a.manga.createFolder(name: "Reading")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        let other = try XCTUnwrap(b.manga.listFolders().first { $0.name == "Reading" })
        _ = try b.manga.upsertWork(galleryId: 99, folderId: other.id)
        try a.manga.dbWriter.write { try $0.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [folder.id]) }
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(try b.manga.getWork(galleryId: 99)?.folders.first?.name, "미분류")
    }

    func testLiveICloudContainerUploadAndCoordinatedRead() async throws {
        guard ProcessInfo.processInfo.environment["TEGNAL_BOORU_LIVE_TESTS"] == "1" else { throw XCTSkip("Opt-in device iCloud test") }
        XCTAssertNotNil(FileManager.default.ubiquityIdentityToken, "An iCloud account with Drive enabled is required")
        let container = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: AppStorage.iCloudContainerId) }.value
        let root = try XCTUnwrap(container, "The signed iCloud container must be available")
            .appendingPathComponent("Documents/SyncDiagnostics/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let row = LibrarySyncRow(table: "manga.saved_searches", values: ["query": .text("sync diagnostic")])
        var ledger = LibrarySyncLedger(); ledger.capture([row.key: row], device: "diagnostic")
        let document = LibrarySyncDocument(changes: ledger.changes)
        let data = try JSONEncoder().encode(document)
        let destination = root.appendingPathComponent("library-diagnostic.json")
        try await Task.detached { try CloudLibraryFiles.write(data, to: destination, ubiquitous: true) }.value
        let read = try await Task.detached { try CloudLibraryFiles.read(in: root) }.value
        XCTAssertEqual(read.first?.changes, document.changes)
        for _ in 0..<60 {
            var probe = destination
            probe.removeAllCachedResourceValues()
            let values = try probe.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            if values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == true { return }
            try await Task.sleep(for: .seconds(1))
        }
        var probe = destination; probe.removeAllCachedResourceValues()
        let state = try probe.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        let error = state.ubiquitousItemUploadingError as NSError?
        XCTFail("iCloud upload timed out: managed=\(String(describing: state.isUbiquitousItem)), uploaded=\(String(describing: state.ubiquitousItemIsUploaded)), error=\(error?.domain ?? "none")/\(error?.code ?? 0)")
    }

    func testManuallyAddedFirstServerSyncsAsUserData() throws {
        let a = try adapter(), b = try adapter()
        let server = BooruServer.presets[2]
        try a.booru.saveServer(server)
        try a.booru.saveFavorite(BooruFixtureSource.post(101, server: server))
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try b.booru.refresh()
        XCTAssertEqual(b.booru.servers.map(\.canonicalAddress), [server.canonicalAddress])
        XCTAssertEqual(b.booru.favorites(serverIDs: b.booru.servers.map(\.id)).count, 1)
        let row = try XCTUnwrap(try a.snapshot().values.first { $0.table == "booru.servers" })
        XCTAssertFalse(row.isFactoryDefault)
    }

    func testTwoDevicesMergeFoldersWorksSettingsAndOfflineDeletionWithoutLocalPaths() throws {
        let a = try adapter(), b = try adapter()
        let fa = try a.manga.createFolder(name: "Art"), fb = try b.manga.createFolder(name: "Reading")
        XCTAssertEqual(fa.id, fb.id) // Local IDs collide, global folder identities must not.
        _ = try a.manga.upsertWork(galleryId: 100, folderId: fa.id, title: "First")
        _ = try b.manga.upsertWork(galleryId: 200, folderId: fb.id, title: "Second")
        try a.manga.setThumb(galleryId: 100, status: "ready", path: "/private/device-a/cover.jpg")
        a.mangaDefaults.set(5, forKey: "grid_columns")
        a.mangaDefaults.set("tag:landscape", forKey: "manga.defaultTags")
        a.booruDefaults.set(true, forKey: "reader.keepAwake")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(try a.manga.worksCount(), 2); XCTAssertEqual(try b.manga.worksCount(), 2)
        XCTAssertEqual(try b.manga.getWork(galleryId: 100)?.folders.first?.name, "Art")
        XCTAssertNil(try b.manga.getWork(galleryId: 100)?.thumbPath)
        XCTAssertNil(b.mangaDefaults.object(forKey: "grid_columns")); XCTAssertNil(b.booruDefaults.object(forKey: "reader.keepAwake"))
        XCTAssertEqual(b.mangaDefaults.string(forKey: "manga.defaultTags"), "tag:landscape")
        try a.manga.deleteWork(galleryId: 100)
        _ = try b.manga.upsertWork(galleryId: 300, folderId: fb.id)
        try exchange(a, b, &la, &lb)
        XCTAssertNil(try b.manga.getWork(galleryId: 100)); XCTAssertNotNil(try a.manga.getWork(galleryId: 300))
        let old = la.changes
        la.capture(try a.snapshot(), device: "A")
        XCTAssertEqual(old, la.changes, "Applying remote records must not create an endless echo")
    }
    func testBooruServerIdentityAndFolderOrderSurviveMerge() throws {
        let a = try adapter(), b = try adapter()
        let sa = BooruServer(id: "a", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        let sb = BooruServer(id: "b", name: "Gelbooru", baseURL: URL(string: "https://www.gelbooru.com/")!, engine: .gelbooru)
        try a.booru.saveServer(sa); try b.booru.saveServer(sb)
        let folder = try a.booru.saveFolder(name: "Favorites", color: 0xFF112233)
        try a.booru.database.write { try BooruStore.ensureUnsorted(in: $0) }
        try a.booru.reorderFolders([folder, "unsorted"])
        let post = BooruPost(serverID: sa.id, postID: 123, width: 100, height: 100, tags: ["landscape"], artists: [], rating: "g", score: 1, fileExtension: "jpg")
        try a.booru.saveFavorite(post, folderID: folder)
        try a.booru.toggleTag("landscape sky", serverID: sa.id, kind: "search")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        try b.booru.refresh()
        XCTAssertTrue(b.booru.isFavorite(post.onServer(sb.id)))
        XCTAssertEqual(b.booru.folderID(for: post.onServer(sb.id)), folder)
        XCTAssertEqual(b.booru.folders().first?.id, folder)
        XCTAssertEqual(b.booru.savedTags(serverID: sb.id, kind: "search"), ["landscape sky"])
        try a.booru.deleteFolder(folder)
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(b.booru.folderID(for: post.onServer(sb.id)), "unsorted")
        XCTAssertFalse(b.booru.folders().contains { $0.id == folder })
    }
    func testFreshDeviceDoesNotOverwriteExistingDefaultFolderColor() throws {
        let a = try adapter(), b = try adapter()
        try a.booru.database.write { try BooruStore.ensureUnsorted(in: $0) }
        try a.booru.setFolderColor("unsorted", color: 0xFFABCDEF)
        let folder = try XCTUnwrap(a.manga.listFolders().first?.id)
        try a.manga.setFolderColor(id: folder, color: 0xFF123456)
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(b.booru.folders().first?.color, 0xFFABCDEF)
        XCTAssertEqual(try b.manga.listFolders().first?.color, 0xFF123456)
    }

    func testFileRoundTripAndDeleteTombstoneDoesNotRetainWorkMetadata() throws {
        let a = try adapter()
        _ = try a.manga.upsertWork(galleryId: 90, title: "Private title")
        var ledger = LibrarySyncLedger(); ledger.capture(try a.snapshot(), device: "A")
        try a.manga.deleteWork(galleryId: 90); ledger.capture(try a.snapshot(), device: "A")
        let deletion = try XCTUnwrap(ledger.changes.values.first { $0.deleted && $0.row.table == "manga.works" })
        XCTAssertEqual(Set(deletion.row.values.keys), ["gallery_id"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONEncoder().encode(LibrarySyncDocument(changes: ledger.changes))
        try CloudLibraryFiles.write(data, to: root.appendingPathComponent("library-A.json"))
        XCTAssertEqual(try CloudLibraryFiles.read(in: root).first?.changes, ledger.changes)
    }
    func testHistoryExpiresButSavedMultiTagSearchDoesNot() throws {
        let defaults = ReaderPreferences.defaults
        let previous = defaults.object(forKey: "search.retentionDays")
        defaults.set(3, forKey: "search.retentionDays")
        defer { if let previous { defaults.set(previous, forKey: "search.retentionDays") } else { defaults.removeObject(forKey: "search.retentionDays") } }
        let a = try adapter()
        try a.manga.recordSearch("tag:landscape tag:sky")
        try a.manga.toggleSavedSearch("tag:landscape tag:sky")
        try a.manga.dbWriter.write { try $0.execute(sql: "UPDATE search_history SET used_at = ?", arguments: [Date().addingTimeInterval(-4 * 86400).timeIntervalSince1970]) }
        XCTAssertTrue(try a.manga.searchHistory().isEmpty)
        XCTAssertEqual(try a.manga.savedSearches(), ["tag:landscape tag:sky"])
        try a.manga.clearSearchHistory()
        XCTAssertEqual(try a.manga.savedSearches().count, 1)
    }
    @MainActor func testBookmarkCopiesTheVisibleCoverIntoFolderPreviews() async throws {
        let env = AppEnvironment(database: try .inMemory(), browserPreferences: UserDefaults(suiteName: "cover-test-" + UUID().uuidString)!)
        let source = FixtureContentSource()
        let gallery = try await source.gallery(900000001)
        let images = PageImageStore(source: source)
        _ = try await images.load(gallery.pages[0], galleryID: gallery.id, thumbnail: true)
        _ = try ContentBookmarkAction.toggle(id: gallery.id, gallery: gallery, env: env, images: images)
        for _ in 0..<50 {
            if try env.database.getWork(galleryId: gallery.id)?.thumbStatus == "ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let work = try XCTUnwrap(env.database.getWork(galleryId: gallery.id))
        XCTAssertEqual(work.thumbStatus, "ready")
        let path = try XCTUnwrap(work.thumbPath)
        XCTAssertNotNil(UIImage(contentsOfFile: path))
        XCTAssertEqual(try env.database.folderPreviews().values.flatMap { $0 }.first?.galleryId, gallery.id)
        _ = try ContentBookmarkAction.toggle(id: gallery.id, gallery: gallery, env: env, images: images)
        XCTAssertNil(try env.database.getWork(galleryId: gallery.id))
        try? FileManager.default.removeItem(atPath: path)
    }

    func testPreviouslyFailedCoversAreRetriedWithoutRepeatingTheSameBatch() throws {
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 17, title: "Existing item", tags: "sky")
        try db.setThumb(galleryId: 17, status: "failed")
        XCTAssertEqual(try db.worksNeedingFill().map(\.galleryId), [17])
        XCTAssertEqual(try db.countNeedingFill(), 1)
        XCTAssertTrue(try db.worksNeedingFill(exclude: [17]).isEmpty)
    }

    func testOriginalTagIsNotMistakenForTheOriginalImage() throws {
        let html = Data("""
        <html><li><a href="index.php?page=post&amp;s=list&amp;tags=original">original</a></li>
        <img id="image" src="https://img.example/sample.jpg">
        <a href="https://img.example/full.png">Original image</a></html>
        """.utf8)
        let post = try BooruLegacyHTML.post(html, server: BooruServer.presets[1], id: 15029425)
        XCTAssertEqual(post.fileURL?.absoluteString, "https://img.example/full.png")
        XCTAssertEqual(post.fileExtension, "png")
        let withoutDownload = Data("<html><a href='?tags=original'>original</a><img id='image' src='https://img.example/full.jpg'></html>".utf8)
        XCTAssertEqual(try BooruLegacyHTML.post(withoutDownload, server: BooruServer.presets[1], id: 1).fileURL?.path, "/full.jpg")
    }

    func testGelbooruVideoUsesPlayableMP4SourceRatherThanPosterOrWebM() throws {
        let html = Data("<html><video id='image' poster='https://img.example/poster.jpg'><source src='https://video.example/file.webm' type='video/webm'><source src='https://video.example/file.mp4' type='video/mp4'></video><a href='https://video.example/file.webm'>Original video</a></html>".utf8)
        let post = try BooruLegacyHTML.post(html, server: BooruServer.presets[1], id: 10)
        XCTAssertEqual(post.fileURL?.pathExtension, "mp4")
        XCTAssertTrue(post.isVideo)
    }

    func testAnimeBoxesImportMatchesEquivalentServerAddresses() throws {
        let a = try adapter()
        let server = BooruServer(id: "local", name: "Gelbooru", baseURL: URL(string: "https://gelbooru.com")!, engine: .gelbooru)
        try a.booru.saveServer(server)
        let data = Data(#"{"backupVersion":"1.0","servers":[{"serverName":"Gelbooru","url":"https://www.gelbooru.com/","type":1}],"favorites":[{"ppostId":"123","ppostUrl":"https://gelbooru.com/index.php?page=post&s=view&id=123","file":{"url":"https://img.example/a.jpg"}}]}"#.utf8)
        let result = try a.booru.importAnimeBoxes(.parse(data), options: .init())
        XCTAssertEqual(result.serversAdded, 0); XCTAssertEqual(result.added, 1)
        XCTAssertEqual(a.booru.favorites(serverID: server.id).first?.postID, 123)
    }
}

private actor CloudAccessFixture {
    private var available = true
    func setAvailable(_ value: Bool) { available = value }
    func resolve() async -> URL? {
        try? await Task.sleep(for: .milliseconds(100))
        return available ? URL(fileURLWithPath: "/tmp/test-cloud-container") : nil
    }
}

private actor BackfillFixtureSource: ContentProviding {
    enum Failure { case none, emptyGallery, invalidImage, emptyTitle, emptyTags }
    let failure: Failure
    private let fixture = FixtureContentSource()
    private(set) var requests: [Int64] = []
    init(failure: Failure = .none) { self.failure = failure }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        requests.append(id)
        let gallery = try await fixture.gallery(id)
        return NativeGallery(id: id, title: failure == .emptyTitle ? "" : gallery.title, artists: gallery.artists, language: gallery.language,
                             type: gallery.type, tags: failure == .emptyTags ? [] : gallery.tags, pages: failure == .emptyGallery ? [] : gallery.pages)
    }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { try await fixture.list(query, offset: offset, count: count) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        if failure == .invalidImage { return Data("not an image".utf8) }
        return try await fixture.image(page, galleryID: galleryID, thumbnail: thumbnail)
    }
}
