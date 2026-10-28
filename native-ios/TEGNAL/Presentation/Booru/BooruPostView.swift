import SwiftUI
import Translation
import NaturalLanguage

enum BooruFailureNavigation {
    static func swipe(_ translation: CGSize) -> Int? {
        guard abs(translation.width) > 50, abs(translation.width) > abs(translation.height) * 1.3 else { return nil }
        return translation.width < 0 ? 1 : -1
    }
}

/// Keep the edges tappable and horizontal swipes available even when WebKit
/// has no usable document. Only the center panel owns links and vertical scroll.
struct BooruMediaFailureView: View {
    let post: BooruPost
    let server: BooruServer
    var removed = false
    let onGesture: (BooruMediaGesture) -> Void
    let retry: () -> Void
    private var page: URL { server.pageURL(postID: post.postID) }
    private var email: URL {
        var components = URLComponents(string: "mailto:contact@nextline.work")!
        components.queryItems = [.init(name: "subject", value: "TEGNAL: " + L10n.text("Unable to Load")),
                                 .init(name: "body", value: page.absoluteString)]
        return components.url!
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.9).contentShape(Rectangle())
                    .onTapGesture { point in onGesture(.tap(point.x / max(1, geometry.size.width))) }
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: removed ? "trash" : "photo.badge.exclamationmark").font(.largeTitle)
                        Text(L10n.text(removed ? "Deleted Post" : "Unable to Load")).font(.title2.bold())
                        Text(L10n.text(removed ? "This post was deleted or removed from the website." : "The media could not be loaded or its format is unavailable on this device."))
                            .foregroundStyle(.secondary)
                        Link(destination: page) { Label(L10n.text("Open on Website"), systemImage: "safari").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
                            .accessibilityIdentifier("booru.failure.website")
                        if !removed {
                            Text(L10n.text("If you can view this post on the website, contact the developer so we can fix it. Include the post link."))
                                .font(.callout).foregroundStyle(.secondary)
                            Link(L10n.text("Official Discord"), destination: URL(string: "https://discord.gg/DFT9Hm66Gz")!)
                                .accessibilityIdentifier("booru.failure.discord")
                            Link("contact@nextline.work", destination: email).font(.callout)
                                .accessibilityIdentifier("booru.failure.email")
                            Button(L10n.text("Try Again"), action: retry).buttonStyle(.bordered)
                        }
                    }.multilineTextAlignment(.center).frame(maxWidth: 440).frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                .padding(.horizontal, 44).padding(.top, geometry.safeAreaInsets.top + 36).padding(.bottom, 230)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                if let delta = BooruFailureNavigation.swipe(value.translation) { onGesture(.swipe(delta)) }
            })
        }.accessibilityIdentifier(removed ? "booru.removed" : "booru.failure")
    }
}

struct BooruViewerBatch {
    let posts: [BooruPost]
    let hasMore: Bool
    var failure: String? = nil
}

/// Keep activity in shared state so an in-flight response reads the latest
/// lifecycle, rather than the scenePhase captured by its starting View value.
@MainActor @Observable final class BooruViewerPagination {
    var isActive = false
    private(set) var isLoading = false
    var hasMore = true
    private(set) var requestedFromID: String?
    var wantsNext: Bool { requestedFromID != nil }

    func requestAdvance(from id: String) { requestedFromID = id }
    func cancelAdvance() { requestedFromID = nil }
    func beginRequest() -> Bool {
        guard isActive, !isLoading, hasMore else { return false }
        isLoading = true
        return true
    }
    func finishRequest() { isLoading = false }
    func takeAdvance(currentID: String, nextExists: Bool) -> Bool {
        guard let requestedFromID else { return false }
        guard requestedFromID == currentID else { cancelAdvance(); return false }
        guard isActive else { return false }
        guard nextExists else {
            if !isLoading { cancelAdvance() }
            return false
        }
        cancelAdvance()
        return true
    }
}

struct BooruViewerAccessNavigation {
    enum Destination: Equatable { case post(Int), loadMore, close }
    private(set) var restrictedIDs = Set<String>()
    private(set) var pendingID: String?
    private(set) var direction = 1
    private(set) var enteredByNavigation = false
    private var requestedMore = false

    init(removedIDs: Set<String> = []) { restrictedIDs = removedIDs }

