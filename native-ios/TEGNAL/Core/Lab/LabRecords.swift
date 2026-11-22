import Foundation
import GRDB

/// One fact about the lab, as kept in the image database's `lab_records` table so it travels in iCloud sync and backups.
///
/// Keys: `card:<episode>` (engraved), `fail:<id>` (망작 hung), `edition:<id>` (value = 연구비 paid), `purchase:<item>` (value = count,
/// text = `{"price":…,"baseline":…}`), and `state:type` (text = type id), `state:greeted`, `state:grandfathered`, `state:seenEdition` (text).
/// Merging two devices keeps the larger value and the earlier time, so nothing earned is lost.
struct LabRecord: Equatable, Sendable {
    var key: String
    var value: Int
    var text: String?
    var at: Date
}

/// Where the lab keeps its records.
protocol LabRecordStore: Sendable {
    func all() throws -> [LabRecord]
    /// Makes the stored records exactly these, writing only what changed.
    func replace(with records: [LabRecord]) throws
}

/// The records in the image database.
struct LabDatabaseRecords: LabRecordStore {
    let database: DatabaseQueue

    static func migrate(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE lab_records (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL DEFAULT 0, text TEXT, at DOUBLE NOT NULL)")
    }

    func all() throws -> [LabRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value, text, at FROM lab_records").map {
                LabRecord(key: $0["key"], value: $0["value"], text: $0["text"], at: Date(timeIntervalSince1970: $0["at"]))
            }
        }
    }

    func replace(with records: [LabRecord]) throws {
        try database.write { db in
            var existing: [String: LabRecord] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value, text, at FROM lab_records") {
                existing[row["key"]] = LabRecord(key: row["key"], value: row["value"], text: row["text"], at: Date(timeIntervalSince1970: row["at"]))
            }
            let keys = Set(records.map(\.key))
            for key in existing.keys where !keys.contains(key) {
                try db.execute(sql: "DELETE FROM lab_records WHERE key = ?", arguments: [key])
            }
            for record in records where existing[record.key] != record {
                try db.execute(sql: """
                    INSERT INTO lab_records (key, value, text, at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, text = excluded.text, at = excluded.at
                    """, arguments: [record.key, record.value, record.text, record.at.timeIntervalSince1970])
            }
        }
    }
}

/// Records kept in memory, for tests and before the database is reached.
final class LabMemoryRecords: LabRecordStore, @unchecked Sendable {
    private var records: [String: LabRecord] = [:]
    private let lock = NSLock()
    init() {}
    func all() throws -> [LabRecord] { lock.withLock { Array(records.values) } }
    func replace(with records: [LabRecord]) throws { lock.withLock { self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) }) } }
}

extension LabProgress {
    init(records: [LabRecord]) {
        self.init()
        for record in records {
            let parts = record.key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (kind, id) = (parts[0], parts[1])
            switch kind {
            case "card": cards[id] = record.at
            case "fail": fails[id] = record.at
            case "edition": editions[id] = record.value
            case "purchase":
                struct Detail: Decodable { var price: Int; var baseline: Int? }
                let detail = record.text.flatMap { try? JSONDecoder().decode(Detail.self, from: Data($0.utf8)) }
                purchases[id] = LabPurchase(price: detail?.price ?? 0, count: record.value, date: record.at, baseline: detail?.baseline)
            case "state":
                switch id {
                case "type": type = record.text; diagnosed = record.at
                case "greeted": greeted = record.value > 0
                case "grandfathered": grandfathered = record.value > 0
                case "seenEdition": seenEdition = record.text
                default: break
                }
            default: break
            }
        }
    }

    var records: [LabRecord] {
        var list: [LabRecord] = []
        for (id, at) in cards { list.append(LabRecord(key: "card:" + id, value: 1, at: at)) }
        for (id, at) in fails { list.append(LabRecord(key: "fail:" + id, value: 1, at: at)) }
        // Editions have no date of their own here; the day in the id is enough to order them.
        for (id, paid) in editions { list.append(LabRecord(key: "edition:" + id, value: paid, at: Date(timeIntervalSince1970: 0))) }
        for (id, purchase) in purchases {
            let detail = purchase.baseline.map { "{\"price\":\(purchase.price),\"baseline\":\($0)}" } ?? "{\"price\":\(purchase.price)}"
            list.append(LabRecord(key: "purchase:" + id, value: purchase.count, text: detail, at: purchase.date))
        }
        if let type { list.append(LabRecord(key: "state:type", value: 1, text: type, at: diagnosed ?? Date(timeIntervalSince1970: 0))) }
        if greeted { list.append(LabRecord(key: "state:greeted", value: 1, at: Date(timeIntervalSince1970: 0))) }
        if grandfathered { list.append(LabRecord(key: "state:grandfathered", value: 1, at: Date(timeIntervalSince1970: 0))) }
        if let seenEdition { list.append(LabRecord(key: "state:seenEdition", value: 1, text: seenEdition, at: Date(timeIntervalSince1970: 0))) }
        return list
    }
}
