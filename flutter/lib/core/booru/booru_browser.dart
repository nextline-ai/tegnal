import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../content/content_errors.dart';
import '../content/site_account.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import 'booru_html.dart';
import 'booru_models.dart';
import '../support/perf_trace.dart';

/// One cookie of a server's browser profile, as `HTTPCookie` keeps it.
class BooruCookie {
  const BooruCookie({required this.name, required this.value, required this.domain, this.path = '/', this.isSecure = false, this.expiresDate});

  final String name;
  final String value;

  /// A leading dot covers subdomains; without one the cookie belongs to that host only.
  final String domain;
  final String path;
  final bool isSecure;
  final DateTime? expiresDate;

  /// `HTTPCookie.cookies(withResponseHeaderFields:for:)` for one `Set-Cookie` value.
  static BooruCookie? parse(String header, Uri url) {
    final Cookie cookie;
    try {
      cookie = Cookie.fromSetCookieValue(header);
    } on Object {
      return null;
    }
    final host = url.host.toLowerCase();
    var domain = host;
    final attribute = cookie.domain?.toLowerCase();
    if (attribute != null && attribute.isNotEmpty) {
      final bare = attribute.startsWith('.') ? attribute.substring(1) : attribute;
      // A server may only widen a cookie to its own domain.
      if (host != bare && !host.endsWith('.$bare')) return null;
      domain = '.$bare';
    }
    var path = cookie.path ?? '';
    if (!path.startsWith('/')) {
      final requestPath = url.path.isEmpty ? '/' : url.path;
      final slash = requestPath.lastIndexOf('/');
      path = slash <= 0 ? '/' : requestPath.substring(0, slash);
    }
    final expires = cookie.maxAge != null ? DateTime.now().add(Duration(seconds: cookie.maxAge!)) : cookie.expires;
    return BooruCookie(name: cookie.name, value: cookie.value, domain: domain, path: path, isSecure: cookie.secure, expiresDate: expires);
  }

  factory BooruCookie.fromJson(Map<String, Object?> json) => BooruCookie(
    name: json['name'] as String,
    value: json['value'] as String,
    domain: json['domain'] as String,
    path: json['path'] as String? ?? '/',
    isSecure: json['secure'] as bool? ?? false,
    expiresDate: json['expires'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['expires'] as int, isUtc: true),
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'secure': isSecure,
    if (expiresDate != null) 'expires': expiresDate!.millisecondsSinceEpoch,
  };

  bool sameIdentity(BooruCookie other) => other.name == name && other.domain == domain && other.path == path;

  @override
  bool operator ==(Object other) =>
      other is BooruCookie &&
      other.name == name &&
      other.value == value &&
      other.domain == domain &&
      other.path == path &&
      other.isSecure == isSecure &&
      other.expiresDate == expiresDate;
  @override
  int get hashCode => Object.hash(name, value, domain, path, isSecure, expiresDate);
}

/// Browser validation, API requests and media share one profile per server.
/// Comics mode's sign-in cookies and the shared web view are never used.
///
/// Cookies are sign-in material: they live in [secrets] (the device keystore in the app),
/// never in the libraries, backups or logs. Reads are served from memory.
class BooruBrowserSession {
  BooruBrowserSession({SecretStore? secrets}) : secrets = secrets ?? MemorySecretStore();

  static BooruBrowserSession shared = BooruBrowserSession();

  final SecretStore secrets;
  final _cookies = <String, List<BooruCookie>>{};
  final _challengedPages = <String, String>{};
  final _accessRevisions = <String, int>{};

  /// Removes the web view's own data for a server (its Android WebView profile) when cookies are reset.
  Future<void> Function(BooruServer server)? clearWebsiteData;

  static const defaultUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

  /// The validation browser's own user agent. Clearance cookies are bound to it, so the
  /// app sets this from its web view (`WebViewController.getUserAgent`) before requests.
  String userAgent = defaultUserAgent;

  String? challengePage(BooruServer server) => _challengedPages[server.id];

