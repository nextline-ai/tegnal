import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.tegnaladdon`, a JSON file. Plain `.json` add-ons open as well.
    static let tegnalAddon = UTType(exportedAs: "work.nextline.tegnal.addon", conformingTo: .json)
}

/// The settings row that leads to the add-ons, in both modes' settings.
struct AddonsSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink { AddonsView() } label: {
                LabeledContent {
                    let count = AddonRuntime.shared.effects.enabledIDs.count
                    if count > 0 { Text(String(count)) }
                } label: { Label(L10n.text("Add-ons"), systemImage: "puzzlepiece.extension") }
            }.accessibilityIdentifier("settings.addons")
        }
    }
}

/// A checked add-on waiting for the learner to decide.
private struct AddonCandidate: Identifiable {
    let addon: Addon
    let digest: String
    let existing: InstalledAddon?
    var id: String { addon.id + digest }
}

struct AddonsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var installed: [InstalledAddon] = []
    @State private var picking = false
    @State private var reading = false
    @State private var candidate: AddonCandidate?
    @State private var error: String?
    private var store: AddonStore { AddonStore(env.booru) }

    var body: some View {
        List {
            Section {
                Button { picking = true } label: { Label(L10n.text("Open Add-on File"), systemImage: "doc.badge.plus") }
                    .disabled(reading)
                    .accessibilityIdentifier("addons.import")
            } footer: {
                Text(L10n.text("Add-ons are files made by other people that you download yourself. They hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything a file adds before it is installed."))
            }
            if installed.isEmpty {
                Section {
                    ContentUnavailableView(L10n.text("No Add-ons"), systemImage: "puzzlepiece.extension",
                                           description: Text(L10n.text("Open a .tegnaladdon file to add tag translations, search tags, challenges or learning tracks.")))
                }
            } else {
                Section {
                    ForEach(installed) { item in
                        NavigationLink { AddonDetailView(id: item.id, changed: reload) } label: { AddonRow(item: item) }
                            .accessibilityIdentifier("addons.row." + item.id)
                    }
                } header: { Text(L10n.text("Installed")) } footer: {
                    Text(L10n.text("Turning an add-on off or removing it takes back everything it added. Your own settings are never changed."))
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).accessibilityIdentifier("addons.error") }
            }
        }
        .navigationTitle(L10n.text("Add-ons")).navigationBarTitleDisplayMode(.inline)
        .overlay { if reading { ProgressView() } }
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
                    try store.install(candidate.addon, digest: candidate.digest)
                    error = nil
                    applyChanges()
                } catch let failure { error = failure.localizedDescription }
            }
        }
    }

    private func open(_ url: URL) {
        reading = true
        Task {
            defer { reading = false }
            do {
                let (addon, digest) = try await Task.detached { try Addon.read(url) }.value
                error = nil
                candidate = AddonCandidate(addon: addon, digest: digest, existing: installed.first { $0.id == addon.id })
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func reload() { installed = ((try? store.installed()) ?? []).reversed() }

    private func applyChanges() {
        reload()
        AddonRuntime.apply(env.booru)
    }
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
                Text(item.addon.title).font(.headline).foregroundStyle(item.enabled ? .primary : .secondary)
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
                AddonHeader(addon: item.addon)
                Section {
                    Toggle(L10n.text("Use This Add-on"), isOn: Binding(get: { item.enabled }, set: { setEnabled($0) }))
                        .accessibilityIdentifier("addons.enabled")
                }
                AddonContentsSections(addon: item.addon)
                AddonOriginSection(addon: item.addon, digest: item.digest, installed: item.installed)
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
private struct AddonInstallSheet: View {
    let candidate: AddonCandidate
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text(L10n.text("This add-on was made by someone else. Install it only if you trust where it came from. It holds data only and cannot run code or connect to the internet."))
                    } icon: { Image(systemName: "checkmark.shield").foregroundStyle(.green) }
                    .font(.callout)
                }
                AddonHeader(addon: candidate.addon)
                if let existing = candidate.existing {
                    Section {
                        let order = AddonCheck.compare(candidate.addon.version, existing.addon.version)
                        let key = order == .orderedDescending ? "Updates version %@ to %@." : order == .orderedSame ? "Replaces the installed version %@ with this copy (%@)." : "This is older than the installed version %@. Installing it goes back to %@."
                        Label(L10n.text(key, existing.addon.version, candidate.addon.version), systemImage: order == .orderedAscending ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(order == .orderedAscending ? .orange : .primary)
                            .accessibilityIdentifier("addons.update")
                    }
                }
                AddonContentsSections(addon: candidate.addon)
                AddonOriginSection(addon: candidate.addon, digest: candidate.digest, installed: nil)
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

private struct AddonHeader: View {
    let addon: Addon
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(addon.title).font(.title3.weight(.semibold)).accessibilityIdentifier("addons.name")
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
    var body: some View {
        Section {
            LabeledContent(L10n.text("Identifier"), value: addon.id)
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
private struct AddonContentsSections: View {
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
