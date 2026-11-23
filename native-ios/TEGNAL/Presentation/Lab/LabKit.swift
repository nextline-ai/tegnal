import SwiftUI
import UIKit

// MARK: - Colour

/// The lab's few colours. Screens use the system background and stock lists; these are only for the lab's own things.
/// Material rule: deep solid colour is what no longer changes (an engraved card); paper is what still changes (a blank card, the cheat sheet).
enum LabPalette {
    static let paper = Color(labHex: "ECE9E2")
    static let paperInk = Color(labHex: "1D1D1F")
    static let paperMuted = Color(labHex: "5C5A55")
    static let paperRule = Color(labHex: "8A867D")
    /// Measured values: the rate and every gauge.
    static let gauge = Color(labLight: "A86400", dark: "FFB02E")
    /// A tool passed.
    static let pass = Color(labLight: "1E8A50", dark: "5BE49B")
    /// A 망작.
    static let fail = Color(labLight: "D0432A", dark: "FF6B4A")
    /// 먹, the system sheet's sixth card colour. Engraved cards take the course's other five in turn; this one is kept for card No. 000.
    static let ink = "3A3A3C"
    /// The main button: near-white in dark appearance, ink in light.
    static let primary = Color(labLight: "1D1D1F", dark: "F5F5F7")
    static let onPrimary = Color(labLight: "FFFFFF", dark: "000000")
    /// A grey surface, a little lighter for each step back in a stack.
    static func surface(_ step: Int = 0) -> Color {
        Color(uiColor: UIColor { trait in
            let dark = trait.userInterfaceStyle == .dark
            let base: CGFloat = dark ? 0.110 : 0.949
            let level = dark ? base + CGFloat(step) * 0.025 : base - CGFloat(step) * 0.02
            return UIColor(white: level, alpha: 1)
        })
    }

    /// The light ink printed on a card of this colour: the colour mixed far towards white.
    static func tint(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0x3A3A3C
        func mix(_ channel: UInt32) -> Double { (Double(channel) / 255) * 0.3 + 0.7 }
        return Color(red: mix((value >> 16) & 0xFF), green: mix((value >> 8) & 0xFF), blue: mix(value & 0xFF))
    }
}

extension Color {
    init(labHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x3A3A3C
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    init(labLight light: String, dark: String) {
        self.init(uiColor: UIColor { UIColor(Color(labHex: $0.userInterfaceStyle == .dark ? dark : light)) })
    }
    /// Text on a signal colour: black on the bright dark-mode shades, white on the deeper light-mode ones.
    static let labOnSignal = Color(labLight: "FFFFFF", dark: "000000")
}

// MARK: - Type

/// Three voices: serif for the content (titles, verdicts, the engraved line), the system font for the app, monospaced for numbers.
enum LabFont {
    /// The content voice at its heaviest: titles and verdicts. The system's sans-serif, like the rest of learning mode
    /// (user, 2026-11-24: the serif is kept only for viewing mode's recap).
    static func voice(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .system(size: size, weight: .bold)
    }
    /// The content voice, lighter: a line on a small card.
    static func line(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func number(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

extension View {
    /// Every line in the lab sits 130% of its font size below the one before (iOS 26 and later). Set once on each of the lab's screens.
    @ViewBuilder func labLines() -> some View {
        if #available(iOS 26, *) { lineHeight(.multiple(factor: 1.3)) } else { self }
    }
    /// A little extra room between lines before iOS 26, where the fixed line height is not available.
    @ViewBuilder func labSpacing(_ value: CGFloat) -> some View {
        if #available(iOS 26, *) { self } else { lineSpacing(value) }
    }
    /// A card's shadow, cast by its outline only: the text and buttons on it cast none.
    func labCardShadow(_ color: Color = .black.opacity(0.4), radius: CGFloat = 12, y: CGFloat = -8) -> some View {
        compositingGroup().shadow(color: color, radius: radius, y: y)
    }
}

// MARK: - Headers

/// The top of each lab tab, as the mockups draw it: a quiet line above a large title, and something on the right.
struct LabHeader<Trailing: View>: View {
    let kicker: Text
    let title: String
    /// The quiet line goes under the title, as on every tab of the lab.
    var below = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if !below { line }
                Text(title).font(.system(size: 34, weight: .heavy)).tracking(-0.5).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if below { line }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.top, 8)
    }

    private var line: some View { kicker.font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1) }
}

extension LabHeader where Trailing == EmptyView {
    init(kicker: Text, title: String) { self.init(kicker: kicker, title: title) { EmptyView() } }
}

// MARK: - The card

/// A card of the deck in one of its three states.
struct LabCardFace: View {
    enum State { case blank, earned, locked }
    let serial: String
    var title: String
    var line: String?
    /// The card's colour, six hexadecimal digits.
    var color: String = LabPalette.ink
    var state: State
    /// A short label at the top right, such as the card's name.
    var label: String?
    var footer: String?
    var date: String?
    /// How many letters of the line are pressed in so far, while it is being engraved. Nil shows the whole line.
    var engraved: Double?
    var large = false
    /// Content at the top, as for a card peeking out of the stack.
    var top = false

