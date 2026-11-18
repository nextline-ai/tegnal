import SwiftUI

/// A picture at reading size for a question or an example, loaded through the image library's own cache.
struct StudyPicture: View {
    let post: BooruPost
    let server: BooruServer
    var fills = false
    @State private var image: UIImage?
    @State private var failed = false
    private var url: URL? { post.reducedDataURL ?? post.sampleURL ?? post.previewURL }
    private var isFixture: Bool {
        #if DEBUG
        return BooruUITestSupport.enabled
        #else
        return false
        #endif
    }
    var body: some View {
        // The picture is drawn over a box of the size it is given, so that a wide or tall one never pushes the layout out.
        // Where the box must be filled, the whole picture is still shown, over a blurred copy of itself that fills the rest.
        Color(uiColor: .tertiarySystemFill).overlay {
            if let image {
                if fills { Image(uiImage: image).resizable().scaledToFill().blur(radius: 18).opacity(0.75) }
                Image(uiImage: image).resizable().scaledToFit()
            }
            else if isFixture {
                LinearGradient(colors: [.indigo, .cyan.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "mountain.2.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.8))
            } else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .clipped()
        .task(id: post.id) {
            guard !isFixture, let url else { failed = !isFixture; return }
            if let cached = BooruThumbnailCache.shared.cachedImage(url: url, server: server) { image = cached; return }
            do {
                let loaded = try await BooruThumbnailCache.shared.image(url: url, server: server)
                try Task.checkCancellation()
                image = loaded
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

/// Everything about one tag: what it means, what it looks like, what it is mixed up with and what the server says.
/// It works for any tag; a tag the curriculum does not teach shows what the server knows.
struct StudyTagView: View {
    let name: String
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @State private var board = StudyBoard()
    @State private var info: StudyTagInfo?
    @State private var examples: [BooruPost] = []
    @State private var loading = true
    @State private var opened: BooruPost?
    @State private var session: StudySession?
    @State private var copied = false
    @State private var showsWholePage = false

    private var tag: StudyTag? { board.curriculum.tag(name) }
    private var words: String { StudyPrompt.words(name) }
    /// Saved tags belong to a server; with several chosen, the first is the one the button reads and changes.
    private var saved: Bool { store.selectedServers.first.map { store.savedTags(serverID: $0.id).contains(name) } ?? false }

    var body: some View {
        List {
            heading
            actions
            if !store.selectedServers.isEmpty { pictures }
            if let tag, let mixed = tag.confusable?.compactMap(board.curriculum.tag), !mixed.isEmpty {
                Section(L10n.text("Often Mixed Up With")) {
                    ForEach(mixed) { other in
                        NavigationLink { StudyTagView(name: other.name, source: source) } label: { StudyTagRow(tag: other, progress: board.progress[other.name], count: nil) }
                    }
                }
            }
            if let related = info?.related.filter({ $0.category == 0 }).prefix(16), !related.isEmpty {
                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(related)) { other in
                            StudyChip(title: StudyPrompt.words(other.name), detail: "\(Int((other.frequency * 100).rounded()))%", name: other.name, source: source)
                        }
                    }.padding(.vertical, 4)
                } header: { Text(L10n.text("Often Used Together")) }
                  footer: { Text(L10n.text("The share of this tag's posts that also carry each tag.")) }
            }
            if let wiki = info?.wiki { page(wiki) }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(words).navigationBarTitleDisplayMode(.inline)
        .appFullScreenCover(item: $opened) { post in
            if let server = store.servers.first(where: { $0.id == post.serverID }) {
                BooruPostView(post: post, posts: examples, server: server, source: source)
            }
        }
        .appFullScreenCover(item: $session, onDismiss: { board.reload(store) }) { StudyQuizView(session: $0, source: source) }
        .onAppear { board.reload(store) }
        .task(id: name + "|" + store.selectedServerIDs.joined(separator: ",")) {
            loading = true
            async let found = StudyLookup.examples(name, store: store, source: source)
            async let known = StudyLookup.info(name, store: store, source: source)
            let (posts, details) = await (found, known)
            guard !Task.isCancelled else { return }
            examples = Array(posts.prefix(18)); info = details; loading = false
        }
    }

    private var heading: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(words).font(.title2.weight(.bold)).textSelection(.enabled)
                        if let tag, L10n.language != "en" { Text(tag.title()).font(.headline).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    if tag != nil { StudyMastery(progress: board.progress[name]).padding(.top, 8) }
                }
                if let tag { Text(tag.note.resolved()).font(.body) }
                else if !loading, info?.wiki == nil { Text(L10n.text("This tag is not part of the lessons, and the server has no page about it.")).font(.subheadline).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    if let count = info?.count {
                        StudyBadge(symbol: "photo.on.rectangle", text: L10n.text("%@ posts", StudyStyle.count(count)))
                    }
                    if let unit = board.curriculum.unit(of: name) { StudyBadge(symbol: unit.symbol, text: unit.title.resolved()) }
                    if let names = info?.wiki?.otherNames, let other = names.first(where: { $0 != name }) {
                        StudyBadge(symbol: "character.bubble", text: other.replacingOccurrences(of: "_", with: " "))
                    }
                }
            }.padding(.vertical, 4)
        }
    }

    private var actions: some View {
        Section {
            Button {
                UIPasteboard.general.string = words; copied = true
                Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
            } label: { Label(L10n.text(copied ? "Copied" : "Copy for a Prompt"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                .accessibilityIdentifier("study.copy")
            if let server = store.selectedServers.first {
                NavigationLink { BooruFeedView(servers: store.selectedServers, source: source, initialQuery: name) } label: {
                    Label(L10n.text("Browse Pictures With This Tag"), systemImage: "magnifyingglass")
                }
                Button {
                    store.perform { try store.toggleTag(name, serverID: server.id) }
                } label: { Label(L10n.text(saved ? "Remove Saved Tag" : "Save Tag"), systemImage: saved ? "star.fill" : "star") }
            }
            if tag != nil {
                Button { session = StudySession(scope: .tags([name] + (tag?.confusable ?? [])), store: store, source: source) } label: {
                    Label(L10n.text("Practice This Tag"), systemImage: "play.circle")
                }.accessibilityIdentifier("study.practice")
            }
        }
    }

    private var pictures: some View {
        Section(L10n.text("Examples")) {
            if examples.isEmpty {
                if loading { HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 120) }
                else { Text(L10n.text("No pictures could be read for this tag.")).font(.subheadline).foregroundStyle(.secondary) }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(examples) { post in
                            if let server = store.servers.first(where: { $0.id == post.serverID }) {
                                Button { opened = post } label: {
                                    BooruThumbnail(post: post, server: server).frame(width: 112, height: 150).clipShape(RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).accessibilityIdentifier("study.example.\(post.postID)")
                            }
                        }
                    }.padding(.horizontal, 16)
                }.frame(height: 150).listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            }
        }
    }

    @ViewBuilder private func page(_ wiki: StudyWiki) -> some View {
        let blocks = StudyDText.blocks(wiki.body)
        let shown = showsWholePage ? blocks : Array(blocks.prefix(6))
        if !blocks.isEmpty {
            Section {
                // One row for the whole page, so that its lines sit as close as running text.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let text): Text(text).font(.subheadline.weight(.semibold)).padding(.top, 6)
                        case .paragraph(let text): StudyLinkedText(text: text, source: source)
                        case .bullet(let level, let text):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                StudyLinkedText(text: text, source: source)
                            }.padding(.leading, CGFloat(max(0, level - 1)) * 14)
                        }
                    }
                }.padding(.vertical, 4)
                if blocks.count > shown.count { Button(L10n.text("Show the Whole Page")) { showsWholePage = true } }
                NavigationLink { BooruNoteTranslationView(text: StudyDText.plain(wiki.body)).navigationTitle(L10n.text("Translation")).navigationBarTitleDisplayMode(.inline) } label: {
                    Label(L10n.text("Translate"), systemImage: "translate")
                }
            } header: { Text(L10n.text("From the Server's Tag Page")) }
              footer: { if let server = StudyLookup.infoServer(store) { Text(server.displayName) } }
        }
    }
}

