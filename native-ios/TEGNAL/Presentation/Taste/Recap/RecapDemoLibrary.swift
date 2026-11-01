#if DEBUG
import Foundation

/// Fourteen months of believable activity for UI tests and screenshots: taste
/// drifts over time, one tag goes quiet and returns, and evenings dominate.
enum RecapDemoLibrary {
    private static let eras: [[String]] = [
        ["forest", "river", "mist", "mountain", "cabin"],
        ["ocean", "lighthouse", "gull", "storm", "harbor"],
        ["rain", "umbrella", "neon", "city", "train"],
        ["snow", "lantern", "shrine", "night", "fox"]
    ]
    @MainActor static func seed(_ env: AppEnvironment) {
        let server = BooruServer.presets[0], store = env.booru
        let artists = ["mira_sato", "noa_lindqvist", "hana_okabe", "theo_marsh"], series = ["sky_atlas", "paper_harbor"], characters = ["lumi", "captain_oda"]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: env.taste.control.timeZone) ?? .gmt
        var postID: Int64 = 5000, stamped: [(String, Double)] = []
        let start = calendar.dateInterval(of: .month, for: Date())!.start
        for monthsAgo in stride(from: 13, through: 0, by: -1) {
            let era = eras[(13 - monthsAgo) / 3 % eras.count], first = calendar.date(byAdding: .month, value: -monthsAgo, to: start)!
            let total = monthsAgo == 0 ? 14 : 18 + (13 - monthsAgo) * 3
            for index in 0..<total {
                postID += 1
                var tags = [era[index % era.count], era[(index + 2) % era.count], "scenery"]
                if monthsAgo == 1, index % 4 == 0 { tags.append("aurora") }            // new to the collection
                if monthsAgo == 1, index % 7 == 0 { tags.append("forest") }             // back after a long absence
                let artist = artists[index % 3 == 0 ? 0 : index % 5 == 0 ? 2 : (13 - monthsAgo) % 4]
                tags = tags.uniqued
                var categories = Dictionary(uniqueKeysWithValues: tags.map { ($0, 0) }); categories[artist] = 1
                if index % 6 == 0 { tags.append(series[monthsAgo % 2]); categories[series[monthsAgo % 2]] = 3 }
                if index % 8 == 0 { tags.append(characters[monthsAgo % 2]); categories[characters[monthsAgo % 2]] = 4 }
                var post = BooruFixtureSource.post(postID, server: server, tags: tags + [artist])
                post.artists = [artist]; post.tagCategories = categories
                let origin: DiscoveryContext = index % 4 == 0 ? .init(origin: .search, query: tags[0], session: "s\(monthsAgo)-\(index % 5)") : .init(origin: .feed, session: "s\(monthsAgo)-\(index % 5)")
                try? store.toggleFavorite(post, context: origin)
                let day = monthsAgo == 0 ? Double(index % max(1, calendar.component(.day, from: Date()))) : Double(index * 2 % 27)
                let hour = index % 5 == 0 ? 8.0 : index % 3 == 0 ? 15.0 : 22.5
                let moment = first.timeIntervalSince1970 + day * 86400 + hour * 3600 + Double(index % 40) * 60
                stamped.append((String(postID), moment))
                let item = TasteItem(source: server.canonicalAddress, id: postID, tags: tags + [artist])
                try? store.database.write { db in
                    try TasteStore.recordDwell(.init(seconds: 40 + Double(index % 9) * 55, pages: 1), item: item, context: origin, db: db, at: Date(timeIntervalSince1970: moment + 30))
                    if index == 3 { for visit in 1...4 { try TasteStore.recordDwell(.init(seconds: 240, pages: 1), item: item, context: origin, db: db, at: Date(timeIntervalSince1970: moment + Double(visit) * 7200)) } }
                }
            }
        }
        let times = Dictionary(uniqueKeysWithValues: stamped)
        for var event in (try? store.tasteStore.events()) ?? [] where event.kind == .save {
            guard let moment = times[String(event.item.id)] else { continue }
            event.at = moment
            try? store.database.write { db in
                try db.execute(sql: "UPDATE taste_events SET at = ?, payload = ? WHERE id = ?", arguments: [moment, try JSONEncoder().encode(event), event.id])
                try db.execute(sql: "UPDATE favorites SET saved_at = ? WHERE post_id = ?", arguments: [moment, event.item.id])
            }
        }
        _ = try? store.saveFolder(id: "recap-demo", name: "Recap demo")
    }
}
#endif
