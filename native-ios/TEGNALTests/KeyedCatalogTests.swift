import XCTest
import UIKit
@testable import TEGNAL

final class KeyedCatalogTests: XCTestCase {
    private let keys = ["manga.site_address", "manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site",
                        "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base", "manga.resolved_api",
                        "manga.resolved_login", "manga.account_site", "manga.account_host", "manga.account_required"]
    private var saved: [String: Any] = [:]
    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = MangaUrls.preferences.object(forKey: key) }
        for key in keys { MangaUrls.preferences.removeObject(forKey: key) }
        MangaUrls.preferences.set("keyed.example", forKey: "manga.site_address")
        GalleryKeys.shared.removeAll()
        SiteAccount.signOut()
    }
    override func tearDown() {
        KeyedFixtureProtocol.install(nil)
        SiteAccount.signOut()
        GalleryKeys.shared.removeAll()
        for key in keys { MangaUrls.preferences.set(saved[key], forKey: key) }
        super.tearDown()
    }
    private func fixture() -> KeyedFixture {
        let fixture = KeyedFixture()
        KeyedFixtureProtocol.install(fixture)
        return fixture
    }

    func testListingResolvesTheProtocolAndFollowsTheCursor() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let first = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        XCTAssertEqual(first.ids, [3002, 3001, 3000])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(MangaUrls.backend, .keyed)
        XCTAssertEqual(MangaUrls.keyedAPI?.absoluteString, "https://api.keyed.example/api.php")
        XCTAssertEqual(MangaUrls.signInURL?.absoluteString, "https://keyed.example/bounce_login.php?b=d&bt=1")
        XCTAssertEqual(MangaUrls.galleryUrl(for: 3000), "https://keyed.example/g/3000/\(KeyedFixture.key(3000))/")
        XCTAssertEqual(GallerySort.available, [.latest, .today])
        XCTAssertTrue(GalleryCategory.available.contains("western"))

        let second = try await source.list(GalleryQuery(language: "all"), offset: 3, count: 3)
        XCTAssertEqual(second.ids, [2999, 2998])
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(fixture.requests.contains { $0.query?.contains("next=2999") == true })

        let preview = try XCTUnwrap(source.cachedPreview(3000))
        XCTAssertEqual(preview.title, "Sample 3000", "A translation leads with its translated title")
        XCTAssertEqual(source.cachedPreview(2999)?.title, "原題 2999", "A work still in Japanese leads with its original title")
        XCTAssertEqual(source.cachedPreview(3001)?.type, "manga")
        XCTAssertEqual(preview.artists, ["sample artist"])
        XCTAssertEqual(preview.language, "korean")
        XCTAssertTrue(preview.tags.contains("series:sample series"))
        XCTAssertTrue(preview.tags.contains("tag:sample tag"))
        XCTAssertEqual(fixture.count(path: "/api.php"), 2, "Each listing page reads its details in one batch")
    }

    func testSearchesSendTagsCategoriesAndExclusionsInTheSiteSpelling() async throws {
        let query = GalleryQuery(language: "korean", artist: "sample artist", text: "female:big_breasts series:sample -tag:excluded type:manga")
        let url = try KeyedCatalogSource.searchURL(query, site: "https://keyed.example/", categories: try KeyedCatalogSource.selectedCategories(query),
                                                   language: "korean", next: "2999")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "f_search" }?.value,
                       #"female:"big breasts$" parody:"sample$" language:"korean$" artist:"sample artist$" -other:"excluded$""#)
        XCTAssertEqual(items.first { $0.name == "f_cats" }?.value, String(1023 & ~4))
        XCTAssertEqual(items.first { $0.name == "next" }?.value, "2999")
        XCTAssertNil(try URLComponents(url: KeyedCatalogSource.searchURL(GalleryQuery(language: "all"), site: "https://keyed.example/",
                                                                      categories: KeyedCatalogSource.allCategories, language: nil, next: nil),
                                       resolvingAgainstBaseURL: false)?.queryItems)

        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let filtered = try await source.list(GalleryQuery(language: "all", text: "-female:marked_tag"), offset: 0, count: 5)
        XCTAssertFalse(filtered.ids.contains(3002), "Exclusions also apply to rows the site still returned")
        let manga = try await source.list(GalleryQuery(language: "all", text: "type:manga"), offset: 0, count: 5)
        XCTAssertEqual(manga.ids, [3001])
    }

    func testWorkPagesPreviewsAndReaderImages() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 3)
        let gallery = try await source.gallery(3000)
        XCTAssertEqual(gallery.pages.count, 3)
        XCTAssertEqual(gallery.pages[1].name, "two.jpg")
        XCTAssertEqual(gallery.pages[0].thumbnailURL?.absoluteString, "https://covers.example/3000.jpg", "The first page shows the cover")

        let cover = try await source.image(gallery.pages[0], galleryID: 3000, thumbnail: true)
        XCTAssertEqual(cover, fixture.image)
        let tileData = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: true)
        let tile = try XCTUnwrap(UIImage(data: tileData))
        XCTAssertEqual(tile.size, CGSize(width: 100, height: 150), "A page preview is cut out of the sheet of previews")
        _ = try await source.image(gallery.pages[0], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(fixture.count(path: "/3000-0.png"), 1, "Tiles of one sheet share one download")

        _ = try await source.image(gallery.pages[2], galleryID: 3000, thumbnail: true)
        XCTAssertTrue(fixture.requests.contains { $0.path == "/g/3000/\(KeyedFixture.key(3000))" && $0.query == "p=1" },
                      "Pages past the first sheet are read when they are needed")

        fixture.failFirstNode = true
        let page = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
        XCTAssertEqual(page, fixture.image)
        XCTAssertTrue(fixture.requests.contains { $0.host == "node2.volunteer.example" && $0.port == 8440 }, "A failed host is replaced by another one")
        XCTAssertTrue(fixture.requests.contains { $0.query == "nl=alt-2" })
    }

    func testImageAllowanceNoticeIsReportedInsteadOfShown() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let gallery = try await source.gallery(3000)
        fixture.allowanceUsed = true
        do {
            _ = try await source.image(gallery.pages[1], galleryID: 3000, thumbnail: false)
            XCTFail("The notice image must not be shown as a page")
        } catch ContentError.imageLimit { }
    }

    func testForgottenKeyIsFoundBySearchingTheNumber() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        GalleryKeys.shared.removeAll()
        XCTAssertEqual(MangaUrls.galleryUrl(for: 2990), "https://keyed.example/?f_search=gid:2990")
        let gallery = try await source.gallery(2990)
        XCTAssertEqual(gallery.id, 2990)
        XCTAssertTrue(fixture.requests.contains { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "f_search", value: "gid:2990")) == true })
        XCTAssertEqual(GalleryKeys.shared.key(for: 2990), KeyedFixture.key(2990))
    }

    func testMembersOnlySiteAsksForSignInThenSendsOnlyTheIdentity() async throws {
        MangaUrls.preferences.set("members.example", forKey: "manga.site_address")
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        do {
            _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 2)
            XCTFail("A signed-out visitor sees nothing")
        } catch ContentError.signInRequired { }
        XCTAssertTrue(MangaUrls.requiresSignIn)
        XCTAssertEqual(MangaUrls.accountHost, "account.example")
        XCTAssertEqual(MangaUrls.signInURL?.absoluteString, "https://account.example/index.php?act=Login&CODE=00")

        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret"), ("tracking", "1")].map {
            HTTPCookie(properties: [.domain: ".account.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies))
        MangaUrls.resetResolvedBackend()
        let batch = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 2)
        XCTAssertEqual(batch.ids, [3002, 3001])
        let header = try XCTUnwrap(fixture.cookies.last)
        XCTAssertTrue(header.contains("app_member_id=42") && header.contains("app_pass_hash=secret") && header.contains("nw=1"))
        XCTAssertFalse(header.contains("tracking"), "Only the account identity is kept from sign-in")
        XCTAssertTrue(header.contains("access=granted"), "Cookies the site grants are sent back to it")
        XCTAssertNil(SiteAccount.cookieHeader(for: URL(string: "https://covers.example/3000.jpg")!), "The identity never reaches other hosts")

        MangaUrls.preferences.set("catalog.example", forKey: "manga.site_address")
        XCTAssertNil(SiteAccount.cookieHeader(for: URL(string: "https://catalog.example/")!), "Sites that do not use accounts never receive it")
    }

    func testAccountFavoritesImportAndMirrorBookmarks() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        _ = try await source.list(GalleryQuery(language: "all"), offset: 0, count: 1)
        do {
            _ = try await source.accountFavorites(after: nil)
            XCTFail("Favorites belong to a signed-in account")
        } catch ContentError.signInRequired { }
        let cookies = [("app_member_id", "42"), ("app_pass_hash", "secret")].map {
            HTTPCookie(properties: [.domain: ".keyed.example", .path: "/", .name: $0.0, .value: $0.1])!
        }
        XCTAssertTrue(SiteAccount.signIn(with: cookies))
        let first = try await source.accountFavorites(after: nil)
        XCTAssertEqual(first.ids, [2998, 2990])
        XCTAssertEqual(first.next, "2990")
        let last = try await source.accountFavorites(after: first.next)
        XCTAssertEqual(last.ids, [2980])
        XCTAssertNil(last.next)
        XCTAssertNotNil(source.cachedPreview(2980), "Imported favorites carry their titles and tags")

        try await source.setAccountFavorite(3000, saved: true)
        try await source.setAccountFavorite(3000, saved: false)
        XCTAssertEqual(fixture.favoriteForms, ["favcat=0&favnote=&apply=Add+to+Favorites&update=1", "favcat=favdel&favnote=&update=1"])
        XCTAssertTrue(fixture.requests.contains { $0.path == "/gallerypopups.php" && $0.query?.contains("t=\(KeyedFixture.key(3000))") == true })
    }

    func testPopularNarrowsBySearchLanguageAndCategory() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let all = try await source.list(GalleryQuery(language: "all", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(all.ids, [2999, 3000, 3001])
        let korean = try await source.list(GalleryQuery(language: "korean", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(korean.ids, [3000, 3001])
        let manga = try await source.list(GalleryQuery(language: "all", text: "type:manga", sort: .today), offset: 0, count: 10)
        XCTAssertEqual(manga.ids, [3001])
        XCTAssertEqual(fixture.count(path: "/popular"), 1)
    }

    func testSuggestionsUseTheAppNamespacesAndCanonicalTags() async throws {
        let fixture = fixture(), source = MangaContentSource(transport: fixture.transport())
        let suggestions = try await source.suggestions(for: "-sample")
        XCTAssertEqual(suggestions.map(\.token), ["series:sample_series", "female:sample_tag"])
        let narrowed = try await source.suggestions(for: "series:sam")
        XCTAssertEqual(narrowed.map(\.token), ["series:sample_series"])
    }

    func testSiteLinksAndSearchesOpenInTheApp() {
        let link = "https://keyed.example/g/3000/\(KeyedFixture.key(3000))/"
        XCTAssertEqual(ContentRoute.initial(link), .gallery(3000))
        XCTAssertEqual(GalleryKeys.shared.key(for: 3000), KeyedFixture.key(3000))
        XCTAssertEqual(GalleryIDParser.parse("look at " + link), [3000])
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/?f_search=gid%3A3000"), .gallery(3000))
        XCTAssertEqual(ContentRoute.initial("https://keyed.example/?f_search=artist%3A%22sample+artist%24%22+-other%3A%22x+y%24%22"),
                       .query("artist:sample_artist -tag:x_y"))
        XCTAssertNil(ContentRoute.initial("https://other.example/g/3000/\(KeyedFixture.key(3000))/"))
    }

    func testPreviewTilesAreCutFromTheSheet() throws {
        let tile = try KeyedCatalogSource.cropped(KeyedFixture.sheet, to: CGRect(x: 100, y: 0, width: 100, height: 150))
        let image = try XCTUnwrap(UIImage(data: tile)?.cgImage)
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 150)
        let entries = KeyedCatalogSource.entries(in: String(decoding: KeyedFixture.detail(3000, page: 0), as: UTF8.self), galleryID: 3000)
        XCTAssertEqual(entries[1]?.thumb?.crop, CGRect(x: 100, y: 0, width: 100, height: 150))
        XCTAssertEqual(entries[1]?.key, "2222222222")
        XCTAssertTrue(entries[0]?.thumb.flatMap(KeyedCatalogSource.encoded).map { KeyedCatalogSource.thumb(from: $0) == entries[0]?.thumb } ?? false)
    }
}

private final class KeyedFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var sentCookies: [String] = []
    private var forms: [String] = []
    var failFirstNode = false
    var allowanceUsed = false
    let image = Data(repeating: 0x42, count: 64)
    var requests: [URL] { lock.withLock { recorded } }
    var cookies: [String] { lock.withLock { sentCookies } }
    var favoriteForms: [String] { lock.withLock { forms } }
    func count(path: String) -> Int { requests.filter { $0.path == path }.count }

    static func key(_ id: Int64) -> String {
        let hex = String(id, radix: 16)
        return String(repeating: "0", count: 10 - hex.count) + hex
    }

    static let sheet: Data = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 150), format: {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
    }()).pngData { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        UIColor.blue.setFill(); context.fill(CGRect(x: 100, y: 0, width: 100, height: 150))
    }

    func transport() -> ContentTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyedFixtureProtocol.self]
        return ContentTransport(configuration: configuration)
    }

    private static func listing(_ ids: [Int64], next: Int64?) -> Data {
        let rows = ids.map { #"<tr><td class="gl3c"><a href="https://keyed.example/g/\#($0)/\#(key($0))/"><div class="glink">Sample \#($0)</div></a></td></tr>"# }.joined()
        let nav = next.map { #"<div class="searchnav"><a id="unext" href="https://keyed.example/?f_search=x&amp;next=\#($0)">Next &gt;</a></div>"# } ?? #"<div class="searchnav"><span id="unext">Next &gt;</span></div>"#
        return Data(#"<html><body><form><input type="text" id="f_search" name="f_search"></form><table class="itg">\#(rows)</table>\#(nav)</body></html>"#.utf8)
    }

    static func detail(_ id: Int64, page: Int) -> Data {
        let entries: [(String, Int, String, String, Int)] = page == 0
            ? [("1111111111", 1, "one.jpg", "\(id)-0.png", 0), ("2222222222", 2, "two.jpg", "\(id)-0.png", -100)]
            : [("3333333333", 3, "three.jpg", "\(id)-1.png", 0)]
        let links = entries.map { key, number, name, sheet, offset in
            #"<a href="https://keyed.example/s/\#(key)/\#(id)-\#(number)"><div title="Page \#(number): \#(name)" style="width:100px;height:150px;background:transparent url(https://sheets.example/\#(sheet)) \#(offset)px 0 no-repeat"></div></a>"#
        }.joined()
        return Data(#"<html><script>var api_url = "https://api.keyed.example/api.php";\#nvar login_url = "https://keyed.example/bounce_login.php?b=d&bt=1";</script><div id="gdt">\#(links)</div></html>"#.utf8)
    }

    private func details(_ body: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        if request["method"] as? String == "tagsuggest" {
            return try JSONSerialization.data(withJSONObject: ["tags": ["1": ["ns": "parody", "tn": "sample series"],
                                                                         "2": ["ns": "temp", "tn": "sample alias", "mns": "female", "mtn": "sample tag"],
                                                                         "3": ["ns": "temp", "tn": "loose word"]]])
        }
        let items = (request["gidlist"] as! [[Any]]).map { pair -> [String: Any] in
            let id = (pair[0] as! NSNumber).int64Value
            guard pair[1] as? String == Self.key(id) else { return ["gid": id, "error": "Key missing, or incorrect key provided."] }
            var tags = [id == 2999 ? "language:japanese" : "language:korean", "artist:sample artist", "parody:sample series", "other:sample tag"]
            if id != 2999 { tags.append("language:translated") }
            if id == 3002 { tags.append("female:marked tag") }
            return ["gid": id, "token": Self.key(id), "title": "Sample \(id)", "title_jpn": "原題 \(id)",
                    "category": id == 3001 ? "Manga" : "Doujinshi", "thumb": "https://covers.example/\(id).jpg",
                    "filecount": "3", "tags": tags]
        }
        return try JSONSerialization.data(withJSONObject: ["gmetadata": items])
    }

    enum Reply {
        case data(Int, Data, [String: String])
        case redirect(URL)
    }

    func reply(_ request: URLRequest) throws -> Reply {
        let url = request.url!
        lock.withLock {
            recorded.append(url)
            if let cookie = request.value(forHTTPHeaderField: "Cookie") { sentCookies.append(cookie) }
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "covers.example": return .data(200, image, ["Content-Type": "image/jpeg"])
        case "sheets.example": return .data(200, Self.sheet, ["Content-Type": "image/png"])
        case "node1.volunteer.example":
            return failFirstNode ? .data(503, Data(), [:]) : .data(200, image, ["Content-Type": "image/webp"])
        case "node2.volunteer.example": return .data(200, image, ["Content-Type": "image/webp"])
        case "notice.example": return .data(200, image, ["Content-Type": "image/gif"])
        case "api.keyed.example", "api.members.example":
            return .data(200, try details(Self.body(request)), ["Content-Type": "application/json"])
        case "members.example":
            guard (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("app_member_id=42") else {
                return .redirect(URL(string: "https://account.example/remoteapi.php?ex=token")!)
            }
            if url.path == "/" {
                return .data(200, Self.listing([3002, 3001, 3000], next: nil), ["Content-Type": "text/html", "Set-Cookie": "access=granted; path=/"])
            }
            return .data(200, Self.detail(3002, page: 0), ["Content-Type": "text/html"])
        case "keyed.example": break
        default: return .data(404, Data(), [:])
        }
        switch url.path {
        case "/":
            if let search = items.first(where: { $0.name == "f_search" })?.value, search.hasPrefix("gid:"), let id = Int64(search.dropFirst(4)) {
                return .data(200, Self.listing([id], next: nil), ["Content-Type": "text/html"])
            }
            let next = items.first { $0.name == "next" }?.value
            let ids: [Int64] = next == nil ? [3002, 3001, 3000] : [2999, 2998]
            var shown = ids
            if let cats = items.first(where: { $0.name == "f_cats" })?.value, let mask = Int(cats), mask & 4 == 0 { shown = ids.filter { $0 == 3001 } }
            return .data(200, Self.listing(shown, next: next == nil ? 2999 : nil), ["Content-Type": "text/html"])
        case "/popular": return .data(200, Self.listing([2999, 3000, 3001], next: nil), ["Content-Type": "text/html"])
        case "/favorites.php":
            guard (request.value(forHTTPHeaderField: "Cookie") ?? "").contains("app_member_id=42") else {
                return .data(200, Data(#"<html><form><input type="password" name="PassWord"></form></html>"#.utf8), ["Content-Type": "text/html"])
            }
            let next = items.first { $0.name == "next" }?.value
            return .data(200, next == nil ? Self.listing([2998, 2990], next: 2990) : Self.listing([2980], next: nil), ["Content-Type": "text/html"])
        case "/gallerypopups.php":
            lock.withLock { forms.append(String(decoding: Self.body(request), as: UTF8.self)) }
            return .data(200, Data("<html><script>window.opener.location.reload();</script></html>".utf8), ["Content-Type": "text/html"])
        default:
            let parts = url.path.split(separator: "/")
            if parts.first == "g", parts.count == 3, let id = Int64(parts[1]), String(parts[2]) == Self.key(id) {
                return .data(200, Self.detail(id, page: url.query == "p=1" ? 1 : 0), ["Content-Type": "text/html"])
            }
            if parts.first == "s", parts.count == 3, let number = parts[2].split(separator: "-").last {
                let reload = items.first { $0.name == "nl" }?.value
                let host = allowanceUsed ? "https://notice.example/g/509.gif" : reload == nil ? "https://node1.volunteer.example:8440/h/\(number).webp" : "https://node2.volunteer.example:8440/h/\(number).webp"
                let page = #"<html><div id="i3"><a href="/next"><img id="img" src="\#(host)" onerror="this.onerror=null; nl('alt-\#(number)')"></a></div><p>reader page with enough text to be a real page</p></html>"#
                return .data(200, Data(page.utf8), ["Content-Type": "text/html"])
            }
            return .data(404, Data(), [:])
        }
    }

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class KeyedFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixture: KeyedFixture?
    static func install(_ fixture: KeyedFixture?) { lock.withLock { Self.fixture = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let fixture = Self.lock.withLock({ Self.fixture }) else { throw URLError(.cancelled) }
            switch try fixture.reply(request) {
            case .data(let status, let data, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let target):
                let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
