import SwiftUI

/// Creates a folder from a tag, or writes a rule for one that exists.
struct FolderRuleEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    private let creatingFolder: Bool
    private let ruleID: String?
    @State private var name = ""
    @State private var tag: String
    @State private var excluded: String
    @State private var folders: [Folder] = []
    @State private var folderID: Int64?
    /// Keeps a new folder filling up, or runs a new rule over works already saved.
    @State private var extends = false
    @State private var includesOtherFolders: Bool
    @State private var matches = 0
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    /// A new folder, optionally filled from the tag a search already holds.
    init(tag: String = "") {
        creatingFolder = true
        ruleID = nil
        _tag = State(initialValue: tag)
        _excluded = State(initialValue: "")
        _includesOtherFolders = State(initialValue: false)
    }

    /// A rule for an existing folder.
    init(rule: FolderRule?, folderID: Int64?) {
        creatingFolder = false
        ruleID = rule?.id
        _tag = State(initialValue: rule?.query ?? "")
        _excluded = State(initialValue: rule?.excluded ?? "")
        _includesOtherFolders = State(initialValue: rule?.includesOtherFolders == true)
        _folderID = State(initialValue: folderID)
    }

    private var query: WorkQuery { WorkQuery(tag, excluding: excluded) }
    private var canSave: Bool {
        guard !query.isEmpty else { return false }
        return creatingFolder ? !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : folderID != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if creatingFolder {
                        TextField(L10n.text("Folder Name"), text: $name).focused($nameFocused).accessibilityIdentifier("folderRule.name")
                    } else {
                        if folders.isEmpty { Text(L10n.text("Create a folder to organize your works.")).foregroundStyle(.secondary) }
                        else {
                            Picker(L10n.text("Folder"), selection: $folderID) {
                                ForEach(folders) { Text($0.displayName).tag($0.id) }
                            }.accessibilityIdentifier("folderRule.folder")
                        }
                    }
                }
                Section {
                    LabeledContent(L10n.text("Tag")) {
                        TextField(L10n.text("Tag"), text: $tag, prompt: Text(verbatim: "language:korean")).tagInput().accessibilityIdentifier("folderRule.tag")
                    }
                    LabeledContent(L10n.text("Excluded Tags")) {
                        TextField(L10n.text("Excluded Tags"), text: $excluded, prompt: Text(verbatim: "tag:example")).tagInput().accessibilityIdentifier("folderRule.excluded")
                    }
                } footer: {
                    Text(query.isEmpty ? L10n.text("Separate tags with spaces. Use _ for a space inside a tag.") : L10n.text("%@ saved works match.", String(matches)))
                        .accessibilityIdentifier("folderRule.matches")
                }
                Section {
                    Toggle(L10n.text(creatingFolder ? "Also Add New Saves" : "Apply to Saved Works"), isOn: $extends).accessibilityIdentifier("folderRule.extends")
                    Toggle(L10n.text("Include Other Folders"), isOn: $includesOtherFolders).accessibilityIdentifier("folderRule.otherFolders")
                } footer: {
                    Text(L10n.text("Only Unfiled works are added. Turn this on to add works from other folders too. They stay in those folders."))
                }
            }
            .navigationTitle(L10n.text(creatingFolder ? "New Folder" : "Classification Rule")).navigationBarTitleDisplayMode(.inline)
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
        .presentationDetents([.medium, .large])
        .task {
            folders = ((try? env.database.listFolders()) ?? []).filter { $0.name != "미분류" }
            if creatingFolder { nameFocused = true } else if folderID == nil { folderID = folders.first?.id }
        }
        .task(id: "\(tag)\u{0}\(excluded)\u{0}\(includesOtherFolders)") {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            matches = (try? env.database.matchingWorkCount(query, includingOtherFolders: includesOtherFolders)) ?? 0
        }
    }

    private func save() {
        do {
            let target = creatingFolder ? try env.database.createFolder(name: name).id : folderID
            guard let target else { return }
            if creatingFolder || extends { try env.database.addMatchingWorks(query, toFolder: target, includingOtherFolders: includesOtherFolders) }
            if !creatingFolder || extends {
                try env.database.saveFolderRule(id: ruleID, folderID: target, query: tag, excluded: excluded, includesOtherFolders: includesOtherFolders)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    func tagInput() -> some View { multilineTextAlignment(.trailing).autocorrectionDisabled().textInputAutocapitalization(.never) }
}

struct FolderRulesView: View {
    private struct Editing: Identifiable {
        let rule: FolderRule?
        let folderID: Int64?
        var id: String { rule?.id ?? "new" }
    }
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(LibrarySavePreferences.rulesEnabledKey, store: ReaderPreferences.defaults) private var enabled = true
    @State private var rules: [(rule: FolderRule, folder: Folder)] = []
    @State private var editing: Editing?

    var body: some View {
        List {
            Section {
                Toggle(L10n.text("Classify New Saves"), isOn: $enabled).accessibilityIdentifier("folderRules.enabled")
            } footer: { Text(L10n.text("A work saved to Unfiled with a rule's tag moves to that rule's folder. Works in other folders stay put unless the rule includes them.")) }
            Section {
                ForEach(rules, id: \.rule.id) { item in
                    Button { editing = Editing(rule: item.rule, folderID: item.folder.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.rule.query.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                            if !item.rule.excluded.isEmpty {
                                Text(L10n.text("Except %@", item.rule.excluded.replacingOccurrences(of: "_", with: " "))).font(.caption).foregroundStyle(.secondary)
                            }
                            Label(item.folder.displayName, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            if item.rule.includesOtherFolders == true {
                                Text(L10n.text("Include Other Folders")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("folderRules.rule." + item.rule.id)
                }
                .onDelete { offsets in
                    for index in offsets { try? env.database.deleteFolderRule(id: rules[index].rule.id) }
                    reload()
                }
                if rules.isEmpty { Text(L10n.text("No rules yet.")).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(L10n.text("Automatic Classification")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = Editing(rule: nil, folderID: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L10n.text("Add Rule")).accessibilityIdentifier("folderRules.add")
            }
        }
        .task { reload() }
        .appSheet(item: $editing, onDismiss: reload) { FolderRuleEditor(rule: $0.rule, folderID: $0.folderID) }
    }

    private func reload() { rules = (try? env.database.folderRules()) ?? [] }
}

struct SavedWorksSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @SwiftUI.AppStorage(LibrarySavePreferences.defaultFolderKey, store: ReaderPreferences.defaults) private var defaultFolder = 0
    @State private var folders: [Folder] = []
    private var selection: Binding<Int64> {
        Binding(get: { (try? env.database.defaultSaveFolder().id) ?? 0 }, set: { defaultFolder = Int($0) })
    }
    var body: some View {
        Section(L10n.text("Saved Works")) {
            Picker(L10n.text("Default Save Folder"), selection: selection) {
                ForEach(folders) { Text($0.displayName).tag($0.id ?? 0) }
            }.accessibilityIdentifier("settings.defaultFolder")
            NavigationLink { FolderRulesView() } label: { Text(L10n.text("Automatic Classification")) }
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
