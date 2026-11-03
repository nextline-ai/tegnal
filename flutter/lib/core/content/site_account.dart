import 'dart:convert';
import 'dart:io';

import 'manga_urls.dart';

/// Some catalogs open a work by its number plus a short key. The key is only a
/// cache: a forgotten one is found again by searching the number.
class GalleryKeys {
  GalleryKeys({this.file, this.limit = 50000});

  /// The app replaces this with a file-backed instance in its support directory at launch.
  static GalleryKeys shared = GalleryKeys();

  final File? file;
  final int limit;
  final _keys = <int, String>{};
  final _order = <int>[];
  bool _loaded = false;
  bool _saving = false;

  static bool isKey(String value) => RegExp(r'^[0-9a-f]{10}$').hasMatch(value);

  String? key(int id) {
    _loadIfNeeded();
    return _keys[id];
  }

  void remember(int id, String key) => rememberAll([(id, key)]);

  void rememberAll(List<(int, String)> pairs) {
    _loadIfNeeded();
    var changed = false;
    for (final (id, key) in pairs) {
      if (id <= 0 || !isKey(key) || _keys[id] == key) continue;
      if (!_keys.containsKey(id)) _order.add(id);
      _keys[id] = key;
      changed = true;
    }
    if (_order.length > limit) {
      final dropped = _order.length - limit * 9 ~/ 10;
      for (final id in _order.take(dropped)) {
        _keys.remove(id);
      }
      _order.removeRange(0, dropped);
    }
    if (changed) _scheduleSave();
  }

  void removeAll() {
    _keys.clear();
    _order.clear();
    _loaded = true;
    final file = this.file;
    if (file != null && file.existsSync()) file.deleteSync();
  }

  void _loadIfNeeded() {
    if (_loaded) return;
    _loaded = true;
    final file = this.file;
    if (file == null || !file.existsSync()) return;
    try {
      final rows = jsonDecode(file.readAsStringSync());
      if (rows is! List) return;
      for (final row in rows) {
        if (row is! List || row.length != 2 || row[0] is! String || row[1] is! String) continue;
        final id = int.tryParse(row[0] as String);
        if (id == null || !isKey(row[1] as String) || _keys.containsKey(id)) continue;
        _keys[id] = row[1] as String;
        _order.add(id);
      }
    } on Object {
      // A damaged cache is rebuilt as works are seen again.
    }
  }

  void _scheduleSave() {
    final file = this.file;
    if (file == null || _saving) return;
    _saving = true;
    Future<void>.delayed(const Duration(seconds: 2), () {
      _saving = false;
      final rows = [
        for (final id in _order)
          if (_keys[id] case final key?) ['$id', key],
      ];
      try {
        file.parent.createSync(recursive: true);
        final temporary = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(rows), flush: true);
        temporary.renameSync(file.path);
      } on FileSystemException {
        // Keys are a cache; a failed save only costs a search later.
      }
    });
  }
}

/// Where the signed-in identity is kept: the Android Keystore in the app, memory in tests.
abstract interface class SecretStore {
  String? read(String name);
  void write(String name, String? value);
}

class MemorySecretStore implements SecretStore {
  final _values = <String, String>{};
  @override
  String? read(String name) => _values[name];
  @override
  void write(String name, String? value) => value == null ? _values.remove(name) : _values[name] = value;
}

/// A cookie as a sign-in page or response hands it over.
class SiteCookie {
  const SiteCookie({required this.name, required this.value, this.expires});
  final String name;
  final String value;
  final DateTime? expires;
}

class _Stored {
  _Stored({Map<String, String>? identity, Map<String, Map<String, String>>? sites}) : identity = identity ?? {}, sites = sites ?? {};
  Map<String, String> identity;

  /// Cookies the connected site set for itself, by host.
  Map<String, Map<String, String>> sites;

  factory _Stored.fromJson(Map<String, Object?> json) => _Stored(
    identity: {...?(json['identity'] as Map?)?.cast<String, String>()},
    sites: {
      for (final MapEntry(:key, :value) in ((json['sites'] as Map?) ?? {}).entries) key as String: {...(value as Map).cast<String, String>()},
    },
  );
  Map<String, Object?> toJson() => {'identity': identity, 'sites': sites};
}

/// The signed-in identity a catalog may ask for, kept in secure storage.
/// Only the account's identity cookies are kept from sign-in, and they reach
/// nothing but the connected site and its own subdomains.
abstract final class SiteAccount {
  static const _secretName = 'site-account';

  /// The app installs a Keystore-backed store at launch.
  static SecretStore store = MemorySecretStore();
  static _Stored? _cached;
  static SecretStore? _cachedStore;

  /// Notified after a sign-in or sign-out, like `siteAccountDidChange`.
  static final listeners = <void Function()>[];

