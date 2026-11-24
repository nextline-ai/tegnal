import SwiftUI

/// Settings' top level for either mode, as the system Settings app lays out its own: search, the
/// mode's own connection rows, then a short list of pages, those that change the most first. Where
/// Apple Intelligence runs, the Settings Assistant comes first and fills most of the first screen.
struct SettingsHome<Top: View>: View {
    let booru: Bool
    @ViewBuilder var top: () -> Top
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var assistant = SettingsAssistant()
    @State private var assistantAvailable = SettingsAssistant.isAvailable
    @State private var height: CGFloat = 700

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if assistantAvailable {
            // The model loads only once a request is being written, and its session ends with each
            // answer, so Apple Intelligence stays off (and the phone cool) while Settings is just open.
            list
        } else {
            list.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(L10n.text("Search Settings")))
        }
    }

    private var list: some View {
        List {
            // The community invitation comes first, above everything else, while it is due.
            if env.discordInvitationVisible, trimmedQuery.isEmpty { Section { DiscordInvitationBanner() } }
            if assistantAvailable {
                Section {
                    SettingsAssistantHero(assistant: assistant, suggestions: suggestionKeys.map { L10n.text($0) }, minHeight: height * 0.7, ask: ask) { turn in
                        assistant.undo(turn, env: env, booru: booru)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                // Search waits below the assistant, as a plain field.
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField(L10n.text("Search Settings"), text: $query).submitLabel(.search)
                            .accessibilityIdentifier("settings.search")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(.borderless).accessibilityLabel(L10n.text("Clear"))
                        }
                    }
                }
            }
            if trimmedQuery.isEmpty {
                Section {
                    top()
                    SettingsCategoryRow(category: .addons, booru: booru)
                }
                ForEach(Array(SettingsCategory.groups.enumerated()), id: \.offset) { _, group in
                    Section { ForEach(group) { SettingsCategoryRow(category: $0, booru: booru) } }
                }
                DeveloperInfoSection()
            } else {
                results
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .navigationDestination(for: SettingsCategory.self) { SettingsCategoryPage(category: $0, booru: booru) }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { height = proxy.size.height }.onChange(of: proxy.size.height) { _, value in height = value }
        })
    }

    private var suggestionKeys: [String] {
        booru ? ["Show thumbnails in two big columns", "Always load original images", "Use the light theme"]
              : ["Read right to left like manga", "Scroll through works like a webtoon", "Show thumbnails in two big columns"]
    }

    private func ask(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard assistantAvailable, !request.isEmpty, !assistant.busy else { return }
        Task { await assistant.ask(request, env: env, booru: booru) }
    }

    @ViewBuilder private var results: some View {
        let found = SettingsCatalog.search(trimmedQuery, in: SettingsCatalog.items(booru: booru))
        if assistantAvailable {
            Section {
                Button { ask(trimmedQuery); query = "" } label: {
                    Label(L10n.text("Ask Apple Intelligence: “%@”", trimmedQuery), systemImage: "apple.intelligence")
                }.disabled(assistant.busy).accessibilityIdentifier("settings.assistant.ask")
            }
        }
        Section {
            if found.isEmpty {
                Text(L10n.text("No Matching Settings")).foregroundStyle(.secondary)
            }
            ForEach(found) { item in
                NavigationLink(value: item.category) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.category.title).font(.footnote).foregroundStyle(.secondary)
                        }
                    } icon: { SettingsIconTile(symbol: item.category.symbol, tint: item.category.tint) }
                }.accessibilityIdentifier("settings.result." + item.id)
            }
        }
    }
}

