import SwiftUI

/// One episode, played full screen: the disaster and the choice, the tool, then the card's engraving.
struct LabEpisodeView: View {
    let episode: LabEpisode
    @Environment(\.dismiss) private var dismiss
    private var store: LabStore { LabStore.shared }

    enum Phase: Int { case choice, tool, engrave }
    @State private var phase = Phase.choice
    /// The choice picked, shown with its verdict until the learner goes back to the choices.
    @State private var picked: Int?
    @State private var hungNow: [String] = []
    @State private var passed = false
    @State private var toolRun = 0
    @State private var started = Date()
    @State private var engraving: LabEngraving?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choice: choiceStage.transition(.opacity)
                case .tool: toolStage.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                case .engrave: LabEngraveView(episode: episode, engraving: engraving, seconds: Date().timeIntervalSince(started), hung: hungNow) { dismiss() }
                    .transition(.opacity)
                }
            }
            .toolbar {
                if phase != .engrave {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("lab.episode.close")
                    }
                    ToolbarItem(placement: .principal) { progress }
                    ToolbarItem(placement: .topBarTrailing) {
                        if phase == .tool {
                            Button { toolRun += 1; passed = false } label: { Image(systemName: "arrow.counterclockwise") }
                                .accessibilityLabel(L10n.text("lab.tool.again")).accessibilityIdentifier("lab.tool.again")
                        } else {
                            Text(episode.serial).font(LabFont.number(12)).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Four short bars: disaster, choice, tool, engraving.
    private var progress: some View {
        let reached = phase == .choice ? (picked == nil ? 1 : 2) : phase == .tool ? 3 : 4
        return HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(index < reached ? Color.primary : Color.secondary.opacity(0.3)).frame(height: 4)
            }
        }
        .frame(width: 150)
        .accessibilityElement().accessibilityLabel(L10n.text("lab.episode.step", String(reached), "4"))
    }

    // MARK: The disaster and the choice

    private var choiceStage: some View {
        let choice = picked.map { episode.choices[$0] }
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LabBubble(text: choice.flatMap { $0.fail == nil ? nil : episode.disaster.ask.text + "\n+ " + $0.text.text } ?? episode.disaster.ask.text, mine: true)
                    LabBubble(text: choice?.fail?.reply.text ?? episode.disaster.reply.text)
                        .id(picked)
                        .transition(.opacity)
                    Spacer(minLength: 28)
                    Group {
                        if let index = picked, let choice { verdict(index, choice) } else { opening }
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 20).padding(.top, 12)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .animation(.easeOut(duration: 0.25), value: picked)
            }
            // On a short screen the choices stay in view; the chat above scrolls.
            .defaultScrollAnchor(.bottom)
        }
    }

    private var opening: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(episode.disaster.verdict.text).font(LabFont.voice(29)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("lab.disaster")
                Text(episode.disaster.question.text).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(episode.choices.indices, id: \.self) { index in
                    Button { pick(index) } label: {
                        Text(episode.choices[index].text.text).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    .labSecondary().buttonBorderShape(.roundedRectangle(radius: 18))
                    .accessibilityIdentifier("lab.choice.\(index)")
                }
            }
        }
        .transition(.opacity)
    }

    private func verdict(_ index: Int, _ choice: LabChoice) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if choice.isRight {
                    LabTag(text: L10n.text("lab.pass"), color: LabPalette.pass)
                } else if let fail = episode.fails.first(where: { $0.choice == choice.text }) {
                    LabTag(text: L10n.text("lab.fail.hung", String(format: "%02d", store.number(fail))), color: LabPalette.fail)
                        .accessibilityIdentifier("lab.fail.tag")
                }
                Text(choice.verdict.text).font(LabFont.voice(25)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lab.verdict")
                if let why = choice.why { Text(why.text).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack(spacing: 8) {
                Button { withAnimation(.spring(duration: 0.45, bounce: 0.1)) { picked = nil } } label: {
                    Text(L10n.text(choice.isRight ? "lab.choice.seeFails" : "lab.choice.tryOthers")).frame(maxWidth: .infinity)
                }
                .labSecondary().buttonBorderShape(.roundedRectangle(radius: 18))
                .accessibilityIdentifier("lab.choice.back")
                if choice.isRight {
                    Button { withAnimation(.spring(duration: 0.55, bounce: 0.12)) { phase = .tool } } label: { Text(L10n.text("lab.choice.tryIt")).frame(maxWidth: .infinity) }
                        .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                        .accessibilityIdentifier("lab.choice.next")
                }
            }
        }
        .transition(.opacity)
    }

    private func pick(_ index: Int) {
        let choice = episode.choices[index]
        if choice.isRight {
            LabHaptic.pass()
        } else if let fail = episode.fails.first(where: { $0.choice == choice.text }) {
            // No shaking and no penalty: a quiet tag, and the 망작 goes up in the gallery.
            LabHaptic.press()
            if store.hang(fail) { hungNow.append(fail.id) }
        }
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { picked = index }
    }

    // MARK: The tool

    private var toolStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.tool.title.text).font(.system(size: 22, weight: .bold)).accessibilityAddTraits(.isHeader)
                    if let hint = episode.tool.hint { Text(hint.text).font(.system(size: 15)).foregroundStyle(.secondary) }
                }
                LabToolView(tool: episode.tool, passed: $passed).id(toolRun)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if passed {
                    Button {
                        engraving = store.engrave(episode, failsHung: hungNow.count)
                        withAnimation(.easeInOut(duration: 0.45)) { phase = .engrave }
                    } label: { Text(L10n.text(store.earned(episode) ? "lab.tool.finish" : "lab.tool.engrave")).frame(maxWidth: .infinity) }
                        .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                        .accessibilityIdentifier("lab.tool.engrave")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Text(L10n.text("lab.tool.pending")).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Color(uiColor: .systemBackground))
            .animation(.snappy, value: passed)
        }
    }
}

