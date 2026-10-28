import 'package:material_ui/material_ui.dart';

/// The collection's accents and semantic Material color roles.
abstract final class TegnalColors {
  static const accent = Color(0xFF009DFF);
  static const green = Color(0xFF269E58);
  static const red = Color(0xFFDB3548);
  static const orange = Color(0xFFE57B24);
  static const purple = Color(0xFF9861DE);
  static const grey = Color(0xFF8A8A91);

  static Color background(BuildContext context) =>
      Theme.of(context).colorScheme.surface;
  static Color surface(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainer;
  static Color label(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;
  static Color secondaryLabel(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
  static Color fill(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHighest;
  static Color separator(BuildContext context) =>
      Theme.of(context).colorScheme.outlineVariant;
}

/// Material 3 with the Expressive components supported by material_ui 1.8.0.
/// Pretendard and its Japanese companion are bundled for offline typography.
ThemeData tegnalTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: TegnalColors.accent,
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFF009DFF) : TegnalColors.accent,
        onPrimary: dark ? const Color(0xFF002E68) : Colors.white,
        surface: dark ? Colors.black : const Color(0xFFFAFAFC),
        surfaceContainerLowest: dark ? const Color(0xFF08080A) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF1C1C1E)
            : const Color(0xFFF5F5F8),
        onSurface: dark ? Colors.white : const Color(0xFF151517),
        onSurfaceVariant: dark
            ? const Color(0xFF98989E)
            : const Color(0xFF68686E),
        surfaceContainer: dark
            ? const Color(0xFF1C1C1E)
            : const Color(0xFFF0F0F5),
        surfaceContainerHigh: dark
            ? const Color(0xFF25252A)
            : const Color(0xFFEAEAF0),
        surfaceContainerHighest: dark
            ? const Color(0xFF303037)
            : const Color(0xFFE3E3EB),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'Pretendard',
    fontFamilyFallback: const ['Pretendard JP'],
    iconTheme: IconThemeData(size: 28, color: scheme.onSurface),
    primaryIconTheme: IconThemeData(size: 28, color: scheme.onPrimary),
    iconButtonTheme: const IconButtonThemeData(
      variant: StyleVariant.material3Expressive,
      style: ButtonStyle(
        iconSize: WidgetStatePropertyAll(30),
        minimumSize: WidgetStatePropertyAll(Size(48, 48)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
      ),
    ),
    appBarTheme: AppBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      iconTheme: IconThemeData(size: 30, color: scheme.onSurface),
      actionsIconTheme: IconThemeData(size: 30, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontFamily: 'Pretendard',
          fontFamilyFallback: const ['Pretendard JP'],
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: dark ? const Color(0xFF202020) : const Color(0xFFEFEFF1),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class TegnalIconBadge extends StatelessWidget {
  const TegnalIconBadge({
    super.key,
    required this.icon,
    this.color = TegnalColors.accent,
    this.size = 36,
  });
  final IconData icon;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(size * .3),
    ),
    alignment: Alignment.center,
    child: Icon(icon, size: size * .72, color: Colors.white),
  );
}

/// The platform-independent Material switch provides touch, drag, keyboard,
/// focus, and accessibility behavior through the official component.
class TegnalSwitch extends StatelessWidget {
  const TegnalSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor = TegnalColors.accent,
    this.semanticLabel,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      label: semanticLabel,
      enabled: onChanged != null,
      child: Switch(
        value: value,
        onChanged: onChanged,
        activeTrackColor: activeColor,
      ),
    ),
  );
}
