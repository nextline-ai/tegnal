import CryptoKit
import Foundation
import GRDB

/// A comics library read from another app's backup, export or link list. The file is only
/// read; what it holds is shown first and merged into the library when the person confirms.
///
/// Every format is recognized by its contents, never by its name:
/// - `viewerDatabase`: an SQLite export with `LOCAL_FAVORITES`, `DOWNLOADS` and `HISTORY`
///   tables keyed by `GID` and `TOKEN` (Android viewers of the keyed catalog).
/// - `settingsExport`: a JSON list of `{type, config}` records whose gallery history record
///   (type 5) holds each work as JSON (a cross-platform viewer of the keyed catalog).
/// - `downloadFolder`: download folders that each keep a `manifest.json` with `gid`, `token`
///   and `pages` (an iOS viewer of the keyed catalog, visible in the Files app).
/// - `readerBackup`: a gzip-compressed protobuf backup of a general manga reader; only its
///   entries whose address is unmistakably a work of a supported catalog are kept.
/// - `linkList`: browser bookmarks (HTML) or any text holding work links or bare numbers.
struct OtherAppLibrary: Sendable {
    enum Format: String, Sendable {
        case viewerDatabase, settingsExport, downloadFolder, readerBackup, linkList

        var title: String {
            switch self {
            case .viewerDatabase: return L10n.text("Viewer Database Export")
            case .settingsExport: return L10n.text("App Data Export")
            case .downloadFolder: return L10n.text("Download Folders")
            case .readerBackup: return L10n.text("Manga Reader Backup")
            case .linkList: return L10n.text("Link List or Bookmarks")
            }
        }
    }

    struct Entry: Sendable, Equatable {
        var id: Int64
        var key: String?
        var title: String?
        var artists: [String] = []
        var language: String?
        var type: String?
        var tags: [String] = []
        var publishedAt: String?
        var savedAt: Date?

        var hasMetadata: Bool { !(title ?? "").isEmpty || !tags.isEmpty || !artists.isEmpty }
    }

    /// A folder from the file. `nil` names Unfiled.
    struct Shelf: Sendable {
        var name: String?
        var entries: [Entry]
        var displayName: String { name ?? L10n.text("Unfiled") }
    }

    var format: Format
    var shelves: [Shelf]
    /// Works the person opened in the other app, imported only on request.
    var history: [Entry]
    /// Rows that were not a readable work of a supported catalog.
    var skipped: Int

    var workCount: Int { Set(shelves.flatMap { $0.entries.map(\.id) }).count }
    var isEmpty: Bool { workCount == 0 && history.isEmpty }
}

enum OtherAppImportError: LocalizedError {
    case unrecognized, tooLarge, empty, mangaViewerDatabase, imageAppBackup

    var errorDescription: String? {
        switch self {
        case .unrecognized: return L10n.text("This file isn’t a backup, export or link list TEGNAL can read.")
        case .tooLarge: return L10n.text("This file exceeds the 256 MB import limit.")
        case .empty: return L10n.text("This file holds no works TEGNAL can open.")
        case .mangaViewerDatabase: return L10n.text("This is a manga viewer database. Import it with Import user.db or Import data.db.")
        case .imageAppBackup: return L10n.text("This is an image app backup. Import it in Images mode.")
        }
    }
}

enum OtherAppImport {
    static let maximumBytes = 256 * 1024 * 1024

