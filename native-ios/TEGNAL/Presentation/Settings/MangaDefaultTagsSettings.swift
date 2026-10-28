import SwiftUI

struct MangaDefaultTagsSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section {
            Toggle(isOn: $env.allowsMangaLanguageExceptions) {
                SettingsHelpLabel("Allow Language Filter Exceptions", help: "Includes Game CG, Artist CG and Image Set even when their language differs from your filter. Turn off to apply the language filter to all works.")
            }
                .accessibilityIdentifier("settings.mangaLanguageExceptions")
            NavigationLink {
                Form {
                    Section {
                        TextField("tag:scenery", text: $env.defaultTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("manga.defaultTags")
                    } header: { SettingsHelpLabel("Default Tags", help: "Adds these tags to every comics search. Separate tags with spaces and use underscores inside a tag.") }
                    Section {
                        TextField("tag:spoilers", text: $env.defaultExcludedTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("manga.defaultExcludedTags")
                    } header: { SettingsHelpLabel("Default Excluded Tags", help: "Hides matching works from every comics search. Enter tags normally; the app adds the minus sign for you.") }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(L10n.text("Default Search Tags")).navigationBarTitleDisplayMode(.inline)
            } label: { Label(L10n.text("Default Search Tags"), systemImage: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("manga.defaultTagsSettings")
        } header: { Text(L10n.text("Search")) }
    }
}
