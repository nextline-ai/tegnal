import SwiftUI
import GRDB

public struct WorksGridView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    public let folder: Folder?
    public let artist: String?
    private let opensSearch: Bool

    @State private var works: [Work] = []
    /// Everything in this folder or search, before the category narrows it.
    @State private var scopeWorks: [Work] = []
    @State private var categories: [(key: String, count: Int)] = []
    @State private var category = ""
    @State private var reloadGeneration = 0
    @State private var similarity: VisualSimilaritySeed?
    @State private var selecting = false
    @State private var selection = Set<Int64>()
    @State private var confirmingDelete = false
    @State private var allFolders: [Folder] = []
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var selectedDetailGalleryId: Int64?
    @State private var activeBrowserUrl: String?
    @State private var activeBrowserShowsInformation = false
    @State private var workPendingDelete: Work?
    @State private var workPendingMoveToNewFolder: Work?
    @State private var showNewFolderAlert = false
    @State private var toastMessage: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var showJumpSheet = false
    @State private var pendingJump: Int64?
    @State private var composingFolder = false
    @FocusState private var isSearchFocused: Bool

    public init(folder: Folder? = nil, artist: String? = nil) {
        self.folder = folder
        self.artist = artist
        opensSearch = false
    }

    init(search: String) {
        folder = nil
        artist = nil
        opensSearch = true
        _searchText = State(initialValue: search)
    }

    private var isPushed: Bool {
        folder != nil || artist != nil || opensSearch
    }

    public var body: some View {
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 56).id("works.top")

                    if categories.count > 1 || !category.isEmpty {
                        HStack { categoryMenu; Spacer(minLength: 0) }.padding(.horizontal, 16).padding(.bottom, 8)
                    }

                    if works.isEmpty, !category.isEmpty, !scopeWorks.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.text("No Works in This Category"), systemImage: "square.stack")
                        } actions: {
                            Button(L10n.text("Show All Categories")) { category = "" }.accessibilityIdentifier("works.allCategories")
                        }.padding(.top, 40)
                    } else if works.isEmpty {
                        ContentUnavailableView(
                            L10n.text("No Works"),
                            systemImage: "square.grid.2x2",
                            description: Text(searchText.isEmpty ? L10n.text("Add a work number to get started.") : L10n.text("No results for '%@'", String(describing: searchText)))
                        )
                        .padding(.top, 40)
                    } else {
                        ArtworkGrid(mode: .manga) { style in
                            ForEach(works) { work in
                                WorkCardView(work: work)
                                    .id(work.galleryId)
                                    .accessibilityIdentifier("works.card.\(work.galleryId)")
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if selecting {
                                            if selection.contains(work.galleryId) { selection.remove(work.galleryId) } else { selection.insert(work.galleryId) }
                                        } else { open(work) }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { Image(systemName: selection.contains(work.galleryId) ? "checkmark.circle.fill" : "circle").font(.system(size: style.fontSize(22, minimum: 12))).foregroundStyle(.white, .blue).padding(style.inset(10)).allowsHitTesting(false) }
                                    }
                                    .contextMenu {
                                        workContextMenu(for: work)
                                    } preview: {
                                        WorkContextPreview(work: work)
                                    }

                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                handleScrollGeometry(oldY: oldY, newY: newY)
            }

            standardSearchBar
                .offset(y: isSearchBarVisible ? 0 : -60)
                .opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: category) { applyCategory() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isPushed)
        .toolbarBackground(.hidden, for: .navigationBar)
        .appSheet(item: $similarity) { VisualSimilarityView(seed: $0) }
        .appSheet(item: Binding(
            get: { selectedDetailGalleryId.map { IdentifiableInt64(id: $0) } },
            set: { selectedDetailGalleryId = $0?.id }
        ), onDismiss: { loadWorks() }) { item in
            ContentEntryView(initialUrl: MangaUrls.galleryUrl(for: item.id), siblingIDs: works.map(\.galleryId), willCloseManga: { viewed in
                MangaViewerReturn.restore(openedID: item.id, viewedID: viewed, availableIDs: works.lazy.map(\.galleryId), using: proxy)
            })
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .appSheet(item: browserSelection(information: true)) { item in
            ContentEntryView(initialUrl: item.id, siblingIDs: works.map(\.galleryId), willCloseManga: { viewed in
                MangaViewerReturn.restore(openedID: GalleryIDParser.parse(item.id).first, viewedID: viewed, availableIDs: works.lazy.map(\.galleryId), using: proxy)
            })
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .appFullScreenCover(item: browserSelection(information: false)) { item in
            ContentEntryView(initialUrl: item.id, siblingIDs: works.map(\.galleryId), willCloseManga: { viewed in
                MangaViewerReturn.restore(openedID: GalleryIDParser.parse(item.id).first, viewedID: viewed, availableIDs: works.lazy.map(\.galleryId), using: proxy)
            })
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isPushed {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.backward")
                                .font(.system(size: 14, weight: .bold))
                            Text(artist ?? folder?.displayName ?? L10n.text(opensSearch ? "Search Results" : "All"))
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                } else {
                    LiquidGlassTitleCapsule(L10n.text("All"))
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                AppToolbarActions {
                    Button { selecting.toggle(); selection.removeAll() } label: { Image(systemName: selecting ? "xmark" : "checkmark.circle") }
                        .frame(height: 32).accessibilityLabel(L10n.text(selecting ? "Done" : "Select")).accessibilityIdentifier("works.select")
                    if selecting {
                        Menu {
                            Button(L10n.text("Select All")) { selection = Set(works.map(\.galleryId)) }
                            ForEach(allFolders) { target in
                                Button(target.displayName) {
                                    do {
                                        if let id = target.id { try env.database.moveSelectedWorks(selection, to: id, from: folder?.id) }
                                        selection.removeAll(); selecting = false; loadWorks()
                                    } catch { showToast(error.localizedDescription) }
                                }
                            }
                        } label: { Image(systemName: "folder") }.frame(height: 32).accessibilityLabel(L10n.text("Move to Another Folder"))
                        Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }.frame(height: 32).disabled(selection.isEmpty)
                            .accessibilityLabel(L10n.text("Delete")).accessibilityIdentifier("works.selection.delete")
                    } else {
                    if opensSearch {
                        Button { composingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                            .frame(height: 32).disabled(works.isEmpty).accessibilityLabel(L10n.text("Create Folder from Results")).accessibilityIdentifier("works.createFolder")
                    }
                    Menu {
                        Button(L10n.text("Jump to Top"), systemImage: "arrow.up.to.line") { isSearchFocused = false; proxy.scrollTo("works.top", anchor: .top) }
                        Button(L10n.text("Jump to Bottom"), systemImage: "arrow.down.to.line") {
                            isSearchFocused = false
                            if let id = works.last?.galleryId { proxy.scrollTo(id, anchor: .bottom) }
                        }
                        Button(L10n.text("Browse by Saved Date"), systemImage: "calendar") { isSearchFocused = false; showJumpSheet = true }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .frame(height: 32)
                    .disabled(works.isEmpty).accessibilityLabel(L10n.text("Quick Jump")).accessibilityIdentifier("works.jump")
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .frame(height: 32)
                    .accessibilityIdentifier("works.add")
                    }
                }
            }
        }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            deleteButtons(selection) { selection.removeAll(); selecting = false }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(deleteMessage(selection))
        }
        .appSheet(isPresented: $showJumpSheet, onDismiss: {
            if let id = pendingJump { proxy.scrollTo(id, anchor: .top); pendingJump = nil }
        }) {
            savedDateSheet
        }
        .appSheet(isPresented: $showAddSheet, onDismiss: { loadWorks() }) {
            AddWorkSheet()
        }
        .appSheet(isPresented: $composingFolder) { FolderRuleEditor(tag: searchText) }
        .alert(L10n.text("Delete Work"), isPresented: Binding(
            get: { workPendingDelete != nil },
            set: { if !$0 { workPendingDelete = nil } }
        )) {
            if let work = workPendingDelete {
                deleteButtons([work.galleryId]) { workPendingDelete = nil }
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                workPendingDelete = nil
            }
        } message: {
            if let work = workPendingDelete { Text(deleteMessage(work)) }
        }
        .newFolderPrompt(isPresented: $showNewFolderAlert, title: "Create Folder and Move", actionTitle: "Create and Move") { identity in
            if let work = workPendingMoveToNewFolder, let id = try? env.database.folderID(identity: identity),
               let folder = try? env.database.listFolders().first(where: { $0.id == id }) {
                moveWork(work, to: folder)
            }
            workPendingMoveToNewFolder = nil
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background {
            #if os(iOS)
            NavigationPopGestureEnabler().frame(width: 0, height: 0)
            #endif
        }
        .task(id: WorksQuery(query: searchText, revision: reloadGeneration, active: env.mode == .manga && scenePhase == .active)) {
            await observeWorks()
        }
        }
    }

    @MainActor private func observeWorks() async {
        guard env.mode == .manga, scenePhase == .active else { return }
        let query = searchText
        let folderID = folder?.id
        let selectedArtist = artist
        do {
            // Cancel superseded searches before scanning a large local library.
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            let observation = ValueObservation.tracking { db -> WorkSnapshot in
                let works = try AppDatabase.fetchWorks(db, folderId: folderID, query: query, artist: selectedArtist)
                let folders = try AppDatabase.fetchFolders(db)
                return WorkSnapshot(works: works, folders: folders)
            }.removeDuplicates()
            for try await snapshot in observation.values(in: env.database.dbWriter, bufferingPolicy: .bufferingNewest(1)) {
                try Task.checkCancellation()
                scopeWorks = snapshot.works
                applyCategory()
                if allFolders != snapshot.folders { allFolders = snapshot.folders }
            }
        } catch is CancellationError { }
        catch { showToast(error.localizedDescription) }
    }

    private var categoryMenu: some View {
        BrowseFilterMenu(title: category.isEmpty ? L10n.text("Category") : GalleryCategory.title(category), icon: "square.stack") {
            Picker(L10n.text("Category"), selection: $category) {
                Text(L10n.text("All Categories")).tag("")
                ForEach(categories, id: \.key) { item in
                    Text(L10n.text("%@ (%@)", GalleryCategory.title(item.key), item.count.formatted())).tag(item.key)
                }
            }
        }
        .accessibilityIdentifier("works.category")
    }

    private func applyCategory() {
        var counts: [String: Int] = [:]
        for work in scopeWorks {
            let key = GalleryCategory.key(work.type ?? "")
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        categories = counts.map { (key: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
        works = category.isEmpty ? scopeWorks : scopeWorks.filter { GalleryCategory.key($0.type ?? "") == category }
    }

    private func browserSelection(information: Bool) -> Binding<IdentifiableString?> {
        Binding(get: {
            activeBrowserShowsInformation == information ? activeBrowserUrl.map { IdentifiableString(id: $0) } : nil
        }, set: { item in
            if activeBrowserShowsInformation == information { activeBrowserUrl = item?.id }
        })
    }
    /// A saved number names the same work on every connected website.
    private func open(_ work: Work) {
        // Opens where it still is: the website it came from comes right after the checked one.
        SiteFallbackContent.shared.prefer(work.site, for: work.galleryId)
        openManga(for: work.galleryId)
    }
    private func openManga(for galleryId: Int64) {
        let opening = MangaThumbnailOpening.stored()
        activeBrowserShowsInformation = opening == .information
        activeBrowserUrl = opening.url(for: galleryId)
    }

    private struct WorkSnapshot: Equatable {
        let works: [Work]
        let folders: [Folder]
    }

    private struct WorksQuery: Hashable {
        let query: String
        let revision: Int
        let active: Bool
    }

    private func loadWorks() {
        reloadGeneration += 1
    }

    private func moveWork(_ work: Work, to targetFolder: Folder) {
        guard let targetId = targetFolder.id else { return }
        do {
            try env.database.moveWorkToFolder(
                galleryId: work.galleryId,
                targetFolderId: targetId,
                currentFolderId: folder?.id
            )
            loadWorks()
            showToast(L10n.text("Moved to folder '%@'", String(describing: targetFolder.displayName)))
        } catch {
            print("Failed to move work: \(error)")
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    /// Delete, or with favorites a website keeps in step, a choice of taking them off the website too.
    @ViewBuilder
    private func deleteButtons(_ ids: Set<Int64>, done: @escaping () -> Void) -> some View {
        if env.syncedSiteFavorites(among: ids) {
            Button(L10n.text("Delete Here and on Website"), role: .destructive) { delete(ids, keepOnWebsite: false); done() }
                .accessibilityIdentifier("works.delete.everywhere")
            Button(L10n.text("Delete in App Only"), role: .destructive) { delete(ids, keepOnWebsite: true); done() }
                .accessibilityIdentifier("works.delete.appOnly")
        } else {
            Button(L10n.text("Delete"), role: .destructive) { delete(ids, keepOnWebsite: false); done() }
        }
    }

    private var savedDateSheet: some View {
        SavedDateView(months: WorkMonthDestination.make(works), runs: WorkSaveBatch.make(works),
                      broughtIn: env.siteFavoritesSetUpTimes, identifier: "works", jump: { id in
            pendingJump = id; showJumpSheet = false
        }, select: { ids in
            selection = Set(ids); selecting = true
            pendingJump = works.first { selection.contains($0.galleryId) }?.galleryId
            showJumpSheet = false
        })
    }

    private func deleteMessage(_ work: Work) -> String {
        let question = L10n.text("Delete this work (number: %@)?", String(describing: String(work.galleryId)))
        guard env.syncedSiteFavorites(among: [work.galleryId]) else { return question }
        return question + "\n" + L10n.text("It is also a favorite on a website synced with your folders.")
    }

    private func deleteMessage(_ ids: Set<Int64>) -> String {
        let count = L10n.text("%@ works will be deleted.", ids.count.formatted())
        return env.syncedSiteFavorites(among: ids) ? count + "\n" + L10n.text("Some of them are favorites on a website synced with your folders.") : count
    }

    private func delete(_ ids: Set<Int64>, keepOnWebsite: Bool) {
        do { try env.deleteSavedWorks(ids, keepOnWebsite: keepOnWebsite); loadWorks() }
        catch { showToast(error.localizedDescription) }
    }

    private static func cover(of work: Work) -> UIImage? {
        guard work.thumbStatus == "ready", let path = work.thumbPath else { return nil }
        return LocalThumbnailCache.shared.image(forPath: path) ?? UIImage(contentsOfFile: path)
    }
    @ViewBuilder
    private func workContextMenu(for work: Work) -> some View {
        if env.readingQueue.contains(work.galleryId) {
            Button(L10n.text("Remove from Up Next"), systemImage: "minus.circle") { env.readingQueue.remove(work.galleryId) }
        } else {
            Button(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward") {
                if env.readingQueue.add(ReadingQueueItem(work: work), cover: Self.cover(of: work)) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            }
        }
        Button(L10n.text("Find works with a similar art style"), systemImage: "photo.on.rectangle.angled") { similarity = .init(work: work) }
        Menu {
            Button {
                workPendingMoveToNewFolder = work
                showNewFolderAlert = true
            } label: {
                Label(L10n.text("Create New Folder…"), systemImage: "folder.badge.plus")
            }

            Divider()

            ForEach(allFolders) { targetFolder in
                Button {
                    moveWork(work, to: targetFolder)
                } label: {
                    HStack {
                        Text(targetFolder.displayName)
                        if targetFolder.id == folder?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(L10n.text("Move to Another Folder"), systemImage: "folder")
        }

        Button {
            selectedDetailGalleryId = work.galleryId
        } label: {
            Label(L10n.text("Work Details"), systemImage: "info.circle")
        }

        Button {
            UIPasteboard.general.string = String(work.galleryId)
            showToast(L10n.text("Copied work number %@", String(describing: String(work.galleryId))))
        } label: {
            Label(L10n.text("Copy Work Number (%@)", String(describing: String(work.galleryId))), systemImage: "doc.on.doc")
        }

        Button(role: .destructive) {
            workPendingDelete = work
        } label: {
            Label(L10n.text("Delete"), systemImage: "trash")
        }
    }

    private var standardSearchBar: some View {
        ScrollSearchBar(text: $searchText, focused: $isSearchFocused, prompt: L10n.text("Search works"), identifier: "works.search")
    }

    private func handleScrollGeometry(oldY: CGFloat, newY: CGFloat) {
        if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: isSearchFocused) {
            isSearchBarVisible = visible
        }
    }

}

extension View {
    @ViewBuilder
    func trackScrollGeometry(onScroll: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldY, newY in
                onScroll(oldY, newY)
            }
        } else {
            self
        }
    }
}

#if os(iOS)
final class PopGestureController: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.delegate = self
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return (navigationController?.viewControllers.count ?? 0) > 1
    }
}

struct NavigationPopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PopGestureController {
        PopGestureController()
    }
    func updateUIViewController(_ uiViewController: PopGestureController, context: Context) {}
}
#endif






/// Accumulate movement so slow drags and 120 Hz displays behave like fast swipes.
/// This is intentionally not observable: only a visibility change redraws the view.
final class ScrollSearchVisibility {
    private var travel: CGFloat = 0
    func update(oldY: CGFloat, newY: CGFloat, focused: Bool) -> Bool? {
        if focused || newY <= 15 { travel = 0; return true }
        let delta = newY - oldY
        guard abs(delta) > 0.1 else { return nil }
        if travel * delta < 0 { travel = delta } else { travel += delta }
        if travel >= 32 { travel = 0; return false }
        if travel <= -24 { travel = 0; return true }
        return nil
    }
}

/// Shared by library and Explore so scrolling and search appearance stay consistent.
struct ScrollSearchBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let prompt: String
    let identifier: String
    var submit: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(.system(size: 16)).textFieldStyle(.plain)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused(focused).submitLabel(.search).onSubmit(submit)
                .accessibilityIdentifier(identifier)
            Button {
                if text.isEmpty { focused.wrappedValue = false } else { text = "" }
            } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 32, height: 40).contentShape(Rectangle()) }
                .buttonStyle(.plain).opacity((focused.wrappedValue || !text.isEmpty) ? 1 : 0)
                .accessibilityLabel(L10n.text("Clear Search"))
        }
        .padding(.horizontal, 14).frame(height: 44).glassCapsule(isInteractive: true)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

