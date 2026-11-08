import SwiftUI
import UIKit

// Animation is a single compositor transform, independent of SwiftUI feed updates.
struct SplashTiming: Equatable {
    let hold: TimeInterval
    let slide: TimeInterval
    static let launch = SplashTiming(hold: 1.2, slide: 1.8)
    static let resume = SplashTiming(hold: 0.6, slide: 0.9)
    var total: TimeInterval { hold + slide }
}

@MainActor private enum SplashArtwork {
    // Prepare each original JPEG once; launch and resume reuse the same images.
    static let light = load("splash_light")
    static let dark = load("splash_dark")
    private static func load(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        let image = UIImage(contentsOfFile: url.path)
        return image?.preparingForDisplay() ?? image
    }
    static func make(frame: CGRect, identifier: String) -> UIView {
        let cover = SplashArtworkView(frame: frame)
        cover.accessibilityIdentifier = identifier
        return cover
    }
    static func slide(_ cover: UIView, duration: TimeInterval) {
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : duration,
                       delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            if UIAccessibility.isReduceMotionEnabled { cover.alpha = 0 }
            else { cover.transform = CGAffineTransform(translationX: 0, y: -cover.bounds.height - 1) }
        }
    }
}

/// UIKit traits follow both the app's appearance setting and system changes,
/// including a privacy cover reused after returning from the background.
@MainActor private final class SplashArtworkView: UIView {
    private let imageView = UIImageView()
    private let fallback = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
        isOpaque = true; clipsToBounds = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        fallback.text = L10n.text("TEGNAL"); fallback.textColor = .label
        fallback.font = .systemFont(ofSize: 48, weight: .bold)
        fallback.textAlignment = .center; fallback.adjustsFontSizeToFitWidth = true
        for view in [imageView, fallback] {
            view.frame = bounds; view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SplashArtworkView, _: UITraitCollection) in
            view.updateArtwork()
        }
        updateArtwork()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); updateArtwork() }
    private func updateArtwork() {
        imageView.image = traitCollection.userInterfaceStyle == .dark ? SplashArtwork.dark : SplashArtwork.light
        fallback.isHidden = imageView.image != nil
    }
}

// MARK: - App switcher privacy cover and resume splash
#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private var covers: [ObjectIdentifier: UIView] = [:]
    private var generation = 0
    private var cleanup: Task<Void, Never>?
    init() {}
    func show() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.rootViewController != nil }
        show(in: windows)
    }
    func show(in windows: [UIWindow]) {
        cleanup?.cancel(); cleanup = nil; generation += 1
        UIView.performWithoutAnimation {
            for window in windows {
                let key = ObjectIdentifier(window)
                let cover = covers[key] ?? SplashArtwork.make(frame: window.bounds, identifier: "privacy.cover")
                cover.layer.removeAllAnimations(); cover.transform = .identity; cover.alpha = 1
                cover.frame = window.bounds; cover.isUserInteractionEnabled = true
                cover.accessibilityElementsHidden = false
                window.addSubview(cover); covers[key] = cover
            }
        }
    }
    func hide(timing: SplashTiming = .resume, completion: @escaping @MainActor () -> Void = {}) {
        // Both scenePhase and UIKit notifications can fire for the same activation.
        guard cleanup == nil else { return }
        guard !covers.isEmpty else { completion(); return }
        generation += 1; let current = generation
        if timing.hold == 0 && timing.slide == 0 {
            for cover in covers.values { cover.removeFromSuperview() }
            covers.removeAll(); completion(); return
        }
        cleanup = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timing.hold))
                guard let self, self.generation == current else { return }
                for cover in self.covers.values {
                    cover.isUserInteractionEnabled = false; cover.accessibilityElementsHidden = true
                    SplashArtwork.slide(cover, duration: timing.slide)
                }
                try await Task.sleep(for: .seconds(UIAccessibility.isReduceMotionEnabled ? 0.2 : timing.slide + 0.05))
                guard self.generation == current else { return }
                for cover in self.covers.values { cover.removeFromSuperview() }
                self.covers.removeAll(); self.cleanup = nil; completion()
            } catch { }
        }
    }
}
#else
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private init() {}
    func show() {}
    func hide(timing: SplashTiming = .resume, completion: @escaping @MainActor () -> Void = {}) { completion() }
}
#endif

