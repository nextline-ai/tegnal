// Ported from native-ios/TEGNALTests/NativeContentTests.swift.
// Not ported here:
// - testBrowserRejectsUnsafeNavigationSchemesAndCredentials: EmbeddedBrowserModel is a platform screen (step 5).
// - testLocalizationCatalogsAndShareExtensionContainAllKeys: the string tables belong to the app shell.
// - testSearchVisibilityAccumulatesSlowScrollAndKeepsFocusedSearchVisible, testMonthDestinationsPreserveVisibleOrderAndCounts:
//   ScrollSearchVisibility and WorkMonthDestination are screen models.
// - testGalleryKeepsGroupsSeriesAndCharactersSoTheyCanBeSaved: only the parsed tags are checked here;
//   ArtworkTagGroup belongs to the work details screen (step 3).
// - testSpreadsRespectBoundariesAndLastPartialSpread, testTranslationCropUsesOriginalPixelsAndViewport,
//   testBoundedImageDecodeAndCache: reader and PageImageStore (step 3).
// - testCancelledGalleryParsingStopsBeforeDocumentWork, testCancellingOneGalleryConsumerReturnsWhileAnotherKeepsDownload,
//   testCancellingLastGalleryConsumerStopsDownloadAndAllowsRetry: Dart futures have no cooperative cancellation;
//   callers discard results instead.
// - The launch warmup and GalleryFeedLoader tests: screen models of the explore feed.
// - NativeContentLiveTests: opt-in tests against a live site.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/cdn_routing.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';

import 'content_test_support.dart';

final sampleHash = '${'0' * 61}abc';
const routing = '''
'use strict';
gg = { m: function(g) {
var o = 0;
switch (g) {
case 3243:
o = 1; break;
}
return o;
},
s: function(h) { var m = /(..)(.)\$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
b: '123456/'
};
''';

Uint8List galleryDocument(Map<String, Object?> json, {String suffix = ''}) => utf8.encode('var galleryinfo = ${jsonEncode(json)}$suffix');

NativeGallery work(int id, {String language = 'korean', List<GalleryVersion>? versions, List<String> tags = const []}) =>
    NativeGallery(id: id, title: 'Work $id', artists: const [], language: language, type: 'manga', tags: tags, pages: const [], versions: versions);

class _RelatedSource extends ContentProviding {
  @override
  Future<NativeGallery> gallery(int id) async {
    if (id == 404) throw ContentError.galleryNotFound;
    if (id == 5) await Future<void>.delayed(const Duration(milliseconds: 50));
    return NativeGallery(id: id, title: 'Work', artists: const [], language: 'korean', type: 'manga', tags: const [], pages: const []);
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async => Uint8List(0);
}

void main() {
  setUp(() => resetContent(site: 'comics.example'));

  test('language exceptions default off and persist into launch queries', () {
    final defaults = MemoryPreferences();
    final env = ContentEnvironment(browserPreferences: defaults);
    expect(env.allowsMangaLanguageExceptions, isFalse);
    expect(env.launchMangaQuery.allowsLanguageExceptions, isFalse);
    env.allowsMangaLanguageExceptions = true;
    final restored = ContentEnvironment(browserPreferences: defaults);
    expect(restored.allowsMangaLanguageExceptions, isTrue);
    expect(restored.launchMangaQuery.allowsLanguageExceptions, isTrue);
    restored.allowsMangaLanguageExceptions = false;
    expect(restored.launchMangaQuery.allowsLanguageExceptions, isFalse);
  });

  test('manga content controls persist hiding and artist exclusions without deleting saved works', () {
    final defaults = MemoryPreferences();
    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 1234, title: 'Saved work');
    final env = ContentEnvironment(browserPreferences: defaults);
    env.defaultExcludedTags = 'tag:excluded';
    env.setMangaGalleryHidden(1234, hidden: true);
    env.blockMangaArtist('Sample Artist');
    env.blockMangaArtist('sample artist');
    final restored = ContentEnvironment(browserPreferences: defaults);
    expect(restored.hiddenMangaGalleryIDs.contains(1234), isTrue);
    expect(restored.defaultExcludedTags, 'tag:excluded artist:Sample_Artist');
    expect(restored.launchMangaQuery.text.contains('-artist:Sample_Artist'), isTrue);
    expect(database.getWork(1234), isNotNull);
    restored.setMangaGalleryHidden(1234, hidden: false);
    expect(ContentEnvironment(browserPreferences: defaults).hiddenMangaGalleryIDs, isEmpty);
  });

