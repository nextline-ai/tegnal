import Foundation

/// One lesson on writing prompts: what the makers of the image models document, with examples and a few questions.
struct StudyLesson: Codable, Hashable, Identifiable, Sendable {
    struct Example: Codable, Hashable, Sendable {
        /// Prompt text, shown as written.
        let code: String
        var note: StudyText?
    }
    struct Part: Codable, Hashable, Sendable {
        var heading: StudyText?
        /// Running text; words between backticks are prompt syntax.
        var body: StudyText?
        var examples: [Example]?
    }
    struct Check: Codable, Hashable, Sendable {
        let question: StudyText
        /// Prompt text to choose between, the same in every language.
        let choices: [String]
        let answer: Int
        let why: StudyText
    }
    let id: String
    let symbol: String
    /// A hands-on tool shown with the lesson; `emphasis` is the weight converter.
    var tool: String?
    let title: StudyText
    let summary: StudyText
    let parts: [Part]
    var checks: [Check] = []
    /// The pages the lesson was written from.
    var sources: [String] = []
}

struct StudyGuide: Codable, Sendable {
    var version = 1
    /// The month the sources were last read, as `yyyy-MM`.
    var checked = ""
    var lessons: [StudyLesson] = []

    static let bundled: StudyGuide = {
        guard let url = Bundle.main.url(forResource: "PromptGuide", withExtension: "json"), let data = try? Data(contentsOf: url) else { return .init() }
        return (try? JSONDecoder().decode(StudyGuide.self, from: data)) ?? .init()
    }()

    /// The lessons whose every question has been answered right, kept as their ids joined by commas.
    static func finished(_ stored: String) -> Set<String> { Set(stored.split(separator: ",").map(String.init)) }
    static func finishing(_ id: String, in stored: String) -> String { finished(stored).union([id]).sorted().joined(separator: ",") }
}

/// The ways image generators write how strongly a tag should count.
enum StudyEmphasis: String, CaseIterable, Identifiable, Sendable {
    /// NovelAI braces and brackets, one pair for each step of 1.05.
    case braces
    /// NovelAI's numbered form, `1.5::tag ::` (V4 and later; negative weights from V4.5).
    case numbered
    /// The Stable Diffusion web UI's `(tag:1.5)`.
    case weighted
    var id: String { rawValue }

    static let step = 1.05

    /// The whole number of brace pairs (negative for brackets) closest to a weight.
    static func pairs(_ weight: Double) -> Int {
        guard weight > 0 else { return 0 }
        return Int((log(weight) / log(step)).rounded())
    }

    static func number(_ weight: Double) -> String {
        let text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), weight)
        let trimmed = text.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }

    /// `words` written with `weight` in this notation. A weight of one is written plainly.
    func written(_ words: String, weight: Double) -> String {
        let escaped = words.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        guard !words.isEmpty else { return "" }
        if abs(weight - 1) < 0.000_1 { return self == .weighted ? escaped : words }
        switch self {
        case .braces:
            let pairs = Self.pairs(weight)
            if pairs == 0 { return words }
            let count = min(abs(pairs), 20)
            return String(repeating: pairs > 0 ? "{" : "[", count: count) + words + String(repeating: pairs > 0 ? "}" : "]", count: count)
        case .numbered: return "\(Self.number(weight))::\(words) ::"
        case .weighted: return "(\(escaped):\(Self.number(weight)))"
        }
    }

    /// The weight this notation really gives, which for braces is the nearest step.
    func effective(_ weight: Double) -> Double {
        self == .braces ? pow(Self.step, Double(Self.pairs(weight))) : weight
    }
}
