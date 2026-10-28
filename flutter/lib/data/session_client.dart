import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/content.dart';

/// Android WebView owns this device's browser session. Cookies are obtained for
/// one concrete URL at a time and are never part of source or backup metadata.
class BrowserSession {
  static const _channel = MethodChannel('work.nextline.tegnal/browser');

  /// Changes whenever browser authentication may have changed.
  static int _browserRevision = 0;
  static final Set<String> _openedOrigins = {};
  static final Set<String> _preferredOrigins = {};
  static final Set<String> _failedOrigins = {};
  static final Set<String> _retryFirstOrigins = {};
  static final Set<String> _checkedOrigins = {};
  static final Map<String, Future<void>> _routeChecks = {};
  static final Map<(Uri, String), Future<Map<String, String>>> _headerLookups =
      {};
  static int _routeGeneration = 0;
  static int _fetchId = 0;
  static final Map<String, int> _originRevisions = {};
  static String revisionFor(Uri uri) {
    final domainVersions =
        _originRevisions.entries
            .where(
              (entry) =>
                  uri.host == entry.key || uri.host.endsWith('.${entry.key}'),
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return '$_browserRevision:${domainVersions.map((e) => '${e.key}=${e.value}').join(',')}';
  }

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void _validate(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const ContentException(
        'Only secure HTTPS website addresses can be opened.',
      );
    }
  }

