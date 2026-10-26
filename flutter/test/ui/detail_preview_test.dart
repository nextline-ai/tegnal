import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/detail_screen.dart';
import 'package:tegnal/features/reader_screen.dart';

class _DetailSource implements ContentSource {
  _DetailSource(this.item, this.page);
  final ContentItem item;
  final Uri page;
  int pageCalls = 0;
  @override
  Future<ContentItem> detail(int id) async => item;
  @override
  Future<List<ReaderPage>> pages(ContentItem item) async {
    pageCalls++;
    return List.generate(
      120,
      (_) => ReaderPage(url: page, width: 1, height: 1),
    );
  }

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
  late _DetailSource source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-detail-');
    final file = File('${directory.path}/page.png');
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1sAAAAASUVORK5CYII=',
      ),
    );
    store = LibraryStore.memory();
    controller = AppController(store, sourceFactory: (_) => source);
    downloads = DownloadManager(store, directory);
  });

  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> launch(WidgetTester tester, {bool longMetadata = false}) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final config = controller.addSource(
      'https://comics.example',
      SourceKind.manga,
    );
    final item = ContentItem(
      sourceId: config.id,
      id: 42,
      mode: AppMode.manga,
      title: 'Work title',
      pageCount: 120,
      artists: const ['Artist'],
      tags: longMetadata
          ? List.generate(100, (i) => 'long_metadata_tag_$i')
          : const ['language:english', 'type:manga'],
    );
    source = _DetailSource(item, Uri.file('${directory.path}/page.png'));
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          controller: controller,
          item: item,
          downloads: downloads,
          onSearch: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'detail waits for meaningful scroll and creates only nearby previews',
    (tester) async {
      await launch(tester);
      expect(find.text('Work Details'), findsOneWidget);
      expect(source.pageCalls, 0);
      expect(
        find.byKey(const ValueKey('content.detail.preview.1')),
        findsNothing,
      );
      final scroll = find.byKey(const ValueKey('content.detail.scroll'));
      await tester.drag(scroll, const Offset(0, -50));
      await tester.pumpAndSettle();
      expect(source.pageCalls, 0);
      await tester.drag(scroll, const Offset(0, -650));
      await tester.pumpAndSettle();
      expect(source.pageCalls, 1);
      expect(
        find.byKey(const ValueKey('content.detail.preview.1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('content.detail.preview.120')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(
        find.byKey(const ValueKey('content.detail.preview.3')),
      );
      await tester.tap(find.byKey(const ValueKey('content.detail.preview.3')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<ReaderScreen>(find.byType(ReaderScreen)).initialPageIndex,
        2,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('long metadata delays previews until its end has been reached', (
    tester,
  ) async {
    await launch(tester, longMetadata: true);
    final scroll = find.byKey(const ValueKey('content.detail.scroll'));
    await tester.drag(scroll, const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(source.pageCalls, 0);
    for (var i = 0; i < 12 && source.pageCalls == 0; i++) {
      await tester.drag(scroll, const Offset(0, -650));
      await tester.pumpAndSettle();
    }
    expect(source.pageCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
