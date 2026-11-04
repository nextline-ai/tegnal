import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:io';
import 'dart:typed_data';

import '../content/content_errors.dart';
import '../content/content_transport.dart';
import '../downloads/download_store.dart';
import 'booru_browser.dart';
import 'booru_client.dart';
import 'booru_models.dart';
import 'booru_thumbnail_disk_cache.dart';

/// What encoded media bytes are, read from their signature rather than a file name.
abstract final class BooruMediaType {
  /// The file extension for the image or video format of [data], or null for anything else.
  static String? sniff(Uint8List data) {
    bool starts(List<int> bytes, [int offset = 0]) {
      if (data.length < offset + bytes.length) return false;
      for (var index = 0; index < bytes.length; index++) {
        if (data[offset + index] != bytes[index]) return false;
      }
      return true;
    }

    String ascii(int offset, int length) => data.length < offset + length ? '' : String.fromCharCodes(data.sublist(offset, offset + length));
    if (starts(const [0xFF, 0xD8, 0xFF])) return 'jpeg';
    if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
    if (ascii(0, 6) == 'GIF87a' || ascii(0, 6) == 'GIF89a') return 'gif';
    if (ascii(0, 4) == 'RIFF' && ascii(8, 4) == 'WEBP') return 'webp';
    if (ascii(0, 2) == 'BM' && data.length > 14) return 'bmp';
    if (starts(const [0xFF, 0x0A]) || starts(const [0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20])) return 'jxl';
    if (starts(const [0x1A, 0x45, 0xDF, 0xA3])) return 'webm';
    if (ascii(4, 4) == 'ftyp') {
      final brand = ascii(8, 4);
      if (brand == 'avif' || brand == 'avis') return 'avif';
      if (['heic', 'heix', 'hevc', 'heim', 'heis', 'mif1', 'msf1'].contains(brand)) return 'heic';
      if (brand == 'qt  ') return 'mov';
      if (brand.startsWith('M4V')) return 'm4v';
      return 'mp4';
    }
    return null;
  }

  static const _images = {'jpeg', 'png', 'gif', 'webp', 'bmp', 'jxl', 'avif', 'heic'};

  /// Whether [data] is an image the viewer can decode (`CGImageSourceGetCount > 0`).
  static bool isImage(Uint8List data) => _images.contains(sniff(data));

  /// `UTType.preferredFilenameExtension` for a saved image.
  static String? imageExtension(Uint8List data) {
    final type = sniff(data);
    if (!_images.contains(type)) return null;
    return type == 'jpeg' ? 'jpeg' : type;
  }
}

class _MemoryCache {
  _MemoryCache(this.capacity, this.countLimit);
  final int capacity;
  final int countLimit;
  final _values = <String, Uint8List>{};
  var _bytes = 0;

  Uint8List? operator [](String key) {
    final value = _values.remove(key);
    if (value != null) _values[key] = value;
    return value;
  }

  void put(String key, Uint8List value) {
    final old = _values.remove(key);
    if (old != null) _bytes -= old.length;
    if (value.length > capacity) return;
    _values[key] = value;
    _bytes += value.length;
    while (_bytes > capacity || _values.length > countLimit) {
      final oldest = _values.keys.first;
      _bytes -= _values.remove(oldest)!.length;
    }
  }

  void clear() {
    _values.clear();
    _bytes = 0;
  }
}

typedef BooruMediaLoader = Future<Uint8List> Function(String url, BooruServer server);

/// Encoded image bytes for one purpose: grid thumbnails ([BooruImageCache.thumbnails]) or
/// viewer originals ([BooruImageCache.viewer]). Memory serves synchronous cell reads, the
/// bounded disk cache survives relaunches, and simultaneous consumers share one download.
class BooruImageCache {
  BooruImageCache({
    required Directory directory,
    int diskCapacity = 256 * 1024 * 1024,
    int memoryCapacity = 128 * 1024 * 1024,
    int memoryCount = 256,
    String fileExtension = 'img',
    this.maximumBytes = 64 * 1024 * 1024,
    this.isViewer = false,
    this.prefetchWorkers = 2,
    this.loadData,
    this.client,
    this.transform,
  }) : _disk = BooruThumbnailDiskCache(directory: directory, capacity: diskCapacity, fileExtension: fileExtension),
       _memory = _MemoryCache(memoryCapacity, memoryCount);

  /// Grid previews: `Caches/BooruThumbnails`, 256 MB on disk.
  factory BooruImageCache.thumbnails(Directory caches, {BooruMediaLoader? loadData, Future<Uint8List?> Function(Uint8List data)? transform}) =>
      BooruImageCache(directory: BooruThumbnailDiskCache.defaultDirectory(caches), loadData: loadData, transform: transform, fileExtension: 'png');

