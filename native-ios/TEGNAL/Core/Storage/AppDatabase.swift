import Foundation
import GRDB

enum FolderDeletionError: LocalizedError {
    case containsWorks
    var errorDescription: String? { L10n.text("Move or remove the works in Uncategorized before deleting it.") }
}

public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try Self.migrator.migrate(dbWriter)
    }

    public static func open(at path: String? = nil) throws -> AppDatabase {
        let databasePath = try path ?? AppStorage.preparedContainerURL().appendingPathComponent("memo.sqlite").path
        var config = Configuration()
        config.qos = .userInitiated
        config.foreignKeysEnabled = true
        let dbQueue = try DatabaseQueue(path: databasePath, configuration: config)
        let db = try AppDatabase(dbQueue)
        try db.repairOrphanWorks()
        return db
    }

    public static func inMemory() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(configuration: Configuration())
        let db = try AppDatabase(dbQueue)
        try db.repairOrphanWorks()
        return db
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_schema") { db in
            try db.create(table: "folders", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("description", .text)
                t.column("color", .integer).notNull().defaults(to: 4288585374)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("source_group_id", .integer)
            }

            try db.create(table: "works", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gallery_id", .integer).notNull().unique()
                t.column("title", .text)
                t.column("artists", .text)
                t.column("language", .text)
                t.column("type", .text)
                t.column("series", .text)
                t.column("groups", .text)
                t.column("tags", .text)
                t.column("note", .text)
                t.column("bookmarked_at", .text).notNull()
                t.column("published_at", .text)
                t.column("last_opened_at", .text)
                t.column("updated_at", .text)
                t.column("metadata_source", .text)
                t.column("catalog_matched", .boolean).notNull().defaults(to: false)
                t.column("thumb_status", .text).notNull().defaults(to: "missing")
                t.column("thumb_path", .text)
                t.column("thumb_failed_at", .text)
                t.column("thumb_page", .integer).defaults(to: 1)
            }
            try db.create(index: "idx_works_bookmarked", on: "works", columns: ["bookmarked_at"])
            try db.create(index: "idx_works_gallery_id", on: "works", columns: ["gallery_id"])

            try db.create(table: "folder_works", ifNotExists: true) { t in
                t.column("folder_id", .integer).notNull().references("folders", onDelete: .cascade)
                t.column("work_id", .integer).notNull().references("works", onDelete: .cascade)
                t.column("added_at", .text).notNull()
                t.primaryKey(["folder_id", "work_id"])
            }

            try db.create(table: "catalog_works", ifNotExists: true) { t in
                t.column("id", .integer).primaryKey() // gallery_id
                t.column("title", .text)
                t.column("type", .text)
                t.column("language", .text)
                t.column("artists", .text)
                t.column("groups", .text)
                t.column("series", .text)
                t.column("characters", .text)
                t.column("tags", .text)
                t.column("published", .text)
            }
            try db.create(index: "idx_catalog_title", on: "catalog_works", columns: ["title"])

            try db.create(table: "artists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .integer).notNull().defaults(to: 0)
                t.column("note", .text)
                t.column("folder_id", .integer).references("folders", onDelete: .setNull)
                t.column("bookmarked_at", .text).notNull()
                t.uniqueKey(["name", "kind"])
            }

            try db.create(table: "inbox", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("gallery_id", .integer).notNull()
                t.column("raw_text", .text)
                t.column("received_at", .text).notNull()
                t.column("processed_at", .text)
            }
            try db.create(index: "idx_folder_works_work_id", on: "folder_works", columns: ["work_id"])
        }

        migrator.registerMigration("v2_thumb_page") { db in
            if try !db.columns(in: "works").contains(where: { $0.name == "thumb_page" }) {
                try db.alter(table: "works") { t in
                    t.add(column: "thumb_page", .integer).defaults(to: 1)
                }
            }
        }

        migrator.registerMigration("v3_searches_and_sync_identity") { db in
            try db.execute(sql: "CREATE TABLE search_history (query TEXT PRIMARY KEY, used_at DOUBLE NOT NULL); CREATE TABLE saved_searches (query TEXT PRIMARY KEY);")
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN sync_id TEXT")
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM folders") {
                let id: Int64 = row["id"]
                let name: String = row["name"]
                try db.execute(sql: "UPDATE folders SET sync_id = ? WHERE id = ?", arguments: [name == "미분류" ? "unsorted" : UUID().uuidString, id])
            }
            try db.execute(sql: "CREATE UNIQUE INDEX folder_sync_id ON folders(sync_id)")
        }
        migrator.registerMigration("v4_folder_order") { db in
            try db.execute(sql: "CREATE TABLE library_order (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        }
        migrator.registerMigration("v5_taste") { try TasteStore.migrate($0) }
        migrator.registerMigration("v6_visual_fingerprints") { try VisualFingerprintStore.migrate($0) }
        migrator.registerMigration("v7_visual_cleanup") { try VisualFingerprintStore.installDeletionTrigger($0) }
        migrator.registerMigration("v8_default_folder_lifecycle") { db in
            // Bootstrap once. Reopening an empty library must not recreate a deleted folder.
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 0 {
                _ = try Self.unfiledFolder(in: db)
            }
        }
        migrator.registerMigration("v9_index_folder_works_work_id") { db in
            try db.create(index: "idx_folder_works_work_id", on: "folder_works", columns: ["work_id"], ifNotExists: true)
        }
        migrator.registerMigration("v10_generic_import_metadata") { db in
            let columns = try db.columns(in: "folders").map(\.name)
            guard !columns.contains(MangaImportMetadata.groupIDKey) else { return }
            let legacy = MangaImportMetadata.legacyGroupIDKey(in: columns)
            try db.alter(table: "folders") { table in
                if let legacy { table.rename(column: legacy, to: MangaImportMetadata.groupIDKey) }
                else { table.add(column: MangaImportMetadata.groupIDKey, .integer) }
            }
        }
        migrator.registerMigration("v11_folder_rule_rows") { try Self.adoptLegacyFolderRules($0) }
        // Local only: the sync and backup table lists leave it out.
        migrator.registerMigration("v12_refresh_queue") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS refresh_queue (gallery_id INTEGER PRIMARY KEY NOT NULL)")
        }
        migrator.registerMigration("v13_work_site") { db in
            if try !db.columns(in: "works").map(\.name).contains("site") { try db.execute(sql: "ALTER TABLE works ADD COLUMN site TEXT") }
        }
        migrator.registerMigration("v14_one_work_per_number") { try Self.restoreOneWorkPerNumber($0) }
        migrator.registerMigration("v15_work_page_count") { db in
            if try !db.columns(in: "works").map(\.name).contains("page_count") { try db.execute(sql: "ALTER TABLE works ADD COLUMN page_count INTEGER") }
        }
        // Folder colors from the earlier, quieter palette or the old color picker become the
        // closest vivid color.
        migrator.registerMigration("v16_vivid_folder_colors") { try Self.adoptVividFolderColors($0) }
        return migrator
    }

    /// Every supported website numbers its works the same way, so a number is one work. Test builds
    /// briefly saved a number once per website; this folds those copies into one, keeping the latest
    /// saved, and puts the tables back as they were. Other libraries are left untouched.
    static func restoreOneWorkPerNumber(_ db: Database) throws {
        let perSite = try Row.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_works_identity'") != nil
        guard perSite else { return }
        let duplicated = try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works GROUP BY gallery_id HAVING COUNT(*) > 1")
        for galleryId in duplicated {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM works WHERE gallery_id = ? ORDER BY bookmarked_at DESC, id DESC", arguments: [galleryId])
            guard let keeper = rows.first, let keeperId: Int64 = keeper["id"] else { continue }
            for row in rows.dropFirst() {
                guard let id: Int64 = row["id"] else { continue }
                // The latest saved copy stays; what it lacks comes from the older ones.
                for column in ["title", "artists", "language", "type", "series", "groups", "tags", "note", "published_at", "metadata_source", "site"] {
                    try db.execute(sql: "UPDATE works SET \(column) = (SELECT \(column) FROM works WHERE id = ?) WHERE id = ? AND (\(column) IS NULL OR \(column) = '')", arguments: [id, keeperId])
                }
                try db.execute(sql: """
                UPDATE works SET last_opened_at = (SELECT NULLIF(MAX(COALESCE(last_opened_at, '')), '') FROM works WHERE id IN (?, ?)) WHERE id = ?
                """, arguments: [id, keeperId, keeperId])
                try db.execute(sql: """
                UPDATE works SET thumb_status = o.thumb_status, thumb_path = o.thumb_path, thumb_page = o.thumb_page, thumb_failed_at = o.thumb_failed_at
                FROM (SELECT * FROM works WHERE id = ?) o WHERE works.id = ? AND works.thumb_status != 'ready' AND o.thumb_status = 'ready'
                """, arguments: [id, keeperId])
                // A folder holds the work once, saved when it was last saved there.
                try db.execute(sql: """
                INSERT INTO folder_works (folder_id, work_id, added_at) SELECT folder_id, ?, added_at FROM folder_works WHERE work_id = ?
                ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)
                """, arguments: [keeperId, id])
                try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [id])
                try db.execute(sql: "INSERT OR IGNORE INTO refresh_queue (work_id) SELECT ? FROM refresh_queue WHERE work_id = ?", arguments: [keeperId, id])
                try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [id])
            }
        }
        try db.execute(sql: "DROP TRIGGER IF EXISTS remove_visual_fingerprint")
        try db.execute(sql: """
        CREATE TABLE works_restored (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            gallery_id INTEGER NOT NULL UNIQUE,
            title TEXT, artists TEXT, language TEXT, type TEXT, series TEXT, groups TEXT, tags TEXT, note TEXT,
            bookmarked_at TEXT NOT NULL, published_at TEXT, last_opened_at TEXT, updated_at TEXT, metadata_source TEXT,
            catalog_matched BOOLEAN NOT NULL DEFAULT 0, thumb_status TEXT NOT NULL DEFAULT 'missing', thumb_path TEXT,
            thumb_failed_at TEXT, thumb_page INTEGER DEFAULT 1, site TEXT
        )
        """)
        let columns = "id, gallery_id, title, artists, language, type, series, groups, tags, note, bookmarked_at, published_at, last_opened_at, updated_at, metadata_source, catalog_matched, thumb_status, thumb_path, thumb_failed_at, thumb_page, site"
        try db.execute(sql: "INSERT INTO works_restored (\(columns)) SELECT \(columns) FROM works")
        try db.execute(sql: "DROP TABLE works")
        try db.execute(sql: "ALTER TABLE works_restored RENAME TO works")
        try db.execute(sql: "CREATE INDEX idx_works_bookmarked ON works(bookmarked_at)")
        try db.execute(sql: "CREATE INDEX idx_works_gallery_id ON works(gallery_id)")
        try VisualFingerprintStore.installDeletionTrigger(db)
        // The refresh queue names numbers again.
        try db.execute(sql: "CREATE TABLE refresh_queue_numbers (gallery_id INTEGER PRIMARY KEY NOT NULL)")
        if try db.columns(in: "refresh_queue").map(\.name).contains("work_id") {
            try db.execute(sql: "INSERT OR IGNORE INTO refresh_queue_numbers (gallery_id) SELECT w.gallery_id FROM refresh_queue q JOIN works w ON w.id = q.work_id")
        }
        try db.execute(sql: "DROP TABLE refresh_queue")
        try db.execute(sql: "ALTER TABLE refresh_queue_numbers RENAME TO refresh_queue")
    }

    // MARK: - Folders & Color Generation

    public static var curatedFolderColors: [Int64] { FolderPalette.colors }
    public static var presetColors: [Int64] { FolderPalette.colors }

    public static func colorFromHSV(h: Double, s: Double, v: Double) -> Int64 {
        let c = v * s
        let modH = (h.truncatingRemainder(dividingBy: 1.0) + 1.0).truncatingRemainder(dividingBy: 1.0) * 6.0
        let x = c * (1.0 - abs(modH.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(modH) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let r = Int64(round((r1 + m) * 255.0))
        let g = Int64(round((g1 + m) * 255.0))
        let b = Int64(round((b1 + m) * 255.0))
        return (0xFF << 24) | (r << 16) | (g << 8) | b
    }

    public func nextUniqueFolderColor(in db: Database, excluding: Set<Int64> = []) -> Int64 {
        let existingColors = (try? Int64.fetchAll(db, sql: "SELECT color FROM folders")) ?? []
        return Self.nextFolderColor(existingColors: existingColors, excluding: excluding)
    }

    /// Shared by both libraries: the first palette color no folder uses, then generated hues.
    public static func nextFolderColor(existingColors: [Int64], excluding: Set<Int64> = []) -> Int64 {
        FolderPalette.next(used: Set(existingColors).union(excluding))
    }

    public func nextUniqueFolderColor(excluding: Set<Int64> = []) -> Int64 {
        (try? dbWriter.read { db in nextUniqueFolderColor(in: db, excluding: excluding) })
            ?? FolderPalette.colors[0]
    }

    /// Moves every folder onto the current palette, keeping folders apart where the palette allows.
    static func adoptVividFolderColors(_ db: Database, table: String = "folders") throws {
        let colors = try Int64.fetchAll(db, sql: "SELECT DISTINCT color FROM \(table)")
        for (old, new) in FolderPalette.replacing(colors) where old != new {
            try db.execute(sql: "UPDATE \(table) SET color = ? WHERE color = ?", arguments: [new, old])
        }
    }

    static func unfiledFolder(in db: Database) throws -> Folder {
        if let existing = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE sync_id = 'unsorted' OR name = '미분류' LIMIT 1") { return existing }
        try db.execute(sql: "INSERT INTO folders (name, description, color, sort_order, created_at, sync_id) VALUES ('미분류', '기본 폴더', ?, 1, ?, 'unsorted')", arguments: [FolderPalette.unfiled, ISO8601DateFormatter().string(from: Date())])
        return try Folder.fetchOne(db, key: db.lastInsertedRowID)!
    }

    private func repairOrphanWorks() throws {
        let orphaned = try dbWriter.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM works WHERE id NOT IN (SELECT work_id FROM folder_works))") == true }
        if orphaned { _ = try ensureDefaultFolder() }
    }

    @discardableResult
    public func ensureDefaultFolder() throws -> Folder {
        try dbWriter.write { db in
            let folder: Folder
            if let existing = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = '미분류' LIMIT 1")
                ?? Folder.fetchOne(db, sql: "SELECT * FROM folders ORDER BY sort_order ASC, id ASC LIMIT 1") {
                folder = existing
            } else {
                let now = ISO8601DateFormatter().string(from: Date())
                var newFolder = Folder(name: "미분류", description: "기본 폴더", color: FolderPalette.unfiled, sortOrder: 1, createdAt: now)
                try newFolder.insert(db)
                if newFolder.id == nil { newFolder.id = db.lastInsertedRowID }
                folder = newFolder
            }

            // Link any orphan works to the default folder
            if let defaultId = folder.id {
                try db.execute(sql: """
                INSERT INTO folder_works (folder_id, work_id, added_at)
                SELECT ?, id, bookmarked_at FROM works
                WHERE id NOT IN (SELECT work_id FROM folder_works) ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)
                """, arguments: [defaultId])

                // Prune works from defaultFolder if they belong to other folders
                try db.execute(sql: """
                DELETE FROM folder_works
                WHERE folder_id = ?
                  AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id != ?)
                """, arguments: [defaultId, defaultId])
            }

            return folder
        }
    }

    public func syncFoldersToAppGroup() {
        guard let folders = try? listFolders() else { return }
        let payload = folders.map { [
            "id": $0.id ?? 0,
            "name": $0.name,
            "color": $0.color,
            "work_count": $0.workCount
        ] }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: AppStorage.foldersJSONURL, options: .atomic)
            if let defaults = UserDefaults(suiteName: AppStorage.appGroup) {
                defaults.set(String(data: data, encoding: .utf8), forKey: "folders_json")
            }
        }
    }

    public func listFolders() throws -> [Folder] {
        try dbWriter.read { try Self.fetchFolders($0) }
    }

    /// Reused by observations so the snapshot is fetched on the database queue.
    static func fetchFolders(_ db: Database) throws -> [Folder] {
        let sql = """
        SELECT f.*, COUNT(fw.work_id) AS work_count
        FROM folders f
        LEFT JOIN folder_works fw ON fw.folder_id = f.id
        GROUP BY f.id
        ORDER BY f.sort_order ASC, f.id ASC
        """
        let rows = try Row.fetchAll(db, sql: sql)
        let smart = Set(try fetchFolderRules(db).filter(\.isActive).map(\.folder))
        return rows.map { row in
            var folder = Folder(
                id: row["id"],
                name: row["name"],
                description: row["description"],
                color: row["color"],
                sortOrder: row["sort_order"],
                createdAt: row["created_at"],
                sourceGroupId: row["source_group_id"],
                workCount: row["work_count"]
            )
            folder.isSmart = (row["sync_id"] as String?).map(smart.contains) ?? false
            return folder
        }
    }

    public func folderPreviews(limitPerFolder: Int = 4) throws -> [Int64: [Work]] {
        try dbWriter.read { try Self.fetchFolderPreviews($0, limitPerFolder: limitPerFolder) }
    }

    /// Reused by observations so the snapshot is fetched on the database queue.
    static func fetchFolderPreviews(_ db: Database, limitPerFolder: Int = 4) throws -> [Int64: [Work]] {
        let sql = """
        WITH ranked AS (
            SELECT fw.folder_id, w.*,
                   ROW_NUMBER() OVER (
                       PARTITION BY fw.folder_id
                       ORDER BY COALESCE(NULLIF(w.bookmarked_at, ''), fw.added_at) DESC, w.id DESC
                   ) AS rn
            FROM folder_works fw
            INNER JOIN works w ON w.id = fw.work_id
        )
        SELECT * FROM ranked WHERE rn <= ?
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [limitPerFolder])
        var result: [Int64: [Work]] = [:]
        for row in rows {
            let folderId: Int64 = row["folder_id"]
            let work = try Work(row: row)
            result[folderId, default: []].append(work)
        }
        return result
    }

    public func createFolder(name: String, description: String? = nil, color: Int64? = nil, sourceGroupId: Int64? = nil) throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = try dbWriter.write { db -> Folder in
            let resolvedColor = color ?? nextUniqueFolderColor(in: db)

            // 1. Check by sourceGroupId if provided
            if let sourceGroupId, var existing = try Folder.filter(Column("source_group_id") == sourceGroupId).fetchOne(db) {
                if existing.name != trimmed && !trimmed.isEmpty {
                    try db.execute(sql: "UPDATE folders SET name = ? WHERE id = ?", arguments: [trimmed, existing.id])
                    existing.name = trimmed
                }
                return existing
            }

            // 2. Check by name
            if var existing = try Folder.filter(Folder.Columns.name == trimmed).fetchOne(db) {
                if let sourceGroupId, existing.sourceGroupId == nil {
                    try db.execute(sql: "UPDATE folders SET source_group_id = ? WHERE id = ?", arguments: [sourceGroupId, existing.id])
                    existing.sourceGroupId = sourceGroupId
                }
                return existing
            }

            let maxOrder: Int = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM folders") ?? 0
            let now = ISO8601DateFormatter().string(from: Date())
            var newFolder = Folder(
                name: trimmed,
                description: description,
                color: resolvedColor,
                sortOrder: maxOrder + 1,
                createdAt: now,
                sourceGroupId: sourceGroupId
            )
            try newFolder.insert(db)
            if newFolder.id == nil {
                newFolder.id = db.lastInsertedRowID
            }
            return newFolder
        }
        syncFoldersToAppGroup()
        return folder
    }

    public func deleteFolder(id: Int64) throws {
        try dbWriter.write { db in
            guard let folder = try Folder.fetchOne(db, key: id) else { return }
            let hasWorks = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folder_works WHERE folder_id = ?)", arguments: [id]) == true
            if folder.name == "미분류", hasWorks { throw FolderDeletionError.containsWorks }
            if let identity = try String.fetchOne(db, sql: "SELECT sync_id FROM folders WHERE id = ?", arguments: [id]) {
                try db.execute(sql: "DELETE FROM library_order WHERE key = ?", arguments: [FolderRule.keyPrefix + identity])
            }
            if !hasWorks {
                try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
                return
            }
            let defaultFolder = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = '미분류' AND id != ? LIMIT 1", arguments: [id])
                ?? Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE id != ? ORDER BY sort_order ASC, id ASC LIMIT 1", arguments: [id])
                ?? Self.unfiledFolder(in: db)
            // Works only this folder held move to Unfiled; ones another folder holds stay there.
            try db.execute(
                sql: """
                INSERT INTO folder_works (folder_id, work_id, added_at)
                SELECT ?, fw.work_id, fw.added_at FROM folder_works fw WHERE fw.folder_id = ?
                  AND NOT EXISTS (SELECT 1 FROM folder_works other WHERE other.work_id = fw.work_id AND other.folder_id != fw.folder_id)
                ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)
                """,
                arguments: [defaultFolder.id, id]
            )
            try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
        }
        syncFoldersToAppGroup()
    }

    public func renameFolder(id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE folders SET name = ? WHERE id = ?", arguments: [trimmed, id])
        }
        syncFoldersToAppGroup()
    }

    public func setFolderColor(id: Int64, color: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE folders SET color = ? WHERE id = ?", arguments: [color, id])
        }
        syncFoldersToAppGroup()
    }

    // MARK: - Works

    public func listWorks(folderId: Int64? = nil, query: String? = nil, artist: String? = nil) throws -> [Work] {
        try dbWriter.read { try Self.fetchWorks($0, folderId: folderId, query: query, artist: artist) }
    }

    /// Reused by observations so the snapshot is fetched on the database queue.
    static func fetchWorks(_ db: Database, folderId: Int64? = nil, query: String? = nil, artist: String? = nil) throws -> [Work] {
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        if let folderId {
            conditions.append("w.id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)")
            arguments.append(folderId)
        }

        if let artist, !artist.isEmpty {
            conditions.append("(w.artists LIKE ? OR w.groups LIKE ?)")
            arguments.append("%\(artist)%")
            arguments.append("%\(artist)%")
        }

        if let query {
            let search = WorkQuery(query).conditions
            if !search.sql.isEmpty {
                conditions.append(search.sql)
                arguments += search.arguments
            }
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT w.* FROM works w
        \(whereClause)
        ORDER BY w.bookmarked_at DESC, w.id DESC
        """
        var works = try Work.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        // Join the same filtered works instead of binding one parameter per work.
        // Large imported libraries can exceed SQLite's parameter limit.
        if !works.isEmpty {
            let folderSql = """
            SELECT fw.work_id, f.* FROM folders f
            INNER JOIN folder_works fw ON fw.folder_id = f.id
            INNER JOIN works w ON w.id = fw.work_id
            \(whereClause)
            ORDER BY f.sort_order ASC, f.id ASC
            """
            let rows = try Row.fetchAll(db, sql: folderSql, arguments: StatementArguments(arguments))
            var foldersByWorkId: [Int64: [Folder]] = [:]
            for row in rows {
                let workId: Int64 = row["work_id"]
                let folder = Folder(
                    id: row["id"],
                    name: row["name"],
                    description: row["description"],
                    color: row["color"],
                    sortOrder: row["sort_order"],
                    createdAt: row["created_at"],
                    sourceGroupId: row["source_group_id"],
                    workCount: 0
                )
                foldersByWorkId[workId, default: []].append(folder)
            }
            for i in works.indices {
                if let workId = works[i].id {
                    works[i].folders = foldersByWorkId[workId] ?? []
                }
            }
        }

        return works
    }

    public func getWork(galleryId: Int64) throws -> Work? {
        try dbWriter.read { db in
            guard var work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db) else {
                return nil
            }
            if let workId = work.id {
                let folderSql = """
                SELECT f.* FROM folders f
                INNER JOIN folder_works fw ON fw.folder_id = f.id
                WHERE fw.work_id = ?
                ORDER BY f.sort_order ASC
                """
                work.folders = try Folder.fetchAll(db, sql: folderSql, arguments: [workId])
            }
            return work
        }
    }

    public func upsertWork(
        galleryId: Int64,
        folderId: Int64? = nil,
        title: String? = nil,
        artists: String? = nil,
        language: String? = nil,
        type: String? = nil,
        series: String? = nil,
        groups: String? = nil,
        tags: String? = nil,
        publishedAt: String? = nil,
        bookmarkedAt: String? = nil,
        metadataSource: String? = nil,
        catalogMatched: Bool = false,
        overwriteMetadata: Bool = false,
        site: String? = nil,
        pageCount: Int? = nil,
        discoveryContext: DiscoveryContext? = nil
    ) throws -> Work {
        try dbWriter.write { db in
            let now = ISO8601DateFormatter().string(from: Date())
            var work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db)
            let wasNew = work == nil
            let lackedTags = (work?.tags ?? "").isEmpty

            if var existing = work {
                if overwriteMetadata || existing.metadataSource != "manual" {
                    if let title, !title.isEmpty { existing.title = title }
                    if let artists, !artists.isEmpty { existing.artists = artists }
                    if let language, !language.isEmpty { existing.language = language }
                    if let type, !type.isEmpty { existing.type = type }
                    if let series, !series.isEmpty { existing.series = series }
                    if let groups, !groups.isEmpty { existing.groups = groups }
                    if let tags, !tags.isEmpty { existing.tags = tags }
                    if let publishedAt, !publishedAt.isEmpty { existing.publishedAt = publishedAt }
                    if let metadataSource { existing.metadataSource = metadataSource }
                    existing.catalogMatched = catalogMatched || existing.catalogMatched
                }
                // The first site a work is known from stays its site.
                if existing.site == nil, let site, !site.isEmpty { existing.site = site }
                if let pageCount, pageCount > 0 { existing.pageCount = pageCount }
                existing.updatedAt = now
                try existing.update(db)
                work = existing
            } else {
                var newWork = Work(
                    galleryId: galleryId,
                    title: title,
                    artists: artists,
                    language: language,
                    type: type,
                    series: series,
                    groups: groups,
                    tags: tags,
                    bookmarkedAt: bookmarkedAt ?? now,
                    publishedAt: publishedAt,
                    updatedAt: now,
                    metadataSource: metadataSource,
                    catalogMatched: catalogMatched,
                    site: site?.isEmpty == true ? nil : site,
                    pageCount: pageCount.flatMap { $0 > 0 ? $0 : nil }
                )
                try newWork.insert(db)
                if newWork.id == nil {
                    newWork.id = db.lastInsertedRowID
                }
                work = newWork
            }

            // A deleted last folder is recreated only when a new save actually needs one.
            var effectiveFolderId = folderId
            if effectiveFolderId == nil, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders") == 0 {
                effectiveFolderId = try Self.unfiledFolder(in: db).id
            }
            if let folderId = effectiveFolderId {
                let resolvedWorkId = work?.id ?? (try? Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [galleryId]))
                if let workId = resolvedWorkId {
                    try db.execute(
                        sql: "INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?) ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)",
                        arguments: [folderId, workId, now]
                    )
                    // If assigned to a non-default folder, remove from default folder (미분류)
                    if let defaultId = try? Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1"), defaultId != folderId {
                        try db.execute(
                            sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?",
                            arguments: [defaultId, workId]
                        )
                    }
                }
            }

            if lackedTags, wasNew || !(work?.tags ?? "").isEmpty, let workId = work?.id {
                try Self.applyFolderRules(toWork: workId, now: now, db: db)
            }
            if wasNew, let discoveryContext { try TasteStore.record(.save, item: .comic(galleryId, tags: work?.tags), context: discoveryContext, db: db) }
            else if wasNew { try TasteStore.record(.imported, item: .comic(galleryId, tags: work?.tags), db: db) }
            else if !wasNew { try TasteStore.record(.metadata, item: .comic(galleryId, tags: work?.tags), db: db) }
            return work!
        }
    }

    public func addWorkToFolder(workId: Int64, folderId: Int64) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?) ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)",
                arguments: [folderId, workId, now]
            )
        }
    }

    public func setManualTitle(galleryId: Int64, title: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET title = ?, metadata_source = 'manual', updated_at = ? WHERE gallery_id = ?",
                arguments: [title, now, galleryId]
            )
        }
    }

    public func setNote(galleryId: Int64, note: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET note = ?, updated_at = ? WHERE gallery_id = ?",
                arguments: [note, now, galleryId]
            )
        }
    }

    public func markOpened(galleryId: Int64) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET last_opened_at = ? WHERE gallery_id = ?",
                arguments: [now, galleryId]
            )
        }
    }

    public func moveWorkToFolder(galleryId: Int64, targetFolderId: Int64, currentFolderId: Int64? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            guard let work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db),
                  let workId = work.id else { return }

            if let currentFolderId {
                try db.execute(
                    sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?",
                    arguments: [currentFolderId, workId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM folder_works WHERE work_id = ?",
                    arguments: [workId]
                )
            }

            try db.execute(
                sql: "INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?) ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)",
                arguments: [targetFolderId, workId, now]
            )
        }
    }

    public func deleteWork(galleryId: Int64) throws {
        try dbWriter.write { db in
            try TasteStore.record(.remove, item: .comic(galleryId), db: db)
            if let work = try Work.filter(Work.Columns.galleryId == galleryId).fetchOne(db), let workId = work.id {
                try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [workId])
                try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [workId])
            }
        }
    }

    public func setThumb(galleryId: Int64, status: String, path: String? = nil, page: Int? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        // Invalidate before observers receive the updated thumbnail record.
        if let path {
            LocalThumbnailCache.shared.invalidate(path: path)
        }
        try dbWriter.write { db in
            if status == "failed" || status == "gone" {
                try db.execute(
                    sql: "UPDATE works SET thumb_status = ?, thumb_failed_at = ? WHERE gallery_id = ?",
                    arguments: [status, now, galleryId]
                )
            } else if status == "ready" {
                if let page = page {
                    try db.execute(
                        sql: "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_page = ?, thumb_failed_at = NULL WHERE gallery_id = ?",
                        arguments: [status, path, page, galleryId]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_failed_at = NULL WHERE gallery_id = ?",
                        arguments: [status, path, galleryId]
                    )
                }
            } else {
                try db.execute(
                    sql: "UPDATE works SET thumb_status = ?, thumb_path = NULL WHERE gallery_id = ?",
                    arguments: [status, galleryId]
                )
            }
        }
        if status == "ready", let path {
            let store = VisualFingerprintStore(database: dbWriter)
            Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
                _ = try? await store.save(data: data, scope: "comics", id: galleryId)
            }
        }
    }

    /// Keeps a saved work's page count once a website has said it; unsaved works are left alone.
    public func fillPageCount(galleryId: Int64, count: Int?) throws {
        guard let count, count > 0 else { return }
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE works SET page_count = ? WHERE gallery_id = ? AND COALESCE(page_count, 0) != ?", arguments: [count, galleryId, count])
        }
    }

    public func setThumbPage(galleryId: Int64, page: Int) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE works SET thumb_page = ? WHERE gallery_id = ?",
                arguments: [page, galleryId]
            )
        }
    }

    /// Ready is a local-file promise, not a property that survives moving an
    /// app container. Repair old absolute paths before choosing backfill work.
    func repairThumbnailReferences(in directory: URL) throws {
        let records = try dbWriter.read { try Row.fetchAll($0, sql: "SELECT gallery_id, thumb_path FROM works WHERE thumb_status = 'ready'") }
        var changes: [(id: Int64, old: String?, recovered: String?)] = []
        for row in records {
            let id: Int64 = row["gallery_id"], old: String? = row["thumb_path"]
            if let old, AppStorage.isReadableThumbnail(URL(fileURLWithPath: old)) { continue }
            var candidates = [directory.appendingPathComponent("native_\(id).jpg")]
            if let old, !old.isEmpty { candidates.insert(directory.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent), at: 0) }
            changes.append((id, old, candidates.first(where: AppStorage.isReadableThumbnail)?.path))
        }
        guard !changes.isEmpty else { return }
        try dbWriter.write { db in
            for change in changes {
                try db.execute(sql: "UPDATE works SET thumb_status = ?, thumb_path = ?, thumb_failed_at = NULL WHERE gallery_id = ? AND thumb_status = 'ready' AND COALESCE(thumb_path, '') = ?",
                               arguments: [change.recovered == nil ? "missing" : "ready", change.recovered, change.id, change.old ?? ""])
            }
        }
        for change in changes {
            if let old = change.old { LocalThumbnailCache.shared.invalidate(path: old) }
            if let recovered = change.recovered { LocalThumbnailCache.shared.invalidate(path: recovered) }
        }
    }

    /// Empty tags need filling until the site itself has answered: some works carry no tags
    /// there, and asking again would never fill them.
    private static let needsFill = """
        (thumb_status != 'gone' AND (thumb_status IN ('missing', 'failed')
         OR (thumb_status = 'ready' AND COALESCE(thumb_path, '') = '')
         OR TRIM(COALESCE(title, '')) = ''
         OR (TRIM(COALESCE(tags, '')) = '' AND COALESCE(metadata_source, '') != 'manga')))
        """

    public func worksNeedingFill(limit: Int = 8, exclude: Set<Int64> = []) throws -> [Work] {
        try dbWriter.read { db in
            let placeholders = exclude.isEmpty ? "" : "AND gallery_id NOT IN (\(exclude.map(String.init).joined(separator: ",")))"
            let sql = """
            SELECT * FROM works WHERE \(Self.needsFill)
            \(placeholders)
            ORDER BY bookmarked_at DESC, id DESC
            LIMIT ?
            """
            return try Work.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    public func countNeedingFill(exclude: Set<Int64> = []) throws -> Int {
        let exclusions = exclude.isEmpty ? "" : " AND gallery_id NOT IN (\(exclude.map(String.init).joined(separator: ",")))"
        return try dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM works WHERE " + Self.needsFill + exclusions) ?? 0 }
    }

    // MARK: - Refresh queue

    /// Queues every saved work to be read from the site again. The queue lives in the
    /// database, so a refresh picks up where it stopped after the app closes, and a work
    /// that could not be fetched stays queued for the next run instead of being skipped.
    @discardableResult public func queueRefresh() throws -> Int {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM refresh_queue WHERE gallery_id NOT IN (SELECT gallery_id FROM works)")
            try db.execute(sql: "INSERT OR IGNORE INTO refresh_queue (gallery_id) SELECT gallery_id FROM works")
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refresh_queue") ?? 0
        }
    }

    /// Queued works, newest saves first, like the fill queue.
    public func worksAwaitingRefresh(limit: Int = 8, exclude: Set<Int64> = []) throws -> [Int64] {
        let exclusions = exclude.isEmpty ? "" : "WHERE w.gallery_id NOT IN (\(exclude.map(String.init).joined(separator: ",")))"
        return try dbWriter.read {
            try Int64.fetchAll($0, sql: """
            SELECT w.gallery_id FROM refresh_queue q JOIN works w ON w.gallery_id = q.gallery_id
            \(exclusions)
            ORDER BY w.bookmarked_at DESC, w.id DESC
            LIMIT ?
            """, arguments: [limit])
        }
    }

    public func countAwaitingRefresh() throws -> Int {
        try dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM refresh_queue q JOIN works w ON w.gallery_id = q.gallery_id") ?? 0 }
    }

    /// Takes a work off the refresh queue once the site has answered for it.
    public func finishRefresh(galleryId: Int64) throws {
        try dbWriter.write { try $0.execute(sql: "DELETE FROM refresh_queue WHERE gallery_id = ?", arguments: [galleryId]) }
    }

    /// Works the queue still has to visit: missing information, or waiting for a refresh.
    public func countPendingFill(exclude: Set<Int64> = []) throws -> Int {
        let exclusions = exclude.isEmpty ? "" : " AND gallery_id NOT IN (\(exclude.map(String.init).joined(separator: ",")))"
        return try dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM works WHERE (" + Self.needsFill + " OR gallery_id IN (SELECT gallery_id FROM refresh_queue))" + exclusions) ?? 0
        }
    }

    public func savedGalleryIDs() throws -> [Int64] {
        try dbWriter.read { try Int64.fetchAll($0, sql: "SELECT gallery_id FROM works ORDER BY bookmarked_at DESC, id DESC") }
    }

    public func worksCount() throws -> Int {
        try dbWriter.read { db in
            try Work.fetchCount(db)
        }
    }

    public func missingTitleCount() throws -> Int {
        try dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM works WHERE title IS NULL OR TRIM(title) = ''") ?? 0
        }
    }

    // MARK: - Catalog Works

    public func getCatalog(galleryId: Int64) throws -> CatalogWork? {
        try dbWriter.read { db in
            try CatalogWork.fetchOne(db, key: galleryId)
        }
    }

    public func catalogCount() throws -> Int {
        try dbWriter.read { db in
            try CatalogWork.fetchCount(db)
        }
    }

    public func listAllGalleryIds() throws -> [Int64] {
        try dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works ORDER BY id DESC")
        }
    }

    public func listGalleryIdsNeedingMetadata() throws -> [Int64] {
        try dbWriter.read { db in
            try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works WHERE title IS NULL OR title = '' OR tags IS NULL OR tags = '' OR catalog_matched = 0 ORDER BY id DESC")
        }
    }

    public func applyCatalogBatchToWorks(_ items: [CatalogWork]) throws -> Int {
        guard !items.isEmpty else { return 0 }
        let now = ISO8601DateFormatter().string(from: Date())
        return try dbWriter.write { db in
            let updateSql = """
            UPDATE works
            SET title = CASE WHEN (title IS NULL OR title = '' OR metadata_source != 'manual') THEN ? ELSE title END,
                artists = CASE WHEN (artists IS NULL OR artists = '' OR metadata_source != 'manual') THEN ? ELSE artists END,
                language = CASE WHEN (language IS NULL OR language = '' OR metadata_source != 'manual') THEN ? ELSE language END,
                type = CASE WHEN (type IS NULL OR type = '' OR metadata_source != 'manual') THEN ? ELSE type END,
                series = CASE WHEN (series IS NULL OR series = '' OR metadata_source != 'manual') THEN ? ELSE series END,
                groups = CASE WHEN (groups IS NULL OR groups = '' OR metadata_source != 'manual') THEN ? ELSE groups END,
                tags = CASE WHEN (tags IS NULL OR tags = '' OR metadata_source != 'manual') THEN ? ELSE tags END,
                published_at = CASE WHEN published_at IS NULL THEN ? ELSE published_at END,
                catalog_matched = 1,
                metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END,
                updated_at = ?
            WHERE gallery_id = ?
            """
            let updateStmt = try db.makeStatement(sql: updateSql)

            let insertCatSql = """
            INSERT OR REPLACE INTO catalog_works (id, title, type, language, artists, groups, series, characters, tags, published)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let catStmt = try db.makeStatement(sql: insertCatSql)

            var updatedCount = 0
            for item in items {
                let untagged = try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ? AND COALESCE(tags, '') = ''", arguments: [item.id])
                try updateStmt.execute(arguments: [
                    item.title,
                    item.artists,
                    item.language,
                    item.type,
                    item.series,
                    item.groups,
                    item.tags,
                    item.published,
                    now,
                    item.id
                ])
                if db.changesCount > 0 {
                    updatedCount += 1
                }
                if let untagged, !(item.tags ?? "").isEmpty { try Self.applyFolderRules(toWork: untagged, now: now, db: db) }

                try catStmt.execute(arguments: [
                    item.id,
                    item.title,
                    item.type,
                    item.language,
                    item.artists,
                    item.groups,
                    item.series,
                    item.characters,
                    item.tags,
                    item.published
                ])
            }
            return updatedCount
        }
    }

    public func upsertCatalogBatch(_ batch: [CatalogWork]) throws {
        try dbWriter.write { db in
            let sql = """
            INSERT OR REPLACE INTO catalog_works (id, title, type, language, artists, groups, series, characters, tags, published)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let statement = try db.makeStatement(sql: sql)
            for item in batch {
                try statement.execute(arguments: [
                    item.id,
                    item.title,
                    item.type,
                    item.language,
                    item.artists,
                    item.groups,
                    item.series,
                    item.characters,
                    item.tags,
                    item.published
                ])
            }
        }
    }

    public func applyCatalogToWorks() throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            let untagged = try Int64.fetchAll(db, sql: """
            SELECT w.id FROM works w JOIN catalog_works c ON c.id = w.gallery_id
            WHERE COALESCE(w.tags, '') = '' AND COALESCE(c.tags, '') != ''
              AND (w.title IS NULL OR w.metadata_source != 'manual')
            """)
            let sql = """
            UPDATE works
            SET title = (SELECT c.title FROM catalog_works c WHERE c.id = works.gallery_id),
                artists = (SELECT c.artists FROM catalog_works c WHERE c.id = works.gallery_id),
                language = (SELECT c.language FROM catalog_works c WHERE c.id = works.gallery_id),
                type = (SELECT c.type FROM catalog_works c WHERE c.id = works.gallery_id),
                series = (SELECT c.series FROM catalog_works c WHERE c.id = works.gallery_id),
                groups = (SELECT c.groups FROM catalog_works c WHERE c.id = works.gallery_id),
                tags = (SELECT c.tags FROM catalog_works c WHERE c.id = works.gallery_id),
                published_at = (SELECT c.published FROM catalog_works c WHERE c.id = works.gallery_id),
                catalog_matched = 1,
                metadata_source = CASE WHEN metadata_source = 'manual' THEN 'manual' ELSE 'catalog' END
            WHERE EXISTS (SELECT 1 FROM catalog_works c WHERE c.id = works.gallery_id)
              AND (title IS NULL OR metadata_source != 'manual')
            """
            try db.execute(sql: sql)
            for id in untagged { try Self.applyFolderRules(toWork: id, now: now, db: db) }
        }
    }

    // MARK: - Artists

    public func listArtists() throws -> [ArtistMemo] {
        try dbWriter.read { db in
            try ArtistMemo.order(ArtistMemo.Columns.name.asc).fetchAll(db)
        }
    }

    public func addFavoriteArtist(name: String, kind: Int = 0) throws -> ArtistMemo {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbWriter.write { db in
            if let existing = try ArtistMemo.filter(ArtistMemo.Columns.name == trimmed && ArtistMemo.Columns.kind == kind).fetchOne(db) {
                return existing
            }
            var artist = ArtistMemo(name: trimmed, kind: kind)
            try artist.insert(db)
            if artist.id == nil { artist.id = db.lastInsertedRowID }
            return artist
        }
    }

    public func removeFavoriteArtist(name: String, kind: Int? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbWriter.write { db in
            if let kind { try db.execute(sql: "DELETE FROM artists WHERE name = ? AND kind = ?", arguments: [trimmed, kind]) }
            else { try db.execute(sql: "DELETE FROM artists WHERE name = ?", arguments: [trimmed]) }
        }
    }
}

