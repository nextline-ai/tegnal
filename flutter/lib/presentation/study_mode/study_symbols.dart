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
  canvas.saveLayer(
    Rect.fromLTWH(-size, -size, size * 3, size * 3),
    Paint()..color = Color.fromARGB((color.a * 255).round(), 0, 0, 0),
  );
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
  void stroke(Path path, double width, {bool erase = false, StrokeCap cap = StrokeCap.round}) =>
      canvas.drawPath(path, _paint(erase, width)..strokeCap = cap);

  /// A line through [xy] (x, y pairs).
  void line(List<double> xy, double width, {bool erase = false, bool close = false, StrokeCap cap = StrokeCap.round}) =>
      stroke(poly(xy, close: close), width, erase: erase, cap: cap);

  void circle(double x, double y, double r, {bool erase = false}) =>
      canvas.drawCircle(Offset(x, y), r, _paint(erase));

  /// A circle outline whose stroke centre is at radius [r].
  void ring(double x, double y, double r, double width, {bool erase = false}) =>
      canvas.drawCircle(Offset(x, y), r, _paint(erase, width));

  void box(double l, double t, double r, double b, double radius, {bool erase = false}) =>
      canvas.drawRRect(RRect.fromLTRBR(l, t, r, b, Radius.circular(radius)), _paint(erase));

  /// A rounded rectangle outline whose stroke centre runs along (l, t, r, b).
  void frame(double l, double t, double r, double b, double radius, double width, {bool erase = false}) =>
      canvas.drawRRect(RRect.fromLTRBR(l, t, r, b, Radius.circular(radius)), _paint(erase, width));

  /// A pill (capsule) from (x1, y1) to (x2, y2), [width] across.
  void pill(double x1, double y1, double x2, double y2, double width, {bool erase = false}) =>
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), _paint(erase, width));

  void oval(double l, double t, double r, double b, {bool erase = false}) =>
      canvas.drawOval(Rect.fromLTRB(l, t, r, b), _paint(erase));

  /// An arc of the circle at (x, y) radius [r], from [start] sweeping [sweep] degrees (0 = right, clockwise).
  void arc(double x, double y, double r, double start, double sweep, double width, {bool erase = false, StrokeCap cap = StrokeCap.round}) =>
      canvas.drawArc(
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

final Map<String, void Function(_Pen)> _symbols = {
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
    p.fill(
      roundPoly([112, 116, 145, 116, 145, 130, 157, 141, 157, 152, 145, 162, 145, 168, 153, 175, 153, 187, 128, 207, 112, 191], 4),
    );
    p.circle(128, 72, 9.5, erase: true);
  },
  'key': (p) {
    p.circle(128, 92, 43);
    p.fill(
      roundPoly([108, 116, 148, 116, 148, 132, 161, 144, 161, 153, 149, 163, 149, 168, 157, 176, 157, 186, 128, 209, 108, 191], 5),
    );
    p.circle(128, 92, 31, erase: true);
    p.fill(
      roundPoly([120, 110, 136, 110, 136, 136, 148, 147, 148, 150, 137, 160, 137, 172, 144, 178, 144, 183, 128, 196, 120, 188], 2),
      erase: true,
    );
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
    p.stroke(Path()..moveTo(70, 92)..quadraticBezierTo(70, 108, 96, 116), 12);
    p.line([164, 74, 186, 74, 186, 92], 12);
    p.stroke(Path()..moveTo(186, 92)..quadraticBezierTo(186, 108, 160, 116), 12);
  },
  'crown.fill': (p) {
    p.fill(roundPoly([60, 104, 102, 126, 128, 78, 154, 126, 196, 104, 188, 154, 68, 154], 5));
    p.circle(60, 104, 17);
    p.circle(196, 104, 17);
    p.circle(128, 77, 16);
    p.fill(roundPoly([72, 168, 184, 168, 178, 192, 78, 192], 6));
  },
};