    mutating func moved(_ delta: Int) {
        if delta != 0 { direction = delta < 0 ? -1 : 1; enteredByNavigation = true }
        pendingID = nil; requestedMore = false
    }
    mutating func restrict(_ id: String) {
        restrictedIDs.insert(id)
        guard pendingID != id else { return }
        pendingID = id; requestedMore = false
    }
    mutating func removed(_ id: String) -> Bool {
        restrictedIDs.insert(id)
        guard enteredByNavigation else { return false }
        restrict(id)
        return true
    }
    mutating func recordRemovals(_ posts: [BooruPost]) {
        restrictedIDs.formUnion(posts.lazy.filter(\.isRemoved).map(\.id))
    }
    func candidate(in ids: [String], startingAt index: Int, direction: Int, excluding: Set<String>) -> Int? {
        var index = index
        while ids.indices.contains(index) {
            if !restrictedIDs.contains(ids[index]), !excluding.contains(ids[index]) { return index }
            index += direction < 0 ? -1 : 1
        }
        return nil
    }
    mutating func destination(in ids: [String], current: Int, canLoadMore: Bool, excluding: Set<String>) -> Destination {
        if let next = candidate(in: ids, startingAt: current + direction, direction: direction, excluding: excluding) { return .post(next) }
        if direction > 0, canLoadMore, !requestedMore { requestedMore = true; return .loadMore }
        if let previous = candidate(in: ids, startingAt: current - direction, direction: -direction, excluding: excluding) { return .post(previous) }
        if canLoadMore, !requestedMore { requestedMore = true; return .loadMore }
        return .close
    }
}

