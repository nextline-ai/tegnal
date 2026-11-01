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
            Image(systemName: "ellipsis").font(.system(size: compact ? 11 : 13, weight: .bold)).foregroundStyle(.white.opacity(compact ? 0.9 : 1))
                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28).background(.black.opacity(compact ? 0.32 : 0.55), in: Circle())
                .frame(width: 44, height: 44, alignment: compact ? .topTrailing : .center).padding(compact ? 5 : 0).contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.text("Recommendation options")).accessibilityIdentifier("taste.more.\(item.item.id)")
    }
}

/// How far the feed reaches, plus a temporary lens from today's strongest threads.
struct SmartSteering: View {
    let mode: TasteMode
    let feed: TasteFeedState
    let source: String
    let refresh: () -> Void
    let focus: (TasteFocus?) -> Void
    @Environment(AppEnvironment.self) private var env
    private var level: Int { env.taste.control.discoveryLevel ?? 1 }
    private var threads: [TasteLearnedTag] {
        guard let learning = feed.learning else { return [] }
        return Array(learning.recentTags.prefix(8))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("How far to reach"), selection: Binding(get: { level }, set: { value in
                env.taste.change { $0.discoveryLevel = value }; refresh()
            })) {
                Text(L10n.text("Familiar")).tag(0); Text(L10n.text("Balanced")).tag(1); Text(L10n.text("Adventurous")).tag(2)
            }.pickerStyle(.segmented).accessibilityIdentifier("taste.discovery")
            if let active = feed.focus {
                Button { focus(nil) } label: {
                    Label(L10n.text("Showing: %@", active.why.label), systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold)).lineLimit(1)
                }.buttonStyle(.bordered).tint(TastePresentation.accent).accessibilityIdentifier("taste.focus.clear")
            } else if !threads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(threads) { tag in
                            Button { focus(.init(seed: .init(source: tag.source, name: tag.name, general: tag.saves), why: .recent(tag.name))) } label: {
                                Text(RecapText.tag(tag.name)).font(.subheadline.weight(.medium)).lineLimit(1)
                                    .padding(.horizontal, 12).frame(minHeight: 36).background(.quaternary.opacity(0.5), in: Capsule())
                            }.buttonStyle(.plain).accessibilityHint(L10n.text("Shows only this for now")).accessibilityIdentifier("taste.thread.\(tag.name)")
                        }
                    }.padding(.horizontal, 20)
                }.padding(.horizontal, -20)
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

/// Today's top pick: the single best match, with its reason in plain words.
struct SmartHeroCard: View {
    let item: TasteRecommendation
    let open: () -> Void
    let toggle: () -> Void
    var isBookmarked = false
    let feedback: RecommendationFeedback
    @Environment(AppEnvironment.self) private var env
    private var mode: TasteMode { item.post == nil ? .comics : .booru }
    private var saved: Bool { item.post.map { env.booru.favoriteIDs.contains($0.id) } ?? isBookmarked }
    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                SmartArtwork(item: item, large: true).aspectRatio(1.05, contentMode: .fit).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("Today's pick")).font(RecapType.folio(11)).textCase(.uppercase).kerning(1.2).opacity(0.85)
                    if let title = item.gallery?.title { Text(title).font(RecapType.display(21, weight: .bold)).lineLimit(2) }
                    if let why = item.why { Text(why.sentence).font(.subheadline.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }.foregroundStyle(.white).padding(16).padding(.trailing, 28)
            }
            .overlay(alignment: .topLeading) {
                if saved { Image(systemName: "bookmark.fill").foregroundStyle(.yellow).padding(9).background(.black.opacity(0.6), in: Circle()).padding(10).accessibilityHidden(true) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20)).contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("taste.work.\(item.item.id)")
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in toggle() })
            .accessibilityValue(WorkSaveResult.accessibilityValue(saved: saved, mode: mode))
            .accessibilityAction(named: WorkSaveResult.actionTitle(saved: saved, mode: mode), toggle)
            .overlay(alignment: .topTrailing) { RecommendationMenu(item: item, feedback: feedback).padding(4) }
    }
}

struct SmartShelfView: View {
    let shelf: TasteShelf
    let open: (TasteRecommendation) -> Void
    let toggle: (TasteRecommendation) -> Void
    let bookmarks: Set<Int64>
    let feedback: RecommendationFeedback
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(shelf.plan.title, systemImage: shelf.plan.why.icon).font(.headline).lineLimit(1)
                Text(shelf.plan.why.sentence).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(shelf.items) { item in
                        Button { open(item) } label: {
                            SmartArtwork(item: item).frame(width: 128, height: 172).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topLeading) {
                                    if bookmarks.contains(item.item.id) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.yellow).padding(6) }
                                }.contentShape(Rectangle())
                        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("taste.shelf.\(item.item.id)")
                            .accessibilityLabel(item.gallery?.title ?? item.why?.label ?? L10n.text("Open"))
                            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in toggle(item) })
                            .overlay(alignment: .topTrailing) { RecommendationMenu(item: item, feedback: feedback, compact: true) }
                    }
                }.padding(.horizontal, 20)
            }.padding(.horizontal, -20)
        }.padding(.vertical, 4).accessibilityElement(children: .contain).accessibilityIdentifier("taste.shelf.\(shelf.plan.kind.rawValue)")
    }
}

struct SmartUndoBar: View {
    let undo: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.text("Hidden. Your next refresh will learn from this.")).font(.subheadline).lineLimit(2)
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
                      footer: { Text(L10n.text("Longer bars mean stronger, more recent evidence. Your changes apply on the next refresh.")) }
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

/// Everything the feed believes about a person, and the means to correct it.
struct TasteTunerView: View {
    let mode: TasteMode
    let feed: TasteFeedState
    let source: String
    let refresh: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var learning: TasteLearning?
    @State private var changed = false
    private var strongest: [TasteLearnedTag] { Array((learning?.ranked() ?? []).prefix(24)) }
    private var peak: Double { max(0.001, strongest.first?.weight ?? 1) }
    private var steered: [String] { (env.taste.control.tasteBoosts ?? [:]).keys.sorted() }
    var body: some View {
        List {
            Section {
                Picker(L10n.text("How far to reach"), selection: Binding(get: { env.taste.control.discoveryLevel ?? 1 }, set: { value in env.taste.change { $0.discoveryLevel = value }; changed = true })) {
                    Text(L10n.text("Familiar")).tag(0); Text(L10n.text("Balanced")).tag(1); Text(L10n.text("Adventurous")).tag(2)
                }.pickerStyle(.segmented)
            } header: { Text(L10n.text("How far to reach")) }
              footer: { Text(L10n.text("Recent saves count most, and older ones fade gradually. Long views and finished works count too. Opening a work briefly teaches nothing.")) }
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
                NavigationLink { TasteTagList(tags: feed.snapshot?.tags ?? [], mode: mode) } label: { Label(L10n.text("Recommendation evidence"), systemImage: "list.bullet.rectangle") }
                NavigationLink { RecommendationSettingsView(mode: mode, initialSource: source) } label: { Label(L10n.text("Recommendation filters"), systemImage: "line.3.horizontal.decrease") }
            }
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
