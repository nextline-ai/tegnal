import SwiftUI
import QuartzCore

/// Shared spacing for compact action groups in the navigation bar.
struct AppToolbarActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 8)
    }
}

struct AppModeSwitchTransition: Identifiable {
    static let seconds = 0.24
    let id = UUID()
    let from: CGFloat
    let to: CGFloat
    let started: ContinuousClock.Instant
    var deadline: ContinuousClock.Instant { started.advanced(by: .milliseconds(240)) }

    func position(at now: ContinuousClock.Instant) -> CGFloat {
        let elapsed = started.duration(to: now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let progress = min(1, max(0, seconds / Self.seconds))
        let eased = progress * progress * (3 - 2 * progress)
        return from + (to - from) * CGFloat(eased)
    }
}

private struct AppModeThumb: UIViewRepresentable {
    let position: CGFloat
    let transition: AppModeSwitchTransition?
    func makeUIView(context: Context) -> AppModeThumbView { AppModeThumbView() }
    func updateUIView(_ view: AppModeThumbView, context: Context) { view.display(position: position, transition: transition) }
}

private final class AppModeThumbView: UIView {
    private let bubble = UIView()
    private var transitionID: UUID?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        bubble.isUserInteractionEnabled = false
        bubble.backgroundColor = .white
        bubble.layer.cornerRadius = 19
        bubble.layer.cornerCurve = .continuous
        addSubview(bubble)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        bubble.bounds = CGRect(x: 0, y: 0, width: 42, height: 38)
        bubble.center = CGPoint(x: 21, y: 19)
    }
    func display(position: CGFloat, transition: AppModeSwitchTransition?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.layer.transform = CATransform3DMakeTranslation(transition?.to ?? position, 0, 0)
        CATransaction.commit()
        guard let transition else {
            bubble.layer.removeAnimation(forKey: "mode.thumb")
            transitionID = nil
            return
        }
        guard transitionID != transition.id else { return }
        transitionID = transition.id
        let elapsed = transition.started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        guard seconds < AppModeSwitchTransition.seconds else { bubble.layer.removeAnimation(forKey: "mode.thumb"); return }
        // The compositor interpolates the shared curve. No SwiftUI view update
        // or layout work is needed for each animation frame.
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = (0...60).map { frame in
            NSNumber(value: Double(transition.position(at: transition.started.advanced(by: .milliseconds(frame * 4)))))
        }
        animation.duration = AppModeSwitchTransition.seconds
        animation.beginTime = bubble.layer.convertTime(CACurrentMediaTime(), from: nil) - max(0, seconds)
        animation.calculationMode = .linear
        animation.fillMode = .backwards
        bubble.layer.add(animation, forKey: "mode.thumb")
    }
}

/// Every retained toolbar samples the same motion clock, including during a
/// crossfade. A newly visible toolbar continues the motion instead of replaying it.
@Observable final class AppModeSwitchMotion {
    private(set) var transition: AppModeSwitchTransition?
    private var restingPosition: CGFloat?
    @ObservationIgnored private var lastInteraction: ContinuousClock.Instant?
    static func position(_ mode: AppMode) -> CGFloat { mode == .manga ? 0 : 44 }
    func position(for mode: AppMode, at now: ContinuousClock.Instant = .now) -> CGFloat {
        transition?.position(at: now) ?? restingPosition ?? Self.position(mode)
    }
    func prepare(for mode: AppMode) {
        if restingPosition == nil { restingPosition = Self.position(mode) }
    }
    func move(to mode: AppMode, reducedMotion: Bool, at now: ContinuousClock.Instant = .now) {
        let target = Self.position(mode)
        if reducedMotion { transition = nil; restingPosition = target; return }
        guard transition?.to != target else { return }
        let from = position(for: mode, at: now)
        restingPosition = target
        if abs(from - target) < 0.001 { transition = nil }
        else { transition = AppModeSwitchTransition(from: from, to: target, started: now) }
    }
    func drag(to position: CGFloat) {
        transition = nil
        restingPosition = min(44, max(0, position))
    }
    func finish(_ id: UUID) {
        guard transition?.id == id else { return }
        transition = nil
    }
    func acceptInteraction(at now: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        if let lastInteraction, lastInteraction.duration(to: now) < .milliseconds(220) { return false }
        lastInteraction = now
        return true
    }
}

private struct DisplayedAppModeKey: EnvironmentKey { static let defaultValue: AppMode? = nil }
extension EnvironmentValues {
    var displayedAppMode: AppMode? {
        get { self[DisplayedAppModeKey.self] }
        set { self[DisplayedAppModeKey.self] = newValue }
    }
}

