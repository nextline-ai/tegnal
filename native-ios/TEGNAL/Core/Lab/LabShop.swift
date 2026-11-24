import CryptoKit
import Foundation

// MARK: - The shop list

/// What 보석 buys. The list is not in the app: TEGNAL publishes it beside the add-ons (`v1/lab/shop.json`, signed with the
/// add-on key), and the app keeps the last copy it read. Goods that need files (course files, add-ons, home scenes) are
/// downloaded after they are bought and checked against the size and SHA-256 the signed list gives (`LabGoods`).
/// Format and fields: `docs/features/live-shop.md`.
struct LabShop: Decodable, Sendable {
    static let format = "tegnal-lab-shop"
    static let schemaVersion = 1
    static let maximumBytes = 512 * 1024

    var currency: LabText
    var note: LabText?
    var sections: [Section]

    struct Section: Decodable, Sendable, Identifiable {
        var title: LabText
        var items: [LabShopItem]
        var id: String { title.resolved("ko") }

        init(title: LabText, items: [LabShopItem]) { self.title = title; self.items = items }

        /// An item that is not shaped like one at all is left out, rather than hiding the whole shop.
        init(from decoder: Decoder) throws {
            struct Lossy: Decodable {
                let item: LabShopItem?
                init(from decoder: Decoder) throws { item = try? LabShopItem(from: decoder) }
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(LabText.self, forKey: .title)
            var seen = Set<String>()
            items = try container.decode([Lossy].self, forKey: .items).compactMap(\.item).filter { seen.insert($0.id).inserted }
        }
        private enum CodingKeys: String, CodingKey { case title, items }
    }

    init(currency: LabText = LabShop.defaultCurrency, note: LabText? = nil, sections: [Section]) {
        self.currency = currency; self.note = note; self.sections = sections
    }

    var items: [LabShopItem] { sections.flatMap(\.items) }
    func item(_ id: String) -> LabShopItem? { items.first { $0.id == id } }

    /// The permanent goods together: what can be owned once, not used up. The cards are priced against this.
    var permanentTotal: Int { items.filter { !$0.isRepeat }.compactMap(\.price).reduce(0, +) }

    static let defaultCurrency = LabText(values: ["ko": "보석", "en": "Gems", "ja": "ジェム"])
    /// No list read yet: the currency's name, and nothing for sale.
    static let empty = LabShop(sections: [])

