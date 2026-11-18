import SwiftUI

/// Everything learning mode shows, read again whenever a lesson may have changed it.
@MainActor @Observable
final class StudyModeModel {
    static let goalKey = "study.goal"
    let path = StudyPath.bundled
    let curriculum = StudyCurriculum.bundled
    private let defaults = ReaderPreferences.booruDefaults
    private(set) var records: [String: StudyLessonRecord] = [:]
    private(set) var progress: [String: StudyProgress] = [:]
    private(set) var summary = StudySummary()
    private(set) var game = StudyGame()
    private(set) var server = StudyServer.fallback
    private(set) var needsServer = false
    /// Every badge, which of them are earned, and the numbers they are measured by.
    private(set) var awards: [StudyAward] = []
    private(set) var earned: [String: StudyAwardRecord] = [:]
    private(set) var facts = StudyFacts()
    /// How many tags have been missed at least once, for Weak Spots.
    private(set) var weak = 0
    var goal: Int { didSet { defaults.set(goal, forKey: Self.goalKey) } }

    init() {
        let saved = ReaderPreferences.booruDefaults.integer(forKey: Self.goalKey)
        goal = StudyGame.goals.contains(saved) ? saved : StudyGame.defaultGoal
    }

    func reload(_ store: BooruStore) {
        let study = store.studyStore
        let days = (try? study.days()) ?? []
        records = (try? study.lessons()) ?? [:]
        progress = (try? study.progress()) ?? [:]
        summary = StudySummary(curriculum: curriculum, progress: progress, days: days)
        game = StudyGame(days: days, goal: goal)
        server = StudyServer.current(store, defaults: defaults)
        needsServer = StudyServer.needsChoice(store, defaults: defaults)
        if awards.isEmpty { awards = StudyAward.all(path) }
        earned = (try? study.awards()) ?? [:]
        facts = StudyFacts(path: path, records: records, days: days, progress: progress, stats: (try? study.stats()) ?? [:])
        weak = progress.values.filter { $0.wrong > 0 && curriculum.contains($0.tag) }.count
    }

    func choose(_ server: BooruServer, store: BooruStore) {
        defaults.set(server.id, forKey: StudyServer.key)
        reload(store)
    }
}

/// Learning mode: its own screens and its own dock, in place of the library's.
struct StudyModeRoot: View {
    @Environment(BooruStore.self) private var store
    @State private var mode = StudyMode.shared
    @State private var model = StudyModeModel()
    @State private var session: StudyLessonSession?
    @State private var choosingServer = false
    /// The lesson that has just been finished, while the path celebrates it.
    @State private var celebrating: String?
    @State private var finished: String?
    @State private var speed: StudySpeedRound?
    @State private var showingAwards = false
    /// Badges earned away from a lesson, waiting for their celebration.
    @State private var parade: [StudyAward] = []
    private let source: any BooruProviding = TasteSources.booru

