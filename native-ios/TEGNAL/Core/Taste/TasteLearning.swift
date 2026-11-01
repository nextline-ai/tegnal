import Foundation

enum TasteSignal: String, Sendable { case dismissed, restored }

/// Why a work was chosen, in terms a person can check against their own activity.
enum RecommendationWhy: Hashable, Sendable {
    case taste(String), recent(String), hidden(String), comeback(String), pair(String, String)
    case person(String, RecapPerson.Role, Int), novel(String), similar(String), popular
    var icon: String {
        switch self {
        case .taste: "heart"
        case .recent: "flame"
        case .hidden: "sparkles"
        case .comeback: "arrow.uturn.backward"
        case .pair: "link"
        case .person: "paintpalette"
        case .novel: "safari"
        case .similar: "square.on.square"
        case .popular: "chart.line.uptrend.xyaxis"
        }
    }
    /// A few words that fit under a card.
    var label: String {
        switch self {
        case .taste(let tag), .recent(let tag), .hidden(let tag), .comeback(let tag), .novel(let tag), .similar(let tag): RecapText.tag(tag)
        case .pair(let first, let second): RecapText.tag(first) + " × " + RecapText.tag(second)
        case .person(let name, _, _): RecapText.tag(name).capitalized
        case .popular: L10n.text("Popular now")
        }
    }
    /// The full sentence, drawn only from counted facts.
    var sentence: String {
        switch self {
        case .taste(let tag): L10n.text("You often save works tagged %@.", RecapText.tag(tag))
        case .recent(let tag): L10n.text("You have been saving %@ lately.", RecapText.tag(tag))
        case .hidden(let tag): L10n.text("You keep saving %@ without searching for it.", RecapText.tag(tag))
        case .comeback(let tag): L10n.text("You loved %@ before and haven't visited in a while.", RecapText.tag(tag))
        case .pair(let first, let second): L10n.text("%@ and %@ often appear together in what you save.", RecapText.tag(first), RecapText.tag(second))
        case .person(let name, _, let count): L10n.text("You saved %@ works by %@.", String(count), RecapText.tag(name).capitalized)
        case .novel(let tag): L10n.text("A step outside your usual taste, by way of %@.", RecapText.tag(tag))
        case .similar(let tag): L10n.text("Close to the work you picked, through %@.", RecapText.tag(tag))
        case .popular: L10n.text("Popular on this site while we learn your taste.")
        }
    }
}

extension TasteRecommendation {
    var reachesOut: Bool {
        if novel || reason.discovery { return true }
        if case .comeback = why { return true }
        return false
    }
    /// Three works that can fail independently: something current, something
    /// from long-standing taste and something new, never on one shared reason.
    static func picks(from items: [TasteRecommendation], count: Int = 3) -> [TasteRecommendation] {
        var chosen: [TasteRecommendation] = [], reasons = Set<String>()
        func take(_ matches: (TasteRecommendation) -> Bool) {
            guard chosen.count < count, let item = items.first(where: { candidate in matches(candidate) && !reasons.contains(candidate.reason.name) && !chosen.contains { $0.id == candidate.id } }) else { return }
            chosen.append(item); reasons.insert(item.reason.name)
        }
        take { item in
            switch item.why { case .recent, .person: true; default: false }
        }
        take { !$0.reachesOut }
        take(\.reachesOut)
        while chosen.count < count {
            let before = chosen.count
            take { _ in true }
            if chosen.count == before { reasons.removeAll(); take { _ in true } }
            if chosen.count == before { break }
        }
        return chosen
    }
}

/// One line of the explanation sheet. `strength` is relative within a work.
struct RecommendationFactor: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case tag, person, boosted, reduced, fresh }
    var kind: Kind
    var name: String
    var key: String
    var strength: Double
    var id: String { kind.rawValue + key }
}

struct TasteLearnedTag: Identifiable, Hashable, Sendable {
    var source: String
    var name: String
    /// Recency-weighted evidence. Saves count most, then finished and long views.
    var weight: Double
    var saves = 0
    var recent = 0
    var id: String { TasteControl.tagKey(source: source, tag: name) }
}

struct TasteLearnedPerson: Identifiable, Hashable, Sendable {
    var source: String
    var name: String
    var role: RecapPerson.Role
    var weight: Double
    var saves = 0
    var id: String { role.rawValue + TasteControl.tagKey(source: source, tag: name) }
    var query: String {
        let spoken = name.replacingOccurrences(of: " ", with: "_")
        return source == MangaUrls.source ? role.rawValue + ":" + spoken : spoken
    }
    var key: String { TasteControl.tagKey(source: source, tag: query) }
}

