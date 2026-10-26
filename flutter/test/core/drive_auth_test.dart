import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/data/drive_auth.dart';

class _MemoryTokens implements DriveTokenStore {
  final values = <String, String>{};
  Completer<void>? writeStarted;
  Completer<void>? releaseWrite;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (writeStarted != null && !writeStarted!.isCompleted) {
      writeStarted!.complete();
    }
    await releaseWrite?.future;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  const clientId = 'desktop-client-fixture';
  const refreshToken = 'private-refresh-fixture';
  const accessToken = 'private-access-fixture';
  String storageKey(String id) =>
      'tegnal.drive.oauth.${sha256.convert(utf8.encode(id))}';
  Map<String, Object> credentials() => {
    'id': 'stable-google-account',
    'email': 'fixture@example.invalid',
    'refreshToken': refreshToken,
  };
  http.Response tokenResponse({String token = accessToken}) => http.Response(
    jsonEncode({
      'access_token': token,
      'expires_in': 3600,
      'token_type': 'Bearer',
      'scope': 'openid email $driveFileScope',
      'refresh_token': refreshToken,
    }),
    200,
  );

  late _MemoryTokens store;
  late List<_TrackedClient> clients;
  late List<http.Request> requests;
  late DateTime now;
  late GoogleDriveAuth auth;

  setUp(() {
    store = _MemoryTokens();
    clients = [];
    requests = [];
    now = DateTime.utc(2026, 10, 27);
  });

  GoogleDriveAuth create({
    String id = clientId,
    Future<bool> Function(Uri)? launch,
    FutureOr<http.Response> Function(http.Request)? respond,
    Duration timeout = const Duration(seconds: 3),
  }) {
    auth = GoogleDriveAuth(
      desktopClientId: id,
      desktopClientSecret: 'public-installed-client-fixture',
      platform: TargetPlatform.linux,
      tokenStore: store,
      now: () => now,
      authorizationTimeout: timeout,
      clientFactory: () {
        final client = _TrackedClient((request) async {
          requests.add(request);
          if (respond != null) return await respond(request);
          if (request.url.host == 'openidconnect.googleapis.com') {
            return http.Response(
              jsonEncode({
                'sub': 'stable-google-account',
                'email': 'fixture@example.invalid',
              }),
              200,
            );
          }
          return tokenResponse();
        });
        clients.add(client);
        return client;
      },
      browserLauncher:
          launch ?? (_) async => throw StateError('No browser expected'),
    );
    addTearDown(auth.dispose);
    return auth;
  }

  Future<bool> callback(Uri authorization, {bool validState = true}) async {
    final redirect = Uri.parse(authorization.queryParameters['redirect_uri']!);
    expect(redirect.host, '127.0.0.1');
    expect(redirect.port, greaterThan(0));
    expect(redirect.path, '/oauth2callback');
    final response = await http.get(
      redirect.replace(
        queryParameters: {
          'state': validState
              ? authorization.queryParameters['state']!
              : 'invalid-state',
          'code': 'authorization-code-fixture',
        },
      ),
    );
    expect(response.statusCode, validState ? 200 : 400);
    expect(response.body, isNot(contains('authorization-code-fixture')));
    return true;
  }

  test(
    'missing configuration is clear and performs no authorization',
    () async {
      var opened = false;
      auth = GoogleDriveAuth(
        platform: TargetPlatform.windows,
        desktopClientId: '',
        desktopClientSecret: '',
        tokenStore: store,
        browserLauncher: (_) async => opened = true,
      );
      addTearDown(auth.dispose);
      expect(auth.configured, isFalse);
      expect(auth.configurationMessage, contains('GOOGLE_DESKTOP_CLIENT_ID'));
      expect(await auth.restore(), isFalse);
      await expectLater(auth.connect(), throwsA(isA<DriveAuthException>()));
      expect(opened, isFalse);
      expect(store.values, isEmpty);
    },
  );

