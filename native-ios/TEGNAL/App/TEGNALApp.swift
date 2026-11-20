import SwiftUI
import UIKit

// MARK: - App switcher privacy cover

/// What hides the app in the app switcher: the home scene's blurred first frame, the same picture
/// the app starts from. Coming back, it simply fades.
#if os(iOS) && !targetEnvironment(macCatalyst)
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    static let fade: TimeInterval = 0.3
    private var covers: [ObjectIdentifier: UIView] = [:]
    private var generation = 0
    private var leaving = false
    init() {}
    func show() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.rootViewController != nil }
        show(in: windows)
    }
    func show(in windows: [UIWindow]) {
        generation += 1; leaving = false
        UIView.performWithoutAnimation {
            for window in windows {
                let key = ObjectIdentifier(window)
                let cover = covers[key] ?? {
                    let view = HomeStillView()
                    view.accessibilityIdentifier = "privacy.cover"
                    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    return view
                }()
                cover.layer.removeAllAnimations(); cover.alpha = 1
                cover.frame = window.bounds; cover.isUserInteractionEnabled = true
                cover.accessibilityElementsHidden = false
                window.addSubview(cover); covers[key] = cover
            }
        }
    }
    func hide(animated: Bool = true, completion: @escaping @MainActor () -> Void = {}) {
        // Both scenePhase and UIKit notifications can fire for the same activation.
        guard !leaving else { return }
        guard !covers.isEmpty else { completion(); return }
        generation += 1; let current = generation
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            for cover in covers.values { cover.removeFromSuperview() }
            covers.removeAll(); completion(); return
        }
        leaving = true
        let fading = Array(covers.values)
        for cover in fading { cover.isUserInteractionEnabled = false; cover.accessibilityElementsHidden = true }
        UIView.animate(withDuration: Self.fade, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            for cover in fading { cover.alpha = 0 }
        } completion: { [weak self] _ in
            // The app can leave again before the fade ends; the cover then stays where it was put back.
            guard let self, self.generation == current else { return }
            for cover in self.covers.values { cover.removeFromSuperview() }
            self.covers.removeAll(); self.leaving = false; completion()
        }
    }
}
#else
@MainActor final class PrivacyCoverManager {
    static let shared = PrivacyCoverManager()
    private init() {}
    func show() {}
    func hide(animated: Bool = true, completion: @escaping @MainActor () -> Void = {}) { completion() }
}

