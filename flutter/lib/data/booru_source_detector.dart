import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/content.dart';
import 'source_http_client.dart';

typedef BooruDetectionClientFactory = http.Client Function(Uri origin);

/// Identifies supported Booru engines from native-compatible host suggestions
/// or the configured site's bounded homepage HTML. It never writes settings.
class BooruSourceDetector {
  BooruSourceDetector({
    BooruDetectionClientFactory? clientFactory,
    this.timeout = const Duration(seconds: 20),
    this.maxResponseBytes = 1024 * 1024,
    this.maxRedirects = 5,
  }) : _clientFactory = clientFactory ?? _sessionClient {
    if (timeout <= Duration.zero || maxResponseBytes < 1 || maxRedirects < 0) {
      throw ArgumentError('Detection limits must be positive.');
    }
  }

  final BooruDetectionClientFactory _clientFactory;
  final Duration timeout;
  final int maxResponseBytes;
  final int maxRedirects;

  /// Returns immediately for the same known-host suggestions as native iOS.
  /// Otherwise fetches only the site's HTTPS HTML home page.
  Future<SourceKind?> detect(
    Uri origin, {
    Future<void>? abortTrigger,
    bool allowComics = false,
  }) async {
    if (!_validInput(origin)) {
      throw const FormatException('Enter a valid HTTPS website address.');
    }
    final suggested = suggestFromHost(origin);
    if (suggested != null) return suggested;

    final client = _clientFactory(origin);
    final operation = _DetectionOperation(origin, timeout, abortTrigger);
    try {
      final html = await _loadHome(client, origin, operation);
      return recognizeHtml(html, allowComics: allowComics);
    } finally {
      operation.dispose();
      client.close();
    }
  }

