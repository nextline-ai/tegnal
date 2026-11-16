import SwiftUI

struct BooruBackupView: View {
    @State private var busy = false

    var body: some View {
        Form {
            LibraryMaintenanceLinks(booru: true)
            LibraryBackupSection(busy: $busy)
            Section {
                NavigationLink { ChallengeBackupView() } label: { Label { Text(L10n.text("Challenge Backup and Import")) } icon: { Image(systemName: "dice").foregroundStyle(.purple) } }
                NavigationLink { AnimeBoxesImportView() } label: { Label(L10n.text("Import from Anime Boxes"), systemImage: "shippingbox") }
                    .accessibilityIdentifier("booru.importLink")
                NavigationLink { AnimeBoxesImportView(otherApps: true) } label: { Label(L10n.text("Import from Another Image App"), systemImage: "square.and.arrow.down.on.square") }
                    .accessibilityIdentifier("booru.importOtherApp")
            }.disabled(busy)
            CloudSyncSection()
        }
        .navigationTitle(L10n.text("Library Management"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
