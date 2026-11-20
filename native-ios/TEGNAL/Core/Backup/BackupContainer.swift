import Compression
import CryptoKit
import Foundation

/// Why a backup was made.
enum BackupKind: String, Codable, CaseIterable, Sendable {
    /// First launch after an update that changed the first or second version number, or from a
    /// version that left no marker.
    case minor
    /// First launch after any other version or build change.
    case patch
    /// "Back Up Now".
    case manual
    /// Made just before a restore.
    case safety
}

enum BackupError: LocalizedError, Equatable {
    case notBackup
    case damaged
    case otherPlatform
    case newerApp
    case tooLarge
    case notDownloaded
    case unavailable
    case databaseUnreadable
    case safetyBackupFailed
    case snapshotFailed(String)

    var errorDescription: String? {
        switch self {
        case .notBackup: return L10n.text("This file is not a TEGNAL backup.")
        case .damaged: return L10n.text("This backup is damaged and cannot be used.")
        case .otherPlatform: return L10n.text("This backup was made on another kind of device and cannot be restored here.")
        case .newerApp: return L10n.text("This backup was made by a newer version of TEGNAL. Update the app to restore it.")
        case .tooLarge: return L10n.text("The backup is too large.")
        case .notDownloaded: return L10n.text("The backup is still downloading from iCloud. Try again in a moment.")
        case .unavailable: return L10n.text("This backup is no longer available.")
        case .databaseUnreadable: return L10n.text("The backup's library could not be opened. Your data was not changed.")
        case .safetyBackupFailed: return L10n.text("The current data could not be backed up first, so nothing was restored.")
        case .snapshotFailed(let reason): return L10n.text("The backup before the update could not be made: %@", reason)
        }
    }
}

/// The JSON at the head of a `.tegnalbackup` file.
struct BackupManifest: Codable, Equatable, Sendable {
    struct Device: Codable, Equatable, Sendable { var id: String; var name: String }
    struct Counts: Codable, Equatable, Sendable { var works: Int; var images: Int }
    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var policy: String
        var size: Int64
        var storedSize: Int64
        var compression: String
        var sha256: String
    }

    var format = "tegnal-backup"
    var version = 1
    var id: String
    var kind: BackupKind
    var platform: String
    var createdAt: Date
    var dataVersion: String?
    var dataBuild: String?
    var appVersion: String
    var appBuild: String
    var device: Device
    var counts: Counts?
    var entries: [Entry] = []

    private enum CodingKeys: String, CodingKey {
        case format, version, id, kind, platform, createdAt, dataVersion, dataBuild, appVersion, appBuild, device, counts, entries
    }

    init(id: String = UUID().uuidString, kind: BackupKind, platform: String = "ios", createdAt: Date, dataVersion: String?, dataBuild: String?,
         appVersion: String, appBuild: String, device: Device, counts: Counts? = nil) {
        self.id = id; self.kind = kind; self.platform = platform; self.createdAt = createdAt
        self.dataVersion = dataVersion; self.dataBuild = dataBuild; self.appVersion = appVersion; self.appBuild = appBuild
        self.device = device; self.counts = counts
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format); try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id); try c.encode(kind, forKey: .kind); try c.encode(platform, forKey: .platform)
        try c.encode(createdAt, forKey: .createdAt)
        // The format writes an unknown data version as null rather than leaving it out.
        try c.encode(dataVersion, forKey: .dataVersion); try c.encode(dataBuild, forKey: .dataBuild)
        try c.encode(appVersion, forKey: .appVersion); try c.encode(appBuild, forKey: .appBuild)
        try c.encode(device, forKey: .device); try c.encodeIfPresent(counts, forKey: .counts)
        try c.encode(entries, forKey: .entries)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The file name this backup is stored under.
    var fileName: String {
        BackupName(kind: kind, dataVersion: dataVersion, dataBuild: dataBuild, createdAt: createdAt, deviceID: device.id).fileName
    }
}

/// `tegnal_<kind>_<dataVersion or 0>_<dataBuild or 0>_<yyyyMMdd'T'HHmmss'Z'>_<device id>.tegnalbackup`,
/// so a list needs neither a download nor the file's contents.
struct BackupName: Equatable, Hashable, Sendable {
    static let fileExtension = "tegnalbackup"
    var kind: BackupKind
    var dataVersion: String?
    var dataBuild: String?
    var createdAt: Date
    var deviceID: String

