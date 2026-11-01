import Foundation
import Observation

struct TasteShelf: Identifiable, Sendable {
    var plan: TasteShelfPlan
    var items: [TasteRecommendation]
    var id: String { plan.id }
}

/// A temporary lens over the feed. It never changes what the profile has learned.
struct TasteFocus: Equatable, Sendable {
    var seed: TasteTag
    var why: RecommendationWhy
}

/// Owned by the app, independently of tab/view lifetimes. Only explicit refresh
/// replaces an existing feed; pagination appends without changing its order.
@MainActor @Observable
final class TasteFeedState {
    private(set) var discoverySession = UUID().uuidString
    private(set) var initialized = false
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var snapshot: TasteSnapshot?
    private(set) var report: TasteReport?
    private(set) var results = TasteRecommendations()
    private(set) var error: String?
    var sortMessage: String?
    private(set) var pageVersion = 0
    private(set) var learning: TasteLearning?
    private(set) var shelves: [TasteShelf] = []
    private(set) var focus: TasteFocus?
    private(set) var starter = false
    private(set) var lastDismissed: TasteRecommendation?
    @ObservationIgnored private var shelfWork: Task<Void, Never>?
    @ObservationIgnored private var dismissedPosition: (deck: Int?, shelf: String?, index: Int)?
    private var appliedFocus: TasteFocus?
    private var activeSeeds: [String: [TasteTag]]?
    private var activePreferences: [String: RecommendationPreferences]?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var paginationWork: Task<Void, Never>?
    private var generation = UUID()
    private var shown: [String] = []
    private var seedOffset = -1
    let source: String?
    let sourceAddresses: [String]?
    private var appliedPreferences: [String: RecommendationPreferences]?
    private var previousSorts: [String: RecommendationSort] = [:]
    private func remember(_ items: [TasteRecommendation]) {
        let ids = Set(items.map(\.id))
        shown.removeAll { ids.contains($0) }
        shown += items.map(\.id)
        if shown.count > 2000 { shown.removeFirst(shown.count - 2000) }
    }
    @ObservationIgnored private let booruSource: any BooruProviding
    @ObservationIgnored private let comicSource: any ContentProviding
    init(source: String? = nil, sources: [String]? = nil, booruSource: any BooruProviding = TasteSources.booru, comicSource: any ContentProviding = TasteSources.comic) {
        self.source = source
        self.sourceAddresses = sources ?? source.map { [$0] }
        self.booruSource = booruSource; self.comicSource = comicSource
    }

    /// Project session access changes without replacing the recommendation
    /// deck, pagination cursor, or persisted taste evidence.
    func visibleItems(in store: BooruStore) -> [TasteRecommendation] {
        let hidden = store.confirmedGoldRestrictedIDs
        return hidden.isEmpty ? results.items : results.items.filter { $0.post.map { !hidden.contains($0.id) } ?? true }
    }
    func visibleShelves(in store: BooruStore) -> [TasteShelf] {
        let hidden = store.confirmedGoldRestrictedIDs
        return hidden.isEmpty ? shelves : shelves.map { shelf in
            var value = shelf; value.items.removeAll { $0.post.map { hidden.contains($0.id) } ?? false }
            return value
        }
    }

    /// "Not interested" leaves at once and teaches the next refresh; undo is exact.
    func dismiss(_ item: TasteRecommendation, mode: TasteMode, env: AppEnvironment) {
        try? env.taste.store(mode).record(signal: .dismissed, item: item.item)
        lastDismissed = item
        dismissedPosition = (results.items.firstIndex { $0.id == item.id }, nil, 0)
        results.items.removeAll { $0.id == item.id }
        for index in shelves.indices {
            if let position = shelves[index].items.firstIndex(where: { $0.id == item.id }) {
                dismissedPosition?.shelf = shelves[index].id; dismissedPosition?.index = position
                shelves[index].items.remove(at: position)
            }
        }
        pageVersion += 1
    }
    func undoDismiss(mode: TasteMode, env: AppEnvironment) {
        guard let item = lastDismissed else { return }
        try? env.taste.store(mode).record(signal: .restored, item: item.item)
        if let deck = dismissedPosition?.deck { results.items.insert(item, at: min(deck, results.items.count)) }
        if let shelf = dismissedPosition?.shelf, let index = shelves.firstIndex(where: { $0.id == shelf }) {
            shelves[index].items.insert(item, at: min(dismissedPosition?.index ?? 0, shelves[index].items.count))
        }
        lastDismissed = nil; dismissedPosition = nil; pageVersion += 1
    }
    func clearUndo() { lastDismissed = nil; dismissedPosition = nil }

