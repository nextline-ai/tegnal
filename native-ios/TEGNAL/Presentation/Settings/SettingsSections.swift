import SwiftUI

struct ReaderSettingsSection: View {
    let booru: Bool
    @Binding var isPresented: Bool
    var body: some View {
        Section {
            Button { isPresented = true } label: {
                HStack {
                    Label { Text(L10n.text("Viewer Detail Settings")).foregroundStyle(.primary) } icon: { Image(systemName: "slider.horizontal.3") }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }.accessibilityIdentifier(booru ? "booru.readerSettings" : "settings.reader")
        } header: { Text(L10n.text("Viewer")) }
    }
}

struct SettingsSupportSection: View {
    @Binding var showOnboarding: Bool
    var booru = false
    var body: some View {
        Section(L10n.text("Help & Privacy")) {
            NavigationLink { KeyboardShortcutsView() } label: {
                Label(L10n.text("Keyboard & Mouse"), systemImage: "keyboard")
            }.accessibilityIdentifier("settings.shortcuts")
            Button(L10n.text("Replay Onboarding"), systemImage: "sparkles") { showOnboarding = true }
                .accessibilityIdentifier("settings.onboarding")
            NavigationLink { PrivacyPolicyView() } label: {
                Label(L10n.text("Privacy Policy"), systemImage: "hand.raised")
            }.accessibilityIdentifier("settings.privacy")
            NavigationLink { AcknowledgmentsView() } label: {
                Label(L10n.text("Open Source Licenses"), systemImage: "doc.text")
            }
            LabeledContent(L10n.text("Version"), value: version)
            SettingsResetButton(booru: booru)
        }
    }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(policy).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Link(L10n.text("View Online"), destination: URL(string: "https://github.com/nextline-ai/tegnal/blob/main/docs/privacy-policy.md")!)
                Link("contact@nextline.work", destination: URL(string: "mailto:contact@nextline.work")!)
            }.padding(20)
        }.navigationTitle(L10n.text("Privacy Policy")).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings.privacyPolicy")
    }
    private var policy: String {
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt", subdirectory: nil, localization: L10n.language),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return L10n.text("Unable to load privacy policy.") }
        return text
    }
}

/// Reports are explicitly composed and sent by the user, never submitted automatically.
struct ContentReportView: View {
    let page: URL
    var body: some View {
        List {
            Section {
                Text(L10n.text("Include what is wrong with this content. Your mail app opens a draft containing the page address; nothing is sent until you send it."))
                Link(L10n.text("Report by Email"), destination: mailURL)
                    .accessibilityIdentifier("content.reportEmail")
                Link(L10n.text("Open on Website"), destination: page)
                Text(page.absoluteString).font(.footnote).textSelection(.enabled)
            } footer: {
                Text(L10n.text("NextLine can investigate app behavior. The source website controls its posts; use its reporting tools to request removal there."))
            }
            Section { Text("contact@nextline.work").textSelection(.enabled) }
        }.navigationTitle(L10n.text("Report Content")).navigationBarTitleDisplayMode(.inline)
    }
    private var mailURL: URL {
        var url = URLComponents(string: "mailto:contact@nextline.work")!
        url.queryItems = [.init(name: "subject", value: "TEGNAL — Content report"), .init(name: "body", value: page.absoluteString + "\n\n")]
        return url.url!
    }
}

private struct AcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            Text(license).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.navigationTitle(L10n.text("Open Source Licenses")).navigationBarTitleDisplayMode(.inline)
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "Acknowledgments", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "GRDB.swift" }
        return text
    }
}

struct BooruSafeModeSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section {
            Toggle(isOn: $env.booruSafeMode) {
                SettingsHelpLabel("Safe Mode", help: "Adds one rating tag to image searches. You can change or remove it in your search. Comics Mode is unavailable while this is on because some comics websites do not support rating filters.")
            }
                .accessibilityIdentifier("booru.safeMode")
            if env.booruSafeMode {
                Picker(L10n.text("Age Guide"), selection: $env.booruSafeRating) {
                    ForEach(BooruSafeRating.allCases) { rating in
                        Text(rating.title).tag(rating)
                    }
                }.accessibilityIdentifier("booru.safeRating")
                LabeledContent(L10n.text("Default Search Tag"), value: env.booruSafeRating.tag)
            }
        } header: { Text(L10n.text("Safe Mode")) }
    }
}

/// Optional help stays beside its setting instead of adding a paragraph to every row.
struct SettingsHelpLabel: View {
    let title: String
    let help: String
    var symbol: String? = nil
    init(_ title: String, help: String, symbol: String? = nil) {
        self.title = title; self.help = help; self.symbol = symbol
    }
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Label(L10n.text(title), systemImage: symbol) }
            else { Text(L10n.text(title)) }
            SettingsInfoButton(title: title, message: help)
        }
    }
}

struct SettingsInfoButton: View {
    let title: String
    let message: String
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "info.circle").font(.body).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.borderless)
            .accessibilityLabel(L10n.text("About %@", L10n.text(title)))
            .accessibilityIdentifier("settings.help." + title)
            .alert(L10n.text(title), isPresented: $presented) {
                Button(L10n.text("Done"), role: .cancel) {}
            } message: { Text(L10n.text(message)) }
    }
}

struct SettingsResetButton: View {
    var booru = false
    var viewerOnly = false
    @Environment(AppEnvironment.self) private var env
    @State private var confirming = false
    var body: some View {
        Button(L10n.text("Reset Settings to Defaults"), role: .destructive) { confirming = true }
            .accessibilityIdentifier(viewerOnly ? "reader.settings.reset" : "settings.reset")
            .confirmationDialog(L10n.text("Reset Settings to Defaults?"), isPresented: $confirming, titleVisibility: .visible) {
                Button(L10n.text("Reset"), role: .destructive) {
                    if viewerOnly { ReaderPreferenceReset.reset(booru: booru) }
                    else { env.resetModeSettings(booru: booru) }
                }
            } message: {
                Text(L10n.text(viewerOnly ? "Resets this mode’s viewer options. Saved works and reading progress are kept." : "Resets this mode’s appearance, browsing and viewer options. Libraries, website connections, sign-in details and iCloud settings are kept."))
            }
    }
}

enum ReaderPreferenceReset {
    static let keys = ["reader.resumeBehavior", "reader.pagesPerSpread", "reader.autoAdvance", "reader.autoSeconds", "reader.mode", "reader.rtl", "reader.bottomMenu", "reader.pageNumber", "reader.keepAwake", "reader.prefetch", "reader.dimming", "reader.tapNavigation", "reader.continuousPreviewSwipe", "reader.continuousWorkSwipe", "reader.continuousBackSwipe", "reader.helpHidden", "reader.translationLanguage"]
    static func reset(booru: Bool, defaults: UserDefaults? = nil) {
        let store = defaults ?? (booru ? ReaderPreferences.booruDefaults : ReaderPreferences.defaults)
        for key in keys + (booru ? ["booru.original", "booru.reducedData", "booru.showNotes"] : []) { store.removeObject(forKey: key) }
    }
}
