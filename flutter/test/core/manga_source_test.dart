import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/manga_source.dart';

const _routing = """
'use strict';
gg = { m: function(g) { var o = 0; switch (g) { case 2730: o = 1; break; } return o; },
s: function(h) { var m = /(..)(.)\$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
b: '123/' };
""";

final _hash = List.filled(64, 'a').join();
final _config = SourceConfig(
  id: 'manga-custom',
  name: 'Custom manga',
  baseUrl: Uri.parse('https://comics.example'),
  kind: SourceKind.manga,
);

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Uint8List _ints(List<int> values) {
  final data = ByteData(values.length * 4);
  for (var index = 0; index < values.length; index++) {
    data.setUint32(index * 4, values[index]);
  }
  return data.buffer.asUint8List();
}

http.Response _range(
  http.Request request,
  Uint8List bytes, {
  bool incorrectStart = false,
}) {
  final match = RegExp(r'bytes=(\d+)-(\d+)')
      .firstMatch(request.headers['range']!);
  final start = int.parse(match!.group(1)!);
  final requestedEnd = int.parse(match.group(2)!);
  if (start >= bytes.length) return http.Response('', 416);
  final end = requestedEnd < bytes.length ? requestedEnd : bytes.length - 1;
  return http.Response.bytes(
    bytes.sublist(start, end + 1),
    206,
    headers: {
      'content-range':
          'bytes ${incorrectStart ? start + 1 : start}-$end/${bytes.length}',
    },
  );
}

class _IndexedFixture {
  final requests = <http.Request>[];
  List<int> ids = List.generate(25, (index) => 2000 - index);
  bool malformedRange = false;
  bool executableRouting = false;
  bool executableGallery = false;
  int homepageLoads = 0;
  bool moved = false;
  late final client = MockClient((request) async {
    requests.add(request);
    final path = Uri.decodeComponent(request.url.path);
    if (request.url.host == 'comics.example') {
      if (path == '/') {
        homepageLoads++;
        return http.Response(
          '<script src="/assets/common.js?v=7"></script>',
          200,
        );
      }
      if (path == '/assets/common.js') {
        return http.Response(
          "const domain = '${moved ? 'new-storage.example' : 'storage.example'}';",
          200,
        );
      }
    }
    if (request.url.host == 'ltn.storage.example' && moved) {
      throw http.ClientException('The backend moved');
    }
    if (path == '/index-all.nozomi' || path == '/popular/week-all.nozomi') {
      if (request.headers.containsKey('range')) {
        return _range(request, _ints(ids), incorrectStart: malformedRange);
      }
      return http.Response.bytes(_ints(ids), 200);
    }
    if (path == '/index-korean.nozomi') {
      return http.Response.bytes(_ints([2000]), 200);
    }
    if (path == '/galleriesindex/version') return http.Response('1', 200);
    if (path == '/galleriesindex/galleries.1.index') {
      final bytes = ByteData(464);
      bytes.setUint32(0, 1);
      bytes.setUint32(4, 4);
      final key = sha256.convert(utf8.encode('sample')).bytes.take(4).toList();
      for (var index = 0; index < 4; index++) {
        bytes.setUint8(8 + index, key[index]);
      }
      bytes.setUint32(12, 1);
      bytes.setUint64(16, 0);
      bytes.setUint32(24, 12);
      return _range(request, bytes.buffer.asUint8List());
    }
    if (path == '/galleriesindex/galleries.1.data') {
      return _range(request, _ints([2, 2000, 1999]));
    }
    if (path == '/artist/sample artist-all.nozomi') {
      return http.Response.bytes(_ints([2000, 1998]), 200);
    }
    if (path == '/tag/female:exclude-all.nozomi') {
      return http.Response.bytes(_ints([1999]), 200);
    }
    if (path == '/gg.js') {
      return http.Response(
        '$_routing${executableRouting ? 'unsafe();' : ''}',
        200,
      );
    }
    if (path.startsWith('/galleries/')) {
      final id = int.parse(path.split('/').last.split('.').first);
      final object = {
        'title': 'Title $id',
        'japanese_title': '日本語 &amp; &#x41;',
        'artists': [
          {'artist': 'sample artist'},
        ],
        'language': 'korean',
        'type': 'manga',
        'published': '2026-10-01',
        'tags': [
          {'tag': 'sample', 'female': '1', 'male': true},
        ],
        'files': [
          {
            'hash': _hash,
            'name': '1.jpg',
            'width': 100,
            'height': 150,
            'hasavif': 1,
          },
        ],
      };
      return http.Response(
        'var galleryinfo = ${jsonEncode(object)};${executableGallery ? 'unsafe();' : ''}',
        200,
        headers: {'content-type': 'application/javascript; charset=utf-8'},
      );
    }
    if (request.url.host == 'tagindex.comics.example') {
      return _json([
        ['sample artist', 12, 'artist'],
        ['sample artist', 12, 'artist'],
      ]);
    }
    return http.Response('', 404);
  });
}

