import SwiftUI
import WebKit

/// One image server's account, in its settings. The person signs in on the server's own page or
/// saves the API key the server's account settings show; the app keeps only that sign-in, in the
/// server's own browser profile and the keychain. In image mode's settings the server's connection
/// and filter rows follow at the bottom of the same section.
struct BooruAccountSection<Rows: View>: View {
    let server: BooruServer
    /// The section's title: the server's name where the section stands for the whole server.
    var header: String?
    @ViewBuilder var rows: () -> Rows
    @Environment(AppEnvironment.self) private var env
    @State private var signingIn = false
    @State private var confirmingSignOut = false
    @State private var canChange = true
    @State private var hasKey = false

    init(server: BooruServer, header: String? = nil, @ViewBuilder rows: @escaping () -> Rows) {
        self.server = server
        self.header = header
        self.rows = rows
    }

    var body: some View {
        let sync = env.booruAccounts
        let identity = sync.identity(server)
        Section {
            Group {
                if let identity {
                    LabeledContent(L10n.text("Website Account"),
                                   value: identity.displayName.isEmpty ? L10n.text("Signed In") : identity.displayName)
                        .accessibilityIdentifier("booru.account.status")
                    if server.engine == .gelbooru {
                        // Gelbooru keeps two kinds of access apart; both are shown, and the website's is used first.
                        LabeledContent(L10n.text("Website Sign-In"), value: L10n.text(canChange ? "Signed In" : "Not Signed In"))
                            .accessibilityIdentifier("booru.account.website")
                    }
                    if server.engine == .gelbooru || server.engine == .danbooru {
                        // Danbooru uses a saved API key first, Gelbooru its website sign-in.
                        LabeledContent(L10n.text("API Key"), value: L10n.text(hasKey ? "Stored" : "Not Saved"))
                            .accessibilityIdentifier("booru.account.apiKey")
                    }
                    if sync.expired.contains(server.id) || !canChange {
                        // An API key that only reads, or a sign-in the website stopped accepting.
                        Button { signingIn = true } label: {
                            Label(L10n.text(canChange ? "Sign In Again" : "Sign In to Website"),
                                  systemImage: canChange ? "exclamationmark.arrow.triangle.2.circlepath" : "person.crop.circle")
                        }
                        .accessibilityIdentifier("booru.account.signInAgain")
                        .appSheet(isPresented: $signingIn, onDismiss: refresh) { BooruSignInView(server: server) }
                    }
                    BooruFavoritesSyncRows(server: server)
                } else {
                    Button { signingIn = true } label: {
                        Label(L10n.text("Sign In to Website"), systemImage: "person.crop.circle")
                    }
                    .accessibilityIdentifier("booru.account.signIn")
                    .appSheet(isPresented: $signingIn, onDismiss: refresh) { BooruSignInView(server: server) }
                }
            }
            .task(id: "\(server.id)-\(identity?.userID ?? 0)-\(identity?.name ?? "")") {
                // An API key saved in the server's settings, or a sign-in kept from the website, counts too.
                await sync.discover(server)
                canChange = await BooruAccountClient.shared.canChange(server)
                hasKey = (try? BooruKeychain.read(serverID: server.id).isEmpty) == false
            }
            rows()
            if identity != nil {
                Button(L10n.text("Sign Out"), role: .destructive) { confirmingSignOut = true }
                    .accessibilityIdentifier("booru.account.signOut")
                    .confirmationDialog(L10n.text("Sign out of this website?"), isPresented: $confirmingSignOut, titleVisibility: .visible) {
                        Button(L10n.text("Sign Out"), role: .destructive) { Task { await sync.signOut(server) } }
                    } message: {
                        Text(L10n.text("Saved images stay in the app. Folders made for favorite groups stay as plain folders."))
                    }
            }
        } header: {
            Text(header ?? L10n.text("Website Account"))
        } footer: {
            if identity == nil && sync.refusedKeys.contains(server.id) {
                Text(L10n.text(server.engine == .gelbooru
                               ? "The website didn't accept the saved account details. In the server's settings, enter the numeric User ID and the API key shown together in your account options on the website."
                               : "The website didn't accept the saved account details. Check the username and API key in the server's settings."))
                    .foregroundStyle(.red)
            } else if server.engine == .gelbooru {
                Text(L10n.text("Gelbooru: an API key only reads your favorites and comments. Adding and removing favorites, voting and commenting need the website sign-in, and a vote can only be up and can't be taken back. With both, the app uses the website sign-in."))
            } else if server.engine == .danbooru {
                Text(L10n.text("Danbooru: with an API key saved in the server's settings, the app uses it for favorites, favorite groups, votes and comments, so the website sign-in isn't needed. Without one, it uses the website sign-in. With both, the app uses the API key."))
            } else {
                Text(L10n.text(server.engine.keepsFavoriteLists
                               ? "Sign in on the website itself, or save your API key in the server's settings, to keep favorites, favorite groups, votes and comments there. The app keeps only the sign-in, on this device, never your password."
                               : "Sign in on the website itself, or save your API key in the server's settings, to keep favorites, votes and comments there. The app keeps only the sign-in, on this device, never your password."))
            }
        }
    }

