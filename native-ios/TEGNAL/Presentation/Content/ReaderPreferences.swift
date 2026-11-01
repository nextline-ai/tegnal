import SwiftUI

// A separate defaults suite keeps UI tests from changing the reader preferences on the device.
enum ReaderPreferences {
    static var booruDefaults: UserDefaults {
        #if DEBUG
        if ContentPreferences.isIsolated { return testingBooruDefaults }
        #endif
        return persistentBooruDefaults
    }
    #if DEBUG
    private static let testingBooruDefaults = UserDefaults(suiteName: "work.nextline.tegnal.booru-ui-tests")!
    #endif
    private static let persistentBooruDefaults: UserDefaults = {
        let store = UserDefaults(suiteName: "work.nextline.tegnal.booru.preferences")!
        if !store.bool(forKey: "booru.preferencesSeparated") {
            // Preserve Booru-only options from the earlier shared store, without importing manga reader options.
            for key in ["booru.original", "booru.showNotes", "booru.rememberHistory", "booru.autoLoad", "booru.fitThumbnails"] {
                if let value = UserDefaults.standard.object(forKey: key), store.object(forKey: key) == nil { store.set(value, forKey: key) }
            }
            store.set(true, forKey: "booru.preferencesSeparated")
        }
        return store
    }()

    static var defaults: UserDefaults {
        #if DEBUG
        if ContentUITestSupport.enabled { return ContentUITestSupport.defaults }
        #endif
        return ContentPreferences.defaults
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case horizontal, vertical, continuous
    var id: String { rawValue }
    var title: String {
        switch self {
        case .horizontal: return L10n.text("Horizontal Paging")
        case .vertical: return L10n.text("Vertical Paging")
        case .continuous: return L10n.text("Continuous Scroll")
        }
    }
}

enum MangaThumbnailOpening: Equatable {
    case viewer, information
    static let preferenceKey = "manga.showInformationBeforeReading"
    static func stored(in defaults: UserDefaults = ReaderPreferences.defaults) -> Self {
        defaults.bool(forKey: preferenceKey) ? .information : .viewer
    }
    func route(for id: Int64, context: DiscoveryContext) -> ContentRoute {
        self == .information ? .discoveredGallery(id, context) : .discoveredReader(id, 1, context)
    }
    func url(for id: Int64) -> String {
        self == .information ? MangaUrls.galleryUrl(for: id) : MangaUrls.readerUrl(for: id)
    }
}

enum ReaderResumeBehavior: String, CaseIterable, Identifiable {
    case ask, continueReading, fromBeginning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: L10n.text("Ask Before Continuing")
        case .continueReading: L10n.text("Continue Reading")
        case .fromBeginning: L10n.text("Start from Beginning")
        }
    }

    static func stored(in defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: "reader.resumeBehavior") ?? "") ?? .ask
    }

    func opening(initial: Int, saved: Int, resumesProgress: Bool) -> ReaderOpening {
        guard resumesProgress, initial <= 1, saved > 0 else { return .page(max(1, initial)) }
        switch self {
        case .ask: return .confirmation(saved)
        case .continueReading: return .page(saved)
        case .fromBeginning: return .page(1)
        }
    }
}

enum ReaderOpening: Equatable {
    case page(Int), confirmation(Int)
    var page: Int {
        switch self { case .page(let page), .confirmation(let page): page }
    }
    var needsConfirmation: Bool {
        if case .confirmation = self { return true }
        return false
    }
    var initialPage: Int { needsConfirmation ? 1 : page }
    func resolved(continuing: Bool) -> Self { .page(continuing ? page : 1) }
}

