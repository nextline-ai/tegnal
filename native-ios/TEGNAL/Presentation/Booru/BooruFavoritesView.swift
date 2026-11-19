import SwiftUI

private struct BooruFavoritesSearch: Identifiable, Hashable {
    let query: String
    var id: String { query }
}

/// Saved in image mode, laid out as comics mode's: the chosen servers' folders and the global ones,
/// with a search of everything they hold. With several servers chosen, each folder names its server.
struct BooruFavoritesView: View {
    let source: any BooruProviding
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 390
    @Environment(BooruStore.self) private var store
    @State private var creating = false
    /// The server a new folder goes to; nil makes a global folder.
    @State private var newFolderServer: String?
    @State private var smartFolder: SmartFolderTarget?
    @State private var editing: BooruFolderEdit?
    @State private var deleting: BooruFolder?
    @State private var reordering = false
    @State private var renaming: BooruFolder?
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var folderMessage: String?
    @State private var searchText = ""
    @State private var searchResults: BooruFavoritesSearch?
    private var showsServerNames: Bool { store.selectedServerIDs.count > 1 }
    var body: some View {
        let geometry = ArtworkGridGeometry(width: width,
            columns: typeSize.isAccessibilitySize ? 1 : ArtworkGridGeometry.columns(chosen: env.folderColumns(for: .booru), width: width, minimum: sizeClass == .regular ? 240 : 160),
            minimum: sizeClass == .regular ? 240 : 160, removesPadding: env.removesGridPadding(for: .booru), maximumColumns: 12)
        ScrollView {
            // Without a server chosen there are no folders but global ones, as Explore shows nothing.
            if store.selectedServers.isEmpty && store.visibleFolders().isEmpty {
                BooruNoSelectionView().padding(.top, 60)
            } else {
            ArtworkGrid(mode: .booru, kind: .folders, surroundingPadding: 16) { _ in
                if env.recentImages.showsInSaved {
                    let recents = env.recentImages.entries.filter { env.booru.isShownInSafeMode($0.post) }
                    NavigationLink { RecentImagesView() } label: {
                        BooruFolderCard(title: L10n.text("Recent Images"), color: RecentFolderStyle.color, posts: Array(recents.prefix(4).map(\.post)), count: recents.count)
                            .contextMenu {
                                Button(L10n.text("Hide from Saved"), systemImage: "eye.slash") { env.recentImages.setShowsInSaved(false) }
                            }
                    }.buttonStyle(.plain).accessibilityIdentifier("booru.recentFolder")
                }
                ForEach(store.visibleFolders()) { folder in
                    NavigationLink { BooruFolderContentsView(source: source, folderID: folder.id) } label: {
                        let posts = store.visibleFavorites(folderID: folder.id)
                        BooruFolderCard(title: folder.plainName, isSmart: folder.isSmart, color: folder.color, posts: posts, count: posts.count,
                                        server: showsServerNames ? store.serverName(ofFolder: folder) : nil, isGlobal: folder.isGlobal)
                    }.buttonStyle(.plain).accessibilityIdentifier("booru.folder.\(folder.id)")
                        .contextMenu { menu(for: folder) }
                }
            }.padding(16)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.text("Search Favorites"))
        .autocorrectionDisabled().textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { searchResults = BooruFavoritesSearch(query: query) }
        }
        .navigationDestination(item: $searchResults) { BooruFolderContentsView(source: source, initialQuery: $0.query) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            AppToolbarActions {
                createButton
                BooruServerMenu(compact: true)
            }
        } }
        .transientMessage($folderMessage)
        .newFolderPrompt(isPresented: $creating, booru: true, booruServerID: newFolderServer, identifier: "booru.folderName") { _ in }
        .appSheet(item: $smartFolder) { FolderRuleEditor(booru: true, folder: $0.id) }
        .appSheet(isPresented: $reordering) { FolderOrderView(booru: true) }
        .appSheet(item: $editing) { item in
            if let folder = item.folder {
                let posts = store.visibleFavorites(folderID: folder.id)
                // Colors differ among the folders shown beside it: its server's and the global ones.
                let others = store.folders().filter { $0.id != folder.id && (folder.serverID == nil || $0.serverID == nil || $0.serverID == folder.serverID) }
                FolderColorSheet(title: folder.displayName, color: folder.color, others: others.map(\.color)) { color in
                    store.perform { try store.setFolderColor(folder.id, color: color) }
                } preview: { color in
                    BooruFolderCard(title: folder.plainName, isSmart: folder.isSmart, color: color, posts: posts, count: posts.count,
                                    server: showsServerNames ? store.serverName(ofFolder: folder) : nil, isGlobal: folder.isGlobal)
                }
            }
        }
        .background {
            FolderNameAlert(isPresented: $showRename, name: $renameDraft, identifier: "folder.rename", title: "Rename Folder", actionTitle: "Save") { value in
                if let folder = renaming { store.perform { try store.saveFolder(id: folder.id, name: value, color: folder.color) } }
            }
        }
        .confirmationDialog(L10n.text("Delete Folder?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete"), role: .destructive) { if let deleting { store.perform { try store.deleteFolder(deleting.id) } }; deleting = nil }
        } message: { Text(L10n.text("Favorites in this folder will move to Uncategorized.")) }
    }

    /// One server chosen, a new folder is that server's; with several, the menu asks which, or global.
    @ViewBuilder private var createButton: some View {
        let chosen = store.selectedServers
        if chosen.count > 1 {
            Menu {
                ForEach(chosen) { server in
                    Button(server.displayName, systemImage: "server.rack") { newFolderServer = server.id; creating = true }
                        .accessibilityIdentifier("booru.createFolder." + server.id)
                }
                Divider()
                Button(L10n.text("Global Folder"), systemImage: "globe") { newFolderServer = nil; creating = true }
                    .accessibilityIdentifier("booru.createFolder.global")
            } label: { Image(systemName: "folder.badge.plus").font(.system(size: 17, weight: .medium)) }
                .accessibilityLabel(L10n.text("Create Folder")).accessibilityIdentifier("booru.createFolder")
        } else {
            Button { newFolderServer = chosen.first?.id; creating = true } label: { Image(systemName: "folder.badge.plus").font(.system(size: 17, weight: .medium)) }
                .accessibilityLabel(L10n.text("Create Folder")).accessibilityIdentifier("booru.createFolder")
        }
    }

    @ViewBuilder private func menu(for folder: BooruFolder) -> some View {
        Button(L10n.text("Change Color"), systemImage: "paintpalette") { editing = .init(folder: folder) }
        Button(L10n.text("Reorder Folders"), systemImage: "arrow.up.arrow.down") { reordering = true }
        if !folder.isUncategorized {
            Button(L10n.text("Rename Folder"), systemImage: "pencil") { renaming = folder; renameDraft = folder.plainName; showRename = true }
        }
        // Uncategorized can be a smart folder like any other.
        Button(L10n.text("Smart Folder"), systemImage: "sparkles") { smartFolder = .init(id: folder.id) }
        // Each server keeps its own Uncategorized.
        if !folder.isUncategorized {
            Toggle(isOn: Binding(get: { folder.isGlobal }, set: { global in
                store.perform { try store.setGlobal(folder.id, global, emptyServer: store.selectedServerID.isEmpty ? nil : store.selectedServerID) }
            })) { Label(L10n.text("Global Folder"), systemImage: "globe") }
                .accessibilityIdentifier("booru.globalFolder")
            Button(L10n.text("Delete Folder"), systemImage: "trash", role: .destructive) {
                if env.booruAccounts.isListFolder(folder.id) {
                    folderMessage = L10n.text("This folder holds a favorite group of a website you're signed in to, so it stays while you're signed in. To delete it, sign out of that website or turn off Sync Favorites with Folders in its settings.")
                } else { deleting = folder }
            }
        }
    }
}

