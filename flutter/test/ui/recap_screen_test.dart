import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/recap.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/recap_screen.dart';
import 'package:tegnal/ui/l10n.dart';
import 'package:tegnal/ui/recap_palette.dart';

const _capture = bool.fromEnvironment('TEGNAL_CAPTURE_UI');

void main() {
  final recap = recapSample(AppMode.booru, now: DateTime(2026, 10, 15));
  final palette = RecapPalette.seeded('sky');
  final boundary = GlobalKey();

  Future<void> prepare(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await L10n.load();
      for (final family in ['Pretendard', 'serif', 'monospace']) {
        await (FontLoader(family)
              ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
            .load();
      }
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
  }

  Widget app(Widget child) => RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      locale: const Locale('ko'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Pretendard',
      ),
      home: child,
    ),
  );

  Future<void> shot(WidgetTester tester, String name) async {
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (!_capture) return;
    final output = Directory('build/ui-captures/recap')
      ..createSync(recursive: true);
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${output.path}/$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget story({bool private = false, bool auto = false}) => RecapStoryScreen(
    recap: recap,
    palette: palette,
    private: private,
    autoAdvance: auto,
    onSearch: (_) {},
  );

  testWidgets('every page of an issue renders and advances without overflow', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(app(story()));
    final pages = RecapPage.pagesFor(recap);
    expect(pages.length, greaterThanOrEqualTo(10));
    for (final (index, page) in pages.indexed) {
      await shot(tester, '${index.toString().padLeft(2, '0')}-${page.name}');
      expect(tester.takeException(), isNull, reason: page.name);
      if (index < pages.length - 1) {
        await tester.tap(find.byKey(const ValueKey('recap.story.next')));
        await tester.pump();
      }
    }
    expect(find.byKey(const ValueKey('recap.saved')), findsOneWidget);
    expect(find.byKey(const ValueKey('recap.story.next')), findsNothing);
  });

  testWidgets('auto advance moves on, and stops at the last page', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(app(story(auto: true)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 4600));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('RECAP'), findsWidgets);
    expect(find.byKey(const ValueKey('recap.story.next')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('screen readers set the pace instead of the timer', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(
      app(
        MediaQuery(
          data: const MediaQueryData(
            accessibleNavigation: true,
            size: Size(390, 844),
          ),
          child: story(auto: true),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    final state = tester.state(find.byType(RecapStoryScreen));
    expect(state, isNotNull);
    expect(find.text('장'), findsNothing, reason: 'still on the cover');
  });

  testWidgets('private mode swaps artwork for the issue colors', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(app(story(private: true)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RecapColorField), findsWidgets);
    expect(find.byType(RecapGeneratedArt), findsNothing);
    await shot(tester, 'private-cover');
  });

  testWidgets('a share card shows only colors and numbers until asked', (
    tester,
  ) async {
    await prepare(tester);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: RecapShareSheet(recap: recap, palette: palette),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(RecapGeneratedArt), findsNothing);
    expect(
      find.text(
        recap.tags.take(3).map((tag) => recapTagText(tag.name)).join('  ·  '),
      ),
      findsNothing,
    );
    await shot(tester, 'share-default');
    await tester.tap(find.byKey(const ValueKey('recap.share.tags')));
    await tester.pump();
    expect(
      find.text(
        recap.tags.take(3).map((tag) => recapTagText(tag.name)).join('  ·  '),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('recap.share.artwork')));
    await tester.pump();
    expect(find.byType(RecapGeneratedArt), findsOneWidget);
  });

  testWidgets('an empty library leads with a sample issue', (tester) async {
    await prepare(tester);
    final store = LibraryStore.memory();
    final controller = AppController(store);
    addTearDown(() {
      controller.dispose();
      store.close();
    });
    await tester.pumpWidget(
      app(
        RecapScreen(
          controller: controller,
          mode: AppMode.booru,
          onSearch: (_) {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('recap.sample')), findsOneWidget);
    await shot(tester, 'home-empty');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a real library builds issues, the week and the shelf', (
    tester,
  ) async {
    await prepare(tester);
    final store = LibraryStore.memory();
    final controller = AppController(store);
    addTearDown(() {
      controller.dispose();
      store.close();
    });
    final now = DateTime.now();
    for (var month = 0; month < 4; month++) {
      for (var id = 0; id < 8; id++) {
        controller.taste.record(
          'save',
          ContentItem(
            sourceId: 'a',
            id: month * 100 + id,
            mode: AppMode.booru,
            title: 'Work',
            tags: ['sky', 'tag$month'],
          ),
          at: DateTime(now.year, now.month - month, 1 + id),
        );
      }
    }
    await tester.pumpWidget(
      app(
        RecapScreen(
          controller: controller,
          mode: AppMode.booru,
          onSearch: (_) {},
          autoAdvance: false,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('recap.latest')), findsOneWidget);
    await shot(tester, 'home-issues');
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('recap.latest')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('recap.latest')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RecapStoryScreen), findsOneWidget);
  });
}
