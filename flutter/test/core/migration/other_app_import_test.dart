import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/anime_boxes_import.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/migration/other_app_import.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/sql_database.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('tegnal-other-app-'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('viewer database export', () {
    String create() {
      final path = '${temp.path}/export.db';
      final db = SqlDatabase.open(path);
      const columns =
          'GID INTEGER PRIMARY KEY, TOKEN TEXT, TITLE TEXT, TITLE_JPN TEXT, THUMB TEXT, CATEGORY INTEGER, POSTED TEXT, UPLOADER TEXT, RATING REAL, SIMPLE_LANGUAGE TEXT';
      db.execute('CREATE TABLE LOCAL_FAVORITES ($columns, TIME INTEGER)');
      db.execute('CREATE TABLE DOWNLOADS ($columns, STATE INTEGER, LEGACY INTEGER, TIME INTEGER, LABEL TEXT)');
      db.execute('CREATE TABLE DOWNLOAD_LABELS (_id INTEGER PRIMARY KEY, LABEL TEXT, TIME INTEGER)');
      db.execute('CREATE TABLE HISTORY ($columns, MODE INTEGER, TIME INTEGER)');
      db.execute(
        "INSERT INTO LOCAL_FAVORITES VALUES (2000001, '0123456789', 'First &amp; Last', NULL, NULL, 2, '2024-01-02 03:04', 'u', 4.5, 'KO', 1700000000000)",
      );
      db.execute("INSERT INTO LOCAL_FAVORITES VALUES (2000002, 'not-a-key', NULL, 'Second', NULL, 512, NULL, NULL, 0, NULL, 1700000001000)");
      db.execute("INSERT INTO LOCAL_FAVORITES VALUES (0, NULL, 'Broken', NULL, NULL, 2, NULL, NULL, 0, NULL, 0)");
      db.execute("INSERT INTO DOWNLOAD_LABELS VALUES (1, 'Later', 0)");
      db.execute("INSERT INTO DOWNLOADS VALUES (2000003, 'abcdefabcd', 'Third', NULL, NULL, 4, NULL, NULL, 0, 'EN', 3, 0, 1700000002000, 'Later')");
      db.execute("INSERT INTO DOWNLOADS VALUES (2000001, '0123456789', 'First', NULL, NULL, 2, NULL, NULL, 0, 'KO', 3, 0, 1700000003000, NULL)");
      db.execute("INSERT INTO HISTORY VALUES (2000004, 'fedcbafedc', 'Read once', NULL, NULL, 8, NULL, NULL, 0, NULL, 0, 1700000004000)");
      db.close();
      return path;
    }

    test('becomes folders, with history only on request', () {
      final library = OtherAppImport.read(File(create()));
      expect(library.format, OtherAppFormat.viewerDatabase);
      expect([for (final shelf in library.shelves) shelf.name], [L10n.text('Favorites'), L10n.text('Downloads'), 'Later']);
      expect([for (final entry in library.shelves[0].entries) entry.id], [2000002, 2000001]);
      expect(library.skipped, 1);
      final first = library.shelves[0].entries.firstWhere((entry) => entry.id == 2000001);
      expect(first.key, '0123456789');
      expect(first.title, 'First & Last');
      expect(first.type, 'doujinshi');
      expect(first.language, 'korean');
      expect(first.publishedAt, isNotNull);
      final second = library.shelves[0].entries.firstWhere((entry) => entry.id == 2000002);
      expect(second.key, isNull);
      expect(second.title, 'Second');
      expect(second.type, 'western');
      expect([for (final entry in library.history) entry.id], [2000004]);
      expect(library.workCount, 3);

      final database = AppDatabase.inMemory();
      expect(database.importOtherApp(library), const OtherAppImportResult(added: 3, existing: 0, folders: 3));
      expect(database.getWork(2000004), isNull);
      expect(database.getWork(2000001)?.title, 'First & Last');
      expect(database.getWork(2000001)?.metadataSource, 'remote');
      expect(GalleryKeys.shared.key(2000003), 'abcdefabcd');
      final later = database.listFolders().firstWhere((folder) => folder.name == 'Later').id!;
      expect(database.galleryIDsInFolder(later), [2000003]);

      final again = database.importOtherApp(library, options: const OtherAppImportOptions(includeHistory: true));
      expect(again, const OtherAppImportResult(added: 1, existing: 3, folders: 1));
      final history = database.listFolders().firstWhere((folder) => folder.name == L10n.text('Reading History')).id!;
      expect(database.galleryIDsInFolder(history), [2000004]);
    });

    test('other apps\' databases point to their own imports', () {
      final viewer = SqlDatabase.open('${temp.path}/viewer.db')..execute('CREATE TABLE BookmarkArticle (Id INTEGER)');
      viewer.close();
      expect(() => OtherAppImport.readDatabase('${temp.path}/viewer.db'), throwsA(OtherAppImportError.mangaViewerDatabase));
      final images = SqlDatabase.open('${temp.path}/images.db')..execute('CREATE TABLE BooruItem (id INTEGER)');
      images.close();
      expect(() => OtherAppImport.readDatabase('${temp.path}/images.db'), throwsA(OtherAppImportError.imageAppBackup));
    });
  });

  test('app data export history keeps tags and keys', () {
    final body = {
      'gid': 3000001,
      'token': '1111111111',
      'title': 'Exported',
      'category': 'Artist CG',
      'language': 'Japanese',
      'galleryUrl': 'https://catalog.example/g/3000001/1111111111/',
      'publishTime': '2023-05-06 07:08',
      'tags': {
        'artist': [
          {
            'tagData': {'namespace': 'artist', '_key': 'someone'},
          },
        ],
        'parody': [
          {
            'tagData': {'namespace': 'parody', '_key': 'original'},
          },
        ],
        'female': [
          {
            'tagData': {'namespace': 'female', '_key': 'glasses'},
          },
        ],
      },
    };
    final rows = [
      {'gid': 3000001, 'jsonBody': jsonEncode(body), 'lastReadTime': '2024-02-03 04:05:06.000'},
      {'gid': 3000002, 'jsonBody': 'not json', 'lastReadTime': ''},
    ];
    final records = [
      {'id': -1, 'shareCode': '', 'identificationCode': '', 'type': 4, 'version': '1.0.0', 'config': '[]', 'ctime': 0},
      {'id': -1, 'shareCode': '', 'identificationCode': '', 'type': 5, 'version': '1.0.0', 'config': jsonEncode(rows), 'ctime': 0},
    ];
    final library = OtherAppImport.parse(utf8.encode(jsonEncode(records)), connectedHosts: const []);
    expect(library.format, OtherAppFormat.settingsExport);
    expect(library.workCount, 0);
    expect(library.skipped, 1);
    final entry = library.history.single;
    expect(entry.id, 3000001);
    expect(entry.key, '1111111111');
    expect(entry.type, 'artistcg');
    expect(entry.language, 'japanese');
    expect(entry.artists, ['someone']);
    expect(entry.tags.toSet(), {'series:original', 'female:glasses'});
    expect(entry.savedAt, isNotNull);

    final database = AppDatabase.inMemory();
    expect(database.importOtherApp(library, options: const OtherAppImportOptions(includeHistory: true)).added, 1);
    expect(database.getWork(3000001)?.artists, 'someone');
  });

  test('download folder manifests are found', () {
    final folder = Directory('${temp.path}/root/Downloads/3000005')..createSync(recursive: true);
    final manifest = {
      'gid': '3000005',
      'host': 'Keyed',
      'token': '2222222222',
      'title': 'Downloaded',
      'category': 'Asian Porn',
      'language': 'Korean',
      'uploader': 'u',
      'postedDate': 700000000.0,
      'rating': 4,
      'pages': [1, '1.jpg'],
      'tags': [
        {
          'rawNamespace': 'female',
          'contents': [
            {'rawNamespace': 'female', 'text': 'maid', 'isVotedUp': false, 'isVotedDown': false},
          ],
        },
        {
          'rawNamespace': 'language',
          'contents': [
            {'rawNamespace': 'language', 'text': 'translated', 'isVotedUp': false, 'isVotedDown': false},
          ],
        },
      ],
    };
    File('${folder.path}/manifest.json').writeAsStringSync(jsonEncode(manifest));
    File('${temp.path}/root/Downloads/.queue.json').writeAsStringSync('{}');
    final library = OtherAppImport.readDownloadFolder(Directory('${temp.path}/root'));
    expect(library.format, OtherAppFormat.downloadFolder);
    final entry = library.shelves.single.entries.single;
    expect(entry.id, 3000005);
    expect(entry.key, '2222222222');
    expect(entry.type, 'photo');
    expect(entry.language, 'korean');
    expect(entry.tags, ['female:maid']);
    expect(entry.publishedAt, isNotNull);
  });

  group('manga reader backup', () {
    List<int> varint(int value) {
      final bytes = <int>[];
      var rest = value;
      do {
        var byte = rest & 0x7F;
        rest >>= 7;
        if (rest != 0) byte |= 0x80;
        bytes.add(byte);
      } while (rest != 0);
      return bytes;
    }

    List<int> field(int number, int wire) => varint(number << 3 | wire);
    List<int> message(int number, List<int> bytes) => [...field(number, 2), ...varint(bytes.length), ...bytes];
    List<int> text(int number, String value) => message(number, utf8.encode(value));
    List<int> number(int number, int value) => [...field(number, 0), ...varint(value)];

    test('keeps only catalog works, by category', () {
      final keyed = [
        ...number(1, 6902),
        ...text(2, '/g/4000001/3333333333/'),
        ...text(3, 'Keyed work'),
        ...text(4, 'Artist A'),
        ...text(5, 'Artist A'),
        ...number(13, 1700000000000),
        ...number(17, 1),
        ...number(100, 1),
      ];
      final indexed = [...number(1, 77), ...text(2, '/galleries/4000002.html'), ...text(3, 'Indexed work'), ...message(17, varint(2))];
      final ordinary = [...number(1, 55), ...text(2, '/manga/some-series-123456.html'), ...text(3, 'Not a catalog work')];
      final removed = [...number(1, 6902), ...text(2, '/g/4000003/4444444444/'), ...number(100, 0)];
      final backup = [
        ...message(1, keyed),
        ...message(1, indexed),
        ...message(1, ordinary),
        ...message(1, removed),
        ...message(2, [...text(1, 'Reading'), ...number(2, 1)]),
        ...message(2, [...text(1, 'Done'), ...number(2, 2)]),
        ...message(101, [...text(1, 'Source'), ...number(2, 6902)]),
      ];
      final library = OtherAppImport.parse(Uint8List.fromList(gzip.encode(backup)), connectedHosts: const []);
      expect(library.format, OtherAppFormat.readerBackup);
      expect([for (final shelf in library.shelves) shelf.name], ['Reading', 'Done']);
      expect(library.shelves[0].entries.single.id, 4000001);
      expect(library.shelves[0].entries.single.key, '3333333333');
      expect(library.shelves[0].entries.single.artists, ['Artist A']);
      expect(library.shelves[1].entries.single.id, 4000002);
      expect(library.skipped, 1);
      expect(library.workCount, 2);
    });

    test('reads titled addresses only from the indexed source', () {
      final titled = [...number(1, 9001), ...text(2, '/doujinshi/some-title-4000010.html'), ...text(3, 'Titled')];
      final elsewhere = [...number(1, 9002), ...text(2, '/doujinshi/some-title-4000011.html'), ...text(3, 'Elsewhere')];
      final backup = [
        ...message(1, titled),
        ...message(1, elsewhere),
        ...message(101, [...text(1, 'Index Source'), ...number(2, 9001)]),
        ...message(101, [...text(1, 'Other Source'), ...number(2, 9002)]),
      ];
      final library = OtherAppImport.readerBackup(Uint8List.fromList(backup), indexedSourceDigests: {OtherAppImport.digest('index source')});
      expect([for (final entry in library.shelves.single.entries) entry.id], [4000010]);
      expect(library.skipped, 1);
      expect(OtherAppImport.isIndexedSource('Index Source'), isFalse);
    });
  });

  test('browser bookmarks keep folders and ignore other links', () {
    const html = '''
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Toolbar</H3>
    <DL><p>
        <DT><A HREF="https://catalog.example/g/5000001/5555555555/" ADD_DATE="1700000000">One</A>
        <DT><H3 ADD_DATE="1700000000">Comics &amp; more</H3>
        <DL><p>
            <DT><A HREF="https://index.example/galleries/5000002.html" ADD_DATE="1700000001">Two</A>
            <DT><A HREF="https://news.example/story-5000003.html" ADD_DATE="1700000002">Unrelated</A>
            <DT><A HREF="https://connected.example/some-title-5000004.html">Connected</A>
        </DL><p>
    </DL><p>
</DL><p>
''';
    final library = OtherAppImport.parse(utf8.encode(html), connectedHosts: const ['connected.example']);
    expect(library.format, OtherAppFormat.linkList);
    expect([for (final shelf in library.shelves) shelf.name], [null, 'Comics & more']);
    expect([for (final entry in library.shelves[0].entries) entry.id], [5000001]);
    expect(library.shelves[0].entries.single.key, '5555555555');
    expect([for (final entry in library.shelves[1].entries) entry.id], [5000002, 5000004]);
  });

  test('plain lists of numbers and links', () {
    final numbers = OtherAppImport.parse(utf8.encode('6000001\n6000002, 6000003\n'), connectedHosts: const []);
    expect([for (final entry in numbers.shelves.single.entries) entry.id], [6000001, 6000002, 6000003]);
    final mixed = OtherAppImport.parse(utf8.encode('see https://index.example/reader/6000004.html and 12345 words'), connectedHosts: const []);
    expect([for (final entry in mixed.shelves.single.entries) entry.id], [6000004]);
    expect(() => OtherAppImport.parse(utf8.encode('hello world 2024'), connectedHosts: const []), throwsA(OtherAppImportError.empty));
  });

  group('image apps', () {
    test('bookmark export finds servers from post pages', () {
      final export = {
        'version': 1,
        'date': '2024-01-01T00:00:00.000',
        'data': [
          {
            'id': 1,
            'booruId': 1,
            'createdAt': '2024-01-02T03:04:05.000',
            'sourceUrl': 'https://img.example/posts/101',
            'thumbnailUrl': 'https://cdn.img.example/p/101.jpg',
            'sampleUrl': 'https://cdn.img.example/s/101.jpg',
            'originalUrl': 'https://cdn.img.example/o/101.png',
            'width': 800.0,
            'height': 600.0,
            'tags': ['a', 'b'],
            'format': 'png',
            'postId': 101,
          },
          {
            'id': 2,
            'booruId': 2,
            'createdAt': '2024-01-02T03:04:05.000',
            'sourceUrl': 'https://pics.example/index.php?page=post&s=view&id=202',
            'originalUrl': 'https://pics.example/images/202.jpg',
            'tags': ['c'],
          },
          {
            'id': 3,
            'booruId': 3,
            'createdAt': '2024-01-02T03:04:05.000',
            'sourceUrl': 'https://wall.example/post/show/303/some-tags',
            'originalUrl': 'https://wall.example/image/303.jpg',
            'tags': <String>[],
          },
          {'id': 4, 'booruId': 4, 'createdAt': '', 'sourceUrl': 'https://elsewhere.example/art/404', 'originalUrl': 'https://elsewhere.example/404.jpg'},
        ],
      };
      final backup = AnimeBoxesBackup.parseBookmarks(utf8.encode(jsonEncode(export)))!;
      expect(backup.source, AnimeBoxesSource.bookmarkExport);
      expect([for (final server in backup.servers) server.engine], [BooruEngine.danbooru, BooruEngine.gelbooru, BooruEngine.moebooru]);
      expect([for (final favorite in backup.favorites) favorite.post.postID], [101, 202, 303]);
      expect(backup.favorites[0].post.width, 800);
      expect(backup.favorites[0].post.fileExtension, 'png');
      expect(backup.skippedFavorites, 1);

      final store = BooruStore.inMemory();
      final result = store.importAnimeBoxes(backup);
      expect(result.added, 3);
      expect(result.serversAdded, 3);
      final again = store.importAnimeBoxes(backup, options: const AnimeBoxesImportOptions(folderID: AnimeBoxesBackup.importedFolderID));
      expect(again.added, 0);
      expect(again.duplicates, 3);
    });

    test('app database favorites, tags and searches', () {
      final path = '${temp.path}/store.db';
      final db = SqlDatabase.open(path);
      db.execute(
        'CREATE TABLE BooruItem (id INTEGER PRIMARY KEY, thumbnailURL TEXT, sampleURL TEXT, fileURL TEXT, postURL TEXT, mediaType TEXT, isSnatched INTEGER, isFavourite INTEGER)',
      );
      db.execute('CREATE TABLE Tag (id INTEGER PRIMARY KEY, name TEXT, tagType TEXT, updatedAt INTEGER)');
      db.execute('CREATE TABLE ImageTag (tagID INTEGER, booruItemID INTEGER)');
      db.execute('CREATE TABLE SearchHistory (id INTEGER PRIMARY KEY, booruType TEXT, booruName TEXT, searchText TEXT, isFavourite INTEGER, timestamp TEXT)');
      db.execute(
        "INSERT INTO BooruItem VALUES (1, 'https://img.example/t/1.jpg', NULL, 'https://img.example/o/1.jpg', 'https://img.example/posts/11', 'image', 0, 1)",
      );
      db.execute("INSERT INTO BooruItem VALUES (2, NULL, NULL, 'https://img.example/o/2.jpg', 'https://img.example/posts/12', 'image', 1, 0)");
      db.execute("INSERT INTO Tag VALUES (1, 'blue_sky', NULL, NULL)");
      db.execute('INSERT INTO ImageTag VALUES (1, 1)');
      db.execute("INSERT INTO SearchHistory VALUES (1, 'danbooru', 'x', 'blue_sky', 1, '2024-01-01 00:00:00')");
      db.close();
      final backup = AnimeBoxesBackup.read(File(path));
      expect(backup.source, AnimeBoxesSource.imageAppDatabase);
      expect([for (final favorite in backup.favorites) favorite.post.postID], [11]);
      expect(backup.favorites.single.post.tags, ['blue_sky']);
      expect(backup.history.single.text, 'blue_sky');
      expect(backup.history.single.starred, isTrue);
    });
  });
}
