import Foundation

/// A complete issue made of invented works. It runs through the real builder, so
/// the sample shows exactly what a person's own issue will contain.
extension TasteRecap {
    static func sample(mode: TasteMode, now: Date = Date(), timeZone: String = TimeZone.current.identifier) -> TasteRecap? {
        var control = TasteControl(); control.timeZone = timeZone
        let source = mode == .comics ? MangaUrls.source : "https://sample.invalid"
        let tags = mode == .booru
            ? ["sky", "cloud", "scenery", "sunset", "ocean", "rain", "forest", "night", "lantern", "umbrella", "train", "snow"]
            : ["tag:slice_of_life", "tag:adventure", "tag:fantasy", "tag:school_life", "tag:romance", "tag:mystery", "tag:travel", "tag:cooking", "tag:music", "tag:sports", "tag:seasons", "tag:friendship"]
        let artists = ["Mira Sato", "Noa Lindqvist", "Hana Okabe", "Theo Marsh"]
        guard let interval = TastePeriod.month.interval(offset: -1, now: now, timeZone: timeZone),
              let earlier = TastePeriod.month.interval(offset: -2, now: now, timeZone: timeZone) else { return nil }
        var events: [TasteEvent] = [], library: [String: RecapWorkInfo] = [:]
        func add(_ kind: TasteEvent.Kind, _ item: TasteItem, at: Double, context: DiscoveryContext, dwell: TasteDwell? = nil) {
            var event = TasteEvent(kind: kind, item: item, context: context, dwell: dwell)
            event.id = "sample-\(events.count)"; event.at = at; events.append(event)
        }
        let day = 86400.0, start = interval.start.timeIntervalSince1970
        for index in 0..<46 {
            let tagIndexes = [index % 3, 3 + index % 4, index % 9 == 0 ? 11 : 6 + index % 3]
            let item = TasteItem(source: source, id: Int64(index + 1), tags: tagIndexes.map { tags[$0] })
            let origin: DiscoveryContext = index % 3 == 0 ? .init(origin: .search, query: tags[index % 3], session: "s\(index % 7)") : .init(origin: .feed, session: "s\(index % 7)")
            let date = start + Double(index % 26) * day + (index % 4 == 0 ? 3 : 21) * 3600 + Double(index) * 90
            add(.open, item, at: date - 120, context: origin)
            add(.save, item, at: date, context: origin)
            add(.open, item, at: date + 30, context: origin, dwell: .init(seconds: 180 + Double(index % 5) * 200, pages: 8 + index % 18, finished: index % 3 == 0))
            if index == 4 { for visit in 1...4 { add(.open, item, at: date + Double(visit) * 18000, context: origin, dwell: .init(seconds: 300, pages: 20)) } }
            library[item.key] = .init(title: L10n.text("Sample work %@", String(index + 1)), artists: [artists[index % 5 == 0 ? 1 : index % 3 == 0 ? 2 : 0]], savedAt: Date(timeIntervalSince1970: date))
        }
        for index in 0..<18 {
            let item = TasteItem(source: source, id: Int64(index + 100), tags: [tags[index % 5], tags[5 + index % 3]])
            add(.save, item, at: earlier.start.timeIntervalSince1970 + Double(index) * day, context: .init(origin: .feed, session: "old\(index)"))
        }
        for index in 0..<6 {
            let item = TasteItem(source: source, id: Int64(index + 200), tags: [tags[index % 3]])
            add(.seed, item, at: 0, context: .unknown)
            library[item.key] = .init(title: L10n.text("Sample work %@", String(index + 47)), artists: [artists[3]], savedAt: Date(timeIntervalSince1970: 86400))
        }
        for index in 0..<5 { add(.search, .init(source: source, id: 0, tags: [tags[index]]), at: start + Double(index) * 4 * day, context: .init(origin: .search, query: tags[index], session: "q\(index)")) }
        let index = RecapIndex(events: events, control: control, mode: mode, library: library)
        guard var recap = index.recap(period: .month, offset: -1, now: now) else { return nil }
        recap.isSample = true; recap.issue = 12
        return recap
    }
}
