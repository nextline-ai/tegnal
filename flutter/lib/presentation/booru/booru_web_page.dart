import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_models.dart';
import '../../core/content/content_errors.dart';
import '../../core/support/perf_trace.dart';

/// [BooruBrowserPage] on an off-screen Android web view. It shares the app's cookie store
/// with the Validate Client browser, and its requests carry the browser's own connection,
/// which some servers require beyond a cookie.
class WebViewBooruPage implements BooruBrowserPage {
  WebViewBooruPage(this.server) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_channel, onMessageReceived: _received)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _status = 200,
          onHttpError: (error) {
            if (error.request?.uri.toString() == _target?.toString()) _status = error.response?.statusCode ?? _status;
          },
          onPageFinished: (address) {
            _url = Uri.tryParse(address);
            _finishLoad(null);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _finishLoad(const NetworkError(NetworkErrorCode.networkConnectionLost));
          },
        ),
      );
    // Requests need only a document of the server's origin. Its plain-text robots file loads
    // without the site's scripts, images and ads; a server without one serves its home page.
    _load(Uri.parse(server.baseURL).resolve('/robots.txt'));
  }

  static const _channel = 'TegnalBooruBridge';

  final BooruServer server;
  late final WebViewController _controller;
  Uri? _url;
  Uri? _target;
  int _status = 200;
  Completer<void> _loaded = Completer<void>();
  final _pending = <int, Completer<String>>{};
  var _nextID = 0;
  var _stopped = false;

  @override
  Uri? get url => _url;

  /// Android has no separate script world, so account credentials never reach the page.
  @override
  bool get isolatesScripts => false;

  void _load(Uri target) {
    _target = target;
    if (_loaded.isCompleted) _loaded = Completer<void>();
    final watch = Stopwatch()..start();
    _loaded.future.then((_) => PerfTrace.log('booru page load', watch.elapsed, detail: target.path), onError: (_) {});
    _controller.loadRequest(target);
  }

  void _finishLoad(Object? error) {
    if (_loaded.isCompleted) return;
    error == null ? _loaded.complete() : _loaded.completeError(error);
  }

  @override
  Future<void> ready() {
    if (_stopped) throw const BrowserProcessTerminated();
    return _loaded.future.timeout(const Duration(seconds: 30), onTimeout: () => throw const NetworkError(NetworkErrorCode.timedOut));
  }

  @override
  Future<int> navigate(Uri url) async {
    _load(url);
    await ready();
    return _status;
  }

  @override
  Future<String> evaluate(String script, Map<String, Object?> arguments) async {
    if (_stopped) throw const BrowserProcessTerminated();
    final id = _nextID++;
    final result = _pending[id] = Completer<String>();
    final names = arguments.keys.join(', ');
    final values = arguments.values.map(jsonEncode).join(', ');
    // The scripts are async function bodies, as WebKit's `callAsyncJavaScript` takes them;
    // the result comes back through the channel once the promise settles.
    final source =
        '(async function($names) {\n$script\n})($values).then('
        'function (value) { $_channel.postMessage(JSON.stringify({id: $id, value: value === undefined ? null : value})); }, '
        'function (error) { $_channel.postMessage(JSON.stringify({id: $id, error: String(error && error.message || error)})); });';
    try {
      await _controller.runJavaScript(source);
    } on Object {
      _pending.remove(id);
      throw const NetworkError(NetworkErrorCode.networkConnectionLost);
    }
    return result.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        _pending.remove(id);
        throw const NetworkError(NetworkErrorCode.timedOut);
      },
    );
  }

  void _received(JavaScriptMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (decoded is! Map || decoded['id'] is! int) return;
    final completer = _pending.remove(decoded['id']);
    if (completer == null) return;
    if (decoded.containsKey('error')) {
      completer.completeError(const BooruError(BooruErrorKind.invalidResponse));
    } else {
      completer.complete(jsonEncode(decoded['value']));
    }
  }

  @override
  void stop() {
    _stopped = true;
    _controller.loadRequest(Uri.parse('about:blank'));
    for (final completer in _pending.values) {
      completer.completeError(const BrowserProcessTerminated());
    }
    _pending.clear();
    _finishLoad(const BrowserProcessTerminated());
  }
}
