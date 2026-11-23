import SwiftUI

// MARK: - Cheat sheet

/// The cheat sheet: one sheet of paper, swapped whenever the field changes. Cards 001 and 004 open its sections.
struct LabSheetView: View {
    @State private var store = LabStore.shared
    @State private var paid = 0
    @State private var mode = StudyMode.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabHeader(kicker: Text(L10n.text("lab.sheet.subtitle")), title: L10n.text("lab.tab.sheet"))
                if let edition = store.edition { paper(edition) } else {
                    ContentUnavailableView(L10n.text("lab.sheet.none"), systemImage: "doc.text")
                }
                if paid > 0 {
                    Text(L10n.text("lab.sheet.paid", String(paid), store.shop.currency.text)).font(.system(size: 13, weight: .semibold)).foregroundStyle(LabPalette.gauge)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("lab.sheet.paid")
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

    private func paper(_ edition: LabEdition) -> some View { LabSheetPaper(edition: edition) }
}

/// The sheet itself, printed on paper: a masthead with the date stamp and what changed, a numbered section for each family of jobs,
/// and the footer under a double rule. Each row reads in one glance: the job, an example, the pick on a tag, and why.
/// A section no card has opened yet is shown blacked out, with the card that opens it.
struct LabSheetPaper: View {
    let edition: LabEdition
    private var store: LabStore { .shared }
    private let ink = LabPalette.paperInk
    private let muted = LabPalette.paperMuted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            ForEach(Array(edition.sections.enumerated()), id: \.element.id) { index, section in
                sectionView(index + 1, section).padding(.top, 30)
            }
            if let footer = edition.footer {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 2) {
                        Rectangle().fill(ink).frame(height: 0.5)
                        Rectangle().fill(ink).frame(height: 2)
                    }
                    Text(footer.text).font(LabFont.line(14)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 30)
            }
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 26)
        .background { LabCardBackground(state: .blank, radius: 22) }
        .environment(\.colorScheme, .light)
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI LAB · CHEAT SHEET").font(LabFont.number(10)).tracking(1.8).foregroundStyle(muted)
                    if let change = edition.change {
                        Text(change.text).font(LabFont.line(16)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                stamp
            }
            Rectangle().fill(ink).frame(height: 2)
        }
    }

    /// A rubber stamp in red ink: the day this sheet was curated.
    private var stamp: some View {
        let red = Color(labHex: "B3392B")
        return VStack(spacing: 2) {
            Text(L10n.text("lab.sheet.basis")).font(.system(size: 10, weight: .heavy)).tracking(1.2)
            Text(edition.stamp).font(LabFont.number(14))
        }
        .foregroundStyle(red)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(red, lineWidth: 1.6) }
        .padding(3)
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(red, lineWidth: 0.8) }
        .opacity(0.88)
        .rotationEffect(.degrees(-5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("lab.sheet.stamp", edition.stamp))
        .accessibilityIdentifier("lab.sheet.stamp")
    }

    private func sectionView(_ number: Int, _ section: LabSheetSection) -> some View {
        let opened = store.opened(section)
        let card = section.opens.flatMap(store.course.episode)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", number)).font(LabFont.number(14)).foregroundStyle(muted)
                Text(section.title.text).font(LabFont.voice(21)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if let card, opened {
                Label(L10n.text("lab.card.number", card.digits) + " · " + card.label, systemImage: "key.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                    .padding(.top, 6)
            }
            Rectangle().fill(ink).frame(height: 1).padding(.top, 12)
            if opened {
                VStack(spacing: 0) {
                    ForEach(section.rows.indices, id: \.self) { index in
                        row(section.rows[index])
                        if index < section.rows.count - 1 { Rectangle().fill(LabPalette.paperRule.opacity(0.4)).frame(height: 0.5) }
                    }
                }
                .accessibilityIdentifier("lab.sheet.section.\(section.id)")
            } else {
                blackedOut(section, card: card)
            }
        }
    }

    private func row(_ row: LabSheetRow) -> some View {
        let job = VStack(alignment: .leading, spacing: 2) {
            Text(row.task.text).font(.system(size: 17, weight: .bold)).foregroundStyle(ink)
            if let example = row.example { Text(example.text).font(.system(size: 13)).foregroundStyle(muted) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            // The pick sits beside the job when there is room, under it when there is not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) { job.fixedSize(); Spacer(minLength: 0); pick(row) }
                VStack(alignment: .leading, spacing: 8) { job; pick(row) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let why = row.why {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold)).foregroundStyle(muted)
                    Text(why.text).font(.system(size: 14)).foregroundStyle(ink.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    /// The pick on a tag: solid ink once settled; a pencilled outline, marked as a draft, while it is not.
    private func pick(_ row: LabSheetRow) -> some View {
        let draft = row.draft == true
        return HStack(spacing: 6) {
            if draft {
                Text(L10n.text("lab.sheet.draft")).font(.system(size: 10, weight: .heavy)).foregroundStyle(muted)
            }
            Text(row.pick).font(.system(size: 15, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(draft ? ink : LabPalette.paper)
        .padding(.horizontal, 13).frame(height: 32)
        .background {
            if draft { Capsule().strokeBorder(ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
            else { Capsule().fill(ink) }
        }
        .fixedSize()
    }

    /// A section not opened yet: its rows blacked out, and the card that opens it.
    private func blackedOut(_ section: LabSheetSection, card: LabEpisode?) -> some View {
        let widths: [(CGFloat, CGFloat)] = [(104, 150), (78, 118), (124, 168), (92, 134)]
        return VStack(spacing: 0) {
            ForEach(section.rows.indices, id: \.self) { index in
                let width = widths[index % widths.count]
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(ink.opacity(0.75)).frame(width: width.0, height: 13)
                        Capsule().fill(ink.opacity(0.3)).frame(width: width.1, height: 9)
                    }
                    Spacer(minLength: 0)
                    Capsule().fill(ink.opacity(0.75)).frame(width: 76, height: 28)
                }
                .padding(.vertical, 16)
                if index < section.rows.count - 1 { Rectangle().fill(LabPalette.paperRule.opacity(0.4)).frame(height: 0.5) }
            }
        }
        .opacity(0.35)
        .overlay {
            Label(L10n.text("lab.sheet.locked", card?.digits ?? ""), systemImage: "lock.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(ink)
                .padding(.horizontal, 16).frame(height: 38)
                .background(LabPalette.paper, in: Capsule())
                .overlay { Capsule().strokeBorder(ink.opacity(0.25), lineWidth: 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("lab.sheet.locked", card?.digits ?? ""))
        .accessibilityIdentifier("lab.sheet.locked.\(section.id)")
    }
}

// MARK: - The gallery of 망작

/// Every trap's 망작, framed once it has been pressed. Traps not yet pressed are empty frames that call the learner back.
struct LabFailsView: View {
    let play: (LabEpisode) -> Void
    @State private var store = LabStore.shared
    @State private var shown: LabFail?

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
                            Button { shown = fail } label: { frame(fail) }.buttonStyle(LabPressStyle()).accessibilityIdentifier("lab.fail.\(fail.id)")
                        } else {
                            empty(fail)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .appSheet(item: $shown) { fail in LabFailSheet(fail: fail, play: play).presentationDetents([.medium, .large]) }
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
            Text(locked ? L10n.text("lab.card.locked") : L10n.text("lab.fails.waiting")).font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
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
                    Text(L10n.text("lab.fail.got")).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
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
                    Text(L10n.text("lab.card.number", episode?.digits ?? "") + " · " + L10n.text("lab.fail.gotNote", store.shop.currency.text, String(store.course.info.rewards.fail)))
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

/// One 망작, close up: the trap that made it and what came out.
struct LabFailSheet: View {
    let fail: LabFail
    let play: (LabEpisode) -> Void
    @Environment(\.dismiss) private var dismiss
    private var store: LabStore { .shared }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabTag(text: String(format: "No. %02d", store.number(fail)), color: LabPalette.fail, mono: true)
                    Text(fail.name.text).font(LabFont.voice(26))
                    LabBubble(text: fail.choice.text, mine: true)
                    LabBubble(text: fail.reply.text)
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("Close")) }
            }
        }
        .labLines()
    }
}

// MARK: - Shop

/// The shop: what 연구비 buys, as square cards.
struct LabShopView: View {
    @State private var store = LabStore.shared
    @State private var confirming: LabShopItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LabHeader(kicker: Text(L10n.text("lab.shop.subtitle")), title: L10n.text("lab.tab.shop"))
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
            .padding(.horizontal, 20).padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
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
        if owned, item.id == LabStore.tagCourse, !StudyMode.shared.tagsOpen {
            Button(L10n.text("lab.shop.open")) { StudyMode.shared.openTags() }
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
            ForEach(type.episodes.compactMap(store.course.episode)) { episode in
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
