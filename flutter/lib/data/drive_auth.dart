import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const driveFileScope = 'https://www.googleapis.com/auth/drive.file';

class DriveIdentity {
  const DriveIdentity({required this.id, required this.email});
  final String id;
  final String email;
}

abstract interface class DriveAuth {
  bool get configured;
  String? get configurationMessage;
  DriveIdentity? get identity;
  Future<bool> restore();
  Future<DriveIdentity> connect();
  Future<String> accessToken({bool interactive = false});
  Future<void> disconnect();
  void dispose();
}

/// Only controlled, user-facing messages cross the authentication boundary.
class DriveAuthException implements Exception {
  const DriveAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class DriveTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureDriveTokenStore implements DriveTokenStore {
  SecureDriveTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Android uses Google's SDK. Windows/Linux use installed-app OAuth with PKCE.
/// No authentication or restoration is started by constructing this object.
class GoogleDriveAuth implements DriveAuth {
  GoogleDriveAuth({
    String? webClientId,
    String? desktopClientId,
    String? desktopClientSecret,
    TargetPlatform? platform,
    DriveTokenStore? tokenStore,
    http.Client Function()? clientFactory,
    Future<bool> Function(Uri)? browserLauncher,
    DateTime Function()? now,
    this.authorizationTimeout = const Duration(minutes: 3),
  }) : _webClientId =
           webClientId ?? const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
       _desktopClientId =
           desktopClientId ??
           const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID'),
       _desktopClientSecret =
           desktopClientSecret ??
           const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET'),
       _platform = platform ?? defaultTargetPlatform,
       _store = tokenStore ?? SecureDriveTokenStore(),
       _clientFactory = clientFactory ?? http.Client.new,
       _browserLauncher =
           browserLauncher ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _now = now ?? DateTime.now;

  final String _webClientId;
  final String _desktopClientId;
  final String _desktopClientSecret;
  final TargetPlatform _platform;
  final DriveTokenStore _store;
  final http.Client Function() _clientFactory;
  final Future<bool> Function(Uri) _browserLauncher;
  final DateTime Function() _now;
  final Duration authorizationTimeout;
  static Future<void>? _androidInitialization;
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _revokeEndpoint = 'https://oauth2.googleapis.com/revoke';
  static const _userinfoEndpoint =
      'https://openidconnect.googleapis.com/v1/userinfo';

  DriveIdentity? _identity;
  GoogleSignInAccount? _androidAccount;
  String? _token;
  DateTime? _expiresAt;
  String? _refreshToken;
  int _epoch = 0;
  bool _disposed = false;
  Future<DriveIdentity>? _connecting;
  Future<String>? _refreshing;
  Future<void> _storageOperations = Future<void>.value();
  final Set<http.Client> _clients = {};
  HttpServer? _callbackServer;
  Completer<String>? _callback;

  bool get _desktop =>
      _platform == TargetPlatform.windows || _platform == TargetPlatform.linux;
  String get _storageKey =>
      'tegnal.drive.oauth.${sha256.convert(utf8.encode(_desktopClientId))}';
  @override
  DriveIdentity? get identity => _identity;
  @override
  bool get configured => configurationMessage == null;
  @override
  String? get configurationMessage {
    if (kIsWeb || (!_desktop && _platform != TargetPlatform.android)) {
      return 'Google Drive sync is available on Android, Windows, and Linux.';
    }
    if (_platform == TargetPlatform.android && _webClientId.trim().isEmpty) {
      return 'Google Drive setup is required: configure GOOGLE_WEB_CLIENT_ID. See docs/google-drive-setup.md.';
    }
    if (_desktop &&
        (_desktopClientId.trim().isEmpty ||
            _desktopClientSecret.trim().isEmpty)) {
      return 'Google Drive setup is required: configure GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET. See docs/google-drive-setup.md.';
    }
    return null;
  }

  void _check(int epoch) {
    if (_disposed || epoch != _epoch) {
      throw const DriveAuthException('Google sign-in was cancelled.');
    }
  }

  void _requireConfigured() {
    _check(_epoch);
    if (!configured) throw DriveAuthException(configurationMessage!);
  }

  Future<T> _safe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DriveAuthException {
      rethrow;
    } on GoogleSignInException catch (error) {
      throw DriveAuthException(switch (error.code) {
        GoogleSignInExceptionCode.canceled => 'Google sign-in was cancelled.',
        GoogleSignInExceptionCode.clientConfigurationError => 'Google sign-in is not configured correctly. Check the OAuth client and Android signing certificate.',
        GoogleSignInExceptionCode.uiUnavailable =>
          'Open TEGNAL and try connecting Google Drive again.',
        _ => 'Google sign-in failed. Check your connection and try again.',
      });
    } catch (_) {
      // SDK/HTTP exceptions can include response bodies, headers, and tokens.
      throw const DriveAuthException(
        'Google Drive sign-in failed. Check your connection and OAuth setup, then try again.',
      );
    }
  }

  /// Call only after the user has opted in to automatic sync or chosen reconnect.
  @override
  Future<bool> restore() => _safe(() async {
    if (!configured) return false;
    final epoch = _epoch;
    _check(epoch);
    if (_connecting != null) {
      await _connecting;
      _check(epoch);
      return _identity != null;
    }
    if (_desktop) {
      final record = await _readCredentials(epoch);
      if (record == null) return false;
      _identity = DriveIdentity(id: record['id']!, email: record['email']!);
      _refreshToken = record['refreshToken'];
      try {
        await accessToken();
        return true;
      } on DriveAuthException {
        if (_identity == null) return false;
        rethrow;
      }
    }
    await _initializeAndroid();
    _check(epoch);
    final account = await GoogleSignIn.instance
        .attemptLightweightAuthentication();
    _check(epoch);
    if (account == null) return false;
    final authorization = await account.authorizationClient
        .authorizationForScopes(const [driveFileScope]);
    _check(epoch);
    if (authorization == null) return false;
    _androidAccount = account;
    _identity = DriveIdentity(id: account.id, email: account.email);
    return true;
  });

  @override
  Future<DriveIdentity> connect() {
    final pending = _connecting;
    if (pending != null) return pending;
    final epoch = ++_epoch;
    late final Future<DriveIdentity> operation;
    operation =
        _safe(() async {
          _requireConfigured();
          if (_desktop) return _connectDesktop(epoch);
          await _initializeAndroid();
          _check(epoch);
          final account = await GoogleSignIn.instance.authenticate(
            scopeHint: const [driveFileScope],
          );
          _check(epoch);
          var authorization = await account.authorizationClient
              .authorizationForScopes(const [driveFileScope]);
          _check(epoch);
          authorization ??= await account.authorizationClient.authorizeScopes(
            const [driveFileScope],
          );
          _check(epoch);
          _androidAccount = account;
          return _identity = DriveIdentity(
            id: account.id,
            email: account.email,
          );
        }).whenComplete(() {
          if (identical(_connecting, operation)) _connecting = null;
        });
    _connecting = operation;
    return operation;
  }

  Future<void> _initializeAndroid() => _androidInitialization ??= GoogleSignIn
      .instance
      .initialize(serverClientId: _webClientId);

  @override
  Future<String> accessToken({bool interactive = false}) => _safe(() async {
    _requireConfigured();
    var epoch = _epoch;
    if (_identity == null) {
      if (!interactive) {
        throw const DriveAuthException('Connect Google Drive to continue.');
      }
      await connect();
      epoch = _epoch;
    }
    _check(epoch);
    if (!_desktop) {
      final account = _androidAccount;
      if (account == null) {
        throw const DriveAuthException('Reconnect Google Drive to continue.');
      }
      var authorization = await account.authorizationClient
          .authorizationForScopes(const [driveFileScope]);
      _check(epoch);
      if (authorization == null && interactive) {
        authorization = await account.authorizationClient.authorizeScopes(
          const [driveFileScope],
        );
        _check(epoch);
      }
      if (authorization == null) {
        throw const DriveAuthException(
          'Reconnect Google Drive to grant file access.',
        );
      }
      return authorization.accessToken;
    }
    if (_token != null &&
        _expiresAt != null &&
        _now().isBefore(_expiresAt!.subtract(const Duration(seconds: 60)))) {
      return _token!;
    }
    final pending = _refreshing;
    if (pending != null) return pending;
    late final Future<String> operation;
    operation = _refreshDesktop(epoch).whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
    _refreshing = operation;
    return operation;
  });

  Future<Map<String, String>?> _readCredentials(int epoch) async {
    final raw = await _store.read(_storageKey);
    _check(epoch);
    if (raw == null) return null;
    try {
      final record = (jsonDecode(raw) as Map).cast<String, dynamic>();
      for (final key in ['id', 'email', 'refreshToken']) {
        if (record[key] is! String || (record[key] as String).isEmpty) {
          throw const FormatException();
        }
      }
      return record.cast<String, String>();
    } catch (_) {
      await _deleteCredentials();
      _check(epoch);
      return null;
    }
  }

  Future<void> _saveCredentials(int epoch, DriveIdentity user, String refresh) {
    final operation = _storageOperations.then((_) async {
      _check(epoch);
      final previous = await _store.read(_storageKey);
      _check(epoch);
      await _store.write(
        _storageKey,
        jsonEncode({
          'id': user.id,
          'email': user.email,
          'refreshToken': refresh,
        }),
      );
      if (_disposed || epoch != _epoch) {
        // Secure-store writes cannot be interrupted. Roll back a completed
        // stale write before the serialized disconnect deletion can run.
        if (previous == null) {
          await _store.delete(_storageKey);
        } else {
          await _store.write(_storageKey, previous);
        }
      }
      _check(epoch);
    });
    _storageOperations = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _deleteCredentials() {
    final operation = _storageOperations.then(
      (_) => _store.delete(_storageKey),
    );
    _storageOperations = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<String> _refreshDesktop(int epoch) async {
    final refresh = _refreshToken;
    if (refresh == null) {
      throw const DriveAuthException('Reconnect Google Drive to continue.');
    }
    final result = await _request(
      Uri.parse(_tokenEndpoint),
      epoch,
      body: {
        'client_id': _desktopClientId,
        'client_secret': _desktopClientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      },
    );
    _check(epoch);
    if (result['error'] == 'invalid_grant') {
      ++_epoch;
      _clearMemory();
      await _deleteCredentials();
      throw const DriveAuthException(
        'Google Drive access expired or was revoked. Connect again to continue.',
      );
    }
    _acceptToken(result);
    final replacement = result['refresh_token'];
    if (replacement is String && replacement.isNotEmpty) {
      await _saveCredentials(epoch, _identity!, replacement);
      _check(epoch);
      _refreshToken = replacement;
    }
    return _token!;
  }

  void _acceptToken(Map<String, dynamic> result) {
    final token = result['access_token'];
    final seconds = result['expires_in'];
    final tokenType = result['token_type'];
    if (result.containsKey('error') ||
        token is! String ||
        token.isEmpty ||
        seconds is! num ||
        seconds <= 0 ||
        (tokenType != null && tokenType.toString().toLowerCase() != 'bearer')) {
      throw const DriveAuthException(
        'Google did not grant Drive access. Connect again to continue.',
      );
    }
    final scopes = result['scope'];
    if (scopes is String && !scopes.split(' ').contains(driveFileScope)) {
      throw const DriveAuthException(
        'Google Drive file access was not granted. Connect again to continue.',
      );
    }
    _token = token;
    _expiresAt = _now().add(Duration(seconds: seconds.toInt()));
  }

  Future<DriveIdentity> _connectDesktop(int epoch) async {
    final state = _randomString();
    final verifier = _randomString();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Completer<String>? callback;
    try {
      _check(epoch);
      _callbackServer = server;
      final redirect = Uri.parse(
        'http://127.0.0.1:${server.port}/oauth2callback',
      );
      final pending = Completer<String>();
      callback = pending;
      _callback = pending;
      server.listen(
        (request) async {
          if (request.uri.path != '/oauth2callback') {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          final query = request.uri.queryParametersAll;
          final receivedState = query['state'];
          final validState =
              receivedState?.length == 1 &&
              _constantTimeEqual(receivedState!.single, state);
          final codes = query['code'];
          final valid =
              request.method == 'GET' &&
              validState &&
              codes?.length == 1 &&
              codes!.single.isNotEmpty &&
              !query.containsKey('error');
          request.response.statusCode = valid
              ? HttpStatus.ok
              : HttpStatus.badRequest;
          request.response.headers.contentType = ContentType.text;
          request.response.headers.set('Cache-Control', 'no-store');
          request.response.write(
            valid ? 'Sign-in received. Return to TEGNAL.' : 'Sign-in could not be verified. Return to TEGNAL and try again.',
          );
          try {
            await request.response.close();
          } catch (_) {
            // Closing the browser tab does not expose raw socket errors.
          }
          if (!pending.isCompleted) {
            if (valid) {
              pending.complete(codes.single);
            } else {
              pending.completeError(
                const DriveAuthException(
                  'Google sign-in could not be verified.',
                ),
              );
            }
          }
        },
        onError: (Object _) {
          if (!pending.isCompleted) {
            pending.completeError(
              const DriveAuthException('Google sign-in was interrupted.'),
            );
          }
        },
      );
      final authorization = Uri.https(
        'accounts.google.com',
        '/o/oauth2/v2/auth',
        {
          'client_id': _desktopClientId,
          'redirect_uri': redirect.toString(),
          'response_type': 'code',
          'scope': 'openid email $driveFileScope',
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'access_type': 'offline',
          'prompt': 'consent select_account',
        },
      );
      final results = await Future.wait<Object>([
        _launchBrowser(authorization),
        pending.future.timeout(
          authorizationTimeout,
          onTimeout: () => throw const DriveAuthException(
            'Google sign-in timed out. Try connecting again.',
          ),
        ),
      ], eagerError: true);
      _check(epoch);
      final result = await _request(
        Uri.parse(_tokenEndpoint),
        epoch,
        body: {
          'client_id': _desktopClientId,
          'client_secret': _desktopClientSecret,
          'code': results[1] as String,
          'code_verifier': verifier,
          'redirect_uri': redirect.toString(),
          'grant_type': 'authorization_code',
        },
      );
      _check(epoch);
      // Keep the access token local until the account and refresh token validate.
      final previousToken = _token;
      final previousExpiry = _expiresAt;
      _acceptToken(result);
      final token = _token!;
      final expiry = _expiresAt;
      _token = previousToken;
      _expiresAt = previousExpiry;
      final refresh = result['refresh_token'];
      if (refresh is! String || refresh.isEmpty) {
        throw const DriveAuthException(
          'Google did not provide offline access. Reconnect and allow Drive access.',
        );
      }
      final profile = await _request(
        Uri.parse(_userinfoEndpoint),
        epoch,
        bearer: token,
      );
      _check(epoch);
      final id = profile['sub'];
      final email = profile['email'];
      if (id is! String || id.isEmpty || email is! String || email.isEmpty) {
        throw const DriveAuthException('Google account could not be verified.');
      }
      final user = DriveIdentity(id: id, email: email);
      await _saveCredentials(epoch, user, refresh);
      _check(epoch);
      _refreshToken = refresh;
      _token = token;
      _expiresAt = expiry;
      return _identity = user;
    } finally {
      if (callback != null && !callback.isCompleted) {
        callback.completeError(
          const DriveAuthException('Google sign-in was cancelled.'),
        );
      }
      if (identical(_callbackServer, server)) {
        _callbackServer = null;
        _callback = null;
      }
      await server.close(force: true);
    }
  }

  Future<bool> _launchBrowser(Uri uri) async {
    if (!await _browserLauncher(uri)) {
      throw const DriveAuthException(
        'The system browser could not be opened for Google sign-in.',
      );
    }
    return true;
  }

  Future<Map<String, dynamic>> _request(
    Uri uri,
    int epoch, {
    Map<String, String>? body,
    String? bearer,
  }) async {
    _check(epoch);
    final client = _clientFactory();
    _clients.add(client);
    try {
      final response =
          await (body == null
                  ? client.get(
                      uri,
                      headers: {'Authorization': 'Bearer $bearer'},
                    )
                  : client.post(uri, body: body))
              .timeout(const Duration(seconds: 25));
      _check(epoch);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const DriveAuthException(
          'Google returned an invalid sign-in response.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (uri.toString() == _tokenEndpoint &&
            decoded['error'] == 'invalid_grant') {
          return {'error': 'invalid_grant'};
        }
        throw const DriveAuthException(
          'Google could not authorize Drive access. Check your connection and OAuth setup.',
        );
      }
      return decoded;
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  void _clearMemory() {
    _identity = null;
    _androidAccount = null;
    _token = null;
    _expiresAt = null;
    _refreshToken = null;
  }

  void _cancelPending() {
    final callback = _callback;
    if (callback != null && !callback.isCompleted) {
      callback.completeError(
        const DriveAuthException('Google sign-in was cancelled.'),
      );
    }
    unawaited(_callbackServer?.close(force: true));
    _callbackServer = null;
    _callback = null;
    for (final client in _clients.toList()) {
      client.close();
    }
  }

  @override
  Future<void> disconnect() => _safe(() async {
    ++_epoch;
    final refresh = _refreshToken;
    _cancelPending();
    _clearMemory();
    _connecting = null;
    _refreshing = null;
    if (_desktop) {
      // Delete before best-effort revocation, including any earlier queued write.
      await _deleteCredentials();
      if (refresh != null) {
        final client = _clientFactory();
        try {
          await client
              .post(Uri.parse(_revokeEndpoint), body: {'token': refresh})
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          // Local disconnect still succeeds when Google is offline.
        } finally {
          client.close();
        }
      }
    } else if (_platform == TargetPlatform.android &&
        _androidInitialization != null) {
      await _initializeAndroid();
      await GoogleSignIn.instance.disconnect();
    }
  });

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _cancelPending();
    _clearMemory();
  }

  static String _randomString() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static bool _constantTimeEqual(String left, String right) {
    var difference = left.length ^ right.length;
    for (var index = 0; index < left.length; index++) {
      difference |=
          left.codeUnitAt(index) ^
          (index < right.length ? right.codeUnitAt(index) : 0);
    }
    return difference == 0;
  }
}
