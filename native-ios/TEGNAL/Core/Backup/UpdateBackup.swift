import Foundation
import GRDB
import UIKit

/// Where the backup engine reads and writes. Tests pass temporary folders and their own domains.
struct BackupSetup: Sendable {
    /// The folder holding `memo.sqlite` and `booru.sqlite`.
    var dataFolder: URL
    /// The engine's own folder: staging, the local vault, a pending restore. Outside the data folder.
    var root: URL
    /// Small files outside the data folder, by entry name.
    var files: [String: URL]
    /// Preferences domains, by entry name.
    var preferences: [String: String]
    /// The domain that keeps the `backup.*` keys.
    var markerDomain: String
    /// Which favorites sync keys live in each preferences entry.
    var favorites: [String: SiteFavoriteFolders.Keys] = [
        BackupEntry.standardPreferences: SiteFavoriteFolders.mangaKeys,
        BackupEntry.booruPreferences: SiteFavoriteFolders.booruKeys,
    ]
    var appVersion: String
    var appBuild: String
    var platform = "ios"
    var device: BackupManifest.Device
    var now: @Sendable () -> Date = { Date() }
    /// Called at each step of applying a restore; tests throw from it to cut the restore off there.
    var restoreFault: (@Sendable (RestoreStep) throws -> Void)?

    var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    var vault: URL { root.appendingPathComponent("Vault", isDirectory: true) }
    var work: URL { root.appendingPathComponent("Work", isDirectory: true) }
    var restore: URL { root.appendingPathComponent("Restore", isDirectory: true) }
    var markerDefaults: UserDefaults { Self.defaults(markerDomain) }

    static func defaults(_ domain: String) -> UserDefaults {
        domain == Bundle.main.bundleIdentifier ? .standard : UserDefaults(suiteName: domain) ?? .standard
    }

    /// The app's own folders and domains.
    @MainActor static func standard() -> BackupSetup {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let domain = Bundle.main.bundleIdentifier ?? "work.nextline.tegnal"
        return BackupSetup(
            dataFolder: AppStorage.sharedContainerURL,
            root: support.appendingPathComponent("Backups", isDirectory: true),
            files: [
                "files/gallery-keys": GalleryKeys.defaultFile,
                "files/work-missing-sites": WorkSiteMemory.defaultFile,
                "files/downloads.json": DownloadStore.manifestURL(in: DownloadStore.appDirectory),
                "files/downloads-settings.json": DownloadStore.settingsURL(in: DownloadStore.appDirectory),
                "files/generated-index.json": GenerationStore.indexURL(in: GenerationStore.defaultFolder),
            ],
            preferences: [BackupEntry.standardPreferences: domain, BackupEntry.booruPreferences: ReaderPreferences.booruDomain],
            markerDomain: domain,
            appVersion: UpdateBackup.bundleVersion, appBuild: UpdateBackup.bundleBuild,
            device: .init(id: UpdateBackup.deviceID(in: Self.defaults(domain)), name: UIDevice.current.name))
    }

    #if DEBUG
    /// Tests and previews never touch the installed app's data.
    @MainActor static func isolated() -> BackupSetup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tegnal-update-backup-isolated", isDirectory: true)
        let domain = "work.nextline.tegnal.update-backup-isolated"
        let files = root.appendingPathComponent("Files", isDirectory: true)
        return BackupSetup(
            dataFolder: root.appendingPathComponent("Data", isDirectory: true), root: root.appendingPathComponent("Backups", isDirectory: true),
            files: Dictionary(uniqueKeysWithValues: BackupEntry.fileEntries.map { ($0, files.appendingPathComponent(String($0.dropFirst(6)))) }),
            preferences: [BackupEntry.standardPreferences: domain, BackupEntry.booruPreferences: domain + ".booru"],
            markerDomain: domain, appVersion: UpdateBackup.bundleVersion, appBuild: UpdateBackup.bundleBuild,
            device: .init(id: UpdateBackup.deviceID(in: Self.defaults(domain)), name: UIDevice.current.name))
    }
    #endif
}

