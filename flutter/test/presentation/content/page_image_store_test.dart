// Page image loading, caching and prefetch from native-ios/TEGNALTests/ReaderUXTests.swift.
// The GalleryFeedLoader tests of that file (testRefresh…, testNewFilterRejectsLateResults…,
// testPagination…, testCanceling…Card…, testEvictedPreview…, testPreparedCoverWindow…,
// testOffscreenCard…, testFeedPublishes…, testOffscreenFeedText…, testFeedAppend…,
// testAllPrefetchWorkersBlocked…, testPrefetchPrioritizes…, testReverseScroll…, testFilterChange…,
// testUnavailableCover…, testFeedRetains…, testHiddenFeedStops…) cover the Explore feed loader,
// which lives with the Explore screen (lib/presentation/content/gallery_feed_loader.dart).
// testOCRFindsSyntheticPageText needs on-device text recognition (translation).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/presentation/content/page_image_store.dart';

/// `CountingContentSource`: fixture works whose image requests take 150 ms and are counted.
class CountingContentSource extends ContentProviding {
  final _fixture = FixtureContentSource();
  int requests = 0;

  @override
  Future<NativeGallery> gallery(int id) => _fixture.gallery(id);
  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) => _fixture.list(query, offset: offset, count: count);
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    requests += 1;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return _fixture.image(page, galleryID: galleryID, thumbnail: thumbnail);
  }
}

/// `ReaderTurnSource`: twelve pages whose downloads wait until released (page 0 is released).
class ReaderTurnSource extends ContentProviding {
  ReaderTurnSource(this.data);
  final Uint8List data;
  final _counts = <int, int>{};
  final _pending = <int, List<Completer<Uint8List>>>{};
  final _released = <int>{0};
  int maximumConcurrent = 0;

  int get activeCount => _pending.values.fold(0, (sum, list) => sum + list.length);
  int requests(int page) => _counts[page] ?? 0;

  @override
  Future<NativeGallery> gallery(int id) async => NativeGallery(
    id: id,
    title: 'Reader turns',
    artists: const [],
    language: 'korean',
    type: 'manga',
    tags: const [],
    pages: [
      for (var index = 0; index < 12; index++)
        GalleryPage(hash: (index + 100).toRadixString(16).padLeft(64, '0'), name: '$index.png', width: 800, height: 1200, hasAVIF: false),
    ],
  );
  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) {
    final index = int.parse(page.name.split('.').first);
    _counts[index] = requests(index) + 1;
    if (_released.contains(index)) return Future.value(data);
    final completer = Completer<Uint8List>();
    _pending.putIfAbsent(index, () => []).add(completer);
    if (activeCount > maximumConcurrent) maximumConcurrent = activeCount;
    return completer.future;
  }

  void release(int page) {
    _released.add(page);
    for (final completer in _pending.remove(page) ?? const <Completer<Uint8List>>[]) {
      completer.complete(data);
    }
  }

  void releaseAll() {
    for (var page = 0; page < 12; page++) {
      release(page);
    }
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Reader request did not reach the expected state');
}

Future<Uint8List> _sampleData() async {
  final fixture = FixtureContentSource();
  final sample = await fixture.gallery(1);
  return fixture.image(sample.pages[0], galleryID: sample.id, thumbnail: false);
}

