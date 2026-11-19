import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

// Drawings of the SF Symbols that learning mode uses and that the `CupertinoIcons` font has no close glyph for, so
// that `StudyIcon` shows the same symbol as iOS rather than a stand-in. Each one is drawn by hand to look like the
// bold SF Symbol: the same size, weight and position inside the box as `Image(systemName:)` at the same point size.
//
// Units: a drawing is laid out on a 256 × 256 grid whose middle 128 × 128 square (64…192 both ways) is the icon's
// box, so that a symbol that is wider or taller than its point size (as many SF Symbols are) can reach past the box,
// as it does on iOS.

/// The drawing of [name] in a [size] × [size] box, in [color]; null when [name] has no drawing here.
Widget? studySymbol(String name, {required double size, required Color color}) {
  final draw = _symbols[name];
  if (draw == null) return null;
  return SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _StudySymbolPainter(name, draw, color)),
  );
}

/// Whether [name] has a drawing here.
bool studySymbolDrawn(String name) => _symbols.containsKey(name);

/// The names that have a drawing, in the order they were added.
Iterable<String> get studySymbolNames => _symbols.keys;

/// Paints [name] into the [size] × [size] box at the canvas origin. Does nothing for a name with no drawing.
void paintStudySymbol(Canvas canvas, String name, double size, Color color) {
  final draw = _symbols[name];
  if (draw == null || size <= 0) return;
  // One layer, so that overlapping parts of a see-through colour do not darken where they meet and cut-outs can
  // erase what is under them.
  canvas.saveLayer(Rect.fromLTWH(-size, -size, size * 3, size * 3), Paint()..color = Color.fromARGB((color.a * 255).round(), 0, 0, 0));
  canvas.scale(size / 128);
  canvas.translate(-64, -64);
  draw(_Pen(canvas, color.withValues(alpha: 1)));
  canvas.restore();
}

class _StudySymbolPainter extends CustomPainter {
  const _StudySymbolPainter(this.name, this.draw, this.color);

  final String name;
  final void Function(_Pen) draw;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    paintStudySymbol(canvas, name, size.shortestSide, color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StudySymbolPainter oldDelegate) => oldDelegate.name != name || oldDelegate.color != color;
}

/// What a drawing paints with: solid shapes in the icon colour, and the same shapes erased to cut holes.
class _Pen {
  _Pen(this.canvas, Color color)
    : _ink = Paint()
        ..color = color
        ..isAntiAlias = true,
      _rub = Paint()
        ..blendMode = BlendMode.clear
        ..isAntiAlias = true;

  final Canvas canvas;
  final Paint _ink;
  final Paint _rub;

  Paint _paint(bool erase, [double? width]) {
    final base = erase ? _rub : _ink;
    if (width == null) return base..style = PaintingStyle.fill;
    return base
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
  }

  void fill(Path path, {bool erase = false}) => canvas.drawPath(path, _paint(erase));

  /// [path] drawn as a line [width] wide with round ends and corners.
  void stroke(Path path, double width, {bool erase = false, StrokeCap cap = StrokeCap.round}) => canvas.drawPath(path, _paint(erase, width)..strokeCap = cap);

  /// A line through [xy] (x, y pairs).
  void line(List<double> xy, double width, {bool erase = false, bool close = false, StrokeCap cap = StrokeCap.round}) => stroke(
    poly(xy, close: close),
    width,
    erase: erase,
    cap: cap,
  );

  void circle(double x, double y, double r, {bool erase = false}) => canvas.drawCircle(Offset(x, y), r, _paint(erase));

  /// A circle outline whose stroke centre is at radius [r].
  void ring(double x, double y, double r, double width, {bool erase = false}) => canvas.drawCircle(Offset(x, y), r, _paint(erase, width));

  void box(double l, double t, double r, double b, double radius, {bool erase = false}) =>
      canvas.drawRRect(RRect.fromLTRBR(l, t, r, b, Radius.circular(radius)), _paint(erase));

  /// A rounded rectangle outline whose stroke centre runs along (l, t, r, b).
  void frame(double l, double t, double r, double b, double radius, double width, {bool erase = false}) =>
      canvas.drawRRect(RRect.fromLTRBR(l, t, r, b, Radius.circular(radius)), _paint(erase, width));

