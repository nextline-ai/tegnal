import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_source.dart';

void main() {
  SourceConfig config(SourceKind kind, {String path = ''}) => SourceConfig(
    id: 'fixture',
    name: 'Fixture',
    baseUrl: Uri.parse('https://booru.invalid$path'),
    kind: kind,
  );
  Map<String, dynamic> row(int id) => {
    'id': id,
    'file_url': '/images/$id.png',
    'tags': 'blue sky',
  };

  test(
    'Danbooru uses 1-based pages, score sorting and native backup metadata',
    () async {
      late Uri requested;
      final source = BooruSource(
        config(SourceKind.danbooru, path: '/gallery'),
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(
              List.generate(
                40,
                (index) => {
                  ...row(index + 1),
                  'tag_string': 'blue sky author',
                  'tag_string_artist': 'author',
                  'tag_string_meta': 'highres',
                  'tag_string_character': 'hero',
                  'image_width': 1600,
                  'image_height': 900,
                  'rating': 's',
                  'score': 7,
                  'fav_count': 4,
                  'pool_ids': [12],
                  'media_asset': {
                    'variants': [
                      {'type': 'full', 'url': '//cdn.invalid/full.jpg'},
                    ],
                  },
                },
              ),
            ),
            200,
          );
        }),
      );
      final result = await source.search(
        'blue order:id sort:random',
        page: 2,
        popular: true,
      );
      expect(requested.path, '/gallery/posts.json');
      expect(requested.queryParameters, {
        'tags': 'blue order:score',
        'limit': '40',
        'page': '2',
      });
      expect(result.hasMore, isTrue);
      final post = result.items.first;
      expect(post.mediaUrl.toString(), 'https://cdn.invalid/full.jpg');
      expect(post.artists, ['author']);
      expect(post.metadata['rating'], 's');
      expect(post.metadata['poolIDs'], [12]);
      expect(post.metadata['tagCategories'], {
        'author': 1,
        'hero': 4,
        'highres': 5,
      });
      expect(post.metadata['favoriteCount'], 4);
      expect(post.metadata['fileURL'], 'https://booru.invalid/images/1.png');
      expect(
        ContentItem.fromJson(jsonDecode(jsonEncode(post.toJson()))).metadata,
        post.metadata,
      );
    },
  );

  test('Gelbooru uses 0-based API pages and parses XML attributes', () async {
    late Uri requested;
    final source = BooruSource(
      config(SourceKind.gelbooru),
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          '''<?xml version="1.0"?><posts count="1"><post id="9" file_url="//cdn.invalid/a.webm" preview_url="/thumb.jpg" width="1200" height="800" tags="a &amp; b" rating="s" score="-2" /></posts>''',
          200,
        );
      }),
    );
    final result = await source.search('a', page: 3, popular: true);
    expect(requested.queryParameters['pid'], '2');
    expect(requested.queryParameters['tags'], 'a sort:score:desc');
    expect(result.hasMore, isFalse);
    final post = result.items.single;
    expect(post.tags, ['a', '&', 'b']);
    expect(post.score, -2);
    expect(post.width, 1200);
    expect(post.mediaType, 'video');
    expect(post.metadata['rating'], 'g');
    expect(
      (await source.pages(post)).single.url.toString(),
      'https://cdn.invalid/a.webm',
    );
  });

  test('Moebooru detail and suggestions use dialect endpoints', () async {
    final requested = <Uri>[];
    final source = BooruSource(
      config(SourceKind.moebooru),
      client: MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/tag.json') {
          return http.Response('[{"name":"blue_sky"}]', 200);
        }
        return http.Response(
          jsonEncode([
            {
              ...row(5),
              'file_url': '/animation.gif',
              'sample_url': '/sample.jpg',
              'rating': 's',
            },
          ]),
          200,
        );
      }),
    );
    final post = await source.detail(5);
    expect(requested.first.path, '/post.json');
    expect(requested.first.queryParameters['tags'], 'id:5');
    expect(post.mediaType, 'animation');
    expect(post.mediaUrl?.path, '/animation.gif');
    expect(post.metadata['rating'], 'g');
    expect(await source.suggestions('sky -blu'), ['blue_sky']);
    expect(requested.last.queryParameters['name'], 'blu*');
    expect(await source.suggestions('rating:s'), isEmpty);
    expect(await source.suggestions('blue\t'), isEmpty);
    expect(requested.length, 2);
  });

  test(
    'Danbooru direct detail objects and XML child fields are accepted',
    () async {
      final source = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((request) async {
          if (request.url.path == '/posts/2.json') {
            return http.Response(jsonEncode(row(2)), 200);
          }
          return http.Response(
            '<tags><tag><name>blue_sky</name><post-count>7</post-count></tag></tags>',
            200,
          );
        }),
      );
      expect((await source.detail(2)).id, 2);
      expect(await source.suggestions('blu'), ['blue_sky']);
    },
  );

  test(
    'legacy galleries follow actual offsets and resolve preview-only detail',
    () async {
      final requested = <Uri>[];
      final source = BooruSource(
        config(SourceKind.oldGelbooru, path: '/index.php'),
        client: MockClient((request) async {
          requested.add(request.url);
          if (request.url.queryParameters['s'] == 'view') {
            return http.Response('''<html><body><img id="image" src="http://cdn.invalid/sample.jpg" width="640" height="480">
          <a href="http://cdn.invalid/full.png">Original image</a><textarea name="tags">blue author</textarea>
          <ul><li class="tag-type-artist"><a href="?page=post&amp;s=list&amp;tags=author">author</a></li></ul>
          Size: 1200 x 900 Rating: Safe Score: -4</body></html>''', 200);
          }
          return http.Response(
            '''<html><body><a id="p11" href="?page=post&amp;s=view&amp;id=11"><img src="http://cdn.invalid/thumb.jpg" title="blue rating:s score:2"></a>
        <a href="https://evil.invalid/index.php?page=post&amp;s=list&amp;pid=21">Other</a>
        <a href="?page=post&amp;s=list&amp;pid=24&amp;tags=blue">Next</a></body></html>''',
            200,
          );
        }),
      );
      final result = await source.search('blue');
      expect(requested.first.path, '/index.php');
      expect(result.hasMore, isTrue);
      expect(result.items.single.mediaUrl, isNull);
      expect(
        result.items.single.thumbnailUrl.toString(),
        'https://cdn.invalid/thumb.jpg',
      );
      expect(result.items.single.metadata['rating'], 'g');
      await source.search('blue', page: 2);
      expect(requested.last.queryParameters['pid'], '24');
      final pages = await source.pages(result.items.single);
      expect(pages.single.url.toString(), 'https://cdn.invalid/sample.jpg');
      expect(pages.single.width, 1200);
      final detail = await source.detail(11);
      expect(detail.artists, ['author']);
      expect(detail.metadata['fileURL'], 'https://cdn.invalid/full.png');
      expect(detail.score, -4);
    },
  );

  test(
    'legacy suggestions use sidebar and empty galleries terminate',
    () async {
      final source = BooruSource(
        config(SourceKind.oldGelbooru),
        client: MockClient((request) async {
          if (request.url.queryParameters['tags'] == 'blu*') {
            return http.Response(
              '''<html><body><li><a href="?tags=blue">blue</a></li><li><a href="?tags=green">green</a></li></body></html>''',
              200,
            );
          }
          return http.Response(
            '<html><body>Nobody here but us chickens!</body></html>',
            200,
          );
        }),
      );
      expect(await source.suggestions('blu'), ['blue']);
      final empty = await source.search('missing');
      expect(empty.items, isEmpty);
      expect(empty.hasMore, isFalse);
    },
  );

  test('Gelbooru 401 falls back to public gallery', () async {
    final source = BooruSource(
      config(SourceKind.gelbooru),
      client: MockClient((request) async {
        if (request.url.queryParameters['page'] == 'dapi') {
          return http.Response('API key required', 401);
        }
        return http.Response('<html><body>No posts found</body></html>', 200);
      }),
    );
    expect((await source.search('absent')).items, isEmpty);
  });

  test(
    'HTTP statuses, network failures and browser challenges surface errors',
    () async {
      for (final status in [401, 403, 404, 429, 500]) {
        final source = BooruSource(
          config(SourceKind.danbooru),
          client: MockClient((_) async => http.Response('error', status)),
        );
        await expectLater(
          source.search('a'),
          throwsA(
            isA<ContentException>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
      }
      final challenge = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient(
          (_) async => http.Response('<html>Just a moment cf-chl-</html>', 200),
        ),
      );
      await expectLater(
        challenge.search('a'),
        throwsA(
          isA<ContentException>().having(
            (e) => e.message,
            'message',
            contains('verification'),
          ),
        ),
      );
      final validJson = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              {...row(123), 'tag_string': 'just a moment'},
            ]),
            200,
          ),
        ),
      );
      expect((await validJson.search('a')).items.single.id, 123);
      final offline = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(offline.search('a'), throwsA(isA<ContentException>()));
      offline.close();
      await expectLater(
        offline.search('a'),
        throwsA(
          isA<ContentException>().having(
            (e) => e.message,
            'message',
            contains('closed'),
          ),
        ),
      );
    },
  );

  test('invalid payloads and insecure media fail explicitly', () async {
    for (final body in [
      'not json',
      '{"success":false}',
      '<html>Login</html>',
      '[{"id":0}]',
    ]) {
      final source = BooruSource(
        config(SourceKind.danbooru),
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(source.search('a'), throwsA(isA<ContentException>()));
    }
    final source = BooruSource(
      config(SourceKind.danbooru),
      client: MockClient(
        (_) async => http.Response(
          '[{"id":1,"file_url":"http://cdn.invalid/a.png","preview_file_url":"https://user:pass@cdn.invalid/a.png"}]',
          200,
        ),
      ),
    );
    final item = (await source.search('a')).items.single;
    expect(item.mediaUrl, isNull);
    expect(item.thumbnailUrl, isNull);
    await expectLater(source.pages(item), throwsA(isA<ContentException>()));
    await expectLater(source.search('a', page: 0), throwsArgumentError);
  });

  test('cross-origin redirects are rejected', () async {
    final source = BooruSource(
      config(SourceKind.danbooru),
      client: MockClient(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': 'https://evil.invalid/posts.json'},
        ),
      ),
    );
    await expectLater(
      source.search('a'),
      throwsA(
        isA<ContentException>().having((e) => e.statusCode, 'status', 302),
      ),
    );
  });
}
