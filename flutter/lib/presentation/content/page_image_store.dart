import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import '../../core/content/manga_urls.dart';
import '../../core/storage/thumbnail_disk_cache.dart';
import 'reader_models.dart';
import '../../core/support/perf_trace.dart';

/// Limits CPU-heavy decoding across every reader and feed store (`PageImageDecodeQueue`).
class PageImageDecodeQueue {
  PageImageDecodeQueue({int limit = 2}) : limit = math.max(1, limit);
  static final shared = PageImageDecodeQueue();

  final int limit;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> perform<T>(Future<T> Function() operation) async {
    if (_active >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _active += 1;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active -= 1;
      }
    }
  }
}

/// One consumer of a shared image request. Cancelling leaves the others; the last one
/// to leave abandons the request, as cancelling the native task does.
class PageImageRequest {
  PageImageRequest._(this.image, this._cancel);
  final Future<ui.Image> image;
  final void Function() _cancel;
  void cancel() => _cancel();
}

class _Flight {
  _Flight(this.id);
  final Object id;
  final waiters = <Object>{};
  final completer = Completer<ui.Image>();
}

/// Decoded page and cover images, bounded in memory and on disk, shared between
/// concurrent requests for the same page. Thumbnails decode to at most 480 px on
/// the long side and pages to 3000 px, as in the native store.
class PageImageStore {
  PageImageStore({
    required this.source,
    this.countLimit = 128,
    this.byteLimit = 192 * 1024 * 1024,
    Directory? diskDirectory,
    int diskCapacity = 512 * 1024 * 1024,
    bool Function()? allowsPrefetch,
  }) : allowsPrefetch = allowsPrefetch ?? (() => true),
       _disk = _makeDisk(diskDirectory, diskCapacity);

  /// The persistent page cache directory, installed at launch (`Caches/MangaPageCache`).
  static Directory? defaultDiskDirectory;

  /// Tests and the offline fixture never share bytes on disk: synthetic hashes repeat.
  static bool get isTesting => ContentPreferences.isIsolated || Platform.environment.containsKey('FLUTTER_TEST');

  static ThumbnailDiskCache? _makeDisk(Directory? directory, int capacity) {
    final target = directory ?? (isTesting ? null : defaultDiskDirectory);
    if (capacity <= 0 || target == null) return null;
    return ThumbnailDiskCache(directory: target, capacity: capacity, fileExtension: 'page');
  }

  final ContentProviding source;
  final int countLimit;
  final int byteLimit;

  /// False under the device's low-power or thermal pressure; speculation then stops.
  final bool Function() allowsPrefetch;
  final ThumbnailDiskCache? _disk;

  /// Completes once downloaded pages started so far are on disk (for tests and relaunch).
  Future<void> get idle => _disk?.idle ?? Future.value();
  final _cache = <String, ui.Image>{};
  final _flights = <String, _Flight>{};
  int _bytes = 0;

  bool get canPrefetch => allowsPrefetch();

  static String _key(String hash, bool thumbnail) => '$hash:$thumbnail';

  ui.Image? cachedImage(String hash, {bool thumbnail = false}) {
    final key = _key(hash, thumbnail);
    final image = _cache.remove(key);
    if (image != null) _cache[key] = image;
    return image;
  }

  Future<ui.Image> load(GalleryPage page, {required int galleryID, bool thumbnail = false}) => request(page, galleryID: galleryID, thumbnail: thumbnail).image;

  /// A cancellable [load]. Requests for the same page share one download and decode.
  PageImageRequest request(GalleryPage page, {required int galleryID, bool thumbnail = false}) {
    final key = _key(page.hash, thumbnail);
    final cached = cachedImage(page.hash, thumbnail: thumbnail);
    if (cached != null) return PageImageRequest._(Future.value(cached), () {});
    final waiter = Object();
    final flight = _flights.putIfAbsent(key, () {
      final created = _Flight(Object());
      unawaited(_run(key, created, page, galleryID: galleryID, thumbnail: thumbnail));
      return created;
    });
    flight.waiters.add(waiter);
    final result = Completer<ui.Image>();
    var finished = false;
    flight.completer.future.then(
      (image) {
        if (!finished) {
          finished = true;
          result.complete(image);
        }
        _release(key, flight, waiter);
      },
      onError: (Object error, StackTrace stack) {
        if (!finished) {
          finished = true;
          result.completeError(error, stack);
        }
        _release(key, flight, waiter);
      },
    );
    return PageImageRequest._(result.future, () {
      if (finished) return;
      finished = true;
      result.completeError(const CancellationError());
      _release(key, flight, waiter);
    });
  }

