import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'taste_controller.dart';
import 'taste_models.dart';
import 'taste_recap.dart';
import 'taste_store.dart';

/// An sRGB color with components from 0 to 1, as the native palette stores it.
class RecapColor {
  const RecapColor(this.red, this.green, this.blue);

  factory RecapColor.hsb(double hue, double saturation, double brightness) {
    final sector = ((hue % 1) + 1) % 1 * 6;
    final index = sector.floor(), fraction = sector - index;
    final p = brightness * (1 - saturation), q = brightness * (1 - saturation * fraction), t = brightness * (1 - saturation * (1 - fraction));
    return switch (index) {
      0 => RecapColor(brightness, t, p),
      1 => RecapColor(q, brightness, p),
      2 => RecapColor(p, brightness, t),
      3 => RecapColor(p, q, brightness),
      4 => RecapColor(t, p, brightness),
      _ => RecapColor(brightness, p, q),
    };
  }

  /// From 8-bit channels, as decoded pixels arrive.
  factory RecapColor.bytes(int red, int green, int blue) => RecapColor(red / 255, green / 255, blue / 255);

  final double red, green, blue;

  /// Opaque ARGB for the UI's `Color`.
  int get argb => 0xFF000000 | ((red * 255).floor() << 16) | ((green * 255).floor() << 8) | (blue * 255).floor();
  String get hex => '#${[red, green, blue].map((value) => (value * 255).floor().toRadixString(16).padLeft(2, '0').toUpperCase()).join()}';
  double get luminance => 0.2126 * red + 0.7152 * green + 0.0722 * blue;

  (double hue, double saturation, double brightness) get hsb {
    final high = math.max(red, math.max(green, blue)), low = math.min(red, math.min(green, blue)), delta = high - low;
    if (delta <= 0) return (0, 0, high);
    double hue;
    if (high == red) {
      hue = (green - blue) / delta;
    } else if (high == green) {
      hue = (blue - red) / delta + 2;
    } else {
      hue = (red - green) / delta + 4;
    }
    hue /= 6;
    if (hue < 0) hue += 1;
    return (hue, delta / high, high);
  }

  RecapColor withValues({double? saturation, required double brightness}) {
    final value = hsb;
    return RecapColor.hsb(value.$1, saturation ?? value.$2, brightness);
  }

  factory RecapColor.fromJson(JsonObject json) => RecapColor(json.number('red'), json.number('green'), json.number('blue'));
  JsonObject toJson() => {'red': red, 'green': green, 'blue': blue};

  @override
  bool operator ==(Object other) => other is RecapColor && other.red == red && other.green == green && other.blue == blue;
  @override
  int get hashCode => Object.hash(red, green, blue);
}

/// The colors of a period, measured from the covers the person kept. Five
/// swatches ordered by presence, with stage colors derived for legible type.
class RecapPalette {
  const RecapPalette(this.swatches);
  final List<RecapColor> swatches;

  double get leadHue => _lead.hsb.$1;
  RecapColor get _lead {
    var best = swatches.first;
    for (final color in swatches) {
      if (_vividness(color) > _vividness(best)) best = color;
    }
    return best;
  }

  static double _vividness(RecapColor color) {
    final value = color.hsb;
    return value.$2 * value.$3;
  }

  /// Always dark enough for white type, whatever the artwork's colors are.
  RecapColor get ink => _lead.withValues(saturation: math.min(0.75, _lead.hsb.$2), brightness: 0.13);
  RecapColor get deep => _lead.withValues(saturation: math.min(0.8, _lead.hsb.$2), brightness: 0.26);

  /// Always bright enough to read on [ink].
  RecapColor get accent => _lead.withValues(saturation: math.min(0.72, math.max(0.38, _lead.hsb.$2)), brightness: math.max(0.9, _lead.hsb.$3));
  RecapColor get paper => _lead.withValues(saturation: math.min(0.1, _lead.hsb.$2), brightness: 0.96);
  RecapColor get paperInk => _lead.withValues(saturation: math.min(0.65, _lead.hsb.$2), brightness: 0.17);

