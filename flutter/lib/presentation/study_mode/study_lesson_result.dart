import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/study/study_store.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../study/study_result_view.dart' show StudyConfetti;
import 'study_award_views.dart';
import 'study_kit.dart';
import 'study_lesson_parts.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';

// The end of a lesson and the pages after it. Ported from `StudyLessonResult` in `StudyLessonView.swift` and
// `StudyMilestoneView` in `StudyReactions.swift`.

const _white = Color(0xFFFFFFFF);

ShapeBorder _rounded(double radius, [BorderSide side = BorderSide.none]) => RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// A value that follows [on] (0 or 1) along [spring], overshooting as the spring does.
class _Sprung extends StatelessWidget {
  const _Sprung({required this.on, required this.spring, required this.builder, this.child});
  final bool on;
  final StudySpring spring;
  final Widget Function(BuildContext context, double value, Widget? child) builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(end: on ? 1 : 0),
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : spring.settle,
    curve: spring,
    builder: builder,
    child: child,
  );
}

/// A finished lesson: the guide cheers, the stars land one by one, the numbers count up, and anything reached beyond
/// the lesson (a streak, the day's goal, a level, a badge) gets a page of its own afterwards (`StudyLessonResult`).
class StudyLessonResult extends StatefulWidget {
  const StudyLessonResult({super.key, required this.booru, required this.session, required this.model, required this.done});

  final BooruContext booru;
  final StudyLessonSession session;
  final StudyModeModel model;

  /// Called by the last Continue.
  final VoidCallback done;

  @override
  State<StudyLessonResult> createState() => _StudyLessonResultState();
}

class _StudyLessonResultState extends State<StudyLessonResult> {
  static final _pageSpring = StudySpring(0.45, 0.2);

  /// How far the results have unfolded: 1 the guide and title, 2–4 the stars, 5 the tiles, 6 the goal.
  int _stage = 0;
  StudyGame _game = StudyGame();
  int _streak = 0;
  List<StudyDay> _days = const [];
  List<StudyMilestone> _milestones = const [];

  /// Zero shows the results; later pages show the milestones in turn.
  int _page = 0;
  bool _unfolded = false;
  bool _disposed = false;

