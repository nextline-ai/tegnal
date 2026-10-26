import 'package:http/http.dart' as http;

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
    try {
      return await _session.send(request);
    } on AndroidMangaNetworkException catch (error) {
      throw SourceConnectionException(error);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _session.close();
    _transport.close();
  }
}

/// A connection failure after the permitted transport recovery was exhausted.
/// It does not imply an HTTP access denial or a certificate validation failure.
class SourceConnectionException extends ContentException {
  const SourceConnectionException(this.cause)
    : super(
        'Unable to connect to this website. If it also requires a VPN or HTTPS bypass app in Chrome, enable it and try again.',
      );

  final AndroidMangaNetworkException cause;
}
