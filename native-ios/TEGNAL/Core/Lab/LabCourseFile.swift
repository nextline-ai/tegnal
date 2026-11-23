import CryptoKit
import Foundation

/// A deck course in one file: `course.json` with its episodes written inline, as `"episodes": [ … ]`.
/// Learners import these in learning mode's 코스 tab (`.tegnalcourse`, or plain `.json`).
///
/// Like add-ons, a course file is data only: nothing in it is run, fetched or opened. It is refused, never cleaned,
/// when any part breaks the rules below, so what the 코스 tab shows is all the file holds. An imported course pays no 연구비,
/// so a made-up course can never buy what the lab's own cards earn.
enum LabCourseFile {
    static let format = "tegnal-lab-course"
    static let version = 1
    static let fileExtension = "tegnalcourse"
    static let maximumBytes = 4 * 1024 * 1024
    /// Course ids the app's own courses use, which a file may not take.
    static let reserved: Set<String> = [LearningCourse.labID, LearningCourse.tagsID]
    static let limits = (seasons: 12, episodes: 100, choices: 6, text: 4_000, strings: 40_000)

    /// Reads a file the learner picked, at most one byte past the limit. Nothing in it is used until it has passed every check.
    static func data(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw LabCourseFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // One byte past the limit, so a file that grew after its size was read is still refused.
        return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    }

    /// The engines this version of the app can play. A file for any other is for a newer app.
    static let engines: Set<String> = ["deck", "tags"]

    /// A course from its file: a deck course, or a course on the 2D AI course's engine (`"engine": "tags"`).
    /// Throws `.newer` for a file this app is too old for: a later version, another engine, or a tool, lesson or step it
    /// does not know. Such a file is a course all the same, kept until the app is updated (`LearningCourses.waiting`).
    static func decode(_ data: Data) throws -> LearningCourse {
        guard data.count <= maximumBytes else { throw LabCourseFileError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any],
              top["format"] as? String == format else { throw LabCourseFileError.notCourse }
        guard let version = top["version"] as? Int, version >= 1 else { throw LabCourseFileError.notCourse }
        guard version <= Self.version else { throw LabCourseFileError.newer }
        let engine = top["engine"] as? String ?? "deck"
        guard engines.contains(engine) else { throw LabCourseFileError.newer }
        var strings = 0
        try checkStrings(top, path: "", count: &strings)
        if engine == "tags" {
            let course = try TagCourse.decode(top)
            return LearningCourse(id: course.id, engine: .tags, item: nil, deck: nil, lessons: course, imported: true)
        }
        guard let episodes = top["episodes"] as? [Any] else { throw LabCourseFileError.invalid("episodes") }
        // A tool from a later version of the app.
        for episode in episodes {
            if let kind = ((episode as? [String: Any])?["tool"] as? [String: Any])?["kind"] as? String, LabTool.Kind(rawValue: kind) == nil {
                throw LabCourseFileError.newer
            }
        }
        struct Inline: Decodable { var episodes: [LabEpisode] }
        let course: LabCourse
        do {
            let decoder = JSONDecoder()
            course = LabCourse(info: try decoder.decode(LabCourseInfo.self, from: data),
                               episodes: try decoder.decode(Inline.self, from: data).episodes, imported: true)
        } catch { throw LabCourseFileError.invalid(describe(error)) }
        if let problem = course.problems(imported: true).first { throw LabCourseFileError.invalid(problem) }
        return LearningCourse(id: course.id, engine: .deck, item: nil, deck: course, lessons: nil, imported: true)
    }

