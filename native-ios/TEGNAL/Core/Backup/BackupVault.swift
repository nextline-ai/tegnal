import Foundation

enum BackupPlace: String, Sendable, Hashable { case local, iCloud }

/// One backup file as a vault lists it, from its name and size alone.
struct BackupVaultFile: Equatable, Sendable {
    var name: String
    var size: Int64
    var place: BackupPlace
    /// Whether the file's bytes are on this device.
    var downloaded: Bool
    var downloading = false
}

/// A place backups are kept. The store shows every vault as one list.
@MainActor protocol BackupVault: AnyObject {
    var place: BackupPlace { get }
    func available() async -> Bool
    func list() async throws -> [BackupVaultFile]
    /// Moves a local file into the vault under `name`.
    func add(_ file: URL, name: String) async throws
    /// Copies a backup into `folder`, waiting for it to download first.
    func fetch(_ name: String, into folder: URL) async throws -> URL
    func delete(_ name: String) async throws
    /// The head of a backup already on this device; nil when it would need a download.
    func manifest(_ name: String) async -> BackupManifest?
}

/// A folder under Application Support, outside the data folder.
@MainActor final class LocalBackupVault: BackupVault {
    let place = BackupPlace.local
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func available() async -> Bool { true }

    func list() async throws -> [BackupVaultFile] {
        let folder = folder
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]).compactMap { url in
                guard BackupName(fileName: url.lastPathComponent) != nil else { return nil }
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return BackupVaultFile(name: url.lastPathComponent, size: size, place: .local, downloaded: true)
            }
        }.value
    }

    func add(_ file: URL, name: String) async throws {
        let destination = folder.appendingPathComponent(name), folder = folder
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard file.standardizedFileURL != destination.standardizedFileURL else { return }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: file, to: destination)
        }.value
    }

    func fetch(_ name: String, into target: URL) async throws -> URL {
        let source = folder.appendingPathComponent(name)
        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: source.path) else { throw BackupError.unavailable }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let copy = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: source, to: copy)
            return copy
        }.value
    }

    func delete(_ name: String) async throws {
        let file = folder.appendingPathComponent(name)
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }.value
    }

    func manifest(_ name: String) async -> BackupManifest? {
        let file = folder.appendingPathComponent(name)
        return await Task.detached(priority: .utility) { try? BackupArchive.open(file).manifest }.value
    }
}

/// `Documents/Backups/v1/` in the app's iCloud container, shared by every device of the account.
/// Like the library sync, the container is resolved off the main thread, a metadata query finds
/// files not downloaded yet, and every read and write is coordinated.
@MainActor final class CloudBackupVault: BackupVault {
    let place = BackupPlace.iCloud
    /// Called when iCloud reports files arriving or changing, so the list can be read again.
    var onChange: (() -> Void)?
    private let resolveContainer: @Sendable () async -> URL?
    private let query = NSMetadataQuery()
    private var queryStarted = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    /// How long a restore or export waits for a file to download.
    static let downloadTimeout: Duration = .seconds(120)

    init(resolveContainer: @escaping @Sendable () async -> URL? = {
        await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: AppStorage.iCloudContainerId)
        }.value
    }) {
        self.resolveContainer = resolveContainer
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "tegnal_*." + BackupName.fileExtension)
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange?() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.query.stop(); self?.queryStarted = false; self?.onChange?() }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// Signed in with iCloud Drive on: the folder; otherwise nil. Never a previously resolved path.
    private func root() async -> URL? {
        guard FileManager.default.ubiquityIdentityToken != nil, let container = await resolveContainer() else { return nil }
        return container.appendingPathComponent("Documents/Backups/v1", isDirectory: true)
    }

    func available() async -> Bool { await root() != nil }

    func list() async throws -> [BackupVaultFile] {
        guard let root = await root() else { return [] }
        if !queryStarted { queryStarted = query.start() }
        // The folder says which files exist; a file just deleted can linger in the query's results.
        // The query only adds what the folder cannot say about a file not downloaded yet.
        var details: [String: (size: Int64, downloading: Bool)] = [:]
        query.disableUpdates()
        for item in query.results.compactMap({ $0 as? NSMetadataItem }) {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { continue }
            details[url.lastPathComponent] = ((item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                                              item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false)
        }
        query.enableUpdates()
        let listed = try await Task.detached(priority: .utility) { try CloudBackupFiles.list(root) }.value
        return listed.map { file in
            var merged = file
            if let known = details[file.name] {
                if merged.size == 0 { merged.size = known.size }
                merged.downloading = merged.downloading || known.downloading
            }
            return merged
        }
    }

    func add(_ file: URL, name: String) async throws {
        guard let root = await root() else { throw BackupError.unavailable }
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let destination = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { try CloudBackupFiles.remove(destination) }
            try FileManager.default.setUbiquitous(true, itemAt: file, destinationURL: destination)
        }.value
    }

    func fetch(_ name: String, into folder: URL) async throws -> URL {
        guard let root = await root() else { throw BackupError.unavailable }
        let url = root.appendingPathComponent(name)
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: Self.downloadTimeout)
        while !(try await Task.detached(priority: .userInitiated) { try CloudBackupFiles.isDownloaded(url) }.value) {
            guard clock.now < deadline else { throw BackupError.notDownloaded }
            try await Task.sleep(for: .milliseconds(500))
        }
        return try await Task.detached(priority: .userInitiated) { try CloudBackupFiles.copy(url, into: folder) }.value
    }

    func delete(_ name: String) async throws {
        guard let root = await root() else { throw BackupError.unavailable }
        try await Task.detached(priority: .utility) { try CloudBackupFiles.remove(root.appendingPathComponent(name)) }.value
    }

    func manifest(_ name: String) async -> BackupManifest? {
        guard let root = await root() else { return nil }
        return await Task.detached(priority: .utility) { CloudBackupFiles.manifest(root.appendingPathComponent(name)) }.value
    }
}

/// Blocking coordination lives off the main thread.
enum CloudBackupFiles {
    static func list(_ root: URL) throws -> [BackupVaultFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey, .fileSizeKey]
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).compactMap { url in
            var name = url.lastPathComponent, placeholder = false
            // Older systems keep a file not downloaded yet as `.<name>.icloud`.
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)); placeholder = true }
            guard BackupName(fileName: name) != nil else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let status = values?.ubiquitousItemDownloadingStatus
            return BackupVaultFile(name: name, size: placeholder ? 0 : Int64(values?.fileSize ?? 0), place: .iCloud,
                                   downloaded: !placeholder && (status == nil || status == .current),
                                   downloading: values?.ubiquitousItemIsDownloading ?? false)
        }
    }

    /// Starts the download when the file is not on the device yet.
    static func isDownloaded(_ url: URL) throws -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        if !FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: placeholder.path) { throw BackupError.unavailable }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        if FileManager.default.fileExists(atPath: url.path), status == nil || status == .current { return true }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
    }

    static func copy(_ url: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try FileManager.default.copyItem(at: coordinated, to: copy) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get()
        return copy
    }

    /// Reads only the head, and only when the file is already downloaded.
    static func manifest(_ url: URL) -> BackupManifest? {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        guard FileManager.default.fileExists(atPath: url.path), status == nil || status == .current else { return nil }
        var manifest: BackupManifest?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { coordinated in
            manifest = try? BackupArchive.open(coordinated).manifest
        }
        return manifest
    }

    static func remove(_ url: URL) throws {
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { coordinated in
            result = Result { try FileManager.default.removeItem(at: coordinated) }
        }
        if let error { throw error }
        try result?.get()
    }
}
