import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/session_client.dart';
import 'package:tegnal/features/reader_screen.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/reader_image_provider.dart';

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
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
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
    store.setSetting('reader.helpHidden', true);
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
    Duration settleDuration = const Duration(seconds: 1),
    bool reduceMotion = false,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  readerRoute(
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
    await tester.pump(settleDuration);
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
    'Translate checks the installed app and does not silently save an image',
    (tester) async {
      const channel = MethodChannel(
        'work.nextline.tegnal/installed_translation',
      );
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return 'manual';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await launch(tester, item: booruItem(1));
      await openControls(tester);
      await tester.tap(find.text('Translate'));
      await pumpReader(tester);
      expect(find.text('Save Image and Open Google Translate'), findsOneWidget);
      expect(calls, ['capability']);
      await tester.tap(find.text('Cancel'));
      await pumpReader(tester);
      expect(calls, ['capability']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Translate sends only the visible reader image to an installed handler',
    (tester) async {
      const channel = MethodChannel(
        'work.nextline.tegnal/installed_translation',
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'capability' ? 'direct' : null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      await launch(tester, item: booruItem(1));
      await openControls(tester);
      await tester.tap(find.text('Translate'));
      await pumpReader(tester);
      await pumpReader(tester);
      expect(calls.map((call) => call.method), ['capability', 'shareImage']);
      expect((calls.last.arguments['png'] as List).take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'reader guide hides on request and stays hidden on the next work',
    (tester) async {
      store.setSetting('reader.helpHidden', false);
      final item = ContentItem(
        sourceId: manga.id,
        id: 10,
        mode: AppMode.manga,
        title: 'Guide work',
        pageCount: 3,
      );
      await launch(tester, item: item, initialPageIndex: 0);
      await pumpReader(tester);
      expect(find.text('Reader Guide'), findsOneWidget);
      await tester.tap(find.text("Don't Show Again"));
      await pumpReader(tester);
      expect(store.setting('reader.helpHidden'), isTrue);
      expect(find.text('Reader Guide'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await launch(tester, item: item, initialPageIndex: 0);
      expect(find.text('Reader Guide'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multi-page spreads navigate aligned groups and apply changed layout',
    (tester) async {
      pagesByID[10] = [...pagesByID[10]!, ...pagesByID[10]!].take(5).toList();
      controller.setReaderPreferences(
        AppMode.manga,
        const ReaderPreferences(pagesPerSpread: 2, prefetch: 0),
      );
      final item = ContentItem(
        sourceId: manga.id,
        id: 10,
        mode: AppMode.manga,
        title: 'Five pages',
        pageCount: 5,
      );
      await launch(tester, item: item, initialPageIndex: 0);
      await openControls(tester);
      await tester.tap(find.byTooltip('Next page'));
      await pumpReader(tester);
      expect(controller.readingPosition(item), 2);
      await tester.tap(find.byTooltip('Next page'));
      await pumpReader(tester);
      expect(controller.readingPosition(item), 4);
      await tester.tap(find.byTooltip('Previous page'));
      await pumpReader(tester);
      expect(controller.readingPosition(item), 2);
      await tester.tap(find.text('More Settings'));
      await pumpReader(tester);
      await tester.tap(find.text('Pages per View'));
      await pumpReader(tester);
      await tester.tap(find.text('3').last);
      await pumpReader(tester);
      await tester.tap(find.text('Done'));
      await pumpReader(tester);
      expect(controller.readerPreferences(AppMode.manga).pagesPerSpread, 3);
      expect(controller.readingPosition(item), 0);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.initialPage,
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resume asks explicitly and preserves direct page selection', (
    tester,
  ) async {
    final item = ContentItem(
      sourceId: manga.id,
      id: 10,
      mode: AppMode.manga,
      title: 'Three pages',
      pageCount: 3,
    );
    controller.saveReadingPosition(item, 2);
    await launch(tester, item: item);
    expect(find.text('Continue Reading'), findsWidgets);
    await tester.tap(find.text('Start from Beginning'));
    await pumpReader(tester);
    expect(controller.readingPosition(item), 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(
        resumeBehavior: ReaderResumeBehavior.fromBeginning,
      ),
    );
    controller.saveReadingPosition(item, 2);
    await launch(tester, item: item, initialPageIndex: 1);
    expect(controller.readingPosition(item), 1);
    expect(find.text('Continue Reading'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
      await tester.tap(find.text('Add Favorite'));
      await tester.pump();
      expect(controller.isSaved(last), isTrue);
      expect(controller.isSaved(middle), isFalse);
      expect(controller.isSaved(first), isFalse);

      await tester.tap(find.byTooltip('Previous page'));
      await pumpReader(tester);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.text('Add Favorite'));
      await tester.pump();
      expect(controller.isSaved(middle), isTrue);
      expect(controller.isSaved(first), isFalse);

      await tester.tap(find.byTooltip('Previous page'));
      await pumpReader(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.tap(find.text('Add Favorite'));
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

  testWidgets(
    'unknown continuous page dimensions update the measured page height',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const Color(0xff2288aa), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(4, 4);
        for (final limit in [1024, 1600, 3000]) {
          final provider = readerImageProvider(pagesByID[10]!.first, {}, limit);
          final key = await provider.obtainKey(ImageConfiguration.empty);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              SynchronousFuture(ImageInfo(image: image.clone())),
            ),
          );
        }
        image.dispose();
        picture.dispose();
      });
      pagesByID[10] = [
        for (final page in pagesByID[10]!) ReaderPage(url: page.url),
      ];
      controller.setReaderPreferences(
        AppMode.manga,
        const ReaderPreferences(
          readingMode: ReadingMode.continuous,
          prefetch: 0,
        ),
      );
      final item = ContentItem(
        sourceId: manga.id,
        id: 10,
        mode: AppMode.manga,
        title: 'Unknown dimensions',
        pageCount: 3,
      );
      await launch(tester, item: item, initialPageIndex: 0);
      await pumpReader(tester);
      await pumpReader(tester);
      final viewport = tester.getSize(find.byType(ReaderScreen));
      expect(
        tester.getSize(find.byType(InteractiveViewer).first).height,
        viewport.width,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'prefetched image and returned image show without loading spinner',
    (tester) async {
      final first = booruItem(1);
      final second = booruItem(2);
      await launch(tester, item: first, sequence: [first, second]);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await pumpReader(tester);
      }
      await openControls(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Next page'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.byTooltip('Previous page'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(source.pageCalls[1], 1);
      expect(source.pageCalls[2], 1);

      final context = tester.element(find.byType(ReaderScreen));
      final page = pagesByID[1]!.single;
      final provider = readerImageProvider(page, const {}, 3000);
      final prepared = ReaderPreparedImages();
      await prepared.remember(
        page,
        3000,
        provider,
        createLocalImageConfiguration(context),
      );
      expect(prepared.find(page, 3000), isNotNull);
      const channel = MethodChannel('work.nextline.tegnal/browser');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      try {
        await BrowserSession.resetCookies(Uri.https('reader.example'));
        expect(prepared.find(page, 3000), isNull);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

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

  testWidgets(
    'post neighbor speculation waits for the native settle interval',
    (tester) async {
      final first = booruItem(1);
      await launch(
        tester,
        item: first,
        sequence: [first, booruItem(2), booruItem(3)],
        settleDuration: Duration.zero,
      );
      expect(source.pageCalls.keys, [1]);
      await tester.pump(const Duration(milliseconds: 199));
      expect(source.pageCalls.keys, [1]);
      await tester.pump(const Duration(milliseconds: 1));
      await pumpReader(tester);
      expect(source.pageCalls.keys, containsAll([1, 2, 3]));
      expect(source.pageCalls.values, everyElement(1));
    },
  );

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

  testWidgets(
    'exit drag follows finger, springs back, and animates dismissal',
    (tester) async {
      await launch(tester, item: booruItem(1));
      final transform = find.byKey(const ValueKey('reader-exit-transform'));
      double offset() =>
          tester.widget<Transform>(transform).transform.getTranslation().y;
      final start = tester.getRect(find.byType(ReaderScreen)).center;
      final cancel = await tester.startGesture(start);
      await tester.pump(const Duration(seconds: 1));
      await cancel.moveBy(const Offset(0, 60));
      await tester.pump();
      expect(offset(), closeTo(60, 0.1));
      await cancel.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(offset(), inExclusiveRange(0, 60));
      await tester.pump(const Duration(seconds: 1));
      expect(offset(), closeTo(0, 0.1));
      expect(find.byType(ReaderScreen), findsOneWidget);

      final exit = await tester.startGesture(start);
      await exit.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(offset(), closeTo(120, 0.1));
      expect(find.text('Open reader'), findsOneWidget);
      await exit.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(offset(), greaterThan(120));
      expect(find.byType(ReaderScreen), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
    },
  );

  testWidgets('reduced motion skips drag and dismissal animation', (
    tester,
  ) async {
    await launch(tester, item: booruItem(1), reduceMotion: true);
    final gesture = await tester.startGesture(
      tester.getRect(find.byType(ReaderScreen)).center,
    );
    await gesture.moveBy(const Offset(0, 120));
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('reader-exit-transform')),
    );
    expect(transform.transform.getTranslation().y, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsNothing);
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
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(showPageNumber: true),
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
