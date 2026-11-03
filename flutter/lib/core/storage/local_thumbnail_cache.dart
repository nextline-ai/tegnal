import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// One consumer's claim on a decode, cancelled when its cell leaves the screen.
class LocalThumbnailRequest {
  LocalThumbnailRequest._(this.image, this._cancel);

  /// The decoded cover, or null when the file is missing, unreadable or the request was cancelled.
  final Future<ui.Image?> image;
  final void Function() _cancel;

  void cancel() => _cancel();
}

class _Pending {
  _Pending(this.id, {required this.prefetched});
  final Object id;
  final waiters = <Object, Completer<ui.Image?>>{};
  bool prefetched;
  bool cancelled = false;
}

/// `LocalThumbnailCache`: saved-work covers decoded from their files off the build path,
/// two at a time, shared by every cell showing the same file, and kept in memory by count
/// and decoded size. A failed decode is not remembered, so a later load tries again.
class LocalThumbnailCache {
  LocalThumbnailCache({int maximumPixelSize = 768, this.countLimit = 128, this.costLimit = 64 * 1024 * 1024, int maxConcurrentDecodes = 2})
    : maximumPixelSize = math.max(1, maximumPixelSize),
      _slots = maxConcurrentDecodes;

  static final shared = LocalThumbnailCache();

  final int maximumPixelSize;
  final int countLimit;
  final int costLimit;

  final _cache = <String, ui.Image>{};
  int _cost = 0;
  final _pending = <String, _Pending>{};
  final _queue = Queue<(String, _Pending)>();
  int _slots;
  bool _suspended = false;
  final _invalidations = StreamController<String?>.broadcast();

  /// A path whose cover changed, or null when every cover was dropped (`didInvalidate`).
  Stream<String?> get invalidations => _invalidations.stream;

  /// A cache miss never opens a file on the caller's thread.
  ui.Image? image(String path) {
    final image = _cache.remove(path);
    if (image != null) _cache[path] = image;
    return image;
  }

  Future<ui.Image?> load(String path) => request(path).image;

  LocalThumbnailRequest request(String path) {
    final cached = image(path);
    if (cached != null) return LocalThumbnailRequest._(Future.value(cached), () {});
    final waiter = Object(), completer = Completer<ui.Image?>();
    _enqueue(path, waiter: waiter, completer: completer);
    return LocalThumbnailRequest._(completer.future, () => _cancelLoad(path, waiter));
  }

  void prefetch(Iterable<String> paths) {
    for (final path in paths.toSet()) {
      if (image(path) == null) _enqueue(path);
    }
  }

  void _enqueue(String path, {Object? waiter, Completer<ui.Image?>? completer}) {
    final existing = _pending[path];
    if (existing != null) {
      if (waiter != null && completer != null) {
        existing.waiters[waiter] = completer;
      } else {
        existing.prefetched = true;
      }
      return;
    }
    final request = _Pending(Object(), prefetched: waiter == null);
    if (waiter != null && completer != null) request.waiters[waiter] = completer;
    _pending[path] = request;
    _queue.add((path, request));
    _drain();
  }

  void _drain() {
    while (!_suspended && _slots > 0 && _queue.isNotEmpty) {
      final (path, request) = _queue.removeFirst();
      // Cancelled queued requests never decode.
      if (request.cancelled || !identical(_pending[path], request)) continue;
      _slots -= 1;
      unawaited(_run(path, request));
    }
  }

  Future<void> _run(String path, _Pending request) async {
    ui.Image? decoded;
    try {
      decoded = await decode(path, maximumPixelSize: maximumPixelSize);
    } finally {
      _slots += 1;
    }
    if (identical(_pending[path], request)) {
      _pending.remove(path);
      if (decoded != null) _store(path, decoded);
      for (final waiter in request.waiters.values) {
        if (!waiter.isCompleted) waiter.complete(decoded);
      }
    }
    _drain();
  }

  void _store(String path, ui.Image image) {
    final old = _cache.remove(path);
    if (old != null) _cost -= _bytes(old);
    _cache[path] = image;
    _cost += _bytes(image);
    while (_cache.length > countLimit || _cost > costLimit && _cache.length > 1) {
      final oldest = _cache.keys.first;
      _cost -= _bytes(_cache.remove(oldest)!);
    }
  }

  static int _bytes(ui.Image image) => image.width * image.height * 4;

  void _cancelLoad(String path, Object waiter) {
    final request = _pending[path];
    final completer = request?.waiters.remove(waiter);
    if (request == null || completer == null) return;
    if (request.waiters.isEmpty && !request.prefetched) {
      _pending.remove(path);
      request.cancelled = true;
    }
    if (!completer.isCompleted) completer.complete(null);
  }

  /// Consumers waiting for a path (for tests).
  int pendingConsumerCount(String path) => _pending[path]?.waiters.length ?? 0;

  /// Stops starting new decodes, so tests can observe queued requests.
  set suspended(bool value) {
    _suspended = value;
    if (!value) _drain();
  }

  void invalidate(String path) {
    final old = _cache.remove(path);
    if (old != null) _cost -= _bytes(old);
    final request = _pending.remove(path);
    if (request != null) {
      request.cancelled = true;
      for (final waiter in request.waiters.values) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
    }
    _invalidations.add(path);
  }

  void clear() {
    _cache.clear();
    _cost = 0;
    final requests = _pending.values.toList();
    _pending.clear();
    for (final request in requests) {
      request.cancelled = true;
      for (final waiter in request.waiters.values) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
    }
    _invalidations.add(null);
  }

  /// Decodes no larger than [maximumPixelSize] on the longer side, or null for a missing or invalid file.
  static Future<ui.Image?> decode(String path, {required int maximumPixelSize}) async {
    Uint8List data;
    try {
      data = await File(path).readAsBytes();
    } on FileSystemException {
      return null;
    }
    if (data.isEmpty) return null;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(data);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final longest = math.max(descriptor.width, descriptor.height);
      final scale = longest > maximumPixelSize ? maximumPixelSize / longest : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, descriptor.width),
        targetHeight: (descriptor.height * scale).round().clamp(1, descriptor.height),
      );
      return (await codec.getNextFrame()).image;
    } on Object {
      return null;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
