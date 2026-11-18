import SwiftUI
import UniformTypeIdentifiers

/// A database of a comics viewer that keeps its bookmarks in one file and its catalogue of works
/// in another. Each is recognized by the tables it holds, whatever the file is called.
enum ViewerDatabase: Sendable {
    case bookmarks, catalog

    var title: String { L10n.text(self == .bookmarks ? "Bookmark Backup" : "Work Information Catalog") }

    /// The kind of viewer database at `url`, or nil for any other file.
    static func recognize(_ url: URL) throws -> ViewerDatabase? {
        try reading(url) { path in
            if MangaViewerImportService.isUserDb(at: path) { return .bookmarks }
            return MangaViewerImportService.isDataDb(at: path) ? .catalog : nil
        }
    }

    /// Hands `work` a path SQLite can open. A file the app may read in place is read there, which
    /// matters for a catalogue of several hundred megabytes; one that cannot be is copied first.
    static func reading<T>(_ url: URL, _ work: (String) throws -> T) throws -> T {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
              let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 16), head.starts(with: Array("SQLite format 3".utf8)) else {
            return try work("")
        }
        if MangaViewerImportService.isUserDb(at: url.path) || MangaViewerImportService.isDataDb(at: url.path) { return try work(url.path) }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        return try work(copy.path)
    }
}

