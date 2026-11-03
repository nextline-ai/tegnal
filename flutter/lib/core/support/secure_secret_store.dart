import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../content/site_account.dart';

/// The asynchronous key-value secure storage behind [SecureSecretStore].
abstract interface class SecureStorage {
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore-wrapped storage (`flutter_secure_storage`), the app's keychain.
class KeystoreStorage implements SecureStorage {
  KeystoreStorage([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());
  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecureStorage implements SecureStorage {
  final values = <String, String>{};
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// The synchronous [SecretStore] that [SiteAccount] reads, backed by secure storage.
/// Everything is read once at launch ([load]); reads are then served from memory, and
/// writes update memory at once and reach storage in order in the background.
class SecureSecretStore implements SecretStore {
  SecureSecretStore._(this._storage, this._values);

  /// Values are namespaced so other secure entries never mix with these.
  static const _prefix = 'tegnal.secret.';

  static Future<SecureSecretStore> load([SecureStorage? storage]) async {
    final backing = storage ?? KeystoreStorage();
    Map<String, String> all;
    try {
      all = await backing.readAll();
    } on Object {
      // An unreadable store (a reset Keystore) behaves as signed out.
      all = {};
    }
    return SecureSecretStore._(backing, {
      for (final MapEntry(:key, :value) in all.entries)
        if (key.startsWith(_prefix)) key.substring(_prefix.length): value,
    });
  }

  final SecureStorage _storage;
  final Map<String, String> _values;
  Future<void> _pending = Future.value();

  @override
  String? read(String name) => _values[name];

  @override
  void write(String name, String? value) {
    if (value == null) {
      _values.remove(name);
    } else {
      _values[name] = value;
    }
    _pending = _pending.then((_) async {
      try {
        if (value == null) {
          await _storage.delete(_prefix + name);
        } else {
          await _storage.write(_prefix + name, value);
        }
      } on Object {
        // Memory keeps the value for this run; the next launch reads what storage holds.
      }
    });
  }

  /// Completes once every earlier write reached storage.
  Future<void> flush() => _pending;
}
