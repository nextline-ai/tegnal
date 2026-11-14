import Foundation
import SwiftUI

enum CoverQueuePolicy {
    static func allowsBackfill(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        guard !lowPowerMode else { return false }
        switch thermalState {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }
    static var allowsBackfill: Bool {
        allowsBackfill(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState)
    }
}

@Observable
public final class CoverQueueState: @unchecked Sendable {
    public var isRunning: Bool = false
    public var isPaused: Bool = false
    public var processed: Int = 0
    public var failed: Int = 0
    public var gone: Int = 0
    public var total: Int = 0
    public var remaining: Int = 0
    public var error: String?
    var heatWarningDismissed = false
    var showsHeatBanner: Bool { isRunning && total >= 100 && !heatWarningDismissed }

    public init() {}
}

public actor CoverQueueActor {
    private let database: AppDatabase
    private let thumbsDir: URL
    private let source: any ContentProviding
    private let images: PageImageStore
    /// Another connected website's reader, for a work saved from it: it may carry works the
    /// checked website lacks. Nil reads the work from the checked website.
    private let siteSource: @Sendable (String) -> (any ContentProviding)?
    private var siteImages: [String: PageImageStore] = [:]
    private let allowsBackfill: @Sendable () -> Bool
    private let delay: Duration
    private var checkedThumbnailFiles = false
    private var isRunning: Bool = false
    private var isPaused: Bool = false
    private var kickAgain: Bool = false

    public init(database: AppDatabase, thumbsDir: URL = AppStorage.thumbsDirURL) {
        self.database = database
        self.thumbsDir = thumbsDir
        self.source = MangaContentSource.shared
        self.images = PageImageStore(source: MangaContentSource.shared)
        self.siteSource = { site in
            guard site != ComicSites.active, ComicSites.all.contains(site) else { return nil }
            return SiteContent.for(site)
        }
        self.allowsBackfill = { CoverQueuePolicy.allowsBackfill }
        self.delay = .milliseconds(150)
    }

    init(database: AppDatabase, thumbsDir: URL, source: any ContentProviding,
         siteSource: @escaping @Sendable (String) -> (any ContentProviding)? = { _ in nil },
         allowsBackfill: @escaping @Sendable () -> Bool = { CoverQueuePolicy.allowsBackfill }, delay: Duration = .milliseconds(150)) {
        self.database = database; self.thumbsDir = thumbsDir; self.source = source; self.siteSource = siteSource
        self.images = PageImageStore(source: source)
        self.allowsBackfill = allowsBackfill; self.delay = delay
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    /// Queues every saved work so a fix in how a site is read reaches works saved before it.
    @discardableResult func queueRefresh() throws -> Int { try database.queueRefresh() }

    public func start(state: CoverQueueState, downloadsEnabled: Bool = true) async {
        isPaused = false
        if isRunning {
            kickAgain = true
            return
        }
        isRunning = true
        await MainActor.run {
            state.isRunning = true
            state.isPaused = false
            state.processed = 0
            state.failed = 0
            state.gone = 0
            state.error = nil
            if state.remaining == 0 { state.heatWarningDismissed = false }
            state.total = 0
            state.remaining = 0
        }

        do {
            if !checkedThumbnailFiles {
                try database.repairThumbnailReferences(in: thumbsDir)
                checkedThumbnailFiles = true
            }
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            let total = try database.countPendingFill()
            await MainActor.run { state.total = total; state.remaining = total; state.isRunning = downloadsEnabled && total > 0 }

            // Each work is tried once per run; a queued refresh that fails is tried again next run.
            var attempted = Set<Int64>()

            repeat {
                kickAgain = false
                while downloadsEnabled && !isPaused && !Task.isCancelled && allowsBackfill() {
                    let refresh = try database.worksAwaitingRefresh(limit: 6, exclude: attempted)
                    let batch = refresh.isEmpty ? try database.worksNeedingFill(limit: 6, exclude: attempted).map(\.galleryId) : refresh
                    if batch.isEmpty { break }
                    let planned = attempted.count + (try database.countPendingFill(exclude: attempted))
                    await MainActor.run { state.total = max(state.total, planned) }

                    for galleryId in batch {
                        if isPaused || Task.isCancelled || !allowsBackfill() { break }
                        let refreshes = !refresh.isEmpty
                        attempted.insert(galleryId)

                        do {
                            try await fetchOne(galleryId, refresh: refreshes)
                            // A removed bookmark is not a successfully filled work. Tags may stay
                            // empty only when the site itself lists none.
                            if let saved = try database.getWork(galleryId: galleryId) {
                                guard saved.hasThumb, saved.hasTitle,
                                      !(saved.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || saved.metadataSource == "manga" else { throw ContentError.invalidResponse }
                                await MainActor.run { state.processed += 1 }
                            }
                            if refreshes { try database.finishRefresh(galleryId: galleryId) }
                        } catch is CancellationError {
                            break
                        } catch let error as URLError where error.code == .cancelled {
                            break
                        } catch ContentError.galleryNotFound {
                            // The website no longer has the work: nothing more to read.
                            if refreshes { try? database.finishRefresh(galleryId: galleryId) }
                            await MainActor.run { state.gone += 1 }
                        } catch {
                            await MainActor.run { state.failed += 1 }
                            if (try? database.getWork(galleryId: galleryId)?.hasThumb) != true {
                                try? database.setThumb(galleryId: galleryId, status: "failed")
                            }
                        }

                        let remaining = try database.countPendingFill()
                        await MainActor.run { state.remaining = remaining }
                        // Politeness delay
                        do { try await Task.sleep(for: delay) } catch { break }
                    }
                }
            } while downloadsEnabled && kickAgain && !isPaused && !Task.isCancelled && allowsBackfill()
        } catch {
            await MainActor.run { state.error = error.localizedDescription }
        }
        // Finish publishing before a replacement run can start. A detached
        // cleanup could previously mark a new run as stopped.
        isRunning = false
        await MainActor.run { state.isRunning = false }
    }

    public func fetchOne(_ galleryId: Int64, refresh: Bool = false) async throws {
        try Task.checkCancellation()
        var existing = try database.getWork(galleryId: galleryId)

        // If title or tags are missing, check offline catalog first
        if existing == nil || !existing!.hasTitle || (existing?.tags ?? "").isEmpty {
            if let catalog = try database.getCatalog(galleryId: galleryId) {
                _ = try database.upsertWork(
                    galleryId: galleryId,
                    title: catalog.title,
                    artists: catalog.artists,
                    language: catalog.language,
                    type: catalog.type,
                    series: catalog.series,
                    groups: catalog.groups,
                    tags: catalog.tags,
                    publishedAt: catalog.published,
                    metadataSource: "catalog",
                    catalogMatched: true,
                    overwriteMetadata: false
                )
                existing = try database.getWork(galleryId: galleryId)
            }
        }

        let needTitle = existing == nil || !existing!.hasTitle
        let needCover = existing?.hasThumb != true
        let needTags = (existing?.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !refresh && !needTitle && !needCover && !needTags {
            if existing?.thumbStatus != "ready" {
                try database.setThumb(galleryId: galleryId, status: "ready", path: existing?.thumbPath)
            }
            return
        }

        let (source, images) = reader(for: existing?.site)
        let gallery: NativeGallery
        do {
            gallery = try await source.gallery(galleryId)
        } catch ContentError.unavailable(let status) where status == 404 || status == 410 {
            try Task.checkCancellation()
            // Only a missing gallery document means the work is gone. A 404
            // from an image/CDN request below remains a retryable failure.
            // A refresh keeps the cover the work already has.
            if !refresh { try database.setThumb(galleryId: galleryId, status: "gone") }
            throw ContentError.galleryNotFound
        }
        try Task.checkCancellation()
        guard try database.getWork(galleryId: galleryId) != nil else { return }
        _ = try database.upsertWork(
            galleryId: galleryId, title: needTitle || refresh ? gallery.title : nil,
            artists: gallery.artists.joined(separator: ", "), language: gallery.language,
            type: gallery.type, tags: gallery.tags.joined(separator: ", "), metadataSource: "manga"
        )
        if needCover {
            guard !gallery.pages.isEmpty else { throw ContentError.invalidResponse }
            let page = min(max(1, existing?.thumbPage ?? 1), gallery.pages.count)
            let image = try await images.load(gallery.pages[page - 1], galleryID: galleryId, thumbnail: true)
            try Task.checkCancellation()
            guard try database.getWork(galleryId: galleryId) != nil else { return }
            guard let data = image.jpegData(compressionQuality: 0.9) else { throw ContentError.unsupportedFormat }
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
            let file = thumbsDir.appendingPathComponent("native_\(galleryId).jpg")
            try data.write(to: file, options: .atomic)
            guard AppStorage.isReadableThumbnail(file) else { throw ContentError.unsupportedFormat }
            try database.setThumb(galleryId: galleryId, status: "ready", path: file.path, page: page)
        }
    }

    /// A work saved from another connected website is read there; one saved from the checked
    /// website, or from an unknown one, from the checked one.
    private func reader(for site: String?) -> (any ContentProviding, PageImageStore) {
        guard let site, let other = siteSource(site) else { return (source, images) }
        if let store = siteImages[site] { return (other, store) }
        let store = PageImageStore(source: other)
        siteImages[site] = store
        return (other, store)
    }
}
