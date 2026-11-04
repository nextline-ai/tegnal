import SwiftUI
import NaturalLanguage
import Translation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Hand-lettered balloons come back from text recognition one line at a time. Lines of one
/// language that follow each other closely and overlap along the line are one balloon: they are
/// translated as one sentence under one label. Balloons side by side do not overlap that way.
enum ReaderBalloonGrouping {
    /// Japanese and Chinese balloons often read in vertical columns.
    static func isColumn(_ region: ReaderTextRegion, language: String?) -> Bool {
        ["ja", "zh"].contains(language ?? "") && region.bounds.height > region.bounds.width * 1.6
    }

    static func balloons(_ lines: [ReaderTextRegion]) -> [ReaderTextRegion] {
        guard lines.count > 1 else { return lines.map { region(from: [$0], language: language(of: $0.text)) } }
        let languages = lines.map { language(of: $0.text) }
        let columns = lines.indices.map { isColumn(lines[$0], language: languages[$0]) }
        func unit(_ index: Int) -> CGFloat { columns[index] ? lines[index].bounds.width : lines[index].bounds.height }
        var parent = Array(lines.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current { current = parent[current] }
            return current
        }
        for i in lines.indices {
            for j in lines.indices where j > i {
                guard languages[i] == languages[j], columns[i] == columns[j] else { continue }
                let a = lines[i].bounds, b = lines[j].bounds
                let size = max(unit(i), unit(j))
                // Lines of one balloon share a size.
                guard min(unit(i), unit(j)) * 2.2 >= size else { continue }
                let joins: Bool
                if columns[i] {
                    let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
                    let shared = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    joins = gap <= size * 0.6 && shared >= min(a.height, b.height) * 0.5
                } else {
                    let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                    let shared = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    joins = gap <= size * 0.6 && shared >= min(a.width, b.width) * 0.5
                }
                if joins { parent[root(j)] = root(i) }
            }
        }
        let groups = Dictionary(grouping: lines.indices, by: root)
        return groups.keys.sorted().compactMap { key in
            guard let members = groups[key] else { return nil }
            let vertical = columns[members[0]]
            // Vision's origin is at the bottom left: columns read right to left, lines top to bottom.
            let ordered = members.map { lines[$0] }.sorted { vertical ? $0.bounds.maxX > $1.bounds.maxX : $0.bounds.maxY > $1.bounds.maxY }
            return region(from: ordered, language: languages[members[0]], vertical: vertical)
        }
    }

    private static func region(from lines: [ReaderTextRegion], language: String?, vertical: Bool = false) -> ReaderTextRegion {
        let separator = ["ja", "zh"].contains(language ?? "") ? "" : " "
        let bounds = lines.dropFirst().reduce(lines[0].bounds) { $0.union($1.bounds) }
        return ReaderTextRegion(text: lines.map(\.text).joined(separator: separator), bounds: bounds, lines: lines.count, vertical: vertical)
    }

    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue).languageCode?.identifier ?? $0.rawValue }
    }
}

/// Lines of the pages before, original and translated, so a page reads on from the last one.
struct ReaderTranslationContext: Sendable {
    var pairs: [(source: String, translation: String)] = []
    /// Enough for a conversation to carry over, small enough for an on-device model.
    static let limit = 12
}

#if canImport(FoundationModels)
/// The on-device language model translates a whole page at once, so speakers keep their voice
/// and a sentence split across balloons reads as one. Nothing leaves the device.
@available(iOS 26.0, *)
enum ReaderModelTranslator {
    static func translate(_ lines: [String], target: String, context: ReaderTranslationContext) async throws -> [String]? {
        // Translation is a transformation of the reader's own content.
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable, model.supportsLocale(Locale(identifier: target)) else { return nil }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: target) ?? target
        let session = LanguageModelSession(model: model, instructions: """
            You translate the speech balloons of one comic page into natural, conversational \(language). \
            Keep each speaker's tone, keep names consistent with the earlier lines, and keep sound effects short. \
            Reply with exactly one line per numbered line, in the form "number. translation", and nothing else.
            """)
        var prompt = ""
        if !context.pairs.isEmpty {
            prompt += "Earlier lines, already translated:\n"
            prompt += context.pairs.map { "\($0.source) → \($0.translation)" }.joined(separator: "\n")
            prompt += "\n\n"
        }
        prompt += "Lines on this page:\n" + lines.enumerated().map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n")
        let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3))
        return parse(response.content, count: lines.count)
    }

    /// One translation for every numbered line, or nothing when the reply misses some.
    static func parse(_ reply: String, count: Int) -> [String]? {
        var found: [Int: String] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), let number = Int(trimmed[..<dot]),
                  (1...count).contains(number) else { continue }
            let text = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, found[number] == nil { found[number] = text }
        }
        guard found.count == count else { return nil }
        return (1...count).compactMap { found[$0] }
    }
}
#endif

/// Apple Translation hands out sessions only to a SwiftUI view. The reader keeps one invisible
/// host, and pages queue their balloons here; the host translates them one page at a time.
@MainActor @Observable final class ReaderTranslationBroker {
    fileprivate var configurationValue: Any?
    private var jobs: [(texts: [String], target: String, continuation: CheckedContinuation<[String], Error>)] = []
    private var target: String?