    /// What the app itself can sell while the server's list cannot be read (offline, or a list for a later app): the course it
    /// carries and the prompt analyzer (user, 2026-11-24). Their prices match the published list (`docs/live/shop.json`); a test
    /// keeps the two the same.
    static let builtIn = LabShop(sections: [
        Section(title: LabText(values: ["ko": "코스", "en": "Courses", "ja": "コース"]), items: [
            LabShopItem(id: "course.tags", kind: "course",
                        name: LabText(values: ["ko": "2D AI 배우기", "en": "Learn 2D AI", "ja": "2D AIを学ぶ"]),
                        summary: LabText(values: ["ko": "AI로 그리는 2D 일러스트", "en": "2D illustrations drawn with AI", "ja": "AIで描く2Dイラスト"]),
                        symbol: "paintbrush.pointed", price: 500, course: LearningCourse.tagsID, color: "7C5CFF",
                        detail: LabText(values: [
                            "ko": "실제 그림으로 태그를 익히고, 배운 프롬프트로 직접 그려 보는 코스입니다.\n\n- 레슨 62개, 섹션 11개\n- 레슨·별 세 개·섹션을 처음 마칠 때마다 보석\n- 배운 태그로 바로 그리는 생성기",
                            "en": "Learn tags from real pictures, then draw with the prompts you learned.\n\n- 62 lessons in 11 sections\n- Gems the first time you finish a lesson, get three stars or finish a section\n- A generator that draws with the tags you learned",
                            "ja": "実際の絵でタグを覚え、学んだプロンプトで描いてみるコースです。\n\n- 11セクション、62レッスン\n- レッスン・星3つ・セクションを初めて終えるたびにジェム\n- 学んだタグですぐ描けるジェネレーター",
                        ])),
        ]),
        Section(title: LabText(values: ["ko": "도구", "en": "Tools", "ja": "ツール"]), items: [
            LabShopItem(id: LabFeature.promptAnalyzer.item, kind: "feature",
                        name: LabText(values: ["ko": "프롬프트 분석기", "en": "Prompt Analyzer", "ja": "プロンプトアナライザー"]),
                        summary: LabText(values: ["ko": "바로 쓰는 AI 프롬프트, 원 클릭 이미지 생성", "en": "Ready-to-use AI prompts, one-click image generation", "ja": "すぐ使えるAIプロンプト、ワンクリックで画像生成"]),
                        symbol: "text.viewfinder", price: 200, requires: "course.tags", feature: LabFeature.promptAnalyzer.rawValue, color: "0A84FF",
                        detail: LabText(values: [
                            "ko": "마음에 든 그림을 그대로 쓸 수 있는 AI 프롬프트로 바꾸고, 한 번 눌러 바로 이미지를 생성합니다.\n\n- 즉시 쓰는 프롬프트: 이미지 생성 AI가 읽는 순서로 정리돼 복사해서 바로 사용\n- 원 클릭 생성: 그 프롬프트 그대로 생성기에서 바로 그리기\n- 프롬프트 · 괄호 이스케이프 · 검색 태그 세 가지 형식\n- 그림 속 2D AI 배우기 태그를 바로 연습",
                            "en": "Turns a picture you like into an AI prompt you can use as it is, and generates an image from it in one click.\n\n- Ready-to-use prompts, in the order image generators read, copied in one tap\n- One-click generation: draw with that very prompt in the generator\n- Three formats: prompt, escaped brackets and search tags\n- Practise the picture's Learn 2D AI tags right away",
                            "ja": "気に入った絵を、そのまま使えるAIプロンプトに変え、ワンクリックで画像を生成します。\n\n- すぐ使えるプロンプト：画像生成AIが読む順に整理され、コピーしてそのまま使用\n- ワンクリック生成：そのプロンプトのままジェネレーターで描く\n- プロンプト・括弧エスケープ・検索タグの3形式\n- 絵の中の「2D AIを学ぶ」のタグをすぐ練習",
                        ])),
        ]),
    ])

    /// Reads a list's JSON. Throws `.newer` for a list written for a later app.
    static func decode(_ data: Data) throws -> LabShop {
        struct Head: Decodable { var format: String; var schemaVersion: Int }
        guard data.count <= maximumBytes, let head = try? JSONDecoder().decode(Head.self, from: data), head.format == format, head.schemaVersion >= 1 else {
            throw LabShopError.invalid
        }
        guard head.schemaVersion <= schemaVersion else { throw LabShopError.newer }
        guard let shop = try? JSONDecoder().decode(LabShop.self, from: data) else { throw LabShopError.invalid }
        return shop
    }
}

enum LabShopError: Error, Equatable { case invalid, newer, unsigned }

/// A file the shop delivers, as the signed list names it. Its path is under the add-on server's `v1/`.
struct LabShopFile: Decodable, Hashable, Sendable {
    var path: String
    var size: Int
    var sha256: String

    static let maximumBytes = 40 * 1024 * 1024
    /// An item's picture.
    static let imageBytes = 2 * 1024 * 1024

    /// Letters, digits, `.`, `-`, `_` and `/` only, no `..` and nothing absolute, so a path can only name a file on TEGNAL's server.
    var valid: Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.count <= 200 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }
            && (1...Self.maximumBytes).contains(size) && sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    var name: String { String(path.split(separator: "/").last ?? "") }
}

/// An official add-on the shop sells. Its file sits where the free official add-ons do; it is not in their list.
struct LabShopAddon: Decodable, Hashable, Sendable {
    var id: String
    var version: String
    var mode: AddonMode
    var file: LabShopFile
    var valid: Bool { AddonCheck.identifier(id) && AddonCheck.version(version) && file.valid && file.size <= Addon.maximumBytes }
}

/// A home scene: its opening film, its loop, the opening's first frame blurred, and optionally its music and colours.
struct LabShopHome: Decodable, Hashable, Sendable {
    var intro: LabShopFile
    var loop: LabShopFile
    var still: LabShopFile
    var theme: LabShopFile?
    /// `sky`, `ground` and `dusk` as six hexadecimal digits.
    var palette: [String: String]?

