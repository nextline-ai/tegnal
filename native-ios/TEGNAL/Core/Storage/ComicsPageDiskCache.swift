import Foundation

/// The one on-device cache of comics pages and previews. Every viewer, list and cover reader
/// shares it, so its size limit holds for the whole app instead of for each screen.
actor ComicsPageDiskCache {
    static let shared = ComicsPageDiskCache()
    static let capacityKey = "manga.pageCacheMegabytes"
    /// Sizes a person can pick, in megabytes.
    static let choices = [256, 512, 1024, 2048, 4096]
    static let defaultMegabytes = 512
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaPageCache", isDirectory: true)
    }

    static var configuredMegabytes: Int {
        let value = ReaderPreferences.defaults.integer(forKey: capacityKey)
        return choices.contains(value) ? value : defaultMegabytes
    }

    private var disk: BooruThumbnailDiskCache

    init(directory: URL = ComicsPageDiskCache.directory, megabytes: Int = ComicsPageDiskCache.configuredMegabytes) {
        disk = BooruThumbnailDiskCache(directory: directory, capacity: megabytes * 1024 * 1024, fileExtension: "page")
    }

    var capacity: Int { disk.capacity }

    func read(_ key: String) -> Data? { disk.capacity > 0 ? disk.read(key) : nil }

    func write(_ data: Data, key: String) { if disk.capacity > 0 { disk.write(data, key: key) } }

    func usedBytes() -> Int { disk.usedBytes() }

    func clear() { disk.clear() }

    /// Applies a new size limit at once, removing the least recently viewed pages above it.
    func setMegabytes(_ megabytes: Int) {
        guard Self.choices.contains(megabytes) else { return }
        ReaderPreferences.defaults.set(megabytes, forKey: Self.capacityKey)
        disk = BooruThumbnailDiskCache(directory: disk.directory, capacity: megabytes * 1024 * 1024, fileExtension: "page")
        _ = disk.usedBytes()
    }
}
