import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import 'image_translation.dart';
import 'page_image_store.dart';

/// `ReaderTranslationSession`: translation mode. Once on, every page shows its translation over
/// the original as it comes into view, the next spread is prepared ahead, and a tap on the pill
/// shows the original again. Each page reads on from the lines of the pages before it.
class ReaderTranslationSession extends ChangeNotifier {
  ReaderTranslationSession(this.preferences);
  final Preferences preferences;

  bool _on = false;
  bool _showsOriginal = false;
  final _pages = <String, List<TranslatedRegion>>{};
  final _working = <String>{};
  final _history = <int, List<(String, String)>>{};
  List<({int index, GalleryPage page, int galleryID})> _queue = [];
  bool _running = false;
  int _generation = 0;
  PageImageStore? _images;
  String _target = 'en';

  /// The last failure worth telling the reader about.
  String? message;

  /// Enough for a conversation to carry over, small enough for an on-device model.
  static const contextLimit = 12;

  bool get isOn => _on;
  bool get showsOriginal => _showsOriginal;

  List<TranslatedRegion>? balloons(String hash) => _on && !_showsOriginal ? _pages[hash] : null;
  bool isWorking(String hash) => _on && _working.contains(hash);

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
    _target = TranslationLanguage.resolved(TranslationLanguage.preference(preferences));
    notifyListeners();
  }

  void stop() {
    _on = false;
    _showsOriginal = false;
    _queue = [];
    _working.clear();
    _generation++;
    notifyListeners();
  }

  void toggleOriginal() {
    _showsOriginal = !_showsOriginal;
    notifyListeners();
  }

  /// Translates the visible spread first, then the next one.
  void follow(NativeGallery gallery, {required int index, required int count, required PageImageStore images}) {
    if (!_on) return;
    _images = images;
    final end = (index + count * 2).clamp(0, gallery.pages.length);
    _queue = [
      for (var position = index; position < end; position++)
        if (!_pages.containsKey(gallery.pages[position].hash)) (index: position, page: gallery.pages[position], galleryID: gallery.id),
    ];
    if (!_running) _run();
  }

  Future<void> _run() async {
    _running = true;
    final generation = _generation;
    while (_on && generation == _generation && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      final images = _images;
      if (_pages.containsKey(job.page.hash) || images == null) continue;
      _working.add(job.page.hash);
      notifyListeners();
      try {
        final regions = await _translate(job.page, job.index, job.galleryID, images);
        if (generation == _generation) _pages[job.page.hash] = regions;
      } on TranslationError catch (error) {
        if (error.isQuiet) {
          if (generation == _generation) _pages[job.page.hash] = const [];
        } else {
          message ??= error.message;
        }
      } on Object catch (error) {
        message ??= ContentError.message(error);
      }
      _working.remove(job.page.hash);
      if (generation == _generation) notifyListeners();
    }
    _running = false;
    // A newer session may have queued pages while this one finished.
    if (_on && _queue.isNotEmpty && generation != _generation) _run();
  }

  Future<List<TranslatedRegion>> _translate(GalleryPage page, int index, int galleryID, PageImageStore images) async {
    final bytes = await images.data(page, galleryID: galleryID);
    final context = <(String, String)>[for (var previous = (index - 3).clamp(0, index); previous < index; previous++) ...?_history[previous]];
    final regions = await ImageTranslation.translate(
      bytes,
      _target,
      context: context.length > contextLimit ? context.sublist(context.length - contextLimit) : context,
    );
    _history[index] = [
      for (final region in regions)
        if (region.source case final source?) (source, region.text),
    ];
    return regions;
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
