import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.tegnalbackup` file; declared in Info.plist so the file picker can filter for it.
    static let tegnalBackup = UTType(exportedAs: "work.nextline.tegnal.backup", conformingTo: .data)
}

/// Words for a backup, shared by the list, the restore question and the "restart now" cover.
enum AutomaticBackupText {
    /// In the app's own language, not the system's.
    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L10n.language)))
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }

    /// What the backup is, from how it was made.
    static func title(_ item: AutomaticBackups.Item) -> String {
        switch item.kind {
        case .minor:
            return item.appVersion.map { L10n.text("Before the update to %@", $0) } ?? L10n.text("Before an update")
        case .patch:
            guard let version = item.appVersion else { return L10n.text("Before an update") }
            // A build-only update has the same version number as the one before it.
            return item.appBuild.map { L10n.text("Before the update to %@ (%@)", version, $0) } ?? L10n.text("Before the update to %@", version)
        case .manual: return L10n.text("Manual backup")
        case .safety: return L10n.text("Before a restore")
        }
    }

    static func dataVersion(_ version: String?) -> String {
        version.map { L10n.text("Data from %@", $0) } ?? L10n.text("Data from an earlier version")
    }
}

/// Backups made before updates, by hand and before restores: see them, restore one, export or delete.
struct AutomaticBackupsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var picking = false
    @State private var sharing: ExportedBackup?
    @State private var restoring: AutomaticBackups.Item?
    @State private var deleting: AutomaticBackups.Item?
    @State private var message: String?
    /// Covers the moment between a tap and the model reporting that it is working.
    @State private var acting = false

    var body: some View {
        let backups = env.backups
        let blocked = acting || backups.isWorking || backups.pendingRestore != nil
        List {
            notices(backups)
            statusSection(backups, blocked: blocked)
            listSection(backups, blocked: blocked)
        }
        .navigationTitle(L10n.text("Automatic Backups")).navigationBarTitleDisplayMode(.inline)
        .task { await backups.refresh() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.tegnalBackup, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    run { if try await backups.importFile(url) != nil { message = L10n.text("The backup was added to the list.") } }
                }
            case .failure(let error):
                if (error as NSError).code != CocoaError.userCancelled.rawValue { message = error.localizedDescription }
            }
        }
        .sheet(item: $sharing) { ExportShareSheet(url: $0.url) }
        .alert(L10n.text("Restore This Backup?"), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }), presenting: restoring) { item in
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Restore"), role: .destructive) { run { try await backups.restore(item) } }
                .accessibilityIdentifier("backups.restoreConfirm")
        } message: { item in
            Text(restoreMessage(item))
        }
        .alert(deleting?.isProtected == true ? L10n.text("Delete an Always-Kept Backup?") : L10n.text("Delete This Backup?"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(item.isProtected ? L10n.text("Delete Anyway") : L10n.text("Delete"), role: .destructive) { run { try await backups.delete(item) } }
                .accessibilityIdentifier("backups.deleteConfirm")
        } message: { item in
            Text(item.isProtected
                 ? L10n.text("TEGNAL keeps this backup whatever the total size, so you can go back after an update. Once it is deleted, you can no longer go back to this version of your data. This can’t be undone.")
                 : L10n.text("This backup is deleted from this device and from iCloud. This can’t be undone."))
        }
    }

    // MARK: Notices

    /// Something that went wrong on its own, or a restore that just finished, in the screen's own words.
    @ViewBuilder private func notices(_ backups: AutomaticBackups) -> some View {
        let report = backups.lastRestore.flatMap { shownReport($0) }
        let failure = backups.lastFailure
        if report != nil || failure != nil {
            Section {
                if let report {
                    HStack(alignment: .top, spacing: 10) {
                        Label {
                            Text(report.succeeded
                                 ? restoredNotice(report)
                                 : L10n.text("The last restore did not finish, so your library was left as it was."))
                        } icon: {
                            Image(systemName: report.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(report.succeeded ? Color.green : Color.orange)
                        }
                        Spacer(minLength: 0)
                        Button(L10n.text("Dismiss")) { backups.dismissRestoreReport() }.buttonStyle(.borderless).font(.footnote)
                    }.accessibilityIdentifier("backups.restoreNotice")
                }
                if let failure {
                    HStack(alignment: .top, spacing: 10) {
                        Label {
                            Text(L10n.text("A backup could not be completed on %@ (TEGNAL %@). Your library was not changed. Back Up Now saves a copy.",
                                           AutomaticBackupText.date(failure.date), failure.appVersion))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                        Button(L10n.text("Dismiss")) { backups.dismissFailure() }.buttonStyle(.borderless).font(.footnote)
                    }.accessibilityIdentifier("backups.failureNotice")
                }
            }
        }
    }

    /// The engine keeps the last report until it is dismissed; it is shown for a week.
    private func shownReport(_ report: BackupRestoreReport) -> BackupRestoreReport? {
        Date().timeIntervalSince(report.date) < 7 * 24 * 3600 ? report : nil
    }

    private func restoredNotice(_ report: BackupRestoreReport) -> String {
        guard let made = BackupName(fileName: report.backup)?.createdAt else { return L10n.text("Your library was restored from a backup.") }
        return L10n.text("Your library was restored from the backup of %@.", AutomaticBackupText.date(made))
    }

    // MARK: Status

    private func statusSection(_ backups: AutomaticBackups, blocked: Bool) -> some View {
        Section {
            Toggle(isOn: Bindable(backups).keepInICloud) {
                Label(L10n.text("Keep in iCloud"), systemImage: "icloud")
            }
            // Without iCloud the switch stays as it was set but cannot change.
            .disabled(!backups.iCloudAvailable)
            .accessibilityIdentifier("backups.keepInICloud")
            LabeledContent(L10n.text("Space Used"), value: L10n.text("%@ of %@", AutomaticBackupText.size(backups.totalSize), AutomaticBackupText.size(backups.limit)))
                .accessibilityIdentifier("backups.size")
            Button {
                run { try await backups.backUpNow() }
            } label: {
                HStack {
                    Label(L10n.text("Back Up Now"), systemImage: "externaldrive.badge.plus")
                    if blocked && backups.pendingRestore == nil { Spacer(); ProgressView() }
                }
            }
            .disabled(blocked)
            .accessibilityIdentifier("backups.backUpNow")
            Button(L10n.text("Import from File"), systemImage: "square.and.arrow.down") { picking = true }
                .disabled(blocked)
                .accessibilityIdentifier("backups.import")
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("backups.message") }
        } footer: {
            if backups.iCloudAvailable {
                Text(L10n.text("New backups are copied to iCloud Drive, so they can come back if you lose this device. This is separate from iCloud Sync."))
            } else {
                Label(L10n.text("iCloud Drive is not available. Backups stay on this device until it is."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: List

    private func listSection(_ backups: AutomaticBackups, blocked: Bool) -> some View {
        Section {
            if backups.items.isEmpty {
                Text(L10n.text("No backups yet. One is made automatically before each update.")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("backups.empty")
            }
            ForEach(backups.items) { item in
                AutomaticBackupRow(item: item, blocked: blocked, restore: { restoring = item }, export: { export(item, backups) }, delete: { deleting = item })
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(L10n.text("Delete"), role: .destructive) { deleting = item }.disabled(blocked)
                        Button(L10n.text("Restore")) { restoring = item }.tint(.accentColor).disabled(blocked)
                    }
            }
        } header: {
            Text(L10n.text("Backups"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Backups are kept up to %@ in total. The two newest backups made before updates, the newest one made before a major update, the newest one made before a restore and the newest one made by hand are always kept; older ones are removed first when the limit is reached.", AutomaticBackupText.size(backups.limit)))
                Text(L10n.text("A backup holds your libraries, folders and settings. It does not hold passwords, sign-ins, downloaded files or covers."))
            }
        }
    }

    private func restoreMessage(_ item: AutomaticBackups.Item) -> String {
        [L10n.text("Everything in TEGNAL is replaced by the backup of %@. It is not merged with what you have now.", AutomaticBackupText.date(item.createdAt)),
         L10n.text("Your current data is backed up first, so you can go back."),
         L10n.text("Passwords, sign-ins, downloaded files and covers are not part of a backup and stay as they are. Website favorites sync asks again how to start."),
         L10n.text("TEGNAL has to be closed and opened again to finish.")].joined(separator: "\n\n")
    }

    // MARK: Work

    /// One action at a time; a failure is shown under the buttons.
    private func run(_ work: @escaping () async throws -> Void) {
        acting = true; message = nil
        Task {
            defer { acting = false }
            do { try await work() } catch { message = error.localizedDescription }
        }
    }

    private func export(_ item: AutomaticBackups.Item, _ backups: AutomaticBackups) {
        run { sharing = ExportedBackup(url: try await backups.export(item)) }
    }
}

private struct AutomaticBackupRow: View {
    let item: AutomaticBackups.Item
    let blocked: Bool
    let restore: () -> Void
    let export: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AutomaticBackupText.date(item.createdAt)).font(.headline)
                Text(AutomaticBackupText.title(item)).font(.subheadline)
                Text(AutomaticBackupText.dataVersion(item.dataVersion) + " · " + AutomaticBackupText.size(item.size))
                    .font(.footnote).foregroundStyle(.secondary)
                if !item.isThisDevice {
                    mark(item.deviceName.map { L10n.text("From %@", $0) } ?? L10n.text("From another device"), "iphone.gen3")
                }
                if item.isProtected {
                    mark(L10n.text("Always kept"), "pin.fill")
                }
                switch item.download {
                case .onDevice: EmptyView()
                case .inCloud: mark(L10n.text("In iCloud, not on this device yet"), "icloud.and.arrow.down")
                case .downloading: mark(L10n.text("Downloading from iCloud…"), "icloud.and.arrow.down")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("backups.row")
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .disabled(blocked)
            .accessibilityLabel(L10n.text("Backup Actions"))
            .accessibilityIdentifier("backups.menu")
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
    }

    /// A small icon and its text on one line; a Label in a list row would indent the text like a row title.
    private func mark(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text)
        }
        .font(.footnote).foregroundStyle(.secondary)
    }

    @ViewBuilder private var actions: some View {
        Button(L10n.text("Restore…"), systemImage: "arrow.counterclockwise", action: restore).accessibilityIdentifier("backups.restore")
        Button(L10n.text("Export to File"), systemImage: "square.and.arrow.up", action: export).accessibilityIdentifier("backups.export")
        Button(L10n.text("Delete…"), systemImage: "trash", role: .destructive, action: delete).accessibilityIdentifier("backups.delete")
    }
}

private struct ExportedBackup: Identifiable { let id = UUID(); let url: URL }
private struct ExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Covers the whole app while a restore waits for the app to be closed and opened again. It has no
/// way out but cancelling: until then nothing has been replaced, and using the app would only be undone.
struct PendingRestoreCover: View {
    @Environment(AppEnvironment.self) private var env
    @State private var failure: String?

    var body: some View {
        let pending = env.backups.pendingRestore
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill").font(.system(size: 64)).foregroundStyle(Color.accentColor)
                Text(L10n.text("Restore Is Ready")).font(.title.bold()).multilineTextAlignment(.center)
                    .accessibilityIdentifier("backups.pending.title")
                if let pending {
                    VStack(spacing: 4) {
                        Text(AutomaticBackupText.date(pending.createdAt)).font(.headline)
                        Text(AutomaticBackupText.dataVersion(pending.dataVersion)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("Close TEGNAL completely, then open it again. The restore finishes while it starts."))
                    .multilineTextAlignment(.center)
                Text(L10n.text("Until then nothing has changed. Cancel the restore to keep using TEGNAL as it is."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480).padding(.horizontal, 28)
            Spacer(minLength: 24)
            Button(role: .destructive) {
                do { try env.backups.cancelPendingRestore() } catch { failure = error.localizedDescription }
            } label: {
                Text(L10n.text("Cancel Restore")).font(.headline).frame(maxWidth: 480).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .padding(.horizontal, 28).padding(.bottom, 32)
            .accessibilityIdentifier("backups.pending.cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .alert(L10n.text("Unable to Save"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("Done"), role: .cancel) {}
        } message: { Text(failure ?? "") }
    }
}
