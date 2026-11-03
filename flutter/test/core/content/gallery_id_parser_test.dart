// Ported from native-ios/TEGNALTests/GalleryIDParserTests.swift.
// Not ported yet:
// - testCancelledMangaViewerImportStopsBeforeOpeningTheSource,
//   testCancelledCatalogImportCommitsOnlyTheCompletedBatch and
//   testMangaViewerUserDbImportRoutesToCorrectFolders need MangaViewerImportService (step 7).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/gallery_id_parser.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/library_backup.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/domain/models.dart';

import 'content_test_support.dart';

void main() {
  setUp(resetContent);

  test('import metadata migration preserves folder identity and works', () {
    final directory = Directory.systemTemp.createTempSync('tegnal-migration-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/memo.sqlite';
    final preferences = AppPreferences.memory();
    final original = AppDatabase.open(path: path, preferences: preferences);
    final folder = original.createFolder(name: 'Imported folder', sourceGroupId: 42);
    original.upsertWork(galleryId: 1234, folderId: folder.id, title: 'Saved work');
    original.dbWriter.write((db) {
      db.execute('ALTER TABLE "folders" RENAME COLUMN "source_group_id" TO "legacy_group_id"');
      db.execute("DELETE FROM grdb_migrations WHERE identifier = 'v10_generic_import_metadata'");
    });
    original.dbWriter.close();
    final migrated = AppDatabase.open(path: path, preferences: preferences);
    final restored = migrated.listFolders().firstWhere((value) => value.name == folder.name);
    expect(restored.id, folder.id);
    expect(restored.sourceGroupId, 42);
    expect(migrated.listWorks(folderId: folder.id).map((work) => work.galleryId), [1234]);
    expect(migrated.createFolder(name: folder.name, sourceGroupId: 42).id, folder.id);
    final columns = migrated.dbWriter.columns('folders');
    expect(columns.contains('source_group_id'), isTrue);
    expect(columns.contains('legacy_group_id'), isFalse);
  });

  test('imported folder backup reads historical field and exports generic field', () {
    final folder = Folder(name: 'Imported folder', sourceGroupId: 42);
    final historical = {...folder.toJson()};
    historical['legacy_group_id'] = historical.remove('source_group_id');
    final restored = Folder.fromJson(decodeJsonObject(utf8.encode(jsonEncode(historical))));
    expect(restored.sourceGroupId, 42);
    expect(MangaImportMetadata.groupID(historical), 42);
    final exported = restored.toJson();
    expect(exported['source_group_id'], 42);
    expect(exported.containsKey('legacy_group_id'), isFalse);
  });

  test('standard manga url', () => expect(GalleryIDParser.parse('https://comics.example/galleries/1234567.html'), [1234567]));

  test('reader url', () => expect(GalleryIDParser.parse('https://comics.example/reader/9876543.html#1'), [9876543]));

  test('proxy url', () => expect(GalleryIDParser.parse('https://proxy.example/galleries/2345678.html?lang=ko'), [2345678]));

  test('nested share url', () {
    expect(GalleryIDParser.parse('https://share.example/link?u=https%3A%2F%2Fcomics.example%2Fgalleries%2F3456789.html'), [3456789]);
  });

  test('plain number tokens', () => expect(GalleryIDParser.parse('작품 번호 모음: 123456, 7891011; 4567890'), [123456, 7891011, 4567890]));

  test('manga url with year in title', () {
    expect(GalleryIDParser.parse('2024 Manga Comic https://comics.example/galleries/888888.html'), [
      888888,
    ], reason: 'Should prioritize the gallery URL and ignore the year 2024');
  });

  test('unique folder colors', () {
    final db = AppDatabase.inMemory();
    final createdColors = <int>{};
    for (var index = 1; index <= 20; index++) {
      final folder = db.createFolder(name: 'Folder $index');
      expect(folder.id, isNotNull, reason: 'Folder ID must not be nil upon creation');
      expect(createdColors.contains(folder.color), isFalse, reason: 'Color for folder $index should be unique and not repeated');
      createdColors.add(folder.color);
    }
    expect(createdColors.length, 20, reason: 'All 20 folders must have unique colors');
  });

  test('background backup export preserves library fields and separate outputs', () {
    final directory = Directory.systemTemp.createTempSync('tegnal-export-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final database = AppDatabase.inMemory();
    final folder = database.createFolder(name: 'Backup folder', color: 0xFF123456);
    database.upsertWork(galleryId: 1234, folderId: folder.id, title: 'Backup title', artists: 'Artist', tags: 'tag:test');
    database.setNote(1234, 'My note');
    database.setThumbPage(1234, 3);
    database.addFavoriteArtist('Artist');
    final first = MangaLibraryBackup.export(database, temporary: directory);
    final second = MangaLibraryBackup.export(database, temporary: directory);
    expect(first.path, isNot(second.path));
    final json = jsonDecode(first.readAsStringSync()) as Map<String, Object?>;
    expect(json['version'], 2);
    final work = (json['works'] as List).first as Map<String, Object?>;
    expect(work['gallery_id'], 1234);
    expect(work['title'], 'Backup title');
    expect(work['note'], 'My note');
    expect(work['tags'], 'tag:test');
    expect(work['thumb_page'], 3);
    expect(work['folders'], ['Backup folder']);
    expect(((json['artists'] as List).first as Map)['name'], 'Artist');
  });
}
