import 'dart:async';
import 'dart:convert';

import '../support/preferences.dart';
import 'content_errors.dart';
import 'content_transport.dart';
import 'content_url.dart';
import 'document_catalog_source.dart';
import 'keyed_catalog_source.dart';
import 'site_account.dart';

/// Test hosts and previews must never rewrite an installed app’s connection.
abstract final class ContentPreferences {
  /// True for tests and the offline fixture run, which may connect `.example` addresses.
  static bool isIsolated = false;

  /// The app's standard preferences, installed at launch.
  static Preferences defaults = MemoryPreferences();
}

/// `SiteScope`: the connected website a request is for. Lists that show every connected
/// website at once read the other websites inside their scope, so the checked website never
/// has to change: what was learned about a website that is not checked lives in its saved
/// snapshot. The scope follows the request through every `await`.
abstract final class SiteScope {
  static const _key = #tegnalSiteScope;

  static String? get site => Zone.current[_key] as String?;

  /// Runs [body], and everything it waits for, for [site].
  static T run<T>(String? site, T Function() body) => runZoned(body, zoneValues: {_key: site});

  /// The website a scope names when it is not the checked one.
  static String? get other {
    final scoped = site;
    if (scoped == null || scoped.isEmpty || scoped == (ContentPreferences.defaults.string('manga.site_address') ?? '')) return null;
    return scoped;
  }
}

/// `ScopedPreferences`: connection settings as a request sees them: those of the checked
/// website, or inside a [SiteScope] for another website, that website's saved snapshot.
class ScopedPreferences extends Preferences {
  static final shared = ScopedPreferences();
  static final _scopedKeys = {...MangaUrls.resolvedKeys, ...MangaUrls.accountKeys};
  Preferences get _base => ContentPreferences.defaults;

  String? _scoped(String key) {
    final site = SiteScope.other;
    return site != null && (key == 'manga.site_address' || _scopedKeys.contains(key)) ? site : null;
  }

  @override
  Object? object(String key) {
    final site = _scoped(key);
    if (site == null) return _base.object(key);
    if (key == 'manga.site_address') return site;
    final value = ComicSites._snapshots()[site]?[key];
    // JSON brings lists back untyped; settings want a list of text.
    return value is List ? value.whereType<String>().toList() : value;
  }

  @override
  void set(String key, Object? value) {
    final site = _scoped(key);
    if (site == null || key == 'manga.site_address') return _base.set(key, value);
    final snapshots = ComicSites._snapshots();
    final saved = snapshots.putIfAbsent(site, () => {});
    if (value == null) {
      saved.remove(key);
    } else {
      saved[key] = value;
    }
    ComicSites._save(snapshots);
  }
}

/// Pages a keyed catalog links to from its own navigation, on its own host.
enum KeyedFeature {
  toplist,
  watched;

  static KeyedFeature? fromName(String name) => values.where((feature) => feature.name == name).firstOrNull;
}

enum MangaBackend {
  indexed,
  document,
  keyed;

  static MangaBackend? fromRawValue(String? value) => values.where((backend) => backend.name == value).firstOrNull;
}

abstract final class MangaUrls {
  static Preferences get preferences => ScopedPreferences.shared;

  static MangaBackend get backend {
    if (preferences.string('manga.resolved_backend_site') != home) return MangaBackend.indexed;
    return MangaBackend.fromRawValue(preferences.string('manga.resolved_protocol')) ?? MangaBackend.indexed;
  }

  static String configuredHomeIn(Preferences preferences) {
    final saved = preferences.string('manga.site_address');
    if (saved == null || saved.isEmpty) return '';
    final clean = saved.trim();
    if (clean.contains('://')) return clean.endsWith('/') ? clean : '$clean/';
    return 'https://$clean/';
  }

  static String get configuredHome => configuredHomeIn(preferences);
  static String get home => configuredHome;

  static String get configuredHost => ContentURL.parse(home)?.host.toLowerCase() ?? '';

  /// The site address without its trailing slash, which names a comic's source.
  static String sourceIn(Preferences preferences) {
    final home = configuredHomeIn(preferences);
    return home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  }

  static String get source => sourceIn(preferences);

  static String galleryUrl(int galleryId) {
    if (home.isEmpty) return '';
    return switch (backend) {
      MangaBackend.document => '${home}r/$galleryId',
      MangaBackend.keyed => _keyedGalleryURL(galleryId),
      MangaBackend.indexed => '${home}galleries/$galleryId.html',
    };
  }

