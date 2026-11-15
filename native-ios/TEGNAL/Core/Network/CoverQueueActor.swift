import CryptoKit
import Foundation
import SwiftUI

/// Some comics websites, the keyed kind, block a network address that reads many works in a short
/// time. Filling a library reads every work that lacks information, so it reads from the other
/// connected websites when there are any, and asks first when there are none.
enum CoverFillGuard {
    /// Works filled without asking even from such a website: a few new saves.
    static let quietLimit = 10
    /// How long the fill waits after a work read from such a website.
    static let slowDelay: Duration = .seconds(3)

    /// What the person chose the last time they were asked, on this device.
    enum Decision: String { case none, declined, approved }
    enum Outcome: Equatable {
        case run
        /// Wait for the person: they chose not to fill from these websites.
        case hold
        /// Ask first: `pending` works would be read from `sites` alone.
        case ask(pending: Int, sites: [String])
    }

    /// Thrown for a work none of the other websites carry, left for the person to open themselves.
    struct LeftForBlockingSite: Error {}

    /// The websites known to block bulk reading, by digest of their domain, for the time before
    /// their protocol is learned (a members-only one shows signed-out visitors nothing to learn from).
    private static let domains: Set<String> = [
        "1b047e60dd887a4f010dc3ee0c3305b011d3ee6e40b8cd8d7a70c5fe74efc955",
        "3eb2fe8d6f00dba0f737d0c6996400f0b2bd7b989f0d2922dadaaca1f3dddfe6",
    ]

