import SwiftUI

struct CloudSyncSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmDisable = false
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { env.sync.enabled }, set: { value in
                if value { env.sync.enabled = true; Task { await env.sync.synchronize(env: env) } }
                else { confirmDisable = true }
            })) {
                SettingsHelpLabel("iCloud Sync", help: "Keeps both libraries, folders and general settings in sync across your devices. Layout, viewer preferences, downloaded media and sign-in details stay on each device.")
            }.accessibilityIdentifier("settings.icloud")
            Text(env.sync.status).font(.footnote).foregroundStyle(.secondary)
            if let bytes = env.sync.documentBytes {
                LabeledContent(L10n.text("This Device’s Sync Data"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.footnote)
            }
            if let bytes = env.sync.cloudBytes, env.sync.cloudDocumentCount > 0 {
                LabeledContent(L10n.text("iCloud Sync Documents"), value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .font(.footnote)
            }
            if env.sync.enabled {
                Button(L10n.text("Sync Now"), systemImage: "arrow.triangle.2.circlepath") { Task { await env.sync.synchronize(env: env) } }
                    .disabled(env.sync.syncing)
            }
        } header: { Text("iCloud") }
        .alert(L10n.text("Turn Off iCloud Sync?"), isPresented: $confirmDisable) {
            Button(L10n.text("Turn Off"), role: .destructive) { env.sync.enabled = false }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Changes on this device will stop syncing. Existing data on this device and in iCloud will be kept. Turning sync on again will merge changes."))
        }
    }
}
