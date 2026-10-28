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
    @State private var showHelp = false
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

    init(booru: Bool = false) {
        self.booru = booru
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
                    if !booru {
                        Button(L10n.text("Reader Guide")) { showHelp = true }.accessibilityIdentifier("reader.settings.help")
                    }
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
        .sheet(isPresented: $showHelp) { ReaderHelpView() }
    }
}

struct ReaderHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @SwiftUI.AppStorage("reader.helpHidden", store: ReaderPreferences.defaults) private var hidden = false
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @SwiftUI.AppStorage("reader.mode", store: ReaderPreferences.defaults) private var mode = ReaderMode.horizontal.rawValue
    @State private var step = 0
    private let titles = [L10n.text("Read with Taps"), L10n.text("Zoom and Translate"), L10n.text("Exit the Work")]
    private var descriptions: [String] { [
        L10n.text("Tap either side to turn pages. Tap the center for the quick menu, or hold anywhere to bookmark."),
        L10n.text("Double tap or pinch to zoom. Drag to position the area you want, then choose Translate in the quick menu."),
        mode == ReaderMode.continuous.rawValue ? L10n.text("In Continuous Scroll, drag down from the top handle to close. Dragging the pages only scrolls.") : L10n.text("At the original zoom level, swipe down to exit. While zoomed, dragging only moves the image. You can also exit from the quick menu.")
    ] }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker(L10n.text("Gesture Guide"), selection: $step) {
                        Text(L10n.text("Taps")).tag(0); Text(L10n.text("Zoom & Translate")).tag(1); Text(L10n.text("Exit")).tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("reader.help.steps")
                    guideImage
                    Text(titles[step]).font(.title3.bold())
                    Text(descriptions[step]).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        ForEach(0..<3) { index in
                            Circle().fill(index == step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(width: 6, height: 6)
                        }
                        Spacer()
                        if step < 2 { Button(L10n.text("Next Tip"), systemImage: "arrow.right") { step += 1 }.accessibilityIdentifier("reader.help.next") }
                    }
                }.padding(16).frame(maxWidth: 460).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button(L10n.text("Don't Show Again")) { hidden = true; dismiss() }
                        .buttonStyle(.bordered).accessibilityIdentifier("reader.help.never")
                    Text(L10n.text("You can reopen this guide in Reader Settings or Settings.")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(12).background(Color(uiColor: .systemBackground))
            }
            .navigationTitle(L10n.text("Reader Guide")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Close")) { dismiss() }.accessibilityIdentifier("reader.help.close") } }
        }.presentationBackground(Color(uiColor: .systemBackground))
    }
    private var guideImage: some View {
        Image("ReaderGuide").resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    ZStack {
                        if step == 0 {
                            HStack(spacing: 0) {
                                Color.blue.opacity(0.12).frame(width: size.width * 0.3)
                                Color.teal.opacity(0.12).frame(width: size.width * 0.4)
                                Color.blue.opacity(0.12).frame(width: size.width * 0.3)
                            }.padding(.vertical, size.height * 0.1)
                            tip(rtl ? L10n.text("Next") : L10n.text("Previous"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.16, y: size.height * 0.43)
                            tip(L10n.text("Quick Menu"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.43)
                            tip(rtl ? L10n.text("Previous") : L10n.text("Next"), icon: "hand.tap.fill")
                                .position(x: size.width * 0.84, y: size.height * 0.43)
                            tip(L10n.text("Hold to bookmark"), icon: "bookmark.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.68)
                        } else if step == 1 {
                            tip(L10n.text("Double tap or pinch to zoom"), icon: "arrow.up.left.and.arrow.down.right")
                                .position(x: size.width * 0.5, y: size.height * 0.27)
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 56, weight: .light)).foregroundStyle(.white)
                                .padding(20).background(.black.opacity(0.65), in: Circle())
                                .position(x: size.width * 0.5, y: size.height * 0.5)
                            tip(L10n.text("Drag to position"), icon: "hand.draw.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.7)
                            tip(L10n.text("Tap center → Translate"), icon: "translate")
                                .position(x: size.width * 0.5, y: size.height * 0.85)
                        } else {
                            tip(L10n.text("At original zoom"), icon: "arrow.down.right.and.arrow.up.left")
                                .position(x: size.width * 0.5, y: size.height * 0.2)
                            Image(systemName: "arrow.down").font(.system(size: 90, weight: .medium)).foregroundStyle(.white)
                                .padding(24).background(.black.opacity(0.65), in: Capsule())
                                .position(x: size.width * 0.5, y: size.height * 0.48)
                            tip(L10n.text("Swipe down to exit"), icon: "hand.draw.fill")
                                .position(x: size.width * 0.5, y: size.height * 0.77)
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .ignore).accessibilityLabel(descriptions[step])
            .accessibilityIdentifier("reader.help.visual")
    }
    private func tip(_ title: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption.bold()).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.white).padding(10).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
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

@MainActor
enum ContentBookmarkAction {
    static func toggle(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> WorkSaveResult {
        if try env.database.getWork(galleryId: id) != nil {
            try env.database.deleteWork(galleryId: id)
            return .removed(.comics)
        }
        return try save(id: id, gallery: gallery, env: env, images: images, context: context)
    }

    static func save(id: Int64, gallery: NativeGallery?, env: AppEnvironment, images: PageImageStore? = nil, context: DiscoveryContext = .unknown) throws -> WorkSaveResult {
        if try env.database.getWork(galleryId: id) != nil { return .unchanged(.comics) }
        let folders = try env.database.listFolders()
        let folder = try folders.first(where: { $0.name == "미분류" }) ?? folders.first ?? env.database.ensureDefaultFolder()
        _ = try env.database.upsertWork(galleryId: id, folderId: folder.id,
            title: gallery?.title, artists: gallery?.artists.joined(separator: ", "),
            language: gallery?.language, type: gallery?.type, tags: gallery?.tags.joined(separator: ", "), metadataSource: "remote", discoveryContext: context)
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
    @MainActor init(_ result: WorkSaveResult) {
        self.result = result
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
    @MainActor static func perform(_ action: () throws -> WorkSaveResult) -> Self {
        do { return Self(try action()) } catch { return Self(.failed) }
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
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let feedback {
                Label { Text(feedback.result.message).font(.subheadline.weight(.semibold)) } icon: {
                    Image(systemName: feedback.result.icon).foregroundStyle(feedback.result.color)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(16).allowsHitTesting(false)
                .accessibilityElement(children: .ignore).accessibilityLabel(feedback.result.message)
                .accessibilityIdentifier(identifier)
                .transition(.opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: feedback?.id)
        .task(id: feedback?.id) {
            guard feedback != nil else { return }
            do { try await Task.sleep(for: .seconds(3)); feedback = nil } catch { }
        }
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