    /// Reads a picked file or folder. Folders are searched for download manifests.
    static func read(_ url: URL) throws -> OtherAppLibrary {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try readDownloadFolder(url)
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let head = try FileHandle(forReadingFrom: url).readLeading(16)
        if head.starts(with: Array("SQLite format 3".utf8)) {
            // Read a private copy: the picked file may be in iCloud, and SQLite needs a real file.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
            try FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            return try readDatabase(at: copy.path)
        }
        guard size <= maximumBytes else { throw OtherAppImportError.tooLarge }
        return try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Reads a file's bytes: a gzip backup, a JSON export, a manifest or text with links.
    static func parse(_ data: Data, connectedHosts: [String] = ComicSites.all) throws -> OtherAppLibrary {
        guard data.count <= maximumBytes else { throw OtherAppImportError.tooLarge }
        if data.starts(with: [0x1F, 0x8B]) {
            let library = try readerBackup(Gzip.inflate(data))
            guard !library.isEmpty else { throw OtherAppImportError.empty }
            return library
        }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: data) {
            if let records = json as? [[String: Any]], records.contains(where: { $0["config"] is String && $0["type"] != nil }) {
                let library = settingsExport(records)
                guard !library.isEmpty else { throw OtherAppImportError.empty }
                return library
            }
            if let manifest = json as? [String: Any], let entry = manifestEntry(manifest) {
                return OtherAppLibrary(format: .downloadFolder, shelves: [.init(name: L10n.text("Downloads"), entries: [entry])], history: [], skipped: 0)
            }
            if let object = json as? [String: Any], object["data"] is [Any] || object["servers"] is [Any] {
                throw OtherAppImportError.imageAppBackup
            }
        }
        let library = linkList(text, connectedHosts: connectedHosts)
        guard !library.isEmpty else {
            throw library.skipped > 0 || !trimmed.isEmpty ? OtherAppImportError.empty : OtherAppImportError.unrecognized
        }
        return library
    }

    // MARK: - Viewer database export

