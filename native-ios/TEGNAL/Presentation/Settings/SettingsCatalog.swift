import SwiftUI

/// The pages Settings is divided into, as the system Settings app divides its own. The top level
/// lists only these, the ones that change the most first.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case browsing, viewer, appearance, language, library, taste, addons, start, privacy, help
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .browsing: "Explore & Search"
        case .viewer: "Viewer"
        case .appearance: "Appearance & Layout"
        case .language: "Language & Translation"
        case .library: "Library & Storage"
        case .taste: "Taste Analysis"
        case .addons: "Add-ons"
        case .start: "Start & Safe Mode"
        case .privacy: "Privacy & Security"
        case .help: "Help & About"
        }
    }
    var title: String { L10n.text(titleKey) }

    var symbol: String {
        switch self {
        case .browsing: "magnifyingglass"
        case .viewer: "book.fill"
        case .appearance: "square.grid.2x2.fill"
        case .language: "character.bubble.fill"
        case .library: "externaldrive.fill"
        case .taste: "sparkles"
        case .addons: "puzzlepiece.extension.fill"
        case .start: "power"
        case .privacy: "hand.raised.fill"
        case .help: "questionmark"
        }
    }

    /// The tile colors follow the system Settings app: one system color per page.
    var tint: Color {
        switch self {
        case .browsing: .blue
        case .viewer: .orange
        case .appearance: .indigo
        case .language: .teal
        case .library: .gray
        case .taste: .pink
        case .addons: .purple
        case .start: .green
        case .privacy: .blue
        case .help: .gray
        }
    }

    /// Top-level groups, in order: what changes every visit first, help last. Add-ons sits with the
    /// website or servers, above these, since add-ons change what those show.
    static let groups: [[SettingsCategory]] = [
        [.browsing, .viewer, .appearance, .language],
        [.library, .taste],
        [.start, .privacy],
        [.help],
    ]
}

/// How the assistant may change a setting. Every value is text: "on"/"off", an option, a number or tags.
struct SettingsControl {
    enum Kind {
        case toggle
        case choice([(value: String, title: String)])
        case number(ClosedRange<Int>)
        /// Tags added to or removed from a list; the value is the tags, separated by spaces.
        case tags
    }
    let kind: Kind
    let get: @MainActor (AppEnvironment) -> String
    let set: @MainActor (AppEnvironment, String) -> Void
    /// Names the assistant sees instead of stored values that would mislead it, by stored value.
    var modelNames: [String: String] = [:]

    func modelName(_ value: String) -> String { modelNames[value] ?? value }

