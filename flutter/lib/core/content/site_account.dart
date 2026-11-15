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

  /// Forgets a key the site no longer accepts, so the number is searched again.
  void forget(int id) {
    _loadIfNeeded();
    if (_keys.remove(id) == null) return;
    _order.remove(id);
    _scheduleSave();
  }

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
  _Stored({
    Map<String, String>? identity,
    Map<String, Map<String, String>>? sites,
    Map<String, Map<String, String>>? sessions,
    Map<String, Map<String, String>>? identities,
  }) : identity = identity ?? {},
       sites = sites ?? {},
       sessions = sessions ?? {},
       identities = identities ?? {};

  /// The forum identity every website shared before each kept its own; on first read it moves
  /// to the websites connected at the time.
  Map<String, String> identity;

  /// Each website's forum identity, by host.
  Map<String, Map<String, String>> identities;

  /// Whether this was read from a sign-in kept before each website had its own.
  bool fromShared = false;

  /// Cookies the connected site set for itself, by host.
  Map<String, Map<String, String>> sites;

  /// Sign-ins made on a site's own pages, by host: the cookies its pages set once signed in.
  Map<String, Map<String, String>> sessions;

  static Map<String, Map<String, String>> _byHost(Object? value) => {
    for (final MapEntry(:key, :value) in ((value as Map?) ?? {}).entries) key as String: {...(value as Map).cast<String, String>()},
  };

  factory _Stored.fromJson(Map<String, Object?> json) => _Stored(
    identity: {...?(json['identity'] as Map?)?.cast<String, String>()},
    sites: _byHost(json['sites']),
    // Missing in sign-ins kept before these existed.
    sessions: _byHost(json['sessions']),
    identities: _byHost(json['identities']),
  )..fromShared = !json.containsKey('identities');
  Map<String, Object?> toJson() => {
    if (identity.isNotEmpty) 'identity': identity,
    'sites': sites,
    if (sessions.isNotEmpty) 'sessions': sessions,
    'identities': identities,
  };
  bool get isEmpty => identity.isEmpty && sites.isEmpty && sessions.isEmpty && identities.isEmpty;
}

/// What a person pasted from a browser where they are signed in.
class PastedCookies {
  PastedCookies({Map<String, String>? identity, Map<String, String>? site}) : identity = identity ?? {}, site = site ?? {};
  final Map<String, String> identity;

  /// Other cookies the site keeps for the account, such as access to a members-only catalog.
  final Map<String, String> site;
  bool get isComplete => SiteAccount._signedIn(identity);
}

/// The signed-in identities catalogs ask for, kept in secure storage, one per website. Only an
/// account's identity cookies are kept from sign-in, and they reach nothing but the website they
/// were signed in for and its own subdomains.
abstract final class SiteAccount {
  /// Websites that signed an account in but handed it the placeholder instead of access.
  static final _refused = <String>{};

  static const _secretName = 'site-account';

  /// The app installs a Keystore-backed store at launch.
  static SecretStore store = MemorySecretStore();
  static _Stored? _cached;
  static SecretStore? _cachedStore;

  /// Notified after a sign-in or sign-out, like `siteAccountDidChange`.
  static final listeners = <void Function()>[];

  /// Names follow the forum software these catalogs share, not any one site.
  static bool isIdentity(String name) => name.endsWith('_member_id') || name.endsWith('_pass_hash');

  /// The cookie a members-only catalog hands an account it lets in.
  static const accessCookie = 'igneous';

  /// A value the site sends instead of access when the account is not let in. Keeping it would
  /// keep the account out even after the account is allowed.
  static bool isPlaceholder(String name, String value) => name == accessCookie && (value.isEmpty || value == 'mystery' || value == 'deleted');

  /// Whether the connected website keeps a forum identity of its own.
  static bool get isSignedIn => hasIdentity(MangaUrls.configuredHost);

  /// Whether [host] keeps a forum identity of its own.
  static bool hasIdentity(String host) => host.isNotEmpty && _signedIn(_load().identities[host] ?? const {});

  /// Whether [host] has an account: its forum identity, or a sign-in made on its own pages.
  static bool isSignedInAt(String host) {
    final stored = _load();
    return (stored.sessions[host] ?? const {}).isNotEmpty || _signedIn(stored.identities[host] ?? const {});
  }

