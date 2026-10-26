import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../data/source_http_client.dart';

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
  }) : headers = Map.unmodifiable(headers);

  final Uri url;
  final Map<String, String> headers;
  final int maximumBytes;

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
      mapEquals(other.headers, headers);

  @override
  int get hashCode {
    final names = headers.keys.toList()..sort();
    return Object.hash(
      url,
      maximumBytes,
      Object.hashAll(names.map((name) => Object.hash(name, headers[name]))),
    );
  }
}

/// Encoded bytes live only for the request/decode. No second unbounded byte
/// cache is retained alongside Flutter's existing bounded decoded ImageCache.
class SessionImageLoader {
  SessionImageLoader({
    this.clientFactory,
    this.maximumBytes = 64 * 1024 * 1024,
    this.requestTimeout = const Duration(seconds: 30),
  });

  final Duration requestTimeout;
  final http.Client Function(Uri)? clientFactory;
  final int maximumBytes;

  static final _requests = _ImageRequests();

  Future<Uint8List> load(
    Uri url, {
    Map<String, String> headers = const {},
    void Function(ImageChunkEvent)? onChunk,
  }) => _requests.run(() => _load(url, headers: headers, onChunk: onChunk));

  Future<Uint8List> _load(
    Uri url, {
    required Map<String, String> headers,
    void Function(ImageChunkEvent)? onChunk,
  }) async {
    final abort = Completer<void>();
    final deadline = Timer(requestTimeout, () => abort.complete());
    try {
      return await _loadUntilAborted(url, headers, onChunk, abort);
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
  ) async {
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
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          final location = response.headers['location'];
          if (location == null || redirects == 5) {
            throw const HttpException('The image redirected too many times.');
          }
          current = current.resolve(location);
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
        return bytes.takeBytes();
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

/// Keep the CPU/network window small like the native image queues. Idle
/// transports retain connection/ECH reuse, with at most eight origin clients.
/// Only two jobs run, so eviction can never close an in-flight origin client.
class _ImageRequests {
  int _active = 0;
  final _waiting = <Completer<void>>[];
  final _clients = <String, http.Client>{};
  final _inUse = <String, int>{};

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= 2) {
      final turn = Completer<void>();
      // A fast fling must not retain an entire library of queued closures and
      // credentials. New visible work supersedes the oldest waiting image.
      // Failed ImageProvider keys are evicted, so returning cells can retry.
      if (_waiting.length >= 64) {
        _waiting
            .removeAt(0)
            .completeError(
              const HttpException(
                'A newer image replaced this queued request.',
              ),
            );
      }
      _waiting.add(turn);
      await turn.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeLast().complete();
      }
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
