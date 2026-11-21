import 'dart:async';

import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_models.dart';
import '../../core/content/content_errors.dart';
import '../../core/support/perf_trace.dart';
import '../browser/hidden_web_page.dart';

/// [BooruBrowserPage] on an off-screen Android web view. It shares the app's cookie store
/// with the Validate Client browser, and its requests carry the browser's own connection,
/// which some servers require beyond a cookie.
class WebViewBooruPage implements BooruBrowserPage {
  WebViewBooruPage(this.server) {
    final watch = Stopwatch()..start();
    // Requests need only a document of the server's origin. Its plain-text robots file loads
    // without the site's scripts, images and ads; a server without one serves its home page.
    final start = _start = Uri.parse(server.baseURL).resolve('/robots.txt');
    _page = HiddenWebPage(start, scriptFailure: () => const BooruError(BooruErrorKind.invalidResponse));
    _page.ready().then((_) => PerfTrace.log('booru page load', watch.elapsed, detail: start.path), onError: (_) {});
  }

  final BooruServer server;
  late final HiddenWebPage _page;
  late final Uri _start;
  Future<void>? _reload;

  @override
  Uri? get url => _page.url;

  /// Android has no separate script world, so account credentials never reach the page.
  @override
  bool get isolatesScripts => false;

  @override
  Future<void> ready() async {
    try {
      await _page.ready();
    } on NetworkError {
      // A failed load would fail every later request, even after the person passes the
      // server's check in Validate Client; the next request loads the page again instead.
      if (_page.isStopped) rethrow;
      final reload = _reload ??= () async {
        _page.load(_page.url ?? _start);
        try {
          await _page.ready();
        } finally {
          _reload = null;
        }
      }();
      await reload;
    }
  }

  @override
  Future<int> navigate(Uri url) async {
    _page.load(url);
    await _page.ready();
    return _page.status;
  }

  @override
  Future<String> evaluate(String script, Map<String, Object?> arguments) => _page.evaluate(script, arguments);

  @override
  void stop() => _page.stop();
}
