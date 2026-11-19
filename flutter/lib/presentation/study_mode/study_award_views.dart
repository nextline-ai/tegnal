import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../core/study/study_awards.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../study/study_result_view.dart' show StudyConfetti;
import 'study_kit.dart';
import 'study_mode_model.dart';
import 'study_reactions.dart';

// Badges are drawn, not pictured: a metal body with a bevelled rim, a sunken plate, an embossed sign and a light
// that sweeps across. A badge not yet earned is the same shape in shadow, ringed by how far along it is.
// Ported from `StudyAwardViews.swift`.

// MARK: - Shape and metal

/// The outline of a badge (`StudyBadgeShape`). Each family has its own, so that a shelf of badges reads at a glance.
class StudyBadgeShape {
  /// The outline of [family]'s badges.
  const StudyBadgeShape(this.family);

  /// Whose outline this is.
  final StudyAwardFamily family;

  /// The outline in [rect], centred and as wide as the shorter side.
  Path path(Rect rect) {
    final side = math.min(rect.width, rect.height);
    final center = rect.center;
    final radius = side / 2;
    List<Offset> ring(int count, {double inner = 1, double turn = -math.pi / 2}) {
      final points = <Offset>[];
      for (var index = 0; index < count; index++) {
        final length = radius * (inner < 1 && index % 2 == 1 ? inner : 1);
        final angle = turn + index / count * 2 * math.pi;
        points.add(Offset(center.dx + math.cos(angle) * length, center.dy + math.sin(angle) * length));
      }
      return points;
    }

    switch (family) {
      case StudyAwardFamily.lessons:
        return _rounded(ring(6), side * 0.1);
      case StudyAwardFamily.streak:
        return _rounded(ring(24, inner: 0.9), side * 0.05);
      case StudyAwardFamily.tags:
        return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
      case StudyAwardFamily.perfect:
        return _rounded(ring(10, inner: 0.62), side * 0.07);
      case StudyAwardFamily.combo:
        return _rounded(ring(16, inner: 0.8), side * 0.045);
      case StudyAwardFamily.xp:
        return _rounded(ring(4), side * 0.14);
      case StudyAwardFamily.studio:
        return _rounded(ring(8, turn: -math.pi / 2 + math.pi / 8), side * 0.09);
      case StudyAwardFamily.speed:
        return _rounded(ring(5), side * 0.11);
      case StudyAwardFamily.sections:
        // A shield: flat across the top, drawn in to a point at the foot.
        final left = center.dx - radius * 0.86, right = center.dx + radius * 0.86, top = center.dy - radius * 0.92;
        return Path()
          ..moveTo(center.dx, top + radius * 0.1)
          ..quadraticBezierTo(center.dx + radius * 0.5, top + radius * 0.14, right, top)
          ..lineTo(right, center.dy + radius * 0.12)
          ..quadraticBezierTo(right, center.dy + radius * 0.72, center.dx, center.dy + radius)
          ..quadraticBezierTo(left, center.dy + radius * 0.72, left, center.dy + radius * 0.12)
          ..lineTo(left, top)
          ..quadraticBezierTo(center.dx - radius * 0.5, top + radius * 0.14, center.dx, top + radius * 0.1)
          ..close();
    }
  }

  /// A polygon through [points] with its corners rounded off: it starts halfway along the last side, and each
  /// corner is an arc of [corner] tangent to its two sides, ending on the way to the middle of the next side.
  static Path _rounded(List<Offset> points, double corner) {
    final path = Path();
    if (points.length <= 2) return path;
    final last = points.last;
    var current = Offset((last.dx + points[0].dx) / 2, (last.dy + points[0].dy) / 2);
    path.moveTo(current.dx, current.dy);
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      final middle = Offset((points[index].dx + next.dx) / 2, (points[index].dy + next.dy) / 2);
      current = _arcTangent(path, current, points[index], middle, corner);
    }
    return path..close();
  }

  /// `CGPath.addArc(tangent1End:tangent2End:radius:)`: a line from [from] to where a circle of [radius] touches the
  /// side towards [corner], then the arc to where it touches the side from [corner] to [to]. Returns the arc's end.
  static Offset _arcTangent(Path path, Offset from, Offset corner, Offset to, double radius) {
    final a = from - corner, b = to - corner;
    final la = a.distance, lb = b.distance;
    if (la < 1e-9 || lb < 1e-9 || radius <= 0) {
      path.lineTo(corner.dx, corner.dy);
      return corner;
    }
    final u = a / la, v = b / lb;
    final angle = math.acos((u.dx * v.dx + u.dy * v.dy).clamp(-1.0, 1.0));
    if (angle < 1e-6 || math.pi - angle < 1e-6) {
      path.lineTo(corner.dx, corner.dy);
      return corner;
    }
    final reach = radius / math.tan(angle / 2);
    final start = corner + u * reach, end = corner + v * reach;
    path.lineTo(start.dx, start.dy);
    // On screen, with y pointing down, a positive cross product turns clockwise.
    final turn = (corner.dx - from.dx) * (to.dy - corner.dy) - (corner.dy - from.dy) * (to.dx - corner.dx);
    path.arcToPoint(end, radius: Radius.circular(radius), clockwise: turn > 0);
    return end;
  }
}

