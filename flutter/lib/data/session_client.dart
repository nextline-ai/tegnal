import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/content.dart';

/// Android WebView owns this device's browser session. Cookies are obtained for
/// one concrete URL at a time and are never part of source or backup metadata.
class BrowserSession {
  static const _channel = MethodChannel('work.nextline.tegnal/browser');

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
      try {
        await _channel.invokeMethod<void>('open', {
          'url': url.toString(),
          'labels': labels,
        });
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

  static Future<void> _receive(Uri uri, String? header) async {
    if (!supported || header == null || header.isEmpty) return;
    // An Expires date contains a comma but no following cookie-name=value.
    final values = header.split(RegExp(r',(?=\s*[^;,=\s]+=)'));
    try {
      await _channel.invokeMethod<void>('receiveCookies', {
        'url': uri.toString(),
        'cookies': values,
      });
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
