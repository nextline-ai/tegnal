import SwiftUI

struct ReaderPreviewView: View {
    @ScaledMetric(relativeTo: .caption) private var pageNumberSize: CGFloat = 12
    @Environment(\.dismiss) private var dismiss
    let gallery: NativeGallery
    let images: PageImageStore
    @Binding var current: Int
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    ArtworkGrid(mode: .manga) { style in
                        ForEach(gallery.pages.indices, id: \.self) { index in
                            Button { current = index; dismiss() } label: {
                                VStack(spacing: style.inset(6)) {
                                    ReaderThumbnail(page: gallery.pages[index], galleryID: gallery.id, images: images)
                                        .aspectRatio(0.72, contentMode: .fit).clipped()
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current == index ? Color.accentColor : .clear, lineWidth: 3))
                                    Text("\(index + 1)").font(.system(size: style.fontSize(pageNumberSize, minimum: 9), design: .monospaced))
                                }
                            }.buttonStyle(.plain).id(index).accessibilityLabel(L10n.text("Pages: %@", String(describing: index + 1)))
                                .accessibilityIdentifier("reader.preview.\(index + 1)")
                        }
                    }
                }.onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle(L10n.text("Total pages: %@", String(describing: gallery.pages.count))).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
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
            if let image { Image(uiImage: image).resizable().scaledToFit() }
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
    var body: some View { Label(L10n.text(category.title), systemImage: category.symbol).foregroundStyle(category.color) }
}
struct ArtworkTagCloud: View {
    let groups: [ArtworkTagGroup]
    var destination: ((ArtworkTag) -> ContentRoute)? = nil
    var action: ((ArtworkTag) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if group.category != .female && group.category != .male {
                        ArtworkTagHeading(category: group.category).font(.caption.weight(.semibold))
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
