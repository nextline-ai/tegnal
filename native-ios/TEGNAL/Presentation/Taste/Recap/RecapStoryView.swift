import SwiftUI

struct RecapActions {
    var openWork: (RecapWork) -> Void
    var openTag: (RecapTag) -> Void
    var search: (String, String) -> Void
    var showSaved: () -> Void
    var share: () -> Void
    var replay: () -> Void
    var close: () -> Void
}

private struct RecapSearch: Identifiable { let query: String; let source: String; var id: String { source + query } }

/// A tap-through issue. Pages advance by themselves, stop while held or covered,
/// and never run on under VoiceOver, where the reader sets the pace.
struct RecapStoryView: View {
    let recap: TasteRecap
    let palette: RecapPalette
    @Environment(AppEnvironment.self) private var env
    @Environment(RecapArtwork.self) private var artwork
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var forward = true
    @State private var elapsed: TimeInterval = 0
    @State private var started: Date?
    @State private var holding = false
    @State private var pressed: Date?
    @State private var dragOffset: CGFloat = 0
    @State private var opened: TasteRecommendation?
    @State private var tag: TasteTag?
    @State private var search: RecapSearch?
    @State private var sharing = false
    @State private var browsing = false
    @FocusState private var focused: Bool
    private var pages: [RecapPage] { RecapPage.pages(for: recap) }
    private var page: RecapPage { pages[min(index, pages.count - 1)] }
    private var covered: Bool { opened != nil || tag != nil || search != nil || sharing || browsing }
    private var manual: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--recap-manual")
        #else
        return false
        #endif
    }
    private var playing: Bool { !manual && !holding && !covered && !voiceOver && scenePhase == .active && index < pages.count - 1 && dragOffset == 0 }
    private func duration(_ page: RecapPage) -> TimeInterval {
        switch page { case .cover: 4.5; case .chart, .rhythm, .persona: 9; case .palette: 6; default: 7 }
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 600, safe = geometry.safeAreaInsets
            let full = CGSize(width: geometry.size.width + safe.leading + safe.trailing, height: geometry.size.height + safe.top + safe.bottom)
            let size = compact ? full : CGSize(width: min(full.width, full.height * 0.62), height: full.height)
            ZStack {
                palette.ink.ignoresSafeArea()
                if !compact { RecapColorField(palette: palette).opacity(0.45).ignoresSafeArea() }
                ZStack {
                    RecapPageView(page: page, recap: recap, palette: palette, number: index + 1, total: pages.count, timeZone: RecapFormat.zone(env), safeArea: safe, actions: actions)
                        .id(page)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
                }
                .frame(width: size.width, height: size.height).clipped()
                .contentShape(Rectangle())
                .gesture(press(width: size.width))
                .position(x: geometry.size.width / 2, y: (geometry.size.height + safe.bottom - safe.top) / 2)
                chrome.frame(width: size.width, height: geometry.size.height)
            }
            .offset(y: dragOffset)
            .scaleEffect(1 - min(0.08, dragOffset / 3000))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .statusBarHidden(true).preferredColorScheme(.dark).tint(palette.accent)
        .persistentSystemOverlays(.hidden)
        .accessibilityElement(children: .contain).accessibilityIdentifier("recap.story")
        .accessibilityAction(.magicTap) { go(index + 1) }
        .sensoryFeedback(.selection, trigger: index)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { go(index + 1); return .handled }
        .onKeyPress(.leftArrow) { go(index - 1); return .handled }
        .onKeyPress(.space) { holding.toggle(); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task(id: "\(index):\(playing)") {
            guard playing else { return }
            let current = index, begin = Date()
            started = begin
            let remaining = duration(page) - elapsed
            do {
                try await Task.sleep(for: .seconds(max(0, remaining)))
                started = nil; go(index + 1)
            } catch {
                if index == current { elapsed += Date().timeIntervalSince(begin) }
                if started == begin { started = nil }
            }
        }
        .environment(\.booruBrowsingMode, env.mode)
        .tasteWorkPresentation($opened) { _ in .init(origin: .library) }
        .appSheet(item: $tag) { tag in
            NavigationStack {
                TasteTagDetail(tag: tag, mode: recap.mode).toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { self.tag = nil } } }
            }
        }
        .appSheet(item: $search) { search in searchSheet(search) }
        .appSheet(isPresented: $sharing) { RecapShareView(recap: recap, palette: palette) }
        .appSheet(isPresented: $browsing) {
            NavigationStack {
                RecapWorksView(recap: recap, palette: palette).environment(artwork)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { browsing = false } } }
            }
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(pages.indices, id: \.self) { position in
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing || position != index)) { context in
                        let live = started.map { context.date.timeIntervalSince($0) } ?? 0
                        let fraction = position < index ? 1 : position > index ? 0 : playing || holding ? min(1, (elapsed + live) / duration(page)) : position == pages.count - 1 ? 1 : elapsed / duration(page)
                        GeometryReader { bar in
                            Capsule().fill(.white.opacity(0.28)).overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: bar.size.width * fraction)
                            }
                        }
                    }.frame(height: 2.5)
                }
            }.padding(.horizontal, 12).padding(.top, 10).accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: "RECAP").font(RecapType.display(15)).foregroundStyle(.white)
                Text(RecapFormat.title(recap, timeZone: RecapFormat.zone(env))).font(RecapType.folio(11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Spacer()
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up").recapChrome() }
                    .accessibilityLabel(L10n.text("Share")).accessibilityIdentifier("recap.story.share")
                Button { dismiss() } label: { Image(systemName: "xmark").recapChrome() }
                    .accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("recap.story.close")
            }.padding(.leading, 14).padding(.trailing, 6).padding(.top, 2)
            Spacer()
            if voiceOver || index < pages.count - 1 {
                HStack {
                    Spacer()
                    Button { go(index - 1) } label: { Image(systemName: "chevron.left").recapChrome() }
                        .disabled(index == 0).accessibilityLabel(L10n.text("Previous card")).opacity(index == 0 ? 0.35 : 1)
                    Button { go(index + 1) } label: { Image(systemName: "chevron.right").recapChrome() }
                        .accessibilityLabel(L10n.text("Next card")).accessibilityIdentifier("recap.story.next")
                }.padding(.horizontal, 8).padding(.bottom, 8).colorMultiply(page == .persona ? palette.paperInk : .white)
            }
        }
    }

    private func press(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressed == nil {
                    pressed = value.time
                    let begin = value.time
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        if pressed == begin { holding = true }
                    }
                }
                if value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) { dragOffset = value.translation.height }
            }
            .onEnded { value in
                let quick = value.time.timeIntervalSince(pressed ?? value.time) < 0.25
                let moved = max(abs(value.translation.width), abs(value.translation.height))
                pressed = nil; holding = false
                if dragOffset > 110 || value.predictedEndTranslation.height > 320 { dismiss(); return }
                if dragOffset != 0 { withAnimation(.spring(duration: 0.3)) { dragOffset = 0 } }
                if moved < 12 { if quick { go(value.location.x < width * 0.28 ? index - 1 : index + 1) } }
                else if abs(value.translation.width) > 50 { go(value.translation.width < 0 ? index + 1 : index - 1) }
            }
    }
    private func go(_ target: Int) {
        guard pages.indices.contains(target), target != index else { return }
        forward = target > index; elapsed = 0; started = nil
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.08)) { index = target }
    }
    private var actions: RecapActions {
        .init(openWork: open, openTag: { tag = detail($0) }, search: { search = .init(query: $0, source: $1) },
              showSaved: { browsing = true }, share: { sharing = true }, replay: { go(0) }, close: { dismiss() })
    }
    private func open(_ work: RecapWork) {
        guard !recap.isSample else { return }
        opened = .init(item: work.item, post: artwork.post(work), gallery: nil, reason: TasteTag(source: work.item.source, name: recap.tags.first?.name ?? ""), score: 0)
    }
    private func detail(_ tag: RecapTag) -> TasteTag? {
        guard !recap.isSample else { return nil }
        let works = recap.saved.filter { tag.works.contains($0.id) }.map(\.item)
        return .init(source: tag.source, name: tag.name, confirmed: tag.confirmed, hidden: tag.hidden, general: max(0, tag.count - tag.confirmed - tag.hidden), sessions: tag.sessions, works: works)
    }
    @ViewBuilder private func searchSheet(_ search: RecapSearch) -> some View {
        if recap.mode == .booru, let server = env.booru.servers.first(where: { $0.canonicalAddress == search.source }) {
            NavigationStack {
                BooruFeedView(server: server, source: TasteSources.booru, initialQuery: search.query)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { self.search = nil } } }
            }.environment(env.booru).environment(\.discoveryContext, DiscoveryContext(origin: .recommendation))
        } else if recap.mode == .comics, env.isSiteVerified {
            NativeContentView(source: TasteSources.comic, initialQuery: search.query).environment(\.discoveryContext, DiscoveryContext(origin: .recommendation))
        } else {
            NavigationStack {
                ContentUnavailableView(L10n.text("Connect this source in Settings to explore this tag."), systemImage: "link")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("Done")) { self.search = nil } } }
            }
        }
    }
}

private extension Image {
    func recapChrome() -> some View {
        font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
            .shadow(color: .black.opacity(0.35), radius: 4)
    }
}