    func setFocus(_ value: TasteFocus?, mode: TasteMode, env: AppEnvironment, language: String) {
        guard value != focus else { return }
        focus = value
        refresh(mode: mode, env: env, language: language)
    }

    func ensureLoaded(mode: TasteMode, env: AppEnvironment, language: String) {
        guard !initialized, env.taste.control.enabled else { return }
        refresh(mode: mode, env: env, language: language)
    }
    func clear() {
        cancelLoading()
        snapshot = nil; report = nil; results = .init(); error = nil; sortMessage = nil; appliedPreferences = nil; previousSorts = [:]
        learning = nil; shelves = []; focus = nil; appliedFocus = nil; activeSeeds = nil; activePreferences = nil; starter = false; lastDismissed = nil
        loading = false; loadingMore = false; initialized = false; shown = []; seedOffset = -1
    }
    func cancelLoading() {
        work?.cancel(); work = nil
        paginationWork?.cancel(); paginationWork = nil
        shelfWork?.cancel(); shelfWork = nil
        generation = UUID(); loading = false; loadingMore = false
        if snapshot == nil { initialized = false }
    }
    func applyExclusions(_ control: TasteControl, mode: TasteMode) {
        cancelLoading()
        if var filtered = snapshot {
            filtered.tags.removeAll { !control.allows($0.name, source: $0.source, mode: mode) }
            filtered.previousTagCounts = filtered.previousTagCounts.filter { key, _ in
                let parts = key.components(separatedBy: "\n")
                return parts.count == 2 && control.allows(parts[1], source: parts[0], mode: mode)
            }
            snapshot = filtered
        }
        let allowed = Set(snapshot?.tags.map(\.id) ?? [])
        report?.insights.removeAll { !allowed.contains($0.tagKey) }
    }

