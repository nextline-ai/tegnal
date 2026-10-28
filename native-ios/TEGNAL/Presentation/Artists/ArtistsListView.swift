import SwiftUI
import GRDB

public struct ArtistsListView: View {
    @Environment(AppEnvironment.self) private var env
    public init() {}
    public var body: some View {
        SavedCollectionsBrowser(database: env.database, booru: env.booru)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { AppModeSwitch() }
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Tags")) }
            }
    }
}

struct SavedCollectionEntry: Identifiable, Hashable {
    let kind: SavedCollectionKind
    let name: String
    var id: String { kind.rawValue + ":" + name }
}

private struct MangaCollectionSnapshot: Equatable {
    var tags: [ArtistMemo] = []
    var searches: [String] = []
    var history: [String] = []
    static func read(_ db: Database) throws -> Self {
        Self(tags: try ArtistMemo.order(ArtistMemo.Columns.name.asc).fetchAll(db),
             searches: try String.fetchAll(db, sql: "SELECT query FROM saved_searches ORDER BY query"),
             history: try String.fetchAll(db, sql: "SELECT query FROM search_history WHERE used_at >= ? ORDER BY used_at DESC", arguments: [SearchRetention.cutoff(booru: false)]))
    }
}

/// Both screens share presentation; all reads and writes keep their original mode's database.
@MainActor @Observable
final class SavedCollectionsModel {
    let database: AppDatabase
    let booru: BooruStore
    let server: BooruServer?
    private let preferences: UserDefaults
    private var manga = MangaCollectionSnapshot()
    private var orderRevision = 0
    var error: String?
    var notice: String?
    var noticeRevision = 0
    var isManga: Bool { server == nil }

