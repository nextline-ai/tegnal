import SwiftUI

/// Bindings resolve to the current mode; the two libraries keep independent preferences.
struct ModeAppearanceSettings: View {
    @SwiftUI.AppStorage("app.resumeAnimation", store: ContentPreferences.defaults) private var resumeAnimation = true
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage("booru.fitThumbnails", store: ReaderPreferences.booruDefaults) private var fitThumbnails = false
    var body: some View {
        @Bindable var env = env
        Section(L10n.text("Appearance")) {
            Picker(L10n.text("Appearance"), selection: $env.appTheme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Toggle(L10n.text("Play Animation When Returning"), isOn: $resumeAnimation)
            columnPicker("Folder Columns", selection: $env.folderColumns, identifier: "settings.folderColumns")
            columnPicker("Grid Columns", selection: $env.gridColumns, identifier: "settings.gridColumns")
            Toggle(isOn: $env.removesGridPadding) {
                SettingsHelpLabel("Show Without Spacing", help: "Removes the gaps and outer margins around artwork and folder thumbnails.")
            }.accessibilityIdentifier("settings.noGridPadding")
            if env.mode == .booru {
                Toggle(isOn: $fitThumbnails) {
                    SettingsHelpLabel("Fit Entire Thumbnails", help: "Shows the whole image inside each thumbnail. When off, thumbnails fill the card and may crop the edges.")
                }
            }
            if env.mode == .manga {
                HStack {
                    SettingsHelpLabel("Preview Columns", help: "Automatic shows twice as many columns as the artwork grid. Choose a number to keep the preview layout fixed.")
                    Spacer()
                    Picker(L10n.text("Preview Columns"), selection: $env.mangaPreviewColumns) {
                        Text(L10n.text("Automatic (2× Grid)")).tag(0)
                        ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                    }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier("settings.previewColumns")
                }
                Picker(L10n.text("Preview Rows per Page"), selection: $env.mangaPreviewRows) {
                    ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.previewRows")
                Toggle(L10n.text("Show Work Titles"), isOn: $env.showsMangaTitles).accessibilityIdentifier("settings.showMangaTitles")
                Toggle(L10n.text("Show Work Artists"), isOn: $env.showsMangaArtists).accessibilityIdentifier("settings.showMangaArtists")
            }
        }
    }
    private func columnPicker(_ title: String, selection: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHelpLabel(title, help: "Automatic fits the columns to the screen width. Choose a number to keep the layout fixed.").font(.subheadline)
            Picker(L10n.text(title), selection: selection) {
                Text(L10n.text("Automatic")).tag(0)
                ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}
