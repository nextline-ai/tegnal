import SwiftUI
import UIKit

/// The home scene and the two journeys out of it.
///
/// Everything that moves is a layer, and every journey is handed to the render server as one set
/// of keyframes. Building the library's screens on the main thread while the camera sinks
/// therefore costs the journey no frames.
@MainActor final class HomeStageView: UIView, UIGestureRecognizerDelegate {
    private enum Phase { case home, pullingOut, travelling, away, pullingBack, returning }

    private let stage: HomeStage
    /// SwiftUI owns this view's own frame and visibility; everything is drawn in this child.
    private let content = UIView()
    private let under = UIView()
    private let scene = HomeSceneView()
    private let over = UIView()
    private let ground = CALayer()
    private let music = HomeMusic()
    private var realms: [HomeRealm: HomeRealmLayers] = [:]
    private var images: [HomeArt.Request: CGImage] = [:]
    private var builtSize = CGSize.zero
    private var preparing = false
    private var shown: HomeRealm?
    private var phase = Phase.home
    private var moment = 0.0
    private var armed = false
    private var active = false
    private var started = false
    private var opened = false
    private var journey = 0
    /// The place to go on to once the scene has been reached, when one place was asked for from the other.
    private var onward: HomeRealm?
    private static var made = false
    /// Both are on the window, so that a pull counts wherever it starts: on the scene's words, a toolbar, a dock.
    private let outward = UIPanGestureRecognizer()
    private let back = UIPanGestureRecognizer()
    private let nudge = UIImpactFeedbackGenerator(style: .soft)
    private let land = UIImpactFeedbackGenerator(style: .medium)

