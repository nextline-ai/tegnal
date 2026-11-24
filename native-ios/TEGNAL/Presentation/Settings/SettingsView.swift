import SwiftUI
import GRDB
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showConnection = false
    public init() {}
    public var body: some View {
        SettingsHome(booru: false) {
            // The website comes first, as an account does in the system Settings app.
            if env.comicSites.isEmpty {
                Button { showConnection = true } label: {
                    Label { Text(L10n.text("Website Connection")).foregroundStyle(.primary) } icon: { SettingsIconTile(symbol: "globe", tint: .blue) }
                }.accessibilityIdentifier("settings.connection")
            } else {
                NavigationLink { ComicSitesView() } label: {
                    LabeledContent { Text(env.mangaSiteAddress).lineLimit(1) } label: {
                        Label { Text(L10n.text("Website Connection")) } icon: { SettingsIconTile(symbol: "globe", tint: .blue) }
                    }
                }.accessibilityIdentifier("settings.connection")
            }
        }
        .onAppear { env.presentDiscordInvitationIfDue() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Settings")) }
        }
        .appSheet(isPresented: $showConnection) { WebsiteConnectionEditor(server: nil, initialAddress: env.isSiteVerified ? env.mangaSiteAddress : "") }
    }
}

/// All unconnected modes use the same neutral website connection flow.
struct ComicsSetupView: View {
    var body: some View {
        WebsiteSetupView(connectionIdentifier: "comics.enterAddress", mangaImportIdentifier: "comics.importMangaViewer")
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("comics.setup")
    }
}

/// The connected comics websites: tap one to use it, swipe to remove it, or add another.
struct ComicSitesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var adding = false
    @State private var ordering = false
    @State private var editing: String?
    var body: some View {
        List {
            Section {
                ForEach(env.comicSites, id: \.self) { site in
                    HStack {
                        // Picks the websites lists show together, as the Explore menu does: several, or none.
                        // The check sits before the name, as image servers show theirs.
                        Button { env.toggleListedComicSite(site) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: env.listedComicSites.contains(site) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                Text(site).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(env.listedComicSites.contains(site) ? .isSelected : [])
                        .accessibilityIdentifier("settings.site.\(site)")
                        // Each website keeps its own account and check, like an image server.
                        Button { editing = site } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("Website Settings") + " " + site)
                            .accessibilityIdentifier("settings.site.settings.\(site)")
                    }
                    .swipeActions { Button(L10n.text("Delete"), role: .destructive) { env.removeComicsSite(site) } }
                }
            } footer: {
                Text(L10n.text("Lists and searches show the checked websites together, as the Explore menu picks them. Saved works remember where they were saved, and a website that numbers its works the same way can open them too."))
            }
            if env.comicSites.count > 1 {
                Section {
                    Button { ordering = true } label: { Label(L10n.text("Website Priority"), systemImage: "arrow.up.arrow.down") }
                        .accessibilityIdentifier("settings.sitePriority")
                } footer: {
                    Text(L10n.text("When lists show several websites, a work they share shows from the one higher in this order. Saved works open from the checked website first, then in this order."))
                }
            }
            Section {
                Button { adding = true } label: { Label(L10n.text("Add Website"), systemImage: "plus") }
                    .accessibilityIdentifier("settings.addSite")
            }
        }
        .navigationTitle(L10n.text("Website Connection")).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { site in ComicSiteSettingsView(site: site) }
        .appSheet(isPresented: $adding) { WebsiteConnectionEditor(server: nil) }
        .appSheet(isPresented: $ordering) { SitePriorityView() }
    }
}

/// Drags the connected websites into the order lists prefer them in.
struct SitePriorityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [String] = []
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sites, id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            if env.listedComicSites.contains(site) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .onMove { from, to in sites.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text(L10n.text("When lists show several websites, a work they share shows from the one higher in this order. Saved works open from the checked website first, then in this order."))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L10n.text("Website Priority")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) { env.reorderComicSites(sites); dismiss() }.accessibilityIdentifier("settings.sitePriority.save")
                }
            }
            .onAppear { sites = env.comicSites }
        }
    }
}

