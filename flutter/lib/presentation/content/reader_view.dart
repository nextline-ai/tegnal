import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'gallery_detail_view.dart';
import 'image_translation.dart';
import 'page_image_store.dart';
import 'reader_guide_overlay.dart';
import 'reader_models.dart';
import 'viewer_dismiss.dart';
import 'reader_pager.dart';
import 'reader_translation.dart';
import '../design/alert_dialog.dart';
import '../../core/taste/taste_models.dart';
import 'content_bookmark.dart';
import 'reading_queue_views.dart';
import 'viewer_quick_menu.dart';
import '../../core/content/recent_works.dart';
import '../../core/content/manga_urls.dart';

/// Opens the reader full screen over everything, as `fullScreenCover` does.
Future<void> openReader(
  BuildContext context, {
  required int galleryID,
  required int initialPage,
  required ContentProviding source,
  required PageImageStore images,
  required ContentEnvironment content,
  required AppDatabase database,
  required Preferences preferences,
  bool savesProgress = true,
  bool resumesProgress = true,
  required Future<void> Function(NativeGallery gallery) bookmark,
  ValueChanged<String>? search,
  void Function(BuildContext context, NativeGallery gallery)? download,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  ViewerRoute<void>(
    builder: (context) => _ReaderSession(
      initialID: galleryID,
      // `MangaReaderSession`: the reader switches to a work from Up Next in place.
      build: (id, open) => NativeReaderView(
        key: ValueKey(id),
        galleryID: id,
        initialPage: id == galleryID ? initialPage : 1,
        source: source,
        images: images,
        content: content,
        database: database,
        preferences: preferences,
        savesProgress: savesProgress,
        resumesProgress: id == galleryID && resumesProgress,
        bookmark: bookmark,
        search: search,
        download: download,
        openWork: open,
      ),
    ),
  ),
);

class _ReaderSession extends StatefulWidget {
  const _ReaderSession({required this.initialID, required this.build});
  final int initialID;
  final Widget Function(int id, ValueChanged<int> open) build;

  @override
  State<_ReaderSession> createState() => _ReaderSessionState();
}

class _ReaderSessionState extends State<_ReaderSession> {
  late int _id = widget.initialID;

  @override
  Widget build(BuildContext context) => widget.build(_id, (id) => setState(() => _id = id));
}

/// `NativeReaderView`: a work's pages on black, with a quick menu, settings and work information.
class NativeReaderView extends StatefulWidget {
  const NativeReaderView({
    super.key,
    required this.galleryID,
    required this.initialPage,
    required this.source,
    required this.images,
    required this.content,
    required this.database,
    required this.preferences,
    required this.bookmark,
    this.savesProgress = true,
    this.resumesProgress = true,
    this.search,
    this.download,
    this.openWork,
  });

  final int galleryID;

  /// One-based, like the native reader.
  final int initialPage;
  final ContentProviding source;
  final PageImageStore images;
  final ContentEnvironment content;
  final AppDatabase database;
  final Preferences preferences;
  final bool savesProgress;
  final bool resumesProgress;
  final Future<void> Function(NativeGallery gallery) bookmark;
  final ValueChanged<String>? search;

  /// Queues the work for offline reading and shows the downloads, as the quick menu does.
  final void Function(BuildContext context, NativeGallery gallery)? download;

  /// Switches the reader to another work, as a work from Up Next opens in place.
  final ValueChanged<int>? openWork;

  @override
  State<NativeReaderView> createState() => _NativeReaderViewState();
}

class _NativeReaderViewState extends State<NativeReaderView> with TickerProviderStateMixin {
  NativeGallery? _gallery;
  late ReaderOpening _opening;
  bool _resumeReady = false;
  int _current = 0;
  String? _error;
  bool _menuVisible = false;
  bool _sheetOpen = false;
  final _zoomedPages = <int>{};
  String? _toast;
  Timer? _toastTimer;

  /// The page being translated on its own, shown over the reader until Original closes it.
  int? _translating;

  /// Translation mode, kept while pages turn.
  late final _translation = ReaderTranslationSession(widget.preferences)..addListener(_translationChanged);

  /// The translation pill shows for a moment after something changes, then fades away.
  Timer? _pillTimer;
  bool _pillShown = false;
  Timer? _autoTimer;
  late final _dismiss = ViewerDismiss(vsync: this);
  bool _exiting = false;
  final _guide = ReaderGuideSession();
  bool _pendingGuide = false;
  final _menuKey = GlobalKey();

  /// Loads the pages after the visible spread while reading, as the native reader does.
  final _prefetcher = ReaderPagePrefetcher();
  String? _prefetchKey;
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;

  Preferences get _defaults => widget.preferences;
  String get _mode => _defaults.string('reader.mode') ?? ReaderMode.horizontal.rawValue;
  bool get _rtl => _defaults.boolean('reader.rtl') ?? false;
  int get _pagesPerSpread => _defaults.integerOrNull('reader.pagesPerSpread') ?? 1;
  bool get _bottomMenu => _defaults.boolean('reader.bottomMenu') ?? false;
  bool get _pageNumber => _defaults.boolean('reader.pageNumber') ?? false;
  bool get _keepAwake => _defaults.boolean('reader.keepAwake') ?? true;
  double get _dimming => (_defaults.object('reader.dimming') as num?)?.toDouble() ?? 0;
  bool get _tapNavigation => _defaults.boolean('reader.tapNavigation') ?? true;
  bool get _autoAdvance => _defaults.boolean('reader.autoAdvance') ?? false;
  double get _autoSeconds => (_defaults.object('reader.autoSeconds') as num?)?.toDouble() ?? 10;
  int get _count => readerSpreadCount(_pagesPerSpread);
  bool get _zoomed => _zoomedPages.isNotEmpty;
  bool get _active => !_exiting && !_opening.needsConfirmation && !_sheetOpen && _translating == null;
  int get _prefetchCount => _defaults.integerOrNull(ReaderSettingKeys.prefetch) ?? 3;

  /// Follows the visible page; speculation stops while zoomed, behind a sheet or in the background.
  void _syncPrefetch() {
    final gallery = _gallery;
    final allowed =
        gallery != null &&
        _active &&
        _foreground &&
        !_zoomed &&
        _prefetchCount > 0 &&
        _current >= 0 &&
        _current < gallery.pages.length &&
        widget.images.canPrefetch;
    final key = allowed ? '${gallery.id}:$_current:$_pagesPerSpread:$_prefetchCount' : null;
    if (key == _prefetchKey) return;
    _prefetchKey = key;
    if (allowed) {
      _prefetcher.update(gallery: gallery, images: widget.images, current: _current, count: _prefetchCount, visibleCount: _pagesPerSpread);
    } else {
      _prefetcher.cancel();
    }
  }

  @override
  void initState() {
    super.initState();
    final saved = widget.savesProgress ? _defaults.integer('reader_page_${widget.galleryID}') : 0;
    _opening = ReaderResumeBehavior.stored(_defaults).opening(initial: widget.initialPage, saved: saved, resumesProgress: widget.resumesProgress);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ReaderScreen.keepAwake(_keepAwake);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        _foreground = state == AppLifecycleState.resumed;
        _syncPrefetch();
      },
    );
    _load();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _lifecycle.dispose();
    _prefetcher.cancel();
    _autoTimer?.cancel();
    _pillTimer?.cancel();
    _translation
      ..removeListener(_translationChanged)
      ..dispose();
    _dismiss.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    ReaderScreen.keepAwake(false);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _menuVisible = false;
    });
    try {
      final gallery = _gallery ?? await widget.source.gallery(widget.galleryID);
      if (!mounted) return;
      if (_gallery == null) {
        setState(() {
          _current = ReaderLayout.initialPage(_opening.initialPage, saved: 0, total: gallery.pages.length, count: _pagesPerSpread);
          _gallery = gallery;
        });
      }
      if (_opening.needsConfirmation) {
        final first = gallery.pages.firstOrNull;
        if (first != null) {
          try {
            await widget.images.load(first, galleryID: widget.galleryID);
          } on Object {
            // The prompt still appears.
          }
        }
        if (!mounted) return;
        setState(() => _resumeReady = true);
        await _askToResume();
        return;
      }
      _saveProgress();
      if (!(_defaults.boolean(ReaderSettingKeys.helpHidden) ?? false) && !_guide.hasStarted) setState(_guide.start);
      if (widget.savesProgress) {
        widget.database.markOpened(gallery.id);
        _rememberOpened(gallery);
      }
      _scheduleAuto();
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = ContentError.message(error);
          _menuVisible = true;
        });
      }
    }
  }

  Future<void> _askToResume() async {
    final continuing = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Continue Reading?')),
        content: Text(L10n.text('Continue from page %@?', ['${_opening.page}'])),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Continue Reading'))),
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (!mounted) return;
    final resolved = _opening.resolved(continuing: continuing ?? false);
    setState(() {
      if (_gallery != null) _current = ReaderLayout.initialPage(resolved.page, saved: 0, total: _gallery!.pages.length, count: _pagesPerSpread);
      _opening = resolved;
    });
    _saveProgress();
    _scheduleAuto();
  }

  void _saveProgress() {
    if (widget.savesProgress && !_opening.needsConfirmation) _defaults.set('reader_page_${widget.galleryID}', _current + 1);
  }

  void _pageChanged(int page) {
    final start = ReaderLayout.start(page, count: _pagesPerSpread);
    if (start == _current) return;
    setState(() {
      _current = start;
      _zoomedPages.clear();
    });
    _markReadIfLast();
    _saveProgress();
    _scheduleAuto();
    _followTranslation();
  }

  /// Read to the end, a work waiting in Up Next has been read.
  void _markReadIfLast() {
    final gallery = _gallery;
    if (gallery == null || gallery.pages.isEmpty) return;
    if (_current + _count >= gallery.pages.length) ReadingQueueScope.read(context)?.finished(gallery.id);
  }

  void _setMenu(bool visible) {
    if (_menuVisible == visible) return;
    setState(() => _menuVisible = visible);
    if (visible) _guide.openedMenu();
  }

  void _showQueue() => showAppSheet<void>(
    context,
    grabber: true,
    builder: (sheetContext, controller) => ReadingQueueView(
      queue: ReadingQueueScope.read(context)!,
      scrollController: controller,
      read: (id) {
        Navigator.of(sheetContext).pop();
        _openQueued(id);
      },
    ),
  );

  void _openQueued(int id) {
    setState(() => _menuVisible = false);
    if (id == widget.galleryID) return;
    widget.openWork?.call(id);
  }

  /// Puts the work at the top of Recently Opened Works, with its cover once it loads.
  void _rememberOpened(NativeGallery gallery) {
    final recents = RecentWorks.shared;
    if (recents == null) return;
    final first = gallery.pages.firstOrNull;
    recents.openedGallery(gallery, site: ComicSites.active, cover: first == null || recents.hasCover(gallery.id) ? null : _coverData(first, gallery.id));
  }

  Future<Uint8List?> _coverData(GalleryPage page, int id) async {
    try {
      return await widget.images.data(page, galleryID: id, thumbnail: true);
    } on Object {
      return null;
    }
  }

  void _move(int delta) {
    final gallery = _gallery;
    if (gallery == null) return;
    _pageChanged(ReaderLayout.next(_current, delta: delta, count: _pagesPerSpread, total: gallery.pages.length));
  }

  void _tapped(double x) {
    if (x >= 0.3 && x <= 0.7) {
      setState(() {
        _menuVisible = !_menuVisible;
        if (_menuVisible) _guide.openedMenu();
      });
      _scheduleAuto();
    } else if (_tapNavigation) {
      _move((x < 0.3 ? -1 : 1) * (_rtl ? -1 : 1));
    }
  }

  /// Turns pages at the chosen interval, pausing while anything else needs attention.
  void _scheduleAuto() {
    _autoTimer?.cancel();
    final gallery = _gallery;
    if (!_autoAdvance || _guide.step != null || !_active || _menuVisible || _zoomed || gallery == null) return;
    _autoTimer = Timer(Duration(milliseconds: (_autoSeconds.clamp(2, 120) * 1000).round()), () {
      if (!mounted) return;
      final next = ReaderLayout.next(_current, delta: 1, count: _pagesPerSpread, total: gallery.pages.length);
      if (next == _current) {
        _defaults.set('reader.autoAdvance', false);
      } else {
        _pageChanged(next);
      }
    });
  }

  Future<void> _bookmark() async {
    final gallery = _gallery;
    if (gallery == null) return;
    await widget.bookmark(gallery);
    // The quick menu shows whether the work is now bookmarked.
    if (mounted) setState(() {});
  }

  void _advanceGuide() {
    setState(() {
      switch (_guide.step) {
        case ReaderGuideStep.navigation:
          _guide.advance();
          _menuVisible = true;
        case ReaderGuideStep.tools:
          _guide.advance();
          _menuVisible = false;
        case ReaderGuideStep.exit:
          _finishGuide();
        case null:
          break;
      }
    });
    _scheduleAuto();
  }

  void _finishGuide() {
    setState(_guide.finish);
    _defaults.set(ReaderSettingKeys.helpHidden, true);
    _scheduleAuto();
  }

  void _close() {
    if (_exiting) return;
    if (_guide.step != null) _finishGuide();
    _exiting = true;
    Navigator.of(context).pop();
  }

  Future<void> _sheet(Widget Function(BuildContext context, ScrollController controller) builder) async {
    setState(() => _sheetOpen = true);
    _autoTimer?.cancel();
    await showAppSheet<void>(context, grabber: true, builder: builder);
    if (!mounted) return;
    setState(() {
      _sheetOpen = false;
      if (_pendingGuide) {
        _pendingGuide = false;
        _menuVisible = false;
        _guide.start();
      }
    });
    ReaderScreen.keepAwake(_keepAwake);
    _scheduleAuto();
  }

  void _openSettings() => _sheet(
    (context, controller) => ReaderSettingsView(
      preferences: _defaults,
      scrollController: controller,
      onChanged: () => setState(() {}),
      onShowGuide: () {
        _pendingGuide = true;
        Navigator.of(context).pop();
      },
    ),
  );

  void _openInformation() {
    final gallery = _gallery;
    if (gallery == null) return;
    _sheet(
      // Like work information over Explore, a swipe to the right closes it.
      (sheetContext, controller) => SheetSwipeBack(
        close: () => Navigator.of(sheetContext).pop(),
        child: ScrollEdgeSheet(
          bar: SheetNavigationBar(
            title: L10n.text('Work Details'),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(sheetContext).pop()),
          ),
          child: GalleryWorkInformation(
            gallery: gallery,
            images: widget.images,
            content: widget.content,
            database: widget.database,
            showsCover: false,
            showsRead: false,
            scrollController: controller,
            topInset: 76,
            actions: GalleryDetailActions(
              read: (page, {required resume}) {
                Navigator.of(sheetContext).pop();
                _pageChanged(page);
              },
              save: (gallery) => widget.bookmark(gallery),
              search: widget.search == null
                  ? null
                  : (text) {
                      Navigator.of(sheetContext).pop();
                      _close();
                      widget.search!(text);
                    },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _jump() async {
    final gallery = _gallery;
    if (gallery == null) return;
    final controller = TextEditingController(text: '${_current + 1}');
    final page = await showCupertinoDialog<int>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Go to Page')),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(controller: controller, keyboardType: TextInputType.number, placeholder: L10n.text('Page Number'), autofocus: true),
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, int.tryParse(controller.text)), child: Text(L10n.text('Go'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    controller.dispose();
    if (page == null || !mounted) return;
    _pageChanged(ReaderLayout.start((page - 1).clamp(0, gallery.pages.length - 1), count: _pagesPerSpread));
  }

  @override
  Widget build(BuildContext context) {
    _syncPrefetch();
    final gallery = _gallery;
    final media = MediaQuery.of(context);
    return CupertinoTheme(
      data: tegnalTheme(Brightness.dark),
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: _swipes(gallery, media),
        child: ViewerDismissSurface(
          dismiss: _dismiss,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Stack(
              children: [
                Positioned.fill(
                  child: gallery != null && (!_opening.needsConfirmation || _resumeReady)
                      ? ReaderTranslationScope(session: _translation, child: _reader(gallery))
                      : _error != null
                      ? Center(
                          child: ContentFailure(message: _error!, retry: _load, content: widget.content),
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CupertinoActivityIndicator(color: Color(0xFFFFFFFF)),
                              const SizedBox(height: 8),
                              Text(L10n.text('Loading page'), style: TegnalType.style(15, color: const Color(0xFFFFFFFF))),
                            ],
                          ),
                        ),
                ),
                if (_dimming > 0)
                  Positioned.fill(
                    child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, _dimming.clamp(0, 0.65)))),
                  ),
                // `ReaderDismissHandle`; the pull itself belongs to the whole reader.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: math.max(44, media.padding.top + 24),
                  child: IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Semantics(
                          button: true,
                          label: L10n.text('Swipe down to exit the work'),
                          onTap: _close,
                          child: Container(
                            width: 60,
                            height: 4,
                            decoration: const ShapeDecoration(color: Color(0xFF636366), shape: StadiumBorder()),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Only the menu moves, by its own height, so it visibly rises and falls.
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10 + media.padding.bottom,
                  child: ViewerMenuReveal(
                    visible: _menuVisible || gallery == null,
                    child: Column(
                      key: const ValueKey('menu'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ReadingQueueScope.of(context) case final queue?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: ReaderQueueRow(queue: queue, currentID: widget.galleryID, open: _openQueued, showList: _showQueue),
                          ),
                        _quickMenu(gallery),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  // The native menu sits above the home indicator; immersive Android has no inset there,
                  // so keep the same clearance from the gesture area.
                  bottom: 16 + math.max(media.padding.bottom, 34),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!(_menuVisible || gallery == null) && _pageNumber)
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: const ShapeDecoration(color: Color(0x80000000), shape: StadiumBorder()),
                          child: Text('${_current + 1} / ${gallery.pages.length}', style: TegnalType.style(12, color: const Color(0xFFFFFFFF))),
                        ),
                      if (_bottomMenu && !_menuVisible && gallery != null) ...[
                        const SizedBox(height: 8),
                        ReaderMenuGlass(
                          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: _menuActions(compact: true)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_guide.step case final step? when !_sheetOpen)
                  Positioned.fill(
                    child: ReaderGuideOverlay(
                      step: step,
                      configuration: ReaderGuideConfiguration(booru: false, defaults: _defaults),
                      menuKey: _menuKey,
                      next: _advanceGuide,
                      finish: _finishGuide,
                    ),
                  ),
                if (_translating case final index? when gallery != null && index < gallery.pages.length)
                  Positioned.fill(
                    child: ImageTranslationView(
                      key: ValueKey(index),
                      loadImage: () => widget.images.data(gallery.pages[index], galleryID: widget.galleryID),
                      preferences: _defaults,
                      finished: () => setState(() => _translating = null),
                      failed: (message) {
                        setState(() => _translating = null);
                        _showToast(message);
                      },
                    ),
                  ),
                if (_translation.isOn && gallery != null && _current < gallery.pages.length)
                  Positioned(
                    top: media.padding.top + 8,
                    right: 16,
                    child: Builder(
                      builder: (context) {
                        final working = _translation.isWorking(gallery.pages[_current].hash);
                        final visible = _menuVisible || working || _pillShown;
                        return IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedOpacity(
                            opacity: visible ? 1 : 0,
                            duration: const Duration(milliseconds: 250),
                            child: ReaderTranslationToggle(
                              showsOriginal: _translation.showsOriginal,
                              working: working,
                              onPressed: () {
                                _translation.toggleOriginal();
                                _showPill();
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (_toast != null)
                  Positioned(
                    top: media.padding.top + 16,
                    left: 16,
                    right: 16,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const ShapeDecoration(color: Color(0xE6303030), shape: StadiumBorder()),
                        child: Text(
                          _toast!,
                          style: TegnalType.style(15, weight: FontWeight.w700, color: const Color(0xFFFFFFFF)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `ReaderExitGesture` and `ReaderInformationGesture`: pulling down closes the reader from
  /// anywhere when pages turn sideways, or from the top 64 points when they scroll vertically;
  /// swiping up from the bottom quarter opens work information.
  Map<Type, GestureRecognizerFactory> _swipes(NativeGallery? gallery, MediaQueryData media) {
    final bounds = Offset.zero & media.size;
    final mode = _mode;
    return {
      ViewerPullDownRecognizer: GestureRecognizerFactoryWithHandlers<ViewerPullDownRecognizer>(
        () => ViewerPullDownRecognizer(accepts: (point) => false),
        (recognizer) => recognizer
          ..accepts = ((point) =>
              _active && !_zoomed && (mode == ReaderMode.horizontal.rawValue || ReaderDismissal.isInExitZone(point, bounds, safeTop: media.padding.top)))
          ..onStart = (() => _dismiss.begin(context))
          ..onUpdate = ((delta) => _dismiss.update(delta.dy))
          ..onEnd = ((delta, velocity) => _dismiss.end(delta: delta, velocity: velocity, screenHeight: media.size.height, exit: _close))
          ..onCancel = _dismiss.cancel,
      ),
      ViewerSwipeUpRecognizer: GestureRecognizerFactoryWithHandlers<ViewerSwipeUpRecognizer>(
        () => ViewerSwipeUpRecognizer(accepts: (point) => false),
        (recognizer) => recognizer
          ..accepts = ((point) =>
              gallery != null &&
              _active &&
              !_zoomed &&
              !_menuVisible &&
              ReaderInformationReveal.isEnabled(mode: mode, continuousOptIn: _defaults.boolean(ReaderSettingKeys.continuousPreviewSwipe) ?? false) &&
              ReaderInformationReveal.isInZone(point, bounds))
          ..onEnd = ((delta, velocity) {
            if (ReaderInformationReveal.shouldReveal(delta: delta, velocity: velocity)) _openInformation();
          }),
      ),
    };
  }

  /// Turns translation mode on or off from the quick menu.
  void _translate() {
    if (!ReaderPreferences.continuousTranslation && !_translation.isOn) {
      setState(() {
        _translating = _current;
        _menuVisible = false;
      });
      _scheduleAuto();
      return;
    }
    setState(() => _menuVisible = false);
    _translation.toggle();
    _followTranslation();
    _scheduleAuto();
  }

  void _followTranslation() {
    final gallery = _gallery;
    if (!_translation.isOn || gallery == null) return;
    _translation.follow(gallery, index: _current, count: _count, images: widget.images);
    _showPill();
  }

  void _showPill() {
    _pillTimer?.cancel();
    if (mounted) setState(() => _pillShown = true);
    _pillTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _pillShown = false);
    });
  }

  void _translationChanged() {
    if (!mounted) return;
    final message = _translation.message;
    if (message != null) {
      _translation.message = null;
      _showToast(message);
    }
    setState(() {});
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Widget _reader(NativeGallery gallery) {
    void zoomChanged(int index, bool zoomed) {
      setState(() => zoomed ? _zoomedPages.add(index) : _zoomedPages.remove(index));
      _scheduleAuto();
    }

    if (_mode == ReaderMode.continuous.rawValue) {
      return ReaderContinuousView(
        key: ValueKey('${gallery.id}:continuous:$_pagesPerSpread'),
        gallery: gallery,
        images: widget.images,
        current: _current,
        onPageChanged: _pageChanged,
        tap: _tapped,
        bookmark: _bookmark,
        count: _count,
        rtl: _rtl,
        onZoomChanged: zoomChanged,
        isActive: _active,
      );
    }
    return ReaderPager(
      key: ValueKey('${gallery.id}:$_mode:$_rtl:$_pagesPerSpread'),
      gallery: gallery,
      images: widget.images,
      vertical: _mode == ReaderMode.vertical.rawValue,
      rtl: _rtl,
      current: _current,
      onPageChanged: _pageChanged,
      tap: _tapped,
      bookmark: _bookmark,
      count: _count,
      onZoomChanged: zoomChanged,
      isActive: _active,
    );
  }

  Widget _quickMenu(NativeGallery? gallery) {
    final total = gallery?.pages.length ?? 0;
    return ViewerQuickMenuPanel(
      key: _menuKey,
      close: () {
        _setMenu(false);
        _scheduleAuto();
      },
      navigation: ViewerQuickMenuNavigation(
        position: '${_current + 1} / $total',
        previousLabel: L10n.text('Previous Page'),
        nextLabel: L10n.text('Next Page'),
        closeLabel: L10n.text('Close Menu'),
        previous: _current == 0 ? null : () => _move(-1),
        next: _current + _count >= math.max(1, total) ? null : () => _move(1),
        jump: _jump,
        close: () {
          _setMenu(false);
          _scheduleAuto();
        },
      ),
      actions: _menuActions(compact: false),
    );
  }

  Widget _menuActions({required bool compact}) {
    final gallery = _gallery;
    final hasGallery = gallery != null;
    // Read each time the menu draws, so a change from the details sheet shows too.
    final saved = gallery != null && widget.database.getWork(gallery.id) != null;
    final savedColor = SystemColors.yellow.resolveFrom(context);
    final items = <(String, Widget Function(Color), VoidCallback?)>[
      // Translation arrives with its own rebuild step.
      (
        L10n.text('Download Work'),
        (color) => Icon(CupertinoIcons.arrow_down_circle, size: 24, color: color),
        hasGallery && widget.download != null ? () => widget.download!(context, _gallery!) : null,
      ),
      (
        WorkSaveResult.actionTitle(saved: saved, mode: TasteMode.comics),
        (color) => saved ? Icon(CupertinoIcons.bookmark_fill, size: 24, color: savedColor) : Icon(CupertinoIcons.bookmark, size: 24, color: color),
        hasGallery ? _bookmark : null,
      ),
      (L10n.text('Exit'), (color) => ExitSymbol(color: color), _close),
      (
        L10n.text(_translation.isOn ? 'Stop Translating' : 'Translate'),
        (color) => TranslateSymbol(color: _translation.isOn ? TegnalColors.tint.resolveFrom(context) : color),
        hasGallery ? _translate : null,
      ),
      (L10n.text('Work Details'), (color) => Icon(CupertinoIcons.info_circle, size: 24, color: color), hasGallery ? _openInformation : null),
      (L10n.text('More Settings'), (color) => Icon(CupertinoIcons.slider_horizontal_3, size: 24, color: color), _openSettings),
    ];
    const white = Color(0xFFFFFFFF);
    if (!compact) {
      return ViewerQuickMenuGrid(
        children: [
          for (final (title, icon, action) in items)
            ViewerQuickMenuButton(
              title: title,
              icon: SizedBox(height: 26, child: Center(child: icon(white))),
              onTap: action,
            ),
        ],
      );
    }
    const columns = 6;
    return Column(
      children: [
        for (var row = 0; row < items.length / columns; row++) ...[
          if (row > 0) const SizedBox(height: 20),
          Row(
            children: [
              for (final (title, icon, action) in items.skip(row * columns).take(columns))
                Expanded(
                  child: Semantics(
                    button: true,
                    label: title,
                    enabled: action != null,
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: action,
                      child: Opacity(
                        opacity: action == null ? 0.35 : 1,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(height: 24, child: Center(child: icon(white))),
                              const SizedBox(height: 6),
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TegnalType.style(9, weight: FontWeight.w500, color: white),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `ReaderMenuGlass`: dark glass tinted 30% black, 24 pt corners, always in dark appearance.
/// The fill is measured from the native menu over a light page and over black.
class ReaderMenuGlass extends StatelessWidget {
  const ReaderMenuGlass({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(24)));
    return ClipPath(
      clipper: const ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: const ShapeDecoration(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
              side: BorderSide(color: Color(0x26FFFFFF), width: 0.5),
            ),
            color: Color(0xC0242426),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Keeps the screen on while reading, through the app's own window flag.
abstract final class ReaderScreen {
  static const _channel = MethodChannel('work.nextline.tegnal/screen');
  static Future<void> keepAwake(bool value) async {
    try {
      await _channel.invokeMethod<void>('keepAwake', value);
    } on Object {
      // Tests and platforms without the channel ignore it.
    }
  }
}

/// `ReaderSettingsView` for comics, or with [booru] for the image viewer's own options.
class ReaderSettingsView extends StatefulWidget {
  const ReaderSettingsView({super.key, required this.preferences, this.booru = false, this.scrollController, this.onChanged, this.onShowGuide});
  final Preferences preferences;
  final bool booru;
  final ScrollController? scrollController;
  final VoidCallback? onChanged;

  /// Inside the reader the guide starts at once; elsewhere it waits for the next work.
  final VoidCallback? onShowGuide;

  @override
  State<ReaderSettingsView> createState() => _ReaderSettingsViewState();
}

class _ReaderSettingsViewState extends State<ReaderSettingsView> {
  Preferences get _defaults => widget.preferences;

  void _set(String key, Object? value) {
    setState(() => _defaults.set(key, value));
    widget.onChanged?.call();
  }

  bool _bool(String key, bool fallback) => _defaults.boolean(key) ?? fallback;

  @override
  Widget build(BuildContext context) {
    final mode = _defaults.string('reader.mode') ?? ReaderMode.horizontal.rawValue;
    final pagesPerSpread = _defaults.integerOrNull('reader.pagesPerSpread') ?? 1;
    final resume = _defaults.string('reader.resumeBehavior') ?? ReaderResumeBehavior.ask.rawValue;
    final autoAdvance = _bool('reader.autoAdvance', false);
    final seconds = ((_defaults.object('reader.autoSeconds') as num?)?.toDouble() ?? 10).round();
    final prefetch = _defaults.integerOrNull('reader.prefetch') ?? 3;
    final dimming = (_defaults.object('reader.dimming') as num?)?.toDouble() ?? 0;
    final continuous = mode == ReaderMode.continuous.rawValue;
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Viewer Detail Settings'),
        trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
      ),
      child: ListView(
        controller: widget.scrollController,
        padding: EdgeInsets.only(top: 76 + 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (!widget.booru) ...[
            FormSection(
              prominentHeader: true,
              header: Text(L10n.text('Reading Progress')),
              children: [
                _PickerRow<String>(
                  title: L10n.text('When Reopening a Work'),
                  options: [for (final behavior in ReaderResumeBehavior.values) (behavior.rawValue, behavior.title)],
                  selected: resume,
                  onSelected: (value) => _set('reader.resumeBehavior', value),
                ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('Page Navigation')),
            children: [
              if (!widget.booru) ...[
                _PickerRow<String>(
                  title: L10n.text('Reading Mode'),
                  options: [for (final value in ReaderMode.values) (value.rawValue, value.title)],
                  selected: mode,
                  onSelected: (value) => _set('reader.mode', value),
                ),
                if (continuous) ...[
                  _ToggleRow(
                    title: L10n.text('Swipe Right to Go Back'),
                    help: 'In Continuous Scroll, swipe right from the left edge of the safe area to return to the list. Off by default. Swiping elsewhere can still change works if that option is on.',
                    value: _bool('reader.continuousBackSwipe', false),
                    onChanged: (value) => _set('reader.continuousBackSwipe', value),
                  ),
                  _ToggleRow(
                    title: L10n.text('Swipe Left or Right to Change Works'),
                    help: 'Switches between works already loaded in the current list. Turn off to keep horizontal swipes from changing works.',
                    value: _bool('reader.continuousWorkSwipe', false),
                    onChanged: (value) => _set('reader.continuousWorkSwipe', value),
                  ),
                  _ToggleRow(
                    title: L10n.text('Swipe Up for Work Information'),
                    help: 'Swipe up from the bottom of a page to open its work information. Off by default in Continuous Scroll so you can scroll without opening a sheet.',
                    value: _bool('reader.continuousPreviewSwipe', false),
                    onChanged: (value) => _set('reader.continuousPreviewSwipe', value),
                  ),
                ],
                _PickerRow<int>(
                  title: L10n.text('Pages per View'),
                  options: [
                    for (var count = 1; count <= 4; count++) (count, L10n.text('Pages: %@', ['$count'])),
                  ],
                  selected: pagesPerSpread,
                  onSelected: (value) => _set('reader.pagesPerSpread', value),
                ),
              ],
              _ToggleRow(title: L10n.text('Read Right to Left'), value: _bool('reader.rtl', false), onChanged: (value) => _set('reader.rtl', value)),
              _ToggleRow(
                title: L10n.text('Tap the Sides to Turn Pages'),
                value: _bool('reader.tapNavigation', true),
                onChanged: (value) => _set('reader.tapNavigation', value),
              ),
              _ToggleRow(
                title: L10n.text('Double Tap to Zoom'),
                help: widget.booru
                    ? 'Turn off so quick taps on the sides never zoom in. Images then change without waiting for a second tap. Pinch still zooms.'
                    : 'Turn off so quick taps on the sides never zoom in. Pages then turn without waiting for a second tap. Pinch still zooms.',
                value: _bool(ReaderPreferences.doubleTapZoomKey, true),
                onChanged: (value) => _set(ReaderPreferences.doubleTapZoomKey, value),
              ),
            ],
          ),
          const SizedBox(height: 26),
          if (widget.booru) ...[
            FormSection(
              prominentHeader: true,
              header: Text(L10n.text('Media')),
              children: [
                _ToggleRow(
                  title: L10n.text('Show Notes on Images'),
                  value: _bool('booru.showNotes', true),
                  onChanged: (value) => _set('booru.showNotes', value),
                ),
                _ToggleRow(
                  title: L10n.text('Load Original Images'),
                  help: 'Loads the full-size file from the website. This can use more data and take longer to load.',
                  value: _bool('booru.original', false),
                  onChanged: (value) => _set('booru.original', value),
                ),
                _ToggleRow(
                  title: L10n.text('Reduce Image Data Further'),
                  help: 'Uses smaller compressed images when available. Load Original Images takes priority over this setting.',
                  value: _bool('booru.reducedData', false),
                  onChanged: _bool('booru.original', false) ? null : (value) => _set('booru.reducedData', value),
                ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          if (!widget.booru) ...[
            FormSection(
              prominentHeader: true,
              header: Text(L10n.text('Translation')),
              children: [
                _ToggleRow(
                  title: L10n.text('AI Translation (Beta)'),
                  help: 'Keeps translation on while you turn pages, and the on-device AI reads each page with the lines before it. Vertical or small text may not be recognized; turn this off to use the standard translation.',
                  value: _bool(ReaderPreferences.continuousTranslationKey, false),
                  onChanged: (value) => _set(ReaderPreferences.continuousTranslationKey, value),
                ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('Display')),
            children: [
              _ToggleRow(
                title: L10n.text('Show Quick Menu at Bottom'),
                help: 'Keeps the viewer’s quick actions visible along the bottom of the screen.',
                value: _bool('reader.bottomMenu', false),
                onChanged: (value) => _set('reader.bottomMenu', value),
              ),
              _ToggleRow(
                title: L10n.text('Show Page Number'),
                value: _bool('reader.pageNumber', false),
                onChanged: (value) => _set('reader.pageNumber', value),
              ),
              _ToggleRow(
                title: L10n.text('Keep Screen Awake While Reading'),
                value: _bool('reader.keepAwake', true),
                onChanged: (value) => _set('reader.keepAwake', value),
              ),
              FormRow(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L10n.text('Dim Screen')),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: TegnalSlider(
                        value: dimming.clamp(0, 0.65),
                        max: 0.65,
                        label: L10n.text('Dim Screen'),
                        onChanged: (value) => _set('reader.dimming', value),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('Auto Advance')),
            children: [
              _ToggleRow(
                title: L10n.text('Auto Advance'),
                help: 'Turns pages at your chosen interval. Pauses while a menu, settings, translation or zoom is open, and stops at the last page.',
                value: autoAdvance,
                onChanged: (value) => _set('reader.autoAdvance', value),
              ),
              // The native stepper keeps its look while auto advance is off; it only stops responding.
              FormRow(
                child: Row(
                  children: [
                    Expanded(child: Text(L10n.text('Advance every %@ seconds', ['$seconds']))),
                    _Stepper(
                      decrement: autoAdvance && seconds > 2 ? () => _set('reader.autoSeconds', (seconds - 1).toDouble()) : null,
                      increment: autoAdvance && seconds < 120 ? () => _set('reader.autoSeconds', (seconds + 1).toDouble()) : null,
                      dimsDisabled: autoAdvance,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          if (!widget.booru) ...[
            FormSection(
              prominentHeader: true,
              header: Text(L10n.text('Loading Options')),
              children: [
                _PickerRow<int>(
                  title: L10n.text('Prefetch Pages'),
                  help: 'Loads upcoming pages in advance so they open faster. Uses extra data and keeps the images in memory only.',
                  options: [(0, L10n.text('Off')), (2, L10n.text('2 Pages')), (3, L10n.text('3 Pages')), (5, L10n.text('5 Pages'))],
                  selected: prefetch,
                  onSelected: (value) => _set('reader.prefetch', value),
                ),
              ],
            ),
            const SizedBox(height: 26),
          ],
          FormSection(
            prominentHeader: true,
            header: Text(L10n.text('Gesture Guide')),
            children: [
              FormRow(
                child: Row(
                  children: [
                    Flexible(child: Text(L10n.text('Viewer Gestures'))),
                    const SizedBox(width: 4),
                    FormHelpButton(
                      title: L10n.text('Viewer Gestures'),
                      message: L10n.text(
                        widget.booru
                            ? 'Tap the center for the quick menu, hold to save, and tap the sides or swipe to change images. Double tap or pinch to zoom. Swipe up from the bottom for details, or swipe down at original zoom to close. For videos, tap with two fingers to open the quick menu.'
                            : 'Tap the center for the quick menu, hold to save, and double tap or pinch to zoom. Open Work Information from the quick menu or swipe up from the bottom. In Continuous Scroll, enable that gesture above; drag down from the top handle to close.',
                      ),
                    ),
                  ],
                ),
              ),
              FormRow(
                onTap: _showGuide,
                child: Text(L10n.text('Reader Guide'), style: TegnalType.style(17, color: TegnalColors.tint.resolveFrom(context))),
              ),
            ],
          ),
          const SizedBox(height: 26),
          FormSection(
            children: [
              FormRow(
                onTap: _confirmReset,
                child: Text(L10n.text('Reset Settings to Defaults'), style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showGuide() {
    if (widget.onShowGuide case final show?) {
      show();
      return;
    }
    _set(ReaderSettingKeys.helpHidden, false);
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Reader Guide')),
        content: Text(L10n.text('The guide will appear over the next work you open.')),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
      ),
    );
  }

  Future<void> _confirmReset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Reset Settings to Defaults?')),
        message: Text(L10n.text('Resets this mode’s viewer options. Saved works and reading progress are kept.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Reset')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset != true) return;
    setState(() => ReaderPreferenceReset.reset(booru: widget.booru, defaults: _defaults));
    widget.onChanged?.call();
  }
}

/// A form row whose trailing value opens a pull-down menu (`Picker` with the menu style).
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({required this.title, required this.options, required this.selected, required this.onSelected, this.help});
  final String title;
  final String? help;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final current = options.where((option) => option.$1 == selected).firstOrNull?.$2 ?? '';
    return Builder(
      builder: (context) => FormRow(
        onTap: () async {
          final value = await showPullDownMenu<T>(
            context,
            anchor: anchorRectOf(context),
            items: [for (final (value, label) in options) PullDownMenuItem(value: value, title: label, checked: value == selected)],
          );
          if (value != null) onSelected(value);
        },
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(child: Text(title)),
                  if (help != null) ...[const SizedBox(width: 4), FormHelpButton(title: title, message: L10n.text(help!))],
                ],
              ),
            ),
            Text(current, style: TegnalType.style(17, color: secondary)),
            const SizedBox(width: 4),
            Icon(CupertinoIcons.chevron_up_chevron_down, size: 15, color: secondary),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({required this.title, required this.value, required this.onChanged, this.help});
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) => FormRow(
    child: Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(child: Text(title)),
              if (help != null) ...[const SizedBox(width: 4), FormHelpButton(title: title, message: L10n.text(help!))],
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Native switches sit 2 pt closer to the row's trailing edge than text does.
        Transform.translate(
          offset: const Offset(2, 0),
          child: TegnalSwitch(value: value, onChanged: onChanged),
        ),
      ],
    ),
  );
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.decrement, required this.increment, this.dimsDisabled = true});
  final VoidCallback? decrement;
  final VoidCallback? increment;
  final bool dimsDisabled;

  static const background = CupertinoDynamicColor.withBrightness(color: Color(0xFFEEEEEF), darkColor: Color(0xFF3B3B3D));

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    // Bold strokes like the native stepper's minus and plus glyphs.
    Widget bar({bool vertical = false}) => Container(
      width: vertical ? 2.4 : 13,
      height: vertical ? 13 : 2.4,
      decoration: ShapeDecoration(color: label, shape: const StadiumBorder()),
    );
    Widget half(Widget glyph, VoidCallback? onTap) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: SizedBox(
        width: 46,
        height: 32,
        child: Opacity(
          opacity: onTap == null && dimsDisabled ? 0.3 : 1,
          child: Center(child: glyph),
        ),
      ),
    );
    // Assistive technologies adjust it as one control, as they do the native stepper.
    return Semantics(
      onIncrease: increment,
      onDecrease: decrement,
      child: ExcludeSemantics(
        child: Container(
          decoration: ShapeDecoration(color: background.resolveFrom(context), shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              half(bar(), decrement),
              Container(width: 0.7, height: 24, color: TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.5)),
              half(Stack(alignment: Alignment.center, children: [bar(), bar(vertical: true)]), increment),
            ],
          ),
        ),
      ),
    );
  }
}
