import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

/// SF Symbols the native app uses, mapped to their Cupertino icon equivalents.
abstract final class Symbols {
  static const folderFill = CupertinoIcons.folder_fill;
  static const folder = CupertinoIcons.folder;
  static const globe = CupertinoIcons.globe;
  static const tagFill = CupertinoIcons.tag_fill;
  static const gearshapeFill = CupertinoIcons.gear_alt_fill;
  static const ellipsis = CupertinoIcons.ellipsis;
  static const bookFill = CupertinoIcons.book_fill;
  static const book = CupertinoIcons.book;
  static const photoFill = CupertinoIcons.photo_fill;
  static const photo = CupertinoIcons.photo;
  static const magnifyingglass = CupertinoIcons.search;
  static const xmarkCircleFill = CupertinoIcons.xmark_circle_fill;
  static const squareStack = CupertinoIcons.square_stack;
  static const arrowUpArrowDown = CupertinoIcons.arrow_up_arrow_down;
  static const clock = CupertinoIcons.clock;
  static const star = CupertinoIcons.star;
  static const starFill = CupertinoIcons.star_fill;
  static const trash = CupertinoIcons.trash;
  static const bookmarkFill = CupertinoIcons.bookmark_fill;
  static const checkmark = CupertinoIcons.checkmark_alt;
  static const wifiExclamationmark = CupertinoIcons.wifi_exclamationmark;
}

/// `apple.intelligence`: three looped strokes forming a rosette. Cupertino icons
/// have no equivalent, so it is drawn.
class IntelligenceSymbol extends StatelessWidget {
  const IntelligenceSymbol({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _IntelligencePainter(resolved));
  }
}

class _IntelligencePainter extends CustomPainter {
  _IntelligencePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.085
      ..strokeJoin = StrokeJoin.round;
    final petal = Rect.fromCenter(center: Offset.zero, width: size.width * 0.86, height: size.height * 0.40);
    for (var index = 0; index < 3; index++) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(index * math.pi / 3);
      canvas.drawRRect(RRect.fromRectAndRadius(petal, Radius.circular(petal.height / 2)), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_IntelligencePainter old) => old.color != color;
}

/// `rectangle.portrait.and.arrow.right`: a door-like frame open on the right with an
/// arrow leaving it. Cupertino icons only have the arrow entering, so it is drawn.
class ExitSymbol extends StatelessWidget {
  const ExitSymbol({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _ExitPainter(resolved));
  }
}

class _ExitPainter extends CustomPainter {
  _ExitPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * unit
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final radius = 2.6 * unit;
    final frame = Path()
      ..moveTo(15 * unit, 7.5 * unit)
      ..lineTo(15 * unit, 4.6 * unit)
      ..arcToPoint(Offset(15 * unit - radius, 2 * unit), radius: Radius.circular(radius), clockwise: false)
      ..lineTo(5.6 * unit, 2 * unit)
      ..arcToPoint(Offset(3 * unit, 2 * unit + radius), radius: Radius.circular(radius), clockwise: false)
      ..lineTo(3 * unit, 22 * unit - radius)
      ..arcToPoint(Offset(5.6 * unit, 22 * unit), radius: Radius.circular(radius), clockwise: false)
      ..lineTo(15 * unit - radius, 22 * unit)
      ..arcToPoint(Offset(15 * unit, 22 * unit - radius), radius: Radius.circular(radius), clockwise: false)
      ..lineTo(15 * unit, 16.5 * unit);
    canvas.drawPath(frame, paint);
    canvas.drawLine(Offset(9 * unit, 12 * unit), Offset(22 * unit, 12 * unit), paint);
    canvas.drawPath(
      Path()
        ..moveTo(18.4 * unit, 8.4 * unit)
        ..lineTo(22 * unit, 12 * unit)
        ..lineTo(18.4 * unit, 15.6 * unit),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ExitPainter old) => old.color != color;
}

