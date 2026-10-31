import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../data/source_http_client.dart';
import '../data/session_client.dart';

/// Thumbnails use this budget; anything larger is a reader page or original.
const thumbnailMaximumBytes = 2 * 1024 * 1024;

/// Flutter's 100 MiB default holds only about four full reader pages, so
/// prefetched neighbors were evicted before use. Matches the native reader.
const decodedImageCacheBytes = 192 * 1024 * 1024;

ImageProvider<Object> sessionImageProvider(
  Uri url,
  Map<String, String> headers, {
  int maximumBytes = 64 * 1024 * 1024,
}) => url.scheme == 'file'
    ? FileImage(File.fromUri(url))
    : SessionNetworkImage(url, headers: headers, maximumBytes: maximumBytes);

/// Uses the same authenticated transport as source requests. ImageCache shares
/// requests and decoded pixels between visible images and reader prefetch.
class SessionNetworkImage extends ImageProvider<SessionNetworkImage> {
  SessionNetworkImage(
    this.url, {
    Map<String, String> headers = const {},
    this.maximumBytes = 64 * 1024 * 1024,
  }) : headers = Map.unmodifiable(headers),
       sessionRevision = BrowserSession.revisionFor(url);

  final Uri url;
  final Map<String, String> headers;
  final int maximumBytes;
  final String sessionRevision;

  @override
  Future<SessionNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    SessionNetworkImage key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(decode, chunks),
      scale: 1,
      chunkEvents: chunks.stream,
    );
  }

  Future<ui.Codec> _load(
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      final bytes = await SessionImageLoader(maximumBytes: maximumBytes)
          .load(url, headers: headers, onChunk: chunks.add);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // Match NetworkImage: failed keys must be retriable immediately.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      await chunks.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SessionNetworkImage &&
      other.url == url &&
      other.maximumBytes == maximumBytes &&
      other.sessionRevision == sessionRevision &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode {
    final names = headers.keys.toList()..sort();
    return Object.hash(
      url,
      maximumBytes,
      sessionRevision,
      Object.hashAll(names.map((name) => Object.hash(name, headers[name]))),
    );
  }
}