private struct BooruFolderCard: View {
    @Environment(\.artworkCellStyle) private var style
    let title: String
    var isSmart = false
    let color: Int64
    let posts: [BooruPost]
    let count: Int
    /// With several servers chosen, the server's name takes the count's place.
    var server: String? = nil
    var isGlobal = false
    @Environment(BooruStore.self) private var store
    /// Light colors such as yellow take dark text, as comics folders do.
    private var text: Color { FolderBentoFrame<EmptyView>.textColor(color) }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.aspectRatio(1.25, contentMode: .fit).overlay {
                VStack(spacing: style.inset(4)) {
                    ForEach(0..<2) { row in
                        HStack(spacing: style.inset(4)) {
                            ForEach(0..<2) { col in
                                let index = row * 2 + col
                                text.opacity(0.12).overlay {
                                    if posts.indices.contains(index), let server = store.servers.first(where: { $0.id == posts[index].serverID }) {
                                        BooruThumbnail(post: posts[index], server: server)
                                    } else { Image(systemName: "photo").font(.system(size: style.fontSize(20))).foregroundStyle(text.opacity(0.3)) }
                                }.clipped().clipShape(RoundedRectangle(cornerRadius: style.radius(8)))
                            }
                        }
                    }
                }.padding(style.inset(6))
            }.clipped()
            FolderCardCaption(title: title, isSmart: isSmart, count: count, color: text, detail: server, isGlobal: isGlobal)
        }.foregroundStyle(text).background(Color(argb: color))
            .clipShape(RoundedRectangle(cornerRadius: style.radius(16))).overlay(RoundedRectangle(cornerRadius: style.radius(16)).stroke(.white.opacity(0.15), lineWidth: style.removesPadding ? 0 : 0.5))
    }
}

