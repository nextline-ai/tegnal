import SwiftUI
import UIKit

/// How many recently opened works or images a list keeps: none, or up to 500 in steps of ten,
/// 50 unless changed.
enum RecentLimit {
    static let standard = 50
    static let maximum = 500
    static let step = 10
    static func stored(_ key: String, in defaults: UserDefaults) -> Int {
        let value = defaults.object(forKey: key) as? Int ?? standard
        return min(max(0, value), maximum)
    }
    static func clamped(_ value: Int) -> Int { min(max(0, (value / step) * step), maximum) }
}

/// A work opened in the viewer lately, kept with what the list shows and what Saved search
/// looks through, so the list never has to load it.
struct RecentWork: Codable, Equatable, Identifiable, Sendable {
    var item: ReadingQueueItem
    var openedAt: Date
    var language: String?
    var type: String?
    var tags: [String]?
    var id: Int64 { item.id }

    /// Saved search applies to recent works the same way.
    func matches(_ query: WorkQuery) -> Bool {
        query.matches(.init(galleryID: id, title: item.title, artists: item.artists, language: language ?? "", type: type ?? "",
                            tags: (tags ?? []).joined(separator: ", ")))
    }
}

extension RecentWork {
    /// The list as stored, for iCloud sync and backups, which read it without the app's list.
    static func stored(in defaults: UserDefaults) -> [RecentWork] {
        defaults.data(forKey: RecentWorks.key).flatMap { try? JSONDecoder().decode([RecentWork].self, from: $0) } ?? []
    }
    /// Newest first, one entry per work and the newest copy of each, at most `limit`.
    static func merged(_ entries: [RecentWork], limit: Int) -> [RecentWork] {
        var newest: [Int64: RecentWork] = [:]
        for entry in entries where newest[entry.id].map({ entry.openedAt > $0.openedAt }) ?? true { newest[entry.id] = entry }
        return Array(newest.values.sorted { $0.openedAt == $1.openedAt ? $0.id > $1.id : $0.openedAt > $1.openedAt }.prefix(max(0, limit)))
    }
}

/// `RecentWorks`: comics opened in the viewer, newest first. Opening a work again moves it to
/// the top; the oldest leave once the list passes the count chosen in Settings. The list travels
/// with iCloud sync and backups; covers stay on this device.
@MainActor @Observable final class RecentWorks {
    nonisolated static let key = "manga.recentWorks"
    nonisolated static let limitKey = "manga.recentWorks.limit"
    /// Saved shows the list as a folder; off unless chosen. A layout choice, kept on this device.
    nonisolated static let savedFolderKey = "manga.recentWorks.showsInSaved"

    private(set) var entries: [RecentWork] = []
    /// How many works the list keeps; none turns it off.
    private(set) var limit: Int
    private(set) var showsInSaved: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let covers: URL

    init(defaults: UserDefaults, covers: URL? = nil) {
        self.defaults = defaults
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        showsInSaved = defaults.bool(forKey: Self.savedFolderKey)
        self.covers = covers ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RecentWorks", isDirectory: true)
        entries = RecentWork.stored(in: defaults)
        trim()
    }

    func setShowsInSaved(_ value: Bool) {
        showsInSaved = value
        defaults.set(value, forKey: Self.savedFolderKey)
    }

    /// Reads the list again after iCloud sync changed it underneath.
    func reload() {
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        let stored = RecentWork.stored(in: defaults)
        if stored != entries { entries = stored }
        trim()
    }

    /// Works from a backup join the list by when they were opened; the newer copy of a work wins.
    func merge(_ incoming: [RecentWork]) {
        guard !incoming.isEmpty else { return }
        entries = RecentWork.merged(entries + incoming, limit: Int.max)
        trim()
        save()
    }

    /// A lower count drops the oldest works at once; none clears the list.
    func setLimit(_ value: Int) {
        limit = RecentLimit.clamped(value)
        defaults.set(limit, forKey: Self.limitKey)
        trim()
        save()
    }