    var body: some View {
        let tint = LabPalette.tint(color)
        let ink: Color = state == .earned ? .white : state == .locked ? .secondary : LabPalette.paperInk
        let muted: Color = state == .earned ? tint : state == .locked ? .secondary : LabPalette.paperMuted
        VStack(alignment: .leading, spacing: large ? 14 : 6) {
            HStack {
                Text(state == .earned && large ? "AI LAB" : serial).font(.system(size: 11, weight: .bold)).tracking(1.6)
                Spacer()
                if state == .earned && large { Text(serial).font(.system(size: 11, weight: .bold)).tracking(1.6) }
                else if let label { Text(label).font(.system(size: 11, weight: .bold)).tracking(1.4) }
                if state == .locked { Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(muted)
            if !top { Spacer(minLength: 0) }
            if state == .earned, let line {
                if large { Rectangle().fill(tint).frame(width: 28, height: 2).padding(.bottom, 2) }
                LabEngravedText(text: line, revealed: engraved, font: large ? LabFont.voice(28) : LabFont.line(16), color: ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(title).font(state == .locked && top ? .system(size: 13, weight: .semibold) : LabFont.voice(large ? 26 : 14))
                    .foregroundStyle(ink)
                    .lineLimit(state == .locked && top ? 1 : large ? 4 : 3).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state == .blank { LabDashedRule(color: LabPalette.paperRule) }
            }
            if top { Spacer(minLength: 0) }
            if let footer {
                HStack {
                    Text(footer).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    Spacer()
                    if let date { Text(date).font(LabFont.number(11, .medium)) }
                }
                .foregroundStyle(muted)
            }
        }
        .padding(.horizontal, large ? 24 : 20).padding(.vertical, large ? 22 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { LabCardBackground(state: state, color: color, radius: large ? 24 : 20) }
        .accessibilityElement(children: .combine)
    }
}

struct LabCardBackground: View {
    let state: LabCardFace.State
    var color: String = LabPalette.ink
    var radius: CGFloat = 20
    var step = 0
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch state {
        case .earned:
            // Flat, deep colour with a hairline of light along the top edge, as an enamelled card.
            shape.fill(Color(labHex: color))
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
        case .locked:
            // A locked card shows only its title, on the plain grey of the system: the title is the bait.
            shape.fill(LabPalette.surface(step))
        case .blank:
            shape.fill(LabPalette.paper)
                .overlay { shape.strokeBorder(.black.opacity(0.05), lineWidth: 0.5) }
        }
    }
}

/// The engraved line, pressed in one letter at a time while `revealed` climbs. Each letter arrives from a little above, out of a blur.
struct LabEngravedText: View {
    let text: String
    var revealed: Double?
    let font: Font
    let color: Color
    var body: some View {
        let label = Text(text).font(font).foregroundStyle(color)
        if let revealed {
            if #available(iOS 18, *) {
                label.textRenderer(LabEngraveRenderer(revealed: revealed))
            } else {
                Text(String(text.prefix(Int(revealed)))).font(font).foregroundStyle(color)
            }
        } else {
            label
        }
    }
}

@available(iOS 18, *)
struct LabEngraveRenderer: TextRenderer, Animatable {
    var revealed: Double
    var animatableData: Double {
        get { revealed }
        set { revealed = newValue }
    }
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                for glyph in run {
                    // 0 before its turn, 1 once pressed in.
                    let t = max(0, min(1, (revealed - index) * 1.6))
                    if t > 0 {
                        var copy = context
                        copy.opacity = t
                        if t < 1 { copy.addFilter(.blur(radius: (1 - t) * 5)) }
                        copy.translateBy(x: 0, y: (1 - t) * -7)
                        copy.draw(glyph)
                    }
                    index += 1
                }
            }
        }
    }
}

