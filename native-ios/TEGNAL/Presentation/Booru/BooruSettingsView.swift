import SwiftUI

private struct ServerEdit: Identifiable {
    let id = UUID()
    var server: BooruServer?
}

struct BooruServersView: View {
    @Environment(BooruStore.self) private var store
    @State private var editing: ServerEdit?
    @State private var deleting: BooruServer?
    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    HStack {
                        Button { store.perform { try store.toggleServer(server) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: store.selectedServerIDs.contains(server.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.displayName).foregroundStyle(.primary)
                                    Text(server.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { editing = .init(server: server) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Edit") + " " + server.displayName)
                    }.padding(.vertical, 4).swipeActions {
                        Button(L10n.text("Delete"), role: .destructive) { deleting = server }
                    }
                }
                Button(L10n.text("Add a Server"), systemImage: "plus") { editing = .init() }.accessibilityIdentifier("booru.addServer")
            } header: { Text(L10n.text("Servers")) } footer: { Text(L10n.text("Danbooru, Gelbooru, Old Gelbooru (v0.1.11) and Moebooru compatible servers are supported.")) }
        }.navigationTitle(L10n.text("Servers")).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { item in WebsiteConnectionEditor(server: item.server) }
            .confirmationDialog(L10n.text("Delete Server?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L10n.text("Delete"), role: .destructive) { if let deleting { store.perform { try store.deleteServer(deleting); Task { await BooruBrowserSession.reset(deleting) } } }; deleting = nil }
            } message: { Text(L10n.text("This removes the server and its Booru favorites, saved tags, artists, history and blacklist from this device.")) }
    }
}

enum ServerType: Hashable, Identifiable, Sendable {
    case comics
    case booru(BooruEngine)

    var id: String {
        switch self {
        case .comics: return "comics"
        case .booru(let engine): return engine.rawValue
        }
    }

    var title: String {
        switch self {
        case .comics: return L10n.text("Comics Mode")
        case .booru(let engine): return engine.title
        }
    }

    var icon: String {
        switch self {
        case .comics: return "book"
        case .booru: return "checkmark.circle"
        }
    }

