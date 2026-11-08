import SwiftUI
import Translation

struct LanguageSettingsSection: View {
    var booru = false
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(ArtistBrowsing.preferenceKey, store: ReaderPreferences.defaults) private var artistLanguage = "all"
    @SwiftUI.AppStorage(TagBrowsing.preferenceKey, store: ReaderPreferences.defaults) private var tagLanguage = "all"
    var body: some View {
        @Bindable var env = env
        Section(L10n.text("Language")) {
            Picker(L10n.text("App Language"), selection: $env.appLanguage) {
                Text(L10n.text("System Language")).tag("system")
                Text("English").tag("en")
                Text("한국어").tag("ko")
                Text("日本語").tag("ja")
            }.accessibilityIdentifier("settings.appLanguage")
            if !booru {
                languagePicker("Artist Works Language", help: Self.artistHelp, selection: $artistLanguage, identifier: "settings.artistLanguage")
                languagePicker("Tag Works Language", help: Self.tagHelp, selection: $tagLanguage, identifier: "settings.tagLanguage")
            }
            NavigationLink { TranslationLanguageSettings(booru: booru) } label: {
                Label(L10n.text("Translation Language"), systemImage: "character.bubble")
            }.accessibilityIdentifier("settings.translationLanguage")
        }
    }

    static let artistHelp = "The language works start in when you open an artist, such as from a work's artist or a search for one artist. Changing the language there also changes this setting."
    static let tagHelp = "The language works start in when you open a single tag, such as from a work's tags. Changing the language there also changes this setting. Searches with several words keep All."

    private func languagePicker(_ title: String, help: String, selection: Binding<String>, identifier: String) -> some View {
        HStack {
            SettingsHelpLabel(title, help: help)
            Spacer()
            Picker(L10n.text(title), selection: selection) {
                Text(L10n.text("All")).tag("all")
                Text(L10n.text("Korean")).tag("korean")
                Text(L10n.text("Japanese")).tag("japanese")
                Text(L10n.text("English")).tag("english")
            }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier(identifier)
        }
    }
}

enum ReaderTranslationLanguage {
    static func preference(booru: Bool) -> String {
        (booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults).string(forKey: "reader.translationLanguage") ?? "system"
    }
    static func resolved(_ value: String) -> String { value == "system" ? L10n.systemLanguage : value }
    static func name(_ identifier: String) -> String {
        Locale(identifier: L10n.language).localizedString(forIdentifier: identifier) ?? identifier
    }
}

struct TranslationLanguageSettings: View {
    @SwiftUI.AppStorage private var language: String
    @State private var languages: [String] = []
    init(booru: Bool) {
        _language = SwiftUI.AppStorage(wrappedValue: "system", "reader.translationLanguage", store: booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
    }
    var body: some View {
        List {
            Section {
                HStack {
                    option("system", title: L10n.text("System Language"))
                    SettingsInfoButton(title: "Translation Language", message: "Uses your device’s language unless you choose another language below. Comics and Image modes remember separate choices.")
                }
            }
            if #available(iOS 18.0, *) {
                Section(L10n.text("Choose a Language")) {
                    ForEach(languages, id: \.self) { option($0, title: ReaderTranslationLanguage.name($0)) }
                }
            }
        }
        .navigationTitle(L10n.text("Translation Language")).navigationBarTitleDisplayMode(.inline)
        .task {
            if #available(iOS 18.0, *) {
                languages = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
                    .sorted { ReaderTranslationLanguage.name($0).localizedStandardCompare(ReaderTranslationLanguage.name($1)) == .orderedAscending }
            }
        }
    }
    private func option(_ value: String, title: String) -> some View {
        Button { language = value } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if language == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }.accessibilityIdentifier("translation.language." + value).accessibilityAddTraits(language == value ? [.isSelected] : [])
    }
}
