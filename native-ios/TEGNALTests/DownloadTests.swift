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
}
