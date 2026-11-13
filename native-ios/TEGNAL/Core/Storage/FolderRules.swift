import Foundation
import GRDB

/// A smart folder's rule. A folder has at most one, kept in its own row so iCloud merges
/// edits folder by folder, and folders are named by their sync identity.
struct FolderRule: Identifiable, Codable, Hashable, Sendable {
    static let keyPrefix = "folder_rule."
    var folder: String
    var query: String
    var excluded = ""
    /// Switching a rule off keeps its tags. Optional so rules saved before this still decode.
    var isEnabled: Bool?
    /// Folders the rule reads from. Absent follows wherever new saves land.
    var sources: [String]?
    /// Reads every folder, including ones made later.
    var includesOtherFolders: Bool?
    /// Comics only: a matching work also stays in the folder it came from. Rules saved before
    /// this choice existed copied, so absent reads as true; the editor always writes it.
    /// Images are in one folder at a time and always move.
    var keepsOriginal: Bool?
    var id: String { folder }
    var isActive: Bool { isEnabled != false }
    var copies: Bool { keepsOriginal ?? true }
    var workQuery: WorkQuery { WorkQuery(query, excluding: excluded) }

    /// The mark stays with the name, so every list of folders shows it.
    static func markedName(_ name: String, isSmart: Bool) -> String { isSmart ? name + "\u{00A0}✦" : name }

    /// Parsed once, because a library is scanned on every edit of the tags.
    var postMatcher: (BooruPost) -> Bool {
        guard !workQuery.isEmpty else { return { _ in false } }
        let required = BooruBlacklist(query.replacingOccurrences(of: ",", with: " "))
        let refused = BooruBlacklist(excluded.split { $0.isWhitespace || $0 == "," }.joined(separator: "\n"))
        return { required.contains($0) && !refused.contains($0) }
    }
}

struct SmartFolderChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let canBeSmart: Bool
}

/// What a smart folder needs from either library.
protocol SmartFolderLibrary {
    func folderChoices() throws -> [SmartFolderChoice]
    /// Where new saves land, which is what a rule reads unless it says otherwise.
    func defaultRuleSources() throws -> Set<String>
    func rule(forFolder id: String) throws -> FolderRule?
    func smartRules() throws -> [FolderRule]
    func matchingCount(_ rule: FolderRule) throws -> Int
    /// Saved works that match the tags but sit in folders the rule does not look in.
    func matchingCountElsewhere(_ rule: FolderRule) throws -> Int
    func createRuleFolder(named name: String) throws -> String
    func saveRule(_ rule: FolderRule) throws
    func deleteRule(forFolder id: String) throws
    func fill(_ rule: FolderRule) throws
}

enum LibrarySavePreferences {
    static let defaultFolderKey = "library.defaultFolderIdentity"
    static let legacyDefaultFolderKey = "library.defaultFolder"
    static let rulesEnabledKey = "library.folderRules"
    static var rulesEnabled: Bool { ReaderPreferences.defaults.object(forKey: rulesEnabledKey) as? Bool ?? true }

    /// Row IDs differ between devices, so an older local choice moves to the folder's identity.
    static func defaultFolderIdentity(_ db: Database, defaults: UserDefaults = ReaderPreferences.defaults) throws -> String? {
        if let identity = defaults.string(forKey: defaultFolderKey) { return identity }
        let legacy = defaults.integer(forKey: legacyDefaultFolderKey)
        guard legacy != 0, let identity = try String.fetchOne(db, sql: "SELECT sync_id FROM folders WHERE id = ?", arguments: [legacy]) else { return nil }
        defaults.set(identity, forKey: defaultFolderKey)
        defaults.removeObject(forKey: legacyDefaultFolderKey)
        return identity
    }
}

extension AppDatabase {
    private static let legacyRulesKey = "folder_rules"

    /// A row that cannot be read, say from a newer version, never blocks a save.
    static func fetchFolderRules(_ db: Database) throws -> [FolderRule] {
        try Data.fetchAll(db, sql: "SELECT value FROM library_order WHERE key GLOB ?", arguments: [FolderRule.keyPrefix + "*"])
            .compactMap { try? JSONDecoder().decode(FolderRule.self, from: $0) }
    }

    static func storeFolderRule(_ rule: FolderRule, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO library_order VALUES (?, ?)", arguments: [FolderRule.keyPrefix + rule.folder, try JSONEncoder().encode(rule)])
    }

