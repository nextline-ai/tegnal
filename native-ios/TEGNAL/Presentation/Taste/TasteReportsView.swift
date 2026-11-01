import SwiftUI

struct TasteReportsView: View {
    @State private var mode: TasteMode
    let period: TastePeriod
    @Environment(AppEnvironment.self) private var env
    @State private var offset: Int
    @State private var snapshot: TasteSnapshot?
    @State private var failed = false
    @State private var report: TasteReport?
    @State private var displayedKey = ""
    @State private var loaded: [String: (TasteSnapshot, TasteReport?)] = [:]
    private var requestKey: String { "\(mode.rawValue):\(offset):\(env.taste.control.analysisKey(mode))" }
    init(mode: TasteMode, period: TastePeriod) {
        _mode = State(initialValue: mode); self.period = period
        _offset = State(initialValue: period == .month ? -1 : 0)
    }
    var body: some View {
        VStack(spacing: 12) {
            TastePeriodNavigation(period: period, offset: $offset, timeZone: env.taste.control.timeZone, latestOffset: period == .month ? -1 : 0)
                .padding(.horizontal).fixedSize(horizontal: false, vertical: true)
            if !env.taste.control.enabled {
                ContentUnavailableView(L10n.text("Taste analysis is paused on your devices."), systemImage: "pause.circle")
            } else if let snapshot {
                ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            TasteStatisticsView(snapshot: snapshot, period: period, timeZone: env.taste.control.timeZone)
                            if snapshot.saves == 0 { Text(L10n.text("No saved works in this period. Try the previous period to see earlier activity.")).foregroundStyle(.secondary) }
                            if let report, !report.insights.isEmpty {
                                TasteSectionHeading(title: "What stands out")
                                ForEach(report.insights) { insight in
                                    if let tag = snapshot.tags.first(where: { $0.id == insight.tagKey }) {
                                        NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: {
                                            TasteSurface {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text(TastePresentation.name(tag.name)).font(.headline)
                                                    Text(TastePresentation.explanation(insight, tag: tag, snapshot: snapshot)).font(.subheadline).foregroundStyle(.secondary)
                                                }
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            if !snapshot.tags.isEmpty {
                                NavigationLink { TasteTagList(tags: snapshot.tags, mode: mode) } label: { Label(L10n.text("Recommendation evidence"), systemImage: "arrow.up.right") }
                                ForEach(snapshot.tags.prefix(5)) { tag in
                                    NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: { TasteSurface { TasteTagRow(tag: tag) } }.buttonStyle(.plain)
                                }
                            }
                        }.padding().frame(maxWidth: 960).frame(maxWidth: .infinity)
                    }
            } else if failed {
                ContentUnavailableView {
                    Label(L10n.text("Unable to update taste analysis."), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                } actions: { Button(L10n.text("Try Again")) { Task { await load() } } }
            } else { Spacer(); ProgressView(); Spacer() }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.text(period == .month ? "Monthly Recap" : "Weekly statistics"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(TastePresentation.accent)
        .accessibilityIdentifier(period == .month ? "taste.monthly" : "taste.weekly")
        .toolbar { ToolbarItem(placement: .principal) {
            AppModeSwitch(previewMode: Binding(get: { mode == .booru ? .booru : .manga }, set: { mode = $0 == .booru ? .booru : .comics }))
        } }
        .task(id: requestKey) { await load() }
    }
    @MainActor private func load() async {
        let key = requestKey
        displayedKey = key; failed = false
        guard env.taste.control.enabled else { snapshot = nil; report = nil; return }
        if let existing = loaded[key] { snapshot = existing.0; report = existing.1; return }
        snapshot = nil; report = nil
        do {
            let result = try await env.taste.snapshot(mode, period: period, offset: offset)
            try Task.checkCancellation(); snapshot = result
            loaded[key] = (result, nil)
            let control = env.taste.control
            let cached = try env.taste.store(mode).report(digest: result.digest, language: L10n.language, epoch: control.epoch)
            if let cached, cached.isValid(for: result), true { report = cached }
            else {
                let generated = await StatisticalInsightService.report(snapshot: result, control: control, language: L10n.language)
                try Task.checkCancellation()
                guard env.taste.control == control else { return }
                report = generated; try env.taste.store(mode).saveReport(generated)
            }
            loaded[key] = (result, report)
        } catch is CancellationError { }
        catch { failed = true }
    }
}

/// One banner above the shared tab container, with dismissal persisted per month.
struct TasteRecapBanner: View {
    let mode: TasteMode
    let date: Date
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(verbatim: "R").font(RecapType.display(26)).frame(width: 34, height: 44).background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Your new issue has arrived")).font(.subheadline.bold())
                        Text(date, format: .dateTime.year().month(.wide)).font(.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.bold())
                }.padding(.leading, 16).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("taste.recap.open")
            Button(action: dismiss) { Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss recap banner")).accessibilityIdentifier("taste.recap.dismiss")
        }.foregroundStyle(.white)
            .background(LinearGradient(colors: [Color(red: 0.13, green: 0.09, blue: 0.2), Color(red: 0.25, green: 0.1, blue: 0.27)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
