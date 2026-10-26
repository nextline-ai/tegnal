import SwiftUI

public struct AppRootTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = .folders
    @State private var didSetup = false

    public init() {}

    public var body: some View {
        RetainedModeContainer(mode: env.mode,
            manga: AnyView(mangaTabs.environment(\.displayedAppMode, .manga).environment(env).environment(env.booru).environment(\.locale, Locale(identifier: L10n.language)).clearTopScrollEdge()),
            booru: AnyView(BooruRootView(selectedTab: $selectedTab).environment(\.displayedAppMode, .booru).environment(env).environment(env.booru).environment(\.locale, Locale(identifier: L10n.language)).clearTopScrollEdge()))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .clearTopScrollEdge()
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            guard !didSetup else { return }
            didSetup = true
            setupApp()
        }
        .onChange(of: env.isSiteVerified) { _, verified in
            if verified {
                #if DEBUG
                if ContentUITestSupport.enabled { return }
                #endif
                env.startCoverQueue()
            }
        }
    }

    private var mangaTabs: some View { ComicsRootTabs(selection: $selectedTab) }

    private func setupApp() {
        #if DEBUG
        if ContentUITestSupport.enabled { return }
        #endif
        env.database.syncFoldersToAppGroup()
        env.startCoverQueue()
        observeShareNotifications()
        consumePendingShare()
    }

    private func syncFoldersToAppGroup() {
        env.database.syncFoldersToAppGroup()
    }

    private func observeShareNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .didReceiveShareExtensionNotification, object: nil)
                }
            },
            AppStorage.darwinNotificationName,
            nil,
            .deliverImmediately
        )

        NotificationCenter.default.addObserver(forName: .didReceiveShareExtensionNotification, object: nil, queue: .main) { _ in
            consumePendingShare()
        }
    }

    private func consumePendingShare() {
        let pendingURL = AppStorage.pendingShareURL
        guard FileManager.default.fileExists(atPath: pendingURL.path),
              let data = try? Data(contentsOf: pendingURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            return
        }

        try? FileManager.default.removeItem(at: pendingURL)

        var folderId = json["folder_id"] as? Int64
        if let newFolderName = json["new_folder_name"] as? String, !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let created = try? env.database.createFolder(name: newFolderName) {
                folderId = created.id
            }
        }

        let ids = GalleryIDParser.parse(text)
        guard !ids.isEmpty else { return }

        Task {
            for id in ids {
                _ = try? env.database.upsertWork(
                    galleryId: id,
                    folderId: folderId,
                    metadataSource: nil,
                    catalogMatched: false
                )
            }
            env.startCoverQueue()
        }
    }
}

public extension Notification.Name {
    static let didReceiveShareExtensionNotification = Notification.Name("didReceiveShareExtensionNotification")
}

extension View {
    @ViewBuilder
    func adaptableTabStyleIfAvailable() -> some View {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, visionOS 2.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
        #else
        self
        #endif
    }
}


/// Retain each library's state while connecting only the selected navigation tree.
private struct RetainedModeContainer: UIViewControllerRepresentable {
    let mode: AppMode
    let manga: AnyView
    let booru: AnyView
    func makeUIViewController(context: Context) -> RetainedModeController { RetainedModeController() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: RetainedModeController, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateUIViewController(_ controller: RetainedModeController, context: Context) {
        controller.update(mode: mode, manga: manga, booru: booru)
    }
}

private final class ModeTransitionFrameTick: NSObject {
    let action: (CADisplayLink) -> Void
    init(action: @escaping (CADisplayLink) -> Void) { self.action = action }
    @objc func advance(_ link: CADisplayLink) { action(link) }
}

final class RetainedModeController: UIViewController {
    private var hosts: [AppMode: UIHostingController<AnyView>] = [:]
    private var selected: AppMode = .booru
    private struct Request {
        let mode: AppMode
        let manga: AnyView
        let booru: AnyView
    }
    private var pending: Request?
    private var updateScheduled = false
    private var transitionAnimator: UIViewPropertyAnimator?
    private var transitionID: UUID?
    private var transitionStartLink: CADisplayLink?
    private var transitionBody: UIView?
    deinit { transitionStartLink?.invalidate() }
    override var childForStatusBarHidden: UIViewController? { hosts[selected] }
    override var childForStatusBarStyle: UIViewController? { hosts[selected] }
    func update(mode: AppMode, manga: AnyView, booru: AnyView) {
        // Representable updates run inside SwiftUI's parent transaction. Defer
        // child-host creation and containment until that transaction has finished.
        if pending == nil, selected == mode, hosts[mode]?.parent === self { return }
        pending = Request(mode: mode, manga: manga, booru: booru)
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let request = self.pending else { return }
            self.pending = nil
            self.apply(request)
        }
    }

