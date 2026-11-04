import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/booru/booru_client.dart';
import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_support.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../../core/taste/taste_models.dart';
import '../../core/taste/taste_viewing.dart';
import '../content/content_bookmark.dart';
import '../content/reader_guide_overlay.dart';
import '../content/reader_models.dart';
import '../content/reader_view.dart' show ReaderMenuGlass, ReaderScreen, ReaderSettingsView;
import '../content/work_save_feedback.dart';
import '../design/app_sheet.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../settings/downloads_view.dart';
import 'booru_common.dart';
import 'booru_favorites_view.dart';
import 'booru_media_view.dart';
import 'booru_post_details.dart';

/// The next page of a feed, handed to an open viewer.
class BooruViewerBatch {
  const BooruViewerBatch({required this.posts, required this.hasMore, this.failure});
  final List<BooruPost> posts;
  final bool hasMore;
  final String? failure;
}

/// `BooruPostView`: one image or video at a time on black, moving through the list it was
/// opened from and loading the feed's next page at its end.
class BooruPostView extends StatefulWidget {
  const BooruPostView({super.key, required this.booru, required this.post, required this.posts, required this.discovery, this.loadMore, this.willClose});

  final BooruContext booru;
  final BooruPost post;
  final List<BooruPost> posts;
  final DiscoveryContext discovery;
  final Future<BooruViewerBatch> Function()? loadMore;
  final ValueChanged<BooruPost>? willClose;

  /// Opens the viewer full screen over everything, as `fullScreenCover` does.
  static Future<void> open(
    BuildContext context, {
    required BooruContext booru,
    required BooruPost post,
    required List<BooruPost> posts,
    required DiscoveryContext discovery,
    Future<BooruViewerBatch> Function()? loadMore,
    ValueChanged<BooruPost>? willClose,
  }) => Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 380),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondary) =>
          BooruPostView(booru: booru, post: post, posts: posts, discovery: discovery, loadMore: loadMore, willClose: willClose),
      transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );

  @override
  State<BooruPostView> createState() => _BooruPostViewState();
}

class _BooruPostViewState extends State<BooruPostView> {
  late List<BooruPost> _posts = [...widget.posts];
  late BooruPost _post = widget.post;
  late final _access = BooruViewerAccessNavigation(
    removedIDs: {
      for (final post in widget.posts)
        if (post.isRemoved) post.id,
    },
  );
  late bool _original = _defaults.boolean('booru.original') ?? false;
  bool _menuVisible = false;
  bool _sheetOpen = false;
  bool _zoomed = false;
  bool _exiting = false;
  String _mediaStatus = 'loading';
  bool _showsLoading = false;
  Timer? _loadingTimer;
  int _retry = 0;
  String? _refreshedMediaID;
  List<BooruNote> _notes = [];
  String? _notesError;
  String? _loadedNotesKey;
  String? _toast;
  Timer? _toastTimer;
  Timer? _autoTimer;
  double _drag = 0;
  bool _loadingMore = false;
  late bool _hasMore = widget.loadMore != null;
  String? _requestedFromID;
  final _guide = ReaderGuideSession();
  final _viewing = TasteViewingSession();
  bool _pendingGuide = false;
  final _menuKey = GlobalKey();

