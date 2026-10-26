import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/legacy_import.dart';
import 'package:tegnal/data/library_store.dart';

Map<String, dynamic> animeFixture() => {
  'backupVersion': '1.0',
  'servers': [
    {
      'url': 'http://safebooru.org/index.php',
      'type': 1,
      'serverName': 'Safe',
      'isSelected': true,
      'api_key': 'secret',
    },
    {'url': 'https://safebooru.org', 'type': 1, 'serverName': 'Duplicate'},
    {'url': 'https://legacy.booru.org', 'type': '1', 'serverName': 'Old'},
    {'url': 'https://unsupported.invalid', 'type': 99},
  ],
  'favorites': [
    {
      'ppostId': '77',
      'ppostUrl': 'https://safebooru.org/index.php?page=post&s=view&id=77',
      'file': {
        'url': 'http://safebooru.org/images/77.jpg',
        'width': '800',
        'height': 1200,
        'ext': 'JPG',
      },
      'preview': {'url': '//safebooru.org/thumb/77.jpg'},
      'sample': {'url': '/sample/77.jpg'},
      'tags': 'blue sky',
      'tag_artist': ['Artist'],
      'rating': 's',
      'score': '14',
      'dateAdded': '2024-01-01T00:00:00Z',
    },
    {
      'ppostId': 78,
      'ppostUrl': 'https://safebooru.org/index.php?page=post&s=view&id=78',
      'file': {'url': '/images/78.png', 'width': 100, 'height': 200},
      'rating': 's',
      'dateAdded': 'invalid',
    },
    {'ppostId': 79, 'ppostUrl': 'https://safebooru.org.evil.invalid/post/79'},
    {
      'ppostId': 80,
      'ppostUrl': 'https://legacy.booru.org/index.php?id=80',
      'rating': 's',
    },
  ],
  'searchHistory': [
    {
      'searchText': 'blue sky',
      'searchDate': '2024-02-01T00:00:00Z',
      'starred': true,
    },
    {'searchText': '', 'searchDate': 'invalid'},
  ],
  'bannedTags': [
    'spoilers',
    {'tag': 'gore'},
    {'wrong': 'skip'},
  ],
};

