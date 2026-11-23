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
    /// The treasure chest's lid, for the 보석 page: the results' button opens it too.
    var chestOpened: Binding<Bool> = .constant(true)
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch milestone {
        case .streak: StudyTheme.flame
        case .goal: StudyTheme.good
        case .level, .award, .gems: StudyTheme.gold
        }
    }

    var body: some View {
        switch milestone {
        case .award(let award): StudyAwardCelebration(award: award)
        case .gems(let reward): StudyChestPage(reward: reward, opened: chestOpened)
        default: page
        }
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
            case .award, .gems: break
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
        case .award, .gems: EmptyView()
        }
    }

    private var title: String {
        switch milestone {
        case .streak(let count): L10n.text("%@-Day Streak!", String(count))
        case .goal: L10n.text("Daily Goal Met!")
        case .level(let level): L10n.text("Level %@!", String(level))
        case .award(let award): award.name
        case .gems(let reward): String(reward.paid.total)
        }
    }

    private var detail: String {
        switch milestone {
        case .streak(let count): L10n.text(count <= 1 ? "A streak starts today. Come back tomorrow to keep it going." : "You showed up again today. Keep it going tomorrow.")
        case .goal(let goal): L10n.text("You earned the %@ XP you set for today.", String(goal))
        case .level: L10n.text("You know more tags than you did yesterday. Keep climbing.")
        case .award(let award): award.explanation
        case .gems: ""
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

// MARK: - Treasure chest

/// The 보석 a lesson paid, in a treasure chest. It waits, wobbling, until it is tapped or the button below is pressed; then it
/// shakes three times, its lid bursts open with light, the gems fly up into the counter, the counter climbs from the balance
/// before to the balance after, and what paid comes in line by line.
struct StudyChestPage: View {
    let reward: StudyGemReward
    @Binding var opened: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// 0 closed, 1 shaking, 2 open with the gems in flight, 3 counted, 4 what paid listed.
    @State private var stage = 0
    @State private var shakes = 0

    /// `stage` starts the page further on, for pictures of it.
    init(reward: StudyGemReward, opened: Binding<Bool>, stage: Int = 0) {
        self.reward = reward
        _opened = opened
        _stage = State(initialValue: stage)
        _shown = State(initialValue: stage > 0)
    }

    static let gemColors: [Color] = [Color(studyHex: "37D5FF"), StudyTheme.primary, Color(studyHex: "FF5FA2"), Color(studyHex: "3EDC9B"), StudyTheme.gold]
    /// Where the counter sits, from the chest's centre, so the gems fly into it.
    private static let counterLift: CGFloat = -205

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            // Above the chest's light, which spreads up behind it.
            counter.zIndex(1)
            ZStack {
                rays
                StudyChest(openness: stage >= 2 ? 1 : 0)
                    .animation(.spring(duration: 0.7, bounce: 0.4), value: stage >= 2)
                    .phaseAnimator([0.0, -3.5, 3.5, 0.0, 0.0, 0.0]) { view, tilt in view.rotationEffect(.degrees(stage == 0 && !reduceMotion ? tilt : 0), anchor: .bottom) }
                        animation: { _ in .easeInOut(duration: 0.22) }
                    .keyframeAnimator(initialValue: 0.0, trigger: shakes) { view, tilt in
                        view.rotationEffect(.degrees(tilt), anchor: .bottom).scaleEffect(x: 1 + abs(tilt) / 120, y: 1 - abs(tilt) / 160, anchor: .bottom)
                    } keyframes: { _ in
                        CubicKeyframe(-9, duration: 0.05); CubicKeyframe(9, duration: 0.07); CubicKeyframe(-5, duration: 0.05); CubicKeyframe(0, duration: 0.05)
                    }
                    .studyPop(shown, from: 0.3)
                if !reduceMotion { gems }
            }
            .frame(width: 260, height: 230)
            .overlay { StudyBurst(trigger: stage >= 2 ? 1 : 0, count: 30, reach: 170, colors: Self.gemColors + [.white]) }
            .contentShape(Rectangle())
            .onTapGesture { if !opened { opened = true } }
            .accessibilityElement().accessibilityLabel(L10n.text("study.chest.title")).accessibilityAddTraits(stage == 0 ? .isButton : [])
            .accessibilityIdentifier("study.chest")
            Text(stage >= 2 ? L10n.text("study.chest.got", String(reward.paid.total)) : L10n.text("study.chest.title"))
                .font(StudyTheme.title(30)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: stage >= 2)
                .studyRise(shown, delay: 0.2).accessibilityIdentifier("study.milestone")
            if stage < 2 {
                Text(L10n.text("study.chest.hint")).font(StudyTheme.body(16, .bold)).foregroundStyle(StudyTheme.muted)
                    .phaseAnimator([0.0, -5.0]) { view, lift in view.offset(y: reduceMotion ? 0 : lift) } animation: { _ in .easeInOut(duration: 0.6) }
                    .studyRise(shown, delay: 0.3)
            } else {
                lines
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if stage >= 2, !reduceMotion { StudyConfetti(pieces: 90).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: shakes)
        .sensoryFeedback(.success, trigger: stage) { _, new in new == 2 || new == 4 }
        .onChange(of: opened) { _, now in if now { open() } }
        .onAppear {
            shown = true
            StudySound.star1.play()
            if opened { open() }
        }
    }

    /// The balance, with the gem it is counted in; it climbs once the gems land and swells a little as it settles.
    private var counter: some View {
        VStack(spacing: 2) {
            Text(LabStore.shared.shop.currency.text).font(StudyTheme.body(13, .heavy)).foregroundStyle(StudyTheme.muted)
            HStack(spacing: 8) {
                StudyGem(size: 30, color: Self.gemColors[0])
                StudyCount(value: Double(stage >= 3 ? reward.after : reward.before)).font(StudyTheme.title(40)).foregroundStyle(StudyTheme.ink)
                    .animation(.easeOut(duration: 1.0), value: stage >= 3)
                    .accessibilityIdentifier("study.chest.balance")
            }
            .scaleEffect(stage == 3 ? 1.12 : 1).animation(.spring(duration: 0.4, bounce: 0.6), value: stage)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(StudyTheme.surface, in: Capsule())
        .overlay { Capsule().strokeBorder(stage >= 3 ? StudyTheme.gold : StudyTheme.line, lineWidth: 2) }
        .studyRise(shown, delay: 0.1)
    }

    /// Light turning behind the chest once it is open.
    private var rays: some View {
        ZStack {
            RadialGradient(colors: [Color(studyHex: "FFF3B0"), StudyTheme.gold.opacity(0.45), .clear], center: .center, startRadius: 4, endRadius: 120)
                .frame(width: 260, height: 260)
            ForEach(0..<12, id: \.self) { index in
                Capsule().fill(StudyTheme.gold.opacity(0.28)).frame(width: 12, height: 170).offset(y: -85).rotationEffect(.degrees(Double(index) * 30))
            }
            .rotationEffect(.degrees(stage >= 2 && !reduceMotion ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 20).repeatForever(autoreverses: false), value: stage >= 2)
        }
        .offset(y: -30)
        .scaleEffect(stage >= 2 ? 1 : 0.1).opacity(stage >= 2 ? 1 : 0)
        .animation(.spring(duration: 0.6, bounce: 0.3), value: stage >= 2)
        .accessibilityHidden(true)
    }

    /// The gems: out of the chest in a fan, a moment in the air, then into the counter above.
    private var gems: some View {
        let count = min(14, max(6, reward.paid.total / 5))
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let spread = Double(index) / Double(max(1, count - 1)) - 0.5
                let spray = CGSize(width: spread * 230, height: -70 - abs(sin(Double(index) * 1.7)) * 70)
                let delay = Double(index) * 0.045
                StudyGem(size: 26, color: Self.gemColors[index % Self.gemColors.count])
                    .keyframeAnimator(initialValue: StudyGemFlight(), trigger: stage >= 2) { view, flight in
                        view.scaleEffect(flight.scale).rotationEffect(.degrees(flight.spin)).offset(flight.offset).opacity(flight.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.offset) {
                            LinearKeyframe(CGSize(width: 0, height: -20), duration: delay)
                            SpringKeyframe(spray, duration: 0.5, spring: .bouncy)
                            LinearKeyframe(spray, duration: 0.12)
                            CubicKeyframe(CGSize(width: 0, height: Self.counterLift), duration: 0.42)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.2, duration: delay)
                            SpringKeyframe(1.15, duration: 0.5)
                            LinearKeyframe(1, duration: 0.12)
                            CubicKeyframe(0.45, duration: 0.42)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: delay)
                            LinearKeyframe(1, duration: 0.06)
                            LinearKeyframe(1, duration: 0.96)
                            LinearKeyframe(0, duration: 0.06)
                        }
                        KeyframeTrack(\.spin) {
                            LinearKeyframe(0, duration: delay)
                            CubicKeyframe(spread * 140, duration: 1.04)
                        }
                    }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    /// What paid, line by line: the lesson, its three stars, its section.
    private var lines: some View {
        let rows: [(String, String, Color, Int)] = [
            ("checkmark.circle.fill", L10n.text("study.chest.lesson"), StudyTheme.good, reward.paid.lesson),
            ("star.fill", L10n.text("study.chest.stars"), StudyTheme.gold, reward.paid.stars),
            ("flag.checkered", L10n.text("study.chest.section"), StudyTheme.primary, reward.paid.section)
        ].filter { $0.3 > 0 }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 10) {
                    Image(systemName: row.0).font(.system(size: 17, weight: .bold)).foregroundStyle(row.2).frame(width: 24)
                    Text(row.1).font(StudyTheme.body(16, .heavy)).foregroundStyle(StudyTheme.ink)
                    Spacer()
                    Text(verbatim: "+\(row.3)").font(StudyTheme.body(17, .heavy)).foregroundStyle(StudyTheme.primary).monospacedDigit()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
                .studyRise(stage >= 4, delay: Double(index) * 0.12)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("study.chest.lines")
    }

    private func open() {
        guard stage == 0 else { return }
        guard !reduceMotion else { stage = 4; StudySound.levelup.play(); return }
        Task {
            stage = 1
            for _ in 0..<3 {
                shakes += 1
                StudySound.pick.play()
                try? await Task.sleep(for: .milliseconds(240))
            }
            withAnimation(.spring(duration: 0.45, bounce: 0.45)) { stage = 2 }
            StudySound.levelup.play()
            try? await Task.sleep(for: .milliseconds(1150))
            stage = 3
            StudySound.combo.play()
            try? await Task.sleep(for: .milliseconds(900))
            stage = 4
        }
    }
}

/// One gem's flight out of the chest.
struct StudyGemFlight {
    var offset = CGSize(width: 0, height: -20)
    var scale = 0.2
    var opacity = 0.0
    var spin = 0.0
}

/// A cut gem: a diamond with a lighter crown and a white glint, in the course's chunky style.
struct StudyGem: View {
    var size: CGFloat
    var color: Color
    var body: some View {
        Image(systemName: "diamond.fill").font(.system(size: size, weight: .black)).foregroundStyle(color)
            .overlay {
                Image(systemName: "diamond.fill").font(.system(size: size * 0.42, weight: .black)).foregroundStyle(.white.opacity(0.55))
                    .offset(x: -size * 0.12, y: -size * 0.14)
            }
            .shadow(color: color.studyEdge(), radius: 0, y: size / 12)
    }
}

/// A treasure chest, painted on a 220 × 200 grid (the Android app paints the same grid). `openness` runs from 0 (shut) to 1
/// (open, a spring may overshoot): the outside of the domed lid folds down onto its hinge, then its lit inside rises behind
/// the glowing mouth, and the lock drops away.
struct StudyChest: View, Animatable {
    var openness: Double
    var animatableData: Double { get { openness } set { openness = newValue } }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 220, y: size.height / 200)
            StudyChestArt.draw(in: &context, openness: openness)
        }
        .frame(width: 220, height: 200)
        .accessibilityHidden(true)
    }
}

