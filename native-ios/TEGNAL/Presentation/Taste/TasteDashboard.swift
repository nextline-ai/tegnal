import SwiftUI
import GRDB

struct TasteDashboard: View {
    let mode: TasteMode
    var comicLanguage: String = L10n.contentLanguage
    var isRoot = false
    var explore: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var bookmarks = Set<Int64>()
    @State private var saveFeedback: WorkSaveFeedback?
    @State private var opened: TasteRecommendation?
    @State private var explaining: TasteRecommendation?
    @State private var openedShelf: TasteRecommendation?
    @State private var comicPrefetchTask: Task<Void, Never>?
    @State private var prefetchAnchor: Int?
    @State private var viewportWidth: CGFloat = 390
    private var sources: [String] { mode == .comics ? [MangaUrls.source] : env.booru.selectedServers.map(\.canonicalAddress) }
    private var source: String { sources.first ?? "" }
    private var isActiveMode: Bool { env.mode == (mode == .booru ? .booru : .manga) }
    private var feed: TasteFeedState { env.taste.feed(mode, sources: sources) }
    private var lookahead: Int {
        let count = typeSize.isAccessibilitySize ? 1 : env.gridColumns(for: mode == .booru ? .booru : .manga)
        return (count == 0 ? 2 : count) * 2
    }

