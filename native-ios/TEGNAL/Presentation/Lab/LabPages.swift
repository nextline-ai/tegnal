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
                    Text(L10n.text("lab.sheet.paid", String(paid), store.shop.currency.text)).font(LabFont.number(13)).foregroundStyle(LabPalette.gauge)
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

    private func paper(_ edition: LabEdition) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("lab.sheet.stamp", edition.stamp))
                    .font(LabFont.number(12)).foregroundStyle(LabPalette.paperInk)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(LabPalette.paperInk, lineWidth: 1.5) }
                    .rotationEffect(.degrees(-2))
                    .accessibilityIdentifier("lab.sheet.stamp")
                if let change = edition.change { Text(change.text).font(.system(size: 13)).foregroundStyle(LabPalette.paperMuted) }
            }
            ForEach(edition.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title.text).font(LabFont.voice(20)).foregroundStyle(LabPalette.paperInk)
                    if store.opened(section) {
                        VStack(spacing: 0) {
                            ForEach(section.rows.indices, id: \.self) { index in
                                let row = section.rows[index]
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.task.text).font(.system(size: 15, weight: .semibold))
                                        if let example = row.example { Text(example.text).font(.system(size: 12)).foregroundStyle(LabPalette.paperMuted) }
                                    }
                                    Spacer(minLength: 8)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(row.pick).font(.system(size: 15, weight: .bold)).multilineTextAlignment(.trailing)
                                        if let why = row.why { Text(why.text).font(.system(size: 12)).foregroundStyle(LabPalette.paperMuted).multilineTextAlignment(.trailing) }
                                    }
                                }
                                .foregroundStyle(LabPalette.paperInk)
                                .padding(.vertical, 11)
                                .accessibilityElement(children: .combine)
                                if index < section.rows.count - 1 { Rectangle().fill(LabPalette.paperRule.opacity(0.35)).frame(height: 0.5) }
                            }
                        }
                        .accessibilityIdentifier("lab.sheet.section.\(section.id)")
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                            Text(L10n.text("lab.sheet.locked", (section.opens.flatMap(store.course.episode)?.digits ?? "")))
                        }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(LabPalette.paperMuted)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(LabPalette.paperRule.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                        .accessibilityIdentifier("lab.sheet.locked.\(section.id)")
                    }
                }
            }
            if let footer = edition.footer { Text(footer.text).font(.system(size: 12)).foregroundStyle(LabPalette.paperMuted) }
        }
        .padding(22)
        .background { LabCardBackground(state: .blank, radius: 22) }
        .environment(\.colorScheme, .light)
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

    private func frame(_ fail: LabFail) -> some View {
        let episode = store.course.episode(fail.episode)
        return VStack(alignment: .leading, spacing: 8) {
            Text(fail.reply.text).font(LabFont.line(13)).lineSpacing(2).foregroundStyle(LabPalette.paperInk).lineLimit(5)
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                .padding(12)
                .background(LabPalette.paper)
                .padding(7)
                .background(Color(labHex: "2A2724"), in: RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            Text(fail.name.text).font(.system(size: 14, weight: .bold)).lineLimit(1)
            Text(String(format: "No. %02d", store.number(fail)) + " · " + L10n.text("lab.card.number", episode?.digits ?? ""))
                .font(LabFont.number(11, .medium)).foregroundStyle(.secondary)
        }
    }

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
        if owned, item.id == LabStore.tagCourse {
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
            Text(question.text.text).font(LabFont.voice(26)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
                LabCardFace(serial: "No. 000", title: type.name.text, line: type.name.text, color: LabPalette.teal, state: .earned,
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
                        LabCardFace(serial: "No. 000", title: type.name.text, line: type.name.text, color: LabPalette.teal, state: .earned,
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
    }
}
