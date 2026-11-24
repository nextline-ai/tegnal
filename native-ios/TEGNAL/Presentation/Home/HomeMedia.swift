import AVFoundation
import UIKit

/// The night colours at the head and foot of the illustration, which the sky and the ground continue.
/// A home scene bought in the shop may bring colours of its own (`HomeScenes`).
enum HomePalette {
    static var sky: UIColor { color("sky", 0x0B0717) }
    static var ground: UIColor { color("ground", 0x1E1430) }
    static var dusk: UIColor { color("dusk", 0x2A1E51) }

    private static func color(_ name: String, _ fallback: UInt32) -> UIColor {
        let value = HomeScenes.color(name) ?? fallback
        return UIColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum HomeMediaFile {
    /// The chosen home scene's file for `home_intro`, `home_loop` or `home_theme`, else the app's own.
    static func url(_ name: String, _ type: String) -> URL? {
        if let chosen = HomeScenes.url(String(name.dropFirst("home_".count))) { return chosen }
        return Bundle.main.url(forResource: name, withExtension: type, subdirectory: "HomeMedia")
    }
}

/// How the app sounds. Everything it plays is media: the volume buttons set it, the silent switch
/// leaves it alone, and it plays alongside whatever the listener already has on.
enum AppAudio {
    static func useMediaVolume() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    }
}

/// How the picture sits on a screen. A phone shows all of it. A tablet or a Mac window is another
/// shape, so the picture fills it and closes in on the word TEGNAL.
enum HomeFraming {
    static let pictureSize = CGSize(width: 1206, height: 2622)
    /// The middle of the word TEGNAL, as a share of the picture's width and height.
    static let focus = CGPoint(x: 0.5, y: 0.388)

    /// Where the whole picture lies so that it covers a screen of this size with its focus in the middle,
    /// or as near the middle as the picture's own edges allow.
    static func frame(in size: CGSize) -> CGRect {
        let scale = max(size.width / pictureSize.width, size.height / pictureSize.height)
        let width = pictureSize.width * scale, height = pictureSize.height * scale
        return CGRect(x: min(0, max(size.width - width, size.width / 2 - width * focus.x)),
                      y: min(0, max(size.height - height, size.height / 2 - height * focus.y)), width: width, height: height)
    }
}

/// The film's first frame, already blurred: what the app shows while it starts, what the scene opens
/// from, and what covers the app in the app switcher. It is framed exactly as the film is.
@MainActor final class HomeStillView: UIView {
    /// A plain file in the app, not a catalogue entry: the system's launch screen can only read it that way.
    /// A home scene bought in the shop brings its own, which the app shows once it has started.
    static var picture: UIImage? { HomeScenes.url("still").flatMap { UIImage(contentsOfFile: $0.path) } ?? UIImage(named: "HomeBlur.jpg") }
    let imageView = UIImageView(image: HomeStillView.picture)

    init() {
        super.init(frame: .zero)
        backgroundColor = HomePalette.dusk
        clipsToBounds = true
        isOpaque = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = HomeFraming.frame(in: bounds.size)
    }
}

/// The illustration itself: its opening film once, then its loop for as long as the scene is watched.
@MainActor final class HomeSceneView: UIView {
    private let player = AVQueuePlayer()
    private let picture = UIView()
    private let videoLayer = AVPlayerLayer()
    private let headShade = CAGradientLayer()
    private let footShade = CAGradientLayer()
    private let veil = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let still = HomeStillView()
    /// The system's launch screen is plain black, so that every home scene can follow it; the scene fades in from that black.
    private let curtain = UIView()
    private var loopAsset: AVURLAsset?
    private var ending: NSObjectProtocol?
    private var ready: NSKeyValueObservation?
    private var clearing: UIViewPropertyAnimator?
    private var opening = false
    private var cleared = false
    private var wantsPlayback = false
    /// Called once the first frame of the film can be shown.
    var onFirstFrame: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HomePalette.dusk
        isOpaque = true
        clipsToBounds = false
        picture.clipsToBounds = true
        addSubview(picture)

        videoLayer.player = player
        videoLayer.videoGravity = .resizeAspectFill
        picture.layer.addSublayer(videoLayer)

        // The picture ends in the same dark as the sky above it and the soil under it, whatever part of it the screen shows.
        headShade.colors = [HomePalette.sky.cgColor, HomePalette.sky.withAlphaComponent(0).cgColor]
        footShade.colors = [HomePalette.ground.withAlphaComponent(0).cgColor, HomePalette.ground.cgColor]
        for shade in [headShade, footShade] { picture.layer.addSublayer(shade) }

        // The scene opens from a blur. The still on top is that same blur as a picture, the one the
        // system showed while the app started, so nothing changes on screen when the app takes over.
        veil.overrideUserInterfaceStyle = .dark
        veil.isUserInteractionEnabled = false
        addSubview(veil)
        addSubview(still)
        curtain.backgroundColor = .black
        curtain.isUserInteractionEnabled = false
        addSubview(curtain)
        picture.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)

