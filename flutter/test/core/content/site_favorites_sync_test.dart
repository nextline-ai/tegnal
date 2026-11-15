// Ported from native-ios/TEGNALTests/CombinedCatalogTests.swift (favorites sync and website priority).
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/combined_catalog.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/content/site_favorites_sync.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';

import 'content_test_support.dart';

/// A website's favorites, kept in memory.
class _Favorites extends SiteContent {
  _Favorites(super.site, this.ids);
  final Set<int> ids;
  int writes = 0;
  bool refuses = false;

  @override
  Future<(List<int>, String?)> accountFavorites({String? after, int? category}) async {
    if (refuses) throw ContentError.signInRequired;
    final sorted = ids.toList()..sort();
    // Two pages, so every page is read.
    return after == null ? (sorted.take(2).toList(), sorted.length > 2 ? 'next' : null) : (sorted.skip(2).toList(), null);
  }

  @override
  Future<void> setAccountFavorite(int id, {required bool saved, int category = 0}) async {
    writes += 1;
    saved ? ids.add(id) : ids.remove(id);
  }

  @override
  NativeGallery? cachedPreview(int id) => null;
}

void main() {
  late AppDatabase database;
  late _Favorites site;
  late SiteFavoritesSync sync;
  const host = 'keyed.example';

  setUp(() {
    final preferences = resetContent(site: host);
    database = AppDatabase.inMemory(preferences: AppPreferences.memory());
    site = _Favorites(host, {1, 2, 3});
    sync = SiteFavoritesSync(
      database: database,
      content: ContentEnvironment(browserPreferences: preferences),
      linksOverride: SiteFavoriteFolders(MemoryPreferences()),
      siteContent: (_) => site,
    );
    expect(SiteAccount.signIn(const [SiteCookie(name: 'ipb_member_id', value: '7'), SiteCookie(name: 'ipb_pass_hash', value: 'x')], host: host), isTrue);
  });

  List<int> folder() => database.galleryIDsInFolder(sync.folderID(host)!)..sort();

  test('favorites sync follows the side that changed', () {
    final first = FavoriteSyncPlan.make(local: {1}, remote: {1, 2, 3}, base: null);
    expect(first.addLocally, [2, 3], reason: "The first sync brings the website's favorites into the folder");
    expect([...first.removeLocally, ...first.removeFromSite], isEmpty, reason: 'The first sync never removes');
    final plan = FavoriteSyncPlan.make(local: {1, 2, 4}, remote: {1, 3, 5}, base: {1, 2, 3});
    expect(plan.addLocally, [5]);
    expect(plan.removeLocally, [2]);
    expect(plan.addOnSite, [4]);
    expect(plan.removeFromSite, [3]);
    expect(plan.settled, {1, 4, 5});
    final push = FavoriteSyncPlan.make(local: {1, 4}, remote: {1, 2}, base: {1, 2});
    expect(push.addOnSite, [4]);
    expect(push.removeFromSite, [2]);
    expect(push.addLocally.isEmpty && push.removeLocally.isEmpty, isTrue, reason: 'Sending changes alone never changes the folder');
  });

  test('a first sign-in fills a folder named after the website, and both sides stay the same', () async {
    await sync.setUp(host);
    expect(database.listFolders().where((folder) => folder.name == host), hasLength(1));
    expect(folder(), [1, 2, 3], reason: 'Every page of favorites is brought in');

    // Changes in the app reach the website.
    database.addWork(1, database.listFolders().first.id!);
    database.upsertWork(galleryId: 4, folderId: sync.folderID(host));
    database.removeWorkFromFolder(2, sync.folderID(host)!);
    await sync.sync(host, pull: false);
    expect(site.ids, {1, 3, 4});

    // Changes on the website reach the folder.
    site.ids
      ..remove(3)
      ..add(5);
    await sync.sync(host);
    expect(folder(), [1, 4, 5]);
    expect(database.getWork(3), isNull, reason: 'A work only the folder held leaves the library, as removing its bookmark would');
    expect(database.getWork(1), isNotNull);

    // Nothing changed: nothing is sent.
    final writes = site.writes;
    await sync.sync(host);
    expect(site.writes, writes);
  });

  test('a website that keeps the account out gets no folder, and a deleted folder stops the sync', () async {
    site.refuses = true;
    await sync.setUp(host);
    expect(sync.links.folder(host), isNull);
    expect(database.listFolders().where((folder) => folder.name == host), isEmpty);

    site.refuses = false;
    await sync.setUp(host);
    database.deleteFolder(sync.folderID(host)!);
    await sync.sync(host);
    expect(sync.links.folder(host), isNull);
    expect(site.ids, {1, 2, 3}, reason: "Deleting the folder leaves the website's favorites alone");
    expect(sync.links.isDeclined(host), isTrue);
    await sync.setUp(host);
    expect(sync.links.folder(host), isNull, reason: 'Turned off, it is not set up again on its own');
    await sync.setUp(host, requested: true);
    expect(sync.links.folder(host), isNotNull);
  });

  test('website priority reorders the connected websites', () {
    ContentPreferences.defaults.set('manga.sites', ['a.example.org', 'b.example.org', 'c.example.org']);
    ComicSites.reorder(['c.example.org', 'a.example.org']);
    expect(ComicSites.all.take(3), ['c.example.org', 'a.example.org', 'b.example.org']);
  });
}
