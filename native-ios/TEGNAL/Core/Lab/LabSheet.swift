import CryptoKit
import Foundation

// MARK: - The cheat sheet (Layer 2)

/// One edition of the cheat sheet: what to use for which job right now. Editions come irregularly, whenever the field changes.
/// The app carries one in `AILab/cheatsheet.json`; newer ones are downloaded, signed with TEGNAL's add-on key, and kept.
struct LabEdition: Codable, Equatable, Sendable, Identifiable {
    static let format = "tegnal-lab-cheatsheet"
    var format: String
    var id: String
    /// The day it was curated, `yyyy-MM-dd`. Shown to the day; there is never a date for the next one.
    var date: String
    /// 연구비 for reading it the first time. Missing means the course's usual amount; 0 pays nothing.
    var reward: Int?
    /// What changed since the last edition, one line.
    var change: LabSheetText?
    var sections: [LabSheetSection]
    var footer: LabSheetText?

    /// `2026.11.23`.
    var stamp: String { date.replacingOccurrences(of: "-", with: ".") }
    var valid: Bool {
        format == Self.format && !id.isEmpty && date.count == 10 && !sections.isEmpty && sections.allSatisfy { !$0.rows.isEmpty }
    }

    /// The newest of the bundled edition and the last one downloaded.
    static func newest() -> LabEdition? {
        [bundled, LabSheetSource.saved()].compactMap { $0 }.max { $0.date < $1.date }
    }

    static let bundled: LabEdition? = {
        guard let url = Bundle.main.url(forResource: "cheatsheet", withExtension: "json", subdirectory: "AILab"),
              let data = try? Data(contentsOf: url), let edition = try? JSONDecoder().decode(LabEdition.self, from: data), edition.valid else { return nil }
        return edition
    }()
}

/// Cheat-sheet text: one string, a list of lines, or per language. Kept apart from the course's text so editions stay plain JSON.
struct LabSheetText: Codable, Equatable, Sendable {
    var values: [String: String]
    init(from decoder: Decoder) throws { values = try LabText(from: decoder).values }
    func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(values) }
    var text: String { LabText(values: values).text }
}

extension LabText {
    init(values: [String: String]) { self.init(""); self.values = values }
}

struct LabSheetSection: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: LabSheetText
    /// The episode whose card opens this section. None: always open.
    var opens: String?
    var rows: [LabSheetRow]
}

struct LabSheetRow: Codable, Equatable, Sendable {
    var task: LabSheetText
    var example: LabSheetText?
    /// The product or tool to use now. Real names live only here, never in the course.
    var pick: String
    var why: LabSheetText?
    /// A pick not settled yet: the sheet marks it as a draft.
    var draft: Bool?
}

/// Downloads newer editions from TEGNAL's add-on server and keeps the last one.
enum LabSheetSource {
    static let url = AddonMarket.liveBase.appending(path: "lab/cheatsheet.json")
    static let maximumBytes = 256 * 1024
    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "AILab/cheatsheet.json")
    }

    static func saved() -> LabEdition? {
        guard let file, let data = try? Data(contentsOf: file), let edition = try? JSONDecoder().decode(LabEdition.self, from: data), edition.valid else { return nil }
        return edition
    }

    /// Fetches the published edition. Its file holds the edition's bytes and their signature (`{"payload": base64, "signature": base64}`),
    /// signed with the same key as the add-on catalog. An edition that is not signed, or not valid, is ignored.
    static func fetch(key: P256.Signing.PublicKey = AddonMarket.live.publicKey) async -> LabEdition? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--lab-") || $0.contains("ui-test") }) { return nil }
        #endif
        guard let data = try? await AddonMarket.get(url, limit: maximumBytes * 2), let edition = try? open(data, key: key) else { return nil }
        if let file, let payload = try? JSONEncoder().encode(edition) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? payload.write(to: file, options: .atomic)
        }
        return edition
    }

    static func open(_ file: Data, key: P256.Signing.PublicKey) throws -> LabEdition {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: file),
              let payload = Data(base64Encoded: envelope.payload), payload.count <= maximumBytes,
              let der = Data(base64Encoded: envelope.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: payload),
              let edition = try? JSONDecoder().decode(LabEdition.self, from: payload), edition.valid else { throw AddonMarketError.unsigned }
        return edition
    }
}

// MARK: - The shop

/// What 연구비 buys. `AILab/shop.json`.
struct LabShop: Decodable, Sendable {
    var currency: LabText
    var note: LabText?
    var sections: [Section]

    struct Section: Decodable, Sendable, Identifiable {
        var title: LabText
        var items: [LabShopItem]
        var id: String { title.resolved("ko") }
    }

    var items: [LabShopItem] { sections.flatMap(\.items) }
    func item(_ id: String) -> LabShopItem? { items.first { $0.id == id } }

    /// The permanent goods together: what can be owned once, not used up. The cards are priced against this.
    var permanentTotal: Int { items.filter { !$0.isRepeat }.compactMap(\.price).reduce(0, +) }

    static let bundled: LabShop = {
        guard let url = Bundle.main.url(forResource: "shop", withExtension: "json", subdirectory: "AILab"),
              let data = try? Data(contentsOf: url), let shop = try? JSONDecoder().decode(LabShop.self, from: data) else {
            return LabShop(currency: "연구비", note: nil, sections: [])
        }
        return shop
    }()
}

struct LabShopItem: Decodable, Sendable, Identifiable, Hashable {
    var id: String
    /// `course`, `home`, `ticket` or `addon`.
    var kind: String
    var name: LabText
    var summary: LabText?
    var symbol: String?
    var price: Int?
    /// Sold with a limited-sale label: it may not stay on sale.
    var limited: Bool?
    /// Can be bought again, such as tickets that are used up.
    var `repeat`: Bool?
    /// Shown, but not on sale yet.
    var soon: Bool?

    var isLimited: Bool { limited ?? false }
    var isRepeat: Bool { self.repeat ?? false }
    var isSoon: Bool { soon ?? false }
}
