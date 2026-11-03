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
    }
    private static let lock = NSLock()
    private static let service = "work.nextline.tegnal.site-account"
    private nonisolated(unsafe) static var cached: Stored?
    static let didChange = Notification.Name("siteAccountDidChange")

    /// Names follow the forum software these catalogs share, not any one site.
    static func isIdentity(_ name: String) -> Bool { name.hasSuffix("_member_id") || name.hasSuffix("_pass_hash") }

    static var isSignedIn: Bool { signedIn(lock.withLock { load() }.identity) }

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
            stored.sites.removeAll()
            save(stored)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
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
        var values = stored.sites[host] ?? [:]
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
        guard !stored.identity.isEmpty || !stored.sites.isEmpty, let data = try? JSONEncoder().encode(stored) else {
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