struct BooruPostView: View {
    @Environment(\.discoveryContext) private var discovery
    @State private var showDownloads = false
    @State private var posts: [BooruPost]
    var loadMore: (() async -> BooruViewerBatch)?
    var positionChanged: (BooruPost) -> Void
    var willClose: (BooruPost) -> Void
    var contextForPost: ((BooruPost) -> DiscoveryContext)?
    private var activeDiscovery: DiscoveryContext { contextForPost?(post) ?? discovery }
    @State private var pagination = BooruViewerPagination()
    @State private var accessNavigation = BooruViewerAccessNavigation()
    @State private var pagingTask: Task<Void, Never>?
    private var loadingMore: Bool { pagination.isLoading }
    private var wantsNext: Bool { pagination.wantsNext }
    private var hasMorePages: Bool { pagination.hasMore }
    private let initialServer: BooruServer
    private var server: BooruServer { store.servers.first { $0.id == post.serverID } ?? initialServer }
    let source: any BooruProviding
    var challenge: ChallengeSessionController?
    @Environment(BooruStore.self) private var store
    @Environment(AppEnvironment.self) private var env
    @Environment(\.booruBrowsingMode) private var browsingMode
    @Environment(\.dismiss) private var dismiss
    @State private var post: BooruPost
    @State private var notes: [BooruNote] = []
    @State private var notesError: String?
    @State private var loadedNotesKey: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var menuVisible = false
    @SwiftUI.AppStorage("booru.videoMenuHintSeen", store: ReaderPreferences.booruDefaults) private var videoMenuHintSeen = false
    @State private var readerSettings = false
    @State private var filing = false
    @State private var translation: ReaderTranslationRequest?
    @State private var viewport = BooruViewerViewport()
    @State private var zoomed = false
    @State private var toast: String?
    @State private var saveFeedback: WorkSaveFeedback?
    @State private var exiting = false
    @State private var showJump = false
    @State private var jumpText = ""
    @State private var previousIdleTimer = false
    @SwiftUI.AppStorage("reader.rtl", store: ReaderPreferences.booruDefaults) private var rtl = false
    @SwiftUI.AppStorage("reader.bottomMenu", store: ReaderPreferences.booruDefaults) private var bottomMenu = false
    @SwiftUI.AppStorage("reader.pageNumber", store: ReaderPreferences.booruDefaults) private var pageNumber = false
    @SwiftUI.AppStorage("reader.keepAwake", store: ReaderPreferences.booruDefaults) private var keepAwake = true
    @SwiftUI.AppStorage("reader.dimming", store: ReaderPreferences.booruDefaults) private var dimming = 0.0
    @SwiftUI.AppStorage("reader.tapNavigation", store: ReaderPreferences.booruDefaults) private var tapNavigation = true
    @SwiftUI.AppStorage("reader.autoAdvance", store: ReaderPreferences.booruDefaults) private var autoAdvance = false
    @SwiftUI.AppStorage("reader.autoSeconds", store: ReaderPreferences.booruDefaults) private var autoSeconds = 10.0
    @SwiftUI.AppStorage("booru.reducedData", store: ReaderPreferences.booruDefaults) private var reducedData = false
    @SwiftUI.AppStorage("booru.original", store: ReaderPreferences.booruDefaults) private var loadOriginal = false
    @SwiftUI.AppStorage("booru.showNotes", store: ReaderPreferences.booruDefaults) private var showNotes = true
    @State private var original = false
    @State private var info = false
    @State private var selectedNote: BooruNote?
    @State private var mediaStatus = "loading"
    @State private var loadingIndicatorID: String?
    @State private var retry = 0
    @State private var refreshedMediaID: String?
    init(post: BooruPost, posts: [BooruPost], server: BooruServer, source: any BooruProviding, loadMore: (() async -> BooruViewerBatch)? = nil, positionChanged: @escaping (BooruPost) -> Void = { _ in }, willClose: @escaping (BooruPost) -> Void = { _ in }, contextForPost: ((BooruPost) -> DiscoveryContext)? = nil, challenge: ChallengeSessionController? = nil) {
        self.challenge = challenge
        _posts = State(initialValue: posts); self.loadMore = loadMore; self.positionChanged = positionChanged; self.willClose = willClose; self.contextForPost = contextForPost; self.initialServer = server; self.source = source; _post = State(initialValue: post)
        _accessNavigation = State(initialValue: BooruViewerAccessNavigation(removedIDs: Set(posts.lazy.filter(\.isRemoved).map(\.id))))
        _original = State(initialValue: ReaderPreferences.booruDefaults.bool(forKey: "booru.original"))
    }
    private var index: Int { posts.firstIndex(where: { $0.id == post.id }) ?? 0 }
    private var isActive: Bool { !exiting && env.mode == browsingMode && scenePhase == .active }
    private var mediaActive: Bool {
        isActive && !post.isRemoved && mediaStatus != "removed" && store.isVisible(post) && !accessNavigation.restrictedIDs.contains(post.id) && translation == nil && !info && !readerSettings && !filing && !showJump && selectedNote == nil
    }
    private var resolvesMissingMedia: Bool { server.engine.usesGelbooruPages || server.engine == .danbooru }
    private var mediaReady: Bool { ["ready", "playing", "ended"].contains(mediaStatus) }
    private var waitingForMedia: Bool { mediaStatus == "loading" || loadingMore && wantsNext }
    private var mayLoadNotes: Bool { isActive && (showNotes && mediaReady || info) }
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if post.isRemoved || mediaStatus == "removed" {
                    BooruMediaFailureView(post: post, server: server, removed: true, onGesture: gesture, retry: {})
                } else if post.viewerURL(original: original, reducedData: reducedData) != nil || resolvesMissingMedia && mediaStatus != "unavailable" {
                    BooruMediaView(post: post, server: server, original: original, reducedData: reducedData, active: mediaActive, failed: mediaStatus == "error", notes: notes, showNotes: showNotes,
                                   onNote: { selectedNote = $0 }, onStatus: { [postID = post.id] status in
                                       if post.id == postID, !accessNavigation.restrictedIDs.contains(postID) { mediaStatus = status }
                                   }, onGesture: gesture, onGoldRequired: { [postID = post.id] in skipGoldRestricted(postID) },
                                   onRemoved: { [postID = post.id] in removedPost(postID) })
                        .ignoresSafeArea().id("\(server.id)-\(retry)")
                    #if DEBUG
                    if BooruUITestSupport.enabled || BooruUITestSupport.liveEnabled {
                        Text("\(post.postID):\(zoomed ? "zoomed" : "fit")").font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.viewerState").frame(maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                        Text(mediaStatus).font(.caption2).foregroundStyle(.white).accessibilityIdentifier("booru.mediaStatus")
                            .accessibilityValue(post.fileURL?.absoluteString ?? "unresolved")
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                    }
                    #endif
                    if loadingIndicatorID == post.id && waitingForMedia && isActive { ProgressView().tint(.white).allowsHitTesting(false).accessibilityIdentifier("booru.loading") }
                    if mediaStatus == "error" {
                        BooruMediaFailureView(post: post, server: server, onGesture: gesture) { mediaStatus = "loading"; retry += 1 }
                    }
                } else {
                    BooruMediaFailureView(post: post, server: server, onGesture: gesture) { mediaStatus = "loading"; retry += 1 }
                }
                Color.black.opacity(min(0.65, max(0, dimming))).ignoresSafeArea().allowsHitTesting(false)
                VStack {
                    if let toast { Text(toast).font(.subheadline.bold()).padding(12).background(.regularMaterial, in: Capsule()).accessibilityIdentifier("booru.toast") }
                    Spacer()
                    if menuVisible || post.isRemoved || ["error", "unavailable", "removed"].contains(mediaStatus) || post.viewerURL(original: original, reducedData: reducedData) == nil && !resolvesMissingMedia { quickMenu }
                    else if pageNumber { Text("\(index + 1) / \(posts.count)").font(.caption.monospacedDigit()).padding(6).background(.black.opacity(0.5), in: Capsule()) }
                }.padding(16)
            }
            .overlay {
                if let translation {
                    ReaderTranslationView(loadImage: {
                        try await BooruThumbnailCache.shared.translationImage(post: post, server: server, rect: translation.rect)
                    }, booru: true, finished: { self.translation = nil }, failed: { message in self.translation = nil; toast = message })
                        .id(translation.id).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black).transition(.opacity)
                }
            }
            .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
            .overlay(alignment: .top) {
                ReaderDismissHandle(identifier: "booru.exitHandle", dismiss: closeViewer)
                    .ignoresSafeArea(edges: .top)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if bottomMenu && !menuVisible && translation == nil { menuActions(compact: true).padding(12).modifier(ReaderMenuGlass()).padding(.horizontal, 12).padding(.bottom, 6) }
            }
            .overlay(alignment: .top) {
                if let challenge, translation == nil { ChallengeViewerControls(controller: challenge) }
            }
            .onChange(of: challenge?.session.phase) { _, phase in
                if phase == .idle || phase == .ended { closeViewer() }
            }
            .background(VideoMenuGesture(enabled: post.isVideo && !info && !readerSettings && !filing && translation == nil && selectedNote == nil && !showJump) { menuVisible.toggle() })
            .accessibilityAction(named: L10n.text("Open Menu")) { menuVisible = true }
            .background(ReaderKeyboardCommands(enabled: !info && !readerSettings && !filing && !showJump && selectedNote == nil, action: shortcut))
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
            .interactiveDismissDisabled()
            .task(id: post.id) {
                if store.confirmedGoldRestrictedIDs.contains(post.id) { skipGoldRestricted(post.id); return }
                try? store.observeTaste(post, context: activeDiscovery)
                positionChanged(post)
            }
            .task(id: "\(post.id):\(waitingForMedia):\(isActive)") {
                loadingIndicatorID = nil
                guard isActive, waitingForMedia else { return }
                if !(loadingMore && wantsNext), let url = post.viewerURL(original: original, reducedData: reducedData),
                   BooruViewerImageCache.shared.cachedImage(url: url, server: server) != nil { return }
                do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
                catch { return }
                if !(loadingMore && wantsNext), let url = post.viewerURL(original: original, reducedData: reducedData),
                   BooruViewerImageCache.shared.cachedImage(url: url, server: server) != nil { return }
                loadingIndicatorID = post.id
            }
            .task(id: "\(post.id):\(posts.count):\(loadOriginal):\(reducedData):\(mediaActive):\(mediaReady)") { await preloadNeighbors() }
            .task(id: "\(post.id):\(mediaReady):\(isActive)") {
                guard isActive, mediaReady, index >= posts.count - 5 else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                requestMore()
            }
            .appSheet(isPresented: $filing) { BooruFolderPicker(post: post).environment(\.discoveryContext, activeDiscovery) }
            .appSheet(isPresented: $readerSettings) { ReaderSettingsView(booru: true) }
            .alert(L10n.text("Go to Page"), isPresented: $showJump) {
                TextField(L10n.text("Page Number"), text: $jumpText).keyboardType(.numberPad)
                Button(L10n.text("Go")) { if let number = Int(jumpText), posts.indices.contains(number - 1) { move(number - 1 - index) } }
                Button(L10n.text("Cancel"), role: .cancel) {}
            }
            .onAppear { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake }
            .onChange(of: isActive, initial: true) { _, active in
                pagination.isActive = active
                if active { completePendingAdvance() }
            }
            .onChange(of: store.confirmedGoldRestrictedIDs) { _, ids in
                if ids.contains(post.id) { skipGoldRestricted(post.id) }
            }
            .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
                pagination.isActive = false; pagination.cancelAdvance(); pagingTask?.cancel()
            }
            .onChange(of: loadOriginal) { _, value in original = value }
            .onChange(of: post.viewerURL(original: original, reducedData: reducedData)) { _, _ in mediaStatus = "loading" }
            .onChange(of: post.isVideo, initial: true) { _, video in
                if video && !videoMenuHintSeen { videoMenuHintSeen = true; toast = L10n.text("Tap with two fingers for the video menu") }
            }
            .workSaveFeedback($saveFeedback, identifier: "booru.toast")
            .task(id: toast) {
                guard toast != nil else { return }
                do { try await Task.sleep(for: .seconds(2)); toast = nil } catch {}
            }
            .task(id: "\(translation?.id.uuidString ?? ""):\(filing):\(autoAdvance):\(autoSeconds):\(post.id):\(menuVisible):\(readerSettings):\(info):\(showJump):\(selectedNote?.id ?? 0):\(zoomed):\(isActive):\(mediaStatus)") {
                guard autoAdvance, isActive, translation == nil, !filing, !menuVisible, !readerSettings, !info, !showJump, selectedNote == nil, !zoomed, ["ready", "ended"].contains(mediaStatus) else { return }
                do {
                    try await Task.sleep(for: .seconds(min(120, max(2, autoSeconds))))
                    try Task.checkCancellation()
                    if index < posts.count - 1 || loadMore != nil && hasMorePages { move(1) } else { autoAdvance = false }
                } catch {}
            }
            .task(id: mediaStatus == "error" ? post.id : "") {
                guard mediaStatus == "error", resolvesMissingMedia, refreshedMediaID != post.id else { return }
                refreshedMediaID = post.id
                do {
                    let resolved = try await source.details(server: server, post: post)
                    try Task.checkCancellation()
                    if resolved.fileURL != post.fileURL || resolved.sampleURL != post.sampleURL {
                        post = resolved; mediaStatus = "loading"
                        if let folder = store.folderID(for: post) { try store.saveFavorite(post, folderID: folder) }
                    }
                } catch {
                    if !Task.isCancelled {
                        if error as? BooruPostAccessError == .removed { removedPost(post.id) }
                        else if error as? BooruPostAccessError == .goldRequired { skipGoldRestricted(post.id) }
                        else { toast = BooruConnectionMessage.describe(error) }
                    }
                }
            }
            .task(id: post.id + ":\(retry)") { await resolveCurrentPost() }
            .task(id: "\(post.id):\(retry):\(mayLoadNotes)") {
                let key = "\(post.id):\(retry)"
                guard mayLoadNotes, loadedNotesKey != key else { return }
                do {
                    let result = try await source.notes(server: server, postID: post.postID)
                    try Task.checkCancellation()
                    notes = result; loadedNotesKey = key
                } catch {
                    if !Task.isCancelled { notesError = error.localizedDescription; loadedNotesKey = key }
                }
            }
            .appSheet(isPresented: $info) { details }
            .appSheet(item: $selectedNote) { note in
                NavigationStack {
                    BooruNoteTranslationView(text: note.body)
                        .navigationTitle(L10n.text("Notes")).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("Done")) { selectedNote = nil }.accessibilityIdentifier("booru.noteClose").keyboardShortcut(.cancelAction)
                        } }
                }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
        }
        .presentationBackground(.clear)
        .background(ReaderExitGesture(enabled: !exiting && !zoomed && !menuVisible && !info && !readerSettings && !filing && !showJump && translation == nil && selectedNote == nil, movesContainer: true, progress: { _ in }, exit: { closeViewer() }))
    }
    private func shortcut(_ command: ReaderShortcut) {
        guard !info, !readerSettings, !filing, !showJump, selectedNote == nil else { return }
        if command == .exit {
            if translation != nil { translation = nil } else { closeViewer() }
            return
        }
        guard translation == nil else { return }
        switch command {
        case .previous: move(rtl ? 1 : -1)
        case .next: move(rtl ? -1 : 1)
        case .menu: menuVisible.toggle()
        case .favorite: gesture(.hold)
        case .details: info = true
        case .exit: break
        }
    }
    private var quickMenu: some View {
        VStack(spacing: 16) {
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(index == 0).accessibilityLabel(L10n.text("Previous")).accessibilityIdentifier("booru.previous")
                Spacer()
                Button { jumpText = String(index + 1); showJump = true } label: { Text("\(index + 1) / \(posts.count)").font(.headline.monospacedDigit()) }.accessibilityIdentifier("booru.position")
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(index >= posts.count - 1 && (loadMore == nil || !hasMorePages)).accessibilityLabel(L10n.text("Next")).accessibilityIdentifier("booru.next")
                Button { menuVisible = false } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(L10n.text("Close Menu")).accessibilityIdentifier("booru.menuClose")
            }
            menuActions(compact: false)
        }.padding(16).buttonStyle(.plain).modifier(ReaderMenuGlass())
    }
    private func menuActions(compact: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: compact ? 4 : 3), spacing: 18) {
            menuButton(L10n.text("Download Work"), icon: "arrow.down.circle", id: "download", compact: compact) {
                DownloadStore.shared.enqueue(post, server: server); showDownloads = true
            }
            menuButton(L10n.text(store.isFavorite(post) ? "Remove Favorite" : "Add Favorite"), icon: store.isFavorite(post) ? "heart.fill" : "heart", id: "favorite", compact: compact) { toggleFavorite() }
            menuButton(L10n.text("Save to Folder"), icon: "folder", id: "folder", compact: compact) { filing = true }
            menuButton(L10n.text("Translate"), icon: "translate", id: "translate", compact: compact) {
                menuVisible = false; translation = .init(index: index, rect: viewport.rect)
            }.disabled(post.isVideo || mediaStatus != "ready")
            menuButton(L10n.text("Exit"), icon: "rectangle.portrait.and.arrow.right", id: "close", compact: compact) { closeViewer() }
            menuButton(L10n.text("Notes"), icon: showNotes ? "text.bubble.fill" : "text.bubble", id: "notes", compact: compact) { showNotes.toggle() }
            menuButton(L10n.text("Details"), icon: "info.circle", id: "info", compact: compact) { info = true }
            ShareLink(item: server.pageURL(postID: post.postID)) { menuLabel(L10n.text("Share"), icon: "square.and.arrow.up", compact: compact) }
            menuButton(L10n.text("More Settings"), icon: "slider.horizontal.3", id: "readerSettings", compact: compact) { readerSettings = true }
        }.buttonStyle(.plain).foregroundStyle(.white).tint(.white)
            .appSheet(isPresented: $showDownloads) { DownloadsSheet(mode: .booru) }
    }
    private func menuLabel(_ title: String, icon: String, compact: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 21))
            Text(title).font(compact ? .system(size: 9, weight: .medium) : .caption).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, minHeight: 44)
    }
    private func menuButton(_ title: String, icon: String, id: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { menuLabel(title, icon: icon, compact: compact) }.accessibilityLabel(title).accessibilityIdentifier("booru." + id)
    }
    private func toggleFavorite() {
        saveFeedback = .perform { try BooruFavoriteAction.toggle(post, store: store, context: activeDiscovery) }
    }
    private func closeViewer() {
        guard !exiting else { return }
        exiting = true
        pagination.isActive = false; pagination.cancelAdvance()
        willClose(post)
        dismiss()
    }
    private func gesture(_ gesture: BooruMediaGesture) {
        guard !info, !readerSettings, !filing, translation == nil, selectedNote == nil, !showJump else { return }
        switch gesture {
        case .shortcut(let command): shortcut(command)
        case .tap(let x):
            if (0.3...0.7).contains(x) { menuVisible.toggle() }
            else if tapNavigation { move((x < 0.3 ? -1 : 1) * (rtl ? -1 : 1)) }
        case .swipe(let delta): if !zoomed { move(delta * (rtl ? -1 : 1)) }
        case .hold:
            toggleFavorite()
        case .dismiss: if !zoomed { closeViewer() }
        case .details: if !zoomed { info = true }
        case .zoom(let value): if zoomed != value { zoomed = value }
        case .viewport(let rect): viewport.rect = rect
        }
    }
    private func resolveCurrentPost() async {
        notes = []; notesError = nil
        if post.isRemoved { removedPost(post.id); return }
        if resolvesMissingMedia && post.viewerURL(original: original, reducedData: reducedData) == nil {
            do {
                let resolved = try await source.details(server: server, post: post)
                try Task.checkCancellation()
                post = resolved; positionChanged(resolved)
                if let i = posts.firstIndex(where: { $0.id == resolved.id }) { posts[i] = resolved }
                if resolved.viewerURL(original: original, reducedData: reducedData) == nil { mediaStatus = "unavailable" }
                if let folder = store.folderID(for: post) { try store.saveFavorite(post, folderID: folder) }
            } catch {
                if !Task.isCancelled {
                    if error as? BooruPostAccessError == .removed { removedPost(post.id) }
                    else if error as? BooruPostAccessError == .goldRequired { skipGoldRestricted(post.id) }
                    else { mediaStatus = "error"; toast = BooruConnectionMessage.describe(error) }
                }
            }
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("ID") {
                        HStack {
                            Text(String(post.postID)).textSelection(.enabled).accessibilityIdentifier("booru.postID")
                            Button { UIPasteboard.general.string = String(post.postID) } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel(L10n.text("Copy ID")).accessibilityIdentifier("booru.copyID")
                        }
                    }
                    LabeledContent(L10n.text("Server"), value: server.displayName)
                    LabeledContent(L10n.text("Resolution"), value: "\(post.width) × \(post.height)")
                    LabeledContent(L10n.text("Format"), value: post.fileExtension.uppercased())
                    LabeledContent(L10n.text("Score"), value: String(post.score))
                    if !post.isVideo && !post.isAnimated {
                        Toggle(L10n.text("Original Image"), isOn: $original)
                    }
                    Link(L10n.text("Open on Website"), destination: server.pageURL(postID: post.postID))
                }
                ForEach(ArtworkTagGroup.make(tags: post.tags, artists: post.artists, categories: post.tagCategories ?? [:])) { group in
                    Section {
                        ForEach(group.tags) { tag in
                            tagRow(tag.query, category: group.category, title: tag.name).tint(group.category.color).foregroundStyle(group.category.color)
                        }
                    } header: { ArtworkTagHeading(category: group.category) }
                }
                if !post.poolIDs.isEmpty {
                    Section(L10n.text("Pools")) {
                        ForEach(post.poolIDs, id: \.self) { id in
                            NavigationLink("Pool #\(id)") { BooruFeedView(server: server, source: source, pool: .init(id: id, name: "Pool #\(id)", count: 0)) }
                        }
                    }
                }
                Section(L10n.text("Notes")) {
                    if let notesError {
                        Text(notesError).foregroundStyle(.secondary)
                        Button(L10n.text("Try Again")) { retry += 1 }
                    } else if notes.isEmpty { Text(L10n.text("No Notes")).foregroundStyle(.secondary) }
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        VStack(alignment: .leading, spacing: 6) { Text("#\(index + 1)").font(.caption).foregroundStyle(.secondary); Text(note.body).textSelection(.enabled) }
                    }
                }
                Section(L10n.text("Content Controls")) {
                    NavigationLink { ContentReportView(page: server.pageURL(postID: post.postID)) } label: {
                        Label(L10n.text("Report Content"), systemImage: "flag")
                    }.accessibilityIdentifier("booru.report")
                    Button(L10n.text("Hide This Post"), systemImage: "eye.slash") { hideContent(rule: "id:\(post.postID)") }
                        .accessibilityIdentifier("booru.hidePost")
                    if !post.artists.isEmpty {
                        Menu(L10n.text("Block Artist"), systemImage: "person.crop.circle.badge.xmark") {
                            ForEach(post.artists, id: \.self) { artist in
                                Button(artist) { hideContent(rule: "artist:" + artist) }
                            }
                        }
                    }
                }
            }.navigationTitle(L10n.text("Details")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { info = false }.keyboardShortcut(.cancelAction) } }
        }.presentationDragIndicator(.visible)
            .task(id: post.id) {
                guard server.engine.usesGelbooruPages, post.tagCategories == nil else { return }
                do {
                    let resolved = try await source.details(server: server, post: post)
                    try Task.checkCancellation()
                    post = resolved
                    if let index = posts.firstIndex(where: { $0.id == resolved.id }) { posts[index] = resolved }
                } catch { if !Task.isCancelled { toast = BooruConnectionMessage.describe(error) } }
            }
    }
    private func hideContent(rule: String) {
        store.perform {
            let old = store.blacklist(serverID: server.id)
            try store.setBlacklist(old.isEmpty ? rule : old + "\n" + rule, serverID: server.id)
            info = false
            closeViewer()
        }
    }

    private func tagRow(_ tag: String, category: ArtworkTagCategory, title: String? = nil) -> some View {
        HStack {
            NavigationLink { BooruFeedView(server: server, source: source, initialQuery: tag) } label: { Text(title ?? tag.replacingOccurrences(of: "_", with: " ")) }
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in saveTag(tag, kind: SavedCollectionKind(category: category).rawValue) })
                .accessibilityAction(named: L10n.text("Save Tag")) { saveTag(tag, kind: SavedCollectionKind(category: category).rawValue) }
            Menu {
                Button(L10n.text(store.savedTags(serverID: server.id, kind: SavedCollectionKind(category: category).rawValue).contains(tag) ? "Remove Saved Tag" : "Save Tag"), systemImage: "tag") { saveTag(tag, kind: SavedCollectionKind(category: category).rawValue) }
                Button(L10n.text("Save Artist"), systemImage: "person") { saveTag(tag, kind: "artist") }
                Button(L10n.text("Blacklist Tag"), systemImage: "eye.slash") {
                    store.perform {
                        let old = store.blacklist(serverID: server.id)
                        try store.setBlacklist(old.isEmpty ? tag : old + "\n" + tag, serverID: server.id)
                        info = false
                        closeViewer()
                    }
                }
            } label: {
                Image(systemName: store.savedTags(serverID: server.id, kind: SavedCollectionKind(category: category).rawValue).contains(tag) ? "star.fill" : "ellipsis.circle")
            }.buttonStyle(.borderless)
        }
    }
    private func saveTag(_ tag: String, kind: String) {
        do {
            let saved = !store.savedTags(serverID: server.id, kind: kind).contains(tag)
            try store.toggleTag(tag, serverID: server.id, kind: kind)
            SavedTagFeedback.notify(saved: saved)
            toast = L10n.text(saved ? "Saved to Tags" : "Removed from Tags")
        } catch { toast = error.localizedDescription }
    }
    private func move(_ delta: Int) {
        guard pagination.isActive else { return }
        let next = accessNavigation.candidate(in: posts.map(\.id), startingAt: index + delta,
                                             direction: delta < 0 ? -1 : 1, excluding: store.confirmedGoldRestrictedIDs)
        guard let next else {
            if delta > 0, loadMore != nil, hasMorePages { pagination.requestAdvance(from: post.id); requestMore() }
            else { pagination.cancelAdvance() }
            return
        }
        pagination.cancelAdvance()
        accessNavigation.moved(delta)
        // The jump alert dismisses independently. Retain the ready document,
        // crop and notes when its selected page has not changed.
        guard next != index else { return }
        selectPost(at: next)
    }
    private func selectPost(at next: Int) {
        viewport.rect = CGRect(x: 0, y: 0, width: 1, height: 1); translation = nil
        post = posts[next]; original = loadOriginal; mediaStatus = "loading"; zoomed = false; notes = []; loadedNotesKey = nil
        positionChanged(post)
    }
    private func skipGoldRestricted(_ id: String) {
        guard !exiting, post.id == id else { return }
        store.recordGoldRestriction(post)
        accessNavigation.restrict(id)
        pagination.cancelAdvance()
        mediaStatus = "restricted"
        continueAfterRestriction()
    }
    private func removedPost(_ id: String) {
        guard !exiting, post.id == id else { return }
        pagination.cancelAdvance()
        mediaStatus = "removed"; notes = []; zoomed = false
        if accessNavigation.removed(id) { continueAfterRestriction() }
    }
    private func continueAfterRestriction() {
        guard pagination.isActive, !pagination.isLoading, accessNavigation.pendingID == post.id else { return }
        let destination = accessNavigation.destination(in: posts.map(\.id), current: index,
                                                       canLoadMore: loadMore != nil && hasMorePages,
                                                       excluding: store.confirmedGoldRestrictedIDs)
        switch destination {
        case .post(let next):
            let direction = accessNavigation.direction
            accessNavigation.moved(direction)
            selectPost(at: next)
        case .loadMore: requestMore()
        case .close: closeViewer()
        }
    }
    private func requestMore() {
        guard loadMore != nil, pagination.beginRequest() else { return }
        pagingTask = Task {
            await extendFeed()
            pagination.finishRequest()
            guard !Task.isCancelled else { return }
            completePendingAdvance()
        }
    }
    private func extendFeed() async {
        guard let loadMore else { return }
        let batch = await loadMore()
        guard !Task.isCancelled else { return }
        var seen = Set(posts.map(\.id))
        posts += batch.posts.filter { seen.insert($0.id).inserted }
        accessNavigation.recordRemovals(batch.posts)
        pagination.hasMore = batch.hasMore
        if let failure = batch.failure { toast = failure }
    }
    private func completePendingAdvance() {
        if accessNavigation.pendingID == post.id { continueAfterRestriction(); return }
        let next = accessNavigation.candidate(in: posts.map(\.id), startingAt: index + 1, direction: 1,
                                             excluding: store.confirmedGoldRestrictedIDs)
        if pagination.takeAdvance(currentID: post.id, nextExists: next != nil), let next { move(next - index) }
    }
    private func preloadNeighbors() async {
        #if DEBUG
        if BooruUITestSupport.enabled { return }
        #endif
        guard mediaActive, mediaReady, !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair else { return }
        // Wait for a settled page; fast swipes should not fetch four originals.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let next = index + 1
        guard posts.indices.contains(next) else { return }
        var item = posts[next]
        guard let host = store.servers.first(where: { $0.id == item.serverID }) else { return }
        if item.viewerURL(original: loadOriginal, reducedData: reducedData) == nil, host.engine.usesGelbooruPages,
           let resolved = try? await source.details(server: host, post: item) {
            guard !Task.isCancelled else { return }
            item = resolved
            if let i = posts.firstIndex(where: { $0.id == item.id }) { posts[i] = item }
        }
        if !item.isVideo, let url = item.viewerURL(original: loadOriginal, reducedData: reducedData) {
            await BooruViewerImageCache.shared.prefetch(url: url, server: host)
        }
    }

}

