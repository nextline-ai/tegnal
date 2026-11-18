import SwiftUI
import AVFoundation

// Learning mode answers everything the learner does: a sound, a movement, a word from the guide.

/// The sounds learning mode makes. They are played as media: the volume buttons turn them up and down, the silent
/// switch does not mute them, and they play over music the learner is listening to without stopping it.
@MainActor
enum StudySound: String, CaseIterable {
    case tap, pick, right, wrong, match, combo, star1, star2, star3, complete, levelup, streak
    static let key = "study.sound"
    static var isOn: Bool {
        get { ReaderPreferences.booruDefaults.object(forKey: key) as? Bool ?? true }
        set { ReaderPreferences.booruDefaults.set(newValue, forKey: key) }
    }
    private static var players: [StudySound: AVAudioPlayer] = [:]
    private static var claimed = false

    /// Loads every sound, so that the first one played does not arrive late.
    static func warm() {
        guard isOn else { return }
        for sound in allCases { _ = sound.player() }
    }

    /// Hands the audio session back as it was found, once learning mode is left.
    static func rest() {
        // The whole app plays as media, so there is nothing to hand back; the next sound simply claims the session again.
        claimed = false
    }

    private func player() -> AVAudioPlayer? {
        if let player = Self.players[self] { return player }
        guard let url = Bundle.main.url(forResource: "StudySound-" + rawValue, withExtension: "wav", subdirectory: "StudySounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        Self.players[self] = player
        return player
    }

    func play() {
        guard Self.isOn else { return }
        if !Self.claimed {
            Self.claimed = true
            // Playback is the category the silent switch leaves alone; mixing keeps the learner's own music going.
            AppAudio.useMediaVolume()
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        guard let player = player() else { return }
        player.currentTime = 0
        player.play()
    }
}

/// What the guide says when an answer is in. The words change so that praise does not wear out.
enum StudyPraise {
    static let right = ["That's right!", "Nice!", "Great job!", "Exactly!", "You got it!"]
    static let wrong = ["Not quite", "Almost!", "So close!"]
    /// The runs of right answers that are called out.
    static let runs: Set<Int> = [3, 5, 10, 15, 20, 30]

    static func line(right: Bool, combo: Int, seed: Int) -> String {
        if right, combo >= 10 { return L10n.text("Unstoppable!") }
        if right, combo >= 5 { return L10n.text("On fire!") }
        let lines = right ? Self.right : wrong
        return L10n.text(lines[abs(seed) % lines.count])
    }
}

/// A steady value in 0..<1 for a piece of an effect, so that every frame draws the same piece the same way.
private func studyUnit(_ index: Int, _ salt: Int) -> Double {
    var value = UInt64(truncatingIfNeeded: index &* 2_654_435_761 &+ salt &* 40_503 &+ 12_345)
    value ^= value >> 15; value = value &* 2_246_822_519; value ^= value >> 13
    return Double(value % 10_000) / 10_000
}

/// Sparks thrown out from the middle of the view, once each time `trigger` changes.
struct StudyBurst: View {
    var trigger: Int
    var count = 16
    var reach: CGFloat = 90
    var colors: [Color] = [StudyTheme.gold, StudyTheme.good, StudyTheme.primary, StudyTheme.flame]
    /// Fires as soon as it is on screen as well.
    var onAppear = false
    @State private var began: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let length = 0.85

    var body: some View {
        TimelineView(.animation(paused: began == nil)) { timeline in
            Canvas { context, size in
                guard let began else { return }
                let progress = timeline.date.timeIntervalSince(began) / Self.length
                guard progress < 1 else { return }
                let ease = 1 - pow(1 - progress, 3)
                for index in 0..<count {
                    let angle = (Double(index) + studyUnit(index, 1) * 0.8) / Double(count) * 2 * .pi
                    let distance = reach * (0.4 + studyUnit(index, 2) * 0.6) * ease
                    var piece = context
                    piece.opacity = 1 - progress * progress
                    piece.translateBy(x: size.width / 2 + cos(angle) * distance, y: size.height / 2 + sin(angle) * distance + 36 * progress * progress)
                    piece.rotate(by: .radians(progress * 4 + studyUnit(index, 3) * 6))
                    let side = (5 + studyUnit(index, 4) * 7) * (1 - progress * 0.4)
                    piece.fill(index % 3 == 0 ? Self.spark(side * 1.6) : Path(ellipseIn: CGRect(x: -side / 2, y: -side / 2, width: side, height: side)),
                               with: .color(colors[index % colors.count]))
                }
            }
        }
        .frame(width: reach * 2.6, height: reach * 2.6)
        .allowsHitTesting(false).accessibilityHidden(true)
        .onChange(of: trigger) { fire() }
        .onAppear { if onAppear { fire() } }
    }

    private func fire() {
        guard !reduceMotion else { return }
        let now = Date.now
        began = now
        Task { try? await Task.sleep(for: .seconds(Self.length + 0.05)); if began == now { began = nil } }
    }

    /// A four-pointed spark.
    private static func spark(_ side: CGFloat) -> Path {
        var path = Path()
        for index in 0..<8 {
            let radius = index % 2 == 0 ? side / 2 : side / 6
            let angle = Double(index) / 8 * 2 * .pi
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Shakes its content from side to side as `travel` moves from one whole number to the next.
struct StudyShake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat { get { travel } set { travel = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 9 * sin(travel * .pi * 4), y: 0))
    }
}

/// A whole number that counts up to its value when animated.
struct StudyCount: View, Animatable {
    var value: Double
    var prefix = ""
    var suffix = ""
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text(verbatim: prefix + String(Int(value.rounded())) + suffix).monospacedDigit() }
}

extension View {
    /// Springs in from small the first time it is shown, after a wait.
    func studyPop(_ shown: Bool, delay: Double = 0, from scale: CGFloat = 0.4) -> some View {
        scaleEffect(shown ? 1 : scale).opacity(shown ? 1 : 0)
            .animation(.spring(duration: 0.5, bounce: 0.5).delay(delay), value: shown)
    }
    /// Slides up into place the first time it is shown, after a wait.
    func studyRise(_ shown: Bool, delay: Double = 0, by distance: CGFloat = 26) -> some View {
        offset(y: shown ? 0 : distance).opacity(shown ? 1 : 0)
            .animation(.spring(duration: 0.45, bounce: 0.3).delay(delay), value: shown)
    }
}

/// Called out across the top of a lesson when right answers run on.
struct StudyComboBanner: View {
    let combo: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill").font(.system(size: 22, weight: .heavy))
                .phaseAnimator([1.0, 1.25, 1.0]) { view, scale in view.scaleEffect(scale) } animation: { _ in .easeInOut(duration: 0.3) }
            Text(L10n.text("%@ in a row!", String(combo))).font(StudyTheme.title(20))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(LinearGradient(colors: [StudyTheme.flame, StudyTheme.gold], startPoint: .leading, endPoint: .trailing), in: Capsule())
        .background { Capsule().fill(StudyTheme.flame.studyEdge()).offset(y: 4) }
        .overlay { StudyBurst(trigger: combo, count: 14, reach: 80, colors: [StudyTheme.gold, StudyTheme.flame, .white], onAppear: true) }
        .accessibilityElement(children: .combine).accessibilityIdentifier("study.combo")
    }
}

// MARK: - Milestones

/// A full page shown after a lesson's results for something reached beyond the lesson: a streak, the day's goal, a level.
struct StudyMilestoneView: View {
    let milestone: StudyMilestone
    let days: [StudyDay]
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch milestone {
        case .streak: StudyTheme.flame
        case .goal: StudyTheme.good
        case .level, .award: StudyTheme.gold
        }
    }

