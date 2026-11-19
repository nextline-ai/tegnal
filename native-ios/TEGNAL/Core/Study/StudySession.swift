import Foundation
import Observation

/// Reads what the connected servers know about tags, and example pictures, within the app's own limits:
/// only the servers chosen for browsing are asked, and hidden or blacklisted pictures stay out.
enum StudyLookup {
    /// The server asked about tags: one that answers tag pages if any is chosen, since only that kind has them.
    static func infoServer(_ store: BooruStore) -> BooruServer? {
        store.selectedServers.first { $0.engine == .danbooru } ?? store.selectedServers.first
    }

    static func shown(_ posts: [BooruPost], store: BooruStore) -> [BooruPost] {
        var blacklists: [String: BooruBlacklist] = [:]
        return posts.filter { post in
            guard StudyEngine.usable(post), store.isVisible(post), store.isShownInSafeMode(post) else { return false }
            let blacklist = blacklists[post.serverID] ?? BooruBlacklist(store.filteringBlacklist(serverID: post.serverID))
            blacklists[post.serverID] = blacklist
            return !blacklist.contains(post)
        }
    }

    /// Stops waiting after a few seconds, so a slow server never holds up a question.
    static func hurried<T: Sendable>(seconds: Double = 8, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await work() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Pictures carrying a tag from one of the chosen servers.
    static func examples(_ tag: String, store: BooruStore, source: any BooruProviding, page: Int = 0) async -> [BooruPost] {
        guard let server = store.selectedServers.randomElement() else { return [] }
        let batch = await hurried { try await source.posts(server: server, query: tag, page: page) }
        return shown(batch?.posts ?? [], store: store)
    }

    /// Pictures carrying a tag from the one server learning mode reads. That server was chosen for learning,
    /// so the choice of browsing servers and Safe Mode's own choice do not apply; hidden and blacklisted pictures still stay out.
    static func examples(_ tag: String, server: BooruServer, store: BooruStore, source: any BooruProviding, page: Int = 0) async -> [BooruPost] {
        let batch = await hurried { try await source.posts(server: server, query: tag, page: page) }
        let blacklist = BooruBlacklist(store.filteringBlacklist(serverID: server.id))
        return (batch?.posts ?? []).filter { StudyEngine.usable($0) && store.isVisible($0) && !blacklist.contains($0) }
    }

    /// What the server says about one tag. A recent answer kept on the device is used as it is.
    static func info(_ tag: String, store: BooruStore, source: any BooruProviding) async -> StudyTagInfo? {
        guard let server = infoServer(store) else { return nil }
        let study = store.studyStore, address = server.canonicalAddress
        let kept = try? study.info(tag, address: address)
        if let kept, kept.complete, !kept.isStale { return kept }
        async let counted = hurried { try await source.tags(server: server, names: [tag]) }
        async let page = hurried { try await source.wiki(server: server, tag: tag) }
        async let near = hurried { try await source.relatedTags(server: server, tag: tag) }
        let (tags, wiki, related) = await (counted, page, near)
        // Nothing answered: keep what was known and ask again next time.
        guard tags != nil || wiki != nil || related != nil else { return kept }
        let found = tags?.first { $0.name == tag }
        // Complete only when everything this kind of server offers was answered, so that a page
        // that timed out once is asked for again instead of staying missing until the cache goes stale.
        let hasPages = server.engine == .danbooru
        let info = StudyTagInfo(name: tag, count: found?.count ?? kept?.count, category: found?.category ?? kept?.category,
                                wiki: (wiki ?? nil) ?? kept?.wiki, related: related ?? kept?.related ?? [], fetched: .now,
                                complete: tags != nil && (!hasPages || (wiki != nil && related != nil)))
        try? study.save(info, address: address)
        return info
    }

    /// Post counts for many tags in as few requests as the server allows. Returns every count known afterwards.
    static func counts(_ tags: [String], store: BooruStore, source: any BooruProviding) async -> [String: Int] {
        guard let server = infoServer(store) else { return [:] }
        let study = store.studyStore, address = server.canonicalAddress
        var known = (try? study.counts(address: address)) ?? [:]
        let missing = tags.filter { known[$0] == nil }
        guard !missing.isEmpty, let found = await hurried(seconds: 12, { try await source.tags(server: server, names: missing) }) else { return known }
        // A name the server left out of its answer has no posts there; keeping that saves asking again.
        let answered = Set(found.map(\.name))
        for tag in found + missing.filter({ !answered.contains($0) }).map({ BooruTag(name: $0, count: 0, category: 0) }) {
            known[tag.name] = tag.count
            let kept = try? study.info(tag.name, address: address)
            try? study.save(.init(name: tag.name, count: tag.count, category: tag.category, wiki: kept?.wiki, related: kept?.related ?? [],
                                  fetched: kept?.fetched ?? .now, complete: kept?.complete ?? false), address: address)
        }
        return known
    }
}

/// One round of questions: it gathers pictures, asks, records each answer and moves on.
@MainActor @Observable
final class StudySession: Identifiable {
    enum Phase: Equatable { case loading, asking, answered(Int), finished }
    struct Result: Identifiable, Hashable { let tag: StudyTag; let right: Bool; var id: String { tag.name } }

