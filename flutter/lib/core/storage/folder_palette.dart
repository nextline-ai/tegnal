import 'dart:math' as math;

import 'app_database.dart';

/// `FolderPalette`: folder colors for both libraries, a fixed set of vivid colors in the order
/// new folders take them, then generated hues once a library uses every one. The color sheet
/// offers the first ten a library doesn't use yet.
abstract final class FolderPalette {
  static const colors = [
    0xFF1F6BFF, // Blue
    0xFFFF3B30, // Red
    0xFF00C853, // Green
    0xFFFF9500, // Orange
    0xFF8E4BFF, // Violet
    0xFFFF2D87, // Pink
    0xFF00C2E8, // Cyan
    0xFFFFCC00, // Yellow
    0xFF4A3DFF, // Indigo
    0xFF00BFA0, // Teal
    0xFFFF6A3D, // Coral
    0xFF7CD200, // Lime
    0xFFD63CFF, // Magenta
    0xFF2FA8FF, // Sky
    0xFFFFB000, // Amber
    0xFF00A86B, // Emerald
    0xFFB026FF, // Purple
    0xFFFF4F7B, // Rose
    0xFF0047D6, // Cobalt
    0xFF2EE0B0, // Mint
    0xFFE3122C, // Crimson
    0xFF3DB500, // Leaf
    0xFFFF4FD8, // Orchid
    0xFF0090C8, // Ocean
    0xFFFF7A00, // Tangerine
    0xFF6A1BE0, // Grape
    0xFFE0006E, // Raspberry
    0xFF00897B, // Pine
    0xFFC8A000, // Gold
    0xFF2D3DB8, // Navy
    0xFF0A84FF, // Azure
    0xFF7B83FF, // Periwinkle
    0xFF00D0D0, // Turquoise
    0xFFB5651D, // Copper
    0xFF9C27B0, // Plum
    0xFF5C6B80, // Slate
  ];

  /// The comics library's Unfiled and the image library's Uncategorized folder when first made.
  static const unfiled = 0xFF2FA8FF;
  static const unsorted = 0xFF00C853;

  /// What the two default folders were made with before; sync still treats these as untouched.
  static const earlierUnfiled = 0xFF2196F3;
  static const earlierUnsorted = 0xFF66BB70;
  static const _slate = 0xFF5C6B80;
  static const _generatedCount = 512;

  /// Every color earlier versions handed out on their own, each with its own replacement, so
  /// folders that differed still differ.
  static const replacements = {
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

  static int colorAt(int index) => index < colors.length ? colors[index] : generated(index - colors.length);

  /// Golden-angle hues after the palette, bright enough to sit with it.
  static int generated(int index) => AppDatabase.colorFromHSV(h: (index * 0.618033988749895) % 1.0, s: 0.8, v: 0.95);

  static final Set<int> _generatedColors = {for (var index = 0; index < _generatedCount; index++) generated(index)};

  static bool isCurrent(int color) => colors.contains(color) || _generatedColors.contains(color);

  /// The first `count` colors none of `used` takes, in the order new folders get them.
  static List<int> unused(Set<int> used, int count) {
    final result = <int>[];
    for (var index = 0; result.length < count && index < colors.length + _generatedCount; index++) {
      final color = colorAt(index);
      if (!used.contains(color)) result.add(color);
    }
    return result;
  }

  static int next(Set<int> used) {
    final choices = unused(used, 1);
    return choices.isEmpty ? colors.first : choices.first;
  }

  static int _opaque(int color) => 0xFF000000 | (color & 0xFFFFFF);

  /// A color from an earlier version, a backup, another device or another app, as the closest
  /// current color. Current colors stay as they are.
  static int vivid(int color) {
    final opaque = _opaque(color);
    if (isCurrent(opaque)) return opaque;
    return replacements[opaque] ?? nearest(opaque);
  }

  /// New colors for a library's folder colors: earlier palette colors by the table, others by the
  /// nearest color no other folder has taken.
  static Map<int, int> replacing(List<int> existing) {
    final result = <int, int>{};
    final taken = <int>{};
    for (final color in existing) {
      final opaque = _opaque(color);
      final mapped = isCurrent(opaque) ? opaque : replacements[opaque];
      if (mapped != null) {
        result[color] = mapped;
        taken.add(mapped);
      }
    }
    for (final color in existing) {
      if (result.containsKey(color)) continue;
      final mapped = nearest(_opaque(color), avoiding: taken);
      result[color] = mapped;
      taken.add(mapped);
    }
    return result;
  }

  /// Grays go to slate. Other colors keep their hue, made vivid, and take the closest palette color
  /// in OKLab, skipping `avoiding` while any other is left.
  static int nearest(int color, {Set<int> avoiding = const {}}) {
    final (lightness, a, b) = _oklab(color);
    final chroma = math.sqrt(a * a + b * b);
    final free = [
      for (final candidate in colors)
        if (!avoiding.contains(candidate)) candidate,
    ];
    final pool = free.isEmpty ? colors : free;
    if (chroma < 0.05 && (pool.contains(_slate) || free.isEmpty)) return _slate;
    final (double, double, double) target;
    if (chroma < 0.05) {
      target = (lightness, a, b);
    } else {
      final boosted = math.max(chroma, 0.17) / chroma;
      target = (math.min(math.max(lightness, 0.5), 0.82), a * boosted, b * boosted);
    }
    var best = pool.first;
    var bestDistance = double.infinity;
    for (final candidate in pool) {
      if (candidate == _slate && chroma >= 0.05) continue;
      final (l, ca, cb) = _oklab(candidate);
      final distance = (l - target.$1) * (l - target.$1) + (ca - target.$2) * (ca - target.$2) + (cb - target.$3) * (cb - target.$3);
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    return best;
  }

  static (double, double, double) _oklab(int argb) {
    double linear(int channel) {
      final value = (channel & 0xFF) / 255;
      return value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    }

    double cbrt(double value) => value <= 0 ? 0 : math.pow(value, 1 / 3).toDouble();
    final r = linear(argb >> 16), g = linear(argb >> 8), b = linear(argb);
    final l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    );
  }
}