  static String readerUrl(int galleryId, {int page = 1}) {
    if (home.isEmpty) return '';
    final shown = page < 1 ? 1 : page;
    return switch (backend) {
      MangaBackend.document => '${home}r/$galleryId#$shown',
      MangaBackend.keyed => _keyedGalleryURL(galleryId),
      MangaBackend.indexed => '${home}reader/$galleryId.html#$shown',
    };
  }

  /// Without its key a work is still one search away.
  static String _keyedGalleryURL(int galleryId) {
    final key = GalleryKeys.shared.key(galleryId);
    if (key != null) return '${home}g/$galleryId/$key/';
    return ContentURL.withQueryItems(home, [('f_search', 'gid:$galleryId')]).toString();
  }

  static String artistAllUrl(String artist) {
    if (home.isEmpty) return '';
    final trimmed = artist.trim();
    if (backend == MangaBackend.keyed) {
      return ContentURL.withQueryItems(home, [('f_search', KeyedCatalogSource.remoteTerm('artist:${trimmed.replaceAll(' ', '_')}'))]).toString();
    }
    if (backend == MangaBackend.document) {
      return ContentURL.withQueryItems(home, [('search', 'artist:${trimmed.replaceAll(' ', '_')}')]).toString();
    }
    return '${home}artist/${ContentURL.path(trimmed)}-all.html';
  }

  static String get dataHost {
    if (hasResolvedBackend) {
      final resolved = preferences.string('manga.resolved_data_host');
      if (resolved != null && resolved.isNotEmpty) return resolved;
    }
    if (configuredHost.isEmpty) return '';
    return 'ltn.$configuredHost';
  }

  static String get dataBaseURL => dataHost.isEmpty ? '' : 'https://$dataHost/';

  static String get cdnHost {
    if (hasResolvedBackend) {
      final resolved = preferences.string('manga.resolved_cdn_host');
      if (resolved != null && resolved.isNotEmpty) return resolved;
    }
    return configuredHost;
  }

  /// A discovered backend belongs to the exact address the user connected.
  /// Persist it across launches; only a connection failure or site change refreshes it.
  static bool get hasResolvedBackend =>
      home.isNotEmpty &&
      preferences.string('manga.resolved_backend_site') == home &&
      (preferences.string('manga.resolved_data_host') ?? '').isNotEmpty &&
      (preferences.string('manga.resolved_cdn_host') ?? '').isNotEmpty;

  /// Read host declarations, never execute downloaded JavaScript. Frontend
  /// gallery HTML links are not data endpoints and must not become the backend.
  static bool extractBackend(String text, {String? site}) {
    final target = site ?? home;
    if (target.isEmpty || home != target) return false;
    final hosts = indexedBackendHosts(text);
    if (hosts == null || home != target) return false;
    if (preferences.string('manga.resolved_backend_site') != target) {
      preferences.remove('manga.resolved_media_hosts');
      preferences.remove('manga.resolved_preview_base');
    }
    preferences.set('manga.resolved_data_host', hosts.dataHost);
    preferences.set('manga.resolved_cdn_host', hosts.cdn);
    preferences.set('manga.resolved_backend_site', target);
    preferences.set('manga.resolved_protocol', MangaBackend.indexed.name);
    return true;
  }

