import SwiftUI

/// The feedback a card can offer. Absent on surfaces that only show evidence.
struct RecommendationFeedback {
    var why: (TasteRecommendation) -> Void
    var more: (TasteRecommendation) -> Void
    var dismiss: (TasteRecommendation) -> Void
}

struct RecommendationMenu: View {
    let item: TasteRecommendation
    let feedback: RecommendationFeedback
    var compact = false
    var body: some View {
        Menu {
            Button { feedback.why(item) } label: { Label(L10n.text("Why this recommendation?"), systemImage: "questionmark.circle") }
            Button { feedback.more(item) } label: { Label(L10n.text("More like this"), systemImage: "square.on.square") }
            Button(role: .destructive) { feedback.dismiss(item) } label: { Label(L10n.text("Not interested"), systemImage: "hand.thumbsdown") }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: compact ? 14 : 16, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.75), radius: 3).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.text("Recommendation options")).accessibilityIdentifier("taste.more.\(item.item.id)")
    }
}

/// How far the feed reaches, then today's threads with the tuner at their head.
/// Sections breathe more than the works inside them, which stay close together.
enum SmartSpacing {
    static let section: CGFloat = 40
    static let heading: CGFloat = 16
}

struct SmartSteering: View {
    let feed: TasteFeedState
    let refresh: () -> Void
    let focus: (TasteFocus?) -> Void
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("How far to reach"), selection: Binding(get: { env.taste.control.discoveryLevel ?? 1 }, set: { value in
                env.taste.change { $0.discoveryLevel = value }; refresh()
            })) {
                Text(L10n.text("Familiar")).tag(0); Text(L10n.text("Balanced")).tag(1); Text(L10n.text("Adventurous")).tag(2)
            }.pickerStyle(.segmented).accessibilityIdentifier("taste.discovery")
            if let active = feed.focus {
                Button { focus(nil) } label: {
                    Label(active.why.label, systemImage: "xmark").font(.subheadline.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 34).foregroundStyle(.white).background(TastePresentation.accent, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("taste.focus.clear")
            }
        }
    }
}

struct SmartArtwork: View {
    let item: TasteRecommendation
    var large = false
    @Environment(AppEnvironment.self) private var env
    @State private var sample: UIImage?
    private var usesFixtures: Bool {
        #if DEBUG
        return BooruUITestSupport.enabled
        #else
        return false
        #endif
    }
    var body: some View {
        ZStack {
            if let post = item.post, let server = env.booru.servers.first(where: { $0.id == post.serverID }) {
                BooruThumbnail(post: post, server: server)
                if let sample { GeometryReader { geometry in Image(uiImage: sample).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }.transition(.opacity) }
            } else if let gallery = item.gallery { TasteArtwork(gallery: gallery) }
            else { Color.secondary.opacity(0.12) }
        }
        .task(id: item.id) {
            guard large, !usesFixtures, let post = item.post, !post.isVideo, !post.isAnimated, let url = post.sampleURL,
                  let server = env.booru.servers.first(where: { $0.id == post.serverID }),
                  let image = try? await BooruThumbnailCache.shared.image(url: url, server: server), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { sample = image }
        }
    }
}

/// Three equal cards, so no single choice has to carry the page.
struct SmartPicksView: View {
    let items: [TasteRecommendation]
    let open: (TasteRecommendation) -> Void
    let toggle: (TasteRecommendation) -> Void
    let bookmarks: Set<Int64>
    let feedback: RecommendationFeedback
    /// Lines the cards up with the grid below, which follows the grid settings.
    var inset: CGFloat = 0
    @Environment(AppEnvironment.self) private var env
    private func saved(_ item: TasteRecommendation) -> Bool { item.post.map { env.booru.favoriteIDs.contains($0.id) } ?? bookmarks.contains(item.item.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: SmartSpacing.heading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("Today's picks")).font(.title3.bold()).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(L10n.text("One each from your usual taste, recent interests and something new.")).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let mode: TasteMode = item.post == nil ? .comics : .booru
                    // A tap gesture rather than a Button, so a hold can bookmark or carry the work.
                    Color.clear.aspectRatio(0.74, contentMode: .fit).overlay { SmartArtwork(item: item) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            if saved(item) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.yellow).padding(6).accessibilityHidden(true) }
                        }.contentShape(Rectangle())
                        .onTapGesture { open(item) }
                        .accessibilityAddTraits(.isButton).accessibilityAction { open(item) }
                        .accessibilityIdentifier("taste.work.\(item.item.id)")
                        .smartHold(item, queue: env.readingQueue) { toggle(item) }
                        .accessibilityLabel(item.gallery?.title ?? item.why?.sentence ?? L10n.text("Open"))
                        .accessibilityValue(WorkSaveResult.accessibilityValue(saved: saved(item), mode: mode))
                        .accessibilityAction(named: WorkSaveResult.actionTitle(saved: saved(item), mode: mode)) { toggle(item) }
                        .overlay(alignment: .topTrailing) { RecommendationMenu(item: item, feedback: feedback, compact: true) }
                        .frame(maxWidth: 190)
                }
            }.padding(.horizontal, inset)
        }
    }
}

