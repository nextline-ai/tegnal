import SwiftUI
import Observation

/// The two places the home scene leads to: the library below the ground, learning mode above the clouds.
enum HomeRealm: String, Sendable, CaseIterable {
    case library, study
    /// Which way the world moves on screen while travelling there: up when sinking, down when rising.
    var direction: Double { self == .library ? 1 : -1 }
    var code: Character { self == .library ? "L" : "S" }
}

/// Which places were opened lately. The library reads its first pages from the network as the app
/// opens, and that is only worth doing for someone who goes there.
struct HomeHabit: Equatable {
    static let key = "home.recentPlaces"
    static let limit = 8
    /// One letter for each place opened, the newest last.
    private(set) var recent: String

    init(recent: String = "") { self.recent = String(recent.filter { $0 == "L" || $0 == "S" }.suffix(Self.limit)) }

    /// Before anything is known, the choice made while setting up the app stands in.
    func prefersLibrary(startsLearning: Bool) -> Bool {
        recent.isEmpty ? !startsLearning : recent.contains(HomeRealm.library.code)
    }

    mutating func record(_ realm: HomeRealm) {
        recent = String((recent + String(realm.code)).suffix(Self.limit))
    }
}

/// The journey between the home scene (0) and a place (1), as plain numbers, so that the finger,
/// the animation and the tests all read the same curve.
///
/// The world is one tall picture. The home scene is its middle; the ground under it ends in the
/// roof of a cave, with the library in the open space below, and the sky over it ends in the top
/// of the clouds, with learning mode above them. A journey is the camera moving along it.
enum HomeTravel {
    /// Seconds from letting go at the home scene to standing in the place.
    static let duration = 2.2
    /// The same when the app opens straight into a place: the scene is passed through, not stayed in.
    static let quickDuration = 1.7
    /// Seconds for the way back.
    static let returnDuration = 1.9
    /// How far from the home scene the ground or the sky ends, in screen heights.
    static let depth = 2.2
    /// What reaches past that end: what hangs from the cave's roof, the tops of the clouds, and the shade or mist beyond them.
    static let overhang = 0.5
    /// How far the camera moves in all: to the end, across the screen, and clear of what reaches past it.
    static let distance = depth + 1 + overhang
    /// How much of that reach is already back in view when a place starts being pulled; it is the faint end of the shade.
    static let slack = 0.25
    /// How far a finger has to pull, as a share of the screen's height, for letting go to travel.
    static let commit = 0.17
    /// The same for pulling a place back toward the scene.
    static let returnCommit = 0.14
    /// A flick this fast travels without the distance.
    static let flick: CGFloat = 900
    private static let lead = 0.6

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    static func smooth(_ value: Double) -> Double { let u = clamp(value); return u * u * (3 - 2 * u) }

    /// A curve from 0 to 1 that leaves with one slope and arrives with another.
    static func hermite(_ s: Double, from start: Double, to end: Double) -> Double {
        let u = clamp(s), u2 = u * u, u3 = u2 * u
        return start * (u3 - 2 * u2 + u) + (3 * u2 - 2 * u3) + end * (u3 - u2)
    }

    /// The camera's place in screen heights. It leaves at once, so that it can follow a finger, and comes gently to rest.
    static func camera(_ t: Double) -> Double { distance * hermite(t, from: lead, to: 0) }

    /// How fast the camera moves, in screen heights for each unit of the journey.
    static func cameraSpeed(_ t: Double) -> Double {
        let step = 0.001, low = max(0, t - step), high = min(1, t + step)
        return (camera(high) - camera(low)) / (high - low)
    }

