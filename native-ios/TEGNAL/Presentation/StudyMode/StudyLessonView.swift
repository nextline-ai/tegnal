import SwiftUI

/// A lesson played from its first step to its results.
struct StudyPlayView: View {
    @State var session: StudyLessonSession
    /// Where the play goes when it ends or is closed, in place of dismissing its cover: the welcome plays the placement test in place.
    var leave: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismissCover
    private func dismiss() { if let leave { leave() } else { dismissCover() } }
    @State private var confirmingQuit = false
    /// Counts right answers, to set off the sparks and the bounce of the bar.
    @State private var cheers = 0
    @State private var misses = 0
    @State private var praise = ""
    @State private var banner: Int?
    @State private var viewing: StudyViewing?
    @Environment(BooruStore.self) private var store
    private var feedback: Bool? { if case .feedback(let right) = session.phase { return right }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            if session.phase != .finished { bar }
            Group {
                switch session.phase {
                case .loading:
                    VStack(spacing: 16) {
                        StudyMascot(pose: .think, size: 130)
                        Text(L10n.text("Getting the pictures ready…")).font(StudyTheme.body(17, .bold)).foregroundStyle(StudyTheme.muted)
                        ProgressView()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished:
                    if session.isPlacement { StudyPlacementResult(session: session) { dismiss() } }
                    else { StudyLessonResult(session: session) { dismiss() } }
                default:
                    if let step = session.step {
                        content(step).id(step.id)
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
            }
            .animation(.snappy(duration: 0.28), value: session.step?.id)
        }
        .background(StudyTheme.background.ignoresSafeArea())
        // A run of right answers is called out over the lesson.
        .overlay(alignment: .top) {
            if let banner { StudyComboBanner(combo: banner).padding(.top, 58).transition(.scale(scale: 0.3).combined(with: .opacity)).id(banner) }
        }
        .animation(.spring(duration: 0.4, bounce: 0.5), value: banner)
        .tint(StudyTheme.primary)
        .environment(\.studyOpenPicture, open)
        .appFullScreenCover(item: $viewing) { viewing in
            BooruPostView(post: viewing.post, posts: viewing.posts, server: session.server, source: session.source)
        }
        .task { await session.start() }
        .sensoryFeedback(trigger: feedback) { _, right in right == true ? .success : right == false ? .error : nil }
        .onChange(of: session.phase) { _, phase in react(phase) }
        .confirmationDialog(L10n.text("Leave this lesson?"), isPresented: $confirmingQuit, titleVisibility: .visible) {
            Button(L10n.text("Leave"), role: .destructive) { dismiss() }
        } message: { Text(L10n.text("What you did in this lesson will not be kept.")) }
    }

    /// Opens a picture in the library's own image viewer, where it can be zoomed, translated, saved and filed.
    private func open(_ post: BooruPost, _ among: [BooruPost]) {
        // What is saved in the viewer is filed under the picture's server. A server only learning mode knew
        // (Safebooru, for a learner with no server of their own) joins the library, so that the save is found there.
        if !store.servers.contains(where: { $0.id == session.server.id }), (try? store.saveServer(session.server)) != nil {
            ReaderPreferences.booruDefaults.set(session.server.id, forKey: StudyServer.key)
        }
        viewing = StudyViewing(post: post, posts: among.contains(post) ? among : [post])
    }

    /// Answers what just happened with a sound, a word and a movement.
    private func react(_ phase: StudyLessonSession.Phase) {
        guard case .feedback(let right) = phase else { return }
        praise = StudyPraise.line(right: right, combo: session.combo, seed: session.index &* 7 &+ session.asked)
        if right {
            cheers += 1
            if StudyPraise.runs.contains(session.combo) {
                StudySound.combo.play()
                let combo = session.combo
                banner = combo
                Task { try? await Task.sleep(for: .seconds(1.5)); if banner == combo { banner = nil } }
            } else { StudySound.right.play() }
        } else {
            misses += 1
            StudySound.wrong.play()
        }
    }

    private var bar: some View {
        HStack(spacing: 14) {
            // Nothing of the placement test is kept until it ends, so it closes without asking.
            Button { if session.index == 0 || session.isPlacement { dismiss() } else { confirmingQuit = true } } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(StudyTheme.muted).frame(width: 36, height: 36)
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("study.close")
            StudyBar(value: session.progress).accessibilityIdentifier("study.progress")
                .phaseAnimator([1.0, 1.45, 1.0], trigger: cheers) { view, scale in view.scaleEffect(x: 1, y: scale) } animation: { _ in .spring(duration: 0.22, bounce: 0.5) }
            if session.combo >= 2 {
                StudyStat(symbol: "flame.fill", color: StudyTheme.flame, value: String(session.combo))
                    .transition(.scale.combined(with: .opacity)).accessibilityLabel(L10n.text("Right in a row: %@", String(session.combo)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .animation(.spring(duration: 0.3, bounce: 0.4), value: session.combo)
    }

    @ViewBuilder private func content(_ step: StudyStep) -> some View {
        let revealed = feedback != nil
        Group {
            switch step.kind {
            case .card(let card): StudyCardStep(card: card) { session.proceed() }
            case .teach(let tag, let posts): StudyTeachStep(tag: tag, posts: posts, server: session.server) { session.proceed() }
            case .quiz(let question): StudyQuizStep(question: question, server: session.server, revealed: revealed) { session.answer($0, tag: question.tag.name) }
            case .ask(let ask): StudyAskStep(ask: ask, revealed: revealed, unsure: session.isPlacement ? { session.answer(false) } : nil) { session.answer($0) }
            case .match(let tags): StudyMatchStep(tags: tags, revealed: revealed) { session.answer($0) }
            case .build(let build): StudyBuildStep(build: build, picture: session.builtPictures[build], server: session.server, revealed: revealed) { session.answer($0) }
            case .order(let order): StudyOrderStep(order: order, revealed: revealed) { session.answer($0) }
            case .sort(let sort): StudySortStep(sort: sort, revealed: revealed) { session.answer($0) }
            case .odd(let post, let choices, let answer):
                StudyOddStep(post: post, choices: choices, answer: answer, server: session.server, revealed: revealed) { session.answer($0, tag: choices[answer].name) }
            case .spell(let tag, let post): StudySpellStep(tag: tag, post: post, server: session.server, revealed: revealed) { session.answer($0, tag: tag.name) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let right = feedback { verdict(right, step).transition(.move(edge: .bottom)) }
        }
        .animation(.spring(duration: 0.38, bounce: 0.3), value: revealed)
    }

    /// What was right, said once an answer is in, and the way on. The guide is glad or sorry with the learner.
    private func verdict(_ right: Bool, _ step: StudyStep) -> some View {
        let color = right ? StudyTheme.good : StudyTheme.bad
        let detail: String? = switch step.kind {
        case .quiz(let question): "`\(question.tag.english)` · " + question.tag.note.resolved()
        case .ask(let ask): ask.why.resolved()
        case .build(let build): "`\(StudyPrompt.text(build.answer, style: .natural))`"
        case .order(let order): order.why.resolved()
        case .sort(let sort): sort.why.resolved()
        case .odd(_, let choices, let answer): L10n.text("This picture does not carry `%@`.", choices[answer].english)
        case .spell(let tag, _): "`\(tag.english)` · " + tag.note.resolved()
        default: nil
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(praise.isEmpty ? L10n.text(right ? "That's right!" : "Not quite") : praise, systemImage: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(StudyTheme.title(22)).foregroundStyle(color)
                        .modifier(StudyShake(travel: right ? 0 : CGFloat(misses))).animation(.linear(duration: 0.4), value: misses)
                        .accessibilityIdentifier("study.verdict").accessibilityValue(right ? "right" : "wrong")
                    if let detail { StudyRichText(source: detail, size: 15).fixedSize(horizontal: false, vertical: true) }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                StudyVerdictGuide(right: right)
            }
            StudyMainButton(title: L10n.text("Continue"), color: color) { StudySound.tap.play(); session.next() }.accessibilityIdentifier("study.next")
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            StudyTheme.surface.overlay(color.opacity(0.16)).overlay(alignment: .top) { Rectangle().fill(color.opacity(0.5)).frame(height: 2) }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The guide beside a verdict: it jumps in cheering for a right answer and droops for a wrong one.
private struct StudyVerdictGuide: View {
    let right: Bool
    @State private var shown = false
    var body: some View {
        StudyMascot(pose: right ? .cheer : .sad, size: 112)
            .padding(.top, -40)
            .rotationEffect(.degrees(shown ? 0 : right ? -25 : 12), anchor: .bottom)
            .studyPop(shown, delay: 0.08, from: 0.2)
            .overlay { if right { StudyBurst(trigger: shown ? 1 : 0, count: 18, reach: 70) } }
            .onAppear { shown = true }
    }
}

// MARK: - Shared pieces

/// A picture opened in the image viewer, with the pictures beside it to page through.
private struct StudyViewing: Identifiable {
    let post: BooruPost
    let posts: [BooruPost]
    var id: String { post.id }
}

private struct StudyOpenPictureKey: EnvironmentKey {
    static let defaultValue: (BooruPost, [BooruPost]) -> Void = { _, _ in }
}
extension EnvironmentValues {
    /// Opens a lesson's picture in the image viewer.
    var studyOpenPicture: (BooruPost, [BooruPost]) -> Void {
        get { self[StudyOpenPictureKey.self] }
        set { self[StudyOpenPictureKey.self] = newValue }
    }
}

/// Makes a lesson's picture open in the image viewer: by a tap anywhere on it, or, where a tap already chooses
/// the picture as an answer, by the small button in its corner.
private struct StudyZoom: ViewModifier {
    let post: BooruPost
    var among: [BooruPost] = []
    var cornerOnly = false
    @Environment(\.studyOpenPicture) private var open

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { if !cornerOnly { open(post, among) } }
            .overlay(alignment: .topTrailing) {
                Button { open(post, among) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .padding(7).background(.black.opacity(0.5), in: Circle()).padding(8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Open in the Viewer")).accessibilityIdentifier("study.zoom")
            }
    }
}
extension View {
    fileprivate func studyZoom(_ post: BooruPost, among: [BooruPost] = [], cornerOnly: Bool = false) -> some View {
        modifier(StudyZoom(post: post, among: among, cornerOnly: cornerOnly))
    }
}

/// A step's scrolling body with its button pinned below.
private struct StudyStepFrame<Content: View>: View {
    let button: String
    var enabled = true
    var hidden = false
    /// A quieter way on above the main button, such as "I Don't Know" in the placement test.
    var secondary: (title: String, action: () -> Void)? = nil
    let action: () -> Void
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !hidden {
                VStack(spacing: 6) {
                    if let secondary {
                        Button { StudySound.tap.play(); secondary.action() } label: {
                            Text(L10n.text(secondary.title)).font(StudyTheme.body(16, .heavy)).foregroundStyle(StudyTheme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("study.unsure")
                    }
                    StudyMainButton(title: L10n.text(button), action: action).disabled(!enabled).accessibilityIdentifier("study.check")
                }
                .frame(maxWidth: 600).padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity)
                .background(StudyTheme.background)
            }
        }
    }
}

private enum StudyChoiceState { case idle, picked, right, wrong, faded }

/// An answer that can be picked, and that shows afterwards whether it was right.
private struct StudyChoiceStyle: ButtonStyle {
    let state: StudyChoiceState
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let color: Color = switch state {
        case .picked: StudyTheme.primary
        case .right: StudyTheme.good
        case .wrong: StudyTheme.bad
        default: StudyTheme.line
        }
        let down = configuration.isPressed
        return configuration.label
            .foregroundStyle(state == .idle || state == .faded ? StudyTheme.ink : scheme == .dark ? color : color.studyEdge())
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StudyTheme.surface)
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(state == .idle || state == .faded ? .clear : color.opacity(0.14)) }
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color, lineWidth: 2) }
            }
            .offset(y: down ? 4 : 0)
            .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color).offset(y: 4) }
            .padding(.bottom, 4)
            .opacity(state == .faded ? 0.5 : 1)
            // A picked answer leans forward, the right one jumps and a wrong one shakes its head.
            .scaleEffect(state == .picked ? 1.03 : state == .right ? 1.05 : 1)
            .modifier(StudyShake(travel: state == .wrong ? 1 : 0))
            .animation(.spring(duration: 0.35, bounce: 0.6), value: state)
            .animation(.easeOut(duration: 0.08), value: down)
    }
}

private func choiceState(_ index: Int, picked: Int?, answer: Int, revealed: Bool) -> StudyChoiceState {
    if revealed { return index == answer ? .right : index == picked ? .wrong : .faded }
    return index == picked ? .picked : .idle
}

/// Lays chips out in lines, wrapping at the edge.
private struct StudyFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { arrange(proposal.width ?? .infinity, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

// MARK: - Steps

/// The tail of a speech bubble: a triangle open along its foot.
private struct StudyTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct StudyCardStep: View {
    private enum Opened: String, Identifiable { case key, generator; var id: String { rawValue } }
    let card: StudyPathLesson.Card
    let proceed: () -> Void
    @State private var shown = false
    @State private var opened: Opened?
    @State private var generation = GenerationStore.shared
    @Environment(\.openURL) private var openURL
    private var pose: StudyMascot.Pose { StudyMascot.Pose(rawValue: card.pose ?? "") ?? .read }

    var body: some View {
        StudyStepFrame(button: "Continue", action: { StudySound.tap.play(); proceed() }) {
            // The guide tells it: its picture, then what it says in a bubble.
            HStack(alignment: .bottom, spacing: 12) {
                StudyMascot(pose: pose, size: 124).studyPop(shown, from: 0.3).padding(.bottom, pose.isBust ? -30 : -4)
                if let symbol = card.symbol {
                    Image(systemName: symbol).font(.system(size: 42, weight: .bold)).foregroundStyle(StudyTheme.primary)
                        .symbolEffect(.bounce, value: shown)
                        .frame(maxWidth: .infinity, minHeight: 108).background(StudyTheme.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .studyPop(shown, delay: 0.12, from: 0.6)
                }
            }.padding(.top, 8)
            StudyCard(padding: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.title.resolved()).font(StudyTheme.title(25)).foregroundStyle(StudyTheme.ink).accessibilityIdentifier("study.cardTitle")
                    StudyRichText(source: card.body.resolved(), size: 18)
                    if let code = card.code { StudyCodeBox(code: code) }
                }
            }
            // The bubble's tail points up at the guide. It lies under the bubble, which covers its foot.
            .background(alignment: .topLeading) {
                if !pose.isBust {
                    StudyTail().fill(StudyTheme.surface).overlay { StudyTail().stroke(StudyTheme.line, style: StrokeStyle(lineWidth: 2, lineJoin: .round)) }
                        .frame(width: 24, height: 16).offset(x: 50, y: -13)
                }
            }
            .studyRise(shown, delay: 0.1)
            if let action = card.action { button(action).studyRise(shown, delay: 0.25) }
        }
        .onAppear { shown = true }
        .appSheet(item: $opened) { opened in
            NavigationStack {
                if opened == .key { GeneratorAccountView() } else {
                    GeneratorView(prompt: card.code ?? "")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { self.opened = nil } } }
                }
            }
        }
    }

    /// Something to do from the card itself, so that what was just read can be done at once.
    @ViewBuilder private func button(_ action: String) -> some View {
        let connected = generation.hasKey
        Button {
            StudySound.tap.play()
            switch action {
            case "civitai": if let url = URL(string: "https://civitai.com/user/account") { openURL(url) }
            case "key": opened = .key
            default: opened = .generator
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: action == "civitai" ? "safari.fill" : action == "key" ? (connected ? "checkmark.seal.fill" : "key.fill") : "wand.and.stars")
                Text(L10n.text(action == "civitai" ? "Open Civitai Account Settings" : action == "key" ? (connected ? "API Key Connected" : "Enter the API Key") : "Open the Generator"))
            }.font(StudyTheme.body(17, .heavy)).frame(maxWidth: .infinity).padding(.vertical, 13)
        }
        .buttonStyle(StudyPressStyle(color: action == "key" && connected ? StudyTheme.good : StudyTheme.gold, ink: .white))
        .accessibilityIdentifier("study.cardAction")
    }
}

private struct StudyTeachStep: View {
    let tag: StudyTag
    let posts: [BooruPost]
    let server: BooruServer
    let proceed: () -> Void
    @State private var shown = false
    var body: some View {
        StudyStepFrame(button: "Got It", action: { StudySound.tap.play(); proceed() }) {
            Label(L10n.text("New Tag"), systemImage: "sparkles").font(StudyTheme.body(13, .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6).background(StudyTheme.primary, in: Capsule())
                .studyPop(shown)
            Text(tag.english).font(StudyTheme.title(36)).foregroundStyle(StudyTheme.ink).accessibilityIdentifier("study.newTag")
                .studyPop(shown, delay: 0.1, from: 0.5)
                .overlay(alignment: .leading) { StudyBurst(trigger: shown ? 1 : 0, count: 14, reach: 80).offset(x: -40) }
            StudyCard {
                VStack(alignment: .leading, spacing: 6) {
                    if L10n.language != "en" { Text(tag.title()).font(StudyTheme.body(18, .heavy)).foregroundStyle(StudyTheme.primary) }
                    Text(tag.note.resolved()).font(StudyTheme.body(17, .medium)).foregroundStyle(StudyTheme.ink).lineSpacing(3)
                }
            }
            .studyRise(shown, delay: 0.18)
            if !posts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                            StudyPicture(post: post, server: server)
                                .aspectRatio(min(2.2, max(0.5, CGFloat(max(post.width, 1)) / CGFloat(max(post.height, 1)))), contentMode: .fit)
                                .frame(height: 190)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .studyZoom(post, among: posts)
                                .rotationEffect(.degrees(shown ? 0 : index % 2 == 0 ? -6 : 6))
                                .studyRise(shown, delay: 0.28 + Double(index) * 0.09, by: 40)
                        }
                    }
                }
                .scrollClipDisabled()
                Text(L10n.text("Pictures that carry this tag")).font(StudyTheme.body(13, .bold)).foregroundStyle(StudyTheme.muted)
            }
        }
        .onAppear { shown = true; StudySound.match.play() }
    }
}