/// The last thing that went wrong with a backup made on its own, shown in the backups screen.
struct BackupFailure: Codable, Equatable, Sendable {
    var date: Date
    var message: String
    var appVersion: String
}

/// How the last restore went, written at the launch that applied it.
struct BackupRestoreReport: Codable, Equatable, Sendable {
    var date: Date
    var backup: String
    var succeeded: Bool
    var message: String?
}

/// A restore that waits for the next launch.
struct PendingBackupRestore: Codable, Equatable, Sendable {
    var name: String
    var id: String
    var kind: BackupKind
    var createdAt: Date
    var dataVersion: String?
    var stagedAt: Date
    /// Launches that started applying it; one cut off twice (by the watchdog, say) is given up.
    var attempts: Int?
}

/// The steps of applying a restore, in order.
enum RestoreStep: Equatable, Sendable {
    case movedAside(String)
    case copiedIn(String)
    case checked
    case wrotePreferences(String)
    case commit
}

/// The engine: snapshots, packing, the launch step and restore. Every function takes its folders
/// and domains from a `BackupSetup`.
enum UpdateBackup {
    static let lastVersionKey = "backup.lastRun.version"
    static let lastBuildKey = "backup.lastRun.build"
    static let deviceIDKey = "backup.deviceID"
    static let failureKey = "backup.lastFailure"
    static let restoreReportKey = "backup.lastRestore"
    static let keepInICloudKey = "backup.keepInICloud"
    /// Set by a restore; the library sync sends the restored library as the newest state.
    static let libraryReplacedKey = "backup.libraryReplacedAt"
    private static let pendingMarker = "pending.json"
    private static let snapshotInfo = "snapshot.json"

    static var bundleVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var bundleBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Never rolled back by a restore. Apple's own keys in the app's domain (languages, window and
    /// web view state) belong to the system.
    static func isKept(_ key: String) -> Bool {
        key.hasPrefix("backup.") || key.hasPrefix("privacy.")
            || ["icloud.installation", "icloud.librarySyncEnabled", "icloud.offReminderShown", "drive.librarySyncEnabled"].contains(key)
            || ["Apple", "NS", "com.apple.", "WebKit"].contains { key.hasPrefix($0) }
    }

    /// A short id naming this device in backup file names, made once.
    static func deviceID(in defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: deviceIDKey), !id.isEmpty { return id }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    // MARK: Versions

    static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    static func isNewer(version: String, build: String, than other: String, build otherBuild: String) -> Bool {
        var a = components(version), b = components(other)
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count); b += Array(repeating: 0, count: count - b.count)
        if a != b { return b.lexicographicallyPrecedes(a) }
        return (Int(build) ?? 0) > (Int(otherBuild) ?? 0)
    }

    /// `minor` when the first or second version number changed, or nothing says which version ran last.
    static func kind(from version: String?, to current: String) -> BackupKind {
        guard let version else { return .minor }
        let a = components(version) + [0, 0], b = components(current) + [0, 0]
        return a[0] != b[0] || a[1] != b[1] ? .minor : .patch
    }

    // MARK: Launch step

    /// The app's launch step. Tests and UI tests skip it unless `--update-backup-launch-test` asks,
    /// and then it works on throwaway folders.
    @MainActor static func launch() {
        #if DEBUG
        if ContentPreferences.isIsolated || ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled {
            if ProcessInfo.processInfo.arguments.contains("--update-backup-launch-test") { runAtLaunch(.isolated()) }
            return
        }
        #endif
        runAtLaunch(.standard())
    }

    struct LaunchReport: Equatable {
        /// The backup staged before the databases open, if any.
        var staged: BackupKind?
        /// The backup that should have been staged but could not be.
        var failed: BackupKind?
        /// Whether a pending restore was applied (true) or rolled back (false).
        var restored: Bool?
    }

