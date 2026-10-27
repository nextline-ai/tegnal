import SwiftUI
import GRDB
import UniformTypeIdentifiers

public struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showReader = false
    @State private var showOnboarding = false
    @State private var showConnection = false
    public init() {}
    public var body: some View {
        @Bindable var env = env
        List {
            if env.discordInvitationVisible { Section { DiscordInvitationBanner() } }
            Section {
                Button { showConnection = true } label: {
                    Label(L10n.text("Website Connection"), systemImage: "globe")
                }.accessibilityIdentifier("settings.connection")
                Toggle(L10n.text("Use Embedded Browser"), isOn: $env.useEmbeddedBrowser)
                    .accessibilityIdentifier("settings.embeddedBrowser")
            } header: { Text(L10n.text("Browsing")) } footer: {
                Text(L10n.text("Use the website if the native viewer stops working. Turn off to return to the native viewer."))
            }
            Section {
                NavigationLink { DownloadsView(mode: .manga) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("settings.downloads")
            }
            ModeAppearanceSettings()
            LanguageSettingsSection()
            MangaDefaultTagsSettings()
            ReaderSettingsSection(booru: false, isPresented: $showReader)
            SearchHistorySettings()
            TasteSettingsSection(mode: .comics)
            CloudSyncSection()
            Section {
                NavigationLink { MangaLibraryToolsView() } label: {
                    Label(L10n.text("Library Management"), systemImage: "externaldrive")
                }.accessibilityIdentifier("settings.libraryManagement")
            } header: { Text(L10n.text("Data & Storage")) } footer: {
                Text(L10n.text("Import, back up, and fill missing information for your saved works."))
            }
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
                                Text(L10n.text("Fill Covers, Titles, and Tags"))
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
                                } else {
                                    Text(L10n.text("Fetch missing covers and metadata in the background."))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
