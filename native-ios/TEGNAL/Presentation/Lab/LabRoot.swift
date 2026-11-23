import SwiftUI

/// The lab's tabs. `courses` lists the courses, the 2D AI course among them; `sheet` stands apart at the right end of the dock.
enum LabTab: String, Hashable {
    case deck, fails, courses, shop, sheet
    static let coursesSymbol = "square.stack.3d.up.fill"

    /// The role that gives a tab the separate glass circle at the trailing end of the bar: iOS 26's search role, iOS 27's
    /// prominent one. Nil before iOS 26, where no such place exists.
    @available(iOS 18.0, *)
    static var trailingRole: TabRole? {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        if #available(iOS 26.0, *) { return .search }
        return nil
    }
}

/// The deck engine: AI 실험실, and every imported deck course on the same screens (without the AI lab's cheat sheet and diagnosis).
/// The stock tab bar and navigation stacks; the cards, paper and gauges are the lab's own.
/// The way back to the home scene is the swipe up from the bottom, as everywhere in learning mode.
struct LabRoot: View {
    @Environment(BooruStore.self) private var booru
    @State private var mode = StudyMode.shared
    @State private var store = LabStore.shared
    @State private var playing: LabEpisode?
    @State private var diagnosing = false
    /// Told once to a learner who studied 2D AI 배우기 before it was sold: what it paid, and that it now opens from the shop.
    @State private var legacy: (gems: Int, lessons: Int)?
    /// A 망작 opened from the gallery, shown over everything, dock included.
    @State private var revealing: LabFail?

    var body: some View {
        tabs
            .overlay {
                if let revealing { LabFailReveal(fail: revealing, won: false) { self.revealing = nil }.id(revealing.id) }
            }
            .labLines()
            .appFullScreenCover(item: $playing) { LabEpisodeView(episode: $0) }
            .appFullScreenCover(isPresented: $diagnosing) { LabDiagnosisView() }
            .alert(L10n.text("lab.legacy.title"), isPresented: Binding(get: { legacy != nil }, set: { if !$0 { legacy = nil } })) {
                Button(L10n.text("lab.legacy.open")) { mode.labTab = .courses; legacy = nil; greet() }
                Button(L10n.text("OK"), role: .cancel) { legacy = nil; greet() }
            } message: {
                if let legacy { Text(L10n.text("lab.legacy.message", String(legacy.lessons), String(legacy.gems))) }
            }
            .onAppear {
                store.reload()
                countCourses()
                greet()
            }
            .onChange(of: booru.revision) { countCourses() }
            .onChange(of: HomeStage.shared.coversScreen) { _, _ in countCourses(); greet() }
            .task {
                if let edition = await LabSheetSource.fetch() { store.show(edition) }
            }
    }

