import Foundation
import WebKit

/// Some system network filters apply to WebKit rather than URLSession. Keep the
/// configured origin in a browser session without changing the native screens.
@MainActor
enum ContentBrowserTransport {
    private static var sessions: [String: Browser] = [:]

    /// A sign-in or sign-out changes the cookies a browser session was started with.
    static func reset() {
        for browser in sessions.values { browser.view.stopLoading() }
        sessions.removeAll()
    }

    static func inspectWebsite(at origin: URL) async throws -> String {
        for attempt in 0..<3 {
            do { return try await websiteHTML(at: origin) }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, ContentTransport.isTransient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private static func websiteHTML(at origin: URL) async throws -> String {
        guard origin.scheme == "https", origin.user == nil, origin.password == nil else { throw URLError(.unsupportedURL) }
        let browser = Browser(origin: origin)
        defer { browser.view.stopLoading() }
        try await browser.ready()
        let value = try await browser.view.evaluateJavaScript("document.documentElement.outerHTML", in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard let text = value as? String, text.utf8.count <= 1_000_000 else { throw ContentError.invalidResponse }
        return text
    }

    static func get(_ url: URL, origin: URL, limit: Int, range: Range<Int>?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try await fetch(url, origin: origin, limit: limit, range: range, timeout: timeout, body: nil, contentType: nil)
    }

    static func post(_ url: URL, origin: URL, body: Data, contentType: String, limit: Int, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try await fetch(url, origin: origin, limit: limit, range: nil, timeout: timeout, body: body, contentType: contentType)
    }

    private static func fetch(_ url: URL, origin: URL, limit: Int, range: Range<Int>?, timeout: TimeInterval,
                              body: Data?, contentType: String?) async throws -> (Data, HTTPURLResponse) {
        guard ContentTransport.allows(url), origin.absoluteString == MangaUrls.home else { throw URLError(.unsupportedURL) }
        let key = origin.absoluteString
        if sessions[key] == nil {
            sessions = sessions.filter { $0.key == key }
            sessions[key] = Browser(origin: origin)
        }
        let browser = sessions[key]!
        do { try await browser.ready() }
        catch {
            if !Task.isCancelled, sessions[key] === browser {
                browser.view.stopLoading()
                sessions[key] = nil
            }
            throw error
        }
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        let value = try await withTaskCancellationHandler {
            try await browser.view.callAsyncJavaScript("""
                const target = new URL(address);
                const controller = new AbortController();
                globalThis.contentRequests ??= new Map();
                globalThis.contentRequests.set(requestID, controller);
                const timer = setTimeout(() => controller.abort(), timeout);
                try {
                    const headers = {};
                    if (range) headers.Range = range;
                    if (contentType) headers['Content-Type'] = contentType;
                    const response = await fetch(target.href, {headers, redirect:'error', method: body === null ? 'GET' : 'POST',
                        body: body === null ? undefined : body,
                        credentials:target.origin === location.origin ? 'include' : 'omit', signal:controller.signal});
                    const reader = response.body.getReader();
                    const chunks = [];
                    let size = 0;
                    while (true) {
                        const chunk = await reader.read();
                        if (chunk.done) break;
                        size += chunk.value.length;
                        if (size > limit) { await reader.cancel(); return {tooLarge:true}; }
                        chunks.push(chunk.value);
                    }
                    let binary = '';
                    for (const chunk of chunks) {
                        for (let offset = 0; offset < chunk.length; offset += 8192)
                            binary += String.fromCharCode(...chunk.subarray(offset, offset + 8192));
                    }
                    return {status:response.status, body:btoa(binary),
                        mime:response.headers.get('content-type') ?? '', range:response.headers.get('content-range') ?? ''};
                } catch (error) {
                    if (error.name === 'AbortError') return {networkError:'timeout'};
                    if (error.name === 'TypeError') return {networkError:'connection'};
                    throw error;
                } finally {
                    clearTimeout(timer);
                    globalThis.contentRequests.delete(requestID);
                }
                """, arguments: ["address": url.absoluteString, "requestID": requestID, "limit": limit,
                                  "timeout": Int(timeout * 1000),
                                  "range": range.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" } ?? "",
                                  "body": body.map { String(decoding: $0, as: UTF8.self) } ?? NSNull(), "contentType": contentType ?? ""],
                in: nil, contentWorld: .defaultClient)
        } onCancel: {
            Task { @MainActor in
                _ = try? await browser.view.callAsyncJavaScript("globalThis.contentRequests?.get(requestID)?.abort();",
                    arguments: ["requestID": requestID], in: nil, contentWorld: .defaultClient)
            }
        }
        try Task.checkCancellation()
        guard origin.absoluteString == MangaUrls.home, ContentTransport.allows(url) else { throw CancellationError() }
        if let result = value as? [String: Any], result["tooLarge"] as? Bool == true { throw ContentError.tooLarge }
        if let result = value as? [String: Any], let failure = result["networkError"] as? String {
            throw URLError(failure == "timeout" ? .timedOut : .networkConnectionLost)
        }
        guard let result = value as? [String: Any], let status = result["status"] as? Int,
              let body = result["body"] as? String, let data = Data(base64Encoded: body), data.count <= limit,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                  headerFields: ["Content-Type": result["mime"] as? String ?? "", "Content-Range": result["range"] as? String ?? ""]) else {
            throw ContentError.invalidResponse
        }
        guard [200, 206, 416].contains(status) else { throw ContentError.unavailable(status) }
        return (data, response)
    }

    private final class Browser: NSObject, WKNavigationDelegate {
        let origin: URL
        let view: WKWebView
        private var committed = false
        private var failure: Error?
        private var pendingCookies = 0
        init(origin: URL) {
            self.origin = origin
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            view.navigationDelegate = self
            view.load(URLRequest(url: origin))
            // A cookie store that has not served a page yet may never confirm a cookie, so the
            // page loads at once and requests wait briefly for the account's cookies instead.
            let cookies = SiteAccount.browserCookies(for: origin.host?.lowercased() ?? "")
            pendingCookies = cookies.count
            for cookie in cookies {
                view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in self?.pendingCookies -= 1 }
            }
        }
        func ready() async throws {
            for attempt in 0..<200 {
                try Task.checkCancellation()
                if let failure { throw failure }
                if committed, view.url?.host == origin.host, pendingCookies <= 0 || attempt >= 30,
                   (try? await view.evaluateJavaScript("document.readyState !== 'loading'", in: nil, contentWorld: .defaultClient)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw URLError(.timedOut)
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = URLError(.networkConnectionLost) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame == false {
                decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
            } else {
                decisionHandler(url.scheme == "https" && url.host == origin.host && url.port == origin.port ? .allow : .cancel)
            }
        }
    }
}