  test('browser fallback is opt in and persists separately from legacy preference', () {
    final defaults = MemoryPreferences()..set('use_in_app_browser', true);
    final env = ContentEnvironment(browserPreferences: defaults);
    expect(env.useEmbeddedBrowser, isFalse);
    env.useEmbeddedBrowser = true;
    final restored = ContentEnvironment(browserPreferences: defaults);
    expect(restored.useEmbeddedBrowser, isTrue);
    restored.useEmbeddedBrowser = false;
    expect(ContentEnvironment(browserPreferences: defaults).useEmbeddedBrowser, isFalse);
    expect(defaults.boolean('use_in_app_browser'), isTrue);
  });

  test('category filter adds one type unless the search names one', () {
    expect(const GalleryQuery(text: 'female:sample').filteredTo('doujinshi').text, 'female:sample type:doujinshi');
    expect(const GalleryQuery(text: 'type:manga').filteredTo('doujinshi').text, 'type:manga');
    expect(const GalleryQuery().filteredTo('').text, '');
    expect(const GalleryQuery().filteredTo('unknown').text, '', reason: 'A category the site cannot filter by is ignored');
    final narrowed = const GalleryQuery().filteredTo('manga').applyingDefaults(tags: '', excluded: 'female:excluded');
    expect(narrowed.text, 'type:manga -female:excluded');
    expect(GalleryCategory.key('Artist CG'), 'artistcg');
    expect(GalleryCategory.key('non-h'), 'non-h');
    expect(GalleryCategory.title('unknown'), 'Unknown');
    expect(ContentEnvironment(browserPreferences: MemoryPreferences()).showsMangaCategories, isFalse, reason: 'Thumbnails show categories only once turned on');
  });

  test('tag completion preserves earlier terms and namespaces', () {
    final context = TagCompletionContext.parse('language:korean  -female:SA')!;
    expect(context.token, 'female:sa');
    expect(context.inserting(const TagSuggestion(namespace: 'female', name: 'sample tag', count: 42)), 'language:korean  -female:sample_tag ');
    for (final input in ['', 'a', 'female:', '12345', 'female:sa ', 'https://comics.example/reader/12345.html', 'unknown:sa', 'female:a:b']) {
      expect(TagCompletionContext.parse(input), isNull, reason: input);
    }
  });

  test('suggestions parse deduplicate and reject malformed rows', () {
    final rows = [
      ['sample tag', 42, 'female'],
      ['sample tag', 42, 'female'],
      ['sample tag', 12, 'male'],
      ['bad', -1, 'tag'],
      ['bad', 1, 'invalid'],
      ['incomplete'],
    ];
    final suggestions = TagSuggestion.parse(utf8.encode(jsonEncode(rows)));
    expect(suggestions.map((item) => item.token), ['female:sample_tag', 'male:sample_tag']);
    expect(() => TagSuggestion.parse(utf8.encode('{}')), throwsA(isA<ContentError>()));
    expect(() => TagSuggestion.parse(utf8.encode(jsonEncode(List.filled(101, rows[0])))), throwsA(isA<ContentError>()));
  });

  test('suggestion URL matches character index and policy', () {
    expect(MangaContentSource.suggestionURL('language:KO').toString(), 'https://tagindex.comics.example/language/k/o.json');
    expect(MangaContentSource.suggestionURL('a_b.c').path, '/global/a/_/b/dot/c.json');
    expect(() => MangaContentSource.suggestionURL('bad:aa'), throwsA(isA<ContentError>()));
    expect(ContentTransport.allows(MangaContentSource.suggestionURL('language:ko')), isTrue);
    expect(ContentTransport.allows(Uri.parse('https://tagindex.comics.example.evil.example/a')), isFalse);
  });

  test('suggestion cache avoids repeated network and skips short input', () async {
    final fetcher = FixtureFetcher((_) => FixtureReply.text(200, '[["korean",99947,"language"]]'));
    final source = MangaContentSource(transport: ContentTransport(fetcher: fetcher));
    final first = await source.suggestions('language:ko');
    final second = await source.suggestions('language:KO');
    final skipped = await source.suggestions('k');
    expect(first.map((item) => item.token), ['language:korean']);
    expect(first, second);
    expect(skipped, isEmpty);
    // The Swift count also depends on whether an earlier test left the site's discovery cooling down;
    // counting the suggestion host keeps the check independent of test order.
    expect(fetcher.requests.where((request) => request.url.host.startsWith('tagindex.')).length, 1);
  });