    func opened(_ gallery: NativeGallery, site: String?, at date: Date = Date()) {
        let item = ReadingQueueItem(gallery: gallery, id: gallery.id, title: nil, artists: nil, language: nil, type: nil, site: site)
        opened(RecentWork(item: item, openedAt: date, language: gallery.language, type: gallery.type, tags: gallery.tags))
    }
    func opened(_ work: RecentWork) {
        guard limit > 0 else { return }
        entries.removeAll { $0.id == work.id }
        entries.insert(work, at: 0)
        trim()
        save()
    }
    func remove(_ id: Int64) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: coverURL(id))
        save()
    }
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: covers)
        save()
    }

    // MARK: Covers

    func cover(_ id: Int64) -> UIImage? { UIImage(contentsOfFile: coverURL(id).path) }
    func hasCover(_ id: Int64) -> Bool { FileManager.default.fileExists(atPath: coverURL(id).path) }
    func storeCover(_ image: UIImage, for id: Int64) {
        guard entries.contains(where: { $0.id == id }) else { return }
        let scale = min(1, 360 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = small.jpegData(compressionQuality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        try? data.write(to: coverURL(id), options: .atomic)
    }
    private func coverURL(_ id: Int64) -> URL { covers.appendingPathComponent("\(id).jpg") }

    private func trim() {
        guard entries.count > limit else { return }
        for entry in entries[limit...] { try? FileManager.default.removeItem(at: coverURL(entry.id)) }
        entries.removeLast(entries.count - limit)
    }
    private func save() {
        if entries.isEmpty { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

/// An image opened in the viewer lately.
struct RecentImage: Codable, Equatable, Identifiable, Sendable {
    var post: BooruPost
    var openedAt: Date
    var id: String { post.id }
}

extension RecentImage {
    static func stored(in defaults: UserDefaults) -> [RecentImage] {
        defaults.data(forKey: RecentImages.key).flatMap { try? JSONDecoder().decode([RecentImage].self, from: $0) } ?? []
    }
    /// Newest first, one entry per image and the newest copy of each, at most `limit`.
    static func merged(_ entries: [RecentImage], limit: Int) -> [RecentImage] {
        var newest: [String: RecentImage] = [:]
        for entry in entries where newest[entry.id].map({ entry.openedAt > $0.openedAt }) ?? true { newest[entry.id] = entry }
        return Array(newest.values.sorted { $0.openedAt == $1.openedAt ? $0.id > $1.id : $0.openedAt > $1.openedAt }.prefix(max(0, limit)))
    }
}

/// `RecentImages`: image mode's recently opened images, kept like comics' recent works, in
/// image mode's own settings.
@MainActor @Observable final class RecentImages {
    nonisolated static let key = "booru.recentPosts"
    nonisolated static let limitKey = "booru.recentPosts.limit"
    nonisolated static let savedFolderKey = "booru.recentPosts.showsInSaved"

    private(set) var entries: [RecentImage] = []
    private(set) var limit: Int
    private(set) var showsInSaved: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        showsInSaved = defaults.bool(forKey: Self.savedFolderKey)
        entries = RecentImage.stored(in: defaults)
        trim()
    }

    func setShowsInSaved(_ value: Bool) {
        showsInSaved = value
        defaults.set(value, forKey: Self.savedFolderKey)
    }

    func reload() {
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        let stored = RecentImage.stored(in: defaults)
        if stored != entries { entries = stored }
        trim()
    }

    func merge(_ incoming: [RecentImage]) {
        guard !incoming.isEmpty else { return }
        entries = RecentImage.merged(entries + incoming, limit: Int.max)
        trim()
        save()
    }

    func setLimit(_ value: Int) {
        limit = RecentLimit.clamped(value)
        defaults.set(limit, forKey: Self.limitKey)
        trim()
        save()
    }
    func opened(_ post: BooruPost, at date: Date = Date()) {
        guard limit > 0 else { return }
        entries.removeAll { $0.id == post.id }
        entries.insert(RecentImage(post: post, openedAt: date), at: 0)
        trim()
        save()
    }
    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }
    func clear() {
        entries.removeAll()
        save()
    }

    private func trim() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
    private func save() {
        if entries.isEmpty { defaults.removeObject(forKey: Self.key) }
        else if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: Settings

/// The rows Search History settings gain: the list of recently opened works or images, whether
/// Saved shows it as a folder, and a slider for how many to keep.
struct RecentWorksSettings: View {
    @Environment(AppEnvironment.self) private var env
    let booru: Bool
    @State private var limit: Double = Double(RecentLimit.standard)

    var body: some View {
        NavigationLink {
            if booru { RecentImagesView() } else { RecentWorksView() }
        } label: {
            LabeledContent(L10n.text(booru ? "Recently Opened Images" : "Recently Opened Works"), value: String(booru ? env.recentImages.entries.count : env.recentWorks.entries.count))
        }.accessibilityIdentifier("settings.recentWorks")
        Toggle(L10n.text("Show as Folder in Saved"), isOn: Binding(
            get: { booru ? env.recentImages.showsInSaved : env.recentWorks.showsInSaved },
            set: { if booru { env.recentImages.setShowsInSaved($0) } else { env.recentWorks.setShowsInSaved($0) } }))
            .accessibilityIdentifier("settings.recentWorksInSaved")
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(booru ? "Keep Recent Images" : "Keep Recent Works"))
                Spacer()
                Text(Self.title(Int(limit), booru: booru)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $limit, in: 0...Double(RecentLimit.maximum), step: Double(RecentLimit.step)) { editing in
                guard !editing else { return }
                if booru { env.recentImages.setLimit(Int(limit)) } else { env.recentWorks.setLimit(Int(limit)) }
            }
            .accessibilityLabel(L10n.text(booru ? "Keep Recent Images" : "Keep Recent Works"))
            .accessibilityValue(Self.title(Int(limit), booru: booru))
            .accessibilityIdentifier("settings.recentWorksLimit")
        }
        .onAppear { limit = Double(booru ? env.recentImages.limit : env.recentWorks.limit) }
    }

    static func title(_ count: Int, booru: Bool) -> String {
        count == 0 ? L10n.text("Don't Keep") : L10n.text(booru ? "%@ items" : "%@ works", String(count))
    }
}

// MARK: Saved folder

/// The neutral color the recent folder wears in Saved; it is not a folder the user colors.
enum RecentFolderStyle { static let color: Int64 = 0xFF636366 }

/// Recently opened works as a folder card in Saved, with the latest covers.
struct RecentWorksFolderCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.artworkCellStyle) private var style
    var body: some View {
        let recents = env.recentWorks
        let entries = Array(recents.entries.prefix(4))
        let text = FolderBentoFrame<EmptyView>.textColor(RecentFolderStyle.color)
        FolderBentoFrame(color: RecentFolderStyle.color, title: L10n.text("Recent Works"), count: recents.entries.count) { index in
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay {
                if entries.indices.contains(index) {
                    if let cover = recents.cover(entries[index].id) { Image(uiImage: cover).resizable().scaledToFill() }
                    else { FolderBentoPlaceholder(galleryID: entries[index].id, color: text) }
                } else {
                    RoundedRectangle(cornerRadius: style.radius(8), style: .continuous).fill(text.opacity(0.08))
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: style.radius(8), style: .continuous))
        }
    }
}

