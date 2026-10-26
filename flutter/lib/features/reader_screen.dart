import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../data/download_manager.dart';
import '../data/booru_extras.dart';
import '../data/session_client.dart';
import '../ui/reader_image_provider.dart';
import '../ui/l10n.dart';
import '../ui/design_system.dart';
import '../ui/common.dart';
import '../ui/session_image.dart';
import 'reader_notes.dart';

class _ReaderManifest {
  const _ReaderManifest({
    required this.item,
    required this.pages,
    required this.offline,
  });
  final ContentItem item;
  final List<ReaderPage> pages;
  final bool offline;
}

int _readerDecodeLimit(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final scale = MediaQuery.devicePixelRatioOf(context);
  return (size.longestSide * scale * 2).ceil().clamp(1024, 3000);
}

/// A reader owns only its viewing session. Reading position and preferences are
/// persisted by the controller; completed downloads are always preferred.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.controller,
    required this.item,
    required this.downloads,
    this.initialPageIndex,
    this.sequence = const [],
    this.onSearch,
  });
  final AppController controller;
  final ContentItem item;
  final DownloadManager downloads;
  final int? initialPageIndex;
  final List<ContentItem> sequence;
  final ValueChanged<String>? onSearch;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

/// Mirrors the native reader's downward exit threshold without taking part in
/// Flutter's gesture arena (which also owns page swipes, scrolling and pinch).
class ReaderExitGesturePolicy {
  const ReaderExitGesturePolicy._();

  static bool startsInContinuousExitZone(double y, double safeTop) =>
      y >= safeTop && y <= safeTop + 64;

  static bool shouldExit(Offset delta, double velocityY) =>
      delta.dy > delta.dx.abs() * 1.25 &&
      (delta.dy >= 96 || (delta.dy >= 24 && velocityY >= 550));

  static bool shouldAdvancePost(Offset delta) =>
      delta.dx.abs() >= 50 && delta.dx.abs() > delta.dy.abs() * 1.3;
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  late ReaderPreferences _prefs;
  late final List<ContentItem> _sequence;
  int _postIndex = 0;
  ContentItem get _item => _sequence[_postIndex];
  bool get _postSequence => _item.mode == AppMode.booru && _sequence.length > 1;
  int get _position => _postSequence ? _postIndex : _index;
  int get _count => _postSequence ? _sequence.length : _pages.length;
  late ContentItem _resolvedItem;
  List<ReaderPage> _sourcePages = [];
  List<BooruNote> _notes = [];
  BooruExtras? _notesClient;
  bool _showNotes = false;
  PageController? _pager;
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final Map<int, double> _ratios = {};
  final Map<String, _ReaderManifest> _manifestCache = {};
  final Map<String, Future<_ReaderManifest>> _manifestFlights = {};
  Timer? _auto;
  int _index = 0;
  int _generation = 0;
  int _prefetchGeneration = 0;
  int _prefetchManifestCount = 0;
  int _prefetchImageCount = 0;
  bool _loading = true;
  bool _offline = false;
  bool _chrome = false;
  bool _downloading = false;
  bool _zoomed = false;
  bool _settingsOpen = false;
  bool _active = true;
  bool? _previousAwake;
  String? _error;
  Size _viewport = Size.zero;
  final Set<int> _activePointers = {};
  int? _exitPointer;
  Offset? _exitStart;
  Offset? _exitLast;
  Duration? _exitLastTime;
  double _exitVelocityY = 0;

  String _t(String key) => L10n.tr(context, key);
  bool get _video => _resolvedItem.mediaType == 'video';
  bool get _continuous =>
      _item.mode == AppMode.manga &&
      _prefs.readingMode == ReadingMode.continuous;
  List<ReaderPage> get _pages {
    final original = Uri.tryParse(
      _resolvedItem.metadata['fileURL'] as String? ?? '',
    );
    if (!_offline &&
        _prefs.originalImages &&
        _sourcePages.length == 1 &&
        original?.scheme == 'https' &&
        original!.userInfo.isEmpty &&
        original.host.isNotEmpty) {
      final page = _sourcePages.single;
      return [
        ReaderPage(
          url: original,
          thumbnailUrl: page.thumbnailUrl,
          width: page.width,
          height: page.height,
          headers: page.headers,
        ),
      ];
    }
    return _sourcePages;
  }