    init(stage: HomeStage) {
        self.stage = stage
        super.init(frame: .zero)
        backgroundColor = .clear
        content.backgroundColor = .clear
        content.clipsToBounds = true
        addSubview(content)
        for view in [under, scene, over] { content.addSubview(view) }
        under.isUserInteractionEnabled = false; over.isUserInteractionEnabled = false
        ground.zPosition = 1
        scene.layer.addSublayer(ground)
        scene.onFirstFrame = { [weak self] in self?.open() }

        outward.addTarget(self, action: #selector(pullOut(_:)))
        back.addTarget(self, action: #selector(pullBack(_:)))
        for pan in [outward, back] { pan.delegate = self; pan.maximumNumberOfTouches = 1 }

        NotificationCenter.default.addObserver(self, selector: #selector(shed), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        stage.travel = { [weak self] realm in self?.travel(to: realm, leaving: 0) }
        stage.travelQuickly = { [weak self] realm in self?.travel(to: realm, leaving: 0, within: HomeTravel.quickDuration) }
        stage.goHome = { [weak self] in self?.returnHome() }
        stage.transfer = { [weak self] realm in self?.transfer(to: realm) }
        // A second scene replaces the first when the whole screen is rebuilt, for a new language. It starts from the scene again.
        if Self.made { stage.restart() }
        Self.made = true
        stage.onMutedChange = { [weak self] _ in self?.updateMusic(fade: 0.6) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = bounds
        for view in [under, over] { view.frame = content.bounds }
        scene.bounds = content.bounds
        scene.center = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        CATransaction.commit()
        if builtSize != bounds.size, phase == .home || phase == .away {
            // A turned or resized screen is a different world; it is drawn again when next needed.
            discard()
            if phase == .home { apply(0, realm: nil) }
            if opened { prepare() }
        }
    }

    /// Away from the scene, its pictures are only needed again on the way back; under pressure they are let go.
    @objc private func shed() {
        guard phase == .away else { return }
        discard()
    }

    private func discard() {
        for realm in realms.values { realm.container.removeFromSuperlayer(); realm.drift.removeFromSuperlayer() }
        realms = [:]; images = [:]; shown = nil; builtSize = .zero
        ground.contents = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for pan in [outward, back] {
            pan.view?.removeGestureRecognizer(pan)
            window?.addGestureRecognizer(pan)
        }
    }

    // MARK: Opening

    /// The scene is told whether the app is in front; film and music stop when it is not.
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        guard phase == .home || phase == .pullingOut else { return }
        if active { scene.play() } else { scene.pause() }
        updateMusic(fade: active ? 2.4 : 0.3)
        if active, !started {
            started = true
            // A film that never shows its first frame must not leave the app behind a blur.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.open() }
        }
    }

    /// Clears the opening blur. With a place to open in, the scene is only passed through, so it clears faster.
    private func open() {
        guard !opened else { return }
        opened = true
        #if DEBUG
        if let frozen = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--home-freeze=") })?.dropFirst(14) {
            // For screenshots: `--home-freeze=blur` keeps the opening blur, and
            // `--home-freeze=library:0.5` holds the journey to the library at its middle.
            if frozen == "blur" { scene.holdBlur(); return }
            let parts = frozen.split(separator: ":")
            if parts.count == 2, let realm = HomeRealm(rawValue: String(parts[0])), let moment = Double(parts[1]) {
                scene.open(seconds: 0.1) { [weak self] in
                    guard let self else { return }
                    self.build(); self.show(realm); self.apply(moment, realm: realm)
                    self.realms[realm]?.drift.birthRate = 1
                    self.phase = .travelling; self.stage.beginDrag(); self.stage.engagement = 1
                }
                return
            }
        }
        #endif
        stage.introStarted()
        prepare()
        let seconds = stage.preferred == nil ? 1.7 : 0.9
        scene.open(seconds: seconds) {}
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.75) { [weak self] in self?.stage.finishIntro() }
    }

    private func updateMusic(fade: TimeInterval) {
        let wanted = active && !stage.muted && (phase == .home || phase == .pullingOut || phase == .returning)
        if wanted { music.play(fade: fade) } else { music.stop(fade: min(fade, 1.2)) }
    }

    // MARK: Building the world

    /// Draws the pictures in the background, so that the first pull finds them ready.
    private func prepare() {
        let size = bounds.size
        guard size.width > 0, builtSize != size, !preparing else { return }
        preparing = true
        let requests = HomeArt.requests(for: size), scale = window?.screen.scale ?? traitCollection.displayScale
        Task.detached(priority: .userInitiated) {
            var images: [HomeArt.Request: CGImage] = [:]
            for request in requests { images[request] = HomeArt.render(request, screenScale: scale) }
            await MainActor.run { [weak self, images] in
                guard let self else { return }
                self.preparing = false
                guard self.builtSize != size, self.bounds.size == size else { return }
                self.images = images
                self.assemble(size)
            }
        }
    }

    /// The same, at once, for a finger that arrives before the background work has finished.
    private func build() {
        let size = bounds.size
        guard size.width > 0, builtSize != size else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        for request in HomeArt.requests(for: size) where images[request] == nil { images[request] = HomeArt.render(request, screenScale: scale) }
        assemble(size)
    }

    private func assemble(_ size: CGSize) {
        builtSize = size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for realm in HomeRealm.allCases { realms[realm] = HomeRealmLayers(realm: realm, size: size, images: images) }
        // The soil and its roots hang from the foot of the picture and leave with it.
        if let image = images[HomeArt.ground(size)] {
            let height = size.width * CGFloat(image.height) / CGFloat(image.width)
            ground.contents = image
            // It starts just under the screen: not a blade of its grass shows until the picture moves.
            ground.frame = CGRect(x: 0, y: size.height - 1, width: size.width, height: height)
        }
        CATransaction.commit()
        // The layers keep the pictures from here on.
        images = [:]
    }

    private func show(_ realm: HomeRealm?) {
        guard shown != realm else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let shown, let old = realms[shown] {
            old.container.removeFromSuperlayer(); old.drift.removeFromSuperlayer()
            old.drift.birthRate = 0
        }
        shown = realm
        if let realm, let layers = realms[realm] {
            under.layer.addSublayer(layers.container)
            over.layer.addSublayer(layers.drift)
            ground.isHidden = realm != .library
        }
        CATransaction.commit()
    }

    // MARK: The journey as numbers

    private struct Pose {
        /// How far the picture and the world have moved with the camera.
        var slide: CGFloat
        /// How much more, or less, each plane has moved than the world it stands in.
        var planes: [CGFloat]
        var drift: Float
    }

    private func pose(_ t: Double, realm: HomeRealm?) -> Pose {
        let direction = realm?.direction ?? 1
        let slide = -direction * HomeTravel.camera(t) * Double(bounds.height)
        return Pose(slide: CGFloat(slide), planes: (realm.flatMap { realms[$0] }?.planes ?? []).map { CGFloat(slide * ($0.depth - 1)) },
                    drift: Float(HomeTravel.drift(t)))
    }

    /// Places every layer where it stands at one moment of the journey.
    private func apply(_ t: Double, realm: HomeRealm?) {
        moment = t
        let pose = pose(t, realm: realm)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.layer.transform = CATransform3DMakeTranslation(0, pose.slide, 0)
        if let realm, let layers = realms[realm] {
            layers.world.transform = CATransform3DMakeTranslation(0, pose.slide, 0)
            layers.edge.transform = CATransform3DMakeTranslation(0, pose.slide, 0)
            for (plane, offset) in zip(layers.planes, pose.planes) { plane.layer.transform = CATransform3DMakeTranslation(0, offset, 0) }
            layers.drift.opacity = pose.drift
        }
        CATransaction.commit()
    }

    /// Plays the journey through the given moments. The render server runs it; the main thread is free at once.
    private func run(_ moments: [Double], seconds: Double, realm: HomeRealm, completion: @escaping () -> Void) {
        guard let layers = realms[realm], let last = moments.last else { completion(); return }
        let poses = moments.map { pose($0, realm: realm) }
        journey += 1
        let current = journey
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.journey == current else { return }
            completion()
        }
        func play(_ layer: CALayer, _ keyPath: String, _ values: [NSNumber]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = seconds
            animation.calculationMode = .linear
            layer.add(animation, forKey: "home." + keyPath)
        }
        let slide = poses.map { NSNumber(value: Double($0.slide)) }
        for layer in [scene.layer, layers.world, layers.edge] { play(layer, "transform.translation.y", slide) }
        for (index, plane) in layers.planes.enumerated() {
            play(plane.layer, "transform.translation.y", poses.map { NSNumber(value: Double($0.planes[index])) })
        }
        play(layers.drift, "opacity", poses.map { NSNumber(value: $0.drift) })
        apply(last, realm: realm)
        CATransaction.commit()
    }

