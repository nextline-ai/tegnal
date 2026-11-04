import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../../core/support/l10n.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_models.dart';
import '../../../core/taste/taste_recap.dart';
import '../../booru/booru_feed_view.dart';
import '../../booru/booru_post_view.dart';
import '../../design/app_sheet.dart';
import '../../design/tegnal_theme.dart';
import '../taste_context.dart';
import 'recap_artwork.dart';
import 'recap_pages.dart';
import 'recap_share_view.dart';
import 'recap_style.dart';

/// Opens an issue full screen over everything, as `fullScreenCover` does.
Future<void> openRecapStory(
  BuildContext context, {
  required TasteContext taste,
  required TasteRecap recap,
  required RecapPalette palette,
  required RecapArtwork artwork,
}) => Navigator.of(context, rootNavigator: true).push<void>(
  PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, animation, secondary) => RecapScope(
      artwork: artwork,
      private: taste.booru.safeMode,
      child: RecapStoryView(taste: taste, recap: recap, palette: palette),
    ),
    transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

/// `RecapStoryView`: a tap-through issue. Pages advance by themselves, stop while held or
/// covered, and never run on under a screen reader, where the reader sets the pace.
class RecapStoryView extends StatefulWidget {
  const RecapStoryView({super.key, required this.taste, required this.recap, required this.palette});
  final TasteContext taste;
  final TasteRecap recap;
  final RecapPalette palette;

  @override
  State<RecapStoryView> createState() => _RecapStoryViewState();
}

class _RecapStoryViewState extends State<RecapStoryView> with SingleTickerProviderStateMixin {
  late final List<RecapPage> _pages = RecapPage.pages(widget.recap);
  late final _progress = AnimationController(vsync: this);
  int _index = 0;
  bool _forward = true;
  bool _holding = false;
  bool _covered = false;
  double _drag = 0;
  DateTime? _pressed;
  Offset? _pressStart;

  RecapPage get _page => _pages[math.min(_index, _pages.length - 1)];

  static Duration _duration(RecapPage page) => switch (page) {
    RecapPage.cover => const Duration(milliseconds: 4500),
    RecapPage.chart || RecapPage.rhythm || RecapPage.persona => const Duration(seconds: 9),
    RecapPage.palette => const Duration(seconds: 6),
    _ => const Duration(seconds: 7),
  };

