import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/taste/recap_shelf.dart';
import 'recap_style.dart';

/// `RecapCoverArt`: illustrated covers drawn entirely in code, so a cover can sit on a
/// shelf or be shared without ever showing a saved work. Each issue takes its hue from
/// the period's measured colors, and neighboring issues always get different scenes.
class RecapCoverArt extends StatelessWidget {
  const RecapCoverArt({super.key, required this.palette, required this.seed});
  static const styles = 8;
  final RecapPalette palette;
  final int seed;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: RecapCoverPainter(seed: seed, hue: palette.leadHue),
      size: Size.infinite,
    ),
  );
}

class RecapCoverPainter extends CustomPainter {
  RecapCoverPainter({required this.seed, required this.hue});
  final int seed;
  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    _Scene(seed, hue, size, canvas).draw();
  }

  @override
  bool shouldRepaint(RecapCoverPainter old) => old.seed != seed || old.hue != hue;
}

class _Scene {
  _Scene(this.seed, this.hue, this.size, this.canvas) : _random = RecapRandom(seed) {
    shift = 0.06 + _random.next() * 0.14;
  }

  final int seed;
  final double hue;
  final Size size;
  final Canvas canvas;
  final RecapRandom _random;
  late final double shift;

  double get width => size.width;
  double get height => size.height;
  double next() => _random.next();

  Color tone(double offset, double saturation, double brightness) => RecapColor.hsb(hue + offset, saturation, brightness).color;