  void recordChallenge(String url, BooruServer server) {
    if (!booruSameOrigin(url, server.baseURL)) return;
    _challengedPages[server.id] = url;
  }

  void clearChallenge(BooruServer server) {
    _challengedPages.remove(server.id);
    _accessRevisions[server.id] = (_accessRevisions[server.id] ?? 0) + 1;
  }

  int accessRevision(BooruServer server) => _accessRevisions[server.id] ?? 0;

  /// A stable profile name for the server's isolated web view data.
  static String identifier(String serverID) {
    final bytes = sha256.convert(utf8.encode('tegnal.booru.profile.$serverID')).bytes.take(16).toList();
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String _key(String serverID) => 'booru.cookies.$serverID';

  List<BooruCookie> cookies(BooruServer server) => List.unmodifiable(_load(server.id));

  List<BooruCookie> _load(String serverID) => _cookies.putIfAbsent(serverID, () {
    final raw = secrets.read(_key(serverID));
    if (raw == null) return [];
    try {
      final now = DateTime.now();
      return [
        for (final item in jsonDecode(raw) as List)
          if (BooruCookie.fromJson((item as Map).cast<String, Object?>()) case final cookie when cookie.expiresDate?.isAfter(now) ?? true) cookie,
      ];
    } on Object {
      return [];
    }
  });

  void _save(String serverID) {
    final values = _cookies[serverID] ?? [];
    secrets.write(_key(serverID), values.isEmpty ? null : jsonEncode([for (final cookie in values) cookie.toJson()]));
  }

  void setCookie(BooruCookie cookie, BooruServer server) {
    final values = _load(server.id)..removeWhere(cookie.sameIdentity);
    if (cookie.expiresDate?.isAfter(DateTime.now()) ?? true) values.add(cookie);
    _save(server.id);
  }

  /// Takes the cookies the validation web view holds for the server, as a `Cookie` request header
  /// (`name=value; …`), which is all Android's cookie manager reports. They are kept host-only.
  void importCookieHeader(String? header, String url, BooruServer server) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (header == null || host.isEmpty || !booruSameOrigin(url, server.baseURL)) return;
    for (final part in header.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim(), value = part.substring(separator + 1).trim();
      if (name.isEmpty) continue;
      // A cookie the manager already holds under a wider domain keeps its scope.
      final existing = _load(server.id).where((cookie) => cookie.name == name && matches(cookie, Uri.parse(url))).firstOrNull;
      setCookie(
        BooruCookie(
          name: name,
          value: value,
          domain: existing?.domain ?? host,
          path: existing?.path ?? '/',
          isSecure: true,
          expiresDate: existing?.expiresDate,
        ),
        server,
      );
    }
  }

  static bool matches(BooruCookie cookie, Uri url, {DateTime? now}) {
    final host = url.host.toLowerCase();
    if (host.isEmpty || cookie.isSecure && url.scheme != 'https') return false;
    if (!(cookie.expiresDate?.isAfter(now ?? DateTime.now()) ?? true)) return false;
    final domain = cookie.domain.toLowerCase();
    final bare = domain.startsWith('.') ? domain.substring(1) : domain;
    if (!(host == bare || domain.startsWith('.') && host.endsWith('.$bare'))) return false;
    final path = url.path.isEmpty ? '/' : url.path;
    return path == cookie.path || path.startsWith(cookie.path) && (cookie.path.endsWith('/') || path.substring(cookie.path.length).startsWith('/'));
  }