/// The same compact switch occupies the title area of every root navigation bar.
struct AppModeSwitch: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayedAppMode) private var displayedAppMode
    /// A tutorial can preview the switch without changing the active library.
    var previewMode: Binding<AppMode>? = nil
    @State private var previewMotion = AppModeSwitchMotion()
    @State private var dragOrigin: CGFloat?
    @GestureState private var dragging = false
    @State private var visible = false
    @State private var hintPhase = 0
    private let hintColors: [Color] = [.cyan, .purple, .pink, .orange, .green]
    private var isActiveControl: Bool { previewMode != nil || displayedAppMode == nil || displayedAppMode == env.mode }
    private var animatesHint: Bool { env.modeSwitchHintPending && visible && isActiveControl && scenePhase == .active && !reduceMotion }
    private var activeMode: AppMode { previewMode?.wrappedValue ?? env.mode }
    private var current: AppMode { activeMode }
    private var motion: AppModeSwitchMotion { previewMode == nil ? env.modeSwitchMotion : previewMotion }
    var body: some View {
        Button { change(current == .manga ? .booru : .manga) } label: {
            HStack(spacing: 2) {
                mode(.manga)
                mode(.booru)
            }
            .background(alignment: .leading) {
                AppModeThumb(position: motion.position(for: current), transition: motion.transition)
                    .frame(width: 42, height: 38, alignment: .leading)
                    .transaction { $0.animation = nil }
            }
            .padding(3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .overlay {
            if env.modeSwitchHintPending {
                Capsule().strokeBorder(hintColors[hintPhase], lineWidth: 2.5)
                    .background(Capsule().fill(hintColors[hintPhase].opacity(0.12)))
                    .opacity(hintPhase.isMultiple(of: 2) ? 1 : 0.45)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: animatesHint) {
            guard animatesHint else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
                withAnimation(.easeInOut(duration: 0.7)) { hintPhase = (hintPhase + 1) % hintColors.count }
            }
        }
        .task(id: "\(motion.transition?.id.uuidString ?? ""):\(visible):\(scenePhase)") {
            guard visible, scenePhase == .active, let transition = motion.transition else { return }
            do {
                try await Task.sleep(until: transition.deadline, clock: .continuous)
                motion.finish(transition.id)
            } catch {}
        }
        .highPriorityGesture(DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard isActiveControl else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if dragOrigin == nil { dragOrigin = motion.position(for: current) }
                    motion.drag(to: (dragOrigin ?? position(current)) + value.translation.width)
                }
            }
            .onEnded { value in
                let end = (dragOrigin ?? position(current)) + value.predictedEndTranslation.width
                dragOrigin = nil
                change(end > 22 ? .booru : .manga)
            })
        .onChange(of: dragging) { _, active in
            guard !active else { return }
            DispatchQueue.main.async {
                // Cancellation has no onEnded callback. Keep the absolute thumb
                // position until it can settle, rather than resetting a translation.
                if visible && isActiveControl && !dragging && dragOrigin != nil { dragOrigin = nil; settle(activeMode) }
            }
        }
        .onChange(of: activeMode) { _, _ in
            dragOrigin = nil
            if isActiveControl { settle(activeMode) }
        }
        .onAppear {
            visible = true
            motion.prepare(for: activeMode)
            settle(activeMode)
        }
        .onDisappear {
            visible = false
            dragOrigin = nil
        }
        .accessibilityLabel(L10n.text("Switch Modes"))
        .accessibilityHint(L10n.text("Tap or swipe to switch between comics and images."))
        .accessibilityValue(current.title)
        .accessibilityIdentifier("app.mode")
    }
    private func mode(_ mode: AppMode) -> some View {
        Image(systemName: current == mode ? mode.icon + ".fill" : mode.icon)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 38)
            .foregroundStyle(current == mode ? Color.black : Color.gray)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
    private func position(_ mode: AppMode) -> CGFloat { mode == .manga ? 0 : 44 }
    private func change(_ mode: AppMode) {
        guard isActiveControl else { return }
        guard mode != current, motion.acceptInteraction() else { settle(current); return }
        env.acknowledgeModeSwitch()
        // The shared selection is authoritative immediately. A disappearing
        // toolbar must never commit an older selection from an animation callback.
        settle(mode)
        if let previewMode { previewMode.wrappedValue = mode }
        else { env.mode = mode }
    }
    private func settle(_ mode: AppMode) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            motion.move(to: mode, reducedMotion: reduceMotion)
        }
    }
}

extension View {
    @ViewBuilder func clearTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .top) }
        else { self }
    }

    func appRootHeader(_ title: String) -> some View {
        self.safeAreaInset(edge: .top, spacing: 0) { ImportReminderBanner() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule(L10n.text(title)) }
                ToolbarItem(placement: .principal) { AppModeSwitch().id(title) }
            }
    }
}

private struct ImportReminderBanner: View {
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage("onboarding.importReminderDismissed", store: ReaderPreferences.defaults) private var hidden = false
    @State private var showingImport = false
    var body: some View {
        Group {
            if env.isOnboardingCompleted && !hidden {
                HStack(spacing: 12) {
                    Button {
                        hidden = true
                        showingImport = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.down").font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.text("Import from Other Apps")).font(.subheadline.weight(.semibold))
                                Text("Anime Boxes · Other Manga Viewer").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("importReminder.open")
                    Button { hidden = true } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 32, height: 36)
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("importReminder.close")
                }
                .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .appSheet(isPresented: $showingImport) { OnboardingView(importsOnly: true).environment(env).environment(env.booru) }
    }
}
