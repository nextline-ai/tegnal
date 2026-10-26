import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/ui/content_tile.dart';

void main() {
  late LibraryStore store;
  late AppController controller;

  setUp(() {
    store = LibraryStore.memory();
    controller = AppController(
      store,
      sourceFactory: (_) => throw StateError('Widget tests must stay offline.'),
    );
  });

  tearDown(() {
    controller.dispose();
    store.database.close();
  });

  Future<void> pumpLibrary(WidgetTester tester, AppMode mode) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.setMode(mode);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        home: LibraryScreen(controller: controller, onOpen: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  void folder(String id, AppMode mode) =>
      store.saveFolder(LibraryFolder(id: id, mode: mode, name: id));

  ContentItem save(int id, AppMode mode, List<String> folders) {
    final item = ContentItem(
      sourceId: 'offline',
      id: id,
      mode: mode,
      title: 'Work $id',
    );
    store.saveItem(
      item,
      folderIds: folders,
      note: 'Note $id',
      savedAt: DateTime.utc(2026, 10, id),
    );
    return item;
  }

  Future<void> selectAll(WidgetTester tester) async {
    await tester.tap(find.text('All Favorites'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.check_circle_outline));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ContentTile>(find.byType(ContentTile))
          .every((tile) => tile.selecting && tile.selected),
      isTrue,
    );
  }

  Future<void> chooseFolder(WidgetTester tester, String name) async {
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
    final choice = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(name),
    );
    await tester.tap(choice);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'bulk moving images replaces their one folder and preserves notes',
    (tester) async {
      folder('Original', AppMode.booru);
      folder('Destination', AppMode.booru);
      final first = save(1, AppMode.booru, ['Original']);
      final second = save(2, AppMode.booru, []);
      await pumpLibrary(tester, AppMode.booru);
      await selectAll(tester);
      await chooseFolder(tester, 'Destination');

      for (final item in [first, second]) {
        final saved = store.saved(item.key)!;
        expect(saved.folderIds, ['Destination']);
        expect(saved.note, 'Note ${item.id}');
        expect(saved.savedAt, DateTime.utc(2026, 10, item.id));
      }
      expect(find.text('Select'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adding comics to a folder preserves existing memberships', (
    tester,
  ) async {
    for (final name in ['Reading', 'Reference', 'Destination']) {
      folder(name, AppMode.manga);
    }
    final first = save(1, AppMode.manga, ['Reading', 'Reference']);
    final second = save(2, AppMode.manga, ['Reference']);
    await pumpLibrary(tester, AppMode.manga);
    await selectAll(tester);
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Add to Folder'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Destination'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      store.saved(first.key)!.folderIds,
      unorderedEquals(['Reading', 'Reference', 'Destination']),
    );
    expect(
      store.saved(second.key)!.folderIds,
      unorderedEquals(['Reference', 'Destination']),
    );
    expect(store.saved(first.key)!.note, 'Note 1');
    expect(tester.takeException(), isNull);
  });

  for (final mode in AppMode.values) {
    testWidgets('choosing Unfiled explicitly clears ${mode.name} memberships', (
      tester,
    ) async {
      folder('Existing', mode);
      final item = save(1, mode, ['Existing']);
      await pumpLibrary(tester, mode);
      await selectAll(tester);
      await chooseFolder(tester, 'Unfiled');

      expect(store.saved(item.key)!.folderIds, isEmpty);
      expect(store.saved(item.key)!.note, 'Note 1');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'cancelling bulk removal retains selected works and organization',
    (tester) async {
      folder('Keep', AppMode.booru);
      final item = save(1, AppMode.booru, ['Keep']);
      await pumpLibrary(tester, AppMode.booru);
      await selectAll(tester);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.saved(item.key)!.folderIds, ['Keep']);
      expect(store.saved(item.key)!.note, 'Note 1');
      expect(
        tester.widget<ContentTile>(find.byType(ContentTile)).selected,
        isTrue,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a custom folder named like Unfiled keeps its own collection', (
    tester,
  ) async {
    store.saveFolder(
      const LibraryFolder(
        id: 'custom-unfiled',
        mode: AppMode.booru,
        name: '미분류',
      ),
    );
    final item = save(1, AppMode.booru, ['custom-unfiled']);
    await pumpLibrary(tester, AppMode.booru);
    expect(find.text('미분류'), findsOneWidget);
    expect(find.text('Unfiled'), findsOneWidget);
    await tester.tap(find.text('미분류'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ContentTile>(find.byType(ContentTile)).item.key,
      item.key,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'imported native Unfiled appears once and includes new unfiled works',
    (tester) async {
      BackupCodec(store).importJson(
        jsonEncode({
          'format': 'tegnal-image-library',
          'version': 1,
          'exportedAt': 814838400.0,
          'servers': [
            {
              'id': 'offline',
              'name': 'Offline',
              'baseURL': 'https://offline.invalid',
              'engine': 'danbooru',
            },
          ],
          'folders': [
            {'id': 'unsorted', 'name': '', 'color': 0xFF66BB6A},
          ],
          'favorites': [
            {
              'post': {
                'serverID': 'offline',
                'postID': 8,
                'width': 100,
                'height': 100,
                'tags': <String>[],
                'artists': <String>[],
                'rating': 'g',
                'score': 0,
                'fileExtension': 'jpg',
                'poolIDs': <int>[],
              },
              'folderID': 'unsorted',
              'savedAt': 1792886400.0,
            },
          ],
          'history': <dynamic>[],
          'savedTags': <dynamic>[],
          'blacklist': <String, String>{},
          'selectedServerIDs': ['offline'],
        }),
      );
      final newItem = save(9, AppMode.booru, []);
      await pumpLibrary(tester, AppMode.booru);

      expect(find.text('Unfiled'), findsOneWidget);
      expect(find.text('Uncategorized'), findsNothing);
      await tester.tap(find.text('Unfiled'));
      await tester.pumpAndSettle();
      final ids = tester
          .widgetList<ContentTile>(find.byType(ContentTile))
          .map((tile) => tile.item.id);
      expect(ids, unorderedEquals([8, newItem.id]));
      expect(tester.takeException(), isNull);
    },
  );
}
