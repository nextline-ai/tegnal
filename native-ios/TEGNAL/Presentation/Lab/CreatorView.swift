import SwiftUI

// MARK: - Who made this

/// Who makes TEGNAL and its courses: NextLine, the studio behind them (https://nextline.work). Shown as a page in each built-in
/// course's onboarding (the AI lab before its one-minute check, 2D AI 배우기 after its hello) and behind a "누가 만들었나요?" button
/// in the 코스 tab and the 2D course's Me tab, so a learner can see who stands behind the lessons.
///
/// The figures are the ones NextLine publishes on its own site; keep them in step with it.
enum Creator {
    static let site = URL(string: "https://nextline.work")!
    static let mail = URL(string: "mailto:contact@nextline.work")!
    static let ink = Color(labHex: "F5F2EE")
    static let muted = Color(labHex: "9C978F")
    static let ground = Color(labHex: "0C0B0B")
    static let raised = Color(labHex: "1A1817")
    /// The mark's colours, from hot pink through red to amber, as on the site.
    static let gradient = LinearGradient(stops: [
        .init(color: Color(labHex: "FF0D5E"), location: 0), .init(color: Color(labHex: "FF240C"), location: 0.38),
        .init(color: Color(labHex: "FF732D"), location: 0.62), .init(color: Color(labHex: "FFB047"), location: 0.82),
        .init(color: Color(labHex: "FFD356"), location: 1),
    ], startPoint: .topLeading, endPoint: .bottomTrailing)

    struct Record: Identifiable {
        let id: String
        let value: String
        var label: String { "creator.\(id).label" }
        var detail: String { "creator.\(id).detail" }
    }
    static let records = [Record(id: "chatbot", value: "creator.chatbot.value"), Record(id: "app", value: "TOP 25"), Record(id: "edu", value: "#1"),
                          Record(id: "usage", value: "creator.usage.value")]
    static let work = ["creator.work.prompt", "creator.work.design", "creator.work.build", "creator.work.teach"]
}

/// NextLine's mark: the N drawn as two strokes, a bar and a falling diagonal.
struct NextLineMark: Shape {
    func path(in rect: CGRect) -> Path {
        // The site's own drawing, in its 652 × 514 box from (186, 255).
        let box = CGRect(x: 186, y: 255, width: 652, height: 514)
        let scale = min(rect.width / box.width, rect.height / box.height)
        let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + (x - box.minX) * scale, y: origin.y + (y - box.minY) * scale) }
        var path = Path()
        path.addLines([point(528.6, 460.1), point(528.6, 628.76), point(660.76, 760.92), point(829.42, 760.92)])
        path.closeSubpath()
        path.addLines([point(312.53, 263.08), point(194.59, 263.08), point(194.59, 760.92), point(312.84, 760.92), point(312.84, 432.05),
                       point(433.74, 552.95), point(433.74, 384.29)])
        path.closeSubpath()
        return path
    }
}

