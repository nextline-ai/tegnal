import Foundation
import GRDB

/// Cheap change tokens avoid re-decoding the entire library on idle sync polls.
/// Read on the writer connection: total_changes is connection-local, while
/// data_version also detects edits from the share extension or another connection.
@MainActor
final class LibrarySyncSnapshotCache {
    private struct DatabaseVersion: Equatable {
        let identity: ObjectIdentifier
        let local: Int64
        let external: Int64
    }
    private struct Signature: Equatable {
        let manga: DatabaseVersion
        let booru: DatabaseVersion
        let preferences: [String: Data]
    }
    private var signature: Signature?
    private var rows: [String: LibrarySyncRow] = [:]
    private(set) var snapshotCount = 0

    func snapshot(_ adapter: LibrarySyncAdapter) throws -> [String: LibrarySyncRow] {
        let before = try signature(for: adapter)
        if signature == before { return rows }
        let next = try adapter.snapshot()
        snapshotCount += 1
        let after = try signature(for: adapter)
        // A concurrent database edit must be read by the next pass.
        signature = before == after ? after : nil
        rows = next
        return next
    }

    func invalidate() { signature = nil; rows.removeAll() }

    private func signature(for adapter: LibrarySyncAdapter) throws -> Signature {
        func version(_ writer: any DatabaseWriter) throws -> DatabaseVersion {
            try writer.writeWithoutTransaction { db in
                .init(identity: ObjectIdentifier(writer),
                      local: try Int64.fetchOne(db, sql: "SELECT total_changes()") ?? 0,
                      external: try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0)
            }
        }
        var preferences: [String: Data] = [:]
        for (mode, defaults, keys) in [("manga", adapter.mangaDefaults, LibrarySyncAdapter.commonPreferences + [RecentWorks.key]),
                                       ("booru", adapter.booruDefaults, LibrarySyncAdapter.booruPreferences + [RecentImages.key])] {
            for key in keys {
                if let value = defaults.object(forKey: key) {
                    preferences[mode + ":" + key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
                }
            }
        }
        return try .init(manga: version(adapter.manga.dbWriter), booru: version(adapter.booru.database), preferences: preferences)
    }
}

/// Explicit allowlists keep caches, API keys, cookies, onboarding and device layout local.
struct LibrarySyncAdapter {
    let manga: AppDatabase
    let booru: BooruStore
    let mangaDefaults: UserDefaults
    let booruDefaults: UserDefaults
    static let commonPreferences = ["site_verified", "app.language", "app_theme", "booru.app_theme", "manga.defaultTags", "manga.defaultExcludedTags", "manga.artistLanguage", "manga.tagLanguage", "search.retentionDays", "search.rememberHistory", "reader.translationLanguage", LibrarySavePreferences.defaultFolderKey, LibrarySavePreferences.rulesEnabledKey, RecentWorks.limitKey]
    static let booruPreferences = ["search.retentionDays", "reader.translationLanguage", "booru.rememberHistory", "booru.showNotes", RecentImages.limitKey]
    static let columns: [String: [String]] = [
        "manga.library_order": ["key", "value"],
        "manga.folders": ["sync_id", "name", "description", "color", "sort_order", "created_at", "source_group_id"],
        "manga.works": workColumns,
        // Further works under a number already saved from another website. Older versions,
        // which keep one work per number, leave this table alone.
        "manga.work_variants": workColumns,
        "manga.folder_works": ["folder_id", "work_id", "added_at", "work_site"],
        "manga.artists": ["name", "kind", "note", "bookmarked_at"],
        "manga.search_history": ["query", "used_at"], "manga.saved_searches": ["query"],
        "booru.challenges": ["id", "payload"],
        "booru.servers": ["id", "payload", "position"], "booru.folders": ["id", "name", "color", "position"],
        "booru.favorites": ["server_id", "post_id", "payload", "saved_at", "folder_id"],
        "booru.history": ["server_id", "query", "used_at"], "booru.saved_tags": ["server_id", "name", "kind"],
        "booru.settings": ["key", "value"]
    ]
    static let workColumns = ["gallery_id", "title", "artists", "language", "type", "series", "groups", "tags", "note", "bookmarked_at", "published_at", "metadata_source", "catalog_matched", "thumb_page", "site"]
    /// Columns a peer that does not know the value yet sends empty: they fill in, never clear.
    static let keepsKnownValue: Set<String> = ["site"]

