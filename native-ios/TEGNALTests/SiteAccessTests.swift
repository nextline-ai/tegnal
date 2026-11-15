import XCTest
@testable import TEGNAL

/// Signing in with cookies, members-only access, bot checks, opening works on other connected
/// websites, and what account-based work pages say besides their pages.
final class SiteAccessTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site",
                        "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base", "manga.resolved_api",
                        "manga.resolved_login", "manga.account_site", "manga.account_host", "manga.account_login", "manga.account_required", "manga.resolved_features",
                        "manga.sites", "manga.siteSnapshots"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = MangaUrls.preferences.object(forKey: key) }
        for key in keys { MangaUrls.preferences.removeObject(forKey: key) }
        SiteAccount.signOut()
        SiteClearance.removeAll()
        StubProtocol.handler = nil
    }

    override func tearDown() {
        StubProtocol.handler = nil
        SiteAccount.signOut()
        SiteClearance.removeAll()
        for host in ["members.example", "keyed.example", "checked.example", "private.example"] { ContentTransport.clearChallenge(forHost: host) }
        for key in keys { MangaUrls.preferences.set(saved[key], forKey: key) }
        super.tearDown()
    }

    private func connect(_ host: String) { MangaUrls.preferences.set(host, forKey: "manga.site_address") }

    private func resolveKeyed(_ host: String) {
        connect(host)
        let home = "https://\(host)/"
        MangaUrls.preferences.set(host, forKey: "manga.resolved_data_host")
        MangaUrls.preferences.set(host, forKey: "manga.resolved_cdn_host")
        MangaUrls.preferences.set(home, forKey: "manga.resolved_backend_site")
        MangaUrls.preferences.set("keyed", forKey: "manga.resolved_protocol")
    }

    private func transport() -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ContentTransport(configuration: configuration)
    }

    // MARK: Cookies

    func testPastedCookiesKeepTheAccountAndItsAccessButNeverAPlaceholder() {
        let header = "Cookie: ipb_member_id=1234567; ipb_pass_hash=0123456789abcdef0123456789abcdef; igneous=mystery; sk=abc123; tracking=1"
        let pasted = SiteAccount.parseCookies(header)
        XCTAssertTrue(pasted.isComplete)
        XCTAssertEqual(pasted.identity, ["ipb_member_id": "1234567", "ipb_pass_hash": "0123456789abcdef0123456789abcdef"])
        XCTAssertEqual(pasted.site, ["sk": "abc123"], "A placeholder instead of access, and unrelated cookies, are dropped")

        let lines = SiteAccount.parseCookies("ipb_member_id = 42\nipb_pass_hash=\"ffeeddccbbaa99887766554433221100\"\nigneous=a1b2c3d4e5")
        XCTAssertEqual(lines.identity["ipb_member_id"], "42")
        XCTAssertEqual(lines.identity["ipb_pass_hash"], "ffeeddccbbaa99887766554433221100")
        XCTAssertEqual(lines.site["igneous"], "a1b2c3d4e5")
        XCTAssertFalse(SiteAccount.parseCookies("igneous=a1b2c3").isComplete)
    }

    func testAccessFromSignInSurvivesThePlaceholderTheSiteSendsBack() throws {
        connect("members.example")
        MangaUrls.markUsesAccount(site: MangaUrls.home)
        let pasted = SiteAccount.parseCookies("ipb_member_id=7; ipb_pass_hash=0123456789abcdef0123456789abcdef; igneous=feedface01")
        XCTAssertTrue(SiteAccount.signIn(pasted: pasted, host: "members.example"))
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["igneous"], "feedface01")

        let placeholder = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://members.example/")!, statusCode: 200, httpVersion: nil,
                                                       headerFields: ["Set-Cookie": "igneous=mystery; path=/; domain=.members.example"]))
        SiteAccount.store(placeholder)
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["igneous"], "feedface01")

        SiteAccount.forget(SiteAccount.accessCookie, host: "members.example")
        XCTAssertNil(SiteAccount.cookies(forSite: "members.example")["igneous"], "A refused access cookie is dropped so a fresh one is handed out")
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["ipb_member_id"], "7")
        XCTAssertEqual(SiteAccount.savedCookieNames(host: "members.example"), ["ipb_member_id", "ipb_pass_hash"])
        let tracked = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://members.example/")!, statusCode: 200, httpVersion: nil,
                                                   headerFields: ["Set-Cookie": "__utmp=tracked; path=/, sk=settings; path=/"]))
        SiteAccount.store(tracked)
        XCTAssertNil(SiteAccount.cookies(forSite: "members.example")["__utmp"], "The tracking cookie is never sent back")
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["sk"], "settings")
    }

    func testAccessTheWallHandsOutIsKeptAndRefusedAccessIsDropped() async throws {
        resolveKeyed("members.example")
        let pasted = SiteAccount.parseCookies("ipb_member_id=7; ipb_pass_hash=0123456789abcdef0123456789abcdef; igneous=refused001")
        XCTAssertTrue(SiteAccount.signIn(pasted: pasted, host: "members.example"))
        let wall = Data(#"<html><body><img src="https://members.example/img/kokomade.jpg"></body></html>"#.utf8)
        // The wall answers a request whose access was refused, and hands out new access with it.
        StubProtocol.handler = { _ in (200, ["Content-Type": "text/html", "Set-Cookie": "igneous=fresh00001; path=/; domain=.members.example"], wall) }
        let source = MangaContentSource(transport: transport())
        do {
            _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 5)
            XCTFail("Expected the wall")
        } catch { XCTAssertEqual(error as? ContentError, .signInRequired) }
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["igneous"], "fresh00001", "Access the wall just handed out is kept for the next request")

        StubProtocol.handler = { _ in (200, ["Content-Type": "text/html"], wall) }
        do {
            _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 5)
            XCTFail("Expected the wall")
        } catch { XCTAssertEqual(error as? ContentError, .signInRequired) }
        XCTAssertNil(SiteAccount.cookies(forSite: "members.example")["igneous"], "Access the site refused is dropped so a fresh one is handed out")
        XCTAssertEqual(SiteAccount.cookies(forSite: "members.example")["ipb_member_id"], "7")
    }

    func testMembersOnlySiteAsksForAnAccountAndOpensOnceSignedIn() async throws {
        connect("members.example")
        let listing = #"<html><body><form><input name="f_search"></form><div class="searchnav"></div><a href="https://members.example/g/3000/0000000bb8/">Work</a></body></html>"#
        StubProtocol.handler = { request in
            let signedIn = request.value(forHTTPHeaderField: "Cookie")?.contains("ipb_member_id=7") == true
            if request.url?.path == "/" && signedIn { return (200, ["Content-Type": "text/html"], Data(listing.utf8)) }
            return (200, ["Content-Type": "image/gif"], Data(repeating: 0x47, count: 512))
        }
        let transport = transport()
        await MangaUrls.resolveBackend(transport: transport, force: true)
        XCTAssertTrue(MangaUrls.requiresSignIn, "A homepage that only shows a picture belongs to a members-only site")
        do {
            _ = try await MangaContentSource(transport: transport).list(GalleryQuery(language: "all"), offset: 0, count: 5)
            XCTFail("Expected a sign-in request")
        } catch { XCTAssertEqual(error as? ContentError, .signInRequired) }

        XCTAssertTrue(SiteAccount.signIn(pasted: SiteAccount.parseCookies("ipb_member_id=7; ipb_pass_hash=0123456789abcdef0123456789abcdef"), host: "members.example"))
        MangaUrls.resetResolvedBackend()
        MangaUrls.markUsesAccount(site: MangaUrls.home)
        await MangaUrls.resolveBackend(transport: transport, force: true)
        XCTAssertEqual(MangaUrls.backend, .keyed)
        XCTAssertTrue(MangaUrls.hasResolvedBackend)
    }

    // MARK: Bot checks

    func testBotCheckResponsesAreRecognized() throws {
        func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://checked.example/")!, statusCode: status, httpVersion: nil, headerFields: headers))
        }
        XCTAssertTrue(ContentTransport.isBotCheck(try response(403, ["cf-mitigated": "challenge"])))
        XCTAssertTrue(ContentTransport.isBotCheck(try response(503, ["Server": "cloudflare", "Content-Type": "text/html; charset=UTF-8"])))
        XCTAssertFalse(ContentTransport.isBotCheck(try response(404, ["Server": "cloudflare", "Content-Type": "text/html"])))
        XCTAssertFalse(ContentTransport.isBotCheck(try response(403, ["Server": "nginx", "Content-Type": "text/html"])))
        XCTAssertFalse(ContentTransport.isBotCheck(try response(503, ["Server": "cloudflare", "Content-Type": "image/webp"])))
    }

    func testAStoppedFirstLookAsksForTheCheckAndAPassedCheckTravelsWithItsBrowser() async throws {
        connect("checked.example")
        let recorded = Recorder()
        StubProtocol.handler = { request in
            recorded.add(request)
            if request.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=passed") == true {
                return (404, ["Content-Type": "text/html"], Data())
            }
            return (403, ["cf-mitigated": "challenge", "Content-Type": "text/html"], Data("<title>Just a moment...</title>".utf8))
        }
        let transport = transport()
        do {
            _ = try await MangaContentSource(transport: transport).gallery(3000)
            XCTFail("Expected a bot check")
        } catch { XCTAssertEqual(error as? ContentError, .verificationRequired) }
        XCTAssertEqual(ContentTransport.challengedPage(forHost: "checked.example")?.host, "checked.example")

        let clearance = try XCTUnwrap(HTTPCookie(properties: [.domain: ".checked.example", .path: "/", .name: "cf_clearance", .value: "passed"]))
        let foreign = try XCTUnwrap(HTTPCookie(properties: [.domain: ".other.example", .path: "/", .name: "cf_clearance", .value: "elsewhere"]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [.domain: ".checked.example", .path: "/", .name: "session", .value: "x"]))
        XCTAssertFalse(SiteClearance.save([unrelated], userAgent: "Agent/1", host: "checked.example"))
        XCTAssertTrue(SiteClearance.save([clearance, foreign, unrelated], userAgent: "Agent/1", host: "www.checked.example"))
        let entry = try XCTUnwrap(SiteClearance.entry(forHost: "api.checked.example"))
        XCTAssertEqual(entry.cookies, ["cf_clearance": "passed"])
        XCTAssertEqual(ContentTransport.cookieHeader(account: "nw=1", clearance: entry), "nw=1; cf_clearance=passed")

        _ = try? await transport.get(URL(string: "https://checked.example/common.js")!, limit: 1000)
        let sent = try XCTUnwrap(recorded.requests.last)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "Agent/1", "A passed check counts only with the browser that passed it")
        XCTAssertTrue(sent.value(forHTTPHeaderField: "Cookie")?.contains("cf_clearance=passed") == true)
    }

    func testCheckAndSignInPagesAllowOnlySecurePagesAndTheFramesAChecksDraws() {
        XCTAssertTrue(ComicsBrowserProfile.allows(URL(string: "https://checked.example/login")!, mainFrame: true))
        XCTAssertFalse(ComicsBrowserProfile.allows(URL(string: "http://checked.example/")!, mainFrame: true))
        XCTAssertFalse(ComicsBrowserProfile.allows(URL(string: "https://user:pass@checked.example/")!, mainFrame: true))
        XCTAssertFalse(ComicsBrowserProfile.allows(URL(string: "about:srcdoc")!, mainFrame: true))
        XCTAssertTrue(ComicsBrowserProfile.allows(URL(string: "about:srcdoc")!, mainFrame: false))
        XCTAssertTrue(ComicsBrowserProfile.allows(URL(string: "blob:https://checked.example/abc")!, mainFrame: false))
        XCTAssertFalse(ComicsBrowserProfile.allows(URL(string: "javascript:alert(1)")!, mainFrame: false))
    }

    // MARK: Page messages

    func testNoticesServedInPlaceOfAnImageAreNeverKeptAsPages() {
        let page = URL(string: "https://node.example/h/1.webp")!
        XCTAssertEqual(KeyedCatalogSource.imageNotice(Data(repeating: 1, count: 64), url: URL(string: "https://node.example/img/509.gif")!), .imageLimit)
        // The notices are recognized by their digest (checked against copies of both), never by size alone.
        XCTAssertNil(KeyedCatalogSource.imageNotice(Data(repeating: 1, count: 28_658), url: page))
        XCTAssertNil(KeyedCatalogSource.imageNotice(Data(repeating: 1, count: 144_844), url: page))
        XCTAssertNil(KeyedCatalogSource.imageNotice(Data(repeating: 1, count: 64), url: page))
    }

    func testPagesThatSayNoInsteadOfShowingWorks() {
        let filler = String(repeating: "x", count: 200)
        XCTAssertEqual(KeyedCatalogSource.pageError("Your IP address has been temporarily banned for excessive pageloads. The ban expires in 59 minutes"), .temporarilyBlocked)
        XCTAssertEqual(KeyedCatalogSource.pageError("<html>\(filler)<img src=\"https://media.example/img/kokomade.jpg\"></html>"), .signInRequired)
        XCTAssertEqual(KeyedCatalogSource.pageError("<p>You have exceeded your image viewing limits.</p>\(filler)"), .imageLimit)
        XCTAssertEqual(KeyedCatalogSource.pageError(""), .signInRequired)
        XCTAssertNil(KeyedCatalogSource.pageError("<html><body>\(filler)</body></html>"))
        XCTAssertEqual(KeyedCatalogSource.pageError("Key missing, or incorrect key provided."), .galleryNotFound, "A wrong key is not a sign-in wall")
        XCTAssertEqual(KeyedCatalogSource.pageError("Invalid page."), .galleryNotFound)
        let listing = "<html>" + String(repeating: "<tr>work</tr>", count: 1000) + "<a>Temporarily Banned Again</a></html>"
        XCTAssertNil(KeyedCatalogSource.pageError(listing), "A title on a full listing is not a notice")
        XCTAssertTrue(ContentError.allowsOtherSite(ContentError.galleryNotFound))
        XCTAssertTrue(ContentError.allowsOtherSite(ContentError.unavailable(404)))
        XCTAssertTrue(ContentError.allowsOtherSite(URLError(.cannotFindHost)))
        XCTAssertFalse(ContentError.allowsOtherSite(ContentError.invalidQuery))
        XCTAssertFalse(ContentError.allowsOtherSite(URLError(.notConnectedToInternet)), "Without a connection every website fails alike")
        XCTAssertFalse(ContentError.allowsOtherSite(CancellationError()))
    }

    func testAStalePageKeyIsNotASignInWall() {
        XCTAssertEqual(KeyedCatalogSource.pageError("Keep trying."), .galleryNotFound,
                       "A page link whose key no longer matches is answered in two words, which says nothing about the account")
        XCTAssertEqual(KeyedCatalogSource.pageError("Short."), .signInRequired, "Other near-empty pages still read as the members-only wall")
    }

    // MARK: Opening works on other connected websites

    func testAWorkMissingOnTheCheckedWebsiteOpensElsewhereAndGoesThereFirstNextTime() async throws {
        let memory = WorkSiteMemory(file: nil)
        let active = FakeSite(name: "a.example", works: [1: "one"])
        let mirror = FakeSite(name: "b.example", works: [1: "one", 2: "two"])
        let third = FakeSite(name: "c.example", works: [3: "three"])
        let sources: [String: FakeSite] = ["b.example": mirror, "c.example": third]
        let content = SiteFallbackContent(primary: active, sourceFor: { sources[$0]! },
                                          sites: { ("a.example", ["a.example", "b.example", "c.example"]) }, memory: memory)

        let first = try await content.gallery(1)
        XCTAssertEqual(first.title, "one")
        XCTAssertNil(memory.site(for: 1), "A work the checked website still has needs no detour")
        XCTAssertNil(content.servingSite(for: 1))

        let moved = try await content.gallery(2)
        XCTAssertEqual(moved.title, "two")
        XCTAssertEqual(memory.site(for: 2), "b.example")
        XCTAssertEqual(content.servingSite(for: 2), "b.example")
        XCTAssertEqual(content.candidates(for: 2).first, "b.example")
        let checkedBefore = await active.calls
        _ = try await content.gallery(2)
        let checkedAfter = await active.calls
        XCTAssertEqual(checkedBefore, checkedAfter, "Once remembered, the checked website is not asked again first")

        let image = try await content.image(GalleryPage(hash: "h", name: "1", width: 1, height: 1, hasAVIF: false, index: 0, sourceSite: "https://b.example/"),
                                            galleryID: 2, thumbnail: true)
        XCTAssertEqual(String(decoding: image, as: UTF8.self), "b.example", "Pages load from the website their work was read from")

        content.prefer("c.example", for: 3)
        XCTAssertEqual(content.candidates(for: 3), ["a.example", "c.example", "b.example"])
        let third3 = try await content.gallery(3)
        XCTAssertEqual(third3.title, "three")

        do {
            _ = try await content.gallery(9)
            XCTFail("A work no website has stays missing")
        } catch { XCTAssertEqual(error as? ContentError, .galleryNotFound) }

        memory.forget(site: "b.example")
        XCTAssertNil(memory.site(for: 2))
    }

    // MARK: Filling from websites that block bulk reading

    func testAFillReadsABlockingWebsiteOnlyForWorksTheOthersNoLongerHave() async throws {
        let blocking = FakeSite(name: "keyed.example", works: [1: "one", 3: "three"])
        let mirror = FakeSite(name: "b.example", works: [1: "one", 2: "two"])
        let content = SiteFallbackContent(primary: blocking, sourceFor: { _ in mirror },
                                          sites: { ("keyed.example", ["keyed.example", "b.example"]) }, memory: WorkSiteMemory(file: nil),
                                          blocksBulkReading: { $0 == "keyed.example" })

        let filled = try await content.gallery(1, preferring: "keyed.example", inBulk: true)
        XCTAssertEqual(filled.title, "one")
        var checked = await blocking.calls
        XCTAssertEqual(checked, 0, "A work another website has is never read from the one that blocks bulk reading")
        XCTAssertFalse(content.tookBlockingRead(1))

        let deleted = try await content.gallery(3, preferring: "b.example", inBulk: true)
        XCTAssertEqual(deleted.title, "three", "A work the other websites deleted is read from the one that blocks bulk reading")
        checked = await blocking.calls
        XCTAssertEqual(checked, 1)
        XCTAssertTrue(content.tookBlockingRead(3), "So the next read waits longer")
        XCTAssertFalse(content.tookBlockingRead(3))

        do {
            _ = try await content.gallery(9, preferring: nil, inBulk: true)
            XCTFail("A work no website has stays missing")
        } catch { XCTAssertEqual(error as? ContentError, .galleryNotFound) }

        let unreachable = FakeSite(name: "b.example", works: [:], refusal: .unavailable(503))
        let cut = SiteFallbackContent(primary: blocking, sourceFor: { _ in unreachable },
                                      sites: { ("keyed.example", ["keyed.example", "b.example"]) }, memory: WorkSiteMemory(file: nil),
                                      blocksBulkReading: { $0 == "keyed.example" })
        let before = await blocking.calls
        do {
            _ = try await cut.gallery(3, preferring: nil, inBulk: true)
            XCTFail("A work the other websites could not be asked about waits for a later fill")
        } catch { XCTAssertTrue(error is CoverFillGuard.LeftForBlockingSite) }
        let after = await blocking.calls
        XCTAssertEqual(before, after)
        let opened = try await cut.gallery(3)
        XCTAssertEqual(opened.title, "three", "Opening a work by hand still reads every website")

        let alone = SiteFallbackContent(primary: blocking, sourceFor: { _ in mirror }, sites: { ("keyed.example", ["keyed.example"]) },
                                        memory: WorkSiteMemory(file: nil), blocksBulkReading: { $0 == "keyed.example" })
        let only = try await alone.gallery(1, preferring: nil, inBulk: true)
        XCTAssertEqual(only.title, "one", "With no other website, the fill reads it (after asking, and slowly)")
        XCTAssertTrue(alone.tookBlockingRead(1))
    }

    func testTheFillReadsDeletedWorksFromABlockingWebsiteAndLeavesUnreachableOnesForLater() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-fill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocking = FakeSite(name: "keyed.example", works: [7: "seven", 8: "eight"])
        let mirror = FakeSite(name: "b.example", works: [:])
        let content = SiteFallbackContent(primary: mirror, sourceFor: { _ in blocking },
                                          sites: { ("b.example", ["keyed.example", "b.example"]) }, memory: WorkSiteMemory(file: nil),
                                          blocksBulkReading: { $0 == "keyed.example" })
        _ = try db.upsertWork(galleryId: 7, metadataSource: nil, catalogMatched: false, site: "b.example")
        await CoverQueueActor(database: db, thumbsDir: root, source: content, allowsBackfill: { true }, delay: .zero, slowDelay: .zero).start(state: CoverQueueState())
        var checked = await blocking.calls
        XCTAssertEqual(checked, 1)
        XCTAssertEqual(try db.getWork(galleryId: 7)?.title, "seven", "Deleted on the other website, read from the one that still has it")

        let unreachable = FakeSite(name: "b.example", works: [:], refusal: .unavailable(503))
        let cut = SiteFallbackContent(primary: unreachable, sourceFor: { _ in blocking },
                                      sites: { ("b.example", ["keyed.example", "b.example"]) }, memory: WorkSiteMemory(file: nil),
                                      blocksBulkReading: { $0 == "keyed.example" })
        _ = try db.upsertWork(galleryId: 8, metadataSource: nil, catalogMatched: false, site: "b.example")
        try db.setThumb(galleryId: 7, status: "gone")
        let state = CoverQueueState()
        await CoverQueueActor(database: db, thumbsDir: root, source: cut, allowsBackfill: { true }, delay: .zero, slowDelay: .zero).start(state: state)
        checked = await blocking.calls
        XCTAssertEqual(checked, 1, "An unreachable website is not a deleted work")
        XCTAssertEqual(state.failed, 1)
        XCTAssertEqual(state.gone, 0)
        XCTAssertEqual(try db.getWork(galleryId: 8)?.thumbStatus, "failed", "Tried again on a later fill")

        await CoverQueueActor(database: db, thumbsDir: root, source: cut, allowsBackfill: { true }, delay: .zero, slowDelay: .zero)
            .start(state: CoverQueueState(), mayRead: { false })
        let unreachableCalls = await unreachable.calls
        XCTAssertEqual(unreachableCalls, 1, "A run that must ask first reads nothing")
    }

    func testReadingFromABlockingWebsiteWaitsLongerBetweenWorks() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-fill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Work 2 is missing: an unanswered read waits as long as an answered one.
        let blocking = FakeSite(name: "keyed.example", works: [1: "one"])
        let content = SiteFallbackContent(primary: blocking, sourceFor: { _ in blocking }, sites: { ("keyed.example", ["keyed.example"]) },
                                          memory: WorkSiteMemory(file: nil), blocksBulkReading: { $0 == "keyed.example" })
        for id: Int64 in [1, 2] { _ = try db.upsertWork(galleryId: id, metadataSource: nil, catalogMatched: false, site: "keyed.example") }
        let started = ContinuousClock.now
        await CoverQueueActor(database: db, thumbsDir: root, source: content, allowsBackfill: { true }, delay: .zero, slowDelay: .milliseconds(300))
            .start(state: CoverQueueState())
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(600))
        let calls = await blocking.calls
        XCTAssertEqual(calls, 2)
    }

    func testAWebsiteThatStopsAnsweringThisDeviceEndsTheFill() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-fill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blocking = FakeSite(name: "keyed.example", works: [:], refusal: .temporarilyBlocked)
        let content = SiteFallbackContent(primary: blocking, sourceFor: { _ in blocking }, sites: { ("keyed.example", ["keyed.example"]) },
                                          memory: WorkSiteMemory(file: nil), blocksBulkReading: { $0 == "keyed.example" })
        for id: Int64 in 1...5 { _ = try db.upsertWork(galleryId: id, metadataSource: nil, catalogMatched: false, site: "keyed.example") }
        let state = CoverQueueState()
        await CoverQueueActor(database: db, thumbsDir: root, source: content, allowsBackfill: { true }, delay: .zero, slowDelay: .zero).start(state: state)
        let calls = await blocking.calls
        XCTAssertEqual(calls, 1, "Reading on would only keep the device blocked for longer")
        XCTAssertEqual(state.failed, 1)
        XCTAssertEqual(state.error, ContentError.temporarilyBlocked.localizedDescription)
    }

    func testFillingFromOnlyBlockingWebsitesAsksFirstAndRemembersTheAnswer() throws {
        let defaults = UserDefaults(suiteName: "bulk-fill-\(UUID().uuidString)")!
        let blocks: (String) -> Bool = { $0.hasPrefix("keyed") }
        func outcome(_ sites: [String], _ pending: Int, manual: Bool = false) -> CoverFillGuard.Outcome {
            CoverFillGuard.outcome(sites: sites, blocks: blocks, pending: { pending }, manual: manual, defaults: defaults)
        }
        XCTAssertTrue(CoverFillGuard.blocksBulkReading("keyed.example", backend: .keyed))
        XCTAssertFalse(CoverFillGuard.blocksBulkReading("indexed.example", backend: .indexed))
        XCTAssertFalse(CoverFillGuard.blocksBulkReading("indexed.example", backend: nil))
        XCTAssertEqual(CoverFillGuard.skipped(among: ["keyed.example", "b.example"], blocks: blocks), ["keyed.example"])
        XCTAssertEqual(CoverFillGuard.skipped(among: ["keyed.example"], blocks: blocks), [], "Nothing is skipped when nothing else can be read")

        XCTAssertEqual(outcome([], 500), .run)
        XCTAssertEqual(outcome(["keyed.example", "b.example"], 500), .run, "Another website is read instead")
        XCTAssertEqual(outcome(["keyed.example"], CoverFillGuard.quietLimit), .run, "A few new saves are read without asking")
        XCTAssertEqual(outcome(["keyed.example"], 50), .ask(pending: 50, sites: ["keyed.example"]))

        CoverFillGuard.record(.declined, pending: 50, in: defaults)
        XCTAssertEqual(outcome(["keyed.example"], 50), .hold)
        XCTAssertEqual(outcome(["keyed.example"], 55), .hold)
        XCTAssertEqual(outcome(["keyed.example"], 50, manual: true), .ask(pending: 50, sites: ["keyed.example"]), "The fill button asks again")
        XCTAssertEqual(outcome(["keyed.example"], 61), .ask(pending: 61, sites: ["keyed.example"]), "An import asks again")

        CoverFillGuard.record(.approved, pending: 61, in: defaults)
        XCTAssertEqual(outcome(["keyed.example"], 61), .run)
        XCTAssertEqual(outcome(["keyed.example"], 20), .run)
        XCTAssertEqual(CoverFillGuard.decision(in: defaults).baseline, 20, "Filled works lower the mark")
        XCTAssertEqual(outcome(["keyed.example"], 30), .run)
        XCTAssertEqual(outcome(["keyed.example"], 31), .ask(pending: 31, sites: ["keyed.example"]), "Works saved since are asked about")

        CoverFillGuard.forget(in: defaults)
        XCTAssertEqual(CoverFillGuard.decision(in: defaults).0, .none)
    }

    func testWorkSitesAreKeptAcrossLaunches() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("work-sites-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let memory = WorkSiteMemory(file: file, limit: 3)
        for id in 1...4 { memory.remember(Int64(id), site: "b.example") }
        XCTAssertNil(memory.site(for: 1), "The oldest entries make room for new ones")
        XCTAssertEqual(memory.site(for: 4), "b.example")
        memory.remember(4, site: nil)
        XCTAssertNil(memory.site(for: 4))
        let saved = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { saved.fulfill() }
        wait(for: [saved], timeout: 5)
        let reloaded = WorkSiteMemory(file: file, limit: 3)
        XCTAssertEqual(reloaded.site(for: 3), "b.example")
        XCTAssertNil(reloaded.site(for: 4))
    }

    // MARK: Work pages

    func testWorkPageRatingStatsFavoriteAndComments() throws {
        let extras = KeyedWorkPage.extras(from: Self.workPage)
        XCTAssertEqual(extras.rating, 4.65)
        XCTAssertEqual(extras.ratingCount, 321)
        XCTAssertEqual(extras.favorited, 1234)
        XCTAssertEqual(extras.fileSize, "45.67 MiB")
        XCTAssertEqual(extras.length, 24)
        XCTAssertEqual(extras.parentID, 2999)
        XCTAssertEqual(extras.uploader, "someone")
        XCTAssertEqual(extras.posted, KeyedWorkPage.postedDate("2024-03-05 10:20"))
        XCTAssertNotNil(extras.posted)
        XCTAssertEqual(extras.favoriteCategory, 2)
        XCTAssertEqual(extras.favoriteName, "Reading")
        XCTAssertEqual(extras.torrentCount, 2)
        XCTAssertEqual(extras.torrentsURL?.query, "gid=3000&t=0000000bb8")
        XCTAssertTrue(extras.hasMoreComments)
        XCTAssertTrue(extras.canRate)
        XCTAssertEqual(KeyedWorkPage.apiKey(in: Self.workPage), .init(uid: 1234567, key: "0123456789abcdef"))
        XCTAssertEqual(extras.comments.count, 2)
        let note = try XCTUnwrap(extras.comments.first)
        XCTAssertTrue(note.isUploader)
        XCTAssertNil(note.score)
        XCTAssertEqual(note.text, "Thanks for reading\nPart 2 soon")
        let comment = extras.comments[1]
        XCTAssertEqual(comment.author, "reader")
        XCTAssertEqual(comment.score, 15)
        XCTAssertEqual(comment.text, "Great & fun")
        XCTAssertNotNil(comment.posted)
        XCTAssertEqual(WorkExtrasSection.preview([comment, note]).first?.id, 0, "The uploader's note leads the preview")

        let unrated = KeyedWorkPage.extras(from: ##"<td id="rating_label" colspan="3">Not Yet Rated</td><a id="favoritelink" href="#">Add to Favorites</a>"##)
        XCTAssertNil(unrated.rating)
        XCTAssertNil(unrated.favoriteCategory)
        XCTAssertFalse(unrated.canRate)
    }

    func testTorrentsFavoritesCategoriesAndImageAllowance() throws {
        let torrents = KeyedWorkPage.torrents(from: Self.torrentPage)
        XCTAssertEqual(torrents.count, 1)
        let torrent = try XCTUnwrap(torrents.first)
        XCTAssertEqual(torrent.name, "Sample Work.zip")
        XCTAssertEqual(torrent.size, "45.6 MiB")
        XCTAssertEqual(torrent.seeds, 3)
        XCTAssertEqual(torrent.peers, 1)
        XCTAssertEqual(torrent.downloads, 120)
        XCTAssertEqual(torrent.posted, "2024-03-05 12:00")
        XCTAssertEqual(torrent.uploader, "seeder")
        XCTAssertEqual(torrent.magnet?.absoluteString.hasPrefix("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"), true)

        let categories = KeyedCatalogSource.favoriteCategories(in: Self.favoritesPage)
        XCTAssertEqual(categories.map(\.id), [0, 1, 9])
        XCTAssertEqual(categories.map(\.name), ["Favorites 0", "Reading", "Later"])
        XCTAssertEqual(categories.map(\.count), [12, 1234, 0])

        let allowance = try XCTUnwrap(KeyedCatalogSource.imageAllowance(in: "<p>You are currently at <strong>1,234</strong> towards a limit of <strong>5,000</strong>.</p>"))
        XCTAssertEqual(allowance.used, 1234)
        XCTAssertEqual(allowance.limit, 5000)
        XCTAssertNil(KeyedCatalogSource.imageAllowance(in: "<p>Nothing here</p>"))
    }

    func testRankingsTheWebsiteLinksToBecomeSorts() {
        resolveKeyed("keyed.example")
        XCTAssertEqual(GallerySort.available, [.latest, .today])
        MangaUrls.noteKeyedNavigation(#"<a href="https://other.example/toplist.php">Toplists</a><a href="https://keyed.example/watched">Watched</a>"#, site: "https://keyed.example/")
        XCTAssertEqual(MangaUrls.keyedFeatures, [.watched], "A toplist on another host is not this website's")
        XCTAssertEqual(GallerySort.available, [.latest, .today], "Watched tags need a signed-in account")
        XCTAssertTrue(SiteAccount.signIn(pasted: SiteAccount.parseCookies("ipb_member_id=7; ipb_pass_hash=0123456789abcdef0123456789abcdef"), host: "keyed.example"))
        MangaUrls.noteKeyedNavigation(#"<a href="https://keyed.example/toplist.php">Toplists</a>"#, site: "https://keyed.example/")
        XCTAssertEqual(GallerySort.available, [.latest, .today, .month, .year, .allTime, .watched])
        XCTAssertEqual(GallerySort.allTime.toplist, 11)
        XCTAssertNil(GallerySort.watched.toplist)
        connect("indexed.example")
        XCTAssertEqual(GallerySort.available, [.latest, .today, .week, .month, .year])
    }

    // MARK: Cache

    func testOneCacheSizeLimitHoldsForEveryReader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("page-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ComicsPageDiskCache(directory: directory, megabytes: 256)
        let page = Data(repeating: 7, count: 1024)
        await cache.write(page, key: "a")
        await cache.write(page, key: "b")
        let used = await cache.usedBytes()
        XCTAssertEqual(used, 2048)
        let read = await cache.read("a")
        XCTAssertEqual(read, page)
        await cache.clear()
        let cleared = await cache.usedBytes()
        XCTAssertEqual(cleared, 0)
        XCTAssertTrue(ComicsPageDiskCache.choices.contains(ComicsPageDiskCache.defaultMegabytes))
    }


    // MARK: Members-only document catalogs

    func testAMembersOnlyCatalogListsOpenlyAndOpensWorksWithItsOwnSignIn() async throws {
        connect("private.example")
        StubProtocol.handler = { request in
            let url = request.url!
            let signedIn = request.value(forHTTPHeaderField: "Cookie")?.contains("site_session=abc") == true
            switch url.path {
            case "/":
                return (302, ["Location": "/account/login?redirect=%2F"], Data())
            case "/account/login":
                return (200, ["Content-Type": "text/html"], Data(Self.memberSignInPage.utf8))
            case "/ajax/search":
                let rows: [[String: Any]] = [["id": 3000, "title": "Sample", "category": 2, "views": 10, "blocked": 0,
                                              "thumb_extension": "jpg", "filecount": 13, "tags": [["tag": ["language", "korean"]]]]]
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: rows))
            case "/r/3000":
                guard signedIn else { return (302, ["Location": "/account/login?redirect=%2Fr%2F3000"], Data()) }
                return (200, ["Content-Type": "text/html"], Data(Self.memberWork.utf8))
            default:
                return (404, ["Content-Type": "text/html"], Data())
            }
        }
        XCTAssertTrue(MangaUrls.isDocumentPage(Self.memberSignInPage), "Its sign-in page names the same catalog")
        let source = MangaContentSource(transport: transport())
        let batch = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 5)
        XCTAssertEqual(batch.ids, [3000], "Lists stay open to everyone")
        XCTAssertEqual(MangaUrls.backend, .document)
        XCTAssertTrue(MangaUrls.usesSiteSession)
        XCTAssertEqual(MangaUrls.signInURL?.path, "/account/login")
        XCTAssertEqual(source.cachedPreview(3000)?.displayedPageCount, 13, "A list row's page count shows before the work opens")
        XCTAssertFalse(SiteAccount.isSignedIn(host: "private.example"))

        do {
            _ = try await source.gallery(3000)
            XCTFail("A signed-out visitor is sent to the sign-in page")
        } catch { XCTAssertEqual(error as? ContentError, .signInRequired) }

        let cookies = try ["site_session": ".private.example", "_ga": ".private.example", "cf_clearance": ".private.example", "other": ".elsewhere.example"].map { name, domain in
            try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: name == "site_session" ? "abc" : "x"]))
        }
        XCTAssertTrue(SiteAccount.signIn(session: cookies, host: "private.example"))
        XCTAssertTrue(SiteAccount.isSignedIn(host: "private.example"))
        XCTAssertFalse(SiteAccount.isSignedIn, "A site's own sign-in is not the forum identity")
        let sent = SiteAccount.cookies(forSite: "private.example")
        XCTAssertEqual(sent["site_session"], "abc")
        XCTAssertNil(sent["_ga"]); XCTAssertNil(sent["cf_clearance"]); XCTAssertNil(sent["other"])

        let work = try await source.gallery(3000)
        XCTAssertEqual(work.pages.count, 2)
        XCTAssertEqual(work.displayedPageCount, 2)

        SiteAccount.signOut(host: "private.example")
        XCTAssertFalse(SiteAccount.isSignedIn(host: "private.example"))
    }

    func testPageCountsComeFromListsAndStayWithSavedWorks() throws {
        var preview = NativeGallery(id: 1, title: "", artists: [], language: "", type: "", tags: [],
                                    pages: [GalleryPage(hash: "h", name: "cover", width: 0, height: 0, hasAVIF: false)])
        XCTAssertEqual(preview.displayedPageCount, 1)
        preview.pageCount = 0
        XCTAssertNil(preview.displayedPageCount, "A list row that does not say has no count, not one page")
        preview.pageCount = 24
        XCTAssertEqual(preview.displayedPageCount, 24)

        let database = try AppDatabase.inMemory()
        _ = try database.upsertWork(galleryId: 42, title: "Saved", pageCount: 24)
        XCTAssertEqual(try database.getWork(galleryId: 42)?.pageCount, 24)
        _ = try database.upsertWork(galleryId: 42, title: "Saved", pageCount: nil)
        XCTAssertEqual(try database.getWork(galleryId: 42)?.pageCount, 24, "A save that does not know keeps the count")
        try database.fillPageCount(galleryId: 42, count: 30)
        XCTAssertEqual(try database.getWork(galleryId: 42)?.pageCount, 30)
        try database.fillPageCount(galleryId: 7, count: 30)
        XCTAssertNil(try database.getWork(galleryId: 7), "Opening an unsaved work saves nothing")
        XCTAssertEqual(ReadingQueueItem(work: try XCTUnwrap(database.getWork(galleryId: 42))).pages, 30)
        XCTAssertTrue(LibrarySyncAdapter.columns["manga.works"]?.contains("page_count") == true)
        XCTAssertTrue(LibrarySyncAdapter.keepsKnownValue.contains("page_count"), "A device that does not know the count never clears it")
    }

    static let memberSignInPage = #"""
    <html><head><title>Login</title>
    <script>const serverConfig = { test: false, isSecretHost: true, thumbServer: {"url":"https:\/\/thumbs.private.example"} };</script>
    <script src="/js/index.head.js?1"></script></head>
    <body><form id="loginForm" method="post" action="/ajax/account-login">
    <input type="hidden" name="csrf" value="x"><input type="text" name="username"><input type="password" name="password">
    <div class="cf-turnstile" data-sitekey="x"></div><button type="submit">Login</button></form></body></html>
    """#

    static let memberWork = #"""
    <html><head><script>
    const gallery = {"id":3000,"title":"Sample","title_jpn":null,"category":2,"blocked":0,"tags":[{"tag":["language","korean"]}],
    "files":[{"id":"a","name":"1.webp","image":{"url":"https://media.private.example/1.webp","width":10,"height":10}},
             {"id":"b","name":"2.webp","image":{"url":"https://media.private.example/2.webp","width":10,"height":10}}]};
    </script></head><body></body></html>
    """#

    // MARK: Fixtures

    static let workPage = #"""
    <div id="gdn"><a href="https://keyed.example/uploader/someone">someone</a></div>
    <div id="gdd"><table>
    <tr><td class="gdt1">Posted:</td><td class="gdt2">2024-03-05 10:20</td></tr>
    <tr><td class="gdt1">Parent:</td><td class="gdt2"><a href="https://keyed.example/g/2999/0000000bb7/">2999</a></td></tr>
    <tr><td class="gdt1">Visible:</td><td class="gdt2">Yes</td></tr>
    <tr><td class="gdt1">Language:</td><td class="gdt2">Korean &nbsp;</td></tr>
    <tr><td class="gdt1">File Size:</td><td class="gdt2">45.67 MiB</td></tr>
    <tr><td class="gdt1">Length:</td><td class="gdt2">24 pages</td></tr>
    <tr><td class="gdt1">Favorited:</td><td class="gdt2" id="favcount">1,234 times</td></tr>
    </table></div>
    <div id="gdr"><table><tr><td id="rating_label" colspan="3">Average: 4.65</td></tr>
    <tr><td class="grt1">Rating:</td><td><span id="rating_count">321</span></td></tr></table></div>
    <div id="gdf"><div id="fav"><div class="i" style="background-image:url(https://media.example/fav.png); background-position:0px -40px; margin-left:16px" title="Reading"></div></div>
    <a id="favoritelink" href="#" onclick="return popUp('https://keyed.example/gallerypopups.php?gid=3000&amp;t=0000000bb8&amp;act=addfav',675,415)">Reading</a></div>
    <p class="g2 gsp"><a href="#" onclick="return popUp('https://keyed.example/gallerytorrents.php?gid=3000&amp;t=0000000bb8',610,590)">Torrent Download (2)</a></p>
    <script>var apiuid = 1234567; var apikey = "0123456789abcdef";</script>
    <div id="cdiv" class="gm">
    <div class="c1"><div class="c2"><div class="c3">Posted on 05 March 2024, 10:21 by: &nbsp; <a href="https://keyed.example/uploader/someone">someone</a></div><div class="c4 nosel">Uploader Comment</div><div class="c"></div></div><div class="c6" id="comment_0">Thanks for reading<br>Part 2 soon</div></div>
    <div class="c1"><div class="c2"><div class="c3">Posted on 06 March 2024, 11:00 by: &nbsp; <a href="https://keyed.example/index.php?showuser=42">reader</a>&nbsp; &nbsp; <a href="https://keyed.example/index.php?act=Msg">[PM]</a></div><div class="c5 nosel">Score <span id="comment_score_123">+15</span></div><div class="c"></div></div><div class="c6" id="comment_123">Great &amp; fun</div></div>
    </div>
    <div id="chd"><p>There are 12 more comments - <a href="https://keyed.example/g/3000/0000000bb8/?hc=1#comments">click to show all</a>.</p></div>
    """#

    static let torrentPage = #"""
    <form method="post" action="https://keyed.example/gallerytorrents.php?gid=3000&amp;t=0000000bb8">
    <div><table style="width:99%">
    <tr><td style="width:190px"><span style="font-weight:bold">Posted:</span> <span>2024-03-05 12:00</span></td><td><span style="font-weight:bold">Size:</span> 45.6 MiB</td><td><span style="font-weight:bold">Seeds:</span> 3</td><td><span style="font-weight:bold">Peers:</span> 1</td><td><span style="font-weight:bold">Downloads:</span> 120</td></tr>
    <tr><td colspan="5"><span style="font-weight:bold">Uploader:</span> seeder</td></tr>
    <tr><td colspan="5"> &nbsp; <a href="https://tracker.example/get/3000/0123456789abcdef0123456789abcdef01234567.torrent?p=x">Sample Work.zip</a></td></tr>
    </table></div></form>
    """#

    static let favoritesPage = #"""
    <div class="ido"><div class="nosel">
    <div class="fp" onclick="document.location='https://keyed.example/favorites.php?favcat=0'"><div>12</div><div class="i" style="background-position:0px -2px" title="Favorites 0"></div><div>Favorites 0</div></div>
    <div class="fp fps" onclick="document.location='https://keyed.example/favorites.php?favcat=1'"><div>1,234</div><div class="i" style="background-position:0px -21px" title="Reading"></div><div>Reading</div></div>
    <div class="fp" onclick="document.location='https://keyed.example/favorites.php?favcat=9'"><div>0</div><div class="i" style="background-position:0px -173px" title="Later"></div><div>Later</div></div>
    <div style="clear:both"></div>
    <div class="fp fps" onclick="document.location='https://keyed.example/favorites.php'" style="width:140px">Show All Favorites</div>
    </div></div>
    """#
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func add(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private actor FakeSite: ContentProviding {
    let name: String
    let works: [Int64: String]
    /// What the website answers every request with instead of a work.
    let refusal: ContentError?
    private(set) var calls = 0
    init(name: String, works: [Int64: String], refusal: ContentError? = nil) { self.name = name; self.works = works; self.refusal = refusal }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        calls += 1
        if let refusal { throw refusal }
        guard let title = works[id] else { throw ContentError.galleryNotFound }
        return NativeGallery(id: id, title: title, artists: [], language: "", type: "", tags: [], pages: [])
    }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { GalleryBatch(ids: [], hasMore: false) }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data { Data(name.utf8) }
}

private final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private static let lock = NSLock()
    private nonisolated(unsafe) static var stored: Handler?
    static var handler: Handler? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location, relativeTo: url)?.absoluteURL {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
