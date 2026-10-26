import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/sync_snapshot.dart';

import 'backup_codec_test.dart' show combinedFixture;

String _empty() {
  final store = LibraryStore.memory();
  try {
    return BackupCodec(store).exportJson();
  } finally {
    store.close();
  }
}

String _databaseContents(LibraryStore store) => jsonEncode({
  for (final table in [
    'sources',
    'folders',
    'items',
    'memberships',
    'artists',
    'history',
    'settings',
    'progress',
    'downloads',
    'portable',
  ])
    table: store.database
        .select('SELECT * FROM $table ORDER BY rowid')
        .map((row) => {...row})
        .toList(),
});

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.memory());
  tearDown(() => store.close());

  test('fingerprint ignores map order and four clocks, preserving nested dates and array order', () {
    final original = combinedFixture();
    final changed = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
    changed['exportedAt'] = '2026-10-27T00:00:00Z';
    changed['comics']['exported_at'] = '2026-10-27T00:00:00Z';
    changed['images']['exportedAt'] += 100;
    changed['challenges']['exportedAt'] = '2026-10-27T00:00:00Z';
    expect(
      SyncSnapshot.fingerprint(jsonEncode(changed)),
      SyncSnapshot.fingerprint(jsonEncode(original)),
    );
    expect(
      SyncSnapshot.fingerprint(
        jsonEncode(Map.fromEntries(original.entries.toList().reversed)),
      ),
      SyncSnapshot.fingerprint(jsonEncode(original)),
    );
    changed['comics']['works'][0]['portableExtra']['exportedAt'] =
        'Keep this date';
    expect(
      SyncSnapshot.fingerprint(jsonEncode(changed)),
      isNot(SyncSnapshot.fingerprint(jsonEncode(original))),
    );
    changed['comics']['works'][0]['portableExtra'].remove('exportedAt');
    changed['images']['favorites'][0]['post']['tags'] = ['highres', 'blue'];
    expect(
      SyncSnapshot.fingerprint(jsonEncode(changed)),
      isNot(SyncSnapshot.fingerprint(jsonEncode(original))),
    );
  });

  test('isEmpty considers metadata outside saved works', () {
    expect(SyncSnapshot.isEmpty(_empty()), isTrue);
    final fixture = combinedFixture();
    for (final (section, key) in [
      ('comics', 'folders'),
      ('comics', 'artists'),
      ('comics', 'history'),
      ('comics', 'saved_searches'),
      ('images', 'servers'),
      ('challenges', 'games'),
    ]) {
      final empty = jsonDecode(_empty()) as Map<String, dynamic>;
      empty[section][key] = fixture[section][key];
      expect(
        SyncSnapshot.isEmpty(jsonEncode(empty)),
        isFalse,
        reason: '$section.$key is meaningful library data',
      );
    }
    final extension = jsonDecode(_empty()) as Map<String, dynamic>;
    extension['portableExtra'] = {'enabled': false};
    expect(SyncSnapshot.isEmpty(jsonEncode(extension)), isFalse);
  });

  test('exact replacement removes deleted works, folders, memberships, artists, history and extras', () {
    final codec = BackupCodec(store);
    codec.importJson(jsonEncode(combinedFixture()));
    final comic = store.items(AppMode.manga).single;
    store.saveFolder(
      const LibraryFolder(
        id: 'local-extra',
        mode: AppMode.manga,
        name: 'Delete this folder',
      ),
    );
    store.saveItem(comic.item, folderIds: [...comic.folderIds, 'local-extra']);
    store.saveItem(
      const ContentItem(
        sourceId: '',
        id: 99,
        mode: AppMode.manga,
        title: 'Delete this work',
      ),
    );
    store.saveArtist(
      const ArtistEntry(name: 'Delete artist', mode: AppMode.manga),
    );
    store.recordSearch(AppMode.manga, '', 'Delete history');
    store.setPortable('backup.extras', {'oldExtension': 'Delete me'});
    final remote = combinedFixture();
    remote['comics']['works'][0]['title'] = 'Updated remotely';
    remote['comics']['works'][0]['note'] = '';
    remote['comics']['works'][0]['tags'] = '';
    remote['comics']['works'][0]['artists'] = '';
    remote['comics']['works'][0]['folders'] = <String>[];
    remote['comics']['works'][0].remove('language');
    remote['comics']['artists'] = [];
    remote['comics']['history'] = [];
    remote['comics']['saved_searches'] = [];
    remote['comics']['folders'] = [];
    remote['images']['savedTags'] = [];
    remote['images']['history'] = [];
    remote['images']['blacklist'] = {};
    remote['images']['selectedServerIDs'] = [];
    SyncSnapshot.replace(store, jsonEncode(remote));
    final saved = store.items(AppMode.manga).single;
    expect(saved.item.title, 'Updated remotely');
    expect(saved.folderIds, isEmpty);
    expect(saved.note, '');
    expect(saved.item.tags, isEmpty);
    expect(saved.item.artists, isEmpty);
    expect(saved.item.metadata.containsKey('language'), isFalse);
    expect(store.folders(AppMode.manga), isEmpty);
    expect(store.artists(AppMode.manga), isEmpty);
    expect(store.artists(AppMode.booru), isEmpty);
    expect(store.history(AppMode.manga), isEmpty);
    expect(store.history(AppMode.booru), isEmpty);
    expect(store.portable('backup.comics')!['saved_searches'], isEmpty);
    expect(
      store.portable('backup.extras')!.containsKey('oldExtension'),
      isFalse,
    );
    expect(store.setting('blacklist.remote'), '');
    expect(store.setting('selected.booru'), isEmpty);
    final exported = codec.exportJson();
    final second = LibraryStore.memory();
    try {
      BackupCodec(second).importJson(exported);
      expect(second.items(AppMode.manga).single.item.title, 'Updated remotely');
      expect(second.items(AppMode.manga).single.folderIds, isEmpty);
      expect(second.portable('backup.challenges')!['games'], hasLength(1));
    } finally {
      second.close();
    }
  });

  test('retained local source and media identity preserves progress, downloads, notes and device settings', () {
    store.saveSource(
      SourceConfig(
        id: 'manga-first',
        name: 'First',
        baseUrl: Uri.https('manga-first.invalid'),
        kind: SourceKind.manga,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: 'manga-second',
        name: 'Second',
        baseUrl: Uri.https('manga-second.invalid'),
        kind: SourceKind.manga,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: 'stable-local',
        name: 'Old name',
        baseUrl: Uri.https('example.invalid'),
        kind: SourceKind.gelbooru,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: 'removed-site',
        name: 'Remove',
        baseUrl: Uri.https('removed.invalid'),
        kind: SourceKind.danbooru,
      ),
    );
    BackupCodec(store).importJson(jsonEncode(combinedFixture()));
    final manga = store.items(AppMode.manga).single;
    final mangaJson = manga.item.toJson()
      ..['sourceId'] = 'manga-second'
      ..['thumbnailUrl'] = 'https://manga-second.invalid/cover.jpg'
      ..['mediaUrl'] = 'https://manga-second.invalid/page.jpg'
      ..['pageUrl'] = 'https://manga-second.invalid/gallery/12345'
      ..['pageCount'] = 20
      ..['metadata'] = {
        ...manga.item.metadata,
        'backend': 'indexed',
        'sourceSite': 'https://manga-second.invalid',
        'files': [
          {'name': 'one'},
        ],
      };
    store.saveItem(ContentItem.fromJson(mangaJson));
    final image = store.items(AppMode.booru).single;
    store.saveItem(
      ContentItem.fromJson({
        ...image.item.toJson(),
        'pageUrl': 'https://example.invalid/posts/77',
      }),
      note: 'Local image note',
    );
    store.saveItem(
      const ContentItem(
        sourceId: 'removed-site',
        id: 88,
        mode: AppMode.booru,
        title: 'Removed remotely',
      ),
    );
    store.setProgress(manga.item.key, 8);
    store.setProgress(image.item.key, 3);
    final download = {
      'item': image.item.toJson(),
      'localPath': '/local/media.jpg',
    };
    store.saveDownload(image.item.key, download);
    store.setSetting('appearance', 'dark');
    store.setSetting('reader.manga', {'rightToLeft': true});
    store.setSetting('credentials.stable-local', {'token': 'device secret'});
    store.setPortable('runtime.local', {'position': 3});
    final remote = combinedFixture();
    remote['images']['servers'][0]['name'] = 'Renamed remotely';
    remote['images']['servers'][0]['engine'] = 'danbooru';
    SyncSnapshot.replace(store, jsonEncode(remote));
    final retained = store.items(AppMode.manga).single.item;
    expect(retained.sourceId, 'manga-second');
    expect(retained.thumbnailUrl.toString(), mangaJson['thumbnailUrl']);
    expect(retained.mediaUrl.toString(), mangaJson['mediaUrl']);
    expect(retained.pageUrl.toString(), mangaJson['pageUrl']);
    expect(retained.pageCount, 20);
    expect(retained.metadata['files'], [
      {'name': 'one'},
    ]);
    expect(store.sources(AppMode.manga), hasLength(2));
    final server = store.sources(AppMode.booru).single;
    expect(server.id, 'stable-local');
    expect(server.name, 'Renamed remotely');
    expect(server.kind, SourceKind.danbooru);
    final retainedImage = store.items(AppMode.booru).single;
    expect(retainedImage.item.key, image.item.key);
    expect(retainedImage.note, 'Local image note');
    expect(
      retainedImage.item.pageUrl.toString(),
      'https://example.invalid/posts/77',
    );
    expect(store.progress(manga.item.key), 8);
    expect(store.progress(image.item.key), 3);
    expect(store.downloads().single, download);
    expect(store.setting('appearance'), 'dark');
    expect(store.setting('reader.manga'), {'rightToLeft': true});
    expect(store.setting('credentials.stable-local'), {
      'token': 'device secret',
    });
    expect(store.portable('runtime.local'), {'position': 3});
    final output = jsonDecode(BackupCodec(store).exportJson());
    expect(output['images']['servers'][0]['id'], 'stable-local');
    expect(
      output['images']['favorites'][0]['post']['serverID'],
      'stable-local',
    );
    expect(output['images']['history'][0]['serverID'], 'stable-local');
    expect(output['images']['savedTags'][0]['serverID'], 'stable-local');
  });

  test('malformed input and source collisions leave every table untouched', () {
    BackupCodec(store).importJson(jsonEncode(combinedFixture()));
    final before = _databaseContents(store);
    final invalid = combinedFixture();
    invalid['images']['favorites'][0]['folderID'] = 'missing';
    expect(
      () => SyncSnapshot.replace(store, jsonEncode(invalid)),
      throwsFormatException,
    );
    expect(_databaseContents(store), before);
    final collision = combinedFixture();
    collision['images']['servers'][0]['baseURL'] = 'https://different.invalid';
    expect(
      () => SyncSnapshot.replace(store, jsonEncode(collision)),
      throwsFormatException,
    );
    expect(_databaseContents(store), before);
    expect(
      () => SyncSnapshot.replace(store, jsonEncode(collision['comics'])),
      throwsFormatException,
    );
    expect(_databaseContents(store), before);
  });

  test('a live write failure rolls the complete replacement back', () {
    BackupCodec(store).importJson(jsonEncode(combinedFixture()));
    final before = _databaseContents(store);
    store.database.execute(
      "CREATE TRIGGER reject_sync BEFORE INSERT ON folders BEGIN SELECT RAISE(ABORT, 'blocked'); END",
    );
    expect(
      () => SyncSnapshot.replace(store, jsonEncode(combinedFixture())),
      throwsA(isA<SqliteException>()),
    );
    expect(_databaseContents(store), before);
  });

  test('explicit merge retains unique local and remote works, with remote duplicate metadata', () {
    final local = combinedFixture();
    final remote = combinedFixture();
    local['comics']['works'].add({
      'gallery_id': 11,
      'title': 'Local only',
      'folders': [],
    });
    remote['comics']['works'].add({
      'gallery_id': 22,
      'title': 'Remote only',
      'folders': [],
    });
    remote['comics']['works'][0]['title'] = 'Remote duplicate wins';
    final merged = SyncSnapshot.merge(jsonEncode(local), jsonEncode(remote));
    BackupCodec(store).importJson(merged);
    expect(store.items(AppMode.manga).map((s) => s.item.id).toSet(), {
      11,
      22,
      12345,
    });
    expect(store.saved('manga:12345')!.item.title, 'Remote duplicate wins');
    BackupCodec(store).inspect(merged);
  });
}
