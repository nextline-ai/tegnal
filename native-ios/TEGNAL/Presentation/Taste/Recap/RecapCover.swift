import SwiftUI

enum RecapType {
    static func display(_ size: CGFloat, weight: Font.Weight = .black) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func folio(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
}

enum RecapFormat {
    private static func formatter(_ template: String, timeZone: TimeZone) -> DateFormatter {
        let value = DateFormatter(); value.locale = Locale(identifier: L10n.language); value.timeZone = timeZone
        value.setLocalizedDateFormatFromTemplate(template)
        return value
    }
    @MainActor static func zone(_ env: AppEnvironment) -> TimeZone { TimeZone(identifier: env.taste.control.timeZone) ?? .gmt }
    static func title(_ recap: TasteRecap, timeZone: TimeZone) -> String {
        switch recap.period {
        case .month: return formatter("yMMMM", timeZone: timeZone).string(from: recap.interval.start)
        case .year: return formatter("y", timeZone: timeZone).string(from: recap.interval.start)
        default:
            let days = formatter("MMMd", timeZone: timeZone)
            return days.string(from: recap.interval.start) + " – " + days.string(from: recap.interval.end.addingTimeInterval(-1))
        }
    }
    static func day(_ date: Date, timeZone: TimeZone) -> String { formatter("MMMd", timeZone: timeZone).string(from: date) }
    static func month(_ date: Date, timeZone: TimeZone) -> String { formatter("MMM", timeZone: timeZone).string(from: date) }
    static func signed(_ value: Int) -> String { (value > 0 ? "+" : "") + value.formatted() }
    static func modeName(_ mode: TasteMode) -> String { L10n.text(mode == .booru ? "Images" : "Comics") }
}

/// A printed cover: masthead over artwork, with the issue's facts set like coverlines.
struct RecapCoverLayout<Background: View>: View {
    let recap: TasteRecap
    let palette: RecapPalette
    let timeZone: TimeZone
    var showsTags = true
    var note: String? = nil
    var insets = EdgeInsets()
    @ViewBuilder var background: Background
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                background.frame(width: width, height: geometry.size.height).clipped()
                LinearGradient(stops: [.init(color: palette.ink.opacity(0.78), location: 0), .init(color: palette.ink.opacity(0), location: 0.34),
                                       .init(color: palette.ink.opacity(0), location: 0.46), .init(color: palette.ink.opacity(0.94), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "RECAP").font(RecapType.display(width * 0.262)).kerning(-width * 0.006).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(.white.opacity(0.75)).frame(height: max(1, width * 0.003)).padding(.top, width * 0.006)
                    HStack {
                        Text(recap.isSample ? L10n.text("Sample issue") : L10n.text("No. %@", String(recap.issue)))
                        Spacer(minLength: 8)
                        Text(RecapFormat.title(recap, timeZone: timeZone)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 8)
                        Text(RecapFormat.modeName(recap.mode))
                    }.font(RecapType.folio(width * 0.03)).textCase(.uppercase).padding(.top, width * 0.02)
                    Spacer(minLength: 0)
                    if let note {
                        Text(note).font(RecapType.display(width * 0.042, weight: .medium)).italic().fixedSize(horizontal: false, vertical: true).padding(.bottom, width * 0.03)
                    }
                    if let persona = recap.persona {
                        Text(persona.title).font(RecapType.display(width * 0.098, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsTags, !recap.tags.isEmpty {
                        Text(recap.tags.prefix(3).map { RecapText.tag($0.name) }.joined(separator: "  ·  "))
                            .font(.system(size: width * 0.04, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).opacity(0.9).padding(.top, width * 0.016)
                    }
                    Rectangle().fill(.white.opacity(0.4)).frame(height: max(1, width * 0.002)).padding(.top, width * 0.03)
                    HStack(alignment: .firstTextBaseline, spacing: width * 0.05) {
                        fact(recap.saves.formatted(), L10n.text("Saved"), width: width)
                        fact(recap.opens.formatted(), L10n.text("Opened"), width: width)
                        fact(recap.activeDays.formatted(), L10n.text("Active days"), width: width)
                    }.padding(.top, width * 0.026)
                }.padding(width * 0.058).padding(insets).foregroundStyle(.white)
            }.environment(\.colorScheme, .dark)
        }
    }
    private func fact(_ value: String, _ label: String, width: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: width * 0.012) {
            Text(value).font(RecapType.display(width * 0.05, weight: .bold))
            Text(label).font(.system(size: width * 0.031, weight: .medium)).opacity(0.78)
        }.lineLimit(1).minimumScaleFactor(0.7)
    }
}

struct RecapCover: View {
    let recap: TasteRecap
    let palette: RecapPalette
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        RecapCoverLayout(recap: recap, palette: palette, timeZone: RecapFormat.zone(env)) {
            RecapCoverArt(palette: palette, seed: recap.coverSeed)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Recap issue %@, %@", String(recap.issue), RecapFormat.title(recap, timeZone: RecapFormat.zone(env))))
    }
}
