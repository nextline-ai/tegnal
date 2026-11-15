import Foundation
import Security

/// Some catalogs open a work by its number plus a short key. The key is only a
/// cache: a forgotten one is found again by searching the number.
final class GalleryKeys: @unchecked Sendable {
    static let shared = GalleryKeys(file: ContentPreferences.isIsolated ? nil : GalleryKeys.defaultFile)
    private static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("gallery-keys.plist")
    }
    private let lock = NSLock()
    private let file: URL?
    private let limit: Int
    private var keys: [Int64: String] = [:]
    private var order: [Int64] = []
    private var loaded = false
    private var saving = false

    init(file: URL?, limit: Int = 50_000) {
        self.file = file
        self.limit = limit
    }

    static func isKey(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func key(for id: Int64) -> String? {
        lock.withLock { loadIfNeeded(); return keys[id] }
    }

    func remember(_ id: Int64, key: String) { remember([(id, key)]) }

    /// Forgets a key the site no longer accepts, so the number is searched again.
    func forget(_ id: Int64) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            guard keys.removeValue(forKey: id) != nil else { return false }
            order.removeAll { $0 == id }
            return true
        }
        if changed { scheduleSave() }
    }

    func remember(_ pairs: [(Int64, String)]) {
        let changed = lock.withLock { () -> Bool in
            loadIfNeeded()
            var changed = false
            for (id, key) in pairs where id > 0 && Self.isKey(key) && keys[id] != key {
                if keys[id] == nil { order.append(id) }
                keys[id] = key
                changed = true
            }
            if order.count > limit {
                let dropped = order.prefix(order.count - limit * 9 / 10)
                for id in dropped { keys[id] = nil }
                order.removeFirst(dropped.count)
            }
            return changed
        }
        if changed { scheduleSave() }
    }

    func removeAll() {
        lock.withLock { keys.removeAll(); order.removeAll(); loaded = true }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let rows = try? PropertyListDecoder().decode([[String]].self, from: data) else { return }
        for row in rows where row.count == 2 {
            guard let id = Int64(row[0]), Self.isKey(row[1]), keys[id] == nil else { continue }
            keys[id] = row[1]
            order.append(id)
        }
    }

    private func scheduleSave() {
        guard let file else { return }
        let start = lock.withLock { () -> Bool in
            guard !saving else { return false }
            saving = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            let rows = lock.withLock { () -> [[String]] in
                saving = false
                return order.compactMap { id in keys[id].map { [String(id), $0] } }
            }
            guard let data = try? PropertyListEncoder().encode(rows) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            AppStorage.excludeFromBackup(file)
        }
    }
}

/// The signed-in identities catalogs ask for, kept in the keychain, one per website. Only an
/// account's identity cookies are kept from sign-in, and they reach nothing but the website they
/// were signed in for and its own subdomains.
enum SiteAccount {
    private struct Stored: Codable {
        /// The forum identity every website shared before each kept its own; on first read it moves
        /// to the websites connected at the time.
        var identity: [String: String] = [:]
        /// Cookies each website set for itself, by host.
        var sites: [String: [String: String]] = [:]
        /// Sign-ins made on a site's own pages, by host: the cookies its pages set once signed in.
        /// Optional so sign-ins kept before these existed still read.
        var sessions: [String: [String: String]]? = nil
        /// Each website's forum identity, by host. Optional so sign-ins kept before these existed still read.
        var identities: [String: [String: String]]? = nil
    }
    private static let lock = NSLock()
    private static let service = "work.nextline.tegnal.site-account"
    private nonisolated(unsafe) static var cached: Stored?
    /// Websites that signed an account in but handed it the placeholder instead of access.
    private nonisolated(unsafe) static var refused = Set<String>()
    static let didChange = Notification.Name("siteAccountDidChange")

    /// Names follow the forum software these catalogs share, not any one site.
    static func isIdentity(_ name: String) -> Bool { name.hasSuffix("_member_id") || name.hasSuffix("_pass_hash") }

