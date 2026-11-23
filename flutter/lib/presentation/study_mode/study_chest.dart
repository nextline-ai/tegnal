import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';

import '../../core/lab/lab_store.dart';
import '../../core/study/study_path.dart';
import '../../core/support/l10n.dart';
import '../study/study_result_view.dart' show StudyConfetti;
import 'study_kit.dart';
import 'study_reactions.dart';

// The 보석 a 2D AI 배우기 lesson paid, opened from a treasure chest. Ported from `StudyChestPage`, `StudyChest` and
// `StudyChestArt` in `StudyReactions.swift`; the chest is painted on the same 220 × 200 grid.

const _white = Color(0xFFFFFFFF);

ShapeBorder _rounded(double radius, [BorderSide side = BorderSide.none]) => RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

/// The gems' colours: sky, the course's violet, pink, mint and gold.
const studyGemColors = [Color(0xFF37D5FF), Color(0xFF7C5CFF), Color(0xFFFF5FA2), Color(0xFF3EDC9B), Color(0xFFFFB627)];

/// The 보석 a lesson paid, in a treasure chest. It waits, wobbling, until it is tapped or the button below is pressed
/// ([opened]); then it shakes three times, its lid bursts open with light, the gems fly up into the counter, the counter
/// climbs from the balance before to the balance after, and what paid comes in line by line.
class StudyChestPage extends StatefulWidget {
  const StudyChestPage({super.key, required this.reward, required this.opened, required this.onOpen, this.stage = 0});

  final StudyGemReward reward;

  /// Whether the chest has been opened, here or by the button below.
  final bool opened;

  /// Called when the chest itself is tapped.
  final VoidCallback onOpen;

  /// Starts the page further on, for pictures of it.
  final int stage;

  @override
  State<StudyChestPage> createState() => _StudyChestPageState();
}

class _StudyChestPageState extends State<StudyChestPage> with TickerProviderStateMixin {
  /// Where the counter sits, from the chest's centre, so the gems fly into it.
  static const _counterLift = -205.0;
  static final _lidSpring = StudySpring(0.7, 0.4);
  static final _raysSpring = StudySpring(0.6, 0.3);