/// `translate`: two speech balloons, an outlined one with a Latin letter behind a
/// filled one with a CJK character. Cupertino icons have no equivalent, so it is drawn.
class TranslateSymbol extends StatelessWidget {
  const TranslateSymbol({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    final unit = size / 24;
    TextStyle glyph(Color color) => TextStyle(fontSize: 10.5 * unit, height: 1, fontWeight: FontWeight.w700, color: color);
    return SizedBox(
      width: size * 1.15,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: 15 * unit,
            height: 14 * unit,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: resolved, width: 1.6 * unit),
                borderRadius: BorderRadius.circular(3.5 * unit),
              ),
              child: Center(child: Text('A', style: glyph(resolved))),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: 15 * unit,
            height: 14 * unit,
            child: DecoratedBox(
              decoration: BoxDecoration(color: resolved, borderRadius: BorderRadius.circular(3.5 * unit)),
              child: Center(child: Text('文', style: glyph(const Color(0xFF000000)))),
            ),
          ),
        ],
      ),
    );
  }
}

/// `hand.tap.fill`: a raised index finger with a tap ring above its tip. Cupertino
/// icons have no tapping hand, so it is drawn.
class HandTapSymbol extends StatelessWidget {
  const HandTapSymbol({super.key, this.size = 36, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _HandTapPainter(resolved));
  }
}

class _HandTapPainter extends CustomPainter {
  _HandTapPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 30;
    final fill = Paint()..color = color;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * unit
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: Offset(11.5 * unit, 8.5 * unit), radius: 6.5 * unit), math.pi * 0.85, math.pi * 1.3, false, ring);
    RRect rect(double left, double top, double right, double bottom, double radius) =>
        RRect.fromLTRBR(left * unit, top * unit, right * unit, bottom * unit, Radius.circular(radius * unit));
    canvas.drawRRect(rect(9, 6, 14, 22, 2.5), fill);
    canvas.drawRRect(rect(13.4, 12.5, 18, 22, 2.3), fill);
    canvas.drawRRect(rect(17.4, 13.5, 22, 22, 2.3), fill);
    canvas.drawRRect(rect(21.4, 15, 25.5, 23, 2.1), fill);
    canvas.drawRRect(rect(9, 17, 25.5, 29.5, 6), fill);
    // The thumb rests along the palm's left side.
    canvas.save();
    canvas.translate(9 * unit, 21 * unit);
    canvas.rotate(-0.7);
    canvas.drawRRect(RRect.fromLTRBR(-6 * unit, -2 * unit, 1 * unit, 2.4 * unit, Radius.circular(2.2 * unit)), fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HandTapPainter old) => old.color != color;
}

/// `paintpalette`: a painter's palette outline with four paint dots and a thumb hole.
class PaletteSymbol extends StatelessWidget {
  const PaletteSymbol({super.key, this.size = 21, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _PalettePainter(resolved));
  }
}

class _PalettePainter extends CustomPainter {
  _PalettePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * unit
      ..strokeJoin = StrokeJoin.round;
    final outline = Path()
      ..moveTo(12 * unit, 2.5 * unit)
      ..cubicTo(5.8 * unit, 2.5 * unit, 1.5 * unit, 6.6 * unit, 1.5 * unit, 11.8 * unit)
      ..cubicTo(1.5 * unit, 17.4 * unit, 6 * unit, 21.5 * unit, 11.4 * unit, 21.5 * unit)
      ..cubicTo(13.2 * unit, 21.5 * unit, 13.6 * unit, 20.2 * unit, 13 * unit, 18.9 * unit)
      ..cubicTo(12.3 * unit, 17.4 * unit, 13.2 * unit, 15.6 * unit, 15 * unit, 15.6 * unit)
      ..lineTo(17.6 * unit, 15.6 * unit)
      ..cubicTo(20.5 * unit, 15.6 * unit, 22.5 * unit, 13.7 * unit, 22.5 * unit, 11 * unit)
      ..cubicTo(22.5 * unit, 6.2 * unit, 17.8 * unit, 2.5 * unit, 12 * unit, 2.5 * unit)
      ..close();
    canvas.drawPath(outline, stroke);
    final fill = Paint()..color = color;
    for (final dot in const [Offset(6.4, 12.4), Offset(8, 7.6), Offset(12.6, 6), Offset(17, 8)]) {
      canvas.drawCircle(dot * unit, 1.7 * unit, fill);
    }
  }

  @override
  bool shouldRepaint(_PalettePainter old) => old.color != color;
}

