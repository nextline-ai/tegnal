import SwiftUI
import WebKit

/// The same developer identity and support destinations in both library modes.
struct DeveloperInfoSection: View {
    private let website = URL(string: "https://nextline.work")!
    private let community = URL(string: "https://discord.gg/vUTGZNMaMB")!

    var body: some View {
        Section {
            HStack {
                Spacer(minLength: 0)
                DeveloperLogo().frame(width: 230, height: 64)
                    .accessibilityLabel("NextLine")
                    .accessibilityIdentifier("developer.logo")
                Spacer(minLength: 0)
            }.padding(.vertical, 8)
            LabeledContent(L10n.text("Developer"), value: "NextLine")
            Link(destination: website) {
                HStack(spacing: 12) {
                    Label(L10n.text("Website"), systemImage: "globe")
                    Spacer(minLength: 8)
                    Text("nextline.work")
                    Image(systemName: "arrow.up.right").font(.caption)
                }
            }.accessibilityIdentifier("developer.website")
            Link(destination: URL(string: "mailto:contact@nextline.work")!) {
                HStack {
                    Label(L10n.text("Email"), systemImage: "envelope")
                    Spacer()
                    Text("contact@nextline.work").foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("developer.email")
            VStack(spacing: 10) {
                developerButton("Discord", destination: community, identifier: "developer.community")
                developerButton("GitHub", destination: URL(string: "https://github.com/nextline-ai/tegnal")!, identifier: "developer.github")
            }.padding(.vertical, 8)

        } header: {
            Text(L10n.text("Developer"))
        }
    }
    private func developerButton(_ service: String, destination: URL, identifier: String) -> some View {
        Link(destination: destination) {
            Image("Developer" + service + "_" + (L10n.language == "ko" ? "kr" : "en"))
                .resizable().scaledToFit().frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
            .accessibilityLabel(service == "Discord" ? L10n.text("Community & Bug Reports") + " · Discord" : L10n.text("View on GitHub"))
            .accessibilityIdentifier(identifier)
    }
}

/// A compact native invitation, separate from the developer section's large buttons.
struct DiscordInvitationBanner: View {
    @Environment(AppEnvironment.self) private var env
    private let discordColor = Color(red: 88 / 255, green: 101 / 255, blue: 242 / 255)
    var body: some View {
        if env.discordInvitationVisible {
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://discord.gg/vUTGZNMaMB")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.body).foregroundStyle(.white)
                            .frame(width: 24)
                        Text(L10n.text("Join us on Discord")).font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .accessibilityIdentifier("discord.invitation.join")
                Button { env.dismissDiscordInvitation() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 28, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.borderless).accessibilityLabel(L10n.text("Close"))
                    .accessibilityIdentifier("discord.invitation.close")
            }.accessibilityIdentifier("discord.invitation")
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 12))
                .listRowBackground(discordColor)
                .onAppear { env.recordDiscordInvitationDisplay() }
        }
    }
}


private struct DeveloperLogo: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator {
        var renderedScheme: ColorScheme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.renderedScheme != colorScheme else { return }
        if let url = Bundle.main.url(forResource: "nextline-logo", withExtension: "svg"), let svg = try? String(contentsOf: url, encoding: .utf8) {
            // Trim the square artboard's empty margins for display; preserve the bundled SVG unchanged.
            let artwork = svg.replacingOccurrences(of: "viewBox=\"0 0 1024 1024\"", with: "viewBox=\"210 440 600 144\"")
            let textColor = colorScheme == .dark ? "#fff" : "#000"
            view.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\"><style>html,body{margin:0;background:transparent}svg{width:100%;height:64px}svg .cls-1{fill:\(textColor)}</style>" + artwork, baseURL: nil)
            context.coordinator.renderedScheme = colorScheme
        }
    }
}
