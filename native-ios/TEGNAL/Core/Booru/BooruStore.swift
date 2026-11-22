import Foundation
import GRDB
import Observation
import Security

/// Image-mode storage; portable backups and iCloud coordinate both library databases.
@Observable
final class BooruStore: @unchecked Sendable {
    let database: DatabaseQueue
    private let prefetchSavedPreviews: Bool
    struct FavoriteRecord { let post: BooruPost; let folderID: String; let savedAt: Date }
    private struct FavoriteQuery: Hashable { let folderID: String?; let query: String; let safeMode: Bool; let servers: [String] }
    @ObservationIgnored private let snapshotLock = NSLock()
    @ObservationIgnored private var cachedFavoriteIDs: (revision: Int, value: Set<String>)?
    @ObservationIgnored private var cachedFavorites: (revision: Int, value: [FavoriteRecord])?
    @ObservationIgnored private var cachedFolders: (revision: Int, value: [BooruFolder])?
    @ObservationIgnored private var visibleFavoritesRevision = -1
    @ObservationIgnored private var visibleFavoritesCache: [FavoriteQuery: [BooruPost]] = [:]
    @ObservationIgnored private var snapshotGeneration = 0
    @ObservationIgnored private var goldRestrictedIDs: Set<String> = []
    private(set) var servers: [BooruServer] = []
    /// The folder style the person chose; nil while a library from before server folders waits to be asked.
    private(set) var chosenFolderStyle: BooruFolderStyle?
    private(set) var selectedServerID = ""
    private(set) var selectedServerIDs: [String] = []
    var selectedServers: [BooruServer] { servers.filter { selectedServerIDs.contains($0.id) } }
    private(set) var revision = 0
    /// Safe Mode, set by the app. Safebooru carries only all-ages images, so it is the one server
    /// browsed, and only images saved from it are shown; everything else stays saved, out of sight.
    var safeMode = false {
        didSet { if safeMode != oldValue { invalidateSnapshots(); revision += 1 } }
    }
    /// Whether a saved image may be shown under Safe Mode.
    func isShownInSafeMode(_ post: BooruPost) -> Bool { !safeMode || isSafebooru(serverID: post.serverID) }
    func isSafebooru(serverID: String) -> Bool { servers.first { $0.id == serverID }?.isSafebooru == true }
    /// The servers that can be chosen to browse: Safebooru alone in Safe Mode.
    var selectableServers: [BooruServer] { safeMode ? servers.filter(\.isSafebooru) : servers }
    /// What was chosen before Safe Mode, chosen again when it is turned off.
    private static let presafeSelectionKey = "safe_mode.previous_servers"
    var error: String?
    var selectedServer: BooruServer? { servers.first { $0.id == selectedServerID } }

    /// Access restrictions are scoped to this running session, never persisted
    /// as a blacklist or a deletion from the user's saved library.
    var confirmedGoldRestrictedIDs: Set<String> {
        access(keyPath: \.confirmedGoldRestrictedIDs)
        return snapshotLock.withLock { goldRestrictedIDs }
    }

    func isVisible(_ post: BooruPost) -> Bool {
        !confirmedGoldRestrictedIDs.contains(post.id)
    }

    func recordGoldRestriction(_ post: BooruPost) {
        recordGoldRestrictions(serverID: post.serverID, postIDs: [post.postID])
    }

    func recordGoldRestrictions(serverID: String, postIDs: [Int64]) {
        let ids = Set(postIDs.filter { $0 > 0 }.map { "\(serverID):\($0)" })
        guard !ids.isEmpty, !ids.isSubset(of: confirmedGoldRestrictedIDs) else { return }
        withMutation(keyPath: \.confirmedGoldRestrictedIDs) {
            snapshotLock.withLock { goldRestrictedIDs.formUnion(ids) }
        }
    }

    func clearGoldRestrictions(serverID: String? = nil) {
        let matches: (String) -> Bool = { id in
            guard let serverID else { return true }
            guard let separator = id.lastIndex(of: ":") else { return false }
            return id[..<separator] == serverID
        }
        guard confirmedGoldRestrictedIDs.contains(where: matches) else { return }
        withMutation(keyPath: \.confirmedGoldRestrictedIDs) {
            snapshotLock.withLock {
                goldRestrictedIDs = goldRestrictedIDs.filter { !matches($0) }
            }
        }
    }

    init(path: String? = nil, prefetchSavedPreviews: Bool = false) throws {
        self.prefetchSavedPreviews = prefetchSavedPreviews
        database = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try Self.migrator.migrate(database)
        try reload()
    }

