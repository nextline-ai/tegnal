import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/library_store.dart';

Map<String, dynamic> comicsFixture() => {
  'version': 2,
  'exported_at': '2026-10-26T00:00:00Z',
  'folders': [
    {
      'id': 4,
      'name': 'Reading',
      'color': 0xFFEEDDCC,
      'sort_order': 2,
      'old_viewer_group_id': 42,
      'description': 'A portable description',
    },
  ],
  'works': [
    {
      'gallery_id': 12345,
      'title': 'Saved comic',
      'artists': 'Artist, Group',
      'note': 'Keep this note',
      'bookmarked_at': '2026-10-25T03:00:00Z',
      'language': 'japanese',
      'type': 'manga',
      'series': 'Series',
      'groups': 'Group',
      'tags': 'blue, sky',
      'published_at': '2024-01-01',
      'thumb_page': 3,
      'folders': ['Reading'],
      'portableExtra': {'edition': 2},
      'thumb_path': '/Users/private/cover.jpg',
    },
  ],
  'artists': [
    {'name': 'Artist', 'kind': 0, 'note': 'Artist memo'},
  ],
  'history': [
    {'query': 'artist:artist', 'used_at': 1792886400.0},
  ],
  'saved_searches': ['blue sky'],
};

Map<String, dynamic> imagesFixture() => {
  'format': 'tegnal-image-library', 'version': 1,
  // Swift Codable Date is seconds since 2001, not Unix milliseconds.
  'exportedAt': 814838400.0,
  'servers': [
    {
      'id': 'remote',
      'name': 'Example',
      'baseURL': 'https://example.invalid/index.php',
      'engine': 'gelbooru',
      'portableServerExtra': 7,
      'credentials': {'account': 'private', 'api_key': 'must-not-export'},
    },
  ],
  'folders': [
    {'id': 'unsorted', 'name': '', 'color': 0xFFFFFFFF},
  ],
  'favorites': [
    {
      'post': {
        'serverID': 'remote',
        'postID': 77,
        'previewURL': 'https://example.invalid/thumb.jpg',
        'sampleURL': 'https://example.invalid/sample.jpg',
        'fileURL': 'https://example.invalid/full.jpg',
        'width': 1200,
        'height': 1600,
        'tags': ['blue', 'highres'],
        'artists': ['Artist'],
        'rating': 'g',
        'score': 13,
        'fileExtension': 'jpg',
        'poolIDs': [9],
        'metadataTags': ['highres'],
        'favoriteCount': 5,
        'tagCategories': {'Artist': 1},
        'animated': false,
        'portablePostExtra': 'ok',
      },
      'folderID': 'unsorted',
      'savedAt': 1792886400.125,
      'portableFavoriteExtra': 9,
    },
  ],
  'history': [
    {'serverID': 'remote', 'query': 'blue', 'usedAt': 1792886400.0},
  ],
  'savedTags': [
    {'serverID': 'remote', 'name': 'blue', 'kind': 'tag'},
  ],
  'blacklist': {'remote': 'spoilers\nartist_*'},
  'selectedServerIDs': ['remote'],
};

Map<String, dynamic> challengeFixture() => {
  'format': 'tegnal-challenges',
  'schemaVersion': 1,
  'games': [
    {
      'id': 'sketch',
      'title': 'Sketch',
      'detail': '',
      'reels': [
        for (var i = 0; i < 2; i++)
          {
            'id': 'reel$i',
            'title': 'Choice $i',
            'filter': '',
            'options': [
              {
                'id': 'option$i',
                'text': 'Landscape',
                'tags': ['landscape'],
                'group': '',
                'enabled': true,
                'weight': 1,
              },
            ],
          },
      ],
      'groups': [],
      'template': '{reel1} · {reel2} · {goal}',
      'goal': {
        'mode': 'time',
        'time': {'minimum': 30, 'maximum': 60, 'step': 30},
        'count': {'minimum': 1, 'maximum': 3, 'step': 1},
        'timeWeight': 50,
        'countWeight': 50,
      },
      'target': 100,
      'bands': [
        {'id': 'band', 'through': 100, 'minimum': 1, 'maximum': 10},
      ],
      'multiplier': 1.0,
      'endings': [
        {
          'id': 'ending',
          'title': 'Done',
          'detail': '',
          'badge': '',
          'color': 'purple',
          'weight': 1,
        },
      ],
      'helpPages': [
        {'id': 'help', 'title': 'Guide', 'body': 'Choose a reference.'},
      ],
      'portableGameExtra': true,
    },
  ],
};

