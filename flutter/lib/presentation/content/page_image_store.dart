import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';

/// Decoded page and cover images, bounded in memory and shared between
/// concurrent requests for the same page. Thumbnails decode to at most 480 px
/// on the long side and pages to 3000 px, as in the native store.
class PageImageStore {
  PageImageStore({required this.source, this.countLimit = 128, this.byteLimit = 192 * 1024 * 1024});

  final ContentProviding source;
  final int countLimit;
  final int byteLimit;
  final _cache = <String, ui.Image>{};
  final _flights = <String, Future<ui.Image>>{};
  int _bytes = 0;

  static String _key(String hash, bool thumbnail) => '$hash:$thumbnail';

  ui.Image? cachedImage(String hash, {bool thumbnail = false}) {
    final key = _key(hash, thumbnail);
    final image = _cache.remove(key);
    if (image != null) _cache[key] = image;
    return image;
  }

  Future<ui.Image> load(GalleryPage page, {required int galleryID, bool thumbnail = false}) {
    final key = _key(page.hash, thumbnail);
    final cached = cachedImage(page.hash, thumbnail: thumbnail);
    if (cached != null) return Future.value(cached);
    return _flights.putIfAbsent(key, () async {
      try {
        final data = await source.image(page, galleryID: galleryID, thumbnail: thumbnail);
        final image = await decode(data, maxPixelSize: thumbnail ? 480 : 3000);
        _store(key, image);
        return image;
      } finally {
        unawaited(_flights.remove(key));
      }
    });
  }

  void _store(String key, ui.Image image) {
    _cache.remove(key);
    _cache[key] = image;
    _bytes += image.width * image.height * 4;
    while (_cache.length > countLimit || _bytes > byteLimit && _cache.length > 1) {
      final oldest = _cache.keys.first;
      final removed = _cache.remove(oldest)!;
      _bytes -= removed.width * removed.height * 4;
    }
  }

  /// Decodes no larger than `maxPixelSize` on the longer side, keeping the aspect ratio.
  static Future<ui.Image> decode(Uint8List data, {required int maxPixelSize}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(data);
    ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } on Object {
      buffer.dispose();
      throw ContentError.unsupportedFormat;
    }
    final longest = math.max(descriptor.width, descriptor.height);
    final scale = longest > maxPixelSize ? maxPixelSize / longest : 1.0;
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, descriptor.width),
      targetHeight: (descriptor.height * scale).round().clamp(1, descriptor.height),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
