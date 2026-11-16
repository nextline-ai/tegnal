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
    /// Where the files are: nil for the app's own storage (every download before 1.5.2), else a
    /// `DownloadLocation` key. `path` is the folder inside it; nil means the download's id.
    var location: String?
    var path: String?
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

/// A place downloads can be saved: the app's folder in the Files app, or a folder the person
/// chose, kept as a security-scoped bookmark.
struct DownloadLocation: Codable, Equatable, Identifiable {
    static let files = "files"
    var id: String
    var name: String
    var bookmark: Data?
    static let onDevice = DownloadLocation(id: files, name: "", bookmark: nil)
    var isFiles: Bool { id == Self.files }
}

private struct DownloadSettings: Codable {
    var current = DownloadLocation.files
    var folders: [DownloadLocation] = []
}

/// Durable downloads live outside the evictable viewer cache. One worker per mode
/// keeps large galleries from blocking image downloads or exhausting memory.
/// The record of downloads stays in the app's own storage; the files go to the chosen location,
/// in a folder named after the work, so the Files app and other apps can open them.
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
    /// The move to the current location in progress: how many are done of how many.
    private(set) var moving: (done: Int, total: Int)?
    private(set) var locationError: String?
    private var settings = DownloadSettings()
    private let directory: URL
    /// The app's Documents folder, which the Files app shows as the app's folder on the device.
    private let filesRoot: URL
    @ObservationIgnored private var resolvedFolders: [String: URL] = [:]
    private let manga: any ContentProviding
    private let booru: any BooruProviding
    @ObservationIgnored private var workers: [WorkDownload.Mode: Task<Void, Never>] = [:]
    @ObservationIgnored private var active: [WorkDownload.Mode: UUID] = [:]
    @ObservationIgnored private var suspended = false

    static let appDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")

    /// `filesRoot` defaults to Documents for the app's own store, and to a folder beside a test's
    /// directory otherwise, so tests never write into the Files app.
    init(directory: URL = DownloadStore.appDirectory, filesRoot: URL? = nil,
         manga: any ContentProviding = SiteFallbackContent.shared, booru: any BooruProviding = BooruClient.shared) {
        self.directory = directory; self.manga = manga; self.booru = booru
        self.filesRoot = filesRoot ?? (directory == Self.appDirectory
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            : directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-files"))
        let settingsFile = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsFile), let saved = try? JSONDecoder().decode(DownloadSettings.self, from: data) { settings = saved }
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
                    let files = urls(item)
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
        var item = item
        place(&item)
        items.insert(item, at: 0)
        if persist() { schedule(item.mode) }
        return item.id
    }
    func folder(_ item: WorkDownload) -> URL {
        (root(item.location) ?? directory).appendingPathComponent(item.path ?? item.id.uuidString, isDirectory: true)
    }
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
    // MARK: - Location

    var locations: [DownloadLocation] { [.onDevice] + settings.folders }
    var currentLocation: DownloadLocation { locations.first { $0.id == settings.current } ?? .onDevice }
    /// Downloads saved somewhere other than the current location, which a move can bring over.
    var elsewhere: [WorkDownload] { items.filter { $0.location != settings.current } }
    /// The ones a move takes now: everything elsewhere except running downloads.
    var movable: [WorkDownload] { elsewhere.filter { ![.queued, .downloading].contains($0.status) } }
    var isDownloading: Bool { items.contains { [.queued, .downloading].contains($0.status) } }
    /// The Files app's address of the app's own folder, to open it there.
    var filesAppURL: URL? { URL(string: "shareddocuments://" + filesRoot.path) }

    func root(_ location: String?) -> URL? {
        guard let location else { return directory }
        if location == DownloadLocation.files { return filesRoot }
        if let url = resolvedFolders[location] { return url }
        guard let saved = settings.folders.first(where: { $0.id == location }), let bookmark = saved.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        // Access stays open while the app runs, as downloads and the offline reader use it at any time.
        _ = url.startAccessingSecurityScopedResource()
        if stale, let index = settings.folders.firstIndex(where: { $0.id == location }),
           let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            settings.folders[index].bookmark = fresh
            saveSettings()
        }
        resolvedFolders[location] = url
        return url
    }

    func setLocation(_ id: String) {
        guard locations.contains(where: { $0.id == id }) else { return }
        settings.current = id
        locationError = nil
        saveSettings()
    }

    /// Adds a folder picked in the document picker and saves new downloads there.
    func addFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let probe = url.appendingPathComponent(".tegnal-\(UUID().uuidString)")
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if let known = settings.folders.first(where: { root($0.id)?.standardizedFileURL == url.standardizedFileURL }) {
                settings.current = known.id
            } else {
                let location = DownloadLocation(id: "folder:" + UUID().uuidString, name: url.lastPathComponent, bookmark: bookmark)
                settings.folders.append(location)
                settings.current = location.id
            }
            locationError = nil
            saveSettings()
        } catch { locationError = error.localizedDescription }
    }

    /// Forgets a chosen folder. Downloads saved there stay listed only while it can still be opened.
    func removeFolder(_ id: String) {
        guard id != DownloadLocation.files, !items.contains(where: { $0.location == id }) else { return }
        settings.folders.removeAll { $0.id == id }
        if settings.current == id { settings.current = DownloadLocation.files }
        if let url = resolvedFolders.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        saveSettings()
    }

    private func saveSettings() {
        do { try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"), options: .atomic) }
        catch { locationError = error.localizedDescription }
    }

    /// Gives a new download a folder named after the work in the current location.
    private func place(_ item: inout WorkDownload) {
        guard let root = root(settings.current) else { item.location = nil; item.path = nil; return }
        let group = L10n.text(item.mode == .manga ? "Comics" : "Images")
        let name: String
        if let gallery = item.gallery { name = "\(Self.fileName(gallery.title, limit: 60)) [\(gallery.id)]" }
        else { name = Self.fileName(item.title, limit: 80) }
        let parent = root.appendingPathComponent(group, isDirectory: true)
        var candidate = name, number = 2
        let taken = Set(items.filter { $0.location == settings.current }.compactMap(\.path))
        while taken.contains(group + "/" + candidate) || FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
            candidate = "\(name) (\(number))"; number += 1
        }
        item.location = settings.current
        item.path = group + "/" + candidate
    }

    /// A name the file system and the Files app accept: no slashes or colons, no leading dot.
    static func fileName(_ text: String, limit: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = String(text.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > limit { name = String(name.prefix(limit)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Download" : name
    }

    /// Makes the folder that holds a download's folder. Mode folders in the Files app are left out
    /// of device backups, as downloads can be fetched again.
    private func prepareParent(of item: WorkDownload) throws {
        var parent = folder(item).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard item.location == DownloadLocation.files else { return }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? parent.setResourceValues(values)
    }

    /// Moves downloads saved elsewhere, including the app's own storage, into the current location
    /// without downloading them again. Running downloads are left where they are.
    func moveElsewhereHere() async {
        let targets = movable.map(\.id)
        guard moving == nil, !targets.isEmpty else { return }
        moving = (0, targets.count)
        locationError = nil
        for (done, id) in targets.enumerated() {
            moving = (done, targets.count)
            await Task.yield()
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let source = folder(items[index])
            var moved = items[index]
            place(&moved)
            let destination = folder(moved)
            do {
                if FileManager.default.fileExists(atPath: source.path) {
                    try prepareParent(of: moved)
                    try await Task.detached(priority: .userInitiated) { try FileManager.default.moveItem(at: source, to: destination) }.value
                }
                guard let current = items.firstIndex(where: { $0.id == id }) else { continue }
                items[current].location = moved.location
                items[current].path = moved.path
                persist()
            } catch {
                locationError = error.localizedDescription
                break
            }
        }
        moving = nil
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
            // Not started yet: it goes wherever downloads are saved now.
            if item.files.isEmpty, item.location != settings.current, !FileManager.default.fileExists(atPath: folder(item).path) {
                var placed = item
                place(&placed)
                try update(item.id) { $0.location = placed.location; $0.path = placed.path }
            }
            try update(item.id) { $0.status = .downloading; $0.error = nil }
            guard let current = items.first(where: { $0.id == item.id }) else { throw CancellationError() }
            let item = current
            try prepareParent(of: item)
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