class _BadgeClipper extends CustomClipper<Path> {
  const _BadgeClipper(this.family);
  final StudyAwardFamily family;

  @override
  Path getClip(Size size) => StudyBadgeShape(family).path(Offset.zero & size);

  @override
  bool shouldReclip(_BadgeClipper old) => old.family != family;
}

/// The colours a badge is cast in (`StudyMetal`).
class StudyMetal {
  /// A metal from its three shades and, for the rarest, the hues that run round it.
  const StudyMetal({required this.light, required this.mid, required this.dark, this.hues});

  /// The metal of [award]: a section's own colour, or bronze, silver, gold or prism.
  factory StudyMetal.of(StudyAward award) {
    if (award.color case final hex?) {
      final base = studyHex(hex);
      return StudyMetal(light: studyLifted(base), mid: base, dark: studyEdge(base));
    }
    return switch (award.metal) {
      StudyAwardMetal.bronze => StudyMetal(light: studyHex('F3B37C'), mid: studyHex('CC7A3A'), dark: studyHex('7E4219')),
      StudyAwardMetal.silver => StudyMetal(light: studyHex('F7F9FC'), mid: studyHex('B4BDCB'), dark: studyHex('6C7686')),
      StudyAwardMetal.gold => StudyMetal(light: studyHex('FFEC9E'), mid: studyHex('FFB627'), dark: studyHex('B36B00')),
      StudyAwardMetal.prism => StudyMetal(
        light: studyHex('E9E4FF'),
        mid: studyHex('9B8CFF'),
        dark: studyHex('4A2FB8'),
        hues: [
          for (final hex in ['9B8CFF', '5CE1E6', '8DF5B6', 'FFE27A', 'FF8AD8', '9B8CFF']) studyHex(hex),
        ],
      ),
    };
  }

  /// Where light falls.
  final Color light;

  /// The body.
  final Color mid;

  /// The edge and the shadows.
  final Color dark;

  /// More than one hue running round the badge, for the rarest.
  final List<Color>? hues;
}

// MARK: - The badge

const _white = Color(0xFFFFFFFF);
const _clearWhite = Color(0x00FFFFFF);
const _clearBlack = Color(0x00000000);

Color _alpha(Color color, double opacity) => color.withValues(alpha: color.a * opacity);

/// A badge (`StudyMedal`): earned, it is cast metal that a light sweeps across now and then; not earned, it is the
/// same shape in shadow with a ring showing [progress] and a small lock. Earned, it is [size] square; not earned the
/// ring takes 9 % more on every side.
class StudyMedal extends StatefulWidget {
  /// The badge for [award].
  const StudyMedal({super.key, required this.award, this.earned = true, this.progress = 0, this.size = 92, this.shines = true});

  /// Which badge.
  final StudyAward award;

  /// Whether it has been earned.
  final bool earned;

  /// From zero to one, shown as a ring round a badge not yet earned.
  final double progress;

  /// The badge's width and height.
  final double size;

  /// A light sweeps across an earned badge now and then.
  final bool shines;

  /// One sweep: a wait, then the light crosses.
  static const wait = Duration(milliseconds: 2400);
  static const sweep = Duration(milliseconds: 1100);

  @override
  State<StudyMedal> createState() => _StudyMedalState();
}

class _StudyMedalState extends State<StudyMedal> with SingleTickerProviderStateMixin {
  AnimationController? _sweep;

  bool get _sweeps => widget.earned && widget.shines && !MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }

  @override
  void didUpdateWidget(StudyMedal old) {
    super.didUpdateWidget(old);
    _update();
  }

  void _update() {
    if (_sweeps) {
      final controller = _sweep ??= AnimationController(vsync: this, duration: StudyMedal.wait + StudyMedal.sweep);
      if (!controller.isAnimating) controller.repeat();
    } else {
      _sweep?.stop();
    }
  }

  @override
  void dispose() {
    _sweep?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final award = widget.award;
    final size = widget.size;
    final earned = widget.earned;
    final metal = StudyMetal.of(award);
    final lift = award.family == StudyAwardFamily.sections ? -size * 0.04 : 0.0;
    // An SF Symbol at a font size fills about as much as a Cupertino glyph a little larger.
    final glyph = size * 0.34;

    final Widget symbol = earned
        ? Stack(
            children: [
              // The hard shadow below the embossed sign.
              Transform.translate(
                offset: Offset(0, size * 0.022),
                child: StudyIcon(award.symbol, size: glyph, color: _alpha(metal.dark, 0.9)),
              ),
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (rect) =>
                    LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_white, metal.light]).createShader(rect),
                child: StudyIcon(award.symbol, size: glyph, color: _white),
              ),
            ],
          )
        : StudyIcon(award.symbol, size: glyph, color: _alpha(theme.muted, 0.45));

    final body = SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          CustomPaint(
            painter: _MedalPainter(family: award.family, earned: earned, metal: metal, line: theme.line, sunken: theme.sunken),
          ),
          Center(
            child: Transform.translate(offset: Offset(0, lift), child: symbol),
          ),
          if (_sweeps && _sweep != null)
            RepaintBoundary(
              child: ClipPath(
                clipper: _BadgeClipper(award.family),
                child: CustomPaint(painter: _SweepPainter(_sweep!)),
              ),
            ),
        ],
      ),
    );

    final Widget medal;
    if (earned) {
      medal = body;
    } else {
      final pad = size * 0.09;
      final outer = size + pad * 2;
      final lock = size * 0.15;
      medal = SizedBox.square(
        dimension: outer,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(left: pad, top: pad, width: size, height: size, child: body),
            Positioned.fill(
              child: CustomPaint(
                painter: _ProgressRingPainter(progress: widget.progress, width: size * 0.045, track: _alpha(theme.line, 0.6), fill: theme.primary),
              ),
            ),
            Positioned(
              right: pad,
              bottom: pad,
              child: Container(
                padding: EdgeInsets.all(size * 0.055),
                decoration: ShapeDecoration(
                  color: theme.surface,
                  shape: CircleBorder(side: BorderSide(color: theme.line, width: 1.5)),
                ),
                child: StudyIcon('lock.fill', size: lock, color: theme.muted),
              ),
            ),
          ],
        ),
      );
    }
    return Semantics(container: true, excludeSemantics: true, label: award.name, value: L10n.text(earned ? 'Earned' : 'Locked'), child: medal);
  }
}

