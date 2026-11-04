import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import 'tegnal_theme.dart';

/// The native app's `glassCapsule`, `glassCircle` and `glassSurface`: a blurred,
/// translucent surface with a hairline edge, drawn above scrolling content.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.shape, required this.child, this.blur = 6, this.elevated = false});

  const Glass.capsule({super.key, required this.child, this.blur = 6, this.elevated = false}) : shape = const StadiumBorder();
  const Glass.circle({super.key, required this.child, this.blur = 6, this.elevated = false}) : shape = const CircleBorder();
  Glass.surface({super.key, required this.child, double cornerRadius = 16, this.blur = 6, this.elevated = false})
    : shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(cornerRadius)));

  final ShapeBorder shape;
  final Widget child;
  final double blur;

  /// Controls in a sheet sit on a lighter surface and read lighter, as they do on iOS.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final fill = (elevated ? TegnalColors.elevatedGlassFill : TegnalColors.glassFill).resolveFrom(context);
    final stroke = TegnalColors.glassStroke.resolveFrom(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: dark ? const [] : const [BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        // Side-by-side surfaces under one [BackdropGroup] blur a single shared copy of the
        // screen behind them, rather than each reading it again.
        child: BackdropFilter.grouped(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: ShapeDecoration(color: fill, shape: shape),
            position: DecorationPosition.background,
            child: CustomPaint(
              foregroundPainter: _GlassEdge(shape: shape, stroke: stroke, dark: dark),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A hairline rim, brighter along the top edge like light catching glass.
class _GlassEdge extends CustomPainter {
  _GlassEdge({required this.shape, required this.stroke, required this.dark});
  final ShapeBorder shape;
  final Color stroke;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getInnerPath(rect.deflate(0.25));
    final highlight = dark ? const Color(0x24FFFFFF) : const Color(0x66FFFFFF);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.75
      ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [highlight, stroke, stroke], [0, 0.45, 1]);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GlassEdge old) => old.stroke != stroke || old.dark != dark || old.shape != shape;
}
