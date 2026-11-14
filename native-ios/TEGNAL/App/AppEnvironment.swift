import Foundation
import SwiftUI

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case dark = "dark"
    case light = "light"
    case system = "system"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: return L10n.text("Dark Mode")
        case .light: return L10n.text("Light Mode")
        case .system: return L10n.text("System Default")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

/// A launch page can be requested by the splash warmup and the visible feed at
/// once. Canceling one consumer must not cancel the other's request.
actor LaunchPageCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, Error>
        var consumers: Set<UUID>
    }
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private var flights: [Key: Flight] = [:]

    func value(for key: Key, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value = values[key] { return value }
        let consumer = UUID(), task: Task<Value, Error>
        if var flight = flights[key] {
            flight.consumers.insert(consumer); flights[key] = flight; task = flight.task
        } else {
            let token = UUID()
            task = Task {
                let value = try await load()
                try Task.checkCancellation()
                self.store(value, key: key, token: token)
                return value
            }
            flights[key] = Flight(id: token, task: task, consumers: [consumer])
        }
        return try await withTaskCancellationHandler {
            defer { release(key, consumer: consumer) }
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { Task { await self.release(key, consumer: consumer) } }
    }

    private func store(_ value: Value, key: Key, token: UUID) {
        guard flights[key]?.id == token else { return }
        values[key] = value
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 8 { values.removeValue(forKey: order.removeFirst()) }
    }
    private func release(_ key: Key, consumer: UUID) {
        guard var flight = flights[key], flight.consumers.remove(consumer) != nil else { return }
        if flight.consumers.isEmpty { flights.removeValue(forKey: key); flight.task.cancel() }
        else { flights[key] = flight }
    }
    func consumerCount(for key: Key) -> Int { flights[key]?.consumers.count ?? 0 }
    func invalidate(_ key: Key) {
        values.removeValue(forKey: key); order.removeAll { $0 == key }
        flights.removeValue(forKey: key)?.task.cancel()
    }
}