  /// Viewer originals: `Caches/BooruViewerImages`, 512 MB on disk, a few in memory.
  factory BooruImageCache.viewer(Directory caches, {BooruMediaLoader? loadData}) => BooruImageCache(
    directory: Directory('${caches.path}/BooruViewerImages'),
    diskCapacity: 512 * 1024 * 1024,
    memoryCapacity: 48 * 1024 * 1024,
    memoryCount: 6,
    fileExtension: 'media',
    maximumBytes: 128 * 1024 * 1024,
    isViewer: true,
    loadData: loadData,
  );

  static BooruImageCache? sharedThumbnails;
  static BooruImageCache? sharedViewer;

  final BooruThumbnailDiskCache _disk;
  final _MemoryCache _memory;
  final BooruMediaLoader? loadData;

  /// The client whose connection and profile downloads use; [BooruClient.shared] without one.
  final BooruClient? client;
  final int maximumBytes;
  final bool isViewer;
  final int prefetchWorkers;

  /// Prepares what the cache keeps from downloaded bytes, such as a downscaled PNG for the
  /// grid. Null keeps the downloaded bytes; a null result rejects them as undecodable.
  final Future<Uint8List?> Function(Uint8List data)? transform;

  final _inFlight = <String, Future<Uint8List>>{};
  final _prefetchQueue = Queue<(String, String, BooruServer)>();
  final _prefetchKeys = <String>{};
  var _activePrefetches = 0;
  var _generation = 0;
  var _prefetchGeneration = 0;

  BooruClient get _client => client ?? BooruClient.shared;

  static String cacheKey(String url, BooruServer server) => '${server.canonicalAddress}:${server.id}:$url';

  Uint8List? cached(String url, BooruServer server) => _memory[cacheKey(url, server)];

  /// Downloads in progress that consumers share, for tests.
  int get inFlightCount => _inFlight.length;

  Future<Uint8List> load(String url, BooruServer server) {
    final key = cacheKey(url, server);
    final memory = _memory[key];
    if (memory != null) return Future.value(memory);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final captured = _generation;
    // A shared load survives cell reuse and feeds both memory and disk caches.
    final task = () async {
      try {
        // The file is read off the frame, so scrolling over cached cells never waits on storage.
        final disk = await _disk.readAsync(key);
        if (disk != null && captured == _generation) {
          if (_valid(disk)) {
            _memory.put(key, disk);
            return disk;
          }
          _disk.remove(key);
        }
        final downloaded = await _download(url, server);
        final kept = transform == null ? downloaded : await transform!(downloaded);
        if (kept == null || captured != _generation) throw const BooruError(BooruErrorKind.invalidResponse);
        _memory.put(key, kept);
        _disk.write(kept, key);
        return kept;
      } finally {
        if (captured == _generation) _inFlight.remove(key);
      }
    }();
    _inFlight[key] = task;
    return task;
  }

  bool _valid(Uint8List data) => BooruMediaType.isImage(data);

  Future<Uint8List> _download(String url, BooruServer server) async {
    final Uint8List data;
    final loadData = this.loadData;
    if (loadData != null) {
      data = await loadData(url, server);
    } else if (BooruWebTransport.prefersBrowser(server)) {
      // The server answers direct requests with a browser check, so a direct try only adds a round trip.
      data = await BooruWebTransport.imageData(url, server);
    } else {
      final target = Uri.tryParse(url);
      if (target == null || target.scheme != 'https' || target.userInfo.isNotEmpty) throw const BooruError(BooruErrorKind.invalidServer);
      try {
        final request = BooruRequest(target);
        _client.session.prepare(request, server);
        final response = await _client.send(request, publicMedia: true, limit: maximumBytes);
        if (isViewer && server.engine == BooruEngine.danbooru && response.statusCode == 451) throw BooruPostAccessError.removed;
        if (BooruWebTransport.isAvailable && BooruClient.needsBrowser(response.data, response.statusCode)) BooruWebTransport.directChallenged(server);
        if (response.statusCode < 200 || response.statusCode >= 300 || !_valid(response.data)) {
          final restriction = isViewer ? BooruPostAccessError.detect(response.data, server) : null;
          if (restriction != null) throw restriction;
          throw const BooruError(BooruErrorKind.invalidResponse);
        }
        return response.data;
      } catch (error) {
        if (error is BooruPostAccessError || !BooruWebTransport.hasSession(server)) rethrow;
        data = await BooruWebTransport.imageData(url, server);
      }
    }
    if (data.length > maximumBytes || !_valid(data)) {
      final restriction = isViewer ? BooruPostAccessError.detect(data, server) : null;
      if (restriction != null) throw restriction;
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    return data;
  }

  /// Loads ahead of the visible cells, two at a time. A fast fling replaces obsolete
  /// lookahead: at most 24 addresses wait.
  void prefetch(List<(String, BooruServer)> items) {
    for (final (url, server) in items) {
      final key = cacheKey(url, server);
      if (_memory[key] != null || _inFlight.containsKey(key) || !_prefetchKeys.add(key)) continue;
      _prefetchQueue.add((key, url, server));
    }
    while (_prefetchQueue.length > 24) {
      _prefetchKeys.remove(_prefetchQueue.removeFirst().$1);
    }
    _startPrefetches();
  }

  void _startPrefetches() {
    while (_activePrefetches < prefetchWorkers && _prefetchQueue.isNotEmpty) {
      final (key, url, server) = _prefetchQueue.removeFirst();
      final captured = _prefetchGeneration;
      _activePrefetches += 1;
      load(url, server).then<void>((_) {}, onError: (_) {}).whenComplete(() {
        if (captured == _prefetchGeneration) _prefetchKeys.remove(key);
        _activePrefetches -= 1;
        _startPrefetches();
      });
    }
  }

  /// Drops waiting lookahead. Loads already running keep their slots until they finish,
  /// since a visible cell may share them.
  void cancelPrefetch() {
    _prefetchGeneration += 1;
    _prefetchQueue.clear();
    _prefetchKeys.clear();
  }

  /// Number of lookahead loads running, for tests.
  int get activePrefetches => _activePrefetches;

  /// Completes once downloaded copies started so far are on disk (for tests and relaunch).
  Future<void> get idle => _disk.idle;

  Future<void> clear() async {
    _generation += 1;
    _inFlight.clear();
    cancelPrefetch();
    _memory.clear();
    _disk.clear();
  }
}

/// Saves image-mode media for the download queue, with the server's browser profile.
class BooruMediaDownloader implements BooruMediaDownloading {
  BooruMediaDownloader({this.source, this.connection});