    static func readDatabase(at path: String) throws -> OtherAppLibrary {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try queue.read { db in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'").map { $0.uppercased() })
            if tables.contains("BOOKMARKARTICLE") || tables.contains("MANGACOLUMNMODEL") { throw OtherAppImportError.mangaViewerDatabase }
            if tables.contains("BOORUITEM") { throw OtherAppImportError.imageAppBackup }
            func columns(_ table: String) throws -> Set<String> {
                guard tables.contains(table) else { return [] }
                return Set(try db.columns(in: table).map { $0.name.uppercased() })
            }
            func hasWorks(_ table: String) throws -> Bool { try columns(table).contains("GID") }
            guard try hasWorks("LOCAL_FAVORITES") || hasWorks("DOWNLOADS") || hasWorks("HISTORY") else { throw OtherAppImportError.unrecognized }
            var skipped = 0
            func entries(_ table: String) throws -> [(Entry, Row)] {
                guard try hasWorks(table) else { return [] }
                let order = try columns(table).contains("TIME") ? "ORDER BY TIME DESC" : ""
                return try Row.fetchAll(db, sql: "SELECT * FROM \(table) \(order)").compactMap { row in
                    guard let entry = viewerEntry(row) else { skipped += 1; return nil }
                    return (entry, row)
                }
            }
            var shelves: [Shelf] = []
            let favorites = try entries("LOCAL_FAVORITES").map(\.0)
            if !favorites.isEmpty { shelves.append(.init(name: L10n.text("Favorites"), entries: favorites)) }
            // Downloads keep their labels as folders, in the order the labels were made.
            var labelled: [String: [Entry]] = [:], unlabelled: [Entry] = []
            for (entry, row) in try entries("DOWNLOADS") {
                let label = (string(row, "LABEL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty { unlabelled.append(entry) } else { labelled[label, default: []].append(entry) }
            }
            if !unlabelled.isEmpty { shelves.append(.init(name: L10n.text("Downloads"), entries: unlabelled)) }
            var labelOrder: [String] = []
            if tables.contains("DOWNLOAD_LABELS") {
                labelOrder = try Row.fetchAll(db, sql: "SELECT * FROM DOWNLOAD_LABELS").compactMap { string($0, "LABEL") }
            }
            for label in labelOrder + labelled.keys.sorted() where labelled[label] != nil {
                shelves.append(.init(name: label, entries: labelled.removeValue(forKey: label) ?? []))
            }
            let history = try entries("HISTORY").map(\.0)
            return OtherAppLibrary(format: .viewerDatabase, shelves: shelves, history: history, skipped: skipped)
        }
    }

    typealias Entry = OtherAppLibrary.Entry
    typealias Shelf = OtherAppLibrary.Shelf

    private static func string(_ row: Row, _ column: String) -> String? {
        for name in [column, column.lowercased()] where row.hasColumn(name) {
            let value: DatabaseValue = row[name]
            switch value.storage {
            case .string(let text): return text
            case .int64(let number): return String(number)
            case .double(let number): return String(number)
            default: return nil
            }
        }
        return nil
    }

    private static func number(_ row: Row, _ column: String) -> Int64? {
        string(row, column).flatMap { Int64($0) ?? Double($0).map { Int64($0) } }
    }

    private static func viewerEntry(_ row: Row) -> Entry? {
        guard let id = number(row, "GID"), (1...9_999_999_999).contains(id) else { return nil }
        var entry = Entry(id: id)
        entry.key = string(row, "TOKEN").flatMap { GalleryKeys.isKey($0) ? $0 : nil }
        entry.title = clean(string(row, "TITLE")) ?? clean(string(row, "TITLE_JPN"))
        entry.type = number(row, "CATEGORY").flatMap { categoryBit(Int($0)) }
        entry.language = string(row, "SIMPLE_LANGUAGE").flatMap(languageCode)
        entry.publishedAt = string(row, "POSTED").flatMap(isoDate)
        if let time = number(row, "TIME"), time > 0 { entry.savedAt = Date(timeIntervalSince1970: Double(time) / 1000) }
        return entry
    }

    /// The category bits these exports keep in `CATEGORY`.
    static func categoryBit(_ value: Int) -> String? {
        switch value {
        case 0x1: return "misc"
        case 0x2: return "doujinshi"
        case 0x4: return "manga"
        case 0x8: return "artistcg"
        case 0x10: return "gamecg"
        case 0x20: return "imageset"
        case 0x40: return "cosplay"
        case 0x80: return "photo"
        case 0x100: return "non-h"
        case 0x200: return "western"
        default: return nil
        }
    }

    /// The short language codes these exports keep. Works without one are in the source language.
    static func languageCode(_ code: String) -> String? {
        switch code.trimmingCharacters(in: .whitespaces).uppercased() {
        case "JA", "JP": return "japanese"
        case "EN": return "english"
        case "ZH", "CN": return "chinese"
        case "KO", "KR": return "korean"
        case "ES": return "spanish"
        case "RU": return "russian"
        case "FR": return "french"
        case "PT": return "portuguese"
        case "TH": return "thai"
        case "DE": return "german"
        case "IT": return "italian"
        case "VI": return "vietnamese"
        case "PL": return "polish"
        case "HU": return "hungarian"
        case "NL": return "dutch"
        default: return nil
        }
    }

    /// A category name such as `Artist CG`, as the library keeps it.
    static func categoryName(_ name: String?) -> String? {
        guard let name else { return nil }
        let key = GalleryCategory.key(name)
        switch key {
        case "", "private", "none": return nil
        case "asianporn": return "photo"
        default: return key
        }
    }

    // MARK: - App data export

    static func settingsExport(_ records: [[String: Any]]) -> OtherAppLibrary {
        var history: [Entry] = [], skipped = 0
        for record in records where integer(record["type"]) == 5 {
            guard let config = record["config"] as? String,
                  let rows = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [[String: Any]] else { continue }
            for row in rows {
                guard let body = (row["jsonBody"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any],
                      var entry = exportedGallery(body, id: integer(row["gid"])) else { skipped += 1; continue }
                entry.savedAt = (row["lastReadTime"] as? String).flatMap(parseDate)
                history.append(entry)
            }
        }
        history.sort { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
        return OtherAppLibrary(format: .settingsExport, shelves: [], history: history, skipped: skipped)
    }

    private static func exportedGallery(_ body: [String: Any], id: Int64?) -> Entry? {
        let link = (body["galleryUrl"] as? String).flatMap { KeyedCatalogSource.links(in: $0).first }
        guard let number = link?.id ?? id ?? integer(body["gid"]), number > 0 else { return nil }
        var entry = Entry(id: number)
        entry.key = link?.key ?? (body["token"] as? String).flatMap { GalleryKeys.isKey($0) ? $0 : nil }
        entry.title = clean(body["title"] as? String)
        entry.type = categoryName(body["category"] as? String)
        entry.language = clean(body["language"] as? String)?.lowercased()
        entry.publishedAt = (body["publishTime"] as? String).flatMap(isoDate)
        if let groups = body["tags"] as? [String: Any] {
            var tags: [(String, String)] = []
            for (namespace, values) in groups {
                for value in values as? [Any] ?? [] {
                    let data = (value as? [String: Any])?["tagData"] as? [String: Any]
                    if let name = (data?["_key"] ?? data?["key"]) as? String ?? value as? String, !name.isEmpty {
                        tags.append(((data?["namespace"] as? String) ?? namespace, name))
                    }
                }
            }
            apply(tags, to: &entry)
        }
        return entry
    }

    /// Splits namespaced tags the way the library keeps them: artists apart, language as the
    /// work's language, the rest as `namespace:name` with local namespace names.
    private static func apply(_ tags: [(String, String)], to entry: inout Entry) {
        for (rawNamespace, name) in tags {
            let namespace = rawNamespace.lowercased()
            switch namespace {
            case "artist": if !entry.artists.contains(name) { entry.artists.append(name) }
            case "language":
                if entry.language == nil, !["translated", "rewrite"].contains(name) { entry.language = name }
            default:
                let local = namespace == "parody" ? "series" : namespace == "other" || namespace.isEmpty || namespace == "misc" ? "tag" : namespace
                entry.tags.append(local + ":" + name)
            }
        }
    }

    // MARK: - Download folders

    static func readDownloadFolder(_ folder: URL) throws -> OtherAppLibrary {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw OtherAppImportError.unrecognized
        }
        var entries: [Entry] = [], skipped = 0, seen = Set<Int64>()
        for case let file as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            guard file.lastPathComponent == "manifest.json",
                  (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= 8 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { continue }
            guard let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entry = manifestEntry(manifest) else { skipped += 1; continue }
            if seen.insert(entry.id).inserted { entries.append(entry) }
        }
        guard !entries.isEmpty else { throw skipped > 0 ? OtherAppImportError.empty : OtherAppImportError.unrecognized }
        entries.sort { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
        return OtherAppLibrary(format: .downloadFolder, shelves: [.init(name: L10n.text("Downloads"), entries: entries)], history: [], skipped: skipped)
    }

    static func manifestEntry(_ manifest: [String: Any]) -> Entry? {
        guard manifest["pages"] != nil, let id = integer(manifest["gid"]), (1...9_999_999_999).contains(id),
              let key = manifest["token"] as? String else { return nil }
        var entry = Entry(id: id)
        entry.key = GalleryKeys.isKey(key) ? key : nil
        entry.title = clean(manifest["title"] as? String) ?? clean(manifest["jpnTitle"] as? String)
        entry.type = categoryName(manifest["category"] as? String)
        let language = clean(manifest["language"] as? String)?.lowercased()
        entry.language = ["n/a", "other"].contains(language ?? "") ? nil : language
        // Dates in these manifests count seconds from 2001.
        if let posted = manifest["postedDate"] as? Double {
            entry.publishedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: posted))
        }
        var tags: [(String, String)] = []
        for group in manifest["tags"] as? [[String: Any]] ?? [] {
            let namespace = group["rawNamespace"] as? String ?? ""
            for content in group["contents"] as? [[String: Any]] ?? [] {
                if let text = content["text"] as? String, !text.isEmpty { tags.append((content["rawNamespace"] as? String ?? namespace, text)) }
            }
        }
        apply(tags, to: &entry)
        return entry
    }

    // MARK: - Manga reader backup

    static func readerBackup(_ data: Data, indexedSourceDigests: Set<String> = indexedSourceDigests) throws -> OtherAppLibrary {
        var reader = ProtoReader(data)
        var mangas: [Data] = [], categories: [(order: Int64, name: String)] = [], indexedSources = Set<UInt64>()
        while let field = try reader.next() {
            switch (field.number, field.wire) {
            case (1, 2): mangas.append(try reader.lengthDelimited())
            case (101, 2):
                var source = ProtoReader(try reader.lengthDelimited())
                var name = "", id: UInt64 = 0
                while let inner = try source.next() {
                    switch (inner.number, inner.wire) {
                    case (1, 2): name = String(decoding: try source.lengthDelimited(), as: UTF8.self)
                    case (2, 0): id = try source.varint()
                    default: try source.skip(inner.wire)
                    }
                }
                if isIndexedSource(name, digests: indexedSourceDigests) { indexedSources.insert(id) }
            case (2, 2):
                var category = ProtoReader(try reader.lengthDelimited())
                var name = "", order: Int64 = 0
                while let inner = try category.next() {
                    switch (inner.number, inner.wire) {
                    case (1, 2): name = String(decoding: try category.lengthDelimited(), as: UTF8.self)
                    case (2, 0): order = Int64(bitPattern: try category.varint())
                    default: try category.skip(inner.wire)
                    }
                }
                if !name.isEmpty { categories.append((order, name)) }
            default: try reader.skip(field.wire)
            }
        }
        guard !mangas.isEmpty || !categories.isEmpty else { throw OtherAppImportError.unrecognized }
        var byCategory: [Int64: [Entry]] = [:], unfiled: [Entry] = [], skipped = 0
        for bytes in mangas {
            var manga = ProtoReader(bytes)
            var url = "", title = "", artist = "", author = "", added: Int64 = 0, favorite = true, orders: [Int64] = [], source: UInt64 = 0
            while let field = try manga.next() {
                switch (field.number, field.wire) {
                case (1, 0): source = try manga.varint()
                case (2, 2): url = String(decoding: try manga.lengthDelimited(), as: UTF8.self)
                case (3, 2): title = String(decoding: try manga.lengthDelimited(), as: UTF8.self)
                case (4, 2): artist = String(decoding: try manga.lengthDelimited(), as: UTF8.self)
                case (5, 2): author = String(decoding: try manga.lengthDelimited(), as: UTF8.self)
                case (13, 0): added = Int64(bitPattern: try manga.varint())
                case (17, 0): orders.append(Int64(bitPattern: try manga.varint()))
                case (17, 2):
                    var packed = ProtoReader(try manga.lengthDelimited())
                    while !packed.isAtEnd { orders.append(Int64(bitPattern: try packed.varint())) }
                case (100, 0): favorite = try manga.varint() != 0
                default: try manga.skip(field.wire)
                }
            }
            guard favorite else { continue }
            guard let link = strictLinks(in: url, connectedHosts: []).first ?? (indexedSources.contains(source) ? indexedSourceLink(url) : nil) else {
                skipped += 1; continue
            }
            var entry = Entry(id: link.id, key: link.key)
            entry.title = clean(title)
            entry.artists = [artist, author].compactMap(clean).flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            entry.artists = entry.artists.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            if added > 0 { entry.savedAt = Date(timeIntervalSince1970: Double(added) / 1000) }
            let known = orders.filter { order in categories.contains { $0.order == order } }
            if known.isEmpty { unfiled.append(entry) }
            for order in known { byCategory[order, default: []].append(entry) }
        }
        var shelves: [Shelf] = []
        if !unfiled.isEmpty { shelves.append(.init(name: nil, entries: unfiled)) }
        for category in categories.sorted(by: { $0.order < $1.order }) {
            if let entries = byCategory.removeValue(forKey: category.order) { shelves.append(.init(name: category.name, entries: entries)) }
        }
        return OtherAppLibrary(format: .readerBackup, shelves: shelves, history: [], skipped: skipped)
    }

    /// The indexed catalog's own source in a reader backup, recognized by a SHA-256 digest of its
    /// lowercased name so the name never appears here. Its entries keep addresses that end in
    /// the work's number, such as `/type/title-123.html`, which elsewhere could be anything.
    static let indexedSourceDigests: Set<String> = [
        "548bcf3e89779bf069f4f1a8cbc4e9e1578b93459ab280db9f6f6328e0a7b4ef",
        "18a79419bbf79acdbb5373ec92b740e97544190c818551fabb8cb8cbfa089be4",
    ]

    static func isIndexedSource(_ name: String, digests: Set<String> = indexedSourceDigests) -> Bool {
        digests.contains(digest(name))
    }

    static func digest(_ name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let numberedPagePattern = try! NSRegularExpression(pattern: #"(?:/(?:manga|galleries|reader)/|-)([0-9]{4,10})\.html(?:[?#].*)?$"#, options: .caseInsensitive)

    private static func indexedSourceLink(_ url: String) -> (id: Int64, key: String?)? {
        let source = url as NSString
        guard let match = numberedPagePattern.firstMatch(in: url, range: NSRange(location: 0, length: source.length)),
              let id = Int64(source.substring(with: match.range(at: 1))) else { return nil }
        return (id, nil)
    }

    // MARK: - Link lists and browser bookmarks

    static func linkList(_ text: String, connectedHosts: [String]) -> OtherAppLibrary {
        let isBookmarkFile = text.range(of: "<DL", options: .caseInsensitive) != nil && text.range(of: "<A ", options: .caseInsensitive) != nil
        var order: [String?] = [], grouped: [String?: [Entry]] = [:], seen: [String?: Set<Int64>] = [:]
        func add(_ entry: Entry, to folder: String?) {
            if grouped[folder] == nil { order.append(folder); grouped[folder] = [] }
            guard seen[folder, default: []].insert(entry.id).inserted else { return }
            grouped[folder]?.append(entry)
        }
        if isBookmarkFile {
            // Netscape bookmark files nest folders as `<DT><H3>name</H3><DL> … </DL>`.
            let pattern = try! NSRegularExpression(pattern: #"<H3([^>]*)>(.*?)</H3>|<DL[^>]*>|</DL>|<A\s([^>]*)>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
            let source = text as NSString
            var stack: [String?] = [], pending: String?? = .none
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let token = source.substring(with: match.range)
                if match.range(at: 2).location != NSNotFound {
                    let attributes = source.substring(with: match.range(at: 1)).uppercased()
                    let name = decodeEntities(source.substring(with: match.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
                    // The browser's own toolbar folder is where loose bookmarks live.
                    pending = .some(attributes.contains("PERSONAL_TOOLBAR_FOLDER") || name.isEmpty ? nil : name)
                } else if token.uppercased().hasPrefix("<DL") {
                    if stack.isEmpty, pending == nil { stack.append(nil) } else { stack.append(pending ?? stack.last ?? nil) }
                    pending = .none
                } else if token.uppercased() == "</DL>" {
                    if !stack.isEmpty { stack.removeLast() }
                } else if match.range(at: 3).location != NSNotFound {
                    let attributes = source.substring(with: match.range(at: 3))
                    guard let href = attribute("HREF", in: attributes) else { continue }
                    for link in strictLinks(in: decodeEntities(href), connectedHosts: connectedHosts) {
                        var entry = Entry(id: link.id, key: link.key)
                        if let added = attribute("ADD_DATE", in: attributes).flatMap(Double.init), added > 0 { entry.savedAt = Date(timeIntervalSince1970: added) }
                        add(entry, to: stack.last ?? nil)
                    }
                }
            }
        } else {
            for link in strictLinks(in: text, connectedHosts: connectedHosts) { add(Entry(id: link.id, key: link.key), to: nil) }
            // A plain list of numbers, one or more per line, names works directly.
            if grouped.isEmpty {
                let tokens = text.components(separatedBy: CharacterSet(charactersIn: " \t\r\n,;")).filter { !$0.isEmpty }
                if !tokens.isEmpty, tokens.allSatisfy({ $0.count >= 4 && $0.count <= 10 && $0.allSatisfy(\.isASCIIDigitCharacter) }) {
                    for token in tokens { if let id = Int64(token), id >= 1000 { add(Entry(id: id), to: nil) } }
                }
            }
        }
        let shelves = order.map { Shelf(name: $0, entries: grouped[$0] ?? []) }
        return OtherAppLibrary(format: .linkList, shelves: shelves, history: [], skipped: 0)
    }

    /// Work links whose shape cannot belong to anything else: a number with its 10-character key,
    /// and the indexed catalog's `galleries/` and `reader/` pages. The shorter shapes (a title
    /// ending in the number, the document catalog's `r/`) are taken only from connected sites.
    static func strictLinks(in text: String, connectedHosts: [String]) -> [(id: Int64, key: String?)] {
        var result: [(id: Int64, key: String?)] = [], seen = Set<Int64>()
        func add(_ id: Int64, _ key: String?) {
            guard (1000...9_999_999_999).contains(id) || key != nil, id > 0, seen.insert(id).inserted else { return }
            result.append((id, key))
        }
        for link in KeyedCatalogSource.links(in: text) + KeyedCatalogSource.viewerLinks(in: text) { add(link.id, link.key) }
        let source = text as NSString
        for match in indexedPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if let id = Int64(source.substring(with: match.range(at: 1))) { add(id, nil) }
        }
        let hosts = Set(connectedHosts.map { BooruServer.bareHost($0) }.filter { !$0.isEmpty })
        guard !hosts.isEmpty else { return result }
        for match in urlPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let address = source.substring(with: match.range)
            guard let url = URL(string: address), let host = url.host, hosts.contains(BooruServer.bareHost(host)) else { continue }
            for id in GalleryIDParser.parse(url.absoluteString) { add(id, nil) }
        }
        return result
    }

    private static let indexedPattern = try! NSRegularExpression(pattern: #"/(?:galleries|reader)/([0-9]{4,10})\.html"#, options: .caseInsensitive)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: .caseInsensitive)

    // MARK: - Helpers

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return (value as? String).flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return NativeGallery.decodeEntities(text)
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#, options: .caseInsensitive)
        let source = attributes as NSString
        guard let match = pattern.firstMatch(in: attributes, range: NSRange(location: 0, length: source.length)) else { return nil }
        return source.substring(with: match.range(at: 1))
    }

    private static func decodeEntities(_ text: String) -> String { NativeGallery.decodeEntities(text) }

    /// Times such as `2024-04-29 23:47`, `2024-04-29 23:47:23.370` or ISO 8601.
    static func parseDate(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func isoDate(_ text: String) -> String? {
        parseDate(text).map { ISO8601DateFormatter().string(from: $0) }
    }
}

// MARK: - Import

struct OtherAppImportOptions: Sendable {
    /// Also save the works from the other app's reading history, in a folder of their own.
    var includeHistory = false
    /// Every work goes into this folder instead of the file's own folders.
    var destination: Int64?
}

struct OtherAppImportResult: Sendable, Equatable {
    let added: Int
    let existing: Int
    let folders: Int
}

extension AppDatabase {
    /// Saves the file's works into folders named like the file's. A work already in the library
    /// keeps its information and folders and is only added to the new folder as well. Keys
    /// in the file are remembered so each work opens without a search.
    func importOtherApp(_ library: OtherAppLibrary, options: OtherAppImportOptions) throws -> OtherAppImportResult {
        var shelves = library.shelves
        if options.includeHistory, !library.history.isEmpty {
            shelves.append(.init(name: L10n.text("Reading History"), entries: library.history))
        }
        let before = Set(try listFolders().compactMap(\.id))
        var added = 0, existing = 0, handled = Set<Int64>(), keys: [(Int64, String)] = []
        defer { GalleryKeys.shared.remember(keys) }
        for shelf in shelves where !shelf.entries.isEmpty {
            try Task.checkCancellation()
            let folderID: Int64
            if let destination = options.destination { folderID = destination }
            else if let name = shelf.name { guard let id = try createFolder(name: name).id else { continue }; folderID = id }
            else { folderID = try unfiledFolderID() }
            for entry in shelf.entries {
                try Task.checkCancellation()
                if let key = entry.key { keys.append((entry.id, key)) }
                if try getWork(galleryId: entry.id) != nil {
                    try addWork(galleryId: entry.id, folderID: folderID)
                    if handled.insert(entry.id).inserted { existing += 1 }
                    continue
                }
                handled.insert(entry.id)
                _ = try upsertWork(galleryId: entry.id, folderId: folderID, title: entry.title,
                                   artists: entry.artists.isEmpty ? nil : entry.artists.joined(separator: ", "),
                                   language: entry.language, type: entry.type,
                                   tags: entry.tags.isEmpty ? nil : entry.tags.joined(separator: ", "),
                                   publishedAt: entry.publishedAt,
                                   bookmarkedAt: entry.savedAt.map { ISO8601DateFormatter().string(from: $0) },
                                   metadataSource: entry.hasMetadata ? "remote" : nil)
                added += 1
            }
        }
        let created = Set(try listFolders().compactMap(\.id)).subtracting(before).count
        return OtherAppImportResult(added: added, existing: existing, folders: created)
    }
}

// MARK: - Gzip and protobuf

enum Gzip {
    /// The members of a gzip file are one raw deflate stream behind a small header.
    static func inflate(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw OtherAppImportError.unrecognized }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { guard index + 2 <= bytes.count else { throw OtherAppImportError.unrecognized }; index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw OtherAppImportError.unrecognized }
        let body = Data(bytes[index..<(bytes.count - 8)])
        let expected = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        guard expected <= 512 * 1024 * 1024 else { throw OtherAppImportError.tooLarge }
        do { return try (body as NSData).decompressed(using: .zlib) as Data }
        catch { throw OtherAppImportError.unrecognized }
    }
}

/// Just enough of the protobuf wire format to walk a backup's messages.
struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func next() throws -> (number: Int, wire: Int)? {
        guard !isAtEnd else { return nil }
        let tag = try varint()
        guard tag >> 3 > 0 else { throw OtherAppImportError.unrecognized }
        return (Int(tag >> 3), Int(tag & 7))
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard index < bytes.count, shift < 64 else { throw OtherAppImportError.unrecognized }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    mutating func lengthDelimited() throws -> Data {
        let length = try varint()
        guard length <= UInt64(bytes.count - index) else { throw OtherAppImportError.unrecognized }
        defer { index += Int(length) }
        return Data(bytes[index..<(index + Int(length))])
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: index += 8
        case 2: _ = try lengthDelimited()
        case 5: index += 4
        default: throw OtherAppImportError.unrecognized
        }
        guard index <= bytes.count else { throw OtherAppImportError.unrecognized }
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

private extension FileHandle {
    func readLeading(_ count: Int) throws -> Data {
        defer { try? close() }
        return try read(upToCount: count) ?? Data()
    }
}
