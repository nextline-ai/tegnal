import SwiftUI
import UniformTypeIdentifiers

/// Every seven days the app is opened, a library with something in it suggests saving a backup
/// file. Only Settings turns the reminder off; the reminder itself offers no "don't show again".
enum BackupReminder {
    static let enabledKey = "backup.reminder.enabled"
    static let lastShownKey = "backup.reminder.lastShown"
    static let lastSavedKey = "backup.lastSaved"
    static let interval: TimeInterval = 7 * 86400

    static var defaults: UserDefaults { ReaderPreferences.defaults }

    static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Due once a week has passed since the reminder last showed, or since the last saved backup.
    /// The first time it is asked, the week starts then, so a new install is not asked at once.
    static func isDue(now: Date = Date(), defaults: UserDefaults = defaults) -> Bool {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return false }
        let shown = defaults.object(forKey: lastShownKey) as? Double
        let saved = defaults.object(forKey: lastSavedKey) as? Double
        guard let last = [shown, saved].compactMap({ $0 }).max() else {
            defaults.set(now.timeIntervalSince1970, forKey: lastShownKey)
            return false
        }
        return now.timeIntervalSince1970 - last >= interval
    }

    static func shown(now: Date = Date(), defaults: UserDefaults = defaults) { defaults.set(now.timeIntervalSince1970, forKey: lastShownKey) }
    static func saved(now: Date = Date(), defaults: UserDefaults = defaults) { defaults.set(now.timeIntervalSince1970, forKey: lastSavedKey) }

    static func filename(now: Date = Date()) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"
        return "tegnal-backup-" + format.string(from: now)
    }
}

/// The backup as a document the system save panel writes where the person chooses.
struct BackupJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Shows the weekly reminder over the app when it comes to the front.
struct BackupReminderModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var asking = false
    @State private var document: BackupJSONDocument?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { check() } }
            .alert(L10n.text("Back Up Your Library"), isPresented: $asking) {
                Button(L10n.text("Save File")) { save() }
                Button(L10n.text("Later"), role: .cancel) {}
            } message: {
                Text(message)
            }
            .fileExporter(isPresented: Binding(get: { document != nil }, set: { if !$0 { document = nil } }),
                          document: document, contentType: .json, defaultFilename: BackupReminder.filename()) { result in
                if case .success = result { BackupReminder.saved() }
                document = nil
            }
            .alert(L10n.text("Unable to create backup: %@", failure ?? ""), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            }
    }

    private var message: String {
        let weekly = L10n.text("Save a backup file about once a week, so your bookmarks, folders and challenges are safe if this device is lost or reset. You can turn this reminder off in Settings.")
        guard env.sync.enabled else { return weekly }
        return L10n.text("Your library is syncing with iCloud, so it is already backed up across your Apple devices. A backup file you keep yourself still helps if iCloud data is removed or you change accounts.") + "\n\n" + weekly
    }

    private func check() {
        #if DEBUG
        if ContentUITestSupport.enabled && !ProcessInfo.processInfo.arguments.contains("--backup-reminder-test") { return }
        #endif
        guard env.isOnboardingCompleted, !asking, document == nil else { return }
        let works = (try? env.database.worksCount()) ?? 0
        guard works > 0 || !env.booru.favoriteIDs.isEmpty else { return }
        #if DEBUG
        let forced = ProcessInfo.processInfo.arguments.contains("--backup-reminder-test")
        #else
        let forced = false
        #endif
        guard forced || BackupReminder.isDue() else { return }
        BackupReminder.shown()
        asking = true
    }

    private func save() {
        let database = env.database, images = env.booru
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try LibraryBackup.export(database: database, images: images) }.value
                document = BackupJSONDocument(data: try Data(contentsOf: url))
            } catch { failure = error.localizedDescription }
        }
    }
}

/// The only place the weekly reminder turns off.
struct BackupReminderToggle: View {
    @SwiftUI.AppStorage(BackupReminder.enabledKey, store: BackupReminder.defaults) private var enabled = true
    var body: some View {
        Toggle(L10n.text("Weekly Backup Reminder"), isOn: $enabled).accessibilityIdentifier("backup.reminder")
    }
}
