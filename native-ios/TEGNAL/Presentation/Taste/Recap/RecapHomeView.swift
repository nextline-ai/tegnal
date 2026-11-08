import SwiftUI

private struct RecapPresentation: Identifiable { let recap: TasteRecap; let palette: RecapPalette; var id: String { recap.id } }

/// The magazine rack: the latest issue up front, the current week beside it,
/// every back issue kept, and the shape of a person's taste across them.
struct RecapHomeView: View {
    @State private var mode: TasteMode
    /// Opens this month's issue as soon as it has loaded, for the arrival banner.
    var opening: Date? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var shelf = RecapShelf()
    @State private var artwork: RecapArtwork?
    @State private var reading: RecapPresentation?
    @State private var openedArrival = false
    @State private var notReady = false
    private var requestKey: String { "\(mode.rawValue):\(env.taste.control.analysisKey(mode)):\(env.booru.revision)" }
    init(mode: TasteMode, opening: Date? = nil) { _mode = State(initialValue: mode); self.opening = opening }
    var body: some View {
        Group {
            if !env.taste.control.enabled {
                ContentUnavailableView {
                    Label(L10n.text("Taste analysis is paused on your devices."), systemImage: "pause.circle")
                } actions: { Button(L10n.text("Enable Taste Analysis")) { env.taste.change { $0.enabled = true } } }
            } else if shelf.failed {
                ContentUnavailableView {
                    Label(L10n.text("Unable to update taste analysis."), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                } actions: { Button(L10n.text("Try Again")) { Task { await shelf.load(mode: mode, env: env, key: requestKey) } } }
            } else if !shelf.loaded || artwork == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let artwork { content.environment(artwork) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.text("Recap")).navigationBarTitleDisplayMode(.inline)
        .tint(TastePresentation.accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("taste.monthly")
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !env.booruSafeMode {
                    AppModeSwitch(previewMode: Binding(get: { mode == .booru ? .booru : .manga }, set: { mode = $0 == .booru ? .booru : .comics }))
                }
            }
        }
        .environment(\.recapPrivate, env.booruSafeMode)
        .task { if artwork == nil { artwork = RecapArtwork(env: env) } }
        .task(id: requestKey) {
            await shelf.load(mode: mode, env: env, key: requestKey)
            guard !Task.isCancelled else { return }
            if !openedArrival, let opening, let recap = shelf.recap(for: opening) { openedArrival = true; open(recap) }
            if let artwork { for recap in ([shelf.latest, shelf.year, shelf.week, shelf.sample].compactMap { $0 } + shelf.pastIssues.prefix(8)) { await shelf.measure(recap, artwork: artwork, env: env) } }
        }
        .appFullScreenCover(item: $reading) { item in
            RecapStoryView(recap: item.recap, palette: shelf.palette(item.recap)).environment(artwork ?? RecapArtwork(env: env)).environment(\.recapPrivate, env.booruSafeMode)
        }
    }
    private func open(_ recap: TasteRecap) { reading = .init(recap: shelf.opened(recap), palette: shelf.palette(recap)) }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                masthead
                if let latest = shelf.latest { hero(latest) }
                else if let sample = shelf.sample { first(sample) }
                if let week = shelf.week, week.hasActivity { weekly(week) }
                if let year = shelf.year { yearly(year) }
                if !shelf.pastIssues.isEmpty { backIssues }
                if shelf.issues.count >= 2 { trend }
                privacy
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
    }
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "RECAP").font(RecapType.display(44)).kerning(-0.5)
            Text(L10n.text("A magazine made from what you loved.")).font(.subheadline).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func hero(_ recap: TasteRecap) -> some View {
        let palette = shelf.palette(recap)
        return VStack(alignment: .leading, spacing: 14) {
            Button { open(recap) } label: {
                RecapCover(recap: recap, palette: palette).aspectRatio(0.74, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: palette.ink.opacity(0.4), radius: 18, y: 10).contentShape(Rectangle())
            }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.latest")
            Button { open(recap) } label: {
                Label(L10n.text(recap.isComplete ? "Read this issue" : "Read so far"), systemImage: "book.pages").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).tint(palette.deep)
        }
    }
    /// Before the first issue: a veiled cover that says plainly the recap is not ready, and a tap
    /// that explains when it will be rather than opening a sample.
    private func first(_ sample: TasteRecap) -> some View {
        let palette = shelf.palette(sample)
        return VStack(alignment: .leading, spacing: 14) {
            Button { notReady = true } label: {
                RecapCover(recap: sample, palette: palette).aspectRatio(0.74, contentMode: .fit)
                    .overlay {
                        ZStack {
                            Rectangle().fill(.black.opacity(0.45))
                            VStack(spacing: 10) {
                                Image(systemName: "hourglass").font(.system(size: 34, weight: .semibold))
                                Text(L10n.text("Recap is not ready yet")).font(.title3.bold())
                            }.foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
            }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.sample")
            Text(L10n.text("Your first issue is on its way")).font(.title3.bold())
            Text(L10n.text("Recap arrives after 30 days of using TEGNAL. Save and open works in the meantime: your cover, colors and persona will come from them.")).font(.subheadline).foregroundStyle(.secondary)
        }
        .alert(L10n.text("Recap is not ready yet"), isPresented: $notReady) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: {
            Text(L10n.text("Your first recap arrives after 30 days of using TEGNAL."))
        }
    }
    private func weekly(_ recap: TasteRecap) -> some View {
        let peak = max(1, recap.days.map(\.touched).max() ?? 1), palette = shelf.palette(recap)
        return Button { open(recap) } label: {
            TasteSurface {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L10n.text("This week")).font(.headline)
                        Spacer()
                        Text(RecapFormat.title(recap, timeZone: RecapFormat.zone(env))).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(recap.days) { day in
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 5).fill(day.touched > 0 ? AnyShapeStyle(TastePresentation.accent.opacity(0.35 + 0.65 * Double(day.touched) / Double(peak))) : AnyShapeStyle(Color.secondary.opacity(0.14))).frame(height: 8 + 44 * Double(day.touched) / Double(peak))
                            }.frame(maxWidth: .infinity)
                        }
                    }.frame(height: 54, alignment: .bottom).accessibilityHidden(true)
                    HStack(spacing: 22) {
                        weekFact(recap.saves, "Saved"); weekFact(recap.opens, "Opened")
                        if recap.seconds >= 60 { weekFact(RecapText.duration(recap.seconds), "Viewing time") }
                        Spacer(minLength: 0)
                    }
                    if let top = recap.signature ?? recap.tags.first { Label(RecapText.tag(top.name), systemImage: "number").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
                }.foregroundStyle(.primary)
            }
        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.week").id(palette)
    }
    private func weekFact(_ value: Int, _ title: String) -> some View { weekFact(value.formatted(), title) }
    private func weekFact(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    private func yearly(_ recap: TasteRecap) -> some View {
        let palette = shelf.palette(recap)
        return Button { open(recap) } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Year in review")).font(RecapType.folio(11)).textCase(.uppercase).kerning(1.2).opacity(0.8)
                    Text(RecapFormat.title(recap, timeZone: RecapFormat.zone(env))).font(RecapType.display(38))
                    Text(L10n.text("%@ works · %@ active days", recap.saves.formatted(), recap.activeDays.formatted())).font(.subheadline).opacity(0.85)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.title3.weight(.semibold))
            }.padding(20).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
                .background { ZStack { RecapColorField(palette: palette, seed: 21); palette.ink.opacity(0.32) } }.clipShape(RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.year")
    }
    private var backIssues: some View {
        VStack(alignment: .leading, spacing: 12) {
            TasteSectionHeading(title: "Back issues")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(shelf.pastIssues) { recap in
                        Button { open(recap) } label: {
                            RecapCover(recap: recap, palette: shelf.palette(recap)).frame(width: 164, height: 222).clipShape(RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
                        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.issue.\(recap.issue)")
                    }
                }.padding(.horizontal, 20)
            }.padding(.horizontal, -20)
        }
    }
    private var trend: some View {
        let months = Array(shelf.issues.prefix(12).reversed()), peak = max(1, months.map(\.saves).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            TasteSectionHeading(title: "Your taste over time", subtitle: L10n.text("Each bar is an issue, labeled with the tag that set it apart."))
            TasteSurface {
                VStack(spacing: 9) {
                    ForEach(months.reversed()) { recap in
                        Button { open(recap) } label: {
                            HStack(spacing: 10) {
                                Text(RecapFormat.month(recap.interval.start, timeZone: RecapFormat.zone(env))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                                GeometryReader { bar in
                                    let width = max(6, bar.size.width * Double(recap.saves) / Double(peak))
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(shelf.palette(recap).swatches[0].color.opacity(0.85)).frame(width: width)
                                    }
                                }.frame(height: 10)
                                Text((recap.signature ?? recap.tags.first).map { RecapText.tag($0.name) } ?? "—").font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(1).frame(width: 104, alignment: .trailing)
                            }.frame(minHeight: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("Made on this device from your own activity. Nothing is uploaded to build it."), systemImage: "lock").font(.footnote).foregroundStyle(.secondary)
            NavigationLink { TasteReportsView(mode: mode, period: .week) } label: { Label(L10n.text("Weekly statistics"), systemImage: "chart.bar.xaxis").font(.footnote.weight(.medium)) }
        }
    }
}

struct RecapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.975 : 1).animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

/// The Smart tab's way in: the latest cover on a single quiet row.
struct RecapEntryCard: View {
    let mode: TasteMode
    @Environment(AppEnvironment.self) private var env
    @State private var shelf = RecapShelf()
    var body: some View {
        NavigationLink { RecapHomeView(mode: mode) } label: {
            HStack(spacing: 12) {
                Group {
                    if let recap = shelf.latest ?? shelf.sample { RecapCoverArt(palette: shelf.palette(recap), seed: recap.coverSeed) }
                    else { TastePresentation.accent.opacity(0.14) }
                }.frame(width: 36, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "RECAP").font(RecapType.display(16)).foregroundStyle(.primary)
                    if let latest = shelf.latest { Text(RecapFormat.title(latest, timeZone: RecapFormat.zone(env))).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    else if shelf.sample != nil { Text(L10n.text("Recap is not ready yet")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(RecapPressStyle()).accessibilityIdentifier("recap.entry")
        .task(id: "\(mode.rawValue):\(env.taste.revision)") { await shelf.load(mode: mode, env: env, key: "\(mode.rawValue)") }
    }
}
