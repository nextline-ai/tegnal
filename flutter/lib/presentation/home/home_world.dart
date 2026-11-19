import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'home_travel.dart';

enum HomeSide { free, leading, trailing }

/// One drawing standing somewhere in the world the camera travels through.
class HomeSprite {
  const HomeSprite(
    this.art, {
    required this.at,
    this.x = 0.5,
    this.width = 1,
    this.side = HomeSide.free,
    this.spans = false,
    this.mirrored = false,
    this.opacity = 1,
  });

  final String art;

  /// The camera's place, in screen heights from the home scene, at which the drawing is level with the middle of the screen.
  final double at;

  /// Its middle across the screen, from 0 to 1. A drawing on a side hugs that edge instead.
  final double x;

  /// Its width, as a share of a phone's width. A drawing that spans is measured against the screen's width.
  final double width;
  final HomeSide side;
  final bool spans;
  final bool mirrored;
  final double opacity;
}

/// Drawings at one distance. A plane nearer than 1 passes faster than the camera, a farther one slower.
class HomePlane {
  const HomePlane(this.depth, this.sprites);
  final double depth;
  final List<HomeSprite> sprites;
}

abstract final class HomeWorld {
  static List<HomePlane> planes(HomeRealm realm) => realm == HomeRealm.library ? _underground : _sky;

  /// The drawing the world ends in: the cave's roof, or the top of the clouds.
  static String edge(HomeRealm realm) => realm == HomeRealm.library ? 'HomeCeiling' : 'HomeCloudBank';

  /// The share of that drawing's height, from its top, that lies on the world's last line.
  static double edgeLine(HomeRealm realm) => realm == HomeRealm.library ? 0.2 : 0.7;

  /// The colours behind everything, from the home scene to the world's end.
  static (List<Color>, List<double>) backdrop(HomeRealm realm) => realm == HomeRealm.library
      ? (const [Color(0xFF1E1430), Color(0xFF1A112C), Color(0xFF150D26), Color(0xFF120B21), Color(0xFF0D0716)], const [0, 0.2, 0.45, 0.7, 1])
      : (
          const [Color(0xFF0B0717), Color(0xFF100B2A), Color(0xFF1C1354), Color(0xFF33248C), Color(0xFF5B45C4), Color(0xFF8F78EA)],
          const [0, 0.18, 0.42, 0.64, 0.84, 1],
        );

  /// What lies just past the end, thinning out over the place: the cave's shade, or mist off the clouds.
  static List<Color> veil(HomeRealm realm) => realm == HomeRealm.library
      ? const [Color(0xDB0D0716), Color(0x800D0716), Color(0x000D0716)]
      : const [Color(0xBFF4EEFF), Color(0x59E2D6FF), Color(0x00E2D6FF)];

  static const _underground = [
    HomePlane(0.45, [
      HomeSprite('HomeStrataA', at: 0.9, width: 1.5, spans: true, mirrored: true, opacity: 0.4),
      HomeSprite('HomeGems', at: 1.3, x: 0.35, width: 1.1, opacity: 0.8),
      HomeSprite('HomeLantern', at: 1.5, x: 0.78, width: 0.3, opacity: 0.5),
      HomeSprite('HomeStrataB', at: 2.1, width: 1.5, spans: true, opacity: 0.35),
      HomeSprite('HomeGems', at: 2.5, x: 0.6, width: 1.1, mirrored: true, opacity: 0.8),
    ]),
    HomePlane(0.75, [
      HomeSprite('HomeCrystals', at: 0.95, width: 0.52, side: HomeSide.leading),
      HomeSprite('HomeLantern', at: 1.3, x: 0.72, width: 0.44, opacity: 0.9),
      HomeSprite('HomeCrystals', at: 1.75, width: 0.5, side: HomeSide.trailing, mirrored: true),
      HomeSprite('HomeMushrooms', at: 2.3, x: 0.3, width: 0.34),
    ]),
    HomePlane(1, [
      HomeSprite('HomeStrataA', at: 0.6, spans: true),
      HomeSprite('HomeGems', at: 0.97, width: 1),
      HomeSprite('HomeRelicFrame', at: 0.98, x: 0.7, width: 0.3),
      HomeSprite('HomeStrataB', at: 1.34, spans: true),
      HomeSprite('HomeGems', at: 1.68, width: 1, mirrored: true),
      HomeSprite('HomeRelicBooks', at: 1.7, x: 0.3, width: 0.3),
      HomeSprite('HomeStrataA', at: 2.06, spans: true, mirrored: true),
      HomeSprite('HomeGems', at: 2.42, width: 1),
    ]),
    HomePlane(1.35, [
      HomeSprite('HomeRockSide', at: 1.15, width: 0.4, side: HomeSide.leading),
      HomeSprite('HomeRockSide', at: 1.85, width: 0.4, side: HomeSide.trailing, mirrored: true),
      HomeSprite('HomeCrystals', at: 2.25, width: 0.56, side: HomeSide.leading),
    ]),
    HomePlane(1.8, [HomeSprite('HomeRockSide', at: 2.05, width: 0.44, side: HomeSide.trailing, mirrored: true)]),
  ];

