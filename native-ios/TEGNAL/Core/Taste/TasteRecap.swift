import Foundation

/// Library facts that analysis events do not carry. Only works the library still
/// shows are present, so a recap can never resurface something hidden or blacklisted.
struct RecapWorkInfo: Sendable, Hashable {
    var title: String? = nil
    var artists: [String] = []
    var series: [String] = []
    var characters: [String] = []
    var savedAt: Date? = nil
    var thumbPath: String? = nil
}

struct RecapWork: Identifiable, Sendable, Hashable {
    var item: TasteItem
    var info: RecapWorkInfo
    var opens = 0
    var seconds: Double = 0
    var score: Double = 0
    var id: String { item.key }
}

struct RecapTag: Identifiable, Sendable, Hashable {
    var name: String
    var source: String
    var count: Int
    var previousCount = 0
    var rank = 0
    var previousRank: Int? = nil
    var isNew = false
    var confirmed = 0
    var hidden = 0
    var sessions: Set<String> = []
    var works: [String] = []
    var id: String { name }
    /// Positive when the tag climbed. Nil when it has no previous rank to compare.
    var movement: Int? { previousRank.map { $0 - rank } }
}

struct RecapPerson: Identifiable, Sendable, Hashable {
    enum Role: String, Sendable { case artist, series, character }
    var name: String
    var role: Role
    var count: Int
    var previousCount = 0
    var works: [String] = []
    var id: String { role.rawValue + ":" + name }
}

struct RecapHighlight: Sendable, Hashable {
    enum Kind: String, Sendable { case hidden, comeback, newcomer, rising }
    var kind: Kind
    var tag: RecapTag
}

/// A localized sentence kept as data so tests assert facts, not one language.
struct RecapLine: Sendable, Hashable {
    var key: String
    var arguments: [String] = []
    init(_ key: String, _ arguments: String...) { self.key = key; self.arguments = arguments }
    var text: String { L10n.text(key, arguments: arguments) }
}

struct RecapPersona: Sendable, Hashable {
    enum Rhythm: String, Sendable, CaseIterable { case midnight, dawn, weekend, steady, daylight }
    enum Style: String, Sendable, CaseIterable { case curator, hunter, devotee, explorer, wanderer, collector }
    var rhythm: Rhythm
    var style: Style
    var traits: [RecapLine]
    var title: String { L10n.text("%@ %@", arguments: [L10n.text("persona.rhythm." + rhythm.rawValue), L10n.text("persona.style." + style.rawValue)]) }
    var summary: String { L10n.text("persona.summary." + style.rawValue) }
}

struct RecapDay: Identifiable, Sendable, Hashable {
    var date: Date
    var touched = 0
    var saved = 0
    var id: Date { date }
}

struct RecapOrigins: Sendable, Hashable {
    var search = 0, feed = 0, recommendation = 0, other = 0
    var total: Int { search + feed + recommendation + other }
}

struct TasteRecap: Identifiable, Sendable {
    var mode: TasteMode
    var period: TastePeriod
    var offset: Int
    var interval: DateInterval
    var isComplete: Bool
    var isSample = false
    var issue = 1

    var saves = 0
    var previousSaves = 0
    var opens = 0
    var previousOpens = 0
    var searches = 0
    var seconds: Double = 0
    var pages = 0
    var finished = 0
    var activeDays = 0
    var longestStreak = 0

    var tags: [RecapTag] = []
    var people: [RecapPerson] = []
    var highlights: [RecapHighlight] = []
    var opening: RecapTag? = nil
    var closing: RecapTag? = nil
    /// What set this period apart. A tag on nearly every work can lead the chart for
    /// months without saying anything, so this weighs presence against rarity.
    var signature: RecapTag? = nil
    var days: [RecapDay] = []
    var hours = [Int](repeating: 0, count: 24)
    var origins = RecapOrigins()
    var saved: [RecapWork] = []
    var revisited: RecapWork? = nil
    var rediscover: [RecapWork] = []
    var next: [RecapTag] = []
    var months: [TasteRecapMonth] = []
    var persona: RecapPersona? = nil

