import SwiftUI
import GRDB

/// One entry point for library links and Explore, including the website fallback.
struct ContentEntryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var initialUrl: String = MangaUrls.home
    var embedded = false
    var siblingIDs: [Int64] = []
    var willCloseManga: (Int64) -> Void = { _ in }
    var body: some View {
        if !env.isSiteVerified {
            NavigationStack {
                ComicsSetupView()
                    .toolbar {
                        if !embedded {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                                    .labelStyle(.iconOnly).accessibilityIdentifier("content.close")
                            }
                        }
                    }
            }
        } else if env.useEmbeddedBrowser {
            if embedded {
                NavigationStack { InAppMangaBrowserView(initialUrl: initialUrl, embedded: true).appRootHeader("Explore") }
            } else { InAppMangaBrowserView(initialUrl: initialUrl, embedded: false) }
        } else {
            #if DEBUG
            if ContentUITestSupport.enabled {
                NativeContentView(initialUrl: initialUrl, source: ContentUITestSupport.source, savesProgress: false, embedded: embedded,
                                  images: env.launchFeeds.images, readerIDs: siblingIDs, willCloseManga: willCloseManga, startup: ProcessInfo.processInfo.arguments.contains("--launch-warmup-test") ? env.launchFeeds : nil)
            } else {
                NativeContentView(initialUrl: initialUrl, source: env.launchFeeds.manga, embedded: embedded,
                                  images: env.launchFeeds.images, readerIDs: siblingIDs, willCloseManga: willCloseManga, startup: env.launchFeeds)
            }
            #else
            NativeContentView(initialUrl: initialUrl, source: env.launchFeeds.manga, embedded: embedded,
                              images: env.launchFeeds.images, readerIDs: siblingIDs, willCloseManga: willCloseManga, startup: env.launchFeeds)
            #endif
        }
    }

}

/// The native content view. It renders data directly and never creates a web view.
public struct NativeContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    private let embedded: Bool
    private let initialRoute: ContentRoute?
    private let source: any ContentProviding
    private let savesProgress: Bool
    private let startup: LaunchFeedWarmup?
    private let willCloseManga: (Int64) -> Void
    @State private var readerSequence: MangaReaderSequence
    @State private var images: PageImageStore
    @State private var path: [ContentRoute] = []
    @State private var presentedGallery: GalleryDestination?
    private struct GalleryDestination: Identifiable {
        let id: Int64
        let context: DiscoveryContext
    }
    @State private var presentedReader: ReaderDestination?
    @State private var readerSearch: String?
    private struct ReaderDestination: Identifiable {
        let id: Int64
        let page: Int
        let context: DiscoveryContext
        let resumesProgress: Bool
    }
    private func openReader(_ id: Int64, _ page: Int, _ context: DiscoveryContext, _ resumesProgress: Bool = true) {
        presentedReader = ReaderDestination(id: id, page: page, context: context, resumesProgress: resumesProgress)
    }
    private func navigate(_ route: ContentRoute) {
        switch route {
        case .gallery(let id): presentedGallery = GalleryDestination(id: id, context: .unknown)
        case .discoveredGallery(let id, let context): presentedGallery = GalleryDestination(id: id, context: context)
        case .reader(let id, let page): openReader(id, page, .unknown)
        case .discoveredReader(let id, let page, let context): openReader(id, page, context)
        default: path.append(route)
        }
    }
    /// A work linked from another work stacks on it, so going back returns there.
    private func follow(_ route: ContentRoute) {
        if case .discoveredReader(let id, let page, let context) = route { openReader(id, page, context) }
        else { path.append(route) }
    }

    public init(initialUrl: String = MangaUrls.home, embedded: Bool = false) {
        self.init(initialUrl: initialUrl, source: MangaContentSource.shared, embedded: embedded)
    }

    init(initialUrl: String = MangaUrls.home, source: any ContentProviding, savesProgress: Bool = true, embedded: Bool = false, initialQuery: String? = nil, images: PageImageStore? = nil, readerIDs: [Int64] = [], sequence: MangaReaderSequence? = nil, willCloseManga: @escaping (Int64) -> Void = { _ in }, startup: LaunchFeedWarmup? = nil) {
        self.embedded = embedded
        _readerSequence = State(initialValue: sequence ?? MangaReaderSequence(readerIDs))
        initialRoute = initialQuery.map(ContentRoute.query) ?? ContentRoute.initial(initialUrl)
        self.source = source
        self.savesProgress = savesProgress
        self.startup = startup
        self.willCloseManga = willCloseManga
        _images = State(initialValue: images ?? PageImageStore(source: source))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            root
                .modifier(EmbeddedQueueClearance(embedded: embedded))
                .navigationDestination(for: ContentRoute.self) { route in destination(route).modifier(EmbeddedQueueClearance(embedded: embedded)) }
                .toolbar {
                    if embedded { ToolbarItem(placement: .principal) { AppModeSwitch() } }
                    if !embedded { ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("content.close")
                    } }
                }
        }
        // Work information in a sheet closes with a swipe to the right, as a page goes back. Only
        // on its first page: once something is pushed, the system's back swipe, which also starts
        // mid-screen, goes back a page as before.
        .modifier(SheetSwipeBack(enabled: !embedded && path.isEmpty && opensInformation, close: { dismiss() }))
        .appSheet(item: $presentedGallery) { gallery in
            NativeContentView(initialUrl: MangaUrls.galleryUrl(for: gallery.id), source: source,
                              savesProgress: savesProgress, images: images, readerIDs: readerSequence.ids, sequence: readerSequence, willCloseManga: willCloseManga)
                .environment(\.discoveryContext, gallery.context)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .appFullScreenCover(item: $presentedReader, onDismiss: {
            if let readerSearch { self.readerSearch = nil; path.append(.query(readerSearch)) }
        }) { reader in
            MangaReaderSession(galleryID: reader.id, initialPage: reader.page, source: source, images: images,
                             savesProgress: savesProgress, resumesProgress: reader.resumesProgress, search: { text in readerSearch = text; presentedReader = nil },
                             exit: { presentedReader = nil }, willClose: willCloseManga)
                .environment(\.discoveryContext, reader.context)
                .environment(\.mangaReaderSequence, readerSequence)
        }
        .presentationDragIndicator(.visible)
        .environment(\.mangaReaderSequence, readerSequence)
    }

    private var opensInformation: Bool {
        switch initialRoute {
        case .gallery, .discoveredGallery: true
        default: false
        }
    }

    @ViewBuilder private var root: some View {
        if embedded && savesProgress && !env.isSiteVerified {
            ContentUnavailableView(L10n.text("Connect a Website"), systemImage: "globe", description: Text(L10n.text("Connect the website address in Settings.")))
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Explore")) } }
        } else if let initialRoute { destination(initialRoute) }
        else { GalleryFeedView(source: source, images: images, startup: startup, navigate: navigate) }
    }

    @ViewBuilder private func destination(_ route: ContentRoute) -> some View {
        switch route {
        case .discoveredGallery(let id, let context):
            RemoteGalleryView(galleryID: id, source: source, images: images, read: openReader, follow: follow).environment(\.discoveryContext, context)
        case .discoveredReader(let id, let page, let context):
            MangaReaderSession(galleryID: id, initialPage: page, source: source, images: images, savesProgress: savesProgress, search: { text in
                if !path.isEmpty { path.removeLast() }; path.append(.query(text))
            }, exit: { if path.isEmpty { dismiss() } else { path.removeLast() } }, willClose: willCloseManga).environment(\.discoveryContext, context)
        case .reader(let id, let page):
            MangaReaderSession(galleryID: id, initialPage: page, source: source, images: images, savesProgress: savesProgress, search: { text in
                if !path.isEmpty { path.removeLast() }
                path.append(.query(text))
            }, exit: { if path.isEmpty { dismiss() } else { path.removeLast() } }, willClose: willCloseManga)
        case .gallery(let id):
            RemoteGalleryView(galleryID: id, source: source, images: images, read: openReader, follow: follow)
        case .artist(let name):
            GalleryFeedView(artist: name, source: source, images: images, navigate: navigate)
        case .query(let text):
            GalleryFeedView(initialQuery: text, source: source, images: images, navigate: navigate)
        }
    }
}

/// Picks the connected comics websites Explore lists together, as image mode picks servers.
struct ComicSiteMenu: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        let listed = env.listedComicSites
        Menu {
            ForEach(env.comicSites, id: \.self) { site in
                Toggle(site, isOn: Binding(get: { listed.contains(site) }, set: { selected in
                    guard selected != env.listedComicSites.contains(site) else { return }
                    env.toggleListedComicSite(site)
                }))
            }
        } label: {
            Label(L10n.text("Website"), systemImage: "globe")
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel(L10n.text("Website") + ": " + (listed.isEmpty ? L10n.text("No websites selected") : listed.joined(separator: ", ")))
        .accessibilityIdentifier("content.siteMenu")
    }
}

/// Explore with every website unpicked, as image mode shows no servers.
struct ComicNoSiteSelectionView: View {
    var body: some View {
        ContentUnavailableView(L10n.text("No websites selected"), systemImage: "globe",
            description: Text(L10n.text("Choose websites using the website button above. Your saved works are kept.")))
            .accessibilityIdentifier("content.noSiteSelection")
    }
}

