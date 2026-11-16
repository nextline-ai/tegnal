import XCTest
import UIKit
@testable import TEGNAL

private actor DownloadFixture: ContentProviding {
    var calls = 0
    var shouldFail = false
    var failureCall: Int?
    let document: NativeGallery
    let data: Data
    init(document: NativeGallery, data: Data) { self.document = document; self.data = data }
    func fail(_ value: Bool) { shouldFail = value }
    func failOnCall(_ value: Int) { failureCall = value }
    func count() -> Int { calls }
    func gallery(_ id: Int64) async throws -> NativeGallery { document }
    func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { .init(ids: [], hasMore: false) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        calls += 1
        if shouldFail || failureCall == calls { throw URLError(.notConnectedToInternet) }
        return data
    }
}

@MainActor final class DownloadTests: XCTestCase {
    private func fixture() -> (NativeGallery, Data, URL) {
        let gallery = NativeGallery(id: 42, title: "Offline test", artists: [], language: "", type: "", tags: [],
                                    pages: [.init(hash: String(repeating: "a", count: 64), name: "../../unsafe.png", width: 4, height: 4, hasAVIF: false)])
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()!
        return (gallery, data, FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func finish(_ store: DownloadStore, status: WorkDownload.Status) async throws {
        for _ in 0..<200 {
            if store.items.first?.status == status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Download did not reach \(status)")
    }
    func testDownloadSurvivesRestartAndReadsWithoutNetwork() async throws {
        let (gallery, data, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DownloadFixture(document: gallery, data: data)
        let store = DownloadStore(directory: directory, manga: source)
        let id = store.enqueue(gallery)
        XCTAssertEqual(id, store.enqueue(gallery))
        try await finish(store, status: .completed)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].files, ["00001.png"])
        XCTAssertEqual(store.items[0].bytes, Int64(data.count))
        let restored = DownloadStore(directory: directory, manga: source)
        let item = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(item.status, .completed)
        await source.fail(true)
        let offline = DownloadedContentSource(item: item, folder: restored.folder(item))
        let local = try await offline.image(gallery.pages[0], galleryID: 42, thumbnail: false)
        XCTAssertEqual(local, data)
        restored.remove(id)
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.folder(item).path))
    }
    func testPauseBeforeStartPersistsAndResumeDownloads() async throws {
        let (gallery, data, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DownloadFixture(document: gallery, data: data)
        let store = DownloadStore(directory: directory, manga: source)
        let id = store.enqueue(gallery)
        store.pause(id)
        await Task.yield()
        let restored = DownloadStore(directory: directory, manga: source)
        XCTAssertEqual(restored.items.first?.status, .paused)
        restored.resume(id)
        try await finish(restored, status: .completed)
        let calls = await source.count()
        XCTAssertEqual(calls, 1)
    }
    func testFailureCanRetryAndModesDoNotCollide() async throws {
        let (gallery, data, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DownloadFixture(document: gallery, data: data)
        await source.fail(true)
        let store = DownloadStore(directory: directory, manga: source)
        let id = store.enqueue(gallery)
        try await finish(store, status: .failed)
        XCTAssertNotNil(store.items.first?.error)
        await source.fail(false)
        store.resume(id)
        try await finish(store, status: .completed)
        store.setBackground(true)
        for engine in BooruEngine.allCases {
            let server = BooruServer(name: engine.rawValue, baseURL: URL(string: "https://\(engine.rawValue).example")!, engine: engine)
            let post = BooruPost(serverID: server.id, postID: 42, width: 4, height: 4, tags: [], artists: [], rating: "s", score: 0, fileExtension: "png")
            let first = store.enqueue(post, server: server)
            XCTAssertEqual(first, store.enqueue(post, server: server))
        }
        XCTAssertEqual(store.items.filter { $0.mode == .manga }.count, 1)
        XCTAssertEqual(store.items.filter { $0.mode == .booru }.count, BooruEngine.allCases.count)
    }
    func testResumeKeepsCompletedPagesAndRepairsMissingFiles() async throws {
        let (first, data, directory) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = NativeGallery(id: first.id, title: first.title, artists: [], language: "", type: "", tags: [],
                                    pages: first.pages + [.init(hash: String(repeating: "b", count: 64), name: "second.png", width: 4, height: 4, hasAVIF: false)])
        let source = DownloadFixture(document: gallery, data: data)
        await source.failOnCall(2)
        let store = DownloadStore(directory: directory, manga: source)
        let id = store.enqueue(gallery)
        try await finish(store, status: .failed)
        XCTAssertEqual(store.items[0].files.count, 1)
        store.resume(id)
        try await finish(store, status: .completed)
        let calls = await source.count()
        XCTAssertEqual(calls, 3, "The completed first page must not be downloaded again")
        try FileManager.default.removeItem(at: store.urls(store.items[0])[0])
        let restored = DownloadStore(directory: directory, manga: source)
        XCTAssertEqual(restored.items[0].status, .paused)
        restored.resume(id)
        try await finish(restored, status: .completed)
        let repairedCalls = await source.count()
        XCTAssertEqual(repairedCalls, 4)
        XCTAssertEqual(restored.items[0].bytes, Int64(data.count * 2))
    }

    func testLocalSearchUsesTitleTagsArtistsIDsAndNormalizesQueries() throws {
        let (base, _, _) = fixture()
        let gallery = NativeGallery(id: base.id, title: "Café Moon", artists: ["Sample Artist"], language: "korean", type: "manga", tags: ["female:blue_hair", "night_sky"], pages: base.pages)
        let item = WorkDownload(key: "comic:42", mode: .manga, title: gallery.title, origin: "comics.example", gallery: gallery)
        XCTAssertTrue(item.matches("CAFE blue hair"))
        XCTAssertTrue(item.matches("night_sky Sample 42"))
        XCTAssertTrue(item.matches("korean manga"))
        XCTAssertTrue(item.matches("  "))
        XCTAssertFalse(item.matches("Moon missing_tag"))
        let restored = try JSONDecoder().decode(WorkDownload.self, from: JSONEncoder().encode(item))
        XCTAssertTrue(restored.matches("female:blue_hair"))
        let server = BooruServer(name: "Images", baseURL: URL(string: "https://images.example")!, engine: .danbooru)
        let post = BooruPost(serverID: server.id, postID: 123, width: 4, height: 4, tags: ["blue_hair", "night_sky"], artists: ["Some Artist"], rating: "s", score: 0, fileExtension: "png")
        let image = WorkDownload(key: "image:123", mode: .booru, title: "Images #123", origin: server.canonicalAddress, server: server, post: post)
        XCTAssertTrue(image.matches("123 BLUE_HAIR artist"))
        XCTAssertFalse(image.matches("42"))
    }

    func testHTMLIsNotAcceptedAsDownloadedImage() {
        XCTAssertThrowsError(try DownloadStore.imageExtension(Data("<html>Sign in</html>".utf8)))
    }

    func testNewDownloadsGoToTheFilesFolderUnderTheWorksName() async throws {
        let (gallery, data, directory) = fixture()
        let files = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-files")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: files) }
        let store = DownloadStore(directory: directory, manga: DownloadFixture(document: gallery, data: data))
        XCTAssertTrue(store.currentLocation.isFiles)
        store.enqueue(gallery)
        try await finish(store, status: .completed)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.location, DownloadLocation.files)
        XCTAssertEqual(item.path, L10n.text("Comics") + "/Offline test [42]")
        XCTAssertEqual(store.urls(item).first, files.appendingPathComponent(L10n.text("Comics") + "/Offline test [42]/00001.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.urls(item)[0].path))
        XCTAssertTrue(store.elsewhere.isEmpty)
        let restored = DownloadStore(directory: directory, manga: DownloadFixture(document: gallery, data: data))
        XCTAssertEqual(restored.items.first?.status, .completed)
        XCTAssertEqual(restored.urls(restored.items[0]), store.urls(item))
    }

    func testEarlierDownloadsMoveToTheCurrentLocationWithoutDownloadingAgain() async throws {
        let (gallery, data, directory) = fixture()
        let files = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-files")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: files) }
        // What 1.5.1 left: the record without a location, the files in a folder named by its id.
        let earlier = WorkDownload(key: "comics.example:42", mode: .manga, title: gallery.title, origin: "comics.example", gallery: gallery,
                                   status: .completed, files: ["00001.png"], bytes: Int64(data.count))
        let old = directory.appendingPathComponent(earlier.id.uuidString)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try data.write(to: old.appendingPathComponent("00001.png"))
        try JSONEncoder().encode([earlier]).write(to: directory.appendingPathComponent("downloads.json"))
        let source = DownloadFixture(document: gallery, data: data)
        let store = DownloadStore(directory: directory, manga: source)
        XCTAssertEqual(store.items.first?.status, .completed)
        XCTAssertNil(store.items.first?.location)
        XCTAssertEqual(store.movable.map(\.id), [earlier.id])
        await store.moveElsewhereHere()
        XCTAssertNil(store.locationError)
        XCTAssertNil(store.moving)
        let moved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(moved.location, DownloadLocation.files)
        XCTAssertEqual(try Data(contentsOf: store.urls(moved)[0]), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(store.movable.isEmpty)
        let calls = await source.count()
        XCTAssertEqual(calls, 0)
        let restored = DownloadStore(directory: directory, manga: source)
        XCTAssertEqual(restored.items.first?.status, .completed)
        XCTAssertEqual(restored.items.first?.location, DownloadLocation.files)
    }

    func testAChosenFolderTakesNewDownloadsAndKeepsEarlierOnesWhereTheyAre() async throws {
        let (gallery, data, directory) = fixture()
        let files = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-files")
        let chosen = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { for url in [directory, files, chosen] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let store = DownloadStore(directory: directory, manga: DownloadFixture(document: gallery, data: data))
        store.enqueue(gallery)
        try await finish(store, status: .completed)
        store.addFolder(chosen)
        XCTAssertNil(store.locationError)
        XCTAssertFalse(store.currentLocation.isFiles)
        XCTAssertEqual(store.currentLocation.name, chosen.lastPathComponent)
        XCTAssertEqual(store.movable.count, 1, "the earlier download stays until it is moved")
        let second = NativeGallery(id: 43, title: "Second: part/two", artists: [], language: "", type: "", tags: [], pages: gallery.pages)
        let secondStore = store
        secondStore.enqueue(second)
        for _ in 0..<200 where secondStore.items.first?.status != .completed { try await Task.sleep(for: .milliseconds(20)) }
        let item = try XCTUnwrap(secondStore.items.first { $0.gallery?.id == 43 })
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.location, store.currentLocation.id)
        XCTAssertEqual(item.path, L10n.text("Comics") + "/Second part two [43]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chosen.appendingPathComponent(item.path! + "/00001.png").path))
        store.setLocation(DownloadLocation.files)
        store.removeFolder(item.location!)
        XCTAssertEqual(store.locations.count, 2, "a folder still holding downloads is kept")
    }

    func testFolderNamesAvoidCharactersTheFilesAppRefuses() {
        XCTAssertEqual(DownloadStore.fileName("a/b:c\n.d", limit: 60), "a b c .d")
        XCTAssertEqual(DownloadStore.fileName("..hidden", limit: 60), "hidden")
        XCTAssertEqual(DownloadStore.fileName(" / ", limit: 60), "Download")
        XCTAssertEqual(DownloadStore.fileName(String(repeating: "가", count: 100), limit: 60).count, 60)
    }
}
