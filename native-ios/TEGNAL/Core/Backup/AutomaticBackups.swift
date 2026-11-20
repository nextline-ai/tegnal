import Foundation
import GRDB
import Observation

/// What the Automatic Backups screen shows and does. Every vault is merged into one list.
@MainActor @Observable
final class AutomaticBackups {
    /// One backup, wherever it is kept.
    struct Item: Identifiable, Equatable, Sendable {
        /// The file name; the same backup in two vaults is one item.
        let id: String
        let kind: BackupKind
        let createdAt: Date
        /// The version that last wrote the data; nil when unknown (the update from a version without backups).
        let dataVersion: String?
        let dataBuild: String?
        /// The version that made the backup; read from the file once it is on this device, else nil.
        let appVersion: String?
        let appBuild: String?
        let size: Int64
        let deviceID: String
        /// The making device's name; read from the file once it is on this device, else nil.
        let deviceName: String?
        let isThisDevice: Bool
        /// Kept whatever the total size (the newest backups from before updates).
        let isProtected: Bool
        let places: Set<BackupPlace>
        let download: Download
    }
    enum Download: Equatable, Sendable {
        /// The file is on this device.
        case onDevice
        case downloading
        /// Only in iCloud; restoring or exporting downloads it first.
        case inCloud
    }

    /// Every backup, newest first.
    private(set) var items: [Item] = []
    /// All backups together, each counted once.
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// The size retention keeps all backups under.
    let limit = BackupRetention.limit
    /// Whether iCloud Drive can hold backups now.
    private(set) var iCloudAvailable = false
    /// Moves new backups to iCloud when on (the default). Independent of library sync.
    var keepInICloud: Bool {
        didSet {
            setup.markerDefaults.set(keepInICloud, forKey: UpdateBackup.keepInICloudKey)
            if keepInICloud { Task { try? await serial { await self.moveToCloud(); await self.reload() } } }
        }
    }
    /// The last backup that failed on its own (before an update, or a restore that rolled back).
    private(set) var lastFailure: BackupFailure?
    /// How the last restore went, from the launch that applied it, until dismissed. A restore that rolled
    /// back is reported here only, not in `lastFailure`.
    private(set) var lastRestore: BackupRestoreReport?
    /// A restore waiting for the app to be closed and opened again.
    private(set) var pendingRestore: PendingBackupRestore?
    /// Whether an action or background pass is running.
    var isWorking: Bool { running > 0 }

    @ObservationIgnored let setup: BackupSetup
    @ObservationIgnored private let local: LocalBackupVault
    @ObservationIgnored private let cloud: (any BackupVault)?
    @ObservationIgnored private let databases: () -> UpdateBackup.OpenDatabases
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var details: [String: BackupManifest] = [:]
    @ObservationIgnored private var reloadScheduled = false
    private var running = 0

    init(setup: BackupSetup, databases: @escaping () -> UpdateBackup.OpenDatabases, cloud: (any BackupVault)?) {
        self.setup = setup
        self.databases = databases
        self.local = LocalBackupVault(folder: setup.vault)
        self.cloud = cloud
        keepInICloud = setup.markerDefaults.object(forKey: UpdateBackup.keepInICloudKey) as? Bool ?? true
        lastFailure = UpdateBackup.lastFailure(setup)
        lastRestore = UpdateBackup.lastRestore(setup)
        pendingRestore = UpdateBackup.pendingRestore(setup)
        if let cloud = cloud as? CloudBackupVault {
            cloud.onChange = { [weak self] in self?.scheduleReload() }
        }
    }

    // MARK: Actions

    /// Packs what the launch step staged, moves backups to iCloud and applies retention. Runs after launch.
    func afterLaunch() async {
        try? await serial {
            let setup = self.setup
            let packed = await Task.detached(priority: .utility) { () -> [String] in
                var names: [String] = []
                for snapshot in UpdateBackup.stagedSnapshots(setup) {
                    do { names.append(try UpdateBackup.pack(snapshot, setup: setup).manifest.fileName) }
                    catch {
                        UpdateBackup.recordFailure(setup, message: error.localizedDescription)
                        // A snapshot that can never be packed would fail on every launch.
                        if error as? BackupError == .tooLarge { try? FileManager.default.removeItem(at: snapshot) }
                    }
                }
                // Files of a pass cut off earlier; a staged restore stays.
                try? FileManager.default.removeItem(at: setup.work)
                for folder in (try? FileManager.default.contentsOfDirectory(at: setup.restore, includingPropertiesForKeys: nil)) ?? []
                    where folder.lastPathComponent.hasPrefix("incoming-") { try? FileManager.default.removeItem(at: folder) }
                return names
            }.value
            self.lastFailure = UpdateBackup.lastFailure(setup)
            await self.moveToCloud()
            await self.applyRetention(keeping: Set(packed))
            await self.reload()
        }
    }