struct ContentFailureView: View {
    let message: String
    let retry: () -> Void
    /// Optional because failures also show in screens hosted outside the app's environment.
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    @State private var signingIn = false
    /// A website that shows nothing until someone signs in gets its sign-in right here.
    private var asksForSignIn: Bool {
        env != nil && message == ContentError.signInRequired.localizedDescription && MangaUrls.signInURL != nil
    }
    /// A connected website that numbers works the same way may still show what this one won't.
    private var sibling: String? {
        guard let env, env.isSiteVerified else { return nil }
        let blocked = [ContentError.signInRequired, .galleryNotFound, .unavailable(403), .unavailable(404), .unavailable(410)].map(\.localizedDescription)
        guard blocked.contains(message) else { return nil }
        _ = env.comicSitesRevision
        return ComicSites.siblings(of: env.mangaSiteAddress).first
    }
    var body: some View {
        ContentUnavailableView {
            Label(L10n.text(asksForSignIn ? "Sign In Required" : "Unable to Load"), systemImage: asksForSignIn ? "person.crop.circle" : "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if asksForSignIn {
                Button(L10n.text("Sign In to Website")) { signingIn = true }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("content.signIn")
                Button(L10n.text("Try Again"), action: retry).accessibilityIdentifier("content.retry")
            } else {
                Button(L10n.text("Try Again"), action: retry).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("content.retry")
            }
            if let sibling, let env {
                Button(L10n.text("Open on %@", sibling)) { env.switchComicsSite(to: sibling); retry() }
                    .accessibilityIdentifier("content.openOnSibling")
            }
        }
        .appSheet(isPresented: $signingIn) {
            SiteSignInView { env?.siteSignInFinished(); retry() }
        }
    }
}

private struct ContentBookmark: Identifiable {
    let id: Int64
}

/// A pull at the top of a feed either refreshes it or, in a sheet, closes the sheet.
extension EnvironmentValues {
    @Entry var feedClosesOnPull = false
}

private struct FeedRefresh: ViewModifier {
    let enabled: Bool
    let action: () async -> Void
    func body(content: Content) -> some View {
        if enabled { content.refreshable { await action() } } else { content }
    }
}

private struct GalleryFeedView: View {
    @Environment(\.mangaReaderSequence) private var readerSequence
    @Environment(\.feedClosesOnPull) private var closesOnPull
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @Environment(\.discoveryContext) private var inheritedContext
    @State private var tasteSession = UUID().uuidString
    @State private var submitted = false
    private var discovery: DiscoveryContext {
        DiscoveryContext(origin: !submitted && inheritedContext.origin == .recommendation ? .recommendation : query.text.isEmpty ? .feed : .search, query: query.text, defaults: env.defaultTags + " " + env.defaultExcludedTags, session: tasteSession)
    }
    @Environment(AppEnvironment.self) private var env
    @State private var toast: String?
    @State private var saveFeedback: WorkSaveFeedback?
    let artist: String?
    private let browsesArtist: Bool
    private let browsesTag: Bool
    /// The tag the feed opened on; its language is remembered only while it still shows that tag.
    private let initialText: String
    let source: any ContentProviding
    let images: PageImageStore
    let navigate: (ContentRoute) -> Void
    @State private var query: GalleryQuery
    @State private var searchText: String
    @State private var isSearchBarVisible = true
    @FocusState private var isSearchFocused: Bool
    @State private var confirmingHistoryClear = false
    @State private var suggestions: [TagSuggestion] = []
    @State private var suggesting = false
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var paginationViewport = GalleryPaginationViewport()
    @State private var searchViewportHeight: CGFloat = 0
    @State private var footerVisible = false
    @State private var savedWorks = SavedWorkKeys()
    @State private var history: [String] = []
    @State private var savedSearches: [String] = []
    @State private var loadedQuery: GalleryQuery?
    @State private var openedCategory = ""
    private let isMainFeed: Bool
    @State private var loadedSite: String?
    private struct InitialRequest: Hashable { let query: GalleryQuery; let site: String }
    @State private var loader: GalleryFeedLoader

    init(artist: String? = nil, initialQuery: String = "", source: any ContentProviding, images: PageImageStore, startup: LaunchFeedWarmup? = nil, navigate: @escaping (ContentRoute) -> Void) {
        self.artist = artist
        self.source = source
        self.images = images
        _loader = State(initialValue: GalleryFeedLoader(source: source, images: images, startup: startup))
        self.navigate = navigate
        let browsesArtist = artist != nil || ArtistBrowsing.matches(initialQuery)
        self.browsesArtist = browsesArtist
        let browsesTag = !browsesArtist && TagBrowsing.matches(initialQuery)
        self.browsesTag = browsesTag
        self.initialText = initialQuery
        isMainFeed = artist == nil && initialQuery.isEmpty
        let language = browsesArtist ? ArtistBrowsing.language : browsesTag ? TagBrowsing.language : initialQuery.isEmpty ? L10n.contentLanguage : "all"
        _query = State(initialValue: GalleryQuery(language: language, artist: artist, text: initialQuery))
        _searchText = State(initialValue: initialQuery)
    }

    private var effectiveQuery: GalleryQuery { effectiveQuery(category: category.wrappedValue) }

    private func effectiveQuery(category: String) -> GalleryQuery {
        var result = query.filtered(to: category).applyingDefaults(tags: env.defaultTags, excluded: env.defaultExcludedTags)
        result.allowsLanguageExceptions = env.allowsMangaLanguageExceptions
        return result
    }

    /// The main feed remembers its category; a feed opened from a tag or artist starts with all.
    private var category: Binding<String> {
        isMainFeed ? Binding(get: { env.mangaBrowseCategory }, set: { env.mangaBrowseCategory = $0 }) : $openedCategory
    }

    private var languageMenu: some View {
        BrowseFilterMenu(title: L10n.text(query.language.capitalized), icon: "globe") {
            Picker(L10n.text("Language"), selection: $query.language) {
                Text(L10n.text("Korean")).tag("korean")
                Text(L10n.text("Japanese")).tag("japanese")
                Text(L10n.text("English")).tag("english")
                Text(L10n.text("All")).tag("all")
            }
        }.accessibilityIdentifier("content.language")
    }

    private var categoryMenu: some View {
        let selected = GalleryCategory.available.contains(category.wrappedValue) ? category.wrappedValue : ""
        return BrowseFilterMenu(title: selected.isEmpty ? L10n.text("Category") : GalleryCategory.title(selected), icon: "square.stack") {
            Picker(L10n.text("Category"), selection: Binding(get: { selected }, set: { category.wrappedValue = $0 })) {
                Text(L10n.text("All Categories")).tag("")
                ForEach(GalleryCategory.available, id: \.self) { Text(GalleryCategory.title($0)).tag($0) }
            }
        }.accessibilityIdentifier("content.category")
    }

    private var sortMenu: some View {
        BrowseFilterMenu(title: query.sort.title, icon: "arrow.up.arrow.down") {
            Picker(L10n.text("Sort"), selection: $query.sort) {
                ForEach(GallerySort.available) { Text($0.title).tag($0) }
            }
        }.accessibilityIdentifier("content.sort")
    }

    private var isActive: Bool { env.mode == .manga && scenePhase == .active }

