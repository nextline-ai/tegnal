import XCTest
import GRDB
@testable import TEGNAL

/// Every supported website numbers its works the same way: a number is one saved work.
final class OneWorkPerNumberTests: XCTestCase {
    /// Test builds briefly saved a number once per website. Their libraries fold back into one
    /// work per number, keeping the latest saved, and a folder holds each work once.
    func testTestBuildCopiesFoldIntoTheLatestSavedWork() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue, upTo: "v13_work_site")
        // The tables as those test builds left them.
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE works_identity (
                id INTEGER PRIMARY KEY AUTOINCREMENT, gallery_id INTEGER NOT NULL,
                title TEXT, artists TEXT, language TEXT, type TEXT, series TEXT, groups TEXT, tags TEXT, note TEXT,
                bookmarked_at TEXT NOT NULL, published_at TEXT, last_opened_at TEXT, updated_at TEXT, metadata_source TEXT,
                catalog_matched BOOLEAN NOT NULL DEFAULT 0, thumb_status TEXT NOT NULL DEFAULT 'missing', thumb_path TEXT,
                thumb_failed_at TEXT, thumb_page INTEGER DEFAULT 1, site TEXT);
            DROP TABLE works;
            ALTER TABLE works_identity RENAME TO works;
            CREATE UNIQUE INDEX idx_works_identity ON works(gallery_id, COALESCE(site, ''));
            DROP TABLE refresh_queue;
            CREATE TABLE refresh_queue (work_id INTEGER PRIMARY KEY NOT NULL);
            INSERT INTO folders (id, name, created_at) VALUES (10, 'A', '2024-01-01'), (11, 'B', '2024-01-01');
            INSERT INTO works (id, gallery_id, title, note, bookmarked_at, last_opened_at, site, thumb_status, thumb_path)
                VALUES (5, 100, 'Older', 'mine', '2024-01-01', '2024-03-01', 'one.example', 'ready', '/older.jpg'),
                       (6, 100, 'Newer', NULL, '2024-02-01', NULL, 'two.example', 'missing', NULL),
                       (7, 200, 'Alone', NULL, '2024-01-05', NULL, NULL, 'missing', NULL);
            INSERT INTO folder_works VALUES (10, 5, '2024-01-01'), (10, 6, '2024-02-01'), (11, 5, '2024-01-03'), (10, 7, '2024-01-05');
            INSERT INTO refresh_queue VALUES (5), (7);
            """)
        }
        try AppDatabase.migrator.migrate(queue)
        try queue.read { db in
            let works = try Row.fetchAll(db, sql: "SELECT * FROM works ORDER BY gallery_id")
            XCTAssertEqual(works.count, 2)
            let kept = works[0]
            XCTAssertEqual(kept["id"] as Int64, 6, "The latest saved copy stays")
            XCTAssertEqual(kept["title"] as String, "Newer")
            XCTAssertEqual(kept["note"] as String?, "mine", "What it lacked comes from the older copy")
            XCTAssertEqual(kept["last_opened_at"] as String?, "2024-03-01")
            XCTAssertEqual(kept["thumb_path"] as String?, "/older.jpg")
            XCTAssertEqual(kept["site"] as String?, "two.example")
            let links = try Row.fetchAll(db, sql: "SELECT folder_id, work_id, added_at FROM folder_works WHERE work_id = 6 ORDER BY folder_id")
            XCTAssertEqual(links.map { $0["folder_id"] as Int64 }, [10, 11], "The work stays in every folder it was in, once each")
            XCTAssertEqual(links.map { $0["added_at"] as String }, ["2024-02-01", "2024-01-03"], "A folder keeps the latest save")
            XCTAssertEqual(Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM refresh_queue")), [100, 200], "The refresh queue names numbers again")
            XCTAssertFalse(try db.indexes(on: "works").contains { $0.name == "idx_works_identity" })
        }
        try queue.write { db in
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO works (gallery_id, bookmarked_at, site) VALUES (100, '2024-04-01', 'three.example')"),
                                 "A number is one work again")
        }
    }

    func testALibraryWithoutTestBuildCopiesIsLeftAsItWas() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.upsertWork(galleryId: 1, title: "One", site: "one.example")
        _ = try database.upsertWork(galleryId: 1, title: "Again", site: "two.example")
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM works") }, 1, "Saving from another website is the same work")
        XCTAssertEqual(try database.getWork(galleryId: 1)?.site, "one.example", "It keeps the website it was first saved from")
    }

    /// A work may be in several folders, once in each; saving it again to a folder keeps the latest save.
    func testSavingAgainToAFolderKeepsTheLatestSave() throws {
        let database = try AppDatabase.inMemory()
        let first = try database.createFolder(name: "First"), second = try database.createFolder(name: "Second")
        _ = try database.upsertWork(galleryId: 3, folderId: first.id)
        try database.addWork(galleryId: 3, folderID: second.id!)
        let addedAt = { (folder: Int64) in try database.dbWriter.read { try String.fetchOne($0, sql: "SELECT added_at FROM folder_works WHERE folder_id = ?", arguments: [folder]) } }
        try database.dbWriter.write { try $0.execute(sql: "UPDATE folder_works SET added_at = '2000-01-01T00:00:00Z' WHERE folder_id = ?", arguments: [second.id]) }
        try database.addWork(galleryId: 3, folderID: second.id!)
        XCTAssertNotEqual(try addedAt(second.id!), "2000-01-01T00:00:00Z", "Saved again, it takes the newer date")
        XCTAssertEqual(try database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM folder_works WHERE work_id = (SELECT id FROM works WHERE gallery_id = 3)") }, 2,
                       "One link per folder")
    }
}

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
        NativeGallery(id: id, title: title, artists: [artist], language: "korean", type: "manga", tags: [], pages: [])
    }

    func testWorksFromEveryWebsiteAreTakenInTurnAndANumberIsShownOnce() async throws {
        let first = Source([Self.work(1, "One"), Self.work(2, "Two"), Self.work(3, "Three")])
        let second = Source([Self.work(9001, "Elsewhere"), Self.work(2, "Two, listed again"), Self.work(9002, "Also elsewhere")])
        let sources: [String: Source] = ["a.example.org": first, "b.example.org": second]
        let catalog = CombinedCatalog(pageSize: 2, sourceFor: { sources[$0]! })
        let sites = ["a.example.org", "b.example.org"]

        let page = try await catalog.list(GalleryQuery(), sites: sites, offset: 0, count: 3)
        XCTAssertEqual(page.items, [FeedItem(id: 1, site: "a.example.org"), FeedItem(id: 9001, site: "b.example.org"), FeedItem(id: 2, site: "a.example.org")])
        XCTAssertTrue(page.hasMore)
        let rest = try await catalog.list(GalleryQuery(), sites: sites, offset: 3, count: 10)
        XCTAssertEqual(rest.items, [FeedItem(id: 3, site: "a.example.org"), FeedItem(id: 9002, site: "b.example.org")],
                       "The second website's copy of a number already shown is left out")
        XCTAssertFalse(rest.hasMore)
        let leftOut = await catalog.leftOut
        XCTAssertEqual(leftOut, 1)

        // A page asked for again is answered again the same way.
        let again = try await catalog.list(GalleryQuery(), sites: sites, offset: 3, count: 10)
        XCTAssertEqual(again.items, rest.items)
    }

    func testAWorkSharedByTwoWebsitesShowsFromTheHigherOne() async throws {
        // The lower website reaches the shared work first in its own list.
        let higher = Source([Self.work(1, "One"), Self.work(7, "Shared")])
        let lower = Source([Self.work(7, "Shared, listed first"), Self.work(9001, "Elsewhere")])
        let sources: [String: Source] = ["a.example.org": higher, "b.example.org": lower]
        let catalog = CombinedCatalog(pageSize: 2, sourceFor: { sources[$0]! })
        let page = try await catalog.list(GalleryQuery(), sites: ["a.example.org", "b.example.org"], offset: 0, count: 10)
        XCTAssertEqual(page.items, [FeedItem(id: 1, site: "a.example.org"), FeedItem(id: 9001, site: "b.example.org"), FeedItem(id: 7, site: "a.example.org")],
                       "The higher website in Website Priority keeps the shared work")
        let swapped = CombinedCatalog(pageSize: 2, sourceFor: { sources[$0]! })
        let reversed = try await swapped.list(GalleryQuery(), sites: ["b.example.org", "a.example.org"], offset: 0, count: 10)
        XCTAssertEqual(reversed.items.first { $0.id == 7 }?.site, "b.example.org", "Changing the order changes which copy shows")
    }

    func testWebsitePriorityReordersTheConnectedWebsites() {
        let defaults = ContentPreferences.defaults
        defaults.set(["a.example.org", "b.example.org", "c.example.org"], forKey: "manga.sites")
        defer { defaults.removeObject(forKey: "manga.sites") }
        ComicSites.reorder(["c.example.org", "a.example.org"])
        XCTAssertEqual(Array(ComicSites.all.prefix(3)), ["c.example.org", "a.example.org", "b.example.org"], "A site the order leaves out keeps its place at the end")
    }

    func testFavoritesSyncFollowsTheSideThatChanged() {
        let first = FavoriteSyncPlan.make(local: [1], remote: [1, 2, 3], base: nil)
        XCTAssertEqual(first.addLocally, [2, 3], "The first sync brings the website's favorites into the folder")
        XCTAssertEqual(first.addOnSite, [], "A work already on both sides needs nothing")
        XCTAssertEqual(first.removeLocally + first.removeFromSite, [], "The first sync never removes")
        XCTAssertEqual(first.settled, [1, 2, 3])

        let plan = FavoriteSyncPlan.make(local: [1, 2, 4], remote: [1, 3, 5], base: [1, 2, 3])
        XCTAssertEqual(plan.addLocally, [5], "Added on the website")
        XCTAssertEqual(plan.removeLocally, [2], "Removed on the website")
        XCTAssertEqual(plan.addOnSite, [4], "Added to the folder")
        XCTAssertEqual(plan.removeFromSite, [3], "Removed from the folder")
        XCTAssertEqual(plan.settled, [1, 4, 5])

        let push = FavoriteSyncPlan.make(local: [1, 4], remote: [1, 2], base: [1, 2])
        XCTAssertEqual(push.addOnSite, [4])
        XCTAssertEqual(push.removeFromSite, [2])
        XCTAssertTrue(push.addLocally.isEmpty && push.removeLocally.isEmpty, "Sending changes alone never changes the folder")
        XCTAssertTrue(FavoriteSyncPlan.make(local: [1, 2], remote: [1, 2], base: [1, 2]).isEmpty)
    }

    func testFavoriteFoldersRememberLinksBaselinesAndATurnedOffSync() {
        let defaults = UserDefaults(suiteName: "site-favorites-\(UUID().uuidString)")!
        let folders = SiteFavoriteFolders(defaults: defaults)
        XCTAssertNil(folders.folder(for: "a.example.org"))
        folders.link("a.example.org", folder: "folder-1")
        XCTAssertEqual(folders.folder(for: "a.example.org"), "folder-1")
        XCTAssertNil(folders.baseline(for: "a.example.org"), "A new link has no baseline, so nothing is removed on its first sync")
        folders.setBaseline([3, 1], for: "a.example.org")
        XCTAssertEqual(SiteFavoriteFolders(defaults: defaults).baseline(for: "a.example.org"), [1, 3])
        folders.unlink("a.example.org", declined: true)
        XCTAssertNil(folders.folder(for: "a.example.org"))
        XCTAssertNil(folders.baseline(for: "a.example.org"))
        XCTAssertTrue(folders.isDeclined("a.example.org"), "Turned off by hand, it is not set up again on its own")
        folders.link("a.example.org", folder: "folder-2")
        XCTAssertFalse(folders.isDeclined("a.example.org"), "Turning it back on clears that")
    }

    func testOneWebsiteFailingLeavesTheOthersShowing() async throws {
        let working = Source([Self.work(1, "One")])
        let failing = Source([], failure: ContentError.signInRequired)
        let sources: [String: Source] = ["a.example.org": working, "b.example.org": failing]
        let catalog = CombinedCatalog(sourceFor: { sources[$0]! })
        let batch = try await catalog.list(GalleryQuery(), sites: ["a.example.org", "b.example.org"], offset: 0, count: 10)
        XCTAssertEqual(batch.items, [FeedItem(id: 1, site: "a.example.org")])

        let none = CombinedCatalog(sourceFor: { _ in failing })
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
