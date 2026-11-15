import SwiftUI
import WebKit
import Combine

/// Shown for websites that use accounts, or that have not been recognized yet and may be
/// members-only. The person signs in on the website itself or pastes the cookies of a browser where
/// they are signed in; the app keeps only the sign-in cookies it is handed.
struct SiteAccountSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var signingIn = false
    @State private var pastingCookies = false
    @State private var verifying = false
    @State private var confirmingSignOut = false
    @State private var importTask: Task<Void, Never>?
    @State private var importMessage: String?
    @State private var clearanceRevision = 0
    @State private var categories: [FavoriteCategory] = []
    @State private var allowance: (used: Int, limit: Int)?

    private var host: String { MangaUrls.configuredHost }
    private var usesAccountHere: Bool { MangaUrls.usesAccount }
    private var isShown: Bool {
        guard !env.comicSites.isEmpty, !host.isEmpty else { return false }
        _ = clearanceRevision
        return env.siteAccountSignedIn || usesAccountHere || !MangaUrls.hasResolvedBackend
            || MangaUrls.backend == .keyed || SiteClearance.hasClearance(forHost: host)
    }

    var body: some View {
        @Bindable var env = env
        if isShown {
            Section {
                if env.siteAccountSignedIn {
                    LabeledContent(L10n.text("Website Account"), value: L10n.text("Signed In"))
                        .accessibilityIdentifier("settings.siteAccount.status")
                    if let allowance {
                        LabeledContent(L10n.text("Image Allowance")) {
                            Text("\(allowance.used.formatted()) / \(allowance.limit.formatted())").monospacedDigit()
                        }.accessibilityIdentifier("settings.siteAccount.allowance")
                    }
                    if !usesAccountHere && !MangaUrls.usesSiteSession {
                        Button {
                            MangaUrls.markUsesAccount(site: MangaUrls.home)
                            env.siteSignInFinished()
                        } label: { Label(L10n.text("Use This Account on This Website"), systemImage: "person.crop.circle.badge.checkmark") }
                            .accessibilityIdentifier("settings.siteAccount.useHere")
                    } else if MangaUrls.requiresSignIn || SiteAccount.savedCookieNames(host: host).contains(SiteAccount.accessCookie) {
                        Button {
                            SiteAccount.forget(SiteAccount.accessCookie, host: host)
                            env.siteSignInFinished()
                        } label: { Label(L10n.text("Refresh Website Access"), systemImage: "arrow.triangle.2.circlepath") }
                            .accessibilityIdentifier("settings.siteAccount.refreshAccess")
                    }
                    if MangaUrls.backend == .keyed && MangaUrls.hasResolvedBackend {
                        Toggle(isOn: $env.syncsAccountFavorites) {
                            SettingsHelpLabel("Sync Bookmarks with Account Favorites",
                                              help: "Bookmarking a work also adds it to your favorites on the website, and removing the bookmark removes it there.")
                        }.accessibilityIdentifier("settings.siteAccount.syncFavorites")
                        if env.syncsAccountFavorites {
                            Picker(L10n.text("Favorites Category"), selection: $env.accountFavoriteCategory) {
                                ForEach(0..<10, id: \.self) { number in
                                    Text(categories.first { $0.id == number }?.name ?? L10n.text("Category %@", String(number + 1))).tag(number)
                                }
                            }.accessibilityIdentifier("settings.siteAccount.category")
                        }
                        Menu {
                            Button(L10n.text("Into the Default Folder"), systemImage: "tray.and.arrow.down") {
                                importTask = Task { await importFavorites(byCategory: false) }
                            }
                            Button(L10n.text("Into a Folder for Each Category"), systemImage: "folder.badge.plus") {
                                importTask = Task { await importFavorites(byCategory: true) }
                            }
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
                    }
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
                    if !MangaUrls.usesSiteSession {
                        Button { pastingCookies = true } label: {
                            Label(L10n.text("Sign In with Cookies"), systemImage: "doc.on.clipboard")
                        }.accessibilityIdentifier("settings.siteAccount.cookies")
                        .appSheet(isPresented: $pastingCookies) { SiteCookieSignInView() }
                    }
                }
                Button { verifying = true } label: {
                    LabeledContent {
                        if SiteClearance.hasClearance(forHost: host) { Text(L10n.text("Done")) }
                    } label: { Label(L10n.text("Validate Client"), systemImage: "checkmark.shield") }
                }.accessibilityIdentifier("settings.siteAccount.validate")
                .appSheet(isPresented: $verifying) { SiteVerificationView(host: host) { clearanceRevision += 1 } }
            } header: {
                Text(L10n.text("Website Account"))
            } footer: {
                Text(L10n.text("Some websites show more works, or keep favorites, for signed-in accounts. Create an account on the website itself. The app keeps only the sign-in in this device's keychain, never your password. If a website keeps asking you to check you’re not a bot, use Validate Client."))
            }
            .onDisappear { importTask?.cancel() }
            .onReceive(NotificationCenter.default.publisher(for: SiteClearance.didChange).receive(on: RunLoop.main)) { _ in clearanceRevision += 1 }
            .task(id: env.siteAccountSignedIn) {
                guard env.siteAccountSignedIn, MangaUrls.backend == .keyed, MangaUrls.hasResolvedBackend else { allowance = nil; return }
                allowance = (try? await MangaContentSource.shared.imageAllowance()) ?? nil
            }
            .task(id: env.syncsAccountFavorites) {
                guard env.syncsAccountFavorites, categories.isEmpty else { return }
                categories = (try? await MangaContentSource.shared.favoriteCategories()) ?? []
            }
        }
    }

    private func importFavorites(byCategory: Bool) async {
        defer { importTask = nil }
        do {
            let added = try await env.importAccountFavorites(intoCategoryFolders: byCategory)
            importMessage = added == 0 ? L10n.text("Every account favorite is already bookmarked.")
                : L10n.text("Bookmarked %@ works from your account favorites.", String(added))
        } catch {
            if !Task.isCancelled { importMessage = ContentError.message(error) }
        }
    }
}

