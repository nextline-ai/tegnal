import SwiftUI

private struct RecapRevealKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var recapRevealed: Bool {
        get { self[RecapRevealKey.self] }
        set { self[RecapRevealKey.self] = newValue }
    }
}
private struct RecapRise: ViewModifier {
    let order: Int
    @Environment(\.recapRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(revealed ? 1 : 0).offset(y: revealed || reduceMotion ? 0 : 22)
            .animation(.spring(duration: 0.6, bounce: 0.12).delay(Double(order) * 0.09 + 0.1), value: revealed)
    }
}
private extension View { func rise(_ order: Int = 0) -> some View { modifier(RecapRise(order: order)) } }

/// Rolls up to its value when the page opens. Reduced motion lands on it at once.
private struct RecapCount: View {
    let value: Int
    let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    var body: some View {
        Text(shown.formatted()).font(font).monospacedDigit().contentTransition(.numericText(value: Double(shown))).lineLimit(1).minimumScaleFactor(0.4)
            .accessibilityLabel(value.formatted())
            .onAppear {
                if reduceMotion { shown = value } else { withAnimation(.easeOut(duration: 1.1).delay(0.2)) { shown = value } }
            }
    }
}

private struct RecapEyebrow: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(RecapType.folio(12)).textCase(.uppercase).kerning(1.4).foregroundStyle(color).accessibilityAddTraits(.isHeader)
    }
}

