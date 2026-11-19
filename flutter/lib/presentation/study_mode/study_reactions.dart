import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import 'study_kit.dart';

// Learning mode answers everything the learner does: a sound, a movement, a word from the guide.
// Ported from `StudyReactions.swift`, except the milestone page.

/// The sounds learning mode makes. They play as media: the volume buttons turn them up and down, the silent mode
/// does not mute them, and they play over the learner's music without stopping it. The native side is a `SoundPool`
/// behind the `work.nextline.tegnal/study_sound` channel; where it is missing every call does nothing.
enum StudySound {
  /// A button press.
  tap,

  /// A choice picked.
  pick,

  /// A right answer.
  right,

  /// A wrong answer.
  wrong,

  /// A pair matched.
  match,

  /// A run of right answers.
  combo,

  /// One star earned.
  star1,

  /// Two stars earned.
  star2,

  /// Three stars earned.
  star3,

  /// A lesson completed.
  complete,

  /// A level reached.
  levelup,

  /// A streak extended.
  streak;

  /// The image-mode preference that turns the sounds on and off.
  static const key = 'study.sound';

  /// The platform channel to the sound player.
  static const channel = MethodChannel('work.nextline.tegnal/study_sound');

  static Preferences? _store;
  static bool _local = true;

  /// Stores [isOn] in [preferences] (the image-mode store); `StudyMode.attach` calls this.
  static void attach(Preferences preferences) => _store = preferences;

  /// Whether sounds play; on unless the learner turned them off.
  static bool get isOn => _store != null ? _store!.boolean(key) ?? true : _local;
  static set isOn(bool value) {
    _local = value;
    _store?.set(key, value);
  }