// MARK: Lists

/// Recently opened works, newest first, laid out as a Saved folder is: the search bar, the same
/// cards, Select and Quick Jump. A tap opens the work again.
struct RecentWorksView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var opened: RecentWork?
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<Int64>()
    @State private var confirmingDelete = false
    @State private var saved: [Int64: Work] = [:]
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @FocusState private var isSearchFocused: Bool
    @SwiftUI.AppStorage(MangaThumbnailOpening.preferenceKey, store: ReaderPreferences.defaults) private var showsInformationBeforeReading = false

    private var shown: [RecentWork] {
        let search = WorkQuery(query)
        return search.isEmpty ? env.recentWorks.entries : env.recentWorks.entries.filter { $0.matches(search) }
    }

    var body: some View {
        let recents = env.recentWorks
        let shown = shown
        ScrollViewReader { proxy in
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 56).id("recentWorks.top")
                    if recents.entries.isEmpty {
                        ContentUnavailableView(L10n.text("No Recent Works"), systemImage: "clock", description: Text(L10n.text("Works you open in the viewer appear here."))).padding(.top, 40)
                    } else if shown.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    } else {
                        ArtworkGrid(mode: .manga) { style in
                            ForEach(shown) { entry in
                                RecentWorkCard(entry: entry, saved: saved[entry.id], cover: recents.cover(entry.id))
                                    .id(entry.id)
                                    .accessibilityIdentifier("recentWorks.\(entry.id)")
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if selecting {
                                            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
                                        } else { opened = entry }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if selecting { Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle").font(.system(size: style.fontSize(22, minimum: 12))).foregroundStyle(.white, .blue).padding(style.inset(10)).allowsHitTesting(false) }
                                    }
                                    .contextMenu {
                                        Button(L10n.text("Remove"), systemImage: "trash", role: .destructive) { recents.remove(entry.id) }
                                    }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: isSearchFocused) { isSearchBarVisible = visible }
            }
            ScrollSearchBar(text: $query, focused: $isSearchFocused, prompt: L10n.text("Search works"), identifier: "recentWorks.search")
                .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: isSearchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward").font(.system(size: 14, weight: .bold))
                        Text(L10n.text("Recently Opened Works")).font(.system(size: 15, weight: .bold))
                    }
                    .foregroundColor(.primary).padding(.horizontal, 10).padding(.vertical, 5).fixedSize()
                }.buttonStyle(.plain).accessibilityIdentifier("recentWorks.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                AppToolbarActions {
                    Button { selecting.toggle(); selection.removeAll() } label: { Image(systemName: selecting ? "xmark" : "checkmark.circle") }
                        .frame(height: 32).disabled(recents.entries.isEmpty).accessibilityLabel(L10n.text(selecting ? "Done" : "Select")).accessibilityIdentifier("recentWorks.select")
                    if selecting {
                        Button { selection = Set(shown.map(\.id)) } label: { Image(systemName: "checkmark.circle.fill") }
                            .frame(height: 32).accessibilityLabel(L10n.text("Select All")).accessibilityIdentifier("recentWorks.selectAll")
                        Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                            .frame(height: 32).disabled(selection.isEmpty).accessibilityLabel(L10n.text("Delete")).accessibilityIdentifier("recentWorks.delete")
                    } else {
                        Menu {
                            Button(L10n.text("Jump to Top"), systemImage: "arrow.up.to.line") { isSearchFocused = false; proxy.scrollTo("recentWorks.top", anchor: .top) }
                            Button(L10n.text("Jump to Bottom"), systemImage: "arrow.down.to.line") {
                                isSearchFocused = false
                                if let id = shown.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        } label: { Image(systemName: "arrow.up.arrow.down") }
                        .frame(height: 32).disabled(shown.isEmpty).accessibilityLabel(L10n.text("Quick Jump"))
                    }
                }
            }
        }
        .alert(L10n.text("Delete Selected Items?"), isPresented: $confirmingDelete) {
            Button(L10n.text("Delete"), role: .destructive) {
                for id in selection { recents.remove(id) }
                selection.removeAll(); selecting = false
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("They leave Recently Opened Works. Saved works stay saved.")) }
        .appSheet(item: Binding(get: { showsInformationBeforeReading ? opened : nil }, set: { opened = $0 })) { entry in
            ContentEntryView(initialUrl: MangaThumbnailOpening.information.url(for: entry.id), siblingIDs: shown.map(\.id))
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .appFullScreenCover(item: Binding(get: { showsInformationBeforeReading ? nil : opened }, set: { opened = $0 })) { entry in
            ContentEntryView(initialUrl: MangaThumbnailOpening.viewer.url(for: entry.id), siblingIDs: shown.map(\.id))
        }
        .background {
            #if os(iOS)
            NavigationPopGestureEnabler().frame(width: 0, height: 0)
            #endif
        }
        .task(id: recents.entries.map(\.id)) { loadSaved(recents.entries.map(\.id)) }
        }
    }

    /// Saved works show their library cover, as they do in their folder.
    private func loadSaved(_ ids: [Int64]) {
        guard !ids.isEmpty else { saved = [:]; return }
        let works = (try? env.database.dbWriter.read { db in try Work.filter(ids.contains(Work.Columns.galleryId)).fetchAll(db) }) ?? []
        saved = Dictionary(works.map { ($0.galleryId, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// A recently opened work drawn as a folder's work card.
private struct RecentWorkCard: View {
    @Environment(\.artworkCellStyle) private var style
    let entry: RecentWork
    let saved: Work?
    let cover: UIImage?
    var body: some View {
        GalleryCardLayout(title: entry.item.title.isEmpty ? String(entry.id) : entry.item.title, artists: entry.item.artists,
                          language: entry.language ?? "", type: entry.type ?? "") {
            if let saved, saved.thumbStatus == "ready" {
                LocalThumbnailView(path: saved.thumbPath, revision: String(saved.thumbPage ?? 1)) { image in
                    if let image { Image(uiImage: image).resizable().scaledToFill() } else { placeholder }
                }
            } else if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
            } else { placeholder }
        }
    }
    private var placeholder: some View {
        Rectangle().fill(Color.secondary.opacity(0.12)).overlay {
            VStack(spacing: style.inset(6)) {
                Image(systemName: "photo").font(.system(size: style.fontSize(22)))
                if style.showsTitle { Text(String(entry.id)).font(.system(size: style.fontSize(11))) }
            }.foregroundStyle(.secondary)
        }
    }
}

/// Recently opened images, newest first, laid out as a Saved folder is; a tap opens the image again.
struct RecentImagesView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        BooruFolderContentsView(source: TasteSources.booru, recents: true).environment(env.booru)
    }
}