    static var migrator: DatabaseMigrator {
        var migrations = DatabaseMigrator()
        migrations.registerMigration("booru_v1") { db in
            try db.execute(sql: """
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE servers (id TEXT PRIMARY KEY, payload BLOB NOT NULL, position INTEGER NOT NULL);
                CREATE TABLE favorites (server_id TEXT NOT NULL, post_id INTEGER NOT NULL, payload BLOB NOT NULL, saved_at DOUBLE NOT NULL, PRIMARY KEY(server_id, post_id));
                CREATE TABLE history (server_id TEXT NOT NULL, query TEXT NOT NULL, used_at DOUBLE NOT NULL, PRIMARY KEY(server_id, query));
                CREATE TABLE saved_tags (server_id TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(server_id, name, kind));
                CREATE INDEX favorite_date ON favorites(server_id, saved_at DESC);
                """)
            // Servers are added only by explicit address entry, import, or library sync.
        }
        migrations.registerMigration("booru_v2_folders") { db in
            try db.execute(sql: """
                CREATE TABLE folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, position INTEGER NOT NULL);
                INSERT INTO folders VALUES ('unsorted', '', 4284922736, 0);
                ALTER TABLE favorites ADD COLUMN folder_id TEXT NOT NULL DEFAULT 'unsorted';
                CREATE INDEX favorite_folder ON favorites(folder_id, saved_at DESC);
                """)
        }
        migrations.registerMigration("booru_v3_legacy_engine") { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM servers") {
                var server = try JSONDecoder().decode(BooruServer.self, from: row["payload"] as Data)
                if server.engine == .gelbooru, server.baseURL.host?.hasSuffix(".booru.org") == true {
                    server.engine = .oldGelbooru
                    try db.execute(sql: "UPDATE servers SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(server), server.id])
                }
            }
        }
        migrations.registerMigration("booru_v4_canonical_servers") { db in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var identities: [String: String] = [:]
            for server in servers {
                guard let target = identities[server.canonicalAddress] else { identities[server.canonicalAddress] = server.id; continue }
                for row in try Row.fetchAll(db, sql: "SELECT * FROM favorites WHERE server_id = ?", arguments: [server.id]) {
                    let post = try JSONDecoder().decode(BooruPost.self, from: row["payload"] as Data).onServer(target)
                    try db.execute(sql: "INSERT OR IGNORE INTO favorites VALUES (?, ?, ?, ?, ?)", arguments: [target, post.postID, try JSONEncoder().encode(post), row["saved_at"] as Double, row["folder_id"] as String])
                }
                try db.execute(sql: "INSERT OR IGNORE INTO history SELECT ?, query, used_at FROM history WHERE server_id = ?", arguments: [target, server.id])
                try db.execute(sql: "INSERT OR IGNORE INTO saved_tags SELECT ?, name, kind FROM saved_tags WHERE server_id = ?", arguments: [target, server.id])
                let oldKey = "blacklist." + server.id, newKey = "blacklist." + target
                if let rules = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [oldKey]) {
                    let existing = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [newKey]) ?? ""
                    try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [newKey, [existing, rules].filter { !$0.isEmpty }.joined(separator: "\n")])
                }
                for table in ["favorites", "history", "saved_tags"] { try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [server.id]) }
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [oldKey])
                try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [server.id])
                if let raw = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'selected_servers'"), let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) {
                    let mapped = Array(Set(ids.map { $0 == server.id ? target : $0 }))
                    try db.execute(sql: "UPDATE settings SET value = ? WHERE key = 'selected_servers'", arguments: [String(decoding: try JSONEncoder().encode(mapped), as: UTF8.self)])
                }
            }
        }
        migrations.registerMigration("booru_v5_site_folders") { db in
            for row in try Row.fetchAll(db, sql: "SELECT payload FROM servers") {
                let server = try JSONDecoder().decode(BooruServer.self, from: row["payload"] as Data)
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorites WHERE server_id = ? AND folder_id = 'unsorted'", arguments: [server.id]) ?? 0
                if count > 0 {
                    let folder = try Self.legacySiteFolder(for: server.id, db: db)
                    try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'unsorted'", arguments: [folder, server.id])
                }
            }
        }
        migrations.registerMigration("booru_v6_import_site_folders") { db in
            try Self.organizeLegacyImports(db: db, legacy: true)
        }
        migrations.registerMigration("booru_v7_taste") { try TasteStore.migrate($0) }
        migrations.registerMigration("booru_v8_visual_fingerprints") { try VisualFingerprintStore.migrate($0) }
        migrations.registerMigration("booru_v9_visual_cleanup") { try VisualFingerprintStore.installDeletionTrigger($0) }
        migrations.registerMigration("booru_v10_challenges") { try ChallengeStore.migrate($0) }
        migrations.registerMigration("booru_v11_optional_unsorted") { db in
            try db.execute(sql: "DELETE FROM folders WHERE id = 'unsorted' AND color = 4284922736 AND NOT EXISTS(SELECT 1 FROM favorites WHERE folder_id = 'unsorted')")
        }
        migrations.registerMigration("booru_v12_vivid_folder_colors") { try AppDatabase.adoptFolderPalette($0) }
        // Each server gets folders of its own; a folder with images of several servers becomes one
        // folder of the same name and color in each, and a folder holding nothing stays global.
        // Each server gets an Uncategorized of its own. Folders made before stay shared by every server
        // until the person chooses (`adoptFolderStyle`); a library with none starts with server folders.
        migrations.registerMigration("booru_v13_server_folders") { db in
            try db.execute(sql: "ALTER TABLE folders ADD COLUMN server_id TEXT")
            try Self.assignFolderServers(db: db, split: false)
            let shared = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders WHERE server_id IS NULL AND id != 'unsorted' AND id NOT GLOB ?",
                                          arguments: [BooruFolder.uncategorizedPrefix + "*"]) ?? 0
            if shared == 0 { try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [BooruFolderStyle.key, BooruFolderStyle.byServer.rawValue]) }
        }
        migrations.registerMigration("booru_v14_study") { try StudyStore.migrate($0) }
        migrations.registerMigration("booru_v15_study_game") { try StudyStore.migrateGame($0) }
        migrations.registerMigration("booru_v16_study_awards") { try StudyStore.migrateAwards($0) }
        migrations.registerMigration("booru_v17_addons") { try AddonStore.migrate($0) }
        migrations.registerMigration("booru_v18_addon_origin") { try AddonStore.migrateOrigin($0) }
        migrations.registerMigration("booru_v19_system_folder_colors") { try AppDatabase.adoptFolderPalette($0) }
        return migrations
    }

    static func open() throws -> BooruStore {
        try BooruStore(path: AppStorage.preparedContainerURL().appendingPathComponent("booru.sqlite").path, prefetchSavedPreviews: true)
    }

    func reload() throws {
        invalidateSnapshots()
        let updatedServers = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map {
                try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data)
            }
        }
        for server in servers where !updatedServers.contains(server) { clearGoldRestrictions(serverID: server.id) }
        servers = updatedServers
        let legacy = try setting("selected_server") ?? servers.first?.id ?? ""
        let saved = try setting("selected_servers").flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [legacy]
        // Another device or a restored backup may have chosen other servers; Safe Mode keeps to Safebooru.
        selectedServerIDs = servers.map(\.id).filter { saved.contains($0) && (!safeMode || isSafebooru(serverID: $0)) }
        selectedServerID = selectedServerIDs.first ?? ""
        let style = try setting(BooruFolderStyle.key).flatMap(BooruFolderStyle.init(rawValue:))
        if style != chosenFolderStyle { chosenFolderStyle = style }
    }

    func refresh() throws { try reload(); revision += 1 }

    /// Sync writes directly to SQLite off the main actor. Invalidate cached
    /// query results at that commit, before the later UI revision notification.
    func invalidateSnapshots() {
        snapshotLock.withLock {
            snapshotGeneration &+= 1
            cachedFavoriteIDs = nil; cachedFavorites = nil; cachedFolders = nil
            visibleFavoritesCache = [:]; visibleFavoritesRevision = -1
        }
    }

    private var snapshotVersion: Int {
        let revision = self.revision
        return snapshotLock.withLock { revision &+ snapshotGeneration }
    }

    func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }

    /// Explicit single-server selection is used for links/setup; toolbar selection is additive.
    func select(_ server: BooruServer) throws { try setSelectedServers([server.id]) }

    func toggleServer(_ server: BooruServer) throws {
        var ids = selectedServerIDs
        if ids.contains(server.id) { ids.removeAll { $0 == server.id } }
        else { ids.append(server.id) }
        try setSelectedServers(ids)
    }

    func setSelectedServers(_ ids: [String]) throws {
        let valid = servers.map(\.id).filter { ids.contains($0) && (!safeMode || isSafebooru(serverID: $0)) }
        // In Safe Mode, choosing only other servers leaves Safebooru chosen rather than nothing.
        if safeMode, valid.isEmpty, !selectedServerIDs.isEmpty { return }
        try setSetting("selected_servers", value: String(decoding: JSONEncoder().encode(valid), as: UTF8.self))
        selectedServerIDs = valid
        selectedServerID = valid.first ?? ""
    }

    /// Safe Mode browses Safebooru alone, adding it first when it is not among the servers. The
    /// servers chosen until then are remembered for when it is turned off.
    func enterSafeMode() throws {
        safeMode = true
        let chosen = try setting("selected_servers") ?? ""
        if try setting(Self.presafeSelectionKey) == nil, !chosen.isEmpty { try setSetting(Self.presafeSelectionKey, value: chosen) }
        try selectSafebooru()
    }

    /// Chooses again what was chosen before Safe Mode, or keeps Safebooru when that is gone.
    func leaveSafeMode() throws {
        safeMode = false
        guard let raw = try setting(Self.presafeSelectionKey) else { return }
        try removeSetting(Self.presafeSelectionKey)
        let previous = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        if previous.contains(where: { id in servers.contains { $0.id == id } }) { try setSelectedServers(previous) }
    }

    func selectSafebooru() throws {
        if let existing = servers.first(where: \.isSafebooru) {
            try setSelectedServers([existing.id])
        } else {
            let server = BooruServer.safebooru()
            try saveServer(server)
            try setSelectedServers([server.id])
        }
    }

    func saveServer(_ server: BooruServer) throws {
        guard !servers.contains(where: { $0.id != server.id && $0.canonicalAddress == server.canonicalAddress }) else { throw BooruError.duplicateServer }
        let position = servers.firstIndex(where: { $0.id == server.id }) ?? servers.count
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO servers VALUES (?, ?, ?)", arguments: [server.id, try JSONEncoder().encode(server), position])
            // A server has its Uncategorized from the start.
            _ = try Self.uncategorized(for: server.id, db: db)
        }
        try reload()
        // Saving also follows a credentials edit, even when the server address
        // itself is unchanged. A different account may have Gold access.
        clearGoldRestrictions(serverID: server.id)
        revision += 1
    }

    func deleteServer(_ server: BooruServer) throws {
        try BooruKeychain.save(.init(), serverID: server.id)
        try database.write { db in
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM favorites WHERE server_id = ?", arguments: [server.id]) {
                try TasteStore.record(.remove, item: Self.tasteItem(JSONDecoder().decode(BooruPost.self, from: data), db: db), db: db)
            }
            try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [server.id])
            for table in ["favorites", "history", "saved_tags"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [server.id])
            }
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: ["blacklist." + server.id])
            try StudyStore.forget(address: server.canonicalAddress, db: db)
            // Its folders go with it; global folders stay.
            for id in try String.fetchAll(db, sql: "SELECT id FROM folders WHERE server_id = ?", arguments: [server.id]) {
                try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [FolderRule.keyPrefix + id])
            }
            try db.execute(sql: "DELETE FROM folders WHERE server_id = ?", arguments: [server.id])
        }
        try reload()
        revision += 1
    }

    func favorites(serverID: String) -> [BooruPost] {
        favorites(serverIDs: [serverID])
    }

    /// Read once by the grid's body so lazy cells observe imports and restored data.
    var favoriteIDs: Set<String> {
        let revision = snapshotVersion
        if let value = snapshotLock.withLock({ cachedFavoriteIDs?.revision == revision ? cachedFavoriteIDs?.value : nil }) { return value }
        let value: Set<String> = (try? database.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT server_id, post_id FROM favorites").map { row in
                let serverID: String = row["server_id"]
                let postID: Int64 = row["post_id"]
                return "\(serverID):\(postID)"
            })
        }) ?? []
        snapshotLock.withLock { cachedFavoriteIDs = (revision, value) }
        return value
    }

    func isFavorite(_ post: BooruPost) -> Bool {
        favoriteIDs.contains(post.id)
    }

    func toggleFavorite(_ post: BooruPost, context: DiscoveryContext = .unknown) throws {
        let adding = try database.write { db in
            try db.execute(sql: "DELETE FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID])
            let adding = db.changesCount == 0
            if adding {
                let folder = try Self.smartDestination(for: post, landing: Self.defaultFolder(for: post.serverID, db: db), db: db)
                try db.execute(sql: "INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), Date().timeIntervalSince1970, folder])
            }
            try TasteStore.record(adding ? .save : .remove, item: Self.tasteItem(post, db: db), context: context, db: db)
            return adding
        }
        revision += 1
        if adding { warmSavedPreview(post) }
    }

    func favorites(serverIDs: [String], folderID: String? = nil) -> [BooruPost] {
        guard !serverIDs.isEmpty else { return [] }
        let servers = Set(serverIDs)
        return favoriteRecords().compactMap { record in
            servers.contains(record.post.serverID) && (folderID == nil || record.folderID == folderID) ? record.post : nil
        }
    }

    func favoriteRecords() -> [FavoriteRecord] {
        let revision = snapshotVersion
        if let value = snapshotLock.withLock({ cachedFavorites?.revision == revision ? cachedFavorites?.value : nil }) { return value }
        let value: [FavoriteRecord] = (try? database.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(db, sql: "SELECT payload, folder_id, saved_at FROM favorites ORDER BY saved_at DESC").map { row in
                FavoriteRecord(post: try decoder.decode(BooruPost.self, from: row["payload"] as Data), folderID: row["folder_id"], savedAt: Date(timeIntervalSince1970: row["saved_at"]))
            }
        }) ?? []
        snapshotLock.withLock { cachedFavorites = (revision, value) }
        return value
    }

    /// Favorites search: a post's tags or its number.
    nonisolated static func matches(_ post: BooruPost, query: String) -> Bool {
        query.isEmpty || post.tags.joined(separator: " ").localizedCaseInsensitiveContains(query) || String(post.postID).contains(query)
    }

    /// Without a folder, the images of every folder shown in Saved.
    func visibleFavorites(folderID: String? = nil, query: String = "") -> [BooruPost] {
        let revision = snapshotVersion, safeMode = safeMode, key = FavoriteQuery(folderID: folderID, query: query, safeMode: safeMode, servers: folderID == nil ? selectedServerIDs : [])
        let hidden = confirmedGoldRestrictedIDs
        if let value = snapshotLock.withLock({ visibleFavoritesRevision == revision ? visibleFavoritesCache[key] : nil }) {
            return hidden.isEmpty ? value : value.filter { !hidden.contains($0.id) }
        }
        let filters = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, BooruBlacklist(filteringBlacklist(serverID: $0.id))) })
        let safebooru = Set(servers.filter(\.isSafebooru).map(\.id))
        let shown = folderID == nil ? Set(visibleFolders().map(\.id)) : nil
        let value = favoriteRecords().compactMap { record -> BooruPost? in
            guard folderID.map({ record.folderID == $0 }) ?? shown!.contains(record.folderID) else { return nil }
            return filters[record.post.serverID] != nil ? record.post : nil
        }.filter {
            !(filters[$0.serverID]?.contains($0) ?? false) && Self.matches($0, query: query)
                && (!safeMode || safebooru.contains($0.serverID))
        }
        snapshotLock.withLock {
            if visibleFavoritesRevision != revision || visibleFavoritesCache.count >= 32 {
                visibleFavoritesCache = [:]; visibleFavoritesRevision = revision
            }
            visibleFavoritesCache[key] = value
        }
        return hidden.isEmpty ? value : value.filter { !hidden.contains($0.id) }
    }

    func favoriteSavedDates() -> [String: Date] {
        Dictionary(uniqueKeysWithValues: favoriteRecords().map { ($0.post.id, $0.savedAt) })
    }

    /// Every folder of every server, global ones included.
    func folders() -> [BooruFolder] {
        let revision = snapshotVersion
        if let value = snapshotLock.withLock({ cachedFolders?.revision == revision ? cachedFolders?.value : nil }) { return value }
        let value: [BooruFolder] = (try? database.read { db in
            let smart = Set(try Self.fetchFolderRules(db).filter(\.isActive).map(\.folder))
            return try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY position, name").map {
                BooruFolder(id: $0["id"], name: $0["name"], color: $0["color"], isSmart: smart.contains($0["id"] as String), serverID: $0["server_id"])
            }
        }) ?? []
        snapshotLock.withLock { cachedFolders = (revision, value) }
        return value
    }

    /// The folders Saved shows: the chosen servers' and the global ones.
    func visibleFolders() -> [BooruFolder] {
        let chosen = Set(selectedServerIDs)
        return folders().filter { $0.serverID.map(chosen.contains) ?? true }
    }

    /// The folders an image of the server may go to: its own and the global ones.
    func folders(forServer serverID: String) -> [BooruFolder] {
        folders().filter { $0.holds(serverID: serverID) }
    }

    func folder(_ id: String) -> BooruFolder? { folders().first { $0.id == id } }

    /// The server a folder belongs to, by name, for when several servers' folders are shown together.
    func serverName(ofFolder folder: BooruFolder) -> String? {
        folder.serverID.flatMap { id in servers.first { $0.id == id }?.displayName }
    }

    /// Creates a folder in a server, or a global one when `serverID` is nil; for a folder that
    /// exists, only its name and color change.
    @discardableResult func saveFolder(id: String = UUID().uuidString, name: String, color: Int64? = nil, serverID: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, id != "unsorted" else { throw BooruError.invalidResponse }
        try database.write { db in
            let existing = try Row.fetchOne(db, sql: "SELECT color, server_id FROM folders WHERE id = ?", arguments: [id])
            let owner: String? = existing.map { $0["server_id"] as String? } ?? serverID
            let resolved = try color ?? existing?["color"] ?? Self.nextFolderColor(serverID: owner, db: db)
            try db.execute(sql: "INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders), ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color",
                           arguments: [id, name, resolved, owner])
        }
        revision += 1
        return id
    }

    /// A global folder is shown whichever servers are chosen and takes images of any of them. Made
    /// a server's folder again, it stays in each server it holds images of, with the same name and
    /// color; a global folder holding nothing goes to `emptyServer`.
    func setGlobal(_ id: String, _ global: Bool, emptyServer: String?) throws {
        guard !BooruFolder.isUncategorized(id) else { return }
        try database.write { db in
            if global {
                try db.execute(sql: "UPDATE folders SET server_id = NULL WHERE id = ?", arguments: [id])
            } else {
                let addresses = Dictionary(try Self.decodedServers(db).map { ($0.id, $0.canonicalAddress) }, uniquingKeysWith: { first, _ in first })
                let owners = try String.fetchAll(db, sql: "SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?", arguments: [id])
                    .filter { addresses[$0] != nil }.sorted { addresses[$0]! < addresses[$1]! }
                guard let owner = owners.first ?? emptyServer.flatMap({ addresses[$0] != nil ? $0 : nil }) else { return }
                try db.execute(sql: "UPDATE folders SET server_id = ? WHERE id = ?", arguments: [owner, id])
                try Self.settleFolders(db: db)
            }
        }
        try refresh()
    }

    /// A server's Uncategorized stays while the server does. Images of a deleted folder go where
    /// their server saves by default, or to its Uncategorized when that was this folder.
    func deleteFolder(_ id: String) throws {
        try database.write { db in
            let owner = try String.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [id])
            if BooruFolder.isUncategorized(id), let owner, try Self.server(owner, db: db) != nil { throw FolderDeletionError.containsWorks }
            try Self.moveImages(outOf: id, db: db)
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [FolderRule.keyPrefix + id])
        }
        revision += 1
    }

    func folderID(for post: BooruPost) -> String? {
        _ = revision
        return try? database.read { try String.fetchOne($0, sql: "SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID]) }
    }

    func saveFavorite(_ post: BooruPost, folderID: String? = nil, context: DiscoveryContext? = nil) throws {
        try database.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT folder_id FROM favorites WHERE server_id = ? AND post_id = ?", arguments: [post.serverID, post.postID])
            let folderID = try folderID ?? existing ?? Self.smartDestination(for: post, landing: Self.defaultFolder(for: post.serverID, db: db), db: db)
            // Another server's folder never takes it; global folders take any image.
            guard try Self.folder(folderID, holds: post.serverID, db: db) else { throw BooruError.invalidResponse }
            try db.execute(sql: "INSERT INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, folder_id = excluded.folder_id", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), Date().timeIntervalSince1970, folderID])
            if existing == nil, let context { try TasteStore.record(.save, item: Self.tasteItem(post, db: db), context: context, db: db) }
            else if existing == nil { try TasteStore.record(.imported, item: Self.tasteItem(post, db: db), db: db) }
            else if existing != nil { try TasteStore.record(.metadata, item: Self.tasteItem(post, db: db), db: db) }
        }
        revision += 1
        warmSavedPreview(post)
    }

    private func warmSavedPreview(_ post: BooruPost) {
        guard prefetchSavedPreviews, let server = servers.first(where: { $0.id == post.serverID }), let url = post.previewURL ?? post.sampleURL else { return }
        let store = VisualFingerprintStore(database: database)
        Task(priority: .utility) {
            guard let image = try? await BooruThumbnailCache.shared.image(url: url, server: server), let data = image.jpegData(compressionQuality: 0.9) else { return }
            _ = try? await store.save(data: data, scope: server.id, id: post.postID)
        }
    }

    func organizeLegacyImports() throws {
        try database.write { try Self.organizeLegacyImports(db: $0) }
    }

    /// Repair the former shared import destination without moving user-created folders.
    static func organizeLegacyImports(db: Database, legacy: Bool = false) throws {
        for serverID in try String.fetchAll(db, sql: "SELECT DISTINCT server_id FROM favorites WHERE folder_id = 'anime-boxes'") {
            let folder = try legacy ? legacySiteFolder(for: serverID, db: db) : defaultFolder(for: serverID, db: db)
            try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND folder_id = 'anime-boxes'", arguments: [folder, serverID])
        }
        try db.execute(sql: "DELETE FROM folders WHERE id = 'anime-boxes' AND NOT EXISTS (SELECT 1 FROM favorites WHERE folder_id = 'anime-boxes')")
    }

    /// The server's own folder as the migrations before folder ownership made it.
    private static func legacySiteFolder(for serverID: String, db: Database) throws -> String {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM servers WHERE id = ?", arguments: [serverID]) else { throw BooruError.invalidServer }
        let server = try JSONDecoder().decode(BooruServer.self, from: data)
        let id = BooruFolder.uncategorizedPrefix + server.canonicalAddress
        if try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [id]) == nil {
            let color = try AppDatabase.nextFolderColor(existingColors: Int64.fetchAll(db, sql: "SELECT color FROM folders"))
            try db.execute(sql: "INSERT INTO folders (id, name, color, position) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders))", arguments: [id, server.displayName, color])
        }
        return id
    }

    /// Where an image of the server is saved when no folder is chosen: the server's chosen folder,
    /// or its Uncategorized.
    static func defaultFolder(for serverID: String, db: Database) throws -> String {
        guard let server = try server(serverID, db: db) else { throw BooruError.invalidServer }
        if let chosen = server.saveFolder, try folder(chosen, holds: serverID, db: db) { return chosen }
        return try uncategorized(for: serverID, db: db)
    }

    func history(serverID: String, limit: Int? = 500) -> [String] {
        _ = revision
        return (try? database.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM history WHERE server_id = ? AND used_at >= ? ORDER BY used_at DESC LIMIT ?", arguments: [serverID, SearchRetention.cutoff(booru: true), limit ?? -1])
        }) ?? []
    }

    func recordSearch(_ query: String, serverID: String) throws {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !PrivacySettings.isIncognito else { return }
        try database.write { db in
            try db.execute(sql: "DELETE FROM history WHERE used_at < ?", arguments: [SearchRetention.cutoff(booru: true)])
            try db.execute(sql: "INSERT OR REPLACE INTO history VALUES (?, ?, ?)", arguments: [serverID, value, Date().timeIntervalSince1970])
            try db.execute(sql: "DELETE FROM history WHERE server_id = ? AND query NOT IN (SELECT query FROM history WHERE server_id = ? ORDER BY used_at DESC LIMIT 500)", arguments: [serverID, serverID])
        }
        revision += 1
    }

    func clearHistory(serverID: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM history WHERE server_id = ?", arguments: [serverID]) }
        revision += 1
    }

    func savedTags(serverID: String, kind: String = "tag") -> [String] {
        _ = revision
        return (try? database.read { try String.fetchAll($0, sql: "SELECT name FROM saved_tags WHERE server_id = ? AND kind = ? ORDER BY name", arguments: [serverID, kind]) }) ?? []
    }

    func toggleTag(_ name: String, serverID: String, kind: String = "tag") throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM saved_tags WHERE server_id = ? AND name = ? AND kind = ?", arguments: [serverID, name, kind])
            if db.changesCount == 0 { try db.execute(sql: "INSERT INTO saved_tags VALUES (?, ?, ?)", arguments: [serverID, name, kind]) }
        }
        revision += 1
    }

    func blacklist(serverID: String) -> String {
        _ = revision
        return (try? setting("blacklist." + serverID)) ?? ""
    }
    /// The rules that hide images from a server: the learner's own, then those of add-ons that are on.
    /// Only for filtering; the learner edits `blacklist(serverID:)`, which never holds an add-on's rules.
    func filteringBlacklist(serverID: String) -> String {
        let own = blacklist(serverID: serverID), added = AddonRuntime.shared.effects.imageExclude
        return added.isEmpty ? own : ([own] + added).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func setBlacklist(_ text: String, serverID: String) throws { try setSetting("blacklist." + serverID, value: text) }
    func setting(_ key: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }
    func setSetting(_ key: String, value: String) throws {
        try database.write { try $0.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [key, value]) }
        revision += 1
    }
    func removeSetting(_ key: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key]) }
        revision += 1
    }
}