    @ViewBuilder private var tabs: some View {
        let deck = NavigationStack { LabDeckView(play: { playing = $0 }, diagnose: { diagnosing = true }, covered: playing != nil) }
        let fails = NavigationStack { LabFailsView(play: { playing = $0 }, open: { revealing = $0 }) }
        let courses = NavigationStack { LabCoursesView() }
        let shop = NavigationStack { LabShopView() }
        let sheet = NavigationStack { LabSheetView() }
        let newEdition: Text? = store.editionWaiting ? Text(L10n.text("lab.new")) : nil
        if #available(iOS 18.0, *) {
            TabView(selection: $mode.labTab) {
                Tab(L10n.text("lab.tab.deck"), systemImage: "rectangle.stack.fill", value: LabTab.deck) { deck }
                Tab(L10n.text("lab.tab.fails"), systemImage: "photo.fill", value: LabTab.fails) { fails }
                Tab(L10n.text("lab.tab.courses"), systemImage: LabTab.coursesSymbol, value: LabTab.courses) { courses }
                Tab(L10n.text("lab.tab.shop"), systemImage: "bag.fill", value: LabTab.shop) { shop }
                // Like Smart in viewing mode: the cheat sheet stands apart at the right end of the dock. It is the AI lab's own.
                if !store.course.imported {
                    Tab(L10n.text("lab.tab.sheet"), systemImage: "doc.text.fill", value: LabTab.sheet, role: LabTab.trailingRole) { sheet }
                        .badge(newEdition)
                }
            }
        } else {
            TabView(selection: $mode.labTab) {
                deck.tabItem { Label(L10n.text("lab.tab.deck"), systemImage: "rectangle.stack.fill") }.tag(LabTab.deck)
                fails.tabItem { Label(L10n.text("lab.tab.fails"), systemImage: "photo.fill") }.tag(LabTab.fails)
                courses.tabItem { Label(L10n.text("lab.tab.courses"), systemImage: LabTab.coursesSymbol) }.tag(LabTab.courses)
                shop.tabItem { Label(L10n.text("lab.tab.shop"), systemImage: "bag.fill") }.tag(LabTab.shop)
                if !store.course.imported {
                    sheet.tabItem { Label(L10n.text("lab.tab.sheet"), systemImage: "doc.text.fill") }.tag(LabTab.sheet).badge(newEdition)
                }
            }
        }
    }

    /// Lessons of the 2D course finished so far, which pay once the course is bought. A learner who studied tags before the lab keeps it.
    private func countCourses() {
        store.settleTagCourse(in: booru.studyStore)
        // Told once the home scene has gone, before the welcome check.
        if store.owesLegacyNotice, !HomeStage.shared.coversScreen {
            legacy = store.tagCoursePaid
            store.noticeLegacy()
        }
    }

    /// A first visit begins with the one-minute check, once the home scene has gone.
    private func greet() {
        guard !store.progress.greeted, store.offersDiagnosis, !HomeStage.shared.coversScreen, !diagnosing, legacy == nil, !store.owesLegacyNotice else { return }
        store.greeted()
        Task { try? await Task.sleep(for: .milliseconds(400)); diagnosing = true }
    }
}

// MARK: - The deck

/// The deck: home and collection at once, as a wallet of cards. Engraved cards stack at the top with their number, name and line;
/// the next blank card lies in front; locked ones wait below with only their titles.
struct LabDeckView: View {
    let play: (LabEpisode) -> Void
    let diagnose: () -> Void
    /// True while an episode is open over the deck. A card engraved there slides into the stack once the deck is seen again.
    let covered: Bool
    @State private var store = LabStore.shared
    @State private var showingType = false
    /// The engraved cards the deck shows. It catches up with the store after an episode closes, so the new card can be seen arriving.
    @State private var shown: Set<String> = []
    /// The folded pile at the back of the stack, fanned out by a tap.
    @State private var fanned = false
    /// The card just engraved, shown in its colours where the blank card lay, before it goes into the stack.
    @State private var arriving: String?
    /// The front card's height as laid out, and whether it is held there, so it can shrink smoothly to a card's size.
    @State private var frontHeight: CGFloat = 290
    @State private var pinned = false
    @Namespace private var space

    private static let earnedHeight: CGFloat = 200
    private static let lockedPeek: CGFloat = 44
    private static let lockedHeight: CGFloat = 120

    /// How far back a card in the stack sits: 1 just behind the blank card, more further up. One rule runs from the front of
    /// the stack to the back, with no step anywhere: each card is a little smaller, shows a little less of itself, and is a
    /// little fainter than the one in front, as things further off are. Lines further back may be cut through; the deck
    /// reads as leaning away into the distance and never grows past about four strips' height, however many cards it holds.
    /// Shrinks quickly near the front and ever more slowly further back, towards 74%.
    private static func scale(_ depth: Int) -> CGFloat { 0.74 + 0.26 * pow(0.8, CGFloat(depth)) }
    /// From the card's top edge to the foot of its line: padding, the number row, the gap, one line of the serif at 130%.
    private static let stripContent: CGFloat = 14 + 14 + 6 + 21
    /// The card just behind the blank one shows its whole strip; each card behind shows 74% of what the one in front shows.
    private static let front: CGFloat = 64
    private static let recede: CGFloat = 0.74
    /// Fanned out, every card shows its whole strip.
    private func peek(_ depth: Int) -> CGFloat {
        fanned ? (Self.stripContent * Self.scale(depth)).rounded() + 8 : Self.front * pow(Self.recede, CGFloat(depth - 1))
    }
    /// So far back that it would show less than a hairline: left out until the deck is fanned.
    private func hidden(_ depth: Int) -> Bool { peek(depth) < 1.5 }
    /// Too little of it shows to read or aim at: a tap fans the deck out rather than opening the card.
    private func compact(_ depth: Int) -> Bool { !fanned && peek(depth) < 40 }
    private func shownHeight(_ depth: Int) -> CGFloat { hidden(depth) ? 0 : peek(depth) }
    /// How far a card has faded into the page: none just behind the blank card, a little more for each step back.
    /// Fanned out, the cards stay readable, so they fade less.
    private func fade(_ depth: Int) -> Double { min(fanned ? 0.4 : 0.8, 1 - pow(0.84, Double(depth - 1))) }
    /// And it softens a little for each step back, past the first two.
    private func blur(_ depth: Int) -> CGFloat { fanned ? 0 : min(2.5, max(0, 0.45 * CGFloat(depth - 2))) }
    private func fan(_ open: Bool) {
        LabHaptic.tick()
        withAnimation(.spring(duration: 0.55, bounce: 0.18)) { fanned = open }
    }