  String get mood {
    final value = swatches.first.hsb;
    if (value.$2 < 0.16) return value.$3 < 0.45 ? 'ink' : (value.$3 > 0.78 ? 'paper' : 'ash');
    final degrees = value.$1 * 360;
    if (degrees < 15) return 'ember';
    if (degrees < 42) return 'amber';
    if (degrees < 68) return 'honey';
    if (degrees < 160) return 'moss';
    if (degrees < 195) return 'lagoon';
    if (degrees < 235) return 'deepSea';
    if (degrees < 265) return 'twilight';
    if (degrees < 300) return 'iris';
    if (degrees < 345) return 'peony';
    return 'ember';
  }

  String get moodName => L10n.text('palette.$mood');

  /// Colorless pixels dilute every month into grey, so colors count by how
  /// much they read as color. A page of white margin cannot outvote a blue sky.
  static RecapPalette? extract(List<RecapColor> pixels) {
    final buckets = <int, List<double>>{};
    for (final pixel in pixels) {
      final value = pixel.hsb;
      if (value.$3 <= 0.08) continue;
      final neutral = value.$2 < 0.14;
      final key = neutral ? 100 + (value.$3 * 3.99).floor() : (value.$1 * 12).floor() * 3 + (value.$3 * 2.99).floor();
      final weight = neutral ? 0.12 : 0.25 + value.$2 * value.$3;
      final bucket = buckets[key] ??= [0, 0, 0, 0];
      bucket[0] += pixel.red * weight;
      bucket[1] += pixel.green * weight;
      bucket[2] += pixel.blue * weight;
      bucket[3] += weight;
    }
    final ranked = buckets.entries.toList()..sort((a, b) => a.value[3] == b.value[3] ? a.key.compareTo(b.key) : b.value[3].compareTo(a.value[3]));
    final chosen = <RecapColor>[];
    for (final entry in ranked) {
      final bucket = entry.value;
      final color = RecapColor(bucket[0] / bucket[3], bucket[1] / bucket[3], bucket[2] / bucket[3]);
      if (chosen.any((other) => _distance(other, color) < 0.2)) continue;
      chosen.add(color);
      if (chosen.length == 5) break;
    }
    if (chosen.isEmpty) return null;
    while (chosen.length < 5) {
      final last = chosen.last;
      chosen.add(last.withValues(brightness: math.min(1, last.hsb.$3 * 0.72 + 0.1)));
    }
    return RecapPalette(chosen);
  }

  static double _distance(RecapColor a, RecapColor b) =>
      math.sqrt((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue));

  /// Stable colors for a period whose covers are not available yet.
  static RecapPalette seeded(String text) {
    // FNV-1a over UTF-8, wrapping at 64 bits like the native seed.
    var seed = BigInt.parse('1469598103934665603');
    final prime = BigInt.parse('1099511628211'), mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(text)) {
      seed = ((seed ^ BigInt.from(byte)) * prime) & mask;
    }
    final hue = (seed % BigInt.from(360)).toInt() / 360;
    return RecapPalette([
      RecapColor.hsb(hue, 0.72, 0.82),
      RecapColor.hsb(hue + 0.08, 0.55, 0.95),
      RecapColor.hsb(hue - 0.09, 0.68, 0.62),
      RecapColor.hsb(hue + 0.46, 0.5, 0.9),
      RecapColor.hsb(hue + 0.02, 0.2, 0.96),
    ]);
  }

  /// Samples of a decoded RGBA image already scaled to [side] × [side] by the UI.
  static List<RecapColor> pixels(List<int> rgba) => [
    for (var index = 0; index + 3 < rgba.length; index += 4) RecapColor.bytes(rgba[index], rgba[index + 1], rgba[index + 2]),
  ];

  factory RecapPalette.fromJson(JsonObject json) => RecapPalette(json.list('swatches', (value) => RecapColor.fromJson(jsonObject(value))));
  JsonObject toJson() => {
    'swatches': [for (final color in swatches) color.toJson()],
  };

  @override
  bool operator ==(Object other) => other is RecapPalette && listEquals(other.swatches, swatches);
  @override
  int get hashCode => Object.hashAll(swatches);
}