  static const _sky = [
    HomePlane(0.45, [
      HomeSprite('HomeStarfield', at: 0.5, x: 0.4, width: 1.3, opacity: 0.8),
      HomeSprite('HomeStarfield', at: 1.2, x: 0.6, width: 1.3, mirrored: true, opacity: 0.75),
      HomeSprite('HomeCloudC', at: 1.9, x: 0.7, width: 0.8, opacity: 0.45),
      HomeSprite('HomeStarfield', at: 2.1, x: 0.45, width: 1.3, opacity: 0.7),
      HomeSprite('HomeCloudB', at: 2.6, x: 0.25, width: 0.7, opacity: 0.5),
    ]),
    HomePlane(0.75, [
      HomeSprite('HomeCloudB', at: 0.5, x: 0.84, width: 0.62, opacity: 0.55),
      HomeSprite('HomeShootingStar', at: 0.75, x: 0.62, width: 0.5),
      HomeSprite('HomeCloudA', at: 1.1, x: 0.14, width: 0.9, opacity: 0.85),
      HomeSprite('HomeMoon', at: 1.45, x: 0.74, width: 0.6),
      HomeSprite('HomeCloudB', at: 1.95, x: 0.82, width: 0.74, opacity: 0.9),
      HomeSprite('HomeCloudC', at: 2.4, x: 0.24, width: 0.86, opacity: 0.9),
    ]),
    HomePlane(1, [
      HomeSprite('HomeStarfield', at: 0.45, width: 1),
      HomeSprite('HomeConstellation', at: 0.92, x: 0.36, width: 0.56),
      HomeSprite('HomeStarfield', at: 1.1, width: 1, mirrored: true),
      HomeSprite('HomeStarfield', at: 1.75, width: 1, opacity: 0.9),
      HomeSprite('HomeSparkle', at: 2.02, x: 0.3, width: 0.34),
      HomeSprite('HomeStarfield', at: 2.36, width: 1, mirrored: true, opacity: 0.9),
    ]),
    HomePlane(1.35, [HomeSprite('HomeCloudA', at: 1.45, x: 0.86, width: 1.05, mirrored: true), HomeSprite('HomeCloudC', at: 2.0, x: 0.1, width: 1.1)]),
    HomePlane(1.8, [HomeSprite('HomeCloudB', at: 2.1, x: 0.8, width: 1.3)]),
  ];
}

/// The drawings, decoded once from `assets/home/art` and kept while the scene may still be needed.
abstract final class HomeArt {
  /// Each drawing's size in its file, so that every rect is known before the pictures are decoded.
  static const sizes = <String, Size>{
    'HomeCeiling': Size(1170, 615),
    'HomeCloudA': Size(940, 297),
    'HomeCloudB': Size(1100, 330),
    'HomeCloudBank': Size(1170, 665),
    'HomeCloudC': Size(990, 292),
    'HomeConstellation': Size(500, 375),
    'HomeCrystals': Size(500, 625),
    'HomeGems': Size(900, 900),
    'HomeGroundEdge': Size(900, 743),
    'HomeLantern': Size(400, 550),
    'HomeMoon': Size(540, 540),
    'HomeMushrooms': Size(310, 219),
    'HomeRelicBooks': Size(270, 216),
    'HomeRelicFrame': Size(270, 234),
    'HomeRockSide': Size(400, 1382),
    'HomeShootingStar': Size(450, 191),
    'HomeSparkle': Size(310, 310),
    'HomeStarfield': Size(900, 900),
    'HomeStrataA': Size(900, 608),
    'HomeStrataB': Size(900, 608),
  };

