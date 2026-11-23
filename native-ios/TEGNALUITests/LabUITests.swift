import XCTest

/// The AI lab: the first visit's check, an episode from disaster to engraving, and what it leaves behind.
final class LabUITests: XCTestCase {
    func testAFirstEpisodeHangsAFlopAndEngravesItsCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--lab-mode", "--lab-reset", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()

        // A first visit begins with the one-minute check; it can be skipped.
        let skip = element(app, "lab.diagnosis.skip")
        XCTAssertTrue(skip.waitForExistence(timeout: 15), "A first visit is offered the check")
        skip.tap()

        XCTAssertTrue(element(app, "lab.rate").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "lab.rate").value as? String, "10%", "The rate starts at the course's base")
        element(app, "lab.deck.start").tap()

        // A trap: no penalty, a 망작 hung in the gallery.
        XCTAssertTrue(element(app, "lab.disaster").waitForExistence(timeout: 5))
        element(app, "lab.choice.0").tap()
        XCTAssertTrue(element(app, "lab.fail.tag").waitForExistence(timeout: 5), "Pressing a trap hangs its 망작")
        let won = element(app, "lab.fail.reveal.done")
        XCTAssertTrue(won.waitForExistence(timeout: 5), "A 망작 won for the first time comes up as a card")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: won)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        won.tap()
        element(app, "lab.choice.back").tap()

        // The right choice leads to the tool.
        element(app, "lab.choice.2").tap()
        element(app, "lab.choice.next").tap()
        XCTAssertFalse(element(app, "lab.tool.engrave").exists, "The card is engraved only once the tool is passed")
        let model = app.segmentedControls["lab.switch.0"]
        let thinking = app.segmentedControls["lab.switch.1"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.buttons.element(boundBy: 1).tap()
        thinking.buttons.element(boundBy: 2).tap()
        let engrave = element(app, "lab.tool.engrave")
        XCTAssertTrue(engrave.waitForExistence(timeout: 5), "The best setting passes")
        engrave.tap()

        XCTAssertTrue(element(app, "lab.engrave.title").waitForExistence(timeout: 5))
        let put = element(app, "lab.engrave.put")
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: put)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 15), .completed, "The way back appears once the line is engraved")
        put.tap()

        // Back on the deck: the rate has climbed and card 001 is in the stack.
        XCTAssertTrue(element(app, "lab.deck.earned.ep01").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "lab.rate").value as? String, "24%")

        // The gallery brings a 망작 up close the way it came up when it was won.
        app.tabBars.buttons["망작"].firstMatch.tap()
        element(app, "lab.fail.ep01-1").tap()
        let close = element(app, "lab.fail.reveal.done")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "A 망작 opens from the gallery as a card")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: close)], timeout: 5), .completed)
        close.tap()

        // Courses: the lab is the one on screen, so its card opens nothing; the 2D course not bought shows its price.
        app.tabBars.buttons["코스"].firstMatch.tap()
        XCTAssertTrue(element(app, "lab.2d.buy").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "lab.courses.open.ai-lab").exists)
        XCTAssertFalse(element(app, "lab.courses.open.2d-ai").exists, "A course not bought does not open from its card")
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
