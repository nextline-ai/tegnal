import Foundation

/// Which backups go. Works from names and sizes only.
///
/// Automatic backups made every few days are thinned as they age, so the kept ones grow further
/// apart rather than the oldest simply disappearing. When all backups together are still over the
/// limit, the one whose removal leaves the smallest gap for its age goes first, again widening the
/// spacing instead of cutting off the past.
enum BackupRetention {
    static let limit: Int64 = 100 * 1024 * 1024
    private static let day: TimeInterval = 24 * 3600
    /// How often an automatic backup is made while the app is used.
    static let periodicInterval: TimeInterval = 3 * day

    /// How far apart kept automatic backups are, by age: every one for the first two weeks, then
    /// one in each two weeks until twelve weeks, one in each eight weeks until a year, and one in
    /// each 24 weeks after that.
    static let tiers: [(until: TimeInterval, spacing: TimeInterval)] = [
        (14 * day, 0), (84 * day, 14 * day), (364 * day, 56 * day), (.infinity, 168 * day),
    ]

    struct Item: Equatable, Sendable {
        var name: String
        var size: Int64
        var device: String
        var kind: BackupKind
        var date: Date
    }

    /// Per device, the two newest `patch` backups and the newest `minor`, `safety`, `manual` and
    /// `periodic` ones are always kept: the copy made before a restore must outlive the passes after it.
    static func protected(_ items: [Item]) -> Set<String> {
        var kept = Set<String>()
        for (_, ofDevice) in Dictionary(grouping: unique(items), by: \.device) {
            let newest = ofDevice.sorted { ($0.date, $0.name) > ($1.date, $1.name) }
            for (kind, count) in [(BackupKind.patch, 2), (.minor, 1), (.safety, 1), (.manual, 1), (.periodic, 1)] {
                kept.formUnion(newest.filter { $0.kind == kind }.prefix(count).map(\.name))
            }
        }
        return kept
    }

    /// Automatic backups the spacing no longer needs. Within each window of an age tier only the
    /// oldest stays, so a window keeps the same backup as newer ones age into it. Windows are fixed
    /// in time, not counted from today, so what is kept does not shift from day to day.
    static func thinned(_ items: [Item], now: Date, keeping: Set<String> = []) -> [String] {
        let kept = protected(items).union(keeping)
        var deleted: [String] = []
        for (_, ofDevice) in Dictionary(grouping: unique(items).filter { $0.kind == .periodic }, by: \.device) {
            var windows = Set<String>()
            for item in ofDevice.sorted(by: { ($0.date, $0.name) < ($1.date, $1.name) }) {
                let age = now.timeIntervalSince(item.date)
                guard let tier = tiers.firstIndex(where: { age < $0.until }), tiers[tier].spacing > 0 else { continue }
                let window = "\(tier):\(Int((item.date.timeIntervalSince1970 / tiers[tier].spacing).rounded(.down)))"
                if !windows.insert(window).inserted, !kept.contains(item.name) { deleted.append(item.name) }
            }
        }
        return deleted
    }

    /// The backups to delete until the rest fit; `keeping` (the backup just made) is never among
    /// them. Each step removes the unprotected backup whose removal leaves the smallest gap for its
    /// age, so older backups grow further apart. The oldest and newest of all go only when nothing
    /// else can.
    static func expired(_ items: [Item], limit: Int64 = limit, keeping: Set<String> = [], now: Date = Date()) -> [String] {
        var timeline = unique(items).sorted { ($0.date, $0.name) < ($1.date, $1.name) }
        var total = timeline.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return [] }
        let kept = protected(timeline).union(keeping)
        var deleted: [String] = []
        while total > limit {
            var best: (index: Int, score: Double)?
            for (index, item) in timeline.enumerated() where !kept.contains(item.name) {
                let score: Double
                if index == 0 || index == timeline.count - 1 { score = .infinity }
                else {
                    let gap = timeline[index + 1].date.timeIntervalSince(timeline[index - 1].date)
                    score = gap / max(now.timeIntervalSince(item.date), day)
                }
                // Ties go to the older backup.
                if best == nil || score < best!.score { best = (index, score) }
            }
            guard let best else { break }
            let item = timeline.remove(at: best.index)
            deleted.append(item.name); total -= item.size
        }
        return deleted
    }

    /// A backup kept in two places counts once.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.name).inserted }
    }
}
