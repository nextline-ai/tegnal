import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/migration/manga_viewer_import.dart';
import 'package:tegnal/core/migration/violet_import.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/sql_database.dart';

/// A backup with the tables and value shapes Violet exports on Android.
void _createBackup(String path) {
  final db = SqlDatabase.open(path);
  db.write((db) {
    db.execute('''
      CREATE TABLE android_metadata (locale TEXT);
      CREATE TABLE BookmarkGroup (Id integer primary key autoincrement, Name text, DateTime text, Description text, Color integer, Gorder integer);
      CREATE TABLE BookmarkArticle (Id integer primary key autoincrement, Article text, DateTime text, GroupId integer);
      CREATE TABLE BookmarkArtist (Id integer primary key autoincrement, Artist text, IsGroup integer, DateTime text, GroupId integer);
      CREATE TABLE ArticleReadLog (Id integer primary key autoincrement, Article text, DateTimeStart text, DateTimeEnd text, LastPage integer, Type integer);
      CREATE TABLE BookmarkCropImage (Id integer primary key autoincrement, Article integer, Page integer, Area text, AspectRatio double, DateTime text);
      CREATE TABLE SearchLog (Id integer primary key autoincrement, SearchWhat text, DateTime text);
    ''');
    db.execute('''
      INSERT INTO android_metadata VALUES ('ko_KR');
      INSERT INTO BookmarkGroup VALUES
        (1, 'violet_default', '2024-04-28 01:42:17.408162', 'Unclassified bookmarks.', 4288585374, 1),
        (3, 'Later', '2024-06-09 01:56:30.623878', '새로운 그룹', 4294940672, 3),
        (2, 'Rain', '2024-06-09 01:54:13.546289', 'Wet days', 4280391411, 2);
      INSERT INTO BookmarkArticle VALUES
        (4, '1001', '2024-04-29 23:47:23.370404', 1),
        (5, '1002', '2024-06-10 10:00:00.000000', 2),
        (6, '1001', '2024-06-11 10:00:00.000000', 3),
        (7, '1003', '2024-06-12 10:00:00.000000', 99),
        (8, 'not a number', '2024-06-13 10:00:00.000000', 1),
        (9, '1002', '2024-06-14 10:00:00.000000', 1);
      INSERT INTO BookmarkArtist VALUES
        (1, 'mira', 0, '2024-05-10 01:20:16.746477', 1),
        (2, 'studio', 1, '2024-05-11 01:20:16.746477', 1),
        (3, 'someone', 2, '2024-05-12 01:20:16.746477', 1),
        (4, 'sky atlas', 3, '2024-05-13 01:20:16.746477', 1),
        (5, '', 0, '2024-05-14 01:20:16.746477', 1);
      INSERT INTO ArticleReadLog VALUES
        (1, '1001', '2025-10-13 05:43:02.453711', '2025-10-13 05:43:20.778031', 5, 0),
        (2, '1001', '2025-10-14 05:43:02.453711', '', 7, 0),
        (3, '1002', '2025-10-12 05:43:02.453711', '2025-10-12 05:44:00.000000', 3, 0),
        (4, '5000', '2025-10-12 05:43:02.453711', '2025-10-12 05:44:00.000000', 3, 0);
    ''');
  });
  db.close();
}

void main() {
  late Directory directory;
  late String backup;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('violet-import');
    backup = '${directory.path}/violet-bookmarks.db.sqlite';
    _createBackup(backup);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('a backup is recognized by its bookmark tables', () {
    expect(VioletImportService.isBackup(backup), isTrue);
    final other = '${directory.path}/other.db';
    SqlDatabase.open(other)
      ..execute('CREATE TABLE Something (Id INTEGER)')
      ..close();
    expect(VioletImportService.isBackup(other), isFalse);
    expect(VioletImportService.isBackup('${directory.path}/missing.db'), isFalse);
  });

  test('groups become folders in order and works land in them with their saved dates', () async {
    final library = AppDatabase.inMemory();
    final progress = <(int, int)>[];
    final result = await VioletImportService(library).import(backup, progress: (done, total) => progress.add((done, total)));
    expect(result.folders, 2);
    expect(result.works, 3, reason: 'a work saved twice counts once, and a row without a number is skipped');
    expect(result.artists, 3);
    expect(progress.last, (6, 6));

    final folders = library.listFolders();
    expect(folders.where((folder) => folder.name != '미분류').map((folder) => folder.name), ['Rain', 'Later']);
    final rain = folders.firstWhere((folder) => folder.name == 'Rain');
    final later = folders.firstWhere((folder) => folder.name == 'Later');
    expect(rain.description, 'Wet days');
    expect(rain.color, 4280391411);
    expect(later.description, isNull, reason: "Violet's placeholder description is not kept");
    expect(later.color, isNot(4294940672), reason: "Violet's new-group color takes the next folder color");

    expect(library.getWork(1001)!.folders.map((folder) => folder.name), ['Later'], reason: 'filed works leave the default folder');
    expect(library.getWork(1002)!.folders.map((folder) => folder.name), ['Rain']);
    expect(library.getWork(1003)!.folders.map((folder) => folder.name), ['미분류'], reason: 'an unknown group files the work as unfiled');
    final saved = DateTime.parse(library.getWork(1002)!.bookmarkedAt);
    expect(saved.isUtc, isTrue);
    expect(saved, DateTime(2024, 6, 10, 10).toUtc().copyWith(millisecond: 0, microsecond: 0));
  });

  test('artists, groups and series are saved; uploaders are left out', () async {
    final library = AppDatabase.inMemory();
    await VioletImportService(library).import(backup);
    expect({for (final artist in library.listArtists()) (artist.name, artist.kind)}, {('mira', 0), ('studio', 1), ('sky atlas', 3)});
  });

  test('the reading log sets when saved works were last opened', () async {
    final library = AppDatabase.inMemory();
    final result = await VioletImportService(library).import(backup);
    expect(result.opened, 2, reason: 'only saved works take a reading time');
    expect(DateTime.parse(library.getWork(1001)!.lastOpenedAt!), DateTime(2025, 10, 14, 5, 43, 2).toUtc());
    expect(DateTime.parse(library.getWork(1002)!.lastOpenedAt!), DateTime(2025, 10, 12, 5, 44).toUtc());
    expect(library.getWork(1003)!.lastOpenedAt, isNull);
    expect(library.getWork(5000), isNull);
  });

  test('importing twice merges instead of duplicating', () async {
    final library = AppDatabase.inMemory();
    await VioletImportService(library).import(backup);
    await VioletImportService(library).import(backup);
    expect(library.listFolders().where((folder) => folder.name == 'Rain'), hasLength(1));
    expect(library.listAllGalleryIds().toSet(), {1001, 1002, 1003});
    expect(library.listArtists(), hasLength(3));
  });

  test('cancelling stops before any work is saved', () async {
    final library = AppDatabase.inMemory();
    await expectLater(VioletImportService(library).import(backup, cancelled: () => true), throwsA(isA<ImportCancelled>()));
    expect(library.listAllGalleryIds(), isEmpty);
  });
}