    /// The moment of the journey at which the camera has moved this far.
    static func progress(camera target: Double) -> Double {
        guard target > 0 else { return 0 }
        guard target < distance else { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<26 {
            let middle = (low + high) / 2
            if camera(middle) < target { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// How far the world has followed a finger, in screen heights: closely at first, then more and more loosely.
    static func follow(_ pulled: CGFloat, height: CGFloat) -> Double {
        guard height > 0, pulled > 0 else { return 0 }
        return 0.9 * (1 - exp(-Double(pulled / height) * 1.11))
    }

    /// The moment a finger at the home scene has pulled to.
    static func progress(drag: CGFloat, height: CGFloat) -> Double { progress(camera: follow(drag, height: height)) }

    /// The moment a finger pulling a place back has reached: the world's edge comes back in under it.
    static func progress(pull: CGFloat, height: CGFloat) -> Double {
        progress(camera: distance - slack - follow(pull, height: height))
    }

    /// Dust or stars drifting past, while moving.
    static func drift(_ t: Double) -> Double { smooth(t / 0.1) * (1 - smooth((t - 0.6) / 0.25)) }

    /// The moments an animation passes through, one for each frame, between two points of the journey.
    /// `leaving` is how fast the journey was already moving when the finger let go, in units a second.
    static func moments(from start: Double, to end: Double, seconds: Double, leaving: Double = 0, landing: Double = 1) -> [Double] {
        let span = end - start
        guard abs(span) > 0.0001, seconds > 0 else { return [end, end] }
        let slope = min(2.6, max(0.35, leaving * seconds / abs(span)))
        let frames = max(2, Int((seconds * 90).rounded()))
        return (0...frames).map { start + span * hermite(Double($0) / Double(frames), from: slope, to: landing) }
    }
}

/// What the app is showing, and what the home scene has to do next.
@MainActor @Observable
final class HomeStage {
    static let shared = HomeStage()
    static let mutedKey = "home.musicOff"
    static let hintKey = "home.returnHintsShown"

    enum Place: Equatable { case home, library, study }

    /// Tests that drive the library or learning mode directly start without the scene.
    let enabled: Bool
    /// The place on screen once nothing is moving.
    private(set) var place: Place
    /// A journey is under way, by finger or on its own.
    private(set) var moving = false
    /// The opening blur has cleared.
    private(set) var introFinished = false
    /// The library may read its first pages from the network.
    private(set) var libraryWarm: Bool
    /// The library's screens exist.
    private(set) var libraryMounted: Bool
    /// The learning screens exist. They are small and are built on the way there.
    private(set) var studyMounted: Bool
    /// The library has been on screen, so its own background work may run.
    private(set) var libraryOpened: Bool
    /// How far the hints at the home scene have faded under a finger, from 0 to 1.
    var engagement: Double = 0
    /// How far a place has been pulled down, and whether letting go now goes back.
    var pull: CGFloat = 0
    var pullArmed = false
    /// The scene's hints are held back until the logo has arrived.
    private(set) var hintsReady = false
    var muted: Bool { didSet { defaults.set(muted, forKey: Self.mutedKey); onMutedChange?(muted) } }
    /// Set by the scene's view, which does the travelling.
    @ObservationIgnored var travel: ((HomeRealm) -> Void)?
    @ObservationIgnored var travelQuickly: ((HomeRealm) -> Void)?
    @ObservationIgnored var goHome: (() -> Void)?
    @ObservationIgnored var transfer: ((HomeRealm) -> Void)?
    @ObservationIgnored var onMutedChange: ((Bool) -> Void)?
    @ObservationIgnored private let defaults = ReaderPreferences.defaults
    @ObservationIgnored private var habit: HomeHabit
    @ObservationIgnored private let prefersLibrary: Bool

    /// The scene covers the screen: nothing underneath should ask a question or speak.
    var coversScreen: Bool { enabled && (place == .home || moving) }
    var atHome: Bool { enabled && place == .home }

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        var enabled = true
        #if DEBUG
        if ContentUITestSupport.enabled || ContentUITestSupport.unitTestsEnabled {
            enabled = arguments.contains("--splash-ui-test") || arguments.contains("--home-test") || arguments.contains { $0.hasPrefix("--home-freeze=") }
        }
        #endif
        self.enabled = enabled
        muted = defaults.bool(forKey: Self.mutedKey)
        habit = HomeHabit(recent: defaults.string(forKey: HomeHabit.key) ?? "")
        let studying = StudyMode.shared.active
        prefersLibrary = StudyMode.shared.startsInLibrary || habit.prefersLibrary(startsLearning: StudyMode.shared.startsActive)
        if enabled {
            place = .home
            libraryWarm = prefersLibrary
            libraryMounted = false
            studyMounted = false
            libraryOpened = false
        } else {
            place = studying ? .study : .library
            libraryWarm = true
            libraryMounted = true
            studyMounted = true
            libraryOpened = true
        }
    }

    /// The place the app is set to open in, if any. The scene is then passed through quickly, not skipped.
    var preferred: HomeRealm? { StudyMode.shared.startsActive ? .study : StudyMode.shared.startsInLibrary ? .library : nil }
    @ObservationIgnored private var openedPreferred = false

    /// Goes on to the place the app is set to open in, once: after the opening blur, or after the app has been set up.
    func openPreferred(after delay: TimeInterval = 0) {
        guard enabled, !openedPreferred, introFinished, let realm = preferred else { return }
        openedPreferred = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.place == .home, !self.moving else { return }
            self.travelQuickly?(realm)
        }
    }

    /// The first picture is on screen. Someone who goes to the library has it built now, behind the scene.
    func introStarted() {
        guard enabled, prefersLibrary, !libraryMounted else { return }
        let wait = preferred == .library ? 50 : 700
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            self?.libraryMounted = true
        }
    }

    func finishIntro() {
        introFinished = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            withAnimation(.easeInOut(duration: 1.2)) { self?.hintsReady = true }
        }
    }