  bool get _accessible => MediaQuery.accessibleNavigationOf(context);
  bool get _playing => !_holding && !_covered && !_accessible && _index < _pages.length - 1 && _drag == 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _progress.addStatusListener((status) {
      if (status == AnimationStatus.completed) _go(_index + 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _progress.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _start() {
    _progress.duration = _duration(_page);
    _sync();
  }

  /// Runs the page's timer while nothing pauses it, keeping the time already spent.
  void _sync() {
    if (!mounted) return;
    if (_playing) {
      if (!_progress.isAnimating) _progress.forward();
    } else {
      _progress.stop();
    }
  }

  void _go(int target) {
    if (target < 0 || target >= _pages.length || target == _index) return;
    HapticFeedback.selectionClick();
    setState(() {
      _forward = target > _index;
      _index = target;
    });
    _progress
      ..stop()
      ..reset()
      ..duration = _duration(_page);
    _sync();
  }

  Future<void> _cover(Future<void> Function() action) async {
    setState(() => _covered = true);
    _sync();
    await action();
    if (!mounted) return;
    setState(() => _covered = false);
    _sync();
  }

  void _close() => Navigator.of(context).pop();

  // MARK: Gestures

  void _down(PointerDownEvent event) {
    final time = DateTime.now();
    _pressed = time;
    _pressStart = event.localPosition;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (mounted && _pressed == time) {
        setState(() => _holding = true);
        _sync();
      }
    });
  }

  void _move(PointerMoveEvent event) {
    final start = _pressStart;
    if (start == null) return;
    final delta = event.localPosition - start;
    if (delta.dy > 0 && delta.dy.abs() > delta.dx.abs()) setState(() => _drag = delta.dy);
  }

  void _up(PointerUpEvent event, double width) {
    final start = _pressStart, pressed = _pressed;
    _pressed = null;
    _pressStart = null;
    final wasHolding = _holding;
    setState(() => _holding = false);
    if (start == null || pressed == null) return _sync();
    final delta = event.localPosition - start;
    final quick = DateTime.now().difference(pressed).inMilliseconds < 250;
    final moved = math.max(delta.dx.abs(), delta.dy.abs());
    if (_drag > 110) return _close();
    if (_drag != 0) setState(() => _drag = 0);
    if (moved < 12) {
      if (quick && !wasHolding) _go(event.localPosition.dx < width * 0.28 ? _index - 1 : _index + 1);
    } else if (delta.dx.abs() > 50) {
      _go(delta.dx < 0 ? _index + 1 : _index - 1);
    }
    _sync();
  }

  // MARK: Actions

  RecapActions get _actions => RecapActions(
    openWork: _openWork,
    openTag: (tag) => _search(tag.name, tag.source),
    search: _search,
    showSaved: () => _cover(
      () => showAppSheet<void>(
        context,
        grabber: true,
        builder: (context, controller) => RecapScope(
          artwork: RecapScope.of(this.context).artwork,
          private: RecapScope.of(this.context).private,
          child: RecapWorksView(taste: widget.taste, recap: widget.recap, palette: widget.palette, open: _openWork),
        ),
      ),
    ),
    share: _share,
    replay: () => _go(0),
    close: _close,
  );

  void _share() => _cover(
    () => showAppSheet<void>(
      context,
      builder: (context, controller) => RecapShareView(recap: widget.recap, palette: widget.palette),
    ),
  );

  void _openWork(RecapWork work) {
    if (widget.recap.isSample) return;
    final taste = widget.taste;
    if (widget.recap.mode == TasteMode.booru) {
      final post = RecapScope.of(context).artwork.post(work);
      if (post == null) return;
      _cover(
        () => BooruPostView.open(
          context,
          booru: taste.booru,
          post: post,
          posts: [post],
          discovery: DiscoveryContext(origin: DiscoveryOrigin.library),
        ),
      );
    } else {
      taste.comics.openThumbnail(context, work.item.id);
    }
  }

  void _search(String query, String source) {
    if (widget.recap.isSample) return;
    final taste = widget.taste;
    if (widget.recap.mode == TasteMode.booru) {
      final server = taste.booru.store.servers.where((server) => server.canonicalAddress == source).firstOrNull;
      if (server == null) return;
      _cover(
        () => showAppSheet<void>(
          context,
          builder: (sheetContext, controller) => Navigator(
            onGenerateRoute: (_) => CupertinoPageRoute<void>(
              builder: (context) => BooruFeedView(booru: taste.booru, servers: [server], initialQuery: query, onBack: () => Navigator.of(sheetContext).pop()),
            ),
          ),
        ),
      );
    } else {
      taste.comics.search(context, query);
    }
  }

  // MARK: Layout

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Android hides its bars while reading; keep the iOS clearance for the camera and home edge.
    final safe = EdgeInsets.fromLTRB(media.padding.left, math.max(media.padding.top, 62), media.padding.right, math.max(media.padding.bottom, 34));
    final palette = widget.palette;
    return CupertinoTheme(
      data: tegnalTheme(Brightness.dark),
      child: ColoredBox(
        color: palette.inkColor,
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Transform.scale(
            scale: 1 - math.min(0.08, _drag / 3000),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 600;
                final width = compact ? constraints.maxWidth : math.min(constraints.maxWidth, constraints.maxHeight * 0.62);
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    if (!compact)
                      Positioned.fill(
                        child: Opacity(opacity: 0.45, child: RecapColorField(palette: palette)),
                      ),
                    SizedBox(
                      width: width,
                      height: constraints.maxHeight,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _down,
                        onPointerMove: _move,
                        onPointerUp: (event) => _up(event, width),
                        onPointerCancel: (_) {
                          _pressed = null;
                          setState(() => _holding = false);
                          _sync();
                        },
                        child: ClipRect(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 420),
                            switchInCurve: Curves.easeOutCubic,
                            transitionBuilder: (child, animation) {
                              final entering = child.key == ValueKey(_page);
                              if (!entering || MediaQuery.disableAnimationsOf(context)) return FadeTransition(opacity: animation, child: child);
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(begin: Offset(_forward ? 1 : -1, 0), end: Offset.zero).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                            child: RecapPageView(key: ValueKey(_page), page: _page, recap: widget.recap, palette: palette, safeArea: safe, actions: _actions),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: width, height: constraints.maxHeight, child: _chrome(safe)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _chrome(EdgeInsets safe) {
    const white = Color(0xFFFFFFFF);
    Widget button(IconData icon, String label, VoidCallback? onTap, {Color color = white}) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 17,
            color: color,
            shadows: const [Shadow(color: Color(0x59000000), blurRadius: 8)],
          ),
        ),
      ),
    );
    final last = _index == _pages.length - 1;
    // The persona page is printed on paper, so its arrows take the paper's ink.
    final arrows = _page == RecapPage.persona ? widget.palette.paperInkColor : white;
    return Padding(
      padding: EdgeInsets.only(top: safe.top),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                for (var position = 0; position < _pages.length; position++) ...[
                  if (position > 0) const SizedBox(width: 4),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _progress,
                      builder: (context, _) {
                        final fraction = position < _index
                            ? 1.0
                            : position > _index
                            ? 0.0
                            : (position == _pages.length - 1 ? 1.0 : _progress.value);
                        return Container(
                          height: 2.5,
                          decoration: const ShapeDecoration(color: Color(0x47FFFFFF), shape: StadiumBorder()),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: fraction,
                            child: Container(
                              decoration: const ShapeDecoration(color: white, shape: StadiumBorder()),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 0),
            child: Row(
              children: [
                Text('RECAP', style: RecapType.display(15, color: white)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    RecapFormat.title(widget.recap),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RecapType.folio(11, color: white.withValues(alpha: 0.75)),
                  ),
                ),
                button(CupertinoIcons.square_arrow_up, L10n.text('Share'), _share),
                button(CupertinoIcons.xmark, L10n.text('Close'), _close),
              ],
            ),
          ),
          const Spacer(),
          if (_accessible || !last)
            Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + safe.bottom),
              child: Row(
                children: [
                  const Spacer(),
                  Opacity(
                    opacity: _index == 0 ? 0.35 : 1,
                    child: button(CupertinoIcons.chevron_left, L10n.text('Previous card'), _index == 0 ? null : () => _go(_index - 1), color: arrows),
                  ),
                  button(CupertinoIcons.chevron_right, L10n.text('Next card'), () => _go(_index + 1), color: arrows),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
