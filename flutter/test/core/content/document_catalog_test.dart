// Ported from native-ios/TEGNALTests/DocumentCatalogTests.swift.
// Not ported here:
// - testCancellationStopsPendingConnectionRetries: Dart futures have no cooperative cancellation.
// - testConfiguredLiveCatalog: opt-in test against a live site.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/content_url.dart';
import 'package:tegnal/core/content/document_catalog_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/gallery_id_parser.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';

import 'content_test_support.dart';

class CatalogFixture {
  final requests = <Uri>[];
  bool expireFirstManifest = false;
  bool omitThumbnails = false;
  bool visualCollections = false;
  bool markEvenRows = false;
  Map<int, String> originalTitles = {};
  Map<int, List<String>> languages = {};
  final image = List.filled(64, 0x42);

  int count(String path) => requests.where((url) => url.path == path).length;
  ContentTransport transport() => ContentTransport(fetcher: FixtureFetcher(reply));

  Map<String, Object?> _row(int id) {
    final tags = <Map<String, Object?>>[
      for (final language in languages[id] ?? ['korean'])
        {
          'tag': ['language', language],
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
      if (markEvenRows && id.isEven)
        {
          'tag': ['female', 'marked tag'],
        },
    ];
    return {
      'id': id,
      'title': 'Sample {book}',
      'title_jpn': originalTitles[id],
      'category': 2,
      'views': id * 10,
      'blocked': 0,
      'thumb_extension': 'jpg',
      'tags': tags,
    };
  }

  List<int> document(int id) {
    final object = _row(id);
    final expiry = expireFirstManifest && count('/r/$id') == 1 ? 1 : 4102444800;
    object['files'] = [
      for (var index = 0; index < 2; index++)
        {
          'id': 'file-$index',
          'name': '$index.jpg',
          'image': {'url': 'https://media.example/$index.webp?expires=$expiry&version=$expiry', 'width': 100, 'height': 150},
          'thumbnail': omitThumbnails ? null : {'url': 'https://media.example/$index.jpg?expires=$expiry&version=$expiry'},
        },
    ];
    return utf8.encode('<script>const gallery = ${jsonEncode(object)}; ignoredFunction();</script>');
  }

  FixtureReply reply(HttpExchange request) {
    final url = request.url;
    requests.add(url);
    if (url.host == 'media.example' || url.host == 'preview.example') return FixtureReply(200, image, {'Content-Type': 'image/webp'});
    if (url.host == 'archive.example' && url.path == '/') return FixtureReply.text(200, "const domain = 'files.example';");
    if (url.host == 'ltn.files.example' && url.path == '/galleries/2000.js') {
      return FixtureReply.text(
        200,
        'var galleryinfo = {"title":"Indexed sample","files":[{"hash":"${'a' * 64}","name":"0.jpg"},{"hash":"${'b' * 64}","name":"1.jpg"}]};',
      );
    }
    if (url.host != 'catalog.example') return FixtureReply(404);
    switch (url.path) {
      case '/':
        return FixtureReply.text(
          200,
          '<script src="/js/index.search.tail.js"></script><script>const serverConfig = { thumbServer: {"url":"https://preview.example"} };</script>',
        );
      case '/ajax/search':
        final items = ContentURL.queryItems(url);
        final cursorValue = items.where((item) => item.$1 == 'next-id' || item.$1 == 'next-views-id').firstOrNull?.$2;
        final cursor = cursorValue == null ? null : int.tryParse(cursorValue);
        final start = cursor == null ? 2000 : cursor - 1;
        final categories = (items.where((item) => item.$1 == 'categories').firstOrNull?.$2 ?? '2').split(',').map(int.tryParse).nonNulls.toSet();
        final rows = <Map<String, Object?>>[
          if (categories.contains(2))
            for (var id = start; id >= (1901 > start - 49 ? 1901 : start - 49); id--) _row(id),
        ];
        if (visualCollections) {
          for (final (id, category) in [(2003, 3), (2002, 4), (2001, 6)]) {
            if (categories.contains(category) && (cursor == null || id < cursor)) {
              rows.add(
                _row(id)
                  ..['category'] = category
                  ..['tags'] = [
                    {
                      'tag': ['artist', 'sample_artist'],
                    },
                  ],
              );
            }
          }
        }
        if (visualCollections && items.any((item) => item.$1 == 'search' && (item.$2 ?? '').contains('language:korean'))) {
          rows.removeWhere((row) => (row['category'] as int? ?? 2) != 2);
        }
        rows.sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
        return FixtureReply.text(200, jsonEncode(rows), {'Content-Type': 'application/json'});
      case '/ajax/search-tags':
        return FixtureReply.text(200, '["parody:sample_series"]', {'Content-Type': 'application/json'});
      default:
        final id = int.tryParse(url.pathSegments.lastOrNull ?? '');
        if (url.path.startsWith('/r/') && id != null) return FixtureReply(200, document(id), {'Content-Type': 'text/html'});
        return FixtureReply(404);
    }
  }
}

class RetryingCatalogFixture {
  RetryingCatalogFixture({List<NetworkErrorCode> directFailures = const [], List<Object> browserFailures = const [], this.status = 200})
    : _directFailures = [...directFailures],
      _browserFailures = [...browserFailures];

