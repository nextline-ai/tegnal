/// Native AppDatabase.nextFolderColor: first unused curated color, followed by
/// golden-ratio hues once the entire palette is present in this library.
abstract final class FolderColors {
  static const palette = <int>[
    0xFF2563EB,
    0xFF059669,
    0xFFEA580C,
    0xFFE11D48,
    0xFF7C3AED,
    0xFF0891B2,
    0xFFD97706,
    0xFFDB2777,
    0xFF4F46E5,
    0xFF0D9488,
    0xFF65A30D,
    0xFFC026D3,
    0xFFDC2626,
    0xFF9333EA,
    0xFF0284C7,
    0xFFB45309,
    0xFF16A34A,
    0xFFF97316,
    0xFF6366F1,
    0xFF14B8A6,
    0xFF84CC16,
    0xFFEC4899,
    0xFFA855F7,
    0xFF3B82F6,
    0xFF10B981,
    0xFFF59E0B,
    0xFFEF4444,
    0xFF64748B,
  ];

  static int next(List<int> existingColors, {Set<int> excluding = const {}}) {
    final used = {...existingColors, ...excluding};
    for (final color in palette) {
      if (!used.contains(color)) return color;
    }
    final hue =
        ((existingColors.length + excluding.length) * .618033988749895) % 1;
    const c = .88 * .75;
    final h = ((hue % 1 + 1) % 1) * 6;
    final x = c * (1 - ((h % 2) - 1).abs());
    const m = .88 - c;
    final (r, g, b) = switch (h.toInt() % 6) {
      0 => (c, x, 0.0),
      1 => (x, c, 0.0),
      2 => (0.0, c, x),
      3 => (0.0, x, c),
      4 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return 0xFF000000 |
        (((r + m) * 255).round() << 16) |
        (((g + m) * 255).round() << 8) |
        ((b + m) * 255).round();
  }
}
