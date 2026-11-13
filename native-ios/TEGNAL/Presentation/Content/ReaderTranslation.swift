import SwiftUI
import Vision
import VisionKit
import ImageIO
import CoreText

struct ReaderTextRegion: Sendable, Equatable {
    let text: String
    /// Vision's normalized coordinates, with the origin at the bottom left.
    let bounds: CGRect
    /// How many lines or columns the original ran over; a label's text matches one of them.
    var lines = 1
    /// The original ran in vertical columns, so its label sizes text by width.
    var vertical = false
}

/// The language a work is written in, as text recognition wants it. Comics carry their language,
/// so recognition reads with one known language instead of detecting it on every page.
enum ReaderSourceLanguage {
    private static let named: [String: [String]] = [
        "japanese": ["ja-JP"], "korean": ["ko-KR"], "chinese": ["zh-Hans", "zh-Hant"], "english": ["en-US"],
        "french": ["fr-FR"], "german": ["de-DE"], "spanish": ["es-ES"], "italian": ["it-IT"], "portuguese": ["pt-BR"],
        "russian": ["ru-RU"], "ukrainian": ["uk-UA"], "thai": ["th-TH"], "vietnamese": ["vi-VT"], "cantonese": ["yue-Hant"],
    ]
    /// Recognition languages for a work's language tag ("japanese", or a code such as "ja"); nil when unknown.
    static func recognitionLanguages(for tag: String?) -> [String]? {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !tag.isEmpty else { return nil }
        if let languages = named[tag] { return languages }
        guard let code = Locale.Language(identifier: tag).languageCode?.identifier else { return nil }
        return named.values.first { $0.contains { Locale.Language(identifier: $0).languageCode?.identifier == code } }
    }
    /// The language code to group and translate with: "ja" for Japanese works.
    static func code(for tag: String?) -> String? {
        recognitionLanguages(for: tag)?.first.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
    }
    /// Japanese and Chinese comics set most dialogue in vertical columns.
    static func writesVertically(_ tag: String?) -> Bool { ["ja", "zh"].contains(code(for: tag) ?? "") }
}

actor ReaderTextRecognizer {
    static let shared = ReaderTextRecognizer()
    /// Without a known language, these are detected among. Detection is slower, so comics pass theirs.
    static let detectedLanguages = ["ja-JP", "en-US", "ko-KR", "zh-Hans", "zh-Hant"]

    /// The Swift request: on current systems it reads vertical Japanese and Chinese columns, which the
    /// older `VNRecognizeTextRequest` returns nothing for on every system.
    @available(iOS 18.0, *)
    func recognize(_ image: UIImage, languages: [String]? = nil) async throws -> [ReaderTextRegion] {
        try Task.checkCancellation()
        guard let cgImage = image.cgImage else { throw ContentError.unsupportedFormat }
        return try await Self.recognize(cgImage, languages: languages)
    }

    @available(iOS 18.0, *)
    static func recognize(_ image: CGImage, languages: [String]?) async throws -> [ReaderTextRegion] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = Set(request.supportedRecognitionLanguages.map(\.maximalIdentifier))
        func available(_ identifiers: [String]) -> [Locale.Language] {
            identifiers.map { Locale.Language(identifier: $0) }.filter { supported.contains($0.maximalIdentifier) }
        }
        if let known = languages.map(available), !known.isEmpty {
            request.recognitionLanguages = known
            request.automaticallyDetectsLanguage = false
        } else {
            request.recognitionLanguages = available(detectedLanguages)
            request.automaticallyDetectsLanguage = true
        }
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return ReaderTextRegion(text: candidate.string, bounds: observation.boundingBox.cgRect)
        }
    }
}

