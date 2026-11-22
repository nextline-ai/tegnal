import SwiftUI
import UniformTypeIdentifiers

/// The hands-on part of an episode, chosen by the tool's kind. `passed` turns true once the learner has done what the tool asks.
struct LabToolView: View {
    let tool: LabTool
    @Binding var passed: Bool

    var body: some View {
        switch tool.kind {
        case .switches: LabSwitchesTool(tool: tool, passed: $passed)
        case .chips: if tool.mode == "toggle" { LabComposeTool(tool: tool, passed: $passed) } else { LabChipsTool(tool: tool, passed: $passed) }
        case .stamps: LabStampsTool(tool: tool, passed: $passed)
        case .marks: LabMarksTool(tool: tool, passed: $passed)
        case .equip: LabEquipTool(tool: tool, passed: $passed)
        case .rot: LabRotTool(tool: tool, passed: $passed)
        }
    }
}

/// The AI's answer under a tool, with a small label above it in the measuring voice.
private struct LabAnswer: View {
    var meta: String?
    let text: String
    var note: String?
    var tone: LabMeter.Tone = .measure
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meta, !meta.isEmpty { Text(meta).font(LabFont.number(11)).tracking(1).foregroundStyle(.secondary) }
            Text(text).font(.system(size: 15)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if let note, !note.isEmpty {
                Text(note).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone == .pass ? LabPalette.pass : tone == .fail ? LabPalette.fail : LabPalette.gauge)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1) }
        .animation(.easeOut(duration: 0.2), value: text)
        .accessibilityElement(children: .combine).accessibilityIdentifier("lab.answer")
    }
}

// MARK: - Switches

/// Switches under a prompt: each setting has its own answer, or, once every switch is set, an answer put together from them.
struct LabSwitchesTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var picks: [Int?] = []
    /// The passing settings reached so far, for tools that ask for more than one.
    @State private var reached: Set<[Int]> = []

    private var controls: [LabControl] { tool.controls ?? [] }

    private var composed: (meta: String?, text: String, score: Int)? {
        guard let compose = tool.compose, !picks.isEmpty, picks.allSatisfy({ $0 != nil }) else { return nil }
        let lines = zip(controls, picks).compactMap { control, pick in pick.flatMap { control.options[$0].line?.text } }
        let text = ([compose.head?.text] + lines.map { "· " + $0 } + [compose.tail?.text]).compactMap { $0 }.joined(separator: "\n")
        return (compose.meta?.text, text, compose.score)
    }
    private var result: LabResult? { (tool.results ?? []).first { $0.matches(picks) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let prompt = tool.prompt { LabPromptBox(text: prompt.text) { EmptyView() } }
            ForEach(controls.indices, id: \.self) { index in
                LabControlView(control: controls[index], pick: Binding(get: { picks.indices.contains(index) ? picks[index] : nil },
                                                                     set: { value in picks[index] = value; LabHaptic.tick(); check() }),
                               index: index)
            }
            let score = composed?.score ?? result?.score ?? 0
            if let gauge = tool.gauge { LabMeter(label: gauge.text, value: score, tone: passed ? .pass : .measure) }
            if let composed {
                LabAnswer(meta: composed.meta, text: composed.text, note: nil, tone: .pass)
            } else if let result {
                LabAnswer(meta: result.meta?.text, text: result.reply.text, note: result.note?.text, tone: result.pass == true ? .pass : .measure)
            }
            if let need = tool.need, need > 1 {
                Text(L10n.text("lab.switches.reached", String(min(reached.count, need)), String(need)))
                    .font(LabFont.number(12)).foregroundStyle(.secondary)
            }
        }
        .onAppear { if picks.isEmpty { picks = controls.map { $0.unset == true ? nil : 0 }; check() } }
    }

    private func check() {
        if composed != nil { pass(); return }
        guard let result, result.pass == true else { return }
        reached.insert(picks.map { $0 ?? -1 })
        if reached.count >= (tool.need ?? 1) { pass() }
    }
    private func pass() { guard !passed else { return }; LabHaptic.pass(); withAnimation { passed = true } }
}