    /// Rules used to share one synced row. The first rule of each folder is the one kept.
    static func adoptLegacyFolderRules(_ db: Database) throws {
        guard let data = try Data.fetchOne(db, sql: "SELECT value FROM library_order WHERE key = ?", arguments: [legacyRulesKey]) else { return }
        var filled = Set(try fetchFolderRules(db).map(\.folder))
        for rule in (try? JSONDecoder().decode([FolderRule].self, from: data)) ?? [] where filled.insert(rule.folder).inserted {
            try storeFolderRule(rule, db: db)
        }
        try db.execute(sql: "DELETE FROM library_order WHERE key = ?", arguments: [legacyRulesKey])
    }

    func adoptLegacyFolderRules() throws { try dbWriter.write { try Self.adoptLegacyFolderRules($0) } }

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

    func identity(ofFolder id: Int64) throws -> String {
        try dbWriter.write { try Self.folderIdentity(id, db: $0) }
    }

    func folderRules() throws -> [(rule: FolderRule, folder: Folder)] {
        try dbWriter.read { db in
            let folders = try Self.fetchFolders(db)
            let rules: [(rule: FolderRule, folder: Folder)] = try Self.fetchFolderRules(db).compactMap { rule in
                guard let id = try Self.folderID(ofRule: rule, db: db), let folder = folders.first(where: { $0.id == id }) else { return nil }
                return (rule, folder)
            }
            return rules.sorted { ($0.folder.sortOrder, $0.folder.id ?? 0) < ($1.folder.sortOrder, $1.folder.id ?? 0) }
        }
    }

    /// Unfiled and the default save folder: a work anywhere else was put there by someone.
    private static func landingFolderIDs(_ db: Database) throws -> [Int64] {
        var ids = try Int64.fetchAll(db, sql: "SELECT id FROM folders WHERE name = '미분류'")
        if let identity = try LibrarySavePreferences.defaultFolderIdentity(db),
           let id = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = ?", arguments: [identity]) { ids.append(id) }
        return ids
    }

    /// Which works a rule may take, over `works` aliased as `w`.
    private static func sourceCondition(_ rule: FolderRule, db: Database) throws -> String? {
        if rule.includesOtherFolders == true { return nil }
        func list(_ ids: [Int64]) -> String { ids.map(String.init).joined(separator: ",") }
        guard rule.sources != nil else {
            return "NOT EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id NOT IN (\(list(try landingFolderIDs(db)))))"
        }
        return "EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id IN (\(list(try sourceFolderIDs(rule, db: db)))))"
    }

    /// The folders a rule looks in, never its own: where a moving rule takes works from.
    private static func sourceFolderIDs(_ rule: FolderRule, db: Database) throws -> [Int64] {
        let own = try folderID(ofRule: rule, db: db)
        let ids: [Int64]
        if rule.includesOtherFolders == true { ids = try Int64.fetchAll(db, sql: "SELECT id FROM folders") }
        else if let sources = rule.sources {
            let marks = sources.map { _ in "?" }.joined(separator: ",")
            ids = sources.isEmpty ? [] : try Int64.fetchAll(db, sql: "SELECT id FROM folders WHERE sync_id IN (\(marks))", arguments: StatementArguments(sources))
        } else { ids = try landingFolderIDs(db) }
        return ids.filter { $0 != own }
    }

    private static func matching(_ rule: FolderRule, db: Database) throws -> (sql: String, arguments: [DatabaseValueConvertible]) {
        let (conditions, arguments) = rule.workQuery.conditions
        return (try sourceCondition(rule, db: db).map { "\(conditions) AND \($0)" } ?? conditions, arguments)
    }

    func matchingWorkCount(_ rule: FolderRule) throws -> Int {
        guard !rule.workQuery.isEmpty else { return 0 }
        return try dbWriter.read { db in
            let (conditions, arguments) = try Self.matching(rule, db: db)
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM works w WHERE \(conditions)", arguments: StatementArguments(arguments)) ?? 0
        }
    }

