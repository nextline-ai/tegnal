import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-settings-align-');
    store = LibraryStore.memory();
    store.setSetting('language', 'en');
    controller = AppController(store);
    downloads = DownloadManager(
      store,
      directory,
      clientFactory: () => throw StateError('No downloads in settings test.'),
    );
  });

  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  testWidgets('settings trailing content hugs the right edge', (tester) async {
    tester.view.physicalSize = const Size(420, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(controller: controller, downloads: downloads),
        ),
      ),
    );

    final scrollable = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    final themeValue = find.byKey(const ValueKey('settings-value-Theme'));
    await tester.scrollUntilVisible(themeValue, 160, scrollable: scrollable);
    final themeRect = tester.getRect(themeValue);
    final themeChevron = tester.getRect(
      find.byKey(const ValueKey('settings-chevron-Theme')),
    );
    final languageChevron = tester.getRect(
      find.byKey(const ValueKey('settings-chevron-Language')),
    );
    expect((themeChevron.right - 388).abs(), lessThan(1));
    expect((languageChevron.right - 388).abs(), lessThan(1));
    expect((themeChevron.left - themeRect.right - 8).abs(), lessThan(1));

    final systemAiValue = find.byKey(
      const ValueKey('settings-value-System AI'),
    );
    await tester.scrollUntilVisible(systemAiValue, 160, scrollable: scrollable);
    final systemAiRect = tester.getRect(systemAiValue);
    final statisticsRect = tester.getRect(
      find.byKey(const ValueKey('settings-value-Local Statistics')),
    );
    expect((systemAiRect.right - 388).abs(), lessThan(1));
    expect((statisticsRect.right - 388).abs(), lessThan(1));
    expect(tester.takeException(), isNull);
  });
}