    /// A sign-in page closed by hand may still have signed the account in.
    private func refresh() {
        let sync = env.booruAccounts, server = server
        Task {
            await sync.discover(server, force: true)
            canChange = await BooruAccountClient.shared.canChange(server)
            hasKey = (try? BooruKeychain.read(serverID: server.id).isEmpty) == false
        }
    }
}

extension BooruAccountSection where Rows == EmptyView {
    init(server: BooruServer, header: String? = nil) {
        self.init(server: server, header: header) { EmptyView() }
    }
}

/// Whether the account's favorites and the app's folders are kept the same, which folder each list
/// has, where images saved in other folders go, and a sync on demand.
private struct BooruFavoritesSyncRows: View {
    let server: BooruServer
    @Environment(AppEnvironment.self) private var env
    @State private var syncing = false
    @State private var failure: String?

    var body: some View {
        let sync = env.booruAccounts
        let state = sync.state(server)
        let names = sync.listNames[server.id] ?? [:]
        Toggle(isOn: Binding(get: { state != nil }, set: { on in
            if on { run { try await sync.setUpSync(server, requested: true) } } else { sync.stop(server) }
        })) {
            SettingsHelpLabel("Sync Favorites with Folders",
                              help: server.engine.keepsFavoriteLists
                                ? "Images you save in the app are kept in your favorites on the website, and favorites you add there come to the app. Each favorite group that holds images becomes a folder of the same name, and the two hold the same images. You can't delete such a folder yourself while you're signed in. Images saved before signing in stay in the app only."
                                : "Images you save in the app are kept in your favorites on the website, and favorites you add there come to the app. Images saved before signing in stay in the app only.")
        }
        .disabled(syncing)
        .accessibilityIdentifier("booru.account.syncFavorites")
        if let state {
            ForEach(state.folders.keys.sorted(), id: \.self) { list in
                if let folder = state.folders[list], let name = env.booru.folders().first(where: { $0.id == folder })?.displayName {
                    LabeledContent(list == BooruAccounts.favoritesList ? L10n.text("Favorites") : names[list] ?? "#\(list)", value: name)
                }
            }
            let free = ([BooruAccounts.favoritesList] + names.keys.sorted()).filter { state.folders[$0] == nil }
            Picker(selection: Binding(get: { state.unassigned.flatMap { free.contains($0) ? $0 : nil } },
                                      set: { sync.setOtherFoldersList($0, server: server) })) {
                Text(L10n.text("Keep in App Only")).tag(Int?.none)
                ForEach(free, id: \.self) { list in
                    Text(list == BooruAccounts.favoritesList ? L10n.text("Favorites") : names[list] ?? "#\(list)").tag(Optional(list))
                }
            } label: {
                SettingsHelpLabel("List for Other Folders",
                                  help: "Images you save in folders that don't stand for a favorite group are added to this list on the website. Keep in App Only leaves them off the website; the website's favorites then come to a folder of their own.")
            }
            .accessibilityIdentifier("booru.account.otherList")
            Button { run { _ = try await sync.sync(server) } } label: {
                HStack {
                    Label(L10n.text("Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncing { ProgressView() }
                }
            }
            .disabled(syncing)
            .accessibilityIdentifier("booru.account.syncNow")
            .alert(L10n.text("Sync Favorites with Folders"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L10n.text("OK"), role: .cancel) {}
            } message: { Text(failure ?? "") }
        } else if syncing {
            HStack { ProgressView(); Text(L10n.text("Reading Favorites…")).foregroundStyle(.secondary) }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        syncing = true
        Task {
            do { try await body() } catch { failure = BooruConnectionMessage.describe(error) }
            syncing = false
        }
    }
}

/// The server's own sign-in page, in the server's browser profile, where a check passed before
/// lets the page through. The sign-in counts once the page shows the account.
struct BooruSignInView: View {
    let server: BooruServer
    @Environment(AppEnvironment.self) private var env
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
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("booru.signIn.retry")
                    }
                } else {
                    VStack(spacing: 0) {
                        if loading { ProgressView(value: progress).progressViewStyle(.linear) }
                        BooruSignInWebView(server: server, loading: $loading, progress: $progress, failure: $failure,
                                           check: { await env.booruAccounts.check(server) }) { identity in
                            let sync = env.booruAccounts
                            Task { await sync.signedIn(server, identity: identity) }
                            dismiss()
                        }
                        .id(attempt)
                    }
                }
            }
            .navigationTitle(L10n.text("Sign In to Website"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
    }
}

private struct BooruSignInWebView: UIViewRepresentable {
    let server: BooruServer
    @Binding var loading: Bool
    @Binding var progress: Double
    @Binding var failure: String?
    /// Asks the server which account its pages are signed in with now.
    let check: () async -> BooruAccountIdentity?
    let signedIn: (BooruAccountIdentity) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BooruBrowserSession.dataStore(for: server)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.accessibilityIdentifier = "booru.signIn.web"
        context.coordinator.attach(view)
        view.load(URLRequest(url: server.engine.signInURL(base: server.baseURL)))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: BooruSignInWebView
        private var watcher: Task<Void, Never>?
        private var observation: NSKeyValueObservation?
        private var done = false
        private var checking = false
        /// Dropped connections are tried again here, a few times, rather than ending the sign-in.
        private var retries = 0
        private var lastRequest: URLRequest?
        init(_ parent: BooruSignInWebView) { self.parent = parent }