/// On the Mac the window stays on screen when the app is not in front; the same still covers it.
private struct InactiveCover: UIViewRepresentable {
    func makeUIView(context: Context) -> HomeStillView { HomeStillView() }
    func updateUIView(_ view: HomeStillView, context: Context) {}
}
#endif

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

    @State private var stage = HomeStage.shared
    /// The home scene opens from a blur, as the splash once slid away; what waited for the splash waits for that.
    private var isSplashScreenVisible: Bool { stage.enabled && !stage.introFinished }
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
        // The first pages are read ahead only for someone on the way to the library.
        return LaunchRequest(active: enabled && stage.libraryWarm && scenePhase == .active && launchThermalAllowed && env.isOnboardingCompleted,
                             query: env.isSiteVerified && !env.booruSafeMode ? env.launchMangaQuery : nil, site: env.mangaSiteAddress,
                             servers: servers, booruQuery: "")
    }
    private var splashEnabled: Bool { stage.enabled }

    init() {
        // Encrypted DNS is the first thing set, before any request leaves the app.
        EncryptedDNS.applyStored()
        AppAudio.useMediaVolume()
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
                    HomeRootView()
                } else if isContentUITest {
                    NativeContentView(source: ContentUITestSupport.source, savesProgress: false)
                } else {
                    HomeRootView()
                }
                #else
                HomeRootView()
                #endif

                #if targetEnvironment(macCatalyst)
                if scenePhase != .active && !isSplashScreenVisible {
                    InactiveCover().ignoresSafeArea().zIndex(9998)
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
            // Keeps each signed-in website's favorites and its folder the same while the app is open.
            .task(id: "\(scenePhase):\(isSplashScreenVisible):\(stage.libraryWarm):favorites") {
                guard !isContentUITest, scenePhase == .active, !isSplashScreenVisible, stage.libraryWarm else { return }
                await env.runSiteFavoritesSync()
            }
            // The same for each signed-in image server.
            .task(id: "\(scenePhase):\(isSplashScreenVisible):\(stage.libraryWarm):booruFavorites") {
                guard !isContentUITest, scenePhase == .active, !isSplashScreenVisible, stage.libraryWarm else { return }
                await env.booruAccounts.run()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase != .inactive { DownloadStore.shared.setBackground(phase == .background) }
                guard !isContentUITest else { return }
                // A recording that is still running keeps its cover after the return animation.
                if phase == .active { ScreenCaptureGuard.shared.start(); ScreenCaptureGuard.shared.update() }
                env.setCoverQueueActive(phase == .active)
                if phase == .active { backgroundSync.cancel() }
                else if phase == .background, env.sync.enabled { backgroundSync.start(env: env) }
            }
            // An app set to open in a place goes straight on to it: after the blur, or once it has been set up.
            .onChange(of: stage.introFinished) { _, finished in if finished, env.isOnboardingCompleted || isContentUITest { stage.openPreferred() } }
            .onChange(of: env.isOnboardingCompleted) { _, completed in if completed { stage.openPreferred(after: 0.7) } }
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
            // The home scene fills the whole screen. This is set outside the part that is rebuilt for a new
            // language: set inside it, the status bar stayed hidden after the rebuild.
            .statusBarHidden(stage.atHome)
            .persistentSystemOverlays(stage.atHome ? .hidden : .automatic)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                if !isSplashScreenVisible || !splashEnabled { isResumeSplashVisible = true }
                PrivacyCoverManager.shared.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                PrivacyCoverManager.shared.hide(animated: splashEnabled && !isSplashScreenVisible) { isResumeSplashVisible = false }
            }
            .appFullScreenCover(isPresented: Binding(
                get: {
                    let allowsOnboarding = !isContentUITest || ProcessInfo.processInfo.arguments.contains("--onboarding-test")
                    return allowsOnboarding && !env.isOnboardingCompleted && (!isSplashScreenVisible || !splashEnabled)
                },
                set: { _ in }
            )) {
                OnboardingView()
            }
            // Sync left off from the old onboarding switch: ask once, after the splash.
            .appSheet(isPresented: Binding(
                get: { env.isOnboardingCompleted && env.sync.needsOffReminder && !stage.coversScreen },
                set: { _ in }
            )) {
                CloudSyncTurnOffView(alreadyOff: true)
            }
            // A signed-in website's favorites wait for the person to choose how they start syncing.
            .appSheet(item: Binding(
                get: { env.isOnboardingCompleted && !env.sync.needsOffReminder && !stage.coversScreen ? env.favoriteSetupOffer : nil },
                set: { _ in }
            )) { offer in
                SiteFavoritesSetupSheet(offer: offer, env: env)
            }
            // A library from before server folders chooses how its image folders work, once, in image mode.
            .appSheet(isPresented: Binding(
                get: { env.mode == .booru && env.isOnboardingCompleted && !env.sync.needsOffReminder && !stage.coversScreen && env.booru.folderStylePending },
                set: { _ in }
            )) {
                BooruFolderStyleSheet()
            }
            // The same for a signed-in image server.
            .appSheet(item: Binding(
                get: { env.isOnboardingCompleted && !env.sync.needsOffReminder && !stage.coversScreen && env.favoriteSetupOffer == nil && !env.booru.folderStylePending ? env.booruAccounts.setupOffer : nil },
                set: { _ in }
            )) { offer in
                SiteFavoritesSetupSheet(offer: offer, sync: env.booruAccounts)
            }
            // Include the presenting root and its sheets, not just the tab content.
            // Retained UIKit hosts also inject these same instances at their own roots.
            .environment(env)
            .environment(env.booru)
        }
    }
}
