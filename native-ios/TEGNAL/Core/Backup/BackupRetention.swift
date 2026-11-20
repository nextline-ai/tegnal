import Foundation

/// Which backups go when all of them together are over the limit. Works from names and sizes only.
enum BackupRetention {
    static let limit: Int64 = 100 * 1024 * 1024

    struct Item: Equatable, Sendable {
        var name: String
        var size: Int64
        var device: String
        var kind: BackupKind
        var date: Date
    }

    /// Per device, the two newest `patch` backups and the newest `minor`, `safety` and `manual` ones
    /// are always kept: the copy made before a restore must outlive the passes after it.
    static func protected(_ items: [Item]) -> Set<String> {
        var kept = Set<String>()
        for (_, ofDevice) in Dictionary(grouping: unique(items), by: \.device) {
            let newest = ofDevice.sorted { ($0.date, $0.name) > ($1.date, $1.name) }
            for (kind, count) in [(BackupKind.patch, 2), (.minor, 1), (.safety, 1), (.manual, 1)] {
                kept.formUnion(newest.filter { $0.kind == kind }.prefix(count).map(\.name))
            }
        }
        return kept
    }

    /// The backups to delete, oldest unprotected first, until the rest fit; `keeping` (the backup
    /// just made) is never among them.
    static func expired(_ items: [Item], limit: Int64 = limit, keeping: Set<String> = []) -> [String] {
        let all = unique(items)
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return [] }
        let kept = protected(all).union(keeping)
        var deleted: [String] = []
        for item in all.filter({ !kept.contains($0.name) }).sorted(by: { ($0.date, $0.name) < ($1.date, $1.name) }) {
            guard total > limit else { break }
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
