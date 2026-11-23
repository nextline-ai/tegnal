import SwiftUI
import GRDB

/// How duplicates are found and which copy stays, kept between visits, one set for each mode.
struct DuplicateCleanupOptions: Codable, Equatable {
    /// What makes two saved works the same work.
    enum Match: String, Codable, CaseIterable, Identifiable {
        /// The same work number: one work saved in several folders.
        case sameNumber
        /// The title without its bracketed parts (circle, parody, language, translator) and the same artist.
        case sameTitle
        /// The same full title, artist, language and type.
        case exact
        var id: String { rawValue }
        var title: String {
            switch self { case .sameNumber: "Same Work Number"; case .sameTitle: "Same Title and Artist"; case .exact: "Exact Match" }
        }
    }

    /// Which copy stays once folders and language have had their say.
    enum Keep: String, Codable, CaseIterable, Identifiable {
        case oldestSaved, newestSaved, newestNumber, oldestNumber, mostPages, recentlyRead, largestImage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oldestSaved: "Saved First"
            case .newestSaved: "Saved Last"
            case .newestNumber: "Newest Upload"
            case .oldestNumber: "Oldest Upload"
            case .mostPages: "Most Pages"
            case .recentlyRead: "Read Most Recently"
            case .largestImage: "Largest Image"
            }
        }
        static func choices(images: Bool, match: Match = .sameTitle) -> [Keep] {
            if images { return [.oldestSaved, .newestSaved, .newestNumber, .oldestNumber, .largestImage] }
            // One work in several folders: only when it went into each folder tells them apart.
            if match == .sameNumber { return [.oldestSaved, .newestSaved] }
            return [.oldestSaved, .newestSaved, .newestNumber, .oldestNumber, .mostPages, .recentlyRead]
        }
    }

    var match = Match.sameNumber
    /// A translation of a work counts as the same work.
    var acrossLanguages = false
    var keep = Keep.oldestSaved
    /// A copy in this language stays first; empty for any.
    var preferredLanguage = ""
    /// A copy in a folder higher in `folderOrder` stays first.
    var useFolderOrder = true
    /// Folder keys, highest first; folders not listed follow in their usual order.
    var folderOrder: [String] = []
    /// The kept copy takes the folders and notes of the copies removed.
    var combine = true
    /// Removed copies that a signed-in website keeps as favorites leave it too.
    var removeFromWebsite = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let standard = DuplicateCleanupOptions()
        match = (try? values.decodeIfPresent(Match.self, forKey: .match)) ?? standard.match
        acrossLanguages = (try? values.decodeIfPresent(Bool.self, forKey: .acrossLanguages)) ?? standard.acrossLanguages
        keep = (try? values.decodeIfPresent(Keep.self, forKey: .keep)) ?? standard.keep
        preferredLanguage = (try? values.decodeIfPresent(String.self, forKey: .preferredLanguage)) ?? standard.preferredLanguage
        useFolderOrder = (try? values.decodeIfPresent(Bool.self, forKey: .useFolderOrder)) ?? standard.useFolderOrder
        folderOrder = (try? values.decodeIfPresent([String].self, forKey: .folderOrder)) ?? standard.folderOrder
        combine = (try? values.decodeIfPresent(Bool.self, forKey: .combine)) ?? standard.combine
        removeFromWebsite = (try? values.decodeIfPresent(Bool.self, forKey: .removeFromWebsite)) ?? standard.removeFromWebsite
    }

    /// The keep rule, or saved first where the chosen one doesn't apply to this match.
    func keep(images: Bool) -> Keep { Keep.choices(images: images, match: match).contains(keep) ? keep : .oldestSaved }

    private static func key(images: Bool) -> String { images ? "booru.duplicateCleanup" : "library.duplicateCleanup" }

    static func load(images: Bool, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key(images: images)), let value = try? JSONDecoder().decode(Self.self, from: data) else {
            var value = Self()
            if images { value.keep = .oldestSaved }
            return value
        }
        return value
    }

    func save(images: Bool, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(images: images)) }
    }
}

/// One saved copy of a work or an image, as the cleanup compares them.
struct DuplicateCopy: Identifiable, Equatable {
    /// The work number, or the image's `server:post` id.
    let id: String
    /// The work number or post number; a larger one was uploaded later.
    let number: Int64
    let title: String
    let savedAt: Date?
    let lastOpenedAt: Date?
    /// The folders it is saved in, by their keys.
    let folders: [String]
    let language: String
    /// Pages for a work; pixels for an image.
    let size: Int
    var thumbnailPath: String? = nil
    var previewURL: URL? = nil
    /// The image's server, shown beside it.
    var server: String? = nil
}

/// Copies of one work or image, with the one that stays. For one work saved in several folders
/// (`workNumber`), each copy is one of its folders, and the folder kept is where it stays.
struct DuplicateGroup: Identifiable, Equatable {
    let id: String
    let title: String
    var copies: [DuplicateCopy]
    var keeperID: String
    var workNumber: Int64? = nil
    var keeper: DuplicateCopy? { copies.first { $0.id == keeperID } }
    var removals: [DuplicateCopy] { copies.filter { $0.id != keeperID } }
}

