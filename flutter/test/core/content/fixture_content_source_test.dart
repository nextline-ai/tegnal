// The offline source the explore screens run on, matching the native FixtureContentSource.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_urls.dart';

import 'content_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetContent);

  test('the fixture environment connects the sample site offline', () {
    final environment = ContentEnvironment.fixture();
    expect(environment.isSiteVerified, isTrue);
    expect(environment.mangaSiteAddress, 'comics.example');
    expect(MangaUrls.home, 'https://comics.example/');
    expect(environment.source, isA<FixtureContentSource>());
  });

  test('the default fixture lists one work with three pages', () async {
    final source = FixtureContentSource();
    expect((await source.list(const GalleryQuery(), offset: 0, count: 24)).ids, [900000001]);
    expect((await source.list(const GalleryQuery(), offset: 24, count: 24)).ids, isEmpty);
    final gallery = await source.gallery(900000001);
    expect(gallery.title, '네이티브 읽기 테스트');
    expect(gallery.type, 'manga');
    expect(gallery.pages.map((page) => page.name), ['1.png', '2.png', '3.png']);
  });

  test('the long feed pages through 120 works and filters by category', () async {
    final source = FixtureContentSource(options: {FixtureOption.longFeed});
    final first = await source.list(const GalleryQuery(), offset: 0, count: 24);
    expect(first.ids.first, 900000001);
    expect(first.hasMore, isTrue);
    final manga = await source.list(const GalleryQuery(text: 'type:manga'), offset: 0, count: 100);
    expect(manga.ids.length, 24);
    expect(manga.ids.every((id) => FixtureContentSource.categories[id % 5] == 'manga'), isTrue);
  });

  test('the initial error fails once, then loads', () async {
    final source = FixtureContentSource(options: {FixtureOption.initialError});
    await expectLater(source.list(const GalleryQuery(), offset: 0, count: 24), throwsA(const NetworkError(NetworkErrorCode.notConnectedToInternet)));
    expect((await source.list(const GalleryQuery(), offset: 0, count: 24)).ids, [900000001]);
  });

  test('pages are drawn as decodable images', () async {
    final source = FixtureContentSource();
    final gallery = await source.gallery(900000001);
    final data = await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true);
    final frame = await (await ui.instantiateImageCodec(Uint8List.fromList(data))).getNextFrame();
    expect((frame.image.width, frame.image.height), (800, 1200));
    expect(source.imageRequests, 1);
  });

  test('suggestions answer the sample prefix only', () async {
    final source = FixtureContentSource();
    expect(await source.suggestions('female:sa'), [const TagSuggestion(namespace: 'female', name: 'sample tag', count: 42)]);
    expect(await source.suggestions('female:x'), isEmpty);
  });
}