/// A named row of the Smart tab. Every shelf states why it exists.
struct TasteShelfPlan: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case recent, person, pair, hidden, comeback }
    var kind: Kind
    var source: String
    var seed: TasteTag
    var why: RecommendationWhy
    var id: String { kind.rawValue + seed.id }
    var title: String {
        switch why {
        case .recent(let tag): RecapText.tag(tag)
        case .person(let name, _, _): RecapText.tag(name).capitalized
        case .pair(let first, let second): RecapText.tag(first) + " × " + RecapText.tag(second)
        case .hidden(let tag): RecapText.tag(tag)
        case .comeback(let tag): L10n.text("Back to %@", RecapText.tag(tag))
        default: why.label
        }
    }
}

/// What the app has learned, rebuilt from history on every refresh. Nothing here
/// is sent anywhere, and every number traces back to events the person can delete.
struct TasteLearning: Sendable {
    /// Taste moves. A save loses half its pull every six weeks.
    static let halfLife = 45.0
    private(set) var tags: [String: TasteLearnedTag] = [:]
    private(set) var people: [TasteLearnedPerson] = []
    private(set) var pairs: [(first: TasteLearnedTag, second: TasteLearnedTag, count: Int)] = []
    private(set) var seen = Set<String>()
    private(set) var dismissed = Set<String>()
    private var penalties: [String: Double] = [:]
    private var personOf: [String: [TasteLearnedPerson]] = [:]
    private let boosts: [String: Int]
    let level: Int
    private var peak = 1.0
    private var libraryCount = 0

    var discoverySlots: Int { [1, 3, 5][level] }

    init(index: RecapIndex, control: TasteControl, now: Date = Date()) {
        boosts = control.tasteBoosts ?? [:]
        level = min(2, max(0, control.discoveryLevel ?? 1))
        let clock = now.timeIntervalSince1970
        func decay(_ at: Double) -> Double { pow(0.5, max(0, clock - at) / 86400 / Self.halfLife) }
        var learned: [String: TasteLearnedTag] = [:], persons: [String: TasteLearnedPerson] = [:]
        var active: [String: RecapIndex.Entry] = [:]
        var together: [String: Int] = [:]
        var restored = Set<String>()
        var savedCredit: [String: (amount: Double, recent: Bool)] = [:]
        func credit(_ entry: RecapIndex.Entry, _ amount: Double, saved: Bool) {
            for name in entry.tags {
                let key = TasteControl.tagKey(source: entry.item.source, tag: name)
                var tag = learned[key] ?? .init(source: entry.item.source, name: name, weight: 0)
                tag.weight += amount
                if saved { tag.saves += 1; if clock - entry.at < 30 * 86400 { tag.recent += 1 } }
                learned[key] = tag
            }
            guard let info = index.library[entry.key] else { return }
            func credited(_ name: String, _ role: RecapPerson.Role) {
                guard !["anonymous", "unknown", "original"].contains(TasteTagPolicy.normalize(name)) else { return }
                let id = role.rawValue + TasteControl.tagKey(source: entry.item.source, tag: name)
                var person = persons[id] ?? .init(source: entry.item.source, name: name, role: role, weight: 0)
                person.weight += amount
                if saved { person.saves += 1 }
                persons[id] = person
            }
            info.artists.forEach { credited($0, .artist) }
            info.series.forEach { credited($0, .series) }
            info.characters.forEach { credited($0, .character) }
        }
        for entry in index.entries {
            let fade = decay(entry.at)
            switch entry.kind {
            case .save:
                let amount = (entry.context.preferenceAction ? 1 : 0.7) * fade
                credit(entry, amount, saved: true)
                savedCredit[entry.key] = (amount, clock - entry.at < 30 * 86400)
                active[entry.key] = entry
                if clock - entry.at < 120 * 86400 {
                    let names = entry.tags.prefix(16)
                    for (offset, first) in names.enumerated() {
                        for second in names.dropFirst(offset + 1) { together[entry.item.source + "\n" + first + "\n" + second, default: 0] += 1 }
                    }
                }
            case .seed, .imported:
                // A library arriving all at once says little about today.
                let amount = 0.2 * max(fade, 0.25)
                credit(entry, amount, saved: true); active[entry.key] = entry
                savedCredit[entry.key] = (amount, clock - entry.at < 30 * 86400)
            case .remove:
                // Unsaving takes back exactly what the save gave.
                if let earlier = savedCredit.removeValue(forKey: entry.key) {
                    credit(entry, -earlier.amount, saved: false)
                    for name in entry.tags {
                        let key = TasteControl.tagKey(source: entry.item.source, tag: name)
                        learned[key]?.saves -= 1
                        if earlier.recent { learned[key]?.recent -= 1 }
                    }
                }
                active[entry.key] = nil
            case .open:
                if entry.signal == TasteSignal.dismissed.rawValue {
                    dismissed.insert(entry.key); restored.remove(entry.key)
                    for name in entry.tags { penalties[TasteControl.tagKey(source: entry.item.source, tag: name), default: 0] += 0.35 * fade }
                } else if entry.signal == TasteSignal.restored.rawValue {
                    restored.insert(entry.key); dismissed.remove(entry.key)
                    for name in entry.tags { penalties[TasteControl.tagKey(source: entry.item.source, tag: name), default: 0] -= 0.35 * fade }
                } else {
                    seen.insert(entry.key)
                    if let dwell = entry.dwell, dwell.seconds >= 20 {
                        credit(entry, (min(1, dwell.seconds / 240) * 0.6 + (dwell.finished ? 0.3 : 0)) * fade, saved: false)
                    }
                }
            default: break
            }
        }
        tags = learned
        peak = max(1, learned.values.map(\.weight).max() ?? 1)
        people = persons.values.filter { $0.saves >= 2 }.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
        for person in people {
            personOf[TasteControl.tagKey(source: person.source, tag: TasteTagPolicy.normalize(person.name)), default: []].append(person)
            personOf[TasteControl.tagKey(source: person.source, tag: TasteTagPolicy.normalize(person.query)), default: []].append(person)
        }
        libraryCount = active.count
        let total = max(1, Double(active.count))
        pairs = together.compactMap { key, count -> (TasteLearnedTag, TasteLearnedTag, Int)? in
            let parts = key.components(separatedBy: "\n")
            guard count >= 3, parts.count == 3,
                  let first = learned[TasteControl.tagKey(source: parts[0], tag: parts[1])], let second = learned[TasteControl.tagKey(source: parts[0], tag: parts[2])] else { return nil }
            // A tag on everything pairs with everything; lift keeps the meaningful ones.
            let lift = Double(count) * total / Double(max(1, first.saves) * max(1, second.saves))
            return lift >= 1.2 && max(first.saves, second.saves) * 5 < active.count * 4 + 5 ? (first, second, count) : nil
        }.sorted { $0.2 == $1.2 ? $0.0.id + $0.1.id < $1.0.id + $1.1.id : $0.2 > $1.2 }.map { (first: $0.0, second: $0.1, count: $0.2) }
    }