    /// The id and name of a course file this app is too old for, so it can be kept and named until the app is updated.
    static func peek(_ data: Data) -> (id: String, title: String)? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], top["format"] as? String == format,
              let id = top["id"] as? String, AddonCheck.identifier(id, max: 48), !reserved.contains(id) else { return nil }
        let title = (try? JSONSerialization.data(withJSONObject: ["t": top["title"] ?? id]))
            .flatMap { try? JSONDecoder().decode([String: LabText].self, from: $0) }?["t"]?.text ?? id
        guard clean(title), title.count <= 80 else { return nil }
        return (id, title)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Every string in the file: short enough, and free of control characters and invisible marks
    /// (which can make text read differently from what it is). Line breaks are allowed.
    private static func checkStrings(_ value: Any, path: String, count: inout Int) throws {
        if let text = value as? String {
            count += 1
            guard count <= limits.strings, clean(text) else { throw LabCourseFileError.invalid(path.isEmpty ? "text" : path) }
        } else if let object = value as? [String: Any] {
            for (key, inner) in object { try checkStrings(inner, path: path.isEmpty ? key : path + "." + key, count: &count) }
        } else if let array = value as? [Any] {
            for (index, inner) in array.enumerated() { try checkStrings(inner, path: path + "[\(index)]", count: &count) }
        }
    }

    /// An episode or 망작 id: lowercase letters, digits, dots, hyphens and underscores, up to 64. Never a slash, which
    /// `LabStore.key` puts between a course and its ids.
    static func part(_ value: String) -> Bool {
        (1...64).contains(value.count) && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isLowercase || ("0"..."9").contains($0) || ".-_".unicodeScalars.contains($0)) }
    }

    /// The add-on rule for text, with line breaks allowed and empty text let through (a script may leave a line blank).
    static func clean(_ text: String) -> Bool {
        text.count <= limits.text && text.unicodeScalars.allSatisfy { scalar in
            if scalar == "\n" { return true }
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: return false
            // Joiners keep emoji whole; every other invisible format mark is refused.
            case .format: return scalar.value == 0x200D
            default: return true
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "file" }
        let path: [CodingKey]
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
        @unknown default: path = []
        }
        let text = path.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return text.isEmpty ? "file" : text
    }
}

enum LabCourseFileError: LocalizedError, Equatable {
    case tooLarge, notCourse, newer, reserved, invalid(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.text("lab.import.tooLarge")
        case .notCourse: return L10n.text("lab.import.notCourse")
        case .newer: return L10n.text("lab.import.newer")
        case .reserved: return L10n.text("lab.import.reserved")
        case .invalid(let field): return L10n.text("lab.import.invalid", field)
        }
    }
}

// MARK: - The rules every deck course keeps

extension LabCourse {
    /// What is wrong with the course, as the field at fault; empty when nothing is. The bundled course is held to the same
    /// rules by its tests; an imported one is refused for the first problem found.
    func problems(imported: Bool = false) -> [String] {
        var found: [String] = []
        func require(_ value: Bool, _ field: String) { if !value { found.append(field) } }
        let info = self.info
        require(AddonCheck.identifier(info.id, max: 48), "id")
        if imported { require(!LabCourseFile.reserved.contains(info.id), "id") }
        require(!info.title.isEmpty && info.title.text.count <= 80, "title")
        require(!info.gauge.isEmpty && info.gauge.text.count <= 40, "gauge")
        require((0...100).contains(info.base), "base")
        require((info.cardColors ?? []).allSatisfy(AddonCheck.color) && (info.cardColors?.count ?? 1) > 0, "cardColors")

        require((1...LabCourseFile.limits.seasons).contains(seasons.count), "seasons")
        require(Set(seasons.map(\.number)).count == seasons.count, "seasons")
        let listed = seasons.flatMap(\.episodes)
        require(Set(listed).count == listed.count, "seasons.episodes")
        for season in seasons {
            let field = "seasons[\(season.number)]"
            require(!season.title.isEmpty && !season.episodes.isEmpty, field)
            require(["fixed", "free"].contains(season.order), field + ".order")
            if let after = season.opensAfter { require(seasons.contains { $0.number == after && $0.number < season.number }, field + ".opensAfter") }
        }

        require((1...LabCourseFile.limits.episodes).contains(episodes.count), "episodes")
        require(Set(episodes.map(\.id)) == Set(listed) && episodes.count == listed.count, "episodes")
        require(Set(episodes.map(\.number)).count == episodes.count, "episodes.number")
        let fails = self.fails.map(\.id)
        require(Set(fails).count == fails.count, "fail.id")
        for fail in fails { require(LabCourseFile.part(fail), "fail.id " + AddonCheck.preview(fail)) }
        require(top <= 100, "impact")
        for episode in episodes { found += episode.problems() }
        return found
    }
}