  static SourceKind? suggestFromHost(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.endsWith('.booru.org')) return SourceKind.oldGelbooru;
    final normalized = host.startsWith('www.') ? host.substring(4) : host;
    return switch (normalized) {
      'safebooru.org' || 'gelbooru.com' => SourceKind.gelbooru,
      'danbooru.donmai.us' => SourceKind.danbooru,
      'yande.re' || 'konachan.com' || 'konachan.net' => SourceKind.moebooru,
      _ => null,
    };
  }

  /// Mirrors ServerType.recognizing's Booru markers and their precedence.
  static SourceKind? recognizeHtml(String html, {bool allowComics = false}) {
    if (allowComics && (_isIndexedManga(html) || _isDocumentManga(html))) {
      return SourceKind.manga;
    }
    if (RegExp(r'''Danbooru\.|content=["']Danbooru''').hasMatch(html)) {
      return SourceKind.danbooru;
    }
    if (RegExp(
      r'Gelbooru\s+Beta\s+0\.1\.11',
      caseSensitive: false,
    ).hasMatch(html)) {
      return SourceKind.oldGelbooru;
    }
    if (html.toLowerCase().contains('moebooru')) return SourceKind.moebooru;
    if (html.toLowerCase().contains('gelbooru')) return SourceKind.gelbooru;
    return null;
  }

  static http.Client _sessionClient(Uri origin) =>
      SourceHttpClient(origin: origin, allowSubdomains: true);

  static bool _isIndexedManga(String html) {
    final hasBackend = [
      RegExp(
        r'''(?:var|let|const)\s+domain\s*=\s*["']([a-z0-9-]+(?:\.[a-z0-9-]+)+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''(?:(?:https?:)?//)([a-z0-9-]+(?:\.[a-z0-9-]+)+)/(?:gg\.js(?:[?"'\s>]|$)|galleries/[0-9]+\.js(?:[?"'\s>]|$))''',
        caseSensitive: false,
      ),
      RegExp(
        r'''(?:(?:https?:)?//)(ltn\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)/common\.js(?:[?"'\s>]|$)''',
        caseSensitive: false,
      ),
    ].any((pattern) => pattern.hasMatch(html));
    if (!hasBackend) return false;
    return html.contains('.nozomi') ||
        RegExp(
          r'''/(?:common\.js|gg\.js|galleries/[0-9]+\.js)(?:[?"'\s>]|$)''',
          caseSensitive: false,
        ).hasMatch(html);
  }

  static bool _isDocumentManga(String html) {
    if (RegExp(r'/js/index\.search\.', caseSensitive: false).hasMatch(html)) {
      return true;
    }
    if (html.contains('/ajax/search') &&
        html.contains('serverConfig') &&
        html.contains('thumbServer')) {
      return true;
    }
    final assignment = RegExp(r'\b(?:const|let|var)\s+gallery\s*=\s*\{')
        .firstMatch(html);
    if (assignment == null) return false;
    final start = assignment.end - 1;
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var index = start; index < html.length; index++) {
      final character = html[index];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (character == r'\') {
          escaped = true;
        } else if (character == '"') {
          quoted = false;
        }
      } else if (character == '"') {
        quoted = true;
      } else if (character == '{') {
        depth++;
      } else if (character == '}') {
        depth--;
        if (depth == 0) {
          try {
            final value = jsonDecode(html.substring(start, index + 1));
            return value is Map &&
                value['id'] is num &&
                (value['id'] as num) > 0 &&
                value['files'] is List;
          } on FormatException {
            return false;
          }
        }
      }
    }
    return false;
  }

  Future<String> _loadHome(
    http.Client client,
    Uri origin,
    _DetectionOperation operation,
  ) async {
    var target = origin;
    final seen = <String>{};
    for (var redirects = 0; ; redirects++) {
      operation.check();
      if (!_safeTarget(target)) {
        throw const FormatException(
          'The website redirected to an unsafe address.',
        );
      }
      if (!seen.add(target.toString())) {
        throw const FormatException('The website returned a redirect loop.');
      }
      final request =
          http.AbortableRequest('GET', target, abortTrigger: operation.signal)
            ..followRedirects = false
            ..maxRedirects = 0
            ..headers['accept'] = 'text/html,application/xhtml+xml';
      final response = await operation.race(client.send(request));
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.listen((_) {}).cancel();
        if (location == null || redirects >= maxRedirects) {
          throw const FormatException('The website redirected too many times.');
        }
        target = target.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw HttpException(
          'The website returned HTTP ${response.statusCode}.',
        );
      }
      final body = await _readBody(response, operation);
      return utf8.decode(body, allowMalformed: true);
    }
  }

  Future<List<int>> _readBody(
    http.StreamedResponse response,
    _DetectionOperation operation,
  ) async {
    if (response.contentLength != null &&
        response.contentLength! > maxResponseBytes) {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('The website response is too large.');
    }
    final iterator = StreamIterator<List<int>>(response.stream);
    final bytes = BytesBuilder(copy: false);
    try {
      while (await operation.race(iterator.moveNext())) {
        final chunk = iterator.current;
        if (bytes.length + chunk.length > maxResponseBytes) {
          await iterator.cancel();
          throw const FormatException('The website response is too large.');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      await iterator.cancel();
    }
  }

  static bool _isRedirect(int code) =>
      code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  static bool _validInput(Uri uri) =>
      _safeTarget(uri) && !uri.hasQuery && !uri.hasFragment;

  static bool _safeTarget(Uri uri) =>
      uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

class _DetectionOperation {
  _DetectionOperation(this.uri, Duration timeout, Future<void>? abortTrigger) {
    _timer = Timer(timeout, () {
      timedOut = true;
      _complete();
    });
    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then<void>(
          (_) => _complete(),
          onError: (Object _, StackTrace _) => _complete(),
        ),
      );
    }
  }

  final Uri uri;
  final Completer<void> _signalCompleter = Completer<void>();
  late final Timer _timer;
  bool timedOut = false;

  Future<void> get signal => _signalCompleter.future;

  void _complete() {
    if (!_signalCompleter.isCompleted) _signalCompleter.complete();
  }

  void check() {
    if (timedOut) throw TimeoutException('Website identification timed out.');
    if (_signalCompleter.isCompleted) throw http.RequestAbortedException(uri);
  }

  Future<T> race<T>(Future<T> future) {
    check();
    return Future.any<T>([
      future,
      signal.then<T>((_) {
        if (timedOut) {
          throw TimeoutException('Website identification timed out.');
        }
        throw http.RequestAbortedException(uri);
      }),
    ]);
  }

  void dispose() => _timer.cancel();
}