    var id: String { "\(mode.rawValue):\(period.rawValue):\(Int(interval.start.timeIntervalSince1970))" }
    var hasActivity: Bool { saves > 0 || opens > 0 }
    var cover: RecapWork? { saved.first }
    var busiestDay: RecapDay? { days.filter { $0.touched > 0 }.max { $0.touched == $1.touched ? $0.date > $1.date : $0.touched < $1.touched } }
    var peakHour: Int? { hours.max().flatMap { $0 > 0 ? hours.firstIndex(of: $0) : nil } }
    func person(_ role: RecapPerson.Role) -> RecapPerson? { people.first { $0.role == role } }
    func work(_ key: String) -> RecapWork? { saved.first { $0.id == key } }

    /// The story's opening sentence, drawn only from counted facts.
    var editorNote: RecapLine? {
        if let opening, let closing, opening.name != closing.name, saves >= 6 {
            return RecapLine("You began with %@ and ended on %@.", RecapText.tag(opening.name), RecapText.tag(closing.name))
        }
        guard let top = signature ?? tags.first else { return nil }
        if let highlight = highlights.first, highlight.tag.name != top.name {
            return RecapLine("%@ held the center, while %@ quietly arrived.", RecapText.tag(top.name), RecapText.tag(highlight.tag.name))
        }
        return RecapLine("%@ ran through this issue from start to finish.", RecapText.tag(top.name))
    }
}

struct TasteRecapMonth: Identifiable, Sendable, Hashable {
    var start: Date
    var saves: Int
    var topTag: String?
    var id: Date { start }
}

enum RecapText {
    /// Namespaces and underscores are search syntax, not something to read.
    static func tag(_ name: String) -> String {
        let bare = name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
        return TastePresentation.name(bare)
    }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return minutes % 60 == 0 ? L10n.text("%@ hr", String(minutes / 60)) : L10n.text("%@ hr %@ min", String(minutes / 60), String(minutes % 60)) }
        return L10n.text("%@ min", String(max(1, minutes)))
    }
}

/// Decoded history with every tag decision already made, so that many issues can be
/// built from one pass. Pure and deterministic: tests feed it events and a library.
struct RecapIndex: Sendable {
    struct Entry: Sendable {
        var at: Double
        var kind: TasteEvent.Kind
        var key: String
        var item: TasteItem
        var tags: [String]
        var context: DiscoveryContext
        var dwell: TasteDwell?
        var signal: String?
    }
    let mode: TasteMode
    let timeZone: TimeZone
    let library: [String: RecapWorkInfo]
    private(set) var entries: [Entry] = []
    private(set) var tagHistory: [String: [Double]] = [:]
    private(set) var searched: [String: Double] = [:]
    private(set) var latest: [String: (item: TasteItem, tags: [String])] = [:]
    private(set) var lastOpened: [String: Double] = [:]

