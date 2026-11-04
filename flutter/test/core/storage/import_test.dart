import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/anime_boxes_import.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/migration/manga_viewer_import.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/sql_database.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_store.dart';

Uint8List _backup(Map<String, Object?> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, Object?> _sample() => {
  'backupVersion': '1.0',
  'servers': [
    {'url': 'http://images-a.invalid', 'type': 3, 'serverName': 'Images A', 'isSelected': true},
    {'url': 'https://images-b.invalid/', 'type': 1, 'serverName': 'Images B'},
    {'url': 'https://unknown.invalid', 'type': 99},
    {'url': 'not an address', 'type': 1},
  ],
  'favorites': [
    {
      'ppostId': 7,
      'ppostUrl': 'https://images-a.invalid/posts/7',
      'tags': 'sky cloud',
      'tag_artist': 'mira',
      'rating': 's',
      'score': 12,
      'dateAdded': '2026-09-02T12:00:00Z',
      'file': {'url': 'http://images-a.invalid/data/7.png', 'width': 800, 'height': 600},
      'preview': {'url': '/preview/7.jpg'},
    },
    {'ppostId': 7, 'ppostUrl': 'https://images-a.invalid/posts/7', 'tags': 'sky'},
    {'ppostId': 8, 'ppostUrl': 'https://images-b.invalid/index.php?id=8', 'tags': ['sea'], 'rating': 's'},
    {'ppostId': 9, 'ppostUrl': 'https://elsewhere.invalid/posts/9'},
    {'ppostId': 0, 'ppostUrl': 'https://images-a.invalid/posts/0'},
  ],
  'searchHistory': [
    {'searchText': 'sky', 'searchDate': '2026-09-01T00:00:00Z', 'starred': true},
    {'searchText': '  '},
  ],
  'bannedTags': [
    'gore',
    {'tag': 'spoilers'},
    {'name': ''},
  ],
};

void _createUserDatabase(String path) {
  final db = SqlDatabase.open(path);
  db.write((db) {
    db.execute('CREATE TABLE BookmarkGroup (Id INTEGER, Name TEXT, Color INTEGER, Gorder INTEGER, Description TEXT)');
    db.execute('CREATE TABLE BookmarkArticle (Id INTEGER, Article TEXT, GroupId INTEGER, DateTime TEXT)');
    db.execute('CREATE TABLE BookmarkArtist (Artist TEXT, IsGroup INTEGER)');
    db.execute("INSERT INTO BookmarkGroup VALUES (1, 'x_default', 0, 0, NULL), (5, 'Favorites', 4280000000, 1, 'Best')");
    db.execute("INSERT INTO BookmarkArticle VALUES (1, '1001', 5, '2026-01-02'), (2, '1002', 1, '2026-01-03'), (NULL, 'not a number', 1, '2026-01-04')");
    db.execute("INSERT INTO BookmarkArtist VALUES ('mira', 0), ('', 0), ('studio', 1)");
  });
  db.close();
}

void _createDataDatabase(String path) {
  final db = SqlDatabase.open(path);
  db.write((db) {
    db.execute('CREATE TABLE MangaColumnModel (Id INTEGER, Title TEXT, Type TEXT, Artists TEXT, Characters TEXT, Groups TEXT, Language TEXT, Series TEXT, Tags TEXT, Published)');
    db.execute(
      "INSERT INTO MangaColumnModel VALUES (1001, 'Rain &amp; Sky', 'manga', '|mira|', 'N/A', '', 'english', '|sky atlas|', '|tag:rain|female:umbrella|', 638000000000000000)",
    );
    db.execute("INSERT INTO MangaColumnModel VALUES (1002, 'Second', 'doujinshi', 'noa', NULL, NULL, 'korean', NULL, NULL, '2026-03-04')");
    db.execute("INSERT INTO MangaColumnModel VALUES (2000, 'Not in the library', 'manga', 'theo', NULL, NULL, 'english', NULL, NULL, NULL)");
  });
  db.close();
}

void main() {
  group('Anime Boxes', () {
    test('a backup reads servers by type and skips what it cannot place', () {
      final backup = AnimeBoxesBackup.parse(_backup(_sample()));
      expect(backup.servers.map((server) => server.engine), [BooruEngine.danbooru, BooruEngine.gelbooru]);
      expect(backup.servers.every((server) => server.baseURL.startsWith('https://')), isTrue);
      expect(backup.skippedServers, 2);
      expect(backup.selectedIDs, [backup.servers.first.id]);
      expect(backup.favorites.map((favorite) => favorite.post.postID), [7, 8]);
      expect(backup.skippedFavorites, 2);
      final first = backup.favorites.first.post;
      expect(first.fileURL, 'https://images-a.invalid/data/7.png');
      expect(first.previewURL, 'https://images-a.invalid/preview/7.jpg');
      expect(first.tags, ['sky', 'cloud']);
      expect(first.artists, ['mira']);
      expect(first.fileExtension, 'png');
      expect(backup.favorites[1].post.rating, 'g', reason: 'older engines rate safe works as general');
      expect(backup.history.map((search) => search.text), ['sky']);
      expect(backup.skippedHistory, 1);
      expect(backup.blacklist, ['gore', 'spoilers']);
      expect(backup.skippedRules, 1);
    });

    test('anything but a version 1.0 backup is refused', () {
      for (final data in [
        utf8.encode('not json'),
        utf8.encode('{}'),
        _backup({..._sample(), 'backupVersion': '2.0'}),
      ]) {
        expect(() => AnimeBoxesBackup.parse(Uint8List.fromList(data)), throwsA(AnimeBoxesImportError.format));
      }
      expect(() => AnimeBoxesBackup.parse(Uint8List(AnimeBoxesBackup.maximumBytes + 1)), throwsA(AnimeBoxesImportError.tooLarge));
      final empty = AnimeBoxesBackup.parse(_backup({'backupVersion': '1.0', 'servers': <Object?>[], 'favorites': <Object?>[]}));
      expect(() => BooruStore.inMemory().importAnimeBoxes(empty), throwsA(AnimeBoxesImportError.noServers));
    });

    test('importing merges servers, favorites, history and blocks once', () {
      final store = BooruStore.inMemory();
      final backup = AnimeBoxesBackup.parse(_backup(_sample()));
      final result = store.importAnimeBoxes(backup);
      expect(result.added, 2);
      expect(result.duplicates, 0);
      expect(result.serversAdded, 2);
      expect(store.servers, hasLength(2));
      expect(store.selectedServerIDs, [store.servers.first.id]);
      final server = store.servers.first;
      expect(store.history(server.id), contains('sky'));
      expect(store.savedTags(server.id, kind: 'search'), contains('sky'));
      expect(store.blacklist(server.id).split('\n'), ['gore', 'spoilers']);
      expect(store.tasteStore.events().map((event) => event.kind).toSet(), {TasteEventKind.imported});

      final again = store.importAnimeBoxes(AnimeBoxesBackup.parse(_backup(_sample())));
      expect(again.added, 0);
      expect(again.duplicates, 2);
      expect(again.serversAdded, 0);
      expect(store.servers, hasLength(2));
      expect(store.blacklist(server.id).split('\n'), ['gore', 'spoilers'], reason: 'rules are not repeated');
    });

    test('favorites can land in an Anime Boxes folder or an existing one', () {
      final store = BooruStore.inMemory();
      store.importAnimeBoxes(AnimeBoxesBackup.parse(_backup(_sample())), options: const AnimeBoxesImportOptions(folderID: 'anime-boxes', history: false, blacklist: false));
      expect(store.folders().any((folder) => folder.id == 'anime-boxes'), isTrue);
      expect(store.visibleFavorites(folderID: 'anime-boxes'), hasLength(2));
      expect(store.history(store.servers.first.id), isEmpty);
      expect(store.blacklist(store.servers.first.id), isEmpty);
      expect(
        () => BooruStore.inMemory().importAnimeBoxes(AnimeBoxesBackup.parse(_backup(_sample())), options: const AnimeBoxesImportOptions(folderID: 'missing')),
        throwsA(isA<BooruError>()),
      );
    });
  });

  group('manga viewer', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('viewer-import'));
    tearDown(() => directory.deleteSync(recursive: true));

    test('databases are recognized by their tables', () {
      final user = '${directory.path}/user.db', data = '${directory.path}/data.db';
      _createUserDatabase(user);
      _createDataDatabase(data);
      expect(MangaViewerImportService.isUserDatabase(user), isTrue);
      expect(MangaViewerImportService.isDataDatabase(user), isFalse);
      expect(MangaViewerImportService.isDataDatabase(data), isTrue);
      expect(MangaViewerImportService.isUserDatabase(data), isFalse);
      expect(MangaViewerImportService.isUserDatabase('${directory.path}/missing.db'), isFalse);
    });

    test('bookmarks, folders and artists import and catalog matches fill them', () {
      final user = '${directory.path}/user.db', data = '${directory.path}/data.db';
      _createUserDatabase(user);
      _createDataDatabase(data);
      final library = AppDatabase.inMemory();
      final service = MangaViewerImportService(library);
      final summary = service.importUserDatabase(user);
      expect(summary.folders, 2);
      expect(summary.works, 2);
      expect(summary.artists, 2);
      expect(library.listFolders().map((folder) => folder.name), containsAll(['Favorites']));
      expect(library.getWork(1001)!.folders.map((folder) => folder.name), ['Favorites'], reason: 'filed works leave the default folder');
      expect(library.listArtists().map((artist) => artist.name).toSet(), {'mira', 'studio'});

      final matched = service.matchAndFillWorks(data);
      expect(matched.matched, 2);
      expect(matched.totalWorks, 2);
      final work = library.getWork(1001)!;
      expect(work.title, 'Rain & Sky');
      expect(work.artists, 'mira');
      expect(library.getWork(2000), isNull, reason: 'only the library\'s own works are filled');
      expect(File(user).existsSync() && File(data).existsSync(), isTrue);
    });

    test('a whole catalog imports in pages and reports progress', () {
      final data = '${directory.path}/data.db';
      _createDataDatabase(data);
      final library = AppDatabase.inMemory();
      final counts = <int>[];
      expect(MangaViewerImportService(library).importDataDatabase(data, progress: counts.add), 3);
      expect(counts, [3]);
      final catalog = library.getCatalog(1001)!;
      expect(catalog.characters, isNull);
      expect(catalog.series, 'sky atlas');
      expect(catalog.tags, 'tag:rain, female:umbrella');
      expect(catalog.published, startsWith('2022-'));
      expect(library.getCatalog(1002)!.published, '2026-03-04');
    });

    test('cancelling stops before anything is written and a non-catalog file is refused', () {
      final user = '${directory.path}/user.db';
      _createUserDatabase(user);
      final library = AppDatabase.inMemory();
      expect(() => MangaViewerImportService(library).importUserDatabase(user, cancelled: () => true), throwsA(isA<ImportCancelled>()));
      expect(library.listAllGalleryIds(), isEmpty);
      expect(() => MangaViewerImportService(library).importDataDatabase(user), throwsA(isA<ImportFormatError>()));
    });
  });
}