/// Small encoded LRU avoids repeat downloads when decoded images are evicted.
/// Its bounded memory and session-scoped disk tiers obey server cache rules.
class SessionImageLoader {
  SessionImageLoader({
    this.clientFactory,
    this.maximumBytes = 64 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 30),
    this.cache,
  });

  final SessionImageByteCache? cache;
  final Duration requestTimeout;
  final http.Client Function(Uri)? clientFactory;
  final int maximumBytes;

  static final _requests = _ImageRequests();
  static final _sharedCache = SessionImageByteCache(useDisk: true);
  static bool _memoryObserverRegistered = false;

  static Future<void> clearCache() async {
    await _sharedCache.clear();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  Future<Uint8List> load(
    Uri url, {
    Map<String, String> headers = const {},
    void Function(ImageChunkEvent)? onChunk,
  }) {
    // Injected transports are isolated unless a cache is explicitly supplied.
    final selected = cache ?? (clientFactory == null ? _sharedCache : null);
    final foreground = maximumBytes > thumbnailMaximumBytes;
    if (identical(selected, _sharedCache) && !_memoryObserverRegistered) {
      WidgetsBinding.instance.addObserver(_sharedCache);
      _memoryObserverRegistered = true;
    }
    final key = _ImageByteKey(
      url,
      headers,
      maximumBytes,
      BrowserSession.revisionFor(url),
    );
    if (selected == null) {
      return _requests.run(
        () => _load(url, headers: headers, onChunk: onChunk),
        foreground: foreground,
      );
    }
    final generation = selected._generation;
    return selected._getOrLoad(
      key,
      () => _requests.run(
        () => _load(
          url,
          headers: headers,
          onChunk: onChunk,
          cache: selected,
          key: key,
          cacheGeneration: generation,
        ),
        foreground: foreground,
      ),
    );
  }

  Future<Uint8List> _load(
    Uri url, {
    required Map<String, String> headers,
    void Function(ImageChunkEvent)? onChunk,
    SessionImageByteCache? cache,
    _ImageByteKey? key,
    int? cacheGeneration,
  }) async {
    final abort = Completer<void>();
    final deadline = Timer(requestTimeout, () => abort.complete());
    try {
      return await _loadUntilAborted(
        url,
        headers,
        onChunk,
        abort,
        cache,
        key,
        cacheGeneration,
      );
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> _loadUntilAborted(
    Uri url,
    Map<String, String> headers,
    void Function(ImageChunkEvent)? onChunk,
    Completer<void> abort,
    SessionImageByteCache? cache,
    _ImageByteKey? key,
    int? cacheGeneration,
  ) async {
    var cacheAllowed = true;
    var current = url;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (abort.isCompleted) throw http.RequestAbortedException(current);
      if (current.scheme != 'https' ||
          current.host.isEmpty ||
          current.userInfo.isNotEmpty) {
        throw const HttpException('An image requires a secure HTTPS address.');
      }
      final requestUri = current;
      final client = clientFactory?.call(current) ?? _requests.client(current);
      try {
        final request = http.AbortableRequest(
          'GET',
          current,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers.addAll({
          for (final entry in headers.entries)
            // The transport resolves cookies for each concrete destination.
            // Do not replay credentials from the original URL on a CDN hop.
            if (entry.key.toLowerCase() != 'cookie' &&
                (current.origin == url.origin ||
                    !{
                      'authorization',
                      'proxy-authorization',
                    }.contains(entry.key.toLowerCase())))
              entry.key: entry.value,
        });
        // Await the transport's cancellation acknowledgement before releasing
        // this job's slot. Future.timeout alone leaves native work running.
        final response = await client.send(request);
        final directives = (response.headers['cache-control'] ?? '')
            .toLowerCase();
        if (directives.contains('no-store') ||
            directives.contains('no-cache') ||
            response.headers['vary']?.trim() == '*') {
          cacheAllowed = false;
        }
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          final location = response.headers['location'];
          if (location == null || redirects == 5) {
            throw const HttpException('The image redirected too many times.');
          }
          current = current.resolve(location);
          // A destination cookie can change independently of the original URL.
          // Avoid reusing redirected authenticated sessions under the wrong key.
          if (BrowserSession.supported && current.origin != url.origin) {
            cacheAllowed = false;
          }
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.listen((_) {}).cancel();
          throw NetworkImageLoadException(
            statusCode: response.statusCode,
            uri: current,
          );
        }
        final length = response.contentLength;
        if (length != null && length > maximumBytes) {
          await response.stream.listen((_) {}).cancel();
          throw const HttpException('The image is too large to load.');
        }
        final bytes = BytesBuilder(copy: false);
        var received = 0;
        await for (final chunk in response.stream) {
          received += chunk.length;
          if (received > maximumBytes) {
            throw const HttpException('The image is too large to load.');
          }
          bytes.add(chunk);
          onChunk?.call(
            ImageChunkEvent(
              cumulativeBytesLoaded: received,
              expectedTotalBytes: length,
            ),
          );
        }
        if (received == 0) throw const HttpException('The image is empty.');
        final result = bytes.takeBytes();
        if (cacheAllowed &&
            key != null &&
            key.revision == BrowserSession.revisionFor(url)) {
          final maxAge = RegExp(r'(?:^|,)\s*max-age\s*=\s*(\d+)')
              .firstMatch(directives);
          final age = int.tryParse(response.headers['age'] ?? '') ?? 0;
          var seconds = 3600;
          if (maxAge != null) {
            seconds = ((int.tryParse(maxAge.group(1)!) ?? 0) - age).clamp(
              0,
              7 * 24 * 3600,
            );
          } else if (response.headers['expires'] != null) {
            try {
              final expires = HttpDate.parse(response.headers['expires']!);
              final date = response.headers['date'] == null
                  ? DateTime.now().toUtc()
                  : HttpDate.parse(response.headers['date']!);
              seconds = (expires.difference(date).inSeconds - age).clamp(
                0,
                7 * 24 * 3600,
              );
            } on FormatException {
              seconds = 0;
            }
          }
          cache?._put(key, result, Duration(seconds: seconds), cacheGeneration);
        }
        return result;
      } finally {
        if (clientFactory != null) {
          client.close();
        } else {
          _requests.release(requestUri);
        }
      }
    }
    throw const HttpException('The image redirected too many times.');
  }
}

/// Matches the native six-connection window. Thumbnails stop one slot short,
/// so a reader page never waits behind a full grid of covers. Idle transports
/// retain connection/ECH reuse, with at most eight origin clients; eviction
/// skips any origin still in use.
class _ImageRequests {
  static const _maximumActive = 6;
  static const _maximumThumbnails = 5;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  final _waitingForeground = <Completer<void>>[];
  final _clients = <String, http.Client>{};
  final _inUse = <String, int>{};

  Future<T> run<T>(
    Future<T> Function() operation, {
    bool foreground = false,
  }) async {
    final queue = foreground ? _waitingForeground : _waiting;
    final turn = Completer<void>();
    // A fast fling must not retain an entire library of queued closures and
    // credentials. New visible work supersedes the oldest waiting image.
    // Failed ImageProvider keys are evicted, so returning cells can retry.
    if (queue.length >= 64) {
      queue
          .removeAt(0)
          .completeError(
            const HttpException('A newer image replaced this queued request.'),
          );
    }
    queue.add(turn);
    _startNext();
    await turn.future;
    try {
      return await operation();
    } finally {
      _active--;
      _startNext();
    }
  }

  void _startNext() {
    while (true) {
      final Completer<void> next;
      if (_waitingForeground.isNotEmpty && _active < _maximumActive) {
        next = _waitingForeground.removeLast();
      } else if (_waiting.isNotEmpty && _active < _maximumThumbnails) {
        next = _waiting.removeLast();
      } else {
        return;
      }
      _active++;
      next.complete();
    }
  }

  http.Client client(Uri url) {
    final key = url.origin;
    _inUse.update(key, (count) => count + 1, ifAbsent: () => 1);
    final existing = _clients.remove(key);
    final result = existing ?? SourceHttpClient(origin: url);
    _clients[key] = result;
    _trim();
    return result;
  }

  void release(Uri url) {
    final key = url.origin;
    final remaining = (_inUse[key] ?? 1) - 1;
    if (remaining == 0) {
      _inUse.remove(key);
    } else {
      _inUse[key] = remaining;
    }
    _trim();
  }

  void _trim() {
    while (_clients.length > 8) {
      final idle = _clients.keys.where((key) => !_inUse.containsKey(key));
      if (idle.isEmpty) return;
      _clients.remove(idle.first)!.close();
    }
  }
}

class _ImageByteKey {
  _ImageByteKey(
    this.url,
    Map<String, String> headers,
    this.maximumBytes,
    this.revision,
  ) : headers = Map.unmodifiable(headers);
  final Uri url;
  final Map<String, String> headers;
  final int maximumBytes;
  final String revision;
  @override
  bool operator ==(Object other) =>
      other is _ImageByteKey &&
      url == other.url &&
      maximumBytes == other.maximumBytes &&
      revision == other.revision &&
      mapEquals(headers, other.headers);
  @override
  int get hashCode {
    final keys = headers.keys.toList()..sort();
    return Object.hash(
      url,
      maximumBytes,
      revision,
      Object.hashAll(keys.map((k) => Object.hash(k, headers[k]))),
    );
  }
}

class _ByteEntry {
  _ByteEntry(this.bytes, this.expires);
  final Uint8List bytes;
  final DateTime expires;
}

/// Bounded LRU. Clearing also prevents outstanding work from repopulating it.
class SessionImageByteCache with WidgetsBindingObserver {
  SessionImageByteCache({
    this.maximumBytes = 32 * 1024 * 1024,
    this.maximumDiskBytes = 512 * 1024 * 1024,
    this.useDisk = false,
    this.diskDirectory,
    this.beforeDiskWrite,
  });
  final int maximumBytes;
  final int maximumDiskBytes;
  final bool useDisk;
  final Directory? diskDirectory;
  @visibleForTesting
  final Future<void> Function()? beforeDiskWrite;
  final _entries = <_ImageByteKey, _ByteEntry>{};
  final _flights = <_ImageByteKey, Future<Uint8List>>{};
  int _size = 0;
  int _generation = 0;
  Future<void> _diskQueue = Future.value();
  Directory? _directory;
  Map<String, int>? _diskIndex;
  int _diskSize = 0;
  int _pendingDiskBytes = 0;
  int _pendingDiskJobs = 0;
  final _pendingDiskKeys = <_ImageByteKey, int>{};
  static const _maximumPendingDiskBytes = 32 * 1024 * 1024;
  static const _maximumPendingDiskJobs = 16;
  // Only credentialed files are tied to this process. Anonymous media survives
  // a restart, as the native disk caches do.
  final String _session = List.generate(
    4,
    (_) => Random.secure().nextInt(1 << 32).toRadixString(16),
  ).join();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _diskQueue.then((_) => operation());
    _diskQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return result;
  }

  Future<Directory> _dir() async {
    if (_directory != null) return _directory!;
    final parent = diskDirectory ?? await getTemporaryDirectory();
    final directory = Directory('${parent.path}/tegnal-image-cache');
    await directory.create(recursive: true);
    return _directory = directory;
  }

  /// Size accounting is only needed to write, so a launch that merely reads
  /// cached images never pays for scanning the directory.
  Future<void> _indexDisk(Directory directory) async {
    if (_diskIndex != null) return;
    final files = await directory
        .list()
        .where((e) => e is File && e.path.endsWith('.data'))
        .cast<File>()
        .toList();
    // Bound metadata operations while indexing older session files.
    final stats = <FileStat>[];
    for (var i = 0; i < files.length; i += 32) {
      stats.addAll(
        await Future.wait(files.skip(i).take(32).map((file) => file.stat())),
      );
    }
    final order = List.generate(files.length, (i) => i)
      ..sort((a, b) => stats[a].modified.compareTo(stats[b].modified));
    _diskIndex = {
      for (final i in order)
        files[i].uri.pathSegments.last.replaceFirst(RegExp(r'\.data$'), ''):
            stats[i].size,
    };
    _diskSize = stats.fold<int>(0, (sum, stat) => sum + stat.size);
  }

  bool _persistent(_ImageByteKey key) =>
      BrowserSession.isInitialRevision(key.revision) &&
      !key.headers.keys.any(
        (name) =>
            const {'authorization', 'cookie'}.contains(name.toLowerCase()),
      );

  String _name(_ImageByteKey key) {
    final names = key.headers.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              if (!_persistent(key)) _session,
              key.url.toString(),
              key.maximumBytes,
              key.revision,
              for (final name in names) [name, key.headers[name]],
            ]),
          ),
        )
        .toString();
  }

  @visibleForTesting
  Future<void> waitForDiskWrites() => _diskQueue;

  @override
  void didHaveMemoryPressure() {
    // Flutter clears its decoded ImageCache independently. Release our encoded
    // tier too, while retaining disk entries and ongoing requests.
    _entries.clear();
    _size = 0;
  }

  Future<void> clear() {
    _generation++;
    _entries.clear();
    _flights.clear();
    _size = 0;
    if (!useDisk) return Future.value();
    return _serial(() async {
      try {
        final dir = await _dir();
        if (await dir.exists()) await dir.delete(recursive: true);
        _directory = null;
        _diskIndex = null;
        _diskSize = 0;
      } on FileSystemException {
        // A missing cache is equivalent to an empty one.
      } on MissingPluginException {
        // Cache storage is optional on unsupported hosts.
      }
    });
  }

  Future<Uint8List> _getOrLoad(
    _ImageByteKey key,
    Future<Uint8List> Function() load,
  ) {
    final entry = _entries.remove(key);
    if (entry != null) {
      if (DateTime.now().isBefore(entry.expires)) {
        _entries[key] = entry;
        return Future.value(entry.bytes);
      }
      _size -= entry.bytes.length;
    }
    final existing = _flights[key];
    if (existing != null) return existing;
    final generation = _generation;
    final future = () async {
      // An indexed miss is certain, and before indexing only anonymous files
      // can predate this process. Only queued writes for this key need order.
      if (useDisk) {
        final index = _diskIndex;
        if (_pendingDiskKeys.containsKey(key)) {
          final disk = await _serial(() => _readDisk(key, generation));
          if (disk != null) return disk;
        } else if (index?.containsKey(_name(key)) ?? _persistent(key)) {
          final disk = await _readDisk(key, generation);
          if (disk != null) return disk;
        }
      }
      return load();
    }();
    _flights[key] = future;
    future.then<void>(
      (_) {
        if (generation == _generation && identical(_flights[key], future)) {
          _flights.remove(key);
        }
      },
      onError: (Object _, StackTrace stack) {
        if (generation == _generation && identical(_flights[key], future)) {
          _flights.remove(key);
        }
      },
    );
    return future;
  }

  Future<Uint8List?> _readDisk(_ImageByteKey key, int generation) async {
    try {
      final dir = await _dir();
      final name = _name(key);
      final data = File('${dir.path}/$name.data');
      final meta = File('${dir.path}/$name.meta');
      final expires = DateTime.fromMillisecondsSinceEpoch(
        int.parse(await meta.readAsString()),
      );
      if (generation != _generation || !DateTime.now().isBefore(expires)) {
        await data.delete();
        await meta.delete();
        _diskSize -= _diskIndex?.remove(name) ?? 0;
        return null;
      }
      final bytes = await data.readAsBytes();
      if (bytes.length > key.maximumBytes || generation != _generation) {
        return null;
      }
      final size = _diskIndex?.remove(name);
      if (size != null) _diskIndex![name] = size;
      // The modified time carries recency across restarts into _indexDisk.
      unawaited(
        data
            .setLastModified(DateTime.now())
            .then<void>((_) {}, onError: (Object _, StackTrace stack) {}),
      );
      _remember(key, bytes, expires);
      return bytes;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  void _put(
    _ImageByteKey key,
    Uint8List bytes,
    Duration lifetime,
    int? generation,
  ) {
    if (generation != _generation ||
        !_flights.containsKey(key) ||
        lifetime <= Duration.zero) {
      return;
    }
    final expires = DateTime.now().add(lifetime);
    _remember(key, bytes, expires);
    if (!useDisk ||
        bytes.length > maximumDiskBytes ||
        bytes.length + _pendingDiskBytes > _maximumPendingDiskBytes ||
        _pendingDiskJobs >= _maximumPendingDiskJobs) {
      return;
    }
    _pendingDiskBytes += bytes.length;
    _pendingDiskJobs++;
    _pendingDiskKeys.update(key, (count) => count + 1, ifAbsent: () => 1);
    // Persistence is best effort and never delays decode. Reserve bytes before
    // enqueueing so a fling cannot accumulate an unbounded disk backlog.
    unawaited(
      _serial(() async {
        try {
          if (generation != _generation) return;
          await beforeDiskWrite?.call();
          if (generation != _generation) return;
          final dir = await _dir();
          await _indexDisk(dir);
          if (generation != _generation) return;
          final name = _name(key);
          final data = File('${dir.path}/$name.data');
          final meta = File('${dir.path}/$name.meta');
          await data.writeAsBytes(bytes);
          if (generation != _generation) {
            await data.delete();
            return;
          }
          await meta.writeAsString(expires.millisecondsSinceEpoch.toString());
          final oldSize = _diskIndex!.remove(name) ?? 0;
          _diskSize -= oldSize;
          _diskIndex![name] = bytes.length;
          _diskSize += bytes.length;
          while (_diskSize > maximumDiskBytes && _diskIndex!.isNotEmpty) {
            final oldest = _diskIndex!.keys.first;
            final size = _diskIndex!.remove(oldest)!;
            final oldData = File('${dir.path}/$oldest.data');
            final oldMeta = File('${dir.path}/$oldest.meta');
            if (await oldData.exists()) await oldData.delete();
            if (await oldMeta.exists()) await oldMeta.delete();
            _diskSize -= size;
          }
        } on FileSystemException {
          // A failed cache write does not fail the image.
        } on MissingPluginException {
          // Cache storage is optional on unsupported hosts.
        } finally {
          _pendingDiskBytes -= bytes.length;
          _pendingDiskJobs--;
          final remaining = _pendingDiskKeys[key]! - 1;
          if (remaining == 0) {
            _pendingDiskKeys.remove(key);
          } else {
            _pendingDiskKeys[key] = remaining;
          }
        }
      }),
    );
  }

  void _remember(_ImageByteKey key, Uint8List bytes, DateTime expires) {
    if (bytes.length > maximumBytes) return;
    final previous = _entries.remove(key);
    if (previous != null) _size -= previous.bytes.length;
    while (_size + bytes.length > maximumBytes && _entries.isNotEmpty) {
      _size -= _entries.remove(_entries.keys.first)!.bytes.length;
    }
    _entries[key] = _ByteEntry(bytes, expires);
    _size += bytes.length;
  }
}
