import Foundation
import GRDB
import Observation
import UIKit

/// An add-on kept in the app, with whether it is on.
struct InstalledAddon: Identifiable, Equatable, Sendable {
    let addon: Addon
    var enabled: Bool
    let installed: Date
    /// SHA-256 of the file as it was opened, so that a learner can compare it with what its maker published.
    let digest: String
    var id: String { addon.id }
}

/// A learning-mode track brought by an add-on, ready for the path.
struct StudyTrack: Identifiable, Sendable {
    /// The add-on's identifier.
    let id: String
    let title: StudyText
    let summary: StudyText
    let color: String
    let symbol: String
    /// The track's own sections. Its lesson identifiers start with `addon:<add-on>:` so that they never meet the main path's.
    let path: StudyPath
    /// The tags the track teaches beyond the app's curriculum.
    let unit: StudyUnit?

    func complete(_ records: [String: StudyLessonRecord]) -> Bool { !path.lessons.isEmpty && path.lessons.allSatisfy { records[$0.id] != nil } }
}

/// What the add-ons that are on change, gathered in one place.
struct AddonEffects: Sendable {
    var enabledIDs: Set<String> = []
    /// Tag (lowercase, underscores) to the words shown for it.
    var translations: [String: String] = [:]
    var comicsInclude: [String] = []
    var comicsExclude: [String] = []
    var imageExclude: [String] = []
    var tracks: [StudyTrack] = []

    static let challengePrefix = "addon:"
    static func challengeID(addon: String, game: String) -> String { challengePrefix + addon + ":" + game }
    static func lessonID(addon: String, lesson: String) -> String { "addon:" + addon + ":" + lesson }

    /// Add-ons installed later win where two translate the same tag.
    init(_ installed: [InstalledAddon] = []) {
        var seenInclude = Set<String>(), seenExclude = Set<String>(), seenRules = Set<String>()
        for item in installed.sorted(by: { $0.installed < $1.installed }) where item.enabled {
            let addon = item.addon, contents = addon.contents
            enabledIDs.insert(addon.id)
            for (tag, words) in contents.tagTranslations?.entries ?? [:] { translations[AddonCheck.tagKey(tag)] = words }
            for term in contents.searchTags?.comics?.include ?? [] where seenInclude.insert(term.lowercased()).inserted { comicsInclude.append(term) }
            for term in contents.searchTags?.comics?.exclude ?? [] where seenExclude.insert(term.lowercased()).inserted { comicsExclude.append(term) }
            for rule in contents.searchTags?.images?.exclude ?? [] where seenRules.insert(rule.lowercased()).inserted { imageExclude.append(rule) }
            if let track = contents.learningTrack { tracks.append(Self.track(track, addon: addon.id)) }
        }
    }

    /// The words shown for a tag, by its full name (`female:glasses`) or, failing that, its name without the namespace.
    func translation(_ tag: String) -> String? {
        guard !translations.isEmpty else { return nil }
        let key = AddonCheck.tagKey(tag)
        if let words = translations[key] { return words }
        if let colon = key.firstIndex(of: ":"), key.index(after: colon) < key.endIndex { return translations[String(key[key.index(after: colon)...])] }
        return nil
    }

    private static func symbol(_ name: String?, fallback: String) -> String {
        guard let name, UIImage(systemName: name) != nil else { return fallback }
        return name
    }

    private static func track(_ track: AddonTrack, addon: String) -> StudyTrack {
        let sections = track.sections.map { section in
            StudyPathSection(id: "addon:" + addon + ":" + section.id, title: section.title, summary: section.summary, color: section.color, lessons: section.lessons.map { lesson in
                let steps = lesson.steps?.map { step -> StudyPathLesson.Step in
                    var step = step
                    if var card = step.card {
                        card.symbol = card.symbol.map { symbol($0, fallback: "sparkles") }
                        card.action = nil
                        step.card = card
                    }
                    return step
                }
                return StudyPathLesson(id: lessonID(addon: addon, lesson: lesson.id), kind: lesson.kind, symbol: symbol(lesson.symbol, fallback: "book.fill"),
                                       title: lesson.title, summary: lesson.summary, tags: lesson.tags, steps: steps)
            })
        }
        let unit = (track.groups ?? []).isEmpty ? nil : StudyUnit(id: "addon:" + addon, title: track.title, summary: track.summary, groups: track.groups ?? [])
        return StudyTrack(id: addon, title: track.title, summary: track.summary, color: track.color, symbol: symbol(track.symbol, fallback: "graduationcap.fill"),
                          path: StudyPath(version: 3, sections: sections), unit: unit)
    }
}