    var body: some View {
        let course = store.course
        let earned = course.episodes.filter { shown.contains($0.id) }
        let next = course.episodes.first { !shown.contains($0.id) && store.state($0) != .locked }
        let waiting = Array(course.episodes.filter { !shown.contains($0.id) && $0.id != next?.id }.prefix(3))
        let rate = course.base + earned.reduce(0) { $0 + $1.impact }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LabHeader(kicker: kicker(next ?? earned.last), title: L10n.text("lab.deck.title"), below: true) {
                    LabRing(value: rate)
                        .accessibilityElement().accessibilityLabel(course.info.gauge.text).accessibilityValue("\(rate)%")
                        .accessibilityIdentifier("lab.rate")
                }
                LabSeasonTrack(course: course, shown: shown, current: (next ?? earned.last).flatMap(course.season))
                let stacked = earned.count + (store.offersDiagnosis ? 1 : 0)
                VStack(spacing: 0) {
                    if stacked > 2 {
                        Button { fan(!fanned) } label: {
                            Label(fanned ? L10n.text("lab.deck.fold") : L10n.text("lab.deck.unfold", String(stacked)),
                                  systemImage: fanned ? "chevron.up" : "chevron.down")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("lab.deck.fan")
                    }
                    VStack(spacing: 0) {
                        typeCard(depth: earned.count + 1)
                        ForEach(Array(earned.enumerated()), id: \.element.id) { index, episode in
                            // Fanned out, each season's cards sit under its own heading.
                            if fanned, let season = course.season(of: episode), index == 0 || course.season(of: earned[index - 1]) != season {
                                seasonHeading(season).transition(.opacity)
                            }
                            NavigationLink(value: episode.id) {
                                band(depth: earned.count - index) {
                                    LabCardFace(serial: episode.serial, title: episode.title.text, line: episode.card.line.text, color: course.color(episode),
                                                state: .earned, label: episode.label, top: true)
                                }
                            }
                            .buttonStyle(LabPressStyle())
                            .matchedTransitionSourceIfAvailable(id: episode.id, in: space)
                            // Taken over from the coloured card in front, at its size: no jump as it becomes the nearest strip.
                            .transition(.asymmetric(insertion: .scale(scale: 1 / Self.scale(1), anchor: .top), removal: .opacity))
                            .accessibilityIdentifier("lab.deck.earned.\(episode.id)")
                        }
                        if let next {
                            frontCard(next)
                                .id(next.id)
                                // The next blank card rises from below, over the locked ones, and covers the one just engraved,
                                // tucking it into the stack.
                                .transition(.asymmetric(insertion: .offset(y: 300), removal: .identity))
                        } else {
                            finished.transition(.asymmetric(insertion: .offset(y: 300), removal: .identity))
                        }
                    }
                    .zIndex(1)
                    if !waiting.isEmpty {
                        VStack(spacing: Self.lockedPeek - Self.lockedHeight) {
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { offset, episode in
                                let before = offset == 0 ? next : waiting[offset - 1]
                                let season = course.season(of: episode)
                                HStack(spacing: 8) {
                                    // A locked card that opens a new season carries its season's name.
                                    if let season, before.flatMap(course.season) != season {
                                        Text(L10n.text("lab.season", String(season.number)))
                                            .font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 2)
                                            .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1) }
                                    }
                                    Text(episode.digits + " · " + episode.title.text).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(L10n.text("lab.card.locked"))
                                }
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 18).padding(.top, 13)
                                .frame(maxWidth: .infinity, minHeight: Self.lockedHeight, maxHeight: Self.lockedHeight, alignment: .topLeading)
                                .background { LabCardBackground(state: .locked, radius: 18, step: offset) }
                                .labCardShadow(.black.opacity(offset == 0 ? 0 : 0.4), radius: 8, y: -6)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("lab.deck.locked.\(episode.id)")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in
            if let episode = course.episode(id) {
                LabCardDetailView(episode: episode, play: play).navigationZoomIfAvailable(id: id, in: space)
            }
        }
        .appSheet(isPresented: $showingType) { LabTypeSheet(diagnose: diagnose) }
        .onAppear { if !covered { shown = store.earnedIDs } }
        .onChange(of: covered) { _, covered in
            guard !covered else { return }
            // The cover has gone. The blank card in front comes up in its engraved colours, settling to a card's size; then the
            // next blank card rises over it from below, tucking it into the stack as the cards behind lean one step further back,
            // and the ring climbs.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                let all = store.earnedIDs
                let added = all.subtracting(shown)
                guard added.count == 1, let id = added.first, store.course.episodes.first(where: { !shown.contains($0.id) })?.id == id else {
                    withAnimation(.spring(duration: 0.75, bounce: 0.1)) { shown = all }
                    return
                }
                // The front card is held at the height it has now, so its shrink to a card's size can be animated.
                pinned = true
                try? await Task.sleep(for: .milliseconds(30))
                LabHaptic.tick()
                withAnimation(.spring(duration: 0.55, bounce: 0.06)) { arriving = id }
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.spring(duration: 0.65, bounce: 0.08)) {
                    shown = all
                    arriving = nil
                    pinned = false
                }
                LabHaptic.snap()
            }
        }
        .onChange(of: store.earnedIDs.count) { if !covered { withAnimation(.spring(duration: 0.6)) { shown = store.earnedIDs } } }
    }

    /// A season's name over its cards, when the deck is fanned out.
    private func seasonHeading(_ season: LabSeason) -> some View {
        HStack(spacing: 8) {
            Text(L10n.text("lab.season", String(season.number))).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            Text(season.title.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).lineLimit(1)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
        .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 10)
        // The page's own background, so the heading cuts cleanly across the foot of the card above it.
        .background(Color(uiColor: .systemBackground))
        .accessibilityAddTraits(.isHeader)
    }

    /// "시즌 1 · 3/15", under the title.
    private func kicker(_ episode: LabEpisode?) -> Text {
        let season = episode.flatMap { store.course.season(of: $0) }?.number ?? 1
        return Text(L10n.text("lab.season", String(season)) + " · ")
            + Text("\(shown.count)/\(store.course.episodes.count)").font(LabFont.number(13))
    }

    /// A card further up the stack: smaller and fainter the further back it sits, and only its top showing above the card in front.
    private func band<Card: View>(depth: Int, @ViewBuilder _ card: () -> Card) -> some View {
        card()
            .frame(height: Self.earnedHeight)
            // The page's own background laid over the card: it fades into the distance in light and dark appearance alike.
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(fade(depth))).allowsHitTesting(false) }
            .labCardShadow(.black.opacity(0.32 * (1 - fade(depth) * 0.6)), radius: 10, y: -6)
            .blur(radius: blur(depth))
            .scaleEffect(Self.scale(depth), anchor: .top)
            .frame(height: shownHeight(depth), alignment: .top)
            .opacity(hidden(depth) ? 0 : 1)
            // A strip too thin to read fans the deck out rather than opening its card.
            .overlay {
                if compact(depth) { Color.clear.contentShape(Rectangle()).onTapGesture { fan(true) } }
            }
            .accessibilityHidden(hidden(depth))
    }

    /// Card No. 000: the learner's type, or the paper card that invites the check. It sits at the back of the stack.
    @ViewBuilder private func typeCard(depth: Int) -> some View {
        if !store.offersDiagnosis {
            EmptyView()
        } else if let type = store.type {
            Button { showingType = true } label: {
                band(depth: depth) {
                    LabCardFace(serial: "No. 000", title: type.name.text, line: type.name.text, color: LabPalette.ink, state: .earned,
                                label: L10n.text("lab.type.label"), top: true)
                }
            }
            .buttonStyle(LabPressStyle()).accessibilityIdentifier("lab.deck.type")
        } else {
            Button(action: diagnose) {
                band(depth: depth) {
                    LabCardFace(serial: "No. 000 · " + L10n.text("lab.card.blank"), title: L10n.text("lab.deck.diagnose"), state: .blank, top: true)
                }
            }
            .buttonStyle(LabPressStyle()).accessibilityIdentifier("lab.deck.diagnose")
        }
    }

    /// The card in front: the next blank card or, just after it was engraved, the same card in its colours, which fades in
    /// over the paper while the card shrinks to the size of the cards in the stack it is about to join.
    private func frontCard(_ episode: LabEpisode) -> some View {
        let coloured = arriving == episode.id
        return ZStack(alignment: .top) {
            nextCard(episode).opacity(coloured ? 0 : 1)
            LabCardFace(serial: episode.serial, title: episode.title.text, line: episode.card.line.text, color: store.course.color(episode),
                        state: .earned, label: episode.label, top: true)
                .frame(maxHeight: .infinity)
                .opacity(coloured ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(!coloured)
        }
        .frame(height: coloured ? Self.earnedHeight : pinned ? frontHeight : nil, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !pinned { frontHeight = $0 } }
        // While it shrinks, the paper below the new edge is cut off; above and beside, its shadow still falls.
        .mask { Rectangle().padding(.top, -60).padding(.horizontal, -60) }
    }

    private func nextCard(_ episode: LabEpisode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(episode.serial + " · " + L10n.text("lab.card.blank"))
                Spacer()
                Text(L10n.text("lab.card.minutes", "3"))
            }
            .font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(LabPalette.paperMuted)
            Spacer(minLength: 18)
            VStack(alignment: .leading, spacing: 10) {
                Text(episode.title.text).font(LabFont.voice(28)).tracking(-0.6).foregroundStyle(LabPalette.paperInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lab.deck.next.title")
                if let teaser = episode.teaser {
                    Text(teaser.text).font(.system(size: 14)).labSpacing(2).foregroundStyle(LabPalette.paperMuted).fixedSize(horizontal: false, vertical: true)
                }
                LabDashedRule(color: LabPalette.paperRule)
            }
            Spacer(minLength: 18)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    (Text((store.course.imported ? L10n.text("lab.card.impactOf", store.course.info.gauge.text) : L10n.text("lab.card.impact")) + " ") + Text("+\(episode.impact)%").font(LabFont.number(11)).foregroundColor(LabPalette.paperInk))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(LabPalette.paperMuted)
                    LabImpactPips(impact: episode.impact)
                }
                Spacer()
                Button { play(episode) } label: { Text(L10n.text("lab.card.start")).font(.system(size: 15, weight: .bold)).padding(.horizontal, 10) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(LabPalette.paperInk)
                    .accessibilityIdentifier("lab.deck.start")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(minHeight: 290)
        .background { LabCardBackground(state: .blank, radius: 20) }
        .labCardShadow(.black.opacity(0.45), radius: 12, y: -10)
        .environment(\.colorScheme, .light)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("lab.deck.complete")).font(LabFont.voice(24)).foregroundStyle(LabPalette.paperInk)
            Text(L10n.text("lab.deck.completeNote")).font(.system(size: 14)).foregroundStyle(LabPalette.paperMuted)
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 200, alignment: .bottomLeading)
        .background { LabCardBackground(state: .blank, radius: 20) }
        .labCardShadow(.black.opacity(0.45), radius: 12, y: -10)
    }
}

