import SwiftUI

/// A share card never carries saved works: the cover is drawn, and tags stay off
/// until the person turns them on.
struct RecapShareView: View {
    let recap: TasteRecap
    let palette: RecapPalette
    enum Format: String, CaseIterable, Identifiable { case story, square
        var id: String { rawValue }
        var size: CGSize { self == .story ? CGSize(width: 360, height: 640) : CGSize(width: 360, height: 360) }
    }
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var format = Format.story
    @State private var showsTags = false
    @State private var rendered: UIImage?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if let rendered { Image(uiImage: rendered).resizable().scaledToFit() }
                        else { poster.aspectRatio(format.size, contentMode: .fit) }
                    }.frame(maxHeight: 380).clipShape(RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity)
                        .accessibilityLabel(L10n.text("Share card preview")).accessibilityIdentifier("recap.share.preview")
                }.listRowBackground(Color.clear)
                Section {
                    Picker(L10n.text("Format"), selection: $format) {
                        Text(L10n.text("Story")).tag(Format.story); Text(L10n.text("Square")).tag(Format.square)
                    }.pickerStyle(.segmented)
                    Toggle(L10n.text("Show top tags"), isOn: $showsTags).accessibilityIdentifier("recap.share.tags")
                } footer: { Text(L10n.text("Share cards never include your saved works.")) }
            }
            .navigationTitle(L10n.text("Share cover")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() }.accessibilityIdentifier("recap.share.close") }
                ToolbarItem(placement: .confirmationAction) {
                    if let rendered {
                        let image = Image(uiImage: rendered)
                        ShareLink(item: image, preview: SharePreview(L10n.text("My TEGNAL Recap"), image: image)) { Label(L10n.text("Share"), systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("recap.share.send")
                    }
                }
            }
            .task(id: "\(format.rawValue):\(showsTags)") { render() }
        }
    }
    private var poster: some View {
        RecapCoverLayout(recap: recap, palette: palette, timeZone: RecapFormat.zone(env), showsTags: showsTags) {
            RecapCoverArt(palette: palette, seed: recap.coverSeed)
        }.overlay(alignment: .bottomTrailing) {
            Text(verbatim: "TEGNAL").font(RecapType.display(13, weight: .heavy)).kerning(1).foregroundStyle(.white.opacity(0.9)).padding(18)
        }
    }
    private func render() {
        let renderer = ImageRenderer(content: poster.frame(width: format.size.width, height: format.size.height))
        renderer.scale = 3
        rendered = renderer.uiImage
    }
}

/// The period's saves as a browsable shelf, with a way to keep them together.
struct RecapWorksView: View {
    let recap: TasteRecap
    let palette: RecapPalette
    @Environment(AppEnvironment.self) private var env
    @Environment(RecapArtwork.self) private var artwork
    @State private var opened: TasteRecommendation?
    @State private var message: String?
    @State private var confirming = false
    private var folderName: String { L10n.text("%@ Recap", RecapFormat.title(recap, timeZone: RecapFormat.zone(env))) }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 4)], spacing: 4) {
                ForEach(recap.saved) { work in
                    Button { open(work) } label: {
                        RecapArtTile(work: work, palette: palette, generated: recap.isSample).aspectRatio(0.74, contentMode: .fit).clipped().contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(work.info.title ?? L10n.text("Open"))
                }
            }.padding(4)
        }
        .navigationTitle(RecapFormat.title(recap, timeZone: RecapFormat.zone(env))).navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain).accessibilityIdentifier("recap.works")
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button { confirming = true } label: { Label(L10n.text("Make a folder"), systemImage: "folder.badge.plus") }.disabled(recap.isSample).accessibilityIdentifier("recap.works.folder")
            }
        }
        .confirmationDialog(L10n.text("Make a folder"), isPresented: $confirming) {
            Button(L10n.text("Create “%@”", folderName), action: collect)
            Button(L10n.text("Cancel"), role: .cancel) { }
        } message: {
            Text(L10n.text(recap.mode == .booru ? "Images keep one folder each, so these %@ images will move into the new folder." : "These %@ works will also appear in the new folder.", String(recap.saved.count)))
        }
        .environment(\.booruBrowsingMode, env.mode)
        .tasteWorkPresentation($opened) { _ in .init(origin: .library) }
        .transientMessage($message)
    }
    private func open(_ work: RecapWork) {
        guard !recap.isSample else { return }
        opened = .init(item: work.item, post: artwork.post(work), gallery: nil, reason: TasteTag(source: work.item.source, name: recap.tags.first?.name ?? ""), score: 0)
    }
    private func collect() {
        do {
            if recap.mode == .comics {
                let folder = try env.database.createFolder(name: folderName)
                guard let id = folder.id else { return }
                for work in recap.saved { if let row = try env.database.getWork(galleryId: work.item.id)?.id { try env.database.addWorkToFolder(workId: row, folderId: id) } }
            } else {
                let id = try env.booru.saveFolder(name: folderName)
                for work in recap.saved { if let post = artwork.post(work) { try env.booru.saveFavorite(post, folderID: id) } }
            }
            message = L10n.text("Folder created")
        } catch { message = L10n.text("Unable to create the folder") }
    }
}
