import SwiftUI
import UniformTypeIdentifiers

/// Reads a backup, export, download folder or link list from another comics app, shows what
/// it holds, and merges it into the library when the person confirms.
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

    var body: some View {
        Form {
            Section {
                Label(L10n.text("Import from Another Comics App"), systemImage: "square.and.arrow.down.on.square.fill").font(.headline)
                Text(L10n.text("Choose a backup, export or link list from another comics app. TEGNAL recognizes what the file holds and shows it before importing."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.text(library == nil ? "Choose File" : "Choose Another File"), systemImage: "doc.badge.plus") { picker = .item }
                    .disabled(loading).accessibilityIdentifier("otherApp.chooseFile")
                Button(L10n.text("Choose Download Folder"), systemImage: "folder.badge.plus") { picker = .folder }
                    .disabled(loading).accessibilityIdentifier("otherApp.chooseFolder")
            } footer: {
                Text(L10n.text("Supported: database exports (.db), app data exports (.json), download folders with manifest.json, manga reader backups (.tachibk), and link lists or browser bookmarks (.txt, .html)."))
            }
            if loading { Section { ProgressView(L10n.text("Importing…")) } }
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
        .navigationTitle(L10n.text("Another App")).navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }), allowedContentTypes: [picker ?? .item]) { outcome in
            if case .success(let url) = outcome { read(url) }
            else if case .failure(let failure) = outcome { error = failure.localizedDescription }
        }
        .task { folders = (try? env.database.listFolders()) ?? [] }
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

    private func read(_ url: URL) {
        task?.cancel(); loading = true; result = nil; error = nil; library = nil
        task = Task {
            do {
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
