import Foundation
import GRDB

/// A badge the learner can earn. Badges come in families, and most families have several, each harder than the last.
struct StudyAward: Identifiable, Hashable, Sendable {
    enum Family: String, CaseIterable, Sendable { case lessons, sections, streak, tags, perfect, combo, xp, studio, speed }
    enum Metal: Int, Sendable { case bronze, silver, gold, prism }

    let id: String
    let family: Family
    let metal: Metal
    let symbol: String
    /// English wording, which is also the key of its translations. A section's badge is named by the section instead.
    let title: String
    let detail: String
    /// How much of the family's measure earns it.
    let goal: Int
    /// For a section's badge: which section, its colour and its own name.
    var section: String?
    var color: String?
    var sectionTitle: StudyText?

    /// Every badge there is, in the order the gallery shows them.
    static func all(_ path: StudyPath = .bundled) -> [StudyAward] {
        func make(_ family: Family, _ rows: [(Int, String, String, String)]) -> [StudyAward] {
            rows.enumerated().map { index, row in
                .init(id: "\(family.rawValue)-\(row.0)", family: family, metal: Metal(rawValue: min(3, index)) ?? .gold,
                      symbol: row.1, title: row.2, detail: row.3, goal: row.0)
            }
        }
        var awards = make(.lessons, [
            (1, "figure.walk", "First Step", "Finish your first lesson."),
            (10, "book.fill", "Getting Going", "Finish 10 lessons."),
            (30, "books.vertical.fill", "Dedicated Learner", "Finish 30 lessons.")])
        // The last of the family is the whole path, however long the path is.
        awards.append(.init(id: "lessons-all", family: .lessons, metal: .prism, symbol: "graduationcap.fill", title: "Graduate", detail: "Finish every lesson on the map.", goal: max(1, path.lessons.count)))
        awards += path.sections.filter { !$0.lessons.isEmpty }.map { section in
            .init(id: "section-\(section.id)", family: .sections, metal: .gold, symbol: section.lessons.first?.symbol ?? "flag.fill", title: "", detail: "Finish every lesson of this section.",
                  goal: section.lessons.count, section: section.id, color: section.color, sectionTitle: section.title)
        }
        awards += make(.streak, [
            (3, "flame.fill", "Three in a Row", "Study 3 days in a row."),
            (7, "flame.fill", "A Full Week", "Study 7 days in a row."),
            (14, "flame.fill", "Two Weeks Strong", "Study 14 days in a row."),
            (30, "flame.fill", "A Month of Study", "Study 30 days in a row.")])
        awards += make(.tags, [
            (10, "tag.fill", "Tag Collector", "Learn 10 tags well."),
            (50, "tag.fill", "Tag Scholar", "Learn 50 tags well."),
            (150, "tag.fill", "Walking Dictionary", "Learn 150 tags well."),
            (300, "tag.fill", "Tag Master", "Learn 300 tags well.")])
        awards += make(.perfect, [
            (1, "star.fill", "Flawless", "Finish a lesson with three stars."),
            (10, "star.fill", "Sharp Eye", "Finish 10 lessons with three stars."),
            (25, "star.fill", "Perfectionist", "Finish 25 lessons with three stars.")])
        awards += make(.combo, [
            (5, "bolt.horizontal.fill", "Warming Up", "Get 5 answers right in a row."),
            (10, "bolt.horizontal.fill", "Hot Streak", "Get 10 answers right in a row."),
            (20, "bolt.horizontal.fill", "Can't Be Stopped", "Get 20 answers right in a row.")])
        awards += make(.xp, [
            (100, "bolt.fill", "First Hundred", "Earn 100 XP."),
            (500, "bolt.fill", "Five Hundred Club", "Earn 500 XP."),
            (2000, "bolt.fill", "Two Thousand Strong", "Earn 2,000 XP.")])
        awards += [
            .init(id: "studio-key", family: .studio, metal: .bronze, symbol: "key.fill", title: "Connected", detail: "Save your Civitai API key.", goal: 1),
            .init(id: "studio-1", family: .studio, metal: .silver, symbol: "wand.and.stars", title: "First Picture", detail: "Generate your first picture.", goal: 1),
            .init(id: "studio-3", family: .studio, metal: .silver, symbol: "slider.horizontal.3", title: "Advanced Unlocked", detail: "Generate 3 pictures. This opens the generator's advanced settings.", goal: StudyAward.advancedPictures),
            .init(id: "studio-10", family: .studio, metal: .gold, symbol: "photo.stack.fill", title: "Studio Regular", detail: "Generate 10 pictures.", goal: 10),
            .init(id: "studio-50", family: .studio, metal: .prism, symbol: "paintpalette.fill", title: "Prolific", detail: "Generate 50 pictures.", goal: 50)]
        awards += make(.speed, [
            (10, "hare.fill", "Quick Fingers", "Score 10 in a Speed Round."),
            (20, "hare.fill", "Lightning", "Score 20 in a Speed Round.")])
        return awards
    }

    /// The pictures to generate before the generator shows its advanced settings.
    static let advancedPictures = 3

    var name: String { sectionTitle?.resolved() ?? L10n.text(title) }
    var explanation: String { L10n.text(detail) }
}

extension StudyAward.Family {
    var title: String {
        L10n.text(["lessons": "Lessons", "sections": "Sections", "streak": "Day streak", "tags": "Tags", "perfect": "Perfect Lessons", "combo": "Right in a Row",
                   "xp": "Experience", "studio": "Studio", "speed": "Speed Round"][rawValue] ?? "")
    }
}

