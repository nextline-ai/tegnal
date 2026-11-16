import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'image_translation.dart';
import 'page_image_store.dart';

/// One image to translate: where it sits in the reading order, the key its balloons are kept
/// under, and how its bytes are read (`ReaderTranslationJob`).
typedef ReaderTranslationJob = ({int index, String key, Future<Uint8List> Function() load});

/// `ReaderTranslationSession`: translation mode. Once on, every page shows its translation over
/// the original as it comes into view, the next spread is prepared ahead, and a tap on the pill
/// shows the original again. Each page reads on from the lines of the pages before it.
class ReaderTranslationSession extends ChangeNotifier {
  ReaderTranslationSession(this.preferences);
  final Preferences preferences;

  bool _on = false;
  bool _showsOriginal = false;
  final _pages = <String, List<TranslatedRegion>>{};

  /// Each page's balloons from its page-wide reading and from the zoomed areas read again, kept
  /// apart so the on-device model's page-wide reply, which can arrive after a zoom, never takes
  /// back what a closer reading found.
  final _pageWide = <String, List<TranslatedRegion>>{};
  final _zoomed = <String, List<TranslatedRegion>>{};

  /// Zoomed areas of each page already read again, and the reading in progress.
  final _readAreas = <String, List<ui.Rect>>{};
  String? _zoomWorking;
  ui.Rect? _zoomArea;
  int _zoomGeneration = 0;

  /// A zoom made before its page had any translation, read as soon as the page has one.
  ({String key, int index, ui.Rect area, Future<Uint8List> Function() load})? _pendingZoom;
  final _working = <String>{};
  final _history = <int, List<(String, String)>>{};
  List<ReaderTranslationJob> _queue = [];
  bool _continues = true;

  /// The work's language tag, when known: only its recognizer reads the pages.
  String? _language;
  bool _running = false;
  int _generation = 0;
  String _target = 'en';

  /// The last failure worth telling the reader about.
  String? message;

  /// How balloons look, as this mode's viewer settings say.
  TranslationStyle get style => TranslationStyle.stored(preferences);

  /// Enough for a conversation to carry over, small enough for an on-device model.
  static const contextLimit = 12;

  bool get isOn => _on;
  bool get showsOriginal => _showsOriginal;

  List<TranslatedRegion>? balloons(String hash) => _on && !_showsOriginal ? _pages[hash] : null;
  bool isWorking(String hash) => _on && (_working.contains(hash) || _zoomWorking == hash);

  /// Whether pages are still being translated.
  bool get isWorkingAny => _running;

  void toggle() {
    if (_on) {
      stop();
      return;
    }
    _on = true;
    _showsOriginal = false;
    message = null;
    // Loading the model takes seconds; start while the first page is read.
    unawaited(AITranslationModel.check(prepare: true));
    _target = TranslationLanguage.resolved(TranslationLanguage.preference(preferences));
    notifyListeners();
  }

  void stop() {
    _on = false;
    _showsOriginal = false;
    _queue = [];
    _working.clear();
    _generation++;
    _zoomGeneration++;
    _zoomWorking = null;
    _zoomArea = null;
    _pendingZoom = null;
    notifyListeners();
  }

  /// `readZoomed`: once a zoom or a move settles on a translated page, only the part on screen is
  /// read again from the original pixels, so small text the page-wide reading missed is
  /// translated; its balloons replace the page-wide ones where it found text. [area] is
  /// normalized to the image with a top-left origin.
  void readZoomed({required String key, required int index, required ui.Rect area, required Future<Uint8List> Function() load}) {
    if (!_on || !ZoomedText.needsReading(area, _readAreas[key] ?? const [])) return;
    // The area being read already covers this one, as after a small nudge.
    if (_zoomWorking == key && _zoomArea != null && !ZoomedText.needsReading(area, [_zoomArea!])) return;
    final generation = ++_zoomGeneration;
    // Zoomed before the page had any translation: the area is read once the page has one, rather
    // than racing the page-wide reading for the same pixels.
    if (!_pages.containsKey(key)) {
      _pendingZoom = (key: key, index: index, area: area, load: load);
      _zoomWorking = null;
      _zoomArea = null;
      return;
    }
    _pendingZoom = null;
    _zoomWorking = key;
    _zoomArea = area;
    notifyListeners();
    unawaited(_readZoomed(key, index, area, load, generation));
  }

