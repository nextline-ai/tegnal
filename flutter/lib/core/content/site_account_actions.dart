import 'dart:async';

import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import 'site_favorites_sync.dart';
import 'content_environment.dart';
import 'gallery_content.dart';
import 'keyed_work_extras.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// One page of the signed-in account's favorites and the cursor of the next one.
typedef AccountFavoritesPage = Future<(List<int>, String?)> Function({String? after, int? category});

/// What `AppEnvironment` does around website accounts.
abstract final class SiteAccountActions {
  /// Cookies Android's `CookieManager.getCookie(url)` reports, as `name=value; name=value`.
  static List<SiteCookie> parseCookieHeader(String? header) {
    if (header == null) return [];
    final result = <SiteCookie>[];
    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final name = part.substring(0, index).trim(), value = part.substring(index + 1).trim();
      if (name.isNotEmpty) result.add(SiteCookie(name: name, value: value));
    }
    return result;
  }

  /// The sign-in page loads only https pages, and `about:blank`; the frames a bot check draws
  /// itself may also use `about:srcdoc`, `blob:` and `data:`.
  static bool allowsSignInNavigation(Uri url, {bool mainFrame = true}) {
    if (url.scheme == 'https') return url.userInfo.isEmpty;
    if (mainFrame) return url.toString() == 'about:blank';
    return ['about:blank', 'about:srcdoc'].contains(url.toString()) || ['blob', 'data'].contains(url.scheme);
  }

  /// What was learned about [site] (a connected website; null is the checked one), read in its own scope.
  static T scoped<T>(String? site, T Function() body) => SiteScope.run(site ?? ComicSites.active, body);

  /// Keeps a sign-in made on a site's own pages. Returns false while it left no cookies.
  static bool finishSessionSignIn(List<SiteCookie> cookies, ContentEnvironment content, {String? site}) {
    if (!SiteAccount.signInSession(cookies, host: scoped(site, () => MangaUrls.configuredHost))) return false;
    // Requests carry the account from now on, where works also open without one.
    scoped(site, () => MangaUrls.markUsesAccount(site: MangaUrls.home, signInPage: MangaUrls.signInURL));
    signInChanged(content, site: site);
    return true;
  }

  /// Signs a connected website in with cookies copied from a browser.
  static bool signInPasted(PastedCookies pasted, ContentEnvironment content, {String? site}) {
    if (!SiteAccount.signInPasted(pasted, host: scoped(site, () => MangaUrls.configuredHost))) return false;
    scoped(site, () => MangaUrls.markUsesAccount(site: MangaUrls.home));
    signInChanged(content, site: site);
    return true;
  }

  /// Signs a connected website in with the account another website keeps.
  static bool useAccount(String source, ContentEnvironment content, {String? site}) {
    if (!SiteAccount.useAccount(from: source, on: scoped(site, () => MangaUrls.configuredHost))) return false;
    scoped(site, () => MangaUrls.markUsesAccount(site: MangaUrls.home));
    signInChanged(content, site: site);
    return true;
  }

  /// Whether a connected website now shows its signed-in account: its favorites open.
  static Future<bool> checkSiteAccount(AccountFavoritesPage favorites, {String? site}) => scoped(site, () async {
    await MangaUrls.resolveBackend(force: true);
    if (!MangaUrls.hasResolvedBackend || MangaUrls.backend != MangaBackend.keyed) return false;
    try {
      await favorites();
      return true;
    } on Object {
      return false;
    }
  });

  /// Keeps the identity from a finished sign-in page. Returns false while the cookies hold
  /// none, so the page stays open until the person has signed in (`siteSignInFinished`).
  static bool finishSignIn(List<SiteCookie> cookies, ContentEnvironment content, {String? site}) {
    if (!SiteAccount.signIn(cookies, host: scoped(site, () => MangaUrls.configuredHost))) return false;
    scoped(site, () => MangaUrls.markUsesAccount(site: MangaUrls.home));
    signInChanged(content, site: site);
    return true;
  }

  /// A finished sign-in changes what the site shows, so its protocol is read again.
  static void signInChanged(ContentEnvironment content, {String? site}) {
    scoped(site, MangaUrls.resetResolvedBackend);
    content.refreshSiteAccount();
    // A first sign-in brings the website's favorites into a folder named after it.
    unawaited(SiteFavoritesSync.shared?.setUp(site ?? ComicSites.active));
  }

  /// Signs one connected website out; the other websites keep their accounts.
  static void signOut(ContentEnvironment content, {String? site}) {
    final host = scoped(site, () => MangaUrls.configuredHost);
    SiteAccount.signOutAt(host);
    // The folders stay as plain folders; signing in again sets them up afresh.
    SiteFavoritesSync.shared?.forget(site ?? ComicSites.active);
    signInChanged(content, site: site);
  }

  /// Bookmarks every account favorite not already saved, into the default folder, or each
  /// favorites category into a folder of the same name. With categories, works already saved
  /// join their category's folder too, so the library holds the account's arrangement.
  /// Returns how many works were added.
  static Future<int> importAccountFavorites({
    required AppDatabase database,
    required AccountFavoritesPage favorites,
    NativeGallery? Function(int id)? preview,
    void Function()? startCoverQueue,
    Future<List<FavoriteCategory>> Function()? categories,
  }) async {
    var added = 0;
    if (categories != null) {
      for (final category in await categories()) {
        if (category.count <= 0) continue;
        final folder = database.createFolder(name: category.name).id;
        added += await _importFavorites(database, favorites, preview, category: category.id, folder: folder, joinsExisting: true);
      }
    } else {
      added = await _importFavorites(database, favorites, preview, folder: database.defaultSaveFolder().id, joinsExisting: false);
    }
    if (added > 0) startCoverQueue?.call();
    return added;
  }

  static Future<int> _importFavorites(
    AppDatabase database,
    AccountFavoritesPage favorites,
    NativeGallery? Function(int id)? preview, {
    int? category,
    int? folder,
    required bool joinsExisting,
  }) async {
    String? next;
    var added = 0, pages = 0;
    do {
      final (ids, cursor) = await favorites(after: next, category: category);
      for (final id in ids) {
        if (database.getWork(id) != null) {
          if (joinsExisting && folder != null) database.addWork(id, folder);
          continue;
        }
        final work = preview?.call(id);
        database.upsertWork(
          galleryId: id,
          folderId: folder,
          title: work?.title,
          artists: work?.artists.join(', '),
          language: work?.language,
          type: work?.type,
          tags: work?.tags.join(', '),
          metadataSource: 'remote',
          site: ComicSites.active,
          pageCount: work?.displayedPageCount,
        );
        added += 1;
      }
      next = cursor;
      pages += 1;
    } while (next != null && pages < 500);
    return added;
  }
}