    init(events input: [TasteEvent], control: TasteControl, mode: TasteMode, library: [String: RecapWorkInfo]) {
        self.mode = mode; self.library = library
        timeZone = TimeZone(identifier: control.timeZone) ?? .gmt
        let events = Dictionary(input.filter { $0.epoch == control.epoch }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in TasteEvent.ordered(a, b) ? b : a }).values.sorted(by: TasteEvent.ordered)
        var metadata: [String: Set<String>] = [:]
        for event in events { metadata[event.item.source, default: []].formUnion(event.item.metadata.map(TasteTagPolicy.normalize)) }
        func eligible(_ item: TasteItem) -> [String] {
            let blocked = metadata[item.source, default: []]
            return Set(item.tags.map(TasteTagPolicy.normalize)).filter {
                TasteTagPolicy.eligible($0, metadata: blocked) && control.allows($0, source: item.source, mode: mode)
            }.sorted()
        }
        var resolved: [String: (item: TasteItem, tags: [String])] = [:]
        for event in events where [.save, .seed, .imported, .metadata].contains(event.kind) && event.item.id != 0 {
            resolved[event.item.key] = (event.item, eligible(event.item))
        }
        entries.reserveCapacity(events.count)
        for event in events {
            let known = resolved[event.item.key]
            let tags = event.kind == .search ? eligible(event.item) : known?.tags ?? eligible(event.item)
            let item = known?.item ?? event.item
            if event.kind == .search, event.context.origin == .search {
                for tag in tags { searched[TasteControl.tagKey(source: item.source, tag: tag)] = min(searched[TasteControl.tagKey(source: item.source, tag: tag)] ?? .infinity, event.at) }
            }
            if event.kind == .save || event.kind == .seed || event.kind == .imported {
                for tag in tags { tagHistory[tag, default: []].append(event.at) }
                latest[item.key] = (item, tags)
            } else if event.kind == .remove { latest.removeValue(forKey: item.key) }
            if event.kind == .open, event.signal == nil { lastOpened[item.key] = max(lastOpened[item.key] ?? 0, event.at) }
            entries.append(.init(at: event.at, kind: event.kind, key: item.key, item: item, tags: tags, context: event.context, dwell: event.dwell, signal: event.signal))
        }
    }

    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4; return value }
    private func firstEntry(atOrAfter time: Double) -> Int {
        var low = 0, high = entries.count
        while low < high { let middle = (low + high) / 2; if entries[middle].at < time { low = middle + 1 } else { high = middle } }
        return low
    }
    private func savedCount(_ tag: String, before time: Double) -> Int {
        guard let times = tagHistory[tag] else { return 0 }
        var low = 0, high = times.count
        while low < high { let middle = (low + high) / 2; if times[middle] < time { low = middle + 1 } else { high = middle } }
        return low
    }

    func recap(period: TastePeriod, offset: Int, now: Date = Date(), rediscovers: Bool = true) -> TasteRecap? {
        guard let interval = period.interval(offset: offset, now: now, timeZone: timeZone.identifier),
              let previous = period.interval(offset: offset - 1, now: now, timeZone: timeZone.identifier) else { return nil }
        var result = TasteRecap(mode: mode, period: period, offset: offset, interval: interval, isComplete: now >= interval.end)
        let calendar = calendar
        let start = interval.start.timeIntervalSince1970, end = interval.end.timeIntervalSince1970
        let previousStart = previous.start.timeIntervalSince1970, middle = (start + end) / 2

        var chosen: [String: Entry] = [:], earlier: [String: Entry] = [:]
        var opened = Set<String>(), openedEarlier = Set<String>()
        var sessionsByWork: [String: Set<String>] = [:], viewingsByWork: [String: Int] = [:], secondsByWork: [String: Double] = [:]
        var searchSessions = Set<String>()
        var days: [Date: RecapDay] = [:]
        var touched: [Date: Set<String>] = [:]
        for index in firstEntry(atOrAfter: previousStart)..<entries.count {
            let entry = entries[index]
            guard entry.at < end else { break }
            // Feedback on a recommendation is not activity with the work.
            if entry.signal != nil { continue }
            guard entry.at >= start else {
                if entry.kind == .save, earlier[entry.key] == nil { earlier[entry.key] = entry }
                if entry.kind == .open, entry.signal == nil { openedEarlier.insert(entry.key) }
                continue
            }
            let moment = Date(timeIntervalSince1970: entry.at), day = calendar.startOfDay(for: moment)
            switch entry.kind {
            case .save:
                if chosen[entry.key] == nil {
                    chosen[entry.key] = entry
                    days[day, default: .init(date: day)].saved += 1
                    touched[day, default: []].insert(entry.key)
                    result.hours[calendar.component(.hour, from: moment)] += 1
                }
            case .open:
                opened.insert(entry.key)
                if let dwell = entry.dwell {
                    result.seconds += dwell.seconds; result.pages += dwell.pages
                    if dwell.finished { result.finished += 1 }
                    secondsByWork[entry.key, default: 0] += dwell.seconds
                    viewingsByWork[entry.key, default: 0] += 1
                } else {
                    sessionsByWork[entry.key, default: []].insert(entry.context.session)
                    touched[day, default: []].insert(entry.key)
                    result.hours[calendar.component(.hour, from: moment)] += 1
                }
            case .search:
                if entry.context.origin == .search { searchSessions.insert(entry.context.session) }
            default: break
            }
        }
        result.saves = chosen.count; result.previousSaves = earlier.count
        result.opens = opened.count; result.previousOpens = openedEarlier.count
        result.searches = searchSessions.count
        for (day, keys) in touched { days[day, default: .init(date: day)].touched = keys.count }
        result.days = Self.fill(days, interval: interval, calendar: calendar)
        result.activeDays = days.count
        result.longestStreak = Self.longestRun(result.days)

        func people(_ info: RecapWorkInfo) -> [(String, RecapPerson.Role)] {
            info.artists.map { ($0, .artist) } + info.series.map { ($0, .series) } + info.characters.map { ($0, .character) }
        }
        func spoken(_ name: String) -> String { TasteTagPolicy.normalize(name) }
        var tags: [String: RecapTag] = [:], sources: [String: [String: Int]] = [:], personal: [String: RecapPerson] = [:]
        var firstHalf: [String: Int] = [:], secondHalf: [String: Int] = [:]
        for entry in chosen.values {
            let info = library[entry.key] ?? .init()
            let credited = Set(people(info).map { spoken($0.0) })
            for (name, role) in people(info) where !Self.anonymous.contains(spoken(name)) {
                let id = role.rawValue + ":" + name
                var person = personal[id] ?? .init(name: name, role: role, count: 0)
                person.count += 1; person.works.append(entry.key); personal[id] = person
            }
            switch entry.context.origin {
            case .search: result.origins.search += 1
            case .feed: result.origins.feed += 1
            case .recommendation: result.origins.recommendation += 1
            default: result.origins.other += 1
            }
            for name in entry.tags where !credited.contains(name) && (!entry.context.constraints.contains(name) || entry.context.included.contains(name)) {
                var tag = tags[name] ?? .init(name: name, source: entry.item.source, count: 0)
                tag.count += 1; tag.works.append(entry.key)
                if entry.context.preferenceAction {
                    if entry.context.chosenTags.contains(name) { tag.confirmed += 1 }
                    else { tag.hidden += 1; tag.sessions.insert(entry.context.session) }
                }
                tags[name] = tag
                sources[name, default: [:]][entry.item.source, default: 0] += 1
                if entry.at < middle { firstHalf[name, default: 0] += 1 } else { secondHalf[name, default: 0] += 1 }
            }
        }
        var previousCounts: [String: Int] = [:]
        for entry in earlier.values {
            for name in entry.tags { previousCounts[name, default: 0] += 1 }
            for (name, role) in people(library[entry.key] ?? .init()) { personal[role.rawValue + ":" + name]?.previousCount += 1 }
        }
        let previousRanks = Dictionary(uniqueKeysWithValues: previousCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.enumerated().map { ($0.element.key, $0.offset + 1) })
        var ranked = tags.values.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        for index in ranked.indices {
            let name = ranked[index].name
            ranked[index].rank = index + 1
            ranked[index].previousRank = previousRanks[name]
            ranked[index].previousCount = previousCounts[name, default: 0]
            ranked[index].isNew = savedCount(name, before: start) == 0
            ranked[index].source = sources[name, default: [:]].sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first?.key ?? ranked[index].source
        }
        result.tags = ranked
        result.people = personal.values.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        func best(_ counts: [String: Int]) -> RecapTag? {
            counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.flatMap { top in ranked.first { $0.name == top.key } }
        }
        result.opening = best(firstHalf); result.closing = best(secondHalf)
        let everything = max(1, latest.count)
        result.signature = ranked.filter { $0.count >= 2 || ranked.count < 4 }.max { signatureScore($0, total: everything) < signatureScore($1, total: everything) }
        result.highlights = Self.highlights(ranked, period: period) { tag in
            let source = TasteControl.tagKey(source: tag.source, tag: tag.name)
            return (self.searched[source].map { $0 < end } ?? false, self.savedCount(tag.name, before: previousStart))
        }

        let counts = Dictionary(uniqueKeysWithValues: ranked.map { ($0.name, $0.count) })
        func score(_ tags: [String]) -> Double {
            Double(tags.reduce(0) { $0 + counts[$1, default: 0] }) / max(1, Double(tags.count).squareRoot())
        }
        func work(_ key: String, tags: [String], item: TasteItem) -> RecapWork? {
            // A viewing and the open that began it are one visit, not two.
            library[key].map { .init(item: item, info: $0, opens: max(viewingsByWork[key, default: 0], sessionsByWork[key]?.count ?? 0), seconds: secondsByWork[key, default: 0], score: score(tags)) }
        }
        result.saved = chosen.compactMap { work($0.key, tags: $0.value.tags, item: $0.value.item) }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let viewed = (Set(secondsByWork.keys).union(sessionsByWork.keys)).compactMap { key in latest[key].flatMap { work(key, tags: $0.tags, item: $0.item) } }
        result.revisited = viewed.filter { $0.opens >= 2 }
            .max { ($0.seconds, $0.opens, $1.id) < ($1.seconds, $1.opens, $0.id) }

        let top = Set(ranked.prefix(10).map(\.name))
        if rediscovers, period != .week, !top.isEmpty {
            let settled = start - 30 * 86400, quiet = end - 60 * 86400
            result.rediscover = Array(latest.compactMap { key, value -> RecapWork? in
                guard chosen[key] == nil, lastOpened[key, default: 0] < quiet, !value.tags.isEmpty,
                      let info = library[key], (info.savedAt?.timeIntervalSince1970 ?? 0) < settled else { return nil }
                let overlap = value.tags.filter(top.contains)
                guard !overlap.isEmpty else { return nil }
                return RecapWork(item: value.item, info: info, score: score(overlap))
            }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(6))
        }
        var nextNames = Set<String>()
        result.next = Array((result.highlights.map(\.tag) + ranked.dropFirst(3).filter { $0.isNew || $0.count > $0.previousCount } + ranked.dropFirst(3))
            .filter { nextNames.insert($0.name).inserted }.prefix(3))
        result.persona = Self.persona(result, now: now, calendar: calendar)
        return result
    }

    private func signatureScore(_ tag: RecapTag, total: Int) -> Double {
        Double(tag.count) * log(1 + Double(total) / Double(max(1, tagHistory[tag.name]?.count ?? 1)))
    }

    private static let anonymous: Set<String> = ["anonymous", "unknown", "unknown_artist", "artist_request", "original"]

    private static func fill(_ days: [Date: RecapDay], interval: DateInterval, calendar: Calendar) -> [RecapDay] {
        var result: [RecapDay] = [], day = interval.start
        while day < interval.end {
            result.append(days[day] ?? .init(date: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
    private static func longestRun(_ days: [RecapDay]) -> Int {
        var best = 0, run = 0
        for day in days { run = day.touched > 0 ? run + 1 : 0; best = max(best, run) }
        return best
    }

    /// Ordered by how surprising each pattern is. The chart's leader is already
    /// on its own page, so it only qualifies when nothing else does.
    private static func highlights(_ tags: [RecapTag], period: TastePeriod, history: (RecapTag) -> (searched: Bool, older: Int)) -> [RecapHighlight] {
        let required = period == .week ? 2 : 3
        var found: [RecapHighlight] = []
        for tag in tags {
            let (searched, older) = history(tag)
            if tag.confirmed == 0, !searched, tag.hidden >= 5, tag.sessions.count >= 3 { found.append(.init(kind: .hidden, tag: tag)) }
            else if tag.previousCount == 0, !tag.isNew, older >= 3, tag.count >= 2 { found.append(.init(kind: .comeback, tag: tag)) }
            else if tag.isNew, tag.count >= required { found.append(.init(kind: .newcomer, tag: tag)) }
            else if tag.previousCount > 0, tag.count >= required, tag.count >= tag.previousCount * 2 { found.append(.init(kind: .rising, tag: tag)) }
        }
        let order: [RecapHighlight.Kind] = [.hidden, .comeback, .newcomer, .rising]
        let sorted = found.sorted { (order.firstIndex(of: $0.kind)!, $0.tag.rank) < (order.firstIndex(of: $1.kind)!, $1.tag.rank) }
        return Array((sorted.filter { $0.tag.rank > 1 } + sorted.filter { $0.tag.rank == 1 }).prefix(3))
    }

    private static func persona(_ recap: TasteRecap, now: Date, calendar: Calendar) -> RecapPersona? {
        guard recap.saves + recap.opens >= 5 else { return nil }
        func percent(_ part: Int, _ whole: Int) -> Int { whole == 0 ? 0 : Int((Double(part) / Double(whole) * 100).rounded()) }
        let activity = recap.hours.reduce(0, +)
        let night = recap.hours[22...23].reduce(0, +) + recap.hours[0...4].reduce(0, +)
        let dawn = recap.hours[5...9].reduce(0, +)
        let weekend = recap.days.filter { [1, 7].contains(calendar.component(.weekday, from: $0.date)) }.reduce(0) { $0 + $1.touched }
        let total = recap.days.reduce(0) { $0 + $1.touched }
        let elapsed = max(1, recap.days.filter { $0.date <= now }.count)
        var traits: [(Int, RecapLine)] = []
        let rhythm: RecapPersona.Rhythm
        if percent(night, activity) >= 40 {
            rhythm = .midnight; traits.append((percent(night, activity), RecapLine("%@%% of your activity came after 10 PM", String(percent(night, activity)))))
        } else if percent(dawn, activity) >= 30 {
            rhythm = .dawn; traits.append((percent(dawn, activity), RecapLine("%@%% of your activity came before 10 AM", String(percent(dawn, activity)))))
        } else if recap.period != .week, percent(weekend, total) >= 55 {
            rhythm = .weekend; traits.append((percent(weekend, total), RecapLine("%@%% of your activity fell on weekends", String(percent(weekend, total)))))
        } else if percent(recap.activeDays, elapsed) >= 50 {
            rhythm = .steady; traits.append((percent(recap.activeDays, elapsed), RecapLine("Active on %@ of %@ days", String(recap.activeDays), String(elapsed))))
        } else {
            rhythm = .daylight; traits.append((0, RecapLine("Most active around %@", RecapPersonaClock.hour(recap.peakHour ?? 12))))
        }
        let saveRate = percent(recap.saves, max(recap.opens, recap.saves))
        let searchShare = percent(recap.origins.search, recap.origins.total), feedShare = percent(recap.origins.feed, recap.origins.total)
        // A tag nearly every work carries says nothing about focus.
        let leaders = Set(recap.tags.filter { $0.count * 5 < recap.saves * 4 }.prefix(3).flatMap(\.works))
        let focus = percent(leaders.count, recap.saves)
        let newcomers = recap.tags.filter(\.isNew).count
        let breadth = percent(newcomers, recap.tags.count)
        let style: RecapPersona.Style
        if recap.opens >= 15, saveRate <= 15 {
            style = .curator; traits.append((100 - saveRate, RecapLine("You kept %@ of %@ works you opened", String(recap.saves), String(recap.opens))))
        } else if recap.saves >= 3, searchShare >= 55 {
            style = .hunter; traits.append((searchShare, RecapLine("%@%% of saves came from your searches", String(searchShare))))
        } else if recap.saves >= 5, focus >= 70 {
            style = .devotee; traits.append((focus, RecapLine("Your top 3 tags cover %@%% of your saves", String(focus))))
        } else if recap.tags.count >= 8, breadth >= 35 {
            style = .explorer; traits.append((breadth, RecapLine("%@ tags were new to your collection", String(newcomers))))
        } else if recap.saves >= 3, feedShare >= 60 {
            style = .wanderer; traits.append((feedShare, RecapLine("%@%% of saves came from browsing", String(feedShare))))
        } else {
            style = .collector; traits.append((0, RecapLine("%@ works joined your collection", String(recap.saves))))
        }
        if recap.longestStreak >= 3 { traits.append((recap.longestStreak, RecapLine("Longest streak: %@ days", String(recap.longestStreak)))) }
        return .init(rhythm: rhythm, style: style, traits: traits.map(\.1))
    }
}

enum RecapPersonaClock {
    static func hour(_ hour: Int) -> String { L10n.text(hour < 12 ? "%@ AM" : "%@ PM", String(hour % 12 == 0 ? 12 : hour % 12)) }
}

extension RecapIndex {
    /// Every period with activity, newest first, numbered like a magazine's run.
    func issues(period: TastePeriod = .month, now: Date = Date(), limit: Int = 36) -> [TasteRecap] {
        guard let first = entries.first(where: { $0.kind == .save || ($0.kind == .open && $0.at > 0 && $0.signal == nil) }) else { return [] }
        let calendar = calendar, unit: Calendar.Component = period == .week ? .weekOfYear : period == .year ? .year : .month
        let startOfFirst = calendar.dateInterval(of: unit, for: Date(timeIntervalSince1970: first.at))?.start ?? Date(timeIntervalSince1970: first.at)
        let startOfNow = calendar.dateInterval(of: unit, for: now)?.start ?? now
        let span = calendar.dateComponents([unit], from: startOfFirst, to: startOfNow).value(for: unit) ?? 0
        var result: [TasteRecap] = []
        for offset in stride(from: 0, through: -max(0, span), by: -1) {
            if result.count >= limit { break }
            // Shelves show many issues. Library matching waits until one is opened.
            if let recap = recap(period: period, offset: offset, now: now, rediscovers: false), recap.hasActivity { result.append(recap) }
        }
        for index in result.indices { result[index].issue = result.count - index }
        return result
    }
    func yearly(offset: Int, now: Date = Date()) -> TasteRecap? {
        guard var recap = recap(period: .year, offset: offset, now: now) else { return nil }
        recap.months = (0..<12).compactMap { month in
            guard let start = calendar.date(byAdding: .month, value: month, to: recap.interval.start),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            let range = entries[firstEntry(atOrAfter: start.timeIntervalSince1970)...].prefix { $0.at < end.timeIntervalSince1970 }.filter { $0.kind == .save }
            var seen = Set<String>(), counts: [String: Int] = [:]
            for entry in range where seen.insert(entry.key).inserted { for tag in entry.tags { counts[tag, default: 0] += 1 } }
            return .init(start: start, saves: seen.count, topTag: counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key)
        }
        return recap
    }
}

/// The story's pages, chosen from what the period actually contains. A page
/// with nothing true to say is left out rather than padded.
enum RecapPage: String, CaseIterable, Identifiable, Sendable {
    case cover, numbers, chart, person, palette, discovery, rhythm, time, year, favorite, rediscover, persona, next
    var id: String { rawValue }
    static func pages(for recap: TasteRecap) -> [RecapPage] {
        guard recap.hasActivity else { return [.cover] }
        var pages: [RecapPage] = [.cover, .numbers]
        if !recap.tags.isEmpty { pages.append(.chart) }
        if recap.period != .week, !recap.people.isEmpty, (recap.people.first?.count ?? 0) >= 2 { pages.append(.person) }
        if recap.period != .week, !recap.saved.isEmpty { pages.append(.palette) }
        if !recap.highlights.isEmpty { pages.append(.discovery) }
        if !recap.months.isEmpty { pages.append(.year) }
        if recap.activeDays >= 2 { pages.append(.rhythm) }
        if recap.seconds >= 300 { pages.append(.time) }
        if recap.revisited != nil { pages.append(.favorite) }
        if !recap.rediscover.isEmpty { pages.append(.rediscover) }
        if recap.persona != nil { pages.append(.persona) }
        pages.append(.next)
        return pages
    }
}

extension Array where Element: Hashable {
    var uniqued: [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
