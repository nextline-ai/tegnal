import Foundation

public enum MangaUrls {
    public static var configuredHome: String {
        let saved = UserDefaults.standard.string(forKey: "manga.site_address")
        if let saved, !saved.isEmpty {
            let clean = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.contains("://") {
                return clean.hasSuffix("/") ? clean : clean + "/"
            } else {
                return "https://\(clean)/"
            }
        }
        return ""
    }

    public static var home: String {
        configuredHome
    }

    public static var configuredHost: String {
        URL(string: home)?.host?.lowercased() ?? ""
    }

    public static var source: String { String(home.dropLast(home.hasSuffix("/") ? 1 : 0)) }

    public static func galleryUrl(for galleryId: Int64) -> String {
        home.isEmpty ? "" : "\(home)galleries/\(galleryId).html"
    }

    public static func artistAllUrl(for artist: String) -> String {
        guard !home.isEmpty else { return "" }
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return "\(home)artist/\(encoded)-all.html"
    }

    public static var dataHost: String {
        if let resolved = UserDefaults.standard.string(forKey: "manga.resolved_data_host"), !resolved.isEmpty {
            return resolved
        }
        guard !configuredHost.isEmpty else { return "" }
        return "ltn." + configuredHost
    }

    public static var dataBaseURL: String {
        dataHost.isEmpty ? "" : "https://\(dataHost)/"
    }

    public static var cdnHost: String {
        if let resolved = UserDefaults.standard.string(forKey: "manga.resolved_cdn_host"), !resolved.isEmpty {
            return resolved
        }
        return configuredHost
    }

    /// Extracts backend data host and CDN domain directly from site HTML or script content.
    @discardableResult
    public static func extractBackend(from text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let patterns = [
            #"//(?:([a-zA-Z0-9-]+)\.)?([a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)/(?:gg\.js|galleries/)"#,
            #"var\s+domain\s*=\s*['"]([a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)['"]"#,
            #"(?:https?:)?//([a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)/gg\.js"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let nsText = text as NSString
                if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    let domain = nsText.substring(with: match.range(at: 2)).lowercased()
                    let prefix = match.range(at: 1).location != NSNotFound ? nsText.substring(with: match.range(at: 1)).lowercased() : "ltn"
                    let host = prefix.isEmpty ? "ltn." + domain : prefix + "." + domain
                    UserDefaults.standard.set(host, forKey: "manga.resolved_data_host")
                    UserDefaults.standard.set(domain, forKey: "manga.resolved_cdn_host")
                    return true
                } else if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    let found = nsText.substring(with: match.range(at: 1)).lowercased()
                    let domain = found.hasPrefix("ltn.") ? String(found.dropFirst(4)) : found
                    let host = found.hasPrefix("ltn.") ? found : "ltn." + domain
                    UserDefaults.standard.set(host, forKey: "manga.resolved_data_host")
                    UserDefaults.standard.set(domain, forKey: "manga.resolved_cdn_host")
                    return true
                }
            }
        }
        return false
    }

    /// Discovers and extracts backend hosts using the user's configured site URL.
    static func resolveBackend(transport: ContentTransport? = nil) async {
        guard !home.isEmpty, let target = URL(string: home) else { return }
        var request = URLRequest(url: target)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let body = String(data: data, encoding: .utf8) {
                _ = extractBackend(from: body)
            }
        } catch { }
    }

    public static func resetResolvedBackend() {
        UserDefaults.standard.removeObject(forKey: "manga.resolved_data_host")
        UserDefaults.standard.removeObject(forKey: "manga.resolved_cdn_host")
    }

}

public enum GalleryIDParser {
    private static let mangaIdRegex: NSRegularExpression = {
        let pattern = #"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?(?:galleries|reader)/(\d{4,10})(?:\.html)?|(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?[^/\s]+/[^/\s]*-(\d{4,10})\.html"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let nestedUrlRegex: NSRegularExpression = {
        let pattern = #"[?&]u=([^&\s]+)"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let tokenDigitsRegex: NSRegularExpression = {
        let pattern = #"^\d{4,10}$"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Extracts gallery IDs from text, URLs, or share payloads.
    public static func parse(_ raw: String) -> [Int64] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var ids: [Int64] = []
        var seen = Set<Int64>()

        func add(_ digits: String) {
            guard let id = Int64(digits), id >= 1000, id <= 9_999_999_999 else { return }
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        func addFrom(_ value: String, depth: Int = 0) {
            guard depth <= 3 else { return }
            let nsValue = value as NSString
            let matches = mangaIdRegex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
            for match in matches {
                if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    add(nsValue.substring(with: match.range(at: 1)))
                } else if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                    add(nsValue.substring(with: match.range(at: 2)))
                }
            }

            let nestedMatches = nestedUrlRegex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
            for match in nestedMatches {
                if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
                    let encoded = nsValue.substring(with: match.range(at: 1))
                    if let decoded = encoded.removingPercentEncoding, (decoded.localizedCaseInsensitiveContains("manga") || decoded.contains("galleries") || decoded.contains("reader")) {
                        addFrom(decoded, depth: depth + 1)
                    }
                }
            }
        }

        addFrom(text)
        if !ids.isEmpty {
            return ids
        }

        // Fallback: split by whitespace, comma, semicolons
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " \t\r\n,;"))
        for token in tokens {
            let nsToken = token as NSString
            let matches = tokenDigitsRegex.matches(in: token, range: NSRange(location: 0, length: nsToken.length))
            if !matches.isEmpty {
                add(token)
            }
        }

        return ids
    }
}