/// Everything of a badge below its sign.
class _MedalPainter extends CustomPainter {
  const _MedalPainter({required this.family, required this.earned, required this.metal, required this.line, required this.sunken});
  final StudyAwardFamily family;
  final bool earned;
  final StudyMetal metal;
  final Color line;
  final Color sunken;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Offset.zero & canvasSize;
    final size = math.min(canvasSize.width, canvasSize.height);
    final shape = StudyBadgeShape(family).path(rect);
    Paint fill(Gradient gradient, Rect bounds) => Paint()
      ..isAntiAlias = true
      ..shader = gradient.createShader(bounds);
    Paint stroke(Gradient gradient, Rect bounds, double width) => fill(gradient, bounds)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    if (!earned) {
      canvas.drawPath(shape.shift(Offset(0, size * 0.04)), Paint()..color = line);
      canvas.drawPath(shape, Paint()..color = sunken);
      canvas
        ..save()
        ..clipPath(shape);
      canvas.drawPath(
        shape,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = size * 0.06,
      );
      canvas.restore();
      return;
    }

    // The edge the badge stands on gives it thickness.
    canvas.drawPath(shape.shift(Offset(0, size * 0.05)), Paint()..color = metal.dark);
    canvas.drawPath(shape, fill(LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [metal.light, metal.mid, metal.dark]), rect));
    if (metal.hues case final hues?) {
      canvas.drawPath(shape, fill(SweepGradient(colors: [for (final hue in hues) _alpha(hue, 0.75)]), rect)..blendMode = BlendMode.softLight);
      canvas.drawPath(shape, fill(SweepGradient(colors: [for (final hue in hues) _alpha(hue, 0.35)]), rect));
    }
    // The bevel: lit from above, shaded below.
    canvas
      ..save()
      ..clipPath(shape);
    canvas.drawPath(
      shape,
      stroke(
        LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_alpha(_white, 0.95), _alpha(_white, 0.1), const Color(0x4D000000)]),
        rect,
        size * 0.09,
      ),
    );
    canvas.restore();
    // The plate the sign sits in, sunk below the rim.
    final center = rect.center;
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..scale(0.74)
      ..translate(-center.dx, -center.dy);
    canvas.drawPath(shape, fill(LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [metal.dark, metal.mid]), rect));
    canvas.drawPath(
      shape,
      stroke(
        // Black at 35 % to clear to white at 55 %, without passing through grey.
        const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x59000000), _clearBlack, _clearWhite, Color(0x8CFFFFFF)],
          stops: [0, 0.5, 0.5, 1],
        ),
        rect,
        size * 0.035,
      ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MedalPainter old) =>
      old.family != family ||
      old.earned != earned ||
      old.line != line ||
      old.sunken != sunken ||
      old.metal.light != metal.light ||
      old.metal.mid != metal.mid ||
      old.metal.dark != metal.dark;
}

/// The light that sweeps across an earned badge: it waits, then crosses in 1.1 s, ease in-out, tilted 22°.
class _SweepPainter extends CustomPainter {
  _SweepPainter(this.clock) : super(repaint: clock);
  final Animation<double> clock;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final size = math.min(canvasSize.width, canvasSize.height);
    final total = (StudyMedal.wait + StudyMedal.sweep).inMicroseconds;
    final elapsed = clock.value * total;
    final wait = StudyMedal.wait.inMicroseconds;
    final moved = elapsed <= wait ? 0.0 : Curves.easeInOut.transform(((elapsed - wait) / StudyMedal.sweep.inMicroseconds).clamp(0.0, 1.0));
    final x = -size * 0.9 + size * 1.8 * moved;
    final band = Rect.fromCenter(center: Offset.zero, width: size * 0.34, height: canvasSize.height);
    canvas
      ..save()
      ..translate(canvasSize.width / 2 + x, canvasSize.height / 2)
      ..rotate(22 * math.pi / 180);
    canvas.drawRect(band, Paint()..shader = const LinearGradient(colors: [_clearWhite, Color(0xBFFFFFFF), _clearWhite]).createShader(band));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.clock != clock;
}