extension View {
    /// The card a detail page grows out of (iOS 18 and later).
    @ViewBuilder func matchedTransitionSourceIfAvailable(id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: space) } else { self }
    }
    /// A detail page that grows out of its card and shrinks back into it (iOS 18 and later).
    @ViewBuilder func navigationZoomIfAvailable(id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: space)) } else { self }
    }
}

/// How much a card adds, as five short bars.
struct LabImpactPips: View {
    let impact: Int
    var body: some View {
        let filled = impact >= 12 ? 5 : impact >= 9 ? 4 : impact >= 6 ? 3 : impact >= 3 ? 2 : 1
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule().fill(index < filled ? LabPalette.paperInk : LabPalette.paperRule.opacity(0.4)).frame(width: 14, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The back of a card

/// An engraved card turned over: how to use it, the text to copy, the sheet it opened, its 망작, and playing it again.
struct LabCardDetailView: View {
    let episode: LabEpisode
    let play: (LabEpisode) -> Void
    @State private var store = LabStore.shared
    @State private var mode = StudyMode.shared

    var body: some View {
        let fails = episode.fails
        let sections = store.edition?.sections.filter { $0.opens == episode.id } ?? []
        let season = store.course.season(of: episode)
        List {
            Section {
                LabCardFace(serial: episode.serial, title: episode.title.text, line: episode.card.line.text, color: store.course.color(episode), state: .earned,
                            footer: [episode.label, season.map { L10n.text("lab.season", String($0.number)) }].compactMap { $0 }.joined(separator: " · "),
                            date: store.engraved(episode)?.labStamp, large: true)
                    .frame(width: 280, height: 352).frame(maxWidth: .infinity)
                    .labCardShadow(Color(labHex: store.course.color(episode)).opacity(0.45), radius: 24, y: 14)
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            Section(L10n.text("lab.card.uses")) {
                ForEach(episode.card.uses.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1)).font(LabFont.number(13)).foregroundStyle(LabPalette.gauge)
                        Text(episode.card.uses[index].text)
                    }
                }
            }
            if let copy = episode.card.copy {
                Section {
                    Text(copy.text).font(.system(size: 15)).textSelection(.enabled)
                    LabCopyButton(text: copy.text)
                } header: { Text(L10n.text("lab.card.copy")) } footer: { Text(L10n.text("lab.card.copyNote")) }
            }
            Section {
                ForEach(sections) { section in
                    Button { mode.labTab = .sheet } label: {
                        LabRow(title: L10n.text("lab.card.opened"), detail: section.title.text, value: store.edition.map { L10n.text("lab.sheet.stamp", $0.stamp) })
                    }
                }
                Button { mode.labTab = .fails } label: {
                    LabRow(title: L10n.text("lab.tab.fails"), detail: nil, value: "\(fails.filter(store.hung).count)/\(fails.count)")
                }
                .accessibilityIdentifier("lab.card.fails")
            }
            Section {
                Button { play(episode) } label: { Label(L10n.text("lab.card.again"), systemImage: "arrow.counterclockwise") }
                    .accessibilityIdentifier("lab.card.again")
            }
        }
        .navigationTitle("\(episode.number) / \(store.course.episodes.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { LabShareCard(episode: episode) } }
    }
}

/// A list row with a title, a quiet detail and a value at the end.
struct LabRow: View {
    let title: String
    var detail: String?
    var value: String?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            Spacer()
            if let value { Text(value).font(LabFont.number(13)).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The seasons side by side under the deck's title: one bar per season, as long as it has cards and filled as far as they are
/// engraved, the season in play picked out, with its name below. Seasons read as chapters of their own.
struct LabSeasonTrack: View {
    let course: LabCourse
    let shown: Set<String>
    let current: LabSeason?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let total = CGFloat(max(1, course.episodes.count))
                let room = proxy.size.width - 5 * CGFloat(max(0, course.seasons.count - 1))
                HStack(spacing: 5) {
                    ForEach(course.seasons) { season in
                        let done = season.episodes.filter(shown.contains).count
                        let here = season == current
                        let width = room * CGFloat(season.episodes.count) / total
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(here ? 0.3 : 0.16))
                            Capsule().fill(done == season.episodes.count ? LabPalette.pass : Color.primary)
                                .frame(width: width * CGFloat(done) / CGFloat(max(1, season.episodes.count)))
                        }
                        .frame(width: width, height: here ? 6 : 4)
                        .accessibilityElement()
                        .accessibilityLabel(L10n.text("lab.season", String(season.number)) + " · " + season.title.text)
                        .accessibilityValue("\(done)/\(season.episodes.count)")
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 6)
            if let current {
                Text(current.title.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("lab.season.current")
            }
        }
        .animation(.spring(duration: 0.6), value: shown)
    }
}