  static String path(String art) => 'assets/home/art/$art.webp';

  static final Map<String, ui.Image> _images = {};
  static Future<void>? _loading;

  /// Fires as the pictures arrive, so that a journey begun early draws them once they are ready.
  static final loaded = ChangeNotifierHandle();

  static ui.Image? image(String art) => _images[art];
  static bool get ready => _images.length == sizes.length;

  /// Decodes every drawing, in the background, once. Calling it again while it runs, or after, costs nothing.
  static Future<void> load() => _loading ??= _load().whenComplete(() => _loading = null);

  static Future<void> _load() async {
    for (final art in sizes.keys) {
      if (_images.containsKey(art)) continue;
      try {
        final data = await rootBundle.load(path(art));
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        final frame = await codec.getNextFrame();
        codec.dispose();
        _images[art] = frame.image;
        loaded.notify();
      } on Object {
        // A drawing that cannot be read is simply left out of the world.
      }
    }
  }

  /// Away from the scene, its pictures are only needed again on the way back; under memory pressure they are let go.
  static void shed() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    loaded.notify();
  }

  /// The width that sizes everything that is not laid across the whole screen: a phone's width, or less on a wide screen.
  static double unit(Size size) => math.min(size.width, size.height * 0.46);

  /// The world's edge is drawn at a phone's scale and laid side by side across a wider screen, rather than
  /// stretched over it: stretched, a tablet's cave roof hung halfway down the screen.
  static double edgeTile(Size size) {
    final count = math.max(1.0, (size.width / unit(size)).roundToDouble());
    return size.width / count;
  }

  static double spriteWidth(HomeSprite sprite, Size size) => sprite.spans ? size.width * sprite.width : unit(size) * sprite.width;

  static double tall(String art, double width) {
    final source = sizes[art]!;
    return width * source.height / source.width;
  }
}

/// A [Listenable] anyone can poke.
class ChangeNotifierHandle extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// One drawing placed in the world: its rect before the camera moves, how much it fades, and whether it is turned round.
class HomePiece {
  const HomePiece(this.art, this.rect, {this.opacity = 1, this.mirrored = false});
  final String art;
  final Rect rect;
  final double opacity;
  final bool mirrored;
}

