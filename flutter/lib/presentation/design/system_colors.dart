import 'package:cupertino_ui/cupertino_ui.dart';

/// iOS 26 system colors, light and dark, as the native app's `.orange`, `.indigo` and so on render.
abstract final class SystemColors {
  static const red = CupertinoDynamicColor.withBrightness(color: Color(0xFFFF383C), darkColor: Color(0xFFFF4245));
  static const orange = CupertinoDynamicColor.withBrightness(color: Color(0xFFFF8D28), darkColor: Color(0xFFFF9230));
  static const yellow = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFCC00), darkColor: Color(0xFFFFD600));
  static const green = CupertinoDynamicColor.withBrightness(color: Color(0xFF34C759), darkColor: Color(0xFF30D158));
  static const mint = CupertinoDynamicColor.withBrightness(color: Color(0xFF00C8B3), darkColor: Color(0xFF00DAC3));
  static const teal = CupertinoDynamicColor.withBrightness(color: Color(0xFF00C3D0), darkColor: Color(0xFF00D2E0));
  static const cyan = CupertinoDynamicColor.withBrightness(color: Color(0xFF00C0E8), darkColor: Color(0xFF3CD3FE));
  static const blue = CupertinoDynamicColor.withBrightness(color: Color(0xFF0088FF), darkColor: Color(0xFF0091FF));
  static const indigo = CupertinoDynamicColor.withBrightness(color: Color(0xFF6155F5), darkColor: Color(0xFF6D7CFF));
  static const purple = CupertinoDynamicColor.withBrightness(color: Color(0xFFCB30E0), darkColor: Color(0xFFDB34F2));
  static const pink = CupertinoDynamicColor.withBrightness(color: Color(0xFFFF2D55), darkColor: Color(0xFFFF375F));
  static const brown = CupertinoDynamicColor.withBrightness(color: Color(0xFFAC7F5E), darkColor: Color(0xFFB78A66));
}

/// `FlowLayout`: children left to right, wrapping to a new line when the next one does not fit.
class FlowLayout extends StatelessWidget {
  const FlowLayout({super.key, this.spacing = 8, required this.children});
  final double spacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(spacing: spacing, runSpacing: spacing, children: children);
}