    init(database: AppDatabase, booru: BooruStore, server: BooruServer? = nil, preferences: UserDefaults? = nil) {
        self.database = database; self.booru = booru; self.server = server
        self.preferences = preferences ?? (server == nil ? ReaderPreferences.defaults : ReaderPreferences.booruDefaults)
    }
    var sections: [SavedCollectionKind] {
        SavedCollectionKind.allCases.filter { [.tag, .artist, .series, .search, .history].contains($0) || !names($0).isEmpty }
    }
    func names(_ kind: SavedCollectionKind) -> [String] {
        _ = orderRevision
        let values: [String]
        if let server {
            values = kind == .history ? booru.history(serverID: server.id, limit: nil) : booru.savedTags(serverID: server.id, kind: kind.rawValue)
        } else {
            switch kind {
            case .search: values = manga.searches
            case .history: values = manga.history
            default: values = manga.tags.filter { $0.kind == kind.mangaKind }.map(\.name)
            }
        }
        return SavedCollectionOrdering.resolve(values, preferred: preferences.stringArray(forKey: orderKey(kind)) ?? [])
    }
    func refresh() throws {
        if isManga { manga = try database.dbWriter.read { try MangaCollectionSnapshot.read($0) } }
    }
    func observe() async {
        guard isManga else { return }
        do {
            let observation = ValueObservation.tracking { try MangaCollectionSnapshot.read($0) }
            for try await value in observation.removeDuplicates().values(in: database.dbWriter, bufferingPolicy: .bufferingNewest(1)) {
                try Task.checkCancellation(); manga = value
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func save(_ name: String, kind: SavedCollectionKind) {
        perform {
            let target: SavedCollectionKind = kind == .history ? .search : kind
            // Booru queries are literal site tags; namespaces are added only for comics.
            var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if isManga { value = target.normalized(value) }
            else if target != .search { value = value.replacingOccurrences(of: " ", with: "_") }
            guard !value.isEmpty else { return }
            if let server {
                if !booru.savedTags(serverID: server.id, kind: target.rawValue).contains(value) {
                    try booru.toggleTag(value, serverID: server.id, kind: target.rawValue)
                }
            } else { try database.saveCollectionTag(value, kind: target) }
            try refresh(); notice = L10n.text("Saved to Tags"); noticeRevision += 1
        }
    }
    func toggle(_ name: String, kind: SavedCollectionKind) {
        perform {
            let target: SavedCollectionKind = kind == .history ? .search : kind
            let saved: Bool
            if let server {
                saved = !booru.savedTags(serverID: server.id, kind: target.rawValue).contains(name)
                try booru.toggleTag(name, serverID: server.id, kind: target.rawValue)
            } else { saved = try database.toggleCollectionTag(name, kind: target) }
            try refresh(); SavedTagFeedback.notify(saved: saved)
            notice = L10n.text(saved ? "Saved to Tags" : "Removed from Tags"); noticeRevision += 1
        }
    }
    func reorder(_ kind: SavedCollectionKind, from: IndexSet, to: Int) {
        var values = names(kind)
        guard from.allSatisfy({ values.indices.contains($0) }), (0...values.count).contains(to) else { return }
        values.move(fromOffsets: from, toOffset: to)
        preferences.set(values, forKey: orderKey(kind)); orderRevision += 1
    }
    func remove(_ name: String, kind: SavedCollectionKind) {
        perform {
            if let server {
                if kind == .history { try booru.deleteSearch(name, serverID: server.id) }
                else if booru.savedTags(serverID: server.id, kind: kind.rawValue).contains(name) { try booru.toggleTag(name, serverID: server.id, kind: kind.rawValue) }
            } else {
                switch kind {
                case .history: try database.deleteSearch(name)
                case .search: if try database.savedSearches().contains(name) { try database.toggleSavedSearch(name) }
                default: if let code = kind.mangaKind { try database.removeFavoriteArtist(name: name, kind: code) }
                }
            }
            try refresh()
        }
    }
    func toggleSearch(_ name: String) {
        if names(.search).contains(name) { remove(name, kind: .search) } else { save(name, kind: .search) }
    }
    func clearHistory() {
        perform {
            if let server { try booru.clearHistory(serverID: server.id) } else { try database.clearSearchHistory() }
            try refresh()
        }
    }
    func move(_ source: String, to target: String, kind: SavedCollectionKind) {
        let current = names(kind)
        let changed = SavedCollectionOrdering.moved(current, source: source, target: target)
        guard changed != current else { return }
        preferences.set(changed, forKey: orderKey(kind)); orderRevision += 1
    }
    func move(_ entry: SavedCollectionEntry, direction: Int) {
        let values = names(entry.kind)
        guard let index = values.firstIndex(of: entry.name), values.indices.contains(index + direction) else { return }
        move(entry.name, to: values[index + direction], kind: entry.kind)
    }
    func query(_ entry: SavedCollectionEntry) -> String { entry.kind.query(entry.name, manga: isManga) }
    private func orderKey(_ kind: SavedCollectionKind) -> String {
        "collections.order." + (server.map { "booru." + $0.id } ?? "manga") + "." + kind.rawValue
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}

struct SavedCollectionsBrowser: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: SavedCollectionsModel
    @State private var name = ""
    @State private var kind = SavedCollectionKind.tag
    @State private var opened: SavedCollectionEntry?
    let source: any BooruProviding
    init(database: AppDatabase, booru: BooruStore, server: BooruServer? = nil, source: any BooruProviding = BooruClient.shared) {
        _model = State(initialValue: SavedCollectionsModel(database: database, booru: booru, server: server)); self.source = source
    }
    var body: some View {
        List {
            ForEach(model.sections) { section in
                SavedCollectionSection(model: model, kind: section, full: false, open: { opened = $0 })
            }
            Section(L10n.text("Save a Tag or Artist")) {
                Picker(L10n.text("Type"), selection: $kind) {
                    ForEach(SavedCollectionKind.allCases.filter { $0 != .history }) { Text(L10n.text($0.title)).tag($0) }
                }
                HStack {
                    TextField(L10n.text("Tag name"), text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier(model.isManga ? "manga.savedName" : "booru.savedName")
                        .onSubmit(add)
                    Button(L10n.text("Add"), action: add).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier(model.isManga ? "manga.saveTag" : "booru.saveTag")
                }
            }
        }.listStyle(.insetGrouped).environment(\.editMode, .constant(.active))
            .navigationDestination(for: SavedCollectionKind.self) { kind in SavedCollectionFullView(model: model, kind: kind, source: source) }
            .modifier(SavedCollectionResults(model: model, source: source, opened: $opened))
            .modifier(SavedCollectionFeedback(model: model))
            .task(id: env.mode == (model.isManga ? AppMode.manga : .booru) && scenePhase == .active) {
                guard env.mode == (model.isManga ? AppMode.manga : .booru), scenePhase == .active else { return }
                await model.observe()
            }
    }
    private func add() { model.save(name, kind: kind); if model.error == nil { name = "" } }
}

private struct SavedCollectionFullView: View {
    let model: SavedCollectionsModel
    let kind: SavedCollectionKind
    let source: any BooruProviding
    @State private var opened: SavedCollectionEntry?
    var body: some View {
        List { SavedCollectionSection(model: model, kind: kind, full: true, open: { opened = $0 }) }
            .listStyle(.insetGrouped).environment(\.editMode, .constant(.active)).navigationTitle(L10n.text(kind.title)).navigationBarTitleDisplayMode(.inline)
            .modifier(SavedCollectionResults(model: model, source: source, opened: $opened))
            .modifier(SavedCollectionFeedback(model: model))
    }
}

private struct SavedCollectionSection: View {
    let model: SavedCollectionsModel
    let kind: SavedCollectionKind
    let full: Bool
    let open: (SavedCollectionEntry) -> Void
    @State private var confirmClear = false
    var body: some View {
        let names = model.names(kind)
        Section {
            if names.isEmpty { Text(L10n.text("Nothing Saved Yet")).foregroundStyle(.secondary) }
            ForEach(full ? names : SavedCollectionOrdering.preview(names), id: \.self) { name in
                SavedCollectionRow(model: model, entry: .init(kind: kind, name: name), full: full, open: open)
            }.onMove { model.reorder(kind, from: $0, to: $1) }
            if !full && SavedCollectionOrdering.showsMore(names.count) {
                NavigationLink(value: kind) { Text(L10n.text("Show More")) }
                    .accessibilityIdentifier("collections.moreBottom." + kind.rawValue)
            }
        } header: {
            HStack {
                Text(L10n.text(kind.title))
                Text(String(names.count)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if kind == .history {
                    Button { confirmClear = true } label: { Image(systemName: "trash") }
                        .disabled(names.isEmpty).accessibilityLabel(L10n.text("Clear History"))
                }
            }
        }
        .alert(L10n.text("Clear History?"), isPresented: $confirmClear) {
            Button(L10n.text("Clear History"), role: .destructive) { model.clearHistory() }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Search history will be deleted. Saved searches will be kept.")) }
    }
}

private struct SavedCollectionRow: View {
    let model: SavedCollectionsModel
    let entry: SavedCollectionEntry
    let full: Bool
    let open: (SavedCollectionEntry) -> Void
    var body: some View {
        HStack(spacing: 10) {
            if full {
                rowButton.highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in model.toggle(entry.name, kind: entry.kind) })
            } else { rowButton }
            if entry.kind == .history {
                Button { model.toggleSearch(entry.name) } label: {
                    Image(systemName: model.names(.search).contains(entry.name) ? "star.fill" : "star")
                        .foregroundStyle(.yellow).frame(width: 32, height: 36)
                }.buttonStyle(.borderless).accessibilityLabel(L10n.text("Saved Searches"))
            }
        }
        .swipeActions { Button(L10n.text("Remove"), role: .destructive) { model.remove(entry.name, kind: entry.kind) } }
        .accessibilityAction(named: L10n.text("Move Up")) { model.move(entry, direction: -1) }
        .accessibilityAction(named: L10n.text("Move Down")) { model.move(entry, direction: 1) }
        .contextMenu { Button(L10n.text("Remove"), role: .destructive) { model.remove(entry.name, kind: entry.kind) } }
        .accessibilityAction(named: L10n.text("Save Tag")) { model.toggle(entry.name, kind: entry.kind) }
    }
    private var rowButton: some View {
        Button { open(entry) } label: {
            HStack {
                Label(entry.name.replacingOccurrences(of: "_", with: " "), systemImage: entry.kind.symbol)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("collections." + entry.id)
    }
}

private struct SavedCollectionResults: ViewModifier {
    let model: SavedCollectionsModel
    let source: any BooruProviding
    @Binding var opened: SavedCollectionEntry?
    func body(content: Content) -> some View {
        content
            .navigationDestination(item: Binding(get: { model.isManga ? nil : opened }, set: { opened = $0 })) { entry in
                if let server = model.server { BooruFeedView(server: server, source: source, initialQuery: model.query(entry)) }
            }
            .appFullScreenCover(item: Binding(get: { model.isManga ? opened : nil }, set: { opened = $0 })) { entry in
                ContentEntryView(initialUrl: mangaURL(model.query(entry)))
            }
    }
    private func mangaURL(_ query: String) -> String {
        var url = URLComponents(string: MangaUrls.home)!
        url.queryItems = [.init(name: "search", value: query)]
        return url.url!.absoluteString
    }
}

private struct SavedCollectionFeedback: ViewModifier {
    let model: SavedCollectionsModel
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    Text(notice).font(.subheadline).padding(12).background(.regularMaterial, in: Capsule()).padding(.bottom, 20)
                }
            }
            .task(id: model.noticeRevision) {
                guard model.notice != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); model.notice = nil } catch {}
            }
            .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button(L10n.text("Done"), role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

extension SavedCollectionKind {
    var symbol: String {
        switch self {
        case .tag: "tag"
        case .artist: "person"
        case .series: "books.vertical"
        case .character: "person.crop.square"
        case .group: "person.2"
        case .language: "globe"
        case .type: "square.stack"
        case .female, .male: "person.text.rectangle"
        case .metadata: "info.circle"
        case .search: "star"
        case .history: "clock"
        }
    }
    init(category: ArtworkTagCategory) {
        switch category {
        case .general: self = .tag
        default: self = Self(rawValue: category.rawValue) ?? .tag
        }
    }
}

@MainActor enum SavedTagFeedback {
    static func notify(saved: Bool) {
        WorkSaveFeedback.haptic(saved ? .added(.comics) : .removed(.comics))
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: L10n.text(saved ? "Saved to Tags" : "Removed from Tags"))
        }
    }
}
