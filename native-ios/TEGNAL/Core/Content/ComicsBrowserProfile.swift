import Foundation
import WebKit
import CryptoKit

/// One browser profile per comics website, shared by its sign-in and its bot check, so a check
/// passed once also lets the sign-in page through. Image mode and other websites never share it.
@MainActor
enum ComicsBrowserProfile {
    private static var stores: [String: WKWebsiteDataStore] = [:]

    static func dataStore(forHost host: String) -> WKWebsiteDataStore {
        let site = SiteClearance.domain(of: host)
        if let store = stores[site] { return store }
        let store: WKWebsiteDataStore
        if ContentPreferences.isIsolated { store = .nonPersistent() }
        else { store = WKWebsiteDataStore(forIdentifier: identifier(site)) }
        stores[site] = store
        return store
    }

    nonisolated static func identifier(_ site: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("tegnal.comics.profile." + site).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func configuration(forHost host: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(forHost: host)
        return configuration
    }

    /// Keeps the bot check's cookies that a profile's browser holds, with that browser's identity.
    @discardableResult
    static func adoptClearance(from view: WKWebView, host: String) async -> Bool {
        let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard cookies.contains(where: { $0.name == "cf_clearance" }) else { return false }
        guard let agent = try? await view.evaluateJavaScript("navigator.userAgent") as? String, !agent.isEmpty else { return false }
        return SiteClearance.save(cookies, userAgent: agent, host: host)
    }

    /// Forgets everything a website's profile kept, including a sign-in made in it.
    static func reset(host: String) async {
        SiteClearance.remove(host: host)
        await dataStore(forHost: host).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Signs a website's profile out, keeping its passed bot check.
    static func forgetSignIn(host: String, session: Bool = false) async {
        let store = dataStore(forHost: host).httpCookieStore
        for cookie in await store.allCookies() {
            let account = SiteAccount.isIdentity(cookie.name) || cookie.name == SiteAccount.accessCookie
            // A site's own sign-in lives in whichever of its cookies it chose; all but the bot check's go.
            guard account || (session && !SiteClearance.isClearanceCookie(cookie.name)) else { continue }
            await store.deleteCookie(cookie)
        }
    }

    /// Navigations a sign-in or check page may make: secure pages and the frames a check draws itself.
    nonisolated static func allows(_ url: URL, mainFrame: Bool) -> Bool {
        if url.scheme == "https" { return url.user == nil && url.password == nil }
        guard !mainFrame else { return url.absoluteString == "about:blank" }
        return ["about:blank", "about:srcdoc"].contains(url.absoluteString) || ["blob", "data"].contains(url.scheme ?? "")
    }
}
