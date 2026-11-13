import SwiftUI

private enum ReaderSheet: String, Identifiable {
    case settings, information, downloads
    var id: String { rawValue }
}

struct NativeReaderView: View {
    @Environment(\.discoveryContext) private var discovery
    @Environment(AppEnvironment.self) private var env
    let galleryID: Int64
    let initialPage: Int
    let source: any ContentProviding
    let images: PageImageStore
    let savesProgress: Bool
    let resumesProgress: Bool
    let offline: Bool
    let search: (String) -> Void
    private let openWork: ((Int64, Int?) -> Void)?
    @State private var pendingWork: (id: Int64, page: Int?)?
    let exit: () -> Void
    let changeWork: ((Int) -> Bool)?
    @SwiftUI.AppStorage("reader.continuousBackSwipe", store: ReaderPreferences.defaults) private var continuousBackSwipe = false
    @SwiftUI.AppStorage("reader.continuousWorkSwipe", store: ReaderPreferences.defaults) private var continuousWorkSwipe = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var translationRequest: ReaderTranslationRequest?
    /// Translation mode, kept while pages turn.
    @State private var translation = ReaderTranslationSession()
    /// The translation pill shows for a moment after something changes, then fades away.
    @State private var translationPillUntil = Date.distantPast
    @State private var zoomed = false
    @State private var zoomedPages: Set<Int> = []
    @State private var exiting = false
    @State private var opening: ReaderOpening
    @State private var showResume = false
    @State private var resumeReady = false
    @State private var pendingSearch: String?
    @SwiftUI.AppStorage("reader.pagesPerSpread", store: ReaderPreferences.defaults) private var pagesPerSpread = 1
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.defaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.defaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("reader.helpHidden", store: ReaderPreferences.defaults) private var helpHidden = false
    @State private var gallery: NativeGallery?
    @State private var currentPage = 0
    @State private var viewing = TasteViewingSession()
    @State private var viewedGallery: NativeGallery?
    @State private var pagePrefetcher = ReaderPagePrefetcher()
    @State private var error: String?
    @State private var retry = 0
    @State private var menuVisible = false
    @State private var showingQueue = false
    @State private var queueBarDrag: CGFloat = 0
    @State private var sheet: ReaderSheet?
    @State private var guide = ReaderGuideSession()
    @State private var pendingGuide = false
    @State private var viewports: [Int: CGRect] = [:]
    @State private var toast: String?
    @State private var saveFeedback: WorkSaveFeedback?
    /// Whether the work is bookmarked, read again each time the quick menu opens.
    @State private var saved = false
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var previousIdleTimer = false
    @SwiftUI.AppStorage("reader.mode", store: ReaderPreferences.defaults) private var mode = ReaderMode.horizontal.rawValue
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.defaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.defaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.defaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.defaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.prefetch", store: ReaderPreferences.defaults) private var prefetch = 3
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.defaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.defaults) private var tapNavigation = true
    @SwiftUI.AppStorage("reader.continuousPreviewSwipe", store: ReaderPreferences.defaults) private var continuousInformationSwipe = false

    init(galleryID: Int64, initialPage: Int, source: any ContentProviding, images: PageImageStore,
         savesProgress: Bool, offline: Bool = false, resumesProgress: Bool = true, search: @escaping (String) -> Void, exit: @escaping () -> Void, changeWork: ((Int) -> Bool)? = nil, openWork: ((Int64, Int?) -> Void)? = nil) {
        self.changeWork = changeWork
        self.galleryID = galleryID; self.initialPage = initialPage
        self.source = source; self.images = images; self.savesProgress = savesProgress; self.offline = offline
        self.resumesProgress = resumesProgress
        self.search = search; self.exit = exit; self.openWork = openWork
        let defaults = ReaderPreferences.defaults
        let saved = savesProgress ? defaults.integer(forKey: "reader_page_\(galleryID)") : 0
        let opening = ReaderResumeBehavior.stored(in: defaults).opening(initial: initialPage, saved: saved, resumesProgress: resumesProgress)
        _opening = State(initialValue: opening)
        if let cached = source.cachedGallery(galleryID) {
            _gallery = State(initialValue: cached)
            _currentPage = State(initialValue: ReaderLayout.initialPage(opening.initialPage, saved: 0, total: cached.pages.count,
                                                                     count: ReaderPreferences.defaults.integer(forKey: "reader.pagesPerSpread")))
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let gallery, !opening.needsConfirmation || resumeReady {
                reader(gallery).ignoresSafeArea()
                    .environment(translation)
                    .overlay(Color.black.opacity(min(0.65, max(0, dimming))).allowsHitTesting(false))
            } else if let error {
                ContentFailureView(message: error) { retry += 1 }.preferredColorScheme(.dark)
            } else { ProgressView(L10n.text("Loading page")).tint(.white).foregroundStyle(.white) }

            VStack {
                if let toast {
                    Text(toast).font(.subheadline.bold()).padding(12).background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("reader.toast")
                }
                Spacer()
                if !(menuVisible || gallery == nil), pageNumber, let gallery {
                    Text("\(currentPage + 1) / \(gallery.pages.count)")
                        .font(.caption).padding(6).background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                }
            }.padding(16)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if menuVisible || gallery == nil {
                    // Only the menu moves, by its own height, so it visibly rises and falls.
                    VStack(spacing: 10) {
                        queueBar
                        quickMenu
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.move(edge: .bottom))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            // A view leaving a ZStack loses its place on top; this keeps it in front while it slides away.
            .zIndex(1)
        }
        .animation(Self.menuMotion, value: menuVisible)
        .appSheet(isPresented: $showingQueue) {
            ReadingQueueView(read: { id in showingQueue = false; menuVisible = false; openQueued(id) })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .overlay(alignment: .top) {
            VStack {
                ReaderDismissHandle(identifier: "reader.exitHandle", dismiss: closeReader)
                Spacer()
            }.ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .background(ReaderExitGesture(enabled: readerActive && sheet == nil && !showJump && !zoomed,
                                      requiresTopSafeZone: mode == ReaderMode.continuous.rawValue,
                                      movesContainer: true,
                                      progress: { _ in }, exit: closeReader))
        .background(ReaderInformationGesture(enabled: ReaderInformationReveal.isEnabled(mode: mode, continuousOptIn: continuousInformationSwipe) && readerActive && gallery != nil && !zoomed && !menuVisible && sheet == nil && !showJump,
                                         reveal: { sheet = .information }))
        .overlay(alignment: .topTrailing) {
            if let request = translationRequest, let gallery, gallery.pages.indices.contains(request.index) {
                ReaderTranslationView(page: gallery.pages[request.index], galleryID: galleryID, language: gallery.language, images: images, rect: request.rect, finished: {
                    guard translationRequest?.id == request.id else { return }
                    translationRequest = nil
                }, failed: { message in
                    guard translationRequest?.id == request.id else { return }
                    toast = message; translationRequest = nil
                })
                .id(request.id)
            }
        }
        .overlay(alignment: .bottom) {
            if translationMode != .off, !menuVisible, sheet == nil, gallery != nil {
                ReaderTranslationModeBar(mode: translationMode, select: setTranslationMode)
                    // On the row of Live Text's own buttons, which sit this far above the safe area.
                    .padding(.bottom, ReaderTranslationModeBar.bottomInset)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: translationMode)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bottomMenu && !menuVisible && gallery != nil { menuActions(compact: true).padding(.horizontal, 12).padding(.vertical, 8)
                    .modifier(ReaderMenuGlass()).padding(.horizontal, 12).padding(.bottom, 6) }
        }
        .background(ReaderWorkSwipeGesture(enabled: continuousWorkSwipe && mode == ReaderMode.continuous.rawValue && readerActive && sheet == nil && !zoomed && !menuVisible && !showJump, excludesLeadingEdge: continuousBackSwipe) { delta in
            if changeWork?(delta) != true { toast = L10n.text("No More Works in This List") }
        })
        .background(ReaderBackSwipeGesture(enabled: continuousBackSwipe && mode == ReaderMode.continuous.rawValue && readerActive && sheet == nil && !zoomed && !menuVisible && !showJump, back: closeReader))
        .background(ReaderKeyboardCommands(enabled: readerActive && sheet == nil && !showJump, action: shortcut))
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .presentationBackground(.clear)
        .overlayPreferenceValue(ReaderGuideMenuBounds.self) { bounds in
            if let step = guide.step, sheet == nil, translationRequest == nil, !showJump {
                ReaderGuideOverlay(step: step, configuration: ReaderGuideConfiguration(booru: false, defaults: ReaderPreferences.defaults),
                                   menuBounds: bounds, next: advanceGuide, finish: finishGuide)
            }
        }
        .onChange(of: menuVisible) { _, visible in
            if visible { guide.openedMenu(); readSaved() }
        }
        // The quick menu may stay pinned at the bottom; the details sheet can also change the bookmark.
        .onChange(of: sheet) { _, _ in readSaved() }
        .task(id: galleryID) { readSaved() }
        // Keep VoiceOver in the reader while preserving its page and menu controls.
        // The presenting gallery/navigation stack remains mounted underneath.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .appSheet(item: $sheet, onDismiss: {
            if let pendingSearch { self.pendingSearch = nil; search(pendingSearch) }
            if let pendingWork { self.pendingWork = nil; openWork?(pendingWork.id, pendingWork.page) }
            if pendingGuide { pendingGuide = false; menuVisible = false; guide.start() }
        }) { item in
            switch item {
            case .downloads: DownloadsSheet(mode: .manga)
            case .settings: ReaderSettingsView(onShowGuide: { pendingGuide = true; sheet = nil })
            case .information:
                if let gallery {
                    ReaderWorkInformationView(gallery: gallery, images: images, current: $currentPage,
                        search: { pendingSearch = $0; sheet = nil }, links: openWork.map { _ in
                            // Another language keeps your place; a related work is a new start.
                            GalleryWorkLinks(source: source, openVersion: { pendingWork = ($0, currentPage + 1); sheet = nil },
                                             openRelated: { pendingWork = ($0, nil); sheet = nil })
                        })
                }
            }
        }
        .alert(L10n.text("Go to Page"), isPresented: $showJump) {
            TextField(L10n.text("Page Number"), text: $jumpText).keyboardType(.numberPad)
            Button(L10n.text("Go")) {
                if let page = Int(jumpText), let gallery { currentPage = ReaderLayout.start(min(max(page - 1, 0), gallery.pages.count - 1), count: pagesPerSpread) }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .alert(L10n.text("Continue Reading?"), isPresented: $showResume) {
            Button(L10n.text("Continue Reading")) { resolveOpening(continuing: true) }
                .accessibilityIdentifier("reader.resume.continue")
            Button(L10n.text("Cancel"), role: .cancel) { resolveOpening(continuing: false) }
                .accessibilityIdentifier("reader.resume.cancel")
        } message: {
            Text(L10n.text("Continue from page %@?", String(describing: opening.page)))
        }
        .task(id: "\(retry):\(opening.needsConfirmation)") {
            await loadGallery()
        }
        .task(id: "\(currentPage):\(pagesPerSpread):\(prefetch):\(gallery?.id ?? 0):\(mayPrefetch)") {
            guard !Task.isCancelled else { return }
            guard mayPrefetch, prefetch > 0, let gallery, gallery.pages.indices.contains(currentPage) else {
                pagePrefetcher.cancel(); return
            }
            let allowed = await images.canPrefetch
            guard !Task.isCancelled else { return }
            if allowed {
                pagePrefetcher.update(gallery: gallery, images: images, current: currentPage, count: prefetch, visibleCount: pagesPerSpread)
            } else { pagePrefetcher.cancel() }
        }
        .workSaveFeedback($saveFeedback, identifier: "reader.toast")
        .task(id: toast) {
            guard toast != nil else { return }
            do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
        }
        .task(id: autoTaskID) {
            guard autoAdvance, guide.step == nil, readerActive, sheet == nil, !menuVisible, !showJump,
                  !zoomed, !exiting, translationRequest == nil, let gallery else { return }
            do {
                try await Task.sleep(for: .seconds(min(120, max(2, autoSeconds))))
                try Task.checkCancellation()
                let next = ReaderLayout.next(currentPage, delta: 1, count: pagesPerSpread, total: gallery.pages.count)
                if next == currentPage { autoAdvance = false } else { currentPage = next }
            } catch {}
        }
        .onChange(of: "\(mode):\(rtl):\(pagesPerSpread)") { _, _ in
            viewports = [:]; zoomedPages = []; zoomed = false
        }
        .onChange(of: pagesPerSpread) { _, count in currentPage = ReaderLayout.start(currentPage, count: count) }
        .onChange(of: currentPage) { _, page in
            let start = ReaderLayout.start(page, count: pagesPerSpread)
            if start != page { currentPage = start }
            translationRequest = nil; viewports = [:]; zoomed = false; zoomedPages = []
            if savesProgress && !opening.needsConfirmation { ReaderPreferences.defaults.set(page + 1, forKey: "reader_page_\(galleryID)") }
            showViewingPage()
            followTranslation()
        }
        .onChange(of: translation.message) { _, message in if let message { toast = message; translation.message = nil } }
        .background {
            if #available(iOS 18.0, *) { ReaderTranslationHost(broker: translation.broker) }
        }
        .overlay(alignment: .topTrailing) {
            if translation.isOn, let gallery, gallery.pages.indices.contains(currentPage) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let hash = gallery.pages[currentPage].hash
                    let visible = menuVisible || translation.isWorking(on: hash) || context.date < translationPillUntil
                    ReaderTranslationToggle(showsOriginal: translation.showsOriginal, working: translation.isWorking(on: hash)) {
                        translation.showsOriginal.toggle(); showTranslationPill()
                    }
                    .opacity(visible ? 1 : 0).allowsHitTesting(visible)
                    .animation(.easeInOut(duration: 0.25), value: visible)
                }
                .padding(.top, 8).padding(.trailing, 16)
            }
        }
        .onAppear { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake && scenePhase == .active }
        .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value && scenePhase == .active }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
            if phase != .active { pagePrefetcher.cancel() }
        }
        .onChange(of: viewingActive, initial: true) { _, active in
            if active { viewing.resume(); showViewingPage() } else { viewing.pause() }
        }
        .onChange(of: gallery?.id, initial: true) { _, _ in
            recordViewing(); viewedGallery = gallery
            if viewingActive { viewing.resume(); showViewingPage() }
        }
        .onDisappear { pagePrefetcher.cancel(); UIApplication.shared.isIdleTimerDisabled = previousIdleTimer; recordViewing() }
    }
    private var viewingActive: Bool { readerActive && gallery != nil && sheet == nil }
    private func showViewingPage() {
        guard let gallery, !gallery.pages.isEmpty else { return }
        let isLast = currentPage + ReaderLayout.count(pagesPerSpread) >= gallery.pages.count
        viewing.show(currentPage, isLast: isLast)
        // Read to the end, a work waiting in Up Next has been read.
        if isLast { env.readingQueue.finished(gallery.id) }
    }
    private func recordViewing() {
        guard let dwell = viewing.finish(), let gallery = viewedGallery else { return }
        let database = env.database, context = discovery
        Task.detached(priority: .utility) { try? database.recordDwell(dwell, gallery: gallery, context: context) }
    }

    @ViewBuilder private func reader(_ gallery: NativeGallery) -> some View {
        if mode == ReaderMode.continuous.rawValue {
            ReaderContinuousView(gallery: gallery, images: images, current: $currentPage, tap: tapped, bookmark: bookmark, count: ReaderLayout.count(pagesPerSpread), rtl: rtl, viewport: viewportChanged, isActive: readerActive)
                .id("\(gallery.id):continuous:\(pagesPerSpread)")
        } else {
            ReaderPager(gallery: gallery, images: images, vertical: mode == ReaderMode.vertical.rawValue, rtl: rtl,
                        current: $currentPage, tap: tapped, bookmark: bookmark, count: ReaderLayout.count(pagesPerSpread), viewport: viewportChanged, isActive: readerActive)
                .id("\(gallery.id):\(mode):\(rtl):\(pagesPerSpread)")
        }
    }

    private var quickMenu: some View {
        ViewerQuickMenuPanel(close: { withAnimation(Self.menuMotion) { menuVisible = false } }) {
            HStack(spacing: 12) {
                ViewerQuickMenuCircle(icon: "chevron.left", label: L10n.text("Previous Page")) { move(-1) }
                    .disabled(currentPage == 0).accessibilityIdentifier("reader.previous")
                Button { jumpText = String(currentPage + 1); showJump = true } label: {
                    Text("\(currentPage + 1) / \(gallery?.pages.count ?? 0)").font(.headline.monospacedDigit())
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }.accessibilityLabel(L10n.text("Page %@ / %@", String(describing: currentPage + 1), String(describing: gallery?.pages.count ?? 0))).accessibilityIdentifier("reader.position")
                ViewerQuickMenuCircle(icon: "chevron.right", label: L10n.text("Next Page")) { move(1) }
                    .disabled(currentPage + ReaderLayout.count(pagesPerSpread) >= (gallery?.pages.count ?? 1)).accessibilityIdentifier("reader.next")
                ViewerQuickMenuCircle(icon: "xmark", label: L10n.text("Close Menu")) { withAnimation(Self.menuMotion) { menuVisible = false } }
                    .accessibilityIdentifier("reader.menu.close")
            }
        } actions: {
            menuActions(compact: false)
        }
        .anchorPreference(key: ReaderGuideMenuBounds.self, value: .bounds) { $0 }
    }

    /// The works around the open one in Up Next. A work opened from elsewhere goes before the list.
    private var queueNeighbors: (previous: ReadingQueueItem?, next: ReadingQueueItem?) {
        let items = env.readingQueue.items
        guard let index = items.firstIndex(where: { $0.id == gallery?.id }) else { return (nil, items.first) }
        return (index > 0 ? items[index - 1] : nil, index + 1 < items.count ? items[index + 1] : nil)
    }
    /// Up Next, one row above the quick menu: the next work waiting, which the reader switches to.
    /// Swiped like a music app's player, it moves to the next or the previous work in the list.
    @ViewBuilder private var queueBar: some View {
        let neighbors = queueNeighbors
        if let shown = neighbors.next ?? neighbors.previous {
            ReadingQueueBar(read: { id in menuVisible = false; openQueued(id) }, showList: { showingQueue = true }, next: shown)
                .frame(height: 72)
                .modifier(ReadingQueueBarBackground())
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: 560)
                .offset(x: queueBarDrag)
                // Ahead of the bar's buttons, so a swipe never reads as a tap.
                .highPriorityGesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let allowed = value.translation.width < 0 ? neighbors.next != nil : neighbors.previous != nil
                        // Resists past the ends, where there is no work to move to.
                        queueBarDrag = allowed ? value.translation.width : value.translation.width / 4
                    }
                    .onEnded { value in
                        let width = value.translation.width, projected = value.predictedEndTranslation.width
                        let target = width < -60 || projected < -160 ? neighbors.next : width > 60 || projected > 160 ? neighbors.previous : nil
                        if let target {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.easeIn(duration: 0.16)) { queueBarDrag = width < 0 ? -420 : 420 }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(160))
                                queueBarDrag = 0
                                openQueued(target.id)
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { queueBarDrag = 0 }
                        }
                    })
                .accessibilityAction(named: L10n.text("Next")) { if let next = neighbors.next { openQueued(next.id) } }
                .accessibilityAction(named: L10n.text("Previous")) { if let previous = neighbors.previous { openQueued(previous.id) } }
        }
    }
    private func openQueued(_ id: Int64) {
        if let openWork { openWork(id, 1) } else { toast = L10n.text("No More Works in This List") }
    }

    private func menuActions(compact: Bool) -> some View {
        let columns = Array(repeating: GridItem(.flexible()), count: compact ? 6 : 3)
        return LazyVGrid(columns: columns, spacing: compact ? 18 : 20) {
            menuButton(L10n.text("Download Work"), icon: "arrow.down.circle", id: offline ? "download.offline" : "download", compact: compact) {
                if let gallery { DownloadStore.shared.enqueue(gallery); sheet = .downloads }
            }.disabled(gallery == nil || offline)
            menuButton(L10n.text(saved ? "Remove Bookmark" : "Bookmark"), icon: saved ? "bookmark.fill" : "bookmark", id: "bookmark", compact: compact,
                       color: saved ? WorkSaveResult.added(.comics).color : nil, action: bookmark)
            menuButton(L10n.text("Exit"), icon: "rectangle.portrait.and.arrow.right", id: "exit", compact: compact, action: closeReader)
            menuButton(L10n.text(translation.isOn ? "Stop Translating" : "Translate"), icon: "translate", id: "translate", compact: compact,
                       color: translation.isOn ? .accentColor : nil) { translate() }
            menuButton(L10n.text("Work Details"), icon: "info.circle", id: "information", compact: compact) { sheet = .information }
            menuButton(L10n.text("More Settings"), icon: "slider.horizontal.3", id: "settings", compact: compact) { sheet = .settings }
        }
    }

    @ViewBuilder private func menuButton(_ title: String, icon: String, id: String, compact: Bool, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Group {
            if compact {
                Button(action: action) {
                    VStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 21)).foregroundStyle(color ?? .white)
                        Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                .foregroundStyle(.white).tint(.white).buttonStyle(.plain)
                .accessibilityLabel(title)
            } else {
                ViewerQuickMenuButton(title: title, icon: icon, color: color, action: action)
            }
        }
        .disabled(gallery == nil && id != "exit" && id != "settings")
        .accessibilityIdentifier("reader.\(id)")
    }

    private var autoTaskID: String {
        "\(guide.step?.rawValue ?? -1):\(autoAdvance):\(autoSeconds):\(currentPage):\(pagesPerSpread):\(menuVisible):\(sheet?.rawValue ?? ""):\(showJump):\(zoomed):\(exiting):\(translationRequest?.id.uuidString ?? ""):\(scenePhase):\(gallery?.id ?? 0):\(opening.needsConfirmation)"
    }
    private var readerActive: Bool { scenePhase == .active && !exiting && translationRequest == nil && !opening.needsConfirmation }
    private var mayPrefetch: Bool { readerActive && sheet == nil && !zoomed }
    private func viewportChanged(_ index: Int, rect: CGRect, scale: CGFloat) {
        if scale > 1.01 { zoomedPages.insert(index) } else { zoomedPages.remove(index) }
        zoomed = !zoomedPages.isEmpty
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        if scale > 1.01 { viewports[index] = rect } else { viewports.removeValue(forKey: index) }
        // AI translation reads a zoomed-in area again, for text too small to read on the whole page.
        if translation.isOn, scale >= ReaderZoomedText.minimumScale, let gallery, gallery.pages.indices.contains(index) {
            translation.readZoomed(gallery.pages[index], index: index, galleryID: galleryID, area: rect, images: images)
        }
    }

    private func shortcut(_ command: ReaderShortcut) {
        guard sheet == nil, !showJump else { return }
        if command == .exit {
            if translationRequest != nil { translationRequest = nil } else { closeReader() }
            return
        }
        guard translationRequest == nil else { return }
        switch command {
        case .previous: move(rtl ? 1 : -1)
        case .next: move(rtl ? -1 : 1)
        case .menu: withAnimation(Self.menuMotion) { menuVisible.toggle() }
        case .favorite: bookmark()
        case .details: sheet = .information
        case .exit: break
        }
    }
    /// The quick menu rises and falls with the same spring.
    static let menuMotion = Animation.spring(response: 0.34, dampingFraction: 0.86)
    private func tapped(_ x: CGFloat) {
        if (0.3...0.7).contains(x) { withAnimation(Self.menuMotion) { menuVisible.toggle() } }
        else if tapNavigation { move((x < 0.3 ? -1 : 1) * (rtl ? -1 : 1)) }
    }
    private func move(_ delta: Int) {
        guard let gallery else { return }
        currentPage = ReaderLayout.next(currentPage, delta: delta, count: pagesPerSpread, total: gallery.pages.count)
    }
    private func advanceGuide() {
        switch guide.step {
        case .navigation: guide.advance(); menuVisible = true
        case .tools: guide.advance(); menuVisible = false
        case .exit: finishGuide()
        case nil: break
        }
    }
    private func finishGuide() { guide.finish(); helpHidden = true }
    private func closeReader() {
        guard !exiting else { return }
        if guide.step != nil { finishGuide() }
        exiting = true
        exit()
    }
    private func bookmark() {
        saveFeedback = .perform(galleryID: galleryID) { try ContentBookmarkAction.toggle(id: galleryID, gallery: gallery, env: env, images: images, context: discovery) }
        readSaved()
    }
    private func readSaved() { saved = (try? env.database.getWork(galleryId: galleryID)) != nil }
    private var translationMode: ReaderTranslationMode {
        translation.isOn ? .ai : translationRequest != nil ? .standard : .off
    }
    /// Translate in the quick menu starts the mode last chosen, AI unless the reader picked the
    /// standard translation, or stops translating.
    private func translate() {
        menuVisible = false
        if translationMode != .off { setTranslationMode(.off); return }
        setTranslationMode(ReaderTranslationSession.isSupported && ReaderPreferences.continuousTranslation ? .ai : .standard)
    }
    /// The switch under the page; AI or standard becomes what Translate starts next time.
    private func setTranslationMode(_ mode: ReaderTranslationMode) {
        guard mode != translationMode else { return }
        if translation.isOn { translation.stop() }
        translationRequest = nil
        switch mode {
        case .off: break
        case .standard:
            ReaderPreferences.continuousTranslation = false
            translateCurrentPage()
        case .ai:
            ReaderPreferences.continuousTranslation = true
            startAITranslation()
        }
    }
    /// AI translation on iOS 18 and later, reading the text itself. Where this system cannot read
    /// vertical columns, the standard translation, which can, translates the page instead.
    private func startAITranslation() {
        guard ReaderSourceLanguage.writesVertically(gallery?.language) else { beginAITranslation(); return }
        Task { @MainActor in
            guard await ReaderVerticalTextSupport.shared.isSupported() else { translateCurrentPage(); return }
            guard translationMode == .off else { return }
            beginAITranslation()
        }
    }
    private func beginAITranslation() {
        guard !translation.isOn else { return }
        translation.toggle()
        followTranslation()
        showTranslationPill()
    }
    private func translateCurrentPage() {
        translationRequest = ReaderTranslationRequest(index: currentPage, rect: viewports[currentPage] ?? CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    private func followTranslation() {
        guard translation.isOn, let gallery else { return }
        translation.follow(gallery: gallery, index: currentPage, count: ReaderLayout.count(pagesPerSpread), images: images)
        showTranslationPill()
    }
    private func showTranslationPill() { translationPillUntil = Date().addingTimeInterval(2.5) }
    private func resolveOpening(continuing: Bool) {
        let resolved = opening.resolved(continuing: continuing)
        if let gallery {
            currentPage = ReaderLayout.initialPage(resolved.page, saved: 0, total: gallery.pages.count, count: pagesPerSpread)
        }
        opening = resolved
    }
    /// Puts the work at the top of Recently Opened Works, with its cover once it loads.
    private func rememberOpened(_ value: NativeGallery) {
        let recents = env.recentWorks
        recents.opened(value, site: ComicSites.active.isEmpty ? nil : ComicSites.active)
        guard recents.entries.first?.id == value.id, !recents.hasCover(value.id), let first = value.pages.first else { return }
        let images = images, id = value.id
        Task(priority: .utility) {
            guard let cover = try? await images.load(first, galleryID: id, thumbnail: true) else { return }
            recents.storeCover(cover, for: id)
        }
    }
    private func loadGallery() async {
        error = nil
        // Even an unavailable gallery must retain a visible way out.
        menuVisible = false
        do {
            let value: NativeGallery
            if let gallery { value = gallery }
            else { value = try await source.gallery(galleryID) }
            try Task.checkCancellation()
            if gallery == nil {
                currentPage = ReaderLayout.initialPage(opening.initialPage, saved: 0, total: value.pages.count, count: pagesPerSpread)
                gallery = value
            }
            if savesProgress { rememberOpened(value) }
            if opening.needsConfirmation {
                if let first = value.pages.first { _ = try? await images.load(first, galleryID: galleryID) }
                try Task.checkCancellation()
                resumeReady = true
                showResume = true
                return
            }
            // A cached initial page is already in @State and does not trigger onChange.
            if savesProgress { ReaderPreferences.defaults.set(currentPage + 1, forKey: "reader_page_\(galleryID)") }
            if !helpHidden, !guide.hasStarted { guide.start() }
            let database = env.database, context = discovery, recordProgress = savesProgress
            let record = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try? database.observeTaste(value, context: context)
                try Task.checkCancellation()
                if recordProgress { try? database.markOpened(galleryId: value.id) }
            }
            _ = await withTaskCancellationHandler { await record.result } onCancel: { record.cancel() }
        } catch {
            if !Task.isCancelled { self.error = ContentError.message(error); menuVisible = true }
        }
    }
}