actor LaunchWorkSlots {
    private struct Waiter { let id: UUID; let priority: TaskPriority; let continuation: CheckedContinuation<Void, Error> }
    private var running = 0
    private var waiting: [Waiter] = []
    func perform<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if running < 2 { running += 1; continuation.resume() }
                else { waiting.append(Waiter(id: id, priority: Task.currentPriority, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        guard let index = waiting.indices.max(by: { waiting[$0].priority < waiting[$1].priority }) else { running -= 1; return }
        waiting.remove(at: index).continuation.resume()
    }
}

/// Process-local preparation of one list page and its thumbnail pixels. It never
/// advances a feed cursor or downloads reader originals.
@MainActor
final class LaunchFeedWarmup {
    struct MangaKey: Hashable, Sendable { let site: String; let query: GalleryQuery }
    struct BooruKey: Hashable, Sendable { let server: BooruServer; let query: String; let sort: BooruSort }
    private enum Job: Hashable, Sendable { case manga(MangaKey), booru(BooruKey) }
    private enum Prepared: Sendable { case manga(Job, [Int64]), booru(Job, BooruServer, [BooruPost]) }
    private enum Cover: Sendable { case manga(Int64), booru(URL, BooruServer) }
    let manga: any ContentProviding
    let booru: any BooruProviding
    let images: PageImageStore
    let mangaPages = LaunchPageCache<MangaKey, GalleryBatch>()
    let booruPages = LaunchPageCache<BooruKey, BooruBatch>()
    private let thumbnail: @Sendable (URL, BooruServer) async throws -> Void
    private let slots = LaunchWorkSlots()
    private var completed = Set<Job>()
    private var consumed = Set<Job>()
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init(manga: any ContentProviding, booru: any BooruProviding, images: PageImageStore? = nil,
         thumbnail: @escaping @Sendable (URL, BooruServer) async throws -> Void = { url, server in
             _ = try await BooruThumbnailCache.shared.image(url: url, server: server)
         }) {
        self.manga = manga; self.booru = booru
        self.images = images ?? PageImageStore(source: manga)
        self.thumbnail = thumbnail
    }

    func mangaPage(query: GalleryQuery, site: String, initialConsumer: Bool = false) async throws -> GalleryBatch {
        let source = manga, slots = slots
        let key = MangaKey(site: site, query: query)
        if initialConsumer, consumed.contains(.manga(key)) { return try await source.list(query, offset: 0, count: 24) }
        let page = try await mangaPages.value(for: key) {
            try await slots.perform { try await source.list(query, offset: 0, count: 24) }
        }
        try Task.checkCancellation()
        return page
    }
    func booruPage(server: BooruServer, query: String, sort: BooruSort, initialConsumer: Bool = false) async throws -> BooruBatch {
        let source = booru, slots = slots
        let key = BooruKey(server: server, query: query, sort: sort)
        if initialConsumer, consumed.contains(.booru(key)) {
            return try await BooruSortValidation.posts(source: source, server: server, query: query, page: 0, sort: sort)
        }
        let page = try await booruPages.value(for: key) {
            try await slots.perform {
                try await BooruSortValidation.posts(source: source, server: server, query: query, page: 0, sort: sort)
            }
        }
        try Task.checkCancellation()
        return page
    }
    // A canceled UI task can discard a result after its await returns. Consume
    // the handoff only when the feed actually publishes that first page.
    func didPublishManga(query: GalleryQuery, site: String) {
        consumed.insert(.manga(MangaKey(site: site, query: query)))
    }
    func didPublishBooru(server: BooruServer, query: String, sort: BooruSort) {
        consumed.insert(.booru(BooruKey(server: server, query: query, sort: sort)))
    }
    func invalidateManga(query: GalleryQuery, site: String) async {
        let key = MangaKey(site: site, query: query)
        consumed.insert(.manga(key)); completed.insert(.manga(key))
        await mangaPages.invalidate(key)
    }
    func invalidateBooru(server: BooruServer, query: String, sort: BooruSort) async {
        let key = BooruKey(server: server, query: query, sort: sort)
        consumed.insert(.booru(key)); completed.insert(.booru(key))
        await booruPages.invalidate(key)
    }

    func run(mangaQuery: GalleryQuery?, site: String, servers: [BooruServer], preferredMode: AppMode = .manga, booruQuery: String = "") async {
        guard !Task.isCancelled else { return }
        let previous = work, token = UUID()
        previous?.cancel(); generation = token
        let task = Task(priority: .utility) { [weak self] in
            // An in-flight shared thumbnail may still serve a visible cell. Its
            // worker retains the slot until it finishes, including after cancel.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var jobs = mangaQuery.map { [Job.manga(MangaKey(site: site, query: $0))] } ?? []
            jobs += servers.map { .booru(BooruKey(server: $0, query: booruQuery, sort: .latest)) }
            if preferredMode == .booru, mangaQuery != nil, !servers.isEmpty { jobs.swapAt(0, 1) }
            jobs.removeAll { self.completed.contains($0) }
            var prepared: [Prepared] = []
            await withTaskGroup(of: Prepared?.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<2 { if let job = iterator.next() { group.addTask { await self.prepareList(job) } } }
                while let result = await group.next() {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let result { prepared.append(result) }
                    if let job = iterator.next() { group.addTask { await self.prepareList(job) } }
                }
            }
            guard !Task.isCancelled else { return }
            var covers: [Cover] = [], posts: [(BooruPost, BooruServer)] = []
            for page in prepared {
                switch page {
                case .manga(_, let ids): covers += ids.prefix(10).map(Cover.manga)
                case .booru(_, let server, let batch): posts += batch.map { ($0, server) }
                }
            }
            // Twenty previews in total, even with multiple selected servers.
            // Keep the native list page sizes so pagination cannot skip IDs.
            posts.sort { $0.0.postID == $1.0.postID ? $0.0.id < $1.0.id : $0.0.postID > $1.0.postID }
            let booruCovers: [Cover] = posts.prefix(20).compactMap { post, server in
                (post.previewURL ?? post.sampleURL).map { .booru($0, server) }
            }
            covers = preferredMode == .booru ? booruCovers + covers : covers + booruCovers
            await withTaskGroup(of: Void.self) { group in
                var iterator = covers.makeIterator()
                for _ in 0..<2 { if let cover = iterator.next() { group.addTask { await self.prepareCover(cover) } } }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let cover = iterator.next() { group.addTask { await self.prepareCover(cover) } }
                }
            }
            guard !Task.isCancelled else { return }
            for page in prepared {
                switch page { case .manga(let job, _), .booru(let job, _, _): completed.insert(job) }
            }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == token { work = nil }
    }

    private func prepareList(_ job: Job) async -> Prepared? {
        do {
            try Task.checkCancellation()
            switch job {
            case .manga(let key):
                let page = try await mangaPage(query: key.query, site: key.site)
                return .manga(job, page.ids)
            case .booru(let key):
                let page = try await booruPage(server: key.server, query: key.query, sort: key.sort)
                return .booru(job, key.server, page.posts)
            }
        } catch { return nil }
    }
    private func prepareCover(_ cover: Cover) async {
        let manga = manga, images = images, thumbnail = thumbnail
        try? await slots.perform {
            switch cover {
            case .manga(let id):
                let gallery = try await manga.gallery(id)
                try Task.checkCancellation()
                if let page = gallery.pages.first { _ = try await images.load(page, galleryID: id, thumbnail: true) }
            case .booru(let url, let server): try await thumbnail(url, server)
            }
        }
    }
}

@Observable
public final class AppEnvironment: @unchecked Sendable {
    public let database: AppDatabase
    public let coverQueueActor: CoverQueueActor
    public let coverQueueState: CoverQueueState
    public let mangaViewerImporter: MangaViewerImportService
    let booru: BooruStore
    let modeSwitchMotion = AppModeSwitchMotion()
    @ObservationIgnored var removedBookmarks: [Int64: RemovedBookmark] = [:]
    /// The folder each work saved this session went to, which Change Folder moves it out of.
    @ObservationIgnored var savedFolders: [Int64: Int64] = [:]

    private var selectedMode: AppMode
    var mode: AppMode {
        get { selectedMode }
        set {
            selectedMode = booruSafeMode ? .booru : newValue
            browserPreferences.set(selectedMode.rawValue, forKey: "content_mode")
            // Observation notifies before storing, and SwiftUI can reevaluate the root
            // inside that notification. Notify again so it cannot keep the old mode.
            withMutation(keyPath: \.selectedMode) {}
        }
    }
    private(set) var booruSearchRevision = 0
    var booruSafeMode: Bool {
        didSet {
            guard booruSafeMode != oldValue else { return }
            browserPreferences.set(booruSafeMode, forKey: "booru.safeMode")
            booru.safeRating = booruSafeMode ? booruSafeRating : nil
            if booruSafeMode {
                mode = .booru
                // Turning it on goes straight to Safebooru, whose images are all ages.
                booru.perform { try booru.selectSafebooru() }
            }
            booruSearchRevision += 1
        }
    }
    var booruSafeRating: BooruSafeRating {
        didSet {
            guard booruSafeRating != oldValue else { return }
            browserPreferences.set(booruSafeRating.rawValue, forKey: "booru.safeRating")
            booru.safeRating = booruSafeMode ? booruSafeRating : nil
            booruSearchRevision += 1
        }
    }
    /// Safe Mode adds its rating tag only when a server other than Safebooru is chosen; Safebooru
    /// has no rating tags to search by, and every image there is all ages.
    func booruQuery(_ query: String) -> String {
        booruSafeMode && booru.selectedServers.contains(where: { !$0.isSafebooru }) ? booruSafeRating.applyingDefault(to: query) : query
    }
    private(set) var discordInvitationVisible = false
    @ObservationIgnored private var discordInvitationRecorded = false
    // Separate the corrected cadence from the earlier prematurely consumed display date.
    private let discordInvitationNextKey = "discord.invitation.nextPresentation"
    func presentDiscordInvitationIfDue(at now: Date = .now) {
        guard !discordInvitationVisible,
              browserPreferences.double(forKey: discordInvitationNextKey) <= now.timeIntervalSince1970 else { return }
        discordInvitationVisible = true
        discordInvitationRecorded = false
    }
    func recordDiscordInvitationDisplay(at now: Date = .now) {
        guard discordInvitationVisible, !discordInvitationRecorded else { return }
        discordInvitationRecorded = true
        browserPreferences.set(now.addingTimeInterval(3 * 86400).timeIntervalSince1970, forKey: discordInvitationNextKey)
    }
    func dismissDiscordInvitation(at now: Date = .now) {
        discordInvitationVisible = false
        browserPreferences.set(now.addingTimeInterval(7 * 86400).timeIntervalSince1970, forKey: discordInvitationNextKey)
    }
    private(set) var modeSwitchHintPending: Bool
    func acknowledgeModeSwitch() {
        guard modeSwitchHintPending else { return }
        modeSwitchHintPending = false
        browserPreferences.set(true, forKey: "mode_switch.discovered")
    }
    var appLanguage: String {
        didSet {
            browserPreferences.set(appLanguage, forKey: "app.language")
            L10n.appLanguage = appLanguage
        }
    }

    private var mangaTheme: AppTheme
    private var booruTheme: AppTheme
    private var mangaColumns: Int
    private var booruColumns: Int
    private var mangaPreviewColumnCount: Int
    private var mangaPreviewRowCount: Int
    private var mangaRemovesGridPadding: Bool
    private var booruRemovesGridPadding: Bool
    var showsMangaTitles: Bool { didSet { browserPreferences.set(showsMangaTitles, forKey: "manga.grid.showTitles") } }
    var showsMangaArtists: Bool { didSet { browserPreferences.set(showsMangaArtists, forKey: "manga.grid.showArtists") } }
    var showsMangaCategories: Bool { didSet { browserPreferences.set(showsMangaCategories, forKey: "manga.grid.showCategories") } }
    /// Signed in to the connected website, for sites that use accounts.
    var siteAccountSignedIn = SiteAccount.isSignedIn
    var syncsAccountFavorites: Bool { didSet { browserPreferences.set(syncsAccountFavorites, forKey: "manga.syncAccountFavorites") } }
    private var mangaFolderColumns: Int
    private var booruFolderColumns: Int

    public var appTheme: AppTheme {
        get { mode == .manga ? mangaTheme : booruTheme }
        set {
            if mode == .manga { mangaTheme = newValue } else { booruTheme = newValue }
            browserPreferences.set(newValue.rawValue, forKey: mode == .manga ? "app_theme" : "booru.app_theme")
        }
    }

    func gridColumns(for mode: AppMode) -> Int { mode == .manga ? mangaColumns : booruColumns }
    func folderColumns(for mode: AppMode) -> Int { mode == .manga ? mangaFolderColumns : booruFolderColumns }
    func removesGridPadding(for mode: AppMode) -> Bool { mode == .manga ? mangaRemovesGridPadding : booruRemovesGridPadding }
    var removesGridPadding: Bool {
        get { removesGridPadding(for: mode) }
        set {
            if mode == .manga { mangaRemovesGridPadding = newValue } else { booruRemovesGridPadding = newValue }
            browserPreferences.set(newValue, forKey: mode == .manga ? "manga.grid.noPadding" : "booru.grid.noPadding")
        }
    }

    public var gridColumns: Int {
        get { mode == .manga ? mangaColumns : booruColumns }
        set {
            let value = min(5, max(0, newValue))
            if mode == .manga { mangaColumns = value } else { booruColumns = value }
            browserPreferences.set(value, forKey: mode == .manga ? "grid_columns" : "booru.grid_columns")
        }
    }

    /// Zero follows twice the resolved artwork grid column count.
    var mangaPreviewColumns: Int {
        get { mangaPreviewColumnCount }
        set {
            let value = min(10, max(0, newValue))
            mangaPreviewColumnCount = value
            browserPreferences.set(value, forKey: "manga.preview.columns")
        }
    }

    var mangaPreviewRows: Int {
        get { mangaPreviewRowCount }
        set {
            mangaPreviewRowCount = min(10, max(1, newValue))
            browserPreferences.set(mangaPreviewRowCount, forKey: "manga.preview.rows")
        }
    }

    public var folderColumns: Int {
        get { mode == .manga ? mangaFolderColumns : booruFolderColumns }
        set {
            let value = min(5, max(0, newValue))
            if mode == .manga { mangaFolderColumns = value } else { booruFolderColumns = value }
            browserPreferences.set(value, forKey: mode == .manga ? "folder_columns" : "booru.folder_columns")
        }
    }

    var allowsMangaLanguageExceptions: Bool {
        didSet { browserPreferences.set(allowsMangaLanguageExceptions, forKey: "manga.languageExceptions") }
    }

    /// The comics websites Explore and its searches list together, picked as image mode picks
    /// its servers. Nil until someone picks.
    private var chosenComicSites: [String]? {
        didSet { browserPreferences.set(chosenComicSites, forKey: "manga.exploreSites") }
    }

    /// The connected websites lists show. One picked website, or none picked yet, is the checked
    /// one, so switching websites elsewhere still changes what is listed; with several picked,
    /// the checked one is always among them. A single connected website is always listed.
    var listedComicSites: [String] { Self.listedSites(comicSites, active: mangaSiteAddress, chosen: chosenComicSites) }

    static func listedSites(_ sites: [String], active: String, chosen: [String]?) -> [String] {
        guard sites.count > 1 else { return sites.isEmpty && !active.isEmpty ? [active] : sites }
        guard let chosen, chosen.count != 1 else { return sites.filter { $0 == active } }
        if chosen.isEmpty { return [] }
        return sites.filter { chosen.contains($0) || $0 == active }
    }

    /// The websites picked after tapping `site` in the menu, and the one to check, if it changes.
    static func toggling(_ site: String, listed: [String], sites: [String], active: String) -> (chosen: [String], check: String?) {
        var listed = listed
        if listed.contains(site) { listed.removeAll { $0 == site } } else { listed.append(site) }
        let chosen = sites.filter(listed.contains)
        return (chosen, chosen.first.flatMap { chosen.contains(active) ? nil : $0 })
    }

    /// Whether lists mix several websites.
    var listsSeveralComicSites: Bool { listedComicSites.count > 1 }

    /// Adds or removes a website from the listed ones. Removing the checked website checks
    /// another listed one, so reading and accounts follow what is shown.
    @MainActor func toggleListedComicSite(_ site: String) {
        let next = Self.toggling(site, listed: listedComicSites, sites: comicSites, active: mangaSiteAddress)
        chosenComicSites = next.chosen
        if let check = next.check { switchComicsSite(to: check) }
    }

    var defaultTags: String {
        didSet { browserPreferences.set(defaultTags, forKey: "manga.defaultTags") }
    }
    var defaultExcludedTags: String {
        didSet { browserPreferences.set(defaultExcludedTags, forKey: "manga.defaultExcludedTags") }
    }
    /// The category the main comics feed is narrowed to, empty for all.
    var mangaBrowseCategory: String {
        didSet { browserPreferences.set(mangaBrowseCategory, forKey: "manga.browseCategory") }
    }
    var hiddenMangaGalleryIDs: Set<Int64> {
        didSet { browserPreferences.set(hiddenMangaGalleryIDs.sorted().map(String.init), forKey: "manga.hiddenGalleryIDs") }
    }

    func setMangaGalleryHidden(_ id: Int64, hidden: Bool) {
        guard id > 0 else { return }
        if hidden { hiddenMangaGalleryIDs.insert(id) } else { hiddenMangaGalleryIDs.remove(id) }
    }

    func blockMangaArtist(_ name: String) {
        let artist = name.split(whereSeparator: \.isWhitespace).joined(separator: "_")
        guard !artist.isEmpty else { return }
        let rule = "artist:" + artist
        let existing = defaultExcludedTags.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !existing.contains(where: { $0.lowercased() == rule.lowercased() || $0.lowercased() == "-" + rule.lowercased() }) else { return }
        defaultExcludedTags = (existing + [rule]).joined(separator: " ")
    }

    @MainActor var taste: TasteController {
        if let tasteStorage { return tasteStorage }
        let controller = TasteController(library: database, images: booru)
        tasteStorage = controller
        return controller
    }
    @ObservationIgnored private var tasteStorage: TasteController?
    /// Up Next for comics.
    @MainActor var readingQueue: ReadingQueue {
        if let readingQueueStorage { return readingQueueStorage }
        let queue = ReadingQueue(defaults: browserPreferences)
        readingQueueStorage = queue
        return queue
    }
    @ObservationIgnored private var readingQueueStorage: ReadingQueue?
    /// Comics opened in the viewer lately.
    @MainActor var recentWorks: RecentWorks {
        if let recentWorksStorage { return recentWorksStorage }
        let recents = RecentWorks(defaults: browserPreferences)
        recentWorksStorage = recents
        return recents
    }
    @ObservationIgnored private var recentWorksStorage: RecentWorks?
    /// Images opened in image mode's viewer lately.
    @MainActor var recentImages: RecentImages {
        if let recentImagesStorage { return recentImagesStorage }
        let recents = RecentImages(defaults: ReaderPreferences.booruDefaults)
        recentImagesStorage = recents
        return recents
    }
    @ObservationIgnored private var recentImagesStorage: RecentImages?
    @ObservationIgnored private var coverQueueTask: Task<Void, Never>?
    @ObservationIgnored private var coverQueueGeneration = UUID()
    @ObservationIgnored private var coverQueueActive = true
    @ObservationIgnored private var resumeCoverQueue = false
    @ObservationIgnored private var coverQueueRequested = false

    @MainActor var launchFeeds: LaunchFeedWarmup {
        if let launchFeedsStorage { return launchFeedsStorage }
        let manga: any ContentProviding
        let images: any BooruProviding
        #if DEBUG
        manga = ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? ContentUITestSupport.source : MangaContentSource.shared
        images = BooruUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? BooruUITestSupport.source : BooruClient.shared
        #else
        manga = MangaContentSource.shared; images = BooruClient.shared
        #endif
        let value = LaunchFeedWarmup(manga: manga, booru: images)
        launchFeedsStorage = value
        return value
    }
    @ObservationIgnored private var launchFeedsStorage: LaunchFeedWarmup?

    @MainActor func resetModeSettings(booru: Bool) {
        if booru {
            booruTheme = .dark; booruColumns = 0; booruFolderColumns = 0; booruRemovesGridPadding = false
            booruSafeMode = false; booruSafeRating = .general
        } else {
            mangaTheme = .dark; mangaColumns = 0; mangaFolderColumns = 0; mangaRemovesGridPadding = false
            mangaPreviewColumns = 0; mangaPreviewRows = 5; showsMangaTitles = true; showsMangaArtists = true; showsMangaCategories = false
            allowsMangaLanguageExceptions = false; defaultTags = ""; defaultExcludedTags = ""; useEmbeddedBrowser = false
        }
        browserPreferences.set(AppTheme.dark.rawValue, forKey: booru ? "booru.app_theme" : "app_theme")
        for key in booru ? ["booru.grid_columns", "booru.folder_columns", "booru.grid.noPadding"] : ["grid_columns", "folder_columns", "manga.grid.noPadding", MangaThumbnailOpening.preferenceKey] { browserPreferences.removeObject(forKey: key) }
        let preferences = booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults
        for key in ["search.retentionDays", booru ? "booru.rememberHistory" : "search.rememberHistory", "booru.fitThumbnails", "booru.useEmbeddedBrowser"] { preferences.removeObject(forKey: key) }
        browserPreferences.removeObject(forKey: "app.resumeAnimation")
        ReaderPreferenceReset.reset(booru: booru)
    }

    var launchMangaQuery: GalleryQuery {
        var query = GalleryQuery(language: L10n.contentLanguage).filtered(to: mangaBrowseCategory).applyingDefaults(tags: defaultTags, excluded: defaultExcludedTags)
        query.allowsLanguageExceptions = allowsMangaLanguageExceptions
        return query
    }

    @MainActor var sync: LibraryCloudSync { syncStorage ?? makeSync() }
    @ObservationIgnored private var syncStorage: LibraryCloudSync?
    @MainActor private func makeSync() -> LibraryCloudSync {
        let value = LibraryCloudSync(defaults: browserPreferences); syncStorage = value; return value
    }
    @MainActor func reloadSyncedPreferences() {
        // Assign only changed values: materializing absent defaults would upload them
        // as fresh edits and overwrite another device's preferences on the next pass.
        let language = browserPreferences.string(forKey: "app.language") ?? "system"
        if appLanguage != language { appLanguage = language }
        let comicsTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        if mangaTheme != comicsTheme { mangaTheme = comicsTheme }
        let imageTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        if booruTheme != imageTheme { booruTheme = imageTheme }
        let tags = browserPreferences.string(forKey: "manga.defaultTags") ?? ""
        if defaultTags != tags { defaultTags = tags }
        let exclusions = browserPreferences.string(forKey: "manga.defaultExcludedTags") ?? ""
        if defaultExcludedTags != exclusions { defaultExcludedTags = exclusions }
        let hidden = Set((browserPreferences.stringArray(forKey: "manga.hiddenGalleryIDs") ?? []).compactMap(Int64.init))
        if hiddenMangaGalleryIDs != hidden { hiddenMangaGalleryIDs = hidden }
        let verified = browserPreferences.bool(forKey: "site_verified") && Self.supportsComicsAddress(browserPreferences.string(forKey: "manga.site_address") ?? "")
        if isSiteVerified != verified { isSiteVerified = verified }
        recentWorksStorage?.reload()
        recentImagesStorage?.reload()
        let siteAddress = browserPreferences.string(forKey: "manga.site_address") ?? ""
        if mangaSiteAddress != siteAddress { mangaSiteAddress = siteAddress }
    }
    private let browserPreferences: UserDefaults

    public var mangaSiteAddress: String {
        didSet {
            // A site connected before the list existed joins it before another takes its place.
            ComicSites.add(oldValue)
            ComicSites.switchSite(from: oldValue, to: mangaSiteAddress)
            browserPreferences.set(mangaSiteAddress, forKey: "manga.site_address")
            if ContentPreferences.isIsolated {
                MangaUrls.preferences.set(mangaSiteAddress, forKey: "manga.site_address")
            }
            ComicSites.add(mangaSiteAddress)
            comicSitesRevision += 1
        }
    }

    /// Changes when a comics site is added, removed or switched, so lists of sites redraw.
    public private(set) var comicSitesRevision = 0
    public var comicSites: [String] { _ = comicSitesRevision; return ComicSites.all }

    /// Makes another connected site the active one.
    @MainActor public func switchComicsSite(to site: String) {
        guard site != mangaSiteAddress, ComicSites.all.contains(site) else { return }
        isSiteVerified = true
        mangaSiteAddress = site
        ContentBrowserTransport.reset()
    }

    /// Forgets a site; forgetting the active one moves to the next, or disconnects.
    @MainActor public func removeComicsSite(_ site: String) {
        let remaining = ComicSites.all.filter { $0 != site }
        if site == mangaSiteAddress {
            if let next = remaining.first { switchComicsSite(to: next) }
            else { isSiteVerified = false; mangaSiteAddress = "" }
        }
        ComicSites.remove(site)
        comicSitesRevision += 1
    }

    public var useEmbeddedBrowser: Bool {
        didSet {
            browserPreferences.set(useEmbeddedBrowser, forKey: "use_embedded_browser")
        }
    }

    public var isOnboardingCompleted: Bool {
        didSet {
            browserPreferences.set(isOnboardingCompleted, forKey: "onboarding_completed")
        }
    }

    public var isSiteVerified: Bool {
        didSet {
            browserPreferences.set(isSiteVerified, forKey: "site_verified")
        }
    }

    public convenience init(database: AppDatabase, browserPreferences: UserDefaults = .standard) {
        self.init(database: database, browserPreferences: browserPreferences, booru: try! BooruStore())
    }

    init(database: AppDatabase, browserPreferences: UserDefaults = .standard, booru: BooruStore, coverQueue: CoverQueueActor? = nil) {
        self.browserPreferences = browserPreferences
        let discoveredSwitch = browserPreferences.object(forKey: "mode_switch.discovered") as? Bool
            ?? browserPreferences.bool(forKey: "onboarding_completed")
        self.modeSwitchHintPending = !discoveredSwitch
        // Remember a genuinely new install before onboarding is completed.
        browserPreferences.set(discoveredSwitch, forKey: "mode_switch.discovered")
        self.appLanguage = browserPreferences.string(forKey: "app.language") ?? "system"
        L10n.appLanguage = browserPreferences.string(forKey: "app.language") ?? "system"
        self.booru = booru
        let safeMode = browserPreferences.bool(forKey: "booru.safeMode")
        self.booruSafeMode = safeMode
        let safeRating = BooruSafeRating(rawValue: browserPreferences.string(forKey: "booru.safeRating") ?? "") ?? .general
        self.booruSafeRating = safeRating
        booru.safeRating = safeMode ? safeRating : nil
        self.selectedMode = safeMode ? .booru : AppMode(rawValue: browserPreferences.string(forKey: "content_mode") ?? "") ?? .booru
        self.database = database
        self.coverQueueActor = coverQueue ?? CoverQueueActor(database: database)
        self.coverQueueState = CoverQueueState()
        self.mangaViewerImporter = MangaViewerImportService(appDb: database)

        self.mangaTheme = AppTheme(rawValue: browserPreferences.string(forKey: "app_theme") ?? "") ?? .dark
        self.booruTheme = AppTheme(rawValue: browserPreferences.string(forKey: "booru.app_theme") ?? "") ?? .dark
        let mangaColumns = browserPreferences.integer(forKey: "grid_columns")
        let booruColumns = browserPreferences.integer(forKey: "booru.grid_columns")
        self.mangaColumns = min(5, max(0, mangaColumns))
        self.booruColumns = min(5, max(0, booruColumns))
        self.mangaPreviewColumnCount = min(10, max(0, browserPreferences.integer(forKey: "manga.preview.columns")))
        self.mangaPreviewRowCount = min(10, max(1, browserPreferences.object(forKey: "manga.preview.rows") as? Int ?? 5))
        self.mangaRemovesGridPadding = browserPreferences.bool(forKey: "manga.grid.noPadding")
        self.booruRemovesGridPadding = browserPreferences.bool(forKey: "booru.grid.noPadding")
        self.showsMangaTitles = browserPreferences.object(forKey: "manga.grid.showTitles") as? Bool ?? true
        self.showsMangaArtists = browserPreferences.object(forKey: "manga.grid.showArtists") as? Bool ?? true
        self.showsMangaCategories = browserPreferences.bool(forKey: "manga.grid.showCategories")
        self.syncsAccountFavorites = browserPreferences.bool(forKey: "manga.syncAccountFavorites")
        self.mangaFolderColumns = min(5, max(0, browserPreferences.integer(forKey: "folder_columns")))
        self.booruFolderColumns = min(5, max(0, browserPreferences.integer(forKey: "booru.folder_columns")))
        self.allowsMangaLanguageExceptions = browserPreferences.bool(forKey: "manga.languageExceptions")
        self.chosenComicSites = browserPreferences.stringArray(forKey: "manga.exploreSites")
        self.defaultTags = browserPreferences.string(forKey: "manga.defaultTags") ?? ""
        self.defaultExcludedTags = browserPreferences.string(forKey: "manga.defaultExcludedTags") ?? ""
        self.mangaBrowseCategory = browserPreferences.string(forKey: "manga.browseCategory") ?? ""
        self.hiddenMangaGalleryIDs = Set((browserPreferences.stringArray(forKey: "manga.hiddenGalleryIDs") ?? []).compactMap(Int64.init))

        // New opt-in fallback; the old preference selected native UI versus external Safari.
        self.useEmbeddedBrowser = browserPreferences.bool(forKey: "use_embedded_browser")

        self.isOnboardingCompleted = browserPreferences.bool(forKey: "onboarding_completed")
        self.isSiteVerified = browserPreferences.bool(forKey: "site_verified") && Self.supportsComicsAddress(browserPreferences.string(forKey: "manga.site_address") ?? "")
        self.mangaSiteAddress = browserPreferences.string(forKey: "manga.site_address") ?? ""
    }

    static func supportsComicsAddress(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard let url = URLComponents(string: value.contains("://") ? value : "https://" + value) else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard url.user == nil && url.password == nil else { return false }
        guard host.contains(".") || host == "localhost" else { return false }
        guard !host.hasPrefix(".") && !host.hasSuffix(".") else { return false }
        if !ContentPreferences.isIsolated && ["example", "test", "invalid"].contains(host.split(separator: ".").last.map(String.init) ?? "") { return false }
        if let scheme = url.scheme?.lowercased(), scheme != "https" && scheme != "http" {
            return false
        }
        return true
    }

    static func normalizedComicsAddress(_ input: String) -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: raw.contains("://") ? raw : "https://" + raw),
              let host = url.host?.lowercased() else {
            return raw.lowercased()
        }
        // As for image servers, a site is the same with or without `www.`, and its other
        // hosts are named from the bare one.
        return BooruServer.bareHost(host)
    }

    @discardableResult
    public func verifySite(input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isValid = Self.supportsComicsAddress(cleaned)
        if isValid {
            self.isSiteVerified = true
            let saved = Self.normalizedComicsAddress(cleaned)
            self.mangaSiteAddress = saved
        }
        return isValid
    }

    public static func standard() -> AppEnvironment {
        do {
            let db = try AppDatabase.open()
            return AppEnvironment(database: db, booru: try BooruStore.open())
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    public static func preview() -> AppEnvironment {
        let db = try! AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "work.nextline.tegnal.preview-browser")!
        defaults.removePersistentDomain(forName: "work.nextline.tegnal.preview-browser")
        return AppEnvironment(database: db, browserPreferences: defaults)
    }

    @MainActor public func startCoverQueue() {
        guard coverQueueActive, CoverQueuePolicy.allowsBackfill else { resumeCoverQueue = true; return }
        if let task = coverQueueTask, !task.isCancelled {
            coverQueueRequested = true
            return
        }
        let previous = coverQueueTask, token = UUID()
        coverQueueGeneration = token
        coverQueueTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            defer { if self.coverQueueGeneration == token { self.coverQueueTask = nil } }
            repeat {
                coverQueueRequested = false
                await coverQueueActor.start(state: coverQueueState, downloadsEnabled: isSiteVerified)
            } while coverQueueRequested && !Task.isCancelled && coverQueueActive && CoverQueuePolicy.allowsBackfill
            if !CoverQueuePolicy.allowsBackfill { resumeCoverQueue = true }
        }
    }

    /// A finished sign-in changes what the site shows, so its protocol is read again.
    @MainActor func siteSignInFinished() {
        siteAccountSignedIn = SiteAccount.isSignedIn
        MangaUrls.resetResolvedBackend()
        ContentBrowserTransport.reset()
    }

    @MainActor func signOutOfSite() {
        SiteAccount.signOut()
        siteAccountSignedIn = false
        syncsAccountFavorites = false
        MangaUrls.resetResolvedBackend()
        ContentBrowserTransport.reset()
    }

    /// Bookmarks every account favorite not already saved, into the default folder.
    @MainActor func importAccountFavorites() async throws -> Int {
        let folder = try database.defaultSaveFolder().id
        var next: String?, added = 0, pages = 0
        repeat {
            let page = try await MangaContentSource.shared.accountFavorites(after: next)
            try Task.checkCancellation()
            for id in page.ids where try database.getWork(galleryId: id, site: ComicSites.active) == nil {
                let work = MangaContentSource.shared.cachedPreview(id)
                _ = try database.upsertWork(galleryId: id, folderId: folder, title: work?.title, artists: work?.artists.joined(separator: ", "),
                                            language: work?.language, type: work?.type, tags: work?.tags.joined(separator: ", "), metadataSource: "remote", site: ComicSites.active)
                added += 1
            }
            next = page.next
            pages += 1
        } while next != nil && pages < 500
        if added > 0 { startCoverQueue() }
        return added
    }

    /// Mirrors a bookmark change to the account's favorites when that is turned on.
    @MainActor func syncAccountFavorite(_ id: Int64, saved: Bool) {
        guard syncsAccountFavorites, siteAccountSignedIn, MangaUrls.hasResolvedBackend, MangaUrls.backend == .keyed else { return }
        Task { try? await MangaContentSource.shared.setAccountFavorite(id, saved: saved) }
    }

    /// Fetches every saved work's information again through the background queue.
    @MainActor func refreshSavedWorkInformation() {
        Task {
            _ = try? await coverQueueActor.queueRefresh()
            startCoverQueue()
        }
    }

    @MainActor func setCoverQueueActive(_ active: Bool) {
        let allowed = active && CoverQueuePolicy.allowsBackfill
        guard coverQueueActive != allowed else { return }
        coverQueueActive = allowed
        if !allowed {
            resumeCoverQueue = resumeCoverQueue || (coverQueueTask != nil && !coverQueueState.isPaused)
            coverQueueTask?.cancel()
        } else if resumeCoverQueue {
            resumeCoverQueue = false
            startCoverQueue()
        }
    }
}