/// Wiki wording whose tag links open that tag's page here.
private struct StudyLinkedText: View {
    let text: AttributedString
    let source: any BooruProviding
    @State private var opened: StudyLinkedTag?
    var body: some View {
        Text(text).font(.subheadline).tint(StudyStyle.accent)
            .environment(\.openURL, OpenURLAction { url in
                guard let name = StudyDText.tag(from: url) else { return .systemAction }
                opened = .init(name: name); return .handled
            })
            .navigationDestination(item: $opened) { StudyTagView(name: $0.name, source: source) }
    }
}
private struct StudyLinkedTag: Identifiable, Hashable { let name: String; var id: String { name } }

private struct StudyChip: View {
    let title: String
    let detail: String
    let name: String
    let source: any BooruProviding
    @State private var opened = false
    var body: some View {
        Button { opened = true } label: {
            HStack(spacing: 5) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }.buttonStyle(.plain)
            .navigationDestination(isPresented: $opened) { StudyTagView(name: name, source: source) }
    }
}

struct StudyBadge: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol).font(.caption).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// A picture's tags written the way image generators are prompted, with the tags it can teach below.
struct StudyPromptView: View {
    let post: BooruPost
    let source: any BooruProviding
    @Environment(BooruStore.self) private var store
    @SwiftUI.AppStorage("study.promptStyle", store: ReaderPreferences.booruDefaults) private var style = StudyPrompt.Style.natural.rawValue
    @SwiftUI.AppStorage("study.promptArtists", store: ReaderPreferences.booruDefaults) private var artists = false
    @State private var board = StudyBoard()
    @State private var session: StudySession?
    @State private var copied = false
    private var chosen: StudyPrompt.Style { StudyPrompt.Style(rawValue: style) ?? .natural }
    private var text: String { StudyPrompt.text(StudyPrompt.ordered(post, artists: artists), style: chosen) }
    private var taught: [StudyTag] { board.curriculum.taught(in: post) }
    var body: some View {
        List {
            Section {
                Picker(L10n.text("Format"), selection: $style) {
                    Text(L10n.text("Prompt")).tag(StudyPrompt.Style.natural.rawValue)
                    Text(L10n.text("Escaped Brackets")).tag(StudyPrompt.Style.escaped.rawValue)
                    Text(L10n.text("Search Tags")).tag(StudyPrompt.Style.tags.rawValue)
                }.pickerStyle(.segmented).listRowSeparator(.hidden)
                Text(text).font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("study.prompt")
                if !post.artists.isEmpty { Toggle(L10n.text("Include Artist Names"), isOn: $artists) }
                Button {
                    UIPasteboard.general.string = text; copied = true
                    Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                } label: { Label(L10n.text(copied ? "Copied" : "Copy Prompt"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityIdentifier("study.promptCopy")
                NavigationLink { GeneratorView(prompt: StudyPrompt.text(StudyPrompt.ordered(post, artists: artists), style: .escaped)) } label: {
                    Label(L10n.text("Generate With This Prompt"), systemImage: "wand.and.stars")
                }.accessibilityIdentifier("study.promptGenerate")
            } footer: {
                Text(L10n.text(chosen == .escaped ? "For tools that read brackets as emphasis: brackets that belong to a tag are escaped." : chosen == .tags ? "The tags as the server writes them, ready to search with." : "Headcount first, then characters and series, then what the picture shows. File and translation tags are left out."))
            }
            if !taught.isEmpty {
                Section {
                    Button { session = StudySession(scope: .tags(taught.map(\.name)), store: store, source: source) } label: {
                        Label(L10n.text("Practice These Tags"), systemImage: "play.circle")
                    }.accessibilityIdentifier("study.promptPractice")
                    ForEach(taught) { tag in
                        NavigationLink { StudyTagView(name: tag.name, source: source) } label: { StudyTagRow(tag: tag, progress: board.progress[tag.name], count: nil) }
                    }
                } header: { Text(L10n.text("Tags in This Picture")) }
            }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(L10n.text("Prompt")).navigationBarTitleDisplayMode(.inline)
        .appFullScreenCover(item: $session, onDismiss: { board.reload(store) }) { StudyQuizView(session: $0, source: source) }
        .onAppear { board.reload(store) }
    }
}