/// A ring round a badge not yet earned: the track, and the part done from the top, clockwise, with round ends.
class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({required this.progress, required this.width, required this.track, required this.fill});
  final double progress;
  final double width;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final circle = Rect.fromCircle(center: size.center(Offset.zero), radius: math.min(size.width, size.height) / 2);
    canvas.drawOval(
      circle,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
    final done = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    if (done <= 0) return;
    canvas.drawArc(
      circle,
      -math.pi / 2,
      done * 2 * math.pi,
      false,
      Paint()
        ..color = fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ProgressRingPainter old) => old.progress != progress || old.width != width || old.track != track || old.fill != fill;
}

/// Text that shrinks, down to [minimumScale] of its size, before it is cut off (`.minimumScaleFactor`).
class StudyFitText extends StatelessWidget {
  /// [text] in [style] on at most [maxLines] lines.
  const StudyFitText(this.text, {super.key, required this.style, this.maxLines = 1, this.minimumScale = 1, this.textAlign = TextAlign.center});

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minimumScale;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var fitted = style;
        final base = style.fontSize ?? 14;
        if (constraints.hasBoundedWidth && minimumScale < 1) {
          for (var scale = 1.0; scale >= minimumScale - 1e-9; scale -= 0.05) {
            fitted = style.copyWith(fontSize: base * math.max(scale, minimumScale));
            final painter = TextPainter(
              text: TextSpan(text: text, style: fitted),
              maxLines: maxLines,
              textDirection: direction,
              textScaler: scaler,
            )..layout(maxWidth: constraints.maxWidth);
            final fits = !painter.didExceedMaxLines;
            painter.dispose();
            if (fits) break;
          }
        }
        return Text(text, style: fitted, maxLines: maxLines, overflow: TextOverflow.ellipsis, textAlign: textAlign);
      },
    );
  }
}

const _tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

/// An SF Symbol and a title in the same style (`Label`).
Widget _label(String symbol, String title, TextStyle style, Color color, {double? iconSize}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    StudyIcon(symbol, size: iconSize ?? (style.fontSize ?? 17), color: color),
    SizedBox(width: (style.fontSize ?? 17) * 0.35),
    Flexible(
      child: Text(title, style: style.copyWith(color: color)),
    ),
  ],
);

// MARK: - On the Me tab

/// The latest badges and how many there are, leading to all of them (`StudyAwardsCard`).
class StudyAwardsCard extends StatelessWidget {
  /// A card for [model]'s badges; a tap calls [open].
  const StudyAwardsCard({super.key, required this.model, required this.open});

  final StudyModeModel model;
  final VoidCallback open;

  /// The four badges the card shows: the newest earned, or with none yet, the nearest to being earned.
  static List<StudyAward> shown(StudyModeModel model) {
    final all = model.awards;
    final earned = all.where((award) => model.earned[award.id] != null).toList();
    if (earned.isEmpty) {
      final sorted = [...all];
      mergeSort(sorted, compare: (a, b) => model.facts.progress(b).compareTo(model.facts.progress(a)));
      return sorted.take(4).toList();
    }
    mergeSort(earned, compare: (a, b) => model.earned[b.id]!.earned.compareTo(model.earned[a.id]!.earned));
    return earned.take(4).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final theme = StudyTheme.of(context);
        final all = model.awards;
        final count = all.where((award) => model.earned[award.id] != null).length;
        return StudyPressButton(
          key: const Key('study.awards'),
          outlined: true,
          radius: 22,
          onPressed: () {
            StudySound.tap.play();
            open();
          },
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _label('trophy.fill', L10n.text('Achievements'), StudyTheme.title(20), theme.ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$count / ${all.length}', style: StudyTheme.body(15, StudyTheme.heavy).copyWith(color: theme.gold).merge(_tabular)),
                    const SizedBox(width: 8),
                    StudyIcon('chevron.right', size: 13, color: theme.muted),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final award in shown(model))
                      Expanded(
                        child: Center(
                          child: StudyMedal(award: award, earned: model.earned[award.id] != null, progress: model.facts.progress(award), size: 62),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                StudyBar(value: all.isEmpty ? 0 : count / all.length, color: theme.gold, height: 10),
              ],
            ),
          ),
        );
      },
    );
  }
}

// MARK: - The gallery

/// Every badge by family, with how far along each one is (`StudyAwardsGallery`). A full page that pops itself.
class StudyAwardsGallery extends StatelessWidget {
  /// The gallery of [model]'s badges.
  const StudyAwardsGallery({super.key, required this.model});

  final StudyModeModel model;

