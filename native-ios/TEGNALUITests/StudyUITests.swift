import XCTest

final class StudyUITests: XCTestCase {
    // MARK: Learning mode

    func testTagStudyTakesOverTheWholeScreenAndLeadsBackToTheLibrary() {
        let app = launch(mode: false)
        tab(app, "Tags").tap()
        let entry = element(app, "study.entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        // A first visit is welcomed: a hello, a daily goal, and how much the learner knows.
        XCTAssertTrue(app.staticTexts["Welcome to Learn 2D AI!"].waitForExistence(timeout: 5), "A first visit is welcomed")
        element(app, "study.welcome.next").tap()
        XCTAssertTrue(element(app, "study.welcome.goal.20").waitForExistence(timeout: 5))
        element(app, "study.welcome.goal.30").tap()
        element(app, "study.welcome.next").tap()
        XCTAssertTrue(element(app, "study.welcome.new").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "study.welcome.next").isEnabled, "Nothing is chosen yet")
        element(app, "study.welcome.new").tap()
        element(app, "study.welcome.next").tap()
        XCTAssertTrue(app.staticTexts["Where should the pictures come from?"].waitForExistence(timeout: 5), "A learner with servers chooses one after the welcome")
        XCTAssertTrue(app.staticTexts["Suggested"].exists, "Danbooru is suggested when it is there")
        element(app, "study.serverChoice.Danbooru").tap()
        XCTAssertTrue(element(app, "study.dock.path").waitForExistence(timeout: 5), "Learning mode brings its own dock")
        XCTAssertTrue(element(app, "study.node.s0-order").exists, "The path starts from nothing")
        XCTAssertEqual(element(app, "study.node.s0-tags").value as? String, "Locked")
        element(app, "study.dock.me").tap()
        XCTAssertTrue(element(app, "study.startInMode").waitForExistence(timeout: 5), "Opening in learning mode is a setting")
        XCTAssertTrue(app.staticTexts["Danbooru"].exists, "The chosen server is shown")
        // The way out is at the foot of the page, below the badges and the settings.
        app.swipeUp()
        element(app, "study.leave").tap()
        XCTAssertFalse(element(app, "study.dock.path").waitForExistence(timeout: 1.5), "Learning mode is gone")
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "The library is one tap away")
        // Learning mode slides away over a moment; the library can be touched once it has gone.
        let free = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: entry)
        XCTAssertEqual(XCTWaiter.wait(for: [free], timeout: 5), .completed)
    }

    func testThePlacementTestEndsAtTheFirstQuestionNotKnown() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Welcome to Learn 2D AI!"].waitForExistence(timeout: 10))
        element(app, "study.welcome.next").tap()
        element(app, "study.welcome.next").tap()
        XCTAssertTrue(element(app, "study.welcome.some").waitForExistence(timeout: 5))
        element(app, "study.welcome.some").tap()
        element(app, "study.welcome.next").tap()
        // The test asks without pictures; "I Don't Know" answers as missed and ends it.
        XCTAssertTrue(element(app, "study.choice.0").waitForExistence(timeout: 10), "The test asks at once")
        XCTAssertTrue(element(app, "study.unsure").exists)
        element(app, "study.unsure").tap()
        XCTAssertEqual(element(app, "study.verdict").value as? String, "wrong")
        element(app, "study.next").tap()
        XCTAssertTrue(element(app, "study.placement.title").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Let's Start from the Beginning"].exists, "Missing the first question starts at the beginning")
        element(app, "study.done").tap()
        if app.staticTexts["Where should the pictures come from?"].waitForExistence(timeout: 3) { element(app, "study.serverChoice.Danbooru").tap() }
        XCTAssertTrue(element(app, "study.node.s0-order").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "study.node.s0-tags").value as? String, "Locked")
        XCTAssertFalse(app.staticTexts["Welcome to Learn 2D AI!"].exists, "The welcome has closed")
    }

    func testAFirstLessonExplainsFromNothingAsksAndPaysOut() {
        let app = launch(seed: "s0-order")
        open(app, "s0-order")
        XCTAssertTrue(element(app, "study.cardTitle").waitForExistence(timeout: 10), "An idea is told before it is asked")
        var asked = 0
        play(app) {
            if element(app, "study.choice.0").exists { asked += 1; element(app, "study.choice.0").tap() }
        }
        XCTAssertGreaterThanOrEqual(asked, 3)
        XCTAssertTrue(element(app, "study.stars").exists)
        XCTAssertTrue(app.staticTexts["Today's goal"].waitForExistence(timeout: 8))
        element(app, "study.done").tap()
        // The 보석 it paid come first, in a treasure chest that the button (or a tap on it) opens.
        XCTAssertTrue(element(app, "study.chest").waitForExistence(timeout: 5), "A first finish pays 보석, opened from a chest")
        let balance = element(app, "study.chest.balance")
        let before = balance.label
        element(app, "study.done").tap()
        XCTAssertTrue(element(app, "study.chest.lines").waitForExistence(timeout: 6), "Opened, it lists what paid")
        let climbed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: balance)
        XCTAssertEqual(XCTWaiter.wait(for: [climbed], timeout: 6), .completed, "The balance climbs once the gems land")
        element(app, "study.done").tap()
        XCTAssertTrue(app.staticTexts["1-Day Streak!"].waitForExistence(timeout: 5), "The day's first lesson gets a page for the streak it starts")
        finish(app)
        XCTAssertTrue(element(app, "study.node.s0-tags").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "study.node.s0-tags").value as? String, "Next", "Finishing a lesson opens the one after it")
        XCTAssertNotEqual(element(app, "study.hud.xp").label, "XP 0", "A lesson earns experience")
        XCTAssertEqual(element(app, "study.hud.streak").label, "Day streak 1")
    }

    func testATagLessonShowsEachNewTagAsksInPromptWordsAndCollectsThem() {
        let app = launch(language: "ko", seed: "s1-who")
        open(app, "s1-who")
        XCTAssertTrue(element(app, "study.newTag").waitForExistence(timeout: 15), "A new tag is shown before it is asked")
        var paired = false, worded = 0
        play(app) {
            let match = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "study.match.tag."))
            if match.firstMatch.exists {
                // Every tag is paired with its meaning.
                for name in match.allElementsBoundByIndex.map(\.identifier).map({ String($0.dropFirst("study.match.tag.".count)) }) {
                    element(app, "study.match.tag.\(name)").tap(); element(app, "study.match.meaning.\(name)").tap()
                }
                paired = true
            } else if element(app, "study.choice.0").exists {
                let label = element(app, "study.choice.0").label
                if !label.hasPrefix("그림") {
                    worded += 1
                    XCTAssertTrue(label.allSatisfy(\.isASCII), "A tag is asked as a prompt writes it, without a translation: \(label)")
                }
                element(app, "study.choice.0").tap()
            }
        }
        XCTAssertTrue(paired, "Tags are paired with their meanings")
        XCTAssertTrue(sawOdd, "A picture is shown with one tag that is not on it")
        XCTAssertTrue(typed, "A tag is typed from memory before the lesson ends")
        XCTAssertGreaterThan(worded, 0)
        finish(app)
        element(app, "study.dock.me").tap()
        XCTAssertTrue(element(app, "study.dex.1girl").waitForExistence(timeout: 5), "Tags met in a lesson are kept in the collection, on the Me tab")
    }

    func testTheLastLessonOfASectionHasPromptsBuiltFromABankOfTags() {
        let app = launch(seed: "s1-boss")
        open(app, "s1-boss")
        let answers = [["1girl", "solo", "smile"], ["1boy", "solo", "upper_body"], ["2girls", "full_body", "looking_at_viewer"], ["1girl", "solo", "portrait", "closed_eyes", "blush"]]
        var built = 0
        play(app) {
            guard element(app, "study.build.tray").exists, built < answers.count else { return }
            for tag in answers[built] { element(app, "study.build.bank.\(tag)").tap() }
            built += 1
        }
        XCTAssertEqual(built, answers.count)
        XCTAssertEqual(element(app, "study.stars").label, "Stars: 3", "No mistake earns every star")
        XCTAssertTrue(sawCombo, "Three right answers in a row are called out")
        finish(app)
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Lesson Done"), object: element(app, "study.node.s1-boss"))
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed, "The finished lesson is marked on the path")
    }

    func testALessonHasThingsPutInOrderAndLeadsStraightToTheKeySheet() {
        let app = launch(seed: "api-issue", extra: ["--generation-ui-test", "--generation-no-key"])
        open(app, "api-issue")
        XCTAssertTrue(element(app, "study.cardTitle").waitForExistence(timeout: 10))
        var ordered = false, opened = false
        play(app, action: {
            // The card that opens Civitai is left alone: it would leave the app.
            let button = element(app, "study.cardAction")
            guard !opened, button.label.contains("Enter the API Key") else { return }
            button.tap()
            XCTAssertTrue(element(app, "generator.key").waitForExistence(timeout: 5), "The key can be entered from the lesson that explains it")
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            opened = true
        }) {
            if element(app, "study.order.item.0").exists {
                // The first step is dragged into the first place; the rest are tapped in their numbered order.
                element(app, "study.order.item.0").press(forDuration: 0.2, thenDragTo: element(app, "study.order.slot.0"))
                XCTAssertTrue(element(app, "study.order.place.0").waitForExistence(timeout: 3), "A step can be dragged into a place")
                for index in 1..<5 { element(app, "study.order.item.\(index)").tap() }
                element(app, "study.check").tap()
                XCTAssertTrue(element(app, "study.verdict").waitForExistence(timeout: 5))
                XCTAssertEqual(element(app, "study.verdict").value as? String, "right")
                ordered = true
            } else if element(app, "study.choice.0").exists { element(app, "study.choice.0").tap() }
        }
        XCTAssertTrue(ordered, "The steps of getting a key are put in order")
        XCTAssertTrue(opened)
        finish(app)
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Next"), object: element(app, "study.node.api-air"))
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 8), .completed)
    }

    func testThingsAreSortedIntoTwoBucketsOneAtATime() {
        let app = launch(language: "ko", seed: "api-key")
        open(app, "api-key")
        var sorted = 0
        play(app) {
            let left = element(app, "study.sort.left")
            if left.exists {
                XCTAssertTrue(element(app, "study.sort.item").exists || element(app, "study.next").exists || sorted > 0)
                if left.isEnabled { left.tap(); sorted += 1 }
            } else if element(app, "study.choice.0").exists { element(app, "study.choice.0").tap() }
        }
        XCTAssertGreaterThanOrEqual(sorted, 5, "Every thing is dropped into a bucket")
        XCTAssertNotEqual(element(app, "study.stars").label, "Stars: 3", "Dropping everything into one bucket is not a perfect round")
        finish(app)
        XCTAssertTrue(element(app, "study.node.api-buzz").waitForExistence(timeout: 8))
    }

    func testTheGeneratorAsksForAKeyAndLeadsToTheLessonsAboutIt() {
        let app = launch(seed: "s0-order", extra: ["--generation-ui-test", "--generation-no-key"])
        element(app, "study.dock.lab").tap()
        XCTAssertTrue(app.staticTexts["Connect an API Key First"].waitForExistence(timeout: 5), "Generating needs a key, and the generator tab says so")
        element(app, "study.lab.learn").tap()
        XCTAssertTrue(element(app, "study.cardTitle").waitForExistence(timeout: 10), "The lessons about the API open from the generator tab")
        XCTAssertTrue(element(app, "study.cardTitle").label.contains("connection"), "It starts with why a connection is needed")
    }

    func testBadgesAreEarnedShownAndExplained() {
        let app = launch(seed: "s1-who")
        element(app, "study.dock.me").tap()
        let card = element(app, "study.awards")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Badges are on the Me tab")
        card.tap()
        XCTAssertTrue(element(app, "study.awards.count").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "study.award.lessons-1").value as? String, "Earned", "Finished lessons have earned the first badge")
        XCTAssertEqual(element(app, "study.award.section-s0").value as? String, "Earned", "A finished section has its own badge")
        XCTAssertEqual(element(app, "study.award.lessons-all").value as? String, "Locked")
        element(app, "study.award.lessons-all").tap()
        XCTAssertTrue(element(app, "study.award.name").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "study.award.name").label, "Graduate")
        XCTAssertTrue(app.staticTexts["Finish every lesson on the map."].exists, "A badge says how it is earned")
    }

    func testALessonThatEarnsABadgeCelebratesIt() {
        let app = launch(seed: "s0-order")
        open(app, "s0-order")
        play(app) { if element(app, "study.choice.0").exists { element(app, "study.choice.0").tap() } }
        var celebrated = false
        let done = element(app, "study.done")
        for _ in 0..<9 where done.exists {
            if app.staticTexts["Achievement Unlocked!"].exists { celebrated = true; XCTAssertTrue(app.staticTexts["First Step"].exists) }
            done.tap()
            _ = element(app, "study.dock.path").waitForExistence(timeout: 1.5)
        }
        XCTAssertTrue(celebrated, "The first finished lesson earns the first badge, with a page of its own")
    }

    func testPracticeHasWeakSpotsAndASpeedRound() {
        let app = launch(seed: "s1-who", extra: ["--study-seed-tags=8"])
        element(app, "study.dock.practice").tap()
        XCTAssertTrue(element(app, "study.weak").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "study.weak").isEnabled, "Tags answered wrong can be asked again")
        // The AI lab's shop sits at the foot of the page.
        app.swipeUp(); app.swipeUp()
        XCTAssertTrue(element(app, "lab.shop.balance").waitForExistence(timeout: 5), "The shop is at the foot of Practice")
        app.swipeDown(); app.swipeDown()
        element(app, "study.speed").tap()
        XCTAssertTrue(element(app, "study.speed.go").waitForExistence(timeout: 5)); element(app, "study.speed.go").tap()
        for _ in 0..<4 {
            XCTAssertTrue(element(app, "study.speed.choice.0").waitForExistence(timeout: 5), "Questions keep coming without a Check button")
            element(app, "study.speed.choice.0").tap()
        }
        XCTAssertTrue(element(app, "study.speed.score").exists)
    }

    func testSmartTabRemindsOfDueTagsAndOpensPractice() {
        let app = launch(mode: false, extra: ["--study-due-test", "--study-seed-path=s0-order"])
        tab(app, "Smart").tap()
        let card = element(app, "study.reviewCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "A due tag shows the reminder")
        card.tap()
        let review = element(app, "study.review")
        XCTAssertTrue(review.waitForExistence(timeout: 5), "The reminder opens learning mode's practice")
        review.tap()
        XCTAssertTrue(element(app, "study.choice.0").waitForExistence(timeout: 15))
        play(app) { if element(app, "study.choice.0").exists { element(app, "study.choice.0").tap() } }
        XCTAssertTrue(app.staticTexts["Review Complete!"].exists)
    }

    // MARK: Generator and viewer

    func testALessonTeachesEmphasisWithExamplesAToolAndQuestions() {
        let app = launch(language: "ko", seed: "s0-order")
        element(app, "study.dock.lab").tap(); element(app, "study.lab.guide").tap()
        reveal(app, "study.lesson.emphasis-novelai").tap()
        XCTAssertTrue(app.staticTexts["중괄호와 대괄호"].waitForExistence(timeout: 5), "Lessons are written in the app language")
        XCTAssertEqual(reveal(app, "study.emphasis.braces").label, "{{{{rain}}}}", "1.2 is closest to four pairs of braces")
        XCTAssertEqual(reveal(app, "study.emphasis.numbered").label, "1.2::rain ::")
        XCTAssertEqual(reveal(app, "study.emphasis.weighted").label, "(rain:1.2)")
        reveal(app, "study.check.0.0").tap()
        XCTAssertTrue(element(app, "study.check.0.why").waitForExistence(timeout: 5), "A wrong answer is explained")
        app.buttons["다시 시도"].firstMatch.tap()
        reveal(app, "study.check.0.1").tap()
        XCTAssertEqual(reveal(app, "study.check.0.1").value as? String, "정답", "A question can be tried again")
    }

    func testAPromptIsDrawnOnTheGeneratorTabWithTheUsersKeyAndKept() {
        let app = launch(seed: "s0-order", extra: ["--generation-ui-test"])
        element(app, "study.dock.lab").tap()
        XCTAssertTrue(element(app, "generator.prompt").waitForExistence(timeout: 5), "The tab is the generator itself")
        XCTAssertFalse(app.staticTexts["Connect an API Key First"].exists, "A saved key needs no asking")
        reveal(app, "generator.model").tap()
        let field = element(app, "generator.air")
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText("urn:air:sdxl:checkpoint:civitai:827184@2514310")
        element(app, "generator.useAIR").tap()
        XCTAssertTrue(app.staticTexts["Fixture Model · v1"].waitForExistence(timeout: 10), "The chosen model is named on the tab")
        let prompt = reveal(app, "generator.prompt")
        prompt.tap(); prompt.typeText("1girl, smile")
        let generate = reveal(app, "generator.generate")
        XCTAssertTrue(generate.isEnabled); generate.tap()
        XCTAssertTrue(element(app, "generator.recent").waitForExistence(timeout: 20), "The finished picture is kept under the canvas")
        XCTAssertTrue(element(app, "generator.result").exists, "and shown on the canvas")
        // The first picture earns a badge, shown as soon as it is drawn.
        XCTAssertTrue(app.staticTexts["Achievement Unlocked!"].waitForExistence(timeout: 10), "The first picture earns its badge at once")
        app.buttons["Continue"].firstMatch.tap()
        reveal(app, "generator.recent").tap()
        XCTAssertTrue(element(app, "generator.picture").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1girl, smile"].exists, "A picture keeps the prompt it was made from")
    }

    func testGeneratingWithoutAKeyAsksForOneAndChecksIt() {
        let app = launch(seed: "s0-order", extra: ["--generation-ui-test", "--generation-no-key"])
        element(app, "study.dock.lab").tap(); reveal(app, "study.lab.generator").tap()
        XCTAssertTrue(element(app, "generator.addKey").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Advanced Settings"].exists, "A beginner sees that the advanced settings are still locked")
        XCTAssertFalse(element(app, "generator.negative").exists, "Advanced settings stay out of the way at first")
        element(app, "generator.addKey").tap()
        let key = element(app, "generator.key")
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.tap(); key.typeText("wrong")
        element(app, "generator.saveKey").tap()
        XCTAssertTrue(app.staticTexts["Civitai did not accept this API key."].waitForExistence(timeout: 10), "A refused key is not saved")
        XCTAssertFalse(element(app, "generator.removeKey").exists)
        key.tap(); key.typeText("right")
        element(app, "generator.saveKey").tap()
        XCTAssertTrue(element(app, "generator.signedIn").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "generator.removeKey").waitForExistence(timeout: 5))
    }

    func testAPictureOpensAsAPromptWithItsTagsInPromptOrder() {
        let app = launch(mode: false)
        tab(app, "Explore").tap()
        let post = element(app, "booru.post.101")
        XCTAssertTrue(post.waitForExistence(timeout: 10)); post.tap()
        openMenu(app); element(app, "booru.info").tap()
        reveal(app, "booru.prompt").tap()
        let prompt = element(app, "study.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertEqual(prompt.label, "scenery, mountain", "Artist names stay out unless asked for")
        XCTAssertTrue(app.staticTexts["Tags in This Picture"].exists, "Tags the lessons teach are listed for practice")
    }

    // MARK: Helpers

    private var sawCombo = false
    private var typed = false
    private var sawOdd = false
    override func setUpWithError() throws { continueAfterFailure = false }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        // The course's tabs are the stock tab bar's buttons, which do not always carry the identifier given to their tab
        // (in Korean they come with only their label): they are found by place, in the bar that shows the map's symbol.
        let tabs = ["path", "practice", "lab", "courses", "me"]
        if id.hasPrefix("study.dock."), let index = tabs.firstIndex(of: String(id.dropFirst("study.dock.".count))) {
            return app.tabBars.containing(.image, identifier: "map.fill").firstMatch.buttons.element(boundBy: index)
        }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    /// Starts the app with the image fixture: in learning mode, or in the library when `mode` is false.
    /// `seed` names the lesson the path starts at, with a server already chosen.
    private func launch(language: String = "en", mode: Bool = true, seed: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--study-ui-test", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "ko" ? "ko_KR" : "en_US"]
            + (mode ? ["--study-mode"] : []) + (seed.map { ["--study-seed-path=\($0)"] } ?? []) + extra
        app.launch()
        if mode { XCTAssertTrue(element(app, "study.dock.path").waitForExistence(timeout: 15)) }
        return app
    }
    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let tab = app.tabBars.buttons[name]
        return tab.waitForExistence(timeout: 10) ? tab : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }
    private func open(_ app: XCUIApplication, _ lesson: String) {
        let node = element(app, "study.node.\(lesson)")
        // A stop that is open starts its lesson at a tap.
        XCTAssertTrue(node.waitForExistence(timeout: 10)); node.tap()
    }
    /// Leaves a finished lesson, passing any page shown for a streak, a goal or a level.
    private func finish(_ app: XCUIApplication) {
        let done = element(app, "study.done")
        for _ in 0..<8 where done.exists {
            done.tap()
            _ = element(app, "study.dock.path").waitForExistence(timeout: 1.5)
        }
        XCTAssertTrue(element(app, "study.dock.path").waitForExistence(timeout: 5), "The lesson closes back onto the path")
    }
    /// Plays a lesson to its end. `answer` is called on every step that waits for something to be chosen,
    /// and `action` on a card that offers something to do.
    private func play(_ app: XCUIApplication, action: () -> Void = {}, answer: () -> Void) {
        let complete = element(app, "study.complete"), next = element(app, "study.next"), check = element(app, "study.check")
        for _ in 0..<90 {
            if complete.exists { return }
            if next.exists {
                if element(app, "study.combo").exists { sawCombo = true }
                next.tap(); continue
            }
            if element(app, "study.cardAction").exists { action() }
            // A tag to type: anything is typed, since the test cannot know the word; the step then counts as missed.
            let field = element(app, "study.spell.field")
            if field.exists, !check.isEnabled { field.tap(); field.typeText("smile"); typed = true }
            // A picture with one tag that is not on it: any lesson or review of tags may bring one.
            let odd = element(app, "study.odd.0")
            if odd.exists, !check.isEnabled { odd.tap(); sawOdd = true }
            if check.exists, check.isEnabled { check.tap(); continue }
            answer()
            if check.exists, check.isEnabled { check.tap() } else { _ = next.waitForExistence(timeout: 2) }
        }
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "The lesson comes to an end")
    }
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let value = element(app, id)
        for _ in 0..<16 {
            let top = app.navigationBars.allElementsBoundByIndex.filter { $0.isHittable }.map { $0.frame.maxY }.max() ?? 140
            let visible = value.exists && value.isHittable && value.frame.midY > top + 10 && value.frame.midY < app.frame.maxY - 110
            if visible { return value }
            scroll(app, up: !value.exists || value.frame.midY > top + 10)
        }
        XCTAssertTrue(value.isHittable, id); return value
    }
    private func scroll(_ app: XCUIApplication, up: Bool) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: up ? 0.7 : 0.3))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: up ? 0.3 : 0.7)))
    }
    private func openMenu(_ app: XCUIApplication) {
        if !element(app, "booru.menuClose").exists {
            XCTAssertTrue(element(app, "booru.media").waitForExistence(timeout: 5))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label IN %@", ["ready", "playing", "ended", "error"]), object: element(app, "booru.mediaStatus"))
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(element(app, "booru.menuClose").waitForExistence(timeout: 5))
        }
    }
}