/// Every rect of one journey on a screen of one size, as `HomeRealmLayers` lays out its layers.
///
/// Everything between the home scene and the world's end lives in the world, which is cut off
/// along that end, so that slow, far-off drawings never trail out over the place beyond it. The
/// end itself, with what hangs past it, is the edge. Both move with the camera; the planes inside
/// the world move a little more or less, by their distance.
class HomeRealmLayout {
  HomeRealmLayout(this.realm, this.size) {
    final direction = realm.direction, height = size.height, width = size.width;
    final length = height * HomeTravel.depth;
    // Where the world begins on screen before the camera has moved: under the picture, or over it.
    final top = realm == HomeRealm.library ? height : -length;
    line = realm == HomeRealm.library ? height + length : -length;
    world = Rect.fromLTWH(0, top, width, length);
    final (colors, stops) = HomeWorld.backdrop(realm);
    // The colours run outward from the home scene: downward under the ground, upward in the sky.
    backdrop = Paint()
      ..shader = ui.Gradient.linear(
        realm == HomeRealm.library ? world.topCenter : world.bottomCenter,
        realm == HomeRealm.library ? world.bottomCenter : world.topCenter,
        colors,
        stops,
      );
    for (final plane in HomeWorld.planes(realm)) {
      final pieces = <HomePiece>[];
      for (final sprite in plane.sprites) {
        final pieceWidth = HomeArt.spriteWidth(sprite, size), tall = HomeArt.tall(sprite.art, pieceWidth);
        final x = switch (sprite.side) {
          HomeSide.free => width * sprite.x,
          HomeSide.leading => pieceWidth / 2 - pieceWidth * 0.1,
          HomeSide.trailing => width - pieceWidth / 2 + pieceWidth * 0.1,
        };
        // Before the camera moves; a plane then moves `slide * depth` in all.
        final y = height / 2 + direction * sprite.at * plane.depth * height;
        pieces.add(
          HomePiece(
            sprite.art,
            Rect.fromCenter(center: Offset(x, y), width: pieceWidth, height: tall),
            opacity: sprite.opacity,
            mirrored: sprite.mirrored,
          ),
        );
      }
      planes.add((plane.depth, pieces));
    }

    // The shade under the roof, or the mist over the clouds, reaches out over the place.
    final reach = height * HomeTravel.overhang;
    veilRect = realm == HomeRealm.library ? Rect.fromLTWH(0, line - 2, width, reach) : Rect.fromLTWH(0, line + 2 - reach, width, reach);
    veil = Paint()
      ..shader = ui.Gradient.linear(
        realm == HomeRealm.library ? veilRect.topCenter : veilRect.bottomCenter,
        realm == HomeRealm.library ? veilRect.bottomCenter : veilRect.topCenter,
        HomeWorld.veil(realm),
        const [0, 0.4, 1],
      );
    if (realm == HomeRealm.library) {
      // Two lanterns hang from the roof on their chains, the last things passed.
      final lanternWidth = HomeArt.unit(size) * 0.4, tall = HomeArt.tall('HomeLantern', lanternWidth);
      for (final (x, scale) in const [(0.2, 1.0), (0.83, 0.78)]) {
        edge.add(HomePiece('HomeLantern', Rect.fromLTWH(width * x - lanternWidth * scale / 2, line, lanternWidth * scale, tall * scale)));
      }
    }
    // The edge is two deep: larger copies stand a little behind the nearer ones. Each row is the same
    // drawing laid side by side, every other one turned round, so that neighbours meet edge to edge.
    final art = HomeWorld.edge(realm);
    for (final wide in const [true, false]) {
      final step = HomeArt.edgeTile(size) * (wide ? 1.3 : 1);
      final tileWidth = step + 1, tall = HomeArt.tall(art, tileWidth);
      var x = wide ? -step * 0.45 : 0.0;
      var index = wide ? 1 : 0;
      while (x < width) {
        final y = line - tall * HomeWorld.edgeLine(realm) - (wide ? height * 0.035 : 0);
        edge.add(HomePiece(art, Rect.fromLTWH(x, y, tileWidth, tall), mirrored: index.isOdd, opacity: wide && realm == HomeRealm.study ? 0.85 : 1));
        x += step;
        index += 1;
      }
    }
    // The soil and its roots hang from the foot of the picture and leave with it. It starts just under the
    // screen: not a blade of its grass shows until the picture moves.
    ground = Rect.fromLTWH(0, height - 1, width, HomeArt.tall('HomeGroundEdge', width));
  }

  final HomeRealm realm;
  final Size size;

  /// The world's last line on screen, before the camera moves.
  late final double line;
  late final Rect world;
  late final Paint backdrop;
  final planes = <(double, List<HomePiece>)>[];
  late final Rect veilRect;
  late final Paint veil;

  /// The lanterns, then the far row of the edge, then the near one.
  final edge = <HomePiece>[];
  late final Rect ground;

  /// How far the picture and the world have moved with the camera at moment `t`.
  double slide(double t) => -realm.direction * HomeTravel.camera(t) * size.height;
}

final _piecePaint = Paint()..filterQuality = FilterQuality.medium;