    /// The cookie a members-only catalog hands an account it lets in.
    static let accessCookie = "igneous"

    /// A value the site sends instead of access when the account is not let in. Keeping it would
    /// keep the account out even after the account is allowed.
    static func isPlaceholder(name: String, value: String) -> Bool {
        name == accessCookie && (value.isEmpty || value == "mystery" || value == "deleted")
    }

    /// Whether the connected website keeps a forum identity of its own.
    static var isSignedIn: Bool { hasIdentity(host: MangaUrls.configuredHost) }

    /// Whether [host] keeps a forum identity of its own.
    static func hasIdentity(host: String) -> Bool {
        !host.isEmpty && signedIn(lock.withLock { load() }.identities?[host] ?? [:])
    }

    /// Whether [host] has an account: its forum identity, or a sign-in made on its own pages.
    static func isSignedIn(host: String) -> Bool {
        let stored = lock.withLock { load() }
        return !(stored.sessions?[host] ?? [:]).isEmpty || signedIn(stored.identities?[host] ?? [:])
    }

    /// Whether [host] signed its account in but hands it the placeholder instead of access: a
    /// members-only catalog that hasn't opened to this account.
    static func refusesAccess(host: String) -> Bool {
        lock.withLock { refused.contains(host) && signedIn(load().identities?[host] ?? [:]) }
    }