extension LabEpisode {
    /// What is wrong with one episode: its text, its choices and whether its tool can be passed with what the file gives it.
    func problems() -> [String] {
        var found: [String] = []
        let field = "episodes." + id
        func require(_ value: Bool, _ part: String) { if !value { found.append(field + (part.isEmpty ? "" : "." + part)) } }
        require(LabCourseFile.part(id), "id")
        require(number >= 1 && number <= 999, "number")
        require(!title.isEmpty, "title")
        require(impact >= 0 && reward >= 0, "impact")
        require(!disaster.ask.isEmpty && !disaster.reply.isEmpty && !disaster.verdict.isEmpty && !disaster.question.isEmpty, "disaster")
        require((2...LabCourseFile.limits.choices).contains(choices.count) && choices.contains(where: \.isRight), "choices")
        for choice in choices where !choice.isRight { require(choice.fail != nil, "choices.fail") }
        require(!card.line.isEmpty && card.uses.count == 3, "card")

        let tool = self.tool
        switch tool.kind {
        case .switches:
            let controls = tool.controls ?? []
            require(!controls.isEmpty && controls.allSatisfy { !$0.options.isEmpty }, "tool.controls")
            let passing = (tool.results ?? []).filter { $0.pass == true }
            require(tool.compose != nil || passing.count >= (tool.need ?? 1), "tool.results")
            for result in tool.results ?? [] {
                require(result.when.count == controls.count, "tool.results.when")
                for (index, value) in result.when.enumerated() where value >= 0 && index < controls.count {
                    require(controls[index].options.indices.contains(value), "tool.results.when")
                }
            }
            if tool.compose != nil { require(controls.allSatisfy { $0.options.allSatisfy { $0.line != nil } }, "tool.compose") }
        case .chips:
            let chips = tool.chips ?? []
            if tool.mode == "toggle" {
                require(chips.filter { $0.line != nil }.count >= (tool.need ?? 1), "tool.chips")
            } else {
                require(chips.contains { $0.pass == true }, "tool.chips")
                require(chips.allSatisfy { !($0.replies ?? []).isEmpty }, "tool.chips.replies")
            }
        case .stamps:
            let labels = tool.stamps ?? []
            require(labels.count == 2, "tool.stamps")
            require(!(tool.items ?? []).isEmpty && (tool.items ?? []).allSatisfy { labels.indices.contains($0.answer) }, "tool.items")
        case .marks:
            require((tool.pieces ?? []).contains(where: \.isTarget), "tool.pieces")
            require(["cut", "flag", "mask"].contains(tool.style ?? "cut"), "tool.style")
            if tool.style == "mask" { require((tool.pieces ?? []).filter(\.isTarget).allSatisfy { $0.swap != nil }, "tool.pieces.swap") }
        case .equip:
            let gear = Set((tool.gear ?? []).map(\.id))
            require(!(tool.missions ?? []).isEmpty, "tool.missions")
            for mission in tool.missions ?? [] { require(Set(mission.needs).isSubset(of: gear), "tool.missions.needs") }
            for item in tool.gear ?? [] { require(item.symbol.map(AddonCheck.symbol) ?? true, "tool.gear.symbol") }
        case .rot:
            require((tool.replies ?? []).count >= (tool.minRetries ?? 2), "tool.replies")
            require(tool.fresh != nil, "tool.fresh")
        }
        return found
    }
}