/// Turns over in one unbroken movement: the front shows until it is edge-on, then the back, the right way round.
struct LabFlip<Front: View, Back: View>: View, Animatable {
    var angle: Double
    @ViewBuilder var front: Front
    @ViewBuilder var back: Back
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    var body: some View {
        ZStack {
            if angle < 90 { front } else { back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0)) }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.42)
    }
}

/// A band of light that crosses a card once, as when it catches the light.
struct LabSheen: View {
    var progress: Double
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            // Taller than the card, so the slanted band still covers it from top to bottom; it starts and ends wholly off the card.
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.5, height: height * 1.8)
                .rotationEffect(.degrees(18))
                .position(x: -width * 0.7 + width * 2.4 * progress, y: height / 2)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dotted line on a blank card where its sentence will be engraved.
struct LabDashedRule: View {
    var color: Color
    var body: some View {
        Line().stroke(color, style: StrokeStyle(lineWidth: 1, dash: [4, 4])).frame(height: 1).accessibilityHidden(true)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }
}

/// A card under a finger sinks a little and comes back with a spring.
struct LabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(duration: 0.3, bounce: 0.35), value: configuration.isPressed)
    }
}

// MARK: - Gauges

/// The rate as a dial: three quarters of a ring, the number in the middle.
struct LabRing: View {
    let value: Int
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(LabPalette.surface(1), style: StrokeStyle(lineWidth: size * 0.078, lineCap: .round))
            Circle().trim(from: 0, to: 0.75 * CGFloat(min(100, max(0, value))) / 100)
                .stroke(LabPalette.gauge, style: StrokeStyle(lineWidth: size * 0.078, lineCap: .round))
        }
        .rotationEffect(.degrees(135))
        .overlay {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(String(value)).font(LabFont.number(size * 0.25)).tracking(-0.6).contentTransition(.numericText(value: Double(value)))
                Text("%").font(LabFont.number(size * 0.155))
            }
            .foregroundStyle(LabPalette.gauge)
        }
        .frame(width: size, height: size)
    }
}

/// A gauge bar for a tool's measure, 0 to 100. Amber while it climbs, green when passed, red when it went wrong.
struct LabMeter: View {
    let label: String
    let value: Int
    var tone: Tone = .measure
    enum Tone { case measure, pass, fail }
    var color: Color { switch tone { case .measure: LabPalette.gauge; case .pass: LabPalette.pass; case .fail: LabPalette.fail } }
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(LabFont.number(11)).tracking(1).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(LabPalette.surface(1))
                    Capsule().fill(color).frame(width: proxy.size.width * CGFloat(min(100, max(0, value))) / 100)
                }
            }
            .frame(height: 8)
            Text(String(value)).font(LabFont.number(15)).foregroundStyle(color).frame(minWidth: 34, alignment: .trailing)
                .contentTransition(.numericText(value: Double(value)))
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: value)
        .animation(.easeOut(duration: 0.25), value: tone)
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(String(value))
        .accessibilityIdentifier("lab.meter")
    }
}

/// A quiet tag: "망작 No. 07 · 전시됨", "통과", a date.
struct LabTag: View {
    let text: String
    var color: Color
    var ink: Color = .labOnSignal
    var mono = false
    var body: some View {
        Text(text).font(mono ? LabFont.number(11) : .system(size: 12, weight: .bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(color, in: Capsule())
    }
}

// MARK: - Chat

/// A fake chat line: the learner on the right, the AI on the left.
struct LabBubble: View {
    let text: String
    var mine = false
    var tint: Color?
    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            Text(text).font(.system(size: 15))
                .foregroundStyle(mine ? Color(uiColor: .systemBackground) : .primary)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(mine ? AnyShapeStyle(Color.primary) : AnyShapeStyle(tint ?? LabPalette.surface()),
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: mine ? 20 : 6, bottomTrailingRadius: mine ? 6 : 20, topTrailingRadius: 20, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: 32) }
        }
    }
}