void main() {
  test('concurrent loads share download and decoded image', () async {
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final store = PageImageStore(source: source);
    final pair = await Future.wait([store.load(gallery.pages[0], galleryID: 1), store.load(gallery.pages[0], galleryID: 1)]);
    expect(identical(pair[0], pair[1]), isTrue);
    expect(source.requests, 1);
  });

  test('prefetch eliminates next page download', () async {
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final store = PageImageStore(source: source);
    await store.prefetch(gallery, current: 0, count: 2);
    final before = source.requests;
    await store.load(gallery.pages[1], galleryID: 1);
    expect(before, 3);
    expect(source.requests, before);
  });

  test('prefetch bounds incomplete final spread and disabled setting', () {
    expect(PageImageStore.prefetchIndices(total: 5, current: 4, count: 3, visibleCount: 4), [4, 3]);
    expect(PageImageStore.prefetchIndices(total: 6, current: 4, count: 3, visibleCount: 4), [4, 3]);
    expect(PageImageStore.prefetchIndices(total: 8, current: 0, count: 2, visibleCount: 4), [0, 4, 5]);
    expect(PageImageStore.prefetchIndices(total: 8, current: 0, count: 0), <int>[]);
    expect(PageImageStore.prefetchIndices(total: 0, current: 0, count: 3), <int>[]);
    expect(PageImageStore.prefetchIndices(total: 5, current: 5, count: 3), <int>[]);
    expect(PageImageStore.prefetchIndices(total: 5, current: 4, count: 9223372036854775807), [4, 3]);
  });

  test('energy policy skips speculation but still loads requested page', () async {
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final store = PageImageStore(source: source, allowsPrefetch: () => false);
    await store.prefetch(gallery, current: 0, count: 3);
    expect(source.requests, 0);
    await store.load(gallery.pages[0], galleryID: 1);
    expect(source.requests, 1);
  });

  test('disk page cache survives store recreation without download', () async {
    final directory = Directory.systemTemp.createTempSync('tegnal-pages-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final firstStore = PageImageStore(source: source, diskDirectory: directory);
    await Future.wait([firstStore.load(gallery.pages[0], galleryID: 1), firstStore.load(gallery.pages[0], galleryID: 1)]);
    final secondStore = PageImageStore(source: source, diskDirectory: directory);
    final restored = await secondStore.load(gallery.pages[0], galleryID: 1);
    expect(restored.width, greaterThan(0));
    expect(source.requests, 1);
    expect(directory.listSync().length, 1);
  });

  test('cancelling one consumer keeps shared download alive', () async {
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final store = PageImageStore(source: source);
    final first = store.request(gallery.pages[0], galleryID: 1);
    final second = store.request(gallery.pages[0], galleryID: 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.cancel();
    await expectLater(first.image, throwsA(isA<CancellationError>()), reason: 'Cancelled consumer must not receive an image');
    await second.image;
    expect(source.requests, 1);
  });

  test('reader starts with cached thumbnail and distinguishes full resolution', () async {
    final source = CountingContentSource();
    final gallery = await source.gallery(1);
    final page = gallery.pages[0];
    final images = PageImageStore(source: source);
    final thumbnail = await images.load(page, galleryID: gallery.id, thumbnail: true);
    final preview = ReaderPageImage.cached(page.hash, images)!;
    expect(identical(preview.image, thumbnail), isTrue);
    expect(preview.satisfies(page.hash), isFalse, reason: 'A cached preview must still upgrade to full resolution');
    final fullImage = await images.load(page, galleryID: gallery.id);
    final full = ReaderPageImage.cached(page.hash, images)!;
    expect(identical(full.image, fullImage), isTrue, reason: 'Prefer a decoded full page over its thumbnail');
    expect(full.satisfies(page.hash), isTrue, reason: 'Retained full pixels need no reload after lifecycle changes');
    expect(full.satisfies('another-page'), isFalse);
    expect(source.requests, 2);
  });

  test('page turn keeps the next download across prefetch windows', () async {
    final source = ReaderTurnSource(await _sampleData());
    final gallery = await source.gallery(7);
    final images = PageImageStore(source: source, allowsPrefetch: () => true);
    final prefetcher = ReaderPagePrefetcher();
    addTearDown(prefetcher.cancel);
    prefetcher.update(gallery: gallery, images: images, current: 0, count: 3);
    await _waitFor(() => source.requests(1) == 1);
    // The screen replaces its page request before the newly visible page attaches.
    prefetcher.update(gallery: gallery, images: images, current: 1, count: 3);
    final visible = images.load(gallery.pages[1], galleryID: gallery.id);
    await _waitFor(() => images.consumerCount(gallery.pages[1].hash) == 2);
    source.release(1);
    await visible;
    expect(source.requests(1), 1);
    source.releaseAll();
  });

  test('rolling prefetch keeps its concurrency bound during fast turns', () async {
    final source = ReaderTurnSource(await _sampleData());
    final gallery = await source.gallery(7);
    final images = PageImageStore(source: source, allowsPrefetch: () => true);
    final prefetcher = ReaderPagePrefetcher();
    addTearDown(prefetcher.cancel);
    prefetcher.update(gallery: gallery, images: images, current: 0, count: 3);
    await _waitFor(() => source.requests(3) == 1);
    prefetcher.update(gallery: gallery, images: images, current: 1, count: 3);
    prefetcher.update(gallery: gallery, images: images, current: 2, count: 3);
    source.release(2);
    await _waitFor(() => source.requests(4) == 1);
    expect(source.requests(5), 0, reason: 'Nearby in-flight requests retain the three speculative slots');
    expect(source.maximumConcurrent, lessThanOrEqualTo(3));
    for (var page = 1; page <= 3; page++) {
      expect(source.requests(page), 1);
    }
    prefetcher.cancel();
    expect(prefetcher.activeIndices, isEmpty);
    source.releaseAll();
  });

  test('visible spread loads before starting more speculation', () async {
    final source = ReaderTurnSource(await _sampleData());
    final gallery = await source.gallery(7);
    final images = PageImageStore(source: source, allowsPrefetch: () => true);
    final prefetcher = ReaderPagePrefetcher();
    addTearDown(prefetcher.cancel);
    prefetcher.update(gallery: gallery, images: images, current: 0, count: 3, visibleCount: 2);
    await _waitFor(() => source.requests(1) == 1);
    expect(source.requests(2), 0, reason: 'The second visible page gets priority over future pages');
    source.release(1);
    await _waitFor(() => source.requests(2) == 1);
    prefetcher.cancel();
    source.releaseAll();
  });

  test('dismissing prefetch stops unused work and keeps a visible consumer', () async {
    final source = ReaderTurnSource(await _sampleData());
    final gallery = await source.gallery(7);
    final images = PageImageStore(source: source, allowsPrefetch: () => true);
    final prefetcher = ReaderPagePrefetcher();
    addTearDown(prefetcher.cancel);
    prefetcher.update(gallery: gallery, images: images, current: 0, count: 3);
    await _waitFor(() => source.requests(3) == 1);
    final visible = images.load(gallery.pages[1], galleryID: gallery.id);
    await _waitFor(() => images.consumerCount(gallery.pages[1].hash) == 2);
    prefetcher.cancel();
    expect(images.consumerCount(gallery.pages[1].hash), 1, reason: 'The visible page keeps its own consumer');
    expect(images.consumerCount(gallery.pages[2].hash), 0);
    source.release(1);
    await visible;
    expect(source.requests(1), 1);
    source.releaseAll();
  });
}