    /// Reads the list again and applies retention, as when the screen opens.
    func refresh() async {
        try? await serial {
            await self.applyRetention(keeping: [])
            await self.reload()
        }
    }

    /// Backs up the open databases now (kind `manual`).
    func backUpNow() async throws {
        try await serial {
            let name = try await self.backUp(.manual)
            await self.moveToCloud()
            await self.applyRetention(keeping: [name])
            await self.reload()
        }
    }

    /// Checks the backup, backs up the current data (kind `safety`) and stages the restore for the
    /// next launch. Nothing changes until then.
    func restore(_ item: Item) async throws {
        try await serial {
            let setup = self.setup
            let file = try await self.fetch(item)
            defer { try? FileManager.default.removeItem(at: file) }
            let (folder, manifest) = try await Task.detached(priority: .userInitiated) { try UpdateBackup.prepareRestore(file, setup: setup) }.value
            let safety: String
            do { safety = try await self.backUp(.safety) }
            catch {
                try? FileManager.default.removeItem(at: folder)
                throw BackupError.safetyBackupFailed
            }
            try await Task.detached(priority: .userInitiated) { try UpdateBackup.stageRestore(folder, manifest: manifest, setup: setup) }.value
            self.pendingRestore = UpdateBackup.pendingRestore(setup)
            await self.moveToCloud()
            await self.applyRetention(keeping: [safety, item.id])
            await self.reload()
        }
    }

    /// Drops the staged restore; the data stays as it is.
    func cancelPendingRestore() throws {
        try UpdateBackup.cancelPendingRestore(setup)
        pendingRestore = nil
    }

    /// Deletes the backup from every vault holding it, protected or not.
    func delete(_ item: Item) async throws {
        try await serial {
            try await self.local.delete(item.id)
            if item.places.contains(.iCloud) { try await self.cloud?.delete(item.id) }
            await self.reload()
        }
    }