// MARK: Folders by server

/// Whether image folders belong to one server each, or are shared by every server as before 1.6.0.
enum BooruFolderStyle: String, CaseIterable, Identifiable {
    case byServer, shared
    var id: String { rawValue }
    static let key = "folder_style"
    var title: String { self == .byServer ? "Each Server's Own Folders" : "Folders Shared by All Servers" }
}

extension BooruStore {
    /// The style in use: the one chosen, or shared folders while a library from before waits for a choice.
    var folderStyle: BooruFolderStyle { chosenFolderStyle ?? .shared }
    /// A library from before server folders whose folders wait for the person to choose a style.
    var folderStylePending: Bool { chosenFolderStyle == nil }

    /// The server a new folder made while browsing `serverID` belongs to: none when folders are shared.
    func newFolderServer(_ serverID: String?) -> String? { folderStyle == .shared ? nil : serverID }

    /// What giving each server its own folders would change: shared folders holding images, and those
    /// holding images of several servers, which would become one folder per server.
    func folderStyleImpact() -> (folders: Int, mixed: Int) {
        (try? database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.id, COUNT(DISTINCT f.server_id) AS servers FROM folders d JOIN favorites f ON f.folder_id = d.id
                WHERE d.server_id IS NULL AND d.id != 'unsorted' AND d.id NOT GLOB ? GROUP BY d.id
                """, arguments: [BooruFolder.uncategorizedPrefix + "*"])
            return (rows.count, rows.filter { ($0["servers"] as Int) > 1 }.count)
        }) ?? (0, 0)
    }

    /// Switches folder style. By server: each shared folder goes to the server of its images, one
    /// folder of the same name for each when it holds several. Shared: every folder holds any server's
    /// images again, and a server's copy of a folder joins the folder it came from. Each server's
    /// Uncategorized and `kept` folders (a server's favorites lists) stay with their server.
    func adoptFolderStyle(_ style: BooruFolderStyle, kept: Set<String> = []) throws {
        try database.write { db in
            switch style {
            case .byServer: try Self.assignFolderServers(db: db)
            case .shared: try Self.shareFolders(db: db, kept: kept)
            }
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: [BooruFolderStyle.key, style.rawValue])
        }
        try refresh()
    }

    static func shareFolders(db: Database, kept: Set<String>) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id FROM folders WHERE instr(id, ?) > 0", arguments: [copyMarker]) {
            let id: String = row["id"], base = baseFolderID(id)
            guard !kept.contains(id), !kept.contains(base),
                  try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [base]) != nil else { continue }
            try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE folder_id = ?", arguments: [base, id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [FolderRule.keyPrefix + id])
        }
        for id in try String.fetchAll(db, sql: "SELECT id FROM folders WHERE server_id IS NOT NULL AND id NOT GLOB ?", arguments: [BooruFolder.uncategorizedPrefix + "*"])
        where !kept.contains(id) {
            try db.execute(sql: "UPDATE folders SET server_id = NULL WHERE id = ?", arguments: [id])
        }
    }

    /// A copy of a folder for another server is named `<folder>@<server address>`, the same on every
    /// device, so devices that split a folder at once agree on the copies.
    static let copyMarker = "@https://"
    static func copyID(of id: String, address: String) -> String { baseFolderID(id) + "@" + address }
    static func baseFolderID(_ id: String) -> String { id.components(separatedBy: copyMarker).first ?? id }

    static func decodedServers(_ db: Database) throws -> [BooruServer] {
        try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").compactMap { try? JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
    }

    static func server(_ id: String, db: Database) throws -> BooruServer? {
        try Data.fetchOne(db, sql: "SELECT payload FROM servers WHERE id = ?", arguments: [id]).map { try JSONDecoder().decode(BooruServer.self, from: $0) }
    }

    /// Before a folder goes: its images go where their server saves by default, or to the server's
    /// Uncategorized when that was this folder.
    static func moveImages(outOf id: String, db: Database) throws {
        for serverID in try String.fetchAll(db, sql: "SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?", arguments: [id]) where try server(serverID, db: db) != nil {
            var target = try defaultFolder(for: serverID, db: db)
            if target == id { target = try uncategorized(for: serverID, db: db) }
            try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE folder_id = ? AND server_id = ?", arguments: [target, id, serverID])
        }
    }

    /// Whether an image of the server may sit in the folder: one of the server's own, or a global one.
    static func folder(_ id: String, holds serverID: String, db: Database) throws -> Bool {
        guard id != "unsorted", let row = try Row.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [id]) else { return false }
        let owner: String? = row["server_id"]
        return owner == nil || owner == serverID
    }

    /// The color the fewest folders shown beside it use: the server's own and the global ones.
    static func nextFolderColor(serverID: String?, db: Database) throws -> Int64 {
        let colors = try serverID.map { try Int64.fetchAll(db, sql: "SELECT color FROM folders WHERE server_id = ? OR server_id IS NULL", arguments: [$0]) }
            ?? Int64.fetchAll(db, sql: "SELECT color FROM folders")
        return AppDatabase.nextFolderColor(existingColors: colors)
    }

    /// The server's Uncategorized, made when missing. It keeps the id the server's own folder had,
    /// so images already there stay.
    @discardableResult
    static func uncategorized(for serverID: String, db: Database) throws -> String {
        if let id = try String.fetchOne(db, sql: "SELECT id FROM folders WHERE server_id = ? AND id GLOB ? ORDER BY position LIMIT 1", arguments: [serverID, BooruFolder.uncategorizedPrefix + "*"]) { return id }
        guard let server = try server(serverID, db: db) else { throw BooruError.invalidServer }
        let id = BooruFolder.uncategorizedPrefix + server.canonicalAddress
        if try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [id]) != nil {
            // Left by another device, an older version or a server at this address before.
            try db.execute(sql: "UPDATE folders SET server_id = ? WHERE id = ?", arguments: [serverID, id])
        } else {
            // Named for the server, which is what versions before folder ownership show.
            try db.execute(sql: "INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, (SELECT COUNT(*) FROM folders), ?)",
                           arguments: [id, server.displayName, try nextFolderColor(serverID: serverID, db: db), serverID])
        }
        return id
    }

    /// The folder of the server that stands for the given one: the folder itself when it may hold
    /// the server's images, else the server's copy of it with its name, color, place and rule,
    /// made when missing.
    static func counterpart(of id: String, serverID: String, db: Database) throws -> String {
        if try folder(id, holds: serverID, db: db) { return id }
        if BooruFolder.isUncategorized(id) { return try uncategorized(for: serverID, db: db) }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE id = ?", arguments: [id]),
              let server = try server(serverID, db: db) else { return try defaultFolder(for: serverID, db: db) }
        let base = baseFolderID(id)
        if base != id, try String.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [base]) == serverID { return base }
        let copy = copyID(of: id, address: server.canonicalAddress)
        if let owner = try Row.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [copy]) {
            if (owner["server_id"] as String?) != serverID { try db.execute(sql: "UPDATE folders SET server_id = ? WHERE id = ?", arguments: [serverID, copy]) }
            return copy
        }
        try db.execute(sql: "INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, ?, ?)",
                       arguments: [copy, row["name"] as String, row["color"] as Int64, row["position"] as Int64, serverID])
        if var rule = try fetchFolderRules(db).first(where: { $0.folder == id }) {
            rule.folder = copy
            rule.sources = try rule.sources.map { try resolvedSources($0, serverID: serverID, db: db) }
            try storeFolderRule(rule, db: db)
        }
        return copy
    }

    /// A rule's folders as the server's own: each of its folders that may hold the server's images,
    /// its copy for the server, or the server's Uncategorized for another server's.
    private static func resolvedSources(_ sources: [String], serverID: String, db: Database) throws -> [String] {
        var result: [String] = []
        for source in sources {
            if try folder(source, holds: serverID, db: db) { result.append(source) }
            else if BooruFolder.isUncategorized(source) { result.append(try uncategorized(for: serverID, db: db)) }
            else if let server = try server(serverID, db: db), try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [copyID(of: source, address: server.canonicalAddress)]) != nil {
                result.append(copyID(of: source, address: server.canonicalAddress))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Gives every folder from before folder ownership a server: each server's own folder becomes
    /// its Uncategorized, a folder belongs to the server of its images (one folder of the same name
    /// in each when it holds several servers'), and a folder holding nothing stays global.
    /// `only` limits it to folders just restored from an older backup.
    static func assignFolderServers(db: Database, only ids: Set<String>? = nil, split: Bool = true) throws {
        let servers = try decodedServers(db)
        let byAddress = Dictionary(servers.map { ($0.canonicalAddress, $0.id) }, uniquingKeysWith: { first, _ in first })
        let addresses = Dictionary(servers.map { ($0.id, $0.canonicalAddress) }, uniquingKeysWith: { first, _ in first })
        for id in try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name") where id != "unsorted" && (ids?.contains(id) ?? true) {
            if id.hasPrefix(BooruFolder.uncategorizedPrefix), let owner = byAddress[String(id.dropFirst(BooruFolder.uncategorizedPrefix.count))] {
                try db.execute(sql: "UPDATE folders SET server_id = ? WHERE id = ?", arguments: [owner, id])
                continue
            }
            guard split else { continue }
            // The server whose address comes first keeps the folder, so every device picks the same one.
            let owners = try String.fetchAll(db, sql: "SELECT DISTINCT server_id FROM favorites WHERE folder_id = ?", arguments: [id])
                .filter { addresses[$0] != nil }.sorted { addresses[$0]! < addresses[$1]! }
            if let owner = owners.first { try db.execute(sql: "UPDATE folders SET server_id = ? WHERE id = ?", arguments: [owner, id]) }
        }
        try settleFolders(db: db)
        // A rule reads its own server's folders; a global one reads every server's Uncategorized
        // where it read the shared one.
        let uncategorized = try String.fetchAll(db, sql: "SELECT id FROM folders WHERE id GLOB ?", arguments: [BooruFolder.uncategorizedPrefix + "*"])
        for var rule in try fetchFolderRules(db) where ids?.contains(rule.folder) ?? true {
            guard let sources = rule.sources, let row = try Row.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [rule.folder]) else { continue }
            if let owner = row["server_id"] as String? { rule.sources = try resolvedSources(sources, serverID: owner, db: db) }
            else { rule.sources = sources.flatMap { $0 == "unsorted" ? uncategorized : [$0] } }
            try storeFolderRule(rule, db: db)
        }
    }

    /// Puts every image where it may be: in a folder of its own server or a global one. Run after
    /// anything that brings folders or images from elsewhere: iCloud, a backup, an import, or an
    /// older version on another device. Each server keeps its Uncategorized.
    static func settleFolders(db: Database) throws {
        let servers = try decodedServers(db)
        let known = Set(servers.map(\.id))
        for server in servers { try uncategorized(for: server.id, db: db) }
        // Folders of servers that are gone, and the shared Uncategorized from before: their images
        // go to their own servers' folders of the same name.
        let stale = try String.fetchAll(db, sql: "SELECT id FROM folders WHERE id = 'unsorted' OR (server_id IS NULL AND id GLOB ?) OR (server_id IS NOT NULL AND server_id NOT IN (SELECT id FROM servers))",
                                        arguments: [BooruFolder.uncategorizedPrefix + "*"])
        for id in stale {
            for row in try Row.fetchAll(db, sql: "SELECT server_id, post_id FROM favorites WHERE folder_id = ?", arguments: [id]) where known.contains(row["server_id"]) {
                let serverID: String = row["server_id"]
                let target = BooruFolder.isUncategorized(id) ? try uncategorized(for: serverID, db: db) : try counterpart(of: id, serverID: serverID, db: db)
                try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?", arguments: [target, serverID, row["post_id"] as Int64])
            }
            if id == "unsorted", let rule = try fetchFolderRules(db).first(where: { $0.folder == id }) {
                let ruled = Set(try fetchFolderRules(db).map(\.folder))
                for server in servers {
                    let target = try uncategorized(for: server.id, db: db)
                    guard !ruled.contains(target) else { continue }
                    var copy = rule; copy.folder = target; copy.sources = try rule.sources.map { try resolvedSources($0, serverID: server.id, db: db) }
                    try storeFolderRule(copy, db: db)
                }
            }
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [FolderRule.keyPrefix + id])
        }
        // Images in a folder gone, or in another server's folder.
        let misplaced = try Row.fetchAll(db, sql: """
            SELECT f.server_id, f.post_id, f.folder_id FROM favorites f LEFT JOIN folders d ON d.id = f.folder_id
            WHERE d.id IS NULL OR (d.server_id IS NOT NULL AND d.server_id != f.server_id)
            """)
        for row in misplaced where known.contains(row["server_id"]) {
            let serverID: String = row["server_id"], folderID: String = row["folder_id"]
            let exists = try String.fetchOne(db, sql: "SELECT id FROM folders WHERE id = ?", arguments: [folderID]) != nil
            let target = exists ? try counterpart(of: folderID, serverID: serverID, db: db) : try defaultFolder(for: serverID, db: db)
            try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?", arguments: [target, serverID, row["post_id"] as Int64])
        }
        // Two devices may each have kept a different server's folder under the first id; a copy
        // that ended up in the same server as its original goes back into it.
        for row in try Row.fetchAll(db, sql: "SELECT id, server_id FROM folders WHERE server_id IS NOT NULL AND instr(id, ?) > 0", arguments: [copyMarker]) {
            let id: String = row["id"], owner: String = row["server_id"], base = baseFolderID(id)
            guard try String.fetchOne(db, sql: "SELECT server_id FROM folders WHERE id = ?", arguments: [base]) == owner else { continue }
            try db.execute(sql: "UPDATE favorites SET folder_id = ? WHERE folder_id = ?", arguments: [base, id])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [FolderRule.keyPrefix + id])
        }
    }
}

/// API keys never enter SQLite, preferences, media requests, exports or logs.
enum BooruKeychain {
    private static let service = "work.nextline.tegnal.booru"
    static func read(serverID: String) throws -> BooruCredentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: serverID, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = result as? Data else { throw BooruError.storage }
        return try JSONDecoder().decode(BooruCredentials.self, from: data).normalized
    }
    static func save(_ credentials: BooruCredentials, serverID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: serverID]
        if credentials.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw BooruError.storage }
            return
        }
        let data = try JSONEncoder().encode(credentials)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BooruError.storage }
        } else if result != errSecSuccess { throw BooruError.storage }
    }
}