    func translate(_ texts: [String], target: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            jobs.append((texts, target, continuation))
            guard #available(iOS 18.0, *) else {
                continuation.resume(throwing: ContentError.unsupportedFormat)
                jobs.removeLast()
                return
            }
            if self.target != target || configurationValue == nil {
                self.target = target
                configurationValue = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: target))
            } else {
                var configuration = configurationValue as? TranslationSession.Configuration
                configuration?.invalidate()
                configurationValue = configuration
            }
        }
    }

    @available(iOS 18.0, *)
    var configuration: TranslationSession.Configuration? { configurationValue as? TranslationSession.Configuration }

    @available(iOS 18.0, *)
    func serve(_ session: TranslationSession) async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            do {
                let requests = job.texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                let responses = try await session.translations(from: requests)
                var translated = job.texts
                for response in responses {
                    if let key = response.clientIdentifier, let index = Int(key), translated.indices.contains(index) { translated[index] = response.targetText }
                }
                job.continuation.resume(returning: translated)
            } catch { job.continuation.resume(throwing: error) }
        }
    }
}

@available(iOS 18.0, *)
struct ReaderTranslationHost: View {
    let broker: ReaderTranslationBroker
    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            .translationTask(broker.configuration) { session in await broker.serve(session) }
    }
}

/// Translation mode: once on, every page shows its translation over the original as it comes
/// into view, the next page is prepared ahead, and a tap on the pill shows the original again.
@MainActor @Observable final class ReaderTranslationSession {
    private(set) var isOn = false
    var showsOriginal = false
    private(set) var pages: [String: [ReaderTextRegion]] = [:]
    private(set) var working: Set<String> = []
    /// The last failure worth telling the reader about.
    var message: String?
    let broker = ReaderTranslationBroker()
    private var target = "en"
    private var queue: [(index: Int, page: GalleryPage, galleryID: Int64)] = []
    private var worker: Task<Void, Never>?
    private var history: [Int: [(String, String)]] = [:]
    private var images: PageImageStore?

    /// Apple Translation needs iOS 18; the language model, iOS 26.
    static var isSupported: Bool { if #available(iOS 18.0, *) { true } else { false } }

    func balloons(for hash: String) -> [ReaderTextRegion]? { isOn && !showsOriginal ? pages[hash] : nil }
    func isWorking(on hash: String) -> Bool { isOn && working.contains(hash) }

    func toggle() {
        if isOn { stop() } else {
            isOn = true; showsOriginal = false; message = nil
            target = ReaderTranslationLanguage.resolved(ReaderTranslationLanguage.preference(booru: false))
        }
    }

    func stop() {
        isOn = false; showsOriginal = false
        worker?.cancel(); worker = nil; queue = []; working = []
    }

    /// Translates the visible spread first, then the next one.
    func follow(gallery: NativeGallery, index: Int, count: Int, images: PageImageStore) {
        guard isOn else { return }
        self.images = images
        let wanted = Array(index..<min(gallery.pages.count, index + count * 2))
        queue = wanted.compactMap { position in
            let page = gallery.pages[position]
            return pages[page.hash] == nil ? (position, page, gallery.id) : nil
        }
        if worker == nil { worker = Task { await run() } }
    }

    private func run() async {
        while isOn, !Task.isCancelled, !queue.isEmpty {
            let job = queue.removeFirst()
            guard pages[job.page.hash] == nil, let images else { continue }
            working.insert(job.page.hash)
            do {
                let balloons = try await translate(job.page, index: job.index, galleryID: job.galleryID, images: images)
                if isOn { pages[job.page.hash] = balloons }
            } catch is CancellationError {
            } catch { if isOn, message == nil { message = ContentError.message(error) } }
            working.remove(job.page.hash)
        }
        worker = nil
    }

    private func translate(_ page: GalleryPage, index: Int, galleryID: Int64, images: PageImageStore) async throws -> [ReaderTextRegion] {
        let image = try await images.load(page, galleryID: galleryID)
        let lines = try await ReaderTextRecognizer.shared.recognize(image)
        let targetCode = Locale.Language(identifier: target).languageCode?.identifier ?? target
        // Text already in the target language stays as drawn.
        let foreign = ReaderBalloonGrouping.balloons(lines).filter { ReaderBalloonGrouping.language(of: $0.text) != targetCode }
        guard !foreign.isEmpty else { return [] }
        let sources = foreign.map(\.text)
        var context = ReaderTranslationContext()
        for previous in stride(from: index - 1, through: max(0, index - 3), by: -1) { context.pairs.insert(contentsOf: history[previous] ?? [], at: 0) }
        context.pairs = Array(context.pairs.suffix(ReaderTranslationContext.limit))
        var translated: [String]?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { translated = try? await ReaderModelTranslator.translate(sources, target: target, context: context) }
        #endif
        if translated == nil { translated = try await broker.translate(sources, target: target) }
        let texts = translated ?? sources
        history[index] = Array(zip(sources, texts))
        return zip(foreign, texts).map { ReaderTextRegion(text: $1, bounds: $0.bounds, lines: $0.lines, vertical: $0.vertical) }
    }
}

/// The only control translation mode adds: a small pill that switches between the translation
/// and the original, fading away once it is not needed.
struct ReaderTranslationToggle: View {
    let showsOriginal: Bool
    let working: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                if working { ProgressView().controlSize(.mini).tint(.white) }
                else { Image(systemName: "translate").font(.system(size: 13, weight: .semibold)) }
                // Names what a tap shows next.
                Text(L10n.text(showsOriginal ? "Show Translation" : "Show Original")).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 32)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reader.translation.toggle")
    }
}
