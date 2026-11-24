import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Changes settings from a request in the learner's own words, with the on-device Apple
/// Intelligence model. Nothing leaves the device. Each request shows what changed, and Undo puts it back.
@MainActor @Observable final class SettingsAssistant {
    struct Change: Identifiable, Equatable {
        let id = UUID()
        let itemID: String
        let title: String
        let from: String
        let to: String
        /// The stored value before the change, for Undo.
        let previous: String
    }

    struct Turn: Identifiable {
        let id = UUID()
        let request: String
        var reply = ""
        var changes: [Change] = []
        /// A page the request needs, for what the assistant cannot change by itself.
        var open: SettingsCategory?
        var failed = false
        var undone = false
        var pending = true
    }

    /// What the model answers: settings and values, untrusted until `apply` checks them.
    struct Plan {
        var changes: [(id: String, value: String)] = []
        var reply = ""
        var open: String?
    }

    private(set) var turns: [Turn] = []
    var busy: Bool { turns.contains { $0.pending } }

    /// True when this device runs Apple Intelligence and it is turned on and ready.
    static var isAvailable: Bool {
        #if DEBUG
        // UI tests see the model only when they ask for it, so other tests keep a plain search field.
        if ContentUITestSupport.enabled, !ProcessInfo.processInfo.arguments.contains("--settings-assistant-test") { return false }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Loads the model ahead of a request that is being written; never merely because Settings is open.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable { SettingsModel.prewarm() }
        #endif
    }