  Future<void> _readZoomed(String key, int index, ui.Rect area, Future<Uint8List> Function() load, int generation) async {
    bool current() => _on && generation == _zoomGeneration;
    try {
      // A quick run of moves reads only where the screen stops.
      await Future<void>.delayed(ZoomedText.coalesce);
      if (!current()) return;
      final crop = await ZoomedText.crop(await load(), area);
      if (crop == null || !current()) return;
      final found = ZoomedText.place(await ImageTranslation.translate(crop, _target, language: _language), area);
      if (!current()) return;
      if (found.isEmpty) {
        (_readAreas[key] ??= []).add(area);
        return;
      }
      // Lines this page already translated keep their translation; only new text is translated.
      final known = {for (final (source, translation) in _history[index] ?? const <(String, String)>[]) source: translation};
      void show(List<TranslatedRegion> regions) {
        _zoomed[key] = ZoomedText.merge(_zoomed[key] ?? const [], [
          for (final region in regions)
            if (known[region.source] case final translation?) region.withText(translation) else region,
        ]);
        _pages[key] = ZoomedText.merge(_pageWide[key] ?? _pages[key] ?? const [], _zoomed[key]!);
        // Shown once: moving back here later keeps it rather than reading it again.
        final read = _readAreas[key] ??= [];
        if (!read.contains(area)) read.add(area);
        notifyListeners();
      }

      // The quick translation shows at once; the on-device AI model's replaces it.
      show(found);
      final fresh = [
        for (final region in found)
          if (region.source != null && !known.containsKey(region.source)) region,
      ];
      if (fresh.isEmpty || AITranslationModel.status != AITranslationModel.available) return;
      final context = <(String, String)>[
        if (_continues)
          for (var previous = (index - 3).clamp(0, index); previous < index; previous++) ...?_history[previous],
        ...?_history[index],
      ];
      final lines = await ImageTranslation.refine(
        [for (final region in fresh) region.source!],
        _target,
        context: context.length > contextLimit ? context.sublist(context.length - contextLimit) : context,
      );
      if (lines == null || !current()) return;
      final refined = {for (final (position, region) in fresh.indexed) region.source!: lines[position]};
      (_history[index] ??= []).addAll([for (final entry in refined.entries) (entry.key, entry.value)]);
      show([
        for (final region in found)
          if (refined[region.source] case final text?) region.withText(text) else region,
      ]);
    } on TranslationError catch (error) {
      if (!error.isQuiet && current()) message ??= error.message;
    } on Object catch (error) {
      if (current()) message ??= ContentError.message(error);
    } finally {
      if (generation == _zoomGeneration && _zoomWorking == key) {
        _zoomWorking = null;
        _zoomArea = null;
        if (_on) notifyListeners();
      }
    }
  }

  /// Sets a page's page-wide balloons, keeping what zoomed readings found on top, and reads a
  /// zoom that was waiting for this page.
  void _setPageWide(String key, List<TranslatedRegion> regions) {
    _pageWide[key] = regions;
    _pages[key] = ZoomedText.merge(regions, _zoomed[key] ?? const []);
    final pending = _pendingZoom;
    if (pending != null && pending.key == key) {
      _pendingZoom = null;
      readZoomed(key: key, index: pending.index, area: pending.area, load: pending.load);
    }
  }

  void toggleOriginal() {
    _showsOriginal = !_showsOriginal;
    notifyListeners();
  }

  /// Translates the visible spread first, then the next one.
  void follow(NativeGallery gallery, {required int index, required int count, required PageImageStore images}) {
    final end = (index + count * 2).clamp(0, gallery.pages.length);
    followJobs([
      for (var position = index; position < end; position++)
        (index: position, key: gallery.pages[position].hash, load: () => images.data(gallery.pages[position], galleryID: gallery.id)),
    ], language: gallery.language);
  }