    private func apply(_ request: Request) {
        let mode = request.mode
        guard selected != mode || hosts[mode]?.parent !== self else { return }
        let outgoing = hosts[selected].flatMap { $0.parent === self ? $0 : nil }
        outgoing?.view.isUserInteractionEnabled = false
        outgoing?.view.accessibilityElementsHidden = true
        let animates = outgoing != nil && view.window != nil && !UIAccessibility.isReduceMotionEnabled
        // Capture only the already rendered body, outside the SwiftUI update
        // transaction. Never duplicate or move the live navigation/tab materials.
        var snapshot: UIView?
        if animates, let outgoing {
            let surface = transitionBody ?? bodySurface(in: outgoing)
            let region = transitionBody.map { view.convert($0.bounds, from: $0) } ?? view.bounds
            if region.width > 0, region.height > 0 {
                snapshot = surface.resizableSnapshotView(from: surface.convert(region, from: view), afterScreenUpdates: false, withCapInsets: .zero)
                snapshot?.frame = region
                if let snapshot { hideSnapshotFromAccessibility(snapshot) }
            }
        }
        transitionStartLink?.invalidate(); transitionStartLink = nil
        transitionAnimator?.stopAnimation(true); transitionAnimator = nil; transitionID = nil
        transitionBody?.removeFromSuperview(); transitionBody = nil
        for (key, host) in hosts where key != mode { detach(host) }
        selected = mode
        let active: UIHostingController<AnyView>
        if let host = hosts[mode] {
            active = host
        } else {
            // The roots own stable bindings and shared observable models. Their
            // own updates preserve navigation; replacing rootView here re-enters
            // nested TabView/NavigationStack rendering during a mode change.
            let host = UIHostingController(rootView: mode == .manga ? request.manga : request.booru)
            hosts[mode] = host
            active = host
        }
        let alreadyAttached = active.parent === self
        if !alreadyAttached {
            UIView.performWithoutAnimation {
                addChild(active)
                active.view.translatesAutoresizingMaskIntoConstraints = false
                active.view.backgroundColor = .systemBackground
                active.view.isOpaque = true
                view.addSubview(active.view)
                NSLayoutConstraint.activate([
                    active.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    active.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    active.view.topAnchor.constraint(equalTo: view.topAnchor),
                    active.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                active.didMove(toParent: self)
            }
        }
        // Keep the selected host and both bars still and opaque. Two frozen body
        // panels move edge-to-edge inside one clipped stage, with no opacity fade.
        active.view.isHidden = false
        active.view.accessibilityElementsHidden = false
        active.view.isUserInteractionEnabled = true
        active.view.alpha = 1
        view.bringSubviewToFront(active.view)
        if let snapshot {
            let originalRegion = snapshot.frame
            let stage = transitionPanel(identifier: "mode.transition.body")
            UIView.performWithoutAnimation { view.layoutIfNeeded() }
            install(stage, in: active, region: originalRegion)
            snapshot.frame = stage.bounds
            stage.addSubview(snapshot)
            transitionBody = stage
            let id = UUID()
            transitionID = id
            // Newly mounted navigation/tab bars need a display boundary to settle
            // before computing their shared body region and capturing its content.
            var frames = 0
            let target = ModeTransitionFrameTick { [weak self, weak active, weak stage] link in
                guard let self, let active, let stage, self.transitionID == id, self.selected == mode else {
                    link.invalidate(); return
                }
                frames += 1
                guard frames >= 2 else { return }
                link.invalidate(); self.transitionStartLink = nil
                self.startSlide(mode: mode, active: active, stage: stage, outgoing: snapshot,
                                originalRegion: originalRegion, id: id)
            }
            let link = CADisplayLink(target: target, selector: #selector(ModeTransitionFrameTick.advance(_:)))
            transitionStartLink = link
            link.add(to: .main, forMode: .common)
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func hideSnapshotFromAccessibility(_ snapshot: UIView) {
        snapshot.isUserInteractionEnabled = false
        snapshot.isAccessibilityElement = false
        snapshot.accessibilityElementsHidden = true
        snapshot.accessibilityElements = []
    }

    private func transitionPanel(identifier: String) -> UIView {
        let panel = UIView()
        panel.backgroundColor = .systemBackground
        panel.isOpaque = true
        panel.clipsToBounds = true
        panel.isUserInteractionEnabled = false
        panel.isAccessibilityElement = false
        panel.accessibilityElementsHidden = true
        panel.accessibilityElements = []
        panel.accessibilityIdentifier = identifier
        return panel
    }

    private func startSlide(mode: AppMode, active: UIViewController, stage: UIView, outgoing: UIView,
                            originalRegion: CGRect, id: UUID) {
        let region = originalRegion.intersection(view.bounds)
        let surface = bodySurface(in: active)
        let sourceRegion = surface.convert(region, from: view)
        // A reattached host may not have a cached rendered surface yet. Flush its
        // drawing here, outside the SwiftUI transaction, before taking its snapshot.
        guard !region.isNull, region.width > 0, region.height > 0,
              let incoming = surface.resizableSnapshotView(from: sourceRegion, afterScreenUpdates: true, withCapInsets: .zero) else {
            stage.removeFromSuperview(); transitionBody = nil; transitionID = nil
            return
        }
        hideSnapshotFromAccessibility(incoming)
        install(stage, in: active, region: region)
        let outgoingPanel = transitionPanel(identifier: "mode.transition.outgoing")
        let incomingPanel = transitionPanel(identifier: "mode.transition.incoming")
        outgoingPanel.frame = stage.bounds; incomingPanel.frame = stage.bounds
        outgoing.frame = originalRegion.offsetBy(dx: -region.minX, dy: -region.minY)
        outgoingPanel.addSubview(outgoing)
        incoming.frame = incomingPanel.bounds
        incomingPanel.addSubview(incoming)
        stage.addSubview(outgoingPanel); stage.addSubview(incomingPanel)
        let distance = region.width * (mode == .booru ? 1.0 : -1.0)
        incomingPanel.transform = CGAffineTransform(translationX: distance, y: 0)
        let animation = UIViewPropertyAnimator(duration: AppModeSwitchTransition.seconds, curve: .easeInOut) {
            outgoingPanel.transform = CGAffineTransform(translationX: -distance, y: 0)
            incomingPanel.transform = .identity
        }
        animation.addCompletion { [weak self, weak stage] _ in
            guard let self, self.transitionID == id, self.selected == mode else { return }
            stage?.removeFromSuperview(); self.transitionBody = nil
            self.transitionAnimator = nil; self.transitionID = nil
        }
        transitionAnimator = animation
        animation.startAnimation()
    }

    private func tabController(in host: UIViewController) -> UITabBarController? {
        if let tabs = host as? UITabBarController { return tabs }
        if let navigation = host as? UINavigationController {
            return navigation.visibleViewController.flatMap { tabController(in: $0) }
        }
        for child in host.children where child.viewIfLoaded?.window != nil {
            if let tabs = tabController(in: child) { return tabs }
        }
        return nil
    }

    private func navigationController(in host: UIViewController) -> UINavigationController? {
        if let navigation = host as? UINavigationController { return navigation }
        if let tabs = host as? UITabBarController {
            return tabs.selectedViewController.flatMap { navigationController(in: $0) }
        }
        for child in host.children where child.viewIfLoaded?.window != nil {
            if let navigation = navigationController(in: child) { return navigation }
        }
        return nil
    }

    private func bodySurface(in host: UIViewController) -> UIView {
        // Snapshot the content below BOTH native bars. Its backdrop can slide
        // behind the navigation controls without duplicating their icons/thumb.
        navigationController(in: host)?.visibleViewController?.view
            ?? tabController(in: host)?.selectedViewController?.view ?? host.view
    }

    private func install(_ stage: UIView, in host: UIViewController, region: CGRect) {
        let surface = bodySurface(in: host)
        let container: UIView = navigationController(in: host)?.view ?? tabController(in: host)?.view ?? view
        var branch = surface
        while let parent = branch.superview, parent !== container { branch = parent }
        if branch.superview === container {
            // Native navigation and tab bars remain above the body. Their live
            // glass samples the moving content all the way to the screen edges.
            container.insertSubview(stage, aboveSubview: branch)
            stage.frame = container.convert(region, from: view)
        } else {
            view.addSubview(stage)
            stage.frame = region
        }
    }

    private func detach(_ host: UIHostingController<AnyView>) {
        guard host.parent === self else { return }
        host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        UIView.performWithoutAnimation {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        host.view.alpha = 1
    }
}

/// Both libraries share the same destinations, including a persistent recommendation workspace.
struct AppTabLayout<Saved: View, Explore: View, Collections: View, Settings: View>: View {
    @Binding var selection: AppTab
    @Environment(AppEnvironment.self) private var env
    @State private var showingRecap = false
    let mode: AppMode
    let saved: Saved
    let explore: Explore
    let collections: Collections
    let settings: Settings
    private var collectionsTitle: String { L10n.text(mode == .booru ? "Tags" : "Artists") }
    private var collectionsIcon: String { mode == .booru ? "tag" : "person.2" }
    private var settingsTitle: String { L10n.text(mode == .booru ? "More" : "Settings") }
    private var settingsIcon: String { mode == .booru ? "ellipsis" : "gearshape" }
    private var insights: some View {
        NavigationStack { TasteDashboard(mode: mode == .booru ? .booru : .comics, isRoot: true, explore: { selection = .works }) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if env.coverQueueState.showsHeatBanner {
                CoverFillHeatBanner(state: env.coverQueueState)
            }
            if let date = env.taste.pendingRecap(tasteMode) {
                TasteRecapBanner(mode: tasteMode, date: date, open: { showingRecap = true }, dismiss: { env.taste.dismissRecap(tasteMode) })
                    .environment(\.timeZone, TimeZone(identifier: env.taste.control.timeZone) ?? .gmt)
                    .fixedSize(horizontal: false, vertical: true)
            }
            tabContent
        }
        .appSheet(isPresented: $showingRecap, onDismiss: { env.taste.dismissRecap(tasteMode) }) {
            NavigationStack {
                TasteReportsView(mode: tasteMode, period: .month)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { showingRecap = false } } }
            }
        }
    }
    private var tabContent: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: $selection) {
                    Tab(L10n.text("Saved"), systemImage: "folder.fill", value: .folders) { saved }
                    Tab(L10n.text("Explore"), systemImage: "globe", value: .works) { explore }
                    Tab(collectionsTitle, systemImage: collectionsIcon, value: .artists) { collections }
                    Tab(settingsTitle, systemImage: settingsIcon, value: .settings) { settings }
                    Tab(L10n.text("Smart"), systemImage: "apple.intelligence", value: .insights, role: insightsRole) { insights }
                }
            } else {
                TabView(selection: $selection) {
                    saved.tabItem { Label(L10n.text("Saved"), systemImage: "folder.fill") }.tag(AppTab.folders)
                    explore.tabItem { Label(L10n.text("Explore"), systemImage: "globe") }.tag(AppTab.works)
                    collections.tabItem { Label(collectionsTitle, systemImage: collectionsIcon) }.tag(AppTab.artists)
                    settings.tabItem { Label(settingsTitle, systemImage: settingsIcon) }.tag(AppTab.settings)
                    insights.tabItem { Label(L10n.text("Smart"), systemImage: "apple.intelligence") }.tag(AppTab.insights)
                }
            }
        }.adaptableTabStyleIfAvailable()
    }

