import SwiftUI
import WebKit

extension Notification.Name { static let comicsClientValidated = Notification.Name("comicsClientValidated") }

/// A comics website's bot check, passed in the website's own browser profile. The cookies it
/// hands out are kept with this browser's identity, and the app's requests to the website use both.
struct SiteVerificationView: View {
    let host: String
    var finished: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var model: SiteVerificationModel
    @State private var confirmReset = false

    init(host: String, finished: @escaping () -> Void = {}) {
        self.host = host
        self.finished = finished
        let start = ContentTransport.challengedPage(forHost: host) ?? URL(string: "https://\(host)/")!
        _model = State(initialValue: SiteVerificationModel(host: host, startURL: start))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.address?.host ?? host, systemImage: model.verified ? "checkmark.shield" : "lock.shield")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(model.verified ? Color.green : Color.primary)
                    Text(L10n.text(model.verified ? "The check is done. The app uses it for this website until the website asks again."
                                                  : "Finish any check the website shows. The app keeps the result for this website."))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("site.verify.status")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                if model.stalled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Verification is taking longer than expected. Reload, or reset this website’s cookies and try again."))
                            .font(.footnote)
                        HStack {
                            Button(L10n.text("Reload")) { model.reload() }
                            Button(L10n.text("Reset Cookies"), role: .destructive) { confirmReset = true }
                        }.font(.footnote)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.loading { ProgressView(value: model.progress).progressViewStyle(.linear) }
                SiteVerificationWebView(view: model.webView)
                    .overlay {
                        if let error = model.error {
                            ContentFailureView(message: error) { model.reload() }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(uiColor: .systemBackground))
                        }
                    }
            }
            .navigationTitle(L10n.text("Validate Client")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("Reload"), systemImage: "arrow.clockwise") { model.reload() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }.accessibilityIdentifier("site.verify.done")
                }
            }
            .confirmationDialog(L10n.text("Reset Cookies?"), isPresented: $confirmReset, titleVisibility: .visible) {
                Button(L10n.text("Reset Cookies"), role: .destructive) {
                    Task { await ComicsBrowserProfile.reset(host: host); model.reload() }
                }
            } message: { Text(L10n.text("This website’s check and the browser data kept for it are removed. Your account sign-in in the app is kept.")) }
            .task { model.begin() }
            .onDisappear {
                model.stop()
                Task { @MainActor in
                    if await model.capture() || model.verified {
                        ContentTransport.clearChallenge(forHost: host)
                        if !MangaUrls.hasResolvedBackend { MangaUrls.resetResolvedBackend() }
                        NotificationCenter.default.post(name: .comicsClientValidated, object: host)
                    }
                    finished()
                }
            }
        }
    }
}

@MainActor @Observable
final class SiteVerificationModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let host: String
    let startURL: URL
    let webView: WKWebView
    var address: URL?
    var loading = false
    var progress = 0.0
    var error: String?
    var stalled = false
    var verified = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    init(host: String, startURL: URL) {
        self.host = host
        self.startURL = startURL
        webView = WKWebView(frame: .zero, configuration: ComicsBrowserProfile.configuration(forHost: host))
        if #available(iOS 26.0, *) { webView.scrollView.topEdgeEffect.isHidden = true }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "site.verify.web"
        progressObservation = webView.observe(\.estimatedProgress) { [weak self] view, _ in
            let value = view.estimatedProgress
            Task { @MainActor in self?.progress = value }
        }
    }

    func begin() {
        guard webView.url == nil else { return }
        reload(startURL)
    }

    func reload(_ url: URL? = nil) {
        error = nil; stalled = false; loading = true
        #if DEBUG
        if ContentUITestSupport.enabled {
            webView.loadHTMLString("<html><meta name='viewport' content='width=device-width'><body><h2>Client verification</h2></body></html>",
                                   baseURL: URL(string: "https://\(host)/"))
            return
        }
        #endif
        webView.load(URLRequest(url: url ?? webView.url ?? startURL))
        watch()
    }

    func stop() { monitor?.cancel(); monitor = nil }

    /// Looks for a passed check every second; neither page loads nor cookie notifications are
    /// dependable signals that the check let the browser through.
    private func watch() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            let begun = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let checking = await self.showsCheck()
                if !checking, await self.capture() {
                    self.verified = true
                    self.stalled = false
                }
                if checking, Date().timeIntervalSince(begun) > 25 { self.stalled = true }
            }
        }
    }

    @discardableResult
    func capture() async -> Bool {
        guard await ComicsBrowserProfile.adoptClearance(from: webView, host: host) else { return false }
        return true
    }

    private func showsCheck() async -> Bool {
        let result = try? await webView.evaluateJavaScript("""
            (() => !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage, .cf-turnstile')
                || /^(just a moment|checking your browser|attention required)/i.test(document.title))()
            """)
        return result as? Bool ?? false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; address = webView.url }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading = false; error = L10n.text("Unable to Load") }

    private func failed(_ error: Error) {
        loading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.error = ContentError.message(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let main = action.targetFrame?.isMainFrame ?? true
        let allowed = ComicsBrowserProfile.allows(url, mainFrame: main)
        if allowed && action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
        else { decisionHandler(allowed ? .allow : .cancel) }
    }
}

private struct SiteVerificationWebView: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
