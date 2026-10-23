import Foundation

public enum AppStorage {
    public static let appGroup = "group.work.nextline.tegnal"
    public static let iCloudContainerId = "iCloud.work.nextline.tegnal"
    public static let darwinNotificationName = "work.nextline.tegnal.share" as CFString

    private static let fallbackContainerURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tegnal", isDirectory: true)

    // macOS can return a group URL even when its directory does not exist or
    // the current signature has no access to it. Resolve once so both databases,
    // thumbnails and sync files use the same writable directory for this process.
    private static let containerResolution: Result<URL, Error> = Result {
        try resolveContainerURL(
            group: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
            fallback: fallbackContainerURL
        )
    }

    public static var sharedContainerURL: URL {
        (try? preparedContainerURL()) ?? fallbackContainerURL
    }

    static func preparedContainerURL() throws -> URL {
        try containerResolution.get()
    }

    static func resolveContainerURL(group: URL?, fallback: URL) throws -> URL {
        if let group {
            do { try prepareDirectory(group); return group }
            catch { /* Use app-local storage when the shared container is unavailable. */ }
        }
        try prepareDirectory(fallback)
        return fallback
    }

    private static func prepareDirectory(_ directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // A URL or isWritableFile alone does not establish sandbox write access.
        let probe = directory.appendingPathComponent(".storage-check-" + UUID().uuidString)
        defer { try? files.removeItem(at: probe) }
        try Data().write(to: probe, options: .withoutOverwriting)
    }

    public static var localDbURL: URL {
        sharedContainerURL.appendingPathComponent("memo.sqlite")
    }

    public static var thumbsDirURL: URL {
        let dir = sharedContainerURL.appendingPathComponent("thumbs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
        return dir
    }

    static func isReadableThumbnail(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    public static var pendingShareURL: URL {
        sharedContainerURL.appendingPathComponent("pending_share.json")
    }

    public static var foldersJSONURL: URL {
        sharedContainerURL.appendingPathComponent("folders.json")
    }

    /// Exclude item from iCloud backup (for cache/thumbs)
    public static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }
}

import UIKit
import ImageIO

/// Bounded, coalesced thumbnail decoding. View evaluation only reads memory;
/// ImageIO opens and downsamples files on the operation queue.
public final class LocalThumbnailCache: @unchecked Sendable {
    public static let shared = LocalThumbnailCache()
    static let didInvalidate = Notification.Name("localThumbnailCacheDidInvalidate")
    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private let decodeQueue: OperationQueue
    private struct Request {
        let id: UUID
        let operation: BlockOperation
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        var prefetched = false
    }
    private var pending: [String: Request] = [:]
    let maximumPixelSize: Int

    init(maximumPixelSize: Int = 768, decodeQueue: OperationQueue = OperationQueue()) {
        self.maximumPixelSize = max(1, maximumPixelSize)
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
        self.decodeQueue = decodeQueue
        decodeQueue.name = "work-thumbnail-decode"
        decodeQueue.qualityOfService = .userInitiated
        decodeQueue.maxConcurrentOperationCount = 2
    }

    /// A cache miss never opens a file on the caller's thread.
    public func image(forPath path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    public func load(forPath path: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        let waiterID = UUID()
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(path: path, waiterID: waiterID, waiter: continuation)
            }
        } onCancel: { cancelLoad(path: path, waiterID: waiterID) }
        return Task.isCancelled ? nil : image
    }

    private func enqueue(path: String, waiterID: UUID? = nil, waiter: CheckedContinuation<UIImage?, Never>? = nil) {
        lock.lock()
        // Check under the same lock used by cancellation so a cancellation
        // arriving before registration cannot leave an orphaned waiter.
        if waiter != nil && Task.isCancelled {
            lock.unlock(); waiter?.resume(returning: nil); return
        }
        if let image = cache.object(forKey: path as NSString) {
            lock.unlock()
            waiter?.resume(returning: image)
            return
        }
        if var request = pending[path] {
            if let waiter, let waiterID { request.waiters[waiterID] = waiter }
            else { request.prefetched = true }
            pending[path] = request
            lock.unlock()
            return
        }
        let requestID = UUID(), operation = BlockOperation()
        var request = Request(id: requestID, operation: operation, prefetched: waiter == nil)
        if let waiter, let waiterID { request.waiters[waiterID] = waiter }
        operation.addExecutionBlock { [self] in
            lock.lock()
            let active = pending[path]?.id == requestID
            lock.unlock()
            guard active else { return }
            let image = autoreleasepool { decode(path: path) }
            lock.lock()
            guard pending[path]?.id == requestID else { lock.unlock(); return }
            let waiters = pending.removeValue(forKey: path)?.waiters.values.map { $0 } ?? []
            if let image, let cgImage = image.cgImage {
                cache.setObject(image, forKey: path as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            }
            lock.unlock()
            for waiter in waiters { waiter.resume(returning: image) }
        }
        pending[path] = request
        lock.unlock()
        decodeQueue.addOperation(operation)
    }

    private func cancelLoad(path: String, waiterID: UUID) {
        lock.lock()
        guard var request = pending[path], let waiter = request.waiters.removeValue(forKey: waiterID) else {
            lock.unlock(); return
        }
        let orphaned = request.waiters.isEmpty && !request.prefetched
        if orphaned { pending.removeValue(forKey: path) }
        else { pending[path] = request }
        lock.unlock()
        // Cancelled queued operations never decode. If ImageIO has already
        // started, OperationQueue retains its physical slot until it returns.
        if orphaned { request.operation.cancel() }
        waiter.resume(returning: nil)
    }

    /// Allows cancellation tests to await registration without timing sleeps.
    func pendingConsumerCount(forPath path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending[path]?.waiters.count ?? 0
    }

    private func decode(path: String) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    public func invalidate(path: String) {
        lock.lock()
        cache.removeObject(forKey: path as NSString)
        let request = pending.removeValue(forKey: path)
        lock.unlock()
        request?.operation.cancel()
        for waiter in request?.waiters.values.map({ $0 }) ?? [] { waiter.resume(returning: nil) }
        NotificationCenter.default.post(name: Self.didInvalidate, object: self, userInfo: ["path": path])
    }

    public func prefetch(paths: [String]) {
        for path in Set(paths) { enqueue(path: path) }
    }

    public func clear() {
        lock.lock()
        cache.removeAllObjects()
        let requests = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for request in requests {
            request.operation.cancel()
            for waiter in request.waiters.values { waiter.resume(returning: nil) }
        }
        NotificationCenter.default.post(name: Self.didInvalidate, object: self)
    }
}
