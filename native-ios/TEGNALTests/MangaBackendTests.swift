import XCTest
@testable import TEGNAL

final class MangaBackendTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        MangaUrls.resetResolvedBackend()
    }
    override func tearDown() {
        BackendFixtureProtocol.install(nil)
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        super.tearDown()
    }
    private func fixture() -> BackendFixture {
        let fixture = BackendFixture()
        UserDefaults.standard.set(fixture.host, forKey: "manga.site_address")
        BackendFixtureProtocol.install(fixture)
        return fixture
    }

    func testFirstListAndMetadataDiscoverTheCustomSitesScriptOnlyOnce() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        async let list = source.list(GalleryQuery(), offset: 0, count: 2)
        async let gallery = source.gallery(1234)
        let (batch, work) = try await (list, gallery)
        XCTAssertEqual(batch.ids, [1234, 5678])
        XCTAssertEqual(work.id, 1234)
        XCTAssertEqual(fixture.count(path: "/"), 1)
        XCTAssertEqual(fixture.count(path: "/assets/common.js"), 1)
        XCTAssertEqual(fixture.count(host: "ltn." + fixture.host), 0, "Resolve the script before requesting the old derived host")
        XCTAssertEqual(MangaUrls.dataHost, "ltn." + fixture.domain)
        XCTAssertEqual(MangaUrls.cdnHost, fixture.domain)
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://w1." + fixture.domain + "/image.webp")!))
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://unrelated.example/gg.js")!))
    }

    func testSavedEndpointsSurviveNewSourcesWithoutRediscovery() async throws {
        let fixture = fixture()
        _ = try await MangaContentSource(transport: fixture.transport()).list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "manga.resolved_backend_site"), MangaUrls.home)
        for _ in 0..<3 {
            let freshSource = MangaContentSource(transport: fixture.transport())
            let gallery = try await freshSource.gallery(1234)
            XCTAssertFalse(gallery.pages.isEmpty)
        }
        XCTAssertTrue(MangaUrls.hasResolvedBackend)
        XCTAssertEqual(fixture.count(path: "/"), 1)
        XCTAssertEqual(fixture.count(path: "/assets/common.js"), 1)
    }

    func testFailedSavedEndpointRefreshesThenRetriesTheOriginalRequest() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(), offset: 0, count: 2)
        let previous = MangaUrls.dataHost
        fixture.advanceDomain()
        let gallery = try await source.gallery(1234)
        XCTAssertEqual(gallery.id, 1234)
        XCTAssertNotEqual(MangaUrls.dataHost, previous)
        XCTAssertEqual(MangaUrls.dataHost, "ltn." + fixture.domain)
        XCTAssertEqual(fixture.count(path: "/"), 2)
        XCTAssertEqual(fixture.count(path: "/assets/common.js"), 2)
        _ = try await MangaContentSource(transport: fixture.transport()).list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(fixture.count(path: "/"), 2)
    }

    func testImageConnectionFailureRefreshesTheSavedCDNOnlyWhenNeeded() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(1234)
        _ = try await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true)
        XCTAssertEqual(fixture.count(path: "/"), 1)
        fixture.advanceDomain()
        _ = try await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true)
        XCTAssertEqual(fixture.count(path: "/"), 2)
        XCTAssertEqual(MangaUrls.cdnHost, fixture.domain)
        _ = try await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true)
        XCTAssertEqual(fixture.count(path: "/"), 2)
    }

    func testRemovedWorkDoesNotTriggerBackendRefresh() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(), offset: 0, count: 2)
        do { _ = try await source.gallery(9999); XCTFail("Missing work must fail") }
        catch ContentError.unavailable(404) { }
        XCTAssertEqual(fixture.count(path: "/"), 1)
        XCTAssertTrue(MangaUrls.hasResolvedBackend)
    }

    func testSiteChangeCannotReuseOrAcceptThePreviousSitesEndpoints() async throws {
        let fixture = fixture()
        await MangaUrls.resolveBackend(transport: fixture.transport())
        let original = MangaUrls.home
        UserDefaults.standard.set("another-comics.example", forKey: "manga.site_address")
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        XCTAssertEqual(MangaUrls.dataHost, "ltn.another-comics.example")
        XCTAssertEqual(MangaUrls.cdnHost, "another-comics.example")
        XCTAssertFalse(MangaUrls.extractBackend(from: "const domain = 'late-response.example';", site: original))
        XCTAssertEqual(MangaUrls.dataHost, "ltn.another-comics.example")
        MangaUrls.resetResolvedBackend()
        XCTAssertNil(UserDefaults.standard.object(forKey: "manga.resolved_backend_site"))
    }

    func testFrontendGalleryLinksDoNotMasqueradeAsDataEndpoints() {
        _ = fixture()
        XCTAssertFalse(MangaUrls.extractBackend(from: #"<a href="https://front.example/galleries/1234.html">Work</a>"#))
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        XCTAssertTrue(MangaUrls.extractBackend(from: #"<script src="//ltn.storage.example/gg.js?v=123"></script>"#))
        XCTAssertEqual(MangaUrls.dataHost, "ltn.storage.example")
        XCTAssertEqual(MangaUrls.cdnHost, "storage.example")
    }

    func testRoutingUsesTheSavedCDNWithoutRecheckingTheHomepage() async throws {
        let fixture = fixture()
        let source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(1234)
        // Exercise the same discovery/cache path used by the routing configuration.
        let (data, _) = try await fixture.transport().getData("gg.js", limit: 100_000)
        let routing = try CDNRouting(String(decoding: data, as: UTF8.self))
        let thumbnail = try routing.url(hash: gallery.pages[0].hash, format: "webp", thumbnail: true)
        XCTAssertEqual(thumbnail.host, "atn." + fixture.domain)
        XCTAssertEqual(fixture.count(path: "/"), 1)
        XCTAssertEqual(fixture.count(path: "/assets/common.js"), 1)
    }
}

private final class BackendFixture: @unchecked Sendable {
    let host = "comics-" + UUID().uuidString.lowercased() + ".example"
    private let lock = NSLock()
    private var generation = 1
    private var requests: [URL] = []
    var domain: String { lock.withLock { domain(generation) } }
    private func domain(_ generation: Int) -> String { "storage-\(generation)." + host }
    func advanceDomain() { lock.withLock { generation += 1 } }
    func count(path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }
    func count(host: String) -> Int { lock.withLock { requests.filter { $0.host == host }.count } }
    func transport() -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendFixtureProtocol.self]
        return ContentTransport(configuration: configuration)
    }
    func reply(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        try lock.withLock {
            let url = request.url!; requests.append(url)
            if url.host == host {
                if url.path == "/" {
                    return (200, Data(#"<script src="/assets/common.js?v=7"></script><a href="/galleries/1234.html">Work</a>"#.utf8), [:])
                }
                if url.path == "/assets/common.js" { return (200, Data("const domain = '\(domain(generation))';".utf8), [:]) }
                return (404, Data(), [:])
            }
            guard ["ltn.", "atn."].contains(where: { url.host == $0 + domain(generation) }) else { throw URLError(.cannotFindHost) }
            if url.path.hasSuffix(".webp") { return (200, Data(repeating: 1, count: 64), ["Content-Type": "image/webp"]) }
            switch url.path {
            case "/index-korean.nozomi":
                return (206, Data([0, 0, 4, 210, 0, 0, 22, 46]), ["Content-Range": "bytes 0-7/8"])
            case "/galleries/1234.js":
                let hash = String(repeating: "a", count: 64)
                return (200, Data("var galleryinfo = {\"title\":\"Fixture\",\"files\":[{\"hash\":\"\(hash)\",\"name\":\"1.jpg\",\"width\":100,\"height\":150}]};".utf8), [:])
            case "/gg.js":
                let script = """
                'use strict';
                gg = { m: function(g) { var o = 0; switch (g) { case 1: o = 1; break; } return o; },
                s: function(h) { var m = /(..)(.)$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
                b: '123/' };
                """
                return (200, Data(script.utf8), [:])
            default: return (404, Data(), [:])
            }
        }
    }
}

private final class BackendFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: BackendFixture?
    static func install(_ value: BackendFixture?) { lock.withLock { fixture = value } }
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
