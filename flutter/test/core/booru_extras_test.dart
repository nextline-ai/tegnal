import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_extras.dart';

void main() {
  SourceConfig config(SourceKind kind) => SourceConfig(
    id: 'fixture',
    name: 'Fixture',
    baseUrl: Uri.parse('https://source.invalid/gallery'),
    kind: kind,
  );
  Map<String, dynamic> note(int id) => {
    'id': id,
    'x': '10.5',
    'y': 20,
    'width': 100,
    'height': '50',
    'body': 'Hello &amp; <b>world</b><br>Next<script>ignore()</script>',
    'is_active': true,
  };

  test(
    'Danbooru pool search uses projected paginated wildcard query',
    () async {
      late Uri requested;
      final extras = BooruExtras(
        config(SourceKind.danbooru),
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(
              List.generate(
                20,
                (index) => {
                  'id': index + 1,
                  'name': 'pool_$index',
                  'post_count': '8',
                  'description': '<b>Description</b>',
                },
              ),
            ),
            200,
          );
        }),
      );
      final page = await extras.pools(' blue ', page: 2);
      expect(requested.path, '/gallery/pools.json');
      expect(requested.queryParameters, {
        'page': '2',
        'limit': '20',
        'search[name_matches]': '*blue*',
        'only': 'id,name,post_count,description',
      });
      expect(page.hasMore, isTrue);
      expect(page.pools.first.postCount, 8);
      expect(page.pools.first.description, 'Description');
    },
  );

  test(
    'Danbooru authored pool sequence uses ordpool instead of default ordering',
    () async {
      late Uri requested;
      final extras = BooruExtras(
        config(SourceKind.danbooru),
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            '[{"id":8,"file_url":"/8.jpg"},{"id":2,"file_url":"/2.jpg"}]',
            200,
          );
        }),
      );
      final page = await extras.poolPosts(7, page: 3);
      expect(requested.path, '/gallery/posts.json');
      expect(requested.queryParameters['tags'], 'ordpool:7');
      expect(requested.queryParameters['page'], '3');
      expect(page.items.map((post) => post.id), [8, 2]);
      expect(page.hasMore, isFalse);
    },
  );

  test(
    'Moebooru pools, posts and notes use their own JSON endpoints',
    () async {
      final requested = <Uri>[];
      final extras = BooruExtras(
        config(SourceKind.moebooru),
        client: MockClient((request) async {
          requested.add(request.url);
          return switch (request.url.path.split('/').last) {
            'pool.json' => http.Response('[{"id":3,"name":"blue"}]', 200),
            'post.json' => http.Response('[]', 200),
            _ => http.Response(jsonEncode([note(1)]), 200),
          };
        }),
      );
      final page = await extras.pools('blue');
      expect(requested.last.queryParameters['query'], 'blue');
      expect(page.pools.single.postCount, isNull);
      expect(page.hasMore, isFalse);
      await extras.poolPosts(3);
      expect(requested.last.queryParameters['tags'], 'pool:3');
      final notes = await extras.notes(19);
      expect(requested.last.path, '/gallery/note.json');
      expect(requested.last.queryParameters, {'post_id': '19'});
      expect(notes.single.x, 10.5);
      expect(notes.single.body, 'Hello & world\nNext');
    },
  );

  test(
    'Danbooru notes fetch every page and filter inactive or invalid geometry',
    () async {
      final requested = <Uri>[];
      final extras = BooruExtras(
        config(SourceKind.danbooru),
        client: MockClient((request) async {
          requested.add(request.url);
          final rows = request.url.queryParameters['page'] == '1'
              ? List.generate(200, (i) => note(i + 1))
              : [
                  {...note(201), 'is_active': false},
                  {...note(202), 'width': 0},
                  note(203),
                ];
          return http.Response(jsonEncode(rows), 200);
        }),
      );
      final notes = await extras.notes(6);
      expect(requested.length, 2);
      expect(requested.first.queryParameters, {
        'search[post_id]': '6',
        'search[is_active]': 'true',
        'limit': '200',
        'page': '1',
      });
      expect(requested.last.queryParameters['page'], '2');
      expect(notes.length, 201);
      expect(notes.last.id, 203);
    },
  );

  test(
    'nonadvancing notes pages fail instead of looping or silently truncating',
    () async {
      var requests = 0;
      final extras = BooruExtras(
        config(SourceKind.danbooru),
        client: MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode(List.generate(200, (i) => note(i + 1))),
            200,
          );
        }),
      );
      await expectLater(
        extras.notes(3),
        throwsA(
          isA<ContentException>().having(
            (e) => e.message,
            'message',
            contains('advance'),
          ),
        ),
      );
      expect(requests, 2);
    },
  );

  test(
    'unsupported Gelbooru extras report unsupported without requests',
    () async {
      for (final kind in [SourceKind.gelbooru, SourceKind.oldGelbooru]) {
        final extras = BooruExtras(
          config(kind),
          client: MockClient(
            (_) async => throw StateError('Unexpected network'),
          ),
        );
        expect(extras.supported, isFalse);
        await expectLater(extras.pools(''), throwsA(isA<ContentException>()));
        await expectLater(extras.notes(1), throwsA(isA<ContentException>()));
        await expectLater(
          extras.poolPosts(1),
          throwsA(isA<ContentException>()),
        );
      }
    },
  );

  test(
    'HTTP failures and malformed responses do not appear as empty extras',
    () async {
      for (final status in [401, 403, 429, 500]) {
        final extras = BooruExtras(
          config(SourceKind.danbooru),
          client: MockClient((_) async => http.Response('failure', status)),
        );
        await expectLater(
          extras.pools(''),
          throwsA(
            isA<ContentException>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
      }
      for (final body in [
        'not JSON',
        '{"error":"unsupported"}',
        '<html>Verify</html>',
      ]) {
        final extras = BooruExtras(
          config(SourceKind.danbooru),
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(extras.pools(''), throwsA(isA<ContentException>()));
      }
    },
  );
}
