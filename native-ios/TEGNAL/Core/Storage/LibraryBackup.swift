import Foundation
import GRDB

enum LibraryBackupError: LocalizedError {
    case invalid
    var errorDescription: String? { L10n.text("This backup is invalid, too large, or uses an unsupported version.") }
}

/// One portable document for both libraries. Media, caches and credentials stay local.
struct LibraryBackup: Codable, Sendable {
    var format = "tegnal-library"
    var version = 1
    var exportedAt = ISO8601DateFormatter().string(from: Date())
    var comics: MangaBackup
    var images: BooruBackup
    var challenges: ChallengeBackup
    static let maximumBytes = 128 * 1024 * 1024

    static func capture(database: AppDatabase, images: BooruStore) throws -> Self {
        var imageBackup = try images.exportBackup()
        for index in imageBackup.favorites.indices { imageBackup.favorites[index].post = imageBackup.favorites[index].post.cloudMetadata }
        let value = try Self(comics: MangaBackup.capture(database), images: imageBackup,
                             challenges: ChallengeBackup(games: ChallengeStore(images).definitions()))
        try value.validate()
        return value
    }

    func validate() throws {
        guard format == "tegnal-library", version == 1 else { throw LibraryBackupError.invalid }
        try comics.validate(); try images.validate(); try challenges.validate()
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw LibraryBackupError.invalid }
        return data
    }

    static func export(database: AppDatabase, images: BooruStore) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tegnal-backup.json")
        try capture(database: database, images: images).encoded().write(to: url, options: .atomic)
        return url
    }
}

