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
                    if paid > 0 {
                        LabTag(text: L10n.text("lab.sheet.paid", String(paid), store.shop.currency.text), color: LabPalette.gauge)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityIdentifier("lab.sheet.paid")
                    }
                }
                if let edition = store.edition { LabSheetBoard(edition: edition) } else {
                    ContentUnavailableView(L10n.text("lab.sheet.none"), systemImage: "doc.text")
                }
                // At the very foot: whether a new edition should be told when it comes out.
                LabSheetAlertToggle()
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

/// The switch at the foot of the cheat sheet: a notification when a new edition is published (`LabSheetAlerts`).
/// Turning it on asks iOS for permission; refused, or taken back later in Settings, it says where to allow it.
struct LabSheetAlertToggle: View {
    @State private var on = LabSheetAlerts.isOn
    @State private var blocked = false
    @State private var working = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { on }, set: { change($0) })) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("lab.sheet.alerts")).font(.system(size: 16, weight: .semibold))
                        Text(L10n.text("lab.sheet.alerts.detail")).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: on ? "bell.badge.fill" : "bell").foregroundStyle(on ? LabPalette.fail : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .disabled(working)
            .accessibilityIdentifier("lab.sheet.alerts")
            if blocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("lab.sheet.alerts.blocked")).font(.system(size: 13)).foregroundStyle(LabPalette.fail)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("lab.sheet.alerts.settings")) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("lab.sheet.alerts.settings")
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: scenePhase) { await refresh() }
    }

    private func change(_ wanted: Bool) {
        LabHaptic.tick()
        withAnimation { on = wanted }
        working = true
        Task {
            let done = await LabSheetAlerts.set(wanted)
            withAnimation { on = LabSheetAlerts.isOn; blocked = wanted && !done }
            working = false
        }
    }

    /// The switch can be on while iOS no longer lets the app notify; that is said, not hidden.
    private func refresh() async {
        guard scenePhase == .active else { return }
        on = LabSheetAlerts.isOn
        let allowed = await LabSheetAlerts.allowed()
        withAnimation { blocked = on && !allowed || (blocked && !allowed) }
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
                // Only while locked: which card opens it. Once open, nothing more needs saying.
                if let card, !open {
                    Label(L10n.text("lab.sheet.locked", card.digits), systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(LabPalette.fail)
                        .accessibilityIdentifier("lab.sheet.locked.\(section.id)")
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
                Image(systemName: LabSheetRowDetail.symbol(row)).font(.system(size: 12, weight: .bold)).foregroundStyle(LabSheetRowDetail.tint(row))
                Text(row.task.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if open { LabSheetLabel(row: row) }
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

/// The tag at a tile's top right: the row's own `label` in its `labelColor` (a tinted capsule), or a quiet dashed outline
/// without a colour; "초안" for a draft pick that names no label of its own.
struct LabSheetLabel: View {
    let row: LabSheetRow
    var large = false
    var body: some View {
        if let text = row.label?.text ?? (row.draft == true ? L10n.text("lab.sheet.draft") : nil), !text.isEmpty {
            let size: CGFloat = large ? 12 : 10
            if let hex = row.labelColor, hex.count == 6 {
                let color = Color(labHex: hex)
                Text(text).font(.system(size: size, weight: .heavy)).foregroundStyle(color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(color.opacity(0.16), in: Capsule())
                    .accessibilityIdentifier("lab.sheet.label")
            } else {
                Text(text).font(.system(size: size, weight: .heavy)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                    .accessibilityIdentifier("lab.sheet.label")
            }
        }
    }
}

/// What a tap on a cheat-sheet row opens: the pick and why, the longer story, how to use it, a prompt to copy and the
/// other picks for the same job. Stock sheet, list and buttons.
struct LabSheetRowDetail: View {
    let row: LabSheetRow
    @Environment(\.dismiss) private var dismiss

    /// The row's own colour for its symbol, or the lab's gauge colour.
    static func tint(_ row: LabSheetRow) -> Color {
        guard let hex = row.color, hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return LabPalette.gauge }
        return Color(labHex: hex)
    }

    static func symbol(_ row: LabSheetRow) -> String {
        guard let name = row.symbol, UIImage(systemName: name) != nil else { return "sparkles" }
        return name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // The answer first: the job as its label, the pick as large as the page's title, then why.
                    VStack(alignment: .leading, spacing: 10) {
                        Label { Text(row.task.text) } icon: { Image(systemName: Self.symbol(row)).foregroundStyle(Self.tint(row)) }
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.pick).font(.system(size: 32, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                            LabSheetLabel(row: row, large: true)
                        }
                        if let why = row.why { Text(why.text).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true) }
                        if let example = row.example {
                            Text(L10n.text("lab.sheet.example", example.text)).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        if row.draft == true {
                            Label(L10n.text("lab.sheet.draftNote"), systemImage: "pencil.and.scribble").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("lab.sheet.detail")
                    // The rest is the sheet's own writing, as Markdown.
                    if let detail = row.detail {
                        Divider()
                        LabMarkdown(text: detail.text)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// A small Markdown renderer for writing that comes with the app's own data, such as a cheat-sheet row's details: paragraphs,
/// `#`–`###` headings, `-`/`*` and `1.` lists, `>` quotes, `---` rules and fenced code shown with a copy button; inline
/// **bold**, *italic* and `code`. Links show as their text and open nothing. Android draws the same blocks (`LabMarkdown`).
struct LabMarkdown: View {
    let text: String

    enum Block: Hashable {
        case heading(Int, String), paragraph(String), bullet(String), numbered(String, String), quote(String), code(String), rule
    }

    /// The blocks of a Markdown text, in order.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = [], code: [String]?
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " {
                flush(); blocks.append(.heading(min(3, line.distance(from: line.startIndex, to: hashes)), String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if line == "---" || line == "***" {
                flush(); blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix(">") {
                flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Inline Markdown as styled text, with links kept as plain words.
    static func inline(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs where run.link != nil { value[run.range].link = nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in view(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(.system(size: [22, 19, 17][level - 1], weight: .bold)).padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary)
                Text(Self.inline(text)).font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number + ".").font(LabFont.number(14)).foregroundStyle(LabPalette.gauge).frame(minWidth: 18, alignment: .leading)
                Text(Self.inline(text)).font(.system(size: 16)).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let text):
            Text(Self.inline(text)).font(.system(size: 16)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let code):
            LabCodeBlock(code: code)
        case .rule:
            Divider()
        }
    }
}

/// Fenced code in Markdown: set in a fixed-width face on a tinted plate, with a button that copies it.
struct LabCodeBlock: View {
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(code).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = code
                LabHaptic.pass()
                withAnimation { copied = true }
            } label: { Label(L10n.text(copied ? "lab.sheet.copied" : "lab.sheet.copy"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("lab.sheet.copy")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
/// from above, swings on its pin and settles a little crooked, and only then its name, number and the 보석 it paid come in.
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

/// The shop: what 보석 buys, as square cards.
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
            : { switch state {
                case .short(let missing): return L10n.text("lab.shop.short", String(missing))
                case .needs(let id): return L10n.text("lab.shop.needs", store.shop.item(id)?.name.text ?? id)
                default: return item.summary?.text ?? ""
            } }()
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
    /// The lab's first welcome: who made it comes first, then the questions. A check taken again from the deck goes straight in.
    var introduces = false
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [Int] = []
    @State private var result: LabType?
    @State private var introduced = false
    private var store: LabStore { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if introduces, !introduced { creator } else if let diagnosis = store.diagnosis {
                    if let result { resultPage(result) } else if answers.count < diagnosis.questions.count { question(diagnosis, answers.count) }
                }
            }
            .animation(.snappy(duration: 0.3), value: answers)
            .animation(.snappy(duration: 0.3), value: result)
            .animation(.snappy(duration: 0.3), value: introduced)
            .toolbar {
                if result == nil, !introduces || introduced {
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

    /// Who made the lab, before its first question.
    private var creator: some View {
        ScrollView {
            CreatorProfile(onboarding: true).padding(.horizontal, 16).padding(.top, 8).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button { LabHaptic.tick(); introduced = true } label: { Text(L10n.text("Continue")).frame(maxWidth: .infinity) }
                .labPrimary().buttonBorderShape(.roundedRectangle(radius: 18))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityIdentifier("lab.diagnosis.creator")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(L10n.text("lab.diagnosis.skip")) { dismiss() }.accessibilityIdentifier("lab.diagnosis.skip")
            }
        }
        .transition(.opacity)
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