    init(kind: BackupKind, dataVersion: String?, dataBuild: String?, createdAt: Date, deviceID: String) {
        self.kind = kind
        self.dataVersion = dataVersion.map(Self.part).flatMap { $0 == "0" ? nil : $0 }
        self.dataBuild = dataBuild.map(Self.part).flatMap { $0 == "0" ? nil : $0 }
        // The name keeps whole seconds; the date read back from it must equal the one written.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.deviceID = Self.part(deviceID)
    }

    init?(fileName: String) {
        let suffix = "." + Self.fileExtension
        guard fileName.hasSuffix(suffix) else { return nil }
        let parts = fileName.dropLast(suffix.count).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "tegnal", let kind = BackupKind(rawValue: parts[1]),
              let date = Self.formatter.date(from: parts[4]), !parts[5].isEmpty,
              [parts[2], parts[3], parts[5]].allSatisfy({ $0 == Self.part($0) }) else { return nil }
        self.init(kind: kind, dataVersion: parts[2], dataBuild: parts[3], createdAt: date, deviceID: parts[5])
    }

    var fileName: String {
        ["tegnal", kind.rawValue, dataVersion ?? "0", dataBuild ?? "0", Self.formatter.string(from: createdAt), deviceID].joined(separator: "_")
            + "." + Self.fileExtension
    }

    /// Underscores separate the parts; anything but letters, digits, dots and dashes becomes a dash.
    private static func part(_ value: String) -> String {
        let cleaned = String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" })
        return cleaned.isEmpty ? "0" : cleaned
    }
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// The entries a backup may hold. A name from a file is only ever looked up here, never used as a path.
enum BackupEntry {
    enum Policy: String { case replace, ifMissing }
    static let databases = ["memo.sqlite", "booru.sqlite"]
    static let databaseSuffixes = ["", "-journal", "-wal", "-shm"]
    static let databaseEntries = databases.flatMap { name in databaseSuffixes.map { "db/" + name + $0 } }
    static let standardPreferences = "prefs/standard.plist"
    static let booruPreferences = "prefs/booru.plist"
    static let preferenceEntries = [standardPreferences, booruPreferences]
    static let fileEntries = ["files/gallery-keys", "files/work-missing-sites", "files/downloads.json", "files/downloads-settings.json", "files/generated-index.json"]
    /// Every known entry, in the order a backup stores them.
    static let all = databaseEntries + preferenceEntries + fileEntries

    static func policy(_ name: String) -> Policy? {
        if fileEntries.contains(name) { return .ifMissing }
        return all.contains(name) ? .replace : nil
    }
}

/// Raw DEFLATE (RFC 1951) streamed in chunks, so no entry is ever held whole in memory.
enum Deflate {
    private static let chunk = 1 << 20

    /// Reads `count` bytes from `input` and passes what the stream produces to `output`.
    static func run(_ operation: compression_stream_operation, input: FileHandle, count: Int64,
                    onInput: (Data) -> Void = { _ in }, output: (Data) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw BackupError.damaged }
        defer { compression_stream_destroy(stream) }
        let size = 1 << 16
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { destination.deallocate() }
        // The stream wants a source pointer even when there is nothing left to give it.
        let empty = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { empty.deallocate() }
        var remaining = count, ended = false
        repeat {
            let data = remaining > 0 ? (try input.read(upToCount: Int(min(Int64(chunk), remaining))) ?? Data()) : Data()
            guard remaining == 0 || !data.isEmpty else { throw BackupError.damaged }
            remaining -= Int64(data.count)
            onInput(data)
            let final = remaining == 0
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.isEmpty ? UnsafePointer(empty) : raw.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.src_size = raw.count
                while true {
                    stream.pointee.dst_ptr = destination
                    stream.pointee.dst_size = size
                    let status = compression_stream_process(stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = size - stream.pointee.dst_size
                    if produced > 0 { try output(Data(bytes: destination, count: produced)) }
                    if status == COMPRESSION_STATUS_END { ended = true; break }
                    guard status == COMPRESSION_STATUS_OK else { throw BackupError.damaged }
                    // More input is needed once this chunk is used up and nothing is left to flush.
                    if stream.pointee.src_size == 0 && produced < size && !final { break }
                    if final && stream.pointee.src_size == 0 && produced == 0 { throw BackupError.damaged }
                }
            }
            // A stream that ends before its stored bytes do carries data that belongs to nothing.
            if ended && (remaining > 0 || stream.pointee.src_size > 0) { throw BackupError.damaged }
        } while !ended
    }
}