class _DocumentFixture {
  Object? category = 2;
  String? categoryLabel;
  String? serverType;
  List<Map<String, dynamic>> Function(Uri)? searchRows;
  final requests = <http.Request>[];
  bool expired = false;
  bool unsafe = false;
  int detailLoads = 0;
  Map<String, dynamic> row(int id) => {
    'id': id,
    'title': 'Book {name}',
    'title_jpn': null,
    'category': category,
    if (categoryLabel != null) 'category_label': categoryLabel,
    if (serverType != null) 'type': serverType,
    'views': id * 10,
    'blocked': 0,
    'thumb_extension': 'jpg',
    'unknownFutureField': 'preserved',
    'tags': [
      {
        'tag': ['language', 'korean'],
      },
      {
        'tag': ['artist', 'sample_artist'],
      },
      {
        'tag': ['parody', 'sample_series'],
      },
      {
        'tag': ['other', 'sample_tag'],
      },
    ],
  };
  late final client = MockClient((request) async {
    requests.add(request);
    if (request.url.path == '/') {
      return http.Response(
        '<script src="/js/index.search.tail.js"></script>'
        '<script>const serverConfig = {thumbServer: {"url":"https://preview.example"}};</script>',
        200,
      );
    }
    if (request.url.path == '/ajax/search') {
      final cursor = int.tryParse(
        request.url.queryParameters['next-id'] ??
            request.url.queryParameters['next-views-id'] ??
            '',
      );
      if (searchRows != null) return _json(searchRows!(request.url));
      return _json(
        cursor == null
            ? List.generate(50, (index) => row(2000 - index))
            : [row(1950), row(1949)],
      );
    }
    if (request.url.path == '/ajax/search-tags') {
      return _json(['parody:sample_series']);
    }
    if (request.url.path.startsWith('/r/')) {
      detailLoads++;
      final id = int.parse(request.url.pathSegments.last);
      final object = row(id);
      final expiry = expired && detailLoads == 1 ? 1 : 4102444800;
      object['title'] = 'Brace } and escaped " quote';
      object['files'] = [
        {
          'id': 'file-0',
          'name': '1.jpg',
          'image': {
            'url': unsafe
                ? 'https://127.0.0.1/private'
                : 'https://media.example/1.webp?expires=$expiry',
            'width': 100,
            'height': 150,
          },
          'thumbnail': {'url': 'https://media.example/1.jpg'},
        },
      ];
      return http.Response(
        '<script>const gallery = ${jsonEncode(object)}; ignoredFunction();</script>',
        200,
      );
    }
    return http.Response('', 404);
  });
}

