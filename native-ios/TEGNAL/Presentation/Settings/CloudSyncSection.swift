import SwiftUI

/// The iCloud switch sits at the end of both Library Management screens. Turning it on is one
/// tap; turning it off opens `CloudSyncTurnOffView`, and the switch stays on until that finishes.
struct CloudSyncSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var turningOff = false
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { env.sync.enabled }, set: { value in
                if value { env.sync.enabled = true; Task { await env.sync.synchronize(env: env) } }
                else { turningOff = true }
            })) {
                SettingsHelpLabel("iCloud Sync", help: "Keeps both libraries, folders and general settings in sync across your devices. Layout, viewer preferences, downloaded media and sign-in details stay on each device.")
            }
            .accessibilityIdentifier("settings.icloud")
            .appSheet(isPresented: $turningOff) { CloudSyncTurnOffView() }
            if let bytes = env.sync.documentBytes {
                LabeledContent(L10n.text("This Device’s Sync Data"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if let bytes = env.sync.cloudBytes, env.sync.cloudDocumentCount > 0 {
                LabeledContent(L10n.text("iCloud Sync Documents"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if env.sync.enabled {
                Button(L10n.text("Sync Now"), systemImage: "arrow.triangle.2.circlepath") { Task { await env.sync.synchronize(env: env) } }
                    .disabled(env.sync.syncing)
            }
        } header: {
            Text("iCloud")
        } footer: {
            if env.sync.enabled {
                Text(env.sync.status).accessibilityIdentifier("settings.icloudStatus")
            } else {
                Label(L10n.text("iCloud Sync is off. Your library is saved only on this device."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).accessibilityIdentifier("settings.icloudStatus")
            }
        }
    }
}

/// Turning sync off takes three deliberate steps: read everything that stops, acknowledge it, then
/// hold a button. Each page leads with keeping sync on; the way forward is small, at the end.
/// `alreadyOff` is the one-time reminder for sync left off before this screen existed: the main
/// button turns sync back on, and only the same three steps leave it off.
struct CloudSyncTurnOffView: View {
    static let readingSeconds = 10
    static let holdSeconds = 5.0
    /// A 2,000-bookmark library syncs in about 5 MB, 0.1% of the free 5 GB iCloud plan.
    static let sampleBookmarks = 2_000
    static let sampleBytes: Int64 = 5_000_000
    static let freeICloudBytes: Int64 = 5_000_000_000

    var alreadyOff = false

    private enum Step: Int, CaseIterable { case losses, acknowledge, hold }
    private enum Acknowledgment: String, CaseIterable, Identifiable {
        case deviceOnly, deletion, otherDevices
        var id: String { rawValue }
        var text: String {
            switch self {
            case .deviceOnly: L10n.text("I understand my library will be saved only on this device.")
            case .deletion: L10n.text("I understand that deleting TEGNAL or losing this device can erase what isn’t in iCloud.")
            case .otherDevices: L10n.text("I understand my other devices will stop getting my changes.")
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.losses
    @State private var countdown = Self.readingSeconds
    @State private var acknowledged: Set<Acknowledgment> = []
    @State private var footprint = CloudSyncFootprint()
    @State private var backup: BackupJSONDocument?
    @State private var preparingBackup = false
    @State private var backupFailure: String?
    @State private var turnedOff = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch step {
                    case .losses: losses
                    case .acknowledge: acknowledgments
                    case .hold: hold
                    }
                }
                .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
                .animation(.snappy, value: step)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button { keepSyncOn() } label: {
                    Text(L10n.text(alreadyOff ? "Turn iCloud Sync Back On" : "Keep iCloud Sync On")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("icloudOff.keep")
                .padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .losses {
                        Button { step = Step(rawValue: step.rawValue - 1) ?? .losses } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel(L10n.text("Back"))
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ForEach(Step.allCases, id: \.self) { item in
                            Capsule().fill(item.rawValue <= step.rawValue ? Color.orange : Color.secondary.opacity(0.25)).frame(width: 28, height: 4)
                        }
                    }.accessibilityHidden(true)
                }
            }
            .task { footprint = CloudSyncFootprint(env: env) }
            .task(id: step) {
                guard step == .losses else { return }
                while countdown > 0 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    countdown -= 1
                }
            }
            .fileExporter(isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } }),
                          document: backup, contentType: .json, defaultFilename: BackupReminder.filename()) { result in
                if case .success = result { BackupReminder.saved(); footprint.lastBackup = Date() }
                backup = nil
            }
            .alert(L10n.text("Unable to create backup: %@", backupFailure ?? ""), isPresented: Binding(get: { backupFailure != nil }, set: { if !$0 { backupFailure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            }
            .sensoryFeedback(.warning, trigger: turnedOff)
        }
        .presentationDragIndicator(alreadyOff ? .hidden : .visible)
        // Swiping the warning away keeps sync on; the reminder only closes by choosing.
        .interactiveDismissDisabled(alreadyOff)
        .accessibilityIdentifier("icloudOff")
    }

    private func keepSyncOn() {
        if !env.sync.enabled {
            env.sync.enabled = true
            let env = env
            Task { await env.sync.synchronize(env: env) }
        }
        env.sync.offReminderAnswered()
        dismiss()
    }

    // MARK: Step 1 — everything that stops

    private var losses: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 56)).symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(L10n.text(alreadyOff ? "iCloud Sync Is Off" : "Turn Off iCloud Sync?")).font(.largeTitle.bold())
            Text(L10n.text(alreadyOff
                ? "Your library isn’t backed up to iCloud right now. Here is everything you miss while it is off."
                : "iCloud Sync is what keeps your library safe. Here is everything that stops when it is off."))
                .foregroundStyle(.secondary)
            storageCard
            footprintCard
            VStack(alignment: .leading, spacing: 0) {
                lossRow("externaldrive.badge.xmark", .red, "Your Library Is No Longer Backed Up",
                        "Bookmarks, image favorites, folders and notes you save from now on stay only on this device.")
                Divider().padding(.leading, 56)
                lossRow("trash.fill", .red, "Deleting the App Can Erase Them",
                        "If TEGNAL is deleted, or this device is lost, reset or replaced, anything saved after today can’t be restored from iCloud.")
                Divider().padding(.leading, 56)
                lossRow("ipad.and.iphone", .orange, "Your Other Devices Stop Updating",
                        "Saves and edits on this device won’t reach your other devices, and theirs won’t reach this one.")
                Divider().padding(.leading, 56)
                lossRow("folder.fill", .orange, "Your Organization Stays Behind",
                        "Folder order and colors, smart folder rules, saved searches, search history and challenges no longer carry over.")
                Divider().padding(.leading, 56)
                lossRow("gearshape.2.fill", .gray, "Settings Stop Following You",
                        "Theme, language, default tags and other general settings no longer carry over.")
                Divider().padding(.leading, 56)
                lossRow("chart.bar.xaxis", .purple, "Taste Analysis and History Stay Here",
                        "Taste analysis, recaps and recently opened works and images are no longer shared between devices.")
            }
            .padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Text(L10n.text("What is already in iCloud stays there, but it is no longer updated."))
                .font(.footnote).foregroundStyle(.secondary)
            forwardLink(countdown > 0 ? L10n.text("Continue (%@)", String(countdown)) : L10n.text("Continue"), enabled: countdown == 0) {
                step = .acknowledge
            }
        }
    }

    /// Answers the storage worry up front: the bar is the free 5 GB, and the library is a sliver.
    private var storageCard: some View {
        let share = Double(Self.sampleBytes) / Double(Self.freeICloudBytes)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text(L10n.text("Uses Almost No iCloud Storage")).font(.headline)
            }
            // The size stays on one line; the bookmark count moves under it when both don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { storageSize; storageSample }
                VStack(alignment: .leading, spacing: 2) { storageSize; storageSample }
            }
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(Color.green).frame(width: max(5, proxy.size.width * share))
                    }
                }
                .frame(height: 10)
                HStack {
                    Text(L10n.text("About %@ of the free %@", share.formatted(.percent.precision(.fractionLength(1))),
                                   Self.freeICloudBytes.formatted(.byteCount(style: .file))))
                        .foregroundStyle(.green)
                    Spacer()
                    Text(Self.freeICloudBytes.formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Text(L10n.text("Every Apple account comes with 5 GB of iCloud storage for free. Syncing your library barely touches it."))
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let bytes = env.sync.documentBytes {
                LabeledContent(L10n.text("This Device’s Sync Data"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.subheadline)
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("icloudOff.storage")
    }

    private var storageSize: some View {
        Text(L10n.text("Approximately %@", Self.sampleBytes.formatted(.byteCount(style: .file))))
            .font(.system(.largeTitle, design: .rounded).bold()).foregroundStyle(.green)
            .lineLimit(1).fixedSize()
    }

    private var storageSample: some View {
        Text(L10n.text("for %@ bookmarks", Self.sampleBookmarks.formatted()))
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
    }

    private var footprintCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(alreadyOff ? "What iCloud Sync Would Protect" : "What iCloud Sync Protects Now")).font(.headline)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tile(footprint.works, "Saved Works", "book.closed.fill")
                    tile(footprint.comicFolders, "Comics Folders", "folder.fill")
                }
                GridRow {
                    tile(footprint.images, "Saved Images", "photo.fill")
                    tile(footprint.imageFolders, "Image Folders", "folder.fill")
                }
            }
            Divider()
            LabeledContent(L10n.text("Last Backup File")) {
                Text(footprint.lastBackupText).foregroundStyle(footprint.backupIsStale ? Color.orange : Color.secondary)
            }
            .font(.subheadline).accessibilityIdentifier("icloudOff.lastBackup")
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func tile(_ count: Int, _ title: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(.tint)
            Text(count.formatted()).font(.title2.bold()).monospacedDigit()
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func lossRow(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(tint.gradient, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.headline)
                Text(L10n.text(detail)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 2 — back up, then acknowledge each loss

    private var acknowledgments: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checklist")
                .font(.system(size: 52)).symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(L10n.text("Before You Turn It Off")).font(.largeTitle.bold())
            Text(L10n.text("Without iCloud Sync, a backup file you keep is the surest way to get your library back."))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.text("Save a Backup File First"), systemImage: "square.and.arrow.down.on.square").font(.headline)
                Text(L10n.text("Saves both libraries, folders and challenges into one file you can keep in Files."))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button { saveBackup() } label: {
                        if preparingBackup { ProgressView() } else { Text(L10n.text("Save Backup File")) }
                    }
                    .buttonStyle(.bordered).disabled(preparingBackup).accessibilityIdentifier("icloudOff.backup")
                    Spacer()
                    if !footprint.backupIsStale {
                        Label(L10n.text("Backup Saved"), systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
                    }
                }
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Text(L10n.text("Check each item to continue.")).font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Acknowledgment.allCases) { item in
                    let checked = acknowledged.contains(item)
                    Button {
                        if checked { acknowledged.remove(item) } else { acknowledged.insert(item) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(checked ? Color.orange : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                            Text(item.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(checked ? .isSelected : [])
                    .accessibilityIdentifier("icloudOff.ack." + item.rawValue)
                    if item != Acknowledgment.allCases.last { Divider().padding(.leading, 50) }
                }
            }
            .padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            forwardLink(L10n.text("Continue"), enabled: acknowledged.count == Acknowledgment.allCases.count) { step = .hold }
        }
    }

    private func saveBackup() {
        preparingBackup = true
        let database = env.database, images = env.booru
        let recentWorks = env.recentWorks.entries, recentImages = env.recentImages.entries
        Task {
            defer { preparingBackup = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LibraryBackup.export(database: database, images: images, recentWorks: recentWorks, recentImages: recentImages)
                }.value
                backup = BackupJSONDocument(data: try Data(contentsOf: url))
            } catch { backupFailure = error.localizedDescription }
        }
    }

    // MARK: Step 3 — hold to turn off

    private var hold: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "icloud.slash.fill")
                .font(.system(size: 52)).symbolRenderingMode(.hierarchical).foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(L10n.text(alreadyOff ? "Keep iCloud Sync Off" : "Turn Off iCloud Sync")).font(.largeTitle.bold())
            Text(L10n.text("Touch and hold the button for %@ seconds. Letting go early cancels.", String(Int(Self.holdSeconds))))
                .foregroundStyle(.secondary)
            HoldToConfirmButton(title: alreadyOff ? "Hold to Keep It Off" : "Hold to Turn Off", duration: Self.holdSeconds) {
                env.sync.enabled = false
                env.sync.offReminderAnswered()
                turnedOff = true
                dismiss()
            }
            .padding(.vertical, 8)
            Text(L10n.text(alreadyOff
                ? "Changes on this device won’t sync. You can turn iCloud Sync on later in Library Management."
                : "Changes on this device will stop syncing. Existing data on this device and in iCloud will be kept. Turning sync on again will merge changes."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The way forward is a quiet line at the very end of the page, below everything to read.
    private func forwardLink(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote).monospacedDigit()
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.5))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .padding(.top, 12)
        .accessibilityIdentifier("icloudOff.continue")
    }
}

