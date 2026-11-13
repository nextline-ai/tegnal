import SwiftUI
import Translation
import NaturalLanguage

/// Apple Translation supplies the requested target; the original image remains
/// intact underneath text overlays that zoom and pan with the page. Once a zoom settles, the part
/// on screen is read again on its own, so small text the page-wide reading missed is translated too.
@available(iOS 18.0, *)
struct TargetedTranslationCanvas: View {
    let image: UIImage
    let target: String
    /// The work's language tag, when known: text is read in it instead of detected.
    var source: String? = nil
    let retry: Int
    var working: () -> Void = {}
    let ready: () -> Void
    let failed: (String) -> Void
    /// Read and waiting for translation, and the zoomed area it came from (nil for the whole image).
    @State private var pending: [ReaderTextRegion] = []
    @State private var pendingArea: CGRect?
    @State private var translated: [ReaderTextRegion] = []
    @State private var configuration: TranslationSession.Configuration?
    /// The zoomed area to read next, and the ones already read.
    @State private var focus: CGRect?
    @State private var readAreas: [CGRect] = []
    var body: some View {
        TranslatedPageCanvas(image: image, regions: translated, zoomSettled: { area in
            guard let area, ReaderZoomedText.needsReading(area, after: readAreas) else { return }
            focus = area
        })
        .task(id: retry) { readAreas = []; await read(nil) }
        .task(id: focus) { if let focus { await read(focus) } }
        .translationTask(configuration) { session in
            do {
                try Task.checkCancellation()
                let regions = pending, area = pendingArea
                let requests = regions.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
                let responses = try await session.translations(from: requests)
                try Task.checkCancellation()
                let found = responses.compactMap { response -> ReaderTextRegion? in
                    guard let key = response.clientIdentifier, let index = Int(key), regions.indices.contains(index) else { return nil }
                    let region = regions[index]
                    return ReaderTextRegion(text: response.targetText, bounds: region.bounds, lines: region.lines, vertical: region.vertical)
                }
                show(found, area: area)
            } catch { if !Task.isCancelled { failed(error.localizedDescription) } }
        }
    }

    /// Reads the whole image, or one zoomed area of it, and queues what it finds for translation.
    private func read(_ area: CGRect?) async {
        do {
            var picture = image
            if let area {
                guard let cgImage = image.cgImage, let crop = ReaderZoomedText.crop(cgImage, to: area) else { return }
                picture = UIImage(cgImage: crop)
                readAreas.append(area)
                working()
            }
            let lines = try await ReaderTextRecognizer.shared.recognize(picture, languages: ReaderSourceLanguage.recognitionLanguages(for: source))
            try Task.checkCancellation()
            // Columns and lines of one balloon translate as one sentence.
            var found = ReaderBalloonGrouping.balloons(lines, language: ReaderSourceLanguage.code(for: source))
            if let area { found = ReaderZoomedText.place(found, readIn: area) }
            guard !found.isEmpty else {
                if area == nil { failed(L10n.text("No text was found in this image.")) } else { ready() }
                return
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(found.map(\.text).joined(separator: "\n"))
            let detected = ReaderSourceLanguage.code(for: source) ?? recognizer.dominantLanguage.map(\.rawValue)
            if let detected, Locale.Language(identifier: detected).languageCode == Locale.Language(identifier: target).languageCode {
                show(found, area: area)
                return
            }
            pending = found
            pendingArea = area
            if configuration == nil {
                configuration = .init(source: detected.map { Locale.Language(identifier: $0) },
                                      target: Locale.Language(identifier: target))
            }
            else { configuration?.invalidate() }
        } catch { if !Task.isCancelled { failed(error.localizedDescription) } }
    }

    /// A whole-image reading replaces every label; a zoomed one replaces those where it found text.
    private func show(_ found: [ReaderTextRegion], area: CGRect?) {
        translated = area == nil ? found : ReaderZoomedText.merge(translated, with: found)
        ready()
    }
}

private struct TranslatedPageCanvas: UIViewRepresentable {
    let image: UIImage
    let regions: [ReaderTextRegion]
    var zoomSettled: (CGRect?) -> Void = { _ in }
    func makeUIView(context: Context) -> TranslatedPageView { TranslatedPageView() }
    func updateUIView(_ view: TranslatedPageView, context: Context) {
        view.zoomSettled = zoomSettled
        view.configure(image, regions: regions)
    }
}

final class TranslatedPageView: UIView {
    private let scroll = PageScrollView()
    private var labels: [UILabel] = []
    private var regions: [ReaderTextRegion] = []
    private var image: UIImage?
    private var labelLayoutSize = CGSize.zero
    /// The zoomed area on screen once the viewport stays still; nil when not zoomed in.
    var zoomSettled: (CGRect?) -> Void = { _ in }
    private var settleTask: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        addSubview(scroll)
        scroll.geometryChanged = { [weak self] in
            self?.placeLabels()
            self?.scheduleSettle()
        }
        scroll.imageView.accessibilityIdentifier = "reader.translation.image"
        scroll.imageView.isAccessibilityElement = false
        scroll.imageView.accessibilityCustomActions = []
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); scroll.frame = bounds; placeLabels() }
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: ReaderZoomedText.settle) } catch { return }
            guard let self else { return }
            zoomSettled(ReaderZoomedText.visibleRect(of: scroll))
        }
    }
    func configure(_ image: UIImage, regions: [ReaderTextRegion]) {
        if self.image !== image { self.image = image; labelLayoutSize = .zero; scroll.update(image: image) }
        guard self.regions != regions else { return }
        self.regions = regions
        labelLayoutSize = .zero
        labels.forEach { $0.removeFromSuperview() }
        labels = regions.enumerated().map { index, region in
            let label = UILabel()
            label.text = region.text
            label.textColor = .black
            label.backgroundColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.layer.cornerRadius = 3
            label.clipsToBounds = true
            label.accessibilityIdentifier = "reader.translation.text.\(index)"
            scroll.imageView.addSubview(label)
            return label
        }
        placeLabels()
    }
    private func placeLabels() {
        let size = scroll.imageView.bounds.size
        // Labels are children of imageView, so UIKit already transforms them with
        // the image. Pan and zoom do not change their local layout or typography.
        guard size.width > 0, size.height > 0, size != labelLayoutSize else { return }
        labelLayoutSize = size
        for (index, region) in regions.enumerated() where labels.indices.contains(index) {
            let box = region.bounds
            let frame = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                               width: box.width * size.width, height: box.height * size.height)
            labels[index].frame = frame.insetBy(dx: -3, dy: -3).intersection(CGRect(origin: .zero, size: size))
            labels[index].font = .systemFont(ofSize: ReaderTranslationLabel.fontSize(for: region, in: frame), weight: .medium)
        }
    }
}

/// The size translated text starts at over a balloon. Vertical balloons are sized by column width,
/// since horizontal translated text runs across them; labels then shrink to fit.
enum ReaderTranslationLabel {
    static func fontSize(for region: ReaderTextRegion, in frame: CGRect) -> CGFloat {
        let basis = (region.vertical ? frame.width * 0.6 : frame.height * 0.78) / CGFloat(max(1, region.lines))
        return max(8, min(22, basis))
    }
}
