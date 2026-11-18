import SwiftUI

/// Writes a prompt and has Civitai draw it, with the user's own API key and models named by AIR.
struct GeneratorView: View {
    @Environment(BooruStore.self) private var library
    @State private var store = GenerationStore.shared
    @State private var run = GenerationRun()
    @State private var prompt: String
    @State private var estimate: Double?
    @State private var showingAccount = false
    @State private var opened: GeneratedPicture?
    /// Pictures generated so far, ever: the advanced settings open after the first few.
    @State private var made = 0
    @State private var showsAdvanced = ReaderPreferences.booruDefaults.object(forKey: GeneratorView.advancedKey) as? Bool ?? true

    static let advancedKey = "generation.showsAdvanced"

    init(prompt: String = "") { _prompt = State(initialValue: prompt) }

    /// A beginner sees a prompt, a model and a button. Size, steps, LoRAs and the rest open once a few pictures are made.
    private var unlocked: Bool { made >= StudyAward.advancedPictures }
    private var advanced: Bool { unlocked && showsAdvanced }

    private var settings: GenerationSettings { store.settings }
    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Safe Mode never asks for mature results, whatever the switch says.
    private var sent: GenerationSettings { var value = settings; if library.safeMode { value.mature = false }; return value }
    private var cost: String { L10n.text("About %@ Buzz", String(Int((estimate ?? Double(settings.roughCost)).rounded(.up)))) }
    /// What a cost estimate depends on, so that typing a prompt does not ask for a new one.
    private var priced: [String] {
        [settings.model?.air ?? "", "\(settings.width)x\(settings.height)", String(settings.steps), String(settings.quantity), String(sent.mature), String(store.hasKey)]
            + settings.loras.map { $0.model.air }
    }