/// Whether this system's text recognition reads vertical columns. iOS 18 recognizes horizontal text
/// only, while Live Text reads both; newer systems read both. Measured once per system version on a
/// small vertical sample, so a model that changes with an update is measured again.
actor ReaderVerticalTextSupport {
    static let shared = ReaderVerticalTextSupport()
    static let sample = ["今日は雨だって", "傘を持ってきた"]
    private var task: Task<Bool, Never>?
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, system: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.defaults = defaults
        key = "reader.verticalTextRecognition." + system
    }

    func isSupported() async -> Bool {
        if defaults.object(forKey: key) != nil { return defaults.bool(forKey: key) }
        if task == nil {
            task = Task.detached(priority: .userInitiated) {
                guard #available(iOS 18.0, *), let image = Self.sampleImage(),
                      let regions = try? await ReaderTextRecognizer.recognize(image, languages: ["ja-JP"]) else { return false }
                return Self.reads(regions.map(\.text).joined(), expected: Self.sample.joined())
            }
        }
        let supported = await task?.value ?? false
        defaults.set(supported, forKey: key)
        return supported
    }

    /// Nearly every character of the sample came back; punctuation and order aside.
    static func reads(_ text: String, expected: String) -> Bool {
        var remaining = Array(text.filter { $0.isLetter || $0.isNumber })
        let wanted = expected.filter { $0.isLetter || $0.isNumber }
        guard !wanted.isEmpty else { return false }
        var found = 0
        for character in wanted {
            if let index = remaining.firstIndex(of: character) { remaining.remove(at: index); found += 1 }
        }
        return Double(found) >= Double(wanted.count) * 0.8
    }

    /// Two columns of vertical Japanese, set the way comic balloons are.
    static func sampleImage() -> CGImage? {
        let size = CGSize(width: 320, height: 420)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 40, nil)
        let text = NSAttributedString(string: sample.joined(separator: "\n"), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true,
        ])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(),
                                             CGPath(rect: CGRect(x: 80, y: 40, width: 160, height: 340), transform: nil),
                                             [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }
}

/// Zoomed translation. Small text a page-wide reading misses becomes legible once the reader zooms
/// in, so the part on screen is read again on its own and its results replace the page-wide ones there.
enum ReaderZoomedText {
    /// Zoom from which reading the visible part again finds more than the page-wide reading.
    static let minimumScale: CGFloat = 1.3
    /// How long the viewport stays still before it is read.
    static let settle: Duration = .milliseconds(600)

    /// The image area on screen, normalized with a top-left origin; nil when not zoomed in enough.
    @MainActor static func visibleRect(of scroll: PageScrollView) -> CGRect? {
        let image = scroll.imageView.bounds
        guard scroll.zoomScale >= minimumScale, image.width > 0, image.height > 0 else { return nil }
        let visible = scroll.convert(scroll.bounds, to: scroll.imageView).intersection(image)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
        return CGRect(x: visible.minX / image.width, y: visible.minY / image.height,
                      width: visible.width / image.width, height: visible.height / image.height)
    }

    /// A viewport needs reading unless an earlier reading covered it at a similar zoom.
    static func needsReading(_ rect: CGRect, after read: [CGRect]) -> Bool {
        !read.contains { $0.insetBy(dx: -0.01, dy: -0.01).contains(rect) && $0.width * $0.height <= rect.width * rect.height * 1.5 }
    }

