import Foundation

/// One connected website's works, read inside its scope with caches of its own, whichever
/// website is checked.
final class SiteContent: ContentProviding, Sendable {
    let site: String
    private let inner: MangaContentSource

    init(site: String, transport: ContentTransport = .shared) {
        self.site = site
        inner = MangaContentSource(transport: transport)
    }

    func suggestions(for token: String) async throws -> [TagSuggestion] {
        try await SiteScope.$site.withValue(site) { try await inner.suggestions(for: token) }
    }
    func gallery(_ id: Int64) async throws -> NativeGallery {
        try await SiteScope.$site.withValue(site) { try await inner.gallery(id) }
    }
    func list(_ query: GalleryQuery, offset: Int, count: Int) async throws -> GalleryBatch {
        try await SiteScope.$site.withValue(site) { try await inner.list(query, offset: offset, count: count) }
    }
    func image(_ page: GalleryPage, galleryID: Int64, thumbnail: Bool) async throws -> Data {
        try await SiteScope.$site.withValue(site) { try await inner.image(page, galleryID: galleryID, thumbnail: thumbnail) }
    }
    func cachedGallery(_ id: Int64) -> NativeGallery? { SiteScope.$site.withValue(site) { inner.cachedGallery(id) } }
    func cachedPreview(_ id: Int64) -> NativeGallery? { SiteScope.$site.withValue(site) { inner.cachedPreview(id) } }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var sources: [String: SiteContent] = [:]

    /// The shared reader of a connected website.
    static func `for`(_ site: String) -> SiteContent {
        lock.withLock {
            if let source = sources[site] { return source }
            let source = SiteContent(site: site)
            sources[site] = source
            return source
        }
    }
}

/// A work in a list that shows several websites: its number means something only together
/// with the website it came from.
struct FeedItem: Hashable, Sendable {
    let id: Int64
    let site: String
}

struct CombinedBatch: Sendable {
    let items: [FeedItem]
    let hasMore: Bool
}

/// Lists every connected website at once. Each website keeps its own page position; their
/// works are taken in turn, the checked website first. Every website numbers its works the same
/// way, so a number another website already showed is left out before it is shown, and nothing
/// disappears on screen.
actor CombinedCatalog {
    typealias SourceFor = @Sendable (String) -> any ContentProviding
    private let sourceFor: SourceFor
    private let pageSize: Int

    private struct Lane {
        var offset = 0
        var more = true
        var pending: [Int64] = []
        var seen = Set<Int64>()
        var error: Error?
    }
    private var query: GalleryQuery?
    private var sites: [String] = []
    private var lanes: [String: Lane] = [:]
    private var emitted: [FeedItem] = []
    private var shown = Set<Int64>()
    /// Works left out because another website already showed them.
    private(set) var leftOut = 0

    init(pageSize: Int = 24, sourceFor: @escaping SourceFor = { SiteContent.for($0) }) {
        self.pageSize = pageSize
        self.sourceFor = sourceFor
    }

    /// `offset` 0 starts over; later offsets continue, and one already answered is answered
    /// again the same way, so a page whose answer was dropped is not lost.
    func list(_ query: GalleryQuery, sites: [String], offset: Int, count: Int) async throws -> CombinedBatch {
        if offset == 0 || query != self.query || sites != self.sites { reset(query, sites: sites) }
        while emitted.count < offset + count, lanes.values.contains(where: { !$0.pending.isEmpty || $0.more }) {
            try await fill()
            try Task.checkCancellation()
            if !takeRound() && !lanes.values.contains(where: { $0.more }) { break }
        }
        if emitted.count <= offset, let error = sites.compactMap({ lanes[$0]?.error }).first,
           sites.allSatisfy({ lanes[$0]?.error != nil || (lanes[$0]?.pending.isEmpty == true && lanes[$0]?.more == false) }) {
            throw error
        }
        let more = lanes.values.contains { !$0.pending.isEmpty || $0.more }
        let page = Array(emitted.dropFirst(offset).prefix(count))
        return CombinedBatch(items: page, hasMore: more || emitted.count > offset + count)
    }

    private func reset(_ query: GalleryQuery, sites: [String]) {
        self.query = query
        self.sites = sites
        lanes = Dictionary(uniqueKeysWithValues: sites.map { ($0, Lane()) })
        emitted = []; shown = []; leftOut = 0
    }

    /// Reads the next page of every website that has run out of works to give.
    private func fill() async throws {
        guard let query else { return }
        let needed = sites.filter { lanes[$0]?.pending.isEmpty == true && lanes[$0]?.more == true }
        guard !needed.isEmpty else { return }
        let pageSize = pageSize, sourceFor = sourceFor
        let pages = await withTaskGroup(of: (String, Result<GalleryBatch, Error>).self) { group in
            for site in needed {
                let offset = lanes[site]!.offset
                group.addTask { (site, await Result(catching: { try await sourceFor(site).list(query, offset: offset, count: pageSize) })) }
            }
            var result: [String: Result<GalleryBatch, Error>] = [:]
            for await (site, page) in group { result[site] = page }
            return result
        }
        try Task.checkCancellation()
        for (site, page) in pages {
            guard var lane = lanes[site] else { continue }
            switch page {
            case .success(let batch):
                lane.offset += batch.ids.count
                lane.more = batch.hasMore && !batch.ids.isEmpty
                for id in batch.ids where lane.seen.insert(id).inserted { lane.pending.append(id) }
            case .failure(let error):
                // One website failing leaves the others showing.
                if error is CancellationError { throw error }
                lane.error = error; lane.more = false
            }
            lanes[site] = lane
        }
    }

    /// Takes one work from each website in turn. Returns whether any was taken.
    private func takeRound() -> Bool {
        var took = false
        for site in sites {
            guard var lane = lanes[site] else { continue }
            while !lane.pending.isEmpty {
                let item = FeedItem(id: lane.pending.removeFirst(), site: site)
                guard shown.insert(item.id).inserted else { leftOut += 1; continue }
                emitted.append(item)
                took = true
                break
            }
            lanes[site] = lane
        }
        return took
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