/// Panning updates the next translation crop without rebuilding the viewer.
private final class BooruViewerViewport {
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Two fingers reach the app menu without intercepting a video's native play,
/// seek, mute, or fullscreen controls. Single taps outside video still work.
private struct VideoMenuGesture: UIViewRepresentable {
    var enabled: Bool
    var action: () -> Void
    func makeUIView(context: Context) -> VideoMenuGestureView { VideoMenuGestureView() }
    func updateUIView(_ view: VideoMenuGestureView, context: Context) { view.action = action; view.tap.isEnabled = enabled }
    static func dismantleUIView(_ view: VideoMenuGestureView, coordinator: ()) { view.tap.view?.removeGestureRecognizer(view.tap) }
}
private final class VideoMenuGestureView: UIView, UIGestureRecognizerDelegate {
    var action: () -> Void = {}
    lazy var tap: UITapGestureRecognizer = {
        let value = UITapGestureRecognizer(target: self, action: #selector(openMenu))
        value.numberOfTouchesRequired = 2; value.cancelsTouchesInView = false; value.delegate = self
        return value
    }()
    override func didMoveToWindow() {
        super.didMoveToWindow(); tap.view?.removeGestureRecognizer(tap); window?.addGestureRecognizer(tap)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    @objc private func openMenu() { action() }
}

/// A note opens directly into Apple Translation using the image viewer's target language.
private struct BooruNoteTranslationView: View {
    let text: String
    var body: some View {
        if #available(iOS 18.0, *) {
            AutomaticallyTranslatedBooruNote(text: text, target: ReaderTranslationLanguage.resolved(ReaderTranslationLanguage.preference(booru: true)))
        } else if #available(iOS 17.4, *) {
            SystemTranslatedBooruNote(text: text)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("Translation requires iOS 17.4 or later.")).foregroundStyle(.secondary)
                    Text(text).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        }
    }
}