/// The Settings Assistant where Apple Intelligence runs: a large card with the Apple Intelligence
/// glow in system colors, suggestions to start, the latest requests with what changed and Undo, and a
/// field to ask in.
struct SettingsAssistantHero: View {
    let assistant: SettingsAssistant
    let suggestions: [String]
    let minHeight: CGFloat
    let ask: (String) -> Void
    let undo: (SettingsAssistant.Turn.ID) -> Void
    @State private var request = ""
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The system colors of the Apple Intelligence glow.
    static let glow: [Color] = [.blue, .purple, .pink, .orange, .cyan, .blue]
    static let symbolStyle = LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    private static let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 28)
            Spacer(minLength: 20)
            if assistant.turns.isEmpty { suggestionList } else { conversation }
            Spacer(minLength: 20)
            composer
            Text(L10n.text("Changes are made on this device by Apple Intelligence, and each can be undone."))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Self.shape)
        .overlay { border }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.assistant")
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Self.symbolStyle)
                .symbolEffect(.pulse, isActive: assistant.busy && !reduceMotion)
                .accessibilityHidden(true)
            Text(L10n.text("Settings Assistant")).font(.title.bold())
            Text(L10n.text("Tell me how you’d like TEGNAL to work, and I’ll change the settings for you."))
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestionList: some View {
        VStack(spacing: 10) {
            ForEach(suggestions, id: \.self) { text in
                Button { ask(text) } label: {
                    Label(text, systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .accessibilityIdentifier("settings.assistant.suggestion")
            }
        }
    }

    /// The two latest requests; older ones leave the card.
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(assistant.turns.suffix(2)) { turn in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Spacer(minLength: 48)
                        Text(turn.request)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityIdentifier("settings.assistant.request")
                    }
                    if turn.pending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.text("Changing settings…")).foregroundStyle(.secondary)
                        }
                    } else {
                        Label {
                            Text(turn.reply).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            if turn.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            else { Image(systemName: "apple.intelligence").foregroundStyle(Self.symbolStyle) }
                        }
                        .accessibilityIdentifier("settings.assistant.reply")
                        if !turn.changes.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(turn.changes) { change in
                                    LabeledContent(change.title, value: change.from + " → " + change.to)
                                        .font(.subheadline).strikethrough(turn.undone)
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                    if change.id != turn.changes.last?.id { Divider().padding(.leading, 14) }
                                }
                            }
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            Button(L10n.text(turn.undone ? "Undone" : "Undo"), systemImage: "arrow.uturn.backward") { undo(turn.id) }
                                .buttonStyle(.bordered).controlSize(.small).disabled(turn.undone)
                                .accessibilityIdentifier("settings.assistant.undo")
                        }
                        if let open = turn.open {
                            NavigationLink(value: open) {
                                Label(L10n.text("Open %@", open.title), systemImage: open.symbol)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L10n.text("Ask for a change"), text: $request, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .onChange(of: focused) { _, editing in if editing { SettingsAssistant.prewarm() } }
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityIdentifier("settings.assistant.field")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 36))
            }
            .buttonStyle(.borderless)
            .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.busy)
            .accessibilityLabel(L10n.text("Ask Apple Intelligence"))
            .accessibilityIdentifier("settings.assistant.send")
        }
    }

    private func send() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.busy else { return }
        request = ""
        focused = false
        ask(text)
    }

    /// The glow turns only while the model works, so an open page draws nothing; it holds still with Reduce Motion.
    private var border: some View {
        TimelineView(.animation(paused: reduceMotion || !assistant.busy)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(reduceMotion || !assistant.busy ? 0 : (seconds * 180).truncatingRemainder(dividingBy: 360))
            let gradient = AngularGradient(colors: Self.glow, center: .center, angle: angle)
            ZStack {
                Self.shape.strokeBorder(gradient, lineWidth: 8).blur(radius: 14).opacity(0.55)
                Self.shape.strokeBorder(gradient, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The colored square the system Settings app draws beside each page.
struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var size = 29
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let booru: Bool
    var body: some View {
        NavigationLink(value: category) {
            LabeledContent {
                if category == .addons {
                    let count = AddonRuntime.shared.effects.enabledCount(booru ? .images : .comics)
                    if count > 0 { Text(String(count)) }
                }
            } label: {
                Label { Text(category.title) } icon: { SettingsIconTile(symbol: category.symbol, tint: category.tint) }
            }
        }.accessibilityIdentifier("settings.category." + category.rawValue)
    }
}

/// One page of Settings, with the sections each mode keeps there.
struct SettingsCategoryPage: View {
    let category: SettingsCategory
    let booru: Bool
    var body: some View {
        switch category {
        case .viewer:
            ReaderSettingsForm(booru: booru).navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
        case .privacy: PrivacySecurityView()
        case .taste: TasteSettingsView(mode: booru ? .booru : .comics)
        case .addons: AddonsView(mode: booru ? .images : .comics)
        default:
            List { sections }
                .listStyle(.insetGrouped)
                .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("settings.page." + category.rawValue)
        }
    }

    @ViewBuilder private var sections: some View {
        switch category {
        case .browsing: if booru { BooruBrowsingSettings() } else { ComicsBrowsingSettings() }
        case .appearance: ModeAppearanceSettings()
        case .language: LanguageSettingsSection(booru: booru)
        case .library: if booru { BooruLibrarySettings() } else { ComicsLibrarySettings() }
        case .start:
            BooruSafeModeSettings()
            StudyModeSettings()
        case .help: SettingsHelpPage(booru: booru)
        case .viewer, .privacy, .taste, .addons: EmptyView()
        }
    }
}

private struct ComicsBrowsingSettings: View {
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(MangaThumbnailOpening.preferenceKey, store: ReaderPreferences.defaults) private var showsInformationBeforeReading = false
    var body: some View {
        @Bindable var env = env
        Section {
            Toggle(isOn: $env.useEmbeddedBrowser) {
                SettingsHelpLabel("Use Embedded Browser", help: "Opens the website instead of the app’s native screens. Try this if a website does not load correctly.", symbol: "safari")
            }.accessibilityIdentifier("settings.embeddedBrowser")
            Toggle(isOn: $showsInformationBeforeReading) {
                SettingsHelpLabel("Show Work Information Before Reading", help: "Shows the title, tags and page previews when you tap a work. When off, the work opens directly in the viewer.", symbol: "list.bullet.below.rectangle")
            }.accessibilityIdentifier("settings.mangaInfoBeforeReading")
            NavigationLink { ThumbnailGestureSettings() } label: {
                Label(L10n.text("Thumbnail Gestures"), systemImage: "hand.tap")
            }.accessibilityIdentifier("settings.thumbnailGestures")
        } header: { Text(L10n.text("Browsing")) }
        MangaDefaultTagsSettings()
        SearchHistorySettings()
    }
}

private struct BooruBrowsingSettings: View {
    @Environment(BooruStore.self) private var store
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    var body: some View {
        Section {
            NavigationLink { ThumbnailGestureSettings(booru: true) } label: {
                Label(L10n.text("Thumbnail Gestures"), systemImage: "hand.tap")
            }.accessibilityIdentifier("booru.thumbnailGestures")
            Toggle(isOn: $useEmbeddedBrowser) {
                SettingsHelpLabel("Use Embedded Browser", help: "Opens the website instead of the app’s native screens. Try this if a website does not load correctly.", symbol: "safari")
            }.accessibilityIdentifier("booru.browserToggle")
        } header: { Text(L10n.text("Browsing")) }
        Section {
            NavigationLink {
                if store.servers.count == 1, let server = store.servers.first { BooruBlacklistView(server: server) } else { BooruServersView() }
            } label: { Label(L10n.text("Tag Blacklist"), systemImage: "eye.slash") }
                .accessibilityIdentifier("booru.blacklistLink")
        } header: { Text(L10n.text("Explore & Search Filters")) } footer: {
            Text(L10n.text("Each server keeps its own tag blacklist, which hides images in Explore and in searches."))
        }
        SearchHistorySettings(booru: true)
    }
}

private struct ComicsLibrarySettings: View {
    var body: some View {
        Section {
            NavigationLink { DownloadsView(mode: .manga) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                .accessibilityIdentifier("settings.downloads")
        }
        SavedWorksSettingsSection()
        Section {
            NavigationLink { MangaLibraryToolsView() } label: {
                Label(L10n.text("Library Management"), systemImage: "externaldrive")
            }.accessibilityIdentifier("settings.libraryManagement")
            NavigationLink { ComicsCacheSettingsView() } label: {
                Label(L10n.text("Image Cache"), systemImage: "photo.stack")
            }.accessibilityIdentifier("settings.imageCache")
        } header: { Text(L10n.text("Data & Storage")) }
    }
}

private struct BooruLibrarySettings: View {
    @State private var cacheCleared = false
    @State private var confirmClearCache = false
    var body: some View {
        Section {
            NavigationLink { DownloadsView(mode: .booru) } label: { Label(L10n.text("Downloads"), systemImage: "arrow.down.circle") }
                .accessibilityIdentifier("booru.downloadsLink")
            NavigationLink { FolderRulesView(booru: true) } label: { Label(L10n.text("Smart Folders"), systemImage: "sparkles") }
                .accessibilityIdentifier("booru.folderRules")
        }
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
        .alert(L10n.text("Clear Image Cache?"), isPresented: $confirmClearCache) {
            Button(L10n.text("Clear Image Cache"), role: .destructive) { Task { await BooruThumbnailCache.shared.clear(); await BooruViewerImageCache.shared.clear(); cacheCleared = true } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Saved favorites are kept. Images will be downloaded again when needed.")) }
    }
}

private struct SettingsHelpPage: View {
    let booru: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var showOnboarding = false
    var body: some View {
        SettingsSupportSection(showOnboarding: $showOnboarding, booru: booru)
            .appFullScreenCover(isPresented: $showOnboarding) { OnboardingView().environment(env) }
    }
}
