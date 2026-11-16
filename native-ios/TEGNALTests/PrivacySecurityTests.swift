import XCTest
import GRDB
@testable import TEGNAL

@MainActor final class PrivacySecurityTests: XCTestCase {
    override func tearDown() {
        ContentPreferences.defaults.removeObject(forKey: PrivacySettings.incognitoKey)
        super.tearDown()
    }

    func testIncognitoKeepsBrowsingOutOfHistoryAndTaste() throws {
        let database = try AppDatabase.inMemory()
        let images = try BooruStore()
        let suite = "work.nextline.tegnal.privacy-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentWorks(defaults: defaults, covers: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let gallery = NativeGallery(id: 7_000_001, title: "Work", artists: [], language: "korean", type: "manga", tags: ["tag:example"], pages: [])

        ContentPreferences.defaults.set(true, forKey: PrivacySettings.incognitoKey)
        XCTAssertTrue(PrivacySettings.isIncognito)
        try database.recordSearch("tag:example")
        try images.recordSearch("blue_sky", serverID: "server")
        recent.opened(gallery, site: nil)
        try database.tasteStore.record(.open, item: .comic(7_000_001, tags: "tag:example"), context: .unknown)
        try database.tasteStore.record(.search, item: .comic(7_000_001, tags: "tag:example"), context: .unknown)
        XCTAssertTrue(try database.searchHistory().isEmpty)
        XCTAssertTrue(images.history(serverID: "server").isEmpty)
        XCTAssertTrue(recent.entries.isEmpty)
        XCTAssertTrue(try database.tasteStore.events().isEmpty)
        // A deliberate save still teaches taste.
        try database.tasteStore.record(.save, item: .comic(7_000_001, tags: "tag:example"), context: .unknown)
        XCTAssertEqual(try database.tasteStore.events().map(\.kind), [.save])

        ContentPreferences.defaults.set(false, forKey: PrivacySettings.incognitoKey)
        try database.recordSearch("tag:example")
        recent.opened(gallery, site: nil)
        XCTAssertEqual(try database.searchHistory(), ["tag:example"])
        XCTAssertEqual(recent.entries.map(\.id), [7_000_001])
    }

    func testLockedBackupOpensOnlyWithItsPassword() throws {
        let plain = Data(#"{"format":"tegnal-library"}"#.utf8)
        let locked = try LockedBackup.lock(plain, password: "correct horse", iterations: 1_000)
        XCTAssertTrue(LockedBackup.isLocked(locked))
        XCTAssertFalse(LockedBackup.isLocked(plain))
        XCTAssertNil(String(data: locked, encoding: .utf8)?.range(of: "tegnal-library"))
        XCTAssertEqual(try LockedBackup.unlock(locked, password: "correct horse"), plain)
        XCTAssertThrowsError(try LockedBackup.unlock(locked, password: "wrong")) { XCTAssertEqual($0 as? LockedBackupError, .wrongPassword) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try locked.write(to: url)
        XCTAssertThrowsError(try LibraryBackupImport.read(url)) { XCTAssertEqual($0 as? LockedBackupError, .passwordRequired) }
    }

    /// Made by the Android app's `LockedBackup.lock` with the password `tegnal-test` and 1,000 rounds.
    func testLockedBackupFromAndroidOpens() throws {
        let file = Data(Self.androidLocked.utf8)
        XCTAssertEqual(String(decoding: try LockedBackup.unlock(file, password: "tegnal-test"), as: UTF8.self), #"{"format":"tegnal-library","from":"android"}"#)
    }

    func testEncryptedDNSChoicesHaveResolversAndAddresses() {
        for choice in EncryptedDNS.allCases where choice != .off {
            XCTAssertEqual(choice.resolver?.scheme, "https")
            XCTAssertFalse(choice.bootstrapAddresses.isEmpty)
        }
        XCTAssertNil(EncryptedDNS.off.resolver)
    }

    static let androidLocked = """
    {
      "cipher": "AES-256-GCM",
      "data": "suXiXWlliLlFMqh64qC92OWtvkrIr2VMv97fWkvxVM9EMf6NnIVNs1JOiCqp3o06MCUMoDKVfVjiAUUr",
      "format": "tegnal-locked-backup",
      "iterations": 1000,
      "kdf": "PBKDF2-SHA256",
      "nonce": "d9T2YfLwzGfdOAK9",
      "salt": "x/jdWQSAEJf8knKpSOTriQ==",
      "version": 1
    }
    """
}