    var body: some View {
        let visibleEntries = loader.items.enumerated().filter { !env.hiddenMangaGalleryIDs.contains($0.element.id) }
        let saved = Dictionary(uniqueKeysWithValues: Set(loader.items.map(\.site)).map { ($0, savedWorks.ids(on: $0)) })
        ScrollViewReader { scrollProxy in
        ZStack(alignment: .top) {
        ScrollView {
            LazyVStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { languageMenu; categoryMenu; Spacer(minLength: 0); sortMenu }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { languageMenu; Spacer(minLength: 0); sortMenu }
                        categoryMenu
                    }
                }
                if picksNoSite {
                    ComicNoSiteSelectionView().padding(.top, 40)
                } else {
                ArtworkGrid(mode: .manga, surroundingPadding: 16, topMarginScale: 0.5) { style in
                    let prefetchColumns = style.columns
                    let lookahead = prefetchColumns * 6
                    let prefetchThresholdIndex = max(0, loader.ids.count - lookahead)
                    // Read once for the grid: each lazy cell reading the loader would observe it again.
                    let previews = loader.previews
                    ForEach(visibleEntries, id: \.element) { index, item in
                        let id = item.id
                        let itemImages = loader.images(for: item) ?? images
                        GalleryGridCard(id: id, preview: previews[item], isBookmarked: saved[item.site]?.contains(id) == true, source: loader.source(for: item), images: itemImages, site: item.site,
                                        details: { showing(item) { navigate(MangaThumbnailOpening.information.route(for: id, context: discovery)) } },
                                        open: { showing(item) {
                                            // The reader steps through works of the website it reads.
                                            readerSequence?.ids = visibleEntries.map(\.element).filter { $0.site == item.site }.map(\.id)
                                            navigate(MangaThumbnailOpening.stored().route(for: id, context: discovery))
                                        } }) { gallery in
                            saveFeedback = .perform(galleryID: id) { try ContentBookmarkAction.toggle(id: id, gallery: gallery, env: env, images: itemImages, context: discovery, site: item.site) }
                        }
                        .id(id)
                        .onAppear {
                            if index.isMultiple(of: prefetchColumns) {
                                loader.prioritizeCovers(startingAt: index, count: lookahead, columns: prefetchColumns)
                            }
                            if index >= prefetchThresholdIndex && loader.hasMore && !loader.loading && loader.error == nil {
                                loader.load(effectiveQuery, reset: false)
                            }
                        }
                    }
                }.accessibilityIdentifier("content.grid")
                // Keep one lazy footer alive across loading changes. Recreating
                // a non-lazy button here starts another page as soon as each request ends.
                VStack {
                    if loader.loading { ProgressView(L10n.text("Loading")).accessibilityIdentifier("content.loading") }
                    else if let error = loader.error { ContentFailureView(message: error) { loader.retry(effectiveQuery) } }
                    else if loader.ids.isEmpty, browsesArtist, query.language != "all" {
                        ContentUnavailableView {
                            Label(L10n.text("No Works in This Language"), systemImage: "globe")
                        } actions: {
                            Button(L10n.text("Show All Languages")) { query.language = "all" }.accessibilityIdentifier("content.allLanguages")
                        }
                    }
                    else if loader.ids.isEmpty, effectiveQuery != effectiveQuery(category: "") {
                        ContentUnavailableView {
                            Label(L10n.text("No Works in This Category"), systemImage: "square.stack")
                        } actions: {
                            Button(L10n.text("Show All Categories")) { category.wrappedValue = "" }.accessibilityIdentifier("content.allCategories")
                        }
                    }
                    else if loader.ids.isEmpty { ContentUnavailableView.search(text: query.text) }
                    else if loader.hasMore {
                        Button(L10n.text("Load More")) { loader.load(effectiveQuery, reset: false) }
                            .frame(maxWidth: .infinity).accessibilityIdentifier("content.more")
                    }
                }.onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("gallery.feedViewport"))
                } action: { frame in
                    paginationViewport.footer = frame
                    updateFooterVisibility()
                }
                }
            }.padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8).padding(.top, 56)
        }
        .coordinateSpace(name: "gallery.feedViewport")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            paginationViewport.height = height
            searchViewportHeight = height
            updateFooterVisibility()
        }
        .scrollDismissesKeyboard(.interactively)
        .trackScrollGeometry { oldY, newY in
            if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: isSearchFocused) {
                isSearchBarVisible = visible
            }
        }
        VStack(spacing: 0) {
            ScrollSearchBar(text: $searchText, focused: $isSearchFocused, prompt: L10n.text("Search, number, or link"), identifier: "content.search", submit: submitSearch)
            if (isSearchFocused || confirmingHistoryClear) && searchText.isEmpty {
                SearchHistoryPanel(history: history, saved: savedSearches, open: { searchText = $0; submitSearch() }, star: { query in
                    do { try env.database.toggleSavedSearch(query); reloadSearches() } catch { toast = error.localizedDescription }
                }, remove: { query in
                    do { try env.database.deleteSearch(query); reloadSearches() } catch { toast = error.localizedDescription }
                }, confirmingClear: $confirmingHistoryClear).searchResultsPanel(height: SearchHistoryPanel.height(availableHeight: searchViewportHeight))
            } else if isSearchFocused, !suggestions.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { item in
                            Button {
                                guard let context = TagCompletionContext(searchText) else { return }
                                searchText = context.inserting(item)
                                suggestions = []
                            } label: {
                                HStack(spacing: 8) {
                                    Text(item.namespace).font(.caption).foregroundStyle(.secondary)
                                    Text(item.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let count = item.count { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
                                }.searchSuggestionRow()
                            }.buttonStyle(.plain).accessibilityIdentifier("content.suggestion.\(item.token)")
                            if item.id != suggestions.last?.id { Divider() }
                        }
                    }
                }.searchResultsPanel(height: min(280, CGFloat(suggestions.count) * 47))
            } else if isSearchFocused && suggesting {
                ProgressView().frame(maxWidth: .infinity).searchResultsPanel(height: 60)
                    .accessibilityLabel(L10n.text("Finding tags"))
            }
        }
        .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
        .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        .searchHistoryClearAlert(isPresented: $confirmingHistoryClear) {
            do { try env.database.clearSearchHistory(); reloadSearches() } catch { toast = error.localizedDescription }
        }
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: isSearchFocused) { _, focused in if focused { isSearchBarVisible = true; reloadSearches() } }
        .onChange(of: query.language) { _, language in
            if browsesArtist { ArtistBrowsing.language = language }
            else if browsesTag && query.text == initialText { TagBrowsing.language = language }
        }
        .task(id: "\(isSearchFocused):\(searchText)") {
            suggestions = []; suggesting = false
            guard isSearchFocused, let context = TagCompletionContext(searchText) else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                suggesting = true
                let result = try await source.suggestions(for: context.token)
                try Task.checkCancellation()
                suggestions = Array(result.prefix(8)); suggesting = false
            } catch { if !Task.isCancelled { suggesting = false } }
        }
        .overlay(alignment: .bottom) {
            if let toast { Text(toast).font(.subheadline.bold()).padding(14).background(.regularMaterial, in: Capsule()).padding().accessibilityIdentifier("content.toast") }
        }
        .workSaveFeedback($saveFeedback, identifier: "content.toast")
        .task(id: toast) {
            guard toast != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
        }
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                LiquidGlassTitleCapsule(artist ?? (query.text.isEmpty ? L10n.text("Explore") : L10n.text("Search Results")))
            }
            if env.comicSites.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { ComicSiteMenu() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isActive) {
            guard isActive else { return }
            do {
                let observation = ValueObservation.tracking { db in try SavedWorkKeys.fetch(db) }
                for try await keys in observation.values(in: env.database.dbWriter) { savedWorks = keys }
            } catch { /* Preserve the last known bookmark state if observation is interrupted. */ }
        }
        .task(id: InitialRequest(query: effectiveQuery, site: feedSite)) {
            guard isActive else { return }
            loader.resume()
            guard loadedQuery != effectiveQuery || loadedSite != feedSite || (!loader.didLoad && !loader.loading) else { return }
            let initial = !loader.didLoad && (loadedQuery == nil || loadedQuery == effectiveQuery) && (loadedSite == nil || loadedSite == feedSite)
            loadedQuery = effectiveQuery
            loadedSite = feedSite
            await reload(useLaunchPage: initial).value
        }
        .task(id: "\(footerVisible):\(loader.loading):\(loader.ids.count):\(isActive):\(isVisible)") {
            guard footerVisible, isActive, isVisible, !picksNoSite, !loader.loading, loader.hasMore, loader.error == nil else { return }
            // Give appended rows time to move the footer below the viewport.
            // Recheck after refresh/resume even when the first IDs stay unchanged.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard footerVisible, isActive, isVisible, !picksNoSite, !loader.loading, loader.hasMore, loader.error == nil else { return }
            loader.load(effectiveQuery, reset: false)
        }
        .onAppear {
            isVisible = true
            if isActive { resumeFeed() } else { loader.suspend() }
        }
        .onDisappear { isVisible = false; loader.suspend() }
        .onChange(of: isActive) { _, active in
            guard isVisible else { return }
            if active { resumeFeed() } else { loader.suspend() }
        }
        .modifier(FeedRefresh(enabled: !closesOnPull) {
            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.text != text { query.text = text }
            else { await reload().value }
        })
        .onAppear {
            let loader = loader, environment = env
            readerSequence?.prepareReturn = { [weak loader, weak environment] opened, viewed in
                guard let loader else { return }
                MangaViewerReturn.restore(openedID: opened, viewedID: viewed,
                    availableIDs: loader.ids.lazy.filter { !(environment?.hiddenMangaGalleryIDs.contains($0) ?? false) }, using: scrollProxy)
            }
        }
        }

    }

    private func resumeFeed() {
        loader.resume()
        if (loadedQuery != effectiveQuery || loadedSite != feedSite || !loader.didLoad) && !loader.loading {
            let initial = !loader.didLoad && (loadedQuery == nil || loadedQuery == effectiveQuery) && (loadedSite == nil || loadedSite == feedSite)
            loadedQuery = effectiveQuery
            loadedSite = feedSite
            reload(useLaunchPage: initial)
        }
    }

    /// What the list shows: the checked website, the picked ones together, or none.
    private var feedSite: String { picksNoSite || env.listsSeveralComicSites ? "*" + env.listedComicSites.joined(separator: ",") : env.mangaSiteAddress }

    /// Every connected website unpicked in the website menu.
    private var picksNoSite: Bool { env.listedComicSites.isEmpty && !env.comicSites.isEmpty }

    @discardableResult private func reload(useLaunchPage: Bool = false) -> Task<Void, Never> {
        if picksNoSite { return Task {} }
        if env.listsSeveralComicSites { return loader.load(effectiveQuery, reset: true, combinedSites: env.listedComicSites) }
        return loader.load(effectiveQuery, reset: true, useLaunchPage: useLaunchPage, site: env.mangaSiteAddress)
    }

    /// A work from another website in a combined list opens with that website checked, which
    /// leaves the combined list as it is.
    private func showing(_ item: FeedItem, _ action: () -> Void) {
        if env.listsSeveralComicSites, item.site != env.mangaSiteAddress { env.switchComicsSite(to: item.site) }
        action()
    }

    private func updateFooterVisibility() {
        let visible = paginationViewport.footer.map { $0.maxY > 0 && $0.minY < paginationViewport.height } ?? false
        if footerVisible != visible { footerVisible = visible }
    }

    private func submitSearch() {
        isSearchFocused = false
        suggestions = []
        submitted = true; tasteSession = UUID().uuidString
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ReaderPreferences.defaults.object(forKey: "search.rememberHistory") as? Bool ?? true {
            try? env.database.recordSearch(text)
            try? env.database.recordTasteSearch(DiscoveryContext(origin: .search, query: text, defaults: env.defaultTags + " " + env.defaultExcludedTags, session: tasteSession))
        }
        reloadSearches()
        if let route = ContentRoute.initial(text) { navigate(route) }
        else if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(text), id > 0 { navigate(.gallery(id)) }
        else {
            if query.text == text { reload() }
            else { query.text = text }
        }
    }
    private func reloadSearches() {
        history = (try? env.database.searchHistory()) ?? []
        savedSearches = (try? env.database.savedSearches()) ?? []
    }

}