private struct StudyQuizStep: View {
    let question: StudyQuestion
    let server: BooruServer
    let revealed: Bool
    let answer: (Bool) -> Void
    @State private var picked: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        StudyStepFrame(button: "Check", enabled: picked != nil, hidden: revealed, action: { if let picked { answer(picked == question.answer) } }) {
            switch question.kind {
            case .pictureToTag:
                prompt("Which tag does this picture carry?")
                if let post = question.posts.first {
                    StudyPicture(post: post, server: server)
                        .aspectRatio(min(1.6, max(0.7, CGFloat(max(post.width, 1)) / CGFloat(max(post.height, 1)))), contentMode: .fit)
                        .frame(maxWidth: .infinity).frame(maxHeight: sizeClass == .regular ? 480 : 300)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).accessibilityIdentifier("study.picture")
                        .studyZoom(post)
                }
                words
            case .meaningToTag:
                prompt("Which tag means this?")
                StudyCard { Text(question.tag.note.resolved()).font(StudyTheme.body(19, .semibold)).foregroundStyle(StudyTheme.ink).lineSpacing(3) }
                words
            case .tagToPicture:
                prompt("Which picture carries this tag?")
                Text(question.tag.english).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.primary).frame(maxWidth: .infinity)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(Array(question.posts.enumerated()), id: \.element.id) { index, post in
                        Button { picked = index; StudySound.pick.play() } label: {
                            StudyPicture(post: post, server: server, fills: true)
                                .frame(maxWidth: .infinity).aspectRatio(0.82, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(5)
                        }
                        .buttonStyle(StudyChoiceStyle(state: choiceState(index, picked: picked, answer: question.answer, revealed: revealed)))
                        .allowsHitTesting(!revealed)
                        .accessibilityLabel(L10n.text("Picture %@", String(index + 1))).accessibilityIdentifier("study.choice.\(index)")
                        .studyZoom(post, among: question.posts, cornerOnly: true)
                    }
                }
            }
        }
    }

    private func prompt(_ text: String) -> some View {
        Text(L10n.text(text)).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
    }

    /// Tags are offered in the words a prompt is written in, never translated. Short ones share a line.
    private var words: some View {
        let limit = typeSize.isAccessibilitySize ? 0 : sizeClass == .regular ? 22 : 13
        return VStack(spacing: 12) {
            ForEach(StudyQuestion.rows(question.choices.map(\.english.count), limit: limit), id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { index in
                        Button { picked = index; StudySound.pick.play() } label: {
                            Text(question.choices[index].english).font(StudyTheme.body(19, .heavy)).lineLimit(2).minimumScaleFactor(0.75)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 56).padding(.horizontal, 10)
                        }
                        .buttonStyle(StudyChoiceStyle(state: choiceState(index, picked: picked, answer: question.answer, revealed: revealed)))
                        .allowsHitTesting(!revealed).accessibilityIdentifier("study.choice.\(index)")
                    }
                }
            }
        }
    }
}