    private var tasteMode: TasteMode { mode == .booru ? .booru : .comics }
    @available(iOS 18.0, *)
    private var insightsRole: TabRole? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        // iOS 26 gives the search role the separate trailing glass circle.
        if #available(iOS 26.0, *) { return .search }
        return nil
    }
}

private struct CoverFillHeatBanner: View {
    let state: CoverQueueState
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "thermometer.medium").font(.title3).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Filling missing information")).font(.subheadline.bold())
                Text(L10n.text("Filling %@ works in the background may warm up your device and use battery. Recently saved works are processed first.", String(state.total)))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { state.heatWarningDismissed = true } label: {
                Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss filling notice"))
                .accessibilityIdentifier("library.fillHeatBanner.dismiss")
        }.padding(.leading, 16).padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16).padding(.vertical, 6)
            .accessibilityIdentifier("library.fillHeatBanner")
    }
}

private struct ComicsRootTabs: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: AppTab
    var body: some View {
        AppTabLayout(selection: $selection, mode: .manga,
            saved: NavigationStack {
                FoldersView()
                    .safeAreaInset(edge: .top) { if !env.isSiteVerified { ComicsConnectionCard().padding(.horizontal) } }
            },
            explore: exploration,
            collections: NavigationStack { ArtistsListView() },
            settings: NavigationStack { SettingsView() })
    }

    @ViewBuilder private var exploration: some View {
        if env.isSiteVerified { ContentEntryView(embedded: true) }
        else {
            NavigationStack {
                Group {
                    if env.booru.servers.isEmpty { ComicsSetupView() }
                    else { ComicsPoolsView() }
                }.appRootHeader("Explore")
            }
        }
    }

}