/// Only the Explore tab sits over the Up Next bar; a work opened over it in a sheet does not.
private struct EmbeddedQueueClearance: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded { content.readingQueueClearance() } else { content.environment(\.readingQueueInset, 0) }
    }
}

/// Follows a rightward swipe across the sheet and closes it once the swipe goes far or fast enough.
private struct SheetSwipeBack: ViewModifier {
    let enabled: Bool
    let close: () -> Void
    @State private var offset: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(SwipeBackHost(enabled: enabled) { phase, translation, velocity in
                switch phase {
                case .changed: offset = max(0, translation)
                case .ended:
                    if translation > 110 || velocity > 700 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeOut(duration: 0.18)) { offset = 420 }
                        close()
                    } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 } }
                case .cancelled: withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                }
            })
    }
}

enum SwipeBackPhase { case changed, ended, cancelled }

/// Puts the swipe on the sheet's own view in UIKit, beside SwiftUI's gestures rather than under
/// them, so a swipe that starts on a title, a tag or a button still goes back.
private struct SwipeBackHost: UIViewRepresentable {
    let enabled: Bool
    let update: (SwipeBackPhase, CGFloat, CGFloat) -> Void
    func makeUIView(context: Context) -> HostView { HostView() }
    func updateUIView(_ view: HostView, context: Context) {
        view.recognizer.isEnabled = enabled
        view.update = update
    }
    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.recognizer.view?.removeGestureRecognizer(view.recognizer)
    }

    final class HostView: UIView {
        let recognizer = RightSwipeRecognizer()
        var update: (SwipeBackPhase, CGFloat, CGFloat) -> Void = { _, _, _ in }
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            recognizer.addTarget(self, action: #selector(changed))
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Attaches to the presented controller's view, so it covers this sheet and nothing over it.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var current = superview
            while let view = current {
                if let controller = Self.controller(owning: view), controller.presentingViewController != nil {
                    if recognizer.view !== view { recognizer.view?.removeGestureRecognizer(recognizer); view.addGestureRecognizer(recognizer) }
                    return
                }
                current = view.superview
            }
        }

        /// The controller whose view this is. SwiftUI puts responders of its own between the two.
        private static func controller(owning view: UIView) -> UIViewController? {
            var responder = view.next
            while let current = responder, !(current is UIView) {
                if let controller = current as? UIViewController { return controller.view === view ? controller : nil }
                responder = current.next
            }
            return nil
        }

        @objc private func changed() {
            switch recognizer.state {
            case .began, .changed: update(.changed, recognizer.translation, recognizer.velocity)
            case .ended: update(.ended, recognizer.translation, recognizer.velocity)
            case .cancelled, .failed: update(.cancelled, 0, 0)
            default: break
            }
        }
    }
}

/// Recognizes a one-finger swipe that clearly heads right. It gives way to anything under the
/// finger that can still scroll back to the left, and vertical scrolling waits only the few points
/// it takes to tell the directions apart.
final class RightSwipeRecognizer: UIGestureRecognizer {
    private var start: CGPoint = .zero
    private var last: (point: CGPoint, time: TimeInterval) = (.zero, 0)
    private(set) var translation: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private var blocked = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, (event.allTouches?.count ?? 1) == 1, let touch = touches.first else { state = .failed; return }
        start = touch.location(in: nil)
        last = (start, touch.timestamp)
        translation = 0; velocity = 0
        blocked = Self.scrollsBack(from: touch.view)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        if state == .possible {
            guard hypot(dx, dy) >= 10 else { return }
            state = !blocked && dx > 0 && abs(dx) > abs(dy) * 1.5 ? .began : .failed
            if state == .failed { return }
        } else {
            state = .changed
        }
        let elapsed = touch.timestamp - last.time
        if elapsed > 0 { velocity = (point.x - last.point.x) / elapsed }
        last = (point, touch.timestamp)
        translation = dx
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .began || state == .changed ? .ended : .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    /// A button or tag under the finger takes the touch as it lands; a swipe that heads right
    /// afterwards still goes back.
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        !(preventing.view?.isDescendant(of: view ?? UIView()) ?? false) || preventing is UIPanGestureRecognizer
    }

    /// Scrolling views below wait to see whether this is a swipe back.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    /// Whether a view under the finger scrolls sideways and is not at its leading edge.
    private static func scrollsBack(from view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if let scroll = candidate as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1,
               scroll.contentOffset.x > -scroll.adjustedContentInset.left + 0.5 { return true }
            current = candidate.superview
        }
        return false
    }
}

/// A tap, and a double tap only when one is set. Two taps close together are the double tap; a
/// lone tap acts once the moment for a second one has passed. Timed here: paired tap gestures
/// on the card let the first tap act at once, so the double tap never arrived.
struct ThumbnailTaps: ViewModifier {
    let tap: () -> Void
    let doubleTap: (() -> Void)?
    @State private var waiting: Task<Void, Never>?
    static let interval: Duration = .milliseconds(300)

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                guard let doubleTap else { tap(); return }
                if let first = waiting {
                    first.cancel()
                    waiting = nil
                    doubleTap()
                    return
                }
                waiting = Task { @MainActor in
                    try? await Task.sleep(for: Self.interval)
                    guard !Task.isCancelled else { return }
                    waiting = nil
                    tap()
                }
            }
            .onDisappear { waiting?.cancel(); waiting = nil }
    }
}