// SwiftUI owns the host's frame/transform. Animate only its child so layout
// updates cannot reinterpret the exit transform as a new placement.
@MainActor final class SplashContainerView: UIView {
    let artwork = SplashArtwork.make(frame: .zero, identifier: "splash.artwork")
    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "splash.launch"
        addSubview(artwork)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        artwork.bounds = CGRect(origin: .zero, size: bounds.size)
        artwork.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

private struct SplashScreenOverlay: UIViewRepresentable {
    @Binding var isVisible: Bool
    let active: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SplashContainerView { SplashContainerView() }
    func updateUIView(_ view: SplashContainerView, context: Context) {
        if active { context.coordinator.start(view.artwork, finished: { isVisible = false }) }
        else { context.coordinator.cancel(view.artwork) }
    }
    static func dismantleUIView(_ view: SplashContainerView, coordinator: Coordinator) { coordinator.cancel(view.artwork) }
    @MainActor final class Coordinator {
        var work: Task<Void, Never>?
        func start(_ view: UIView, finished: @escaping @MainActor () -> Void) {
            guard work == nil else { return }
            work = Task { [weak view] in
                do {
                    try await Task.sleep(for: .seconds(SplashTiming.launch.hold))
                    guard let view else { return }
                    SplashArtwork.slide(view, duration: SplashTiming.launch.slide)
                    try await Task.sleep(for: .seconds(UIAccessibility.isReduceMotionEnabled ? 0.2 : SplashTiming.launch.slide + 0.05))
                    finished()
                } catch { }
            }
        }
        func cancel(_ view: UIView) {
            work?.cancel(); work = nil
            view.layer.removeAllAnimations(); view.transform = .identity; view.alpha = 1
        }
    }
}

// MARK: - Main Application

@MainActor private final class BackgroundLibrarySync {
    private var task: Task<Void, Never>?
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation = UUID()

    func start(env: AppEnvironment) {
        guard task == nil else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save library to iCloud") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        guard identifier != .invalid else { return }
        let token = UUID(); generation = token
        task = Task { [weak self] in
            defer { self?.finish(generation: token) }
            do {
                // The foreground task is being cancelled by scenePhase; let it
                // release its sync lock before saving the final local changes.
                while env.sync.syncing { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                await env.sync.synchronize(env: env)
            } catch { }
        }
    }
    func cancel() { task?.cancel(); finish() }
    private func finish(generation token: UUID? = nil) {
        guard token == nil || token == generation else { return }
        generation = UUID()
        task = nil
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}

@main
struct TEGNALApp: App {

    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var env = ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled ? ContentUITestSupport.environment() : AppEnvironment.standard()
    #else
    @State private var env = AppEnvironment.standard()
    #endif

    private var isContentUITest: Bool {
        #if DEBUG
        ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled
        #else
        false
        #endif
    }

    @State private var isSplashScreenVisible = true
    @SwiftUI.AppStorage("app.resumeAnimation", store: ContentPreferences.defaults) private var resumeAnimation = true
    @State private var isResumeSplashVisible = false
    @State private var backgroundSync = BackgroundLibrarySync()
    @State private var launchThermalAllowed = ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
    private struct LaunchRequest: Hashable {
        let active: Bool
        let query: GalleryQuery?
        let site: String
        let servers: [BooruServer]
        let booruQuery: String
    }
    private var launchRequest: LaunchRequest {
        let enabled = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--launch-warmup-test")
        let servers = env.booru.selectedServers
        return LaunchRequest(active: enabled && scenePhase == .active && launchThermalAllowed && env.isOnboardingCompleted,
                             query: env.isSiteVerified && !env.booruSafeMode ? env.launchMangaQuery : nil, site: env.mangaSiteAddress,
                             servers: servers, booruQuery: env.booruQuery(""))
    }
    private var splashEnabled: Bool { !isContentUITest || ProcessInfo.processInfo.arguments.contains("--splash-ui-test") }
    // This branch is the final TestFlight build; every Release build asks testers to move to the App Store.
    private var showsTestFlightSunset: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--testflight-sunset")
        #else
        true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                #if DEBUG
                if ContentUITestSupport.libraryJumpTest {
                    NavigationStack {
                        WorksGridView(folder: try? env.database.listFolders().first(where: { $0.name == "이동 테스트" }))
                    }
                } else if ContentUITestSupport.categoryLibraryTest {
                    NavigationStack { WorksGridView() }
                } else if isContentUITest && (ProcessInfo.processInfo.arguments.contains("--native-content-tab-test") || BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled) {
                    AppRootTabView()
                } else if isContentUITest {
                    NativeContentView(source: ContentUITestSupport.source, savesProgress: false)
                } else {
                    AppRootTabView()
                }
                #else
                AppRootTabView()
                #endif

                // The app keeps running underneath so iCloud sync can finish, but it can't be used.
                if showsTestFlightSunset {
                    TestFlightSunsetView().zIndex(9000)
                }

                // Cold launch holds 1.2 seconds and slides for 1.8 seconds while active.
                if isSplashScreenVisible && splashEnabled {
                    SplashScreenOverlay(isVisible: $isSplashScreenVisible, active: scenePhase == .active)
                        .zIndex(9999)
                        .ignoresSafeArea()
                }


                #if targetEnvironment(macCatalyst)
                if scenePhase != .active && !isSplashScreenVisible {
                    SplashScreenOverlay(isVisible: .constant(true), active: false)
                        .clipped().ignoresSafeArea().zIndex(9998)
                }
                #endif
            }
            .task(id: launchRequest) {
                let request = launchRequest
                // After a settings change, visible feeds own the fresh request.
                guard request.active, env.booruSearchRevision == 0 else { return }
                await env.launchFeeds.run(mangaQuery: request.query, site: request.site, servers: request.servers,
                                          preferredMode: env.mode, booruQuery: request.booruQuery)
            }
            .task(id: "\(scenePhase):\(env.sync.enabled):\(isSplashScreenVisible):\(isResumeSplashVisible)") {
                guard !isContentUITest, scenePhase == .active, !isSplashScreenVisible, !isResumeSplashVisible else { return }
                env.pruneSearchHistory()
                var prepareReports = true
                while !Task.isCancelled {
                    if env.sync.enabled {
                        await env.sync.synchronize(env: env)
                        guard !Task.isCancelled else { return }
                        await env.taste.synchronize(env: env)
                    }
                    if prepareReports { await env.taste.prepareCompletedReports(); prepareReports = false }
                    guard env.sync.enabled else { return }
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase != .inactive { DownloadStore.shared.setBackground(phase == .background) }
                guard !isContentUITest else { return }
                env.setCoverQueueActive(phase == .active)
                if phase == .active { backgroundSync.cancel() }
                else if phase == .background, env.sync.enabled { backgroundSync.start(env: env) }
            }
            .onChange(of: env.mode) { _, _ in env.setCoverQueueActive(scenePhase == .active) }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                env.setCoverQueueActive(scenePhase == .active)
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                launchThermalAllowed = ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical
                env.setCoverQueueActive(scenePhase == .active)
            }
            .preferredColorScheme(env.appTheme.colorScheme)
            .environment(\.locale, Locale(identifier: L10n.language))
            .id(env.appLanguage)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                if !isSplashScreenVisible || !splashEnabled { isResumeSplashVisible = true }
                PrivacyCoverManager.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                let timing: SplashTiming = splashEnabled && resumeAnimation && !isSplashScreenVisible ? .resume : .init(hold: 0, slide: 0)
                PrivacyCoverManager.shared.hide(timing: timing) { isResumeSplashVisible = false }
            }
            .appFullScreenCover(isPresented: Binding(
                get: {
                    let allowsOnboarding = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--onboarding-test")
                    return allowsOnboarding && !showsTestFlightSunset && !env.isOnboardingCompleted && (!isSplashScreenVisible || !splashEnabled)
                },
                set: { _ in }
            )) {
                OnboardingView()
            }
            // Include the presenting root and its sheets, not just the tab content.
            // Retained UIKit hosts also inject these same instances at their own roots.
            .environment(env)
            .environment(env.booru)
        }
    }
}

