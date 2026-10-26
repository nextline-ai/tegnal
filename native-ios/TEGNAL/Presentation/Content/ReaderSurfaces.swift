import SwiftUI

struct ReaderPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    let images: PageImageStore
    @Binding var current: Int
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    GalleryPagePreviewGrid(gallery: gallery, images: images, current: current, identifier: "reader.preview") { index in
                        current = index; dismiss()
                    }
                }.onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle(L10n.text("Total pages: %@", String(describing: gallery.pages.count))).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
    }
}

/// Loading is latched by the detail screen only after meaningful downward
/// travel AND reaching the end of its metadata. A visible footer alone is not intent.
enum GalleryPreviewLoading {
    static func shouldLoad(metadata: CGRect, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0 else { return false }
        let minimumTravel = max(160, min(320, viewportHeight * 0.35))
        return 20 - metadata.minY >= minimumTravel && metadata.maxY <= viewportHeight - 44
    }
}

struct GalleryDetailPreviews: View {
    @Environment(AppEnvironment.self) private var env
    @State private var width: CGFloat = 350
    @State private var selectedPage = 0
    let gallery: NativeGallery
    let images: PageImageStore
    let enabled: Bool
    let select: (Int) -> Void
    var body: some View {
        let fullWidth = width + 40
        let columns = GalleryPreviewLayout.columns(width: fullWidth, artworkColumns: env.gridColumns(for: .manga),
            previewColumns: env.mangaPreviewColumns, removesArtworkPadding: env.removesGridPadding(for: .manga))
        let rows = env.mangaPreviewRows
        let pageCount = GalleryPreviewLayout.pageCount(total: gallery.pages.count, columns: columns, rows: rows)
        let geometry = ArtworkGridGeometry(width: fullWidth, columns: columns, removesPadding: env.removesGridPadding(for: .manga),
                                           maximumColumns: max(10, columns))
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            HStack(spacing: 12) {
                Text(L10n.text("Preview")).font(.headline).fixedSize()
                if enabled {
                    GalleryPreviewPagePicker(count: pageCount, selection: $selectedPage)
                }
            }
            if enabled {
                TabView(selection: $selectedPage) {
                    ForEach(0..<pageCount, id: \.self) { page in
                        GalleryPagePreviewGrid(gallery: gallery, images: images, current: nil, identifier: "content.detail.preview",
                            pageRange: GalleryPreviewLayout.pageRange(page, total: gallery.pages.count, columns: columns, rows: rows), select: select)
                            .frame(maxHeight: .infinity, alignment: .top).tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: GalleryPreviewLayout.height(rows: rows, geometry: geometry))
                .padding(.horizontal, -20)
                .onChange(of: columns) { _, _ in selectedPage = 0 }
                .onChange(of: rows) { _, _ in selectedPage = 0 }
            } else {
                Label(L10n.text("Scroll down to load page previews."), systemImage: "chevron.down")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                    .accessibilityIdentifier("content.detail.previewHint")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

private struct GalleryPreviewPagePicker: View {
    let count: Int
    @Binding var selection: Int
    @State private var width: CGFloat = 0
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { page in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { selection = page } } label: {
                            Text(String(page + 1)).font(.subheadline.monospacedDigit().weight(selection == page ? .bold : .regular))
                                .frame(minWidth: 32, minHeight: 36)
                                .background(selection == page ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).id(page)
                            .accessibilityLabel(L10n.text("Page %@ / %@", String(page + 1), String(count)))
                            .accessibilityAddTraits(selection == page ? .isSelected : [])
                            .accessibilityIdentifier("content.detail.previewPage.\(page + 1)")
                    }
                }.frame(minWidth: width, alignment: .trailing)
            }.scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onChange(of: selection) { _, page in withAnimation { proxy.scrollTo(page, anchor: .trailing) } }
        }.frame(height: 40)
    }
}

enum GalleryPreviewLayout {
    static func pageSize(columns: Int, rows: Int) -> Int { max(1, columns) * max(1, rows) }
    static func pageCount(total: Int, columns: Int, rows: Int) -> Int {
        let size = pageSize(columns: columns, rows: rows)
        return max(1, (max(0, total) + size - 1) / size)
    }
    static func pageRange(_ page: Int, total: Int, columns: Int, rows: Int) -> Range<Int> {
        let size = pageSize(columns: columns, rows: rows)
        let start = min(max(0, page) * size, max(0, total))
        return start..<min(start + size, max(0, total))
    }
    static func height(rows: Int, geometry: ArtworkGridGeometry) -> CGFloat {
        let rows = max(1, rows)
        return CGFloat(rows) * geometry.cellWidth / 0.72 + CGFloat(rows - 1) * geometry.spacing + geometry.margin * 2
    }
    static func columns(width: CGFloat, artworkColumns: Int, previewColumns: Int, removesArtworkPadding: Bool) -> Int {
        if previewColumns > 0 { return min(10, previewColumns) }
        let artwork = ArtworkGridGeometry(width: width, columns: artworkColumns, removesPadding: removesArtworkPadding)
        return artwork.count * 2
    }
}

