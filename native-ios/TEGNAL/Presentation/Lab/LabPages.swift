import SwiftUI

// MARK: - Cheat sheet

/// The cheat sheet: what to use for which job right now, swapped whenever the field changes. Cards 001 and 004 open its sections.
///
/// Read in one order: the page and the day it was curated (a red stamp beside the title), what changed, then each question
/// as a grid of tiles. On a tile the answer, the pick, is the largest thing; the job is its label and the reason one quiet line.
/// The example, the longer story, tips, a prompt and the other picks wait one tap away.
struct LabSheetView: View {
    @State private var store = LabStore.shared
    @State private var paid = 0
    @State private var mode = StudyMode.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    LabHeader(kicker: Text(L10n.text("lab.sheet.subtitle")), title: L10n.text("lab.tab.sheet")) {
                        if let edition = store.edition { LabSheetStamp(edition: edition) }
                    }
                    if let change = store.edition?.change {
                        Label { Text(change.text) } icon: { Image(systemName: "sparkles") }
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("lab.sheet.change")
                    }
                    if paid > 0 {
                        LabTag(text: L10n.text("lab.sheet.paid", String(paid), store.shop.currency.text), color: LabPalette.gauge)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityIdentifier("lab.sheet.paid")
                    }
                }
                if let edition = store.edition { LabSheetBoard(edition: edition) } else {
                    ContentUnavailableView(L10n.text("lab.sheet.none"), systemImage: "doc.text")
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { if let edition = await LabSheetSource.fetch() { store.show(edition) } }
        .onAppear { readIfShown() }
        .onChange(of: mode.labTab) { readIfShown() }
        .onChange(of: store.edition?.id) { readIfShown() }
    }

    private func readIfShown() {
        guard mode.labTab == .sheet else { return }
        let amount = store.read()
        if amount > 0 { withAnimation(.spring(duration: 0.5)) { paid = amount } }
    }
}

/// The day the sheet was curated, as a small red rubber stamp beside the title.
struct LabSheetStamp: View {
    let edition: LabEdition
    var body: some View {
        let red = Color(labHex: "D0432A")
        VStack(spacing: 1) {
            Text(L10n.text("lab.sheet.basis")).font(.system(size: 9, weight: .heavy)).tracking(1)
            Text(edition.stamp).font(LabFont.number(13))
        }
        .foregroundStyle(red)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(red, lineWidth: 1.4) }
        .rotationEffect(.degrees(-4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("lab.sheet.stamp", edition.stamp))
        .accessibilityIdentifier("lab.sheet.stamp")
    }
}