    /// The pixels of `rect` (normalized, top-left origin).
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let pixels = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                            width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
        return image.cropping(to: pixels)
    }

    /// The pixels of `area` (normalized to the image, top-left origin), which may reach past the image:
    /// what lies outside it is black, like the screen around a page. Large areas are scaled down to
    /// `maximumPixels` on their long side, since text recognition reads at about that size anyway.
    static func render(_ image: CGImage, area: CGRect, maximumPixels: CGFloat = 4096) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let full = CGSize(width: area.width * width, height: area.height * height)
        guard full.width >= 1, full.height >= 1 else { return nil }
        let scale = min(1, maximumPixels / max(full.width, full.height))
        let size = CGSize(width: (full.width * scale).rounded(), height: (full.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        // CoreGraphics draws from the bottom left.
        let drawn = CGRect(x: -area.minX * width * scale, y: size.height + area.minY * height * scale - height * scale,
                           width: width * scale, height: height * scale)
        context.draw(image, in: drawn)
        return context.makeImage()
    }

    /// Regions read in the crop of `rect`, placed on the whole image. Text cut by the screen edge is
    /// dropped: it is read whole from the page or a later viewport.
    static func place(_ regions: [ReaderTextRegion], readIn rect: CGRect) -> [ReaderTextRegion] {
        let edge: CGFloat = 0.01
        return regions.compactMap { region in
            let b = region.bounds
            let cut = (b.minX < edge && rect.minX > 0.001) || (b.maxX > 1 - edge && rect.maxX < 0.999)
                || (b.maxY > 1 - edge && rect.minY > 0.001) || (b.minY < edge && rect.maxY < 0.999)
            guard !cut else { return nil }
            // Vision's origin is at the bottom left, of the crop and of the page alike.
            return ReaderTextRegion(text: region.text,
                                    bounds: CGRect(x: rect.minX + b.minX * rect.width, y: 1 - rect.maxY + b.minY * rect.height,
                                                   width: b.width * rect.width, height: b.height * rect.height),
                                    lines: region.lines, vertical: region.vertical)
        }
    }

    /// The closer reading wins where it found text; earlier text elsewhere stays.
    static func merge(_ existing: [ReaderTextRegion], with found: [ReaderTextRegion]) -> [ReaderTextRegion] {
        existing.filter { old in !found.contains { $0.bounds.intersects(old.bounds) } } + found
    }
}

struct ReaderTranslationRequest: Identifiable {
    let id = UUID()
    let index: Int
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Mac uses Vision OCR and Apple Translation directly; iOS keeps its native
/// Live Text interface when the user chooses the system translation language.
struct ReaderTranslationView: View {
    let loadImage: () async throws -> UIImage
    let finished: () -> Void
    let failed: (String) -> Void
    private let targetLanguage: String
    /// The work's language tag, when the work states it.
    private let sourceLanguage: String?
    @State private var image: UIImage?
    @State private var analyzing = true
    @State private var needsManualAction = false
    @State private var retry = 0
    @State private var readsVerticalText = true

    init(page: GalleryPage, galleryID: Int64, language: String?, images: PageImageStore, rect: CGRect, finished: @escaping () -> Void, failed: @escaping (String) -> Void) {
        self.loadImage = { try await images.translationCrop(page, galleryID: galleryID, rect: rect) }
        self.finished = finished; self.failed = failed
        self.targetLanguage = ReaderTranslationLanguage.preference(booru: false)
        self.sourceLanguage = language
    }
    init(loadImage: @escaping () async throws -> UIImage, booru: Bool = false, finished: @escaping () -> Void, failed: @escaping (String) -> Void) {
        self.loadImage = loadImage; self.finished = finished; self.failed = failed
        self.targetLanguage = ReaderTranslationLanguage.preference(booru: booru)
        self.sourceLanguage = nil
    }

