// Ported from native-ios/TEGNALTests/LibraryBackupTests.swift (duplicate cleanup).
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/duplicate_cleanup.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/domain/models.dart';

void main() {
  late AppDatabase database;
  late Folder mine, other;

  setUp(() {
    database = AppDatabase.inMemory(preferences: AppPreferences.memory());
    mine = database.createFolder(name: 'Mine');
    other = database.createFolder(name: 'Other');
    database.upsertWork(
      galleryId: 10,
      folderId: other.id,
      title: '[Circle] Summer Days [Korean]',
      artists: 'Author',
      language: 'korean',
      bookmarkedAt: '2026-01-01T00:00:00Z',
      pageCount: 20,
    );
    database.upsertWork(
      galleryId: 30,
      folderId: mine.id,
      title: '[Circle] Summer Days [Korean] [Team B]',
      artists: 'Author',
      language: 'korean',
      bookmarkedAt: '2026-03-01T00:00:00Z',
      pageCount: 24,
    );
    database.upsertWork(
      galleryId: 20,
      title: '[Circle] Summer Days',
      artists: 'Author',
      language: 'japanese',
      bookmarkedAt: '2026-02-01T00:00:00Z',
      pageCount: 22,
    );
    database.upsertWork(galleryId: 40, title: 'Winter', artists: 'Someone', language: 'korean');
    database.setNote(10, 'Read twice');
  });

  List<DuplicateGroup> groups(DuplicateCleanupOptions options, {List<Folder> order = const []}) {
    final folders = database.listFolders();
    final keys = {for (final folder in folders) folder.id!: '${folder.id}'};
    final rank = DuplicateFinder.rank(order: [for (final folder in order) '${folder.id}'], standard: [for (final folder in folders) '${folder.id}']);
    return DuplicateFinder.comics(database.listWorks(), folderKeys: keys, folderRank: rank, options: options);
  }

  List<String> folderNames(int galleryId) => (database.getWork(galleryId)?.folders.map((folder) => folder.name).toList() ?? [])..sort();

  test('core titles drop bracketed parts but keep a bracket-only title', () {
    expect(DuplicateFinder.coreTitle('[Circle (Artist)] Summer Days! (Some Show) [Korean] [Team]'), 'summer days');
    expect(DuplicateFinder.coreTitle('【サークル】 夏の日 ［中国翻訳］'), '夏の日');
    expect(DuplicateFinder.coreTitle('Summer  Days'), DuplicateFinder.coreTitle('summer days [v2]'));
    expect(DuplicateFinder.coreTitle('[Only Brackets]'), 'only brackets', reason: 'A title that is all brackets keeps them');
  });

  test('duplicates match titles without brackets, and translations only when asked', () {
    var options = DuplicateCleanupOptions(match: DuplicateMatch.sameTitle, useFolderOrder: false);
    expect(groups(options).map((group) => {for (final copy in group.copies) copy.id}), [
      {'10', '30'},
    ], reason: "Another translator's copy is the same work");
    options = options.copyWith(acrossLanguages: true);
    expect(groups(options).map((group) => {for (final copy in group.copies) copy.id}), [
      {'10', '20', '30'},
    ]);
    options = options.copyWith(match: DuplicateMatch.exact);
    expect(groups(options), isEmpty, reason: 'Exact matching needs the same full title');
  });

  test('the kept copy follows folder order, language, then the rule', () {
    var options = DuplicateCleanupOptions(match: DuplicateMatch.sameTitle, acrossLanguages: true, useFolderOrder: false);
    expect(groups(options)[0].keeperID, '10');
    options = options.copyWith(keep: DuplicateKeep.newestSaved);
    expect(groups(options)[0].keeperID, '30');
    options = options.copyWith(keep: DuplicateKeep.mostPages);
    expect(groups(options)[0].keeperID, '30');
    options = options.copyWith(keep: DuplicateKeep.newestNumber);
    expect(groups(options)[0].keeperID, '30');
    options = options.copyWith(preferredLanguage: 'japanese');
    expect(groups(options)[0].keeperID, '20', reason: 'The preferred language comes before the rule');
    options = options.copyWith(useFolderOrder: true);
    expect(groups(options, order: [other, mine])[0].keeperID, '10', reason: 'A copy in a higher folder comes first of all');
    expect(groups(options, order: [mine, other])[0].keeperID, '30');
  });

  test('a cleanup combines folders and notes, and undo puts everything back', () {
    final found = groups(DuplicateCleanupOptions(match: DuplicateMatch.sameTitle), order: [mine, other]);
    expect(found[0].keeperID, '30');
    final undo = DuplicateCleaner.applyComics(found, combine: true, removeFromWebsite: true, database: database);
    expect(undo.removedCount, 1);
    expect(database.getWork(10), isNull);
    expect(folderNames(30), ['Mine', 'Other'], reason: "The kept copy takes the removed copy's folders");
    expect(database.getWork(30)?.note, 'Read twice');

    DuplicateCleaner.undo(undo, database: database);
    final back = database.getWork(10)!;
    expect(folderNames(10), ['Other']);
    expect(back.note, 'Read twice');
    expect(back.bookmarkedAt, '2026-01-01T00:00:00Z', reason: 'It returns as it was saved');
    expect(folderNames(30), ['Mine']);
    expect(database.getWork(30)?.note, isNull);
  });

  test('the same work number in several folders stays in one, and fixed folders are left alone', () {
    final a = database.createFolder(name: 'A'), b = database.createFolder(name: 'B'), site = database.createFolder(name: 'Favorites 0');
    database.upsertWork(galleryId: 1, folderId: a.id, title: 'One');
    database.addWork(1, b.id!);
    database.addWork(1, site.id!);
    database.upsertWork(galleryId: 2, folderId: a.id, title: 'Two');
    database.dbWriter.write((db) {
      db.execute("UPDATE folder_works SET added_at = '2026-01-01T00:00:00Z' WHERE folder_id = ?", [a.id]);
      db.execute("UPDATE folder_works SET added_at = '2026-02-01T00:00:00Z' WHERE folder_id = ?", [b.id]);
    });
    final folders = database.listFolders();
    final keys = {for (final folder in folders) folder.id!: '${folder.id}'};
    final names = {for (final folder in folders) '${folder.id}': folder.name};
    final times = DuplicateCleaner.folderTimes(database);
    List<DuplicateGroup> found(DuplicateCleanupOptions options, List<String> order) => DuplicateFinder.placements(
      database.listWorks(),
      addedAt: times,
      folderKeys: keys,
      folderNames: names,
      folderRank: DuplicateFinder.rank(order: order, standard: [for (final folder in folders) '${folder.id}']),
      fixed: {'${site.id}'},
      options: options,
    ).where((group) => group.workNumber == 1).toList();
    var options = DuplicateCleanupOptions();
    expect(options.match, DuplicateMatch.sameNumber, reason: 'The work number is the default');
    final byFolder = found(options, ['${b.id}']);
    expect(byFolder, hasLength(1));
    expect({for (final copy in byFolder[0].copies) copy.title}, {'A', 'B'}, reason: 'A folder kept with website favorites is not touched');
    expect(byFolder[0].keeper?.title, 'B');
    options = options.copyWith(useFolderOrder: false);
    expect(found(options, const [])[0].keeper?.title, 'A', reason: 'Without folder order, the folder it went into first stays');

    final undo = DuplicateCleaner.applyComics(byFolder, combine: true, removeFromWebsite: false, database: database);
    expect(undo.tidiedCount, 1);
    expect(undo.removedCount, 0, reason: 'No work leaves the library');
    expect(folderNames(1), ['B', 'Favorites 0']);
    DuplicateCleaner.undo(undo, database: database);
    expect(folderNames(1), ['A', 'B', 'Favorites 0']);
  });

  test('cleanup options read older saves and keep their choices, one set for each mode', () {
    final preferences = MemoryPreferences({'library.duplicateCleanup': '{"keep":"newestSaved"}'});
    final read = DuplicateCleanupOptions.load(preferences, images: false);
    expect(read.keep, DuplicateKeep.newestSaved);
    expect(read.match, DuplicateMatch.sameNumber, reason: "Options a save didn't have take their defaults");
    final changed = read.copyWith(folderOrder: ['3', '1']);
    changed.save(preferences, images: false);
    expect(DuplicateCleanupOptions.load(preferences, images: false), changed);
    expect(DuplicateCleanupOptions.load(preferences, images: true), DuplicateCleanupOptions(), reason: 'Each mode keeps its own');
  });
}
