import SwiftUI

/// The settings row both modes show for privacy and network choices.
struct PrivacySecuritySection: View {
    var body: some View {
        Section {
            NavigationLink { PrivacySecurityView() } label: {
                Label(L10n.text("Privacy & Security"), systemImage: "lock.shield")
            }.accessibilityIdentifier("settings.privacy")
        }
    }
}

struct PrivacySecurityView: View {
    @SwiftUI.AppStorage(PrivacySettings.incognitoKey, store: ContentPreferences.defaults) private var incognito = false
    @SwiftUI.AppStorage(PrivacySettings.captureProtectionKey, store: ContentPreferences.defaults) private var captureProtection = false
    @SwiftUI.AppStorage(PrivacySettings.encryptedDNSKey, store: ContentPreferences.defaults) private var encryptedDNS = EncryptedDNS.off.rawValue

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Incognito Mode"), isOn: $incognito)
                    .accessibilityIdentifier("privacy.incognito")
            } footer: {
                Text(L10n.text("While on, works you open, searches and viewing time aren’t recorded, and nothing is learned for recommendations. Works you save still go to your library."))
            }
            Section {
                Toggle(L10n.text("Hide During Screen Recording"), isOn: $captureProtection)
                    .accessibilityIdentifier("privacy.captureProtection")
            } footer: {
                Text(L10n.text("Covers the app while the screen is being recorded or mirrored. The app switcher always shows the cover instead of your library."))
            }
            if #available(iOS 18.0, *) {
                Section {
                    Text(L10n.text("Touch and hold TEGNAL on the Home Screen, then choose Require Face ID. The app then asks for Face ID or your passcode each time it opens."))
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: {
                    Text(L10n.text("App Lock"))
                }
            }
            Section {
                Picker(L10n.text("Encrypted DNS"), selection: $encryptedDNS) {
                    ForEach(EncryptedDNS.allCases) { Text($0.title).tag($0.rawValue) }
                }.accessibilityIdentifier("privacy.encryptedDNS")
            } header: {
                Text(L10n.text("Network"))
            } footer: {
                Text(L10n.text("Looks up website addresses over an encrypted connection, so the network can’t see or change them. Website checks and the in-app browser use the system’s DNS."))
            }
        }
        .navigationTitle(L10n.text("Privacy & Security"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: encryptedDNS) { _, _ in EncryptedDNS.applyStored(changed: true) }
        .onChange(of: captureProtection) { _, _ in ScreenCaptureGuard.shared.update() }
    }
}
