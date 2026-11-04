import 'dart:async';

import 'package:flutter/services.dart';

import '../support/perf_trace.dart';
import '../support/preferences.dart';
import 'content_errors.dart';
import 'content_transport.dart';

/// [HttpFetcher] on Android's own Chromium network stack, which encrypts the server name
/// (ECH) for sites that publish ECH keys in DNS. A network that resets connections by
/// server name lets these through, so a site reached once through a VPN keeps working
/// without one. Android 14 and later; elsewhere [available] is false.
class EncryptedHelloFetcher implements HttpFetcher {
  EncryptedHelloFetcher([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('work.nextline.tegnal/ech');

  final MethodChannel _channel;
  bool? _available;

  Future<bool> get available async {
    final known = _available;
    if (known != null) return known;
    try {
      return _available = await _channel.invokeMethod<bool>('available') ?? false;
    } on Object {
      return _available = false;
    }
  }

  @override
  Future<HttpReply> send(HttpExchange request) async {
    if (!await available) throw const NetworkError(NetworkErrorCode.secureConnectionFailed);
    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<Object?, Object?>('fetch', {
        'url': request.url.toString(),
        'method': request.method,
        'headers': request.headers,
        'body': request.body == null ? null : Uint8List.fromList(request.body!),
        // The transport bounds the body; the native side only needs a ceiling.
        'limit': 128 * 1024 * 1024,
        'timeoutMs': request.timeout.inMilliseconds,
      });
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'timeout' => const NetworkError(NetworkErrorCode.timedOut),
        'cannotFindHost' => const NetworkError(NetworkErrorCode.cannotFindHost),
        'notConnected' => const NetworkError(NetworkErrorCode.notConnectedToInternet),
        'cannotConnect' => const NetworkError(NetworkErrorCode.cannotConnectToHost),
        'tooLarge' => ContentError.tooLarge,
        'secureConnection' => const NetworkError(NetworkErrorCode.secureConnectionFailed),
        _ => const NetworkError(NetworkErrorCode.networkConnectionLost),
      };
    } on MissingPluginException {
      _available = false;
      throw const NetworkError(NetworkErrorCode.secureConnectionFailed);
    }
    if (reply == null) throw const NetworkError(NetworkErrorCode.cannotParseResponse);
    final headers = <String, List<String>>{
      for (final MapEntry(:key, :value) in ((reply['headers'] as Map?) ?? const {}).entries)
        if (key is String && value is List) key: [for (final item in value) '$item'],
    };
    final body = reply['body'] is Uint8List ? reply['body'] as Uint8List : Uint8List(0);
    return HttpReply(statusCode: (reply['status'] as num?)?.toInt() ?? 0, headers: headers, body: Stream.value(body));
  }
}

/// Sends through [primary] and, when a host's connection is cut during the handshake, retries
/// through [fallback]. Hosts that needed the fallback skip [primary] for a while, across launches,
/// so a filtered site costs one failed connection rather than one per request.
class FilteredNetworkFetcher implements HttpFetcher {
  FilteredNetworkFetcher({required this.primary, required this.fallback, this.preferences, this.memory = const Duration(days: 7)});

  final HttpFetcher primary;
  final HttpFetcher fallback;

  /// Where filtered hosts are remembered; null keeps them in memory only.
  final Preferences? preferences;
  final Duration memory;

  static const _key = 'network.filteredHosts';
  final _until = <String, DateTime>{};
  var _loaded = false;

  /// A connection reset or a failed handshake is what name filtering looks like; a refused
  /// connection or a missing host is not, and stays the primary route's answer.
  static bool isFiltered(Object error) =>
      error is NetworkError &&
      const [NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.networkConnectionLost, NetworkErrorCode.timedOut].contains(error.code);

  bool prefersFallback(String host, {DateTime? now}) {
    _load();
    final until = _until[host.toLowerCase()];
    return until != null && until.isAfter(now ?? DateTime.now());
  }

  void _remember(String host, {DateTime? now}) {
    _load();
    _until[host.toLowerCase()] = (now ?? DateTime.now()).add(memory);
    preferences?.set(_key, [for (final MapEntry(:key, :value) in _until.entries) '$key ${value.millisecondsSinceEpoch}']);
  }

  void _forget(String host) {
    _load();
    if (_until.remove(host.toLowerCase()) == null) return;
    preferences?.set(_key, [for (final MapEntry(:key, :value) in _until.entries) '$key ${value.millisecondsSinceEpoch}']);
  }

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final stored = preferences?.object(_key);
    if (stored is! List) return;
    for (final line in stored.whereType<String>()) {
      final parts = line.split(' ');
      final millis = parts.length == 2 ? int.tryParse(parts[1]) : null;
      if (millis != null) _until[parts[0]] = DateTime.fromMillisecondsSinceEpoch(millis);
    }
  }

  @override
  Future<HttpReply> send(HttpExchange request) async {
    final host = request.url.host;
    if (prefersFallback(host)) {
      try {
        return await PerfTrace.span('http ech ${request.url.host}${request.url.path}', () => fallback.send(request));
      } catch (error) {
        // The filter may have been lifted, or the site dropped ECH: try the plain route once more.
        if (!isFiltered(error)) rethrow;
        _forget(host);
        return primary.send(request);
      }
    }
    try {
      return await primary.send(request);
    } catch (error) {
      if (!isFiltered(error)) rethrow;
      final reply = await PerfTrace.span('http ech ${request.url.host}${request.url.path}', () => fallback.send(request));
      _remember(host);
      return reply;
    }
  }
}
