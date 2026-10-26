import SwiftUI

/// Shared spacing for compact action groups in the navigation bar.
struct AppToolbarActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 8)
    }
}

/// Retained navigation trees share the same thumb animation when modes change.
@Observable final class AppModeSwitchMotion {
    var position: CGFloat?
    var target: AppMode?
    @ObservationIgnored private var lastInteraction: ContinuousClock.Instant?
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
                Capsule().fill(.white)
                    .frame(width: 42, height: 38)
                    .offset(x: motion.position ?? position(current))
            }
            .padding(3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule(isInteractive: true)
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
        .highPriorityGesture(DragGesture(minimumDistance: 12)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard isActiveControl else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if dragOrigin == nil { dragOrigin = motion.position ?? position(current) }
                    motion.position = min(44, max(0, (dragOrigin ?? position(current)) + value.translation.width))
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
                if isActiveControl && !dragging && dragOrigin != nil { dragOrigin = nil; settle(activeMode) }
            }
        }
        .onChange(of: activeMode) { _, _ in
            guard isActiveControl else { return }
            dragOrigin = nil
            // Read the current selection: retained trees can deliver older changes later.
            if motion.target != activeMode { settle(activeMode) }
        }
        .onAppear {
            visible = true
            if motion.position == nil { motion.position = position(current); motion.target = current }
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
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 38)
            .foregroundStyle(current == mode ? Color.black : Color.secondary)
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
        if motion.position == nil { motion.position = position(current) }
        motion.target = mode
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            motion.position = position(mode)
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
