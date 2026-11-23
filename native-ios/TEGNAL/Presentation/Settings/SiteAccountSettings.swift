import SwiftUI
import WebKit
import Combine

/// One connected website's account, in that website's own settings. The person signs in on the
/// website itself or pastes the cookies of a browser where they are signed in; the app keeps only
/// the sign-in cookies it is handed, for this website alone.
struct SiteAccountSection: View {
    /// The connected website, as the list of websites names it.
    let site: String
    @Environment(AppEnvironment.self) private var env
    @State private var signingIn = false
    @State private var pastingCookies = false
    @State private var verifying = false
    @State private var confirmingSignOut = false
    @State private var importTask: Task<Void, Never>?
    @State private var importMessage: String?
    @State private var revision = 0
    @State private var allowance: (used: Int, limit: Int)?
    @State private var profiles: [SiteSettingsProfile] = []

    /// What was learned about this website, read in its own scope.
    private func scoped<T>(_ body: () -> T) -> T { SiteScope.$site.withValue(site, operation: body) }
    private var isChecked: Bool { site == env.mangaSiteAddress }
    private var host: String { scoped { MangaUrls.configuredHost } }
    private var signedIn: Bool { _ = revision; _ = env.siteAccountSignedIn; return SiteAccount.isSignedIn(host: host) }
    private var refused: Bool { _ = revision; return SiteAccount.refusesAccess(host: host) }
    private var usesSiteSession: Bool { scoped { MangaUrls.usesSiteSession } }
    private var favoritesNotSynced: Bool { _ = env.favoriteFoldersRevision; return SiteFavoriteFolders.shared.state(for: site) == nil }
    private var keyed: Bool { scoped { MangaUrls.hasResolvedBackend && MangaUrls.backend == .keyed } }
    /// Whether the account keeps favorites the app can sync with its folders.
    private var keepsFavorites: Bool { scoped { MangaUrls.hasResolvedBackend && MangaUrls.backend != .indexed } }
    /// Websites whose account this one can use, as two websites of one forum share theirs.
    private var sources: [String] { _ = revision; return usesSiteSession ? [] : SiteAccount.accountSources(excluding: host) }
    /// Whether accounts matter here: a website that uses them, or one not recognized yet that may be members-only.
    private var showsAccount: Bool {
        _ = revision
        return signedIn || scoped { MangaUrls.usesAccount || !MangaUrls.hasResolvedBackend || MangaUrls.backend != .indexed }
    }