/// The effects of the add-ons that are on, read by searches, tag lists and learning mode.
/// Reads are safe from any thread; changes are made on the main thread.
@Observable
final class AddonRuntime: @unchecked Sendable {
    static let shared = AddonRuntime()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var state = AddonEffects()

    var effects: AddonEffects {
        access(keyPath: \.effects)
        return lock.withLock { state }
    }

    func apply(_ next: AddonEffects) {
        withMutation(keyPath: \.effects) { lock.withLock { state = next } }
    }

    /// Reads the add-ons again after one was added, changed or removed.
    func reload(_ booru: BooruStore) {
        apply(AddonEffects((try? AddonStore(booru).installed()) ?? []))
    }

    /// The words to show for a tag, or nil to show the tag itself.
    func translation(_ tag: String) -> String? {
        lock.withLock { state.translations.isEmpty } ? nil : effects.translation(tag)
    }
}

/// Add-ons kept in the image-mode database, beside the challenges they may bring.
struct AddonStore {
    let database: DatabaseQueue
    init(_ booru: BooruStore) { database = booru.database }
    init(database: DatabaseQueue) { self.database = database }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE addons (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, installed DOUBLE NOT NULL, digest TEXT NOT NULL);
            """)
    }

    /// Every add-on kept, checked again on the way out. One that no longer passes is left out, never used.
    func installed() throws -> [InstalledAddon] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload, enabled, installed, digest FROM addons ORDER BY installed").compactMap { row in
                guard let addon = try? JSONDecoder().decode(Addon.self, from: row["payload"] as Data), (try? addon.validate()) != nil else { return nil }
                return InstalledAddon(addon: addon, enabled: (row["enabled"] as Int) != 0, installed: Date(timeIntervalSince1970: row["installed"]), digest: row["digest"])
            }
        }
    }

    /// Adds an add-on, or replaces the one with the same identifier. A replaced add-on stays on or off as it was.
    func install(_ addon: Addon, digest: String, now: Date = .now) throws {
        try addon.validate()
        let payload = try JSONEncoder().encode(addon)
        try database.write { db in
            let enabled = try Int.fetchOne(db, sql: "SELECT enabled FROM addons WHERE id = ?", arguments: [addon.id]) ?? 1
            let installed = try Double.fetchOne(db, sql: "SELECT installed FROM addons WHERE id = ?", arguments: [addon.id]) ?? now.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO addons (id, payload, enabled, installed, digest) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, digest = excluded.digest
                """, arguments: [addon.id, payload, enabled, installed, digest])
            try Self.writeChallenges(addon, db: db)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) throws {
        try database.write { db in try db.execute(sql: "UPDATE addons SET enabled = ? WHERE id = ?", arguments: [enabled ? 1 : 0, id]) }
    }

    /// Removes an add-on and the challenges it brought. Lessons finished in its track stay in the learner's record.
    func remove(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM addons WHERE id = ?", arguments: [id])
            let prefix = AddonEffects.challengeID(addon: id, game: "")
            for table in ["challenges", "challenge_sessions"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE substr(id, 1, ?) = ?", arguments: [prefix.count, prefix])
            }
        }
    }

    /// The add-on's challenges join the challenge library under identifiers of its own. An update replaces them,
    /// and drops the ones it no longer has.
    private static func writeChallenges(_ addon: Addon, db: Database) throws {
        let prefix = AddonEffects.challengeID(addon: addon.id, game: "")
        let games = (addon.contents.challenges ?? []).map { game -> ChallengeDefinition in
            var game = game; game.id = AddonEffects.challengeID(addon: addon.id, game: game.id); return game
        }
        let keep = Set(games.map(\.id))
        let existing = try String.fetchAll(db, sql: "SELECT id FROM challenges WHERE substr(id, 1, ?) = ?", arguments: [prefix.count, prefix])
        for id in existing where !keep.contains(id) {
            try db.execute(sql: "DELETE FROM challenges WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM challenge_sessions WHERE id = ?", arguments: [id])
        }
        for game in games {
            try game.validate()
            try db.execute(sql: "INSERT INTO challenges (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                           arguments: [game.id, try JSONEncoder().encode(game)])
        }
    }
}