/// One switch: a segmented control when its positions are short, a column of rows when they are sentences.
private struct LabControlView: View {
    let control: LabControl
    @Binding var pick: Int?
    let index: Int
    var body: some View {
        let long = control.options.contains { $0.label.text.count > 12 }
        VStack(alignment: .leading, spacing: 8) {
            Text(control.label.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if long {
                VStack(spacing: 8) {
                    ForEach(control.options.indices, id: \.self) { option in
                        Button { pick = option } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: pick == option ? "checkmark.circle.fill" : "circle").foregroundStyle(pick == option ? Color.accentColor : .secondary)
                                Text(control.options[option].label.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 15, weight: .medium)).padding(.vertical, 4)
                        }
                        .labSecondary().buttonBorderShape(.roundedRectangle(radius: 16))
                        .accessibilityAddTraits(pick == option ? .isSelected : [])
                        .accessibilityIdentifier("lab.switch.\(index).\(option)")
                    }
                }
            } else {
                Picker(control.label.text, selection: $pick) {
                    ForEach(control.options.indices, id: \.self) { option in Text(control.options[option].label.text).tag(Optional(option)) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("lab.switch.\(index)")
            }
        }
    }
}

// MARK: - Chips

/// Chips that go after the prompt, one at a time. Each press shows the AI's inner voice first, then its answer; pressing again can make it worse.
struct LabChipsTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var chosen: Int?
    @State private var presses: [Int: Int] = [:]
    @State private var thinking = false

    private var chips: [LabChip] { tool.chips ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabPromptBox(text: tool.prompt?.text ?? "") {
                if let chosen {
                    if let attach = chips[chosen].attach {
                        Text(attach.text).font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(LabPalette.paper.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .foregroundStyle(LabPalette.paperMuted)
                    }
                    Text("+ " + chips[chosen].label.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
            }
            LabFlow {
                ForEach(chips.indices, id: \.self) { index in
                    Button { press(index) } label: { Text(chips[index].label.text).font(.system(size: 15, weight: .semibold)) }
                        .labSecondary().buttonBorderShape(.capsule)
                        .accessibilityIdentifier("lab.chip.\(index)")
                }
            }
            if let chosen {
                let chip = chips[chosen]
                if let think = chip.think {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "brain").foregroundStyle(.secondary)
                        Text(think.text).font(.system(size: 14).italic()).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("lab.think")
                }
                if !thinking {
                    if let gauge = tool.gauge { LabMeter(label: gauge.text, value: chip.score ?? 0, tone: chip.pass == true ? .pass : .measure) }
                    LabAnswer(text: reply(chip, presses[chosen] ?? 1), tone: chip.pass == true ? .pass : .measure)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: thinking)
        .animation(.snappy(duration: 0.25), value: chosen)
    }

    private func reply(_ chip: LabChip, _ count: Int) -> String {
        guard let replies = chip.replies, !replies.isEmpty else { return "" }
        return replies[min(count, replies.count) - 1].text
    }

    private func press(_ index: Int) {
        LabHaptic.tick()
        presses[index, default: 0] += 1
        chosen = index
        let chip = chips[index]
        thinking = chip.think != nil
        Task {
            if chip.think != nil { try? await Task.sleep(for: .milliseconds(700)) }
            thinking = false
            if chip.pass == true, !passed { LabHaptic.pass(); withAnimation { passed = true } }
        }
    }
}

/// Chips that are switched on and off, each adding a line to a card the learner can copy.
struct LabComposeTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var on: Set<Int> = []
    private var chips: [LabChip] { tool.chips ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabFlow {
                ForEach(chips.indices, id: \.self) { index in
                    let chosen = on.contains(index)
                    Button {
                        LabHaptic.tick()
                        if chosen { on.remove(index) } else { on.insert(index) }
                        if on.count >= (tool.need ?? 1), !passed { LabHaptic.pass(); withAnimation { passed = true } }
                    } label: {
                        Label(chips[index].label.text, systemImage: chosen ? "checkmark" : "plus").font(.system(size: 15, weight: .semibold))
                    }
                    .modifier(LabChipStyle(on: chosen))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("lab.chip.\(index)")
                }
            }
            let lines = on.sorted().compactMap { chips[$0].line?.text }
            VStack(alignment: .leading, spacing: 10) {
                Text(tool.head?.text ?? "").font(LabFont.number(11)).tracking(1).foregroundStyle(LabPalette.paperMuted)
                if lines.isEmpty {
                    LabDashedRule(color: LabPalette.paperRule).padding(.vertical, 8)
                } else {
                    Text(lines.joined(separator: "\n")).font(.system(size: 15, weight: .medium)).lineSpacing(4).foregroundStyle(LabPalette.paperInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !lines.isEmpty {
                    LabCopyButton(text: lines.joined(separator: "\n")).font(.system(size: 14, weight: .semibold)).tint(LabPalette.paperInk)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { LabCardBackground(state: .blank, radius: 18) }
            .animation(.snappy, value: on)
        }
    }
}

private struct LabChipStyle: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.labPrimary().buttonBorderShape(.capsule).controlSize(.regular) } else { content.labSecondary().buttonBorderShape(.capsule).controlSize(.regular) }
    }
}

// MARK: - Stamps

/// Paper cards one after another, each stamped with one of two verdicts; the answer shows once it is stamped.
struct LabStampsTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var stamped: [Int] = []

    private var items: [LabStampItem] { tool.items ?? [] }
    private var labels: [String] { (tool.stamps ?? []).map(\.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(min(stamped.count + 1, items.count)) / \(items.count)").font(LabFont.number(12)).foregroundStyle(.secondary)
            if stamped.count < items.count {
                let item = items[stamped.count]
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.text.text).font(LabFont.voice(21)).foregroundStyle(LabPalette.paperInk).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    LabDashedRule(color: LabPalette.paperRule)
                }
                .padding(20)
                .background { LabCardBackground(state: .blank, radius: 20) }
                .id(stamped.count)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                HStack(spacing: 10) {
                    ForEach(labels.indices, id: \.self) { index in
                        Button { stamp(index) } label: { Text(labels[index]).frame(maxWidth: .infinity) }
                            .labSecondary().buttonBorderShape(.roundedRectangle(radius: 16))
                            .accessibilityIdentifier("lab.stamp.\(index)")
                    }
                }
            } else {
                let right = zip(items, stamped).filter { $0.answer == $1 }.count
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("lab.stamps.score", String(right), String(items.count))).font(LabFont.number(15)).foregroundStyle(LabPalette.pass)
                    if let summary = tool.summary { Text(summary.text).font(LabFont.voice(22)) }
                }
            }
            ForEach(Array(zip(items, stamped).enumerated()).reversed(), id: \.offset) { offset, pair in
                LabStampedRow(item: pair.0, pick: pair.1, label: labels.indices.contains(pair.1) ? labels[pair.1] : "")
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: stamped)
    }

    private func stamp(_ index: Int) {
        LabHaptic.press()
        stamped.append(index)
        if stamped.count == items.count { LabHaptic.pass(); withAnimation { passed = true } }
    }
}