    static func recognizing(_ html: String) -> Self? {
        if MangaUrls.isDocumentPage(html) || MangaUrls.isIndexedPage(html) { return .comics }
        if html.range(of: #"Danbooru\.|content=["']Danbooru"#, options: .regularExpression) != nil { return .booru(.danbooru) }
        if html.range(of: #"Gelbooru\s+Beta\s+0\.1\.11"#, options: [.regularExpression, .caseInsensitive]) != nil { return .booru(.oldGelbooru) }
        if html.range(of: "Moebooru", options: .caseInsensitive) != nil { return .booru(.moebooru) }
        if html.range(of: "Gelbooru", options: .caseInsensitive) != nil { return .booru(.gelbooru) }
        return nil
    }

    @MainActor static func detect(at url: URL, loadHTML: (URL) async throws -> String = { try await ContentBrowserTransport.inspectWebsite(at: $0) }) async throws -> Self? {
        if let engine = BooruEngine.suggested(for: url) { return .booru(engine) }
        #if DEBUG
        if ContentUITestSupport.enabled { return recognizing(try await ContentUITestSupport.websiteHTML(for: url)) }
        #endif
        return recognizing(try await loadHTML(url))
    }
}

struct WebsiteModeGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            mode(.manga, description: "Read multi-page works by their work number.", icon: "book.closed")
            mode(.booru, description: "Browse individual images using tags.", icon: "photo")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("website.modeGuide")
    }
    private func mode(_ mode: AppMode, description: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.title).font(.subheadline.bold())
                Text(L10n.text(description)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct WebsiteConnectionEditor: View {
    let server: BooruServer?
    var initialAddress = ""
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var serverTypeChoice: ServerType?
    @State private var showOptions = false
    private enum Detection: Equatable {
        case idle, checking(URL), recognized(URL, ServerType), unrecognized(URL), failed(URL)
    }
    @State private var detection = Detection.idle
    @State private var detectionRetry = 0
    private var needsConnectionHelp: Bool {
        switch detection {
        case .failed(let url), .unrecognized(let url): return url == addressURL
        default: return false
        }
    }
    private var addressURL: URL? { try? BooruServer.validatedURL(address) }
    private var allowsComics: Bool { server == nil }

    private var detectedServerType: ServerType? {
        if case .recognized(let url, let type) = detection, url == addressURL { return type }
        if let suggested = addressURL.flatMap(BooruEngine.suggested) {
            return .booru(suggested)
        }
        return nil
    }

    private var effectiveServerType: ServerType? {
        serverTypeChoice ?? detectedServerType
    }

    private var isComics: Bool {
        effectiveServerType == .comics
    }

    @State private var account = ""
    @State private var apiKey = ""
    @State private var error: String?
    @State private var initialized = false
    @State private var validating = false
    var body: some View {
        NavigationStack { form }
    }

    private var form: some View {
        Form {
            Section {
                TextField("https://example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(server != nil).accessibilityIdentifier("booru.serverURL")
                    .accessibilityLabel(L10n.text("Website Address"))
            } header: { Text(L10n.text("Website Address")) } footer: {
                Text(L10n.text(server == nil ? "Enter a comics or image website. We’ll detect its type and switch to the right mode." : "Enter the website’s home address."))
            }
            Section {
                Picker(L10n.text("Mode"), selection: $serverTypeChoice) {
                    Text(L10n.text("Automatic")).tag(nil as ServerType?)
                    if allowsComics {
                        Text(L10n.text("Comics Mode")).tag(Optional(ServerType.comics))
                    }
                    ForEach(BooruEngine.allCases) { engine in
                        Text(L10n.text("Image Mode") + " · " + engine.title).tag(Optional(ServerType.booru(engine)))
                    }
                }.accessibilityIdentifier("booru.serverEngine")
                if case .checking(let url) = detection, url == addressURL, serverTypeChoice == nil {
                    ProgressView(L10n.text("Identifying website…")).accessibilityIdentifier("website.detecting")
                } else if let effectiveServerType {
                    Label(effectiveServerType == .comics ? L10n.text("Comics Mode") : L10n.text("Image Mode"), systemImage: effectiveServerType.icon)
                        .foregroundStyle(.tint).accessibilityIdentifier("website.detectedMode")
                    if case .booru(let engine) = effectiveServerType { Text(engine.title).font(.footnote).foregroundStyle(.secondary) }
                    Text(L10n.text("Saving this address will open the matching mode.")).font(.footnote).foregroundStyle(.secondary)
                } else if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.text("Couldn’t identify this website. Check the connection or select its mode manually."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text(L10n.text("Connection")) }
            if needsConnectionHelp {
                Section {
                    Text(ContentError.initialConnectionHelp)
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("website.connectionHelp")
                    Button(L10n.text("Try Again")) { detectionRetry += 1 }
                        .accessibilityIdentifier("website.retryDetection")
                }
            }
            if server == nil { Section { WebsiteModeGuide() } }
            if case .booru(let engine) = effectiveServerType {
                Section {
                    DisclosureGroup(isExpanded: $showOptions) {
                        TextField(L10n.text("Name (Optional)"), text: $name).accessibilityIdentifier("booru.serverName")
                        if engine != .oldGelbooru {
                            TextField(L10n.text(engine == .gelbooru ? "User ID" : "Username"), text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField(L10n.text(engine == .moebooru ? "Password Hash" : "API Key"), text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text(L10n.text("Use credentials from your server account settings. They are stored securely in Keychain."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(L10n.text("Additional Options")).accessibilityIdentifier("booru.serverOptions")
                    }
                }
            }
            if let server {
                Section {
                    Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = true }
                    NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle(L10n.text(server == nil ? "Connect a Website" : "Edit Server"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save"), action: save)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveServerType == nil)
                        .accessibilityIdentifier("booru.serverSave")
                }
            }
            .sheet(isPresented: $validating) { if let server { BooruValidationView(server: server) } }
            .onAppear {
                guard !initialized else { return }; initialized = true
                guard let server else { address = initialAddress; return }
                name = server.displayName; address = server.baseURL.absoluteString; serverTypeChoice = .booru(server.engine); showOptions = true
                do { let credentials = try BooruKeychain.read(serverID: server.id); account = credentials.account; apiKey = credentials.apiKey }
                catch { self.error = error.localizedDescription }
            }
            .task(id: "\(addressURL?.absoluteString ?? "")|\(detectionRetry)") {
                detection = .idle
                if server == nil { serverTypeChoice = nil }
                guard allowsComics, server == nil, let url = addressURL,
                      BooruEngine.suggested(for: url) == nil else { return }
                detection = .checking(url)
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    let type = try await ServerType.detect(at: url)
                    try Task.checkCancellation()
                    guard addressURL == url else { return }
                    detection = type.map { .recognized(url, $0) } ?? .unrecognized(url)
                } catch {
                    if !Task.isCancelled, addressURL == url { detection = .failed(url) }
                }
            }
    }
    private func save() {
        guard let effectiveServerType else { return }
        switch effectiveServerType {
        case .comics:
            if env.verifySite(input: address) {
                dismiss()
                env.mode = .manga
            } else {
                self.error = L10n.text("This address is not supported. Check the website address and try again.")
            }
        case .booru(let engine):
            do {
                let url = try BooruServer.validatedURL(address)
                let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = BooruServer(id: server?.id ?? UUID().uuidString, name: displayName.isEmpty ? (url.host ?? url.absoluteString) : displayName, baseURL: url, engine: engine)
                guard !store.servers.contains(where: { $0.id != value.id && $0.baseURL == url }) else { throw BooruError.duplicateServer }
                let credentials = BooruCredentials(account: account.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                guard credentials.account.isEmpty == credentials.apiKey.isEmpty else { throw BooruError.authentication }
                try BooruKeychain.save(credentials, serverID: value.id)
                try store.saveServer(value)
                if server == nil { try store.setSelectedServers(store.selectedServerIDs + [value.id]) }
                dismiss()
                env.mode = .booru
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct BooruBlacklistView: View {
    let server: BooruServer
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 240).font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("booru.blacklistText")
            } header: { Text(L10n.text("Tag Blacklist")) } footer: {
                Text(L10n.text("One rule per line. Use tags, rating:explicit, id:123, or artist:name. Remove a rule to unblock content."))
            }
            Section(L10n.text("Example")) { Text("spoilers\ngore -scenery\nrating:explicit\nartist_*").font(.footnote.monospaced()).foregroundStyle(.secondary) }
        }.navigationTitle(server.displayName).navigationBarTitleDisplayMode(.inline)
            .onAppear { text = store.blacklist(serverID: server.id) }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Save")) {
                    do { try store.setBlacklist(text, serverID: server.id); dismiss() }
                    catch { store.error = error.localizedDescription }
                }.accessibilityIdentifier("booru.blacklistSave")
            } }
    }
}

struct BooruMoreView: View {
    let source: any BooruProviding
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    @State private var showOnboarding = false
    @State private var showReader = false
    @State private var validating: BooruServer?
    @State private var cacheCleared = false
    @State private var confirmClearCache = false
    @SwiftUI.AppStorage("booru.fitThumbnails", store: ReaderPreferences.booruDefaults) private var fitThumbnails = false
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    var body: some View {
        Form {
            Section {
                NavigationLink { ChallengeLibraryView(source: source) } label: { Label { Text(L10n.text("Challenge Roulette")) } icon: { Image(systemName: "dice").foregroundStyle(.purple) } }
                    .accessibilityIdentifier("booru.challengesLink")
                NavigationLink { BooruServersView() } label: { Label(L10n.text("Servers"), systemImage: "server.rack") }
                    .accessibilityIdentifier("booru.serversLink")
                if !store.servers.isEmpty {
                    NavigationLink {
                        if store.selectedServers.count == 1, let server = store.selectedServer { BooruPoolsView(server: server, source: source) }
                        else { BooruPoolServersView(source: source) }
                    } label: { Label(L10n.text("Pools"), systemImage: "rectangle.stack") }
                        .accessibilityIdentifier("booru.poolsLink")
                }
                NavigationLink { DownloadsView(mode: .booru) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("booru.downloadsLink")
            } footer: {
                Text(store.selectedServers.map(\.displayName).joined(separator: " · "))
            }

            ModeAppearanceSettings()
            LanguageSettingsSection(booru: true)
            Section {
                Toggle(L10n.text("Use Embedded Browser"), isOn: $useEmbeddedBrowser).accessibilityIdentifier("booru.browserToggle")
                Toggle(L10n.text("Fit Entire Thumbnails"), isOn: $fitThumbnails)
            } header: { Text(L10n.text("Browsing")) } footer: {
                Text(L10n.text("Use the website if the native viewer stops working. Turn off to return to the native viewer."))
            }
            ForEach(store.selectedServers) { server in
                Section(L10n.text("Connection & Filters") + " · " + server.displayName) {
                    NavigationLink { BooruBlacklistView(server: server) } label: { Label(L10n.text("Tag Blacklist"), systemImage: "eye.slash") }.accessibilityIdentifier("booru.blacklist")
                    Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = server }.accessibilityIdentifier("booru.validate")
                    NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }.accessibilityIdentifier("booru.cookies")
                }
            }
            ReaderSettingsSection(booru: true, isPresented: $showReader)
            SearchHistorySettings(booru: true)
            TasteSettingsSection(mode: .booru)
            CloudSyncSection()
            Section {
                NavigationLink { BooruBackupView() } label: { Label(L10n.text("Library Management"), systemImage: "externaldrive") }
                    .accessibilityIdentifier("booru.libraryManagement")
                Button(L10n.text(cacheCleared ? "Image Cache Cleared" : "Clear Image Cache")) {
                    confirmClearCache = true
                }.accessibilityIdentifier("settings.clearCache")
            } header: { Text(L10n.text("Data & Storage")) } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Booru favorites, tags, artists and history are stored separately from manga mode, and separately for each server."))
                    Text(L10n.text("Previews use up to 256 MB and viewer images use up to 512 MB of on-device cache. Two images before and after the current work are preloaded. These caches stay out of iCloud and can be cleared here."))
                }
            }
            SettingsSupportSection(showOnboarding: $showOnboarding)
            DeveloperInfoSection()
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
        .alert(L10n.text("Clear Image Cache?"), isPresented: $confirmClearCache) {
            Button(L10n.text("Clear Image Cache"), role: .destructive) { Task { await BooruThumbnailCache.shared.clear(); await BooruViewerImageCache.shared.clear(); cacheCleared = true } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Saved favorites are kept. Images will be downloaded again when needed.")) }
        .sheet(isPresented: $showReader) { ReaderSettingsView(booru: true) }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView().environment(env) }
        .sheet(item: $validating) { BooruValidationView(server: $0) }

    }
}
