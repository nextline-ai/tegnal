import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/reader_screen.dart';
import 'package:tegnal/ui/design_system.dart';

class _LocalReaderSource implements ContentSource {
  _LocalReaderSource(this.pagesByID);
  final Map<int, List<ReaderPage>> pagesByID;
  final Map<int, int> pageCalls = {};

  @override
  Future<List<ReaderPage>> pages(ContentItem item) async {
    pageCalls.update(item.id, (count) => count + 1, ifAbsent: () => 1);
    return pagesByID[item.id] ??
        (item.mediaUrl == null ? [] : [ReaderPage(url: item.mediaUrl!)]);
  }

  @override
  Future<ContentItem> detail(int id) =>
      throw StateError('Local reader fixtures do not request details.');

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async => const ContentPage([], hasMore: false);

  @override
  Future<List<String>> suggestions(String query) async => [];

  @override
  void close() {}
}

void main() {
  late Directory directory;
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  late SourceConfig booru;
  late SourceConfig manga;
  late Map<int, List<ReaderPage>> pagesByID;
  late _LocalReaderSource source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-reader-flow-');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1sAAAAASUVORK5CYII=',
    );
    final imageURLs = <int, Uri>{};
    for (var id = 1; id <= 3; id++) {
      final file = File('${directory.path}/$id.png')..writeAsBytesSync(png);
      imageURLs[id] = file.uri;
    }
    pagesByID = {
      for (final entry in imageURLs.entries)
        entry.key: [ReaderPage(url: entry.value, width: 1, height: 1)],
    };
    pagesByID[10] = [
      for (var page = 1; page <= 3; page++)
        ReaderPage(url: imageURLs[page]!, width: 1, height: 1),
    ];
    store = LibraryStore.memory();
    store.setSetting('language', 'en');
    store.setSetting('onboarding', true);
    store.setSetting('reader.booru', const ReaderPreferences().toJson());
    controller = AppController(
      store,
      sourceFactory: (_) => source = _LocalReaderSource(pagesByID),
    );
    booru = controller.addSource('https://reader.example', SourceKind.gelbooru);
    manga = controller.addSource('https://comics.example', SourceKind.manga);
    downloads = DownloadManager(
      store,
      directory,
      clientFactory: () => throw StateError('No network downloads in tests.'),
    );
  });

  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  ContentItem booruItem(int id) => ContentItem(
    sourceId: booru.id,
    id: id,
    mode: AppMode.booru,
    title: 'Image $id',
    mediaUrl: Uri.file('${directory.path}/$id.png'),
    pageUrl: Uri.https('reader.example', '/posts/$id'),
  );

  Future<void> launch(
    WidgetTester tester, {
    required ContentItem item,
    List<ContentItem> sequence = const [],
    int? initialPageIndex,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ReaderScreen(
                      controller: controller,
                      downloads: downloads,
                      item: item,
                      sequence: sequence,
                      initialPageIndex: initialPageIndex,
                    ),
                  ),
                ),
                child: const Text('Open reader'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open reader'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> pumpReader(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openControls(WidgetTester tester) async {
    await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
    await pumpReader(tester);
    expect(find.byTooltip('Close controls'), findsOneWidget);
  }

  testWidgets(
    'sequence preserves order from the tapped middle post and saves each target',
    (tester) async {
      final first = booruItem(1);
      final middle = booruItem(2);
      final last = booruItem(3);
      await launch(tester, item: middle, sequence: [first, middle, last]);
      await openControls(tester);

      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Next page'));
      await pumpReader(tester);
      expect(find.text('3 / 3'), findsOneWidget);
      await tester.tap(find.text('Save to library'));
      await tester.pump();
      expect(controller.isSaved(last), isTrue);
      expect(controller.isSaved(middle), isFalse);
      expect(controller.isSaved(first), isFalse);

      await tester.tap(find.byTooltip('Previous page'));
      await pumpReader(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.text('Save to library'));
      await tester.pump();
      expect(controller.isSaved(middle), isTrue);
      expect(controller.isSaved(first), isFalse);

      await tester.tap(find.byTooltip('Previous page'));
      await pumpReader(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.text('Save to library'));
      await tester.pump();
      expect(controller.isSaved(first), isTrue);
      expect(controller.isSaved(middle), isTrue);
      expect(controller.isSaved(last), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system Back hides controls before the reader is exited', (
    tester,
  ) async {
    await launch(tester, item: booruItem(1));
    await openControls(tester);

    await Navigator.of(tester.element(find.byType(ReaderScreen))).maybePop();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(find.byTooltip('Close controls'), findsNothing);

    Navigator.of(tester.element(find.byType(ReaderScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Open reader'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('reader exit threshold matches the native down-swipe gesture', () {
    expect(ReaderExitGesturePolicy.shouldExit(const Offset(0, 96), 0), isTrue);
    expect(
      ReaderExitGesturePolicy.shouldExit(const Offset(0, 24), 550),
      isTrue,
    );
    expect(
      ReaderExitGesturePolicy.shouldExit(const Offset(0, 23), 900),
      isFalse,
    );
    expect(
      ReaderExitGesturePolicy.shouldExit(const Offset(80, 96), 900),
      isFalse,
    );
    expect(ReaderExitGesturePolicy.startsInContinuousExitZone(80, 24), isTrue);
    expect(
      ReaderExitGesturePolicy.startsInContinuousExitZone(100, 24),
      isFalse,
    );
    expect(
      ReaderExitGesturePolicy.shouldAdvancePost(const Offset(-50, 20)),
      isTrue,
    );
    expect(
      ReaderExitGesturePolicy.shouldAdvancePost(const Offset(-50, 40)),
      isFalse,
    );
  });

  testWidgets('adjacent post manifests are bounded and reused on navigation', (
    tester,
  ) async {
    final first = booruItem(1);
    final middle = booruItem(2);
    final last = booruItem(3);
    await launch(tester, item: first, sequence: [first, middle, last]);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(source.pageCalls.keys, everyElement(isIn([1, 2, 3])));
    expect(source.pageCalls.values, everyElement(lessThanOrEqualTo(1)));
    expect(source.pageCalls.length, lessThanOrEqualTo(3));

    final swipe = await tester.startGesture(
      tester.getRect(find.byType(ReaderScreen)).center,
    );
    await swipe.moveBy(const Offset(-100, 0));
    await swipe.up();
    await pumpReader(tester);
    expect(source.pageCalls[2], 1);
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader long press toggles the current bookmark immediately', (
    tester,
  ) async {
    final item = booruItem(1);
    await launch(tester, item: item);

    await tester.longPress(find.byType(ReaderScreen));
    await tester.pump();
    expect(controller.isSaved(item), isTrue);
    expect(find.text('Saved'), findsOneWidget);

    await tester.longPress(find.byType(ReaderScreen));
    await tester.pump();
    expect(controller.isSaved(item), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a downward swipe dismisses the reader without stealing paging', (
    tester,
  ) async {
    final first = booruItem(1);
    final second = booruItem(2);
    await launch(tester, item: first, sequence: [first, second]);

    final bounds = tester.getRect(find.byType(ReaderScreen));
    final gesture = await tester.startGesture(bounds.center);
    await gesture.moveBy(const Offset(0, 120));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);

    await launch(tester, item: first, sequence: [first, second]);
    final horizontal = await tester.startGesture(
      tester.getRect(find.byType(ReaderScreen)).center,
    );
    await horizontal.moveBy(const Offset(-120, 0));
    await horizontal.up();
    await pumpReader(tester);
    expect(find.byType(ReaderScreen), findsOneWidget);
    await openControls(tester);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('continuous reader requires a top-zone exit swipe', (
    tester,
  ) async {
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(readingMode: ReadingMode.continuous),
    );
    final item = ContentItem(
      sourceId: manga.id,
      id: 10,
      mode: AppMode.manga,
      title: 'Three page work',
      pageUrl: Uri.https('comics.example', '/10'),
      pageCount: 3,
    );
    await launch(tester, item: item);
    final bounds = tester.getRect(find.byType(ReaderScreen));

    final scroll = await tester.startGesture(bounds.center);
    await scroll.moveBy(const Offset(0, 120));
    await scroll.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReaderScreen), findsOneWidget);

    final safeTop = MediaQuery.paddingOf(
      tester.element(find.byType(ReaderScreen)),
    ).top;
    final exit = await tester.startGesture(
      Offset(bounds.center.dx, safeTop + 32),
    );
    await exit.moveBy(const Offset(0, 120));
    await exit.up();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi-touch cancels the reader exit candidate', (tester) async {
    final item = booruItem(1);
    await launch(tester, item: item);
    final bounds = tester.getRect(find.byType(ReaderScreen));
    final first = await tester.startGesture(bounds.center, pointer: 1);
    await first.moveBy(const Offset(0, 120));
    final second = await tester.startGesture(
      bounds.center + const Offset(24, 0),
      pointer: 2,
    );
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader controls disable the down-swipe exit', (tester) async {
    await launch(tester, item: booruItem(1));
    await openControls(tester);
    final bounds = tester.getRect(find.byType(ReaderScreen));
    final gesture = await tester.startGesture(
      Offset(bounds.center.dx, bounds.center.dy - 100),
    );
    await gesture.moveBy(const Offset(0, 120));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(find.byTooltip('Close controls'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page preview opens the selected manga page', (tester) async {
    final item = ContentItem(
      sourceId: manga.id,
      id: 10,
      mode: AppMode.manga,
      title: 'Three page work',
      pageUrl: Uri.https('comics.example', '/10'),
      pageCount: 3,
    );
    await launch(tester, item: item, initialPageIndex: 0);
    await openControls(tester);
    await tester.tap(find.text('Preview').first);
    await pumpReader(tester);
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.text('3').last);
    await pumpReader(tester);

    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.byTooltip('Close controls'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto advance pauses with quick controls open', (tester) async {
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(autoAdvance: true, autoSeconds: 2),
    );
    final item = ContentItem(
      sourceId: manga.id,
      id: 10,
      mode: AppMode.manga,
      title: 'Three page work',
      pageUrl: Uri.https('comics.example', '/10'),
      pageCount: 3,
    );
    await launch(tester, item: item, initialPageIndex: 0);
    await openControls(tester);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Close controls'));
    await tester.pump(const Duration(seconds: 3));
    await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2 / 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
