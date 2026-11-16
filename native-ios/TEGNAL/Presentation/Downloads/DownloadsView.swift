import SwiftUI
import QuickLook
import AVFoundation

struct DownloadsView: View {
    let mode: WorkDownload.Mode
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    @Environment(AppEnvironment.self) private var env
    @State private var store = DownloadStore.shared
    @State private var deleting: WorkDownload?
    @State private var query = ""
    @State private var isSearchBarVisible = true
    @State private var searchScroll = ScrollSearchVisibility()
    @FocusState private var searchFocused: Bool
    private var items: [WorkDownload] { store.items.filter { $0.mode == mode } }
    private var results: [WorkDownload] { items.filter { $0.matches(query) } }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.text("%@ items", String(results.count)))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12)
                    if let error = store.storageError { Text(error).foregroundStyle(.red).padding(.horizontal, 16) }
                    let movable = store.movable.filter { $0.mode == mode }
                    if !movable.isEmpty {
                        NavigationLink { DownloadSettingsView(store: store) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.questionmark").font(.title3).foregroundStyle(.tint)
                                Text(movable.contains { $0.location == nil }
                                     ? L10n.text("%@ downloads are in the app's own storage, where the Files app can't open them.", String(movable.count))
                                     : L10n.text("%@ downloads are saved in another folder.", String(movable.count)))
                                    .font(.subheadline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(L10n.text("Move")).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                            }
                            .padding(14)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16).padding(.top, 10)
                        .accessibilityIdentifier("downloads.moveHint")
                    }
                    if results.isEmpty {
                        ContentUnavailableView(L10n.text(items.isEmpty ? "No Downloads" : "No Works"),
                            systemImage: items.isEmpty ? "arrow.down.circle" : "magnifyingglass",
                            description: Text(items.isEmpty ? L10n.text("Download a work from the viewer quick menu.") : L10n.text("No results for '%@'", query)))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ArtworkGrid(mode: mode == .manga ? .manga : .booru) { style in
                            ForEach(results) { item in
                                VStack(alignment: .leading, spacing: style.inset(6)) {
                                    if item.status == .completed {
                                        NavigationLink { DownloadFilesView(item: item, store: store) } label: { card(item, style: style) }
                                            .buttonStyle(.plain).accessibilityIdentifier("download.open")
                                    } else { card(item, style: style) }
                                    downloadStatus(item, style: style)
                                }.contextMenu { actions(item) }
                            }
                        }
                    }
                }.padding(.top, 56)
            }
            .scrollDismissesKeyboard(.interactively)
            .trackScrollGeometry { oldY, newY in
                if let visible = searchScroll.update(oldY: oldY, newY: newY, focused: searchFocused) { isSearchBarVisible = visible }
            }
            ScrollSearchBar(text: $query, focused: $searchFocused, prompt: L10n.text("Search Downloads"), identifier: "downloads.search")
                .offset(y: isSearchBarVisible ? 0 : -60).opacity(isSearchBarVisible ? 1 : 0)
                .allowsHitTesting(isSearchBarVisible).accessibilityHidden(!isSearchBarVisible)
        }
        .animation(isSearchBarVisible ? .spring(response: 0.35, dampingFraction: 0.86) : .easeInOut(duration: 0.32), value: isSearchBarVisible)
        .onChange(of: searchFocused) { _, focused in if focused { isSearchBarVisible = true } }
        .navigationTitle(L10n.text("Downloads"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DownloadSettingsView(store: store) } label: { Image(systemName: "folder.badge.gearshape") }
                    .accessibilityLabel(L10n.text("Download Location"))
                    .accessibilityIdentifier("downloads.location")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(mode == .manga ? "manga.downloads" : "booru.downloads")
        .confirmationDialog(L10n.text("Delete Download?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete"), role: .destructive) { if let deleting { store.remove(deleting.id) }; deleting = nil }
        } message: { Text(L10n.text("This removes the downloaded files from this device.")) }
    }

    @ViewBuilder private func card(_ item: WorkDownload, style: ArtworkCellStyle) -> some View {
        VStack(alignment: .leading, spacing: style.inset(4)) {
            if let gallery = item.gallery {
                GalleryCardLayout(title: item.title, artists: item.artists.joined(separator: ", "), language: gallery.language, type: gallery.type, pages: gallery.displayedPageCount) {
                    DownloadCoverView(url: store.urls(item).first, isVideo: false)
                }
            } else if let post = item.post {
                BooruThumbnailCardLayout(post: post) {
                    DownloadCoverView(url: store.urls(item).first, isVideo: post.isVideo)
                }
                Text(item.title).font(.system(size: style.fontSize(titleSize, minimum: 10), weight: .medium)).lineLimit(2).foregroundStyle(.primary)
                if !item.artists.isEmpty { Text(item.artists.joined(separator: ", ")).font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.secondary).lineLimit(1) }
            }
            if !item.tags.isEmpty {
                Text(item.tags.prefix(4).joined(separator: " · ")).font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
    }

    private func downloadStatus(_ item: WorkDownload, style: ArtworkCellStyle) -> some View {
        VStack(alignment: .leading, spacing: style.inset(4)) {
            if item.status != .completed {
                if item.status == .downloading && item.total == 1 {
                    if let progress = store.transferProgress[item.id] { ProgressView(value: progress) }
                    else { ProgressView() }
                } else { ProgressView(value: Double(item.files.count), total: Double(max(1, item.total))) }
            }
            HStack(spacing: style.inset(4)) {
                Text(L10n.text(status(item.status))).lineLimit(1)
                if item.status != .completed { Text("\(item.files.count)/\(item.total)") }
                Spacer(minLength: 0)
                Menu { actions(item) } label: {
                    Image(systemName: "ellipsis").frame(width: max(24, 36 * style.scale), height: max(24, 36 * style.scale)).contentShape(Rectangle())
                }.accessibilityLabel(L10n.text("Download Actions")).accessibilityIdentifier("download.actions")
            }.font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.secondary)
            if let error = item.error { Text(error).font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.red).lineLimit(2) }
        }
    }

    @ViewBuilder private func actions(_ item: WorkDownload) -> some View {
        if [.queued, .downloading].contains(item.status) {
            Button(L10n.text("Pause"), systemImage: "pause") { store.pause(item.id) }
        }
        if [.paused, .failed].contains(item.status) {
            Button(L10n.text(item.status == .failed ? "Retry" : "Resume"), systemImage: "arrow.clockwise") { store.resume(item.id) }
        }
        Button(L10n.text("Delete Download"), systemImage: "trash", role: .destructive) { deleting = item }
    }

    private func status(_ status: WorkDownload.Status) -> String {
        switch status {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }
}

