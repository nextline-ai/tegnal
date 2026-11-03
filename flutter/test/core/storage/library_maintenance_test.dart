import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/storage/library_maintenance.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase database;
  setUp(() => database = AppDatabase.inMemory(preferences: AppPreferences.memory()));

  List<String> folderNames(int galleryId) => (database.getWork(galleryId)?.folders.map((folder) => folder.name).toList() ?? [])..sort();

  // LibraryBackupTests.testClassificationAndDuplicateReviewPreserveDifferentLanguagesFoldersAndNotes
  test('classification and duplicate review keep languages apart and merge folders and notes', () {
    final a = database.createFolder(name: 'A'), b = database.createFolder(name: 'B');
    database.upsertWork(galleryId: 101, folderId: a.id, title: 'Same Title', artists: 'Author', language: 'japanese', type: 'manga');
    database.upsertWork(galleryId: 102, folderId: b.id, title: 'Same Title', artists: 'Author', language: 'japanese', type: 'manga');
    database.upsertWork(galleryId: 103, title: 'Same Title', artists: 'Author', language: 'english', type: 'manga');
    database.upsertWork(galleryId: 101, title: 'Same Title');
    database.setNote(101, 'First note');
    database.setNote(102, 'Second note');
    final works = database.listWorks();
    expect(works, hasLength(3), reason: 'Saving the same number must update its existing record');
    final groups = LibraryMaintenance.classification(works: works, posts: const [], criterion: LibraryClassification.language);
    expect(groups.firstWhere((group) => group.name == 'japanese').count, 2);
    final candidates = LibraryMaintenance.duplicates(works: works, posts: const []);
    expect(candidates, hasLength(1));
    expect(candidates[0].count, 2);
    LibraryMaintenance.mergeComics(candidates[0], keeping: 101, database: database);
    final kept = database.getWork(101)!;
    expect(kept.folders.map((folder) => folder.name).toSet(), {'A', 'B'});
    expect(kept.note, contains('First note'));
    expect(kept.note, contains('Second note'));
    expect(database.getWork(102), isNull);
    expect(database.getWork(103), isNotNull);

    final first = server('first'), second = server('second');
    final p = post(1, first)..fileURL = 'https://a.example/0123456789abcdef0123456789abcdef.jpg';
    final q = post(2, second)..fileURL = 'https://b.example/0123456789abcdef0123456789abcdef.jpg';
    expect(LibraryMaintenance.duplicates(works: const [], posts: [p, q]).first.count, 2);
  });

  // FolderRuleTests: merging into a work that is Unfiled takes it out of Unfiled.
  test('merging a duplicate into an unfiled copy leaves only the real folder', () {
    final kept = database.createFolder(name: 'Kept');
    database.upsertWork(galleryId: 1, folderId: database.defaultSaveFolder().id, title: 'Same', artists: 'Author', language: 'korean', type: 'manga');
    database.upsertWork(galleryId: 2, folderId: kept.id, title: 'Same', artists: 'Author', language: 'korean', type: 'manga');
    final group = LibraryMaintenance.duplicates(works: database.listWorks(), posts: const []).first;
    LibraryMaintenance.mergeComics(group, keeping: 1, database: database);
    expect(folderNames(1), ['Kept']);
  });

  test('a work in two folders is not a duplicate', () {
    final first = database.createFolder(name: 'First'), second = database.createFolder(name: 'Second');
    database.upsertWork(galleryId: 1, folderId: first.id, title: 'Same', artists: 'Author', language: 'korean', type: 'manga');
    database.addWork(1, second.id!);
    expect(LibraryMaintenance.duplicates(works: database.listWorks(), posts: const []), isEmpty);
  });

  test('duplicate keys collapse whitespace and need a title and an artist', () {
    database.upsertWork(galleryId: 1, title: '  Same   Title ', artists: 'Author');
    database.upsertWork(galleryId: 2, title: 'same title', artists: 'author');
    database.upsertWork(galleryId: 3, title: 'Same Title');
    final works = database.listWorks();
    expect(LibraryMaintenance.duplicateKey(works.firstWhere((work) => work.galleryId == 3)), isNull);
    expect(LibraryMaintenance.duplicates(works: works, posts: const []).single.works.map((work) => work.galleryId).toSet(), {1, 2});
  });

  test('a file address that is not a hash keys by the whole address', () {
    final p = post(1, server('one'))..fileURL = 'https://a.example/image.png';
    final q = post(2, server('two'))..fileURL = 'https://b.example/image.png';
    expect(LibraryMaintenance.postDuplicateKey(p), 'url:https://a.example/image.png');
    expect(LibraryMaintenance.duplicates(works: const [], posts: [p, q]), isEmpty);
  });

  test('classify creates criterion folders, reuses them and keeps existing memberships', () {
    final mine = database.createFolder(name: 'Mine');
    database.upsertWork(galleryId: 1, folderId: mine.id, artists: 'Alpha, Beta');
    database.upsertWork(galleryId: 2, artists: 'Alpha');
    database.createFolder(name: 'Artists · Beta');
    final groups = LibraryMaintenance.classification(works: database.listWorks(), posts: const [], criterion: LibraryClassification.artist);
    expect(groups.map((group) => group.name), ['Alpha', 'Beta']);
    LibraryMaintenance.classify(groups, title: 'Artists', database: database);
    expect(folderNames(1), ['Artists · Alpha', 'Artists · Beta', 'Mine']);
    expect(folderNames(2), ['Artists · Alpha']);
    expect(database.listFolders().where((folder) => folder.name == 'Artists · Beta'), hasLength(1));
  });

  test('only unsorted keeps works outside any real folder', () {
    final real = database.createFolder(name: 'Real');
    database.upsertWork(galleryId: 1, folderId: real.id);
    database.upsertWork(galleryId: 2, folderId: database.defaultSaveFolder().id);
    final loaded = LibraryMaintenance.load(database: database, booru: false, onlyUnsorted: true, duplicates: false);
    expect(loaded.works.map((work) => work.galleryId), [2]);
    final all = LibraryMaintenance.load(database: database, booru: false, onlyUnsorted: true, duplicates: true);
    expect(all.works, hasLength(2));
  });

  test('image classification groups by rating, server name and first artist', () {
    final one = server('one'), two = server('two');
    final posts = [
      post(1, one, rating: 'g'),
      post(2, two, rating: 's', artists: const ['b', 'a']),
    ];
    final ratings = LibraryMaintenance.classification(works: const [], posts: posts, criterion: LibraryClassification.rating);
    expect(ratings.map((group) => group.name), ['g', 's']);
    final servers = LibraryMaintenance.classification(works: const [], posts: posts, criterion: LibraryClassification.server, serverNames: {'one': 'One'});
    expect(servers.map((group) => group.name), ['One', 'two']);
    final artists = LibraryMaintenance.classification(works: const [], posts: posts, criterion: LibraryClassification.artist);
    expect(artists.map((group) => group.name), ['b', 'sample_artist']);
  });

  test('names compare like localizedStandardCompare', () {
    final names = ['item 10', 'Item 2', 'item 1'];
    names.sort(localizedStandardCompare);
    expect(names, ['item 1', 'Item 2', 'item 10']);
  });
}
