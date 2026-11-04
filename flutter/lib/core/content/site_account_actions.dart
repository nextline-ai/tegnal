import '../storage/app_database.dart';
import '../storage/folder_rules.dart';
import 'content_environment.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// One page of the signed-in account's favorites and the cursor of the next one.
typedef AccountFavoritesPage = Future<(List<int>, String?)> Function({String? after});

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

  /// The sign-in page loads only https pages, and `about:blank`.
  static bool allowsSignInNavigation(Uri url) => url.scheme == 'https' || url.toString() == 'about:blank';

  /// Keeps the identity from a finished sign-in page. Returns false while the cookies hold
  /// none, so the page stays open until the person has signed in (`siteSignInFinished`).
  static bool finishSignIn(List<SiteCookie> cookies, ContentEnvironment content) {
    if (!SiteAccount.signIn(cookies)) return false;
    signInChanged(content);
    return true;
  }

  /// A finished sign-in changes what the site shows, so its protocol is read again.
  static void signInChanged(ContentEnvironment content) {
    content.refreshSiteAccount();
    MangaUrls.resetResolvedBackend();
  }

  static void signOut(ContentEnvironment content) {
    SiteAccount.signOut();
    content.syncsAccountFavorites = false;
    content.refreshSiteAccount();
    MangaUrls.resetResolvedBackend();
  }

  /// Bookmarks every account favorite not already saved, into the default folder.
  /// Returns how many works were added.
  static Future<int> importAccountFavorites({
    required AppDatabase database,
    required AccountFavoritesPage favorites,
    NativeGallery? Function(int id)? preview,
    void Function()? startCoverQueue,
  }) async {
    final folder = database.defaultSaveFolder().id;
    String? next;
    var added = 0, pages = 0;
    do {
      final (ids, cursor) = await favorites(after: next);
      for (final id in ids) {
        if (database.getWork(id) != null) continue;
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
        );
        added += 1;
      }
      next = cursor;
      pages += 1;
    } while (next != null && pages < 500);
    if (added > 0) startCoverQueue?.call();
    return added;
  }
}