/// Draws one piece moved down by `dy`, if it is on screen at all.
void _drawPiece(Canvas canvas, HomePiece piece, double dy, Rect screen) {
  final image = HomeArt.image(piece.art);
  if (image == null || piece.opacity <= 0) return;
  final rect = piece.rect.shift(Offset(0, dy));
  if (!rect.overlaps(screen)) return;
  final source = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  _piecePaint.color = Color.fromRGBO(0, 0, 0, piece.opacity);
  if (piece.mirrored) {
    canvas.save();
    canvas.translate(rect.center.dx, 0);
    canvas.scale(-1, 1);
    canvas.translate(-rect.center.dx, 0);
    canvas.drawImageRect(image, source, rect, _piecePaint);
    canvas.restore();
  } else {
    canvas.drawImageRect(image, source, rect, _piecePaint);
  }
}

/// The journey's moment, the place it leads to and the screen's layouts, shared by everything that draws it.
class HomePose extends ChangeNotifier {
  double moment = 0;
  HomeRealm? realm;
  final layouts = <HomeRealm, HomeRealmLayout>{};

  HomeRealmLayout? get layout => realm == null ? null : layouts[realm];

  /// How far the picture has moved with the camera.
  double get slide => layout?.slide(moment) ?? 0;

  void set(double moment, HomeRealm? realm) {
    this.moment = moment;
    this.realm = realm;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

/// What lies behind the picture: the world's backdrop and planes, cut off at its end, then the edge.
class HomeUnderPainter extends CustomPainter {
  HomeUnderPainter(this.pose) : super(repaint: Listenable.merge([pose, HomeArt.loaded]));
  final HomePose pose;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = pose.layout;
    if (layout == null || layout.size != size) return;
    final slide = pose.slide, screen = Offset.zero & size;
    final world = layout.world.shift(Offset(0, slide));
    if (world.overlaps(screen)) {
      canvas.save();
      canvas.clipRect(world.intersect(screen));
      canvas.save();
      canvas.translate(0, slide);
      canvas.drawRect(layout.world, layout.backdrop);
      canvas.restore();
      for (final (depth, pieces) in layout.planes) {
        for (final piece in pieces) {
          _drawPiece(canvas, piece, slide * depth, screen);
        }
      }
      canvas.restore();
    }
    final veil = layout.veilRect.shift(Offset(0, slide));
    if (veil.overlaps(screen)) {
      canvas.save();
      canvas.translate(0, slide);
      canvas.drawRect(layout.veilRect, layout.veil);
      canvas.restore();
    }
    for (final piece in layout.edge) {
      _drawPiece(canvas, piece, slide, screen);
    }
  }

  @override
  bool shouldRepaint(HomeUnderPainter old) => old.pose != pose;
}

/// What lies in front of the picture: the soil hanging from its foot, under the ground, and the dust or stars drifting past.
class HomeOverPainter extends CustomPainter {
  HomeOverPainter(this.pose, this.drift) : super(repaint: Listenable.merge([pose, drift, HomeArt.loaded]));
  final HomePose pose;
  final HomeDrift drift;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = pose.layout;
    if (layout == null || layout.size != size) return;
    final screen = Offset.zero & size;
    if (layout.realm == HomeRealm.library) _drawPiece(canvas, HomePiece('HomeGroundEdge', layout.ground), pose.slide, screen);
    drift.paint(canvas, size, HomeTravel.drift(pose.moment));
  }

  @override
  bool shouldRepaint(HomeOverPainter old) => old.pose != pose || old.drift != drift;
}

/// One mote, streak or twinkle.
class _Particle {
  _Particle(this.kind, this.x, this.y, this.vx, this.vy, this.ay, this.life, this.scale, this.scaleSpeed, this.color, this.alpha, this.alphaSpeed);
  final int kind;
  double x, y;
  final double vx, vy, ay, life, scaleSpeed, alphaSpeed;
  double scale, alpha, age = 0;
  final Color color;
}

/// One kind of particle, as a Core Animation emitter cell describes it.
class _Cell {
  const _Cell({
    required this.kind,
    required this.rate,
    required this.life,
    this.lifeRange = 0,
    required this.velocity,
    this.velocityRange = 0,
    required this.longitude,
    this.longitudeRange = 0,
    this.ay = 0,
    required this.scale,
    this.scaleRange = 0,
    this.scaleSpeed = 0,
    required this.color,
    this.alphaRange = 0,
    this.alphaSpeed = 0,
  });
  final int kind;
  final double rate, life, lifeRange, velocity, velocityRange, longitude, longitudeRange, ay, scale, scaleRange, scaleSpeed, alphaRange, alphaSpeed;
  final Color color;
}

