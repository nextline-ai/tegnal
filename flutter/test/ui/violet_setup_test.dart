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
import 'package:tegnal/ui/l10n.dart';

void main() {
  late Directory directory;
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  var fileSelections = 0;
  late String selectedPath;
  var acceptedExtensions = <String>[];
  var acceptedLabel = '';
  setUp(() async {
    await L10n.load();
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
    final android = sqlite3.open('${directory.path}/bookmarks.db.sqlite');
    android.execute("""
      CREATE TABLE android_metadata(locale TEXT);
      CREATE TABLE BookmarkGroup(Id INTEGER,Name TEXT,DateTime TEXT,Description TEXT,Color INTEGER,Gorder INTEGER);
      CREATE TABLE BookmarkArticle(Id INTEGER,Article TEXT,DateTime TEXT,GroupId INTEGER);
      CREATE TABLE BookmarkArtist(Id INTEGER,Artist TEXT,IsGroup INTEGER,DateTime TEXT,GroupId INTEGER);
      CREATE TABLE ArticleReadLog(Id INTEGER,Article TEXT,DateTimeStart TEXT,DateTimeEnd TEXT,LastPage INTEGER,Type INTEGER);
      CREATE TABLE BookmarkCropImage(Id INTEGER,Article INTEGER,Page INTEGER,Area TEXT,AspectRatio REAL,DateTime TEXT);
      CREATE TABLE SearchLog(Id INTEGER,SearchWhat TEXT,DateTime TEXT);
      CREATE TABLE DownloadItem(Id INTEGER,PrivatePath TEXT);
      INSERT INTO BookmarkGroup VALUES (2,'Violet collection','2026-10-28','Fixture group',4280640491,0);
      INSERT INTO BookmarkArticle VALUES (1,'321','2026-10-28T00:00:00Z',2);
      INSERT INTO BookmarkArtist VALUES (1,'Fixture artist',0,'2026-10-28T00:00:00Z',2);
      INSERT INTO ArticleReadLog VALUES (1,'321','2026-10-28T00:00:00Z','2026-10-28T00:10:00Z',3,0);
      INSERT INTO BookmarkCropImage VALUES (1,321,2,'fixture crop',1.0,'2026-10-28');
      INSERT INTO SearchLog VALUES (1,'fixture_search','2026-10-28T00:00:00Z');
      INSERT INTO DownloadItem VALUES (1,'synthetic-local-file');
    """);
    android.close();
    selectedPath = '${directory.path}/bookmarks.db.sqlite';
    acceptedExtensions = [];
    fileSelections = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          (call) async {
            expect(call.method, 'openFile');
            fileSelections++;
            final groups =
                (call.arguments as Map)['acceptedTypeGroups'] as List;
            acceptedLabel = (groups.first as Map)['label'] as String;
            acceptedExtensions = ((groups.first as Map)['extensions'] as List)
                .cast<String>();
            return [selectedPath];
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
    'onboarding imports Android SQLite bookmarks after preview and confirmation',
    (tester) async {
      await mount(tester, OnboardingScreen(controller: controller));
      final shortcut = find.byKey(const ValueKey('onboarding-import-shortcut'));
      await tester.ensureVisible(shortcut);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      final violet = find.byKey(const ValueKey('onboarding-import-action'));
      expect(tester.widget(violet), isA<FilledButton>());
      expect(find.text('Import Data from Other Manga Viewers'), findsWidgets);
      expect(find.text('Import from Violet'), findsNothing);
      expect(find.text('Anime Boxes'), findsNothing);
      expect(find.text('Image Library Backup'), findsNothing);
      expect(find.text('Other Backup Formats'), findsNothing);
      expect(find.textContaining('Android'), findsNothing);
      expect(
        tester.getTopLeft(violet).dy,
        lessThan(tester.getTopLeft(find.text('TEGNAL JSON Backup')).dy),
      );
      await tester.tap(violet);
      await waitFor(tester, 'Import Library');
      expect(acceptedExtensions, contains('sqlite'));
      expect(acceptedLabel, 'SQLite Backup from Other Manga Viewers');
      expect(acceptedExtensions, isNot(contains('abbj')));
      expect(store.saved('manga:321'), isNull);
      expect(
        find.textContaining('Read-log records (preserved)'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Download records not imported'),
        findsOneWidget,
      );
      expect(
        find.textContaining('not included in TEGNAL JSON backups'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Reader positions and image crops are not applied.',
        ),
        findsOneWidget,
      );
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
      final violet = find.text('Import Data from Other Manga Viewers').first;
      expect(violet.hitTestable(), findsOneWidget);
      await tester.tap(violet);
      await finishImport(tester);
    },
  );

  testWidgets(
    'cancelling the Android preview leaves the saved library unchanged',
    (tester) async {
      store.saveItem(
        const ContentItem(
          sourceId: '',
          id: 999,
          mode: AppMode.manga,
          title: 'Existing',
        ),
        note: 'Keep',
      );
      await mount(
        tester,
        SettingsScreen(controller: controller, downloads: downloads),
      );
      await tester.tap(find.text('Import Data from Other Manga Viewers').first);
      await waitFor(tester, 'Import Library');
      expect(store.saved('manga:321'), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(store.savedKeys(), {'manga:999'});
      expect(store.saved('manga:999')!.note, 'Keep');
      expect(store.folders(AppMode.manga), isEmpty);
      expect(find.text('Import Complete'), findsNothing);
    },
  );

  testWidgets(
    'the primary importer rejects an older database without losing data',
    (tester) async {
      selectedPath = '${directory.path}/user.db';
      store.saveItem(
        const ContentItem(
          sourceId: '',
          id: 999,
          mode: AppMode.manga,
          title: 'Existing',
        ),
        note: 'Keep',
      );
      await mount(
        tester,
        SettingsScreen(controller: controller, downloads: downloads),
      );
      await tester.tap(find.text('Import Data from Other Manga Viewers').first);
      await waitFor(tester, 'Unable to Import');
      expect(
        find.textContaining(
          'Choose a SQLite database from another manga viewer.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('No library data was changed.'),
        findsOneWidget,
      );
      expect(store.savedKeys(), {'manga:999'});
      expect(store.saved('manga:999')!.note, 'Keep');
      expect(store.folders(AppMode.manga), isEmpty);
      expect(find.text('Import Library'), findsNothing);
    },
  );

  testWidgets('Settings keeps old user databases behind Other Backup Formats', (
    tester,
  ) async {
    selectedPath = '${directory.path}/user.db';
    await mount(
      tester,
      SettingsScreen(controller: controller, downloads: downloads),
    );
    await tester.scrollUntilVisible(
      find.text('Other Backup Formats'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Other Backup Formats')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other Backup Formats'));
    await waitFor(tester, 'Import Library');
    expect(acceptedExtensions, containsAll(['db', 'abbj']));
    await finishImport(tester);
  });

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