struct ReaderSettingsView: View {
    var booru = false
    @Environment(\.dismiss) private var dismiss
    private var onShowGuide: (() -> Void)?
    @State private var guideQueued = false
    @SwiftUI.AppStorage("reader.resumeBehavior", store: ReaderPreferences.defaults) private var resumeBehavior = ReaderResumeBehavior.ask.rawValue
    @SwiftUI.AppStorage("booru.reducedData", store: ReaderPreferences.booruDefaults) private var reducedData = false
    @SwiftUI.AppStorage("booru.original", store: ReaderPreferences.booruDefaults) private var original = false
    @SwiftUI.AppStorage("booru.showNotes", store: ReaderPreferences.booruDefaults) private var showNotes = true
    @SwiftUI.AppStorage("reader.pagesPerSpread", store: ReaderPreferences.defaults) private var pagesPerSpread = 1
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.defaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.defaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("reader.mode", store: ReaderPreferences.defaults) private var mode = ReaderMode.horizontal.rawValue
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.defaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.defaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.defaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.prefetch", store: ReaderPreferences.defaults) private var prefetch = 3
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.defaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.defaults) private var tapNavigation = true
    @SwiftUI.AppStorage("reader.continuousBackSwipe", store: ReaderPreferences.defaults) private var continuousBackSwipe = false
    @SwiftUI.AppStorage("reader.continuousWorkSwipe", store: ReaderPreferences.defaults) private var continuousWorkSwipe = false
    @SwiftUI.AppStorage("reader.continuousPreviewSwipe", store: ReaderPreferences.defaults) private var continuousInformationSwipe = false

    init(booru: Bool = false, onShowGuide: (() -> Void)? = nil) {
        self.booru = booru
        self.onShowGuide = onShowGuide
        let preferences = booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults
        _pagesPerSpread = SwiftUI.AppStorage(wrappedValue: 1, "reader.pagesPerSpread", store: preferences)
        _autoAdvance = SwiftUI.AppStorage(wrappedValue: false, "reader.autoAdvance", store: preferences)
        _autoSeconds = SwiftUI.AppStorage(wrappedValue: 10.0, "reader.autoSeconds", store: preferences)
        _mode = SwiftUI.AppStorage(wrappedValue: ReaderMode.horizontal.rawValue, "reader.mode", store: preferences)
        _rtl = SwiftUI.AppStorage(wrappedValue: false, "reader.rtl", store: preferences)
        _bottomMenu = SwiftUI.AppStorage(wrappedValue: false, "reader.bottomMenu", store: preferences)
        _pageNumber = SwiftUI.AppStorage(wrappedValue: false, "reader.pageNumber", store: preferences)
        _keepAwake = SwiftUI.AppStorage(wrappedValue: true, "reader.keepAwake", store: preferences)
        _prefetch = SwiftUI.AppStorage(wrappedValue: 3, "reader.prefetch", store: preferences)
        _dimming = SwiftUI.AppStorage(wrappedValue: 0.0, "reader.dimming", store: preferences)
        _tapNavigation = SwiftUI.AppStorage(wrappedValue: true, "reader.tapNavigation", store: preferences)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !booru {
                    Section(L10n.text("Reading Progress")) {
                        Picker(L10n.text("When Reopening a Work"), selection: $resumeBehavior) {
                            ForEach(ReaderResumeBehavior.allCases) { Text($0.title).tag($0.rawValue) }
                        }.accessibilityIdentifier("reader.settings.resumeBehavior")
                    }
                }
                Section(L10n.text("Page Navigation")) {
                    if !booru {
                        Picker(L10n.text("Reading Mode"), selection: $mode) {
                            ForEach(ReaderMode.allCases) { Text($0.title).tag($0.rawValue) }
                        }.accessibilityIdentifier("reader.settings.mode")
                        if mode == ReaderMode.continuous.rawValue {
                            Toggle(isOn: $continuousBackSwipe) {
                                SettingsHelpLabel("Swipe Right to Go Back", help: "In Continuous Scroll, swipe right from the left edge of the safe area to return to the list. Off by default. Swiping elsewhere can still change works if that option is on.")
                            }.accessibilityIdentifier("reader.settings.backSwipe")
                            Toggle(isOn: $continuousWorkSwipe) {
                                SettingsHelpLabel("Swipe Left or Right to Change Works", help: "Switches between works already loaded in the current list. Turn off to keep horizontal swipes from changing works.")
                            }.accessibilityIdentifier("reader.settings.workSwipe")
                            Toggle(isOn: $continuousInformationSwipe) {
                                SettingsHelpLabel("Swipe Up for Work Information", help: "Swipe up from the bottom of a page to open its work information. Off by default in Continuous Scroll so you can scroll without opening a sheet.")
                            }.accessibilityIdentifier("reader.settings.continuousInformationSwipe")
                        }
                        Picker(L10n.text("Pages per View"), selection: $pagesPerSpread) {
                            ForEach(1...4, id: \.self) { Text(L10n.text("Pages: %@", String(describing: $0))).tag($0) }
                        }.accessibilityIdentifier("reader.settings.spread")
                    }
                    Toggle(L10n.text("Read Right to Left"), isOn: $rtl).accessibilityIdentifier("reader.settings.rtl")
                    Toggle(L10n.text("Tap the Sides to Turn Pages"), isOn: $tapNavigation)
                }
                if booru {
                    Section(L10n.text("Media")) {
                        Toggle(L10n.text("Show Notes on Images"), isOn: $showNotes)
                        Toggle(isOn: $original) {
                            SettingsHelpLabel("Load Original Images", help: "Loads the full-size file from the website. This can use more data and take longer to load.")
                        }
                        Toggle(isOn: $reducedData) {
                            SettingsHelpLabel("Reduce Image Data Further", help: "Uses smaller compressed images when available. Load Original Images takes priority over this setting.")
                        }.disabled(original).accessibilityIdentifier("reader.settings.reducedData")
                    }
                }
                Section(L10n.text("Display")) {
                    Toggle(isOn: $bottomMenu) {
                        SettingsHelpLabel("Show Quick Menu at Bottom", help: "Keeps the viewer’s quick actions visible along the bottom of the screen.")
                    }.accessibilityIdentifier("reader.settings.bottomMenu")
                    Toggle(L10n.text("Show Page Number"), isOn: $pageNumber)
                    Toggle(L10n.text("Keep Screen Awake While Reading"), isOn: $keepAwake)
                    VStack(alignment: .leading) {
                        Text(L10n.text("Dim Screen"))
                        Slider(value: $dimming, in: 0...0.65).accessibilityLabel(L10n.text("Dim Screen"))
                    }
                }
                Section(L10n.text("Auto Advance")) {
                    Toggle(isOn: $autoAdvance) {
                        SettingsHelpLabel("Auto Advance", help: "Turns pages at your chosen interval. Pauses while a menu, settings, translation or zoom is open, and stops at the last page.")
                    }.accessibilityIdentifier("reader.settings.auto")
                    Stepper(L10n.text("Advance every %@ seconds", String(describing: Int(autoSeconds))), value: $autoSeconds, in: 2...120, step: 1)
                        .accessibilityIdentifier("reader.settings.seconds").disabled(!autoAdvance)
                }
                if !booru {
                    Section(L10n.text("Loading Options")) {
                        HStack {
                            SettingsHelpLabel("Prefetch Pages", help: "Loads upcoming pages in advance so they open faster. Uses extra data and keeps the images in memory only.")
                            Spacer()
                            Picker(L10n.text("Prefetch Pages"), selection: $prefetch) {
                            Text(L10n.text("Off")).tag(0)
                            Text(L10n.text("2 Pages")).tag(2)
                            Text(L10n.text("3 Pages")).tag(3)
                            Text(L10n.text("5 Pages")).tag(5)
                            }.labelsHidden()
                        }
                    }
                }
                Section(L10n.text("Gesture Guide")) {
                    SettingsHelpLabel("Viewer Gestures", help: booru
                        ? "Tap the center for the quick menu, hold to save, and tap the sides or swipe to change images. Double tap or pinch to zoom. Swipe up from the bottom for details, or swipe down at original zoom to close. For videos, tap with two fingers to open the quick menu."
                        : "Tap the center for the quick menu, hold to save, and double tap or pinch to zoom. Open Work Information from the quick menu or swipe up from the bottom. In Continuous Scroll, enable that gesture above; drag down from the top handle to close.")
                    Button(L10n.text("Reader Guide")) {
                        if let onShowGuide { onShowGuide() }
                        else {
                            (booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults).set(false, forKey: "reader.helpHidden")
                            guideQueued = true
                        }
                    }.accessibilityIdentifier("reader.settings.help")
                }
                Section { SettingsResetButton(booru: booru, viewerOnly: true) }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(L10n.text("Viewer Detail Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() }.accessibilityIdentifier("reader.settings.done") } }
        }
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .alert(L10n.text("Reader Guide"), isPresented: $guideQueued) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { Text(L10n.text("The guide will appear over the next work you open.")) }
    }
}