/// Reads a backup, export, database, download folder or link list from another comics viewer,
/// shows what it holds, and merges it into the library when the person confirms. One button
/// takes every kind of file; what the file is, is worked out from the file.
struct OtherAppImportView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var picker: UTType?
    @State private var library: OtherAppLibrary?
    @State private var options = OtherAppImportOptions()
    @State private var folders: [Folder] = []
    @State private var loading = false
    @State private var result: OtherAppImportResult?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    /// The picked file, when it is a viewer's own database, and what has been done with it.
    @State private var database: (kind: ViewerDatabase, url: URL)?
    @State private var status: String?
    @State private var saved = 0

    var body: some View {
        Form {
            Section {
                Label(L10n.text("Import from Another Comics Viewer"), systemImage: "square.and.arrow.down.on.square.fill").font(.headline)
                Text(L10n.text("Choose a backup, export, database or link list from another comics viewer. TEGNAL recognizes what the file holds and shows it before importing."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.text(library == nil && database == nil ? "Choose File" : "Choose Another File"), systemImage: "doc.badge.plus") { picker = .item }
                    .disabled(loading).accessibilityIdentifier("otherApp.chooseFile")
                Button(L10n.text("Choose Download Folder"), systemImage: "folder.badge.plus") { picker = .folder }
                    .disabled(loading).accessibilityIdentifier("otherApp.chooseFolder")
            } footer: {
                Text(L10n.text("Supported: bookmark backups and work catalogs (user.db, data.db), database exports (.db), app data exports (.json), download folders with manifest.json, manga reader backups (.tachibk), and link lists or browser bookmarks (.txt, .html)."))
            }
            if loading { Section { ProgressView(status ?? L10n.text("Importing…")) } }
            else if let status { Section { Text(status).accessibilityIdentifier("otherApp.status") } }
            if let database, !loading { viewerDatabase(database.kind) }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("otherApp.error") } }
            if let result {
                Section {
                    Label(L10n.text("Import Complete"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.text("%@ works added · %@ already saved · %@ folders created", String(result.added), String(result.existing), String(result.folders)))
                        .accessibilityIdentifier("otherApp.result")
                } footer: {
                    Text(L10n.text("Titles, tags and covers are filled in from the connected website in the background."))
                }
            } else if let library {
                contents(library)
                Section(L10n.text("Import Options")) {
                    Picker(L10n.text("Destination Folder"), selection: $options.destination) {
                        Text(L10n.text(library.shelves.count > 1 || library.shelves.first?.name != nil ? "Folders from the File" : "Unfiled")).tag(Int64?.none)
                        ForEach(folders) { folder in Text(folder.displayName).tag(folder.id) }
                    }
                    if !library.history.isEmpty {
                        Toggle(L10n.text("Import Reading History as a Folder"), isOn: $options.includeHistory)
                            .accessibilityIdentifier("otherApp.history")
                    }
                }
                Section {
                    Button(L10n.text("Import"), systemImage: "square.and.arrow.down", action: commit)
                        .disabled(loading || (library.workCount == 0 && !options.includeHistory))
                        .accessibilityIdentifier("otherApp.import")
                } footer: {
                    Text(L10n.text("Works already in your library keep their information and folders. Covers and missing information are read from the connected website afterwards, following the bulk reading limits."))
                }
            }
        }
        .navigationTitle(L10n.text("Other Comics Viewer")).navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }), allowedContentTypes: [picker ?? .item]) { outcome in
            if case .success(let url) = outcome { read(url) }
            else if case .failure(let failure) = outcome { error = failure.localizedDescription }
        }
        .task { folders = (try? env.database.listFolders()) ?? []; saved = (try? env.database.worksCount()) ?? 0 }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private func contents(_ library: OtherAppLibrary) -> some View {
        Section(L10n.text("File Contents")) {
            LabeledContent(L10n.text("Kind"), value: library.format.title)
            LabeledContent(L10n.text("Works"), value: String(library.workCount))
            if !library.history.isEmpty {
                LabeledContent(L10n.text("Reading History"), value: String(library.history.count))
            }
            if !library.shelves.isEmpty {
                DisclosureGroup(L10n.text("Folders")) {
                    ForEach(Array(library.shelves.enumerated()), id: \.offset) { _, shelf in
                        LabeledContent(shelf.displayName, value: String(shelf.entries.count))
                    }
                }
            }
            if library.skipped > 0 {
                Text(L10n.text("%@ entries that aren’t works of a supported catalog will be skipped.", String(library.skipped))).foregroundStyle(.orange)
            }
        }
    }

    /// What a viewer's own database offers: its bookmarks are imported as they are; its catalogue
    /// either fills in the works already saved or is kept whole.
    @ViewBuilder private func viewerDatabase(_ kind: ViewerDatabase) -> some View {
        Section(L10n.text("File Contents")) {
            LabeledContent(L10n.text("Kind"), value: kind.title).accessibilityIdentifier("otherApp.viewerDatabase")
        }
        if kind == .bookmarks {
            Section {
                Button(L10n.text("Import"), systemImage: "square.and.arrow.down") { importBookmarks() }
                    .accessibilityIdentifier("otherApp.import")
            } footer: {
                Text(L10n.text("Titles, tags and covers are filled in from the connected website in the background."))
            }
        } else {
            Section {
                Button(L10n.text("⚡️ Fill Only My Library (Recommended)")) { importCatalog(matchOnly: true) }.disabled(saved == 0)
                Button(L10n.text("📦 Save Entire Catalog (Background Import)")) { importCatalog(matchOnly: false) }
            } footer: {
                if saved == 0 {
                    Text(L10n.text("There are no saved works to match. Import user.db (bookmarks) first, then import data.db to fill the information you need."))
                }
            }
        }
    }

    private func importBookmarks() {
        guard let url = database?.url else { return }
        let importer = env.mangaViewerImporter
        run(L10n.text("Importing library from user.db…")) {
            let found = try ViewerDatabase.reading(url) { try importer.importUserDb(path: $0) }
            return L10n.text("user.db imported: %@ folders, %@ works, %@ artists", String(found.folders), String(found.works), String(found.artists))
        }
    }

    private func importCatalog(matchOnly: Bool) {
        guard let url = database?.url else { return }
        let importer = env.mangaViewerImporter
        run(L10n.text(matchOnly ? "Matching metadata for your library…" : "Caching large file… Please wait.")) {
            try ViewerDatabase.reading(url) { path in
                if matchOnly {
                    let found = try importer.matchAndFillWorks(fromDataDb: path)
                    return L10n.text("Metadata matched! Filled %2$@ of %1$@ saved works.", String(found.totalWorks), String(found.matched))
                }
                let total = try importer.importDataDb(path: path) { count in
                    Task { @MainActor in if loading { status = L10n.text("Importing entire catalog… (%@ records)", String(count)) } }
                }
                return L10n.text("data.db imported: %@ catalog records applied", String(total))
            }
        }
    }

    /// Runs one import away from the main thread and reports how it ended. Leaving the screen cancels it.
    private func run(_ message: String, _ work: @escaping @Sendable () throws -> String) {
        task?.cancel(); loading = true; error = nil; status = message
        task = Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { try work() }.value
                status = outcome
                database = nil
                env.startCoverQueue()
            } catch {
                status = error is CancellationError ? L10n.text("The task was canceled.") : L10n.text("Import failed: %@", error.localizedDescription)
            }
            folders = (try? env.database.listFolders()) ?? []; saved = (try? env.database.worksCount()) ?? 0
            loading = false
        }
    }

    private func read(_ url: URL) {
        task?.cancel(); loading = true; result = nil; error = nil; library = nil; database = nil; status = nil
        task = Task {
            do {
                // A viewer's own database is recognized first; every other file is read as a library to preview.
                if let kind = try await Task.detached(priority: .userInitiated, operation: { try ViewerDatabase.recognize(url) }).value {
                    try Task.checkCancellation()
                    database = (kind, url); loading = false
                    return
                }
                let parsed = try await Task.detached(priority: .userInitiated) { try OtherAppImport.read(url) }.value
                try Task.checkCancellation()
                library = parsed
                // A file that only remembers what was read imports that history by default.
                options = OtherAppImportOptions(includeHistory: parsed.workCount == 0 && !parsed.history.isEmpty)
                loading = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; loading = false }
            }
        }
    }

    private func commit() {
        guard let library else { return }
        loading = true; error = nil
        let database = env.database, options = options
        task = Task {
            do {
                result = try await Task.detached(priority: .userInitiated) { try database.importOtherApp(library, options: options) }.value
                env.startCoverQueue()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            folders = (try? env.database.listFolders()) ?? []
            loading = false
        }
    }
}
