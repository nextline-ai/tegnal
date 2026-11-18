import XCTest
@testable import TEGNAL

final class StudyGuideTests: XCTestCase {
    private let languages = ["en", "ko", "ja"]

    // MARK: Bundled guide

    func testTheBundledGuideDecodesWithNineLessonsWithUniqueIds() {
        let guide = StudyGuide.bundled
        XCTAssertEqual(guide.lessons.count, 9)
        XCTAssertEqual(Set(guide.lessons.map(\.id)).count, guide.lessons.count, "Lesson ids are unique")
        XCTAssertTrue(guide.lessons.allSatisfy { !$0.id.isEmpty && !$0.symbol.isEmpty && !$0.parts.isEmpty })
        XCTAssertGreaterThanOrEqual(guide.version, 1)
        XCTAssertNotNil(guide.checked.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression), "The month the sources were read, as yyyy-MM")
    }

    private func texts(of lesson: StudyLesson) -> [(String, StudyText)] {
        var all: [(String, StudyText)] = [("title", lesson.title), ("summary", lesson.summary)]
        for (index, part) in lesson.parts.enumerated() {
            if let heading = part.heading { all.append(("part \(index) heading", heading)) }
            if let body = part.body { all.append(("part \(index) body", body)) }
            for (number, example) in (part.examples ?? []).enumerated() {
                if let note = example.note { all.append(("part \(index) example \(number) note", note)) }
            }
        }
        for (index, check) in lesson.checks.enumerated() {
            all.append(("check \(index) question", check.question))
            all.append(("check \(index) why", check.why))
        }
        return all
    }

    func testEveryLocalizedTextHasEnglishKoreanAndJapanese() {
        for lesson in StudyGuide.bundled.lessons {
            for (name, text) in texts(of: lesson) {
                for language in languages {
                    let value = text[language]
                    XCTAssertFalse(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "\(lesson.id) \(name) has no \(language) text")
                }
            }
        }
    }

    func testEveryCheckOffersTwoToFourDistinctChoicesAndAnInRangeAnswer() {
        var checks = 0
        for lesson in StudyGuide.bundled.lessons {
            for (index, check) in lesson.checks.enumerated() {
                checks += 1
                let label = "\(lesson.id) check \(index)"
                XCTAssertTrue((2...4).contains(check.choices.count), "\(label) has \(check.choices.count) choices")
                XCTAssertEqual(Set(check.choices).count, check.choices.count, "\(label) repeats a choice")
                XCTAssertTrue(check.choices.indices.contains(check.answer), "\(label) answer \(check.answer) is out of range")
                XCTAssertTrue(check.choices.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(label) has a blank choice")
            }
        }
        XCTAssertGreaterThan(checks, 0, "The guide asks questions")
    }

    func testEverySourceIsAnHTTPSAddress() {
        var sources = 0
        for lesson in StudyGuide.bundled.lessons {
            for source in lesson.sources {
                sources += 1
                let url = URL(string: source)
                XCTAssertEqual(url?.scheme, "https", "\(lesson.id): \(source)")
                XCTAssertFalse(url?.host?.isEmpty ?? true, "\(lesson.id): \(source)")
            }
        }
        XCTAssertGreaterThan(sources, 0)
    }

    func testTheGuideHasLessonsWithTheEmphasisTool() {
        let tooled = StudyGuide.bundled.lessons.filter { $0.tool == "emphasis" }
        XCTAssertFalse(tooled.isEmpty)
        XCTAssertTrue(StudyGuide.bundled.lessons.compactMap(\.tool).allSatisfy { $0 == "emphasis" }, "Only tools the app knows how to show")
    }

    func testBacktickSpansAreBalancedInEveryBodyAndAnswerExplanation() {
        for lesson in StudyGuide.bundled.lessons {
            var written: [(String, StudyText)] = []
            for (index, part) in lesson.parts.enumerated() { if let body = part.body { written.append(("part \(index) body", body)) } }
            for (index, check) in lesson.checks.enumerated() { written.append(("check \(index) why", check.why)) }
            for (name, text) in written {
                for language in languages {
                    let count = (text[language] ?? "").filter { $0 == "`" }.count
                    XCTAssertEqual(count % 2, 0, "\(lesson.id) \(name) (\(language)) has an unclosed backtick")
                }
            }
        }
    }

    // MARK: Finished lessons

    func testFinishedLessonsAreReadFromTheStoredList() {
        XCTAssertEqual(StudyGuide.finished(""), [])
        XCTAssertEqual(StudyGuide.finished("basics"), ["basics"])
        XCTAssertEqual(StudyGuide.finished("basics,tips,basics"), ["basics", "tips"])
    }

    func testFinishingALessonAddsItInSortedOrderWithoutDuplicates() {
        XCTAssertEqual(StudyGuide.finishing("quality", in: ""), "quality")
        XCTAssertEqual(StudyGuide.finishing("quality", in: "tips,basics"), "basics,quality,tips")
        XCTAssertEqual(StudyGuide.finishing("basics", in: "basics"), "basics")
        let once = StudyGuide.finishing("text", in: "basics")
        XCTAssertEqual(StudyGuide.finishing("text", in: once), once)
    }

    func testFinishedAndFinishingRoundTrip() {
        var stored = ""
        for id in ["tips", "basics", "negative", "basics"] { stored = StudyGuide.finishing(id, in: stored) }
        XCTAssertEqual(StudyGuide.finished(stored), ["basics", "negative", "tips"])
        XCTAssertEqual(stored, "basics,negative,tips")
    }

    // MARK: Emphasis

    func testPairsCountsTheStepsOfOnePointZeroFive() {
        XCTAssertEqual(StudyEmphasis.pairs(1.0), 0)
        XCTAssertEqual(StudyEmphasis.pairs(1.05), 1)
        XCTAssertEqual(StudyEmphasis.pairs(1.1025), 2)
        XCTAssertEqual(StudyEmphasis.pairs(1.5), 8)
        XCTAssertEqual(StudyEmphasis.pairs(1 / 1.05), -1)
        XCTAssertEqual(StudyEmphasis.pairs(0.9), -2)
        XCTAssertEqual(StudyEmphasis.pairs(1.01), 0, "Too close to one to take a step")
        XCTAssertEqual(StudyEmphasis.pairs(0), 0)
        XCTAssertEqual(StudyEmphasis.pairs(-2), 0)
    }

    func testNumberTrimsTrailingZeros() {
        XCTAssertEqual(StudyEmphasis.number(1.5), "1.5")
        XCTAssertEqual(StudyEmphasis.number(1.05), "1.05")
        XCTAssertEqual(StudyEmphasis.number(2), "2")
        XCTAssertEqual(StudyEmphasis.number(10), "10")
        XCTAssertEqual(StudyEmphasis.number(100), "100")
        XCTAssertEqual(StudyEmphasis.number(0), "0")
        XCTAssertEqual(StudyEmphasis.number(0.1), "0.1")
        XCTAssertEqual(StudyEmphasis.number(1.23456), "1.2346")
        XCTAssertEqual(StudyEmphasis.number(0.8), "0.8")
    }

    func testBracesWriteOnePairForEachStep() {
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 1.1025), "{{rain}}")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 1.05), "{rain}")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 1 / 1.05), "[rain]")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 0.952), "[rain]")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 0.907), "[[rain]]")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 1.0), "rain")
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 1.01), "rain", "Less than half a step is no step")
        XCTAssertEqual(StudyEmphasis.braces.written("heavy rain", weight: 1.05), "{heavy rain}")
    }

    func testBracesStopAtTwentyPairs() {
        let written = StudyEmphasis.braces.written("rain", weight: 100)
        XCTAssertEqual(written, String(repeating: "{", count: 20) + "rain" + String(repeating: "}", count: 20))
        XCTAssertEqual(StudyEmphasis.braces.written("rain", weight: 0.01), String(repeating: "[", count: 20) + "rain" + String(repeating: "]", count: 20))
    }

    func testNumberedWritesTheWeightBeforeTheTag() {
        XCTAssertEqual(StudyEmphasis.numbered.written("rain", weight: 1.5), "1.5::rain ::")
        XCTAssertEqual(StudyEmphasis.numbered.written("rain", weight: 0.8), "0.8::rain ::")
        XCTAssertEqual(StudyEmphasis.numbered.written("rain", weight: 2), "2::rain ::")
        XCTAssertEqual(StudyEmphasis.numbered.written("rain", weight: 1.0), "rain")
    }

    func testWeightedWritesParenthesesAndEscapesThoseInTheWords() {
        XCTAssertEqual(StudyEmphasis.weighted.written("rain", weight: 1.5), "(rain:1.5)")
        XCTAssertEqual(StudyEmphasis.weighted.written("rain", weight: 0.8), "(rain:0.8)")
        XCTAssertEqual(StudyEmphasis.weighted.written("hand (detailed)", weight: 1.5), "(hand \\(detailed\\):1.5)")
        XCTAssertEqual(StudyEmphasis.weighted.written("hand (detailed)", weight: 1.0), "hand \\(detailed\\)", "Even at weight one the parentheses would otherwise weigh")
        XCTAssertEqual(StudyEmphasis.weighted.written("rain", weight: 1.0), "rain")
    }

    func testOtherNotationsLeaveParenthesesAlone() {
        XCTAssertEqual(StudyEmphasis.braces.written("hand (detailed)", weight: 1.05), "{hand (detailed)}")
        XCTAssertEqual(StudyEmphasis.numbered.written("hand (detailed)", weight: 1.5), "1.5::hand (detailed) ::")
        XCTAssertEqual(StudyEmphasis.braces.written("hand (detailed)", weight: 1.0), "hand (detailed)")
        XCTAssertEqual(StudyEmphasis.numbered.written("hand (detailed)", weight: 1.0), "hand (detailed)")
    }

    func testNothingIsWrittenForEmptyWords() {
        for notation in StudyEmphasis.allCases {
            XCTAssertEqual(notation.written("", weight: 1.5), "", "\(notation)")
            XCTAssertEqual(notation.written("", weight: 1.0), "", "\(notation)")
        }
    }

    func testEffectiveWeightIsTheNearestStepOnlyForBraces() {
        XCTAssertEqual(StudyEmphasis.braces.effective(1.1025), 1.1025, accuracy: 0.000_001)
        XCTAssertEqual(StudyEmphasis.braces.effective(1.1), 1.1025, accuracy: 0.000_001)
        XCTAssertEqual(StudyEmphasis.braces.effective(1.0), 1.0, accuracy: 0.000_001)
        XCTAssertEqual(StudyEmphasis.braces.effective(0.95), 1 / 1.05, accuracy: 0.000_001)
        XCTAssertEqual(StudyEmphasis.braces.effective(1.5), pow(1.05, 8), accuracy: 0.000_001)
        XCTAssertEqual(StudyEmphasis.numbered.effective(1.37), 1.37)
        XCTAssertEqual(StudyEmphasis.weighted.effective(1.37), 1.37)
    }

    // MARK: Answer rows

    func testRowsPairNeighboursThatAreAllShort() {
        XCTAssertEqual(StudyQuestion.rows([3, 4, 5, 6], limit: 10), [[0, 1], [2, 3]])
        XCTAssertEqual(StudyQuestion.rows([10, 10], limit: 10), [[0, 1]], "A length equal to the limit still fits")
    }

    func testALongChoiceKeepsItsOwnLineAndDoesNotPairWithAShortNeighbour() {
        XCTAssertEqual(StudyQuestion.rows([3, 20, 4], limit: 10), [[0], [1], [2]])
        XCTAssertEqual(StudyQuestion.rows([20, 3, 4], limit: 10), [[0], [1, 2]])
        XCTAssertEqual(StudyQuestion.rows([3, 4, 20], limit: 10), [[0, 1], [2]])
        XCTAssertEqual(StudyQuestion.rows([20, 30], limit: 10), [[0], [1]])
        XCTAssertEqual(StudyQuestion.rows([11, 1], limit: 10), [[0], [1]])
    }

    func testAnOddCountLeavesTheLastChoiceAlone() {
        XCTAssertEqual(StudyQuestion.rows([1, 2, 3], limit: 5), [[0, 1], [2]])
        XCTAssertEqual(StudyQuestion.rows([1], limit: 5), [[0]])
    }

    func testALimitOfZeroPutsEveryChoiceOnItsOwnLine() {
        XCTAssertEqual(StudyQuestion.rows([1, 2, 3, 4], limit: 0), [[0], [1], [2], [3]])
    }

    func testNoChoicesMakeNoRows() {
        XCTAssertEqual(StudyQuestion.rows([], limit: 10), [])
    }

    func testRowsCoverEveryChoiceExactlyOnceInOrder() {
        let lengths = [4, 25, 3, 3, 3, 40, 2, 9, 30]
        let flattened = StudyQuestion.rows(lengths, limit: 12).flatMap { $0 }
        XCTAssertEqual(flattened, Array(lengths.indices))
    }

    // MARK: Grade

    func testGradeFromTheRightAnswers() {
        XCTAssertEqual(StudyGrade(right: 10, total: 10), .perfect)
        XCTAssertEqual(StudyGrade(right: 1, total: 1), .perfect)
        XCTAssertEqual(StudyGrade(right: 9, total: 10), .great)
        XCTAssertEqual(StudyGrade(right: 7, total: 10), .great)
        XCTAssertEqual(StudyGrade(right: 6, total: 10), .practice)
        XCTAssertEqual(StudyGrade(right: 0, total: 10), .practice)
        XCTAssertEqual(StudyGrade(right: 0, total: 0), .practice, "An empty round is not a perfect one")
    }

    func testEveryGradeHasATitleAndASymbol() {
        let grades: [StudyGrade] = [.perfect, .great, .practice]
        XCTAssertEqual(Set(grades.map(\.title)).count, 3)
        XCTAssertEqual(Set(grades.map(\.symbol)).count, 3)
        XCTAssertTrue(grades.allSatisfy { !$0.colors.isEmpty })
    }
}
