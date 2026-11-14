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
    @State private var newFolderName = ""
    @State private var toastMessage: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @State private var showJumpSheet = false
    @State private var pendingJump: Int64?
    @State private var composingFolder = false
    /// A work saved from another website that numbers its works differently.
    @State private var siteChoice: Work?
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
                                            if let id = work.id { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
                                        } else { open(work) }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { Image(systemName: work.id.map(selection.contains) == true ? "checkmark.circle.fill" : "circle").font(.system(size: style.fontSize(22, minimum: 12))).foregroundStyle(.white, .blue).padding(style.inset(10)).allowsHitTesting(false) }
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
                            Button(L10n.text("Select All")) { selection = Set(works.compactMap(\.id)) }
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
                        Button(L10n.text("Jump to Saved Month"), systemImage: "calendar") { isSearchFocused = false; showJumpSheet = true }
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
        .alert(L10n.text("Saved from %@", siteChoice?.site ?? ""), isPresented: Binding(get: { siteChoice != nil }, set: { if !$0 { siteChoice = nil } }), presenting: siteChoice) { work in
            Button(L10n.text("Switch and Open")) {
                if let site = work.site { env.switchComicsSite(to: site) }
                openManga(for: work.galleryId)
            }
            Button(L10n.text("Open Here")) { openManga(for: work.galleryId) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { work in
            Text(L10n.text("This work was saved from %@, which numbers its works differently from %@. Switch websites to open the same work.", work.site ?? "", env.mangaSiteAddress))
        }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            Button(L10n.text("Delete"), role: .destructive) {
                do { try env.database.deleteSelectedWorks(selection); selection.removeAll(); selecting = false; loadWorks() }
                catch { showToast(error.localizedDescription) }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .appSheet(isPresented: $showJumpSheet, onDismiss: {
            if let id = pendingJump { proxy.scrollTo(id, anchor: .top); pendingJump = nil }
        }) {
            WorkMonthJumpView(months: WorkMonthDestination.make(works)) { id in
                pendingJump = id; showJumpSheet = false
            }
        }
        .appSheet(isPresented: $showAddSheet, onDismiss: { loadWorks() }) {
            AddWorkSheet()
        }
        .appSheet(isPresented: $composingFolder) { FolderRuleEditor(tag: searchText, smart: false) }
        .alert(L10n.text("Delete Work"), isPresented: Binding(
            get: { workPendingDelete != nil },
            set: { if !$0 { workPendingDelete = nil } }
        )) {
            Button(L10n.text("Delete"), role: .destructive) {
                if let work = workPendingDelete {
                    deleteWork(work)
                    workPendingDelete = nil
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {
                workPendingDelete = nil
            }
        } message: {
            if let work = workPendingDelete {
                Text(L10n.text("Delete this work (number: %@)?", String(describing: String(work.galleryId))))
            }
        }
        .alert(L10n.text("Create Folder and Move"), isPresented: $showNewFolderAlert) {
            TextField(L10n.text("New Folder Name"), text: $newFolderName)
            Button(L10n.text("Cancel"), role: .cancel) {
                newFolderName = ""
                workPendingMoveToNewFolder = nil
            }
            Button(L10n.text("Create and Move")) {
                if let work = workPendingMoveToNewFolder {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, let newFolder = try? env.database.createFolder(name: trimmed) {
                        moveWork(work, to: newFolder)
                    }
                }
                newFolderName = ""
                workPendingMoveToNewFolder = nil
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    /// A work from another connected website whose numbers mean other works opens there.
    private func open(_ work: Work) {
        if let site = work.site, site != env.mangaSiteAddress, env.comicSites.contains(site), !ComicSites.sharesNumbers(site, env.mangaSiteAddress) {
            siteChoice = work
        } else { openManga(for: work.galleryId) }
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
                site: work.site,
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

    private func deleteWork(_ work: Work) {
        try? env.database.deleteWork(galleryId: work.galleryId, site: work.site)
        loadWorks()
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
                newFolderName = ""
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

struct WorkMonthDestination: Identifiable {
    let id: String
    let firstGalleryID: Int64
    var count: Int
    var title: String {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return L10n.text("No Date") }
        return L10n.text("%@-%@", String(describing: parts[0]), String(describing: month))
    }
    static func make(_ works: [Work]) -> [Self] {
        var destinations: [Self] = []
        var positions: [String: Int] = [:]
        for work in works {
            let month = String(work.bookmarkedAt.prefix(7))
            if let index = positions[month] { destinations[index].count += 1 }
            else {
                positions[month] = destinations.count
                destinations.append(Self(id: month, firstGalleryID: work.galleryId, count: 1))
            }
        }
        return destinations
    }
}

private struct WorkMonthJumpView: View {
    @Environment(\.dismiss) private var dismiss
    let months: [WorkMonthDestination]
    let select: (Int64) -> Void
    var body: some View {
        NavigationStack {
            List(months) { month in
                Button { select(month.firstGalleryID) } label: {
                    HStack {
                        Text(month.title).foregroundStyle(.primary)
                        Spacer()
                        Text(L10n.text("%@ items", String(describing: month.count))).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("works.month.\(month.id)")
            }
            .navigationTitle(L10n.text("Jump to Saved Month")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
        }.presentationDetents([.medium, .large])
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
