import XCTest
import GRDB
@testable import TEGNAL

final class FolderPaletteTests: XCTestCase {
    /// Colors 1.5.1 and earlier gave folders on their own, in the order they gave them.
    private let earlierPalette: [Int64] = [
        0xFF2563EB, 0xFF059669, 0xFFEA580C, 0xFFE11D48, 0xFF7C3AED, 0xFF0891B2, 0xFFD97706, 0xFFDB2777,
        0xFF4F46E5, 0xFF0D9488, 0xFF65A30D, 0xFFC026D3, 0xFFDC2626, 0xFF9333EA, 0xFF0284C7, 0xFFB45309,
        0xFF16A34A, 0xFFF97316, 0xFF6366F1, 0xFF14B8A6, 0xFF84CC16, 0xFFEC4899, 0xFFA855F7, 0xFF3B82F6,
        0xFF10B981, 0xFFF59E0B, 0xFFEF4444, 0xFF64748B
    ]

    func testEveryEarlierColorBecomesItsOwnCurrentColorAndCurrentColorsStay() {
        let mapped = earlierPalette.map(FolderPalette.vivid)
        XCTAssertEqual(Set(mapped).count, earlierPalette.count, "folders that differed must still differ")
        XCTAssertTrue(mapped.allSatisfy(FolderPalette.colors.contains))
        XCTAssertEqual(FolderPalette.vivid(0xFF2563EB), FolderPalette.colors[0])
        XCTAssertEqual(FolderPalette.vivid(FolderPalette.earlierUnfiled), FolderPalette.unfiled)
        XCTAssertEqual(FolderPalette.vivid(FolderPalette.earlierUnsorted), FolderPalette.unsorted)
        for color in FolderPalette.colors + (0..<40).map(FolderPalette.generated) {
            XCTAssertEqual(FolderPalette.vivid(color), color)
        }
        XCTAssertEqual(Set(FolderPalette.colors).count, FolderPalette.colors.count)
    }

    func testOtherColorsKeepTheirHueAndGraysBecomeSlate() {
        XCTAssertEqual(FolderPalette.vivid(0xFF9E9E9E), 0xFF5C6B80)
        XCTAssertEqual(FolderPalette.vivid(0xFF000000), 0xFF5C6B80)
        XCTAssertEqual(FolderPalette.vivid(0xFFFF0000), 0xFFFF3B30)
        XCTAssertEqual(FolderPalette.vivid(0xFFFFFF00), 0xFFFFCC00)
        XCTAssertEqual(FolderPalette.vivid(0x00FF0000), 0xFFFF3B30, "a color without alpha counts as opaque")
    }

    func testChoicesAreTheFirstTenUnusedColorsAndGoPastThePalette() {
        let used: Set<Int64> = [FolderPalette.colors[0], FolderPalette.colors[2]]
        let choices = FolderPalette.unused(used, count: 10)
        XCTAssertEqual(choices.count, 10)
        XCTAssertEqual(choices.first, FolderPalette.colors[1])
        XCTAssertTrue(used.isDisjoint(with: choices))
        let everything = FolderPalette.unused(Set(FolderPalette.colors), count: 10)
        XCTAssertEqual(everything, (0..<10).map(FolderPalette.generated))
        XCTAssertEqual(FolderPalette.next(used: used), FolderPalette.colors[1])
    }

    func testMigrationRecolorsFoldersKeepingThemApart() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE folders (id TEXT PRIMARY KEY, color INTEGER NOT NULL)")
            // Two custom colors close to the same palette color take different ones.
            for (id, color) in [("a", 0xFF2563EB), ("b", 0xFF1E70F0), ("c", 0xFF1F6BFF), ("d", 0xFF9E9E9E), ("e", 0xFF2563EB)] as [(String, Int64)] {
                try db.execute(sql: "INSERT INTO folders VALUES (?, ?)", arguments: [id, color])
            }
            try AppDatabase.adoptVividFolderColors(db)
        }
        let colors = try queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, color FROM folders").map { ($0["id"] as String, $0["color"] as Int64) })
        }
        XCTAssertEqual(colors["a"], FolderPalette.colors[0])
        XCTAssertEqual(colors["e"], FolderPalette.colors[0], "the same color stays the same")
        XCTAssertEqual(colors["c"], FolderPalette.colors[0], "a current color is kept")
        XCTAssertNotEqual(colors["b"], FolderPalette.colors[0])
        XCTAssertTrue(FolderPalette.colors.contains(colors["b"] ?? 0))
        XCTAssertEqual(colors["d"], 0xFF5C6B80)
    }

    func testNewLibrariesStartWithTheNewDefaultsAndBackupsBringOldColorsUpToDate() throws {
        let comics = try AppDatabase.inMemory()
        XCTAssertEqual(try comics.ensureDefaultFolder().color, FolderPalette.unfiled)
        XCTAssertEqual(try comics.createFolder(name: "First").color, FolderPalette.colors[0])
        let images = try BooruStore()
        try images.database.write { try BooruStore.ensureUnsorted(in: $0) }
        try images.refresh()
        XCTAssertEqual(images.folders().first { $0.id == "unsorted" }?.color, FolderPalette.unsorted)

        let backup = BooruBackup(servers: [], folders: [.init(id: "old", name: "Old", color: 0xFF0D9488)], favorites: [],
                                 history: [], savedTags: [], blacklist: [:], selectedServerIDs: [])
        try images.restoreBackup(backup)
        XCTAssertEqual(images.folders().first { $0.id == "old" }?.color, 0xFF00897B)
    }
}