  test(
    'Android requires a Web client ID and unsupported platforms explain why',
    () {
      auth = GoogleDriveAuth(platform: TargetPlatform.android, webClientId: '');
      expect(auth.configured, isFalse);
      expect(auth.configurationMessage, contains('GOOGLE_WEB_CLIENT_ID'));
      auth.dispose();
      auth = GoogleDriveAuth(platform: TargetPlatform.iOS);
      expect(
        auth.configurationMessage,
        contains('Android, Windows, and Linux'),
      );
      auth.dispose();
    },
  );

  test(
    'system-browser PKCE validates state and stores only refresh credentials',
    () async {
      late Uri authorization;
      create(
        launch: (uri) async {
          authorization = uri;
          return callback(uri);
        },
      );
      final user = await auth.connect();
      expect(user.id, 'stable-google-account');
      expect(user.email, 'fixture@example.invalid');
      expect(authorization.scheme, 'https');
      expect(authorization.host, 'accounts.google.com');
      expect(
        authorization.queryParameters['scope'],
        'openid email $driveFileScope',
      );
      expect(authorization.queryParameters['access_type'], 'offline');
      expect(authorization.queryParameters['code_challenge_method'], 'S256');
      final exchange = requests.singleWhere(
        (request) => request.url.path == '/token',
      );
      final body = exchange.bodyFields;
      final computed = base64Url
          .encode(sha256.convert(ascii.encode(body['code_verifier']!)).bytes)
          .replaceAll('=', '');
      expect(authorization.queryParameters['code_challenge'], computed);
      expect(body['grant_type'], 'authorization_code');
      expect(
        body['redirect_uri'],
        authorization.queryParameters['redirect_uri'],
      );
      expect(requests.last.headers['Authorization'], 'Bearer $accessToken');
      expect(store.values.keys, [storageKey(clientId)]);
      expect(jsonDecode(store.values.values.single), credentials());
      expect(store.values.values.single, isNot(contains(accessToken)));
      expect(await auth.accessToken(), accessToken);
      expect(requests, hasLength(2));
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  test(
    'invalid callback state closes listener and never exchanges code',
    () async {
      late Uri redirect;
      create(
        launch: (uri) async {
          redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          return callback(uri, validState: false);
        },
      );
      await expectLater(
        auth.connect(),
        throwsA(
          isA<DriveAuthException>().having(
            (error) => error.message,
            'message',
            contains('verified'),
          ),
        ),
      );
      expect(requests, isEmpty);
      expect(store.values, isEmpty);
      expect(auth.identity, isNull);
      await expectLater(http.get(redirect), throwsA(anything));
    },
  );

  test(
    'restoration refreshes silently and cached access expires before refresh',
    () async {
      store.values[storageKey(clientId)] = jsonEncode(credentials());
      var sequence = 0;
      create(
        respond: (request) {
          expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
          expect(request.bodyFields['grant_type'], 'refresh_token');
          expect(request.bodyFields['refresh_token'], refreshToken);
          return tokenResponse(token: 'access-${++sequence}');
        },
      );
      expect(await auth.restore(), isTrue);
      expect(auth.identity!.id, 'stable-google-account');
      expect(await auth.accessToken(), 'access-1');
      expect(requests, hasLength(1));
      now = now.add(const Duration(minutes: 59, seconds: 1));
      expect(await auth.accessToken(), 'access-2');
      expect(requests, hasLength(2));
      expect(clients.every((client) => client.closed), isTrue);
    },
  );

  test('invalid_grant clears account and secure credentials without exposing provider details', () async {
    store.values[storageKey(clientId)] = jsonEncode(credentials());
    create(
      respond: (_) => http.Response(
        jsonEncode({
          'error': 'invalid_grant',
          'error_description': '$refreshToken $accessToken secret diagnostic',
        }),
        400,
      ),
    );
    expect(await auth.restore(), isFalse);
    expect(auth.identity, isNull);
    expect(store.values, isEmpty);
    await expectLater(auth.accessToken(), throwsA(isA<DriveAuthException>()));
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('HTTP and decoding failures expose only controlled messages and close clients', () async {
    store.values[storageKey(clientId)] = jsonEncode(credentials());
    create(
      respond: (_) => throw StateError('$refreshToken $accessToken diagnostic'),
    );
    try {
      await auth.restore();
      fail('Expected sanitized failure');
    } catch (error) {
      expect(error, isA<DriveAuthException>());
      expect(error.toString(), isNot(contains(refreshToken)));
      expect(error.toString(), isNot(contains(accessToken)));
      expect(error.toString(), isNot(contains('diagnostic')));
    }
    expect(clients.every((client) => client.closed), isTrue);
  });

  test('OAuth clients cannot restore each other\'s stored account', () async {
    store.values[storageKey('different-client')] = jsonEncode(credentials());
    create();
    expect(await auth.restore(), isFalse);
    expect(requests, isEmpty);
    expect(auth.identity, isNull);
    expect(store.values, hasLength(1));
  });

  test(
    'browser failure and authorization timeout close callback server',
    () async {
      late Uri redirect;
      create(
        launch: (uri) async {
          redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          return false;
        },
      );
      await expectLater(auth.connect(), throwsA(isA<DriveAuthException>()));
      await expectLater(http.get(redirect), throwsA(anything));
      create(
        timeout: const Duration(milliseconds: 20),
        launch: (uri) async {
          redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          return true;
        },
      );
      await expectLater(
        auth.connect(),
        throwsA(
          isA<DriveAuthException>().having(
            (error) => error.message,
            'message',
            contains('timed out'),
          ),
        ),
      );
      await expectLater(http.get(redirect), throwsA(anything));
      expect(store.values, isEmpty);
    },
  );

  test(
    'disconnect cancels pending sign-in and a late callback cannot restore it',
    () async {
      final browserOpened = Completer<Uri>();
      create(
        launch: (uri) async {
          browserOpened.complete(uri);
          return true;
        },
      );
      final connected = auth.connect();
      final rejected = expectLater(
        connected,
        throwsA(isA<DriveAuthException>()),
      );
      final authorization = await browserOpened.future;
      await auth.disconnect();
      await rejected;
      final redirect = Uri.parse(
        authorization.queryParameters['redirect_uri']!,
      );
      await expectLater(http.get(redirect), throwsA(anything));
      expect(auth.identity, isNull);
      expect(store.values, isEmpty);
      expect(requests, isEmpty);
    },
  );

  test(
    'disconnect rolls back a secure-store write already in flight',
    () async {
      store.writeStarted = Completer<void>();
      store.releaseWrite = Completer<void>();
      create(launch: callback);
      final connected = auth.connect();
      final rejected = expectLater(
        connected,
        throwsA(isA<DriveAuthException>()),
      );
      await store.writeStarted!.future;
      final disconnected = auth.disconnect();
      store.releaseWrite!.complete();
      await disconnected;
      await rejected;
      expect(auth.identity, isNull);
      expect(store.values, isEmpty);
      expect(clients.every((client) => client.closed), isTrue);
    },
  );
  test(
    'disposing during a credential write preserves the previous account',
    () async {
      final previous = jsonEncode({
        'id': 'previous-account',
        'email': 'previous@example.invalid',
        'refreshToken': 'previous-refresh-fixture',
      });
      store.values[storageKey(clientId)] = previous;
      store.writeStarted = Completer<void>();
      store.releaseWrite = Completer<void>();
      create(launch: callback);
      final connected = auth.connect();
      final rejected = expectLater(
        connected,
        throwsA(isA<DriveAuthException>()),
      );
      await store.writeStarted!.future;
      auth.dispose();
      store.releaseWrite!.complete();
      await rejected;
      expect(auth.identity, isNull);
      expect(store.values[storageKey(clientId)], previous);
    },
  );
}
