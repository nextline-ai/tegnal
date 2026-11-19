import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/study/study_engine.dart';
import '../../core/study/study_models.dart';
import '../../core/study/study_path.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../study/study_result_view.dart' show StudyConfetti;
import 'study_kit.dart';
import 'study_lesson_view.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';

/// What learning mode shows on a first visit and after a reset (`StudyWelcomeView`): a hello, a daily goal, and how
/// much the learner already knows. Someone who knows some of it takes the placement test, played in place, which can
/// start them further along the path.
class StudyWelcomeView extends StatefulWidget {
  const StudyWelcomeView({super.key, required this.booru, required this.model, required this.finish});
  final BooruContext booru;
  final StudyModeModel model;
  final VoidCallback finish;

  @override
  State<StudyWelcomeView> createState() => _StudyWelcomeViewState();
}

class _StudyWelcomeViewState extends State<StudyWelcomeView> {
  static const _last = 2;
  static const _goalNames = {10: 'Casual', 20: 'Regular', 30: 'Serious', 50: 'Intense'};
  static final _slide = StudySpring(0.32, 0.1);

  int _page = 0;

  /// True for "I Know Some Already", false for "I'm New to This"; null until one is picked.
  bool? _knowsSome;
  StudyLessonSession? _test;

  StudyModeModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    _test?.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _next() {
    StudySound.tap.play();
    if (_page < _last) {
      setState(() => _page += 1);
      return;
    }
    if (_knowsSome == true) {
      // The test is about the main path, so it asks with the app's own curriculum.
      setState(
        () => _test = StudyLessonSession(
          plan: StudyLessonPlan.placement,
          store: widget.booru.store,
          source: widget.booru.source,
          server: model.server,
          engine: StudyEngine(curriculum: StudyCurriculum.bundled),
        ),
      );
    } else {
      widget.finish();
    }
  }

