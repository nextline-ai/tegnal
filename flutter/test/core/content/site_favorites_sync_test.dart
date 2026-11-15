// Ported from native-ios/TEGNALTests/CombinedCatalogTests.swift (favorites sync and website priority).
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/combined_catalog.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/document_catalog_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/keyed_work_extras.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/content/site_favorites_sync.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';

import 'content_test_support.dart';

/// A website's favorites categories, kept in memory. A favorite sits in one category, as the
/// keyed website keeps them, unless [exclusive] is off, as lists an account makes are.
class _Favorites extends SiteContent {
  _Favorites(super.site, this.members, {this.exclusive = true, Map<int, String>? names})
    : names = names ?? {for (var id = 0; id < 10; id++) id: 'Favorites $id'};
  final Map<int, Set<int>> members;
  final Map<int, String> names;
  final bool exclusive;
  int writes = 0;
  bool refuses = false;

  @override
  Future<AccountFavorites> accountFavoriteLists() async {
    if (refuses) throw ContentError.signInRequired;
    return AccountFavorites(
      categories: [
        for (final MapEntry(:key, :value) in names.entries)
          FavoriteCategory(id: key, name: value, count: members.values.where((categories) => categories.contains(key)).length),
      ],
      members: {
        for (final MapEntry(:key, :value) in members.entries) key: {...value},
      },
      exclusive: exclusive,
    );
  }

  @override
  Future<void> changeAccountFavorite(int id, {required int category, required bool adds}) async {
    writes += 1;
    if (exclusive) {
      adds ? members[id] = {category} : members.remove(id);
    } else if (adds) {
      (members[id] ??= {}).add(category);
    } else {
      members[id]?.remove(category);
      if (members[id]?.isEmpty ?? false) members.remove(id);
    }
  }

  @override
  NativeGallery? cachedPreview(int id) => null;
}

const _unassigned = FavoritePlace.unassigned;
FavoritePlace _category(int id) => FavoritePlace.category(id);

