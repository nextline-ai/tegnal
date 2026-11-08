import Foundation
import GRDB

/// A search over saved works. Spaces and commas separate terms, and every term must match.
/// `field:value` reads one field exactly, `-` excludes a term and `_` stands for a space.
struct WorkQuery: Equatable, Sendable {
    private struct Term: Equatable, Sendable {
        let excluded: Bool
        let field: String?
        let value: String
    }
    private static let fields: Set<String> = ["artist", "group", "series", "parody", "character", "type", "female", "male", "language", "tag", "meta"]
    private let terms: [Term]

    init(_ text: String, excluding excluded: String = "") {
        terms = Self.tokens(text).compactMap { Self.term($0, excluded: false) } + Self.tokens(excluded).compactMap { Self.term($0, excluded: true) }
    }

    /// Exclusions alone never count, so they cannot select an entire library.
    var isEmpty: Bool { terms.allSatisfy(\.excluded) }

    /// Conditions over the `works` table aliased as `w`.
    var conditions: (sql: String, arguments: [DatabaseValueConvertible]) {
        var clauses: [String] = [], arguments: [DatabaseValueConvertible] = []
        for term in terms {
            let (clause, values) = Self.condition(term)
            clauses.append(term.excluded ? "NOT (\(clause))" : "(\(clause))")
            arguments += values
        }
        return (clauses.joined(separator: " AND "), arguments)
    }

    private static func tokens(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0 == "," }.map(String.init)
    }

    private static func term(_ token: String, excluded: Bool) -> Term? {
        let excluded = excluded || token.hasPrefix("-")
        let raw = token.hasPrefix("-") ? String(token.dropFirst()) : token
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let isField = parts.count == 2 && fields.contains(parts[0].lowercased())
        let value = (isField ? parts[1] : raw).replacingOccurrences(of: "_", with: " ")
        return value.isEmpty ? nil : Term(excluded: excluded, field: isField ? parts[0].lowercased() : nil, value: value)
    }

    private static func condition(_ term: Term) -> (String, [DatabaseValueConvertible]) {
        var clauses: [String] = [], arguments: [DatabaseValueConvertible] = []
        func anyEntry(_ column: String, _ value: String) {
            clauses.append("', ' || REPLACE(COALESCE(\(column), ''), '_', ' ') || ', ' LIKE ? ESCAPE '\\'")
            arguments.append("%, " + escaped(value) + ", %")
        }
        func contains(_ column: String) {
            clauses.append("REPLACE(COALESCE(\(column), ''), '_', ' ') LIKE ? ESCAPE '\\'")
            arguments.append("%" + escaped(term.value) + "%")
        }
        switch term.field {
        case nil:
            for column in ["w.title", "w.artists", "w.groups", "w.series", "w.language", "w.type", "w.tags", "w.note"] { contains(column) }
            if let id = Int64(term.value) { clauses.append("w.gallery_id = ?"); arguments.append(id) }
        case "language": anyEntry("w.language", term.value); anyEntry("w.tags", "language:" + term.value)
        case "artist": anyEntry("w.artists", term.value); anyEntry("w.tags", "artist:" + term.value)
        case "group": anyEntry("w.groups", term.value); anyEntry("w.tags", "group:" + term.value)
        case "series", "parody": anyEntry("w.series", term.value); anyEntry("w.tags", term.field! + ":" + term.value)
        case "type": anyEntry("w.type", term.value); anyEntry("w.tags", "type:" + term.value)
        case "tag": anyEntry("w.tags", term.value); anyEntry("w.tags", "tag:" + term.value)
        case let field?: anyEntry("w.tags", field + ":" + term.value)
        }
        return (clauses.joined(separator: " OR "), arguments)
    }

    /// What a work held outside the library shows, for the same search in memory.
    struct Fields: Sendable {
        var galleryID: Int64
        var title = ""
        var artists = ""
        var groups = ""
        var series = ""
        var language = ""
        var type = ""
        var tags = ""
        var note = ""
    }

    /// The same match the SQL conditions make, over a work's fields in memory: every term must
    /// hit, and an excluded term must miss.
    func matches(_ fields: Fields) -> Bool {
        terms.allSatisfy { term in Self.hits(term, fields) != term.excluded }
    }

    private static func hits(_ term: Term, _ fields: Fields) -> Bool {
        func normalized(_ text: String) -> String { text.replacingOccurrences(of: "_", with: " ").lowercased() }
        let value = term.value.lowercased()
        func contains(_ column: String) -> Bool { normalized(column).contains(value) }
        func anyEntry(_ column: String, _ entry: String) -> Bool { (", " + normalized(column) + ", ").contains(", " + entry.lowercased() + ", ") }
        switch term.field {
        case nil:
            return [fields.title, fields.artists, fields.groups, fields.series, fields.language, fields.type, fields.tags, fields.note].contains(where: contains)
                || Int64(term.value) == fields.galleryID
        case "language": return anyEntry(fields.language, term.value) || anyEntry(fields.tags, "language:" + term.value)
        case "artist": return anyEntry(fields.artists, term.value) || anyEntry(fields.tags, "artist:" + term.value)
        case "group": return anyEntry(fields.groups, term.value) || anyEntry(fields.tags, "group:" + term.value)
        case "series", "parody": return anyEntry(fields.series, term.value) || anyEntry(fields.tags, term.field! + ":" + term.value)
        case "type": return anyEntry(fields.type, term.value) || anyEntry(fields.tags, "type:" + term.value)
        case "tag": return anyEntry(fields.tags, term.value) || anyEntry(fields.tags, "tag:" + term.value)
        case let field?: return anyEntry(fields.tags, field + ":" + term.value)
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
    }
}
