import Foundation

/// Reads a server's tag page into plain blocks of text. Only wording and tag links are kept:
/// embedded posts, tables and markup the app cannot show are dropped, and nothing is fetched or run.
enum StudyDText {
    enum Block: Hashable, Sendable {
        case heading(String)
        case paragraph(AttributedString)
        case bullet(Int, AttributedString)
    }

    /// A link the reader handles itself to open another tag.
    static func link(_ tag: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "tegnaltag"; parts.host = "tag"; parts.queryItems = [.init(name: "name", value: tag)]
        return parts.url
    }
    static func tag(from url: URL) -> String? {
        guard url.scheme == "tegnaltag" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
    }
    /// A page title as a tag name: lowercase, with underscores for spaces.
    static func tagName(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
    }

    static func blocks(_ text: String, limit: Int = 120) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph = []
            if !joined.isEmpty { blocks.append(.paragraph(inline(joined))) }
        }
        var skipping = 0
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            guard blocks.count < limit else { break }
            var line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            // Tables and code hold layout, not wording.
            if lower.hasPrefix("[table") || lower.hasPrefix("[code") || lower.hasPrefix("[nodtext") { skipping += 1 }
            if skipping > 0 {
                if lower.contains("[/table]") || lower.contains("[/code]") || lower.contains("[/nodtext]") { skipping -= 1 }
                continue
            }
            if lower.hasPrefix("!post #") || lower.hasPrefix("!asset #") || lower.hasPrefix("* !post #") || lower.hasPrefix("* !asset #") { continue }
            line = strip(line, pattern: #"\[/?(expand|spoilers?|quote|tn|section|hr|br)(=[^\]]*)?\]"#)
            if line.isEmpty { flush(); continue }
            if let match = firstMatch(#"^h[1-6](#[^.\s]*)?\.\s*(.+)$"#, line) {
                flush(); blocks.append(.heading(String(inline(match[2]).characters))); continue
            }
            if let match = firstMatch(#"^(\*+)\s+(.+)$"#, line) {
                flush(); blocks.append(.bullet(match[1].count, inline(match[2]))); continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// The wording alone, for search, copying and translation.
    static func plain(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .heading(let value): return value
            case .paragraph(let value): return String(value.characters)
            case .bullet(_, let value): return "• " + String(value.characters)
            }
        }.joined(separator: "\n")
    }

    private static func firstMatch(_ pattern: String, _ string: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: string).map { String(string[$0]) } ?? "" }
    }
    private static func strip(_ string: String, pattern: String) -> String {
        string.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
    }

    private static let token = try! NSRegularExpression(pattern: [
        #"\[\[([^\]|]+)(\|([^\]]*))?\]\]"#,            // [[tag]] or [[tag|label]]
        #"\{\{([^}]+)\}\}"#,                            // {{search}}
        #"\[(/?)(b|i|u|s|strong|em)\]"#,                // style marks
        #""([^"\n]+)":\[?(https?://[^\s\]]+|[/#][^\s\]]*)\]?"#, // "label":link
        #"<(https?://[^>\s]+)>"#,                       // <link>
        #"\[/?[a-z]+(=[^\]]*)?\]"#                      // any other mark
    ].joined(separator: "|"), options: [.caseInsensitive])

    static func inline(_ text: String) -> AttributedString {
        var output = AttributedString()
        var bold = 0, italic = 0
        func piece(_ string: String, link: URL? = nil) -> AttributedString {
            var part = AttributedString(string)
            if bold > 0 && italic > 0 { part.inlinePresentationIntent = [.stronglyEmphasized, .emphasized] }
            else if bold > 0 { part.inlinePresentationIntent = .stronglyEmphasized }
            else if italic > 0 { part.inlinePresentationIntent = .emphasized }
            if let link { part.link = link }
            return part
        }
        let whole = NSRange(text.startIndex..., in: text)
        var cursor = text.startIndex
        for match in token.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound { output += piece(String(text[cursor..<range.lowerBound])) }
            cursor = range.upperBound
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
            if let title = group(1) {
                // An empty label means the title without its bracketed qualifier.
                let hasBar = group(2) != nil
                var label = group(3) ?? ""
                if label.isEmpty { label = hasBar ? title.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression) : title }
                let target = title.split(separator: "#").first.map(String.init) ?? title
                output += piece(label, link: target.isEmpty ? nil : link(tagName(target)))
            } else if let search = group(4) {
                output += piece(search)
            } else if let mark = group(6) {
                let closing = group(5) == "/"
                switch mark.lowercased() {
                case "b", "strong": bold = max(0, bold + (closing ? -1 : 1))
                case "i", "em": italic = max(0, italic + (closing ? -1 : 1))
                default: break
                }
            } else if let label = group(7) {
                output += piece(label)
            } else if let address = group(9) {
                output += piece(address)
            }
        }
        if cursor < text.endIndex { output += piece(String(text[cursor...])) }
        return output
    }
}
