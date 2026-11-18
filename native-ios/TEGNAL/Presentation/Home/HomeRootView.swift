import SwiftUI

/// The app's root: the library and learning mode, with the home scene over them until one is chosen.
struct HomeRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = HomeStage.shared

    var body: some View {
        ZStack {
            AppRootTabView()
                .accessibilityHidden(stage.coversScreen)
            if stage.enabled {
                HomeStageHost(stage: stage, active: scenePhase == .active)
                    .ignoresSafeArea()
                    .allowsHitTesting(stage.coversScreen)
                    .accessibilityHidden(true)
                HomeChrome(stage: stage)
            }
        }
    }
}

/// The few words laid over the scene: where each pull leads, the music switch, and the way back.
private struct HomeChrome: View {
    let stage: HomeStage
    @State private var breathing = false
    @State private var showsWayBack = false

    var body: some View {
        ZStack {
            if stage.place == .home {
                VStack(spacing: 0) {
                    way(.study)
                    Spacer(minLength: 0)
                    way(.library)
                }
                .padding(.top, 14).padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(stage.hintsReady ? 1 - stage.engagement : 0)
                .overlay(alignment: .topTrailing) { musicButton.opacity(stage.introFinished ? 1 - stage.engagement : 0) }
                .transition(.opacity)
                .onAppear { breathing = true }
                .onDisappear { breathing = false }
            }
            VStack {
                // Each place is pulled back from its own side: the library from its top bar, learning mode from its dock.
                let rising = stage.place == .study
                if stage.pull > 0, stage.place != .home, !rising { pulling(rising: false).padding(.top, 6) }
                Spacer(minLength: 0)
                if stage.pull > 0, rising { pulling(rising: true).padding(.bottom, 104) }
                else if showsWayBack, !stage.coversScreen, stage.pull == 0 {
                    notice(rising ? "Swipe up from the bottom bar to return to the start" : "Pull down from the top to return to the start", symbol: rising ? "arrow.up" : "arrow.down")
                        .padding(.bottom, rising ? 104 : 92)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.25), value: stage.pullArmed)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: stage.coversScreen) { _, covered in
            // The way back is told the first few times a place is reached.
            guard !covered, stage.place != .home, stage.takeReturnHint() else { return }
            withAnimation(.snappy) { showsWayBack = true }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 0.5)) { showsWayBack = false }
            }
        }
    }

    /// One of the two ways out. It can be pulled toward from anywhere on the scene, or simply tapped.
    private func way(_ realm: HomeRealm) -> some View {
        let study = realm == .study
        return Button { if !stage.moving { stage.travel?(realm) } } label: {
            VStack(spacing: 5) {
                if !study { arrow("chevron.compact.up", rising: true) }
                Text(L10n.text(study ? "Learning Mode" : "Viewing Mode"))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .tracking(2.5)
                if study { arrow("chevron.compact.down", rising: false) }
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 1)
            .padding(.horizontal, 28).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(study ? "home.study" : "home.library")
        .accessibilityHint(L10n.text(study ? "Swipe down anywhere to open." : "Swipe up anywhere to open."))
    }

    private func arrow(_ symbol: String, rising: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .light))
            .offset(y: breathing ? (rising ? -5 : 5) : 0)
            .opacity(breathing ? 1 : 0.55)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: breathing)
            .accessibilityHidden(true)
    }

    private func pulling(rising: Bool) -> some View {
        notice(stage.pullArmed ? "Release to Return" : "Keep Pulling to Return", symbol: stage.pullArmed ? "house.fill" : rising ? "arrow.up" : "arrow.down")
            .opacity(min(1, Double(stage.pull) / 36))
            .contentTransition(.opacity)
    }

    private var musicButton: some View {
        // A pull that happens to start on the button is a pull, not a press.
        Button { if !stage.moving { stage.muted.toggle() } } label: {
            Image(systemName: stage.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.13), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.6) }
                .contentTransition(.symbolEffect(.replace))
                .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 10).padding(.top, 4)
        .accessibilityLabel(L10n.text(stage.muted ? "Turn Music On" : "Turn Music Off"))
        .accessibilityIdentifier("home.music")
    }

    private func notice(_ key: String, symbol: String) -> some View {
        Label(L10n.text(key), systemImage: symbol)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("home.wayBack")
    }
}