  /// Protocol recognition without changing the user’s configured connection.
  static ({String dataHost, String cdn})? indexedBackendHosts(String text) {
    String? capture(String pattern) => RegExp(pattern, caseSensitive: false).firstMatch(text)?.group(1)?.toLowerCase();
    const domainPattern = r'''(?:var|let|const)\s+domain\s*=\s*['"]([a-z0-9-]+(?:\.[a-z0-9-]+)+)['"]''';
    // The current indexed frontend derives domain from a literal domain2.
    // Recognize that declaration without evaluating downloaded JavaScript.
    const derivedDomainPattern = r'''(?:var|let|const)\s+domain\s*=\s*[^;\n]*['"]ltn\.['"]\s*\+\s*domain2\b''';
    const domain2Pattern = r'''(?:var|let|const)\s+domain2\s*=\s*['"]([a-z0-9-]+(?:\.[a-z0-9-]+)+)['"]''';
    const endpointPattern = r'''(?:(?:https?:)?//)([a-z0-9-]+(?:\.[a-z0-9-]+)+)/(?:gg\.js(?:[?"'\s>]|$)|galleries/[0-9]+\.js(?:[?"'\s>]|$))''';
    const scriptPattern = r'''(?:(?:https?:)?//)(ltn\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)/common\.js(?:[?"'\s>]|$)''';
    final String dataHost, cdn;
    final derivedDomain = RegExp(derivedDomainPattern, caseSensitive: false).hasMatch(text) ? capture(domain2Pattern) : null;
    final domain = capture(domainPattern) ?? derivedDomain;
    if (domain != null) {
      cdn = domain.startsWith('ltn.') ? domain.substring(4) : domain;
      dataHost = 'ltn.$cdn';
    } else {
      final host = capture(endpointPattern) ?? capture(scriptPattern);
      if (host == null) return null;
      dataHost = host;
      cdn = host.startsWith('ltn.') ? host.substring(4) : host;
    }
    final valid = [dataHost, cdn].every((host) => host.split('.').every((label) => label.isNotEmpty && !label.startsWith('-') && !label.endsWith('-')));
    return valid ? (dataHost: dataHost, cdn: cdn) : null;
  }

  static bool extractDocumentBackend(String text, {required String site}) {
    final host = ContentURL.parse(site)?.host;
    if (home != site || host == null || host.isEmpty || !isDocumentPage(text)) return false;
    if (preferences.string('manga.resolved_backend_site') != site) preferences.remove('manga.resolved_media_hosts');
    preferences.set('manga.resolved_data_host', host);
    preferences.set('manga.resolved_cdn_host', host);
    preferences.set('manga.resolved_protocol', MangaBackend.document.name);
    preferences.set('manga.resolved_backend_site', site);
    preferences.remove('manga.resolved_preview_base');
    final match = RegExp(r'thumbServer\s*:\s*(\{[^{}]+\})').firstMatch(text);
    if (match != null) {
      try {
        final item = jsonDecode(match.group(1)!);
        final value = item is Map ? item['url'] : null;
        final url = value is String ? ContentURL.parse(value) : null;
        if (url != null && DocumentCatalogSource.safeMediaURL(url)) {
          preferences.set('manga.resolved_preview_base', url.toString());
          registerMedia([url], site: site);
        }
      } on FormatException {
        // A preview server that cannot be read leaves previews to each work's page.
      }
    }
    return true;
  }

  static bool isDocumentPage(String text) {
    if (RegExp(r'/js/index\.search\.').hasMatch(text)) return true;
    if (text.contains('/ajax/search') && text.contains('serverConfig') && text.contains('thumbServer')) return true;
    // A members-only host of the same catalog greets visitors with its sign-in page, which
    // carries the same configuration and posts to the same kind of endpoint.
    if (text.contains('serverConfig') && text.contains('thumbServer') && RegExp(r'action="/ajax/[a-z-]+"').hasMatch(text)) return true;
    try {
      final gallery = DocumentCatalogSource.embeddedObject(utf8.encode(text), 'gallery');
      final id = gallery['id'];
      return id is num && id.toInt() > 0 && gallery['files'] is List && (gallery['files'] as List).every((file) => file is Map);
    } on Object {
      return false;
    }
  }

  /// A listing whose works link as number plus key, with its own search form.
  static bool isKeyedPage(String text) {
    if (!text.contains('f_search') && !text.contains('searchnav')) return false;
    return KeyedCatalogSource.links(text).isNotEmpty;
  }

  static bool extractKeyedBackend(String text, {required String site}) {
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (home != site || host == null || host.isEmpty || !isKeyedPage(text)) return false;
    if (preferences.string('manga.resolved_backend_site') != site) {
      for (final key in ['manga.resolved_media_hosts', 'manga.resolved_preview_base', 'manga.resolved_api', 'manga.resolved_login']) {
        preferences.remove(key);
      }
    }
    preferences.set('manga.resolved_data_host', host);
    preferences.set('manga.resolved_cdn_host', host);
    preferences.set('manga.resolved_protocol', MangaBackend.keyed.name);
    preferences.set('manga.resolved_backend_site', site);
    preferences.remove('manga.account_required');
    return true;
  }

