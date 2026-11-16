import Foundation
import GRDB

struct AnimeBoxesBackup: Sendable {
    struct Favorite: Sendable { let post: BooruPost; let savedAt: Double }
    struct Search: Sendable { let text: String; let date: Double; let starred: Bool }
    /// Which app's file this was read from. Every kind merges the same way.
    enum Source: Sendable { case animeBoxes, bookmarkExport, imageAppDatabase }
    var source: Source = .animeBoxes
    let servers: [BooruServer]
    let selectedIDs: [String]
    let favorites: [Favorite]
    let history: [Search]
    let blacklist: [String]
    let skippedServers: Int
    let skippedFavorites: Int
    let skippedHistory: Int
    let skippedRules: Int

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: 16) ?? Data()
        try? handle.close()
        if head.starts(with: Array("SQLite format 3".utf8)) {
            // SQLite needs a real file; the picked one may live in iCloud.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
            try FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            return try readDatabase(at: copy.path)
        }
        guard size <= 64 * 1024 * 1024 else { throw AnimeBoxesImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let bookmarks = try parseBookmarks(data) { return bookmarks }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw AnimeBoxesImportError.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawServers = root["servers"] as? [[String: Any]],
              let rawFavorites = root["favorites"] as? [[String: Any]],
              let version = root["backupVersion"] as? String, version == "1.0" else { throw AnimeBoxesImportError.format }
        var servers: [BooruServer] = [], selected: [String] = [], favorites: [Favorite] = []
        var skippedServers = 0, skippedFavorites = 0
        for row in rawServers {
            guard let url = baseURL(row["url"] as? String ?? ""), let host = url.host else { skippedServers += 1; continue }
            let engine: BooruEngine
            switch integer(row["type"]) {
            case 1: engine = host.hasSuffix(".booru.org") ? .oldGelbooru : .gelbooru
            case 4: engine = .oldGelbooru
            case 3: engine = .danbooru
            default:
                if ["yande.re", "konachan.com", "konachan.net"].contains(host) { engine = .moebooru }
                else { skippedServers += 1; continue }
            }
            let existing = servers.first { $0.canonicalAddress == BooruServer.canonicalAddress(url) }
            let server = existing ?? BooruServer(name: (row["serverName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host, baseURL: url, engine: engine)
            if existing == nil { servers.append(server) }
            if row["isSelected"] as? Bool == true { selected.append(server.id) }
        }
        let formatter = ISO8601DateFormatter()
        func date(_ raw: Any?) -> Double { (raw as? String).flatMap(formatter.date(from:))?.timeIntervalSince1970 ?? 0 }
        var seen = Set<String>()
        for row in rawFavorites {
            guard let postID = integer(row["ppostId"]), postID > 0,
                  let page = URL(string: row["ppostUrl"] as? String ?? ""),
                  let server = servers.filter({ BooruServer.canonicalAddress(page).hasPrefix($0.canonicalAddress + "/") || BooruServer.canonicalAddress(page) == $0.canonicalAddress }).max(by: { $0.baseURL.path.count < $1.baseURL.path.count }) else { skippedFavorites += 1; continue }
            let file = row["file"] as? [String: Any] ?? [:]
            let preview = row["preview"] as? [String: Any] ?? [:]
            let sample = row["sample"] as? [String: Any] ?? [:]
            let jpeg = row["jpeg"] as? [String: Any] ?? [:]
            let fileURL = mediaURL(file["url"], base: server.baseURL)
            let tags = tokens(row["tags"])
            let post = BooruPost(serverID: server.id, postID: postID,
                                 previewURL: mediaURL(preview["url"], base: server.baseURL),
                                 sampleURL: mediaURL(sample["url"], base: server.baseURL) ?? mediaURL(jpeg["url"], base: server.baseURL), fileURL: fileURL,
                                 width: max(0, Int(integer(file["width"]) ?? 0)), height: max(0, Int(integer(file["height"]) ?? 0)),
                                 tags: tags, artists: tokens(row["tag_artist"]), rating: !server.usesModernRatings && row["rating"] as? String == "s" ? "g" : row["rating"] as? String ?? "",
                                 score: Int(integer(row["score"]) ?? 0), fileExtension: (file["ext"] as? String ?? fileURL?.pathExtension ?? "").lowercased())
            if seen.insert(post.id).inserted { favorites.append(.init(post: post, savedAt: date(row["dateAdded"]))) }
        }
        let rawHistory = root["searchHistory"] as? [[String: Any]] ?? []
        let history: [Search] = rawHistory.compactMap {
            guard let text = $0["searchText"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Search(text: text, date: date($0["searchDate"]), starred: $0["starred"] as? Bool ?? false)
        }
        let rawRules = root["bannedTags"] as? [Any] ?? []
        let blacklist: [String] = rawRules.compactMap {
            if let value = $0 as? String { return value.isEmpty ? nil : value }
            if let row = $0 as? [String: Any], let value = (row["tag"] ?? row["name"]) as? String { return value.isEmpty ? nil : value }
            return nil
        }
        return Self(servers: servers, selectedIDs: selected, favorites: favorites, history: history, blacklist: blacklist,
                    skippedServers: skippedServers, skippedFavorites: skippedFavorites, skippedHistory: rawHistory.count - history.count, skippedRules: rawRules.count - blacklist.count)
    }

    static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return (value as? String).flatMap(Int64.init)
    }
    static func tokens(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        return (value as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private static func baseURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        let secure = raw.hasPrefix("http://") ? "https://" + raw.dropFirst(7) : raw
        return try? BooruServer.validatedURL(secure)
    }
    static func mediaURL(_ raw: Any?, base: URL) -> URL? {
        guard let raw = raw as? String, !raw.isEmpty,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["https", "http"].contains(parts.scheme), parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }
}

// MARK: - Other image apps

extension AnimeBoxesBackup {
    /// The folder the other image apps' favorites may go to instead of the site folders.
    static let importedFolderID = "imported"

    /// A post page address, such as `/posts/1`, `/post/show/1` or `index.php?page=post&s=view&id=1`,
    /// as the server it belongs to and the post's number. The engine comes from the page's shape.
    static func postPage(_ raw: String) -> (server: BooruServer, postID: Int64)? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty else { return nil }
        let path = parts.path
        let engine: BooruEngine, postID: Int64?, base: String
        if let match = path.firstMatch(of: #/^(.*?)\/posts\/([0-9]+)\/?$/#) {
            engine = .danbooru; postID = Int64(match.2); base = String(match.1)
        } else if let match = path.firstMatch(of: #/^(.*?)\/post\/show\/([0-9]+)(?:\/.*)?$/#) {
            engine = .moebooru; postID = Int64(match.2); base = String(match.1)
        } else if path.hasSuffix("index.php"), let items = parts.queryItems,
                  items.first(where: { $0.name == "page" })?.value == "post", items.first(where: { $0.name == "s" })?.value == "view" {
            postID = items.first(where: { $0.name == "id" })?.value.flatMap { Int64($0) }
            base = String(path.dropLast("index.php".count))
            engine = .gelbooru
        } else { return nil }
        // A page shape can't tell the old gallery engine from the new one; an import maps onto a
        // server already added with the same address, which keeps its own engine.
        guard let postID, postID > 0, let url = try? BooruServer.validatedURL("https://" + host.lowercased() + base) else { return nil }
        return (BooruServer(name: BooruServer.bareHost(url), baseURL: url, engine: engine), postID)
    }

    /// Bookmarks exported as `{version, data: [...]}` or a bare list, each with the post's page
    /// address and its media addresses. Nil when the data isn't such an export.
    static func parseBookmarks(_ data: Data) throws -> Self? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let rows: [[String: Any]]
        if let object = json as? [String: Any] {
            guard object["backupVersion"] == nil, let list = object["data"] as? [[String: Any]] else { return nil }
            rows = list
        } else if let list = json as? [[String: Any]] {
            if list.contains(where: { $0["config"] is String && $0["type"] != nil }) { throw AnimeBoxesImportError.comicsBackup }
            rows = list
        } else { return nil }
        guard rows.contains(where: { $0["sourceUrl"] is String && ($0["originalUrl"] != nil || $0["thumbnailUrl"] != nil) }) else { return nil }
        var builder = Builder(source: .bookmarkExport)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in rows {
            let saved = (row["createdAt"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) ?? OtherAppImport.parseDate($0) }
            builder.add(page: row["sourceUrl"] as? String, preview: row["thumbnailUrl"], sample: row["sampleUrl"], file: row["originalUrl"],
                        width: row["width"], height: row["height"], tags: row["tags"], format: row["format"] as? String,
                        savedAt: saved?.timeIntervalSince1970 ?? 0)
        }
        return builder.backup()
    }

    /// An image app's own database: favorite items with their page and media addresses, their
    /// tags, and the search history.
    static func readDatabase(at path: String) throws -> Self {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try queue.read { db in
            if try db.tableExists("LOCAL_FAVORITES") || db.tableExists("BookmarkArticle") || db.tableExists("MangaColumnModel") {
                throw AnimeBoxesImportError.comicsBackup
            }
            guard try db.tableExists("BooruItem") else { throw AnimeBoxesImportError.format }
            var tags: [Int64: [String]] = [:]
            if try db.tableExists("ImageTag"), try db.tableExists("Tag") {
                for row in try Row.fetchAll(db, sql: "SELECT it.booruItemID AS item, t.name AS name FROM ImageTag it JOIN Tag t ON t.id = it.tagID WHERE it.booruItemID IN (SELECT id FROM BooruItem WHERE isFavourite = 1)") {
                    if let item = row["item"] as Int64?, let name = row["name"] as String?, !name.isEmpty { tags[item, default: []].append(name) }
                }
            }
            var builder = Builder(source: .imageAppDatabase)
            for row in try Row.fetchAll(db, sql: "SELECT * FROM BooruItem WHERE isFavourite = 1 ORDER BY id DESC") {
                let id: Int64 = row["id"] ?? 0
                builder.add(page: row["postURL"], preview: row["thumbnailURL"] as String?, sample: row["sampleURL"] as String?, file: row["fileURL"] as String?,
                            width: nil, height: nil, tags: tags[id] ?? [], format: nil, savedAt: 0)
            }
            if try db.tableExists("SearchHistory") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM SearchHistory ORDER BY id DESC") {
                    let text: String = row["searchText"] ?? ""
                    let date = (row["timestamp"] as String?).flatMap(OtherAppImport.parseDate)?.timeIntervalSince1970 ?? 0
                    builder.search(text, date: date, starred: (row["isFavourite"] as Int64?) == 1)
                }
            }
            return builder.backup()
        }
    }

    /// Collects posts by the server their page belongs to.
    private struct Builder {
        let source: Source
        var servers: [BooruServer] = []
        var favorites: [Favorite] = []
        var history: [Search] = []
        var skippedFavorites = 0
        var skippedHistory = 0
        var seen = Set<String>()

        init(source: Source) { self.source = source }

        mutating func add(page: String?, preview: Any?, sample: Any?, file: Any?, width: Any?, height: Any?, tags: Any?, format: String?, savedAt: Double) {
            guard let page, let found = AnimeBoxesBackup.postPage(page) else { skippedFavorites += 1; return }
            let server: BooruServer
            if let existing = servers.first(where: { $0.canonicalAddress == found.server.canonicalAddress }) { server = existing }
            else { server = found.server; servers.append(server) }
            let fileURL = AnimeBoxesBackup.mediaURL(file, base: server.baseURL)
            let list = AnimeBoxesBackup.tokens(tags)
            let post = BooruPost(serverID: server.id, postID: found.postID,
                                 previewURL: AnimeBoxesBackup.mediaURL(preview, base: server.baseURL),
                                 sampleURL: AnimeBoxesBackup.mediaURL(sample, base: server.baseURL), fileURL: fileURL,
                                 width: max(0, Int(AnimeBoxesBackup.integer(width) ?? 0)), height: max(0, Int(AnimeBoxesBackup.integer(height) ?? 0)),
                                 tags: list, artists: [], rating: "", score: 0,
                                 fileExtension: (format.flatMap { $0.isEmpty ? nil : $0 } ?? fileURL?.pathExtension ?? "").lowercased())
            if seen.insert(post.id).inserted { favorites.append(.init(post: post, savedAt: savedAt)) }
        }

        mutating func search(_ text: String, date: Double, starred: Bool) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { skippedHistory += 1; return }
            history.append(.init(text: text, date: date, starred: starred))
        }

        func backup() -> AnimeBoxesBackup {
            AnimeBoxesBackup(source: source, servers: servers, selectedIDs: [], favorites: favorites, history: history, blacklist: [],
                             skippedServers: 0, skippedFavorites: skippedFavorites, skippedHistory: skippedHistory, skippedRules: 0)
        }
    }
}