  StudyLessonSession get _session => widget.session;
  int get _accuracy => _session.asked == 0 ? 100 : ((_session.asked - _session.mistakes) / _session.asked * 100).round();
  bool get _empty => _session.asked == 0 && _session.plan.lesson == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_unfolded) return;
    _unfolded = true;
    _unfold();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _setStage(int stage) {
    if (_disposed) return;
    final old = _stage;
    setState(() => _stage = stage);
    if (stage >= 2 && stage <= 4 && stage - 1 <= _session.stars) HapticFeedback.heavyImpact();
    if (old == 0 && stage > 0) HapticFeedback.mediumImpact();
  }

  /// Reads where the learner now stands, then lets the results appear a piece at a time.
  void _unfold() {
    final booru = widget.booru;
    try {
      _days = booru.store.studyStore.days();
    } on Object {
      _days = const [];
    }
    _game = StudyGame.of(days: _days, goal: widget.model.goal);
    _streak = StudySummary.of(curriculum: widget.model.curriculum, progress: const {}, days: _days).streak;
    final milestones = StudyMilestone.reached(before: _session.before, earned: _session.earned, goal: _game.goal, streak: _streak);
    // Badges this lesson earned get their pages after the streak, the goal and the level.
    final badges = widget.model.refreshAwards();
    try {
      booru.store.studyStore.markSeen([for (final badge in badges) badge.id]);
    } on Object {
      // A badge that cannot be marked is celebrated again later.
    }
    _milestones = [...milestones, for (final badge in badges) StudyMilestone.award(badge)];
    if (_empty) return;
    StudySound.complete.play();
    if (MediaQuery.disableAnimationsOf(context)) {
      _stage = 6;
      HapticFeedback.mediumImpact();
      return;
    }
    unawaited(_play());
  }

  Future<void> _play() async {
    Future<void> wait(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));
    await wait(150);
    _setStage(1);
    const sounds = [StudySound.star1, StudySound.star2, StudySound.star3];
    for (var star = 1; star <= 3; star++) {
      await wait(star == 1 ? 550 : 330);
      if (_disposed) return;
      _setStage(star + 1);
      if (star <= _session.stars) sounds[star - 1].play();
    }
    await wait(380);
    _setStage(5);
    await wait(450);
    _setStage(6);
  }

  void _continue() {
    StudySound.tap.play();
    if (_page < _milestones.length) {
      setState(() => _page += 1);
    } else {
      widget.done();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final page = _page == 0
        ? KeyedSubtree(key: const ValueKey(0), child: _results(context))
        : StudyMilestoneView(key: ValueKey(_page), milestone: _milestones[_page - 1], days: _days);
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: reduce ? Duration.zero : _pageSpring.settle,
                switchInCurve: _pageSpring,
                switchOutCurve: _pageSpring.flipped,
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                transitionBuilder: (child, animation) {
                  final incoming = child.key == page.key;
                  if (incoming && _page == 0) return FadeTransition(opacity: animation, child: child);
                  // A milestone comes in from the trailing edge; what it replaces leaves by the leading edge.
                  final slide = Tween<Offset>(begin: incoming ? const Offset(1, 0) : const Offset(-1, 0), end: Offset.zero).animate(animation);
                  return SlideTransition(
                    position: slide,
                    child: FadeTransition(opacity: animation.drive(Tween(begin: 0.0, end: 1.0)), child: child),
                  );
                },
                child: page,
              ),
            ),
          ),
        ),
        ColoredBox(
          color: theme.background,
          child: Padding(
            padding: EdgeInsets.only(left: 18, right: 18, top: 10, bottom: 10 + bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: StudyMainButton(key: const Key('study.done'), title: L10n.text('Continue'), onPressed: _continue),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final session = _session;
    final game = _game;
    final stars = session.stars;
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            // As SwiftUI's scroll view does, the content starts below the status bar.
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.only(left: 18, right: 18, bottom: 20),
                  child: Column(
                    spacing: 22,
                    children: _empty
                        ? [
                            const Padding(
                              padding: EdgeInsets.only(top: 60),
                              child: StudyMascot(pose: StudyMascotPose.cheer, size: 150),
                            ),
                            Text(L10n.text('Nothing to Review'), style: StudyTheme.title(28).copyWith(color: theme.ink)),
                            Text(
                              L10n.text('No tag is due right now. Learn new tags or come back later.'),
                              textAlign: TextAlign.center,
                              style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.muted),
                            ),
                          ]
                        : [
                            Padding(
                              padding: const EdgeInsets.only(top: 28),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  StudyPop(
                                    shown: _stage >= 1,
                                    from: 0.2,
                                    child: _Jump(
                                      on: _stage >= 1,
                                      child: const StudyMascot(pose: StudyMascotPose.cheer, size: 170),
                                    ),
                                  ),
                                  Positioned.fill(child: StudyBurst(trigger: _stage >= 1 ? 1 : 0, count: 24, reach: 130)),
                                ],
                              ),
                            ),
                            StudyRise(
                              shown: _stage >= 1,
                              delay: 0.1,
                              child: Text(
                                L10n.text(session.plan.lesson == null ? 'Review Complete!' : 'Lesson Complete!'),
                                key: const Key('study.complete'),
                                textAlign: TextAlign.center,
                                style: StudyTheme.title(32).copyWith(color: theme.ink),
                              ),
                            ),
                            Semantics(
                              key: const Key('study.stars'),
                              container: true,
                              excludeSemantics: true,
                              label: L10n.text('Stars: %@', ['$stars']),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                spacing: 10,
                                // An SF star's frame is about a third wider than its point size.
                                children: [
                                  for (var index = 0; index < 3; index++)
                                    SizedBox(
                                      width: 64,
                                      child: Center(child: _star(theme, index, won: index < stars)),
                                    ),
                                ],
                              ),
                            ),
                            Row(
                              spacing: 10,
                              children: [
                                _tile(
                                  theme,
                                  L10n.text('Earned'),
                                  'bolt.fill',
                                  theme.gold,
                                  0,
                                  StudyCount(
                                    value: _stage >= 5 ? session.earned.toDouble() : 0,
                                    prefix: '+',
                                    suffix: ' XP',
                                    duration: const Duration(milliseconds: 900),
                                  ),
                                ),
                                _tile(
                                  theme,
                                  L10n.text('Accuracy'),
                                  'scope',
                                  theme.good,
                                  1,
                                  StudyCount(value: _stage >= 5 ? _accuracy.toDouble() : 0, suffix: '%', duration: const Duration(milliseconds: 900)),
                                ),
                                _tile(
                                  theme,
                                  L10n.text('Best run'),
                                  'flame.fill',
                                  theme.flame,
                                  2,
                                  StudyCount(value: _stage >= 5 ? session.bestCombo.toDouble() : 0, duration: const Duration(milliseconds: 900)),
                                ),
                              ],
                            ),
                            StudyRise(
                              shown: _stage >= 6,
                              child: StudyCard(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 10,
                                  children: [
                                    Row(
                                      children: [
                                        StudyIcon(game.goalMet ? 'checkmark.seal.fill' : 'target', size: 16, color: game.goalMet ? theme.good : theme.ink),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            L10n.text("Today's goal"),
                                            style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: game.goalMet ? theme.good : theme.ink),
                                          ),
                                        ),
                                        Text(
                                          '${game.today} / ${game.goal} XP',
                                          style: StudyTheme.body(
                                            14,
                                            StudyTheme.heavy,
                                          ).copyWith(color: theme.muted, fontFeatures: const [FontFeature.tabularFigures()]),
                                        ),
                                      ],
                                    ),
                                    StudyBar(
                                      value: _stage >= 6 ? game.goalProgress : (game.goal > 0 ? math.min(1, session.before.today / game.goal) : 0),
                                      color: game.goalMet ? theme.good : theme.gold,
                                    ),
                                    if (_streak > 0)
                                      Row(
                                        children: [
                                          StudyIcon('flame.fill', size: 15, color: theme.flame),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              L10n.text('Day streak: %@', ['$_streak']),
                                              style: StudyTheme.body(15, StudyTheme.heavy).copyWith(color: theme.flame),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!_empty && !reduce) Positioned.fill(child: StudyConfetti(pieces: stars == 3 ? 140 : (stars == 2 ? 80 : 40))),
      ],
    );
  }

  static final _starSpring = StudySpring(0.4, 0.55);

  Widget _star(StudyTheme theme, int index, {required bool won}) {
    final landed = _stage >= index + 2;
    return Transform.translate(
      offset: Offset(0, index == 1 ? -10 : 0),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          _Sprung(
            on: landed,
            spring: _starSpring,
            child: StudyIcon('star.fill', size: 48, color: won ? theme.gold : theme.line),
            builder: (context, value, child) => Opacity(
              opacity: value.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: -50 * (1 - value) * math.pi / 180,
                child: Transform.scale(
                  scale: 2.6 + (1 - 2.6) * value,
                  child: won
                      ? Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // The hard shadow the star stands on.
                            Transform.translate(
                              offset: const Offset(0, 3),
                              child: StudyIcon('star.fill', size: 48, color: studyEdge(theme.gold)),
                            ),
                            child!,
                          ],
                        )
                      : child,
                ),
              ),
            ),
          ),
          if (won)
            Positioned.fill(
              child: StudyBurst(trigger: landed ? 1 : 0, count: 12, reach: 54, colors: [theme.gold, _white, theme.flame]),
            ),
        ],
      ),
    );
  }

  Widget _tile(StudyTheme theme, String title, String symbol, Color color, int index, Widget value) {
    return Expanded(
      child: StudyPop(
        shown: _stage >= 5,
        delay: index * 0.1,
        from: 0.5,
        child: MergeSemantics(
          child: Container(
            decoration: ShapeDecoration(color: theme.surface, shape: _rounded(16)),
            foregroundDecoration: ShapeDecoration(shape: _rounded(16, BorderSide(color: color, width: 2))),
            clipBehavior: Clip.antiAlias,
            child: Column(
              spacing: 6,
              children: [
                Container(
                  width: double.infinity,
                  color: color,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: StudyShrinkingText(title, maxLines: 1, minScale: 0.8, style: StudyTheme.body(12, StudyTheme.heavy).copyWith(color: _white)),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 10),
                  child: DefaultTextStyle.merge(
                    style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: theme.ink),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 4,
                      children: [
                        StudyIcon(symbol, size: 18, color: color),
                        Flexible(child: value),
                      ],
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
}

/// The guide's jump when the results open: up 18 points and back, each on a 0.3 s spring with bounce 0.6.
class _Jump extends StatefulWidget {
  const _Jump({required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  State<_Jump> createState() => _JumpState();
}

class _JumpState extends State<_Jump> with SingleTickerProviderStateMixin {
  static final _spring = StudySpring(0.3, 0.6);
  late final AnimationController _controller = AnimationController(vsync: this, duration: _spring.settle * 2);

  @override
  void didUpdateWidget(_Jump old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on && !MediaQuery.disableAnimationsOf(context)) _controller.forward(from: 0);
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
      final t = _controller.value * 2;
      final lift = !_controller.isAnimating
          ? 0.0
          : t < 1
          ? -18 * _spring.transform(t)
          : -18 + 18 * _spring.transform(t - 1);
      return Transform.translate(offset: Offset(0, lift), child: child);
    },
  );
}

// MARK: - Milestones

/// A full page shown after a lesson's results for something reached beyond the lesson: a streak, the day's goal, a
/// level or a badge (`StudyMilestoneView`).
class StudyMilestoneView extends StatefulWidget {
  const StudyMilestoneView({super.key, required this.milestone, required this.days});

  final StudyMilestone milestone;

  /// The days studied, for the streak's week.
  final List<StudyDay> days;

  @override
  State<StudyMilestoneView> createState() => _StudyMilestoneViewState();
}

class _StudyMilestoneViewState extends State<StudyMilestoneView> with TickerProviderStateMixin {
  static final _raysSpring = StudySpring(0.6, 0.3);
  bool _shown = false;

  /// The streak's number counts on half a second after the page appears.
  bool _counted = false;
  Timer? _count;
  late final AnimationController _rays = AnimationController(vsync: this, duration: const Duration(seconds: 24));
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void initState() {
    super.initState();
    if (widget.milestone is StudyAwardMilestone) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduce = MediaQuery.disableAnimationsOf(context);
      setState(() {
        _shown = true;
        _counted = reduce;
      });
      HapticFeedback.mediumImpact();
      switch (widget.milestone) {
        case StudyStreakMilestone():
          StudySound.streak.play();
        case StudyGoalMilestone():
          StudySound.combo.play();
        case StudyLevelMilestone():
          StudySound.levelup.play();
        case StudyAwardMilestone():
          break;
      }
      if (!reduce) {
        _rays.repeat();
        _pulse.repeat(reverse: true);
        _bounce.forward();
        _count = Timer(const Duration(milliseconds: 500), () {
          if (mounted) setState(() => _counted = true);
        });
      }
    });
  }

  @override
  void dispose() {
    _count?.cancel();
    _rays.dispose();
    _pulse.dispose();
    _bounce.dispose();
    super.dispose();
  }

  Color _color(StudyTheme theme) => switch (widget.milestone) {
    StudyStreakMilestone() => theme.flame,
    StudyGoalMilestone() => theme.good,
    StudyLevelMilestone() || StudyAwardMilestone() => theme.gold,
  };

  String get _title => switch (widget.milestone) {
    StudyStreakMilestone(:final days) => L10n.text('%@-Day Streak!', ['$days']),
    StudyGoalMilestone() => L10n.text('Daily Goal Met!'),
    StudyLevelMilestone(:final level) => L10n.text('Level %@!', ['$level']),
    StudyAwardMilestone(:final award) => award.name,
  };

  String get _detail => switch (widget.milestone) {
    StudyStreakMilestone(:final days) => L10n.text(
      days <= 1 ? 'A streak starts today. Come back tomorrow to keep it going.' : 'You showed up again today. Keep it going tomorrow.',
    ),
    StudyGoalMilestone(:final xp) => L10n.text('You earned the %@ XP you set for today.', ['$xp']),
    StudyLevelMilestone() => L10n.text('You know more tags than you did yesterday. Keep climbing.'),
    StudyAwardMilestone(:final award) => award.explanation,
  };

  @override
  Widget build(BuildContext context) {
    final milestone = widget.milestone;
    if (milestone is StudyAwardMilestone) return StudyAwardCelebration(award: milestone.award);
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final color = _color(theme);
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: math.max(0, constraints.maxHeight - MediaQuery.paddingOf(context).top), minWidth: constraints.maxWidth),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Padding(
                      // The spacers' least height, plus the 22 points of spacing beside them.
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 22,
                        children: [
                          SizedBox.square(
                            dimension: 230,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.center,
                              children: [
                                // Rays turning slowly behind the badge.
                                _Sprung(
                                  on: _shown,
                                  spring: _raysSpring,
                                  builder: (context, value, child) => Opacity(
                                    opacity: value.clamp(0.0, 1.0),
                                    child: Transform.scale(scale: 0.2 + 0.8 * value, child: child),
                                  ),
                                  child: RotationTransition(
                                    turns: _rays,
                                    child: CustomPaint(size: const Size.square(230), painter: _Rays(color.withValues(alpha: 0.22))),
                                  ),
                                ),
                                StudyPop(shown: _shown, delay: 0.1, from: 0.1, child: _badge(theme)),
                                // Over the badge, so that sparks flying past the edge do not widen the page.
                                Positioned.fill(
                                  child: StudyBurst(trigger: _shown ? 1 : 0, count: 26, reach: 150, colors: [color, theme.gold, theme.primary, _white]),
                                ),
                              ],
                            ),
                          ),
                          StudyRise(
                            shown: _shown,
                            delay: 0.35,
                            child: Text(
                              _title,
                              key: const Key('study.milestone'),
                              textAlign: TextAlign.center,
                              style: StudyTheme.title(32).copyWith(color: theme.ink),
                            ),
                          ),
                          StudyRise(
                            shown: _shown,
                            delay: 0.45,
                            child: Text(
                              _detail,
                              textAlign: TextAlign.center,
                              style: StudyTheme.body(17, StudyTheme.medium).copyWith(color: theme.muted),
                            ),
                          ),
                          if (milestone is StudyStreakMilestone) StudyRise(shown: _shown, delay: 0.55, child: _week(theme)),
                          if (milestone is StudyGoalMilestone)
                            StudyPop(
                              shown: _shown,
                              delay: 0.5,
                              child: const StudyMascot(pose: StudyMascotPose.cheer, size: 120),
                            ),
                          if (milestone is StudyLevelMilestone)
                            StudyPop(
                              shown: _shown,
                              delay: 0.5,
                              child: const StudyMascot(pose: StudyMascotPose.fullBody, size: 130),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (milestone is StudyLevelMilestone && !reduce) const Positioned.fill(child: StudyConfetti(pieces: 110)),
      ],
    );
  }

  /// A large symbol filled top to bottom from gold to flame.
  Widget _gradientSymbol(StudyTheme theme, String symbol, double size) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (rect) => LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [theme.gold, theme.flame]).createShader(rect),
    child: StudyIcon(symbol, size: size, color: _white),
  );

  Widget _badge(StudyTheme theme) {
    final edge = [Shadow(color: studyEdge(theme.flame), offset: const Offset(0, 3))];
    switch (widget.milestone) {
      case StudyStreakMilestone(:final days):
        return Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) =>
                  Transform.scale(scale: 1 + 0.06 * Curves.easeInOut.transform(_pulse.value), alignment: Alignment.bottomCenter, child: child),
              child: _gradientSymbol(theme, 'flame.fill', 150),
            ),
            Transform.translate(
              offset: const Offset(0, 28),
              child: StudyCount(
                value: (_counted ? days : math.max(0, days - 1)).toDouble(),
                style: StudyTheme.title(58).copyWith(color: _white, shadows: edge),
              ),
            ),
          ],
        );
      case StudyGoalMilestone():
        return AnimatedBuilder(
          animation: _bounce,
          builder: (context, child) {
            // A symbol bounce: down a little, up past its size and back.
            final t = _bounce.value;
            final scale = t < 0.25
                ? 1 - 0.1 * Curves.easeOut.transform(t / 0.25)
                : t < 0.6
                ? 0.9 + 0.25 * Curves.easeOut.transform((t - 0.25) / 0.35)
                : 1.15 - 0.15 * Curves.easeInOut.transform((t - 0.6) / 0.4);
            return Transform.scale(scale: scale, child: child);
          },
          child: StudyIcon('checkmark.seal.fill', size: 140, color: theme.good),
        );
      case StudyLevelMilestone(:final level):
        return Stack(
          alignment: Alignment.center,
          children: [
            _gradientSymbol(theme, 'shield.fill', 150),
            Transform.translate(
              offset: const Offset(0, -6),
              child: Text(
                '$level',
                style: StudyTheme.title(64).copyWith(color: _white, shadows: edge),
              ),
            ),
          ],
        );
      case StudyAwardMilestone():
        return const SizedBox.shrink();
    }
  }

  /// The one-letter weekday names, Sunday first, as `Calendar.veryShortWeekdaySymbols` gives them.
  static List<String> get _weekdays => switch (L10n.language) {
    'ko' => const ['일', '월', '화', '수', '목', '금', '토'],
    'ja' => const ['日', '月', '火', '水', '木', '金', '土'],
    _ => const ['S', 'M', 'T', 'W', 'T', 'F', 'S'],
  };

  /// The last seven days, lit where something was studied.
  Widget _week(StudyTheme theme) {
    final studied = {
      for (final day in widget.days)
        if (day.isStudied) day.day,
    };
    final today = DateTime.now();
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: ShapeDecoration(color: theme.surface, shape: _rounded(20)),
        foregroundDecoration: ShapeDecoration(shape: _rounded(20, BorderSide(color: theme.line, width: 2))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            for (var back = 6; back >= 0; back--)
              Builder(
                builder: (context) {
                  final date = DateTime(today.year, today.month, today.day - back);
                  final lit = studied.contains(StudyDay.key(date)) || back == 0;
                  return Column(
                    spacing: 6,
                    children: [
                      Text(_weekdays[date.weekday % 7], style: StudyTheme.body(12, StudyTheme.heavy).copyWith(color: theme.muted)),
                      StudyPop(
                        shown: _shown,
                        delay: 0.6 + (6 - back) * 0.06,
                        child: Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: lit ? ShapeDecoration(shape: const CircleBorder(), color: theme.flame.withValues(alpha: 0.16)) : null,
                          child: StudyIcon(lit ? 'flame.fill' : 'circle.fill', size: lit ? 20 : 12, color: lit ? theme.flame : theme.line),
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Twelve capsules 10 by 150 points standing out from the middle, 30 degrees apart.
class _Rays extends CustomPainter {
  const _Rays(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final center = size.center(Offset.zero);
    for (var index = 0; index < 12; index++) {
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(index * 30 * math.pi / 180)
        ..drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-5, -150, 10, 150), const Radius.circular(5)), paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_Rays old) => old.color != color;
}