  test('gallery keeps groups series and characters so they can be saved', () {
    final json = {
      'title': 'Credits',
      'artists': [
        {'artist': 'painter'},
      ],
      'groups': [
        {'group': 'circle one'},
        {'group': ''},
      ],
      'parodys': [
        {'parody': 'some show'},
      ],
      'characters': [
        {'character': 'hero'},
      ],
      'tags': [
        {'tag': 'full color'},
      ],
      'files': [
        {'hash': sampleHash, 'name': '1.jpg'},
      ],
    };
    expect(NativeGallery.parse(galleryDocument(json), 7).tags, ['group:circle one', 'series:some show', 'character:hero', 'tag:full color']);
  });

  test('gallery reads its other languages and related works', () {
    final json = {
      'title': 'Linked',
      'language': 'english',
      'files': [
        {'hash': sampleHash, 'name': '1.jpg'},
      ],
      'languages': [
        {'galleryid': 7, 'name': 'english', 'language_localname': 'English'},
        {'galleryid': '8', 'name': 'korean', 'language_localname': '한국어'},
        {'galleryid': 8, 'name': 'korean'},
        {'galleryid': 9, 'name': 'japanese', 'language_localname': null},
        {'name': 'broken'},
      ],
      'related': [11, '12', 11, 0, 'nope'],
    };
    final gallery = NativeGallery.parse(galleryDocument(json), 7);
    expect(gallery.versions?.map((version) => version.id), [7, 8, 9], reason: 'Repeats and entries without a number are dropped');
    expect(gallery.relatedIDs, [11, 12]);
    expect(gallery.otherVersions('japanese').map((version) => version.displayName), [
      'Japanese',
      '한국어',
    ], reason: 'This work is left out and your language comes first');
    expect(gallery.suggestedVersion('korean')?.id, 8);
    expect(gallery.suggestedVersion('english'), isNull, reason: 'Nothing to suggest when this is already the language');
    expect(gallery.suggestedVersion('french'), isNull);
  });

  test('alternates are optional in a work already downloaded', () {
    const saved = '{"id":1,"title":"Old","artists":[],"language":"","type":"","tags":[],"pages":[]}';
    final gallery = NativeGallery.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(gallery.versions, isNull);
    expect(gallery.relatedIDs, isNull);
    expect(gallery.otherVersions('korean'), isEmpty);
  });

  test('default exclusions apply to a work loaded directly', () {
    const gallery = NativeGallery(
      id: 1,
      title: 'Summer Trip',
      artists: ['some_artist'],
      language: 'korean',
      type: 'manga',
      tags: ['female:long hair', 'group:circle one', 'tag:full color'],
      pages: [],
    );
    for (final term in [
      'female:long_hair',
      '-female:long_hair',
      'artist:Some_Artist',
      'group:circle_one',
      'full_color',
      'summer',
      'type:manga',
      'a b language:korean',
    ]) {
      expect(gallery.isExcluded(term), isTrue, reason: term);
    }
    for (final term in ['', '-', 'female:short_hair', 'male:long_hair', 'tag:long_hair', 'winter', 'language:japanese']) {
      expect(gallery.isExcluded(term), isFalse, reason: term);
    }
  });

  test('related works keep order and skip what should not show', () {
    const korean = GalleryVersion(id: 2, language: 'korean'), japanese = GalleryVersion(id: 3, language: 'japanese');
    final current = work(
      1,
      versions: const [
        GalleryVersion(id: 1, language: 'korean'),
        GalleryVersion(id: 4, language: 'english'),
      ],
    );
    const translated = GalleryVersion(id: 21, language: 'korean'), raw = GalleryVersion(id: 20, language: 'japanese');
    final works = [
      work(10),
      work(4, language: 'english'),
      work(30, tags: ['tag:skip me']),
      work(40),
      work(20, language: 'japanese', versions: [raw, translated]),
      work(21, versions: [raw, translated]),
      work(3, language: 'japanese', versions: [japanese, korean]),
    ];
    expect(RelatedWorks.select(works, current, hidden: {40}, excluded: 'tag:skip_me'), [
      10,
      21,
      2,
    ], reason: "Order stays, this work's other languages go, hidden and excluded works go, and each work appears once in the reader's language");
    expect(
      RelatedWorks.select(
        [
          work(3, language: 'japanese', versions: [japanese, korean]),
        ],
        current,
        hidden: {2},
        excluded: '',
      ),
      isEmpty,
    );
  });