    var body: some View {
        Group {
            switch mode.tab {
            case .path: StudyPathView(model: model, celebrating: celebrating, start: start)
            case .practice: StudyPracticeView(model: model, start: start) { speed = StudySpeedRound(store: store) }
            case .dex: StudyDexView(model: model, source: source)
            case .lab: StudyLabView(model: model, start: start, closed: celebrate)
            case .me: StudyMeView(model: model, chooseServer: { choosingServer = true }, openAwards: { showingAwards = true })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { StudyDock(selection: $mode.tab) }
        .tint(StudyTheme.primary)
        .fullScreenCover(item: $session, onDismiss: closed) { StudyPlayView(session: $0) }
        .sheet(isPresented: $choosingServer) { StudyServerPicker(model: model).presentationDetents([.medium, .large]) }
        .fullScreenCover(item: $speed, onDismiss: { withAnimation { model.reload(store) }; celebrate() }) { StudySpeedView(round: $0) }
        .fullScreenCover(isPresented: $showingAwards) { StudyAwardsGallery(model: model) }
        .fullScreenCover(isPresented: Binding(get: { !parade.isEmpty }, set: { if !$0 { parade = [] } })) {
            StudyAwardParade(awards: parade) { parade = []; model.reload(store) }
        }
        .onAppear {
            #if DEBUG
            // For tests and screenshots: `--study-seed-path=<lesson>` starts with every lesson before that one finished.
            if let target = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--study-seed-path=") })?.dropFirst(18) {
                for lesson in model.path.lessons.prefix(while: { $0.id != target }) { try? store.studyStore.earn(15, lesson: lesson.id, stars: 3) }
                ReaderPreferences.booruDefaults.set(StudyServer.recommended(StudyServer.choices(store)).id, forKey: StudyServer.key)
            }
            // `--study-seed-xp=<n>` starts with that much experience earned today, to reach a level's edge.
            if let xp = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--study-seed-xp=") })?.dropFirst(16), let amount = Int(xp), model.game.xp == 0 {
                try? store.studyStore.earn(amount)
            }
            // `--study-seed-tags=<n>` starts with the first n tags answered once, the first two of them wrongly as well.
            if let count = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--study-seed-tags=") })?.dropFirst(18), let amount = Int(count),
               ((try? store.studyStore.progress()) ?? [:]).count < amount {
                for (index, tag) in model.curriculum.tags.prefix(amount).enumerated() {
                    if index < 2 { try? store.studyStore.answer(tag.name, right: false) }
                    try? store.studyStore.answer(tag.name, right: true)
                }
            }
            // Badges the seeds earn are not celebrated: the seeded lessons were never played.
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--study-seed-") }) {
                try? store.studyStore.markSeen(StudyAwards.refresh(store, path: model.path).map(\.id))
            }
            #endif
            model.reload(store)
            StudySound.warm()
            // A learner who already has servers says once which one the pictures come from.
            if model.needsServer { choosingServer = true } else { celebrate() }
        }
        .onChange(of: store.revision) { model.reload(store) }
        // The path behind a finished lesson is already up to date when the lesson closes.
        .onChange(of: session?.phase) { _, phase in
            guard phase == .finished else { return }
            model.reload(store)
            finished = session?.plan.lesson?.id
        }
    }

    /// Shows the badges earned since the last look that no lesson's results have shown, such as one for a picture generated.
    private func celebrate() {
        let unseen = StudyAwards.refresh(store, path: model.path)
        model.reload(store)
        guard !unseen.isEmpty, session == nil, speed == nil else { return }
        try? store.studyStore.markSeen(unseen.map(\.id))
        // A cover cannot go up while another is on its way down. A long backlog, as after an update, shows only its last few.
        Task { try? await Task.sleep(for: .milliseconds(450)); parade = Array(unseen.suffix(3)) }
    }

    /// Back on the path after a lesson: the stop just finished bursts, and the numbers at the top count up.
    private func closed() {
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { model.reload(store) }
        celebrate()
        guard let done = finished else { return }
        finished = nil
        mode.tab = .path
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            celebrating = done
            try? await Task.sleep(for: .milliseconds(200))
            StudySound.star2.play()
            try? await Task.sleep(for: .seconds(1.3))
            if celebrating == done { celebrating = nil }
        }
    }

    private func start(_ plan: StudyLessonPlan) {
        session = StudyLessonSession(plan: plan, store: store, source: source, server: model.server)
    }
}