  static void _send(String method, [Object? arguments]) {
    if (kIsWeb) return;
    unawaited(channel.invokeMethod<void>(method, arguments).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Loads every sound, so that the first one played does not arrive late.
  static void warm() {
    if (!isOn) return;
    _send('warm', {
      'names': [for (final sound in values) sound.name],
    });
  }

  /// Lets the sound player go once learning mode is left; the next sound starts it again.
  static void rest() => _send('rest');

  /// Plays this sound from the start, if sounds are on.
  void play() {
    if (!isOn) return;
    _send('play', {'name': name});
  }
}

/// What the guide says when an answer is in. The words change so that praise does not wear out.
abstract final class StudyPraise {
  /// The lines for a right answer (English keys of [L10n]).
  static const right = ["That's right!", 'Nice!', 'Great job!', 'Exactly!', 'You got it!'];

  /// The lines for a wrong answer.
  static const wrong = ['Not quite', 'Almost!', 'So close!'];

  /// The runs of right answers that are called out.
  static const Set<int> runs = {3, 5, 10, 15, 20, 30};

  /// A line for an answer; [seed] picks among the lines, and long runs get their own words.
  static String line({required bool right, required int combo, required int seed}) {
    if (right && combo >= 10) return L10n.text('Unstoppable!');
    if (right && combo >= 5) return L10n.text('On fire!');
    final lines = right ? StudyPraise.right : wrong;
    return L10n.text(lines[seed.abs() % lines.length]);
  }
}

/// A steady value in 0..<1 for a piece of an effect, so that every frame draws the same piece the same way. The
/// arithmetic is Swift's `UInt64` wrap-around, so a piece looks as it does on iOS.
double studyUnit(int index, int salt) {
  var value = index * 2654435761 + salt * 40503 + 12345;
  value ^= value >>> 15;
  value *= 2246822519;
  value ^= value >>> 13;
  // `value % 10000` for the unsigned reading of the 64 bits.
  final remainder = (2 * ((value >>> 1) % 10000) + (value & 1)) % 10000;
  return remainder / 10000;
}

/// Sparks thrown out from the middle of the box, once each time [trigger] changes (`StudyBurst`). It paints beyond
/// its box without clipping and never changes its parent's size: give it tight room, such as `Positioned.fill`, and it
/// centers on that; with loose room it takes none and centers on its place.
class StudyBurst extends StatefulWidget {
  /// A burst of [count] pieces flying up to [reach] points.
  const StudyBurst({super.key, required this.trigger, this.count = 16, this.reach = 90, this.colors, this.onAppear = false});

  /// The burst fires each time this value changes.
  final int trigger;

  /// How many pieces.
  final int count;

  /// How far the pieces fly.
  final double reach;

  /// The pieces' colours in turn; null is gold, good, primary and flame.
  final List<Color>? colors;

  /// Fires as soon as it is on screen as well.
  final bool onAppear;

  /// How long a burst lasts.
  static const length = Duration(milliseconds: 850);

  @override
  State<StudyBurst> createState() => _StudyBurstState();
}

class _StudyBurstState extends State<StudyBurst> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: StudyBurst.length);
  bool _appeared = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_appeared) {
      _appeared = true;
      if (widget.onAppear) _fire();
    }
  }

  @override
  void didUpdateWidget(StudyBurst old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _fire();
  }

  void _fire() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final side = widget.reach * 2.6;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: constraints.isTight ? constraints.maxWidth : 0,
            height: constraints.isTight ? constraints.maxHeight : 0,
            child: OverflowBox(
              minWidth: side,
              maxWidth: side,
              minHeight: side,
              maxHeight: side,
              child: CustomPaint(
                key: const Key('study.burst'),
                painter: StudyBurstPainter(
                  progress: _controller,
                  count: widget.count,
                  reach: widget.reach,
                  colors: widget.colors ?? [theme.gold, theme.good, theme.primary, theme.flame],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws one moment of a burst from the middle of the canvas; paints nothing unless [progress] is running.
class StudyBurstPainter extends CustomPainter {
  /// A painter over [progress], which runs 0 to 1 while the burst is flying.
  StudyBurstPainter({required this.progress, required this.count, required this.reach, required this.colors}) : super(repaint: progress);

  /// The burst's clock.
  final AnimationController progress;

  /// How many pieces.
  final int count;

  /// How far they fly.
  final double reach;

  /// Their colours in turn.
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (!progress.isAnimating || colors.isEmpty) return;
    final p = progress.value;
    if (p >= 1) return;
    final ease = 1 - math.pow(1 - p, 3).toDouble();
    for (var index = 0; index < count; index++) {
      final angle = (index + studyUnit(index, 1) * 0.8) / count * 2 * math.pi;
      final distance = reach * (0.4 + studyUnit(index, 2) * 0.6) * ease;
      final color = colors[index % colors.length];
      final side = (5 + studyUnit(index, 4) * 7) * (1 - p * 0.4);
      canvas
        ..save()
        ..translate(size.width / 2 + math.cos(angle) * distance, size.height / 2 + math.sin(angle) * distance + 36 * p * p)
        ..rotate(p * 4 + studyUnit(index, 3) * 6);
      final paint = Paint()..color = color.withValues(alpha: color.a * (1 - p * p));
      if (index % 3 == 0) {
        canvas.drawPath(_spark(side * 1.6), paint);
      } else {
        canvas.drawOval(Rect.fromLTWH(-side / 2, -side / 2, side, side), paint);
      }
      canvas.restore();
    }
  }

  /// A four-pointed spark.
  static Path _spark(double side) {
    final path = Path();
    for (var index = 0; index < 8; index++) {
      final radius = index.isEven ? side / 2 : side / 6;
      final angle = index / 8 * 2 * math.pi;
      final point = Offset(math.cos(angle) * radius, math.sin(angle) * radius);
      index == 0 ? path.moveTo(point.dx, point.dy) : path.lineTo(point.dx, point.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(StudyBurstPainter old) => old.count != count || old.reach != reach || !listEquals(old.colors, colors) || old.progress != progress;
}

/// Shakes its child from side to side, ±9 points over two full waves, each time [travel] increases (`StudyShake`).
/// A smaller [travel] only resets it. Nothing moves with reduced motion.
class StudyShake extends StatefulWidget {
  /// Shakes [child] as [travel] goes up.
  const StudyShake({super.key, required this.travel, required this.child, this.duration = const Duration(milliseconds: 400)});

  /// A count that goes up for each shake; a shake covers one whole step.
  final double travel;

  /// How long a shake takes (the Swift views use a 0.4 s linear animation).
  final Duration duration;

  /// The content shaken.
  final Widget child;

  @override
  State<StudyShake> createState() => _StudyShakeState();
}

class _StudyShakeState extends State<StudyShake> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(vsync: this, value: widget.travel);

  @override
  void didUpdateWidget(StudyShake old) {
    super.didUpdateWidget(old);
    if (widget.travel == old.travel) return;
    if (widget.travel > old.travel && !MediaQuery.disableAnimationsOf(context)) {
      _controller.animateTo(widget.travel, duration: widget.duration, curve: Curves.linear);
    } else {
      _controller.value = widget.travel;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => Transform.translate(offset: Offset(9 * math.sin(_controller.value * math.pi * 4), 0), child: child),
    );
  }
}

/// A whole number that counts up to its value (`StudyCount`). It takes the text style around it and uses tabular
/// digits, so the number does not jiggle.
class StudyCount extends StatelessWidget {
  /// Shows [value] rounded, between [prefix] and [suffix], counting from [from] (default: no count, just [value]).
  const StudyCount({
    super.key,
    required this.value,
    this.from,
    this.prefix = '',
    this.suffix = '',
    this.duration = const Duration(milliseconds: 500),
    this.curve = Curves.easeOut,
    this.style,
  });

  /// The number counted to.
  final double value;

  /// Where the first count starts; later changes count on from what is shown.
  final double? from;

  /// Text before the number.
  final String prefix;

  /// Text after the number.
  final String suffix;

  /// How long a count takes.
  final Duration duration;

  /// The easing of the count.
  final Curve curve;

  /// Added to the surrounding text style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: from, end: value),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration,
      curve: curve,
      builder: (context, shown, _) => Text('$prefix${shown.round()}$suffix', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]).merge(style)),
    );
  }
}