  /// The `Cookie` header for [url], longest paths first, or null without cookies.
  String? cookieHeader(BooruServer server, Uri url) {
    final matching = _load(server.id).where((cookie) => matches(cookie, url)).toList()..sort((a, b) => b.path.length.compareTo(a.path.length));
    return matching.isEmpty ? null : matching.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  /// The headers every request for the server carries: the browser's agent, the server as
  /// referrer and the profile's cookies for [url] (the server's home without one).
  Map<String, String> requestHeaders(BooruServer server, {String? url}) {
    final target = Uri.tryParse(url ?? server.baseURL);
    final cookies = target == null ? null : cookieHeader(server, target);
    return {'User-Agent': userAgent, 'Referer': '${server.baseURL}/', 'Cookie': ?cookies};
  }

  /// `prepare(_:server:)`: the request with the profile's agent, referrer and cookies.
  void prepare(BooruRequest request, BooruServer server) {
    request.headers.removeWhere((name, _) => name.toLowerCase() == 'cookie' || name.toLowerCase() == 'user-agent' || name.toLowerCase() == 'referer');
    request.headers.addAll(requestHeaders(server, url: request.url.toString()));
  }

  void receive(Uri url, List<String> setCookies, BooruServer server) {
    final host = Uri.tryParse(server.baseURL)?.host;
    if (url.host != host) return;
    for (final header in setCookies) {
      final cookie = BooruCookie.parse(header, url);
      if (cookie != null) setCookie(cookie, server);
    }
  }

  Future<void> reset(BooruServer server) async {
    clearChallenge(server);
    BooruWebTransport.reset(server);
    _cookies[server.id] = [];
    _save(server.id);
    await clearWebsiteData?.call(server);
  }
}

/// A request as `URLRequest` holds it: the address and its headers.
class BooruRequest {
  BooruRequest(this.url, {Map<String, String>? headers}) : headers = {...?headers};
  Uri url;
  final Map<String, String> headers;

  String? header(String name) => headers.entries.where((entry) => entry.key.toLowerCase() == name.toLowerCase()).firstOrNull?.value;
}

/// A received response: its address, status, lower-case headers and body.
class BooruResponse {
  BooruResponse({required this.url, required this.statusCode, Map<String, List<String>>? headers, required this.data})
    : headers = {for (final MapEntry(:key, :value) in (headers ?? {}).entries) key.toLowerCase(): value};
  final Uri url;
  final int statusCode;
  final Map<String, List<String>> headers;
  final Uint8List data;
}

/// A hidden page of the server's validated browser. The app backs it with a web view
/// that uses the server's profile ([BooruBrowserSession.identifier]); everything else
/// about the fallback transport lives in [BooruWebTransport].
abstract interface class BooruBrowserPage {
  /// The address of the committed document, or null before the first one.
  Uri? get url;

  /// Whether [evaluate] runs in a script world the website's own scripts cannot reach (WebKit's
  /// client world). Without it, account credentials are never handed to the page.
  bool get isolatesScripts;

  /// Completes once a document has committed and finished its initial parse. Throws the
  /// load's failure ([NetworkError], [BrowserProcessTerminated]) or a timeout.
  Future<void> ready();

  /// Runs [script] as the body of an async function with [arguments] in scope and returns
  /// its result encoded as JSON.
  Future<String> evaluate(String script, Map<String, Object?> arguments);

  /// Navigates the page to [url] as a same-origin navigation and completes once the main frame
  /// committed, with the main document's response status.
  Future<int> navigate(Uri url);

  /// Stops loading and releases the page.
  void stop();
}

typedef BooruBrowserFactory = BooruBrowserPage Function(BooruServer server);

class _Browser {
  _Browser(this.page);
  final BooruBrowserPage page;

  /// Navigations replace the page's document, so each waits for the requests already
  /// running and holds new ones back until it commits.
  Future<void> _navigation = Future.value();
  final _running = <Future<void>>{};

  /// Images share at most this many slots; API requests never wait for them.
  static const imageSlots = 6;
  var _images = 0;
  final _waitingImages = Queue<Completer<void>>();

  /// Script requests run side by side: each is its own `fetch` in the page.
  Future<T> shared<T>(Future<T> Function() operation, {bool image = false}) async {
    await _navigation;
    if (image) await _imageSlot();
    try {
      final result = operation();
      final tracked = result.then<void>((_) {}, onError: (_) {});
      _running.add(tracked);
      tracked.whenComplete(() => _running.remove(tracked));
      return await result;
    } finally {
      if (image) _releaseImageSlot();
    }
  }