private struct DownloadCoverView: View {
    let url: URL?
    let isVideo: Bool
    @State private var videoImage: UIImage?
    var body: some View {
        Color.secondary.opacity(0.12).overlay {
            if isVideo {
                if let videoImage { Image(uiImage: videoImage).resizable().scaledToFill() }
                else { Image(systemName: "play.rectangle").font(.title2).foregroundStyle(.secondary) }
            } else {
                LocalThumbnailView(path: url?.path) { image in
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
                }
            }
        }.clipped()
            .task(id: url) {
                videoImage = nil
                guard isVideo, let url else { return }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 600, height: 600)
                if let frame = try? await generator.image(at: .zero), !Task.isCancelled {
                    videoImage = UIImage(cgImage: frame.image)
                }
            }
    }
}

private struct DownloadFilesView: View {
    let item: WorkDownload
    let store: DownloadStore
    @State private var preview: URL?
    @State private var reading = false
    @State private var opened = false
    var body: some View {
        List {
            Section {
                Text(item.title).font(.headline).textSelection(.enabled)
                if !item.artists.isEmpty { Text(item.artists.joined(separator: ", ")).foregroundStyle(.secondary) }
                if !item.tags.isEmpty {
                    DisclosureGroup(L10n.text("Tags")) {
                        Text(item.tags.joined(separator: " · ")).font(.subheadline).textSelection(.enabled)
                    }
                }
            }
            if item.gallery != nil {
                Button { reading = true } label: { Label(L10n.text("Read Offline"), systemImage: AppMode.manga.icon) }
            }
            ForEach(store.urls(item), id: \.self) { file in
                HStack {
                    Button(file.lastPathComponent) { preview = file }
                    Spacer()
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }.navigationTitle(item.title).navigationBarTitleDisplayMode(.inline).quickLookPreview($preview)
            .onAppear {
                guard !opened else { return }; opened = true
                if item.gallery != nil { reading = true }
                else { preview = store.urls(item).first }
            }
            .appFullScreenCover(isPresented: $reading) {
                OfflineMangaReader(item: item, folder: store.folder(item))
            }
    }
}

private struct OfflineMangaReader: View {
    @Environment(\.dismiss) private var dismiss
    private let source: DownloadedContentSource
    @State private var images: PageImageStore
    init(item: WorkDownload, folder: URL) {
        let source = DownloadedContentSource(item: item, folder: folder)
        self.source = source
        _images = State(initialValue: PageImageStore(source: source, diskCapacity: 0))
    }
    var body: some View {
        if let gallery = source.item.gallery {
            NativeReaderView(galleryID: gallery.id, initialPage: 1, source: source, images: images,
                             savesProgress: true, offline: true, search: { _ in }, exit: { dismiss() })
        }
    }
}

/// Where downloads are saved, and moving the ones saved elsewhere, such as in the app's own
/// storage where versions before 1.5.2 kept them, without downloading them again.
struct DownloadSettingsView: View {
    let store: DownloadStore
    @State private var choosing = false

    static var deviceName: String {
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp { return L10n.text("On My Mac") }
        return L10n.text(UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone")
    }
    static var deviceSymbol: String {
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp { return "laptopcomputer" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }
    static func title(_ location: DownloadLocation) -> String { location.isFiles ? deviceName : location.name }

    var body: some View {
        let movable = store.movable
        Form {
            Section {
                ForEach(store.locations) { location in
                    let selected = store.currentLocation.id == location.id
                    Button { store.setLocation(location.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: location.isFiles ? Self.deviceSymbol : "folder").foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.title(location)).foregroundStyle(.primary)
                                Text(location.isFiles ? L10n.text("TEGNAL folder in the Files app") : L10n.text("Folder you chose"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier(location.isFiles ? "downloads.location.files" : "downloads.location.folder")
                    .swipeActions {
                        if !location.isFiles, !store.items.contains(where: { $0.location == location.id }) {
                            Button(L10n.text("Remove"), role: .destructive) { store.removeFolder(location.id) }
                        }
                    }
                }
                Button { choosing = true } label: { Label(L10n.text("Choose Folder…"), systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("downloads.chooseFolder")
            } header: {
                Text(L10n.text("Save Downloads To"))
            } footer: {
                Text(L10n.text("Each work gets its own folder inside a Comics or Images folder, so the Files app and other apps can open it. A folder you choose can be in iCloud Drive or on another drive."))
            }
            if store.currentLocation.isFiles, let url = store.filesAppURL {
                Section {
                    Button { UIApplication.shared.open(url) } label: { Label(L10n.text("Show in Files"), systemImage: "folder") }
                }
            }
            Section {
                if let moving = store.moving {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(moving.done), total: Double(max(1, moving.total)))
                        Text(L10n.text("Moving %@ of %@…", String(moving.done + 1), String(moving.total))).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button { Task { await store.moveElsewhereHere() } } label: {
                        Label(L10n.text("Move to Selected Location"), systemImage: "tray.and.arrow.down")
                    }
                    .disabled(movable.isEmpty)
                    .accessibilityIdentifier("downloads.move")
                }
                if let error = store.locationError { Text(error).font(.footnote).foregroundStyle(.red) }
            } header: {
                Text(L10n.text("Downloaded Files"))
            } footer: {
                Text(movable.isEmpty
                     ? L10n.text("Every download is in the folder above.")
                     : L10n.text("%@ downloads are saved elsewhere, such as in the app's own storage where earlier versions kept them. Moving them doesn't download them again.", String(movable.count)))
            }
            Section {} footer: {
                Text(L10n.text("Keep the app open while downloading. Interrupted downloads can be resumed in Downloads."))
            }
        }
        .navigationTitle(L10n.text("Download Location"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.addFolder(url) }
        }
        .accessibilityIdentifier("downloads.settings")
    }
}

struct DownloadsSheet: View {
    let mode: WorkDownload.Mode
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            DownloadsView(mode: mode)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
    }
}
