import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/ui/metadata_fill.dart';

class _PendingMetadataSource implements ContentSource {
  final response = Completer<ContentItem>();
  @override
  Future<ContentItem> detail(int id) => response.future;
  @override
  Future<List<ReaderPage>> pages(ContentItem item) async => [];
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
  late LibraryStore store;
  late AppController controller;
  late _PendingMetadataSource source;
  setUp(() {
    store = LibraryStore.memory();
    source = _PendingMetadataSource();
    controller = AppController(store, sourceFactory: (_) => source);
    store.saveItem(
      const ContentItem(sourceId: '', id: 1, mode: AppMode.manga, title: '#1'),
    );
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });
  Future<void> host(
    WidgetTester tester, {
    VoidCallback? connect,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              MetadataFillNotice(
                controller: controller,
                onConnect: connect ?? () {},
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('missing-source notice is visible with a real connect action', (
    tester,
  ) async {
    var connections = 0;
    await host(tester, connect: () => connections++);
    controller.libraryRestored(fillMissingMetadata: true);
    await tester.pump();
    expect(
      find.text(
        'Connect a comics website to fill imported covers, titles and tags.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Connect a Website'));
    expect(connections, 1);
    expect(store.sources(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'running progress can pause and dismiss without deleting the library',
    (tester) async {
      controller.addSource('https://source.invalid', SourceKind.manga);
      await host(tester);
      unawaited(controller.fillMissingMetadata());
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('0 / 1'), findsOneWidget);
      await tester.tap(find.text('Pause'));
      await tester.pump();
      expect(find.text('Metadata filling is paused.'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.byTooltip('Dismiss filling notice'));
      await tester.pump();
      expect(find.byKey(const ValueKey('metadata-fill-notice')), findsNothing);
      expect(controller.metadataFillPaused, true);
      expect(store.isSaved('manga:1'), true);
      source.response.complete(
        const ContentItem(
          sourceId: 'remote',
          id: 1,
          mode: AppMode.manga,
          title: 'Remote',
        ),
      );
      await tester.pump();
      expect(store.saved('manga:1')!.item.title, '#1');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'native heat warning and controls fit a narrow large-text layout',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.metadataFillRunning = true;
      controller.metadataFillTotal = 1191;
      controller.metadataFillCompleted = 12;
      await host(tester, scale: 2);
      expect(find.text('12 / 1191'), findsOneWidget);
      expect(find.textContaining('may warm up your device'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.byTooltip('Dismiss filling notice'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
