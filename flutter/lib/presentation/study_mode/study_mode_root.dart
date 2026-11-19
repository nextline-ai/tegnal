import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';

import '../../core/booru/booru_models.dart';
import '../../core/generation/generation_store.dart';
import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/study/study_speed.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../generation/generator_account_view.dart';
import '../generation/generator_sheet.dart';
import '../generation/generator_view.dart';
import '../settings/settings_rows.dart';
import '../study/study_guide_view.dart';
import '../study/study_tag_view.dart';
import '../study/study_widgets.dart';
import 'study_award_views.dart';
import 'study_kit.dart';
import 'study_lesson_view.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';
import 'study_speed_view.dart';

// Learning mode's frame: its tabs, its dock and its top bar, laid over the library. Ported from `StudyModeRoot.swift`
// and the way `AppRootTabView.swift` lays the mode over the library.

// MARK: - Fixture seeds

/// `--study-seed-path=<lesson>`: every lesson before that one starts finished.
const String _seedPath = String.fromEnvironment('TEGNAL_STUDY_SEED');

/// `--study-seed-xp=<n>`: that much experience earned today.
const int _seedXP = int.fromEnvironment('TEGNAL_STUDY_XP');

/// `--study-seed-tags=<n>`: the first n tags answered once, the first two wrongly as well.
const int _seedTags = int.fromEnvironment('TEGNAL_STUDY_TAGS');

// MARK: - Presenting

/// Opens a page full screen over everything, as `appFullScreenCover` does. The future completes when it is closed.
Future<T?> _cover<T>(BuildContext context, WidgetBuilder builder) => Navigator.of(context, rootNavigator: true).push<T>(
  PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, animation, secondary) => builder(context),
    transitionsBuilder: (context, animation, secondary, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

/// `.appSheet { NavigationStack { … } }` with a Close button: a sheet with its own navigation stack, whose first page's
/// back button closes the sheet.
Future<void> _showStudySheet(BuildContext context, WidgetBuilder builder) => showAppSheet<void>(
  context,
  builder: (sheetContext, controller) {
    final sheet = Navigator.of(sheetContext);
    return StudyPresentation(
      sheet: true,
      child: Navigator(
        onGenerateRoute: (_) => CupertinoPageRoute<void>(
          builder: (context) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) sheet.pop();
            },
            child: builder(context),
          ),
        ),
      ),
    );
  },
);

// MARK: - Over the library

/// Lays learning mode over the library, as `AppRootTabView` does: while [StudyMode.active], [StudyModeRoot] covers the
/// whole screen, the library's tab bar included, and the library waits underneath, out of reach of taps and of
/// VoiceOver. Entering and leaving fade and settle from a slightly larger size (`.snappy(duration: 0.35)`).
class StudyModeOverlay extends StatelessWidget {
  const StudyModeOverlay({super.key, required this.booru, required this.child, this.mode});

  /// The image library's context, which learning mode reads from.
  final BooruContext booru;

  /// The library.
  final Widget child;

  /// The mode to follow; null is [StudyMode.shared].
  final StudyMode? mode;

  static final _spring = StudySpring(0.35, 0.15);