  final BooruProviding? source;

  /// The client whose connection and profile downloads use; [BooruClient.shared] without one.
  final BooruClient? connection;
  BooruClient get client => connection ?? BooruClient.shared;

  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) => (source ?? client).details(server, post);

  @override
  Future<String> download(
    Uri url, {
    required BooruServer server,
    required BooruPost post,
    required Directory folder,
    void Function(double fraction)? progress,
  }) async {
    if (url.scheme != 'https') throw const BooruError(BooruErrorKind.invalidResponse);
    try {
      return await _downloadMedia(url, server, post, folder, progress);
    } catch (error) {
      if (post.isVideo || !BooruWebTransport.hasSession(server)) rethrow;
      final data = await BooruWebTransport.imageData(url.toString(), server);
      final ext = BooruMediaType.imageExtension(data);
      if (ext == null) throw ContentError.unsupportedFormat;
      final name = '${post.postID}.$ext';
      await File('${folder.path}/$name').writeAsBytes(data, flush: true);
      return name;
    }
  }

  Future<String> _downloadMedia(Uri url, BooruServer server, BooruPost post, Directory folder, void Function(double fraction)? progress) async {
    final request = BooruRequest(url);
    client.session.prepare(request, server);
    final (head, reply) = await client.open(request, publicMedia: true);
    if (head.statusCode < 200 || head.statusCode >= 300) {
      reply.abort?.call();
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    final total = int.tryParse(head.headers['content-length']?.firstOrNull ?? '') ?? -1;
    await folder.create(recursive: true);
    final temporary = File('${folder.path}/.${post.postID}.download');
    final sink = temporary.openWrite();
    var received = 0;
    final prefix = BytesBuilder(copy: false);
    try {
      await for (final chunk in reply.body.timeout(const Duration(seconds: 60))) {
        if (prefix.length < 64) prefix.add(chunk.take(64 - prefix.length).toList());
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress?.call(received / total);
      }
      await sink.close();
    } on TimeoutException {
      await sink.close();
      await temporary.delete().catchError((_) => temporary);
      throw const NetworkError(NetworkErrorCode.timedOut);
    } on IOException catch (error) {
      await sink.close();
      await temporary.delete().catchError((_) => temporary);
      throw IoHttpFetcher.networkError(error);
    }
    final String ext;
    if (post.isVideo) {
      final type = head.headers['content-type']?.firstOrNull?.toLowerCase() ?? '';
      if (!type.startsWith('video/')) {
        await temporary.delete();
        throw const BooruError(BooruErrorKind.invalidResponse);
      }
      ext = post.fileExtension.toLowerCase();
    } else {
      final sniffed = BooruMediaType.imageExtension(prefix.takeBytes());
      if (sniffed == null) {
        await temporary.delete();
        throw ContentError.unsupportedFormat;
      }
      ext = sniffed;
    }
    final name = '${post.postID}.$ext';
    final destination = File('${folder.path}/$name');
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
    return name;
  }
}