void main() {
  late AppDatabase database;
  late _Favorites site;
  late SiteFavoritesSync sync;
  const host = 'keyed.example';

  setUp(() {
    final preferences = resetContent(site: host);
    database = AppDatabase.inMemory(preferences: AppPreferences.memory());
    site = _Favorites(host, {
      1: {0},
      2: {0},
      3: {1},
    });
    sync = SiteFavoritesSync(
      database: database,
      content: ContentEnvironment(browserPreferences: preferences),
      storeOverride: SiteFavoriteFolders(MemoryPreferences()),
      siteContent: (_) => site,
    );
    expect(SiteAccount.signIn(const [SiteCookie(name: 'ipb_member_id', value: '7'), SiteCookie(name: 'ipb_pass_hash', value: 'x')], host: host), isTrue);
  });

  int folderNamed(String name) => database.listFolders().firstWhere((folder) => folder.name == name).id!;
  List<int> worksIn(String name) => database.galleryIDsInFolder(folderNamed(name))..sort();

  test('favorites sync follows the side that changed a category', () {
    final first = FavoriteSyncPlan.make(
      local: {
        1: {_category(0)},
        9: {_unassigned},
      },
      remote: {
        1: {0},
        2: {1},
        3: {4},
      },
      base: null,
      folders: {0, 1},
      unassigned: 5,
      localOnly: {},
    );
    expect(first.local, {
      2: {_category(1)},
      3: {_unassigned},
    }, reason: 'The first sync brings each category into its folder, and one without a folder into Unfiled');
    expect(first.keepLocal, [9], reason: 'The library saved before the sync is not sent all at once');
    expect(first.site, isEmpty);

    final plan = FavoriteSyncPlan.make(
      local: {
        1: {_category(1)},
        2: {_category(1)},
        3: {_category(0)},
        6: {_unassigned},
      },
      remote: {
        1: {0},
        2: {0},
        3: {0},
        5: {1},
      },
      base: {
        1: {0},
        2: {1},
        3: {0},
        4: {1},
      },
      folders: {0, 1},
      unassigned: 5,
      localOnly: {},
    );
    expect(plan.local, {
      2: {_category(0)},
      5: {_category(1)},
    }, reason: 'Moved and added on the website');
    expect(plan.site, [const FavoriteSiteChange(1, 1, adds: true), const FavoriteSiteChange(6, 5, adds: true)]);

    final both = FavoriteSyncPlan.make(
      local: {
        1: {_category(1)},
      },
      remote: {
        1: {2},
      },
      base: {
        1: {0},
      },
      folders: {0, 1, 2},
      unassigned: null,
      localOnly: {},
    );
    expect(both.local[1], {_category(1), _category(2)}, reason: 'Moved on both sides: the folder follows the website too');
    expect(both.site, isEmpty, reason: 'and the website keeps its own');

    final out = FavoriteSyncPlan.make(
      local: {
        1: {_unassigned},
      },
      remote: {
        1: {0},
      },
      base: {
        1: {0},
      },
      folders: {0},
      unassigned: null,
      localOnly: {},
    );
    expect(out.site, [const FavoriteSiteChange(1, 0, adds: false)], reason: 'Taken out of the category folder with nowhere else to go');
    expect(out.local, isEmpty, reason: 'It stays in the app');
    final later = FavoriteSyncPlan.make(
      local: {
        1: {_unassigned},
      },
      remote: {},
      base: {},
      folders: {0},
      unassigned: null,
      localOnly: {},
    );
    expect(later.isEmpty, isTrue, reason: 'Without a spare category, works in other folders are never sent');
  });

  test('lists keep a work in several folders and leave lists without folders alone', () {
    final plan = FavoriteSyncPlan.make(
      local: {
        1: {_category(10), _category(11)},
        2: {_category(10)},
        3: {_unassigned},
      },
      remote: {
        1: {10},
        2: {10, 11, 30},
        3: {30},
      },
      base: {
        1: {10},
        2: {10, 11, 30},
        3: {30},
      },
      folders: {10, 11},
      unassigned: 20,
      localOnly: {},
      exclusive: false,
    );
    expect(plan.site, [const FavoriteSiteChange(1, 11, adds: true), const FavoriteSiteChange(2, 11, adds: false)]);
    expect(plan.local, isEmpty);
    expect(plan.settled[2], {10, 30});
  });

  test('works from other folders get only a category the account left empty', () {
    AccountFavorites favorites(List<int> counts) => AccountFavorites(
      categories: [for (var id = 0; id < counts.length; id++) FavoriteCategory(id: id, name: 'Favorites $id', count: counts[id])],
      members: const {},
      exclusive: true,
    );
    expect(favorites([3, 0, 2, 0]).spareCategory(besides: {0, 2}), 1);
    expect(favorites([3, 4, 2, 1]).spareCategory(besides: {0, 1, 2}), isNull, reason: "A category holding favorites without a folder is the account's own");
    expect(favorites(List.filled(10, 1)).spareCategory(besides: {for (var id = 0; id < 10; id++) id}), isNull);
  });

  test('favorite lists are read from the favorites page', () {
    final lists = DocumentCatalogSource.favoriteListsIn(
      '<script>const favorites = [{"id":12,"name":"Later [a]","private":1,"galleries":[{"id":101,"time":1},{"id":102,"time":2}]},{"id":3,"name":"","private":0,"galleries":[{"id":101,"time":3}]}]; const favoriteThumbnails = [];</script>'
          .codeUnits,
    );
    expect(lists.categories, const [FavoriteCategory(id: 3, name: 'fav:3', count: 1), FavoriteCategory(id: 12, name: 'Later [a]', count: 2)]);
    expect(lists.members, {
      101: {3, 12},
      102: {12},
    });
    expect(lists.exclusive, isFalse);
  });

  test('a first sign-in makes a folder for each category with favorites, and both sides stay the same', () async {
    final unfiled = database.unfiledFolderID();
    database.upsertWork(galleryId: 9, folderId: unfiled);
    await sync.setUp(host);
    expect(worksIn('Favorites 0'), [1, 2]);
    expect(worksIn('Favorites 1'), [3]);
    expect(database.listFolders().where((folder) => folder.name == 'Favorites 2'), isEmpty, reason: 'An empty category gets no folder');
    expect(site.members.containsKey(9), isFalse, reason: 'The library saved before the sync is not sent all at once');

    // Changes in the app reach the website.
    database.addWork(1, folderNamed('Favorites 1'));
    database.removeWorkFromFolder(1, folderNamed('Favorites 0'));
    database.upsertWork(galleryId: 4, folderId: unfiled);
    database.removeWorkFromFolder(2, folderNamed('Favorites 0'));
    await sync.sync(host, pull: false);
    expect(site.members, {
      1: {1},
      3: {1},
      4: {2},
    }, reason: 'Moved, saved in another folder (kept in the first category without a folder), and removed');

    // Changes on the website reach the folders.
    site.members
      ..[3] = {0}
      ..[5] = {7};
    await sync.sync(host);
    expect(worksIn('Favorites 0'), [3]);
    expect(worksIn('Favorites 1'), [1]);
    expect(database.folderIDs(5), [folderNamed('Favorites 7')], reason: 'A category filled on the website later gets its own folder');

    // Nothing changed: nothing is sent.
    final writes = site.writes;
    await sync.sync(host);
    expect(site.writes, writes);
  });

  test('a website with lists keeps a work in each list folder it is in', () async {
    site = _Favorites(
      host,
      {
        1: {10, 11},
        2: {11},
      },
      exclusive: false,
      names: {10: 'Later', 11: 'Best', 12: 'Empty'},
    );
    await sync.setUp(host);
    expect(worksIn('Later'), [1]);
    expect(worksIn('Best'), [1, 2]);
    expect(sync.store.state(host)?.unassigned, 12, reason: 'Works in other folders go to the list without a folder');

    database.addWork(2, folderNamed('Later'));
    database.removeWorkFromFolder(1, folderNamed('Best'));
    await sync.sync(host, pull: false);
    expect(site.members, {
      1: {10},
      2: {10, 11},
    });
  });

  test('a category folder that went missing comes back with its works, and the website keeps them', () async {
    await sync.setUp(host);
    database.deleteFolder(folderNamed('Favorites 0'));
    expect(database.folderIDs(1), [database.unfiledFolderID()]);
    await sync.sync(host, pull: false);
    expect(worksIn('Favorites 0'), [1, 2]);
    expect(database.folderIDs(1), [folderNamed('Favorites 0')], reason: 'It leaves Unfiled again');
    expect(site.members, {
      1: {0},
      2: {0},
      3: {1},
    }, reason: "The website's favorites stay as they were");
  });

  test('a category filled on the website later gets its own folder', () async {
    await sync.setUp(host);
    expect(sync.store.state(host)?.unassigned, 2);
    site.members[7] = {3};
    await sync.sync(host);
    expect(worksIn('Favorites 3'), [7]);
  });

  test('a synced folder is kept only while signed in, and signing in again sets the sync up afresh', () async {
    await sync.setUp(host);
    final folder = folderNamed('Favorites 0');
    expect(sync.isSiteFavoritesFolder(folder), isTrue);
    expect(sync.isSiteFavoritesFolder(database.unfiledFolderID()), isFalse);
    SiteAccount.signOutAt(host);
    sync.forget(host);
    expect(sync.isSiteFavoritesFolder(folder), isFalse);
    expect(sync.store.state(host), isNull);
    expect(sync.store.isDeclined(host), isFalse, reason: 'Signing out is not turning the sync off');
    expect(SiteAccount.signIn(const [SiteCookie(name: 'ipb_member_id', value: '7'), SiteCookie(name: 'ipb_pass_hash', value: 'x')], host: host), isTrue);
    await sync.setUp(host);
    expect(database.listFolders().where((folder) => folder.name == 'Favorites 0'), hasLength(1), reason: 'The folder of the same name is used again');
    expect(sync.isSiteFavoritesFolder(folder), isTrue);
  });

  test('a website that keeps the account out gets no folders, and turning the sync off keeps it off', () async {
    site.refuses = true;
    await sync.setUp(host);
    expect(sync.store.state(host), isNull);
    expect(database.listFolders().where((folder) => folder.name == 'Favorites 0'), isEmpty);

    site.refuses = false;
    await sync.setUp(host);
    expect(sync.store.state(host), isNotNull);
    sync.stop(host);
    expect(sync.store.isDeclined(host), isTrue);
    await sync.setUp(host);
    expect(sync.store.state(host), isNull, reason: 'Turned off, it is not set up again on its own');
    await sync.setUp(host, requested: true);
    expect(sync.store.state(host), isNotNull);
  });

  test('website priority reorders the connected websites', () {
    ContentPreferences.defaults.set('manga.sites', ['a.example.org', 'b.example.org', 'c.example.org']);
    ComicSites.reorder(['c.example.org', 'a.example.org']);
    expect(ComicSites.all.take(3), ['c.example.org', 'a.example.org', 'b.example.org']);
  });
}
