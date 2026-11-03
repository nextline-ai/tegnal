import 'package:shared_preferences/shared_preferences.dart';

/// The subset of `UserDefaults` the core logic reads. Values keep their type,
/// so `object(forKey:) as? Int` and friends translate directly.
abstract class Preferences {
  Object? object(String key);
  void set(String key, Object? value);
  void remove(String key) => set(key, null);

  String? string(String key) => object(key) is String ? object(key) as String : null;
  int? integerOrNull(String key) => object(key) is int ? object(key) as int : null;

  /// `UserDefaults.integer(forKey:)`, which reads 0 for a missing value.
  int integer(String key) => integerOrNull(key) ?? 0;
  bool? boolean(String key) => object(key) is bool ? object(key) as bool : null;
}

class MemoryPreferences extends Preferences {
  MemoryPreferences([Map<String, Object?>? values]) : _values = {...?values};
  final Map<String, Object?> _values;

  @override
  Object? object(String key) => _values[key];

  @override
  void set(String key, Object? value) => value == null ? _values.remove(key) : _values[key] = value;
}

/// Persistent preferences. Each native suite becomes a key prefix in one store.
/// Like `UserDefaults`, a value reads back at once and reaches disk shortly after.
class StoredPreferences extends Preferences {
  StoredPreferences._(this._store, this._prefix, this._pending);
  final SharedPreferencesWithCache _store;
  final String _prefix;
  final Set<Future<void>> _pending;

  @override
  Object? object(String key) => _store.get(_prefix + key);

  @override
  void set(String key, Object? value) {
    final name = _prefix + key;
    final Future<void> write = switch (value) {
      null => _store.remove(name),
      bool value => _store.setBool(name, value),
      int value => _store.setInt(name, value),
      double value => _store.setDouble(name, value),
      String value => _store.setString(name, value),
      List<String> value => _store.setStringList(name, value),
      _ => throw ArgumentError.value(value, key, 'Unsupported preference type'),
    };
    _pending.add(write);
    write.whenComplete(() => _pending.remove(write));
  }
}

/// `ReaderPreferences.defaults` (comics and shared library options) and
/// `ReaderPreferences.booruDefaults` (image mode) are kept apart as in the native app.
class AppPreferences {
  AppPreferences({required this.defaults, required this.booruDefaults}) : _pending = {};
  AppPreferences.memory() : defaults = MemoryPreferences(), booruDefaults = MemoryPreferences(), _pending = {};
  AppPreferences._(this.defaults, this.booruDefaults, this._pending);

  final Preferences defaults;
  final Preferences booruDefaults;
  final Set<Future<void>> _pending;

  /// Loaded once at launch; every later read is served from memory.
  static Future<AppPreferences> load() async {
    final store = await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions());
    final pending = <Future<void>>{};
    return AppPreferences._(StoredPreferences._(store, '', pending), StoredPreferences._(store, 'booru.suite.', pending), pending);
  }

  /// Waits until every value set so far is on disk, for example before the app is suspended.
  Future<void> flush() => Future.wait([..._pending]);
}
