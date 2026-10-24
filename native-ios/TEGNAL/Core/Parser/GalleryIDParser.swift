import Foundation

public enum MangaUrls {
    enum Backend: String { case indexed, document }
    static var backend: Backend {
        guard UserDefaults.standard.string(forKey: "manga.resolved_backend_site") == home else { return .indexed }
        return Backend(rawValue: UserDefaults.standard.string(forKey: "manga.resolved_protocol") ?? "") ?? .indexed
    }
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
        home.isEmpty ? "" : backend == .document ? "\(home)r/\(galleryId)" : "\(home)galleries/\(galleryId).html"
    }

    public static func readerUrl(for galleryId: Int64, page: Int = 1) -> String {
        guard !home.isEmpty else { return "" }
        return backend == .document ? "\(home)r/\(galleryId)#\(max(1, page))" : "\(home)reader/\(galleryId).html#\(max(1, page))"
    }

    public static func artistAllUrl(for artist: String) -> String {
        guard !home.isEmpty else { return "" }
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        if backend == .document {
            var url = URLComponents(string: home)!
            url.queryItems = [URLQueryItem(name: "search", value: "artist:" + trimmed.replacingOccurrences(of: " ", with: "_"))]
            return url.url?.absoluteString ?? ""
        }
        return "\(home)artist/\(encoded)-all.html"
    }

    public static var dataHost: String {
        if hasResolvedBackend, let resolved = UserDefaults.standard.string(forKey: "manga.resolved_data_host"), !resolved.isEmpty {
            return resolved
        }
        guard !configuredHost.isEmpty else { return "" }
        return "ltn." + configuredHost
    }

    public static var dataBaseURL: String {
        dataHost.isEmpty ? "" : "https://\(dataHost)/"
    }

    public static var cdnHost: String {
        if hasResolvedBackend, let resolved = UserDefaults.standard.string(forKey: "manga.resolved_cdn_host"), !resolved.isEmpty {
            return resolved
        }
        return configuredHost
    }

    /// A discovered backend belongs to the exact address the user connected.
    /// Persist it across launches; only a connection failure or site change refreshes it.
    static var hasResolvedBackend: Bool {
        let defaults = UserDefaults.standard
        return !home.isEmpty && defaults.string(forKey: "manga.resolved_backend_site") == home
            && !(defaults.string(forKey: "manga.resolved_data_host") ?? "").isEmpty
            && !(defaults.string(forKey: "manga.resolved_cdn_host") ?? "").isEmpty
    }

    /// Read host declarations, never execute downloaded JavaScript. Frontend
    /// gallery HTML links are not data endpoints and must not become the backend.
    @discardableResult
    public static func extractBackend(from text: String) -> Bool {
        extractBackend(from: text, site: home)
    }

    @discardableResult
    static func extractBackend(from text: String, site: String) -> Bool {
        guard !site.isEmpty, home == site else { return false }
        guard let (dataHost, cdn) = indexedBackendHosts(in: text), home == site else { return false }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "manga.resolved_backend_site") != site {
            defaults.removeObject(forKey: "manga.resolved_media_hosts")
            defaults.removeObject(forKey: "manga.resolved_preview_base")
        }
        defaults.set(dataHost, forKey: "manga.resolved_data_host")
        defaults.set(cdn, forKey: "manga.resolved_cdn_host")
        defaults.set(site, forKey: "manga.resolved_backend_site")
        defaults.set(Backend.indexed.rawValue, forKey: "manga.resolved_protocol")
        return true
    }

    /// Protocol recognition without changing the user’s configured connection.
    static func indexedBackendHosts(in text: String) -> (dataHost: String, cdn: String)? {
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).lowercased()
        }
        let domainPattern = #"(?:var|let|const)\s+domain\s*=\s*['"]([a-z0-9-]+(?:\.[a-z0-9-]+)+)['"]"#
        let endpointPattern = #"(?:(?:https?:)?//)([a-z0-9-]+(?:\.[a-z0-9-]+)+)/(?:gg\.js(?:[?"'\s>]|$)|galleries/[0-9]+\.js(?:[?"'\s>]|$))"#
        let scriptPattern = #"(?:(?:https?:)?//)(ltn\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)/common\.js(?:[?"'\s>]|$)"#
        let dataHost: String, cdn: String
        if let domain = capture(domainPattern) {
            cdn = domain.hasPrefix("ltn.") ? String(domain.dropFirst(4)) : domain
            dataHost = "ltn." + cdn
        } else if let host = capture(endpointPattern) ?? capture(scriptPattern) {
            dataHost = host
            cdn = host.hasPrefix("ltn.") ? String(host.dropFirst(4)) : host
        } else { return nil }
        guard [dataHost, cdn].allSatisfy({ host in
            host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
            }
        }) else { return nil }
        return (dataHost, cdn)
    }

    @discardableResult
    static func extractDocumentBackend(from text: String, site: String) -> Bool {
        guard home == site, let host = URL(string: site)?.host,
              isDocumentPage(text) else { return false }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "manga.resolved_backend_site") != site { defaults.removeObject(forKey: "manga.resolved_media_hosts") }
        defaults.set(host, forKey: "manga.resolved_data_host")
        defaults.set(host, forKey: "manga.resolved_cdn_host")
        defaults.set(Backend.document.rawValue, forKey: "manga.resolved_protocol")
        defaults.set(site, forKey: "manga.resolved_backend_site")
        defaults.removeObject(forKey: "manga.resolved_preview_base")
        if let regex = try? NSRegularExpression(pattern: #"thumbServer\s*:\s*(\{[^{}]+\})"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text),
           let data = String(text[range]).data(using: .utf8),
           let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let value = item["url"] as? String, let url = URL(string: value), DocumentCatalogSource.safeMediaURL(url) {
            defaults.set(url.absoluteString, forKey: "manga.resolved_preview_base")
            registerMedia([url], site: site)
        }
        return true
    }

    static func isDocumentPage(_ text: String) -> Bool {
        if text.range(of: #"/js/index\.search\."#, options: .regularExpression) != nil { return true }
        if text.contains("/ajax/search"), text.contains("serverConfig"), text.contains("thumbServer") { return true }
        guard let data = text.data(using: .utf8),
              let gallery = try? DocumentCatalogSource.embeddedObject(data, named: "gallery"),
              (gallery["id"] as? NSNumber)?.int64Value ?? 0 > 0,
              gallery["files"] is [[String: Any]] else { return false }
        return true
    }

    static func isIndexedPage(_ text: String) -> Bool {
        guard indexedBackendHosts(in: text) != nil else { return false }
        return text.contains(".nozomi") || text.range(of: #"/(?:common\.js|gg\.js|galleries/[0-9]+\.js)(?:[?"'\s>]|$)"#, options: .regularExpression) != nil
    }

    static func registerMedia(_ urls: [URL], site: String) {
        guard site == home else { return }
        var hosts = Set(UserDefaults.standard.stringArray(forKey: "manga.resolved_media_hosts") ?? [])
        hosts.formUnion(urls.filter { DocumentCatalogSource.safeMediaURL($0) }.compactMap { $0.host?.lowercased() })
        UserDefaults.standard.set(Array(hosts.prefix(64)), forKey: "manga.resolved_media_hosts")
    }

    static func allowsMedia(_ host: String) -> Bool {
        hasResolvedBackend && backend == .document && (UserDefaults.standard.stringArray(forKey: "manga.resolved_media_hosts") ?? []).contains(host)
    }

    /// Keep discovery anchored to the user's address, including its own common.js.
    static func resolveBackend(transport: ContentTransport = .shared, force: Bool = false) async {
        await MangaBackendResolver.shared.resolve(transport: transport, force: force)
    }

    static func discoverBackend(site: String, transport: ContentTransport) async -> Bool {
        guard let homepage = URL(string: site), !site.isEmpty else { return false }
        var scripts: [URL] = []
        do {
            let (data, _) = try await transport.get(homepage, limit: 1_000_000, timeout: 8)
            guard home == site, !Task.isCancelled else { return false }
            let body = String(decoding: data, as: UTF8.self)
            if extractBackend(from: body, site: site) { return true }
            if extractDocumentBackend(from: body, site: site) { return true }
            let pattern = #"<script\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"]"#
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(match.range(at: 1), in: body),
                      let url = URL(string: String(body[range]), relativeTo: homepage)?.absoluteURL,
                      url.host?.lowercased() == homepage.host?.lowercased(),
                      url.lastPathComponent == "common.js", !scripts.contains(url) else { continue }
                scripts.append(url)
                if scripts.count == 3 { break }
            }
        } catch { }
        let common = homepage.appendingPathComponent("common.js")
        if !scripts.contains(common) { scripts.append(common) }
        for url in scripts {
            guard home == site, !Task.isCancelled else { return false }
            if let (data, _) = try? await transport.get(url, limit: 1_000_000, timeout: 8),
               extractBackend(from: String(decoding: data, as: UTF8.self), site: site) { return true }
        }
        return false
    }

    public static func resetResolvedBackend() {
        for key in ["manga.resolved_data_host", "manga.resolved_cdn_host", "manga.resolved_backend_site", "manga.resolved_protocol", "manga.resolved_media_hosts", "manga.resolved_preview_base"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

}

/// Coalesce discovery for concurrent covers and lists. Failed discovery has a
/// short cooldown; successful discovery lives in UserDefaults without a timer.
private actor MangaBackendResolver {
    static let shared = MangaBackendResolver()
    private var flights: [String: Task<Bool, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    func resolve(transport: ContentTransport, force: Bool) async {
        let site = MangaUrls.home
        guard !site.isEmpty, !Task.isCancelled else { return }
        if let flight = flights[site] { _ = await flight.value; return }
        if !force && MangaUrls.hasResolvedBackend { return }
        if !force, let date = failedAt[site], Date().timeIntervalSince(date) < 10 { return }
        let task = Task { await MangaUrls.discoverBackend(site: site, transport: transport) }
        flights[site] = task
        let succeeded = await task.value
        flights[site] = nil
        if succeeded { failedAt[site] = nil }
        else { failedAt[site] = Date() }
    }
}

public enum GalleryIDParser {
    private static let mangaIdRegex: NSRegularExpression = {
        let pattern = #"(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?(?:galleries|reader|r)/(\d{4,10})(?:\.html)?|(?:(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}/)?[^/\s]+/[^/\s]*-(\d{4,10})\.html"#
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
                    if let decoded = encoded.removingPercentEncoding {
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