  final payload = utf8.encode('[]');
  final List<NetworkErrorCode> _directFailures;
  final List<Object> _browserFailures;
  final int status;
  int direct = 0;
  int browser = 0;
  void Function()? onBrowserRequest;

  ContentTransport transport() => ContentTransport(
    fetcher: FixtureFetcher((request) {
      direct += 1;
      if (_directFailures.isNotEmpty) throw NetworkError(_directFailures.removeAt(0));
      return FixtureReply(status, payload, {'Content-Type': 'application/json'});
    }),
    browserFetch: (url, _, _, _, _) async {
      browser += 1;
      final failure = _browserFailures.isEmpty ? null : _browserFailures.removeAt(0);
      onBrowserRequest?.call();
      if (failure != null) throw failure;
      return ContentResult(
        payload,
        ContentResponse(
          url: url,
          statusCode: status,
          headers: {
            'Content-Type': ['application/json'],
          },
        ),
      );
    },
  );
}

void main() {
  setUp(() => resetContent(site: 'catalog.example'));

  test('short reader links and wrapped links keep the numeric identity', () {
    expect(GalleryIDParser.parse('https://catalog.example/r/2000#2'), [2000]);
    expect(GalleryIDParser.parse('https://archive.example/reader/2000.html#2'), [2000]);
    expect(GalleryIDParser.parse('https://share.example/?u=https%3A%2F%2Fcatalog.example%2Fr%2F2000%232'), [2000]);
    expect(ContentRoute.initial('https://catalog.example/r/2000#2'), const ReaderRoute(2000, 2));
    expect(ContentRoute.initial('https://catalog.example/r/2000'), const GalleryRoute(2000));
    expect(ContentRoute.initial('https://catalog.example/?search=artist%3Asample'), const QueryRoute('artist:sample'));
    expect(ContentRoute.initial('https://foreign.example/r/2000#2'), isNull);
  });

  test('discovery and links follow the configured protocol', () async {
    final fixture = CatalogFixture();
    final source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(), offset: 0, count: 2);
    expect(MangaUrls.backend, MangaBackend.document);
    expect(MangaUrls.galleryUrl(2000), 'https://catalog.example/r/2000');
    expect(MangaUrls.readerUrl(2000, page: 3), 'https://catalog.example/r/2000#3');
    expect(ContentRoute.configuredURL(Uri.parse('https://catalog.example/reader/2000.html#3')).toString(), 'https://catalog.example/r/2000#3');
    expect(ContentRoute.initial(MangaUrls.artistAllUrl('sample artist')), const QueryRoute('artist:sample_artist'));
    expect(fixture.count('/'), 1);
    expect(ContentTransport.allows(Uri.parse('https://preview.example/0/2/0.jpg')), isTrue);
    MangaUrls.preferences.set('manga.site_address', 'archive.example');
    expect(MangaUrls.hasResolvedBackend, isFalse);
    expect(MangaUrls.readerUrl(2000, page: 3), 'https://archive.example/reader/2000.html#3');
    expect(ContentTransport.allows(Uri.parse('https://preview.example/0/2/0.jpg')), isFalse);
  });