struct BooruFolderContentsView: View {
    let source: any BooruProviding
    var folderID: String?
    /// Recently opened images, shown the way a folder shows its favorites.
    var recents = false
    /// Saved's search: every folder shown there, searched for this.
    var initialQuery = ""
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    @State private var query = ""
    @State private var queryLoaded = false
    @State private var selectedPost: BooruPost?
    @State private var viewerPosition: BooruPost?
    @State private var saveFeedback: WorkSaveFeedback?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmingDelete = false
    @State private var showJump = false
    @State private var pendingJump: String?
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @FocusState private var searchFocused: Bool
    private var posts: [BooruPost] {
        guard recents else { return store.visibleFavorites(folderID: folderID, query: query) }
        let servers = Set(store.servers.map(\.id))
        return env.recentImages.entries.map(\.post).filter { servers.contains($0.serverID) && BooruStore.matches($0, query: query) && store.isShownInSafeMode($0) }
    }
    var body: some View {
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                Group {
                    if recents && env.recentImages.entries.isEmpty {
                        ContentUnavailableView(L10n.text("No Recent Images"), systemImage: "clock", description: Text(L10n.text("Images you open in the viewer appear here."))).padding(.top, 48)
                    } else if recents && posts.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 48)
                    } else if posts.isEmpty {
                        ContentUnavailableView(L10n.text("No Favorites"), systemImage: "heart", description: Text(L10n.text("Hold an image to save it, or choose Save to Folder from its menu."))).padding(.top, 48)
                    } else { BooruPostGrid(posts: posts, selection: selecting ? $selection : nil, feedback: { saveFeedback = $0 }) { viewerPosition = $0; selectedPost = $0 } }
                }.padding(.top, 56)
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
            }
            ScrollSearchBar(text: $query, focused: $searchFocused, prompt: L10n.text(recents ? "Search tags" : "Search Favorites"), identifier: "booru.favoritesSearch")
                .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .onAppear { if !queryLoaded { queryLoaded = true; query = initialQuery } }
        .workSaveFeedback($saveFeedback, identifier: "booru.saveStatus")
        .navigationTitle(recents ? L10n.text("Recently Opened Images") : store.folders().first(where: { $0.id == folderID })?.displayName ?? L10n.text("All Favorites"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 2) {
                BooruServerMenu()
                if selecting {
                    Button { selection = Set(posts.map(\.id)) } label: { Image(systemName: "checkmark.circle.fill") }.accessibilityLabel(L10n.text("Select All"))
                    if !recents {
                        // Folders that may hold every image chosen: global ones, and one server's own when all are its.
                        let chosen = posts.filter { selection.contains($0.id) }
                        let servers = Set(chosen.map(\.serverID))
                        Menu {
                            ForEach(store.folders().filter { folder in servers.allSatisfy { folder.holds(serverID: $0) } }) { folder in
                                Button(folder.displayName) { store.perform { try store.moveFavorites(chosen, folderID: folder.id); selection.removeAll(); selecting = false } }
                            }
                        } label: { Image(systemName: "folder") }.disabled(selection.isEmpty).accessibilityLabel(L10n.text("Move to Another Folder"))
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }.disabled(selection.isEmpty).accessibilityLabel(L10n.text("Delete")).accessibilityIdentifier("booru.deleteSelected")
                } else {
                    Menu {
                        Button(L10n.text("Jump to Top"), systemImage: "arrow.up.to.line") { if let first = posts.first { proxy.scrollTo(first.id, anchor: .top) } }
                        Button(L10n.text("Jump to Bottom"), systemImage: "arrow.down.to.line") { if let last = posts.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                        if !recents { Button(L10n.text("Browse by Saved Date"), systemImage: "calendar") { showJump = true } }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.disabled(posts.isEmpty).accessibilityLabel(L10n.text("Quick Jump"))
                }
                Button { selecting.toggle(); selection.removeAll() } label: { Image(systemName: selecting ? "xmark" : "checkmark.circle") }
                    .accessibilityLabel(L10n.text(selecting ? "Done" : "Select")).accessibilityIdentifier("booru.select")
            }
        } }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            if recents {
                Button(L10n.text("Delete"), role: .destructive) {
                    for id in selection { env.recentImages.remove(id) }
                    selection.removeAll(); selecting = false
                }
            } else if env.booruAccounts.syncsAny(chosenPosts) {
                Button(L10n.text("Delete Here and on Website"), role: .destructive) { deleteChosen(keepOnServer: false) }
                    .accessibilityIdentifier("booru.delete.everywhere")
                Button(L10n.text("Delete in App Only"), role: .destructive) { deleteChosen(keepOnServer: true) }
                    .accessibilityIdentifier("booru.delete.appOnly")
            } else {
                Button(L10n.text("Delete"), role: .destructive) { deleteChosen(keepOnServer: false) }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            if recents { Text(L10n.text("They leave Recently Opened Images. Favorites stay saved.")) }
            else { Text(deleteMessage) }
        }
        .appSheet(isPresented: $showJump, onDismiss: { if let pendingJump { proxy.scrollTo(pendingJump, anchor: .top); self.pendingJump = nil } }) {
            savedDateSheet
        }
        .appFullScreenCover(item: $selectedPost) { post in
            if let server = store.servers.first(where: { $0.id == post.serverID }) { BooruPostView(post: viewerPosition ?? post, posts: posts, server: server, source: source, positionChanged: { viewerPosition = $0 }, willClose: { viewed in
                BooruViewerReturn.restore(openedID: selectedPost?.id, viewedID: viewed.id, availableIDs: posts.lazy.map(\.id), using: proxy)
            }) }
        }
        }
    }
    private var chosenPosts: [BooruPost] { posts.filter { selection.contains($0.id) } }

    private var deleteMessage: String {
        let count = L10n.text("%@ images will be deleted.", selection.count.formatted())
        guard env.booruAccounts.syncsAny(chosenPosts) else { return count }
        return count + "\n" + L10n.text("Some of them are favorites on a website synced with your folders.")
    }

    private func deleteChosen(keepOnServer: Bool) {
        let chosen = chosenPosts
        store.perform { try env.booruAccounts.removeFavorites(chosen, keepOnServer: keepOnServer) }
        selection.removeAll(); selecting = false
    }

    /// Favorites by when they were saved: runs saved together, and months.
    private var savedDateSheet: some View {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
        let dates = store.favoriteSavedDates()
        let shown = posts.map { (id: $0.id, date: dates[$0.id]) }
        let setUp = env.booruAccounts.setUpTimes
        let servers = Set(posts.map(\.serverID))
        return SavedDateView(months: SavedMonth.make(items: shown.map { ($0.id, $0.date.map(formatter.string(from:)) ?? "") }),
                             runs: SavedRun.make(items: shown), broughtIn: servers.compactMap { setUp[$0] }, identifier: "booru", images: true, jump: { id in
            pendingJump = id; showJump = false
        }, select: { ids in
            selection = Set(ids); selecting = true
            pendingJump = posts.first { selection.contains($0.id) }?.id
            showJump = false
        })
    }
}

private struct BooruFolderEdit: Identifiable {
    let id = UUID()
    var folder: BooruFolder?
}

struct BooruFolderPicker: View {
    @Environment(\.discoveryContext) private var discovery
    let post: BooruPost
    /// Names the chosen folder, so the notice that offered the change can say where it went.
    var filed: ((String) -> Void)? = nil
    @Environment(BooruStore.self) private var store
    var body: some View {
        // The image's own server's folders and the global ones; a folder made here is its server's.
        let current = store.folderID(for: post)
        FolderPickerSheet(rows: store.folders(forServer: post.serverID).map {
            FolderPickerRow(id: $0.id, name: $0.displayName, color: $0.color, isCurrent: $0.id == current, isGlobal: $0.isGlobal)
        }, identifier: "booru.pickFolder", pick: { row in
            file(in: row.id, name: row.name)
        }, create: { id in
            file(in: id, name: store.folders().first { $0.id == id }?.displayName ?? "")
        }, booru: true, booruServerID: post.serverID)
    }
    private func file(in id: String, name: String) {
        store.perform {
            try store.saveFavorite(post, folderID: id, context: discovery)
            filed?(name)
        }
    }
}

