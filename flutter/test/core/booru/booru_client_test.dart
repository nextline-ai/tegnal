// Ported from native-ios/TEGNALTests/BooruTests.swift and BooruRevisionTests.swift.
//
// Native tests that name real websites use neutral `.example` servers here. Where the
// native client recognizes one named website (its public gallery, notes on the post page,
// its autocomplete route, its modern ratings), these tests check the same behavior learned
// from the server's responses instead. Live network tests, WebKit transport tests and
// AppEnvironment tests are not ported.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_browser.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_html.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_transport.dart';

import '../content/content_test_support.dart';

final dan = BooruServer(id: 'test-dan', name: 'Test', baseURL: 'https://example.com/booru', engine: BooruEngine.danbooru);
final legacy = BooruServer(id: 'legacy', name: 'Legacy', baseURL: 'https://legacy.example', engine: BooruEngine.oldGelbooru);

BooruServer copy(BooruServer server, {String? id, BooruEngine? engine, String? baseURL}) =>
    BooruServer(id: id ?? server.id, name: server.name, baseURL: baseURL ?? server.baseURL, engine: engine ?? server.engine);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// `mocked { request in (status, body) }`: a client whose network is [handler].
BooruClient mocked(FutureOr<(int, String)> Function(HttpExchange request) handler, {BooruCredentialStore? credentials, BooruBrowserSession? session}) =>
    BooruClient(
      fetcher: FixtureFetcher((request) async {
        final (status, body) = await handler(request);
        return FixtureReply.text(status, body);
      }),
      credentials: credentials ?? MemoryCredentialStore(),
      session: session ?? BooruBrowserSession(),
      poolRequestDelay: Duration.zero,
    );

String? item(HttpExchange request, String name) => request.url.queryParameters[name];

Future<Object?> failure(Future<Object?> Function() operation) async {
  try {
    await operation();
  } catch (error) {
    return error;
  }
  fail('Expected an error');
}

