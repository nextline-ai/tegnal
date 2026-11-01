import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'thumbnail_image_provider.dart';

/// The colors of a period, measured from the covers the person kept. Five
/// swatches ordered by presence, with stage colors derived for legible type.
class RecapPalette {
  const RecapPalette(this.swatches);
  final List<Color> swatches;

  HSVColor get _lead => HSVColor.fromColor(
    swatches.reduce((a, b) => _vividness(a) >= _vividness(b) ? a : b),
  );
  static double _vividness(Color color) {
    final value = HSVColor.fromColor(color);
    return value.saturation * value.value;
  }

  HSVColor _tone(double saturation, double value) => _lead
      .withSaturation(math.min(saturation, _lead.saturation))
      .withValue(value);

  /// Always dark enough for white type, whatever the artwork's colors are.
  Color get ink => _tone(.75, .13).toColor();
  Color get deep => _tone(.8, .26).toColor();

  /// Always bright enough to read on [ink].
  Color get accent => _lead
      .withSaturation(_lead.saturation.clamp(.38, .72))
      .withValue(math.max(.9, _lead.value))
      .toColor();
  Color get paper => _tone(.1, .96).toColor();
  Color get paperInk => _tone(.65, .17).toColor();

  String get mood {
    final value = HSVColor.fromColor(swatches.first);
    if (value.saturation < .16) {
      return value.value < .45 ? 'ink' : (value.value > .78 ? 'paper' : 'ash');
    }
    final hue = value.hue;
    if (hue < 15) return 'ember';
    if (hue < 42) return 'amber';
    if (hue < 68) return 'honey';
    if (hue < 160) return 'moss';
    if (hue < 195) return 'lagoon';
    if (hue < 235) return 'deepSea';
    if (hue < 265) return 'twilight';
    if (hue < 300) return 'iris';
    if (hue < 345) return 'peony';
    return 'ember';
  }

  /// Colorless pixels dilute every month into grey, so colors count by how
  /// much they read as color. A page of white margin cannot outvote a blue sky.
  static RecapPalette? extract(Iterable<Color> pixels) {
    final buckets = <int, List<double>>{};
    for (final pixel in pixels) {
      final value = HSVColor.fromColor(pixel);
      if (value.value <= .08) continue;
      final neutral = value.saturation < .14;
      final key = neutral
          ? 1000 + (value.value * 3.99).floor()
          : (value.hue / 30).floor() * 3 + (value.value * 2.99).floor();
      final weight = neutral ? .12 : .25 + value.saturation * value.value;
      final bucket = buckets[key] ??= [0, 0, 0, 0];
      bucket[0] += pixel.r * weight;
      bucket[1] += pixel.g * weight;
      bucket[2] += pixel.b * weight;
      bucket[3] += weight;
    }
    final ranked = buckets.entries.toList()
      ..sort((a, b) {
        final weight = b.value[3].compareTo(a.value[3]);
        return weight == 0 ? a.key.compareTo(b.key) : weight;
      });
    final chosen = <Color>[];
    for (final entry in ranked) {
      final bucket = entry.value;
      final color = Color.from(
        alpha: 1,
        red: bucket[0] / bucket[3],
        green: bucket[1] / bucket[3],
        blue: bucket[2] / bucket[3],
      );
      if (chosen.any((other) => _distance(other, color) < .2)) continue;
      chosen.add(color);
      if (chosen.length == 5) break;
    }
    if (chosen.isEmpty) return null;
    while (chosen.length < 5) {
      final last = HSVColor.fromColor(chosen.last);
      chosen.add(last.withValue(math.min(1, last.value * .72 + .1)).toColor());
    }
    return RecapPalette(chosen);
  }

  static double _distance(Color a, Color b) => math.sqrt(
    math.pow(a.r - b.r, 2) + math.pow(a.g - b.g, 2) + math.pow(a.b - b.b, 2),
  );

