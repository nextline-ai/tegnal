import CryptoKit
import Foundation

// MARK: - The catalog

/// The list of official add-ons, published by TEGNAL beside their files as `catalog.json`.
///
/// That file holds the list's exact bytes and their signature together (`{"payload": base64, "signature": base64}`),
/// so the two always change at once. The list is signed with TEGNAL's key and names each file's size and SHA-256, so the app installs only
/// the copy that was published, even if the server that holds the files were changed by someone else.
/// A downloaded file is then read and checked exactly like a file the learner opens.
struct AddonCatalog: Codable, Equatable, Sendable {
    static let format = "tegnal-addon-catalog"
    static let schemaVersion = 1
    static let maximumBytes = 1024 * 1024

    var format = AddonCatalog.format
    var schemaVersion = AddonCatalog.schemaVersion
    var addons: [AddonListing]

    init(addons: [AddonListing]) { self.addons = addons }

    /// An entry that is not shaped like one is left out, rather than hiding the whole list.
    init(from decoder: Decoder) throws {
        struct Lossy: Decodable {
            let listing: AddonListing?
            init(from decoder: Decoder) throws { listing = try? AddonListing(from: decoder) }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        addons = try container.decode([Lossy].self, forKey: .addons).compactMap(\.listing)
    }
}

/// One official add-on in the catalog. Its file lives at `files/<id>/<version>.tegnaladdon`.
struct AddonListing: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var version: String
    var name: StudyText
    var author: String
    var summary: StudyText?
    /// `translations`, `searchTags`, `challenges` and `track`.
    var kinds: [String]
    var size: Int
    var sha256: String
    /// The add-on file format it is written in. One newer than the app's is shown but cannot be installed.
    var schemaVersion: Int?

    var title: String { name.addonResolved() }
    var addonKinds: [AddonKind] { kinds.compactMap(AddonKind.init(rawValue:)) }
    var path: String { "files/\(id)/\(version).\(Addon.fileExtension)" }
    var supported: Bool { (schemaVersion ?? 1) <= Addon.schemaVersion }

    var valid: Bool {
        AddonCheck.identifier(id) && AddonCheck.version(version) && AddonCheck.text(name, max: 80) && AddonCheck.line(author, max: 80)
            && (summary.map { AddonCheck.text($0, max: 600, multiline: true) } ?? true)
            && (1...Addon.maximumBytes).contains(size)
            && sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && kinds.count <= 8 && (schemaVersion ?? 1) >= 1
    }
}

/// How an official add-on in the catalog stands against what is installed.
enum AddonListingState: Equatable {
    case get, installed, update, fromFile, unsupported

    init(_ listing: AddonListing, installed: InstalledAddon?) {
        if !listing.supported { self = .unsupported; return }
        guard let installed else { self = .get; return }
        if !installed.official { self = .fromFile; return }
        if installed.digest == listing.sha256 { self = .installed; return }
        self = AddonCheck.compare(listing.version, installed.addon.version) == .orderedDescending ? .update : .installed
    }
}

enum AddonMarketError: LocalizedError, Equatable {
    case offline, server(Int), unsigned, damaged
    var errorDescription: String? {
        switch self {
        case .offline: return L10n.text("The add-on server could not be reached. Check your connection and try again.")
        case .server(let status): return L10n.text("The add-on server answered with an error (%@). Try again later.", String(status))
        case .unsigned: return L10n.text("The list of official add-ons could not be confirmed as TEGNAL’s, so it is not shown. Try again later.")
        case .damaged: return L10n.text("The downloaded file did not match the official copy, so it was not installed.")
        }
    }
}

// MARK: - The market

/// Reads the official catalog and downloads its add-ons from TEGNAL's file server.
struct AddonMarket: Sendable {
    /// TEGNAL's add-on bucket, served over HTTPS.
    static let liveBase = URL(string: "https://addons.nextline.work/v1/")!
    /// The public half of TEGNAL's add-on signing key: an uncompressed P-256 point, base64.
    static let livePublicKey = "BPv9FYG+EK8HUde5G9dQdmXEWBKuKxfugSVz/Kz1QjeSsCX6gd+IJ0ijqdBjgo705slZl5eK981OZYgzicVCzsk="
    static let live = AddonMarket(base: liveBase, publicKey: try! P256.Signing.PublicKey(x963Representation: Data(base64Encoded: livePublicKey)!))

    let base: URL
    let publicKey: P256.Signing.PublicKey
    /// Fetches one file, no larger than the limit given. Replaced in tests.
    var fetch: @Sendable (URL, Int) async throws -> Data = AddonMarket.get(_:limit:)

    func catalog() async throws -> AddonCatalog {
        try Self.open(try await fetch(base.appending(path: "catalog.json"), AddonCatalog.maximumBytes * 2), key: publicKey)
    }

    /// Downloads an official add-on and checks it against the signed catalog before reading it.
    func download(_ listing: AddonListing) async throws -> (addon: Addon, digest: String) {
        let data = try await fetch(base.appending(path: listing.path), listing.size)
        return try Self.check(data, against: listing)
    }

    /// Reads the published `catalog.json`: the list's bytes and their signature.
    static func open(_ file: Data, key: P256.Signing.PublicKey) throws -> AddonCatalog {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: file),
              let payload = Data(base64Encoded: envelope.payload), let signature = Data(base64Encoded: envelope.signature) else { throw AddonMarketError.unsigned }
        return try verify(payload, signature: signature, key: key)
    }

    /// Checks the signature (ECDSA P-256 with SHA-256, DER) over the exact bytes of the list, then reads it.
    /// Entries that do not pass are left out.
    static func verify(_ data: Data, signature der: Data, key: P256.Signing.PublicKey) throws -> AddonCatalog {
        guard data.count <= AddonCatalog.maximumBytes,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: data) else { throw AddonMarketError.unsigned }
        guard var catalog = try? JSONDecoder().decode(AddonCatalog.self, from: data), catalog.format == AddonCatalog.format else { throw AddonMarketError.unsigned }
        guard catalog.schemaVersion <= AddonCatalog.schemaVersion else { throw AddonError.newerFormat }
        var seen = Set<String>()
        catalog.addons = catalog.addons.filter { $0.valid && seen.insert($0.id).inserted }
        return catalog
    }

    static func check(_ data: Data, against listing: AddonListing) throws -> (addon: Addon, digest: String) {
        guard data.count == listing.size, Addon.digest(data) == listing.sha256 else { throw AddonMarketError.damaged }
        let read = try Addon.decode(data)
        guard read.addon.id == listing.id, read.addon.version == listing.version else { throw AddonMarketError.damaged }
        return read
    }

    @Sendable static func get(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AddonMarketError.offline }
        guard let http = response as? HTTPURLResponse else { throw AddonMarketError.offline }
        guard http.statusCode == 200 else { throw AddonMarketError.server(http.statusCode) }
        guard data.count <= limit else { throw AddonMarketError.damaged }
        return data
    }
}
