import SwiftUI
import Combine

/// Grid geometry is resolved once per container, not once per thumbnail.
enum WorkGridLayout {
    static func columns(_ count: Int, minimum: CGFloat = 160, spacing: CGFloat = 14) -> [GridItem] {
        if count == 0 { return [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)] }
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top), count: min(5, max(1, count)))
    }
}

struct ArtworkCellStyle: Equatable {
    var width: CGFloat = 160
    var removesPadding = false
    var showsTitle = true
    var showsArtists = true
    var columns = 1
    var scale: CGFloat { min(1, max(0.2, width / 160)) }
    func inset(_ value: CGFloat) -> CGFloat { removesPadding ? 0 : value * scale }
    func radius(_ value: CGFloat) -> CGFloat { inset(value) }
    func fontSize(_ value: CGFloat, minimum: CGFloat = 8) -> CGFloat { max(minimum, value * scale) }
}

struct ArtworkGridGeometry: Equatable {
    let count: Int
    let cellWidth: CGFloat
    let spacing: CGFloat
    let margin: CGFloat
    init(width: CGFloat, columns: Int, minimum: CGFloat = 160, removesPadding: Bool, maximumColumns: Int = 5) {
        let width = max(1, width)
        count = columns == 0 ? max(1, Int((width - (removesPadding ? 0 : 32) + 14) / (minimum + 14))) : min(max(1, maximumColumns), max(1, columns))
        let gaps = CGFloat(count - 1)
        // Solve the proportional margins and gaps together with the cell width.
        let proposed = (width - 32 - gaps * 14) / CGFloat(count)
        cellWidth = removesPadding ? width / CGFloat(count) : proposed >= 160 ? proposed : width / (CGFloat(count) + (32 + gaps * 14) / 160)
        let scale = min(1, cellWidth / 160)
        spacing = removesPadding ? 0 : 14 * scale
        margin = removesPadding ? 0 : 16 * scale
    }
}

private struct ArtworkCellStyleKey: EnvironmentKey { static let defaultValue = ArtworkCellStyle() }
extension EnvironmentValues {
    var artworkCellStyle: ArtworkCellStyle {
        get { self[ArtworkCellStyleKey.self] }
        set { self[ArtworkCellStyleKey.self] = newValue }
    }
}

/// Online, saved, recommended and downloaded artwork share the same density.
struct ArtworkGrid<Content: View>: View {
    enum Kind { case artwork, folders }
    let mode: AppMode
    var kind: Kind = .artwork
    /// The surrounding section keeps its own controls inset; the grid can reach the edges.
    var surroundingPadding: CGFloat = 0
    @ViewBuilder let content: (ArtworkCellStyle) -> Content
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 390
    var body: some View {
        let columns = typeSize.isAccessibilitySize ? 1 : kind == .folders ? env.folderColumns(for: mode) : env.gridColumns(for: mode)
        let geometry = ArtworkGridGeometry(width: width, columns: columns,
            minimum: kind == .folders && sizeClass == .regular ? 240 : 160, removesPadding: env.removesGridPadding(for: mode))
        let style = ArtworkCellStyle(width: geometry.cellWidth, removesPadding: env.removesGridPadding(for: mode),
            showsTitle: mode != .manga || env.showsMangaTitles, showsArtists: mode != .manga || env.showsMangaArtists, columns: geometry.count)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: geometry.spacing, alignment: .top), count: geometry.count), alignment: .leading, spacing: geometry.spacing) {
            content(style)
        }
        .environment(\.artworkCellStyle, style)
        .padding(geometry.margin)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs(width - $0) > 0.5 { width = $0 } }
        .padding(.horizontal, -surroundingPadding)
    }
}

/// Shared cover ratio, language badge and typography for local and remote galleries.
struct GalleryCardLayout<Cover: View>: View {
    @Environment(\.artworkCellStyle) private var style
    @ScaledMetric(relativeTo: .subheadline) private var titleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 11
    let title: String
    let artists: String
    let language: String
    var recommendationTag: String? = nil
    @ViewBuilder let cover: () -> Cover
    var body: some View {
        VStack(alignment: .leading, spacing: style.inset(6)) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear.aspectRatio(0.72, contentMode: .fit).overlay { cover() }.clipped()
                if !language.isEmpty {
                    Text(language).font(.system(size: style.fontSize(badgeSize), weight: .bold)).padding(.horizontal, style.inset(6)).padding(.vertical, style.inset(2))
                        .background(.ultraThinMaterial, in: Capsule()).padding(style.inset(6))
                }
            }.clipShape(RoundedRectangle(cornerRadius: style.radius(12), style: .continuous))
            if style.showsTitle || style.showsArtists && !artists.isEmpty || recommendationTag != nil {
                VStack(alignment: .leading, spacing: style.inset(2)) {
                    if style.showsTitle { Text(title).font(.system(size: style.fontSize(titleSize, minimum: 10), weight: .medium)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.primary) }
                    if let recommendationTag {
                        Label(recommendationTag, systemImage: "number").font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.secondary).lineLimit(style.width < 110 ? 1 : 2)
                    }
                    if style.showsArtists && !artists.isEmpty { Text(artists).font(.system(size: style.fontSize(captionSize, minimum: 9))).foregroundStyle(.secondary).lineLimit(1) }
                }.padding(.horizontal, style.inset(2))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, artists, language].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

public struct WorkCardView: View {
    @Environment(\.artworkCellStyle) private var style
    public let work: Work
    public init(work: Work) { self.work = work }
    public var body: some View {
        GalleryCardLayout(title: work.hasTitle ? work.title ?? "" : String(work.galleryId), artists: work.artists ?? "", language: work.language ?? "") {
            LocalThumbnailView(path: work.thumbStatus == "ready" ? work.thumbPath : nil, revision: String(work.thumbPage ?? 1)) { image in
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12)).overlay {
                        VStack(spacing: style.inset(6)) {
                            Image(systemName: work.thumbStatus == "gone" ? "slash.circle" : "photo").font(.system(size: style.fontSize(22)))
                            if style.showsTitle { Text(String(work.galleryId)).font(.system(size: style.fontSize(11), design: .monospaced)) }
                        }.foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Only visible cells request local files, with cancellation preventing stale
/// results from being assigned when SwiftUI reuses or removes a cell.
struct LocalThumbnailView<Content: View>: View {
    let path: String?
    var revision: String = ""
    @ViewBuilder let content: (UIImage?) -> Content
    @State private var image: UIImage?
    @State private var loadedRequest: Request?
    @State private var cacheRevision = 0

    private struct Request: Equatable {
        let path: String?
        let revision: String
        let cacheRevision: Int
    }

    var body: some View {
        let request = Request(path: path, revision: revision, cacheRevision: cacheRevision)
        content(loadedRequest == request ? image : path.flatMap { LocalThumbnailCache.shared.image(forPath: $0) })
            .task(id: request) {
                guard let path else { image = nil; loadedRequest = request; return }
                let loadedImage = await LocalThumbnailCache.shared.load(forPath: path)
                guard !Task.isCancelled else { return }
                image = loadedImage
                loadedRequest = request
            }
            .onReceive(NotificationCenter.default.publisher(for: LocalThumbnailCache.didInvalidate).receive(on: DispatchQueue.main)) { notification in
                guard (notification.object as? LocalThumbnailCache) === LocalThumbnailCache.shared else { return }
                guard notification.userInfo?["path"] == nil || notification.userInfo?["path"] as? String == path else { return }
                cacheRevision += 1
            }
    }
}