    let id = UUID()
    let scope: StudyScope
    private(set) var tags: [StudyTag] = []
    private(set) var index = 0
    private(set) var question: StudyQuestion?
    private(set) var phase: Phase = .loading
    private(set) var results: [Result] = []
    /// True when no picture could be read for a question, so it was asked by meaning.
    private(set) var withoutPictures = false
    var rightCount: Int { results.filter(\.right).count }

    private let engine: StudyEngine
    private let store: BooruStore
    private let source: any BooruProviding
    private var generator = SystemRandomNumberGenerator()
    private var pool: [BooruPost] = []
    private var asked: Set<String> = []
    private var gathering: [String: Task<Void, Never>] = [:]
    private var used: Set<String> = []
    private let records: Bool

    init(scope: StudyScope, store: BooruStore, source: any BooruProviding, engine: StudyEngine = .init(), records: Bool = true) {
        self.scope = scope; self.store = store; self.source = source; self.engine = engine; self.records = records
    }

    func start() async {
        guard tags.isEmpty else { return }
        let progress = (try? store.studyStore.progress()) ?? [:]
        tags = engine.round(scope, progress: progress, now: .now, using: &generator)
        guard !tags.isEmpty else { phase = .finished; return }
        await ask()
    }

    func choose(_ choice: Int) {
        guard phase == .asking, let question else { return }
        let right = choice == question.answer
        results.append(.init(tag: question.tag, right: right))
        if records { try? store.studyStore.answer(question.tag.name, right: right) }
        phase = .answered(choice)
    }

    func advance() async {
        guard case .answered = phase else { return }
        index += 1
        if index >= tags.count { question = nil; phase = .finished; return }
        await ask()
    }

    private func ask() async {
        let tag = tags[index]
        phase = .loading
        if needsPictures(tag) { await gather(tag) }
        // Pictures already shown this round are not shown again while others remain.
        let unused = pool.filter { !used.contains($0.id) }
        var next = engine.question(for: tag, pool: unused, using: &generator)
        if next?.kind == .meaningToTag, unused.count != pool.count { next = engine.question(for: tag, pool: pool, using: &generator) ?? next }
        if let next, next.kind == .meaningToTag, needsPictures(tag) { withoutPictures = true }
        next?.posts.forEach { used.insert($0.id) }
        question = next
        phase = next == nil ? .finished : .asking
        if index + 1 < tags.count { let following = tags[index + 1]; if needsPictures(following) { prepare(following) } }
    }

    private func needsPictures(_ tag: StudyTag) -> Bool {
        guard engine.curriculum.group(of: tag.name)?.visual ?? true, !store.selectedServers.isEmpty else { return false }
        return !pool.contains { !used.contains($0.id) && engine.teaches($0, tag) }
    }

    private func prepare(_ tag: StudyTag) {
        guard gathering[tag.name] == nil, !asked.contains(tag.name) else { return }
        gathering[tag.name] = Task { [weak self] in await self?.read(tag) }
    }

    private func gather(_ tag: StudyTag) async {
        if let running = gathering[tag.name] { await running.value; return }
        guard !asked.contains(tag.name) else { return }
        await read(tag)
    }

    private func read(_ tag: StudyTag) async {
        asked.insert(tag.name)
        defer { gathering[tag.name] = nil }
        // A page a little way in keeps the round from always opening on the same newest pictures.
        let page = Int.random(in: 0..<4, using: &generator)
        var found = await StudyLookup.examples(tag.name, store: store, source: source, page: page)
        if !found.contains(where: { engine.teaches($0, tag) }) {
            found += await StudyLookup.examples(tag.name, store: store, source: source, page: 0)
        }
        let known = Set(pool.map(\.id))
        pool += found.filter { !known.contains($0.id) }
        if pool.count > 600 { pool.removeFirst(pool.count - 600) }
    }
}