private final class GalleryPaginationViewport {
    var footer: CGRect?
    var height: CGFloat = 0
}
private struct GalleryGridCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.artworkCellStyle) private var style
    @Environment(\.isDisplayedAppModeActive) private var modeActive
    @Environment(\.scenePhase) private var scenePhase
    private struct LoadKey: Hashable { let preview: ObjectIdentifier?; let active: Bool }
    let id: Int64
    let isBookmarked: Bool
    /// The website the work is listed from, when a list shows several.
    let site: String?
    let open: () -> Void
    /// Work information, for a gesture set to show it; opening is the fallback.
    let details: () -> Void
    let bookmark: (NativeGallery?) -> Void
    private let suppliedPreview: GalleryFeedPreview?
    @SwiftUI.AppStorage(ThumbnailGesture.doubleTap.key(), store: ReaderPreferences.defaults) private var doubleTapAction = ThumbnailGesture.doubleTap.standard().rawValue
    @State private var preview: GalleryFeedPreview
    private var gallery: NativeGallery? { preview.gallery }
    private var image: UIImage? { preview.displayImage }
    private var isQueued: Bool { env.readingQueue.contains(id) }
    private var queueItem: ReadingQueueItem {
        ReadingQueueItem(gallery: gallery, id: id, title: preview.display?.title, artists: preview.display?.artists,
                         language: preview.display?.language, type: preview.display?.type, site: site ?? (ComicSites.active.isEmpty ? nil : ComicSites.active))
    }
    /// Runs what Settings assigns to the gesture.
    private func perform(_ gesture: ThumbnailGesture) {
        switch gesture.action() {
        case .open: open()
        case .details: details()
        case .bookmark: bookmark(gallery)
        case .upNext:
            if isQueued { env.readingQueue.remove(id); UISelectionFeedbackGenerator().selectionChanged() } else { addToQueue() }
        case .favorite, .folder, .none: break
        }
    }
    private func addToQueue() {
        if env.readingQueue.add(queueItem, cover: image) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    init(id: Int64, preview: GalleryFeedPreview?, isBookmarked: Bool, source: any ContentProviding, images: PageImageStore, site: String? = nil,
         details: (() -> Void)? = nil, open: @escaping () -> Void, bookmark: @escaping (NativeGallery?) -> Void) {
        self.id = id
        self.site = site
        self.isBookmarked = isBookmarked
        self.suppliedPreview = preview
        self.open = open
        self.details = details ?? open
        self.bookmark = bookmark
        _preview = State(initialValue: preview ?? GalleryFeedPreview(id: id, source: source, images: images))
    }

    var body: some View {
        GalleryCardLayout(title: preview.display?.title ?? L10n.text("Work %@", String(describing: id)), artists: preview.display?.artists ?? "", language: preview.display?.language ?? "", type: preview.display?.type ?? "") {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: AppMode.manga.icon).foregroundStyle(.secondary) } }
        }
        .overlay(alignment: .topLeading) {
            if isBookmarked {
                Image(systemName: "bookmark.fill").font(.system(size: style.fontSize(14), weight: .semibold))
                    .foregroundStyle(.yellow).padding(style.inset(8)).background(.black.opacity(0.72), in: Circle())
                    .padding(style.inset(7)).accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isQueued {
                Image(systemName: "text.line.last.and.arrowtriangle.forward").font(.system(size: style.fontSize(12), weight: .semibold))
                    .foregroundStyle(.white).padding(style.inset(8)).background(.black.opacity(0.72), in: Circle())
                    .padding(style.inset(7)).accessibilityHidden(true).allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isQueued)
        .contentShape(Rectangle())
        .modifier(ThumbnailTaps(tap: { perform(.tap) }, doubleTap: ThumbnailAction(rawValue: doubleTapAction) == ThumbnailAction.none ? nil : { perform(.doubleTap) }))
        // Held and let go, the hold's chosen action runs; moved after the hold, the work is carried
        // down to the Up Next panel.
        .workHold(env.readingQueue, item: { queueItem }, cover: { image }, bookmark: { perform(.hold) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("content.gallery.\(id)")
        .accessibilityValue(isBookmarked ? L10n.text("Bookmarked") : L10n.text("Not bookmarked"))
        .accessibilityAction { perform(.tap) }
        .accessibilityAction(named: WorkSaveResult.actionTitle(saved: isBookmarked, mode: .comics)) { bookmark(gallery) }
        .accessibilityAction(named: L10n.text(isQueued ? "Remove from Up Next" : "Add to Up Next")) {
            if isQueued { env.readingQueue.remove(id) } else { addToQueue() }
        }
        .onAppear { preview.restoreCachedContent() }
        .task(id: LoadKey(preview: suppliedPreview.map(ObjectIdentifier.init), active: modeActive && scenePhase == .active)) {
            guard modeActive, scenePhase == .active else { return }
            if let suppliedPreview { preview = suppliedPreview }
            await preview.load()
        }
        .onDisappear {
            // Shared previews belong to the loader's bounded viewport window.
            // A lazy cell disappearing must not erase a prepared nearby cover.
            if suppliedPreview == nil { preview.discardDisplayContent() }
        }
    }
}

private struct RemoteGalleryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.discoveryContext) private var discovery
    let galleryID: Int64
    let source: any ContentProviding
    let images: PageImageStore
    @State private var gallery: NativeGallery?
    @State private var cover: UIImage?
    @State private var coverFinished = false
    @State private var error: String?
    @State private var retry = 0
    var read: (Int64, Int, DiscoveryContext, Bool) -> Void
    var follow: (ContentRoute) -> Void

    private var links: GalleryWorkLinks {
        GalleryWorkLinks(source: source,
            openVersion: { follow(.discoveredGallery($0, discovery)) },
            // A related work wasn't searched for, so it must not count as a match for this search.
            openRelated: { follow(MangaThumbnailOpening.stored().route(for: $0, context: DiscoveryContext(origin: .feed, session: discovery.session))) })
    }

    var body: some View {
        Group {
            if let gallery {
                GalleryWorkInformation(gallery: gallery, images: images, cover: cover, coverFinished: coverFinished,
                    read: { read(galleryID, 1, discovery, true) },
                    selectPage: { read(galleryID, $0 + 1, discovery, false) }, links: links)
            } else if let error { ContentFailureView(message: error) { retry += 1 } }
            else { ProgressView(L10n.text("Loading work details")) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(L10n.text("Work Details"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            error = nil
            do {
                let value = try await source.gallery(galleryID)
                try Task.checkCancellation()
                gallery = value
                try? env.database.observeTaste(value, context: discovery)
                if let page = value.pages.first {
                    let loaded = try? await images.load(page, galleryID: galleryID, thumbnail: true)
                    try Task.checkCancellation()
                    cover = loaded
                }
                coverFinished = true
            } catch { if !Task.isCancelled { self.error = ContentError.message(error) } }
        }
    }
}

/// Where a work's other languages and related works lead. Offline reading has none.
struct GalleryWorkLinks {
    let source: any ContentProviding
    let openVersion: (Int64) -> Void
    let openRelated: (Int64) -> Void
}

/// Explore, saved works and the viewer use the same work information sections.
/// The viewer omits only the cover and the action that would open another reader.
struct GalleryWorkInformation: View {
    @Environment(\.discoveryContext) private var discovery
    @Environment(AppEnvironment.self) private var env
    let gallery: NativeGallery
    let images: PageImageStore
    var cover: UIImage? = nil
    var coverFinished = true
    var showsCover = true
    var read: (() -> Void)? = nil
    let selectPage: (Int) -> Void
    var search: ((String) -> Void)? = nil
    var links: GalleryWorkLinks? = nil
    @State private var previewsEnabled = false
    @State private var bookmark: ContentBookmark?
    @State private var savedIDs = Set<Int64>()
    @State private var saveFeedback: WorkSaveFeedback?

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GalleryInformation(gallery: gallery, cover: cover, coverFinished: coverFinished,
                        showsCover: showsCover, read: read,
                        bookmark: { bookmark = ContentBookmark(id: gallery.id) }, search: search,
                        openVersion: links?.openVersion, savedIDs: savedIDs)
                        .onGeometryChange(for: Bool.self) { geometry in
                            GalleryPreviewLoading.shouldLoad(metadata: geometry.frame(in: .named("gallery.detailViewport")),
                                                             viewportHeight: viewport.size.height)
                        } action: { if $0 { previewsEnabled = true } }
                    GalleryDetailPreviews(gallery: gallery, images: images, enabled: previewsEnabled, select: selectPage)
                        .frame(minHeight: previewsEnabled ? nil : viewport.size.height, alignment: .topLeading)
                    if let links, previewsEnabled, gallery.relatedIDs?.isEmpty == false {
                        GalleryRelatedWorks(gallery: gallery, images: images, links: links, savedIDs: savedIDs, feedback: $saveFeedback)
                    }
                    MangaContentControls(gallery: gallery)
                }.padding(20)
            }
            .coordinateSpace(name: "gallery.detailViewport")
            .accessibilityIdentifier("content.detail.scroll")
        }
        .workSaveFeedback($saveFeedback, identifier: "content.toast")
        .appSheet(item: $bookmark) { target in
            AddWorkSheet(initialText: String(target.id)).environment(\.discoveryContext, discovery)
        }
        .task {
            guard links != nil else { return }
            do {
                let site = env.mangaSiteAddress
                let observation = ValueObservation.tracking { db in try SavedWorkKeys.fetch(db) }
                for try await keys in observation.values(in: env.database.dbWriter) { savedIDs = keys.ids(on: site) }
            } catch { /* Saved marks are a hint, so a dropped observation keeps the last ones. */ }
        }
    }
}

/// Five or so works sit better in a rail than in a grid set for browsing a whole feed.
private struct GalleryRelatedWorks: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.discoveryContext) private var discovery
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 132
    let gallery: NativeGallery
    let images: PageImageStore
    let links: GalleryWorkLinks
    let savedIDs: Set<Int64>
    @Binding var feedback: WorkSaveFeedback?
    @State private var ids: [Int64]?

    private var style: ArtworkCellStyle {
        ArtworkCellStyle(width: cardWidth, showsTitle: env.showsMangaTitles, showsArtists: env.showsMangaArtists, showsCategory: env.showsMangaCategories)
    }

    var body: some View {
        let visible = ids?.filter { !env.hiddenMangaGalleryIDs.contains($0) }
        Group {
            if visible?.isEmpty != true {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    Text(L10n.text("Related Works")).font(.headline)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            if let visible {
                                ForEach(visible, id: \.self) { id in
                                    GalleryGridCard(id: id, preview: nil, isBookmarked: savedIDs.contains(id), source: links.source, images: images, open: { links.openRelated(id) }) { work in
                                        feedback = .perform(galleryID: id) { try ContentBookmarkAction.toggle(id: id, gallery: work, env: env, images: images, context: discovery) }
                                    }.frame(width: cardWidth)
                                }
                            } else {
                                ForEach(0..<3, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: style.radius(12), style: .continuous).fill(Color.secondary.opacity(0.12))
                                        .aspectRatio(0.72, contentMode: .fit).frame(width: cardWidth)
                                }.accessibilityHidden(true)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                    .contentMargins(.horizontal, 20, for: .scrollContent).padding(.horizontal, -20)
                    .environment(\.artworkCellStyle, style)
                    .accessibilityIdentifier("content.detail.related")
                }
            }
        }
        .task(id: gallery.id) {
            let found = await RelatedWorks.load(for: gallery, source: links.source, hidden: env.hiddenMangaGalleryIDs, excluded: env.defaultExcludedTags)
            if !Task.isCancelled { ids = found }
        }
    }
}