  /// Completes when the Android browser closes. On desktop this opens the
  /// external default browser, whose cookies cannot be imported into the app.
  static Future<void> open(
    Uri url, {
    Map<String, String> labels = const {},
  }) async {
    _validate(url);
    if (supported) {
      _routeGeneration++;
      _preferredOrigins.remove(url.origin);
      _retryFirstOrigins.remove(url.origin);
      _checkedOrigins.remove(url.origin);
      try {
        try {
          await _channel.invokeMethod<void>('open', {
            'url': url.toString(),
            'labels': labels,
          });
          _openedOrigins.add(url.origin);
          if (_failedOrigins.remove(url.origin)) {
            _retryFirstOrigins.add(url.origin);
          }
        } finally {
          _browserRevision++;
        }
      } on PlatformException {
        throw const ContentException(
          'Unable to open the browser. Close any open browser and retry.',
        );
      } on MissingPluginException {
        throw const ContentException(
          'Embedded website verification is available in the Android app.',
        );
      }
    } else {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const ContentException('Unable to open the default browser.');
      }
    }
  }

  static bool canRetryVerified(Uri uri) =>
      supported && _openedOrigins.contains(uri.origin);
  static bool prefersVerified(Uri uri) =>
      canRetryVerified(uri) && _preferredOrigins.contains(uri.origin);
  static void forgetVerifiedRoute(Uri uri) =>
      _preferredOrigins.remove(uri.origin);
  static void rememberNetworkFailure(Uri uri) => _failedOrigins.add(uri.origin);
  static bool takeVerificationRetry(Uri uri) =>
      _retryFirstOrigins.remove(uri.origin);

  /// Restores only an origin that previously completed a successful browser
  /// request; native preferences never contain cookies or credentials.
  static Future<void> restoreVerifiedRoute(Uri uri) async {
    if (!supported || canRetryVerified(uri)) return;
    final existing = _routeChecks[uri.origin];
    if (existing != null) return existing;
    if (!_checkedOrigins.add(uri.origin)) return;
    final generation = _routeGeneration;
    final check = () async {
      try {
        final allowed = await _channel.invokeMethod<bool>('hasVerifiedRoute', {
          'url': uri.toString(),
        });
        if (generation != _routeGeneration) {
          _checkedOrigins.remove(uri.origin);
          return;
        }
        if (allowed == true) {
          _openedOrigins.add(uri.origin);
          _preferredOrigins.add(uri.origin);
        }
      } on PlatformException {
        // A missing route is a normal unverified session.
      } on MissingPluginException {
        // The Android bridge is unavailable in tests and other hosts.
      }
    }();
    _routeChecks[uri.origin] = check;
    try {
      await check;
    } finally {
      if (identical(_routeChecks[uri.origin], check)) {
        _routeChecks.remove(uri.origin);
      }
    }
  }

  @visibleForTesting
  static void resetLocalRouteStateForTesting() {
    _openedOrigins.clear();
    _preferredOrigins.clear();
    _failedOrigins.clear();
    _retryFirstOrigins.clear();
    _checkedOrigins.clear();
    _routeChecks.clear();
    _routeGeneration++;
  }

  /// Browser-session retry is restricted to the exact source origin and does
  /// not receive caller credentials. WebView supplies its own scoped cookies.
  static Future<http.StreamedResponse> verifiedGet(
    http.BaseRequest request, {
    Stream<void>? closed,
  }) async {
    if (!canRetryVerified(request.url)) {
      throw http.ClientException('Browser session unavailable.', request.url);
    }
    final id = '${++_fetchId}';
    Future<void> cancel() async {
      try {
        await _channel.invokeMethod<void>('cancelVerifiedGet', {
          'requestId': id,
        });
      } on PlatformException {
        // Native work may already be finished.
      } on MissingPluginException {
        // Host was detached during cancellation.
      }
    }

    final operation = _channel.invokeMapMethod<Object?, Object?>(
      'verifiedGet',
      {'requestId': id, 'url': request.url.toString()},
    );
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    final stopped = Completer<Map<Object?, Object?>?>();
    var ended = false;
    Future<void> stop() async {
      if (ended || stopped.isCompleted) return;
      await cancel();
      if (!ended && !stopped.isCompleted) {
        stopped.completeError(http.RequestAbortedException(request.url));
      }
    }

    final subscription = closed?.listen((_) => unawaited(stop()));
    if (trigger != null) unawaited(trigger.then((_) => stop()));
    try {
      final response = await Future.any<Map<Object?, Object?>?>([
        operation,
        stopped.future,
      ]);
      if (response?['cookieChanged'] == true) _browserRevision++;
      final status = response?['statusCode'];
      final body = response?['body'];
      if (status is! int ||
          body is! Uint8List ||
          body.length > 12 * 1024 * 1024) {
        throw http.ClientException(
          'Invalid browser-session response.',
          request.url,
        );
      }
      final prefix = utf8
          .decode(body.take(4096).toList(), allowMalformed: true)
          .replaceFirst(RegExp(r'^\uFEFF'), '')
          .trimLeft();
      final expected = request.url.path.endsWith('/posts.json') ? '[' : '{';
      if (status >= 200 && status < 300 && prefix.startsWith(expected)) {
        _preferredOrigins.add(request.url.origin);
      } else {
        _preferredOrigins.remove(request.url.origin);
      }
      return http.StreamedResponse(
        Stream.value(body),
        status,
        contentLength: body.length,
        request: request,
      );
    } on PlatformException catch (error) {
      if (error.code == 'aborted' || error.code == 'closed') {
        throw http.RequestAbortedException(request.url);
      }
      rethrow;
    } finally {
      ended = true;
      await subscription?.cancel();
    }
  }

  /// Ask for the media URL itself, never the configured source URL. Android's
  /// CookieManager applies cookie domain/path/secure rules for that exact URL.
  /// Callers must keep these ephemeral headers out of persisted ReaderPages.
  static Future<Map<String, String>> headersFor(Uri uri) async {
    if (!supported ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return {};
    }
    // Visible and prefetched copies often ask for the same URL concurrently.
    // Share only that in-flight platform call, never a completed cookie value.
    final key = (uri, revisionFor(uri));
    // Keep a stalled platform channel from retaining an unbounded key set.
    if (!_headerLookups.containsKey(key) && _headerLookups.length >= 64) {
      return _readHeaders(uri);
    }
    final future = _headerLookups.putIfAbsent(key, () => _readHeaders(uri));
    try {
      return Map.of(await future);
    } finally {
      if (identical(_headerLookups[key], future)) _headerLookups.remove(key);
    }
  }

  static Future<Map<String, String>> _readHeaders(Uri uri) async {
    try {
      final headers = await _channel.invokeMapMethod<String, String>(
        'headersFor',
        {'url': uri.toString()},
      );
      return headers == null
          ? {}
          : {
              for (final entry in headers.entries)
                if ([
                      'cookie',
                      'user-agent',
                    ].contains(entry.key.toLowerCase()) &&
                    entry.value.isNotEmpty)
                  entry.key: entry.value,
            };
    } on MissingPluginException {
      return {};
    } on PlatformException {
      return {};
    }
  }

  static Future<void> shareLink(Uri uri, {String title = ''}) async {
    _validate(uri);
    if (!supported) return;
    await _channel.invokeMethod<void>('shareLink', {
      'url': uri.toString(),
      'title': title,
    });
  }

  static Future<List<String>> cookiesFor(Uri uri) async {
    _validate(uri);
    if (!supported) return [];
    return (await _channel.invokeListMethod<String>('cookiesFor', {
          'url': uri.toString(),
        })) ??
        [];
  }

  static Future<void> resetCookies(Uri uri) async {
    _validate(uri);
    if (supported) {
      await _channel.invokeMethod<void>('resetCookies', {
        'url': uri.toString(),
      });
      // CookieManager cannot report all domain/path scopes affected by reset.
      _routeGeneration++;
      _openedOrigins.clear();
      _preferredOrigins.clear();
      _failedOrigins.clear();
      _retryFirstOrigins.clear();
      _checkedOrigins.clear();
      _browserRevision++;
    }
  }

  static Future<void> _receive(Uri uri, String? header) async {
    if (!supported || header == null || header.isEmpty) return;
    final before = await _readHeaders(uri);
    // An Expires date contains a comma but no following cookie-name=value.
    final values = header.split(RegExp(r',(?=\s*[^;,=\s]+=)'));
    try {
      await _channel.invokeMethod<void>('receiveCookies', {
        'url': uri.toString(),
        'cookies': values,
      });
      final after = await _readHeaders(uri);
      // Cookies scoped to another path cannot be observed at this URL.
      final pathMatches = RegExp(
        r'(?:^|;)\s*path=([^;\s,]+)',
        caseSensitive: false,
      ).allMatches(header);
      final otherPath = pathMatches.any(
        (match) => !uri.path.startsWith(match.group(1)!),
      );
      if (!mapEquals(before, after) || otherPath) {
        _routeGeneration++;
        final domains = <String>{uri.host};
        for (final match in RegExp(
          r'(?:^|;)\s*domain=([^;\s,]+)',
          caseSensitive: false,
        ).allMatches(header)) {
          final domain = match
              .group(1)!
              .toLowerCase()
              .replaceFirst(RegExp(r'^\.'), '');
          if (uri.host == domain || uri.host.endsWith('.$domain')) {
            domains.add(domain);
          }
        }
        final invalidated = _preferredOrigins.where((value) {
          final host = Uri.parse(value).host;
          return domains.any(
            (domain) => host == domain || host.endsWith('.$domain'),
          );
        }).toList();
        _preferredOrigins.removeAll(invalidated);
        try {
          await _channel.invokeMethod<void>('invalidateStoredDomains', {
            'domains': domains.toList(),
          });
        } on PlatformException {
          // Current-process route is already invalidated.
        } on MissingPluginException {
          // The native bridge may have detached.
        }
        for (final domain in domains) {
          _originRevisions.update(
            domain,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        }
      }
    } on MissingPluginException {
      // A host without the Android bridge is a normal stateless client.
    } on PlatformException {
      // A cookie rejection must not discard an otherwise valid HTTP response.
    }
  }
}