// MARK: - TestFlight sunset

/// Blocks the final TestFlight build and sends testers to the App Store release,
/// which installs over this build and keeps its data.
private struct TestFlightSunsetView: View {
    static let appStore = URL(string: "https://apps.apple.com/app/id6825935560")!
    @Environment(\.openURL) private var openURL
    @State private var showsDetails = false

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 64)).foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(L10n.text("TEGNAL is now on the App Store"))
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    Text(L10n.text("This TestFlight version will no longer be updated and will stop working when it expires. Install the App Store version to keep using TEGNAL. All your data carries over."))
                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    VStack(spacing: 12) {
                        Button { openURL(Self.appStore) } label: {
                            Text(L10n.text("Download Release Version")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("testflightSunset.download")
                        Button { showsDetails = true } label: {
                            Text(L10n.text("Learn More")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("testflightSunset.learnMore")
                    }.padding(.top, 8)
                }
                .padding(28)
                .frame(maxWidth: 440)
                .background(.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
                .padding(24)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("testflightSunset")
        .sheet(isPresented: $showsDetails) { TestFlightSunsetDetails(appStore: Self.appStore) }
    }
}

private struct TestFlightSunsetDetails: View {
    let appStore: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let sections: [(String, String)] = [
        ("Why is TestFlight ending?",
         "TestFlight builds go through their own Apple review, separate from the App Store, and it takes about as long. Keeping a second version that way costs too much, so TestFlight won't be updated from now on. New versions will come out on the App Store."),
        ("When does this version stop working?",
         "This test version expires 90 days after it was uploaded. After that it won't open."),
        ("What happens to my data?",
         "The App Store version installs over this one, so all your data carries over. Important data such as your saved works is also backed up to your private iCloud while iCloud sync is on, so nothing is lost."),
        ("How do I switch?",
         "Tap Download Release Version, then install TEGNAL from the App Store. Don't delete this app first. Deleting it also deletes the data stored on this device."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(sections, id: \.0) { title, body in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text(title)).font(.headline)
                            Text(L10n.text(body)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button { openURL(appStore) } label: {
                        Text(L10n.text("Download Release Version")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("testflightSunset.details.download")
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(L10n.text("Learn More"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }
                }
            }
        }
    }
}
