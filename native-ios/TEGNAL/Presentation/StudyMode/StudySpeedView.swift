import SwiftUI
import Observation

/// A minute of quick questions on tags already met: a meaning is shown, and the tag is tapped. No picture is fetched,
/// so nothing waits on the network.
@MainActor @Observable
final class StudySpeedRound: Identifiable {
    enum Phase { case ready, playing, finished }
    let id = UUID()
    static let length = 60.0
    static let most = 20
    /// Tags needed before a round can offer four different answers.
    static let needed = 4

    private(set) var phase = Phase.ready
    private(set) var question: StudyQuestion?
    private(set) var score = 0
    private(set) var asked = 0
    private(set) var combo = 0
    private(set) var bestCombo = 0
    /// Whether the last answer was right, until the next question is shown.
    private(set) var last: Bool?
    private(set) var ends = Date.distantFuture
    private(set) var best = 0
    private(set) var earned = 0
    private(set) var record = false
    let tags: [StudyTag]
    private let store: BooruStore
    private var generator = SystemRandomNumberGenerator()

    init(store: BooruStore, curriculum: StudyCurriculum = .bundled) {
        self.store = store
        let progress = (try? store.studyStore.progress()) ?? [:]
        tags = Self.met(progress, curriculum: curriculum)
        best = (try? store.studyStore.stats())?[StudyCounter.speed] ?? 0
    }

    /// The tags a round may ask: the ones answered at least once.
    static func met(_ progress: [String: StudyProgress], curriculum: StudyCurriculum) -> [StudyTag] {
        curriculum.tags.filter { progress[$0.name].map { !$0.isNew } == true }
    }
    /// Experience for a round: a point for each right answer, up to a ceiling.
    static func reward(_ score: Int) -> Int { min(most, max(0, score)) }

    var canPlay: Bool { tags.count >= Self.needed }

    func start(now: Date = .now) {
        guard canPlay, phase == .ready else { return }
        phase = .playing; ends = now.addingTimeInterval(Self.length)
        ask()
    }

    private func ask() {
        guard let tag = tags.filter({ $0.name != question?.tag.name }).randomElement(using: &generator) else { return }
        let choices = (Array(tags.filter { $0.name != tag.name }.shuffled(using: &generator).prefix(3)) + [tag]).shuffled(using: &generator)
        question = StudyQuestion(kind: .meaningToTag, tag: tag, choices: choices, answer: choices.firstIndex(of: tag) ?? 0)
        last = nil
    }

    /// Takes an answer and moves straight on. Returns whether it was right.
    @discardableResult
    func answer(_ index: Int) -> Bool {
        guard phase == .playing, let question, last == nil else { return false }
        let right = index == question.answer
        asked += 1
        if right { score += 1; combo += 1; bestCombo = max(bestCombo, combo) } else { combo = 0 }
        last = right
        return right
    }

    func next() { if phase == .playing { ask() } }

    func finish() {
        guard phase == .playing else { return }
        phase = .finished
        earned = Self.reward(score)
        record = score > best && score > 0
        if earned > 0 { try? store.studyStore.earn(earned) }
        try? store.studyStore.raise(StudyCounter.speed, to: score)
        try? store.studyStore.raise(StudyCounter.combo, to: bestCombo)
    }
}