/// The dust in the cave, or the stars falling past in the sky, drawn additively in one call.
///
/// A small hand-written emitter that follows the three emitter cells of the native app: warm and
/// violet motes rising anywhere on screen in the cave, streaks and twinkles falling from above the
/// screen in the sky. On the way back everything passes the other way.
class HomeDrift extends ChangeNotifier {
  static const _dot = 0, _line = 1;

  /// Sizes of the native particle pictures in points (a 32 pt dot, a 3 × 72 pt line), which the cells' scales apply to:
  /// a twinkle is about 4 points across, a streak about 2 × 50.
  static const _dotSize = 32.0;
  static const _lineSize = Size(3, 72);

  static const _cave = [
    _Cell(
      kind: _dot,
      rate: 7,
      life: 5,
      lifeRange: 2,
      velocity: 34,
      velocityRange: 26,
      longitude: -math.pi / 2,
      longitudeRange: math.pi / 2.5,
      ay: -8,
      scale: 0.13,
      scaleRange: 0.09,
      scaleSpeed: -0.008,
      color: Color.fromRGBO(255, 214, 143, 0.9),
      alphaRange: 0.4,
      alphaSpeed: -0.16,
    ),
    _Cell(
      kind: _dot,
      rate: 5,
      life: 5,
      lifeRange: 2,
      velocity: 34,
      velocityRange: 26,
      longitude: -math.pi / 2,
      longitudeRange: math.pi / 2.5,
      ay: -8,
      scale: 0.13,
      scaleRange: 0.09,
      scaleSpeed: -0.008,
      color: Color.fromRGBO(189, 158, 255, 0.8),
      alphaRange: 0.4,
      alphaSpeed: -0.16,
    ),
  ];

  static const _sky = [
    _Cell(
      kind: _line,
      rate: 9,
      life: 2.2,
      velocity: 640,
      velocityRange: 300,
      longitude: math.pi / 2,
      scale: 0.7,
      scaleRange: 0.5,
      color: Color.fromRGBO(230, 219, 255, 0.5),
      alphaRange: 0.3,
    ),
    _Cell(
      kind: _dot,
      rate: 16,
      life: 4.5,
      velocity: 150,
      velocityRange: 90,
      longitude: math.pi / 2,
      scale: 0.12,
      scaleRange: 0.1,
      color: Color.fromRGBO(255, 255, 255, 0.9),
      alphaRange: 0.5,
      alphaSpeed: -0.12,
    ),
  ];

  final _random = math.Random(7);
  final _particles = <_Particle>[];
  final _debt = <double>[0, 0];
  HomeRealm? _realm;
  Size _size = Size.zero;
  bool _reversed = false;
  bool _emitting = false;
  static ui.Image? _dotImage, _lineImage;

  bool get running => _emitting || _particles.isNotEmpty;

  /// Starts a realm's drift as if it had already been running for three seconds, so the screen is never empty.
  void start(HomeRealm realm, Size size, {required bool reversed}) {
    _ensureImages();
    if (_realm != realm || _size != size) _particles.clear();
    _realm = realm;
    _size = size;
    _reversed = reversed;
    _emitting = true;
    if (_particles.isEmpty) {
      for (var step = 0; step < 90; step++) {
        advance(1 / 30, notify: false);
      }
    }
    notifyListeners();
  }

  /// No more particles are born; those already out finish their lives.
  void stop({bool clear = false}) {
    _emitting = false;
    if (clear) {
      _particles.clear();
      _realm = null;
    }
    notifyListeners();
  }

  List<_Cell> get _cells => _realm == HomeRealm.library ? _cave : _sky;

  double _spread(double range) => (_random.nextDouble() * 2 - 1) * range;