private struct StudyAskStep: View {
    let ask: StudyPathLesson.Ask
    let revealed: Bool
    /// Offered in the placement test: answers as missed, without a guess.
    var unsure: (() -> Void)? = nil
    let answer: (Bool) -> Void
    @State private var picked: Int?
    var body: some View {
        StudyStepFrame(button: "Check", enabled: picked != nil, hidden: revealed, secondary: unsure.map { ("I Don't Know", $0) },
                       action: { if let picked { answer(picked == ask.answer) } }) {
            HStack(alignment: .top, spacing: 12) {
                StudyMascot(pose: .think, size: 76)
                StudyCard(padding: 14) { StudyRichText(source: ask.question.resolved(), size: 19) }
            }.padding(.top, 8)
            VStack(spacing: 12) {
                ForEach(Array(ask.choices.enumerated()), id: \.offset) { index, choice in
                    Button { picked = index; StudySound.pick.play() } label: {
                        Text(choice.resolved()).font(ask.code == true ? StudyTheme.code : StudyTheme.body(18, .bold))
                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(StudyChoiceStyle(state: choiceState(index, picked: picked, answer: ask.answer, revealed: revealed)))
                    .allowsHitTesting(!revealed).accessibilityIdentifier("study.choice.\(index)")
                }
            }
        }
    }
}

/// Tags on one side and what they mean on the other, paired by tapping one of each.
private struct StudyMatchStep: View {
    let tags: [StudyTag]
    let revealed: Bool
    let answer: (Bool) -> Void
    @State private var left: [StudyTag] = []
    @State private var right: [StudyTag] = []
    @State private var chosen: String?
    @State private var matched: Set<String> = []
    @State private var missed: String?
    @State private var slipped = false