  void sky(List<Color> colors) => canvas.drawRect(
    Offset.zero & size,
    Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors).createShader(Offset.zero & size),
  );

  void disc(Offset center, double radius, Color color) => canvas.drawCircle(center, radius, Paint()..color = color);

  /// A filled horizon. Two summed sines keep the outline from looking mechanical.
  void ridge({required double floor, required double swell, required double waves, required double phase, required Color color}) {
    final path = Path()..moveTo(0, height);
    for (var step = 0; step <= 180; step++) {
      final x = width * step / 180, position = x / width * math.pi * 2;
      path.lineTo(x, floor + math.sin(position * waves + phase) * swell + math.sin(position * waves * 2.3 + phase * 1.7) * swell * 0.28);
    }
    path
      ..lineTo(width, height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void stars({required int count, required double limit, required Color color}) {
    for (var index = 0; index < count; index++) {
      final radius = width * (0.0025 + next() * 0.004);
      final center = Offset(width * next(), height * limit * next());
      disc(center, radius, color.withValues(alpha: 0.4 + next() * 0.6));
    }
  }

  void draw() {
    switch (((seed % RecapCoverArt.styles) + RecapCoverArt.styles) % RecapCoverArt.styles) {
      case 0:
        ridges();
      case 1:
        sea();
      case 2:
        arches();
      case 3:
        orbit();
      case 4:
        clouds();
      case 5:
        forest();
      case 6:
        city();
      default:
        aurora();
    }
  }

  void ridges() {
    sky([tone(0, 0.62, 0.34), tone(shift, 0.72, 0.82), tone(shift * 2, 0.5, 1)]);
    disc(Offset(width * (0.3 + next() * 0.4), height * (0.3 + next() * 0.14)), width * 0.2, tone(shift * 2.6, 0.28, 1));
    for (var layer = 0; layer < 4; layer++) {
      ridge(
        floor: height * (0.54 + layer * 0.12),
        swell: height * (0.05 + next() * 0.06),
        waves: 1.2 + next() * 1.8,
        phase: next() * 6,
        color: tone(-shift * layer * 0.8, 0.55 + layer * 0.08, 0.62 - layer * 0.14),
      );
    }
  }

  void sea() {
    sky([tone(0, 0.68, 0.26), tone(shift, 0.6, 0.62), tone(shift * 2, 0.38, 0.96)]);
    final horizon = height * 0.56;
    disc(Offset(width * (0.35 + next() * 0.3), horizon - height * 0.08), width * 0.21, tone(shift * 2.5, 0.2, 1));
    for (var band = 0; band < 7; band++) {
      final progress = band / 6;
      ridge(
        floor: horizon + height * 0.44 * progress * progress + height * 0.02,
        swell: height * (0.006 + 0.012 * progress),
        waves: 5 + next() * 3,
        phase: next() * 6,
        color: tone(-shift * progress * 0.7, 0.62 + 0.14 * progress, 0.64 - 0.46 * progress),
      );
    }
  }

  void arches() {
    sky([tone(shift * 2, 0.32, 0.97), tone(shift * 1.4, 0.42, 0.92)]);
    final center = width * 0.5, base = height * 1.02;
    final bands = [
      tone(-shift * 1.5, 0.66, 0.34),
      tone(-shift * 0.6, 0.72, 0.6),
      tone(shift * 0.4, 0.68, 0.84),
      tone(shift * 1.6, 0.46, 0.96),
      tone(-shift, 0.7, 0.46),
      tone(0, 0.7, 0.26),
    ];
    for (final (index, color) in bands.indexed) {
      final radius = width * (0.62 - 0.1 * index);
      final top = height * 0.74;
      final path = Path()
        ..moveTo(center - radius, base)
        ..lineTo(center - radius, top)
        ..arcTo(Rect.fromCircle(center: Offset(center, top), radius: radius), math.pi, math.pi, false)
        ..lineTo(center + radius, base)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  void orbit() {
    sky([tone(-shift, 0.7, 0.14), tone(0, 0.72, 0.3), tone(shift, 0.68, 0.46)]);
    stars(count: 70, limit: 1, color: tone(shift * 2, 0.12, 1));
    final center = Offset(width * (0.44 + next() * 0.14), height * 0.58), radius = width * 0.3;
    final ringColor = tone(shift * 2.4, 0.3, 0.98);
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(-0.36);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: radius * 3.5, height: radius * 0.84),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 0.02
        ..color = ringColor.withValues(alpha: 0.75),
    );
    canvas.restore();
    final planet = Rect.fromCircle(center: center, radius: radius);
    canvas.drawOval(
      planet,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tone(shift * 2, 0.42, 1), tone(0, 0.74, 0.74), tone(-shift, 0.8, 0.36)],
        ).createShader(planet),
    );
    final transform = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..rotateZ(-0.36)
      ..scaleByDouble(radius * 1.75, radius * 0.42, 1, 1);
    final front = (Path()..addArc(Rect.fromCircle(center: Offset.zero, radius: 1), 0, math.pi)).transform(transform.storage);
    canvas.drawPath(
      front,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width * 0.02
        ..color = ringColor,
    );
    disc(Offset(width * 0.8, height * 0.34), width * 0.04, tone(shift * 2.6, 0.18, 1));
  }

  void clouds() {
    sky([tone(0, 0.56, 0.5), tone(shift, 0.5, 0.78), tone(shift * 1.8, 0.3, 0.98)]);
    disc(Offset(width * (0.28 + next() * 0.44), height * 0.46), width * 0.17, tone(shift * 2.6, 0.24, 1));
    for (var layer = 0; layer < 4; layer++) {
      final floor = height * (0.56 + layer * 0.12);
      final color = tone(shift * (1.6 - layer * 0.7), 0.2 + layer * 0.12, 0.98 - layer * 0.12);
      final path = Path()..addRect(Rect.fromLTWH(0, floor, width, height - floor));
      var x = -width * 0.08 - next() * width * 0.1;
      while (x < width * 1.1) {
        final radius = width * (0.09 + next() * 0.09);
        path.addOval(Rect.fromLTWH(x - radius, floor - radius * (0.7 + next() * 0.5), radius * 2, radius * 2));
        x += radius * 1.25;
      }
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  void forest() {
    sky([tone(0, 0.56, 0.3), tone(shift, 0.5, 0.66), tone(shift * 1.9, 0.3, 0.98)]);
    disc(Offset(width * (0.3 + next() * 0.4), height * 0.44), width * 0.16, tone(shift * 2.6, 0.2, 1));
    for (var layer = 0; layer < 3; layer++) {
      final floor = height * (0.62 + layer * 0.13), tree = height * (0.15 + layer * 0.05);
      final paint = Paint()..color = tone(-shift * layer * 0.7, 0.58, 0.48 - layer * 0.15);
      var x = -width * 0.05;
      while (x < width * 1.05) {
        final tall = tree * (0.72 + next() * 0.5), wide = tall * 0.36;
        for (var tier = 0; tier < 3; tier++) {
          final top = floor - tall + tall * tier * 0.26, bottom = top + tall * 0.5, half = wide * (0.6 + tier * 0.26);
          canvas.drawPath(
            Path()
              ..moveTo(x, top)
              ..lineTo(x + half, bottom)
              ..lineTo(x - half, bottom)
              ..close(),
            paint,
          );
        }
        x += wide * (0.9 + next() * 0.8);
      }
      canvas.drawRect(Rect.fromLTWH(0, floor - tree * 0.12, width, height - floor + tree * 0.12), paint);
    }
  }

  void city() {
    sky([tone(-shift, 0.72, 0.2), tone(0, 0.74, 0.5), tone(shift * 1.6, 0.62, 0.98)]);
    disc(Offset(width * (0.3 + next() * 0.4), height * 0.46), width * 0.18, tone(shift * 2.4, 0.32, 1));
    for (var layer = 0; layer < 3; layer++) {
      final paint = Paint()..color = tone(-shift * (layer + 0.5), 0.62, 0.44 - layer * 0.14);
      final ground = height * (0.68 + layer * 0.09);
      var x = -width * 0.02;
      while (x < width) {
        final wide = width * (0.09 + next() * 0.09), tall = height * (0.12 + next() * 0.16);
        canvas.drawRect(Rect.fromLTWH(x, ground - tall, wide, height), paint);
        if (layer == 2) {
          final cell = width * 0.018;
          final window = Paint()..color = tone(shift * 2.4, 0.42, 1).withValues(alpha: 0.9);
          for (var row = 0; row < (tall / (cell * 2.4)).floor(); row++) {
            for (var column = 0; column < math.max(1, (wide / (cell * 2.2)).floor()); column++) {
              if (next() > 0.55) {
                canvas.drawRect(Rect.fromLTWH(x + cell * 0.8 + column * cell * 2.2, ground - tall + cell + row * cell * 2.4, cell, cell * 1.3), window);
              }
            }
          }
        }
        x += wide + width * 0.004;
      }
    }
  }

  void aurora() {
    sky([tone(-shift, 0.7, 0.12), tone(0, 0.7, 0.24), tone(shift * 0.6, 0.62, 0.38)]);
    stars(count: 60, limit: 0.7, color: tone(shift * 2, 0.1, 1));
    for (var ribbon = 0; ribbon < 5; ribbon++) {
      final base = height * (0.34 + ribbon * 0.06),
          swell = height * 0.07,
          waves = 0.9 + next() * 0.8,
          phase = next() * 6,
          length = height * (0.22 + next() * 0.1);
      final path = Path()..moveTo(0, base + math.sin(phase) * swell);
      for (var step = 1; step <= 120; step++) {
        final x = width * step / 120;
        path.lineTo(x, base + math.sin(x / width * math.pi * 2 * waves + phase) * swell);
      }
      path
        ..lineTo(width, height)
        ..lineTo(0, height)
        ..close();
      final color = tone(shift * ribbon * 0.8 + 0.25, 0.62, 1);
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.42), color.withValues(alpha: 0)],
          ).createShader(Rect.fromLTRB(0, base - swell, width, base + length)),
      );
    }
    ridge(floor: height * 0.76, swell: height * 0.04, waves: 1.3 + next(), phase: next() * 6, color: tone(-shift, 0.6, 0.26));
    ridge(floor: height * 0.86, swell: height * 0.024, waves: 1.8 + next(), phase: next() * 6, color: tone(-shift * 1.5, 0.66, 0.14));
  }
}