/// Signs in with the cookies of a browser where the person is already signed in.
struct SiteCookieSignInView: View {
    var finished: () -> Void = {}
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var memberID = ""
    @State private var passHash = ""
    @State private var access = ""
    @State private var extras: [String: String] = [:]
    @State private var checking = false
    @State private var result: String?
    @State private var succeeded = false

    private var pasted: SiteAccount.PastedCookies {
        var cookies = SiteAccount.PastedCookies()
        let id = memberID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = passHash.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { cookies.identity["ipb_member_id"] = id }
        if !hash.isEmpty { cookies.identity["ipb_pass_hash"] = hash }
        cookies.site = extras
        let value = access.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !SiteAccount.isPlaceholder(name: SiteAccount.accessCookie, value: value) { cookies.site[SiteAccount.accessCookie] = value }
        else { cookies.site[SiteAccount.accessCookie] = nil }
        return cookies
    }

    private var isValid: Bool {
        (Int(memberID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            && passHash.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^[0-9a-fA-F]{16,64}$"#, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in fill(from: strings.joined(separator: "\n")) }
                    }
                    .accessibilityIdentifier("site.cookies.paste")
                } footer: {
                    Text(L10n.text("Copy the cookies from a browser where you’re signed in to the website, such as a cookie list or a shortcut’s output, then paste them here."))
                }
                Section {
                    TextField(L10n.text("Member ID"), text: $memberID)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("site.cookies.member")
                    SecureField(L10n.text("Pass Hash"), text: $passHash)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("site.cookies.hash")
                    SecureField(L10n.text("Access Cookie (Optional)"), text: $access)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("site.cookies.access")
                } header: {
                    Text(L10n.text("Cookies"))
                } footer: {
                    Text(L10n.text("The values of the cookies named “ipb_member_id”, “ipb_pass_hash” and, for members-only websites, “igneous”. They’re kept only in this device’s keychain and sent only to the connected website."))
                }
                if !extras.isEmpty {
                    Section {
                        ForEach(extras.keys.sorted(), id: \.self) { name in
                            LabeledContent(name, value: L10n.text("Included"))
                        }
                    } header: { Text(L10n.text("Other Cookies")) }
                }
                if let result {
                    Section {
                        Label(result, systemImage: succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(succeeded ? Color.green : Color.orange)
                            .accessibilityIdentifier("site.cookies.result")
                    }
                }
            }
            .navigationTitle(L10n.text("Sign In with Cookies"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking { ProgressView() }
                    else {
                        Button(L10n.text("Sign In")) { Task { await signIn() } }
                            .disabled(!isValid).accessibilityIdentifier("site.cookies.signIn")
                    }
                }
            }
            .interactiveDismissDisabled(checking)
        }
    }

    private func fill(from text: String) {
        let found = SiteAccount.parseCookies(text)
        if let id = found.identity.first(where: { $0.key.hasSuffix("_member_id") })?.value { memberID = id }
        if let hash = found.identity.first(where: { $0.key.hasSuffix("_pass_hash") })?.value { passHash = hash }
        if let value = found.site[SiteAccount.accessCookie] { access = value }
        extras = found.site.filter { $0.key != SiteAccount.accessCookie }
        result = found.isComplete ? nil : L10n.text("No sign-in cookies were found in what you pasted.")
        succeeded = false
    }

    private func signIn() async {
        checking = true
        defer { checking = false }
        guard SiteAccount.signIn(pasted: pasted, host: MangaUrls.configuredHost) else { return }
        MangaUrls.markUsesAccount(site: MangaUrls.home)
        env.siteSignInFinished()
        succeeded = await env.checkSiteAccount()
        if succeeded {
            finished()
            dismiss()
        } else {
            result = L10n.text("Signed in, but the website still didn’t show your account. Check the cookies, including the access cookie, or try again later.")
        }
    }
}

