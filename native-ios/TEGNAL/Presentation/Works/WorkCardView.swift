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
    var showsCategory = false
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

    /// The narrowest an artwork card may be before Automatic drops a column. Phones and an
    /// iPhone Duo keep 160 pt; wider windows let cards grow a little with the screen, so an iPad
    /// shows three columns upright and four on its side rather than rows of phone-sized cards.
    static func artworkMinimum(width: CGFloat) -> CGFloat { min(300, 160 + max(0, width - 600) * 0.2) }

    /// Wider than any phone or an iPhone Duo on its side.
    static let wideWidth: CGFloat = 602
    /// A chosen column count describes a phone held upright, where Automatic shows two. A wider
    /// window keeps that choice relative to its own Automatic count: four chosen shows twice as
    /// many columns as Automatic there, two the same number, so cards grow with the screen too.
    static func columns(chosen: Int, width: CGFloat, minimum: CGFloat? = nil) -> Int {
        guard chosen > 0, width > wideWidth else { return chosen }
        let automatic = ArtworkGridGeometry(width: width, columns: 0, minimum: minimum ?? artworkMinimum(width: width), removesPadding: false).count
        return min(12, max(1, Int((CGFloat(chosen) * CGFloat(automatic) / 2).rounded())))
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
    var topMarginScale: CGFloat = 1
    @ViewBuilder let content: (ArtworkCellStyle) -> Content
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 390
    var body: some View {
        let chosen = kind == .folders ? env.folderColumns(for: mode) : env.gridColumns(for: mode)
        let minimum = kind == .folders ? (sizeClass == .regular ? 240 : 160) : ArtworkGridGeometry.artworkMinimum(width: width)
        let columns = typeSize.isAccessibilitySize ? 1 : ArtworkGridGeometry.columns(chosen: chosen, width: width, minimum: minimum)
        let geometry = ArtworkGridGeometry(width: width, columns: columns, minimum: minimum,
            removesPadding: env.removesGridPadding(for: mode), maximumColumns: 12)
        let style = ArtworkCellStyle(width: geometry.cellWidth, removesPadding: env.removesGridPadding(for: mode),
            showsTitle: mode != .manga || env.showsMangaTitles, showsArtists: mode != .manga || env.showsMangaArtists,
            showsCategory: mode == .manga && env.showsMangaCategories, columns: geometry.count)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: geometry.spacing, alignment: .top), count: geometry.count), alignment: .leading, spacing: geometry.spacing) {
            content(style)
        }
        .environment(\.artworkCellStyle, style)
        .padding(.horizontal, geometry.margin)
        .padding(.bottom, geometry.margin)
        .padding(.top, geometry.margin * topMarginScale)
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
    var type = ""
    /// Shown before the language, as “13 | korean”.
    var pages: Int? = nil
    var showsLanguage = true
    var recommendationTag: String? = nil
    @ViewBuilder let cover: () -> Cover
    private var category: String { type.isEmpty ? "" : GalleryCategory.title(type) }
    var body: some View {
        VStack(alignment: .leading, spacing: style.inset(6)) {
            ZStack(alignment: .bottom) {
                Color.clear.aspectRatio(0.72, contentMode: .fit).overlay { cover() }.clipped()
                if showsLanguage {
                    // A narrow card keeps the language and lets the category go.
                    ViewThatFits(in: .horizontal) {
                        badges(category: style.showsCategory ? category : "")
                        badges(category: "")
                    }.padding(style.inset(6))
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
            .accessibilityLabel([title, artists, category, pageText, language].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func badges(category: String) -> some View {
        HStack(spacing: style.inset(4)) {
            if !category.isEmpty {
                badge(category).foregroundStyle(.white).background(GalleryCategory.color(type), in: Capsule())
            }
            Spacer(minLength: 0)
            if pageCount != nil || !language.isEmpty { pagesAndLanguage.background(.ultraThinMaterial, in: Capsule()) }
        }
    }

    private var pageCount: Int? { pages.flatMap { $0 > 0 ? $0 : nil } }
    private var pageText: String { pageCount.map { L10n.text("%@ pages", String($0)) } ?? "" }

    /// The page count and the language share one badge, split by a thin line.
    private var pagesAndLanguage: some View {
        HStack(spacing: style.inset(4)) {
            if let pageCount { Text(String(pageCount)).monospacedDigit() }
            if pageCount != nil && !language.isEmpty {
                Rectangle().fill(.primary.opacity(0.55)).frame(width: 1, height: style.fontSize(badgeSize) * 0.85)
            }
            if !language.isEmpty { Text(language) }
        }
        .font(.system(size: style.fontSize(badgeSize), weight: .bold)).lineLimit(1).fixedSize()
        .padding(.horizontal, style.inset(6)).padding(.vertical, style.inset(2))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: style.fontSize(badgeSize), weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, style.inset(6)).padding(.vertical, style.inset(2))
    }
}

extension GalleryCategory {
    /// Distinct hues let a grid be scanned by category at a glance.
    static func color(_ type: String) -> Color {
        switch key(type) {
        case "doujinshi": return Color(red: 0.80, green: 0.24, blue: 0.24)
        case "manga": return Color(red: 0.86, green: 0.45, blue: 0.10)
        case "artistcg": return Color(red: 0.72, green: 0.56, blue: 0.04)
        case "gamecg": return Color(red: 0.20, green: 0.58, blue: 0.30)
        case "imageset": return Color(red: 0.30, green: 0.36, blue: 0.80)
        case "anime": return Color(red: 0.08, green: 0.56, blue: 0.62)
        case "western": return Color(red: 0.45, green: 0.58, blue: 0.10)
        case "non-h": return Color(red: 0.16, green: 0.46, blue: 0.82)
        case "cosplay": return Color(red: 0.56, green: 0.30, blue: 0.76)
        case "photo": return Color(red: 0.80, green: 0.30, blue: 0.56)
        default: return Color(white: 0.42)
        }
    }
}

public struct WorkCardView: View {
    @Environment(\.artworkCellStyle) private var style
    public let work: Work
    public init(work: Work) { self.work = work }
    public var body: some View {
        GalleryCardLayout(title: work.hasTitle ? work.title ?? "" : String(work.galleryId), artists: work.artists ?? "", language: work.language ?? "", type: work.type ?? "", pages: work.pageCount) {
            LocalThumbnailView(path: work.thumbStatus == "ready" ? work.thumbPath : nil, revision: String(work.thumbPage ?? 1)) { image in
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12)).overlay {
                        VStack(spacing: style.inset(6)) {
                            Image(systemName: work.thumbStatus == "gone" ? "slash.circle" : "photo").font(.system(size: style.fontSize(22)))
                            if style.showsTitle { Text(String(work.galleryId)).font(.system(size: style.fontSize(11))) }
                        }.foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Shown while a card is held, so reading a work's details takes no second tap.
struct WorkContextPreview: View {
    let work: Work
    private var details: String {
        [work.language, work.type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var tags: [ArtworkTag] {
        let names = (work.tags ?? "").components(separatedBy: ", ")
        return ArtworkTagGroup.make(tags: names, mode: .comics).flatMap(\.tags).filter { $0.category != .language && $0.category != .artist }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            LocalThumbnailView(path: work.thumbStatus == "ready" ? work.thumbPath : nil, revision: String(work.thumbPage ?? 1)) { image in
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(Color.secondary.opacity(0.12)) }
            }.frame(width: 104, height: 148).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(work.hasTitle ? work.title ?? "" : String(work.galleryId)).font(.headline).lineLimit(3)
                if let artists = work.artists, !artists.isEmpty { Text(artists).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                if !details.isEmpty { Text(details).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                if !tags.isEmpty {
                    Text(tags.prefix(6).map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14).frame(width: 340, alignment: .topLeading)
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
