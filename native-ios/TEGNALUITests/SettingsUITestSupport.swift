import XCTest

/// Settings lists pages at its top level, as the system Settings app does. A test asks for a row
/// by its identifier, and this opens the page that holds it first, from wherever in Settings it is.
extension XCUIApplication {
    /// The page each row lives on; rows that are themselves top-level pages name that page.
    static let settingsPages: [String: String] = {
        var pages: [String: String] = [:]
        let rows: [String: [String]] = [
            "browsing": ["settings.embeddedBrowser", "settings.mangaInfoBeforeReading", "settings.thumbnailGestures", "booru.thumbnailGestures",
                         "booru.browserToggle", "booru.blacklistLink", "manga.defaultTagsSettings", "settings.mangaLanguageExceptions",
                         "settings.rememberHistory", "settings.historyRetention", "settings.recentWorks", "settings.recentWorksInSaved"],
            "appearance": ["settings.gridColumns", "settings.folderColumns", "settings.noGridPadding", "settings.showMangaTitles",
                           "settings.showMangaArtists", "settings.showMangaCategories", "settings.previewColumns", "settings.previewRows"],
            "language": ["settings.appLanguage", "settings.translationLanguage", "settings.preferredLanguage", "settings.artistLanguage", "settings.tagLanguage"],
            "library": ["settings.libraryManagement", "booru.libraryManagement", "settings.downloads", "booru.downloadsLink", "settings.imageCache",
                        "settings.clearCache", "settings.defaultFolder", "settings.folderRules", "booru.folderRules"],
            "start": ["booru.safeMode", "settings.startInStudyMode", "settings.startInViewingMode", "settings.enterStudyMode"],
            "help": ["settings.onboarding", "settings.privacyPolicyRow", "settings.shortcuts", "settings.reset", "developer.logo", "developer.website", "developer.email",
                     "developer.community", "developer.github", "developer.publisher"],
        ]
        for (page, ids) in rows { for id in ids { pages[id] = page } }
        return pages
    }()
    /// Rows that used to sit in the list and are now top-level pages themselves.
    static let settingsPageRows = ["settings.addons": "addons", "settings.privacy": "privacy", "settings.taste": "taste",
                                   "settings.reader": "viewer", "booru.readerSettings": "viewer"]

    private func any(_ id: String) -> XCUIElement { descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Whether the Settings tab shows its top level, with the page rows.
    var showsSettingsTop: Bool {
        descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.category.'")).firstMatch.exists
    }

    /// Returns to Settings' top level from one of its pages.
    func openSettingsTop() {
        for _ in 0..<4 where !showsSettingsTop {
            let back = navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
    }

    /// Opens a top-level Settings page, such as "viewer" or "help".
    func openSettingsPage(_ page: String) {
        let row = any("settings.category." + page)
        if !row.exists || !row.isHittable { openSettingsTop() }
        for _ in 0..<6 where !(row.exists && row.isHittable) { swipeUp() }
        for _ in 0..<8 where !(row.exists && row.isHittable) { swipeDown() }
        XCTAssertTrue(row.isHittable, "Missing Settings page: " + page)
        row.tap()
        _ = any("settings.page." + page).waitForExistence(timeout: 3)
    }

    /// A Settings row, after opening the page that holds it and scrolling it into view.
    func settingsRow(_ id: String) -> XCUIElement {
        if let page = Self.settingsPageRows[id] {
            openSettingsTop()
            let row = any("settings.category." + page)
            for _ in 0..<6 where !(row.exists && row.isHittable) { swipeUp() }
            for _ in 0..<8 where !(row.exists && row.isHittable) { swipeDown() }
            return row
        }
        let row = any(id)
        if row.exists && row.isHittable { return row }
        if let page = Self.settingsPages[id], !any("settings.page." + page).exists { openSettingsPage(page) }
        for _ in 0..<6 where !(row.exists && row.isHittable) { swipeUp() }
        XCTAssertTrue(row.isHittable, "Missing Settings row: " + id)
        return row
    }
}