    /// A finger is heading for the library: its first pages can be on their way before it lets go.
    func leanToward(_ realm: HomeRealm) {
        if realm == .library, !libraryWarm { libraryWarm = true }
    }

    /// Letting go has chosen a place. Its screens are built under the scene while the journey plays.
    func depart(to realm: HomeRealm) {
        moving = true
        habit.record(realm)
        defaults.set(habit.recent, forKey: HomeHabit.key)
        if realm == .library { libraryWarm = true }
        // The journey is handed to the render server first; the screens are built a moment later, under it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            var quiet = Transaction(); quiet.disablesAnimations = true
            withTransaction(quiet) {
                StudyMode.shared.active = realm == .study
                // The home scene's learning mode is the AI lab; only the library's 2D AI entries ask for the course itself.
                if realm == .study { StudyMode.shared.arrive() }
                if realm == .library { self.libraryMounted = true } else { self.studyMounted = true }
            }
        }
    }

    func arrive(at realm: HomeRealm) {
        place = realm == .library ? .library : .study
        if realm == .library { libraryOpened = true }
        moving = false; engagement = 0; pull = 0; pullArmed = false
    }

    func beginReturn() { moving = true }
    func cancelReturn() { moving = false; pull = 0; pullArmed = false }
    func beginDrag() { moving = true }
    func cancelDrag() { moving = false; engagement = 0 }

    func arriveHome() {
        place = .home
        moving = false; engagement = 0; pull = 0; pullArmed = false
        StudySound.rest()
    }

    /// Goes from the place on screen to the other one by way of the home scene: back along one journey and out along the other.
    /// False where the scene is not in use, or is itself on screen; the caller then switches places as before.
    func cross(to realm: HomeRealm) -> Bool {
        guard enabled, place != .home, let transfer else { return false }
        if !moving, place != (realm == .study ? .study : .library) { transfer(realm) }
        return true
    }

    /// A new copy of the scene has been made, as happens when the app's language changes: everything starts again from it.
    func restart() {
        place = .home
        moving = false; introFinished = false; hintsReady = false
        engagement = 0; pull = 0; pullArmed = false
    }

    /// Where the scene is not in use, learning mode and the library still open each other directly; the scene keeps up with whichever shows.
    func follow(studying: Bool) {
        guard enabled, place != .home, !moving else { return }
        place = studying ? .study : .library
        if studying { studyMounted = true } else { libraryWarm = true; libraryMounted = true; libraryOpened = true }
    }

    /// The way back is shown the first few times a place is reached.
    func takeReturnHint() -> Bool {
        let shown = defaults.integer(forKey: Self.hintKey)
        guard shown < 3 else { return false }
        defaults.set(shown + 1, forKey: Self.hintKey)
        return true
    }
}
