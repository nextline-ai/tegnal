import Foundation
import UIKit

/// A course on the 2D AI course's engine, from a course file with `"engine": "tags"`: its own path of lessons (the shape of
/// `StudyPath.json`), and tags of its own beyond the app's curriculum (the shape of `TagStudy.json` groups). It plays on the 2D
/// AI course's screens, with its lessons kept apart from the bundled path (`course:<id>:<lesson>`), and earns XP and stars
/// as lessons do, but no badges, placement or 연구비.
///
/// ```json
/// { "format": "tegnal-lab-course", "version": 1, "engine": "tags", "id": "maker.backgrounds",
///   "title": {"ko": "배경과 장소"}, "summary": {"ko": "…"}, "color": "2F9E6E", "symbol": "mountain.2.fill",
///   "groups": [ /* StudyGroup */ ], "sections": [ /* StudyPathSection, lessons concept · tags · boss */ ] }
/// ```
struct TagCourse: Sendable {
    let id: String
    let title: StudyText
    let summary: StudyText
    /// Six hexadecimal digits.
    let color: String
    let symbol: String
    /// The course's own lessons, under ids that never meet the bundled path's.
    let path: StudyPath
    /// The tags the course teaches beyond the app's curriculum.
    let unit: StudyUnit?

    static let limits = (sections: 40, lessons: 300, steps: 80, groups: 60, tags: 2_000)
    static let poses: Set<String> = ["wave", "cheer", "think", "sad", "read", "close-up", "full-body"]
    /// What this version of the app knows how to play. Anything else in a file asks for a newer app.
    static let lessonKinds: Set<String> = ["concept", "tags", "boss"]
    static let stepKinds: Set<String> = ["card", "ask", "build", "order", "sort"]

    static func lessonID(course: String, lesson: String) -> String { "course:" + course + ":" + lesson }

    /// The text of the course, as `StudyText` maps; checked like add-on text.
    fileprivate struct File: Decodable {
        var id: String
        var title: StudyText
        var summary: StudyText
        var color: String
        var symbol: String?
        var groups: [StudyGroup]?
        var sections: [StudyPathSection]
    }

    /// Reads and checks a file's object. Throws `LabCourseFileError.newer` for a lesson or step this app does not know.
    static func decode(_ top: [String: Any]) throws -> TagCourse {
        // A lesson or step kind from a later version of the app: the course is for a newer app, not a broken file.
        for section in top["sections"] as? [[String: Any]] ?? [] {
            for lesson in section["lessons"] as? [[String: Any]] ?? [] {
                if let kind = lesson["kind"] as? String, !lessonKinds.contains(kind) { throw LabCourseFileError.newer }
                for step in lesson["steps"] as? [[String: Any]] ?? [] where !Set(step.keys).isSubset(of: stepKinds) { throw LabCourseFileError.newer }
            }
        }
        let file: File
        do {
            let filled = fillEnglish(top, depth: 0)
            file = try JSONDecoder().decode(File.self, from: JSONSerialization.data(withJSONObject: filled))
        } catch { throw LabCourseFileError.invalid("file") }
        try file.validate()
        let sections = file.sections.map { section in
            StudyPathSection(id: "course:\(file.id):\(section.id)", title: section.title, summary: section.summary, color: section.color, lessons: section.lessons.map { lesson in
                let steps = lesson.steps?.map { step -> StudyPathLesson.Step in
                    var step = step
                    if var card = step.card {
                        card.symbol = card.symbol.map { symbol($0, fallback: "sparkles") }
                        card.action = nil
                        step.card = card
                    }
                    return step
                }
                return StudyPathLesson(id: lessonID(course: file.id, lesson: lesson.id), kind: lesson.kind, symbol: symbol(lesson.symbol, fallback: "book.fill"),
                                       title: lesson.title, summary: lesson.summary, tags: lesson.tags, steps: steps)
            })
        }
        let groups = file.groups ?? []
        return TagCourse(id: file.id, title: file.title, summary: file.summary, color: file.color, symbol: symbol(file.symbol, fallback: "graduationcap.fill"),
                         path: StudyPath(version: 3, sections: sections),
                         unit: groups.isEmpty ? nil : StudyUnit(id: "course:" + file.id, title: file.title, summary: file.summary, groups: groups))
    }

    private static func symbol(_ name: String?, fallback: String) -> String {
        guard let name, UIImage(systemName: name) != nil else { return fallback }
        return name
    }

    /// Gives every text in the app languages an English wording, taken from Korean or Japanese where English is missing.
    private static func fillEnglish(_ value: Any, depth: Int) -> Any {
        guard depth < 24 else { return value }
        if var object = value as? [String: Any] {
            let languages: Set<String> = ["en", "ko", "ja"]
            if !object.isEmpty, Set(object.keys).isSubset(of: languages), object.values.allSatisfy({ $0 is String }) {
                if object["en"] == nil, let other = (object["ko"] ?? object["ja"]) { object["en"] = other }
                return object
            }
            for (key, inner) in object { object[key] = fillEnglish(inner, depth: depth + 1) }
            return object
        }
        if let array = value as? [Any] { return array.map { fillEnglish($0, depth: depth + 1) } }
        return value
    }

    /// Every lesson of the course is done.
    func complete(_ records: [String: StudyLessonRecord]) -> Bool { !path.lessons.isEmpty && path.lessons.allSatisfy { records[$0.id] != nil } }
}

