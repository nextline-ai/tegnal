import XCTest

final class MarketingScreenshotsTests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tab(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(button, "Missing navigation: " + label)
        button?.tap()
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    func testScreenshots() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--marketing-capture", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        XCTAssertTrue(element(app, "booru.allFavorites").waitForExistence(timeout: 15))
        // Allow the local ImageIO thumbnails to finish before recording the library.
        Thread.sleep(forTimeInterval: 2)
        shot(app, "01-library-top")
        app.swipeUp(velocity: .slow)
        shot(app, "01-library")
        tab(app, "탐색")
        let cover = element(app, "booru.post.1004")
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        shot(app, "02-explore")
        cover.tap()
        let ready = element(app, "marketing.mediaStatus")
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'ready'"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        shot(app, "03-viewer")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "booru.menuClose").waitForExistence(timeout: 5))
        shot(app, "04-viewer-controls")
        // Exit through the visible menu so a top-edge drag cannot open Notification Center.
        element(app, "booru.close").tap()
        XCTAssertTrue(element(app, "booru.media").waitForNonExistence(timeout: 5))
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        let search = app.textFields["booru.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        XCTAssertTrue(element(app, "history.clear").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "history.saved.indoors plants").waitForExistence(timeout: 5))
        let savedQuery = element(app, "history.saved.indoors plants")
        // A compact viewport cannot show both sections above the keyboard at once.
        if !savedQuery.isHittable { app.scrollViews["search.suggestions"].swipeUp(velocity: .slow) }
        XCTAssertTrue(savedQuery.isHittable)
        shot(app, "08-search-history")
        app.buttons["검색 지우기"].firstMatch.tap()
        tab(app, "태그")
        app.swipeUp(velocity: .slow)
        shot(app, "05-saved-searches")
        tab(app, "저장")
        let all = element(app, "booru.allFavorites")
        for _ in 0..<4 where !all.isHittable { app.swipeDown() }
        XCTAssertTrue(all.isHittable); all.tap()
        XCTAssertTrue(element(app, "booru.select").waitForExistence(timeout: 5))
        element(app, "booru.select").tap()
        element(app, "booru.post.1001").tap()
        element(app, "booru.post.1002").tap()
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "06-organize")
        tab(app, "더보기")
        XCTAssertTrue(app.staticTexts["Discord에 참여하세요"].waitForExistence(timeout: 5))
        shot(app, "09-settings")
        let safeMode = app.switches["booru.safeMode"]
        for _ in 0..<12 where !safeMode.isHittable { app.swipeUp() }
        XCTAssertTrue(safeMode.isHittable)
        let safeControl = safeMode.switches.firstMatch
        XCTAssertTrue(safeControl.exists); safeControl.tap()
        XCTAssertTrue(element(app, "booru.safeRating").waitForExistence(timeout: 5))
        shot(app, "10-safe-mode")
        let management = element(app, "booru.libraryManagement")
        for _ in 0..<10 where !management.isHittable { app.swipeUp() }
        XCTAssertTrue(management.isHittable); management.tap()
        XCTAssertTrue(element(app, "backup.export").waitForExistence(timeout: 5))
        shot(app, "07-backup")
    }
    func testOrganizationScreenshot() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--booru-ui-test", "--marketing-capture", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        let all = element(app, "booru.allFavorites")
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        all.tap()
        XCTAssertTrue(element(app, "booru.select").waitForExistence(timeout: 5))
        element(app, "booru.select").tap()
        element(app, "booru.post.1001").tap()
        element(app, "booru.post.1002").tap()
        // Wait for the final tapped checkbox's pressed highlight to finish.
        Thread.sleep(forTimeInterval: 0.6)
        shot(app, "06-organize")
    }
}
