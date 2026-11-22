import Foundation
import GRDB

/// Portable values: local row IDs, cache paths and credentials never leave the device.
enum SyncValue: Codable, Equatable, Sendable {
    case text(String), integer(Int64), real(Double), blob(Data), null
    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .real(value)
        case .string(let value): self = .text(value)
        case .blob(let value): self = .blob(value)
        }
    }
    var databaseValue: DatabaseValue {
        switch self {
        case .text(let value): return value.databaseValue
        case .integer(let value): return value.databaseValue
        case .real(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        case .null: return .null
        }
    }
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
}

struct LibrarySyncRow: Codable, Equatable, Sendable {
    let table: String
    var values: [String: SyncValue]
    var key: String {
        let keys = Self.keys[table] ?? []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return table + ":" + ((try? encoder.encode(keys.map { values[$0] ?? .null })) ?? Data()).base64EncodedString()
    }
    var isFactoryDefault: Bool {
        // Every palette's first color counts, so devices on all versions agree.
        if table == "booru.folders" { return values["id"]?.string == "unsorted" && ([FolderPalette.unsorted] + FolderPalette.earlierUnsorted).contains(values["color"]?.integer) && values["position"]?.integer == 0 }
        if table == "manga.folders" { return values["sync_id"]?.string == "unsorted" && ([FolderPalette.unfiled] + FolderPalette.earlierUnfiled).contains(values["color"]?.integer) && values["sort_order"]?.integer == 1 }
        return false
    }
    static let keys: [String: [String]] = [
        "manga.library_order": ["key"], "manga.folders": ["sync_id"], "manga.works": ["gallery_id"], "manga.folder_works": ["folder_id", "work_id"],
        "manga.artists": ["name", "kind"], "manga.search_history": ["query"], "manga.saved_searches": ["query"],
        "booru.challenges": ["id"], "booru.servers": ["id"], "booru.folders": ["id"], "booru.favorites": ["server_id", "post_id"],
        "booru.saved_tags": ["server_id", "name", "kind"], "booru.history": ["server_id", "query"],
        "booru.settings": ["key"], "booru.study_progress": ["tag"], "booru.study_days": ["day"],
        "booru.study_lessons": ["lesson"], "booru.study_awards": ["id"], "booru.study_stats": ["name"],
        "preferences.manga": ["key"], "preferences.booru": ["key"],
        "recent.works": ["id"], "recent.images": ["server_id", "post_id"]
    ]
}

struct LibrarySyncChange: Codable, Equatable, Sendable {
    let row: LibrarySyncRow
    let timestamp: Double
    let device: String
    let deleted: Bool
    func isNewer(than other: Self) -> Bool {
        timestamp == other.timestamp ? device > other.device : timestamp > other.timestamp
    }
}

struct LibrarySyncLedger: Codable, Sendable {
    var version = 1
    var changes: [String: LibrarySyncChange] = [:]
    var baseline: [String: LibrarySyncRow] = [:]

    mutating func capture(_ snapshot: [String: LibrarySyncRow], device: String, now: Double = Date().timeIntervalSince1970) {
        let timestamp = max(now, (changes.values.map(\.timestamp).max() ?? 0) + 0.000001)
        for (key, row) in snapshot where baseline[key] != row {
            // A default folder no one has changed stays untouched when a new palette recolors it, so
            // it never wins over a color picked on another device that has not synced here yet.
            let untouched = row.isFactoryDefault && baseline[key]?.isFactoryDefault != false && (changes[key]?.timestamp ?? 0) == 0
            changes[key] = .init(row: row, timestamp: untouched ? 0 : timestamp, device: device, deleted: false)
        }
        for (key, row) in baseline where snapshot[key] == nil {
            let tombstone = LibrarySyncRow(table: row.table, values: row.values.filter { (LibrarySyncRow.keys[row.table] ?? []).contains($0.key) })
            changes[key] = .init(row: tombstone, timestamp: timestamp, device: device, deleted: true)
        }
        baseline = snapshot
    }
    /// A restore replaced the library: every row it holds is this device's newest edit, and every row
    /// known before that it lacks is deleted, so other devices follow it instead of filling it back in.
    /// Stamped no earlier than the restore, so edits made elsewhere after it still win.
    mutating func captureReplacement(_ snapshot: [String: LibrarySyncRow], device: String, at restored: Double) {
        let timestamp = max(restored, (changes.values.map(\.timestamp).max() ?? 0) + 0.000001)
        let known = Set(baseline.keys).union(changes.filter { !$0.value.deleted }.keys)
        for (key, row) in snapshot { changes[key] = .init(row: row, timestamp: timestamp, device: device, deleted: false) }
        for key in known where snapshot[key] == nil {
            guard let row = baseline[key] ?? changes[key]?.row else { continue }
            let tombstone = LibrarySyncRow(table: row.table, values: row.values.filter { (LibrarySyncRow.keys[row.table] ?? []).contains($0.key) })
            changes[key] = .init(row: tombstone, timestamp: timestamp, device: device, deleted: true)
        }
        baseline = snapshot
    }
    mutating func merge(_ remote: [String: LibrarySyncChange]) {
        for (key, change) in remote where key == change.row.key && LibrarySyncRow.keys[change.row.table] != nil {
            if changes[key].map({ change.isNewer(than: $0) }) ?? true { changes[key] = change }
        }
    }
}

struct LibrarySyncDocument: Codable, Sendable {
    var version = 1
    let changes: [String: LibrarySyncChange]
}