enum AnimeBoxesImportError: LocalizedError {
    case format, tooLarge, noServers, comicsBackup
    var errorDescription: String? {
        switch self {
        case .format: return L10n.text("Choose an Anime Boxes .abbj backup (version 1.0).")
        case .comicsBackup: return L10n.text("This is a comics app backup. Import it in Comics mode.")
        case .tooLarge: return L10n.text("This backup exceeds the 64 MB import limit.")
        case .noServers: return L10n.text("This backup contains no supported servers.")
        }
    }
}

struct AnimeBoxesImportOptions: Sendable {
    var history = true
    var blacklist = true
    var selection = true
    var folderID = "by-site"
}
struct AnimeBoxesImportResult: Sendable {
    let added: Int
    let duplicates: Int
    let serversAdded: Int
}

extension BooruStore {
    /// The entire merge commits together. Existing favorites keep custom folders and their original saved date.
    func importAnimeBoxes(_ backup: AnimeBoxesBackup, options: AnimeBoxesImportOptions) throws -> AnimeBoxesImportResult {
        guard !backup.servers.isEmpty else { throw AnimeBoxesImportError.noServers }
        let result = try database.write { db in
            var existing = try Row.fetchAll(db, sql: "SELECT payload FROM servers ORDER BY position").map { try JSONDecoder().decode(BooruServer.self, from: $0["payload"] as Data) }
            var mapping: [String: String] = [:]
            var serverCount = 0
            for imported in backup.servers {
                if let match = existing.first(where: { $0.canonicalAddress == imported.canonicalAddress }) { mapping[imported.id] = match.id }
                else {
                    try db.execute(sql: "INSERT INTO servers VALUES (?, ?, ?)", arguments: [imported.id, try JSONEncoder().encode(imported), existing.count])
                    mapping[imported.id] = imported.id; existing.append(imported); serverCount += 1
                }
            }
            if options.folderID == "anime-boxes" {
                try db.execute(sql: "INSERT OR IGNORE INTO folders VALUES ('anime-boxes', 'Anime Boxes', 4287784115, (SELECT COUNT(*) FROM folders))")
            } else if options.folderID == AnimeBoxesBackup.importedFolderID {
                try db.execute(sql: "INSERT OR IGNORE INTO folders VALUES (?, ?, 4287784115, (SELECT COUNT(*) FROM folders))", arguments: [AnimeBoxesBackup.importedFolderID, L10n.text("Imported")])
            }
            if options.folderID != "by-site" {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)", arguments: [options.folderID]) == true else { throw BooruError.invalidResponse }
            }
            var added = 0, duplicates = 0
            for favorite in backup.favorites {
                let old = favorite.post
                guard let id = mapping[old.serverID] else { continue }
                let post = BooruPost(serverID: id, postID: old.postID, previewURL: old.previewURL, sampleURL: old.sampleURL, fileURL: old.fileURL, width: old.width, height: old.height, tags: old.tags, artists: old.artists, rating: old.rating, score: old.score, fileExtension: old.fileExtension, poolIDs: old.poolIDs, metadataTags: old.metadataTags)
                let folderID = try Self.smartDestination(for: post, landing: options.folderID == "by-site" ? Self.defaultFolder(for: id, db: db) : options.folderID, db: db)
                try db.execute(sql: "INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)", arguments: [id, post.postID, try JSONEncoder().encode(post), favorite.savedAt, folderID])
                if db.changesCount > 0 {
                    added += 1
                    try TasteStore.record(.imported, item: Self.tasteItem(post, db: db), db: db)
                } else { duplicates += 1 }
            }
            if options.folderID == "by-site" { try Self.organizeLegacyImports(db: db) }
            for id in Set(mapping.values) {
                if options.history {
                    for search in backup.history {
                        try db.execute(sql: "INSERT INTO history VALUES (?, ?, ?) ON CONFLICT(server_id, query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)", arguments: [id, search.text, search.date])
                        if search.starred { try db.execute(sql: "INSERT OR IGNORE INTO saved_tags VALUES (?, ?, 'search')", arguments: [id, search.text]) }
                    }
                }
                if options.blacklist, !backup.blacklist.isEmpty {
                    let old = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: ["blacklist." + id]) ?? ""
                    var seen = Set<String>()
                    let merged = (old.components(separatedBy: .newlines) + backup.blacklist).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
                    try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES (?, ?)", arguments: ["blacklist." + id, merged])
                }
            }
            if options.selection {
                let ids = backup.selectedIDs.compactMap { mapping[$0] }
                if !ids.isEmpty { try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('selected_servers', ?)", arguments: [String(decoding: JSONEncoder().encode(ids), as: UTF8.self)]) }
            }
            return AnimeBoxesImportResult(added: added, duplicates: duplicates, serversAdded: serverCount)
        }
        try refresh()
        return result
    }
}
