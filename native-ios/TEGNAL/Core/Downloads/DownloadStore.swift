import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers

struct WorkDownload: Codable, Identifiable {
    enum Mode: String, Codable { case manga, booru }
    enum Status: String, Codable { case queued, downloading, paused, failed, completed }
    var id = UUID()
    var key: String
    var mode: Mode
    var title: String
    var origin: String
    var gallery: NativeGallery?
    var server: BooruServer?
    var post: BooruPost?
    var status: Status = .queued
    var files: [String] = []
    var bytes: Int64 = 0
    var error: String?
    var total: Int { gallery?.pages.count ?? 1 }
    var tags: [String] { gallery?.tags ?? post?.tags ?? [] }
    var artists: [String] { gallery?.artists ?? post?.artists ?? [] }

    /// Match every word across local metadata. Underscores and spaces are
    /// equivalent, so tags copied from a booru work with ordinary typing too.
    func matches(_ query: String) -> Bool {
        func normalized(_ text: String) -> String {
            text.replacingOccurrences(of: "_", with: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        let metadata = normalized(([title, origin, gallery?.language ?? "", gallery?.type ?? "",
                                    gallery.map { String($0.id) } ?? post.map { String($0.postID) } ?? ""] + tags + artists).joined(separator: " "))
        return normalized(query).split(whereSeparator: \.isWhitespace).allSatisfy { metadata.contains($0) }
    }

}

/// Durable downloads live outside the evictable viewer cache. One worker per mode
/// keeps large galleries from blocking image downloads or exhausting memory.
@MainActor @Observable final class DownloadStore {
    static let shared: DownloadStore = {
        #if DEBUG
        if ContentUITestSupport.enabled && !BooruUITestSupport.liveEnabled {
            return DownloadStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DownloadUITests/" + UUID().uuidString),
                                 manga: ContentUITestSupport.source, booru: BooruUITestSupport.source)
        }
        #endif
        return DownloadStore()
    }()
    private(set) var items: [WorkDownload] = []
    private(set) var storageError: String?
    private(set) var transferProgress: [UUID: Double] = [:]
    private let directory: URL
    private let manga: any ContentProviding
    private let booru: any BooruProviding
    @ObservationIgnored private var workers: [WorkDownload.Mode: Task<Void, Never>] = [:]
    @ObservationIgnored private var active: [WorkDownload.Mode: UUID] = [:]
    @ObservationIgnored private var suspended = false

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads"),
         manga: any ContentProviding = MangaContentSource.shared, booru: any BooruProviding = BooruClient.shared) {
        self.directory = directory; self.manga = manga; self.booru = booru
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var location = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            let manifest = directory.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                items = try JSONDecoder().decode([WorkDownload].self, from: Data(contentsOf: manifest))
                for index in items.indices {
                    let item = items[index]
                    let files = item.files.map { directory.appendingPathComponent(item.id.uuidString).appendingPathComponent($0) }
                    if [.queued, .downloading].contains(item.status) || (item.status == .completed &&
                        (item.files.count != item.total || files.contains { !FileManager.default.fileExists(atPath: $0.path) })) {
                        items[index].status = .paused
                    }
                }
            }
        } catch { storageError = error.localizedDescription }
    }

    @discardableResult func enqueue(_ gallery: NativeGallery) -> UUID {
        add(.init(key: "\(MangaUrls.configuredHost):\(gallery.id)", mode: .manga, title: gallery.title,
                  origin: MangaUrls.configuredHost, gallery: gallery))
    }
    @discardableResult func enqueue(_ post: BooruPost, server: BooruServer) -> UUID {
        add(.init(key: "\(server.canonicalAddress):\(post.postID)", mode: .booru,
                  title: "\(server.displayName) #\(post.postID)", origin: server.canonicalAddress, server: server, post: post))
    }
    private func add(_ item: WorkDownload) -> UUID {
        if let existing = items.first(where: { $0.mode == item.mode && $0.key == item.key }) { return existing.id }
        guard storageError == nil else { return item.id }
        items.insert(item, at: 0)
        if persist() { schedule(item.mode) }
        return item.id
    }
    func folder(_ item: WorkDownload) -> URL { directory.appendingPathComponent(item.id.uuidString) }
    func urls(_ item: WorkDownload) -> [URL] { item.files.map { folder(item).appendingPathComponent($0) } }
    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), [.queued, .downloading].contains(items[index].status) else { return }
        items[index].status = .paused
        if active[items[index].mode] == id { workers[items[index].mode]?.cancel() }
        persist()
    }
    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), [.failed, .paused].contains(items[index].status) else { return }
        items[index].status = .queued; items[index].error = nil
        if persist() { schedule(items[index].mode) }
    }
    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        pause(id)
        do {
            if FileManager.default.fileExists(atPath: folder(item).path) { try FileManager.default.removeItem(at: folder(item)) }
            items.removeAll { $0.id == id }; persist()
        } catch { storageError = error.localizedDescription }
    }
    func setBackground(_ background: Bool) {
        suspended = background
        if background {
            for item in items where [.queued, .downloading].contains(item.status) { pause(item.id) }
        }
    }
    @discardableResult private func persist() -> Bool {
        do {
            try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("downloads.json"), options: .atomic)
            storageError = nil; return true
        } catch { storageError = error.localizedDescription; return false }
    }
    private func schedule(_ mode: WorkDownload.Mode) {
        guard !suspended, workers[mode] == nil, let item = items.last(where: { $0.mode == mode && $0.status == .queued }) else { return }
        active[mode] = item.id
        workers[mode] = Task {
            await run(item)
            transferProgress[item.id] = nil
            workers[mode] = nil; active[mode] = nil
            schedule(mode)
        }
    }
    private func update(_ id: UUID, _ change: (inout WorkDownload) -> Void) throws {
        try Task.checkCancellation()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        change(&items[index])
        guard persist() else { throw CocoaError(.fileWriteUnknown) }
    }
    private func run(_ item: WorkDownload) async {
        do {
            try update(item.id) { $0.status = .downloading; $0.error = nil }
            try FileManager.default.createDirectory(at: folder(item), withIntermediateDirectories: true)
            if let gallery = item.gallery {
                // Do not silently resume a gallery against a different configured site.
                guard item.origin == MangaUrls.configuredHost else { throw ContentError.invalidResponse }
                for (index, page) in gallery.pages.enumerated() {
                    try Task.checkCancellation()
                    if index < item.files.count, FileManager.default.fileExists(atPath: urls(item)[index].path) { continue }
                    var requestPage = page
                    requestPage.index = index
                    let data = try await manga.image(requestPage, galleryID: gallery.id, thumbnail: false)
                    try Task.checkCancellation()
                    let ext = try Self.imageExtension(data)
                    try save(data, name: String(format: "%05d", index + 1) + "." + ext, item: item, index: index)
                    // Match the site's download pacing instead of flooding its CDN.
                    if index + 1 < gallery.pages.count { try await Task.sleep(for: .seconds(1)) }
                }
            } else if let server = item.server, let post = item.post {
                let resolved = post.fileURL == nil ? try await booru.details(server: server, post: post) : post
                try update(item.id) { $0.post = resolved }
                guard let url = resolved.fileURL, url.scheme == "https" else { throw BooruError.invalidResponse }
                do {
                    try await downloadMedia(url, server: server, post: resolved, item: item)
                } catch {
                    try Task.checkCancellation()
                    guard !resolved.isVideo, BooruWebTransport.hasSession(for: server) else { throw error }
                    let data = try await BooruWebTransport.imageData(url: url, server: server)
                    let ext = try Self.imageExtension(data)
                    try save(data, name: "\(post.postID).\(ext)", item: item, index: 0)
                }
            } else { throw ContentError.invalidResponse }
            try update(item.id) { $0.status = .completed }
        } catch {
            if !Task.isCancelled, let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].status = .failed; items[index].error = error.localizedDescription; persist()
            }
        }
    }
    private func save(_ data: Data, name: String, item: WorkDownload, index: Int) throws {
        try Task.checkCancellation()
        try data.write(to: folder(item).appendingPathComponent(name), options: .atomic)
        try update(item.id) {
            if index < $0.files.count { $0.files[index] = name } else { $0.files.append(name) }
            $0.bytes = Self.fileBytes(folder(item), names: $0.files)
        }
    }
    private static func fileBytes(_ folder: URL, names: [String]) -> Int64 {
        names.reduce(0) { $0 + Int64((try? folder.appendingPathComponent($1).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    static func imageExtension(_ data: Data) throws -> String {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
              let type = CGImageSourceGetType(image), let ext = UTType(type as String)?.preferredFilenameExtension else { throw ContentError.unsupportedFormat }
        return ext
    }
    private func downloadMedia(_ url: URL, server: BooruServer, post: BooruPost, item: WorkDownload) async throws {
        let config = URLSessionConfiguration.ephemeral
        let progress = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard self?.active[item.mode] == item.id else { return }
                self?.transferProgress[item.id] = fraction
            }
        }
        let session = URLSession(configuration: config, delegate: progress, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = await BooruBrowserSession.prepare(URLRequest(url: url), server: server)
        let (temporary, response) = try await session.download(for: request, delegate: progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw BooruError.invalidResponse }
        let ext: String
        if post.isVideo {
            guard response.mimeType?.hasPrefix("video/") == true else { throw BooruError.invalidResponse }
            ext = post.fileExtension.lowercased()
        } else {
            ext = try Self.imageExtension(Data(contentsOf: temporary, options: .mappedIfSafe))
        }
        let name = "\(post.postID).\(ext)"
        let destination = folder(item).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try update(item.id) { $0.files = [name]; $0.bytes = Self.fileBytes(folder(item), names: [name]) }
    }
}

/// Reads only durable local files; never falls back to the network or viewer cache.
struct DownloadedContentSource: ContentProviding {
    let item: WorkDownload
    let folder: URL
    func cachedGallery(_ id: Int64) -> NativeGallery? { item.gallery?.id == id ? item.gallery : nil }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        guard let gallery = cachedGallery(id) else { throw ContentError.galleryNotFound }
        return gallery
    }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        try Task.checkCancellation()
        guard let gallery = cachedGallery(galleryID), let index = gallery.pages.firstIndex(of: page), item.files.indices.contains(index) else { throw ContentError.invalidResponse }
        return try Data(contentsOf: folder.appendingPathComponent(item.files[index]), options: .mappedIfSafe)
    }
    func suggestions(for token: String) async throws -> [TagSuggestion] { [] }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch { GalleryBatch(ids: [], hasMore: false) }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    private let redirects = BooruRedirectPolicy(publicMedia: true)
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}
