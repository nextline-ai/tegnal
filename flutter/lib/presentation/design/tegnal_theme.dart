import 'package:cupertino_ui/cupertino_ui.dart';

/// iOS system colors as the native app resolves them, light and dark.
abstract final class TegnalColors {
  static const background = CupertinoDynamicColor.withBrightness(color: Color(0xFFFFFFFF), darkColor: Color(0xFF000000));
  static const secondaryBackground = CupertinoDynamicColor.withBrightness(color: Color(0xFFF2F2F7), darkColor: Color(0xFF1C1C1E));
  static const label = CupertinoDynamicColor.withBrightness(color: Color(0xFF000000), darkColor: Color(0xFFFFFFFF));
  static const secondaryLabel = CupertinoDynamicColor.withBrightness(color: Color(0x993C3C43), darkColor: Color(0x99EBEBF5));
  static const tertiaryLabel = CupertinoDynamicColor.withBrightness(color: Color(0x4D3C3C43), darkColor: Color(0x4DEBEBF5));
  static const separator = CupertinoDynamicColor.withBrightness(color: Color(0x4A3C3C43), darkColor: Color(0x99545458));

  /// `Color.accentColor` / `.tint` on iOS 26.
  static const tint = CupertinoDynamicColor.withBrightness(color: Color(0xFF0088FF), darkColor: Color(0xFF0091FF));

  /// `.secondary.opacity(0.12)`, the empty cover.
  static const coverPlaceholder = CupertinoDynamicColor.withBrightness(color: Color(0x1F3C3C43), darkColor: Color(0x1FEBEBF5));

  /// Liquid Glass over plain backgrounds, measured from the native app.
  static const glassFill = CupertinoDynamicColor.withBrightness(color: Color(0xF2FFFFFF), darkColor: Color(0x6B404040));
  static const glassStroke = CupertinoDynamicColor.withBrightness(color: Color(0x1F000000), darkColor: Color(0x1AFFFFFF));
  static const glassSelection = CupertinoDynamicColor.withBrightness(color: Color(0x22000000), darkColor: Color(0x4D000000));
}

/// The native type scale (SF Pro sizes), set in Pretendard with its Japanese companion as fallback.
abstract final class TegnalType {
  static const family = 'Pretendard';
  static const fallback = ['Pretendard JP'];

  static TextStyle style(double size, {FontWeight weight = FontWeight.w400, Color? color, double? height}) => TextStyle(
    fontFamily: family,
    fontFamilyFallback: fallback,
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
    letterSpacing: _tracking(size),
  );

  /// SF Pro's optical tracking at common sizes, in points.
  static double _tracking(double size) => switch (size) {
    >= 20 => 0.38,
    >= 17 => -0.43,
    >= 15 => -0.23,
    >= 13 => -0.08,
    _ => 0,
  };

  static const double body = 17;
  static const double subheadline = 15;
  static const double footnote = 13;
  static const double caption = 12;
  static const double caption2 = 11;
}

CupertinoThemeData tegnalTheme(Brightness brightness) => CupertinoThemeData(
  brightness: brightness,
  primaryColor: TegnalColors.tint,
  scaffoldBackgroundColor: TegnalColors.background,
  barBackgroundColor: const Color(0x00000000),
  textTheme: CupertinoTextThemeData(
    primaryColor: TegnalColors.tint,
    textStyle: TegnalType.style(TegnalType.body, color: TegnalColors.label),
  ),
);