private struct LabStampedRow: View {
    let item: LabStampItem
    let pick: Int
    let label: String
    var body: some View {
        let right = item.answer == pick
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .heavy))
                .foregroundStyle(right ? LabPalette.pass : LabPalette.fail)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(right ? LabPalette.pass : LabPalette.fail, lineWidth: 1.5) }
                .rotationEffect(.degrees(-4))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text.text).font(.system(size: 14, weight: .semibold))
                if let reveal = item.reveal { Text(reveal.text).font(.system(size: 13)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Marks

/// Pieces of text to strike out (`cut`), stamp as made up (`flag`) or black out (`mask`).
struct LabMarksTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var marked: Set<Int> = []
    @State private var shaking: Int?
    @State private var complaint: String?
    @State private var started: Date?
    @State private var took: TimeInterval?

    private var pieces: [LabPiece] { tool.pieces ?? [] }
    private var style: String { tool.style ?? "cut" }
    private var targets: Int { pieces.filter(\.isTarget).count }
    private var hits: Int { marked.filter { pieces[$0].isTarget }.count }
    private var misses: Int { marked.filter { !pieces[$0].isTarget }.count }
    private var score: Int { targets == 0 ? 0 : max(0, min(100, (hits - misses) * 100 / targets)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if style == "mask" { maskText } else { lines }
            if let gauge = tool.gauge {
                LabMeter(label: gauge.text, value: score, tone: misses > 0 ? .fail : passed ? .pass : .measure)
            }
            if let complaint {
                Text(complaint).font(.system(size: 13, weight: .semibold)).foregroundStyle(LabPalette.fail).transition(.opacity)
            }
            if style == "cut" { output }
            if let took, passed {
                Text(L10n.text("lab.marks.time", String(format: "%.1f", took))).font(LabFont.number(15)).foregroundStyle(LabPalette.pass)
            }
        }
        .animation(.snappy(duration: 0.25), value: marked)
        .animation(.snappy(duration: 0.25), value: complaint)
        .onAppear { started = started ?? Date() }
    }

    private var lines: some View {
        VStack(spacing: 0) {
            ForEach(pieces.indices, id: \.self) { index in
                let piece = pieces[index]
                let on = marked.contains(index)
                Button { tap(index) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(on ? Color.secondary.opacity(0.3) : LabPalette.gauge).frame(width: 3, height: 18).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(piece.text.text).font(.system(size: 14)).multilineTextAlignment(.leading)
                                .strikethrough(style == "cut" && on).foregroundStyle(style == "cut" && on ? .secondary : .primary)
                            if style == "flag", on, let why = piece.why {
                                Text(why.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(LabPalette.fail)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if style == "flag", on {
                            Text(L10n.text("lab.marks.fake")).font(.system(size: 11, weight: .heavy)).foregroundStyle(LabPalette.fail)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(LabPalette.fail, lineWidth: 1.5) }
                                .rotationEffect(.degrees(-6))
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: shaking == index ? 6 : 0)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("lab.piece.\(index)")
                if index < pieces.count - 1 { Divider().padding(.leading, 27) }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var maskText: some View {
        LabFlow(spacing: 0, lineSpacing: 6) {
            ForEach(pieces.indices, id: \.self) { index in
                let piece = pieces[index]
                let on = marked.contains(index)
                Button { tap(index) } label: {
                    Text(on ? (piece.swap?.text ?? "●●●") : piece.text.text)
                        .font(.system(size: 16, weight: piece.isTarget || on ? .semibold : .regular))
                        .foregroundStyle(on ? Color(uiColor: .systemBackground) : .primary)
                        .padding(.horizontal, on ? 6 : 0).padding(.vertical, 2)
                        .background(on ? Color.primary : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .offset(x: shaking == index ? 5 : 0)
                .accessibilityIdentifier("lab.piece.\(index)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var output: some View {
        let text: LabText? = misses > 0 ? (tool.wrong ?? tool.before) : passed ? tool.after : hits * 2 >= targets ? (tool.middle ?? tool.before) : tool.before
        if let text {
            LabAnswer(text: text.text, tone: misses > 0 ? .fail : passed ? .pass : .measure)
        }
    }

    private func tap(_ index: Int) {
        let piece = pieces[index]
        if style != "cut", !piece.isTarget {
            // Only made-up or private pieces can be marked; anything else says why and stays.
            LabHaptic.miss()
            complaint = tool.wrong?.text
            withAnimation(.spring(duration: 0.12, bounce: 0.8)) { shaking = index }
            Task { try? await Task.sleep(for: .milliseconds(180)); withAnimation { shaking = nil }; try? await Task.sleep(for: .seconds(1.4)); complaint = nil }
            return
        }
        guard style == "cut" || !marked.contains(index) else { return }
        LabHaptic.tick()
        if marked.contains(index) { marked.remove(index) } else { marked.insert(index) }
        let done = hits == targets && misses == 0
        if done, !passed {
            took = started.map { Date().timeIntervalSince($0) }
            LabHaptic.pass(); withAnimation { passed = true }
        }
    }
}

// MARK: - Equip

/// A brain (or a prompt box) in the middle and gear to fit to it, by dragging or tapping; missions clear as the right gear goes on.
struct LabEquipTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var fitted: [String] = []
    @State private var note: String?
    @State private var targeted = false

    private var gear: [LabGear] { tool.gear ?? [] }
    private var missions: [LabMission] { tool.missions ?? [] }
    private func done(_ mission: LabMission) -> Bool { mission.needs.allSatisfy(fitted.contains) }

    var body: some View {
        VStack(spacing: 18) {
            core
            LabFlow {
                ForEach(gear) { item in
                    let on = fitted.contains(item.id)
                    Button { toggle(item) } label: { Label(item.label.text, systemImage: item.symbol ?? "puzzlepiece").font(.system(size: 14, weight: .semibold)) }
                        .modifier(LabChipStyle(on: on))
                        .draggable(item.id)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("lab.gear.\(item.id)")
                }
            }
            if let note { Text(note).font(.system(size: 13, weight: .semibold)).foregroundStyle(LabPalette.fail).transition(.opacity) }
            VStack(spacing: 0) {
                ForEach(missions.indices, id: \.self) { index in
                    let mission = missions[index]
                    let ok = done(mission)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? LabPalette.pass : .secondary).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mission.text.text).font(.system(size: 15, weight: .semibold))
                            Text((ok ? mission.after : mission.before).text).font(.system(size: 13)).foregroundStyle(ok ? .primary : .secondary)
                                .contentTransition(.opacity)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("lab.mission.\(index)")
                    if index < missions.count - 1 { Divider().padding(.leading, 44) }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: fitted)
        .animation(.snappy, value: note)
    }

    private var core: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color(uiColor: .secondarySystemBackground)).frame(width: 120, height: 120)
                    .overlay { Circle().strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: targeted ? 3 : 1, dash: fitted.isEmpty ? [5, 5] : [])) }
                Image(systemName: tool.core?.text == nil ? "brain" : "brain.head.profile").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            }
            .scaleEffect(targeted ? 1.06 : 1)
            .dropDestination(for: String.self) { ids, _ in
                for id in ids { if let item = gear.first(where: { $0.id == id }), !fitted.contains(id) { toggle(item) } }
                return true
            } isTargeted: { targeted = $0 }
            Text(tool.core?.text ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if !fitted.isEmpty {
                Text(fitted.compactMap { id in gear.first { $0.id == id }?.label.text }.joined(separator: " + "))
                    .font(LabFont.number(12)).foregroundStyle(LabPalette.gauge).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("lab.core")
    }

    private func toggle(_ item: LabGear) {
        LabHaptic.press()
        if let index = fitted.firstIndex(of: item.id) { fitted.remove(at: index); note = nil; return }
        fitted.append(item.id)
        note = item.miss?.text
        if missions.allSatisfy(done), !passed { LabHaptic.pass(); withAnimation { passed = true } }
    }
}

// MARK: - Rot

/// "Write it again" pressed over and over: each answer is worse and the memory fills with old failures, until the learner leaves for a new chat.
struct LabRotTool: View {
    let tool: LabTool
    @Binding var passed: Bool
    @State private var retries = 0
    @State private var fresh = false

    private var replies: [LabText] { tool.replies ?? [] }
    private var rot: Int { fresh ? 0 : min(100, retries * 100 / max(1, replies.count)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let gauge = tool.gauge { LabMeter(label: gauge.text, value: rot, tone: fresh ? .pass : rot >= 75 ? .fail : .measure) }
            VStack(spacing: 10) {
                if fresh {
                    Text(L10n.text("lab.rot.newChat")).font(LabFont.number(11)).tracking(1).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    LabBubble(text: tool.carry?.text ?? "", mine: true)
                    LabBubble(text: tool.fresh?.text ?? "")
                } else {
                    ForEach(0..<retries, id: \.self) { index in
                        LabBubble(text: tool.retry?.text ?? "", mine: true)
                        LabBubble(text: replies[min(index, replies.count - 1)].text,
                                  tint: LabPalette.fail.opacity(Double(index + 1) / Double(max(1, replies.count)) * 0.22))
                    }
                }
            }
            .transition(.opacity)
            if !fresh {
                HStack(spacing: 10) {
                    Button {
                        LabHaptic.tick()
                        retries += 1
                    } label: { Label(tool.retry?.text ?? "", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .labSecondary().buttonBorderShape(.roundedRectangle(radius: 16))
                        .accessibilityIdentifier("lab.rot.retry")
                    if retries >= (tool.minRetries ?? 2) {
                        Button {
                            LabHaptic.pass()
                            withAnimation(.snappy(duration: 0.4)) { fresh = true; passed = true }
                        } label: { Label(tool.reset?.text ?? "", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                            .labPrimary().buttonBorderShape(.roundedRectangle(radius: 16))
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityIdentifier("lab.rot.reset")
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: retries)
    }
}
