import XCTest
@testable import TEGNAL

final class BooruAccountTests: XCTestCase {
    private let dan = BooruServer(id: "account-dan-\(UUID().uuidString)", name: "Danbooru", baseURL: URL(string: "https://example.com/booru")!, engine: .danbooru)
    private let gel = BooruServer(id: "account-gel-\(UUID().uuidString)", name: "Gelbooru", baseURL: URL(string: "https://example.org")!, engine: .gelbooru)
    private let moe = BooruServer(id: "account-moe-\(UUID().uuidString)", name: "Moebooru", baseURL: URL(string: "https://example.net")!, engine: .moebooru)

    func testParsersReadEachServersAccountAnswers() throws {
        XCTAssertEqual(BooruAccountParser.csrfToken("<head><meta name=\"csrf-param\" content=\"authenticity_token\"><meta name=\"csrf-token\" content=\"abc+/=\"></head>"), "abc+/=")
        XCTAssertNil(BooruAccountParser.danbooruIdentity(Data(#"{"id":null,"name":"Anonymous","level":0}"#.utf8)))
        XCTAssertEqual(BooruAccountParser.danbooruIdentity(Data(#"{"id":42,"name":"some_one","level":20}"#.utf8)), BooruAccountIdentity(userID: 42, name: "some_one"))
        func cookie(_ name: String, _ value: String) -> HTTPCookie { HTTPCookie(properties: [.domain: "example.org", .path: "/", .name: name, .value: value])! }
        XCTAssertEqual(BooruAccountParser.gelbooruIdentity(cookies: [cookie("user_id", "77"), cookie("pass_hash", "f00")])?.userID, 77)
        XCTAssertNil(BooruAccountParser.gelbooruIdentity(cookies: [cookie("user_id", "77")]), "An id without its hash is not a sign-in")
        XCTAssertEqual(BooruAccountParser.moebooruIdentity(cookies: [cookie("login", "a%20b"), cookie("pass_hash", "f00")])?.name, "a b")
        let options = "<td><input type=\"text\" value=\"&amp;api_key=0123456789abcdef0123456789abcdef&amp;user_id=77\" readonly></td>"
        let key = try XCTUnwrap(BooruAccountParser.gelbooruAPIKey(options))
        XCTAssertEqual(key.apiKey, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(key.userID, 77)
        XCTAssertEqual(BooruAccountParser.plainDText("[quote]x said:\nhi[/quote]\n[b]Nice[/b] \"link\":https://a.example/p [[tag_name]] {{blue_sky}}"),
                       "“x said:\nhi”\n\nNice link tag_name blue_sky")
    }

    func testCommentsReadFromJSONXMLAndBothPageShapes() throws {
        let danbooru = Data(#"[{"id":12,"body":"later","score":-1,"created_at":"2024-06-16T05:42:45.123-04:00","is_deleted":false,"creator":{"name":"b_user"}},{"id":9,"body":"first","score":3,"created_at":"2024-06-15T00:00:00.000Z","is_deleted":false,"creator":{"name":"a"}},{"id":10,"body":"gone","is_deleted":true,"creator":{"name":"c"}}]"#.utf8)
        let comments = BooruAccountParser.danbooruComments(danbooru)
        XCTAssertEqual(comments.map(\.id), [9, 12])
        XCTAssertEqual(comments.last?.author, "b user")
        XCTAssertEqual(comments.last?.score, -1)
        XCTAssertNotNil(comments.last?.posted)
        let xml = Data(#"<?xml version="1.0" encoding="UTF-8"?><comments type="array"><comment created_at="2024-06-16 05:42" post_id="5" body="Hello &amp; welcome" creator="someone" id="41104" creator_id="3"/></comments>"#.utf8)
        XCTAssertEqual(try BooruAccountParser.gelbooruAPIComments(xml).map(\.text), ["Hello & welcome"])
        let page = """
        <div id="comment-list"><div id="c41104">
            <div class="col1">
                <a href="index.php?page=account&amp;s=profile&amp;uname=0ncedash">0ncedash</a>
                <span>&gt;&gt; #41104</span><br />
                <b>Posted on 2024-06-16 05:42:45 Score: <a id="sc41104">3</a> (vote <a href="#">Up</a>)</b>
            </div>
            <div class="col2">5 million posts, awesome! :D</div>
        </div></div>
        """
        let parsed = BooruAccountParser.gelbooruPageComments(page)
        XCTAssertEqual(parsed.map(\.id), [41104])
        XCTAssertEqual(parsed.first?.author, "0ncedash")
        XCTAssertEqual(parsed.first?.score, 3)
        XCTAssertEqual(parsed.first?.text, "5 million posts, awesome! :D")
        XCTAssertNotNil(parsed.first?.posted)
        let modern = """
        <div class="commentBody"><a href="index.php?page=account&amp;s=profile&amp;id=5"><b>poster</b></a> #301 commented at 2024-01-02 03:04:05<br />Great picture</div>
        """
        let other = BooruAccountParser.gelbooruPageComments(modern)
        XCTAssertEqual(other.map(\.id), [301])
        XCTAssertEqual(other.first?.author, "poster")
        XCTAssertEqual(other.first?.text, "Great picture")
    }

    func testAPIAccessLinePastedIntoEitherFieldFillsBoth() {
        let line = "&api_key=348erj3kr&user_id=1824193"
        XCTAssertEqual(BooruCredentials(account: line, apiKey: "").normalized, BooruCredentials(account: "1824193", apiKey: "348erj3kr"))
        XCTAssertEqual(BooruCredentials(account: "", apiKey: " \(line)\n").normalized, BooruCredentials(account: "1824193", apiKey: "348erj3kr"))
        XCTAssertEqual(BooruCredentials(account: "1824193", apiKey: "&amp;api_key=abc&amp;user_id=7").normalized, BooruCredentials(account: "7", apiKey: "abc"))
        XCTAssertEqual(BooruCredentials(account: " name ", apiKey: " key ").normalized, BooruCredentials(account: "name", apiKey: "key"), "Other details are only trimmed")
    }

    func testAFavoritesPageWithNoImagesIsEmptyOnlyWhenItIsTheWebsitesOwnPage() {
        let empty = Data("<html><body><a href=\"index.php?page=favorites&amp;s=view&amp;id=7\">My Favorites</a><div id=\"paginator\"></div></body></html>".utf8)
        XCTAssertTrue(BooruAccountParser.isEmptyFavoritesPage(empty))
        let images = Data("<html><body><span class=\"thumb\"><a href=\"index.php?page=post&amp;s=view&amp;id=12\"></a></span></body></html>".utf8)
        XCTAssertFalse(BooruAccountParser.isEmptyFavoritesPage(images), "Images the parser didn't recognize are not an empty page")
        let link = Data("<html><body><a href=\"index.php?page=post&s=view&id=12\">12</a></body></html>".utf8)
        XCTAssertFalse(BooruAccountParser.isEmptyFavoritesPage(link))
        let check = Data("<html><head><title>Just a moment...</title></head><body><form id=\"challenge-form\"></form></body></html>".utf8)
        XCTAssertFalse(BooruAccountParser.isEmptyFavoritesPage(check), "A bot check never reads as no favorites")
        XCTAssertFalse(BooruAccountParser.isEmptyFavoritesPage(Data("{}".utf8)))
    }

    func testCommentFormKeepsHiddenFieldsWithoutPostingAnonymously() throws {
        let html = """
        <form method="post" action="index.php?page=search"><input name="tags"></form>
        <form method="post" action="index.php?page=comment&amp;id=5&amp;s=save">
          <textarea name="comment" rows="7"></textarea>
          <input type="checkbox" name="post_anonymous" checked> Anonymous
          <input type="hidden" name="conf" id="conf" value="0">
          <input type="submit" name="submit" value="Post comment">
          <input type="submit" name="preview" value="Preview">
        </form>
        """
        let form = try XCTUnwrap(BooruAccountParser.commentForm(html, text: "Nice"))
        XCTAssertEqual(form.action, "index.php?page=comment&id=5&s=save")
        XCTAssertEqual(form.fields.map { $0.0 + "=" + $0.1 }, ["comment=Nice", "conf=1", "submit=Post comment"])
        XCTAssertNil(BooruAccountParser.commentForm("<form action='x'><input name='a'></form>", text: "x"))
    }

    func testRequestsCarryEachServersSignInTheWayItExpects() throws {
        let key = BooruCredentials(account: "name", apiKey: "secret")
        let danbooru = try BooruAccountClient.request(server: dan, method: "POST", path: "favorites.json", query: [("post_id", "5")], form: [],
                                                      accept: "application/json", credentials: key)
        XCTAssertEqual(danbooru.url?.absoluteString, "https://example.com/booru/favorites.json?post_id=5")
        XCTAssertEqual(danbooru.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("name:secret".utf8).base64EncodedString())
        let moebooru = try BooruAccountClient.request(server: moe, method: "POST", path: "post/vote.json", query: [], form: [("id", "5"), ("score", "3")],
                                                      accept: "application/json", credentials: key)
        XCTAssertEqual(String(decoding: moebooru.httpBody ?? Data(), as: UTF8.self), "id=5&score=3&login=name&password_hash=secret")
        XCTAssertNil(moebooru.value(forHTTPHeaderField: "Authorization"))
        let page = try BooruAccountClient.request(server: gel, method: "GET", path: "public/addfav.php", query: [("id", "5")], form: nil,
                                                  accept: "text/html", credentials: key)
        XCTAssertEqual(page.url?.absoluteString, "https://example.org/public/addfav.php?id=5", "Page actions rely on the sign-in cookies, never the API key")
        let api = try BooruAccountClient.request(server: gel, method: "GET", path: "index.php", query: [("page", "dapi"), ("tags", "fav:7 a+b")], form: nil,
                                                 accept: "application/json", credentials: key)
        XCTAssertEqual(api.url?.query, "page=dapi&tags=fav%3A7%20a%2Bb&user_id=name&api_key=secret")
        let form = try BooruAccountClient.request(server: gel, method: "POST", path: "", query: [], form: [("comment", "a&b")], accept: "text/html",
                                                  credentials: .init(), target: URL(string: "https://example.org/index.php?page=comment&id=5&s=save"))
        XCTAssertEqual(form.url?.absoluteString, "https://example.org/index.php?page=comment&id=5&s=save")
        XCTAssertEqual(String(decoding: form.httpBody ?? Data(), as: UTF8.self), "comment=a%26b")
        XCTAssertThrowsError(try BooruAccountClient.request(server: gel, method: "POST", path: "", query: [], form: [], accept: "text/html",
                                                            credentials: .init(), target: URL(string: "https://elsewhere.example/steal")))
    }

    func testAnImageInAListFolderKeepsItsOtherListsUntilMovedToAnotherList() {
        var state = SiteFavoriteFolders.State(unassigned: 0, exclusive: false)
        state.folders = [7: "seven", 8: "eight"]
        state.baseline = [1: [0, 7, 8], 2: [7, 8], 3: [7]]
        let places = BooruAccountSync.places(saved: [1: "seven", 2: "eight", 3: "eight", 4: "other"], state: state)
        XCTAssertEqual(places[1], [.category(7), .category(8)], "One folder stands for every list the image was in")
        XCTAssertEqual(places[2], [.category(7), .category(8)])
        XCTAssertEqual(places[3], [.category(8)], "Moved to another list's folder, it leaves the lists it was in")
        XCTAssertEqual(places[4], [.unassigned])
    }

    @MainActor func testDanbooruSyncBringsInFavoritesAndGroupsThenSendsChangesMadeInTheApp() async throws {
        let store = try BooruStore()
        try store.saveServer(dan)
        let suite = "booru-account-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = BooruAccounts(defaults: defaults)
        accounts.setIdentity(BooruAccountIdentity(userID: 42, name: "me"), serverID: dan.id)
        let before = try BooruDecoder.post(["id": 9, "file_url": "https://cdn.example.com/9.jpg"], server: dan)
        try store.saveFavorite(before)

        let log = RequestLog()
        BooruAccountURLProtocol.handler = { request in
            let url = request.url!
            log.append("\(request.httpMethod ?? "GET") \(url.path.replacingOccurrences(of: "/booru/", with: "")) \(url.query ?? "")"
                       + (request.value(forHTTPHeaderField: "X-CSRF-Token").map { " csrf=\($0)" } ?? ""))
            switch url.path {
            case "/booru/favorites.json" where request.httpMethod == "GET": return (200, #"[{"post_id":1},{"post_id":2}]"#)
            case "/booru/favorite_groups.json": return (200, #"[{"id":7,"name":"my_group","post_ids":[2,3]},{"id":8,"name":"empty","post_ids":[]}]"#)
            case "/booru/posts.json":
                let ids = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tags" }?.value ?? "")
                    .replacingOccurrences(of: "id:", with: "").split(separator: ",")
                return (200, "[" + ids.map { #"{"id":\#($0),"file_url":"https://cdn.example.com/\#($0).jpg","tag_string":"sky"}"# }.joined(separator: ",") + "]")
            case "/booru/profile": return (200, #"<html><head><meta name="csrf-token" content="tok"></head></html>"#)
            default: return (200, "{}")
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BooruAccountURLProtocol.self]
        let sync = BooruAccountSync(store: store, accounts: accounts, client: BooruAccountClient(session: URLSession(configuration: config)))

        await sync.setUp(dan)
        let state = try XCTUnwrap(accounts.favorites.state(for: dan.id))
        let groupFolder = try XCTUnwrap(state.folders[7])
        XCTAssertNil(state.folders[8], "An empty group gets no folder")
        XCTAssertEqual(store.folders().first { $0.id == groupFolder }?.name, "my group")
        let saved = try store.favoriteFolders(serverID: dan.id)
        XCTAssertEqual(Set(saved.keys), [1, 2, 3, 9])
        XCTAssertEqual(saved[2], groupFolder)
        XCTAssertEqual(saved[3], groupFolder)
        XCTAssertNotEqual(saved[1], groupFolder)
        XCTAssertTrue(state.localOnly.contains(9), "The library saved before signing in is not sent")
        XCTAssertFalse(log.entries.contains { $0.hasPrefix("POST") || $0.hasPrefix("PUT") || $0.hasPrefix("DELETE") }, "Reading the site changes nothing there")
        XCTAssertTrue(sync.isListFolder(groupFolder))

        // Saved in the app and moved out of the group's folder: both reach the website.
        log.removeAll()
        let added = try BooruDecoder.post(["id": 10, "file_url": "https://cdn.example.com/10.jpg"], server: dan)
        try store.saveFavorite(added)
        let three = try XCTUnwrap(store.savedPost(serverID: dan.id, postID: 3))
        try store.moveFavorites([three], folderID: try XCTUnwrap(saved[1]))
        _ = try await sync.sync(dan, pull: false)
        XCTAssertEqual(Set(log.entries), [
            "GET profile ",
            "POST favorites.json post_id=3 csrf=tok",
            "PUT favorite_groups/7/remove_post.json post_id=3 csrf=tok",
            "POST favorites.json post_id=10 csrf=tok",
        ])
        let after = try XCTUnwrap(accounts.favorites.state(for: dan.id))
        XCTAssertEqual(after.baseline?[3], [0])
        XCTAssertEqual(after.baseline?[10], [0])

        // Removed on the website: the app follows.
        log.removeAll()
        BooruAccountURLProtocol.handler = { request in
            switch request.url!.path {
            case "/booru/favorites.json": return (200, #"[{"post_id":1},{"post_id":3},{"post_id":10}]"#)
            case "/booru/favorite_groups.json": return (200, #"[{"id":7,"name":"my_group","post_ids":[2]}]"#)
            default: return (200, "[]")
            }
        }
        _ = try await sync.sync(dan)
        XCTAssertEqual(Set(try store.favoriteFolders(serverID: dan.id).keys), [1, 2, 3, 9, 10])
        BooruAccountURLProtocol.handler = { request in
            switch request.url!.path {
            case "/booru/favorites.json": return (200, #"[{"post_id":1},{"post_id":10}]"#)
            case "/booru/favorite_groups.json": return (200, #"[{"id":7,"name":"my_group","post_ids":[]}]"#)
            default: return (200, "[]")
            }
        }
        _ = try await sync.sync(dan)
        let final = try store.favoriteFolders(serverID: dan.id)
        XCTAssertEqual(Set(final.keys), [1, 9, 10], "Images taken off the website leave the app; the earlier library stays")
        XCTAssertFalse(store.folderIDs().contains(groupFolder), "An emptied group and its emptied folder go together")
    }

    @MainActor func testSavedAPIKeysSignInAndAGelbooruKeyOnlyReads() async throws {
        let store = try BooruStore()
        try store.saveServer(gel)
        try BooruKeychain.save(BooruCredentials(account: "77", apiKey: "key"), serverID: gel.id)
        defer { try? BooruKeychain.save(.init(), serverID: gel.id) }
        let suite = "booru-account-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = BooruAccounts(defaults: defaults)
        let log = RequestLog()
        BooruAccountURLProtocol.handler = { request in
            let url = request.url!
            log.append("\(request.httpMethod ?? "GET") \(url.path) \(url.query ?? "")")
            if url.query?.contains("fav%3A77") == true { return (200, #"{"post":[{"id":5,"file_url":"https://cdn.example.com/5.jpg","tags":"sky"}]}"#) }
            return (200, "{}")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BooruAccountURLProtocol.self]
        let client = BooruAccountClient(session: URLSession(configuration: config))
        let sync = BooruAccountSync(store: store, accounts: accounts, client: client)

        await sync.discover(gel)
        XCTAssertEqual(accounts.identity(serverID: gel.id)?.userID, 77, "A saved user id and API key sign the account in")
        let canChange = await client.canChange(gel)
        XCTAssertFalse(canChange, "Gelbooru's API key reads; changes need the website's sign-in")
        XCTAssertEqual(Set(try store.favoriteFolders(serverID: gel.id).keys), [5], "The key reads the account's favorites")
        XCTAssertTrue(log.entries.contains { $0.contains("api_key=key") && $0.contains("user_id=77") })

        log.removeAll()
        try store.saveFavorite(try BooruDecoder.post(["id": 6, "file_url": "https://cdn.example.com/6.jpg"], server: gel))
        _ = try await sync.sync(gel, pull: false)
        XCTAssertFalse(log.entries.contains { $0.contains("addfav") }, "Nothing is sent without a sign-in that can change things")
        XCTAssertNil(accounts.favorites.state(for: gel.id)?.baseline?[6], "It waits to be sent once there is one")

        await sync.signOut(gel)
        XCTAssertNil(accounts.identity(serverID: gel.id))
        XCTAssertTrue(try BooruKeychain.read(serverID: gel.id).isEmpty, "Signing out forgets the saved key too")
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func removeAll() { lock.withLock { values.removeAll() } }
    var entries: [String] { lock.withLock { values } }
}

private final class BooruAccountURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