  test('search previews avoid fetching every full document', () async {
    final fixture = CatalogFixture(), source = MangaContentSource(transport: fixture.transport());
    final batch = await source.list(const GalleryQuery(), offset: 0, count: 2);
    expect(batch.ids, [2000, 1999]);
    final preview = source.cachedPreview(2000)!;
    expect(source.cachedGallery(2000), isNull, reason: 'A search preview must never seed a reader with an incomplete page list');
    expect(preview.title, 'Sample {book}');
    final bytes = await source.image(preview.pages[0], galleryID: 2000, thumbnail: true);
    expect(bytes, fixture.image);
    expect(fixture.count('/r/2000'), 0);
    final full = await source.gallery(2000);
    expect(full.pages.length, 2);
    expect(source.cachedGallery(2000)?.pages.length, 2);
    expect(full.artists, ['sample_artist']);
    expect(full.language, 'korean');
    expect(full.tags.contains('series:sample_series'), isTrue);
    expect(full.tags.contains('tag:sample_tag'), isTrue);
    expect(fixture.count('/r/2000'), 1);
  });

  test('page previews and reader use separate server image URLs', () async {
    final fixture = CatalogFixture(), source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(2000);
    final page = gallery.pages[1];
    expect(page.thumbnailURL, isNot(page.imageURL));
    await source.image(page, galleryID: gallery.id, thumbnail: true);
    expect(fixture.count('/1.jpg'), 1);
    expect(fixture.count('/1.webp'), 0, reason: 'Previews must not download the reader image');
    await source.image(page, galleryID: gallery.id, thumbnail: false);
    expect(fixture.count('/1.webp'), 1);
  });

  test('missing page thumbnail never falls back to reader image', () async {
    final fixture = CatalogFixture()..omitThumbnails = true;
    final source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(2000);
    expect(gallery.pages[1].thumbnailURL, isNull);
    await expectLater(source.image(gallery.pages[1], galleryID: gallery.id, thumbnail: true), throwsA(ContentError.invalidResponse));
    expect(fixture.count('/1.webp'), 0);
    await source.image(gallery.pages[1], galleryID: gallery.id, thumbnail: false);
    expect(fixture.count('/1.webp'), 1, reason: 'The original remains available to the reader');
  });

