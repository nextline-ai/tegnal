// Ported from native-ios/TEGNALTests/FolderRuleTests.swift.
//
// Not ported yet, because the types they exercise have not been ported:
// - testViewerImportFilesOnlyWorksArrivingUnfiled: MangaViewerImportService (Core/Migration).
// - testMergingDuplicatesLeavesUnfiledWhenARealFolderCameAlong: LibraryMaintenance (duplicate merge).
// - testAWorkInTwoFoldersIsNotADuplicate: LibraryMaintenance (duplicate detection).
// - testRemovedBookmarkReturnsToItsFoldersAndNote: ContentBookmarkAction and AppEnvironment (bookmark undo).
// - testRemovedBookmarkSkipsAFolderDeletedSince: ContentBookmarkAction and AppEnvironment (bookmark undo).
// - testChangingFolderLeavesFoldersARuleAdded: ContentBookmarkAction and AppEnvironment.savedFolders.
// - testArtistQueriesAreRecognized: ArtistBrowsing (Presentation).
// UI-only tests (testFlowLayoutBreaksLinesAsIfReservedWidthWereUsed,
// testAddingToAFolderDoesNotChangeNotifications) belong to the screen ports.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/storage/library_backup.dart';
import 'package:tegnal/core/storage/work_query.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/domain/models.dart';

import '../../support/fixtures.dart';