    private func meaning(_ tag: StudyTag) -> String { L10n.language == "en" ? tag.note.resolved() : tag.title() }

    var body: some View {
        StudyStepFrame(button: "Check", hidden: true, action: {}) {
            Text(L10n.text("Pair each tag with what it means")).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(left) { tag in
                        cell(tag.english, state: matched.contains(tag.name) ? .right : chosen == tag.name ? .picked : .idle, id: "study.match.tag.\(tag.name)") {
                            chosen = chosen == tag.name ? nil : tag.name
                            StudySound.pick.play()
                        }
                    }
                }
                VStack(spacing: 12) {
                    ForEach(right) { tag in
                        cell(meaning(tag), state: matched.contains(tag.name) ? .right : missed == tag.name ? .wrong : .idle, id: "study.match.meaning.\(tag.name)") { pair(tag) }
                    }
                }
            }
        }
        .onAppear {
            guard left.isEmpty else { return }
            left = tags.shuffled(); right = tags.shuffled()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: matched.count)
        .sensoryFeedback(.error, trigger: missed) { _, missed in missed != nil }
    }

    private func cell(_ text: String, state: StudyChoiceState, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(StudyTheme.body(16, .heavy)).lineLimit(3).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 60).padding(.horizontal, 8)
        }
        .buttonStyle(StudyChoiceStyle(state: state)).allowsHitTesting(state != .right && !revealed).accessibilityIdentifier(id)
    }

    private func pair(_ tag: StudyTag) {
        guard let chosen else { return }
        if chosen == tag.name {
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { matched.insert(tag.name) }
            StudySound.match.play()
            self.chosen = nil
            if matched.count == tags.count { Task { try? await Task.sleep(for: .milliseconds(350)); answer(!slipped) } }
        } else {
            slipped = true; missed = tag.name
            StudySound.wrong.play()
            Task { try? await Task.sleep(for: .milliseconds(450)); missed = nil }
        }
    }
}

/// A picture described in words, written as a prompt by tapping tags from a bank.
private struct StudyBuildStep: View {
    let build: StudyPathLesson.Build
    let picture: BooruPost?
    let server: BooruServer
    let revealed: Bool
    let answer: (Bool) -> Void
    @State private var bank: [String] = []
    @State private var chosen: [String] = []