struct StudyDock: View {
    @Binding var selection: StudyTab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(StudyTab.allCases) { tab in
                let chosen = tab == selection
                Button { StudySound.tap.play(); withAnimation(.snappy(duration: 0.2)) { selection = tab } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 21, weight: .bold))
                            .symbolEffect(.bounce, value: chosen)
                        Text(tab.title).font(StudyTheme.body(11, .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(chosen ? StudyTheme.primary : StudyTheme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background { if chosen { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StudyTheme.primary.opacity(0.14)) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("study.dock.\(tab.rawValue)").accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(6)
        .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
        .frame(maxWidth: 520).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .background(StudyTheme.background)
    }
}

/// The bar above every tab: the streak, the experience, today's goal and the way back to the library.
struct StudyHUD: View {
    let model: StudyModeModel
    var body: some View {
        HStack(spacing: 16) {
            Button { StudyMode.shared.leave() } label: {
                Image(systemName: "books.vertical.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(StudyTheme.muted)
                    .frame(width: 40, height: 40).background(StudyTheme.surface, in: Circle())
                    .overlay { Circle().strokeBorder(StudyTheme.line, lineWidth: 2) }
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("Back to the Library")).accessibilityIdentifier("study.exit")
            StudyStat(symbol: "flame.fill", color: model.summary.streak > 0 ? StudyTheme.flame : StudyTheme.muted, value: String(model.summary.streak))
                .accessibilityLabel(L10n.text("Day streak") + " " + String(model.summary.streak)).accessibilityIdentifier("study.hud.streak")
            StudyStat(symbol: "bolt.fill", color: StudyTheme.gold, value: String(model.game.xp))
                .accessibilityLabel("XP " + String(model.game.xp)).accessibilityIdentifier("study.hud.xp")
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                StudyBar(value: model.game.goalProgress, color: model.game.goalMet ? StudyTheme.good : StudyTheme.gold, height: 12).frame(width: 74)
                Text("\(min(model.game.today, model.game.goal))/\(model.game.goal)").font(StudyTheme.body(14, .heavy)).foregroundStyle(StudyTheme.muted).monospacedDigit()
            }
            .accessibilityElement().accessibilityLabel(L10n.text("Today's goal") + " \(model.game.today)/\(model.game.goal)").accessibilityIdentifier("study.hud.goal")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(StudyTheme.background)
    }
}

// MARK: - Path

struct StudyPathView: View {
    let model: StudyModeModel
    var celebrating: String?
    let start: (StudyLessonPlan) -> Void
    @State private var selected: StudyPathLesson?
    /// True once the learner has closed the card, until they tap a stop or finish a lesson.
    @State private var dismissed = false
    private static let sway: [CGFloat] = [0, 58, 86, 58, 0, -58, -86, -58]

    var body: some View {
        let current = model.path.current(model.records)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.path.sections) { section in
                        banner(section).padding(.top, 18).padding(.bottom, 22)
                        if section.lessons.isEmpty {
                            Label(L10n.text("Opens in a coming update"), systemImage: "lock.fill")
                                .font(StudyTheme.body(14, .bold)).foregroundStyle(StudyTheme.muted).padding(.bottom, 8)
                        }
                        ForEach(Array(section.lessons.enumerated()), id: \.element.id) { index, lesson in
                            node(lesson, Color(studyHex: section.color), current: current?.id == lesson.id)
                                .offset(x: Self.sway[index % Self.sway.count])
                                .frame(maxWidth: .infinity)
                                // The guide stands beside the lesson the learner is on, on the side the path leaves free.
                                .overlay(alignment: Self.sway[index % Self.sway.count] > 0 ? .leading : .trailing) {
                                    if current?.id == lesson.id {
                                        StudyMascot(pose: .fullBody, size: 104).padding(.horizontal, 18)
                                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                                    }
                                }
                                .animation(.spring(duration: 0.5, bounce: 0.5), value: current?.id)
                                .padding(.bottom, 20).id(lesson.id)
                        }
                    }
                    Color.clear.frame(height: 190)
                }
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .onAppear { if let current { proxy.scrollTo(current.id, anchor: .center) } }
            .onChange(of: current?.id) { _, id in if let id, celebrating == nil { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            // A stop just finished is shown bursting first; then the path glides on to the next one.
            .onChange(of: celebrating) { _, done in
                if let done { withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(done, anchor: .center) } }
                else if let current { withAnimation(.spring(duration: 0.9, bounce: 0.15)) { proxy.scrollTo(current.id, anchor: .center) } }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { StudyHUD(model: model) }
        // The lesson the learner is on offers its start at once; any other stop does when tapped.
        .overlay(alignment: .bottom) {
            if let shown = selected ?? (dismissed || celebrating != nil ? nil : current) { card(shown).id(shown.id) }
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: selected)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: dismissed)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: celebrating)
        .onChange(of: current?.id) { selected = nil; dismissed = false }
    }

    private func banner(_ section: StudyPathSection) -> some View {
        let done = section.lessons.filter { model.records[$0.id] != nil }.count
        let color = Color(studyHex: section.color)
        return VStack(alignment: .leading, spacing: 6) {
            Text(section.title.resolved()).font(StudyTheme.title(22)).foregroundStyle(.white)
            Text(section.summary.resolved()).font(StudyTheme.body(14, .medium)).foregroundStyle(.white.opacity(0.9))
            if !section.lessons.isEmpty {
                HStack(spacing: 8) {
                    StudyBar(value: Double(done) / Double(section.lessons.count), color: .white, height: 10, track: .black.opacity(0.22))
                    Text("\(done)/\(section.lessons.count)").font(StudyTheme.body(13, .heavy)).foregroundStyle(.white).monospacedDigit()
                }.padding(.top, 4)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(section.lessons.isEmpty ? color.opacity(0.45) : color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(color.studyEdge().opacity(section.lessons.isEmpty ? 0.45 : 1)).offset(y: 5) }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine).accessibilityIdentifier("study.section.\(section.id)")
    }

    private func node(_ lesson: StudyPathLesson, _ color: Color, current: Bool) -> some View {
        let record = model.records[lesson.id]
        let open = record != nil || current
        let size: CGFloat = lesson.kind == .boss ? 92 : 76
        return VStack(spacing: 8) {
            if current {
                Text(L10n.text("Start")).font(StudyTheme.body(14, .heavy)).foregroundStyle(color)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(StudyTheme.surface, in: Capsule()).overlay { Capsule().strokeBorder(StudyTheme.line, lineWidth: 2) }
                    .phaseAnimator([0, -5]) { view, lift in view.offset(y: lift) } animation: { _ in .easeInOut(duration: 0.8) }
            }
            Button { StudySound.pick.play(); selected = lesson; dismissed = false } label: {
                Image(systemName: open ? (record != nil && lesson.kind != .boss ? "checkmark" : lesson.symbol) : "lock.fill")
                    .font(.system(size: size * 0.38, weight: .heavy))
                    .frame(width: size, height: size)
            }
            .buttonStyle(StudyPressStyle(color: open ? color : StudyTheme.sunken, ink: open ? .white : StudyTheme.muted, radius: size / 2, depth: 7))
            .disabled(!open)
            .background {
                // The stop the learner is on breathes, so that the eye lands on it.
                if current {
                    Circle().strokeBorder(color.opacity(0.35), lineWidth: 6).padding(-9)
                        .phaseAnimator([1.0, 1.12]) { view, scale in view.scaleEffect(scale).opacity(2.12 - scale) } animation: { _ in .easeInOut(duration: 0.9) }
                }
            }
            .phaseAnimator([1.0, 1.3, 1.0], trigger: celebrating == lesson.id) { view, scale in view.scaleEffect(scale) } animation: { _ in .spring(duration: 0.3, bounce: 0.6) }
            .overlay { if celebrating == lesson.id { StudyBurst(trigger: 1, count: 22, reach: 110, onAppear: true) } }
            .accessibilityLabel(lesson.title.resolved())
            .accessibilityValue(L10n.text(record != nil ? "Lesson Done" : current ? "Next" : "Locked"))
            .accessibilityIdentifier("study.node.\(lesson.id)")
            if let record { StudyStars(count: record.stars, size: 13) }
            Text(lesson.title.resolved()).font(StudyTheme.body(13, .bold)).foregroundStyle(open ? StudyTheme.ink : StudyTheme.muted)
        }
    }

    /// What a tapped lesson is, and the button that starts it.
    private func card(_ lesson: StudyPathLesson) -> some View {
        let record = model.records[lesson.id]
        let detail = switch lesson.kind {
        case .tags: L10n.text("New tags: %@", String(lesson.tags?.count ?? 0))
        case .concept: lesson.summary?.resolved() ?? L10n.text("An idea, explained from the start")
        case .boss: L10n.text("Put prompts together yourself")
        }
        return StudyCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lesson.title.resolved()).font(StudyTheme.title(21)).foregroundStyle(StudyTheme.ink)
                        Text(detail).font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                    }
                    Spacer()
                    Button { selected = nil; dismissed = true } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(StudyTheme.muted).padding(8) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Close"))
                }
                if let record { StudyStars(count: record.stars, size: 18) }
                StudyMainButton(title: L10n.text(record == nil ? "Start  +%@ XP" : "Play Again  +%@ XP", String(StudyGame.earned(mistakes: 1, bestCombo: 0))), symbol: "play.fill") {
                    StudySound.tap.play(); selected = nil; start(.lesson(lesson))
                }.accessibilityIdentifier("study.startLesson")
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct StudyStars: View {
    let count: Int
    var size: CGFloat = 16
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: "star.fill").font(.system(size: size, weight: .bold)).foregroundStyle(index < count ? StudyTheme.gold : StudyTheme.line)
            }
        }.accessibilityElement().accessibilityLabel(L10n.text("Stars: %@", String(count)))
    }
}