  void advance(double dt, {bool notify = true}) {
    if (_realm == null) return;
    final width = _size.width, height = _size.height;
    for (final particle in _particles) {
      particle.age += dt;
      particle.x += particle.vx * dt;
      particle.y += (particle.vy + particle.ay * particle.age) * dt;
      particle.scale = math.max(0, particle.scale + particle.scaleSpeed * dt);
      particle.alpha += particle.alphaSpeed * dt;
    }
    _particles.removeWhere((particle) => particle.age >= particle.life || particle.alpha <= 0 || particle.scale <= 0);
    if (_emitting) {
      final cells = _cells;
      for (var index = 0; index < cells.length; index++) {
        final cell = cells[index];
        _debt[index] += cell.rate * dt;
        while (_debt[index] >= 1) {
          _debt[index] -= 1;
          final angle = cell.longitude + _spread(cell.longitudeRange / 2);
          final speed = math.max(0.0, cell.velocity + _spread(cell.velocityRange));
          final x = _random.nextDouble() * width;
          // The cave's dust is born anywhere over a little more than the screen; the sky's from a line above it.
          final y = _realm == HomeRealm.library ? height / 2 + (_random.nextDouble() - 0.5) * height * 1.2 : -60.0;
          _particles.add(
            _Particle(
              cell.kind,
              x,
              y,
              math.cos(angle) * speed,
              math.sin(angle) * speed,
              cell.ay,
              math.max(0.2, cell.life + _spread(cell.lifeRange)),
              math.max(0.01, cell.scale + _spread(cell.scaleRange)),
              cell.scaleSpeed,
              cell.color,
              (cell.color.a + _spread(cell.alphaRange)).clamp(0.0, 1.0),
              cell.alphaSpeed,
            ),
          );
        }
      }
    }
    if (notify) notifyListeners();
  }

  void paint(Canvas canvas, Size size, double opacity) {
    final dot = _dotImage, line = _lineImage;
    if (opacity <= 0.001 || _particles.isEmpty || dot == null || line == null || size != _size) return;
    canvas.save();
    if (_reversed) {
      canvas.translate(0, size.height);
      canvas.scale(1, -1);
    }
    final paint = Paint()..blendMode = BlendMode.plus;
    for (final kind in const [_dot, _line]) {
      final image = kind == _dot ? dot : line;
      final source = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
      final transforms = <RSTransform>[], rects = <Rect>[], colors = <Color>[];
      for (final particle in _particles) {
        if (particle.kind != kind) continue;
        final scale = kind == _dot ? _dotSize * particle.scale / image.width : _lineSize.height * particle.scale / image.height;
        transforms.add(
          RSTransform.fromComponents(
            rotation: 0,
            scale: scale,
            anchorX: source.width / 2,
            anchorY: source.height / 2,
            translateX: particle.x,
            translateY: particle.y,
          ),
        );
        rects.add(source);
        colors.add(particle.color.withValues(alpha: (particle.alpha * opacity).clamp(0.0, 1.0)));
      }
      if (transforms.isEmpty) continue;
      canvas.drawAtlas(image, transforms, rects, colors, BlendMode.modulate, null, paint);
    }
    canvas.restore();
  }

  /// The soft dot and the thin streak every particle is drawn from, made once.
  static void _ensureImages() {
    if (_dotImage != null) return;
    var recorder = ui.PictureRecorder();
    var canvas = Canvas(recorder);
    const dot = 64.0;
    canvas.drawCircle(
      const Offset(dot / 2, dot / 2),
      dot / 2,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(dot / 2, dot / 2),
          dot / 2,
          const [Color(0xFFFFFFFF), Color(0x59FFFFFF), Color(0x00FFFFFF)],
          const [0, 0.35, 1],
        ),
    );
    _dotImage = recorder.endRecording().toImageSync(dot.toInt(), dot.toInt());
    recorder = ui.PictureRecorder();
    canvas = Canvas(recorder);
    const line = Size(6, 144);
    canvas.drawRect(
      Offset.zero & line,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, line.height), const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)], const [0, 0.8, 1]),
    );
    _lineImage = recorder.endRecording().toImageSync(line.width.toInt(), line.height.toInt());
  }
}
