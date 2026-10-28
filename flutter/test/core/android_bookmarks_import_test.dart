import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/android_bookmarks_import.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/legacy_import.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  late Directory directory;
  late LibraryStore store;
  late AndroidBookmarksImport importer;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'android-bookmarks-test-',
    );
    path = '${directory.path}/bookmarks.sqlite';
    store = LibraryStore.memory();
    importer = AndroidBookmarksImport(store);
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  void fixture({int extra = 0}) {
    final source = sqlite3.open(path);
    source.execute('''
      CREATE TABLE android_metadata(locale TEXT);
      CREATE TABLE BookmarkGroup(Id INTEGER PRIMARY KEY,Name TEXT,DateTime TEXT,Description TEXT,Color INTEGER,Gorder INTEGER);
      CREATE TABLE BookmarkArticle(Id INTEGER PRIMARY KEY,Article TEXT,DateTime TEXT,GroupId INTEGER);
      CREATE TABLE BookmarkArtist(Id INTEGER,Artist TEXT,IsGroup INTEGER,DateTime TEXT,GroupId INTEGER);
      CREATE TABLE ArticleReadLog(Id INTEGER,Article TEXT,DateTimeStart TEXT,DateTimeEnd TEXT,LastPage INTEGER,Type INTEGER);
      CREATE TABLE BookmarkCropImage(Id INTEGER,Article INTEGER,Page INTEGER,Area TEXT,AspectRatio REAL,DateTime TEXT);
      CREATE TABLE SearchLog(Id INTEGER,SearchWhat TEXT,DateTime TEXT);
      CREATE TABLE DownloadItem(Id INTEGER,Path TEXT,ThumbnailHeader TEXT);
      INSERT INTO BookmarkGroup VALUES(0,'fixture_default','2024-01-01','Default description',4281558681,0);
      INSERT INTO BookmarkGroup VALUES(2,'Reading','2024-01-01','Group description',-12298906,1);
      INSERT INTO BookmarkArticle VALUES(1,'100','2024-01-01T00:00:00Z',0);
      INSERT INTO BookmarkArticle VALUES(2,'100','2024-01-02T00:00:00Z',2);
      INSERT INTO BookmarkArticle VALUES(3,'{"Id":101}','2024-01-03T00:00:00Z',2);
      INSERT INTO BookmarkArticle VALUES(4,'invalid','2024-01-03',2);
      INSERT INTO BookmarkArtist VALUES(1,'Fixture artist',0,'2024-01-01',2);
      INSERT INTO BookmarkArtist VALUES(2,'Fixture group',1,'2024-01-01',2);
      INSERT INTO ArticleReadLog VALUES(1,'100','2024-01-01','2024-01-02',7,0);
      INSERT INTO ArticleReadLog VALUES(2,'999','2024-01-01','2024-01-02',15,0);
      INSERT INTO BookmarkCropImage VALUES(1,100,3,'opaque area',1.5,'2024-01-01');
      INSERT INTO SearchLog VALUES(1,'fixture query','2024-01-01T00:00:00Z');
      INSERT INTO SearchLog VALUES(2,'fixture query','2024-01-02T00:00:00Z');
      INSERT INTO SearchLog VALUES(3,'','2024-01-01');
      INSERT INTO DownloadItem VALUES(1,'/private/other-app/file','secret-header-fixture');
    ''');
    if (extra > 0) {
      source.execute('BEGIN');
      final insert = source.prepare(
        'INSERT INTO BookmarkArticle VALUES(?,?,?,?)',
      );
      try {
        for (var i = 0; i < extra; i++) {
          insert.execute([i + 10, '${i + 1000}', '2024-01-01', 2]);
        }
      } finally {
        insert.close();
      }
      source.execute('COMMIT');
    }
    source.close();
  }

  Map<String, int> counts(LibraryStore target) => {
    for (final table in [
      'items',
      'folders',
      'memberships',
      'artists',
      'history',
      'portable',
      'progress',
      'sources',
    ])
      table:
          target.database.select('SELECT COUNT(*) AS n FROM $table').single['n']
              as int,
  };

  test(
    'preview validates Android structure without modifying either database',
    () async {
      fixture();
      final before = sha256.convert(await File(path).readAsBytes());
      final summary = await importer.inspectFile(path);
      expect(summary.workCount, 2);
      expect(summary.folderCount, 2);
      expect(summary.artistCount, 2);
      expect(summary.readLogCount, 2);
      expect(summary.searchCount, 3);
      expect(summary.cropCount, 1);
      expect(summary.preservedRecordCount, 14);
      expect(summary.unsupportedDownloadCount, 1);
      expect(summary.duplicates, 1);
      expect(summary.skipped, 2);
      expect(counts(store).values, everyElement(0));
      expect(sha256.convert(await File(path).readAsBytes()), before);
    },
  );

  test(
    'bookmarks map to native library while opaque logs and crops remain local',
    () async {
      fixture();
      await importer.importFile(path);
      expect(store.items(AppMode.manga), hasLength(2));
      final saved = store.saved('manga:100')!;
      expect(saved.item.title, '#100');
      expect(saved.item.thumbnailUrl, isNull);
      expect(saved.item.sourceId, isEmpty);
      expect(store.sources(), isEmpty);
      expect(saved.savedAt, DateTime.utc(2024, 1, 2));
      expect(saved.folderIds, [
        store
            .folders(AppMode.manga)
            .where((f) => f.name == 'Reading')
            .single
            .id,
      ]);
      expect(
        store
            .folders(AppMode.manga)
            .singleWhere((f) => f.name == 'Reading')
            .color,
        0xff445566,
      );
      expect(store.artists(AppMode.manga).map((a) => a.kind).toSet(), {0, 1});
      expect(store.history(AppMode.manga).single.query, 'fixture query');
      expect(store.database.select('SELECT * FROM progress'), isEmpty);
      expect(store.saved('manga:999'), isNull); // An open isn't a bookmark.
      final archived = store.database
          .select(
            "SELECT payload FROM portable WHERE key LIKE 'legacy.androidBookmarks.record.%'",
          )
          .map((r) => jsonDecode(r['payload'] as String) as Map)
          .toList();
      expect(
        archived.where((r) => r['table'] == 'ArticleReadLog'),
        hasLength(2),
      );
      expect(
        archived.singleWhere(
          (r) => r['table'] == 'BookmarkCropImage',
        )['record']['Area'],
        'opaque area',
      );
      expect(jsonEncode(archived), isNot(contains('secret-header-fixture')));
      expect(jsonEncode(archived), isNot(contains('/private/other-app')));
    },
  );

  test('reimport preserves user metadata, note, placement, progress and artist edits', () async {
    fixture();
    store.saveFolder(
      const LibraryFolder(
        id: 'user-folder',
        mode: AppMode.manga,
        name: 'Reading',
        color: 0xff123456,
        position: 20,
      ),
    );
    store.saveItem(
      const ContentItem(
        sourceId: 'custom',
        id: 100,
        mode: AppMode.manga,
        title: 'User title',
        tags: ['user-tag'],
        metadata: {'metadata_source': 'manual'},
      ),
      folderIds: ['user-folder'],
      note: 'User note',
      savedAt: DateTime.utc(2020),
    );
    store.setProgress('manga:100', 12);
    store.saveArtist(
      const ArtistEntry(
        name: 'Fixture artist',
        mode: AppMode.manga,
        sourceId: 'custom',
        note: 'User artist note',
      ),
    );
    store.recordSearch(
      AppMode.manga,
      '',
      'fixture query',
      usedAt: DateTime.utc(2025),
    );
    await importer.importFile(path);
    final first = counts(store);
    // User renaming and color changes after import must also survive reimport.
    final imported = store
        .folders(AppMode.manga)
        .firstWhere((f) => f.id != 'user-folder');
    store.saveFolder(
      LibraryFolder(
        id: imported.id,
        mode: AppMode.manga,
        name: 'User renamed',
        color: 0xffabcdef,
        position: 30,
      ),
    );
    await importer.importFile(path);
    expect(counts(store), first);
    final saved = store.saved('manga:100')!;
    expect(saved.item.title, 'User title');
    expect(saved.item.tags, ['user-tag']);
    expect(saved.note, 'User note');
    expect(saved.savedAt, DateTime.utc(2020));
    expect(saved.folderIds, ['user-folder']);
    expect(store.progress(saved.item.key), 12);
    expect(
      store
          .artists(AppMode.manga)
          .singleWhere((a) => a.name == 'Fixture artist')
          .note,
      'User artist note',
    );
    expect(
      store
          .folders(AppMode.manga)
          .singleWhere((f) => f.id == 'user-folder')
          .toJson(),
      const LibraryFolder(
        id: 'user-folder',
        mode: AppMode.manga,
        name: 'Reading',
        color: 0xff123456,
        position: 20,
      ).toJson(),
    );
    expect(
      store.folders(AppMode.manga).singleWhere((f) => f.id == imported.id).name,
      'User renamed',
    );
    expect(store.history(AppMode.manga).single.usedAt, DateTime.utc(2025));
  });

  test('cancel after worker staging commits no live rows', () async {
    fixture();
    var cancelled = false, reported = 0;
    await expectLater(
      importer.importFile(
        path,
        isCancelled: () => cancelled,
        onProgress: (value) {
          reported = value;
          cancelled = true;
        },
      ),
      throwsA(isA<LegacyImportCancelled>()),
    );
    expect(reported, 14);
    expect(counts(store).values, everyElement(0));
  });

  test('late write failure rolls back folders, works, artists, searches and archives', () async {
    fixture();
    store.setSetting('user.preference', true);
    store.database.execute(
      "CREATE TRIGGER fail_archive BEFORE INSERT ON portable WHEN NEW.key LIKE 'legacy.androidBookmarks.record.%' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;",
    );
    await expectLater(
      importer.importFile(path),
      throwsA(isA<SqliteException>()),
    );
    expect(counts(store).values, everyElement(0));
    expect(store.setting('user.preference'), true);
    store.database.execute('DROP TRIGGER fail_archive');
    await importer.importFile(path);
    expect(store.items(AppMode.manga), hasLength(2));
  });

  test(
    'primary Android path rejects an old user database without fallback',
    () async {
      final old = sqlite3.open(path);
      old.execute(
        'CREATE TABLE BookmarkArticle(Id INTEGER,Article INTEGER,GroupId INTEGER,DateTime TEXT); CREATE TABLE BookmarkGroup(Id INTEGER,Name TEXT,Color INTEGER,Gorder INTEGER)',
      );
      old.close();
      await expectLater(importer.inspectFile(path), throwsFormatException);
      await expectLater(importer.importFile(path), throwsFormatException);
      expect(counts(store).values, everyElement(0));
    },
  );

  test(
    'large input stages off the caller isolate and remains idempotent',
    () async {
      fixture(extra: 5000);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        final summary = await importer.importFile(path);
        expect(summary.workCount, 5002);
        expect(ticks, greaterThan(1));
        final first = counts(store);
        await importer.importFile(path);
        expect(counts(store), first);
      } finally {
        timer.cancel();
      }
    },
  );

  test('native JSON roundtrip retains library data without leaking raw private archives', () async {
    fixture();
    await importer.importFile(path);
    final encoded = BackupCodec(store).exportJson();
    expect(encoded, isNot(contains('secret-header-fixture')));
    expect(encoded, isNot(contains('opaque area')));
    final restored = LibraryStore.memory();
    try {
      BackupCodec(restored).importJson(encoded);
      expect(restored.items(AppMode.manga), hasLength(2));
      expect(restored.folders(AppMode.manga), hasLength(2));
      expect(restored.artists(AppMode.manga), hasLength(2));
      expect(restored.history(AppMode.manga), hasLength(1));
      expect(restored.saved('manga:100')!.item.title, '#100');
    } finally {
      restored.close();
    }
  });
}