    private func startDrift(_ realm: HomeRealm, returning: Bool) {
        guard let drift = realms[realm]?.drift else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // On the way back the dust and the stars pass the other way.
        drift.setAffineTransform(CGAffineTransform(scaleX: 1, y: returning ? -1 : 1))
        drift.birthRate = 1
        drift.beginTime = CACurrentMediaTime() - 3
        CATransaction.commit()
    }

    // MARK: Leaving home

    /// The place on screen once the scene has been left.
    private var placeRealm: HomeRealm { stage.place == .study ? .study : .library }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === outward || recognizer === back else { return super.gestureRecognizerShouldBegin(recognizer) }
        // Only the scene and the two places it leads to are pulled, not what is opened over them.
        guard stage.enabled, let window, window.rootViewController?.presentedViewController == nil,
              let pan = recognizer as? UIPanGestureRecognizer else { return false }
        let speed = pan.velocity(in: window), start = pan.location(in: window).y - pan.translation(in: window).y
        if recognizer === outward { return phase == .home && stage.atHome && abs(speed.y) > abs(speed.x) }
        guard phase == .away, !stage.moving else { return false }
        if placeRealm == .library {
            // The library came down from the scene: it is pulled down from its top bar to go back up.
            return start <= window.safeAreaInsets.top + 64 && speed.y > 0 && speed.y > abs(speed.x) * 1.2
        }
        // Learning mode rose from it: it is swept up from its dock to come back down.
        return start >= window.bounds.height - window.safeAreaInsets.bottom - 96 && speed.y < 0 && -speed.y > abs(speed.x) * 1.2
    }

    /// A pull that starts on a bar belongs to the scene; a list under it waits for it to give up first.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        (recognizer === back || recognizer === outward) && other.view is UIScrollView
    }

    @objc private func pullOut(_ recognizer: UIPanGestureRecognizer) {
        let offset = recognizer.translation(in: self).y, height = bounds.height
        switch recognizer.state {
        case .began:
            guard phase == .home else { return }
            phase = .pullingOut
            armed = false
            build()
            stage.beginDrag()
            nudge.prepare()
        case .changed:
            guard phase == .pullingOut, abs(offset) > 0.5 else { return }
            let realm: HomeRealm = offset < 0 ? .library : .study
            if shown != realm { show(realm); startDrift(realm, returning: false); stage.leanToward(realm) }
            apply(HomeTravel.progress(drag: abs(offset), height: height), realm: realm)
            stage.engagement = min(1, Double(abs(offset)) / 70)
            let reached = abs(offset) > height * HomeTravel.commit
            if reached != armed { armed = reached; nudge.impactOccurred(intensity: reached ? 0.9 : 0.5) }
        case .ended, .cancelled, .failed:
            guard phase == .pullingOut else { return }
            let speed = recognizer.velocity(in: self).y
            let onward = offset * speed >= 0 || abs(speed) < 120
            let flicked = abs(speed) > HomeTravel.flick && offset * speed > 0 && abs(offset) > 24
            if recognizer.state == .ended, let realm = shown, (abs(offset) > height * HomeTravel.commit && onward) || flicked {
                // The finger's speed carries on into the journey.
                let pace = Double(abs(speed) / height) / max(0.2, HomeTravel.cameraSpeed(moment))
                travel(to: realm, leaving: onward ? pace : 0)
            } else {
                settleHome()
            }
        default: break
        }
    }

    private func settleHome() {
        guard let realm = shown, moment > 0.0005 else { finishHome(); return }
        phase = .returning
        withAnimation(.easeOut(duration: 0.3)) { stage.engagement = 0 }
        run(HomeTravel.moments(from: moment, to: 0, seconds: 0.5, landing: 0), seconds: 0.5, realm: realm) { [weak self] in self?.finishHome() }
    }

    private func finishHome() {
        show(nil)
        apply(0, realm: nil)
        content.alpha = 1; content.isHidden = false
        isUserInteractionEnabled = true
        phase = .home
        stage.cancelDrag()
        if stage.place != .home { stage.arriveHome() }
        if let next = onward {
            // Only passing through: the scene's words stay away, and the second journey leaves at once.
            onward = nil
            stage.engagement = 1
            travel(to: next, leaving: 0)
            return
        }
        updateMusic(fade: 1.2)
    }

    /// Goes from the place on screen to the other one, all the way back through the scene and out again.
    func transfer(to realm: HomeRealm) {
        guard phase == .away, placeRealm != realm else { return }
        onward = realm
        returnHome()
    }

    /// Travels to a place from wherever the scene now stands.
    func travel(to realm: HomeRealm, leaving pace: Double, within duration: Double = HomeTravel.duration) {
        guard phase == .home || phase == .pullingOut else { return }
        build()
        if shown != realm { show(realm); startDrift(realm, returning: false); apply(moment, realm: realm) }
        phase = .travelling
        stage.depart(to: realm)
        withAnimation(.easeOut(duration: 0.25)) { stage.engagement = 1 }
        music.stop(fade: 1.4)
        land.prepare()
        if UIAccessibility.isReduceMotionEnabled {
            fade(to: 0) { [weak self] in self?.finishAway(realm) }
            return
        }
        let seconds = max(1.1, duration * (1 - moment))
        run(HomeTravel.moments(from: moment, to: 1, seconds: seconds, leaving: pace), seconds: seconds, realm: realm) { [weak self] in self?.finishAway(realm) }
        // The world's edge is felt as it goes by.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.62) { [weak self] in
            guard let self, self.phase == .travelling else { return }
            self.land.impactOccurred(intensity: 0.6)
        }
    }

    private func finishAway(_ realm: HomeRealm) {
        scene.pause()
        realms[realm]?.drift.birthRate = 0
        content.isHidden = true; content.alpha = 1
        isUserInteractionEnabled = false
        phase = .away
        stage.arrive(at: realm)
    }

    /// With motion reduced, a place and the scene simply fade into each other.
    private func fade(to opacity: CGFloat, completion: @escaping () -> Void) {
        journey += 1
        let current = journey
        UIView.animate(withDuration: 0.45, animations: { self.content.alpha = opacity }) { [weak self] _ in
            guard let self, self.journey == current else { return }
            completion()
        }
    }

    // MARK: Coming back

    @objc private func pullBack(_ recognizer: UIPanGestureRecognizer) {
        guard let window else { return }
        // The world's edge comes back in under the finger: the cave's roof from above, the clouds from below.
        let travelled = recognizer.translation(in: window).y * (placeRealm == .library ? 1 : -1)
        let offset = max(0, travelled), height = bounds.height
        switch recognizer.state {
        case .began:
            guard phase == .away else { return }
            beginReturn()
            phase = .pullingBack
            nudge.prepare()
        case .changed:
            guard phase == .pullingBack, let realm = shown else { return }
            if UIAccessibility.isReduceMotionEnabled { content.alpha = min(0.6, offset / height * 2) }
            else { apply(HomeTravel.progress(pull: offset, height: height), realm: realm) }
            stage.pull = offset
            let reached = offset > height * HomeTravel.returnCommit
            if reached != armed { armed = reached; stage.pullArmed = reached; nudge.impactOccurred(intensity: reached ? 0.9 : 0.5) }
        case .ended, .cancelled, .failed:
            guard phase == .pullingBack, let realm = shown else { return }
            let speed = recognizer.velocity(in: window).y * (placeRealm == .library ? 1 : -1)
            let committed = recognizer.state == .ended && ((offset > height * HomeTravel.returnCommit && speed > -120) || (speed > HomeTravel.flick && offset > 24))
            if committed { returnHome() } else { settleAway(realm) }
        default: break
        }
    }

    /// Brings the scene back over the place, with the world's edge waiting just out of sight.
    private func beginReturn() {
        let realm = placeRealm
        build()
        armed = false
        content.isHidden = false
        isUserInteractionEnabled = true
        show(realm)
        startDrift(realm, returning: true)
        if UIAccessibility.isReduceMotionEnabled { apply(0, realm: nil); content.alpha = 0 }
        else { apply(HomeTravel.progress(pull: 0, height: bounds.height), realm: realm) }
        stage.beginReturn()
    }

    private func settleAway(_ realm: HomeRealm) {
        phase = .travelling
        withAnimation(.easeOut(duration: 0.25)) { stage.pull = 0; stage.pullArmed = false }
        let done: () -> Void = { [weak self] in
            guard let self else { return }
            self.content.isHidden = true; self.content.alpha = 1
            self.isUserInteractionEnabled = false
            self.realms[realm]?.drift.birthRate = 0
            self.phase = .away
            self.stage.cancelReturn()
        }
        if UIAccessibility.isReduceMotionEnabled { fade(to: 0, completion: done); return }
        run(HomeTravel.moments(from: moment, to: 1, seconds: 0.4, landing: 0), seconds: 0.4, realm: realm, completion: done)
    }

    /// Travels back to the home scene from the place on screen.
    func returnHome() {
        if phase == .away { beginReturn() }
        guard phase == .away || phase == .pullingBack else { return }
        let realm = shown ?? placeRealm
        phase = .returning
        withAnimation(.easeOut(duration: 0.25)) { stage.pull = 0; stage.pullArmed = false }
        if active { scene.play() }
        if onward == nil { updateMusic(fade: 2.2) }
        if UIAccessibility.isReduceMotionEnabled {
            fade(to: 1) { [weak self] in self?.finishHome() }
            return
        }
        let seconds = max(1.2, HomeTravel.returnDuration * moment)
        run(HomeTravel.moments(from: moment, to: 0, seconds: seconds, landing: 0), seconds: seconds, realm: realm) { [weak self] in self?.finishHome() }
    }
}

struct HomeStageHost: UIViewRepresentable {
    let stage: HomeStage
    let active: Bool
    func makeUIView(context: Context) -> HomeStageView { HomeStageView(stage: stage) }
    func updateUIView(_ view: HomeStageView, context: Context) { view.setActive(active) }
}
