import SwiftUI

/// Everything the recap surfaces read for one mode, built off the main actor.
@MainActor @Observable
final class RecapShelf {
    private(set) var issues: [TasteRecap] = []
    private(set) var week: TasteRecap?
    private(set) var year: TasteRecap?
    private(set) var sample: TasteRecap?
    private(set) var loaded = false
    private(set) var failed = false
    private(set) var loadedKey = ""
    private var palettes: [String: RecapPalette] = [:]
    private var index: RecapIndex?

    var latest: TasteRecap? { issues.first(where: \.isComplete) ?? issues.first }
    var pastIssues: [TasteRecap] { issues.filter { $0.id != latest?.id } }
    func recap(for start: Date) -> TasteRecap? { issues.first { $0.interval.start == start } }
    func palette(_ recap: TasteRecap) -> RecapPalette { palettes[recap.id] ?? .seeded(recap.tags.first?.name ?? recap.id) }

    /// The full issue, including matches from the wider library.
    func opened(_ recap: TasteRecap, now: Date = Date()) -> TasteRecap {
        guard recap.period == .month, !recap.isSample, var full = index?.recap(period: .month, offset: recap.offset, now: now) else { return recap }
        full.issue = recap.issue
        return full
    }
    func load(mode: TasteMode, env: AppEnvironment, key: String, now: Date = Date()) async {
        if loadedKey != key { loaded = false; failed = false }
        do {
            let index = try await env.taste.recapIndex(mode, hiddenComics: env.hiddenMangaGalleryIDs)
            try Task.checkCancellation()
            let months = index, zone = env.taste.control.timeZone
            let built = await Task.detached(priority: .userInitiated) {
                let issues = months.issues(period: .month, now: now)
                let year = months.yearly(offset: 0, now: now).flatMap { $0.saves >= 3 ? $0 : nil } ?? months.yearly(offset: -1, now: now).flatMap { $0.saves >= 3 ? $0 : nil }
                return (issues, months.recap(period: .week, offset: 0, now: now), year, issues.isEmpty ? TasteRecap.sample(mode: mode, now: now, timeZone: zone) : nil)
            }.value
            try Task.checkCancellation()
            self.index = index; issues = built.0; week = built.1; year = built.2; sample = built.3; loaded = true; loadedKey = key
            try Task.checkCancellation()
            for recap in ([latest, year].compactMap { $0 } + issues + (sample.map { [$0] } ?? [])).prefix(14) { restore(recap, env: env) }
        } catch is CancellationError { }
        catch { failed = true; loaded = true }
    }
    private func restore(_ recap: TasteRecap, env: AppEnvironment) {
        guard palettes[recap.id] == nil, !recap.isSample,
              let saved = try? env.taste.store(recap.mode).metadata(RecapPalette.self, key: "recap.palette." + recap.id) else { return }
        palettes[recap.id] = saved
    }
    /// Measured once from the period's covers. Open periods are re-measured because they still change.
    func measure(_ recap: TasteRecap, artwork: RecapArtwork, env: AppEnvironment) async {
        guard palettes[recap.id] == nil || !recap.isComplete, !recap.saved.isEmpty else { return }
        var pixels: [RecapColor] = []
        for work in recap.saved.prefix(16) {
            guard !Task.isCancelled else { return }
            if let image = await artwork.image(work, generated: recap.isSample) { pixels += RecapPalette.pixels(of: image) }
        }
        guard let palette = RecapPalette.extract(pixels), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.45)) { palettes[recap.id] = palette }
        if !recap.isSample, recap.isComplete { try? env.taste.store(recap.mode).metadata(palette, key: "recap.palette." + recap.id) }
    }
}
