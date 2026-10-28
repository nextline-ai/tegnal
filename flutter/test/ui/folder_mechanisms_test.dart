import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/backup_codec.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/artwork_layout.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  setUp(() {
    store = LibraryStore.memory();
    controller = AppController(store);
    controller.setMode(AppMode.booru);
    for (final (index, name) in ['A', 'B', 'C'].indexed) {
      store.saveFolder(
        LibraryFolder(
          id: name,
          mode: AppMode.booru,
          name: name,
          position: index,
        ),
      );
    }
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    AppMode mode = AppMode.booru,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.dark),
        home: LibraryScreen(controller: controller, mode: mode, onOpen: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> actions(WidgetTester tester, String name, String action) async {
    await tester.longPress(find.text(name));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'creation asks only for a name and Cancel consumes no automatic color',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Automatic color');
      expect(find.text('Folder color'), findsNothing);
      expect(find.byKey(const ValueKey('folder-creation-color')), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(controller.folders(AppMode.booru).length, 3);
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Automatic color');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      final created = controller
          .folders(AppMode.booru)
          .firstWhere((folder) => folder.name == 'Automatic color');
      expect(created.color, 0xFF2563EB);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'folder color accepts arbitrary opaque RGB and commits on selection',
    (tester) async {
      final item = ContentItem(
        sourceId: 'local',
        id: 1,
        mode: AppMode.booru,
        title: 'Keep this',
      );
      store.saveItem(item, folderIds: ['A'], note: 'Keep note');
      await mount(tester);
      await actions(tester, 'A', 'Change Color');
      await tester.enterText(
        find.byKey(const ValueKey('folder-color-hex')),
        '12ABEF',
      );
      await tester.pumpAndSettle();
      expect(
        controller.folders(AppMode.booru).firstWhere((f) => f.id == 'A').color,
        0xFF12ABEF,
      );
      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(store.saved(item.key)!.folderIds, ['A']);
      expect(store.saved(item.key)!.note, 'Keep note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Unfiled color persists and a populated Unfiled cannot be deleted',
    (tester) async {
      final item = ContentItem(
        sourceId: 'local',
        id: 1,
        mode: AppMode.manga,
        title: 'Unfiled work',
      );
      store.saveItem(item);
      await mount(tester, mode: AppMode.manga);
      await actions(tester, 'Unfiled', 'Change Color');
      await tester.enterText(
        find.byKey(const ValueKey('folder-color-hex')),
        '7451AC',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Done'));
      await tester.pumpAndSettle();
      expect(
        controller
            .folders(AppMode.manga)
            .firstWhere((folder) => folder.name == '미분류')
            .color,
        0xFF7451AC,
      );
      await actions(tester, 'Unfiled', 'Delete Folder');
      expect(
        find.text(
          'Move or remove the works in Uncategorized before deleting it.',
        ),
        findsOneWidget,
      );
      expect(store.saved(item.key), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drag reorder is a draft until Save and Cancel preserves order', (
    tester,
  ) async {
    await mount(tester);
    Future<void> dragB() async {
      await actions(tester, 'B', 'Reorder Folders');
      final handle = find.byType(ReorderableDragStartListener).at(1);
      final pointer = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 300));
      final target = tester.getCenter(
        find.byKey(const ValueKey('folder-order-A')),
      );
      await pointer.moveTo(Offset(tester.getCenter(handle).dx, target.dy + 10));
      await tester.pump(const Duration(milliseconds: 300));
      await pointer.up();
      await tester.pumpAndSettle();
    }

    await dragB();
    expect(controller.folders(AppMode.booru).map((f) => f.id), ['A', 'B', 'C']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.folders(AppMode.booru).map((f) => f.id), ['A', 'B', 'C']);
    await dragB();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(controller.folders(AppMode.booru).map((f) => f.id), ['B', 'A', 'C']);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [AppMode.manga]) {
    testWidgets(
      'customized Unfiled survives native ${mode.name} export/import once',
      (tester) async {
        if (mode == AppMode.manga) {
          for (final (index, name) in ['Manga A', 'Manga B'].indexed) {
            store.saveFolder(
              LibraryFolder(id: name, mode: mode, name: name, position: index),
            );
          }
        }
        controller.setMode(mode);
        await mount(tester, mode: mode);
        await actions(tester, 'Unfiled', 'Change Color');
        await tester.enterText(
          find.byKey(const ValueKey('folder-color-hex')),
          '12ABEF',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Done'));
        await tester.pumpAndSettle();
        await actions(tester, 'Unfiled', 'Reorder Folders');
        final order = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        order.onReorderItem!(0, 2);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final restoredStore = LibraryStore.memory();
        BackupCodec(restoredStore).importJson(BackupCodec(store).exportJson());
        final restored = AppController(restoredStore);
        final folders = restored.folders(mode);
        expect(folders.length, mode == AppMode.manga ? 3 : 4);
        expect(folders[2].color, 0xFF12ABEF);
        expect(
          folders[2].name,
          mode == AppMode.manga ? '미분류' : 'Uncategorized',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: tegnalTheme(Brightness.dark),
            home: LibraryScreen(
              controller: restored,
              mode: mode,
              onOpen: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Unfiled'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        restored.dispose();
        restoredStore.close();
      },
    );
  }

  test(
    'automatic density uses the native 160pt minimum and five-column ceiling',
    () {
      final layout = ArtworkLayout(controller, AppMode.booru);
      expect(layout.columns(378), 2); // 402pt window with 12pt margins.
      expect(layout.columns(296), 1); // 320pt window.
      expect(layout.columns(1800), 5);
      controller.setPreference('gridColumns.booru', 3);
      expect(layout.columns(378), 3);
    },
  );

  testWidgets('mode-specific columns and spacing change the real folder grid', (
    tester,
  ) async {
    controller.setPreference('folderColumns.booru', 4);
    controller.setPreference('folderColumns.manga', 1);
    controller.setPreference('removesGridPadding.booru', true);
    await mount(tester);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);
    expect(delegate.mainAxisSpacing, 0);
    expect(delegate.crossAxisSpacing, 0);
    expect(tester.takeException(), isNull);
  });
}
