import XCTest
import UIKit
import WebKit
@testable import TEGNAL

final class DocumentCatalogTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site",
                        "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base", "reader_page_2000"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = MangaUrls.preferences.object(forKey: key) }
        MangaUrls.resetResolvedBackend()
        MangaUrls.preferences.set("catalog.example", forKey: "manga.site_address")
    }
    override func tearDown() {
        CatalogFixtureProtocol.install(nil)
        RetryingCatalogProtocol.install(nil)
        for key in keys { MangaUrls.preferences.set(saved[key], forKey: key) }
        super.tearDown()
    }
    private func fixture() -> CatalogFixture {
        let fixture = CatalogFixture()
        CatalogFixtureProtocol.install(fixture)
        return fixture
    }

    func testShortReaderLinksAndWrappedLinksKeepTheNumericIdentity() {
        XCTAssertEqual(GalleryIDParser.parse("https://catalog.example/r/2000#2"), [2000])
        XCTAssertEqual(GalleryIDParser.parse("https://archive.example/reader/2000.html#2"), [2000])
        XCTAssertEqual(GalleryIDParser.parse("https://share.example/?u=https%3A%2F%2Fcatalog.example%2Fr%2F2000%232"), [2000])
        XCTAssertEqual(ContentRoute.initial("https://catalog.example/r/2000#2"), .reader(2000, 2))
        XCTAssertEqual(ContentRoute.initial("https://catalog.example/?search=artist%3Asample"), .query("artist:sample"))
        XCTAssertNil(ContentRoute.initial("https://foreign.example/r/2000#2"))
    }

    func testDiscoveryAndLinksFollowTheConfiguredProtocol() async throws {
        let fixture = fixture()
        let source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(MangaUrls.backend, .document)
        XCTAssertEqual(MangaUrls.galleryUrl(for: 2000), "https://catalog.example/r/2000")
        XCTAssertEqual(MangaUrls.readerUrl(for: 2000, page: 3), "https://catalog.example/r/2000#3")
        XCTAssertEqual(ContentRoute.configuredURL(URL(string: "https://catalog.example/reader/2000.html#3")!).absoluteString,
                       "https://catalog.example/r/2000#3")
        XCTAssertEqual(ContentRoute.initial(MangaUrls.artistAllUrl(for: "sample artist")), .query("artist:sample_artist"))
        XCTAssertEqual(fixture.count("/"), 1)
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://preview.example/0/2/0.jpg")!))
        MangaUrls.preferences.set("archive.example", forKey: "manga.site_address")
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        XCTAssertEqual(MangaUrls.readerUrl(for: 2000, page: 3), "https://archive.example/reader/2000.html#3")
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://preview.example/0/2/0.jpg")!))
    }

    func testSearchPreviewsAvoidFetchingEveryFullDocument() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let batch = try await source.list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(batch.ids, [2000, 1999])
        let preview = try XCTUnwrap(source.cachedPreview(2000))
        XCTAssertNil(source.cachedGallery(2000), "A search preview must never seed a reader with an incomplete page list")
        XCTAssertEqual(preview.title, "Sample {book}")
        let bytes = try await source.image(preview.pages[0], galleryID: 2000, thumbnail: true)
        XCTAssertEqual(bytes, fixture.image)
        XCTAssertEqual(fixture.count("/r/2000"), 0)
        let full = try await source.gallery(2000)
        XCTAssertEqual(full.pages.count, 2)
        XCTAssertEqual(source.cachedGallery(2000)?.pages.count, 2)
        XCTAssertEqual(full.artists, ["sample_artist"])
        XCTAssertEqual(full.language, "korean")
        XCTAssertTrue(full.tags.contains("series:sample_series"))
        XCTAssertTrue(full.tags.contains("tag:sample_tag"))
        XCTAssertEqual(fixture.count("/r/2000"), 1)
    }

    func testPaginationReusesBufferedResultsAndThenFollowsTheCursor() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(), offset: 0, count: 2)
        let second = try await source.list(GalleryQuery(), offset: 2, count: 2)
        XCTAssertEqual(second.ids, [1998, 1997])
        XCTAssertEqual(fixture.count("/ajax/search"), 2)
        let next = try await source.list(GalleryQuery(), offset: 48, count: 4)
        XCTAssertEqual(next.ids, [1952, 1951, 1950, 1949])
        XCTAssertEqual(fixture.count("/ajax/search"), 3)
        XCTAssertTrue(fixture.requests.contains { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "next-id", value: "1951")) == true })
    }

    func testVisualCollectionsBypassImplicitLanguageButRetainTypesAndRanking() async throws {
        let fixture = fixture(); fixture.visualCollections = true
        let source = MangaContentSource(transport: fixture.transport())
        let latest = try await source.list(GalleryQuery(), offset: 0, count: 5)
        XCTAssertEqual(latest.ids, [2003, 2002, 2001, 2000, 1999])
        let popular = try await source.list(GalleryQuery(sort: .week), offset: 0, count: 5)
        XCTAssertEqual(popular.ids, latest.ids)
        let onlyManga = try await source.list(GalleryQuery(text: "type:manga"), offset: 0, count: 2)
        XCTAssertEqual(onlyManga.ids, [2000, 1999])
        let onlyVisual = try await source.list(GalleryQuery(text: "type:gamecg"), offset: 0, count: 5)
        XCTAssertEqual(onlyVisual.ids, [2002])
        let visualRequests = fixture.requests.filter { $0.path == "/ajax/search" }.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
            .filter { $0.contains { $0.name == "categories" && $0.value == "3,4,6" } }
        XCTAssertFalse(visualRequests.isEmpty)
        XCTAssertTrue(visualRequests.allSatisfy { !$0.contains { $0.name == "search" && ($0.value ?? "").contains("language:korean") } })
    }

    func testFiltersAndSuggestionsTranslateNamespacesWithoutChangingTheirLocalForm() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let query = GalleryQuery(language: "korean", artist: "sample artist", text: "series:sample -tag:excluded type:manga", sort: .week)
        let url = try DocumentCatalogSource.searchURL(query, site: MangaUrls.home, now: Date(timeIntervalSince1970: 1_800_000_000))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let search = try XCTUnwrap(items.first { $0.name == "search" }?.value)
        XCTAssertTrue(search.contains("parody:sample"))
        XCTAssertTrue(search.contains("-other:excluded"))
        XCTAssertTrue(search.contains("artist:sample_artist"))
        XCTAssertTrue(items.contains(.init(name: "categories", value: "2")))
        XCTAssertTrue(items.contains { $0.name == "start-date" })
        let suggestions = try await source.suggestions(for: "series:sam")
        XCTAssertEqual(suggestions, [.init(namespace: "series", name: "sample_series", count: nil)])
    }

    func testEmbeddedJSONHandlesEscapesAndDoesNotExecuteFollowingScripts() throws {
        let fixture = fixture()
        let parsed = try DocumentCatalogSource.parseGallery(fixture.document(2000), id: 2000, site: MangaUrls.home)
        XCTAssertEqual(parsed.title, "Sample {book}")
        XCTAssertEqual(parsed.pages.map(\.index), [0, 1])
        XCTAssertEqual(parsed.pages[0].hash.count, 64)
        XCTAssertThrowsError(try DocumentCatalogSource.parseGallery(fixture.document(2000), id: 1999, site: MangaUrls.home))
        XCTAssertThrowsError(try DocumentCatalogSource.parseGallery(Data("<script>const gallery = execute();</script>".utf8), id: 2000, site: MangaUrls.home))
    }

    func testExpiredPageAddressesRefreshOnceForTheWholeGallery() async throws {
        let fixture = fixture()
        fixture.expireFirstManifest = true
        let source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(2000)
        for page in gallery.pages {
            let bytes = try await source.image(page, galleryID: 2000, thumbnail: false)
            XCTAssertEqual(bytes, fixture.image)
        }
        XCTAssertEqual(fixture.count("/r/2000"), 2)
        XCTAssertFalse(fixture.requests.contains { $0.query?.contains("expires=1&") == true })
    }

    @MainActor func testChangingTheAddressPreservesBookmarksNotesAndReadingPosition() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let suite = "catalog-switch-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let database = try AppDatabase.inMemory()
        let env = AppEnvironment(database: database, browserPreferences: preferences)
        XCTAssertTrue(env.verifySite(input: "catalog.example"))
        let gallery = try await source.gallery(2000)
        let work = try database.upsertWork(galleryId: gallery.id, title: "Saved title")
        try database.setNote(galleryId: gallery.id, note: "Keep this note")
        MangaUrls.preferences.set(7, forKey: "reader_page_2000")
        XCTAssertTrue(env.verifySite(input: "archive.example"))
        XCTAssertNil(source.cachedGallery(2000))
        let switched = try await source.gallery(2000)
        XCTAssertEqual(switched.id, gallery.id)
        XCTAssertEqual(switched.title, "Indexed sample")
        XCTAssertEqual(try database.getWork(galleryId: 2000)?.id, work.id)
        XCTAssertEqual(try database.getWork(galleryId: 2000)?.note, "Keep this note")
        XCTAssertEqual(MangaUrls.preferences.integer(forKey: "reader_page_2000"), 7)
        XCTAssertEqual(try database.listWorks().count, 1)
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://media.example/page.webp")!))
        let returned = env.verifySite(input: "catalog.example")
        XCTAssertTrue(returned)
        let restored = try await source.gallery(2000)
        XCTAssertEqual(restored.title, "Sample {book}")
    }

    func testOldDownloadsDecodeWithoutOptionalNetworkDescriptors() throws {
        let data = Data(#"{"hash":"abc","name":"1.jpg","width":1,"height":2,"hasAVIF":false}"#.utf8)
        let page = try JSONDecoder().decode(GalleryPage.self, from: data)
        XCTAssertNil(page.imageURL)
        XCTAssertNil(page.index)
        XCTAssertNil(page.sourceSite)
    }

    func testMediaDiscoveryRejectsLocalAndCredentialBearingAddresses() {
        for value in ["http://media.example/1", "https://127.0.0.1/1", "https://files.local/1", "https://user:pass@media.example/1", "https://media.example:9443/1"] {
            XCTAssertFalse(DocumentCatalogSource.safeMediaURL(URL(string: value)!), value)
        }
        XCTAssertTrue(DocumentCatalogSource.safeMediaURL(URL(string: "https://media.example/page.webp?expires=1")!))
    }

    func testInterruptedBrowserRequestRecoversAndReusesTheWorkingTransport() async throws {
        let fixture = RetryingCatalogFixture(directFailures: [.secureConnectionFailed, .secureConnectionFailed],
                                             browserFailures: [URLError(.networkConnectionLost)])
        let transport = fixture.transport(), url = URL(string: MangaUrls.home + "ajax/search")!
        let (data, _) = try await transport.get(url, limit: 1024)
        XCTAssertEqual(data, fixture.payload)
        XCTAssertEqual(fixture.counts.direct, 2)
        XCTAssertEqual(fixture.counts.browser, 2)
        _ = try await transport.get(url, limit: 1024)
        XCTAssertEqual(fixture.counts.direct, 2, "A successful browser connection must be reused")
        XCTAssertEqual(fixture.counts.browser, 3)
    }

    func testTimedOutOriginCanRecoverThroughTheBrowser() async throws {
        let fixture = RetryingCatalogFixture(directFailures: [.timedOut])
        let (data, _) = try await fixture.transport().get(URL(string: MangaUrls.home + "ajax/search")!, limit: 1024)
        XCTAssertEqual(data, fixture.payload)
        XCTAssertEqual(fixture.counts.direct, 1)
        XCTAssertEqual(fixture.counts.browser, 1)
    }

    func testTerminatedWebProcessIsRetryable() async throws {
        let fixture = RetryingCatalogFixture(directFailures: [.secureConnectionFailed, .secureConnectionFailed],
            browserFailures: [NSError(domain: WKError.errorDomain, code: WKError.webContentProcessTerminated.rawValue)])
        _ = try await fixture.transport().get(URL(string: MangaUrls.home)!, limit: 1024)
        XCTAssertEqual(fixture.counts.browser, 2)
    }

    func testPersistentConnectionFailureHasABoundedRetryCount() async {
        let fixture = RetryingCatalogFixture(directFailures: Array(repeating: .secureConnectionFailed, count: 3),
            browserFailures: Array(repeating: URLError(.networkConnectionLost), count: 3))
        do {
            _ = try await fixture.transport().get(URL(string: MangaUrls.home)!, limit: 1024)
            XCTFail("A persistent failure must be returned after the retry budget")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(fixture.counts.direct, 3)
        XCTAssertEqual(fixture.counts.browser, 3)
    }

    func testCertificateRejectionAndHTTPFailuresAreNotRetried() async {
        let certificate = RetryingCatalogFixture(directFailures: [.serverCertificateUntrusted])
        do {
            _ = try await certificate.transport().get(URL(string: MangaUrls.home)!, limit: 1024)
            XCTFail("Certificate validation must remain enforced")
        } catch { XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted) }
        XCTAssertEqual(certificate.counts.direct, 1)
        XCTAssertEqual(certificate.counts.browser, 0)
        for status in [403, 404, 429, 500] {
            let fixture = RetryingCatalogFixture(status: status)
            do {
                _ = try await fixture.transport().get(URL(string: MangaUrls.home)!, limit: 1024)
                XCTFail("HTTP failures must be reported")
            } catch ContentError.unavailable(let received) { XCTAssertEqual(received, status) }
            catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(fixture.counts.direct, 1)
            XCTAssertEqual(fixture.counts.browser, 0)
        }
    }

    func testCancellationStopsPendingConnectionRetries() async {
        let first = expectation(description: "The initial browser request failed")
        let fixture = RetryingCatalogFixture(directFailures: [.secureConnectionFailed], browserFailures: [URLError(.networkConnectionLost)])
        fixture.onBrowserRequest = { first.fulfill() }
        let transport = fixture.transport(), url = URL(string: MangaUrls.home)!
        let task = Task { try await transport.get(url, limit: 1024) }
        await fulfillment(of: [first], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled work must not retry") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(fixture.counts.direct, 1)
        XCTAssertEqual(fixture.counts.browser, 1)
    }

    func testChangingTheSiteStopsPendingConnectionRetries() async {
        let fixture = RetryingCatalogFixture(directFailures: [.secureConnectionFailed], browserFailures: [URLError(.networkConnectionLost)])
        fixture.onBrowserRequest = { MangaUrls.preferences.set("other.example", forKey: "manga.site_address") }
        do {
            _ = try await fixture.transport().get(URL(string: MangaUrls.home)!, limit: 1024)
            XCTFail("A previous site's request must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.counts.direct, 1)
        XCTAssertEqual(fixture.counts.browser, 1)
    }

    func testConfiguredLiveCatalog() async throws {
        guard let address = ProcessInfo.processInfo.environment["TEGNAL_CATALOG_ADDRESS"], let url = URL(string: address), let host = url.host else {
            throw XCTSkip("An explicit catalog address is required for live verification")
        }
        let detected = try await ServerType.detect(at: url)
        XCTAssertEqual(detected, .comics)
        XCTAssertEqual(MangaUrls.configuredHost, "catalog.example", "Address detection must not change the saved connection")
        MangaUrls.preferences.set(host, forKey: "manga.site_address")
        let source = MangaContentSource()
        let batch = try await source.list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertFalse(batch.ids.isEmpty)
        XCTAssertEqual(MangaUrls.backend, .document)
        let firstID = try XCTUnwrap(batch.ids.first)
        let preview = try XCTUnwrap(source.cachedPreview(firstID))
        let previewBytes = try await source.image(preview.pages[0], galleryID: firstID, thumbnail: true)
        let previewDecodes = await MainActor.run { UIImage(data: previewBytes) != nil }
        XCTAssertTrue(previewDecodes)
        let id = ProcessInfo.processInfo.environment["TEGNAL_SHARED_GALLERY_ID"].flatMap(Int64.init) ?? firstID
        let gallery = try await source.gallery(id)
        XCTAssertEqual(gallery.id, id)
        XCTAssertFalse(gallery.pages.isEmpty)
        let image = try await source.image(gallery.pages[0], galleryID: id, thumbnail: true)
        XCTAssertGreaterThan(image.count, 32)
        let fullPage = try await source.image(gallery.pages[0], galleryID: id, thumbnail: false)
        let pageDecodes = await MainActor.run { UIImage(data: fullPage) != nil }
        XCTAssertTrue(pageDecodes)
        if let reference = ProcessInfo.processInfo.environment["TEGNAL_REFERENCE_ADDRESS"], let referenceURL = URL(string: reference), let referenceHost = referenceURL.host {
            let referenceType = try await ServerType.detect(at: referenceURL)
            XCTAssertEqual(referenceType, .comics)
            MangaUrls.preferences.set(referenceHost, forKey: "manga.site_address")
            MangaUrls.resetResolvedBackend()
            let counterpart = try await source.gallery(id)
            XCTAssertEqual(counterpart.id, gallery.id)
            XCTAssertEqual(counterpart.pages.count, gallery.pages.count)
            let referenceImage = try await source.image(counterpart.pages[0], galleryID: id, thumbnail: true)
            XCTAssertGreaterThan(referenceImage.count, 32)
            // Titles and image encoding differ between catalogs. Compare the
            // actual cover as well as the page count to verify the shared ID.
            let signatures = await MainActor.run { (Self.coverSignature(image), Self.coverSignature(referenceImage)) }
            let first = try XCTUnwrap(signatures.0), second = try XCTUnwrap(signatures.1)
            let difference = zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(first.count * 255)
            XCTAssertLessThan(difference, 0.12, "The shared numeric ID must identify the same cover on both servers")
        }
    }

    @MainActor private static func coverSignature(_ data: Data) -> [UInt8]? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16 * 16)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        return drawn ? bytes : nil
    }
}

private final class RetryingCatalogFixture: @unchecked Sendable {
    let payload = Data("[]".utf8)
    private let lock = NSLock()
    private var directFailures: [URLError.Code]
    private var browserFailures: [Error]
    private var directCount = 0
    private var browserCount = 0
    private let status: Int
    var onBrowserRequest: (@Sendable () -> Void)?
    var counts: (direct: Int, browser: Int) { lock.withLock { (directCount, browserCount) } }

    init(directFailures: [URLError.Code] = [], browserFailures: [Error] = [], status: Int = 200) {
        self.directFailures = directFailures
        self.browserFailures = browserFailures
        self.status = status
    }

    func transport() -> ContentTransport {
        RetryingCatalogProtocol.install(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryingCatalogProtocol.self]
        return ContentTransport(configuration: configuration, browserFetch: { [self] url, _, _, _, _ in
            let failure = lock.withLock { browserCount += 1; return browserFailures.isEmpty ? nil : browserFailures.removeFirst() }
            onBrowserRequest?()
            if let failure { throw failure }
            return response(url)
        })
    }

    func reply(_ url: URL) throws -> (Data, HTTPURLResponse) {
        let failure = lock.withLock { directCount += 1; return directFailures.isEmpty ? nil : directFailures.removeFirst() }
        if let failure { throw URLError(failure) }
        return response(url)
    }
    private func response(_ url: URL) -> (Data, HTTPURLResponse) {
        (payload, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

private final class RetryingCatalogProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixture: RetryingCatalogFixture?
    static func install(_ fixture: RetryingCatalogFixture?) { lock.withLock { Self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.lock.withLock({ Self.fixture }) else { throw URLError(.cancelled) }
            let (data, response) = try fixture.reply(request.url!)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class CatalogFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var expireFirstManifest = false
    var visualCollections = false
    let image = Data(repeating: 0x42, count: 64)
    var requests: [URL] { lock.withLock { recorded } }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func transport() -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureProtocol.self]
        return ContentTransport(configuration: configuration)
    }
    private func row(_ id: Int64) -> [String: Any] {
        ["id": id, "title": "Sample {book}", "title_jpn": NSNull(), "category": 2, "views": id * 10, "blocked": 0,
         "thumb_extension": "jpg", "tags": [["tag": ["language", "korean"]], ["tag": ["artist", "sample_artist"]],
                                                   ["tag": ["parody", "sample_series"]], ["tag": ["other", "sample_tag"]]]]
    }
    func document(_ id: Int64) -> Data {
        var object = row(id)
        let expiry = expireFirstManifest && count("/r/\(id)") == 1 ? 1 : 4_102_444_800
        object["files"] = (0..<2).map { index -> [String: Any] in
            ["id": "file-\(index)", "name": "\(index).jpg",
             "image": ["url": "https://media.example/\(index).webp?expires=\(expiry)&version=\(expiry)", "width": 100, "height": 150],
             "thumbnail": ["url": "https://media.example/\(index).jpg?expires=\(expiry)&version=\(expiry)"]]
        }
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return Data("<script>const gallery = \(json); ignoredFunction();</script>".utf8)
    }
    func reply(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        let url = request.url!
        lock.withLock { recorded.append(url) }
        if url.host == "media.example" || url.host == "preview.example" { return (200, image, ["Content-Type": "image/webp"]) }
        if url.host == "archive.example" && url.path == "/" { return (200, Data("const domain = 'files.example';".utf8), [:]) }
        if url.host == "ltn.files.example", url.path == "/galleries/2000.js" {
            return (200, Data("var galleryinfo = {\"title\":\"Indexed sample\",\"files\":[{\"hash\":\"\(String(repeating: "a", count: 64))\",\"name\":\"0.jpg\"},{\"hash\":\"\(String(repeating: "b", count: 64))\",\"name\":\"1.jpg\"}]};".utf8), [:])
        }
        guard url.host == "catalog.example" else { return (404, Data(), [:]) }
        switch url.path {
        case "/": return (200, Data(#"<script src="/js/index.search.tail.js"></script><script>const serverConfig = { thumbServer: {"url":"https://preview.example"} };</script>"#.utf8), [:])
        case "/ajax/search":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let cursor = items.first { $0.name == "next-id" || $0.name == "next-views-id" }?.value.flatMap(Int64.init)
            let start = cursor.map { $0 - 1 } ?? 2000
            let categories = Set((items.first { $0.name == "categories" }?.value ?? "2").split(separator: ",").compactMap { Int($0) })
            var rows = categories.contains(2) ? stride(from: start, through: max(1901, start - 49), by: -1).map(row) : []
            if visualCollections {
                for (id, category) in [(Int64(2003), 3), (2002, 4), (2001, 6)] where categories.contains(category) && (cursor == nil || id < cursor!) {
                    var visual = row(id); visual["category"] = category
                    visual["tags"] = [["tag": ["artist", "sample_artist"]]]
                    rows.append(visual)
                }
            }
            rows.sort { ($0["id"] as! Int64) > ($1["id"] as! Int64) }
            return (200, try JSONSerialization.data(withJSONObject: rows), ["Content-Type": "application/json"])
        case "/ajax/search-tags": return (200, Data(#"["parody:sample_series"]"#.utf8), ["Content-Type": "application/json"])
        default:
            if url.path.hasPrefix("/r/"), let id = Int64(url.lastPathComponent) { return (200, document(id), ["Content-Type": "text/html"]) }
            return (404, Data(), [:])
        }
    }
}

private final class CatalogFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixture: CatalogFixture?
    static func install(_ fixture: CatalogFixture?) { lock.withLock { Self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.lock.withLock({ Self.fixture }) else { throw URLError(.cancelled) }
            let (status, data, headers) = try fixture.reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
