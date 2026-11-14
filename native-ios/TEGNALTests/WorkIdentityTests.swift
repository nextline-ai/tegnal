import XCTest
import GRDB
@testable import TEGNAL

/// One number may name a different work on each website; the library keeps both.
final class WorkIdentityTests: XCTestCase {
    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
        WorkIdentity.siblings = { _ in [] }
    }

    override func tearDown() {
        WorkIdentity.siblings = { ComicSites.siblings(of: $0) }
        super.tearDown()
    }

    private func rows(_ id: Int64) throws -> [Work] {
        try database.dbWriter.read { try WorkIdentity.rows($0, galleryId: id) }
    }

    func testTheSameNumberFromTwoWebsitesIsTwoSavedWorks() throws {
        let indexed = try database.upsertWork(galleryId: 7, title: "Alpha", artists: "first", site: "indexed.example.org")
        let keyed = try database.upsertWork(galleryId: 7, title: "Beta", artists: "second", site: "keyed.example.org")
        XCTAssertNotEqual(indexed.id, keyed.id)
        XCTAssertEqual(try rows(7).count, 2)
        XCTAssertEqual(try database.getWork(galleryId: 7, site: "indexed.example.org")?.title, "Alpha")
        XCTAssertEqual(try database.getWork(galleryId: 7, site: "keyed.example.org")?.title, "Beta")
        XCTAssertNil(try database.getWork(galleryId: 7, site: "other.example.org"), "Another website's number names another work")

        // Saving again from the same website updates it instead of adding a third.
        _ = try database.upsertWork(galleryId: 7, title: "Alpha 2", site: "indexed.example.org")
        XCTAssertEqual(try rows(7).count, 2)

        try database.deleteWork(galleryId: 7, site: "keyed.example.org")
        XCTAssertEqual(try rows(7).map(\.title), ["Alpha 2"])
    }

    func testAWorkWhoseWebsiteIsUnknownIsClaimedByTheFirstWebsiteThatSavesIt() throws {
        _ = try database.upsertWork(galleryId: 9, title: "Imported")
        let claimed = try database.upsertWork(galleryId: 9, site: "indexed.example.org")
        XCTAssertEqual(claimed.site, "indexed.example.org")
        XCTAssertEqual(try rows(9).count, 1)
        // Afterwards the other website's number is its own work.
        _ = try database.upsertWork(galleryId: 9, site: "keyed.example.org")
        XCTAssertEqual(Set(try rows(9).compactMap(\.site)), ["indexed.example.org", "keyed.example.org"])
    }

    func testWebsitesThatNumberTheirWorksTheSameWayShareASavedWork() throws {
        WorkIdentity.siblings = { $0 == "mirror.example.org" ? ["keyed.example.org"] : [] }
        _ = try database.upsertWork(galleryId: 11, title: "Shared", site: "keyed.example.org")
        XCTAssertEqual(try database.getWork(galleryId: 11, site: "mirror.example.org")?.title, "Shared")
        _ = try database.upsertWork(galleryId: 11, title: "Shared again", site: "mirror.example.org")
        XCTAssertEqual(try rows(11).count, 1)
    }

    func testSavedMarksFollowTheWebsite() throws {
        _ = try database.upsertWork(galleryId: 1, site: "indexed.example.org")
        _ = try database.upsertWork(galleryId: 2)
        let keys = try database.dbWriter.read { try SavedWorkKeys.fetch($0) }
        XCTAssertEqual(keys.ids(on: "indexed.example.org"), [1, 2])
        XCTAssertEqual(keys.ids(on: "keyed.example.org"), [2], "A work whose website is unknown shows as saved everywhere")
    }

    func testMigrationKeepsEveryWorkFolderLinkAndQueuedRefresh() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "v13_work_site")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO folders (id, name, created_at) VALUES (10, 'Kept', '2024-01-01');
            INSERT INTO works (id, gallery_id, title, bookmarked_at, site, note) VALUES (5, 100, 'Old', '2024-01-01', 'indexed.example.org', 'mine'), (6, 200, 'Other', '2024-01-02', NULL, NULL);
            INSERT INTO folder_works VALUES (10, 5, '2024-01-01'), (10, 6, '2024-01-02');
            INSERT INTO refresh_queue VALUES (200);
            INSERT INTO visual_fingerprints VALUES ('comics', 100, 1, 'd', x'00');
            """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder_works WHERE folder_id = 10"), 2)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT note FROM works WHERE id = 5"), "mine")
            XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT work_id FROM refresh_queue"), [6])
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO works (gallery_id, title, bookmarked_at, site) VALUES (100, 'New', '2024-02-01', 'keyed.example.org')")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO works (gallery_id, bookmarked_at, site) VALUES (100, '2024-02-01', 'keyed.example.org')"),
                                 "A number and website stay unique")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO works (gallery_id, bookmarked_at) VALUES (200, '2024-02-01')"),
                                 "So does a number whose website is unknown")
            // Removing one of two works under a number keeps the cover fingerprint the other uses.
            try db.execute(sql: "DELETE FROM works WHERE id = 5")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM visual_fingerprints"), 1)
            try db.execute(sql: "DELETE FROM works WHERE gallery_id = 100")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM visual_fingerprints"), 0)
        }
    }

    // MARK: - Importing again

    private func violetBackup(_ articles: [(Int64, Int)], groups: [(Int, String)] = [(1, "violet_default")]) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("identity_\(UUID().uuidString).db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
            CREATE TABLE BookmarkGroup (Id INTEGER PRIMARY KEY, Name TEXT, Description TEXT, Color INTEGER, Gorder INTEGER);
            CREATE TABLE BookmarkArticle (Id INTEGER PRIMARY KEY, Article TEXT, DateTime TEXT, GroupId INTEGER);
            """)
            for (id, name) in groups { try db.execute(sql: "INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (?, ?, ?)", arguments: [id, name, id]) }
            for (index, (article, group)) in articles.enumerated() {
                try db.execute(sql: "INSERT INTO BookmarkArticle (Id, Article, DateTime, GroupId) VALUES (?, ?, ?, ?)", arguments: [index + 1, String(article), "2024-01-0\(index % 9 + 1)", group])
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// An earlier version merged a backup's work into a different saved work under the same
    /// number. Importing the backup again brings it back as its own work, and leaves the works
    /// saved since, and everything already imported, as they were.
    func testImportingAgainFillsInWorksAnEarlierVersionMergedAway() throws {
        // Saved from a website: number 500 there is another work than the backup's 500.
        let saved = try database.upsertWork(galleryId: 500, folderId: try database.defaultSaveFolder().id, title: "Alpha", artists: "artist a", site: "keyed.example.org")
        // Saved since the first import: the same work as the backup's 501, now with its website.
        _ = try database.upsertWork(galleryId: 501, title: "Gamma", artists: "artist c", site: "indexed.example.org")
        // Saved since, not in the backup at all.
        _ = try database.upsertWork(galleryId: 502, title: "Delta", artists: "artist d", site: "keyed.example.org")
        try database.upsertCatalogBatch([
            CatalogWork(id: 500, title: "Beta", artists: "artist b", tags: "tag:one"),
            CatalogWork(id: 501, title: "Gamma", artists: "artist c", tags: "tag:two"),
            CatalogWork(id: 503, title: "Epsilon", artists: "artist e", tags: "tag:three")
        ])
        let backup = try violetBackup([(500, 2), (501, 2), (503, 2)], groups: [(1, "violet_default"), (2, "Kept")])
        let importer = MangaViewerImportService(appDb: database)

        // What the earlier version did: the backup's 500 joined the saved Alpha.
        let kept = try database.createFolder(name: "Kept")
        try database.addWorkToFolder(workId: saved.id!, folderId: kept.id!)

        _ = try importer.importUserDb(path: backup)
        XCTAssertEqual(try rows(500).compactMap(\.title).sorted(), ["Alpha", "Beta"], "The merged-away work is back")
        XCTAssertEqual(try database.getWork(galleryId: 500, site: "keyed.example.org")?.title, "Alpha", "The saved work keeps its information")
        let beta = try XCTUnwrap(try rows(500).first { $0.site == nil })
        XCTAssertEqual(beta.artists, "artist b")
        XCTAssertEqual(try database.getWork(galleryId: 500)?.folders.map(\.name), ["Kept"])
        XCTAssertEqual(try rows(501).count, 1, "The same work saved since is not doubled")
        XCTAssertEqual(try rows(501).first?.site, "indexed.example.org")
        XCTAssertEqual(try rows(502).count, 1)
        XCTAssertEqual(try rows(503).map(\.title), ["Epsilon"])

        // Importing once more changes nothing.
        let count = try database.worksCount()
        _ = try importer.importUserDb(path: backup)
        XCTAssertEqual(try database.worksCount(), count)
    }

    /// Without anything to compare, a backup's number stays with the saved work, as before.
    func testABackupThatSaysNothingAboutAWorkStaysWithTheSavedOne() throws {
        _ = try database.upsertWork(galleryId: 600, title: "Saved", artists: "someone", site: "keyed.example.org")
        _ = try MangaViewerImportService(appDb: database).importUserDb(path: try violetBackup([(600, 1)]))
        XCTAssertEqual(try rows(600).count, 1)
    }

    // MARK: - Backups and sync

    func testBackupsKeepTwoWorksUnderOneNumber() throws {
        _ = try database.upsertWork(galleryId: 700, title: "Alpha", site: "indexed.example.org")
        _ = try database.upsertWork(galleryId: 700, title: "Beta", site: "keyed.example.org")
        let backup = try MangaBackup.capture(database)
        try backup.validate()
        let restored = try AppDatabase.inMemory()
        try restored.dbWriter.write { try backup.restore(in: $0) }
        XCTAssertEqual(Set(try restored.dbWriter.read { try WorkIdentity.rows($0, galleryId: 700) }.compactMap(\.title)), ["Alpha", "Beta"])
        // Restoring into the same library adds nothing.
        try database.dbWriter.write { try backup.restore(in: $0) }
        XCTAssertEqual(try rows(700).count, 2)
    }

    private func adapter() throws -> LibrarySyncAdapter {
        let suite = "identity.sync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults, booruDefaults: defaults)
    }

    private func exchange(_ a: LibrarySyncAdapter, _ b: LibrarySyncAdapter, _ la: inout LibrarySyncLedger, _ lb: inout LibrarySyncLedger) throws {
        la.capture(try a.snapshot(), device: "A"); lb.capture(try b.snapshot(), device: "B")
        la.merge(lb.changes); lb.merge(la.changes)
        try a.apply(la.changes); try b.apply(lb.changes)
        la.baseline = try a.snapshot(); lb.baseline = try b.snapshot()
    }

    func testSyncCarriesBothWorksUnderOneNumberAndTheirFolders() throws {
        let a = try adapter(), b = try adapter()
        let folder = try a.manga.createFolder(name: "Art")
        _ = try a.manga.upsertWork(galleryId: 800, folderId: folder.id, title: "Alpha", site: "indexed.example.org")
        _ = try a.manga.upsertWork(galleryId: 800, title: "Beta", site: "keyed.example.org")
        _ = try a.manga.upsertWork(galleryId: 801, title: "Unknown")
        var la = LibrarySyncLedger(), lb = LibrarySyncLedger()
        try exchange(a, b, &la, &lb)
        let synced = try b.manga.dbWriter.read { try WorkIdentity.rows($0, galleryId: 800) }
        XCTAssertEqual(Set(synced.map { "\($0.title ?? "")@\($0.site ?? "")" }), ["Alpha@indexed.example.org", "Beta@keyed.example.org"])
        XCTAssertEqual(try b.manga.getWork(galleryId: 800, site: "indexed.example.org")?.folders.map(\.name), ["Art"])
        XCTAssertEqual(try b.manga.getWork(galleryId: 801)?.title, "Unknown")
        // Older versions read one work per number: the number row is a work with a website.
        XCTAssertEqual(try a.snapshot().values.filter { $0.table == "manga.works" && $0.values["gallery_id"] == .integer(800) }.first?.values["site"], .text("indexed.example.org"))

        // Settled: nothing changes on another pass, and removing one leaves the other.
        let before = lb.changes
        lb.capture(try b.snapshot(), device: "B")
        XCTAssertEqual(lb.changes, before)
        try a.manga.deleteWork(galleryId: 800, site: "keyed.example.org")
        try exchange(a, b, &la, &lb)
        XCTAssertEqual(try b.manga.dbWriter.read { try WorkIdentity.rows($0, galleryId: 800) }.map(\.site), ["indexed.example.org"])
    }

    // MARK: - Matching

    func testTitlesAreComparedWithoutBracketsWidthOrPunctuation() {
        XCTAssertEqual(WorkMatcher.normalizedTitle("[Circle (Artist)] Title Here! (Series) [Korean] [Digital]"), "titlehere")
        XCTAssertEqual(WorkMatcher.normalizedTitle("［サークル］ タイトル　ＡＢＣ"), "タイトルabc")
        let first = WorkMatcher.fingerprint(titles: ["[Circle (Artist)] Title Here [Korean]"], artists: ["artist"], pages: 24)
        let second = WorkMatcher.fingerprint(titles: ["(C99) [Circle (Artist)] Title Here [Korean] [Digital]"], artists: ["Artist"], pages: 25)
        XCTAssertTrue(WorkMatcher.isSameWork(first, second))
        XCTAssertFalse(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ["Title Here"], artists: ["artist"], pages: 40)), "Page counts too far apart")
        XCTAssertFalse(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ["Title Here"], artists: ["someone else"], pages: 24)))
        XCTAssertTrue(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ["Title Here"], artists: [], pages: 0)), "Unknown artists and pages do not decide")
    }
}

