import SwiftUI
import Observation

/// Whether the app is showing learning mode, which takes over the whole screen, dock included.
@MainActor @Observable
final class StudyMode {
    static let shared = StudyMode()
    static let startKey = "study.startInMode"
    private let defaults = ReaderPreferences.booruDefaults
    var active: Bool
    /// The tab learning mode opens on the next time it is entered.
    var tab = StudyTab.path
    /// The course on screen (`LearningCourse.id`). Learning mode opens on the AI lab; the 코스 tab switches to another.
    private(set) var courseID: String
    /// The lab tab shown, in whichever deck course is on screen.
    var labTab = LabTab.deck
    /// The engine of the course on screen, which decides the screens learning mode shows.
    var engine: LearningCourse.Engine { LearningCourses.shared.course(courseID)?.engine ?? .deck }
    /// Set by the library's 2D AI entries just before the way through the home scene, so learning mode opens on that course.
    private var wanted: String?
    /// Learning mode has been reached through the home scene: the lab, unless a 2D AI entry asked for the course.
    func arrive() {
        show(wanted ?? LearningCourse.labID)
        wanted = nil
    }
    /// Open straight into learning mode when the app starts.
    var startsActive: Bool { didSet { defaults.set(startsActive, forKey: Self.startKey); if startsActive, startsInLibrary { startsInLibrary = false } } }
    /// Go straight on from the opening scene into the library when the app starts. Only one of the two can be on.
    static let libraryStartKey = "home.startInLibrary"
    var startsInLibrary: Bool { didSet { defaults.set(startsInLibrary, forKey: Self.libraryStartKey); if startsInLibrary, startsActive { startsActive = false } } }

    private init() {
        let starts = defaults.bool(forKey: Self.startKey)
        startsActive = starts
        startsInLibrary = !starts && defaults.bool(forKey: Self.libraryStartKey)
        let arguments = ProcessInfo.processInfo.arguments
        active = starts || arguments.contains("--study-mode") || arguments.contains("--lab-mode")
        // `--study-mode` opens the tag course itself, for its own tests; `--lab-mode` opens the lab.
        courseID = arguments.contains("--study-mode") ? LearningCourse.tagsID : LearningCourse.labID
    }
    /// Opens learning mode on the AI lab.
    func enterLab(_ tab: LabTab = .deck) {
        show(LearningCourse.labID)
        wanted = nil
        labTab = tab
        if active { return }
        if HomeStage.shared.cross(to: .study) { return }
        withAnimation(.snappy(duration: 0.35)) { active = true }
    }
    /// Switches to a course from the 코스 tab. A course not bought yet leaves the lab on its 코스 tab, where it is sold.
    func open(_ id: String, tab: StudyTab = .path) {
        guard let course = LearningCourses.shared.course(id), LearningCourses.shared.owned(course) else {
            show(LearningCourse.labID); labTab = .courses; return
        }
        self.tab = tab
        withAnimation(.snappy(duration: 0.35)) { show(id) }
    }
    /// Puts a course on screen. A deck course lands on its cards; leaving the 2D course quiets its sounds.
    private func show(_ id: String) {
        guard let course = LearningCourses.shared.course(id) else { return show(LearningCourse.labID) }
        if engine == .tags, id != courseID { StudySound.rest() }
        if let deck = course.deck { LabStore.shared.show(course: deck); if id != courseID { labTab = .deck } }
        courseID = id
    }
    /// Opens learning mode. From the library, the way there leads back up through the home scene and on into the sky.
    func enter(_ tab: StudyTab = .path) {
        self.tab = tab
        // The library's tag-study entries lead to the course when it is owned, and to the lab's 코스 tab, where it is sold, when not.
        LabStore.shared.reload()
        if LabStore.shared.ownsTagCourse { show(LearningCourse.tagsID); wanted = LearningCourse.tagsID } else { show(LearningCourse.labID); labTab = .courses }
        if HomeStage.shared.cross(to: .study) { return }
        withAnimation(.snappy(duration: 0.35)) { active = true }
    }
    /// Opens the library, by the same way in the other direction.
    func leave() {
        if HomeStage.shared.cross(to: .library) { return }
        withAnimation(.snappy(duration: 0.35)) { active = false }; StudySound.rest()
    }
}

/// The course's tabs. The collection lives on the Me tab; `courses` lists the lab's courses and leads back to the AI lab.
/// The lab's shop sits at the foot of the Practice tab (a sixth tab would fold into More).
enum StudyTab: String, CaseIterable, Identifiable {
    case path, practice, lab, courses, me
    var id: String { rawValue }
    var title: String { L10n.text(["path": "Map", "practice": "Practice", "lab": "Studio", "courses": "lab.tab.courses", "me": "Me"][rawValue] ?? "") }
    var symbol: String { ["path": "map.fill", "practice": "dumbbell.fill", "lab": "wand.and.stars", "courses": LabTab.coursesSymbol, "me": "person.crop.circle.fill"][rawValue] ?? "circle" }
}