  /// Stable colors for a period whose covers are not available yet.
  factory RecapPalette.seeded(String text) {
    var hash = 2166136261;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 16777619) & 0xffffffff;
    }
    final hue = (hash % 360).toDouble();
    Color tone(double shift, double saturation, double value) =>
        HSVColor.fromAHSV(1, (hue + shift) % 360, saturation, value).toColor();
    return RecapPalette([
      tone(0, .72, .82),
      tone(29, .55, .95),
      tone(328, .68, .62),
      tone(166, .5, .9),
      tone(7, .2, .96),
    ]);
  }

  List<int> toJson() => swatches.map((color) => color.toARGB32()).toList();
  static RecapPalette? fromJson(Object? value) {
    if (value is! List || value.length != 5) return null;
    return RecapPalette(value.whereType<int>().map(Color.new).toList());
  }

  /// Reads a cover at a tiny size; failures simply contribute no pixels.
  static Future<List<Color>> pixels(
    Uri url,
    Map<String, String> headers,
  ) async {
    final completer = Completer<ui.Image?>();
    final stream = thumbnailImageProvider(
      url,
      headers,
      24,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future;
    if (image == null) return const [];
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return const [];
      return [
        for (var offset = 0; offset + 3 < data.lengthInBytes; offset += 4)
          Color.fromARGB(
            255,
            data.getUint8(offset),
            data.getUint8(offset + 1),
            data.getUint8(offset + 2),
          ),
      ];
    } finally {
      image.dispose();
    }
  }
}

/// Abstract color fields. They stand in for artwork whenever a page must not
/// show any: the private mode and share cards.
class RecapColorField extends StatelessWidget {
  const RecapColorField({super.key, required this.palette, this.seed = 7});
  final RecapPalette palette;
  final int seed;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRect(
      child: CustomPaint(
        painter: _ColorFieldPainter(palette, seed),
        size: Size.infinite,
      ),
    ),
  );
}

class _ColorFieldPainter extends CustomPainter {
  const _ColorFieldPainter(this.palette, this.seed);
  final RecapPalette palette;
  final int seed;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.ink);
    final random = math.Random(seed);
    final blur = math.min(size.width, size.height) * .13;
    final paint = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    for (var index = 0; index < 7; index++) {
      final radius =
          math.max(size.width, size.height) * (.24 + random.nextDouble() * .3);
      paint.color = palette.swatches[index % 5].withValues(
        alpha: .62 + random.nextDouble() * .38,
      );
      canvas.drawCircle(
        Offset(
          size.width * random.nextDouble(),
          size.height * random.nextDouble(),
        ),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ColorFieldPainter old) =>
      old.palette != palette || old.seed != seed;
}

/// Procedural landscapes for the sample issue, which has no library to draw from.
class RecapGeneratedArt extends StatelessWidget {
  const RecapGeneratedArt({super.key, required this.seed});
  final int seed;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRect(
      child: CustomPaint(painter: _LandscapePainter(seed), size: Size.infinite),
    ),
  );
}

class _LandscapePainter extends CustomPainter {
  const _LandscapePainter(this.seed);
  final int seed;
  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed * 7919 + 13);
    final hue = random.nextDouble() * 360;
    final shift = 22 + random.nextDouble() * 50;
    Color tone(double offset, double saturation, double value) =>
        HSVColor.fromAHSV(1, (hue + offset) % 360, saturation, value).toColor();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          [tone(0, .62, .34), tone(shift, .72, .82), tone(shift * 2, .5, 1)],
          [0, .62, 1],
        ),
    );
    final sun = size.width * (.1 + random.nextDouble() * .12);
    canvas.drawCircle(
      Offset(
        size.width * (.2 + random.nextDouble() * .6),
        size.height * (.2 + random.nextDouble() * .3),
      ),
      sun,
      Paint()..color = tone(shift * 2.6, .28, 1),
    );
    for (var layer = 0; layer < 4; layer++) {
      final floor = size.height * (.5 + layer * .13);
      final swell = size.height * (.05 + random.nextDouble() * .09);
      final phase = random.nextDouble() * 6;
      final wave = 1.2 + random.nextDouble() * 2.4;
      final path = Path()..moveTo(0, size.height);
      for (var step = 0; step <= 40; step++) {
        final x = size.width * step / 40;
        path.lineTo(
          x,
          floor + math.sin(x / size.width * wave * math.pi * 2 + phase) * swell,
        );
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = tone(
            -shift * layer * .8,
            .55 + layer * .08,
            .62 - layer * .14,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_LandscapePainter old) => old.seed != seed;
}
