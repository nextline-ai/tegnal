import 'dart:math' as math;

/// `FolderPalette`: folder colors for both libraries, Apple's iOS system colors as the Human
/// Interface Guidelines give them for the light appearance. The color sheet shows every one; a new
/// folder takes the one the fewest folders use, in `assignmentOrder`.
abstract final class FolderPalette {
  static const red = 0xFFFF383C;
  static const orange = 0xFFFF8D28;
  static const yellow = 0xFFFFCC00;
  static const green = 0xFF34C759;
  static const mint = 0xFF00C8B3;
  static const teal = 0xFF00C3D0;
  static const cyan = 0xFF00C0E8;
  static const blue = 0xFF0088FF;
  static const indigo = 0xFF6155F5;
  static const purple = 0xFFCB30E0;
  static const pink = 0xFFFF2D55;
  static const brown = 0xFFAC7F5E;
  static const gray = 0xFF8E8E93;

  /// In the order the color sheet shows them.
  static const colors = [red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray];

  /// The order new folders take them: hues far apart first, so the first folders differ most.
  static const assignmentOrder = [blue, red, green, orange, purple, yellow, teal, pink, indigo, mint, cyan, brown, gray];

  /// The comics library's Unfiled and the image library's Uncategorized folder when first made.
  static const unfiled = blue;
  static const unsorted = green;

  /// What the two default folders were made with before, newest first; sync still treats these as untouched.
  static const earlierUnfiled = [0xFF2FA8FF, 0xFF2196F3];
  static const earlierUnsorted = [0xFF00C853, 0xFF66BB70];

  /// The vivid palette 1.6 used, each color with the system color that replaces it. Fixed rather
  /// than worked out, so every device and both apps move a folder to the same color.
  static const previous = {
    0xFF1F6BFF: blue, 0xFFFF3B30: red, 0xFF00C853: green, 0xFFFF9500: orange, //
    0xFF8E4BFF: purple, 0xFFFF2D87: pink, 0xFF00C2E8: cyan, 0xFFFFCC00: yellow, //
    0xFF4A3DFF: indigo, 0xFF00BFA0: mint, 0xFFFF6A3D: orange, 0xFF7CD200: green, //
    0xFFD63CFF: purple, 0xFF2FA8FF: blue, 0xFFFFB000: yellow, 0xFF00A86B: green, //
    0xFFB026FF: purple, 0xFFFF4F7B: pink, 0xFF0047D6: blue, 0xFF2EE0B0: mint, //
    0xFFE3122C: red, 0xFF3DB500: green, 0xFFFF4FD8: purple, 0xFF0090C8: cyan, //
    0xFFFF7A00: orange, 0xFF6A1BE0: indigo, 0xFFE0006E: pink, 0xFF00897B: mint, //
    0xFFC8A000: yellow, 0xFF2D3DB8: indigo, 0xFF0A84FF: blue, 0xFF7B83FF: indigo, //
    0xFF00D0D0: teal, 0xFFB5651D: brown, 0xFF9C27B0: purple, 0xFF5C6B80: gray,
  };

  /// Every color versions before 1.6 handed out on their own, with the 1.6 color that replaced it.
  static const earlier = {
    0xFF2196F3: 0xFF2FA8FF,
    0xFF66BB70: 0xFF00C853,
    0xFF2563EB: 0xFF1F6BFF,
    0xFF059669: 0xFF00A86B,
    0xFFEA580C: 0xFFFF6A3D,
    0xFFE11D48: 0xFFE3122C,
    0xFF7C3AED: 0xFF6A1BE0,
    0xFF0891B2: 0xFF0090C8,
    0xFFD97706: 0xFFFF7A00,
    0xFFDB2777: 0xFFE0006E,
    0xFF4F46E5: 0xFF4A3DFF,
    0xFF0D9488: 0xFF00897B,
    0xFF65A30D: 0xFF3DB500,
    0xFFC026D3: 0xFF9C27B0,
    0xFFDC2626: 0xFFFF3B30,
    0xFF9333EA: 0xFFB026FF,
    0xFF0284C7: 0xFF0A84FF,
    0xFFB45309: 0xFFB5651D,
    0xFF16A34A: 0xFF00BFA0,
    0xFFF97316: 0xFFFF9500,
    0xFF6366F1: 0xFF8E4BFF,
    0xFF14B8A6: 0xFF00D0D0,
    0xFF84CC16: 0xFF7CD200,
    0xFFEC4899: 0xFFFF2D87,
    0xFFA855F7: 0xFFD63CFF,
    0xFF3B82F6: 0xFF7B83FF,
    0xFF10B981: 0xFF2EE0B0,
    0xFFF59E0B: 0xFFFFB000,
    0xFFEF4444: 0xFFFF4F7B,
    0xFF64748B: 0xFF5C6B80,
  };

  static bool isCurrent(int color) => colors.contains(color);

  /// The color for a new folder: the first in `assignmentOrder` the fewest of `existing` use,
  /// leaving out `excluding` while any other is left.
  static int next(Iterable<int> existing, {Set<int> excluding = const {}}) {
    final counts = <int, int>{};
    for (final color in existing) {
      final system = vivid(color);
      counts[system] = (counts[system] ?? 0) + 1;
    }
    final free = [
      for (final color in assignmentOrder)
        if (!excluding.contains(color)) color,
    ];
    var best = blue;
    var fewest = -1;
    for (final color in free.isEmpty ? assignmentOrder : free) {
      final count = counts[color] ?? 0;
      if (fewest < 0 || count < fewest) {
        best = color;
        fewest = count;
      }
    }
    return best;
  }

  static int _opaque(int color) => 0xFF000000 | (color & 0xFFFFFF);

  /// A color from an earlier version, a backup, another device or another app, as the system color
  /// for it. System colors stay as they are. The same color always gives the same answer.
  static int vivid(int color) {
    final opaque = _opaque(color);
    if (isCurrent(opaque)) return opaque;
    return previous[earlier[opaque] ?? opaque] ?? nearest(opaque);
  }

  /// Grays go to gray and dark or muted warm colors to brown. Every other color takes the system
  /// color nearest its hue in OKLCH.
  static int nearest(int color) {
    final (lightness, chroma, hue) = _oklch(color);
    if (chroma < 0.04) return gray;
    if (hue >= 30 && hue <= 100 && (lightness < 0.55 || (chroma < 0.11 && lightness < 0.75))) return brown;
    double distance(int other) {
      final d = (hue - _oklch(other).$3).abs();
      return math.min(d, 360 - d);
    }

    var best = blue;
    var closest = double.infinity;
    for (final candidate in colors) {
      if (candidate == gray || candidate == brown) continue;
      final d = distance(candidate);
      if (d < closest) {
        best = candidate;
        closest = d;
      }
    }
    return best;
  }

  static (double, double, double) _oklch(int argb) {
    double linear(int channel) {
      final value = (channel & 0xFF) / 255;
      return value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    }

    double cbrt(double value) => value <= 0 ? 0 : math.pow(value, 1 / 3).toDouble();
    final r = linear(argb >> 16), g = linear(argb >> 8), b = linear(argb);
    final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    final a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    final bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    final hue = math.atan2(bb, a) * 180 / math.pi;
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, math.sqrt(a * a + bb * bb), hue < 0 ? hue + 360 : hue);
  }
}
