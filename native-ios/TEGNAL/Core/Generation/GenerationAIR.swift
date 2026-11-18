import Foundation

/// An AI Resource identifier: `urn:air:{ecosystem}:{type}:{source}:{id}[@{version}][+{file}][.{format}]`.
/// The `urn:` and `air:` prefixes, the ecosystem and the type may be left out; a source and an id are always there.
struct GenerationAIR: Hashable, Sendable {
    enum Kind: String, Sendable { case checkpoint, lora, embedding, vae, other }
    /// The engine family a checkpoint runs on.
    enum Family: String, Sendable { case sd1, sdxl, anima }

    var ecosystem: String?
    var type: String?
    var source: String
    var id: String
    var version: String?
    var file: String?
    var format: String?

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/")
    private static func valid(_ text: String, extra: String = "") -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) || extra.unicodeScalars.contains($0) }
    }

    init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["urn:", "air:"] where rest.lowercased().hasPrefix(prefix) { rest = String(rest.dropFirst(prefix.count)) }
        var parts = rest.components(separatedBy: ":")
        guard (2...4).contains(parts.count) else { return nil }
        var last = parts.removeLast()
        if let at = last.firstIndex(of: "@") {
            var tail = String(last[last.index(after: at)...])
            last = String(last[..<at])
            if let dot = tail.lastIndex(of: "."), tail[tail.index(after: dot)...].allSatisfy(\.isLetter), tail.index(after: dot) < tail.endIndex {
                format = String(tail[tail.index(after: dot)...]); tail = String(tail[..<dot])
            }
            if let plus = tail.firstIndex(of: "+") { file = String(tail[tail.index(after: plus)...]); tail = String(tail[..<plus]) }
            guard Self.valid(tail, extra: ".=,%"), file.map({ Self.valid($0) }) ?? true else { return nil }
            version = tail
        }
        guard Self.valid(last, extra: "."), parts.allSatisfy({ Self.valid($0) }) else { return nil }
        id = last
        source = parts.removeLast()
        // With one part left it is the ecosystem; with two, the ecosystem and the type.
        if parts.count == 2 { type = parts[1].lowercased() }
        ecosystem = parts.first?.lowercased()
    }

    /// The identifier in its full form.
    var text: String {
        var result = "urn:air:" + ([ecosystem, type].compactMap { $0 } + [source, id]).joined(separator: ":")
        if let version { result += "@" + version }
        if let file { result += "+" + file }
        if let format { result += "." + format }
        return result
    }

    var kind: Kind {
        switch type {
        case "checkpoint", "model", "diffusionmodel", "unet": .checkpoint
        case "lora", "locon", "dora", "lycoris": .lora
        case "embedding", "textualinversion": .embedding
        case "vae": .vae
        default: .other
        }
    }

    /// Anima, Stable Diffusion 1.5 and the SDXL family, which Illustrious, NoobAI, Pony and Animagine belong to.
    var family: Family? {
        switch ecosystem {
        case "anima": .anima
        case "sd1", "sd15", "sd1.5": .sd1
        case "sdxl", "illustrious", "noobai", "pony", "sdxlturbo", "sdxllightning", "sdxlhyper": .sdxl
        default: nil
        }
    }

    /// The model version a pasted web address or a bare number points at, to be looked up for its identifier.
    static func versionID(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), number > 0 { return number }
        guard let components = URLComponents(string: trimmed) else { return nil }
        if let value = components.queryItems?.first(where: { $0.name == "modelVersionId" })?.value, let number = Int(value) { return number }
        let path = components.path.split(separator: "/").map(String.init)
        if let index = path.firstIndex(of: "model-versions"), index + 1 < path.count { return Int(path[index + 1]) }
        return nil
    }
}
