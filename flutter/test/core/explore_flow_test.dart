import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';

class _SortedSource implements ContentSource, SortedContentSource {
  BooruSort? reject;
  final requested = <BooruSort>[];
  @override
  Future<ContentPage> searchSorted(
    String query, {
    int page = 1,
    BooruSort sort = BooruSort.latest,
  }) async {
    requested.add(sort);
    if (sort == reject) throw UnsupportedBooruSort(sort);
    return ContentPage([
      ContentItem(
        sourceId: 'fixture',
        id: page,
        mode: AppMode.booru,
        title: query,
      ),
    ], hasMore: true);
  }

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) => searchSorted(
    query,
    page: page,
    sort: popular ? BooruSort.popular : BooruSort.latest,
  );
  @override
  void close() {}
  @override
  Future<ContentItem> detail(int id) => throw UnimplementedError();
  @override
  Future<List<ReaderPage>> pages(ContentItem item) =>
      throw UnimplementedError();
  @override
  Future<List<String>> suggestions(String query) async => [];
}

void main() {
  late LibraryStore store;
  late AppController controller;
  late _SortedSource source;
  setUp(() {
    store = LibraryStore.memory();
    source = _SortedSource();
    controller = AppController(store, sourceFactory: (_) => source);
    controller.addSource('https://example.test', SourceKind.danbooru);
    controller.setMode(AppMode.booru);
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });

  test(
    'explicit empty server selection persists and never starts a request',
    () async {
      controller.selectSources([]);
      expect(controller.selectedSources(), isEmpty);
      await controller.search();
      expect(source.requested, isEmpty);
      final reloaded = AppController(store, sourceFactory: (_) => source);
      expect(reloaded.selectedSources(), isEmpty);
      reloaded.dispose();
    },
  );

  test(
    'sort remains selected across pagination and rejected sort restores feed',
    () async {
      await controller.search(query: 'sky', booruSort: BooruSort.mostFavorited);
      await controller.search(more: true);
      expect(source.requested, [
        BooruSort.mostFavorited,
        BooruSort.mostFavorited,
      ]);
      source.reject = BooruSort.trending;
      await controller.search(booruSort: BooruSort.trending);
      final state = controller.explore();
      expect(state.booruSort, BooruSort.mostFavorited);
      expect(state.items.map((item) => item.id), [1, 2]);
      expect(state.page, 2);
      expect(state.loading, isFalse);
      expect(state.error, contains('do not support'));
      await controller.search(more: true);
      expect(state.items.map((item) => item.id), [1, 2, 3]);
    },
  );

  test(
    'changing to an engine with fewer sorts resets an unsupported choice',
    () async {
      await controller.search(booruSort: BooruSort.trending);
      controller.addSource('https://other.test', SourceKind.moebooru);
      expect(controller.explore().booruSort, BooruSort.latest);
      expect(controller.explore().items, isEmpty);
    },
  );
}
