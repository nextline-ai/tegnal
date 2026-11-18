import Foundation

/// What a study round covers.
enum StudyScope: Hashable, Sendable {
    /// Tags that are due again first, then tags not met yet.
    case today
    /// Only tags that are due again.
    case review
    case unit(String)
    /// Chosen tags, such as the ones on a picture being viewed.
    case tags([String])
}

/// Chooses what to ask and builds the questions. It holds no state and reads no clock or server,
/// so the same inputs always give the same round.
struct StudyEngine: Sendable {
    var curriculum: StudyCurriculum = .bundled
    static let roundSize = 10

    // MARK: Round

    /// The tags of a round, in the order they are asked.
    func round<G: RandomNumberGenerator>(_ scope: StudyScope, progress: [String: StudyProgress], count: Int = StudyEngine.roundSize, now: Date, using generator: inout G) -> [StudyTag] {
        let candidates: [StudyTag]
        switch scope {
        case .today, .review: candidates = curriculum.tags
        case .unit(let id): candidates = curriculum.unit(id)?.tags ?? []
        case .tags(let names):
            var seen = Set<String>()
            candidates = names.compactMap { seen.insert($0).inserted ? curriculum.tag($0) : nil }
        }
        // Longest overdue first, so that a tag about to be forgotten is not pushed out by newer ones.
        let due = candidates.filter { progress[$0.name]?.isDue(now) == true }
            .sorted { (progress[$0.name]?.due ?? now) < (progress[$1.name]?.due ?? now) }
        if scope == .review { return Array(due.prefix(count)) }
        let fresh = candidates.filter { progress[$0.name]?.isNew ?? true }
        var chosen = Array(due.prefix(count))
        // New tags come in curriculum order, a few per round, so that reviews are never crowded out entirely.
        let room = scope == .today ? max(count - chosen.count, min(3, count)) : count - chosen.count
        chosen = Array(chosen.prefix(max(0, count - min(room, fresh.count)))) + fresh.prefix(room)
        if chosen.count < count {
            // A unit or a picture's tags can be practised again before anything is due: least known first.
            let taken = Set(chosen.map(\.name))
            let rest = candidates.filter { !taken.contains($0.name) }.shuffled(using: &generator)
                .sorted { (progress[$0.name]?.step ?? 0) < (progress[$1.name]?.step ?? 0) }
            if scope != .today { chosen += rest.prefix(count - chosen.count) }
        }
        return Array(chosen.prefix(count))
    }

    // MARK: Pictures

    /// A still picture that can be shown small: no video, animation or removed post.
    static func usable(_ post: BooruPost) -> Bool {
        !post.isRemoved && !post.isVideo && !post.isAnimated && (post.previewURL ?? post.sampleURL) != nil
    }

    /// Whether a picture is a fair example of a tag: it carries the tag, and where the tag's group
    /// allows one answer only, it carries no other tag of that group.
    func teaches(_ post: BooruPost, _ tag: StudyTag) -> Bool {
        guard post.tags.contains(tag.name) else { return false }
        guard let group = curriculum.group(of: tag.name), group.exclusive else { return true }
        let tags = Set(post.tags)
        return !group.tags.contains { $0.name != tag.name && tags.contains($0.name) }
    }

    // MARK: Wrong answers

    /// Tags to offer beside the right one: the ones learners mix up first, then others answering the same question.
    func distractors<G: RandomNumberGenerator>(for tag: StudyTag, count: Int = 3, excluding: Set<String> = [], using generator: inout G) -> [StudyTag] {
        var chosen: [StudyTag] = []
        var taken = excluding.union([tag.name])
        func take(_ candidates: [StudyTag]) {
            for candidate in candidates.shuffled(using: &generator) where chosen.count < count && taken.insert(candidate.name).inserted {
                chosen.append(candidate)
            }
        }
        take((tag.confusable ?? []).compactMap(curriculum.tag))
        take(curriculum.group(of: tag.name)?.tags ?? [])
        take(curriculum.unit(of: tag.name)?.tags ?? [])
        if chosen.count < count { take(curriculum.tags) }
        return chosen
    }

    // MARK: Questions

