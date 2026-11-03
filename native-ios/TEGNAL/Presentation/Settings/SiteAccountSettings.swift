import SwiftUI
import WebKit

/// Shown for websites that use accounts. The person signs in on the website
/// itself; the app keeps only the identity cookies it hands back.
struct SiteAccountSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var signingIn = false
    @State private var confirmingSignOut = false
    @State private var importTask: Task<Void, Never>?
    @State private var importMessage: String?

    var body: some View {
        @Bindable var env = env
        if env.siteAccountSignedIn || MangaUrls.usesAccount {
            Section {
                if env.siteAccountSignedIn {
                    LabeledContent(L10n.text("Website Account"), value: L10n.text("Signed In"))
                        .accessibilityIdentifier("settings.siteAccount.status")
                    Toggle(isOn: $env.syncsAccountFavorites) {
                        SettingsHelpLabel("Sync Bookmarks with Account Favorites",
                                          help: "Bookmarking a work also adds it to your favorites on the website, and removing the bookmark removes it there.")
                    }.accessibilityIdentifier("settings.siteAccount.syncFavorites")
                    Button {
                        importTask = Task { await importFavorites() }
                    } label: {
                        HStack {
                            Label(L10n.text("Import Account Favorites"), systemImage: "square.and.arrow.down")
                            Spacer()
                            if importTask != nil { ProgressView() }
                        }
                    }.disabled(importTask != nil).accessibilityIdentifier("settings.siteAccount.import")
                    .alert(L10n.text("Import Account Favorites"), isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                        Button(L10n.text("OK"), role: .cancel) { }
                    } message: { Text(importMessage ?? "") }
                    Button(L10n.text("Sign Out"), role: .destructive) { confirmingSignOut = true }
                        .accessibilityIdentifier("settings.siteAccount.signOut")
                        .confirmationDialog(L10n.text("Sign out of this website?"), isPresented: $confirmingSignOut, titleVisibility: .visible) {
                            Button(L10n.text("Sign Out"), role: .destructive) { env.signOutOfSite() }
                        }
                } else {
                    Button { signingIn = true } label: {
                        Label(L10n.text("Sign In to Website"), systemImage: "person.crop.circle")
                    }.disabled(MangaUrls.signInURL == nil).accessibilityIdentifier("settings.siteAccount.signIn")
                    // Presented from the row: a list section cannot present a sheet.
                    .appSheet(isPresented: $signingIn) { SiteSignInView { env.siteSignInFinished() } }
                }
            } header: {
                Text(L10n.text("Website Account"))
            } footer: {
                Text(L10n.text("Some websites show more works, or keep favorites, for signed-in accounts. Create an account on the website itself. The app keeps only the sign-in in this device's keychain, never your password."))
            }
            .onDisappear { importTask?.cancel() }
        }
    }

    private func importFavorites() async {
        defer { importTask = nil }
        do {
            let added = try await env.importAccountFavorites()
            importMessage = added == 0 ? L10n.text("Every account favorite is already bookmarked.")
                : L10n.text("Bookmarked %@ works from your account favorites.", String(added))
        } catch {
            if !Task.isCancelled { importMessage = ContentError.message(error) }
        }
    }
}

/// The website's own sign-in page in a private browser session.
struct SiteSignInView: View {
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView {
                        Label(L10n.text("Unable to Load"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(failure)
                    } actions: {
                        Button(L10n.text("Try Again")) { self.failure = nil; loading = true; attempt += 1 }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("site.signIn.retry")
                    }
                } else if let url = MangaUrls.signInURL {
                    SiteSignInWebView(url: url, loading: $loading, failure: $failure) { cookies in
                        guard SiteAccount.signIn(with: cookies) else { return }
                        finished()
                        dismiss()
                    }
                    .id(attempt)
                    .overlay { if loading { ProgressView().controlSize(.large) } }
                } else {
                    ContentUnavailableView(L10n.text("Unable to Load"), systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text(L10n.text("Open a few works on the website first, then try signing in again.")))
                }
            }
            .navigationTitle(L10n.text("Sign In to Website"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
    }
}

private struct SiteSignInWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var failure: String?
    let signedIn: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "site.signIn.web"
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) { }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SiteSignInWebView
        init(_ parent: SiteSignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [parent] cookies in
                DispatchQueue.main.async { parent.signedIn(cookies) }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

        private func fail(_ error: Error) {
            parent.loading = false
            // A page left for another one is not a failure.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.failure = ContentError.message(error)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = action.request.url?.scheme
            decisionHandler(scheme == "https" || action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