/// Decoded pixels of a work's cover for palette measurement, supplied by the UI
/// (`RecapArtwork.image`). Returns RGBA bytes of a small square, or null.
typedef RecapCoverPixels = Future<List<int>?> Function(RecapWork work, {required bool generated});

/// `RecapShelf`: everything the recap surfaces read for one mode.
class RecapShelf extends ChangeNotifier {
  RecapShelf({required this.controller, required this.mode});
  final TasteController controller;
  final TasteMode mode;

  List<TasteRecap> issues = [];
  TasteRecap? week;
  TasteRecap? year;
  TasteRecap? sample;
  bool loaded = false;
  bool failed = false;
  String loadedKey = '';
  final _palettes = <String, RecapPalette>{};
  RecapIndex? _index;

  TasteRecap? get latest => issues.where((recap) => recap.isComplete).firstOrNull ?? issues.firstOrNull;
  List<TasteRecap> get pastIssues => issues.where((recap) => recap.id != latest?.id).toList();
  TasteRecap? recap(DateTime start) => issues.where((recap) => recap.interval.start == start).firstOrNull;
  RecapPalette palette(TasteRecap recap) => _palettes[recap.id] ?? RecapPalette.seeded(recap.tags.firstOrNull?.name ?? recap.id);

  /// The full issue, including matches from the wider library.
  TasteRecap opened(TasteRecap recap, {DateTime? now}) {
    if (recap.period != TastePeriod.month || recap.isSample) return recap;
    final full = _index?.recap(period: TastePeriod.month, offset: recap.offset, now: now);
    if (full == null) return recap;
    return full..issue = recap.issue;
  }

  void load({required String key, DateTime? now}) {
    if (loadedKey != key) {
      loaded = false;
      failed = false;
    }
    try {
      final clock = now ?? DateTime.now();
      final index = controller.recapIndex(mode);
      final built = index.issues(period: TastePeriod.month, now: clock);
      TasteRecap? enough(TasteRecap? recap) => recap != null && recap.saves >= 3 ? recap : null;
      _index = index;
      issues = built;
      week = index.recap(period: TastePeriod.week, offset: 0, now: clock);
      year = enough(index.yearly(offset: 0, now: clock)) ?? enough(index.yearly(offset: -1, now: clock));
      sample = built.isEmpty ? TasteRecapSample.sample(mode: mode, now: clock, timeZone: controller.control.timeZone) : null;
      loaded = true;
      loadedKey = key;
      for (final recap in [?latest, ?year, ...issues, ?sample].take(14)) {
        _restore(recap);
      }
    } on Object {
      failed = true;
      loaded = true;
    }
    notifyListeners();
  }

  void _restore(TasteRecap recap) {
    if (_palettes.containsKey(recap.id) || recap.isSample) return;
    final saved = controller.store(recap.mode).metadata('recap.palette.${recap.id}');
    if (saved is Map<String, Object?>) {
      try {
        _palettes[recap.id] = RecapPalette.fromJson(saved);
      } on SwiftJsonError {
        // A palette that cannot be read is measured again.
      }
    }
  }

  /// Measured once from the period's covers. Open periods are re-measured because they still change.
  Future<void> measure(TasteRecap recap, RecapCoverPixels artwork) async {
    if ((_palettes.containsKey(recap.id) && recap.isComplete) || recap.saved.isEmpty) return;
    final pixels = <RecapColor>[];
    for (final work in recap.saved.take(16)) {
      final rgba = await artwork(work, generated: recap.isSample);
      if (rgba != null) pixels.addAll(RecapPalette.pixels(rgba));
    }
    final palette = RecapPalette.extract(pixels);
    if (palette == null) return;
    _palettes[recap.id] = palette;
    if (!recap.isSample && recap.isComplete) controller.store(recap.mode).setMetadata(palette.toJson(), 'recap.palette.${recap.id}');
    notifyListeners();
  }
}