    var files: [(role: String, file: LabShopFile)] {
        [("intro", intro), ("loop", loop), ("still", still)] + (theme.map { [("theme", $0)] } ?? [])
    }
    var valid: Bool {
        files.allSatisfy(\.file.valid) && (palette ?? [:]).allSatisfy { ["sky", "ground", "dusk"].contains($0.key) && LabShopHome.hex($0.value) != nil }
    }
    static func hex(_ value: String) -> UInt32? {
        guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(value, radix: 16)
    }
}

/// Features of the app the shop sells the key to. The code is in the app; buying `feature.<id>` opens it.
enum LabFeature: String, CaseIterable, Sendable {
    case promptAnalyzer = "prompt-analyzer"
    var item: String { "feature." + rawValue }
}

struct LabShopItem: Decodable, Sendable, Identifiable, Hashable {
    /// The kinds of goods this app knows how to deliver, and the newest item fields it reads.
    static let kinds: Set<String> = ["course", "feature", "addon", "home", "ticket"]
    static let version = 1
    /// The courses in the app that the shop sells, by course id, with the item that sells each.
    static let bundledCourses = [LearningCourse.tagsID: "course.tags"]

    var id: String
    /// `course`, `feature`, `addon`, `home` or `ticket`.
    var kind: String
    /// The version of the item's fields. One newer than the app's asks for an update.
    var version: Int?
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
    /// The item that must be owned first, such as 2D AI 배우기 for the tickets its picture generator uses.
    var requires: String?

    // What it delivers, by kind. Read leniently: a later app may shape them differently, which only makes the item unsupported.
    /// `course`: a course bundled in the app (`LearningCourse.id`).
    var course: String?
    /// `course`: a course file to download (`tegnal-lab-course`).
    var file: LabShopFile?
    /// `feature`: the feature it opens (`LabFeature`).
    var feature: String?
    var addon: LabShopAddon?
    var home: LabShopHome?
    /// `ticket`: tickets one purchase brings.
    var count: Int?
    /// The card's colour, six hexadecimal digits. Missing: the colour of its kind (`LabShopStyle`).
    var color: String?
    /// What the item's page says beyond the summary, as Markdown (`LabMarkdown`).
    var detail: LabText?
    /// A picture that fills the item's card and page in place of its colour and symbol (`LabShopImages`).
    var image: LabShopFile?