    /// The value in the form `set` takes, or nil when it is not one this setting allows.
    func normalized(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .toggle:
            switch text.lowercased() {
            case "on", "true", "yes", "1": return "on"
            case "off", "false", "no", "0": return "off"
            default: return nil
            }
        case .choice(let options):
            return options.first { $0.value.caseInsensitiveCompare(text) == .orderedSame || modelName($0.value).caseInsensitiveCompare(text) == .orderedSame }?.value
        case .number(let range):
            guard let number = Int(text), range.contains(number) else { return nil }
            return String(number)
        case .tags:
            let tags = SettingsControl.tags(text)
            return tags.isEmpty ? nil : tags.joined(separator: " ")
        }
    }

    /// A value as the screen shows it.
    func display(_ value: String) -> String {
        switch kind {
        case .toggle: L10n.text(value == "on" ? "settings.value.on" : "settings.value.off")
        case .choice(let options): options.first { $0.value == value }?.title ?? value
        case .number, .tags: value
        }
    }

    /// The allowed values, as the assistant reads them.
    var allowed: String {
        switch kind {
        case .toggle: "on/off"
        case .choice(let options): options.map { modelName($0.value) }.joined(separator: "/")
        case .number(let range): "\(range.lowerBound)-\(range.upperBound)"
        case .tags: "tags separated by spaces, with underscores inside a tag"
        }
    }

    static func tags(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }.filter { !$0.isEmpty }
    }

    // MARK: Builders

    static func toggle(_ store: @escaping () -> UserDefaults, _ key: String, default standard: Bool) -> Self {
        .init(kind: .toggle, get: { _ in (store().object(forKey: key) as? Bool ?? standard) ? "on" : "off" },
              set: { _, value in store().set(value == "on", forKey: key) })
    }
    static func toggle(_ path: ReferenceWritableKeyPath<AppEnvironment, Bool>) -> Self {
        .init(kind: .toggle, get: { $0[keyPath: path] ? "on" : "off" }, set: { env, value in env[keyPath: path] = value == "on" })
    }
    static func choice(_ store: @escaping () -> UserDefaults, _ key: String, default standard: String, _ options: [(String, String)]) -> Self {
        .init(kind: .choice(options.map { ($0.0, $0.1) }), get: { _ in store().string(forKey: key) ?? standard },
              set: { _, value in store().set(value, forKey: key) })
    }
    static func intChoice(_ store: @escaping () -> UserDefaults, _ key: String, default standard: Int, _ options: [(Int, String)]) -> Self {
        .init(kind: .choice(options.map { (String($0.0), $0.1) }), get: { _ in String(store().object(forKey: key) as? Int ?? standard) },
              set: { _, value in store().set(Int(value) ?? standard, forKey: key) })
    }
    static func intChoice(_ path: ReferenceWritableKeyPath<AppEnvironment, Int>, _ options: [(Int, String)]) -> Self {
        .init(kind: .choice(options.map { (String($0.0), $0.1) }), get: { String($0[keyPath: path]) },
              set: { env, value in if let number = Int(value) { env[keyPath: path] = number } })
    }
    /// Adds tags to a space-separated list, or removes them from it.
    static func tagList(_ path: ReferenceWritableKeyPath<AppEnvironment, String>, adding: Bool) -> Self {
        .init(kind: .tags, get: { $0[keyPath: path] }, set: { env, value in
            var list = tags(env[keyPath: path])
            for tag in tags(value) {
                if adding { if !list.contains(tag) { list.append(tag) } } else { list.removeAll { $0 == tag } }
            }
            env[keyPath: path] = list.joined(separator: " ")
        })
    }
}

/// One setting or page that search finds, and the assistant changes when it has a control.
struct SettingsItem: Identifiable {
    let id: String
    let titleKey: String
    var detailKey: String? = nil
    let category: SettingsCategory
    /// What the setting does, for the assistant, in English.
    var hint: String? = nil
    /// Extra English words search matches, such as "dark" for the theme.
    var keywords: String = ""
    /// The name the assistant reads, when the screen's name would mislead it.
    var modelTitle: String? = nil
    var control: SettingsControl? = nil
    /// False for a control that only the assistant uses, such as removing a default tag.
    var listed = true

    var title: String { [L10n.text(titleKey), detailKey.map { L10n.text($0) }].compactMap { $0 }.joined(separator: " · ") }
    var englishTitle: String { [titleKey, detailKey].compactMap { $0 }.joined(separator: " · ") }
    var assistantTitle: String { modelTitle ?? englishTitle }
}

