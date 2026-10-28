import SwiftUI

struct BooruSavedView: View {
    let server: BooruServer
    let source: any BooruProviding
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    var body: some View {
        SavedCollectionsBrowser(database: env.database, booru: store, server: server, source: source)
            .navigationTitle(L10n.text("Tags")).navigationBarTitleDisplayMode(.inline)
    }
}

struct BooruPoolsView: View {
    @Environment(\.booruBrowsingMode) private var browsingMode
    let server: BooruServer
    let source: any BooruProviding
    var comicsMode = false
    @State private var text = ""
    @State private var query = ""
    @State private var pools: [BooruPool] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var reload = 0
    @State private var validating = false
    @State private var generation = UUID()
    var body: some View {
        List {
            if comicsMode {
                Section { ComicsConnectionCard().listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }
            Section {
                if server.engine.usesGelbooruPages { Text(L10n.text("Browse pools or enter a pool ID to open it.")).font(.footnote).foregroundStyle(.secondary) }
                ForEach(pools) { pool in
                    NavigationLink { BooruFeedView(server: server, source: source, pool: pool).environment(\.booruBrowsingMode, browsingMode) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(.tint).frame(width: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(pool.name.replacingOccurrences(of: "_", with: " ")).font(.headline).lineLimit(2)
                                Text(pool.hasKnownCount || pool.count > 0 ? "#\(pool.id) · " + L10n.text("%@ posts", String(pool.count)) : "#\(pool.id)").font(.caption).foregroundStyle(.secondary)
                                if !pool.description.isEmpty { Text(pool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }.padding(.vertical, 8)
                        }
                    }.accessibilityIdentifier("booru.pool.\(pool.id)")
                }
                if loading { ProgressView(L10n.text("Loading")) }
                else if let error {
                    ContentFailureView(message: error) { reload += 1 }
                    Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = true }
                }
                else if pools.isEmpty && !hasMore { ContentUnavailableView.search(text: query) }
                if hasMore && !loading && error == nil {
                    Button(L10n.text("Load More")) { Task { await load(reset: false) } }
                }
            }
        }.navigationTitle(comicsMode ? "" : L10n.text("Pools")).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, prompt: L10n.text(server.engine.usesGelbooruPages ? "Pool ID" : "Search Pools"))
            .onSubmit(of: .search) { query = text; reload += 1 }
            .onChange(of: text) { _, value in if value.isEmpty { query = "" } }
            .task(id: server.id + "|" + query + "|\(reload)") { await load(reset: true) }
            .refreshable { await load(reset: true) }
            .onReceive(NotificationCenter.default.publisher(for: .booruClientValidated)) { if $0.object as? String == server.id { reload += 1 } }
            .appSheet(isPresented: $validating) { BooruValidationView(server: server) }
    }
    private func load(reset: Bool) async {
        if !reset && loading { return }
        if reset { generation = UUID(); page = 0; pools = []; hasMore = true }
        let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            var scannedPages = 0
            repeat {
                let result = try await source.pools(server: server, query: query, page: page)
                try Task.checkCancellation()
                guard generation == current else { return }
                var seen = Set(pools.map(\.id))
                pools += result.filter { (!$0.hasKnownCount || $0.count > 0) && seen.insert($0.id).inserted }
                hasMore = result.count >= (server.engine.usesGelbooruPages ? 25 : 20)
                page += 1; scannedPages += 1
                if pools.isEmpty && hasMore && scannedPages < 5 { try await Task.sleep(for: .milliseconds(250)) }
            } while pools.isEmpty && hasMore && scannedPages < 5
        } catch { if !Task.isCancelled && generation == current { self.error = BooruConnectionMessage.describe(error) } }
    }
}

struct BooruSavedServersView: View {
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    var body: some View {
        Group {
            if store.selectedServers.isEmpty { BooruNoSelectionView() }
            else if store.selectedServers.count == 1, let server = store.selectedServer { BooruSavedView(server: server, source: source).id(server.id) }
            else {
                List(store.selectedServers) { server in
                    NavigationLink { BooruSavedView(server: server, source: source) } label: { Label(server.displayName, systemImage: "server.rack") }
                }
            }
        }.toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
    }
}

struct BooruPoolServersView: View {
    @Environment(\.booruBrowsingMode) private var browsingMode
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    var body: some View {
        List(store.selectedServers) { server in
            NavigationLink { BooruPoolsView(server: server, source: source).environment(\.booruBrowsingMode, browsingMode) } label: {
                Label(server.displayName, systemImage: "server.rack")
            }
        }.navigationTitle(L10n.text("Pools")).navigationBarTitleDisplayMode(.inline)
    }
}

/// Comics browsing falls back to ordered image pools until a comics site is connected.
struct ComicsPoolsView: View {
    @Environment(BooruStore.self) private var store
    private var source: any BooruProviding {
        #if DEBUG
        if BooruUITestSupport.enabled { return BooruUITestSupport.source }
        #endif
        return BooruClient.shared
    }
    var body: some View {
        Group {
            if store.selectedServers.isEmpty { BooruNoSelectionView() }
            else if store.selectedServers.count == 1, let server = store.selectedServer { BooruPoolsView(server: server, source: source, comicsMode: true).id(server.id) }
            else { BooruPoolServersView(source: source) }
        }.toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
            .environment(\.booruBrowsingMode, .manga)
    }
}