    func refresh(mode: TasteMode, env: AppEnvironment, language: String) {
        guard env.taste.control.enabled, mode == .comics || !(sourceAddresses ?? env.booru.selectedServers.map(\.canonicalAddress)).isEmpty else { return }
        paginationWork?.cancel(); paginationWork = nil
        shelfWork?.cancel(); shelfWork = nil
        work?.cancel(); let token = UUID(); generation = token
        discoverySession = UUID().uuidString
        seedOffset += 1
        let selection = seedOffset
        initialized = true; loading = true; loadingMore = false; error = nil
        work = Task {
            defer { if generation == token { loading = false; work = nil } }
            do {
                var value = try await env.taste.snapshot(mode, period: .recommendations, offset: 0)
                try Task.checkCancellation()
                guard generation == token else { return }
                let addresses = mode == .comics ? [MangaUrls.source] : sourceAddresses ?? env.booru.selectedServers.map(\.canonicalAddress)
                value.tags.removeAll { !addresses.contains($0.source) }
                let control = env.taste.control
                let preferences = Dictionary(uniqueKeysWithValues: addresses.map { ($0, control.preferences(source: $0)) })
                let wanted = focus
                let preferencesChanged = appliedPreferences != preferences || appliedFocus != wanted
                let model = try? await env.taste.learning(mode, hiddenComics: env.hiddenMangaGalleryIDs)
                try Task.checkCancellation()
                guard generation == token else { return }
                // Nothing learned yet: open with what is popular rather than an empty page.
                let cold = value.tags.isEmpty && wanted == nil
                let seeds = wanted.map { [$0.seed.source: [$0.seed]] } ?? (cold ? Dictionary(uniqueKeysWithValues: addresses.map { ($0, [TasteTag(source: $0, name: "")]) }) : nil)
                let effective = cold ? preferences.mapValues { value in var copy = value; copy.sort = .week; return copy } : wanted == nil ? preferences : preferences.mapValues { value in var copy = value; copy.sort = .recommended; return copy }
                let whyOverride = wanted?.why ?? (cold ? .popular : nil)
                let explanation = await StatisticalInsightService.report(snapshot: value, control: control, language: L10n.language, selectionOffset: selection)
                var batch = TasteRecommendations(); batch.cursor = preferencesChanged ? .init() : results.cursor
                let viewed = model?.seen ?? []
                var excluded = (preferencesChanged ? Set<String>() : Set(shown)).union(viewed)
                // Continue the deck before starting another cycle. On wrap, prefer
                // works outside the currently visible page; only a depleted deck repeats.
                for cycle in 0..<3 {
                    for _ in 0..<3 {
                        batch = try await RecommendationService.load(mode: mode, snapshot: value, report: explanation, env: env, language: language,
                            booruSource: booruSource, comicSource: comicSource, sourceAddress: source, sourceAddresses: sourceAddresses, preferencesOverride: effective, cursor: batch.cursor,
                            excluding: excluded, shuffled: true, seedOffset: selection, learning: model, seedOverride: seeds, whyOverride: whyOverride)
                        if batch.unsupportedSort || !batch.items.isEmpty || !batch.cursor.hasMore || !batch.failures.isEmpty { break }
                    }
                    if batch.unsupportedSort || !batch.items.isEmpty || batch.cursor.hasMore || !batch.failures.isEmpty || cycle == 2 { break }
                    batch.cursor = .init()
                    excluded = cycle == 0 ? Set(results.items.map(\.id)).union(viewed) : []
                }
                try Task.checkCancellation()
                guard generation == token, env.taste.control.enabled else { return }
                if batch.unsupportedSort {
                    env.taste.change { control in
                        for address in batch.unsupportedSources {
                            var reverted = preferences[address] ?? .init()
                            reverted.sort = appliedPreferences?[address]?.sort ?? .recommended
                            control.setPreferences(reverted, source: address)
                        }
                    }
                    sortMessage = L10n.text("This server does not support that sort. Your previous sort has been restored.")
                    if snapshot == nil { refresh(mode: mode, env: env, language: language) }
                    return
                }
                for (address, value) in preferences where value.sort != appliedPreferences?[address]?.sort { previousSorts[address] = appliedPreferences?[address]?.sort ?? .recommended }
                appliedPreferences = preferences; appliedFocus = wanted; activeSeeds = seeds; activePreferences = effective
                learning = model; starter = cold; lastDismissed = nil
                if cold { batch.failures = [] }
                if preferencesChanged { shown = [] }
                if preferences.values.allSatisfy({ $0.sort == .recommended }), batch.items.count > 1, batch.items.map(\.id) == results.items.map(\.id) {
                    batch.items.append(batch.items.removeFirst())
                }
                snapshot = value; report = explanation; results = batch; remember(batch.items); pageVersion += 1; loading = false
                if let model, wanted == nil, !cold, preferences.values.allSatisfy({ $0.sort == .recommended }) {
                    loadShelves(model, mode: mode, env: env, language: language, addresses: addresses, snapshot: value, preferences: preferences, selection: selection, token: token)
                } else { shelves = [] }
            } catch is CancellationError { }
            catch { if generation == token { self.error = L10n.text("Unable to update taste analysis.") } }
        }
    }
    func waitForRefresh() async { await work?.value }
    func waitForShelves() async { await shelfWork?.value }