  /// Whether [host] signed its account in but hands it the placeholder instead of access: a
  /// members-only catalog that hasn't opened to this account.
  static bool refusesAccess(String host) => _refused.contains(host) && hasIdentity(host);

  /// Signs [host] in with the account another website keeps, as for two websites of one forum.
  static bool useAccount({required String from, required String on}) => _keep({...?_load().identities[from]}, host: on);

  /// Other websites keeping a forum identity that [host] could use too.
  static List<String> accountSources({required String excluding}) => [
    for (final MapEntry(:key, :value) in _load().identities.entries)
      if (key != excluding && _signedIn(value)) key,
  ]..sort();

  /// Keeps [identity] for [host]; cookies the website set for another account no longer apply.
  static bool _keep(Map<String, String> identity, {Map<String, String>? site, required String host}) {
    if (!_signedIn(identity) || host.isEmpty) return false;
    final stored = _load();
    stored.identities[host] = identity;
    if (site != null && site.isNotEmpty) {
      stored.sites[host] = {...site};
    } else {
      stored.sites.remove(host);
    }
    _refused.remove(host);
    _save(stored);
    _notify();
    return true;
  }

  static bool hasSession(String host) => (_load().sessions[host] ?? const {}).isNotEmpty;

  /// Reads `name=value` pairs from a cookie header, a browser's cookie list or one value per line.
  /// Only the account cookies and cookies the site keeps for it are taken.
  static PastedCookies parseCookies(String text) {
    final result = PastedCookies();
    for (final piece in text.split(RegExp(r'[;\n\r\t,]'))) {
      var pair = piece.trim();
      if (pair.toLowerCase().startsWith('cookie:')) pair = pair.substring(7).trim();
      final equals = pair.indexOf('=');
      if (equals <= 0) continue;
      final name = pair.substring(0, equals).trim();
      final value = pair.substring(equals + 1).trim().replaceAll(RegExp('^["\']+|["\']+\$'), '');
      if (!_isCookieName(name) || !_isCookieValue(value)) continue;
      if (isIdentity(name)) {
        result.identity[name] = value;
      } else if (keepsForAccount(name) && !isPlaceholder(name, value)) {
        result.site[name] = value;
      }
    }
    return result;
  }

  /// Cookies an account carries besides its identity: access, settings key and perks.
  static bool keepsForAccount(String name) => const [accessCookie, 'sk', 'sp', 'star', 'hath_perks', 'iq'].contains(name);

