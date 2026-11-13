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

    /// `language` is the work's own, when known. Otherwise each line's language is guessed from its text.
    static func balloons(_ lines: [ReaderTextRegion], language known: String? = nil) -> [ReaderTextRegion] {
        guard lines.count > 1 else {
            return lines.map { region(from: [$0], language: known ?? language(of: $0.text), vertical: isColumn($0, language: known ?? language(of: $0.text))) }
        }
        let languages = lines.map { known ?? language(of: $0.text) }
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
    static func prewarm() {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return }
        LanguageModelSession(model: model).prewarm()
    }

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
        guard let translated = parse(response.content, count: lines.count), accepts(translated, sources: lines, target: target) else { return nil }
        return translated
    }

    /// A reply counts only when it is in the target language: the model sometimes answers by
    /// repeating the original. Most lines must change, and the page as a whole must read as the target.
    static func accepts(_ replies: [String], sources: [String], target: String) -> Bool {
        func letters(_ text: String) -> String { text.filter { $0.isLetter } }
        // Lines without words, such as "…!?" or a page number, stay as they are in any language.
        let worded = zip(replies, sources).filter { letters($0.1).count >= 2 }
        let unchanged = worded.filter { letters($0.0) == letters($0.1) }.count
        guard unchanged * 2 <= worded.count else { return false }
        let text = replies.joined(separator: "\n")
        // Too little text to tell its language; the count check above still applies.
        guard letters(text).count >= 6 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let found = recognizer.dominantLanguage else { return true }
        return Locale.Language(identifier: found.rawValue).languageCode == Locale.Language(identifier: target).languageCode
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

/// Apple Translation for a language pair already on the device: no interface, no download, and
/// an answer in a fraction of a second. Nil when the pair or the source language is unknown.
@available(iOS 26.0, *)
enum ReaderInstalledTranslator {
    static func translate(_ texts: [String], source: String?, target: String) async throws -> [String]? {
        guard let source else { return nil }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return nil }
        let session = TranslationSession(installedSource: from, target: to)
        let responses = try await session.translations(from: texts.enumerated().map { .init(sourceText: $0.element, clientIdentifier: String($0.offset)) })
        var translated = texts
        for response in responses {
            if let key = response.clientIdentifier, let index = Int(key), translated.indices.contains(index) { translated[index] = response.targetText }
        }
        return translated
    }
}

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
    /// The work's language tag: text is read in it rather than detected, and its balloons grouped by it.
    private var source: String?
    private var worker: Task<Void, Never>?
    private var history: [Int: [(String, String)]] = [:]
    private var images: PageImageStore?
    /// Zoomed areas of each page already read again, and the reading in progress.
    private var readAreas: [String: [CGRect]] = [:]
    private var zoomWorker: Task<Void, Never>?
    private var zoomWorking: String?

    /// Apple Translation needs iOS 18; the language model, iOS 26.
    static var isSupported: Bool { if #available(iOS 18.0, *) { true } else { false } }

    func balloons(for hash: String) -> [ReaderTextRegion]? { isOn && !showsOriginal ? pages[hash] : nil }
    func isWorking(on hash: String) -> Bool { isOn && (working.contains(hash) || zoomWorking == hash) }

    func toggle() {
        if isOn { stop() } else {
            isOn = true; showsOriginal = false; message = nil
            target = ReaderTranslationLanguage.resolved(ReaderTranslationLanguage.preference(booru: false))
            #if canImport(FoundationModels)
            // Loading the model takes seconds; start while the first page is read.
            if #available(iOS 26.0, *) { ReaderModelTranslator.prewarm() }
            #endif
        }
    }

    func stop() {
        isOn = false; showsOriginal = false
        worker?.cancel(); worker = nil; queue = []; working = []
        zoomWorker?.cancel(); zoomWorker = nil; zoomWorking = nil
    }

    /// Once a zoom settles on a translated page, the part on screen is read again from the original
    /// pixels, so small text the page-wide reading missed is translated; its balloons replace the
    /// page-wide ones where it found text. `area` is normalized with a top-left origin.
    func readZoomed(_ page: GalleryPage, index: Int, galleryID: Int64, area: CGRect, images: PageImageStore) {
        // A page still being read whole is read first; zooming again after that reads the area.
        guard isOn, pages[page.hash] != nil, ReaderZoomedText.needsReading(area, after: readAreas[page.hash] ?? []) else { return }
        zoomWorker?.cancel()
        zoomWorking = page.hash
        zoomWorker = Task {
            defer { if zoomWorking == page.hash, !Task.isCancelled { zoomWorking = nil } }
            do {
                let crop = try await images.translationCrop(page, galleryID: galleryID, rect: area)
                let found = ReaderZoomedText.place(try await foreignBalloons(in: crop), readIn: area)
                try Task.checkCancellation()
                readAreas[page.hash, default: []].append(area)
                guard isOn, !found.isEmpty else { return }
                let texts = try await translate(found.map(\.text), index: index, addingTo: true)
                try Task.checkCancellation()
                guard isOn else { return }
                let translated = zip(found, texts).map { ReaderTextRegion(text: $1, bounds: $0.bounds, lines: $0.lines, vertical: $0.vertical) }
                pages[page.hash] = ReaderZoomedText.merge(pages[page.hash] ?? [], with: translated)
            } catch is CancellationError {
            } catch { if isOn, message == nil { message = ContentError.message(error) } }
        }
    }

    /// Translates the visible spread first, then the next one.
    func follow(gallery: NativeGallery, index: Int, count: Int, images: PageImageStore) {
        guard isOn else { return }
        self.images = images
        source = gallery.language
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

    /// Shows Apple's quick translation as soon as it is ready, then the on-device model's.
    private func translate(_ page: GalleryPage, index: Int, galleryID: Int64, images: PageImageStore) async throws -> [ReaderTextRegion] {
        let image = try await images.load(page, galleryID: galleryID)
        let foreign = try await foreignBalloons(in: image)
        guard !foreign.isEmpty else { return [] }
        func regions(_ texts: [String]) -> [ReaderTextRegion] {
            zip(foreign, texts).map { ReaderTextRegion(text: $1, bounds: $0.bounds, lines: $0.lines, vertical: $0.vertical) }
        }
        let texts = try await translate(foreign.map(\.text), index: index, addingTo: false) { [weak self] quick in
            guard let self, isOn else { return }
            pages[page.hash] = regions(quick)
        }
        return regions(texts)
    }

    /// The balloons of an image that are not yet in the target language.
    private func foreignBalloons(in image: UIImage) async throws -> [ReaderTextRegion] {
        guard #available(iOS 18.0, *) else { throw ContentError.unsupportedFormat }
        let lines = try await ReaderTextRecognizer.shared.recognize(image, languages: ReaderSourceLanguage.recognitionLanguages(for: source))
        let targetCode = Locale.Language(identifier: target).languageCode?.identifier ?? target
        let sourceCode = ReaderSourceLanguage.code(for: source)
        // A work already in the target language stays as drawn, and so do balloons already in it.
        guard sourceCode != targetCode else { return [] }
        return ReaderBalloonGrouping.balloons(lines, language: sourceCode).filter { ReaderBalloonGrouping.language(of: $0.text) != targetCode }
    }

    /// Translates one page's lines with the lines of the pages before; `addingTo` keeps the page's
    /// earlier lines as context for the next pages, for a zoomed reading of a page already translated.
    ///
    /// The on-device model reads the page as a whole but takes seconds, longest on the first page
    /// while it loads. Apple Translation of a language pair already on the device answers at once
    /// without any interface, so `preview` gets its lines first; the model's replace them, unless
    /// the model is unavailable, gives an unusable reply or takes longer than `modelLimit`.
    private func translate(_ sources: [String], index: Int, addingTo: Bool, preview: (([String]) -> Void)? = nil) async throws -> [String] {
        var context = ReaderTranslationContext()
        for previous in stride(from: index - 1, through: max(0, index - 3), by: -1) { context.pairs.insert(contentsOf: history[previous] ?? [], at: 0) }
        if addingTo { context.pairs += history[index] ?? [] }
        context.pairs = Array(context.pairs.suffix(ReaderTranslationContext.limit))
        let target = target, sourceCode = ReaderSourceLanguage.code(for: source)
        var translated: [String]?
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            let model = Task { try? await ReaderModelTranslator.translate(sources, target: target, context: context) }
            #endif
            let quick = try? await ReaderInstalledTranslator.translate(sources, source: sourceCode, target: target)
            #if canImport(FoundationModels)
            // When the model was quicker still, its lines replace these straight away.
            if let quick { preview?(quick) }
            translated = await Self.value(of: model, within: Self.modelLimit) ?? quick
            #else
            translated = quick
            #endif
        }
        // Stopped meanwhile: the fallback below can ask to download languages, which nobody wants now.
        try Task.checkCancellation()
        if translated == nil { translated = try await broker.translate(sources, target: target) }
        let texts = translated ?? sources
        history[index] = (addingTo ? history[index] ?? [] : []) + Array(zip(sources, texts))
        return texts
    }

    /// Longest the reader waits for the on-device model before keeping Apple's translation.
    static let modelLimit: Duration = .seconds(25)

    /// The task's value, or nil once `limit` passes; the task is then cancelled.
    static func value<Value: Sendable>(of task: Task<Value?, Never>, within limit: Duration) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit); return nil }
            let first = await group.next() ?? nil
            task.cancel()
            group.cancelAll()
            return first
        }
    }
}

