import XCTest
import GRDB
@testable import TEGNAL

final class StudyPathTests: XCTestCase {
    // MARK: - Path data

    func testTheBundledPathDecodesAndItsSectionsAreInOrder() {
        let path = StudyPath.bundled
        XCTAssertFalse(path.sections.isEmpty, "The file is missing or does not decode")
        XCTAssertEqual(path.sections.map(\.id), ["s0", "s1", "mind", "tools", "api", "s2", "s3", "s4", "s5", "s6", "s7"])
        XCTAssertEqual(path.sections.filter { $0.lessons.isEmpty }.map(\.id), [], "Every section has lessons now")
        XCTAssertEqual(path.lessons.count, 62)
        XCTAssertEqual(path.lessons.count, path.sections.reduce(0) { $0 + $1.lessons.count })
    }

    func testLessonIDsAreUniqueAndSectionColoursAreSixHexDigits() {
        let path = StudyPath.bundled
        let ids = path.lessons.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicated: " + Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys.sorted().joined(separator: ", "))
        XCTAssertEqual(ids.filter(\.isEmpty), [])
        for section in path.sections {
            XCTAssertNotNil(section.color.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression), "\(section.id) colour \(section.color)")
        }
    }

    func testEveryTextOfThePathHasEnglishKoreanAndJapaneseExceptTheChoicesOfPromptTextQuestions() {
        var problems: [String] = []
        func check(_ text: StudyText, _ label: String, languages: [String] = ["en", "ko", "ja"]) {
            for language in languages where (text[language] ?? "").isEmpty { problems.append(label + "." + language) }
        }
        for section in StudyPath.bundled.sections {
            check(section.title, section.id + " title")
            check(section.summary, section.id + " summary")
            for lesson in section.lessons {
                check(lesson.title, lesson.id + " title")
                if let summary = lesson.summary { check(summary, lesson.id + " summary") }
                for (index, step) in (lesson.steps ?? []).enumerated() {
                    let label = "\(lesson.id)#\(index)"
                    if let card = step.card { check(card.title, label + " card.title"); check(card.body, label + " card.body") }
                    if let ask = step.ask {
                        check(ask.question, label + " ask.question")
                        check(ask.why, label + " ask.why")
                        for (number, choice) in ask.choices.enumerated() {
                            check(choice, label + " ask.choice\(number)", languages: ask.code == true ? ["en"] : ["en", "ko", "ja"])
                        }
                    }
                    if let build = step.build { check(build.brief, label + " build.brief") }
                    if let order = step.order {
                        check(order.brief, label + " order.brief")
                        check(order.why, label + " order.why")
                        for (number, item) in order.items.enumerated() { check(item, label + " order.item\(number)") }
                    }
                    if let sort = step.sort {
                        check(sort.brief, label + " sort.brief")
                        check(sort.left, label + " sort.left")
                        check(sort.right, label + " sort.right")
                        check(sort.why, label + " sort.why")
                        for (number, item) in sort.items.enumerated() { check(item.text, label + " sort.item\(number)") }
                    }
                }
            }
        }
        XCTAssertEqual(problems, [])
    }

    func testEveryStepIsExactlyOneThingAndEveryLessonHasWhatItsKindNeeds() {
        var problems: [String] = []
        for lesson in StudyPath.bundled.lessons {
            switch lesson.kind {
            case .tags:
                if (lesson.tags ?? []).isEmpty { problems.append(lesson.id + " has no tags") }
                if lesson.steps != nil { problems.append(lesson.id + " is a tags lesson with steps") }
            case .concept, .boss:
                if (lesson.steps ?? []).isEmpty { problems.append(lesson.id + " has no steps") }
            }
            for (index, step) in (lesson.steps ?? []).enumerated() {
                let filled = [step.card != nil, step.ask != nil, step.build != nil, step.order != nil, step.sort != nil].filter { $0 }.count
                if filled != 1 { problems.append("\(lesson.id)#\(index) holds \(filled) things") }
            }
        }
        XCTAssertEqual(problems, [])
    }

    func testEveryTagsLessonNamesOnlyCurriculumTagsAndAtLeastFour() {
        let curriculum = StudyCurriculum.bundled
        XCTAssertFalse(curriculum.tags.isEmpty)
        var problems: [String] = []
        for lesson in StudyPath.bundled.lessons where lesson.kind == .tags {
            let tags = lesson.tags ?? []
            if !(4...6).contains(tags.count) { problems.append("\(lesson.id) has \(tags.count) tags") }
            if tags.count != Set(tags).count { problems.append(lesson.id + " repeats a tag") }
            for tag in tags where !curriculum.contains(tag) { problems.append("\(lesson.id) -> \(tag) is not taught") }
        }
        XCTAssertEqual(problems, [])
    }

    func testEveryAskHasTwoToFourDistinctChoicesAndAnAnswerAmongThem() {
        var problems: [String] = []
        for lesson in StudyPath.bundled.lessons {
            for (index, step) in (lesson.steps ?? []).enumerated() {
                guard let ask = step.ask else { continue }
                let label = "\(lesson.id)#\(index)"
                if !(2...4).contains(ask.choices.count) { problems.append("\(label) has \(ask.choices.count) choices") }
                if !ask.choices.indices.contains(ask.answer) { problems.append("\(label) answer \(ask.answer) is out of range") }
                let english = ask.choices.map { $0["en"] ?? "" }
                if english.count != Set(english).count { problems.append(label + " repeats a choice") }
            }
        }
        XCTAssertEqual(problems, [])
    }

    func testEveryBuildUsesCurriculumTagsKeepsExtrasApartAndWritesOneOrTwoHeadcountTagsFirst() {
        let curriculum = StudyCurriculum.bundled
        var problems: [String] = []
        var builds = 0
        for lesson in StudyPath.bundled.lessons {
            for (index, step) in (lesson.steps ?? []).enumerated() {
                guard let build = step.build else { continue }
                builds += 1
                let label = "\(lesson.id)#\(index)"
                for tag in build.answer + build.extras where !curriculum.contains(tag) { problems.append("\(label) -> \(tag) is not taught") }
                if build.answer.count != Set(build.answer).count { problems.append(label + " repeats an answer tag") }
                if build.extras.count != Set(build.extras).count { problems.append(label + " repeats an extra") }
                if !Set(build.answer).isDisjoint(with: build.extras) { problems.append(label + " extras overlap the answer") }
                let headcount = build.answer.filter { StudyPrompt.leading.contains($0) }
                let written = build.answer.prefix { StudyPrompt.leading.contains($0) }
                if !(1...2).contains(headcount.count) { problems.append("\(label) has \(headcount.count) headcount tags") }
                if written.count != headcount.count { problems.append(label + " does not write its headcount tags first") }
            }
        }
        XCTAssertGreaterThan(builds, 0, "No build in the bundled path")
        XCTAssertEqual(problems, [])
    }

    func testEveryOrderHasThreeToSixDistinctItemsAndAReason() {
        var problems: [String] = []
        var orders = 0
        for lesson in StudyPath.bundled.lessons {
            for (index, step) in (lesson.steps ?? []).enumerated() {
                guard let order = step.order else { continue }
                orders += 1
                let label = "\(lesson.id)#\(index)"
                if !(3...6).contains(order.items.count) { problems.append("\(label) has \(order.items.count) items") }
                let english = order.items.map { $0["en"] ?? "" }
                if english.count != Set(english).count { problems.append(label + " repeats an item") }
                if (order.why["en"] ?? "").isEmpty { problems.append(label + " has no why") }
            }
        }
        XCTAssertGreaterThan(orders, 0, "No order in the bundled path")
        XCTAssertEqual(problems, [])
    }

    func testEverySortHasThreeToSixDistinctItemsForBothSidesAndTwoDifferentLabels() {
        var problems: [String] = []
        var sorts = 0
        for lesson in StudyPath.bundled.lessons {
            for (index, step) in (lesson.steps ?? []).enumerated() {
                guard let sort = step.sort else { continue }
                sorts += 1
                let label = "\(lesson.id)#\(index)"
                if !(3...6).contains(sort.items.count) { problems.append("\(label) has \(sort.items.count) items") }
                if !sort.items.contains(where: { $0.right }) { problems.append(label + " has nothing for the right side") }
                if !sort.items.contains(where: { !$0.right }) { problems.append(label + " has nothing for the left side") }
                let english = sort.items.map { $0.text["en"] ?? "" }
                if english.count != Set(english).count { problems.append(label + " repeats an item") }
                if sort.left["en"] == sort.right["en"] { problems.append(label + " has the same label on both sides") }
                if (sort.why["en"] ?? "").isEmpty { problems.append(label + " has no why") }
            }
        }
        XCTAssertGreaterThan(sorts, 0, "No sort in the bundled path")
        XCTAssertEqual(problems, [])
    }

    func testEveryCardPoseAndActionIsAllowedAndAGeneratorActionCarriesCode() {
        let poses: Set<String> = ["wave", "cheer", "think", "sad", "read", "close-up", "full-body"]
        let actions: Set<String> = ["civitai", "key", "generator"]
        var problems: [String] = []
        var generators = 0
        for lesson in StudyPath.bundled.lessons {
            for (index, step) in (lesson.steps ?? []).enumerated() {
                guard let card = step.card else { continue }
                let label = "\(lesson.id)#\(index)"
                if let pose = card.pose, !poses.contains(pose) { problems.append("\(label) pose \(pose)") }
                if let action = card.action, !actions.contains(action) { problems.append("\(label) action \(action)") }
                if card.action == "generator" {
                    generators += 1
                    if (card.code ?? "").isEmpty { problems.append(label + " opens the generator without code") }
                }
            }
        }
        XCTAssertGreaterThan(generators, 0, "No generator card in the bundled path")
        XCTAssertEqual(problems, [])
    }

    func testTheApiLessonsComeInOrderAndBeforeEveryLessonThatGenerates() throws {
        let path = StudyPath.bundled
        let api = try XCTUnwrap(path.sections.first { $0.id == "api" })
        XCTAssertEqual(api.lessons.map(\.id), ["api-what", "api-key", "api-buzz", "api-doors", "api-issue", "api-air", "api-first"])
        XCTAssertFalse(path.lessons.contains { $0.id == "tools-myth" }, "tools-myth was removed")
        let ids = path.sections.map(\.id)
        let apiIndex = try XCTUnwrap(ids.firstIndex(of: "api"))
        for later in ["s5", "s6", "s7"] {
            XCTAssertLessThan(apiIndex, try XCTUnwrap(ids.firstIndex(of: later), later), "api comes before \(later)")
        }
    }

    func testTheBundledPathIsVersionThree() {
        XCTAssertEqual(StudyPath.bundled.version, 3)
    }

    func testTheTagLessonsOfTheMiddleSectionsHaveFiveTagsEachAndABossAndAConceptFollow() throws {
        let path = StudyPath.bundled
        for id in ["s2", "s3", "s4"] {
            let section = try XCTUnwrap(path.sections.first { $0.id == id }, id)
            let tagLessons = section.lessons.filter { $0.kind == .tags }
            XCTAssertFalse(tagLessons.isEmpty, id)
            for lesson in tagLessons { XCTAssertEqual(lesson.tags?.count, 5, lesson.id) }
            XCTAssertEqual(section.lessons.last?.id, id + "-boss", "\(id) ends with its boss")
            XCTAssertEqual(section.lessons.last?.kind, .boss)
        }
        XCTAssertEqual(path.sections.first { $0.id == "s4" }?.lessons.first { $0.id == "s4-quality" }?.kind, .concept)
    }

    func testEveryLessonIDIsUsedOnceAcrossThePathAndEveryBossHasAtLeastThreeBuilds() {
        let lessons = StudyPath.bundled.lessons
        let ids = lessons.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        let bosses = lessons.filter { $0.kind == .boss }
        XCTAssertFalse(bosses.isEmpty)
        for boss in bosses {
            XCTAssertGreaterThanOrEqual((boss.steps ?? []).compactMap(\.build).count, 3, "\(boss.id) has too few builds")
        }
    }

    func testEveryTagsLessonHasFourToSixDistinctTagsAllInTheBundledCurriculum() {
        let curriculum = StudyCurriculum.bundled
        for lesson in StudyPath.bundled.lessons where lesson.kind == .tags {
            let tags = lesson.tags ?? []
            XCTAssertTrue((4...6).contains(tags.count), "\(lesson.id) has \(tags.count) tags")
            XCTAssertEqual(tags.count, Set(tags).count, "\(lesson.id) repeats a tag")
            for tag in tags { XCTAssertNotNil(curriculum.tag(tag), "\(lesson.id) -> \(tag)") }
        }
    }

    @MainActor func testEveryAuthoredBuildAnswerPassesJudgeAndFailsOnceAnExtraIsAdded() {
        for lesson in StudyPath.bundled.lessons {
            for build in (lesson.steps ?? []).compactMap(\.build) {
                XCTAssertTrue(StudyLessonSession.judge(build.answer, build), "\(lesson.id): \(build.answer)")
                if let extra = build.extras.first { XCTAssertFalse(StudyLessonSession.judge(build.answer + [extra], build)) }
            }
        }
    }

    // MARK: - current and isOpen

    private func record(_ lesson: StudyPathLesson, stars: Int = 3) -> StudyLessonRecord { .init(lesson: lesson.id, stars: stars, runs: 1) }

    func testCurrentIsTheFirstUnfinishedLessonAndNilOnceEveryLessonIsDone() {
        let path = StudyPath.bundled
        let lessons = path.lessons
        XCTAssertGreaterThanOrEqual(lessons.count, 6)
        XCTAssertEqual(path.current([:])?.id, lessons[0].id)
        let three = Dictionary(uniqueKeysWithValues: lessons.prefix(3).map { ($0.id, record($0)) })
        XCTAssertEqual(path.current(three)?.id, lessons[3].id)
        // A lesson finished out of order does not move the learner past an earlier one.
        let skipped = [lessons[2].id: record(lessons[2])]
        XCTAssertEqual(path.current(skipped)?.id, lessons[0].id)
        let all = Dictionary(uniqueKeysWithValues: lessons.map { ($0.id, record($0)) })
        XCTAssertNil(path.current(all))
        XCTAssertNil(StudyPath().current([:]), "A path without lessons has none to be on")
    }

    func testAnUnfinishedLessonIsOpenOnlyWhenItIsTheCurrentOne() {
        let path = StudyPath.bundled
        let lessons = path.lessons
        XCTAssertGreaterThanOrEqual(lessons.count, 6)
        XCTAssertTrue(path.isOpen(lessons[0], [:]))
        XCTAssertFalse(path.isOpen(lessons[1], [:]))
        let three = Dictionary(uniqueKeysWithValues: lessons.prefix(3).map { ($0.id, record($0)) })
        for (index, lesson) in lessons.enumerated() { XCTAssertEqual(path.isOpen(lesson, three), index <= 3, "lesson \(index)") }
        let all = Dictionary(uniqueKeysWithValues: lessons.map { ($0.id, record($0, stars: 1)) })
        XCTAssertTrue(lessons.allSatisfy { path.isOpen($0, all) }, "Finished lessons stay open to play again")
        let skipped = [lessons[2].id: record(lessons[2])]
        XCTAssertTrue(path.isOpen(lessons[2], skipped))
        XCTAssertTrue(path.isOpen(lessons[0], skipped))
        XCTAssertFalse(path.isOpen(lessons[1], skipped))
    }

    // MARK: - Placement

    func testThePlacementTestAsksOneQuestionForEverySectionInPathOrder() {
        let path = StudyPath.bundled
        var generator = SystemRandomNumberGenerator()
        let questions = StudyPlacement.questions(path, curriculum: .bundled, language: "en", using: &generator)
        XCTAssertEqual(questions.map(\.section), Array(path.sections.indices), "Every section with lessons is checked once, in order")
        for question in questions {
            let ask = question.ask
            XCTAssertTrue(ask.choices.indices.contains(ask.answer))
            XCTAssertEqual(Set(ask.choices.map { $0.resolved("en") }).count, ask.choices.count, "Choices are distinct")
            let section = path.sections[question.section]
            if section.lessons.allSatisfy({ ($0.steps ?? []).allSatisfy { $0.ask == nil } }) {
                // A section that only teaches tags is checked by a meaning and that lesson's own tags.
                XCTAssertEqual(ask.code, true)
                let taught = Set(section.lessons.flatMap { $0.tags ?? [] }.map(StudyPrompt.words))
                XCTAssertTrue(ask.choices.allSatisfy { taught.contains($0.resolved("en")) }, "Wrong answers come from the section's own tags")
                XCTAssertGreaterThanOrEqual(ask.choices.count, 2)
            }
        }
    }

    func testThePlacementTestPassesByTheLessonsBeforeTheFirstMissedSection() {
        let path = StudyPath.bundled
        XCTAssertEqual(StudyPlacement.skipped(path, stoppedAt: 0), 0, "Missing the first question starts at the beginning")
        XCTAssertEqual(StudyPlacement.skipped(path, stoppedAt: 2), path.sections[0].lessons.count + path.sections[1].lessons.count)
        XCTAssertEqual(StudyPlacement.skipped(path, stoppedAt: nil), path.lessons.count - path.sections.last!.lessons.count,
                       "Nothing missed begins at the last section")
        XCTAssertEqual(StudyPlacement.skipped(StudyPath(), stoppedAt: nil), 0)
        XCTAssertEqual(StudyPlacement.section(path, placed: 0)?.id, path.sections[0].id)
        XCTAssertEqual(StudyPlacement.section(path, placed: StudyPlacement.skipped(path, stoppedAt: 3))?.id, path.sections[3].id)
    }

    func testAPlacedLearnerStartsAtThePlacementAndTheLessonsPassedByStayOpen() {
        let path = StudyPath.bundled
        let lessons = path.lessons
        let placed = StudyPlacement.skipped(path, stoppedAt: 2)
        XCTAssertEqual(path.current([:], placed: placed)?.id, lessons[placed].id)
        for (index, lesson) in lessons.enumerated() {
            XCTAssertEqual(path.isOpen(lesson, [:], placed: placed), index <= placed, "lesson \(index)")
            XCTAssertEqual(path.isSkipped(lesson, [:], placed: placed), index < placed, "lesson \(index)")
        }
        let first = [lessons[placed].id: record(lessons[placed])]
        XCTAssertEqual(path.current(first, placed: placed)?.id, lessons[placed + 1].id)
        XCTAssertFalse(path.isSkipped(lessons[0], [lessons[0].id: record(lessons[0])], placed: placed), "A passed-by lesson played since is finished")
        // With everything from the placement on finished, the learner is sent back to what was passed by.
        let rest = Dictionary(uniqueKeysWithValues: lessons.dropFirst(placed).map { ($0.id, record($0)) })
        XCTAssertEqual(path.current(rest, placed: placed)?.id, lessons[0].id)
        XCTAssertEqual(path.current([:], placed: 10_000)?.id, lessons[0].id, "A count beyond the path falls back to the first lesson")
    }

    func testTheWelcomeShowsOnlyBeforeAnythingIsPlayedPlacedOrWelcomed() {
        let defaults = freshDefaults()
        XCTAssertTrue(StudyPlacement.needsWelcome(records: [:], xp: 0, placed: 0, defaults: defaults))
        XCTAssertFalse(StudyPlacement.needsWelcome(records: ["a": .init(lesson: "a", stars: 1, runs: 1)], xp: 0, placed: 0, defaults: defaults))
        XCTAssertFalse(StudyPlacement.needsWelcome(records: [:], xp: 5, placed: 0, defaults: defaults))
        XCTAssertFalse(StudyPlacement.needsWelcome(records: [:], xp: 0, placed: 4, defaults: defaults), "A placement synced from another device counts")
        defaults.set(true, forKey: StudyPlacement.welcomedKey)
        XCTAssertFalse(StudyPlacement.needsWelcome(records: [:], xp: 0, placed: 0, defaults: defaults))
    }

    @MainActor func testThePlacementSessionStopsAtTheFirstMissEarnsNothingAndRecordsWhereItPlaced() async throws {
        let store = try BooruStore()
        let session = StudyLessonSession(plan: .placement, store: store, source: PathFakeSource(), server: pathServer, engine: StudyEngine(curriculum: .bundled))
        await session.start()
        XCTAssertEqual(session.steps.count, StudyPath.bundled.sections.count)
        // Right for the first three sections, then missed.
        for _ in 0..<3 { session.answer(true); session.next() }
        session.answer(false)
        XCTAssertEqual(session.phase, .feedback(false))
        session.next()
        XCTAssertEqual(session.phase, .finished, "The first miss ends the test")
        XCTAssertEqual(session.stoppedAt, 3)
        XCTAssertEqual(session.placed, StudyPlacement.skipped(.bundled, stoppedAt: 3))
        XCTAssertEqual(try store.studyStore.stats()[StudyPlacement.counter], session.placed)
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        XCTAssertEqual(try todaysXP(store), 0, "The test earns no experience")
        XCTAssertTrue(try store.studyStore.progress().isEmpty, "No tag is scheduled by the test")
        try store.studyStore.reset()
        XCTAssertNil(try store.studyStore.stats()[StudyPlacement.counter], "A reset clears the placement")
    }

    @MainActor func testAPlacementMissedAtTheFirstQuestionStartsAtTheBeginningAndRecordsNothing() async throws {
        let store = try BooruStore()
        let session = StudyLessonSession(plan: .placement, store: store, source: PathFakeSource(), server: pathServer, engine: StudyEngine(curriculum: .bundled))
        await session.start()
        session.answer(false); session.next()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.placed, 0)
        XCTAssertNil(try store.studyStore.stats()[StudyPlacement.counter])
    }

    // MARK: - Ask.shuffled

    private func ask(answer: Int = 0, count: Int = 3, code: Bool? = nil) -> StudyPathLesson.Ask {
        .init(question: ["en": "Q"], choices: (0..<count).map { ["en": "choice \($0)"] }, answer: answer, why: ["en": "Because"], code: code)
    }

    func testShuffledKeepsTheChoicesAndTheRightAnswerPointsAtTheSameText() {
        for original in [ask(), ask(answer: 2), ask(answer: 1, count: 4, code: true), ask(count: 2)] {
            for seed: UInt64 in 0..<60 {
                var generator = PathSplitMix64(seed: seed)
                let mixed = original.shuffled(using: &generator)
                XCTAssertEqual(Set(mixed.choices), Set(original.choices), "seed \(seed)")
                XCTAssertEqual(mixed.choices.count, original.choices.count)
                XCTAssertEqual(mixed.choices[mixed.answer], original.choices[original.answer], "seed \(seed)")
                XCTAssertEqual(mixed.question, original.question)
                XCTAssertEqual(mixed.why, original.why)
                XCTAssertEqual(mixed.code, original.code)
            }
        }
    }

    func testShuffledDoesNotAlwaysLeaveTheAnswerFirst() {
        let original = ask(count: 4)
        var positions = Set<Int>()
        for seed: UInt64 in 0..<200 {
            var generator = PathSplitMix64(seed: seed)
            positions.insert(original.shuffled(using: &generator).answer)
        }
        XCTAssertEqual(positions, [0, 1, 2, 3], "Over 200 seeds the answer lands in every place")
        var system = SystemRandomNumberGenerator()
        let moved = (0..<100).contains { _ in original.shuffled(using: &system).answer != 0 }
        XCTAssertTrue(moved)
    }

    func testEveryBundledAskKeepsItsRightTextWhenShuffled() {
        var generator = PathSplitMix64(seed: 99)
        var seen = 0
        for lesson in StudyPath.bundled.lessons {
            for ask in (lesson.steps ?? []).compactMap(\.ask) {
                seen += 1
                for _ in 0..<10 {
                    let mixed = ask.shuffled(using: &generator)
                    XCTAssertEqual(mixed.choices[mixed.answer], ask.choices[ask.answer], lesson.id)
                    XCTAssertEqual(Set(mixed.choices), Set(ask.choices))
                }
            }
        }
        XCTAssertGreaterThan(seen, 0)
    }

    // MARK: - Game numbers

    func testEarnedGivesTenAndFiveMoreForNoMistakesAndThreeMoreForARunOfFive() {
        XCTAssertEqual(StudyGame.earned(mistakes: 0, bestCombo: 0), 15)
        XCTAssertEqual(StudyGame.earned(mistakes: 1, bestCombo: 0), 10)
        XCTAssertEqual(StudyGame.earned(mistakes: 0, bestCombo: 4), 15)
        XCTAssertEqual(StudyGame.earned(mistakes: 0, bestCombo: 5), 18)
        XCTAssertEqual(StudyGame.earned(mistakes: 2, bestCombo: 4), 10)
        XCTAssertEqual(StudyGame.earned(mistakes: 1, bestCombo: 5), 13)
        XCTAssertEqual(StudyGame.earned(mistakes: 9, bestCombo: 30), 13)
    }

    func testStarsAreThreeForNoMistakesTwoForOneOrTwoAndOneForMore() {
        XCTAssertEqual(StudyGame.stars(mistakes: 0), 3)
        XCTAssertEqual(StudyGame.stars(mistakes: 1), 2)
        XCTAssertEqual(StudyGame.stars(mistakes: 2), 2)
        XCTAssertEqual(StudyGame.stars(mistakes: 3), 1)
        XCTAssertEqual(StudyGame.stars(mistakes: 40), 1)
    }

    func testLevelAndLevelProgressFollowEveryHundredExperience() {
        var game = StudyGame()
        XCTAssertEqual(game.level, 1)
        XCTAssertEqual(game.levelProgress, 0, accuracy: 1e-9)
        game.xp = 99
        XCTAssertEqual(game.level, 1)
        XCTAssertEqual(game.levelProgress, 0.99, accuracy: 1e-9)
        game.xp = 100
        XCTAssertEqual(game.level, 2)
        XCTAssertEqual(game.levelProgress, 0, accuracy: 1e-9)
        game.xp = 250
        XCTAssertEqual(game.level, 3)
        XCTAssertEqual(game.levelProgress, 0.5, accuracy: 1e-9)
    }

    func testGoalProgressStopsAtOneAndTheGoalIsMetWhenTodayReachesIt() {
        var game = StudyGame()
        XCTAssertEqual(game.goal, StudyGame.defaultGoal)
        XCTAssertTrue(StudyGame.goals.contains(StudyGame.defaultGoal))
        XCTAssertEqual(game.goalProgress, 0, accuracy: 1e-9)
        XCTAssertFalse(game.goalMet)
        game.today = 5
        XCTAssertEqual(game.goalProgress, 0.25, accuracy: 1e-9)
        XCTAssertFalse(game.goalMet)
        game.today = 20
        XCTAssertEqual(game.goalProgress, 1, accuracy: 1e-9)
        XCTAssertTrue(game.goalMet)
        game.today = 75
        XCTAssertEqual(game.goalProgress, 1, accuracy: 1e-9, "A day past the goal still shows a full ring")
        XCTAssertTrue(game.goalMet)
        game.goal = 0
        XCTAssertEqual(game.goalProgress, 1)
    }

    func testGameFromDaysSumsEveryDaysExperienceAndReadsTodays() {
        let now = date(2026, 3, 10)
        let days = [StudyDay(day: "2026-03-10", answered: 4, correct: 3, xp: 12), StudyDay(day: "2026-03-09", xp: 30), StudyDay(day: "2026-03-01", answered: 2, correct: 2)]
        let game = StudyGame(days: days, goal: 30, now: now, calendar: utc)
        XCTAssertEqual(game.xp, 42)
        XCTAssertEqual(game.today, 12)
        XCTAssertEqual(game.goal, 30)
        XCTAssertEqual(game.level, 1)
        let quiet = StudyGame(days: Array(days.dropFirst()), goal: 10, now: now, calendar: utc)
        XCTAssertEqual(quiet.xp, 30)
        XCTAssertEqual(quiet.today, 0)
        XCTAssertEqual(StudyGame(days: [], goal: 20, now: now, calendar: utc), StudyGame())
    }

    func testADayWithExperienceButNoAnswersIsStudiedAndKeepsTheStreak() {
        XCTAssertTrue(StudyDay(day: "d", xp: 5).isStudied)
        XCTAssertTrue(StudyDay(day: "d", answered: 1).isStudied)
        XCTAssertFalse(StudyDay(day: "d").isStudied)
        let now = date(2026, 3, 10)
        let days = [StudyDay(day: "2026-03-10", xp: 15), StudyDay(day: "2026-03-09", answered: 3, correct: 1), StudyDay(day: "2026-03-08", xp: 10)]
        let summary = StudySummary(curriculum: .empty, progress: [:], days: days, now: now, calendar: utc)
        XCTAssertEqual(summary.streak, 3)
        XCTAssertEqual(summary.today, 0, "Experience alone is not an answer")
        XCTAssertEqual(summary.todayCorrect, 0)
        let before = StudySummary(curriculum: .empty, progress: [:], days: Array(days.dropFirst()), now: now, calendar: utc)
        XCTAssertEqual(before.streak, 2, "Yesterday's studied days still count before today's first lesson")
    }

    // MARK: - Store

    @MainActor func testEarnAddsExperienceToTheDayAndLeavesItsAnswersAlone() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        try study.answer("solo", right: true, now: now, calendar: utc)
        try study.answer("solo", right: false, now: now, calendar: utc)
        try study.earn(15, now: now, calendar: utc)
        XCTAssertEqual(try study.days(), [StudyDay(day: "2026-03-10", answered: 2, correct: 1, xp: 15)])
        try study.earn(5, now: now.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(try study.days(), [StudyDay(day: "2026-03-10", answered: 2, correct: 1, xp: 20)])
        try study.answer("solo", right: true, now: now, calendar: utc)
        XCTAssertEqual(try study.days(), [StudyDay(day: "2026-03-10", answered: 3, correct: 2, xp: 20)], "Answering later keeps the experience")
        XCTAssertEqual(try study.progress()["solo"]?.correct, 2, "Earning touches no tag's progress")
    }

    @MainActor func testEarnOnADayWithoutAnswersCreatesARowThatCountsForTheStreak() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        try study.earn(15, now: now, calendar: utc)
        XCTAssertEqual(try study.days(), [StudyDay(day: "2026-03-10", answered: 0, correct: 0, xp: 15)])
        try study.earn(10, now: now.addingTimeInterval(-86_400), calendar: utc)
        let days = try study.days()
        XCTAssertEqual(days.map(\.day), ["2026-03-10", "2026-03-09"])
        XCTAssertEqual(StudySummary(curriculum: .empty, progress: [:], days: days, now: now, calendar: utc).streak, 2)
        XCTAssertEqual(StudyGame(days: days, goal: 20, now: now, calendar: utc).xp, 25)
        XCTAssertTrue(try study.lessons().isEmpty, "Earning without a lesson records none")
    }

    @MainActor func testEarnNeverTakesExperienceAway() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        try study.earn(10, now: now, calendar: utc)
        try study.earn(-50, now: now, calendar: utc)
        XCTAssertEqual(try study.days().first?.xp, 10)
    }

    @MainActor func testEarnWithALessonRecordsItsStarsKeepsTheBestOnAReplayAndCountsRuns() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        XCTAssertTrue(try study.lessons().isEmpty)
        try study.earn(13, lesson: "s1-who", stars: 2, now: now, calendar: utc)
        XCTAssertEqual(try study.lessons()["s1-who"], StudyLessonRecord(lesson: "s1-who", stars: 2, runs: 1))
        try study.earn(10, lesson: "s1-who", stars: 1, now: now, calendar: utc)
        XCTAssertEqual(try study.lessons()["s1-who"], StudyLessonRecord(lesson: "s1-who", stars: 2, runs: 2), "A worse replay keeps the better stars")
        try study.earn(18, lesson: "s1-who", stars: 3, now: now, calendar: utc)
        XCTAssertEqual(try study.lessons()["s1-who"], StudyLessonRecord(lesson: "s1-who", stars: 3, runs: 3))
        XCTAssertEqual(try study.days().first?.xp, 41, "Every run's experience is added")
    }

    @MainActor func testEarnKeepsStarsBetweenOneAndThreeAndLessonsApart() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        try study.earn(1, lesson: "low", stars: 0, now: now, calendar: utc)
        try study.earn(1, lesson: "high", stars: 7, now: now, calendar: utc)
        let lessons = try study.lessons()
        XCTAssertEqual(lessons["low"]?.stars, 1)
        XCTAssertEqual(lessons["high"]?.stars, 3)
        XCTAssertEqual(Set(lessons.keys), ["low", "high"])
    }

    @MainActor func testLessonsRoundTripAsADictionaryByLessonID() throws {
        let study = try BooruStore().studyStore
        let now = date(2026, 3, 10)
        try study.earn(10, lesson: "a", stars: 3, now: now, calendar: utc)
        try study.earn(10, lesson: "b", stars: 1, now: now, calendar: utc)
        try study.earn(10, lesson: "b", stars: 1, now: now, calendar: utc)
        XCTAssertEqual(try study.lessons(), ["a": StudyLessonRecord(lesson: "a", stars: 3, runs: 1), "b": StudyLessonRecord(lesson: "b", stars: 1, runs: 2)])
    }

    @MainActor func testResetClearsLessonsAndExperienceAsWellAsProgressAndDays() throws {
        let store = try BooruStore()
        let study = store.studyStore
        let now = date(2026, 3, 10)
        try study.answer("solo", right: true, now: now, calendar: utc)
        try study.earn(15, lesson: "a", stars: 3, now: now, calendar: utc)
        try study.save(StudyTagInfo(name: "solo", count: 3, category: 0, wiki: nil, related: [], fetched: .now, complete: true), address: "https://a.example")
        try study.reset()
        XCTAssertTrue(try study.lessons().isEmpty)
        XCTAssertTrue(try study.progress().isEmpty)
        XCTAssertTrue(try study.days().isEmpty)
        XCTAssertEqual(StudyGame(days: try study.days(), goal: 20, now: now, calendar: utc).xp, 0)
        XCTAssertNotNil(try study.info("solo", address: "https://a.example"), "What servers said about tags is kept")
    }

    // MARK: - Server choice

    private func freshDefaults() -> UserDefaults {
        let name = "study-path-tests-" + UUID().uuidString
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func server(_ id: String, _ host: String, _ engine: BooruEngine) -> BooruServer {
        BooruServer(id: id, name: id, baseURL: URL(string: "https://" + host)!, engine: engine)
    }

    @MainActor func testWithNoServersTheCurrentOneIsSafebooruAndNothingNeedsChoosing() throws {
        let store = try BooruStore()
        let defaults = freshDefaults()
        XCTAssertTrue(store.selectableServers.isEmpty)
        XCTAssertTrue(StudyServer.fallback.isSafebooru)
        XCTAssertTrue(StudyServer.current(store, defaults: defaults).isSafebooru)
        XCTAssertFalse(StudyServer.needsChoice(store, defaults: defaults))
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [StudyServer.fallback.id])
    }

    func testRecommendedPrefersDanbooruOnItsOwnSiteThenAnyDanbooruThenSafebooru() {
        let donmai = server("p-donmai", "danbooru.donmai.us", .danbooru)
        let otherDan = server("p-dan", "dan.example", .danbooru)
        let gel = server("p-gel", "gel.example", .gelbooru)
        let notDan = server("p-wrong", "danbooru.donmai.us", .gelbooru)
        let safe = BooruServer.safebooru()
        XCTAssertEqual(StudyServer.recommended([gel, otherDan, donmai]).id, donmai.id)
        XCTAssertEqual(StudyServer.recommended([donmai, otherDan]).id, donmai.id)
        XCTAssertEqual(StudyServer.recommended([gel, otherDan]).id, otherDan.id)
        XCTAssertEqual(StudyServer.recommended([notDan, otherDan]).id, otherDan.id, "The site's name alone is not enough; the engine must be Danbooru")
        XCTAssertEqual(StudyServer.recommended([gel, safe]).id, safe.id)
        XCTAssertEqual(StudyServer.recommended([safe, otherDan]).id, otherDan.id)
        XCTAssertEqual(StudyServer.recommended([gel]).id, gel.id)
        XCTAssertEqual(StudyServer.recommended([]).id, StudyServer.fallback.id)
    }

    @MainActor func testWithServersAndNothingChosenAChoiceIsNeededAndTheRecommendedOneIsCurrent() throws {
        let store = try BooruStore()
        let defaults = freshDefaults()
        let moe = server("p-moe", "moe.example", .moebooru), dan = server("p-dan", "dan.example", .danbooru)
        try store.saveServer(moe)
        try store.saveServer(dan)
        XCTAssertTrue(StudyServer.needsChoice(store, defaults: defaults))
        XCTAssertEqual(StudyServer.current(store, defaults: defaults).id, dan.id)
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [moe.id, dan.id, StudyServer.fallback.id], "Safebooru is offered beside the learner's own")
    }

    @MainActor func testAStoredChoiceWinsAndNeedsNoFurtherChoosing() throws {
        let store = try BooruStore()
        let defaults = freshDefaults()
        let moe = server("p-moe", "moe.example", .moebooru), dan = server("p-dan", "dan.example", .danbooru)
        try store.saveServer(moe)
        try store.saveServer(dan)
        defaults.set(moe.id, forKey: StudyServer.key)
        XCTAssertEqual(StudyServer.current(store, defaults: defaults).id, moe.id)
        XCTAssertFalse(StudyServer.needsChoice(store, defaults: defaults))
        // Safebooru, offered although not added, can be the choice too.
        defaults.set(StudyServer.fallback.id, forKey: StudyServer.key)
        XCTAssertEqual(StudyServer.current(store, defaults: defaults).id, StudyServer.fallback.id)
        XCTAssertFalse(StudyServer.needsChoice(store, defaults: defaults))
    }

    @MainActor func testAStoredServerThatNoLongerExistsNeedsAChoiceAgainAndFallsBackToTheRecommendedOne() throws {
        let store = try BooruStore()
        let defaults = freshDefaults()
        let gel = server("p-gel", "gel.example", .gelbooru), dan = server("p-dan", "dan.example", .danbooru)
        try store.saveServer(gel)
        try store.saveServer(dan)
        defaults.set(dan.id, forKey: StudyServer.key)
        XCTAssertFalse(StudyServer.needsChoice(store, defaults: defaults))
        try store.deleteServer(dan)
        XCTAssertTrue(StudyServer.needsChoice(store, defaults: defaults))
        XCTAssertEqual(StudyServer.current(store, defaults: defaults).id, StudyServer.fallback.id, "Nothing Danbooru is left, so Safebooru is suggested")
        defaults.set("never-existed", forKey: StudyServer.key)
        XCTAssertTrue(StudyServer.needsChoice(store, defaults: defaults))
    }

    @MainActor func testChoicesAddSafebooruOnlyWhenTheLearnerHasNone() throws {
        let store = try BooruStore()
        let dan = server("p-dan", "dan.example", .danbooru)
        try store.saveServer(dan)
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [dan.id, StudyServer.fallback.id])
        let safe = BooruServer.safebooru()
        try store.saveServer(safe)
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [dan.id, safe.id], "The learner's own Safebooru is not listed twice")
    }

    @MainActor func testSafeModeOffersOnlySafebooru() throws {
        let store = try BooruStore()
        let defaults = freshDefaults()
        let dan = server("p-dan", "dan.example", .danbooru)
        try store.saveServer(dan)
        store.safeMode = true
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [StudyServer.fallback.id])
        XCTAssertTrue(StudyServer.current(store, defaults: defaults).isSafebooru)
        XCTAssertFalse(StudyServer.needsChoice(store, defaults: defaults), "Nothing but Safebooru can be chosen")
        let safe = BooruServer.safebooru()
        try store.saveServer(safe)
        XCTAssertEqual(StudyServer.choices(store).map(\.id), [safe.id])
        XCTAssertEqual(StudyServer.current(store, defaults: defaults).id, safe.id)
    }

    // MARK: - judge

    private func build(_ answer: [String], extras: [String] = ["crying"]) -> StudyPathLesson.Build {
        .init(brief: ["en": "A picture"], answer: answer, extras: extras)
    }

    @MainActor func testJudgePassesTheRightTagsWithTheHeadcountFirstInAnyOrderOtherwise() {
        let target = build(["1girl", "solo", "smile", "blush"])
        XCTAssertTrue(StudyLessonSession.judge(["1girl", "solo", "smile", "blush"], target))
        XCTAssertTrue(StudyLessonSession.judge(["solo", "1girl", "smile", "blush"], target), "Headcount tags may swap places")
        XCTAssertTrue(StudyLessonSession.judge(["1girl", "solo", "blush", "smile"], target), "Order among the other tags does not matter")
        XCTAssertTrue(StudyLessonSession.judge(["solo", "1girl", "blush", "smile"], target))
        XCTAssertTrue(StudyLessonSession.judge(["1girl"], build(["1girl"])))
        XCTAssertTrue(StudyLessonSession.judge(["blush", "smile"], build(["smile", "blush"])), "A build with no headcount tag has no order to keep")
    }

    @MainActor func testJudgeFailsAHeadcountTagWrittenAfterAnotherTag() {
        let target = build(["1girl", "solo", "smile", "blush"])
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "smile", "solo", "blush"], target))
        XCTAssertFalse(StudyLessonSession.judge(["smile", "blush", "1girl", "solo"], target))
        XCTAssertFalse(StudyLessonSession.judge(["smile", "1girl", "solo", "blush"], target))
        XCTAssertFalse(StudyLessonSession.judge(Array(["1girl", "solo", "smile", "blush"].reversed()), target))
    }

    @MainActor func testJudgeFailsAMissingAnExtraAndAWrongTag() {
        let target = build(["1girl", "solo", "smile", "blush"])
        XCTAssertFalse(StudyLessonSession.judge([], target))
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile"], target), "One tag short")
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile", "blush", "crying"], target), "One tag too many")
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile", "crying"], target), "Right count, wrong tag")
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile", "blush", "2girls"], target))
    }

    @MainActor func testJudgeFailsDuplicates() {
        let target = build(["1girl", "solo", "smile", "blush"])
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile", "blush", "blush"], target), "Every right tag, one of them twice")
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "1girl", "solo", "smile", "blush"], target))
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "solo", "smile", "smile"], target), "Right count, one tag twice and one missing")
        XCTAssertFalse(StudyLessonSession.judge(["1girl", "1girl"], build(["1girl", "solo"])))
    }

    private func order(_ items: [String]) -> StudyPathLesson.Order {
        .init(brief: ["en": "Put in order"], items: items.map { ["en": $0] }, why: ["en": "Because"])
    }

    @MainActor func testJudgeAnOrderPassesOnlyTheRightOrder() {
        let target = order(["a", "b", "c", "d"])
        func text(_ items: [String]) -> [StudyText] { items.map { ["en": $0] } }
        XCTAssertTrue(StudyLessonSession.judge(text(["a", "b", "c", "d"]), target))
        XCTAssertFalse(StudyLessonSession.judge(text(["a", "c", "b", "d"]), target), "Two swapped")
        XCTAssertFalse(StudyLessonSession.judge(text(["d", "c", "b", "a"]), target), "Reversed")
        XCTAssertFalse(StudyLessonSession.judge(text(["a", "b", "c"]), target), "One missing")
        XCTAssertFalse(StudyLessonSession.judge([], target))
        XCTAssertFalse(StudyLessonSession.judge(text(["a", "b", "c", "d", "e"]), target), "One extra")
        XCTAssertFalse(StudyLessonSession.judge(text(["a", "b", "c", "d", "d"]), target), "One repeated")
        XCTAssertFalse(StudyLessonSession.judge(text(["a", "b", "c", "x"]), target), "Right count, wrong item")
    }

    @MainActor func testEveryAuthoredOrderPassesJudgeInItsOwnOrderAndFailsWhenTwoItemsSwap() {
        for lesson in StudyPath.bundled.lessons {
            for order in (lesson.steps ?? []).compactMap(\.order) {
                XCTAssertTrue(StudyLessonSession.judge(order.items, order), lesson.id)
                var swapped = order.items
                swapped.swapAt(0, swapped.count - 1)
                XCTAssertFalse(StudyLessonSession.judge(swapped, order), lesson.id)
            }
        }
    }

    // MARK: - Milestones

    func testNothingIsReachedWhenNothingWasEarned() {
        let before = StudyStanding(xp: 95, today: 15, studiedToday: false)
        XCTAssertEqual(StudyMilestone.reached(before: before, earned: 0, goal: 20, streak: 4), [])
    }

    func testTheStreakIsReachedOnTheDaysFirstStudyWhenThereIsOne() {
        let first = StudyStanding(xp: 0, today: 0, studiedToday: false)
        XCTAssertEqual(StudyMilestone.reached(before: first, earned: 5, goal: 50, streak: 3), [.streak(3)])
        XCTAssertEqual(StudyMilestone.reached(before: first, earned: 5, goal: 50, streak: 0), [], "No streak to celebrate")
        let later = StudyStanding(xp: 10, today: 10, studiedToday: true)
        XCTAssertEqual(StudyMilestone.reached(before: later, earned: 5, goal: 50, streak: 3), [], "Already studied today")
    }

    func testTheGoalIsReachedOnlyByTheLessonThatCrossesIt() {
        let studied = { (today: Int) in StudyStanding(xp: today, today: today, studiedToday: true) }
        XCTAssertEqual(StudyMilestone.reached(before: studied(10), earned: 10, goal: 20, streak: 1), [.goal(20)], "Landing exactly on the goal counts")
        XCTAssertEqual(StudyMilestone.reached(before: studied(15), earned: 18, goal: 20, streak: 1), [.goal(20)])
        XCTAssertEqual(StudyMilestone.reached(before: studied(5), earned: 10, goal: 20, streak: 1), [], "Still short of the goal")
        XCTAssertEqual(StudyMilestone.reached(before: studied(20), earned: 10, goal: 20, streak: 1), [], "Already met before this lesson")
        XCTAssertEqual(StudyMilestone.reached(before: studied(30), earned: 10, goal: 20, streak: 1), [], "Already past it")
    }

    func testALevelIsReachedWhenExperienceCrossesAHundred() {
        let studied = { (xp: Int) in StudyStanding(xp: xp, today: 0, studiedToday: true) }
        XCTAssertEqual(StudyMilestone.reached(before: studied(95), earned: 10, goal: 500, streak: 1), [.level(2)])
        XCTAssertEqual(StudyMilestone.reached(before: studied(90), earned: 10, goal: 500, streak: 1), [.level(2)], "Landing exactly on a hundred counts")
        XCTAssertEqual(StudyMilestone.reached(before: studied(80), earned: 10, goal: 500, streak: 1), [])
        XCTAssertEqual(StudyMilestone.reached(before: studied(199), earned: 18, goal: 500, streak: 1), [.level(3)])
        XCTAssertEqual(StudyMilestone.reached(before: studied(100), earned: 10, goal: 500, streak: 1), [], "Already on level two")
    }

    func testAStreakAGoalAndALevelTogetherComeInThatOrder() {
        let before = StudyStanding(xp: 95, today: 0, studiedToday: false)
        XCTAssertEqual(StudyMilestone.reached(before: before, earned: 20, goal: 20, streak: 7), [.streak(7), .goal(20), .level(2)])
    }

    func testAPlainLessonReachesNothing() {
        let before = StudyStanding(xp: 30, today: 5, studiedToday: true)
        XCTAssertEqual(StudyMilestone.reached(before: before, earned: 10, goal: 20, streak: 5), [])
    }

    // MARK: - Session

    @MainActor private func makeSession(_ plan: StudyLessonPlan, store: BooruStore, source: any BooruProviding = PathFakeSource()) -> StudyLessonSession {
        StudyLessonSession(plan: plan, store: store, source: source, server: pathServer, engine: StudyEngine(curriculum: pathCurriculum))
    }

    private func tagsLesson(_ id: String = "p-tags", _ tags: [String] = ["t1", "t2", "t3", "t4"]) -> StudyPathLesson {
        StudyPathLesson(id: id, kind: .tags, symbol: "tag", title: ["en": id], tags: tags)
    }

    private func kinds(_ steps: [StudyStep]) -> [String] {
        steps.map { (step: StudyStep) -> String in
            switch step.kind {
            case .card: return "card"
            case .teach: return "teach"
            case .quiz: return "quiz"
            case .ask: return "ask"
            case .match: return "match"
            case .build: return "build"
            case .order: return "order"
            case .sort: return "sort"
            case .odd: return "odd"
            case .spell: return "spell"
            }
        }
    }

    private func quizTag(_ step: StudyStep?) -> String? {
        if case .quiz(let question)? = step?.kind { return question.tag.name }
        return nil
    }

    /// Plays a session to its end, answering every asked step as `right` says and moving past cards and new tags.
    @MainActor private func play(_ session: StudyLessonSession, right: (StudyStep) -> Bool = { _ in true }) {
        var turns = 0
        while session.phase == .asking, let step = session.step, turns < 500 {
            turns += 1
            if step.isAsked { session.answer(right(step), tag: quizTag(step)); session.next() } else { session.proceed() }
        }
    }

    /// Moves past anything that is only read, then answers the step that is asked.
    @MainActor private func answerOne(_ session: StudyLessonSession, _ right: Bool) {
        while session.phase == .asking, let step = session.step, !step.isAsked { session.proceed() }
        session.answer(right, tag: quizTag(session.step))
    }

    private func todaysXP(_ store: BooruStore) throws -> Int {
        try store.studyStore.days().first { $0.day == StudyDay.key(.now) }?.xp ?? 0
    }

    @MainActor func testATagsLessonTeachesEachTagThenAsksItThenMatchesThenAsksAllAgain() async throws {
        let store = try BooruStore()
        let session = makeSession(.lesson(tagsLesson()), store: store)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(session.tags.map(\.name), ["t1", "t2", "t3", "t4"])
        let pairs: [String] = Array(repeating: ["teach", "quiz"], count: 4).flatMap { $0 }
        let closing: [String] = Array(repeating: "quiz", count: 4)
        XCTAssertEqual(kinds(session.steps), pairs + ["match"] + closing + ["spell"], "No odd step: the pictures carry too few of the lesson's tags")
        for name in ["t1", "t2", "t3", "t4"] {
            let teach = session.steps.firstIndex { if case .teach(let tag, _) = $0.kind { return tag.name == name }; return false }
            let firstQuestion = session.steps.firstIndex { quizTag($0) == name }
            XCTAssertNotNil(teach, name)
            XCTAssertEqual(firstQuestion, teach.map { $0 + 1 }, "\(name) is asked right after it is shown")
            XCTAssertGreaterThanOrEqual(session.steps.filter { quizTag($0) == name }.count, 2, "\(name) is asked at least twice")
            if let teach, case .teach(_, let posts) = session.steps[teach].kind {
                XCTAssertTrue((1...3).contains(posts.count), "\(name) shows up to three pictures")
                XCTAssertTrue(posts.allSatisfy { $0.tags.contains(name) })
            }
        }
        XCTAssertEqual(session.steps.filter { !$0.again }.count, session.steps.count)
    }

    @MainActor func testATagsLessonHasOneMatchStepOnlyFromFourTagsAndSkipsTagsTheCurriculumDoesNotTeach() async throws {
        let store = try BooruStore()
        let four = makeSession(.lesson(tagsLesson()), store: store)
        await four.start()
        let matches = four.steps.compactMap { step -> [StudyTag]? in if case .match(let tags) = step.kind { return tags }; return nil }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.count, 4)
        XCTAssertTrue(Set(matches.first?.map(\.name) ?? []).isSubset(of: ["t1", "t2", "t3", "t4"]))

        let many = makeSession(.lesson(tagsLesson("p-many", ["t1", "t2", "t3", "t4", "t5", "t6"])), store: store)
        await many.start()
        XCTAssertEqual(kinds(many.steps).filter { $0 == "match" }.count, 1, "Still one match, of four tags")
        XCTAssertEqual(kinds(many.steps).count, 6 * 2 + 1 + 6 + 1)

        let three = makeSession(.lesson(tagsLesson("p-three", ["t1", "t2", "t3", "unknown_tag"])), store: store)
        await three.start()
        XCTAssertEqual(three.tags.map(\.name), ["t1", "t2", "t3"])
        let threePairs: [String] = Array(repeating: ["teach", "quiz"], count: 3).flatMap { $0 }
        let threeClosing: [String] = Array(repeating: "quiz", count: 3)
        XCTAssertEqual(kinds(three.steps), threePairs + threeClosing + ["spell"])
    }

    @MainActor func testATagsLessonStillPlaysWhenTheServerCannotBeReadAndAsksByMeaning() async throws {
        let store = try BooruStore()
        let session = makeSession(.lesson(tagsLesson()), store: store, source: PathFakeSource(failing: true))
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        for step in session.steps {
            switch step.kind {
            case .teach(_, let posts): XCTAssertTrue(posts.isEmpty)
            case .quiz(let question): XCTAssertEqual(question.kind, .meaningToTag)
            default: break
            }
        }
        play(session)
        XCTAssertEqual(session.phase, .finished)
    }

    @MainActor func testAnswerWorksOnlyWhileAskingOnAskedStepsAndProceedOnlyOnCardsAndNewTags() async throws {
        let store = try BooruStore()
        let session = makeSession(.lesson(tagsLesson()), store: store)
        session.answer(true, tag: "t1"); session.proceed(); session.next()
        XCTAssertEqual(session.phase, .loading)
        XCTAssertEqual(session.asked, 0)
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.progress, 0)

        await session.start()
        let count = Double(session.steps.count)
        XCTAssertFalse(try XCTUnwrap(session.step).isAsked, "A new tag is shown first")
        session.answer(true, tag: "t1")
        XCTAssertEqual(session.asked, 0, "A new tag is read, not answered")
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(session.combo, 0)
        session.next()
        XCTAssertEqual(session.index, 0, "next only follows an answer")
        session.proceed()
        XCTAssertEqual(session.index, 1)
        XCTAssertEqual(session.progress, 1 / count, accuracy: 1e-9)

        XCTAssertTrue(try XCTUnwrap(session.step).isAsked)
        session.proceed()
        XCTAssertEqual(session.index, 1, "A question is not skipped")
        session.answer(true, tag: "t1")
        XCTAssertEqual(session.phase, .feedback(true))
        XCTAssertEqual(session.progress, 2 / count, accuracy: 1e-9, "An answered step counts as done")
        session.answer(false, tag: "t1")
        session.proceed()
        XCTAssertEqual(session.asked, 1, "An answered question cannot be answered again")
        XCTAssertEqual(session.mistakes, 0)
        XCTAssertEqual(session.combo, 1)
        XCTAssertEqual(session.index, 1)
        session.next()
        XCTAssertEqual(session.index, 2)
        XCTAssertEqual(session.phase, .asking)

        let steps = session.steps.count
        await session.start()
        XCTAssertEqual(session.steps.count, steps, "Starting twice does not build the lesson again")
        XCTAssertEqual(session.index, 2)

        play(session)
        XCTAssertEqual(session.phase, .finished)
        let asked = session.asked
        session.answer(true, tag: "t1"); session.proceed(); session.next()
        XCTAssertEqual(session.asked, asked)
        XCTAssertEqual(session.progress, 1, accuracy: 1e-9)
        XCTAssertNil(session.step)
    }

    @MainActor func testAMissedStepComesBackOnceAtTheEndAndAMissOnTheRepeatAddsNoMore() async throws {
        let store = try BooruStore()
        let session = makeSession(.lesson(tagsLesson()), store: store)
        await session.start()
        let before = session.steps.count
        session.proceed()
        guard case .quiz(let missed)? = session.step?.kind else { return XCTFail("The second step is a question") }
        session.answer(false, tag: "t1")
        XCTAssertEqual(session.phase, .feedback(false))
        XCTAssertEqual(session.steps.count, before + 1)
        let repeated = try XCTUnwrap(session.steps.last)
        XCTAssertTrue(repeated.again)
        XCTAssertTrue(repeated.isAsked)
        guard case .quiz(let again) = repeated.kind else { return XCTFail("The repeat is the same question") }
        XCTAssertEqual(again.id, missed.id)
        XCTAssertEqual(session.combo, 0)
        XCTAssertEqual(session.mistakes, 1)
        session.next()

        var misses = 0
        play(session) { step in
            guard step.again else { return true }
            misses += 1
            return false
        }
        XCTAssertEqual(misses, 1, "The repeat is asked once")
        XCTAssertEqual(session.steps.count, before + 1, "A second miss adds no further step")
        XCTAssertEqual(session.steps.filter(\.again).count, 1)
        XCTAssertEqual(session.mistakes, 2)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.stars, 2)
        XCTAssertEqual(session.asked, session.steps.filter(\.isAsked).count, "Every asked step was answered once, the repeat too")
    }

    @MainActor func testComboCountsRightAnswersInARowAndBestComboKeepsTheLongestRun() async throws {
        let store = try BooruStore()
        let session = makeSession(.lesson(tagsLesson()), store: store)
        await session.start()
        var expected: [(combo: Int, best: Int, mistakes: Int)] = []
        for right in [true, true, true, false, true, true] {
            answerOne(session, right)
            expected.append((session.combo, session.bestCombo, session.mistakes))
            session.next()
        }
        XCTAssertEqual(expected.map { $0.combo }, [1, 2, 3, 0, 1, 2])
        XCTAssertEqual(expected.map { $0.best }, [1, 2, 3, 3, 3, 3])
        XCTAssertEqual(expected.map { $0.mistakes }, [0, 0, 0, 1, 1, 1])
    }

    @MainActor func testEachTagsReviewDateMovesOnceForEveryFirstAskingAndNotForTheRepeat() async throws {
        let store = try BooruStore()
        let clean = makeSession(.lesson(tagsLesson("clean")), store: store)
        await clean.start()
        play(clean)
        var progress = try store.studyStore.progress()
        for name in ["t1", "t2", "t3", "t4"] {
            XCTAssertEqual(progress[name]?.correct, 2, "\(name) was asked twice")
            XCTAssertEqual(progress[name]?.wrong, 0)
        }
        XCTAssertEqual(try store.studyStore.days().first?.answered, 8, "The match step is not a tag's answer")

        let fresh = try BooruStore()
        let missing = makeSession(.lesson(tagsLesson("missing")), store: fresh)
        await missing.start()
        var missedOnce = false
        play(missing) { step in
            if !step.again, !missedOnce, quizTag(step) == "t1" { missedOnce = true; return false }
            return true
        }
        XCTAssertEqual(missing.mistakes, 1)
        XCTAssertEqual(missing.asked, 11, "Eight questions, the match, the spelling and one repeat")
        progress = try fresh.studyStore.progress()
        XCTAssertEqual(progress["t1"]?.wrong, 1)
        XCTAssertEqual(progress["t1"]?.correct, 1, "The repeat did not move t1 again")
        XCTAssertEqual(progress["t2"]?.correct, 2)
        XCTAssertEqual(try fresh.studyStore.days().first?.answered, 8, "The repeat is not a day's answer either")
    }

    @MainActor func testFinishingRecordsTheLessonWithStarsAndAddsEarnedExperienceToToday() async throws {
        let store = try BooruStore()
        let lesson = tagsLesson("p-finish")
        let first = makeSession(.lesson(lesson), store: store)
        XCTAssertEqual(first.earned, 0)
        await first.start()
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        play(first)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(first.mistakes, 0)
        XCTAssertEqual(first.asked, 10, "Four quizzes, the match, four quizzes and the spelling")
        XCTAssertEqual(first.bestCombo, 10)
        XCTAssertEqual(first.stars, 3)
        XCTAssertEqual(first.earned, StudyGame.earned(mistakes: 0, bestCombo: 10))
        XCTAssertEqual(first.earned, 18)
        XCTAssertEqual(try store.studyStore.lessons(), ["p-finish": StudyLessonRecord(lesson: "p-finish", stars: 3, runs: 1)])
        XCTAssertEqual(try todaysXP(store), 18)

        // A weaker replay adds its experience and a run, and keeps the three stars.
        let replay = makeSession(.lesson(lesson), store: store)
        await replay.start()
        var missedOnce = false
        play(replay) { step in
            if !step.again, !missedOnce, quizTag(step) == "t1" { missedOnce = true; return false }
            return true
        }
        XCTAssertEqual(replay.stars, 2)
        XCTAssertEqual(replay.earned, 13)
        XCTAssertEqual(try store.studyStore.lessons()["p-finish"], StudyLessonRecord(lesson: "p-finish", stars: 3, runs: 2))
        XCTAssertEqual(try todaysXP(store), 31)
    }

    @MainActor func testAConceptLessonTurnsCardsAndAsksIntoStepsInOrderWithTheSameChoiceTexts() async throws {
        let card = StudyPathLesson.Card(title: ["en": "One"], body: ["en": "First card"])
        let question = StudyPathLesson.Ask(question: ["en": "Which?"], choices: [["en": "right"], ["en": "wrong"], ["en": "also wrong"]], answer: 0, why: ["en": "Because"])
        let last = StudyPathLesson.Card(title: ["en": "Two"], body: ["en": "Last card"], code: "1girl, solo")
        let lesson = StudyPathLesson(id: "p-concept", kind: .concept, symbol: "wand.and.stars", title: ["en": "Concept"],
                                     steps: [.init(card: card), .init(ask: question), .init(card: last)])
        let store = try BooruStore()
        let session = makeSession(.lesson(lesson), store: store)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(kinds(session.steps), ["card", "ask", "card"])
        XCTAssertTrue(session.tags.isEmpty)
        XCTAssertTrue(session.builtPictures.isEmpty)
        guard case .card(let shown) = session.steps[0].kind, case .ask(let asked) = session.steps[1].kind, case .card(let ending) = session.steps[2].kind else { return XCTFail("Steps are out of order") }
        XCTAssertEqual(shown, card)
        XCTAssertEqual(ending, last)
        XCTAssertEqual(Set(asked.choices), Set(question.choices))
        XCTAssertEqual(asked.choices[asked.answer], question.choices[question.answer])

        session.proceed()
        XCTAssertTrue(try XCTUnwrap(session.step).isAsked)
        session.answer(true)
        session.next()
        XCTAssertFalse(try XCTUnwrap(session.step).isAsked)
        session.proceed()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.stars, 3)
        XCTAssertEqual(session.earned, 15)
        XCTAssertEqual(try store.studyStore.lessons()["p-concept"]?.stars, 3)
        XCTAssertEqual(try todaysXP(store), 15)
        XCTAssertTrue(try store.studyStore.progress().isEmpty, "A question without a tag moves no review date")
    }

    @MainActor func testAConceptLessonTurnsOrderAndSortStepsIntoTheirKindsInTheLessonsOrder() async throws {
        let ordering = order(["first", "second", "third"])
        let sorting = StudyPathLesson.Sort(brief: ["en": "Which side?"], left: ["en": "Left"], right: ["en": "Right"],
                                           items: [.init(text: ["en": "a"], right: false), .init(text: ["en": "b"], right: true), .init(text: ["en": "c"], right: true)],
                                           why: ["en": "Because"])
        let lesson = StudyPathLesson(id: "p-order-sort", kind: .concept, symbol: "list.number", title: ["en": "Order and sort"],
                                     steps: [.init(card: .init(title: ["en": "Go"], body: ["en": "Read"])), .init(sort: sorting), .init(order: ordering), .init(sort: sorting)])
        let store = try BooruStore()
        let session = makeSession(.lesson(lesson), store: store)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(kinds(session.steps), ["card", "sort", "order", "sort"])
        guard case .sort(let firstSort) = session.steps[1].kind, case .order(let shownOrder) = session.steps[2].kind else { return XCTFail("Steps are out of order") }
        XCTAssertEqual(firstSort, sorting)
        XCTAssertEqual(shownOrder, ordering)
        XCTAssertTrue(session.steps[1].isAsked)
        XCTAssertTrue(session.steps[2].isAsked)
        XCTAssertTrue(session.tags.isEmpty)
        play(session)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.asked, 3)
        XCTAssertEqual(try store.studyStore.lessons()["p-order-sort"]?.stars, 3)
    }

    @MainActor func testBeforeHoldsWhatTheStoreHadBeforeTheLessonPaidOutAndTheDaysFirstStudyIsNotStudiedYet() async throws {
        let store = try BooruStore()
        try store.studyStore.earn(40, now: Date(timeIntervalSinceNow: -2 * 86_400))
        let lesson = StudyPathLesson(id: "p-before", kind: .concept, symbol: "doc", title: ["en": "Before"],
                                     steps: [.init(card: .init(title: ["en": "Card"], body: ["en": "Body"]))])
        let first = makeSession(.lesson(lesson), store: store)
        XCTAssertEqual(first.before, StudyStanding(xp: 0, today: 0, studiedToday: true), "Nothing is read before the lesson starts")
        await first.start()
        XCTAssertFalse(first.before.studiedToday, "Nothing earned today yet")
        first.proceed()
        XCTAssertEqual(first.phase, .finished)
        XCTAssertEqual(first.before, StudyStanding(xp: 40, today: 0, studiedToday: false), "Read before this lesson's own experience was added")
        XCTAssertEqual(try todaysXP(store), first.earned)

        // The same day's next lesson sees the first one's experience, and the day as studied.
        let second = makeSession(.lesson(lesson), store: store)
        await second.start()
        XCTAssertTrue(second.before.studiedToday)
        second.proceed()
        XCTAssertEqual(second.before, StudyStanding(xp: 40 + first.earned, today: first.earned, studiedToday: true))
        XCTAssertEqual(try todaysXP(store), first.earned + second.earned)
    }

    @MainActor func testBeforeCountsADayWithAnswersButNoExperienceAsStudied() async throws {
        let store = try BooruStore()
        try store.studyStore.answer("t1", right: true)
        let lesson = StudyPathLesson(id: "p-answered", kind: .concept, symbol: "doc", title: ["en": "Answered"],
                                     steps: [.init(card: .init(title: ["en": "Card"], body: ["en": "Body"]))])
        let session = makeSession(.lesson(lesson), store: store)
        await session.start()
        XCTAssertTrue(session.before.studiedToday)
        session.proceed()
        XCTAssertEqual(session.before.xp, 0)
        XCTAssertEqual(session.before.today, 0)
    }

    @MainActor func testAConceptLessonOfCardsAloneStillEarnsAndRecordsWhenItsLastCardIsRead() async throws {
        let cards = (1...2).map { StudyPathLesson.Step(card: .init(title: ["en": "Card \($0)"], body: ["en": "Body"])) }
        let lesson = StudyPathLesson(id: "p-cards", kind: .concept, symbol: "doc", title: ["en": "Cards"], steps: cards)
        let store = try BooruStore()
        let session = makeSession(.lesson(lesson), store: store)
        await session.start()
        session.proceed()
        XCTAssertEqual(session.phase, .asking)
        session.proceed()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.asked, 0)
        XCTAssertEqual(try store.studyStore.lessons()["p-cards"]?.runs, 1)
        XCTAssertEqual(try todaysXP(store), session.earned)
        XCTAssertGreaterThan(session.earned, 0)
    }

    @MainActor func testABossLessonHasBuildStepsAndLooksForAPictureCarryingEveryAnswerTag() async throws {
        let fits = StudyPathLesson.Build(brief: ["en": "One girl alone"], answer: ["1girl", "solo", "t1"], extras: ["2girls"])
        let second = StudyPathLesson.Build(brief: ["en": "One boy"], answer: ["1boy", "t2", "t3"], extras: ["t5"])
        let unmatched = StudyPathLesson.Build(brief: ["en": "No picture has both"], answer: ["t4", "t5"], extras: ["t6"])
        let lesson = StudyPathLesson(id: "p-boss", kind: .boss, symbol: "crown", title: ["en": "Boss"],
                                     steps: [.init(card: .init(title: ["en": "Go"], body: ["en": "Build"])), .init(build: fits), .init(build: second), .init(build: unmatched)])
        let source = PathFakeSource(extra: ["t1": ["1girl", "solo"], "t3": ["1boy", "t2"]])
        let store = try BooruStore()
        let session = makeSession(.lesson(lesson), store: store, source: source)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(kinds(session.steps), ["card", "build", "build", "build"])
        XCTAssertEqual(session.tags.map(\.name), ["t1", "t2", "t3", "t4", "t5"], "The curriculum tags the builds use, sorted")
        XCTAssertEqual(Set(session.builtPictures.keys), [fits, second], "Only a build with a fitting picture gets one")
        for (build, post) in session.builtPictures { XCTAssertTrue(Set(build.answer).isSubset(of: Set(post.tags)), build.brief["en"] ?? "") }
        XCTAssertNil(session.builtPictures[unmatched])

        session.proceed()
        for _ in 0..<3 { XCTAssertTrue(try XCTUnwrap(session.step).isAsked); session.answer(true); session.next() }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(try store.studyStore.lessons()["p-boss"]?.stars, 3)
    }

    @MainActor func testThePicturesOfAMeaningOrPictureQuestionNeverOfferATagThePictureAlsoCarriesAndPreferTheLessonsOwnTags() async throws {
        let lessonTags: Set<String> = ["t1", "t2", "t3", "t4"]
        let store = try BooruStore()
        var sawShared = false
        for _ in 0..<30 {
            // Pictures of t1 also carry t2, so t2 must never be offered as a wrong answer for them.
            let session = makeSession(.lesson(tagsLesson()), store: store, source: PathFakeSource(extra: ["t1": ["t2"]]))
            await session.start()
            for step in session.steps {
                guard case .quiz(let question) = step.kind, question.kind != .tagToPicture else { continue }
                XCTAssertEqual(question.choices[question.answer].name, question.tag.name)
                XCTAssertEqual(Set(question.choices.map(\.name)).count, question.choices.count)
                let shown = Set(question.posts.first?.tags ?? [])
                let wrong = question.choices.enumerated().filter { $0.offset != question.answer }.map { $0.element.name }
                XCTAssertTrue(Set(wrong).isDisjoint(with: shown), "\(wrong) offered beside a picture of \(shown)")
                XCTAssertFalse(wrong.contains(question.tag.name))
                let fairOwn = lessonTags.subtracting([question.tag.name]).subtracting(shown)
                XCTAssertEqual(wrong.filter { lessonTags.contains($0) }.count, min(fairOwn.count, wrong.count), "The lesson's own tags come first for \(question.tag.name)")
                if question.tag.name == "t1", shown.contains("t2") { sawShared = true }
            }
        }
        XCTAssertTrue(sawShared, "No picture question about t1 came up in 30 lessons")
    }

    @MainActor func testAReviewWithNothingDueFinishesAtOnceWithoutEarningOrRecordingAnything() async throws {
        let store = try BooruStore()
        try store.studyStore.answer("t1", right: true)
        let session = makeSession(.review, store: store)
        await session.start()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertTrue(session.steps.isEmpty)
        XCTAssertTrue(session.tags.isEmpty)
        XCTAssertEqual(session.earned, 0)
        XCTAssertEqual(session.stars, 0)
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        XCTAssertEqual(try todaysXP(store), 0)
        XCTAssertEqual(try store.studyStore.progress()["t1"]?.correct, 1)

        let empty = try BooruStore()
        let none = makeSession(.review, store: empty)
        await none.start()
        XCTAssertEqual(none.phase, .finished)
        XCTAssertTrue(try empty.studyStore.days().isEmpty)
        XCTAssertTrue(try empty.studyStore.lessons().isEmpty)
    }

    @MainActor func testAReviewOfDueTagsAsksThemAndEarnsExperienceButRecordsNoLesson() async throws {
        let store = try BooruStore()
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        try store.studyStore.answer("t1", right: true, now: past)
        try store.studyStore.answer("t2", right: true, now: past)
        try store.studyStore.answer("t3", right: true)
        let session = makeSession(.review, store: store)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(Set(session.tags.map(\.name)), ["t1", "t2"], "Only the tags that are due")
        XCTAssertEqual(kinds(session.steps), ["quiz", "quiz"])
        play(session)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.earned, 15)
        XCTAssertEqual(try todaysXP(store), 15)
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        let progress = try store.studyStore.progress()
        XCTAssertEqual(progress["t1"]?.correct, 2)
        XCTAssertEqual(progress["t2"]?.correct, 2)
        XCTAssertEqual(progress["t3"]?.correct, 1)
    }

    @MainActor func testAReviewOfFourTagsPutsOneMatchStepInTheMiddleAndRepeatsAMiss() async throws {
        let store = try BooruStore()
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        for name in ["t1", "t2", "t3", "t4"] { try store.studyStore.answer(name, right: true, now: past) }
        let session = makeSession(.review, store: store)
        await session.start()
        XCTAssertEqual(kinds(session.steps), ["quiz", "quiz", "match", "quiz", "quiz"])
        var missedOnce = false
        play(session) { step in
            if !step.again, !missedOnce, quizTag(step) != nil { missedOnce = true; return false }
            return true
        }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.steps.count, 6, "The missed question came back once")
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        XCTAssertEqual(try todaysXP(store), session.earned)
    }

    @MainActor func testALessonWithNoStepsStillFinishesAndIsRecorded() async throws {
        let store = try BooruStore()
        let lesson = tagsLesson("p-empty", ["unknown_tag"])
        let session = makeSession(.lesson(lesson), store: store)
        await session.start()
        XCTAssertEqual(session.phase, .finished)
        XCTAssertTrue(session.steps.isEmpty)
        // SUSPECTED BUG: start() sets the phase to .finished before calling finish(), whose first guard
        // returns when the phase is already .finished, so a lesson that has no steps earns and records nothing.
        // finish() otherwise lets any lesson record (`asked > 0 || plan.lesson != nil`), which suggests this was meant to.
        XCTAssertNotNil(try store.studyStore.lessons()["p-empty"])
    }

    // MARK: - Odd, spell and the weak plan

    @MainActor func testATagsLessonWhoseTagsShareAPictureAsksOddAfterTheMatchAndEndsWithOneSpelling() async throws {
        let store = try BooruStore()
        let source = PathFakeSource(extra: ["t1": ["t2", "t3"]])
        let session = makeSession(.lesson(tagsLesson()), store: store, source: source)
        await session.start()
        let pairs: [String] = Array(repeating: ["teach", "quiz"], count: 4).flatMap { $0 }
        XCTAssertEqual(kinds(session.steps), pairs + ["match", "odd"] + Array(repeating: "quiz", count: 4) + ["spell"])
        guard case .odd(let post, let choices, let answer)? = session.steps.first(where: { kinds([$0]) == ["odd"] })?.kind else { return XCTFail("No odd step") }
        XCTAssertEqual(choices.count, 4)
        XCTAssertTrue(choices.indices.contains(answer))
        XCTAssertFalse(post.tags.contains(choices[answer].name), "The answer is the tag the picture does not carry")
        for (index, tag) in choices.enumerated() where index != answer { XCTAssertTrue(post.tags.contains(tag.name), tag.name) }
        XCTAssertEqual(choices[answer].name, "t4")
        guard case .spell(let tag, _)? = session.steps.last?.kind else { return XCTFail("The last step is the spelling") }
        XCTAssertTrue(["t1", "t2", "t3", "t4"].contains(tag.name))
        XCTAssertEqual(kinds(session.steps).filter { $0 == "spell" }.count, 1)
        play(session)
        XCTAssertEqual(session.phase, .finished)
    }

    @MainActor func testATagsLessonWithoutPicturesHasNoOddStepAndItsSpellingShowsNoPicture() async throws {
        let session = makeSession(.lesson(tagsLesson()), store: try BooruStore(), source: PathFakeSource(failing: true))
        await session.start()
        XCTAssertFalse(kinds(session.steps).contains("odd"))
        XCTAssertEqual(kinds(session.steps).filter { $0 == "spell" }.count, 1)
        if case .spell(_, let post)? = session.steps.last?.kind { XCTAssertNil(post) } else { XCTFail("The last step is the spelling") }
    }

    @MainActor func testAReviewAddsOddWhenPossibleAndSpellsOnlyTagsAtStepTwoOrMoreUpToTwo() async throws {
        let store = try BooruStore()
        let past = Date(timeIntervalSinceNow: -10 * 86_400)
        for name in ["t1", "t2"] { for _ in 0..<2 { try store.studyStore.answer(name, right: true, now: past) } }
        for name in ["t3", "t4"] { try store.studyStore.answer(name, right: true, now: past) }
        let session = makeSession(.review, store: store, source: PathFakeSource(extra: ["t1": ["t2", "t3"]]))
        await session.start()
        XCTAssertEqual(kinds(session.steps), ["quiz", "quiz", "match", "quiz", "quiz", "odd", "spell", "spell"])
        let spelled = session.steps.compactMap { step -> String? in if case .spell(let tag, _) = step.kind { return tag.name }; return nil }
        XCTAssertEqual(Set(spelled), ["t1", "t2"], "Only the tags at step two or more")

        let low = try BooruStore()
        for name in ["t1", "t2", "t3", "t4"] { try low.studyStore.answer(name, right: true, now: past) }
        let plain = makeSession(.review, store: low, source: PathFakeSource(extra: ["t1": ["t2", "t3"]]))
        await plain.start()
        XCTAssertFalse(kinds(plain.steps).contains("spell"), "Tags at step one are not typed")
        XCTAssertTrue(kinds(plain.steps).contains("odd"))

        let many = try BooruStore()
        for name in ["t1", "t2", "t3", "t4"] { for _ in 0..<3 { try many.studyStore.answer(name, right: true, now: past) } }
        let capped = makeSession(.review, store: many)
        await capped.start()
        XCTAssertEqual(kinds(capped.steps).filter { $0 == "spell" }.count, 2, "At most two spellings")
        XCTAssertFalse(kinds(capped.steps).contains("odd"), "No odd step when the pictures give none")
    }

    @MainActor func testTheWeakPlanAsksTheMissedTagsAndRecordsNoLesson() async throws {
        let store = try BooruStore()
        for name in ["t1", "t2", "t3", "t4"] { try store.studyStore.answer(name, right: false) }
        try store.studyStore.answer("t5", right: true)
        let session = makeSession(.weak, store: store)
        await session.start()
        XCTAssertEqual(session.phase, .asking)
        XCTAssertEqual(Set(session.tags.map(\.name)), ["t1", "t2", "t3", "t4"], "A tag never missed is not weak")
        XCTAssertEqual(kinds(session.steps), ["quiz", "quiz", "match", "quiz", "quiz", "quiz", "quiz", "quiz", "quiz"])
        play(session)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertTrue(try store.studyStore.lessons().isEmpty)
        XCTAssertGreaterThan(try todaysXP(store), 0)

        let none = makeSession(.weak, store: try BooruStore())
        await none.start()
        XCTAssertEqual(none.phase, .finished)
        XCTAssertTrue(none.steps.isEmpty)
    }

    @MainActor func testWeakestOrdersByShareOfWrongThenWrongCountThenNameAndCapsAndSkipsTheNeverMissed() throws {
        let store = try BooruStore()
        func put(_ tag: String, correct: Int, wrong: Int) throws {
            try store.database.write { try StudyStore.write(StudyProgress(tag: tag, correct: correct, wrong: wrong), db: $0) }
        }
        try put("t1", correct: 2, wrong: 2)   // half, two missed
        try put("t2", correct: 1, wrong: 1)   // half, one missed
        try put("t5", correct: 1, wrong: 1)   // half, one missed, after t2 by name
        try put("t3", correct: 3, wrong: 1)   // a quarter
        try put("t4", correct: 5, wrong: 0)   // never missed
        try put("t6", correct: 0, wrong: 1)   // always missed
        try put("not_taught", correct: 0, wrong: 9)
        let progress = try store.studyStore.progress()
        XCTAssertEqual(StudyLessonSession.weakest(progress, curriculum: pathCurriculum, count: 10).map(\.name), ["t6", "t1", "t2", "t5", "t3"])
        XCTAssertEqual(StudyLessonSession.weakest(progress, curriculum: pathCurriculum, count: 2).map(\.name), ["t6", "t1"])
        XCTAssertEqual(StudyLessonSession.weakest(progress, curriculum: pathCurriculum, count: 0), [])
        XCTAssertEqual(StudyLessonSession.weakest([:], curriculum: pathCurriculum, count: 5), [])
    }

    @MainActor func testSpelledIgnoresCaseTreatsSpacesAndUnderscoresAlikeAndNeverAcceptsNothing() {
        let tag = plainTag("blue_eyes")
        XCTAssertTrue(StudyLessonSession.spelled("blue_eyes", tag))
        XCTAssertTrue(StudyLessonSession.spelled("Blue Eyes", tag))
        XCTAssertTrue(StudyLessonSession.spelled("BLUE_EYES", tag))
        XCTAssertTrue(StudyLessonSession.spelled("  blue   eyes  ", tag), "Extra spaces are ignored")
        XCTAssertTrue(StudyLessonSession.spelled("blue_ eyes", tag))
        XCTAssertFalse(StudyLessonSession.spelled("blue eye", tag))
        XCTAssertFalse(StudyLessonSession.spelled("blueeyes", tag))
        XCTAssertFalse(StudyLessonSession.spelled("", tag))
        XCTAssertFalse(StudyLessonSession.spelled("   ", tag))
        XCTAssertFalse(StudyLessonSession.spelled("___", tag))
        XCTAssertFalse(StudyLessonSession.spelled("", plainTag("")), "An empty answer is never right")
    }

    @MainActor func testFinishingALessonRaisesTheComboCounterToItsBestRunAndNeverLowersIt() async throws {
        let store = try BooruStore()
        let first = makeSession(.lesson(tagsLesson("c1")), store: store)
        await first.start()
        play(first)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], first.bestCombo)
        XCTAssertEqual(first.bestCombo, 10)

        let worse = makeSession(.lesson(tagsLesson("c2")), store: store)
        await worse.start()
        var turn = 0
        play(worse) { _ in turn += 1; return turn % 3 != 0 }
        XCTAssertLessThan(worse.bestCombo, 10)
        XCTAssertEqual(try store.studyStore.stats()[StudyCounter.combo], 10, "A weaker run leaves the counter alone")
    }

    func testAMilestoneCanBeAnAwardButReachedNeverProducesOne() {
        let award = StudyAward.all(StudyPath()).first { $0.id == "lessons-1" }!
        XCTAssertEqual(StudyMilestone.award(award), StudyMilestone.award(award))
        XCTAssertNotEqual(StudyMilestone.award(award), StudyMilestone.goal(20))
        let before = StudyStanding(xp: 95, today: 0, studiedToday: false)
        let reached = StudyMilestone.reached(before: before, earned: 20, goal: 20, streak: 7)
        XCTAssertFalse(reached.contains { if case .award = $0 { return true }; return false })
    }

    // MARK: - StudyLookup.examples for one server

    @MainActor func testExamplesForOneServerIgnoreTheChosenServersAndLeaveOutUnusableAndBlacklistedPictures() async throws {
        let store = try BooruStore()
        XCTAssertTrue(store.selectedServers.isEmpty)
        let source = PathFakeSource(extra: ["t2": ["hidden_tag"], "t3": ["animated"]])
        let plain = await StudyLookup.examples("t1", server: pathServer, store: store, source: source)
        XCTAssertEqual(plain.count, 5, "No browsing server is chosen, and the learning server is read anyway")
        XCTAssertTrue(plain.allSatisfy { $0.serverID == pathServer.id && $0.tags.contains("t1") })
        let moving = await StudyLookup.examples("t3", server: pathServer, store: store, source: source)
        XCTAssertTrue(moving.isEmpty, "Animated pictures are not examples")
        let before = await StudyLookup.examples("t2", server: pathServer, store: store, source: source)
        XCTAssertEqual(before.count, 5)
        try store.setBlacklist("hidden_tag", serverID: pathServer.id)
        let after = await StudyLookup.examples("t2", server: pathServer, store: store, source: source)
        XCTAssertTrue(after.isEmpty, "The server's blacklist still applies")
        let broken = await StudyLookup.examples("t1", server: pathServer, store: store, source: PathFakeSource(failing: true))
        XCTAssertTrue(broken.isEmpty)
    }

    // MARK: - Fixtures

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private var pathServer: BooruServer {
        BooruServer(id: "path-test", name: "Path", baseURL: URL(string: "https://path.example")!, engine: .danbooru)
    }

    private func plainTag(_ name: String) -> StudyTag { StudyTag(name: name, ko: name, ja: name, note: ["en": name]) }

    /// Eight loose tags the lessons are made of, and three more in another group, none of them exclusive.
    private var pathCurriculum: StudyCurriculum {
        StudyCurriculum(units: [
            StudyUnit(id: "pu", title: ["en": "P"], summary: ["en": ""], groups: [
                StudyGroup(id: "pg", title: ["en": "G"], tags: (1...8).map { plainTag("t\($0)") }),
                StudyGroup(id: "ph", title: ["en": "H"], tags: (1...3).map { plainTag("h\($0)") })
            ])
        ])
    }
}

/// A small deterministic generator, so that a seed always gives the same order.
private struct PathSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Answers every tag with five still pictures that carry it, and any tags `extra` adds for it, immediately.
private actor PathFakeSource: BooruProviding {
    let extra: [String: [String]]
    let failing: Bool
    init(extra: [String: [String]] = [:], failing: Bool = false) { self.extra = extra; self.failing = failing }
    func posts(server: BooruServer, query: String, page: Int) async throws -> BooruBatch {
        if failing { throw URLError(.notConnectedToInternet) }
        // Far from the fixture ids that stand for a GIF and a video.
        let base = 1_000_000 + Int64(query.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 100_000 }) * 10
        return .init(posts: (0..<5).map { BooruFixtureSource.post(base + Int64($0), server: server, tags: [query] + (extra[query] ?? [])) }, hasMore: false)
    }
    func suggestions(server: BooruServer, token: String) async throws -> [BooruTag] { [] }
    func pools(server: BooruServer, query: String, page: Int) async throws -> [BooruPool] { [] }
    func poolPosts(server: BooruServer, poolID: Int64, page: Int) async throws -> BooruBatch { .init(posts: [], hasMore: false) }
    func notes(server: BooruServer, postID: Int64) async throws -> [BooruNote] { [] }
}
