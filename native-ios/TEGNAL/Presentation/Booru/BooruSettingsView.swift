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
                                // The name the app uses for the server everywhere, over its address.
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName).foregroundStyle(.primary)
                                    Text(server.baseURL.host ?? server.baseURL.absoluteString).font(.footnote).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                            // Safe Mode browses Safebooru alone; the other servers stay, unchosen, until it is off.
                            .disabled(store.safeMode && !server.isSafebooru)
                        Button { editing = .init(server: server) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Edit") + " " + server.displayName)
                            .accessibilityIdentifier("booru.editServer.\(server.id)")
                    }.padding(.vertical, 4).swipeActions {
                        Button(L10n.text("Delete"), role: .destructive) { deleting = server }
                    }
                }
                Button(L10n.text("Add a Server"), systemImage: "plus") { editing = .init() }.accessibilityIdentifier("booru.addServer")
            } header: { SettingsHelpLabel("Servers", help: "Add a supported image website, then select the servers you want to search. Each server keeps its own favorites and filters.") }
        }.navigationTitle(L10n.text("Servers")).navigationBarTitleDisplayMode(.inline)
            .appSheet(item: $editing) { item in WebsiteConnectionEditor(server: item.server) }
            .confirmationDialog(L10n.text("Delete Server?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L10n.text("Delete"), role: .destructive) {
                    if let deleting {
                        store.perform {
                            try store.deleteServer(deleting)
                            BooruAccounts.shared.setIdentity(nil, serverID: deleting.id)
                            BooruAccounts.shared.favorites.remove(deleting.id, declined: false)
                            Task { await BooruBrowserSession.reset(deleting) }
                        }
                    }
                    deleting = nil
                }
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
        case .comics: return AppMode.manga.icon
        case .booru: return "checkmark.circle"
        }
    }

    /// Image Mode only for the image engines the app supports; every other website is a comics
    /// site. Comics Mode finds the site's protocol itself once it connects, including sites that
    /// show first visitors a check, a sign-in page or nothing at all.
    static func recognizing(_ html: String) -> Self {
        if MangaUrls.isDocumentPage(html) || MangaUrls.isIndexedPage(html) || MangaUrls.isKeyedPage(html) { return .comics }
        if let engine = BooruEngine.recognizing(html) { return .booru(engine) }
        return .comics
    }

    @MainActor static func detect(at url: URL, loadHTML: (URL) async throws -> String = { try await ContentBrowserTransport.inspectWebsite(at: $0) }) async throws -> Self {
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
            mode(.manga, description: "Read multi-page works by their work number.", icon: AppMode.manga.icon)
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
    /// Where the server's images land when no folder is chosen.
    @State private var saveFolder = ""
    @State private var serverTypeChoice: ServerType?
    @State private var showOptions = false
    private enum Detection: Equatable {
        case idle, checking(URL), recognized(URL, ServerType), failed(URL)
    }
    @State private var detection = Detection.idle
    @State private var detectionRetry = 0
    private var needsConnectionHelp: Bool {
        if case .failed(let url) = detection { return url == addressURL }
        return false
    }
    private var addressURL: URL? { try? BooruServer.validatedURL(address) }
    private var allowsComics: Bool { server == nil }

    private var detectedServerType: ServerType? {
        if case .recognized(let url, let type) = detection, url == addressURL { return type }
        // A home page this device couldn't load may still open through the comics connection,
        // which reaches sites the inspecting browser can't; the image engines are named above.
        if case .failed(let url) = detection, url == addressURL { return .comics }
        if let suggested = addressURL.flatMap(BooruEngine.suggested) {
            return .booru(suggested)
        }
        return nil
    }

    private var effectiveServerType: ServerType? {
        serverTypeChoice ?? detectedServerType
    }

    private var automaticTitle: String {
        guard let detectedServerType else { return L10n.text("Automatic") }
        return L10n.text("Automatic") + " · " + L10n.text(detectedServerType == .comics ? "Comics Mode" : "Image Mode")
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
                // Every server has a name, used for it throughout the app.
                if case .booru = effectiveServerType {
                    LabeledContent(L10n.text("Name")) {
                        TextField(L10n.text("Name"), text: $name, prompt: Text(addressURL?.host ?? ""))
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("booru.serverName")
                    }
                }
            } header: { SettingsHelpLabel("Website Address", help: "Enter the website’s home address. Automatic identifies the website and opens the matching Comics or Image mode.") }
            Section {
                // The Automatic choice names what it found, so the section needs no row of its own for it.
                Picker(L10n.text("Mode"), selection: $serverTypeChoice) {
                    Text(automaticTitle).tag(nil as ServerType?)
                    if allowsComics {
                        Text(L10n.text("Comics Mode")).tag(Optional(ServerType.comics))
                    }
                    ForEach(BooruEngine.allCases) { engine in
                        Text(L10n.text("Image Mode") + " · " + engine.title).tag(Optional(ServerType.booru(engine)))
                    }
                }.accessibilityIdentifier("booru.serverEngine")
                if case .checking(let url) = detection, url == addressURL, serverTypeChoice == nil {
                    ProgressView(L10n.text("Identifying website…")).accessibilityIdentifier("website.detecting")
                } else if effectiveServerType == nil, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            if case .booru(let engine) = effectiveServerType {
                Section {
                    DisclosureGroup(isExpanded: $showOptions) {
                        if engine != .oldGelbooru {
                            TextField(L10n.text(engine == .gelbooru ? "User ID" : "Username"), text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onChange(of: account) { fillPastedAPIAccess() }
                            SecureField(L10n.text(engine == .moebooru ? "Password Hash" : "API Key"), text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .onChange(of: apiKey) { fillPastedAPIAccess() }
                            if engine == .gelbooru {
                                Text(L10n.text("You can paste the whole “&api_key=…&user_id=…” line from your account options on the website into either field."))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        SettingsHelpLabel("Additional Options", help: "Optional account details can improve access on some websites. Copy them from that website’s account settings; they are stored securely in Keychain.")
                            .accessibilityIdentifier("booru.serverOptions")
                    }
                }
            }
            if let server {
                BooruAccountSection(server: server)
                // The server's connection and filters, which image mode's settings no longer list.
                Section {
                    Picker(selection: $saveFolder) {
                        ForEach(store.folders(forServer: server.id)) { Text($0.displayName).tag($0.id) }
                    } label: { Label(L10n.text("Default Save Folder"), systemImage: "folder") }
                        .accessibilityIdentifier("booru.saveFolder")
                    NavigationLink { BooruBlacklistView(server: server) } label: { Label(L10n.text("Tag Blacklist"), systemImage: "eye.slash") }
                        .accessibilityIdentifier("booru.blacklist")
                    Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = true }.accessibilityIdentifier("booru.validate")
                    NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }
                        .accessibilityIdentifier("booru.cookies")
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
            .appSheet(isPresented: $validating) { if let server { BooruValidationView(server: server) } }
            .onAppear {
                guard !initialized else { return }; initialized = true
                guard let server else { address = initialAddress; return }
                name = server.displayName; address = server.baseURL.absoluteString; serverTypeChoice = .booru(server.engine); showOptions = true
                saveFolder = (try? store.database.read { try BooruStore.defaultFolder(for: server.id, db: $0) }) ?? ""
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
                    detection = .recognized(url, type)
                } catch {
                    if !Task.isCancelled, addressURL == url { detection = .failed(url) }
                }
            }
    }
    /// Gelbooru's API access line, pasted into either field, fills both.
    private func fillPastedAPIAccess() {
        for text in [account, apiKey] {
            if let pasted = BooruCredentials.pastedAPIAccess(text) { account = pasted.account; apiKey = pasted.apiKey; return }
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
                // Uncategorized is where a server saves unless told otherwise, so it is never stored as a choice.
                let chosenFolder = saveFolder.isEmpty || BooruFolder.isUncategorized(saveFolder) ? nil : saveFolder
                let value = BooruServer(id: server?.id ?? UUID().uuidString, name: displayName.isEmpty ? (url.host ?? url.absoluteString) : displayName, baseURL: url, engine: engine,
                                        saveFolder: server == nil ? nil : chosenFolder)
                guard !store.servers.contains(where: { $0.id != value.id && $0.baseURL == url }) else { throw BooruError.duplicateServer }
                let credentials = BooruCredentials(account: account, apiKey: apiKey).normalized
                guard credentials.account.isEmpty == credentials.apiKey.isEmpty else { throw BooruError.authentication }
                try BooruKeychain.save(credentials, serverID: value.id)
                try store.saveServer(value)
                if server == nil { try store.setSelectedServers(store.selectedServerIDs + [value.id]) }
                // Account details saved here sign the account in, as a sign-in on the website does.
                let accounts = env.booruAccounts
                if !credentials.isEmpty { Task { await accounts.discover(value, force: true) } }
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
                TextEditor(text: $text).frame(minHeight: 240).font(.body)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("booru.blacklistText")
            } header: { SettingsHelpLabel("Tag Blacklist", help: "Enter one rule per line to hide matching images. You can use a tag, rating:explicit, id:123 or artist:name. Delete a rule to show those images again.") }
            Section(L10n.text("Example")) { Text("spoilers\ngore -scenery\nrating:explicit\nartist_*").font(.footnote).foregroundStyle(.secondary) }
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
    @State private var cacheCleared = false
    @State private var confirmClearCache = false
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    var body: some View {
        Form {
            if env.discordInvitationVisible { Section { DiscordInvitationBanner() } }
            Section(L10n.text("Browsing")) {
                NavigationLink { BooruServersView() } label: { Label(L10n.text("Servers"), systemImage: "server.rack") }
                    .accessibilityIdentifier("booru.serversLink")
                NavigationLink { ChallengeLibraryView(source: source) } label: { Label { Text(L10n.text("Challenge Roulette")) } icon: { Image(systemName: "dice").foregroundStyle(.purple) } }
                    .accessibilityIdentifier("booru.challengesLink")
                if !store.servers.isEmpty {
                    NavigationLink {
                        if store.selectedServers.count == 1, let server = store.selectedServer { BooruPoolsView(server: server, source: source) }
                        else { BooruPoolServersView(source: source) }
                    } label: { Label(L10n.text("Pools"), systemImage: "rectangle.stack") }
                        .accessibilityIdentifier("booru.poolsLink")
                }
                NavigationLink { DownloadsView(mode: .booru) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                    .accessibilityIdentifier("booru.downloadsLink")
                NavigationLink { FolderRulesView(booru: true) } label: { Label(L10n.text("Smart Folders"), systemImage: "sparkles") }
                    .accessibilityIdentifier("booru.folderRules")
                NavigationLink { ThumbnailGestureSettings(booru: true) } label: {
                    Label(L10n.text("Thumbnail Gestures"), systemImage: "hand.tap")
                }.accessibilityIdentifier("booru.thumbnailGestures")
            }

            ReaderSettingsSection(booru: true, isPresented: $showReader)
            ModeAppearanceSettings()
            LanguageSettingsSection(booru: true)
            Section {
                Toggle(isOn: $useEmbeddedBrowser) {
                    SettingsHelpLabel("Use Embedded Browser", help: "Opens the website instead of the app’s native screens. Try this if a website does not load correctly.", symbol: "safari")
                }.accessibilityIdentifier("booru.browserToggle")
            } header: { Text(L10n.text("Website Connection")) }
            SearchHistorySettings(booru: true)
            TasteSettingsSection(mode: .booru)
            BooruSafeModeSettings()
            StudyModeSettings()
            Section {
                NavigationLink { BooruBackupView() } label: { Label(L10n.text("Library Management"), systemImage: "externaldrive") }
                    .accessibilityIdentifier("booru.libraryManagement")
                HStack(spacing: 4) {
                    Button(L10n.text(cacheCleared ? "Image Cache Cleared" : "Clear Image Cache")) {
                        confirmClearCache = true
                    }.accessibilityIdentifier("settings.clearCache")
                    SettingsInfoButton(title: "Clear Image Cache", message: "Deletes temporary thumbnails and viewer images from this device. Your saved works stay in the library; images download again when needed.")
                }
            } header: { Text(L10n.text("Data & Storage")) }
            PrivacySecuritySection()
            SettingsSupportSection(showOnboarding: $showOnboarding, booru: true)
            DeveloperInfoSection()
        }
        .onAppear { env.presentDiscordInvitationIfDue() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
        .alert(L10n.text("Clear Image Cache?"), isPresented: $confirmClearCache) {
            Button(L10n.text("Clear Image Cache"), role: .destructive) { Task { await BooruThumbnailCache.shared.clear(); await BooruViewerImageCache.shared.clear(); cacheCleared = true } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Saved favorites are kept. Images will be downloaded again when needed.")) }
        .appSheet(isPresented: $showReader) { ReaderSettingsView(booru: true) }
        .appFullScreenCover(isPresented: $showOnboarding) { OnboardingView().environment(env) }

    }
}