struct ComicsConnectionCard: View {
    @State private var showConnection = false
    @SwiftUI.AppStorage(MangaThumbnailOpening.preferenceKey, store: ReaderPreferences.defaults) private var showsInformationBeforeReading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Connect a Website")).font(.headline).accessibilityIdentifier("comics.connectionCard")
            Button { showConnection = true } label: {
                Label(L10n.text("Enter Website Address"), systemImage: "link")
            }.buttonStyle(.borderedProminent).accessibilityIdentifier("comics.enterAddress")
            WebsiteImportLinks(mangaImportIdentifier: "comics.importMangaViewer").font(.subheadline)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            .appSheet(isPresented: $showConnection) { WebsiteConnectionEditor(server: nil) }
    }
}


struct MangaLibraryToolsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var worksCount = 0
    @State private var catalogCount = 0
    @State private var missingCount = 0
    @State private var isExporting = false
    @State private var confirmingRefresh = false



    var body: some View {
        List {
            LibraryMaintenanceLinks()
            LibraryBackupSection(busy: $isExporting, onRestore: loadStats)
            Group {
                Section(header: Text(L10n.text("Library Status"))) {
                    LabeledContent(L10n.text("Saved Works"), value: L10n.text("%@ items", String(describing: worksCount)))
                    LabeledContent(L10n.text("Catalog Matches"), value: L10n.text("%@ items", String(describing: catalogCount)))
                    LabeledContent(L10n.text("Missing Titles"), value: L10n.text("%@ items", String(describing: missingCount)))
                }

                Section(header: Text(L10n.text("Automatic Fetching"))) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                SettingsHelpLabel("Fill Covers, Titles, and Tags", help: "Finds missing covers, titles and tags for works in your library. You can pause and resume the background task.")
                                    .font(.headline)
                                if env.coverQueueState.isRunning && env.coverQueueState.total > 0 {
                                    Text(queueProgressText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else if let error = env.coverQueueState.error {
                                    Text(error).font(.caption).foregroundStyle(.secondary)
                                } else if env.coverQueueState.remaining > 0 {
                                    Text(L10n.text("Still missing information: %@ works. Failed downloads can be retried.", String(env.coverQueueState.remaining)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let sites = sitesBlockingBulkReading {
                                    Label(L10n.text("%@ may block your network address when many works are read at once, so filling asks first and reads slowly. Add another website and missing information is read from there.", sites), systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                        .accessibilityIdentifier("library.fillBlockingSites")
                                }
                            }

                            Spacer()

                            Button(action: toggleQueue) {
                                Image(systemName: env.coverQueueState.isRunning && !env.coverQueueState.isPaused ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                            }
                            .accessibilityLabel(L10n.text(env.coverQueueState.isRunning && !env.coverQueueState.isPaused ? "Pause" : "Fill Covers, Titles, and Tags"))
                            .accessibilityIdentifier("library.fillMissing")
                        }

                        if env.coverQueueState.isRunning && env.coverQueueState.total > 0 {
                            ProgressView(
                                value: queueProgressValue,
                                total: Double(max(1, env.coverQueueState.total))
                            )
                        }
                    }
                    .padding(.vertical, 4)

                    Button { confirmingRefresh = true } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L10n.text("Refresh Saved Work Information"), systemImage: "arrow.triangle.2.circlepath")
                            Text(L10n.text("Fetches titles and tags again from the current site, for example after an update changes how a site is read."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(worksCount == 0 || !env.isSiteVerified)
                    .accessibilityIdentifier("library.refreshInformation")
                    .confirmationDialog(L10n.text("Refresh information for %@ saved works?", String(worksCount)), isPresented: $confirmingRefresh, titleVisibility: .visible) {
                        Button(L10n.text("Refresh Information")) { env.refreshSavedWorkInformation() }
                        Button(L10n.text("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.text("Titles and tags are replaced with what the current site shows. If the app closes or some works can’t be fetched, it picks up with the remaining works later. Notes, folders, and covers stay as they are, and works the site shows as a different work are left unchanged."))
                    }
                }
            }
            Section {
                NavigationLink { OtherAppImportView() } label: {
                    Label(L10n.text("Import from Another Comics Viewer"), systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(isExporting)
                .accessibilityIdentifier("comics.importOtherApp")
            } header: {
                Text(L10n.text("Import Data"))
            } footer: {
                Text(L10n.text("Bookmark backups, work catalogs, database exports, app data exports, download folders, manga reader backups, link lists and browser bookmarks. The file's kind is recognized automatically."))
            }

            CloudSyncSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.text("Library Management"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadStats()
        }
    }

    /// The connected websites, when every one of them blocks bulk reading.
    private var sitesBlockingBulkReading: String? {
        let sites = env.comicSites
        guard !sites.isEmpty, sites.allSatisfy({ CoverFillGuard.blocksBulkReading($0) }) else { return nil }
        return sites.joined(separator: ", ")
    }

    private var queueProgressText: String {
        let state = env.coverQueueState
        let done = state.processed + state.failed + state.gone
        return L10n.text("%@/%@ (failed: %@, unavailable: %@)", String(describing: done), String(describing: state.total), String(describing: state.failed), String(describing: state.gone))
    }

    private var queueProgressValue: Double {
        let state = env.coverQueueState
        return Double(state.processed + state.failed + state.gone)
    }

    private func loadStats() {
        worksCount = (try? env.database.worksCount()) ?? 0
        catalogCount = (try? env.database.catalogCount()) ?? 0
        missingCount = (try? env.database.missingTitleCount()) ?? 0
    }

    private func toggleQueue() {
        if env.coverQueueState.isRunning && !env.coverQueueState.isPaused {
            Task { await env.coverQueueActor.pause() }
            env.coverQueueState.isPaused = true
        } else if env.coverQueueState.isRunning && env.coverQueueState.isPaused {
            Task { await env.coverQueueActor.resume() }
            env.coverQueueState.isPaused = false
        } else {
            env.startCoverQueue(manual: true)
        }
    }
}

enum LibraryClassification: String, CaseIterable, Identifiable {
    case artist, language, type, series, rating, server
    var id: String { rawValue }
    var title: String {
        switch self { case .artist: "Artists"; case .language: "Language"; case .type: "Type"; case .series: "Series"; case .rating: "Rating"; case .server: "Server" }
    }
}
struct LibraryClassificationGroup: Identifiable {
    let name: String
    var works: [Work] = []
    var posts: [BooruPost] = []
    var id: String { name }
    var count: Int { works.count + posts.count }
}
enum LibraryMaintenance {
    static func classification(works: [Work], posts: [BooruPost], criterion: LibraryClassification, serverNames: [String: String] = [:]) -> [LibraryClassificationGroup] {
        var groups: [String: LibraryClassificationGroup] = [:]
        func names(_ text: String?) -> [String] { (text ?? "").components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        for work in works {
            let values: [String]
            switch criterion { case .artist: values = names(work.artists); case .language: values = names(work.language); case .type: values = names(work.type); case .series: values = names(work.series); default: values = [] }
            for value in Set(values) { groups[value, default: .init(name: value)].works.append(work) }
        }
        for post in posts {
            let value: String?
            switch criterion {
            case .artist: value = post.artists.first
            case .rating: value = post.rating
            case .server: value = serverNames[post.serverID] ?? post.serverID
            case .type: value = post.fileExtension
            case .series: value = post.tags.first { post.tagCategories?[$0] == 3 }
            case .language: value = post.tags.first { $0.hasPrefix("language:") }
            }
            if let value, !value.isEmpty { groups[value, default: .init(name: value)].posts.append(post) }
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func duplicateKey(_ work: Work) -> String? {
        guard let title = work.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let artists = work.artists, !artists.isEmpty else { return nil }
        return [title, artists, work.language ?? "", work.type ?? ""].map { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\u{0}")
    }
    static func duplicateKey(_ post: BooruPost) -> String? {
        guard let file = post.fileURL else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        if [32, 40, 64].contains(stem.count), stem.allSatisfy({ $0.isHexDigit }) { return "hash:" + stem }
        return "url:" + file.absoluteString
    }
    static func duplicates(works: [Work], posts: [BooruPost]) -> [LibraryClassificationGroup] {
        var groups: [String: LibraryClassificationGroup] = [:]
        for work in works { if let key = duplicateKey(work) { groups[key, default: .init(name: key)].works.append(work) } }
        for post in posts { if let key = duplicateKey(post) { groups[key, default: .init(name: key)].posts.append(post) } }
        return groups.values.filter { $0.count > 1 }.sorted { $0.name < $1.name }
    }
    static func mergeComics(_ group: LibraryClassificationGroup, keeping id: Int64, database: AppDatabase) throws {
        guard group.works.contains(where: { $0.galleryId == id }) else { return }
        try database.dbWriter.write { db in
            guard let keeper = try Work.filter(Work.Columns.galleryId == id).fetchOne(db), let keeperID = keeper.id else { return }
            var notes = [keeper.note].compactMap { $0 }.filter { !$0.isEmpty }
            for candidate in group.works where candidate.galleryId != id {
                guard let work = try Work.filter(Work.Columns.galleryId == candidate.galleryId).fetchOne(db), let oldID = work.id,
                      duplicateKey(work) == group.name, duplicateKey(keeper) == group.name else { continue }
                try db.execute(sql: "INSERT INTO folder_works (folder_id, work_id, added_at) SELECT folder_id, ?, added_at FROM folder_works WHERE work_id = ? ON CONFLICT(folder_id, work_id) DO UPDATE SET added_at = MAX(added_at, excluded.added_at)", arguments: [keeperID, oldID])
                if let note = work.note, !note.isEmpty, !notes.contains(note) { notes.append(note) }
                try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [oldID])
            }
            try AppDatabase.leaveUnfiled(workID: keeperID, db: db)
            try db.execute(sql: "UPDATE works SET note = ? WHERE id = ?", arguments: [notes.joined(separator: "\n\n"), keeperID])
        }
    }
}

struct LibraryMaintenanceLinks: View {
    var booru = false
    var body: some View {
        Section(L10n.text("Organize Saved Works")) {
            NavigationLink { LibraryOrganizationView(booru: booru) } label: { Label(L10n.text("Classify into Folders"), systemImage: "folder.badge.gearshape") }
            NavigationLink { DuplicateCleanupView(booru: booru) } label: { Label(L10n.text("Clean Up Duplicates"), systemImage: "square.on.square") }
                .accessibilityIdentifier("settings.duplicates")
        }
    }
}
struct LibraryOrganizationView: View {
    var booru = false
    @Environment(AppEnvironment.self) private var env
    @State private var criterion = LibraryClassification.artist
    @State private var works: [Work] = []
    @State private var posts: [BooruPost] = []
    @State private var onlyUnsorted = true
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    @State private var confirming = false
    private var groups: [LibraryClassificationGroup] {
        LibraryMaintenance.classification(works: works, posts: posts, criterion: criterion, serverNames: Dictionary(uniqueKeysWithValues: env.booru.servers.map { ($0.id, $0.canonicalAddress) }))
    }
    var body: some View {
        List {
            Section {
                SettingsHelpLabel("Classify into Folders", help: "Creates folders from metadata already saved in your library. Comics keep their existing folder memberships. Images use the first matching value because each image belongs to one folder. Works with missing metadata are skipped.")
                Picker(L10n.text("Classify By"), selection: $criterion) {
                    ForEach(LibraryClassification.allCases.filter { booru || ![.rating, .server].contains($0) }) { Text(L10n.text($0.title)).tag($0) }
                }
                Toggle(L10n.text("Only Unsorted Works"), isOn: $onlyUnsorted)
                Button(L10n.text("Apply Classification")) { confirming = true }.disabled(groups.isEmpty || busy)
                if busy { ProgressView(L10n.text("Processing…")) }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    LabeledContent(group.name.replacingOccurrences(of: "_", with: " "), value: String(group.count))
                } header: { Text(L10n.text(criterion.title)) }
            }
            if groups.isEmpty && !busy { Text(L10n.text("No Matching Metadata")).foregroundStyle(.secondary) }
        }
        .navigationTitle(L10n.text("Classify into Folders")).navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { await load() }
        .onChange(of: onlyUnsorted) { _, _ in Task { await load() } }
        .confirmationDialog(L10n.text("Apply Classification?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.text("Apply")) { Task { await classify() } }
        }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L10n.text("Done"), role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let database = env.database, images = env.booru, imageMode = booru, filter = onlyUnsorted
            let value = try await Task.detached(priority: .userInitiated) { () -> ([Work], [BooruPost]) in
                if imageMode {
                    let posts = images.favorites(serverIDs: images.servers.map(\.id)).filter {
                        !filter || images.folderID(for: $0) == "unsorted" || (images.folderID(for: $0)?.hasPrefix("site:") ?? false)
                    }
                    return ([], posts)
                }
                return (try database.listWorks().filter { !filter || $0.folders.isEmpty || $0.folders.allSatisfy { $0.displayName == L10n.text("Unsorted") || $0.name == "미분류" } }, [])
            }.value
            works = value.0; posts = value.1
        } catch { self.error = error.localizedDescription }
    }
    private func classify() async {
        busy = true
        let plans = groups, database = env.database, images = env.booru, title = L10n.text(criterion.title)
        do {
            try await Task.detached(priority: .userInitiated) {
                for group in plans {
                    let name = title + " · " + group.name.replacingOccurrences(of: "_", with: " ")
                    if !group.works.isEmpty {
                        let folder = try database.listFolders().first { $0.name == name } ?? database.createFolder(name: name)
                        if let folderID = folder.id { for work in group.works { if let id = work.id { try database.addWorkToFolder(workId: id, folderId: folderID) } } }
                    } else {
                        // A group gathers images of any server, so its folder is global.
                        let folderID = try images.folders().first { $0.name == name && $0.isGlobal }?.id ?? images.saveFolder(name: name)
                        try images.moveFavorites(group.posts, folderID: folderID)
                    }
                }
            }.value
            message = L10n.text("Classification Complete")
        } catch { self.error = error.localizedDescription }
        busy = false; await load()
    }
}

/// Chooses what each gesture on a thumbnail does, for comics or for image mode.
struct ThumbnailGestureSettings: View {
    let booru: Bool
    @SwiftUI.AppStorage private var tap: String
    @SwiftUI.AppStorage private var doubleTap: String
    @SwiftUI.AppStorage private var hold: String
    init(booru: Bool = false) {
        self.booru = booru
        let store = ThumbnailGesture.store(booru: booru)
        _tap = .init(wrappedValue: ThumbnailGesture.tap.standard(booru: booru).rawValue, ThumbnailGesture.tap.key(booru: booru), store: store)
        _doubleTap = .init(wrappedValue: ThumbnailGesture.doubleTap.standard(booru: booru).rawValue, ThumbnailGesture.doubleTap.key(booru: booru), store: store)
        _hold = .init(wrappedValue: ThumbnailGesture.hold.standard(booru: booru).rawValue, ThumbnailGesture.hold.key(booru: booru), store: store)
    }
    var body: some View {
        List {
            Section {
                picker(.tap, $tap)
                picker(.doubleTap, $doubleTap)
                picker(.hold, $hold)
            } footer: {
                Text(L10n.text(booru
                    ? "Applies to images in Explore. A double tap action makes single taps wait a moment for a second tap."
                    : "Applies to works in Explore and related works. Open follows Show Work Information Before Reading. Holding a work and moving it still carries it to Up Next. A double tap action makes single taps wait a moment for a second tap."))
            }
            Section {
                Button(L10n.text("Reset to Defaults")) {
                    tap = ThumbnailGesture.tap.standard(booru: booru).rawValue
                    doubleTap = ThumbnailGesture.doubleTap.standard(booru: booru).rawValue
                    hold = ThumbnailGesture.hold.standard(booru: booru).rawValue
                }.accessibilityIdentifier("gestures.reset")
            }
        }
        .navigationTitle(L10n.text("Thumbnail Gestures")).navigationBarTitleDisplayMode(.inline)
    }
    private func picker(_ gesture: ThumbnailGesture, _ value: Binding<String>) -> some View {
        Picker(gesture.title, selection: value) {
            ForEach(gesture.choices(booru: booru)) { Text($0.title).tag($0.rawValue) }
        }.accessibilityIdentifier("gestures." + gesture.rawValue)
    }
}
