import SwiftUI

struct BooruBackupView: View {
    @State private var busy = false

    var body: some View {
        Form {
            BooruFolderStyleSection()
            LibraryMaintenanceLinks(booru: true)
            LibraryBackupSection(busy: $busy)
            Section {
                NavigationLink { ChallengeBackupView() } label: { Label { Text(L10n.text("Challenge Backup and Import")) } icon: { Image(systemName: "dice").foregroundStyle(.purple) } }
                NavigationLink { AnimeBoxesImportView() } label: { Label(L10n.text("Import from Another Image Viewer"), systemImage: "square.and.arrow.down.on.square") }
                    .accessibilityIdentifier("booru.importLink")
            }.disabled(busy)
            CloudSyncSection()
        }
        .navigationTitle(L10n.text("Library Management"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension BooruAccountSync {
    /// Folders that stand for a server's favorites lists; they keep their server whatever the style.
    var listFolderIDs: Set<String> {
        Set(store.servers.flatMap { accounts.favorites.state(for: $0.id)?.folders.values.map { $0 } ?? [] })
    }
}

/// Whether image folders belong to one server each or are shared by all servers, switched with a
/// word on what changes.
struct BooruFolderStyleSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pending: BooruFolderStyle?
    @State private var failure: String?

    var body: some View {
        let store = env.booru
        Section {
            Picker(selection: Binding(get: { store.folderStyle }, set: { if $0 != store.folderStyle { pending = $0 } })) {
                ForEach(BooruFolderStyle.allCases) { Text(L10n.text($0.title)).tag($0) }
            } label: {
                SettingsHelpLabel("Folder Style", help: "Each Server's Own Folders: a folder holds one server's images and shows when that server is chosen; new folders belong to the server you're browsing. Folders Shared by All Servers: folders hold images from any server, as before.")
            }.accessibilityIdentifier("booru.folderStyle")
        } header: { Text(L10n.text("Folders")) }
        .confirmationDialog(L10n.text("Change Folder Style?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Change")) { if let style = pending { adopt(style) } }
        } message: { Text(pending.map { BooruFolderStyleSheet.effect($0, impact: store.folderStyleImpact()) } ?? "") }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("Done"), role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func adopt(_ style: BooruFolderStyle) {
        do { try env.booru.adoptFolderStyle(style, kept: env.booruAccounts.listFolderIDs) } catch { failure = error.localizedDescription }
    }
}

/// Asked once of a library from before server folders: give each server its own folders, or keep
/// the folders shared as they were. Nothing changes until one is chosen.
struct BooruFolderStyleSheet: View {
    @Environment(AppEnvironment.self) private var env
    @State private var impact: (folders: Int, mixed: Int) = (0, 0)
    @State private var failure: String?

    /// What switching to a style does, in a sentence or two.
    static func effect(_ style: BooruFolderStyle, impact: (folders: Int, mixed: Int)) -> String {
        switch style {
        case .byServer:
            return impact.mixed > 0
                ? L10n.text("Each folder goes to the server its images come from. %@ folders hold images from several servers; each becomes one folder of the same name for each server. New folders belong to the server you're browsing.", impact.mixed.formatted())
                : L10n.text("Each folder goes to the server its images come from. New folders belong to the server you're browsing.")
        case .shared:
            return L10n.text("Folders hold images from any server, as before. A server's copy of a folder joins the folder it came from. Folders kept with a server's favorites stay with that server.")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.text("Image folders can now belong to a server, so each server shows only its own folders. Choose how your folders work; you can change it later in Library Management."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    choice(.byServer, systemImage: "server.rack", detail: Self.effect(.byServer, impact: impact))
                }
                Section {
                    choice(.shared, systemImage: "folder", detail: L10n.text("Folders stay exactly as they are and hold images from any server. New folders are shared too."))
                }
            }
            .navigationTitle(L10n.text("Image Folders")).navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .task { impact = env.booru.folderStyleImpact() }
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("Done"), role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func choice(_ style: BooruFolderStyle, systemImage: String, detail: String) -> some View {
        Button {
            do { try env.booru.adoptFolderStyle(style, kept: env.booruAccounts.listFolderIDs) } catch { failure = error.localizedDescription }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(style.title)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("booru.folderStyle.\(style.rawValue)")
    }
}
