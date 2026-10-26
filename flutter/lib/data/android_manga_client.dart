import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Android OkHttp transport for MangaSource. Other platforms keep using the
/// normal package:http client.
class AndroidMangaClient extends http.BaseClient {
  AndroidMangaClient({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'work.nextline.tegnal/manga-http',
  );
  static const int _maximumResponseBytes = 32 * 1024 * 1024;
  static int _nextRequestId = 0;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static http.Client? createIfSupported() =>
      supported ? AndroidMangaClient() : null;

  final MethodChannel _channel;
  final Map<String, Future<void> Function()> _inFlight = {};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('This manga client is closed.');
    if (request.method.toUpperCase() != 'GET' ||
        request.url.scheme != 'https' ||
        request.url.host.isEmpty ||
        request.url.userInfo.isNotEmpty) {
      throw http.ClientException(
        'Only HTTPS GET requests are supported.',
        request.url,
      );
    }
    request.followRedirects = false;

    final requestId = '${++_nextRequestId}';
    var cancelled = false;
    Future<void> cancel() async {
      if (cancelled) return;
      cancelled = true;
      try {
        await _channel.invokeMethod<void>('cancel', {'requestId': requestId});
      } on PlatformException {
        // The request may have completed between cancellation and dispatch.
      } on MissingPluginException {
        // The native activity may already be shutting down.
      }
    }

    _inFlight[requestId] = cancel;

    final requestFuture = _channel.invokeMapMethod<Object?, Object?>(
      'get',
      <String, Object?>{
        'requestId': requestId,
        'url': request.url.toString(),
        'headers': _safeHeaders(request.headers),
        'maxBytes': _maximumResponseBytes,
      },
    );
    final abortTrigger = request is http.Abortable
        ? request.abortTrigger
        : null;
    try {
      final Map<Object?, Object?>? result;
      if (abortTrigger == null) {
        result = await requestFuture;
      } else {
        result = await Future.any<Map<Object?, Object?>?>([
          requestFuture,
          abortTrigger.then<Map<Object?, Object?>>((_) async {
            unawaited(cancel());
            throw http.RequestAbortedException(request.url);
          }),
        ]);
      }
      if (_closed) throw http.ClientException('This manga client is closed.');
      if (cancelled) throw http.RequestAbortedException(request.url);
      if (result == null) {
        throw http.ClientException(
          'The Android manga transport returned no response.',
          request.url,
        );
      }
      final statusCode = result['statusCode'];
      final body = result['body'];
      final responseHeaders = result['headers'];
      if (statusCode is! int ||
          body is! Uint8List ||
          responseHeaders is! Map<Object?, Object?> ||
          body.length > _maximumResponseBytes) {
        throw http.ClientException(
          'The Android manga transport returned an invalid response.',
          request.url,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(body),
        statusCode,
        contentLength: body.length,
        request: request,
        headers: {
          for (final entry in responseHeaders.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        },
      );
    } on PlatformException catch (error) {
      if (error.code == 'aborted' || cancelled) {
        throw http.RequestAbortedException(request.url);
      }
      if (error.code == 'network_error') {
        throw AndroidMangaNetworkException(
          error.message ?? 'The manga server could not be reached.',
          request.url,
        );
      }
      if (error.code == 'certificate_error') {
        throw AndroidMangaCertificateException(
          error.message ??
              'The manga server certificate could not be verified.',
          request.url,
        );
      }
      throw http.ClientException(
        error.message ?? 'The Android manga request failed.',
        request.url,
      );
    } on MissingPluginException {
      throw http.ClientException(
        'The Android manga transport is unavailable.',
        request.url,
      );
    } finally {
      _inFlight.remove(requestId);
    }
  }

  static Map<String, String> _safeHeaders(Map<String, String> headers) {
    const excluded = {
      'connection',
      'content-length',
      'host',
      'keep-alive',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailer',
      'transfer-encoding',
      'upgrade',
    };
    return {
      for (final entry in headers.entries)
        if (!excluded.contains(entry.key.toLowerCase()) &&
            !entry.key.toLowerCase().startsWith('proxy-'))
          entry.key: entry.value,
    };
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancel in _inFlight.values.toList()) {
      unawaited(cancel());
    }
    _inFlight.clear();
  }
}

/// A connection-level failure eligible for the ECH-required fallback.
class AndroidMangaNetworkException extends http.ClientException {
  AndroidMangaNetworkException(super.message, [super.uri]);
}

/// Certificate validation failures must never be retried through another TLS stack.
class AndroidMangaCertificateException extends http.ClientException {
  AndroidMangaCertificateException(super.message, [super.uri]);
}
