import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'content_errors.dart';
import 'content_url.dart';
import 'keyed_catalog_source.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// A received response. Header names are lower case.
class ContentResponse {
  ContentResponse({required this.url, required this.statusCode, Map<String, List<String>>? headers})
    : headers = {for (final MapEntry(:key, :value) in (headers ?? {}).entries) key.toLowerCase(): value};

  final Uri url;
  final int statusCode;
  final Map<String, List<String>> headers;

  String? header(String name) => headers[name.toLowerCase()]?.firstOrNull;

  /// `HTTPURLResponse.mimeType`: the media type without parameters, lower case.
  String? get mimeType {
    final type = header('content-type');
    if (type == null || type.isEmpty) return null;
    return type.split(';').first.trim().toLowerCase();
  }

  /// `expectedContentLength`, or -1 when the length is unknown.
  int get expectedContentLength => int.tryParse(header('content-length') ?? '') ?? -1;
}

class ContentResult {
  const ContentResult(this.data, this.response);
  final Uint8List data;
  final ContentResponse response;
}

/// One request as sent, without redirects being followed.
class HttpExchange {
  HttpExchange({required this.method, required this.url, required this.headers, this.body, required this.timeout});
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;
}

/// The response head plus a body to read as far as the transport allows.
class HttpReply {
  HttpReply({required this.statusCode, required this.headers, required this.body, this.abort});
  final int statusCode;
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;

  /// Discards a body the transport refused before reading it, so its connection is released.
  final void Function()? abort;
}

/// The network below the transport. Tests replace it the way the Swift tests install a `URLProtocol`.
abstract interface class HttpFetcher {
  Future<HttpReply> send(HttpExchange request);
}

/// A hidden browser session, which some filtered networks let through when direct
/// connections fail. Native WebKit has no Dart counterpart yet.
// TODO(platform): implement with an Android WebView session (see ContentBrowserTransport.swift) and verify on a device.
typedef BrowserFetch = Future<ContentResult> Function(Uri url, Uri origin, int limit, (int, int)? range, Duration timeout);
typedef BrowserPost = Future<ContentResult> Function(Uri url, Uri origin, List<int> body, String contentType, int limit, Duration timeout);

/// Bounded downloads. Redirects to hosts outside the connected site are refused before they are followed.
class ContentTransport {
  ContentTransport({HttpFetcher? fetcher, this.browserFetch, this.browserPost}) : fetcher = fetcher ?? IoHttpFetcher();

  static ContentTransport shared = ContentTransport();

  final HttpFetcher fetcher;
  final BrowserFetch? browserFetch;
  final BrowserPost? browserPost;
  final _browserOrigins = <String>{};
  final _foreignRedirects = <String, Uri>{};

  static const _userAgent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1';

  static bool allows(Uri url) {
    if (url.scheme != 'https' || !ContentURL.hasNoCredentials(url) || url.host.isEmpty) return false;
    final host = url.host.toLowerCase();
    if (!ContentURL.usesDefaultPort(url)) {
      // Volunteer image hosts of keyed catalogs listen on their own ports.
      return MangaUrls.backend == MangaBackend.keyed && MangaUrls.allowsMedia(host) && KeyedCatalogSource.safeMediaURL(url);
    }
    final configured = MangaUrls.configuredHost;
    if (configured.isEmpty) return false;
    if (host == configured || host.endsWith('.$configured')) return true;
    final cdn = MangaUrls.cdnHost;
    if (cdn.isNotEmpty && (host == cdn || host.endsWith('.$cdn'))) return true;
    final dataHost = MangaUrls.dataHost;
    if (dataHost.isNotEmpty && (host == dataHost || host.endsWith('.$dataHost'))) return true;
    return MangaUrls.allowsMedia(host);
  }

  /// Where the site tried to send a request it was refused to follow.
  Uri? foreignRedirect(Uri url) => _foreignRedirects[url.toString()];