    init(id: String, kind: String, name: LabText, summary: LabText? = nil, symbol: String? = nil, price: Int? = nil, limited: Bool? = nil,
         repeat again: Bool? = nil, soon: Bool? = nil, requires: String? = nil, course: String? = nil, file: LabShopFile? = nil,
         feature: String? = nil, addon: LabShopAddon? = nil, home: LabShopHome? = nil, count: Int? = nil, color: String? = nil, detail: LabText? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.summary = summary; self.symbol = symbol; self.price = price
        self.limited = limited; self.repeat = again; self.soon = soon; self.requires = requires
        self.course = course; self.file = file; self.feature = feature; self.addon = addon; self.home = home; self.count = count
        self.color = color; self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decode(LabText.self, forKey: .name)
        guard AddonCheck.identifier(id) else { throw LabShopError.invalid }
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        summary = try? c.decodeIfPresent(LabText.self, forKey: .summary)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        price = (try? c.decodeIfPresent(Int.self, forKey: .price)).flatMap { $0 }.flatMap { $0 >= 0 ? $0 : nil }
        limited = try? c.decodeIfPresent(Bool.self, forKey: .limited)
        self.repeat = try? c.decodeIfPresent(Bool.self, forKey: .repeat)
        soon = try? c.decodeIfPresent(Bool.self, forKey: .soon)
        requires = try? c.decodeIfPresent(String.self, forKey: .requires)
        course = try? c.decodeIfPresent(String.self, forKey: .course)
        file = try? c.decodeIfPresent(LabShopFile.self, forKey: .file)
        feature = try? c.decodeIfPresent(String.self, forKey: .feature)
        addon = try? c.decodeIfPresent(LabShopAddon.self, forKey: .addon)
        home = try? c.decodeIfPresent(LabShopHome.self, forKey: .home)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        color = (try? c.decodeIfPresent(String.self, forKey: .color)).flatMap { $0 }.flatMap { LabShopHome.hex($0) != nil ? $0 : nil }
        detail = try? c.decodeIfPresent(LabText.self, forKey: .detail)
        image = (try? c.decodeIfPresent(LabShopFile.self, forKey: .image)).flatMap { $0 }.flatMap { $0.valid && $0.size <= LabShopFile.imageBytes ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, version, name, summary, symbol, price, limited, `repeat`, soon, requires, course, file, feature, addon, home, count, color, detail, image
    }

    var isLimited: Bool { limited ?? false }
    var isRepeat: Bool { self.repeat ?? false }
    var isSoon: Bool { soon ?? false }

    /// True when this app knows what the item is and how to deliver it. Anything else is shown with "update the app to buy it".
    var supported: Bool {
        guard Self.kinds.contains(kind), (version ?? 1) <= Self.version else { return false }
        // Something shown but not on sale yet needs nothing more.
        if isSoon { return true }
        switch kind {
        case "course":
            if let course { return Self.bundledCourses[course] == id }
            return file?.valid ?? false
        case "feature": return feature.flatMap(LabFeature.init(rawValue:)).map { $0.item == id } ?? false
        case "addon": return addon?.valid ?? false
        case "home": return home?.valid ?? false
        case "ticket": return (count ?? 0) > 0
        default: return false
        }
    }

    /// Bought here but brought by files that each device downloads for itself.
    var downloads: Bool { file != nil || addon != nil || home != nil }
}

// MARK: - Reading the list

/// Downloads the shop list from TEGNAL's add-on server and keeps the last good copy.
enum LabShopSource {
    static let url = AddonMarket.liveBase.appending(path: "lab/shop.json")
    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "AILab/shop.json")
    }

    /// The list read last time, if any. Kept as the signed list's own bytes, already checked when they were downloaded.
    static func saved() -> LabShop? {
        #if DEBUG
        if let local = debugFile() { return local }
        #endif
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? LabShop.decode(data)
    }

    /// Fetches the published list. Its file holds the list's bytes and their signature (`{"payload": base64, "signature": base64}`),
    /// signed with the same key as the add-on catalog.
    static func fetch(market: AddonMarket = .live) async throws -> LabShop {
        #if DEBUG
        if let local = debugFile() { return local }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.contains("ui-test") }) { throw AddonMarketError.offline }
        #endif
        let data = try await market.fetch(url, LabShop.maximumBytes * 2)
        let (shop, payload) = try open(data, key: market.publicKey)
        // Only TEGNAL's own list is kept for next time; a list signed with a test key is not.
        if let file, market.publicKey.rawRepresentation == AddonMarket.live.publicKey.rawRepresentation {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? payload.write(to: file, options: .atomic)
        }
        return shop
    }

    /// Checks the signature over the list's exact bytes, then reads it.
    static func open(_ file: Data, key: P256.Signing.PublicKey) throws -> (LabShop, Data) {
        let payload = try LabSigned.payload(file, key: key, limit: LabShop.maximumBytes)
        return (try LabShop.decode(payload), payload)
    }

    #if DEBUG
    /// `--lab-shop=<absolute path>` reads an unsigned list from a file instead, for tests and screenshots.
    private static func debugFile() -> LabShop? {
        guard let path = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--lab-shop=") })?.dropFirst(11),
              let data = FileManager.default.contents(atPath: String(path)) else { return nil }
        return try? LabShop.decode(data)
    }
    #endif
}

/// The envelope TEGNAL's signed files share: `{"payload": base64, "signature": base64}`, ECDSA P-256 with SHA-256 (DER).
enum LabSigned {
    static func payload(_ file: Data, key: P256.Signing.PublicKey, limit: Int) throws -> Data {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: file),
              let payload = Data(base64Encoded: envelope.payload), payload.count <= limit,
              let der = Data(base64Encoded: envelope.signature),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: payload) else { throw LabShopError.unsigned }
        return payload
    }
}