extension AppDatabase {
    func saveCollectionTag(_ raw: String, kind: SavedCollectionKind) throws {
        let name = kind.normalized(raw)
        guard !name.isEmpty, kind != .history else { return }
        if kind == .search {
            if try !savedSearches().contains(name) { try toggleSavedSearch(name) }
        } else if let code = kind.mangaKind {
            let exists = try listArtists().contains { $0.kind == code && SavedCollectionKind.identity($0.name) == SavedCollectionKind.identity(name) }
            if !exists { _ = try addFavoriteArtist(name: name, kind: code) }
        }
    }
}

extension AppDatabase {
    @discardableResult func toggleCollectionTag(_ raw: String, kind: SavedCollectionKind) throws -> Bool {
        let name = kind.normalized(raw)
        guard !name.isEmpty else { return false }
        if kind == .search || kind == .history {
            let saved = try savedSearches().contains(name)
            try toggleSavedSearch(name); return !saved
        }
        guard let code = kind.mangaKind else { return false }
        let matching = try listArtists().filter { $0.kind == code && SavedCollectionKind.identity($0.name) == SavedCollectionKind.identity(name) }
        if matching.isEmpty { try saveCollectionTag(name, kind: kind); return true }
        for value in matching { try removeFavoriteArtist(name: value.name, kind: code) }
        return false
    }
}

