import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/explore_screen.dart';
import 'package:tegnal/ui/content_tile.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  late _FakeBooruSource source;

  setUp(() {
    store = LibraryStore.memory();
    source = _FakeBooruSource();
    controller = AppController(store, sourceFactory: (_) => source);
    final config = SourceConfig(
      id: 'booru',
      name: 'Booru',
      baseUrl: Uri.https('booru.invalid'),
      kind: SourceKind.danbooru,
    );
    store.saveSource(config);
    controller.selectSource(config);
  });

  tearDown(() {
    controller.dispose();
    store.database.close();
  });

  Future<void> pumpExplore(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: ExploreScreen(
          controller: controller,
          mode: AppMode.booru,
          onOpen: (_) {},
          onConnect: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tag suggestion edits the active token without submitting', (
    tester,
  ) async {
    await pumpExplore(tester);
    final field = find.byKey(const ValueKey('explore.search'));
    await tester.tap(field);
    await tester.enterText(field, 'artist:alice sky');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('sky_blue'));
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(field);
    expect(input.controller!.text, 'artist:alice sky_blue ');
    expect(input.focusNode!.hasFocus, isTrue);
    expect(source.searchCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused empty search supports saved and clear-history flow', (
    tester,
  ) async {
    store.recordSearch(AppMode.booru, 'booru', 'landscape blue');
    await pumpExplore(tester);
    final field = find.byKey(const ValueKey('explore.search'));
    await tester.tap(field);
    await tester.pumpAndSettle();

    expect(find.text('Search History'), findsOneWidget);
    expect(find.text('landscape blue'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.star_border));
    await tester.pumpAndSettle();
    expect(
      store.portable('backup.images')!['savedTags'],
      contains(
        allOf(
          containsPair('serverID', 'booru'),
          containsPair('kind', 'search'),
          containsPair('name', 'landscape blue'),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Clear History'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Clear History'),
      ),
    );
    await tester.pumpAndSettle();

    expect(store.history(AppMode.booru), isEmpty);
    expect(find.text('landscape blue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating search control returns after scrolling the feed', (
    tester,
  ) async {
    source.itemCount = 40;
    await controller.search(query: 'blue', forMode: AppMode.booru);
    await pumpExplore(tester);
    final field = find.byKey(const ValueKey('explore.search'));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
    await tester.pumpAndSettle();
    await tester.tap(field);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long press bookmarks without a per-work overflow button', (
    tester,
  ) async {
    source.itemCount = 1;
    await controller.search(forMode: AppMode.booru);
    await pumpExplore(tester);
    final tile = find.byType(ContentTile);

    await tester.longPress(tile);
    await tester.pump();
    final item = controller.explore(AppMode.booru).items.single;
    expect(controller.isSaved(item), isTrue);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Open'), findsNothing);

    expect(find.byTooltip('More'), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _FakeBooruSource implements ContentSource {
  int searchCalls = 0;
  int itemCount = 0;

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async {
    searchCalls++;
    return ContentPage([
      for (var id = 1; id <= itemCount; id++)
        ContentItem(
          sourceId: 'booru',
          id: id,
          mode: AppMode.booru,
          title: 'Post $id',
        ),
    ], hasMore: false);
  }

  @override
  Future<ContentItem> detail(int id) => throw UnimplementedError();

  @override
  void close() {}

  @override
  Future<List<ReaderPage>> pages(ContentItem item) =>
      throw UnimplementedError();

  @override
  Future<List<String>> suggestions(String query) async => ['sky_blue'];
}
