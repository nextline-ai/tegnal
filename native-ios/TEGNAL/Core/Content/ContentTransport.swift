import Foundation
import WebKit

/// Bounded chunked downloads. The delegate rejects foreign redirects before following them.
final class ContentTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ContentTransport()
    typealias BrowserFetch = @Sendable (URL, URL, Int, Range<Int>?, TimeInterval) async throws -> (Data, HTTPURLResponse)
    private let browserFetch: BrowserFetch
    private var session: URLSession!
    private let lock = NSLock()
    private var requests: [Int: Download] = [:]
    private var browserOrigins = Set<String>()

    private final class Download {
        let limit: Int
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var response: HTTPURLResponse?
        var data = Data()
        init(limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.limit = limit
            self.continuation = continuation
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func attach(_ task: URLSessionTask) {
            lock.withLock { self.task = task; if cancelled { task.cancel() } }
        }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }

    init(configuration: URLSessionConfiguration = .ephemeral,
         browserFetch: @escaping BrowserFetch = { url, origin, limit, range, timeout in
             try await ContentBrowserTransport.get(url, origin: origin, limit: limit, range: range, timeout: timeout)
         }) {
        self.browserFetch = browserFetch
        super.init()
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let configured = MangaUrls.configuredHost
        guard !configured.isEmpty else { return false }
        if host == configured || host.hasSuffix("." + configured) { return true }
        let cdn = MangaUrls.cdnHost
        if !cdn.isEmpty && (host == cdn || host.hasSuffix("." + cdn)) { return true }
        let dataHost = MangaUrls.dataHost
        if !dataHost.isEmpty && (host == dataHost || host.hasSuffix("." + dataHost)) { return true }
        if MangaUrls.allowsMedia(host) { return true }
        return false
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }

    func get(_ url: URL, limit: Int, range: Range<Int>? = nil, galleryID: Int64? = nil, timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        guard Self.allows(url), limit > 0 else { throw URLError(.unsupportedURL) }
        let site = MangaUrls.home
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard MangaUrls.home == site else { throw CancellationError() }
            do {
                let result = try await getOnce(url, site: site, limit: limit, range: range, galleryID: galleryID, timeout: timeout)
                try Task.checkCancellation()
                guard MangaUrls.home == site else { throw CancellationError() }
                return result
            } catch {
                try Task.checkCancellation()
                guard MangaUrls.home == site else { throw CancellationError() }
                guard attempt < 2, Self.isTransient(error) else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
    }

    private func getOnce(_ url: URL, site: String, limit: Int, range: Range<Int>?, galleryID: Int64?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let usesBrowser = lock.withLock { browserOrigins.contains(site) }
        if usesBrowser, url.host == MangaUrls.configuredHost, let origin = URL(string: site) {
            return try await browserFetch(url, origin, limit, range, timeout)
        }
        do { return try await direct(url, limit: limit, range: range, galleryID: galleryID, timeout: timeout) }
        catch {
            try Task.checkCancellation()
            guard MangaUrls.home == site, let network = error as? URLError,
                  [.secureConnectionFailed, .networkConnectionLost].contains(network.code)
                    || (url.host == MangaUrls.configuredHost && [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(network.code)),
                  let origin = URL(string: site) else { throw error }
            let result = try await browserFetch(url, origin, limit, range, timeout)
            if url.host == origin.host { _ = lock.withLock { browserOrigins.insert(site) } }
            return result
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return [.secureConnectionFailed, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
                .contains(URLError.Code(rawValue: error.code))
        }
        return error.domain == WKError.errorDomain && error.code == WKError.webContentProcessTerminated.rawValue
    }

    private func direct(_ url: URL, limit: Int, range: Range<Int>?, galleryID: Int64?, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(galleryID.map { MangaUrls.readerUrl(for: $0) } ?? MangaUrls.home, forHTTPHeaderField: "Referer")
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let result: (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock { requests[task.taskIdentifier] = Download(limit: limit, continuation: continuation) }
                cancellation.attach(task)
                task.resume()
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    static func backendConnectionFailed(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(error.code)
    }

    /// Resolve once before the first data request, then reuse the site's saved
    /// endpoints. Refresh only when the saved endpoint actually stops responding.
    func getData(_ path: String, limit: Int, range: Range<Int>? = nil, galleryID: Int64? = nil) async throws -> (Data, HTTPURLResponse) {
        let site = MangaUrls.home
        guard !site.isEmpty else { throw URLError(.unsupportedURL) }
        await MangaUrls.resolveBackend(transport: self)
        try Task.checkCancellation()
        guard MangaUrls.home == site else { throw CancellationError() }
        let host = MangaUrls.dataHost
        guard let target = URL(string: MangaUrls.dataBaseURL + path) else { throw URLError(.badURL) }
        do { return try await get(target, limit: limit, range: range, galleryID: galleryID) }
        catch {
            try Task.checkCancellation()
            let connectionFailed = Self.backendConnectionFailed(error)
            let endpointRemoved: Bool
            if case ContentError.unavailable(let status) = error {
                endpointRemoved = [403, 404].contains(status) && (path == "gg.js" || path.hasSuffix(".nozomi") || path == "galleriesindex/version")
            } else { endpointRemoved = false }
            guard connectionFailed || endpointRemoved, MangaUrls.home == site else { throw error }
            if MangaUrls.dataHost == host { await MangaUrls.resolveBackend(transport: self, force: true) }
            try Task.checkCancellation()
            guard MangaUrls.home == site else { throw CancellationError() }
            guard MangaUrls.dataHost != host, let updated = URL(string: MangaUrls.dataBaseURL + path) else { throw error }
            return try await get(updated, limit: limit, range: range, galleryID: galleryID)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let download = lock.withLock({ requests[dataTask.taskIdentifier] }), let http = response as? HTTPURLResponse else {
            finish(dataTask, error: ContentError.invalidResponse); completionHandler(.cancel); return
        }
        guard [200, 206, 416].contains(http.statusCode) else {
            finish(dataTask, error: ContentError.unavailable(http.statusCode)); completionHandler(.cancel); return
        }
        download.response = http
        if http.statusCode == 416 { finish(dataTask); completionHandler(.cancel); return }
        guard response.expectedContentLength <= Int64(download.limit) else {
            finish(dataTask, error: ContentError.tooLarge); completionHandler(.cancel); return
        }
        download.data.reserveCapacity(min(download.limit, max(0, Int(response.expectedContentLength))))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = lock.withLock({ requests[dataTask.taskIdentifier] }) else { return }
        guard data.count <= download.limit - download.data.count else {
            finish(dataTask, error: ContentError.tooLarge); dataTask.cancel(); return
        }
        download.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(task, error: error) }

    // URLSession's delegate queue is serial; only dictionary registration/removal crosses queues.
    private func finish(_ task: URLSessionTask, error: Error? = nil) {
        guard let download = lock.withLock({ requests.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { download.continuation.resume(throwing: error) }
        else if let response = download.response { download.continuation.resume(returning: (download.data, response)) }
        else { download.continuation.resume(throwing: ContentError.invalidResponse) }
    }
}