    /// Runs before anything opens a database or writes preferences: copies the data the previous
    /// version left when the version changed, then applies a pending restore.
    @discardableResult
    static func runAtLaunch(_ setup: BackupSetup) -> LaunchReport {
        var report = LaunchReport()
        let defaults = setup.markerDefaults
        let lastVersion = defaults.string(forKey: lastVersionKey), lastBuild = defaults.string(forKey: lastBuildKey)
        if lastVersion != setup.appVersion || lastBuild != setup.appBuild {
            if hasData(setup) {
                let kind = kind(from: lastVersion, to: setup.appVersion)
                do {
                    try takeSnapshot(setup, kind: kind, dataVersion: lastVersion, dataBuild: lastVersion == nil ? nil : lastBuild)
                    report.staged = kind
                } catch {
                    report.failed = kind
                    recordFailure(setup, message: BackupError.snapshotFailed(error.localizedDescription).localizedDescription)
                }
            }
            // Written even after a failure: the next launch would otherwise label migrated data as the old version's.
            defaults.set(setup.appVersion, forKey: lastVersionKey)
            defaults.set(setup.appBuild, forKey: lastBuildKey)
        }
        if pendingRestore(setup) != nil {
            report.restored = applyPendingRestore(setup)
        } else {
            settleRestore(setup)
        }
        return report
    }

    static func hasData(_ setup: BackupSetup) -> Bool {
        BackupEntry.databases.contains { FileManager.default.fileExists(atPath: setup.dataFolder.appendingPathComponent($0).path) }
    }

    static func recordFailure(_ setup: BackupSetup, message: String) {
        let failure = BackupFailure(date: setup.now(), message: message, appVersion: setup.appVersion)
        setup.markerDefaults.set(try? JSONEncoder().encode(failure), forKey: failureKey)
    }

    static func lastFailure(_ setup: BackupSetup) -> BackupFailure? {
        setup.markerDefaults.data(forKey: failureKey).flatMap { try? JSONDecoder().decode(BackupFailure.self, from: $0) }
    }

    static func lastRestore(_ setup: BackupSetup) -> BackupRestoreReport? {
        setup.markerDefaults.data(forKey: restoreReportKey).flatMap { try? JSONDecoder().decode(BackupRestoreReport.self, from: $0) }
    }

    // MARK: Snapshots

    /// The open databases a consistent snapshot copies from.
    struct OpenDatabases {
        var memo: any DatabaseReader
        var booru: any DatabaseReader
    }

