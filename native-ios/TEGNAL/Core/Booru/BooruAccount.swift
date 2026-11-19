import Foundation
import GRDB
import Observation
import OSLog
import WebKit

/// The account signed in on an image server, as the server names it.
struct BooruAccountIdentity: Codable, Equatable, Sendable {
    var userID: Int64?
    var name: String
    /// The sign-in itself saved account details to the keychain: an API key the site's settings page
    /// showed, or the password hash its cookies held. Signing out removes them again.
    var savedCredentials = false
    var displayName: String { name.isEmpty ? userID.map { "#\($0)" } ?? "" : name }
}

/// The signed-in account's vote on an image: its own record on the server, when the server keeps one.
struct BooruVote: Equatable, Sendable {
    var id: Int64?
    /// 1 up, -1 down, 0 none.
    var score: Int
}

/// What each kind of image server lets a signed-in account do.
extension BooruEngine {
    /// Named lists besides the account's favorites (Danbooru's favorite groups).
    var keepsFavoriteLists: Bool { self == .danbooru }
    /// Moebooru keeps favorites as the highest vote, so votes there would change favorites.
    var votesUp: Bool { self != .moebooru }
    var votesDown: Bool { self == .danbooru }
    /// Whether the server shows the account its own vote, and lets it be withdrawn.
    var showsOwnVote: Bool { self == .danbooru }

    /// The server's own sign-in page.
    func signInURL(base: URL) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        switch self {
        case .danbooru:
            parts.path += "/login"
            parts.queryItems = [.init(name: "url", value: "/profile")]
        case .gelbooru, .oldGelbooru:
            parts.path += "/index.php"
            parts.queryItems = [.init(name: "page", value: "account"), .init(name: "s", value: "login"), .init(name: "code", value: "00")]
        case .moebooru:
            parts.path += "/user/login"
        }
        return parts.url!
    }
}

/// Each image server's signed-in account and its favorites sync, kept on this device only.
final class BooruAccounts: @unchecked Sendable {
    static let shared = BooruAccounts(defaults: ReaderPreferences.booruDefaults)
    static let didChange = Notification.Name("booruAccountDidChange")
    /// The list id the account's own favorites take in a favorites sync; named lists keep their ids.
    static let favoritesList = 0

    let favorites: SiteFavoriteFolders
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "booru.accounts"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        favorites = SiteFavoriteFolders(defaults: defaults, statesKey: "booru.favoriteSync", declinedKey: "booru.favoriteSyncDeclined")
    }

    func identity(serverID: String) -> BooruAccountIdentity? { lock.withLock { stored[serverID] } }

    func setIdentity(_ identity: BooruAccountIdentity?, serverID: String) {
        lock.withLock {
            var all = stored
            all[serverID] = identity
            defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private var stored: [String: BooruAccountIdentity] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: BooruAccountIdentity].self, from: $0) } ?? [:]
    }
}

/// What a server's favorites hold, with the images its answers already described.
struct BooruAccountFavorites: Sendable {
    var favorites: AccountFavorites
    var posts: [Int64: BooruPost]
}