  /// A work page names the data endpoint and the sign-in page; keep them when they stay on the site.
  static void extractKeyedEndpoints(String text, {required String site}) {
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (home != site || host == null || host.isEmpty) return;
    Uri? value(String name) {
      final match = RegExp('\\b$name\\s*=\\s*"([^"]+)"').firstMatch(text);
      if (match == null) return null;
      final url = ContentURL.parse(match.group(1)!);
      if (url == null || url.scheme != 'https' || !ContentURL.hasNoCredentials(url) || !ContentURL.usesDefaultPort(url)) return null;
      final target = url.host.toLowerCase();
      if (target.isEmpty || !(target == host || target.endsWith('.${SiteAccount.registrableDomain(host)}'))) return null;
      return url;
    }

    final api = value('api_url');
    if (api != null) preferences.set('manga.resolved_api', api.toString());
    final login = value('login_url');
    if (login != null) preferences.set('manga.resolved_login', login.toString());
  }

  static Uri? get keyedAPI {
    if (!hasResolvedBackend || backend != MangaBackend.keyed) return null;
    final saved = preferences.string('manga.resolved_api');
    if (saved != null) {
      final url = ContentURL.parse(saved);
      if (url != null) return url;
    }
    return ContentURL.parse('${home}api.php');
  }

  /// Where the person signs in: what the site itself named, else the account host it sent visitors
  /// to. A members-only site that names neither shares the account of another connected site.
  static Uri? get signInURL {
    final own = _ownSignInURL;
    if (own != null) return own;
    if (SiteScope.other != null) return null;
    for (final site in ComicSites.siblings(ComicSites.active)) {
      final siteHome = homeForSite(site);
      final url = SiteScope.run(site, () => MangaUrls.home == siteHome ? _ownSignInURL : null);
      if (url != null) return url;
    }
    return null;
  }

  static Uri? get _ownSignInURL {
    if (home.isEmpty) return null;
    final page = accountSignInPage;
    if (page != null) return page;
    // A catalog of this kind keeps accounts even where works open without one.
    if (backend == MangaBackend.document && hasResolvedBackend) return ContentURL.parse('${home}account/login');
    if (backend == MangaBackend.keyed && hasResolvedBackend) {
      final saved = preferences.string('manga.resolved_login');
      final url = saved == null ? null : ContentURL.parse(saved);
      if (url != null) return url;
    }
    final host = accountHost;
    if (host != null) return Uri.parse('https://$host/index.php?act=Login&CODE=00');
    return backend == MangaBackend.keyed && hasResolvedBackend ? ContentURL.parse('${home}favorites.php') : null;
  }

  /// The host a members-only site sends signed-out visitors to.
  static String? get accountHost {
    if (preferences.string('manga.account_site') != home) return null;
    return preferences.string('manga.account_host');
  }

  /// The site showed nothing to this visitor and asks for an account first.
  static bool get requiresSignIn =>
      !hasResolvedBackend && preferences.string('manga.account_site') == home && (preferences.boolean('manga.account_required') ?? false);

  static bool get usesAccount => (hasResolvedBackend && backend == MangaBackend.keyed) || preferences.string('manga.account_site') == home;

  /// The person signed in for this site, so it gets the account's cookies before its protocol is known.
  static void markUsesAccount({required String site, Uri? signInPage}) {
    if (home != site) return;
    if (signInPage != null) preferences.set('manga.account_login', signInPage.toString());
    if (hasResolvedBackend && backend == MangaBackend.keyed) return;
    preferences.set('manga.account_site', site);
  }

  /// What belongs to one site's account rather than to its protocol: kept with the site, and
  /// not forgotten when the protocol is looked up again.
  static const accountKeys = ['manga.account_site', 'manga.account_host', 'manga.account_login'];

  /// The site's own sign-in page, found where it sent a signed-out visitor.
  static Uri? get accountSignInPage {
    if (preferences.string('manga.account_site') != home) return null;
    final value = preferences.string('manga.account_login');
    final url = value == null ? null : ContentURL.parse(value);
    if (url == null || url.scheme != 'https' || url.host.toLowerCase() != configuredHost) return null;
    return url;
  }

  /// A catalog whose works open with the signed-in session of its own pages, not with forum cookies.
  static bool get usesSiteSession => hasResolvedBackend && backend == MangaBackend.document;

  static void markRequiresSignIn({required String site, String? accountHost}) {
    if (home != site) return;
    preferences.set('manga.account_site', site);
    if (accountHost != null) preferences.set('manga.account_host', accountHost);
    preferences.set('manga.account_required', true);
  }