    var body: some View {
        StudyStepFrame(button: "Check", enabled: !chosen.isEmpty, hidden: revealed, action: { answer(StudyLessonSession.judge(chosen, build)) }) {
            Text(L10n.text("Write the prompt for this picture")).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            HStack(alignment: .top, spacing: 12) {
                StudyMascot(pose: .wave, size: 76)
                StudyCard(padding: 14) { Text(build.brief.resolved()).font(StudyTheme.body(18, .bold)).foregroundStyle(StudyTheme.ink).lineSpacing(3) }
            }
            // The prompt as it stands, a comma after each tag as it would be typed.
            StudyFlow(spacing: 8) {
                ForEach(chosen, id: \.self) { tag in
                    chip(tag, id: "study.build.chosen.\(tag)") { StudySound.tap.play(); withAnimation(.spring(duration: 0.3, bounce: 0.4)) { chosen.removeAll { $0 == tag } } }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                if chosen.isEmpty { Text(L10n.text("Tap the tags below")).font(StudyTheme.body(15, .medium)).foregroundStyle(StudyTheme.muted).padding(.vertical, 12) }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).padding(12)
            .background(StudyTheme.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("study.build.tray")
            if revealed, let picture {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("A picture this prompt describes")).font(StudyTheme.body(13, .bold)).foregroundStyle(StudyTheme.muted)
                    StudyPicture(post: picture, server: server).aspectRatio(CGFloat(max(picture.width, 1)) / CGFloat(max(picture.height, 1)), contentMode: .fit)
                        .frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .studyZoom(picture)
                }
            } else {
                StudyFlow(spacing: 8) {
                    ForEach(bank, id: \.self) { tag in
                        let used = chosen.contains(tag)
                        chip(tag, id: "study.build.bank.\(tag)") { StudySound.pick.play(); withAnimation(.spring(duration: 0.3, bounce: 0.5)) { chosen.append(tag) } }
                            .opacity(used ? 0.25 : 1).allowsHitTesting(!used)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if bank.isEmpty { bank = (build.answer + build.extras).shuffled() } }
    }

    private func chip(_ tag: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(StudyPrompt.words(tag)).font(StudyTheme.body(17, .heavy)).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(StudyPressStyle(radius: 14, depth: 4, outlined: true)).allowsHitTesting(!revealed).accessibilityIdentifier(id)
    }
}

/// A picture and four tags. Three are on the picture; the one that is not is the answer.
private struct StudyOddStep: View {
    let post: BooruPost
    let choices: [StudyTag]
    let answer: Int
    let server: BooruServer
    let revealed: Bool
    let done: (Bool) -> Void
    @State private var picked: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        StudyStepFrame(button: "Check", enabled: picked != nil, hidden: revealed, action: { if let picked { done(picked == answer) } }) {
            Text(L10n.text("Which tag is NOT in this picture?")).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            StudyPicture(post: post, server: server)
                .aspectRatio(min(1.6, max(0.7, CGFloat(max(post.width, 1)) / CGFloat(max(post.height, 1)))), contentMode: .fit)
                .frame(maxWidth: .infinity).frame(maxHeight: sizeClass == .regular ? 480 : 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous)).accessibilityIdentifier("study.picture")
                .studyZoom(post)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(choices.enumerated()), id: \.offset) { index, tag in
                    Button { picked = index; StudySound.pick.play() } label: {
                        Text(tag.english).font(StudyTheme.body(18, .heavy)).lineLimit(2).minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 56).padding(.horizontal, 8)
                    }
                    .buttonStyle(StudyChoiceStyle(state: choiceState(index, picked: picked, answer: answer, revealed: revealed)))
                    .allowsHitTesting(!revealed).accessibilityIdentifier("study.odd.\(index)")
                }
            }
        }
    }
}

/// A tag typed from memory, the way a prompt is typed. Letters can be asked for one at a time as a hint.
private struct StudySpellStep: View {
    let tag: StudyTag
    let post: BooruPost?
    let server: BooruServer
    let revealed: Bool
    let done: (Bool) -> Void
    @State private var typed = ""
    @State private var hints = 0
    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        StudyStepFrame(button: "Check", enabled: !typed.trimmingCharacters(in: .whitespaces).isEmpty, hidden: revealed,
                       action: { focused = false; done(StudyLessonSession.spelled(typed, tag)) }) {
            Text(L10n.text("Type the tag yourself")).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            HStack(alignment: .top, spacing: 12) {
                StudyMascot(pose: .read, size: 76)
                StudyCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        if L10n.language != "en" { Text(tag.title()).font(StudyTheme.body(18, .heavy)).foregroundStyle(StudyTheme.primary) }
                        Text(tag.note.resolved()).font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.ink).lineSpacing(3)
                    }
                }
            }
            if let post {
                StudyPicture(post: post, server: server)
                    .aspectRatio(min(1.6, max(0.7, CGFloat(max(post.width, 1)) / CGFloat(max(post.height, 1)))), contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(maxHeight: sizeClass == .regular ? 360 : 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .studyZoom(post)
            }
            TextField(L10n.text("Write it in English"), text: $typed)
                .font(StudyTheme.code).foregroundStyle(StudyTheme.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable).submitLabel(.done)
                .focused($focused).disabled(revealed)
                .padding(16)
                .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(revealed ? (StudyLessonSession.spelled(typed, tag) ? StudyTheme.good : StudyTheme.bad) : focused ? StudyTheme.primary : StudyTheme.line, lineWidth: 2) }
                .accessibilityIdentifier("study.spell.field")
            if !revealed {
                HStack(spacing: 10) {
                    if hints > 0 {
                        Text(String(tag.english.prefix(hints)) + String(repeating: "·", count: max(0, tag.english.count - hints)))
                            .font(StudyTheme.code).foregroundStyle(StudyTheme.muted).lineLimit(1).minimumScaleFactor(0.6)
                            .transition(.opacity).accessibilityIdentifier("study.spell.hint")
                    }
                    Spacer()
                    Button { StudySound.tap.play(); withAnimation(.snappy) { hints = min(tag.english.count, hints + 1) } } label: {
                        Label(L10n.text("Hint"), systemImage: "lightbulb.fill").font(StudyTheme.body(14, .heavy)).padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(StudyPressStyle(color: StudyTheme.gold, radius: 12, depth: 3, outlined: true))
                    .disabled(hints >= tag.english.count).accessibilityIdentifier("study.spell.hintButton")
                }
            }
        }
        .onAppear { focused = true }
    }
}

/// Where each numbered place of an order step lies, so that a dragged thing knows which one it is over.
private struct StudyPlaceFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Things that happen one after another, put in order by tapping them or dragging them into numbered places.
private struct StudyOrderStep: View {
    let order: StudyPathLesson.Order
    let revealed: Bool
    let answer: (Bool) -> Void
    /// Positions in the right order, as they were mixed for the bank and as they have been placed.
    @State private var bank: [Int] = []
    @State private var chosen: [Int] = []
    @State private var frames: [Int: CGRect] = [:]
    /// The thing being dragged, how far it has been carried and the place it is over.
    @State private var dragging: Int?
    @State private var carried = CGSize.zero
    @State private var target: Int?
    private static let space = "study.order"