  Future<void> _run(String key, _Flight flight, GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    try {
      final limit = thumbnail ? 480 : 3000;
      final cachedData = await _disk?.readAsync(key);
      ui.Image? restored;
      if (cachedData != null) {
        try {
          restored = await PageImageDecodeQueue.shared.perform(() => decode(cachedData, maxPixelSize: limit));
        } on Object {
          restored = null;
        }
      }
      final ui.Image image;
      if (restored != null) {
        image = restored;
      } else {
        final data = await source.image(page, galleryID: galleryID, thumbnail: thumbnail);
        if (!identical(_flights[key], flight)) throw const CancellationError();
        image = await PageImageDecodeQueue.shared.perform(() => decode(data, maxPixelSize: limit));
        if (identical(_flights[key], flight)) _disk?.write(data, key);
      }
      // Persist once per shared request, however many consumers await it.
      if (identical(_flights[key], flight)) _store(key, image);
      flight.completer.complete(image);
    } on Object catch (error, stack) {
      flight.completer.completeError(error, stack);
    }
  }

  void _release(String key, _Flight flight, Object waiter) {
    if (!flight.waiters.remove(waiter)) return;
    if (flight.waiters.isEmpty && identical(_flights[key], flight)) _flights.remove(key);
  }

  /// How many consumers share the request for a page (for tests).
  int consumerCount(String hash, {bool thumbnail = false}) => _flights[_key(hash, thumbnail)]?.waiters.length ?? 0;

  /// The encoded bytes of a page, from the disk cache or the source, as kept for a saved cover.
  Future<Uint8List> data(GalleryPage page, {required int galleryID, bool thumbnail = false}) async {
    final key = _key(page.hash, thumbnail);
    final cached = await _disk?.readAsync(key);
    if (cached != null) return cached;
    final data = await source.image(page, galleryID: galleryID, thumbnail: thumbnail);
    _disk?.write(data, key);
    return data;
  }

  void _store(String key, ui.Image image) {
    final old = _cache.remove(key);
    if (old != null) _bytes -= old.width * old.height * 4;
    _cache[key] = image;
    _bytes += image.width * image.height * 4;
    while (_cache.length > countLimit || _bytes > byteLimit && _cache.length > 1) {
      final oldest = _cache.keys.first;
      final removed = _cache.remove(oldest)!;
      _bytes -= removed.width * removed.height * 4;
    }
  }

