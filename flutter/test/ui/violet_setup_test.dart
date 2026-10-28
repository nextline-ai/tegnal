import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/drive_sync_controller.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/drive_sync_screen.dart';
import 'package:tegnal/features/onboarding_screen.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';

void main() {
  late Directory directory;
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  var fileSelections = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-violet-setup-');
    store = LibraryStore.memory();
    controller = AppController(store);
    downloads = DownloadManager(
      store,
      directory,
      clientFactory: () => throw StateError('No downloads in setup tests'),
    );
    final source = sqlite3.open('${directory.path}/user.db');
    source.execute(
      'CREATE TABLE BookmarkGroup (Id INTEGER, Name TEXT, Color INTEGER, Gorder INTEGER)',
    );
    source.execute(
      'CREATE TABLE BookmarkArticle (Id INTEGER, Article INTEGER, GroupId INTEGER, DateTime TEXT)',
    );
    source.execute(
      "INSERT INTO BookmarkGroup VALUES (2, 'Violet collection', 4280640491, 0)",
    );
    source.execute(
      "INSERT INTO BookmarkArticle VALUES (1, 321, 2, '2026-10-28T00:00:00Z')",
    );
    source.close();
    fileSelections = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          (call) async {
            expect(call.method, 'openFile');
            fileSelections++;
            return ['${directory.path}/user.db'];
          },
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });
  Future<void> mount(WidgetTester tester, Widget screen) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.dark),
        home: Scaffold(body: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, String label) async {
    for (
      var attempt = 0;
      attempt < 50 && find.text(label).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(label), findsOneWidget);
  }

  Future<void> finishImport(WidgetTester tester) async {
    await waitFor(tester, 'Import Library');
    expect(fileSelections, 1);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Import'));
    await waitFor(tester, 'Import Complete');
    expect(
      store.items(AppMode.manga).map((saved) => saved.item.id),
      contains(321),
    );
    expect(
      store.folders(AppMode.manga).map((folder) => folder.name),
      contains('Violet collection'),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets(
    'onboarding offers SQLite import first and preserves compatible database data',
    (tester) async {
      await mount(tester, OnboardingScreen(controller: controller));
      final shortcut = find.byKey(const ValueKey('onboarding-violet-shortcut'));
      await tester.ensureVisible(shortcut);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      final violet = find.byKey(const ValueKey('onboarding-violet-import'));
      expect(tester.widget(violet), isA<FilledButton>());
      expect(find.text('Import SQLite Backup'), findsWidgets);
      expect(find.text('Import from Violet'), findsNothing);
      expect(find.text('Anime Boxes'), findsNothing);
      expect(
        tester.getTopLeft(violet).dy,
        lessThan(tester.getTopLeft(find.text('TEGNAL JSON Backup')).dy),
      );
      await tester.tap(violet);
      await finishImport(tester);
    },
  );

  testWidgets(
    'settings exposes generic import near the top and uses the validated importer',
    (tester) async {
      await mount(
        tester,
        SettingsScreen(controller: controller, downloads: downloads),
      );
      final violet = find.text('Import from Other Apps').first;
      expect(violet.hitTestable(), findsOneWidget);
      await tester.tap(violet);
      await finishImport(tester);
    },
  );

  testWidgets(
    'Drive status stays disabled even when a controller is provided',
    (tester) async {
      final drive = DriveSyncController(
        library: controller,
        stateDirectory: Directory('${directory.path}/drive'),
      );
      addTearDown(drive.dispose);
      await mount(
        tester,
        SettingsScreen(
          controller: controller,
          downloads: downloads,
          driveSync: drive,
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Google Drive Sync'),
        400,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Temporarily unavailable'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-chevron-Google Drive Sync')),
        findsNothing,
      );
      await tester.tap(find.text('Google Drive Sync'));
      await tester.pumpAndSettle();
      expect(find.byType(DriveSyncScreen), findsNothing);
      expect(drive.connected, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
