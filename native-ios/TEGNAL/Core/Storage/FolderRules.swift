import Foundation
import GRDB

/// Sends newly saved works with a tag to a folder. Rules live in `library_order`,
/// which every synced device already carries, and name folders by their sync identity.
struct FolderRule: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var folder: String
    var query: String
    var excluded = ""
    var workQuery: WorkQuery { WorkQuery(query, excluding: excluded) }
}

enum LibrarySavePreferences {
    static let defaultFolderKey = "library.defaultFolder"
    static let rulesEnabledKey = "library.folderRules"
    static var defaultFolderID: Int64 { Int64(ReaderPreferences.defaults.integer(forKey: defaultFolderKey)) }
    static var rulesEnabled: Bool { ReaderPreferences.defaults.object(forKey: rulesEnabledKey) as? Bool ?? true }
}

extension AppDatabase {
    private static let rulesKey = "folder_rules"

    static func fetchFolderRules(_ db: Database) throws -> [FolderRule] {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM library_order WHERE key = ?", arguments: [rulesKey]) else { return [] }
        return try JSONDecoder().decode([FolderRule].self, from: data)
    }

    static func storeFolderRules(_ rules: [FolderRule], db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO library_order VALUES (?, ?)", arguments: [rulesKey, try JSONEncoder().encode(rules)])
    }

    /// Rules whose folder was deleted, here or on another device, are skipped.
    static func folderID(ofRule rule: FolderRule, db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = ?", arguments: [rule.folder])
    }

    static func folderIdentity(_ id: Int64, db: Database) throws -> String {
        if let identity = try String.fetchOne(db, sql: "SELECT sync_id FROM folders WHERE id = ?", arguments: [id]) { return identity }
        let name = try String.fetchOne(db, sql: "SELECT name FROM folders WHERE id = ?", arguments: [id])
        let identity = name == "미분류" ? "unsorted" : UUID().uuidString
        try db.execute(sql: "UPDATE folders SET sync_id = ? WHERE id = ?", arguments: [identity, id])
        return identity
    }

    func folderRules() throws -> [(rule: FolderRule, folder: Folder)] {
        try dbWriter.read { db in
            let folders = try Self.fetchFolders(db)
            return try Self.fetchFolderRules(db).compactMap { rule in
                guard let id = try Self.folderID(ofRule: rule, db: db), let folder = folders.first(where: { $0.id == id }) else { return nil }
                return (rule, folder)
            }
        }
    }

    func saveFolderRule(id: String? = nil, folderID: Int64, query: String, excluded: String) throws {
        try dbWriter.write { db in
            var rules = try Self.fetchFolderRules(db)
            let rule = FolderRule(id: id ?? UUID().uuidString, folder: try Self.folderIdentity(folderID, db: db), query: query, excluded: excluded)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
            try Self.storeFolderRules(rules, db: db)
        }
    }

    func deleteFolderRule(id: String) throws {
        try dbWriter.write { db in
            try Self.storeFolderRules(try Self.fetchFolderRules(db).filter { $0.id != id }, db: db)
        }
    }

    func matchingWorkCount(_ query: WorkQuery) throws -> Int {
        guard !query.isEmpty else { return 0 }
        let (conditions, arguments) = query.conditions
        return try dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM works w WHERE \(conditions)", arguments: StatementArguments(arguments)) ?? 0 }
    }

    /// Adds saved works to a folder. Works keep their other folders, apart from Unfiled.
    func addMatchingWorks(_ query: WorkQuery, toFolder folderID: Int64) throws {
        guard !query.isEmpty else { return }
        let (conditions, arguments) = query.conditions
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            let values: [DatabaseValueConvertible] = [folderID, now] + arguments
            try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) SELECT ?, w.id, ? FROM works w WHERE \(conditions)", arguments: StatementArguments(values))
            try Self.leaveUnfiled(whenIn: folderID, db: db)
        }
    }

    private static func leaveUnfiled(whenIn folderID: Int64, db: Database) throws {
        guard let unfiled = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1"), unfiled != folderID else { return }
        try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)", arguments: [unfiled, folderID])
    }

    /// Runs once for a new save and once when its tags first arrive, so a work a
    /// person takes out of a folder stays out.
    static func applyFolderRules(toWork workID: Int64, now: String, db: Database) throws {
        guard LibrarySavePreferences.rulesEnabled else { return }
        for rule in try fetchFolderRules(db) where !rule.workQuery.isEmpty {
            guard let folderID = try folderID(ofRule: rule, db: db) else { continue }
            let (conditions, arguments) = rule.workQuery.conditions
            let values: [DatabaseValueConvertible] = [workID] + arguments
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM works w WHERE w.id = ? AND \(conditions))", arguments: StatementArguments(values)) == true else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [folderID, workID, now])
            guard let unfiled = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1"), unfiled != folderID else { continue }
            try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?", arguments: [unfiled, workID])
        }
    }

    func folderIDs(galleryId: Int64) throws -> [Int64] {
        try dbWriter.read { try Int64.fetchAll($0, sql: "SELECT fw.folder_id FROM folder_works fw JOIN works w ON w.id = fw.work_id WHERE w.gallery_id = ? ORDER BY fw.added_at", arguments: [galleryId]) }
    }

    /// Holds and quick saves land here; a folder deleted since falls back to Unfiled.
    func defaultSaveFolder() throws -> Folder {
        let folders = try listFolders()
        return try folders.first { $0.id == LibrarySavePreferences.defaultFolderID } ?? folders.first { $0.name == "미분류" } ?? folders.first ?? ensureDefaultFolder()
    }

    /// Adding a work to a real folder takes it out of Unfiled. The last folder stays.
    func setWork(galleryId: Int64, folderID: Int64, included: Bool) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            guard let workID = try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [galleryId]) else { return }
            if included {
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [folderID, workID, now])
                try Self.leaveUnfiled(whenIn: folderID, db: db)
            } else if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder_works WHERE work_id = ?", arguments: [workID]) ?? 0 > 1 {
                try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?", arguments: [folderID, workID])
            }
        }
    }
}
