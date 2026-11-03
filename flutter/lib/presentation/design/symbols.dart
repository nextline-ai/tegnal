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