  test('related works outlive a work that fails to load', () async {
    const gallery = NativeGallery(id: 1, title: 'Work', artists: [], language: 'korean', type: 'manga', tags: [], pages: [], relatedIDs: [5, 404, 6]);
    final ids = await RelatedWorks.load(gallery, _RelatedSource(), hidden: {}, excluded: '');
    expect(ids, [5, 6], reason: 'The slower work keeps its place');
  });

  test('gallery parses entities and preserves pages', () {
    final json = {
      'title': 'A &amp; B &#x1F4D6;',
      'japanese_title': '',
      'files': [
        {'hash': sampleHash, 'name': 'page.png', 'width': 800, 'height': 1200, 'hasavif': 1},
      ],
    };
    final text = 'var galleryinfo = ${jsonEncode(json)};';
    final gallery = NativeGallery.parse(utf8.encode(text), 1234);
    expect(gallery.title, 'A & B 📖');
    expect(gallery.pages.first.width, 800);
    expect(gallery.pages.first.hasAVIF, isTrue);
    expect(() => NativeGallery.parse(utf8.encode('${text}doSomething();'), 1234), throwsA(isA<ContentError>()));
    expect(() => NativeGallery.parse(utf8.encode('bad {"files":[]}'), 1234), throwsA(isA<ContentError>()));
  });

  test('tag namespaces accept string and numeric flags', () {
    final json = {
      'title': 'Fixture',
      'files': [
        {'hash': sampleHash, 'name': 'page.png'},
      ],
      'tags': [
        {'tag': 'cat', 'female': '1', 'male': ''},
        {'tag': 'dog', 'male': 1},
        {'tag': 'bird', 'female': true},
        {'tag': 'general', 'female': '0'},
        {'tag': 'both', 'male': '1', 'female': 1},
      ],
    };
    expect(NativeGallery.parse(galleryDocument(json), 1).tags, ['female:cat', 'male:dog', 'female:bird', 'tag:general', 'female:both', 'male:both']);
  });

  test('routing uses current shard and epoch', () {
    final value = CDNRouting(routing);
    final full = value.url(hash: sampleHash, format: 'webp', thumbnail: false);
    expect(full.host, 'w2.comics.example');
    expect(full.path, '/123456/3243/$sampleHash.webp');
    final thumb = value.url(hash: sampleHash, format: 'webp', thumbnail: true);
    expect(thumb.host, 'btn.comics.example');
    expect(thumb.path, '/webpsmalltn/c/ab/$sampleHash.webp');
    expect(() => CDNRouting('${routing}unexpectedCode();'), throwsA(isA<ContentError>()));
    expect(() => value.url(hash: '../invalid', format: 'webp', thumbnail: false), throwsA(isA<ContentError>()));
  });

  test('request policy rejects foreign hosts and credentials', () {
    resetContent(site: 'custom-comics.example');
    for (final raw in [
      'http://w1.custom-comics.example/a',
      'https://w1.custom-comics.example.evil.example/a',
      'https://user@w1.custom-comics.example/a',
      'https://example.com/',
      'https://custom-comics.example.evil.example/',
      'https://user@custom-comics.example/',
      'http://custom-comics.example/',
    ]) {
      expect(ContentTransport.allows(Uri.parse(raw)), isFalse, reason: raw);
    }
    expect(ContentTransport.allows(Uri.parse('https://custom-comics.example/')), isTrue);
    expect(ContentTransport.allows(Uri.parse('https://tagindex.custom-comics.example/a')), isTrue);
    expect(ContentTransport.allows(Uri.parse('https://a2.custom-comics.example/a')), isTrue);
  });

  test('reader routes use trusted host and page', () {
    expect(ContentRoute.initial('https://comics.example/reader/12345.html#7'), const ReaderRoute(12345, 7));
    expect(ContentRoute.initial('https://comics.example/artist/a%20b-all.html'), const ArtistRoute('a b'));
    expect(ContentRoute.initial('https://evil.example/reader/12345.html'), isNull);
  });

  test('range requires exact offsets', () {
    final response = ContentResponse(
      url: Uri.parse('https://ltn.comics.example/index-korean.nozomi'),
      statusCode: 206,
      headers: {
        'Content-Range': ['bytes 4-11/100'],
      },
    );
    expect(MangaContentSource.validateRange(response, start: 4, received: 8), 100);
    expect(() => MangaContentSource.validateRange(response, start: 0, received: 8), throwsA(isA<ContentError>()));
    expect(() => MangaContentSource.validateRange(response, start: 4, received: 7), throwsA(isA<ContentError>()));
  });

