import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/study/study_models.dart';
import '../../core/study/study_speed.dart';
import '../../core/support/l10n.dart';
import '../study/study_result_view.dart' show StudyConfetti;
import 'study_award_views.dart' show StudyFitText;
import 'study_kit.dart';
import 'study_reactions.dart';

// A minute of quick questions on tags already met. Ported from the view part of `StudySpeedView.swift`; the round
// itself is `StudySpeedRound` in `core/study/study_speed.dart`.

/// The speed round's page (`StudySpeedView`): ready, playing, then the result. A full page that pops itself on close
/// and on Continue.
class StudySpeedView extends StatefulWidget {
  /// The page for [round]. [now] is the clock the timer reads, `DateTime.now` unless a test gives the same clock it
  /// gave the round.
  const StudySpeedView({super.key, required this.round, this.now});

  final StudySpeedRound round;

  /// The clock the time left is read from.
  final DateTime Function()? now;

  @override
  State<StudySpeedView> createState() => _StudySpeedViewState();
}

const _white = Color(0xFFFFFFFF);
const _tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

class _StudySpeedViewState extends State<StudySpeedView> {
  int _cheers = 0;
  int _shakes = 0;
  bool _shown = false;
  Timer? _clock;
  Timer? _next;

  StudySpeedRound get _round => widget.round;
  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _round.addListener(_changed);
    if (_round.phase == StudySpeedPhase.playing) _tick();
  }

  @override
  void didUpdateWidget(StudySpeedView old) {
    super.didUpdateWidget(old);
    if (old.round != widget.round) {
      old.round.removeListener(_changed);
      widget.round.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _round.removeListener(_changed);
    _clock?.cancel();
    _next?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_round.phase == StudySpeedPhase.finished) {
      _clock?.cancel();
      if (!_shown) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _shown = true);
        });
      }
    }
    setState(() {});
  }

  /// Ten times a second, as the iOS timeline does.
  void _tick() {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (_left <= 0 && _round.phase == StudySpeedPhase.playing) {
        _round.finish();
        StudySound.complete.play();
      }
      setState(() {});
    });
  }

  double get _left => math.max(0, _round.ends.difference(_now()).inMicroseconds / Duration.microsecondsPerSecond);

  void _go() {
    StudySound.combo.play();
    _round.start(_now());
    if (_round.phase == StudySpeedPhase.playing) _tick();
  }

  void _close() => Navigator.of(context).maybePop();

  void _tap(int index) {
    if (_round.answer(index)) {
      setState(() => _cheers += 1);
      StudySound.match.play();
      HapticFeedback.mediumImpact();
    } else {
      StudySound.wrong.play();
      HapticFeedback.heavyImpact();
      setState(() => _shakes += 1);
    }
    // A right answer moves on at once; a wrong one stays long enough to show which tag it was.
    final wait = _round.last == true ? 220 : 800;
    _next?.cancel();
    _next = Timer(Duration(milliseconds: wait), _round.next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    return ColoredBox(
      color: theme.background,
      child: SafeArea(
        child: SizedBox.expand(
          child: switch (_round.phase) {
            StudySpeedPhase.ready => _ready(theme),
            StudySpeedPhase.playing => _playing(theme),
            StudySpeedPhase.finished => _finished(theme),
          },
        ),
      ),
    );
  }

  Widget _closeButton(StudyTheme theme) => Semantics(
    button: true,
    label: L10n.text('Close'),
    excludeSemantics: true,
    child: GestureDetector(
      key: const Key('study.close'),
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      child: SizedBox.square(
        dimension: 36,
        child: Center(child: StudyIcon('xmark', size: 17, color: theme.muted)),
      ),
    ),
  );

  Widget _mainButton(Widget button) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560 + 36),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10), child: button),
    ),
  );

  /// [children] with [gap] between them, centred in the height there is and scrolling when it is too little.
  Widget _centered(double gap, List<Widget> children) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      clipBehavior: Clip.none,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: gap),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (index, child) in children.indexed) ...[if (index > 0) SizedBox(height: gap), child],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _ready(StudyTheme theme) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Row(children: [_closeButton(theme), const Spacer()]),
      ),
      Expanded(
        child: _centered(18, [
          const StudyMascot(pose: StudyMascotPose.fullBody, size: 170),
          Text(
            L10n.text('Speed Round'),
            textAlign: TextAlign.center,
            style: StudyTheme.title(32).copyWith(color: theme.ink),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              L10n.text('Sixty seconds. A meaning appears; tap its tag. How many can you get?'),
              textAlign: TextAlign.center,
              style: StudyTheme.body(17, StudyTheme.medium).copyWith(color: theme.muted),
            ),
          ),
          if (_round.best > 0) _label('trophy.fill', L10n.text('Your best: %@', ['${_round.best}']), StudyTheme.body(16, StudyTheme.heavy), theme.gold),
        ]),
      ),
      _mainButton(StudyMainButton(key: const Key('study.speed.go'), title: L10n.text('Go!'), color: theme.flame, symbol: 'bolt.fill', onPressed: _go)),
    ],
  );

  Widget _playing(StudyTheme theme) {
    final left = _left;
    final question = _round.question;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              _closeButton(theme),
              const SizedBox(width: 14),
              Expanded(
                child: StudyBar(value: left / StudySpeedRound.length, color: left < 10 ? theme.bad : theme.flame),
              ),
              const SizedBox(width: 14),
              StudyStat(key: const Key('study.speed.score'), symbol: 'bolt.fill', color: theme.gold, value: '${_round.score}'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Expanded(
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
              transitionBuilder: (child, animation) {
                final incoming = child.key == ValueKey(question?.id);
                return FadeTransition(
                  opacity: animation,
                  child: incoming
                      ? SlideTransition(
                          position: animation.drive(Tween(begin: const Offset(1, 0), end: Offset.zero)),
                          child: child,
                        )
                      : child,
                );
              },
              child: question == null ? const SizedBox(key: ValueKey('none')) : _question(theme, question),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: reduce ? Duration.zero : StudySpring(0.3, 0.5).settle,
          switchInCurve: StudySpring(0.3, 0.5),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation.drive(CurveTween(curve: const _Clamp())),
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: _round.combo >= 3
              ? Padding(
                  key: const ValueKey('combo'),
                  padding: const EdgeInsets.only(top: 18, bottom: 24),
                  child: _label('flame.fill', L10n.text('%@ in a row!', ['${_round.combo}']), StudyTheme.title(20), theme.flame),
                )
              : const SizedBox(key: ValueKey('quiet'), width: double.infinity),
        ),
      ],
    );
  }

  Widget _question(StudyTheme theme, StudyQuestion question) {
    final answered = _round.last != null;
    Widget choice(int index) {
      final tag = question.choices[index];
      final right = index == question.answer;
      return IgnorePointer(
        ignoring: answered,
        child: StudyPressButton(
          key: Key('study.speed.choice.$index'),
          color: !answered ? theme.primary : (right ? theme.good : theme.sunken),
          ink: !answered || right ? _white : theme.muted,
          radius: 18,
          onPressed: () => _tap(index),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(child: StudyFitText(tag.english, style: StudyTheme.body(18, StudyTheme.heavy), maxLines: 2, minimumScale: 0.7)),
            ),
          ),
        ),
      );
    }

    Widget row(int first) => Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: first < question.choices.length ? choice(first) : const SizedBox()),
        const SizedBox(width: 12),
        Expanded(child: first + 1 < question.choices.length ? choice(first + 1) : const SizedBox()),
      ],
    );

    return Center(
      key: ValueKey(question.id),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  StudyShake(
                    travel: _shakes.toDouble(),
                    duration: const Duration(milliseconds: 300),
                    child: StudyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (L10n.language != 'en') ...[
                            Text(studyWords(question.tag.title()), style: StudyTheme.title(24).copyWith(color: theme.primary)),
                            const SizedBox(height: 6),
                          ],
                          Text(
                            studyWords(question.tag.note.resolved()),
                            style: StudyTheme.body(18, StudyTheme.semibold).copyWith(color: theme.ink, height: (18 * 1.2 + 3) / 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned.fill(child: StudyBurst(trigger: _cheers, count: 14, reach: 90)),
                ],
              ),
              const SizedBox(height: 16),
              for (var first = 0; first < question.choices.length; first += 2) ...[if (first > 0) const SizedBox(height: 12), row(first)],
            ],
          ),
        ),
      ),
    );
  }

  Widget _finished(StudyTheme theme) {
    final round = _round;
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: _centered(20, [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    StudyPop(
                      shown: _shown,
                      from: 0.2,
                      child: StudyMascot(pose: round.score > 0 ? StudyMascotPose.cheer : StudyMascotPose.think, size: 170),
                    ),
                    Positioned.fill(child: StudyBurst(trigger: _shown ? 1 : 0, count: 24, reach: 130)),
                  ],
                ),
                StudyRise(
                  shown: _shown,
                  delay: 0.1,
                  child: Text(
                    L10n.text("Time's Up!"),
                    key: const Key('study.speed.done'),
                    textAlign: TextAlign.center,
                    style: StudyTheme.title(32).copyWith(color: theme.ink),
                  ),
                ),
                // Counts up after 0.3 s over 0.9 s, ease out.
                StudyCount(
                  value: _shown ? round.score.toDouble() : 0,
                  from: 0,
                  duration: const Duration(milliseconds: 1200),
                  curve: const Interval(0.25, 1, curve: Curves.easeOut),
                  style: StudyTheme.title(72).copyWith(color: theme.flame),
                ),
                if (round.record)
                  StudyPop(shown: _shown, delay: 1.1, child: _label('trophy.fill', L10n.text('New Best!'), StudyTheme.title(20), theme.gold))
                else if (round.best > 0)
                  Text(
                    L10n.text('Your best: %@', ['${round.best}']),
                    textAlign: TextAlign.center,
                    style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: theme.muted),
                  ),
                StudyRise(
                  shown: _shown,
                  delay: 0.6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StudyStat(symbol: 'bolt.fill', color: theme.gold, value: '+${round.earned} XP'),
                      const SizedBox(width: 18),
                      StudyStat(symbol: 'flame.fill', color: theme.flame, value: '${round.bestCombo}'),
                    ],
                  ),
                ),
              ]),
            ),
            _mainButton(
              StudyMainButton(
                key: const Key('study.done'),
                title: L10n.text('Continue'),
                onPressed: () {
                  StudySound.tap.play();
                  _close();
                },
              ),
            ),
          ],
        ),
        if (round.record) const Positioned.fill(child: StudyConfetti(pieces: 100)),
      ],
    );
  }
}

/// An SF Symbol and a title in the same style (`Label`).
Widget _label(String symbol, String title, TextStyle style, Color color) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    StudyIcon(symbol, size: style.fontSize ?? 17, color: color),
    SizedBox(width: (style.fontSize ?? 17) * 0.35),
    Flexible(
      child: Text(title, style: style.copyWith(color: color).merge(_tabular)),
    ),
  ],
);

/// Keeps a spring's overshoot out of an opacity.
class _Clamp extends Curve {
  const _Clamp();
  @override
  double transformInternal(double t) => t.clamp(0.0, 1.0);
}