/// Reading in your own language is usually the point of having versions at all.
private struct GalleryVersionSuggestion: View {
    let version: GalleryVersion
    let open: () -> Void
    var body: some View {
        let color = ArtworkTagCategory.language.color
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                Text(L10n.text("View in %@", version.displayName)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.bold()).opacity(0.6)
            }
            .foregroundStyle(color).padding(.horizontal, 14).padding(.vertical, 11)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier("content.detail.versionSuggestion")
    }
}

struct ReaderWorkInformationView: View {
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    let images: PageImageStore
    @Binding var current: Int
    let search: (String) -> Void
    var links: GalleryWorkLinks? = nil
    var body: some View {
        NavigationStack {
            GalleryWorkInformation(gallery: gallery, images: images, showsCover: false,
                selectPage: { current = $0; dismiss() }, search: search, links: links)
                .navigationTitle(L10n.text("Work Details")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        // Like work information over Explore, a swipe to the right closes it.
        .modifier(SheetSwipeBack(enabled: true, close: { dismiss() }))
        .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

private struct GalleryInformation: View {
    let gallery: NativeGallery
    let cover: UIImage?
    let coverFinished: Bool
    let showsCover: Bool
    let read: (() -> Void)?
    let bookmark: () -> Void
    let search: ((String) -> Void)?
    let openVersion: ((Int64) -> Void)?
    let savedIDs: Set<Int64>
    @Environment(AppEnvironment.self) private var env
    private var suggestion: GalleryVersion? {
        gallery.suggestedVersion(for: L10n.contentLanguage).flatMap { env.hiddenMangaGalleryIDs.contains($0.id) ? nil : $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showsCover { WorkDetailCover(image: cover, loading: !coverFinished) }
            GalleryDetailHeading(title: gallery.title, metadata: L10n.text("%@ · %@ · %@ pages", gallery.language, gallery.type, String(gallery.pages.count)))
            VStack(spacing: 11) {
                GalleryDetailActions(read: read, bookmark: bookmark)
                if let openVersion, let suggestion {
                    GalleryVersionSuggestion(version: suggestion) { openVersion(suggestion.id) }
                }
            }
            GalleryDetailMetadata(gallery: gallery, search: search, openVersion: openVersion, savedIDs: savedIDs)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GalleryDetailMetadata: View {
    @Environment(AppEnvironment.self) private var env
    let gallery: NativeGallery
    let search: ((String) -> Void)?
    let openVersion: ((Int64) -> Void)?
    let savedIDs: Set<Int64>
    @State private var favoriteArtists = Set<String>()
    @State private var favoriteError: String?
    @State private var savedTagQueries = Set<String>()
    /// Who made the work, what it comes from and who appears in it, each under its own heading
    /// before the language; the descriptive tags follow together, set apart by color.
    static let creditCategories: [ArtworkTagCategory] = [.group, .series, .character]
    static let tagCategories: [ArtworkTagCategory] = [.female, .male, .general, .metadata, .type]
    private var tagGroups: [ArtworkTagGroup] { ArtworkTagGroup.make(tags: gallery.tags) }
    private var credits: [ArtworkTagGroup] {
        let groups = tagGroups
        return Self.creditCategories.compactMap { category in groups.first { $0.category == category } }
    }
    private var tags: ArtworkTagGroup {
        let groups = tagGroups
        return .init(category: .general, tags: Self.tagCategories.flatMap { category in groups.first { $0.category == category }?.tags ?? [] })
    }
    private var artists: [String] {
        var seen = Set<String>()
        let tagged = ArtworkTagGroup.make(tags: gallery.tags).first { $0.category == .artist }?.tags.map { String($0.query.dropFirst("artist:".count)) } ?? []
        return (gallery.artists + tagged).filter { !MangaArtistFavorite.key($0).isEmpty && seen.insert(MangaArtistFavorite.key($0)).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Artists")).font(.headline)
                if artists.isEmpty { MetadataPlaceholder() }
                else {
                    FlowLayout(spacing: 6) {
                        ForEach(artists, id: \.self) { name in
                            MangaArtistTag(name: name, favorite: isFavorite(name), search: search) { saveTag(name, kind: .artist) }
                        }
                    }
                }
            }
            ForEach(credits) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(group.category.title)).font(.headline)
                    ArtworkTagCloud(groups: [group], headingStyle: .hidden,
                        destination: search == nil ? { .query($0.query.replacingOccurrences(of: " ", with: "_")) } : nil,
                        action: { search?($0.query.replacingOccurrences(of: " ", with: "_")) },
                        savedQueries: savedTagQueries,
                        save: { saveTag($0.query, kind: SavedCollectionKind(category: $0.category)) })
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Language")).font(.headline)
                if gallery.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MetadataPlaceholder() }
                else if let search {
                    Button { search("language:" + gallery.language.replacingOccurrences(of: " ", with: "_")) } label: { languageTag }
                        .buttonStyle(.plain).accessibilityIdentifier("content.detail.language")
                        .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in saveTag(gallery.language, kind: .language) })
                } else {
                    NavigationLink(value: ContentRoute.query("language:" + gallery.language)) { languageTag }
                        .buttonStyle(.plain).accessibilityIdentifier("content.detail.language")
                        .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in saveTag(gallery.language, kind: .language) })
                }
                // Other versions belong with the language, a step below it.
                if let openVersion, !versions.isEmpty {
                    Text(L10n.text("Other Languages")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    FlowLayout(spacing: 6) {
                        ForEach(versions) { version in
                            Button { openVersion(version.id) } label: { versionTag(version) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.text("Open the %@ version", version.displayName))
                                .accessibilityValue(savedIDs.contains(version.id) ? L10n.text("Bookmarked") : L10n.text("Not bookmarked"))
                                .accessibilityIdentifier("content.detail.version.\(version.id)")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SettingsHelpLabel("Tags", help: "Hold an artist or tag to add it to your favorites. Hold it again to remove it.").font(.headline)
                ArtworkTagCloud(groups: [tags], headingStyle: .hidden,
                    destination: search == nil ? { .query($0.query.replacingOccurrences(of: " ", with: "_")) } : nil,
                    action: { search?($0.query.replacingOccurrences(of: " ", with: "_")) },
                    savedQueries: savedTagQueries,
                    save: { saveTag($0.query, kind: SavedCollectionKind(category: $0.category)) })
            }
            GalleryWorkNumber(number: gallery.id)
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task { reloadSavedTags() }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } })) {
            Button(L10n.text("Done"), role: .cancel) { favoriteError = nil }
        } message: { Text(favoriteError ?? "") }
    }
    private var versions: [GalleryVersion] {
        gallery.otherVersions(preferring: L10n.contentLanguage).filter { !env.hiddenMangaGalleryIDs.contains($0.id) }
    }
    /// The chevron sets these apart from the language above, which searches instead of opening a work.
    private func versionTag(_ version: GalleryVersion) -> some View {
        HStack(spacing: 4) {
            if savedIDs.contains(version.id) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.yellow) }
            Text(version.displayName)
            Image(systemName: "chevron.right").font(.caption2.bold()).opacity(0.6)
        }.foregroundStyle(ArtworkTagCategory.language.color).modifier(ArtworkTagPill(color: ArtworkTagCategory.language.color))
    }
    private var languageSaved: Bool { savedTagQueries.contains(SavedCollectionKind.language.query(gallery.language, manga: true)) }
    private var languageTag: some View {
        HStack(spacing: 4) {
            if languageSaved { SavedTagStar(font: .body) }
            Text(gallery.language)
        }.foregroundStyle(ArtworkTagCategory.language.color).modifier(ArtworkTagPill(color: ArtworkTagCategory.language.color))
            .modifier(SavedTagResponse(saved: languageSaved))
    }
    private func isFavorite(_ name: String) -> Bool {
        favoriteArtists.contains { MangaArtistFavorite.key($0) == MangaArtistFavorite.key(name) }
    }
    private func reloadSavedTags() {
        let values = (try? env.database.listArtists()) ?? []
        favoriteArtists = Set(values.filter { $0.kind == 0 }.map(\.name))
        savedTagQueries = Set(values.compactMap { value in
            SavedCollectionKind.allCases.first { $0.mangaKind == value.kind }?.query(value.name, manga: true)
        })
    }
    private func saveTag(_ name: String, kind: SavedCollectionKind) {
        do {
            let saved = try env.database.toggleCollectionTag(name, kind: kind)
            reloadSavedTags(); SavedTagFeedback.notify(saved: saved)
        }
        catch { favoriteError = error.localizedDescription }
    }

}

enum MangaArtistFavorite {
    static func toggle(_ name: String, in database: AppDatabase) throws -> Set<String> {
        let artists = Set(try database.listArtists().filter { $0.kind == 0 }.map(\.name))
        let matching = artists.filter { key($0) == key(name) }
        if matching.isEmpty { _ = try database.addFavoriteArtist(name: name) }
        else { for artist in matching { try database.removeFavoriteArtist(name: artist, kind: 0) } }
        return Set(try database.listArtists().filter { $0.kind == 0 }.map(\.name))
    }
    static func key(_ name: String) -> String {
        SavedCollectionKind.identity(name)
    }
}

struct MetadataPlaceholder: View {
    @ScaledMetric(relativeTo: .body) private var lineHeight = 22
    var body: some View {
        Color.clear.frame(width: lineHeight, height: lineHeight).accessibilityHidden(true)
    }
}