  test('binary data rejects truncation and overflow', () {
    expect(BinaryCursor.ids(Uint8List.fromList([0, 0, 4, 0, 0, 0, 8, 0])), [1024, 2048]);
    expect(() => BinaryCursor.ids(Uint8List.fromList([0, 0, 1])), throwsA(isA<ContentError>()));
    expect(() => BinaryCursor.ids(Uint8List.fromList([0, 0, 0, 0])), throwsA(isA<ContentError>()));
    expect(() => BinaryCursor(Uint8List.fromList(List.filled(8, 255))).u64(), throwsA(isA<ContentError>()));
    expect(() => SearchIndexNode(Uint8List.fromList([0, 0, 0, 1])), throwsA(isA<ContentError>()));
  });

  test('binary IDs decode sliced data and unsigned values', () {
    final sliced = Uint8List.sublistView(Uint8List.fromList([99, 99, 0, 0, 0, 1, 255, 255, 255, 255]), 2);
    expect(BinaryCursor.ids(sliced), [1, 4294967295]);
    expect(BinaryCursor.ids(Uint8List(0)), isEmpty);
    final data = ByteData(100000 * 4);
    for (var index = 0; index < 100000; index++) {
      data.setUint32(index * 4, index + 1);
    }
    expect(BinaryCursor.ids(data.buffer.asUint8List()), [for (var index = 1; index <= 100000; index++) index]);
  });

  test('gallery hash validation preserves lowercase ASCII and page order', () {
    final hash = '0123456789abcdef' * 4;
    final files = [
      for (var index = 0; index < 96; index++) {'hash': hash, 'name': '$index.jpg'},
    ];
    final gallery = NativeGallery.parse(galleryDocument({'title': 'Pages', 'files': files}), 1);
    expect(gallery.pages.map((page) => page.name), [for (var index = 0; index < 96; index++) '$index.jpg']);
    expect(gallery.pages.every((page) => page.hash == hash), isTrue);
    for (final invalid in [hash.substring(0, 63), '${hash}a', hash.toUpperCase(), 'g' * 64, 'é' * 32]) {
      final document = galleryDocument({
        'files': [
          {'hash': invalid, 'name': '1.jpg'},
        ],
      });
      expect(() => NativeGallery.parse(document, 1), throwsA(ContentError.unsupportedFormat));
    }
  });

  test('entity decoder preserves unicode and unknown entities', () {
    expect(NativeGallery.decodeEntities('제목 📖'), '제목 📖');
    expect(NativeGallery.decodeEntities('&#x1F4D6; &amp; &#65; &unknown; &#xD800; &amp;lt;'), '📖 & A &unknown; &#xD800; &lt;');
    expect(NativeGallery.decodeEntities('&quot;&apos;&nbsp;&lt;&gt;'), '"\' <>');
  });

  test('gallery metadata consumers share one download and cached result', () async {
    const id = 12345678;
    final pending = <Completer<FixtureReply>>[];
    final fetcher = FixtureFetcher((request) {
      final last = request.url.pathSegments.lastOrNull ?? '';
      if (int.tryParse(last.replaceAll('.js', '')) != id) throw const NetworkError(NetworkErrorCode.cancelled);
      final completer = Completer<FixtureReply>();
      pending.add(completer);
      return completer.future;
    });
    final source = MangaContentSource(transport: ContentTransport(fetcher: fetcher));
    final first = source.gallery(id), second = source.gallery(id);
    await waitFor(() => source.galleryConsumerCount(id) == 2 && pending.length == 1);
    final hash = 'a' * 64;
    pending.single.complete(
      FixtureReply.text(200, 'var galleryinfo = {"title":"Shared metadata","files":[{"hash":"$hash","name":"1.jpg","width":100,"height":150}]};', {
        'Content-Type': 'application/javascript',
      }),
    );
    final a = await first, b = await second;
    expect(a.id, b.id);
    expect(a.title, 'Shared metadata');
    expect(a.pages.length, 1);
    expect(source.cachedGallery(id), isNotNull);
    await source.gallery(id);
    expect(pending.length, 1, reason: 'Concurrent cards and detail views should download and parse metadata once');
  });
}