/// The website's own sign-in page in the website's browser profile, where a bot check passed
/// before lets the page through.
struct SiteSignInView: View {
    let finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var progress = 0.0
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
                    let session = MangaUrls.usesSiteSession ? MangaUrls.configuredHost : nil
                    VStack(spacing: 0) {
                        if loading { ProgressView(value: progress).progressViewStyle(.linear) }
                        SiteSignInWebView(url: url, session: session, loading: $loading, progress: $progress, failure: $failure) { cookies in
                            if let session {
                                guard SiteAccount.signIn(session: cookies, host: session) else { return }
                            } else {
                                guard SiteAccount.signIn(with: cookies) else { return }
                                MangaUrls.markUsesAccount(site: MangaUrls.home)
                            }
                            finished()
                            dismiss()
                        }
                        .id(attempt)
                    }
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
    /// For a site that signs in on its own pages: its host. Nil for the forum identity.
    let session: String?
    @Binding var loading: Bool
    @Binding var progress: Double
    @Binding var failure: String?
    let signedIn: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let host = url.host?.lowercased() ?? MangaUrls.configuredHost
        let view = WKWebView(frame: .zero, configuration: ComicsBrowserProfile.configuration(forHost: host))
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.accessibilityIdentifier = "site.signIn.web"
        context.coordinator.attach(view, host: host)
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) { }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: SiteSignInWebView
        private var watcher: Task<Void, Never>?
        private var observation: NSKeyValueObservation?
        private var done = false
        /// A site's own sign-in counts once its sign-in form has been shown and then left.
        private var sawSignInForm = false
        init(_ parent: SiteSignInWebView) { self.parent = parent }

        /// Sign-in cookies can arrive without a finished page load, and a bot check can redirect
        /// many times, so the cookie store itself is checked every half second.
        func attach(_ view: WKWebView, host: String) {
            observation = view.observe(\.estimatedProgress) { [parent] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in parent.progress = value }
            }
            watcher = Task { [weak self, weak view] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, let view, !self.done else { return }
                    let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
                    if cookies.contains(where: { $0.name == "cf_clearance" }), let host = view.url?.host {
                        await ComicsBrowserProfile.adoptClearance(from: view, host: host)
                    }
                    if self.parent.session != nil { await self.checkSession(view, cookies: cookies) }
                    else if cookies.contains(where: { SiteAccount.isIdentity($0.name) }) { self.report(cookies) }
                }
            }
        }

        private func checkSession(_ view: WKWebView, cookies: [HTTPCookie]) async {
            guard let session = parent.session, let host = view.url?.host?.lowercased(),
                  SiteClearance.domain(of: host) == SiteClearance.domain(of: session), !view.isLoading,
                  let asks = try? await view.evaluateJavaScript("!!document.querySelector('input[type=password]')") as? Bool else { return }
            if asks { sawSignInForm = true; return }
            guard sawSignInForm, !done else { return }
            done = true
            detach()
            parent.signedIn(cookies)
        }

        func detach() { watcher?.cancel(); watcher = nil; observation = nil }

        private func report(_ cookies: [HTTPCookie]) {
            guard !done, cookies.contains(where: { SiteAccount.isIdentity($0.name) }) else { return }
            parent.signedIn(cookies)
            if SiteAccount.isSignedIn { done = true; detach() }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                if parent.session != nil { await checkSession(webView, cookies: cookies) } else { report(cookies) }
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
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let main = action.targetFrame?.isMainFrame ?? true
            let allowed = ComicsBrowserProfile.allows(url, mainFrame: main)
            if allowed && action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
            else { decisionHandler(allowed ? .allow : .cancel) }
        }
    }
}
