import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../../core/booru/booru_models.dart';
import '../../../core/storage/local_thumbnail_cache.dart';
import '../../../core/taste/recap_shelf.dart';
import '../../../core/taste/taste_recap.dart';
import '../taste_context.dart';
import 'recap_style.dart';

/// `RecapArtwork`: resolves works to images once per screen. Failures stay quiet: a tile
/// without artwork falls back to the issue's own colors instead of a broken placeholder.
class RecapArtwork {
  RecapArtwork(this.taste) {
    final booru = taste.booru;
    for (final post in booru.store.visibleFavorites()) {
      final server = booru.server(post.serverID);
      if (server != null) _posts['${server.canonicalAddress}#${post.postID}'] = (post, server);
    }
  }

  final TasteContext taste;
  final _posts = <String, (BooruPost, BooruServer)>{};
  final _cache = <String, ui.Image>{};
  final _loading = <String, Future<ui.Image?>>{};

  bool get _fixture => taste.booru.fixture;

  BooruPost? post(RecapWork work) => _posts[work.id]?.$1;

  ui.Image? cached(RecapWork work, {bool large = false}) => _cache['${work.id}${large ? '+' : ''}'] ?? _cache[work.id];

  Future<ui.Image?> image(RecapWork work, {bool large = false, bool generated = false}) {
    final key = '${work.id}${large ? '+' : ''}';
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    return _loading[key] ??= _load(work, large: large, generated: generated).then((image) {
      _loading.remove(key);
      if (image != null) _cache[key] = image;
      return image;
    });
  }

  Future<ui.Image?> _load(RecapWork work, {required bool large, required bool generated}) async {
    try {
      if (generated || _fixture) return await RecapGeneratedArt.image(work.item.id);
      final entry = _posts[work.id];
      if (entry != null) {
        final (post, server) = entry;
        // Previews are small; the page's lead image can afford one sample request.
        final sample = large && !post.isVideo && !post.isAnimated ? post.sampleURL : null;
        final url = sample ?? post.previewURL ?? post.sampleURL;
        if (url == null) return null;
        final data = await taste.booru.thumbnails.load(url, server);
        return await _decode(data, width: large ? 900 : 480);
      }
      final path = work.info.thumbPath;
      if (path != null) return await LocalThumbnailCache.shared.load(path);
    } on Object {
      // A missing image falls back to the issue's colors.
    }
    return null;
  }

  static Future<ui.Image> _decode(Uint8List data, {required int width}) async {
    final codec = await ui.instantiateImageCodec(data, targetWidth: width);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// The cover's pixels as a 24 × 24 RGBA square for the palette measurement.
  Future<List<int>?> pixels(RecapWork work, {required bool generated}) async {
    final image = await this.image(work, generated: generated);
    if (image == null) return null;
    const side = 24;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      const Rect.fromLTWH(0, 0, side * 1.0, side * 1.0),
      Paint()..filterQuality = FilterQuality.low,
    );
    final scaled = await recorder.endRecording().toImage(side, side);
    final bytes = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
    scaled.dispose();
    return bytes?.buffer.asUint8List();
  }
}

/// `RecapGeneratedArt`: procedural landscapes for the sample issue, which has no library
/// to draw from, and for offline fixture runs.
abstract final class RecapGeneratedArt {
  static final _images = <int, Future<ui.Image>>{};

  static Future<ui.Image> image(int seed, {Size size = const Size(480, 640)}) => _images[seed] ??= _render(seed, size);

  static Future<ui.Image> _render(int seed, Size size) {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), size, seed);
    return recorder.endRecording().toImage(size.width.round(), size.height.round());
  }

  static void paint(Canvas canvas, Size size, int seed) {
    final random = RecapRandom(seed);
    final hue = random.next(), shift = 0.06 + random.next() * 0.14;
    Color tone(double offset, double saturation, double brightness) => RecapColor.hsb((hue + offset) % 1, saturation, brightness).color;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tone(0, 0.62, 0.34), tone(shift, 0.72, 0.82), tone(shift * 2, 0.5, 1)],
          stops: const [0, 0.62, 1],
        ).createShader(Offset.zero & size),
    );
    final sun = size.width * (0.1 + random.next() * 0.12);
    final x = size.width * (0.15 + random.next() * 0.6), y = size.height * (0.16 + random.next() * 0.3);
    canvas.drawOval(Rect.fromLTWH(x, y, sun * 2, sun * 2), Paint()..color = tone(shift * 2.6, 0.28, 1));
    for (var layer = 0; layer < 4; layer++) {
      final floor = size.height * (0.5 + layer * 0.13);
      final swell = size.height * (0.05 + random.next() * 0.09), phase = random.next() * 6, wave = 1.2 + random.next() * 2.4;
      final path = Path()..moveTo(0, size.height);
      for (var step = 0; step <= 40; step++) {
        final x = size.width * step / 40;
        path.lineTo(x, floor + math.sin(x / size.width * wave * math.pi * 2 + phase) * swell);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = tone(-shift * layer * 0.8, 0.55 + layer * 0.08, 0.62 - layer * 0.14));
    }
  }
}

/// What every recap view below a screen shares: its artwork and whether artwork may show.
class RecapScope extends InheritedWidget {
  const RecapScope({super.key, required this.artwork, required this.private, required super.child});
  final RecapArtwork artwork;

  /// Safe Mode keeps saved works off recap pages; tiles show the issue's colors instead.
  final bool private;

  static RecapScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<RecapScope>()!;

  @override
  bool updateShouldNotify(RecapScope old) => old.artwork != artwork || old.private != private;
}

/// `RecapArtTile`: one tile of a recap, its work's image or the issue's colors.
class RecapArtTile extends StatefulWidget {
  const RecapArtTile({super.key, required this.work, required this.palette, this.large = false, this.generated = false, this.seed = 3});
  final RecapWork? work;
  final RecapPalette palette;
  final bool large;
  final bool generated;
  final int seed;

  @override
  State<RecapArtTile> createState() => _RecapArtTileState();
}

class _RecapArtTileState extends State<RecapArtTile> {
  ui.Image? _image;
  String? _loadedKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(RecapArtTile old) {
    super.didUpdateWidget(old);
    if (old.work?.id != widget.work?.id || old.large != widget.large) _load();
  }

  void _load() {
    final scope = RecapScope.of(context);
    final work = widget.work;
    final key = '${work?.id}:${widget.large}:${scope.private}';
    if (key == _loadedKey) return;
    _loadedKey = key;
    _image = work == null ? null : scope.artwork.cached(work, large: widget.large);
    if (scope.private || work == null) return;
    scope.artwork.image(work, large: widget.large, generated: widget.generated).then((image) {
      if (mounted && _loadedKey == key && image != null) setState(() => _image = image);
    });
  }

  @override
  Widget build(BuildContext context) {
    final private = RecapScope.of(context).private;
    final image = _image;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: !private && image != null
          ? SizedBox.expand(
              key: ValueKey(image),
              child: RawImage(image: image, fit: BoxFit.cover),
            )
          : RecapColorField(key: const ValueKey('field'), palette: widget.palette, seed: widget.seed + (widget.work?.item.id ?? 0)),
    );
  }
}