  /// Translates these images in order, the one on screen first. Pages of one work read on from
  /// the pages before; [continues] false keeps unrelated images, such as posts, apart.
  void followJobs(List<ReaderTranslationJob> jobs, {bool continues = true, String? language}) {
    if (!_on) return;
    _continues = continues;
    _language = language;
    _queue = [
      for (final job in jobs)
        if (!_pages.containsKey(job.key)) job,
    ];
    if (!_running) _run();
  }

  Future<void> _run() async {
    _running = true;
    final generation = _generation;
    while (_on && generation == _generation && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (_pages.containsKey(job.key)) continue;
      _working.add(job.key);
      notifyListeners();
      try {
        final regions = await _translate(job, generation);
        if (generation == _generation) _setPageWide(job.key, regions);
      } on TranslationError catch (error) {
        if (error.isQuiet) {
          if (generation == _generation) _setPageWide(job.key, const []);
        } else {
          message ??= error.message;
        }
      } on Object catch (error) {
        message ??= ContentError.message(error);
      }
      _working.remove(job.key);
      if (generation == _generation) notifyListeners();
    }
    _running = false;
    // A newer session may have queued pages while this one finished.
    if (_on && _queue.isNotEmpty && generation != _generation) _run();
  }

  /// Shows the quick translation as soon as it is ready, then the on-device AI model's, which
  /// reads the page as a whole with the lines of the pages before.
  Future<List<TranslatedRegion>> _translate(ReaderTranslationJob job, int generation) async {
    final bytes = await job.load();
    final index = job.index;
    final quick = await ImageTranslation.translate(bytes, _target, language: _language);
    var regions = quick;
    if (quick.isNotEmpty && generation == _generation && _on) {
      _setPageWide(job.key, quick);
      notifyListeners();
      if (AITranslationModel.status == AITranslationModel.available) {
        final context = <(String, String)>[
          if (_continues)
            for (var previous = (index - 3).clamp(0, index); previous < index; previous++) ...?_history[previous],
        ];
        final lines = await ImageTranslation.refine(
          [for (final region in quick) region.source ?? region.text],
          _target,
          context: context.length > contextLimit ? context.sublist(context.length - contextLimit) : context,
        );
        if (lines != null) regions = [for (final (position, region) in quick.indexed) region.withText(lines[position])];
      }
    }
    _history[index] = [
      for (final region in regions)
        if (region.source case final source?) (source, region.text),
    ];
    return regions;
  }
}

/// `ReaderZoomedText`: zoomed translation. Small text a page-wide reading misses becomes legible
/// once the reader zooms in, so the part on screen is read again on its own and its results
/// replace the page-wide ones there. Areas are normalized to the image with a top-left origin.
abstract final class ZoomedText {
  /// Zoom from which reading the visible part again finds more than the page-wide reading.
  static const minimumScale = 1.3;

  /// How long the viewport stays still before it is read.
  static const settle = Duration(milliseconds: 350);

  /// A short pause before reading, so a quick run of moves reads only where the screen stops.
  static const coalesce = Duration(milliseconds: 250);

  /// The image area on screen for a view of [size] showing the image at [imageRect] through
  /// [transform]; null when it is not zoomed in enough.
  static ui.Rect? visibleArea(Matrix4 transform, ui.Size size, ui.Rect imageRect) {
    if (transform.getMaxScaleOnAxis() < minimumScale || imageRect.width <= 0 || imageRect.height <= 0) return null;
    final inverse = Matrix4.tryInvert(transform);
    if (inverse == null) return null;
    final corners = [MatrixUtils.transformPoint(inverse, ui.Offset.zero), MatrixUtils.transformPoint(inverse, ui.Offset(size.width, size.height))];
    final visible = ui.Rect.fromPoints(corners[0], corners[1]).intersect(imageRect);
    if (visible.width <= 1 || visible.height <= 1) return null;
    return ui.Rect.fromLTWH(
      (visible.left - imageRect.left) / imageRect.width,
      (visible.top - imageRect.top) / imageRect.height,
      visible.width / imageRect.width,
      visible.height / imageRect.height,
    );
  }