enum StudyChestArt {
    static let ink = Color(studyHex: "4A1F07")
    static let goldLight = Color(studyHex: "FFE9A6"), goldMid = Color(studyHex: "FFC02E"), goldDark = Color(studyHex: "D48A06")

    /// The lid's dome, with its foot at `base` and `height` above it; negative heights are not drawn.
    static func dome(base: CGFloat, height: CGFloat, inset: CGFloat = 0) -> Path {
        var path = Path()
        let left = 8 + inset, right = 212 - inset, h = max(0, height)
        path.move(to: CGPoint(x: left, y: base))
        path.addLine(to: CGPoint(x: left, y: base - h * 0.45))
        path.addCurve(to: CGPoint(x: 110, y: base - h), control1: CGPoint(x: left, y: base - h * 0.85), control2: CGPoint(x: 52, y: base - h))
        path.addCurve(to: CGPoint(x: right, y: base - h * 0.45), control1: CGPoint(x: 168, y: base - h), control2: CGPoint(x: right, y: base - h * 0.85))
        path.addLine(to: CGPoint(x: right, y: base))
        path.closeSubpath()
        return path
    }

    static func gold(_ rect: CGRect, across: Bool = false) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [goldLight, goldMid, goldDark]),
                        startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: across ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY))
    }

    static func diamond(_ center: CGPoint, _ size: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - size)); path.addLine(to: CGPoint(x: center.x + size * 0.8, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + size)); path.addLine(to: CGPoint(x: center.x - size * 0.8, y: center.y)); path.closeSubpath()
        return path
    }

    static func rivet(_ context: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: x - 3.2, y: y - 3.2, width: 6.4, height: 6.4)), with: .color(Color(studyHex: "9A5F05")))
        context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.75)))
    }

    static func draw(in context: inout GraphicsContext, openness t: Double) {
        let shut = CGFloat(max(0, 1 - t / 0.45))               // how much of the lid's outside still shows
        let rise = CGFloat(min(1.12, max(0, (t - 0.45) / 0.55))) // how far its inside has risen
        let lit = CGFloat(min(1, max(0, t * 2)))

        // Shadow on the ground.
        context.fill(Path(ellipseIn: CGRect(x: 22, y: 176, width: 176, height: 18)), with: .color(.black.opacity(0.16)))

        // The inside of the lid, standing behind the mouth once it swings past upright; lit from below by what is inside.
        if rise > 0 {
            let inside = dome(base: 88, height: 80 * rise)
            context.fill(inside, with: .linearGradient(Gradient(colors: [Color(studyHex: "7A3814"), Color(studyHex: "4A1C07")]), startPoint: CGPoint(x: 0, y: 88 - 80 * rise), endPoint: CGPoint(x: 0, y: 88)))
            var bands = context
            bands.clip(to: inside)
            for x in [36.0, 166.0] { bands.fill(Path(CGRect(x: x, y: 0, width: 18, height: 90)), with: .color(Color(studyHex: "B87908"))) }
            bands.fill(Path(CGRect(x: 0, y: 40, width: 220, height: 48)), with: .linearGradient(Gradient(colors: [.clear, Color(studyHex: "FFD45A").opacity(0.55)]), startPoint: CGPoint(x: 0, y: 40), endPoint: CGPoint(x: 0, y: 88)))
            context.stroke(dome(base: 88, height: 80 * rise, inset: 3), with: gold(CGRect(x: 0, y: 10, width: 220, height: 80)), lineWidth: 6)
            context.stroke(inside, with: .color(ink), lineWidth: 3)
        }

        // The mouth: the dark inside of the box, gems catching the light.
        if lit > 0 {
            let mouth = Path(roundedRect: CGRect(x: 14, y: 76, width: 192, height: 28), cornerRadius: 10)
            context.fill(mouth, with: .color(Color(studyHex: "3A1604")))
            context.fill(mouth, with: .radialGradient(Gradient(colors: [Color(studyHex: "FFF6CC").opacity(lit), Color(studyHex: "FFC23A").opacity(0.8 * lit), .clear]),
                                                     center: CGPoint(x: 110, y: 92), startRadius: 2, endRadius: 96))
            context.stroke(mouth, with: gold(CGRect(x: 14, y: 76, width: 192, height: 28)), lineWidth: 4)
            context.stroke(mouth, with: .color(ink), lineWidth: 2)
            // A heap of coins and gems spilling over the rim.
            var heap = context
            heap.opacity = Double(lit)
            heap.translateBy(x: 0, y: 10 * (1 - lit))
            for (x, y) in [(40.0, 80.0), (58, 74), (76, 78), (96, 71), (124, 72), (144, 77), (162, 73), (180, 80), (68, 84), (110, 79), (152, 84)] {
                let coin = CGRect(x: x - 9, y: y - 5, width: 18, height: 10)
                heap.fill(Path(ellipseIn: coin.offsetBy(dx: 0, dy: 1.5)), with: .color(Color(studyHex: "9A5F05")))
                heap.fill(Path(ellipseIn: coin), with: gold(coin))
                heap.fill(Path(ellipseIn: coin.insetBy(dx: 5, dy: 3)), with: .color(.white.opacity(0.35)))
            }
            let colors = StudyChestPage.gemColors
            for (index, point) in [CGPoint(x: 52, y: 70), CGPoint(x: 84, y: 64), CGPoint(x: 112, y: 60), CGPoint(x: 138, y: 65), CGPoint(x: 168, y: 70)].enumerated() {
                heap.fill(diamond(CGPoint(x: point.x, y: point.y + 2), 11), with: .color(colors[index % colors.count].studyEdge()))
                heap.fill(diamond(point, 11), with: .color(colors[index % colors.count]))
                heap.fill(diamond(CGPoint(x: point.x - 2.5, y: point.y - 3), 4), with: .color(.white.opacity(0.7)))
            }
        }

        // The body.
        let body = Path(roundedRect: CGRect(x: 12, y: 92, width: 196, height: 88), cornerRadius: 14, style: .continuous)
        context.fill(body, with: .linearGradient(Gradient(colors: [Color(studyHex: "CB7C3E"), Color(studyHex: "8A4418")]), startPoint: CGPoint(x: 0, y: 92), endPoint: CGPoint(x: 0, y: 180)))
        var inBody = context
        inBody.clip(to: body)
        for y in [122.0, 151.0] {
            inBody.fill(Path(CGRect(x: 12, y: y, width: 196, height: 2.2)), with: .color(Color(studyHex: "5E290B").opacity(0.55)))
            inBody.fill(Path(CGRect(x: 12, y: y + 2.2, width: 196, height: 1.4)), with: .color(.white.opacity(0.13)))
        }
        // Light from the left, shade on the right.
        inBody.fill(Path(CGRect(x: 12, y: 92, width: 40, height: 88)), with: .linearGradient(Gradient(colors: [.white.opacity(0.14), .clear]), startPoint: CGPoint(x: 12, y: 0), endPoint: CGPoint(x: 52, y: 0)))
        inBody.fill(Path(CGRect(x: 160, y: 92, width: 48, height: 88)), with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.2)]), startPoint: CGPoint(x: 160, y: 0), endPoint: CGPoint(x: 208, y: 0)))
        let top = CGRect(x: 12, y: 92, width: 196, height: 11), foot = CGRect(x: 12, y: 168, width: 196, height: 12)
        inBody.fill(Path(top), with: gold(top)); inBody.fill(Path(foot), with: gold(foot))
        for x in [36.0, 166.0] {
            let band = CGRect(x: x, y: 92, width: 18, height: 88)
            inBody.fill(Path(band), with: gold(band, across: true))
            inBody.stroke(Path(band), with: .color(ink.opacity(0.45)), lineWidth: 1.2)
        }
        context.stroke(body, with: .color(ink), lineWidth: 3)
        for x in [45.0, 175.0] { for y in [116.0, 158.0] { rivet(&context, x, y) } }

        // The outside of the lid, folding down onto its hinge as it opens.
        if shut > 0 {
            let lid = dome(base: 94, height: 80 * shut)
            context.fill(lid, with: .linearGradient(Gradient(colors: [Color(studyHex: "DA8C47"), Color(studyHex: "99491B")]), startPoint: CGPoint(x: 0, y: 94 - 80 * shut), endPoint: CGPoint(x: 0, y: 94)))
            var inLid = context
            inLid.clip(to: lid)
            for x in [36.0, 166.0] {
                let band = CGRect(x: x, y: 0, width: 18, height: 94)
                inLid.fill(Path(band), with: gold(band, across: true))
                inLid.stroke(Path(band), with: .color(ink.opacity(0.45)), lineWidth: 1.2)
            }
            let rim = CGRect(x: 0, y: 94 - 11 * shut, width: 220, height: 11 * shut)
            inLid.fill(Path(rim), with: gold(rim))
            inLid.fill(Path(ellipseIn: CGRect(x: 44, y: 94 - 76 * shut, width: 132, height: 22 * shut)), with: .color(.white.opacity(0.22)))
            context.stroke(lid, with: .color(ink), lineWidth: 3)
            if shut > 0.6 { for x in [45.0, 175.0] { rivet(&context, x, 94 - 46 * shut) } }
        }

        // The lock, across the seam; it drops away first.
        let fall = CGFloat(min(1, t / 0.3))
        if fall < 1 {
            var lock = context
            lock.opacity = Double(1 - fall)
            lock.translateBy(x: 0, y: 46 * fall)
            let plate = CGRect(x: 92, y: 80, width: 36, height: 40)
            let shape = Path(roundedRect: plate, cornerRadius: 9, style: .continuous)
            lock.fill(Path(roundedRect: plate.offsetBy(dx: 0, dy: 3), cornerRadius: 9, style: .continuous), with: .color(ink))
            lock.fill(shape, with: gold(plate))
            lock.stroke(shape, with: .color(ink), lineWidth: 2.5)
            lock.fill(Path(ellipseIn: CGRect(x: 104.5, y: 89, width: 11, height: 11)), with: .color(ink))
            lock.fill(Path(roundedRect: CGRect(x: 107.5, y: 96, width: 5, height: 13), cornerRadius: 2), with: .color(ink))
        }
    }
}
