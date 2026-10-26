import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/core/content_filter.dart';

class FakeSource implements ContentSource {
  final calls = <Completer<ContentPage>>[];
  final requestedPages = <int>[];
  String sourceId = '';
  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) {
    final c = Completer<ContentPage>();
    calls.add(c);
    requestedPages.add(page);
    return c.future;
  }

  @override
  void close() {}
  @override
  Future<ContentItem> detail(int id) async => ContentItem(
    sourceId: sourceId,
    id: id,
    mode: AppMode.manga,
    title: 'Resolved',
  );
  @override
  Future<List<ReaderPage>> pages(ContentItem item) async {
    if (item.sourceId != sourceId) throw StateError('Wrong source');
    return [ReaderPage(url: Uri.parse('https://example.test/page'))];
  }

  @override
  Future<List<String>> suggestions(String query) async => [];
}

void main() {
  test('multi-server retries preserve each successful source cursor', () async {
    final store = LibraryStore.memory();
    final fakes = <String, FakeSource>{};
    final c = AppController(
      store,
      sourceFactory: (s) => fakes.putIfAbsent(s.id, FakeSource.new),
    );
    addTearDown(() {
      c.dispose();
      store.close();
    });
    final one = c.addSource('https://one.test', SourceKind.danbooru);
    final two = c.addSource('https://two.test', SourceKind.moebooru);
    c.setMode(AppMode.booru);
    c.selectSources([one, two]);
    final first = c.search(query: 'test');
    fakes[one.id]!.calls[0].complete(
      ContentPage([
        ContentItem(sourceId: one.id, id: 1, mode: AppMode.booru, title: 'One'),
      ], hasMore: true),
    );
    fakes[two.id]!.calls[0].completeError(
      const ContentException('Unavailable'),
    );
    await first;
    expect(c.explore().items, hasLength(1));
    expect(c.explore().error, contains('two.test'));
    final retry = c.search(more: true);
    expect(fakes[one.id]!.requestedPages, [1, 2]);
    expect(fakes[two.id]!.requestedPages, [1, 1]);
    fakes[one.id]!.calls[1].complete(const ContentPage([], hasMore: false));
    fakes[two.id]!.calls[1].complete(
      ContentPage([
        ContentItem(sourceId: two.id, id: 1, mode: AppMode.booru, title: 'Two'),
      ], hasMore: false),
    );
    await retry;
    expect(c.explore().items, hasLength(2));
    expect(c.explore().hasMore, isFalse);
    expect(c.explore().error, isNull);
  });
  test('canonical connections stay unique and removed connections remain exportable', () {
    final store = LibraryStore.memory();
    final c = AppController(store, sourceFactory: (_) => FakeSource());
    addTearDown(() {
      c.dispose();
      store.close();
    });
    final a = c.addSource(
      'https://example.test/index.php',
      SourceKind.gelbooru,
    );
    final b = c.addSource('https://example.test/', SourceKind.oldGelbooru);
    expect(a.id, b.id);
    expect(c.sources(AppMode.booru), hasLength(1));
    c.save(
      ContentItem(sourceId: b.id, id: 1, mode: AppMode.booru, title: 'Saved'),
    );
    c.removeSource(b);
    expect(c.sources(AppMode.booru), isEmpty);
    final exported = jsonDecode(BackupCodec(store).exportJson()) as Map;
    expect(exported['images']['favorites'], hasLength(1));
    expect(exported['images']['servers'], hasLength(1));
  });
  test('imported comics resolve selected source before reader pages and restoration cancels stale feeds', () async {
    final store = LibraryStore.memory();
    final fake = FakeSource();
    final c = AppController(store, sourceFactory: (_) => fake);
    addTearDown(() {
      c.dispose();
      store.close();
    });
    final source = c.addSource('https://example.test', SourceKind.manga);
    fake.sourceId = source.id;
    expect(
      await c.pages(
        const ContentItem(
          sourceId: '',
          id: 42,
          mode: AppMode.manga,
          title: 'Imported',
        ),
      ),
      hasLength(1),
    );
    final pending = c.search(query: 'before');
    c.libraryRestored();
    fake.calls.single.complete(const ContentPage([], hasMore: true));
    await pending;
    expect(c.explore().page, 0);
    expect(c.explore().loading, isFalse);
  });
  test(
    'blacklist uses native line, exclusion, wildcard and rating semantics',
    () {
      const item = ContentItem(
        sourceId: 's',
        id: 7,
        mode: AppMode.booru,
        title: 'test',
        tags: ['blue_hair', 'solo'],
        artists: ['artist'],
        metadata: {'rating': 'g'},
      );
      expect(ContentFilter('blue_hair duo').contains(item), isFalse);
      expect(ContentFilter('# comment\nblue* -duo').contains(item), isTrue);
      expect(
        ContentFilter('rating:safe artist:artist id:7').contains(item),
        isTrue,
      );
      expect(ContentFilter('rating:explicit').contains(item), isFalse);
    },
  );
  test(
    'late response cannot overwrite newer query or a changed server',
    () async {
      final store = LibraryStore.memory();
      final fake = FakeSource();
      final c = AppController(store, sourceFactory: (_) => fake);
      addTearDown(() {
        c.dispose();
        store.close();
      });
      final source = c.addSource('https://example.test', SourceKind.danbooru);
      c.setMode(AppMode.booru);
      final old = c.search(query: 'old');
      final fresh = c.search(query: 'fresh');
      final item = ContentItem(
        sourceId: source.id,
        id: 1,
        mode: AppMode.booru,
        title: 'Fresh',
      );
      fake.calls[1].complete(ContentPage([item], hasMore: true));
      await fresh;
      fake.calls[0].complete(const ContentPage([], hasMore: false));
      await old;
      expect(c.explore().items.single.title, 'Fresh');
      expect(c.explore().query, 'fresh');
      final more = c.search(more: true);
      c.addSource('https://other.test', SourceKind.danbooru);
      fake.calls[2].complete(ContentPage([item], hasMore: false));
      await more;
      expect(c.explore().items, isEmpty);
      expect(c.explore().loading, isFalse);
    },
  );
  test('mode switch keeps search state while AI downloads are off', () {
    final store = LibraryStore.memory();
    final c = AppController(store, sourceFactory: (_) => FakeSource());
    addTearDown(() {
      c.dispose();
      store.close();
    });
    c.explore(AppMode.manga).query = 'artist:test';
    c.setMode(AppMode.booru);
    expect(c.explore().query, isEmpty);
    c.setMode(AppMode.manga);
    expect(c.explore().query, 'artist:test');
    expect(c.ai.allowsModelDownload, isFalse);
  });
}