enum ReaderGuideStep: Int, CaseIterable, Identifiable {
    case navigation, tools, exit
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .navigation: L10n.text("Tap the Center")
        case .tools: L10n.text("Your Quick Menu")
        case .exit: L10n.text("Pull Down to Close")
        }
    }
}

struct ReaderGuideSession {
    private(set) var step: ReaderGuideStep?
    private(set) var hasStarted = false
    mutating func start() { hasStarted = true; step = .navigation }
    mutating func openedMenu() { if step == .navigation { step = .tools } }
    mutating func advance() {
        guard let step else { return }
        self.step = ReaderGuideStep(rawValue: step.rawValue + 1)
    }
    mutating func finish() { step = nil }
}

struct ReaderGuideConfiguration: Equatable {
    let booru: Bool
    let continuous: Bool
    let vertical: Bool
    let rtl: Bool
    let tapNavigation: Bool
    let informationSwipe: Bool
    init(booru: Bool, defaults: UserDefaults) {
        self.booru = booru
        let mode = ReaderMode(rawValue: defaults.string(forKey: "reader.mode") ?? "") ?? .horizontal
        continuous = !booru && mode == .continuous
        vertical = !booru && mode != .horizontal
        rtl = defaults.bool(forKey: "reader.rtl")
        tapNavigation = defaults.object(forKey: "reader.tapNavigation") as? Bool ?? true
        informationSwipe = booru || ReaderInformationReveal.isEnabled(mode: mode.rawValue, continuousOptIn: defaults.bool(forKey: "reader.continuousPreviewSwipe"))
    }
    func instruction(for step: ReaderGuideStep) -> String {
        switch step {
        case .navigation:
            L10n.text(continuous ? "Scroll to read. Tap the center to open your menu." : tapNavigation
                ? "Tap the sides to turn pages. Tap the center to open your menu."
                : "Swipe to turn pages. Tap the center to open your menu.")
        case .tools:
            L10n.text("Open work information, save or translate here. Change how you read in Viewer Detail Settings.")
        case .exit:
            L10n.text(continuous ? "Pull down from the top reading area to return to the list. Move back up to cancel."
                : "Pull the work down to return to the list. Move back up to cancel. Zoom out first.")
        }
    }
}