private extension TagCourse.File {
    func validate() throws {
        func require(_ value: Bool, _ field: String) throws { if !value { throw LabCourseFileError.invalid(field) } }
        try require(AddonCheck.identifier(id, max: 48) && !LabCourseFile.reserved.contains(id), "id")
        try require(AddonCheck.text(title, max: 80), "title")
        try require(AddonCheck.text(summary, max: 400, multiline: true), "summary")
        try require(AddonCheck.color(color), "color")
        if let symbol { try require(AddonCheck.symbol(symbol), "symbol") }

        var known = Set<String>()
        let groups = groups ?? []
        try require(groups.count <= TagCourse.limits.groups, "groups")
        try require(Set(groups.map(\.id)).count == groups.count, "groups")
        for group in groups {
            try require(AddonCheck.identifier(group.id, max: 48) && AddonCheck.text(group.title, max: 80), "groups: " + AddonCheck.preview(group.id))
            try require(!group.tags.isEmpty, "groups: " + AddonCheck.preview(group.id))
            for tag in group.tags {
                try require(AddonCheck.tag(tag.name, namespaced: false), "tag " + AddonCheck.preview(tag.name))
                try require(AddonCheck.text(tag.note, max: 400, multiline: true), "tag " + AddonCheck.preview(tag.name))
                for name in [tag.ko, tag.ja].compactMap({ $0 }) { try require(AddonCheck.line(name, max: 80), "tag " + AddonCheck.preview(tag.name)) }
                try require((tag.confusable ?? []).count <= 10 && (tag.confusable ?? []).allSatisfy { AddonCheck.tag($0, namespaced: false) }, "tag " + AddonCheck.preview(tag.name))
                try require(known.insert(tag.name).inserted, "tag " + AddonCheck.preview(tag.name))
            }
        }
        try require(known.count <= TagCourse.limits.tags, "groups")

        try require(!sections.isEmpty && sections.count <= TagCourse.limits.sections, "sections")
        try require(Set(sections.map(\.id)).count == sections.count, "sections")
        let lessons = sections.flatMap(\.lessons)
        try require(!lessons.isEmpty && lessons.count <= TagCourse.limits.lessons, "lessons")
        try require(Set(lessons.map(\.id)).count == lessons.count, "lessons")
        for section in sections {
            try require(AddonCheck.identifier(section.id, max: 48), "section " + AddonCheck.preview(section.id))
            try require(AddonCheck.text(section.title, max: 80) && AddonCheck.text(section.summary, max: 400, multiline: true) && AddonCheck.color(section.color), "section " + AddonCheck.preview(section.id))
            for lesson in section.lessons { try validate(lesson, known: known) }
        }
    }

    private func validate(_ lesson: StudyPathLesson, known: Set<String>) throws {
        let field = "lesson " + AddonCheck.preview(lesson.id)
        func require(_ value: Bool) throws { if !value { throw LabCourseFileError.invalid(field) } }
        try require(AddonCheck.identifier(lesson.id, max: 48) && AddonCheck.symbol(lesson.symbol) && AddonCheck.text(lesson.title, max: 80))
        if let summary = lesson.summary { try require(AddonCheck.text(summary, max: 400, multiline: true)) }
        let taught: (String) -> Bool = { known.contains($0) || StudyCurriculum.bundled.contains($0) }
        switch lesson.kind {
        case .tags:
            let tags = lesson.tags ?? []
            // Every tag of a tags lesson needs a meaning, from the app's curriculum or from the course's own groups.
            try require((lesson.steps ?? []).isEmpty && (1...12).contains(tags.count) && Set(tags).count == tags.count && tags.allSatisfy(taught))
        case .concept, .boss:
            let steps = lesson.steps ?? []
            try require((lesson.tags ?? []).isEmpty && !steps.isEmpty && steps.count <= TagCourse.limits.steps)
            for step in steps {
                let parts = [step.card != nil, step.ask != nil, step.build != nil, step.order != nil, step.sort != nil].filter { $0 }.count
                try require(parts == 1)
                if let card = step.card {
                    // Cards in course files only tell: they never open a page, a key sheet or the generator.
                    try require(card.action == nil)
                    try require(AddonCheck.text(card.title, max: 120) && AddonCheck.text(card.body, max: 2000, multiline: true))
                    try require(card.code.map { AddonCheck.line($0, max: 1000, multiline: true) } ?? true)
                    try require(card.symbol.map(AddonCheck.symbol) ?? true)
                    try require(card.pose.map { TagCourse.poses.contains($0) } ?? true)
                }
                if let ask = step.ask {
                    try require(AddonCheck.text(ask.question, max: 400, multiline: true) && AddonCheck.text(ask.why, max: 600, multiline: true))
                    try require((2...6).contains(ask.choices.count) && ask.choices.indices.contains(ask.answer) && ask.choices.allSatisfy { AddonCheck.text($0, max: 300, multiline: true) })
                }
                if let build = step.build {
                    try require(AddonCheck.text(build.brief, max: 400, multiline: true))
                    try require((1...12).contains(build.answer.count) && Set(build.answer).count == build.answer.count && build.extras.count <= 12)
                    try require((build.answer + build.extras).allSatisfy { AddonCheck.tag($0, namespaced: false) } && Set(build.answer).isDisjoint(with: build.extras))
                }
                if let order = step.order {
                    try require(AddonCheck.text(order.brief, max: 400, multiline: true) && AddonCheck.text(order.why, max: 600, multiline: true))
                    try require((2...8).contains(order.items.count) && order.items.allSatisfy { AddonCheck.text($0, max: 200) })
                }
                if let sort = step.sort {
                    try require(AddonCheck.text(sort.brief, max: 400, multiline: true) && AddonCheck.text(sort.why, max: 600, multiline: true))
                    try require(AddonCheck.text(sort.left, max: 60) && AddonCheck.text(sort.right, max: 60))
                    try require((2...12).contains(sort.items.count) && sort.items.allSatisfy { AddonCheck.text($0.text, max: 200) })
                }
            }
        }
    }
}