    /// A question for a tag from the pictures at hand. Without a fair picture it asks by meaning,
    /// so a round never stops for want of a server.
    func question<G: RandomNumberGenerator>(for tag: StudyTag, pool: [BooruPost], kinds: Set<StudyQuestionKind> = Set(StudyQuestionKind.allCases), using generator: inout G) -> StudyQuestion? {
        let group = curriculum.group(of: tag.name)
        let visual = group?.visual ?? true
        let examples = visual ? pool.filter { teaches($0, tag) } : []
        if kinds.contains(.tagToPicture), let right = examples.randomElement(using: &generator), Int.random(in: 0..<3, using: &generator) == 0 {
            // A wrong picture carries a neighbouring tag and not the asked one; a picture merely lacking the tag may only be under-tagged.
            let siblings = Set((group?.tags ?? []).map(\.name)).subtracting([tag.name])
            var seen = Set([right.id])
            let wrong = pool.shuffled(using: &generator).filter { post in
                !post.tags.contains(tag.name) && post.tags.contains(where: siblings.contains) && seen.insert(post.id).inserted
            }.prefix(3)
            if wrong.count == 3 {
                let posts = ([right] + wrong).shuffled(using: &generator)
                return StudyQuestion(kind: .tagToPicture, tag: tag, posts: posts, answer: posts.firstIndex(of: right) ?? 0)
            }
        }
        if kinds.contains(.pictureToTag), let post = examples.randomElement(using: &generator) {
            let wrong = distractors(for: tag, excluding: Set(post.tags), using: &generator)
            if wrong.count >= 2 {
                let choices = ([tag] + wrong).shuffled(using: &generator)
                return StudyQuestion(kind: .pictureToTag, tag: tag, choices: choices, posts: [post], answer: choices.firstIndex(of: tag) ?? 0)
            }
        }
        guard kinds.contains(.meaningToTag) else { return nil }
        let wrong = distractors(for: tag, using: &generator)
        guard !wrong.isEmpty else { return nil }
        let choices = ([tag] + wrong).shuffled(using: &generator)
        return StudyQuestion(kind: .meaningToTag, tag: tag, choices: choices, answer: choices.firstIndex(of: tag) ?? 0)
    }
}

/// Turns a picture's tags into the text image generators are prompted with.
enum StudyPrompt {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        /// Words apart and commas between tags.
        case natural
        /// As `natural`, with brackets escaped for tools that read them as emphasis.
        case escaped
        /// The tags as the server writes them, ready to search with.
        case tags
        var id: String { rawValue }
    }

    /// A tag as prompts write it. Underscores become spaces, except in emoticons such as `^_^` and `>_<`.
    static func words(_ tag: String) -> String {
        let letters = tag.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return letters <= 1 || tag.count <= 3 ? tag : tag.replacingOccurrences(of: "_", with: " ")
    }

    /// The headcount tags that prompts conventionally open with.
    static let leading: Set<String> = ["1girl", "2girls", "3girls", "4girls", "5girls", "6+girls", "multiple_girls", "1boy", "2boys", "3boys", "4boys", "5boys", "6+boys", "multiple_boys", "1other", "2others", "multiple_others", "no_humans", "solo"]

    /// The tags in prompt order: headcount, characters, series, then what the picture shows. Bookkeeping tags are left out.
    static func ordered(_ post: BooruPost, artists: Bool = false) -> [String] {
        let categories = post.tagCategories ?? [:]
        let meta = Set(post.metadataTags ?? [])
        var count: [String] = [], characters: [String] = [], series: [String] = [], names: [String] = [], general: [String] = []
        var seen = Set<String>()
        for tag in post.tags where seen.insert(tag).inserted {
            if meta.contains(tag) || categories[tag] == 5 || TasteTagPolicy.technical.contains(tag) { continue }
            if post.artists.contains(tag) || categories[tag] == 1 { names.append(tag) }
            else if categories[tag] == 4 { characters.append(tag) }
            else if categories[tag] == 3 { series.append(tag) }
            else if leading.contains(tag) { count.append(tag) }
            else { general.append(tag) }
        }
        return count + characters + series + (artists ? names : []) + general
    }

    static func text(_ tags: [String], style: Style) -> String {
        switch style {
        case .tags: return tags.joined(separator: " ")
        case .natural: return tags.map(words).joined(separator: ", ")
        case .escaped:
            return tags.map { words($0).replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") }.joined(separator: ", ")
        }
    }
}