/// Saved items of one month, in the order the list shows them.
struct SavedMonth<ItemID: Hashable>: Identifiable {
    /// The month as `yyyy-MM`.
    let id: String
    var ids: [ItemID]
    var firstID: ItemID { ids[0] }
    var count: Int { ids.count }
    var title: String {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return L10n.text("No Date") }
        return L10n.text("%@-%@", String(describing: parts[0]), String(describing: month))
    }
    /// Each item with its month, in the order the list shows them.
    static func make(items: [(id: ItemID, month: String)]) -> [Self] {
        var destinations: [Self] = []
        var positions: [String: Int] = [:]
        for item in items {
            if let index = positions[item.month] { destinations[index].ids.append(item.id) }
            else {
                positions[item.month] = destinations.count
                destinations.append(Self(id: item.month, ids: [item.id]))
            }
        }
        return destinations
    }
}

typealias WorkMonthDestination = SavedMonth<Int64>
extension SavedMonth where ItemID == Int64 {
    var firstGalleryID: Int64 { firstID }
    static func make(_ works: [Work]) -> [Self] { make(items: works.map { ($0.galleryId, String($0.bookmarkedAt.prefix(7))) }) }
}

/// Items saved one right after another, as favorites brought in from a website or an import are:
/// each was saved within a minute of the one before, and there are at least a few of them.
struct SavedRun<ItemID: Hashable>: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    /// In the order the list shows them.
    let ids: [ItemID]
    var firstID: ItemID { ids[0] }

    static var gap: TimeInterval { 60 }
    static var minimum: Int { 5 }

    /// Each item with when it was saved, in the order the list shows them; newest run first.
    static func make(items: [(id: ItemID, date: Date?)], gap: TimeInterval = gap, minimum: Int = minimum) -> [Self] {
        let dated = items.compactMap { item in item.date.map { (id: item.id, date: $0) } }.sorted { $0.date < $1.date }
        var groups: [[(id: ItemID, date: Date)]] = []
        for item in dated {
            if let last = groups.last?.last, item.date.timeIntervalSince(last.date) <= gap { groups[groups.count - 1].append(item) }
            else { groups.append([item]) }
        }
        var order: [ItemID: Int] = [:]
        for (index, item) in items.enumerated() where order[item.id] == nil { order[item.id] = index }
        return groups.filter { $0.count >= minimum }.reversed().map { group in
            Self(start: group[0].date, end: group[group.count - 1].date,
                 ids: group.map(\.id).sorted { order[$0, default: .max] < order[$1, default: .max] })
        }
    }

    /// Whether this is the favorites a website brought in when its sync was set up.
    func broughtIn(at times: [Date]) -> Bool {
        times.contains { $0 >= start.addingTimeInterval(-Self.gap) && $0 <= end.addingTimeInterval(Self.gap) }
    }
}