extension Color {
    /// A colour from six hexadecimal digits.
    init(studyHex hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x7C5CFF
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
    /// One colour in light appearance and another in dark.
    init(studyLight light: String, dark: String) {
        self.init(uiColor: UIColor { UIColor(Color(studyHex: $0.userInterfaceStyle == .dark ? dark : light)) })
    }
}

/// Learning mode's own look: bright, rounded and chunky, unlike the library around it.
enum StudyTheme {
    static let background = Color(studyLight: "F6F4FF", dark: "13112A")
    static let surface = Color(studyLight: "FFFFFF", dark: "1F1C3D")
    static let sunken = Color(studyLight: "ECE8FB", dark: "2A2750")
    static let line = Color(studyLight: "DDD7F3", dark: "37336A")
    static let ink = Color(studyLight: "241F47", dark: "F3F1FF")
    static let muted = Color(studyLight: "7A7499", dark: "A49FCB")
    static let primary = Color(studyHex: "7C5CFF")
    static let good = Color(studyHex: "1FBF8F")
    static let bad = Color(studyHex: "FF5D6C")
    static let gold = Color(studyHex: "FFB627")
    static let flame = Color(studyHex: "FF8A3D")

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat = 17, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
    static let code = Font.system(size: 17, weight: .semibold, design: .monospaced)
}

extension Color {
    /// A darker shade of the same colour, for the edge a raised button stands on.
    func studyEdge() -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, saturation * 1.05), brightness: brightness * 0.72, opacity: alpha)
    }
}

/// A raised button that sinks onto its edge when pressed.
struct StudyPressStyle: ButtonStyle {
    var color = StudyTheme.primary
    var ink = Color.white
    var radius: CGFloat = 18
    var depth: CGFloat = 5
    /// An outlined, paper-coloured button, for choices and second actions.
    var outlined = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        let fill = !enabled ? StudyTheme.sunken : outlined ? StudyTheme.surface : color
        let edge = !enabled ? StudyTheme.line : outlined ? StudyTheme.line : color.studyEdge()
        return configuration.label
            .foregroundStyle(!enabled ? StudyTheme.muted : outlined ? StudyTheme.ink : ink)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
                    .overlay { if outlined { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(edge, lineWidth: 2) } }
            }
            .offset(y: down ? depth : 0)
            .background { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(edge).offset(y: depth) }
            .padding(.bottom, depth)
            .animation(.easeOut(duration: 0.08), value: down)
            .sensoryFeedback(.impact(weight: .light), trigger: down) { _, pressed in pressed }
    }
}

/// The wide button at the foot of a screen.
struct StudyMainButton: View {
    let title: String
    var color = StudyTheme.primary
    var symbol: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }.font(StudyTheme.body(18, .heavy)).frame(maxWidth: .infinity).padding(.vertical, 15)
        }.buttonStyle(StudyPressStyle(color: color))
    }
}

struct StudyBar: View {
    let value: Double
    var color = StudyTheme.good
    var height: CGFloat = 16
    var track = StudyTheme.sunken
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .overlay(alignment: .top) { Capsule().fill(.white.opacity(0.28)).frame(height: height * 0.3).padding(.horizontal, 6).padding(.top, 3) }
                    .frame(width: max(height, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: value)
    }
}

/// A card standing on the page.
struct StudyCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(StudyTheme.line, lineWidth: 2) }
    }
}

/// Text in which the words between backticks are prompt text.
struct StudyRichText: View {
    let source: String
    var size: CGFloat = 17
    var body: some View {
        var result = AttributedString()
        for (index, piece) in source.components(separatedBy: "`").enumerated() where !piece.isEmpty {
            var part = AttributedString(piece)
            if index % 2 == 1 {
                part.font = .system(size: size - 1, weight: .bold, design: .monospaced)
                part.foregroundColor = StudyTheme.primary
            } else { part.font = StudyTheme.body(size, .medium) }
            result += part
        }
        return Text(result).foregroundStyle(StudyTheme.ink).lineSpacing(4)
    }
}

/// Prompt text in a box, as it would be typed.
struct StudyCodeBox: View {
    let code: String
    var body: some View {
        Text(code).font(StudyTheme.code).foregroundStyle(StudyTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(StudyTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The guide who walks the path with the learner. A pose with no drawing in the asset catalogue shows a stand-in.
struct StudyMascot: View {
    enum Pose: String, CaseIterable {
        case wave, cheer, think, sad, read
        case closeUp = "close-up"
        case fullBody = "full-body"
        /// True for the drawings that show the guide from the waist up.
        var isBust: Bool { self != .cheer && self != .fullBody }
    }
    var pose = Pose.wave
    var size: CGFloat = 96
    /// Sways gently while it waits, as something alive does.
    var lively = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image = UIImage(named: "StudyMascot-\(pose.rawValue)") {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.36, style: .continuous).fill(StudyTheme.primary.opacity(0.16))
                    RoundedRectangle(cornerRadius: size * 0.36, style: .continuous)
                        .strokeBorder(StudyTheme.primary.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    Image(systemName: "sparkles").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(StudyTheme.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .mask {
            if pose.isBust { LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom) }
            else { Rectangle() }
        }
        .phaseAnimator(lively && !reduceMotion ? [false, true] : [false]) { view, up in
            view.offset(y: up ? -size * 0.025 : size * 0.015).rotationEffect(.degrees(up ? 1.6 : -1.6), anchor: .bottom)
        } animation: { _ in .easeInOut(duration: 1.15) }
        .accessibilityHidden(true)
    }
}

/// A small counter with an icon, as the bar at the top of the path shows.
struct StudyStat: View {
    let symbol: String
    let color: Color
    let value: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color).symbolEffect(.bounce, value: value)
            Text(value).foregroundStyle(StudyTheme.ink).monospacedDigit().contentTransition(.numericText())
        }.font(StudyTheme.body(17, .heavy)).animation(.spring(duration: 0.4, bounce: 0.4), value: value)
    }
}