    var body: some View {
        StudyStepFrame(button: "Check", enabled: chosen.count == order.items.count, hidden: revealed,
                       action: { answer(StudyLessonSession.judge(chosen.map { order.items[$0] }, order)) }) {
            Text(order.brief.resolved()).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            if !revealed {
                Label(L10n.text("Tap them in order, or drag them into place."), systemImage: "hand.draw.fill")
                    .font(StudyTheme.body(13, .bold)).foregroundStyle(StudyTheme.muted)
            }
            VStack(spacing: 10) {
                ForEach(0..<order.items.count, id: \.self) { place in
                    let item = chosen.indices.contains(place) ? chosen[place] : nil
                    HStack(spacing: 12) {
                        Text(String(place + 1)).font(StudyTheme.body(16, .heavy)).foregroundStyle(.white).frame(width: 30, height: 30)
                            .background(target == place ? StudyTheme.gold : item == nil ? StudyTheme.line : StudyTheme.primary, in: Circle())
                            .scaleEffect(target == place ? 1.2 : 1)
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(target == place ? StudyTheme.gold : StudyTheme.line, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                                .background { if target == place { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StudyTheme.gold.opacity(0.14)) } }
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .opacity(item == nil || dragging == item ? 1 : 0)
                                .accessibilityIdentifier("study.order.slot.\(place)")
                            if let item {
                                let right = order.items[item] == order.items[place]
                                row(item, style: StudyChoiceStyle(state: revealed ? (right ? .right : .wrong) : .picked), id: "study.order.place.\(place)") {
                                    StudySound.tap.play(); withAnimation(.spring(duration: 0.3, bounce: 0.4)) { chosen.removeAll { $0 == item } }
                                }
                            }
                        }
                    }
                    .background { GeometryReader { proxy in Color.clear.preference(key: StudyPlaceFrames.self, value: [place: proxy.frame(in: .named(Self.space))]) } }
                    .zIndex(item != nil && dragging == item ? 2 : 0)
                }
            }
            // A placed thing carried down over the bank must pass above it.
            .zIndex(dragging.map(chosen.contains) == true ? 1 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: target)
            if !revealed {
                VStack(spacing: 10) {
                    ForEach(bank.filter { !chosen.contains($0) }, id: \.self) { item in
                        row(item, style: StudyPressStyle(radius: 16, depth: 4, outlined: true), id: "study.order.item.\(item)") {
                            StudySound.pick.play(); withAnimation(.spring(duration: 0.3, bounce: 0.5)) { chosen.append(item) }
                        }
                        .zIndex(dragging == item ? 2 : 0)
                    }
                }.padding(.top, 6)
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(StudyPlaceFrames.self) { frames = $0 }
        .sensoryFeedback(.selection, trigger: target)
        .onAppear {
            guard bank.isEmpty else { return }
            var mixed = Array(order.items.indices).shuffled()
            // Never offered already in order: that would give the answer away.
            if mixed == Array(order.items.indices), mixed.count > 1 { mixed.swapAt(0, 1) }
            bank = mixed
        }
    }

    /// One thing to order: a tap sends it to the next free place or back, and a drag carries it to the place it is dropped on.
    private func row<Style: ButtonStyle>(_ item: Int, style: Style, id: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(order.items[item].resolved()).font(StudyTheme.body(16, .bold)).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 4)
        }
        .buttonStyle(style)
        .scaleEffect(dragging == item ? 1.04 : 1)
        .shadow(color: .black.opacity(dragging == item ? 0.3 : 0), radius: 10, y: 6)
        .offset(dragging == item ? carried : .zero)
        .allowsHitTesting(!revealed)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragging != item { dragging = item; StudySound.pick.play() }
                carried = value.translation
                target = place(at: value.location)
            }
            .onEnded { value in
                let place = place(at: value.location)
                withAnimation(.spring(duration: 0.3, bounce: 0.4)) {
                    // Dropped on a place, it goes there and the others make room; dropped anywhere else, it goes back to the bank.
                    chosen.removeAll { $0 == item }
                    if let place { chosen.insert(item, at: min(place, chosen.count)) }
                    dragging = nil; carried = .zero; target = nil
                }
                StudySound.tap.play()
            })
        .accessibilityIdentifier(id)
    }

    /// The numbered place under a point, taking the nearest one while the point is among the places at all.
    private func place(at point: CGPoint) -> Int? {
        guard let top = frames.values.map(\.minY).min(), let bottom = frames.values.map(\.maxY).max(), point.y >= top - 16, point.y <= bottom + 16 else { return nil }
        return frames.min { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) }?.key
    }
}

/// Things dropped one at a time into one of two buckets.
private struct StudySortStep: View {
    let sort: StudyPathLesson.Sort
    let revealed: Bool
    let answer: (Bool) -> Void
    @State private var queue: [Int] = []
    @State private var placed: [Int] = []
    /// The things first dropped into the wrong bucket.
    @State private var missed: Set<Int> = []
    @State private var shakes = 0
    /// The bucket the card is flying into, while it flies.
    @State private var flying: Bool?
    @State private var bumped: Bool?

    private var current: Int? { queue.first { !placed.contains($0) } }

    var body: some View {
        StudyStepFrame(button: "Check", hidden: true, action: {}) {
            Text(sort.brief.resolved()).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink)
            HStack(spacing: 6) {
                ForEach(queue, id: \.self) { item in
                    Capsule().fill(placed.contains(item) ? StudyTheme.good : item == current ? StudyTheme.primary : StudyTheme.sunken).frame(height: 6)
                }
            }
            ZStack {
                if let current {
                    Text(sort.items[current].text.resolved()).font(StudyTheme.title(21)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                        .padding(22).frame(maxWidth: .infinity, minHeight: 130)
                        .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(StudyTheme.primary, lineWidth: 3) }
                        .background { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(StudyTheme.primary.studyEdge()).offset(y: 6) }
                        .modifier(StudyShake(travel: CGFloat(shakes)))
                        .offset(x: flying == nil ? 0 : flying == true ? 150 : -150, y: flying == nil ? 0 : 150)
                        .scaleEffect(flying == nil ? 1 : 0.25).opacity(flying == nil ? 1 : 0)
                        .rotationEffect(.degrees(flying == nil ? 0 : flying == true ? 14 : -14))
                        .id(current)
                        .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity), removal: .identity))
                        .accessibilityIdentifier("study.sort.item")
                } else {
                    StudyMascot(pose: missed.isEmpty ? .cheer : .think, size: 120)
                        .frame(maxWidth: .infinity, minHeight: 130).transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 6)
            HStack(alignment: .top, spacing: 12) {
                bucket(false)
                bucket(true)
            }
        }
        .onAppear { if queue.isEmpty { queue = Array(sort.items.indices).shuffled() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: placed.count)
        .sensoryFeedback(.error, trigger: shakes)
    }

    /// A bucket, and under it what has been dropped in so far.
    private func bucket(_ right: Bool) -> some View {
        let color = right ? StudyTheme.flame : StudyTheme.primary
        let inside = placed.filter { sort.items[$0].right == right }
        return VStack(spacing: 8) {
            Button { drop(right) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 18, weight: .bold))
                    Text((right ? sort.right : sort.left).resolved()).font(StudyTheme.body(17, .heavy)).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, minHeight: 68).padding(.horizontal, 8)
            }
            .buttonStyle(StudyPressStyle(color: color, radius: 18, depth: 5))
            .scaleEffect(bumped == right ? 1.08 : 1).animation(.spring(duration: 0.25, bounce: 0.6), value: bumped)
            .disabled(current == nil || flying != nil || revealed)
            .accessibilityIdentifier(right ? "study.sort.right" : "study.sort.left")
            ForEach(inside, id: \.self) { item in
                let wrong = missed.contains(item)
                HStack(spacing: 4) {
                    if wrong { Image(systemName: "xmark.circle.fill").foregroundStyle(StudyTheme.bad) }
                    Text(sort.items[item].text.resolved()).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                }
                    .font(StudyTheme.body(13, .bold))
                    .frame(maxWidth: .infinity).padding(.horizontal, 8).padding(.vertical, 8)
                    .background((wrong ? StudyTheme.bad : color).opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { if wrong { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudyTheme.bad, lineWidth: 2) } }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func drop(_ right: Bool) {
        guard let item = current, flying == nil else { return }
        let belongs = sort.items[item].right
        if belongs == right { StudySound.match.play() } else {
            // A wrong bucket shakes the card; it then goes where it belongs, so the right place is seen.
            missed.insert(item)
            StudySound.wrong.play()
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
        }
        Task {
            if belongs != right { try? await Task.sleep(for: .milliseconds(480)) }
            withAnimation(.easeIn(duration: 0.26)) { flying = belongs }
            try? await Task.sleep(for: .milliseconds(240))
            bumped = belongs
            withAnimation(.spring(duration: 0.35, bounce: 0.45)) { placed.append(item); flying = nil }
            try? await Task.sleep(for: .milliseconds(200))
            bumped = nil
            if placed.count == sort.items.count { try? await Task.sleep(for: .milliseconds(350)); answer(missed.isEmpty) }
        }
    }
}