  /// Names follow the forum software these catalogs share, not any one site.
  static bool isIdentity(String name) => name.endsWith('_member_id') || name.endsWith('_pass_hash');

  static bool get isSignedIn => _signedIn(_load().identity);

  static bool _signedIn(Map<String, String> identity) =>
      identity.entries.any((entry) => entry.key.endsWith('_member_id') && (int.tryParse(entry.value) ?? 0) > 0) &&
      identity.entries.any((entry) => entry.key.endsWith('_pass_hash') && entry.value.isNotEmpty);

  /// Keeps the identity from a finished sign-in. Returns false when the cookies hold none.
  static bool signIn(List<SiteCookie> cookies) {
    final identity = {
      for (final cookie in cookies)
        if (isIdentity(cookie.name) && cookie.value.isNotEmpty) cookie.name: cookie.value,
    };
    if (!_signedIn(identity)) return false;
    final stored = _load()
      ..identity = identity
      ..sites.clear();
    _save(stored);
    _notify();
    return true;
  }

  static void signOut() {
    _save(_Stored());
    _notify();
  }

  static void _notify() {
    for (final listener in [...listeners]) {
      listener();
    }
  }

  /// The connected site and its subdomains, while that site is one that uses accounts.
  static bool applies(Uri url) {
    if (url.scheme != 'https' || url.host.isEmpty) return false;
    final host = url.host.toLowerCase();
    final site = MangaUrls.configuredHost;
    if (site.isEmpty || !(host == site || host.endsWith('.$site') || host.endsWith('.${registrableDomain(site)}'))) return false;
    return MangaUrls.usesAccount;
  }

  static String? cookieHeader(Uri url) {
    if (!applies(url)) return null;
    final values = cookies(MangaUrls.configuredHost);
    if (values.isEmpty) return null;
    final names = values.keys.toList()..sort();
    return names.map((name) => '$name=${values[name]}').join('; ');
  }

  /// What the site expects back: the identity, cookies it set, and consent to open flagged works.
  static Map<String, String> cookies(String host) {
    final stored = _load();
    final values = {...?stored.sites[host]};
    values['nw'] = '1';
    if (_signedIn(stored.identity)) values.addAll(stored.identity);
    return values;
  }

  /// The cookies to place in the sign-in browser for the connected site.
  static List<SiteCookie> browserCookies(String host) {
    if (!MangaUrls.usesAccount || host != MangaUrls.configuredHost) return [];
    return [for (final MapEntry(:key, :value) in cookies(host).entries) SiteCookie(name: key, value: value)];
  }

  /// Keeps cookies the site sets for itself, such as access it grants after the identity is checked.
  static void storeResponse(Uri url, List<String> setCookieHeaders) {
    if (!applies(url) || setCookieHeaders.isEmpty) return;
    final received = <SiteCookie>[];
    for (final header in setCookieHeaders) {
      try {
        final cookie = Cookie.fromSetCookieValue(header);
        if (isIdentity(cookie.name) || cookie.name == 'nw') continue;
        received.add(SiteCookie(name: cookie.name, value: cookie.value, expires: cookie.expires));
      } on FormatException {
        continue;
      }
    }
    if (received.isEmpty) return;
    final host = MangaUrls.configuredHost;
    final stored = _load();
    final site = {...?stored.sites[host]};
    for (final cookie in received) {
      final expired = cookie.expires != null && cookie.expires!.isBefore(DateTime.now());
      if (expired || cookie.value.isEmpty || cookie.value == 'deleted') {
        site.remove(cookie.name);
      } else {
        site[cookie.name] = cookie.value;
      }
    }
    final previous = stored.sites[host] ?? {};
    if (previous.length == site.length && previous.entries.every((entry) => site[entry.key] == entry.value)) return;
    stored.sites[host] = site;
    _save(stored);
  }

  static String registrableDomain(String host) {
    final labels = host.split('.').where((label) => label.isNotEmpty).toList();
    return labels.length > 2 ? labels.sublist(labels.length - 2).join('.') : host;
  }

  static _Stored _load() {
    if (_cached != null && identical(_cachedStore, store)) return _cached!;
    var result = _Stored();
    final saved = store.read(_secretName);
    if (saved != null) {
      try {
        result = _Stored.fromJson(jsonDecode(saved) as Map<String, Object?>);
      } on Object {
        result = _Stored();
      }
    }
    _cached = result;
    _cachedStore = store;
    return result;
  }

  static void _save(_Stored stored) {
    _cached = stored;
    _cachedStore = store;
    store.write(_secretName, stored.identity.isEmpty && stored.sites.isEmpty ? null : jsonEncode(stored.toJson()));
  }
}