/// `externaldrive`: a drive's rounded box, with its status light and a slot along the bottom.
class ExternalDriveSymbol extends StatelessWidget {
  const ExternalDriveSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _ExternalDrivePainter(resolved));
  }
}

class _ExternalDrivePainter extends CustomPainter {
  _ExternalDrivePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * unit
      ..strokeJoin = StrokeJoin.round;
    // The body: a flat top edge tapering in from the sides, over a rounded box.
    final body = Path()
      ..moveTo(4.6 * unit, 6.5 * unit)
      ..lineTo(19.4 * unit, 6.5 * unit)
      ..lineTo(22.2 * unit, 13 * unit)
      ..lineTo(22.2 * unit, 16.5 * unit)
      ..arcToPoint(Offset(20 * unit, 18.7 * unit), radius: Radius.circular(2.2 * unit))
      ..lineTo(4 * unit, 18.7 * unit)
      ..arcToPoint(Offset(1.8 * unit, 16.5 * unit), radius: Radius.circular(2.2 * unit))
      ..lineTo(1.8 * unit, 13 * unit)
      ..close();
    canvas.drawPath(body, stroke);
    canvas.drawLine(Offset(1.8 * unit, 13 * unit), Offset(22.2 * unit, 13 * unit), stroke);
    canvas.drawCircle(Offset(18.2 * unit, 15.9 * unit), 1.1 * unit, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ExternalDrivePainter old) => old.color != color;
}

/// `server.rack`: a rounded box in three bays, each with a light at its right.
class ServerRackSymbol extends StatelessWidget {
  const ServerRackSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _ServerRackPainter(resolved));
  }
}

class _ServerRackPainter extends CustomPainter {
  _ServerRackPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * unit;
    final box = Rect.fromLTRB(0.9 * unit, 2.6 * unit, 23.1 * unit, 21.4 * unit);
    canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(3 * unit)), stroke);
    final bay = box.height / 3;
    for (var index = 1; index < 3; index++) {
      canvas.drawLine(Offset(box.left, box.top + bay * index), Offset(box.right, box.top + bay * index), stroke);
    }
    final light = Paint()..color = color;
    for (var index = 0; index < 3; index++) {
      canvas.drawCircle(Offset(18.6 * unit, box.top + bay * (index + 0.5)), 1.45 * unit, light);
    }
  }

  @override
  bool shouldRepaint(_ServerRackPainter old) => old.color != color;
}

/// `dice`: a die with five pips in front of a second die behind it, up and to the left.
class DiceSymbol extends StatelessWidget {
  const DiceSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _DicePainter(resolved));
  }
}

class _DicePainter extends CustomPainter {
  _DicePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * unit;
    final fill = Paint()..color = color;
    final back = RRect.fromLTRBR(2 * unit, 2 * unit, 15.5 * unit, 15.5 * unit, Radius.circular(3.2 * unit));
    final front = RRect.fromLTRBR(7.5 * unit, 7.5 * unit, 22 * unit, 22 * unit, Radius.circular(3.4 * unit));
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRRect(back, stroke);
    canvas.drawCircle(Offset(5.6 * unit, 5.6 * unit), 1.15 * unit, fill);
    // The front die hides the back one where they overlap.
    canvas.drawRRect(front.inflate(1.6 * unit), Paint()..blendMode = BlendMode.clear);
    canvas.drawRRect(front, stroke);
    for (final (x, y) in [(11.3, 11.3), (18.2, 11.3), (14.75, 14.75), (11.3, 18.2), (18.2, 18.2)]) {
      canvas.drawCircle(Offset(x * unit, y * unit), 1.15 * unit, fill);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DicePainter old) => old.color != color;
}

