import Foundation

/// The image server routing an indexed catalog publishes as a small script, read without running it.
/// It is read in pieces, so a reformatted file, another group of cases or another server number still
/// routes; only a script with a piece this reading can't explain is refused.
struct CDNRouting: Sendable {
    let prefix: String
    let defaultValue: Int
    /// The server number each listed bucket goes to instead of the default.
    let bucketValues: [Int: Int]

    init(_ text: String) throws {
        guard let prefix = Self.matches(#"\bb\s*:\s*['"]([0-9]+/)['"]"#, in: text).first?[1],
              let initial = Self.matches(#"\bvar\s+o\s*=\s*([0-9]{1,2})\s*;"#, in: text).first.flatMap({ Int($0[1]) }), initial < 26 else {
            throw ContentError.unsupportedFormat
        }
        var values: [Int: Int] = [:]
        var read = 0
        for group in Self.matches(#"((?:\bcase\s+[0-9]+\s*:\s*)+)o\s*=\s*([0-9]{1,2})\s*;\s*break\s*;"#, in: text) {
            guard let value = Int(group[2]), value < 26 else { throw ContentError.unsupportedFormat }
            for item in Self.matches(#"\bcase\s+([0-9]+)\s*:"#, in: group[1]) {
                guard let bucket = Int(item[1]), (0..<4096).contains(bucket) else { throw ContentError.unsupportedFormat }
                values[bucket] = value
                read += 1
            }
        }
        // Every case the script lists has to be one this reading understood.
        guard read == Self.matches(#"\bcase\s+[0-9]+\s*:"#, in: text).count else { throw ContentError.unsupportedFormat }
        self.prefix = prefix
        defaultValue = initial
        bucketValues = values
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
        }
    }

    func url(hash: String, format: String, thumbnail: Bool) throws -> URL {
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              ["webp", "avif"].contains(format),
              let bucket = Int(String(hash.suffix(1)) + String(hash.suffix(3).prefix(2)), radix: 16) else {
            throw ContentError.unsupportedFormat
        }
        let value = bucketValues[bucket] ?? defaultValue
        // Thumbnail servers are lettered from a, page servers numbered from 1.
        guard let letter = UnicodeScalar(97 + value) else { throw ContentError.unsupportedFormat }
        let host = thumbnail ? "\(Character(letter))tn" : "\(format == "webp" ? "w" : "a")\(1 + value)"
        let path = thumbnail
            ? "\(format)smalltn/\(hash.suffix(1))/\(hash.suffix(3).prefix(2))/\(hash).\(format)"
            : "\(prefix)\(bucket)/\(hash).\(format)"
        let cdn = MangaUrls.cdnHost
        guard !cdn.isEmpty, let url = URL(string: "https://\(host).\(cdn)/\(path)") else { throw ContentError.invalidResponse }
        return url
    }
}