    func matchingWorkCountElsewhere(_ rule: FolderRule) throws -> Int {
        guard !rule.workQuery.isEmpty, rule.includesOtherFolders != true else { return 0 }
        return try dbWriter.read { db in
            let (conditions, arguments) = rule.workQuery.conditions
            guard let source = try Self.sourceCondition(rule, db: db) else { return 0 }
            let own = try Self.folderID(ofRule: rule, db: db) ?? -1
            let sql = "SELECT COUNT(*) FROM works w WHERE \(conditions) AND NOT (\(source)) AND NOT EXISTS (SELECT 1 FROM folder_works fw WHERE fw.work_id = w.id AND fw.folder_id = ?)"
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments + [own])) ?? 0
        }
    }

    /// Files saved works in a folder. A copying rule leaves them where they were too; a moving
    /// rule takes them out of the folders it looked in. Either way they leave Unfiled.
    func addMatchingWorks(_ rule: FolderRule, toFolder folderID: Int64) throws {
        guard !rule.workQuery.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            let (conditions, arguments) = try Self.matching(rule, db: db)
            let matched = try Int64.fetchAll(db, sql: "SELECT w.id FROM works w WHERE \(conditions)", arguments: StatementArguments(arguments))
            for workID in matched {
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [folderID, workID, now])
            }
            if !rule.copies {
                let sources = try Self.sourceFolderIDs(rule, db: db).filter { $0 != folderID }
                if !sources.isEmpty {
                    for workID in matched {
                        try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ? AND folder_id IN (\(sources.map(String.init).joined(separator: ",")))", arguments: [workID])
                    }
                }
            }
            try Self.leaveUnfiled(whenIn: folderID, db: db)
        }
    }

    private static func leaveUnfiled(whenIn folderID: Int64, db: Database) throws {
        guard let unfiled = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE name = '미분류' ORDER BY sort_order ASC, id ASC LIMIT 1"), unfiled != folderID else { return }
        try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id IN (SELECT work_id FROM folder_works WHERE folder_id = ?)", arguments: [unfiled, folderID])
    }

    /// Runs once for a new save and once when its tags first arrive, so a work a person
    /// moves stays where they put it, whether or not it fits the folder's tags.
    /// Every copying rule that matches adds the work; the first moving rule in folder order
    /// takes it out of where it was, and later moving rules leave it alone.
    static func applyFolderRules(toWork workID: Int64, now: String, db: Database) throws {
        guard LibrarySavePreferences.rulesEnabled else { return }
        let order = try String.fetchAll(db, sql: "SELECT sync_id FROM folders WHERE sync_id IS NOT NULL ORDER BY sort_order, id")
        // Read once, or the first match would hide the work from every later rule.
        let rules = try fetchFolderRules(db).filter { rule in
            guard rule.isActive, !rule.workQuery.isEmpty else { return false }
            guard let source = try sourceCondition(rule, db: db) else { return true }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM works w WHERE w.id = ? AND \(source))", arguments: [workID]) == true
        }.sorted { (order.firstIndex(of: $0.folder) ?? .max) < (order.firstIndex(of: $1.folder) ?? .max) }
        let before = Set(try Int64.fetchAll(db, sql: "SELECT folder_id FROM folder_works WHERE work_id = ?", arguments: [workID]))
        var moved = false
        for rule in rules where rule.copies || !moved {
            guard let folderID = try folderID(ofRule: rule, db: db) else { continue }
            let (conditions, arguments) = rule.workQuery.conditions
            let values: [DatabaseValueConvertible] = [workID] + arguments
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM works w WHERE w.id = ? AND \(conditions))", arguments: StatementArguments(values)) == true else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [folderID, workID, now])
            if !rule.copies {
                moved = true
                // Only folders it was in before, so a copy another smart folder just made stays.
                for source in try sourceFolderIDs(rule, db: db) where source != folderID && before.contains(source) {
                    try db.execute(sql: "DELETE FROM folder_works WHERE folder_id = ? AND work_id = ?", arguments: [source, workID])
                }
            }
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
        let chosen = try dbWriter.read { db in
            try LibrarySavePreferences.defaultFolderIdentity(db).flatMap { try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = ?", arguments: [$0]) }
        }
        return try folders.first { $0.id == chosen } ?? folders.first { $0.name == "미분류" } ?? folders.first ?? ensureDefaultFolder()
    }

    /// Adding a work to a real folder takes it out of Unfiled.
    func addWork(galleryId: Int64, folderID: Int64) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbWriter.write { db in
            guard let workID = try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [galleryId]) else { return }
            try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [folderID, workID, now])
            try Self.leaveUnfiled(whenIn: folderID, db: db)
        }
    }

    /// For merges, which can bring a work's Unfiled membership along with real folders.
    static func leaveUnfiled(workID: Int64, db: Database) throws {
        try db.execute(sql: """
        DELETE FROM folder_works
        WHERE work_id = ? AND folder_id IN (SELECT id FROM folders WHERE name = '미분류')
          AND EXISTS (SELECT 1 FROM folder_works fw JOIN folders f ON f.id = fw.folder_id WHERE fw.work_id = ? AND f.name != '미분류')
        """, arguments: [workID, workID])
    }
}

extension AppDatabase: SmartFolderLibrary {
    func folderChoices() throws -> [SmartFolderChoice] {
        try dbWriter.write { db in
            try Self.fetchFolders(db).compactMap { folder in
                guard let id = folder.id else { return nil }
                return SmartFolderChoice(id: try Self.folderIdentity(id, db: db), name: folder.displayName, canBeSmart: folder.name != "미분류")
            }
        }
    }

    func defaultRuleSources() throws -> Set<String> {
        try dbWriter.write { db in Set(try Self.landingFolderIDs(db).map { try Self.folderIdentity($0, db: db) }) }
    }