// Kept in this file so every copy of the project builds it without a new file reference.
/// Folder colors for both libraries: a fixed set of vivid colors in the order new folders take
/// them, then generated hues once a library uses every one. The color sheet offers the first ten
/// a library doesn't use yet.
enum FolderPalette {
    static let colors: [Int64] = [
        0xFF1F6BFF, // Blue
        0xFFFF3B30, // Red
        0xFF00C853, // Green
        0xFFFF9500, // Orange
        0xFF8E4BFF, // Violet
        0xFFFF2D87, // Pink
        0xFF00C2E8, // Cyan
        0xFFFFCC00, // Yellow
        0xFF4A3DFF, // Indigo
        0xFF00BFA0, // Teal
        0xFFFF6A3D, // Coral
        0xFF7CD200, // Lime
        0xFFD63CFF, // Magenta
        0xFF2FA8FF, // Sky
        0xFFFFB000, // Amber
        0xFF00A86B, // Emerald
        0xFFB026FF, // Purple
        0xFFFF4F7B, // Rose
        0xFF0047D6, // Cobalt
        0xFF2EE0B0, // Mint
        0xFFE3122C, // Crimson
        0xFF3DB500, // Leaf
        0xFFFF4FD8, // Orchid
        0xFF0090C8, // Ocean
        0xFFFF7A00, // Tangerine
        0xFF6A1BE0, // Grape
        0xFFE0006E, // Raspberry
        0xFF00897B, // Pine
        0xFFC8A000, // Gold
        0xFF2D3DB8, // Navy
        0xFF0A84FF, // Azure
        0xFF7B83FF, // Periwinkle
        0xFF00D0D0, // Turquoise
        0xFFB5651D, // Copper
        0xFF9C27B0, // Plum
        0xFF5C6B80, // Slate
    ]
    /// The comics library's Unfiled and the image library's Uncategorized folder when first made.
    static let unfiled: Int64 = 0xFF2FA8FF
    static let unsorted: Int64 = 0xFF00C853
    /// What the two default folders were made with before; sync still treats these as untouched.
    static let earlierUnfiled: Int64 = 0xFF2196F3
    static let earlierUnsorted: Int64 = 0xFF66BB70
    private static let slate: Int64 = 0xFF5C6B80
    private static let generatedCount = 512