  @override
  Widget build(BuildContext context) {
    final mode = this.mode ?? StudyMode.shared;
    return ListenableBuilder(
      listenable: mode,
      builder: (context, _) {
        final studying = mode.active;
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              ignoring: studying,
              child: ExcludeSemantics(excluding: studying, child: child),
            ),
            AnimatedSwitcher(
              duration: _spring.settle,
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
              transitionBuilder: (child, animation) => AnimatedBuilder(
                animation: animation,
                child: child,
                builder: (context, child) {
                  final t = _spring.transform(animation.value);
                  return Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.scale(scale: 1.03 - 0.03 * t, child: child),
                  );
                },
              ),
              child: studying ? StudyModeRoot(key: const ValueKey('study.root'), booru: booru, mode: mode) : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}

// MARK: - Root

/// `StudyModeRoot`: learning mode's own screens and its own dock, in place of the library's.
class StudyModeRoot extends StatefulWidget {
  const StudyModeRoot({super.key, required this.booru, this.mode, this.generation});

  final BooruContext booru;

  /// The mode to follow; null is [StudyMode.shared].
  final StudyMode? mode;

  /// The generator's store; null is the app's own. Tests pass one of their own.
  final GenerationStore? generation;

  @override
  State<StudyModeRoot> createState() => _StudyModeRootState();
}

class _StudyModeRootState extends State<StudyModeRoot> {
  late final StudyModeModel model = StudyModeModel(widget.booru);
  StudyMode get mode => widget.mode ?? StudyMode.shared;
  BooruContext get booru => widget.booru;

  /// The lesson being played, while its page is up.
  StudyLessonSession? _session;

  /// The speed round being played, while its page is up.
  StudySpeedRound? _speed;

  /// The lesson that has just been finished, while the path celebrates it.
  String? _celebrating;

  /// The lesson the open session finished, until its page has closed.
  String? _finished;
  bool _paradeOpen = false;

  /// Whether this visit's opening question or celebration has been shown.
  bool _greeted = false;

  /// The tabs opened so far. A tab is built the first time it is opened and kept from then on.
  final Set<StudyTab> _opened = {};

  /// The dock's height with the bottom safe area, which the tabs keep clear of.
  double? _dockHeight;

  @override
  void initState() {
    super.initState();
    if (booru.fixture) _seed();
    model.reload();
    model.addListener(_changed);
    mode.addListener(_changed);
    booru.store.addListener(_storeChanged);
    booru.state.addListener(_storeChanged);
    StudySound.warm();
    _opened.add(mode.tab);
    // A learner who already has servers says once which one the pictures come from.
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    mode.removeListener(_changed);
    booru.store.removeListener(_storeChanged);
    booru.state.removeListener(_storeChanged);
    _session?.removeListener(_sessionChanged);
    model.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _opened.add(mode.tab));
  }

  void _storeChanged() => model.reload();

  /// For tests and screenshots, when the app runs with a fixture: the seeds the iOS DEBUG launch arguments plant.
  void _seed() {
    final study = booru.store.studyStore;
    try {
      if (_seedPath.isNotEmpty) {
        final records = study.lessons();
        for (final lesson in model.path.lessons.takeWhile((lesson) => lesson.id != _seedPath)) {
          if (records[lesson.id] == null) study.earn(15, lesson: lesson.id, stars: 3);
        }
        booru.booruDefaults.set(StudyServer.key, StudyServer.recommended(StudyServer.choices(booru.store)).id);
      }
      if (_seedXP > 0 && StudyGame.of(days: study.days(), goal: model.goal).xp == 0) study.earn(_seedXP);
      if (_seedTags > 0 && study.progress().length < _seedTags) {
        for (final (index, tag) in model.curriculum.tags.take(_seedTags).indexed) {
          if (index < 2) study.answer(tag.name, right: false);
          study.answer(tag.name, right: true);
        }
      }
      // Badges the seeds earn are not celebrated: the seeded lessons were never played.
      if (_seedPath.isNotEmpty || _seedXP > 0 || _seedTags > 0) study.markSeen([for (final award in model.refreshAwards()) award.id]);
    } on Object {
      // A seed that cannot be written leaves the mode as it is.
    }
  }

  void _greet() {
    if (_greeted || !mounted) return;
    _greeted = true;
    if (model.needsServer) {
      _chooseServer();
    } else {
      _celebrate();
    }
  }

  Future<void> _chooseServer() => showAppSheet<void>(
    context,
    medium: true,
    builder: (context, controller) => StudyServerPicker(model: model, controller: controller),
  );

  /// Shows the badges earned since the last look that no lesson's results have shown, such as one for a picture
  /// generated.
  void _celebrate() {
    final unseen = model.refreshAwards();
    model.reload();
    if (unseen.isEmpty || _session != null || _speed != null || _paradeOpen) return;
    try {
      booru.store.studyStore.markSeen([for (final award in unseen) award.id]);
    } on Object {
      // Shown again next time.
    }
    // A cover cannot go up while another is on its way down. A long backlog, as after an update, shows only its last few.
    final shown = unseen.sublist(math.max(0, unseen.length - 3));
    _paradeOpen = true;
    Future<void>.delayed(const Duration(milliseconds: 450), () async {
      if (!mounted) {
        _paradeOpen = false;
        return;
      }
      await _cover<void>(context, (context) => StudyAwardParade(awards: shown, done: () => Navigator.of(context).pop()));
      _paradeOpen = false;
      if (mounted) model.reload();
    });
  }

  /// Starts a lesson: every lesson, review and practice round of the mode begins here, in a page of its own.
  Future<void> _start(StudyLessonPlan plan) async {
    if (_session != null) return;
    // Lessons of an add-on track can teach tags of their own, so the model's curriculum is used.
    final session = StudyLessonSession(
      plan: plan,
      store: booru.store,
      source: booru.source,
      server: model.server,
      engine: StudyEngine(curriculum: model.curriculum),
    );
    _session = session;
    session.addListener(_sessionChanged);
    await _cover<void>(context, (context) => StudyPlayView(booru: booru, session: session, model: model));
    session.removeListener(_sessionChanged);
    _session = null;
    // The page has let the session go; the root made it and ends it.
    session.dispose();
    if (mounted) _closed();
  }

  /// The path behind a finished lesson is already up to date when the lesson closes.
  void _sessionChanged() {
    final session = _session;
    if (session == null || session.phase != StudyLessonPhase.finished || _finished != null) return;
    model.reload();
    _finished = session.plan.lesson?.id;
  }

  /// Back on the path after a lesson: the stop just finished bursts, and the numbers at the top count up.
  void _closed() {
    model.reload();
    _celebrate();
    final done = _finished;
    if (done == null) return;
    _finished = null;
    mode.tab = StudyTab.path;
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
      setState(() => _celebrating = done);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      StudySound.star2.play();
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      if (mounted && _celebrating == done) setState(() => _celebrating = null);
    }());
  }

  Future<void> _startSpeed() async {
    if (_speed != null) return;
    final round = StudySpeedRound(store: booru.store, curriculum: model.curriculum);
    _speed = round;
    await _cover<void>(context, (context) => StudySpeedView(round: round));
    _speed = null;
    round.dispose();
    if (!mounted) return;
    model.reload();
    _celebrate();
  }

  Future<void> _openAwards() => _cover<void>(context, (context) => StudyAwardsGallery(model: model));

  Widget _page(StudyTab tab) => switch (tab) {
    StudyTab.path => StudyPathView(model: model, celebrating: _celebrating, start: _start),
    StudyTab.practice => StudyPracticeView(model: model, start: _start, startSpeed: _startSpeed),
    StudyTab.dex => StudyDexView(model: model),
    StudyTab.lab => StudyLabView(model: model, start: _start, closed: _celebrate, generation: widget.generation),
    StudyTab.me => StudyMeView(model: model, chooseServer: _chooseServer, openAwards: _openAwards, mode: mode),
  };

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final media = MediaQuery.of(context);
    final dock = _dockHeight ?? 80 + media.padding.bottom;
    return ColoredBox(
      color: theme.background,
      child: DefaultTextStyle(
        style: StudyTheme.body().copyWith(color: theme.ink),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.only(top: media.padding.top, left: media.padding.left, right: media.padding.right),
              child: StudyHUD(model: model, mode: mode),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: MediaQuery(
                      data: media.copyWith(
                        padding: media.padding.copyWith(top: 0, bottom: dock),
                        viewPadding: media.viewPadding.copyWith(top: 0, bottom: dock),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // The tab on screen is laid last, over the ones kept underneath.
                          for (final tab in [
                            for (final tab in StudyTab.values)
                              if (_opened.contains(tab) && tab != mode.tab) tab,
                            mode.tab,
                          ])
                            KeyedSubtree(
                              key: ValueKey(tab),
                              child: _TabLayer(shown: tab == mode.tab, child: _page(tab)),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _SizeReporter(
                      onSize: (size) {
                        if (_dockHeight != size.height) setState(() => _dockHeight = size.height);
                      },
                      child: Padding(
                        padding: EdgeInsets.only(bottom: media.padding.bottom),
                        child: StudyDock(selection: mode.tab, onSelected: (tab) => mode.tab = tab),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tab of the root: shown, or kept faded out underneath (`opacity`, `allowsHitTesting`, `accessibilityHidden`),
/// crossing over in 0.2 s.
class _TabLayer extends StatelessWidget {
  const _TabLayer({required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: shown ? 1 : 0,
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
    curve: Curves.easeInOut,
    child: IgnorePointer(
      ignoring: !shown,
      child: ExcludeSemantics(excluding: !shown, child: child),
    ),
  );
}

/// Reports its child's size after each layout.
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);
  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (_reported == size) return;
    _reported = size;
    final reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(reported));
  }
}

// MARK: - Dock

/// `StudyDock`: learning mode's own tab bar. The highlight slides to the chosen tab, whose symbol bounces.
class StudyDock extends StatefulWidget {
  const StudyDock({super.key, required this.selection, required this.onSelected});

  /// The tab on screen.
  final StudyTab selection;

  /// Called with the tab tapped.
  final ValueChanged<StudyTab> onSelected;

  @override
  State<StudyDock> createState() => _StudyDockState();
}

class _StudyDockState extends State<StudyDock> {
  /// How many times each tab has been chosen. Its symbol bounces when it is chosen, not when it is left.
  final Map<StudyTab, int> _chosenCount = {};
  static final _slide = StudySpring(0.32, 0.22);

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final tabs = StudyTab.values;
    final index = tabs.indexOf(widget.selection);
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 6, bottom: 4),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: ShapeDecoration(
              color: theme.surface,
              shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
            ),
            foregroundDecoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: theme.line, width: 2),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 2.0;
                final width = (constraints.maxWidth - spacing * (tabs.length - 1)) / tabs.length;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      key: const Key('study.dock.highlight'),
                      left: index * (width + spacing),
                      top: 0,
                      bottom: 0,
                      width: width,
                      duration: reduce ? Duration.zero : _slide.settle,
                      curve: _slide,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: theme.primary.withValues(alpha: 0.14),
                          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (final (position, tab) in tabs.indexed) ...[if (position > 0) const SizedBox(width: spacing), Expanded(child: _item(tab, theme))],
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(StudyTab tab, StudyTheme theme) {
    final chosen = tab == widget.selection;
    final color = chosen ? theme.primary : theme.muted;
    return Semantics(
      key: Key('study.dock.${tab.name}'),
      button: true,
      selected: chosen,
      label: tab.title,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          StudySound.tap.play();
          if (!chosen) setState(() => _chosenCount[tab] = (_chosenCount[tab] ?? 0) + 1);
          widget.onSelected(tab);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Bounce(
                count: _chosenCount[tab] ?? 0,
                child: StudyIcon(tab.symbol, size: 21, color: color),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(tab.title, maxLines: 1, style: StudyTheme.body(11, StudyTheme.bold).copyWith(color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.symbolEffect(.bounce, value:)`: the symbol squeezes and springs back each time [count] changes.
class _Bounce extends StatefulWidget {
  const _Bounce({required this.count, required this.child});
  final int count;
  final Widget child;

  @override
  State<_Bounce> createState() => _BounceState();
}

class _BounceState extends State<_Bounce> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  static final _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.82).chain(CurveTween(curve: Curves.easeOut)), weight: 25),
    TweenSequenceItem(tween: Tween(begin: 0.82, end: 1.14).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.14, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 40),
  ]);

  @override
  void didUpdateWidget(_Bounce old) {
    super.didUpdateWidget(old);
    if (old.count != widget.count && !MediaQuery.disableAnimationsOf(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) => Transform.scale(scale: _controller.isAnimating ? _scale.evaluate(_controller) : 1, child: child),
  );
}

// MARK: - HUD

/// `StudyHUD`: the bar above every tab: the streak, the experience, today's goal and the way back to the library.
class StudyHUD extends StatelessWidget {
  const StudyHUD({super.key, required this.model, this.mode});
  final StudyModeModel model;

  /// The mode the exit button leaves; null is [StudyMode.shared].
  final StudyMode? mode;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final game = model.game;
    final streak = model.summary.streak;
    return ColoredBox(
      color: theme.background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: L10n.text('Back to the Library'),
              excludeSemantics: true,
              child: GestureDetector(
                key: const Key('study.exit'),
                behavior: HitTestBehavior.opaque,
                onTap: () => (mode ?? StudyMode.shared).leave(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: ShapeDecoration(color: theme.surface, shape: const CircleBorder()),
                  foregroundDecoration: ShapeDecoration(
                    shape: CircleBorder(side: BorderSide(color: theme.line, width: 2)),
                  ),
                  child: Center(child: StudyIcon('books.vertical.fill', size: 17, color: theme.muted)),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Semantics(
              key: const Key('study.hud.streak'),
              label: '${L10n.text('Day streak')} $streak',
              excludeSemantics: true,
              child: StudyStat(symbol: 'flame.fill', color: streak > 0 ? theme.flame : theme.muted, value: '$streak'),
            ),
            const SizedBox(width: 16),
            Semantics(
              key: const Key('study.hud.xp'),
              label: 'XP ${game.xp}',
              excludeSemantics: true,
              child: StudyStat(symbol: 'bolt.fill', color: theme.gold, value: '${game.xp}'),
            ),
            const Spacer(),
            const SizedBox(width: 8),
            Semantics(
              key: const Key('study.hud.goal'),
              label: '${L10n.text("Today's goal")} ${game.today}/${game.goal}',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 74,
                    child: StudyBar(value: game.goalProgress, color: game.goalMet ? theme.good : theme.gold, height: 12),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${math.min(game.today, game.goal)}/${game.goal}',
                    style: StudyTheme.body(14, StudyTheme.heavy).copyWith(color: theme.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// MARK: - Path

/// A scrolling column of the mode's width (`.frame(maxWidth:).frame(maxWidth: .infinity)`), clear of the dock.
class _Scroll extends StatelessWidget {
  const _Scroll({required this.child, this.maxWidth = 560, this.padding = const EdgeInsets.only(left: 16, right: 16, top: 8)});
  final Widget child;
  final double maxWidth;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context);
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: inset.bottom, left: inset.left, right: inset.right),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// `StudyPathView`: the map, a zig-zag of stops under each section's banner.
class StudyPathView extends StatefulWidget {
  const StudyPathView({super.key, required this.model, this.celebrating, required this.start});
  final StudyModeModel model;

  /// The lesson that has just been finished, while it bursts.
  final String? celebrating;
  final ValueChanged<StudyLessonPlan> start;

  static const sway = <double>[0, 58, 86, 58, 0, -58, -86, -58];

  @override
  State<StudyPathView> createState() => _StudyPathViewState();
}

class _StudyPathViewState extends State<StudyPathView> {
  /// True once the learner has closed the start card, until a lesson is finished.
  bool _dismissed = false;
  final _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  String? _current;

  StudyModeModel get model => widget.model;
  StudyPathLesson? get _currentLesson => model.shownPath.current(model.records);

  GlobalKey _key(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _current = _currentLesson?.id;
    model.addListener(_modelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current case final id?) _scrollTo(id, Duration.zero, Curves.linear);
    });
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _modelChanged() {
    final id = _currentLesson?.id;
    if (id == _current) return;
    _current = id;
    if (mounted) setState(() => _dismissed = false);
    if (id != null && widget.celebrating == null) {
      final spring = StudySpring(0.55, 0);
      _scrollTo(id, spring.settle, spring);
    }
  }

  @override
  void didUpdateWidget(StudyPathView old) {
    super.didUpdateWidget(old);
    if (old.celebrating == widget.celebrating) return;
    // A stop just finished is shown bursting first; then the path glides on to the next one.
    if (widget.celebrating case final done?) {
      final snappy = StudySpring(0.25, 0.15);
      _scrollTo(done, snappy.settle, snappy);
    } else if (_currentLesson case final current?) {
      final glide = StudySpring(0.9, 0.15);
      _scrollTo(current.id, glide.settle, glide);
    }
  }

  void _scrollTo(String id, Duration duration, Curve curve) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[id]?.currentContext;
      if (target == null || !mounted) return;
      final reduce = MediaQuery.disableAnimationsOf(context);
      Scrollable.ensureVisible(target, alignment: 0.5, duration: reduce ? Duration.zero : duration, curve: curve);
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentLesson;
    final inset = MediaQuery.paddingOf(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final cardSpring = StudySpring(widget.celebrating != null ? 0.35 : 0.3, 0.2);
    final showsCard = current != null && !_dismissed && widget.celebrating == null;
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.only(left: inset.left, right: inset.right),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    for (final section in model.shownPath.sections) ...[
                      Padding(padding: const EdgeInsets.only(top: 18, bottom: 22), child: _banner(section)),
                      if (section.lessons.isEmpty) _Locked(),
                      for (final (index, lesson) in section.lessons.indexed)
                        Padding(
                          key: _key(lesson.id),
                          padding: const EdgeInsets.only(bottom: 20),
                          child: _row(lesson, index, studyHex(section.color), current: current?.id == lesson.id),
                        ),
                    ],
                    SizedBox(height: 190 + inset.bottom),
                  ],
                ),
              ),
            ),
          ),
        ),
        // The lesson the learner is on offers its start at once; any other stop does when tapped.
        Positioned(
          left: inset.left,
          right: inset.right,
          bottom: inset.bottom,
          child: AnimatedSwitcher(
            duration: reduce ? Duration.zero : cardSpring.settle,
            transitionBuilder: (child, animation) => AnimatedBuilder(
              animation: animation,
              child: child,
              builder: (context, child) {
                final t = cardSpring.transform(animation.value);
                return FractionalTranslation(
                  translation: Offset(0, 1 - t),
                  child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
                );
              },
            ),
            child: showsCard ? KeyedSubtree(key: ValueKey(current.id), child: _card(current)) : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _banner(StudyPathSection section) {
    final done = section.lessons.where((lesson) => model.records[lesson.id] != null).length;
    final color = studyHex(section.color);
    final empty = section.lessons.isEmpty;
    const white = Color(0xFFFFFFFF);
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22));
    return Semantics(
      key: Key('study.section.${section.id}'),
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 5,
              bottom: -5,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: studyEdge(color).withValues(alpha: empty ? 0.45 : 1),
                  shape: shape,
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: ShapeDecoration(color: empty ? color.withValues(alpha: 0.45) : color, shape: shape),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(section.title.resolved(), style: StudyTheme.title(22).copyWith(color: white)),
                  const SizedBox(height: 6),
                  Text(section.summary.resolved(), style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: white.withValues(alpha: 0.9))),
                  if (!empty) ...[
                    const SizedBox(height: 6 + 4),
                    Row(
                      children: [
                        Expanded(
                          child: StudyBar(value: done / section.lessons.length, color: white, height: 10, track: const Color(0x38000000)),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$done/${section.lessons.length}',
                          style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: white, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(StudyPathLesson lesson, int index, Color color, {required bool current}) {
    final sway = StudyPathView.sway[index % StudyPathView.sway.length];
    final pop = StudySpring(0.5, 0.5);
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Center(
          child: Transform.translate(
            offset: Offset(sway, 0),
            child: _node(lesson, color, current: current),
          ),
        ),
        // The guide stands beside the lesson the learner is on, on the side the path leaves free.
        Positioned.fill(
          child: OverflowBox(
            alignment: sway > 0 ? Alignment.centerLeft : Alignment.centerRight,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : pop.settle,
              transitionBuilder: (child, animation) => AnimatedBuilder(
                animation: animation,
                child: child,
                builder: (context, child) {
                  final t = pop.transform(animation.value);
                  return Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.scale(scale: 0.2 + 0.8 * t, child: child),
                  );
                },
              ),
              child: current
                  ? const Padding(
                      key: ValueKey('mascot'),
                      padding: EdgeInsets.symmetric(horizontal: 18),
                      child: StudyMascot(pose: StudyMascotPose.fullBody, size: 104),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _node(StudyPathLesson lesson, Color color, {required bool current}) {
    final theme = StudyTheme.of(context);
    final record = model.records[lesson.id];
    final open = record != null || current;
    final size = lesson.kind == StudyPathLessonKind.boss ? 92.0 : 76.0;
    final celebrating = widget.celebrating == lesson.id;
    final symbol = open ? (record != null && lesson.kind != StudyPathLessonKind.boss ? 'checkmark' : lesson.symbol) : 'lock.fill';
    Widget button = StudyPressButton(
      color: open ? color : theme.sunken,
      ink: open ? const Color(0xFFFFFFFF) : theme.muted,
      radius: size / 2,
      depth: 7,
      onPressed: open
          ? () {
              StudySound.tap.play();
              widget.start(StudyLessonPlan.lesson(lesson));
            }
          : null,
      child: SizedBox.square(
        dimension: size,
        child: Center(child: StudyIcon(symbol, size: size * 0.38)),
      ),
    );
    button = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // The stop the learner is on breathes, so that the eye lands on it.
        if (current)
          Positioned(
            left: -9,
            right: -9,
            top: -9,
            bottom: -9,
            child: _Repeat(
              duration: const Duration(milliseconds: 900),
              builder: (context, t) {
                final scale = 1 + 0.12 * t;
                return Center(
                  child: Opacity(
                    opacity: (2.12 - scale).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        width: size + 18,
                        height: size + 18,
                        decoration: ShapeDecoration(
                          shape: CircleBorder(side: BorderSide(color: color.withValues(alpha: 0.35), width: 6)),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        _CelebrateBounce(active: celebrating, child: button),
        if (celebrating) const Positioned.fill(child: StudyBurst(trigger: 1, count: 22, reach: 110, onAppear: true)),
      ],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (current) ...[
          _Repeat(
            duration: const Duration(milliseconds: 800),
            builder: (context, t) => Transform.translate(
              offset: Offset(0, -5 * t),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: ShapeDecoration(color: theme.surface, shape: const StadiumBorder()),
                foregroundDecoration: ShapeDecoration(
                  shape: StadiumBorder(side: BorderSide(color: theme.line, width: 2)),
                ),
                child: Text(L10n.text('Start'), style: StudyTheme.body(14, StudyTheme.heavy).copyWith(color: color)),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Semantics(
          key: Key('study.node.${lesson.id}'),
          container: true,
          label: lesson.title.resolved(),
          value: L10n.text(
            record != null
                ? 'Lesson Done'
                : current
                ? 'Next'
                : 'Locked',
          ),
          child: button,
        ),
        if (record != null) ...[const SizedBox(height: 8), StudyStars(count: record.stars, size: 13)],
        const SizedBox(height: 8),
        Text(
          lesson.title.resolved(),
          textAlign: TextAlign.center,
          style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: open ? theme.ink : theme.muted),
        ),
      ],
    );
  }

  /// What a tapped lesson is, and the button that starts it.
  Widget _card(StudyPathLesson lesson) {
    final theme = StudyTheme.of(context);
    final record = model.records[lesson.id];
    final detail = switch (lesson.kind) {
      StudyPathLessonKind.tags => L10n.text('New tags: %@', ['${lesson.tags?.length ?? 0}']),
      StudyPathLessonKind.concept => lesson.summary?.resolved() ?? L10n.text('An idea, explained from the start'),
      StudyPathLessonKind.boss => L10n.text('Put prompts together yourself'),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, bottom: 8),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: StudyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(lesson.title.resolved(), style: StudyTheme.title(21).copyWith(color: theme.ink)),
                          const SizedBox(height: 4),
                          Text(detail, style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted)),
                        ],
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: L10n.text('Close'),
                      excludeSemantics: true,
                      child: GestureDetector(
                        key: const Key('study.closeCard'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _dismissed = true),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: StudyIcon('xmark', size: 13, color: theme.muted),
                        ),
                      ),
                    ),
                  ],
                ),
                if (record != null) ...[const SizedBox(height: 12), StudyStars(count: record.stars, size: 18)],
                const SizedBox(height: 12),
                StudyMainButton(
                  key: const Key('study.startLesson'),
                  title: L10n.text(record == null ? 'Start  +%@ XP' : 'Play Again  +%@ XP', ['${StudyGame.earned(mistakes: 1, bestCombo: 0)}']),
                  symbol: 'play.fill',
                  onPressed: () {
                    StudySound.tap.play();
                    widget.start(StudyLessonPlan.lesson(lesson));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Opens in a coming update", under a section with no lessons yet.
class _Locked extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StudyIcon('lock.fill', size: 14, color: theme.muted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(L10n.text('Opens in a coming update'), style: StudyTheme.body(14, StudyTheme.bold).copyWith(color: theme.muted)),
          ),
        ],
      ),
    );
  }
}

/// `.phaseAnimator([a, b]) { … } animation: { _ in .easeInOut(duration:) }`: a value that goes back and forth from 0
/// to 1 for as long as it is on screen. It rests at 0 when motion is reduced.
class _Repeat extends StatefulWidget {
  const _Repeat({required this.duration, required this.builder});
  final Duration duration;
  final Widget Function(BuildContext context, double t) builder;

  @override
  State<_Repeat> createState() => _RepeatState();
}

class _RepeatState extends State<_Repeat> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: widget.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run = !MediaQuery.disableAnimationsOf(context);
    if (run && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!run && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _controller, builder: (context, _) => widget.builder(context, Curves.easeInOut.transform(_controller.value)));
}

/// `.phaseAnimator([1.0, 1.3, 1.0], trigger:)`: grows and springs back each time [active] changes.
class _CelebrateBounce extends StatefulWidget {
  const _CelebrateBounce({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_CelebrateBounce> createState() => _CelebrateBounceState();
}

class _CelebrateBounceState extends State<_CelebrateBounce> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  static final _spring = StudySpring(0.3, 0.6);

  @override
  void didUpdateWidget(_CelebrateBounce old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active && !MediaQuery.disableAnimationsOf(context)) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      if (!_controller.isAnimating) return child!;
      final t = _controller.value;
      final scale = t < 0.5 ? 1 + 0.3 * _spring.transform(t * 2) : 1.3 - 0.3 * _spring.transform((t - 0.5) * 2);
      return Transform.scale(scale: scale, child: child);
    },
  );
}

/// `StudyStars`: three stars, as many of them gold as were earned.
class StudyStars extends StatelessWidget {
  const StudyStars({super.key, required this.count, this.size = 16});
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return Semantics(
      label: L10n.text('Stars: %@', ['$count']),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < 3; index++) ...[
            if (index > 0) const SizedBox(width: 3),
            StudyIcon('star.fill', size: size, color: index < count ? theme.gold : theme.line),
          ],
        ],
      ),
    );
  }
}

// MARK: - Practice

/// `StudyPracticeView`: today's review, Weak Spots and the speed round.
class StudyPracticeView extends StatelessWidget {
  const StudyPracticeView({super.key, required this.model, required this.start, required this.startSpeed});
  final StudyModeModel model;
  final ValueChanged<StudyLessonPlan> start;
  final VoidCallback startSpeed;

  int get _met => StudySpeedRound.met(model.progress, curriculum: model.curriculum).length;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final due = model.summary.due;
    final met = _met;
    return _Scroll(
      child: Column(
        children: [
          StudyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StudyMascot(pose: due > 0 ? StudyMascotPose.read : StudyMascotPose.cheer, size: 84),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(L10n.text("Today's Review"), style: StudyTheme.title(21).copyWith(color: theme.ink)),
                          const SizedBox(height: 4),
                          Text(
                            due > 0
                                ? L10n.text('Tags due again: %@', ['$due'])
                                : L10n.text('Nothing is due. Tags come back here just before you would forget them.'),
                            style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                StudyMainButton(
                  key: const Key('study.review'),
                  title: L10n.text('Review'),
                  color: theme.good,
                  symbol: 'arrow.triangle.2.circlepath',
                  onPressed: due == 0
                      ? null
                      : () {
                          StudySound.tap.play();
                          start(StudyLessonPlan.review);
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _game(
            context,
            'target',
            theme.bad,
            'Weak Spots',
            model.weak > 0 ? L10n.text('Tags you have missed: %@. Ask them again.', ['${model.weak}']) : L10n.text('Tags you miss in lessons gather here.'),
            enabled: model.weak > 0,
            id: 'study.weak',
            action: () => start(StudyLessonPlan.weak),
          ),
          const SizedBox(height: 16),
          _game(
            context,
            'timer',
            theme.flame,
            'Speed Round',
            met >= StudySpeedRound.needed ? L10n.text('As many as you can in a minute.') : L10n.text('Opens once you have learned 4 tags.'),
            enabled: met >= StudySpeedRound.needed,
            id: 'study.speed',
            action: startSpeed,
          ),
        ],
      ),
    );
  }

  Widget _game(
    BuildContext context,
    String symbol,
    Color color,
    String title,
    String detail, {
    required bool enabled,
    required String id,
    required VoidCallback action,
  }) {
    final theme = StudyTheme.of(context);
    return StudyPressButton(
      key: Key(id),
      radius: 20,
      outlined: true,
      onPressed: enabled
          ? () {
              StudySound.tap.play();
              action();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: ShapeDecoration(
                color: enabled ? color : theme.sunken,
                shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Center(child: StudyIcon(enabled ? symbol : 'lock.fill', size: 22, color: enabled ? const Color(0xFFFFFFFF) : theme.muted)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.text(title), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: theme.ink)),
                  const SizedBox(height: 3),
                  Text(detail, style: StudyTheme.body(13, StudyTheme.medium).copyWith(color: theme.muted)),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (enabled) StudyIcon('play.fill', size: 15, color: color),
          ],
        ),
      ),
    );
  }
}

// MARK: - Collection

/// `StudyDexView`: the tags met so far, each opening its page.
class StudyDexView extends StatelessWidget {
  const StudyDexView({super.key, required this.model});
  final StudyModeModel model;

  List<StudyTag> get _met => [
    for (final tag in model.curriculum.tags)
      if (model.progress[tag.name] case final progress? when !progress.isNew) tag,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final met = _met;
    final total = model.summary.total;
    return _Scroll(
      maxWidth: 720,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(L10n.text('Tags collected: %@ of %@', ['${met.length}', '$total']), style: StudyTheme.title(21).copyWith(color: theme.ink)),
          const SizedBox(height: 8),
          StudyBar(value: total == 0 ? 0 : met.length / total, color: theme.primary),
          if (met.isEmpty) ...[
            const SizedBox(height: 14 + 60),
            Center(
              child: Column(
                children: [
                  const StudyMascot(pose: StudyMascotPose.think, size: 110),
                  const SizedBox(height: 12),
                  Text(
                    L10n.text('Tags you learn on the map are kept here.'),
                    textAlign: TextAlign.center,
                    style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.muted),
                  ),
                ],
              ),
            ),
          ],
          if (met.isNotEmpty) ...[
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                // `GridItem(.adaptive(minimum: 150), spacing: 10)`: as many columns of at least 150 as fit.
                const spacing = 10.0;
                final columns = math.max(1, ((constraints.maxWidth + spacing) / (150 + spacing)).floor());
                return Column(
                  children: [
                    for (var row = 0; row * columns < met.length; row++) ...[
                      if (row > 0) const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var column = 0; column < columns; column++) ...[
                            if (column > 0) const SizedBox(width: spacing),
                            Expanded(child: row * columns + column < met.length ? _cell(context, met[row * columns + column]) : const SizedBox()),
                          ],
                        ],
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, StudyTag tag) {
    final theme = StudyTheme.of(context);
    final progress = model.progress[tag.name];
    final step = math.min(progress?.step ?? 0, StudyProgress.learnedStep);
    return StudyPressButton(
      key: Key('study.dex.${tag.name}'),
      radius: 16,
      depth: 4,
      outlined: true,
      onPressed: () => _showStudySheet(context, (context) => StudyTagView(booru: model.booru, name: tag.name)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(tag.english, maxLines: 1, style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: theme.ink)),
            ),
            if (L10n.language != 'en') ...[
              const SizedBox(height: 6),
              Text(
                tag.title(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: StudyTheme.body(13, StudyTheme.medium).copyWith(color: theme.muted),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                for (var index = 0; index < StudyProgress.learnedStep; index++) ...[
                  if (index > 0) const SizedBox(width: 3),
                  Expanded(
                    child: Container(
                      height: 6,
                      decoration: ShapeDecoration(
                        color: index < step ? (progress?.isLearned == true ? theme.good : theme.gold) : theme.sunken,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// MARK: - Studio

/// `StudyLabView`: the Studio, where pictures are generated once an API key is saved.
class StudyLabView extends StatefulWidget {
  const StudyLabView({super.key, required this.model, required this.start, this.closed, this.generation});
  final StudyModeModel model;
  final ValueChanged<StudyLessonPlan> start;

  /// Called when a tool closes: a picture generated in it may have earned a badge.
  final VoidCallback? closed;

  /// The generator's store; null is the app's own.
  final GenerationStore? generation;

  @override
  State<StudyLabView> createState() => _StudyLabViewState();
}

class _StudyLabViewState extends State<StudyLabView> {
  GenerationStore? _generation;

  @override
  void initState() {
    super.initState();
    try {
      _generation = widget.generation ?? widget.model.generation;
    } on Object {
      // Without the app's storage, as in a test, the Studio shows no key.
      _generation = null;
    }
    _generation?.addListener(_changed);
    unawaited(_generation?.load());
  }

  @override
  void dispose() {
    _generation?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Future<void> Function() present) async {
    StudySound.tap.play();
    await present();
    if (mounted) widget.closed?.call();
  }

  void _openKey() {
    final store = _generation;
    if (store == null) return;
    _open(() => showGeneratorSheet<void>(context, (context) => GeneratorAccountView(store: store)));
  }

  @override
  Widget build(BuildContext context) {
    final booru = widget.model.booru;
    return _Scroll(
      child: Column(
        children: [
          _connection(context),
          const SizedBox(height: 16),
          _tool(
            context,
            'generator',
            'wand.and.stars',
            'Generate a Picture',
            'Try a prompt with your own Civitai API key.',
            () => _open(() => _showStudySheet(context, (context) => GeneratorView.forBooru(booru))),
          ),
          const SizedBox(height: 16),
          _tool(
            context,
            'guide',
            'text.book.closed.fill',
            'Writing Prompts',
            'Emphasis, quality tags and what each model recommends.',
            () => _open(() => _showStudySheet(context, (context) => StudyGuideView(booru: booru))),
          ),
        ],
      ),
    );
  }

  /// Generating needs an API key. Until one is saved, this card says so and leads to the lessons that explain it.
  Widget _connection(BuildContext context) {
    final theme = StudyTheme.of(context);
    final connected = _generation?.hasKey ?? false;
    final lesson = widget.model.path.lessons.where((lesson) => lesson.id == 'api-what').firstOrNull;
    return StudyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StudyMascot(pose: connected ? StudyMascotPose.cheer : StudyMascotPose.wave, size: 84),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        StudyIcon(connected ? 'checkmark.seal.fill' : 'key.fill', size: 19, color: connected ? theme.good : theme.ink),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            L10n.text(connected ? 'API Key Connected' : 'Connect an API Key First'),
                            style: StudyTheme.title(19).copyWith(color: connected ? theme.good : theme.ink),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      L10n.text(
                        connected
                            ? 'You can generate pictures. Each one is paid for with Buzz from your Civitai account.'
                            : "Pictures are drawn on Civitai's servers, so the Studio needs your own Civitai API key.",
                      ),
                      style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!connected) ...[
            if (lesson != null) ...[
              const SizedBox(height: 12),
              StudyMainButton(
                key: const Key('study.lab.learn'),
                title: L10n.text('Learn What an API Key Is'),
                symbol: 'graduationcap.fill',
                onPressed: () {
                  StudySound.tap.play();
                  widget.start(StudyLessonPlan.lesson(lesson));
                },
              ),
            ],
            const SizedBox(height: 12),
            StudyMainButton(key: const Key('study.lab.key'), title: L10n.text('Enter the API Key'), color: theme.gold, symbol: 'key.fill', onPressed: _openKey),
          ],
        ],
      ),
    );
  }

  Widget _tool(BuildContext context, String id, String symbol, String title, String detail, VoidCallback open) {
    final theme = StudyTheme.of(context);
    return StudyPressButton(
      key: Key('study.lab.$id'),
      radius: 20,
      outlined: true,
      onPressed: open,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: ShapeDecoration(
                color: theme.primary.withValues(alpha: 0.14),
                shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Center(child: StudyIcon(symbol, size: 22, color: theme.primary)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.text(title), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: theme.ink)),
                  const SizedBox(height: 3),
                  Text(L10n.text(detail), style: StudyTheme.body(13, StudyTheme.medium).copyWith(color: theme.muted)),
                ],
              ),
            ),
            const SizedBox(width: 4),
            StudyIcon('chevron.right', size: 14, color: theme.muted),
          ],
        ),
      ),
    );
  }
}

// MARK: - Me

/// `StudyMeView`: the level, the badges, the daily goal and the mode's settings.
class StudyMeView extends StatefulWidget {
  const StudyMeView({super.key, required this.model, required this.chooseServer, this.openAwards, this.mode});
  final StudyModeModel model;
  final VoidCallback chooseServer;
  final VoidCallback? openAwards;

  /// The mode whose settings are shown; null is [StudyMode.shared].
  final StudyMode? mode;

  @override
  State<StudyMeView> createState() => _StudyMeViewState();
}

class _StudyMeViewState extends State<StudyMeView> {
  StudyModeModel get model => widget.model;
  StudyMode get mode => widget.mode ?? StudyMode.shared;

  Future<void> _confirmReset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Reset study progress?')),
        message: Text(L10n.text('Every tag goes back to not started. This cannot be undone.')),
        actions: [
          CupertinoActionSheetAction(
            key: const Key('study.resetConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('Reset')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset != true) return;
    try {
      model.booru.store.studyStore.reset();
    } on Object {
      // Nothing was reset; the screen reads the store again either way.
    }
    model.reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final game = model.game;
    final canReset = !(game.xp == 0 && model.summary.started == 0);
    final red = CupertinoColors.systemRed.resolveFrom(context);
    return _Scroll(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 16),
      child: Column(
        children: [
          StudyCard(
            child: Row(
              children: [
                const StudyMascot(pose: StudyMascotPose.closeUp, size: 92),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.text('Level %@', ['${game.level}']), style: StudyTheme.title(24).copyWith(color: theme.ink)),
                      const SizedBox(height: 8),
                      StudyBar(value: game.levelProgress, color: theme.gold),
                      const SizedBox(height: 8),
                      Text(
                        '${game.xp % StudyGame.levelSize} / ${StudyGame.levelSize} XP',
                        style: StudyTheme.body(13, StudyTheme.bold).copyWith(color: theme.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          StudyAwardsCard(model: model, open: widget.openAwards ?? () {}),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _tile('flame.fill', theme.flame, '${model.summary.streak}', L10n.text('Day streak'))),
              const SizedBox(width: 10),
              Expanded(child: _tile('checkmark.seal.fill', theme.good, '${model.summary.learned}', L10n.text('Learned'))),
              const SizedBox(width: 10),
              Expanded(child: _tile('bolt.fill', theme.gold, '${game.xp}', 'XP')),
            ],
          ),
          const SizedBox(height: 16),
          StudyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(L10n.text("Today's goal"), style: StudyTheme.body(17, StudyTheme.heavy).copyWith(color: theme.ink)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final (index, goal) in StudyGame.goals.indexed) ...[
                      if (index > 0) const SizedBox(width: 8),
                      Expanded(
                        child: Semantics(
                          selected: model.goal == goal,
                          child: StudyPressButton(
                            key: Key('study.goal.$goal'),
                            color: theme.gold,
                            radius: 14,
                            depth: 4,
                            outlined: model.goal != goal,
                            onPressed: () => model.goal = goal,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('$goal XP', maxLines: 1, style: StudyTheme.body(15, StudyTheme.heavy)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          StudyCard(
            padding: 6,
            child: Column(
              children: [
                Semantics(
                  button: true,
                  child: GestureDetector(
                    key: const Key('study.server'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.chooseServer,
                    child: _row('photo.stack', L10n.text('Pictures From'), model.server.name),
                  ),
                ),
                _divider(theme),
                ListenableBuilder(
                  listenable: mode,
                  builder: (context, _) => _toggle(
                    'graduationcap.fill',
                    L10n.text('Open in Learning Mode'),
                    const Key('study.startInMode'),
                    mode.startsActive,
                    (value) => mode.startsActive = value,
                  ),
                ),
                _divider(theme),
                _toggle('speaker.wave.2.fill', L10n.text('Sound Effects'), const Key('study.sound'), StudySound.isOn, (on) {
                  setState(() => StudySound.isOn = on);
                  if (on) StudySound.right.play();
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
          StudyMainButton(
            key: const Key('study.leave'),
            title: L10n.text('Back to the Library'),
            color: theme.muted,
            symbol: 'books.vertical.fill',
            onPressed: mode.leave,
          ),
          const SizedBox(height: 16 + 4),
          Semantics(
            button: true,
            enabled: canReset,
            child: GestureDetector(
              key: const Key('study.reset'),
              behavior: HitTestBehavior.opaque,
              onTap: canReset ? _confirmReset : null,
              child: Opacity(
                opacity: canReset ? 1 : 0.4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(L10n.text('Reset Study Progress'), style: StudyTheme.body(14, StudyTheme.bold).copyWith(color: red)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(StudyTheme theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Container(height: 1 / MediaQuery.devicePixelRatioOf(context), color: theme.line),
  );

  Widget _label(String symbol, String title) {
    final theme = StudyTheme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Center(child: StudyIcon(symbol, size: 17, color: theme.ink)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(title, style: StudyTheme.body(16, StudyTheme.bold).copyWith(color: theme.ink)),
        ),
      ],
    );
  }

  Widget _toggle(String symbol, String title, Key key, bool value, ValueChanged<bool> changed) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Expanded(child: _label(symbol, title)),
        const SizedBox(width: 8),
        TegnalSwitch(key: key, value: value, onChanged: changed, tint: StudyTheme.of(context).primary),
      ],
    ),
  );

  Widget _tile(String symbol, Color color, String value, String title) {
    final theme = StudyTheme.of(context);
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: ShapeDecoration(
          color: theme.surface,
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18)),
        ),
        foregroundDecoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: theme.line, width: 2),
          ),
        ),
        child: Column(
          children: [
            StudyIcon(symbol, size: 20, color: color),
            const SizedBox(height: 4),
            Text(
              value,
              style: StudyTheme.title(22).copyWith(color: theme.ink, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(title, maxLines: 1, style: StudyTheme.body(12, StudyTheme.bold).copyWith(color: theme.muted)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String symbol, String title, String value) {
    final theme = StudyTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Expanded(child: _label(symbol, title)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: StudyTheme.body(15, StudyTheme.semibold).copyWith(color: theme.muted),
            ),
          ),
          const SizedBox(width: 6),
          StudyIcon('chevron.right', size: 13, color: theme.muted),
        ],
      ),
    );
  }
}

// MARK: - Server

/// `StudyServerPicker`: chooses the one server learning mode shows pictures from.
class StudyServerPicker extends StatelessWidget {
  const StudyServerPicker({super.key, required this.model, this.controller});
  final StudyModeModel model;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final store = model.booru.store;
    final choices = StudyServer.choices(store);
    final suggested = StudyServer.recommended(choices);
    // The suggested server, which is Danbooru when it is there, leads the list.
    final servers = [suggested, ...choices.where((server) => server.id != suggested.id)];
    return ColoredBox(
      color: theme.background,
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) => SingleChildScrollView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.paddingOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.text('Where should the pictures come from?'), style: StudyTheme.title(22).copyWith(color: theme.ink)),
              const SizedBox(height: 12),
              Text(
                L10n.text('Lessons show real pictures from one server. You can change it later under Me.'),
                style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted),
              ),
              for (final server in servers) ...[const SizedBox(height: 12), _choice(context, server, suggested: server.id == suggested.id)],
            ],
          ),
        ),
      ),
    );
  }

  Widget _choice(BuildContext context, BooruServer server, {required bool suggested}) {
    final theme = StudyTheme.of(context);
    final chosen = server.id == model.server.id && !model.needsServer;
    return StudyPressButton(
      key: Key('study.serverChoice.${server.name}'),
      radius: 18,
      outlined: true,
      onPressed: () {
        model.choose(server);
        Navigator.of(context).pop();
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(server.name, style: StudyTheme.body(17, StudyTheme.heavy).copyWith(color: theme.ink)),
                  const SizedBox(height: 3),
                  Text(Uri.tryParse(server.baseURL)?.host ?? '', style: StudyTheme.body(12, StudyTheme.medium).copyWith(color: theme.muted)),
                ],
              ),
            ),
            if (suggested) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: ShapeDecoration(color: theme.good, shape: const StadiumBorder()),
                child: Text(L10n.text('Suggested'), style: StudyTheme.body(12, StudyTheme.heavy).copyWith(color: const Color(0xFFFFFFFF))),
              ),
            ],
            if (chosen) ...[const SizedBox(width: 10), StudyIcon('checkmark.circle.fill', size: 20, color: theme.primary)],
          ],
        ),
      ),
    );
  }
}

// MARK: - Settings

/// `StudyModeSettings`: the setting that opens the app straight into learning mode, and the way in, shown after
/// Safe Mode in both libraries' settings.
class StudyModeSettings extends StatelessWidget {
  const StudyModeSettings({super.key, required this.booru, this.rowColor, this.mode});
  final BooruContext booru;

  /// The rows' colour, as the neighbouring sections use; null is the list row colour.
  final Color? rowColor;

  /// The mode to change; null is [StudyMode.shared].
  final StudyMode? mode;

  @override
  Widget build(BuildContext context) {
    final mode = this.mode ?? StudyMode.shared;
    return ListenableBuilder(
      listenable: mode,
      builder: (context, _) => FormSection(
        prominentHeader: true,
        rowColor: rowColor ?? FormColors.listRow.resolveFrom(context),
        header: Text(L10n.text('Learning Mode')),
        children: [
          SettingsToggleRow(
            key: const Key('settings.startInStudyMode'),
            title: L10n.text('Open in Learning Mode'),
            help: L10n.text(
              'Turning this on opens the app straight into learning mode, where tags for prompting image AI are learned step by step. The library stays one tap away.',
            ),
            value: mode.startsActive,
            onChanged: (value) => mode.startsActive = value,
          ),
          SettingsLinkRow(
            key: const Key('settings.enterStudyMode'),
            title: L10n.text('Enter Learning Mode'),
            tinted: true,
            chevron: false,
            onTap: () => mode.enter(),
          ),
        ],
      ),
    );
  }
}