// MARK: - Results

/// A finished lesson: the guide cheers, the stars land one by one, the numbers count up, and anything reached
/// beyond the lesson (a streak, the day's goal, a level) gets a page of its own afterwards.
struct StudyLessonResult: View {
    let session: StudyLessonSession
    let done: () -> Void
    @Environment(BooruStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the results have unfolded: 1 the guide and title, 2–4 the stars, 5 the tiles, 6 the goal.
    @State private var stage = 0
    @State private var game = StudyGame()
    @State private var streak = 0
    @State private var days: [StudyDay] = []
    @State private var milestones: [StudyMilestone] = []
    /// Zero shows the results; later pages show the milestones in turn.
    @State private var page = 0

    private var accuracy: Int { session.asked == 0 ? 100 : Int((Double(session.asked - session.mistakes) / Double(session.asked) * 100).rounded()) }
    private var empty: Bool { session.asked == 0 && session.plan.lesson == nil }

    var body: some View {
        ZStack(alignment: .top) {
            if page == 0 { results.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity))) }
            else {
                StudyMilestoneView(milestone: milestones[page - 1], days: days).id(page)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: page)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StudyMainButton(title: L10n.text("Continue")) {
                StudySound.tap.play()
                if page < milestones.count { page += 1 } else { done() }
            }
            .frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(StudyTheme.background).accessibilityIdentifier("study.done")
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: stage) { _, new in (2...4).contains(new) && new - 1 <= session.stars }
        .sensoryFeedback(.success, trigger: stage) { old, new in old == 0 && new > 0 }
        .onAppear(perform: unfold)
    }

    private var results: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 22) {
                    if empty {
                        StudyMascot(pose: .cheer, size: 150).padding(.top, 60)
                        Text(L10n.text("Nothing to Review")).font(StudyTheme.title(28)).foregroundStyle(StudyTheme.ink)
                        Text(L10n.text("No tag is due right now. Learn new tags or come back later.")).font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                    } else {
                        StudyMascot(pose: .cheer, size: 170).padding(.top, 28)
                            .phaseAnimator([0.0, -18.0, 0.0], trigger: stage >= 1) { view, lift in view.offset(y: lift) } animation: { _ in .spring(duration: 0.3, bounce: 0.6) }
                            .studyPop(stage >= 1, from: 0.2)
                            .overlay { StudyBurst(trigger: stage >= 1 ? 1 : 0, count: 24, reach: 130) }
                        Text(L10n.text(session.plan.lesson == nil ? "Review Complete!" : "Lesson Complete!")).font(StudyTheme.title(32)).foregroundStyle(StudyTheme.ink)
                            .studyRise(stage >= 1, delay: 0.1).accessibilityIdentifier("study.complete")
                        HStack(spacing: 10) {
                            ForEach(0..<3, id: \.self) { index in
                                let won = index < session.stars, landed = stage >= index + 2
                                Image(systemName: "star.fill").font(.system(size: 48, weight: .bold))
                                    .foregroundStyle(won ? StudyTheme.gold : StudyTheme.line)
                                    .shadow(color: won ? StudyTheme.gold.studyEdge() : .clear, radius: 0, y: 3)
                                    .scaleEffect(landed ? 1 : 2.6).opacity(landed ? 1 : 0)
                                    .rotationEffect(.degrees(landed ? 0 : -50))
                                    .offset(y: index == 1 ? -10 : 0)
                                    .animation(.spring(duration: 0.4, bounce: 0.55), value: landed)
                                    .overlay { if won { StudyBurst(trigger: landed ? 1 : 0, count: 12, reach: 54, colors: [StudyTheme.gold, .white, StudyTheme.flame]) } }
                            }
                        }
                        .accessibilityElement().accessibilityLabel(L10n.text("Stars: %@", String(session.stars))).accessibilityIdentifier("study.stars")
                        HStack(spacing: 10) {
                            tile(L10n.text("Earned"), "bolt.fill", StudyTheme.gold, 0) {
                                StudyCount(value: stage >= 5 ? Double(session.earned) : 0, prefix: "+", suffix: " XP").animation(.easeOut(duration: 0.9), value: stage)
                            }
                            tile(L10n.text("Accuracy"), "scope", StudyTheme.good, 1) {
                                StudyCount(value: stage >= 5 ? Double(accuracy) : 0, suffix: "%").animation(.easeOut(duration: 0.9), value: stage)
                            }
                            tile(L10n.text("Best run"), "flame.fill", StudyTheme.flame, 2) {
                                StudyCount(value: stage >= 5 ? Double(session.bestCombo) : 0).animation(.easeOut(duration: 0.9), value: stage)
                            }
                        }
                        StudyCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(L10n.text("Today's goal"), systemImage: game.goalMet ? "checkmark.seal.fill" : "target")
                                        .font(StudyTheme.body(16, .heavy)).foregroundStyle(game.goalMet ? StudyTheme.good : StudyTheme.ink)
                                    Spacer()
                                    Text(verbatim: "\(game.today) / \(game.goal) XP").font(StudyTheme.body(14, .heavy)).foregroundStyle(StudyTheme.muted).monospacedDigit()
                                }
                                StudyBar(value: stage >= 6 ? game.goalProgress : (game.goal > 0 ? min(1, Double(session.before.today) / Double(game.goal)) : 0),
                                         color: game.goalMet ? StudyTheme.good : StudyTheme.gold)
                                if streak > 0 {
                                    Label(L10n.text("Day streak: %@", String(streak)), systemImage: "flame.fill")
                                        .font(StudyTheme.body(15, .heavy)).foregroundStyle(StudyTheme.flame)
                                }
                            }
                        }
                        .studyRise(stage >= 6)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            if !empty, !reduceMotion {
                StudyConfetti(pieces: session.stars == 3 ? 140 : session.stars == 2 ? 80 : 40).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    /// Reads where the learner now stands, then lets the results appear a piece at a time.
    private func unfold() {
        days = (try? store.studyStore.days()) ?? []
        let saved = ReaderPreferences.booruDefaults.integer(forKey: StudyModeModel.goalKey)
        game = StudyGame(days: days, goal: StudyGame.goals.contains(saved) ? saved : StudyGame.defaultGoal)
        streak = StudySummary(curriculum: .bundled, progress: [:], days: days).streak
        milestones = StudyMilestone.reached(before: session.before, earned: session.earned, goal: game.goal, streak: streak)
        // Badges this lesson earned get their pages after the streak, the goal and the level.
        let badges = StudyAwards.refresh(store)
        try? store.studyStore.markSeen(badges.map(\.id))
        milestones += badges.map { .award($0) }
        guard !empty else { return }
        StudySound.complete.play()
        guard !reduceMotion else { stage = 6; return }
        Task {
            try? await Task.sleep(for: .milliseconds(150)); stage = 1
            for star in 1...3 {
                try? await Task.sleep(for: .milliseconds(star == 1 ? 550 : 330))
                stage = star + 1
                if star <= session.stars { [StudySound.star1, .star2, .star3][star - 1].play() }
            }
            try? await Task.sleep(for: .milliseconds(380)); stage = 5
            try? await Task.sleep(for: .milliseconds(450)); withAnimation(.spring(duration: 0.8, bounce: 0.3)) { stage = 6 }
        }
    }

    private func tile<Value: View>(_ title: String, _ symbol: String, _ color: Color, _ index: Int, @ViewBuilder value: () -> Value) -> some View {
        VStack(spacing: 6) {
            Text(title).font(StudyTheme.body(12, .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).padding(.vertical, 5).background(color)
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                value().foregroundStyle(StudyTheme.ink)
            }.font(StudyTheme.body(18, .heavy)).padding(.bottom, 10).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .background(StudyTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color, lineWidth: 2) }
        .studyPop(stage >= 5, delay: Double(index) * 0.1, from: 0.5)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Placement result

/// Where the placement test put the learner: how it went, the section they begin at, and how many lessons it passed by.
struct StudyPlacementResult: View {
    let session: StudyLessonSession
    let done: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var section: StudyPathSection? { StudyPlacement.section(.bundled, placed: session.placed) }
    private var ahead: Bool { session.placed > 0 }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 20) {
                    StudyMascot(pose: ahead ? .cheer : .wave, size: 160).padding(.top, 32)
                        .phaseAnimator([0.0, -18.0, 0.0], trigger: shown) { view, lift in view.offset(y: lift) } animation: { _ in .spring(duration: 0.3, bounce: 0.6) }
                        .studyPop(shown, from: 0.2)
                        .overlay { if ahead { StudyBurst(trigger: shown ? 1 : 0, count: 24, reach: 130) } }
                    VStack(spacing: 8) {
                        Text(L10n.text(ahead ? "You Know Your Stuff!" : "Let's Start from the Beginning"))
                            .font(StudyTheme.title(30)).foregroundStyle(StudyTheme.ink).multilineTextAlignment(.center)
                            .accessibilityIdentifier("study.placement.title")
                        Text(L10n.text(ahead ? "You can skip ahead on the path." : "We'll learn the basics together, one short lesson at a time."))
                            .font(StudyTheme.body(16, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                    }.studyRise(shown, delay: 0.1)
                    HStack(spacing: 10) {
                        tile(L10n.text("Right Answers"), "checkmark.circle.fill", StudyTheme.good, "\(session.asked - session.mistakes) / \(session.asked)")
                        tile(L10n.text("Lessons Skipped"), "forward.fill", StudyTheme.primary, String(session.placed))
                    }.studyRise(shown, delay: 0.2)
                    if let section {
                        let color = Color(studyHex: section.color)
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L10n.text("Start Here"), systemImage: "flag.fill").font(StudyTheme.body(14, .heavy)).foregroundStyle(.white.opacity(0.9))
                            Text(section.title.resolved()).font(StudyTheme.title(24)).foregroundStyle(.white)
                            Text(section.summary.resolved()).font(StudyTheme.body(15, .medium)).foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(color, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .background { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(color.studyEdge()).offset(y: 5) }
                        .studyPop(shown, delay: 0.35, from: 0.6)
                        .accessibilityElement(children: .combine).accessibilityIdentifier("study.placement.section")
                    }
                    if ahead {
                        Text(L10n.text("The lessons before it stay open on the map, to play whenever you like."))
                            .font(StudyTheme.body(14, .medium)).foregroundStyle(StudyTheme.muted).multilineTextAlignment(.center)
                            .studyRise(shown, delay: 0.45)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            if ahead, !reduceMotion { StudyConfetti(pieces: 90).allowsHitTesting(false).accessibilityHidden(true) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StudyMainButton(title: L10n.text("Start Learning"), symbol: "play.fill") { StudySound.tap.play(); done() }
                .frame(maxWidth: 560).padding(.horizontal, 18).padding(.vertical, 10).frame(maxWidth: .infinity)
                .background(StudyTheme.background).accessibilityIdentifier("study.done")
        }
        .sensoryFeedback(.success, trigger: shown)
        .onAppear {
            shown = true
            (ahead ? StudySound.levelup : StudySound.complete).play()
        }
    }

    private func tile(_ title: String, _ symbol: String, _ color: Color, _ value: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(color)
            Text(verbatim: value).font(StudyTheme.title(22)).foregroundStyle(StudyTheme.ink).monospacedDigit()
            Text(title).font(StudyTheme.body(12, .bold)).foregroundStyle(StudyTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
        .accessibilityElement(children: .combine)
    }
}