  /// A viewport needs reading unless an earlier reading covered it at a similar zoom.
  static bool needsReading(ui.Rect area, List<ui.Rect> read) => !read.any((earlier) {
    final grown = earlier.inflate(0.01);
    return grown.left <= area.left &&
        grown.top <= area.top &&
        grown.right >= area.right &&
        grown.bottom >= area.bottom &&
        earlier.width * earlier.height <= area.width * area.height * 1.5;
  });

  /// The pixels of [area] from an encoded image, as PNG. Large areas are scaled down to
  /// [maximumPixels] on their long side, since text recognition reads at about that size anyway.
  static Future<Uint8List?> crop(Uint8List bytes, ui.Rect area, {double maximumPixels = 4096}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final source = ui.Rect.fromLTWH(area.left * image.width, area.top * image.height, area.width * image.width, area.height * image.height);
      if (source.width < 1 || source.height < 1) return null;
      final scale = math.min(1.0, maximumPixels / math.max(source.width, source.height));
      final width = (source.width * scale).round(), height = (source.height * scale).round();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawImageRect(image, source, ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
      final cropped = await recorder.endRecording().toImage(width, height);
      try {
        final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        cropped.dispose();
      }
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  /// Regions read in the crop of [area], placed on the whole image. Text cut by the screen edge is
  /// dropped: it is read whole from the page or a later viewport.
  static List<TranslatedRegion> place(List<TranslatedRegion> regions, ui.Rect area) {
    const edge = 0.01;
    return [
      for (final region in regions)
        if (!((region.left < edge && area.left > 0.001) ||
            (region.left + region.width > 1 - edge && area.right < 0.999) ||
            (region.top < edge && area.top > 0.001) ||
            (region.top + region.height > 1 - edge && area.bottom < 0.999)))
          TranslatedRegion(
            text: region.text,
            left: area.left + region.left * area.width,
            top: area.top + region.top * area.height,
            width: region.width * area.width,
            height: region.height * area.height,
            vertical: region.vertical,
            lines: region.lines,
            source: region.source,
          ),
    ];
  }

  /// The closer reading wins where it found text; earlier text elsewhere stays.
  static List<TranslatedRegion> merge(List<TranslatedRegion> existing, List<TranslatedRegion> found) {
    ui.Rect box(TranslatedRegion region) => ui.Rect.fromLTWH(region.left, region.top, region.width, region.height);
    return [
      for (final old in existing)
        if (!found.any((region) => box(region).overlaps(box(old)))) old,
      ...found,
    ];
  }
}

/// Hands the reader's translation session to every page, rebuilding them as pages come in.
class ReaderTranslationScope extends InheritedNotifier<ReaderTranslationSession> {
  const ReaderTranslationScope({super.key, required ReaderTranslationSession session, required super.child}) : super(notifier: session);

  static ReaderTranslationSession? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ReaderTranslationScope>()?.notifier;
}

/// `ReaderTranslationToggle`: the only control translation mode adds, a small pill that switches
/// between the translation and the original and fades away once it is not needed.
class ReaderTranslationToggle extends StatelessWidget {
  const ReaderTranslationToggle({super.key, required this.showsOriginal, required this.working, required this.onPressed});
  final bool showsOriginal;
  final bool working;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const white = Color(0xFFFFFFFF);
    // Names what a tap shows next.
    final title = L10n.text(showsOriginal ? 'Show Translation' : 'Show Original');
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const ShapeDecoration(color: Color(0x8C000000), shape: StadiumBorder()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (working)
                const SizedBox.square(dimension: 14, child: CupertinoActivityIndicator(color: white, radius: 7))
              else
                const TranslateSymbol(color: white, size: 15),
              const SizedBox(width: 6),
              Text(
                title,
                style: TegnalType.style(13, weight: FontWeight.w600, color: white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