    /// Signs one website out; other websites keep their accounts.
    static func signOut(host: String) {
        lock.withLock {
            var stored = load()
            stored.sessions?[host] = nil
            stored.identities?[host] = nil
            stored.sites[host] = nil
            refused.remove(host)
            save(stored)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func hasSession(host: String) -> Bool { !(lock.withLock { load() }.sessions?[host] ?? [:]).isEmpty }

    /// Keeps a sign-in made on [host]'s own pages: the cookies its pages set for it, apart from a
    /// bot check's and analytics. Returns false when none are left.
    @discardableResult
    static func signIn(session cookies: [HTTPCookie], host: String) -> Bool {
        let site = registrableDomain(host.lowercased())
        var values: [String: String] = [:]
        for cookie in cookies where !cookie.value.isEmpty && isCookieName(cookie.name) && isCookieValue(cookie.value) {
            let owner = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard owner == site || owner.hasSuffix("." + site), !SiteClearance.isClearanceCookie(cookie.name),
                  !cookie.name.hasPrefix("_ga"), !cookie.name.hasPrefix("_gid") else { continue }
            if let expires = cookie.expiresDate, expires < Date() { continue }
            values[cookie.name] = cookie.value
        }
        guard !values.isEmpty, !host.isEmpty else { return false }
        lock.withLock {
            var stored = load()
            var sessions = stored.sessions ?? [:]
            sessions[host] = values
            stored.sessions = sessions
            save(stored)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    private static func signedIn(_ identity: [String: String]) -> Bool {
        identity.contains { $0.key.hasSuffix("_member_id") && (Int($0.value) ?? 0) > 0 }
            && identity.contains { $0.key.hasSuffix("_pass_hash") && !$0.value.isEmpty }
    }

    /// Keeps the identity from a finished sign-in for [host]. Returns false when the cookies hold none.
    @discardableResult
    static func signIn(with cookies: [HTTPCookie], host: String) -> Bool {
        var identity: [String: String] = [:]
        for cookie in cookies where isIdentity(cookie.name) && !cookie.value.isEmpty { identity[cookie.name] = cookie.value }
        return keep(identity, site: nil, host: host)
    }

    /// Signs [host] in with the account another website keeps, as for two websites of one forum.
    @discardableResult
    static func useAccount(from source: String, on host: String) -> Bool {
        keep(lock.withLock { load().identities?[source] } ?? [:], site: nil, host: host)
    }

    /// Other websites keeping a forum identity that [host] could use too.
    static func accountSources(excluding host: String) -> [String] {
        let stored = lock.withLock { load() }
        return (stored.identities ?? [:]).filter { $0.key != host && signedIn($0.value) }.keys.sorted()
    }

    /// Keeps [identity] for [host]; cookies the website set for another account no longer apply.
    private static func keep(_ identity: [String: String], site cookies: [String: String]?, host: String) -> Bool {
        guard signedIn(identity), !host.isEmpty else { return false }
        lock.withLock {
            var stored = load()
            var identities = stored.identities ?? [:]
            identities[host] = identity
            stored.identities = identities
            stored.sites[host] = cookies.flatMap { $0.isEmpty ? nil : $0 }
            refused.remove(host)
            save(stored)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    /// What a person pasted from a browser where they are signed in.
    struct PastedCookies: Equatable {
        var identity: [String: String] = [:]
        /// Other cookies the site keeps for the account, such as access to a members-only catalog.
        var site: [String: String] = [:]
        var isComplete: Bool { SiteAccount.signedIn(identity) }
    }

    /// Reads `name=value` pairs from a cookie header, a browser's cookie list or one value per line.
    /// Only the account cookies and cookies the site keeps for it are taken.
    static func parseCookies(_ text: String) -> PastedCookies {
        var result = PastedCookies()
        let separators = CharacterSet(charactersIn: ";\n\r\t,")
        for piece in text.components(separatedBy: separators) {
            var pair = piece.trimmingCharacters(in: .whitespaces)
            if pair.lowercased().hasPrefix("cookie:") { pair = String(pair.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            guard isCookieName(name), isCookieValue(value) else { continue }
            if isIdentity(name) { result.identity[name] = value }
            else if keepsForAccount(name), !isPlaceholder(name: name, value: value) { result.site[name] = value }
        }
        return result
    }

    /// Cookies an account carries besides its identity: access, settings key and perks.
    static func keepsForAccount(_ name: String) -> Bool {
        [accessCookie, "sk", "sp", "star", "hath_perks", "iq"].contains(name)
    }

    private static func isCookieName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    private static func isCookieValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && value.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != ";" }
    }

    /// Signs [host] in with cookies copied from a browser; the other cookies belong to [host] too.
    @discardableResult
    static func signIn(pasted: PastedCookies, host: String) -> Bool {
        guard pasted.isComplete else { return false }
        return keep(pasted.identity, site: pasted.site, host: host)
    }

    /// Drops one cookie the site set, so the site hands out a fresh one on the next request.
    static func forget(_ name: String, host: String) {
        lock.withLock {
            var stored = load()
            if name == accessCookie { refused.remove(host) }
            guard stored.sites[host]?[name] != nil else { return }
            stored.sites[host]?[name] = nil
            save(stored)
        }
    }

    /// The value of a cookie the site set for [host], as the next request sends it.
    static func siteCookie(_ name: String, host: String) -> String? {
        lock.withLock { load().sites[host]?[name] }
    }

    /// Sets a cookie for [host] the way the website's own pages would, such as its settings profile.
    static func setSiteCookie(_ name: String, value: String, host: String) {
        guard isCookieName(name), isCookieValue(value), !host.isEmpty else { return }
        lock.withLock {
            var stored = load()
            var site = stored.sites[host] ?? [:]
            guard site[name] != value else { return }
            site[name] = value
            stored.sites[host] = site
            save(stored)
        }
    }

    /// Drops a cookie the site refused, unless the same answer already handed out another one:
    /// a members-only catalog may show its wall to a request without access while setting the
    /// access that lets the next request in.
    static func forget(_ name: String, host: String, refused sent: String?) {
        lock.withLock {
            var stored = load()
            guard let current = stored.sites[host]?[name], current == sent else { return }
            stored.sites[host]?[name] = nil
            save(stored)
        }
    }

    /// The account cookie names saved for [host], for showing what is kept without the values.
    static func savedCookieNames(host: String) -> [String] {
        let stored = lock.withLock { load() }
        guard let identity = stored.identities?[host], signedIn(identity) else { return [] }
        return (Array(identity.keys) + Array((stored.sites[host] ?? [:]).keys)).sorted()
    }

    /// Signs every website out.
    static func signOut() {
        lock.withLock { save(Stored()); refused.removeAll() }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The connected site and its subdomains, while that site is one that uses accounts.
    static func applies(to url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let site = MangaUrls.configuredHost
        guard !site.isEmpty, host == site || host.hasSuffix("." + site) || host.hasSuffix("." + registrableDomain(site)) else { return false }
        return MangaUrls.usesAccount
    }

    static func cookieHeader(for url: URL) -> String? {
        guard applies(to: url) else { return nil }
        let values = cookies(forSite: MangaUrls.configuredHost)
        return values.isEmpty ? nil : values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// What the site expects back: its identity, cookies it set, and consent to open flagged works.
    static func cookies(forSite host: String) -> [String: String] {
        let stored = lock.withLock { load() }
        var values = stored.sessions?[host] ?? [:]
        // What the site set later, such as a renewed session, replaces what sign-in kept. Cookies
        // kept before they were known to be ignored are not sent either.
        values.merge((stored.sites[host] ?? [:]).filter { !isPlaceholder(name: $0.key, value: $0.value) && !ignoresCookie($0.key) && !SiteClearance.isClearanceCookie($0.key) }) { _, newer in newer }
        values["nw"] = "1"
        if let identity = stored.identities?[host], signedIn(identity) { values.merge(identity) { _, identity in identity } }
        return values
    }

    static func browserCookies(for host: String) -> [HTTPCookie] {
        guard MangaUrls.usesAccount, host == MangaUrls.configuredHost else { return [] }
        return cookies(forSite: host).compactMap { name, value in
            HTTPCookie(properties: [.domain: host, .path: "/", .name: name, .value: value, .secure: "TRUE"])
        }
    }

    /// Keeps cookies the site sets for itself, such as access it grants after the identity is
    /// checked, and notes when it hands out the placeholder instead.
    static func store(_ response: HTTPURLResponse) {
        guard let url = response.url, applies(to: url),
              let fields = response.allHeaderFields as? [String: String] else { return }
        // A bot check's cookies are kept with the browser that earned them, never here.
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { !isIdentity($0.name) && !ignoresCookie($0.name) && !SiteClearance.isClearanceCookie($0.name) }
        guard !received.isEmpty else { return }
        let host = MangaUrls.configuredHost
        lock.withLock {
            var stored = load()
            var site = stored.sites[host] ?? [:]
            for cookie in received {
                let expired = cookie.expiresDate.map { $0 < Date() } ?? false
                if cookie.name == accessCookie {
                    if cookie.value == "mystery" { refused.insert(host) }
                    else if !expired && !isPlaceholder(name: cookie.name, value: cookie.value) { refused.remove(host) }
                }
                // A placeholder instead of access is never kept: the access already held stays.
                if isPlaceholder(name: cookie.name, value: cookie.value) { continue }
                if expired || cookie.value.isEmpty || cookie.value == "deleted" { site[cookie.name] = nil }
                else { site[cookie.name] = cookie.value }
            }
            guard stored.sites[host] != site else { return }
            stored.sites[host] = site
            save(stored)
        }
    }

    /// Cookies a site sets that are never kept: the content filter it sets itself, a tracking
    /// cookie other clients drop because sending it back changes how the site answers, and the mark
    /// a members-only catalog leaves on a visit without access, which other clients delete at every
    /// launch and sign-in so it can't keep an account that has access out.
    static func ignoresCookie(_ name: String) -> Bool { ["nw", "__utmp", "yay"].contains(name) }

    static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".")
        return labels.count > 2 ? labels.suffix(2).joined(separator: ".") : host
    }

    private static func load() -> Stored {
        if let cached { return cached }
        var result = Stored()
        if !ContentPreferences.isIsolated {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: "account", kSecReturnData as String: true]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
               let decoded = try? JSONDecoder().decode(Stored.self, from: data) { result = decoded }
        }
        if result.identities == nil {
            // An account kept before each website had its own stays with every website connected now.
            var identities: [String: [String: String]] = [:]
            if signedIn(result.identity) {
                for host in Set(ComicSites.all).union(result.sites.keys) where !host.isEmpty { identities[host] = result.identity }
            }
            result.identities = identities
            result.identity = [:]
            save(result)
        }
        cached = result
        return result
    }

    private static func save(_ stored: Stored) {
        cached = stored
        guard !ContentPreferences.isIsolated else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account"]
        guard !stored.identity.isEmpty || !stored.sites.isEmpty || !(stored.sessions ?? [:]).isEmpty || !(stored.identities ?? [:]).isEmpty,
              let data = try? JSONEncoder().encode(stored) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// What a website's bot check hands a browser that passed it, kept per website with the exact
/// browser identity that earned it: the check accepts its cookies only from that same browser.
/// The cookies reach nothing but that website and its subdomains.
enum SiteClearance {
    struct Entry: Codable, Equatable {
        var cookies: [String: String]
        var userAgent: String
        var savedAt: Date
    }
    private static let lock = NSLock()
    private static let service = "work.nextline.tegnal.site-clearance"
    private nonisolated(unsafe) static var cached: [String: Entry]?
    static let didChange = Notification.Name("siteClearanceDidChange")

    /// Cookies the bot check sets. Nothing else from the check's browser is kept.
    static func isClearanceCookie(_ name: String) -> Bool { name.hasPrefix("cf_") || name.hasPrefix("__cf") }

    /// The website a host belongs to, so a check passed on one of its hosts covers the others.
    static func domain(of host: String) -> String { SiteAccount.registrableDomain(host.lowercased()) }

    static func entry(for url: URL) -> Entry? {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        return entry(forHost: host)
    }

    static func entry(forHost host: String) -> Entry? {
        lock.withLock { load()[domain(of: host)] }
    }

    static func hasClearance(forHost host: String) -> Bool { entry(forHost: host) != nil }

    /// Keeps a passed check. Returns false when the cookies hold no clearance.
    @discardableResult
    static func save(_ cookies: [HTTPCookie], userAgent: String, host: String) -> Bool {
        let site = domain(of: host)
        var values: [String: String] = [:]
        for cookie in cookies where isClearanceCookie(cookie.name) && !cookie.value.isEmpty {
            let owner = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard owner == site || owner.hasSuffix("." + site) else { continue }
            if let expires = cookie.expiresDate, expires < Date() { continue }
            values[cookie.name] = cookie.value
        }
        guard values.keys.contains(where: { $0 == "cf_clearance" }), !userAgent.isEmpty else { return false }
        lock.withLock {
            var entries = load()
            entries[site] = Entry(cookies: values, userAgent: userAgent, savedAt: Date())
            save(entries)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    /// Forgets a website's passed check, as when the website asks again.
    static func remove(host: String) {
        let site = domain(of: host)
        let removed = lock.withLock { () -> Bool in
            var entries = load()
            guard entries.removeValue(forKey: site) != nil else { return false }
            save(entries)
            return true
        }
        if removed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    static func removeAll() {
        lock.withLock { save([:]) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func load() -> [String: Entry] {
        if let cached { return cached }
        var result: [String: Entry] = [:]
        if !ContentPreferences.isIsolated {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: "clearance", kSecReturnData as String: true]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
               let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) { result = decoded }
        }
        cached = result
        return result
    }

    private static func save(_ entries: [String: Entry]) {
        cached = entries
        guard !ContentPreferences.isIsolated else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "clearance"]
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// Where a saved work sits for favorites sync: in a favorites category the app keeps a folder for,
/// or anywhere else.
enum FavoritePlace: Hashable, Sendable {
    case category(Int)
    case unassigned

    var category: Int? { if case .category(let category) = self { category } else { nil } }

    /// A work in a category's folder is not also "anywhere else".
    static func normalized(_ places: Set<FavoritePlace>) -> Set<FavoritePlace> {
        places.contains { $0.category != nil } ? places.subtracting([.unassigned]) : places
    }
}

/// A website's favorites as one read gives them: its categories, or the lists an account makes,
/// and which of them hold each work.
struct AccountFavorites: Equatable, Sendable {
    var categories: [FavoriteCategory]
    var members: [Int64: Set<Int>]
    /// A favorite sits in one category at a time, and adding it to another moves it there. Lists
    /// an account makes can each hold the same work.
    var exclusive: Bool
}

/// Each signed-in website's favorites categories and the app folders kept in step with them.
final class SiteFavoriteFolders: @unchecked Sendable {
    static let shared = SiteFavoriteFolders(defaults: ContentPreferences.defaults)

    struct State: Codable, Equatable, Sendable {
        /// Favorites category or list → the sync identity of its folder.
        var folders: [Int: String] = [:]
        /// Where works in other folders are kept on the website; nil when every category has a folder.
        var unassigned: Int?
        /// The categories holding each work after the last sync; nil before the first.
        var baseline: [Int64: Set<Int>]?
        /// Works never sent to the website: saved before the sync began, or ones it cannot keep.
        var localOnly: Set<Int64> = []
        var lastPull: Date?
        /// Whether a favorite sits in one category at a time; nil reads as true.
        var exclusive: Bool?
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let statesKey = "manga.favoriteSync"
    private static let declinedKey = "manga.favoriteSyncDeclined"

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// A website whose favorites are synced, with what was learned about them.
    func state(for site: String) -> State? {
        lock.withLock { (states[site]).flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
    }

    func setState(_ state: State, for site: String) {
        lock.withLock {
            var states = states
            states[site] = try? JSONEncoder().encode(state)
            defaults.set(states, forKey: Self.statesKey)
            defaults.set(declined.subtracting([site]).sorted(), forKey: Self.declinedKey)
        }
    }

    var syncedSites: [String] { lock.withLock { states.keys.sorted() } }

    /// Stops syncing a website. Turned off by hand, it is not set up again on its own.
    func remove(_ site: String, declined decline: Bool) {
        lock.withLock {
            var states = states
            states[site] = nil
            defaults.set(states, forKey: Self.statesKey)
            if decline { defaults.set(declined.union([site]).sorted(), forKey: Self.declinedKey) }
        }
    }

    func isDeclined(_ site: String) -> Bool { lock.withLock { declined.contains(site) } }

    private var states: [String: Data] { defaults.dictionary(forKey: Self.statesKey) as? [String: Data] ?? [:] }
    private var declined: Set<String> { Set(defaults.stringArray(forKey: Self.declinedKey) ?? []) }
}

/// What one sync changes on each side. Comparing each work's places with where it was after the
/// last sync tells which side added or took it away; the other side follows, and when both changed
/// the same place, the website wins.
struct FavoriteSyncPlan: Equatable, Sendable {
    enum LocalChange: Equatable, Sendable {
        /// The places the saved work ends up in: category folders, or anywhere else.
        case place(Int64, Set<FavoritePlace>)
        case remove(Int64)
    }
    /// One request: a work added to a category (moved there, where a favorite has one) or taken out of it.
    struct SiteChange: Equatable, Sendable {
        let id: Int64
        let category: Int
        let adds: Bool
    }

    var local: [LocalChange] = []
    var site: [SiteChange] = []
    /// The categories holding each work once the plan is carried out.
    var settled: [Int64: Set<Int>] = [:]
    /// Works that stop being sent, and works that start being sent again.
    var keepLocal: [Int64] = []
    var stopKeepingLocal: [Int64] = []

    var isEmpty: Bool { local.isEmpty && site.isEmpty }

    /// `local` is where each saved work sits; `remote` the categories holding each favorite, or the
    /// baseline to send only changes made in the app. A category without a folder counts as
    /// anywhere else, and a work kept anywhere else stays in the categories without folders it is in.
    static func make(local: [Int64: Set<FavoritePlace>], remote: [Int64: Set<Int>], base: [Int64: Set<Int>]?, folders: Set<Int>,
                     unassigned: Int?, localOnly: Set<Int64>, exclusive: Bool = true) -> FavoriteSyncPlan {
        func places(_ categories: Set<Int>) -> Set<FavoritePlace> {
            FavoritePlace.normalized(Set(categories.map { folders.contains($0) ? .category($0) : .unassigned }))
        }
        var plan = FavoriteSyncPlan()
        let ids = Set(local.keys).union(remote.keys).union(base?.keys ?? [:].keys)
        for id in ids.sorted() {
            let l = FavoritePlace.normalized(local[id] ?? []), rawRemote = remote[id] ?? [], r = places(rawRemote)
            var b = base.map { places($0[id] ?? []) }
            if localOnly.contains(id) {
                if !rawRemote.isEmpty { plan.stopKeepingLocal.append(id) }
                else if l.contains(where: { $0.category != nil }) {
                    // Put in a category folder by hand, it is sent after all.
                    plan.stopKeepingLocal.append(id)
                    b = []
                } else { continue }
            }
            let final: Set<FavoritePlace>
            if let b {
                final = FavoritePlace.normalized(l.union(r).union(b).filter { place in
                    let inLocal = l.contains(place), inRemote = r.contains(place)
                    if inLocal == inRemote { return inLocal }
                    // Changed on the website, or on both sides: the website wins.
                    return inRemote != b.contains(place) ? inRemote : inLocal
                })
            } else {
                // The library saved before the sync began is not sent all at once.
                if rawRemote.isEmpty, l == [.unassigned] { plan.keepLocal.append(id); continue }
                final = FavoritePlace.normalized(l.union(r))
            }
            if final != l {
                if final.isEmpty { if !l.isEmpty { plan.local.append(.remove(id)) } }
                else { plan.local.append(.place(id, final)) }
            }
            // The categories the website should hold the work in.
            var wanted = Set(final.compactMap(\.category))
            if final == [.unassigned] {
                let elsewhere = rawRemote.subtracting(folders)
                if !elsewhere.isEmpty { wanted = elsewhere }
                else if let unassigned { wanted = [unassigned] }
                else { plan.keepLocal.append(id) }
            } else if !exclusive, !final.isEmpty {
                // Lists without folders keep what they hold; only a work taken away leaves them too.
                wanted.formUnion(rawRemote.subtracting(folders))
            }
            if exclusive, wanted.count > 1 {
                // The website keeps one: where it already is, else the folder it was just put in.
                let chosen = rawRemote.first { wanted.contains($0) }
                    ?? wanted.filter { !(b ?? []).contains(.category($0)) }.min() ?? wanted.min()!
                wanted = [chosen]
            }
            if wanted == rawRemote {
                if !wanted.isEmpty { plan.settled[id] = wanted }
                continue
            }
            if exclusive {
                if let category = wanted.first { plan.site.append(SiteChange(id: id, category: category, adds: true)) }
                else if let category = rawRemote.min() { plan.site.append(SiteChange(id: id, category: category, adds: false)) }
            } else {
                for category in wanted.subtracting(rawRemote).sorted() { plan.site.append(SiteChange(id: id, category: category, adds: true)) }
                for category in rawRemote.subtracting(wanted).sorted() { plan.site.append(SiteChange(id: id, category: category, adds: false)) }
            }
            if !wanted.isEmpty { plan.settled[id] = wanted }
        }
        return plan
    }
}