        /// Sign-in cookies can arrive without a finished page load, so the page is looked at every second.
        func attach(_ view: WKWebView) {
            observation = view.observe(\.estimatedProgress) { [parent] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in parent.progress = value }
            }
            watcher = Task { [weak self, weak view] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, let view else { return }
                    await self.look(at: view)
                }
            }
        }

        func detach() { watcher?.cancel(); watcher = nil; observation = nil }

        private func look(at view: WKWebView) async {
            guard !done, !checking, !view.isLoading, let url = view.url, BooruWebTransport.sameOrigin(url, parent.server.baseURL) else { return }
            if parent.server.engine == .danbooru {
                // Danbooru names the signed-in account on every page; only then is it asked.
                let user = try? await view.evaluateJavaScript("document.body ? (document.body.dataset.currentUserId || '') : ''") as? String
                guard let user, (Int64(user) ?? 0) > 0 else { return }
            } else {
                let cookies = await view.configuration.websiteDataStore.httpCookieStore.allCookies()
                    .filter { BooruBrowserSession.matches($0, url: parent.server.baseURL) }
                guard BooruAccountParser.gelbooruIdentity(cookies: cookies) != nil || BooruAccountParser.moebooruIdentity(cookies: cookies) != nil else { return }
            }
            checking = true
            defer { checking = false }
            guard let identity = await parent.check(), !done else { return }
            done = true
            detach()
            // The page passed whatever check the website showed; the app's requests use this browser too,
            // so the website doesn't ask for Validate Client again.
            BooruWebTransport.adopt(view, server: parent.server)
            BooruBrowserSession.clearChallenge(for: parent.server)
            NotificationCenter.default.post(name: .booruClientValidated, object: parent.server.id)
            parent.signedIn(identity)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            retries = 0
            Task { await look(at: webView) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error, in: webView) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error, in: webView) }

        private func fail(_ error: Error, in webView: WKWebView) {
            let error = error as NSError
            // A page left for another one, or handed to another frame, is not a failure.
            guard error.code != NSURLErrorCancelled, !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
            let transient = [NSURLErrorSecureConnectionFailed, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost].contains(error.code)
            if transient, retries < 3 {
                retries += 1
                // A form sent again could act twice, so a failed sign-in form starts over from its page.
                let again = lastRequest.flatMap { $0.httpMethod == "POST" ? nil : $0 }
                    ?? URLRequest(url: parent.server.engine.signInURL(base: parent.server.baseURL))
                let delay = retries
                Task { [weak webView] in
                    try? await Task.sleep(for: .milliseconds(700 * delay))
                    webView?.load(again)
                }
                return
            }
            parent.loading = false
            parent.failure = L10n.text("Couldn’t reach the website. Check the connection and try again.")
        }

        /// Secure pages, and the frames a bot check such as Cloudflare's draws itself: the rule the
        /// comics sign-in goes by, which the check lets through. Its frames are often `about:srcdoc`,
        /// `blob:` or `data:`, and turning them away leaves the check, and the sign-in, stuck.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let main = action.targetFrame?.isMainFrame ?? true
            let allowed = ComicsBrowserProfile.allows(url, mainFrame: main)
            if main, allowed { lastRequest = action.request }
            if allowed && action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
            else { decisionHandler(allowed ? .allow : .cancel) }
        }
    }
}