/// What translation is doing in the reader: the on-device AI over every page as it turns, Apple's
/// standard translation of the page on screen, or nothing.
enum ReaderTranslationMode: String, CaseIterable, Identifiable {
    case ai, standard, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ai: L10n.text("AI")
        case .standard: L10n.text("Standard")
        case .off: L10n.text("Off")
        }
    }
    /// AI translation needs iOS 18; the standard one works everywhere.
    @MainActor static var available: [ReaderTranslationMode] { ReaderTranslationSession.isSupported ? allCases : [.standard, .off] }
}

/// Shown under the page while translating, so switching between AI and standard translation, or
/// turning it off, takes one tap. It sits on the same row as Live Text's own buttons, between them.
struct ReaderTranslationModeBar: View {
    static let bottomInset: CGFloat = 44
    let mode: ReaderTranslationMode
    let select: (ReaderTranslationMode) -> Void
    var body: some View {
        Picker(L10n.text("Translation"), selection: Binding(get: { mode }, set: { select($0) })) {
            ForEach(ReaderTranslationMode.available) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .controlSize(.small)
        // Narrow enough to fit between Live Text's buttons on the smallest iPhone.
        .frame(maxWidth: 196)
        .padding(4)
        // Interactive glass would take the segments' taps for its own press effect.
        .modifier(GlassCapsuleModifier())
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("reader.translation.mode")
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