    /// A local copy of the backup to share, downloading it first if needed.
    func export(_ item: Item) async throws -> URL {
        try await serial {
            let exports = FileManager.default.temporaryDirectory.appendingPathComponent("Backup Export", isDirectory: true)
            try? FileManager.default.removeItem(at: exports)
            let copy = try await self.fetch(item)
            let target = exports.appendingPathComponent(item.id)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: copy, to: target)
            return target
        }
    }

    /// Checks a backup file chosen by the person and adds it to the list.
    @discardableResult
    func importFile(_ url: URL) async throws -> Item? {
        try await serial {
            let setup = self.setup
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let (copy, manifest) = try await Task.detached(priority: .userInitiated) { () -> (URL, BackupManifest) in
                // Checked before copying: the file may be anything, of any size.
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= BackupContainer.fileLimit else { throw BackupError.tooLarge }
                let folder = setup.work.appendingPathComponent("import-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent("import." + BackupName.fileExtension)
                try FileManager.default.copyItem(at: url, to: copy)
                do {
                    let archive = try BackupArchive.open(copy)
                    guard archive.manifest.platform == setup.platform else { throw BackupError.otherPlatform }
                    try archive.checkHoldsLibraries()
                    // A date far ahead would make it the newest of its kind and take protection from real backups.
                    guard archive.manifest.createdAt <= setup.now().addingTimeInterval(24 * 3600) else { throw BackupError.damaged }
                    try archive.extract(to: nil)
                    return (copy, archive.manifest)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            }.value
            let name = manifest.fileName
            if !self.items.contains(where: { $0.id == name }) {
                try await self.local.add(copy, name: name)
                self.details[name] = manifest
            }
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            await self.moveToCloud()
            await self.applyRetention(keeping: [name])
            await self.reload()
            return self.items.first { $0.id == name }
        }
    }

    /// Hides the note about the last restore.
    func dismissRestoreReport() {
        setup.markerDefaults.removeObject(forKey: UpdateBackup.restoreReportKey)
        lastRestore = nil
    }

    /// Hides the failure note.
    func dismissFailure() {
        setup.markerDefaults.removeObject(forKey: UpdateBackup.failureKey)
        lastFailure = nil
    }

    // MARK: Work

    /// iCloud reports changes in bursts; one reload waits behind them instead of one per report,
    /// so they cannot pile up ahead of what the person asked for.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            reloadScheduled = false
            try? await serial { await self.reload() }
        }
    }

    /// One action at a time; each waits for the one before it.
    private func serial<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            self.running += 1
            defer { self.running -= 1 }
            return try await work()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    private func backUp(_ kind: BackupKind) async throws -> String {
        let setup = self.setup, databases = databases()
        return try await Task.detached(priority: .userInitiated) {
            let folder = try UpdateBackup.takeSnapshot(setup, kind: kind, dataVersion: setup.appVersion, dataBuild: setup.appBuild, databases: databases)
            let packed = try UpdateBackup.pack(folder, setup: setup)
            return packed.manifest.fileName
        }.value
    }

    private func fetch(_ item: Item) async throws -> URL {
        let folder = setup.work.appendingPathComponent("fetch-" + UUID().uuidString, isDirectory: true)
        if item.places.contains(.local) { return try await local.fetch(item.id, into: folder) }
        guard let cloud else { throw BackupError.unavailable }
        return try await cloud.fetch(item.id, into: folder)
    }

    /// Backups are written locally first and moved to iCloud when it is on and available.
    private func moveToCloud() async {
        guard keepInICloud, let cloud, await cloud.available() else { return }
        for file in (try? await local.list()) ?? [] {
            try? await cloud.add(local.folder.appendingPathComponent(file.name), name: file.name)
        }
    }

    private func files() async -> [BackupVaultFile] {
        let localFiles = (try? await local.list()) ?? []
        let cloudFiles = (try? await cloud?.list()) ?? []
        return localFiles + cloudFiles
    }

    private func applyRetention(keeping: Set<String>) async {
        let files = await files()
        let candidates = files.compactMap { file in
            BackupName(fileName: file.name).map { BackupRetention.Item(name: file.name, size: file.size, device: $0.deviceID, kind: $0.kind, date: $0.createdAt) }
        }
        for name in BackupRetention.expired(candidates, keeping: keeping) {
            for file in files where file.name == name {
                let vault: (any BackupVault)? = file.place == .local ? local : cloud
                try? await vault?.delete(name)
            }
        }
    }

    private func reload() async {
        iCloudAvailable = await cloud?.available() ?? false
        let files = await files()
        // Version and device name come from the file's head, read once for each file on this device.
        for file in files where file.downloaded && details[file.name] == nil {
            let vault: (any BackupVault)? = file.place == .local ? local : cloud
            details[file.name] = await vault?.manifest(file.name)
        }
        let byName = Dictionary(grouping: files, by: \.name)
        let protected = BackupRetention.protected(files.compactMap { file in
            BackupName(fileName: file.name).map { BackupRetention.Item(name: file.name, size: file.size, device: $0.deviceID, kind: $0.kind, date: $0.createdAt) }
        })
        items = byName.compactMap { name, copies -> Item? in
            guard let parsed = BackupName(fileName: name) else { return nil }
            let detail = details[name]
            let download: Download = copies.contains(where: \.downloaded) ? .onDevice : copies.contains(where: \.downloading) ? .downloading : .inCloud
            return Item(id: name, kind: parsed.kind, createdAt: parsed.createdAt, dataVersion: parsed.dataVersion, dataBuild: parsed.dataBuild,
                        appVersion: detail?.appVersion, appBuild: detail?.appBuild, size: copies.map(\.size).max() ?? 0,
                        deviceID: parsed.deviceID, deviceName: detail?.device.name, isThisDevice: parsed.deviceID == setup.device.id,
                        isProtected: protected.contains(name), places: Set(copies.map(\.place)), download: download)
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        lastFailure = UpdateBackup.lastFailure(setup)
        lastRestore = UpdateBackup.lastRestore(setup)
        pendingRestore = UpdateBackup.pendingRestore(setup)
    }
}