struct GalleryWorkNumber: View {
    let number: Int64
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Number")).font(.headline)
            HStack {
                Button(action: copy) {
                    Text(String(number)).foregroundStyle(ArtworkTagCategory.general.color)
                        .modifier(ArtworkTagPill(color: ArtworkTagCategory.general.color))
                }.buttonStyle(.plain)
                    .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in copy() })
                    .accessibilityIdentifier("content.detail.workNumber")
                    .accessibilityHint(L10n.text("Hold to copy"))
                    .accessibilityAction(named: L10n.text("Copy"), copy)
                if copied { Label(L10n.text("Copied"), systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
            }

        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }
    private func copy() {
        UIPasteboard.general.string = String(number); copied = true
        WorkSaveFeedback.haptic(.added(.comics))
    }
}

private struct MangaArtistTag: View {
    let name: String
    let favorite: Bool
    let search: ((String) -> Void)?
    let saveFavorite: () -> Void
    @ScaledMetric(relativeTo: .body) private var starRoom: CGFloat = 26
    var body: some View {
        link
            .buttonStyle(.plain)
            .layoutValue(key: FlowReservedWidth.self, value: favorite ? 0 : starRoom)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in saveFavorite() })
            .accessibilityValue(L10n.text(favorite ? "Favorite Artist" : "Not a Favorite Artist"))
            .accessibilityAction(named: L10n.text(favorite ? "Remove from Artists" : "Add to Artists"), saveFavorite)
            .accessibilityIdentifier("content.detail.artist." + name)
    }
    @ViewBuilder private var link: some View {
        if let search {
            Button { search("artist:" + name.replacingOccurrences(of: " ", with: "_")) } label: { tag }
        } else { NavigationLink(value: ContentRoute.artist(name)) { tag } }
    }
    private var tag: some View {
        HStack(spacing: 4) {
            if favorite { SavedTagStar(font: .body) }
            Text(name.replacingOccurrences(of: "_", with: " "))
        }.foregroundStyle(ArtworkTagCategory.artist.color)
            .modifier(ArtworkTagPill(color: ArtworkTagCategory.artist.color))
            .modifier(SavedTagResponse(saved: favorite))
    }
}

struct GalleryDetailHeading: View {
    let title: String
    let metadata: String
    @State private var showTitle = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Reserve the same total height while keeping metadata immediately
            // below the actual title, including when it occupies just one line.
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.title2.bold()).lineLimit(2, reservesSpace: true)
                Text(metadata).font(.subheadline)
            }.hidden().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Button { showTitle = true } label: {
                    Text(title).font(.title2.bold()).lineLimit(2).truncationMode(.tail)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("content.detail.title")
                    .accessibilityHint(L10n.text("Show Full Title"))
                Text(metadata).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("content.detail.metadata")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .appSheet(isPresented: $showTitle) { GalleryFullTitle(title: title) }
    }
}

private struct GalleryFullTitle: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(title).font(.title2.bold()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                .navigationTitle(L10n.text("Title")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct GalleryDetailActions: View {
    let read: (() -> Void)?
    let bookmark: () -> Void
    @ScaledMetric(relativeTo: .headline) private var fontSize = 19.5
    var body: some View {
        VStack(spacing: 11) {
            if let read { GalleryActionHeight {
                Button(action: read) {
                    Label(L10n.text("Read"), systemImage: AppMode.manga.icon).font(.system(size: fontSize, weight: .bold)).imageScale(.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("content.read")
            } }
            GalleryActionHeight {
                Button(action: bookmark) {
                    Label(L10n.text("Save to Library"), systemImage: "bookmark").font(.system(size: fontSize, weight: .bold)).imageScale(.medium)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 8)
                }.buttonStyle(.bordered).accessibilityIdentifier("content.bookmark")
            }
        }
    }
}

/// Scale each system button's natural height, including its style and text size.
struct GalleryActionHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let button = subviews.first else { return .zero }
        let size = button.sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * 1.25)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .init(bounds.size))
    }
}

/// Drawn as the image viewer's Details list draws its Content Controls section, an inset grouped
/// list: the work information is a scroll view, so the list's look is drawn here.
private struct MangaContentControls: View {
    let gallery: NativeGallery
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// An inset grouped list's row: icons in a column, titles after it.
    private static let iconColumn: CGFloat = 56
    private func row(_ title: String, icon: String, color: Color = .accentColor, chevron: Bool = false) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: Self.iconColumn)
            Text(title).foregroundStyle(color).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
        .padding(.trailing, 16).frame(minHeight: 52).contentShape(Rectangle())
    }
    private var divider: some View { Divider().padding(.leading, Self.iconColumn).padding(.trailing, 16) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Content Controls")).foregroundStyle(.secondary).padding(.horizontal, 17)
            VStack(spacing: 0) {
                if let page = URL(string: MangaUrls.galleryUrl(for: gallery.id)) {
                    NavigationLink { ContentReportView(page: page) } label: {
                        row(L10n.text("Report Content"), icon: "flag", color: .primary, chevron: true)
                    }.accessibilityIdentifier("content.report")
                    divider
                }
                Button {
                    env.setMangaGalleryHidden(gallery.id, hidden: !env.hiddenMangaGalleryIDs.contains(gallery.id))
                    dismiss()
                } label: {
                    row(L10n.text(env.hiddenMangaGalleryIDs.contains(gallery.id) ? "Show This Work" : "Hide This Work"), icon: "eye.slash")
                }.accessibilityIdentifier("content.hideWork")
                if !gallery.artists.isEmpty {
                    divider
                    Menu {
                        ForEach(gallery.artists, id: \.self) { artist in
                            Button(artist) { env.blockMangaArtist(artist); dismiss() }
                        }
                    } label: {
                        row(L10n.text("Block Artist"), icon: "person.crop.circle.badge.xmark")
                    }.accessibilityIdentifier("content.blockArtist")
                }
            }.buttonStyle(.plain)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }.accessibilityIdentifier("content.controls")
    }
}

/// One observable cover per card: prefetch and visible cells share the same request and updates.
@MainActor @Observable
final class GalleryFeedPreview {
    struct Display: Equatable {
        let title: String
        let artists: String
        let language: String
        let type: String
        init(_ gallery: NativeGallery) {
            title = gallery.title
            artists = gallery.artists.joined(separator: ", ")
            language = gallery.language
            type = gallery.type
        }
    }
    let id: Int64
    private(set) var gallery: NativeGallery?
    private(set) var image: UIImage?
    private(set) var display: Display?
    @ObservationIgnored private let source: any ContentProviding
    @ObservationIgnored private let images: PageImageStore
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var waiters = Set<UUID>()
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var coverHash: String?

    init(id: Int64, source: any ContentProviding, images: PageImageStore) {
        self.id = id
        self.source = source
        self.images = images
        gallery = source.cachedPreview(id)
        display = gallery.map(Display.init)
        coverHash = gallery?.pages.first?.hash
        image = gallery?.pages.first.flatMap { images.cachedImage(hash: $0.hash, thumbnail: true) }
    }

    var displayImage: UIImage? {
        guard !cancelled else { return nil }
        return image ?? coverHash.flatMap { images.cachedImage(hash: $0, thumbnail: true) }
    }

    /// Reappearing rows can display an already decoded cover before an async
    /// task runs. Text layout survives even when both bounded caches evict it.
    func restoreCachedContent() {
        guard !cancelled else { return }
        if gallery == nil, let cached = source.cachedPreview(id) { setGallery(cached) }
        if image == nil, let coverHash { image = images.cachedImage(hash: coverHash, thumbnail: true) }
    }

    private func setGallery(_ gallery: NativeGallery) {
        self.gallery = gallery
        let display = Display(gallery)
        if self.display != display { self.display = display }
        coverHash = gallery.pages.first?.hash
    }

    func load() async {
        guard !cancelled, !Task.isCancelled else { return }
        restoreCachedContent()
        guard image == nil || gallery == nil else { return }
        let waiter = UUID()
        waiters.insert(waiter)
        let request = request ?? makeRequest()
        await withTaskCancellationHandler {
            defer { release(waiter) }
            await request.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(waiter) }
        }
    }

    private func makeRequest() -> Task<Void, Never> {
        let token = UUID()
        requestID = token
        let request = Task { [weak self] in
            guard let self else { return }
            defer { if self.requestID == token { self.request = nil } }
            do {
                let gallery: NativeGallery
                if let cached = self.gallery { gallery = cached }
                else { gallery = try await source.gallery(id) }
                try Task.checkCancellation()
                self.setGallery(gallery)
                if let page = gallery.pages.first {
                    let image = try await images.load(page, galleryID: id, thumbnail: true)
                    try Task.checkCancellation()
                    self.image = image
                }
            } catch { /* Keep metadata usable when a cover fails; detail provides an explicit retry. */ }
        }
        self.request = request
        return request
    }

    private func release(_ waiter: UUID) {
        guard waiters.remove(waiter) != nil else { return }
        // A visible cell and speculative lookahead can share a request. Stop it
        // only after both have left, including when SwiftUI cancels a lazy cell.
        if waiters.isEmpty { pause() }
    }

    func pause() {
        request?.cancel(); request = nil; requestID = UUID()
        waiters.removeAll()
    }

    func discardDisplayContent() {
        pause()
        // Release heavy content, but keep the small text projection so a row
        // above the viewport never collapses and grows when scrolling back.
        image = nil
        gallery = nil
    }

    func cancel() { cancelled = true; pause() }
}

