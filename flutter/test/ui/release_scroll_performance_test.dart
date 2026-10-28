import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/explore_screen.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/ui/artwork_layout.dart';
import 'package:tegnal/ui/content_tile.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/grid_bookmark_snapshot.dart';

class _CountingStore extends LibraryStore {
  _CountingStore() : super(sqlite3.openInMemory());
  int itemReads = 0, overviewReads = 0, settingReads = 0, singleSavedReads = 0;
  final bookmarkBatchSizes = <int>[];
  @override
  List<SavedItem> items(AppMode mode, {String? folderId, String query = ''}) {
    itemReads++;
    return super.items(mode, folderId: folderId, query: query);
  }

  @override
  LibraryOverview libraryOverview(
    AppMode mode, {
    Set<String> unfiledFolderIds = const {},
  }) {
    overviewReads++;
    return super.libraryOverview(mode, unfiledFolderIds: unfiledFolderIds);
  }

  @override
  dynamic setting(String key, [dynamic fallback]) {
    settingReads++;
    return super.setting(key, fallback);
  }

  @override
  bool isSaved(String key) {
    singleSavedReads++;
    return super.isSaved(key);
  }

  @override
  Set<String> savedKeysMatching(Iterable<String> keys) {
    final group = keys.toList();
    bookmarkBatchSizes.add(group.length);
    return super.savedKeysMatching(group);
  }
}

void main() {
  late _CountingStore store;
  late AppController controller;
  setUp(() {
    store = _CountingStore();
    store.setPortable('taste.localEvidence', {'initialized': true});
    controller = AppController(store);
    controller.setMode(AppMode.booru);
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });
  ContentItem item(int id) => ContentItem(
    sourceId: 'local',
    id: id,
    mode: AppMode.booru,
    title: 'Work $id',
  );
  Future<void> mount(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: tegnalTheme(Brightness.dark), home: child),
    );
    await tester.pumpAndSettle();
  }

  test(
    'frozen artwork preferences perform no DB reads while tiles lay out',
    () {
      final layout = ArtworkLayout.snapshot(controller, AppMode.booru);
      store.settingReads = 0;
      for (var i = 0; i < 100; i++) {
        layout.radius;
        layout.fitsThumbnails;
        layout.showsTitles;
        layout.showsArtists;
        layout.columns(378);
      }
      expect(store.settingReads, 0);
      controller.setPreference('gridColumns.booru', 3);
      expect(ArtworkLayout.snapshot(controller, AppMode.booru).columns(378), 3);
    },
  );
  test('bookmark lookup is bounded to64 candidates and refreshes with a new snapshot', () {
    final works = [for (var id = 1; id <= 1000; id++) item(id)];
    store.saveItem(works[0]);
    final snapshot = GridBookmarkSnapshot(works, store.savedKeysMatching);
    expect(snapshot.contains(0), isTrue);
    for (var i = 1; i < 64; i++) {
      expect(snapshot.contains(i), isFalse);
    }
    expect(store.bookmarkBatchSizes, [64]);
    snapshot.contains(64);
    expect(store.bookmarkBatchSizes, [64, 64]);
    store.saveItem(works[1]);
    expect(
      GridBookmarkSnapshot(works, store.savedKeysMatching).contains(1),
      isTrue,
    );
  });
  testWidgets(
    'folder overview is lazy and keyboard insets do not reread the library',
    (tester) async {
      for (var id = 0; id < 200; id++) {
        store.saveFolder(
          LibraryFolder(
            id: 'f$id',
            mode: AppMode.booru,
            name: 'Folder $id',
            position: id,
          ),
        );
      }
      store.itemReads = 0;
      await mount(
        tester,
        LibraryScreen(
          controller: controller,
          mode: AppMode.booru,
          onOpen: (_) {},
        ),
      );
      expect(store.itemReads, 0);
      final overviewReads = store.overviewReads;
      final names = find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data ?? '').startsWith('Folder '),
      );
      expect(names.evaluate().length, lessThan(30));
      for (final inset in [50.0, 150.0, 300.0, 150.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(store.overviewReads, overviewReads);
      expect(store.itemReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'collection typing and selection reuse one decoded snapshot until notified',
    (tester) async {
      for (var id = 1; id <= 100; id++) {
        store.saveItem(item(id));
      }
      store.itemReads = 0;
      await mount(
        tester,
        LibraryScreen(
          controller: controller,
          mode: AppMode.booru,
          onOpen: (_) {},
        ),
      );
      await tester.tap(find.text('All Favorites'));
      await tester.pumpAndSettle();
      expect(store.itemReads, 1);
      for (final query in ['W', 'Work', 'Work 1']) {
        await tester.enterText(find.byType(TextField), query);
        await tester.pump();
      }
      await tester.tap(find.text('Select'));
      await tester.pump();
      await tester.tap(find.byType(ContentTile).first);
      await tester.pump();
      expect(store.itemReads, 1);
      controller.changed();
      await tester.pump();
      expect(store.itemReads, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Explore uses bounded bookmark batches and no root reads per IME frame',
    (tester) async {
      final config = SourceConfig(
        id: 'local',
        name: 'Local',
        baseUrl: Uri.https('local.invalid'),
        kind: SourceKind.danbooru,
      );
      store.saveSource(config);
      controller.selectSources([config]);
      controller.explore(AppMode.booru).items = [
        for (var id = 1; id <= 1000; id++) item(id),
      ];
      controller.explore(AppMode.booru).page = 1;
      store.singleSavedReads = 0;
      await mount(
        tester,
        ExploreScreen(
          controller: controller,
          mode: AppMode.booru,
          onOpen: (_) {},
          onConnect: () {},
        ),
      );
      expect(store.singleSavedReads, 0);
      expect(store.bookmarkBatchSizes, [64]);
      await tester.tap(find.byKey(const ValueKey('explore.search')));
      await tester.pumpAndSettle();
      store.settingReads = 0;
      for (final inset in [50.0, 150.0, 300.0, 150.0, 0.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(store.settingReads, 0);
      expect(store.singleSavedReads, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