struct ReaderGuideMenuBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// A coach mark over the real reader. Only the tip card intercepts touches.
struct ReaderGuideOverlay: View {
    let step: ReaderGuideStep
    let configuration: ReaderGuideConfiguration
    var menuBounds: Anchor<CGRect>?
    let next: () -> Void
    let finish: () -> Void

    var body: some View {
        GeometryReader { safeArea in
          GeometryReader { geometry in
            let rect = highlight(in: geometry, safeTop: safeArea.safeAreaInsets.top)
            ZStack {
                ReaderGuideSpotlight(rect: rect).fill(.black.opacity(0.65), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.95), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                if step == .navigation {
                    Image(systemName: "hand.tap.fill").font(.system(size: 36)).foregroundStyle(.white)
                        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false).accessibilityHidden(true)
                } else if step == .exit {
                    Image(systemName: "arrow.down").font(.title.bold()).foregroundStyle(.white)
                        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false).accessibilityHidden(true)
                }
                VStack {
                    if step != .tools { Spacer(minLength: 16) }
                    ReaderGuideTip(step: step, message: configuration.instruction(for: step), next: next, finish: finish)
                        .frame(maxWidth: 420)
                    if step == .tools { Spacer(minLength: 16) }
                }
                .padding(.leading, safeArea.safeAreaInsets.leading + 20)
                .padding(.trailing, safeArea.safeAreaInsets.trailing + 20)
                .padding(.top, safeArea.safeAreaInsets.top + 24)
                .padding(.bottom, safeArea.safeAreaInsets.bottom + 24)
            }
          }.ignoresSafeArea()
        }.accessibilityIdentifier("reader.help.overlay")
    }
    private func highlight(in geometry: GeometryProxy, safeTop: CGFloat) -> CGRect {
        let width = geometry.size.width, height = geometry.size.height
        if step == .tools, let menuBounds { return geometry[menuBounds].insetBy(dx: -4, dy: -4) }
        if step == .exit { return CGRect(x: 12, y: safeTop, width: width - 24, height: 64) }
        return CGRect(x: width * 0.3, y: height * 0.29, width: width * 0.4, height: height * 0.27)
    }
}

