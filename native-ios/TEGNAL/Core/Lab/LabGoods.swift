import Foundation
import Observation

/// Brings what was bought in the shop onto this device: course files, add-ons and home scenes, each downloaded from TEGNAL's
/// server and checked against the size and SHA-256 the signed shop list gives. Purchases travel between devices in the lab's
/// records; the files do not, so a device that has the purchase but not the files offers to download them again, for free.
@MainActor @Observable
final class LabGoods {
    static let shared = LabGoods()

    /// Items being downloaded now.
    private(set) var working: Set<String> = []
    /// The last failure for an item, to show on its card.
    private(set) var failures: [String: String] = [:]
    /// Installed add-ons, by id: version and whether the copy is the official one.
    private(set) var addons: [String: (version: String, official: Bool)] = [:]
    @ObservationIgnored private var booru: BooruStore?
    @ObservationIgnored var market = AddonMarket.live

    /// Called when the app starts, so add-ons can be installed into the image database.
    func attach(_ booru: BooruStore) {
        self.booru = booru
        readAddons()
    }

    func readAddons() {
        guard let booru, let installed = try? AddonStore(booru).installed() else { return }
        addons = Dictionary(installed.map { ($0.addon.id, ($0.addon.version, $0.official)) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: State

    /// True when an owned item needs nothing more on this device.
    func delivered(_ item: LabShopItem) -> Bool {
        if item.file != nil { return LearningCourses.shared.has(item: item.id) }
        if let addon = item.addon {
            guard let installed = addons[addon.id], installed.official else { return false }
            return AddonCheck.compare(installed.version, addon.version) != .orderedAscending
        }
        if let home = item.home { return HomeScenes.has(item.id, home) }
        return true
    }

    /// True when an older copy of an owned add-on or home scene is here and a newer one is for sale.
    func outdated(_ item: LabShopItem) -> Bool {
        if let addon = item.addon, let installed = addons[addon.id], installed.official {
            return AddonCheck.compare(installed.version, addon.version) == .orderedAscending
        }
        if let home = item.home { return HomeScenes.kept(item.id) && !HomeScenes.has(item.id, home) }
        return false
    }

    // MARK: Delivering

    /// Downloads and installs what an owned item brings. Safe to call again: it only redoes what is missing.
    func deliver(_ item: LabShopItem) async {
        guard !working.contains(item.id), item.supported else { return }
        working.insert(item.id)
        failures[item.id] = nil
        defer { working.remove(item.id) }
        do {
            if let file = item.file {
                try LearningCourses.shared.addOfficial(data: try await download(file), item: item.id)
            } else if let listing = item.addon {
                guard let booru else { throw AddonMarketError.offline }
                let data = try await download(listing.file)
                let read = try Addon.decode(data)
                guard read.addon.id == listing.id, read.addon.version == listing.version, read.addon.mode == listing.mode else { throw AddonMarketError.damaged }
                try AddonStore(booru).install(read.addon, digest: read.digest, official: true)
                AddonRuntime.apply(booru)
                readAddons()
            } else if let home = item.home {
                var files: [String: Data] = [:]
                for (role, file) in home.files { files[role] = try await download(file) }
                try HomeScenes.keep(item.id, home: home, files: files)
            }
        } catch is CancellationError {
        } catch {
            // A file that is not the published one says so; anything else (offline, server) asks to try again.
            failures[item.id] = error as? AddonMarketError == .damaged ? AddonMarketError.damaged.errorDescription : L10n.text("lab.shop.downloadFailed")
        }
    }

    /// One file from TEGNAL's server, refused unless it is exactly the one the signed list names.
    func download(_ file: LabShopFile) async throws -> Data {
        guard file.valid else { throw AddonMarketError.damaged }
        let data = try await market.fetch(market.base.appending(path: file.path), file.size)
        guard data.count == file.size, LabCourseFile.digest(data) == file.sha256 else { throw AddonMarketError.damaged }
        return data
    }
}

// MARK: - Home scenes

/// Home scenes bought in the shop, each kept in its own folder, and the one chosen to open the app with.
/// The home scene (`HomeMedia.swift`) asks here for its films, still, music and colours, and falls back to the app's own.
enum HomeScenes {
    static let chosenKey = "home.scene"
    static let changed = Notification.Name("HomeScenes.changed")

    private struct Kept: Codable {
        /// File name and SHA-256 by role (`intro`, `loop`, `still`, `theme`).
        var files: [String: [String]]
        var palette: [String: String]?
    }

    nonisolated(unsafe) static var defaults = UserDefaults.standard
    nonisolated(unsafe) static var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "HomeScenes", directoryHint: .isDirectory)

    private static func folder(_ item: String) -> URL { root.appending(path: item, directoryHint: .isDirectory) }
    private static func kept(_ item: String) -> Kept? {
        (try? Data(contentsOf: folder(item).appending(path: "scene.json"))).flatMap { try? JSONDecoder().decode(Kept.self, from: $0) }
    }

    /// True when a home scene's files are here, whatever their version.
    static func kept(_ item: String) -> Bool { kept(item) != nil }

    /// True when exactly these files are here.
    static func has(_ item: String, _ home: LabShopHome) -> Bool {
        guard let kept = kept(item) else { return false }
        return home.files.allSatisfy { kept.files[$0.role]?.last == $0.file.sha256 }
    }

    static func keep(_ item: String, home: LabShopHome, files: [String: Data]) throws {
        let staging = root.appending(path: "." + item + "-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var names: [String: [String]] = [:]
        for (role, file) in home.files {
            guard let data = files[role] else { continue }
            let name = role + "." + ((file.name as NSString).pathExtension.isEmpty ? "bin" : (file.name as NSString).pathExtension.lowercased())
            try data.write(to: staging.appending(path: name))
            names[role] = [name, file.sha256]
        }
        try JSONEncoder().encode(Kept(files: names, palette: home.palette)).write(to: staging.appending(path: "scene.json"))
        try? FileManager.default.removeItem(at: folder(item))
        try FileManager.default.moveItem(at: staging, to: folder(item))
        if chosen == item { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// The scene the app opens with, or nil for the app's own.
    static var chosen: String? {
        guard let item = defaults.string(forKey: chosenKey), kept(item) != nil else { return nil }
        return item
    }

    static func choose(_ item: String?) {
        guard item != defaults.string(forKey: chosenKey) else { return }
        defaults.set(item, forKey: chosenKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A file of the chosen scene: `intro`, `loop`, `still` or `theme`.
    static func url(_ role: String) -> URL? {
        guard let item = chosen, let name = kept(item)?.files[role]?.first else { return nil }
        let url = folder(item).appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A colour of the chosen scene (`sky`, `ground`, `dusk`) as 0xRRGGBB.
    static func color(_ name: String) -> UInt32? {
        guard let item = chosen else { return nil }
        return kept(item)?.palette?[name].flatMap(LabShopHome.hex)
    }
}
