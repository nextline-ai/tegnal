import XCTest
import Vision
import UIKit

final class NativeContentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func workInformationPreview(_ app: XCUIApplication, page: Int) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: "content.detail.preview.\(page)")
        for _ in 0..<8 {
            if let visible = query.allElementsBoundByIndex.first(where: \.isHittable) { return visible }
            let scrolls = app.scrollViews.matching(identifier: "content.detail.scroll")
            (scrolls.allElementsBoundByIndex.first(where: \.isHittable) ?? scrolls.firstMatch).swipeUp()
        }
        return query.firstMatch
    }
    private func wait(_ item: XCUIElement, _ predicate: String, _ value: String) {
        expectation(for: NSPredicate(format: predicate, value), evaluatedWith: item)
        waitForExpectations(timeout: 10)
    }
    private func launchReader(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"] + extra
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let read = element(app, "content.read")
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        read.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        // Cached previews can exist before fullScreenCover finishes presenting.
        // Wait for the usable destination, not just an image in the view tree.
        if extra.contains("--reader-help-test") {
            expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "reader.help.close"))
        } else {
            expectation(for: NSPredicate { _, _ in
                app.images.matching(identifier: "reader.image").allElementsBoundByIndex.contains { $0.isHittable }
                    && !app.navigationBars.allElementsBoundByIndex.contains { $0.isHittable }
            }, evaluatedWith: app)
        }
        waitForExpectations(timeout: 10)
        return app
    }
    private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat = 0.5) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
    private func menu(_ app: XCUIApplication) {
        expectation(for: NSPredicate { _, _ in
            app.images.matching(identifier: "reader.image").allElementsBoundByIndex.contains { $0.isHittable }
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        tap(app, x: 0.5)
        XCTAssertTrue(element(app, "reader.position").waitForExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testComicReaderKeepsPageAcrossCompactAndWideViewports() {
        let app = launchReader()
        tap(app, x: 0.9)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.menu.close").tap()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 5))
            menu(app)
            XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
            XCTAssertTrue(element(app, "reader.settings").isHittable)
            capture(app, orientation == .portrait ? "Comic reader compact viewport" : "Comic reader wide viewport")
            element(app, "reader.menu.close").tap()
        }
    }

    func testDownloadOpensInOfflineReader() {
        let app = launchReader()
        menu(app)
        let download = element(app, "reader.download")
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(element(app, "manga.downloads").waitForExistence(timeout: 5))
        let open = element(app, "download.open")
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        let search = element(app, "downloads.search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("sample")
        XCTAssertTrue(open.exists)
        capture(app, "Downloaded comic grid with tag search")
        search.typeText("_missing")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: open)
        waitForExpectations(timeout: 5)
        element(app, "manga.downloads").buttons["검색 지우기"].tap()
        search.typeText("900000001")
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        search.typeText("\n")
        open.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        XCTAssertTrue(element(app, "reader.download.offline").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "reader.download.offline").isEnabled)
        capture(app, "Offline comic reader")
    }

    func testSettingsSwitchExploreBetweenNativeAndBuiltInBrowser() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--native-content-tab-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        let setting = element(app, "settings.embeddedBrowser")
        for _ in 0..<4 where !setting.isHittable { app.swipeUp() }
        XCTAssertTrue(setting.isHittable)
        XCTAssertEqual(setting.value as? String, "0")
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(setting.value as? String, "1")
        capture(app, "Built-in browser setting enabled")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["JavaScript ready"].exists)
        XCTAssertFalse(element(app, "content.gallery.900000001").exists)
        app.links["Next test page"].tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        element(app, "browser.back").tap()
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 5))
        element(app, "browser.forward").tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        element(app, "browser.reload").tap()
        XCTAssertTrue(app.staticTexts["Second page"].waitForExistence(timeout: 5))
        app.links["New-window test page"].tap()
        expectation(for: NSPredicate(format: "value CONTAINS '/third'"), evaluatedWith: element(app, "browser.address"))
        waitForExpectations(timeout: 5)
        capture(app, "Embedded WebKit with navigation")
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<4 where !setting.isHittable { app.swipeUp() }
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(setting.value as? String, "0")
        app.tabBars.buttons["Explore"].tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    func testCategoryMenuNarrowsTheFeedAndCardsShowTheirCategory() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--native-content-long-feed", "--show-categories", "-AppleLanguages", "(en)"]
        app.launch()
        let manga = element(app, "content.gallery.900000001")
        XCTAssertTrue(manga.waitForExistence(timeout: 15))
        XCTAssertTrue(manga.label.contains("Manga"), manga.label)
        element(app, "content.category").tap()
        app.buttons["Doujinshi"].tap()
        let doujinshi = element(app, "content.gallery.900000005")
        XCTAssertTrue(doujinshi.waitForExistence(timeout: 10))
        XCTAssertTrue(doujinshi.label.contains("Doujinshi"), doujinshi.label)
        XCTAssertFalse(manga.exists)
        XCTAssertTrue(element(app, "content.category").label.contains("Doujinshi"))
        capture(app, "Feed narrowed to one category")
        element(app, "content.category").tap()
        app.buttons["All Categories"].tap()
        XCTAssertTrue(manga.waitForExistence(timeout: 10))
    }

    func testLibraryCategoryMenuCountsAndNarrowsSavedWorks() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--category-library-test", "--show-categories", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(element(app, "works.card.900000002").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "works.card.900000002").label.contains("Artist CG"))
        element(app, "works.category").tap()
        capture(app, "Library category menu")
        app.buttons["Manga (2)"].tap()
        XCTAssertTrue(element(app, "works.card.900000001").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "works.card.900000006").exists)
        XCTAssertFalse(element(app, "works.card.900000002").exists)
        capture(app, "Library narrowed to one category")
    }

    func testLibraryWorkOpensRequestedInformationInBrowserAndCloses() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--library-jump-test", "--browser-fallback-test", "-AppleLanguages", "(en)"]
        app.launch()
        let card = element(app, "works.card.910000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Browser ready"].waitForExistence(timeout: 10))
        let address = element(app, "browser.address").value as? String ?? ""
        XCTAssertTrue(address.contains("/galleries/910000001.html"), address)
        XCTAssertFalse(element(app, "reader.image").exists)
        capture(app, "Library work in browser fallback")
        element(app, "browser.close").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testSavedInformationDismissesDownwardFromTheGrabber() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--library-jump-test", "-AppleLanguages", "(en)"]
        app.launch()
        let card = element(app, "works.card.910000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let read = element(app, "content.read")
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        let navigation = app.navigationBars["Work Details"]
        XCTAssertTrue(navigation.exists)
        capture(app, "Saved work uses the draggable information sheet")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Saved information sheet hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let grabber = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: navigation.frame.midX, dy: navigation.frame.minY - 8))
        grabber.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        XCTAssertTrue(read.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
    }

    func testBottomSwipeRevealsWorkInformationWithoutAdvancingThePage() {
        let app = launchReader()
        for mode in [nil, "수직으로 넘기기", "스크롤로 보기"] as [String?] {
            if let mode {
                element(app, "reader.settings").tap()
                element(app, "reader.settings.mode").tap()
                app.buttons[mode].tap()
                if mode == "스크롤로 보기" {
                    element(app, "reader.settings.continuousInformationSwipe").switches.firstMatch.tap()
                }
                element(app, "reader.settings.done").tap()
                element(app, "reader.menu.close").tap()
            }
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            bottom.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            let number = element(app, "content.detail.workNumber")
            XCTAssertTrue(number.waitForExistence(timeout: 5))
            XCTAssertFalse(element(app, "content.read").isHittable)
            XCTAssertFalse(element(app, "content.detail.cover").isHittable)
            capture(app, "Bottom swipe reveals work information " + (mode ?? "horizontal"))
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Work information hierarchy " + (mode ?? "horizontal"); hierarchy.lifetime = .keepAlways; add(hierarchy)
            app.buttons["완료"].tap()
            menu(app)
            XCTAssertEqual(element(app, "reader.position").label, "페이지 1 / 3", "Opening work information must not also scroll or turn the page")
        }
    }

    func testExploreInformationDefersPreviewsUntilScrollingAndOpensChosenPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(en)"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        verifyDeferredDetailPreviews(app)
    }

    func testSavedWorkOpensTheSameInformationAndDeferredPreviews() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--library-jump-test", "-AppleLanguages", "(en)"]
        app.launch()
        let card = element(app, "works.card.910000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertFalse(element(app, "reader.image").exists)
        verifyDeferredDetailPreviews(app)
        element(app, "content.close").tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    func testPreviewColumnSettingCreatesProportionalGridWithoutPageNumbers() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--native-content-tab-test", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        let picker = element(app, "settings.previewColumns")
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(picker.label.contains("Automatic (2× Grid)"))
        picker.tap()
        app.buttons["6"].tap()
        capture(app, "Preview column setting")
        app.buttons["Explore"].tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let first = element(app, "content.detail.preview.1")
        let second = element(app, "content.detail.preview.2")
        let third = element(app, "content.detail.preview.3")
        let scroll = element(app, "content.detail.scroll")
        for _ in 0..<6 where !third.isHittable { scroll.swipeUp() }
        XCTAssertTrue(third.isHittable)
        XCTAssertGreaterThan(second.frame.minX - first.frame.maxX, 0)
        XCTAssertLessThan(second.frame.minX - first.frame.maxX, 14)
        XCTAssertEqual(first.frame.minY, third.frame.minY, accuracy: 1)
        XCTAssertLessThan(first.frame.width, scroll.frame.width / 5)
        XCTAssertFalse(first.staticTexts["1"].exists)
        XCTAssertFalse(second.staticTexts["2"].exists)
        capture(app, "Dense previews with proportional spacing and no page numbers")
        third.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.information").tap()
        let readerFirst = workInformationPreview(app, page: 1), readerSecond = workInformationPreview(app, page: 2)
        XCTAssertTrue(readerSecond.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(readerSecond.frame.minX - readerFirst.frame.maxX, 0)
        XCTAssertLessThan(readerSecond.frame.minX - readerFirst.frame.maxX, 14)
        XCTAssertLessThan(readerFirst.frame.width, app.frame.width / 5)
        XCTAssertFalse(readerFirst.staticTexts["1"].exists)
        capture(app, "Reader uses the same dense preview setting")
    }

    private func verifyDeferredDetailPreviews(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 10))
        let preview = element(app, "content.detail.preview.3")
        XCTAssertFalse(preview.exists, "Opening information must not create page thumbnail tasks")
        let scroll = element(app, "content.detail.scroll")
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertFalse(preview.exists, "A tiny scroll must not trigger page previews")
        for _ in 0..<6 where !preview.isHittable { scroll.swipeUp() }
        XCTAssertTrue(preview.isHittable)
        capture(app, "Information page previews after intentional scrolling")
        preview.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "Page 3 / 3")
        element(app, "reader.exit").tap()
        XCTAssertTrue(element(app, "content.detail.preview.3").waitForExistence(timeout: 5))
    }

    func testEnglishLocalization() { verifyLocalization("en", explore: "Explore", read: "Read", guide: "Reader Guide", menu: "Quick Menu") }
    func testJapaneseLocalization() { verifyLocalization("ja", explore: "探索", read: "読む", guide: "ビューアの使い方", menu: "クイックメニュー") }
    func testKoreanLocalization() { verifyLocalization("ko", explore: "탐색", read: "읽기", guide: "읽기 모드 안내", menu: "퀵 메뉴") }
    func testUnsupportedLanguageFallsBackToEnglish() { verifyLocalization("fr", explore: "Explore", read: "Read", guide: "Reader Guide", menu: "Quick Menu") }

    private func verifyLocalization(_ language: String, explore: String, read: String, guide: String, menu menuTitle: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--native-content-tab-test", "--reader-help-test",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[explore].waitForExistence(timeout: 10))
        capture(app, "Localized folders " + language)
        app.tabBars.buttons[explore].tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        capture(app, "Localized explore " + language)
        card.tap()
        let readButton = element(app, "content.read")
        XCTAssertTrue(readButton.waitForExistence(timeout: 10))
        XCTAssertEqual(readButton.label, read)
        readButton.tap()
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars[guide].exists)
        element(app, "reader.help.next").tap()
        capture(app, "Localized guide " + language)
        element(app, "reader.help.close").tap()
        menu(app)
        capture(app, "Localized quick menu " + language)
        element(app, "reader.settings").tap()
        capture(app, "Localized reader settings " + language)
        element(app, "reader.settings.done").tap()
    }

    func testReaderBookmarksAtBothScreenEdgesWithoutTurningPages() {
        let app = launchReader()
        for x in [0.06, 0.94] {
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.65)).press(forDuration: 0.8)
            XCTAssertTrue(element(app, "reader.toast").waitForExistence(timeout: 3))
            menu(app)
            XCTAssertEqual(element(app, "reader.position").label, "페이지 1 / 3")
            element(app, "reader.menu.close").tap()
        }
    }

    func testImmersiveReaderGesturesPreviewAndBookmark() {
        let app = launchReader()
        XCTAssertFalse(app.navigationBars.allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(element(app, "reader.position").exists)
        capture(app, "Immersive reader without chrome")
        let image = element(app, "reader.image")
        image.doubleTap()
        wait(image, "value == %@", "250%")
        image.doubleTap()
        wait(image, "value == %@", "100%")
        tap(app, x: 0.9)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.menu.close").tap()
        tap(app, x: 0.1)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 1 / 3")
        XCTAssertFalse(element(app, "reader.previous").isEnabled)
        capture(app, "Reader quick menu Liquid Glass white controls")
        element(app, "reader.information").tap()
        let last = workInformationPreview(app, page: 3)
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        last.tap()
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        XCTAssertFalse(element(app, "reader.next").isEnabled)
        element(app, "reader.menu.close").tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8)
        XCTAssertTrue(element(app, "reader.toast").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "reader.toast").label, "북마크를 표시했습니다")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        menu(app)
        element(app, "reader.exit").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testReadingModesAndPersistentQuickMenu() {
        let app = launchReader()
        menu(app)
        element(app, "reader.settings").tap()
        let rtl = element(app, "reader.settings.rtl")
        rtl.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(rtl, "value == %@", "1")
        let bottom = element(app, "reader.settings.bottomMenu")
        bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(bottom, "value == %@", "1")
        element(app, "reader.settings.done").tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.settings.done"))
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "reader.menu.close"))
        waitForExpectations(timeout: 10)
        element(app, "reader.menu.close").tap()
        XCTAssertTrue(element(app, "reader.settings").waitForExistence(timeout: 5))
        // Allow the sheet and glass morph transition to complete before capturing pixels.
        sleep(1)
        capture(app, "Persistent Liquid Glass white controls")
        tap(app, x: 0.1)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.settings").tap()
        element(app, "reader.settings.mode").tap()
        app.buttons["수직으로 넘기기"].tap()
        element(app, "reader.settings.done").tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.settings.done"))
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "reader.menu.close"))
        waitForExpectations(timeout: 10)
        element(app, "reader.menu.close").tap()
        app.swipeUp()
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        element(app, "reader.settings").tap()
        element(app, "reader.settings.mode").tap()
        app.buttons["스크롤로 보기"].tap()
        element(app, "reader.settings.done").tap()
        element(app, "reader.information").tap()
        workInformationPreview(app, page: 1).tap()
        element(app, "reader.menu.close").tap()
        app.swipeUp()
        menu(app)
        XCTAssertNotEqual(element(app, "reader.position").label, "페이지 1 / 3")
        capture(app, "Continuous reader with quick menu")
    }

    func testContinuousScrollBackwardsKeepsReaderOpenAndTopHandleCloses() {
        let app = launchReader()
        menu(app)
        element(app, "reader.settings").tap()
        element(app, "reader.settings.mode").tap()
        app.buttons["스크롤로 보기"].tap()
        element(app, "reader.settings.done").tap()
        element(app, "reader.information").tap()
        workInformationPreview(app, page: 2).tap()
        element(app, "reader.menu.close").tap()
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertFalse(element(app, "content.read").isHittable)
        menu(app)
        capture(app, "Continuous scroll backwards stays in reader")
        element(app, "reader.menu.close").tap()
        let handle = element(app, "reader.exitHandle")
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testComicInformationUsesReadableTagsWithoutGenderHeadings() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        let tag = element(app, "tags.female.female:sample")
        for _ in 0..<3 where !tag.isHittable { app.swipeUp() }
        XCTAssertTrue(tag.isHittable)
        XCTAssertGreaterThan(tag.frame.height, 30)
        XCTAssertFalse(app.staticTexts["여성 태그"].exists)
        XCTAssertFalse(app.staticTexts["남성 태그"].exists)
        capture(app, "Comic information uses readable tags with color-only gender groups")
    }

    func testReaderTagSizesMatchLanguageAndKeepCategoryColors() throws {
        let app = launchReader()
        menu(app)
        element(app, "reader.information").tap()
        let language = element(app, "content.detail.language")
        let tag = element(app, "tags.female.female:sample")
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        // List accessibility bounds include row insets. Compare the rendered
        // text instead, so a padded language row cannot hide a tiny tag font.
        let screenshot = try XCTUnwrap(app.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: screenshot).perform([request])
        func textHeight(_ value: String) -> CGFloat? {
            guard let box = request.results?.first(where: { $0.topCandidates(1).first?.string.lowercased() == value })?.boundingBox else { return nil }
            return box.height * CGFloat(screenshot.height)
        }
        let languageHeight = try XCTUnwrap(textHeight("english"))
        let tagHeight = try XCTUnwrap(textHeight("sample"))
        XCTAssertEqual(tagHeight / languageHeight, 1, accuracy: 0.12)
        capture(app, "Consistent language and categorized tag sizes")
    }

    func testOneTapTranslationOnDevice() throws {
        let app = launchReader()
        menu(app)
        element(app, "reader.translate").tap()
        XCTAssertTrue(element(app, "reader.original").waitForExistence(timeout: 10))
        let progress = element(app, "reader.translation.progress")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: progress)
        waitForExpectations(timeout: 60)
        sleep(5)
        capture(app, "Apple Live Text image translation")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let visibleText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(visibleText.contains("확대하려면") && visibleText.contains("탭하세요"), "The actual Apple overlay must display translated page content: \(visibleText)")
        func translateControlNearBottom() throws -> Bool {
            try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
            // Vision's origin is at the bottom left: the control sits in the screen's bottom band.
            return (request.results ?? []).contains { ($0.topCandidates(1).first?.string.contains("번역") ?? false) && $0.boundingBox.midY < 0.15 }
        }
        XCTAssertTrue(try translateControlNearBottom(), "The Translate control sits at the bottom of the screen, below the page")
        func analyses() -> Int { Int((element(app, "reader.translation.canvas").value as? String ?? "").filter(\.isNumber)) ?? 0 }
        XCTAssertEqual(analyses(), 1)
        let translatedImage = element(app, "reader.translation.image")
        translatedImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        wait(translatedImage, "value == %@", "250%")
        sleep(5)
        XCTAssertEqual(translatedImage.value as? String, "250%")
        capture(app, "Apple image translation enlarged")
        XCTAssertFalse(element(app, "reader.translation.progress").exists, "The enlarged area's analysis has finished")
        XCTAssertFalse(element(app, "reader.translation.retry").exists)
        XCTAssertEqual(analyses(), 2, "A settled zoom analyzes the enlarged area again, for small text")
        XCTAssertTrue(try translateControlNearBottom(), "Zoom leaves the Translate control at the bottom of the screen")
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let enlargedText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(enlargedText.contains("탭") || enlargedText.contains("확대"), "The enlarged page must still contain translated content: \(enlargedText)")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.75)))
        app.pinch(withScale: 1.2, velocity: 1)
        sleep(1)
        XCTAssertNotEqual(translatedImage.value as? String, "250%", "Pinch must reach the image through the system overlay")
        XCTAssertNotEqual(translatedImage.value as? String, "100%")
        XCTAssertGreaterThanOrEqual(analyses(), 2)
        try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
        let controlsText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(controlsText.contains { $0.contains("번역") }, "The native translation control must stay on screen after zoom and pan")
        capture(app, "Translation controls remain in viewport after pan and pinch")
        element(app, "reader.original").tap()
        XCTAssertFalse(element(app, "reader.original").exists)
        XCTAssertTrue(element(app, "reader.image").exists)
    }

    func testJapaneseTranslationStartsOnRepeatedOpen() throws {
        let app = launchReader(extra: ["--reader-japanese-test"])
        for attempt in 1...3 {
            menu(app)
            element(app, "reader.translate").tap()
            XCTAssertTrue(element(app, "reader.original").waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "reader.translation.progress"))
            waitForExpectations(timeout: 60)
            sleep(5)
            capture(app, "Japanese automatic translation \(attempt)")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "ja-JP"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(app.screenshot().image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("날씨") || text.contains("공원"), "Actual translated page content is required: \(text)")
            XCTAssertFalse(element(app, "reader.translation.retry").exists)
            element(app, "reader.original").tap()
        }
    }

    func testZoomedShortPagePansVerticallyWithoutExitOrPaging() {
        let app = launchReader(extra: ["--reader-short-page-test"])
        let image = element(app, "reader.image")
        image.doubleTap()
        wait(image, "value == %@", "250%")
        let before = image.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        sleep(1)
        XCTAssertTrue(image.isHittable, "The enlarged reader must remain visible and interactive")
        XCTAssertFalse(element(app, "content.read").isHittable, "Downward pan while zoomed must never dismiss")
        XCTAssertGreaterThan(image.frame.minY, before.minY + 80, "Short pages need real vertical travel, not only bounce")
        app.swipeLeft()
        XCTAssertEqual(image.value as? String, "250%", "Horizontal pan must not turn a page")
        capture(app, "Short zoomed image with free vertical movement")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        wait(image, "value == %@", "100%")
        tap(app, x: 0.9)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 2 / 3")
        element(app, "reader.menu.close").tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testFavoritingATagKeepsItOnItsLine() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.information").tap()
        let artist = element(app, "content.detail.artist.TEGNAL")
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        let line = artist.frame.minY
        artist.press(forDuration: 0.8)
        XCTAssertEqual(artist.frame.minY, line, accuracy: 3)
    }

    func testHoldingAGroupSavesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.information").tap()
        let group = element(app, "tags.group.group:sample circle")
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "group saved"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func launchLinkedWork(_ language: String, locale: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--work-links-test", "-AppleLanguages", "(\(language))", "-AppleLocale", locale] + extra
        app.launch()
        return app
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAWorkLeadsToItsOtherLanguagesAndRelatedWorks() {
        let app = launchLinkedWork("ko", locale: "ko_KR", extra: ["-manga.showInformationBeforeReading", "YES"])
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let suggestion = element(app, "content.detail.versionSuggestion")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10), "An English work with a Korean version offers it to a Korean reader")
        XCTAssertGreaterThan(suggestion.frame.minY, element(app, "content.bookmark").frame.maxY, "It sits just below Save to Library")
        shot("language suggestion")
        suggestion.tap()
        wait(element(app, "content.detail.metadata"), "label BEGINSWITH %@", "korean")
        XCTAssertFalse(element(app, "content.detail.versionSuggestion").exists, "Already in the reader's language")
        XCTAssertTrue(element(app, "content.detail.version.900000001").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "content.detail.version.900000002").exists, "A work never links to itself")
        shot("opened version")
        app.navigationBars.buttons["BackButton"].tap()
        wait(element(app, "content.detail.metadata"), "label BEGINSWITH %@", "english")

        let scroll = app.scrollViews.matching(identifier: "content.detail.scroll").firstMatch
        let related = element(app, "content.gallery.900000011")
        for _ in 0..<8 where !related.isHittable { scroll.swipeUp() }
        XCTAssertTrue(related.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "content.gallery.900000012").exists)
        XCTAssertFalse(app.scrollViews.matching(identifier: "content.detail.related").firstMatch.descendants(matching: .any).matching(identifier: "content.gallery.900000002").firstMatch.exists,
                       "This work's own translation is not a related work")
        shot("related works")
        related.tap()
        wait(element(app, "content.detail.title"), "label CONTAINS %@", "900000011")
    }

    func testReaderInformationOffersYourLanguageBelowSaving() {
        let app = launchLinkedWork("ko", locale: "ko_KR")
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.information").tap()
        let suggestion = element(app, "content.detail.versionSuggestion")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(suggestion.frame.minY, element(app, "content.bookmark").frame.maxY)
        shot("reader language suggestion")
    }

    func testChangingLanguageInTheReaderKeepsThePage() {
        let app = launchLinkedWork("en", locale: "en_US")
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.next").tap()
        XCTAssertEqual(element(app, "reader.position").label, "Page 2 / 3")
        element(app, "reader.information").tap()
        let version = element(app, "content.detail.version.900000002")
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        shot("reader languages")
        version.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "Page 2 / 3")
        element(app, "reader.information").tap()
        wait(element(app, "content.detail.metadata"), "label BEGINSWITH %@", "korean")
    }

    func testChoosingAFolderSavesAtOnceAndOffersAnotherChange() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.bookmark").tap()
        let change = element(app, "reader.toast.folder")
        XCTAssertTrue(change.waitForExistence(timeout: 3))
        change.tap()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "workFolder.")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 5))
        XCTAssertTrue(change.waitForExistence(timeout: 5), "The notice must offer another change")
        XCTAssertTrue(element(app, "reader.toast").label.contains("Saved to folder"))
        XCTAssertTrue(element(app, "reader.toast").label.contains("Unfiled"))
    }

    func testWorkInformationLeadsWithTitleAndDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "NO",
                               "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(element(app, "reader.image").waitForExistence(timeout: 10))
        menu(app)
        element(app, "reader.information").tap()

        // Do not scroll before checking the initial layout.
        let title = element(app, "content.detail.title")
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(title.isHittable)
        XCTAssertFalse(element(app, "content.detail.moreInformation").exists)
    }

    func testHelpCanBeDismissedAndReopened() {
        let app = launchReader(extra: ["--reader-help-test"])
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "reader.help.overlay").exists)
        XCTAssertTrue(element(app, "reader.image").exists, "The actual work stays behind the overlay")
        XCTAssertFalse(app.segmentedControls.element.exists, "There is no separate manual")
        capture(app, "Reader center coach mark")
        tap(app, x: 0.5)
        XCTAssertTrue(element(app, "reader.settings").waitForExistence(timeout: 5))
        capture(app, "Reader real quick menu coach mark")
        element(app, "reader.help.next").tap()
        XCTAssertFalse(element(app, "reader.settings").exists)
        capture(app, "Reader exit coach mark")
        element(app, "reader.help.next").tap()
        XCTAssertFalse(element(app, "reader.help.overlay").exists)
        menu(app)
        element(app, "reader.settings").tap()
        app.swipeUp()
        app.swipeUp()
        element(app, "reader.settings.help").tap()
        XCTAssertTrue(element(app, "reader.help.close").waitForExistence(timeout: 5))
        element(app, "reader.help.close").tap()
    }

    func testMultiplePagesAutoAdvanceAndDownwardExit() {
        let app = launchReader(extra: ["--reader-auto-test"])
        menu(app)
        element(app, "reader.settings").tap()
        element(app, "reader.settings.spread").tap()
        app.buttons["2페이지"].tap()
        let auto = element(app, "reader.settings.auto")
        auto.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        element(app, "reader.settings.done").tap()
        element(app, "reader.menu.close").tap()
        capture(app, "Two pages side by side")
        // Auto advance moves by the spread size; the quick menu then pauses it.
        sleep(3)
        menu(app)
        XCTAssertEqual(element(app, "reader.position").label, "페이지 3 / 3")
        // The exit gesture also works while the quick menu is open.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testExploreTabAndDetailSearch() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-tab-test"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["탐색"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["전체"].exists)
        app.tabBars.buttons["탐색"].tap()
        XCTAssertFalse(element(app, "content.open").exists)
        XCTAssertFalse(element(app, "content.close").exists)
        element(app, "content.sort").tap()
        app.buttons["주간 인기순"].tap()
        element(app, "content.language").tap()
        app.buttons["영어"].tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        element(app, "content.read").tap()
        menu(app)
        element(app, "reader.information").tap()
        element(app, "tags.female.female:sample").tap()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "content.search").value as? String, "female:sample")
        capture(app, "Explore tab tag search")
    }

    func testFolderQuickJumpToOldestAndMonth() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--library-jump-test"]
        app.launch()
        let jump = element(app, "works.jump")
        XCTAssertTrue(jump.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(element(app, "works.add").frame.midX - jump.frame.midX, 44)
        jump.tap()
        app.buttons["맨 아래로"].tap()
        let oldest = element(app, "works.card.910000120")
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: oldest)
        waitForExpectations(timeout: 10)
        capture(app, "Folder oldest work without scrolling")
        jump.tap()
        app.buttons["맨 위로"].tap()
        XCTAssertTrue(element(app, "works.card.910000001").isHittable)
        jump.tap()
        app.buttons["저장한 달로 이동"].tap()
        let august = element(app, "works.month.2026-08")
        XCTAssertTrue(august.waitForExistence(timeout: 5))
        capture(app, "Folder month picker")
        august.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element(app, "works.card.910000061"))
        waitForExpectations(timeout: 10)
        capture(app, "Folder jumped to August")
    }

    func testExploreScrollSearchAndTagCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-long-feed"]
        app.launch()
        let search = element(app, "content.search")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        app.swipeUp()
        capture(app, "Explore after scroll")
        expectation(for: NSPredicate { _, _ in !search.exists || !search.isHittable }, evaluatedWith: search)
        waitForExpectations(timeout: 5)
        app.swipeDown()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: search)
        waitForExpectations(timeout: 5)
        search.tap()
        search.typeText("language:korean female:sa")
        let suggestion = element(app, "content.suggestion.female:sample_tag")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        capture(app, "Explore tag autocomplete")
        suggestion.tap()
        XCTAssertEqual(search.value as? String, "language:korean female:sample_tag ")
        search.typeText("\n")
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        XCTAssertFalse(suggestion.exists)
        capture(app, "Explore completed tag search")
    }

    /// The confirmation takes focus from the search field, which closes the history panel;
    /// the alert must stay until it is answered.
    func testExploreSearchHistoryClearConfirmationStaysOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let search = element(app, "content.search")
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("female:sample\n")
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        let entry = element(app, "history.query.female:sample")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        element(app, "history.clear").tap()
        let alert = app.alerts["Clear History?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(alert.exists, "The confirmation must not close by itself")
        capture(app, "Explore clear history confirmation")
        alert.buttons["Clear History"].tap()
        XCTAssertFalse(alert.exists)
        search.tap()
        XCTAssertTrue(app.staticTexts["Nothing Saved Yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(entry.exists)
    }

    func testRecentWorksFolderInSavedFollowsTheSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "--native-content-tab-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.tabBars.buttons["Saved"].tap()
        XCTAssertFalse(element(app, "manga.recentFolder").waitForExistence(timeout: 3), "Off until chosen in Settings")
        app.tabBars.buttons["Settings"].tap()
        let setting = element(app, "settings.recentWorksInSaved")
        for _ in 0..<8 where !setting.isHittable { app.swipeUp() }
        XCTAssertTrue(setting.isHittable)
        XCTAssertEqual(setting.value as? String, "0")
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(setting.value as? String, "1")
        capture(app, "Recent works folder setting")
        app.tabBars.buttons["Saved"].tap()
        let folder = element(app, "manga.recentFolder")
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        capture(app, "Recent works folder in Saved")
        folder.tap()
        // Laid out as a folder's works: its back capsule, search bar and grid controls.
        let back = element(app, "recentWorks.back")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "recentWorks.search").exists)
        XCTAssertTrue(element(app, "recentWorks.select").exists)
        capture(app, "Recent works opened from Saved")
        back.tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.press(forDuration: 1.0)
        app.buttons["Hide from Saved"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: folder)
        waitForExpectations(timeout: 5)
    }

    func testSlowThumbnailDoesNotHoldFeedLoading() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--slow-detail-cover-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The list must not wait for the 20-second cover response")
        XCTAssertTrue(element(app, "content.loading").waitForNonExistence(timeout: 5))
        let metadata = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "네이티브 읽기 테스트"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [metadata], timeout: 5), .completed)
        card.tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5), "Slow covers must not prevent opening a work")
    }

    func testExplorePreparedCardsAcrossInfiniteScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--native-content-long-feed", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR"]
        app.launch()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        let nextPage = element(app, "content.gallery.900000025")
        for _ in 0..<18 {
            if nextPage.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(nextPage.isHittable)
        for card in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "content.gallery.")).allElementsBoundByIndex where card.isHittable {
            XCTAssertTrue(card.label.contains("네이티브 읽기 테스트"), "A visible card must already have its prepared metadata and cover")
        }
        let previousY = nextPage.frame.minY
        XCUIDevice.shared.press(.home); app.activate()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: nextPage)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(nextPage.frame.minY, previousY, accuracy: 8, "Returning to the app must retain the loaded page and scroll position")
        capture(app, "Explore prepared thumbnails beyond the first page")
        nextPage.tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testExploreReverseScrollKeepsPreparedTextAndCardHeight() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "--native-content-long-feed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let first = element(app, "content.gallery.900000001")
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "네이티브 읽기 테스트"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 5), .completed)
        let originalHeight = first.frame.height
        let later = element(app, "content.gallery.900000025")
        for _ in 0..<12 {
            if later.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(later.isHittable)
        XCTAssertFalse(first.isHittable)
        for _ in 0..<12 {
            if first.isHittable { break }
            app.swipeDown()
            for card in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "content.gallery.")).allElementsBoundByIndex where card.isHittable {
                XCTAssertTrue(card.label.contains("네이티브 읽기 테스트"), "Returning rows must retain their text while covers are restored")
            }
        }
        XCTAssertTrue(first.isHittable)
        XCTAssertEqual(first.frame.height, originalHeight, accuracy: 1)
        capture(app, "Explore returning to previously loaded rows")
        first.tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testPreparedExploreCoverKeepsDetailLayoutAndDismissesDownward() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let cardY = card.frame.minY
        card.tap()
        let read = element(app, "content.read"), cover = element(app, "content.detail.cover"), title = element(app, "content.detail.title")
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Thumbnail loaded"), object: cover)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let coverFrame = cover.frame, titleY = title.frame.minY, readY = read.frame.minY
        XCTAssertEqual(coverFrame.height, 300, accuracy: 1)
        capture(app, "Work details using the prepared Explore thumbnail")
        read.tap()
        XCTAssertTrue(element(app, "reader.exitHandle").waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(element(app, "reader.exitHandle").waitForNonExistence(timeout: 5))
        XCTAssertTrue(read.isHittable)
        XCTAssertEqual(cover.frame.height, coverFrame.height, accuracy: 1)
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        XCTAssertEqual(read.frame.minY, readY, accuracy: 1)
        // Dismiss from the content, including after returning from the immersive reader.
        cover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(read.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
        XCTAssertEqual(card.frame.minY, cardY, accuracy: 1)
    }

    func testImageFailureStillAllowsExit() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-image-error"]
        app.launch()
        XCTAssertTrue(element(app, "content.gallery.900000001").waitForExistence(timeout: 10))
        element(app, "content.gallery.900000001").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 10))
        element(app, "content.read").tap()
        XCTAssertTrue(element(app, "content.retry").waitForExistence(timeout: 10))
        tap(app, x: 0.5, y: 0.3)
        XCTAssertTrue(element(app, "reader.exit").waitForExistence(timeout: 5))
        element(app, "reader.exit").tap()
        XCTAssertTrue(element(app, "content.read").waitForExistence(timeout: 5))
    }

    func testBrowseLongPressAndNetworkRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--native-content-ui-test", "-manga.showInformationBeforeReading", "YES", "-AppleLanguages", "(ko)", "-AppleLocale", "ko_KR", "--native-content-initial-error"]
        app.launch()
        let retry = element(app, "content.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        retry.tap()
        let card = element(app, "content.gallery.900000001")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "content.grid").exists)
        capture(app, "Browse shared gallery grid")
        XCTAssertEqual(card.value as? String, "북마크 안 됨")
        card.press(forDuration: 0.8)
        XCTAssertTrue(element(app, "content.toast").waitForExistence(timeout: 3))
        XCTAssertEqual(element(app, "content.toast").label, "북마크를 표시했습니다")
        wait(card, "value == %@", "북마크됨")
        capture(app, "Explore bookmark badge")
        XCTAssertFalse(element(app, "content.read").exists, "Long press must not also open the gallery")
        card.press(forDuration: 0.8)
        wait(card, "value == %@", "북마크 안 됨")
        XCTAssertEqual(element(app, "content.toast").label, "북마크를 해제했습니다")
        for _ in 0..<3 {
            app.swipeDown()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["결과 없음"].exists)
        }
        capture(app, "Explore bookmark removed and refresh retained")
    }
}
