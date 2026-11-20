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
    @State private var lockingExport = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var lockedFile: URL?

    var body: some View {
        Section {
            // A backup covers the whole app, so both modes open the same screen.
            NavigationLink { AutomaticBackupsView() } label: {
                HStack {
                    Label(L10n.text("Automatic Backups"), systemImage: "clock.arrow.circlepath")
                    let count = env.backups.items.count
                    if count > 0 { Spacer(); Text(count.formatted()).foregroundStyle(.secondary) }
                }
            }.accessibilityIdentifier("settings.automaticBackups")
            Button { export() } label: {
                HStack {
                    Label(L10n.text("Export JSON Backup"), systemImage: "square.and.arrow.up")
                    if busy { Spacer(); ProgressView() }
                }
            }.accessibilityIdentifier("backup.export")
                .sheet(item: $sharing) { BackupShareSheet(url: $0.url) }
            Button { password = ""; confirmation = ""; lockingExport = true } label: {
                Label(L10n.text("Export with Password…"), systemImage: "lock.doc")
            }.accessibilityIdentifier("backup.exportLocked")
                .alert(L10n.text("Lock Backup with a Password"), isPresented: $lockingExport) {
                    SecureField(L10n.text("Password"), text: $password)
                    SecureField(L10n.text("Confirm Password"), text: $confirmation)
                    Button(L10n.text("Cancel"), role: .cancel) {}
                    Button(L10n.text("Export")) {
                        guard password.count >= 4, password == confirmation else {
                            message = L10n.text("The passwords must match and have at least 4 characters."); return
                        }
                        export(password: password)
                    }
                } message: {
                    Text(L10n.text("Anyone with this password can open the backup. A forgotten password can’t be recovered."))
                }
            Button(L10n.text("Import / Restore JSON Backup"), systemImage: "square.and.arrow.down") { picking = true }
                .accessibilityIdentifier("backup.import")
                .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first { load(url) }
                    else if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }
                }
                .alert(L10n.text("Enter Backup Password"), isPresented: Binding(get: { lockedFile != nil }, set: { if !$0 { lockedFile = nil } })) {
                    SecureField(L10n.text("Password"), text: $password)
                    Button(L10n.text("Cancel"), role: .cancel) { lockedFile = nil }
                    Button(L10n.text("Open")) { if let url = lockedFile { lockedFile = nil; load(url, password: password) } }
                } message: {
                    Text(L10n.text("This backup is locked with a password."))
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
            BackupReminderToggle()
        } header: {
            SettingsHelpLabel("Backup & Restore", help: "Exports both libraries, folders, saved searches and other library data into one JSON file. Media and sign-in details are not included. Importing merges the file with your library.")
        } footer: {
            Text(L10n.text("Every seven days, opening the app suggests saving a backup file."))
        }
        .disabled(busy)
    }

    private func export(password: String? = nil) {
        busy = true; message = nil
        let database = env.database, images = env.booru
        let recentWorks = env.recentWorks.entries, recentImages = env.recentImages.entries
        Task {
            defer { busy = false; self.password = ""; confirmation = "" }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackup.export(database: database, images: images, recentWorks: recentWorks, recentImages: recentImages, password: password)
                }.value
                sharing = BackupFile(url: url)
                BackupReminder.saved()
            } catch { message = L10n.text("Unable to create backup: %@", error.localizedDescription) }
        }
    }

    private func load(_ url: URL, password: String? = nil) {
        busy = true; message = nil
        Task {
            defer { busy = false; self.password = "" }
            do { pending = try await Task.detached(priority: .userInitiated) { try LibraryBackupImport.read(url, password: password) }.value }
            catch LockedBackupError.passwordRequired { lockedFile = url }
            catch LockedBackupError.wrongPassword { message = L10n.text("The password is incorrect.") }
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
                env.recentWorks.merge(backup.comics?.recent_works?.map(\.work) ?? [])
                env.recentImages.merge(backup.images?.recentImages(on: images.servers) ?? [])
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