    func boost(_ key: String) -> Int { boosts[key] ?? 0 }
    func isMuted(_ tag: TasteTag) -> Bool { boost(tag.id) < 0 }
    func seedWeight(_ tag: TasteTag) -> Double { (tags[tag.id]?.weight ?? 0) + Double(boost(tag.id)) * 2 * peak }

    /// Tags known but rarely saved: the near edge of a person's taste.
    func fringe(_ source: String) -> [TasteTag] {
        tags.values.filter { $0.source == source && $0.saves >= 1 && $0.saves <= 3 && boost($0.id) >= 0 }
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }.prefix(6)
            .map { TasteTag(source: $0.source, name: $0.name, general: $0.saves) }
    }

    /// Credits have their own shelf, and a tag on nearly everything says nothing.
    private func isDistinct(_ tag: TasteLearnedTag) -> Bool { personOf[tag.id] == nil && tag.saves * 5 < libraryCount * 4 + 5 }
    var recentTags: [TasteLearnedTag] {
        tags.values.filter { $0.recent >= 2 && boost($0.id) >= 0 && isDistinct($0) }.sorted { first, second in
            let a = Double(first.recent) / Double(max(3, first.saves)), b = Double(second.recent) / Double(max(3, second.saves))
            return a == b ? first.id < second.id : a > b
        }
    }
    var dormantTags: [TasteLearnedTag] {
        tags.values.filter { $0.saves >= 5 && $0.recent == 0 && boost($0.id) >= 0 && isDistinct($0) }
            .sorted { $0.saves == $1.saves ? $0.id < $1.id : $0.saves > $1.saves }
    }
    /// Strongest first, for the tuner and the focus row.
    func ranked(_ source: String? = nil) -> [TasteLearnedTag] {
        tags.values.filter { source == nil || $0.source == source }.filter { $0.weight > 0 && personOf[$0.id] == nil }
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
    }

    /// Shelves rotate daily so the page has something new without a refresh.
    func shelves(sources: [String], tags snapshot: [TasteTag], offset: Int, limit: Int = 4) -> [TasteShelfPlan] {
        var pool: [[TasteShelfPlan]] = []
        func tag(_ learned: TasteLearnedTag) -> TasteTag { .init(source: learned.source, name: learned.name, general: learned.saves) }
        let allowed = Set(sources)
        pool.append(recentTags.filter { allowed.contains($0.source) }.prefix(4).map { .init(kind: .recent, source: $0.source, seed: tag($0), why: .recent($0.name)) })
        pool.append(people.filter { allowed.contains($0.source) && boost($0.key) >= 0 }.prefix(5).map {
            .init(kind: .person, source: $0.source, seed: .init(source: $0.source, name: $0.query, general: $0.saves), why: .person($0.name, $0.role, $0.saves))
        })
        pool.append(pairs.filter { allowed.contains($0.first.source) }.prefix(4).map {
            .init(kind: .pair, source: $0.first.source, seed: .init(source: $0.first.source, name: $0.first.name + " " + $0.second.name, general: $0.count), why: .pair($0.first.name, $0.second.name))
        })
        pool.append(snapshot.filter { $0.discovery && allowed.contains($0.source) }.prefix(3).map { .init(kind: .hidden, source: $0.source, seed: $0, why: .hidden($0.name)) })
        pool.append(dormantTags.filter { allowed.contains($0.source) }.prefix(4).map { .init(kind: .comeback, source: $0.source, seed: tag($0), why: .comeback($0.name)) })
        var seenSeeds = Set<String>(), result: [TasteShelfPlan] = []
        for family in pool.indices.map({ pool[($0 + max(0, offset)) % pool.count] }) where !family.isEmpty {
            let plan = family[max(0, offset) % family.count]
            if seenSeeds.insert(plan.seed.id).inserted { result.append(plan) }
            if result.count == limit { break }
        }
        return result
    }

    /// Reranks one candidate and records the facts behind its score. The profile
    /// score stays the base, so personal learning sharpens it without replacing it.
    func personalize(_ candidate: TasteRecommendation, why override: RecommendationWhy? = nil) -> TasteRecommendation {
        var result = candidate
        let source = candidate.item.source, names = candidate.rankingTags ?? Set(candidate.item.eligibleTags)
        var factors: [RecommendationFactor] = []
        var affinity = 0.0, penalty = 0.0, known = 0, explicit = 0.0, credited: TasteLearnedPerson?
        for name in names {
            let key = TasteControl.tagKey(source: source, tag: name)
            let learned = tags[key]
            if let learned, learned.weight > 0 {
                known += 1; affinity += min(learned.weight, peak)
                if personOf[key] == nil { factors.append(.init(kind: .tag, name: name, key: key, strength: learned.weight / peak)) }
            }
            if let person = personOf[key]?.first {
                if credited == nil || person.weight > credited!.weight { credited = person }
            }
            let steered = boosts[key] ?? 0
            if steered != 0 {
                explicit += steered > 0 ? 0.3 : -0.6
                factors.append(.init(kind: steered > 0 ? .boosted : .reduced, name: name, key: key, strength: 1))
            }
            penalty += penalties[key, default: 0]
        }
        let spread = sqrt(Double(max(1, names.count)))
        let novelty = names.isEmpty ? 0 : 1 - Double(known) / Double(names.count)
        result.novel = !names.isEmpty && novelty >= 0.6
        let reach = (Double(level) - 1) * 0.3 * novelty
        result.score = candidate.score + 0.6 * affinity / peak / spread + (credited == nil ? 0 : 0.2) + explicit - 0.5 * penalty / spread + reach
        if let credited { factors.append(.init(kind: .person, name: credited.name, key: credited.key, strength: min(1, credited.weight / peak))) }
        result.factors = Array(factors.sorted { $0.strength == $1.strength ? $0.id < $1.id : $0.strength > $1.strength }.prefix(6))
        result.why = override ?? explanation(for: candidate, credited: credited, novel: result.novel)
        return result
    }

    private func explanation(for candidate: TasteRecommendation, credited: TasteLearnedPerson?, novel: Bool) -> RecommendationWhy {
        let seed = candidate.reason
        if seed.name.isEmpty { return .popular }
        if let credited, credited.saves >= 3 { return .person(credited.name, credited.role, credited.saves) }
        if seed.discovery { return .hidden(seed.name) }
        if novel { return .novel(seed.name) }
        if let learned = tags[seed.id], learned.recent >= 2, learned.recent * 3 >= learned.saves { return .recent(seed.name) }
        return .taste(seed.name)
    }
}