struct SmartShelfView: View {
    @Environment(AppEnvironment.self) private var env
    let shelf: TasteShelf
    let open: (TasteRecommendation) -> Void
    let toggle: (TasteRecommendation) -> Void
    let bookmarks: Set<Int64>
    let feedback: RecommendationFeedback
    var body: some View {
        VStack(alignment: .leading, spacing: SmartSpacing.heading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(shelf.plan.title).font(.title3.bold()).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(shelf.plan.why.sentence).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(shelf.items) { item in
                        SmartArtwork(item: item).frame(width: 132, height: 176).clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topLeading) {
                                if bookmarks.contains(item.item.id) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.yellow).padding(6) }
                            }.contentShape(Rectangle())
                            .onTapGesture { open(item) }
                            .accessibilityAddTraits(.isButton).accessibilityAction { open(item) }
                            .accessibilityIdentifier("taste.shelf.\(item.item.id)")
                            .accessibilityLabel(item.gallery?.title ?? item.why?.label ?? L10n.text("Open"))
                            .smartHold(item, queue: env.readingQueue) { toggle(item) }
                            .overlay(alignment: .topTrailing) { RecommendationMenu(item: item, feedback: feedback, compact: true) }
                    }
                }.padding(.horizontal, 20)
            }.padding(.horizontal, -20)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("taste.shelf.\(shelf.plan.kind.rawValue)")
    }
}

struct SmartUndoBar: View {
    let undo: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.text("Hidden")).font(.subheadline).lineLimit(1)
            Spacer(minLength: 4)
            Button(L10n.text("Undo"), action: undo).font(.subheadline.bold()).accessibilityIdentifier("taste.undo")
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16).padding(.bottom, 74)
        .task { try? await Task.sleep(for: .seconds(6)); if !Task.isCancelled { close() } }
    }
}

/// Every reason behind one recommendation, with direct control over each of them.
struct RecommendationWhyView: View {
    let item: TasteRecommendation
    let mode: TasteMode
    let feed: TasteFeedState
    let refresh: () -> Void
    let moreLikeThis: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        SmartArtwork(item: item).frame(width: 84, height: 112).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 8) {
                            if let why = item.why { Label(why.label, systemImage: why.icon).font(.headline).foregroundStyle(TastePresentation.accent) }
                            Text(item.why?.sentence ?? L10n.text("Matches your saved works.")).font(.subheadline)
                        }
                    }.padding(.vertical, 4)
                }
                Section {
                    Button { dismiss(); moreLikeThis() } label: { Label(L10n.text("More like this"), systemImage: "square.on.square") }.accessibilityIdentifier("taste.why.more")
                    Button(role: .destructive) { feed.dismiss(item, mode: mode, env: env); dismiss() } label: { Label(L10n.text("Not interested"), systemImage: "hand.thumbsdown") }
                        .accessibilityIdentifier("taste.why.dismiss")
                }
                if !item.factors.isEmpty {
                    Section {
                        ForEach(item.factors) { factor in row(factor) }
                    } header: { Text(L10n.text("What counted")) }

                }
            }
            .navigationTitle(L10n.text("Why this recommendation?")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { dismiss() } } }
            .accessibilityElement(children: .contain).accessibilityIdentifier("taste.why")
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func row(_ factor: RecommendationFactor) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(RecapText.tag(factor.name)).font(.subheadline.weight(.medium)).lineLimit(1)
                GeometryReader { bar in
                    Capsule().fill(Color.secondary.opacity(0.15)).overlay(alignment: .leading) {
                        Capsule().fill(TastePresentation.accent).frame(width: max(4, bar.size.width * min(1, factor.strength)))
                    }
                }.frame(height: 4)
            }
            SmartBoostControl(key: factor.key, name: factor.name)
        }.padding(.vertical, 2)
    }
}