    /// Live Text has no Mac interface, so the Mac always reads and translates the text itself. On
    /// iPhone and iPad a chosen language does the same, unless the work is set in vertical columns
    /// this system cannot read; Live Text reads those, into the system language.
    static func usesTextSession(target: String, isMac: Bool, verticalSource: Bool = false, readsVerticalText: Bool = true) -> Bool {
        isMac || target != "system" && (!verticalSource || readsVerticalText)
    }
    private var usesTextSession: Bool {
        if #available(iOS 18.0, *) {
            return Self.usesTextSession(target: targetLanguage, isMac: ProcessInfo.processInfo.isiOSAppOnMac,
                                        verticalSource: ReaderSourceLanguage.writesVertically(sourceLanguage), readsVerticalText: readsVerticalText)
        }
        return false
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                if #available(iOS 18.0, *), usesTextSession {
                    TargetedTranslationCanvas(image: image, target: ReaderTranslationLanguage.resolved(targetLanguage), source: sourceLanguage, retry: retry,
                                              working: { analyzing = true }, ready: { analyzing = false }, failed: failed).ignoresSafeArea()
                } else { LiveTextTranslationCanvas(image: image, retry: retry, working: {
                    analyzing = true; needsManualAction = false
                }, ready: { automatic in
                    analyzing = false
                    needsManualAction = !automatic
                }, failed: failed).ignoresSafeArea() }
            }
            VStack(alignment: .trailing, spacing: 10) {
                Button(L10n.text("Original"), systemImage: "xmark") { finished() }
                    .buttonStyle(.borderedProminent).tint(.black.opacity(0.8))
                    .accessibilityIdentifier("reader.original")
                if analyzing {
                    ProgressView().tint(.white).padding(12).background(.black.opacity(0.75), in: Capsule())
                        .accessibilityLabel(L10n.text("Preparing Apple image translation"))
                        .accessibilityIdentifier("reader.translation.progress")
                }
                if needsManualAction {
                    Button(L10n.text("Retry Translation"), systemImage: "arrow.clockwise") {
                        analyzing = true; needsManualAction = false; retry += 1
                    }.buttonStyle(.borderedProminent).tint(.black.opacity(0.8))
                        .accessibilityIdentifier("reader.translation.retry")
                }
            }.padding(16)
        }
        .task {
            if ReaderSourceLanguage.writesVertically(sourceLanguage), targetLanguage != "system", !ProcessInfo.processInfo.isiOSAppOnMac {
                readsVerticalText = await ReaderVerticalTextSupport.shared.isSupported()
            }
            guard usesTextSession || ImageAnalyzer.isSupported else { failed(L10n.text("This device does not support Apple image analysis.")); return }
            do {
                // Decode the original pixels, including the current enlarged viewport, without painting over them.
                image = try await loadImage()
            } catch { if !Task.isCancelled { failed(ContentError.message(error)) } }
        }
    }
}

/// VisionKit's interface is attached to a stationary container. Only the image zooms and pans, and the
/// system's Live Text and Translate buttons stay at the screen's bottom corners. Once a zoom settles,
/// the part on screen is analyzed again on its own, so text too small for the page-wide analysis is
/// translated; zooming back out returns to the page-wide analysis.
private struct LiveTextTranslationCanvas: UIViewRepresentable {
    let image: UIImage
    let retry: Int
    let working: () -> Void
    let ready: (Bool) -> Void
    let failed: (String) -> Void
    func makeUIView(context: Context) -> LiveTextCanvasView { LiveTextCanvasView() }
    func updateUIView(_ view: LiveTextCanvasView, context: Context) {
        view.configure(image: image, retry: retry, working: working, ready: ready, failed: failed)
    }
    static func dismantleUIView(_ view: LiveTextCanvasView, coordinator: ()) { view.cancel() }
}