private struct ReaderGuideSpotlight: Shape {
    let rect: CGRect
    func path(in bounds: CGRect) -> Path {
        var path = Path(bounds)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: 20, height: 20))
        return path
    }
}

private struct ReaderGuideTip: View {
    let step: ReaderGuideStep
    let message: String
    let next: () -> Void
    let finish: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("Step %@ of %@", String(step.rawValue + 1), "3"))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button(action: finish) { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .accessibilityLabel(L10n.text("Skip Guide")).accessibilityIdentifier("reader.help.close")
            }
            Text(step.title).font(.title2.bold())
            Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
            Button(L10n.text(step == .exit ? "Start Reading" : "Next Tip"), action: next)
                .buttonStyle(.borderedProminent).tint(.accentColor).controlSize(.large).frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("reader.help.next")
        }
        .padding(20).foregroundStyle(.white).tint(.white)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain).accessibilityIdentifier("reader.help.tip")
    }
}

enum ReaderLayout {
    static func count(_ value: Int) -> Int { min(4, max(1, value)) }
    static func start(_ page: Int, count: Int) -> Int { max(0, page) / Self.count(count) * Self.count(count) }
    static func next(_ page: Int, delta: Int, count: Int, total: Int) -> Int {
        min(max(0, start(page, count: count) + delta * Self.count(count)), start(max(0, total - 1), count: count))
    }
    static func initialPage(_ initial: Int, saved: Int, total: Int, count: Int) -> Int {
        let preferred = initial > 1 ? initial : max(initial, saved)
        let page = min(max(1, preferred) - 1, max(0, total - 1))
        return start(page, count: count)
    }
}

/// Lets a removal made by accident come back to where it was, for as long as the app runs.
struct RemovedBookmark {
    let folders: [Int64]
    let note: String?
}