struct StudySpeedView: View {
    @State var round: StudySpeedRound
    @Environment(\.dismiss) private var dismiss
    @State private var cheers = 0
    @State private var shakes = 0
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            switch round.phase {
            case .ready: ready
            case .playing: playing
            case .finished: finished
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyTheme.background.ignoresSafeArea())
        .tint(StudyTheme.primary)
    }

    private var ready: some View {
        VStack(spacing: 18) {
            HStack { close; Spacer() }.padding(.horizontal, 16).padding(.top, 10)
            Spacer()
            StudyMascot(pose: .fullBody, size: 170)
            Text(L10n.text("Speed Round")).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.ink)
            Text(L10n.text("Sixty seconds. A meaning appears; tap its tag. How many can you get?"))
                .font(StudyTheme.body(17, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center).padding(.horizontal, 28)
            if round.best > 0 {
                Label(L10n.text("Your best: %@", String(round.best)), systemImage: "trophy.fill").font(StudyTheme.body(16, .heavy)).foregroundStyle(StudyTheme.gold)
            }
            Spacer()
            StudyMainButton(title: L10n.text("Go!"), color: StudyTheme.flame, symbol: "bolt.fill") { StudySound.combo.play(); round.start() }
                .frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 10).accessibilityIdentifier("study.speed.go")
        }
    }

    private var close: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(StudyTheme.muted).frame(width: 36, height: 36)
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("study.close")
    }

    private var playing: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                close
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    let left = max(0, round.ends.timeIntervalSince(timeline.date))
                    StudyBar(value: left / StudySpeedRound.length, color: left < 10 ? StudyTheme.bad : StudyTheme.flame)
                        .onChange(of: left <= 0) { _, over in if over { round.finish(); StudySound.complete.play() } }
                }
                StudyStat(symbol: "bolt.fill", color: StudyTheme.gold, value: String(round.score)).accessibilityIdentifier("study.speed.score")
            }
            .padding(.horizontal, 16).padding(.top, 10)
            if let question = round.question {
                VStack(spacing: 16) {
                    StudyCard {
                        VStack(alignment: .leading, spacing: 6) {
                            if L10n.language != "en" { Text(question.tag.title()).font(StudyTheme.title(24)).foregroundStyle(StudyTheme.primary) }
                            Text(question.tag.note.resolved()).font(StudyTheme.body(18, .semibold)).foregroundStyle(StudyTheme.ink).lineSpacing(3)
                        }
                    }
                    .modifier(StudyShake(travel: CGFloat(shakes)))
                    .overlay { StudyBurst(trigger: cheers, count: 14, reach: 90) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { index, tag in
                            Button { tap(index) } label: {
                                Text(tag.english).font(StudyTheme.body(18, .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 72).padding(.horizontal, 8)
                            }
                            .buttonStyle(StudyPressStyle(color: round.last == nil ? StudyTheme.primary : index == question.answer ? StudyTheme.good : StudyTheme.sunken,
                                                         ink: round.last == nil || index == question.answer ? .white : StudyTheme.muted, radius: 18))
                            .allowsHitTesting(round.last == nil).accessibilityIdentifier("study.speed.choice.\(index)")
                        }
                    }
                }
                .padding(.horizontal, 18).frame(maxWidth: 600).id(question.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
            Spacer(minLength: 0)
            if round.combo >= 3 {
                Label(L10n.text("%@ in a row!", String(round.combo)), systemImage: "flame.fill").font(StudyTheme.title(20)).foregroundStyle(StudyTheme.flame)
                    .transition(.scale.combined(with: .opacity)).padding(.bottom, 24)
            }
        }
        .animation(.snappy(duration: 0.2), value: round.question?.id)
        .animation(.spring(duration: 0.3, bounce: 0.5), value: round.combo)
        .sensoryFeedback(trigger: round.asked) { _, _ in round.last == true ? .success : .error }
    }

    private func tap(_ index: Int) {
        if round.answer(index) { cheers += 1; StudySound.match.play() } else { StudySound.wrong.play(); withAnimation(.linear(duration: 0.3)) { shakes += 1 } }
        // A right answer moves on at once; a wrong one stays long enough to show which tag it was.
        let wait = round.last == true ? 220 : 800
        Task { try? await Task.sleep(for: .milliseconds(wait)); round.next() }
    }

    private var finished: some View {
        VStack(spacing: 20) {
            Spacer()
            StudyMascot(pose: round.score > 0 ? .cheer : .think, size: 170).studyPop(shown, from: 0.2)
                .overlay { StudyBurst(trigger: shown ? 1 : 0, count: 24, reach: 130) }
            Text(L10n.text("Time's Up!")).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.ink).studyRise(shown, delay: 0.1)
                .accessibilityIdentifier("study.speed.done")
            StudyCount(value: shown ? Double(round.score) : 0).font(StudyTheme.title(72)).foregroundStyle(StudyTheme.flame)
                .animation(.easeOut(duration: 0.9).delay(0.3), value: shown)
            if round.record {
                Label(L10n.text("New Best!"), systemImage: "trophy.fill").font(StudyTheme.title(20)).foregroundStyle(StudyTheme.gold).studyPop(shown, delay: 1.1)
            } else if round.best > 0 {
                Text(L10n.text("Your best: %@", String(round.best))).font(StudyTheme.body(16, .heavy)).foregroundStyle(StudyTheme.muted)
            }
            HStack(spacing: 18) {
                StudyStat(symbol: "bolt.fill", color: StudyTheme.gold, value: "+\(round.earned) XP")
                StudyStat(symbol: "flame.fill", color: StudyTheme.flame, value: String(round.bestCombo))
            }.studyRise(shown, delay: 0.6)
            Spacer()
            StudyMainButton(title: L10n.text("Continue")) { StudySound.tap.play(); dismiss() }
                .frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 10).accessibilityIdentifier("study.done")
        }
        .overlay(alignment: .top) { if round.record { StudyConfetti(pieces: 100).allowsHitTesting(false).accessibilityHidden(true) } }
        .onAppear { shown = true }
    }
}