    var body: some View {
        @Bindable var store = store
        ScrollViewReader { proxy in
        List {
            if !store.hasKey {
                Section {
                    Button { showingAccount = true } label: { Label(L10n.text("Add Your Civitai API Key"), systemImage: "key") }
                        .accessibilityIdentifier("generator.addKey")
                } footer: { Text(L10n.text("Pictures are drawn by Civitai on your own account and paid for with your Buzz. The key stays in this device's keychain.")) }
            }
            Section {
                TextEditor(text: $prompt).font(.callout.monospaced()).frame(minHeight: 120)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("generator.prompt")
                Menu {
                    ForEach(GenerationPreset.all) { preset in
                        Button(preset.name) {
                            prompt = preset.applied(to: prompt)
                            store.settings.negative = preset.negative; store.settings.steps = preset.steps; store.settings.guidance = preset.guidance
                        }
                    }
                } label: { Label(L10n.text("Apply a Model's Recommended Tags"), systemImage: "sparkles") }
                    .accessibilityIdentifier("generator.preset")
            } header: { Text(L10n.text("Prompt")) } footer: {
                if advanced { Text(L10n.text("Round brackets are read as emphasis, as in (rain:1.3). Brackets that belong to a tag are written \\( and \\).")) }
            }
            if advanced {
                Section(L10n.text("Things to Avoid")) {
                    TextEditor(text: $store.settings.negative).font(.callout.monospaced()).frame(minHeight: 72)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("generator.negative")
                }
            }
            Section {
                NavigationLink { GeneratorModelPicker(kind: .checkpoint) { store.settings.use($0) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.model?.name ?? L10n.text("Choose a Model")).font(.body.weight(.medium))
                            .foregroundStyle(settings.model == nil ? StudyStyle.accent : Color.primary)
                        if let model = settings.model {
                            Text([model.base, model.air].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }.accessibilityIdentifier("generator.model")
                if advanced {
                ForEach($store.settings.loras) { $lora in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lora.model.name).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.2f", lora.strength)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $lora.strength, in: 0...1.5, step: 0.05)
                    }
                }.onDelete { store.settings.loras.remove(atOffsets: $0) }
                NavigationLink { GeneratorModelPicker(kind: .lora) { model in
                    if !store.settings.loras.contains(where: { $0.model.air == model.air }) { store.settings.loras.append(.init(model: model)) }
                } } label: { Label(L10n.text("Add a LoRA"), systemImage: "plus") }
                }
            } header: { Text(L10n.text("Model")) }
            if advanced { options }
            if unlocked {
                Section {
                    Toggle(L10n.text("Show Advanced Settings"), isOn: $showsAdvanced.animation()).accessibilityIdentifier("generator.advancedToggle")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("Advanced Settings"), systemImage: "lock.fill").font(.subheadline.weight(.semibold))
                        Text(L10n.text("Size, steps, LoRAs and things to avoid open once you have generated %@ pictures. Until then the recommended settings are used.", String(StudyAward.advancedPictures)))
                            .font(.footnote).foregroundStyle(.secondary)
                        ProgressView(value: Double(min(made, StudyAward.advancedPictures)), total: Double(StudyAward.advancedPictures))
                        Text(verbatim: "\(min(made, StudyAward.advancedPictures)) / \(StudyAward.advancedPictures)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("generator.advancedLocked")
            }
            Section {
                Button(action: generate) {
                    HStack(spacing: 8) {
                        if run.isRunning { ProgressView().tint(.white) } else { Image(systemName: "wand.and.stars") }
                        Text(run.isRunning ? status : L10n.text("Generate")).font(.headline)
                        if !run.isRunning, store.hasKey, settings.model != nil { Text("· " + cost).font(.subheadline).opacity(0.85) }
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(StudyStyle.accent).disabled(run.isRunning || trimmed.isEmpty)
                .accessibilityIdentifier("generator.generate")
                if run.isRunning {
                    Button(L10n.text("Cancel"), role: .destructive) { run.cancel(store: store) }.frame(maxWidth: .infinity)
                }
                if let error = run.error {
                    Label(error.message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("generator.error").id("generate")
                }
            } footer: {
                if let spent = run.lastCost, !run.isRunning { Text(L10n.text("The last request cost %@ Buzz.", String(Int(spent.rounded(.up))))) }
            }
            if !run.made.isEmpty {
                Section(L10n.text("Results")) {
                    GeneratedGrid(pictures: run.made, store: store) { opened = $0 }
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)).id("results")
                }
            }
            if !store.pictures.isEmpty {
                Section {
                    NavigationLink { GeneratedGalleryView() } label: {
                        HStack { Label(L10n.text("Generated Pictures"), systemImage: "photo.on.rectangle"); Spacer(); Text(String(store.pictures.count)).foregroundStyle(.secondary) }
                    }.accessibilityIdentifier("generator.gallery")
                }
            }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        // A finished picture, or the reason there is none, appears below the settings, so it is brought into view.
        .onChange(of: run.made.count) { old, new in
            guard new > old else { return }
            count()
            Task { try? await Task.sleep(for: .milliseconds(150)); withAnimation { proxy.scrollTo("results", anchor: .bottom) } }
        }
        .onChange(of: run.error) { _, error in
            guard error != nil else { return }
            Task { try? await Task.sleep(for: .milliseconds(150)); withAnimation { proxy.scrollTo("generate", anchor: .bottom) } }
        }
        }
        .navigationTitle(L10n.text("Generate a Picture")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAccount = true } label: { Image(systemName: store.hasKey ? "key.fill" : "key") }
                    .accessibilityLabel(L10n.text("Civitai API Key")).accessibilityIdentifier("generator.account")
            }
        }
        .onAppear(perform: count)
        .onChange(of: showsAdvanced) { _, shown in ReaderPreferences.booruDefaults.set(shown, forKey: Self.advancedKey) }
        .sheet(isPresented: $showingAccount) { NavigationStack { GeneratorAccountView() } }
        .sheet(item: $opened) { picture in NavigationStack { GeneratedPictureView(picture: picture) { run.forget(picture) } } }
        .task(id: priced) {
            estimate = nil
            guard store.hasKey, settings.model != nil, !trimmed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            estimate = try? await store.client().estimate(prompt: trimmed, settings: sent)
        }
    }

    /// Reads how many pictures have ever been generated. Deleting pictures later does not lock the settings again.
    private func count() {
        try? library.studyStore.raise(StudyCounter.pictures, to: store.pictures.count)
        withAnimation { made = (try? library.studyStore.stats())?[StudyCounter.pictures] ?? store.pictures.count }
    }

    private var status: String {
        switch run.phase {
        case .queued: L10n.text("Waiting in Line…")
        case .drawing: L10n.text("Drawing…")
        case .saving: L10n.text("Saving…")
        default: L10n.text("Sending…")
        }
    }

    @ViewBuilder private var options: some View {
        @Bindable var store = store
        Section(L10n.text("Settings")) {
            Picker(L10n.text("Size"), selection: Binding(get: { "\(settings.width)x\(settings.height)" }, set: { value in
                if let size = GenerationSettings.sizes.first(where: { "\($0.width)x\($0.height)" == value }) { store.settings.width = size.width; store.settings.height = size.height }
            })) {
                ForEach(GenerationSettings.sizes, id: \.width) { size in
                    Text(verbatim: "\(size.width) × \(size.height)").tag("\(size.width)x\(size.height)")
                }
            }
            Stepper(value: $store.settings.steps, in: GenerationSettings.stepRange) { row(L10n.text("Steps"), String(settings.steps)) }
            VStack(alignment: .leading, spacing: 4) {
                row(L10n.text("Guidance (CFG)"), String(format: "%.1f", settings.guidance))
                Slider(value: $store.settings.guidance, in: 1...12, step: 0.5)
            }
            Picker(L10n.text("Sampler"), selection: $store.settings.sampler) {
                ForEach(GenerationSettings.samplers, id: \.self) { Text(Self.samplerName($0)).tag($0) }
            }
            Picker(L10n.text("Schedule"), selection: $store.settings.schedule) {
                ForEach(GenerationSettings.schedules, id: \.self) { Text(["simple": "Simple", "discrete": "Discrete", "karras": "Karras"][$0] ?? "SGM Uniform").tag($0) }
            }
            Stepper(value: $store.settings.quantity, in: GenerationSettings.quantityRange) { row(L10n.text("Pictures"), String(settings.quantity)) }
            Toggle(L10n.text("Random Seed"), isOn: Binding(get: { settings.seed == nil }, set: { store.settings.seed = $0 ? nil : Int64.random(in: 0...4_294_967_295) }))
            if settings.seed != nil {
                TextField(L10n.text("Seed"), text: Binding(get: { settings.seed.map(String.init) ?? "" }, set: { store.settings.seed = Int64($0.filter(\.isNumber)) ?? 0 }))
                    .keyboardType(.numberPad).font(.body.monospaced())
            }
            if !library.safeMode {
                Toggle(L10n.text("Allow Mature Results"), isOn: $store.settings.mature)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }
    }

    static func samplerName(_ value: String) -> String {
        ["euler_a": "Euler a", "euler": "Euler", "dpm++2m": "DPM++ 2M", "dpm++2s_a": "DPM++ 2S a", "lcm": "LCM"][value] ?? value
    }

    private func generate() {
        guard store.hasKey else { showingAccount = true; return }
        run.start(prompt: trimmed, settings: sent, store: store)
    }
}

/// Generated pictures side by side.
struct GeneratedGrid: View {
    let pictures: [GeneratedPicture]
    let store: GenerationStore
    let open: (GeneratedPicture) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(pictures) { picture in
                Button { open(picture) } label: {
                    Color(uiColor: .tertiarySystemFill)
                        .aspectRatio(CGFloat(max(picture.width, 1)) / CGFloat(max(picture.height, 1)), contentMode: .fit)
                        .overlay { if let image = UIImage(contentsOfFile: store.url(picture).path) { Image(uiImage: image).resizable().scaledToFill() } }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Generated Picture")).accessibilityIdentifier("generator.result")
            }
        }
    }
}

struct GeneratedGalleryView: View {
    @State private var store = GenerationStore.shared
    @State private var opened: GeneratedPicture?
    var body: some View {
        ScrollView {
            GeneratedGrid(pictures: store.pictures, store: store) { opened = $0 }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.text("Generated Pictures")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $opened) { picture in NavigationStack { GeneratedPictureView(picture: picture) {} } }
    }
}

/// One generated picture with what it was made from.
struct GeneratedPictureView: View {
    let picture: GeneratedPicture
    let removed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = GenerationStore.shared
    @State private var copied = false
    @State private var confirming = false
    var body: some View {
        List {
            Section {
                if let image = UIImage(contentsOfFile: store.url(picture).path) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets()).accessibilityIdentifier("generator.picture")
                }
            }
            Section {
                ShareLink(item: store.url(picture)) { Label(L10n.text("Share or Save"), systemImage: "square.and.arrow.up") }
                Button {
                    UIPasteboard.general.string = picture.prompt; copied = true
                    Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
                } label: { Label(L10n.text(copied ? "Copied" : "Copy Prompt"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button {
                    var settings = store.settings
                    settings.negative = picture.negative; settings.width = picture.width; settings.height = picture.height
                    settings.steps = picture.steps; settings.guidance = picture.guidance; settings.seed = picture.seed
                    if !picture.model.isEmpty { settings.use(.init(air: picture.model, name: picture.modelName.isEmpty ? picture.model : picture.modelName)) }
                    store.settings = settings; dismiss()
                } label: { Label(L10n.text("Use These Settings"), systemImage: "slider.horizontal.3") }
            }
            Section(L10n.text("Prompt")) { Text(picture.prompt).font(.callout.monospaced()).textSelection(.enabled) }
            Section {
                detail(L10n.text("Model"), picture.modelName.isEmpty ? picture.model : picture.modelName)
                detail(L10n.text("Size"), "\(picture.width) × \(picture.height)")
                detail(L10n.text("Steps"), String(picture.steps))
                detail(L10n.text("Guidance (CFG)"), String(format: "%.1f", picture.guidance))
                if let seed = picture.seed { detail(L10n.text("Seed"), String(seed)) }
            }
            Section { Button(L10n.text("Delete"), role: .destructive) { confirming = true } }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(picture.date.formatted(date: .abbreviated, time: .shortened)).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
        .confirmationDialog(L10n.text("Delete this picture?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.text("Delete"), role: .destructive) { store.delete(picture); removed(); dismiss() }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(title); Spacer(minLength: 12); Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2) }
            .font(.subheadline)
    }
}

/// The API key: what it is for, saving it after Civitai accepts it, and removing it.
struct GeneratorAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = GenerationStore.shared
    @State private var key = ""
    @State private var checking = false
    @State private var message: String?
    @State private var account: GenerationAccount?
    var body: some View {
        Form {
            Section {
                SecureField(L10n.text("API Key"), text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.password).accessibilityIdentifier("generator.key")
                Button { check() } label: {
                    HStack { Text(L10n.text("Check and Save")); if checking { Spacer(); ProgressView() } }
                }.disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("generator.saveKey")
                if let account {
                    Label(L10n.text("Signed in as %@", account.name), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("generator.signedIn")
                }
                if let message { Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text(L10n.text("Create a key on civitai.com under Account Settings, API Keys. It is kept in this device's keychain and sent only to Civitai."))
            }
            Section {
                Link(destination: URL(string: "https://civitai.com/user/account")!) { Label(L10n.text("Open Civitai Account Settings"), systemImage: "safari") }
            } footer: {
                Text(L10n.text("Each picture is paid for with Buzz from your Civitai account, and Civitai's rules apply to what you ask for. A key gives full access to the account, so remove it here and revoke it on Civitai if this device is lost."))
            }
            if store.hasKey {
                Section { Button(L10n.text("Remove API Key"), role: .destructive) { store.save(key: ""); account = nil; key = "" }.accessibilityIdentifier("generator.removeKey") }
            }
        }
        .navigationTitle(L10n.text("Civitai API Key")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        .task {
            guard store.hasKey, account == nil else { return }
            account = try? await store.client().account()
        }
    }

    private func check() {
        checking = true; message = nil
        let candidate = key
        Task {
            do {
                let found = try await store.client(key: candidate).account()
                if found.status == "banned" || found.status == "muted" { message = L10n.text("This Civitai account is restricted (%@).", found.status) }
                if store.save(key: candidate) { account = found; key = "" } else { message = L10n.text("The key could not be saved on this device.") }
            } catch let error as GenerationError { message = error.message
            } catch { message = error.localizedDescription }
            checking = false
        }
    }
}

/// Chooses a model: by its AIR, by its page address, or by searching the models Civitai can generate with.
struct GeneratorModelPicker: View {
    let kind: GenerationAIR.Kind
    let choose: (GenerationModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(BooruStore.self) private var library
    @State private var store = GenerationStore.shared
    @State private var pasted = ""
    @State private var search = ""
    @State private var results: [GenerationModel] = []
    @State private var searching = false
    @State private var working = false
    @State private var message: String?
    private var example: String { kind == .lora ? "urn:air:sdxl:lora:civitai:123456@789012" : "urn:air:sdxl:checkpoint:civitai:827184@2514310" }
    private var recent: [GenerationModel] { store.recentModels.filter { GenerationAIR($0.air)?.kind == kind } }

    var body: some View {
        List {
            Section {
                TextField(example, text: $pasted, axis: .vertical).font(.callout.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("generator.air")
                Button { Task { await resolve(pasted) } } label: {
                    HStack { Text(L10n.text("Use This Model")); if working { Spacer(); ProgressView() } }
                }.disabled(working || pasted.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("generator.useAIR")
                if let message { Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red) }
            } header: { Text(L10n.text("AIR or Model Page")) } footer: {
                Text(L10n.text("An AIR names a model exactly: urn:air:ecosystem:type:source:id@version. A Civitai model page address or version number works too."))
            }
            if kind == .checkpoint {
                Section {
                    Button { pick(.recommended) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(GenerationModel.recommended.name).foregroundStyle(Color.primary)
                                Text(L10n.text("The best-rated model for 2D illustration, and the one this generator starts with.")).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Text(L10n.text("Suggested")).font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4).background(StudyStyle.accent, in: Capsule())
                        }
                    }.accessibilityIdentifier("generator.recommendedModel")
                }
            }
            if !recent.isEmpty {
                Section(L10n.text("Recent")) { ForEach(recent) { model in line(model) { pick(model) } } }
            }
            Section {
                if searching { ProgressView().frame(maxWidth: .infinity) }
                ForEach(results) { model in line(model) { Task { await lookUp(model) } } }
            } header: { Text(L10n.text(search.isEmpty ? "Most Downloaded on Civitai" : "Search Results")) }
        }
        .listStyle(.insetGrouped).tint(StudyStyle.accent)
        .navigationTitle(L10n.text(kind == .lora ? "Add a LoRA" : "Choose a Model")).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.text("Search Civitai"))
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            searching = true
            results = (try? await store.client().search(search, kind: kind, mature: !library.safeMode && store.settings.mature)) ?? []
            searching = false
        }
    }

    private func line(_ model: GenerationModel, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).foregroundStyle(Color.primary)
                if let base = model.base { Text(base).font(.caption).foregroundStyle(Color.secondary) }
            }
        }.accessibilityIdentifier("generator.modelRow")
    }

    private func pick(_ model: GenerationModel) {
        guard let air = GenerationAIR(model.air) else { message = GenerationError.notFound.message; return }
        if kind == .checkpoint, air.family == nil { message = GenerationError.unsupportedModel.message; return }
        if air.type != nil, air.kind != kind { message = L10n.text(kind == .lora ? "This is not a LoRA." : "This is not a checkpoint."); return }
        store.remember(model); choose(model); dismiss()
    }

    private func lookUp(_ model: GenerationModel) async {
        guard let id = model.versionID else { return }
        working = true; message = nil
        do { pick(try await store.client().version(id)) } catch let error as GenerationError { message = error.message } catch { message = error.localizedDescription }
        working = false
    }

    /// Reads what was pasted: an AIR as it is, or a page address or version number looked up for its AIR.
    private func resolve(_ text: String) async {
        working = true; message = nil
        defer { working = false }
        if let air = GenerationAIR(text), air.ecosystem != nil || text.lowercased().contains("air:") {
            var model = GenerationModel(air: air.text, name: air.text)
            // The name is a nicety; the identifier works without it.
            if air.source == "civitai", let version = air.version.flatMap(Int.init), let found = try? await store.client().version(version), found.air == air.text { model = found }
            pick(model)
        } else if let id = GenerationAIR.versionID(in: text) {
            do { pick(try await store.client().version(id)) } catch let error as GenerationError { message = error.message } catch { message = error.localizedDescription }
        } else {
            message = L10n.text("This is not an AIR, a model page address or a version number.")
        }
    }
}