/// The sheet's questions, each a grid of tiles two across. A question no card has opened yet shows its jobs with the picks
/// held back, and which card opens them.
struct LabSheetBoard: View {
    let edition: LabEdition
    private var store: LabStore { .shared }
    @State private var opened: LabSheetRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(edition.sections) { section in sectionView(section) }
            if let footer = edition.footer {
                Label { Text(footer.text) } icon: { Image(systemName: "info.circle") }
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $opened) { row in LabSheetRowDetail(row: row) }
    }

    private func sectionView(_ section: LabSheetSection) -> some View {
        let open = store.opened(section)
        let card = section.opens.flatMap(store.main.episode)
        let rows = Array(section.rows.enumerated())
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title.text).font(.system(size: 20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let card {
                    Label(L10n.text(open ? "lab.sheet.openedBy" : "lab.sheet.locked", card.digits), systemImage: open ? "key.fill" : "lock.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(open ? AnyShapeStyle(.secondary) : AnyShapeStyle(LabPalette.fail))
                        .accessibilityIdentifier(open ? "" : "lab.sheet.locked.\(section.id)")
                }
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    GridRow {
                        ForEach(pair, id: \.offset) { index, row in
                            if open {
                                Button { LabHaptic.tick(); opened = row } label: { tile(row, open: true) }
                                    .buttonStyle(LabPressStyle())
                                    .accessibilityHint(L10n.text("lab.sheet.more"))
                                    .accessibilityIdentifier("lab.sheet.row.\(section.id).\(index)")
                            } else {
                                tile(row, open: false).accessibilityHidden(true)
                            }
                        }
                        if pair.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(open ? "lab.sheet.section.\(section.id)" : "")
        }
    }

    /// One job: its symbol and name as the label, the pick large, the reason in a line or two.
    private func tile(_ row: LabSheetRow, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: LabSheetRowDetail.symbol(row)).font(.system(size: 12, weight: .bold)).foregroundStyle(LabPalette.gauge)
                Text(row.task.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if open, row.draft == true { LabSheetDraftMark() }
            }
            Group {
                if open {
                    Text(row.pick).font(.system(size: 21, weight: .bold)).foregroundStyle(.primary).lineLimit(2).minimumScaleFactor(0.8)
                    if let why = row.why { Text(why.text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2) }
                } else {
                    // Held back until its card is engraved.
                    Capsule().fill(Color.secondary.opacity(0.22)).frame(width: 84, height: 18).padding(.vertical, 4)
                    Capsule().fill(Color.secondary.opacity(0.14)).frame(width: 120, height: 10)
                }
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if !open { Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary).padding(12) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "초안": a pick not settled yet.
struct LabSheetDraftMark: View {
    var body: some View {
        Text(L10n.text("lab.sheet.draft")).font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
    }
}

/// What a tap on a cheat-sheet row opens: the pick and why, the longer story, how to use it, a prompt to copy and the
/// other picks for the same job. Stock sheet, list and buttons.
struct LabSheetRowDetail: View {
    let row: LabSheetRow
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    static func symbol(_ row: LabSheetRow) -> String {
        guard let name = row.symbol, UIImage(systemName: name) != nil else { return "sparkles" }
        return name
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The answer first: the job as its label, the pick as large as the page's title, then why.
                    VStack(alignment: .leading, spacing: 10) {
                        Label { Text(row.task.text) } icon: { Image(systemName: Self.symbol(row)).foregroundStyle(LabPalette.gauge) }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.pick).font(.system(size: 32, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                            if row.draft == true { LabSheetDraftMark() }
                        }
                        if let why = row.why { Text(why.text).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true) }
                        if let example = row.example {
                            Text(L10n.text("lab.sheet.example", example.text)).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        if row.draft == true {
                            Label(L10n.text("lab.sheet.draftNote"), systemImage: "pencil.and.scribble").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("lab.sheet.detail")
                }
                if let detail = row.detail {
                    Section(L10n.text("lab.sheet.detailTitle")) { Text(detail.text).fixedSize(horizontal: false, vertical: true) }
                }
                if let tips = row.tips, !tips.isEmpty {
                    Section(L10n.text("lab.sheet.tips")) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                            Label { Text(tip.text) } icon: { Text("\(index + 1)").font(LabFont.number(13)).foregroundStyle(LabPalette.gauge) }
                        }
                    }
                }
                if let prompt = row.prompt {
                    Section(L10n.text("lab.sheet.prompt")) {
                        Text(prompt.text).font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = prompt.text
                            LabHaptic.pass()
                            withAnimation { copied = true }
                        } label: { Label(L10n.text(copied ? "lab.sheet.copied" : "lab.sheet.copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .accessibilityIdentifier("lab.sheet.copy")
                    }
                }
                if let alternatives = row.alternatives, !alternatives.isEmpty {
                    Section(L10n.text("lab.sheet.alternatives")) {
                        ForEach(Array(alternatives.enumerated()), id: \.offset) { _, alternative in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(alternative.pick).font(.system(size: 16, weight: .semibold))
                                if let why = alternative.why { Text(why.text).font(.system(size: 14)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("Close"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - The gallery of 망작

/// Every trap's 망작, framed once it has been pressed. Traps not yet pressed are empty frames that call the learner back.
struct LabFailsView: View {
    let play: (LabEpisode) -> Void
    /// Brings a 망작 up close, the same way it came up when it was won.
    let open: (LabFail) -> Void
    @State private var store = LabStore.shared

    var body: some View {
        let fails = store.course.fails
        let hung = fails.filter(store.hung)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabHeader(kicker: Text(L10n.text("lab.fails.subtitle")), title: L10n.text("lab.fails.title")) {
                    (Text("\(hung.count)").foregroundColor(LabPalette.fail) + Text("/\(fails.count)").foregroundColor(.secondary))
                        .font(LabFont.number(20)).accessibilityIdentifier("lab.fails.count")
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(fails) { fail in
                        if store.hung(fail) {
                            Button { LabHaptic.tick(); open(fail) } label: { frame(fail) }.buttonStyle(LabPressStyle()).accessibilityIdentifier("lab.fail.\(fail.id)")
                        } else if let episode = store.course.episode(fail.episode), store.state(episode) != .locked {
                            // Not won yet, but its episode is open: a tap goes straight there to win it.
                            Button { LabHaptic.tick(); play(episode) } label: { empty(fail) }
                                .buttonStyle(LabPressStyle())
                                .accessibilityHint(L10n.text("lab.fails.go"))
                                .accessibilityIdentifier("lab.fail.go.\(fail.id)")
                        } else {
                            empty(fail)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func frame(_ fail: LabFail) -> some View { LabFailFrame(fail: fail) }

    private func empty(_ fail: LabFail) -> some View {
        let episode = store.course.episode(fail.episode)
        let locked = episode.map { store.state($0) == .locked } ?? true
        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                Image(systemName: locked ? "lock" : "questionmark").font(.system(size: 18, weight: .semibold))
                Text(L10n.text("lab.fails.empty")).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 138)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])) }
            if locked {
                Text(L10n.text("lab.card.locked")).font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
            } else {
                Label(L10n.text("lab.fails.go"), systemImage: "arrow.right.circle.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(LabPalette.fail)
            }
            Text(L10n.text("lab.card.number", episode?.digits ?? "") + (episode.map { " · " + $0.label } ?? "")).font(LabFont.number(11, .medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab.fail.empty.\(fail.id)")
    }
}

/// A 망작 as the gallery hangs it: what came out, on paper in a dark frame, with its name and number under it.
struct LabFailFrame: View {
    let fail: LabFail
    /// How many lines of the answer the paper holds; nil shows all of it.
    var lines: Int? = 5
    /// Whether the name and number are written under the frame.
    var captioned = true
    private var store: LabStore { .shared }
    var body: some View {
        let episode = store.course.episode(fail.episode)
        VStack(alignment: .leading, spacing: 8) {
            Text(fail.reply.text).font(LabFont.line(13)).foregroundStyle(LabPalette.paperInk).lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .padding(12)
                .background(LabPalette.paper)
                .padding(7)
                .background(Color(labHex: "2A2724"), in: RoundedRectangle(cornerRadius: 3))
                .labCardShadow(.black.opacity(0.35), radius: 8, y: 4)
            if captioned {
                Text(fail.name.text).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Text(String(format: "No. %02d", store.number(fail)) + " · " + L10n.text("lab.card.number", episode?.digits ?? ""))
                    .font(LabFont.number(11, .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The moment a 망작 is won, the first time its trap is pressed: the chat dims, a ring of light opens, the framed 망작 drops in
/// from above, swings on its pin and settles a little crooked, and only then its name, number and the 연구비 it paid come in.
struct LabFailReveal: View {
    let fail: LabFail
    /// Won just now; false when it is opened again from the gallery, which shows the trap that made it instead.
    var won = true
    let done: () -> Void
    private var store: LabStore { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false
    @State private var hung = false
    @State private var settled = false

    var body: some View {
        let episode = store.course.episode(fail.episode)
        ZStack {
            // The chat goes dark and out of focus behind the card.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(.black.opacity(0.72))
            }
            .ignoresSafeArea()
            .opacity(dimmed ? 1 : 0)
            .contentShape(Rectangle()).onTapGesture {}
                .accessibilityHidden(true)
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    LabTag(text: String(format: "No. %02d", store.number(fail)), color: LabPalette.fail, mono: true)
                    if won {
                        Text(L10n.text("lab.fail.got")).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        // The trap that made it, as the learner pressed it.
                        Text("“" + fail.choice.text + "”").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(settled ? 1 : 0).offset(y: settled ? 0 : -10)

                LabFailFrame(fail: fail, lines: 7, captioned: false)
                    .overlay(alignment: .top) {
                        Circle().fill(Color(labHex: "8A867D")).frame(width: 10, height: 10)
                            .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                            .offset(y: -4)
                    }
                    .frame(width: 260)
                    .background {
                        // A ring of light behind the frame, opening as it lands.
                        Circle().fill(RadialGradient(colors: [LabPalette.paper.opacity(0.3), LabPalette.fail.opacity(0.18), .clear], center: .center, startRadius: 20, endRadius: 220))
                            .frame(width: 440, height: 440)
                            .scaleEffect(settled ? 1 : 0.3).opacity(settled ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .rotationEffect(.degrees(hung ? -2.5 : -22), anchor: .top)
                    .offset(y: hung ? 0 : -320)
                    .accessibilityElement(children: .combine)

                VStack(spacing: 6) {
                    Text(fail.name.text).font(LabFont.voice(24)).foregroundStyle(.white).multilineTextAlignment(.center)
                    Text(won ? L10n.text("lab.card.number", episode?.digits ?? "") + " · " + (store.failReward > 0 ? L10n.text("lab.fail.gotNote", store.shop.currency.text, String(store.failReward)) : L10n.text("lab.fail.hungNote"))
                             : L10n.text("lab.card.number", episode?.digits ?? "") + (episode.map { " · " + $0.title.text } ?? ""))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                .opacity(settled ? 1 : 0).offset(y: settled ? 0 : 12)

                Button(action: close) { Text(L10n.text("OK")).frame(maxWidth: .infinity) }
                    .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                    .frame(width: 260)
                    .opacity(settled ? 1 : 0)
                    .accessibilityIdentifier("lab.fail.reveal.done")
            }
            .padding(.horizontal, 24)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("lab.fail.reveal")
        .task { await play() }
    }

    private func play() async {
        if reduceMotion { dimmed = true; hung = true; settled = true; return }
        withAnimation(.easeOut(duration: 0.25)) { dimmed = true }
        try? await Task.sleep(for: .milliseconds(120))
        // Dropped in, it swings past and back on its pin before it comes to rest.
        withAnimation(.spring(duration: 0.9, bounce: 0.5)) { hung = true }
        try? await Task.sleep(for: .milliseconds(380))
        LabHaptic.snap()
        withAnimation(.spring(duration: 0.6, bounce: 0.2)) { settled = true }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) { settled = false; dimmed = false; hung = false }
        Task { try? await Task.sleep(for: .milliseconds(200)); done() }
    }
}

// MARK: - Shop

/// The shop: what 연구비 buys, as square cards.
struct LabShopView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LabHeader(kicker: Text(L10n.text("lab.shop.subtitle")), title: L10n.text("lab.tab.shop"))
                LabShopContent()
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// What the shop holds: the balance, then each section's square cards. Its own page in the lab; the foot of the 연습 tab in
/// the 2D AI course.
struct LabShopContent: View {
    @State private var store = LabStore.shared
    @State private var confirming: LabShopItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.shop.currency.text).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(String(store.balance)).font(LabFont.number(34)).contentTransition(.numericText(value: Double(store.balance)))
                        .accessibilityIdentifier("lab.shop.balance")
                }
                if let note = store.shop.note { Text(note.text).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .padding(18)
            .background(LabPalette.surface(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            ForEach(store.shop.sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title.text).font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(section.items) { item in card(item) }
                    }
                }
            }
        }
        .animation(.snappy, value: store.balance)
        .alert(confirming.map { L10n.text("lab.shop.confirm", $0.name.text) } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { item in
            Button(L10n.text("lab.shop.buy", String(item.price ?? 0))) {
                if store.buy(item) == .bought { LabHaptic.pass() }
                confirming = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { confirming = nil }
        } message: { item in
            Text(L10n.text("lab.shop.confirmNote", String(store.balance - (item.price ?? 0))))
        }
    }

    /// One thing for sale: a square card with its symbol, name, what it is and its price tag.
    private func card(_ item: LabShopItem) -> some View {
        let state = store.canBuy(item)
        let owned = store.owns(item.id) && !item.isRepeat
        let note: String = owned ? L10n.text("lab.shop.owned")
            : item.isSoon ? L10n.text("lab.shop.soon")
            : { if case .short(let missing) = state { return L10n.text("lab.shop.short", String(missing)) }; return item.summary?.text ?? "" }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: item.symbol ?? "bag").font(.system(size: 22, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(LabPalette.surface(2), in: Circle())
                Spacer()
                if item.isLimited {
                    Text(L10n.text("lab.shop.limited")).font(.system(size: 11, weight: .bold)).foregroundStyle(LabPalette.paperInk)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(LabPalette.paper, in: Capsule())
                }
            }
            Spacer(minLength: 10)
            Text(item.name.text).font(.system(size: 16, weight: .bold)).lineLimit(2).minimumScaleFactor(0.85)
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).padding(.top, 2)
            Spacer(minLength: 10)
            priceTag(item, state: state, owned: owned)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .background(LabPalette.surface(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(item.isSoon ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lab.shop.item.\(item.id)")
    }

    @ViewBuilder private func priceTag(_ item: LabShopItem, state: LabStore.BuyResult, owned: Bool) -> some View {
        // A course bought here opens from its item, unless it is the one on screen.
        if owned, let course = LearningCourses.shared.all.first(where: { $0.item == item.id }), StudyMode.shared.courseID != course.id {
            Button(L10n.text("lab.shop.open")) { StudyMode.shared.open(course.id) }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityIdentifier("lab.shop.open.\(item.id)")
        } else if owned {
            Label(L10n.text("lab.shop.ownedShort"), systemImage: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        } else if let price = item.price {
            if state == .bought {
                Button { confirming = item } label: { Text(String(price)).font(LabFont.number(15)) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(LabPalette.primary).foregroundStyle(LabPalette.onPrimary)
                    .accessibilityIdentifier("lab.shop.buy.\(item.id)")
            } else {
                Text(String(price)).font(LabFont.number(15)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(LabPalette.surface(2), in: Capsule())
                    .accessibilityIdentifier("lab.shop.buy.\(item.id)")
            }
        }
    }
}

// MARK: - Diagnosis

/// The one-minute check: four questions, then card No. 000 with the learner's type and the episodes to look for.
struct LabDiagnosisView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [Int] = []
    @State private var result: LabType?
    private var store: LabStore { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if let diagnosis = store.diagnosis {
                    if let result { resultPage(result) } else if answers.count < diagnosis.questions.count { question(diagnosis, answers.count) }
                }
            }
            .animation(.snappy(duration: 0.3), value: answers)
            .animation(.snappy(duration: 0.3), value: result)
            .toolbar {
                if result == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.text("lab.diagnosis.skip")) { dismiss() }.accessibilityIdentifier("lab.diagnosis.skip")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(answers.count + 1)/\(store.diagnosis?.questions.count ?? 0)").font(LabFont.number(13)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .labLines()
    }

    private func question(_ diagnosis: LabDiagnosis, _ index: Int) -> some View {
        let question = diagnosis.questions[index]
        return VStack(alignment: .leading, spacing: 20) {
            if index == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text(diagnosis.title.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    if let intro = diagnosis.intro { Text(intro.text).font(.system(size: 14)).foregroundStyle(.secondary) }
                }
            }
            Text(question.text.text).font(LabFont.voice(26)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lab.diagnosis.question")
            Spacer()
            VStack(spacing: 8) {
                ForEach(question.options.indices, id: \.self) { option in
                    Button {
                        LabHaptic.tick()
                        answers.append(option)
                        if answers.count == diagnosis.questions.count, let type = diagnosis.result(answers) {
                            store.diagnose(type)
                            LabHaptic.pass()
                            result = type
                        }
                    } label: {
                        Text(question.options[option].text.text).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    .labSecondary().buttonBorderShape(.roundedRectangle(radius: 18))
                    .accessibilityIdentifier("lab.diagnosis.option.\(option)")
                }
            }
        }
        .padding(20)
        .id(index)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private func resultPage(_ type: LabType) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(L10n.text("lab.diagnosis.done")).font(.system(size: 22, weight: .bold)).accessibilityIdentifier("lab.diagnosis.done")
                LabCardFace(serial: "No. 000", title: type.name.text, line: type.name.text, color: LabPalette.ink, state: .earned,
                            footer: type.line.text, large: true)
                    .frame(width: 280, height: 352)
                LabTypeEpisodes(type: type)
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: { Text(L10n.text("lab.engrave.put")).frame(maxWidth: .infinity) }
                .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityIdentifier("lab.diagnosis.close")
        }
    }
}

/// The episodes a type should look for first.
struct LabTypeEpisodes: View {
    let type: LabType
    private var store: LabStore { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("lab.diagnosis.recommended")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(type.episodes.compactMap(store.main.episode)) { episode in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(episode.serial).font(LabFont.number(12)).foregroundStyle(LabPalette.gauge)
                    Text(episode.title.text).font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The back of card No. 000.
struct LabTypeSheet: View {
    let diagnose: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: LabStore { .shared }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let type = store.type {
                    VStack(spacing: 18) {
                        LabCardFace(serial: "No. 000", title: type.name.text, line: type.name.text, color: LabPalette.ink, state: .earned,
                                    footer: type.line.text, date: store.progress.diagnosed?.labStamp, large: true)
                            .frame(width: 280, height: 352)
                        LabTypeEpisodes(type: type)
                        Button(L10n.text("lab.diagnosis.again")) { dismiss(); Task { try? await Task.sleep(for: .milliseconds(400)); diagnose() } }
                            .labSecondary()
                    }
                    .padding(20)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("Close")) }
            }
        }
        .labLines()
    }
}
