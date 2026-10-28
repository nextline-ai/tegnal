import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../core/content.dart';
import 'source_http_client.dart';

class BooruCredentials {
  const BooruCredentials({this.account = '', this.secret = ''});
  final String account;
  final String secret;
  bool get isEmpty => account.isEmpty && secret.isEmpty;
}

/// Only the platform secure store contains sign-in details. They never enter
/// SourceConfig, library metadata, backups, or a log message.
class BooruCredentialsStore {
  static const _storage = FlutterSecureStorage();
  static String _key(SourceConfig source) =>
      'booru.credentials.${sha256.convert(utf8.encode(source.canonicalAddress))}';
  static Future<BooruCredentials> read(SourceConfig source) async {
    try {
      final raw = await _storage.read(key: _key(source));
      if (raw == null) return const BooruCredentials();
      final value = jsonDecode(raw) as Map;
      return BooruCredentials(
        account: value['account'] as String,
        secret: value['secret'] as String,
      );
    } on MissingPluginException {
      return const BooruCredentials();
    }
  }

  static Future<void> save(SourceConfig source, BooruCredentials value) async {
    if (value.account.isEmpty != value.secret.isEmpty) {
      throw const FormatException(
        'Enter both the account and API key, or leave both empty.',
      );
    }
    if (value.isEmpty) {
      await _storage.delete(key: _key(source));
    } else {
      await _storage.write(
        key: _key(source),
        value: jsonEncode({'account': value.account, 'secret': value.secret}),
      );
    }
  }
}

/// Authentication is attached to only this configured HTTPS origin, after
/// redirect validation. Each redirected request is authenticated afresh.
class BooruAuthenticatedClient extends http.BaseClient {
  BooruAuthenticatedClient(
    this.source, {
    http.Client? inner,
    Future<BooruCredentials> Function()? load,
  }) : _inner = inner ?? SourceHttpClient(origin: source.baseUrl),
       _load = load ?? (() => BooruCredentialsStore.read(source));
  final SourceConfig source;
  final http.Client _inner;
  final Future<BooruCredentials> Function() _load;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final inScope =
        request.url.scheme == 'https' &&
        request.url.host == source.baseUrl.host &&
        request.url.port == source.baseUrl.port &&
        request.url.userInfo.isEmpty;
    final credentials = inScope ? await _load() : const BooruCredentials();
    if (credentials.isEmpty || source.kind == SourceKind.oldGelbooru) {
      return _inner.send(request);
    }
    final query = Map<String, String>.from(request.url.queryParameters);
    if (source.kind == SourceKind.danbooru) {
      request.headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${credentials.account}:${credentials.secret}'))}';
      return _inner.send(request);
    }
    if (source.kind == SourceKind.gelbooru) {
      query.addAll({
        'user_id': credentials.account,
        'api_key': credentials.secret,
      });
    } else if (source.kind == SourceKind.moebooru) {
      query.addAll({
        'login': credentials.account,
        'password_hash': credentials.secret,
      });
    } else {
      return _inner.send(request);
    }
    final authenticated =
        http.Request(
            request.method,
            request.url.replace(queryParameters: query),
          )
          ..headers.addAll(request.headers)
          ..followRedirects = false
          ..maxRedirects = request.maxRedirects;
    if (request is http.Request) authenticated.bodyBytes = request.bodyBytes;
    return _inner.send(authenticated);
  }

  @override
  void close() => _inner.close();
}