  BooruContext get _booru => widget.booru;
  Preferences get _defaults => _booru.booruDefaults;
  BooruServer get _server => _booru.server(_post.serverID) ?? _booru.store.servers.first;
  int get _index => math.max(0, _posts.indexWhere((post) => post.id == _post.id));
  bool get _rtl => _defaults.boolean('reader.rtl') ?? false;
  bool get _bottomMenu => _defaults.boolean('reader.bottomMenu') ?? false;
  bool get _pageNumber => _defaults.boolean('reader.pageNumber') ?? false;
  bool get _keepAwake => _defaults.boolean('reader.keepAwake') ?? true;
  double get _dimming => (_defaults.object('reader.dimming') as num?)?.toDouble() ?? 0;
  bool get _tapNavigation => _defaults.boolean('reader.tapNavigation') ?? true;
  bool get _autoAdvance => _defaults.boolean('reader.autoAdvance') ?? false;
  double get _autoSeconds => (_defaults.object('reader.autoSeconds') as num?)?.toDouble() ?? 10;
  bool get _reducedData => _defaults.boolean('booru.reducedData') ?? false;
  bool get _showNotes => _defaults.boolean('booru.showNotes') ?? true;
  bool get _helpHidden => _defaults.boolean(ReaderSettingKeys.helpHidden) ?? false;
  bool get _active => !_exiting && !_sheetOpen;
  bool get _resolvesMissingMedia => _server.engine.usesGelbooruPages || _server.engine == BooruEngine.danbooru;
  String? get _viewerURL => _post.viewerURL(original: _original, reducedData: _reducedData);
  bool get _mediaReady => const {'ready', 'playing', 'ended'}.contains(_mediaStatus);
  bool get _removed => _post.isRemoved || _mediaStatus == 'removed';
  bool get _mediaActive => _active && !_removed && _booru.store.isVisible(_post) && !_access.restrictedIDs.contains(_post.id);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ReaderScreen.keepAwake(_keepAwake);
    _postChanged();
    if (_post.isVideo && !(_defaults.boolean('booru.videoMenuHintSeen') ?? false)) {
      _defaults.set('booru.videoMenuHintSeen', true);
      _showToast(L10n.text('Tap with two fingers for the video menu'));
    }
  }

  @override
  void dispose() {
    _loadingTimer?.cancel();
    _toastTimer?.cancel();
    _autoTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    ReaderScreen.keepAwake(false);
    super.dispose();
  }

  // MARK: Post changes

  void _postChanged() {
    if (_booru.store.confirmedGoldRestrictedIDs.contains(_post.id)) {
      scheduleMicrotask(() => _skipGoldRestricted(_post.id));
      return;
    }
    _booru.store.observeTaste(_post, widget.discovery);
    _viewing.resume();
    _scheduleLoadingIndicator();
    _resolveCurrentPost();
  }

  void _scheduleLoadingIndicator() {
    _loadingTimer?.cancel();
    _showsLoading = false;
    final url = _viewerURL;
    if (url != null && _booru.viewerImages.cached(url, _server) != null) return;
    final id = _post.id;
    _loadingTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted && _post.id == id && (_mediaStatus == 'loading' || _loadingMore && _requestedFromID != null)) setState(() => _showsLoading = true);
    });
  }

  void _status(String status, String postID) {
    if (_post.id != postID || _access.restrictedIDs.contains(postID)) return;
    setState(() {
      _mediaStatus = status;
      if (status != 'loading') _showsLoading = false;
    });
    if (_mediaReady) {
      _loadNotes();
      _maybeStartGuide();
      _preloadNeighbor();
      if (_index >= _posts.length - 5) Timer(const Duration(milliseconds: 200), _requestMore);
    }
    if (status == 'error') _refreshMissingMedia();
    _scheduleAuto();
  }

  Future<void> _resolveCurrentPost() async {
    final post = _post;
    _notes = [];
    _notesError = null;
    if (post.isRemoved) return _removedPost(post.id);
    if (!_resolvesMissingMedia || post.viewerURL(original: _original, reducedData: _reducedData) != null) return;
    try {
      final resolved = await _booru.source.details(_server, post);
      if (!mounted || _post.id != post.id) return;
      setState(() {
        _post = resolved;
        final index = _posts.indexWhere((item) => item.id == resolved.id);
        if (index >= 0) _posts[index] = resolved;
        if (_viewerURL == null) _mediaStatus = 'unavailable';
      });
      if (_booru.store.folderIDFor(resolved) case final folder?) _booru.store.saveFavorite(resolved, folderID: folder);
    } on Object catch (error) {
      if (!mounted || _post.id != post.id) return;
      if (error == BooruPostAccessError.removed) return _removedPost(post.id);
      if (error == BooruPostAccessError.goldRequired) return _skipGoldRestricted(post.id);
      setState(() => _mediaStatus = 'error');
      _showToast(BooruConnectionMessage.describe(error));
    }
  }

  /// A failed address can be stale; resolving the post once more may find a new one.
  Future<void> _refreshMissingMedia() async {
    final post = _post;
    if (!_resolvesMissingMedia || _refreshedMediaID == post.id) return;
    _refreshedMediaID = post.id;
    try {
      final resolved = await _booru.source.details(_server, post);
      if (!mounted || _post.id != post.id) return;
      if (resolved.fileURL != post.fileURL || resolved.sampleURL != post.sampleURL) {
        setState(() {
          _post = resolved;
          _mediaStatus = 'loading';
        });
        if (_booru.store.folderIDFor(resolved) case final folder?) _booru.store.saveFavorite(resolved, folderID: folder);
      }
    } on Object catch (error) {
      if (!mounted || _post.id != post.id) return;
      if (error == BooruPostAccessError.removed) return _removedPost(post.id);
      if (error == BooruPostAccessError.goldRequired) return _skipGoldRestricted(post.id);
      _showToast(BooruConnectionMessage.describe(error));
    }
  }

  Future<void> _loadNotes() async {
    final key = '${_post.id}:$_retry';
    if (!_active || _loadedNotesKey == key || !(_showNotes || _sheetOpen)) return;
    _loadedNotesKey = key;
    try {
      final notes = await _booru.source.notes(_server, _post.postID);
      if (mounted && '${_post.id}:$_retry' == key) setState(() => _notes = notes);
    } on Object catch (error) {
      if (mounted && '${_post.id}:$_retry' == key) setState(() => _notesError = '$error');
    }
  }

  /// Fetches the next image once this one settles, unless the device is saving power.
  Future<void> _preloadNeighbor() async {
    if (_booru.fixture) return;
    final id = _post.id;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted || _post.id != id || !_mediaActive) return;
    final next = _index + 1;
    if (next >= _posts.length) return;
    var item = _posts[next];
    final host = _booru.server(item.serverID);
    if (host == null) return;
    final original = _defaults.boolean('booru.original') ?? false;
    if (item.viewerURL(original: original, reducedData: _reducedData) == null && host.engine.usesGelbooruPages) {
      try {
        item = await _booru.source.details(host, item);
        if (!mounted) return;
        final index = _posts.indexWhere((post) => post.id == item.id);
        if (index >= 0) _posts[index] = item;
      } on Object {
        return;
      }
    }
    final url = item.viewerURL(original: original, reducedData: _reducedData);
    if (!item.isVideo && url != null) _booru.viewerImages.prefetch([(url, host)]);
  }

  // MARK: Navigation

  void _move(int delta) {
    if (!_active) return;
    final next = _access.candidate(
      _posts.map((post) => post.id).toList(),
      startingAt: _index + delta,
      direction: delta < 0 ? -1 : 1,
      excluding: _booru.store.confirmedGoldRestrictedIDs,
    );
    if (next == null) {
      if (delta > 0 && widget.loadMore != null && _hasMore) {
        _requestedFromID = _post.id;
        _requestMore();
      } else {
        _requestedFromID = null;
      }
      return;
    }
    _requestedFromID = null;
    _access.moved(delta);
    if (next != _index) _select(next);
  }

  void _select(int index) {
    _recordViewing(_post);
    setState(() {
      _post = _posts[index];
      _original = _defaults.boolean('booru.original') ?? false;
      _mediaStatus = 'loading';
      _zoomed = false;
      _notes = [];
      _loadedNotesKey = null;
    });
    _postChanged();
  }

  void _recordViewing(BooruPost post) {
    final dwell = _viewing.finish();
    if (dwell != null) _booru.store.recordDwell(dwell, post, widget.discovery);
  }

  void _skipGoldRestricted(String id) {
    if (_exiting || _post.id != id) return;
    _booru.store.recordGoldRestriction(_post);
    _access.restrict(id);
    _requestedFromID = null;
    setState(() => _mediaStatus = 'restricted');
    _continueAfterRestriction();
  }

  void _removedPost(String id) {
    if (_exiting || _post.id != id) return;
    _requestedFromID = null;
    setState(() {
      _mediaStatus = 'removed';
      _notes = [];
      _zoomed = false;
    });
    if (_access.removed(id)) _continueAfterRestriction();
  }

  void _continueAfterRestriction() {
    if (!_active || _loadingMore || _access.pendingID != _post.id) return;
    final destination = _access.destination(
      _posts.map((post) => post.id).toList(),
      current: _index,
      canLoadMore: widget.loadMore != null && _hasMore,
      excluding: _booru.store.confirmedGoldRestrictedIDs,
    );
    switch (destination) {
      case BooruViewerClose():
        _close();
      case BooruViewerLoadMore():
        _requestMore();
      case BooruViewerPost(:final index):
        _access.moved(_access.direction);
        _select(index);
    }
  }

  Future<void> _requestMore() async {
    final loadMore = widget.loadMore;
    if (loadMore == null || _loadingMore || !_hasMore || !_active) return;
    setState(() => _loadingMore = true);
    final batch = await loadMore();
    if (!mounted) return;
    final seen = {for (final post in _posts) post.id};
    setState(() {
      _posts = [..._posts, ...batch.posts.where((post) => seen.add(post.id))];
      _access.recordRemovals(batch.posts);
      _hasMore = batch.hasMore;
      _loadingMore = false;
    });
    if (batch.failure case final failure?) _showToast(failure);
    _completePendingAdvance();
  }

  void _completePendingAdvance() {
    if (_access.pendingID == _post.id) return _continueAfterRestriction();
    final requested = _requestedFromID;
    if (requested == null) return;
    if (requested != _post.id) {
      _requestedFromID = null;
      return;
    }
    final next = _access.candidate(
      _posts.map((post) => post.id).toList(),
      startingAt: _index + 1,
      direction: 1,
      excluding: _booru.store.confirmedGoldRestrictedIDs,
    );
    if (next == null) {
      if (!_loadingMore) _requestedFromID = null;
      return;
    }
    _requestedFromID = null;
    _move(next - _index);
  }

  void _close() {
    if (_exiting) return;
    if (_guide.step != null) _finishGuide();
    _exiting = true;
    _recordViewing(_post);
    widget.willClose?.call(_post);
    Navigator.of(context).pop();
  }

  // MARK: Gestures

  void _gesture(BooruMediaGesture gesture) {
    if (_sheetOpen) return;
    switch (gesture) {
      case BooruTap(:final x):
        if (x >= 0.3 && x <= 0.7) {
          _toggleMenu();
        } else if (_tapNavigation) {
          _move((x < 0.3 ? -1 : 1) * (_rtl ? -1 : 1));
        }
      case BooruSwipe(:final delta):
        if (!_zoomed) _move(delta * (_rtl ? -1 : 1));
      case BooruHold():
        _toggleFavorite();
      case BooruDetails():
        if (!_zoomed) _openDetails();
      case BooruZoom(:final zoomed):
        if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
        _scheduleAuto();
      case BooruVideoMenu():
        _toggleMenu();
    }
  }

  void _toggleMenu() {
    setState(() {
      _menuVisible = !_menuVisible;
      if (_menuVisible) _guide.openedMenu();
    });
    _scheduleAuto();
  }

  void _exitDrag(double offset, {bool? end, double velocity = 0}) {
    if (_zoomed || _sheetOpen) return;
    if (end == true) return _close();
    setState(() => _drag = end == false ? 0 : offset);
  }

  void _toggleFavorite() {
    showWorkSaveFeedback(context, _booru.toggleFavorite(_post, context: widget.discovery), bottom: 16 + math.max(MediaQuery.paddingOf(context).bottom, 34));
    setState(() {});
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // MARK: Auto advance and the guide

  void _scheduleAuto() {
    _autoTimer?.cancel();
    if (!_autoAdvance || _guide.step != null || !_active || _menuVisible || _zoomed || !const {'ready', 'ended'}.contains(_mediaStatus)) return;
    final id = _post.id;
    _autoTimer = Timer(Duration(milliseconds: (_autoSeconds.clamp(2, 120) * 1000).round()), () {
      if (!mounted || _post.id != id) return;
      if (_index < _posts.length - 1 || widget.loadMore != null && _hasMore) {
        _move(1);
      } else {
        _defaults.set('reader.autoAdvance', false);
      }
    });
  }

  void _maybeStartGuide() {
    if (_helpHidden || _guide.hasStarted || _sheetOpen || _menuVisible) return;
    setState(_guide.start);
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

  // MARK: Sheets

  Future<void> _sheet(Widget Function(BuildContext context, ScrollController controller) builder, {bool grabber = true, bool medium = false}) async {
    setState(() => _sheetOpen = true);
    _viewing.pause();
    _autoTimer?.cancel();
    await showAppSheet<void>(context, grabber: grabber, medium: medium, builder: builder);
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
    _viewing.resume();
    _scheduleAuto();
  }

  void _openSettings() => _sheet(
    (context, controller) => ReaderSettingsView(
      preferences: _defaults,
      booru: true,
      scrollController: controller,
      onChanged: () => setState(() => _original = _defaults.boolean('booru.original') ?? false),
      onShowGuide: () {
        _pendingGuide = true;
        Navigator.of(context).pop();
      },
    ),
  );

  void _openDetails() {
    _loadNotes();
    _sheet(
      (sheetContext, controller) => BooruPostDetails(
        booru: _booru,
        post: _post,
        server: _server,
        notes: _notes,
        notesError: _notesError,
        original: _original,
        scrollController: controller,
        onOriginal: (value) => setState(() => _original = value),
        onResolved: (post) => setState(() {
          _post = post;
          final index = _posts.indexWhere((item) => item.id == post.id);
          if (index >= 0) _posts[index] = post;
        }),
        onRetryNotes: () => setState(() {
          _retry++;
          _loadNotes();
        }),
        onHidden: () {
          Navigator.of(sheetContext).pop();
          _close();
        },
      ),
    );
  }

  void _openNote(BooruNote note) => _sheet((context, controller) => BooruNoteView(note: note, scrollController: controller));

  void _openFolders() =>
      _sheet((context, controller) => BooruFolderPicker(booru: _booru, post: _post, discovery: widget.discovery, scrollController: controller), medium: true);

  void _download() {
    _booru.downloads.store.enqueuePost(_post, _server);
    _sheet((context, controller) => DownloadsView(downloads: _booru.downloads, booru: true, inSheet: true), grabber: false);
  }

  Future<void> _share() async {
    try {
      await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<void>('share', {'text': _server.pageURL(_post.postID)});
    } on Object {
      await Clipboard.setData(ClipboardData(text: _server.pageURL(_post.postID)));
    }
  }

  Future<void> _jump() async {
    final controller = TextEditingController(text: '${_index + 1}');
    setState(() => _sheetOpen = true);
    final number = await showCupertinoDialog<int>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
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
    if (!mounted) return;
    setState(() => _sheetOpen = false);
    if (number != null && number >= 1 && number <= _posts.length) _move(number - 1 - _index);
  }

  // MARK: Layout

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final url = _viewerURL;
    final failed = _removed || const {'error', 'unavailable'}.contains(_mediaStatus) || url == null && !_resolvesMissingMedia;
    final server = _server;
    return CupertinoTheme(
      data: tegnalTheme(Brightness.dark),
      child: ColoredBox(
        color: Color.fromRGBO(0, 0, 0, (1 - _drag / 600).clamp(0, 1)),
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0xFF000000))),
              if (_removed)
                Positioned.fill(
                  child: BooruMediaFailureView(post: _post, server: server, removed: true, onGesture: _gesture, retry: () {}),
                )
              else if (url != null)
                Positioned.fill(
                  child: BooruMediaView(
                    key: ValueKey('${server.id}:${_post.id}:$_retry'),
                    booru: _booru,
                    post: _post,
                    server: server,
                    url: url,
                    active: _mediaActive && _mediaStatus != 'error',
                    notes: _notes,
                    showNotes: _showNotes,
                    onNote: _openNote,
                    onStatus: (status) => _status(status, _post.id),
                    onGesture: _gesture,
                    onExitDrag: _exitDrag,
                    onGoldRequired: () => _skipGoldRestricted(_post.id),
                    onRemoved: () => _removedPost(_post.id),
                  ),
                ),
              if (!_removed && (_mediaStatus == 'error' || url == null && !_resolvesMissingMedia || _mediaStatus == 'unavailable'))
                Positioned.fill(
                  child: BooruMediaFailureView(
                    post: _post,
                    server: server,
                    onGesture: _gesture,
                    retry: () => setState(() {
                      _mediaStatus = 'loading';
                      _retry++;
                    }),
                  ),
                ),
              if (_showsLoading && _active && (_mediaStatus == 'loading' || _loadingMore && _requestedFromID != null))
                const Positioned.fill(
                  child: IgnorePointer(child: Center(child: BooruLoadingIndicator())),
                ),
              if (_dimming > 0)
                Positioned.fill(
                  child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, _dimming.clamp(0, 0.65)))),
                ),
              // `ReaderDismissHandle`: the bar that says the viewer closes downward.
              Positioned(
                left: 0,
                right: 0,
                top: 6,
                child: IgnorePointer(
                  child: Center(
                    child: Semantics(
                      label: L10n.text('Swipe down to exit the work'),
                      child: Container(
                        width: 60,
                        height: 4,
                        decoration: const ShapeDecoration(color: Color(0xFF636366), shape: StadiumBorder()),
                      ),
                    ),
                  ),
                ),
              ),
              if (_toast != null)
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const ShapeDecoration(color: Color(0xE6303030), shape: StadiumBorder()),
                        child: Text(
                          _toast!,
                          textAlign: TextAlign.center,
                          style: TegnalType.style(15, weight: FontWeight.w700, color: const Color(0xFFFFFFFF)),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + math.max(media.padding.bottom, 34),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_menuVisible || failed)
                      _quickMenu()
                    else if (_pageNumber)
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const ShapeDecoration(color: Color(0x80000000), shape: StadiumBorder()),
                        child: Text('${_index + 1} / ${_posts.length}', style: TegnalType.style(12, color: const Color(0xFFFFFFFF))),
                      ),
                    if (_bottomMenu && !_menuVisible && !failed) ...[
                      const SizedBox(height: 8),
                      ReaderMenuGlass(
                        child: Padding(padding: const EdgeInsets.all(12), child: _menuActions(compact: true)),
                      ),
                    ],
                  ],
                ),
              ),
              if (_guide.step case final step? when !_sheetOpen)
                Positioned.fill(
                  child: ReaderGuideOverlay(
                    step: step,
                    configuration: ReaderGuideConfiguration(booru: true, defaults: _defaults),
                    menuKey: _menuKey,
                    next: _advanceGuide,
                    finish: _finishGuide,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickMenu() {
    const white = Color(0xFFFFFFFF);
    final disabled = white.withValues(alpha: 0.3);
    final canGoNext = _index < _posts.length - 1 || widget.loadMore != null && _hasMore;
    Widget icon(IconData icon, String label, VoidCallback? onTap, {double size = 22}) => Semantics(
      button: true,
      label: label,
      enabled: onTap != null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: 44,
          child: Icon(icon, size: size, color: onTap == null ? disabled : white),
        ),
      ),
    );
    return ReaderMenuGlass(
      key: _menuKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                icon(CupertinoIcons.chevron_left, L10n.text('Previous'), _index == 0 ? null : () => _move(-1)),
                Expanded(
                  child: GestureDetector(
                    onTap: _jump,
                    child: Center(
                      child: Text(
                        '${_index + 1} / ${_posts.length}',
                        style: TegnalType.style(17, weight: FontWeight.w600, color: white),
                      ),
                    ),
                  ),
                ),
                icon(CupertinoIcons.chevron_right, L10n.text('Next'), canGoNext ? () => _move(1) : null),
                icon(CupertinoIcons.xmark_circle_fill, L10n.text('Close Menu'), () {
                  setState(() => _menuVisible = false);
                  _scheduleAuto();
                }),
              ],
            ),
            const SizedBox(height: 16),
            _menuActions(compact: false),
          ],
        ),
      ),
    );
  }

  Widget _menuActions({required bool compact}) {
    final favorite = _booru.store.isFavorite(_post);
    Widget symbol(IconData icon) => Icon(icon, size: 24, color: const Color(0xFFFFFFFF));
    final items = <(String, Widget, VoidCallback?)>[
      (L10n.text('Download Work'), symbol(CupertinoIcons.arrow_down_circle), _download),
      (
        WorkSaveResult.actionTitle(saved: favorite, mode: TasteMode.booru),
        symbol(favorite ? CupertinoIcons.heart_fill : CupertinoIcons.heart),
        _toggleFavorite,
      ),
      (L10n.text('Save to Folder'), symbol(CupertinoIcons.folder), _openFolders),
      // Translation arrives with its own rebuild step.
      (L10n.text('Translate'), const TranslateSymbol(color: Color(0xFFFFFFFF)), null),
      (L10n.text('Exit'), const ExitSymbol(color: Color(0xFFFFFFFF)), _close),
      (
        L10n.text('Notes'),
        symbol(_showNotes ? CupertinoIcons.text_bubble_fill : CupertinoIcons.text_bubble),
        () => setState(() => _defaults.set('booru.showNotes', !_showNotes)),
      ),
      (L10n.text('Details'), symbol(CupertinoIcons.info_circle), _openDetails),
      (L10n.text('Share'), symbol(CupertinoIcons.square_arrow_up), _share),
      (L10n.text('More Settings'), symbol(CupertinoIcons.slider_horizontal_3), _openSettings),
    ];
    final columns = compact ? 4 : 3;
    const white = Color(0xFFFFFFFF);
    return Column(
      children: [
        for (var row = 0; row < (items.length / columns).ceil(); row++) ...[
          if (row > 0) const SizedBox(height: 21),
          Row(
            children: [
              for (var column = 0; column < columns; column++)
                Expanded(
                  child: row * columns + column >= items.length
                      ? const SizedBox.shrink()
                      : Builder(
                          builder: (context) {
                            final (title, icon, action) = items[row * columns + column];
                            return Semantics(
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
                                        SizedBox(height: 24, child: Center(child: icon)),
                                        const SizedBox(height: 6),
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TegnalType.style(compact ? 9 : 12, weight: compact ? FontWeight.w500 : FontWeight.w400, color: white),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Opens a website or mail link outside the app.
void openExternalLink(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

/// `BooruMediaFailureView`: why the post cannot be shown, with the website link. The edges
/// still take taps and horizontal swipes so the person can move on.
class BooruMediaFailureView extends StatelessWidget {
  const BooruMediaFailureView({super.key, required this.post, required this.server, this.removed = false, required this.onGesture, required this.retry});
  final BooruPost post;
  final BooruServer server;
  final bool removed;
  final ValueChanged<BooruMediaGesture> onGesture;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    const white = Color(0xFFFFFFFF);
    const secondary = Color(0x99EBEBF5);
    final media = MediaQuery.of(context);
    final page = server.pageURL(post.postID);
    Offset? start;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => onGesture(BooruTap(details.localPosition.dx / math.max(1, constraints.maxWidth))),
        onPanStart: (details) => start = details.localPosition,
        onPanEnd: (details) {
          final origin = start;
          if (origin == null) return;
          final delta = details.localPosition - origin;
          if (BooruFailureNavigation.swipe(delta.dx, delta.dy) case final direction?) onGesture(BooruSwipe(direction));
        },
        child: ColoredBox(
          color: const Color(0xE6000000),
          child: Padding(
            padding: EdgeInsets.fromLTRB(44, media.padding.top + 36, 44, 230),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(removed ? CupertinoIcons.trash : CupertinoIcons.exclamationmark_triangle, size: 34, color: white),
                      const SizedBox(height: 16),
                      Text(
                        L10n.text(removed ? 'Deleted Post' : 'Unable to Load'),
                        textAlign: TextAlign.center,
                        style: TegnalType.style(22, weight: FontWeight.w700, color: white),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        L10n.text(
                          removed
                              ? 'This post was deleted or removed from the website.'
                              : 'The media could not be loaded or its format is unavailable on this device.',
                        ),
                        textAlign: TextAlign.center,
                        style: TegnalType.style(17, color: secondary),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: () => openExternalLink(page),
                        child: Container(
                          height: 50,
                          alignment: Alignment.center,
                          decoration: ShapeDecoration(color: SystemColors.blue.resolveFrom(context), shape: const StadiumBorder()),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(CupertinoIcons.compass, size: 20, color: white),
                              const SizedBox(width: 8),
                              Text(
                                L10n.text('Open on Website'),
                                style: TegnalType.style(17, weight: FontWeight.w600, color: white),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (!removed) ...[
                        const SizedBox(height: 16),
                        Text(
                          L10n.text('If you can view this post on the website, contact the developer so we can fix it. Include the post link.'),
                          textAlign: TextAlign.center,
                          style: TegnalType.style(16, color: secondary),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: () => openExternalLink('https://discord.gg/DFT9Hm66Gz'),
                          child: Text(L10n.text('Official Discord'), style: TegnalType.style(17, color: SystemColors.blue.resolveFrom(context))),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: () => openExternalLink(
                            Uri(
                              scheme: 'mailto',
                              path: 'contact@nextline.work',
                              queryParameters: {'subject': 'TEGNAL: ${L10n.text('Unable to Load')}', 'body': page},
                            ).toString(),
                          ),
                          child: Text('contact@nextline.work', style: TegnalType.style(16, color: SystemColors.blue.resolveFrom(context))),
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: retry,
                          child: Container(
                            height: 34,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: ShapeDecoration(color: white.withValues(alpha: 0.15), shape: const StadiumBorder()),
                            child: Center(
                              widthFactor: 1,
                              child: Text(
                                L10n.text('Try Again'),
                                style: TegnalType.style(15, weight: FontWeight.w500, color: white),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
