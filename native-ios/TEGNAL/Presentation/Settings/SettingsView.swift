import SwiftUI
import GRDB
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showReader = false
    @State private var showOnboarding = false
    @State private var showConnection = false
    @SwiftUI.AppStorage(MangaThumbnailOpening.preferenceKey, store: ReaderPreferences.defaults) private var showsInformationBeforeReading = false
    public init() {}
    public var body: some View {
        @Bindable var env = env
        List {
            if env.discordInvitationVisible { Section { DiscordInvitationBanner() } }
            Section {
                Button { showConnection = true } label: {
                    Label(L10n.text("Website Connection"), systemImage: "globe")
                }.accessibilityIdentifier("settings.connection")
                Toggle(isOn: $env.useEmbeddedBrowser) {
                    SettingsHelpLabel("Use Embedded Browser", help: "Opens the website instead of the app’s native screens. Try this if a website does not load correctly.")
                }
                    .accessibilityIdentifier("settings.embeddedBrowser")
                Toggle(isOn: $showsInformationBeforeReading) {
                    SettingsHelpLabel("Show Work Information Before Reading", help: "Shows the title, tags and page previews when you tap a work. When off, the work opens directly in the viewer.")
                }
                    .accessibilityIdentifier("settings.mangaInfoBeforeReading")
            } header: { Text(L10n.text("Browsing")) }
            ReaderSettingsSection(booru: false, isPresented: $showReader)
            Section {
                NavigationLink { DownloadsView(mode: .manga) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("settings.downloads")
            }
            ModeAppearanceSettings()
            LanguageSettingsSection()
            MangaDefaultTagsSettings()
            SearchHistorySettings()
            TasteSettingsSection(mode: .comics)
            CloudSyncSection()
            Section {
                NavigationLink { MangaLibraryToolsView() } label: {
                    Label(L10n.text("Library Management"), systemImage: "externaldrive")
                }.accessibilityIdentifier("settings.libraryManagement")
            } header: { Text(L10n.text("Data & Storage")) }
            SettingsSupportSection(showOnboarding: $showOnboarding)
            DeveloperInfoSection()
        }
        .onAppear { env.presentDiscordInvitationIfDue() }
        .listStyle(.insetGrouped)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text("Settings")) }
        }
        .appSheet(isPresented: $showReader) { ReaderSettingsView() }
        .appSheet(isPresented: $showConnection) { WebsiteConnectionEditor(server: nil, initialAddress: env.isSiteVerified ? env.mangaSiteAddress : "") }
        .appFullScreenCover(isPresented: $showOnboarding) { OnboardingView().environment(env) }
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
    var importOnly = false
    @Environment(AppEnvironment.self) private var env

    @State private var worksCount = 0
    @State private var catalogCount = 0
    @State private var missingCount = 0
    @State private var statusMessage: String?
    @State private var isImporting = false
    @State private var isCancellingImport = false
    @State private var isExporting = false
    @State private var showUserDbPicker = false
    @State private var showDataDbPicker = false
    @State private var showDataDbActionSheet = false
    @State private var showNoWorksAlert = false
    @State private var pendingDataDbUrl: URL? = nil
    @State private var importTask: Task<Void, Never>? = nil



    var body: some View {
        List {
            if !importOnly { LibraryMaintenanceLinks() }
            if !importOnly {
                LibraryBackupSection(busy: $isExporting, onRestore: loadStats)
                    .disabled(isImporting)
            }
            if !importOnly {
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
                }
            }
            Section(header: Text(L10n.text("Import Data (Other Manga Viewer)"))) {
                Button {
                    showUserDbPicker = true
                } label: {
                    Label(L10n.text("Import user.db (Bookmarks, Folders, Artists)"), systemImage: "person.crop.rectangle.stack")
                }
                .disabled(isImporting || isExporting)

                Button {
                    showDataDbPicker = true
                } label: {
                    Label(L10n.text("Import data.db (Work Metadata Catalog)"), systemImage: "cylinder.split.1x2")
                }
                .disabled(isImporting || isExporting)
            }

            if isImporting || statusMessage != nil {
                Section(header: Text(L10n.text("Task Status"))) {
                    if isImporting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(statusMessage ?? L10n.text("Processing…"))
                                .font(.footnote)
                            Spacer()
                            Button(L10n.text("Cancel")) {
                                isCancellingImport = true
                                importTask?.cancel()
                                // Keep controls disabled until the worker acknowledges cancellation.
                                statusMessage = L10n.text("Cancel") + "…"
                            }
                            .disabled(isCancellingImport)
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.text(importOnly ? "Import from Another Manga Viewer" : "Library Management"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showUserDbPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleUserDbImport(result: result)
        }
        .fileImporter(
            isPresented: $showDataDbPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleDataDbSelection(result: result)
        }
        .confirmationDialog(
            L10n.text("How to Import data.db (Catalog)"),
            isPresented: $showDataDbActionSheet,
            titleVisibility: .visible
        ) {
            Button(L10n.text("⚡️ Fill Only My Library (Recommended)")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: true)
                }
            }
            Button(L10n.text("📦 Save Entire Catalog (Background Import)")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: false)
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                pendingDataDbUrl = nil
            }
        } message: {
            Text(L10n.text("data.db is a large catalog that can exceed 500 MB.\n\nChoose 'Fill Only My Library' to extract information for your %@ saved works. This avoids storing hundreds of thousands of unnecessary records.", String(describing: worksCount)))
        }
        .alert(L10n.text("Your Library Is Empty"), isPresented: $showNoWorksAlert) {
            Button(L10n.text("Save Entire Catalog")) {
                if let url = pendingDataDbUrl {
                    startDataDbImport(url: url, matchOnly: false)
                }
            }
            Button(L10n.text("Cancel (Import user.db First)"), role: .cancel) {
                pendingDataDbUrl = nil
            }
        } message: {
            Text(L10n.text("There are no saved works to match. Import user.db (bookmarks) first, then import data.db to fill the information you need."))
        }
        .task {
            loadStats()
        }
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
            env.startCoverQueue()
        }
    }

    private func handleDataDbSelection(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        pendingDataDbUrl = url
        loadStats()
        if worksCount > 0 {
            showDataDbActionSheet = true
        } else {
            showNoWorksAlert = true
        }
    }

    private func handleUserDbImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard !isImporting, !isExporting else { return }
        isImporting = true
        isCancellingImport = false
        statusMessage = L10n.text("Preparing user.db…")

        let importer = env.mangaViewerImporter
        let envRef = env

        importTask = Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            var readPath = url.path
            var tempURL: URL? = nil

            if !MangaViewerImportService.isUserDb(at: readPath) {
                let tempDir = FileManager.default.temporaryDirectory
                let copyUrl = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: copyUrl)
                    try FileManager.default.copyItem(at: url, to: copyUrl)
                    readPath = copyUrl.path
                    tempURL = copyUrl
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Unable to read file: %@", String(describing: error.localizedDescription))
                    }
                    return
                }
            }

            defer {
                if let tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                try Task.checkCancellation()
                let res = try importer.importUserDb(path: readPath)
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = L10n.text("user.db imported: %@ folders, %@ works, %@ artists", String(describing: res.folders), String(describing: res.works), String(describing: res.artists))
                    self.loadStats()
                    envRef.startCoverQueue()
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = error is CancellationError ? L10n.text("The task was canceled.") : L10n.text("Import failed: %@", String(describing: error.localizedDescription))
                    self.loadStats()
                }
            }
        }
    }

    private func startDataDbImport(url: URL, matchOnly: Bool) {
        guard !isImporting, !isExporting else { return }
        isImporting = true
        isCancellingImport = false
        statusMessage = matchOnly ? L10n.text("Matching metadata for your library…") : L10n.text("Preparing catalog import…")

        let importer = env.mangaViewerImporter

        importTask = Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            var readPath = url.path
            var tempURL: URL? = nil

            if !MangaViewerImportService.isDataDb(at: readPath) {
                await MainActor.run {
                    self.statusMessage = L10n.text("Caching large file… Please wait.")
                }
                let tempDir = FileManager.default.temporaryDirectory
                let copyUrl = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: copyUrl)
                    try FileManager.default.copyItem(at: url, to: copyUrl)
                    readPath = copyUrl.path
                    tempURL = copyUrl
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Unable to read file: %@", String(describing: error.localizedDescription))
                    }
                    return
                }
            }

            defer {
                if let tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                try Task.checkCancellation()
                if matchOnly {
                    let res = try importer.matchAndFillWorks(fromDataDb: readPath)
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("Metadata matched! Filled %2$@ of %1$@ saved works.", String(describing: res.totalWorks), String(describing: res.matched)) + "\n" + L10n.text("Missing covers are downloaded separately in the background.")
                        self.loadStats()
                        env.startCoverQueue()
                    }
                } else {
                    let total = try importer.importDataDb(path: readPath) { progress in
                        Task { @MainActor in
                            guard self.isImporting, !self.isCancellingImport else { return }
                            self.statusMessage = L10n.text("Importing entire catalog… (%@ records)", String(describing: progress))
                        }
                    }
                    await MainActor.run {
                        self.isImporting = false
                        self.statusMessage = L10n.text("data.db imported: %@ catalog records applied", String(describing: total))
                        self.loadStats()
                        env.startCoverQueue()
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusMessage = error is CancellationError ? L10n.text("The task was canceled.") : L10n.text("Import failed: %@", String(describing: error.localizedDescription))
                    self.loadStats()
                }
            }
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
                try db.execute(sql: "INSERT OR IGNORE INTO folder_works (folder_id, work_id, added_at) SELECT folder_id, ?, added_at FROM folder_works WHERE work_id = ?", arguments: [keeperID, oldID])
                if let note = work.note, !note.isEmpty, !notes.contains(note) { notes.append(note) }
                try db.execute(sql: "DELETE FROM works WHERE id = ?", arguments: [oldID])
            }
            try db.execute(sql: "UPDATE works SET note = ? WHERE id = ?", arguments: [notes.joined(separator: "\n\n"), keeperID])
        }
    }
}