/// Every setting search and the assistant know about, for one mode.
enum SettingsCatalog {
    @MainActor static func items(booru: Bool) -> [SettingsItem] {
        let reader = { booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults }
        let comics = { ReaderPreferences.defaults }
        let privacy = { ContentPreferences.defaults }
        let onOff: (Bool) -> String = { $0 ? "on" : "off" }
        let languages: [(String, String)] = [("all", L10n.text("All")), ("korean", L10n.text("Korean")), ("japanese", L10n.text("Japanese")), ("english", L10n.text("English"))]
        var items: [SettingsItem] = []
        func add(_ item: SettingsItem) { items.append(item) }

        // Explore & Search
        if booru {
            add(.init(id: "browse.embeddedBrowser", titleKey: "Use Embedded Browser", category: .browsing, hint: "open the website itself instead of the app's screens",
                      control: .toggle(reader, "booru.useEmbeddedBrowser", default: false)))
        } else {
            add(.init(id: "browse.embeddedBrowser", titleKey: "Use Embedded Browser", category: .browsing, hint: "open the website itself instead of the app's screens",
                      control: .toggle(\.useEmbeddedBrowser)))
            add(.init(id: "browse.informationFirst", titleKey: "Show Work Information Before Reading", category: .browsing, hint: "tapping a work shows its details first instead of opening the viewer",
                      control: .toggle(comics, MangaThumbnailOpening.preferenceKey, default: false)))
        }
        add(.init(id: "browse.thumbnailGestures", titleKey: "Thumbnail Gestures", category: .browsing))
        for gesture in ThumbnailGesture.allCases {
            let choices = gesture.choices(booru: booru)
            add(.init(id: "browse.gesture." + gesture.rawValue, titleKey: "Thumbnail Gestures", detailKey: gesture == .tap ? "Tap" : gesture == .doubleTap ? "Double Tap" : "Touch and Hold",
                      category: .browsing, hint: "what a thumbnail in Explore does on this gesture",
                      control: .choice({ ThumbnailGesture.store(booru: booru) }, gesture.key(booru: booru), default: gesture.standard(booru: booru).rawValue, choices.map { ($0.rawValue, $0.title) }),
                      listed: false))
        }
        if booru {
            add(.init(id: "browse.blacklist", titleKey: "Tag Blacklist", category: .browsing, keywords: "block hide tag filter"))
        } else {
            add(.init(id: "search.languageExceptions", titleKey: "Allow Language Filter Exceptions", category: .browsing, hint: "Game CG, Artist CG and Image Set ignore the language filter",
                      control: .toggle(\.allowsMangaLanguageExceptions)))
            add(.init(id: "search.requireTags", titleKey: "Default Tags", category: .browsing, hint: "add tags that every search and Explore must match", keywords: "filter include",
                      control: .tagList(\.defaultTags, adding: true)))
            add(.init(id: "search.stopRequiringTags", titleKey: "Default Tags", detailKey: "Remove", category: .browsing, hint: "remove tags from the default tags",
                      control: .tagList(\.defaultTags, adding: false), listed: false))
            add(.init(id: "search.hideTags", titleKey: "Default Excluded Tags", category: .browsing, hint: "hide works with these tags or artists from Explore and every search", keywords: "block hide blacklist filter artist",
                      control: .tagList(\.defaultExcludedTags, adding: true)))
            add(.init(id: "search.showHiddenTags", titleKey: "Default Excluded Tags", detailKey: "Remove", category: .browsing, hint: "show works with these tags again",
                      control: .tagList(\.defaultExcludedTags, adding: false), listed: false))
        }
        add(.init(id: "search.rememberHistory", titleKey: "Remember Search History", category: .browsing,
                  control: .toggle(reader, booru ? "booru.rememberHistory" : "search.rememberHistory", default: true)))
        add(.init(id: "search.keepHistory", titleKey: "Keep History", category: .browsing, hint: "days search history is kept, 0 keeps it always",
                  control: .intChoice(reader, "search.retentionDays", default: 0, [(3, L10n.text("3 Days")), (7, L10n.text("7 Days")), (30, L10n.text("30 Days")), (0, L10n.text("Always"))])))
        add(.init(id: "browse.recent", titleKey: booru ? "Recently Opened Images" : "Recently Opened Works", category: .browsing, keywords: "recent history"))
        add(.init(id: "browse.recentInSaved", titleKey: "Show as Folder in Saved", category: .browsing, hint: "show recently opened works as a folder in Saved",
                  control: .init(kind: .toggle, get: { onOff(booru ? $0.recentImages.showsInSaved : $0.recentWorks.showsInSaved) },
                                 set: { env, value in if booru { env.recentImages.setShowsInSaved(value == "on") } else { env.recentWorks.setShowsInSaved(value == "on") } })))

        // Viewer
        if !booru {
            add(.init(id: "reader.resume", titleKey: "When Reopening a Work", category: .viewer,
                      control: .choice(comics, "reader.resumeBehavior", default: ReaderResumeBehavior.ask.rawValue, ReaderResumeBehavior.allCases.map { ($0.rawValue, $0.title) })))
            add(.init(id: "reader.mode", titleKey: "Reading Mode", category: .viewer, hint: "how pages move", keywords: "scroll webtoon vertical",
                      control: {
                          var control = SettingsControl.choice(comics, "reader.mode", default: ReaderMode.horizontal.rawValue, ReaderMode.allCases.map { ($0.rawValue, $0.title) })
                          control.modelNames = [ReaderMode.horizontal.rawValue: "sidewaysPages", ReaderMode.vertical.rawValue: "upDownPages", ReaderMode.continuous.rawValue: "webtoonScroll"]
                          return control
                      }()))
            add(.init(id: "reader.backSwipe", titleKey: "Swipe Right to Go Back", category: .viewer, hint: "continuous scroll only",
                      control: .toggle(comics, "reader.continuousBackSwipe", default: false)))
            add(.init(id: "reader.workSwipe", titleKey: "Swipe Left or Right to Change Works", category: .viewer, hint: "continuous scroll only",
                      control: .toggle(comics, "reader.continuousWorkSwipe", default: false)))
            add(.init(id: "reader.informationSwipe", titleKey: "Swipe Up for Work Information", category: .viewer, hint: "continuous scroll only",
                      control: .toggle(comics, "reader.continuousPreviewSwipe", default: false)))
            add(.init(id: "reader.pages", titleKey: "Pages per View", category: .viewer, hint: "0 is automatic: two pages side by side on wide screens", keywords: "spread two pages",
                      control: .intChoice(comics, ReaderLayout.pagesKey, default: ReaderLayout.automatic, [(ReaderLayout.automatic, L10n.text("Automatic"))] + (1...4).map { ($0, L10n.text("Pages: %@", String($0))) })))
        }
        add(.init(id: "reader.rtl", titleKey: "Read Right to Left", category: .viewer, hint: "manga order", keywords: "manga direction rtl",
                  control: .toggle(reader, "reader.rtl", default: false)))
        add(.init(id: "reader.tapNavigation", titleKey: "Tap the Sides to Turn Pages", category: .viewer,
                  control: .toggle(reader, "reader.tapNavigation", default: true)))
        add(.init(id: "reader.doubleTapZoom", titleKey: "Double Tap to Zoom", category: .viewer,
                  control: .toggle(reader, ReaderPreferences.doubleTapZoomKey, default: true)))
        if booru {
            add(.init(id: "reader.notes", titleKey: "Show Notes on Images", category: .viewer, control: .toggle(reader, "booru.showNotes", default: true)))
            add(.init(id: "reader.original", titleKey: "Load Original Images", category: .viewer, hint: "full-size files, more data", keywords: "quality data",
                      control: .toggle(reader, "booru.original", default: false)))
            add(.init(id: "reader.reducedData", titleKey: "Reduce Image Data Further", category: .viewer, hint: "smaller images, less data", keywords: "data cellular",
                      control: .toggle(reader, "booru.reducedData", default: false)))
        }
        if ReaderTranslationSession.isSupported {
            if !booru {
                add(.init(id: "reader.aiTranslation", titleKey: "AI Translation (Beta)", category: .viewer, hint: "keeps translation on while pages turn", keywords: "translate",
                          control: .toggle(comics, ReaderPreferences.continuousTranslationKey, default: true)))
            }
            add(.init(id: "reader.translationBackground", titleKey: "AI Translation Background", category: .viewer, keywords: "translate color",
                      control: .choice(reader, ReaderTranslationStyle.backgroundKey, default: ReaderTranslationStyle.Background.white.rawValue,
                                       ReaderTranslationStyle.Background.allCases.map { ($0.rawValue, $0.title) })))
        }
        add(.init(id: "reader.bottomMenu", titleKey: "Show Quick Menu at Bottom", category: .viewer, control: .toggle(reader, "reader.bottomMenu", default: false)))
        add(.init(id: "reader.pageNumber", titleKey: "Show Page Number", category: .viewer, control: .toggle(reader, "reader.pageNumber", default: false)))
        if !booru {
            add(.init(id: "reader.versionBanner", titleKey: "Preferred Language Version Banner", category: .viewer,
                      control: .toggle(comics, ReaderPreferences.versionBannerKey, default: true)))
        }
        add(.init(id: "reader.keepAwake", titleKey: "Keep Screen Awake While Reading", category: .viewer, keywords: "sleep lock", control: .toggle(reader, "reader.keepAwake", default: true)))
        add(.init(id: "reader.dimming", titleKey: "Dim Screen", category: .viewer, hint: "percent darker, 0 is off", keywords: "brightness dark night",
                  control: .init(kind: .number(0...65), get: { _ in String(Int(((reader().object(forKey: "reader.dimming") as? Double ?? 0) * 100).rounded())) },
                                 set: { _, value in reader().set(Double(Int(value) ?? 0) / 100, forKey: "reader.dimming") })))
        add(.init(id: "reader.autoAdvance", titleKey: "Auto Advance", category: .viewer, hint: "turns pages by itself", keywords: "slideshow automatic",
                  control: .toggle(reader, "reader.autoAdvance", default: false)))
        add(.init(id: "reader.autoSeconds", titleKey: "Auto Advance", detailKey: "Seconds", category: .viewer, hint: "seconds between pages",
                  control: .init(kind: .number(2...120), get: { _ in String(Int(reader().object(forKey: "reader.autoSeconds") as? Double ?? 10)) },
                                 set: { _, value in reader().set(Double(Int(value) ?? 10), forKey: "reader.autoSeconds") }), listed: false))
        if !booru {
            add(.init(id: "reader.prefetch", titleKey: "Prefetch Pages", category: .viewer, hint: "pages loaded ahead, 0 is off", keywords: "preload data",
                      control: .intChoice(comics, "reader.prefetch", default: 3, [(0, L10n.text("Off")), (2, L10n.text("2 Pages")), (3, L10n.text("3 Pages")), (5, L10n.text("5 Pages"))])))
        }
        add(.init(id: "reader.guide", titleKey: "Reader Guide", category: .viewer, keywords: "help gestures tutorial"))

        // Appearance & Layout
        add(.init(id: "appearance.theme", titleKey: "Appearance", category: .appearance, keywords: "theme dark light mode color",
                  control: .init(kind: .choice(AppTheme.allCases.map { ($0.rawValue, $0.title) }), get: { $0.appTheme.rawValue },
                                 set: { env, value in if let theme = AppTheme(rawValue: value) { env.appTheme = theme } })))
        let columns = [(0, L10n.text("Automatic"))] + (1...5).map { ($0, String($0)) }
        // The model reads column counts as sizes, which "bigger" and "smaller" map to more reliably.
        let sizes = ["0": "automatic", "1": "1 column (largest)", "2": "2 columns (large)", "3": "3 columns (medium)", "4": "4 columns (small)", "5": "5 columns (smallest)"]
        func sized(_ control: SettingsControl) -> SettingsControl { var control = control; control.modelNames = sizes; return control }
        add(.init(id: "appearance.thumbnailSize", titleKey: "Grid Columns", category: .appearance, hint: "how many thumbnails per row", keywords: "size thumbnail bigger smaller", modelTitle: "Thumbnail Size (Grid Columns)",
                  control: sized(.intChoice(\.gridColumns, columns))))
        add(.init(id: "appearance.folderSize", titleKey: "Folder Columns", category: .appearance, hint: "how many folders per row", modelTitle: "Folder Size (Folder Columns)", control: sized(.intChoice(\.folderColumns, columns))))
        add(.init(id: "appearance.noSpacing", titleKey: "Show Without Spacing", category: .appearance, hint: "no gaps between thumbnails", keywords: "padding gap margin",
                  control: .toggle(\.removesGridPadding)))
        if booru {
            add(.init(id: "appearance.fitThumbnails", titleKey: "Fit Entire Thumbnails", category: .appearance, hint: "show whole images instead of cropping them", keywords: "crop",
                      control: .toggle(reader, "booru.fitThumbnails", default: false)))
        } else {
            add(.init(id: "appearance.previewColumns", titleKey: "Preview Columns", category: .appearance, hint: "page preview columns in work information, 0 is twice the grid",
                      control: .intChoice(\.mangaPreviewColumns, [(0, L10n.text("Automatic (2× Grid)"))] + (1...10).map { ($0, String($0)) })))
            add(.init(id: "appearance.previewRows", titleKey: "Preview Rows per Page", category: .appearance,
                      control: .intChoice(\.mangaPreviewRows, (1...10).map { ($0, String($0)) })))
            add(.init(id: "appearance.titles", titleKey: "Show Work Titles", category: .appearance, control: .toggle(\.showsMangaTitles)))
            add(.init(id: "appearance.artists", titleKey: "Show Work Artists", category: .appearance, control: .toggle(\.showsMangaArtists)))
            add(.init(id: "appearance.categories", titleKey: "Show Work Categories", category: .appearance, control: .toggle(\.showsMangaCategories)))
        }

        // Language & Translation
        add(.init(id: "language.app", titleKey: "App Language", category: .language,
                  control: .init(kind: .choice([("system", L10n.text("System Language")), ("en", "English"), ("ko", "한국어"), ("ja", "日本語")]),
                                 get: { $0.appLanguage }, set: { env, value in env.appLanguage = value })))
        if !booru {
            add(.init(id: "language.preferred", titleKey: "Preferred Language", category: .language, hint: "the version of a work the viewer offers",
                      control: .choice(comics, PreferredWorkLanguage.key, default: "system", [("system", L10n.text("System Language"))] + languages.dropFirst())))
            add(.init(id: "language.artistWorks", titleKey: "Artist Works Language", category: .language,
                      control: .choice(comics, ArtistBrowsing.preferenceKey, default: "all", languages)))
            add(.init(id: "language.tagWorks", titleKey: "Tag Works Language", category: .language,
                      control: .choice(comics, TagBrowsing.preferenceKey, default: "all", languages)))
        }
        add(.init(id: "language.translation", titleKey: "Translation Language", category: .language, keywords: "translate"))

        // Library & Storage
        add(.init(id: "library.downloads", titleKey: "Downloads", category: .library, keywords: "download offline"))
        if !booru { add(.init(id: "library.defaultFolder", titleKey: "Default Save Folder", category: .library, keywords: "folder save")) }
        add(.init(id: "library.smartFolders", titleKey: "Smart Folders", category: .library, keywords: "folder rule automatic"))
        add(.init(id: "library.management", titleKey: "Library Management", category: .library, keywords: "backup import export sync icloud"))
        add(.init(id: "library.duplicates", titleKey: "Clean Up Duplicates", category: .library, keywords: "duplicate"))
        add(.init(id: "library.classify", titleKey: "Classify into Folders", category: .library, keywords: "folder organize"))
        add(.init(id: "library.cache", titleKey: booru ? "Clear Image Cache" : "Image Cache", category: .library, keywords: "cache storage space"))

        add(.init(id: "taste", titleKey: "Taste Analysis", category: .taste, keywords: "recommendation"))
        add(.init(id: "addons", titleKey: "Add-ons", category: .addons, keywords: "addon plugin extension"))

        // Start & Safe Mode
        add(.init(id: "start.safeMode", titleKey: "Safe Mode", category: .start, hint: "shows only all-ages images from Safebooru and hides the library", keywords: "safe kids sfw",
                  control: .toggle(\.booruSafeMode)))
        add(.init(id: "start.learning", titleKey: "Open in Learning Mode", category: .start, hint: "the app opens into learning mode",
                  control: .init(kind: .toggle, get: { _ in onOff(StudyMode.shared.startsActive) }, set: { _, value in StudyMode.shared.startsActive = value == "on" })))
        add(.init(id: "start.viewing", titleKey: "Open in Viewing Mode", category: .start, hint: "the app skips the opening scene into the library",
                  control: .init(kind: .toggle, get: { _ in onOff(StudyMode.shared.startsInLibrary) }, set: { _, value in StudyMode.shared.startsInLibrary = value == "on" })))

        // Privacy & Security
        add(.init(id: "privacy.incognito", titleKey: "Incognito Mode", category: .privacy, hint: "opened works and searches are not recorded", keywords: "private history",
                  control: .toggle(privacy, PrivacySettings.incognitoKey, default: false)))
        add(.init(id: "privacy.capture", titleKey: "Hide During Screen Recording", category: .privacy, keywords: "screenshot mirror",
                  control: .init(kind: .toggle, get: { _ in onOff(privacy().bool(forKey: PrivacySettings.captureProtectionKey)) },
                                 set: { _, value in privacy().set(value == "on", forKey: PrivacySettings.captureProtectionKey); ScreenCaptureGuard.shared.update() })))
        add(.init(id: "privacy.dns", titleKey: "Encrypted DNS", category: .privacy, keywords: "network dns",
                  control: .init(kind: .choice(EncryptedDNS.allCases.map { ($0.rawValue, $0.title) }), get: { _ in privacy().string(forKey: PrivacySettings.encryptedDNSKey) ?? EncryptedDNS.off.rawValue },
                                 set: { _, value in privacy().set(value, forKey: PrivacySettings.encryptedDNSKey); EncryptedDNS.applyStored(changed: true) })))
        add(.init(id: "privacy.lock", titleKey: "App Lock", category: .privacy, keywords: "face id passcode"))

        // Help & About
        add(.init(id: "help.keyboard", titleKey: "Keyboard & Mouse", category: .help, keywords: "shortcut"))
        add(.init(id: "help.onboarding", titleKey: "Replay Onboarding", category: .help, keywords: "tutorial"))
        add(.init(id: "help.privacyPolicy", titleKey: "Privacy Policy", category: .help))
        add(.init(id: "help.licenses", titleKey: "Open Source Licenses", category: .help))
        add(.init(id: "help.reset", titleKey: "Reset Settings to Defaults", category: .help, keywords: "reset default"))
        return items
    }

    /// Settings whose title, page or keywords contain every word of the query.
    static func search(_ query: String, in items: [SettingsItem]) -> [SettingsItem] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = items.filter { item in
            guard item.listed else { return false }
            let text = fold([item.title, item.englishTitle, item.category.title, item.category.titleKey, item.keywords].joined(separator: " "))
            // Korean and Japanese are often typed without the spaces a title has.
            let compact = text.replacingOccurrences(of: " ", with: "")
            return words.allSatisfy { text.contains($0) || compact.contains($0) }
        }
        // A title starting with the query first, then one holding it whole, then the rest in page order.
        let phrase = words.joined(separator: " ")
        func rank(_ item: SettingsItem) -> Int {
            let titles = [fold(item.title), fold(item.englishTitle)]
            if titles.contains(where: { $0.hasPrefix(phrase) }) { return 0 }
            return titles.contains { $0.contains(phrase) } ? 1 : 2
        }
        return matches.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