    /// Filled after the main deck so a slow shelf can never hold the page. Requests
    /// stay bounded, and a shelf that finds too little simply does not appear.
    private func loadShelves(_ model: TasteLearning, mode: TasteMode, env: AppEnvironment, language: String, addresses: [String], snapshot: TasteSnapshot,
                             preferences: [String: RecommendationPreferences], selection: Int, token: UUID) {
        let slow = mode == .booru && env.booru.servers.contains { addresses.contains($0.canonicalAddress) && $0.engine.usesGelbooruPages }
        let plans = model.shelves(sources: addresses, tags: snapshot.tags, offset: selection, limit: slow ? 2 : 4)
        let keepsCurrent = Set(plans.map(\.id)) == Set(shelves.map(\.id))
        if !keepsCurrent { shelves = [] }
        var used = Set(results.items.prefix(16).map(\.id)).union(model.seen)
        shelfWork = Task {
            var built: [TasteShelf] = []
            for plan in plans {
                guard !Task.isCancelled, generation == token else { return }
                var scoped = preferences; scoped[plan.source]?.sort = .recommended
                guard let batch = try? await RecommendationService.load(mode: mode, snapshot: snapshot, report: nil, env: env, language: language, booruSource: booruSource, comicSource: comicSource,
                    sourceAddresses: [plan.source], preferencesOverride: scoped, excluding: used, shuffled: true, seedOffset: selection, requestTimeout: 15, learning: model, seedOverride: [plan.source: [plan.seed]], whyOverride: plan.why) else { continue }
                guard !Task.isCancelled, generation == token else { return }
                let items = Array(batch.items.prefix(12))
                guard items.count >= 3 else { continue }
                used.formUnion(items.map(\.id)); remember(items)
                built.append(.init(plan: plan, items: items))
                shelves = built
            }
            if built.isEmpty { shelves = [] }
        }
    }

    func loadMore(mode: TasteMode, env: AppEnvironment, language: String) async {
        guard !loading, !loadingMore, results.cursor.hasMore, let snapshot, env.taste.control.enabled else { return }
        loadingMore = true
        let token = generation, selection = seedOffset
        let task = Task { await appendPage(mode: mode, env: env, language: language, snapshot: snapshot, token: token, selection: selection) }
        paginationWork = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func appendPage(mode: TasteMode, env: AppEnvironment, language: String, snapshot: TasteSnapshot, token: UUID, selection: Int) async {
        defer { if token == generation { loadingMore = false; paginationWork = nil } }
        do {
            try Task.checkCancellation()
            guard token == generation else { return }
            var next = results.cursor
            var added: [TasteRecommendation] = []
            var failures: [String] = []
            // Skip a bounded number of pages containing only saved/filtered works.
            for _ in 0..<3 {
                let batch = try await RecommendationService.load(mode: mode, snapshot: snapshot, report: report, env: env, language: language,
                    booruSource: booruSource, comicSource: comicSource, sourceAddress: source, sourceAddresses: sourceAddresses, preferencesOverride: activePreferences ?? appliedPreferences, cursor: next, excluding: Set(shown).union(results.items.map(\.id)).union(learning?.seen ?? []), shuffled: true, seedOffset: selection, learning: learning, seedOverride: activeSeeds, whyOverride: focus?.why ?? (starter ? .popular : nil))
                try Task.checkCancellation()
                guard token == generation, env.taste.control.enabled else { return }
                if batch.unsupportedSort {
                    env.taste.change { control in
                        for address in batch.unsupportedSources {
                            var value = control.preferences(source: address); value.sort = previousSorts[address] ?? .recommended
                            control.setPreferences(value, source: address)
                        }
                    }
                    sortMessage = L10n.text("This server does not support that sort. Your previous sort has been restored.")
                    results.cursor.hasMore = false
                    return
                }
                next = batch.cursor; added = batch.items; failures = batch.failures
                if !added.isEmpty || !next.hasMore || !failures.isEmpty { break }
            }
            remember(added); results.items += added; results.cursor = next; results.failures = failures
            if !added.isEmpty { pageVersion += 1 }
        } catch is CancellationError { }
        catch { if generation == token { self.error = L10n.text("Unable to update taste analysis.") } }
    }
}
