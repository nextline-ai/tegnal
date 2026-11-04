import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../design/tegnal_theme.dart';

import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_recap.dart';

/// `RecapType`: the magazine's display serif and its monospaced folio. Android's
/// serif stands in for the system serif the native app uses.
abstract final class RecapType {
  /// The system serif has no Korean or Japanese; like iOS, those fall back to the app's sans.
  static TextStyle display(double size, {FontWeight weight = FontWeight.w900, Color? color, bool italic = false, double? letterSpacing}) => TextStyle(
    fontFamily: 'serif',
    fontFamilyFallback: const [TegnalType.family, ...TegnalType.fallback],
    fontSize: size,
    fontWeight: weight,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    color: color,
    letterSpacing: letterSpacing,
    height: 1.12,
  );

  /// Italic serif text whose Korean and Japanese stay upright, as iOS sets them.
  static TextSpan italicSpan(String text, TextStyle style) {
    final cjk = RegExp(r'[\u1100-\u11FF\u3000-\u30FF\u3130-\u318F\u4E00-\u9FFF\uAC00-\uD7AF\uFF00-\uFFEF]+');
    final spans = <TextSpan>[];
    var index = 0;
    for (final match in cjk.allMatches(text)) {
      if (match.start > index) spans.add(TextSpan(text: text.substring(index, match.start)));
      spans.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(fontStyle: FontStyle.normal, fontFamily: TegnalType.family),
        ),
      );
      index = match.end;
    }
    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));
    return TextSpan(style: style, children: spans);
  }

  static TextStyle folio(double size, {Color? color, double? letterSpacing}) =>
      TextStyle(fontFamily: 'monospace', fontSize: size, fontWeight: FontWeight.w600, color: color, letterSpacing: letterSpacing, height: 1.2);
}

extension RecapColorStyle on RecapColor {
  Color get color => Color(argb);
}

extension RecapPaletteStyle on RecapPalette {
  Color get inkColor => Color(ink.argb);
  Color get deepColor => Color(deep.argb);
  Color get accentColor => Color(accent.argb);
  Color get paperColor => Color(paper.argb);
  Color get paperInkColor => Color(paperInk.argb);
}

extension RecapCoverSeed on TasteRecap {
  /// Months count up, so consecutive issues step through every scene in turn.
  int get coverSeed {
    final date = interval.start.toUtc().add(const Duration(hours: 12));
    return date.year * 12 + date.month;
  }
}

/// The seeded random numbers native recaps draw with: a 64-bit linear congruential
/// generator whose high bits pick values in thousandths.
class RecapRandom {
  RecapRandom(int seed, {int offset = 12345}) : _state = seed * 2654435761 + offset;
  int _state;

  double next() {
    _state = _state * 6364136223846793005 + 1442695040888963407;
    return ((_state >>> 33) % 1000) / 1000;
  }
}

/// `RecapPressStyle`: a light press-in for cover and tile buttons.
class RecapPressable extends StatefulWidget {
  const RecapPressable({super.key, required this.child, this.onTap, this.label});
  final Widget child;
  final VoidCallback? onTap;
  final String? label;

  @override
  State<RecapPressable> createState() => _RecapPressableState();
}

class _RecapPressableState extends State<RecapPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(scale: _pressed ? 0.975 : 1, duration: const Duration(milliseconds: 220), curve: Curves.easeOutBack, child: widget.child),
    ),
  );
}

/// `RecapColorField`: blurred discs of the issue's colors over its ink, standing in
/// for artwork in private mode, share cards and sample issues.
class RecapColorField extends StatelessWidget {
  const RecapColorField({super.key, required this.palette, this.seed = 7});
  final RecapPalette palette;
  final int seed;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _ColorFieldPainter(palette, seed), size: Size.infinite),
  );
}

class _ColorFieldPainter extends CustomPainter {
  _ColorFieldPainter(this.palette, this.seed);
  final RecapPalette palette;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.inkColor);
    final random = RecapRandom(seed, offset: 97);
    final blur = math.min(size.width, size.height) * 0.13;
    for (var index = 0; index < 7; index++) {
      final color = palette.swatches[index % palette.swatches.length].color;
      final radius = math.max(size.width, size.height) * (0.24 + random.next() * 0.3);
      final center = Offset(size.width * random.next(), size.height * random.next());
      final opacity = 0.62 + random.next() * 0.38;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(_ColorFieldPainter old) => old.palette != palette || old.seed != seed;
}
