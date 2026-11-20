import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The app's preferences store as the backup engine reaches it. The launch step runs before
/// `AppPreferences.load()`, so this goes straight to the plugin and keeps no cache: every call reads or
/// writes the store itself. Values are `bool`, `int`, `double`, `String` and `List<String>`.
abstract interface class BackupPreferenceStore {
  Future<Map<String, Object>> all();
  Future<Object?> get(String key);

  /// A null value removes the key.
  Future<void> set(String key, Object? value);

  /// Makes the store hold exactly [values]: changed and new keys are written, the rest removed. Nothing
  /// is cleared first, so a failure part way leaves keys rather than an empty store.
  Future<void> replaceAll(Map<String, Object> values);
}

/// The plugin's async API with default options, which is the same store `SharedPreferencesWithCache`
/// (behind `AppPreferences`) reads and writes.
class SharedPreferencesBackupStore implements BackupPreferenceStore {
  SharedPreferencesBackupStore([SharedPreferencesAsync? store]) : _store = store ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _store;

  @override
  Future<Map<String, Object>> all() async => {for (final MapEntry(:key, :value) in (await _store.getAll()).entries) key: ?value};

  @override
  Future<Object?> get(String key) async => (await _store.getAll(allowList: {key}))[key];

  @override
  Future<void> set(String key, Object? value) => switch (value) {
    null => _store.remove(key),
    bool value => _store.setBool(key, value),
    int value => _store.setInt(key, value),
    double value => _store.setDouble(key, value),
    String value => _store.setString(key, value),
    List<String> value => _store.setStringList(key, value),
    _ => throw ArgumentError.value(value, key, 'Unsupported preference type'),
  };

  @override
  Future<void> replaceAll(Map<String, Object> values) async {
    final current = await all();
    for (final key in current.keys) {
      if (!values.containsKey(key)) await _store.remove(key);
    }
    for (final MapEntry(:key, :value) in values.entries) {
      if (!BackupPreferences.same(current[key], value)) await set(key, value);
    }
  }
}

/// A store in memory, for tests and for runs without a platform.
class MemoryBackupStore implements BackupPreferenceStore {
  MemoryBackupStore([Map<String, Object>? values]) : values = {...?values};
  final Map<String, Object> values;

  @override
  Future<Map<String, Object>> all() async => {...values};

  @override
  Future<Object?> get(String key) async => values[key];

  @override
  Future<void> set(String key, Object? value) async => value == null ? values.remove(key) : values[key] = value;

  @override
  Future<void> replaceAll(Map<String, Object> next) async {
    values
      ..clear()
      ..addAll(next);
  }
}

/// The `prefs/store.json` entry: every key with its type, so a restore writes back exactly what was there.
abstract final class BackupPreferences {
  /// The image mode's preferences share the store under this prefix (`AppPreferences.booruDefaults`).
  static const imagePrefix = 'booru.suite.';

  static bool same(Object? a, Object? b) {
    if (a is List && b is List) return a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((equal) => equal);
    return a == b && a.runtimeType == b.runtimeType;
  }

  static List<int> encode(Map<String, Object> values) {
    final typed = <String, Object>{};
    for (final key in values.keys.toList()..sort()) {
      final value = values[key]!;
      typed[key] = switch (value) {
        bool value => {'type': 'bool', 'value': value},
        int value => {'type': 'int', 'value': value},
        // Text, so NaN and infinity survive.
        double value => {'type': 'double', 'value': value.toString()},
        String value => {'type': 'string', 'value': value},
        List value => {'type': 'stringList', 'value': value.whereType<String>().toList()},
        _ => throw ArgumentError.value(value, key, 'Unsupported preference type'),
      };
    }
    return utf8.encode(jsonEncode({'format': 'tegnal-preferences', 'version': 1, 'values': typed}));
  }

  /// Null when the bytes are not a preferences entry.
  static Map<String, Object>? decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?> || json['format'] != 'tegnal-preferences' || json['version'] != 1) return null;
      final typed = json['values'];
      if (typed is! Map<String, Object?>) return null;
      final values = <String, Object>{};
      for (final MapEntry(:key, :value) in typed.entries) {
        if (value is! Map<String, Object?>) return null;
        final stored = value['value'];
        values[key] = switch (value['type']) {
          'bool' when stored is bool => stored,
          'int' when stored is int => stored,
          'double' when stored is String => double.parse(stored),
          'string' when stored is String => stored,
          'stringList' when stored is List => stored.cast<String>().toList(),
          _ => throw const FormatException('Unknown preference type'),
        };
      }
      return values;
    } on Object {
      return null;
    }
  }
}