    /// Every color earlier versions handed out on their own, each with its own replacement, so
    /// folders that differed still differ.
    static let replacements: [Int64: Int64] = [
        0xFF2196F3: 0xFF2FA8FF,
        0xFF66BB70: 0xFF00C853,
        0xFF2563EB: 0xFF1F6BFF,
        0xFF059669: 0xFF00A86B,
        0xFFEA580C: 0xFFFF6A3D,
        0xFFE11D48: 0xFFE3122C,
        0xFF7C3AED: 0xFF6A1BE0,
        0xFF0891B2: 0xFF0090C8,
        0xFFD97706: 0xFFFF7A00,
        0xFFDB2777: 0xFFE0006E,
        0xFF4F46E5: 0xFF4A3DFF,
        0xFF0D9488: 0xFF00897B,
        0xFF65A30D: 0xFF3DB500,
        0xFFC026D3: 0xFF9C27B0,
        0xFFDC2626: 0xFFFF3B30,
        0xFF9333EA: 0xFFB026FF,
        0xFF0284C7: 0xFF0A84FF,
        0xFFB45309: 0xFFB5651D,
        0xFF16A34A: 0xFF00BFA0,
        0xFFF97316: 0xFFFF9500,
        0xFF6366F1: 0xFF8E4BFF,
        0xFF14B8A6: 0xFF00D0D0,
        0xFF84CC16: 0xFF7CD200,
        0xFFEC4899: 0xFFFF2D87,
        0xFFA855F7: 0xFFD63CFF,
        0xFF3B82F6: 0xFF7B83FF,
        0xFF10B981: 0xFF2EE0B0,
        0xFFF59E0B: 0xFFFFB000,
        0xFFEF4444: 0xFFFF4F7B,
        0xFF64748B: 0xFF5C6B80,
    ]

