import SwiftUI

struct MangaDefaultTagsSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section {
            Toggle(L10n.text("Allow Language Filter Exceptions"), isOn: $env.allowsMangaLanguageExceptions)
                .accessibilityIdentifier("settings.mangaLanguageExceptions")
            Text(L10n.text("Include Game CG, Artist CG and Image Set regardless of the selected language. Off applies the language filter to every type."))
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                Form {
                    Section(L10n.text("Default Tags")) {
                        TextField("tag:scenery", text: $env.defaultTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("manga.defaultTags")
                    }
                    Section(L10n.text("Default Excluded Tags")) {
                        TextField("tag:spoilers", text: $env.defaultExcludedTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("manga.defaultExcludedTags")
                    }
                    Section {
                        Text(L10n.text("Applied to every native manga search, including artist pages. Separate tags with spaces; use underscores within a tag. Excluded tags are automatically prefixed with a minus sign."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(L10n.text("Default Search Tags")).navigationBarTitleDisplayMode(.inline)
            } label: { Label(L10n.text("Default Search Tags"), systemImage: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("manga.defaultTagsSettings")
        } header: { Text(L10n.text("Search")) }
    }
}