struct LibraryMaintenanceLinks: View {
    var booru = false
    var body: some View {
        Section(L10n.text("Organize Saved Works")) {
            NavigationLink { LibraryOrganizationView(booru: booru) } label: { Label(L10n.text("Classify into Folders"), systemImage: "folder.badge.gearshape") }
            NavigationLink { LibraryOrganizationView(booru: booru, duplicates: true) } label: { Label(L10n.text("Review Duplicate Works"), systemImage: "square.on.square") }
        }
    }
}
struct LibraryOrganizationView: View {
    var booru = false
    var duplicates = false
    @Environment(AppEnvironment.self) private var env
    @State private var criterion = LibraryClassification.artist
    @State private var works: [Work] = []
    @State private var posts: [BooruPost] = []
    @State private var onlyUnsorted = true
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?
    @State private var pendingGroup: LibraryClassificationGroup?
    @State private var keeper = ""
    @State private var inspectedComic: IdentifiableString?
    @State private var inspectedImage: BooruPost?
    @State private var confirming = false
    private var groups: [LibraryClassificationGroup] {
        duplicates ? LibraryMaintenance.duplicates(works: works, posts: posts) : LibraryMaintenance.classification(works: works, posts: posts, criterion: criterion, serverNames: Dictionary(uniqueKeysWithValues: env.booru.servers.map { ($0.id, $0.canonicalAddress) }))
    }
    var body: some View {
        List {
            Section {
                SettingsHelpLabel(duplicates ? "Review Duplicate Works" : "Classify into Folders", help: duplicates
                    ? "Identical work numbers and server post IDs are already merged. This lists possible duplicates with matching metadata or original file addresses. Review each copy before removing it."
                    : "Creates folders from metadata already saved in your library. Comics keep their existing folder memberships. Images use the first matching value because each image belongs to one folder. Works with missing metadata are skipped.")
                if !duplicates {
                    Picker(L10n.text("Classify By"), selection: $criterion) {
                        ForEach(LibraryClassification.allCases.filter { booru || ![.rating, .server].contains($0) }) { Text(L10n.text($0.title)).tag($0) }
                    }
                    Toggle(L10n.text("Only Unsorted Works"), isOn: $onlyUnsorted)
                    Button(L10n.text("Apply Classification")) { confirming = true }.disabled(groups.isEmpty || busy)
                }
                if busy { ProgressView(L10n.text("Processing…")) }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    if duplicates {
                        ForEach(group.works) { work in
                            HStack {
                                Button { inspectedComic = .init(id: MangaUrls.galleryUrl(for: work.galleryId)) } label: { Text((work.title ?? "") + " · " + String(work.galleryId)) }
                                Spacer()
                                Button(L10n.text("Keep This Copy")) { pendingGroup = group; keeper = String(work.galleryId) }.buttonStyle(.bordered)
                            }.buttonStyle(.borderless)
                        }
                        ForEach(group.posts) { post in
                            HStack {
                                Button { inspectedImage = post } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text((env.booru.servers.first { $0.id == post.serverID }?.displayName ?? post.serverID) + " · " + String(post.postID))
                                            Text(env.booru.folders().first { $0.id == env.booru.folderID(for: post) }?.displayName ?? "").font(.caption).foregroundStyle(.secondary)
                                        }
                                        if let url = post.previewURL { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 56, height: 64) }
                                    }
                                }
                                Spacer()
                                Button(L10n.text("Keep This Copy")) { pendingGroup = group; keeper = post.id }.buttonStyle(.bordered)
                            }.buttonStyle(.borderless)
                        }
                    } else { LabeledContent(group.name.replacingOccurrences(of: "_", with: " "), value: String(group.count)) }
                } header: { Text(duplicates ? L10n.text("Possible Duplicates") : L10n.text(criterion.title)) }
            }
            if groups.isEmpty && !busy { Text(L10n.text(duplicates ? "No Duplicate Candidates" : "No Matching Metadata")).foregroundStyle(.secondary) }
        }
        .navigationTitle(L10n.text(duplicates ? "Review Duplicate Works" : "Classify into Folders")).navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .task { await load() }
        .appFullScreenCover(item: $inspectedComic) { ContentEntryView(initialUrl: $0.id) }
        .appFullScreenCover(item: $inspectedImage) { post in
            if let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                BooruPostView(post: post, posts: [post], server: server, source: BooruClient.shared)
            }
        }
        .onChange(of: onlyUnsorted) { _, _ in Task { await load() } }
        .confirmationDialog(L10n.text("Apply Classification?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.text("Apply")) { Task { await classify() } }
        }
        .confirmationDialog(L10n.text("Keep This Copy?"), isPresented: Binding(get: { pendingGroup != nil }, set: { if !$0 { pendingGroup = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Keep This Copy and Remove Others"), role: .destructive) {
                if let group = pendingGroup { let selection = keeper; pendingGroup = nil; Task { await merge(group, keeping: selection) } }
            }
        } message: { Text(L10n.text("Review the number and source before confirming. Comics merge folder memberships and notes into the kept copy. Images keep the selected copy’s folder.")) }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button(L10n.text("Done"), role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            let database = env.database, images = env.booru, imageMode = booru, filter = onlyUnsorted && !duplicates
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
                        let folderID = try images.folders().first { $0.name == name }?.id ?? images.saveFolder(name: name)
                        try images.moveFavorites(group.posts, folderID: folderID)
                    }
                }
            }.value
            message = L10n.text("Classification Complete")
        } catch { self.error = error.localizedDescription }
        busy = false; await load()
    }
    private func merge(_ group: LibraryClassificationGroup, keeping key: String) async {
        busy = true
        do {
            let images = env.booru, database = env.database, imageMode = booru
            try await Task.detached(priority: .userInitiated) {
                if imageMode { try images.removeFavorites(group.posts.filter { $0.id != key }) }
                else if let id = Int64(key) { try LibraryMaintenance.mergeComics(group, keeping: id, database: database) }
            }.value
            message = L10n.text("Duplicate Copies Removed")
        } catch { self.error = error.localizedDescription }
        busy = false; await load()
    }
}