// MARK: - Practice

struct StudyPracticeView: View {
    let model: StudyModeModel
    let start: (StudyLessonPlan) -> Void
    let startSpeed: () -> Void
    private var met: Int { StudySpeedRound.met(model.progress, curriculum: model.curriculum).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StudyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            StudyMascot(pose: model.summary.due > 0 ? .read : .cheer, size: 84)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("Today's Review")).font(StudyTheme.title(21)).foregroundStyle(StudyTheme.ink)
                                Text(model.summary.due > 0 ? L10n.text("Tags due again: %@", String(model.summary.due)) : L10n.text("Nothing is due. Tags come back here just before you would forget them."))
                                    .font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                            }
                        }
                        StudyMainButton(title: L10n.text("Review"), color: StudyTheme.good, symbol: "arrow.triangle.2.circlepath") { StudySound.tap.play(); start(.review) }
                            .disabled(model.summary.due == 0).accessibilityIdentifier("study.review")
                    }
                }
                game("target", StudyTheme.bad, "Weak Spots", model.weak > 0 ? L10n.text("Tags you have missed: %@. Ask them again.", String(model.weak)) : L10n.text("Tags you miss in lessons gather here."),
                     enabled: model.weak > 0, id: "study.weak") { start(.weak) }
                game("timer", StudyTheme.flame, "Speed Round", met >= StudySpeedRound.needed ? L10n.text("As many as you can in a minute.") : L10n.text("Opens once you have learned 4 tags."),
                     enabled: met >= StudySpeedRound.needed, id: "study.speed", action: startSpeed)
            }
            .padding(.horizontal, 16).padding(.top, 8).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StudyHUD(model: model) }
    }

    private func game(_ symbol: String, _ color: Color, _ title: String, _ detail: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button { StudySound.tap.play(); action() } label: {
            HStack(spacing: 14) {
                Image(systemName: enabled ? symbol : "lock.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(enabled ? .white : StudyTheme.muted)
                    .frame(width: 52, height: 52).background(enabled ? color : StudyTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(title)).font(StudyTheme.body(18, .heavy)).foregroundStyle(StudyTheme.ink)
                    Text(detail).font(StudyTheme.body(13, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if enabled { Image(systemName: "play.fill").font(.system(size: 15, weight: .heavy)).foregroundStyle(color) }
            }.padding(16)
        }
        .buttonStyle(StudyPressStyle(radius: 20, outlined: true)).disabled(!enabled)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Collection

struct StudyDexView: View {
    let model: StudyModeModel
    let source: any BooruProviding
    @State private var opened: StudyTag?
    private var met: [StudyTag] { model.curriculum.tags.filter { model.progress[$0.name].map { !$0.isNew } == true } }

    var body: some View {
        let met = met
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Tags collected: %@ of %@", String(met.count), String(model.summary.total))).font(StudyTheme.title(21)).foregroundStyle(StudyTheme.ink)
                    StudyBar(value: model.summary.total == 0 ? 0 : Double(met.count) / Double(model.summary.total), color: StudyTheme.primary)
                }
                if met.isEmpty {
                    VStack(spacing: 12) {
                        StudyMascot(pose: .think, size: 110)
                        Text(L10n.text("Tags you learn on the path are kept here.")).font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 12) {
                    ForEach(met) { tag in
                        let progress = model.progress[tag.name]
                        Button { opened = tag } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tag.english).font(StudyTheme.body(16, .heavy)).lineLimit(1).minimumScaleFactor(0.7)
                                if L10n.language != "en" { Text(tag.title()).font(StudyTheme.body(13, .medium)).foregroundStyle(StudyTheme.muted).lineLimit(1) }
                                HStack(spacing: 3) {
                                    ForEach(0..<StudyProgress.learnedStep, id: \.self) { index in
                                        Capsule().fill(index < min(progress?.step ?? 0, StudyProgress.learnedStep) ? (progress?.isLearned == true ? StudyTheme.good : StudyTheme.gold) : StudyTheme.sunken)
                                            .frame(height: 6)
                                    }
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(StudyPressStyle(radius: 16, depth: 4, outlined: true))
                        .accessibilityIdentifier("study.dex.\(tag.name)")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StudyHUD(model: model) }
        .sheet(item: $opened) { tag in
            NavigationStack {
                StudyTagView(name: tag.name, source: source)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { opened = nil } } }
            }
        }
    }
}

// MARK: - Studio

struct StudyLabView: View {
    private enum Tool: String, Identifiable { case guide, generator, key; var id: String { rawValue } }
    let model: StudyModeModel
    let start: (StudyLessonPlan) -> Void
    /// Called when a tool closes: a picture generated in it may have earned a badge.
    var closed: () -> Void = {}
    @State private var opened: Tool?
    @State private var generation = GenerationStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                connection
                tool(.generator, "wand.and.stars", "Generate a Picture", "Try a prompt with your own Civitai API key.")
                tool(.guide, "text.book.closed.fill", "Writing Prompts", "Emphasis, quality tags and what each model recommends.")
            }
            .padding(.horizontal, 16).padding(.top, 8).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StudyHUD(model: model) }
        .sheet(item: $opened, onDismiss: closed) { tool in
            NavigationStack {
                switch tool {
                case .key: GeneratorAccountView()
                case .guide: StudyGuideView().toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { opened = nil } } }
                case .generator: GeneratorView().toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { opened = nil } } }
                }
            }
        }
    }

    /// Generating needs an API key. Until one is saved, this card says so and leads to the lessons that explain it.
    private var connection: some View {
        let connected = generation.hasKey
        let lesson = model.path.lessons.first { $0.id == "api-what" }
        return StudyCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    StudyMascot(pose: connected ? .cheer : .wave, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L10n.text(connected ? "API Key Connected" : "Connect an API Key First"), systemImage: connected ? "checkmark.seal.fill" : "key.fill")
                            .font(StudyTheme.title(19)).foregroundStyle(connected ? StudyTheme.good : StudyTheme.ink)
                        Text(L10n.text(connected ? "You can generate pictures. Each one is paid for with Buzz from your Civitai account." : "Pictures are drawn on Civitai's servers, so the Studio needs your own Civitai API key."))
                            .font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                    }
                }
                if !connected {
                    if let lesson {
                        StudyMainButton(title: L10n.text("Learn What an API Key Is"), symbol: "graduationcap.fill") { StudySound.tap.play(); start(.lesson(lesson)) }
                            .accessibilityIdentifier("study.lab.learn")
                    }
                    StudyMainButton(title: L10n.text("Enter the API Key"), color: StudyTheme.gold, symbol: "key.fill") { StudySound.tap.play(); opened = .key }
                        .accessibilityIdentifier("study.lab.key")
                }
            }
        }
    }

    private func tool(_ tool: Tool, _ symbol: String, _ title: String, _ detail: String) -> some View {
        Button { StudySound.tap.play(); opened = tool } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(StudyTheme.primary)
                    .frame(width: 52, height: 52).background(StudyTheme.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(title)).font(StudyTheme.body(18, .heavy))
                    Text(L10n.text(detail)).font(StudyTheme.body(13, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .heavy)).foregroundStyle(StudyTheme.muted)
            }.padding(16)
        }
        .buttonStyle(StudyPressStyle(radius: 20, outlined: true))
        .accessibilityIdentifier("study.lab.\(tool.rawValue)")
    }
}

