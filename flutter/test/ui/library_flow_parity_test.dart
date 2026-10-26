import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/artists_screen.dart';
import 'package:tegnal/features/detail_screen.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/common.dart';
import 'package:tegnal/ui/content_tile.dart';
import 'package:tegnal/ui/page_header.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  late _MemorySource sourceClient;
  late SourceConfig mangaSource;

  setUp(() {
    store = LibraryStore.memory();
    sourceClient = _MemorySource();
    controller = AppController(store, sourceFactory: (_) => sourceClient);
    mangaSource = SourceConfig(
      id: 'manga-source',
      name: 'Manga',
      baseUrl: Uri.https('manga.invalid'),
      kind: SourceKind.manga,
    );
    store.saveSource(mangaSource);
  });

  tearDown(() {
    controller.dispose();
    store.database.close();
  });

  ContentItem work(
    int id,
    String title, {
    String sourceId = 'manga-source',
    AppMode mode = AppMode.manga,
    List<String> artists = const [],
    List<String> tags = const [],
  }) => ContentItem(
    sourceId: sourceId,
    id: id,
    mode: mode,
    title: title,
    artists: artists,
    tags: tags,
  );

  Future<void> pumpAtPhoneSize(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: child,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('library and opened collection stay pinned to their mode', (
    tester,
  ) async {
    final mangaFolder = LibraryFolder(
      id: 'manga-folder',
      mode: AppMode.manga,
      name: 'Manga folder',
    );
    final booruFolder = LibraryFolder(
      id: 'booru-folder',
      mode: AppMode.booru,
      name: 'Booru folder',
    );
    store.saveFolder(mangaFolder);
    store.saveFolder(booruFolder);
    store.saveItem(work(1, 'Manga saved'), folderIds: [mangaFolder.id]);
    store.saveItem(
      work(2, 'Booru saved', mode: AppMode.booru, sourceId: 'booru-source'),
      folderIds: [booruFolder.id],
    );
    controller.setMode(AppMode.manga);

    await pumpAtPhoneSize(
      tester,
      LibraryScreen(
        controller: controller,
        mode: AppMode.manga,
        onOpen: (_) {},
      ),
    );
    controller.setMode(AppMode.booru);
    await tester.pumpAndSettle();

    expect(find.text('Manga folder'), findsOneWidget);
    expect(find.text('Booru folder'), findsNothing);
    expect(find.byKey(const ValueKey('mode-switch')), findsOneWidget);
    expect(controller.mode, AppMode.booru);

    await tester.tap(find.widgetWithText(TextButton, 'All Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Manga saved'), findsOneWidget);
    expect(find.text('Booru saved'), findsNothing);
    controller.setMode(AppMode.booru);
    await tester.pumpAndSettle();
    expect(find.text('Manga saved'), findsOneWidget);
  });

  testWidgets('Saved source picker changes Explore sources, not saved items', (
    tester,
  ) async {
    final first = SourceConfig(
      id: 'booru-one',
      name: 'First server',
      baseUrl: Uri.https('one.invalid'),
      kind: SourceKind.danbooru,
    );
    final second = SourceConfig(
      id: 'booru-two',
      name: 'Second server',
      baseUrl: Uri.https('two.invalid'),
      kind: SourceKind.gelbooru,
    );
    store.saveSource(first);
    store.saveSource(second);
    controller.selectSources([first]);
    store.saveItem(
      work(71, 'First saved', sourceId: first.id, mode: AppMode.booru),
    );
    store.saveItem(
      work(72, 'Second saved', sourceId: second.id, mode: AppMode.booru),
    );

    await pumpAtPhoneSize(
      tester,
      LibraryScreen(
        controller: controller,
        mode: AppMode.booru,
        onOpen: (_) {},
      ),
    );
    expect(controller.savedItems(mode: AppMode.booru), hasLength(2));

    await tester.tap(find.byIcon(Icons.dns_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'First server'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Second server'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(
      controller.selectedSources(AppMode.booru).map((source) => source.id),
      ['booru-two'],
    );
    expect(controller.savedItems(mode: AppMode.booru), hasLength(2));

    await tester.tap(find.byIcon(Icons.dns_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Second server'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(controller.selectedSources(AppMode.booru), isEmpty);
    expect(controller.savedItems(mode: AppMode.booru), hasLength(2));
  });

  testWidgets(
    'mode pill toggles from either half and handles slow and fast drags',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      controller.setPreference('glass', true);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
          home: Scaffold(
            body: TegnalPageHeader(
              controller: controller,
              title: 'Saved',
              mode: AppMode.manga,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final pill = find.byKey(const ValueKey('mode-switch'));
      expect(tester.getSize(pill).height, 48);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widgetList<ChromeSurface>(find.byType(ChromeSurface))
            .every((surface) => !surface.enabled),
        isTrue,
      );

      final bounds = tester.getRect(pill);
      await tester.tapAt(Offset(bounds.left + 24, bounds.center.dy));
      await tester.pumpAndSettle();
      expect(controller.mode, AppMode.booru);
      await tester.tapAt(Offset(bounds.right - 24, bounds.center.dy));
      await tester.pumpAndSettle();
      expect(controller.mode, AppMode.manga);

      controller.setMode(AppMode.booru);
      await tester.pumpAndSettle();
      final slowDrag = await tester.startGesture(bounds.center);
      await slowDrag.moveBy(
        const Offset(-30, 0),
        timeStamp: const Duration(milliseconds: 300),
      );
      await slowDrag.moveBy(
        const Offset(-24, 0),
        timeStamp: const Duration(milliseconds: 600),
      );
      await slowDrag.up();
      await tester.pumpAndSettle();
      expect(controller.mode, AppMode.manga);

      await tester.fling(pill, const Offset(120, 0), 1200);
      await tester.pumpAndSettle();
      expect(controller.mode, AppMode.booru);

      final fastShortSwipe = await tester.startGesture(
        Offset(bounds.right - 10, bounds.center.dy),
      );
      await fastShortSwipe.moveBy(
        const Offset(-8, 0),
        timeStamp: const Duration(milliseconds: 10),
      );
      await fastShortSwipe.up();
      await tester.pumpAndSettle();
      expect(
        controller.mode,
        AppMode.manga,
        reason:
            'A short fast swipe switches once without falling through to tap',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder editor can cancel and back out without controller errors',
    (tester) async {
      await pumpAtPhoneSize(
        tester,
        LibraryScreen(
          controller: controller,
          mode: AppMode.manga,
          onOpen: (_) {},
        ),
      );

      await tester.tap(find.byIcon(Icons.create_new_folder_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.folders(AppMode.manga), isEmpty);

      await tester.tap(find.byIcon(Icons.create_new_folder_outlined).first);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(controller.folders(AppMode.manga), isEmpty);
    },
  );

  testWidgets('source form stays inside a short screen above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAddSource(context, controller, mode: AppMode.booru),
              child: const Text('Connect'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    final viewportBottom = 560 - 260;
    expect(
      tester.getRect(find.text('Connect a Website')).top,
      lessThan(viewportBottom),
    );
    await tester.scrollUntilVisible(
      find.text('Add'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('Add')).bottom,
      lessThanOrEqualTo(viewportBottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved work long-press unsaves; overflow keeps editing actions', (
    tester,
  ) async {
    final saved = work(81, 'Saved item');
    store.saveItem(saved);
    await pumpAtPhoneSize(
      tester,
      LibraryScreen(
        controller: controller,
        mode: AppMode.manga,
        onOpen: (_) {},
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, 'All Favorites'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(ContentTile).first);
    await tester.pumpAndSettle();
    expect(store.saved(saved.key), isNull);

    final remaining = work(82, 'Manage this item');
    controller.save(remaining);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit Note and Folders'), findsOneWidget);
    await tester.tap(find.text('Edit Note and Folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.saved(remaining.key)?.item.title, remaining.title);
  });

  testWidgets('Manga artists open local works filtered by the saved kind', (
    tester,
  ) async {
    store.saveArtist(
      const ArtistEntry(name: 'circle_sora', mode: AppMode.manga, kind: 1),
    );
    final groupWork = work(10, 'Circle work', tags: ['group:circle_sora']);
    store.saveItem(groupWork);
    store.saveItem(work(11, 'Artist work', artists: ['circle_sora']));
    controller.setMode(AppMode.booru);

    ContentItem? opened;
    List<ContentItem>? sequence;
    await pumpAtPhoneSize(
      tester,
      ArtistsScreen(
        controller: controller,
        mode: AppMode.manga,
        onOpen: (item) => opened = item,
        onSearch: (_) {},
        onOpenSequence: (item, items) {
          opened = item;
          sequence = items;
        },
      ),
    );

    expect(find.text('circle sora'), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-switch')), findsOneWidget);
    await tester.tap(find.text('circle sora'));
    await tester.pumpAndSettle();
    expect(find.text('Circle work'), findsOneWidget);
    expect(find.text('Artist work'), findsNothing);
    await tester.tap(find.text('Circle work'));
    expect(opened?.id, groupWork.id);
    expect(opened?.title, groupWork.title);
    expect(sequence?.map((item) => item.id).toList(), [groupWork.id]);
  });

  testWidgets(
    'Booru Tags search hides on scroll and returns while header stays fixed',
    (tester) async {
      final booru = SourceConfig(
        id: 'booru-source',
        name: 'Booru',
        baseUrl: Uri.https('booru.invalid'),
        kind: SourceKind.danbooru,
      );
      store.saveSource(booru);
      controller.setMode(AppMode.booru);
      for (var index = 0; index < 30; index++) {
        store.saveArtist(
          ArtistEntry(
            name: 'tag_$index',
            mode: AppMode.booru,
            sourceId: booru.id,
            kind: 1,
          ),
        );
      }
      await pumpAtPhoneSize(
        tester,
        ArtistsScreen(
          controller: controller,
          mode: AppMode.booru,
          onOpen: (_) {},
          onSearch: (_) {},
        ),
      );

      final header = find.byKey(const ValueKey('tegnal-page-header'));
      final search = find.byKey(const ValueKey('artists.search'));
      final headerTop = tester.getTopLeft(header).dy;
      final searchFocus = tester.widget<TextField>(search).focusNode!;
      final scrollable = find
          .descendant(
            of: find.byType(ArtistsScreen),
            matching: find.byType(Scrollable),
          )
          .first;

      await tester.drag(scrollable, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header).dy, headerTop);
      expect(
        tester.getTopLeft(find.text('tag 0')).dy,
        lessThan(tegnalHeaderExtent),
      );
      final hiddenPointer = tester.widget<IgnorePointer>(
        find.ancestor(of: search, matching: find.byType(IgnorePointer)).first,
      );
      expect(hiddenPointer.ignoring, isTrue);
      await tester.tapAt(const Offset(220, 90));
      await tester.pump();
      expect(searchFocus.hasFocus, isFalse);

      await tester.drag(scrollable, const Offset(0, 80));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header).dy, headerTop);
      final visiblePointer = tester.widget<IgnorePointer>(
        find.ancestor(of: search, matching: find.byType(IgnorePointer)).first,
      );
      expect(visiblePointer.ignoring, isFalse);
      await tester.tap(search);
      await tester.pump();
      expect(searchFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Add Work Number parses native links and batch saves offline', (
    tester,
  ) async {
    store.database.execute('DELETE FROM sources WHERE id=?', ['manga-source']);
    store.saveFolder(
      const LibraryFolder(
        id: 'destination',
        mode: AppMode.manga,
        name: 'Destination',
      ),
    );
    await pumpAtPhoneSize(
      tester,
      LibraryScreen(
        controller: controller,
        mode: AppMode.manga,
        onOpen: (_) {},
      ),
    );

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'https://e-hentai.org/r/10042\n'
      'https://reader.example/reader/10043.html '
      'https://e-hentai.org/r/10042',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('10042  10043'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(sourceClient.requestedDetails, isEmpty);
    expect(store.saved('manga:10042')?.item.title, '#10042');
    expect(store.saved('manga:10043')?.item.title, '#10043');
    expect(store.saved('manga:10042')?.item.pageUrl, isNull);
    expect(store.saved('manga:10042')?.folderIds, ['destination']);
    final works =
        (jsonDecode(BackupCodec(store).exportJson()) as Map)['comics']['works']
            as List;
    expect(
      works.map((entry) => (entry as Map)['gallery_id']).toSet(),
      containsAll([10042, 10043]),
    );
    expect(jsonEncode(works), isNot(contains('e-hentai.org')));
  });

  testWidgets(
    'adding an existing work to Unfiled preserves its folder membership',
    (tester) async {
      store.saveFolder(
        const LibraryFolder(
          id: 'existing-folder',
          mode: AppMode.manga,
          name: 'Existing Folder',
        ),
      );
      final saved = work(10051, 'Saved title');
      store.saveItem(
        saved,
        folderIds: ['existing-folder'],
        note: 'Keep this note.',
      );
      await pumpAtPhoneSize(
        tester,
        LibraryScreen(
          controller: controller,
          mode: AppMode.manga,
          onOpen: (_) {},
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '10051');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unfiled').last);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final updated = store.saved('manga:10051')!;
      expect(updated.item.title, 'Saved title');
      expect(updated.note, 'Keep this note.');
      expect(updated.folderIds, ['existing-folder']);
    },
  );

  testWidgets('saved work details edit title and note, then remove safely', (
    tester,
  ) async {
    final saved = work(51, 'Original title');
    store.saveItem(saved, note: 'old note');
    sourceClient.items[51] = saved;
    final downloads = DownloadManager(store, Directory.systemTemp);
    addTearDown(downloads.dispose);
    await pumpAtPhoneSize(
      tester,
      DetailScreen(
        controller: controller,
        item: saved,
        downloads: downloads,
        onSearch: (_) {},
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Changed title');
    await tester.enterText(fields.at(1), 'Changed note');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(store.saved('manga:51')?.item.title, 'Changed title');
    expect(store.saved('manga:51')?.note, 'Changed note');

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(store.saved('manga:51'), isNull);
  });
}

class _MemorySource implements ContentSource {
  final Map<int, ContentItem> items = {};
  final List<int> requestedDetails = [];

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async => const ContentPage([], hasMore: false);

  @override
  Future<ContentItem> detail(int id) async {
    requestedDetails.add(id);
    return items[id] ??
        ContentItem(
          sourceId: 'manga-source',
          id: id,
          mode: AppMode.manga,
          title: 'Fetched $id',
        );
  }

  @override
  Future<List<ReaderPage>> pages(ContentItem item) async => const [];

  @override
  Future<List<String>> suggestions(String query) async => const [];

  @override
  void close() {}
}