  static bool isIndexedPage(String text) {
    if (indexedBackendHosts(text) == null) return false;
    return text.contains('.nozomi') || RegExp(r'''/(?:common\.js|gg\.js|galleries/[0-9]+\.js)(?:[?"'\s>]|$)''').hasMatch(text);
  }

  static void registerMedia(List<Uri> urls, {required String site}) {
    if (site != home) return;
    final keyed = backend == MangaBackend.keyed;
    final hosts = {...?_stringList('manga.resolved_media_hosts')};
    // Keyed catalogs spread images across many volunteer hosts under one domain.
    final incoming = urls
        .where((url) => keyed ? KeyedCatalogSource.safeMediaURL(url) : DocumentCatalogSource.safeMediaURL(url))
        .map((url) => url.host.toLowerCase())
        .map((host) => keyed ? SiteAccount.registrableDomain(host) : host)
        .toList();
    if (hosts.containsAll(incoming)) return;
    hosts.addAll(incoming);
    preferences.set('manga.resolved_media_hosts', hosts.take(64).toList());
  }

  static List<String>? _stringList(String key) {
    final value = preferences.object(key);
    return value is List ? value.whereType<String>().toList() : null;
  }

  static bool allowsMedia(String host) {
    if (!hasResolvedBackend || backend == MangaBackend.indexed) return false;
    final hosts = _stringList('manga.resolved_media_hosts') ?? [];
    if (backend == MangaBackend.keyed) return hosts.any((entry) => host == entry || host.endsWith('.$entry'));
    return hosts.contains(host);
  }

  /// Keep discovery anchored to the user's address, including its own common.js.
  static Future<void> resolveBackend({ContentTransport? transport, bool force = false}) =>
      _MangaBackendResolver.shared.resolve(transport ?? ContentTransport.shared, force: force);

  static Future<bool> discoverBackend(String site, ContentTransport transport, {bool retried = false}) async {
    final homepage = ContentURL.parse(site);
    if (homepage == null || site.isEmpty) return false;
    final host = homepage.host.toLowerCase();
    final access = SiteAccount.siteCookie(SiteAccount.accessCookie, host: host);
    final scripts = <Uri>[];
    try {
      final List<int> data;
      final ContentResponse response;
      try {
        final result = await transport.get(homepage, limit: 1000000, timeout: const Duration(seconds: 8));
        data = result.data;
        response = result.response;
      } catch (error) {
        // A site that hands signed-out visitors to another host with a one-time
        // token is asking for an account; a plain move to a new address is not.
        final target = transport.foreignRedirect(homepage);
        if (target != null && target.host.isNotEmpty && target.query.isNotEmpty) {
          markRequiresSignIn(site: site, accountHost: target.host.toLowerCase());
          return false;
        }
        rethrow;
      }
      if (home != site) return false;
      final body = utf8.decode(data, allowMalformed: true);
      if (extractBackend(body, site: site)) return true;
      if (extractDocumentBackend(body, site: site)) {
        // Its works open only for a signed-in visitor; lists stay open to everyone.
        if (KeyedCatalogSource.asksForSignIn(body) && response.url.host.toLowerCase() == homepage.host.toLowerCase()) {
          markUsesAccount(site: site, signInPage: response.url);
        }
        return true;
      }
      if (extractKeyedBackend(body, site: site)) {
        final link = KeyedCatalogSource.links(body).firstOrNull;
        final page = link == null ? null : ContentURL.parse('${site}g/${link.id}/${link.key}/');
        if (page != null) {
          try {
            final detail = await transport.get(page, limit: 2000000, timeout: const Duration(seconds: 8));
            extractKeyedEndpoints(utf8.decode(detail.data, allowMalformed: true), site: site);
          } on Object {
            // The endpoints fall back to the site's usual names.
          }
        }
        return true;
      }
      // A members-only catalog shows signed-out visitors nothing, or only a picture; a short
      // reply of another kind, such as an interface's error, is not that.
      final mime = response.mimeType?.toLowerCase(), shown = body.trim();
      final showsNothing = (mime?.startsWith('image/') ?? false) || shown.isEmpty || (shown.length < 64 && (mime?.startsWith('text/html') ?? false));
      if (showsNothing) {
        final askedBefore = preferences.string('manga.account_site') == site;
        markRequiresSignIn(site: site);
        // The site's account is tried here once, now that the site asks for one; so is access
        // a members-only catalog handed out with this very answer.
        final handedOut = SiteAccount.siteCookie(SiteAccount.accessCookie, host: host);
        final newAccess = handedOut != null && handedOut != access;
        if (!retried && SiteAccount.isSignedIn && home == site && (!askedBefore || newAccess)) {
          return await discoverBackend(site, transport, retried: true);
        }
        return false;
      }
      final pattern = RegExp(r'''<script\b[^>]*\bsrc\s*=\s*['"]([^'"]+)['"]''', caseSensitive: false);
      for (final match in pattern.allMatches(body)) {
        Uri url;
        try {
          url = homepage.resolve(match.group(1)!);
        } on FormatException {
          continue;
        }
        if (url.host.toLowerCase() != homepage.host.toLowerCase() || url.pathSegments.lastOrNull != 'common.js' || scripts.contains(url)) continue;
        scripts.add(url);
        if (scripts.length == 3) break;
      }
    } catch (error) {
      if (error is CancellationError) return false;
    }
    final common = homepage.resolve('common.js');
    if (!scripts.contains(common)) scripts.add(common);
    for (final url in scripts) {
      if (home != site) return false;
      try {
        final response = await transport.get(url, limit: 1000000, timeout: const Duration(seconds: 8));
        if (extractBackend(utf8.decode(response.data, allowMalformed: true), site: site)) return true;
      } on Object {
        continue;
      }
    }
    return false;
  }