    static func color(at index: Int) -> Int64 {
        index < colors.count ? colors[index] : generated(index - colors.count)
    }

    /// Golden-angle hues after the palette, bright enough to sit with it.
    static func generated(_ index: Int) -> Int64 {
        AppDatabase.colorFromHSV(h: (Double(index) * 0.618033988749895).truncatingRemainder(dividingBy: 1.0), s: 0.8, v: 0.95)
    }
    private static let generatedColors = Set((0..<generatedCount).map(generated))

    static func isCurrent(_ color: Int64) -> Bool { colors.contains(color) || generatedColors.contains(color) }

    /// The first `count` colors none of `used` takes, in the order new folders get them.
    static func unused(_ used: Set<Int64>, count: Int) -> [Int64] {
        var result: [Int64] = []
        var index = 0
        while result.count < count, index < colors.count + generatedCount {
            let color = color(at: index)
            if !used.contains(color) { result.append(color) }
            index += 1
        }
        return result
    }

    static func next(used: Set<Int64>) -> Int64 { unused(used, count: 1).first ?? colors[0] }

    /// A color from an earlier version, a backup, another device or another app, as the closest
    /// current color. Current colors stay as they are.
    static func vivid(_ color: Int64) -> Int64 {
        let opaque = 0xFF000000 | (color & 0xFFFFFF)
        if isCurrent(opaque) { return opaque }
        return replacements[opaque] ?? nearest(opaque)
    }