/// Both detail and reader previews use the source's thumbnail route. The lazy
/// grid starts only visible/nearby cells instead of downloading the whole work.
struct GalleryPagePreviewGrid: View {
    @Environment(AppEnvironment.self) private var env
    @State private var width: CGFloat = 390
    let gallery: NativeGallery
    let images: PageImageStore
    let current: Int?
    let identifier: String
    var pageRange: Range<Int>? = nil
    let select: (Int) -> Void
    var body: some View {
        let columns = GalleryPreviewLayout.columns(width: width, artworkColumns: env.gridColumns(for: .manga),
            previewColumns: env.mangaPreviewColumns, removesArtworkPadding: env.removesGridPadding(for: .manga))
        let removesPadding = env.removesGridPadding(for: .manga)
        let geometry = ArtworkGridGeometry(width: width, columns: columns, removesPadding: removesPadding,
                                           maximumColumns: max(10, columns))
        let style = ArtworkCellStyle(width: geometry.cellWidth, removesPadding: removesPadding)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: geometry.spacing), count: columns),
                  alignment: .leading, spacing: geometry.spacing) {
            // Page order is fixed for the lifetime of this gallery.
            ForEach(pageRange ?? gallery.pages.indices, id: \.self) { index in
                Button { select(index) } label: {
                    ReaderThumbnail(page: gallery.pages[index], galleryID: gallery.id, images: images)
                        .aspectRatio(0.72, contentMode: .fit).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: style.radius(12), style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: style.radius(12), style: .continuous)
                            .strokeBorder(current == index ? Color.accentColor : .clear, lineWidth: 3))
                }.buttonStyle(.plain).id(index)
                    .accessibilityLabel(L10n.text("Pages: %@", String(describing: index + 1)))
                    .accessibilityIdentifier("\(identifier).\(index + 1)")
            }
        }
        .padding(geometry.margin)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if abs(width - $0) > 0.5 { width = $0 } }
    }
}

struct ReaderThumbnail: View {
    @Environment(\.scenePhase) private var scenePhase
    let page: GalleryPage
    let galleryID: Int64
    let images: PageImageStore
    @State private var image: UIImage?
    var body: some View {
        Color.secondary.opacity(0.1).overlay {
            if let image = image ?? images.cachedImage(hash: page.hash, thumbnail: true) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: "\(page.hash):\(scenePhase)") {
            guard scenePhase == .active, image == nil else { return }
            do {
                let loaded = try await images.load(page, galleryID: galleryID, thumbnail: true)
                try Task.checkCancellation()
                image = loaded
            } catch {}
        }
        .onDisappear { image = nil }
    }
}