  /// 0 closed, 1 shaking, 2 open with the gems in flight, 3 counted, 4 what paid listed.
  late int _stage = widget.stage;
  late bool _shown = widget.stage > 0;
  bool _disposed = false;
  late final AnimationController _idle = AnimationController(vsync: this, duration: const Duration(milliseconds: 1320));
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  late final AnimationController _flight = AnimationController(vsync: this, duration: const Duration(milliseconds: 1700));
  late final AnimationController _rays = AnimationController(vsync: this, duration: const Duration(seconds: 20));
  late final AnimationController _hint = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduce = MediaQuery.disableAnimationsOf(context);
      setState(() => _shown = true);
      if (_stage >= 2 && !reduce) _rays.repeat();
      if (_stage > 0) return;
      StudySound.star1.play();
      if (!reduce) {
        _idle.repeat();
        _hint.repeat(reverse: true);
      }
      if (widget.opened) unawaited(_open());
    });
  }

  @override
  void didUpdateWidget(StudyChestPage old) {
    super.didUpdateWidget(old);
    if (widget.opened && !old.opened) unawaited(_open());
  }

  @override
  void dispose() {
    _disposed = true;
    _idle.dispose();
    _shake.dispose();
    _flight.dispose();
    _rays.dispose();
    _hint.dispose();
    super.dispose();
  }

  void _setStage(int stage) {
    if (!_disposed) setState(() => _stage = stage);
  }

  Future<void> _open() async {
    if (_stage != 0) return;
    Future<void> wait(int milliseconds) => Future<void>.delayed(Duration(milliseconds: milliseconds));
    if (MediaQuery.disableAnimationsOf(context)) {
      _setStage(4);
      StudySound.levelup.play();
      unawaited(HapticFeedback.mediumImpact());
      return;
    }
    _idle.stop();
    _hint.stop();
    _setStage(1);
    for (var shake = 0; shake < 3; shake++) {
      unawaited(HapticFeedback.heavyImpact());
      StudySound.pick.play();
      unawaited(_shake.forward(from: 0));
      await wait(240);
      if (_disposed) return;
    }
    _setStage(2);
    StudySound.levelup.play();
    unawaited(HapticFeedback.mediumImpact());
    _rays.repeat();
    unawaited(_flight.forward(from: 0));
    await wait(1150);
    if (_disposed) return;
    _setStage(3);
    StudySound.combo.play();
    await wait(900);
    if (_disposed) return;
    _setStage(4);
    unawaited(HapticFeedback.mediumImpact());
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final open = _stage >= 2;
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
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _chest(theme, reduce, open),
                          const SizedBox(height: 16),
                          StudyRise(
                            shown: _shown,
                            delay: 0.2,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Text(
                                open ? L10n.text('study.chest.got', ['${widget.reward.paid.total}']) : L10n.text('study.chest.title'),
                                key: ValueKey(open),
                                textAlign: TextAlign.center,
                                style: StudyTheme.title(30).copyWith(color: theme.ink),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (!open)
                            StudyRise(
                              shown: _shown,
                              delay: 0.3,
                              child: AnimatedBuilder(
                                animation: _hint,
                                builder: (context, child) => Transform.translate(offset: Offset(0, -5 * Curves.easeInOut.transform(_hint.value)), child: child),
                                child: Text(L10n.text('study.chest.hint'), style: StudyTheme.body(16, StudyTheme.bold).copyWith(color: theme.muted)),
                              ),
                            )
                          else
                            _lines(theme),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (open && !reduce)
          const Positioned.fill(
            child: IgnorePointer(child: ExcludeSemantics(child: StudyConfetti(pieces: 90))),
          ),
      ],
    );
  }

  /// The counter above, the light, the chest and the gems in flight. The counter is painted last, over the light.
  Widget _chest(StudyTheme theme, bool reduce, bool open) {
    return SizedBox(
      width: 260,
      height: 120 + 230,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 120,
            height: 230,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                _light(theme, open),
                Semantics(
                  identifier: 'study.chest',
                  button: _stage == 0,
                  label: L10n.text('study.chest.title'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.opened ? null : widget.onOpen,
                    child: StudyPop(
                      shown: _shown,
                      from: 0.3,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_idle, _shake]),
                        builder: (context, child) {
                          final tilt = _stage == 0 ? _idleTilt(_idle.value) : _shakeTilt(_shake.value);
                          return Transform(
                            alignment: Alignment.bottomCenter,
                            transform: Matrix4.identity()
                              ..rotateZ(tilt * math.pi / 180)
                              ..scaleByDouble(1 + tilt.abs() / 120, 1 - tilt.abs() / 160, 1, 1),
                            child: child,
                          );
                        },
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: open ? 1 : 0),
                          duration: reduce ? Duration.zero : _lidSpring.settle,
                          curve: _lidSpring,
                          builder: (context, openness, _) => CustomPaint(size: const Size(220, 200), painter: StudyChestPainter(openness)),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: StudyBurst(trigger: open ? 1 : 0, count: 30, reach: 170, colors: [...studyGemColors, _white]),
                  ),
                ),
                if (!reduce) IgnorePointer(child: ExcludeSemantics(child: _gems())),
              ],
            ),
          ),
          Positioned(top: 0, child: _counter(theme)),
        ],
      ),
    );
  }

  /// A gentle wobble every 1.3 s while the chest waits.
  static double _idleTilt(double value) {
    const tilts = [0.0, -3.5, 3.5, 0.0, 0.0, 0.0];
    final position = value * tilts.length;
    final index = position.floor() % tilts.length;
    final next = (index + 1) % tilts.length;
    return tilts[index] + (tilts[next] - tilts[index]) * Curves.easeInOut.transform(position - position.floor());
  }

  /// One shake: −9°, 9°, −5°, back.
  static double _shakeTilt(double value) {
    const keys = [0.0, -9.0, 9.0, -5.0, 0.0];
    const times = [0.0, 0.23, 0.55, 0.77, 1.0];
    for (var index = 1; index < keys.length; index++) {
      if (value <= times[index]) {
        final local = (value - times[index - 1]) / (times[index] - times[index - 1]);
        return keys[index - 1] + (keys[index] - keys[index - 1]) * Curves.easeInOut.transform(local.clamp(0, 1));
      }
    }
    return 0;
  }

  /// The balance, with the gem it is counted in; it climbs once the gems land and swells a little as it settles.
  Widget _counter(StudyTheme theme) {
    final counted = _stage >= 3;
    return StudyRise(
      shown: _shown,
      delay: 0.1,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: _stage == 3 ? 1.12 : 1),
        duration: const Duration(milliseconds: 400),
        curve: StudySpring(0.4, 0.6),
        builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: ShapeDecoration(
            color: theme.surface,
            shape: StadiumBorder(side: BorderSide(color: counted ? theme.gold : theme.line, width: 2)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              Text(LabStore.shared.shop.currency.text, style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: theme.muted)),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  const StudyGem(size: 30, color: Color(0xFF37D5FF)),
                  Semantics(
                    identifier: 'study.chest.balance',
                    child: StudyCount(
                      from: widget.reward.before.toDouble(),
                      value: (counted ? widget.reward.after : widget.reward.before).toDouble(),
                      duration: const Duration(milliseconds: 1000),
                      style: StudyTheme.title(40).copyWith(color: theme.ink),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Light turning behind the chest once it is open.
  Widget _light(StudyTheme theme, bool open) {
    return Transform.translate(
      offset: const Offset(0, -30),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: open ? 1 : 0),
        duration: _raysSpring.settle,
        curve: _raysSpring,
        builder: (context, value, child) => Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.1 + 0.9 * value, child: child),
        ),
        child: SizedBox.square(
          dimension: 260,
          child: Stack(
            alignment: Alignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [const Color(0xFFFFF3B0), theme.gold.withValues(alpha: 0.45), theme.gold.withValues(alpha: 0)]),
                ),
                child: const SizedBox.square(dimension: 240),
              ),
              RotationTransition(
                turns: _rays,
                child: CustomPaint(size: const Size.square(260), painter: _Rays(theme.gold.withValues(alpha: 0.28))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The gems: out of the chest in a fan, a moment in the air, then into the counter above.
  Widget _gems() {
    final count = math.min(14, math.max(6, widget.reward.paid.total ~/ 5));
    return AnimatedBuilder(
      animation: _flight,
      builder: (context, _) {
        final seconds = _flight.value * 1.7;
        return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [for (var index = 0; index < count; index++) _gem(index, count, seconds)]);
      },
    );
  }

  Widget _gem(int index, int count, double seconds) {
    final spread = index / math.max(1, count - 1) - 0.5;
    final spray = Offset(spread * 230, -70 - (math.sin(index * 1.7)).abs() * 70);
    const start = Offset(0, -20);
    final local = seconds - index * 0.045;
    if (_stage < 2 || local <= 0 || local >= 1.04) return const SizedBox.shrink();
    Offset offset;
    double scale;
    if (local < 0.5) {
      final t = Curves.easeOutBack.transform(local / 0.5);
      offset = Offset.lerp(start, spray, t)!;
      scale = 0.2 + 0.95 * t;
    } else if (local < 0.62) {
      offset = spray;
      scale = 1;
    } else {
      final t = Curves.easeInCubic.transform((local - 0.62) / 0.42);
      offset = Offset.lerp(spray, const Offset(0, _counterLift), t)!;
      scale = 1 - 0.55 * t;
    }
    final opacity = local < 0.06 ? local / 0.06 : (local > 0.98 ? (1.04 - local) / 0.06 : 1.0);
    return Transform.translate(
      offset: offset,
      child: Transform.rotate(
        angle: spread * 140 * math.min(1, local / 1.04) * math.pi / 180,
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: StudyGem(size: 26, color: studyGemColors[index % studyGemColors.length]),
          ),
        ),
      ),
    );
  }

  /// What paid, line by line: the lesson, its three stars, its section.
  Widget _lines(StudyTheme theme) {
    final paid = widget.reward.paid;
    final rows = [
      ('checkmark.circle.fill', L10n.text('study.chest.lesson'), theme.good, paid.lesson),
      ('star.fill', L10n.text('study.chest.stars'), theme.gold, paid.stars),
      ('flag.checkered', L10n.text('study.chest.section'), theme.primary, paid.section),
    ].where((row) => row.$4 > 0).toList();
    return Semantics(
      identifier: 'study.chest.lines',
      container: true,
      child: Column(
        spacing: 8,
        children: [
          for (var index = 0; index < rows.length; index++)
            StudyRise(
              shown: _stage >= 4,
              delay: index * 0.12,
              child: MergeSemantics(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: ShapeDecoration(
                    color: theme.surface,
                    shape: _rounded(16, BorderSide(color: theme.line, width: 2)),
                  ),
                  child: Row(
                    spacing: 10,
                    children: [
                      SizedBox(width: 24, child: StudyIcon(rows[index].$1, size: 17, color: rows[index].$3)),
                      Expanded(
                        child: Text(rows[index].$2, style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: theme.ink)),
                      ),
                      Text(
                        '+${rows[index].$4}',
                        style: StudyTheme.body(17, StudyTheme.heavy).copyWith(color: theme.primary, fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A cut gem: a diamond with a lighter crown and a white glint, in the course's chunky style.
class StudyGem extends StatelessWidget {
  const StudyGem({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size * 1.15), painter: _GemPainter(color));
}

class _GemPainter extends CustomPainter {
  const _GemPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // The square diamond of SF Symbols' diamond.fill, as the iOS app draws it.
    final half = size.height * 0.44;
    canvas.drawPath(StudyChestPainter.diamond(center.translate(0, half / 6), half, 1), Paint()..color = studyEdge(color));
    canvas.drawPath(StudyChestPainter.diamond(center, half, 1), Paint()..color = color);
    canvas.drawPath(StudyChestPainter.diamond(center.translate(-half * 0.24, -half * 0.28), half * 0.42, 1), Paint()..color = _white.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(_GemPainter old) => old.color != color;
}

/// Twelve capsules 12 by 170 points standing out from the middle, 30 degrees apart.
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
        ..drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-6, -170, 12, 170), const Radius.circular(6)), paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_Rays old) => old.color != color;
}

/// A treasure chest on a 220 × 200 grid. [openness] runs from 0 (shut) to 1 (open; a spring may overshoot): the outside
/// of the domed lid folds down onto its hinge, then its lit inside rises behind the glowing mouth, and the lock drops away.
class StudyChestPainter extends CustomPainter {
  const StudyChestPainter(this.openness);
  final double openness;

  static const _ink = Color(0xFF4A1F07);
  static const _goldColors = [Color(0xFFFFE9A6), Color(0xFFFFC02E), Color(0xFFD48A06)];

  /// The lid's dome, with its foot at [base] and [height] above it.
  static Path dome(double base, double height, [double inset = 0]) {
    final left = 8 + inset, right = 212 - inset, h = math.max(0.0, height);
    return Path()
      ..moveTo(left, base)
      ..lineTo(left, base - h * 0.45)
      ..cubicTo(left, base - h * 0.85, 52, base - h, 110, base - h)
      ..cubicTo(168, base - h, right, base - h * 0.85, right, base - h * 0.45)
      ..lineTo(right, base)
      ..close();
  }

  /// A diamond [size] from its centre to its top; [width] of that to its sides.
  static Path diamond(Offset center, double size, [double width = 0.8]) => Path()
    ..moveTo(center.dx, center.dy - size)
    ..lineTo(center.dx + size * width, center.dy)
    ..lineTo(center.dx, center.dy + size)
    ..lineTo(center.dx - size * width, center.dy)
    ..close();

  static Paint _gold(Rect rect, {bool across = false}) => Paint()
    ..shader = LinearGradient(
      begin: across ? Alignment.centerLeft : Alignment.topCenter,
      end: across ? Alignment.centerRight : Alignment.bottomCenter,
      colors: _goldColors,
    ).createShader(rect);

  static Paint _vertical(Color top, Color bottom, double from, double to) =>
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(Rect.fromLTRB(0, from, 220, to));

  static Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..color = color;

  static void _rivet(Canvas canvas, double x, double y) {
    canvas
      ..drawCircle(Offset(x, y), 3.2, Paint()..color = const Color(0xFF9A5F05))
      ..drawCircle(Offset(x - 0.8, y - 1), 1.2, Paint()..color = _white.withValues(alpha: 0.75));
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..scale(size.width / 220, size.height / 200);
    final t = openness;
    final shut = math.max(0.0, 1 - t / 0.45);
    final rise = math.min(1.12, math.max(0.0, (t - 0.45) / 0.55));
    final lit = math.min(1.0, math.max(0.0, t * 2));

    // Shadow on the ground.
    canvas.drawOval(const Rect.fromLTWH(22, 176, 176, 18), Paint()..color = const Color(0x29000000));

    // The inside of the lid, standing behind the mouth once it swings past upright; lit from below by what is inside.
    if (rise > 0) {
      final inside = dome(88, 80 * rise);
      canvas
        ..drawPath(inside, _vertical(const Color(0xFF7A3814), const Color(0xFF4A1C07), 88 - 80 * rise, 88))
        ..save()
        ..clipPath(inside);
      for (final x in [36.0, 166.0]) {
        canvas.drawRect(Rect.fromLTWH(x, 0, 18, 90), Paint()..color = const Color(0xFFB87908));
      }
      canvas
        ..drawRect(const Rect.fromLTWH(0, 40, 220, 48), _vertical(const Color(0x00FFD45A), const Color(0x8CFFD45A), 40, 88))
        ..restore()
        ..drawPath(
          dome(88, 80 * rise, 3),
          _gold(const Rect.fromLTWH(0, 10, 220, 80))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 6,
        )
        ..drawPath(inside, _stroke(_ink, 3));
    }

    // The mouth: the dark inside of the box, with a heap of coins and gems spilling over the rim.
    if (lit > 0) {
      final mouth = RRect.fromRectAndRadius(const Rect.fromLTWH(14, 76, 192, 28), const Radius.circular(10));
      canvas
        ..drawRRect(mouth, Paint()..color = const Color(0xFF3A1604))
        ..drawRRect(
          mouth,
          Paint()
            ..shader = RadialGradient(
              colors: [
                const Color(0xFFFFF6CC).withValues(alpha: lit),
                const Color(0xFFFFC23A).withValues(alpha: 0.8 * lit),
                const Color(0x00FFC23A),
              ],
            ).createShader(Rect.fromCircle(center: const Offset(110, 92), radius: 96)),
        )
        ..drawRRect(
          mouth,
          _gold(const Rect.fromLTWH(14, 76, 192, 28))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4,
        )
        ..drawRRect(mouth, _stroke(_ink, 2))
        ..save()
        ..translate(0, 10 * (1 - lit));
      final fade = Paint()..color = Color.fromRGBO(0, 0, 0, lit);
      canvas.saveLayer(null, fade);
      for (final (x, y) in const [
        (40.0, 80.0),
        (58.0, 74.0),
        (76.0, 78.0),
        (96.0, 71.0),
        (124.0, 72.0),
        (144.0, 77.0),
        (162.0, 73.0),
        (180.0, 80.0),
        (68.0, 84.0),
        (110.0, 79.0),
        (152.0, 84.0),
      ]) {
        final coin = Rect.fromLTWH(x - 9, y - 5, 18, 10);
        canvas
          ..drawOval(coin.shift(const Offset(0, 1.5)), Paint()..color = const Color(0xFF9A5F05))
          ..drawOval(coin, _gold(coin))
          ..drawOval(coin.deflate(4), Paint()..color = _white.withValues(alpha: 0.35));
      }
      const points = [Offset(52, 70), Offset(84, 64), Offset(112, 60), Offset(138, 65), Offset(168, 70)];
      for (var index = 0; index < points.length; index++) {
        final color = studyGemColors[index % studyGemColors.length];
        canvas
          ..drawPath(diamond(points[index].translate(0, 2), 11), Paint()..color = studyEdge(color))
          ..drawPath(diamond(points[index], 11), Paint()..color = color)
          ..drawPath(diamond(points[index].translate(-2.5, -3), 4), Paint()..color = _white.withValues(alpha: 0.7));
      }
      canvas
        ..restore()
        ..restore();
    }

    // The body.
    final body = RRect.fromRectAndRadius(const Rect.fromLTWH(12, 92, 196, 88), const Radius.circular(14));
    canvas
      ..drawRRect(body, _vertical(const Color(0xFFCB7C3E), const Color(0xFF8A4418), 92, 180))
      ..save()
      ..clipRRect(body);
    for (final y in [122.0, 151.0]) {
      canvas
        ..drawRect(Rect.fromLTWH(12, y, 196, 2.2), Paint()..color = const Color(0x8C5E290B))
        ..drawRect(Rect.fromLTWH(12, y + 2.2, 196, 1.4), Paint()..color = const Color(0x21FFFFFF));
    }
    // Light from the left, shade on the right.
    canvas
      ..drawRect(
        const Rect.fromLTWH(12, 92, 40, 88),
        Paint()..shader = const LinearGradient(colors: [Color(0x24FFFFFF), Color(0x00FFFFFF)]).createShader(const Rect.fromLTWH(12, 92, 40, 88)),
      )
      ..drawRect(
        const Rect.fromLTWH(160, 92, 48, 88),
        Paint()..shader = const LinearGradient(colors: [Color(0x00000000), Color(0x33000000)]).createShader(const Rect.fromLTWH(160, 92, 48, 88)),
      );
    const top = Rect.fromLTWH(12, 92, 196, 11), foot = Rect.fromLTWH(12, 168, 196, 12);
    canvas
      ..drawRect(top, _gold(top))
      ..drawRect(foot, _gold(foot));
    for (final x in [36.0, 166.0]) {
      final band = Rect.fromLTWH(x, 92, 18, 88);
      canvas
        ..drawRect(band, _gold(band, across: true))
        ..drawRect(band, _stroke(_ink.withValues(alpha: 0.45), 1.2));
    }
    canvas
      ..restore()
      ..drawRRect(body, _stroke(_ink, 3));
    for (final x in [45.0, 175.0]) {
      for (final y in [116.0, 158.0]) {
        _rivet(canvas, x, y);
      }
    }

    // The outside of the lid, folding down onto its hinge as it opens.
    if (shut > 0) {
      final lid = dome(94, 80 * shut);
      canvas
        ..drawPath(lid, _vertical(const Color(0xFFDA8C47), const Color(0xFF99491B), 94 - 80 * shut, 94))
        ..save()
        ..clipPath(lid);
      for (final x in [36.0, 166.0]) {
        final band = Rect.fromLTWH(x, 0, 18, 94);
        canvas
          ..drawRect(band, _gold(band, across: true))
          ..drawRect(band, _stroke(_ink.withValues(alpha: 0.45), 1.2));
      }
      final rim = Rect.fromLTWH(0, 94 - 11 * shut, 220, 11 * shut);
      canvas
        ..drawRect(rim, _gold(rim))
        ..drawOval(Rect.fromLTWH(44, 94 - 76 * shut, 132, 22 * shut), Paint()..color = _white.withValues(alpha: 0.22))
        ..restore()
        ..drawPath(lid, _stroke(_ink, 3));
      if (shut > 0.6) {
        for (final x in [45.0, 175.0]) {
          _rivet(canvas, x, 94 - 46 * shut);
        }
      }
    }

    // The lock, across the seam; it drops away first.
    final fall = math.min(1.0, t / 0.3);
    if (fall < 1) {
      canvas
        ..saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, 1 - fall))
        ..translate(0, 46 * fall);
      const plate = Rect.fromLTWH(92, 80, 36, 40);
      final shape = RRect.fromRectAndRadius(plate, const Radius.circular(9));
      canvas
        ..drawRRect(shape.shift(const Offset(0, 3)), Paint()..color = _ink)
        ..drawRRect(shape, _gold(plate))
        ..drawRRect(shape, _stroke(_ink, 2.5))
        ..drawOval(const Rect.fromLTWH(104.5, 89, 11, 11), Paint()..color = _ink)
        ..drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(107.5, 96, 5, 13), const Radius.circular(2)), Paint()..color = _ink)
        ..restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(StudyChestPainter old) => old.openness != openness;
}