void main() {
  late AppPreferences preferences;
  late AppDatabase database;

  setUp(() {
    preferences = AppPreferences.memory();
    database = AppDatabase.inMemory(preferences: preferences);
  });

  void setDefaultFolder(Folder folder) => preferences.defaults.set(LibrarySavePreferences.defaultFolderKey, database.identityOfFolder(folder.id!));

  FolderRule rule(String query, {String excluded = '', bool everyFolder = false}) =>
      FolderRule(folder: '', query: query, excluded: excluded, includesOtherFolders: everyFolder ? true : null);

  void save(int id, {String language = 'korean', List<String> tags = const ['female:sole female', 'tag:full color']}) => database.upsertWork(
    galleryId: id,
    folderId: database.defaultSaveFolder().id,
    title: 'Work $id',
    artists: 'Some Artist',
    language: language,
    type: 'manga',
    tags: tags.join(', '),
  );

  List<int> ids(String query) => database.listWorks(query: query).map((work) => work.galleryId).toList()..sort();

  Set<String> folderNames(int id) {
    final folders = database.listFolders();
    return database.folderIDs(id).map((folder) => folders.where((value) => value.id == folder).firstOrNull?.name).nonNulls.toSet();
  }

  void saveFolderRule(
    int folderID, {
    required String query,
    required String excluded,
    bool? includesOtherFolders,
    List<String>? sources,
    bool? isEnabled,
    bool? keepsOriginal,
  }) => database.saveRule(
    FolderRule(
      folder: database.identityOfFolder(folderID),
      query: query,
      excluded: excluded,
      isEnabled: isEnabled,
      sources: sources,
      includesOtherFolders: includesOtherFolders,
      keepsOriginal: keepsOriginal,
    ),
  );

  Folder unfiled() => database.listFolders().firstWhere((folder) => folder.name == '미분류');

  test('search reads fields exactly and honors exclusions', () {
    save(1);
    save(2, language: 'japanese', tags: ['female:sole female']);
    save(3, language: 'english', tags: ['female:sole dickgirl']);
    expect(ids('language:korean'), [1]);
    expect(ids('female:sole_female'), [1, 2]);
    expect(ids('female:sole'), isEmpty, reason: 'A field value matches one whole tag');
    expect(ids('female:sole_female -language:japanese'), [1]);
    expect(ids('female:sole_female language:japanese'), [2]);
    expect(ids('sole'), [1, 2, 3], reason: 'A plain word still searches every field');
    expect(ids('artist:some_artist'), [1, 2, 3]);
    expect(ids('100%'), isEmpty);
  });

  test('exclusions alone do not count as a query', () {
    save(1);
    expect(WorkQuery('', excluding: 'language:korean').isEmpty, isTrue);
    expect(database.matchingWorkCount(rule('', excluded: 'language:japanese')), 0);
  });

  test('folder filled from a tag keeps other folders and leaves unfiled', () {
    final favorites = database.createFolder(name: 'Favorites');
    save(1);
    database.addWork(1, favorites.id!);
    save(2);
    save(3, language: 'japanese');
    final korean = database.createFolder(name: 'Korean');
    expect(database.matchingWorkCount(rule('language:korean')), 1);
    expect(database.matchingWorkCount(rule('language:korean', everyFolder: true)), 2);
    database.addMatchingWorks(rule('language:korean', everyFolder: true), korean.id!);
    expect(folderNames(1), {'Favorites', 'Korean'});
    expect(folderNames(2), {'Korean'});
    expect(folderNames(3), {'미분류'});
  });

  test('rule applies to new saves and respects its exclusions', () {
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: 'tag:spoiler');
    save(1);
    save(2, tags: ['tag:spoiler']);
    save(3, language: 'japanese');
    expect(folderNames(1), {'Korean'});
    expect(folderNames(2), {'미분류'});
    expect(folderNames(3), {'미분류'});
  });

  test('filling a folder leaves works in other folders by default', () {
    final favorites = database.createFolder(name: 'Favorites');
    save(1);
    database.addWork(1, favorites.id!);
    save(2);
    final korean = database.createFolder(name: 'Korean');
    database.addMatchingWorks(rule('language:korean'), korean.id!);
    expect(folderNames(1), {'Favorites'});
    expect(folderNames(2), {'Korean'});
  });

  test('rule files works from the default save folder and keeps them there', () {
    final inbox = database.createFolder(name: 'Inbox');
    setDefaultFolder(inbox);
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    save(1);
    expect(folderNames(1), {'Inbox', 'Korean'});
    database.upsertWork(galleryId: 2, folderId: unfiled().id, language: 'korean', tags: 'tag:full color');
    expect(folderNames(2), {'Korean'}, reason: 'Unfiled stays a target when another folder is the default');
  });

  test('rule leaves other folders alone unless it includes them', () {
    final favorites = database.createFolder(name: 'Favorites');
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    database.upsertWork(galleryId: 1, folderId: favorites.id, language: 'korean', tags: 'tag:full color');
    expect(folderNames(1), {'Favorites'});

    saveFolderRule(korean.id!, query: 'language:korean', excluded: '', includesOtherFolders: true);
    database.upsertWork(galleryId: 2, folderId: favorites.id, language: 'korean', tags: 'tag:full color');
    expect(folderNames(2), {'Favorites', 'Korean'});
  });

  test('filling a folder takes works from the default save folder but not another', () {
    final inbox = database.createFolder(name: 'Inbox'), kept = database.createFolder(name: 'Kept');
    setDefaultFolder(inbox);
    save(1);
    save(2);
    database.addWork(2, kept.id!);
    final korean = database.createFolder(name: 'Korean');
    expect(database.matchingWorkCount(rule('language:korean')), 1);
    database.addMatchingWorks(rule('language:korean'), korean.id!);
    expect(folderNames(1), {'Inbox', 'Korean'});
    expect(folderNames(2), {'Inbox', 'Kept'}, reason: 'A work also placed in another folder was already sorted');
  });

  test('moving rule takes a new save out of the default save folder', () {
    final inbox = database.createFolder(name: 'Inbox');
    setDefaultFolder(inbox);
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '', keepsOriginal: false);
    save(1);
    expect(folderNames(1), {'Korean'}, reason: 'A moving rule leaves no copy in the folder the work landed in');
    save(2, language: 'japanese');
    expect(folderNames(2), {'Inbox'});
  });

  test('copying rule keeps a new save where it landed', () {
    final inbox = database.createFolder(name: 'Inbox');
    setDefaultFolder(inbox);
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '', keepsOriginal: true);
    save(1);
    expect(folderNames(1), {'Inbox', 'Korean'});
    expect(
      FolderRule(folder: '', query: 'x').copies,
      isTrue,
      reason: 'Rules saved before the choice keep copying',
    );
  });

  test('first moving rule in folder order takes the work and copies still apply', () {
    final korean = database.createFolder(name: 'Korean'), color = database.createFolder(name: 'Color'), all = database.createFolder(name: 'Everything');
    saveFolderRule(color.id!, query: 'tag:full_color', excluded: '', keepsOriginal: false);
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '', keepsOriginal: false);
    saveFolderRule(all.id!, query: 'language:korean', excluded: '', keepsOriginal: true);
    save(1);
    expect(folderNames(1), {'Korean', 'Everything'}, reason: 'Korean comes before Color in folder order; a copying rule adds too');
  });

  test('filling with a moving rule takes works out of the folders it looks in', () {
    final favorites = database.createFolder(name: 'Favorites'), kept = database.createFolder(name: 'Kept');
    save(1);
    database.addWork(1, favorites.id!);
    save(2);
    database.addWork(2, kept.id!);
    save(3);
    final korean = database.createFolder(name: 'Korean');
    final moving = FolderRule(
      folder: database.identityOfFolder(korean.id!),
      query: 'language:korean',
      sources: [database.identityOfFolder(favorites.id!)],
      keepsOriginal: false,
    );
    expect(database.matchingWorkCount(moving), 1);
    expect(database.matchingWorkCountElsewhere(moving), 2, reason: 'Kept and Unfiled match but are not looked in');
    database.addMatchingWorks(moving, korean.id!);
    expect(folderNames(1), {'Korean'});
    expect(folderNames(2), {'Kept'});
    expect(folderNames(3), {'미분류'});
    moving.includesOtherFolders = true;
    expect(database.matchingWorkCountElsewhere(moving), 0);
    database.addMatchingWorks(moving, korean.id!);
    expect(folderNames(2), {'Korean'});
    expect(folderNames(3), {'Korean'});
  });

  test('every rule sees a work arriving in unfiled', () {
    final korean = database.createFolder(name: 'Korean'), color = database.createFolder(name: 'Color');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    saveFolderRule(color.id!, query: 'tag:full_color', excluded: '');
    save(1);
    expect(folderNames(1), {'Korean', 'Color'});
  });

  test('rules saved before the option still load as unfiled only', () {
    const saved = '[{"id":"old","folder":"unsorted","query":"language:korean","excluded":""}]';
    final rules = (jsonDecode(saved) as List).map((value) => FolderRule.fromJson(jsonObject(value))).toList();
    expect(rules.map((rule) => rule.query), ['language:korean']);
    expect(rules[0].includesOtherFolders, isNull);
  });

  test('catalog tags run rules only where they were missing', () {
    final kept = database.createFolder(name: 'Kept'), korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    final unfiledID = database.defaultSaveFolder().id;
    database.upsertWork(galleryId: 1, folderId: unfiledID);
    database.upsertWork(galleryId: 2, folderId: kept.id);
    database.upsertWork(galleryId: 3, folderId: unfiledID);
    database.upsertWork(galleryId: 4, folderId: unfiledID, language: 'japanese', tags: 'tag:old');
    CatalogWork catalog(int id) => CatalogWork(id: id, language: 'korean', tags: 'tag:full color');

    expect(database.applyCatalogBatchToWorks([catalog(1), catalog(2), catalog(4)]), 3);
    expect(folderNames(1), {'Korean'});
    expect(folderNames(2), {'Kept'});
    expect(folderNames(4), {'미분류'}, reason: 'A work that already had tags was classified when they arrived');

    database.upsertCatalogBatch([catalog(3)]);
    database.applyCatalogToWorks();
    expect(folderNames(3), {'Korean'});
  });

  test('rule runs when tags arrive but never refiles a work taken out', () {
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    database.upsertWork(galleryId: 1, folderId: database.defaultSaveFolder().id);
    expect(folderNames(1), {'미분류'});
    database.upsertWork(galleryId: 1, language: 'korean', tags: 'tag:full color');
    expect(folderNames(1), {'Korean'});

    final other = database.createFolder(name: 'Other');
    database.moveWorkToFolder(1, other.id!, currentFolderId: korean.id!);
    database.upsertWork(galleryId: 1, language: 'korean', tags: 'tag:full color, tag:more');
    expect(folderNames(1), {'Other'});
  });

  test('disabled rules and deleted folders do nothing', () {
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    preferences.defaults.set(LibrarySavePreferences.rulesEnabledKey, false);
    save(1);
    expect(folderNames(1), {'미분류'});

    preferences.defaults.set(LibrarySavePreferences.rulesEnabledKey, true);
    database.deleteFolder(korean.id!);
    save(2);
    expect(folderNames(2), {'미분류'});
    expect(database.folderRules(), isEmpty);
  });

  test('default save folder falls back after deletion', () {
    final favorites = database.createFolder(name: 'Favorites');
    setDefaultFolder(favorites);
    expect(database.defaultSaveFolder().name, 'Favorites');
    database.deleteFolder(favorites.id!);
    expect(database.defaultSaveFolder().name, '미분류');
  });

  test('backup carries rules', () {
    final korean = database.createFolder(name: 'Korean');
    final favorites = database.createFolder(name: 'Favorites'), off = database.createFolder(name: 'Off');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: 'tag:spoiler', includesOtherFolders: true);
    saveFolderRule(off.id!, query: 'tag:old', excluded: '', sources: [database.identityOfFolder(favorites.id!)], isEnabled: false);
    final backup = MangaBackup.capture(database);
    backup.validate();
    final restored = AppDatabase.inMemory();
    restored.dbWriter.write((db) => backup.restore(db, restored));
    final rules = restored.folderRules();
    expect(rules.map((entry) => entry.rule.query), ['language:korean', 'tag:old']);
    expect(rules.map((entry) => entry.rule.excluded), ['tag:spoiler', '']);
    expect(rules.map((entry) => entry.rule.includesOtherFolders), [true, null]);
    expect(rules.map((entry) => entry.folder.name), ['Korean', 'Off']);
    expect(rules.map((entry) => entry.rule.isActive), [true, false]);
    final source = restored.listFolders().firstWhere((folder) => folder.name == 'Favorites');
    expect(rules[1].rule.sources, [restored.identityOfFolder(source.id!)]);
  });

  test('a folder is marked only while its rule is on', () {
    final korean = database.createFolder(name: 'Korean');
    expect(database.listFolders().firstWhere((folder) => folder.id == korean.id).displayName, 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: 'tag:spoiler');
    var listed = database.listFolders().firstWhere((folder) => folder.id == korean.id);
    expect(listed.displayName, 'Korean ✦');
    expect(listed.plainName, 'Korean');
    expect(listed.name, 'Korean', reason: 'The mark never enters the stored name');

    saveFolderRule(korean.id!, query: 'language:korean', excluded: 'tag:spoiler', isEnabled: false);
    listed = database.listFolders().firstWhere((folder) => folder.id == korean.id);
    expect(listed.displayName, 'Korean');
    expect(database.rule(database.identityOfFolder(korean.id!))?.excluded, 'tag:spoiler', reason: 'Turning a rule off keeps its tags');
    save(1);
    expect(folderNames(1), {'미분류'});
  });

  test('a rule reads exactly the folders it lists', () {
    final inbox = database.createFolder(name: 'Inbox'), other = database.createFolder(name: 'Other'), korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '', sources: [database.identityOfFolder(inbox.id!)]);
    database.upsertWork(galleryId: 1, folderId: inbox.id, language: 'korean', tags: 'tag:full color');
    database.upsertWork(galleryId: 2, folderId: other.id, language: 'korean', tags: 'tag:full color');
    save(3);
    expect(folderNames(1), {'Inbox', 'Korean'});
    expect(folderNames(2), {'Other'});
    expect(folderNames(3), {'미분류'}, reason: 'Unfiled is only read when it is on the list');
    final listed = database.rule(database.identityOfFolder(korean.id!))!;
    expect(database.matchingWorkCount(listed), 1);
    expect(database.defaultRuleSources().contains('unsorted'), isTrue);
  });

  test('a marked choice shows which folders are smart', () {
    final korean = database.createFolder(name: 'Korean'), plain = database.createFolder(name: 'Plain');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    final choices = database.folderChoices();
    expect(choices.firstWhere((choice) => choice.id == database.identityOfFolder(korean.id!)).name.endsWith('✦'), isTrue);
    expect(choices.firstWhere((choice) => choice.id == database.identityOfFolder(plain.id!)).name.endsWith('✦'), isFalse);
    expect(choices.where((choice) => !choice.canBeSmart).map((choice) => choice.id), ['unsorted']);
  });

  test('a work moved by hand stays in a folder it does not fit', () {
    final korean = database.createFolder(name: 'Korean');
    saveFolderRule(korean.id!, query: 'language:korean', excluded: '');
    save(1, language: 'japanese');
    database.moveWorkToFolder(1, korean.id!);
    expect(folderNames(1), {'Korean'});
    database.fill(database.rule(database.identityOfFolder(korean.id!))!);
    database.upsertWork(galleryId: 1, language: 'japanese', tags: 'tag:more');
    expect(folderNames(1), {'Korean'}, reason: "Rules only ever add, so a person's choice stands");
  });

  test('rules sharing one row split into a row per folder', () {
    final korean = database.createFolder(name: 'Korean'), color = database.createFolder(name: 'Color');
    final first = database.identityOfFolder(korean.id!), second = database.identityOfFolder(color.id!);
    final saved =
        '''
      [{"id":"a","folder":"$first","query":"language:korean","excluded":"tag:a","includesOtherFolders":true},
       {"id":"b","folder":"$second","query":"tag:color","excluded":""},
       {"id":"c","folder":"$first","query":"tag:later","excluded":""}]
      ''';
    database.dbWriter.write((db) {
      db.execute("INSERT INTO library_order VALUES ('folder_rules', ?)", [utf8.encode(saved)]);
      AppDatabaseFolderRules.adoptLegacyFolderRules(db);
    });
    expect(database.smartRules().map((rule) => rule.query), ['language:korean', 'tag:color']);
    expect(database.rule(first)?.includesOtherFolders, isTrue);
    expect(database.dbWriter.read((db) => db.row("SELECT value FROM library_order WHERE key = 'folder_rules'")), isNull);
  });

  test('an older default folder choice moves to its identity', () {
    final inbox = database.createFolder(name: 'Inbox');
    preferences.defaults.set(LibrarySavePreferences.legacyDefaultFolderKey, inbox.id!);
    database.identityOfFolder(inbox.id!);
    expect(database.defaultSaveFolder().name, 'Inbox');
    expect(preferences.defaults.string(LibrarySavePreferences.defaultFolderKey), database.identityOfFolder(inbox.id!));
    expect(preferences.defaults.object(LibrarySavePreferences.legacyDefaultFolderKey), isNull);
  });

  ({BooruStore store, BooruServer server, String site}) images() {
    final store = BooruStore.inMemory(), alpha = server('alpha');
    store.saveServer(alpha);
    return (store: store, server: alpha, site: 'site:${alpha.canonicalAddress}');
  }

  test('image rules file new favorites and leave choices alone', () {
    final (:store, :server, :site) = images();
    final scenery = store.saveFolder(name: 'Scenery'), kept = store.saveFolder(name: 'Kept');
    store.saveRule(FolderRule(folder: scenery, query: 'mountain', excluded: 'night'));
    expect(store.folders().firstWhere((folder) => folder.id == scenery).displayName, 'Scenery ✦');
    expect(store.folders().firstWhere((folder) => folder.id == scenery).plainName, 'Scenery');

    final matching = post(1, server, tags: ['Mountain', 'river']);
    final refused = post(2, server, tags: ['mountain', 'night']);
    final chosen = post(3, server, tags: ['mountain']);
    final toggled = post(4, server, tags: ['mountain']);
    store.saveFavorite(matching);
    store.saveFavorite(refused);
    store.saveFavorite(chosen, folderID: kept);
    store.toggleFavorite(toggled);
    expect(store.folderIDFor(matching), scenery);
    expect(store.folderIDFor(refused), site);
    expect(store.folderIDFor(chosen), kept, reason: 'A folder a person picks is never overruled');
    expect(store.folderIDFor(toggled), scenery);

    store.moveFavorites([matching], kept);
    store.saveFavorite(matching);
    expect(store.folderIDFor(matching), kept, reason: 'A moved image stays moved when its metadata refreshes');
  });

  test('image rules read chosen folders and fill saved favorites', () {
    final (:store, :server, :site) = images();
    final inbox = store.saveFolder(name: 'Inbox'), kept = store.saveFolder(name: 'Kept'), scenery = store.saveFolder(name: 'Scenery');
    final inInbox = post(1, server, tags: ['mountain']);
    final inKept = post(2, server, tags: ['mountain']);
    final inSite = post(3, server, tags: ['mountain']);
    store.saveFavorite(inInbox, folderID: inbox);
    store.saveFavorite(inKept, folderID: kept);
    store.saveFavorite(inSite);

    final rule = FolderRule(folder: scenery, query: 'mountain', sources: [inbox]);
    expect(store.matchingCount(rule), 1);
    rule.sources = null;
    expect(store.matchingCount(rule), 1, reason: 'By default only where favorites land');
    expect(store.defaultRuleSources(), {site});
    rule.includesOtherFolders = true;
    expect(store.matchingCount(rule), 3);
    rule.includesOtherFolders = null;
    rule.sources = [inbox];
    store.saveRule(rule);
    store.fill(rule);
    expect(store.folderIDFor(inInbox), scenery);
    expect(store.folderIDFor(inKept), kept);
    expect(store.folderIDFor(inSite), site);

    store.saveRule(FolderRule(folder: scenery, query: 'mountain', isEnabled: false));
    expect(store.folders().firstWhere((folder) => folder.id == scenery).displayName, 'Scenery', reason: 'The mark goes with the rule');
    final next = post(4, server, tags: ['mountain']);
    store.saveFavorite(next);
    expect(store.folderIDFor(next), site);

    store.deleteFolder(scenery);
    expect(store.smartRules(), isEmpty);
  });

  test('image imports and backups carry smart folders', () {
    final (:store, :server, site: _) = images();
    final scenery = store.saveFolder(name: 'Scenery');
    store.saveRule(FolderRule(folder: scenery, query: 'scenery', excluded: 'night', isEnabled: false));
    store.saveFavorite(post(1, server));
    final backup = BooruBackup.decode(store.exportBackup().encoded());
    final restored = BooruStore.inMemory();
    restored.restoreBackup(backup);
    expect(restored.rule(scenery), FolderRule(folder: scenery, query: 'scenery', excluded: 'night', isEnabled: false));

    final older = jsonObject(jsonDecode(utf8.decode(store.exportBackup().encoded())));
    older.remove('folderRules');
    expect(BooruBackup.decode(utf8.encode(jsonEncode(older))).folderRules, isNull);
  });
}
