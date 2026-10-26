import 'dart:async';
import 'dart:collection';

import 'package:ech_http/ech_http.dart' as ech;
import 'package:http/http.dart' as http;

import 'android_manga_client.dart';

typedef MangaEchResolverFactory = ech.EchResolver Function(
  String host,
  http.Client bootstrapClient,
);
typedef MangaEchClientFactory = http.Client Function(
  String host,
  ech.EchRoute route,
);

/// Retries only Android connection failures through an explicitly routed ECH
/// client. The URL allowlist is supplied by MangaSource and checked before DoH.
class MangaFallbackClient extends http.BaseClient {
  MangaFallbackClient({
    required this._primary,
    required this._allowsUri,
    MangaEchResolverFactory? resolverFactory,
    this._echClientFactory,
    http.Client Function()? bootstrapClientFactory,
    this.timeout = const Duration(seconds: 20),
    this.maxCachedHosts = 8,
  }) : _resolverFactory = resolverFactory ?? _defaultResolverFactory,
       _bootstrapClientFactory =
           bootstrapClientFactory ??
           (() => ech.EchClient(
             timeout: timeout,
             connectTimeout: const Duration(seconds: 10),
             maxResponseBytes: 1024 * 1024,
             maxConcurrentRequests: 4,
             maxConcurrentRequestsPerHost: 2,
           )) {
    if (timeout <= Duration.zero || maxCachedHosts < 1) {
      throw ArgumentError('A positive timeout and cache size are required.');
    }
  }

  static final Uri _dohEndpoint = Uri(
    scheme: 'https',
    host: 'cloudflare-dns.com',
    path: '/dns-query',
  );
  static const int _maxResponseBytes = 32 * 1024 * 1024;

  final http.Client _primary;
  final bool Function(Uri uri) _allowsUri;
  final MangaEchResolverFactory _resolverFactory;
  final MangaEchClientFactory? _echClientFactory;
  final http.Client Function() _bootstrapClientFactory;
  final Duration timeout;
  final int maxCachedHosts;
  final LinkedHashMap<String, _HostClients> _hosts = LinkedHashMap();
  final Set<_RequestCancellation> _activeRequests = {};
  http.Client? _bootstrapClient;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('This manga client is closed.');
    final stopwatch = Stopwatch()..start();
    try {
      return await _primary.send(request);
    } on AndroidMangaNetworkException catch (networkError, stackTrace) {
      if (!_fallbackEligible(request)) {
        Error.throwWithStackTrace(networkError, stackTrace);
      }
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        Error.throwWithStackTrace(networkError, stackTrace);
      }
      return _retryWithEch(request, networkError, stackTrace, remaining);
    }
  }

  bool _fallbackEligible(http.BaseRequest request) =>
      !_closed &&
      request.method.toUpperCase() == 'GET' &&
      request.url.scheme == 'https' &&
      request.url.host.isNotEmpty &&
      request.url.userInfo.isEmpty &&
      _allowsUri(request.url);

  Future<http.StreamedResponse> _retryWithEch(
    http.BaseRequest original,
    AndroidMangaNetworkException networkError,
    StackTrace networkStack,
    Duration remaining,
  ) async {
    final cancellation = _RequestCancellation(
      original.url,
      remaining,
      original is http.Abortable ? original.abortTrigger : null,
    );
    _activeRequests.add(cancellation);
    _HostClients? entry;
    try {
      entry = _hostClients(original.url.host.toLowerCase());
      final ech.EchRoute? route;
      try {
        route = await cancellation.race(entry.resolver.resolve(original.url));
      } on http.RequestAbortedException {
        rethrow;
      } on MangaRequestTimeoutException {
        rethrow;
      } catch (_) {
        if (_closed) rethrow;
        // No ECH record, DoH failure, or malformed resolver answer: retain the
        // original connection error. Never retry with ordinary TLS here.
        Error.throwWithStackTrace(networkError, networkStack);
      }
      if (route == null) Error.throwWithStackTrace(networkError, networkStack);

      final client = entry.clientFor(route, _echClientFactory, timeout);
      final retry = _copyGetRequest(original, cancellation.signal);
      try {
        final response = await cancellation.race(client.send(retry));
        return _retainDeadline(
          response,
          cancellation,
          () => _activeRequests.remove(cancellation),
        );
      } on http.RequestAbortedException {
        rethrow;
      } on MangaRequestTimeoutException {
        rethrow;
      } on ech.EchException catch (error) {
        // A native TLS result carries a curl code and may include certificate
        // validation failure. Preserve it; resolver-side errors were handled
        // above and never get this far.
        if (error.nativeCode != null) rethrow;
        Error.throwWithStackTrace(networkError, networkStack);
      }
    } catch (error) {
      cancellation.dispose();
      _activeRequests.remove(cancellation);
      if (error is http.RequestAbortedException ||
          error is MangaRequestTimeoutException ||
          (error is ech.EchException && error.nativeCode != null) ||
          (_closed && error is http.ClientException)) {
        rethrow;
      }
      if (error is AndroidMangaNetworkException) rethrow;
      Error.throwWithStackTrace(networkError, networkStack);
    }
  }

  http.BaseRequest _copyGetRequest(
    http.BaseRequest original,
    Future<void> abortTrigger,
  ) {
    final request =
        http.AbortableRequest('GET', original.url, abortTrigger: abortTrigger)
          ..followRedirects = false
          ..maxRedirects = 0
          ..persistentConnection = original.persistentConnection;
    request.headers.addAll(_safeHeaders(original.headers));
    if (!request.headers.keys.any(
      (name) => name.toLowerCase() == 'accept-encoding',
    )) {
      if (request.headers.keys.any((name) => name.toLowerCase() == 'range')) {
        request.headers['accept-encoding'] = 'identity';
      }
    }
    return request;
  }

  static Map<String, String> _safeHeaders(Map<String, String> headers) {
    const hopByHop = {
      'connection',
      'content-length',
      'host',
      'keep-alive',
      'proxy-authenticate',
      'proxy-authorization',
      'te',
      'trailer',
      'transfer-encoding',
      'upgrade',
    };
    return {
      for (final entry in headers.entries)
        if (!hopByHop.contains(entry.key.toLowerCase()) &&
            !entry.key.toLowerCase().startsWith('proxy-'))
          entry.key: entry.value,
    };
  }

  http.StreamedResponse _retainDeadline(
    http.StreamedResponse response,
    _RequestCancellation cancellation,
    void Function() onFinished,
  ) {
    final controller = StreamController<List<int>>(sync: true);
    StreamSubscription<List<int>>? subscription;
    void finish() {
      cancellation.dispose();
      onFinished();
      if (!controller.isClosed) unawaited(controller.close());
    }

    controller.onListen = () {
      subscription = response.stream.listen(
        controller.add,
        onError: (Object error, StackTrace stackTrace) {
          final mapped = error is http.RequestAbortedException
              ? cancellation.error
              : error;
          controller.addError(mapped, stackTrace);
          finish();
        },
        onDone: finish,
        cancelOnError: false,
      );
    };
    controller.onPause = () => subscription?.pause();
    controller.onResume = () => subscription?.resume();
    controller.onCancel = () async {
      await subscription?.cancel();
      cancellation.dispose();
      onFinished();
    };
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      reasonPhrase: response.reasonPhrase,
    );
  }

  _HostClients _hostClients(String host) {
    final existing = _hosts.remove(host);
    if (existing != null) {
      _hosts[host] = existing;
      return existing;
    }
    final bootstrap = _bootstrapClient ??= _bootstrapClientFactory();
    final created = _HostClients(host, _resolverFactory(host, bootstrap));
    _hosts[host] = created;
    if (_hosts.length > maxCachedHosts) {
      final oldestKey = _hosts.keys.first;
      final oldest = _hosts.remove(oldestKey);
      oldest?.close();
    }
    return created;
  }

  static ech.EchResolver _defaultResolverFactory(
    String host,
    http.Client bootstrap,
  ) => ech.DohEchResolver(
    client: bootstrap,
    endpoint: _dohEndpoint,
    hosts: {host},
  );

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _activeRequests.toList()) {
      request.cancelForClientClose();
    }
    _activeRequests.clear();
    _primary.close();
    for (final entry in _hosts.values) {
      entry.close();
    }
    _hosts.clear();
    _bootstrapClient?.close();
    _bootstrapClient = null;
  }
}