// MARK: - Me

struct StudyMeView: View {
    @Bindable var model: StudyModeModel
    let chooseServer: () -> Void
    var openAwards: () -> Void = {}
    @Environment(BooruStore.self) private var store
    @State private var mode = StudyMode.shared
    @State private var confirmingReset = false
    @State private var sound = StudySound.isOn

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StudyCard {
                    HStack(spacing: 16) {
                        StudyMascot(pose: .closeUp, size: 92)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Level %@", String(model.game.level))).font(StudyTheme.title(24)).foregroundStyle(StudyTheme.ink)
                            StudyBar(value: model.game.levelProgress, color: StudyTheme.gold)
                            Text("\(model.game.xp % StudyGame.levelSize) / \(StudyGame.levelSize) XP").font(StudyTheme.body(13, .bold)).foregroundStyle(StudyTheme.muted).monospacedDigit()
                        }
                    }
                }
                StudyAwardsCard(model: model, open: openAwards)
                HStack(spacing: 10) {
                    tile("flame.fill", StudyTheme.flame, String(model.summary.streak), L10n.text("Day streak"))
                    tile("checkmark.seal.fill", StudyTheme.good, String(model.summary.learned), L10n.text("Learned"))
                    tile("bolt.fill", StudyTheme.gold, String(model.game.xp), "XP")
                }
                StudyCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("Today's goal")).font(StudyTheme.body(17, .heavy)).foregroundStyle(StudyTheme.ink)
                        HStack(spacing: 8) {
                            ForEach(StudyGame.goals, id: \.self) { goal in
                                Button { model.goal = goal; model.reload(store) } label: {
                                    Text("\(goal) XP").font(StudyTheme.body(15, .heavy)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                }
                                .buttonStyle(StudyPressStyle(color: StudyTheme.gold, radius: 14, depth: 4, outlined: model.goal != goal))
                                .accessibilityAddTraits(model.goal == goal ? .isSelected : [])
                            }
                        }
                    }
                }
                StudyCard(padding: 6) {
                    VStack(spacing: 0) {
                        Button(action: chooseServer) {
                            row("photo.stack", L10n.text("Pictures From"), model.server.name)
                        }.buttonStyle(.plain).accessibilityIdentifier("study.server")
                        Divider().overlay(StudyTheme.line).padding(.horizontal, 12)
                        Toggle(isOn: $mode.startsActive) {
                            Label(L10n.text("Open in Learning Mode"), systemImage: "graduationcap.fill").font(StudyTheme.body(16, .bold)).foregroundStyle(StudyTheme.ink)
                        }.tint(StudyTheme.primary).padding(.horizontal, 12).padding(.vertical, 10).accessibilityIdentifier("study.startInMode")
                        Divider().overlay(StudyTheme.line).padding(.horizontal, 12)
                        Toggle(isOn: $sound) {
                            Label(L10n.text("Sound Effects"), systemImage: "speaker.wave.2.fill").font(StudyTheme.body(16, .bold)).foregroundStyle(StudyTheme.ink)
                        }.tint(StudyTheme.primary).padding(.horizontal, 12).padding(.vertical, 10).accessibilityIdentifier("study.sound")
                            .onChange(of: sound) { _, on in StudySound.isOn = on; if on { StudySound.right.play() } }
                    }
                }
                StudyMainButton(title: L10n.text("Back to the Library"), color: StudyTheme.muted, symbol: "books.vertical.fill") { mode.leave() }
                    .accessibilityIdentifier("study.leave")
                Button(L10n.text("Reset Study Progress"), role: .destructive) { confirmingReset = true }
                    .font(StudyTheme.body(14, .bold)).padding(.top, 4).disabled(model.game.xp == 0 && model.summary.started == 0)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { StudyHUD(model: model) }
        .confirmationDialog(L10n.text("Reset study progress?"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L10n.text("Reset"), role: .destructive) { try? store.studyStore.reset(); model.reload(store) }
        } message: { Text(L10n.text("Every tag goes back to not started. This cannot be undone.")) }
    }

    private func tile(_ symbol: String, _ color: Color, _ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
            Text(value).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink).monospacedDigit()
            Text(title).font(StudyTheme.body(12, .bold)).foregroundStyle(StudyTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }

    private func row(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(StudyTheme.body(16, .bold)).foregroundStyle(StudyTheme.ink)
            Spacer()
            Text(value).font(StudyTheme.body(15, .semibold)).foregroundStyle(StudyTheme.muted)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .heavy)).foregroundStyle(StudyTheme.muted)
        }.padding(.horizontal, 12).padding(.vertical, 14).contentShape(Rectangle())
    }
}