/// What the learner has done so far, as the numbers badges are measured by.
struct StudyFacts: Equatable, Sendable {
    var lessons = 0
    /// Lessons finished in each section, by the section's identifier.
    var sections: [String: Int] = [:]
    var streak = 0
    var learned = 0
    var perfect = 0
    var combo = 0
    var xp = 0
    var key = false
    var pictures = 0
    var speed = 0

    init() {}
    init(path: StudyPath, records: [String: StudyLessonRecord], days: [StudyDay], progress: [String: StudyProgress], stats: [String: Int], now: Date = .now, calendar: Calendar = .current) {
        lessons = path.lessons.filter { records[$0.id] != nil }.count
        for section in path.sections { sections[section.id] = section.lessons.filter { records[$0.id] != nil }.count }
        // The longest run ever reached counts, so that a badge in sight is not lost to one missed day.
        streak = max(StudySummary(curriculum: .init(units: []), progress: [:], days: days, now: now, calendar: calendar).streak, stats[StudyCounter.streak] ?? 0)
        learned = progress.values.filter(\.isLearned).count
        perfect = records.values.filter { $0.stars >= 3 }.count
        combo = stats[StudyCounter.combo] ?? 0
        xp = days.reduce(0) { $0 + $1.xp }
        key = (stats[StudyCounter.key] ?? 0) > 0
        pictures = stats[StudyCounter.pictures] ?? 0
        speed = stats[StudyCounter.speed] ?? 0
    }

    /// How far along the learner is toward a badge, in the badge's own measure.
    func value(for award: StudyAward) -> Int {
        switch award.family {
        case .lessons: lessons
        case .sections: sections[award.section ?? ""] ?? 0
        case .streak: streak
        case .tags: learned
        case .perfect: perfect
        case .combo: combo
        case .xp: xp
        case .studio: award.id == "studio-key" ? (key ? 1 : 0) : pictures
        case .speed: speed
        }
    }
    func has(_ award: StudyAward) -> Bool { value(for: award) >= award.goal }
    /// From zero to one.
    func progress(_ award: StudyAward) -> Double { award.goal <= 0 ? 1 : min(1, Double(value(for: award)) / Double(award.goal)) }
}

/// Counters kept for badges that nothing else in the store remembers.
enum StudyCounter {
    static let combo = "combo", streak = "streak", key = "key", pictures = "pictures", speed = "speed"
}

struct StudyAwardRecord: Hashable, Sendable {
    let id: String
    let earned: Date
    /// False until its celebration has been shown.
    var seen: Bool
}

extension StudyStore {
    static func migrateAwards(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE study_awards (id TEXT PRIMARY KEY NOT NULL, earned DOUBLE NOT NULL, seen INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE study_stats (name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL);
            """)
    }

    func awards() throws -> [String: StudyAwardRecord] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, earned, seen FROM study_awards").map {
                ($0["id"] as String, StudyAwardRecord(id: $0["id"], earned: Date(timeIntervalSince1970: $0["earned"]), seen: ($0["seen"] as Int) != 0))
            })
        }
    }

    /// Records badges as earned. One already earned keeps its date.
    func grant(_ ids: [String], seen: Bool = false, now: Date = .now) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            for id in ids {
                try db.execute(sql: "INSERT OR IGNORE INTO study_awards (id, earned, seen) VALUES (?, ?, ?)", arguments: [id, now.timeIntervalSince1970, seen ? 1 : 0])
            }
        }
    }

    func markSeen(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in for id in ids { try db.execute(sql: "UPDATE study_awards SET seen = 1 WHERE id = ?", arguments: [id]) } }
    }

    func stats() throws -> [String: Int] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT name, value FROM study_stats").map { ($0["name"] as String, $0["value"] as Int) })
        }
    }

    /// Raises a counter to a value; a counter never goes down.
    func raise(_ name: String, to value: Int) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO study_stats (name, value) VALUES (?, ?)
                ON CONFLICT(name) DO UPDATE SET value = MAX(value, excluded.value)
                """, arguments: [name, value])
        }
    }
}

/// Works out which badges have been earned, and hands back the ones still to be celebrated.
@MainActor
enum StudyAwards {
    static func facts(_ store: BooruStore, path: StudyPath = .bundled) -> StudyFacts {
        let study = store.studyStore
        let days = (try? study.days()) ?? []
        return StudyFacts(path: path, records: (try? study.lessons()) ?? [:], days: days, progress: (try? study.progress()) ?? [:], stats: (try? study.stats()) ?? [:])
    }

    /// Brings the counters and the earned badges up to date. Returns the badges earned but not yet shown, in gallery order.
    @discardableResult
    static func refresh(_ store: BooruStore, path: StudyPath = .bundled, generation: GenerationStore = .shared) -> [StudyAward] {
        let study = store.studyStore
        try? study.raise(StudyCounter.pictures, to: generation.pictures.count)
        if generation.hasKey { try? study.raise(StudyCounter.key, to: 1) }
        let days = (try? study.days()) ?? []
        try? study.raise(StudyCounter.streak, to: StudySummary(curriculum: .init(units: []), progress: [:], days: days).streak)
        let facts = facts(store, path: path)
        let all = StudyAward.all(path)
        let known = (try? study.awards()) ?? [:]
        try? study.grant(all.filter { facts.has($0) && known[$0.id] == nil }.map(\.id))
        let records = (try? study.awards()) ?? [:]
        return all.filter { records[$0.id]?.seen == false }
    }
}