    func ask(_ request: String, env: AppEnvironment, booru: Bool) async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        let items = SettingsCatalog.items(booru: booru).filter { $0.control != nil }
        let history = Self.history(turns.suffix(2))
        let turn = Turn(request: text)
        turns.append(turn)
        do {
            let masked = Self.maskingTags(text)
            let plan = Self.unmaskingTags(masked.tags, in: try await Self.plan(masked.request, items: items, env: env, history: history), items: items)
            let result = Self.apply(plan, items: items, env: env)
            update(turn.id) {
                $0.changes = result.changes
                $0.open = result.open
                // The rows below show each change; the reply names them exactly, as the small
                // model's own wording can describe a change wrongly. Its words explain only a refusal.
                if !result.changes.isEmpty {
                    $0.reply = L10n.text("Changed %@.", result.changes.map(\.title).joined(separator: ", "))
                } else {
                    let reply = plan.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    $0.reply = reply.isEmpty || !plan.changes.isEmpty ? L10n.text("Nothing was changed. Try saying which setting and how.") : reply
                }
            }
        } catch {
            update(turn.id) { $0.failed = true; $0.reply = Self.message(for: error) }
        }
        update(turn.id) { $0.pending = false }
    }

    func undo(_ id: Turn.ID, env: AppEnvironment, booru: Bool) {
        guard let turn = turns.first(where: { $0.id == id }), !turn.undone else { return }
        let items = Dictionary(SettingsCatalog.items(booru: booru).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for change in turn.changes.reversed() { items[change.itemID]?.control?.set(env, change.previous) }
        update(id) { $0.undone = true }
    }

    func clear() { turns.removeAll { !$0.pending } }

    private func update(_ id: Turn.ID, _ edit: (inout Turn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        edit(&turns[index])
    }

    /// Applies only listed settings, each to a value it allows and only when it differs; a setting
    /// named twice keeps the last value. Returns what changed.
    static func apply(_ plan: Plan, items: [SettingsItem], env: AppEnvironment) -> (changes: [Change], open: SettingsCategory?) {
        var changes: [Change] = []
        for (id, raw) in plan.changes {
            guard let item = items.first(where: { $0.id == id }), let control = item.control, let value = control.normalized(raw) else { continue }
            let before = control.get(env)
            control.set(env, value)
            let after = control.get(env)
            guard after != before else { continue }
            if let earlier = changes.firstIndex(where: { $0.itemID == id }) {
                let first = changes.remove(at: earlier)
                guard first.previous != after else { continue }
                changes.append(.init(itemID: id, title: item.title, from: first.from, to: display(control, after), previous: first.previous))
            } else {
                changes.append(.init(itemID: id, title: item.title, from: display(control, before), to: display(control, after), previous: before))
            }
        }
        let open = plan.open.flatMap(SettingsCategory.init(rawValue:))
        return (changes, changes.isEmpty ? open : nil)
    }

    /// Tags as the request wrote them, such as "male:males_only": the model can mistype them.
    static func requestTags(_ request: String) -> [String] {
        request.split(whereSeparator: { $0.isWhitespace || ",;\"'“”‘’「」『』()".contains($0) }).map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-.!?。、")) }
            .filter { token in
                guard token.unicodeScalars.allSatisfy({ $0.isASCII }), token.count > 2 else { return false }
                return token.contains("_") || (token.contains(":") && !token.hasPrefix(":") && !token.hasSuffix(":"))
            }
    }

    /// The request with each tag it writes, such as "male:males_only", swapped for TAG1, TAG2…:
    /// the model then cannot mistype them, and their words cannot trip its content guardrails.
    static func maskingTags(_ request: String) -> (request: String, tags: [String]) {
        var tags: [String] = []
        var masked = request
        for tag in requestTags(request) where !tags.contains(tag) {
            tags.append(tag)
            masked = masked.replacingOccurrences(of: tag, with: "TAG\(tags.count)")
        }
        return (masked, tags)
    }

    /// Puts the request's tags back into tag settings; other values pass through unchanged.
    static func unmaskingTags(_ tags: [String], in plan: Plan, items: [SettingsItem]) -> Plan {
        guard !tags.isEmpty else { return plan }
        var plan = plan
        plan.changes = plan.changes.map { change in
            guard let item = items.first(where: { $0.id == change.id }), case .tags = item.control?.kind else { return change }
            let named = SettingsControl.tags(change.value).compactMap { token -> String? in
                guard token.uppercased().hasPrefix("TAG"), let number = Int(token.dropFirst(3)), tags.indices.contains(number - 1) else { return nil }
                return tags[number - 1]
            }
            return (change.id, (named.isEmpty ? tags : named).joined(separator: " "))
        }
        // Higher numbers first, so TAG1 does not eat the start of TAG10.
        for (index, tag) in tags.enumerated().reversed() { plan.reply = plan.reply.replacingOccurrences(of: "TAG\(index + 1)", with: tag) }
        return plan
    }

    private static func display(_ control: SettingsControl, _ value: String) -> String {
        if case .tags = control.kind { return value.isEmpty ? L10n.text("None") : value }
        return control.display(value)
    }

    /// The settings as the model reads them: one line each, with what it may be set to and its value now.
    static func catalog(_ items: [SettingsItem], env: AppEnvironment) -> String {
        items.compactMap { item in
            guard let control = item.control else { return nil }
            var line = "\(item.id) | \(item.assistantTitle)"
            if let hint = item.hint { line += " (\(hint))" }
            line += " | \(control.allowed)"
            if case .tags = control.kind {
                // Only how many: the user's own tags stay out of the prompt, and out of the guardrails' way.
                let count = SettingsControl.tags(control.get(env)).count
                line += " | now: \(count) tags"
            } else {
                line += " | now: " + control.modelName(control.get(env))
            }
            return line
        }.joined(separator: "\n")
    }

    private static func history(_ turns: ArraySlice<Turn>) -> String {
        turns.filter { !$0.failed }.map { turn in
            let changed = turn.undone ? "undone" : turn.changes.isEmpty ? "nothing" : turn.changes.map { "\($0.itemID) to \($0.to)" }.joined(separator: ", ")
            return "Earlier request: \(turn.request) → changed: \(changed)"
        }.joined(separator: "\n")
    }

    private static func plan(_ request: String, items: [SettingsItem], env: AppEnvironment, history: String) async throws -> Plan {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return try await SettingsModel.plan(request: request, items: items, env: env, history: history)
        }
        #endif
        throw CancellationError()
    }

    private static func message(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return L10n.text("Apple Intelligence couldn’t handle this request. Try other words, or find the setting below.")
            case .unsupportedLanguageOrLocale: return L10n.text("Apple Intelligence doesn’t support this language yet. Try asking in English.")
            case .exceededContextWindowSize: return L10n.text("This request is too long. Try a shorter one.")
            default: break
            }
        }
        #endif
        return L10n.text("Apple Intelligence isn’t available right now. Try again in a moment.")
    }
}

#if canImport(FoundationModels)
/// Two steps in one session: the model first picks the settings a request is about, then fills a
/// schema made for just those settings, where each value can only be one the setting allows.
@available(iOS 26.0, *)
enum SettingsModel {
    /// Loads the model ahead of a request that is being written; never merely because Settings is open.
    static func prewarm() { LanguageModelSession(instructions: instructions).prewarm() }

    static var replyLanguage: String { Locale(identifier: "en").localizedString(forLanguageCode: L10n.language) ?? "English" }

    static var instructions: String {
        """
        You change the settings of TEGNAL, an app for reading comics and browsing images, for the user. \
        The settings are listed one per line as: id | name (what it does) | allowed values | current value.
        A request can ask for several things. A wish that no listed setting does exactly, or that is not about these settings at all, gets none. \
        Never pick a setting the user did not ask about. Tags in a request may be written as TAG1, TAG2 and so on; keep them exactly as written.
        """
    }