/// Finds duplicates and chooses which copy stays, with no database or screen of its own.
enum DuplicateFinder {
    /// The title without bracketed parts — circle, parody, language, translator, version — in lower
    /// case with punctuation and extra spaces dropped. A title that is all brackets keeps them.
    static func coreTitle(_ title: String) -> String {
        let pairs: [Character: Character] = ["[": "]", "(": ")", "{": "}", "【": "】", "（": "）", "［": "］", "｛": "｝"]
        var stack: [Character] = []
        var outside = ""
        for character in title {
            if let close = pairs[character] { stack.append(close); continue }
            if let last = stack.last, character == last { stack.removeLast(); continue }
            if stack.isEmpty { outside.append(character) }
        }
        func simplified(_ text: String) -> String {
            let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let core = simplified(outside)
        return core.isEmpty ? simplified(title) : core
    }

    private static func names(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    /// What two works must share to be the same work; nil leaves a work out, as one without a title or artist.
    static func key(_ work: Work, options: DuplicateCleanupOptions) -> String? {
        if options.match == .exact { return LibraryMaintenance.duplicateKey(work) }
        guard let title = work.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let person = names(work.artists).sorted().first ?? names(work.groups).sorted().first else { return nil }
        let core = coreTitle(title)
        guard !core.isEmpty else { return nil }
        var parts = [core, person]
        if !options.acrossLanguages { parts.append((work.language ?? "").lowercased()) }
        return parts.joined(separator: "\u{0}")
    }

    static func copy(_ work: Work, folderKeys: [Int64: String]) -> DuplicateCopy {
        let parser = ISO8601DateFormatter()
        return DuplicateCopy(id: String(work.galleryId), number: work.galleryId, title: work.title ?? String(work.galleryId),
                             savedAt: parser.date(from: work.bookmarkedAt), lastOpenedAt: work.lastOpenedAt.flatMap(parser.date(from:)),
                             folders: work.folders.compactMap { $0.id.flatMap { folderKeys[$0] } }, language: (work.language ?? "").lowercased(),
                             size: work.pageCount ?? 0, thumbnailPath: work.thumbStatus == "ready" ? work.thumbPath : nil)
    }

    /// Saved works that are the same work, each with the copy the options keep.
    static func comics(_ works: [Work], folderKeys: [Int64: String], folderRank: [String: Int], options: DuplicateCleanupOptions) -> [DuplicateGroup] {
        var grouped: [String: [Work]] = [:]
        for work in works { if let key = key(work, options: options) { grouped[key, default: []].append(work) } }
        return grouped.compactMap { key, works -> DuplicateGroup? in
            guard works.count > 1 else { return nil }
            let copies = works.map { copy($0, folderKeys: folderKeys) }
            let keeper = keeper(copies, rank: folderRank, options: options)
            return DuplicateGroup(id: key, title: copies.first { $0.id == keeper }?.title ?? copies[0].title, copies: order(copies, keeper: keeper), keeperID: keeper)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Saved images with the same original file, each with the copy the options keep.
    static func images(_ records: [BooruStore.FavoriteRecord], serverNames: [String: String], folderRank: [String: Int], options: DuplicateCleanupOptions) -> [DuplicateGroup] {
        var grouped: [String: [BooruStore.FavoriteRecord]] = [:]
        for record in records { if let key = LibraryMaintenance.duplicateKey(record.post) { grouped[key, default: []].append(record) } }
        return grouped.compactMap { key, records -> DuplicateGroup? in
            guard records.count > 1 else { return nil }
            let copies = records.map { record in
                DuplicateCopy(id: record.post.id, number: record.post.postID, title: record.post.artists.first ?? record.post.tags.prefix(3).joined(separator: " "),
                              savedAt: record.savedAt, lastOpenedAt: nil, folders: [record.folderID], language: "",
                              size: record.post.width * record.post.height, previewURL: record.post.previewURL,
                              server: serverNames[record.post.serverID] ?? record.post.serverID)
            }
            let keeper = keeper(copies, rank: folderRank, options: options)
            return DuplicateGroup(id: key, title: copies[0].title, copies: order(copies, keeper: keeper), keeperID: keeper)
        }.sorted { ($0.copies.first?.savedAt ?? .distantPast) > ($1.copies.first?.savedAt ?? .distantPast) }
    }

    /// The kept copy first, then the others as they were saved.
    private static func order(_ copies: [DuplicateCopy], keeper: String) -> [DuplicateCopy] {
        copies.sorted { a, b in
            if (a.id == keeper) != (b.id == keeper) { return a.id == keeper }
            return (a.savedAt ?? .distantPast) < (b.savedAt ?? .distantPast)
        }
    }

    /// The copy that stays: one in the highest folder, then one in the preferred language, then the
    /// keep rule; the smaller number settles a tie.
    static func keeper(_ copies: [DuplicateCopy], rank: [String: Int], options: DuplicateCleanupOptions) -> String {
        func folderRank(_ copy: DuplicateCopy) -> Int { copy.folders.compactMap { rank[$0] }.min() ?? .max }
        let language = options.preferredLanguage.lowercased()
        let keep = options.keep(images: copies.contains { $0.server != nil })
        return copies.min { a, b in
            if options.useFolderOrder, folderRank(a) != folderRank(b) { return folderRank(a) < folderRank(b) }
            if !language.isEmpty, (a.language == language) != (b.language == language) { return a.language == language }
            switch keep {
            case .oldestSaved where a.savedAt != b.savedAt: return (a.savedAt ?? .distantFuture) < (b.savedAt ?? .distantFuture)
            case .newestSaved where a.savedAt != b.savedAt: return (a.savedAt ?? .distantPast) > (b.savedAt ?? .distantPast)
            case .newestNumber where a.number != b.number: return a.number > b.number
            case .oldestNumber where a.number != b.number: return a.number < b.number
            case .mostPages where a.size != b.size, .largestImage where a.size != b.size: return a.size > b.size
            case .recentlyRead where a.lastOpenedAt != b.lastOpenedAt: return (a.lastOpenedAt ?? .distantPast) > (b.lastOpenedAt ?? .distantPast)
            default: break
            }
            return a.number < b.number
        }?.id ?? copies[0].id
    }

    /// One work saved in several folders, each folder a copy: it stays in the folder the options
    /// prefer. `fixed` folders (kept with website favorites, smart folders) are left as they are.
    static func placements(_ works: [Work], addedAt: [Int64: [Int64: String]], folderKeys: [Int64: String], folderNames: [String: String],
                           folderRank: [String: Int], fixed: Set<String>, options: DuplicateCleanupOptions) -> [DuplicateGroup] {
        let parser = ISO8601DateFormatter()
        return works.compactMap { work -> DuplicateGroup? in
            let folders = work.folders.compactMap { folder in folder.id.flatMap { id in folderKeys[id].map { (id, $0) } } }.filter { !fixed.contains($0.1) }
            guard folders.count > 1 else { return nil }
            let copies = folders.map { id, key in
                DuplicateCopy(id: "\(work.galleryId)@\(key)", number: work.galleryId, title: folderNames[key] ?? key,
                              savedAt: addedAt[work.galleryId]?[id].flatMap(parser.date(from:)), lastOpenedAt: nil, folders: [key],
                              language: "", size: 0, thumbnailPath: work.thumbStatus == "ready" ? work.thumbPath : nil)
            }
            let keeper = keeper(copies, rank: folderRank, options: options)
            return DuplicateGroup(id: "number:\(work.galleryId)", title: work.title ?? String(work.galleryId), copies: order(copies, keeper: keeper),
                                  keeperID: keeper, workNumber: work.galleryId)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Each folder's place: the chosen order first, then the others in `standard` order.
    static func rank(order: [String], standard: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for key in order + standard where result[key] == nil && standard.contains(key) { result[key] = result.count }
        return result
    }
}

/// What a cleanup changed, so it can be put back.
struct DuplicateUndo {
    /// Removed works, their folders, and the kept works' folders, notes and reading times before.
    var works: [Work] = []
    var memberships: [(workID: Int64, folderID: Int64, addedAt: String)] = []
    var keepers: [(workID: Int64, memberships: [(folderID: Int64, addedAt: String)], note: String?, lastOpenedAt: String?)] = []
    /// Folder memberships a tidy took away.
    var tidied: [(workID: Int64, folderID: Int64, addedAt: String)] = []
    /// Removed images, as they were saved.
    var images: [BooruStore.FavoriteRecord] = []
    /// Website favorites left alone before, by website or server.
    var siteIgnored: [String: Set<Int64>?] = [:]
    var serverIgnored: [String: Set<Int64>?] = [:]
    var removedCount = 0
    var tidiedCount = 0
}

/// Carries a cleanup out on the library, and puts it back.
enum DuplicateCleaner {
    /// Removes each group's other copies. With `combine` the kept copy takes their folders (apart
    /// from the given website folders) and notes. Removed works a website keeps as favorites stay
    /// there unless `removeFromWebsite`.
    static func applyComics(_ groups: [DuplicateGroup], combine: Bool, removeFromWebsite: Bool,
                            websiteFolders: Set<Int64>, database: AppDatabase) throws -> DuplicateUndo {
        var undo = DuplicateUndo()
        let placements = groups.filter { $0.workNumber != nil }
        let groups = groups.filter { $0.workNumber == nil }
        let removed = Set(groups.flatMap { $0.removals.compactMap { Int64($0.id) } })
        if !removeFromWebsite { undo.siteIgnored = leaveOnWebsites(removed) }
        try database.dbWriter.write { db in
            for group in groups {
                guard let keeperNumber = Int64(group.keeperID),
                      let keeper = try Work.filter(Work.Columns.galleryId == keeperNumber).fetchOne(db), let keeperID = keeper.id else { continue }
                let before = try Row.fetchAll(db, sql: "SELECT folder_id, added_at FROM folder_works WHERE work_id = ?", arguments: [keeperID])
                undo.keepers.append((keeperID, before.map { ($0["folder_id"], $0["added_at"]) }, keeper.note, keeper.lastOpenedAt))
                var notes = [keeper.note].compactMap { $0 }.filter { !$0.isEmpty }
                var lastOpened = keeper.lastOpenedAt
                for copy in group.removals {
                    guard let number = Int64(copy.id), let work = try Work.filter(Work.Columns.galleryId == number).fetchOne(db), let workID = work.id else { continue }
                    let rows = try Row.fetchAll(db, sql: "SELECT folder_id, added_at FROM folder_works WHERE work_id = ?", arguments: [workID])
                    undo.works.append(work)
                    undo.memberships += rows.map { (workID, $0["folder_id"], $0["added_at"]) }
                    if combine {
                        for row in rows where !websiteFolders.contains(row["folder_id"]) {
                            try db.execute(sql: "INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?) ON CONFLICT(folder_id, work_id) DO NOTHING",
                                           arguments: [row["folder_id"] as Int64, keeperID, row["added_at"] as String])
                        }
                        if let note = work.note, !note.isEmpty, !notes.contains(note) { notes.append(note) }
                    }
                    if let opened = work.lastOpenedAt, opened > (lastOpened ?? "") { lastOpened = opened }
                    try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [workID])
                    try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [workID])
                    undo.removedCount += 1
                }
                try AppDatabase.leaveUnfiled(workID: keeperID, db: db)
                try db.execute(sql: "UPDATE works SET note = ?, last_opened_at = ? WHERE id = ?",
                               arguments: [notes.isEmpty ? keeper.note : notes.joined(separator: "\n\n"), lastOpened, keeperID])
            }
            for group in placements {
                guard let number = group.workNumber,
                      let workID = try Int64.fetchOne(db, sql: "SELECT id FROM works WHERE gallery_id = ?", arguments: [number]) else { continue }
                for copy in group.removals {
                    guard let folderID = copy.folders.first.flatMap(Int64.init),
                          let addedAt = try String.fetchOne(db, sql: "SELECT added_at FROM folder_works WHERE work_id = ? AND folder_id = ?", arguments: [workID, folderID]) else { continue }
                    try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ? AND folder_id = ?", arguments: [workID, folderID])
                    undo.tidied.append((workID, folderID, addedAt))
                }
                undo.tidiedCount += 1
            }
        }
        return undo
    }

    /// Removes each group's other images. Removed images a server keeps as favorites stay there
    /// unless `removeFromWebsite`.
    @MainActor static func applyImages(_ groups: [DuplicateGroup], records: [BooruStore.FavoriteRecord], removeFromWebsite: Bool,
                                       accounts: BooruAccountSync) throws -> DuplicateUndo {
        var undo = DuplicateUndo()
        let removed = Set(groups.flatMap { $0.removals.map(\.id) })
        undo.images = records.filter { removed.contains($0.post.id) }
        for serverID in Set(undo.images.map(\.post.serverID)) { undo.serverIgnored[serverID] = accounts.accounts.favorites.state(for: serverID)?.ignored }
        try accounts.removeFavorites(undo.images.map(\.post), keepOnServer: !removeFromWebsite)
        undo.removedCount = undo.images.count
        return undo
    }

    /// When each saved work went into each of its folders, by work number and folder.
    static func folderTimes(_ database: AppDatabase) throws -> [Int64: [Int64: String]] {
        try database.dbWriter.read { db in
            var result: [Int64: [Int64: String]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT w.gallery_id, fw.folder_id, fw.added_at FROM folder_works fw JOIN works w ON w.id = fw.work_id") {
                result[row["gallery_id"], default: [:]][row["folder_id"]] = row["added_at"]
            }
            return result
        }
    }

    /// Leaves removed works alone on every synced website; returns what each left alone before.
    private static func leaveOnWebsites(_ ids: Set<Int64>) -> [String: Set<Int64>?] {
        var before: [String: Set<Int64>?] = [:]
        let store = SiteFavoriteFolders.shared
        for site in store.syncedSites {
            guard var state = store.state(for: site) else { continue }
            let kept = ids.filter { state.baseline?[$0] != nil }
            guard !kept.isEmpty else { continue }
            before[site] = state.ignored
            state.ignored = (state.ignored ?? []).union(kept)
            store.setState(state, for: site)
        }
        return before
    }

    /// Puts a cleanup back: removed copies return with their folders, and kept copies get their
    /// folders, notes and reading times back.
    @MainActor static func undo(_ undo: DuplicateUndo, database: AppDatabase, images: BooruStore, accounts: BooruAccountSync) throws {
        if !undo.works.isEmpty || !undo.tidied.isEmpty || !undo.keepers.isEmpty {
            try database.dbWriter.write { db in
                for var work in undo.works where try Work.fetchOne(db, key: work.id) == nil { try work.insert(db) }
                for row in undo.memberships + undo.tidied {
                    try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [row.folderID, row.workID, row.addedAt])
                }
                for keeper in undo.keepers {
                    try db.execute(sql: "DELETE FROM folder_works WHERE work_id = ?", arguments: [keeper.workID])
                    for row in keeper.memberships {
                        try db.execute(sql: "INSERT INTO folder_works (folder_id, work_id, added_at) VALUES (?, ?, ?)", arguments: [row.folderID, keeper.workID, row.addedAt])
                    }
                    try db.execute(sql: "UPDATE works SET note = ?, last_opened_at = ? WHERE id = ?", arguments: [keeper.note, keeper.lastOpenedAt, keeper.workID])
                }
            }
        }
        let sites = SiteFavoriteFolders.shared
        for (site, ignored) in undo.siteIgnored {
            guard var state = sites.state(for: site) else { continue }
            state.ignored = ignored
            sites.setState(state, for: site)
        }
        if !undo.images.isEmpty { try images.restoreFavorites(undo.images) }
        for (serverID, ignored) in undo.serverIgnored {
            guard var state = accounts.accounts.favorites.state(for: serverID) else { continue }
            state.ignored = ignored
            accounts.accounts.favorites.setState(state, for: serverID)
        }
    }
}

extension BooruStore {
    /// Saves images back as they were: the same folder and moment.
    func restoreFavorites(_ records: [FavoriteRecord]) throws {
        try database.write { db in
            let encoder = JSONEncoder()
            for record in records {
                try db.execute(sql: "INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)",
                               arguments: [record.post.serverID, record.post.postID, try encoder.encode(record.post), record.savedAt.timeIntervalSince1970, record.folderID])
            }
        }
        try refresh()
    }
}

/// A language as the library names it, such as "korean", shown in the app's language.
enum LibraryLanguage {
    static func title(_ code: String) -> String { L10n.text(code.prefix(1).uppercased() + code.dropFirst()) }
}

// MARK: - Screen

/// Finds duplicate works (or images) in the whole library and removes the extra copies in one go,
/// keeping the copy the chosen rules prefer; any group can be skipped or given another keeper.
struct DuplicateCleanupView: View {
    var booru = false
    @Environment(AppEnvironment.self) private var env
    @State private var options = DuplicateCleanupOptions()
    @State private var works: [Work] = []
    @State private var records: [BooruStore.FavoriteRecord] = []
    @State private var folders: [(key: String, name: String)] = []
    /// Folders a website's or server's favorites are kept in step with.
    @State private var websiteFolders: Set<String> = []
    @State private var unfiled: String?
    /// When each saved work went into each of its folders.
    @State private var addedAt: [Int64: [Int64: String]] = [:]
    /// Smart folders, left as they are when a work in several folders is tidied.
    @State private var smartFolders: Set<String> = []
    @State private var groups: [DuplicateGroup] = []
    @State private var keepers: [String: String] = [:]
    @State private var skipped: Set<String> = []
    @State private var loaded = false
    @State private var busy = false
    @State private var confirming = false
    @State private var undo: DuplicateUndo?
    @State private var message: String?
    @State private var error: String?
    @State private var inspectedComic: IdentifiableString?

    private var chosenGroups: [DuplicateGroup] {
        groups.filter { !skipped.contains($0.id) }.map { group in
            var group = group
            if let keeper = keepers[group.id], group.copies.contains(where: { $0.id == keeper }) { group.keeperID = keeper }
            return group
        }
    }
    private var removalCount: Int { chosenGroups.reduce(0) { $0 + $1.removals.count } }
    /// One work in several folders: nothing leaves the library, a work only leaves extra folders.
    private var byNumber: Bool { !booru && options.match == .sameNumber }
    private var languages: [String] {
        Set(works.compactMap { $0.language?.lowercased() }.filter { !$0.isEmpty }).sorted()
    }
    private var folderNames: [String: String] { Dictionary(folders.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first }) }
    private var hasWebsiteFavorites: Bool {
        booru ? !env.booruAccounts.setUpTimes.isEmpty || env.booru.servers.contains { env.booruAccounts.state($0) != nil }
              : !SiteFavoriteFolders.shared.syncedSites.isEmpty
    }

    var body: some View {
        List {
            summary
            findSection
            keepSection
            removedSection
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if loaded && groups.isEmpty {
                Section { Text(L10n.text(booru ? "No Duplicate Images" : byNumber ? "No Works in Several Folders" : "No Duplicate Works")).foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in groupSection(group) }
        }
        .navigationTitle(L10n.text("Clean Up Duplicates")).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { applyBar }
        .disabled(busy)
        .task { options = DuplicateCleanupOptions.load(images: booru); await load() }
        .onChange(of: options) { _, value in value.save(images: booru); regroup() }
        .appFullScreenCover(item: $inspectedComic) { ContentEntryView(initialUrl: $0.id) }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("Done"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    // MARK: Sections

    private var summary: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                if busy && !loaded { ProgressView() }
                Text(byNumber ? L10n.text("%@ works in several folders · %@ folders to leave", chosenGroups.count.formatted(), removalCount.formatted())
                              : L10n.text("%@ duplicate groups · %@ copies to remove", chosenGroups.count.formatted(), removalCount.formatted()))
                    .font(.headline).accessibilityIdentifier("duplicates.summary")
            }
        } footer: {
            Text(L10n.text(booru
                ? "Images with the same original file are duplicates. Tap a copy to keep it instead, or skip a group. Undo is available right after cleaning up."
                : byNumber
                ? "A work saved in more than one folder stays in one of them; no work leaves the library. Tap a folder to keep the work there instead, or skip it. Folders kept with website favorites and smart folders are left as they are."
                : "Tap a copy to keep it instead, or skip a group. Undo is available right after cleaning up. A backup in Settings keeps everything safe for longer."))
        }
    }

    @ViewBuilder private var findSection: some View {
        if !booru {
            Section(L10n.text("Find Duplicates")) {
                Picker(L10n.text("Same Work When"), selection: $options.match) {
                    ForEach(DuplicateCleanupOptions.Match.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.accessibilityIdentifier("duplicates.match")
                if options.match == .sameTitle {
                    Toggle(isOn: $options.acrossLanguages) {
                        SettingsHelpLabel("Count Translations as Duplicates", help: "Works with the same title and artist in different languages count as one work, so only one language stays. Use Preferred Language to choose which.")
                    }.accessibilityIdentifier("duplicates.acrossLanguages")
                }
            }
        }
    }

    private var keepSection: some View {
        Section {
            NavigationLink {
                DuplicateFolderOrderView(options: $options, folders: folders)
            } label: {
                LabeledContent(L10n.text("Folder Priority"), value: L10n.text(options.useFolderOrder ? "On" : "Off"))
            }.accessibilityIdentifier("duplicates.folderOrder")
            if !booru && !byNumber {
                Picker(L10n.text("Preferred Language"), selection: $options.preferredLanguage) {
                    Text(L10n.text("Any Language")).tag("")
                    ForEach(languages, id: \.self) { Text(LibraryLanguage.title($0)).tag($0) }
                    if !options.preferredLanguage.isEmpty && !languages.contains(options.preferredLanguage) {
                        Text(LibraryLanguage.title(options.preferredLanguage)).tag(options.preferredLanguage)
                    }
                }.accessibilityIdentifier("duplicates.language")
            }
            Picker(L10n.text("Then Keep"), selection: Binding(get: { options.keep(images: booru) }, set: { options.keep = $0 })) {
                ForEach(DuplicateCleanupOptions.Keep.choices(images: booru, match: options.match)) { Text(L10n.text($0.title)).tag($0) }
            }.accessibilityIdentifier("duplicates.keep")
        } header: {
            Text(L10n.text("Which Copy Stays"))
        } footer: {
            Text(L10n.text(booru || byNumber
                ? "A copy in a folder higher in Folder Priority stays first; then the rule above decides."
                : "A copy in a folder higher in Folder Priority stays first, then one in the preferred language; then the rule above decides."))
        }
    }

    @ViewBuilder private var removedSection: some View {
        if !byNumber && (!booru || hasWebsiteFavorites) {
            Section(L10n.text("Removed Copies")) {
                if !booru {
                    Toggle(L10n.text("Bring Folders and Notes Along"), isOn: $options.combine).accessibilityIdentifier("duplicates.combine")
                }
                if hasWebsiteFavorites {
                    Toggle(isOn: $options.removeFromWebsite) {
                        SettingsHelpLabel("Remove from Website Favorites Too", help: "Off, removed copies stay in your favorites on the website and the sync leaves them alone. On, they leave the website's favorites as well.")
                    }.accessibilityIdentifier("duplicates.removeFromWebsite")
                }
            }
        }
    }

    private func groupSection(_ group: DuplicateGroup) -> some View {
        let skippedGroup = skipped.contains(group.id)
        let keeper = keepers[group.id] ?? group.keeperID
        return Section {
            ForEach(group.copies) { copy in
                DuplicateCopyRow(copy: copy, keeps: copy.id == keeper, skipped: skippedGroup, images: booru, placement: group.workNumber != nil,
                                 folderNames: copy.folders.compactMap { folderNames[$0] }) {
                    keepers[group.id] = copy.id
                    skipped.remove(group.id)
                } open: {
                    if !booru, let number = Int64(copy.id) { inspectedComic = .init(id: MangaUrls.galleryUrl(for: number)) }
                }
            }
        } header: {
            HStack {
                Text(group.title).lineLimit(1)
                Spacer()
                Button(L10n.text(skippedGroup ? "Include" : "Skip")) {
                    if skippedGroup { skipped.remove(group.id) } else { skipped.insert(group.id) }
                }.font(.caption.weight(.semibold)).textCase(nil)
                    .accessibilityIdentifier("duplicates.skip.\(group.copies.map(\.id).sorted().joined(separator: "-"))")
            }
        }
    }

    private var applyBar: some View {
        VStack(spacing: 8) {
            if let undo {
                HStack {
                    Text(undo.removedCount > 0 ? L10n.text("Removed %@ copies", undo.removedCount.formatted()) : L10n.text("Tidied %@ works", undo.tidiedCount.formatted())).font(.subheadline)
                    Spacer()
                    Button(L10n.text("Undo")) { Task { await revert(undo) } }.buttonStyle(.bordered).accessibilityIdentifier("duplicates.undo")
                }
            }
            Button {
                confirming = true
            } label: {
                Text(byNumber ? L10n.text("Tidy %@ Works", chosenGroups.count.formatted()) : L10n.text("Clean Up %@ Copies", removalCount.formatted())).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(removalCount == 0 || busy)
            .accessibilityIdentifier("duplicates.apply")
            // On the button, so on iPad the question points at it instead of hiding under the top bar.
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(L10n.text("Clean Up"), role: .destructive) { Task { await apply() } }.accessibilityIdentifier("duplicates.confirm")
            } message: { Text(confirmMessage) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var confirmTitle: String {
        byNumber ? L10n.text("Tidy %@ Works?", chosenGroups.count.formatted()) : L10n.text("Clean Up %@ Copies?", removalCount.formatted())
    }
    private var confirmMessage: String {
        if byNumber { return L10n.text("Each work stays in one folder and leaves %@ others. No work leaves the library.", removalCount.formatted()) }
        var parts = [L10n.text("%@ copies leave the library; one copy of each stays.", removalCount.formatted())]
        if hasWebsiteFavorites {
            parts.append(L10n.text(options.removeFromWebsite ? "Copies that are website favorites leave the website too." : "Website favorites stay as they are."))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Work

    private func load() async {
        busy = true; defer { busy = false; loaded = true }
        do {
            if booru {
                records = env.booru.favoriteRecords()
                let syncedFolders = Set(env.booru.folders().map(\.id).filter { env.booruAccounts.isListFolder($0) })
                let all = env.booru.folders()
                websiteFolders = syncedFolders
                unfiled = all.first { $0.isUncategorized }?.id
                // The person's own folders first, then folders a server keeps, then uncategorized ones.
                let ordered = all.filter { !$0.isUncategorized && !syncedFolders.contains($0.id) } + all.filter { syncedFolders.contains($0.id) } + all.filter(\.isUncategorized)
                folders = ordered.map { ($0.id, $0.displayName) }
            } else {
                let database = env.database
                let value = try await Task.detached(priority: .userInitiated) { (try database.listWorks(), try DuplicateCleaner.folderTimes(database)) }.value
                works = value.0
                addedAt = value.1
                let all = try database.listFolders()
                smartFolders = Set(all.filter(\.isSmart).compactMap { $0.id.map(String.init) })
                var synced = Set<String>()
                let sites = SiteFavoriteFolders.shared
                for site in sites.syncedSites {
                    for identity in (sites.state(for: site)?.folders ?? [:]).values {
                        if let id = try database.folderID(identity: identity) { synced.insert(String(id)) }
                    }
                }
                websiteFolders = synced
                let unfiledID = try database.unfiledFolderID()
                unfiled = String(unfiledID)
                let mine = all.filter { $0.id != unfiledID && !synced.contains(String($0.id ?? -1)) }
                let ordered = mine + all.filter { synced.contains(String($0.id ?? -1)) } + all.filter { $0.id == unfiledID }
                folders = ordered.compactMap { folder in folder.id.map { (String($0), folder.displayName) } }
            }
            regroup()
        } catch { self.error = error.localizedDescription }
    }

    private func regroup() {
        let rank = DuplicateFinder.rank(order: options.folderOrder, standard: folders.map(\.key))
        if booru {
            let names = Dictionary(env.booru.servers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
            groups = DuplicateFinder.images(records, serverNames: names, folderRank: rank, options: options)
        } else {
            let keys = Dictionary(uniqueKeysWithValues: folders.compactMap { item in Int64(item.key).map { ($0, item.key) } })
            groups = options.match == .sameNumber
                ? DuplicateFinder.placements(works, addedAt: addedAt, folderKeys: keys, folderNames: folderNames, folderRank: rank,
                                             fixed: websiteFolders.union(smartFolders), options: options)
                : DuplicateFinder.comics(works, folderKeys: keys, folderRank: rank, options: options)
        }
        // A keeper chosen by hand stays chosen while its group is still found.
        let ids = Set(groups.map(\.id))
        keepers = keepers.filter { ids.contains($0.key) }
        skipped = skipped.intersection(ids)
    }

    private func apply() async {
        busy = true; defer { busy = false }
        do {
            let chosen = chosenGroups
            if booru {
                undo = try DuplicateCleaner.applyImages(chosen, records: records, removeFromWebsite: options.removeFromWebsite, accounts: env.booruAccounts)
            } else {
                let database = env.database, combine = options.combine, everywhere = options.removeFromWebsite
                let websiteIDs = Set(websiteFolders.compactMap { Int64($0) })
                // Folders kept in step with a website are only brought along when the website may change.
                let fixed = everywhere ? Set<Int64>() : websiteIDs
                undo = try await Task.detached(priority: .userInitiated) {
                    try DuplicateCleaner.applyComics(chosen, combine: combine, removeFromWebsite: everywhere, websiteFolders: fixed, database: database)
                }.value
            }
            message = nil
            keepers = [:]; skipped = []
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func revert(_ record: DuplicateUndo) async {
        busy = true; defer { busy = false }
        do {
            try DuplicateCleaner.undo(record, database: env.database, images: env.booru, accounts: env.booruAccounts)
            undo = nil
            message = L10n.text("The cleanup was undone.")
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// One copy in a group: its cover, number, language, pages, save date and folders, and whether it stays.
private struct DuplicateCopyRow: View {
    let copy: DuplicateCopy
    let keeps: Bool
    let skipped: Bool
    let images: Bool
    /// The copy is one of a work's folders.
    let placement: Bool
    let folderNames: [String]
    let choose: () -> Void
    let open: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                cover.frame(width: 44, height: 60).clipShape(RoundedRectangle(cornerRadius: 6)).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.title).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(L10n.text(skipped ? "Skipped" : keeps ? "Keep" : "Remove"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(skipped ? Color.secondary : keeps ? Color.green : Color.red)
                    .background(Capsule().fill((skipped ? Color.secondary : keeps ? Color.green : Color.red).opacity(0.15)))
            }
            .opacity(!keeps && !skipped ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.text("Keep This Copy"), systemImage: "checkmark.circle", action: choose)
            if !images && !placement { Button(L10n.text("Work Details"), systemImage: "info.circle", action: open) }
        }
        .accessibilityIdentifier("duplicates.copy.\(copy.id)")
        .accessibilityValue(L10n.text(keeps ? "Keep" : "Remove"))
    }

    @ViewBuilder private var cover: some View {
        if placement {
            Image(systemName: "folder").font(.title3).foregroundStyle(Color.accentColor)
        } else if let path = copy.thumbnailPath, let image = LocalThumbnailCache.shared.image(forPath: path) ?? UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let url = copy.previewURL {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        } else {
            Image(systemName: images ? "photo" : "book.closed").foregroundStyle(.secondary)
        }
    }

    private var details: String {
        let date = copy.savedAt.map { L10n.text("Saved %@", $0.formatted(.dateTime.locale(Locale(identifier: L10n.language)).year().month().day())) }
        if placement { return date ?? "" }
        var parts: [String] = []
        if let server = copy.server { parts.append(server) }
        parts.append("#\(copy.number)")
        if !copy.language.isEmpty { parts.append(LibraryLanguage.title(copy.language)) }
        if !images, copy.size > 0 { parts.append(L10n.text("%@ pages", copy.size.formatted())) }
        if images, copy.size > 0 { parts.append(L10n.text("%@ megapixels", (Double(copy.size) / 1_000_000).formatted(.number.precision(.fractionLength(1))))) }
        if let date { parts.append(date) }
        if !folderNames.isEmpty { parts.append(folderNames.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// The folders in the order their copies stay, dragged into place.
struct DuplicateFolderOrderView: View {
    @Binding var options: DuplicateCleanupOptions
    let folders: [(key: String, name: String)]
    @State private var order: [String] = []

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Prefer Folders in This Order"), isOn: $options.useFolderOrder).accessibilityIdentifier("duplicates.useFolderOrder")
            } footer: {
                Text(L10n.text("A copy in a folder higher in the list stays. Drag folders to change the order. Your own folders come first at the start, then folders kept with website favorites, then Unfiled."))
            }
            if options.useFolderOrder {
                Section {
                    ForEach(order, id: \.self) { key in
                        Text(folders.first { $0.key == key }?.name ?? key)
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        options.folderOrder = order
                    }
                }
                Section {
                    Button(L10n.text("Reset Order")) {
                        options.folderOrder = []
                        order = folders.map(\.key)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(L10n.text("Folder Priority")).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let rank = DuplicateFinder.rank(order: options.folderOrder, standard: folders.map(\.key))
            order = folders.map(\.key).sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
        }
    }
}