  test('pagination reuses buffered results and then follows the cursor', () async {
    final fixture = CatalogFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(), offset: 0, count: 2);
    final second = await source.list(const GalleryQuery(), offset: 2, count: 2);
    expect(second.ids, [1998, 1997]);
    // The Swift test expects 2 and then 3, but the native source makes 1 and then 2 requests;
    // that test fails on the native app (checked at c95a18e). These are the native results.
    expect(fixture.count('/ajax/search'), 1);
    final next = await source.list(const GalleryQuery(), offset: 48, count: 4);
    expect(next.ids, [1952, 1951, 1950, 1949]);
    expect(fixture.count('/ajax/search'), 2);
    expect(fixture.requests.any((url) => ContentURL.queryItems(url).contains(('next-id', '1951'))), isTrue);
  });

  test('visual collections bypass implicit language but retain types and ranking', () async {
    final fixture = CatalogFixture()..visualCollections = true;
    final source = MangaContentSource(transport: fixture.transport());
    final strict = await source.list(const GalleryQuery(), offset: 0, count: 5);
    expect(strict.ids, [2000, 1999, 1998, 1997, 1996], reason: 'Language exceptions are off by default');
    final latest = await source.list(const GalleryQuery(allowsLanguageExceptions: true), offset: 0, count: 5);
    expect(latest.ids, [2003, 2002, 2001, 2000, 1999]);
    final popular = await source.list(const GalleryQuery(sort: GallerySort.week, allowsLanguageExceptions: true), offset: 0, count: 5);
    expect(popular.ids, latest.ids);
    final onlyManga = await source.list(const GalleryQuery(text: 'type:manga', allowsLanguageExceptions: true), offset: 0, count: 2);
    expect(onlyManga.ids, [2000, 1999]);
    final onlyVisual = await source.list(const GalleryQuery(text: 'type:gamecg', allowsLanguageExceptions: true), offset: 0, count: 5);
    expect(onlyVisual.ids, [2002]);
    final visualRequests = fixture.requests
        .where((url) => url.path == '/ajax/search')
        .map(ContentURL.queryItems)
        .where((items) => items.any((item) => item.$1 == 'categories' && item.$2 == '3,4,6'))
        .toList();
    expect(visualRequests, isNotEmpty);
    expect(visualRequests.every((items) => !items.any((item) => item.$1 == 'search' && (item.$2 ?? '').contains('language:korean'))), isTrue);
    final strictVisual = await source.list(const GalleryQuery(text: 'type:gamecg'), offset: 0, count: 5);
    expect(strictVisual.ids, isEmpty, reason: 'The language filter also applies to an explicitly selected visual type');
  });

  test('filters and suggestions translate namespaces without changing their local form', () async {
    final fixture = CatalogFixture(), source = MangaContentSource(transport: fixture.transport());
    const query = GalleryQuery(language: 'korean', artist: 'sample artist', text: 'series:sample -tag:excluded type:manga', sort: GallerySort.week);
    final url = DocumentCatalogSource.searchURL(query, site: MangaUrls.home, now: DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true));
    final items = ContentURL.queryItems(url);
    final search = items.firstWhere((item) => item.$1 == 'search').$2!;
    expect(search.contains('parody:sample'), isTrue);
    expect(search.contains('excluded'), isFalse, reason: 'The remote search would read a minus as an ordinary word');
    expect(search.contains('artist:sample_artist'), isTrue);
    expect(items.contains(('categories', '2')), isTrue);
    expect(items.any((item) => item.$1 == 'start-date'), isTrue);
    final suggestions = await source.suggestions('series:sam');
    expect(suggestions, [const TagSuggestion(namespace: 'series', name: 'sample_series')]);
  });

  test('translations keep their translated title while originals keep their own script', () {
    final fixture = CatalogFixture()
      ..originalTitles = {2000: '原題', 1999: '原題', 1998: '原題'}
      ..languages = {
        2000: ['translated', 'korean'],
        1999: [],
        1998: ['english'],
      };
    final translated = DocumentCatalogSource.parseGallery(fixture.document(2000), 2000, site: MangaUrls.home);
    expect(translated.title, 'Sample {book}');
    expect(translated.language, 'korean', reason: "A translation marker is not the work's language");
    final original = DocumentCatalogSource.parseGallery(fixture.document(1999), 1999, site: MangaUrls.home);
    expect(original.title, '原題');
    expect(original.language, '');
    final otherOriginal = DocumentCatalogSource.parseGallery(fixture.document(1998), 1998, site: MangaUrls.home);
    expect(otherOriginal.title, 'Sample {book}');
  });

  test('excluded tags stay out of the request and remove matching rows', () async {
    final fixture = CatalogFixture()
      ..markEvenRows = true
      ..visualCollections = true;
    final source = MangaContentSource(transport: fixture.transport());
    final batch = await source.list(const GalleryQuery(text: '-female:marked_tag'), offset: 0, count: 4);
    expect(batch.ids, [1999, 1997, 1995, 1993]);
    final next = await source.list(const GalleryQuery(text: '-female:marked_tag'), offset: 4, count: 2);
    expect(next.ids, [1991, 1989]);
    final defaults = await source.list(const GalleryQuery().applyingDefaults(tags: '', excluded: 'female:marked_tag'), offset: 0, count: 2);
    expect(defaults.ids, [1999, 1997], reason: 'Default exclusions take the same path');
    final mixed = await source.list(const GalleryQuery(text: '-female:marked_tag', allowsLanguageExceptions: true), offset: 0, count: 5);
    expect(mixed.ids, [2003, 2002, 2001, 1999, 1997]);
    final searches = fixture.requests.where((url) => url.path == '/ajax/search').map((url) => ContentURL.queryValue(url, 'search')).nonNulls;
    expect(searches.every((search) => !search.contains('marked')), isTrue);
  });

  test('embedded JSON handles escapes and does not execute following scripts', () {
    final fixture = CatalogFixture();
    final parsed = DocumentCatalogSource.parseGallery(fixture.document(2000), 2000, site: MangaUrls.home);
    expect(parsed.title, 'Sample {book}');
    expect(parsed.pages.map((page) => page.index), [0, 1]);
    expect(parsed.pages[0].hash.length, 64);
    expect(() => DocumentCatalogSource.parseGallery(fixture.document(2000), 1999, site: MangaUrls.home), throwsA(isA<ContentError>()));
    expect(
      () => DocumentCatalogSource.parseGallery(utf8.encode('<script>const gallery = execute();</script>'), 2000, site: MangaUrls.home),
      throwsA(isA<ContentError>()),
    );
  });

  test('expired page addresses refresh once for the whole gallery', () async {
    final fixture = CatalogFixture()..expireFirstManifest = true;
    final source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(2000);
    for (final page in gallery.pages) {
      expect(await source.image(page, galleryID: 2000, thumbnail: false), fixture.image);
    }
    expect(fixture.count('/r/2000'), 2);
    expect(fixture.requests.any((url) => url.query.contains('expires=1&')), isFalse);
  });

  test('changing the address preserves bookmarks notes and reading position', () async {
    final fixture = CatalogFixture(), source = MangaContentSource(transport: fixture.transport());
    final database = AppDatabase.inMemory();
    final env = ContentEnvironment(browserPreferences: MemoryPreferences());
    expect(env.verifySite('catalog.example'), isTrue);
    final gallery = await source.gallery(2000);
    final work = database.upsertWork(galleryId: gallery.id, title: 'Saved title');
    database.setNote(gallery.id, 'Keep this note');
    MangaUrls.preferences.set('reader_page_2000', 7);
    expect(env.verifySite('archive.example'), isTrue);
    expect(source.cachedGallery(2000), isNull);
    final switched = await source.gallery(2000);
    expect(switched.id, gallery.id);
    expect(switched.title, 'Indexed sample');
    expect(database.getWork(2000)?.id, work.id);
    expect(database.getWork(2000)?.note, 'Keep this note');
    expect(MangaUrls.preferences.integer('reader_page_2000'), 7);
    expect(database.listWorks().length, 1);
    expect(ContentTransport.allows(Uri.parse('https://media.example/page.webp')), isFalse);
    expect(env.verifySite('catalog.example'), isTrue);
    final restored = await source.gallery(2000);
    expect(restored.title, 'Sample {book}');
  });

  test('old downloads decode without optional network descriptors', () {
    final page = GalleryPage.fromJson(jsonDecode('{"hash":"abc","name":"1.jpg","width":1,"height":2,"hasAVIF":false}') as Map<String, Object?>);
    expect(page.imageURL, isNull);
    expect(page.index, isNull);
    expect(page.sourceSite, isNull);
  });

  test('media discovery rejects local and credential bearing addresses', () {
    for (final value in [
      'http://media.example/1',
      'https://127.0.0.1/1',
      'https://files.local/1',
      'https://user:pass@media.example/1',
      'https://media.example:9443/1',
    ]) {
      expect(DocumentCatalogSource.safeMediaURL(Uri.parse(value)), isFalse, reason: value);
    }
    expect(DocumentCatalogSource.safeMediaURL(Uri.parse('https://media.example/page.webp?expires=1')), isTrue);
  });

  test('interrupted browser request recovers and reuses the working transport', () async {
    final fixture = RetryingCatalogFixture(
      directFailures: [NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.secureConnectionFailed],
      browserFailures: [const NetworkError(NetworkErrorCode.networkConnectionLost)],
    );
    final transport = fixture.transport(), url = Uri.parse('${MangaUrls.home}ajax/search');
    final result = await transport.get(url, limit: 1024);
    expect(result.data, fixture.payload);
    expect((fixture.direct, fixture.browser), (2, 2));
    await transport.get(url, limit: 1024);
    expect(fixture.direct, 2, reason: 'A successful browser connection must be reused');
    expect(fixture.browser, 3);
  });

  test('timed out origin can recover through the browser', () async {
    final fixture = RetryingCatalogFixture(directFailures: [NetworkErrorCode.timedOut]);
    final result = await fixture.transport().get(Uri.parse('${MangaUrls.home}ajax/search'), limit: 1024);
    expect(result.data, fixture.payload);
    expect((fixture.direct, fixture.browser), (1, 1));
  });

  test('terminated web process is retryable', () async {
    final fixture = RetryingCatalogFixture(
      directFailures: [NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.secureConnectionFailed],
      browserFailures: [const BrowserProcessTerminated()],
    );
    await fixture.transport().get(Uri.parse(MangaUrls.home), limit: 1024);
    expect(fixture.browser, 2);
  });

  test('persistent connection failure has a bounded retry count', () async {
    final fixture = RetryingCatalogFixture(
      directFailures: List.filled(3, NetworkErrorCode.secureConnectionFailed),
      browserFailures: List.filled(3, const NetworkError(NetworkErrorCode.networkConnectionLost)),
    );
    await expectLater(fixture.transport().get(Uri.parse(MangaUrls.home), limit: 1024), throwsA(const NetworkError(NetworkErrorCode.networkConnectionLost)));
    expect((fixture.direct, fixture.browser), (3, 3));
  });

  test('certificate rejection and HTTP failures are not retried', () async {
    final certificate = RetryingCatalogFixture(directFailures: [NetworkErrorCode.serverCertificateUntrusted]);
    await expectLater(
      certificate.transport().get(Uri.parse(MangaUrls.home), limit: 1024),
      throwsA(const NetworkError(NetworkErrorCode.serverCertificateUntrusted)),
    );
    expect((certificate.direct, certificate.browser), (1, 0));
    for (final status in [403, 404, 429, 500]) {
      final fixture = RetryingCatalogFixture(status: status);
      await expectLater(fixture.transport().get(Uri.parse(MangaUrls.home), limit: 1024), throwsA(ContentError.unavailable(status)));
      expect((fixture.direct, fixture.browser), (1, 0));
    }
  });

  test('changing the site stops pending connection retries', () async {
    final fixture = RetryingCatalogFixture(
      directFailures: [NetworkErrorCode.secureConnectionFailed],
      browserFailures: [const NetworkError(NetworkErrorCode.networkConnectionLost)],
    );
    fixture.onBrowserRequest = () => MangaUrls.preferences.set('manga.site_address', 'other.example');
    await expectLater(fixture.transport().get(Uri.parse(MangaUrls.home), limit: 1024), throwsA(isA<CancellationError>()));
    expect((fixture.direct, fixture.browser), (1, 1));
  });
}
