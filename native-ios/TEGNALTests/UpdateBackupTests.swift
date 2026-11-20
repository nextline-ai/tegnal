import CryptoKit
import XCTest
import GRDB
@testable import TEGNAL

final class UpdateBackupTests: XCTestCase {
    private var roots: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        roots = []; suites = []
        super.tearDown()
    }

    // MARK: Container

    func testContainerRoundTripKeepsEveryByteAndStoresIncompressibleDataAsItIs() throws {
        let setup = makeSetup()
        let folder = try scratch(setup, "source")
        var random = SystemRandomNumberGenerator()
        let compressible = Data((0..<3_000_000).map { UInt8($0 % 7) })
        let noise = Data((0..<1_500_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        try write(compressible, folder, "db/memo.sqlite")
        try write(noise, folder, "db/booru.sqlite")
        try write(Data(), folder, "db/memo.sqlite-journal")
        try write(Data("keys".utf8), folder, "files/gallery-keys")
        try write(Data("ignored".utf8), folder, "notes.txt")
        let file = setup.vault.appendingPathComponent("round.tegnalbackup")
        let written = try BackupContainer.write(folder: folder, manifest: manifest(), to: file, work: setup.work)

        let archive = try BackupArchive.open(file)
        XCTAssertEqual(archive.manifest, written)
        XCTAssertEqual(archive.manifest.entries.map(\.name), ["db/memo.sqlite", "db/memo.sqlite-journal", "db/booru.sqlite", "files/gallery-keys"])
        XCTAssertEqual(archive.manifest.entries.first { $0.name == "db/memo.sqlite" }?.compression, "deflate")
        XCTAssertEqual(archive.manifest.entries.first { $0.name == "db/booru.sqlite" }?.compression, "none", "Data that does not shrink is stored as it is")
        XCTAssertEqual(archive.manifest.entries.first { $0.name == "files/gallery-keys" }?.policy, "ifMissing")
        let out = try scratch(setup, "out")
        try archive.extract(to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("db/memo.sqlite")), compressible)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("db/booru.sqlite")), noise)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("db/memo.sqlite-journal")), Data())
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("files/gallery-keys")), Data("keys".utf8))

        // The stored deflate stream is plain RFC 1951, as the Android app writes it.
        let raw = try Data(contentsOf: file)
        let entry = archive.manifest.entries[0]
        let start = Int(archive.bodyOffset)
        let inflated = try (raw.subdata(in: start..<start + Int(entry.storedSize)) as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(inflated, compressible)
        let json = try XCTUnwrap(String(data: raw.subdata(in: 13..<start), encoding: .utf8))
        XCTAssertTrue(json.contains("\"dataVersion\":null"), "An unknown data version is written as null")
        XCTAssertTrue(json.contains("\"createdAt\":\"2026-11-20T03:15:00Z\""))
    }

    func testDamagedOrForeignFilesAreRefused() throws {
        let setup = makeSetup()
        let folder = try scratch(setup, "source")
        var random = SystemRandomNumberGenerator()
        try write(Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) }), folder, "db/memo.sqlite")
        let file = setup.vault.appendingPathComponent("good.tegnalbackup")
        try BackupContainer.write(folder: folder, manifest: manifest(), to: file, work: setup.work)
        let good = try Data(contentsOf: file)

        var magic = good; magic[0] = UInt8(ascii: "X")
        XCTAssertThrowsError(try BackupArchive.open(save(magic, setup))) { XCTAssertEqual($0 as? BackupError, .notBackup) }

        var version = good; version[8] = 2
        XCTAssertThrowsError(try BackupArchive.open(save(version, setup))) { XCTAssertEqual($0 as? BackupError, .notBackup) }

        var flipped = good; flipped[flipped.count - 1] ^= 0xFF
        let opened = try BackupArchive.open(save(flipped, setup))
        XCTAssertThrowsError(try opened.extract(to: try scratch(setup, "flipped"))) { XCTAssertEqual($0 as? BackupError, .damaged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.root.appendingPathComponent("flipped/db/memo.sqlite").path),
                       "A file that fails its checksum is not left behind")

        XCTAssertThrowsError(try BackupArchive.open(save(good.dropLast(), setup))) { XCTAssertEqual($0 as? BackupError, .damaged) }
        XCTAssertThrowsError(try BackupArchive.open(save(good + Data([0]), setup))) { XCTAssertEqual($0 as? BackupError, .damaged) }

        var oversized = BackupContainer.magic
        oversized.append(1)
        withUnsafeBytes(of: UInt32(BackupContainer.manifestLimit + 1).bigEndian) { oversized.append(contentsOf: $0) }
        oversized.append(Data(count: BackupContainer.manifestLimit + 1))
        XCTAssertThrowsError(try BackupArchive.open(save(oversized, setup))) { XCTAssertEqual($0 as? BackupError, .notBackup) }

        var android = manifest(); android.platform = "android"
        let foreign = try container([("db/memo.sqlite", Data("x".utf8))], manifest: android, setup: setup)
        XCTAssertThrowsError(try BackupArchive.open(foreign).checkRestorable(appVersion: "1.6.0", appBuild: "47")) { XCTAssertEqual($0 as? BackupError, .otherPlatform) }
        XCTAssertThrowsError(try UpdateBackup.prepareRestore(foreign, setup: setup)) { XCTAssertEqual($0 as? BackupError, .otherPlatform) }

        var newer = manifest(); newer.appVersion = "1.10.0"
        let future = try container([("db/memo.sqlite", Data("x".utf8))], manifest: newer, setup: setup)
        XCTAssertThrowsError(try UpdateBackup.prepareRestore(future, setup: setup)) { XCTAssertEqual($0 as? BackupError, .newerApp) }
        var newerBuild = manifest(); newerBuild.appVersion = "1.6.0"; newerBuild.appBuild = "48"
        XCTAssertThrowsError(try BackupArchive.open(container([], manifest: newerBuild, setup: setup)).checkRestorable(appVersion: "1.6.0", appBuild: "47")) {
            XCTAssertEqual($0 as? BackupError, .newerApp)
        }
        var older = manifest(); older.appVersion = "1.5.1"; older.appBuild = "44"
        let libraries = [("db/memo.sqlite", Data("x".utf8)), ("db/booru.sqlite", Data("y".utf8))]
        XCTAssertNoThrow(try BackupArchive.open(container(libraries, manifest: older, setup: setup)).checkRestorable(appVersion: "1.6.0", appBuild: "47"))
    }

    func testUnknownEntryNamesAreCheckedButNeverWritten() throws {
        let setup = makeSetup()
        let file = try container([("../escape", Data("evil".utf8)), ("db/memo.sqlite", Data("library".utf8)), ("files/unknown", Data("?".utf8))],
                                 manifest: manifest(), setup: setup)
        let out = try scratch(setup, "deep/out")
        try BackupArchive.open(file).extract(to: out)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("db/memo.sqlite")), Data("library".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent("escape").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("files/unknown").path))

        // An unknown entry is still checked: a wrong checksum anywhere refuses the file.
        let bad = try container([("files/unknown", Data("?".utf8))], manifest: manifest(), setup: setup, corruptChecksum: true)
        XCTAssertThrowsError(try BackupArchive.open(bad).extract(to: nil)) { XCTAssertEqual($0 as? BackupError, .damaged) }
    }

    func testFileNamesEncodeAndDecode() throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000.75)
        let name = BackupName(kind: .minor, dataVersion: "1.5.1", dataBuild: "44", createdAt: date, deviceID: "a1b2c3d4")
        XCTAssertEqual(name.fileName, "tegnal_minor_1.5.1_44_20261118T110640Z_a1b2c3d4.tegnalbackup")
        XCTAssertEqual(BackupName(fileName: name.fileName), name)
        XCTAssertEqual(BackupName(fileName: name.fileName)?.createdAt, Date(timeIntervalSince1970: 1_795_000_000))

        let unknown = BackupName(kind: .minor, dataVersion: nil, dataBuild: nil, createdAt: date, deviceID: "a1b2c3d4")
        XCTAssertEqual(unknown.fileName, "tegnal_minor_0_0_20261118T110640Z_a1b2c3d4.tegnalbackup")
        let decoded = try XCTUnwrap(BackupName(fileName: unknown.fileName))
        XCTAssertNil(decoded.dataVersion); XCTAssertNil(decoded.dataBuild)

        let odd = BackupName(kind: .manual, dataVersion: "1.6_beta 2", dataBuild: "4/7", createdAt: date, deviceID: "dev_ice")
        XCTAssertEqual(odd.fileName, "tegnal_manual_1.6-beta-2_4-7_20261118T110640Z_dev-ice.tegnalbackup")
        XCTAssertEqual(BackupName(fileName: odd.fileName), odd)

        for invalid in ["tegnal_minor_1.5.1_44_20261118T110640Z_a1b2c3d4.zip", "tegnal_other_1_1_20261118T110640Z_a.tegnalbackup",
                        "tegnal_minor_1_1_2026-11-19_a.tegnalbackup", "tegnal_minor_1_1_20261118T110640Z_.tegnalbackup",
                        "other_minor_1_1_20261118T110640Z_a.tegnalbackup", "tegnal_minor_1_1_20261118T110640Z_a_b.tegnalbackup"] {
            XCTAssertNil(BackupName(fileName: invalid), invalid)
        }
    }

    // MARK: Retention

    func testRetentionDeletesNothingUnderTheLimit() {
        let items = (0..<10).map { item("m\($0)", .manual, day: $0, mb: 9) }
        XCTAssertEqual(BackupRetention.expired(items), [])
    }

    func testRetentionDeletesOldestUnprotectedFirst() {
        let items = [item("p1", .patch, day: 1, mb: 30), item("m2", .manual, day: 2, mb: 30), item("s3", .safety, day: 3, mb: 30),
                     item("m4", .manual, day: 4, mb: 30), item("p5", .patch, day: 5, mb: 30), item("min6", .minor, day: 6, mb: 30)]
        // 180 MB: only m2 is unprotected (the newest safety and manual backups are kept too), so it goes and the rest stays over.
        XCTAssertEqual(BackupRetention.expired(items), ["m2"])
        let more = items + [item("p7", .patch, day: 7, mb: 1)]
        XCTAssertEqual(BackupRetention.expired(more), ["p1", "m2"], "A third patch is no longer protected; oldest first")
    }

    func testRetentionKeepsProtectedBackupsEvenWhenTheyAloneExceedTheLimit() {
        let items = [item("p1", .patch, day: 1, mb: 60), item("p2", .patch, day: 2, mb: 60), item("min0", .minor, day: 0, mb: 60),
                     item("min3", .minor, day: 3, mb: 60), item("m4", .manual, day: 4, mb: 1),
                     item("other-p", .patch, day: 1, mb: 60, device: "other"), item("other-min", .minor, day: 1, mb: 60, device: "other")]
        let expired = BackupRetention.expired(items)
        XCTAssertEqual(expired, ["min0"], "Only the older minor may go; each device keeps its own protected backups")
        XCTAssertEqual(BackupRetention.protected(items), ["p1", "p2", "min3", "m4", "other-p", "other-min"])
    }

    func testRetentionCountsABackupInTwoVaultsOnce() {
        let items = [item("a", .manual, day: 1, mb: 60), item("a", .manual, day: 1, mb: 60), item("b", .manual, day: 2, mb: 30)]
        XCTAssertEqual(BackupRetention.expired(items), [], "90 MB, not 150 MB")
        let over = items + [item("c", .manual, day: 3, mb: 20)]
        XCTAssertEqual(BackupRetention.expired(over), ["a"])
    }

    func testRetentionNeverDeletesTheBackupJustMade() {
        let items = [item("old", .manual, day: 1, mb: 150), item("new", .manual, day: 0, mb: 50)]
        XCTAssertEqual(BackupRetention.expired(items, keeping: ["old"]), ["new"])
        XCTAssertEqual(BackupRetention.expired([item("only", .manual, day: 1, mb: 150)], keeping: ["only"]), [])
    }

    // MARK: Launch step

    func testFreshInstallWritesTheMarkerAndMakesNoBackup() {
        let setup = makeSetup()
        let report = UpdateBackup.runAtLaunch(setup)
        XCTAssertNil(report.staged); XCTAssertNil(report.failed)
        XCTAssertEqual(setup.markerDefaults.string(forKey: UpdateBackup.lastVersionKey), "1.6.0")
        XCTAssertEqual(setup.markerDefaults.string(forKey: UpdateBackup.lastBuildKey), "47")
        XCTAssertTrue(UpdateBackup.stagedSnapshots(setup).isEmpty)
    }

    func testDataWithoutMarkerMakesAMinorBackupOfUnknownVersion() throws {
        let setup = makeSetup()
        try makeLibrary(setup, works: [1])
        setup.markerDefaults.set("dark", forKey: "app_theme")
        try write(Data("keys".utf8), setup.files["files/gallery-keys"]!.deletingLastPathComponent(), "gallery-keys.plist")
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).staged, .minor)
        let staged = try XCTUnwrap(UpdateBackup.stagedSnapshots(setup).first)
        let packed = try UpdateBackup.pack(staged, setup: setup)
        XCTAssertNil(packed.manifest.dataVersion); XCTAssertNil(packed.manifest.dataBuild)
        XCTAssertEqual(packed.manifest.kind, .minor)
        XCTAssertEqual(packed.manifest.appVersion, "1.6.0")
        XCTAssertEqual(packed.url.lastPathComponent.prefix(21), "tegnal_minor_0_0_2026")
        let names = Set(packed.manifest.entries.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["db/memo.sqlite", "db/booru.sqlite", "prefs/standard.plist", "prefs/booru.plist", "files/gallery-keys"]))
        XCTAssertTrue(UpdateBackup.stagedSnapshots(setup).isEmpty, "Packing empties the staging folder")
        XCTAssertNil(UpdateBackup.runAtLaunch(setup).staged, "The same version makes no backup")
    }

    func testVersionChangesPickTheBackupKind() throws {
        let cases: [(String, String, String, String, BackupKind?)] = [
            ("1.6.0", "47", "1.6.0", "47", nil), ("1.6.0", "47", "1.6.1", "48", .patch),
            ("1.6.3", "50", "1.7.0", "51", .minor), ("1.6.0", "47", "1.6.0", "48", .patch), ("1.9.2", "60", "2.0", "61", .minor),
        ]
        for (fromVersion, fromBuild, version, build, kind) in cases {
            let setup = makeSetup(version: version, build: build)
            try makeLibrary(setup, works: [1])
            setup.markerDefaults.set(fromVersion, forKey: UpdateBackup.lastVersionKey)
            setup.markerDefaults.set(fromBuild, forKey: UpdateBackup.lastBuildKey)
            XCTAssertEqual(UpdateBackup.runAtLaunch(setup).staged, kind, "\(fromVersion) (\(fromBuild)) → \(version) (\(build))")
            if let kind {
                let packed = try UpdateBackup.pack(XCTUnwrap(UpdateBackup.stagedSnapshots(setup).first), setup: setup)
                XCTAssertEqual(packed.manifest.kind, kind)
                XCTAssertEqual(packed.manifest.dataVersion, fromVersion); XCTAssertEqual(packed.manifest.dataBuild, fromBuild)
            }
        }
    }

    func testFailedSnapshotStillWritesTheMarkerAndRecordsTheFailure() throws {
        let setup = makeSetup()
        try makeLibrary(setup, works: [1])
        setup.markerDefaults.set("1.5.1", forKey: UpdateBackup.lastVersionKey)
        try FileManager.default.createDirectory(at: setup.root, withIntermediateDirectories: true)
        try Data().write(to: setup.staging)  // a file where the staging folder belongs
        let report = UpdateBackup.runAtLaunch(setup)
        XCTAssertEqual(report.failed, .minor); XCTAssertNil(report.staged)
        XCTAssertEqual(setup.markerDefaults.string(forKey: UpdateBackup.lastVersionKey), "1.6.0")
        XCTAssertEqual(UpdateBackup.lastFailure(setup)?.appVersion, "1.6.0")
        XCTAssertNil(UpdateBackup.runAtLaunch(setup).failed, "The next launch does not label migrated data as the old version's")
    }

    func testSnapshotIsTakenBeforeMigration() throws {
        let setup = makeSetup(version: "1.6.0", build: "47")
        let path = setup.dataFolder.appendingPathComponent("memo.sqlite").path
        do {
            let queue = try DatabaseQueue(path: path)
            try AppDatabase.migrator.migrate(queue, upTo: "v15_work_page_count")
            try queue.close()
            try BooruStore(path: setup.dataFolder.appendingPathComponent("booru.sqlite").path).database.close()
        }
        setup.markerDefaults.set("1.5.1", forKey: UpdateBackup.lastVersionKey)
        setup.markerDefaults.set("44", forKey: UpdateBackup.lastBuildKey)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).staged, .minor)
        // The new version then opens and migrates the data.
        let opened = try AppDatabase.open(at: path)
        XCTAssertTrue(try migrations(opened.dbWriter).contains("v16_vivid_folder_colors"))
        try opened.dbWriter.close()

        let packed = try UpdateBackup.pack(XCTUnwrap(UpdateBackup.stagedSnapshots(setup).first), setup: setup)
        XCTAssertEqual(packed.manifest.dataVersion, "1.5.1")
        let prepared = try UpdateBackup.prepareRestore(packed.url, setup: setup)
        let unpacked = try DatabaseQueue(path: prepared.folder.appendingPathComponent("db/memo.sqlite").path)
        let saved = try migrations(unpacked)
        try unpacked.close()
        XCTAssertTrue(saved.contains("v15_work_page_count"))
        XCTAssertFalse(saved.contains("v16_vivid_folder_colors"), "The backup holds the file from before the update")
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        var placed: Set<String> = []
        var checking = setup
        checking.restoreFault = { step in
            guard step == .copiedIn("booru.sqlite") else { return }
            let queue = try DatabaseQueue(path: path)
            defer { try? queue.close() }
            placed = try queue.read { try Set(String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")) }
        }
        XCTAssertEqual(UpdateBackup.runAtLaunch(checking).restored, true)
        XCTAssertFalse(placed.contains("v16_vivid_folder_colors"), "The file put back is the one from before the update")
        XCTAssertTrue(placed.contains("v15_work_page_count"))
        let restored = try DatabaseQueue(path: path)
        XCTAssertTrue(try migrations(restored).contains("v16_vivid_folder_colors"), "This version's migrations then run on it, as on a real update")
        try restored.close()
    }

    // MARK: Restore

    func testRestoreReplacesDataKeepsKeptKeysAndWritesOnlyMissingFiles() throws {
        let setup = makeSetup()
        let standard = setup.markerDefaults
        standard.set("light", forKey: "app_theme")
        standard.set(1, forKey: "privacy.incognito")
        standard.set("before", forKey: "icloud.installation")
        try write(Data("keys at backup".utf8), setup.files["files/gallery-keys"]!.deletingLastPathComponent(), "gallery-keys.plist")
        try write(Data("downloads at backup".utf8), setup.files["files/downloads.json"]!.deletingLastPathComponent(), "downloads.json")
        let backup: URL
        do {
            let (memo, booru) = try openLibrary(setup)
            let folder = try memo.createFolder(name: "Kept")
            _ = try memo.upsertWork(galleryId: 1, folderId: folder.id, title: "One")
            backup = try manualBackup(setup, memo: memo, booru: booru)
            // Changes made after the backup.
            _ = try memo.upsertWork(galleryId: 2, title: "Two")
            try memo.renameFolder(id: folder.id!, name: "Renamed")
            try close(memo, booru)
        }
        standard.set("dark", forKey: "app_theme")
        standard.set("added later", forKey: "manga.defaultTags")
        standard.set(2, forKey: "privacy.incognito")
        standard.set("after", forKey: "icloud.installation")
        try write(Data("keys now".utf8), setup.files["files/gallery-keys"]!.deletingLastPathComponent(), "gallery-keys.plist")
        try FileManager.default.removeItem(at: setup.files["files/downloads.json"]!)

        let prepared = try UpdateBackup.prepareRestore(backup, setup: setup)
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        XCTAssertNotNil(UpdateBackup.pendingRestore(setup))
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, true)
        XCTAssertNil(UpdateBackup.pendingRestore(setup))
        XCTAssertEqual(UpdateBackup.lastRestore(setup)?.succeeded, true)

        let (memo, booru) = try openLibrary(setup)
        XCTAssertNotNil(try memo.getWork(galleryId: 1))
        XCTAssertNil(try memo.getWork(galleryId: 2), "A work added after the backup is gone")
        XCTAssertTrue(try memo.listFolders().contains { $0.name == "Kept" })
        XCTAssertFalse(try memo.listFolders().contains { $0.name == "Renamed" }, "The folder change is undone")
        try close(memo, booru)
        XCTAssertEqual(standard.string(forKey: "app_theme"), "light")
        XCTAssertNil(standard.object(forKey: "manga.defaultTags"), "A key added after the backup goes")
        XCTAssertEqual(standard.integer(forKey: "privacy.incognito"), 2, "Kept keys are not rolled back")
        XCTAssertEqual(standard.string(forKey: "icloud.installation"), "after")
        XCTAssertEqual(standard.string(forKey: UpdateBackup.lastVersionKey), "1.6.0")
        XCTAssertNotNil(standard.object(forKey: UpdateBackup.libraryReplacedKey))
        XCTAssertEqual(try Data(contentsOf: setup.files["files/gallery-keys"]!), Data("keys now".utf8), "An existing file stays")
        XCTAssertEqual(try Data(contentsOf: setup.files["files/downloads.json"]!), Data("downloads at backup".utf8), "A missing file is written")
    }

    func testCorruptDatabaseInBackupRollsBackAndLeavesDataUnchanged() throws {
        let setup = makeSetup()
        try makeLibrary(setup, works: [7])
        setup.markerDefaults.set("1.6.0", forKey: UpdateBackup.lastVersionKey)
        setup.markerDefaults.set("47", forKey: UpdateBackup.lastBuildKey)
        setup.markerDefaults.set("current", forKey: "app_theme")
        let before = try Data(contentsOf: setup.dataFolder.appendingPathComponent("memo.sqlite"))
        // A backup whose checksums are right but whose database is not a database.
        let folder = try scratch(setup, "Restore/incoming-test")
        try write(Data(repeating: 0x42, count: 8192), folder, "db/memo.sqlite")
        try write(try Data(contentsOf: setup.dataFolder.appendingPathComponent("booru.sqlite")), folder, "db/booru.sqlite")
        try write(try PropertyListSerialization.data(fromPropertyList: ["app_theme": "restored"], format: .binary, options: 0), folder, "prefs/standard.plist")
        try UpdateBackup.stageRestore(folder, manifest: manifest(), setup: setup)

        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        XCTAssertEqual(try Data(contentsOf: setup.dataFolder.appendingPathComponent("memo.sqlite")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.dataFolder.appendingPathComponent("booru.sqlite").path))
        XCTAssertEqual(setup.markerDefaults.string(forKey: "app_theme"), "current")
        XCTAssertNil(UpdateBackup.pendingRestore(setup), "A failed restore is not tried again on every launch")
        XCTAssertEqual(UpdateBackup.lastRestore(setup)?.succeeded, false)
        XCTAssertNil(UpdateBackup.lastFailure(setup), "A restore that rolled back is reported in one place only")
        XCTAssertNil(setup.markerDefaults.object(forKey: UpdateBackup.libraryReplacedKey))
        let (memo, booru) = try openLibrary(setup)
        XCTAssertNotNil(try memo.getWork(galleryId: 7))
        try close(memo, booru)
    }

    func testRestoreMakesEveryFavoritesSyncAskAgainAndKeepsDeclinedAccountsDeclined() throws {
        let setup = makeSetup()
        let manga = setup.markerDefaults, images = BackupSetup.defaults(setup.preferences[BackupEntry.booruPreferences]!)
        let sites = SiteFavoriteFolders(defaults: manga)
        let servers = SiteFavoriteFolders(defaults: images, statesKey: SiteFavoriteFolders.booruKeys.states, declinedKey: SiteFavoriteFolders.booruKeys.declined)
        sites.setState(.init(), for: "synced.example")
        sites.remove("declined-then.example", declined: true)
        servers.setState(.init(), for: "server-a")
        servers.remove("server-declined-then", declined: true)
        let backup: URL
        do {
            let (memo, booru) = try openLibrary(setup)
            backup = try manualBackup(setup, memo: memo, booru: booru)
            try close(memo, booru)
        }
        sites.remove("declined-now.example", declined: true)
        sites.setState(.init(), for: "declined-then.example")
        XCTAssertFalse(sites.isDeclined("declined-then.example"))
        XCTAssertFalse(sites.asksAgain("synced.example"))

        let prepared = try UpdateBackup.prepareRestore(backup, setup: setup)
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, true)

        XCTAssertTrue(sites.syncedSites.isEmpty, "No website syncs until the first-sync choice is answered again")
        XCTAssertNil(sites.state(for: "synced.example"))
        XCTAssertTrue(sites.isDeclined("declined-then.example"))
        XCTAssertTrue(sites.isDeclined("declined-now.example"))
        XCTAssertFalse(sites.isDeclined("synced.example"))
        XCTAssertTrue(sites.asksAgain("synced.example"), "Even a website without favorites is asked")
        XCTAssertFalse(sites.asksAgain("declined-then.example"), "A declined account is not asked")
        XCTAssertFalse(sites.asksAgain("never-synced.example"), "An account that never synced follows the usual setup")
        XCTAssertTrue(servers.syncedSites.isEmpty)
        XCTAssertTrue(servers.isDeclined("server-declined-then"))
        XCTAssertFalse(servers.isDeclined("server-a"))
        XCTAssertTrue(servers.asksAgain("server-a"))

        // The wait ends per account, when it is answered.
        sites.setState(.init(), for: "synced.example")
        XCTAssertFalse(sites.asksAgain("synced.example"))
        XCTAssertNil(manga.object(forKey: SiteFavoriteFolders.mangaKeys.asksAgain), "Nothing is left once every account is answered")
        servers.remove("server-a", declined: true)
        XCTAssertFalse(servers.asksAgain("server-a"))
        XCTAssertNil(images.object(forKey: SiteFavoriteFolders.booruKeys.asksAgain))
    }

    func testLibrarySyncSendsTheRestoredLibraryAsTheNewestState() throws {
        let setup = makeSetup()
        let manga = setup.markerDefaults, images = BackupSetup.defaults(setup.preferences[BackupEntry.booruPreferences]!)
        var local = LibrarySyncLedger()
        var peer = try peerLibrary()
        let backup: URL
        do {
            let (memo, booru) = try openLibrary(setup)
            let adapter = LibrarySyncAdapter(manga: memo, booru: booru, mangaDefaults: manga, booruDefaults: images)
            _ = try memo.upsertWork(galleryId: 1, title: "One")
            _ = try memo.upsertWork(galleryId: 2, title: "Two")
            backup = try manualBackup(setup, memo: memo, booru: booru)
            _ = try memo.upsertWork(galleryId: 3, title: "Three")
            local.capture(try adapter.snapshot(), device: "local")
            peer.ledger.merge(local.changes)
            try peer.adapter.apply(peer.ledger.changes)
            peer.ledger.baseline = try peer.adapter.snapshot()
            try close(memo, booru)
        }
        // The other device edits a work the restore brings back as it was, before the restore happens.
        _ = try peer.adapter.manga.upsertWork(galleryId: 2, title: "Edited elsewhere", overwriteMetadata: true)
        peer.ledger.capture(try peer.adapter.snapshot(), device: "peer")

        let prepared = try UpdateBackup.prepareRestore(backup, setup: setup)
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, true)
        let replacedAt = try XCTUnwrap(manga.object(forKey: UpdateBackup.libraryReplacedKey) as? Double)

        let (memo, booru) = try openLibrary(setup)
        let adapter = LibrarySyncAdapter(manga: memo, booru: booru, mangaDefaults: manga, booruDefaults: images)
        local.captureReplacement(try adapter.snapshot(), device: "local", at: replacedAt)
        local.merge(peer.ledger.changes)
        let work3 = try XCTUnwrap(local.changes.values.first { $0.row.table == "manga.works" && $0.row.values["gallery_id"] == .integer(3) })
        XCTAssertTrue(work3.deleted, "A work missing from the restored library is sent as a deletion")
        let work2 = try XCTUnwrap(local.changes.values.first { $0.row.table == "manga.works" && $0.row.values["gallery_id"] == .integer(2) })
        XCTAssertEqual(work2.row.values["title"], .text("Two"), "The restored library wins over the cloud copy")
        try adapter.apply(local.changes)
        XCTAssertNil(try memo.getWork(galleryId: 3), "Nothing is downloaded back")
        XCTAssertEqual(try memo.getWork(galleryId: 2)?.title, "Two")
        try close(memo, booru)

        peer.ledger.merge(local.changes)
        try peer.adapter.apply(peer.ledger.changes)
        XCTAssertNil(try peer.adapter.manga.getWork(galleryId: 3), "The other device follows the restore")
        XCTAssertEqual(try peer.adapter.manga.getWork(galleryId: 2)?.title, "Two")
    }

    func testRestoredWorkWithoutItsCoverWaitsForTheBulkFillGuard() throws {
        let setup = makeSetup()
        let thumbs = try scratch(setup, "thumbs")
        let (memo, booru) = try openLibrary(setup)
        for id in 1...(CoverFillGuard.quietLimit + 5) {
            _ = try memo.upsertWork(galleryId: Int64(id), title: "Work", tags: "tag:one")
            try memo.setThumb(galleryId: Int64(id), status: "ready", path: "/old/container/thumbs/native_\(id).jpg")
        }
        XCTAssertEqual(try memo.countPendingFill(), 0, "Restored rows still claim their covers")
        try memo.repairThumbnailReferences(in: thumbs)
        XCTAssertEqual(try memo.countPendingFill(), CoverFillGuard.quietLimit + 5, "Each cover not on the device goes back to the queue")
        let suite = "update-backup-tests-guard-" + UUID().uuidString; suites.append(suite)
        let outcome = CoverFillGuard.outcome(sites: ["keyed.example"], blocks: { _ in true }, pending: { (try? memo.countPendingFill()) ?? 0 },
                                             manual: false, defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(outcome, .ask(pending: CoverFillGuard.quietLimit + 5, sites: ["keyed.example"]), "They are not read in bulk without asking")
        try close(memo, booru)
    }

    // MARK: Restore failures

    func testFailureAtEachStepOfApplyingLeavesTheOriginalDataInPlace() throws {
        let steps: [RestoreStep] = [.movedAside("memo.sqlite"), .movedAside("booru.sqlite"), .copiedIn("memo.sqlite"), .copiedIn("booru.sqlite"),
                                    .checked, .wrotePreferences(BackupEntry.standardPreferences), .wrotePreferences(BackupEntry.booruPreferences), .commit]
        for step in steps {
            var setup = makeSetup()
            let original = try stageChangedRestore(setup)
            setup.restoreFault = { if $0 == step { throw TestFault() } }
            XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false, "\(step)")
            try assertOriginal(setup, original, "\(step)")
            XCTAssertEqual(UpdateBackup.lastRestore(setup)?.succeeded, false)
            XCTAssertNil(setup.markerDefaults.object(forKey: UpdateBackup.libraryReplacedKey), "\(step)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.files["files/downloads.json"]!.path), "A file the restore wrote goes with it (\(step))")
            // The next launch has nothing to apply and leaves the data alone.
            setup.restoreFault = nil
            XCTAssertNil(UpdateBackup.runAtLaunch(setup).restored)
            try assertOriginal(setup, original, "next launch after \(step)")
        }
    }

    func testKillBetweenMovingTheTwoDatabasesLosesNeither() throws {
        var setup = makeSetup()
        let original = try stageChangedRestore(setup)
        setup.restoreFault = { if $0 == .movedAside("memo.sqlite") { throw UpdateBackup.SimulatedTermination() } }
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.dataFolder.appendingPathComponent("memo.sqlite").path), "The app died with one library aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.dataFolder.appendingPathComponent("booru.sqlite").path))
        // The next launch puts memo back, leaves booru alone, tries again and fails its check.
        setup.restoreFault = { if $0 == .checked { throw TestFault() } }
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        try assertOriginal(setup, original, "after the kill")

        // Without a pending marker a launch puts files left aside back too.
        var other = makeSetup()
        let kept = try stageChangedRestore(other)
        other.restoreFault = { if $0 == .movedAside("memo.sqlite") { throw UpdateBackup.SimulatedTermination() } }
        _ = UpdateBackup.runAtLaunch(other)
        try UpdateBackup.cancelPendingRestore(other)
        other.restoreFault = nil
        XCTAssertNil(UpdateBackup.runAtLaunch(other).restored)
        try assertOriginal(other, kept, "unrecorded restore")
    }

    func testRestoreCutOffTwiceIsGivenUp() throws {
        var setup = makeSetup()
        let original = try stageChangedRestore(setup)
        setup.restoreFault = { if $0 == .checked { throw UpdateBackup.SimulatedTermination() } }
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        XCTAssertEqual(UpdateBackup.pendingRestore(setup)?.attempts, 1)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        XCTAssertEqual(UpdateBackup.pendingRestore(setup)?.attempts, 2)
        setup.restoreFault = nil
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false, "A third launch does not try again")
        XCTAssertNil(UpdateBackup.pendingRestore(setup))
        XCTAssertEqual(UpdateBackup.lastRestore(setup)?.succeeded, false)
        try assertOriginal(setup, original, "given up")
    }

    func testDatabaseThatPassesQuickCheckButFailsTheMigratorRollsBack() throws {
        let setup = makeSetup()
        let original = try stageChangedRestore(setup, stage: false)
        let source = makeSetup()
        do {
            let queue = try DatabaseQueue(path: source.dataFolder.appendingPathComponent("memo.sqlite").path)
            try AppDatabase.migrator.migrate(queue, upTo: "v15_work_page_count")
            try queue.write { try $0.execute(sql: "DROP TABLE folder_works; DROP TABLE folders") }
            XCTAssertEqual(try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }, "ok")
            try queue.close()
            try BooruStore(path: source.dataFolder.appendingPathComponent("booru.sqlite").path).database.close()
        }
        let packed = try UpdateBackup.pack(UpdateBackup.takeSnapshot(source, kind: .manual, dataVersion: "1.6.0", dataBuild: "47"), setup: source)
        let prepared = try UpdateBackup.prepareRestore(packed.url, setup: setup)
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, false)
        try assertOriginal(setup, original, "migrator failure")
        let (memo, booru) = try openLibrary(setup)
        XCTAssertNotNil(try memo.getWork(galleryId: 2), "The app opens its own library afterwards")
        try close(memo, booru)
    }

    @MainActor func testBackupWithoutBothLibrariesIsRefused() async throws {
        let setup = makeSetup()
        let prefs = try PropertyListSerialization.data(fromPropertyList: ["app_theme": "dark"], format: .binary, options: 0)
        for entries in [[("prefs/standard.plist", prefs)], [("db/memo.sqlite", Data("x".utf8)), ("prefs/standard.plist", prefs)]] {
            let file = try container(entries, manifest: manifest(), setup: setup)
            XCTAssertThrowsError(try UpdateBackup.prepareRestore(file, setup: setup)) { XCTAssertEqual($0 as? BackupError, .damaged) }
            let model = AutomaticBackups(setup: setup, databases: { fatalError("No backup is made") }, cloud: nil)
            do { _ = try await model.importFile(file); XCTFail("Imported a backup without both libraries") }
            catch { XCTAssertEqual(error as? BackupError, .damaged) }
        }
        var future = manifest(); future.createdAt = Date().addingTimeInterval(3 * 24 * 3600)
        let file = try container([("db/memo.sqlite", Data("x".utf8)), ("db/booru.sqlite", Data("y".utf8))], manifest: future, setup: setup)
        let model = AutomaticBackups(setup: setup, databases: { fatalError("No backup is made") }, cloud: nil)
        do { _ = try await model.importFile(file); XCTFail("Imported a backup dated days ahead") }
        catch { XCTAssertEqual(error as? BackupError, .damaged) }
        XCTAssertTrue(model.items.isEmpty)
    }

    func testSizesThatLieAreRefusedBeforeAnyWork() throws {
        let setup = makeSetup()
        func entry(_ name: String, size: Int64, stored: Int64) -> BackupManifest.Entry {
            .init(name: name, policy: "replace", size: size, storedSize: stored, compression: "deflate", sha256: String(repeating: "0", count: 64))
        }
        let cases: [[BackupManifest.Entry]] = [
            [entry("db/memo.sqlite", size: 3 << 30, stored: 1)],
            [entry("db/memo.sqlite", size: 1 << 30, stored: 1), entry("db/booru.sqlite", size: 1 << 30, stored: 1), entry("files/gallery-keys", size: 1, stored: 1)],
            [entry("db/memo.sqlite", size: 1, stored: Int64.max), entry("db/booru.sqlite", size: 1, stored: Int64.max)],
            [entry("db/memo.sqlite", size: 1, stored: BackupContainer.fileLimit), entry("db/booru.sqlite", size: 1, stored: .max - BackupContainer.fileLimit + 1)],
        ]
        for entries in cases {
            var head = manifest(); head.entries = entries
            let json = try BackupManifest.encoder.encode(head)
            var file = BackupContainer.magic
            file.append(1)
            withUnsafeBytes(of: UInt32(json.count).bigEndian) { file.append(contentsOf: $0) }
            file.append(json); file.append(Data(count: 3))
            XCTAssertThrowsError(try BackupArchive.open(save(file, setup))) { XCTAssertEqual($0 as? BackupError, .tooLarge, "\(entries.map(\.size))") }
        }
    }

    // MARK: Kept data

    func testAppleOwnedKeysAndTheTasteDeviceAreKept() throws {
        let setup = makeSetup()
        let standard = setup.markerDefaults
        for key in ["AppleLanguages", "NSWindow Frame Main", "WebKitDeveloperExtras", "com.apple.thing"] { standard.set("at backup", forKey: key) }
        standard.set("light", forKey: "app_theme")
        // A backup from another device whose library has its own analysis device.
        let source = makeSetup()
        try makeLibrary(source, works: [1])
        let packed = try UpdateBackup.pack(UpdateBackup.takeSnapshot(source, kind: .manual, dataVersion: "1.6.0", dataBuild: "47"), setup: source)
        try makeLibrary(setup, works: [2])
        let device = try tasteDevice(setup)
        XCTAssertNotEqual(device, try tasteDevice(source))
        for key in ["AppleLanguages", "NSWindow Frame Main", "WebKitDeveloperExtras", "com.apple.thing"] { standard.set("now", forKey: key) }
        standard.set("dark", forKey: "app_theme")

        let before = UserDefaults.standard.persistentDomain(forName: setup.markerDomain) ?? [:]
        let prepared = try UpdateBackup.prepareRestore(packed.url, setup: setup)
        try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, true)
        // Read from the domain itself: the argument domain answers AppleLanguages for the test process.
        let domain = UserDefaults.standard.persistentDomain(forName: setup.markerDomain) ?? [:]
        for key in ["AppleLanguages", "NSWindow Frame Main", "WebKitDeveloperExtras", "com.apple.thing"] {
            XCTAssertEqual(domain[key] as? String, before[key] as? String, key)
        }
        XCTAssertEqual(domain["NSWindow Frame Main"] as? String, "now")
        XCTAssertNotEqual(standard.string(forKey: "app_theme"), "dark", "Other keys are rolled back")
        XCTAssertEqual(try tasteDevice(setup), device, "This device keeps its own analysis device")
        let (memo, booru) = try openLibrary(setup)
        XCTAssertNotNil(try memo.getWork(galleryId: 1)); XCTAssertNil(try memo.getWork(galleryId: 2))
        try close(memo, booru)
    }

    func testNewestSafetyAndManualBackupsSurviveLaterPasses() {
        // The protected update backups alone are over the limit.
        let items = [item("p1", .patch, day: 1, mb: 40), item("p2", .patch, day: 2, mb: 40), item("min3", .minor, day: 3, mb: 40),
                     item("s0", .safety, day: 0, mb: 10), item("s4", .safety, day: 4, mb: 10),
                     item("m1", .manual, day: 1, mb: 10), item("m5", .manual, day: 5, mb: 10)]
        XCTAssertEqual(BackupRetention.expired(items, keeping: ["s4"]), ["s0", "m1"])
        let later = items.filter { !["s0", "m1"].contains($0.name) }
        XCTAssertEqual(BackupRetention.expired(later), [], "A pass that did not make them still keeps them")
    }

    // MARK: Library sync after a restore

    func testReplacementOnADeviceThatNeverSyncedSendsNoDeletions() throws {
        let local = try peerLibrary(), cloud = try peerLibrary()
        _ = try local.adapter.manga.upsertWork(galleryId: 1, title: "Restored")
        _ = try cloud.adapter.manga.upsertWork(galleryId: 1, title: "Cloud")
        _ = try cloud.adapter.manga.upsertWork(galleryId: 9, title: "Only in the cloud")
        var remote = cloud.ledger
        remote.capture(try cloud.adapter.snapshot(), device: "cloud", now: 100)
        var ledger = LibrarySyncLedger()
        ledger.captureReplacement(try local.adapter.snapshot(), device: "local", at: 200)
        XCTAssertFalse(ledger.changes.values.contains(where: \.deleted), "With nothing known before, nothing is sent as deleted")
        ledger.merge(remote.changes)
        try local.adapter.apply(ledger.changes)
        XCTAssertEqual(try local.adapter.manga.getWork(galleryId: 1)?.title, "Restored", "The restored row wins")
        XCTAssertNotNil(try local.adapter.manga.getWork(galleryId: 9), "A cloud row the backup lacks comes back")
    }

    @MainActor func testRestoreStampIsUsedOnlyWhileSyncIsOnInTheSameSession() {
        let suite = "update-backup-tests-sync-" + UUID().uuidString; suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: LibraryCloudSync.enabledKey)
        defaults.set(123.0, forKey: UpdateBackup.libraryReplacedKey)
        XCTAssertNil(LibraryCloudSync(defaults: defaults).pendingReplacement, "Sync off: the stamp is dropped")
        XCTAssertNil(defaults.object(forKey: UpdateBackup.libraryReplacedKey))

        defaults.set(true, forKey: LibraryCloudSync.enabledKey)
        defaults.set(456.0, forKey: UpdateBackup.libraryReplacedKey)
        let sync = LibraryCloudSync(defaults: defaults)
        XCTAssertEqual(sync.pendingReplacement, 456)
        XCTAssertNil(defaults.object(forKey: UpdateBackup.libraryReplacedKey), "A later session never sees the old stamp")
        XCTAssertNil(LibraryCloudSync(defaults: defaults).pendingReplacement)
        sync.enabled = false
        XCTAssertNil(sync.pendingReplacement, "Turned off before its first sync, the stamp goes")
    }

    func testRestoreWithSyncOffLeavesNoStamp() throws {
        let setup = makeSetup()
        setup.markerDefaults.set(false, forKey: LibraryCloudSync.enabledKey)
        _ = try stageChangedRestore(setup)
        XCTAssertEqual(UpdateBackup.runAtLaunch(setup).restored, true)
        XCTAssertNil(setup.markerDefaults.object(forKey: UpdateBackup.libraryReplacedKey))
        XCTAssertEqual(setup.markerDefaults.object(forKey: LibraryCloudSync.enabledKey) as? Bool, false)
    }

    // MARK: Screen model

    @MainActor func testScreenModelBacksUpExportsImportsStagesAndCancelsARestore() async throws {
        let setup = makeSetup()
        let (memo, booru) = try openLibrary(setup)
        _ = try memo.upsertWork(galleryId: 1, title: "One")
        let model = AutomaticBackups(setup: setup, databases: { .init(memo: memo.dbWriter, booru: booru.database) }, cloud: nil)
        XCTAssertTrue(model.keepInICloud, "Keep in iCloud starts on")
        XCTAssertFalse(model.iCloudAvailable)

        try await model.backUpNow()
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(item.kind, .manual)
        XCTAssertEqual(item.dataVersion, "1.6.0"); XCTAssertEqual(item.appVersion, "1.6.0")
        XCTAssertEqual(item.deviceName, "Test iPhone"); XCTAssertTrue(item.isThisDevice)
        XCTAssertEqual(item.places, [.local]); XCTAssertEqual(item.download, .onDevice)
        XCTAssertGreaterThan(item.size, 0); XCTAssertEqual(model.totalSize, item.size)
        XCTAssertTrue(item.isProtected, "The newest backup made by hand is always kept")

        let exported = try await model.export(item)
        XCTAssertEqual(try BackupArchive.open(exported).manifest.fileName, item.id)
        try await model.delete(item)
        XCTAssertTrue(model.items.isEmpty)
        let imported = try await model.importFile(exported)
        XCTAssertEqual(imported?.id, item.id, "An imported file is listed under its own name again")

        try await model.restore(try XCTUnwrap(imported))
        XCTAssertEqual(model.pendingRestore?.name, item.id)
        XCTAssertTrue(model.items.contains { $0.kind == .safety }, "The current data is backed up before a restore is staged")
        try model.cancelPendingRestore()
        XCTAssertNil(model.pendingRestore)
        XCTAssertNil(UpdateBackup.pendingRestore(setup))
        try close(memo, booru)
    }

    // MARK: Helpers

    private struct TestFault: Error {}

    /// The original data, as the restore must leave it when it fails.
    private struct Original { var files: [String: Data]; var theme: String?; var booruKey: String? }

    /// A library of works 1 and 2 whose backup holds work 1 only, staged to restore. Returns the data as it is now.
    private func stageChangedRestore(_ setup: BackupSetup, stage: Bool = true) throws -> Original {
        let images = BackupSetup.defaults(setup.preferences[BackupEntry.booruPreferences]!)
        setup.markerDefaults.set("1.6.0", forKey: UpdateBackup.lastVersionKey)
        setup.markerDefaults.set("47", forKey: UpdateBackup.lastBuildKey)
        setup.markerDefaults.set("at backup", forKey: "app_theme")
        try write(Data("downloads".utf8), setup.files["files/downloads.json"]!.deletingLastPathComponent(), "downloads.json")
        let (memo, booru) = try openLibrary(setup)
        _ = try memo.upsertWork(galleryId: 1, title: "One")
        let backup = try manualBackup(setup, memo: memo, booru: booru)
        _ = try memo.upsertWork(galleryId: 2, title: "Two")
        try booru.saveServer(BooruServer.presets[0])
        try close(memo, booru)
        setup.markerDefaults.set("now", forKey: "app_theme")
        images.set("now", forKey: "booru.showNotes")
        try FileManager.default.removeItem(at: setup.files["files/downloads.json"]!)
        if stage {
            let prepared = try UpdateBackup.prepareRestore(backup, setup: setup)
            try UpdateBackup.stageRestore(prepared.folder, manifest: prepared.manifest, setup: setup)
        }
        return Original(files: try databaseFiles(setup), theme: "now", booruKey: "now")
    }

    private func databaseFiles(_ setup: BackupSetup) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in BackupEntry.databaseEntries {
            let url = setup.dataFolder.appendingPathComponent(String(entry.dropFirst(3)))
            if FileManager.default.fileExists(atPath: url.path) { result[entry] = try Data(contentsOf: url) }
        }
        return result
    }

    private func assertOriginal(_ setup: BackupSetup, _ original: Original, _ label: String, line: UInt = #line) throws {
        XCTAssertEqual(try databaseFiles(setup), original.files, "Both libraries are the originals (\(label))", line: line)
        XCTAssertEqual(setup.markerDefaults.string(forKey: "app_theme"), original.theme, "Preferences are the originals (\(label))", line: line)
        let images = BackupSetup.defaults(setup.preferences[BackupEntry.booruPreferences]!)
        XCTAssertEqual(images.string(forKey: "booru.showNotes"), original.booruKey, label, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.restore.appendingPathComponent("previous").path), label, line: line)
    }

    private func tasteDevice(_ setup: BackupSetup) throws -> Data? {
        let queue = try DatabaseQueue(path: setup.dataFolder.appendingPathComponent("memo.sqlite").path)
        defer { try? queue.close() }
        return try queue.read { try Data.fetchOne($0, sql: "SELECT value FROM taste_meta WHERE key = 'device'") }
    }


    private func makeSetup(version: String = "1.6.0", build: String = "47") -> BackupSetup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-backup-tests-" + UUID().uuidString, isDirectory: true)
        roots.append(root)
        let standard = "update-backup-tests-" + UUID().uuidString, images = standard + ".booru"
        suites += [standard, images]
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Data"), withIntermediateDirectories: true)
        let files = root.appendingPathComponent("Support", isDirectory: true)
        return BackupSetup(
            dataFolder: root.appendingPathComponent("Data", isDirectory: true), root: root.appendingPathComponent("Backups", isDirectory: true),
            files: ["files/gallery-keys": files.appendingPathComponent("gallery-keys.plist"),
                    "files/work-missing-sites": files.appendingPathComponent("work-missing-sites.plist"),
                    "files/downloads.json": files.appendingPathComponent("Downloads/downloads.json"),
                    "files/downloads-settings.json": files.appendingPathComponent("Downloads/settings.json"),
                    "files/generated-index.json": files.appendingPathComponent("Generated/index.json")],
            preferences: [BackupEntry.standardPreferences: standard, BackupEntry.booruPreferences: images],
            markerDomain: standard, appVersion: version, appBuild: build,
            device: .init(id: "a1b2c3d4", name: "Test iPhone"), now: { Date() })
    }

    private func manifest() -> BackupManifest {
        BackupManifest(id: "id", kind: .manual, createdAt: Date(timeIntervalSince1970: 1_795_144_500), dataVersion: nil, dataBuild: nil,
                       appVersion: "1.6.0", appBuild: "47", device: .init(id: "a1b2c3d4", name: "iPhone"))
    }

    private func item(_ name: String, _ kind: BackupKind, day: Int, mb: Int64, device: String = "d") -> BackupRetention.Item {
        .init(name: name, size: mb * 1024 * 1024, device: device, kind: kind, date: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    private func scratch(_ setup: BackupSetup, _ name: String) throws -> URL {
        let url = setup.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, _ folder: URL, _ name: String) throws {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func save(_ data: Data, _ setup: BackupSetup) throws -> URL {
        let url = try scratch(setup, "files").appendingPathComponent(UUID().uuidString + ".tegnalbackup")
        try data.write(to: url)
        return url
    }

    /// A container written by hand, entries stored as they are, so tests can put in names the writer never would.
    private func container(_ entries: [(String, Data)], manifest base: BackupManifest, setup: BackupSetup, corruptChecksum: Bool = false) throws -> URL {
        var manifest = base
        manifest.entries = entries.map { name, data in
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .init(name: name, policy: "replace", size: Int64(data.count), storedSize: Int64(data.count), compression: "none",
                         sha256: corruptChecksum ? String(repeating: "0", count: 64) : digest)
        }
        let json = try BackupManifest.encoder.encode(manifest)
        var file = BackupContainer.magic
        file.append(1)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { file.append(contentsOf: $0) }
        file.append(json)
        for (_, data) in entries { file.append(data) }
        return try save(file, setup)
    }

    private func makeLibrary(_ setup: BackupSetup, works: [Int64]) throws {
        let (memo, booru) = try openLibrary(setup)
        for id in works { _ = try memo.upsertWork(galleryId: id, title: "Work \(id)") }
        try close(memo, booru)
    }

    private func openLibrary(_ setup: BackupSetup) throws -> (AppDatabase, BooruStore) {
        (try AppDatabase.open(at: setup.dataFolder.appendingPathComponent("memo.sqlite").path),
         try BooruStore(path: setup.dataFolder.appendingPathComponent("booru.sqlite").path))
    }

    private func close(_ memo: AppDatabase, _ booru: BooruStore) throws {
        try memo.dbWriter.close()
        try booru.database.close()
    }

    private func manualBackup(_ setup: BackupSetup, memo: AppDatabase, booru: BooruStore) throws -> URL {
        let folder = try UpdateBackup.takeSnapshot(setup, kind: .manual, dataVersion: setup.appVersion, dataBuild: setup.appBuild,
                                                   databases: .init(memo: memo.dbWriter, booru: booru.database))
        return try UpdateBackup.pack(folder, setup: setup).url
    }

    private func migrations(_ reader: any DatabaseReader) throws -> Set<String> {
        try reader.read { try Set(String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")) }
    }

    private func peerLibrary() throws -> (adapter: LibrarySyncAdapter, ledger: LibrarySyncLedger) {
        func defaults() -> UserDefaults {
            let name = "update-backup-tests-peer-" + UUID().uuidString; suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        return (LibrarySyncAdapter(manga: try .inMemory(), booru: try BooruStore(), mangaDefaults: defaults(), booruDefaults: defaults()), LibrarySyncLedger())
    }
}

