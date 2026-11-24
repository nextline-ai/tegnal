import Foundation
import SwiftUI
import GRDB

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
    /// Each image server's signed-in account and its favorites sync.
    @ObservationIgnored lazy var booruAccounts = BooruAccountSync(store: booru)
    let modeSwitchMotion = AppModeSwitchMotion()
    @ObservationIgnored var removedBookmarks: [Int64: RemovedBookmark] = [:]
    /// The folder each work saved this session went to, which Change Folder moves it out of.
    @ObservationIgnored var savedFolders: [Int64: Int64] = [:]

    private var selectedMode: AppMode
    var mode: AppMode {
        get { selectedMode }
        set {
            selectedMode = newValue
            AddonRuntime.shared.displayedMode = AddonMode(newValue)
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
            // Saved and Explore keep to Safebooru, whose images are all ages, in both modes: Comics
            // Mode browses its pools. Turning it off chooses the servers chosen before again.
            if booruSafeMode { booru.perform { try booru.enterSafeMode() } }
            else { booru.perform { try booru.leaveSafeMode() } }
            booruSearchRevision += 1
        }
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
    var siteAccountSignedIn = SiteAccount.isSignedIn(host: MangaUrls.configuredHost)
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
    /// The tags every comics search adds: the learner's own, then those of add-ons that are on.
    /// Add-on tags are never written into `defaultTags`, so turning an add-on off takes them away again.
    var searchDefaultTags: String { Self.joining(defaultTags, AddonRuntime.shared.effects.comicsInclude) }
    var searchExcludedTags: String { Self.joining(defaultExcludedTags, AddonRuntime.shared.effects.comicsExclude) }
    private static func joining(_ own: String, _ added: [String]) -> String {
        added.isEmpty ? own : ([own] + added).filter { !$0.isEmpty }.joined(separator: " ")
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
        let artist = Self.excludedTagRule(name)
        guard !artist.isEmpty, !excludesMangaTag("artist:" + artist) else { return }
        toggleExcludedMangaTag("artist:" + artist)
    }

    /// Whether every comics search leaves out works with this tag, such as `female:big breasts` or `artist:name`.
    func excludesMangaTag(_ tag: String) -> Bool {
        let rule = Self.excludedTagRule(tag)
        return !rule.isEmpty && defaultExcludedTags.split(whereSeparator: \.isWhitespace).contains { Self.sameExclusion(String($0), rule) }
    }

    /// Adds the tag to Default Excluded Tags, or takes it out again. Returns whether searches now leave it out.
    @discardableResult func toggleExcludedMangaTag(_ tag: String) -> Bool {
        let rule = Self.excludedTagRule(tag)
        guard !rule.isEmpty else { return false }
        let existing = defaultExcludedTags.split(whereSeparator: \.isWhitespace).map(String.init)
        if existing.contains(where: { Self.sameExclusion($0, rule) }) {
            defaultExcludedTags = existing.filter { !Self.sameExclusion($0, rule) }.joined(separator: " ")
            return false
        }
        defaultExcludedTags = (existing + [rule]).joined(separator: " ")
        return true
    }

    /// A tag as Default Excluded Tags writes it: underscores inside, no minus sign.
    static func excludedTagRule(_ tag: String) -> String {
        tag.split(whereSeparator: \.isWhitespace).joined(separator: "_")
    }
    private static func sameExclusion(_ term: String, _ rule: String) -> Bool {
        let term = term.lowercased(), rule = rule.lowercased()
        return term == rule || term == "-" + rule
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
    /// The question about filling from a website that blocks bulk reading is on screen.
    @ObservationIgnored var asksBeforeBulkFill = false

    @MainActor var launchFeeds: LaunchFeedWarmup {
        if let launchFeedsStorage { return launchFeedsStorage }
        let manga: any ContentProviding
        let images: any BooruProviding
        #if DEBUG
        manga = ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? ContentUITestSupport.source : SiteFallbackContent.shared
        images = BooruUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? BooruUITestSupport.source : BooruClient.shared
        #else
        manga = SiteFallbackContent.shared; images = BooruClient.shared
        #endif
        let value = LaunchFeedWarmup(manga: manga, booru: images)
        launchFeedsStorage = value
        return value
    }
    @ObservationIgnored private var launchFeedsStorage: LaunchFeedWarmup?

    @MainActor func resetModeSettings(booru: Bool) {
        if booru {
            booruTheme = .dark; booruColumns = 0; booruFolderColumns = 0; booruRemovesGridPadding = false
            booruSafeMode = false
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
        var query = GalleryQuery(language: L10n.contentLanguage).filtered(to: mangaBrowseCategory).applyingDefaults(tags: searchDefaultTags, excluded: searchExcludedTags)
        query.allowsLanguageExceptions = allowsMangaLanguageExceptions
        return query
    }

    @MainActor var sync: LibraryCloudSync { syncStorage ?? makeSync() }
    @ObservationIgnored private var syncStorage: LibraryCloudSync?
    @MainActor private func makeSync() -> LibraryCloudSync {
        let value = LibraryCloudSync(defaults: browserPreferences); syncStorage = value; return value
    }
    /// Automatic backups: the list, Back Up Now, restore, export and import.
    @MainActor var backups: AutomaticBackups { backupsStorage ?? makeBackups() }
    @ObservationIgnored private var backupsStorage: AutomaticBackups?
    @MainActor private func makeBackups() -> AutomaticBackups {
        let memo = database.dbWriter, images = booru.database
        #if DEBUG
        if ContentPreferences.isIsolated {
            let value = AutomaticBackups(setup: .isolated(), databases: { .init(memo: memo, booru: images) }, cloud: nil)
            backupsStorage = value; return value
        }
        #endif
        let value = AutomaticBackups(setup: .standard(), databases: { .init(memo: memo, booru: images) }, cloud: CloudBackupVault())
        backupsStorage = value; return value
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
            let isNewSite = !mangaSiteAddress.isEmpty && !ComicSites.all.contains(mangaSiteAddress)
            // A site connected before the list existed joins it before another takes its place.
            ComicSites.add(oldValue)
            ComicSites.switchSite(from: oldValue, to: mangaSiteAddress)
            browserPreferences.set(mangaSiteAddress, forKey: "manga.site_address")
            if ContentPreferences.isIsolated {
                MangaUrls.preferences.set(mangaSiteAddress, forKey: "manga.site_address")
            }
            ComicSites.add(mangaSiteAddress)
            // Another set of websites is asked about afresh before a fill reads in bulk.
            if isNewSite { CoverFillGuard.forget() }
            comicSitesRevision += 1
            siteAccountSignedIn = SiteAccount.isSignedIn(host: MangaUrls.configuredHost)
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
        siteAccountSignedIn = SiteAccount.isSignedIn(host: MangaUrls.configuredHost)
    }

    /// Forgets a site; forgetting the active one moves to the next, or disconnects.
    /// Website priority: lists that show several websites keep the copy of a shared work from the
    /// higher one, and saved works try them in this order after the checked website.
    @MainActor public func reorderComicSites(_ order: [String]) {
        ComicSites.reorder(order)
        comicSitesRevision += 1
    }

    @MainActor public func removeComicsSite(_ site: String) {
        let remaining = ComicSites.all.filter { $0 != site }
        if site == mangaSiteAddress {
            if let next = remaining.first { switchComicsSite(to: next) }
            else { isSiteVerified = false; mangaSiteAddress = "" }
        }
        ComicSites.remove(site)
        // A removed website's account goes with it.
        SiteAccount.signOut(host: site)
        CoverFillGuard.forget()
        WorkSiteMemory.shared.forget(site: site)
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
        #if DEBUG
        // For tests and screenshots: `--addon-install=<file path>` installs an add-on file at launch, as if it had been opened.
        for path in ProcessInfo.processInfo.arguments.filter({ $0.hasPrefix("--addon-install=") }).map({ String($0.dropFirst(16)) }) {
            if let (addon, digest) = try? Addon.read(URL(fileURLWithPath: path)) { try? AddonStore(booru).install(addon, digest: digest) }
        }
        #endif
        AddonRuntime.shared.reload(booru)
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
        if safeMode {
            booru.safeMode = true
            // A backup or another device may have chosen other servers meanwhile.
            try? booru.reload()
            if booru.selectedServers.isEmpty { try? booru.selectSafebooru() }
        }
        self.selectedMode = AppMode(rawValue: browserPreferences.string(forKey: "content_mode") ?? "") ?? .booru
        AddonRuntime.shared.displayedMode = AddonMode(AppMode(rawValue: browserPreferences.string(forKey: "content_mode") ?? "") ?? .booru)
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

    /// `manual` is the fill button: it asks again even after the person said not now.
    @MainActor public func startCoverQueue(manual: Bool = false) {
        guard coverQueueActive, CoverQueuePolicy.allowsBackfill else { resumeCoverQueue = true; return }
        guard mayFillInBulk(manual: manual) else { return }
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
            let database = self.database
            repeat {
                coverQueueRequested = false
                await coverQueueActor.start(state: coverQueueState, downloadsEnabled: isSiteVerified, mayRead: {
                    CoverFillGuard.outcome(sites: ComicSites.all, pending: { (try? database.countPendingFill()) ?? 0 }, manual: false) == .run
                })
            } while coverQueueRequested && !Task.isCancelled && coverQueueActive && CoverQueuePolicy.allowsBackfill
            if !CoverQueuePolicy.allowsBackfill { resumeCoverQueue = true }
            // Works saved during the run may have stopped it to ask first.
            if !Task.isCancelled { _ = mayFillInBulk(manual: false) }
        }
    }

    /// Whether the fill may read now, asking first when every connected website blocks bulk
    /// reading and many works are waiting. Other websites, when connected, are read instead.
    @MainActor private func mayFillInBulk(manual: Bool) -> Bool {
        guard isSiteVerified else { return true }
        let database = self.database
        switch CoverFillGuard.outcome(sites: ComicSites.all, pending: { (try? database.countPendingFill()) ?? 0 }, manual: manual) {
        case .run: return true
        case .hold: return false
        case .ask(let pending, let sites):
            if !asksBeforeBulkFill { CoverFillSiteWarning.present(env: self, pending: pending, sites: sites) }
            return false
        }
    }

    /// The person's answer to filling from a website that blocks bulk reading.
    @MainActor func answerBulkFill(_ decision: CoverFillGuard.Decision, pending: Int) {
        asksBeforeBulkFill = false
        CoverFillGuard.record(decision, pending: pending)
        if decision == .approved { startCoverQueue() }
    }

    /// A finished sign-in changes what the site shows, so its protocol is read again.
    /// A website's account changed: what was learned about the website is looked up again with it.
    /// [site] is a connected website; nil is the checked one.
    @MainActor func siteSignInFinished(site: String? = nil) {
        // A first sign-in brings the website's favorites into a folder named after it.
        let signedIn = site ?? mangaSiteAddress
        defer { Task { await setUpSiteFavorites(site: signedIn) } }
        if let site, site != mangaSiteAddress {
            SiteScope.$site.withValue(site) { MangaUrls.resetResolvedBackend() }
            comicSitesRevision += 1
            return
        }
        siteAccountSignedIn = SiteAccount.isSignedIn(host: MangaUrls.configuredHost)
        MangaUrls.resetResolvedBackend()
        ContentBrowserTransport.reset()
    }

    /// Signs one connected website out; the other websites keep their accounts. Nil is the checked one.
    @MainActor func signOutOfSite(_ site: String? = nil) {
        let site = site ?? mangaSiteAddress
        let (host, session, signInHost) = SiteScope.$site.withValue(site) {
            (MangaUrls.configuredHost, MangaUrls.usesSiteSession, MangaUrls.signInURL?.host?.lowercased())
        }
        guard !host.isEmpty else { return }
        SiteAccount.signOut(host: host)
        // The folders stay as plain folders; signing in again sets them up afresh.
        SiteFavoriteFolders.shared.remove(site, declined: false)
        favoriteFoldersRevision += 1
        if site == mangaSiteAddress { siteAccountSignedIn = false }
        siteSignInFinished(site: site)
        // The sign-in pages share the website's browser profile; it must not sign the account back in.
        Task {
            await ComicsBrowserProfile.forgetSignIn(host: host, session: session)
            if let signInHost, signInHost != host { await ComicsBrowserProfile.forgetSignIn(host: signInHost) }
        }
    }

    /// Whether a connected website now shows its signed-in account: its favorites open, or a
    /// members-only website shows its works. Nil is the checked website.
    @MainActor func checkSiteAccount(site: String? = nil) async -> Bool {
        guard let site, site != mangaSiteAddress else {
            await MangaUrls.resolveBackend(force: true)
            guard MangaUrls.hasResolvedBackend, MangaUrls.backend != .indexed else { return false }
            do {
                _ = try await MangaContentSource.shared.favoriteCategories()
                return true
            } catch { return false }
        }
        let content = SiteContent.for(site)
        return await SiteScope.$site.withValue(site) {
            await MangaUrls.resolveBackend(force: true)
            guard MangaUrls.hasResolvedBackend, MangaUrls.backend != .indexed else { return false }
            do {
                _ = try await content.favoriteCategories()
                return true
            } catch { return false }
        }
    }

    /// Bookmarks every account favorite not already saved, into the default folder, or each
    /// favorites category into a folder of the same name. With categories, works already saved
    /// join their category's folder too, so the library holds the account's arrangement.
    @MainActor func importAccountFavorites(intoCategoryFolders: Bool = false) async throws -> Int {
        var added = 0
        if intoCategoryFolders {
            let categories = try await MangaContentSource.shared.favoriteCategories()
            for category in categories where category.count > 0 {
                try Task.checkCancellation()
                let folder = try database.createFolder(name: category.name)
                added += try await importAccountFavorites(category: category.id, folder: folder.id, joinsExisting: true)
            }
        } else {
            added = try await importAccountFavorites(category: nil, folder: try database.defaultSaveFolder().id, joinsExisting: false)
        }
        if added > 0 { startCoverQueue() }
        return added
    }

    @MainActor private func importAccountFavorites(category: Int?, folder: Int64?, joinsExisting: Bool) async throws -> Int {
        var next: String?, added = 0, pages = 0
        repeat {
            let page = try await MangaContentSource.shared.accountFavorites(after: next, category: category)
            try Task.checkCancellation()
            for id in page.ids {
                if try database.getWork(galleryId: id) != nil {
                    if joinsExisting, let folder { try database.addWork(galleryId: id, folderID: folder) }
                    continue
                }
                let work = MangaContentSource.shared.cachedPreview(id)
                _ = try database.upsertWork(galleryId: id, folderId: folder, title: work?.title, artists: work?.artists.joined(separator: ", "),
                                            language: work?.language, type: work?.type, tags: work?.tags.joined(separator: ", "), metadataSource: "remote", site: ComicSites.active,
                                            pageCount: work?.displayedPageCount)
                added += 1
            }
            next = page.next
            pages += 1
        } while next != nil && pages < 500
        return added
    }


    // MARK: Website favorites folders

    /// Websites whose favorites sync is running, so two runs never cross.
    @ObservationIgnored private var syncingFavorites = Set<String>()
    /// Changes when a website's favorites sync is set up or runs, so settings redraw.
    public private(set) var favoriteFoldersRevision = 0
    /// At most this many favorites are changed on a website in one sync; the rest wait for the next.
    static let favoriteSendsPerSync = 30
    /// A website whose favorites can be synced, waiting for the person to choose how to start.
    public internal(set) var favoriteSetupOffer: SiteFavoritesSetupOffer?

    /// A website's signed-in account that can keep favorites, by host; nil without one.
    func favoritesAccountHost(_ site: String) -> String? {
        let host = SiteScope.$site.withValue(site) { MangaUrls.configuredHost }
        guard !host.isEmpty, SiteAccount.isSignedIn(host: host), !SiteAccount.refusesAccess(host: host) else { return nil }
        return host
    }

    /// The first time a signed-in website's favorites can be read, nothing changes yet: the person
    /// is shown what bringing them in would do and chooses (`answerSiteFavoritesSetup`). Turned off
    /// in the website's settings, it is not offered again unless turned back on there (`requested`).
    @MainActor func setUpSiteFavorites(site: String, requested: Bool = false) async {
        let store = SiteFavoriteFolders.shared
        guard store.state(for: site) == nil, requested || !store.isDeclined(site), favoritesAccountHost(site) != nil,
              favoriteSetupOffer == nil || favoriteSetupOffer?.site == site else { return }
        // Read before anything is offered, so a website that keeps the account out asks nothing.
        guard let favorites = try? await SiteContent.for(site).accountFavoriteLists(),
              let offer = try? siteFavoritesSetupOffer(site: site, favorites: favorites) else { return }
        // A website with no favorites has nothing to bring in or leave alone, except after a restore,
        // when bringing in would send the restored folders to the website without asking.
        if offer.favoriteCount == 0 && !store.asksAgain(site) { await startSiteFavorites(offer, choice: .bringIn); return }
        guard favoriteSetupOffer == nil || favoriteSetupOffer?.site == site, store.state(for: site) == nil else { return }
        favoriteSetupOffer = offer
    }

    /// What bringing a website's favorites in would change, worked out without changing anything.
    private func siteFavoritesSetupOffer(site: String, favorites: AccountFavorites) throws -> SiteFavoritesSetupOffer {
        var state = SiteFavoriteFolders.State(exclusive: favorites.exclusive)
        let matches = try categoryFolderMatches(favorites, state: state)
        var reused: [Int: Int64] = [:]
        for match in matches { if let id = match.folder?.id { reused[match.category] = id } }
        state.unassigned = favorites.spareCategory(besides: Set(matches.map(\.category)))
        let plan = FavoriteSyncPlan.make(local: try savedFavoritePlaces(folders: reused), remote: favorites.members, base: nil,
                                         folders: Set(matches.map(\.category)), unassigned: state.unassigned, localOnly: [],
                                         exclusive: favorites.exclusive)
        var newWorks = 0, filedWorks = 0
        for change in plan.local {
            guard case .place(let id, _) = change else { continue }
            if try database.getWork(galleryId: id) == nil { newWorks += 1 } else { filedWorks += 1 }
        }
        let host = SiteScope.$site.withValue(site) { MangaUrls.configuredHost }
        return SiteFavoritesSetupOffer(site: site, host: host.isEmpty ? site : host, favorites: favorites,
                                       favoriteCount: favorites.members.count, newWorks: newWorks, filedWorks: filedWorks,
                                       newFolders: matches.filter { $0.folder == nil }.map(\.name))
    }

    /// The person's answer to how a website's favorites start syncing.
    @MainActor func answerSiteFavoritesSetup(_ choice: SiteFavoritesSetupChoice) {
        guard let offer = favoriteSetupOffer else { return }
        favoriteSetupOffer = nil
        Task {
            if choice == .off {
                SiteFavoriteFolders.shared.remove(offer.site, declined: true)
                favoriteFoldersRevision += 1
            } else { await startSiteFavorites(offer, choice: choice) }
            // Another signed-in website waiting to be asked comes next.
            for site in ComicSites.all where site != offer.site && favoriteSetupOffer == nil { await setUpSiteFavorites(site: site) }
        }
    }

    /// Bringing in fills a folder for each category that holds works and adds the favorites the app
    /// lacks. Keeping the library leaves every favorite already on the website alone on both sides,
    /// so only what is added or removed from now on is synced.
    @MainActor private func startSiteFavorites(_ offer: SiteFavoritesSetupOffer, choice: SiteFavoritesSetupChoice) async {
        let store = SiteFavoriteFolders.shared
        guard store.state(for: offer.site) == nil, favoritesAccountHost(offer.site) != nil else { return }
        let favorites = offer.favorites
        do {
            var state = SiteFavoriteFolders.State(exclusive: favorites.exclusive)
            state.setUpAt = Date()
            if choice == .keepLibrary { state.ignored = Set(favorites.members.keys) }
            _ = try linkCategoryFolders(favorites, state: &state)
            state.unassigned = favorites.spareCategory(besides: Set(state.folders.keys))
            store.setState(state, for: offer.site)
            favoriteFoldersRevision += 1
            try await syncSiteFavorites(site: offer.site, remote: favorites)
        } catch {}
    }

    /// Each favorites category holding works the sync looks after, with the unlinked folder already
    /// named so, if there is one, apart from the category kept for other folders.
    private func categoryFolderMatches(_ favorites: AccountFavorites, state: SiteFavoriteFolders.State) throws -> [(category: Int, name: String, folder: Folder?)] {
        var folders = try database.listFolders()
        let held = favorites.heldCategories(ignoring: state.ignored ?? [])
        var taken = Set(state.folders.values)
        var matches: [(category: Int, name: String, folder: Folder?)] = []
        for category in favorites.categories where held.contains(category.id) && state.folders[category.id] == nil && category.id != state.unassigned {
            let index = try folders.firstIndex { folder in
                guard folder.name == category.name, let id = folder.id else { return false }
                return try !taken.contains(database.identity(ofFolder: id))
            }
            if let index, let id = folders[index].id {
                taken.insert(try database.identity(ofFolder: id))
                matches.append((category.id, category.name, folders[index]))
                folders.remove(at: index)
            } else { matches.append((category.id, category.name, nil)) }
        }
        return matches
    }

    /// Gives each favorites category that holds works a folder of its name, or the unlinked folder
    /// already named so, apart from the category kept for other folders. Returns the categories
    /// linked now, whose works the next merge takes from the website.
    private func linkCategoryFolders(_ favorites: AccountFavorites, state: inout SiteFavoriteFolders.State) throws -> Set<Int> {
        var linked = Set<Int>()
        for match in try categoryFolderMatches(favorites, state: state) {
            let folder = try match.folder ?? database.createFolder(name: match.name)
            guard let id = folder.id else { continue }
            state.folders[match.category] = try database.identity(ofFolder: id)
            linked.insert(match.category)
        }
        return linked
    }

    /// A category and its folder come and go together: once a sync that read the website leaves a
    /// category without favorites and its folder empty, whichever side emptied it, the folder goes
    /// too. A smart folder stays, since its tags would be lost; an empty category is free again.
    private func dropEmptiedCategoryFolders(state: inout SiteFavoriteFolders.State, settled: [Int64: Set<Int>]) throws {
        let used = settled.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        for (category, identity) in state.folders where !used.contains(category) {
            guard let id = try database.folderID(identity: identity), try database.galleryIDs(inFolder: id).isEmpty,
                  try database.rule(forFolder: identity)?.isActive != true else { continue }
            try database.deleteFolder(id: id)
            state.folders[category] = nil
        }
    }

    /// Whether a folder stands for a signed-in website's favorites category. Such a folder can't be
    /// deleted while the website keeps its account and the sync is on.
    func isSiteFavoritesFolder(_ id: Int64) -> Bool {
        _ = favoriteFoldersRevision
        guard let identity = try? database.identity(ofFolder: id) else { return false }
        let store = SiteFavoriteFolders.shared
        return store.syncedSites.contains { site in
            favoritesAccountHost(site) != nil && store.state(for: site)?.folders.values.contains(identity) == true
        }
    }

    /// When each synced website's favorites were brought in, to tell those works apart later.
    var siteFavoritesSetUpTimes: [Date] {
        _ = favoriteFoldersRevision
        let store = SiteFavoriteFolders.shared
        return store.syncedSites.compactMap { store.state(for: $0)?.setUpAt }
    }

    /// Whether any of these works is a favorite a signed-in website keeps in step with the app, so
    /// deleting it here would take it off the website too.
    func syncedSiteFavorites(among ids: Set<Int64>) -> Bool {
        let store = SiteFavoriteFolders.shared
        return store.syncedSites.contains { site in
            guard favoritesAccountHost(site) != nil, let state = store.state(for: site) else { return false }
            let ignored = state.ignored ?? []
            return ids.contains { state.baseline?[$0] != nil && !ignored.contains($0) }
        }
    }

    /// Deletes works from the library. `keepOnWebsite` leaves the synced websites' favorites as they
    /// are: those works are left alone by the sync from then on.
    @MainActor func deleteSavedWorks(_ ids: Set<Int64>, keepOnWebsite: Bool) throws {
        if keepOnWebsite {
            let store = SiteFavoriteFolders.shared
            for site in store.syncedSites {
                guard var state = store.state(for: site) else { continue }
                let kept = ids.filter { state.baseline?[$0] != nil }
                guard !kept.isEmpty else { continue }
                state.ignored = (state.ignored ?? []).union(kept)
                store.setState(state, for: site)
            }
        }
        try database.deleteSelectedWorks(ids)
    }

    /// Stops keeping a website's favorites and its folders the same; both keep what they hold.
    @MainActor func stopSyncingSiteFavorites(site: String) {
        SiteFavoriteFolders.shared.remove(site, declined: true)
        favoriteFoldersRevision += 1
    }

    /// The category works in other folders are kept in on the website; nil keeps them in the app only.
    @MainActor func setUnassignedFavoriteCategory(_ category: Int?, site: String) {
        guard var state = SiteFavoriteFolders.shared.state(for: site) else { return }
        state.unassigned = category
        SiteFavoriteFolders.shared.setState(state, for: site)
        favoriteFoldersRevision += 1
    }

    /// Where each saved work sits: the categories' folders it is in, or anywhere else.
    private func savedFavoritePlaces(folders: [Int: Int64]) throws -> [Int64: Set<FavoritePlace>] {
        let categoryOf = Dictionary(folders.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        return try database.savedWorkFolders().mapValues { inFolders in
            let categories = Set(inFolders.compactMap { categoryOf[$0] }.map(FavoritePlace.category))
            return categories.isEmpty ? [.unassigned] : categories
        }
    }

    /// Brings a website's favorites and its folders into step: what was added, removed or moved on
    /// one side since the last sync is done on the other. `pull` reads the website's favorites again;
    /// without it only changes made in the app are sent.
    @MainActor @discardableResult
    func syncSiteFavorites(site: String, pull: Bool = true, remote fetched: AccountFavorites? = nil) async throws -> FavoriteSyncPlan? {
        let store = SiteFavoriteFolders.shared
        guard var state = store.state(for: site), favoritesAccountHost(site) != nil else { return nil }
        guard syncingFavorites.insert(site).inserted else { return nil }
        defer { syncingFavorites.remove(site) }
        // A category folder that went missing is made again from the website's favorites, so the
        // website is read even when only app changes were to be sent.
        var missing = false
        for (category, identity) in state.folders where try database.folderID(identity: identity) == nil {
            state.folders[category] = nil
            missing = true
        }
        let content = SiteContent.for(site)
        let remote: [Int64: Set<Int>]
        var favorites = fetched
        if favorites == nil, pull || missing || state.baseline == nil { favorites = try await content.accountFavoriteLists() }
        if let favorites {
            remote = favorites.members
            state.exclusive = favorites.exclusive
            state.lastPull = Date()
            // A category or list removed on the website lets its folder go; the folder keeps its works.
            let existing = Set(favorites.categories.map(\.id))
            for category in state.folders.keys where !existing.contains(category) { state.folders[category] = nil }
            if let unassigned = state.unassigned, !existing.contains(unassigned) {
                state.unassigned = favorites.spareCategory(besides: Set(state.folders.keys))
            }
            // Every category holding favorites keeps a folder: one filled on the website later, or one
            // whose folder went missing, gets one now and takes its works from the website.
            let linked = try linkCategoryFolders(favorites, state: &state)
            if !linked.isEmpty, let baseline = state.baseline { state.baseline = baseline.mapValues { $0.subtracting(linked) } }
        } else { remote = state.baseline ?? [:] }
        var folders: [Int: Int64] = [:]
        for (category, identity) in state.folders { folders[category] = try database.folderID(identity: identity) }
        let exclusive = state.exclusive ?? true
        // Works deleted in the app only while the website was read are left alone too.
        if let stored = store.state(for: site)?.ignored { state.ignored = (state.ignored ?? []).union(stored) }
        // Read after the website answers, so a change made meanwhile is not lost.
        let plan = FavoriteSyncPlan.make(local: try savedFavoritePlaces(folders: folders), remote: remote, base: state.baseline,
                                         folders: Set(folders.keys), unassigned: state.unassigned, localOnly: state.localOnly,
                                         exclusive: exclusive, ignored: state.ignored ?? [])
        var settled = plan.settled
        state.localOnly.formUnion(plan.keepLocal)
        state.localOnly.subtract(plan.stopKeepingLocal)
        if !plan.stopIgnoring.isEmpty { state.ignored?.subtract(plan.stopIgnoring) }
        // Recorded first, so the folder changes below are not taken for new ones made by hand.
        state.baseline = settled
        store.setState(state, for: site)
        let linked = Set(folders.values)
        let unfiled = try database.unfiledFolderID()
        for change in plan.local {
            switch change {
            case .remove(let id):
                try database.deleteWork(galleryId: id)
            case .place(let id, let places):
                let targets = Set(places.compactMap { $0.category.flatMap { folders[$0] } })
                let current = try database.folderIDs(galleryId: id)
                if current.isEmpty, try database.getWork(galleryId: id) == nil {
                    // A favorite in no category's folder comes to Unfiled.
                    let work = content.cachedPreview(id)
                    _ = try database.upsertWork(galleryId: id, folderId: targets.min() ?? unfiled, title: work?.title,
                                                artists: work?.artists.joined(separator: ", "), language: work?.language, type: work?.type,
                                                tags: work?.tags.joined(separator: ", "), metadataSource: "remote", site: site, pageCount: work?.displayedPageCount)
                }
                for target in targets.subtracting(current) { try database.addWork(galleryId: id, folderID: target) }
                try database.removeWork(galleryId: id, fromFolders: linked.intersection(current).subtracting(targets))
            }
        }
        // A failed request leaves the rest for the next sync instead of asking again and again.
        var sent = 0, failed = false, refused = Set<Int64>()
        for change in plan.site {
            guard !failed, sent < Self.favoriteSendsPerSync, !refused.contains(change.id) else {
                if !refused.contains(change.id) { settled[change.id] = remote[change.id] }
                continue
            }
            if sent > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            sent += 1
            do {
                try await content.changeAccountFavorite(change.id, category: change.category, adds: change.adds)
            } catch ContentError.galleryNotFound where change.adds {
                refused.insert(change.id)
            } catch ContentError.unavailable(422) where change.adds {
                refused.insert(change.id)
            } catch {
                failed = true
                settled[change.id] = remote[change.id]
            }
        }
        // A work the website won't keep stays in the app only.
        for id in refused { state.localOnly.insert(id); settled[id] = remote[id] }
        if favorites != nil { try dropEmptiedCategoryFolders(state: &state, settled: settled) }
        state.baseline = settled
        if let stored = store.state(for: site)?.ignored {
            state.ignored = (state.ignored ?? []).union(stored.subtracting(plan.stopIgnoring))
        }
        store.setState(state, for: site)
        if plan.local.contains(where: { if case .place = $0 { return true } else { return false } }) { startCoverQueue() }
        favoriteFoldersRevision += 1
        return plan
    }

    /// While the app is open: sets up websites signed in since, reads each website's favorites again
    /// when it has not for half an hour, and sends library changes made in the app.
    @MainActor func runSiteFavoritesSync() async {
        let store = SiteFavoriteFolders.shared
        for site in ComicSites.all where favoritesAccountHost(site) != nil {
            if let state = store.state(for: site) {
                if (state.lastPull ?? .distantPast) < Date().addingTimeInterval(-30 * 60) { _ = try? await syncSiteFavorites(site: site) }
            } else { await setUpSiteFavorites(site: site) }
            if Task.isCancelled { return }
        }
        // Any change to which works are saved where.
        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: "SELECT w.gallery_id, fw.folder_id FROM works w LEFT JOIN folder_works fw ON fw.work_id = w.id ORDER BY 1, 2")
        }
        do {
            var first = true
            for try await _ in observation.values(in: database.dbWriter) {
                if first { first = false; continue }
                // A moment's wait gathers a burst of changes into one sync.
                try await Task.sleep(for: .seconds(1))
                for site in store.syncedSites { _ = try? await syncSiteFavorites(site: site, pull: false) }
            }
        } catch {}
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

/// What the first sync with a website's favorites would do, shown before anything changes.
public struct SiteFavoritesSetupOffer: Identifiable {
    public var id: String { site }
    let site: String
    /// The website's address, as the person sees it.
    let host: String
    let favorites: AccountFavorites
    let favoriteCount: Int
    /// Favorites the library doesn't have yet.
    let newWorks: Int
    /// Saved works that would also go into a category's folder.
    let filedWorks: Int
    /// Folders that would be made, one for each category without a folder of its name.
    let newFolders: [String]
}

/// How a website's favorites start syncing.
public enum SiteFavoritesSetupChoice: Equatable {
    /// Brings the favorites into the library, a folder for each category.
    case bringIn
    /// Leaves the library and the website as they are, and syncs only later changes.
    case keepLibrary
    /// Doesn't sync; the website's settings can turn it on.
    case off
}
