import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

import '../core/content.dart';
import 'android_manga_client.dart';
import 'manga_fallback_client.dart';
import 'session_client.dart';

/// Website-session transport shared by Booru APIs, detection, and media.
/// Android uses OkHttp and retries connection failures through verified ECH.
/// Redirects stay caller-owned so every destination gets its own cookie lookup.
class SourceHttpClient extends http.BaseClient {
  SourceHttpClient({
    required this.origin,
    this.allowSubdomains = false,
    http.Client? primary,
    MangaEchResolverFactory? resolverFactory,
    MangaEchClientFactory? echClientFactory,
    http.Client Function()? bootstrapClientFactory,
  }) {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty) {
      throw const ContentException('Enter a valid HTTPS website address.');
    }
    // An injected primary is owned by this client, just like the native one.
    final android = primary ?? AndroidMangaClient.createIfSupported();
    _transport = android == null
        ? http.Client()
        : MangaFallbackClient(
            primary: android,
            allowsUri: _allowsFallback,
            resolverFactory: resolverFactory,
            echClientFactory: echClientFactory,
            bootstrapClientFactory: bootstrapClientFactory,
          );
    _session = SessionClient(origin: origin, inner: _transport);
  }

  final Uri origin;
  final bool allowSubdomains;
  late final http.Client _transport;
  late final SessionClient _session;
  bool _closed = false;
  final _closedSignal = StreamController<void>.broadcast(sync: true);

  bool _allowsFallback(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == origin.port &&
      (uri.host == origin.host ||
          (allowSubdomains && uri.host.endsWith('.${origin.host}')));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('This source client is closed.', request.url);
    }
    if (_browserEligible(request, requireVerification: false)) {
      await BrowserSession.restoreVerifiedRoute(request.url);
      if (_closed) {
        throw http.ClientException(
          'This source client is closed.',
          request.url,
        );
      }
    }
    final browserEligible = _browserEligible(request);
    var attemptedBrowser = false;
    if (browserEligible &&
        (BrowserSession.prefersVerified(request.url) ||
            BrowserSession.takeVerificationRetry(request.url))) {
      attemptedBrowser = true;
      final result = await _browserFetch(request);
      if (result != null) return result;
    }
    try {
      return await _session.send(request);
    } on AndroidMangaNetworkException catch (error) {
      if (_browserEligible(request, requireVerification: false)) {
        BrowserSession.rememberNetworkFailure(request.url);
      }
      if (!_closed && browserEligible && !attemptedBrowser) {
        attemptedBrowser = true;
        final result = await _browserFetch(request);
        if (result != null) return result;
      }
      throw SourceConnectionException(
        error,
        browserRetryFailed:
            attemptedBrowser || BrowserSession.canRetryVerified(request.url),
      );
    }
  }

  Future<http.StreamedResponse?> _browserFetch(http.BaseRequest request) async {
    try {
      return await BrowserSession.verifiedGet(
        request,
        closed: _closedSignal.stream,
      );
    } on http.RequestAbortedException {
      rethrow;
    } on PlatformException catch (failure) {
      BrowserSession.forgetVerifiedRoute(request.url);
      if (failure.code == 'certificate_error') {
        throw AndroidMangaCertificateException(
          'The secure connection could not be verified.',
          request.url,
        );
      }
    } on MissingPluginException {
      BrowserSession.forgetVerifiedRoute(request.url);
    } on http.ClientException {
      BrowserSession.forgetVerifiedRoute(request.url);
    }
    return null;
  }

  bool _browserEligible(
    http.BaseRequest request, {
    bool requireVerification = true,
  }) {
    final url = request.url;
    final headers = {
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final accept = (headers['accept'] ?? '').toLowerCase();
    final allowedHeaders = headers.keys.every(
      (key) => {'accept', 'user-agent', 'cookie'}.contains(key),
    );
    // Only Danbooru's public posts JSON endpoint is supported here. Never
    // pass arbitrary query-string credentials into a page's JavaScript.
    final listRequest =
        url.path.endsWith('/posts.json') &&
        url.queryParameters.keys.every(
          (key) => {'tags', 'limit', 'page'}.contains(key.toLowerCase()),
        );
    final detailRequest =
        RegExp(r'/posts/[0-9]+\.json$').hasMatch(url.path) && !url.hasQuery;
    return request.method.toUpperCase() == 'GET' &&
        url.origin == origin.origin &&
        url.userInfo.isEmpty &&
        allowedHeaders &&
        (listRequest || detailRequest) &&
        (accept.contains('application/json') ||
            accept.contains('application/xml')) &&
        (!requireVerification || BrowserSession.canRetryVerified(url));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.add(null);
    unawaited(_closedSignal.close());
    _session.close();
    _transport.close();
  }
}

/// A connection failure after the permitted transport recovery was exhausted.
/// It does not imply an HTTP access denial or a certificate validation failure.
class SourceConnectionException extends ContentException {
  const SourceConnectionException(this.cause, {bool browserRetryFailed = false})
    : super(
        browserRetryFailed
            ? 'The app could not load this website’s catalog after browser verification. Check that the website allows API access and try verification again.'
            : 'Unable to connect to this website. If it also requires a VPN or HTTPS bypass app in Chrome, enable it and try again.',
      );

  final AndroidMangaNetworkException cause;
}
