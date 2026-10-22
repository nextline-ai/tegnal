import SwiftUI
import UniformTypeIdentifiers

/// Both library-management screens use the same file format and restore path.
struct LibraryBackupSection: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var busy: Bool
    var onRestore: () -> Void = {}
    @State private var picking = false
    @State private var pending: LibraryBackupImport?
    @State private var sharing: BackupFile?
    @State private var message: String?

    var body: some View {
        Section {
            Button { export() } label: {
                HStack {
                    Label(L10n.text("Export JSON Backup"), systemImage: "square.and.arrow.up")
                    if busy { Spacer(); ProgressView() }
                }
            }.accessibilityIdentifier("backup.export")
                .sheet(item: $sharing) { BackupShareSheet(url: $0.url) }
            Button(L10n.text("Import / Restore JSON Backup"), systemImage: "square.and.arrow.down") { picking = true }
                .accessibilityIdentifier("backup.import")
                .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first { load(url) }
                    else if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }
                }
                .alert(L10n.text("Restore Backup?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                    Button(L10n.text("Cancel"), role: .cancel) { pending = nil }
                    Button(L10n.text("Restore")) { if let backup = pending { pending = nil; restore(backup) } }
                } message: {
                    if let pending {
                        Text(L10n.text("Comics: %@ · Images: %@ · Challenges: %@", String(pending.comics?.works.count ?? 0), String(pending.images?.favorites.count ?? 0), String(pending.challenges?.games.count ?? 0)))
                        Text(L10n.text("The backup will be merged with your library. Matching favorites, folder colors and order will use the backup values. These changes also sync when iCloud is enabled."))
                    }
                }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text(L10n.text("Backup & Restore")) } footer: {
            Text(L10n.text("One JSON file backs up both Comics and Image libraries, including folders, saved works, artists, tags, searches, servers, blacklists and challenge definitions. Media, caches and sign-in details are not included. Older separate backups can also be imported."))
        }
        .disabled(busy)
    }

    private func export() {
        busy = true; message = nil
        let database = env.database, images = env.booru
        Task {
            defer { busy = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) { try LibraryBackup.export(database: database, images: images) }.value
                sharing = BackupFile(url: url)
            } catch { message = L10n.text("Unable to create backup: %@", error.localizedDescription) }
        }
    }

    private func load(_ url: URL) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { pending = try await Task.detached(priority: .userInitiated) { try LibraryBackupImport.read(url) }.value }
            catch { message = L10n.text("Unable to restore backup: %@", error.localizedDescription) }
        }
    }

    private func restore(_ backup: LibraryBackupImport) {
        busy = true; message = nil
        let database = env.database, images = env.booru
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) { try backup.restore(database: database, images: images) }.value
                try images.refresh()
                database.syncFoldersToAppGroup()
                env.startCoverQueue()
                env.sync.libraryRestored()
                onRestore()
                message = L10n.text("Backup restored: %@ works, %@ folders", String(backup.workCount), String(backup.folderCount))
                await env.sync.synchronize(env: env)
            } catch { message = L10n.text("Unable to restore backup: %@", error.localizedDescription) }
        }
    }
}

private struct BackupFile: Identifiable { let id = UUID(); let url: URL }
private struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
