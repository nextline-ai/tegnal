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
    /// Installed from the official add-ons, checked against TEGNAL's signed catalog, rather than opened from a file.
    var official = false
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
    /// The add-ons that are on, by the mode they belong to.
    var enabledModes: [String: AddonMode] = [:]
    /// Tag (lowercase, underscores) to the words shown for it, kept apart for each mode.
    var translations: [AddonMode: [String: String]] = [:]
    /// Translated words (folded: lowercase, single spaces, no width or diacritic differences) back to their tag, for searches typed in them.
    /// The first tag given a wording keeps it.
    var tagsByWords: [AddonMode: [String: String]] = [:]
    /// Every translation of a mode as (folded words, tag, words), for suggestions while a search is typed.
    var searchable: [AddonMode: [(folded: String, tag: String, words: String)]] = [:]
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
        let enabled = installed.sorted(by: { $0.installed < $1.installed }).filter(\.enabled)
        for item in enabled {
            let addon = item.addon, contents = addon.contents
            enabledIDs.insert(addon.id)
            enabledModes[addon.id] = addon.mode
            for (tag, words) in contents.tagTranslations?.entries ?? [:] { translations[addon.mode, default: [:]][AddonCheck.tagKey(tag)] = words }
            for term in contents.searchTags?.comics?.include ?? [] where seenInclude.insert(term.lowercased()).inserted { comicsInclude.append(term) }
            for term in contents.searchTags?.comics?.exclude ?? [] where seenExclude.insert(term.lowercased()).inserted { comicsExclude.append(term) }
            for rule in contents.searchTags?.images?.exclude ?? [] where seenRules.insert(rule.lowercased()).inserted { imageExclude.append(rule) }
            if let track = contents.learningTrack { tracks.append(Self.track(track, addon: addon.id)) }
        }
        for (mode, entries) in translations {
            var byWords: [String: String] = [:], list: [(folded: String, tag: String, words: String)] = []
            for (tag, words) in entries.sorted(by: { $0.key < $1.key }) {
                let folded = Self.fold(words)
                if byWords[folded] == nil { byWords[folded] = tag }
                list.append((folded, tag, words))
            }
            tagsByWords[mode] = byWords
            searchable[mode] = list
        }
    }

    /// Namespaces of general tags. Comics pages name a general tag by who has it (`female:`, `male:`, `mixed:`, `other:`),
    /// while a translation may list it once as `tag:` or with no namespace.
    static let generalNamespaces: Set<String> = ["female", "male", "mixed", "other", "tag", "f", "m", "x", "o"]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func enabledCount(_ mode: AddonMode) -> Int { enabledModes.values.filter { $0 == mode }.count }

    /// The words shown for a tag in a mode: by its full name (`female:glasses`); a general tag (`female:`, `male:`, …)
    /// also by its `tag:` name; then by its name without the namespace.
    /// Only that mode's add-ons are read: a comics translation never renames an image tag.
    func translation(_ tag: String, mode: AddonMode) -> String? {
        guard let translations = translations[mode], !translations.isEmpty else { return nil }
        let key = AddonCheck.tagKey(tag)
        if let words = translations[key] { return words }
        guard let colon = key.firstIndex(of: ":") else { return translations["tag:" + key] }
        let name = String(key[key.index(after: colon)...])
        guard !name.isEmpty else { return nil }
        if Self.generalNamespaces.contains(String(key[..<colon])), let words = translations["tag:" + name] { return words }
        return translations[name]
    }

    /// Tags whose translation holds what was typed, those starting with it first. Typed text in plain ASCII letters
    /// is left to the website's own suggestions unless it matches the start of a translation.
    func tags(matching text: String, mode: AddonMode, limit: Int = 8) -> [(tag: String, words: String)] {
        let folded = Self.fold(text)
        guard !folded.isEmpty, let list = searchable[mode] else { return [] }
        var starts: [(tag: String, words: String)] = [], contains: [(tag: String, words: String)] = []
        for item in list {
            if item.folded.hasPrefix(folded) { starts.append((item.tag, item.words)) }
            else if !folded.allSatisfy(\.isASCII), item.folded.contains(folded) { contains.append((item.tag, item.words)) }
        }
        starts.sort { $0.words.count < $1.words.count }
        contains.sort { $0.words.count < $1.words.count }
        return Array((starts + contains).prefix(limit))
    }

    /// A search with every translated name in it written as its tag, so that `제독 -안경` searches `character:teitoku -tag:glasses`.
    /// Only names with letters outside ASCII are turned, so that English searches stay as typed. Names of up to four words are found.
    func searchQuery(_ text: String, mode: AddonMode) -> String {
        guard let index = tagsByWords[mode], !index.isEmpty, !text.allSatisfy(\.isASCII) else { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = [], position = 0
        while position < words.count {
            var matched = false
            for length in stride(from: min(4, words.count - position), through: 1, by: -1) {
                var phrase = words[position..<position + length].joined(separator: " ")
                let negative = phrase.hasPrefix("-")
                if negative { phrase.removeFirst() }
                guard !phrase.allSatisfy(\.isASCII), let tag = index[Self.fold(phrase)] else { continue }
                result.append((negative ? "-" : "") + tag)
                position += length; matched = true
                break
            }
            if !matched { result.append(words[position]); position += 1 }
        }
        return result.joined(separator: " ")
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
    @ObservationIgnored private var shownMode = AddonMode.comics

    /// The mode on screen, for tag names drawn where the mode is not passed along (taste and recap texts,
    /// which always belong to the mode shown). Set by `AppEnvironment.mode`.
    var displayedMode: AddonMode {
        get { lock.withLock { shownMode } }
        set { lock.withLock { shownMode = newValue } }
    }

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

    /// The words to show for a tag in a mode, or nil to show the tag itself.
    func translation(_ tag: String, mode: AddonMode) -> String? {
        lock.withLock { state.translations[mode]?.isEmpty ?? true } ? nil : effects.translation(tag, mode: mode)
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

    static func migrateOrigin(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE addons ADD COLUMN official INTEGER NOT NULL DEFAULT 0")
    }

    /// Every add-on kept, checked again on the way out. One that no longer passes is left out, never used.
    func installed() throws -> [InstalledAddon] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT payload, enabled, installed, digest, official FROM addons ORDER BY installed").compactMap { row in
                guard let addon = try? JSONDecoder().decode(Addon.self, from: row["payload"] as Data), (try? addon.validate()) != nil else { return nil }
                return InstalledAddon(addon: addon, enabled: (row["enabled"] as Int) != 0, installed: Date(timeIntervalSince1970: row["installed"]), digest: row["digest"],
                                      official: (row["official"] as Int) != 0)
            }
        }
    }

    /// Adds an add-on, or replaces the one with the same identifier. A replaced add-on stays on or off as it was.
    /// `official` is set only for a copy downloaded from the official add-ons and checked against the signed catalog.
    func install(_ addon: Addon, digest: String, official: Bool = false, now: Date = .now) throws {
        try addon.validate()
        let payload = try JSONEncoder().encode(addon)
        try database.write { db in
            let enabled = try Int.fetchOne(db, sql: "SELECT enabled FROM addons WHERE id = ?", arguments: [addon.id]) ?? 1
            let installed = try Double.fetchOne(db, sql: "SELECT installed FROM addons WHERE id = ?", arguments: [addon.id]) ?? now.timeIntervalSince1970
            try db.execute(sql: """
                INSERT INTO addons (id, payload, enabled, installed, digest, official) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, digest = excluded.digest, official = excluded.official
                """, arguments: [addon.id, payload, enabled, installed, digest, official ? 1 : 0])
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

/// The word being typed at the end of a search, matched against the translations of the mode's add-ons.
struct AddonSearchCompletion: Equatable {
    let prefix: String
    let excluded: Bool
    let term: String

    init?(_ input: String) {
        guard input.last?.isWhitespace == false, let tail = input.split(whereSeparator: \.isWhitespace).last else { return nil }
        prefix = String(input.dropLast(tail.count))
        excluded = tail.hasPrefix("-")
        term = String(excluded ? tail.dropFirst() : tail[...])
        guard !term.isEmpty, term.count <= 64 else { return nil }
    }

    func inserting(_ tag: String) -> String { prefix + (excluded ? "-" : "") + tag + " " }

    /// Tags whose translation starts with or holds the word, from the add-ons of a mode.
    func suggestions(mode: AddonMode, limit: Int = 6) -> [(tag: String, words: String)] {
        AddonRuntime.shared.effects.tags(matching: term, mode: mode, limit: limit)
    }
}