// MARK: - The engraving

/// The reward: the blank card turns over in one movement and comes up in its season's colour, its line is pressed in one letter
/// at a time, light crosses it once, and only then the numbers settle in below. The longest moment in the lab.
struct LabEngraveView: View {
    let episode: LabEpisode
    let engraving: LabEngraving?
    let seconds: TimeInterval
    let hung: [String]
    let done: () -> Void
    private var store: LabStore { LabStore.shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var angle: Double = 0
    @State private var revealed: Double = 0
    @State private var sheen: Double = 0
    @State private var settled = false
    @State private var shownRate: Int?

    var body: some View {
        let line = episode.card.line.text
        let season = store.course.season(of: episode)
        GeometryReader { proxy in
            let height = min(352, max(250, proxy.size.height * 0.5))
            List {
                Section {
                    VStack(spacing: 6) {
                        Text(String(format: "%d:%02d · ", Int(seconds) / 60, Int(seconds) % 60) + L10n.text("lab.engrave.done"))
                            .font(LabFont.number(12)).tracking(1.2).foregroundStyle(.secondary)
                        Text(engraving?.first == false ? L10n.text("lab.engrave.again") : L10n.text("lab.engrave.title", LabOrdinal.text(max(1, store.earnedCards.count))))
                            .font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                            .accessibilityIdentifier("lab.engrave.title")
                    }
                    .frame(maxWidth: .infinity)
                    LabFlip(angle: angle) {
                        LabCardFace(serial: episode.serial + " · " + L10n.text("lab.card.blank"), title: episode.title.text, state: .blank, large: true)
                    } back: {
                        LabCardFace(serial: episode.serial, title: episode.title.text, line: line, color: store.course.color(episode), state: .earned,
                                    footer: [episode.label, season.map { L10n.text("lab.season", String($0.number)) }].compactMap { $0 }.joined(separator: " · "),
                                    date: (store.progress.cards[episode.id] ?? LabStore.now).labStamp, engraved: revealed, large: true)
                            .overlay { LabSheen(progress: sheen).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous)) }
                    }
                    .frame(width: height * 280 / 352, height: height)
                    .shadow(color: angle > 90 ? Color(labHex: store.course.color(episode)).opacity(0.5) : .black.opacity(0.25), radius: 28, y: 16)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityElement().accessibilityLabel(line)
                    .accessibilityIdentifier("lab.engrave.card")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let engraving, settled {
                    Section {
                        HStack {
                            Text(store.course.info.gauge.text)
                            Spacer()
                            Text("\(engraving.before)% → ").font(LabFont.number(17)).foregroundStyle(.secondary)
                            Text("\(shownRate ?? engraving.before)%").font(LabFont.number(17)).foregroundStyle(LabPalette.gauge)
                                .contentTransition(.numericText(value: Double(shownRate ?? engraving.before)))
                        }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("lab.engrave.rate")
                        HStack {
                            Text(store.shop.currency.text)
                            Spacer()
                            Text("+\(engraving.total)").font(LabFont.number(15))
                            Text(L10n.text("lab.engrave.income", String(engraving.cardReward), String(engraving.failReward))).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("lab.engrave.income")
                        HStack {
                            Text(L10n.text("lab.engrave.fails"))
                            Spacer()
                            Text(L10n.text("lab.count.pieces", String(engraving.failsHung))).font(LabFont.number(15)).foregroundStyle(LabPalette.fail)
                            Text(engraving.failsLeft == 0 ? L10n.text("lab.engrave.allFails") : L10n.text("lab.engrave.failsLeft", String(engraving.failsLeft)))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                LabShareCard(episode: episode).labSecondary().buttonBorderShape(.roundedRectangle(radius: 18))
                Button(action: done) { Text(L10n.text("lab.engrave.put")).frame(maxWidth: .infinity) }
                    .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                    .accessibilityIdentifier("lab.engrave.put")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task { await play(line) }
    }

    private func play(_ line: String) async {
        let count = Double(line.count)
        if reduceMotion {
            angle = 180; revealed = count + 1; settled = true; shownRate = engraving?.after
            return
        }
        try? await Task.sleep(for: .milliseconds(450))
        LabHaptic.snap()
        // One unbroken turn: the paper goes edge-on and comes round as the coloured card, settling with a small give.
        withAnimation(.spring(duration: 1.05, bounce: 0.14)) { angle = 180 }
        try? await Task.sleep(for: .milliseconds(950))
        // The line is pressed in one letter at a time, felt as a run of soft taps.
        let step = 0.075
        withAnimation(.linear(duration: count * step + 0.2)) { revealed = count + 1 }
        for (index, character) in line.enumerated() {
            if character != " " { LabHaptic.press(index % 2 == 0 ? 0.75 : 0.55) }
            try? await Task.sleep(for: .seconds(step))
        }
        withAnimation(.easeInOut(duration: 0.9)) { sheen = 1 }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.spring(duration: 0.6, bounce: 0.18)) { settled = true }
        try? await Task.sleep(for: .milliseconds(250))
        withAnimation(.spring(duration: 1.2)) { shownRate = engraving?.after }
        if engraving?.first == true { LabHaptic.pass() }
    }
}

/// Shares a picture of an engraved card.
struct LabShareCard: View {
    let episode: LabEpisode
    @State private var image: Image?
    var body: some View {
        Group {
            if let image {
                ShareLink(item: image, preview: SharePreview(episode.card.line.text, image: image)) { Image(systemName: "square.and.arrow.up").padding(.vertical, 2) }
            } else {
                Button {} label: { Image(systemName: "square.and.arrow.up").padding(.vertical, 2) }.disabled(true)
            }
        }
        .accessibilityLabel(L10n.text("lab.share"))
        .accessibilityIdentifier("lab.share")
        .task { image = render() }
    }

    @MainActor private func render() -> Image? {
        let store = LabStore.shared
        let card = LabCardFace(serial: episode.serial, title: episode.title.text, line: episode.card.line.text, color: store.course.color(episode), state: .earned,
                               footer: store.course.season(of: episode).map { L10n.text("lab.season", String($0.number)) },
                               date: store.progress.cards[episode.id]?.labStamp, large: true)
            .frame(width: 280, height: 352).padding(24).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}