/// The image's score with the account's vote, as a menu when the account can vote.
struct BooruScoreRow: View {
    let server: BooruServer
    let post: BooruPost
    @Environment(AppEnvironment.self) private var env
    @State private var score: Int?
    @State private var vote = BooruVote(score: 0)
    @State private var voting = false
    @State private var failure: String?
    @State private var canChange = false

    var body: some View {
        let identity = env.booruAccounts.identity(server)
        let canVote = identity != nil && server.engine.votesUp && canChange
        let content = LabeledContent(L10n.text("Score")) {
            HStack(spacing: 6) {
                if voting { ProgressView().controlSize(.small) }
                if vote.score > 0 { Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green) }
                if vote.score < 0 { Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.red) }
                Text(String(score ?? post.score)).monospacedDigit()
                if canVote { Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary) }
            }
        }
        Group {
            if canVote, let identity {
                Menu {
                    if vote.score == 0 || !server.engine.showsOwnVote {
                        Button(L10n.text("Vote Up"), systemImage: "hand.thumbsup") { cast(1, identity) }
                        if server.engine.votesDown { Button(L10n.text("Vote Down"), systemImage: "hand.thumbsdown") { cast(-1, identity) } }
                    } else {
                        if vote.score < 0 { Button(L10n.text("Vote Up"), systemImage: "hand.thumbsup") { cast(1, identity) } }
                        if vote.score > 0, server.engine.votesDown { Button(L10n.text("Vote Down"), systemImage: "hand.thumbsdown") { cast(-1, identity) } }
                        Button(L10n.text("Withdraw Vote"), systemImage: "arrow.uturn.backward") { cast(0, identity) }
                    }
                } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .disabled(voting)
                .accessibilityIdentifier("booru.vote")
            } else {
                content
            }
        }
        .task(id: "\(post.id)-\(identity?.userID ?? 0)") {
            score = nil; vote = BooruVote(score: 0)
            canChange = identity != nil ? await BooruAccountClient.shared.canChange(server) : false
            guard let identity, server.engine.showsOwnVote else { return }
            if let found = try? await BooruAccountClient.shared.vote(server, postID: post.postID, account: identity), !Task.isCancelled { vote = found }
        }
        .alert(L10n.text("Unable to Vote"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private func cast(_ value: Int, _ identity: BooruAccountIdentity) {
        voting = true
        Task {
            defer { voting = false }
            do {
                let current = vote
                let updated = try await BooruAccountClient.shared.vote(server, postID: post.postID, score: value, current: current)
                if server.engine.showsOwnVote {
                    vote = (try? await BooruAccountClient.shared.vote(server, postID: post.postID, account: identity)) ?? BooruVote(score: value)
                } else { vote = BooruVote(score: value) }
                score = updated ?? (score ?? post.score) + (value - current.score)
            } catch { failure = (error as? SiteMessage)?.text ?? BooruConnectionMessage.describe(error) }
        }
    }
}

/// The image's comments in its details: the newest few, all of them on demand, and a comment of
/// the account's own when it is signed in.
struct BooruCommentsSection: View {
    let server: BooruServer
    let postID: Int64
    @Environment(AppEnvironment.self) private var env
    @State private var comments: [WorkComment]?
    @State private var failure: String?
    @State private var showsAll = false
    @State private var writing = false
    @State private var attempt = 0
    @State private var canChange = false

    private var provider: BooruCommentProvider { BooruCommentProvider(server: server) }

    var body: some View {
        Section {
            if let comments {
                if comments.isEmpty {
                    Text(L10n.text("No Comments")).foregroundStyle(.secondary)
                } else {
                    ForEach(comments.suffix(3)) { WorkCommentRow(comment: $0, lineLimit: 4) }
                    if comments.count > 3 {
                        Button { showsAll = true } label: {
                            Label(L10n.text("All Comments") + " (\(comments.count))", systemImage: "text.bubble")
                        }
                        .accessibilityIdentifier("booru.comments.all")
                        .appSheet(isPresented: $showsAll) {
                            WorkCommentsView(galleryID: postID, initial: comments, loadsAll: false, provider: provider)
                        }
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
                Button(L10n.text("Try Again")) { self.failure = nil; attempt += 1 }
            } else {
                HStack { ProgressView(); Text(L10n.text("Loading Comments…")).foregroundStyle(.secondary) }
            }
            if env.booruAccounts.identity(server) != nil && canChange {
                Button { writing = true } label: { Label(L10n.text("Write Comment"), systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("booru.comments.write")
                    .appSheet(isPresented: $writing) {
                        WorkCommentComposer(galleryID: postID, provider: provider) { comments = $0 }
                    }
            }
        } header: {
            Text(L10n.text("Comments"))
        }
        .task(id: "\(server.id)-\(postID)-\(attempt)") {
            comments = nil
            canChange = env.booruAccounts.identity(server) != nil ? await BooruAccountClient.shared.canChange(server) : false
            #if DEBUG
            // Offline fixture runs show one comment without asking a website.
            if BooruUITestSupport.enabled {
                comments = [WorkComment(id: 1, author: "sample user", posted: Date(timeIntervalSince1970: 1_790_000_000), score: 3, text: "Lovely colors.")]
                return
            }
            #endif
            do {
                let loaded = try await BooruAccountClient.shared.comments(server, postID: postID)
                if !Task.isCancelled { comments = loaded }
            } catch {
                if !Task.isCancelled { failure = BooruConnectionMessage.describe(error) }
            }
        }
    }
}