struct ReaderDetailsView: View {
    let search: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    var body: some View {
        NavigationStack {
            List {
                Section { Text(gallery.title).font(.headline).textSelection(.enabled) }
                NavigationLink { ContentReportView(page: URL(string: MangaUrls.galleryUrl(for: gallery.id))!) } label: {
                    Label(L10n.text("Report Content"), systemImage: "flag")
                }.accessibilityIdentifier("reader.report")
                LabeledContent(L10n.text("Work Number"), value: String(gallery.id))

                Section(L10n.text("Language")) { chip(gallery.language, query: "language:" + gallery.language) }
                LabeledContent(L10n.text("Type"), value: gallery.type)
                LabeledContent(L10n.text("Page"), value: String(gallery.pages.count))
                Section(L10n.text("Tags")) {
                    ArtworkTagCloud(groups: ArtworkTagGroup.make(tags: gallery.tags, artists: gallery.artists.map { "artist:" + $0 }), action: { tag in
                        dismiss(); search(tag.query.replacingOccurrences(of: " ", with: "_"))
                    })
                }
            }
            .navigationTitle(L10n.text("Details")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
    }
    private func chip(_ title: String, query: String) -> some View {
        Button { dismiss(); search(query.replacingOccurrences(of: " ", with: "_")) } label: {
            Text(title).foregroundStyle(ArtworkTagCategory.language.color).modifier(ArtworkTagPill(color: ArtworkTagCategory.language.color))
        }.buttonStyle(.plain).accessibilityIdentifier("reader.details.language")
    }

}

/// Categories come from tag namespaces or the server’s category metadata.
enum ArtworkTagCategory: String, CaseIterable, Identifiable {
    case artist, series, character, female, male, group, language, type, metadata, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .artist: "Artists"
        case .series: "Series"
        case .character: "Characters"
        case .female: "Female Tags"
        case .male: "Male Tags"
        case .group: "Groups"
        case .language: "Language"
        case .type: "Type"
        case .metadata: "Metadata Tags"
        case .general: "Other Tags"
        }
    }
    var color: Color {
        switch self {
        case .artist: .orange
        case .series: .purple
        case .character: .green
        case .female: .pink
        case .male: .blue
        case .group: .teal
        case .language: .indigo
        case .type: .brown
        case .metadata: .mint
        case .general: .primary
        }
    }
    var symbol: String {
        switch self {
        case .artist: "paintbrush"
        case .series: "books.vertical"
        case .character: "person.crop.square"
        case .female, .male: "person.text.rectangle"
        case .group: "person.2"
        case .language: "globe"
        case .type: "square.stack"
        case .metadata: "info.circle"
        case .general: "tag"
        }
    }
}
struct ArtworkTag: Identifiable, Hashable {
    let query: String
    let name: String
    let category: ArtworkTagCategory
    var id: String { query }
}
struct ArtworkTagGroup: Identifiable {
    let category: ArtworkTagCategory
    let tags: [ArtworkTag]
    var id: ArtworkTagCategory { category }
    static func make(tags: [String], artists: [String] = [], categories: [String: Int] = [:]) -> [Self] {
        var result: [ArtworkTagCategory: [ArtworkTag]] = [:], seen = Set<String>()
        let artistNames = Set(artists)
        let namespaces: [String: ArtworkTagCategory] = ["artist": .artist, "series": .series, "parody": .series,
            "copyright": .series, "character": .character, "female": .female, "male": .male,
            "group": .group, "language": .language, "type": .type, "meta": .metadata, "tag": .general, "other": .general]
        for raw in artists + tags {
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            let parts = query.split(separator: ":", maxSplits: 1).map(String.init)
            var category: ArtworkTagCategory = artistNames.contains(query) ? .artist : .general
            var name = query
            if parts.count == 2, let known = namespaces[parts[0]] { category = known; name = parts[1] }
            else if let known = categories[query] {
                switch known { case 1: category = .artist; case 3: category = .series; case 4: category = .character; case 5: category = .metadata; default: break }
            }
            name = name.replacingOccurrences(of: "_", with: " ")
            guard seen.insert(category.rawValue + ":" + name).inserted else { continue }
            result[category, default: []].append(.init(query: query, name: name, category: category))
        }
        return ArtworkTagCategory.allCases.compactMap { category in
            guard let tags = result[category], !tags.isEmpty else { return nil }
            return Self(category: category, tags: tags)
        }
    }
}
struct ArtworkTagHeading: View {
    let category: ArtworkTagCategory
    var showsIcon = true
    var body: some View {
        Group {
            if showsIcon { Label(L10n.text(category.title), systemImage: category.symbol) }
            else { Text(L10n.text(category.title)) }
        }.foregroundStyle(category.color)
    }
}
enum ArtworkTagHeadingStyle { case compact, detail }
struct ArtworkTagCloud: View {
    let groups: [ArtworkTagGroup]
    var headingStyle: ArtworkTagHeadingStyle = .compact
    var destination: ((ArtworkTag) -> ContentRoute)? = nil
    var action: ((ArtworkTag) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: headingStyle == .detail ? 12 : 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: headingStyle == .detail ? 4 : 6) {
                    if group.category != .female && group.category != .male {
                        ArtworkTagHeading(category: group.category, showsIcon: headingStyle != .detail)
                            .font(headingStyle == .detail ? .headline : .caption.weight(.semibold))
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(group.tags) { tag in
                            Group {
                                if let destination {
                                    NavigationLink(value: destination(tag)) { tagLabel(tag) }
                                } else {
                                    Button { action?(tag) } label: { tagLabel(tag) }
                                }
                            }.buttonStyle(.plain)
                                .accessibilityLabel(L10n.text(group.category.title) + ": " + tag.name)
                                .accessibilityIdentifier("tags." + group.category.rawValue + "." + tag.query)
                        }
                    }
                }
            }
        }
    }
    private func tagLabel(_ tag: ArtworkTag) -> some View {
        Text(tag.name).foregroundStyle(tag.category.color).modifier(ArtworkTagPill(color: tag.category.color))
    }

}

struct ArtworkTagPill: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content.font(.body).padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(0.12), in: Capsule())
    }
}