/// `flag.checkered`: a pole with a checkered flag waving from its top.
class CheckeredFlagSymbol extends StatelessWidget {
  const CheckeredFlagSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _CheckeredFlagPainter(resolved));
  }
}

class _CheckeredFlagPainter extends CustomPainter {
  _CheckeredFlagPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * unit
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const left = 4.0, right = 21.0, top = 3.5, bottom = 14.5;
    canvas.drawLine(Offset(left * unit, top * unit), Offset(left * unit, 22 * unit), stroke);
    final flag = Rect.fromLTRB(left * unit, top * unit, right * unit, bottom * unit);
    final cellWidth = flag.width / 4, cellHeight = flag.height / 3;
    final fill = Paint()..color = color;
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        if ((row + column).isEven) {
          canvas.drawRect(Rect.fromLTWH(flag.left + column * cellWidth, flag.top + row * cellHeight, cellWidth, cellHeight), fill);
        }
      }
    }
    canvas.drawRRect(RRect.fromRectAndRadius(flag, Radius.circular(1.2 * unit)), stroke);
  }

  @override
  bool shouldRepaint(_CheckeredFlagPainter old) => old.color != color;
}

/// `chart.bar.xaxis`: four rising and falling bars standing on a baseline.
class BarChartAxisSymbol extends StatelessWidget {
  const BarChartAxisSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _BarChartAxisPainter(resolved));
  }
}

class _BarChartAxisPainter extends CustomPainter {
  _BarChartAxisPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final fill = Paint()..color = color;
    const bars = [(2.0, 8.0), (7.5, 4.0), (13.0, 6.5), (18.5, 10.5)];
    for (final (left, top) in bars) {
      canvas.drawRRect(RRect.fromLTRBR(left * unit, top * unit, (left + 3.6) * unit, 18.5 * unit, Radius.circular(0.9 * unit)), fill);
    }
    canvas.drawRRect(RRect.fromLTRBR(1 * unit, 20.2 * unit, 23 * unit, 21.8 * unit, Radius.circular(0.8 * unit)), fill);
  }

  @override
  bool shouldRepaint(_BarChartAxisPainter old) => old.color != color;
}

/// `book.pages`: a page of text lines with a second page edge behind it.
class BookPagesSymbol extends StatelessWidget {
  const BookPagesSymbol({super.key, this.size = 22, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? const Color(0xFFFFFFFF);
    return CustomPaint(size: Size.square(size), painter: _BookPagesPainter(resolved));
  }
}

class _BookPagesPainter extends CustomPainter {
  _BookPagesPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * unit
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The page behind shows along the right and bottom edges.
    final back = Path()
      ..moveTo(18.5 * unit, 3.5 * unit)
      ..lineTo(19.5 * unit, 3.5 * unit)
      ..arcToPoint(Offset(21.5 * unit, 5.5 * unit), radius: Radius.circular(2 * unit))
      ..lineTo(21.5 * unit, 20 * unit)
      ..arcToPoint(Offset(19 * unit, 22.5 * unit), radius: Radius.circular(2.5 * unit))
      ..lineTo(7 * unit, 22.5 * unit);
    canvas.drawPath(back, stroke);
    canvas.drawRRect(RRect.fromLTRBR(3 * unit, 1.5 * unit, 18 * unit, 20 * unit, Radius.circular(2.5 * unit)), stroke);
    for (final y in [6.0, 9.5, 13.0, 16.5]) {
      canvas.drawLine(Offset(6.5 * unit, y * unit), Offset((y == 16.5 ? 11.5 : 14.5) * unit, y * unit), stroke);
    }
  }

  @override
  bool shouldRepaint(_BookPagesPainter old) => old.color != color;
}