  static int _resets = 0;

  /// Changes whenever the resolved protocol is forgotten, so a failed lookup's cooldown does not outlive it.
  static int get resetGeneration => _resets;

  static const resolvedKeys = [
    'manga.resolved_data_host',
    'manga.resolved_cdn_host',
    'manga.resolved_backend_site',
    'manga.resolved_protocol',
    'manga.resolved_media_hosts',
    'manga.resolved_preview_base',
    'manga.resolved_api',
    'manga.resolved_login',
    'manga.account_required',
    'manga.resolved_features',
  ];

  static Set<KeyedFeature> get keyedFeatures {
    if (!hasResolvedBackend || backend != MangaBackend.keyed) return {};
    return {for (final name in _stringList('manga.resolved_features') ?? const <String>[]) ?KeyedFeature.fromName(name)};
  }

  /// Notes what a keyed catalog's navigation offers, from any of its listing pages.
  static void noteKeyedNavigation(String text, {required String site}) {
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (home != site || !hasResolvedBackend || backend != MangaBackend.keyed || host == null || host.isEmpty) return;
    final escaped = RegExp.escape(host);
    final found = <KeyedFeature>{
      if (RegExp('href="(?:https://$escaped)?/toplist\\.php').hasMatch(text)) KeyedFeature.toplist,
      if (RegExp('href="(?:https://$escaped)?/watched"').hasMatch(text)) KeyedFeature.watched,
    };
    final current = keyedFeatures;
    if (found.isEmpty || current.containsAll(found)) return;
    preferences.set('manga.resolved_features', ({...found, ...current}.map((feature) => feature.name).toList()..sort()));
  }

  static void resetResolvedBackend() {
    _resets += 1;
    for (final key in resolvedKeys) {
      preferences.remove(key);
    }
  }

  /// The home address of a connected site, from the host the settings keep.
  static String homeForSite(String site) => site.isEmpty ? '' : 'https://$site/';
}

/// `ComicSites`: the comics websites a person connected. One is active at a time; each keeps
/// what was learned about it, so switching back never repeats the check. Sites that number their
/// works the same way can open each other's saved works.
abstract final class ComicSites {
  static Preferences get _preferences => ContentPreferences.defaults;
  static const _listKey = 'manga.sites';

  /// Kept as JSON text, since stored preferences hold only plain values.
  static const _snapshotsKey = 'manga.siteSnapshots';

  /// Account details that belong to one site, kept with what was learned about it.
  static const _snapshotKeys = [...MangaUrls.resolvedKeys, ...MangaUrls.accountKeys];

  static String get active => _preferences.string('manga.site_address') ?? '';

  /// Connected sites by host, the active one included.
  static List<String> get all {
    final stored = _preferences.object(_listKey);
    final sites = stored is List ? stored.whereType<String>().toList() : <String>[];
    final current = active;
    if (current.isNotEmpty && !sites.contains(current)) sites.add(current);
    return sites;
  }