    static func blocksBulkReading(_ site: String, backend: MangaUrls.Backend?) -> Bool {
        if backend == .keyed { return true }
        let labels = BooruServer.bareHost(site).split(separator: ".")
        guard labels.count >= 2 else { return false }
        let domain = labels.suffix(2).joined(separator: ".")
        return domains.contains(SHA256.hash(data: Data(domain.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    static func blocksBulkReading(_ site: String) -> Bool { blocksBulkReading(site, backend: ComicSites.backend(of: site)) }

    /// The websites a fill skips: those that block bulk reading, while another website can be read.
    static func skipped(among sites: [String], blocks: (String) -> Bool = blocksBulkReading) -> Set<String> {
        let blocking = sites.filter(blocks)
        return blocking.count < sites.count ? Set(blocking) : []
    }

    private static let decisionKey = "manga.bulkFill.decision"
    private static let baselineKey = "manga.bulkFill.baseline"

    static func decision(in defaults: UserDefaults = ContentPreferences.defaults) -> (Decision, baseline: Int) {
        (Decision(rawValue: defaults.string(forKey: decisionKey) ?? "") ?? .none, defaults.integer(forKey: baselineKey))
    }

    /// Keeps the person's answer with the number of works waiting when they gave it.
    static func record(_ decision: Decision, pending: Int, in defaults: UserDefaults = ContentPreferences.defaults) {
        defaults.set(decision.rawValue, forKey: decisionKey)
        defaults.set(pending, forKey: baselineKey)
    }

    static func forget(in defaults: UserDefaults = ContentPreferences.defaults) {
        defaults.removeObject(forKey: decisionKey)
        defaults.removeObject(forKey: baselineKey)
    }

    /// Whether the fill may read now. A few works are read without asking; more are asked about,
    /// and asked about again when the person presses the fill button themselves or more works are
    /// waiting than when they last answered.
    static func outcome(sites: [String], blocks: (String) -> Bool = blocksBulkReading, pending: () -> Int, manual: Bool,
                        defaults: UserDefaults = ContentPreferences.defaults) -> Outcome {
        let blocking = sites.filter(blocks)
        guard !blocking.isEmpty, blocking.count == sites.count else { return .run }
        let waiting = pending()
        guard waiting > quietLimit else { return .run }
        var (decision, baseline) = decision(in: defaults)
        // Filled works lower the mark, so works saved afterwards are measured from what is left.
        if decision != .none, waiting < baseline {
            baseline = waiting
            record(decision, pending: baseline, in: defaults)
        }
        let grew = waiting > baseline + quietLimit
        switch decision {
        case .approved where !grew: return .run
        case .declined where !grew && !manual: return .hold
        default: return .ask(pending: waiting, sites: blocking)
        }
    }
}

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
    private let slowDelay: Duration
    /// Whether the last work was read from a website that blocks bulk reading, so the next waits longer.
    private var readFromBlockingSite = false
    private var checkedThumbnailFiles = false
    private var isRunning: Bool = false
    private var isPaused: Bool = false
    private var kickAgain: Bool = false

    public init(database: AppDatabase, thumbsDir: URL = AppStorage.thumbsDirURL) {
        self.database = database
        self.thumbsDir = thumbsDir
        // A saved work opens from whichever connected website still carries it, its own first.
        self.source = SiteFallbackContent.shared
        self.images = PageImageStore(source: SiteFallbackContent.shared)
        self.siteSource = { _ in nil }
        self.allowsBackfill = { CoverQueuePolicy.allowsBackfill }
        self.delay = .milliseconds(150)
        self.slowDelay = CoverFillGuard.slowDelay
    }

    init(database: AppDatabase, thumbsDir: URL, source: any ContentProviding,
         siteSource: @escaping @Sendable (String) -> (any ContentProviding)? = { _ in nil },
         allowsBackfill: @escaping @Sendable () -> Bool = { CoverQueuePolicy.allowsBackfill }, delay: Duration = .milliseconds(150),
         slowDelay: Duration = CoverFillGuard.slowDelay) {
        self.database = database; self.thumbsDir = thumbsDir; self.source = source; self.siteSource = siteSource
        self.images = PageImageStore(source: source)
        self.allowsBackfill = allowsBackfill; self.delay = delay; self.slowDelay = slowDelay
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    /// Queues every saved work so a fix in how a site is read reaches works saved before it.
    @discardableResult func queueRefresh() throws -> Int { try database.queueRefresh() }

    /// `mayRead` is asked before each batch: a run stops when works saved meanwhile would need
    /// the person's answer first.
    public func start(state: CoverQueueState, downloadsEnabled: Bool = true, mayRead: @escaping @Sendable () -> Bool = { true }) async {
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
            // A website that has stopped answering this device ends the run: reading on would only
            // keep it blocked for longer.
            var refused = false

            repeat {
                kickAgain = false
                while downloadsEnabled && !refused && !isPaused && !Task.isCancelled && allowsBackfill() && mayRead() {
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
                        } catch let error as ContentError where error == .temporarilyBlocked || error == .imageLimit {
                            refused = true
                            await MainActor.run { state.failed += 1; state.error = error.localizedDescription }
                            break
                        } catch {
                            await MainActor.run { state.failed += 1 }
                            if (try? database.getWork(galleryId: galleryId)?.hasThumb) != true {
                                try? database.setThumb(galleryId: galleryId, status: "failed")
                            }
                        }

                        let remaining = try database.countPendingFill()
                        await MainActor.run { state.remaining = remaining }
                        // Politeness delay, longer after a website that blocks bulk reading
                        do { try await Task.sleep(for: readFromBlockingSite ? slowDelay : delay) } catch { break }
                    }
                }
            } while downloadsEnabled && !refused && kickAgain && !isPaused && !Task.isCancelled && allowsBackfill() && mayRead()
        } catch {
            await MainActor.run { state.error = error.localizedDescription }
        }
        // Finish publishing before a replacement run can start. A detached
        // cleanup could previously mark a new run as stopped.
        isRunning = false
        await MainActor.run { state.isRunning = false }
    }

    public func fetchOne(_ galleryId: Int64, refresh: Bool = false) async throws {
        readFromBlockingSite = false
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
            if let fallback = source as? SiteFallbackContent {
                // Websites that block bulk reading are skipped while another website can be read;
                // with none, every read from them, answered or not, waits longer before the next.
                readFromBlockingSite = fallback.readsOnlyBlockingSites
                gallery = try await fallback.gallery(galleryId, preferring: existing?.site, inBulk: true)
            } else { gallery = try await source.gallery(galleryId) }
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
            type: gallery.type, tags: gallery.tags.joined(separator: ", "), metadataSource: "manga",
            pageCount: gallery.displayedPageCount
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