struct SmartBoostControl: View {
    let key: String
    let name: String
    @Environment(AppEnvironment.self) private var env
    private var value: Int { env.taste.control.boost(key) }
    var body: some View {
        HStack(spacing: 2) {
            button(-1, "minus", L10n.text("Show less of %@", RecapText.tag(name)))
            button(1, "plus", L10n.text("Show more of %@", RecapText.tag(name)))
        }
    }
    private func button(_ target: Int, _ icon: String, _ label: String) -> some View {
        Button { env.taste.change { $0.setBoost(value == target ? 0 : target, key: key) } } label: {
            Image(systemName: icon).font(.footnote.bold()).frame(width: 36, height: 36)
                .background(value == target ? TastePresentation.accent : Color.secondary.opacity(0.12), in: Circle())
                .foregroundStyle(value == target ? Color.white : Color.primary)
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(value == target ? .isSelected : [])
    }
}

/// Leaving the dashboard cancels its load, so evidence reads the profile itself
/// when the feed has nothing yet.
private struct TasteLiveEvidence: View {
    let feed: TasteFeedState
    let mode: TasteMode
    @Environment(AppEnvironment.self) private var env
    @State private var loaded: [TasteTag] = []
    var body: some View {
        TasteTagList(tags: feed.snapshot?.tags ?? loaded, mode: mode)
            .task { if feed.snapshot == nil, let value = try? await env.taste.snapshot(mode, period: .recommendations, offset: 0) { loaded = value.tags } }
    }
}

/// Everything the feed believes about a person, and the means to correct it.
struct TasteTunerView: View {
    let mode: TasteMode
    let feed: TasteFeedState
    let source: String
    let refresh: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var learning: TasteLearning?
    private var strongest: [TasteLearnedTag] {
        Array((learning?.ranked() ?? []).filter { env.taste.control.allows($0.name, source: $0.source, mode: mode) }.prefix(24))
    }
    private var peak: Double { max(0.001, strongest.first?.weight ?? 1) }
    private var steered: [String] { (env.taste.control.tasteBoosts ?? [:]).keys.sorted() }
    var body: some View {
        List {
            if !steered.isEmpty {
                Section(L10n.text("Your adjustments")) {
                    ForEach(steered, id: \.self) { key in
                        let name = key.components(separatedBy: "\n").last ?? key
                        HStack {
                            Text(RecapText.tag(name)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            SmartBoostControl(key: key, name: name)
                        }
                    }
                }
            }
            if let people = learning?.people.prefix(8), !people.isEmpty {
                Section(L10n.text("Artists you return to")) {
                    ForEach(Array(people)) { person in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RecapText.tag(person.name).capitalized).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(L10n.text("%@ saved works", String(person.saves))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SmartBoostControl(key: person.key, name: person.name)
                        }
                    }
                }
            }
            Section(L10n.text("What your feed has learned")) {
                if strongest.isEmpty { Text(L10n.text("Save a few works and your taste will appear here.")).foregroundStyle(.secondary) }
                ForEach(strongest) { tag in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(RecapText.tag(tag.name)).font(.subheadline.weight(.medium)).lineLimit(1)
                                if tag.recent >= 2 { Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange).accessibilityLabel(L10n.text("Rising lately")) }
                            }
                            GeometryReader { bar in
                                Capsule().fill(Color.secondary.opacity(0.15)).overlay(alignment: .leading) {
                                    Capsule().fill(TastePresentation.accent).frame(width: max(4, bar.size.width * tag.weight / peak))
                                }
                            }.frame(height: 4)
                        }
                        SmartBoostControl(key: tag.id, name: tag.name)
                    }.padding(.vertical, 2)
                }
            }
            Section {
                NavigationLink { TasteLiveEvidence(feed: feed, mode: mode) } label: { Label(L10n.text("Recommendation evidence"), systemImage: "list.bullet.rectangle") }
                    .accessibilityIdentifier("taste.evidence")
                NavigationLink { RecommendationSettingsView(mode: mode, initialSource: source) } label: { Label(L10n.text("Recommendation filters"), systemImage: "line.3.horizontal.decrease") }
            } footer: { Text(L10n.text("Recommendation searches send the selected tags to your connected websites. Your taste profile is not sent.")) }
        }
        .navigationTitle(L10n.text("Tune your taste")).navigationBarTitleDisplayMode(.inline)
        .tint(TastePresentation.accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("taste.tuner.view")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("Apply")) { refresh(); dismiss() }.fontWeight(.semibold).accessibilityIdentifier("taste.tuner.apply")
            }
        }
        .task { learning = feed.learning; if learning == nil { learning = try? await env.taste.learning(mode, hiddenComics: env.hiddenMangaGalleryIDs) } }
    }
}

extension View {
    /// Holding a recommended work bookmarks it; a comic can also be carried to Up Next.
    @ViewBuilder func smartHold(_ item: TasteRecommendation, queue: ReadingQueue, toggle: @escaping () -> Void) -> some View {
        if item.post == nil, let gallery = item.gallery {
            workHold(queue, item: {
                ReadingQueueItem(gallery: gallery, id: item.item.id, title: nil, artists: nil, language: nil, type: nil,
                                 site: ComicSites.active.isEmpty ? nil : ComicSites.active)
            }, cover: {
                gallery.pages.first.flatMap { TasteSources.images.cachedImage(hash: $0.hash, thumbnail: true) }
            }, bookmark: toggle)
        } else {
            holdToSave(toggle)
        }
    }
}