  void _open(BuildContext context, StudyAward award) {
    StudySound.pick.play();
    final all = model.awards;
    showAppSheet<void>(
      context,
      medium: true,
      // A sheet with a medium and a large detent shows its grabber on iOS.
      grabber: true,
      builder: (context, controller) => ColoredBox(
        color: StudyTheme.of(context).background,
        child: StudyAwardDetail(
          award: award,
          record: model.earned[award.id],
          facts: model.facts,
          family: all.where((other) => other.family == award.family).toList(),
          earned: model.earned,
          controller: controller,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final media = MediaQuery.of(context);
    return ColoredBox(
      color: theme.background,
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final all = model.awards;
          final count = all.where((award) => model.earned[award.id] != null).length;
          return Column(
            children: [
              ColoredBox(
                color: theme.background,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, media.padding.top + 8, 16, 8),
                  child: Row(
                    children: [
                      Semantics(
                        button: true,
                        label: L10n.text('Close'),
                        excludeSemantics: true,
                        child: GestureDetector(
                          key: const Key('study.awards.close'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: ShapeDecoration(
                              color: theme.surface,
                              shape: CircleBorder(side: BorderSide(color: theme.line, width: 2)),
                            ),
                            alignment: Alignment.center,
                            child: StudyIcon('xmark', size: 17, color: theme.muted),
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(16, 18, 16, 18 + media.padding.bottom),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _header(theme, count, all.length),
                            for (final family in StudyAwardFamily.values)
                              if (all.where((award) => award.family == family).toList() case final awards when awards.isNotEmpty) ...[
                                const SizedBox(height: 26),
                                _family(context, theme, family, awards),
                              ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(StudyTheme theme, int count, int total) => Row(
    children: [
      Padding(
        padding: const EdgeInsets.all(6),
        child: Semantics(
          key: const Key('study.awards.count'),
          container: true,
          excludeSemantics: true,
          label: '${L10n.text('Achievements')} $count / $total',
          child: SizedBox.square(
            dimension: 112,
            child: CustomPaint(
              painter: _CountRingPainter(value: total == 0 ? 0 : count / total, track: theme.sunken, colors: [theme.gold, theme.flame]),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$count', style: StudyTheme.title(34).copyWith(color: theme.ink).merge(_tabular)),
                    Text('/ $total', style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: theme.muted).merge(_tabular)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 18),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.text('Achievements'), style: StudyTheme.title(28).copyWith(color: theme.ink)),
            const SizedBox(height: 6),
            Text(
              L10n.text('Every badge is something you really did. Tap one to see how it is earned.'),
              style: StudyTheme.body(14, StudyTheme.medium).copyWith(color: theme.muted),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _family(BuildContext context, StudyTheme theme, StudyAwardFamily family, List<StudyAward> awards) {
    final count = awards.where((award) => model.earned[award.id] != null).length;
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24));
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: ShapeDecoration(color: theme.surface, shape: shape),
      foregroundDecoration: ShapeDecoration(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: theme.line, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(family.title, style: StudyTheme.title(19).copyWith(color: theme.ink)),
              ),
              const SizedBox(width: 8),
              Text('$count / ${awards.length}', style: StudyTheme.body(13, StudyTheme.heavy).copyWith(color: theme.muted).merge(_tabular)),
            ],
          ),
          const SizedBox(height: 14),
          _AdaptiveGrid(minimum: 96, spacing: 10, runSpacing: 18, children: [for (final award in awards) _cell(context, theme, award)]),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, StudyTheme theme, StudyAward award) {
    final earned = model.earned[award.id] != null;
    return GestureDetector(
      key: Key('study.award.${award.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context, award),
      child: Semantics(
        button: true,
        child: Column(
          children: [
            SizedBox(
              height: 96,
              child: Center(
                child: StudyMedal(award: award, earned: earned, progress: model.facts.progress(award), size: 78),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: StudyFitText(
                award.name,
                style: StudyTheme.body(12, StudyTheme.heavy).copyWith(color: earned ? theme.ink : theme.muted),
                maxLines: 2,
                minimumScale: 0.8,
              ),
            ),
            if (!earned) ...[
              const SizedBox(height: 8),
              Text(
                '${math.min(model.facts.value(award), award.goal)} / ${award.goal}',
                style: StudyTheme.body(11, StudyTheme.heavy).copyWith(color: theme.primary).merge(_tabular),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `LazyVGrid` with `.adaptive(minimum:)` columns: as many as fit, sharing the width, each row's items at the top.
class _AdaptiveGrid extends StatelessWidget {
  const _AdaptiveGrid({required this.minimum, required this.spacing, required this.runSpacing, required this.children});
  final double minimum;
  final double spacing;
  final double runSpacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = math.max(1, ((constraints.maxWidth + spacing) / (minimum + spacing)).floor());
        final rows = <Widget>[];
        for (var start = 0; start < children.length; start += columns) {
          if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing));
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) SizedBox(width: spacing),
                  Expanded(child: start + column < children.length ? children[start + column] : const SizedBox()),
                ],
              ],
            ),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      },
    );
  }
}

/// The gallery's ring: a sunken track and the share earned, gold into flame, from the top.
class _CountRingPainter extends CustomPainter {
  const _CountRingPainter({required this.value, required this.track, required this.colors});
  final double value;
  final Color track;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final circle = Rect.fromCircle(center: rect.center, radius: math.min(size.width, size.height) / 2);
    canvas.drawOval(
      circle,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12,
    );
    final done = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    if (done <= 0) return;
    // As SwiftUI does: the stroke and its top-to-bottom gradient are both turned a quarter back.
    canvas
      ..save()
      ..translate(rect.center.dx, rect.center.dy)
      ..rotate(-math.pi / 2)
      ..translate(-rect.center.dx, -rect.center.dy);
    canvas.drawArc(
      circle,
      0,
      done * 2 * math.pi,
      false,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors).createShader(rect)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CountRingPainter old) => old.value != value || old.track != track || old.colors != colors;
}

/// A pan that wins at once, so that tilting the badge does not drag the sheet it sits in.
class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}

String _earnedDate(DateTime date) {
  final day = date.toLocal();
  return switch (L10n.language) {
    'ko' => '${day.year}년 ${day.month}월 ${day.day}일',
    'ja' => '${day.year}年${day.month}月${day.day}日',
    _ => '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][day.month - 1]} ${day.day}, ${day.year}',
  };
}

/// One badge up close (`StudyAwardDetail`). It tilts under a finger, as a medal turned over in the hand would.
class StudyAwardDetail extends StatefulWidget {
  /// [award], earned when [record] is set, among the rest of its [family].
  const StudyAwardDetail({
    super.key,
    required this.award,
    required this.record,
    required this.facts,
    required this.family,
    required this.earned,
    this.controller,
  });

  final StudyAward award;
  final StudyAwardRecord? record;
  final StudyFacts facts;
  final List<StudyAward> family;
  final Map<String, StudyAwardRecord> earned;

  /// The sheet's scroll controller.
  final ScrollController? controller;

  @override
  State<StudyAwardDetail> createState() => _StudyAwardDetailState();
}

class _StudyAwardDetailState extends State<StudyAwardDetail> with SingleTickerProviderStateMixin {
  static final _back = StudySpring(0.7, 0.6);
  late final AnimationController _spring = AnimationController(vsync: this, duration: _back.settle)..addListener(_springing);
  Offset _tilt = Offset.zero;
  Offset _from = Offset.zero;

  /// How far the finger has gone since it touched down.
  Offset _start = Offset.zero;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _springing() => setState(() => _tilt = _from * (1 - _back.transform(_spring.value)));

  void _drag(Offset translation) {
    _spring.stop();
    setState(() => _tilt = Offset(translation.dx.clamp(-120.0, 120.0), translation.dy.clamp(-120.0, 120.0)));
  }

  void _release() {
    _from = _tilt;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _tilt = Offset.zero);
    } else {
      _spring.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final award = widget.award;
    final record = widget.record;
    const size = 168.0;
    final frame = record != null ? size : size * 1.18;
    // SwiftUI's `rotation3DEffect` projects as Core Animation does, with the nearer side larger for positive z; in
    // Flutter's matrices positive z is farther, so the perspective entry is negative to turn the same way.
    Matrix4 turn({double y = 0, double x = 0}) => Matrix4.identity()
      ..setEntry(3, 2, -0.6 / frame)
      ..rotateY(y)
      ..rotateX(x);
    final medal = RawGestureDetector(
      gestures: {
        _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
          _EagerPan.new,
          (pan) => pan
            ..onStart = ((_) => _start = Offset.zero)
            ..onUpdate = ((details) => _drag(_start += details.delta))
            ..onEnd = ((_) => _release())
            ..onCancel = _release,
        ),
      },
      child: Transform(
        alignment: Alignment.center,
        transform: turn(x: -_tilt.dy / 4 * math.pi / 180),
        child: Transform(
          alignment: Alignment.center,
          transform: turn(y: _tilt.dx / 4 * math.pi / 180),
          child: StudyMedal(award: award, earned: record != null, progress: widget.facts.progress(award), size: size),
        ),
      ),
    );
    final top = Padding(
      padding: const EdgeInsets.only(top: 30, bottom: 6),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          StudyPop(shown: _shown, from: 0.3, child: medal),
          if (record != null)
            Positioned.fill(
              child: StudyBurst(trigger: _shown ? 1 : 0, count: 20, reach: 120, colors: [theme.gold, _white, theme.primary]),
            ),
        ],
      ),
    );
    final family = widget.family.length > 1 && award.family != StudyAwardFamily.sections;
    return LayoutBuilder(
      builder: (context, box) {
        // On iOS the sheet grows to its large detent when its content is taller than the medium one. This sheet
        // keeps its medium height, so the big medal gives way first, down to about half its size, and every row
        // below it, the family's other badges included, stays in sight. Only when even that is not enough (very
        // large text) does the sheet scroll.
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final rest = (160 + (family ? 30 + 46 * 1.18 + 12 : 0)) * scale;
        final fits = box.hasBoundedHeight && box.maxHeight - 24 - rest >= 100;
        return SingleChildScrollView(
          controller: widget.controller,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: SizedBox(
            width: double.infinity,
            height: fits ? box.maxHeight - 24 : null,
            child: _detailColumn(
              context,
              theme,
              fits
                  ? Flexible(
                      child: FittedBox(fit: BoxFit.scaleDown, child: top),
                    )
                  : top,
              family,
            ),
          ),
        );
      },
    );
  }

  Widget _detailColumn(BuildContext context, StudyTheme theme, Widget top, bool family) {
    final award = widget.award;
    final record = widget.record;
    return Column(
      children: [
        top,
        const SizedBox(height: 16),
        Text(
          award.name,
          key: const Key('study.award.name'),
          textAlign: TextAlign.center,
          style: StudyTheme.title(26).copyWith(color: theme.ink),
        ),
        const SizedBox(height: 16),
        Text(
          award.explanation,
          textAlign: TextAlign.center,
          style: StudyTheme.body(16, StudyTheme.medium).copyWith(color: theme.muted),
        ),
        const SizedBox(height: 16),
        if (record != null)
          _label('checkmark.seal.fill', L10n.text('Earned on %@', [_earnedDate(record.earned)]), StudyTheme.body(14, StudyTheme.heavy), theme.good)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              // The bar runs the width of the sheet, as SwiftUI's does.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StudyBar(value: widget.facts.progress(award), color: theme.primary, height: 14),
                const SizedBox(height: 6),
                Text(
                  '${math.min(widget.facts.value(award), award.goal)} / ${award.goal}',
                  textAlign: TextAlign.center,
                  style: StudyTheme.body(14, StudyTheme.heavy).copyWith(color: theme.primary).merge(_tabular),
                ),
              ],
            ),
          ),
        if (family) ...[
          const SizedBox(height: 16 + 14),
          // The rest of the family, so that the next rung is in sight.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, other) in widget.family.indexed) ...[
                  if (index > 0) const SizedBox(width: 14),
                  Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.bottomCenter,
                    children: [
                      Opacity(
                        opacity: other.id == award.id ? 1 : 0.75,
                        child: StudyMedal(
                          award: other,
                          earned: widget.earned[other.id] != null,
                          progress: widget.facts.progress(other),
                          size: 46,
                          shines: false,
                        ),
                      ),
                      if (other.id == award.id)
                        Positioned(
                          bottom: -12,
                          child: Container(
                            width: 18,
                            height: 4,
                            decoration: ShapeDecoration(color: theme.primary, shape: const StadiumBorder()),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Room for the mark below the current badge.
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

// MARK: - The moment it is earned

/// Lays [children] out with [gap] between them, centred in the height there is and scrolling when it is too little.
Widget _centered({required double gap, required double edge, required List<Widget> children}) => LayoutBuilder(
  builder: (context, constraints) {
    // Centred in the safe area, below the status bar, as SwiftUI lays out a stack between spacers.
    final column = Padding(
      padding: EdgeInsets.only(top: edge + MediaQuery.paddingOf(context).top, bottom: edge),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final (index, child) in children.indexed) ...[if (index > 0) SizedBox(height: gap), child],
        ],
      ),
    );
    if (!constraints.hasBoundedHeight) return column;
    return SingleChildScrollView(
      clipBehavior: Clip.none,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: column,
      ),
    );
  },
);

/// A full page for a badge just earned (`StudyAwardCelebration`): it spins in, lands, and the light catches it.
class StudyAwardCelebration extends StatefulWidget {
  /// The celebration of [award].
  const StudyAwardCelebration({super.key, required this.award});

  final StudyAward award;

  @override
  State<StudyAwardCelebration> createState() => _StudyAwardCelebrationState();
}

class _StudyAwardCelebrationState extends State<StudyAwardCelebration> with TickerProviderStateMixin {
  static final _land = StudySpring(1.0, 0.35);
  static final _open = StudySpring(0.7, 0.3);
  static const _openDelay = Duration(milliseconds: 250);

  late final AnimationController _medal = AnimationController(vsync: this, duration: _land.settle);
  late final AnimationController _rays = AnimationController(vsync: this, duration: _openDelay + _open.settle);
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(seconds: 28));
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _shown = true);
      final reduce = MediaQuery.disableAnimationsOf(context);
      if (reduce) {
        _medal.value = 1;
        _rays.value = 1;
      } else {
        _medal.forward();
        _rays.forward();
        _turn.repeat();
      }
      StudySound.levelup.play();
      HapticFeedback.mediumImpact();
    });
  }

  @override
  void dispose() {
    _medal.dispose();
    _rays.dispose();
    _turn.dispose();
    super.dispose();
  }

  double _raysOpen() {
    final total = _rays.duration!.inMicroseconds;
    final elapsed = _rays.value * total;
    final wait = _openDelay.inMicroseconds;
    if (_rays.value >= 1) return 1;
    if (elapsed <= wait) return 0;
    return _open.transform(((elapsed - wait) / (total - wait)).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final award = widget.award;
    final metal = StudyMetal.of(award);
    final reduce = MediaQuery.disableAnimationsOf(context);
    const medalSize = 190.0;

    final stage = SizedBox(
      width: 240,
      height: 250,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([_rays, _turn]),
            builder: (context, _) {
              final open = _shown ? _raysOpen() : 0.0;
              return Opacity(
                opacity: open.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.1 + 0.9 * open,
                  child: Transform.rotate(
                    angle: reduce ? 0 : _turn.value * 2 * math.pi,
                    child: CustomPaint(size: const Size(240, 250), painter: _RaysPainter(_alpha(metal.mid, 0.28))),
                  ),
                ),
              );
            },
          ),
          AnimatedBuilder(
            animation: _medal,
            builder: (context, child) {
              final t = _shown ? _land.transform(_medal.value) : 0.0;
              final spin = reduce ? 0.0 : 900 * (1 - t) * math.pi / 180;
              return Transform.translate(
                offset: Offset(0, -260 * (1 - t)),
                child: Transform.scale(
                  scale: 0.15 + 0.85 * t,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, -0.5 / medalSize)
                      ..rotateY(spin),
                    child: child,
                  ),
                ),
              );
            },
            child: StudyMedal(award: award, size: medalSize),
          ),
          Positioned.fill(
            child: StudyBurst(trigger: _shown ? 1 : 0, count: 30, reach: 170, colors: [metal.mid, metal.light, theme.gold, _white]),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _centered(
                gap: 20,
                edge: 20,
                children: [
                  StudyPop(
                    shown: _shown,
                    delay: 0.5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(colors: [theme.gold, theme.flame]),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        L10n.text('Achievement Unlocked!'),
                        textAlign: TextAlign.center,
                        style: StudyTheme.body(16, StudyTheme.heavy).copyWith(color: _white),
                      ),
                    ),
                  ),
                  stage,
                  StudyRise(
                    shown: _shown,
                    delay: 0.7,
                    child: Text(
                      award.name,
                      key: const Key('study.milestone'),
                      textAlign: TextAlign.center,
                      style: StudyTheme.title(32).copyWith(color: theme.ink),
                    ),
                  ),
                  StudyRise(
                    shown: _shown,
                    delay: 0.8,
                    child: Text(
                      award.explanation,
                      textAlign: TextAlign.center,
                      style: StudyTheme.body(17, StudyTheme.medium).copyWith(color: theme.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!reduce) const Positioned.fill(child: StudyConfetti(pieces: 120)),
      ],
    );
  }
}

/// Fourteen rounded rays, 12 wide and 190 long, from the middle outwards.
class _RaysPainter extends CustomPainter {
  const _RaysPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final ray = RRect.fromRectAndRadius(const Rect.fromLTWH(-6, -190, 12, 190), const Radius.circular(6));
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2);
    for (var index = 0; index < 14; index++) {
      canvas
        ..save()
        ..rotate(index * 2 * math.pi / 14)
        ..drawRRect(ray, paint)
        ..restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RaysPainter old) => old.color != color;
}

/// Badges earned away from a lesson, such as by generating a picture, celebrated one after another on return
/// (`StudyAwardParade`). The last Continue calls [done].
class StudyAwardParade extends StatefulWidget {
  /// A parade of [awards].
  const StudyAwardParade({super.key, required this.awards, required this.done});

  final List<StudyAward> awards;
  final VoidCallback done;

  @override
  State<StudyAwardParade> createState() => _StudyAwardParadeState();
}

class _StudyAwardParadeState extends State<StudyAwardParade> {
  static final _slide = StudySpring(0.45, 0.2);
  int _page = 0;

  void _continue() {
    StudySound.tap.play();
    if (_page + 1 < widget.awards.length) {
      setState(() => _page += 1);
    } else {
      widget.done();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = StudyTheme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final current = ValueKey(_page);
    return ColoredBox(
      color: theme.background,
      child: Column(
        children: [
          Expanded(
            child: SafeArea(
              bottom: false,
              child: AnimatedSwitcher(
                duration: reduce ? Duration.zero : _slide.settle,
                switchInCurve: _slide,
                switchOutCurve: _slide,
                layoutBuilder: (currentChild, previous) => Stack(fit: StackFit.expand, children: [...previous, ?currentChild]),
                // In from the trailing edge, out to the leading edge, fading as they go.
                transitionBuilder: (child, animation) {
                  final incoming = child.key == current;
                  return FadeTransition(
                    opacity: animation.drive(Tween<double>(begin: 0, end: 1).chain(CurveTween(curve: const _Clamp()))),
                    child: SlideTransition(
                      position: animation.drive(Tween(begin: Offset(incoming ? 1 : -1, 0), end: Offset.zero)),
                      child: child,
                    ),
                  );
                },
                child: widget.awards.isEmpty || _page >= widget.awards.length
                    ? const SizedBox.expand()
                    : KeyedSubtree(
                        key: current,
                        child: StudyAwardCelebration(award: widget.awards[_page]),
                      ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560 + 36),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: StudyMainButton(key: const Key('study.done'), title: L10n.text('Continue'), onPressed: _continue),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps a spring's overshoot out of an opacity.
class _Clamp extends Curve {
  const _Clamp();
  @override
  double transformInternal(double t) => t.clamp(0.0, 1.0);
}
