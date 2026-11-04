import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

import '../../core/content/content_errors.dart';

/// An off-screen web view page that runs scripts in a website's own origin, so their `fetch`
/// goes out through the browser's connection and cookies. The image and comics browser routes
/// both build on it.
class HiddenWebPage {
  HiddenWebPage(Uri start, {required this.scriptFailure}) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_channel, onMessageReceived: _received)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => status = 200,
          onHttpError: (error) {
            if (error.request?.uri.toString() == _target?.toString()) status = error.response?.statusCode ?? status;
          },
          onPageFinished: (address) {
            url = Uri.tryParse(address);
            _finishLoad(null);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _finishLoad(const NetworkError(NetworkErrorCode.networkConnectionLost));
          },
        ),
      );
    load(start);
  }

  static const _channel = 'TegnalPageBridge';

  /// What a script that threw becomes for the caller.
  final Object Function() scriptFailure;

  late final WebViewController _controller;

  /// The address of the committed document, or null before the first one.
  Uri? url;

  /// The main document's response status.
  int status = 200;

  Uri? _target;
  Completer<void> _loaded = Completer<void>();
  final _pending = <int, Completer<String>>{};
  var _nextID = 0;
  var _stopped = false;

  bool get isStopped => _stopped;

  void load(Uri target) {
    _target = target;
    if (_loaded.isCompleted) _loaded = Completer<void>();
    _controller.loadRequest(target);
  }

  void _finishLoad(Object? error) {
    if (_loaded.isCompleted) return;
    error == null ? _loaded.complete() : _loaded.completeError(error);
  }

  /// Completes once a document has finished loading, or throws its load failure or a timeout.
  Future<void> ready() {
    if (_stopped) throw const BrowserProcessTerminated();
    return _loaded.future.timeout(const Duration(seconds: 30), onTimeout: () => throw const NetworkError(NetworkErrorCode.timedOut));
  }

  /// Runs [script] as the body of an async function with [arguments] in scope and returns its
  /// result encoded as JSON, as WebKit's `callAsyncJavaScript` does.
  Future<String> evaluate(String script, Map<String, Object?> arguments, {Duration timeout = const Duration(seconds: 40)}) async {
    if (_stopped) throw const BrowserProcessTerminated();
    final id = _nextID++;
    final result = _pending[id] = Completer<String>();
    final names = arguments.keys.join(', ');
    final values = arguments.values.map(jsonEncode).join(', ');
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
      timeout,
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
      completer.completeError(scriptFailure());
    } else {
      completer.complete(jsonEncode(decoded['value']));
    }
  }

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