@available(iOS 17.4, *)
private struct SystemTranslatedBooruNote: View {
    let text: String
    @State private var translating = false
    var body: some View {
        ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
            .translationPresentation(isPresented: $translating, text: text)
            .task { translating = true }
    }
}

@available(iOS 18.0, *)
private struct AutomaticallyTranslatedBooruNote: View {
    let text: String
    let target: String
    @State private var translated: String?
    @State private var failure: String?
    @State private var configuration: TranslationSession.Configuration?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let translated {
                    Text(translated).textSelection(.enabled).accessibilityIdentifier("booru.note.translation")
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary)
                    Button(L10n.text("Try Again")) { self.failure = nil; configuration?.invalidate() }
                } else { ProgressView(L10n.text("Translating…")).accessibilityIdentifier("booru.note.translating") }
                if translated != text {
                    Divider()
                    Text(L10n.text("Original Text")).font(.caption).foregroundStyle(.secondary)
                    Text(text).textSelection(.enabled).foregroundStyle(.secondary)
                        .accessibilityIdentifier("booru.note.original")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .task {
            let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
            let source = recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
            let destination = Locale.Language(identifier: target)
            if let source, source.languageCode == destination.languageCode { translated = text }
            else { configuration = .init(source: source, target: destination) }
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                try Task.checkCancellation()
                translated = response.targetText
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