    @MainActor static func plan(request: String, items: [SettingsItem], env: AppEnvironment, history: String) async throws -> SettingsAssistant.Plan {
        // First the separate wishes, then one slot per wish that takes a setting or none, so a
        // request about something else changes nothing instead of whatever comes first in the list.
        var prompt = "Settings:\n\(SettingsAssistant.catalog(items, env: env))\n\n"
        if !history.isEmpty { prompt += history + "\n\n" }
        prompt += "Request: \(request)"
        let session = LanguageModelSession(instructions: instructions)
        let split = DynamicGenerationSchema(name: "Wishes", properties: [
            .init(name: "wishes", description: "Each separate thing the user asks for, in a few English words; a question or anything else is one wish too",
                  schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self), minimumElements: 1, maximumElements: 6)),
        ])
        let wishes = (try? (try await session.respond(to: prompt, schema: try GenerationSchema(root: split, dependencies: []), options: GenerationOptions(sampling: .greedy)))
            .content.value([String].self, forProperty: "wishes")) ?? []
        var plan = SettingsAssistant.Plan()
        guard !wishes.isEmpty else { return plan }
        var slots: [DynamicGenerationSchema.Property] = wishes.enumerated().map { index, wish in
            .init(name: "wish\(index + 1)", description: "The setting that does exactly this: \(wish)", schema: DynamicGenerationSchema(name: "Setting\(index + 1)", anyOf: ["none"] + items.map(\.id)))
        }
        slots.append(.init(name: "open", description: "A settings page for a wish no listed setting does, otherwise none", schema: DynamicGenerationSchema(name: "Page", anyOf: SettingsCategory.allCases.map(\.rawValue) + ["none"])))
        let picked = try await session.respond(to: "For each wish, pick the one setting that does exactly that, or none.",
                                               schema: try GenerationSchema(root: DynamicGenerationSchema(name: "Picks", properties: slots), dependencies: []),
                                               options: GenerationOptions(sampling: .greedy)).content
        let open = try? picked.value(String.self, forProperty: "open")
        plan.open = open == "none" ? nil : open
        var chosen: [SettingsItem] = []
        for index in wishes.indices {
            guard let id = try? picked.value(String.self, forProperty: "wish\(index + 1)") else { continue }
            if let item = items.first(where: { $0.id == id }), !chosen.contains(where: { $0.id == id }) { chosen.append(item) }
        }
        guard !chosen.isEmpty else { return plan }

        var properties: [DynamicGenerationSchema.Property] = chosen.compactMap { item in
            guard let control = item.control else { return nil }
            var description = item.assistantTitle + (item.hint.map { " (\($0))" } ?? "") + ", now " + control.modelName(control.get(env))
            let schema: DynamicGenerationSchema
            switch control.kind {
            case .toggle: schema = DynamicGenerationSchema(name: item.id, anyOf: ["on", "off"])
            case .choice(let options): schema = DynamicGenerationSchema(name: item.id, anyOf: options.map { control.modelName($0.value) })
            case .number(let range): schema = DynamicGenerationSchema(type: Int.self, guides: [.range(range)])
            case .tags:
                description = item.assistantTitle + "; the tags to \(["search.showHiddenTags", "search.stopRequiringTags"].contains(item.id) ? "remove" : "add"), separated by spaces, written exactly as in the request"
                schema = DynamicGenerationSchema(type: String.self)
            }
            return .init(name: item.id, description: description, schema: schema)
        }
        properties.append(.init(name: "reply", description: "One or two short, friendly sentences in \(replyLanguage) saying what you changed, using setting names, never ids", schema: DynamicGenerationSchema(type: String.self)))
        let values = DynamicGenerationSchema(name: "SettingsValues", properties: properties)
        let filled = try await session.respond(to: "Now give each of those settings the value the request wants. Write the reply in \(replyLanguage).",
                                               schema: try GenerationSchema(root: values, dependencies: []), options: GenerationOptions(sampling: .greedy)).content
        for item in chosen {
            guard let control = item.control else { continue }
            if case .number = control.kind {
                if let number = try? filled.value(Int.self, forProperty: item.id) { plan.changes.append((item.id, String(number))) }
            } else if let value = try? filled.value(String.self, forProperty: item.id) {
                plan.changes.append((item.id, value))
            }
        }
        // The small model sometimes names a setting by its id; the reply names it as the screen does.
        plan.reply = chosen.reduce((try? filled.value(String.self, forProperty: "reply")) ?? "") { $0.replacingOccurrences(of: $1.id, with: $1.title) }
        return plan
    }
}
#endif
