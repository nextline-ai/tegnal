import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.tegnaladdon`, a JSON file. Plain `.json` add-ons open as well.
    static let tegnalAddon = UTType(exportedAs: "work.nextline.tegnal.addon", conformingTo: .json)
}

/// The row that leads to a mode's add-ons, last in the Browsing section of that mode's settings.
struct AddonsSettingsRow: View {
    let mode: AddonMode
    var body: some View {
        NavigationLink { AddonsView(mode: mode) } label: {
            LabeledContent {
                let count = AddonRuntime.shared.effects.enabledCount(mode)
                if count > 0 { Text(String(count)) }
            } label: { Label(L10n.text("Add-ons"), systemImage: "puzzlepiece.extension") }
        }.accessibilityIdentifier("settings.addons")
    }
}

/// A checked add-on waiting for the learner to decide.
struct AddonCandidate: Identifiable {
    let addon: Addon
    let digest: String
    let existing: InstalledAddon?
    /// Downloaded from the official add-ons and matched against the signed catalog.
    var official = false
    var id: String { addon.id + digest }
}

/// One mode's add-ons: the installed ones and a file to open at the top, then TEGNAL's official add-ons by grade.
/// Comics and image add-ons never meet: each mode lists, opens and installs only its own.
struct AddonsView: View {
    let mode: AddonMode
    @Environment(AppEnvironment.self) private var env
    @State private var installed: [InstalledAddon] = []
    @State private var picking = false
    @State private var reading = false
    @State private var candidate: AddonCandidate?
    @State private var error: String?
    @State private var catalog: AddonCatalog?
    @State private var loadError: String?
    @State private var downloading: String?
    private var store: AddonStore { AddonStore(env.booru) }
    private var market: AddonMarket { .live }
    private var listings: [AddonListing] { catalog?.addons.filter { $0.mode == mode } ?? [] }

    var body: some View {
        List {
            Section {
                NavigationLink { AddonInstalledListView(mode: mode) } label: {
                    LabeledContent {
                        if !installed.isEmpty { Text(String(installed.count)) }
                    } label: { Label(L10n.text("Installed Add-ons"), systemImage: "checkmark.circle") }
                }.accessibilityIdentifier("addons.installed")
                Button { picking = true } label: { Label(L10n.text("Open Add-on File"), systemImage: "doc.badge.plus") }
                    .disabled(reading)
                    .accessibilityIdentifier("addons.import")
            } header: {
                SettingsHelpLabel("My Add-ons", help: mode == .comics
                                  ? "These add-ons work in Comics Mode only. Image Mode keeps its own add-ons in its settings. Add-ons hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything one adds before it is installed, and turning one off or removing it takes back everything it added."
                                  : "These add-ons work in Image Mode only. Comics Mode keeps its own add-ons in its settings. Add-ons hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything one adds before it is installed, and turning one off or removing it takes back everything it added.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("addons.error") }
            }
            officialSections
        }
        .navigationTitle(L10n.text(mode == .comics ? "Comics Mode Add-ons" : "Image Mode Add-ons")).navigationBarTitleDisplayMode(.inline)
        .overlay { if reading { ProgressView() } }
        .refreshable { await load() }
        .task { if catalog == nil { await load() } }
        .onAppear(perform: reload)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.tegnalAddon, .json]) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url): open(url)
            }
        }
        .sheet(item: $candidate) { candidate in
            AddonInstallSheet(candidate: candidate) {
                do {
                    try store.install(candidate.addon, digest: candidate.digest, official: candidate.official)
                    error = nil
                    applyChanges()
                } catch let failure { error = failure.localizedDescription }
            }
        }
    }

    /// The official add-ons of this mode in one list, recommended ones first, each with its grade beside its name.
    @ViewBuilder private var officialSections: some View {
        Section {
            if catalog != nil {
                let sorted = AddonGrade.allCases.flatMap { grade in listings.filter { $0.addonGrade == grade } }
                if sorted.isEmpty {
                    ContentUnavailableView(L10n.text("No Official Add-ons Yet"), systemImage: "checkmark.seal",
                                           description: Text(L10n.text("Official add-ons appear here as TEGNAL publishes them.")))
                } else {
                    ForEach(sorted) { listing in row(listing) }
                }
            } else if let loadError {
                VStack(spacing: 10) {
                    Label(L10n.text("Couldn’t Load Official Add-ons"), systemImage: "wifi.exclamationmark").font(.headline)
                    Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L10n.text("Try Again")) { Task { await load() } }.accessibilityIdentifier("market.retry")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            SettingsHelpLabel("Official Add-ons", help: "Official add-ons are made and checked by TEGNAL. The list and every file are signed, so only the copy TEGNAL published is installed, and you still see everything one adds before it is installed.\n\nRecommended: TEGNAL advises these for almost everyone.\nSuggested: useful for many people.\nOptional: for particular tastes and uses.")
        }
    }

    @ViewBuilder private func row(_ listing: AddonListing) -> some View {
        let item = installed.first { $0.id == listing.id }
        let state = AddonListingState(listing, installed: item)
        if state == .installed, let item {
            NavigationLink { AddonDetailView(id: item.id, changed: reload) } label: {
                AddonListingRow(listing: listing, state: state, downloading: false)
            }.accessibilityIdentifier("market.row." + listing.id)
        } else {
            Button { get(listing) } label: { AddonListingRow(listing: listing, state: state, downloading: downloading == listing.id) }
                .buttonStyle(.plain)
                .disabled(state == .unsupported || downloading != nil)
                .accessibilityIdentifier("market.row." + listing.id)
        }
    }

    private func load() async {
        do {
            let next = try await market.catalog()
            catalog = next
            loadError = nil
        } catch is CancellationError {
        } catch let failure {
            if catalog == nil { loadError = failure.localizedDescription } else { error = failure.localizedDescription }
        }
    }

    private func get(_ listing: AddonListing) {
        downloading = listing.id
        Task {
            defer { downloading = nil }
            do {
                let (addon, digest) = try await market.download(listing)
                error = nil
                candidate = AddonCandidate(addon: addon, digest: digest, existing: installed.first { $0.id == addon.id }, official: true)
            } catch is CancellationError {
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func open(_ url: URL) {
        reading = true
        Task {
            defer { reading = false }
            do {
                let (addon, digest) = try await Task.detached { try Addon.read(url) }.value
                // An add-on for the other mode is opened from that mode's settings, so that it is never mistaken for this one's.
                guard addon.mode == mode else { throw AddonError.otherMode(addon.mode) }
                error = nil
                candidate = AddonCandidate(addon: addon, digest: digest, existing: installed.first { $0.id == addon.id })
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func reload() { installed = ((try? store.installed()) ?? []).filter { $0.addon.mode == mode } }

    private func applyChanges() {
        reload()
        AddonRuntime.apply(env.booru)
    }
}

/// The add-ons of one mode that are installed, newest first.
struct AddonInstalledListView: View {
    let mode: AddonMode
    @Environment(AppEnvironment.self) private var env
    @State private var installed: [InstalledAddon] = []

    var body: some View {
        List {
            if installed.isEmpty {
                Section {
                    ContentUnavailableView(L10n.text("No Add-ons"), systemImage: "puzzlepiece.extension",
                                           description: Text(L10n.text("Get an official add-on or open a .tegnaladdon file.")))
                }
            } else {
                Section {
                    ForEach(installed) { item in
                        NavigationLink { AddonDetailView(id: item.id, changed: reload) } label: { AddonRow(item: item) }
                            .accessibilityIdentifier("addons.row." + item.id)
                    }
                } header: {
                    SettingsHelpLabel("Installed", help: "Turning an add-on off or removing it takes back everything it added. Your own settings are never changed.")
                }
            }
        }
        .navigationTitle(L10n.text("Installed Add-ons")).navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() { installed = ((try? AddonStore(env.booru).installed()) ?? []).filter { $0.addon.mode == mode }.reversed() }
}

extension AddonRuntime {
    /// Takes in a change to the add-ons everywhere: searches, tag names, image filters, challenges and tracks.
    static func apply(_ booru: BooruStore) {
        shared.reload(booru)
        try? booru.refresh()
    }
}

private struct AddonRow: View {
    let item: InstalledAddon
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.addon.contents.kinds.first?.symbol ?? "puzzlepiece.extension")
                .font(.title3).foregroundStyle(item.enabled ? Color.accentColor : .secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.addon.title).font(.headline).foregroundStyle(item.enabled ? .primary : .secondary)
                    if item.official { AddonOfficialBadge() }
                }
                Text(item.addon.contents.kinds.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if !item.enabled { Text(L10n.text("Off")).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One installed add-on: what it adds, on or off, and the way to remove it.
struct AddonDetailView: View {
    let id: String
    let changed: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var item: InstalledAddon?
    @State private var confirmRemove = false
    @State private var error: String?
    private var store: AddonStore { AddonStore(env.booru) }

    var body: some View {
        List {
            if let item {
                AddonHeader(addon: item.addon, official: item.official)
                Section {
                    Toggle(L10n.text("Use This Add-on"), isOn: Binding(get: { item.enabled }, set: { setEnabled($0) }))
                        .accessibilityIdentifier("addons.enabled")
                }
                AddonContentsSections(addon: item.addon)
                AddonOriginSection(addon: item.addon, digest: item.digest, installed: item.installed, official: item.official)
                Section {
                    Button(L10n.text("Remove Add-on"), systemImage: "trash", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("addons.remove")
                } footer: {
                    if item.addon.contents.learningTrack != nil { Text(L10n.text("Lessons you finished in its track stay in your learning record.")) }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .navigationTitle(item?.addon.title ?? L10n.text("Add-ons")).navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .confirmationDialog(L10n.text("Remove this add-on?"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L10n.text("Remove Add-on"), role: .destructive) { remove() }
        } message: {
            Text(L10n.text("Everything it added is taken away, including the challenges it brought and their progress."))
        }
    }

    private func load() { item = (try? store.installed())?.first { $0.id == id } }

    private func setEnabled(_ on: Bool) {
        do { try store.setEnabled(id, on); load(); AddonRuntime.apply(env.booru); changed() }
        catch let failure { error = failure.localizedDescription }
    }

    private func remove() {
        do { try store.remove(id); AddonRuntime.apply(env.booru); changed(); dismiss() }
        catch let failure { error = failure.localizedDescription }
    }
}

/// Everything a file adds, shown before it is installed.
struct AddonInstallSheet: View {
    let candidate: AddonCandidate
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidate.official {
                        Label {
                            Text(L10n.text("An official add-on from TEGNAL. The downloaded file matched the copy TEGNAL published. It holds data only and cannot run code or connect to the internet."))
                        } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue) }
                        .font(.callout)
                        .accessibilityIdentifier("addons.officialNotice")
                    } else {
                        Label {
                            Text(L10n.text("This add-on was made by someone else. Install it only if you trust where it came from. It holds data only and cannot run code or connect to the internet."))
                        } icon: { Image(systemName: "checkmark.shield").foregroundStyle(.green) }
                        .font(.callout)
                    }
                }
                AddonHeader(addon: candidate.addon, official: candidate.official)
                if let existing = candidate.existing {
                    Section {
                        if existing.official && !candidate.official {
                            Label(L10n.text("This file is not the official copy. Installing it replaces the official add-on, which is then no longer marked as official."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("addons.replacesOfficial")
                        }
                        let order = AddonCheck.compare(candidate.addon.version, existing.addon.version)
                        let key = order == .orderedDescending ? "Updates version %@ to %@." : order == .orderedSame ? "Replaces the installed version %@ with this copy (%@)." : "This is older than the installed version %@. Installing it goes back to %@."
                        Label(L10n.text(key, existing.addon.version, candidate.addon.version), systemImage: order == .orderedAscending ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(order == .orderedAscending ? .orange : .primary)
                            .accessibilityIdentifier("addons.update")
                    }
                }
                AddonContentsSections(addon: candidate.addon)
                AddonOriginSection(addon: candidate.addon, digest: candidate.digest, installed: nil, official: candidate.official)
            }
            .navigationTitle(L10n.text("Check Before Installing")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text(candidate.existing == nil ? "Install" : "Update")) { install(); dismiss() }
                        .accessibilityIdentifier("addons.install")
                }
            }
        }
    }
}

/// The small seal shown beside an official add-on's name.
struct AddonOfficialBadge: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue)
            .accessibilityLabel(L10n.text("Official"))
            .accessibilityIdentifier("addons.officialBadge")
    }
}

private struct AddonHeader: View {
    let addon: Addon
    var official = false
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(addon.title).font(.title3.weight(.semibold)).accessibilityIdentifier("addons.name")
                    if official { AddonOfficialBadge() }
                }
                Text(L10n.text("By %@ · Version %@", addon.author, addon.version)).font(.subheadline).foregroundStyle(.secondary)
                if let summary = addon.summary?.addonResolved(), !summary.isEmpty { Text(summary).font(.callout).padding(.top, 2) }
            }.padding(.vertical, 4)
        }
    }
}

private struct AddonOriginSection: View {
    let addon: Addon
    let digest: String
    let installed: Date?
    var official = false
    var body: some View {
        Section {
            LabeledContent(L10n.text("Identifier"), value: addon.id)
            LabeledContent(L10n.text("Mode"), value: addon.mode.title).accessibilityIdentifier("addons.mode")
            LabeledContent(L10n.text("Source"), value: L10n.text(official ? "Official Add-ons" : "Opened File"))
                .accessibilityIdentifier("addons.source")
            if let installed { LabeledContent(L10n.text("Installed"), value: installed.formatted(date: .abbreviated, time: .shortened)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("File Fingerprint (SHA-256)")).font(.subheadline)
                Text(stride(from: 0, to: digest.count, by: 8).map { offset -> String in
                    let start = digest.index(digest.startIndex, offsetBy: offset)
                    return String(digest[start..<digest.index(start, offsetBy: min(8, digest.count - offset))])
                }.joined(separator: " "))
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: { Text(L10n.text("About This File")) } footer: {
            Text(L10n.text("If the maker publishes a fingerprint, it should match this one exactly."))
        }
    }
}

/// What each part of an add-on adds, with enough of it shown to judge.
struct AddonContentsSections: View {
    let addon: Addon
    private static let shown = 12

    var body: some View {
        let contents = addon.contents
        if let translations = contents.tagTranslations {
            Section {
                ForEach(translations.entries.sorted { $0.key < $1.key }.prefix(Self.shown), id: \.key) { entry in
                    LabeledContent(entry.key.replacingOccurrences(of: "_", with: " "), value: entry.value)
                }
                more(translations.entries.count)
            } header: { Label(AddonKind.translations.title, systemImage: AddonKind.translations.symbol) } footer: {
                Text(L10n.text("%@ tags, written in %@. Tags are shown in these words in place of their own names; searches still use the tags themselves.",
                               String(translations.entries.count), Self.language(translations.language)))
            }
        }
        if let search = contents.searchTags {
            Section {
                terms(L10n.text("Added to Comics Searches"), search.comics?.include ?? [])
                terms(L10n.text("Hidden from Comics Searches"), search.comics?.exclude ?? [])
                terms(L10n.text("Hidden Images (All Servers)"), search.images?.exclude ?? [], separator: "\n")
            } header: { Label(AddonKind.searchTags.title, systemImage: AddonKind.searchTags.symbol) } footer: {
                Text(L10n.text("These apply beside your own default tags and blacklists, which stay as they are."))
            }
        }
        if let games = contents.challenges {
            Section {
                ForEach(games) { game in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.title)
                        Text(L10n.text("%@ choices", String((game.reels + game.groups).reduce(0) { $0 + $1.options.count }))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Label(AddonKind.challenges.title, systemImage: AddonKind.challenges.symbol) } footer: {
                Text(L10n.text("Added to your challenge library."))
            }
        }
        if let track = contents.learningTrack {
            let lessons = track.sections.flatMap(\.lessons)
            let tags = (track.groups ?? []).reduce(0) { $0 + $1.tags.count }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title.addonResolved()).font(.headline)
                    Text(track.summary.addonResolved()).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(track.sections) { section in
                    LabeledContent(section.title.addonResolved(), value: L10n.text("%@ lessons", String(section.lessons.count)))
                }
            } header: { Label(AddonKind.track.title, systemImage: AddonKind.track.symbol) } footer: {
                Text(L10n.text("A track of %@ lessons in learning mode, finished apart from the main path.", String(lessons.count))
                     + (tags > 0 ? " " + L10n.text("It teaches %@ tags of its own.", String(tags)) : "")
                     + " " + L10n.text("Its lessons find example pictures on your chosen picture server, as the main path does."))
            }
        }
    }

    /// Blacklist rules can hold several terms, so they are listed one per line.
    @ViewBuilder private func terms(_ title: String, _ list: [String], separator: String = "  ") -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(list.prefix(40).joined(separator: separator) + (list.count > 40 ? separator + L10n.text("and %@ more", String(list.count - 40)) : ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func more(_ total: Int) -> some View {
        if total > Self.shown { Text(L10n.text("and %@ more", String(total - Self.shown))).font(.caption).foregroundStyle(.secondary) }
    }

    private static func language(_ code: String) -> String {
        switch code { case "ko": return "한국어"; case "ja": return "日本語"; default: return "English" }
    }
}

/// An official add-on's grade, drawn as a small badge beside its name.
struct AddonGradeBadge: View {
    let grade: AddonGrade
    private var color: Color {
        switch grade { case .recommended: return .green; case .suggested: return .blue; case .optional: return .gray }
    }
    var body: some View {
        Text(grade.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
            .fixedSize()
            .accessibilityIdentifier("addons.grade." + grade.rawValue)
    }
}

private struct AddonListingRow: View {
    let listing: AddonListing
    let state: AddonListingState
    let downloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: listing.addonKinds.first?.symbol ?? "puzzlepiece.extension")
                .font(.title3).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                // The badge sits beside the name when both fit on a line, and under it otherwise, so the name is never cut short.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(listing.title).font(.headline).fixedSize()
                        AddonGradeBadge(grade: listing.addonGrade)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(listing.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        AddonGradeBadge(grade: listing.addonGrade)
                    }
                }
                Text(L10n.text("By %@ · Version %@", listing.author, listing.version)).font(.caption).foregroundStyle(.secondary)
                if state == .fromFile {
                    Text(L10n.text("Installed from a File")).font(.caption).foregroundStyle(.orange)
                }
                if let summary = listing.summary?.addonResolved(), !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text((listing.addonKinds.map(\.title) + [ByteCountFormatter.string(fromByteCount: Int64(listing.size), countStyle: .file)]).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if downloading {
            ProgressView()
        } else {
            switch state {
            case .installed:
                Label(L10n.text("Installed"), systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("Installed"))
            case .unsupported:
                Text(L10n.text("Needs a Newer Version")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            case .get, .update, .fromFile:
                Text(L10n.text(state == .update ? "Update" : "Get"))
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