Map<String, dynamic> combinedFixture() => {
  'format': 'tegnal-library',
  'version': 1,
  'exportedAt': '2026-10-26T00:00:00Z',
  'comics': comicsFixture(),
  'images': imagesFixture(),
  'challenges': challengeFixture(),
  'portableExtra': {'description': 'Retain extension', 'apiKey': 'secret'},
  'settings': {'reader.progress': 10},
  'downloads': ['file:///private/media.jpg'],
};

void main() {
  late LibraryStore store;
  late BackupCodec codec;
  setUp(() {
    store = LibraryStore.memory();
    codec = BackupCodec(store);
  });
  tearDown(() => store.close());

  test('restored filters and selections use live settings and saved tag edits export', () {
    store.saveSource(
      SourceConfig(
        id: 'configured',
        name: 'Same server',
        baseUrl: Uri.parse('https://example.invalid'),
        kind: SourceKind.gelbooru,
      ),
    );
    final images = imagesFixture();
    images['savedTags'].add({
      'serverID': 'remote',
      'name': 'Artist',
      'kind': 'artist',
    });
    images['savedTags'].add({
      'serverID': 'remote',
      'name': 'starred query',
      'kind': 'search',
    });
    codec.importJson(jsonEncode(images));
    expect(store.setting('blacklist.configured'), 'spoilers\nartist_*');
    expect(store.setting('selected.booru'), ['configured']);
    expect(store.setting('source.booru'), 'configured');
    expect(store.artists(AppMode.booru).map((a) => a.kind).toSet(), {0, 1});
    final tag = store.artists(AppMode.booru).firstWhere((a) => a.kind == 1);
    store.removeArtist(tag);
    store.setSetting('blacklist.configured', 'changed rule');
    store.setSetting('selected.booru', <String>[]);
    final output = jsonDecode(codec.exportJson())['images'];
    expect(output['blacklist'], {'configured': 'changed rule'});
    expect(output['selectedServerIDs'], isEmpty);
    expect(output['savedTags'].map((dynamic t) => t['kind']).toSet(), {
      'artist',
      'search',
    });
    final second = LibraryStore.memory();
    try {
      BackupCodec(second).importJson(jsonEncode(output));
      expect(second.setting('blacklist.configured'), 'changed rule');
      expect(second.artists(AppMode.booru).single.name, 'Artist');
    } finally {
      second.close();
    }
  });

  test('exports all history entries without the UI display limit', () {
    for (var i = 0; i < 137; i++) {
      store.recordSearch(
        AppMode.manga,
        '',
        'tag$i',
        usedAt: DateTime.utc(2026)
            .add(Duration(microseconds: i * 1000000 + 123456)),
      );
    }
    final output = jsonDecode(codec.exportJson());
    expect(output['comics']['history'], hasLength(137));
    expect(
      output['comics']['history'].last['used_at'],
      DateTime.utc(2026).microsecondsSinceEpoch / 1000000 + 0.123456,
    );
  });

  test(
    'native combined roundtrip preserves portable metadata and date units',
    () {
      final summary = codec.inspect(jsonEncode(combinedFixture()));
      expect(summary.workCount, 2);
      expect(summary.folderCount, 2);
      expect(store.items(AppMode.manga), isEmpty);
      codec.importJson(jsonEncode(combinedFixture()));
      final comic = store.items(AppMode.manga).single;
      expect(
        comic.item.sourceId,
        '',
      ); // No fabricated domain or implicit server.
      expect(comic.note, 'Keep this note');
      expect(comic.savedAt, DateTime.utc(2026, 10, 25, 3));
      expect(
        store.items(AppMode.booru).single.savedAt.millisecondsSinceEpoch,
        1792886400125,
      );
      final output = jsonDecode(codec.exportJson()) as Map<String, dynamic>;
      final manga = output['comics'] as Map<String, dynamic>;
      final images = output['images'] as Map<String, dynamic>;
      expect(manga['version'], 2);
      expect((manga['folders'] as List).single['source_group_id'], 42);
      expect((manga['works'] as List).single['thumb_page'], 3);
      expect((manga['works'] as List).single['portableExtra'], {'edition': 2});
      expect((images['servers'] as List).single['portableServerExtra'], 7);
      expect(
        (images['favorites'] as List).single['post']['portablePostExtra'],
        'ok',
      );
      expect((images['favorites'] as List).single['portableFavoriteExtra'], 9);
      expect(
        (images['favorites'] as List).single['post']['fileURL'],
        'https://example.invalid/full.jpg',
      );
      expect((images['favorites'] as List).single['savedAt'], 1792886400.125);
      final swift = images['exportedAt'] as num;
      final reconstructed = DateTime.utc(2001)
          .add(Duration(microseconds: (swift * 1000000).round()));
      expect(
        reconstructed.difference(DateTime.now().toUtc()).inSeconds.abs(),
        lessThan(3),
      );
      expect(output['challenges']['games'].single['portableGameExtra'], true);
      expect(output['portableExtra'], {'description': 'Retain extension'});
      expect(jsonEncode(output), isNot(contains('must-not-export')));
      expect(jsonEncode(output), isNot(contains('/Users/private')));
      expect(output.containsKey('settings'), false);
      expect(output.containsKey('downloads'), false);
      final second = LibraryStore.memory();
      try {
        BackupCodec(second).importJson(jsonEncode(output));
        expect(second.items(AppMode.manga).single.note, 'Keep this note');
        expect(second.items(AppMode.booru).single.item.id, 77);
      } finally {
        second.close();
      }
    },
  );

  test('legacy modes merge idempotently and retain omitted data', () {
    store.saveSource(
      SourceConfig(
        id: 'manga',
        name: 'Configured',
        baseUrl: Uri.parse('https://manga.invalid'),
        kind: SourceKind.manga,
      ),
    );
    codec.importJson(jsonEncode(comicsFixture()));
    codec.importJson(
      jsonEncode(imagesFixture()..['format'] = 'number-memo-image-library'),
    );
    codec.importJson(
      jsonEncode(challengeFixture()..['format'] = 'number-memo-challenges'),
    );
    codec.importJson(jsonEncode(comicsFixture()));
    codec.importJson(jsonEncode(imagesFixture()));
    expect(store.items(AppMode.manga).single.item.sourceId, 'manga');
    expect(store.items(AppMode.booru), hasLength(1));
    expect(store.folders(AppMode.manga), hasLength(1));
    expect(store.folders(AppMode.booru), hasLength(1));
    final partial = comicsFixture();
    partial['folders'] = [];
    partial['works'] = [
      {'gallery_id': 12345, 'title': null, 'language': null},
    ];
    partial['artists'] = [];
    codec.importJson(jsonEncode(partial));
    final item = store.items(AppMode.manga).single;
    expect(item.item.title, 'Saved comic');
    expect(item.item.metadata['language'], 'japanese');
    expect(item.note, 'Keep this note');
    expect(item.folderIds, hasLength(1));
    final output = jsonDecode(codec.exportJson());
    expect(output['images']['favorites'], hasLength(1));
    expect(output['challenges']['games'], hasLength(1));
    expect(output['comics']['saved_searches'], ['blue sky']);
  });

  test('canonical server remapping and source ID collisions preserve composite post identity', () {
    store.saveSource(
      SourceConfig(
        id: 'existing',
        name: 'Existing',
        baseUrl: Uri.parse('https://example.invalid'),
        kind: SourceKind.gelbooru,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: 'collision',
        name: 'Other',
        baseUrl: Uri.parse('https://other.invalid'),
        kind: SourceKind.danbooru,
      ),
    );
    final images = imagesFixture();
    images['servers'].add({
      'id': 'collision',
      'name': 'New',
      'baseURL': 'https://new.invalid',
      'engine': 'danbooru',
    });
    final otherPost = Map<String, dynamic>.from(
      images['favorites'].single['post'] as Map,
    )..['serverID'] = 'collision';
    images['favorites'].add({
      'post': otherPost,
      'folderID': 'unsorted',
      'savedAt': 1792886401.0,
    });
    images['savedTags'].add({
      'serverID': 'collision',
      'name': 'Artist',
      'kind': 'artist',
    });
    images['blacklist']['collision'] = 'gore';
    images['selectedServerIDs'].add('collision');
    codec.importJson(jsonEncode(images));
    codec.importJson(jsonEncode(images));
    expect(store.sources(), hasLength(3));
    final posts = store.items(AppMode.booru);
    expect(posts, hasLength(2));
    expect(posts.map((p) => p.item.sourceId).toSet(), {
      'existing',
      'collision-import-1',
    });
    final output = jsonDecode(codec.exportJson())['images'];
    expect(output['selectedServerIDs'], ['existing', 'collision-import-1']);
    expect(output['blacklist'], {
      'existing': 'spoilers\nartist_*',
      'collision-import-1': 'gore',
    });
    expect(output['savedTags'].map((dynamic t) => t['serverID']).toSet(), {
      'existing',
      'collision-import-1',
    });
    expect(
      output['favorites'].map((dynamic f) => f['post']['serverID']).toSet(),
      {'existing', 'collision-import-1'},
    );
  });

  test('invalid later section rejects whole backup before mutation', () {
    final broken = combinedFixture();
    broken['images']['favorites'].single['folderID'] = 'missing';
    expect(() => codec.importJson(jsonEncode(broken)), throwsFormatException);
    expect(store.folders(AppMode.manga), isEmpty);
    expect(store.sources(), isEmpty);
    expect(store.portable('backup.comics'), isNull);
    final badChallenge = combinedFixture();
    badChallenge['challenges']['games'].single['template'] = '{unknown}';
    expect(
      () => codec.importJson(jsonEncode(badChallenge)),
      throwsFormatException,
    );
    expect(store.items(AppMode.manga), isEmpty);
  });

  test('transaction failure rolls back all earlier library changes', () {
    store.database.execute(
      "CREATE TRIGGER fail_image BEFORE INSERT ON items WHEN NEW.mode='booru' BEGIN SELECT RAISE(ABORT,'injected storage failure'); END;",
    );
    expect(
      () => codec.importJson(jsonEncode(combinedFixture())),
      throwsA(isA<Exception>()),
    );
    expect(store.items(AppMode.manga), isEmpty);
    expect(store.folders(AppMode.manga), isEmpty);
    expect(store.sources(), isEmpty);
    expect(store.portable('backup.comics'), isNull);
  });

  test('invalid versions, IDs, reference URLs, duplicate records and scalar types reject', () {
    final bads = <Map<String, dynamic>>[
      comicsFixture()..['version'] = 99,
      comicsFixture()
        ..['works'] = [
          {'gallery_id': 0},
        ],
      imagesFixture()..['selectedServerIDs'] = ['missing'],
      imagesFixture()
        ..['savedTags'] = [
          {'serverID': 'remote', 'name': 'x', 'kind': 'wrong'},
        ],
      challengeFixture()..['schemaVersion'] = 2,
    ];
    final remote = imagesFixture();
    remote['favorites'].single['post']['fileURL'] = 'file:///private/a.jpg';
    bads.add(remote);
    final duplicate = comicsFixture();
    duplicate['works'].add(duplicate['works'].single);
    bads.add(duplicate);
    final badColor = comicsFixture();
    badColor['folders'].single['color'] = -1;
    bads.add(badColor);
    for (final bad in bads) {
      expect(() => codec.inspect(jsonEncode(bad)), throwsFormatException);
    }
    expect(store.items(AppMode.manga), isEmpty);
  });

  test('fresh Flutter-created data exports native required keys without settings or media paths', () {
    store.saveSource(
      SourceConfig(
        id: 'server',
        name: 'Server',
        baseUrl: Uri.parse('https://server.invalid'),
        kind: SourceKind.danbooru,
      ),
    );
    store.saveFolder(
      const LibraryFolder(id: 'manga:mine', mode: AppMode.manga, name: 'Mine'),
    );
    store.saveItem(
      const ContentItem(
        sourceId: '',
        id: 4444,
        mode: AppMode.manga,
        title: 'Comic',
      ),
      folderIds: ['manga:mine'],
    );
    store.saveItem(
      ContentItem(
        sourceId: 'server',
        id: 99,
        mode: AppMode.booru,
        title: 'Image',
        mediaUrl: Uri.parse('https://server.invalid/99.jpg'),
        metadata: {'apiKey': 'secret', 'fileURL': 'file:///private/image.jpg'},
      ),
    );
    store.setSetting('apiKey', 'not-exported');
    final output = jsonDecode(codec.exportJson());
    expect(output['images']['folders'].single['id'], 'unsorted');
    final post = output['images']['favorites'].single['post'];
    for (final key in [
      'serverID',
      'postID',
      'width',
      'height',
      'tags',
      'artists',
      'rating',
      'score',
      'fileExtension',
      'poolIDs',
    ]) {
      expect(post.containsKey(key), true, reason: key);
    }
    expect(post['fileURL'], isNull);
    expect(jsonEncode(output), isNot(contains('not-exported')));
    expect(codec.inspect(jsonEncode(output)).workCount, 2);
  });
}
