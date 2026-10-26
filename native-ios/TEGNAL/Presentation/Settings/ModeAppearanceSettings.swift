import SwiftUI

/// Bindings resolve to the current mode; the two libraries keep independent preferences.
struct ModeAppearanceSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section(L10n.text("Appearance")) {
            Picker(L10n.text("Appearance"), selection: $env.appTheme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            columnPicker("Folder Columns", selection: $env.folderColumns, identifier: "settings.folderColumns")
            columnPicker("Grid Columns", selection: $env.gridColumns, identifier: "settings.gridColumns")
            Toggle(L10n.text("Show Without Spacing"), isOn: $env.removesGridPadding).accessibilityIdentifier("settings.noGridPadding")
            if env.mode == .manga {
                Picker(L10n.text("Preview Columns"), selection: $env.mangaPreviewColumns) {
                    Text(L10n.text("Automatic (2× Grid)")).tag(0)
                    ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("settings.previewColumns")
                Text(L10n.text("Automatic uses twice the artwork grid’s column count for page previews."))
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle(L10n.text("Show Work Titles"), isOn: $env.showsMangaTitles).accessibilityIdentifier("settings.showMangaTitles")
                Toggle(L10n.text("Show Work Artists"), isOn: $env.showsMangaArtists).accessibilityIdentifier("settings.showMangaArtists")
            }
            Text(L10n.text("Spacing and text scale with thumbnail size. Show Without Spacing removes grid margins, gaps and card padding."))
                .font(.footnote).foregroundStyle(.secondary)
            Text(L10n.text("Automatic adjusts to the window width. Folder and artwork layouts are saved separately on this device."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func columnPicker(_ title: String, selection: Binding<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.subheadline)
            Picker(L10n.text(title), selection: selection) {
                Text(L10n.text("Automatic")).tag(0)
                ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier(identifier)
        }.padding(.vertical, 4)
    }
}