final class _HostClients {
  _HostClients(this.host, this.resolver);

  final String host;
  final ech.EchResolver resolver;
  ech.EchRoute? _route;
  http.Client? _client;

  http.Client clientFor(
    ech.EchRoute route,
    MangaEchClientFactory? factory,
    Duration timeout,
  ) {
    if (!_sameRoute(_route, route)) {
      _client?.close();
      _route = route;
      _client =
          factory?.call(host, route) ??
          ech.EchClient(
            resolver: ech.StaticEchResolver({host: route}),
            timeout: timeout,
            connectTimeout: const Duration(seconds: 10),
            maxResponseBytes: MangaFallbackClient._maxResponseBytes,
            maxConcurrentRequests: 4,
            maxConcurrentRequestsPerHost: 2,
          );
    }
    return _client!;
  }

  void close() {
    _client?.close();
    _client = null;
    _route = null;
  }

  static bool _sameRoute(ech.EchRoute? first, ech.EchRoute second) =>
      first != null &&
      first.configList == second.configList &&
      _sameList(first.addresses, second.addresses);

  static bool _sameList(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

final class _RequestCancellation {
  _RequestCancellation(
    this.uri,
    Duration timeout,
    Future<void>? originalAbort,
  ) {
    if (originalAbort != null) {
      unawaited(
        originalAbort.then<void>(
          (_) {
            _completeSignal();
          },
          onError: (Object _, StackTrace _) {
            _completeSignal();
          },
        ),
      );
    }
    _timer = Timer(timeout, () {
      _timedOut = true;
      _completeSignal();
    });
  }

  final Uri uri;
  final Completer<void> _signal = Completer<void>();
  late final Timer _timer;
  bool _timedOut = false;
  bool _clientClosed = false;

  Future<void> get signal => _signal.future;
  Object get error => _timedOut
      ? MangaRequestTimeoutException(uri)
      : _clientClosed
      ? http.ClientException('This manga client is closed.', uri)
      : http.RequestAbortedException(uri);

  void _completeSignal() {
    if (!_signal.isCompleted) _signal.complete();
  }

  Future<T> race<T>(Future<T> future) {
    if (_signal.isCompleted) throw error;
    return Future.any<T>([future, _signal.future.then<T>((_) => throw error)]);
  }

  void dispose() => _timer.cancel();

  void cancelForClientClose() {
    _clientClosed = true;
    _completeSignal();
    dispose();
  }
}

class MangaRequestTimeoutException extends http.ClientException {
  MangaRequestTimeoutException(Uri uri)
    : super('The manga server request timed out.', uri);
}