/// A source-scoped adapter for the Android session. Automatic redirects are
/// always disabled before cookies are added; callers must validate each redirect
/// and create a fresh request, which obtains cookies for the destination URL.
/// Desktop requests pass through without importing an external browser session.
class SessionClient extends http.BaseClient {
  SessionClient({required this.origin, http.Client? inner})
    : _inner = inner ?? http.Client(),
      _ownsInner = inner == null {
    BrowserSession._validate(origin);
  }
  final Uri origin;
  final http.Client _inner;
  final bool _ownsInner;
  bool _closed = false;

  bool _inScope(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.host == origin.host || uri.host.endsWith('.${origin.host}'));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('This session client is closed.');
    request.followRedirects = false;
    final inScope = _inScope(request.url);
    if (BrowserSession.supported) {
      // Drop any stale caller-supplied browser cookies before looking up the
      // actual destination. Authorization/API keys remain source-owned.
      request.headers.remove('cookie');
      if (inScope) {
        final headers = await BrowserSession.headersFor(request.url);
        for (final entry in headers.entries) {
          request.headers[entry.key] = entry.value;
        }
      }
    }
    final response = await _inner.send(request);
    if (inScope) {
      await BrowserSession._receive(
        request.url,
        response.headers['set-cookie'],
      );
    }
    return response;
  }

  @override
  void close() {
    _closed = true;
    if (_ownsInner) _inner.close();
  }
}