void main() {
  test('document default range accepts unfamiliar server categories without inventing labels', () async {
    final fixture = _DocumentFixture()..category = 73;
    final source = MangaSource(_config, client: fixture.client);
    final result = await source.search('');
    expect(result.items.first.metadata['category_id'], 73);
    expect(result.items.first.metadata['category_label'], isNull);
    expect(result.items.first.tags, contains('type:73'));
    expect(
      fixture.requests.last.url.queryParameters.containsKey('categories'),
      false,
    );
    source.close();
  });

  test('document type names resolve only after the server supplies an ID and label', () async {
    final fixture = _DocumentFixture()
      ..category = {'id': 73, 'label': 'Illustrated Works'};
    final source = MangaSource(_config, client: fixture.client);
    final detail = await source.detail(2000);
    expect(detail.metadata['category_id'], 73);
    expect(detail.metadata['category_label'], 'Illustrated Works');
    expect(detail.tags, contains('type:illustrated_works'));
    final result = await source.search('type:illustrated_works');
    expect(result.items, isNotEmpty);
    expect(fixture.requests.last.url.queryParameters['categories'], '73');
    source.close();
  });

  test('document server type field is preserved as supplied rather than a built-in name', () async {
    final fixture = _DocumentFixture()
      ..category = 84
      ..serverType = 'Reference';
    final source = MangaSource(_config, client: fixture.client);
    final detail = await source.detail(2000);
    expect(detail.metadata['category_label'], 'Reference');
    expect(detail.tags, contains('type:reference'));
    await source.search('type:reference');
    expect(fixture.requests.last.url.queryParameters['categories'], '84');
    source.close();
  });

  test(
    'unknown named document type fails explicitly without broadening a search',
    () async {
      final fixture = _DocumentFixture();
      final source = MangaSource(_config, client: fixture.client);
      await source.search(
        '',
      ); // Seeing ID 2 alone does not identify its meaning.
      final previous = fixture.requests.length;
      await expectLater(
        source.search('type:manga'),
        throwsA(
          isA<ContentException>().having(
            (error) => error.message,
            'message',
            'This website does not provide a matching category label. Use a numeric category ID.',
          ),
        ),
      );
      expect(fixture.requests.length, previous);
      source.close();
    },
  );

  test('document negative category filters retain cursor order and page boundaries', () async {
    final fixture = _DocumentFixture();
    fixture.searchRows = (url) => url.queryParameters['next-id'] == null
        ? List.generate(
            50,
            (index) => {
              ...fixture.row(2000 - index),
              'category': index.isEven ? 73 : 88,
            },
          )
        : [
            {...fixture.row(1950), 'category': 73},
            {...fixture.row(1949), 'category': 73},
          ];
    final source = MangaSource(_config, client: fixture.client);
    final first = await source.search('-type:88');
    final second = await source.search('-type:88', page: 2);
    expect(first.items, hasLength(20));
    expect(first.hasMore, true);
    expect(second.items, hasLength(7));
    expect(second.hasMore, false);
    final ids = [
      ...first.items,
      ...second.items,
    ].map((item) => item.id).toList();
    expect(ids.toSet(), hasLength(27));
    expect(ids, [...ids]..sort((a, b) => b.compareTo(a)));
    final requests = fixture.requests
        .where((request) => request.url.path == '/ajax/search')
        .toList();
    expect(requests, hasLength(2));
    expect(requests.last.url.queryParameters['next-id'], '1951');
    expect(
      requests.every(
        (request) => !request.url.queryParameters.containsKey('categories'),
      ),
      true,
    );
    source.close();
  });

  test('fully excluded server pages advance their cursor until actual results or end', () async {
    final fixture = _DocumentFixture();
    fixture.searchRows = (url) => url.queryParameters['next-id'] == null
        ? List.generate(
            50,
            (index) => {...fixture.row(2000 - index), 'category': 88},
          )
        : [
            {...fixture.row(1950), 'category': 73},
          ];
    final source = MangaSource(_config, client: fixture.client);
    final result = await source.search('-type:88');
    expect(result.items.map((item) => item.id), [1950]);
    expect(result.hasMore, false);
    expect(fixture.requests.last.url.queryParameters['next-id'], '1951');
    fixture.searchRows = (_) => [
      {...fixture.row(1900), 'category': 88},
    ];
    final empty = await source.search('-type:88 artist:other');
    expect(empty.items, isEmpty);
    expect(empty.hasMore, false);
    source.close();
  });

  test(
    'document type filtering requires server category IDs instead of guessing',
    () async {
      final fixture = _DocumentFixture()..category = null;
      final source = MangaSource(_config, client: fixture.client);
      final unfiltered = await source.search('');
      expect(unfiltered.items, isNotEmpty);
      expect(
        unfiltered.items.first.tags.where((tag) => tag.startsWith('type:')),
        isEmpty,
      );
      await expectLater(
        source.search('type:73'),
        throwsA(
          isA<ContentException>().having(
            (error) => error.message,
            'message',
            'This website does not provide category IDs for type filters.',
          ),
        ),
      );
      source.close();
    },
  );

  test('document popularity periods have independent cached feeds', () async {
    final fixture = _DocumentFixture();
    final source = MangaSource(_config, client: fixture.client);
    await source.search('artist:sample_artist', popular: true, period: 'today');
    await source.search('artist:sample_artist', popular: true, period: 'month');
    final requests = fixture.requests
        .where((request) => request.url.path == '/ajax/search')
        .toList();
    expect(requests.length, 2);
    final dates = requests
        .map(
          (request) =>
              DateTime.parse(request.url.queryParameters['start-date']!),
        )
        .toList();
    expect(dates.first.difference(dates.last).inDays, 29);
    source.close();
  });

  test(
    'legacy language-exception preferences preserve strict indexed filtering',
    () async {
      final fixture = _IndexedFixture();
      final store = LibraryStore.memory();
      store.saveSource(_config);
      store.setSetting('allowsLanguageExceptions.manga', true);
      final controller = AppController(
        store,
        sourceFactory: (config) => MangaSource(config, client: fixture.client),
      );
      try {
        final result = await controller.searchSource(
          _config,
          'language:korean -female:exclude',
        );
        expect(result.items.map((item) => item.id), [2000]);
        expect(
          fixture.requests.where(
            (request) => request.url.path.startsWith('/type/'),
          ),
          isEmpty,
        );
        expect(store.setting('allowsLanguageExceptions.manga'), true);
      } finally {
        controller.dispose();
        store.close();
      }
    },
  );

  test('document language filters are sent unchanged without category exception lanes', () async {
    final fixture = _DocumentFixture();
    final source = MangaSource(_config, client: fixture.client);
    await source.search('language:korean artist:sample_artist -tag:spoilers');
    final requests = fixture.requests
        .where((request) => request.url.path == '/ajax/search')
        .toList();
    expect(requests, hasLength(1));
    expect(
      requests.single.url.queryParameters['search'],
      contains('language:korean'),
    );
    expect(
      requests.single.url.queryParameters.containsKey('categories'),
      false,
    );
    source.close();
  });

  test(
    'discovers custom common.js once, paginates ranges and preserves metadata',
    () async {
      final fixture = _IndexedFixture();
      final source = MangaSource(_config, client: fixture.client);
      final first = await source.search('');
      final second = await source.search('', page: 2);
      expect(first.items.length, 20);
      expect(first.hasMore, isTrue);
      expect(second.items.map((item) => item.id), [
        1980,
        1979,
        1978,
        1977,
        1976,
      ]);
      expect(second.hasMore, isFalse);
      expect(fixture.homepageLoads, 1);
      final item = first.items.first;
      expect(
        item.pageUrl.toString(),
        'https://comics.example/galleries/2000.html',
      );
      expect(item.thumbnailUrl!.host, 'btn.storage.example');
      expect(item.title, '日本語 & A');
      expect(
        item.tags,
        containsAll(['female:sample', 'male:sample', 'language:korean']),
      );
      expect((item.metadata['gallery'] as Map)['published'], '2026-10-01');
      final pages = await source.pages(ContentItem.fromJson(item.toJson()));
      expect(pages.single.previewUrl, item.thumbnailUrl);
      expect(
        pages.single.url.toString(),
        'https://w2.storage.example/123/2730/$_hash.webp',
      );
      expect(pages.single.headers['Referer'], item.pageUrl.toString());
      expect(
        fixture.requests.any(
          (request) => request.url.host == 'ltn.comics.example',
        ),
        isFalse,
      );
      expect(
        fixture.requests
            .where((request) => request.url.path == '/gg.js')
            .length,
        1,
      );
      source.close();
    },
  );

  test(
    'keyword B-tree lookup intersects namespaced and excluded indexes',
    () async {
      final fixture = _IndexedFixture();
      final source = MangaSource(_config, client: fixture.client);
      final result = await source.search(
        'sample artist:sample_artist -female:exclude',
      );
      expect(result.items.map((item) => item.id), [2000]);
      expect(result.hasMore, isFalse);
      expect(
        fixture.requests.any((request) => request.url.path.endsWith('.index')),
        isTrue,
      );
      source.close();
    },
  );

  test(
    'indexed suggestions use configured host and per-character paths',
    () async {
      final fixture = _IndexedFixture();
      final source = MangaSource(_config, client: fixture.client);
      expect(await source.suggestions('previous -artist:sa'), [
        'artist:sample_artist',
      ]);
      final request = fixture.requests.last;
      expect(request.url.host, 'tagindex.comics.example');
      expect(request.url.path, '/artist/s/a.json');
      expect(await source.suggestions('artist:1'), isEmpty);
      source.close();
    },
  );

  test(
    'range mismatch and executable script suffixes fail without evaluation',
    () async {
      final rangeFixture = _IndexedFixture()..malformedRange = true;
      final rangeSource = MangaSource(_config, client: rangeFixture.client);
      await expectLater(
        rangeSource.search(''),
        throwsA(isA<ContentException>()),
      );
      rangeSource.close();
      final routingFixture = _IndexedFixture()..executableRouting = true;
      final routingSource = MangaSource(_config, client: routingFixture.client);
      await expectLater(
        routingSource.detail(2000),
        throwsA(isA<ContentException>()),
      );
      routingSource.close();
      final galleryFixture = _IndexedFixture()..executableGallery = true;
      final gallerySource = MangaSource(_config, client: galleryFixture.client);
      await expectLater(
        gallerySource.detail(2000),
        throwsA(isA<ContentException>()),
      );
      gallerySource.close();
    },
  );

  test('backend connection failure refreshes discovery once and preserves frontend', () async {
    final fixture = _IndexedFixture();
    final source = MangaSource(_config, client: fixture.client);
    await source.detail(2000);
    fixture.moved = true;
    final item = await source.detail(1999);
    expect(item.pageUrl!.host, 'comics.example');
    expect(item.thumbnailUrl!.host, 'btn.new-storage.example');
    expect(fixture.homepageLoads, 2);
    source.close();
  });

  test(
    'document catalog keeps cursor order, previews and remote tag mapping',
    () async {
      final fixture = _DocumentFixture();
      final source = MangaSource(_config, client: fixture.client);
      final first = await source.search('series:sample_series type:2');
      expect(first.items.length, 20);
      expect(
        first.items.first.thumbnailUrl.toString(),
        'https://preview.example/0/2/0.jpg',
      );
      expect(
        first.items.first.tags,
        containsAll(['series:sample_series', 'tag:sample_tag']),
      );
      expect(
        first.items.first.pageUrl.toString(),
        'https://comics.example/r/2000',
      );
      final initial = fixture.requests.last.url;
      expect(initial.queryParameters['search'], 'parody:sample_series');
      expect(initial.queryParameters['categories'], '2');
      final third = await source.search('series:sample_series type:2', page: 3);
      expect(
        third.items.map((item) => item.id),
        List.generate(12, (index) => 1960 - index),
      );
      expect(third.hasMore, isFalse);
      expect(fixture.requests.last.url.queryParameters['next-id'], '1951');
      expect(
        fixture.requests
            .where((request) => request.url.path == '/ajax/search')
            .length,
        2,
      );
      expect(await source.suggestions('series:sa'), ['series:sample_series']);
      expect(fixture.requests.last.url.queryParameters['search'], 'parody:sa');
      source.close();
    },
  );

  test('document manifests parse braces and quotes, retain fields and refresh expired URLs', () async {
    final fixture = _DocumentFixture()..expired = true;
    final source = MangaSource(_config, client: fixture.client);
    final item = await source.detail(2000);
    expect(item.title, 'Brace } and escaped " quote');
    expect(
      (item.metadata['gallery'] as Map)['unknownFutureField'],
      'preserved',
    );
    final pages = await source.pages(ContentItem.fromJson(item.toJson()));
    expect(pages.single.previewUrl.toString(), 'https://media.example/1.jpg');
    expect(fixture.detailLoads, 2);
    expect(pages.single.url.queryParameters['expires'], '4102444800');
    expect(pages.single.width, 100);
    expect(pages.single.headers['Referer'], 'https://comics.example/r/2000');
    expect(
      fixture.requests.any((request) => request.url.host == 'media.example'),
      isFalse,
    );
    source.close();
  });

  test(
    'rejects unsafe manifest media and stops requests after close',
    () async {
      final fixture = _DocumentFixture()..unsafe = true;
      final source = MangaSource(_config, client: fixture.client);
      await expectLater(source.detail(2000), throwsA(isA<ContentException>()));
      source.close();
      final count = fixture.requests.length;
      await expectLater(source.search(''), throwsA(isA<ContentException>()));
      expect(fixture.requests.length, count);
    },
  );

  test('reports HTTP errors and rejects foreign discovery scripts', () async {
    final requests = <Uri>[];
    final source = MangaSource(
      _config,
      client: MockClient((request) async {
        requests.add(request.url);
        if (request.url.path == '/') {
          return http.Response(
            '<script src="https://foreign.example/common.js"></script>',
            200,
          );
        }
        return http.Response('', 403);
      }),
    );
    await expectLater(
      source.search(''),
      throwsA(
        isA<ContentException>().having(
          (error) => error.statusCode,
          'status',
          403,
        ),
      ),
    );
    expect(requests.every((url) => url.host == 'comics.example'), isTrue);
    source.close();
  });
}
