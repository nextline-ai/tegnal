import SwiftUI
import GRDB

private struct SavedWorksSearch: Identifiable, Hashable {
    let query: String
    var id: String { query }
}

public struct FoldersView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var folders: [Folder] = []
    @State private var reloadGeneration = 0
    @State private var previews: [Int64: [Work]] = [:]
    @State private var showCreateAlert = false
    @State private var showAddSheet = false
    @State private var editingColorFolder: Folder?
    @State private var folderPendingDelete: Folder?
    /// A folder kept in step with a website's favorites category, which can't be deleted while signed in.
    @State private var syncedFolder: Folder?
    @State private var renamingFolder: Folder?
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var editError: String?
    @State private var reordering = false
    @State private var folderMessage: String?
    @State private var smartFolder: SmartFolderTarget?
    @State private var searchText = ""
    @State private var searchResults: SavedWorksSearch?


    public init() {}

    public var body: some View {
        ScrollView {
            if folders.isEmpty && !env.recentWorks.showsInSaved {
                ContentUnavailableView(
                    L10n.text("No Folders"),
                    systemImage: "folder",
                    description: Text(L10n.text("Create a folder to organize your works."))
                )
                .padding(.top, 60)
            } else {
                ArtworkGrid(mode: .manga, kind: .folders) { _ in
                    if env.recentWorks.showsInSaved {
                        NavigationLink { RecentWorksView().readingQueueClearance() } label: {
                            RecentWorksFolderCard()
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .contextMenu {
                                    Button(L10n.text("Hide from Saved"), systemImage: "eye.slash") { env.recentWorks.setShowsInSaved(false) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("manga.recentFolder")
                    }
                    ForEach(folders) { folder in
                        NavigationLink(value: folder) {
                            FolderBentoCardView(
                                folder: folder,
                                previews: folder.id.flatMap { previews[$0] } ?? []
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contextMenu {
                                Button {
                                    editingColorFolder = folder
                                } label: {
                                    Label(L10n.text("Change Color"), systemImage: "paintpalette")
                                }

                                Button(L10n.text("Reorder Folders"), systemImage: "arrow.up.arrow.down") { reordering = true }
                                if folder.name != "미분류" {
                                    Button(L10n.text("Rename Folder"), systemImage: "pencil") {
                                        renamingFolder = folder; renameDraft = folder.name; showRename = true
                                    }
                                }
                                // Unfiled can be a smart folder like any other.
                                Button(L10n.text("Smart Folder"), systemImage: "sparkles") {
                                    smartFolder = (folder.id.flatMap { try? env.database.identity(ofFolder: $0) }).map(SmartFolderTarget.init)
                                }
                                Button(role: .destructive) {
                                    if let id = folder.id, env.isSiteFavoritesFolder(id) { syncedFolder = folder }
                                    else if folder.name == "미분류", let id = folder.id { deleteFolder(id) }
                                    else { folderPendingDelete = folder }
                                } label: { Label(L10n.text("Delete Folder"), systemImage: "trash") }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .transientMessage($folderMessage)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.text("Search saved works"))
        .autocorrectionDisabled().textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { searchResults = SavedWorksSearch(query: query) }
        }
        .navigationDestination(item: $searchResults) { WorksGridView(search: $0.query).readingQueueClearance() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(for: Folder.self) { folder in
            WorksGridView(folder: folder).readingQueueClearance()
        }
        .toolbar {
            ToolbarItem(placement: .principal) { AppModeSwitch() }
            ToolbarItem(placement: .topBarLeading) {
                LiquidGlassTitleCapsule(L10n.text("Saved"))
            }

            ToolbarItem(placement: .topBarTrailing) {
                AppToolbarActions {
                    Button {
                        showCreateAlert = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .accessibilityLabel(L10n.text("Create Folder"))
                    .accessibilityIdentifier("manga.createFolder")

                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                    }
                }
            }
        }
        .newFolderPrompt(isPresented: $showCreateAlert, identifier: "folder.name") { _ in loadFolders() }
        .appSheet(item: $smartFolder, onDismiss: loadFolders) { FolderRuleEditor(folder: $0.id) }
        .alert(
            L10n.text("Delete the folder '%@'?", String(describing: folderPendingDelete?.name ?? "")),
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            ),
            presenting: folderPendingDelete
        ) { folder in
            Button(L10n.text("Delete"), role: .destructive) {
                if let id = folder.id {
                    deleteFolder(id)
                }
                folderPendingDelete = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                folderPendingDelete = nil
            }
        } message: { _ in
            Text(L10n.text("Works only in this folder move to Unfiled. Works also in other folders stay there."))
        }
        .alert(L10n.text("Synced with Website Favorites"), isPresented: Binding(get: { syncedFolder != nil }, set: { if !$0 { syncedFolder = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { syncedFolder = nil }
        } message: {
            Text(L10n.text("This folder holds a favorites category of a website you're signed in to, so it stays while you're signed in. To delete it, sign out of that website or turn off Sync Favorites with Folders in its settings."))
        }
        .appSheet(isPresented: $showAddSheet, onDismiss: { loadFolders() }) {
            AddWorkSheet()
        }
        .appSheet(isPresented: $reordering, onDismiss: loadFolders) { FolderOrderView(booru: false) }
        .appSheet(item: $editingColorFolder) { folder in
            FolderColorSheet(title: folder.displayName, color: folder.color, others: folders.filter { $0.id != folder.id }.map(\.color)) { color in
                if let id = folder.id { saveColor(folderId: id, color: color) }
            } preview: { color in
                FolderBentoCardView(folder: folder.recolored(color), previews: folder.id.flatMap { previews[$0] } ?? [])
            }
        }
        .background {
            FolderNameAlert(isPresented: $showRename, name: $renameDraft, identifier: "folder.rename", title: "Rename Folder", actionTitle: "Save") { value in
                do { if let id = renamingFolder?.id { try env.database.renameFolder(id: id, name: value) }; loadFolders() }
                catch { editError = error.localizedDescription }
            }
        }
        .alert(L10n.text("Error"), isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { editError = nil }
        } message: { Text(editError ?? "") }
        .task(id: "\(reloadGeneration):\(env.mode == .manga && scenePhase == .active)") {
            await observeFolders()
        }
    }

    @MainActor private func observeFolders() async {
        guard env.mode == .manga, scenePhase == .active else { return }
        do {
            let observation = ValueObservation.tracking { db -> FolderSnapshot in
                let folders = try AppDatabase.fetchFolders(db)
                let previews = try AppDatabase.fetchFolderPreviews(db)
                return FolderSnapshot(folders: folders, previews: previews)
            }.removeDuplicates()
            for try await snapshot in observation.values(in: env.database.dbWriter, bufferingPolicy: .bufferingNewest(1)) {
                try Task.checkCancellation()
                if folders != snapshot.folders { folders = snapshot.folders }
                previews = snapshot.previews
            }
        } catch is CancellationError { }
        catch { editError = error.localizedDescription }
    }

    private struct FolderSnapshot: Equatable {
        let folders: [Folder]
        let previews: [Int64: [Work]]
    }

    private func loadFolders() {
        reloadGeneration += 1
    }

    private func deleteFolder(_ id: Int64) {
        do { try env.database.deleteFolder(id: id) }
        catch { folderMessage = error.localizedDescription }
        loadFolders()
    }

    private func saveColor(folderId: Int64, color: Int64) {
        do { try env.database.setFolderColor(id: folderId, color: color) }
        catch { editError = error.localizedDescription }
    }
}

/// Ten colors no other folder in the library uses, in the palette's order. A pick recolors the
/// folder at once, and a color nobody uses yet takes its place, so each pick brings a new one.
struct FolderColorSheet<Preview: View>: View {
    let title: String
    let others: Set<Int64>
    let apply: (Int64) -> Void
    let preview: (Int64) -> Preview
    @State private var current: Int64
    @State private var choices: [Int64]
    /// Colors this sheet has shown or the folder had, never offered again while it is open.
    @State private var shown: Set<Int64>
    @Environment(\.dismiss) private var dismiss

    init(title: String, color: Int64, others: [Int64], apply: @escaping (Int64) -> Void, @ViewBuilder preview: @escaping (Int64) -> Preview) {
        self.title = title
        self.others = Set(others)
        self.apply = apply
        self.preview = preview
        let choices = FolderPalette.unused(Set(others).union([color]), count: 10)
        _current = State(initialValue: color)
        _choices = State(initialValue: choices)
        _shown = State(initialValue: Set(choices).union([color]))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    preview(current)
                        .frame(maxWidth: 132)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 16) {
                        ForEach(Array(choices.enumerated()), id: \.element) { index, color in
                            Button { pick(color) } label: {
                                Circle()
                                    .fill(Color(argb: color))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                                    .frame(width: 50, height: 50)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                            .accessibilityLabel(L10n.text("Color %@", String(index + 1)))
                            .accessibilityIdentifier("folder.color.\(index)")
                        }
                    }
                    .padding(.horizontal, 20)
                    Text(L10n.text("These are colors no other folder uses. Each color you pick is replaced by a new one."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(L10n.text("%@ color", title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }.accessibilityIdentifier("folder.color.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityIdentifier("folder.colorSheet")
    }

    private func pick(_ color: Int64) {
        guard let index = choices.firstIndex(of: color) else { return }
        apply(color)
        let replacement = FolderPalette.unused(others.union(shown), count: 1).first
        withAnimation(.snappy) {
            current = color
            if let replacement {
                choices[index] = replacement
                shown.insert(replacement)
            } else {
                choices.remove(at: index)
            }
        }
    }
}

extension Folder {
    func recolored(_ color: Int64) -> Folder {
        var folder = self
        folder.color = color
        return folder
    }
}

/// Every place that makes a folder asks with this prompt: a name, and a switch that makes it a smart
/// folder, set up on the next screen. `created` gets the new folder's identity: a comics folder's
/// sync identity, or an image folder's id.
struct NewFolderPromptModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Binding var isPresented: Bool
    var booru = false
    var title = "New Folder"
    var actionTitle = "Create"
    var identifier = "folder.name"
    let created: (String) -> Void
    @State private var name = ""
    @State private var draft: SmartFolderDraft?

    func body(content: Content) -> some View {
        content
            .background {
                FolderNameAlert(isPresented: $isPresented, name: $name, identifier: identifier, title: title, actionTitle: actionTitle,
                                onSmart: { draft = SmartFolderDraft(name: $0) }) { name in
                    if let identity = try? create(name) { created(identity) }
                }.frame(width: 0, height: 0)
            }
            .appSheet(item: $draft) { FolderRuleEditor(booru: booru, name: $0.name, onCreated: created) }
    }

    private func create(_ name: String) throws -> String {
        if booru { return try env.booru.saveFolder(name: name) }
        guard let id = try env.database.createFolder(name: name).id else { throw BooruError.storage }
        return try env.database.identity(ofFolder: id)
    }
}

extension View {
    func newFolderPrompt(isPresented: Binding<Bool>, booru: Bool = false, title: String = "New Folder", actionTitle: String = "Create",
                         identifier: String = "folder.name", created: @escaping (String) -> Void) -> some View {
        modifier(NewFolderPromptModifier(isPresented: isPresented, booru: booru, title: title, actionTitle: actionTitle, identifier: identifier, created: created))
    }
}

/// A shared modal prompt keeps the input inside equal horizontal margins.
/// Present above navigation chrome and sheets without changing system alert internals.
struct FolderNameAlert: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var name: String
    var identifier = "folder.name"
    var title = "New Folder"
    var actionTitle = "Create"
    /// Shows the smart folder switch; a name confirmed with it on comes here instead of `onCreate`.
    var onSmart: ((String) -> Void)? = nil
    let onCreate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.onAppear = { [weak host, weak coordinator = context.coordinator] in
            if let host { coordinator?.update(host) }
        }
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(host)
    }

    final class Host: UIViewController {
        var onAppear: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    final class Coordinator: NSObject {
        var parent: FolderNameAlert
        private weak var prompt: UIViewController?
        init(_ parent: FolderNameAlert) { self.parent = parent }

        func update(_ host: Host) {
            guard parent.isPresented else {
                if let prompt, !prompt.isBeingDismissed { prompt.dismiss(animated: true) }
                return
            }
            guard prompt == nil, host.view.window != nil, host.presentedViewController == nil else { return }
            let content = FolderNamePrompt(name: parent.$name, identifier: parent.identifier, title: parent.title, actionTitle: parent.actionTitle,
                                           offersSmart: parent.onSmart != nil) { [weak self] name, smart in
                guard let self else { return }
                self.parent.isPresented = false
                self.parent.name = ""
                guard let name else { return }
                if smart, let onSmart = self.parent.onSmart { onSmart(name) } else { self.parent.onCreate(name) }
            }
            let prompt = UIHostingController(rootView: content)
            prompt.modalPresentationStyle = .overFullScreen
            prompt.modalTransitionStyle = .crossDissolve
            prompt.view.backgroundColor = .clear
            prompt.view.accessibilityViewIsModal = true
            self.prompt = prompt
            host.present(prompt, animated: true)
        }
    }
}

private struct FolderNamePrompt: View {
    @Binding var name: String
    let identifier: String
    let title: String
    let actionTitle: String
    let offersSmart: Bool
    let finish: (String?, Bool) -> Void
    @State private var smart = false
    @FocusState private var focused: Bool
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            // Darker than a sheet's dimming, so the prompt stands out from whatever is behind it.
            Color.black.opacity(0.55).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 16) {
                Text(L10n.text(title)).font(.headline)
                TextField(L10n.text("Folder Name"), text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16).frame(minHeight: 48)
                    .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .focused($focused).submitLabel(.done)
                    .onSubmit { if !trimmedName.isEmpty { finish(trimmedName, smart) } }
                    .accessibilityIdentifier(identifier)
                if offersSmart {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $smart) { Label(L10n.text("Smart Folder"), systemImage: "sparkles") }
                            .padding(.horizontal, 16).frame(minHeight: 48)
                            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityIdentifier("folder.smart")
                        Text(L10n.text("Files works that match its tags here on their own. You choose the tags next."))
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                    }
                }
                HStack(spacing: 12) {
                    Button { finish(nil, false) } label: {
                        Text(L10n.text("Cancel")).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    Button { finish(trimmedName, smart) } label: {
                        Text(L10n.text(smart ? "Next" : actionTitle)).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("folder.create")
                }
            }
            .padding(24).frame(maxWidth: 360)
            // A solid card rather than glass, so the field and the switch read clearly on any background.
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folder.namePrompt")
            .padding(24)
        }
        .task { focused = true }
        .accessibilityAction(.escape) { finish(nil, false) }
    }
}