    /// Copies the data into a staging folder. Without `databases` the database files are copied as
    /// they are (nothing has them open yet); with them, SQLite's backup API copies each one whole.
    @discardableResult
    static func takeSnapshot(_ setup: BackupSetup, kind: BackupKind, dataVersion: String?, dataBuild: String?,
                             databases: OpenDatabases? = nil) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: setup.staging, withIntermediateDirectories: true)
        AppStorage.excludeFromBackup(setup.root)
        let id = UUID().uuidString
        // A folder without its info is unfinished; renaming it is the moment it becomes a snapshot.
        let partial = setup.staging.appendingPathComponent(id + ".partial", isDirectory: true)
        let folder = setup.staging.appendingPathComponent(id, isDirectory: true)
        try files.createDirectory(at: partial.appendingPathComponent("db"), withIntermediateDirectories: true)
        do {
            var counts: BackupManifest.Counts?
            if let databases {
                for (name, reader) in [("memo.sqlite", databases.memo), ("booru.sqlite", databases.booru)] {
                    let target = try DatabaseQueue(path: partial.appendingPathComponent("db/" + name).path)
                    try reader.backup(to: target)
                    try target.close()
                }
                let works = try? databases.memo.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM works") }
                let images = try? databases.booru.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM favorites") }
                counts = .init(works: (works ?? nil) ?? 0, images: (images ?? nil) ?? 0)
            } else {
                for entry in BackupEntry.databaseEntries {
                    let source = setup.dataFolder.appendingPathComponent(String(entry.dropFirst(3)))
                    if files.fileExists(atPath: source.path) { try files.copyItem(at: source, to: partial.appendingPathComponent(entry)) }
                }
            }
            try files.createDirectory(at: partial.appendingPathComponent("prefs"), withIntermediateDirectories: true)
            for (entry, domain) in setup.preferences {
                let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
                try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: partial.appendingPathComponent(entry))
            }
            try files.createDirectory(at: partial.appendingPathComponent("files"), withIntermediateDirectories: true)
            for (entry, source) in setup.files where files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: partial.appendingPathComponent(entry))
            }
            let info = BackupManifest(id: id, kind: kind, platform: setup.platform, createdAt: setup.now(), dataVersion: dataVersion, dataBuild: dataBuild,
                                      appVersion: setup.appVersion, appBuild: setup.appBuild, device: setup.device, counts: counts)
            try BackupManifest.encoder.encode(info).write(to: partial.appendingPathComponent(snapshotInfo), options: .atomic)
            try files.moveItem(at: partial, to: folder)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
        return folder
    }

    /// Finished snapshots waiting to be packed, oldest first. Unfinished ones are removed.
    static func stagedSnapshots(_ setup: BackupSetup) -> [URL] {
        let files = FileManager.default
        let folders = (try? files.contentsOfDirectory(at: setup.staging, includingPropertiesForKeys: nil)) ?? []
        var ready: [(URL, Date)] = []
        for folder in folders {
            let info = folder.appendingPathComponent(snapshotInfo)
            guard !folder.lastPathComponent.hasSuffix(".partial"), let data = try? Data(contentsOf: info),
                  let manifest = try? BackupManifest.decoder.decode(BackupManifest.self, from: data) else {
                try? files.removeItem(at: folder); continue
            }
            ready.append((folder, manifest.createdAt))
        }
        return ready.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Packs a staged snapshot into the local vault and removes it from staging.
    static func pack(_ snapshot: URL, setup: BackupSetup) throws -> (url: URL, manifest: BackupManifest) {
        var info = try BackupManifest.decoder.decode(BackupManifest.self, from: Data(contentsOf: snapshot.appendingPathComponent(snapshotInfo)))
        let files = FileManager.default
        try files.createDirectory(at: setup.vault, withIntermediateDirectories: true)
        // Two backups made in the same second would share a name.
        while files.fileExists(atPath: setup.vault.appendingPathComponent(info.fileName).path) {
            info.createdAt = info.createdAt.addingTimeInterval(1)
        }
        let destination = setup.vault.appendingPathComponent(info.fileName)
        let manifest = try BackupContainer.write(folder: snapshot, manifest: info, to: destination, work: setup.work)
        try? files.removeItem(at: snapshot)
        return (destination, manifest)
    }

    // MARK: Restore

    /// Reads a backup, checks it and unpacks it into a folder of its own, ready to stage.
    static func prepareRestore(_ file: URL, setup: BackupSetup) throws -> (folder: URL, manifest: BackupManifest) {
        let archive = try BackupArchive.open(file)
        try archive.checkRestorable(appVersion: setup.appVersion, appBuild: setup.appBuild, platform: setup.platform)
        let folder = setup.restore.appendingPathComponent("incoming-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try archive.extract(to: folder)
            try checkDatabases(in: folder.appendingPathComponent("db"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (folder, archive.manifest)
    }

    /// Each database opens, passes `quick_check`, and lists only migrations this app knows.
    static func checkDatabases(in folder: URL) throws {
        for name in BackupEntry.databases {
            let path = folder.appendingPathComponent(name).path
            // A restore replaces both libraries; one without a library would empty it.
            guard FileManager.default.fileExists(atPath: path) else { throw BackupError.damaged }
            let superseded: Bool
            do {
                let queue = try DatabaseQueue(path: path)
                defer { try? queue.close() }
                superseded = try queue.read { db -> Bool in
                    guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else { throw BackupError.databaseUnreadable }
                    return try (name == "memo.sqlite" ? AppDatabase.migrator : BooruStore.migrator).hasBeenSuperseded(db)
                }
            } catch { throw BackupError.databaseUnreadable }
            if superseded { throw BackupError.newerApp }
        }
    }

    /// Opens the restored files the way the app is about to, migrations included, and closes them again.
    /// A file that passes `quick_check` can still fail here, and the app would then stop at every launch.
    private static func openAsTheApp(_ folder: URL) throws {
        do {
            let memo = try AppDatabase.open(at: folder.appendingPathComponent("memo.sqlite").path)
            try memo.dbWriter.close()
            let booru = try BooruStore(path: folder.appendingPathComponent("booru.sqlite").path)
            try booru.database.close()
        } catch { throw BackupError.databaseUnreadable }
    }

    /// Moves a prepared folder into place and writes the marker the next launch looks for.
    static func stageRestore(_ folder: URL, manifest: BackupManifest, setup: BackupSetup) throws {
        let files = FileManager.default
        settleCommitted(setup)
        try cancelPendingRestore(setup)
        try files.moveItem(at: folder, to: setup.restore.appendingPathComponent("pending", isDirectory: true))
        let pending = PendingBackupRestore(name: manifest.fileName, id: manifest.id, kind: manifest.kind, createdAt: manifest.createdAt,
                                           dataVersion: manifest.dataVersion, stagedAt: setup.now())
        try BackupManifest.encoder.encode(pending).write(to: setup.restore.appendingPathComponent(pendingMarker), options: .atomic)
    }

    static func pendingRestore(_ setup: BackupSetup) -> PendingBackupRestore? {
        (try? Data(contentsOf: setup.restore.appendingPathComponent(pendingMarker)))
            .flatMap { try? BackupManifest.decoder.decode(PendingBackupRestore.self, from: $0) }
    }

    static func cancelPendingRestore(_ setup: BackupSetup) throws {
        let files = FileManager.default
        let marker = setup.restore.appendingPathComponent(pendingMarker)
        if files.fileExists(atPath: marker.path) { try files.removeItem(at: marker) }
        let folder = setup.restore.appendingPathComponent("pending", isDirectory: true)
        if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
    }

    #if DEBUG
    /// Thrown by a test's fault to stand for the app being killed at that step: nothing is cleaned up.
    struct SimulatedTermination: Error {}
    #endif

    /// Puts a staged backup in place. Everything from moving the current files aside to the commit is
    /// one unit: any failure, here or at a later launch, puts the previous databases and preferences
    /// back, so a restore can never leave the app unable to start. Returns whether the backup is in place.
    static func applyPendingRestore(_ setup: BackupSetup) -> Bool {
        guard var pending = pendingRestore(setup) else { return false }
        let files = FileManager.default
        let staged = setup.restore.appendingPathComponent("pending", isDirectory: true)
        let previous = setup.restore.appendingPathComponent("previous", isDirectory: true)
        settleCommitted(setup)
        do {
            // A launch that keeps being cut off (the watchdog, say) must not try for ever.
            let attempts = pending.attempts ?? 0
            guard attempts < 2 else { throw BackupError.databaseUnreadable }
            pending.attempts = attempts + 1
            try BackupManifest.encoder.encode(pending).write(to: setup.restore.appendingPathComponent(pendingMarker), options: .atomic)
            // An earlier launch stopped halfway: start again from the data as it was.
            if files.fileExists(atPath: previous.path) { try rollBack(setup, previous: previous) }
            guard BackupEntry.databases.allSatisfy({ files.fileExists(atPath: staged.appendingPathComponent("db/" + $0).path) }) else {
                throw BackupError.damaged
            }
            try files.createDirectory(at: previous.appendingPathComponent("prefs"), withIntermediateDirectories: true)
            for (entry, domain) in setup.preferences {
                let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
                try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                    .write(to: previous.appendingPathComponent(entry), options: .atomic)
            }
            // Which files each database had, written before any of them moves.
            var present: [String: [String]] = [:]
            for name in BackupEntry.databases {
                present[name] = BackupEntry.databaseSuffixes.map { name + $0 }.filter { files.fileExists(atPath: setup.dataFolder.appendingPathComponent($0).path) }
            }
            try JSONEncoder().encode(present).write(to: previous.appendingPathComponent(movedRecord), options: .atomic)
            for name in BackupEntry.databases {
                // The main file moves last: once it is aside, every file of that database is.
                for file in (present[name] ?? []).sorted(by: { ($0 == name ? 1 : 0, $0) < ($1 == name ? 1 : 0, $1) }) {
                    try files.moveItem(at: setup.dataFolder.appendingPathComponent(file), to: previous.appendingPathComponent(file))
                }
                try setup.restoreFault?(.movedAside(name))
            }
            for name in BackupEntry.databases {
                for file in BackupEntry.databaseSuffixes.map({ name + $0 }) where files.fileExists(atPath: staged.appendingPathComponent("db/" + file).path) {
                    try files.copyItem(at: staged.appendingPathComponent("db/" + file), to: setup.dataFolder.appendingPathComponent(file))
                }
                try setup.restoreFault?(.copiedIn(name))
            }
            try checkDatabases(in: setup.dataFolder)
            keepTasteDevice(from: previous, in: setup.dataFolder)
            try openAsTheApp(setup.dataFolder)
            try setup.restoreFault?(.checked)
            try applyPreferences(from: staged, setup: setup)
            var written: [String] = []
            for (entry, destination) in setup.files.sorted(by: { $0.key < $1.key }) {
                let source = staged.appendingPathComponent(entry)
                guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path) else { continue }
                written.append(destination.path)
                try JSONEncoder().encode(written).write(to: previous.appendingPathComponent(writtenRecord), options: .atomic)
                try? files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? files.copyItem(at: source, to: destination)
            }
            // Library sync off now would make this a stale stamp later; its ordinary capture handles the restore then.
            if setup.markerDefaults.object(forKey: LibraryCloudSync.enabledKey) as? Bool ?? true {
                setup.markerDefaults.set(setup.now().timeIntervalSince1970, forKey: libraryReplacedKey)
            }
            try setup.restoreFault?(.commit)
            // The commit: from here the restore counts as done, and the old files may go.
            try files.moveItem(at: setup.restore.appendingPathComponent(pendingMarker), to: setup.restore.appendingPathComponent(committedMarker))
        } catch {
            #if DEBUG
            if error is SimulatedTermination { return false }
            #endif
            // A rollback that fails leaves the files aside; the next launch tries it again.
            if files.fileExists(atPath: previous.path) { try? rollBack(setup, previous: previous) }
            let message = (error as? BackupError ?? .databaseUnreadable).localizedDescription
            report(setup, .init(date: setup.now(), backup: pending.name, succeeded: false, message: message))
            try? cancelPendingRestore(setup)
            return false
        }
        report(setup, .init(date: setup.now(), backup: pending.name, succeeded: true))
        settleCommitted(setup)
        return true
    }

    private static let committedMarker = "committed.json"
    private static let movedRecord = "moved.json"
    private static let writtenRecord = "written.json"

    /// A committed restore's leftovers go; files aside from one that never committed go back.
    private static func settleRestore(_ setup: BackupSetup) {
        settleCommitted(setup)
        let previous = setup.restore.appendingPathComponent("previous", isDirectory: true)
        if FileManager.default.fileExists(atPath: previous.path) { try? rollBack(setup, previous: previous) }
        try? FileManager.default.removeItem(at: setup.restore.appendingPathComponent("pending", isDirectory: true))
    }

    private static func settleCommitted(_ setup: BackupSetup) {
        let files = FileManager.default
        let committed = setup.restore.appendingPathComponent(committedMarker)
        guard files.fileExists(atPath: committed.path) else { return }
        try? files.removeItem(at: setup.restore.appendingPathComponent("previous", isDirectory: true))
        if pendingRestore(setup) == nil { try? files.removeItem(at: setup.restore.appendingPathComponent("pending", isDirectory: true)) }
        try? files.removeItem(at: committed)
    }

    private static func report(_ setup: BackupSetup, _ report: BackupRestoreReport) {
        setup.markerDefaults.set(try? JSONEncoder().encode(report), forKey: restoreReportKey)
    }

    /// Puts back what an unfinished restore moved aside. Each database is a unit: only one whose main
    /// file is aside has its live files replaced; one still in place is left alone.
    private static func rollBack(_ setup: BackupSetup, previous: URL) throws {
        let files = FileManager.default
        if let data = try? Data(contentsOf: previous.appendingPathComponent(movedRecord)),
           let present = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for name in BackupEntry.databases {
                let siblings = BackupEntry.databaseSuffixes.map { name + $0 }
                let original = present[name] ?? []
                let mainAside = files.fileExists(atPath: previous.appendingPathComponent(name).path)
                // With its main file aside, or with none to begin with, every live file of the database is the restore's.
                if mainAside || original.isEmpty {
                    for file in siblings where files.fileExists(atPath: setup.dataFolder.appendingPathComponent(file).path) {
                        try files.removeItem(at: setup.dataFolder.appendingPathComponent(file))
                    }
                }
                for file in siblings where files.fileExists(atPath: previous.appendingPathComponent(file).path) {
                    guard !files.fileExists(atPath: setup.dataFolder.appendingPathComponent(file).path) else { continue }
                    try files.moveItem(at: previous.appendingPathComponent(file), to: setup.dataFolder.appendingPathComponent(file))
                }
            }
        }
        if let data = try? Data(contentsOf: previous.appendingPathComponent(writtenRecord)),
           let written = try? JSONDecoder().decode([String].self, from: data) {
            for path in written { try? files.removeItem(atPath: path) }
        }
        for (entry, domain) in setup.preferences {
            guard let data = try? Data(contentsOf: previous.appendingPathComponent(entry)),
                  let saved = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            var next = saved.filter { !isKept($0.key) }
            for (key, value) in current where isKept(key) { next[key] = value }
            next[libraryReplacedKey] = nil
            UserDefaults.standard.setPersistentDomain(next, forName: domain)
        }
        try files.removeItem(at: previous)
    }

    /// The backup's keys replace the current ones, except the kept keys. No favorites sync runs again
    /// until the person answers the first-sync choice; accounts declined before or now stay declined.
    private static func applyPreferences(from staged: URL, setup: BackupSetup) throws {
        for (entry, domain) in setup.preferences.sorted(by: { $0.key > $1.key }) {
            let file = staged.appendingPathComponent(entry)
            let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            // A backup without this domain leaves it as it is, but its favorites still wait to be asked.
            var restored = current
            if FileManager.default.fileExists(atPath: file.path) {
                guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
                    throw BackupError.damaged
                }
                restored = values
            }
            var next = restored.filter { !isKept($0.key) }
            for (key, value) in current where isKept(key) { next[key] = value }
            if let keys = setup.favorites[entry] { next = SiteFavoriteFolders.restoredPreferences(next, current: current, keys: keys) }
            UserDefaults.standard.setPersistentDomain(next, forName: domain)
            try setup.restoreFault?(.wrotePreferences(entry))
        }
    }

    /// Analysis history names the device that recorded it; a backup from another device keeps this one's name.
    private static func keepTasteDevice(from previous: URL, in folder: URL) {
        for name in BackupEntry.databases {
            let old = previous.appendingPathComponent(name).path, restored = folder.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: old), FileManager.default.fileExists(atPath: restored) else { continue }
            var readOnly = Configuration(); readOnly.readonly = true
            guard let source = try? DatabaseQueue(path: old, configuration: readOnly) else { continue }
            let device = try? source.read { db -> Data? in
                guard try db.tableExists("taste_meta") else { return nil }
                return try Data.fetchOne(db, sql: "SELECT value FROM taste_meta WHERE key = 'device'")
            }
            try? source.close()
            guard let device = device ?? nil, let target = try? DatabaseQueue(path: restored) else { continue }
            try? target.write { db in
                if try db.tableExists("taste_meta") { try db.execute(sql: "UPDATE taste_meta SET value = ? WHERE key = 'device'", arguments: [device]) }
            }
            try? target.close()
        }
    }
}
