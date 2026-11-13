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
    /// Comics only. New rules move, so each work sits in one place; a rule saved before the
    /// choice existed loads as copying, which is what it did.
    @State private var copies = false
    @State private var fillsSavedWorks: Bool
    @State private var loaded = false
    @State private var matches = 0
    @State private var matchesElsewhere = 0
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
                   sources: sources.map { $0.sorted() }, includesOtherFolders: everyFolder ? true : nil,
                   keepsOriginal: booru ? nil : copies)
    }
    /// How many saved works match, and how many more match where the folder does not look.
    private var matchFooter: String {
        if query.isEmpty { return L10n.text("Separate tags with spaces. Use _ for a space inside a tag.") }
        let found = L10n.text(booru ? "%@ saved images match in the folders it looks in." : "%@ saved works match in the folders it looks in.", String(matches))
        guard matchesElsewhere > 0 else { return found }
        return found + " " + L10n.text("%@ more match in other folders and stay there. Choose those folders under Look In to include them.", String(matchesElsewhere))
    }
    private var sourceFooter: String {
        if everyFolder { return L10n.text("It looks in every folder, including ones you make later.") }
        if sources == nil {
            return L10n.text(booru ? "It looks where new favorites land: Uncategorized and each site's folder. Images you filed in other folders yourself stay put."
                                   : "It looks where new saves land: Unfiled and your default save folder. Works you filed in other folders yourself stay put.")
        }
        return L10n.text(booru ? "It looks only in the folders checked here. Images in other folders stay put." : "It looks only in the folders checked here. Works in other folders stay put.")
    }
    private var actionFooter: String {
        if booru { return L10n.text("An image is in one folder at a time, so a matching image moves here from the folder it was in.") }
        return L10n.text(copies ? "A matching work is added here and also stays in the folder it came from, so it appears in both."
                                : "A matching work leaves the folder it came from, so it appears only here.")
            + " " + L10n.text("Unfiled always lets a work go once it is in a folder.")
    }
    /// The toggle files works already saved once, when Save is tapped; a smart folder alone
    /// only takes works saved after it.
    private var fillFooter: String {
        if fillsSavedWorks || !isSmart {
            if booru { return L10n.text("When you tap Save, matching images in the folders it looks in move here once.") }
            return L10n.text(copies ? "When you tap Save, matching works in the folders it looks in are copied here once."
                                    : "When you tap Save, matching works in the folders it looks in move here once.")
        }
        return L10n.text(booru ? "Only images saved from now on move here. Images you already saved stay where they are."
                               : "Only works saved from now on come here. Works you already saved stay where they are.")
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
                    Text(L10n.text(booru ? "Images you save from now on that match the tags are filed here on their own. An image you move yourself stays where you put it."
                                         : "Works you save from now on that match the tags are filed here on their own. A work you move yourself stays where you put it."))
                }
                Section {
                    LabeledContent(L10n.text("Tag")) {
                        TextField(L10n.text("Tag"), text: $tag, prompt: Text(verbatim: booru ? "landscape" : "language:korean")).tagInput().accessibilityIdentifier("folderRule.tag")
                    }
                    LabeledContent(L10n.text("Excluded Tags")) {
                        TextField(L10n.text("Excluded Tags"), text: $excluded, prompt: Text(verbatim: booru ? "monochrome" : "tag:example")).tagInput().accessibilityIdentifier("folderRule.excluded")
                    }
                } footer: {
                    Text(matchFooter).accessibilityIdentifier("folderRule.matches")
                }.disabled(!usesTags)
                Section {
                    LabeledContent(L10n.text("Look In")) { sourceMenu }
                } header: {
                    Text(L10n.text(booru ? "Where to Find Images" : "Where to Find Works"))
                } footer: {
                    Text(sourceFooter)
                }.disabled(!usesTags)
                Section {
                    if booru {
                        LabeledContent(L10n.text("Matching Images"), value: L10n.text("Move Here"))
                    } else {
                        Picker(L10n.text("Matching Works"), selection: $copies) {
                            Text(L10n.text("Move Here")).tag(false)
                            Text(L10n.text("Copy Here")).tag(true)
                        }.pickerStyle(.segmented).accessibilityIdentifier("folderRule.copies")
                    }
                } header: {
                    Text(L10n.text(booru ? "When an Image Matches" : "When a Work Matches"))
                } footer: {
                    Text(actionFooter)
                }.disabled(!usesTags)
                Section {
                    Toggle(L10n.text(booru ? "Apply to Saved Images Now" : "Apply to Saved Works Now"), isOn: $fillsSavedWorks).accessibilityIdentifier("folderRule.extends")
                } footer: {
                    Text(fillFooter)
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
            matchesElsewhere = (try? library.matchingCountElsewhere(rule)) ?? 0
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
        copies = rule.copies
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
    @State private var defaultSources: Set<String> = []
    @State private var editing: Editing?
    private var library: any SmartFolderLibrary { booru ? env.booru : env.database }

    /// What the rule does, in one line: move or copy, and from where.
    private func summary(_ rule: FolderRule) -> String {
        let places: String
        if rule.includesOtherFolders == true { places = L10n.text("All Folders") }
        else {
            let ids = rule.sources.map(Set.init) ?? defaultSources
            let list = names.filter { ids.contains($0.key) && $0.key != rule.folder }.map(\.value).sorted()
            places = list.count > 2 ? L10n.text("%@ Folders", String(list.count)) : list.joined(separator: ", ")
        }
        return L10n.text(!booru && rule.copies ? "Copies here from %@" : "Moves here from %@", places)
    }

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Use Smart Folders"), isOn: $enabled).accessibilityIdentifier("folderRules.enabled")
            } footer: { Text(L10n.text("A smart folder files new saves that match its tags. Hold a folder to make it one; smart folders show %@ after their name.", "✦")) }
            Section {
                ForEach(rules) { rule in
                    Button { editing = Editing(folder: rule.folder) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.query.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                            if !rule.excluded.isEmpty {
                                Text(L10n.text("Except %@", rule.excluded.replacingOccurrences(of: "_", with: " "))).font(.caption).foregroundStyle(.secondary)
                            }
                            Label(names[rule.folder] ?? "", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            Label(summary(rule), systemImage: !booru && rule.copies ? "plus.square.on.square" : "arrow.right.square").font(.caption).foregroundStyle(.secondary)
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
        defaultSources = (try? library.defaultRuleSources()) ?? []
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

/// One folder in a picker, from either library.
struct FolderPickerRow: Identifiable {
    let id: String
    let name: String
    let color: Int64
    let isCurrent: Bool
}

/// The folder list both modes show when a saved work changes folder: a new folder first, then
/// every folder with its color, the current one checked. Tapping a folder is the whole action.
struct FolderPickerSheet: View {
    let rows: [FolderPickerRow]
    let identifier: String
    let pick: (FolderPickerRow) -> Void
    /// Makes a folder and files the work in it.
    let create: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: {
                    Label(L10n.text("Create New Folder…"), systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier(identifier + ".create")
                ForEach(rows) { row in
                    Button { pick(row); dismiss() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(Color(argb: row.color)).frame(width: 24)
                            Text(row.name).foregroundStyle(.primary)
                            Spacer()
                            if row.isCurrent { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.subheadline.bold()) }
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier + "." + row.id)
                    .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
                }
            }
            .navigationTitle(L10n.text("Save to Folder")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
            .background {
                FolderNameAlert(isPresented: $creating, name: $newName) { name in
                    create(name); dismiss()
                }.frame(width: 0, height: 0)
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct WorkFolderSheet: View {
    let galleryID: Int64
    let filed: (String) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var folders: [Folder] = []

    var body: some View {
        FolderPickerSheet(rows: folders.compactMap { folder in
            folder.id.map { FolderPickerRow(id: String($0), name: folder.displayName, color: folder.color, isCurrent: $0 == env.savedFolders[galleryID]) }
        }, identifier: "workFolder", pick: { row in
            if let folder = folders.first(where: { $0.id.map(String.init) == row.id }) { file(in: folder) }
        }, create: { name in
            if let folder = try? env.database.createFolder(name: name) { file(in: folder) }
        })
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
    }
}