final class LiveTextCanvasView: UIView, ImageAnalysisInteractionDelegate, UIGestureRecognizerDelegate {
    let scroll = PageScrollView()
    let interaction = ImageAnalysisInteraction()
    private var image: UIImage?
    private var retry = -1
    private var analysisTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var ready: (Bool) -> Void = { _ in }
    private var working: () -> Void = {}
    private var analysisCount = 0
    /// The page-wide analysis and the area it covers, kept for zooming back out.
    private var pageAnalysis: (analysis: ImageAnalysis, area: CGRect)?
    /// The area the current analysis covers, normalized to the image with a top-left origin. It is
    /// the whole screen, so it reaches past the image into the black around it.
    private var analyzedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var zoomTask: Task<Void, Never>?
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor = CGPoint.zero
    private var panStartOffset = CGPoint.zero
    private lazy var canvasPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var canvasPinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        addSubview(scroll)
        scroll.usesExternalGestures = true
        scroll.pinchGestureRecognizer?.isEnabled = false
        for gesture in scroll.gestureRecognizers ?? [] {
            if gesture is UILongPressGestureRecognizer || (gesture as? UITapGestureRecognizer)?.numberOfTapsRequired == 1 {
                scroll.removeGestureRecognizer(gesture)
            } else if let doubleTap = gesture as? UITapGestureRecognizer {
                // VisionKit draws above the image. Put double tap on their common ancestor.
                scroll.removeGestureRecognizer(doubleTap)
                doubleTap.delegate = self
                addGestureRecognizer(doubleTap)
            }
        }
        canvasPan.maximumNumberOfTouches = 1
        canvasPan.delegate = self
        canvasPinch.delegate = self
        addGestureRecognizer(canvasPan)
        addGestureRecognizer(canvasPinch)
        scroll.imageView.accessibilityIdentifier = "reader.translation.image"
        scroll.imageView.isAccessibilityElement = false
        interaction.delegate = self
        interaction.preferredInteractionTypes = [.textSelection, .automatic]
        addInteraction(interaction)
        scroll.geometryChanged = { [weak self] in
            self?.updateInterfaceGeometry()
            self?.scheduleZoomedAnalysis()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        updateInterfaceGeometry()
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
    /// VisionKit places its buttons inside the analyzed content's rectangle, offset by these insets.
    /// Measuring them from that rectangle to the screen's corners keeps the buttons fixed on screen
    /// however the image is zoomed or moved, like the Original button above.
    private func updateInterfaceGeometry() {
        let safe = safeAreaInsets
        let screen = bounds.inset(by: UIEdgeInsets(top: safe.top + 8, left: safe.left + 12, bottom: safe.bottom + 12, right: safe.right + 12))
        let content = analyzedFrame()
        let insets = content.isEmpty ? .zero : Self.pinnedInsets(content: content, screen: screen)
        if interaction.supplementaryInterfaceContentInsets != insets { interaction.supplementaryInterfaceContentInsets = insets }
        interaction.setContentsRectNeedsUpdate()
    }
    /// VisionKit hides its buttons when an inset is negative, so while content moves away from a
    /// screen edge mid-gesture they stay just inside it until the next analysis covers the screen again.
    static func pinnedInsets(content: CGRect, screen: CGRect) -> UIEdgeInsets {
        UIEdgeInsets(top: max(12, screen.minY - content.minY), left: max(12, screen.minX - content.minX),
                     bottom: max(12, content.maxY - screen.maxY), right: max(12, content.maxX - screen.maxX))
    }
    /// The screen, in the image's normalized coordinates.
    private func screenArea() -> CGRect? {
        let frame = scroll.imageView.convert(scroll.imageView.bounds, to: self)
        guard frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        return CGRect(x: (bounds.minX - frame.minX) / frame.width, y: (bounds.minY - frame.minY) / frame.height,
                      width: bounds.width / frame.width, height: bounds.height / frame.height)
    }
    /// Where the analyzed part of the image is, in this view.
    private func analyzedFrame() -> CGRect {
        let frame = scroll.imageView.convert(scroll.imageView.bounds, to: self)
        let r = analyzedRect
        return CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
                      width: r.width * frame.width, height: r.height * frame.height)
    }
    private func scheduleZoomedAnalysis() {
        guard pageAnalysis != nil else { return }
        zoomTask?.cancel()
        zoomTask = Task { [weak self] in
            do { try await Task.sleep(for: ReaderZoomedText.settle) } catch { return }
            await self?.analyzeVisiblePart()
        }
    }
    private func analyzeVisiblePart() async {
        guard let image, let page = pageAnalysis else { return }
        guard ReaderZoomedText.visibleRect(of: scroll) != nil, let area = screenArea() else {
            // Zoomed back out: the page-wide analysis covers everything again.
            guard analyzedRect != page.area else { return }
            show(page.analysis, rect: page.area)
            return
        }
        guard ReaderZoomedText.needsReading(area, after: [analyzedRect]),
              let cgImage = image.cgImage, let screen = ReaderZoomedText.render(cgImage, area: area) else { return }
        working()
        do {
            let analysis = try await ImageAnalyzer().analyze(screen, orientation: .up, configuration: .init([.text]))
            try Task.checkCancellation()
            guard !analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { ready(true); return }
            show(analysis, rect: area)
        } catch { if !Task.isCancelled { ready(true) } }
    }
    private func show(_ analysis: ImageAnalysis, rect: CGRect) {
        analyzedRect = rect
        countAnalysis()
        interaction.analysis = analysis
        interaction.selectableItemsHighlighted = true
        updateInterfaceGeometry()
        startTranslation()
    }
    private func countAnalysis() {
        #if DEBUG
        if ContentUITestSupport.enabled {
            analysisCount += 1
            accessibilityIdentifier = "reader.translation.canvas"
            accessibilityValue = L10n.text("Analyses: %@", String(describing: analysisCount))
        }
        #endif
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var node = touch.view
        while let current = node, current !== self {
            if current is UIControl { return false }
            node = current.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer !== canvasPan || (scroll.zoomScale > 1.01 && !interaction.hasActiveTextSelection)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === canvasPinch || other === canvasPinch
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStartOffset = scroll.contentOffset }
        let delta = gesture.translation(in: self)
        if gesture.state == .began || gesture.state == .changed {
            moveImage(to: CGPoint(x: panStartOffset.x - delta.x, y: panStartOffset.y - delta.y))
        }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStartScale = scroll.zoomScale
            pinchAnchor = gesture.location(in: scroll.imageView)
        }
        if gesture.state == .began || gesture.state == .changed {
            let scale = min(scroll.maximumZoomScale, max(1, pinchStartScale * gesture.scale))
            let point = gesture.location(in: self)
            scroll.setZoomScale(scale, animated: false)
            moveImage(to: CGPoint(x: pinchAnchor.x * scale - point.x, y: pinchAnchor.y * scale - point.y))
        }
        if gesture.state == .ended || gesture.state == .cancelled, scroll.zoomScale <= 1.01 {
            moveImage(to: CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top))
        }
    }
    private func moveImage(to offset: CGPoint) {
        let inset = scroll.contentInset
        scroll.setContentOffset(CGPoint(x: min(max(-inset.left, offset.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                                        y: min(max(-inset.top, offset.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom))), animated: false)
    }
    func contentView(for interaction: ImageAnalysisInteraction) -> UIView? { scroll.imageView }
    func contentsRect(for interaction: ImageAnalysisInteraction) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let frame = analyzedFrame()
        return CGRect(x: frame.minX / bounds.width, y: frame.minY / bounds.height,
                      width: frame.width / bounds.width, height: frame.height / bounds.height)
    }
    func configure(image: UIImage, retry: Int, working: @escaping () -> Void, ready: @escaping (Bool) -> Void, failed: @escaping (String) -> Void) {
        self.ready = ready
        self.working = working
        if self.image === image {
            if self.retry != retry { self.retry = retry; startTranslation() }
            return
        }
        cancel()
        self.image = image
        self.retry = retry
        scroll.update(image: image)
        analysisTask = Task { [weak self] in
            do {
                // The page is analyzed with the black around it, so the analysis spans the screen and
                // VisionKit's buttons sit at the screen's corners rather than the page's.
                var area = CGRect(x: 0, y: 0, width: 1, height: 1)
                for _ in 0..<40 {
                    guard let self else { return }
                    layoutIfNeeded()
                    if let screen = screenArea() { area = screen.union(area); break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let cgImage = image.cgImage, let page = ReaderZoomedText.render(cgImage, area: area) else { throw ContentError.unsupportedFormat }
                // Automatic language detection supports mixed-language pages without a fixed locale priority.
                let analysis = try await ImageAnalyzer().analyze(page, orientation: .up, configuration: .init([.text]))
                try Task.checkCancellation()
                guard let self else { return }
                guard !analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failed(L10n.text("No text to translate was found in this area.")); return
                }
                pageAnalysis = (analysis, area)
                show(analysis, rect: area)
            } catch { if !Task.isCancelled { failed(ContentError.message(error)) } }
        }
    }
    private func startTranslation() {
        guard interaction.analysis != nil else { return }
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            // System controls may appear later than the OCR result. Wait for an enabled action,
            // invoke it only once, and never search outside this translation canvas.
            for _ in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self else { return }
                guard window != nil, bounds.width > 0 else { continue }
                layoutIfNeeded()
                if ReaderLiveTextAction.activate(in: self) { ready(true); return }
            }
            self?.ready(false)
        }
    }
    func cancel() {
        analysisTask?.cancel(); activationTask?.cancel(); zoomTask?.cancel()
        interaction.analysis = nil
        pageAnalysis = nil
        analyzedRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

@MainActor enum ReaderLiveTextAction {
    static func activate(in view: UIView) -> Bool {
        // Menu actions are more reliable than the transient visual shortcut button.
        if activateMenu(in: view) { return true }
        return activateControl(in: view)
    }
    private static func activateMenu(in view: UIView) -> Bool {
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            if let button = child as? UIButton, button.isEnabled,
               let menu = button.menu, perform(in: menu, sender: button) { return true }
            if activateMenu(in: child) { return true }
        }
        return false
    }
    private static func activateControl(in view: UIView) -> Bool {
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            if let control = child as? UIControl, control.isEnabled,
               matches((control as? UIButton)?.title(for: .normal)) || matches(control.accessibilityLabel) || matches(control.accessibilityIdentifier) {
                // A selected shortcut already represents translation; pressing it again would turn it off.
                if control.isSelected { return true }
                let events = control.allControlEvents
                if events.contains(.primaryActionTriggered) {
                    control.sendActions(for: .primaryActionTriggered)
                    return true
                }
                if events.contains(.touchUpInside) {
                    control.sendActions(for: .touchUpInside)
                    return true
                }
                // A visible shortcut can precede registration of its action. Keep waiting in that case.
            }
            if activateControl(in: child) { return true }
        }
        return false
    }
    private static func matches(_ title: String?) -> Bool {
        guard let title else { return false }
        return ["translate", "번역", "翻訳", "翻译", "翻譯"].contains { title.localizedCaseInsensitiveContains($0) }
    }
    private static func perform(in menu: UIMenu, sender: UIButton) -> Bool {
        for element in menu.children {
            if let action = element as? UIAction, matches(action.title),
               !action.attributes.contains(.disabled), !action.attributes.contains(.hidden) {
                if action.state != .on { action.performWithSender(sender, target: nil) }
                return true
            }
            if let submenu = element as? UIMenu, perform(in: submenu, sender: sender) { return true }
        }
        return false
    }
}

/// Shared bounded decoding and viewport crop for both manga and Booru translation.
enum ReaderTranslationImage {
    static func decode(source: CGImageSource, rect: CGRect) throws -> UIImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6000,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ContentError.unsupportedFormat }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let bounded = rect.intersection(unit)
        guard !bounded.isNull, !bounded.isEmpty else { throw ContentError.invalidResponse }
        let region = CGRect(x: bounded.minX * CGFloat(image.width), y: bounded.minY * CGFloat(image.height),
                            width: bounded.width * CGFloat(image.width), height: bounded.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: region) else { throw ContentError.invalidResponse }
        return UIImage(cgImage: crop)
    }
}