    var body: some View {
        @Bindable var env = env
        Section {
            if showsAccount {
                if signedIn {
                    LabeledContent(L10n.text("Website Account"), value: L10n.text(refused ? "Signed In, No Access Yet" : "Signed In"))
                        .accessibilityIdentifier("settings.siteAccount.status")
                    if isChecked, let allowance {
                        LabeledContent(L10n.text("Image Allowance")) {
                            Text("\(allowance.used.formatted()) / \(allowance.limit.formatted())").monospacedDigit()
                        }.accessibilityIdentifier("settings.siteAccount.allowance")
                    }
                    if scoped({ MangaUrls.requiresSignIn }) || refused || SiteAccount.savedCookieNames(host: host).contains(SiteAccount.accessCookie) {
                        Button {
                            SiteAccount.forget(SiteAccount.accessCookie, host: host)
                            finished()
                        } label: { Label(L10n.text("Refresh Website Access"), systemImage: "arrow.triangle.2.circlepath") }
                            .accessibilityIdentifier("settings.siteAccount.refreshAccess")
                    }
                    if keepsFavorites { SiteFavoritesSyncRows(site: site) }
                    if isChecked && keyed {
                        Toggle(isOn: Binding(get: { _ = revision; return KeyedCatalogSource.loadsOriginals(host: host) },
                                             set: { KeyedCatalogSource.setLoadsOriginals($0, host: host); revision += 1 })) {
                            SettingsHelpLabel("Load Original Images",
                                              help: "Loads each page’s original file instead of the resized one. The website may charge GP for originals; a page it won’t send is shown resized.")
                        }.accessibilityIdentifier("settings.siteAccount.originals")
                        if profiles.count > 1 {
                            Picker(selection: Binding(get: { profiles.first(where: \.selected)?.id ?? profiles[0].id }, set: { useProfile($0) })) {
                                ForEach(profiles) { Text($0.name).tag($0.id) }
                            } label: {
                                SettingsHelpLabel("Settings Profile",
                                                  help: "Which of your website settings profiles the app reads with, such as one made for the app. Create profiles in the website’s settings.")
                            }.accessibilityIdentifier("settings.siteAccount.profile")
                        }
                        // With the sync on, the categories' folders already hold the favorites.
                        if favoritesNotSynced { Menu {
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
                        } message: { Text(importMessage ?? "") } }
                    }
                    Button(L10n.text("Sign Out"), role: .destructive) { confirmingSignOut = true }
                        .accessibilityIdentifier("settings.siteAccount.signOut")
                        .confirmationDialog(L10n.text("Sign out of this website?"), isPresented: $confirmingSignOut, titleVisibility: .visible) {
                            Button(L10n.text("Sign Out"), role: .destructive) { env.signOutOfSite(site); revision += 1 }
                        }
                } else {
                    Button { signingIn = true } label: {
                        Label(L10n.text("Sign In to Website"), systemImage: "person.crop.circle")
                    }.disabled(scoped { MangaUrls.signInURL } == nil).accessibilityIdentifier("settings.siteAccount.signIn")
                    // Presented from the row: a list section cannot present a sheet.
                    .appSheet(isPresented: $signingIn) { SiteSignInView(site: site) { finished() } }
                    ForEach(sources, id: \.self) { source in
                        Button {
                            if SiteAccount.useAccount(from: source, on: host) {
                                scoped { MangaUrls.markUsesAccount(site: MangaUrls.home) }
                                finished()
                            }
                        } label: { Label(L10n.text("Use the Account from %@", source), systemImage: "person.crop.circle.badge.checkmark") }
                            .accessibilityIdentifier("settings.siteAccount.useFrom.\(source)")
                    }
                    if !usesSiteSession {
                        Button { pastingCookies = true } label: {
                            Label(L10n.text("Sign In with Cookies"), systemImage: "doc.on.clipboard")
                        }.accessibilityIdentifier("settings.siteAccount.cookies")
                        .appSheet(isPresented: $pastingCookies) { SiteCookieSignInView(site: site) { revision += 1 } }
                    }
                }
            }
            Button { verifying = true } label: {
                LabeledContent {
                    if SiteClearance.hasClearance(forHost: host) { Text(L10n.text("Done")) }
                } label: { Label(L10n.text("Validate Client"), systemImage: "checkmark.shield") }
            }.accessibilityIdentifier("settings.siteAccount.validate")
            .appSheet(isPresented: $verifying) { SiteVerificationView(host: host) { revision += 1 } }
        } header: {
            Text(L10n.text(showsAccount ? "Website Account" : "Website"))
        } footer: {
            if showsAccount && refused {
                // Why the website keeps a signed-in account out, and when that may change.
                Text(ContentError.accessDenied.localizedDescription)
            } else if showsAccount {
                Text(L10n.text("Some websites show more works, or keep favorites, for signed-in accounts. Create an account on the website itself. The app keeps only the sign-in in this device's keychain, never your password. If a website keeps asking you to check you’re not a bot, use Validate Client.")
                     + "\n\n" + L10n.text("Each website keeps its own account. Two websites of one forum can share one: sign in on either, then use its account on the other."))
            }
        }
        .onDisappear { importTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: SiteClearance.didChange).receive(on: RunLoop.main)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: SiteAccount.didChange).receive(on: RunLoop.main)) { _ in revision += 1 }
        .task(id: "\(signedIn)-\(isChecked)-\(keyed)") {
            guard isChecked, signedIn, keyed else { allowance = nil; return }
            allowance = (try? await MangaContentSource.shared.imageAllowance()) ?? nil
        }
        .task(id: "\(site)-\(signedIn)") {
            // A website added a moment ago names its sign-in page on its own pages, and signing in or out
            // forgets what was read; read a page again so the rows that depend on it show right away.
            guard !scoped({ MangaUrls.hasResolvedBackend }) else { return }
            await SiteScope.$site.withValue(site) { await MangaUrls.resolveBackend() }
            revision += 1
        }
        .task(id: "\(signedIn)-\(isChecked)-\(keyed)-profiles") {
            guard isChecked, signedIn, keyed else { profiles = []; return }
            profiles = (try? await MangaContentSource.shared.settingsProfiles()) ?? []
        }
    }

    private func finished() {
        env.siteSignInFinished(site: site)
        revision += 1
    }

    private func useProfile(_ id: Int) {
        profiles = profiles.map { SiteSettingsProfile(id: $0.id, name: $0.name, selected: $0.id == id) }
        Task {
            try? await MangaContentSource.shared.useSettingsProfile(id)
            profiles = (try? await MangaContentSource.shared.settingsProfiles()) ?? profiles
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

/// A connected website's own settings: which website it is, and its account.
struct ComicSiteSettingsView: View {
    let site: String
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        List {
            Section {
                LabeledContent(L10n.text("Website Address"), value: site)
                if site != env.mangaSiteAddress {
                    Button { env.switchComicsSite(to: site) } label: { Label(L10n.text("Use This Website"), systemImage: "checkmark.circle") }
                        .accessibilityIdentifier("settings.site.use")
                }
            }
            SiteAccountSection(site: site)
        }
        .navigationTitle(L10n.text("Website Settings")).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.siteSettings")
    }
}

/// Signs in with the cookies of a browser where the person is already signed in.
struct SiteCookieSignInView: View {
    /// The connected website signing in; nil is the checked one.
    var site: String? = nil
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
        let site = site ?? env.mangaSiteAddress
        guard SiteAccount.signIn(pasted: pasted, host: SiteScope.$site.withValue(site) { MangaUrls.configuredHost }) else { return }
        SiteScope.$site.withValue(site) { MangaUrls.markUsesAccount(site: MangaUrls.home) }
        env.siteSignInFinished(site: site)
        succeeded = await env.checkSiteAccount(site: site)
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
    /// The connected website signing in; nil is the checked one.
    var site: String? = nil
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
                } else if let url = scoped({ MangaUrls.signInURL }) {
                    let host = scoped { MangaUrls.configuredHost }
                    let session = scoped { MangaUrls.usesSiteSession } ? host : nil
                    VStack(spacing: 0) {
                        if loading { ProgressView(value: progress).progressViewStyle(.linear) }
                        SiteSignInWebView(url: url, session: session, loading: $loading, progress: $progress, failure: $failure) { cookies in
                            if let session {
                                guard SiteAccount.signIn(session: cookies, host: session) else { return false }
                                // Requests carry the account from now on, where works also open without one.
                                scoped { MangaUrls.markUsesAccount(site: MangaUrls.home, signInPage: url) }
                            } else {
                                guard SiteAccount.signIn(with: cookies, host: host) else { return false }
                                scoped { MangaUrls.markUsesAccount(site: MangaUrls.home) }
                            }
                            finished()
                            dismiss()
                            return true
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

    /// What was learned about the website signing in, read in its own scope.
    private func scoped<T>(_ body: () -> T) -> T { SiteScope.$site.withValue(site ?? ComicSites.active, operation: body) }
}

private struct SiteSignInWebView: UIViewRepresentable {
    let url: URL
    /// For a site that signs in on its own pages: its host. Nil for the forum identity.
    let session: String?
    @Binding var loading: Bool
    @Binding var progress: Double
    @Binding var failure: String?
    /// Keeps the sign-in the cookies hold; true once kept.
    let signedIn: ([HTTPCookie]) -> Bool

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
            _ = parent.signedIn(cookies)
        }

        func detach() { watcher?.cancel(); watcher = nil; observation = nil }

        private func report(_ cookies: [HTTPCookie]) {
            guard !done, cookies.contains(where: { SiteAccount.isIdentity($0.name) }) else { return }
            if parent.signedIn(cookies) { done = true; detach() }
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

/// Whether a website's favorites categories and their folders are kept the same, which folder each
/// category has, the category works in other folders are kept in, and a sync on demand.
private struct SiteFavoritesSyncRows: View {
    @Environment(AppEnvironment.self) private var env
    let site: String
    @State private var categories: [FavoriteCategory] = []
    @State private var syncing = false
    @State private var failure: String?

    private var state: SiteFavoriteFolders.State? { _ = env.favoriteFoldersRevision; return SiteFavoriteFolders.shared.state(for: site) }
    private func name(_ category: Int) -> String {
        if let name = categories.first(where: { $0.id == category })?.name { return name }
        return state?.exclusive == false ? "fav:\(category)" : L10n.text("Category %@", String(category + 1))
    }
    /// Each linked folder's name by its identity, with the folder list read once rather than once a category.
    private func folderNames(_ state: SiteFavoriteFolders.State) -> [String: String] {
        let folders = (try? env.database.listFolders()) ?? []
        let names = Dictionary(folders.compactMap { folder in folder.id.map { ($0, folder.displayName) } }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for identity in state.folders.values {
            if let id = try? env.database.folderID(identity: identity), let name = names[id] { result[identity] = name }
        }
        return result
    }

    var body: some View {
        let state = state
        Toggle(isOn: Binding(get: { state != nil }, set: { on in
            if on { run { await env.setUpSiteFavorites(site: site, requested: true) } }
            else { env.stopSyncingSiteFavorites(site: site) }
        })) {
            SettingsHelpLabel("Sync Favorites with Folders",
                              help: state?.exclusive == false
                                ? "Each favorites list on the website that holds works becomes a folder of the same name, and the two hold the same works; when a list is emptied, its folder goes too. You can't delete such a folder yourself while you're signed in. Works you save in other folders go to the list chosen below, or stay in the app only."
                                : "Each favorites category on the website that holds works becomes a folder of the same name, and the two hold the same works; when a category is emptied, its folder goes too. You can't delete such a folder yourself while you're signed in. Works you save in other folders go to the category chosen below, or stay in the app only.")
        }.disabled(syncing).accessibilityIdentifier("settings.siteAccount.syncFavorites")
        .task(id: "\(site)-\(state != nil)") {
            guard state != nil, categories.isEmpty else { return }
            categories = (try? await SiteContent.for(site).favoriteCategories()) ?? []
        }
        if let state {
            let names = folderNames(state)
            ForEach(state.folders.keys.sorted(), id: \.self) { category in
                if let identity = state.folders[category], let folder = names[identity] {
                    LabeledContent(name(category), value: folder)
                }
            }
            let free = categories.map(\.id).filter { state.folders[$0] == nil }
            if !categories.isEmpty {
                Picker(selection: Binding(get: { state.unassigned.flatMap { free.contains($0) ? $0 : nil } },
                                          set: { env.setUnassignedFavoriteCategory($0, site: site) })) {
                    Text(L10n.text("Keep in App Only")).tag(Int?.none)
                    ForEach(free, id: \.self) { Text(name($0)).tag(Optional($0)) }
                } label: {
                    if state.exclusive == false {
                        SettingsHelpLabel("List for Other Folders",
                                          help: "Works you save in folders that are not a favorites list are added to this list on the website. Keep in App Only leaves them off the website, so they never mix with favorites in a list you use yourself.")
                    } else {
                        SettingsHelpLabel("Category for Other Folders",
                                          help: "Works you save in folders that are not a favorites category are added to this category on the website. Keep in App Only leaves them off the website, so they never mix with favorites in a category you use yourself. With every category in use, this is the only choice.")
                    }
                }.accessibilityIdentifier("settings.siteAccount.otherCategory")
            }
            Button { run { _ = try await env.syncSiteFavorites(site: site) } } label: {
                HStack {
                    Label(L10n.text("Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncing { ProgressView() }
                }
            }.disabled(syncing).accessibilityIdentifier("settings.siteAccount.syncNow")
            .alert(L10n.text("Sync Favorites with Folders"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        syncing = true
        Task {
            do { try await body() } catch { failure = ContentError.message(error) }
            syncing = false
        }
    }
}


/// Asked the first time a signed-in website's or image server's favorites can be synced, before
/// anything changes: bring them into the library, keep the library as it is and sync only later
/// changes, or don't sync.
struct SiteFavoritesSetupSheet: View {
    let host: String
    let favoriteCount: Int
    let bringInDetail: String
    let newFolders: [String]
    let answer: (SiteFavoritesSetupChoice) -> Void

    /// A comics website's favorites.
    init(offer: SiteFavoritesSetupOffer, env: AppEnvironment) {
        let lists = !offer.favorites.exclusive
        var parts: [String] = []
        if offer.newWorks > 0 { parts.append(L10n.text("Adds %@ works your library doesn't have.", offer.newWorks.formatted())) }
        if offer.filedWorks > 0 {
            parts.append(L10n.text(lists ? "Also puts %@ saved works in folders named after the website's lists." : "Also puts %@ saved works in folders named after the website's categories.", offer.filedWorks.formatted()))
        }
        parts.append(L10n.text(lists ? "From then on, each list and its folder hold the same works." : "From then on, each category and its folder hold the same works."))
        self.init(host: offer.host, favoriteCount: offer.favoriteCount, bringInDetail: parts.joined(separator: " "), newFolders: offer.newFolders,
                  answer: { env.answerSiteFavoritesSetup($0) })
    }

    /// An image server's favorites.
    init(offer: BooruFavoritesSetupOffer, sync: BooruAccountSync) {
        var parts: [String] = []
        if offer.newImages > 0 { parts.append(L10n.text("Adds %@ images your library doesn't have.", offer.newImages.formatted())) }
        if offer.filedImages > 0 { parts.append(L10n.text("Also puts %@ saved images in folders named after the website's favorite groups.", offer.filedImages.formatted())) }
        parts.append(L10n.text("From then on, your favorites and these folders hold the same images."))
        self.init(host: offer.serverName, favoriteCount: offer.favoriteCount, bringInDetail: parts.joined(separator: " "), newFolders: offer.newFolders,
                  answer: { choice in Task { await sync.answerSetup(choice) } })
    }

    init(host: String, favoriteCount: Int, bringInDetail: String, newFolders: [String], answer: @escaping (SiteFavoritesSetupChoice) -> Void) {
        self.host = host
        self.favoriteCount = favoriteCount
        self.bringInDetail = bringInDetail
        self.newFolders = newFolders
        self.answer = answer
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.text("%@ has %@ favorites. Choose how they start syncing with your folders.", host, favoriteCount.formatted()))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    choice(.bringIn, title: "Bring In Favorites", systemImage: "square.and.arrow.down", detail: bringInDetail)
                } footer: {
                    if !newFolders.isEmpty { Text(L10n.text("New folders: %@", newFolders.joined(separator: ", "))) }
                }
                Section {
                    choice(.keepLibrary, title: "Keep My Library As It Is", systemImage: "lock",
                           detail: L10n.text("Nothing changes now, in the app or on the website. Favorites already on the website are left alone; only what you add or remove from now on is synced. To bring them in later, turn the sync off and on again in the website's settings."))
                }
                Section {
                    choice(.off, title: "Don't Sync", systemImage: "xmark.circle",
                           detail: L10n.text("The app and the website stay apart. You can turn the sync on later in the website's settings."))
                }
            }
            .navigationTitle(L10n.text("Website Favorites")).navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("favoritesSetup.sheet")
    }

    private func choice(_ choice: SiteFavoritesSetupChoice, title: String, systemImage: String, detail: String) -> some View {
        Button { answer(choice) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(choice == .off ? Color.secondary : Color.accentColor).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(title)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favoritesSetup.\(choice)")
    }
}