  /// A finished test ends the welcome; a test closed early goes back to the question, to be taken again or skipped.
  void _closeTest() {
    final test = _test;
    if (test == null) return;
    if (test.phase == StudyLessonPhase.finished) {
      widget.finish();
      return;
    }
    setState(() => _test = null);
    test.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final test = _test;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_test != null) {
          _closeTest();
        } else if (_page > 0) {
          setState(() => _page -= 1);
        }
      },
      child: ColoredBox(
        key: const Key('study.welcome'),
        color: theme.background,
        child: AnimatedSwitcher(
          duration: reduce ? Duration.zero : const Duration(milliseconds: 350),
          child: test != null
              ? StudyPlayView(key: ValueKey(test.id), booru: widget.booru, session: test, model: model, leave: _closeTest)
              : _pages(context, theme, reduce),
        ),
      ),
    );
  }

  Widget _pages(BuildContext context, StudyTheme theme, bool reduce) {
    final media = MediaQuery.of(context);
    final title = _page < _last ? 'Continue' : (_knowsSome == true ? 'Take the Test' : 'Start Learning');
    return Column(
      key: const ValueKey('pages'),
      children: [
        SizedBox(height: media.padding.top),
        _header(theme),
        Expanded(
          child: AnimatedSwitcher(
            duration: reduce ? Duration.zero : _slide.settle,
            switchInCurve: _slide,
            // Flipped, so the page leaving goes as quickly as the next one comes instead of lingering under it.
            switchOutCurve: _slide.flipped,
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (child, animation) {
              final incoming = child.key == ValueKey(_page);
              return FadeTransition(
                opacity: animation.drive(Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: const _Clamp()))),
                child: SlideTransition(position: animation.drive(Tween(begin: Offset(incoming ? 1 : -1, 0), end: Offset.zero)), child: child),
              );
            },
            child: SingleChildScrollView(
              key: ValueKey(_page),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: switch (_page) {
                    0 => _hello(theme),
                    1 => _goals(theme),
                    _ => _level(theme),
                  },
                ),
              ),
            ),
          ),
        ),
        ColoredBox(
          color: theme.background,
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 10 + media.padding.bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: StudyMainButton(
                  key: const Key('study.welcome.next'),
                  title: L10n.text(title),
                  symbol: _page == _last && _knowsSome == true ? 'scope' : null,
                  onPressed: _page == _last && _knowsSome == null ? null : _next,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(StudyTheme theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      spacing: 14,
      children: [
        Opacity(
          opacity: _page > 0 ? 1 : 0,
          child: Semantics(
            button: true,
            label: L10n.text('Back'),
            excludeSemantics: true,
            child: GestureDetector(
              key: const Key('study.welcome.back'),
              behavior: HitTestBehavior.opaque,
              onTap: _page > 0
                  ? () {
                      StudySound.tap.play();
                      setState(() => _page -= 1);
                    }
                  : null,
              child: SizedBox.square(
                dimension: 36,
                child: Center(child: StudyIcon('chevron.left', size: 17, color: theme.muted)),
              ),
            ),
          ),
        ),
        Expanded(child: StudyBar(value: (_page + 1) / (_last + 1), color: theme.primary)),
        const SizedBox.square(dimension: 36),
      ],
    ),
  );

  Widget _speech(StudyTheme theme, StudyMascotPose pose, String title, String detail) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        StudyMascot(pose: pose, size: 86),
        Expanded(
          child: StudyCard(
            padding: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Text(L10n.text(title), style: StudyTheme.title(22).copyWith(color: theme.ink)),
                Text(L10n.text(detail), style: StudyTheme.body(15, StudyTheme.medium).copyWith(color: theme.muted)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _hello(StudyTheme theme) {
    Widget feature(String symbol, Color color, String text) => Row(
      spacing: 14,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: ShapeDecoration(color: color, shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(13))),
          child: Center(child: StudyIcon(symbol, size: 20, color: const Color(0xFFFFFFFF))),
        ),
        Expanded(child: Text(L10n.text(text), style: StudyTheme.body(16, StudyTheme.bold).copyWith(color: theme.ink))),
      ],
    );
    return Column(
      spacing: 18,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: StudyMascot(pose: StudyMascotPose.wave, size: 170),
        ),
        Column(
          spacing: 8,
          children: [
            Text(
              L10n.text('Welcome to Learning Mode!'),
              textAlign: TextAlign.center,
              style: StudyTheme.title(30).copyWith(color: theme.ink),
            ),
            Text(
              L10n.text('Learn the tags that AI pictures are ordered with, from the very start, one short lesson at a time.'),
              textAlign: TextAlign.center,
              style: StudyTheme.body(17, StudyTheme.medium).copyWith(color: theme.muted),
            ),
          ],
        ),
        StudyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              feature('map.fill', theme.primary, 'Follow the map, one short lesson at a time'),
              feature('flame.fill', theme.flame, 'Meet a daily goal and keep your streak going'),
              feature('trophy.fill', theme.gold, 'Practise with games and collect badges'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _goals(StudyTheme theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 18,
    children: [
      _speech(theme, StudyMascotPose.read, 'Pick a Daily Goal', 'How much would you like to learn each day? You can change it on the Me tab anytime.'),
      Column(
        spacing: 12,
        children: [
          for (final goal in StudyGame.goals)
            _choice(
              key: Key('study.welcome.goal.$goal'),
              chosen: model.goal == goal,
              color: theme.gold,
              radius: 16,
              depth: 4,
              onPressed: () {
                StudySound.pick.play();
                HapticFeedback.selectionClick();
                model.goal = goal;
              },
              child: (ink) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Row(
                    children: [
                      Text(L10n.text(_goalNames[goal] ?? ''), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: ink)),
                      const Spacer(),
                      Opacity(
                        opacity: 0.85,
                        child: Text(L10n.text('%@ XP a day', ['$goal']), style: StudyTheme.body(15, StudyTheme.bold).copyWith(color: ink)),
                      ),
                      const SizedBox(width: 8),
                      StudyIcon(model.goal == goal ? 'checkmark.circle.fill' : 'circle', size: 20, color: ink),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ],
  );

  Widget _level(StudyTheme theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 18,
    children: [
      _speech(theme, StudyMascotPose.think, 'How much do you know about AI pictures?', 'Tell us, and the path starts in the right place.'),
      Column(
        spacing: 12,
        children: [
          _levelChoice(theme, false, 'leaf.fill', "I'm New to This", 'Start from the very first lesson.'),
          _levelChoice(
            theme,
            true,
            'scope',
            'I Know Some Already',
            "Answer a few short questions to find where to begin. A question you can't answer ends the test.",
          ),
        ],
      ),
    ],
  );

  Widget _levelChoice(StudyTheme theme, bool some, String symbol, String title, String detail) {
    final chosen = _knowsSome == some;
    return _choice(
      key: Key(some ? 'study.welcome.some' : 'study.welcome.new'),
      chosen: chosen,
      color: theme.primary,
      radius: 20,
      depth: 5,
      onPressed: () {
        StudySound.pick.play();
        HapticFeedback.selectionClick();
        setState(() => _knowsSome = some);
      },
      child: (ink) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          spacing: 14,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: ShapeDecoration(
                color: chosen ? const Color(0x38FFFFFF) : theme.primary.withValues(alpha: 0.14),
                shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Center(child: StudyIcon(symbol, size: 24, color: chosen ? const Color(0xFFFFFFFF) : theme.primary)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(L10n.text(title), style: StudyTheme.body(18, StudyTheme.heavy).copyWith(color: ink)),
                  Opacity(
                    opacity: 0.85,
                    child: Text(L10n.text(detail), style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: ink)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A choice that fills with [color] once chosen and is an outlined paper button otherwise, leaning forward a little
  /// when chosen, as on iOS.
  Widget _choice({
    required Key key,
    required bool chosen,
    required Color color,
    required double radius,
    required double depth,
    required VoidCallback onPressed,
    required Widget Function(Color ink) child,
  }) {
    final theme = StudyTheme.of(context);
    final ink = chosen ? const Color(0xFFFFFFFF) : theme.ink;
    return Semantics(
      key: key,
      selected: chosen,
      child: AnimatedScale(
        scale: chosen ? 1.02 : 1,
        duration: const Duration(milliseconds: 300),
        curve: StudySpring(0.3, 0.4),
        child: StudyPressButton(color: color, ink: ink, radius: radius, depth: depth, outlined: !chosen, onPressed: onPressed, child: child(ink)),
      ),
    );
  }
}

class _Clamp extends Curve {
  const _Clamp();
  @override
  double transformInternal(double t) => t.clamp(0.0, 1.0);
}

/// Where the placement test put the learner (`StudyPlacementResult`): how it went, the section they begin at, and how
/// many lessons it passed by.
class StudyPlacementResult extends StatefulWidget {
  const StudyPlacementResult({super.key, required this.session, required this.done});
  final StudyLessonSession session;
  final VoidCallback done;

  @override
  State<StudyPlacementResult> createState() => _StudyPlacementResultState();
}

class _StudyPlacementResultState extends State<StudyPlacementResult> {
  bool _shown = false;

  StudyLessonSession get session => widget.session;
  bool get _ahead => session.placed > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _shown = true);
      (_ahead ? StudySound.levelup : StudySound.complete).play();
      HapticFeedback.mediumImpact();
    });
  }

  Widget _tile(StudyTheme theme, String title, String symbol, Color color, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: ShapeDecoration(color: theme.surface, shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(18))),
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: theme.line, width: 2),
        ),
      ),
      child: Semantics(
        container: true,
        child: Column(
          spacing: 4,
          children: [
            StudyIcon(symbol, size: 20, color: color),
            Text(value, style: StudyTheme.title(22).copyWith(color: theme.ink, fontFeatures: const [FontFeature.tabularFigures()])),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: StudyTheme.body(12, StudyTheme.bold).copyWith(color: theme.muted),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final media = MediaQuery.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final section = StudyPlacement.section(StudyPath.bundled, placed: session.placed);
    final color = section == null ? theme.primary : studyHex(section.color);
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        spacing: 20,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 32),
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.center,
                              children: [
                                StudyPop(
                                  shown: _shown,
                                  from: 0.2,
                                  child: StudyMascot(pose: _ahead ? StudyMascotPose.cheer : StudyMascotPose.wave, size: 160),
                                ),
                                if (_ahead) Positioned.fill(child: StudyBurst(trigger: _shown ? 1 : 0, count: 24, reach: 130)),
                              ],
                            ),
                          ),
                          StudyRise(
                            shown: _shown,
                            delay: 0.1,
                            child: Column(
                              spacing: 8,
                              children: [
                                Text(
                                  L10n.text(_ahead ? 'You Know Your Stuff!' : "Let's Start from the Beginning"),
                                  key: const Key('study.placement.title'),
                                  textAlign: TextAlign.center,
                                  style: StudyTheme.title(30).copyWith(color: theme.ink),
                                ),
                                Text(
                                  L10n.text(_ahead ? 'You can skip ahead on the path.' : "We'll learn the basics together, one short lesson at a time."),
                                  textAlign: TextAlign.center,
                                  style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.muted),
                                ),
                              ],
                            ),
                          ),
                          StudyRise(
                            shown: _shown,
                            delay: 0.2,
                            child: Row(
                              spacing: 10,
                              children: [
                                _tile(theme, L10n.text('Right Answers'), 'checkmark.circle.fill', theme.good, '${session.asked - session.mistakes} / ${session.asked}'),
                                _tile(theme, L10n.text('Lessons Skipped'), 'forward.fill', theme.primary, '${session.placed}'),
                              ],
                            ),
                          ),
                          if (section != null)
                            StudyPop(
                              shown: _shown,
                              delay: 0.35,
                              from: 0.6,
                              child: Semantics(
                                key: const Key('study.placement.section'),
                                container: true,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(18),
                                  decoration: ShapeDecoration(
                                    color: color,
                                    shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
                                    shadows: [BoxShadow(color: studyEdge(color), offset: const Offset(0, 5))],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    spacing: 6,
                                    children: [
                                      Row(
                                        spacing: 6,
                                        children: [
                                          const StudyIcon('flag.fill', size: 14, color: Color(0xE6FFFFFF)),
                                          Text(L10n.text('Start Here'), style: StudyTheme.body(14, StudyTheme.heavy).copyWith(color: const Color(0xE6FFFFFF))),
                                        ],
                                      ),
                                      Text(section.title.resolved(), style: StudyTheme.title(24).copyWith(color: const Color(0xFFFFFFFF))),
                                      Text(section.summary.resolved(), style: StudyTheme.body(15, StudyTheme.medium).copyWith(color: const Color(0xE6FFFFFF))),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (_ahead)
                            StudyRise(
                              shown: _shown,
                              delay: 0.45,
                              child: Text(
                                L10n.text('The lessons before it stay open on the map, to play whenever you like.'),
                                textAlign: TextAlign.center,
                                style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_ahead && !reduce) const Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: StudyConfetti(pieces: 90)))),
            ],
          ),
        ),
        ColoredBox(
          color: theme.background,
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 10 + media.padding.bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: StudyMainButton(
                  key: const Key('study.done'),
                  title: L10n.text('Start Learning'),
                  symbol: 'play.fill',
                  onPressed: () {
                    StudySound.tap.play();
                    widget.done();
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
