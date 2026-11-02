import SwiftUI

/// The folder a long press opened, by its sync identity.
struct SmartFolderTarget: Identifiable { let id: String }

/// A new smart folder, carrying the name typed before asking for one.
struct SmartFolderDraft: Identifiable {
    let name: String
    var id: String { name }
}

/// Makes a new folder from a tag, or sets up the smart folder of one that exists.
struct FolderRuleEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private let booru: Bool
    private let creatingFolder: Bool
    private let fixedFolder: Bool
    @State private var name: String
    @State private var tag: String
    @State private var excluded = ""
    @State private var choices: [SmartFolderChoice] = []
    @State private var openFolders: [SmartFolderChoice] = []
    @State private var defaultSources: Set<String> = []
    @State private var folder: String?
    @State private var isSmart: Bool
    /// Stays nil until a person picks, so the rule keeps following the default save folder.
    @State private var sources: Set<String>?
    @State private var everyFolder = false
    @State private var fillsSavedWorks: Bool
    @State private var loaded = false
    @State private var matches = 0
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    /// A new folder, filled from the tag a search already holds or kept filling as a smart folder.
    init(booru: Bool = false, name: String = "", tag: String = "", smart: Bool = true) {
        self.booru = booru
        creatingFolder = true
        fixedFolder = false
        _name = State(initialValue: name)
        _tag = State(initialValue: tag)
        _isSmart = State(initialValue: smart)
        _fillsSavedWorks = State(initialValue: true)
    }

    /// An existing folder, or a choice of folders when none is given.
    init(booru: Bool = false, folder: String?) {
        self.booru = booru
        creatingFolder = false
        fixedFolder = folder != nil
        _name = State(initialValue: "")
        _tag = State(initialValue: "")
        _folder = State(initialValue: folder)
        _isSmart = State(initialValue: true)
        _fillsSavedWorks = State(initialValue: false)
    }

    private var library: any SmartFolderLibrary { booru ? env.booru : env.database }
    private var query: WorkQuery { WorkQuery(tag, excluding: excluded) }
    private var usesTags: Bool { creatingFolder || isSmart }
    private var sourceChoices: [SmartFolderChoice] { choices.filter { $0.id != folder } }
    private var selected: Set<String> { (sources ?? defaultSources).subtracting(folder.map { [$0] } ?? []) }
    private var sourceSummary: String {
        if everyFolder { return L10n.text("All Folders") }
        let names = sourceChoices.filter { selected.contains($0.id) }.map(\.name)
        return names.count > 2 ? L10n.text("%@ Folders", String(names.count)) : names.joined(separator: ", ")
    }
    private var rule: FolderRule {
        FolderRule(folder: folder ?? "", query: tag, excluded: excluded, isEnabled: isSmart ? nil : false,
                   sources: sources.map { $0.sorted() }, includesOtherFolders: everyFolder ? true : nil)
    }
    private var canSave: Bool {
        if creatingFolder { return !query.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return folder != nil && (!query.isEmpty || !isSmart)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if creatingFolder {
                        TextField(L10n.text("Folder Name"), text: $name).focused($nameFocused).accessibilityIdentifier("folderRule.name")
                    } else if fixedFolder {
                        LabeledContent(L10n.text("Folder"), value: choices.first { $0.id == folder }?.name ?? "")
                    } else if openFolders.isEmpty {
                        Text(L10n.text("Create a folder to organize your works.")).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.text("Folder"), selection: $folder) {
                            ForEach(openFolders) { Text($0.name).tag(Optional($0.id)) }
                        }.accessibilityIdentifier("folderRule.folder")
                    }
                }
                Section {
                    Toggle(L10n.text("Smart Folder"), isOn: $isSmart).accessibilityIdentifier("folderRule.smart")
                } footer: {
                    Text(L10n.text("New saves with these tags come here on their own. A work you move yourself stays where you put it, even if its tags differ."))
                }
                Section {
                    LabeledContent(L10n.text("Tag")) {
                        TextField(L10n.text("Tag"), text: $tag, prompt: Text(verbatim: booru ? "landscape" : "language:korean")).tagInput().accessibilityIdentifier("folderRule.tag")
                    }
                    LabeledContent(L10n.text("Excluded Tags")) {
                        TextField(L10n.text("Excluded Tags"), text: $excluded, prompt: Text(verbatim: booru ? "monochrome" : "tag:example")).tagInput().accessibilityIdentifier("folderRule.excluded")
                    }
                } footer: {
                    Text(query.isEmpty ? L10n.text("Separate tags with spaces. Use _ for a space inside a tag.") : L10n.text("%@ saved works match.", String(matches)))
                        .accessibilityIdentifier("folderRule.matches")
                }.disabled(!usesTags)
                Section {
                    LabeledContent(L10n.text("Take Works From")) { sourceMenu }
                    Toggle(L10n.text("Apply to Saved Works"), isOn: $fillsSavedWorks).accessibilityIdentifier("folderRule.extends")
                } footer: {
                    Text(L10n.text(booru ? "Matching images move here from the folders you choose." : "Matching works from the folders you choose are added here. They stay in those folders too."))
                }.disabled(!usesTags)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.text(creatingFolder ? "New Folder" : "Smart Folder")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save"), action: save).disabled(!canSave).accessibilityIdentifier("folderRule.save")
                }
            }
            .alert(L10n.text("Error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(L10n.text("OK"), role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.large])
        .task { load() }
        .task(id: rule) {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            matches = (try? library.matchingCount(rule)) ?? 0
        }
    }

    private var sourceMenu: some View {
        Menu {
            Toggle(L10n.text("All Folders"), isOn: $everyFolder)
            Divider()
            ForEach(sourceChoices) { choice in
                Toggle(choice.name, isOn: Binding(get: { everyFolder || selected.contains(choice.id) }, set: { isOn in
                    var next = selected
                    if isOn { next.insert(choice.id) } else { next.remove(choice.id) }
                    sources = next
                })).disabled(everyFolder || selected == [choice.id])
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceSummary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
        }.menuActionDismissBehavior(.disabled).accessibilityIdentifier("folderRule.sources")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        choices = (try? library.folderChoices()) ?? []
        defaultSources = (try? library.defaultRuleSources()) ?? []
        if creatingFolder { nameFocused = name.isEmpty; return }
        let taken = Set(((try? library.smartRules()) ?? []).map(\.folder))
        openFolders = choices.filter { $0.canBeSmart && !taken.contains($0.id) }
        if folder == nil { folder = openFolders.first?.id }
        guard let folder, let rule = try? library.rule(forFolder: folder) else { return }
        tag = rule.query
        excluded = rule.excluded
        isSmart = rule.isActive
        everyFolder = rule.includesOtherFolders == true
        let existing = rule.sources.map { Set($0).intersection(choices.map(\.id)) }
        sources = existing?.isEmpty == false ? existing : nil
    }

    private func save() {
        do {
            let target = creatingFolder ? try library.createRuleFolder(named: name) : folder
            guard let target else { return }
            var saved = rule
            saved.folder = target
            if !saved.workQuery.isEmpty, !creatingFolder || isSmart { try library.saveRule(saved) }
            else if !creatingFolder { try library.deleteRule(forFolder: target) }
            if usesTags, fillsSavedWorks { try library.fill(saved) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    func tagInput() -> some View { multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never) }
}

struct FolderRulesView: View {
    private struct Editing: Identifiable {
        let folder: String?
        var id: String { folder ?? "new" }
    }
    var booru = false
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(LibrarySavePreferences.rulesEnabledKey, store: ReaderPreferences.defaults) private var enabled = true
    @State private var rules: [FolderRule] = []
    @State private var names: [String: String] = [:]
    @State private var editing: Editing?
    private var library: any SmartFolderLibrary { booru ? env.booru : env.database }

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Use Smart Folders"), isOn: $enabled).accessibilityIdentifier("folderRules.enabled")
            } footer: { Text(L10n.text("Hold a folder to make it a smart folder. Smart folders show %@ after their name.", "✦")) }
            Section {
                ForEach(rules) { rule in
                    Button { editing = Editing(folder: rule.folder) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.query.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                            if !rule.excluded.isEmpty {
                                Text(L10n.text("Except %@", rule.excluded.replacingOccurrences(of: "_", with: " "))).font(.caption).foregroundStyle(.secondary)
                            }
                            Label(names[rule.folder] ?? "", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            if !rule.isActive { Text(L10n.text("Off")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("folderRules.rule." + rule.id)
                }
                .onDelete { offsets in
                    for index in offsets { try? library.deleteRule(forFolder: rules[index].folder) }
                    reload()
                }
                if rules.isEmpty { Text(L10n.text("No smart folders yet.")).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(L10n.text("Smart Folders")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = Editing(folder: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("Add Smart Folder")).accessibilityIdentifier("folderRules.add")
            }
        }
        .task { reload() }
        .appSheet(item: $editing, onDismiss: reload) { FolderRuleEditor(booru: booru, folder: $0.folder) }
    }

    private func reload() {
        rules = (try? library.smartRules()) ?? []
        names = Dictionary(((try? library.folderChoices()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

struct SavedWorksSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(LibrarySavePreferences.defaultFolderKey, store: ReaderPreferences.defaults) private var defaultFolder = ""
    @State private var folders: [Folder] = []
    private var selection: Binding<Int64> {
        Binding(get: { (try? env.database.defaultSaveFolder().id) ?? 0 }, set: { defaultFolder = (try? env.database.identity(ofFolder: $0)) ?? "" })
    }
    var body: some View {
        Section(L10n.text("Saved Works")) {
            Picker(L10n.text("Default Save Folder"), selection: selection) {
                ForEach(folders) { Text($0.displayName).tag($0.id ?? 0) }
            }.accessibilityIdentifier("settings.defaultFolder")
            NavigationLink { FolderRulesView() } label: { Text(L10n.text("Smart Folders")) }
                .accessibilityIdentifier("settings.folderRules")
        }
        .task { folders = (try? env.database.listFolders()) ?? [] }
    }
}

/// Moves a work that was just saved. Tapping a folder is the whole action.
struct WorkFolderTarget: Identifiable { let id: Int64 }

struct WorkFolderSheet: View {
    let galleryID: Int64
    let filed: (String) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [Folder] = []
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label(L10n.text("Create New Folder…"), systemImage: "folder.badge.plus") }
                ForEach(folders) { folder in
                    Button { file(in: folder) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(Color(argb: folder.color)).frame(width: 12, height: 12)
                            Text(folder.displayName).foregroundStyle(.primary)
                            Spacer()
                            if folder.id == env.savedFolders[galleryID] { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.subheadline.bold()) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("workFolder." + folder.name)
                }
            }
            .navigationTitle(L10n.text("Save to Folder")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
            .background {
                FolderNameAlert(isPresented: $creating, name: $newName) { name in
                    if let folder = try? env.database.createFolder(name: name) { file(in: folder) }
                }.frame(width: 0, height: 0)
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .task { folders = (try? env.database.listFolders()) ?? [] }
    }

    private func file(in folder: Folder) {
        guard let id = folder.id else { return }
        do {
            let current = env.savedFolders[galleryID]
            if id != current { try env.database.moveWorkToFolder(galleryId: galleryID, targetFolderId: id, currentFolderId: current) }
            env.savedFolders[galleryID] = id
            filed(folder.displayName)
        } catch {}
        dismiss()
    }
}