  Future<T> exclusive<T>(Future<T> Function() operation) {
    final running = [..._running];
    final result = _navigation.then((_) => Future.wait(running)).then((_) => operation());
    _navigation = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _imageSlot() async {
    if (_images < imageSlots) {
      _images += 1;
      return;
    }
    final waiter = Completer<void>();
    _waitingImages.add(waiter);
    await waiter.future;
  }

  void _releaseImageSlot() {
    if (_waitingImages.isNotEmpty) {
      _waitingImages.removeFirst().complete();
    } else {
      _images -= 1;
    }
  }
}

/// Keep requests in the browser after validation: some servers bind clearance to the
/// browser's connection characteristics, not just its Cookie header.
abstract final class BooruWebTransport {
  /// Creates a hidden page for a server. Null until the app installs its web view factory;
  /// without one, requests stay on direct connections.
  static BooruBrowserFactory? factory;
  static final _sessions = <String, _Browser>{};

  static bool get isAvailable => factory != null;
  static bool hasSession(BooruServer server) => _sessions.containsKey(server.id);

  /// Where it is remembered which servers' direct connections met a browser check, so a
  /// later launch starts their hidden page right away. Null keeps it in memory only.
  static Preferences? preferences;
  static final _directChallenged = <String, DateTime>{};
  static const _challengeMemory = Duration(minutes: 30);
  static String _challengeKey(BooruServer server) => 'booru.directChallengedUntil.${server.id}';

  /// Whether requests for [server] should skip the direct attempt: it met a browser check
  /// recently, and every direct try would only add a round trip before the browser.
  static bool prefersBrowser(BooruServer server, {DateTime? now}) {
    if (!isAvailable) return false;
    var until = _directChallenged[server.id];
    if (until == null) {
      final stored = preferences?.integerOrNull(_challengeKey(server));
      if (stored != null) until = _directChallenged[server.id] = DateTime.fromMillisecondsSinceEpoch(stored);
    }
    return until != null && until.isAfter(now ?? DateTime.now());
  }

  static void directChallenged(BooruServer server, {DateTime? now}) {
    final until = (now ?? DateTime.now()).add(_challengeMemory);
    _directChallenged[server.id] = until;
    preferences?.set(_challengeKey(server), until.millisecondsSinceEpoch);
  }

  /// Starts loading the hidden page of a server that needs it, before its first request.
  static void warm(BooruServer server) {
    if (prefersBrowser(server)) _browser(server);
  }

  /// Keeps the validated page itself, even while it still loads ads or subresources.
  static void adopt(BooruBrowserPage page, BooruServer server) {
    final url = page.url;
    if (url == null || !booruSameOrigin(url.toString(), server.baseURL)) return;
    final previous = _sessions[server.id];
    if (previous != null && !identical(previous.page, page)) previous.page.stop();
    _sessions[server.id] = _Browser(page);
    BooruBrowserSession.shared.clearChallenge(server);
  }

  static void reset(BooruServer server) => _sessions.remove(server.id)?.page.stop();

  /// Returning to the visible browser reclaims its page.
  static void release(BooruBrowserPage page, BooruServer server) {
    if (identical(_sessions[server.id]?.page, page)) _sessions.remove(server.id);
  }

  static bool sameOrigin(String lhs, String rhs) => booruSameOrigin(lhs, rhs);

  static _Browser _browser(BooruServer server) {
    final existing = _sessions[server.id];
    if (existing != null) return existing;
    final make = factory;
    if (make == null) throw const BooruError(BooruErrorKind.unsupported);
    return _sessions[server.id] = _Browser(make(server));
  }