/// The signed-in account's own requests: favorites, votes and comments. Requests carry the
/// cookies of the server's own browser profile, where the person signed in, and the API key
/// saved for the server, never anything for another server.
actor BooruAccountClient {
    static let shared = BooruAccountClient()
    private let session: URLSession
    private let browserFallback: Bool
    private var csrfTokens: [String: String] = [:]

    init(session: URLSession? = nil) {
        browserFallback = session == nil
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        self.session = session ?? URLSession(configuration: config, delegate: BooruRedirectPolicy(), delegateQueue: nil)
    }

    // MARK: Requests

    nonisolated static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }

    /// One request to the server, with its sign-in. A form makes it a POST unless a method is named.
    nonisolated static func request(server: BooruServer, method: String, path: String, query: [(String, String)], form: [(String, String)]?,
                                     accept: String, credentials: BooruCredentials, target: URL? = nil) throws -> URLRequest {
        var items = query, fields = form
        if !credentials.isEmpty {
            switch server.engine {
            case .moebooru:
                let auth = [("login", credentials.account), ("password_hash", credentials.apiKey)]
                if fields != nil { fields! += auth } else { items += auth }
            case .gelbooru where items.contains(where: { $0.0 == "page" && $0.1 == "dapi" }):
                items += [("user_id", credentials.account), ("api_key", credentials.apiKey)]
            default: break
            }
        }
        var components = URLComponents(url: target ?? (path.isEmpty ? server.baseURL : server.baseURL.appendingPathComponent(path)), resolvingAgainstBaseURL: false)!
        // A form's own address keeps its query; anything added follows it.
        let added = items.map { encode($0.0) + "=" + encode($0.1) }
        let kept = target == nil ? [] : [components.percentEncodedQuery].compactMap { $0 }.filter { !$0.isEmpty }
        if !(kept + added).isEmpty { components.percentEncodedQuery = (kept + added).joined(separator: "&") }
        guard target == nil || BooruWebTransport.sameOrigin(components.url ?? server.baseURL, server.baseURL) else { throw BooruError.invalidServer }
        guard let url = components.url else { throw BooruError.invalidServer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(BooruBrowserSession.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let fields {
            request.httpBody = formBody(fields)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if server.engine == .danbooru, !credentials.isEmpty {
            let basic = Data((credentials.account + ":" + credentials.apiKey).utf8).base64EncodedString()
            request.setValue("Basic " + basic, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    @discardableResult
    func send(_ server: BooruServer, _ method: String = "GET", _ path: String, query: [(String, String)] = [], form: [(String, String)]? = nil,
              html: Bool = false, target: URL? = nil, action: Bool = false, retried: Bool = false) async throws -> Data {
        let credentials = try BooruKeychain.read(serverID: server.id)
        var request = try Self.request(server: server, method: method, path: path, query: query, form: form,
                                       accept: html ? "text/html,application/xhtml+xml" : "application/json, application/xml;q=0.9, text/html;q=0.8",
                                       credentials: credentials, target: target)
        if action { request.setValue("1", forHTTPHeaderField: BooruWebTransport.followsNoRedirect) }
        // A signed-in page session proves a change with the page's own token; an API key needs none.
        if method != "GET", server.engine == .danbooru, credentials.isEmpty {
            request.setValue(try await csrfToken(server), forHTTPHeaderField: "X-CSRF-Token")
        }
        let (data, response) = try await transfer(request, server: server)
        await BooruBrowserSession.receive(response, server: server)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200..<400: break
        case 401:
            if let message = Self.message(data) { Self.log.error("Sign-in refused: \(message.text, privacy: .public)") }
            throw BooruError.authentication
        case 403:
            if BooruClient.needsBrowser(data, response: response) && !Self.isMessage(data) { throw BooruError.validationRequired }
            throw Self.message(data) ?? BooruError.authentication
        case 422 where !retried && server.engine == .danbooru && String(decoding: data.prefix(2000), as: UTF8.self).contains("InvalidAuthenticityToken"):
            csrfTokens[server.id] = nil
            return try await send(server, method, path, query: query, form: form, html: html, target: target, action: action, retried: true)
        case 422: throw Self.message(data) ?? BooruError.unavailable(422)
        case 429: throw BooruError.rateLimited
        default: throw BooruError.unavailable(response.statusCode)
        }
        if !html, BooruClient.needsBrowser(data, response: response) { throw BooruError.validationRequired }
        guard data.count < 24_000_000 else { throw BooruError.invalidResponse }
        return data
    }

    private func transfer(_ request: URLRequest, server: BooruServer) async throws -> (Data, HTTPURLResponse) {
        var prepared = await BooruBrowserSession.prepare(request, server: server)
        prepared.setValue(nil, forHTTPHeaderField: BooruWebTransport.followsNoRedirect)
        // A server validated in the browser keeps its requests there, as image searches do; when that
        // browser can't reach the server, the direct connection is tried as well.
        if browserFallback, await BooruWebTransport.hasSession(for: server) {
            do { return try await BooruWebTransport.data(for: request, server: server) }
            catch let error as URLError where BooruConnectionRetry.isTransient(error) {
                let (data, response) = try await session.data(for: prepared)
                guard let http = response as? HTTPURLResponse else { throw BooruError.invalidResponse }
                return (data, http)
            }
        }
        do {
            let (data, response) = try await session.data(for: prepared)
            guard let http = response as? HTTPURLResponse else { throw BooruError.invalidResponse }
            if browserFallback, BooruClient.needsBrowser(data, response: http), !Self.isMessage(data) {
                return try await BooruWebTransport.data(for: request, server: server)
            }
            return (data, http)
        } catch let error as URLError where browserFallback && [.secureConnectionFailed, .networkConnectionLost].contains(error.code) {
            return try await BooruWebTransport.data(for: request, server: server)
        }
    }

    /// A JSON answer naming what went wrong, rather than a bot check's page.
    private static func isMessage(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// The server's own words for a refused change, as Danbooru gives them.
    static func message(_ data: Data) -> SiteMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let text = (object["message"] as? String ?? object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SiteMessage(text: text)
    }

    private func csrfToken(_ server: BooruServer) async throws -> String {
        if let token = csrfTokens[server.id] { return token }
        let page = try await send(server, "GET", "profile", html: true)
        guard let token = BooruAccountParser.csrfToken(String(decoding: page, as: UTF8.self)) else { throw BooruError.authentication }
        csrfTokens[server.id] = token
        return token
    }

    func forgetSession(_ server: BooruServer) { csrfTokens[server.id] = nil }

    nonisolated static let log = Logger(subsystem: "work.nextline.tegnal", category: "booru-account")

    // MARK: Identity

    /// The account the server's own pages are signed in with, or the saved account details; nil when neither.
    func identity(_ server: BooruServer) async throws -> BooruAccountIdentity? {
        let cookies = await BooruBrowserSession.cookies(for: server).filter { BooruBrowserSession.matches($0, url: server.baseURL) }
        let credentials = try BooruKeychain.read(serverID: server.id)
        switch server.engine {
        case .danbooru:
            let data = try await send(server, "GET", "profile.json")
            return BooruAccountParser.danbooruIdentity(data)
        case .gelbooru, .oldGelbooru:
            if let identity = BooruAccountParser.gelbooruIdentity(cookies: cookies) { return identity }
            // A user id and API key saved for the server read its favorites and comments too.
            guard server.engine == .gelbooru, let user = Int64(credentials.account), user > 0, !credentials.apiKey.isEmpty else { return nil }
            return BooruAccountIdentity(userID: user, name: "")
        case .moebooru:
            if let identity = BooruAccountParser.moebooruIdentity(cookies: cookies) { return identity }
            return credentials.isEmpty ? nil : BooruAccountIdentity(name: credentials.account)
        }
    }

    /// Whether the account can change things on the server, not only read them. Gelbooru's API key
    /// reads favorites and comments; favorites, votes and comments change only with the website's
    /// own sign-in.
    func canChange(_ server: BooruServer) async -> Bool {
        switch server.engine {
        case .danbooru, .moebooru: return true
        case .gelbooru, .oldGelbooru:
            let cookies = await BooruBrowserSession.cookies(for: server).filter { BooruBrowserSession.matches($0, url: server.baseURL) }
            return BooruAccountParser.gelbooruIdentity(cookies: cookies) != nil
        }
    }

    /// Whether the server holds anything an account could be found with, before asking it.
    func mayHaveAccount(_ server: BooruServer) async -> Bool {
        if (try? BooruKeychain.read(serverID: server.id).isEmpty) == false { return true }
        let cookies = await BooruBrowserSession.cookies(for: server).filter { BooruBrowserSession.matches($0, url: server.baseURL) }
        switch server.engine {
        case .danbooru: return cookies.contains { $0.name.hasSuffix("_session") }
        case .gelbooru, .oldGelbooru: return BooruAccountParser.gelbooruIdentity(cookies: cookies) != nil
        case .moebooru: return BooruAccountParser.moebooruIdentity(cookies: cookies) != nil
        }
    }

    /// What a finished sign-in can still read for the account: Gelbooru's API key from its settings
    /// page, or the password hash Moebooru's cookies hold, saved when none is saved yet.
    func completeSignIn(_ server: BooruServer, identity: BooruAccountIdentity) async -> BooruAccountIdentity {
        var identity = identity
        guard (try? BooruKeychain.read(serverID: server.id).isEmpty) == true else { return identity }
        switch server.engine {
        case .gelbooru:
            guard let page = try? await send(server, "GET", "index.php", query: [("page", "account"), ("s", "options")], html: true),
                  let key = BooruAccountParser.gelbooruAPIKey(String(decoding: page, as: UTF8.self)),
                  identity.userID == nil || identity.userID == key.userID else { return identity }
            if (try? BooruKeychain.save(BooruCredentials(account: String(key.userID), apiKey: key.apiKey), serverID: server.id)) != nil {
                identity.savedCredentials = true
            }
        case .moebooru:
            let cookies = await BooruBrowserSession.cookies(for: server).filter { BooruBrowserSession.matches($0, url: server.baseURL) }
            guard let hash = cookies.first(where: { $0.name == "pass_hash" })?.value, !hash.isEmpty, !identity.name.isEmpty else { return identity }
            if (try? BooruKeychain.save(BooruCredentials(account: identity.name, apiKey: hash), serverID: server.id)) != nil {
                identity.savedCredentials = true
            }
        case .danbooru, .oldGelbooru: break
        }
        return identity
    }

    // MARK: Favorites

    /// The account's favorites, and Danbooru's favorite groups, with which of them hold each image.
    func favorites(_ server: BooruServer, account: BooruAccountIdentity) async throws -> BooruAccountFavorites {
        var members: [Int64: Set<Int>] = [:]
        var posts: [Int64: BooruPost] = [:]
        var lists: [FavoriteCategory] = []
        let main = BooruAccounts.favoritesList
        switch server.engine {
        case .danbooru:
            guard let user = account.userID else { throw BooruError.authentication }
            var page = 1, count = 0
            while page <= 100 {
                let data = try await send(server, "GET", "favorites.json", query: [("search[user_id]", String(user)), ("limit", "1000"), ("page", String(page)), ("only", "post_id")])
                let rows = try BooruDecoder.rows(data, key: "favorite")
                for row in rows { let id = Int64(BooruDecoder.integer(row["post_id"])); if id > 0 { members[id, default: []].insert(main); count += 1 } }
                if rows.count < 1000 { break }
                page += 1
            }
            lists.append(FavoriteCategory(id: main, name: L10n.text("Favorites"), count: count))
            let data = try await send(server, "GET", "favorite_groups.json", query: [("search[creator_id]", String(user)), ("limit", "1000"), ("only", "id,name,post_ids")])
            for row in try BooruDecoder.rows(data, key: "favorite-group") {
                let id = BooruDecoder.integer(row["id"])
                guard id > 0, let name = row["name"] as? String else { continue }
                let ids = (row["post_ids"] as? [Any] ?? []).map { Int64(BooruDecoder.integer($0)) }.filter { $0 > 0 }
                for post in ids { members[post, default: []].insert(id) }
                lists.append(FavoriteCategory(id: id, name: name.replacingOccurrences(of: "_", with: " "), count: ids.count))
            }
        case .gelbooru, .oldGelbooru:
            guard let user = account.userID else { throw BooruError.authentication }
            var found: [BooruPost] = []
            // The website's sign-in comes first; the API key reads favorites only without one,
            // and an empty API answer is checked against the favorites pages.
            let key = try? BooruKeychain.read(serverID: server.id)
            let cookies = await BooruBrowserSession.cookies(for: server).filter { BooruBrowserSession.matches($0, url: server.baseURL) }
            let website = BooruAccountParser.gelbooruIdentity(cookies: cookies)?.userID
            if server.engine == .gelbooru, website == nil, let key, !key.isEmpty,
               let read = try? await gelbooruAPIFavorites(server, user: user), !read.isEmpty {
                found = read
            } else {
                found = try await favoritesPages(server, user: user)
            }
            for post in found { members[post.postID, default: []].insert(main); posts[post.postID] = post }
            lists.append(FavoriteCategory(id: main, name: L10n.text("Favorites"), count: found.count))
        case .moebooru:
            guard !account.name.isEmpty else { throw BooruError.authentication }
            var page = 1
            while page <= 200 {
                let data = try await send(server, "GET", "post.json", query: [("tags", "vote:3:\(account.name) order:vote"), ("limit", "100"), ("page", String(page))])
                let rows = try BooruDecoder.rows(data, key: "post")
                for row in rows { if let post = try? BooruDecoder.post(row, server: server) { members[post.postID, default: []].insert(main); posts[post.postID] = post } }
                if rows.count < 100 { break }
                page += 1
            }
            lists.append(FavoriteCategory(id: main, name: L10n.text("Favorites"), count: members.count))
        }
        return BooruAccountFavorites(favorites: AccountFavorites(categories: lists, members: members, exclusive: false), posts: posts)
    }

    private func gelbooruAPIFavorites(_ server: BooruServer, user: Int64) async throws -> [BooruPost] {
        var result: [BooruPost] = [], seen = Set<Int64>()
        for page in 0..<200 {
            let data = try await send(server, "GET", "index.php", query: [("page", "dapi"), ("s", "post"), ("q", "index"), ("json", "1"),
                                                                         ("tags", "fav:\(user)"), ("limit", "100"), ("pid", String(page))])
            let rows = try BooruDecoder.rows(data, key: "post")
            for row in rows { if let post = try? BooruDecoder.post(row, server: server), seen.insert(post.postID).inserted { result.append(post) } }
            if rows.count < 100 { break }
        }
        return result
    }

    /// The account's favorites pages, read until a page brings nothing new.
    private func favoritesPages(_ server: BooruServer, user: Int64) async throws -> [BooruPost] {
        var result: [BooruPost] = [], seen = Set<Int64>(), offset = 0
        for _ in 0..<200 {
            let data = try await send(server, "GET", "index.php", query: [("page", "favorites"), ("s", "view"), ("id", String(user)), ("pid", String(offset))], html: true)
            let found: [BooruPost]
            do {
                found = try BooruLegacyHTML.posts(data, server: server)
            } catch BooruError.invalidResponse where BooruAccountParser.isEmptyFavoritesPage(data) {
                // Past the last page, or an account without favorites: the page shows no images at all.
                break
            }
            let page = found.filter { seen.insert($0.postID).inserted }
            if page.isEmpty { break }
            result += page
            offset += page.count
            try await Task.sleep(for: .milliseconds(300))
        }
        return result
    }

    /// Adds an image to the account's favorites or one of its lists, or takes it out.
    func setFavorite(_ server: BooruServer, postID: Int64, list: Int, adds: Bool) async throws {
        let id = String(postID)
        switch server.engine {
        case .danbooru where list != BooruAccounts.favoritesList:
            try await send(server, "PUT", "favorite_groups/\(list)/\(adds ? "add_post" : "remove_post").json", query: [("post_id", id)], form: [])
        case .danbooru:
            do {
                if adds { try await send(server, "POST", "favorites.json", query: [("post_id", id)], form: []) }
                else { try await send(server, "DELETE", "favorites/\(id).json", form: []) }
            } catch let message as SiteMessage where adds && message.text.lowercased().contains("already") {
                // Already a favorite: what was asked for holds.
            } catch BooruError.unavailable(404) where !adds {}
        case .gelbooru, .oldGelbooru:
            if adds {
                let data = try await send(server, "GET", "public/addfav.php", query: [("id", id)], html: true, action: true)
                switch String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
                case "1", "3": break
                case "2": throw BooruError.authentication
                default: break
                }
            } else {
                try await send(server, "GET", "index.php", query: [("page", "favorites"), ("s", "delete"), ("id", id)], html: true, action: true)
            }
        case .moebooru:
            try await send(server, "POST", "post/vote.json", form: [("id", id), ("score", adds ? "3" : "0")])
        }
    }

    /// Images by number, for favorites read as numbers only. Missing or hidden ones are left out.
    func posts(_ server: BooruServer, ids: [Int64]) async throws -> [BooruPost] {
        guard server.engine == .danbooru else { return [] }
        var result: [BooruPost] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            if !result.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let data = try await send(server, "GET", "posts.json", query: [("tags", "id:" + chunk.map(String.init).joined(separator: ",")),
                                                                         ("limit", "100"), ("only", BooruClient.postFields)])
            result += try BooruDecoder.rows(data, key: "post").compactMap { try? BooruDecoder.post($0, server: server) }
        }
        return result
    }

    // MARK: Votes

    func vote(_ server: BooruServer, postID: Int64, account: BooruAccountIdentity) async throws -> BooruVote {
        guard server.engine == .danbooru, let user = account.userID else { return BooruVote(score: 0) }
        let data = try await send(server, "GET", "post_votes.json", query: [("search[post_id]", String(postID)), ("search[user_id]", String(user)),
                                                                           ("search[is_deleted]", "false"), ("limit", "1"), ("only", "id,score")])
        guard let row = try BooruDecoder.rows(data, key: "post-vote").first else { return BooruVote(score: 0) }
        return BooruVote(id: Int64(BooruDecoder.integer(row["id"])), score: BooruDecoder.integer(row["score"]).signum())
    }

    /// Votes an image up or down, or withdraws the account's vote (0); returns the image's score
    /// as it now stands, when the server tells it.
    func vote(_ server: BooruServer, postID: Int64, score: Int, current: BooruVote) async throws -> Int? {
        let id = String(postID)
        switch server.engine {
        case .danbooru:
            if score == 0 {
                guard let vote = current.id else { return nil }
                try await send(server, "DELETE", "post_votes/\(vote).json", form: [])
            } else {
                try await send(server, "POST", "posts/\(id)/votes.json", query: [("score", String(score.signum()))], form: [])
            }
            let data = try await send(server, "GET", "posts/\(id).json", query: [("only", "score")])
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map { BooruDecoder.integer($0["score"]) }
        case .gelbooru, .oldGelbooru:
            guard score > 0 else { throw BooruError.unsupported }
            let data = try await send(server, "GET", "index.php", query: [("page", "post"), ("s", "vote"), ("id", id), ("type", "up")], html: true, action: true)
            return Int(String(decoding: data.prefix(32), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        case .moebooru:
            throw BooruError.unsupported
        }
    }

    // MARK: Comments

    /// An image's comments, oldest first. Every server shows them without an account.
    func comments(_ server: BooruServer, postID: Int64) async throws -> [WorkComment] {
        let id = String(postID)
        switch server.engine {
        case .danbooru:
            let data = try await send(server, "GET", "comments.json", query: [("search[post_id]", id), ("group_by", "comment"), ("limit", "1000"),
                                                                            ("only", "id,body,score,created_at,is_deleted,creator[name]")])
            return BooruAccountParser.danbooruComments(data)
        case .moebooru:
            let data = try await send(server, "GET", "comment.json", query: [("post_id", id)])
            return BooruAccountParser.moebooruComments(data)
        case .gelbooru:
            // DAPI keeps comments on the main site; installs that answer it with nothing show them on the page.
            if let data = try? await send(server, "GET", "index.php", query: [("page", "dapi"), ("s", "comment"), ("q", "index"), ("post_id", id)]),
               let comments = try? BooruAccountParser.gelbooruAPIComments(data), !comments.isEmpty { return comments }
            fallthrough
        case .oldGelbooru:
            let data = try await send(server, "GET", "index.php", query: [("page", "post"), ("s", "view"), ("id", id)], html: true)
            return BooruAccountParser.gelbooruPageComments(String(decoding: data, as: UTF8.self))
        }
    }

    /// Posts a comment under the image as the signed-in account, and returns the comments as they now stand.
    func postComment(_ server: BooruServer, postID: Int64, text: String) async throws -> [WorkComment] {
        let id = String(postID)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return try await comments(server, postID: postID) }
        switch server.engine {
        case .danbooru:
            try await send(server, "POST", "comments.json", form: [("comment[post_id]", id), ("comment[body]", body)])
        case .moebooru:
            try await send(server, "POST", "comment/create.json", form: [("comment[post_id]", id), ("comment[body]", body)])
        case .gelbooru, .oldGelbooru:
            // The post's own page offers the form to a signed-in account; it is sent as the page would.
            let page = try await send(server, "GET", "index.php", query: [("page", "post"), ("s", "view"), ("id", id)], html: true)
            guard let form = BooruAccountParser.commentForm(String(decoding: page, as: UTF8.self), text: body) else {
                throw SiteMessage(text: L10n.text("The website didn’t offer this account a comment form here. Open the image on the website to comment."))
            }
            guard let target = URL(string: form.action, relativeTo: server.baseURL.appendingPathComponent("index.php"))?.absoluteURL,
                  BooruWebTransport.sameOrigin(target, server.baseURL) else { throw BooruError.invalidResponse }
            try await send(server, "POST", "", form: form.fields, html: true, target: target)
        }
        return try await comments(server, postID: postID)
    }
}

/// Reads what the account requests answer. Only page structure and response fields are matched.
enum BooruAccountParser {
    /// A website page with no image on it, as a favorites page is past its last page or for an account
    /// without favorites. A bot check's page or a page whose images weren't recognized is not one.
    static func isEmptyFavoritesPage(_ data: Data) -> Bool {
        let html = String(decoding: data, as: UTF8.self).lowercased()
        guard html.contains("<body") else { return false }
        let checks = ["challenge-form", "cf-chl", "just a moment", "checking your browser"]
        guard !checks.contains(where: html.contains) else { return false }
        return html.firstMatch(of: /page=post(&|&amp;)s=view(&|&amp;)id=\d/) == nil
            && !["class=\"thumb", "thumbnail-preview", "thumbnail-container"].contains(where: html.contains)
    }

    static func csrfToken(_ html: String) -> String? {
        for match in BooruHTML.matches("<meta\\b([^>]*)>", html) {
            let attributes = BooruHTML.attributes(match[1])
            if attributes["name"] == "csrf-token", let token = attributes["content"], !token.isEmpty { return token }
        }
        return nil
    }

    static func danbooruIdentity(_ data: Data) -> BooruAccountIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let id = Int64(BooruDecoder.integer(object["id"]))
        guard id > 0 else { return nil }
        return BooruAccountIdentity(userID: id, name: object["name"] as? String ?? "")
    }

    static func gelbooruIdentity(cookies: [HTTPCookie]) -> BooruAccountIdentity? {
        guard let user = cookies.first(where: { $0.name == "user_id" }).flatMap({ Int64($0.value) }), user > 0,
              cookies.contains(where: { $0.name == "pass_hash" && !$0.value.isEmpty }) else { return nil }
        return BooruAccountIdentity(userID: user, name: "")
    }

    static func moebooruIdentity(cookies: [HTTPCookie]) -> BooruAccountIdentity? {
        guard let login = cookies.first(where: { $0.name == "login" })?.value, !login.isEmpty,
              cookies.contains(where: { $0.name == "pass_hash" && !$0.value.isEmpty }) else { return nil }
        return BooruAccountIdentity(name: login.removingPercentEncoding ?? login)
    }

    /// The API key and user id Gelbooru's account settings page shows for API access.
    static func gelbooruAPIKey(_ html: String) -> (apiKey: String, userID: Int64)? {
        let text = BooruHTML.decode(html)
        guard let match = BooruHTML.matches("api_key=([0-9A-Za-z]{16,128})&user_id=([0-9]{1,12})", text).first,
              let user = Int64(match[2]), user > 0 else { return nil }
        return (match[1], user)
    }

    private static let isoDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        if let object = value as? [String: Any], let seconds = object["s"] as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let date = isoDate.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "EEE MMM dd HH:mm:ss Z yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// DText as plain text: quotes become quoted lines, links keep their words, markup goes.
    static func plainDText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: #"(?is)\[quote\](.*?)\[/quote\]"#, with: "“$1”\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #""([^"\n]+)":\[?(?:https?://|/)[^\s\]]+\]?"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\{\{([^}]+)\}\}"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\[/?(?:b|i|u|s|tn|spoilers?|code|nodtext|expand[^\]]*|url[^\]]*|br)\]"#, with: "", options: .regularExpression)
        return value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func danbooruComments(_ data: Data) -> [WorkComment] {
        let rows = (try? BooruDecoder.rows(data, key: "comment")) ?? []
        return rows.compactMap { row -> WorkComment? in
            let id = BooruDecoder.integer(row["id"])
            guard id > 0, row["is_deleted"] as? Bool != true, let body = row["body"] as? String else { return nil }
            let author = (row["creator"] as? [String: Any])?["name"] as? String ?? row["creator_name"] as? String ?? "?"
            let text = plainDText(body)
            guard !text.isEmpty else { return nil }
            return WorkComment(id: id, author: author.replacingOccurrences(of: "_", with: " "), posted: date(row["created_at"]),
                               score: row["score"].map(BooruDecoder.integer), text: text)
        }.sorted { $0.id < $1.id }
    }

    static func moebooruComments(_ data: Data) -> [WorkComment] {
        let rows = (try? BooruDecoder.rows(data, key: "comment")) ?? []
        return rows.compactMap { row -> WorkComment? in
            let id = BooruDecoder.integer(row["id"])
            guard id > 0, let body = row["body"] as? String else { return nil }
            let text = plainDText(body)
            guard !text.isEmpty else { return nil }
            return WorkComment(id: id, author: row["creator"] as? String ?? "?", posted: date(row["created_at"]), score: nil, text: text)
        }.sorted { $0.id < $1.id }
    }

    static func gelbooruAPIComments(_ data: Data) throws -> [WorkComment] {
        try BooruDecoder.rows(data, key: "comment").compactMap { row -> WorkComment? in
            let id = BooruDecoder.integer(row["id"])
            guard id > 0, let body = row["body"] as? String else { return nil }
            let text = BooruHTML.plainText(BooruHTML.decode(body))
            guard !text.isEmpty else { return nil }
            return WorkComment(id: id, author: row["creator"] as? String ?? "?", posted: date(row["created_at"]), score: nil, text: text)
        }.sorted { $0.id < $1.id }
    }

    /// Comments on a Gelbooru-style post page, in either of the two shapes those pages use:
    /// a block per comment named `c<number>` with the author and date in one column and the text in
    /// the other, or a `commentBody` block whose first bold or linked name is the author.
    static func gelbooruPageComments(_ html: String) -> [WorkComment] {
        var result: [WorkComment] = [], seen = Set<Int>()
        let blocks = html.components(separatedBy: "<div id=\"c").dropFirst()
        for block in blocks {
            guard let id = Int(block.prefix { $0.isNumber }), id > 0, seen.insert(id).inserted else { continue }
            let first = BooruHTML.matches(#"class\s*=\s*["']col1["'][^>]*>(.*?)</div>"#, block).first?[1] ?? ""
            let second = BooruHTML.matches(#"class\s*=\s*["']col2["'][^>]*>(.*?)</div>"#, block).first?[1] ?? ""
            let author = BooruHTML.matches(#"<a\b[^>]*>(.*?)</a>"#, first).first.map { BooruHTML.plainText($0[1]) } ?? "?"
            let posted = BooruHTML.matches(#"(?:Posted on|commented at)\s+([0-9-]+\s+[0-9:]+)"#, first).first.flatMap { date($0[1]) }
            let score = BooruHTML.matches(#"Score:\s*(?:<[^>]*>\s*)*(-?[0-9]+)"#, first).first.flatMap { Int($0[1]) }
            let text = BooruHTML.plainText(second)
            guard !text.isEmpty else { continue }
            result.append(WorkComment(id: id, author: author.isEmpty ? "?" : author, posted: posted, score: score, text: text))
        }
        if !result.isEmpty { return result.sorted { $0.id < $1.id } }
        let bodies = html.components(separatedBy: "commentBody").dropFirst()
        for block in bodies {
            // A block ends where the next comment, the paginator or the comment form begins.
            let content = String(block.split(separator: "<form", maxSplits: 1).first ?? Substring(block))
                .components(separatedBy: "id=\"paginator").first ?? ""
            guard let id = BooruHTML.matches(#"#([0-9]{1,12})"#, content).first.flatMap({ Int($0[1]) }), seen.insert(id).inserted else { continue }
            let author = (BooruHTML.matches(#"<b\b[^>]*>(.*?)</b>"#, content).first ?? BooruHTML.matches(#"<a\b[^>]*>(.*?)</a>"#, content).first)
                .map { BooruHTML.plainText($0[1]) } ?? "?"
            let posted = BooruHTML.matches(#"(?:commented at|Posted on)\s+([0-9-]+\s+[0-9:]+)"#, content).first.flatMap { date($0[1]) }
            let score = BooruHTML.matches(#"Score:\s*(?:<[^>]*>\s*)*(-?[0-9]+)"#, content).first.flatMap { Int($0[1]) }
            var text = BooruHTML.plainText(content.replacingOccurrences(of: #"^[^>]*>"#, with: "", options: .regularExpression))
            for noise in [author, "#\(id)"] where !noise.isEmpty { if let range = text.range(of: noise) { text.removeSubrange(range) } }
            text = text.replacingOccurrences(of: #"(?i)(commented at|Posted on)\s+[0-9-]+\s+[0-9:]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)Score:\s*-?[0-9]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\(\s*vote\s+up\s*\)|\(\s*report comment\s*\)|report comment"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ">|-·")))
            guard !text.isEmpty else { continue }
            result.append(WorkComment(id: id, author: author.isEmpty ? "?" : author, posted: posted, score: score, text: text))
        }
        return result.sorted { $0.id < $1.id }
    }

    struct CommentForm: Equatable {
        let action: String
        let fields: [(String, String)]
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.action == rhs.action && lhs.fields.map { $0.0 + "=" + $0.1 } == rhs.fields.map { $0.0 + "=" + $0.1 }
        }
    }

    /// The page's comment form filled with the text: its hidden fields and first submit button as
    /// the page has them, without posting anonymously.
    static func commentForm(_ html: String, text: String) -> CommentForm? {
        for form in BooruHTML.matches("<form\\b([^>]*)>(.*?)</form>", html) {
            let attributes = BooruHTML.attributes(form[1])
            let action = attributes["action"] ?? ""
            let textareas = BooruHTML.matches("<textarea\\b([^>]*)>", form[2]).compactMap { BooruHTML.attributes($0[1])["name"] }
            guard let field = textareas.first(where: { $0.lowercased().contains("comment") }) ?? (action.contains("comment") ? textareas.first : nil),
                  action.contains("comment") || field.lowercased() == "comment",
                  (attributes["method"] ?? "post").lowercased() == "post" else { continue }
            var fields: [(String, String)] = [(field, text)]
            var submitted = false
            for input in BooruHTML.matches("<input\\b([^>]*)>", form[2]) {
                let values = BooruHTML.attributes(input[1])
                guard let name = values["name"], !name.isEmpty else { continue }
                let type = (values["type"] ?? "text").lowercased()
                switch type {
                case "hidden": fields.append((name, name.lowercased() == "conf" ? "1" : values["value"] ?? ""))
                case "submit" where !submitted: fields.append((name, values["value"] ?? "")); submitted = true
                case "checkbox", "radio":
                    // Anonymous posting stays off; other boxes keep what the page checked.
                    if input[1].lowercased().contains("checked"), !name.lowercased().contains("anonymous") { fields.append((name, values["value"] ?? "on")) }
                case "text":
                    if !name.lowercased().contains("captcha") { fields.append((name, values["value"] ?? "")) }
                default: break
                }
            }
            return CommentForm(action: BooruHTML.decode(action), fields: fields)
        }
        return nil
    }
}

/// Lets the comments views read and write an image server's comments.
struct BooruCommentProvider: WorkExtrasProviding {
    let server: BooruServer
    var client: BooruAccountClient = .shared
    func extras(_ id: Int64) async throws -> WorkExtras? { nil }
    func allComments(_ id: Int64) async throws -> [WorkComment] { try await client.comments(server, postID: id) }
    func rate(_ id: Int64, halfStars: Int) async throws -> (average: Double, count: Int) { throw BooruError.unsupported }
    func postComment(_ id: Int64, text: String) async throws -> [WorkComment] { try await client.postComment(server, postID: id, text: text) }
}

extension BooruStore {
    /// Which folder each saved image of a server sits in.
    func favoriteFolders(serverID: String) throws -> [Int64: String] {
        try database.read { db in
            var result: [Int64: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT post_id, folder_id FROM favorites WHERE server_id = ?", arguments: [serverID]) {
                result[row["post_id"]] = row["folder_id"]
            }
            return result
        }
    }

    func savedPost(serverID: String, postID: Int64) -> BooruPost? {
        try? database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [serverID, postID])
                .map { try JSONDecoder().decode(BooruPost.self, from: $0) }
        }
    }

    func folderIDs() -> Set<String> {
        Set((try? database.read { try String.fetchAll($0, sql: "SELECT id FROM folders") }) ?? [])
    }

    /// What a favorites sync changes in the library, in one write: images the server no longer
    /// keeps, images moved between folders ("" is the server's own folder), and images new to the
    /// app, into a list's folder or where a save without a folder goes.
    func applySyncedFavorites(serverID: String, removals: [Int64], moves: [Int64: String], additions: [(BooruPost, String?)]) throws {
        guard !removals.isEmpty || !moves.isEmpty || !additions.isEmpty else { return }
        try database.write { db in
            let landing = try Self.defaultFolder(for: serverID, db: db)
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            for id in removals {
                guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [serverID, id]) else { continue }
                try TasteStore.record(.remove, item: Self.tasteItem(decoder.decode(BooruPost.self, from: data), db: db), db: db)
                try db.execute(sql: "DELETE FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [serverID, id])
            }
            for (id, folder) in moves {
                try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?", arguments: [folder.isEmpty ? landing : folder, serverID, id])
            }
            let now = Date().timeIntervalSince1970
            for (index, (post, folder)) in additions.enumerated() where post.serverID == serverID {
                let target = try folder ?? Self.smartDestination(for: post, landing: landing, db: db)
                // Each keeps its own moment, so the order they came in stays.
                try db.execute(sql: "INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)",
                               arguments: [serverID, post.postID, try encoder.encode(post), now - Double(index) * 0.001, target])
                if db.changesCount > 0 { try TasteStore.record(.imported, item: Self.tasteItem(post, db: db), db: db) }
            }
        }
        try refresh()
    }
}

/// Keeps each signed-in image server's favorites and the app's folders the same, the way comics
/// websites' favorites are kept: the account's own favorites hold images saved in any folder that
/// isn't a list's, and each named list that holds images (Danbooru's favorite groups) becomes a
/// folder of the same name. What was added, removed or moved on one side since the last sync is
/// done on the other; when both changed the same place, the website wins.
@MainActor @Observable
final class BooruAccountSync {
    let store: BooruStore
    let accounts: BooruAccounts
    let client: BooruAccountClient
    /// Changes when an account or its favorites sync changes, so settings redraw.
    private(set) var revision = 0
    /// Servers whose sign-in the website no longer accepts.
    private(set) var expired = Set<String>()
    /// The names of each server's favorites lists, as last read.
    private(set) var listNames: [String: [Int: String]] = [:]
    /// A server whose favorites can be synced, waiting for the person to choose how to start.
    var setupOffer: BooruFavoritesSetupOffer?
    @ObservationIgnored private var syncing = Set<String>()
    /// At most this many favorites change on a server in one sync; the rest wait for the next.
    static let sendsPerSync = 30
    /// At most this many images are looked up by number in one sync.
    static let lookupsPerSync = 1000

    nonisolated init(store: BooruStore, accounts: BooruAccounts = .shared, client: BooruAccountClient = .shared) {
        self.store = store
        self.accounts = accounts
        self.client = client
    }

    func identity(_ server: BooruServer) -> BooruAccountIdentity? {
        _ = revision
        return accounts.identity(serverID: server.id)
    }

    func state(_ server: BooruServer) -> SiteFavoriteFolders.State? {
        _ = revision
        return accounts.favorites.state(for: server.id)
    }

    /// A sign-in finished on the server's own page: the account is kept, and its favorites are
    /// brought in unless the sync was turned off before.
    func signedIn(_ server: BooruServer, identity: BooruAccountIdentity) async {
        accounts.setIdentity(identity, serverID: server.id)
        expired.remove(server.id)
        store.clearGoldRestrictions(serverID: server.id)
        revision += 1
        let completed = await client.completeSignIn(server, identity: identity)
        if completed != identity { accounts.setIdentity(completed, serverID: server.id); revision += 1 }
        await setUp(server)
    }

    @ObservationIgnored private var looked = Set<String>()

    /// Finds an account the server already knows this device by: an API key saved in the server's
    /// settings, or a sign-in its pages kept. Each server is asked once a session unless [force]d,
    /// as after its account details are saved.
    func discover(_ server: BooruServer, force: Bool = false) async {
        guard accounts.identity(serverID: server.id) == nil, force || !looked.contains(server.id) else { return }
        looked.insert(server.id)
        guard await client.mayHaveAccount(server) else { refusedKeys.remove(server.id); return }
        let identity: BooruAccountIdentity?
        do { identity = try await client.identity(server) }
        catch BooruError.authentication {
            // The website turned the saved account details down; the settings say so.
            refusedKeys.insert(server.id)
            return
        } catch {
            BooruAccountClient.log.error("Account check failed for \(server.engine.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        guard let identity else {
            // A saved key that names no account, such as Gelbooru's user name in place of its user id.
            if (try? BooruKeychain.read(serverID: server.id).isEmpty) == false { refusedKeys.insert(server.id) }
            return
        }
        refusedKeys.remove(server.id)
        guard accounts.identity(serverID: server.id) == nil else { return }
        await signedIn(server, identity: identity)
    }

    /// Servers whose saved account details the website turned down.
    private(set) var refusedKeys = Set<String>()

    /// Reads which account the server's pages are signed in with now.
    func check(_ server: BooruServer) async -> BooruAccountIdentity? {
        try? await client.identity(server)
    }



    func signOut(_ server: BooruServer) async {
        accounts.setIdentity(nil, serverID: server.id)
        accounts.favorites.remove(server.id, declined: false)
        // An API key saved for the account goes too, or the next launch would sign it back in.
        try? BooruKeychain.save(.init(), serverID: server.id)
        looked.insert(server.id)
        expired.remove(server.id)
        revision += 1
        await client.forgetSession(server)
        // The sign-in lives in the server's browser profile; a bot check passed there stays.
        let cookieStore = BooruBrowserSession.dataStore(for: server).httpCookieStore
        for cookie in await cookieStore.allCookies() where BooruBrowserSession.matches(cookie, url: server.baseURL) && !SiteClearance.isClearanceCookie(cookie.name) {
            await cookieStore.deleteCookie(cookie)
        }
        BooruWebTransport.reset(server)
        store.clearGoldRestrictions(serverID: server.id)
    }

    /// The first time a signed-in server's favorites can be read, nothing changes yet: the person is
    /// shown what bringing them in would do and chooses (`answerSetup`).
    func setUp(_ server: BooruServer, requested: Bool = false) async {
        try? await setUpSync(server, requested: requested)
    }

    /// [setUp], telling a sync turned on by hand why it couldn't start.
    func setUpSync(_ server: BooruServer, requested: Bool) async throws {
        let favorites = accounts.favorites
        guard favorites.state(for: server.id) == nil, requested || !favorites.isDeclined(server.id),
              setupOffer == nil || setupOffer?.serverID == server.id,
              let identity = accounts.identity(serverID: server.id) else { return }
        let fetched: BooruAccountFavorites
        do { fetched = try await client.favorites(server, account: identity) }
        catch {
            BooruAccountClient.log.error("Favorites read failed for \(server.engine.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            if requested { throw error }
            return
        }
        remember(fetched, server: server)
        let offer = try self.offer(server, read: fetched)
        // A server with no favorites has nothing to bring in or leave alone.
        if offer.favoriteCount == 0 { await start(offer, choice: .bringIn); return }
        guard setupOffer == nil || setupOffer?.serverID == server.id, favorites.state(for: server.id) == nil else { return }
        setupOffer = offer
    }

    /// What bringing a server's favorites in would change, worked out without changing anything.
    private func offer(_ server: BooruServer, read: BooruAccountFavorites) throws -> BooruFavoritesSetupOffer {
        var state = SiteFavoriteFolders.State(unassigned: BooruAccounts.favoritesList, exclusive: false)
        let matches = try listFolderMatches(read.favorites, server: server, state: state)
        for match in matches { state.folders[match.list] = match.folder ?? "new-\(match.list)" }
        let saved = try store.favoriteFolders(serverID: server.id)
        let plan = FavoriteSyncPlan.make(local: Self.places(saved: saved, state: state), remote: read.favorites.members, base: nil,
                                         folders: Set(state.folders.keys), unassigned: state.unassigned, localOnly: [], exclusive: false)
        var newImages = 0, filedImages = 0
        for change in plan.local {
            guard case .place(let id, _) = change else { continue }
            if saved[id] == nil { newImages += 1 } else { filedImages += 1 }
        }
        return BooruFavoritesSetupOffer(serverID: server.id, serverName: server.displayName, read: read,
                                        favoriteCount: read.favorites.members.count, newImages: newImages, filedImages: filedImages,
                                        newFolders: matches.filter { $0.folder == nil }.map(\.name))
    }

    /// The person's answer to how a server's favorites start syncing.
    func answerSetup(_ choice: SiteFavoritesSetupChoice) async {
        guard let offer = setupOffer else { return }
        setupOffer = nil
        if choice == .off { if let server = store.servers.first(where: { $0.id == offer.serverID }) { stop(server) } }
        else { await start(offer, choice: choice) }
        // Another signed-in server waiting to be asked comes next.
        for server in store.servers where server.id != offer.serverID && setupOffer == nil && accounts.identity(serverID: server.id) != nil {
            await setUp(server)
        }
    }

    /// Bringing in fills a folder for each list that holds images and adds the favorites the app
    /// lacks. Keeping the library leaves every favorite already on the server alone on both sides.
    private func start(_ offer: BooruFavoritesSetupOffer, choice: SiteFavoritesSetupChoice) async {
        let favorites = accounts.favorites
        guard favorites.state(for: offer.serverID) == nil, accounts.identity(serverID: offer.serverID) != nil,
              let server = store.servers.first(where: { $0.id == offer.serverID }) else { return }
        do {
            var state = SiteFavoriteFolders.State(unassigned: BooruAccounts.favoritesList, exclusive: false)
            state.setUpAt = Date()
            if choice == .keepLibrary { state.ignored = Set(offer.read.favorites.members.keys) }
            _ = try linkListFolders(offer.read.favorites, server: server, state: &state)
            favorites.setState(state, for: server.id)
            revision += 1
            try await sync(server, remote: offer.read)
        } catch {}
    }

    /// When each synced server's favorites were brought in, to tell those images apart later.
    var setUpTimes: [String: Date] {
        _ = revision
        var times: [String: Date] = [:]
        for server in store.servers { if let date = accounts.favorites.state(for: server.id)?.setUpAt { times[server.id] = date } }
        return times
    }

    /// Whether any of these saved images is a favorite a signed-in server keeps in step with the app,
    /// so deleting it here would take it off the server too.
    func syncsAny(_ posts: [BooruPost]) -> Bool {
        _ = revision
        return posts.contains { post in
            guard accounts.identity(serverID: post.serverID) != nil, let state = accounts.favorites.state(for: post.serverID) else { return false }
            return state.baseline?[post.postID] != nil && state.ignored?.contains(post.postID) != true
        }
    }

    /// Deletes saved images. `keepOnServer` leaves the servers' favorites as they are: those images
    /// are left alone by the sync from then on.
    func removeFavorites(_ posts: [BooruPost], keepOnServer: Bool) throws {
        if keepOnServer {
            for (serverID, chosen) in Dictionary(grouping: posts, by: \.serverID) {
                guard var state = accounts.favorites.state(for: serverID) else { continue }
                let kept = chosen.map(\.postID).filter { state.baseline?[$0] != nil }
                guard !kept.isEmpty else { continue }
                state.ignored = (state.ignored ?? []).union(kept)
                accounts.favorites.setState(state, for: serverID)
            }
            revision += 1
        }
        try store.removeFavorites(posts)
    }

    func stop(_ server: BooruServer) {
        accounts.favorites.remove(server.id, declined: true)
        revision += 1
    }

    /// Where images in other folders are kept on the server: the account's favorites, or nil for the app only.
    func setOtherFoldersList(_ list: Int?, server: BooruServer) {
        guard var state = accounts.favorites.state(for: server.id) else { return }
        state.unassigned = list
        accounts.favorites.setState(state, for: server.id)
        revision += 1
    }

    /// Whether a folder stands for a signed-in server's favorites list, which can't be deleted while synced.
    func isListFolder(_ folderID: String) -> Bool {
        _ = revision
        return store.servers.contains { server in
            accounts.identity(serverID: server.id) != nil && accounts.favorites.state(for: server.id)?.folders.values.contains(folderID) == true
        }
    }

    private func remember(_ read: BooruAccountFavorites, server: BooruServer) {
        listNames[server.id] = Dictionary(read.favorites.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func listFolderName(_ list: FavoriteCategory, server: BooruServer) -> String {
        list.id == BooruAccounts.favoritesList ? L10n.text("%@ Favorites", server.displayName) : list.name
    }

    /// Each list holding images the sync looks after, with this server's unlinked folder already
    /// named so, if there is one, apart from the list kept for other folders.
    private func listFolderMatches(_ favorites: AccountFavorites, server: BooruServer, state: SiteFavoriteFolders.State) throws -> [(list: Int, name: String, folder: String?)] {
        var taken = Set(store.servers.flatMap { accounts.favorites.state(for: $0.id)?.folders.values.map { $0 } ?? [] }).union(state.folders.values)
        let held = favorites.heldCategories(ignoring: state.ignored ?? [])
        var matches: [(list: Int, name: String, folder: String?)] = []
        for list in favorites.categories where held.contains(list.id) && state.folders[list.id] == nil && list.id != state.unassigned {
            // Only this server's own folders: another server's folder of the same name is its own.
            let name = listFolderName(list, server: server)
            let folder = store.folders().first { $0.serverID == server.id && $0.plainName == name && !$0.isUncategorized && !taken.contains($0.id) }?.id
            if let folder { taken.insert(folder) }
            matches.append((list.id, name, folder))
        }
        return matches
    }

    /// Gives each list that holds images a folder of its name, or the unlinked folder already named
    /// so, apart from the list kept for other folders. Returns the lists linked now.
    private func linkListFolders(_ favorites: AccountFavorites, server: BooruServer, state: inout SiteFavoriteFolders.State) throws -> Set<Int> {
        var linked = Set<Int>()
        for match in try listFolderMatches(favorites, server: server, state: state) {
            state.folders[match.list] = try match.folder ?? store.saveFolder(name: match.name, serverID: server.id)
            linked.insert(match.list)
        }
        return linked
    }

    /// A list and its folder come and go together: a list left empty whose folder is empty loses
    /// the folder, unless it is a smart folder whose rule would be lost.
    private func dropEmptiedListFolders(state: inout SiteFavoriteFolders.State, settled: [Int64: Set<Int>]) throws {
        let used = settled.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let saved = Set((try? store.database.read { try String.fetchAll($0, sql: "SELECT DISTINCT folder_id FROM favorites") }) ?? [])
        let smart = Set(store.folders().filter(\.isSmart).map(\.id))
        for (list, folder) in state.folders where !used.contains(list) && !saved.contains(folder) && !smart.contains(folder) {
            try store.deleteFolder(folder)
            state.folders[list] = nil
        }
    }

    /// Where each saved image of the server sits. An image in a list's folder keeps the other lists
    /// it was in at the last sync: one folder stands for all of them. Moved to another list's folder,
    /// it leaves them.
    func localPlaces(_ server: BooruServer, state: SiteFavoriteFolders.State) throws -> [Int64: Set<FavoritePlace>] {
        Self.places(saved: try store.favoriteFolders(serverID: server.id), state: state)
    }

    nonisolated static func places(saved: [Int64: String], state: SiteFavoriteFolders.State) -> [Int64: Set<FavoritePlace>] {
        let listOf = Dictionary(state.folders.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        var result: [Int64: Set<FavoritePlace>] = [:]
        for (post, folder) in saved {
            guard let list = listOf[folder] else { result[post] = [.unassigned]; continue }
            let before = (state.baseline?[post] ?? []).filter { state.folders[$0] != nil }
            result[post] = before.contains(list) ? Set(before.map(FavoritePlace.category)) : [.category(list)]
        }
        return result
    }

    /// Brings a server's favorites and the folders into step. `pull` reads the server again; without
    /// it only changes made in the app are sent.
    @discardableResult
    func sync(_ server: BooruServer, pull: Bool = true, remote fetched: BooruAccountFavorites? = nil) async throws -> FavoriteSyncPlan? {
        let favoritesStore = accounts.favorites
        guard var state = favoritesStore.state(for: server.id), let identity = accounts.identity(serverID: server.id) else { return nil }
        guard syncing.insert(server.id).inserted else { return nil }
        defer { syncing.remove(server.id) }
        let folders = store.folderIDs()
        var missing = false
        for (list, folder) in state.folders where !folders.contains(folder) { state.folders[list] = nil; missing = true }
        var read = fetched
        do {
            if read == nil, pull || missing || state.baseline == nil { read = try await client.favorites(server, account: identity) }
        } catch BooruError.authentication {
            expired.insert(server.id); revision += 1
            throw BooruError.authentication
        }
        expired.remove(server.id)
        let remote: [Int64: Set<Int>]
        if let read {
            remember(read, server: server)
            remote = read.favorites.members
            state.lastPull = Date()
            let existing = Set(read.favorites.categories.map(\.id))
            for list in state.folders.keys where !existing.contains(list) { state.folders[list] = nil }
            let linked = try linkListFolders(read.favorites, server: server, state: &state)
            if !linked.isEmpty, let baseline = state.baseline { state.baseline = baseline.mapValues { $0.subtracting(linked) } }
        } else { remote = state.baseline ?? [:] }
        // Images deleted in the app only while the server was read are left alone too.
        if let stored = favoritesStore.state(for: server.id)?.ignored { state.ignored = (state.ignored ?? []).union(stored) }
        let plan = FavoriteSyncPlan.make(local: try localPlaces(server, state: state), remote: remote, base: state.baseline,
                                         folders: Set(state.folders.keys), unassigned: state.unassigned, localOnly: state.localOnly, exclusive: false,
                                         ignored: state.ignored ?? [])
        var settled = plan.settled
        state.localOnly.formUnion(plan.keepLocal)
        state.localOnly.subtract(plan.stopKeepingLocal)
        if !plan.stopIgnoring.isEmpty { state.ignored?.subtract(plan.stopIgnoring) }
        state.baseline = settled
        favoritesStore.setState(state, for: server.id)

        // Images new to the app: the answers' own descriptions, or a lookup by number.
        var described = read?.posts ?? [:]
        let saved = try store.favoriteFolders(serverID: server.id)
        let unknown = plan.local.compactMap { change -> Int64? in
            if case .place(let id, _) = change, saved[id] == nil, described[id] == nil { return id }
            return nil
        }
        if !unknown.isEmpty, let found = try? await client.posts(server, ids: Array(unknown.prefix(Self.lookupsPerSync))) {
            for post in found { described[post.postID] = post }
        }
        let listFolders = Set(state.folders.values)
        var removals: [Int64] = [], moves: [Int64: String] = [:], additions: [(BooruPost, String?)] = []
        for change in plan.local {
            switch change {
            case .remove(let id):
                removals.append(id)
            case .place(let id, let places):
                let targets = places.compactMap(\.category).sorted().compactMap { state.folders[$0] }
                if let current = saved[id] {
                    if let target = targets.first, !targets.contains(current) { moves[id] = target }
                    else if targets.isEmpty, listFolders.contains(current) { moves[id] = "" }
                } else if let post = described[id] {
                    additions.append((post, targets.first))
                } else {
                    // Not described yet: it comes again with the next sync instead of counting as removed here.
                    settled[id] = nil
                }
            }
        }
        try store.applySyncedFavorites(serverID: server.id, removals: removals, moves: moves, additions: additions)
        // Without a sign-in that can change things, changes wait until there is one.
        var sent = 0, failed = plan.site.isEmpty ? false : !(await client.canChange(server)), refused = Set<Int64>()
        for change in plan.site {
            guard !failed, sent < Self.sendsPerSync, !refused.contains(change.id) else {
                if !refused.contains(change.id) { settled[change.id] = remote[change.id] }
                continue
            }
            if sent > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            sent += 1
            do {
                try await client.setFavorite(server, postID: change.id, list: change.category, adds: change.adds)
            } catch BooruError.unavailable(let status) where change.adds && [404, 410, 422].contains(status) {
                refused.insert(change.id)
            } catch is SiteMessage where change.adds {
                refused.insert(change.id)
            } catch {
                failed = true
                settled[change.id] = remote[change.id]
            }
        }
        for id in refused { state.localOnly.insert(id); settled[id] = remote[id] }
        if read != nil { try dropEmptiedListFolders(state: &state, settled: settled) }
        state.baseline = settled
        if let stored = favoritesStore.state(for: server.id)?.ignored {
            state.ignored = (state.ignored ?? []).union(stored.subtracting(plan.stopIgnoring))
        }
        favoritesStore.setState(state, for: server.id)
        revision += 1
        return plan
    }

    /// While the app is open: sets up servers signed in since, reads each server's favorites again
    /// after half an hour, and sends changes made in the app.
    func run() async {
        for server in store.servers where accounts.identity(serverID: server.id) == nil { await discover(server) }
        for server in store.servers where accounts.identity(serverID: server.id) != nil {
            if let state = accounts.favorites.state(for: server.id) {
                if (state.lastPull ?? .distantPast) < Date().addingTimeInterval(-30 * 60) { _ = try? await sync(server) }
            } else { await setUp(server) }
            if Task.isCancelled { return }
        }
        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: "SELECT server_id, post_id, folder_id FROM favorites ORDER BY 1, 2")
        }
        do {
            var first = true
            for try await _ in observation.values(in: store.database) {
                if first { first = false; continue }
                try await Task.sleep(for: .seconds(1))
                for server in store.servers where accounts.favorites.state(for: server.id) != nil {
                    _ = try? await sync(server, pull: false)
                }
            }
        } catch {}
    }
}

/// What the first sync with an image server's favorites would do, shown before anything changes.
struct BooruFavoritesSetupOffer: Identifiable {
    var id: String { serverID }
    let serverID: String
    let serverName: String
    let read: BooruAccountFavorites
    let favoriteCount: Int
    /// Favorites the library doesn't have yet.
    let newImages: Int
    /// Saved images that would also go into a list's folder.
    let filedImages: Int
    /// Folders that would be made, one for each list without a folder of its name.
    let newFolders: [String]
}