    var body: some View {
        if case .award(let award) = milestone { StudyAwardCelebration(award: award) } else { page }
    }

    private var page: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            ZStack {
                // Rays turning slowly behind the badge.
                ForEach(0..<12, id: \.self) { index in
                    Capsule().fill(color.opacity(0.22)).frame(width: 10, height: 150).offset(y: -75).rotationEffect(.degrees(Double(index) * 30))
                }
                .rotationEffect(.degrees(shown && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 24).repeatForever(autoreverses: false), value: shown)
                .scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
                .animation(.spring(duration: 0.6, bounce: 0.3), value: shown)
                badge.studyPop(shown, delay: 0.1, from: 0.1)
            }
            .frame(width: 230, height: 230)
            // In an overlay, so that sparks flying past the edge do not widen the page.
            .overlay { StudyBurst(trigger: shown ? 1 : 0, count: 26, reach: 150, colors: [color, StudyTheme.gold, StudyTheme.primary, .white]) }
            Text(title).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                .studyRise(shown, delay: 0.35).accessibilityIdentifier("study.milestone")
            Text(detail).font(StudyTheme.body(17, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                .studyRise(shown, delay: 0.45)
            if case .streak = milestone { week.studyRise(shown, delay: 0.55) }
            if case .goal = milestone { StudyMascot(pose: .cheer, size: 120).studyPop(shown, delay: 0.5) }
            if case .level = milestone { StudyMascot(pose: .fullBody, size: 130).studyPop(shown, delay: 0.5) }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if case .level = milestone, !reduceMotion { StudyConfetti(pieces: 110).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear {
            shown = true
            switch milestone {
            case .streak: StudySound.streak.play()
            case .goal: StudySound.combo.play()
            case .level: StudySound.levelup.play()
            case .award: break
            }
        }
    }

    @ViewBuilder private var badge: some View {
        switch milestone {
        case .streak(let count):
            ZStack {
                Image(systemName: "flame.fill").font(.system(size: 150, weight: .bold)).foregroundStyle(LinearGradient(colors: [StudyTheme.gold, StudyTheme.flame], startPoint: .top, endPoint: .bottom))
                    .phaseAnimator([1.0, 1.06]) { view, scale in view.scaleEffect(scale, anchor: .bottom) } animation: { _ in .easeInOut(duration: 0.7) }
                StudyCount(value: shown ? Double(count) : Double(max(0, count - 1))).font(StudyTheme.title(58)).foregroundStyle(.white)
                    .shadow(color: StudyTheme.flame.studyEdge(), radius: 0, y: 3).offset(y: 28)
                    .animation(.easeOut(duration: 0.5).delay(0.5), value: shown)
            }
        case .goal:
            Image(systemName: "checkmark.seal.fill").font(.system(size: 140, weight: .bold)).foregroundStyle(StudyTheme.good)
                .symbolEffect(.bounce, value: shown)
        case .level(let level):
            ZStack {
                Image(systemName: "shield.fill").font(.system(size: 150, weight: .bold)).foregroundStyle(LinearGradient(colors: [StudyTheme.gold, StudyTheme.flame], startPoint: .top, endPoint: .bottom))
                Text(String(level)).font(StudyTheme.title(64)).foregroundStyle(.white).shadow(color: StudyTheme.flame.studyEdge(), radius: 0, y: 3).offset(y: -6)
            }
        case .award: EmptyView()
        }
    }

    private var title: String {
        switch milestone {
        case .streak(let count): L10n.text("%@-Day Streak!", String(count))
        case .goal: L10n.text("Daily Goal Met!")
        case .level(let level): L10n.text("Level %@!", String(level))
        case .award(let award): award.name
        }
    }

    private var detail: String {
        switch milestone {
        case .streak(let count): L10n.text(count <= 1 ? "A streak starts today. Come back tomorrow to keep it going." : "You showed up again today. Keep it going tomorrow.")
        case .goal(let goal): L10n.text("You earned the %@ XP you set for today.", String(goal))
        case .level: L10n.text("You know more tags than you did yesterday. Keep climbing.")
        case .award(let award): award.explanation
        }
    }

    /// The last seven days, lit where something was studied.
    private var week: some View {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: L10n.language)
        let studied = Set(days.filter(\.isStudied).map(\.day))
        let today = Date.now
        return HStack(spacing: 10) {
            ForEach((0..<7).reversed(), id: \.self) { back in
                let date = calendar.date(byAdding: .day, value: -back, to: today) ?? today
                let lit = studied.contains(StudyDay.key(date, calendar: calendar)) || back == 0
                VStack(spacing: 6) {
                    Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]).font(StudyTheme.body(12, .heavy)).foregroundStyle(StudyTheme.muted)
                    Image(systemName: lit ? "flame.fill" : "circle.fill").font(.system(size: lit ? 20 : 12, weight: .bold))
                        .foregroundStyle(lit ? StudyTheme.flame : StudyTheme.line).frame(width: 30, height: 30)
                        .background(lit ? StudyTheme.flame.opacity(0.16) : .clear, in: Circle())
                        .studyPop(shown, delay: 0.6 + Double(6 - back) * 0.06)
                }
            }
        }
        .padding(16).background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
        .accessibilityHidden(true)
    }
}
