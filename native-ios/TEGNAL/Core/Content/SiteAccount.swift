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

/// The signed-in identity a catalog may ask for, kept in the keychain.
/// Only the account's identity cookies are kept from sign-in, and they reach
/// nothing but the connected site and its own subdomains.
enum SiteAccount {
    private struct Stored: Codable {
        var identity: [String: String] = [:]
        /// Cookies the connected site set for itself, by host.
        var sites: [String: [String: String]] = [:]
        /// Sign-ins made on a site's own pages, by host: the cookies its pages set once signed in.
        /// Optional so sign-ins kept before these existed still read.
        var sessions: [String: [String: String]]? = nil
    }
    private static let lock = NSLock()
    private static let service = "work.nextline.tegnal.site-account"
    private nonisolated(unsafe) static var cached: Stored?
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

    static var isSignedIn: Bool { signedIn(lock.withLock { load() }.identity) }

    /// Whether [host] has an account: the forum identity, or a sign-in made on its own pages.
    static func isSignedIn(host: String) -> Bool {
        let stored = lock.withLock { load() }
        if !(stored.sessions?[host] ?? [:]).isEmpty { return true }
        // A site that signs in on its own pages does not take the forum identity.
        return !MangaUrls.usesSiteSession && signedIn(stored.identity)
    }

    /// Signs out of one site that signs in on its own pages; other sites keep their accounts.
    static func signOut(host: String) {
        lock.withLock {
            var stored = load()
            stored.sessions?[host] = nil
            stored.sites[host] = nil
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

    /// Keeps the identity from a finished sign-in. Returns false when the cookies hold none.
    @discardableResult
    static func signIn(with cookies: [HTTPCookie]) -> Bool {
        var identity: [String: String] = [:]
        for cookie in cookies where isIdentity(cookie.name) && !cookie.value.isEmpty { identity[cookie.name] = cookie.value }
        guard signedIn(identity) else { return false }
        lock.withLock {
            var stored = load()
            stored.identity = identity
            // Cookies a site set for another account no longer apply; its own sign-ins stay.
            stored.sites.removeAll()
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
        [accessCookie, "sk", "star", "hath_perks", "yay", "iq"].contains(name)
    }

    private static func isCookieName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    private static func isCookieValue(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && value.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != ";" }
    }

    /// Signs in with cookies copied from a browser. The other cookies belong to [host].
    @discardableResult
    static func signIn(pasted: PastedCookies, host: String) -> Bool {
        guard pasted.isComplete else { return false }
        lock.withLock {
            var stored = load()
            stored.identity = pasted.identity
            // Cookies a site set for another account no longer apply; its own sign-ins stay.
            stored.sites.removeAll()
            if !host.isEmpty, !pasted.site.isEmpty { stored.sites[host] = pasted.site }
            save(stored)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    /// Drops one cookie the site set, so the site hands out a fresh one on the next request.
    static func forget(_ name: String, host: String) {
        lock.withLock {
            var stored = load()
            guard stored.sites[host]?[name] != nil else { return }
            stored.sites[host]?[name] = nil
            save(stored)
        }
    }

    /// The account cookie names saved for [host], for showing what is kept without the values.
    static func savedCookieNames(host: String) -> [String] {
        let stored = lock.withLock { load() }
        guard signedIn(stored.identity) else { return [] }
        return (Array(stored.identity.keys) + Array((stored.sites[host] ?? [:]).keys)).sorted()
    }

    static func signOut() {
        lock.withLock { save(Stored()) }
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

    /// What the site expects back: the identity, cookies it set, and consent to open flagged works.
    static func cookies(forSite host: String) -> [String: String] {
        let stored = lock.withLock { load() }
        var values = stored.sessions?[host] ?? [:]
        // What the site set later, such as a renewed session, replaces what sign-in kept.
        values.merge((stored.sites[host] ?? [:]).filter { !isPlaceholder(name: $0.key, value: $0.value) }) { _, newer in newer }
        values["nw"] = "1"
        if signedIn(stored.identity) { values.merge(stored.identity) { _, identity in identity } }
        return values
    }

    static func browserCookies(for host: String) -> [HTTPCookie] {
        guard MangaUrls.usesAccount, host == MangaUrls.configuredHost else { return [] }
        return cookies(forSite: host).compactMap { name, value in
            HTTPCookie(properties: [.domain: host, .path: "/", .name: name, .value: value, .secure: "TRUE"])
        }
    }

    /// Keeps cookies the site sets for itself, such as access it grants after the identity is checked.
    static func store(_ response: HTTPURLResponse) {
        guard let url = response.url, applies(to: url),
              let fields = response.allHeaderFields as? [String: String] else { return }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { !isIdentity($0.name) && $0.name != "nw" }
        guard !received.isEmpty else { return }
        let host = MangaUrls.configuredHost
        lock.withLock {
            var stored = load()
            var site = stored.sites[host] ?? [:]
            for cookie in received {
                let expired = cookie.expiresDate.map { $0 < Date() } ?? false
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
        cached = result
        return result
    }

    private static func save(_ stored: Stored) {
        cached = stored
        guard !ContentPreferences.isIsolated else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account"]
        guard !stored.identity.isEmpty || !stored.sites.isEmpty || !(stored.sessions ?? [:]).isEmpty,
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