    var body: some View {
        let layout = ArtworkGridGeometry(width: viewportWidth,
            columns: typeSize.isAccessibilitySize ? 1 : env.gridColumns(for: mode == .booru ? .booru : .manga),
            removesPadding: env.removesGridPadding(for: mode == .booru ? .booru : .manga))
        ScrollViewReader { scrollProxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !sources.isEmpty, env.taste.control.enabled, !picks.isEmpty {
                    SmartPicksView(items: picks, open: { opened = $0 }, toggle: toggle, bookmarks: bookmarks, feedback: feedback, inset: layout.margin - 20).padding(.bottom, SmartSpacing.section)
                }
                if env.taste.control.enabled, feed.focus == nil { RecapEntryCard(mode: mode).padding(.horizontal, layout.margin - 20).padding(.bottom, SmartSpacing.section) }
                if !sources.isEmpty, env.taste.control.enabled {
                    SmartSteering(feed: feed, refresh: refresh, focus: setFocus).padding(.bottom, SmartSpacing.section)
                    ForEach(feed.visibleShelves(in: env.booru)) { shelf in
                        if !shelf.items.isEmpty {
                            SmartShelfView(shelf: shelf, open: { openedShelf = $0 }, toggle: toggle, bookmarks: bookmarks, feedback: feedback).padding(.bottom, SmartSpacing.section)
                        }
                    }
                }
                if sources.isEmpty { BooruNoSelectionView() }
                else if !env.taste.control.enabled { paused }
                else {
                    VStack(alignment: .leading, spacing: SmartSpacing.heading) {
                        if let failure = feed.error { message(failure, icon: "wifi.exclamationmark", action: "Try Again", perform: refresh) }
                        if let snapshot = feed.snapshot, snapshot.tags.isEmpty { gettingStarted }
                        if !gridItems.isEmpty || sources.count > 1 { feedHeader }
                        if let snapshot = feed.snapshot {
                            if !snapshot.tags.isEmpty || !feed.results.items.isEmpty { works }
                        } else if feed.loading {
                            SmartLoadingView()
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, SmartSpacing.section)
            .frame(maxWidth: env.removesGridPadding(for: mode == .booru ? .booru : .manga) ? .infinity : 960)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(TastePresentation.accent)
        .navigationTitle(isRoot ? "" : L10n.text("Taste Analysis"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AppToolbarActions {
                    if mode == .booru { BooruServerMenu(compact: true) }
                    NavigationLink { TasteSettingsView(mode: mode, source: source, tuner: .init(feed: feed, refresh: refresh)) } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(L10n.text("Settings")).accessibilityIdentifier("taste.settings")
                }
            }
            if isRoot {
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Smart")) }
                ToolbarItem(placement: .principal) { AppModeSwitch() }
            }
        }
        .accessibilityIdentifier("taste.dashboard")
        .task(id: "\(mode):\(isActiveMode):\(scenePhase)") {
            guard mode == .comics, isActiveMode, scenePhase == .active else { return }
            let observation = ValueObservation.tracking { db in Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works")) }.removeDuplicates()
            do { for try await ids in observation.values(in: env.database.dbWriter, bufferingPolicy: .bufferingNewest(1)) { bookmarks = ids } } catch { }
        }
        .transientMessage(Binding(get: { feed.sortMessage }, set: { feed.sortMessage = $0 }))
        .overlay(alignment: .bottom) {
            if let item = feed.lastDismissed {
                SmartUndoBar(undo: { feed.undoDismiss(mode: mode, env: env) }, close: { feed.clearUndo() }).id(item.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: feed.lastDismissed?.id)
        .appSheet(item: $explaining) { item in
            RecommendationWhyView(item: item, mode: mode, feed: feed, refresh: refresh, moreLikeThis: { moreLikeThis(item) })
        }
        .tasteWorkPresentation($openedShelf) { .recommended($0.reason.name, session: feed.discoverySession) }
        .workSaveFeedback($saveFeedback, identifier: "taste.saveStatus")
        .onChange(of: sources) { _, _ in ensureLoaded() }
        .onChange(of: env.booruSearchRevision) { _, _ in
            if mode == .booru { feed.clear(); ensureLoaded() }
        }
        .onAppear { ensureLoaded() }
        // Picking works takes a while; it carries on when another tab or mode is shown and is
        // ready on return. Only covers prefetched for the screen stop.
        .onDisappear { cancelPrefetch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ensureLoaded() }
            else { cancelPrefetch(); feed.cancelLoading() }
        }
        .onChange(of: env.mode) { _, _ in
            if isActiveMode { ensureLoaded() }
            else { cancelPrefetch() }
        }
        .onChange(of: feed.discoverySession) { _, _ in cancelPrefetch() }
        .onChange(of: env.booru.confirmedGoldRestrictedIDs) { _, _ in cancelPrefetch() }
        .onChange(of: env.taste.control.enabled) { _, enabled in if enabled { ensureLoaded() } }
        .refreshable { refresh(); await feed.waitForRefresh() }
        .tasteWorkPresentation($opened, feed: feed, willClose: { viewed in
            let items = feed.visibleItems(in: env.booru)
            guard BooruViewerReturn.targetID(openedID: opened?.post?.id, viewedID: viewed.id, availableIDs: items.lazy.compactMap { $0.post?.id }) != nil,
                  let target = items.first(where: { $0.post?.id == viewed.id }) else { return }
            BooruViewerReturn.scroll(to: target.id, using: scrollProxy)
        }, willCloseManga: { viewed in
            guard opened?.item.source == MangaUrls.source, opened?.item.id != viewed,
                  !env.hiddenMangaGalleryIDs.contains(viewed),
                  let target = feed.visibleItems(in: env.booru).first(where: { $0.item.source == MangaUrls.source && $0.item.id == viewed }) else { return }
            BooruViewerReturn.scroll(to: target.id, using: scrollProxy)
        }) { .recommended($0.reason.name, session: feed.discoverySession) }
        }
    }

    private var gridItems: [TasteRecommendation] { feed.visibleItems(in: env.booru) }
    /// Only a personal ranking can pick. A chosen sort keeps its own order.
    private var picks: [TasteRecommendation] {
        let items = gridItems
        guard items.count >= 6, !feed.starter, feed.focus == nil, sources.allSatisfy({ env.taste.control.preferences(source: $0).sort == .recommended }) else { return [] }
        let key = "taste.todayPicks." + mode.rawValue
        let stored = ReaderPreferences.defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TodayPicks.Stored.self, from: $0) }
        let chosen = TodayPicks.choose(from: items, stored: stored, today: TodayPicks.day(Date()))
        // Remember the day's picks once; later renders read them back unchanged.
        if chosen.stored != stored, let data = try? JSONEncoder().encode(chosen.stored) { ReaderPreferences.defaults.set(data, forKey: key) }
        return chosen.picks
    }
    private var feedback: RecommendationFeedback {
        .init(why: { explaining = $0 }, more: moreLikeThis, dismiss: { item in feed.dismiss(item, mode: mode, env: env) })
    }
    private func setFocus(_ focus: TasteFocus?) { feed.setFocus(focus, mode: mode, env: env, language: comicLanguage) }
    private func moreLikeThis(_ item: TasteRecommendation) {
        let names = item.factors.filter { $0.kind == .tag }.map(\.name), fallback = (item.rankingTags ?? []).sorted()
        let chosen = Array((names + fallback).uniqued.prefix(2))
        guard let first = chosen.first else { return }
        setFocus(.init(seed: .init(source: item.item.source, name: chosen.joined(separator: " "), general: 1), why: .similar(first)))
    }
    /// One title with the feed's controls beside it. Several servers keep a row each.
    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.text(feed.starter ? "Popular now" : "For you")).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.8).accessibilityAddTraits(.isHeader)
                    Text(feedDescription).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if sources.count == 1 { RecommendationFilters(mode: mode, source: source, onChange: refresh, compact: true) }
            }
            if sources.count > 1, mode == .booru {
                ForEach(env.booru.selectedServers) { server in
                    HStack {
                        Text(server.displayName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        RecommendationFilters(mode: mode, source: server.canonicalAddress, onChange: refresh, compact: true)
                    }
                }
            }
        }
    }
    private var feedDescription: String {
        if let focus = feed.focus { return focus.why.sentence }
        return feed.starter ? RecommendationWhy.popular.sentence : L10n.text("Chosen from what you've been saving and viewing.")
    }
    private var gettingStarted: some View {
        TasteSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("Start with something you love")).font(.title3.bold())
                Text(L10n.text("Every save teaches your feed.")).font(.subheadline).foregroundStyle(.secondary)
                if let explore {
                    Button(action: explore) { Text(L10n.text("Explore works")).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).tint(TastePresentation.accent).accessibilityIdentifier("taste.startExploring")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("taste.empty")
    }
    private var paused: some View {
        message(L10n.text("Taste analysis is paused on your devices."), icon: "pause.circle", action: "Enable Taste Analysis") { env.taste.change { $0.enabled = true } }
    }
    private func message(_ text: String, icon: String, action: String, perform: @escaping () -> Void) -> some View {
        TasteSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text(action), action: perform).font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(TastePresentation.accent)
            }
        }
    }
    private var works: some View {
        let items = feed.visibleItems(in: env.booru), picked = Set(picks.map(\.id))
        let servers = Dictionary(env.booru.servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = env.booru.favoriteIDs, control = env.taste.control
        return Group {
            if !items.isEmpty {
                let prefetchThresholdIndex = max(0, items.count - lookahead)
                ArtworkGrid(mode: mode == .booru ? .booru : .manga, surroundingPadding: 20, topMarginScale: 0.5) { _ in
                    ForEach(Array(items.enumerated()).filter { !picked.contains($0.element.id) }, id: \.element.id) { index, item in
                        TasteRecommendationCard(item: item, open: { opened = item }, toggle: { toggle(item) }, isBookmarked: bookmarks.contains(item.item.id), feedback: feedback,
                                                server: item.post.flatMap { servers[$0.serverID] }, isFavorite: item.post.map { favorites.contains($0.id) } ?? false, control: control)
                            .id(item.id)
                            .onAppear {
                                guard isActiveMode, scenePhase == .active else { return }
                                if index >= prefetchThresholdIndex && feed.results.failures.isEmpty && feed.results.cursor.hasMore && !feed.loading && !feed.loadingMore {
                                    Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) }
                                }
                                prefetchRecommendations(around: index)
                            }
                    }
                }
            } else if feed.loading {
                SmartLoadingView()
            } else if feed.results.failures.isEmpty && !feed.results.cursor.hasMore {
                message(L10n.text("You're all caught up. Explore more works or refresh for new recommendations."), icon: "checkmark.circle", action: explore == nil ? "Try Again" : "Explore works") { if let explore { explore() } else { refresh() } }
            }
            if feed.loading && !items.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if feed.results.cursor.hasMore && !feed.loading && feed.snapshot != nil {
                if feed.results.failures.isEmpty {
                    Button {
                        Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) }
                    } label: {
                        Group { if feed.loadingMore { ProgressView() } else { Text(L10n.text("Continue browsing")) } }
                            .frame(maxWidth: .infinity).padding()
                    }.disabled(feed.loadingMore)
                        .accessibilityIdentifier("taste.loadMore")
                }
            } else if !feed.loading && !items.isEmpty {
                Text(L10n.text("You've reached the end of these recommendations.")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
            }
            if !feed.results.failures.isEmpty {
                message(L10n.text("Some sources could not be loaded: %@", feed.results.failures.joined(separator: ", ")), icon: "wifi.exclamationmark", action: "Try Again") { Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) } }
            }
        }
    }
    private func prefetchRecommendations(around index: Int) {
        guard isActiveMode, scenePhase == .active, CoverQueuePolicy.allowsBackfill else { return }
        if let anchor = prefetchAnchor, abs(index - anchor) < 4 { return }
        prefetchAnchor = index
        let items = feed.visibleItems(in: env.booru)
        let lookaheadEnd = min(items.count, index + lookahead + 1)
        guard index + 1 < lookaheadEnd else { return }
        let upcoming = Array(items[(index + 1)..<lookaheadEnd])
        let booruTargets = upcoming.compactMap { item -> (URL, BooruServer)? in
            guard let post = item.post,
                  let url = post.previewURL ?? post.sampleURL,
                  let server = env.booru.servers.first(where: { $0.id == post.serverID }) else { return nil }
            return (url, server)
        }
        BooruThumbnailCache.shared.prefetch(booruTargets)
        let comicGalleries = upcoming.compactMap { $0.gallery }
        if !comicGalleries.isEmpty {
            comicPrefetchTask?.cancel()
            comicPrefetchTask = Task(priority: .utility) {
                for gallery in comicGalleries {
                    guard !Task.isCancelled, CoverQueuePolicy.allowsBackfill else { break }
                    if let page = gallery.pages.first {
                        _ = try? await TasteSources.images.load(page, galleryID: gallery.id, thumbnail: true)
                    }
                }
            }
        }
    }

    private func cancelPrefetch() {
        comicPrefetchTask?.cancel(); comicPrefetchTask = nil; prefetchAnchor = nil
    }

    private func ensureLoaded() {
        guard isActiveMode, scenePhase == .active else { return }
        feed.ensureLoaded(mode: mode, env: env, language: comicLanguage)
    }

    private func toggle(_ item: TasteRecommendation) {
        saveFeedback = .perform(galleryID: item.item.id) { try TasteRecommendationAction.toggle(item, env: env, session: feed.discoverySession) }
    }
    private func refresh() { feed.refresh(mode: mode, env: env, language: comicLanguage) }
}