typealias WorkSaveBatch = SavedRun<Int64>
extension SavedRun where ItemID == Int64 {
    var firstGalleryID: Int64 { firstID }
    static func make(_ works: [Work], gap: TimeInterval = gap, minimum: Int = minimum) -> [Self] {
        let parser = ISO8601DateFormatter()
        return make(items: works.map { ($0.galleryId, parser.date(from: $0.bookmarkedAt)) }, gap: gap, minimum: minimum)
    }
}

/// Saved items by when they were saved: runs saved together, and months. A row jumps to its first
/// item; its select button picks all of them, to move or delete together.
struct SavedDateView<ItemID: Hashable>: View {
    @Environment(\.dismiss) private var dismiss
    let months: [SavedMonth<ItemID>]
    let runs: [SavedRun<ItemID>]
    let broughtIn: [Date]
    /// Starts each row's accessibility identifier, such as `works`.
    let identifier: String
    /// Images are named as such; works otherwise.
    var images = false
    let jump: (ItemID) -> Void
    let select: ([ItemID]) -> Void

    var body: some View {
        NavigationStack {
            List {
                if !runs.isEmpty {
                    Section {
                        ForEach(runs) { run in
                            row(title: run.start.formatted(.dateTime.locale(Locale(identifier: L10n.language)).year().month().day().hour().minute()),
                                subtitle: run.broughtIn(at: broughtIn) ? L10n.text("Brought in from website favorites") : nil,
                                count: run.ids.count, first: run.firstID, ids: run.ids,
                                identifier: "\(identifier).batch.\(Int(run.start.timeIntervalSince1970))")
                        }
                    } header: {
                        Text(L10n.text("Saved Together"))
                    } footer: {
                        Text(L10n.text(images ? "Images saved within a minute of each other, such as website favorites brought in or an import. Select them to move or delete them together." : "Works saved within a minute of each other, such as website favorites brought in or an import. Select them to move or delete them together."))
                    }
                }
                Section(L10n.text("By Month")) {
                    ForEach(months) { month in
                        row(title: month.title, subtitle: nil, count: month.count, first: month.firstID, ids: month.ids,
                            identifier: "\(identifier).month.\(month.id)")
                    }
                }
            }
            .navigationTitle(L10n.text("Browse by Saved Date")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }

    private func row(title: String, subtitle: String?, count: Int, first: ItemID, ids: [ItemID], identifier: String) -> some View {
        HStack(spacing: 12) {
            Button { jump(first) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).foregroundStyle(.primary)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(L10n.text("%@ items", String(describing: count))).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            Button { select(ids) } label: { Image(systemName: "checkmark.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text(images ? "Select These Images" : "Select These Works"))
                .accessibilityIdentifier(identifier + ".select")
        }
    }
}

/// One bounded, scrollable suggestion surface for both search modes.
extension View {
    func searchResultsPanel(height: CGFloat) -> some View {
        frame(height: height)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)))
            .padding(.horizontal, 16)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .accessibilityIdentifier("search.suggestions")
    }
}