void main() {
  test('danbooru removal flags and post 451 do not misclassify generic failures', () async {
    final flags = BooruDecoder.post({'id': 12466874, 'is_deleted': true, 'is_banned': true}, dan);
    expect(flags.isRemoved, isTrue);
    expect(BooruPost.fromJson(flags.toJson()).isRemoved, isTrue);
    final legacyPost = BooruDecoder.post({'id': 101}, dan);
    expect(legacyPost.isRemoved, isFalse);
    expect(BooruPostAccessError.detectRow({'id': 12466874, 'is_deleted': true}, dan), BooruPostAccessError.removed);
    expect(BooruPostAccessError.detect(bytes("<meta name='post-is-banned' content='true'>"), dan), BooruPostAccessError.removed);
    expect(BooruPostAccessError.detectRow({'file_url': null, 'is_deleted': false, 'is_banned': false}, dan), isNull);
    final removed = mocked((request) {
      expect(request.url.path.endsWith('posts/12466874.json'), isTrue);
      return (200, '{"id":12466874,"is_deleted":true}');
    });
    final saved = BooruDecoder.post({'id': 12466874, 'file_url': 'https://cdn.example.com/old.jpg'}, dan);
    expect(await failure(() => removed.details(dan, saved)), BooruPostAccessError.removed, reason: 'Refresh stale saved media metadata');
    final takedown = mocked((_) => (451, 'This page has been removed because of a takedown request'));
    expect(await failure(() => takedown.details(dan, legacyPost)), BooruPostAccessError.removed);
    expect(
      await failure(() => takedown.posts(dan, '', 0)),
      isNot(isA<BooruPostAccessError>()),
      reason: 'A feed-wide HTTP error must not silently remove a post',
    );
    final forbidden = mocked((_) => (403, 'Forbidden'));
    expect(await failure(() => forbidden.details(dan, legacyPost)), isNot(isA<BooruPostAccessError>()));
  });

  test('cookie scope and profile isolation', () {
    const cookie = BooruCookie(name: 'clearance', value: 'fixture', domain: '.example.com', path: '/api', isSecure: true);
    expect(BooruBrowserSession.matches(cookie, Uri.parse('https://sub.example.com/api/posts')), isTrue);
    expect(BooruBrowserSession.matches(cookie, Uri.parse('https://example.com/apiculture')), isFalse);
    expect(BooruBrowserSession.matches(cookie, Uri.parse('https://notexample.com/api')), isFalse);
    expect(BooruBrowserSession.matches(cookie, Uri.parse('http://example.com/api')), isFalse);
    expect(BooruBrowserSession.matches(cookie, Uri.parse('https://example.com.evil.test/api')), isFalse);
    expect(BooruBrowserSession.identifier('alpha'), BooruBrowserSession.identifier('alpha'));
    expect(BooruBrowserSession.identifier('alpha'), isNot(BooruBrowserSession.identifier('beta')));
  });

  test('validation cookies reach only their server and reset', () async {
    final session = BooruBrowserSession();
    final a = BooruServer(name: 'A', baseURL: 'https://example.com', engine: BooruEngine.danbooru);
    final b = BooruServer(name: 'B', baseURL: a.baseURL, engine: BooruEngine.danbooru);
    session.setCookie(const BooruCookie(name: 'clearance', value: 'fixture', domain: 'example.com', isSecure: true), a);
    final authorized = BooruRequest(Uri.parse('${a.baseURL}/posts.json'));
    final isolated = BooruRequest(Uri.parse('${a.baseURL}/posts.json'));
    session
      ..userAgent = 'Fixture Agent'
      ..prepare(authorized, a)
      ..prepare(isolated, b);
    expect(authorized.header('Cookie'), 'clearance=fixture');
    expect(isolated.header('Cookie'), isNull);
    expect(authorized.header('User-Agent'), 'Fixture Agent');
    expect(authorized.header('Referer'), 'https://example.com/');
    await session.reset(a);
    final reset = BooruRequest(Uri.parse('${a.baseURL}/posts.json'));
    session.prepare(reset, a);
    expect(reset.header('Cookie'), isNull);
  });

  test('cookies set by responses and the validation browser join only that profile', () async {
    final session = BooruBrowserSession();
    final client = BooruClient(
      fetcher: FixtureFetcher((request) => FixtureReply.text(200, '[]', {'Set-Cookie': 'clearance=token; Path=/; Secure'})),
      credentials: MemoryCredentialStore(),
      session: session,
    );
    await client.posts(dan, '', 0);
    expect(session.cookieHeader(dan, Uri.parse('https://example.com/booru/posts.json')), 'clearance=token');
    final other = copy(dan, id: 'other');
    expect(session.cookies(other), isEmpty);
    session.importCookieHeader('a=1; b=2', 'https://example.com/booru', other);
    expect(session.cookieHeader(other, Uri.parse('https://example.com/x')), 'a=1; b=2');
    session.importCookieHeader('c=3', 'https://elsewhere.example/', other);
    expect(session.cookies(other).map((cookie) => cookie.name), ['a', 'b']);
  });

  test('server validation normalizes and rejects unsafe URLs', () {
    expect(BooruServer.validatedURL(' EXAMPLE.com/booru/ '), 'https://example.com/booru');
    expect(BooruServer.validatedURL('https://example.com/index.php'), 'https://example.com');
    for (final value in [
      'http://example.com',
      'https://me:secret@example.com',
      'file:///private',
      'https://example.com?api_key=secret',
      'https://example.com/#x',
      '',
    ]) {
      expect(() => BooruServer.validatedURL(value), throwsA(isA<BooruError>()), reason: value);
    }
  });

  test('authentication and query encoding stay scoped to server', () {
    const credentials = BooruCredentials(account: 'user+name', apiKey: 'key&?secret');
    final request = BooruClient.request(dan, 'posts.json', [('tags', 'a&b -rating:e')], credentials: credentials);
    expect(request.url.path, '/booru/posts.json');
    expect(request.url.toString().contains('secret'), isFalse);
    expect(request.header('Authorization'), 'Basic ${base64Encode(utf8.encode('user+name:key&?secret'))}');
    expect(request.url.queryParametersAll['tags'], ['a&b -rating:e']);
    final gelbooru = copy(dan, engine: BooruEngine.gelbooru);
    final gel = BooruClient.request(gelbooru, 'index.php', [], credentials: credentials);
    expect(gel.url.queryParameters['user_id'], 'user+name');
    expect(gel.url.queryParameters['api_key'], 'key&?secret');
    expect(gel.header('Authorization'), isNull);
    expect(gelbooru.pageURL(101).contains('secret'), isFalse);
  });

  test('danbooru and legacy media decode', () {
    final row = <String, Object?>{
      'id': 101,
      'tag_string': 'scenery sample_artist',
      'tag_string_artist': 'sample_artist',
      'image_width': 12000,
      'image_height': 9000,
      'file_url': '//cdn.example.com/movie.webm',
      'preview_file_url': '/preview.jpg',
      'large_file_url': 'https://cdn.example.com/sample.jpg',
      'file_ext': 'webm',
      'pool_ids': [77, 78],
      'score': 42,
      'rating': 's',
    };
    final post = BooruDecoder.post(row, dan);
    expect(post.isVideo, isTrue);
    expect(post.width, 12000);
    expect(post.artists, ['sample_artist']);
    expect(post.poolIDs, [77, 78]);
    expect(post.rating, 's');
    expect(post.fileURL, 'https://cdn.example.com/movie.webm');
    expect(post.previewURL, 'https://example.com/preview.jpg');
    final gel = copy(dan, engine: BooruEngine.gelbooru);
    final old = BooruDecoder.post({'id': '102', 'file_url': 'https://cdn.example.com/a.gif', 'tags': 'animated scenery', 'score': null, 'rating': 's'}, gel);
    expect(old.isAnimated, isTrue);
    expect(old.score, 0);
    expect(old.rating, 'g');
    expect(BooruDecoder.safeURL('javascript:alert(1)', dan.baseURL), isNull);
    expect(BooruDecoder.safeURL('https://user:password@example.com/a', dan.baseURL), isNull);
    expect(BooruDecoder.post({'id': 111}, dan).displayURL, isNull);
  });

  test('reduced data media preserves original and animation and decodes category metadata', () {
    final post = BooruDecoder.post({
      'id': 42,
      'file_url': 'https://cdn.example/original.png',
      'file_ext': 'png',
      'large_file_url': 'https://cdn.example/sample.jpg',
      'tag_string': 'sky author series hero',
      'tag_string_artist': 'author',
      'tag_string_copyright': 'series',
      'tag_string_character': 'hero',
      'media_asset': {
        'variants': [
          {'type': '720x720', 'url': 'https://cdn.example/small.webp'},
          {'type': 'sample', 'url': 'https://cdn.example/viewing.jpg'},
        ],
      },
    }, dan);
    expect(post.viewerURL(original: false, reducedData: true), endsWith('small.webp'));
    expect(post.viewerURL(original: false), endsWith('viewing.jpg'));
    expect(post.viewerURL(original: true, reducedData: true), endsWith('original.png'));
    expect(post.tagCategories, {'author': 1, 'series': 3, 'hero': 4});
    final animated = post.copy()..fileExtension = 'gif';
    expect(animated.viewerURL(original: false, reducedData: true), post.fileURL);
    final staticWebP = BooruDecoder.post({
      'id': 43,
      'file_ext': 'webp',
      'file_url': 'https://cdn.example/original.webp',
      'media_asset': {
        'variants': [
          {'type': 'full', 'url': 'https://cdn.example/full.jpg'},
        ],
      },
    }, dan);
    expect(staticWebP.isAnimated, isFalse);
    expect(staticWebP.viewerURL(original: false), endsWith('full.jpg'));
    expect(staticWebP.viewerURL(original: true), endsWith('original.webp'));
    final fallback = post.copy()..reducedDataURL = null;
    expect(fallback.viewerURL(original: false, reducedData: true), post.sampleURL);
    fallback.sampleURL = null;
    expect(fallback.viewerURL(original: false, reducedData: true), post.fileURL);
  });

  test('ugoira uses converted video and refreshes older saved ZIP posts', () async {
    final row = <String, Object?>{
      'id': 101,
      'file_ext': 'zip',
      'tag_string': 'ugoira animated',
      'file_url': 'https://cdn.example.com/original.zip',
      'jpeg_url': 'https://cdn.example.com/still.jpg',
      'media_asset': {
        'variants': [
          {'type': '720x720', 'url': 'https://cdn.example.com/thumb.webp', 'file_ext': 'webp'},
          {'type': 'sample', 'url': 'https://cdn.example.com/converted', 'file_ext': 'webm'},
        ],
      },
    };
    final post = BooruDecoder.post(row, dan);
    expect(post.isVideo, isTrue);
    expect(post.isAnimated, isTrue);
    for (final original in [false, true]) {
      expect(post.viewerURL(original: original, reducedData: true), endsWith('converted'));
    }
    expect(urlPathExtension(post.fileURL), 'zip', reason: 'Downloading the original must still retain the archive');
    expect(BooruPost.fromJson(post.toJson()).animationVideoURL, post.animationVideoURL);
    final legacyRow = {...row}
      ..remove('media_asset')
      ..['large_file_url'] = 'https://cdn.example.com/legacy.webm';
    expect(BooruDecoder.post(legacyRow, dan).viewerURL(original: true), endsWith('legacy.webm'));
    final older = post.copy()..animationVideoURL = null;
    expect(older.viewerURL(original: true), isNull, reason: 'Never hand a ZIP or a still preview to the animation renderer');
    final saved = BooruPost.fromJson(older.toJson()..remove('animationVideoURL'));
    final client = mocked((request) {
      expect(request.url.path, '/booru/posts/101.json');
      return (200, jsonEncode(row));
    });
    final resolved = await client.details(dan, saved);
    expect(resolved.viewerURL(original: false), post.animationVideoURL);
  });

  test('autocomplete uses each engine tag service and canonical values', () async {
    final sites = [
      (dan, 'danbooru'),
      (BooruServer(id: 'gallery', name: 'Gallery', baseURL: 'https://gallery.example', engine: BooruEngine.gelbooru), 'gallery'),
      (BooruServer(id: 'routed', name: 'Routed', baseURL: 'https://routed.example', engine: BooruEngine.gelbooru), 'routed'),
      (BooruServer(id: 'old', name: 'Old', baseURL: 'https://old.example', engine: BooruEngine.oldGelbooru), 'old'),
      (BooruServer(id: 'moe', name: 'Moe', baseURL: 'https://moe.example', engine: BooruEngine.moebooru), 'moebooru'),
    ];
    const rows = '[{"label":"hatsune miku (1,234)","value":"hatsune_miku"},{"label":"miku day (100)","value":"miku_day"}]';
    for (final (server, kind) in sites) {
      final client = mocked((request) {
        switch (kind) {
          case 'danbooru':
            expect(request.url.path, '/booru/autocomplete.json');
            expect(item(request, 'search[type]'), 'tag_query');
            expect(item(request, 'search[query]'), 'miku');
            return (
              200,
              '[{"type":"tag-word","value":"hatsune_miku","label":"Miku","category":4,"post_count":1234},{"type":"tag","value":"highres","category":5,"post_count":100}]',
            );
          case 'moebooru':
            expect(request.url.path, '/tag/autocomplete_name.json');
            expect(item(request, 'term'), 'miku');
            return (200, '["hatsune_miku","miku_day"]');
          case 'routed':
            // A gallery without the classic route answers on the index page's route.
            if (request.url.path == '/autocomplete.php') return (404, 'Not found');
            expect(item(request, 'page'), 'autocomplete2');
            expect(item(request, 'term'), 'miku');
            expect(item(request, 'api_key'), isNull);
            return (200, rows);
          default:
            expect(request.url.path, '/autocomplete.php');
            expect(item(request, 'q'), 'miku');
            return (200, rows);
        }
      });
      final tags = await client.suggestions(server, 'miku');
      expect(tags.length, 2, reason: kind);
      expect(tags.first.name, 'hatsune_miku', reason: 'A canonical or alias match need not start with the typed prefix');
      if (kind != 'moebooru') expect(tags.first.count, 1234);
      if (kind == 'danbooru') expect(tags[1].isMetadata, isTrue);
    }
  });

  test('autocomplete falls back to tag indexes without hiding service errors', () async {
    for (final engine in BooruEngine.values) {
      final server = BooruServer(id: engine.rawValue, name: 'Test', baseURL: 'https://tags.example', engine: engine);
      var primaryRequests = 0;
      final client = mocked((request) {
        final query = request.url.queryParameters;
        if (request.url.path.contains('autocomplete') || query['page'] == 'autocomplete2') {
          primaryRequests += 1;
          return (404, '{}');
        }
        final pattern = switch (engine) {
          BooruEngine.danbooru => query['search[name_matches]'] ?? '',
          BooruEngine.moebooru => query['name'] ?? '',
          BooruEngine.gelbooru => query['name_pattern'] ?? '',
          BooruEngine.oldGelbooru => query['tags'] ?? '',
        };
        if (engine == BooruEngine.oldGelbooru) expect(query['page'], 'tags');
        expect(pattern.startsWith(engine == BooruEngine.gelbooru ? '%' : '*'), isTrue);
        expect(pattern.endsWith(engine == BooruEngine.gelbooru ? '%' : '*'), isTrue);
        final name = pattern.contains('sky') ? 'blue_sky' : 'hatsune_miku';
        if (engine == BooruEngine.oldGelbooru) {
          return (200, "<html><table><tr><td><a href='index.php?page=post&amp;s=list&amp;tags=$name'>$name</a></td><td>1234</td></tr></table></html>");
        }
        return (200, '[{"name":"$name","count":1234}]');
      });
      final first = await client.suggestions(server, 'miku');
      final second = await client.suggestions(server, 'sky');
      expect(first.first.name, 'hatsune_miku');
      expect(second.first.name, 'blue_sky');
      // Gallery engines try both of their routes once.
      expect(primaryRequests, engine.usesGelbooruPages ? 2 : 1, reason: 'Do not re-probe a missing endpoint on every keystroke');
    }
    for (final status in [401, 403, 429, 500]) {
      var requests = 0;
      final client = mocked((_) {
        requests += 1;
        return (status, '{}');
      });
      expect(await failure(() => client.suggestions(dan, 'miku')), isA<BooruError>(), reason: 'Service failure must not become an empty tag list');
      expect(requests, 1);
    }
  });

  test('autocomplete merge preserves ranking and partial failures', () async {
    final servers = [
      for (final name in ['slow', 'fast', 'blocked']) BooruServer(id: name, name: name, baseURL: 'https://$name.example', engine: BooruEngine.danbooru),
    ];
    final result = await BooruTagSuggestionSearch.load(servers: servers, source: _AutocompleteSource(), token: 'miku');
    expect(result.tags.map((tag) => tag.name), ['hatsune_miku', 'cloud', 'very_popular']);
    expect(result.responses.map((response) => response.server.id), ['slow', 'fast', 'blocked']);
    expect(result.error?.contains('blocked'), isTrue);
    expect(result.responses.where((response) => response.error != null).length, 1);
  });

  test('JSON envelopes, XML and empty responses', () {
    expect(BooruDecoder.rows(bytes('{"@attributes":{"count":1},"post":[{"id":"9"}]}'), 'post').length, 1);
    expect(BooruDecoder.rows(bytes('{"@attributes":{"count":0}}'), 'post').length, 0);
    final tags = BooruDecoder.rows(bytes('<?xml version="1.0"?><tags><tag name="landscape" count="123" type="0" id="1"/></tags>'), 'tag');
    expect(tags.first['name'], 'landscape');
    expect(BooruDecoder.rows(bytes("<notes type='array'/>"), 'note').length, 0);
    for (final body in ['<html><body>Sign in</body></html>', '{"success":false}', '{"error":"unauthorized"}', 'garbage']) {
      expect(() => BooruDecoder.rows(bytes(body), 'post'), throwsA(isA<BooruError>()), reason: body);
    }
  });

  test('notes strip markup and inactive notes', () {
    final notes = BooruDecoder.rows(
      bytes("<notes><note id='1' x='10' y='20' width='300' height='90' is_active='true'><body>Hello &amp; &lt;b&gt;world&lt;/b&gt;</body></note></notes>"),
      'note',
    ).map(BooruDecoder.note).nonNulls.toList();
    expect(notes.first.body, 'Hello & world');
    expect(notes.first.width, 300);
    expect(BooruDecoder.note({'id': 2, 'body': 'old', 'is_active': false}), isNull);
    expect(BooruDecoder.note({'id': 2, 'body': 'old', 'is_active': '0'}), isNull);
    final html = bytes(
      "<html><section id='notes'><article data-x='20' data-y='30' data-width='40' data-height='50' data-body='&lt;b&gt;Hello&lt;/b&gt; &amp; world'></article></section></html>",
    );
    expect(BooruHTML.notes(html).first.body, 'Hello & world');
  });

  test('gallery pool parsing preserves sequence', () {
    final list = bytes(
      "<html><a href='index.php?page=pool&amp;s=show&amp;id=77'>Mountain &amp; sky</a><a href='index.php?page=pool&amp;s=show&amp;id=77'>duplicate</a></html>",
    );
    expect(BooruHTML.pools(list), [BooruPool(id: 77, name: 'Mountain & sky', count: 0)]);
    final detail = bytes('<html><span id=\'p103\'></span><article id="p101"></article><span id=\'p103\'></span></html>');
    expect(BooruHTML.postIDs(detail), [103, 101]);
    expect(() => BooruHTML.postIDs(bytes('<html>Just a moment...</html>')), throwsA(isA<BooruError>()));
    final pagination = bytes(
      "<html><a href='?page=pool&amp;s=show&amp;id=77&amp;pid=90'>3</a><a href='?page=pool&amp;s=show&amp;id=77&amp;pid=45'>2</a></html>",
    );
    expect(BooruHTML.nextPoolOffset(pagination, 0), 45);
    expect(BooruHTML.nextPoolOffset(detail, 0), isNull);
    expect(BooruHTML.attributes('data-body="It\'s a note" data-x=\'4\'')['data-body'], "It's a note");
  });

  test('autocomplete preserves terms and negation', () {
    final completion = BooruCompletion.parse('rating:g  -sC')!;
    expect(completion.token, 'sc');
    expect(completion.inserting('scenery'), 'rating:g  -scenery ');
    expect(BooruCompletion.parse('scenery '), isNull);
    expect(BooruCompletion.parse('rating:g'), isNull);
  });

  test('blacklist and exceptions, wildcards and ratings', () {
    final post = BooruFixtureSource.post(101, dan, tags: ['mountain', 'scenery', 'sample_artist']);
    expect(BooruBlacklist('mountain\ncity').contains(post), isTrue);
    expect(BooruBlacklist('mountain city').contains(post), isFalse);
    expect(BooruBlacklist('mountain -city').contains(post), isTrue);
    expect(BooruBlacklist('mountain -scenery').contains(post), isFalse);
    expect(BooruBlacklist('sample_*').contains(post), isTrue);
    expect(BooruBlacklist('rating:general').contains(post), isTrue);
    expect(BooruBlacklist('rating:explicit').contains(post), isFalse);
    expect(BooruBlacklist('id:101').contains(post), isTrue);
    expect(BooruBlacklist('\n# comment\n').contains(post), isFalse);
  });

  test('engine requests, pagination and pool order', () async {
    for (final engine in BooruEngine.values.where((engine) => engine != BooruEngine.oldGelbooru)) {
      final server = copy(dan, id: 'engine-${engine.name}', engine: engine);
      final client = mocked((request) {
        if (engine == BooruEngine.gelbooru) {
          expect(item(request, 'pid'), '1');
          expect(item(request, 's'), 'post');
        } else {
          expect(item(request, 'page'), '2');
        }
        expect(item(request, 'tags'), 'scenery');
        return (200, '[]');
      });
      final batch = await client.posts(server, 'scenery', 1);
      expect(batch.hasMore, isFalse);
    }
    final client = mocked((request) {
      expect(item(request, 'tags'), 'ordpool:77');
      return (200, '[]');
    });
    await client.poolPosts(dan, 77, 0);
  });

  test('server 500 retry preserves exact search and omits only projection', () async {
    var calls = 0;
    final client = mocked((request) {
      calls += 1;
      expect(item(request, 'tags'), 'landscape order:score rating:general');
      expect(item(request, 'page'), '1');
      if (calls == 1) {
        expect(item(request, 'only'), isNotNull);
        return (500, '{}');
      }
      expect(item(request, 'only'), isNull);
      return (200, '[{"id":41,"score":999,"file_url":"https://cdn.example.com/a.jpg"}]');
    });
    final batch = await client.posts(dan, 'landscape order:score rating:general', 0);
    expect(calls, 2);
    expect(batch.posts.map((post) => post.postID), [41]);
  });

  test('persistent 500 does not add hidden score or rating tags', () async {
    var calls = 0;
    final client = mocked((request) {
      calls += 1;
      expect(item(request, 'tags'), 'scenery order:score');
      return (500, '{}');
    });
    final error = await failure(() => client.posts(dan, 'scenery order:score', 0));
    expect(error, isA<BooruError>().having((error) => error.status, 'status', 500));
    expect(calls, 2, reason: 'Bounded retry; never append hidden filters or repeat indefinitely');
  });

  test('old gallery uses HTML and twenty post offsets', () async {
    final server = copy(dan, engine: BooruEngine.oldGelbooru);
    final client = mocked((request) {
      expect(item(request, 'pid'), '40');
      expect(item(request, 'page'), 'post');
      expect(item(request, 's'), 'list');
      return (200, "<html><span class='thumb'><a id='p9'><img src='/thumb.jpg' title='scenery score:3 rating:safe'></a></span></html>");
    });
    final batch = await client.posts(server, 'scenery', 2);
    expect(batch.posts.first.postID, 9);
    expect(batch.hasMore, isFalse);
  });

  test('public gallery fallback uses the actual next offset and is remembered', () async {
    final server = copy(dan, id: 'public-gallery', engine: BooruEngine.gelbooru);
    var apiRequests = 0;
    final client = mocked((request) {
      if (item(request, 'page') == 'dapi') {
        apiRequests += 1;
        return (401, 'API key required');
      }
      final offset = item(request, 'pid');
      if (offset == null) {
        return (
          200,
          "<html><article><a id='p11'><img src='/thumb.jpg' title='scenery score:3 rating:general'></a></article><a href='?page=post&amp;s=list&amp;pid=42'>Next</a></html>",
        );
      }
      expect(offset, '42');
      return (200, "<html><article><a id='p12'><img src='/thumb2.jpg' title='scenery score:2 rating:general'></a></article></html>");
    });
    final first = await client.posts(server, 'scenery', 0);
    expect(first.posts.map((post) => post.postID), [11]);
    expect(first.hasMore, isTrue);
    final second = await client.posts(server, 'scenery', 1);
    expect(second.posts.map((post) => post.postID), [12]);
    expect(second.hasMore, isFalse);
    expect(apiRequests, 1, reason: 'A server that asked for a key keeps using its public gallery');
  });

  test('auth, rate limit and HTML failures remain actionable', () async {
    for (final (status, kind) in [
      (401, BooruErrorKind.authentication),
      (403, BooruErrorKind.validationRequired),
      (429, BooruErrorKind.rateLimited),
      (500, BooruErrorKind.unavailable),
    ]) {
      final client = mocked((_) => (status, '{}'));
      expect(await failure(() => client.posts(dan, '', 0)), isA<BooruError>().having((error) => error.kind, 'kind', kind));
    }
    final client = mocked((_) => (200, '<html>Login required</html>'));
    expect(await failure(() => client.posts(dan, '', 0)), isA<BooruError>());
  });

  test('pool list reads known empty counts and post links keep order', () {
    final html = bytes('''
<html><table><tr><td><a href='?page=pool&amp;s=show&amp;id=746'>Empty</a></td><td>Creator</td><td>0</td></tr>
<tr><td><a href='?page=pool&amp;s=show&amp;id=685'>Pages</a></td><td>Creator</td><td>7</td></tr></table></html>
''');
    final pools = BooruHTML.pools(html);
    expect(pools.every((pool) => pool.hasKnownCount), isTrue);
    expect(pools.where((pool) => !pool.hasKnownCount || pool.count > 0).map((pool) => pool.id), [685]);
    final posts = bytes(
      "<html><span id='p30'><a href='?page=post&amp;s=view&amp;id=30'>one</a></span><a href='?page=post&amp;s=view&amp;id=10'>two</a><a href='?page=pool&amp;s=show&amp;id=9'>unrelated</a></html>",
    );
    expect(BooruHTML.postIDs(posts), [30, 10]);
  });

  test('direct pool lookup does not expose an empty pool', () async {
    final server = copy(dan, engine: BooruEngine.gelbooru);
    final client = mocked((_) => (200, "<html><div id='pool-show'>Empty pool</div></html>"));
    expect(await client.pools(server, '746', 0), isEmpty);
  });

  test('pool uses the public post when the API has no row', () async {
    final server = copy(dan, engine: BooruEngine.gelbooru);
    final client = mocked(
      (request) => switch (item(request, 'page')) {
        'pool' => (200, "<html><a href='?page=post&amp;s=view&amp;id=17'>page</a></html>"),
        'dapi' => (200, '[]'),
        _ => (200, "<html><img id='image' src='https://images.example/page.png'></html>"),
      },
    );
    final batch = await client.poolPosts(server, 5, 0);
    expect(batch.posts.map((post) => post.postID), [17]);
    expect(batch.posts.first.fileURL, isNotNull);
  });

  test('legacy whole pool is paged locally without duplicates', () async {
    final server = copy(dan, id: 'whole-pool', engine: BooruEngine.gelbooru);
    final client = mocked((request) {
      if (item(request, 'page') == 'pool') {
        expect(item(request, 'api_key'), isNull);
        return (200, '<html>${[for (var id = 1; id <= 42; id++) "<span id='p$id'></span>"].join()}</html>');
      }
      return (200, '[{"id":${item(request, 'id')}}]');
    });
    final first = await client.poolPosts(server, 7, 0);
    expect(first.posts.length, 40);
    expect(first.hasMore, isTrue);
    final second = await client.poolPosts(server, 7, 1);
    expect(second.posts.map((post) => post.postID), [41, 42]);
    expect(second.hasMore, isFalse);
  });

  test('danbooru projection includes media and filtering fields', () async {
    final client = mocked((request) {
      expect((item(request, 'only') ?? '').split(',').toSet(), {
        'id',
        'file_url',
        'large_file_url',
        'preview_file_url',
        'image_width',
        'image_height',
        'tag_string',
        'tag_string_artist',
        'tag_string_meta',
        'rating',
        'score',
        'file_ext',
        'pool_ids',
        'fav_count',
        'up_score',
        'comment_count',
        'is_banned',
        'is_deleted',
        'media_asset[variants]',
        'tag_string_copyright',
        'tag_string_character',
      });
      return (
        200,
        '[{"id":101,"file_url":"https://cdn.example.com/a.jpg","preview_file_url":"https://cdn.example.com/p.jpg","tag_string":"scenery","tag_string_artist":"artist","rating":"g","file_ext":"jpg"}]',
      );
    });
    final result = await client.posts(dan, 'scenery', 0);
    expect(result.posts.first.tags, ['scenery']);
    expect(result.posts.first.artists, ['artist']);
    expect(result.posts.first.fileURL, isNotNull);
  });

  test('gold access detection requires an explicit post gate', () {
    const gate =
        "<html><div id='content'><section class='image-container note-container'><p><a href='/user_upgrades/new'>You need a gold account to see this image</a>.</p></section></div></html>";
    expect(BooruPostAccessError.detect(bytes(gate), dan), BooruPostAccessError.goldRequired);
    expect(
      BooruPostAccessError.detect(bytes('{"success":false,"message":"You need a Gold account to see this image."}'), dan),
      BooruPostAccessError.goldRequired,
    );
    expect(BooruPostAccessError.detect(bytes('This post requires a Gold account.'), dan), BooruPostAccessError.goldRequired);
    for (final text in [
      "<html><div id='comments'>You need a gold account to see this image</div><section class='image-container'><img src='/image.jpg'></section></html>",
      "<section class='image-container'><img src='/image.jpg'><p>You need a gold account to see this image</p></section>",
      "<section class='image-container'><p>This page has been removed because of a takedown request or rule violation.</p></section>",
      "<section class='image-container'><p>This image is unavailable in safe mode.</p></section>",
      '{"success":false,"message":"Gold members can search more tags."}',
      'Forbidden',
      '<html>Just a moment...</html>',
    ]) {
      expect(BooruPostAccessError.detect(bytes(text), dan), isNull, reason: text);
    }
    expect(BooruPostAccessError.detect(bytes('{"id":12403879,"is_banned":true,"is_visible":false}'), dan), BooruPostAccessError.removed);
    expect(BooruPostAccessError.detect(bytes(gate), copy(dan, engine: BooruEngine.gelbooru)), isNull);
  });

  test('gold rows are filtered without changing the native page size or repeating checks', () async {
    final rows = [
      for (var id = 1; id <= 39; id++) {'id': id, 'file_url': 'https://cdn.example.com/$id.jpg'},
      {'id': 12403879, 'is_banned': false},
    ];
    var documentCalls = 0;
    final client = mocked((request) {
      if (request.url.path.endsWith('posts.json')) return (200, jsonEncode(rows));
      if (request.url.path.endsWith('posts/12403879.json')) return (200, '{"id":12403879,"is_banned":false}');
      documentCalls += 1;
      expect(request.url.path.endsWith('posts/12403879'), isTrue);
      expect(request.headers['Accept'], 'text/html', reason: 'The access gate exists in HTML, not the projected JSON');
      return (200, "<section class='image-container'><p>You need a gold account to see this image.</p></section>");
    });
    final first = await client.posts(dan, '', 0);
    expect(first.posts.length, 39);
    expect(first.goldRestrictedIDs, [12403879]);
    expect(first.sourcePostCount, 40);
    expect(first.hasMore, isTrue);
    await client.posts(dan, '', 0);
    expect(
      await failure(() => client.details(dan, BooruDecoder.post({'id': 12403879}, dan))),
      BooruPostAccessError.goldRequired,
      reason: 'A saved preview-only post must use the same confirmed restriction',
    );
    expect(documentCalls, 1, reason: 'Feed refreshes and opening the same missing-media post share a short access result cache');
  });

  test('danbooru access failures and removed posts remain in feed', () async {
    var checks = 0;
    final client = mocked((request) {
      if (request.url.path.endsWith('posts.json')) return (200, '[{"id":101,"is_banned":false},{"id":102,"is_banned":true}]');
      checks += 1;
      expect(request.url.path.endsWith('posts/101'), isTrue);
      return (403, '<html>Forbidden</html>');
    });
    for (var round = 0; round < 2; round++) {
      final batch = await client.posts(dan, '', 0);
      expect(batch.posts.map((post) => post.postID), [101, 102]);
      expect(batch.goldRestrictedIDs, isEmpty);
    }
    expect(checks, 2, reason: 'An inconclusive access failure must not become a cached hidden post');
  });

  test('gold access cache retries after browser validation changes', () async {
    final session = BooruBrowserSession();
    final server = copy(dan, id: 'gold-cache');
    var restricted = true, calls = 0;
    final client = mocked((request) {
      if (request.url.path.endsWith('posts/101.json')) return (200, '{"id":101}');
      calls += 1;
      return (
        200,
        restricted
            ? "<section class='image-container'>You need a gold account to see this image.</section>"
            : "<section class='image-container'><img src='https://cdn.example.com/a.jpg'></section>",
      );
    }, session: session);
    final post = BooruDecoder.post({'id': 101}, server);
    expect(await failure(() => client.details(server, post)), BooruPostAccessError.goldRequired);
    restricted = false;
    session.clearChallenge(server);
    await client.details(server, post);
    expect(calls, 2);
  });

  test('explicit gold HTTP error is typed but generic forbidden is not', () async {
    final client = mocked((_) => (403, '{"success":false,"message":"You need a gold account to see this image."}'));
    expect(await failure(() => client.posts(dan, 'id:12403879', 0)), BooruPostAccessError.goldRequired);
    final generic = mocked((_) => (403, '{"success":false,"message":"Forbidden"}'));
    expect(await failure(() => generic.posts(dan, '', 0)), isA<BooruError>().having((error) => error.kind, 'kind', BooruErrorKind.validationRequired));
  });

  test('gold-only sorted page does not trigger unsupported sort fallback', () async {
    final source = _GoldPageSource();
    final result = await BooruSortValidation.posts(source: source, server: dan, query: '', page: 0, sort: BooruSort.popular);
    expect(result.goldRestrictedIDs, [12403879]);
    expect(source.pages, [0], reason: 'A filtered result is still a valid nonempty native page');
  });

  test('gallery details and notes share one document but media refresh stays fresh', () async {
    var calls = 0;
    final client = mocked((_) {
      calls += 1;
      return (
        200,
        "<html><img id='image' src='https://cdn.example.com/sample.jpg'><a href='https://cdn.example.com/original.jpg'>Original image</a><section id='notes'><article data-x='20' data-y='30' data-width='40' data-height='50' data-body='Hello'></article></section></html>",
      );
    });
    final server = BooruServer(id: 'document-reuse', name: 'Gallery', baseURL: 'https://gallery.example', engine: BooruEngine.gelbooru);
    final post = BooruDecoder.post({'id': 101}, server);
    final resolved = await client.details(server, post);
    expect(resolved.viewerURL(original: false), isNotNull);
    final notes = await client.notes(server, 101);
    expect(notes.first.body, 'Hello');
    expect(calls, 1, reason: 'Details and notes used to navigate to the same page twice');
    await client.details(server, resolved);
    expect(calls, 2, reason: 'A failed-media refresh must not reuse an expired URL');
  });

  test('gallery notes come from the API, or from the post page when the API asks for a key', () async {
    final server = BooruServer(id: 'notes', name: 'Gallery', baseURL: 'https://gallery.example', engine: BooruEngine.gelbooru);
    final api = mocked((request) {
      expect(item(request, 's'), 'note');
      return (200, '<notes><note id="3" x="1" y="2" width="3" height="4" body="From the API"/></notes>');
    });
    expect((await api.notes(server, 7)).single.body, 'From the API');
    final page = mocked((request) {
      if (item(request, 'page') == 'dapi') return (401, 'API key required');
      return (200, "<html><article data-x='1' data-y='2' data-width='3' data-height='4' data-body='From the page'></article></html>");
    });
    expect((await page.notes(server, 7)).single.body, 'From the page');
  });

  test('a server reporting modern rating words keeps "s" as sensitive', () async {
    final server = BooruServer(id: 'modern', name: 'Gallery', baseURL: 'https://gallery.example', engine: BooruEngine.gelbooru);
    final client = mocked((_) => (200, '[{"id":1,"rating":"general"},{"id":2,"rating":"s"}]'));
    final batch = await client.posts(server, '', 0);
    expect(batch.posts.map((post) => post.rating), ['general', 's']);
    final legacyServer = copy(server, id: 'legacy-ratings', baseURL: 'https://legacy-ratings.example');
    final legacyClient = mocked((_) => (200, '[{"id":1,"rating":"s"}]'));
    expect((await legacyClient.posts(legacyServer, '', 0)).posts.single.rating, 'g');
  });

  test('API redirects stay on the server while media redirects drop credentials', () async {
    final headers = {'Cookie': 'clearance=private', 'Authorization': 'Basic private', 'Accept': '*/*'};
    final original = Uri.parse('https://example.com/image');
    expect(BooruRedirectPolicy.redirect(original, Uri.parse('https://cdn.example.net/image'), headers), isNull);
    expect(BooruRedirectPolicy.redirect(original, Uri.parse('https://example.com/other'), headers), headers);
    final media = BooruRedirectPolicy.redirect(original, Uri.parse('https://cdn.example.net/image'), headers, publicMedia: true);
    expect(media, {'Accept': '*/*'});
    expect(BooruRedirectPolicy.redirect(original, Uri.parse('http://cdn.example.net/image'), headers, publicMedia: true), isNull);
    final requests = <Uri>[];
    final client = BooruClient(
      fetcher: FixtureFetcher((request) {
        requests.add(request.url);
        return request.url.host == 'example.com' ? FixtureReply.redirect(Uri.parse('https://elsewhere.example/posts.json')) : FixtureReply.text(200, '[]');
      }),
      credentials: MemoryCredentialStore(),
      session: BooruBrowserSession(),
    );
    expect(await failure(() => client.posts(dan, '', 0)), isA<BooruError>().having((error) => error.status, 'status', 302));
    expect(requests.map((url) => url.host), ['example.com'], reason: 'Credentials never follow a redirect to another host');
  });

  test('legacy HTML listing, detail, tags and notes', () {
    final listing = bytes('''
<html><body>Running Gelbooru Beta 0.1.11
<span class="thumb"><a id="p42" href="index.php?page=post&amp;s=view&amp;id=42"><img src="http://img.legacy.example/thumbnails/1/thumbnail_hash.jpg" title="scenery blue_sky score:12 rating:safe"/></a></span>
<span class="thumb"><a id="p42"><img src="https://img.legacy.example/duplicate.jpg"/></a></span>
</body></html>
''');
    final posts = BooruLegacyHTML.posts(listing, legacy);
    expect(posts.length, 1);
    expect(posts[0].tags, ['scenery', 'blue_sky']);
    expect(posts[0].score, 12);
    expect(posts[0].previewURL, startsWith('https:'));
    expect(posts[0].fileURL, isNull, reason: 'Do not guess original formats from thumbnails');
    final details = bytes('''
<html><body>Size: 1600x1200 <br>Rating: Safe<br>Score: <span>12</span>
<img alt="img" src="http://img.legacy.example/images/1/hash.png" onclick="Note.toggle();"/>
<textarea id="tags" name="tags">scenery blue_sky artist_a</textarea>
<li class="artist-tag"><a href="?tags=artist_a">artist_a</a> <small>34</small></li>
<div id="note-box-5" style="left: 10px; top: 20px; width: 100px; height: 50px"></div>
<div id="note-body-5">Hello &amp; world</div></body></html>
''');
    final post = BooruLegacyHTML.post(details, legacy, 42, preview: posts[0].previewURL);
    expect(post.fileExtension, 'png');
    expect(post.width, 1600);
    expect(post.height, 1200);
    expect(post.artists, ['artist_a']);
    expect(post.fileURL, startsWith('https:'));
    expect(BooruLegacyHTML.notes(details).first.body, 'Hello & world');
    expect(BooruLegacyHTML.notes(details).first.width, 100);
    expect(() => BooruLegacyHTML.posts(bytes('<html>Just a moment...</html>'), legacy), throwsA(isA<BooruError>()));
  });

  test('legacy query and unrated posts remain intact', () {
    expect(Uri.parse(legacy.browsingURL('')).query, 'page=post&s=list');
    final data = bytes("<html><a id='p7'><img src='/preview.jpg' title='scenery'></a></html>");
    final posts = BooruLegacyHTML.posts(data, legacy);
    expect(posts.length, 1);
    expect(posts[0].rating, '');
    expect(BooruBlacklist('').contains(posts[0]), isFalse);
  });

  test('modern gallery markup without anchor ID and with a lazy image', () {
    final html = bytes('''
<html><article class="thumbnail-preview"><a href="index.php?page=post&amp;s=view&amp;id=123"><picture><img src="/loading.png" data-original="/thumb.jpg" title="landscape"></picture></a></article>
<script>posts[123] = {'rating':'general', 'score':42, 'user':'fixture'};</script></html>
''');
    final posts = BooruLegacyHTML.posts(html, BooruServer(name: 'Gallery', baseURL: 'https://gallery.example', engine: BooruEngine.gelbooru));
    expect(posts.length, 1);
    expect(posts[0].postID, 123);
    expect(Uri.parse(posts[0].previewURL!).path, '/thumb.jpg');
    expect(posts[0].score, 42);
    expect(posts[0].rating, 'g');
  });

  test('pagination keeps the server link and rejects other origins', () {
    final html = bytes('''
<html><a href="https://elsewhere.invalid/?s=list&amp;pid=10">Other</a>
<a href="?page=post&amp;s=list&amp;tags=all&amp;pid=20&amp;cursor=fixture">Next</a></html>
''');
    final url = Uri.parse(BooruLegacyHTML.nextPageURL(html, legacy, 0)!);
    expect(url.host, Uri.parse(legacy.baseURL).host);
    expect(url.path, '/index.php');
    expect(url.queryParameters['cursor'], 'fixture');
  });

  test('browser routes use public pages and preserve search', () {
    for (final server in [...BooruFixtureEnvironment.servers, legacy, copy(dan, engine: BooruEngine.moebooru)]) {
      final url = server.browsingURL('landscape -rain');
      expect(booruSameOrigin(url, server.baseURL), isTrue);
      expect(Uri.parse(url).queryParameters['tags'], 'landscape -rain');
      expect(url.contains('dapi'), isFalse);
      expect(server.browsingURL('', poolID: 77).contains('tags='), isFalse);
    }
  });

  test('danbooru public pool list parses names and counts and ignores pagination', () {
    final data = bytes('''
<html><div id="c-pools"><table><tr><th>Name</th><th>Count</th></tr>
<tr><td><span><a href="/pools/42">Sky &amp; Sea</a></span><a href="/pools/42?page=2">page 2</a></td><td>1,234</td></tr>
<tr><td><a href="/pools/77">Clouds</a></td><td>18</td></tr></table>
<a href="/pools?page=2">Next</a></div></html>
''');
    final pools = BooruHTML.danbooruPools(data);
    expect(pools.map((pool) => pool.id), [42, 77]);
    expect(pools.first.name, 'Sky & Sea');
    expect(pools.first.count, 1234);
    expect(BooruHTML.danbooruPools(bytes("<html><div id='c-pools'><table></table></div></html>")), isEmpty);
    expect(() => BooruHTML.danbooruPools(bytes('<html>Login required</html>')), throwsA(isA<BooruError>()));
  });

  test('browser transport origin boundary and challenge detection', () {
    const root = 'https://example.com';
    expect(booruSameOrigin('https://example.com:443/posts.json', root), isTrue);
    for (final url in ['http://example.com', 'https://example.com:444', 'https://elsewhere.com', 'https://user:secret@example.com']) {
      expect(booruSameOrigin(url, root), isFalse, reason: url);
    }
    expect(BooruClient.needsBrowser(bytes('<html>Just a moment...</html>'), 200), isTrue);
    expect(BooruClient.needsBrowser(bytes('[]'), 200), isFalse);
  });
}

class _AutocompleteSource extends _EmptySource {
  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async {
    if (server.id == 'blocked') throw const BooruError(BooruErrorKind.validationRequired);
    if (server.id == 'slow') {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return const [BooruTag(name: 'hatsune_miku', count: 1, category: 4), BooruTag(name: 'very_popular', count: 10000, category: 0)];
    }
    return const [BooruTag(name: 'cloud', count: 50, category: 0), BooruTag(name: 'hatsune_miku', count: 10, category: 4)];
  }
}

class _GoldPageSource extends _EmptySource {
  final pages = <int>[];
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    pages.add(page);
    if (page == 0) return const BooruBatch(posts: [], hasMore: true, goldRestrictedIDs: [12403879]);
    return BooruBatch(posts: [BooruFixtureSource.post(101, server)], hasMore: false);
  }
}

class _EmptySource implements BooruProviding {
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async => [];
  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => [];
  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async => [];
  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async => post;
}