    private func assignFolderIdentities() throws {
        // Also assigns identities to legacy imports and share-extension-created folders.
        try manga.dbWriter.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, name FROM folders WHERE sync_id IS NULL") {
                let name: String = row["name"]
                try db.execute(sql: "UPDATE folders SET sync_id = ? WHERE id = ?", arguments: [name == "미분류" ? "unsorted" : UUID().uuidString, row["id"] as Int64])
            }
            _ = try LibrarySavePreferences.defaultFolderIdentity(db, defaults: mangaDefaults)
        }
    }

    /// Image settings stay local unless they describe the library itself.
    private static func travelsUnchanged(_ key: String?) -> Bool { key == "folder_order" || key?.hasPrefix(FolderRule.keyPrefix) == true }

    func snapshot() throws -> [String: LibrarySyncRow] {
        try assignFolderIdentities()
        var rows = try manga.dbWriter.read { db -> [LibrarySyncRow] in
            var result: [LibrarySyncRow] = []
            for (table, columns) in Self.columns where table.hasPrefix("manga.") {
                let local = String(table.dropFirst(6))
                let primary = WorkIdentity.primaryCondition
                let sql = switch local {
                // A link names its work by number, as older versions read it, and by website.
                case "folder_works": """
                    SELECT f.sync_id AS folder_id, CASE WHEN \(primary) THEN w.gallery_id ELSE w.gallery_id || '@' || w.site END AS work_id,
                           fw.added_at, w.site AS work_site
                    FROM folder_works fw JOIN folders f ON f.id = fw.folder_id JOIN works w ON w.id = fw.work_id
                    """
                case "works": "SELECT \(columns.map { "w." + $0 }.joined(separator: ",")) FROM works w WHERE \(primary)"
                case "work_variants": "SELECT \(columns.map { "w." + $0 }.joined(separator: ",")) FROM works w WHERE NOT (\(primary))"
                default: "SELECT \(columns.joined(separator: ",")) FROM \(local)"
                }
                result += try Row.fetchAll(db, sql: sql).map { row in
                    var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, SyncValue(row[$0] as DatabaseValue)) })
                    // Links to a work whose website is unknown stay as older versions wrote them.
                    if local == "folder_works", values["work_site"] == .null { values["work_site"] = nil }
                    return LibrarySyncRow(table: table, values: values)
                }
            }
            return result
        }
        rows += try booru.database.read { db -> [LibrarySyncRow] in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            let addresses = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.canonicalAddress) })
            var result: [LibrarySyncRow] = []
            for (table, columns) in Self.columns where table.hasPrefix("booru.") {
                let local = String(table.dropFirst(6))
                for row in try Row.fetchAll(db, sql: "SELECT \(columns.joined(separator: ",")) FROM \(local)") {
                    var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, SyncValue(row[$0] as DatabaseValue)) })
                    if local == "servers", let raw = values["payload"]?.data {
                        var server = try JSONDecoder().decode(BooruServer.self, from: raw)
                        server.id = server.canonicalAddress
                        values["id"] = .text(server.id); values["payload"] = .blob(try Self.encode(server))
                    }
                    if let id = values["server_id"]?.string, let address = addresses[id] {
                        values["server_id"] = .text(address)
                        if let raw = values["payload"]?.data {
                            let post = try JSONDecoder().decode(BooruPost.self, from: raw).onServer(address).cloudMetadata
                            values["payload"] = .blob(try Self.encode(post))
                        }
                    }
                    if local == "settings", !Self.travelsUnchanged(values["key"]?.string) {
                        guard let key = values["key"]?.string, key.hasPrefix("blacklist."), let address = addresses[String(key.dropFirst(10))] else { continue }
                        values["key"] = .text("blacklist." + address)
                    }
                    result.append(.init(table: table, values: values))
                }
            }
            // One row per recently opened image, so opens on two devices merge. A server that
            // is no longer in the list cannot place its image on another device.
            for entry in RecentImage.stored(in: booruDefaults) {
                guard let address = addresses[entry.post.serverID] else { continue }
                let post = entry.post.onServer(address).cloudMetadata
                result.append(.init(table: "recent.images", values: ["server_id": .text(address), "post_id": .integer(post.postID),
                                                                     "payload": .blob(try Self.encode(RecentImage(post: post, openedAt: entry.openedAt)))]))
            }
            return result
        }
        for entry in RecentWork.stored(in: mangaDefaults) {
            rows.append(.init(table: "recent.works", values: ["id": .integer(entry.id), "payload": .blob(try Self.encode(entry))]))
        }
        for (mode, defaults, keys) in [("manga", mangaDefaults, Self.commonPreferences), ("booru", booruDefaults, Self.booruPreferences)] {
            for key in keys {
                if let value = defaults.object(forKey: key) {
                    let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
                    rows.append(.init(table: "preferences." + mode, values: ["key": .text(key), "value": .blob(data)]))
                }
            }
        }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Normalize old peer records as well as new snapshots before re-uploading them.
    static func mediaFreeChanges(_ changes: [String: LibrarySyncChange]) throws -> [String: LibrarySyncChange] {
        try changes.mapValues { change in
            if change.row.table == "manga.folders" {
                var row = change.row
                row.values = MangaImportMetadata.normalized(row.values)
                return .init(row: row, timestamp: change.timestamp, device: change.device, deleted: change.deleted)
            }
            guard !change.deleted, ["booru.favorites", "recent.images"].contains(change.row.table),
                  let data = change.row.values["payload"]?.data else { return change }
            var row = change.row
            if change.row.table == "recent.images" {
                var entry = try JSONDecoder().decode(RecentImage.self, from: data)
                entry.post = entry.post.cloudMetadata
                row.values["payload"] = .blob(try encode(entry))
            } else {
                row.values["payload"] = .blob(try encode(JSONDecoder().decode(BooruPost.self, from: data).cloudMetadata))
            }
            return .init(row: row, timestamp: change.timestamp, device: change.device, deleted: change.deleted)
        }
    }

    func apply(_ changes: [String: LibrarySyncChange]) throws {
        try assignFolderIdentities()
        let values = Array(changes.values)
        try manga.dbWriter.write { db in
            // Remove dependent links before parents; never replace a whole database.
            for table in ["folder_works", "artists", "work_variants", "works", "folders", "search_history", "saved_searches", "library_order"] {
                for change in values where change.deleted && change.row.table == "manga." + table {
                    var row = change.row
                    if table == "works" || table == "work_variants" {
                        if let work = try Self.localWork(row.values, variant: table == "work_variants", db) { try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [work.id]) }
                        continue
                    }
                    if table == "folders", row.values["sync_id"]?.string == "unsorted",
                       try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folder_works JOIN folders ON folders.id = folder_works.folder_id WHERE folders.sync_id = 'unsorted')") == true { continue }
                    if table == "folder_works" {
                        guard let folder = try localFolder(row.values["folder_id"], db), let work = try localWork(row.values["work_id"], site: row.values["work_site"], db) else { continue }
                        row.values["folder_id"] = .integer(folder); row.values["work_id"] = .integer(work); row.values["work_site"] = nil
                    }
                    try Self.delete(row, db: db)
                }
            }
            for table in ["folders", "works", "work_variants", "artists", "folder_works", "search_history", "saved_searches", "library_order"] {
                for change in values.sorted(by: { $0.row.key < $1.row.key }) where !change.deleted && change.row.table == "manga." + table {
                    var row = change.row
                    if table == "folders", let uid = row.values["sync_id"]?.string, let name = row.values["name"]?.string {
                        if let conflict = try String.fetchOne(db, sql: "SELECT sync_id FROM folders WHERE name = ?", arguments: [name]), conflict != uid {
                            row.values["name"] = .text(name + " (" + String(uid.prefix(8)) + ")")
                        }
                    }
                    if table == "works" || table == "work_variants" { try Self.applyWork(row.values, variant: table == "work_variants", db: db); continue }
                    if table == "folder_works" {
                        guard let folder = try localFolder(row.values["folder_id"], db), let work = try localWork(row.values["work_id"], site: row.values["work_site"], db) else { continue }
                        row.values["folder_id"] = .integer(folder); row.values["work_id"] = .integer(work); row.values["work_site"] = nil
                    }
                    try Self.upsert(row, db: db)
                }
            }
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM library_order WHERE key = 'folders'"), let order = try? JSONDecoder().decode([String].self, from: data) {
                let others = try String.fetchAll(db, sql: "SELECT sync_id FROM folders ORDER BY sort_order, id").filter { !order.contains($0) }
                for (position, uid) in (order + others).enumerated() { try db.execute(sql: "UPDATE folders SET sort_order = ? WHERE sync_id = ?", arguments: [position, uid]) }
            }
            // Concurrent folder deletion cannot orphan an independently saved work.
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM works WHERE id NOT IN (SELECT work_id FROM folder_works))") == true {
                let unfiled = try AppDatabase.unfiledFolder(in: db).id!
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works SELECT ?, id, bookmarked_at FROM works WHERE id NOT IN (SELECT work_id FROM folder_works)", arguments: [unfiled])
            }
        }
        try booru.database.write { db in
            var servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var mapping = Dictionary(servers.map { ($0.canonicalAddress, $0.id) }, uniquingKeysWith: { a, _ in a })
            for change in values where change.row.table == "booru.servers" {
                guard let address = change.row.values["id"]?.string else { continue }
                if change.deleted {
                    if let id = mapping[address] {
                        for table in ["favorites", "history", "saved_tags"] { try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [id]) }
                        try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [id])
                        mapping.removeValue(forKey: address)
                    }
                } else if let data = change.row.values["payload"]?.data {
                    var server = try JSONDecoder().decode(BooruServer.self, from: data)
                    _ = try BooruServer.validatedURL(server.baseURL.absoluteString)
                    guard server.canonicalAddress == address else { throw BooruError.invalidServer }
                    server.id = mapping[address] ?? UUID().uuidString
                    mapping[address] = server.id
                    var row = change.row; row.values["id"] = .text(server.id); row.values["payload"] = .blob(try Self.encode(server))
                    try Self.upsert(row, db: db)
                }
            }
            servers.removeAll()
            for table in ["folders", "favorites", "history", "saved_tags", "settings", "challenges"] {
                for change in values where change.row.table == "booru." + table {
                    var row = change.row
                    if table == "folders", row.values["id"]?.string == "unsorted", change.deleted { continue }
                    if let address = row.values["server_id"]?.string {
                        guard let id = mapping[address] else { continue }
                        row.values["server_id"] = .text(id)
                        if let data = row.values["payload"]?.data {
                            row.values["payload"] = .blob(try Self.encode(JSONDecoder().decode(BooruPost.self, from: data).onServer(id)))
                        }
                    }
                    if table == "settings", !Self.travelsUnchanged(row.values["key"]?.string) {
                        guard let key = row.values["key"]?.string, key.hasPrefix("blacklist."), let id = mapping[String(key.dropFirst(10))] else { continue }
                        row.values["key"] = .text("blacklist." + id)
                    }
                    if table == "challenges", !change.deleted {
                        guard let data = row.values["payload"]?.data, data.count <= ChallengeBackup.maximumBytes else { throw ChallengeError.unsupported }
                        let game = try JSONDecoder().decode(ChallengeDefinition.self, from: data)
                        try game.validate()
                        guard game.id == row.values["id"]?.string else { throw ChallengeError.invalid("Challenges") }
                    }
                    if change.deleted {
                        if table == "challenges", let id = row.values["id"]?.string {
                            try db.execute(sql: "DELETE FROM challenge_sessions WHERE id = ?", arguments: [id])
                        }
                        if table == "folders", let id = row.values["id"]?.string {
                            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE folder_id = ?)", arguments: [id]) == true {
                                try BooruStore.ensureUnsorted(in: db)
                                try db.execute(sql: "UPDATE favorites SET folder_id = 'unsorted' WHERE folder_id = ?", arguments: [id])
                            }
                        }
                        try Self.delete(row, db: db)
                    } else {
                        if table == "favorites", let id = row.values["folder_id"]?.string, try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [id]) == nil {
                            try BooruStore.ensureUnsorted(in: db)
                            row.values["folder_id"] = .text("unsorted")
                        }
                        try Self.upsert(row, db: db)
                    }
                }
            }
            // Apply default-folder deletion after favorite changes; concurrent saves take precedence.
            if values.contains(where: { $0.deleted && $0.row.table == "booru.folders" && $0.row.values["id"]?.string == "unsorted" }) {
                try db.execute(sql: "DELETE FROM folders WHERE id = 'unsorted' AND NOT EXISTS(SELECT 1 FROM favorites WHERE folder_id = 'unsorted')")
            }
            if let text = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'folder_order'"), let order = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
                let others = try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name").filter { !order.contains($0) }
                for (position, id) in (order + others).enumerated() { try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [position, id]) }
            }
        }
        booru.invalidateSnapshots()
        for change in values where change.row.table.hasPrefix("preferences.") {
            let isBooru = change.row.table == "preferences.booru"
            guard let key = change.row.values["key"]?.string, (isBooru ? Self.booruPreferences : Self.commonPreferences).contains(key) else { continue }
            let defaults = isBooru ? booruDefaults : mangaDefaults
            if change.deleted { defaults.removeObject(forKey: key) }
            else if let data = change.row.values["value"]?.data, let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { defaults.set(plist["value"], forKey: key) }
        }
        try applyRecents(values)
    }

    /// Recent lists live in each mode's settings, not a database. Rows merge one entry at a
    /// time; the synced count then keeps the newest ones, as on the device that opened them.
    private func applyRecents(_ values: [LibrarySyncChange]) throws {
        let works = values.filter { $0.row.table == "recent.works" }
        if !works.isEmpty {
            var entries = Dictionary(RecentWork.stored(in: mangaDefaults).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for change in works {
                guard let id = change.row.values["id"]?.integer else { continue }
                if change.deleted { entries[id] = nil; continue }
                guard let data = change.row.values["payload"]?.data, let entry = try? JSONDecoder().decode(RecentWork.self, from: data), entry.id == id else { continue }
                entries[id] = entry
            }
            Self.storeRecents(RecentWork.merged(Array(entries.values), limit: RecentLimit.stored(RecentWorks.limitKey, in: mangaDefaults)),
                              key: RecentWorks.key, in: mangaDefaults)
        }
        let images = values.filter { $0.row.table == "recent.images" }
        if !images.isEmpty {
            let servers = try booru.database.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            }
            var mapping: [String: String] = [:]
            for server in servers where mapping[server.canonicalAddress] == nil { mapping[server.canonicalAddress] = server.id }
            var entries = Dictionary(RecentImage.stored(in: booruDefaults).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for change in images {
                guard let address = change.row.values["server_id"]?.string, let postID = change.row.values["post_id"]?.integer,
                      let server = mapping[address] else { continue }
                let id = "\(server):\(postID)"
                if change.deleted { entries[id] = nil; continue }
                guard let data = change.row.values["payload"]?.data, var entry = try? JSONDecoder().decode(RecentImage.self, from: data),
                      entry.post.postID == postID else { continue }
                entry.post = entry.post.onServer(server)
                entries[id] = entry
            }
            Self.storeRecents(RecentImage.merged(Array(entries.values), limit: RecentLimit.stored(RecentImages.limitKey, in: booruDefaults)),
                              key: RecentImages.key, in: booruDefaults)
        }
    }
    private static func storeRecents<T: Codable & Equatable>(_ entries: [T], key: String, in defaults: UserDefaults) {
        let current = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([T].self, from: $0) } ?? []
        guard current != entries else { return }
        if entries.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
    private func localFolder(_ value: SyncValue?, _ db: Database) throws -> Int64? {
        guard let uid = value?.string else { return nil }
        return try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE sync_id = ?", arguments: [uid])
    }
    /// A link's work: its number (as text with its website, for further works under one
    /// number) and the website, which older versions leave out.
    private func localWork(_ value: SyncValue?, site: SyncValue?, _ db: Database) throws -> Int64? {
        var number = value?.integer, website = site?.string
        if number == nil, let text = value?.string, let separator = text.firstIndex(of: "@") {
            number = Int64(text[..<separator]); website = website ?? String(text[text.index(after: separator)...])
        }
        guard let number else { return nil }
        let rows = try WorkIdentity.rows(db, galleryId: number)
        if let website, !website.isEmpty { return WorkIdentity.pick(rows, site: website)?.id }
        // A link without a website: to the work whose website is unknown, as newer versions send
        // it, else to the one the number alone names, as older versions do.
        return (rows.first { $0.site == nil } ?? WorkIdentity.primary(rows))?.id
    }

    /// The saved work a synced work row names: the one from its website (one whose website is
    /// unknown takes it). Without a website, a number row names the one whose website is
    /// unknown, else the one the number alone names, as older versions mean it; a further
    /// work row only the one whose website is unknown.
    private static func localWork(_ values: [String: SyncValue], variant: Bool, _ db: Database) throws -> Work? {
        guard let number = values["gallery_id"]?.integer else { return nil }
        let rows = try WorkIdentity.rows(db, galleryId: number)
        if let site = values["site"]?.string, !site.isEmpty { return WorkIdentity.pick(rows, site: site) }
        return rows.first { $0.site == nil } ?? (variant ? nil : WorkIdentity.primary(rows))
    }

    private static func applyWork(_ values: [String: SyncValue], variant: Bool, db: Database) throws {
        guard values["gallery_id"]?.integer != nil else { throw BooruError.invalidResponse }
        let fields = workColumns.filter { values[$0] != nil }
        if let work = try localWork(values, variant: variant, db), let id = work.id {
            let updates = fields.filter { $0 != "gallery_id" }
            guard !updates.isEmpty else { return }
            let sql = "UPDATE works SET " + updates.map { keepsKnownValue.contains($0) ? "\($0) = COALESCE(?, \($0))" : "\($0) = ?" }.joined(separator: ",") + " WHERE id = ?"
            try db.execute(sql: sql, arguments: StatementArguments(updates.map { values[$0]!.databaseValue } + [id]))
        } else {
            let sql = "INSERT INTO works (\(fields.joined(separator: ","))) VALUES (\(fields.map { _ in "?" }.joined(separator: ",")))"
            try db.execute(sql: sql, arguments: StatementArguments(fields.map { values[$0]!.databaseValue }))
        }
    }
    private static func upsert(_ incoming: LibrarySyncRow, db: Database) throws {
        var row = incoming
        if row.table == "manga.folders" { row.values = MangaImportMetadata.normalized(row.values) }
        guard let allowed = columns[row.table], let keys = LibrarySyncRow.keys[row.table], keys.allSatisfy({ row.values[$0] != nil }) else { throw BooruError.invalidResponse }
        // Columns this version does not know yet, sent by a newer one, are left out rather than
        // turning the whole row away; the record itself still carries them on to other devices.
        let fields = allowed.filter { row.values[$0] != nil }
        let updates = fields.filter { !keys.contains($0) }.map { keepsKnownValue.contains($0) ? "\($0) = COALESCE(excluded.\($0), \($0))" : "\($0) = excluded.\($0)" }.joined(separator: ",")
        let sql = "INSERT INTO \(row.table.split(separator: ".")[1]) (\(fields.joined(separator: ","))) VALUES (\(fields.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(keys.joined(separator: ","))) DO " + (updates.isEmpty ? "NOTHING" : "UPDATE SET " + updates)
        try db.execute(sql: sql, arguments: StatementArguments(fields.map { row.values[$0]!.databaseValue }))
    }
    private static func delete(_ row: LibrarySyncRow, db: Database) throws {
        guard let keys = LibrarySyncRow.keys[row.table], columns[row.table] != nil else { throw BooruError.invalidResponse }
        try db.execute(sql: "DELETE FROM \(row.table.split(separator: ".")[1]) WHERE \(keys.map { $0 + " = ?" }.joined(separator: " AND "))", arguments: StatementArguments(keys.map { row.values[$0]?.databaseValue ?? .null }))
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value) }
}

extension BooruPost {
    /// Imported embedded thumbnails or device-local paths must never become cloud media.
    var cloudMetadata: Self {
        var post = self
        func remote(_ url: URL?) -> URL? {
            guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        post.previewURL = remote(previewURL)
        post.sampleURL = remote(sampleURL)
        post.fileURL = remote(fileURL)
        return post
    }
}
