import XCTest
@testable import TEGNAL

final class MangaBackendTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site", "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = MangaUrls.preferences.object(forKey: key) }
        MangaUrls.resetResolvedBackend()
    }
    override func tearDown() {
        BackendFixtureProtocol.install(nil)
        for key in keys { MangaUrls.preferences.set(saved[key], forKey: key) }
        super.tearDown()
    }
    private func fixture() -> BackendFixture {
        let fixture = BackendFixture()
        MangaUrls.preferences.set(fixture.host, forKey: "manga.site_address")
        BackendFixtureProtocol.install(fixture)
        return fixture
    }

    func testDerivedDataDomainMatchesCurrentIndexedFrontendWithoutExecutingScript() throws {
        let script = #"""
        const domain2 = 'media.example';
        var domain = (/^dev\./.test(document.location.hostname.toString()) ? 'dev.comics.example' : 'ltn.'+domain2);
        """#
        let hosts = try XCTUnwrap(MangaUrls.indexedBackendHosts(in: script))
        XCTAssertEqual(hosts.dataHost, "ltn.media.example")
        XCTAssertEqual(hosts.cdn, "media.example")
        XCTAssertNil(MangaUrls.indexedBackendHosts(in: "const domain2 = 'unrelated.example';"))
        XCTAssertNil(MangaUrls.indexedBackendHosts(in: "const domain2 = 'broken..example'; var domain = 'ltn.'+domain2;"))
    }

    func testInterruptedSavedEndpointRefreshesBeforeRetryingTheCatalog() async throws {
        for failure in [URLError.Code.secureConnectionFailed, .networkConnectionLost, .timedOut] {
            let fixture = fixture()
            let transport = fixture.transport(browserFetch: { _, _, _, _, _ in throw URLError(failure) })
            let source = MangaContentSource(transport: transport)
            _ = try await source.list(GalleryQuery(), offset: 0, count: 2)
            fixture.advanceDomain(failure: failure)
            let gallery = try await source.gallery(1234)
            XCTAssertEqual(gallery.id, 1234)
            XCTAssertEqual(MangaUrls.dataHost, "ltn." + fixture.domain)
            XCTAssertEqual(fixture.count(path: "/"), 2)
        }
        XCTAssertFalse(ContentTransport.backendConnectionFailed(URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(ContentTransport.backendConnectionFailed(URLError(.cancelled)))
    }

    func testFirstListAndMetadataDiscoverTheCustomSitesScriptOnlyOnce() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        async let list = source.list(GalleryQuery(), offset: 0, count: 2)
        async let gallery = source.gallery(1234)
        let (batch, work) = try await (list, gallery)
        XCTAssertEqual(batch.ids, [5678, 1234])
        XCTAssertEqual(work.id, 1234)
        XCTAssertEqual(fixture.count(path: "/"), 1)
        XCTAssertEqual(fixture.count(path: "/assets/common.js"), 1)
        XCTAssertEqual(fixture.count(host: "ltn." + fixture.host), 0, "Resolve the script before requesting the old derived host")
        XCTAssertEqual(MangaUrls.dataHost, "ltn." + fixture.domain)
        XCTAssertEqual(MangaUrls.cdnHost, fixture.domain)
        XCTAssertTrue(ContentTransport.allows(URL(string: "https://w1." + fixture.domain + "/image.webp")!))
        XCTAssertFalse(ContentTransport.allows(URL(string: "https://unrelated.example/gg.js")!))
    }

    func testTenDefaultExclusionsLoadTheFeedAndApplyEveryFilter() async throws {
        let fixture = fixture()
        let excluded = (1...10).map { "tag:excluded\($0)" }
        fixture.indexes["/index-korean.nozomi"] = Array(2000...2011).reversed()
        fixture.indexes["/tag/included-all.nozomi"] = Array(2000...2011).reversed()
        for index in 1...10 { fixture.indexes["/tag/excluded\(index)-all.nozomi"] = [Int64(2000 + index)] }
        let source = MangaContentSource(transport: fixture.transport())
        for text in ["", "tag:included"] {
            let query = GalleryQuery(text: text).applyingDefaults(tags: "", excluded: excluded.joined(separator: " "))
            let batch = try await source.list(query, offset: 0, count: 24)
            XCTAssertEqual(batch.ids, [2011, 2000], "All ten exclusions must apply to the initial feed and explicit searches")
            XCTAssertFalse(batch.hasMore)
        }
    }

    func testExcessiveSearchTermsReportTheLimitWithoutDroppingFilters() async throws {
        let fixture = fixture()
        let exclusions = (1...GalleryQuery.maximumSearchTerms).map { "tag:excluded\($0)" }.joined(separator: " ")
        let query = GalleryQuery(text: "tag:included").applyingDefaults(tags: "", excluded: exclusions)
        do {
            _ = try await MangaContentSource(transport: fixture.transport()).list(query, offset: 0, count: 1)
            XCTFail("Excessive filters must be reported rather than silently omitted")
        } catch ContentError.tooManySearchTerms(let limit) {
            XCTAssertEqual(limit, GalleryQuery.maximumSearchTerms)
        }
        XCTAssertEqual(fixture.count(path: "/galleriesindex/version"), 0)
    }

    func testLanguageExceptionMergesVisualIndexesWithoutDroppingArtistTypeOrPopularOrder() async throws {
        let fixture = fixture()
        fixture.indexes = ["/index-korean.nozomi": [2000, 1997], "/type/artistcg-all.nozomi": [2003],
            "/type/gamecg-all.nozomi": [2002, 1999], "/type/imageset-all.nozomi": [2001],
            "/artist/sample-all.nozomi": [2002, 1998], "/type/manga-all.nozomi": [2000, 1997],
            "/popular/week-all.nozomi": [1997, 2001, 2002, 2000, 2003, 1999]]
        let source = MangaContentSource(transport: fixture.transport())
        let strict = try await source.list(GalleryQuery(), offset: 0, count: 10)
        XCTAssertEqual(strict.ids, [2000, 1997], "Language exceptions are off by default")
        let first = try await source.list(GalleryQuery(allowsLanguageExceptions: true), offset: 0, count: 3)
        XCTAssertEqual(first.ids, [2003, 2002, 2001])
        let second = try await source.list(GalleryQuery(allowsLanguageExceptions: true), offset: 3, count: 3)
        XCTAssertEqual(second.ids, [2000, 1999, 1997])
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(fixture.count(path: "/type/gamecg-all.nozomi"), 1, "Pagination must reuse the bounded prefix")
        let artist = try await source.list(GalleryQuery(artist: "sample", allowsLanguageExceptions: true), offset: 0, count: 10)
        XCTAssertEqual(artist.ids, [2002])
        let manga = try await source.list(GalleryQuery(text: "type:manga", allowsLanguageExceptions: true), offset: 0, count: 10)
        XCTAssertEqual(manga.ids, [2000, 1997])
        let popular = try await source.list(GalleryQuery(sort: .week, allowsLanguageExceptions: true), offset: 0, count: 10)
        XCTAssertEqual(popular.ids, [1997, 2001, 2002, 2000, 2003, 1999])
        let strictPopular = try await source.list(GalleryQuery(sort: .week), offset: 0, count: 10)
        XCTAssertEqual(strictPopular.ids, [1997, 2000], "Turning exceptions off must not reuse the permissive search cache")
    }

    func testSavedEndpointsSurviveNewSourcesWithoutRediscovery() async throws {
        let fixture = fixture()
        _ = try await MangaContentSource(transport: fixture.transport()).list(GalleryQuery(), offset: 0, count: 2)
        XCTAssertEqual(MangaUrls.preferences.string(forKey: "manga.resolved_backend_site"), MangaUrls.home)
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

    @MainActor func testMissingGalleryHTTPResponseIsCountedAsGoneByBackfill() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let db = try AppDatabase.inMemory()
        _ = try db.upsertWork(galleryId: 9999)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CoverQueueActor(database: db, thumbsDir: root, source: source, allowsBackfill: { true }, delay: .zero)
        let state = CoverQueueState()
        await queue.start(state: state)
        XCTAssertEqual(state.gone, 1)
        XCTAssertEqual(state.failed, 0)
        XCTAssertEqual(state.remaining, 0)
        XCTAssertEqual(try db.getWork(galleryId: 9999)?.thumbStatus, "gone")
    }

    func testSiteChangeCannotReuseOrAcceptThePreviousSitesEndpoints() async throws {
        let fixture = fixture()
        await MangaUrls.resolveBackend(transport: fixture.transport())
        let original = MangaUrls.home
        MangaUrls.preferences.set("another-comics.example", forKey: "manga.site_address")
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        XCTAssertEqual(MangaUrls.dataHost, "ltn.another-comics.example")
        XCTAssertEqual(MangaUrls.cdnHost, "another-comics.example")
        XCTAssertFalse(MangaUrls.extractBackend(from: "const domain = 'late-response.example';", site: original))
        XCTAssertEqual(MangaUrls.dataHost, "ltn.another-comics.example")
        MangaUrls.resetResolvedBackend()
        XCTAssertNil(MangaUrls.preferences.object(forKey: "manga.resolved_backend_site"))
    }

    func testFrontendGalleryLinksDoNotMasqueradeAsDataEndpoints() {
        _ = fixture()
        XCTAssertFalse(MangaUrls.extractBackend(from: #"<a href="https://front.example/galleries/1234.html">Work</a>"#))
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        XCTAssertTrue(MangaUrls.extractBackend(from: #"<script src="//ltn.storage.example/gg.js?v=123"></script>"#))
        XCTAssertEqual(MangaUrls.dataHost, "ltn.storage.example")
        XCTAssertEqual(MangaUrls.cdnHost, "storage.example")
    }

    func testForcedDiscoveryCanRecoverImmediatelyAfterAFailure() async {
        let fixture = fixture(), transport = fixture.transport()
        fixture.setDiscoveryAvailable(false)
        await MangaUrls.resolveBackend(transport: transport)
        XCTAssertFalse(MangaUrls.hasResolvedBackend)
        fixture.setDiscoveryAvailable(true)
        await MangaUrls.resolveBackend(transport: transport, force: true)
        XCTAssertTrue(MangaUrls.hasResolvedBackend, "Explicit recovery must not be blocked by the failed-discovery cooldown")
        XCTAssertEqual(fixture.count(path: "/"), 2)
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
    private var staleEndpointFailure: URLError.Code = .cannotFindHost
    private var discoveryAvailable = true
    var indexes: [String: [Int64]] = [:]
    private var requests: [URL] = []
    var domain: String { lock.withLock { domain(generation) } }
    private func domain(_ generation: Int) -> String { "storage-\(generation)." + host }
    func advanceDomain(failure: URLError.Code = .cannotFindHost) { lock.withLock { generation += 1; staleEndpointFailure = failure } }
    func setDiscoveryAvailable(_ available: Bool) { lock.withLock { discoveryAvailable = available } }
    func count(path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }
    func count(host: String) -> Int { lock.withLock { requests.filter { $0.host == host }.count } }
    func transport(browserFetch: ContentTransport.BrowserFetch? = nil) -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendFixtureProtocol.self]
        if let browserFetch { return ContentTransport(configuration: configuration, browserFetch: browserFetch) }
        return ContentTransport(configuration: configuration)
    }
    func reply(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
        try lock.withLock {
            let url = request.url!; requests.append(url)
            if url.host == host {
                if url.path == "/" {
                    if !discoveryAvailable { return (503, Data(), [:]) }
                    return (200, Data(#"<script src="/assets/common.js?v=7"></script><a href="/galleries/1234.html">Work</a>"#.utf8), [:])
                }
                if url.path == "/assets/common.js" { return (200, Data("const domain = '\(domain(generation))';".utf8), [:]) }
                return (404, Data(), [:])
            }
            guard ["ltn.", "atn."].contains(where: { url.host == $0 + domain(generation) }) else { throw URLError(staleEndpointFailure) }
            if url.path.hasSuffix(".webp") { return (200, Data(repeating: 1, count: 64), ["Content-Type": "image/webp"]) }
            if let ids = indexes[url.path] {
                let data = Data(ids.flatMap { id -> [UInt8] in
                    let value = UInt32(id)
                    return [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
                })
                if let range = request.value(forHTTPHeaderField: "Range") {
                    let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int($0) }
                    let start = parts[0], end = min(parts[1], data.count - 1)
                    if start >= data.count { return (416, Data(), ["Content-Range": "bytes */\(data.count)"]) }
                    return (206, data.subdata(in: start..<(end + 1)), ["Content-Range": "bytes \(start)-\(end)/\(data.count)"])
                }
                return (200, data, [:])
            }
            switch url.path {
            case "/galleriesindex/version": return (200, Data("1".utf8), [:])
            case "/index-korean.nozomi":
                return (206, Data([0, 0, 22, 46, 0, 0, 4, 210]), ["Content-Range": "bytes 0-7/8"])
            case "/type/artistcg-all.nozomi", "/type/gamecg-all.nozomi", "/type/imageset-all.nozomi":
                return (416, Data(), ["Content-Range": "bytes */0"])
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
