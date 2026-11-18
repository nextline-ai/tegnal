import Foundation
import GRDB

/// Tag study's rows in the image database: what has been learned, each day's answers and what servers said about tags.
struct StudyStore {
    let database: DatabaseQueue
    init(_ booru: BooruStore) { database = booru.database }
    init(database: DatabaseQueue) { self.database = database }

    static func migrate(_ db: Database) throws {
        // Progress belongs to the tag, not to a server: the same tag means the same thing wherever it is used.
        try db.execute(sql: """
            CREATE TABLE study_progress (tag TEXT PRIMARY KEY NOT NULL, step INTEGER NOT NULL, due DOUBLE NOT NULL, correct INTEGER NOT NULL, wrong INTEGER NOT NULL, seen DOUBLE NOT NULL);
            CREATE TABLE study_days (day TEXT PRIMARY KEY NOT NULL, answered INTEGER NOT NULL, correct INTEGER NOT NULL);
            CREATE TABLE study_tags (address TEXT NOT NULL, name TEXT NOT NULL, payload BLOB NOT NULL, fetched DOUBLE NOT NULL, PRIMARY KEY(address, name));
            """)
    }

    private static func progress(_ row: Row) -> StudyProgress {
        StudyProgress(tag: row["tag"], step: row["step"], due: Date(timeIntervalSince1970: row["due"]),
                      correct: row["correct"], wrong: row["wrong"], seen: Date(timeIntervalSince1970: row["seen"]))
    }

    func progress() throws -> [String: StudyProgress] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM study_progress").map { row in
                let value = Self.progress(row); return (value.tag, value)
            })
        }
    }

    func days() throws -> [StudyDay] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM study_days ORDER BY day DESC LIMIT 400").map {
                StudyDay(day: $0["day"], answered: $0["answered"], correct: $0["correct"], xp: $0["xp"] ?? 0)
            }
        }
    }

    /// Records one answer and returns the tag's new progress.
    @discardableResult func answer(_ tag: String, right: Bool, now: Date = .now, calendar: Calendar = .current) throws -> StudyProgress {
        try database.write { db in
            let current = try Row.fetchOne(db, sql: "SELECT * FROM study_progress WHERE tag = ?", arguments: [tag]).map(Self.progress) ?? StudyProgress(tag: tag)
            let next = current.answered(right, now: now)
            try Self.write(next, db: db)
            try db.execute(sql: """
                INSERT INTO study_days (day, answered, correct) VALUES (?, 1, ?)
                ON CONFLICT(day) DO UPDATE SET answered = answered + 1, correct = correct + excluded.correct
                """, arguments: [StudyDay.key(now, calendar: calendar), right ? 1 : 0])
            return next
        }
    }

    static func write(_ value: StudyProgress, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO study_progress (tag, step, due, correct, wrong, seen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(tag) DO UPDATE SET step = excluded.step, due = excluded.due, correct = excluded.correct, wrong = excluded.wrong, seen = excluded.seen
            """, arguments: [value.tag, value.step, value.due.timeIntervalSince1970, value.correct, value.wrong, value.seen.timeIntervalSince1970])
    }

    /// Forgets everything learned; what servers said about tags is kept.
    func reset() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM study_progress")
            try db.execute(sql: "DELETE FROM study_days")
            try db.execute(sql: "DELETE FROM study_lessons")
            try db.execute(sql: "DELETE FROM study_awards")
            try db.execute(sql: "DELETE FROM study_stats")
        }
    }

    func info(_ name: String, address: String) throws -> StudyTagInfo? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM study_tags WHERE address = ? AND name = ?", arguments: [address, name])
                .flatMap { try? JSONDecoder().decode(StudyTagInfo.self, from: $0) }
        }
    }

    func counts(address: String) throws -> [String: Int] {
        try database.read { db in
            var counts: [String: Int] = [:]
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM study_tags WHERE address = ?", arguments: [address]) {
                if let info = try? JSONDecoder().decode(StudyTagInfo.self, from: data), let count = info.count { counts[info.name] = count }
            }
            return counts
        }
    }

    func save(_ info: StudyTagInfo, address: String) throws {
        let data = try JSONEncoder().encode(info)
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO study_tags (address, name, payload, fetched) VALUES (?, ?, ?, ?)",
                           arguments: [address, info.name, data, info.fetched.timeIntervalSince1970])
            // The cache is a convenience; old answers leave so that it cannot grow without end.
            try db.execute(sql: "DELETE FROM study_tags WHERE fetched < ?", arguments: [Date().timeIntervalSince1970 - StudyTagInfo.lifetime * 4])
        }
    }

    /// What a removed server said about tags goes with it.
    static func forget(address: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM study_tags WHERE address = ?", arguments: [address])
    }
}

extension BooruStore {
    var studyStore: StudyStore { .init(self) }
}

/// The numbers the study screens show, worked out from what is stored.
struct StudySummary: Equatable, Sendable {
    var total = 0
    var started = 0
    var learned = 0
    var due = 0
    var today = 0
    var todayCorrect = 0
    var streak = 0

    init() {}
    init(curriculum: StudyCurriculum, progress: [String: StudyProgress], days: [StudyDay], now: Date = .now, calendar: Calendar = .current) {
        total = curriculum.count
        for value in progress.values where curriculum.contains(value.tag) {
            if !value.isNew { started += 1 }
            if value.isLearned { learned += 1 }
            if value.isDue(now) { due += 1 }
        }
        let answered = Dictionary(uniqueKeysWithValues: days.filter(\.isStudied).map { ($0.day, $0) })
        let todayKey = StudyDay.key(now, calendar: calendar)
        today = answered[todayKey]?.answered ?? 0
        todayCorrect = answered[todayKey]?.correct ?? 0
        // A streak still counts before today's first answer, so that it is not lost at midnight.
        var date = answered[todayKey] == nil ? calendar.date(byAdding: .day, value: -1, to: now) ?? now : now
        while answered[StudyDay.key(date, calendar: calendar)] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
    }

    static func unit(_ unit: StudyUnit, progress: [String: StudyProgress]) -> (learned: Int, started: Int, total: Int) {
        let tags = unit.tags
        return (tags.filter { progress[$0.name]?.isLearned == true }.count, tags.filter { progress[$0.name].map { !$0.isNew } == true }.count, tags.count)
    }
}