/// A missing mode in an older backup never clears the other mode's local library.
struct LibraryBackupImport: Sendable {
    var comics: MangaBackup?
    var images: BooruBackup?
    var challenges: ChallengeBackup?
    var workCount: Int { (comics?.works.count ?? 0) + (images?.favorites.count ?? 0) }
    var folderCount: Int { (comics?.folders.count ?? 0) + (images?.folders.count ?? 0) }

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= LibraryBackup.maximumBytes else { throw LibraryBackupError.invalid }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= LibraryBackup.maximumBytes,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LibraryBackupError.invalid }
        let decoder = JSONDecoder()
        let value: Self
        if object["format"] as? String == "tegnal-library" {
            let combined = try decoder.decode(LibraryBackup.self, from: data)
            try combined.validate()
            value = .init(comics: combined.comics, images: combined.images, challenges: combined.challenges)
        } else if object["format"] != nil {
            // Keep standalone image and challenge imports compatible with their existing formats.
            if let images = try? BooruBackup.decode(data) { value = .init(images: images) }
            else if let challenges = try? ChallengeBackup.decode(data) { value = .init(challenges: challenges) }
            else { throw LibraryBackupError.invalid }
        } else {
            if let folders = object["folders"] as? [[String: Any]] {
                object["folders"] = folders.map { MangaImportMetadata.normalized($0) }
            }
            value = try .init(comics: decoder.decode(MangaBackup.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        try value.validate()
        return value
    }

    func validate() throws {
        guard comics != nil || images != nil || challenges != nil else { throw LibraryBackupError.invalid }
        try comics?.validate(); try images?.validate(); try challenges?.validate()
    }

    /// Validate everything before touching either library. An error during either
    /// write body rolls back both transactions; records absent from the file stay local.
    func restore(database: AppDatabase, images store: BooruStore) throws {
        try validate()
        try Task.checkCancellation()
        try database.dbWriter.write { mangaDB in
            try store.database.write { imageDB in
                try comics?.restore(in: mangaDB)
                if let images { try store.restoreBackup(images, in: imageDB) }
                if let challenges {
                    for game in challenges.games {
                        try imageDB.execute(sql: "INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                                            arguments: [game.id, try JSONEncoder().encode(game)])
                    }
                }
                try Task.checkCancellation()
            }
        }
    }
}

/// The original comics JSON shape remains readable, with portable fields only.
struct MangaBackup: Codable, Sendable {
    struct FolderRecord: Codable, Sendable {
        var id: Int64?
        var name: String
        var color: Int64?
        var sort_order: Int?
        var source_group_id: Int64?
        var description: String?
    }
    struct WorkRecord: Codable, Sendable {
        var gallery_id: Int64
        var title: String?
        var artists: String?
        var note: String?
        var bookmarked_at: String?
        var language: String?
        var type: String?
        var series: String?
        var groups: String?
        var tags: String?
        var published_at: String?
        var thumb_page: Int?
        var folders: [String]?
    }
    struct ArtistRecord: Codable, Sendable { var name: String; var kind: Int?; var note: String? }
    struct SearchRecord: Codable, Sendable { var query: String; var used_at: Double }
    var version = 2
    var exported_at: String?
    var folders: [FolderRecord]
    var works: [WorkRecord]
    var artists: [ArtistRecord]
    var history: [SearchRecord]?
    var saved_searches: [String]?

    static func capture(_ database: AppDatabase) throws -> Self {
        try database.dbWriter.read { db in
            let folders = try AppDatabase.fetchFolders(db)
            let works = try AppDatabase.fetchWorks(db)
            let artists = try ArtistMemo.order(ArtistMemo.Columns.name.asc).fetchAll(db)
            return Self(exported_at: ISO8601DateFormatter().string(from: Date()), folders: folders.map {
                .init(id: $0.id, name: $0.name, color: $0.color, sort_order: $0.sortOrder, source_group_id: $0.sourceGroupId, description: $0.description)
            }, works: works.map {
                .init(gallery_id: $0.galleryId, title: $0.title, artists: $0.artists, note: $0.note, bookmarked_at: $0.bookmarkedAt,
                      language: $0.language, type: $0.type, series: $0.series, groups: $0.groups, tags: $0.tags,
                      published_at: $0.publishedAt, thumb_page: $0.thumbPage, folders: $0.folders.map(\.name))
            }, artists: artists.map { .init(name: $0.name, kind: $0.kind, note: $0.note) },
                        history: try Row.fetchAll(db, sql: "SELECT * FROM search_history ORDER BY used_at DESC").map { .init(query: $0["query"], used_at: $0["used_at"]) },
                        saved_searches: try String.fetchAll(db, sql: "SELECT query FROM saved_searches ORDER BY query"))
        }
    }

    func validate() throws {
        let names = Set(folders.map(\.name))
        guard [1, 2].contains(version), names.count == folders.count,
              folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (0...0xFFFFFFFF).contains($0.color ?? 0xFF2563EB) }),
              Set(works.map(\.gallery_id)).count == works.count,
              works.allSatisfy({ $0.gallery_id > 0 && ($0.thumb_page ?? 1) > 0 && Set($0.folders ?? []).isSubset(of: names) }),
              artists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && SavedCollectionKind.allCases.compactMap(\.mangaKind).contains($0.kind ?? 0) }),
              Set(artists.map { $0.name + "\u{0}" + String($0.kind ?? 0) }).count == artists.count,
              (history ?? []).allSatisfy({ !$0.query.isEmpty && $0.used_at.isFinite }),
              (saved_searches ?? []).allSatisfy({ !$0.isEmpty }) else { throw LibraryBackupError.invalid }
    }

    func restore(in db: Database) throws {
        var mapping: [String: Int64] = [:]
        for record in folders {
            var folder = try Folder.filter(Folder.Columns.name == record.name).fetchOne(db)
                ?? Folder(name: record.name)
            folder.color = record.color ?? folder.color
            folder.description = record.description ?? folder.description
            folder.sourceGroupId = record.source_group_id ?? folder.sourceGroupId
            try folder.save(db)
            let id = folder.id!
            mapping[record.name] = id
            try db.execute(sql: "UPDATE folders SET sync_id = COALESCE(sync_id, ?) WHERE id = ?",
                           arguments: [record.name == "미분류" ? "unsorted" : UUID().uuidString, id])
        }
        let importedOrder = folders.enumerated().sorted {
            ($0.element.sort_order ?? $0.offset) < ($1.element.sort_order ?? $1.offset)
        }.compactMap { mapping[$0.element.name] }
        let remaining = try Int64.fetchAll(db, sql: "SELECT id FROM folders ORDER BY sort_order, id").filter { !importedOrder.contains($0) }
        for (position, id) in (importedOrder + remaining).enumerated() {
            try db.execute(sql: "UPDATE folders SET sort_order = ? WHERE id = ?", arguments: [position, id])
        }
        let order = try String.fetchAll(db, sql: "SELECT sync_id FROM folders WHERE sync_id IS NOT NULL ORDER BY sort_order, id")
        try db.execute(sql: "INSERT OR REPLACE INTO library_order VALUES ('folders', ?)", arguments: [try JSONEncoder().encode(order)])
        for record in works {
            let existing = try Work.filter(Work.Columns.galleryId == record.gallery_id).fetchOne(db)
            var work = existing ?? Work(galleryId: record.gallery_id)
            work.title = record.title ?? work.title; work.artists = record.artists ?? work.artists
            work.note = record.note ?? work.note; work.language = record.language ?? work.language
            work.type = record.type ?? work.type; work.series = record.series ?? work.series
            work.groups = record.groups ?? work.groups; work.tags = record.tags ?? work.tags
            work.bookmarkedAt = record.bookmarked_at ?? work.bookmarkedAt
            work.publishedAt = record.published_at ?? work.publishedAt; work.thumbPage = record.thumb_page ?? work.thumbPage
            try work.save(db)
            var destinations = (record.folders ?? []).compactMap { mapping[$0] }
            if destinations.isEmpty, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder_works WHERE work_id = ?", arguments: [work.id]) == 0 {
                destinations = [try AppDatabase.unfiledFolder(in: db).id!]
            }
            for id in destinations {
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [id, work.id, work.bookmarkedAt])
            }
            try TasteStore.record(existing == nil ? .imported : .metadata, item: .comic(work.galleryId, tags: work.tags), db: db)
        }
        for artist in artists {
            try db.execute(sql: "INSERT INTO artists (name, kind, note, bookmarked_at) VALUES (?, ?, ?, ?) ON CONFLICT(name, kind) DO UPDATE SET note = COALESCE(excluded.note, artists.note)",
                           arguments: [artist.name, artist.kind ?? 0, artist.note, ISO8601DateFormatter().string(from: Date())])
        }
        for search in history ?? [] {
            try db.execute(sql: "INSERT INTO search_history VALUES (?, ?) ON CONFLICT(query) DO UPDATE SET used_at = MAX(used_at, excluded.used_at)", arguments: [search.query, search.used_at])
        }
        for query in saved_searches ?? [] { try db.execute(sql: "INSERT OR IGNORE INTO saved_searches VALUES (?)", arguments: [query]) }
    }
}

/// Kept for callers which need to read/export the previous comics-only format.
enum MangaLibraryBackup {
    static func export(database: AppDatabase) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tegnal-comics-\(UUID().uuidString).json")
        try encoder.encode(MangaBackup.capture(database)).write(to: url, options: .atomic)
        return url
    }
}