enum BackupContainer {
    static let magic = Data("TEGNALBK".utf8)
    static let containerVersion: UInt8 = 1
    static let headerSize: Int64 = 13
    static let manifestLimit = 1 << 20
    static let fileLimit: Int64 = 512 << 20
    /// What all entries may add up to once unpacked.
    static let unpackedLimit: Int64 = 2 << 30

    /// Packs the known entries found in `folder` into a backup file at `destination`.
    @discardableResult
    static func write(folder: URL, manifest base: BackupManifest, to destination: URL, work: URL) throws -> BackupManifest {
        let files = FileManager.default
        let scratch = work.appendingPathComponent("pack-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        var manifest = base
        manifest.entries = []
        var bodies: [URL] = []
        for name in BackupEntry.all {
            let source = folder.appendingPathComponent(name)
            guard files.fileExists(atPath: source.path), let policy = BackupEntry.policy(name) else { continue }
            let size = try (files.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            let packed = scratch.appendingPathComponent(String(bodies.count))
            files.createFile(atPath: packed.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: packed)
            var hash = SHA256(), stored: Int64 = 0
            do {
                defer { try? input.close(); try? output.close() }
                try Deflate.run(COMPRESSION_STREAM_ENCODE, input: input, count: size, onInput: { hash.update(data: $0) }) { data in
                    try output.write(contentsOf: data); stored += Int64(data.count)
                }
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            // Data that does not shrink is stored as it is.
            let deflated = stored < size
            manifest.entries.append(.init(name: name, policy: policy.rawValue, size: size, storedSize: deflated ? stored : size,
                                          compression: deflated ? "deflate" : "none", sha256: digest))
            bodies.append(deflated ? packed : source)
        }
        let json = try BackupManifest.encoder.encode(manifest)
        guard json.count <= manifestLimit else { throw BackupError.tooLarge }
        let total = headerSize + Int64(json.count) + manifest.entries.reduce(0) { $0 + $1.storedSize }
        guard total <= fileLimit else { throw BackupError.tooLarge }
        let partial = scratch.appendingPathComponent("backup")
        var header = magic
        header.append(containerVersion)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { header.append(contentsOf: $0) }
        files.createFile(atPath: partial.path, contents: header + json)
        let output = try FileHandle(forWritingTo: partial)
        do {
            defer { try? output.close() }
            try output.seekToEnd()
            for (body, entry) in zip(bodies, manifest.entries) {
                let input = try FileHandle(forReadingFrom: body)
                defer { try? input.close() }
                var remaining = entry.storedSize
                while remaining > 0 {
                    let data = try input.read(upToCount: Int(min(Int64(1 << 20), remaining))) ?? Data()
                    // The file changed while it was read; the entry would not match its checksum.
                    guard !data.isEmpty else { throw BackupError.damaged }
                    try output.write(contentsOf: data); remaining -= Int64(data.count)
                }
            }
            try output.synchronize()
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: partial, to: destination)
        return manifest
    }
}

/// A backup file whose head has been read and checked; its entries are checked as they are read.
struct BackupArchive: Sendable {
    let url: URL
    let manifest: BackupManifest
    let bodyOffset: Int64

    static func open(_ url: URL) throws -> BackupArchive {
        let size = try (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= BackupContainer.headerSize else { throw BackupError.notBackup }
        guard size <= BackupContainer.fileLimit else { throw BackupError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: Int(BackupContainer.headerSize)) ?? Data()
        guard header.count == BackupContainer.headerSize, header.prefix(8) == BackupContainer.magic else { throw BackupError.notBackup }
        guard header[header.startIndex + 8] == BackupContainer.containerVersion else { throw BackupError.notBackup }
        let length = header.suffix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= BackupContainer.manifestLimit else { throw BackupError.notBackup }
        guard Int64(length) <= size - BackupContainer.headerSize else { throw BackupError.damaged }
        let json = try handle.read(upToCount: length) ?? Data()
        guard json.count == length else { throw BackupError.damaged }
        guard let manifest = try? BackupManifest.decoder.decode(BackupManifest.self, from: json),
              manifest.format == "tegnal-backup", manifest.version == 1 else { throw BackupError.notBackup }
        var names = Set<String>()
        var unpacked: Int64 = 0
        for entry in manifest.entries {
            // Bounded before any sum, so no declared size can overflow or ask for more than the file can hold.
            guard entry.size <= BackupContainer.unpackedLimit, entry.storedSize <= BackupContainer.fileLimit else { throw BackupError.tooLarge }
            unpacked += max(0, entry.size)
            guard unpacked <= BackupContainer.unpackedLimit else { throw BackupError.tooLarge }
            guard entry.size >= 0, entry.storedSize >= 0, names.insert(entry.name).inserted,
                  entry.sha256.count == 64, entry.sha256.allSatisfy(\.isHexDigit),
                  entry.compression == "deflate" || (entry.compression == "none" && entry.storedSize == entry.size) else { throw BackupError.damaged }
        }
        let body = BackupContainer.headerSize + Int64(length)
        // A shorter file was cut off; a longer one carries bytes the manifest does not account for.
        guard manifest.entries.reduce(Int64(0), { $0 + $1.storedSize }) == size - body else { throw BackupError.damaged }
        return BackupArchive(url: url, manifest: manifest, bodyOffset: body)
    }

    /// A restore replaces both libraries, so a backup must hold both.
    func checkHoldsLibraries() throws {
        let names = Set(manifest.entries.map(\.name))
        guard BackupEntry.databases.allSatisfy({ names.contains("db/" + $0) }) else { throw BackupError.damaged }
    }

    /// Checks whether this app may restore the backup at all.
    func checkRestorable(appVersion: String, appBuild: String, platform: String = "ios") throws {
        guard manifest.platform == platform else { throw BackupError.otherPlatform }
        if UpdateBackup.isNewer(version: manifest.appVersion, build: manifest.appBuild, than: appVersion, build: appBuild) { throw BackupError.newerApp }
        try checkHoldsLibraries()
    }

    /// Checks every entry's size and checksum, writing the known ones into `folder` under their names.
    /// Without a folder it only checks.
    func extract(to folder: URL?) throws {
        let files = FileManager.default
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = bodyOffset
        for entry in manifest.entries {
            try handle.seek(toOffset: UInt64(offset))
            offset += entry.storedSize
            let target = folder?.appendingPathComponent(entry.name)
            let known = BackupEntry.policy(entry.name) != nil && target != nil
            var output: FileHandle?
            if known, let target {
                try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                files.createFile(atPath: target.path, contents: nil)
                output = try FileHandle(forWritingTo: target)
            }
            var hash = SHA256(), written: Int64 = 0
            do {
                defer { try? output?.close() }
                let sink: (Data) throws -> Void = { data in
                    written += Int64(data.count)
                    // Never inflate past the size the manifest declared.
                    guard written <= entry.size else { throw BackupError.damaged }
                    hash.update(data: data)
                    try output?.write(contentsOf: data)
                }
                if entry.compression == "deflate" {
                    try Deflate.run(COMPRESSION_STREAM_DECODE, input: handle, count: entry.storedSize, output: sink)
                } else {
                    var remaining = entry.storedSize
                    while remaining > 0 {
                        let data = try handle.read(upToCount: Int(min(Int64(1 << 20), remaining))) ?? Data()
                        guard !data.isEmpty else { throw BackupError.damaged }
                        remaining -= Int64(data.count)
                        try sink(data)
                    }
                }
            } catch {
                if let target, known { try? files.removeItem(at: target) }
                throw (error as? BackupError) ?? BackupError.damaged
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard written == entry.size, digest == entry.sha256.lowercased() else {
                if let target, known { try? files.removeItem(at: target) }
                throw BackupError.damaged
            }
        }
    }
}