    func rule(forFolder id: String) throws -> FolderRule? {
        try dbWriter.read { try Self.fetchFolderRules($0).first { $0.folder == id } }
    }

    func smartRules() throws -> [FolderRule] { try folderRules().map(\.rule) }
    func matchingCount(_ rule: FolderRule) throws -> Int { try matchingWorkCount(rule) }
    func matchingCountElsewhere(_ rule: FolderRule) throws -> Int { try matchingWorkCountElsewhere(rule) }

    func createRuleFolder(named name: String) throws -> String {
        guard let id = try createFolder(name: name).id else { throw BooruError.storage }
        return try identity(ofFolder: id)
    }

    func saveRule(_ rule: FolderRule) throws {
        try dbWriter.write { try Self.storeFolderRule(rule, db: $0) }
    }

    func deleteRule(forFolder id: String) throws {
        try dbWriter.write { try $0.execute(sql: "DELETE FROM library_order WHERE key = ?", arguments: [FolderRule.keyPrefix + id]) }
    }

    func fill(_ rule: FolderRule) throws {
        guard let id = try dbWriter.read({ try Self.folderID(ofRule: rule, db: $0) }) else { return }
        try addMatchingWorks(rule, toFolder: id)
    }
}

extension BooruStore: SmartFolderLibrary {
    static func fetchFolderRules(_ db: Database) throws -> [FolderRule] {
        try String.fetchAll(db, sql: "SELECT value FROM settings WHERE key GLOB ?", arguments: [FolderRule.keyPrefix + "*"])
            .compactMap { try? JSONDecoder().decode(FolderRule.self, from: Data($0.utf8)) }
    }

    static func storeFolderRule(_ rule: FolderRule, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [FolderRule.keyPrefix + rule.folder, String(decoding: JSONEncoder().encode(rule), as: UTF8.self)])
    }

    /// New favorites land in their site's folder, or Uncategorized.
    private static func isLanding(_ folder: String) -> Bool { folder == "unsorted" || folder.hasPrefix("site:") }

    private static func rule(_ rule: FolderRule, reads folder: String) -> Bool {
        guard folder != rule.folder else { return false }
        if rule.includesOtherFolders == true { return true }
        return rule.sources?.contains(folder) ?? isLanding(folder)
    }

    /// An image is in one folder, so the first matching smart folder takes it. Only new
    /// favorites come through here, so an image a person moves stays where they put it.
    static func smartDestination(for post: BooruPost, landing folder: String, db: Database) throws -> String {
        guard LibrarySavePreferences.rulesEnabled else { return folder }
        let rules = try fetchFolderRules(db).filter { $0.isActive && rule($0, reads: folder) }
        guard !rules.isEmpty else { return folder }
        for id in try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name") {
            if let match = rules.first(where: { $0.folder == id }), match.postMatcher(post) { return id }
        }
        return folder
    }

    private func matches(_ rule: FolderRule) -> [BooruPost] {
        let matcher = rule.postMatcher
        return favoriteRecords().compactMap { Self.rule(rule, reads: $0.folderID) && matcher($0.post) ? $0.post : nil }
    }

    func folderChoices() throws -> [SmartFolderChoice] {
        folders().map { SmartFolderChoice(id: $0.id, name: $0.displayName, canBeSmart: $0.id != "unsorted") }
    }

    func defaultRuleSources() throws -> Set<String> { Set(folders().map(\.id).filter(Self.isLanding)) }

    func rule(forFolder id: String) throws -> FolderRule? {
        try database.read { try Self.fetchFolderRules($0).first { $0.folder == id } }
    }

    func smartRules() throws -> [FolderRule] {
        let rules = try database.read { try Self.fetchFolderRules($0) }
        return folders().compactMap { folder in rules.first { $0.folder == folder.id } }
    }

    func matchingCount(_ rule: FolderRule) throws -> Int { matches(rule).count }
    func matchingCountElsewhere(_ rule: FolderRule) throws -> Int {
        let matcher = rule.postMatcher
        return favoriteRecords().filter { $0.folderID != rule.folder && !Self.rule(rule, reads: $0.folderID) && matcher($0.post) }.count
    }
    func createRuleFolder(named name: String) throws -> String { try saveFolder(name: name) }

    func saveRule(_ rule: FolderRule) throws {
        try setSetting(FolderRule.keyPrefix + rule.folder, value: String(decoding: JSONEncoder().encode(rule), as: UTF8.self))
    }

    func deleteRule(forFolder id: String) throws { try removeSetting(FolderRule.keyPrefix + id) }
    func fill(_ rule: FolderRule) throws { try moveFavorites(matches(rule), folderID: rule.folder) }
}
