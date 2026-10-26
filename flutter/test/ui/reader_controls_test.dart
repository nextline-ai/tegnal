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

class _ReaderSource implements ContentSource {
  _ReaderSource(this.image);
  final Uri image;
  @override
  Future<List<ReaderPage>> pages(ContentItem item) async => [
    ReaderPage(url: image, width: 1, height: 1),
    ReaderPage(url: image, width: 1, height: 1),
  ];
  @override
  Future<ContentItem> detail(int id) => throw UnimplementedError();
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

class _ReaderDownloads extends DownloadManager {
  _ReaderDownloads(super.store, super.directory);
  int added = 0;
  @override
  Future<List<ReaderPage>?> offlinePages(ContentItem item) async => null;
  @override
  Future<void> enqueue(ContentItem item, List<ReaderPage> pages) async {
    added++;
  }
}

void main() {
  testWidgets(
    'reader menu preserves save, folder, note, download and exit actions',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'tegnal-reader-controls-',
      );
      final image = File('${directory.path}/page.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1sAAAAASUVORK5CYII=',
          ),
        );
      final store = LibraryStore.memory();
      final controller = AppController(
        store,
        sourceFactory: (_) => _ReaderSource(image.uri),
      );
      final downloads = _ReaderDownloads(store, directory);
      final source = controller.addSource(
        'https://reader.example',
        SourceKind.manga,
      );
      final folder = controller.createFolder('Read later');
      final item = ContentItem(
        sourceId: source.id,
        id: 7,
        mode: AppMode.manga,
        title: 'A reading fixture',
        pageUrl: Uri.https('reader.example', '/7'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        downloads.dispose();
        controller.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: tegnalTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderScreen(
                        controller: controller,
                        item: item,
                        downloads: downloads,
                      ),
                    ),
                  ),
                  child: const Text('Launch reader'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Launch reader'));
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Download work'), findsNothing);
      await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download work'), findsOneWidget);
      await tester.tap(find.text('Save to library'));
      await tester.pump();
      expect(controller.isSaved(item), isTrue);
      await tester.tap(find.text('Save to folder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Read later'));
      await tester.pump();
      expect(controller.saved(item)!.folderIds, contains(folder.id));
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Notes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField), 'Remember this page');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.saved(item)!.note, 'Remember this page');
      await tester.tap(find.text('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SegmentedButton<ReadingMode>), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
      expect(find.byType(Slider), findsWidgets);
      await tester.tap(find.text('Vertical'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        controller.readerPreferences(AppMode.manga).readingMode,
        ReadingMode.vertical,
      );
      final rightToLeft = controller
          .readerPreferences(AppMode.manga)
          .rightToLeft;
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        controller.readerPreferences(AppMode.manga).rightToLeft,
        !rightToLeft,
      );
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Download work'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(downloads.added, 1);
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Exit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Launch reader'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader palette scrolls at narrow widths and large text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = Directory.systemTemp.createTempSync(
        'tegnal-reader-layout-',
      );
      final store = LibraryStore.memory();
      final controller = AppController(
        store,
        sourceFactory: (_) =>
            _ReaderSource(Uri.file('${directory.path}/missing.png')),
      );
      final downloads = _ReaderDownloads(store, directory);
      final source = controller.addSource(
        'https://reader.example',
        SourceKind.manga,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        downloads.dispose();
        controller.dispose();
        store.close();
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: tegnalTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ReaderScreen(
            controller: controller,
            downloads: downloads,
            item: ContentItem(
              sourceId: source.id,
              id: 9,
              mode: AppMode.manga,
              title: 'Layout fixture',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(const Offset(160, 200));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Save to folder'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Reader settings'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(SegmentedButton<ReadingMode>), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