/// Drives a value from where it is to the new target of [shown] along a spring, after a delay.
class _SpringShown extends StatefulWidget {
  const _SpringShown({required this.shown, required this.delay, required this.spring, required this.builder});
  final bool shown;
  final double delay;
  final StudySpring spring;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<_SpringShown> createState() => _SpringShownState();
}

class _SpringShownState extends State<_SpringShown> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late double _from = widget.shown ? 1 : 0;
  late double _to = _from;
  double _value = 0;

  double get _current {
    if (_controller.status != AnimationStatus.forward) return _to;
    final total = _controller.duration!.inMicroseconds;
    final elapsed = _controller.value * total / Duration.microsecondsPerSecond;
    if (elapsed <= widget.delay) return _from;
    return _from +
        (_to - _from) * widget.spring.transform(((elapsed - widget.delay) / (total / Duration.microsecondsPerSecond - widget.delay)).clamp(0.0, 1.0));
  }

  @override
  void didUpdateWidget(_SpringShown old) {
    super.didUpdateWidget(old);
    if (old.shown == widget.shown) return;
    _value = _current;
    _from = _value;
    _to = widget.shown ? 1 : 0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _from = _to;
      return;
    }
    _controller.duration = Duration(microseconds: (widget.delay * Duration.microsecondsPerSecond).round()) + widget.spring.settle;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _controller, builder: (context, _) => widget.builder(context, _current));
}

/// Springs in from small the first time it is shown, after a wait (`studyPop`): scale and opacity on a 0.5 s spring
/// with bounce 0.5.
class StudyPop extends StatelessWidget {
  /// Shows [child] once [shown] is true, after [delay] seconds, growing from [from] times its size.
  const StudyPop({super.key, required this.shown, required this.child, this.delay = 0, this.from = 0.4});

  /// Whether the child is in.
  final bool shown;

  /// Seconds to wait before it moves.
  final double delay;

  /// The scale it starts from.
  final double from;

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) => _SpringShown(
    shown: shown,
    delay: delay,
    spring: StudySpring.pop,
    builder: (context, value) => Opacity(
      opacity: value.clamp(0.0, 1.0),
      child: Transform.scale(scale: from + (1 - from) * value, child: child),
    ),
  );
}

/// Slides up into place the first time it is shown, after a wait (`studyRise`): offset and opacity on a 0.45 s spring
/// with bounce 0.3.
class StudyRise extends StatelessWidget {
  /// Shows [child] once [shown] is true, after [delay] seconds, rising [by] points.
  const StudyRise({super.key, required this.shown, required this.child, this.delay = 0, this.by = 26});

  /// Whether the child is in.
  final bool shown;

  /// Seconds to wait before it moves.
  final double delay;

  /// The distance it rises.
  final double by;

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) => _SpringShown(
    shown: shown,
    delay: delay,
    spring: StudySpring.rise,
    builder: (context, value) => Opacity(
      opacity: value.clamp(0.0, 1.0),
      child: Transform.translate(offset: Offset(0, by * (1 - value)), child: child),
    ),
  );
}

/// Called out across the top of a lesson when right answers run on (`StudyComboBanner`). Its key is
/// `Key('study.combo')` unless one is given.
class StudyComboBanner extends StatefulWidget {
  /// A banner for a run of [combo] right answers.
  const StudyComboBanner({super.key = const Key('study.combo'), required this.combo});

  /// The length of the run.
  final int combo;

  @override
  State<StudyComboBanner> createState() => _StudyComboBannerState();
}

class _StudyComboBannerState extends State<StudyComboBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  // The flame grows and shrinks, then rests: the phases 1, 1.25 and 1, each 0.3 s ease in-out.
  static final _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.25).chain(CurveTween(curve: Curves.easeInOut)), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: 1),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 1),
  ]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    const white = Color(0xFFFFFFFF);
    return Semantics(
      container: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 4,
            bottom: -4,
            child: DecoratedBox(
              decoration: ShapeDecoration(color: studyEdge(theme.flame), shape: const StadiumBorder()),
            ),
          ),
          DecoratedBox(
            decoration: ShapeDecoration(
              gradient: LinearGradient(colors: [theme.flame, theme.gold]),
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: _pulse.drive(_scale),
                    child: Icon(StudyGlyph.icon('flame.fill'), size: 22, color: white),
                  ),
                  const SizedBox(width: 8),
                  Text(L10n.text('%@ in a row!', ['${widget.combo}']), style: StudyTheme.title(20).copyWith(color: white)),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: StudyBurst(trigger: widget.combo, count: 14, reach: 80, colors: [theme.gold, theme.flame, white], onAppear: true),
          ),
        ],
      ),
    );
  }
}