  static void add(String site) {
    if (site.isEmpty) return;
    final sites = all;
    if (!sites.contains(site)) sites.add(site);
    _preferences.set(_listKey, sites);
  }

  /// Puts the connected sites in a new order of priority. Sites the order leaves out keep their place at the end.
  static void reorder(List<String> order) {
    final current = all;
    _preferences.set(_listKey, [...order.where(current.contains), ...current.where((site) => !order.contains(site))]);
  }

  /// Forgets a site and what was learned about it.
  static void remove(String site) {
    _preferences.set(_listKey, all.where((value) => value != site).toList());
    final snapshots = _snapshots()..remove(site);
    _save(snapshots);
  }

  static Map<String, Map<String, Object?>> _snapshots() {
    final text = _preferences.string(_snapshotsKey);
    if (text == null) return {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is Map) key: {for (final entry in value.entries) '${entry.key}': entry.value},
      };
    } on FormatException {
      return {};
    }
  }

  static void _save(Map<String, Map<String, Object?>> snapshots) => _preferences.set(_snapshotsKey, jsonEncode(snapshots));

  /// Keeps what was learned about [from] and brings back what was learned about [to].
  static void switchSite({required String from, required String to}) {
    if (from == to) {
      MangaUrls.resetResolvedBackend();
      return;
    }
    final snapshots = _snapshots();
    if (from.isNotEmpty) {
      final home = MangaUrls.homeForSite(from);
      final owns = _preferences.string('manga.resolved_backend_site') == home || _preferences.string('manga.account_site') == home;
      if (owns) {
        snapshots[from] = {for (final key in _snapshotKeys) key: ?_preferences.object(key)};
      }
    }
    MangaUrls.resetResolvedBackend();
    for (final key in MangaUrls.accountKeys) {
      _preferences.remove(key);
    }
    for (final MapEntry(:key, :value) in (snapshots[to] ?? const {}).entries) {
      if (!_snapshotKeys.contains(key)) continue;
      // JSON brings lists back untyped; stored preferences want a list of text.
      _preferences.set(key, value is List ? value.whereType<String>().toList() : value);
    }
    _save(snapshots);
  }

  /// How a site's works are reached, once learned.
  static MangaBackend? backendOf(String site) {
    if (site == active) return SiteScope.run(null, () => MangaUrls.hasResolvedBackend ? MangaUrls.backend : null);
    final saved = _snapshots()[site];
    if (saved == null || saved['manga.resolved_backend_site'] != MangaUrls.homeForSite(site)) return null;
    return MangaBackend.fromRawValue(saved['manga.resolved_protocol'] as String?);
  }

  /// Other connected sites. Every supported site numbers its works the same way, so a number
  /// names the same work on each; they differ only in which works they carry.
  static List<String> siblings(String site) => all.where((other) => other != site).toList();
}

/// Coalesce discovery for concurrent covers and lists. Failed discovery has a
/// short cooldown; successful discovery lives in preferences without a timer.
class _MangaBackendResolver {
  static final shared = _MangaBackendResolver();
  final _flights = <String, Future<bool>>{};
  final _failedAt = <String, (DateTime, int)>{};

  Future<void> resolve(ContentTransport transport, {required bool force}) async {
    final site = MangaUrls.home;
    if (site.isEmpty) return;
    final flight = _flights[site];
    if (flight != null) {
      await flight;
      return;
    }
    if (!force && MangaUrls.hasResolvedBackend) return;
    final failure = _failedAt[site];
    if (!force && failure != null && failure.$2 == MangaUrls.resetGeneration && DateTime.now().difference(failure.$1) < const Duration(seconds: 10)) return;
    final task = MangaUrls.discoverBackend(site, transport);
    _flights[site] = task;
    final succeeded = await task;
    _flights.remove(site);
    if (succeeded) {
      _failedAt.remove(site);
    } else {
      _failedAt[site] = (DateTime.now(), MangaUrls.resetGeneration);
    }
  }

  /// Tests start each case without a cooldown left by the previous one.
  void reset() {
    _flights.clear();
    _failedAt.clear();
  }
}

/// For tests: forget discovery flights and cooldowns.
void resetMangaBackendResolver() => _MangaBackendResolver.shared.reset();
