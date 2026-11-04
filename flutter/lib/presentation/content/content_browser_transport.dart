import 'dart:convert';
import 'dart:typed_data';

import 'package:webview_flutter/webview_flutter.dart';

import '../../core/content/content_errors.dart';
import '../../core/content/content_transport.dart';
import '../../core/content/manga_urls.dart';
import '../../core/content/site_account.dart';
import '../browser/hidden_web_page.dart';

/// `ContentBrowserTransport`: some network filters let a browser through where a plain app
/// connection is cut. Requests then go out from a hidden page of the connected site, one per
/// site, through the page's own `fetch`.
abstract final class ContentBrowserTransport {
  static final _sessions = <String, HiddenWebPage>{};

  /// A sign-in or sign-out changes the cookies a page was started with.
  static void reset() {
    for (final page in _sessions.values) {
      page.stop();
    }
    _sessions.clear();
  }

  static Future<ContentResult> get(Uri url, Uri origin, int limit, (int, int)? range, Duration timeout) =>
      _fetch(url, origin, limit: limit, range: range, timeout: timeout);

  static Future<ContentResult> post(Uri url, Uri origin, List<int> body, String contentType, int limit, Duration timeout) =>
      _fetch(url, origin, limit: limit, timeout: timeout, body: body, contentType: contentType);

  static Future<HiddenWebPage> _page(Uri origin) async {
    final key = origin.toString();
    final existing = _sessions[key];
    if (existing != null && !existing.isStopped) return existing;
    reset();
    // Account cookies go in without an expiry, so the web view keeps them only in memory.
    final host = origin.host.toLowerCase();
    final manager = WebViewCookieManager();
    for (final cookie in SiteAccount.browserCookies(host)) {
      await manager.setCookie(WebViewCookie(name: cookie.name, value: cookie.value, domain: host));
    }
    // Requests need only a document of the site's origin; its robots file loads without the
    // site's scripts, images and ads.
    return _sessions[key] = HiddenWebPage(origin.resolve('/robots.txt'), scriptFailure: () => ContentError.invalidResponse);
  }

  static Future<ContentResult> _fetch(
    Uri url,
    Uri origin, {
    required int limit,
    required Duration timeout,
    (int, int)? range,
    List<int>? body,
    String? contentType,
  }) async {
    if (!ContentTransport.allows(url) || origin.toString() != MangaUrls.home) throw const NetworkError(NetworkErrorCode.unsupportedURL);
    final page = await _page(origin);
    try {
      await page.ready();
    } catch (_) {
      if (identical(_sessions[origin.toString()], page)) {
        page.stop();
        _sessions.remove(origin.toString());
      }
      rethrow;
    }
    final raw = await page.evaluate(_script, {
      'address': url.toString(),
      'limit': limit,
      'timeout': timeout.inMilliseconds,
      'range': range == null ? '' : 'bytes=${range.$1}-${range.$2 - 1}',
      'body': body == null ? null : utf8.decode(body, allowMalformed: true),
      'contentType': contentType ?? '',
    }, timeout: timeout + const Duration(seconds: 5));
    if (origin.toString() != MangaUrls.home || !ContentTransport.allows(url)) throw const CancellationError();
    final value = jsonDecode(raw);
    if (value is Map && value['tooLarge'] == true) throw ContentError.tooLarge;
    if (value is Map && value['networkError'] is String) {
      throw NetworkError(value['networkError'] == 'timeout' ? NetworkErrorCode.timedOut : NetworkErrorCode.networkConnectionLost);
    }
    if (value is! Map || value['status'] is! num || value['body'] is! String) throw ContentError.invalidResponse;
    final Uint8List data;
    try {
      data = base64Decode(value['body'] as String);
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (data.length > limit) throw ContentError.tooLarge;
    final status = (value['status'] as num).toInt();
    if (![200, 206, 416].contains(status)) throw ContentError.unavailable(status);
    return ContentResult(
      data,
      ContentResponse(
        url: url,
        statusCode: status,
        headers: {
          'content-type': ['${value['mime'] ?? ''}'],
          'content-range': ['${value['range'] ?? ''}'],
          'content-length': ['${data.length}'],
        },
      ),
    );
  }

  /// The native script: same-origin requests carry the page's cookies, others go without.
  static const _script = '''
const target = new URL(address);
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), timeout);
try {
    const headers = {};
    if (range) headers.Range = range;
    if (contentType) headers['Content-Type'] = contentType;
    const response = await fetch(target.href, {headers, redirect: 'error', method: body === null ? 'GET' : 'POST',
        body: body === null ? undefined : body,
        credentials: target.origin === location.origin ? 'include' : 'omit', signal: controller.signal});
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.length;
        if (size > limit) { await reader.cancel(); return {tooLarge: true}; }
        chunks.push(chunk.value);
    }
    let binary = '';
    for (const chunk of chunks) {
        for (let offset = 0; offset < chunk.length; offset += 8192)
            binary += String.fromCharCode(...chunk.subarray(offset, offset + 8192));
    }
    return {status: response.status, body: btoa(binary),
        mime: response.headers.get('content-type') ?? '', range: response.headers.get('content-range') ?? ''};
} catch (error) {
    if (error.name === 'AbortError') return {networkError: 'timeout'};
    if (error.name === 'TypeError') return {networkError: 'connection'};
    throw error;
} finally {
    clearTimeout(timer);
}
''';
}