/// The fake prompt box of an AI app: what the learner asked, with what has been attached under it.
struct LabPromptBox<Footer: View>: View {
    let text: String
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(14)
        .background(LabPalette.surface(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Layout

/// Lays pieces out in rows that wrap, like words.
struct LabFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in rows(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))))
        }
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + lineSpacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + row))
    }
}

// MARK: - Buttons

extension View {
    /// The main action: prominent glass on iOS 26, the prominent bordered style before. Ink on paper-white in dark appearance,
    /// white on ink in light, as the system sheet draws it, rather than the app's accent colour.
    @ViewBuilder func labPrimary() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).controlSize(.large).tint(LabPalette.primary).foregroundStyle(LabPalette.onPrimary)
        } else {
            buttonStyle(.borderedProminent).controlSize(.large).tint(LabPalette.primary).foregroundStyle(LabPalette.onPrimary)
        }
    }
    /// A secondary action: glass on iOS 26, bordered before.
    @ViewBuilder func labSecondary() -> some View {
        if #available(iOS 26, *) { buttonStyle(.glass).controlSize(.large) } else { buttonStyle(.bordered).controlSize(.large) }
    }
}

/// Copies a text to the clipboard and says so for a moment.
struct LabCopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation { copied = true }
            Task { try? await Task.sleep(for: .seconds(1.5)); withAnimation { copied = false } }
        } label: {
            Label(L10n.text(copied ? "lab.copied" : "lab.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .accessibilityIdentifier("lab.copy")
    }
}

/// A short tap felt under the finger, for each change a tool makes.
@MainActor enum LabHaptic {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notice = UINotificationFeedbackGenerator()
    static func tick() { light.impactOccurred(intensity: 0.7) }
    /// One letter pressed into a card.
    static func press(_ intensity: CGFloat = 0.9) { soft.impactOccurred(intensity: intensity) }
    static func snap() { rigid.impactOccurred(intensity: 0.8) }
    static func pass() { notice.notificationOccurred(.success) }
    static func miss() { notice.notificationOccurred(.warning) }
}

extension LabCourse {
    /// The colour of an episode's engraved card, six hexadecimal digits: the course's card colours in turn, by the card's number.
    func color(_ episode: LabEpisode) -> String {
        let colors = info.cardColors ?? []
        guard !colors.isEmpty else { return LabPalette.ink }
        return colors[(max(1, episode.number) - 1) % colors.count]
    }
}

extension LabEpisode {
    /// The short name, or the number where there is none.
    var label: String { name?.text ?? serial }
}

extension Date {
    /// `2026.11.23`.
    var labStamp: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return String(format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// "세 번째", "3rd", "3番目" for the engraving's title.
enum LabOrdinal {
    static func text(_ number: Int, language: String = L10n.language) -> String {
        switch language {
        case "ko":
            let words = ["첫", "두", "세", "네", "다섯", "여섯", "일곱", "여덟", "아홉", "열", "열한", "열두", "열세", "열네", "열다섯", "열여섯", "열일곱", "열여덟", "열아홉", "스무"]
            return (number >= 1 && number <= words.count ? words[number - 1] : String(number)) + " 번째"
        case "ja": return "\(number)番目"
        default:
            let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
            return "\(number)\(suffix)"
        }
    }
}

// MARK: - A wrong answer

extension EnvironmentValues {
    /// Tints the whole episode red for a moment: a wrong answer, felt at once. Set by `LabEpisodeView`; tools call it.
    @Entry var labMistake: @MainActor () -> Void = {}
}

/// The red wash over the whole screen after a wrong answer: in fast, out slowly. Lets touches through.
struct LabMistakeWash: View {
    let count: Int
    @State private var shown = false
    var body: some View {
        LabPalette.fail.opacity(shown ? 0.22 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: count) {
                withAnimation(.easeOut(duration: 0.08)) { shown = true }
                withAnimation(.easeIn(duration: 0.55).delay(0.12)) { shown = false }
            }
    }
}