        player.isMuted = true
        player.actionAtItemEnd = .advance
        player.allowsExternalPlayback = false
        // A film that loops for ever must not keep the screen awake for ever.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        load()
        // Another home scene chosen in the shop plays from its first frame of loop.
        sceneChange = NotificationCenter.default.addObserver(forName: HomeScenes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.swapScene() }
        }
    }

    private var sceneChange: NSObjectProtocol?

    /// Plays the chosen scene's loop in place of the one playing, with its colours. The opening film is for opening the app.
    private func swapScene() {
        backgroundColor = HomePalette.dusk
        headShade.colors = [HomePalette.sky.cgColor, HomePalette.sky.withAlphaComponent(0).cgColor]
        footShade.colors = [HomePalette.ground.withAlphaComponent(0).cgColor, HomePalette.ground.cgColor]
        guard let loop = HomeMediaFile.url("home_loop", "mp4") else { return }
        let asset = AVURLAsset(url: loop)
        loopAsset = asset
        let playing = player.rate > 0
        player.removeAllItems()
        for _ in 0..<2 { player.insert(AVPlayerItem(asset: asset), after: nil) }
        if playing || (cleared && wantsPlayback) { player.play() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func load() {
        guard let loop = HomeMediaFile.url("home_loop", "mp4") else { return }
        let asset = AVURLAsset(url: loop)
        loopAsset = asset
        if let intro = HomeMediaFile.url("home_intro", "mp4") { player.insert(AVPlayerItem(asset: AVURLAsset(url: intro)), after: nil) }
        for _ in 0..<2 { player.insert(AVPlayerItem(asset: asset), after: nil) }
        // Each time the loop ends, another copy joins the queue behind the one now playing: no gap, no seek.
        ending = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.extend() }
        }
        ready = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in
                guard let self, self.ready != nil else { return }
                self.ready = nil
                self.onFirstFrame?()
            }
        }
    }

    private func extend() {
        guard let loopAsset, player.items().count < 3 else { return }
        player.insert(AVPlayerItem(asset: loopAsset), after: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.bounds = CGRect(origin: .zero, size: bounds.size)
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let size = bounds.size
        // On a phone this is the whole picture; on a wider screen, a close-up around the word TEGNAL.
        videoLayer.frame = HomeFraming.frame(in: size)
        headShade.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.16)
        footShade.frame = CGRect(x: 0, y: size.height * 0.9, width: size.width, height: size.height * 0.1)
        veil.frame = bounds
        still.frame = bounds
        curtain.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, curtain.superview != nil, curtain.alpha == 1 else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.5, delay: 0.05, options: [.curveEaseOut]) {
            self.curtain.alpha = 0
        } completion: { _ in self.curtain.removeFromSuperview() }
    }

    /// Shows the blur the live way, without its still, and keeps it. For taking the still's picture.
    func holdBlur() {
        opening = true
        still.isHidden = true
    }

    /// Lets go of the still, clears the blur, and only then starts the film.
    func open(seconds: TimeInterval, completion: @escaping () -> Void) {
        guard !opening else { return }
        opening = true
        let reduced = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut]) { self.still.alpha = 0 } completion: { _ in
            self.still.removeFromSuperview(); self.still.imageView.image = nil
        }
        let animator = UIViewPropertyAnimator(duration: reduced ? 0.5 : seconds, controlPoint1: CGPoint(x: 0.3, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1)) {
            self.veil.effect = nil
            self.picture.transform = .identity
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.veil.removeFromSuperview()
            self.clearing = nil
            self.cleared = true
            if self.wantsPlayback { self.player.play() }
            completion()
        }
        clearing = animator
        animator.startAnimation(afterDelay: 0.12)
    }

    /// The film plays while the scene is watched. Before the blur has cleared it waits on its first frame.
    func play() {
        wantsPlayback = true
        if cleared { player.play() }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
    }
}

/// The scene's music. It says, the moment the app opens, that the sound is on: it plays whatever
/// the silent switch says, at the volume the buttons set. Someone already listening to something
/// else keeps it and hears no music here.
@MainActor final class HomeMusic {
    static let level: Float = 0.85
    private var player: AVAudioPlayer?
    private var loading = false
    private var wanted = false
    private var quiet: Task<Void, Never>?

    private var sceneChange: NSObjectProtocol?

    init() {
        // Another home scene's music is read the next time the music starts.
        sceneChange = NotificationCenter.default.addObserver(forName: HomeScenes.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let playing = self.player?.isPlaying ?? false
                self.player?.stop()
                self.player = nil
                if playing { self.load(fade: 0.6) }
            }
        }
    }

    func play(fade: TimeInterval) {
        wanted = true
        quiet?.cancel(); quiet = nil
        guard let player else { load(fade: fade); return }
        start(player, fade: fade)
    }

    private func load(fade: TimeInterval) {
        guard !loading, let url = HomeMediaFile.url("home_theme", "mp3") else { return }
        loading = true
        // Opening the file is kept off the main thread, away from the first frames.
        Task.detached(priority: .utility) {
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.prepareToPlay()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                self.player = player
                if self.wanted, let player { self.start(player, fade: fade) }
            }
        }
    }

    private func start(_ player: AVAudioPlayer, fade: TimeInterval) {
        let session = AVAudioSession.sharedInstance()
        if !player.isPlaying {
            guard !session.isOtherAudioPlaying else { return }
            AppAudio.useMediaVolume()
            try? session.setActive(true)
            player.volume = 0
            guard player.play() else { return }
        }
        player.setVolume(Self.level, fadeDuration: fade)
    }

    func stop(fade: TimeInterval) {
        wanted = false
        guard let player, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: fade)
        quiet?.cancel()
        quiet = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(fade + 0.05)) } catch { return }
            guard let self, !self.wanted else { return }
            self.player?.pause()
        }
    }
}