  static bool _isCookieName(String name) => name.isNotEmpty && name.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name);

  static bool _isCookieValue(String value) => value.isNotEmpty && value.length <= 512 && RegExp(r'^[\x21-\x3A\x3C-\x7E]+$').hasMatch(value);

  /// Signs [host] in with cookies copied from a browser; the other cookies belong to [host] too.
  static bool signInPasted(PastedCookies pasted, {required String host}) {
    if (!pasted.isComplete) return false;
    return _keep({...pasted.identity}, site: pasted.site, host: host);
  }

  /// Keeps a sign-in made on [host]'s own pages: the cookies its pages set for it, apart from a
  /// bot check's and analytics. Returns false when none are left.
  static bool signInSession(List<SiteCookie> cookies, {required String host}) {
    final values = {
      for (final cookie in cookies)
        if (cookie.value.isNotEmpty &&
            _isCookieName(cookie.name) &&
            _isCookieValue(cookie.value) &&
            !SiteClearance.isClearanceCookie(cookie.name) &&
            !cookie.name.startsWith('_ga') &&
            !cookie.name.startsWith('_gid') &&
            !(cookie.expires?.isBefore(DateTime.now()) ?? false))
          cookie.name: cookie.value,
    };
    if (values.isEmpty || host.isEmpty) return false;
    final stored = _load();
    stored.sessions[host] = values;
    _save(stored);
    _notify();
    return true;
  }

  /// Drops one cookie the site set, so the site hands out a fresh one on the next request.
  static void forget(String name, {required String host}) {
    if (name == accessCookie) _refused.remove(host);
    final stored = _load();
    if (stored.sites[host]?.remove(name) == null) return;
    _save(stored);
  }

  /// The value of a cookie the site set for [host], as the next request sends it.
  static String? siteCookie(String name, {required String host}) => _load().sites[host]?[name];

  /// Sets a cookie for [host] the way the website's own pages would, such as its settings profile.
  static void setSiteCookie(String name, String value, {required String host}) {
    if (!_isCookieName(name) || !_isCookieValue(value) || host.isEmpty) return;
    final stored = _load();
    final site = stored.sites.putIfAbsent(host, () => {});
    if (site[name] == value) return;
    site[name] = value;
    _save(stored);
  }

  /// Drops a cookie the site refused, unless the same answer already handed out another one:
  /// a members-only catalog may show its wall to a request without access while setting the
  /// access that lets the next request in.
  static void forgetRefused(String name, {required String host, required String? sent}) {
    final stored = _load();
    final current = stored.sites[host]?[name];
    if (current == null || current != sent) return;
    stored.sites[host]!.remove(name);
    _save(stored);
  }

  /// The account cookie names saved for [host], for showing what is kept without the values.
  static List<String> savedCookieNames(String host) {
    final stored = _load();
    final identity = stored.identities[host];
    if (identity == null || !_signedIn(identity)) return [];
    return [...identity.keys, ...?stored.sites[host]?.keys]..sort();
  }

  /// Signs one website out; other websites keep their accounts.
  static void signOutAt(String host) {
    final stored = _load();
    stored.sessions.remove(host);
    stored.identities.remove(host);
    stored.sites.remove(host);
    _refused.remove(host);
    _save(stored);
    _notify();
  }

  static bool _signedIn(Map<String, String> identity) =>
      identity.entries.any((entry) => entry.key.endsWith('_member_id') && (int.tryParse(entry.value) ?? 0) > 0) &&
      identity.entries.any((entry) => entry.key.endsWith('_pass_hash') && entry.value.isNotEmpty);

  /// Keeps the identity from a finished sign-in for [host]. Returns false when the cookies hold none.
  static bool signIn(List<SiteCookie> cookies, {required String host}) => _keep({
    for (final cookie in cookies)
      if (isIdentity(cookie.name) && cookie.value.isNotEmpty) cookie.name: cookie.value,
  }, host: host);

  /// Signs every website out.
  static void signOut() {
    _refused.clear();
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

  /// What the site expects back: its identity, cookies it set, and consent to open flagged works.
  static Map<String, String> cookies(String host) {
    final stored = _load();
    final values = {...?stored.sessions[host]};
    // What the site set later, such as a renewed session, replaces what sign-in kept. Cookies
    // kept before they were known to be ignored are not sent either.
    for (final MapEntry(:key, :value) in (stored.sites[host] ?? const <String, String>{}).entries) {
      if (!isPlaceholder(key, value) && !ignoresCookie(key) && !SiteClearance.isClearanceCookie(key)) values[key] = value;
    }
    values['nw'] = '1';
    final identity = stored.identities[host];
    if (identity != null && _signedIn(identity)) values.addAll(identity);
    return values;
  }

  /// The cookies to place in the sign-in browser for the connected site.
  static List<SiteCookie> browserCookies(String host) {
    if (!MangaUrls.usesAccount || host != MangaUrls.configuredHost) return [];
    return [for (final MapEntry(:key, :value) in cookies(host).entries) SiteCookie(name: key, value: value)];
  }

  /// Keeps cookies the site sets for itself, such as access it grants after the identity is checked.
  /// Cookies a site sets that are never kept: the content filter it sets itself, a tracking
  /// cookie other clients drop because sending it back changes how the site answers, and the mark
  /// a members-only catalog leaves on a visit without access, which other clients delete at every
  /// launch and sign-in so it can't keep an account that has access out.
  static bool ignoresCookie(String name) => const ['nw', '__utmp', 'yay'].contains(name);

  static void storeResponse(Uri url, List<String> setCookieHeaders) {
    if (!applies(url) || setCookieHeaders.isEmpty) return;
    final received = <SiteCookie>[];
    for (final header in setCookieHeaders) {
      try {
        final cookie = Cookie.fromSetCookieValue(header);
        // A bot check's cookies are kept with the browser that earned them, never here.
        if (isIdentity(cookie.name) || ignoresCookie(cookie.name) || SiteClearance.isClearanceCookie(cookie.name)) continue;
        if (cookie.name == accessCookie) {
          final expired = cookie.expires != null && cookie.expires!.isBefore(DateTime.now());
          if (cookie.value == 'mystery') {
            _refused.add(MangaUrls.configuredHost);
          } else if (!expired && !isPlaceholder(cookie.name, cookie.value)) {
            _refused.remove(MangaUrls.configuredHost);
          }
        }
        // A placeholder instead of access is never kept: the access already held stays.
        if (isPlaceholder(cookie.name, cookie.value)) continue;
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
    if (result.fromShared) {
      // An account kept before each website had its own stays with every website connected now.
      if (_signedIn(result.identity)) {
        for (final host in {...ComicSites.all, ...result.sites.keys}) {
          if (host.isNotEmpty) result.identities[host] = {...result.identity};
        }
      }
      result
        ..identity = {}
        ..fromShared = false;
      _save(result);
    }
    _cached = result;
    _cachedStore = store;
    return result;
  }

  static void _save(_Stored stored) {
    _cached = stored;
    _cachedStore = store;
    store.write(_secretName, stored.isEmpty ? null : jsonEncode(stored.toJson()));
  }
}

/// What a website's bot check hands a browser that passed it, kept per website with the exact
/// browser identity that earned it: the check accepts its cookies only from that same browser.
/// The cookies reach nothing but that website and its subdomains.
class ClearanceEntry {
  const ClearanceEntry({required this.cookies, required this.userAgent, required this.savedAt});
  final Map<String, String> cookies;
  final String userAgent;
  final DateTime savedAt;

  factory ClearanceEntry.fromJson(Map<String, Object?> json) => ClearanceEntry(
    cookies: {...?(json['cookies'] as Map?)?.cast<String, String>()},
    userAgent: json['userAgent'] as String? ?? '',
    savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
  Map<String, Object?> toJson() => {'cookies': cookies, 'userAgent': userAgent, 'savedAt': savedAt.toIso8601String()};
}

abstract final class SiteClearance {
  static const _secretName = 'site-clearance';
  static Map<String, ClearanceEntry>? _cached;
  static SecretStore? _cachedStore;

  /// Notified when a check is passed or forgotten.
  static final listeners = <void Function()>[];

  /// Cookies the bot check sets. Nothing else from the check's browser is kept.
  static bool isClearanceCookie(String name) => name.startsWith('cf_') || name.startsWith('__cf');

  /// The website a host belongs to, so a check passed on one of its hosts covers the others.
  static String domain(String host) => SiteAccount.registrableDomain(host.toLowerCase());

  static ClearanceEntry? entryFor(Uri url) => url.scheme == 'https' && url.host.isNotEmpty ? entry(url.host) : null;

  static ClearanceEntry? entry(String host) => _load()[domain(host)];

  static bool hasClearance(String host) => entry(host) != null;

  /// Keeps a passed check. Returns false when the cookies hold no clearance.
  static bool save(List<SiteCookie> cookies, {required String userAgent, required String host}) {
    final values = {
      for (final cookie in cookies)
        if (isClearanceCookie(cookie.name) && cookie.value.isNotEmpty && !(cookie.expires?.isBefore(DateTime.now()) ?? false)) cookie.name: cookie.value,
    };
    if (!values.containsKey('cf_clearance') || userAgent.isEmpty) return false;
    final entries = _load()..[domain(host)] = ClearanceEntry(cookies: values, userAgent: userAgent, savedAt: DateTime.now());
    _save(entries);
    _notify();
    return true;
  }

  /// Forgets a website's passed check, as when the website asks again.
  static void remove(String host) {
    final entries = _load();
    if (entries.remove(domain(host)) == null) return;
    _save(entries);
    _notify();
  }

  static void removeAll() {
    _save({});
    _notify();
  }

  static void _notify() {
    for (final listener in [...listeners]) {
      listener();
    }
  }

  static Map<String, ClearanceEntry> _load() {
    final store = SiteAccount.store;
    if (_cached != null && identical(_cachedStore, store)) return _cached!;
    final result = <String, ClearanceEntry>{};
    final saved = store.read(_secretName);
    if (saved != null) {
      try {
        for (final MapEntry(:key, :value) in (jsonDecode(saved) as Map).entries) {
          result[key as String] = ClearanceEntry.fromJson((value as Map).cast<String, Object?>());
        }
      } on Object {
        result.clear();
      }
    }
    _cached = result;
    _cachedStore = store;
    return result;
  }

  static void _save(Map<String, ClearanceEntry> entries) {
    _cached = entries;
    _cachedStore = SiteAccount.store;
    SiteAccount.store.write(_secretName, entries.isEmpty ? null : jsonEncode({for (final MapEntry(:key, :value) in entries.entries) key: value.toJson()}));
  }
}