  /// A pill (capsule) from (x1, y1) to (x2, y2), [width] across.
  void pill(double x1, double y1, double x2, double y2, double width, {bool erase = false}) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), _paint(erase, width));

  void oval(double l, double t, double r, double b, {bool erase = false}) => canvas.drawOval(Rect.fromLTRB(l, t, r, b), _paint(erase));

  /// An arc of the circle at (x, y) radius [r], from [start] sweeping [sweep] degrees (0 = right, clockwise).
  void arc(double x, double y, double r, double start, double sweep, double width, {bool erase = false, StrokeCap cap = StrokeCap.round}) => canvas.drawArc(
    Rect.fromCircle(center: Offset(x, y), radius: r),
    start * math.pi / 180,
    sweep * math.pi / 180,
    false,
    _paint(erase, width)..strokeCap = cap,
  );

  /// A four-pointed sparkle centred at (x, y), [r] from centre to tip, with concave sides.
  void sparkle(double x, double y, double r, {bool erase = false, double pinch = 0.2}) {
    final k = r * pinch;
    final path = Path()
      ..moveTo(x, y - r)
      ..quadraticBezierTo(x + k, y - k, x + r, y)
      ..quadraticBezierTo(x + k, y + k, x, y + r)
      ..quadraticBezierTo(x - k, y + k, x - r, y)
      ..quadraticBezierTo(x - k, y - k, x, y - r)
      ..close();
    fill(path, erase: erase);
  }
}

/// A path through [xy] (x, y pairs).
Path poly(List<double> xy, {bool close = true}) {
  final path = Path()..moveTo(xy[0], xy[1]);
  for (var i = 2; i + 1 < xy.length; i += 2) {
    path.lineTo(xy[i], xy[i + 1]);
  }
  if (close) path.close();
  return path;
}

/// A polygon through [xy] with every corner rounded by up to [radius].
Path roundPoly(List<double> xy, double radius) {
  final points = [for (var i = 0; i + 1 < xy.length; i += 2) Offset(xy[i], xy[i + 1])];
  final n = points.length;
  final path = Path();
  for (var i = 0; i < n; i++) {
    final prev = points[(i - 1 + n) % n];
    final p = points[i];
    final next = points[(i + 1) % n];
    final a = p - prev;
    final b = next - p;
    final r = math.min(radius, math.min(a.distance, b.distance) / 2);
    final start = p - a / a.distance * r;
    final end = p + b / b.distance * r;
    if (i == 0) {
      path.moveTo(start.dx, start.dy);
    } else {
      path.lineTo(start.dx, start.dy);
    }
    path.quadraticBezierTo(p.dx, p.dy, end.dx, end.dy);
  }
  return path..close();
}