private struct RecapButton: View {
    let title: String
    let icon: String
    var prominent = true
    let palette: RecapPalette
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 18).frame(minHeight: 46)
                .foregroundStyle(prominent ? palette.paperInk : .white)
                .background(prominent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

struct RecapPageView: View {
    let page: RecapPage
    let recap: TasteRecap
    let palette: RecapPalette
    let number: Int
    let total: Int
    let timeZone: TimeZone
    let safeArea: EdgeInsets
    let actions: RecapActions
    @State private var revealed = false
    private var isMonth: Bool { recap.period == .month }
    private var periodWord: String { L10n.text(recap.period == .week ? "this week" : "this issue") }
    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width / 390, geometry.size.height / 760)
            content(unit: unit, size: geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .foregroundStyle(.white)
        }
        .environment(\.recapRevealed, revealed)
        .onAppear { revealed = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.page." + page.rawValue)
    }
    private var top: CGFloat { safeArea.top + 72 }
    private var bottom: CGFloat { max(safeArea.bottom, 12) + 54 }

    @ViewBuilder private func content(unit: CGFloat, size: CGSize) -> some View {
        switch page {
        case .cover: cover(unit: unit)
        case .numbers: numbers(unit: unit, size: size)
        case .chart: chart(unit: unit)
        case .person: person(unit: unit, size: size)
        case .palette: swatches(unit: unit, size: size)
        case .discovery: discovery(unit: unit, size: size)
        case .rhythm: rhythm(unit: unit)
        case .time: time(unit: unit)
        case .year: year(unit: unit)
        case .favorite: favorite(unit: unit, size: size)
        case .rediscover: rediscover(unit: unit)
        case .persona: persona(unit: unit)
        case .next: next(unit: unit)
        }
    }

    private func cover(unit: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            RecapCoverLayout(recap: recap, palette: palette, timeZone: timeZone, note: recap.hasActivity ? recap.editorNote?.text : nil,
                             insets: EdgeInsets(top: safeArea.top + 44, leading: 0, bottom: max(safeArea.bottom, 12) + 30, trailing: 0)) {
                RecapCoverArt(palette: palette, seed: recap.coverSeed)
                    .scaleEffect(revealed ? 1 : 1.08).animation(.easeOut(duration: 2.4), value: revealed)
            }
            if !recap.hasActivity {
                Text(L10n.text("No saved works in this period. Try the previous period to see earlier activity.")).font(.subheadline).padding(22).padding(.bottom, 110)
            }
        }
    }

    private func wall(_ works: ArraySlice<RecapWork>, columns: Int, side: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 6), count: columns), spacing: 6) {
            ForEach(Array(works.enumerated()), id: \.element.id) { position, work in
                RecapArtTile(work: work, palette: palette, generated: recap.isSample, seed: position)
                    .frame(width: side, height: side * 1.3).clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(revealed ? 1 : 0).scaleEffect(revealed ? 1 : 0.86)
                    .animation(.spring(duration: 0.55, bounce: 0.2).delay(Double(position) * 0.025), value: revealed)
            }
        }
    }

    private func numbers(unit: CGFloat, size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            palette.ink
            wall(recap.saved.prefix(24), columns: 5, side: (size.width + 60) / 5)
                .rotationEffect(.degrees(-7)).frame(width: size.width, height: size.height * 0.56, alignment: .top).offset(x: -30, y: -24).clipped()
                .overlay(LinearGradient(colors: [palette.ink.opacity(0.1), palette.ink], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 8 * unit) {
                RecapEyebrow(text: L10n.text("You saved %@", periodWord), color: palette.accent).rise(0)
                RecapCount(value: recap.saves, font: RecapType.display(132 * unit)).rise(1)
                HStack(spacing: 8) {
                    Text(L10n.text(recap.mode == .booru ? "recap.unit.images" : "recap.unit.works")).font(RecapType.display(26 * unit, weight: .semibold))
                    if recap.offset < 0 || recap.previousSaves > 0, recap.saves != recap.previousSaves {
                        Text(L10n.text("%@ vs last period", RecapFormat.signed(recap.saves - recap.previousSaves)))
                            .font(.system(size: 13 * unit, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.14), in: Capsule())
                    }
                }.rise(2)
                Rectangle().fill(.white.opacity(0.28)).frame(height: 1).padding(.vertical, 10 * unit).rise(3)
                HStack(alignment: .top) {
                    stat(recap.opens, "Opened"); Spacer(); stat(recap.searches, "Searches"); Spacer(); stat(recap.activeDays, "Active days")
                }.rise(4)
            }.padding(.horizontal, 24).padding(.bottom, bottom + 18)
        }
    }
    private func stat(_ value: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(RecapType.display(26, weight: .bold)).monospacedDigit()
            Text(L10n.text(title)).font(.caption).opacity(0.72)
        }.accessibilityElement(children: .combine)
    }

    private func chart(unit: CGFloat) -> some View {
        let rows = Array(recap.tags.prefix(recap.period == .week ? 4 : 5)), peak = max(1, rows.first?.count ?? 1)
        return ZStack(alignment: .topLeading) {
            palette.ink
            VStack(alignment: .leading, spacing: 18 * unit) {
                RecapEyebrow(text: L10n.text("The chart"), color: palette.accent).rise(0)
                Text(L10n.text(recap.period == .week ? "The tags that defined your week" : recap.period == .year ? "The tags that defined your year" : "The tags that defined your month"))
                    .font(RecapType.display(33 * unit, weight: .heavy)).lineLimit(3).minimumScaleFactor(0.7).rise(1)
                VStack(spacing: 8 * unit) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, tag in
                        Button { actions.openTag(tag) } label: { chartRow(tag, peak: peak, unit: unit, work: thumbnails(rows)[tag.name]) }.buttonStyle(.plain).rise(position + 2)
                            .accessibilityIdentifier("recap.tag.\(position)")
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
            }.padding(.horizontal, 22).padding(.top, top).padding(.bottom, bottom)
        }
    }
    /// Popular tags share works, so each row claims one the rows above have not used.
    private func thumbnails(_ rows: [RecapTag]) -> [String: RecapWork] {
        var used = Set<String>(), result: [String: RecapWork] = [:]
        for tag in rows {
            let works = recap.saved.filter { tag.works.contains($0.id) }
            guard let work = works.first(where: { !used.contains($0.id) }) ?? works.first else { continue }
            used.insert(work.id); result[tag.name] = work
        }
        return result
    }
    private func chartRow(_ tag: RecapTag, peak: Int, unit: CGFloat, work: RecapWork?) -> some View {
        HStack(spacing: 12) {
            RecapArtTile(work: work, palette: palette, generated: recap.isSample, seed: tag.rank)
                .frame(width: 62 * unit, height: 82 * unit).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(String(tag.rank)).font(RecapType.display(40 * unit)).frame(width: 34 * unit, alignment: .leading).foregroundStyle(tag.rank == 1 ? palette.accent : .white).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(RecapText.tag(tag.name)).font(.system(size: 18 * unit, weight: .bold)).lineLimit(1).minimumScaleFactor(0.65)
                    Spacer(minLength: 4)
                    movement(tag)
                    Text(String(tag.count)).font(RecapType.folio(13)).opacity(0.8)
                }
                GeometryReader { bar in
                    Capsule().fill(.white.opacity(0.13)).overlay(alignment: .leading) {
                        Capsule().fill(tag.rank == 1 ? palette.accent : .white.opacity(0.7)).frame(width: revealed ? bar.size.width * Double(tag.count) / Double(peak) : 0)
                            .animation(.spring(duration: 0.8).delay(0.35 + Double(tag.rank) * 0.07), value: revealed)
                    }
                }.frame(height: 4)
            }
        }.frame(minHeight: 82 * unit, maxHeight: 112 * unit).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
    @ViewBuilder private func movement(_ tag: RecapTag) -> some View {
        if tag.isNew { Text(L10n.text("NEW")).font(RecapType.folio(10)).padding(.horizontal, 6).padding(.vertical, 2).background(palette.accent, in: Capsule()).foregroundStyle(palette.paperInk) }
        else if let change = tag.movement, change != 0 {
            Label(String(abs(change)), systemImage: change > 0 ? "arrow.up" : "arrow.down").labelStyle(.titleAndIcon).font(RecapType.folio(11)).foregroundStyle(change > 0 ? palette.accent : .white.opacity(0.55))
                .accessibilityLabel(L10n.text(change > 0 ? "Up %@" : "Down %@", String(abs(change))))
        }
    }

    private func artworks(_ keys: [String]) -> [RecapWork] { keys.compactMap(recap.work(_:)) }

    private func person(unit: CGFloat, size: CGSize) -> some View {
        let lead = recap.person(.artist) ?? recap.people[0]
        let works = artworks(lead.works)
        return ZStack(alignment: .bottomLeading) {
            RecapArtTile(work: works.first, palette: palette, large: true, generated: recap.isSample, seed: 11)
                .scaleEffect(revealed ? 1.06 : 1).animation(.easeOut(duration: 8), value: revealed)
            LinearGradient(stops: [.init(color: palette.ink.opacity(0.5), location: 0), .init(color: .clear, location: 0.3), .init(color: palette.ink, location: 0.82)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10 * unit) {
                HStack(spacing: 6) {
                    ForEach(Array(works.dropFirst().prefix(3))) { work in
                        RecapArtTile(work: work, palette: palette, generated: recap.isSample).frame(width: 64 * unit, height: 86 * unit).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.45), lineWidth: 1))
                    }
                }.rise(0)
                RecapEyebrow(text: L10n.text(lead.role == .artist ? "Artist of the issue" : lead.role == .series ? "Series of the issue" : "Character of the issue"), color: palette.accent).rise(1)
                Text(RecapText.tag(lead.name).capitalized).font(RecapType.display(46 * unit)).lineLimit(2).minimumScaleFactor(0.5).rise(2)
                Text(L10n.text("%@ works saved %@", lead.count.formatted(), periodWord)).font(.system(size: 17 * unit, weight: .medium)).opacity(0.86).rise(3)
                RecapButton(title: L10n.text("See more"), icon: "magnifyingglass", palette: palette) { actions.search(query(lead), source(lead)) }.padding(.top, 6).rise(4).disabled(recap.isSample)
                    .accessibilityIdentifier("recap.person.search")
            }.padding(.horizontal, 24).padding(.bottom, bottom + 6)
        }
    }
    private func query(_ person: RecapPerson) -> String {
        let name = person.name.replacingOccurrences(of: " ", with: "_")
        guard recap.mode == .comics else { return name }
        return person.role.rawValue + ":" + name
    }
    private func source(_ person: RecapPerson) -> String { person.works.first.flatMap(recap.work(_:))?.item.source ?? "" }

    private func swatches(unit: CGFloat, size: CGSize) -> some View {
        let weights: [CGFloat] = [0.34, 0.24, 0.18, 0.14, 0.1]
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                ForEach(Array(palette.swatches.prefix(5).enumerated()), id: \.offset) { position, swatch in
                    swatch.color.frame(width: size.width * weights[position])
                        .frame(height: revealed ? size.height : 0, alignment: .top).frame(maxHeight: .infinity, alignment: .top)
                        .animation(.spring(duration: 0.8, bounce: 0.1).delay(Double(position) * 0.08), value: revealed)
                        .overlay(alignment: .bottom) {
                            Text(swatch.hex).font(RecapType.folio(9.5)).rotationEffect(.degrees(-90)).fixedSize().frame(width: 16, height: 76)
                                .foregroundStyle(swatch.luminance > 0.55 ? .black.opacity(0.7) : .white.opacity(0.8)).padding(.bottom, 62).rise(5)
                        }
                }
            }.accessibilityHidden(true)
            LinearGradient(stops: [.init(color: palette.ink.opacity(0.94), location: 0), .init(color: palette.ink.opacity(0.74), location: 0.34), .init(color: .clear, location: 0.52)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10 * unit) {
                RecapEyebrow(text: L10n.text("The colors of your covers"), color: .white).rise(1)
                Text(L10n.text("This issue was %@", palette.moodName)).font(RecapType.display(52 * unit)).lineLimit(3).minimumScaleFactor(0.6).rise(2)
                Text(L10n.text("Measured from the covers you kept. Every issue gets its own.")).font(.system(size: 15 * unit, weight: .medium)).opacity(0.86).rise(3)
            }.padding(.horizontal, 24).padding(.top, top).frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func discovery(unit: CGFloat, size: CGSize) -> some View {
        let highlight = recap.highlights[0], tag = highlight.tag
        let works = Array(artworks(tag.works).prefix(3))
        let heading: String, detail: String
        switch highlight.kind {
        case .hidden: heading = L10n.text("A new side of your taste"); detail = L10n.text("You saved %@ works with this tag without searching for it, across %@ sessions.", String(tag.hidden), String(tag.sessions.count))
        case .comeback: heading = L10n.text("Back in rotation"); detail = L10n.text("You had drifted away from this tag. %@ works brought it back.", String(tag.count))
        case .newcomer: heading = L10n.text("New to your collection"); detail = L10n.text("You had never saved this tag before. Now it has %@ works.", String(tag.count))
        case .rising: heading = L10n.text("On the rise"); detail = L10n.text("Saved works with this tag increased from %@ to %@.", String(tag.previousCount), String(tag.count))
        }
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [palette.deep, palette.ink], startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: .leading, spacing: 12 * unit) {
                RecapEyebrow(text: heading, color: palette.accent).rise(0)
                Text(RecapText.tag(tag.name)).font(RecapType.display(54 * unit)).lineLimit(3).minimumScaleFactor(0.45).rise(1)
                Text(detail).font(.system(size: 17 * unit, weight: .medium)).opacity(0.86).fixedSize(horizontal: false, vertical: true).rise(2)
                Spacer(minLength: 8)
                ZStack {
                    ForEach(Array(works.enumerated()), id: \.element.id) { position, work in
                        let shift = CGFloat(position) - CGFloat(works.count - 1) / 2
                        Button { actions.openWork(work) } label: {
                            RecapArtTile(work: work, palette: palette, generated: recap.isSample, seed: position).frame(width: 148 * unit, height: 200 * unit).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1)).shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                        }.buttonStyle(.plain).accessibilityLabel(work.info.title ?? L10n.text("Open"))
                            .rotationEffect(.degrees(revealed ? Double(shift) * 7 : 0)).offset(x: revealed ? shift * 92 * unit : 0, y: abs(shift) * 12)
                            .animation(.spring(duration: 0.7, bounce: 0.25).delay(0.35), value: revealed)
                    }
                }.frame(maxWidth: .infinity).frame(height: 222 * unit)
                Spacer(minLength: 8)
                RecapButton(title: L10n.text("Explore this tag"), icon: "magnifyingglass", palette: palette) { actions.search(tag.name, tag.source) }.rise(4).disabled(recap.isSample)
            }.padding(.horizontal, 24).padding(.top, top).padding(.bottom, bottom)
        }
    }

    private func rhythm(unit: CGFloat) -> some View {
        let streak = recap.longestStreak
        return ZStack(alignment: .topLeading) {
            palette.ink
            VStack(alignment: .leading, spacing: 14 * unit) {
                RecapEyebrow(text: L10n.text("Your rhythm"), color: palette.accent).rise(0)
                Text(streak >= 2 ? L10n.text("%@ days in a row", String(streak)) : L10n.text("%@ active days", String(recap.activeDays)))
                    .font(RecapType.display(42 * unit)).lineLimit(2).minimumScaleFactor(0.6).rise(1)
                if let day = recap.busiestDay {
                    Text(L10n.text("Your busiest day was %@, with %@ works.", RecapFormat.day(day.date, timeZone: timeZone), String(day.touched))).font(.system(size: 16 * unit, weight: .medium)).opacity(0.86).rise(2)
                }
                Spacer(minLength: 6)
                RecapHeatmap(recap: recap, palette: palette, timeZone: timeZone).rise(3)
                Spacer(minLength: 6)
                HStack(spacing: 18 * unit) {
                    RecapClock(hours: recap.hours, accent: palette.accent).frame(width: 136 * unit, height: 136 * unit)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Peak hour")).font(.caption).opacity(0.72)
                        Text(RecapPersonaClock.hour(recap.peakHour ?? 12)).font(RecapType.display(32 * unit))
                        Text(L10n.text("The hour you were most often here.")).font(.caption).opacity(0.72).fixedSize(horizontal: false, vertical: true)
                    }
                }.rise(4).accessibilityElement(children: .combine)
                Spacer(minLength: 6)
            }.padding(.horizontal, 24).padding(.top, top).padding(.bottom, bottom)
        }
    }

    private func time(unit: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            palette.ink
            RecapArtTile(work: recap.revisited ?? recap.saved.dropFirst().first, palette: palette, large: true, generated: recap.isSample, seed: 9)
                .opacity(0.72).scaleEffect(revealed ? 1.08 : 1).animation(.easeOut(duration: 8), value: revealed)
            LinearGradient(stops: [.init(color: palette.ink.opacity(0.55), location: 0), .init(color: palette.ink.opacity(0.15), location: 0.3), .init(color: palette.ink, location: 0.72)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 12 * unit) {
                RecapEyebrow(text: L10n.text("Time with your art"), color: palette.accent).rise(0)
                Text(RecapText.duration(recap.seconds)).font(RecapType.display(68 * unit)).lineLimit(2).minimumScaleFactor(0.5).rise(1)
                Text(L10n.text("Time counts only while a work is on screen and you keep moving.")).font(.system(size: 15 * unit, weight: .medium)).opacity(0.8).rise(2)
                Rectangle().fill(.white.opacity(0.28)).frame(height: 1).padding(.vertical, 8).rise(3)
                HStack(alignment: .top, spacing: 34) {
                    stat(recap.pages, recap.mode == .booru ? "Images viewed" : "Pages read")
                    if recap.mode == .comics { stat(recap.finished, "Finished") }
                }.rise(4)
            }.padding(.horizontal, 24).padding(.bottom, bottom + 12)
        }
    }

    private func year(unit: CGFloat) -> some View {
        let peak = max(1, recap.months.map(\.saves).max() ?? 1)
        let best = recap.months.max { $0.saves < $1.saves }
        return ZStack(alignment: .topLeading) {
            palette.ink
            VStack(alignment: .leading, spacing: 14 * unit) {
                RecapEyebrow(text: L10n.text("The shape of your year"), color: palette.accent).rise(0)
                if let best { Text(L10n.text("%@ was your biggest month", RecapFormat.month(best.start, timeZone: timeZone))).font(RecapType.display(40 * unit)).lineLimit(3).minimumScaleFactor(0.6).rise(1) }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(recap.months) { month in
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            Text(String(month.saves)).font(RecapType.folio(9)).opacity(month.saves > 0 ? 0.8 : 0).lineLimit(1).minimumScaleFactor(0.6)
                            RoundedRectangle(cornerRadius: 4).fill(month.start == best?.start ? palette.accent : .white.opacity(0.32))
                                .frame(height: revealed ? max(3, 210 * unit * Double(month.saves) / Double(peak)) : 3)
                                .animation(.spring(duration: 0.7).delay(Double(month.saves) / Double(peak) * 0.2 + 0.2), value: revealed)
                            Text(String(RecapFormat.month(month.start, timeZone: timeZone).prefix(3))).font(RecapType.folio(8)).lineLimit(1).minimumScaleFactor(0.5).opacity(0.7)
                        }.accessibilityElement(children: .combine)
                    }
                }.frame(height: 270 * unit).rise(2)
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.top, top).padding(.bottom, bottom)
        }
    }

    private func favorite(unit: CGFloat, size: CGSize) -> some View {
        let work = recap.revisited!
        return ZStack(alignment: .bottomLeading) {
            RecapArtTile(work: work, palette: palette, large: true, generated: recap.isSample, seed: 5)
            LinearGradient(stops: [.init(color: palette.ink.opacity(0.55), location: 0), .init(color: .clear, location: 0.3), .init(color: palette.ink, location: 0.86)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10 * unit) {
                RecapEyebrow(text: L10n.text("The one you kept coming back to"), color: palette.accent).rise(0)
                if let title = work.info.title ?? work.info.artists.first.map({ RecapText.tag($0).capitalized }) { Text(title).font(RecapType.display(36 * unit)).lineLimit(3).minimumScaleFactor(0.6).rise(1) }
                Text(work.seconds >= 60 ? L10n.text("Opened %@ times · %@", String(work.opens), RecapText.duration(work.seconds)) : L10n.text("Opened %@ times", String(work.opens)))
                    .font(.system(size: 17 * unit, weight: .medium)).opacity(0.86).rise(2)
                RecapButton(title: L10n.text("Open again"), icon: "arrow.up.right", palette: palette) { actions.openWork(work) }.padding(.top, 6).rise(3).disabled(recap.isSample)
                    .accessibilityIdentifier("recap.favorite.open")
            }.padding(.horizontal, 24).padding(.bottom, bottom + 6)
        }
    }

    private func rediscover(unit: CGFloat) -> some View {
        let works = Array(recap.rediscover.prefix(4))
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [palette.ink, palette.deep], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14 * unit) {
                RecapEyebrow(text: L10n.text("From your own shelves"), color: palette.accent).rise(0)
                Text(L10n.text("Saved long ago, waiting for now")).font(RecapType.display(38 * unit)).lineLimit(3).minimumScaleFactor(0.6).rise(1)
                Text(L10n.text("These match this issue's taste, and you haven't opened them in a while.")).font(.system(size: 15 * unit, weight: .medium)).opacity(0.84).fixedSize(horizontal: false, vertical: true).rise(2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Array(works.enumerated()), id: \.element.id) { position, work in
                        Button { actions.openWork(work) } label: {
                            RecapArtTile(work: work, palette: palette, generated: recap.isSample, seed: position).frame(height: 196 * unit).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .bottomLeading) {
                                    if let title = work.info.title {
                                        Text(title).font(.caption.weight(.semibold)).lineLimit(2).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                                    }
                                }.clipShape(RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(work.info.title ?? L10n.text("Open")).rise(position + 3)
                            .accessibilityIdentifier("recap.rediscover.\(position)")
                    }
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 22).padding(.top, top).padding(.bottom, bottom)
        }
    }

    private func persona(unit: CGFloat) -> some View {
        let persona = recap.persona!
        return ZStack(alignment: .topLeading) {
            palette.paper
            VStack(alignment: .leading, spacing: 14 * unit) {
                Text(L10n.text("This issue, you were")).font(RecapType.folio(12)).textCase(.uppercase).kerning(1.4).opacity(0.65).rise(0)
                Text(persona.title).font(RecapType.display(58 * unit)).lineLimit(3).minimumScaleFactor(0.5).rise(1)
                Text(persona.summary).font(RecapType.display(19 * unit, weight: .medium)).italic().fixedSize(horizontal: false, vertical: true).rise(2)
                Rectangle().fill(palette.paperInk.opacity(0.35)).frame(height: 1).padding(.vertical, 6).rise(3)
                ForEach(Array(persona.traits.enumerated()), id: \.offset) { position, trait in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%02d", position + 1)).font(RecapType.folio(12)).opacity(0.55)
                        Text(trait.text).font(.system(size: 16 * unit, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }.rise(position + 4)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ForEach(Array(recap.saved.prefix(4).enumerated()), id: \.element.id) { position, work in
                        RecapArtTile(work: work, palette: palette, generated: recap.isSample, seed: position).aspectRatio(0.74, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.rise(6)
                HStack(spacing: 0) { ForEach(palette.swatches, id: \.self) { $0.color.frame(height: 10) } }.clipShape(Capsule()).rise(6).accessibilityHidden(true)
                Spacer(minLength: 8)
                Text(L10n.text("Patterns describe your activity in this app. They are suggestions, not conclusions about you.")).font(.caption).opacity(0.62).rise(7)
            }.padding(.horizontal, 24).padding(.top, top).padding(.bottom, bottom + 4).foregroundStyle(palette.paperInk)
            LinearGradient(colors: [palette.ink.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).frame(height: safeArea.top + 60).allowsHitTesting(false)
        }
    }

    private func next(unit: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [palette.deep, palette.ink], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 14 * unit) {
                RecapEyebrow(text: L10n.text("Next issue"), color: palette.accent).rise(0)
                Text(L10n.text("Where to go from here")).font(RecapType.display(40 * unit)).lineLimit(2).minimumScaleFactor(0.6).rise(1)
                ForEach(Array(recap.next.enumerated()), id: \.element.id) { position, tag in
                    Button { actions.search(tag.name, tag.source) } label: {
                        HStack {
                            Text(RecapText.tag(tag.name)).font(RecapType.display(23 * unit, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold))
                        }.padding(.vertical, 12).padding(.horizontal, 2).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.26)).frame(height: 1) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).rise(position + 2).disabled(recap.isSample).accessibilityIdentifier("recap.next.\(position)")
                }
                Spacer(minLength: 8)
                RecapCoverLayout(recap: recap, palette: palette, timeZone: timeZone) {
                    RecapCoverArt(palette: palette, seed: recap.coverSeed)
                }.frame(width: 136 * unit, height: 184 * unit).clipShape(RoundedRectangle(cornerRadius: 7)).frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 8).accessibilityHidden(true).rise(5)
                Spacer(minLength: 8)
                if !recap.saved.isEmpty {
                    Button(action: actions.showSaved) { Label(L10n.text("All %@ saved works", recap.saves.formatted()), systemImage: "square.grid.2x2").font(.system(size: 15, weight: .semibold)).frame(minHeight: 44) }
                        .buttonStyle(.plain).rise(6).accessibilityIdentifier("recap.saved")
                }
                HStack(spacing: 10) {
                    RecapButton(title: L10n.text("Share cover"), icon: "square.and.arrow.up", palette: palette, action: actions.share).accessibilityIdentifier("recap.next.share")
                    RecapButton(title: L10n.text("Replay"), icon: "arrow.counterclockwise", prominent: false, palette: palette, action: actions.replay)
                }.rise(7)
                RecapButton(title: L10n.text("Done"), icon: "checkmark", prominent: false, palette: palette, action: actions.close).rise(8)
            }.padding(.horizontal, 24).padding(.top, top).padding(.bottom, max(safeArea.bottom, 12) + 10)
        }
    }
}