  Future<ContentResult> get(Uri url, {required int limit, (int, int)? range, int? galleryID, Duration timeout = const Duration(seconds: 20)}) async {
    if (!allows(url) || limit <= 0) throw const NetworkError(NetworkErrorCode.unsupportedURL);
    final site = MangaUrls.home;
    var attempt = 0;
    while (true) {
      if (MangaUrls.home != site) throw const CancellationError();
      try {
        final result = await _getOnce(url, site: site, limit: limit, range: range, galleryID: galleryID, timeout: timeout);
        if (MangaUrls.home != site) throw const CancellationError();
        return result;
      } catch (error) {
        if (MangaUrls.home != site) throw const CancellationError();
        if (attempt >= 2 || !isTransient(error)) rethrow;
        attempt += 1;
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
  }

  Future<ContentResult> _getOnce(Uri url, {required String site, required int limit, (int, int)? range, int? galleryID, required Duration timeout}) async {
    final origin = ContentURL.parse(site);
    final browserFetch = this.browserFetch;
    if (_browserOrigins.contains(site) && url.host == MangaUrls.configuredHost && origin != null && browserFetch != null) {
      try {
        return await browserFetch(url, origin, limit, range, timeout);
      } catch (error) {
        // Filtered networks come and go; a browser that cannot connect hands the request back.
        if (MangaUrls.home != site || !isTransient(error)) rethrow;
        final result = await _direct(url, limit: limit, range: range, galleryID: galleryID, timeout: timeout);
        _browserOrigins.remove(site);
        return result;
      }
    }
    try {
      return await _direct(url, limit: limit, range: range, galleryID: galleryID, timeout: timeout);
    } catch (error) {
      if (MangaUrls.home != site || error is! NetworkError || origin == null || browserFetch == null) rethrow;
      final onSite = url.host == MangaUrls.configuredHost;
      final fallback =
          [NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.networkConnectionLost].contains(error.code) ||
          (onSite &&
              [
                NetworkErrorCode.timedOut,
                NetworkErrorCode.cannotConnectToHost,
                NetworkErrorCode.cannotFindHost,
                NetworkErrorCode.dnsLookupFailed,
              ].contains(error.code));
      if (!fallback) rethrow;
      final result = await browserFetch(url, origin, limit, range, timeout);
      if (url.host == origin.host) _browserOrigins.add(site);
      return result;
    }
  }

  static bool isTransient(Object error) {
    if (error is NetworkError) {
      return const [
        NetworkErrorCode.secureConnectionFailed,
        NetworkErrorCode.networkConnectionLost,
        NetworkErrorCode.timedOut,
        NetworkErrorCode.cannotConnectToHost,
        NetworkErrorCode.cannotFindHost,
        NetworkErrorCode.dnsLookupFailed,
      ].contains(error.code);
    }
    return error is BrowserProcessTerminated;
  }

  /// Sends a form or JSON body to the connected site, through the browser when the network only lets it reach the site.
  Future<ContentResult> post(
    Uri url, {
    required List<int> body,
    required String contentType,
    required int limit,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!allows(url) || limit <= 0) throw const NetworkError(NetworkErrorCode.unsupportedURL);
    final site = MangaUrls.home;
    final origin = ContentURL.parse(site);
    final browserPost = this.browserPost;
    if (_browserOrigins.contains(site) && url.host == MangaUrls.configuredHost && origin != null && browserPost != null) {
      return browserPost(url, origin, body, contentType, limit, timeout);
    }
    try {
      return await _direct(url, limit: limit, galleryID: null, timeout: timeout, body: body, contentType: contentType);
    } catch (error) {
      final fallback =
          error is NetworkError &&
          const [
            NetworkErrorCode.secureConnectionFailed,
            NetworkErrorCode.networkConnectionLost,
            NetworkErrorCode.timedOut,
            NetworkErrorCode.cannotConnectToHost,
            NetworkErrorCode.cannotFindHost,
            NetworkErrorCode.dnsLookupFailed,
          ].contains(error.code);
      if (MangaUrls.home != site || url.host != MangaUrls.configuredHost || !fallback || origin == null || browserPost == null) rethrow;
      final result = await browserPost(url, origin, body, contentType, limit, timeout);
      _browserOrigins.add(site);
      return result;
    }
  }

  Future<ContentResult> _direct(
    Uri url, {
    required int limit,
    (int, int)? range,
    int? galleryID,
    required Duration timeout,
    List<int>? body,
    String? contentType,
  }) async {
    final headers = <String, String>{
      'user-agent': _userAgent,
      'referer': galleryID == null ? MangaUrls.home : MangaUrls.readerUrl(galleryID),
      'content-type': ?contentType,
      if (range != null) 'range': 'bytes=${range.$1}-${range.$2 - 1}',
    };
    final cookies = SiteAccount.cookieHeader(url);
    if (cookies != null) headers['cookie'] = cookies;
    var method = body == null ? 'GET' : 'POST';
    var current = url;
    var sentBody = body;
    for (var redirects = 0; ; redirects++) {
      final reply = await fetcher.send(HttpExchange(method: method, url: current, headers: headers, body: sentBody, timeout: timeout));
      final location = reply.headers.entries.where((entry) => entry.key.toLowerCase() == 'location').firstOrNull?.value.firstOrNull;
      if (reply.statusCode >= 300 && reply.statusCode < 400 && location != null && redirects < 10) {
        final target = current.resolve(location);
        if (allows(target)) {
          reply.abort?.call();
          if ([301, 302, 303].contains(reply.statusCode) && method == 'POST') {
            method = 'GET';
            sentBody = null;
            headers.remove('content-type');
          }
          current = target;
          continue;
        }
        if (_foreignRedirects.length > 16) _foreignRedirects.clear();
        _foreignRedirects[url.toString()] = target;
      }
      final response = ContentResponse(url: current, statusCode: reply.statusCode, headers: reply.headers);
      SiteAccount.storeResponse(current, response.headers['set-cookie'] ?? const []);
      if (![200, 206, 416].contains(response.statusCode)) {
        reply.abort?.call();
        throw ContentError.unavailable(response.statusCode);
      }
      if (response.statusCode == 416) {
        reply.abort?.call();
        return ContentResult(Uint8List(0), response);
      }
      if (response.expectedContentLength > limit) {
        reply.abort?.call();
        throw ContentError.tooLarge;
      }
      final data = BytesBuilder(copy: false);
      try {
        await for (final chunk in reply.body.timeout(timeout)) {
          // Leaving the loop cancels the rest of the download.
          if (chunk.length > limit - data.length) throw ContentError.tooLarge;
          data.add(chunk);
        }
      } on TimeoutException {
        throw const NetworkError(NetworkErrorCode.timedOut);
      } on IOException catch (error) {
        throw IoHttpFetcher.networkError(error);
      }
      return ContentResult(data.takeBytes(), response);
    }
  }

  static bool backendConnectionFailed(Object error) =>
      error is NetworkError &&
      const [
        NetworkErrorCode.cannotFindHost,
        NetworkErrorCode.dnsLookupFailed,
        NetworkErrorCode.cannotConnectToHost,
        NetworkErrorCode.secureConnectionFailed,
        NetworkErrorCode.networkConnectionLost,
        NetworkErrorCode.timedOut,
      ].contains(error.code);

  /// Resolve once before the first data request, then reuse the site's saved
  /// endpoints. Refresh only when the saved endpoint actually stops responding.
  Future<ContentResult> getData(String path, {required int limit, (int, int)? range, int? galleryID}) async {
    final site = MangaUrls.home;
    if (site.isEmpty) throw const NetworkError(NetworkErrorCode.unsupportedURL);
    await MangaUrls.resolveBackend(transport: this);
    if (MangaUrls.home != site) throw const CancellationError();
    final host = MangaUrls.dataHost;
    final target = ContentURL.parse(MangaUrls.dataBaseURL + path);
    if (target == null) throw const NetworkError(NetworkErrorCode.badURL);
    try {
      return await get(target, limit: limit, range: range, galleryID: galleryID);
    } catch (error) {
      final connectionFailed = backendConnectionFailed(error);
      final endpointRemoved =
          error is ContentError &&
          (error.isUnavailable(403) || error.isUnavailable(404)) &&
          (path == 'gg.js' || path.endsWith('.nozomi') || path == 'galleriesindex/version');
      if (!(connectionFailed || endpointRemoved) || MangaUrls.home != site) rethrow;
      if (MangaUrls.dataHost == host) await MangaUrls.resolveBackend(transport: this, force: true);
      if (MangaUrls.home != site) throw const CancellationError();
      final updated = ContentURL.parse(MangaUrls.dataBaseURL + path);
      if (MangaUrls.dataHost == host || updated == null) rethrow;
      return get(updated, limit: limit, range: range, galleryID: galleryID);
    }
  }
}

/// `dart:io` connections with an ephemeral, cookie-free client.
class IoHttpFetcher implements HttpFetcher {
  IoHttpFetcher()
    : _client = HttpClient()
        ..maxConnectionsPerHost = 6
        ..autoUncompress = true;

  final HttpClient _client;

  @override
  Future<HttpReply> send(HttpExchange request) async {
    _client.connectionTimeout = request.timeout;
    try {
      final outgoing = await _client.openUrl(request.method, request.url).timeout(request.timeout);
      outgoing.followRedirects = false;
      for (final MapEntry(:key, :value) in request.headers.entries) {
        outgoing.headers.set(key, value, preserveHeaderCase: true);
      }
      final body = request.body;
      if (body != null) {
        outgoing.contentLength = body.length;
        outgoing.add(body);
      }
      final response = await outgoing.close().timeout(request.timeout);
      final headers = <String, List<String>>{};
      response.headers.forEach((name, values) => headers[name] = values);
      return HttpReply(statusCode: response.statusCode, headers: headers, body: response, abort: () => response.listen(null).cancel());
    } on TimeoutException {
      throw const NetworkError(NetworkErrorCode.timedOut);
    } on IOException catch (error) {
      throw networkError(error);
    }
  }

  /// The `URLError` code a `dart:io` failure corresponds to.
  static NetworkError networkError(IOException error) {
    final message = error.toString();
    if (error is HandshakeException || error is TlsException) {
      return NetworkError(
        message.contains('CERTIFICATE_VERIFY_FAILED') ? NetworkErrorCode.serverCertificateUntrusted : NetworkErrorCode.secureConnectionFailed,
      );
    }
    if (error is SocketException) {
      if (message.contains('Failed host lookup') || message.contains('No address associated')) return const NetworkError(NetworkErrorCode.cannotFindHost);
      if (message.contains('Network is unreachable')) return const NetworkError(NetworkErrorCode.notConnectedToInternet);
      if (message.contains('timed out')) return const NetworkError(NetworkErrorCode.timedOut);
      if (message.contains('reset') || message.contains('Broken pipe')) return const NetworkError(NetworkErrorCode.networkConnectionLost);
      return const NetworkError(NetworkErrorCode.cannotConnectToHost);
    }
    if (error is HttpException) return const NetworkError(NetworkErrorCode.networkConnectionLost);
    return const NetworkError(NetworkErrorCode.unknown);
  }
}
