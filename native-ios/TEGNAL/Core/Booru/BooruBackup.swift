import Foundation
import GRDB

/// Portable library data only. Credentials, cookies, caches and device preferences stay local.
struct BooruBackup: Codable, Sendable {
    /// `serverID` names one of the backup's servers; `isGlobal` marks a folder of every server.
    /// Both absent, it is from before folders belonged to servers, and goes where its images are.
    struct Folder: Codable, Sendable {
        var id: String; var name: String; var color: Int64
        var serverID: String? = nil
        var isGlobal: Bool? = nil
        var isLegacy: Bool { serverID == nil && isGlobal == nil }
    }
    struct Favorite: Codable, Sendable { var post: BooruPost; var folderID: String; var savedAt: Double }
    struct Search: Codable, Sendable { var serverID: String; var query: String; var usedAt: Double }
    struct Tag: Codable, Sendable { var serverID: String; var name: String; var kind: String }
    /// A recently opened image; `openedAt` is seconds since 1970, as both apps write it.
    struct Recent: Codable, Sendable { var post: BooruPost; var openedAt: Double }
    var format = "tegnal-image-library"
    var version = 1
    var exportedAt = Date()
    var servers: [BooruServer]
    var folders: [Folder]
    var favorites: [Favorite]
    var history: [Search]
    var savedTags: [Tag]
    var blacklist: [String: String]
    var selectedServerIDs: [String]
    /// Optional so backups from before smart folders still read.
    var folderRules: [FolderRule]?
    /// Optional so backups from before recent images still read.
    var recentImages: [Recent]?
    /// Tag study progress. Times are seconds since 1970, as both apps write them.
    struct Learned: Codable, Sendable { var tag: String; var step: Int; var due: Double; var correct: Int; var wrong: Int; var seen: Double }
    struct Lesson: Codable, Sendable { var lesson: String; var stars: Int; var runs: Int; var finished: Double }
    struct Award: Codable, Sendable { var id: String; var earned: Double }
    struct Study: Codable, Sendable {
        var progress: [Learned]; var days: [StudyDay]
        /// Optional so backups from before learning mode still read.
        var lessons: [Lesson]?; var awards: [Award]?; var stats: [String: Int]?
        init(progress: [Learned], days: [StudyDay], lessons: [Lesson]? = nil, awards: [Award]? = nil, stats: [String: Int]? = nil) {
            self.progress = progress; self.days = days; self.lessons = lessons; self.awards = awards; self.stats = stats
        }
        /// A day written before learning mode has no experience.
        private struct Day: Codable { var day: String; var answered: Int; var correct: Int; var xp: Int? }
        private enum Keys: String, CodingKey { case progress, days, lessons, awards, stats }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            progress = try container.decode([Learned].self, forKey: .progress)
            days = try container.decode([Day].self, forKey: .days).map { StudyDay(day: $0.day, answered: $0.answered, correct: $0.correct, xp: $0.xp ?? 0) }
            lessons = try container.decodeIfPresent([Lesson].self, forKey: .lessons)
            awards = try container.decodeIfPresent([Award].self, forKey: .awards)
            stats = try container.decodeIfPresent([String: Int].self, forKey: .stats)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(progress, forKey: .progress)
            try container.encode(days.map { Day(day: $0.day, answered: $0.answered, correct: $0.correct, xp: $0.xp) }, forKey: .days)
            try container.encodeIfPresent(lessons, forKey: .lessons)
            try container.encodeIfPresent(awards, forKey: .awards)
            try container.encodeIfPresent(stats, forKey: .stats)
        }
    }
    /// Optional so backups from before tag study still read.
    var study: Study?

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw BooruError.invalidResponse }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw BooruError.invalidResponse }
        var value = try JSONDecoder().decode(Self.self, from: data)
        // Only import recognizes the historical format; all new exports use TEGNAL.
        if value.format == "number-memo-image-library" { value.format = "tegnal-image-library" }
        try value.validate()
        return value
    }

    func validate() throws {
        for server in servers { _ = try BooruServer.validatedURL(server.baseURL.absoluteString) }
        let serverIDs = Set(servers.map(\.id)), folderIDs = Set(folders.map(\.id))
        guard format == "tegnal-image-library", version == 1,
              serverIDs.count == servers.count, folderIDs.count == folders.count,
              servers.allSatisfy({ !$0.id.isEmpty }),
              folders.allSatisfy({ !$0.id.isEmpty && (0...0xFFFFFFFF).contains($0.color) && ($0.id == "unsorted" || !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }),
              Set(servers.map(\.canonicalAddress)).count == servers.count,
              Set(favorites.map { $0.post.id }).count == favorites.count,
              favorites.allSatisfy({ serverIDs.contains($0.post.serverID) && folderIDs.contains($0.folderID) && $0.post.postID > 0 && $0.savedAt.isFinite }),
              history.allSatisfy({ serverIDs.contains($0.serverID) && !$0.query.isEmpty && $0.usedAt.isFinite }),
              savedTags.allSatisfy({ serverIDs.contains($0.serverID) && !$0.name.isEmpty && (SavedCollectionKind(rawValue: $0.kind).map { $0 != .history } ?? false) }),
              Set(blacklist.keys).isSubset(of: serverIDs), Set(selectedServerIDs).isSubset(of: serverIDs),
              folders.allSatisfy({ $0.serverID.map(serverIDs.contains) ?? true }),
              (folderRules ?? []).allSatisfy({ folderIDs.contains($0.folder) && !$0.query.isEmpty }),
              (recentImages ?? []).allSatisfy({ serverIDs.contains($0.post.serverID) && $0.post.postID > 0 && $0.openedAt.isFinite }),
              (study?.progress ?? []).allSatisfy({ !$0.tag.isEmpty && $0.tag.count <= 200 && (0...StudyProgress.lastStep).contains($0.step) && $0.correct >= 0 && $0.wrong >= 0 && $0.due.isFinite && $0.seen.isFinite }),
              (study?.days ?? []).allSatisfy({ $0.day.count == 10 && $0.answered >= 0 && (0...$0.answered).contains($0.correct) && $0.xp >= 0 }),
              (study?.lessons ?? []).allSatisfy({ !$0.lesson.isEmpty && $0.lesson.count <= 200 && $0.stars >= 0 && $0.runs >= 0 && $0.finished.isFinite }),
              Set((study?.lessons ?? []).map(\.lesson)).count == (study?.lessons ?? []).count,
              (study?.awards ?? []).allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200 && $0.earned.isFinite }),
              Set((study?.awards ?? []).map(\.id)).count == (study?.awards ?? []).count,
              (study?.stats ?? [:]).allSatisfy({ !$0.key.isEmpty && $0.key.count <= 200 && $0.value >= 0 })
        else { throw BooruError.invalidResponse }
        for server in servers { _ = try BooruServer.validatedURL(server.baseURL.absoluteString) }
        for post in favorites.map(\.post) + (recentImages ?? []).map(\.post) {
            for url in [post.previewURL, post.sampleURL, post.fileURL, post.animationVideoURL].compactMap({ $0 }) {
                guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw BooruError.invalidResponse }
            }
        }
    }

    /// Recent images placed on this device's servers, matched by address as a restore matches them.
    func recentImages(on current: [BooruServer]) -> [RecentImage] {
        let addresses = Dictionary(servers.map { ($0.id, $0.canonicalAddress) }, uniquingKeysWith: { first, _ in first })
        return (recentImages ?? []).compactMap { recent in
            guard let address = addresses[recent.post.serverID], let server = current.first(where: { $0.canonicalAddress == address }) else { return nil }
            return RecentImage(post: recent.post.onServer(server.id), openedAt: Date(timeIntervalSince1970: recent.openedAt))
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension BooruStore {
    func exportBackup() throws -> BooruBackup {
        try database.read { db in
            let servers = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            let folders = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY position, name").map {
                BooruBackup.Folder(id: $0["id"], name: $0["name"], color: $0["color"], serverID: $0["server_id"], isGlobal: ($0["server_id"] as String?) == nil)
            }
            let favorites = try Row.fetchAll(db, sql: "SELECT * FROM favorites ORDER BY saved_at DESC").map { BooruBackup.Favorite(post: try JSONDecoder().decode(BooruPost.self, from: $0["payload"] as Data), folderID: $0["folder_id"], savedAt: $0["saved_at"]) }
            let history = try Row.fetchAll(db, sql: "SELECT * FROM history WHERE used_at >= ? ORDER BY used_at DESC", arguments: [SearchRetention.cutoff(booru: true)]).map { BooruBackup.Search(serverID: $0["server_id"], query: $0["query"], usedAt: $0["used_at"]) }
            let tags = try Row.fetchAll(db, sql: "SELECT * FROM saved_tags ORDER BY server_id, kind, name").map { BooruBackup.Tag(serverID: $0["server_id"], name: $0["name"], kind: $0["kind"]) }
            var blacklist: [String: String] = [:]
            for server in servers { blacklist[server.id] = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: ["blacklist." + server.id]) ?? "" }
            let learned = try Row.fetchAll(db, sql: "SELECT * FROM study_progress ORDER BY tag").map {
                BooruBackup.Learned(tag: $0["tag"], step: $0["step"], due: $0["due"], correct: $0["correct"], wrong: $0["wrong"], seen: $0["seen"])
            }
            let days = try Row.fetchAll(db, sql: "SELECT * FROM study_days ORDER BY day").map { StudyDay(day: $0["day"], answered: $0["answered"], correct: $0["correct"], xp: $0["xp"] ?? 0) }
            let lessons = try Row.fetchAll(db, sql: "SELECT * FROM study_lessons ORDER BY lesson").map { BooruBackup.Lesson(lesson: $0["lesson"], stars: $0["stars"], runs: $0["runs"], finished: $0["finished"]) }
            let awards = try Row.fetchAll(db, sql: "SELECT id, earned FROM study_awards ORDER BY id").map { BooruBackup.Award(id: $0["id"], earned: $0["earned"]) }
            var stats: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, value FROM study_stats") { stats[row["name"]] = row["value"] }
            return BooruBackup(servers: servers, folders: folders, favorites: favorites, history: history, savedTags: tags, blacklist: blacklist, selectedServerIDs: selectedServerIDs, folderRules: try Self.fetchFolderRules(db).filter { rule in folders.contains { $0.id == rule.folder } },
                               study: learned.isEmpty && days.isEmpty && lessons.isEmpty && awards.isEmpty && stats.isEmpty ? nil
                                : .init(progress: learned, days: days, lessons: lessons, awards: awards, stats: stats))
        }
    }

    /// Merge atomically; repeated imports never duplicate servers, folders or favorites.
    /// The backup restores colors, folder membership and ordering without deleting other items.
    func restoreBackup(_ backup: BooruBackup) throws {
        try backup.validate()
        try database.write { try restoreBackup(backup, in: $0) }
        try refresh()
    }

    /// Allows a combined restore to validate and write both libraries in one operation.
    func restoreBackup(_ backup: BooruBackup, in db: Database) throws {
        let existing = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
        var mapping: [String: String] = [:]
        for source in backup.servers {
            if let match = existing.first(where: { $0.canonicalAddress == source.canonicalAddress }) { mapping[source.id] = match.id }
            else {
                var server = source
                if existing.contains(where: { $0.id == server.id }) { server.id = UUID().uuidString }
                mapping[source.id] = server.id
                try db.execute(sql: "INSERT INTO servers VALUES (?, ?, (SELECT COUNT(*) FROM servers))", arguments: [server.id, try JSONEncoder().encode(server)])
            }
        }
        let incomingOrder = backup.folders.map(\.id)
        let remaining = try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name").filter { !incomingOrder.contains($0) }
        for (position, folder) in backup.folders.enumerated() {
            let owner = folder.isGlobal == true ? nil : folder.serverID.flatMap { mapping[$0] }
            // A folder from before folders belonged to servers keeps the server it has here.
            let ownerUpdate = folder.isLegacy ? "" : ", server_id = excluded.server_id"
            try db.execute(sql: "INSERT INTO folders (id, name, color, position, server_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color, position = excluded.position" + ownerUpdate,
                           arguments: [folder.id, folder.id == "unsorted" ? "" : folder.name, FolderPalette.vivid(folder.color), position, owner])
        }
        for (position, id) in (incomingOrder + remaining).enumerated() {
            try db.execute(sql: "UPDATE folders SET position = ? WHERE id = ?", arguments: [position, id])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", arguments: [String(decoding: JSONEncoder().encode(incomingOrder + remaining), as: UTF8.self)])
        for value in backup.favorites {
            guard let targetServerID = mapping[value.post.serverID] else { continue }
            let post = value.post.onServer(targetServerID)
            let existed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE server_id = ? AND post_id = ?)", arguments: [post.serverID, post.postID]) ?? false
            try db.execute(sql: "INSERT INTO favorites VALUES (?, ?, ?, ?, ?) ON CONFLICT(server_id, post_id) DO UPDATE SET payload = excluded.payload, saved_at = excluded.saved_at, folder_id = excluded.folder_id", arguments: [post.serverID, post.postID, try JSONEncoder().encode(post), value.savedAt, value.folderID])
            try TasteStore.record(existed ? .metadata : .imported, item: Self.tasteItem(post, db: db), db: db)
        }
        for value in backup.history {
            guard let targetServerID = mapping[value.serverID] else { continue }
            try db.execute(sql: "INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)", arguments: [targetServerID, value.query, value.usedAt])
        }
        for value in backup.savedTags {
            guard let targetServerID = mapping[value.serverID] else { continue }
            try db.execute(sql: "INSERT OR IGNORE INTO saved_tags VALUES (?, ?, ?)", arguments: [targetServerID, value.name, value.kind])
        }
        for (id, rules) in backup.blacklist {
            guard let targetServerID = mapping[id] else { continue }
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: ["blacklist." + targetServerID, rules])
        }
        for rule in backup.folderRules ?? [] { try Self.storeFolderRule(rule, db: db) }
        // Study progress merges: a tag keeps whichever answer came later, and a day its larger count.
        for value in backup.study?.progress ?? [] {
            try db.execute(sql: """
                INSERT INTO study_progress (tag, step, due, correct, wrong, seen) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(tag) DO UPDATE SET step = excluded.step, due = excluded.due, correct = excluded.correct, wrong = excluded.wrong, seen = excluded.seen
                WHERE excluded.seen > study_progress.seen
                """, arguments: [value.tag, value.step, value.due, value.correct, value.wrong, value.seen])
        }
        for value in backup.study?.days ?? [] {
            try db.execute(sql: """
                INSERT INTO study_days (day, answered, correct, xp) VALUES (?, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET answered = MAX(answered, excluded.answered), correct = MAX(correct, excluded.correct), xp = MAX(xp, excluded.xp)
                """, arguments: [value.day, value.answered, value.correct, value.xp])
        }
        // A lesson finished anywhere stays finished, with its best stars, most runs and latest finish.
        for value in backup.study?.lessons ?? [] {
            try db.execute(sql: """
                INSERT INTO study_lessons (lesson, stars, runs, finished) VALUES (?, ?, ?, ?)
                ON CONFLICT(lesson) DO UPDATE SET stars = MAX(stars, excluded.stars), runs = MAX(runs, excluded.runs), finished = MAX(finished, excluded.finished)
                """, arguments: [value.lesson, value.stars, value.runs, value.finished])
        }
        // A badge keeps its earliest time; one from a backup was celebrated where it was earned.
        for value in backup.study?.awards ?? [] {
            try db.execute(sql: """
                INSERT INTO study_awards (id, earned, seen) VALUES (?, ?, 1)
                ON CONFLICT(id) DO UPDATE SET earned = MIN(earned, excluded.earned), seen = 1
                """, arguments: [value.id, value.earned])
        }
        for (name, value) in backup.study?.stats ?? [:] {
            try db.execute(sql: """
                INSERT INTO study_stats (name, value) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET value = MAX(value, excluded.value)
                """, arguments: [name, value])
        }
        // Folders of an older backup go where their images are when each server keeps its own folders,
        // and stay shared otherwise; every image goes to a folder that may hold it.
        let split = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [BooruFolderStyle.key]) == BooruFolderStyle.byServer.rawValue
        try Self.assignFolderServers(db: db, only: Set(backup.folders.filter(\.isLegacy).map(\.id)), split: split)
        // The order kept is the one the folders now have, each server's Uncategorized included, so a
        // second restore of the same backup changes nothing.
        let order = try String.fetchAll(db, sql: "SELECT id FROM folders ORDER BY position, name")
        try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('folder_order', ?)", arguments: [String(decoding: JSONEncoder().encode(order), as: UTF8.self)])
        if !backup.selectedServerIDs.isEmpty {
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", arguments: [String(decoding: JSONEncoder().encode(backup.selectedServerIDs.compactMap { mapping[$0] }), as: UTF8.self)])
        }
    }
}
