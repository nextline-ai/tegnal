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

/// `RecentWorks`: comics opened in the viewer, newest first. Opening a work again moves it to
/// the top; the oldest leave once the list passes the count chosen in Settings. Kept on this
/// device only.
@MainActor @Observable final class RecentWorks {
    static let key = "manga.recentWorks"
    static let limitKey = "manga.recentWorks.limit"

    private(set) var entries: [RecentWork] = []
    /// How many works the list keeps; none turns it off.
    private(set) var limit: Int
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let covers: URL

    init(defaults: UserDefaults, covers: URL? = nil) {
        self.defaults = defaults
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        self.covers = covers ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RecentWorks", isDirectory: true)
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([RecentWork].self, from: data) { entries = stored }
        trim()
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
        let scale = min(1, 180 / max(image.size.width, image.size.height, 1))
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

/// `RecentImages`: image mode's recently opened images, kept like comics' recent works, in
/// image mode's own settings.
@MainActor @Observable final class RecentImages {
    static let key = "booru.recentPosts"
    static let limitKey = "booru.recentPosts.limit"

    private(set) var entries: [RecentImage] = []
    private(set) var limit: Int
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        limit = RecentLimit.stored(Self.limitKey, in: defaults)
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([RecentImage].self, from: data) { entries = stored }
        trim()
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

/// The rows Search History settings gain: the list of recently opened works or images, and a
/// slider for how many to keep.
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

// MARK: Lists

/// Recently opened works, newest first, searched as Saved is; a tap opens the work again.
struct RecentWorksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var opened: RecentWork?
    @State private var confirmingClear = false
    @State private var query = ""
    @SwiftUI.AppStorage(MangaThumbnailOpening.preferenceKey, store: ReaderPreferences.defaults) private var showsInformationBeforeReading = false

    private var shown: [RecentWork] {
        let search = WorkQuery(query)
        return search.isEmpty ? env.recentWorks.entries : env.recentWorks.entries.filter { $0.matches(search) }
    }

    var body: some View {
        let recents = env.recentWorks
        let shown = shown
        List {
            ForEach(shown) { entry in
                Button { opened = entry } label: { RecentWorkRow(entry: entry, cover: recents.cover(entry.id)) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recentWorks.\(entry.id)")
            }
            .onDelete { offsets in for index in offsets { recents.remove(shown[index].id) } }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.text("Search works"))
        .overlay {
            if recents.entries.isEmpty {
                ContentUnavailableView(L10n.text("No Recent Works"), systemImage: "clock", description: Text(L10n.text("Works you open in the viewer appear here.")))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(L10n.text("Recently Opened Works")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("Clear All"), role: .destructive) { confirmingClear = true }
                    .disabled(recents.entries.isEmpty)
                    .accessibilityIdentifier("recentWorks.clear")
            }
        }
        .confirmationDialog(L10n.text("Clear recently opened works?"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(L10n.text("Clear All"), role: .destructive) { recents.clear() }
        }
        .appSheet(item: Binding(get: { showsInformationBeforeReading ? opened : nil }, set: { opened = $0 })) { entry in
            ContentEntryView(initialUrl: MangaThumbnailOpening.information.url(for: entry.id), siblingIDs: [entry.id])
                .presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .appFullScreenCover(item: Binding(get: { showsInformationBeforeReading ? nil : opened }, set: { opened = $0 })) { entry in
            ContentEntryView(initialUrl: MangaThumbnailOpening.viewer.url(for: entry.id), siblingIDs: [entry.id])
        }
    }
}

private struct RecentWorkRow: View {
    let entry: RecentWork
    let cover: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover { Image(uiImage: cover).resizable().scaledToFill() }
                else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: AppMode.manga.icon).foregroundStyle(.secondary) } }
            }
            .frame(width: 48, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.item.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !entry.item.artists.isEmpty || !entry.item.details.isEmpty {
                    Text([entry.item.artists, entry.item.details].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(entry.openedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// Recently opened images, newest first, searched as favorites are; a tap opens the image again.
struct RecentImagesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var opened: RecentImage?
    @State private var confirmingClear = false
    @State private var query = ""

    private var shown: [RecentImage] {
        env.recentImages.entries.filter { BooruStore.matches($0.post, query: query) && env.booru.isShownInSafeMode($0.post) }
    }

    var body: some View {
        let recents = env.recentImages
        let shown = shown
        let servers = Dictionary(uniqueKeysWithValues: env.booru.servers.map { ($0.id, $0) })
        List {
            ForEach(shown) { entry in
                Button { opened = entry } label: { RecentImageRow(entry: entry, server: servers[entry.post.serverID]) }
                    .buttonStyle(.plain)
                    .disabled(servers[entry.post.serverID] == nil)
                    .accessibilityIdentifier("recentImages.\(entry.post.postID)")
            }
            .onDelete { offsets in for index in offsets { recents.remove(shown[index].id) } }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.text("Search tags"))
        .overlay {
            if recents.entries.isEmpty {
                ContentUnavailableView(L10n.text("No Recent Images"), systemImage: "clock", description: Text(L10n.text("Images you open in the viewer appear here.")))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(L10n.text("Recently Opened Images")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("Clear All"), role: .destructive) { confirmingClear = true }
                    .disabled(recents.entries.isEmpty)
                    .accessibilityIdentifier("recentImages.clear")
            }
        }
        .confirmationDialog(L10n.text("Clear recently opened images?"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(L10n.text("Clear All"), role: .destructive) { recents.clear() }
        }
        .appFullScreenCover(item: $opened) { entry in
            if let server = servers[entry.post.serverID] {
                BooruPostView(post: entry.post, posts: shown.map(\.post).filter { servers[$0.serverID] != nil }, server: server, source: TasteSources.booru)
                    .environment(env.booru)
            }
        }
    }
}

private struct RecentImageRow: View {
    let entry: RecentImage
    let server: BooruServer?
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let server { BooruThumbnail(post: entry.post, server: server) }
                else { Rectangle().fill(Color.secondary.opacity(0.12)).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } }
            }
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(server?.displayName ?? entry.post.serverID) · \(entry.post.postID)").font(.subheadline.weight(.semibold)).lineLimit(1)
                if !entry.post.tags.isEmpty {
                    Text(entry.post.tags.prefix(8).joined(separator: " ").replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(entry.openedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