void main() {
  late LibraryStore store;
  late LegacyImport importer;
  late Directory directory;
  setUp(() async {
    store = LibraryStore.memory();
    importer = LegacyImport(store);
    directory = await Directory.systemTemp.createTemp('tegnal-legacy-test-');
  });
  tearDown(() async {
    store.close();
    await directory.delete(recursive: true);
  });

  String userDatabase() {
    final path = '${directory.path}/user.db';
    final source = sqlite3.open(path);
    source.execute(
      'CREATE TABLE BookmarkGroup (Id INTEGER,Name TEXT,Color INTEGER,Gorder INTEGER,Description TEXT)',
    );
    source.execute(
      'CREATE TABLE BookmarkArticle (Id INTEGER,Article,GroupId INTEGER,DateTime TEXT)',
    );
    source.execute('CREATE TABLE BookmarkArtist (Artist TEXT,IsGroup)');
    source.execute('INSERT INTO BookmarkGroup VALUES (?,?,?,?,?)', [
      1,
      'old_default',
      0,
      0,
      'Default',
    ]);
    source.execute('INSERT INTO BookmarkGroup VALUES (?,?,?,?,?)', [
      2,
      "Reading'); DROP TABLE items; --",
      4294940672,
      1,
      'Named',
    ]);
    source.execute('INSERT INTO BookmarkArticle VALUES (?,?,?,?)', [
      1,
      '12345',
      1,
      '2024-01-02T00:00:00Z',
    ]);
    source.execute('INSERT INTO BookmarkArticle VALUES (?,?,?,?)', [
      2,
      12345,
      2,
      '2024-01-01T00:00:00Z',
    ]);
    source.execute('INSERT INTO BookmarkArticle VALUES (?,?,?,?)', [
      3,
      23456,
      999,
      'invalid date',
    ]);
    source.execute('INSERT INTO BookmarkArticle VALUES (?,?,?,?)', [
      4,
      -1,
      1,
      '2024-01-01T00:00:00Z',
    ]);
    source.execute('INSERT INTO BookmarkArtist VALUES (?,?)', ['Artist', '0']);
    source.execute('INSERT INTO BookmarkArtist VALUES (?,?)', ['Group', 1]);
    source.close();
    return path;
  }

  String catalogDatabase({String table = 'MangaColumnModel'}) {
    final path = '${directory.path}/data.db';
    final source = sqlite3.open(path);
    final quoted = '"${table.replaceAll('"', '""')}"';
    source.execute(
      'CREATE TABLE $quoted (Id INTEGER PRIMARY KEY,Title TEXT,Type TEXT,Artists TEXT,Characters TEXT,Groups TEXT,Language TEXT,Series TEXT,Tags TEXT,Published)',
    );
    final ticks =
        621355968000000000 +
        DateTime.utc(2024, 1, 2).microsecondsSinceEpoch * 10;
    source.execute('INSERT INTO $quoted VALUES (?,?,?,?,?,?,?,?,?,?)', [
      12345,
      'A &amp; B &quot;Title&quot;',
      'manga',
      '| Artist | N/A | Second |',
      'Hero',
      'Group',
      'japanese',
      'Series',
      'blue|sky',
      ticks,
    ]);
    source.execute('INSERT INTO $quoted VALUES (?,?,?,?,?,?,?,?,?,?)', [
      99999,
      'Unbookmarked',
      'manga',
      'Other',
      null,
      null,
      'english',
      null,
      null,
      '2023-01-01',
    ]);
    source.close();
    return path;
  }

  test('user.db is read-only, merges aliases and memberships, preserves existing data', () async {
    final path = userDatabase();
    final original = await File(path).readAsBytes();
    store.saveItem(
      const ContentItem(
        sourceId: '',
        id: 88888,
        mode: AppMode.manga,
        title: 'Existing',
      ),
    );
    final preview = await importer.inspectFile(path);
    expect(preview.workCount, 2);
    expect(store.folders(AppMode.manga), isEmpty);
    final result = await importer.importFile(path);
    expect(result.workCount, 2);
    expect(result.artistCount, 2);
    expect(result.skipped, 1);
    final comic = store
        .items(AppMode.manga)
        .firstWhere((s) => s.item.id == 12345);
    expect(comic.folderIds, hasLength(1));
    expect(
      store
          .folders(AppMode.manga)
          .firstWhere((f) => f.id == comic.folderIds.single)
          .name,
      contains('DROP TABLE'),
    );
    expect(comic.savedAt, DateTime.utc(2024, 1, 2));
    expect(store.items(AppMode.manga), hasLength(3));
    expect(store.artists(AppMode.manga).map((a) => a.kind).toSet(), {0, 1});
    await importer.importFile(path);
    expect(store.items(AppMode.manga), hasLength(3));
    expect(store.folders(AppMode.manga), hasLength(2));
    expect(await File(path).readAsBytes(), original);
  });

  test(
    'catalog match-only decodes ticks pipes HTML and protects manual metadata',
    () async {
      final path = catalogDatabase(table: 'Odd"ColumnModel');
      final original = await File(path).readAsBytes();
      store.saveItem(
        const ContentItem(
          sourceId: '',
          id: 12345,
          mode: AppMode.manga,
          title: 'Placeholder',
        ),
        note: 'My note',
      );
      final preview = await importer.inspectFile(path);
      expect(preview.matchedCount, 1);
      final result = await importer.importFile(path);
      expect(result.catalogCount, 1);
      expect(result.matchedCount, 1);
      final comic = store.items(AppMode.manga).single;
      expect(comic.item.title, 'A & B "Title"');
      expect(comic.item.artists, ['Artist', 'Second']);
      expect(comic.item.tags, ['blue', 'sky']);
      expect(comic.note, 'My note');
      expect(comic.item.metadata['published_at'], '2024-01-02T00:00:00.000Z');
      expect(store.portable('legacy.catalog.99999'), isNull);
      store.saveItem(
        ContentItem(
          sourceId: '',
          id: 12345,
          mode: AppMode.manga,
          title: 'My title',
          artists: ['My artist'],
          metadata: {...comic.item.metadata, 'metadata_source': 'manual'},
        ),
      );
      await importer.importFile(path);
      expect(store.items(AppMode.manga).single.item.title, 'My title');
      expect(store.items(AppMode.manga).single.item.artists, ['My artist']);
      expect(
        store.items(AppMode.manga).single.item.metadata['metadata_source'],
        'manual',
      );
      expect(await File(path).readAsBytes(), original);
    },
  );

  test('full catalog stores metadata without bookmarking extra works, later user import uses it', () async {
    final data = catalogDatabase();
    final result = await importer.importFile(data, fullCatalog: true);
    expect(result.catalogCount, 2);
    expect(result.matchedCount, 0);
    expect(store.items(AppMode.manga), isEmpty);
    expect(store.portable('legacy.catalog.99999')?['title'], 'Unbookmarked');
    final user = userDatabase();
    await importer.importFile(user);
    expect(
      store
          .items(AppMode.manga)
          .firstWhere((s) => s.item.id == 12345)
          .item
          .title,
      'A & B "Title"',
    );
  });

  test(
    'catalog cancellation and SQL failure leave all destination data unchanged',
    () async {
      final path = catalogDatabase();
      var canceled = false;
      await expectLater(
        importer.importFile(
          path,
          fullCatalog: true,
          isCancelled: () => canceled,
          onProgress: (_) => canceled = true,
        ),
        throwsA(isA<LegacyImportCancelled>()),
      );
      expect(store.portable('legacy.catalog.12345'), isNull);
      store.saveItem(
        const ContentItem(
          sourceId: '',
          id: 12345,
          mode: AppMode.manga,
          title: 'Keep',
        ),
      );
      store.database.execute(
        "CREATE TRIGGER fail_catalog BEFORE INSERT ON portable WHEN NEW.key LIKE 'legacy.catalog.%' BEGIN SELECT RAISE(ABORT,'injected failure'); END;",
      );
      await expectLater(
        importer.importFile(path, fullCatalog: true),
        throwsA(isA<Exception>()),
      );
      expect(store.items(AppMode.manga).single.item.title, 'Keep');
      expect(store.portable('legacy.catalog.12345'), isNull);
    },
  );

  test('Anime Boxes maps supported servers, secures media, merges filters and retains existing favorite folder/date', () {
    store.saveSource(
      SourceConfig(
        id: 'existing',
        name: 'Existing',
        baseUrl: Uri.parse('https://safebooru.org'),
        kind: SourceKind.gelbooru,
      ),
    );
    store.saveFolder(
      const LibraryFolder(
        id: 'my-folder',
        mode: AppMode.booru,
        name: 'My folder',
        color: 0xFFAABBCC,
      ),
    );
    store.saveItem(
      const ContentItem(
        sourceId: 'existing',
        id: 77,
        mode: AppMode.booru,
        title: 'Existing favorite',
      ),
      folderIds: ['my-folder'],
      savedAt: DateTime.utc(2020),
    );
    store.setPortable('backup.images', {
      'blacklist': {'existing': 'keep\nspoilers'},
      'selectedServerIDs': ['existing'],
    });
    final text = jsonEncode(animeFixture());
    final preview = importer.inspectAnimeBoxes(text);
    expect(preview.workCount, 2);
    expect(preview.duplicates, 1);
    expect(preview.skipped, 4);
    expect(store.sources(), hasLength(1));
    final result = importer.importAnimeBoxes(text);
    expect(result.serverCount, 1);
    expect(result.workCount, 2);
    expect(store.sources(), hasLength(2));
    final existing = store.saved('booru:existing:77')!;
    expect(existing.folderIds, ['my-folder']);
    expect(existing.savedAt, DateTime.utc(2020));
    final post78 = store
        .items(AppMode.booru)
        .firstWhere((s) => s.item.id == 78);
    expect(
      post78.item.mediaUrl.toString(),
      'https://safebooru.org/images/78.png',
    );
    expect(post78.item.metadata['rating'], 'g');
    expect(post78.savedAt, DateTime.utc(1970));
    final oldServer = store.sources().firstWhere(
      (s) => s.baseUrl.host == 'legacy.booru.org',
    );
    expect(oldServer.kind, SourceKind.oldGelbooru);
    expect(store.history(AppMode.booru, limit: null), hasLength(2));
    final output = jsonDecode(BackupCodec(store).exportJson())['images'];
    expect(output['blacklist']['existing'], 'keep\nspoilers\ngore');
    expect(output['savedTags'], hasLength(2));
    expect(jsonEncode(output), isNot(contains('secret')));
    importer.importAnimeBoxes(text);
    expect(store.items(AppMode.booru), hasLength(3));
    expect(store.saved('booru:existing:77')!.folderIds, ['my-folder']);
  });

  test('unsupported legacy file, format, and absent source do not mutate or create source files', () async {
    expect(
      () => importer.importAnimeBoxes(
        jsonEncode({'backupVersion': '2.0', 'servers': [], 'favorites': []}),
      ),
      throwsFormatException,
    );
    expect(
      () => importer.importAnimeBoxes(
        jsonEncode({'backupVersion': '1.0', 'servers': [], 'favorites': []}),
      ),
      throwsFormatException,
    );
    final path = '${directory.path}/unsupported.db';
    final source = sqlite3.open(path);
    source.execute('CREATE TABLE Unknown (id INTEGER)');
    source.close();
    await expectLater(importer.importFile(path), throwsFormatException);
    final absent = '${directory.path}/missing.db';
    await expectLater(importer.importFile(absent), throwsA(isA<Exception>()));
    expect(File(absent).existsSync(), false);
    expect(store.sources(), isEmpty);
  });

  test('user.db import failure rolls back folders works and artists', () async {
    final path = userDatabase();
    store.database.execute(
      "CREATE TRIGGER fail_artist BEFORE INSERT ON artists BEGIN SELECT RAISE(ABORT,'injected failure'); END;",
    );
    await expectLater(importer.importFile(path), throwsA(isA<Exception>()));
    expect(store.folders(AppMode.manga), isEmpty);
    expect(store.items(AppMode.manga), isEmpty);
  });
}
