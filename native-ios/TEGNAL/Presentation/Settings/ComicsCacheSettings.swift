import SwiftUI

/// How much room comics pages take on this device, how much they may take, and which works
/// open from another connected website.
struct ComicsCacheSettingsView: View {
    @State private var used: Int?
    @State private var megabytes = ComicsPageDiskCache.configuredMegabytes
    @State private var confirmClear = false
    @State private var confirmForget = false
    @State private var remembered = WorkSiteMemory.shared.count

    var body: some View {
        List {
            Section {
                LabeledContent(L10n.text("In Use")) {
                    if let used { Text(Self.size(used)) } else { ProgressView() }
                }.accessibilityIdentifier("settings.cache.used")
                Picker(L10n.text("Maximum Size"), selection: $megabytes) {
                    ForEach(ComicsPageDiskCache.choices, id: \.self) { value in
                        Text(Self.size(value * 1024 * 1024)).tag(value)
                    }
                }
                .accessibilityIdentifier("settings.cache.limit")
                .onChange(of: megabytes) { _, value in
                    Task {
                        await ComicsPageDiskCache.shared.setMegabytes(value)
                        await reload()
                    }
                }
                Button(L10n.text("Clear Image Cache"), role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("settings.cache.clear")
            } header: {
                Text(L10n.text("Viewer and Preview Images"))
            } footer: {
                Text(L10n.text("Pages and previews you’ve viewed are kept so they open without downloading again. When the cache is full, the least recently viewed images are removed first. Saved works and their covers are not affected."))
            }
            Section {
                LabeledContent(L10n.text("Works Opened Elsewhere"), value: String(remembered))
                    .accessibilityIdentifier("settings.cache.remembered")
                Button(L10n.text("Forget Where Works Opened")) { confirmForget = true }
                    .disabled(remembered == 0)
                    .accessibilityIdentifier("settings.cache.forgetSites")
            } header: {
                Text(L10n.text("Other Websites"))
            } footer: {
                Text(L10n.text("When the checked website no longer has a work, the app opens it from another connected website and opens it there first next time. Forgetting this tries the checked website first again."))
            }
        }
        .navigationTitle(L10n.text("Image Cache"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .alert(L10n.text("Clear Image Cache?"), isPresented: $confirmClear) {
            Button(L10n.text("Clear Image Cache"), role: .destructive) {
                Task {
                    await ComicsPageDiskCache.shared.clear()
                    await reload()
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Saved works are kept. Images will be downloaded again when needed.")) }
        .confirmationDialog(L10n.text("Forget Where Works Opened"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button(L10n.text("Forget"), role: .destructive) {
                WorkSiteMemory.shared.removeAll()
                remembered = 0
            }
        }
    }

    private func reload() async {
        used = await ComicsPageDiskCache.shared.usedBytes()
        remembered = WorkSiteMemory.shared.count
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