/// Chooses the one server learning mode shows pictures from.
struct StudyServerPicker: View {
    let model: StudyModeModel
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let suggested = StudyServer.recommended(StudyServer.choices(store))
        // The suggested server, which is Danbooru when it is there, leads the list.
        let servers = [suggested] + StudyServer.choices(store).filter { $0.id != suggested.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("Where should the pictures come from?")).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
                Text(L10n.text("Lessons show real pictures from one server. You can change it later under Me.")).font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted)
                ForEach(servers) { server in
                    Button { model.choose(server, store: store); dismiss() } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).font(StudyTheme.body(17, .heavy))
                                Text(server.baseURL.host ?? "").font(StudyTheme.body(12, .medium)).foregroundStyle(StudyTheme.muted)
                            }
                            Spacer()
                            if server.id == suggested.id {
                                Text(L10n.text("Suggested")).font(StudyTheme.body(12, .heavy)).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5).background(StudyTheme.good, in: Capsule())
                            }
                            if server.id == model.server.id, !model.needsServer { Image(systemName: "checkmark.circle.fill").foregroundStyle(StudyTheme.primary) }
                        }.padding(16)
                    }
                    .buttonStyle(StudyPressStyle(radius: 18, outlined: true))
                    .accessibilityIdentifier("study.serverChoice.\(server.name)")
                }
            }.padding(20)
        }
        .background(StudyTheme.background)
    }
}

/// The setting that opens the app straight into learning mode, shown beside Safe Mode.
struct StudyModeSettings: View {
    @State private var mode = StudyMode.shared
    var body: some View {
        Section {
            Toggle(isOn: $mode.startsActive) {
                SettingsHelpLabel("Open in Learning Mode", help: "Turning this on opens the app straight into learning mode, where tags for prompting image AI are learned step by step. The library stays one tap away.")
            }.accessibilityIdentifier("settings.startInStudyMode")
            Button(L10n.text("Enter Learning Mode")) { mode.enter() }.accessibilityIdentifier("settings.enterStudyMode")
        } header: { Text(L10n.text("Learning Mode")) }
    }
}