/// The page itself, dark in either appearance as NextLine's own pages are. In an onboarding it adds why the course can be trusted.
struct CreatorProfile: View {
    /// Shown inside a course's onboarding: one more line, about the course.
    var onboarding = false
    /// On a dark card of its own, for screens of another colour. The page that stands alone is the dark ground itself.
    var framed = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            section("creator.records") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Creator.records.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { rule }
                        record(item).padding(.top, index == 0 ? -16 : 0)
                    }
                    rule
                    Text(L10n.text("creator.records.note")).font(.system(size: 14)).italic().foregroundStyle(Creator.muted)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, 20)
                }
            }
            section("creator.work") {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(Creator.work.enumerated()), id: \.element) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(Creator.muted)
                            Text(L10n.text(item)).font(.system(size: 17, weight: .medium)).foregroundStyle(Creator.ink)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            VStack(spacing: 12) {
                link("creator.site", symbol: "arrow.up.right", prominent: true, id: "creator.site") { openURL(Creator.site) }
                link("creator.mail", symbol: "envelope", prominent: false, id: "creator.mail") { openURL(Creator.mail) }
            }
            .padding(.top, 56)
        }
        .padding(.horizontal, framed ? 24 : 4).padding(.vertical, framed ? 32 : 8)
        .background {
            if framed { RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Creator.ground) }
        }
        // In a card the mark runs to the card's edge; on its own page, to the screen's.
        .modifier(CreatorFrame(framed: framed))
        .environment(\.colorScheme, .dark)
    }

    /// The key visual: the mark large and glowing, running off the right edge as on the site's opening screen, the name small
    /// at its side; then the motto, and what NextLine is.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // A soft light behind the mark: a blurred disc, so it has no edge anywhere.
                Circle().fill(Color(labHex: "FF240C").opacity(0.32)).frame(width: 240, height: 240).blur(radius: 70)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: 50, y: -10)
                    .allowsHitTesting(false).accessibilityHidden(true)
                NextLineMark().fill(Creator.gradient).frame(width: 236, height: 186)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: 44, y: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "NextLine").font(.system(size: 20, weight: .bold)).foregroundStyle(Creator.ink)
                    Text(verbatim: "051 / BUSAN").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.5)
                        .foregroundStyle(Creator.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "NextLine"))
                .accessibilityIdentifier("creator.profile")
            }
            .frame(height: 236, alignment: .topLeading)
            Text(L10n.text("creator.studio")).font(.system(size: 13, weight: .medium)).foregroundStyle(Creator.muted)
                .padding(.top, 8)
            Text(L10n.text("creator.motto")).font(.system(size: 34, weight: .heavy)).foregroundStyle(Creator.ink)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .padding(.top, 10)
            Text(L10n.text("creator.about")).font(.system(size: 16)).foregroundStyle(Creator.ink.opacity(0.72))
                .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
            if onboarding {
                HStack(spacing: 14) {
                    Capsule().fill(Creator.gradient).frame(width: 3)
                    Text(L10n.text("creator.course")).font(.system(size: 16, weight: .semibold)).foregroundStyle(Creator.ink)
                        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
            }
        }
    }

    private var rule: some View { Rectangle().fill(Creator.ink.opacity(0.1)).frame(height: 1) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(title)).font(.system(size: 12, weight: .semibold)).tracking(1.6).foregroundStyle(Creator.muted)
                .textCase(.uppercase).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.top, 56)
    }

    /// One record: the figure large, what it counts beneath, a quiet note; every row starts on the same edge.
    private func record(_ record: Creator.Record) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(record.value)).font(.system(size: 34, weight: .heavy)).foregroundStyle(Creator.gradient)
                .lineLimit(1).minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(record.label)).font(.system(size: 16, weight: .semibold)).foregroundStyle(Creator.ink)
                Text(L10n.text(record.detail)).font(.system(size: 14)).foregroundStyle(Creator.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }

    private func link(_ title: String, symbol: String, prominent: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(L10n.text(title)).font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(prominent ? Color.white : Creator.ink)
            .padding(.horizontal, 20).frame(height: 56)
            .background {
                if prominent { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Creator.gradient) }
                else { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Creator.ink.opacity(0.2), lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LabPressStyle())
        .accessibilityIdentifier(id)
    }
}

/// Clips the profile to its card when it has one.
private struct CreatorFrame: ViewModifier {
    let framed: Bool
    func body(content: Content) -> some View {
        if framed { content.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)) } else { content }
    }
}

/// The page on its own, as the "누가 만들었나요?" button opens it.
struct CreatorView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                CreatorProfile(framed: false).padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 48)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Creator.ground.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
            .navigationTitle(L10n.text("creator.kicker")).navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// "누가 만들었나요?": a quiet row that opens the page. `style` follows the screen it sits on.
struct CreatorButton: View {
    enum Style { case lab, study }
    var style = Style.lab
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 12) {
                NextLineMark().fill(Creator.gradient).frame(width: 26, height: 21)
                    .frame(width: 40, height: 40).background(Creator.ground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("creator.button")).font(style == .study ? StudyTheme.body(16, .bold) : .system(size: 16, weight: .semibold))
                        .foregroundStyle(style == .study ? StudyTheme.ink : .primary)
                    Text(L10n.text("creator.button.detail")).font(style == .study ? StudyTheme.body(13, .medium) : .system(size: 13))
                        .foregroundStyle(style == .study ? StudyTheme.muted : .secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(style == .study ? StudyTheme.muted : Color.secondary)
            }
            .padding(style == .study ? EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12) : EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background {
                if style == .lab {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("creator.button")
        .appSheet(isPresented: $showing) { CreatorView() }
    }
}