  @override
  void initState() {
    super.initState();
    final seen = <String>{};
    _sequence = widget.item.mode == AppMode.booru
        ? [
            for (final item in [widget.item, ...widget.sequence])
              if (item.mode == AppMode.booru && seen.add(item.key)) item,
          ]
        : [widget.item];
    if (widget.sequence.isNotEmpty && widget.item.mode == AppMode.booru) {
      // Preserve the caller's filtered/sorted order, including items before it.
      _sequence.sort((a, b) {
        final ai = widget.sequence.indexWhere((entry) => entry.key == a.key);
        final bi = widget.sequence.indexWhere((entry) => entry.key == b.key);
        return ai.compareTo(bi);
      });
    }
    _postIndex = _sequence.indexWhere((item) => item.key == widget.item.key);
    _resolvedItem = _item;
    _prefs = widget.controller.readerPreferences(_item.mode);
    _showNotes = _prefs.showNotes;
    _index =
        widget.initialPageIndex ?? widget.controller.readingPosition(_item);
    _scroll.addListener(_scrolled);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_captureAwake());
    unawaited(_load());
  }

  Future<void> _captureAwake() async {
    try {
      final previous = await WakelockPlus.enabled;
      if (!mounted) return;
      _previousAwake = previous;
      await _applyAwake();
    } on Exception {
      // Platforms without an idle timer still retain the viewing preference.
    }
  }

  Future<void> _applyAwake() async {
    try {
      await WakelockPlus.toggle(enable: _active && _prefs.keepAwake);
    } on Exception {
      // No wakelock implementation is available on some desktop targets.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) _prefetchGeneration++;
    if (_active && _sourcePages.isNotEmpty) _scheduleAdjacentPrefetch();
    if (_previousAwake != null) unawaited(_applyAwake());
    _configureAuto();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final requestedItem = _item;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final manifest = await _loadManifest(requestedItem);
      _rememberManifest(requestedItem.key, manifest);
      final offline = manifest.offline ? manifest.pages : null;
      final resolved = manifest.item;
      final pages = manifest.pages;
      if (pages.isEmpty) {
        throw const ContentException('This work has no readable pages.');
      }
      if (!mounted || generation != _generation) return;
      _resolvedItem = resolved;
      _sourcePages = pages;
      _offline = offline != null;
      _index = _index.clamp(0, pages.length - 1);
      _replacePager();
      setState(() {
        _loading = false;
      });
      _savePosition();
      _configureAuto();
      _scheduleAdjacentPrefetch();
      unawaited(_loadNotes(generation));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _continuous) {
          _go(_position, animate: false);
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = AppController.errorMessage(error);
        });
      }
    }
  }

  Future<_ReaderManifest> _resolveManifest(ContentItem requestedItem) async {
    final offline = await widget.downloads.offlinePages(requestedItem);
    if (offline != null) {
      return _ReaderManifest(
        item: requestedItem,
        pages: offline,
        offline: true,
      );
    }
    var resolved = requestedItem;
    if (requestedItem.mode == AppMode.booru && requestedItem.mediaUrl == null) {
      resolved = await widget.controller.detail(requestedItem);
    }
    final pages = await widget.controller.pages(resolved);
    return _ReaderManifest(item: resolved, pages: pages, offline: false);
  }

  Future<_ReaderManifest> _loadManifest(
    ContentItem item, {
    int? prefetchToken,
  }) {
    final cached = _manifestCache.remove(item.key);
    if (cached != null) {
      if (prefetchToken == null ||
          (_active && prefetchToken == _prefetchGeneration)) {
        _rememberManifest(item.key, cached);
      }
      return Future.value(cached);
    }
    final existing = _manifestFlights[item.key];
    if (existing != null) return existing;
    final future = _resolveManifest(item);
    _manifestFlights[item.key] = future;
    return future.then(
      (manifest) {
        _manifestFlights.remove(item.key);
        if (mounted &&
            (prefetchToken == null ||
                (_active && prefetchToken == _prefetchGeneration))) {
          _rememberManifest(item.key, manifest);
        }
        return manifest;
      },
      onError: (Object error, StackTrace stack) {
        _manifestFlights.remove(item.key);
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  void _rememberManifest(String key, _ReaderManifest manifest) {
    _manifestCache.remove(key);
    _manifestCache[key] = manifest;
    while (_manifestCache.length > 4) {
      _manifestCache.remove(_manifestCache.keys.first);
    }
  }

  bool _isVideo(ContentItem item, List<ReaderPage> pages) {
    if (item.mediaType == 'video') return true;
    return pages.any(
      (page) => const {'mp4', 'm4v', 'mov', 'webm', 'mkv', 'avi'}.contains(
        page.url.pathSegments.isEmpty
            ? ''
            : page.url.pathSegments.last.split('.').last.toLowerCase(),
      ),
    );
  }

  void _scheduleAdjacentPrefetch() {
    final token = ++_prefetchGeneration;
    if (!_active || _offline || _pages.isEmpty || _video) return;
    final jobs = <Future<void>>[];
    if (_postSequence) {
      for (final index in [_postIndex - 1, _postIndex + 1, _postIndex + 2]) {
        if (index >= 0 && index < _sequence.length) {
          jobs.add(_prefetchManifest(_sequence[index], token));
        }
      }
    } else {
      final indices = <int>[
        if (_index > 0) _index - 1,
        _index + 1,
        _index + 2,
      ].where((index) => index >= 0 && index < _pages.length);
      for (final index in indices) {
        jobs.add(_prefetchPage(_pages[index], token));
      }
    }
    // Only the immediate neighborhood is considered and at most three loads
    // are started. The shared Flutter ImageCache coalesces visible/prefetch
    // requests using the same URL, headers and bounded decode dimensions.
    unawaited(Future.wait(jobs));
  }

  Future<void> _prefetchManifest(ContentItem item, int token) async {
    if (!_active ||
        token != _prefetchGeneration ||
        item.mediaType == 'video' ||
        _prefetchManifestCount >= 3) {
      return;
    }
    _prefetchManifestCount++;
    late final _ReaderManifest manifest;
    try {
      manifest = await _loadManifest(item, prefetchToken: token);
    } catch (_) {
      _prefetchManifestCount--;
      return;
    }
    _prefetchManifestCount--;
    if (!mounted || !_active || token != _prefetchGeneration) return;
    if (!manifest.offline &&
        manifest.pages.isNotEmpty &&
        !_isVideo(manifest.item, manifest.pages)) {
      await _prefetchPage(manifest.pages.first, token);
    }
  }

  Future<void> _prefetchPage(ReaderPage page, int token) async {
    if (!mounted ||
        !_active ||
        token != _prefetchGeneration ||
        _prefetchImageCount >= 3) {
      return;
    }
    _prefetchImageCount++;
    try {
      final ephemeral = await BrowserSession.headersFor(page.url);
      if (!mounted || !_active || token != _prefetchGeneration) return;
      final provider = readerImageProvider(page, {
        ...page.headers,
        ...ephemeral,
      }, _readerDecodeLimit(context));
      await precacheImage(provider, context, onError: (_, _) {});
    } catch (_) {
      // The visible page owns error presentation; speculation is best-effort.
    } finally {
      _prefetchImageCount--;
    }
  }

  Future<void> _loadNotes(int generation) async {
    final source = widget.controller.sourceById(_item.sourceId);
    if (_offline || _video || source == null || _item.mode != AppMode.booru) {
      return;
    }
    _notesClient?.close();
    final extras = BooruExtras(source);
    if (!extras.supported) {
      extras.close();
      return;
    }
    _notesClient = extras;
    try {
      final notes = await extras.notes(_item.id);
      if (mounted && generation == _generation) {
        setState(() {
          _notes = notes;
        });
      }
    } on ContentException {
      // Notes are optional: access failures must not block available media.
    } finally {
      extras.close();
      if (identical(_notesClient, extras)) _notesClient = null;
    }
  }

  void _replacePager() {
    final old = _pager;
    _pager = PageController(initialPage: _index);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  void _savePosition() {
    if (_item.mode == AppMode.manga) {
      widget.controller.saveReadingPosition(_item, _index);
    }
  }

  void _switchPost(int value) {
    final next = value.clamp(0, _sequence.length - 1);
    if (next == _postIndex) return;
    _auto?.cancel();
    _prefetchGeneration++;
    _notesClient?.close();
    setState(() {
      _postIndex = next;
      _resolvedItem = _item;
      _index = 0;
      _zoomed = false;
      _notes = [];
      _sourcePages = [];
      _ratios.clear();
    });
    unawaited(_load());
  }

  void _setIndex(int value) {
    if (value == _index) return;
    setState(() {
      _index = value;
      _zoomed = false;
    });
    _savePosition();
    _scheduleAdjacentPrefetch();
  }

  double _extent(int index) {
    final page = _sourcePages[index];
    final ratio =
        _ratios[index] ??
        (page.width > 0 && page.height > 0 ? page.width / page.height : 0);
    return ratio > 0
        ? _viewport.width / ratio
        : _viewport.height.clamp(200, double.infinity);
  }

  double _offset(int index) {
    double offset = 0;
    for (var i = 0; i < index; i++) {
      offset += _extent(i);
    }
    return offset;
  }

  void _scrolled() {
    if (!_continuous || !_scroll.hasClients || _sourcePages.isEmpty) {
      return;
    }
    final position = _scroll.offset + _viewport.height * .25;
    double offset = 0;
    var index = 0;
    while (index < _sourcePages.length - 1 &&
        offset + _extent(index) <= position) {
      offset += _extent(index++);
    }
    _setIndex(index);
  }

  void _go(int value, {bool animate = true}) {
    if (_postSequence) {
      _switchPost(value);
      return;
    }
    if (_sourcePages.isEmpty) return;
    final target = value.clamp(0, _sourcePages.length - 1);
    _setIndex(target);
    if (_continuous) {
      if (_scroll.hasClients) {
        final offset = _offset(target)
            .clamp(0.0, _scroll.position.maxScrollExtent);
        if (animate) {
          unawaited(
            _scroll.animateTo(
              offset,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOut,
            ),
          );
        } else {
          _scroll.jumpTo(offset);
        }
      }
    } else if (_pager?.hasClients == true) {
      if (animate) {
        unawaited(
          _pager!.animateToPage(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      } else {
        _pager!.jumpToPage(target);
      }
    }
  }

  void _configureAuto() {
    _auto?.cancel();
    if (!_prefs.autoAdvance || !_active || _video || _count < 2) {
      return;
    }
    _auto = Timer.periodic(
      Duration(seconds: _prefs.autoSeconds.clamp(2, 120)),
      (_) {
        if (!mounted ||
            _chrome ||
            _settingsOpen ||
            _zoomed ||
            _loading ||
            _error != null) {
          return;
        }
        if (_position + 1 >= _count) {
          _updatePreferences(_prefs.copyWith(autoAdvance: false));
        } else {
          _go(_position + 1);
        }
      },
    );
  }

  void _updatePreferences(ReaderPreferences value) {
    final changedLayout =
        value.readingMode != _prefs.readingMode ||
        value.rightToLeft != _prefs.rightToLeft;
    setState(() {
      _prefs = value;
      _showNotes = value.showNotes;
      if (changedLayout) {
        _zoomed = false;
        _replacePager();
      }
    });
    widget.controller.setReaderPreferences(_item.mode, value);
    if (_previousAwake != null) unawaited(_applyAwake());
    _configureAuto();
    if (changedLayout) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _go(_position, animate: false);
      });
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _settingsOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final reverse =
        _prefs.rightToLeft && _prefs.readingMode == ReadingMode.horizontal;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft) {
      final delta = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      _go(_position + (reverse ? -delta : delta));
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      _go(_position + 1);
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      _go(_position - 1);
    } else if (key == LogicalKeyboardKey.home) {
      _go(0);
    } else if (key == LogicalKeyboardKey.end) {
      _go(_count - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      if (_chrome) {
        setState(() => _chrome = false);
      } else {
        Navigator.of(context).maybePop();
      }
    } else if (key == LogicalKeyboardKey.space && !_video) {
      setState(() {
        _chrome = !_chrome;
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _tap(TapUpDetails details) {
    if (_zoomed || _video) return;
    if (_prefs.tapNavigation && _count > 1 && !_continuous) {
      final fraction = details.localPosition.dx / _viewport.width;
      final reverse =
          _prefs.rightToLeft && _prefs.readingMode == ReadingMode.horizontal;
      if (fraction < .3) {
        _go(_position + (reverse ? 1 : -1));
        return;
      }
      if (fraction > .7) {
        _go(_position + (reverse ? -1 : 1));
        return;
      }
    }
    setState(() {
      _chrome = !_chrome;
    });
  }

  bool get _exitGestureEnabled =>
      !_zoomed && !_chrome && !_settingsOpen && !_loading && _error == null;

  void _pointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length != 1 || !_exitGestureEnabled) {
      _clearExitPointer();
      return;
    }
    final safeTop = MediaQuery.paddingOf(context).top;
    if (_continuous &&
        !ReaderExitGesturePolicy.startsInContinuousExitZone(
          event.localPosition.dy,
          safeTop,
        )) {
      _clearExitPointer();
      return;
    }
    _exitPointer = event.pointer;
    _exitStart = event.localPosition;
    _exitLast = event.localPosition;
    _exitLastTime = event.timeStamp;
    _exitVelocityY = 0;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (_exitPointer != event.pointer || !_exitGestureEnabled) return;
    final previous = _exitLast;
    final previousTime = _exitLastTime;
    if (previous != null && previousTime != null) {
      final elapsed = event.timeStamp - previousTime;
      if (elapsed.inMicroseconds > 0) {
        _exitVelocityY =
            (event.localPosition.dy - previous.dy) *
            Duration.microsecondsPerSecond /
            elapsed.inMicroseconds;
      }
    }
    _exitLast = event.localPosition;
    _exitLastTime = event.timeStamp;
  }

  void _pointerUp(PointerEvent event) {
    if (_exitPointer == event.pointer && _exitStart != null) {
      final delta = event.localPosition - _exitStart!;
      if (_exitGestureEnabled &&
          ReaderExitGesturePolicy.shouldExit(delta, _exitVelocityY)) {
        _clearExitPointer();
        Navigator.of(context).maybePop();
      } else if (_exitGestureEnabled &&
          _postSequence &&
          !_zoomed &&
          ReaderExitGesturePolicy.shouldAdvancePost(delta)) {
        _clearExitPointer();
        final direction = delta.dx < 0 ? 1 : -1;
        _go(_position + (_prefs.rightToLeft ? -direction : direction));
      } else {
        _clearExitPointer();
      }
    } else if (_exitPointer == event.pointer) {
      _clearExitPointer();
    }
    _activePointers.remove(event.pointer);
  }

  void _pointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _clearExitPointer();
  }

  void _clearExitPointer() {
    _exitPointer = null;
    _exitStart = null;
    _exitLast = null;
    _exitLastTime = null;
    _exitVelocityY = 0;
  }

  void _toggleBookmark() {
    final removing = widget.controller.isSaved(_item);
    if (removing) {
      widget.controller.unsave(_item);
    } else {
      widget.controller.save(_resolvedItem);
    }
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(_t(removing ? 'Remove from Saved' : 'Saved')),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _settings() async {
    _settingsOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          void update(ReaderPreferences value) {
            _updatePreferences(value);
            refresh(() {});
          }

          Widget toggle(
            String label,
            bool value,
            ValueChanged<bool> onChanged,
          ) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                Expanded(child: Text(_t(label))),
                TegnalSwitch(
                  semanticLabel: _t(label),
                  value: value,
                  onChanged: onChanged,
                ),
              ],
            ),
          );
          return Theme(
            data: tegnalTheme(Brightness.dark),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: 640,
                maxHeight: MediaQuery.sizeOf(context).height * .85,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF1C1C1E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.bodyLarge!
                        .copyWith(color: Colors.white, fontSize: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _t('Reader settings'),
                                style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Text(_t('Done')),
                            ),
                          ],
                        ),
                        if (!_video && _item.mode == AppMode.manga) ...[
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SegmentedButton<ReadingMode>(
                              segments: [
                                ButtonSegment<ReadingMode>(
                                  value: ReadingMode.horizontal,
                                  label: Text(_t('Horizontal')),
                                ),
                                ButtonSegment<ReadingMode>(
                                  value: ReadingMode.vertical,
                                  label: Text(_t('Vertical')),
                                ),
                                ButtonSegment<ReadingMode>(
                                  value: ReadingMode.continuous,
                                  label: Text(_t('Continuous')),
                                ),
                              ],
                              selected: {_prefs.readingMode},
                              showSelectedIcon: false,
                              onSelectionChanged: (selection) {
                                update(
                                  _prefs.copyWith(readingMode: selection.first),
                                );
                              },
                            ),
                          ),
                          toggle(
                            'Right to left',
                            _prefs.rightToLeft,
                            (value) =>
                                update(_prefs.copyWith(rightToLeft: value)),
                          ),
                          toggle(
                            'Tap to turn pages',
                            _prefs.tapNavigation,
                            (value) =>
                                update(_prefs.copyWith(tapNavigation: value)),
                          ),
                          toggle(
                            'Show page number',
                            _prefs.showPageNumber,
                            (value) =>
                                update(_prefs.copyWith(showPageNumber: value)),
                          ),
                          toggle(
                            'Auto advance',
                            _prefs.autoAdvance,
                            (value) =>
                                update(_prefs.copyWith(autoAdvance: value)),
                          ),
                          if (_prefs.autoAdvance) ...[
                            Text(
                              '${_t('Seconds per page')}: ${_prefs.autoSeconds}',
                            ),
                            Slider(
                              value: _prefs.autoSeconds.toDouble(),
                              min: 2,
                              max: 120,
                              divisions: 118,
                              onChanged: (value) => update(
                                _prefs.copyWith(autoSeconds: value.round()),
                              ),
                            ),
                          ],
                        ],
                        if (_item.mode == AppMode.booru &&
                            !_offline &&
                            _resolvedItem.metadata['fileURL'] != null)
                          toggle(
                            'Original images',
                            _prefs.originalImages,
                            (value) =>
                                update(_prefs.copyWith(originalImages: value)),
                          ),
                        toggle(
                          'Keep screen awake',
                          _prefs.keepAwake,
                          (value) => update(_prefs.copyWith(keepAwake: value)),
                        ),
                        Text(_t('Dim screen')),
                        Slider(
                          value: _prefs.dimming,
                          min: 0,
                          max: .65,
                          onChanged: (value) =>
                              update(_prefs.copyWith(dimming: value)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    _settingsOpen = false;
    if (mounted) _focus.requestFocus();
  }

  Widget _button(IconData icon, String label, VoidCallback action) => Semantics(
    label: _t(label),
    button: true,
    child: IconButton(
      onPressed: action,
      tooltip: _t(label),
      icon: Icon(icon, color: Colors.white, size: 28),
    ),
  );

  Future<void> _download() async {
    if (_downloading || _sourcePages.isEmpty) return;
    final downloadedItem = _resolvedItem;
    final downloadedPages = List<ReaderPage>.of(_sourcePages);
    setState(() => _downloading = true);
    try {
      await widget.downloads.enqueue(downloadedItem, downloadedPages);
      widget.controller.save(downloadedItem);
      if (mounted) {
        await showMessage(
          context,
          'Download Added',
          'Keep the app open while downloading. Interrupted downloads can be resumed.',
        );
      }
    } catch (error) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Download',
          AppController.errorMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _folders() async {
    final folders = widget.controller.folders(_item.mode);
    final selected =
        widget.controller.saved(_item)?.folderIds.toSet() ?? <String>{};
    _settingsOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: DefaultTextStyle(
                    style: Theme.of(context).textTheme.titleLarge!,
                    child: Text(_t('Folders')),
                  ),
                ),

                for (final folder in folders)
                  CheckboxListTile(
                    value: selected.contains(folder.id),
                    activeColor: Color(folder.color),
                    title: Text(folder.name),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (_) {
                      refresh(() {
                        final wasSelected = selected.contains(folder.id);
                        if (_item.mode == AppMode.booru) {
                          selected.clear();
                        }
                        wasSelected
                            ? selected.remove(folder.id)
                            : selected.add(folder.id);
                      });
                      widget.controller.save(
                        _resolvedItem,
                        folderIds: selected.toList(),
                      );
                    },
                  ),
                if (folders.isEmpty)
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(_t('Create a folder in your library first.')),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: Text(_t('Done')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _settingsOpen = false;
  }

  Future<void> _note() async {
    _settingsOpen = true;
    final text = TextEditingController(
      text: widget.controller.saved(_item)?.note ?? '',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(_t('Notes')),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: text,
            minLines: 4,
            maxLines: 8,
            autofocus: true,
            decoration: InputDecoration(hintText: _t('Notes')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, text.text),
            child: Text(_t('Save')),
          ),
        ],
      ),
    );
    if (result != null) widget.controller.save(_resolvedItem, note: result);
    // The dialog route may still animate out while its field is mounted.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
    _settingsOpen = false;
  }

  Future<void> _tagActions(String tag, {bool artist = false}) async {
    final item = _resolvedItem;
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tag)),
            if (widget.onSearch != null)
              ListTile(
                leading: const Icon(Icons.search),
                title: Text(_t('Search')),
                onTap: () => Navigator.pop(sheetContext, 'search'),
              ),
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: Text(_t(artist ? 'Save Artist' : 'Save Tag')),
              onTap: () => Navigator.pop(sheetContext, 'save'),
            ),
            if (item.mode == AppMode.booru)
              ListTile(
                leading: const Icon(Icons.block),
                title: Text(_t('Add to Blacklist')),
                onTap: () => Navigator.pop(sheetContext, 'block'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'search') {
      widget.onSearch!(
        artist && item.mode == AppMode.manga ? 'artist:$tag' : tag,
      );
    } else if (action == 'save') {
      widget.controller.store.saveArtist(
        ArtistEntry(
          name: tag,
          mode: item.mode,
          sourceId: item.sourceId,
          kind: artist ? 0 : 1,
        ),
      );
      widget.controller.changed();
    } else if (action == 'block') {
      final key = 'blacklist.${item.sourceId}';
      final existing = widget.controller.store.setting(key, '') as String;
      final rules =
          existing.split('\n').where((line) => line.trim().isNotEmpty).toSet()
            ..add(tag);
      widget.controller.setPreference(key, rules.join('\n'));
    }
  }

  Future<void> _info() async {
    _settingsOpen = true;
    final item = _resolvedItem;
    final source = widget.controller.sourceById(item.sourceId);
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .8,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              _t(item.mode == AppMode.manga ? 'Work Details' : 'Details'),
            ),
            actions: [
              IconButton(
                tooltip: _t('Close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SelectableText(
                item.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              ListTile(
                title: Text('#${item.id}'),
                subtitle: Text(source?.name ?? ''),
                trailing: const Icon(Icons.copy),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: '${item.id}'));
                },
              ),
              Text(
                '${item.width} × ${item.height} · ${item.mediaType} · ${_pages.length} P',
              ),
              const SizedBox(height: 16),
              if (item.pageUrl != null)
                ListTile(
                  leading: const Icon(Icons.open_in_browser),
                  title: Text(_t('Open in Browser')),
                  onTap: () => unawaited(_openWebsite()),
                ),
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(_t('Copy Link')),
                onTap: () => unawaited(_copyLink()),
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: Text(_t('Notes')),
                onTap: () => Navigator.pop(sheetContext, 'note'),
              ),
              const SizedBox(height: 12),
              for (final artist in item.artists)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(artist),
                  onTap: widget.onSearch == null
                      ? null
                      : () => _tagActions(artist, artist: true),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in item.tags)
                    ActionChip(
                      label: Text(tag),
                      onPressed: () => _tagActions(tag),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    _settingsOpen = false;
    if (action == 'note') await _note();
  }

  Future<void> _preview() async {
    _settingsOpen = true;
    final selected = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: .8,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_t('Preview')),
            actions: [
              IconButton(
                tooltip: _t('Close'),
                onPressed: () => Navigator.pop(sheetContext),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: GridView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _pages.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              childAspectRatio: .7,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemBuilder: (_, index) => InkWell(
              onTap: () => Navigator.pop(sheetContext, index),
              child: Column(
                children: [
                  Expanded(
                    child: ReaderPageThumbnail(
                      page: _pages[index],
                      referer: _resolvedItem.pageUrl,
                      fit: BoxFit.contain,
                    ),
                  ),
                  Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: index == _index
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _settingsOpen = false;
    if (selected != null) {
      _go(selected, animate: false);
      setState(() => _chrome = false);
    }
  }

  Future<void> _jump() async {
    _settingsOpen = true;
    final input = TextEditingController(text: '${_position + 1}');
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_t('Go to Page')),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: '1–$_count'),
          onSubmitted: (text) {
            final page = int.tryParse(text);
            if (page != null && page >= 1 && page <= _count) {
              Navigator.pop(dialogContext, page - 1);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(_t('Cancel')),
          ),
          TextButton(
            onPressed: () {
              final page = int.tryParse(input.text);
              if (page != null && page >= 1 && page <= _count) {
                Navigator.pop(dialogContext, page - 1);
              }
            },
            child: Text(_t('Go')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (!mounted) return;
    _settingsOpen = false;
    if (selected != null) _go(selected, animate: false);
  }

  Future<void> _copyLink() async {
    final url = _resolvedItem.pageUrl ?? _pages.firstOrNull?.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (mounted) await showMessage(context, 'Copy Link', 'Copied');
  }

  Future<void> _openWebsite() async {
    final url = _resolvedItem.pageUrl;
    if (url != null &&
        !await launchUrl(url, mode: LaunchMode.externalApplication) &&
        mounted) {
      await showMessage(context, 'Unable to Open', 'No browser is available.');
    }
  }

  Widget _topBar() => SafeArea(
    bottom: false,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF252527),
              borderRadius: BorderRadius.circular(24),
            ),
            child: _button(
              Icons.keyboard_arrow_down,
              'Close',
              () => Navigator.of(context).maybePop(),
            ),
          ),
          const Spacer(),
          if (_video)
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF252527),
                borderRadius: BorderRadius.circular(24),
              ),
              child: _button(
                Icons.more_horiz,
                'Reader settings',
                () => setState(() => _chrome = !_chrome),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _action(IconData icon, String label, VoidCallback? action) => Expanded(
    child: Semantics(
      button: true,
      label: _t(label),
      child: TextButton(
        onPressed: action,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 28,
              color: action == null ? Colors.grey : Colors.white,
            ),
            const SizedBox(height: 8),
            Text(
              _t(label),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.15,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _controls() => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 460,
        maxHeight:
            MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            32,
      ),
      child: SingleChildScrollView(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: ChromeSurface(
            enabled: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: const Color(0xF2232325),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: const Color(0xFF3A3A3C), width: .5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _button(
                        Icons.chevron_left,
                        'Previous page',
                        () => _go(_position - 1),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: _jump,
                          child: Text(
                            '${_position + 1} / $_count',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ),
                      _button(
                        Icons.chevron_right,
                        'Next page',
                        () => _go(_position + 1),
                      ),
                      _button(
                        Icons.cancel,
                        'Close controls',
                        () => setState(() => _chrome = false),
                      ),
                    ],
                  ),
                  ListenableBuilder(
                    listenable: widget.controller,
                    builder: (_, _) => Row(
                      children: [
                        _action(
                          Icons.download,
                          'Download work',
                          _downloading || _loading || _offline
                              ? null
                              : () => unawaited(_download()),
                        ),
                        _action(
                          widget.controller.isSaved(_item)
                              ? Icons.favorite
                              : Icons.favorite_border,
                          widget.controller.isSaved(_item)
                              ? 'Remove from library'
                              : 'Save to library',
                          () {
                            widget.controller.isSaved(_item)
                                ? widget.controller.unsave(_item)
                                : widget.controller.save(_resolvedItem);
                          },
                        ),
                        _action(
                          Icons.folder_outlined,
                          'Save to folder',
                          () => unawaited(_folders()),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      _action(
                        Icons.translate,
                        'Translate',
                        _video
                            ? null
                            : () => unawaited(
                                showMessage(
                                  context,
                                  'On-Device AI',
                                  'No supported preinstalled system translation service is connected.',
                                ),
                              ),
                      ),
                      _action(
                        Icons.logout,
                        'Exit',
                        () => Navigator.of(context).pop(),
                      ),
                      _action(
                        Icons.edit_note,
                        'Notes',
                        _item.mode == AppMode.booru
                            ? () => _updatePreferences(
                                _prefs.copyWith(showNotes: !_showNotes),
                              )
                            : () => unawaited(_note()),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      _action(
                        Icons.info_outline,
                        _item.mode == AppMode.manga
                            ? 'Work Details'
                            : 'Details',
                        () => unawaited(_info()),
                      ),
                      _action(
                        _item.mode == AppMode.manga
                            ? Icons.grid_view
                            : Icons.link,
                        _item.mode == AppMode.manga ? 'Preview' : 'Copy Link',
                        () => unawaited(
                          _item.mode == AppMode.manga
                              ? _preview()
                              : _copyLink(),
                        ),
                      ),
                      _action(
                        Icons.tune,
                        'Reader settings',
                        () => unawaited(_settings()),
                      ),
                    ],
                  ),
                  if (!_video && _pages.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Slider(
                        value: _index.toDouble(),
                        min: 0,
                        max: (_pages.length - 1).toDouble(),
                        divisions: _pages.length - 1,
                        onChanged: (v) => _go(v.round(), animate: false),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _image(int index, {bool continuous = false}) => _ReaderImage(
    key: ValueKey('${_pages[index].url}:$index:$continuous'),
    page: _pages[index],
    continuous: continuous,
    notes: _showNotes ? _notes : const [],
    onZoom: (zoomed) {
      if (mounted && zoomed != _zoomed) {
        setState(() {
          _zoomed = zoomed;
        });
      }
    },
    onRatio: (ratio) {
      if (ratio > 0 && _ratios[index] != ratio) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _ratios[index] = ratio;
            });
          }
        });
      }
    },
  );

  Widget _body() {
    if (_loading) {
      return Center(
        child: Semantics(
          label: _t('Loading pages'),
          child: const CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 38, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              TextButton(onPressed: _load, child: Text(_t('Retry'))),
            ],
          ),
        ),
      );
    }
    if (_video) {
      return _ReaderVideo(
        key: ValueKey(_pages.single.url),
        page: _pages.single,
        keepAwake: _prefs.keepAwake,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: _tap,
      onLongPress: _toggleBookmark,
      child: _postSequence
          ? _image(0)
          : _continuous
          ? ListView.builder(
              controller: _scroll,
              itemCount: _pages.length,
              itemExtentBuilder: (index, dimensions) => _extent(index),
              itemBuilder: (context, index) => _image(index, continuous: true),
            )
          : PageView.builder(
              key: ValueKey('${_prefs.readingMode}:${_prefs.rightToLeft}'),
              controller: _pager,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              scrollDirection: _prefs.readingMode == ReadingMode.vertical
                  ? Axis.vertical
                  : Axis.horizontal,
              reverse:
                  _prefs.readingMode == ReadingMode.horizontal &&
                  _prefs.rightToLeft,
              itemCount: _pages.length,
              onPageChanged: _setIndex,
              itemBuilder: (_, index) => _image(index),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: tegnalTheme(Brightness.dark),
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.black,
      ),
      child: PopScope(
        canPop: !_chrome,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _chrome) setState(() => _chrome = false);
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _key,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final resized =
                    _viewport.width > 0 &&
                    _viewport.width != constraints.maxWidth;
                final retainedIndex = _index;
                _viewport = constraints.biggest;
                if (resized && _continuous) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _go(retainedIndex, animate: false);
                  });
                }
                return Stack(
                  children: [
                    Positioned.fill(
                      child: Listener(
                        onPointerDown: _pointerDown,
                        onPointerMove: _pointerMove,
                        onPointerUp: _pointerUp,
                        onPointerCancel: _pointerCancel,
                        child: _body(),
                      ),
                    ),
                    if (_prefs.dimming > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: Color.fromRGBO(0, 0, 0, _prefs.dimming),
                          ),
                        ),
                      ),
                    if (_loading || _error != null || _video)
                      Align(alignment: Alignment.topCenter, child: _topBar()),
                    if (_sourcePages.isNotEmpty && !_loading && _chrome)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: _controls(),
                      ),
                    if (_sourcePages.isNotEmpty &&
                        !_loading &&
                        !_video &&
                        !_chrome &&
                        _pages.length > 1 &&
                        _prefs.showPageNumber)
                      Positioned(
                        bottom: MediaQuery.paddingOf(context).bottom + 10,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0x99000000),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_position + 1} / $_count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    ++_generation;
    _auto?.cancel();
    _notesClient?.close();
    WidgetsBinding.instance.removeObserver(this);
    if (_sourcePages.isNotEmpty) _savePosition();
    _pager?.dispose();
    _scroll.dispose();
    _focus.dispose();
    if (_previousAwake != null) {
      unawaited(
        WakelockPlus.toggle(enable: _previousAwake!).catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}

class _ReaderImage extends StatefulWidget {
  const _ReaderImage({
    super.key,
    required this.page,
    required this.continuous,
    required this.onZoom,
    required this.onRatio,
    this.notes = const [],
  });
  final List<BooruNote> notes;
  final ReaderPage page;
  final bool continuous;
  final ValueChanged<bool> onZoom;
  final ValueChanged<double> onRatio;
  @override
  State<_ReaderImage> createState() => _ReaderImageState();
}

class _ReaderImageState extends State<_ReaderImage> {
  final TransformationController _transform = TransformationController();
  Offset _doubleTapPosition = Offset.zero;
  bool _zoomed = false;
  int _retry = 0;
  int _prepareGeneration = 0;
  bool _headersReady = false;
  Size _naturalSize = Size.zero;
  Map<String, String> _mediaHeaders = {};
  int _decodeLimit = 3000;
  ImageProvider<Object>? _resolvedProvider;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  ImageProvider<Object> get _provider =>
      _resolvedProvider ??
      readerImageProvider(widget.page, _mediaHeaders, _decodeLimit);

  void _zoomChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed) {
      setState(() {
        _zoomed = zoomed;
      });
      widget.onZoom(zoomed);
    }
  }

  @override
  void initState() {
    super.initState();
    _transform.addListener(_zoomChanged);
    unawaited(_prepareImage());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextLimit = _readerDecodeLimit(context);
    if (nextLimit != _decodeLimit) {
      _decodeLimit = nextLimit;
      if (_headersReady) {
        _resolvedProvider = readerImageProvider(
          widget.page,
          _mediaHeaders,
          _decodeLimit,
        );
      }
    }
    if (_headersReady) _resolveDimensions();
  }

  Future<void> _prepareImage() async {
    final generation = ++_prepareGeneration;
    if (mounted) {
      setState(() {
        _headersReady = false;
      });
    }
    final ephemeral = await BrowserSession.headersFor(widget.page.url);
    if (!mounted || generation != _prepareGeneration) return;
    setState(() {
      _mediaHeaders = {...widget.page.headers, ...ephemeral};
      _resolvedProvider = readerImageProvider(
        widget.page,
        _mediaHeaders,
        _decodeLimit,
      );
      _headersReady = true;
      _retry++;
    });
    _resolveDimensions();
  }

  void _resolveDimensions() {
    if (_imageListener != null) _imageStream?.removeListener(_imageListener!);
    _imageStream = _provider.resolve(createLocalImageConfiguration(context));
    _imageListener = ImageStreamListener(
      (info, synchronous) {
        _naturalSize = Size(
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        );
        widget.onRatio(info.image.width / info.image.height);
        info.dispose();
      },
      onError: (Object error, StackTrace? stack) {
        // The visible Image provides the error and retry control.
      },
    );
    _imageStream!.addListener(_imageListener!);
  }

  @override
  Widget build(BuildContext context) {
    if (!_headersReady) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final image = Image(
      image: _provider,
      key: ValueKey(_retry),
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      frameBuilder: (context, child, frame, sync) => frame == null
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : child,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final expected = progress.expectedTotalBytes;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              if (expected != null && expected > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${(progress.cumulativeBytesLoaded / expected * 100).round()}%',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
      errorBuilder: (context, error, stack) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, color: Colors.grey, size: 38),
            Text(
              L10n.tr(context, 'Unable to load image'),
              style: const TextStyle(color: Colors.grey),
            ),
            TextButton(
              onPressed: () async {
                await _provider.evict();
                if (mounted) {
                  await _prepareImage();
                }
              },
              child: Text(L10n.tr(context, 'Retry')),
            ),
          ],
        ),
      ),
    );
    return GestureDetector(
      onDoubleTapDown: (details) {
        _doubleTapPosition = details.localPosition;
      },
      onDoubleTap: () {
        _transform.value = _zoomed
            ? Matrix4.identity()
            : (Matrix4.diagonal3Values(2.5, 2.5, 1)..setTranslationRaw(
                -_doubleTapPosition.dx * 1.5,
                -_doubleTapPosition.dy * 1.5,
                0,
              ));
      },
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        panEnabled: _zoomed,
        scaleEnabled: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (widget.notes.isNotEmpty)
              Positioned.fill(
                child: ReaderNotesOverlay(
                  notes: widget.notes,
                  imageSize: widget.page.width > 0 && widget.page.height > 0
                      ? Size(
                          widget.page.width.toDouble(),
                          widget.page.height.toDouble(),
                        )
                      : _naturalSize,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (_imageListener != null) _imageStream?.removeListener(_imageListener!);
    _transform.dispose();
    super.dispose();
  }
}

class _ReaderVideo extends StatefulWidget {
  const _ReaderVideo({super.key, required this.page, required this.keepAwake});
  final ReaderPage page;
  final bool keepAwake;
  @override
  State<_ReaderVideo> createState() => _ReaderVideoState();
}

class _ReaderVideoState extends State<_ReaderVideo> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _errors = _player.stream.error.listen((error) {
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    });
    unawaited(_open());
  }

  Future<void> _open() async {
    if (mounted) {
      setState(() {
        _error = null;
      });
    }
    try {
      final ephemeral = await BrowserSession.headersFor(widget.page.url);
      if (!mounted) return;
      await _player.open(
        Media(
          widget.page.url.toString(),
          httpHeaders: {...widget.page.headers, ...ephemeral},
        ),
      );
    } on Exception {
      if (mounted) {
        setState(() {
          _error = 'Unable to play this video. Check the connection and retry.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _error == null
      ? Stack(
          children: [
            Positioned.fill(
              child: Video(
                controller: _controller,
                wakelock: widget.keepAwake,
                controls: NoVideoControls,
              ),
            ),
            Positioned.fill(child: _MaterialPlaybackControls(player: _player)),
          ],
        )
      : Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
                TextButton(
                  onPressed: _open,
                  child: Text(L10n.tr(context, 'Retry')),
                ),
              ],
            ),
          ),
        );

  @override
  void dispose() {
    unawaited(_errors?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }
}

/// Material playback controls preserve the reader's compact media overlay.
class _MaterialPlaybackControls extends StatefulWidget {
  const _MaterialPlaybackControls({required this.player});
  final Player player;
  @override
  State<_MaterialPlaybackControls> createState() =>
      _MaterialPlaybackControlsState();
}

class _MaterialPlaybackControlsState extends State<_MaterialPlaybackControls> {
  bool _visible = true;
  double? _scrub;
  double _lastVolume = 100;
  String _time(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 1 << 40);
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _button(IconData icon, String title, VoidCallback action) => Semantics(
    label: L10n.tr(context, title),
    button: true,
    child: IconButton(
      onPressed: action,
      tooltip: L10n.tr(context, title),
      icon: Icon(icon, color: Colors.white, size: 28),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            _visible = !_visible;
          }),
          child: const ColoredBox(color: Color(0x00000000)),
        ),
      ),
      Center(
        child: StreamBuilder<bool>(
          stream: widget.player.stream.buffering,
          initialData: widget.player.state.buffering,
          builder: (context, snapshot) => snapshot.data == true
              ? const IgnorePointer(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              : const SizedBox(),
        ),
      ),
      if (_visible)
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              color: const Color(0xCC000000),
              child: StreamBuilder<Duration>(
                stream: widget.player.stream.duration,
                initialData: widget.player.state.duration,
                builder: (context, durationSnapshot) => StreamBuilder<Duration>(
                  stream: widget.player.stream.position,
                  initialData: widget.player.state.position,
                  builder: (context, positionSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final position = positionSnapshot.data ?? Duration.zero;
                    final max = duration.inMilliseconds.toDouble();
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (max > 0)
                          Slider(
                            value:
                                (_scrub ?? position.inMilliseconds.toDouble())
                                    .clamp(0, max),
                            max: max,
                            onChanged: (value) => setState(() {
                              _scrub = value;
                            }),
                            onChangeEnd: (value) {
                              unawaited(
                                widget.player.seek(
                                  Duration(milliseconds: value.round()),
                                ),
                              );
                              setState(() {
                                _scrub = null;
                              });
                            },
                          ),
                        Row(
                          children: [
                            _button(
                              Icons.replay_10,
                              'Back 10 seconds',
                              () => unawaited(
                                widget.player.seek(
                                  Duration(
                                    milliseconds:
                                        (position.inMilliseconds - 10000).clamp(
                                          0,
                                          duration.inMilliseconds > 0
                                              ? duration.inMilliseconds
                                              : position.inMilliseconds,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            StreamBuilder<bool>(
                              stream: widget.player.stream.playing,
                              initialData: widget.player.state.playing,
                              builder: (context, snapshot) => _button(
                                snapshot.data == true
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                snapshot.data == true ? 'Pause' : 'Play',
                                () => unawaited(widget.player.playOrPause()),
                              ),
                            ),
                            _button(
                              Icons.forward_10,
                              'Forward 10 seconds',
                              () => unawaited(
                                widget.player.seek(
                                  Duration(
                                    milliseconds:
                                        (position.inMilliseconds + 10000).clamp(
                                          0,
                                          duration.inMilliseconds > 0
                                              ? duration.inMilliseconds
                                              : position.inMilliseconds + 10000,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${_time(position)} / ${_time(duration)}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            StreamBuilder<double>(
                              stream: widget.player.stream.volume,
                              initialData: widget.player.state.volume,
                              builder: (context, snapshot) {
                                final volume = snapshot.data ?? 100;
                                return _button(
                                  volume == 0
                                      ? Icons.volume_off
                                      : Icons.volume_up,
                                  volume == 0 ? 'Unmute' : 'Mute',
                                  () {
                                    if (volume > 0) _lastVolume = volume;
                                    unawaited(
                                      widget.player.setVolume(
                                        volume == 0 ? _lastVolume : 0,
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