/// Calendar-shaped for a week or month; a year reads as twelve rows of days.
private struct RecapHeatmap: View {
    let recap: TasteRecap
    let palette: RecapPalette
    let timeZone: TimeZone
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; value.firstWeekday = 2; return value }
    var body: some View {
        let peak = max(1, recap.days.map(\.touched).max() ?? 1)
        let columns = recap.period == .year ? 31 : 7
        let cells = recap.period == .year ? yearCells : monthCells
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: recap.period == .year ? 2 : 4), count: columns), spacing: recap.period == .year ? 2 : 4) {
            ForEach(cells.indices, id: \.self) { index in
                if let day = cells[index] {
                    RoundedRectangle(cornerRadius: recap.period == .year ? 1.5 : 4)
                        .fill(day.touched == 0 ? AnyShapeStyle(.white.opacity(0.09)) : AnyShapeStyle(palette.accent.opacity(0.32 + 0.68 * Double(day.touched) / Double(peak))))
                        .aspectRatio(recap.period == .year ? 1 : 1.2, contentMode: .fit)
                } else { Color.clear.aspectRatio(recap.period == .year ? 1 : 1.2, contentMode: .fit) }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("%@ active days", String(recap.activeDays)))
    }
    private var monthCells: [RecapDay?] {
        guard let first = recap.days.first else { return [] }
        let lead = (calendar.component(.weekday, from: first.date) + 5) % 7
        return Array(repeating: nil, count: lead) + recap.days
    }
    private var yearCells: [RecapDay?] {
        let byDay = Dictionary(uniqueKeysWithValues: recap.days.map { ($0.date, $0) })
        var result: [RecapDay?] = []
        for month in 0..<12 {
            for day in 0..<31 {
                guard let start = calendar.date(byAdding: .month, value: month, to: recap.interval.start),
                      let date = calendar.date(byAdding: .day, value: day, to: start), calendar.isDate(date, equalTo: start, toGranularity: .month) else { result.append(nil); continue }
                result.append(byDay[calendar.startOfDay(for: date)] ?? .init(date: date))
            }
        }
        return result
    }
}

private struct RecapClock: View {
    let hours: [Int]
    let accent: Color
    var body: some View {
        Canvas { context, size in
            let peak = Double(max(1, hours.max() ?? 1)), center = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2
            for hour in 0..<24 {
                let angle = Double(hour) / 24 * .pi * 2 - .pi / 2, value = Double(hours[hour]) / peak
                let inner = radius * 0.42, outer = inner + (radius - inner) * max(0.06, value)
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                context.stroke(path, with: .color(value > 0 ? accent.opacity(0.45 + value * 0.55) : .white.opacity(0.14)), style: StrokeStyle(lineWidth: max(3, radius * 0.075), lineCap: .round))
            }
        }.accessibilityHidden(true)
    }
}