@MainActor
enum ContentBookmarkAction {
    static func toggle(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> WorkSaveResult {
        if let work = try env.database.getWork(galleryId: id) {
            let folders = try env.database.folderIDs(galleryId: id)
            try env.database.deleteWork(galleryId: id)
            env.removedBookmarks[id] = RemovedBookmark(folders: folders, note: work.note)
            return .removed(.comics)
        }
        return try save(id: id, gallery: gallery, env: env, images: images, context: context)
    }

    static func save(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> WorkSaveResult {
        if try env.database.getWork(galleryId: id) != nil { return .unchanged(.comics) }
        let removed = env.removedBookmarks.removeValue(forKey: id)
        let existing = Set(try env.database.listFolders().compactMap(\.id))
        let restored = (removed?.folders ?? []).filter(existing.contains)
        _ = try env.database.upsertWork(galleryId: id, folderId: try restored.first ?? env.database.defaultSaveFolder().id,
            title: gallery?.title, artists: gallery?.artists.joined(separator: ", "),
            language: gallery?.language, type: gallery?.type, tags: gallery?.tags.joined(separator: ", "), metadataSource: "remote", discoveryContext: context)
        for folder in restored.dropFirst() { try env.database.setWork(galleryId: id, folderID: folder, included: true) }
        if let note = removed?.note { try env.database.setNote(galleryId: id, note: note) }
        if let gallery, let page = gallery.pages.first, let images {
            Task {
                do {
                    let image = try await images.load(page, galleryID: id, thumbnail: true)
                    guard try env.database.getWork(galleryId: id) != nil, let data = image.jpegData(compressionQuality: 0.9) else { return }
                    let url = AppStorage.thumbsDirURL.appendingPathComponent("native_\(id).jpg")
                    try data.write(to: url, options: .atomic)
                    try env.database.setThumb(galleryId: id, status: "ready", path: url.path, page: 1)
                } catch { env.startCoverQueue() }
            }
        }
        #if DEBUG
        if !ContentUITestSupport.enabled && !ContentUITestSupport.unitTestsEnabled { env.startCoverQueue() }
        #else
        env.startCoverQueue()
        #endif
        return .added(.comics)
    }
}


/// Shared result and presentation for saves from feeds, recommendations and readers.
enum WorkSaveResult: Equatable {
    case added(TasteMode), removed(TasteMode), unchanged(TasteMode), failed
    static func accessibilityValue(saved: Bool, mode: TasteMode) -> String {
        L10n.text(mode == .comics ? (saved ? "Bookmarked" : "Not bookmarked") : (saved ? "Saved" : "Not favorited"))
    }
    static func actionTitle(saved: Bool, mode: TasteMode) -> String {
        L10n.text(mode == .comics ? (saved ? "Remove Bookmark" : "Bookmark") : (saved ? "Remove Favorite" : "Add Favorite"))
    }
    var message: String {
        switch self {
        case .added(.comics): L10n.text("Saved to bookmarks")
        case .removed(.comics): L10n.text("Bookmark removed")
        case .unchanged: L10n.text("Already bookmarked")
        case .added(.booru): L10n.text("Saved to Favorites")
        case .removed(.booru): L10n.text("Favorite removed")
        case .failed: L10n.text("Unable to save. Please try again.")
        }
    }
    var icon: String {
        switch self {
        case .added(.comics), .unchanged(.comics): "bookmark.fill"
        case .removed(.comics): "bookmark.slash"
        case .added(.booru), .unchanged(.booru): "heart.fill"
        case .removed(.booru): "heart.slash"
        case .failed: "exclamationmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .added(.comics), .unchanged(.comics): .yellow
        case .added(.booru), .unchanged(.booru): .pink
        case .removed: .secondary
        case .failed: .orange
        }
    }
}
struct WorkSaveFeedback: Identifiable {
    let id = UUID()
    let result: WorkSaveResult
    /// The saved comic, while its folder can still be changed from this notice.
    var galleryID: Int64?
    @MainActor init(_ result: WorkSaveResult, galleryID: Int64? = nil) {
        self.result = result
        if result == .added(.comics) { self.galleryID = galleryID }
        Self.haptic(result)
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: result.message) }
    }
    @MainActor static func haptic(_ result: WorkSaveResult) {
        switch result {
        case .added: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .removed, .unchanged: UISelectionFeedbackGenerator().selectionChanged()
        case .failed: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
    @MainActor static func perform(galleryID: Int64? = nil, _ action: () throws -> WorkSaveResult) -> Self {
        do { return Self(try action(), galleryID: galleryID) } catch { return Self(.failed) }
    }
}
@MainActor enum BooruFavoriteAction {
    static func toggle(_ post: BooruPost, store: BooruStore, context: DiscoveryContext) throws -> WorkSaveResult {
        try store.toggleFavorite(post, context: context)
        return store.isFavorite(post) ? .added(.booru) : .removed(.booru)
    }
}
private struct WorkSaveFeedbackModifier: ViewModifier {
    @Binding var feedback: WorkSaveFeedback?
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filing: WorkFolderTarget?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let feedback {
                HStack(spacing: 12) {
                    Label { Text(feedback.result.message).font(.subheadline.weight(.semibold)) } icon: {
                        Image(systemName: feedback.result.icon).foregroundStyle(feedback.result.color)
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel(feedback.result.message)
                    .accessibilityIdentifier(identifier)
                    if let id = feedback.galleryID {
                        Button(L10n.text("Change Folder")) { filing = WorkFolderTarget(id: id); self.feedback = nil }
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier(identifier + ".folder")
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(16).allowsHitTesting(feedback.galleryID != nil)
                .accessibilityElement(children: .contain)
                .transition(.opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: feedback?.id)
        .task(id: feedback?.id) {
            guard let current = feedback else { return }
            do { try await Task.sleep(for: .seconds(current.galleryID == nil ? 3 : 5)); feedback = nil } catch { }
        }
        .appSheet(item: $filing) { WorkFolderSheet(galleryID: $0.id) }
    }
}
extension View {
    func workSaveFeedback(_ feedback: Binding<WorkSaveFeedback?>, identifier: String) -> some View {
        modifier(WorkSaveFeedbackModifier(feedback: feedback, identifier: identifier))
    }
}


/// Matches the compact gray grabber used by work-details sheets.
struct ReaderDismissHandle: View {
    let identifier: String
    let dismiss: () -> Void
    var body: some View {
        Capsule().fill(Color(uiColor: .systemGray2))
            .frame(width: 60, height: 4)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(L10n.text("Swipe down to exit the work"))
            .accessibilityAddTraits(.isButton).accessibilityAction { dismiss() }
    }
}
