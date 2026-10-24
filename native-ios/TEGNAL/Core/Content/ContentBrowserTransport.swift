import Foundation
import WebKit

/// Some system network filters apply to WebKit rather than URLSession. Keep the
/// configured origin in a browser session without changing the native screens.
@MainActor
enum ContentBrowserTransport {
    private static var sessions: [String: Browser] = [:]

    static func isDocumentCatalog(at origin: URL) async throws -> Bool {
        guard origin.scheme == "https", origin.user == nil, origin.password == nil else { return false }
        let browser = Browser(origin: origin)
        defer { browser.view.stopLoading() }
        try await browser.ready()
        let value = try await browser.view.evaluateJavaScript("document.documentElement.outerHTML", in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation()
        guard let text = value as? String, text.utf8.count <= 1_000_000 else { return false }
        return MangaUrls.isDocumentPage(text)
    }

    static func get(_ url: URL, origin: URL, limit: Int, range: Range<Int>?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
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
                    const response = await fetch(target.href, {headers, redirect:'error',
                        credentials:target.origin === location.origin ? 'include' : 'omit', signal:controller.signal});
                    const reader = response.body.getReader();
                    const chunks = [];
                    let size = 0;
                    while (true) {
                        const chunk = await reader.read();
                        if (chunk.done) break;
                        size += chunk.value.length;
                        if (size > limit) { await reader.cancel(); throw new Error('Response too large'); }
                        chunks.push(chunk.value);
                    }
                    let binary = '';
                    for (const chunk of chunks) {
                        for (let offset = 0; offset < chunk.length; offset += 8192)
                            binary += String.fromCharCode(...chunk.subarray(offset, offset + 8192));
                    }
                    return {status:response.status, body:btoa(binary),
                        mime:response.headers.get('content-type') ?? '', range:response.headers.get('content-range') ?? ''};
                } finally {
                    clearTimeout(timer);
                    globalThis.contentRequests.delete(requestID);
                }
                """, arguments: ["address": url.absoluteString, "requestID": requestID, "limit": limit,
                                  "timeout": Int(timeout * 1000),
                                  "range": range.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" } ?? ""],
                in: nil, contentWorld: .defaultClient)
        } onCancel: {
            Task { @MainActor in
                _ = try? await browser.view.callAsyncJavaScript("globalThis.contentRequests?.get(requestID)?.abort();",
                    arguments: ["requestID": requestID], in: nil, contentWorld: .defaultClient)
            }
        }
        try Task.checkCancellation()
        guard origin.absoluteString == MangaUrls.home, ContentTransport.allows(url) else { throw CancellationError() }
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
        init(origin: URL) {
            self.origin = origin
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            view = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            view.navigationDelegate = self
            view.load(URLRequest(url: origin))
        }
        func ready() async throws {
            for _ in 0..<200 {
                try Task.checkCancellation()
                if let failure { throw failure }
                if committed, view.url?.host == origin.host,
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
