import SwiftUI

/// A comics feed sometimes lists many works by one artist at once, which pushes everything else
/// down. Three or more works by one artist, each within a few works of the one before, are
/// shown as one row with the artist's name instead of a card each.
enum AuthorRuns {
    /// Works by one artist that make a run: three, and always more than a row holds, so a run
    /// never replaces what would fit in a single row anyway (four in three columns).
    static func minimum(columns: Int) -> Int { max(3, columns + 1) }
    /// Other works allowed between two of the artist's works in one run.
    static let allowedGap = 5

    /// One artist's works close together, as positions in the list.
    struct Run: Equatable {
        let artist: String
        let members: [Int]
    }

    /// A line of the feed: a row of cards, or one artist's run.
    enum Row: Equatable {
        case works([Int])
        case run(Run)

        /// The first position the line shows, which names it in the list.
        var first: Int {
            switch self {
            case .works(let positions): positions[0]
            case .run(let run): run.members[0]
            }
        }

        /// Every position the line shows.
        var positions: [Int] {
            switch self {
            case .works(let positions): positions
            case .run(let run): run.members
            }
        }
    }

    /// Runs among works whose artists are known; nil is a work not loaded yet, which never
    /// joins a run but counts as a work between two of one. A work by several artists can join
    /// a run for any of them, and joins one run at most: the longer one wins, then the earlier.
    static func runs(artists: [[String]?], columns: Int = 2) -> [Run] {
        let least = minimum(columns: columns)
        var positions: [String: [Int]] = [:]
        var names: [String: String] = [:]
        for (index, artists) in artists.enumerated() {
            var seen = Set<String>()
            for name in artists ?? [] {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = trimmed.lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                positions[key, default: []].append(index)
                if names[key] == nil { names[key] = trimmed }
            }
        }
        var candidates: [(key: String, members: [Int])] = []
        for (key, list) in positions {
            for chain in chains(list, minimum: least) { candidates.append((key: key, members: chain)) }
        }
        candidates.sort { first, second in
            if first.members.count != second.members.count { return first.members.count > second.members.count }
            if first.members[0] != second.members[0] { return first.members[0] < second.members[0] }
            return first.key < second.key
        }
        var taken = Set<Int>()
        var accepted: [Run] = []
        for candidate in candidates {
            for chain in chains(candidate.members.filter { !taken.contains($0) }, minimum: least) {
                taken.formUnion(chain)
                accepted.append(Run(artist: names[candidate.key] ?? candidate.key, members: chain))
            }
        }
        return accepted.sorted { $0.members[0] < $1.members[0] }
    }

    /// Ascending positions split where too many works lie between two, keeping long enough parts.
    private static func chains(_ list: [Int], minimum: Int) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for position in list {
            if let last = current.last, position - last > allowedGap + 1 {
                if current.count >= minimum { result.append(current) }
                current = []
            }
            current.append(position)
        }
        if current.count >= minimum { result.append(current) }
        return result
    }

    /// Lines for `count` works in `columns` columns. A run takes the place of its first work;
    /// one that starts partway through a row comes after that row, so no row is left short.
    static func rows(count: Int, runs: [Run], columns: Int) -> [Row] {
        let columns = max(1, columns)
        var starts: [Int: Run] = [:]
        var grouped = Set<Int>()
        for run in runs {
            starts[run.members[0]] = run
            grouped.formUnion(run.members)
        }
        var rows: [Row] = []
        var row: [Int] = []
        var waiting: [Run] = []
        for index in 0..<max(0, count) {
            if let run = starts[index] {
                if row.isEmpty { rows.append(.run(run)) } else { waiting.append(run) }
                continue
            }
            guard !grouped.contains(index) else { continue }
            row.append(index)
            if row.count == columns {
                rows.append(.works(row)); row = []
                rows += waiting.map(Row.run); waiting = []
            }
        }
        if !row.isEmpty { rows.append(.works(row)) }
        rows += waiting.map(Row.run)
        return rows
    }

}

/// One artist's run: their name, which opens their works, over a strip of the works' cards.
struct AuthorRunCard<Card: View>: View {
    @Environment(\.artworkCellStyle) private var style
    let artist: String
    let count: Int
    let openArtist: () -> Void
    @ViewBuilder let cards: () -> Card

    var body: some View {
        // Strip cards are the grid's cards, sized and lettered alike; the header names the
        // artist, so each card repeating it is noise.
        var strip = style
        strip.showsArtists = false
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: openArtist) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.rectangle.stack").font(.body.weight(.semibold)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artist).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(L10n.text("%@ works in a row", String(count))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
            .accessibilityHint(L10n.text("Shows all works by this artist"))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: style.spacing) { cards() }
                    .padding(.horizontal, 12)
            }
            .environment(\.artworkCellStyle, strip)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: max(12, style.radius(14)), style: .continuous))
    }
}