/// Pagination completes as soon as IDs arrive. Cover prefetch never holds up the next page.
@MainActor @Observable
final class GalleryFeedLoader {
    private let source: any ContentProviding
    private let images: PageImageStore?
    private let startup: LaunchFeedWarmup?
    private var task: Task<Void, Never>?
    private(set) var previews: [FeedItem: GalleryFeedPreview] = [:]
    private struct CoverFlight { let token: UUID; let task: Task<Void, Never> }
    @ObservationIgnored private var prefetchTasks: [FeedItem: CoverFlight] = [:]
    @ObservationIgnored private var prefetchQueue: [FeedItem] = []
    @ObservationIgnored private var prefetchWindow: [FeedItem] = []
    @ObservationIgnored private var previousCoverIndex: Int?
    @ObservationIgnored private var retainedCoverIDs = Set<FeedItem>()
    @ObservationIgnored private var suspended = false
    /// The websites a combined list shows; nil while it shows the checked one.
    @ObservationIgnored private(set) var combinedSites: [String]?
    @ObservationIgnored private let combined: CombinedCatalog
    private var generation = UUID()
    private var nextOffset = 0
    private var currentQuery: GalleryQuery?
    private var currentSite: String?
    private var lastReset = true
    private(set) var items: [FeedItem] = []
    var ids: [Int64] { items.map(\.id) }
    private(set) var didLoad = false
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var error: String?

    init(source: any ContentProviding, images: PageImageStore? = nil, startup: LaunchFeedWarmup? = nil, combined: CombinedCatalog = CombinedCatalog()) {
        self.source = source
        self.images = images
        self.startup = startup
        self.combined = combined
    }

    private static var siteImages: [String: PageImageStore] = [:]

    /// The preview of a number in a list of one website, where a number names one work.
    func preview(_ id: Int64) -> GalleryFeedPreview? { previews.first { $0.key.id == id }?.value }

    /// The reader of a work's website: in a combined list, that website's own.
    func source(for item: FeedItem) -> any ContentProviding { combinedSites == nil ? source : SiteContent.for(item.site) }

    func images(for item: FeedItem) -> PageImageStore? {
        guard combinedSites != nil, images != nil else { return images }
        if let store = Self.siteImages[item.site] { return store }
        let store = PageImageStore(source: SiteContent.for(item.site))
        Self.siteImages[item.site] = store
        return store
    }

    /// Only the rows near the viewport merit speculation. Never drain a whole
    /// page of full gallery documents and covers just because its IDs arrived.
    func prioritizeCovers(startingAt index: Int, count: Int, columns: Int = 1) {
        guard !suspended, items.indices.contains(index), count > 0 else { return }
        let returning = previousCoverIndex.map { index < $0 } ?? false
        previousCoverIndex = index
        retainCovers(around: index, in: items)
        let end = index + min(returning ? max(1, min(columns, count)) : count, items.count - index)
        let start = returning ? max(0, end - count) : index
        prefetchWindow = returning ? Array(items[start..<end].reversed()) : Array(items[start..<end])
        for id in prefetchWindow { previews[id]?.restoreCachedContent() }
        let priority = Set(prefetchWindow)
        for (id, flight) in prefetchTasks where !priority.contains(id) { flight.task.cancel() }
        prefetchQueue = prefetchWindow.filter { previews[$0]?.image == nil && previews[$0] != nil }
        startPrefetch()
    }

    private func retainCovers(around index: Int, in items: [FeedItem]) {
        // Keep a bounded neighborhood above and below the viewport, independent
        // of the pagination cursor or current scroll direction.
        let start = min(max(0, index - 36), max(0, items.count - 72))
        let end = min(items.count, start + 72)
        let retained = Set(items[start..<end])
        for id in retainedCoverIDs.subtracting(retained) { previews[id]?.discardDisplayContent() }
        retainedCoverIDs = retained
    }

    private func startPrefetch() {
        guard !suspended, CoverQueuePolicy.allowsBackfill else { return }
        while prefetchTasks.count < 2,
              let index = prefetchQueue.firstIndex(where: { prefetchTasks[$0] == nil }) {
            let id = prefetchQueue.remove(at: index)
            guard let preview = previews[id], preview.image == nil else { continue }
            let token = UUID()
            let task = Task(priority: .utility) { [weak self] in
                await preview.load()
                guard let self, self.prefetchTasks[id]?.token == token else { return }
                self.prefetchTasks.removeValue(forKey: id)
                self.startPrefetch()
            }
            prefetchTasks[id] = CoverFlight(token: token, task: task)
        }
    }

    private func stopPrefetch(cancelCovers: Bool) {
        // Canceled work retains its slot until it actually finishes.
        for flight in prefetchTasks.values { flight.task.cancel() }
        prefetchQueue.removeAll()
        if cancelCovers { for preview in previews.values { preview.cancel() } }
    }

    /// `combinedSites` lists those websites together instead of the checked one. Without
    /// either it or `site`, the list goes on as it is.
    @discardableResult func load(_ query: GalleryQuery, reset: Bool, useLaunchPage: Bool = false, site: String? = nil, combinedSites: [String]? = nil) -> Task<Void, Never> {
        guard !suspended else { return Task {} }
        let combinedSites = (combinedSites == nil && site == nil ? self.combinedSites : combinedSites).flatMap { $0.count > 1 ? $0 : nil }
        let site = combinedSites.map { "*" + $0.joined(separator: ",") } ?? site ?? currentSite ?? MangaUrls.configuredHost
        if !reset, loading, currentQuery == query, let task { return task }
        task?.cancel()
        let changedQuery = currentQuery != query || currentSite != site
        if changedQuery {
            stopPrefetch(cancelCovers: true)
            prefetchWindow.removeAll()
            previousCoverIndex = nil
            retainedCoverIDs.removeAll()
            items = []; nextOffset = 0; hasMore = false; previews.removeAll(); didLoad = false
        }
        currentQuery = query
        currentSite = site
        self.combinedSites = combinedSites
        let reset = reset || changedQuery
        lastReset = reset
        let token = UUID()
        generation = token
        loading = true
        error = nil
        let offset = reset ? 0 : nextOffset
        let source = source
        let startup = combinedSites == nil ? startup : nil
        let combined = combined
        let request = Task { [weak self] in
            do {
                let batch: CombinedBatch
                if let combinedSites {
                    batch = try await combined.list(query, sites: combinedSites, offset: offset, count: 24)
                } else {
                    let single: GalleryBatch
                    if reset, useLaunchPage, let startup {
                        single = try await startup.mangaPage(query: query, site: site, initialConsumer: true)
                    } else {
                        if reset, let startup { await startup.invalidateManga(query: query, site: site) }
                        try Task.checkCancellation()
                        single = try await source.list(query, offset: offset, count: 24)
                    }
                    batch = CombinedBatch(items: single.ids.map { FeedItem(id: $0, site: site) }, hasMore: single.hasMore)
                }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                var seen = Set(reset ? [] : self.items)
                let incoming = batch.items.filter { seen.insert($0).inserted }
                let updated = (reset ? [] : self.items) + incoming
                if reset { self.stopPrefetch(cancelCovers: false) }
                // Keep identities/text for loaded rows and decoded covers near
                // the viewport, rather than only near the pagination cursor.
                if reset { self.previews = [:]; self.retainedCoverIDs.removeAll(); self.previousCoverIndex = nil }
                self.retainCovers(around: self.previousCoverIndex ?? max(0, updated.count - 1), in: updated)
                if self.images != nil {
                    for item in incoming {
                        if let images = self.images(for: item) { self.previews[item] = GalleryFeedPreview(id: item.id, source: self.source(for: item), images: images) }
                    }
                }
                self.items = updated
                self.didLoad = true
                if reset && useLaunchPage { startup?.didPublishManga(query: query, site: site) }
                self.nextOffset = offset + batch.items.count
                self.hasMore = batch.hasMore && !batch.items.isEmpty && (reset || !incoming.isEmpty)
                self.prefetchQueue = self.prefetchQueue.filter { self.retainedCoverIDs.contains($0) }
                self.startPrefetch()
            } catch {
                if !Task.isCancelled, let self, self.generation == token { self.error = ContentError.message(error) }
            }
            if let self, self.generation == token { self.loading = false }
        }
        task = request
        return request
    }

    @discardableResult func retry(_ query: GalleryQuery) -> Task<Void, Never> { load(query, reset: lastReset, combinedSites: combinedSites) }

    /// Hidden tabs keep their results, but stop downloading and decoding covers.
    func suspend() {
        suspended = true
        task?.cancel(); generation = UUID(); loading = false
        stopPrefetch(cancelCovers: false)
        for preview in previews.values { preview.pause() }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        // Restore the small viewport window, never all retained pages.
        prefetchQueue = prefetchWindow.filter { previews[$0] != nil && previews[$0]?.image == nil }
        startPrefetch()
    }

    func cancel() {
        task?.cancel(); generation = UUID(); loading = false
        stopPrefetch(cancelCovers: true)
    }
}