  static Future<T> retryConnection<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } catch (error) {
        if (attempt >= 2 || !BooruConnectionRetry.isTransient(error)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  /// A same-origin API request through the page's own `fetch`.
  static Future<BooruResponse> data(BooruRequest request, BooruServer server, {Uri? publicURL}) {
    if (!sameOrigin(request.url.toString(), server.baseURL)) throw const BooruError(BooruErrorKind.invalidServer);
    final browser = _browser(server);
    return PerfTrace.span(
      'booru browser fetch',
      () => browser.shared(() => retryConnection(() => _fetch(request, browser.page, publicURL: publicURL))),
      detail: request.url.path,
    );
  }

  static Future<BooruResponse> _fetch(BooruRequest request, BooruBrowserPage page, {Uri? publicURL}) async {
    await page.ready();
    final current = page.url;
    if (current == null || !sameOrigin(current.toString(), request.url.toString())) throw const BooruError(BooruErrorKind.validationRequired);
    // Page scripts can read what a shared script world passes to fetch, so an account's
    // credentials only travel through an isolated world.
    final url = page.isolatesScripts ? request.url : publicURL ?? request.url;
    final headers = {
      for (final MapEntry(:key, :value) in request.headers.entries)
        if (key.toLowerCase() == 'accept' || key.toLowerCase() == 'authorization' && page.isolatesScripts) key: value,
    };
    final result = BooruBrowserScripts.fetchResult(await page.evaluate(BooruBrowserScripts.fetch, {'address': url.toString(), 'headers': headers}));
    return BooruResponse(url: url, statusCode: result.$1, data: Uint8List.fromList(utf8.encode(result.$2)));
  }

  /// Public galleries sometimes allow document navigation while rejecting API requests.
  /// Reads the rendered document in the validated browser, with serialized navigation.
  static Future<BooruResponse> document(BooruRequest request, BooruServer server) {
    if (!sameOrigin(request.url.toString(), server.baseURL)) throw const BooruError(BooruErrorKind.invalidServer);
    final browser = _browser(server);
    return browser.exclusive(() => retryConnection(() => _document(request.url, browser.page, server)));
  }

  static Future<BooruResponse> _document(Uri url, BooruBrowserPage page, BooruServer server) async {
    final status = await page.navigate(url);
    BooruResponse? lastChallenge;
    for (var attempt = 0; attempt < 300; attempt++) {
      final current = page.url;
      if (current != null && sameOrigin(current.toString(), server.baseURL)) {
        final html = jsonDecode(await page.evaluate(BooruBrowserScripts.outerHTML, const {}));
        if (html is String) {
          final data = Uint8List.fromList(utf8.encode(html));
          if (data.length >= 12000000) throw const BooruError(BooruErrorKind.invalidResponse);
          final response = BooruResponse(url: current, statusCode: status, data: data);
          // Let the website finish its normal navigation and scripts. Interactive
          // checks still require the visible Validate Client browser.
          if (!BooruClientSupport.needsBrowser(data, status)) return response;
          lastChallenge = response;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (lastChallenge != null) return lastChallenge;
    throw const NetworkError(NetworkErrorCode.timedOut);
  }

  static Future<Uint8List> imageData(String url, BooruServer server) {
    final target = Uri.tryParse(url);
    if (target == null || target.scheme != 'https' || target.userInfo.isNotEmpty) throw const BooruError(BooruErrorKind.invalidServer);
    final browser = _browser(server);
    return PerfTrace.span(
      'booru browser image',
      () => browser.shared(image: true, () async {
        await browser.page.ready();
        return BooruBrowserScripts.imageResult(await browser.page.evaluate(BooruBrowserScripts.image, {'address': url}));
      }),
    );
  }
}

/// The scripts the hidden page runs, and how their JSON results read.
abstract final class BooruBrowserScripts {
  /// Redirects are rejected before credentials can leave this origin.
  static const fetch = '''
const target = new URL(address);
if (target.origin !== location.origin || target.protocol !== 'https:') throw new Error('Origin mismatch');
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 25000);
try {
    const response = await fetch(target.href, {method: 'GET', headers,
        credentials: 'include', redirect: 'error', signal: controller.signal});
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let body = '', size = 0;
    while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > 12000000) { await reader.cancel(); throw new Error('Response too large'); }
        body += decoder.decode(chunk.value, {stream: true});
    }
    body += decoder.decode();
    return {status: response.status, body};
} catch (error) {
    if (error.name === 'AbortError') return {networkError: 'timeout'};
    if (error.name === 'TypeError') return {networkError: 'connection'};
    throw error;
} finally { clearTimeout(timer); }
''';

  static const image = '''
const target = new URL(address);
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 25000);
try {
    const response = await fetch(target.href, {credentials: target.origin === location.origin ? 'include' : 'omit',
        redirect: 'error', signal: controller.signal});
    if (!response.ok) throw new Error('Image unavailable');
    const reader = response.body.getReader();
    let size = 0, chunks = [];
    while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > 64000000) { await reader.cancel(); throw new Error('Image too large'); }
        chunks.push(chunk.value);
    }
    const blob = new Blob(chunks);
    return await new Promise((resolve, reject) => {
        const file = new FileReader(); file.onload = () => resolve(file.result);
        file.onerror = reject; file.readAsDataURL(blob);
    });
} finally { clearTimeout(timer); }
''';

  static const outerHTML = "return document.readyState === 'loading' ? null : document.documentElement.outerHTML;";

  /// Whether the visible page still shows a browser check.
  static const challenge = '''
if (document.readyState === 'loading') return null;
return !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage')
    || /^(just a moment|checking your browser|attention required)/i.test(document.title);
''';

  /// The status and text body of a [fetch] result.
  static (int, String) fetchResult(String json) {
    final Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException {
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    if (value is Map && value['networkError'] is String) {
      throw NetworkError(value['networkError'] == 'timeout' ? NetworkErrorCode.timedOut : NetworkErrorCode.networkConnectionLost);
    }
    if (value is! Map || value['status'] is! num || value['body'] is! String) throw const BooruError(BooruErrorKind.invalidResponse);
    return ((value['status'] as num).toInt(), value['body'] as String);
  }

  /// The bytes of an [image] result (a data URL).
  static Uint8List imageResult(String json) {
    final value = jsonDecode(json);
    if (value is! String) throw const BooruError(BooruErrorKind.invalidResponse);
    final comma = value.indexOf(',');
    if (comma < 0) throw const BooruError(BooruErrorKind.invalidResponse);
    try {
      return base64Decode(value.substring(comma + 1));
    } on FormatException {
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
  }
}

/// Retry only transport failures; sign-in, challenges and HTTP errors need their own UI.
abstract final class BooruConnectionRetry {
  static bool isTransient(Object error) =>
      error is NetworkError &&
      const [
        NetworkErrorCode.secureConnectionFailed,
        NetworkErrorCode.networkConnectionLost,
        NetworkErrorCode.timedOut,
        NetworkErrorCode.cannotConnectToHost,
      ].contains(error.code);
}

abstract final class BooruConnectionMessage {
  static String describe(Object error) => ContentError.withConnectionHelp(_detail(error), error);

  static String _detail(Object error) {
    if (error is NetworkError && error.code == NetworkErrorCode.secureConnectionFailed) {
      return L10n.text('Unable to connect securely. Open Validate Client and complete the server’s browser check, then tap Done to retry.');
    }
    if (error is NetworkError && error.code == NetworkErrorCode.networkConnectionLost) {
      return L10n.text('The server interrupted the connection. Open Validate Client, complete the browser check, then tap Done to retry.');
    }
    if (error is BrowserProcessTerminated) return L10n.text('The browser connection was interrupted. Open Validate Client and try again.');
    if (error is BooruError) return error.errorDescription;
    return ContentError.message(error is NetworkError ? NetworkError(NetworkErrorCode.unknown) : error);
  }
}

enum BooruNavigationDecision { allow, cancel, loadInPlace }

/// The Validate Client page's state, driven by its web view's callbacks.
class BooruValidationState extends ChangeNotifier {
  BooruValidationState(this.server);

  final BooruServer server;
  Uri? address;
  bool loading = false;
  String? error;
  bool canGoBack = false;
  bool canGoForward = false;
  bool challengeStalled = false;
  bool _challengePresent = false;
  bool _inspectedPage = false;
  int _retryCount = 0;
  Uri? _requestedURL;
  bool _active = true;
  DateTime? _monitorStart;

  bool get challengePresent => _challengePresent;
  bool get isMonitoring => _monitorStart != null;

  /// The validated page can serve as the server's transport.
  bool get canAdoptSession => _inspectedPage && error == null && !_challengePresent && address != null && booruSameOrigin(address.toString(), server.baseURL);

  void setActive(bool value) {
    _active = value;
    if (!value) {
      _monitorStart = null;
    } else if (loading || _challengePresent) {
      _startMonitoring();
    }
  }

  void _startMonitoring() => _monitorStart = _active ? DateTime.now() : null;

  /// Starts a load; returns the address the web view loads.
  Uri load([Uri? url]) {
    _retryCount = 0;
    _requestedURL = url ?? Uri.parse(server.baseURL);
    error = null;
    loading = true;
    challengeStalled = false;
    _challengePresent = false;
    _inspectedPage = false;
    _startMonitoring();
    notifyListeners();
    return _requestedURL!;
  }

  void didStart() {
    loading = true;
    error = null;
    _inspectedPage = false;
    _startMonitoring();
    notifyListeners();
  }

  void didFinish(Uri? url, {bool canGoBack = false, bool canGoForward = false}) {
    loading = false;
    address = url;
    this.canGoBack = canGoBack;
    this.canGoForward = canGoForward;
    notifyListeners();
  }

  /// The result of [BooruBrowserScripts.challenge] on the page at [url] (null while loading).
  void inspected(Uri url, bool? present) {
    if (present == null || !booruSameOrigin(url.toString(), server.baseURL)) return;
    _inspectedPage = true;
    address = url;
    _challengePresent = present;
    if (!present) challengeStalled = false;
    notifyListeners();
  }

  /// Called every two seconds while [isMonitoring], after inspecting the page. A check still
  /// unresolved after 25 seconds offers reload and reset.
  void monitorTick([DateTime? now]) {
    final start = _monitorStart;
    if (start == null) return;
    if ((now ?? DateTime.now()).difference(start) >= const Duration(seconds: 25) && (_challengePresent || !_inspectedPage || loading)) {
      challengeStalled = true;
      loading = false;
    } else if (_inspectedPage && !_challengePresent && !loading) {
      challengeStalled = false;
      _monitorStart = null;
    }
    notifyListeners();
  }

  /// A failed load. Returns the delay after which the web view reloads [retryURL] for a transient failure.
  Duration? failed(Object failure) {
    if (failure is NetworkError && failure.code == NetworkErrorCode.cancelled) return null;
    if (_active && BooruConnectionRetry.isTransient(failure) && _retryCount < 2 && _requestedURL != null) {
      _retryCount += 1;
      loading = true;
      error = null;
      notifyListeners();
      return Duration(milliseconds: _retryCount * 500);
    }
    _monitorStart = null;
    loading = false;
    error = BooruConnectionMessage.describe(failure);
    notifyListeners();
    return null;
  }

  Uri? get retryURL => _requestedURL;

  void processTerminated() {
    _monitorStart = null;
    loading = false;
    error = L10n.text('Unable to Load');
    notifyListeners();
  }

  /// HTTPS pages (and blank frames) only; a new window opens in place.
  static BooruNavigationDecision navigation(Uri url, {required bool newWindow}) {
    final allowed = url.scheme == 'https' && url.userInfo.isEmpty || url.toString() == 'about:blank';
    if (allowed && newWindow) return BooruNavigationDecision.loadInPlace;
    return allowed ? BooruNavigationDecision.allow : BooruNavigationDecision.cancel;
  }
}

/// The client's response checks, shared with the browser transport.
abstract final class BooruClientSupport {
  static bool needsBrowser(Uint8List data, int? statusCode) {
    if (statusCode == 403) return true;
    final prefix = utf8.decode(data.length > 4096 ? data.sublist(0, 4096) : data, allowMalformed: true).toLowerCase();
    return prefix.contains('cf-chl-') || prefix.contains('just a moment') || prefix.contains('checking your browser');
  }
}