/// A smooth closed curve through [xy] (x, y pairs), as a Catmull-Rom spline.
Path smooth(List<double> xy, {double tension = 1}) {
  final points = [for (var i = 0; i + 1 < xy.length; i += 2) Offset(xy[i], xy[i + 1])];
  final n = points.length;
  final path = Path()..moveTo(points[0].dx, points[0].dy);
  for (var i = 0; i < n; i++) {
    final p0 = points[(i - 1 + n) % n];
    final p1 = points[i];
    final p2 = points[(i + 1) % n];
    final p3 = points[(i + 2) % n];
    final c1 = p1 + (p2 - p0) * (tension / 6);
    final c2 = p2 - (p3 - p1) * (tension / 6);
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path..close();
}

/// [path] scaled by [k] about ([x], [y]).
Path _scaled(Path path, double k, double x, double y) => path.transform(
  (Matrix4.identity()
        ..translateByDouble(x, y, 0, 1)
        ..scaleByDouble(k, k, 1, 1)
        ..translateByDouble(-x, -y, 0, 1))
      .storage,
);

const List<double> _palette = [
  136,
  61,
  176,
  68,
  200,
  86,
  207,
  106,
  196,
  126,
  178,
  140,
  176,
  156,
  180,
  170,
  168,
  186,
  132,
  193,
  90,
  186,
  60,
  166,
  49,
  140,
  50,
  110,
  64,
  82,
  96,
  64,
];

final Map<String, void Function(_Pen)> _symbols = {
  // The heavy marks that the font draws too thin: the lesson's close button, the finished stop's tick, the locked
  // stop, row chevrons, the start button's triangle and the stars, measured from the heavy SF Symbols.
  'xmark': (p) {
    p.line([88, 88, 167, 167], 25, close: false);
    p.line([167, 88, 88, 167], 25, close: false);
  },
  'checkmark': (p) => p.line([80, 130, 110, 172, 175, 83], 24),
  'chevron.right': (p) => p.line([112, 81, 159, 127.5, 112, 174], 24),
  'chevron.left': (p) => p.line([143, 81, 96, 127.5, 143, 174], 24),
  'lock.fill': (p) {
    p.stroke(
      Path()
        ..moveTo(101, 118)
        ..lineTo(101, 98)
        ..arcToPoint(const Offset(153, 98), radius: const Radius.circular(26))
        ..lineTo(153, 118),
      18,
      cap: StrokeCap.butt,
    );
    p.box(81, 112, 173, 192, 13);
  },
  'play.fill': (p) => p.fill(roundPoly([77, 60, 197, 127.5, 77, 195], 20)),
  'star.fill': (p) {
    const cx = 127.5, cy = 134.5, outer = 84.0, inner = 40.0;
    p.fill(
      roundPoly([
        for (var i = 0; i < 10; i++) ...[
          cx + (i.isEven ? outer : inner) * math.sin(i * math.pi / 5),
          cy - (i.isEven ? outer : inner) * math.cos(i * math.pi / 5),
        ],
      ], 14),
    );
  },
  'dumbbell.fill': (p) {
    p.box(38, 92, 61, 165, 11);
    p.box(196, 92, 218, 165, 11);
    p.box(68, 76, 101, 179, 15);
    p.box(155, 76, 188, 179, 15);
    p.box(107, 111, 149, 143, 0);
  },
  'books.vertical.fill': (p) {
    p.box(45, 76, 78, 197, 7);
    p.box(85, 100, 130, 197, 7);
    p.pill(101, 119, 115, 119, 7, erase: true);
    p.pill(101, 175, 115, 175, 7, erase: true);
    p.box(137, 56, 173, 197, 9);
    // The fourth book leans on the third, with a gap between them.
    p.canvas.save();
    p.canvas.translate(191, 137);
    p.canvas.rotate(-7 * math.pi / 180);
    p.box(-19, -65, 19, 65, 10, erase: true);
    p.box(-15, -61, 15, 61, 7);
    p.canvas.restore();
  },
  'key.fill': (p) {
    p.circle(128, 91, 42);
    p.fill(roundPoly([112, 116, 145, 116, 145, 130, 157, 141, 157, 152, 145, 162, 145, 168, 153, 175, 153, 187, 128, 207, 112, 191], 4));
    p.circle(128, 72, 9.5, erase: true);
  },
  'key': (p) {
    p.circle(128, 92, 43);
    p.fill(roundPoly([108, 116, 148, 116, 148, 132, 161, 144, 161, 153, 149, 163, 149, 168, 157, 176, 157, 186, 128, 209, 108, 191], 5));
    p.circle(128, 92, 31, erase: true);
    p.fill(roundPoly([120, 110, 136, 110, 136, 136, 148, 147, 148, 150, 137, 160, 137, 172, 144, 178, 144, 183, 128, 196, 120, 188], 2), erase: true);
    p.circle(128, 79, 9);
    // Close the top of the slot where it meets the ring.
    p.box(120, 118, 136, 124, 0, erase: true);
  },
  'trophy.fill': (p) {
    p.fill(
      Path()
        ..moveTo(98, 57)
        ..lineTo(158, 57)
        ..quadraticBezierTo(168, 57, 168, 67)
        ..lineTo(168, 98)
        ..cubicTo(168, 120, 152, 134, 142, 136)
        ..lineTo(114, 136)
        ..cubicTo(104, 134, 88, 120, 88, 98)
        ..lineTo(88, 67)
        ..quadraticBezierTo(88, 57, 98, 57)
        ..close(),
    );
    p.box(114, 128, 142, 168, 0);
    p.fill(roundPoly([106, 164, 150, 164, 166, 172, 166, 198, 90, 198, 90, 172], 6));
    p.line([92, 74, 70, 74, 70, 92], 12);
    p.stroke(
      Path()
        ..moveTo(70, 92)
        ..quadraticBezierTo(70, 108, 96, 116),
      12,
    );
    p.line([164, 74, 186, 74, 186, 92], 12);
    p.stroke(
      Path()
        ..moveTo(186, 92)
        ..quadraticBezierTo(186, 108, 160, 116),
      12,
    );
  },
  'crown.fill': (p) {
    p.fill(roundPoly([60, 104, 102, 126, 128, 78, 154, 126, 196, 104, 188, 154, 68, 154], 5));
    p.circle(60, 104, 17);
    p.circle(196, 104, 17);
    p.circle(128, 77, 16);
    p.fill(roundPoly([72, 168, 184, 168, 178, 192, 78, 192], 6));
  },
  'brain.head.profile': (p) {
    // The head, facing left, as one thick outline.
    p.stroke(
      Path()
        ..moveTo(172, 197)
        ..lineTo(120, 197)
        ..quadraticBezierTo(112, 197, 112, 189)
        ..lineTo(112, 185)
        ..quadraticBezierTo(112, 177, 104, 177)
        ..lineTo(92, 177)
        ..quadraticBezierTo(84, 177, 84, 169)
        ..lineTo(84, 155)
        ..lineTo(76, 150)
        ..quadraticBezierTo(72, 147, 74, 142)
        ..lineTo(77, 130)
        ..cubicTo(78, 88, 100, 58, 132, 58)
        ..cubicTo(164, 58, 187, 84, 187, 114)
        ..cubicTo(187, 132, 178, 144, 172, 152)
        ..lineTo(172, 197),
      13,
    );
    // The brain: a lumpy outline with two folds and a stem.
    const lumps = [
      [115.0, 91.0, 15.0],
      [139.0, 87.0, 15.0],
      [154.0, 105.0, 13.0],
      [114.0, 112.0, 12.0],
      [137.0, 115.0, 12.0],
    ];
    for (final l in lumps) {
      p.circle(l[0], l[1], l[2] + 2.75);
    }
    for (final l in lumps) {
      p.circle(l[0], l[1], l[2] - 2.75, erase: true);
    }
    p.box(116, 92, 150, 112, 0, erase: true);
    p.stroke(
      Path()
        ..moveTo(127, 77)
        ..cubicTo(114, 86, 120, 98, 128, 100)
        ..cubicTo(136, 102, 132, 112, 124, 114),
      5.5,
    );
    p.stroke(
      Path()
        ..moveTo(146, 95)
        ..cubicTo(148, 104, 156, 108, 146, 118),
      5.5,
    );
    p.line([153, 121, 158, 133], 6);
  },
  'graduationcap.fill': (p) {
    // The cap under the board, with a gap along the board's lower edges.
    p.fill(
      Path()
        ..moveTo(80, 112)
        ..lineTo(188, 112)
        ..lineTo(188, 150)
        ..cubicTo(176, 168, 152, 175, 128, 175)
        ..cubicTo(106, 175, 90, 166, 80, 154)
        ..close(),
    );
    final board = roundPoly([128, 45, 224, 90, 128, 138, 32, 90], 20);
    p.stroke(board, 12, erase: true);
    p.fill(board);
    // The tassel's cord from the button to the left corner and down, outlined by a gap.
    final cord = Path()
      ..moveTo(128, 93)
      ..lineTo(72, 112)
      ..quadraticBezierTo(68, 113, 68, 118)
      ..lineTo(68, 172);
    p.stroke(cord, 14, erase: true);
    p.stroke(cord, 5);
    p.circle(128, 93, 12, erase: true);
    p.oval(117, 85, 139, 101);
    p.box(63, 170, 87, 203, 7);
  },
  'figure.walk': (p) {
    p.circle(128, 65, 14);
    p.line([119, 150, 86, 193], 13);
    final front = poly([122, 136, 133, 160, 149, 194], close: false);
    p.stroke(front, 23, erase: true);
    p.stroke(front, 13);
    p.line([89, 136, 91, 118, 109, 101], 12);
    p.fill(roundPoly([106, 88, 130, 92, 136, 104, 132, 142, 112, 142, 102, 118, 100, 96], 8));
    final arm = poly([134, 101, 146, 117, 166, 118], close: false);
    p.stroke(arm, 21, erase: true);
    p.stroke(arm, 12);
    p.fill(roundPoly([106, 88, 130, 92, 133, 100, 126, 104, 108, 104, 100, 96], 8));
  },
  'figure.run': (p) {
    p.circle(142, 69, 13.5);
    final back = poly([111, 142, 101, 164, 78, 193], close: false);
    p.stroke(back, 13);
    final front = poly([126, 136, 155, 152, 131, 172], close: false);
    p.stroke(front, 22, erase: true);
    p.stroke(front, 13);
    p.line([92, 124, 93, 96, 112, 93], 12);
    p.fill(roundPoly([108, 88, 132, 92, 138, 106, 136, 138, 114, 138, 110, 112, 104, 96], 8));
    final arm = poly([136, 102, 150, 117, 175, 110], close: false);
    p.stroke(arm, 21, erase: true);
    p.stroke(arm, 12);
    p.fill(roundPoly([108, 88, 130, 90, 136, 100, 128, 106, 110, 106, 104, 96], 8));
  },
  'figure.stand': (p) {
    p.circle(128, 67, 13.5);
    p.box(96, 89, 160, 128, 17);
    p.pill(102, 112, 102, 140, 12);
    p.pill(154, 112, 154, 140, 12);
    p.box(112, 100, 144, 156, 0);
    p.line([109.5, 114, 109.5, 152], 3.5, erase: true, cap: StrokeCap.butt);
    p.line([146.5, 114, 146.5, 152], 3.5, erase: true, cap: StrokeCap.butt);
    p.pill(119.5, 150, 119.5, 193, 15);
    p.pill(136.5, 150, 136.5, 193, 15);
    p.line([128, 150, 128, 202], 3.5, erase: true, cap: StrokeCap.butt);
  },
  'photo.stack.fill': (p) {
    p.box(92, 49, 164, 60, 5);
    p.box(76, 67, 180, 77, 5);
    p.box(60, 88, 196, 196, 17);
    p.circle(103, 127, 12, erase: true);
    p.fill(roundPoly([76, 178, 76, 163, 101, 148, 117, 162, 152, 136, 178, 160, 178, 178], 4), erase: true);
    p.box(76, 168, 178, 180, 6, erase: true);
  },
  'photo.stack': (p) {
    p.box(92, 49, 164, 60, 5);
    p.box(76, 67, 180, 77, 5);
    p.frame(66, 94, 190, 190, 12, 12);
    p.circle(110, 128, 12);
    p.fill(roundPoly([70, 166, 102, 150, 116, 160, 152, 138, 186, 164, 186, 186, 70, 186], 4));
  },
  'paintpalette.fill': (p) {
    p.fill(smooth(_palette));
    p.circle(104, 98, 11, erase: true);
    p.circle(78, 124, 9, erase: true);
    p.circle(140, 90, 9, erase: true);
    p.circle(171, 99, 8, erase: true);
    p.circle(134, 149, 17, erase: true);
  },
  'paintpalette': (p) {
    p.stroke(_scaled(smooth(_palette), 0.925, 128, 127), 12);
    p.circle(106, 102, 10);
    p.circle(86, 124, 9);
    p.circle(138, 96, 9);
    p.circle(165, 102, 8);
    p.ring(127, 145, 12, 9);
  },
  'tshirt.fill': (p) {
    p.fill(roundPoly([100, 56, 128, 63, 156, 56, 197, 70, 211, 84, 209, 118, 181, 122, 181, 198, 75, 198, 75, 122, 47, 118, 45, 84, 59, 70], 8));
    p.box(75, 160, 181, 198, 15);
    p.fill(
      Path()
        ..moveTo(106, 73)
        ..quadraticBezierTo(128, 80, 150, 73)
        ..quadraticBezierTo(128, 100, 106, 73)
        ..close(),
      erase: true,
    );
  },
  'shoe.fill': (p) {
    final sole = Path()
      ..moveTo(34, 167)
      ..lineTo(168, 167)
      ..quadraticBezierTo(212, 165, 224, 138);
    p.stroke(sole, 11);
    final upper = Path()
      ..moveTo(34, 100)
      ..lineTo(88, 104)
      ..quadraticBezierTo(98, 82, 112, 82)
      ..lineTo(118, 82)
      ..lineTo(160, 108)
      ..lineTo(198, 108)
      ..cubicTo(222, 108, 232, 122, 222, 134)
      ..cubicTo(212, 146, 198, 150, 180, 150)
      ..lineTo(36, 150)
      ..quadraticBezierTo(28, 150, 28, 142)
      ..lineTo(28, 106)
      ..quadraticBezierTo(28, 100, 34, 100)
      ..close();
    p.stroke(upper, 9, erase: true);
    p.fill(upper);
    for (final x in [116.0, 131.0, 146.0]) {
      p.line([x, x == 116 ? 108 : 108 + (x - 116) / 2, x + 14, 82], 6, erase: true);
    }
  },
  'cpu': (p) {
    for (final c in [106.0, 128.0, 150.0]) {
      p.pill(c, 69, c, 187, 11);
      p.pill(69, c, 187, c, 11);
    }
    p.box(76, 76, 180, 180, 6);
    p.box(91, 91, 165, 165, 2, erase: true);
    p.frame(106, 106, 150, 150, 2, 12);
  },
  'memorychip': (p) {
    for (final c in [86.0, 107.0, 128.0, 149.0, 170.0]) {
      p.pill(c, 77, c, 179, 11);
    }
    p.box(60, 84, 196, 170, 20);
    p.box(76, 100, 180, 154, 7, erase: true);
  },
  'door.left.hand.open': (p) {
    p.stroke(
      Path()
        ..moveTo(84, 188)
        ..lineTo(84, 80)
        ..quadraticBezierTo(84, 68, 96, 68)
        ..lineTo(164, 68)
        ..quadraticBezierTo(176, 68, 176, 80)
        ..lineTo(176, 188),
      16,
    );
    p.fill(roundPoly([100, 82, 124, 93, 124, 182, 100, 194], 3));
  },
  'signpost.right': (p) {
    p.pill(122, 66, 122, 182, 12);
    p.box(94, 179, 152, 197, 5);
    final sign = roundPoly([71, 87, 162, 87, 187, 111, 162, 135, 71, 135], 8);
    p.fill(sign, erase: true);
    p.stroke(sign, 14);
  },
  'scalemass': (p) {
    p.circle(127, 77, 19);
    p.circle(127, 77, 6, erase: true);
    p.fill(roundPoly([86, 100, 170, 100, 193, 198, 63, 198], 13));
    p.fill(roundPoly([98, 116, 158, 116, 175, 184, 81, 184], 4), erase: true);
  },
  'stairs': (p) {
    p.line([72, 182, 72, 154, 100, 154, 100, 126, 128, 126, 128, 98, 156, 98, 156, 70, 183, 70], 15);
  },
  'terminal': (p) {
    p.frame(60, 76, 194, 180, 18, 15);
    p.line([84, 99, 103, 111, 84, 123], 9);
    p.line([113, 126, 141, 126], 7.5);
  },
  'megaphone': (p) {
    p.stroke(
      Path()
        ..moveTo(66, 98)
        ..quadraticBezierTo(126, 98, 172, 68)
        ..lineTo(172, 172)
        ..quadraticBezierTo(126, 142, 66, 142)
        ..quadraticBezierTo(60, 142, 60, 136)
        ..lineTo(60, 104)
        ..quadraticBezierTo(60, 98, 66, 98)
        ..close(),
      12,
    );
    p.pill(100, 100, 100, 140, 14);
    p.fill(roundPoly([78, 146, 112, 146, 120, 192, 92, 194], 8));
    p.fill(roundPoly([92, 154, 104, 154, 108, 178, 99, 178], 3), erase: true);
    p.box(172, 58, 202, 182, 13, erase: true);
    p.frame(178, 66, 194, 174, 8, 12);
  },
  'puzzlepiece.extension': (p) {
    p.box(52, 64, 172, 190, 18);
    p.circle(188, 126, 20);
    p.box(64, 76, 160, 178, 7, erase: true);
    p.circle(78, 126, 26);
    p.circle(78, 126, 13, erase: true);
    p.box(40, 120, 78, 132, 0, erase: true);
    p.circle(188, 126, 8, erase: true);
    p.box(150, 121, 188, 131, 0, erase: true);
  },
  'dice': (p) {
    p.frame(64, 68, 156, 148, 14, 16);
    p.box(84, 82, 200, 198, 22, erase: true);
    p.frame(96, 94, 188, 186, 14, 16);
    for (final c in [
      [121.0, 118.0],
      [167.0, 118.0],
      [144.0, 142.0],
      [121.0, 166.0],
      [167.0, 166.0],
    ]) {
      p.circle(c[0], c[1], 8);
    }
  },
  'hands.clap': (p) {
    // Drawn below.
    _handsClap(p);
  },
  'building.columns': (p) {
    p.stroke(roundPoly([128, 63, 190, 97, 66, 97], 5), 12);
    p.box(60, 91, 196, 104, 4);
    for (final x in [78.0, 110.0, 146.0, 178.0]) {
      p.box(x - 6, 112, x + 6, 176, 0);
      p.fill(roundPoly([x - 14, 107, x + 14, 107, x + 9, 119, x - 9, 119], 2));
      p.box(x - 14, 171, x + 14, 180, 2);
    }
    p.box(52, 187, 203, 200, 5);
  },
  'leaf': (p) {
    p.stroke(
      Path()
        ..moveTo(66, 76)
        ..cubicTo(110, 84, 156, 80, 172, 104)
        ..cubicTo(186, 126, 180, 158, 154, 162)
        ..cubicTo(124, 168, 92, 160, 78, 140)
        ..cubicTo(64, 120, 64, 96, 66, 76)
        ..close(),
      13,
    );
    p.stroke(
      Path()
        ..moveTo(100, 112)
        ..quadraticBezierTo(116, 132, 162, 136)
        ..lineTo(174, 140),
      9,
    );
    p.line([174, 140, 187, 183], 12);
  },
  'leaf.fill': (p) {
    p.fill(
      Path()
        ..moveTo(58, 69)
        ..lineTo(78, 79)
        ..cubicTo(140, 76, 186, 88, 186, 122)
        ..cubicTo(186, 152, 172, 174, 140, 175)
        ..cubicTo(100, 176, 72, 160, 64, 136)
        ..cubicTo(56, 116, 57, 96, 58, 69)
        ..close(),
    );
    p.fill(
      Path()
        ..moveTo(94, 104)
        ..quadraticBezierTo(120, 126, 176, 127)
        ..lineTo(176, 139)
        ..quadraticBezierTo(124, 136, 94, 104)
        ..close(),
      erase: true,
    );
    final stem = Path()
      ..moveTo(170, 133)
      ..quadraticBezierTo(184, 152, 188, 184);
    p.stroke(stem, 20, erase: true);
    p.stroke(stem, 12);
  },
  'ruler.fill': (p) {
    p.box(48, 91, 208, 165, 13);
    p.line([66, 100, 66, 132], 4.5, erase: true);
    for (var x = 80.0; x <= 188; x += 12) {
      final long = x == 128 || x == 188;
      p.line([x, 96, x, long ? 131 : 120], 6.5, erase: true);
    }
    p.box(60, 90, 196, 103, 0);
  },
  'person.badge.key': (p) {
    p.ring(120, 82, 20, 12);
    p.stroke(
      Path()
        ..moveTo(150, 166)
        ..lineTo(72, 166)
        ..cubicTo(74, 148, 92, 130, 118, 129)
        ..lineTo(150, 129),
      12,
    );
    final key = Path()
      ..addOval(Rect.fromCircle(center: const Offset(177, 125), radius: 19))
      ..addPath(roundPoly([168, 136, 186, 136, 186, 148, 191, 154, 191, 161, 186, 165, 186, 178, 177, 188, 168, 180], 3), Offset.zero);
    p.stroke(key, 14, erase: true);
    p.fill(key, erase: true);
    p.fill(key);
    p.circle(177, 119, 6, erase: true);
  },
  'calendar.badge.clock': (p) {
    p.box(52, 58, 185, 173, 19);
    p.box(68, 92, 169, 157, 2, erase: true);
    for (final d in [
      [108.0, 106.0],
      [128.0, 106.0],
      [148.0, 106.0],
      [88.0, 126.0],
      [108.0, 126.0],
      [128.0, 126.0],
      [88.0, 146.0],
      [108.0, 146.0],
      [128.0, 146.0],
    ]) {
      p.box(d[0] - 4.5, d[1] - 6, d[0] + 4.5, d[1] + 6, 2.5);
    }
    p.circle(176, 154, 38, erase: true);
    p.circle(176, 154, 31.5);
    p.line([176, 134, 176, 154, 160, 154], 7, erase: true, cap: StrokeCap.round);
  },
  'camera.aperture': (p) {
    p.ring(128, 128, 57.5, 16);
    // Six straight blades, each touching the round opening in the middle and running out to the ring.
    for (var k = 0; k < 6; k++) {
      final a = (60 * k - 120) * math.pi / 180;
      final touch = Offset(128 + 25 * math.cos(a), 128 + 25 * math.sin(a));
      final u = Offset(-math.sin(a), math.cos(a));
      final w = touch - const Offset(128, 128);
      final b = w.dx * u.dx + w.dy * u.dy;
      final t = -b + math.sqrt(b * b - (w.distanceSquared - 56 * 56));
      final start = touch - u * 15;
      final end = touch + u * t;
      p.line([start.dx, start.dy, end.dx, end.dy], 12, cap: StrokeCap.butt);
    }
  },
  'character.book.closed': (p) {
    p.box(72, 60, 184, 196, 14);
    p.box(88, 76, 168, 148, 3, erase: true);
    p.box(88, 160, 160, 184, 2, erase: true);
    p.fill(roundPoly([172, 158, 190, 158, 190, 183, 160, 183], 3), erase: true);
    p.fill(roundPoly([160, 158, 176, 158, 172, 184, 156, 184], 2));
    p.line([100, 76, 100, 148], 8, cap: StrokeCap.butt);
    p.line([119, 134, 135, 90, 151, 134], 9, cap: StrokeCap.butt);
    p.line([124, 119, 146, 119], 8, cap: StrokeCap.butt);
  },
  'face.dashed': (p) {
    for (var k = 0; k < 8; k++) {
      p.arc(128, 128, 59, 45.0 * k - 14, 28, 13, cap: StrokeCap.butt);
    }
    p.pill(110, 109, 110, 115, 11);
    p.pill(146, 109, 146, 115, 11);
    p.arc(128, 124, 27, 40, 100, 8);
  },
  'sparkles.tv': (p) {
    p.frame(54, 69, 200, 162, 12, 16);
    p.box(92, 180, 172, 196, 8);
    p.sparkle(132, 111, 28, pinch: 0.12);
    p.sparkle(105, 134, 13, pinch: 0.12);
  },
  'iphone.and.arrow.forward': (p) {
    p.frame(92, 64, 168, 191, 14, 16);
    p.box(76, 105, 108, 148, 0, erase: true);
    p.line([66, 126, 138, 126], 12);
    p.line([118, 105, 140, 126, 118, 147], 12);
  },
  'point.3.connected.trianglepath.dotted': (p) => _triangleDots(p, filled: false),
  'point.3.filled.connected.trianglepath.dotted': (p) => _triangleDots(p, filled: true),
  'person.crop.rectangle.badge.plus': (p) {
    p.frame(68, 64, 202, 168, 14, 16);
    p.circle(136, 104, 18);
    p.fill(
      Path()
        ..moveTo(112, 168)
        ..cubicTo(112, 150, 126, 140, 144, 140)
        ..cubicTo(162, 140, 178, 150, 178, 168)
        ..close(),
    );
    p.circle(70, 154, 40, erase: true);
    p.circle(70, 154, 32);
    p.line([53, 154, 87, 154], 9, erase: true);
    p.line([70, 137, 70, 171], 9, erase: true);
  },
  'photo.badge.magnifyingglass': (p) {
    p.frame(57, 64, 188, 166, 12, 16);
    p.circle(100, 100, 14);
    p.fill(roundPoly([64, 172, 64, 142, 92, 127, 110, 140, 150, 108, 186, 140, 186, 172], 6));
    p.circle(176, 146, 36, erase: true);
    p.line([186, 166, 210, 188], 26, erase: true);
    p.ring(176, 146, 20, 12);
    p.line([191, 167, 207, 184], 13);
  },
  'bolt.horizontal.fill': (p) {
    final bolt = poly([47, 158, 104, 94, 156, 120, 210, 95, 157, 162, 102, 134]);
    p.fill(bolt);
    p.stroke(bolt, 16);
  },
  'wand.and.stars': (p) {
    p.pill(126, 130, 177, 181, 21);
    p.stroke(
      (Path()..addRRect(RRect.fromLTRBR(-21, -10.5, 21, 10.5, const Radius.circular(10.5)))).transform(
        (Matrix4.identity()
              ..translateByDouble(107, 111, 0, 1)
              ..rotateZ(math.pi / 4))
            .storage,
      ),
      6,
    );
    p.sparkle(157, 88, 26, pinch: 0.12);
    p.sparkle(78, 148, 17, pinch: 0.12);
    p.sparkle(98, 174, 11, pinch: 0.12);
  },
  'map.fill': (p) {
    p.fill(roundPoly([60, 86, 100, 67, 100, 172, 60, 188], 7));
    p.fill(roundPoly([112, 67, 144, 84, 144, 189, 112, 172], 4));
    p.fill(roundPoly([156, 84, 195, 67, 195, 168, 156, 189], 7));
  },
  'tray.and.arrow.down.fill': (p) {
    p.fill(
      Path()
        ..moveTo(52, 140)
        ..lineTo(112, 140)
        ..cubicTo(114, 156, 122, 162, 128, 162)
        ..cubicTo(134, 162, 142, 156, 144, 140)
        ..lineTo(203, 140)
        ..lineTo(203, 180)
        ..quadraticBezierTo(203, 202, 181, 202)
        ..lineTo(74, 202)
        ..quadraticBezierTo(52, 202, 52, 180)
        ..close(),
    );
    p.line([58, 140, 86, 98, 104, 98], 14);
    p.line([152, 98, 170, 98, 198, 140], 14);
    p.line([128, 59, 128, 128], 15);
    p.line([108, 112, 128, 132, 148, 112], 14);
  },
};

/// One hand of `hands.clap`, fingers up and thumb to the right, around its palm's centre.
Path _hand() {
  var hand = Path()..addRRect(RRect.fromLTRBAndCorners(-40, -24, 40, 44, bottomLeft: const Radius.circular(40), bottomRight: const Radius.circular(40)));
  for (final f in [
    [-30.0, -54.0],
    [-10.0, -72.0],
    [10.0, -80.0],
    [30.0, -72.0],
  ]) {
    hand = Path.combine(PathOperation.union, hand, Path()..addRRect(RRect.fromLTRBR(f[0] - 10, f[1], f[0] + 10, 0, const Radius.circular(10))));
  }
  final thumb = Path()..addRRect(RRect.fromLTRBR(-10, -46, 10, 0, const Radius.circular(10)));
  return Path.combine(
    PathOperation.union,
    hand,
    thumb.transform(
      (Matrix4.identity()
            ..translateByDouble(36, 26, 0, 1)
            ..rotateZ(0.35))
          .storage,
    ),
  );
}

void _handsClap(_Pen p) {
  final hand = _hand();
  void place(double x, double y, double turn, void Function() draw) {
    p.canvas.save();
    p.canvas.translate(x, y);
    p.canvas.rotate(turn * math.pi / 180);
    p.canvas.scale(1.03);
    draw();
    p.canvas.restore();
  }

  place(164, 161, -34, () => p.stroke(hand, 12));
  place(136, 157, -42, () {
    p.fill(hand, erase: true);
    p.stroke(hand, 22, erase: true);
    p.stroke(hand, 12);
    for (final x in [-20.0, 0.0, 20.0]) {
      p.line([x, x == -20 ? -50 : -64, x, -6], 9);
    }
  });
  p.line([41, 90, 58, 94], 11);
  p.line([53, 62, 66, 75], 11);
  p.line([83, 48, 87, 63], 11);
}

void _triangleDots(_Pen p, {required bool filled}) {
  for (final c in [
    [78.0, 90.0],
    [178.0, 90.0],
    [128.0, 162.0],
  ]) {
    if (filled) {
      p.circle(c[0], c[1], 21);
    } else {
      p.ring(c[0], c[1], 16, 11);
    }
  }
  for (final d in [
    [110.0, 90.0],
    [122.0, 90.0],
    [134.0, 90.0],
    [146.0, 90.0],
    [97.0, 120.0],
    [108.0, 134.0],
    [159.0, 120.0],
    [148.0, 134.0],
  ]) {
    p.circle(d[0], d[1], 4.5);
  }
}