/// Lists every connected website at once.
final class CombinedCatalogTests: XCTestCase {
    func testExploreListsTheWebsitesPickedInTheMenuAsImageModePicksServers() {
        let sites = ["one.example", "two.example", "three.example"]
        func listed(_ chosen: [String]?, active: String = "one.example") -> [String] { AppEnvironment.listedSites(sites, active: active, chosen: chosen) }
        XCTAssertEqual(listed(nil), ["one.example"], "Until someone picks, the checked website alone")
        XCTAssertEqual(listed(["two.example"], active: "three.example"), ["three.example"], "One picked website follows the checked one")
        XCTAssertEqual(listed(["one.example", "three.example"]), ["one.example", "three.example"])
        XCTAssertEqual(listed(["two.example", "three.example"]), sites, "The checked website is always among several")
        XCTAssertEqual(listed([]), [], "Every website can be unpicked")
        XCTAssertEqual(AppEnvironment.listedSites(["one.example"], active: "one.example", chosen: []), ["one.example"], "A single website has no menu")

        let added = AppEnvironment.toggling("three.example", listed: ["one.example"], sites: sites, active: "one.example")
        XCTAssertEqual(added.chosen, ["one.example", "three.example"]); XCTAssertNil(added.check)
        let removed = AppEnvironment.toggling("one.example", listed: ["one.example", "three.example"], sites: sites, active: "one.example")
        XCTAssertEqual(removed.chosen, ["three.example"])
        XCTAssertEqual(removed.check, "three.example", "Unpicking the checked website checks a listed one")
        let none = AppEnvironment.toggling("one.example", listed: ["one.example"], sites: sites, active: "one.example")
        XCTAssertEqual(none.chosen, []); XCTAssertNil(none.check)
    }