/// What the person has in the library now, shown before sync can be turned off.
struct CloudSyncFootprint {
    var works = 0
    var comicFolders = 0
    var images = 0
    var imageFolders = 0
    var lastBackup: Date?

    init() {}
    @MainActor init(env: AppEnvironment) {
        works = (try? env.database.worksCount()) ?? 0
        comicFolders = (try? env.database.listFolders().count) ?? 0
        images = env.booru.favoriteIDs.count
        imageFolders = env.booru.folders().count
        if let saved = BackupReminder.defaults.object(forKey: BackupReminder.lastSavedKey) as? Double {
            lastBackup = Date(timeIntervalSince1970: saved)
        }
    }

    /// No backup file, or none in the last week.
    var backupIsStale: Bool {
        guard let lastBackup else { return true }
        return Date().timeIntervalSince(lastBackup) >= BackupReminder.interval
    }

    var lastBackupText: String {
        guard let lastBackup else { return L10n.text("Never Saved") }
        return lastBackup.formatted(.relative(presentation: .named))
    }
}

/// Fills over `duration` while pressed and acts only when the press lasts the whole time.
private struct HoldToConfirmButton: View {
    let title: String
    let duration: Double
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var pressing = false

    var body: some View {
        Text(L10n.text(pressing ? "Keep Holding…" : title))
            .font(.headline).foregroundStyle(.red)
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.12))
                        Capsule().fill(Color.red.opacity(0.3)).frame(width: proxy.size.width * progress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
                action()
            } onPressingChanged: { isPressing in
                pressing = isPressing
                if isPressing { withAnimation(.linear(duration: duration)) { progress = 1 } }
                else { withAnimation(.easeOut(duration: 0.25)) { progress = 0 } }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, new in new }
            .accessibilityElement()
            .accessibilityLabel(L10n.text(title))
            .accessibilityHint(L10n.text("Touch and hold the button for %@ seconds. Letting go early cancels.", String(Int(duration))))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("icloudOff.hold")
    }
}
