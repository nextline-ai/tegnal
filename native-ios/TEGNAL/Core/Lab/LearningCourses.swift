import Foundation
import Observation

/// A course of learning mode, as the 코스 tab lists it. Every course plays on one of two engines:
///
/// - `deck`: the lab's card deck (`LabRoot`). The AI lab is the bundled deck course; imported deck courses play on it too.
/// - `tags`: the tag-study path (`StudyModeRoot`). 2D AI 배우기 is the bundled one; imported `"engine": "tags"` courses
///   bring a path of their own (`TagCourse`).
///
/// A new bundled course is a script folder like `AILab/`, one entry in `LearningCourses.bundled`, and nothing else.
/// A course file for an engine, tool, lesson or step this app does not know waits in `LearningCourses.waiting` until the
/// app is updated.
struct LearningCourse: Identifiable, Sendable {
    enum Engine: String, Sendable { case deck, tags }

    static let labID = "ai-lab"
    static let tagsID = "2d-ai"

    let id: String
    let engine: Engine
    /// The shop item that sells it (`LabStore.owns`); nil when every learner has it.
    let item: String?
    /// The script, for a deck course.
    let deck: LabCourse?
    /// The path, for an imported course on the tags engine. Nil for the bundled 2D AI course, which plays the bundled path.
    let lessons: TagCourse?
    /// Imported by the learner from a course file, rather than bundled.
    let imported: Bool
    /// Bought in the shop and downloaded from TEGNAL: it pays 보석, and no file may take its id.
    var official = false

    var title: String { deck?.title ?? lessons?.title.resolved() ?? L10n.text("Tag Study") }
}

/// A course file kept although this app is too old to play it.
struct WaitingCourse: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
}

/// Every course: the bundled ones first, then those the learner imported, oldest first.
@MainActor @Observable
final class LearningCourses {
    static let shared = LearningCourses()

    /// Courses bought in the shop and downloaded, read from their files.
    private(set) var official: [LearningCourse] = []
    /// Imported courses, read from their files.
    private(set) var imported: [LearningCourse] = []
    /// Imported files this version of the app cannot play yet.
    private(set) var waiting: [WaitingCourse] = []
    /// Where imported course files are kept, one `<id>.json` each.
    private let folder: URL

    init(folder: URL = LearningCourses.defaultFolder) {
        self.folder = folder
        (imported, waiting) = Self.load(folder)
        official = Self.loadOfficial(folder.appending(path: "shop", directoryHint: .isDirectory))
        imported.removeAll { course in official.contains { $0.id == course.id } }
    }

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LearningCourses", directoryHint: .isDirectory)
    }

    static let lab = LearningCourse(id: LearningCourse.labID, engine: .deck, item: nil, deck: .bundled, lessons: nil, imported: false)
    static let tags = LearningCourse(id: LearningCourse.tagsID, engine: .tags, item: LabStore.tagCourse, deck: nil, lessons: nil, imported: false)
    static let bundled = [lab, tags]

    var all: [LearningCourse] { Self.bundled + official + imported }

    func course(_ id: String) -> LearningCourse? { all.first { $0.id == id } }

    /// True when the learner may open the course: it is free, or it was bought in the shop.
    func owned(_ course: LearningCourse) -> Bool { course.item.map(LabStore.shared.owns) ?? true }

    // MARK: Importing

    /// Checks a course file and keeps it. A file for a course already imported replaces it; its records stay.
    /// A course this app is too old for is kept as waiting, and `.newer` is thrown so the learner is told to update.
    @discardableResult
    func add(_ url: URL) throws -> LearningCourse {
        try add(data: LabCourseFile.data(url))
    }

    @discardableResult
    func add(data: Data) throws -> LearningCourse {
        do {
            let course = try LabCourseFile.decode(data)
            guard !official.contains(where: { $0.id == course.id }) else { throw LabCourseFileError.reserved }
            try keep(course.id, data)
            imported.removeAll { $0.id == course.id }
            waiting.removeAll { $0.id == course.id }
            imported.append(course)
            return course
        } catch LabCourseFileError.newer {
            guard let (id, title) = LabCourseFile.peek(data) else { throw LabCourseFileError.newer }
            try keep(id, data)
            imported.removeAll { $0.id == id }
            waiting.removeAll { $0.id == id }
            waiting.append(WaitingCourse(id: id, title: title))
            throw LabCourseFileError.newer
        }
    }

    private func keep(_ id: String, _ data: Data) throws {
        guard !LabCourseFile.reserved.contains(id) else { throw LabCourseFileError.reserved }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: file(id), options: .atomic)
    }

    /// Removes an imported or waiting course. What was done in it stays in the records, so importing it again brings it back.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
        imported.removeAll { $0.id == id }
        waiting.removeAll { $0.id == id }
    }

    private func file(_ id: String) -> URL { folder.appending(path: id + ".json") }

    // MARK: Courses from the shop

    private var shopFolder: URL { folder.appending(path: "shop", directoryHint: .isDirectory) }

    /// True when the course a shop item sells is on this device.
    func has(item: String) -> Bool { official.contains { $0.item == item } }

    /// Keeps a course file the shop delivered for an item, already checked against the signed list. An imported course with the
    /// same id is taken out of the way: the official one replaces it, and its records stay.
    @discardableResult
    func addOfficial(data: Data, item: String) throws -> LearningCourse {
        let course = Self.official(try LabCourseFile.decode(data), item: item)
        try FileManager.default.createDirectory(at: shopFolder, withIntermediateDirectories: true)
        try data.write(to: shopFolder.appending(path: item + ".json"), options: .atomic)
        if imported.contains(where: { $0.id == course.id }) { remove(course.id) }
        official.removeAll { $0.item == item }
        official.append(course)
        return course
    }

    /// A course read from its file, as one sold by the shop.
    private static func official(_ course: LearningCourse, item: String) -> LearningCourse {
        var deck = course.deck
        deck?.official = true
        var result = LearningCourse(id: course.id, engine: course.engine, item: item, deck: deck, lessons: course.lessons, imported: false)
        result.official = true
        return result
    }

    private static func loadOfficial(_ folder: URL) -> [LearningCourse] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let course = try? LabCourseFile.decode(data),
                  !LabCourseFile.reserved.contains(course.id) else { return nil }
            return official(course, item: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Reads the kept files, oldest first. A file this app is too old for waits; one that no longer passes the checks is left out.
    private static func load(_ folder: URL) -> ([LearningCourse], [WaitingCourse]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "json" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        var courses: [LearningCourse] = [], waiting: [WaitingCourse] = []
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let course = try LabCourseFile.decode(data)
                if course.id == name { courses.append(course) }
            } catch LabCourseFileError.newer {
                if let (id, title) = LabCourseFile.peek(data), id == name { waiting.append(WaitingCourse(id: id, title: title)) }
            } catch {}
        }
        return (courses, waiting)
    }
}