struct ReaderMenuGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.3)).platformInteractive(), in: .rect(cornerRadius: 24))
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The viewers' quick menu, laid out as the Camera app lays out its controls: a glass sheet
/// inset from the screen's edges, its tools as round buttons in three columns with their names
/// underneath. Pulling it down puts it away.
struct ViewerQuickMenuPanel<Navigation: View, Actions: View>: View {
    let close: () -> Void
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let actions: Actions
    @GestureState private var pull: CGFloat = 0

    var body: some View {
        VStack(spacing: 18) {
            navigation
            actions
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 28)
        .frame(maxWidth: 560)
        .foregroundStyle(.white).tint(.white).buttonStyle(.plain)
        .modifier(ViewerPanelGlass())
        .offset(y: pull)
        .gesture(DragGesture(minimumDistance: 10)
            .updating($pull) { value, state, _ in state = max(0, value.translation.height) }
            .onEnded { value in if value.translation.height > 70 || value.predictedEndTranslation.height > 180 { close() } })
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pull == 0)
        .accessibilityAction(named: L10n.text("Close Menu"), close)
    }
}

/// The same clear glass as the Up Next bar, with the device's rounded corners.
struct ViewerPanelGlass: ViewModifier {
    var cornerRadius: CGFloat = 44
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .environment(\.colorScheme, .dark)
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .environment(\.colorScheme, .dark)
        }
    }
}