    private actor Source: ContentProviding {
        let works: [Int64: NativeGallery]
        let order: [Int64]
        var failure: Error?
        private(set) var listed = 0
        init(_ works: [NativeGallery], failure: Error? = nil) {
            self.works = Dictionary(uniqueKeysWithValues: works.map { ($0.id, $0) })
            order = works.map(\.id); self.failure = failure
        }
        func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
        func gallery(_ id: Int64) async throws -> NativeGallery {
            guard let work = works[id] else { throw ContentError.galleryNotFound }
            return work
        }
        func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
            if let failure { throw failure }
            listed += 1
            return GalleryBatch(ids: Array(order.dropFirst(offset).prefix(count)), hasMore: order.count > offset + count)
        }
        func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { Data() }
    }

    private static func work(_ id: Int64, _ title: String, artist: String = "artist", pages: Int = 20) -> NativeGallery {
        NativeGallery(id: id, title: title, artists: [artist], language: "korean", type: "manga", tags: [], pages: [], listedPageCount: pages)
    }

    func testWorksFromEveryWebsiteAreTakenInTurnAndTwinsAreLeftOut() async throws {
        let indexed = Source([Self.work(1, "[Circle (Artist)] Same Work [Korean]", pages: 30), Self.work(2, "Only Here"), Self.work(3, "Third")])
        let keyed = Source([Self.work(9001, "(C100) [Circle (Artist)] Same Work [Korean] [Digital]", pages: 31), Self.work(9002, "Elsewhere"), Self.work(2, "Different Work, Same Number")])
        let sources: [String: Source] = ["indexed.example.org": indexed, "keyed.example.org": keyed]
        let catalog = CombinedCatalog(pageSize: 2, sourceFor: { sources[$0]! }, sharesNumbers: { $0 == $1 })
        let sites = ["indexed.example.org", "keyed.example.org"]

        let first = try await catalog.list(GalleryQuery(), sites: sites, offset: 0, count: 3)
        XCTAssertEqual(first.items, [FeedItem(id: 1, site: "indexed.example.org"), FeedItem(id: 9002, site: "keyed.example.org"), FeedItem(id: 2, site: "indexed.example.org")],
                       "The second website's copy of the first work is left out")
        XCTAssertTrue(first.hasMore)
        let rest = try await catalog.list(GalleryQuery(), sites: sites, offset: 3, count: 10)
        XCTAssertEqual(rest.items, [FeedItem(id: 2, site: "keyed.example.org"), FeedItem(id: 3, site: "indexed.example.org")],
                       "The same number from a website that numbers works differently is another work")
        XCTAssertFalse(rest.hasMore)
        let leftOut = await catalog.leftOut
        XCTAssertEqual(leftOut, 1)

        // A page asked for again is answered again the same way.
        let again = try await catalog.list(GalleryQuery(), sites: sites, offset: 3, count: 10)
        XCTAssertEqual(again.items, rest.items)
    }

    func testWebsitesThatShareNumbersShowEachWorkOnce() async throws {
        let first = Source([Self.work(5, "One"), Self.work(6, "Two")])
        let second = Source([Self.work(5, "One, another title"), Self.work(7, "Three")])
        let sources: [String: Source] = ["a.example.org": first, "b.example.org": second]
        let catalog = CombinedCatalog(sourceFor: { sources[$0]! }, sharesNumbers: { _, _ in true })
        let batch = try await catalog.list(GalleryQuery(), sites: ["a.example.org", "b.example.org"], offset: 0, count: 10)
        XCTAssertEqual(batch.items.map(\.id), [5, 7, 6], "The second website gives its next work in place of the one already shown")
    }

    func testOneWebsiteFailingLeavesTheOthersShowing() async throws {
        let working = Source([Self.work(1, "One")])
        let failing = Source([], failure: ContentError.signInRequired)
        let sources: [String: Source] = ["a.example.org": working, "b.example.org": failing]
        let catalog = CombinedCatalog(sourceFor: { sources[$0]! }, sharesNumbers: { $0 == $1 })
        let batch = try await catalog.list(GalleryQuery(), sites: ["a.example.org", "b.example.org"], offset: 0, count: 10)
        XCTAssertEqual(batch.items, [FeedItem(id: 1, site: "a.example.org")])

        let none = CombinedCatalog(sourceFor: { _ in failing }, sharesNumbers: { $0 == $1 })
        do { _ = try await none.list(GalleryQuery(), sites: ["a.example.org", "b.example.org"], offset: 0, count: 10); XCTFail("Every website failing reports it") }
        catch ContentError.signInRequired {}
    }

    func testRequestsReadAnotherWebsitesSavedConnectionInsideItsScope() {
        let defaults = ContentPreferences.defaults
        let saved = defaults.dictionary(forKey: ScopedPreferences.snapshotsKey), address = defaults.string(forKey: "manga.site_address")
        defer {
            defaults.set(saved, forKey: ScopedPreferences.snapshotsKey); defaults.set(address, forKey: "manga.site_address")
        }
        defaults.set("indexed.example.org", forKey: "manga.site_address")
        defaults.set("https://indexed.example.org/", forKey: "manga.resolved_backend_site")
        defaults.set(["keyed.example.org": ["manga.resolved_backend_site": "https://keyed.example.org/", "manga.resolved_protocol": "keyed"]], forKey: ScopedPreferences.snapshotsKey)
        XCTAssertEqual(MangaUrls.home, "https://indexed.example.org/")
        SiteScope.$site.withValue("keyed.example.org") {
            XCTAssertEqual(MangaUrls.home, "https://keyed.example.org/")
            XCTAssertEqual(MangaUrls.preferences.string(forKey: "manga.resolved_protocol"), "keyed")
            MangaUrls.preferences.set("api.keyed.example.org", forKey: "manga.resolved_data_host")
        }
        XCTAssertNotEqual(defaults.string(forKey: "manga.resolved_data_host"), "api.keyed.example.org", "The checked website's connection is untouched")
        XCTAssertEqual((defaults.dictionary(forKey: ScopedPreferences.snapshotsKey)?["keyed.example.org"] as? [String: Any])?["manga.resolved_data_host"] as? String, "api.keyed.example.org")
    }
}