    /// New colors for a library's folder colors: earlier palette colors by the table, others by
    /// the nearest color no other folder has taken.
    static func replacing(_ colors: [Int64]) -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        var taken = Set<Int64>()
        for color in colors {
            let opaque = 0xFF000000 | (color & 0xFFFFFF)
            if isCurrent(opaque) { result[color] = opaque } else if let new = replacements[opaque] { result[color] = new }
            if let new = result[color] { taken.insert(new) }
        }
        for color in colors where result[color] == nil {
            let new = nearest(0xFF000000 | (color & 0xFFFFFF), avoiding: taken)
            result[color] = new
            taken.insert(new)
        }
        return result
    }

    /// Grays go to slate. Other colors keep their hue, made vivid, and take the closest palette
    /// color in OKLab, skipping `avoiding` while any other is left.
    static func nearest(_ color: Int64, avoiding: Set<Int64> = []) -> Int64 {
        let (lightness, a, b) = oklab(color)
        let chroma = (a * a + b * b).squareRoot()
        let free = colors.filter { !avoiding.contains($0) }
        let pool = free.isEmpty ? colors : free
        if chroma < 0.05, pool.contains(slate) || free.isEmpty { return slate }
        let target: (Double, Double, Double)
        if chroma < 0.05 {
            target = (lightness, a, b)
        } else {
            let boosted = max(chroma, 0.17) / chroma
            target = (min(max(lightness, 0.5), 0.82), a * boosted, b * boosted)
        }
        var best = pool[0], bestDistance = Double.infinity
        for candidate in pool where candidate != slate || chroma < 0.05 {
            let (l, ca, cb) = oklab(candidate)
            let distance = (l - target.0) * (l - target.0) + (ca - target.1) * (ca - target.1) + (cb - target.2) * (cb - target.2)
            if distance < bestDistance { best = candidate; bestDistance = distance }
        }
        return best
    }

    private static func oklab(_ argb: Int64) -> (Double, Double, Double) {
        func linear(_ channel: Int64) -> Double {
            let value = Double(channel & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(argb >> 16), g = linear(argb >> 8), b = linear(argb)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