/// One tool of the quick menu: a round button with its name underneath.
struct ViewerQuickMenuButton: View {
    let title: String
    let icon: String
    var color: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) { ViewerQuickMenuLabel(title: title, icon: icon, color: color) }
            .buttonStyle(ViewerQuickMenuButtonStyle())
            .accessibilityLabel(title)
    }
}
struct ViewerQuickMenuLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let icon: String
    var color: Color? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24, weight: .medium))
                .foregroundStyle(color ?? .white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(.white.opacity(0.12)))
            Text(title).font(.subheadline).foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
private struct ViewerQuickMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
/// A round glass control in the quick menu's top row.
struct ViewerQuickMenuCircle: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(ViewerQuickMenuButtonStyle())
        .accessibilityLabel(label)
    }
}

@MainActor @Observable final class MangaReaderSequence {
    var ids: [Int64]
    @ObservationIgnored var prepareReturn: ((Int64, Int64) -> Void)?
    init(_ ids: [Int64] = []) { self.ids = ids }
    static func neighbor(_ id: Int64, delta: Int, ids: [Int64]) -> Int64? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return nil }
        return ids[index + delta]
    }
}
private struct MangaReaderSequenceKey: EnvironmentKey { static let defaultValue: MangaReaderSequence? = nil }
extension EnvironmentValues {
    var mangaReaderSequence: MangaReaderSequence? {
        get { self[MangaReaderSequenceKey.self] }
        set { self[MangaReaderSequenceKey.self] = newValue }
    }
}
struct MangaReaderSession: View {
    @Environment(\.mangaReaderSequence) private var sequence
    let initialPage: Int
    let source: any ContentProviding
    let images: PageImageStore
    let savesProgress: Bool
    let resumesProgress: Bool
    let search: (String) -> Void
    let exit: () -> Void
    let willClose: (Int64) -> Void
    private let openedID: Int64
    @State private var selected: Int64
    init(galleryID: Int64, initialPage: Int, source: any ContentProviding, images: PageImageStore, savesProgress: Bool,
         resumesProgress: Bool = true, search: @escaping (String) -> Void, exit: @escaping () -> Void, willClose: @escaping (Int64) -> Void = { _ in }) {
        self.openedID = galleryID; self.willClose = willClose
        _selected = State(initialValue: galleryID); self.initialPage = initialPage; self.source = source; self.images = images
        self.savesProgress = savesProgress; self.resumesProgress = resumesProgress; self.search = search; self.exit = exit
    }
    @State private var switched = false
    /// The work a linked work was opened from, so paging onward still follows the list.
    @State private var position: Int64?
    @State private var keptPage: Int?
    var body: some View {
        NativeReaderView(galleryID: selected, initialPage: keptPage ?? (switched ? 1 : initialPage), source: source, images: images,
                         savesProgress: savesProgress, resumesProgress: keptPage == nil && resumesProgress, search: { text in prepareClose(); search(text) }, exit: { prepareClose(); exit() }, changeWork: { delta in
            guard let id = MangaReaderSequence.neighbor(position ?? selected, delta: delta, ids: sequence?.ids ?? []) else { return false }
            selected = id; switched = true; keptPage = nil; position = nil; return true
        }, openWork: { id, page in
            position = position ?? selected
            selected = id; switched = true; keptPage = page
        }).id(selected)
    }
    private func prepareClose() {
        sequence?.prepareReturn?(openedID, selected)
        willClose(selected)
    }
}

enum MangaViewerReturn {
    static func targetID<IDs: Sequence>(openedID: Int64?, viewedID: Int64, availableIDs: IDs) -> Int64? where IDs.Element == Int64 {
        guard let openedID, openedID != viewedID, availableIDs.contains(viewedID) else { return nil }
        return viewedID
    }
    @MainActor static func restore<IDs: Sequence>(openedID: Int64?, viewedID: Int64, availableIDs: IDs, using proxy: ScrollViewProxy) where IDs.Element == Int64 {
        guard let target = targetID(openedID: openedID, viewedID: viewedID, availableIDs: availableIDs) else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(target, anchor: .center) }
    }
}