  /// Current and adjacent/next pages are speculatively loaded, three at a time.
  Future<void> prefetch(NativeGallery gallery, {required int current, required int count, int visibleCount = 1}) async {
    if (!allowsPrefetch()) return;
    final queue = Queue.of(prefetchIndices(total: gallery.pages.length, current: current, count: count, visibleCount: visibleCount));
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final index = queue.removeFirst();
        try {
          await load(gallery.pages[index], galleryID: gallery.id);
        } on Object {
          // Speculation never reports failures; the visible page retries on its own.
        }
      }
    }

    await Future.wait([for (var slot = 0; slot < 3; slot++) worker()]);
  }

  /// The current page, the pages after the visible spread, then the page before.
  static List<int> prefetchIndices({required int total, required int current, required int count, int visibleCount = 1}) {
    if (current < 0 || current >= total || count <= 0) return [];
    final int start = current + math.min(ReaderLayout.count(visibleCount), total - current);
    final int end = start + math.min(count, total - start);
    return [current, for (var index = start; index < end; index++) index, if (current > 0) current - 1];
  }

  /// Decodes no larger than `maxPixelSize` on the longer side, keeping the aspect ratio.
  static Future<ui.Image> decode(Uint8List data, {required int maxPixelSize}) =>
      PerfTrace.span('page decode', () => _decode(data, maxPixelSize: maxPixelSize), detail: '${data.length ~/ 1024}KB max $maxPixelSize');

  static Future<ui.Image> _decode(Uint8List data, {required int maxPixelSize}) async {
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

/// The reader shows a cached cover-size preview at once and upgrades it to the full page.
class ReaderPageImage {
  const ReaderPageImage({required this.hash, required this.image, required this.fullResolution});
  final String hash;
  final ui.Image image;
  final bool fullResolution;

  static ReaderPageImage? cached(String hash, PageImageStore images) {
    final full = images.cachedImage(hash);
    if (full != null) return ReaderPageImage(hash: hash, image: full, fullResolution: true);
    final thumbnail = images.cachedImage(hash, thumbnail: true);
    if (thumbnail != null) return ReaderPageImage(hash: hash, image: thumbnail, fullResolution: false);
    return null;
  }

  bool satisfies(String hash) => this.hash == hash && fullResolution;
}

/// The reader owns a rolling window rather than cancelling everything on each turn.
/// Downloads shared by the old and new windows survive the handoff (`ReaderPagePrefetcher`).
class ReaderPagePrefetcher {
  final _jobs = <int, (Object, PageImageRequest)>{};
  final _finished = <int>{};
  List<int> _window = [];
  List<int> _visible = [];
  NativeGallery? _gallery;
  PageImageStore? _images;
  Object _generation = Object();
  static const _limit = 3;

  void update({required NativeGallery gallery, required PageImageStore images, required int current, required int count, int visibleCount = 1}) {
    if (count <= 0 || current < 0 || current >= gallery.pages.length) return cancel();
    if (_gallery?.id != gallery.id || !identical(_images, images)) cancel();
    _gallery = gallery;
    _images = images;
    _visible = [for (var index = current; index < math.min(gallery.pages.length, current + ReaderLayout.count(visibleCount)); index++) index];
    _window = [
      ..._visible,
      ...PageImageStore.prefetchIndices(
        total: gallery.pages.length,
        current: current,
        count: count,
        visibleCount: visibleCount,
      ).where((index) => !_visible.contains(index)),
    ];
    final wanted = _window.toSet();
    for (final index in _jobs.keys.where((index) => !wanted.contains(index)).toList()) {
      _jobs.remove(index)!.$2.cancel();
    }
    _finished.retainAll(wanted);
    // A visible page evicted under memory pressure can be requested again.
    for (final index in _visible) {
      if (images.cachedImage(gallery.pages[index].hash) == null) _finished.remove(index);
    }
    _fill();
  }

  void cancel() {
    _generation = Object();
    for (final job in _jobs.values) {
      job.$2.cancel();
    }
    _jobs.clear();
    _finished.clear();
    _window = [];
    _visible = [];
    _gallery = null;
    _images = null;
  }

  /// Pages being loaded now (for tests).
  Set<int> get activeIndices => _jobs.keys.toSet();

  void _fill() {
    final gallery = _gallery, images = _images;
    if (gallery == null || images == null) return;
    bool cached(int index) => images.cachedImage(gallery.pages[index].hash) != null;
    for (final index in _visible) {
      if (!_jobs.containsKey(index) && !_finished.contains(index) && !cached(index)) _start(index, gallery, images);
    }
    // Give every page in the visible spread the network and decode slots first.
    if (!_visible.every(cached)) return;
    for (final index in _window) {
      if (_visible.contains(index) || _jobs.length >= _limit) continue;
      if (_jobs.containsKey(index) || _finished.contains(index) || cached(index)) continue;
      _start(index, gallery, images);
    }
  }

  void _start(int index, NativeGallery gallery, PageImageStore images) {
    final id = Object(), token = _generation;
    final request = images.request(gallery.pages[index], galleryID: gallery.id);
    _jobs[index] = (id, request);
    request.image.then(
      (_) => _complete(index, id, token),
      onError: (Object error) {
        if (error is! CancellationError) _complete(index, id, token);
      },
    );
  }

  void _complete(int index, Object id, Object token) {
    if (!identical(_generation, token) || !identical(_jobs[index]?.$1, id)) return;
    _jobs.remove(index);
    _finished.add(index);
    _fill();
  }
}
