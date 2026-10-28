import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/content_filter.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/l10n.dart';

void main() {
  late Directory directory;
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;

  setUp(() async {
    await L10n.load();
    directory = await Directory.systemTemp.createTemp('tegnal-runtime-copy-');
    store = LibraryStore.memory();
    controller = AppController(
      store,
      sourceFactory: (_) => throw StateError('Offline copy tests'),
    );
    downloads = DownloadManager(store, directory);
  });
  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, AppMode mode) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    controller.setMode(mode);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.dark),
        home: Scaffold(
          body: SettingsScreen(
            controller: controller,
            downloads: downloads,
            mode: mode,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'image rating copy describes defaults while the protection guard remains active',
    (tester) async {
      controller.setPreference('safeMode.booru', true);
      await mount(tester, AppMode.booru);
      final footer = find.textContaining('Applies the selected default rating');
      await tester.scrollUntilVisible(
        footer,
        400,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(footer), alignment: .5);
      await tester.pumpAndSettle();
      expect(find.text('Image Rating Filter'), findsWidgets);
      expect(find.text('Safe Mode'), findsNothing);
      expect(
        find.textContaining('Existing rating terms are preserved.'),
        findsOneWidget,
      );
      expect(find.textContaining('turn this off'), findsNothing);
      controller.setMode(AppMode.manga);
      expect(controller.mode, AppMode.booru);
      expect(controller.modePreference('safeMode', AppMode.booru), isTrue);
    },
  );

  testWidgets(
    'unsupported language exceptions are explained without deleting saved preferences',
    (tester) async {
      store.setSetting('allowsLanguageExceptions.manga', true);
      await mount(tester, AppMode.manga);
      final footer = find.textContaining(
        'Category-based language exceptions are not supported.',
      );
      await tester.scrollUntilVisible(
        footer,
        400,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(footer, findsOneWidget);
      expect(find.text('Allow Language Filter Exceptions'), findsNothing);
      expect(store.setting('allowsLanguageExceptions.manga'), isTrue);
    },
  );

  testWidgets(
    'block editor uses ordinary examples and retains existing rating-rule compatibility',
    (tester) async {
      store.saveSource(
        SourceConfig(
          id: 'fixture',
          name: 'Fixture site',
          baseUrl: Uri.https('fixture.invalid'),
          kind: SourceKind.danbooru,
        ),
      );
      await mount(tester, AppMode.booru);
      await tester.tap(find.byTooltip('Servers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture site'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blocked Tags'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('landscape, id:123 or artist:name'),
        findsOneWidget,
      );
      expect(find.textContaining('rating:explicit'), findsNothing);
      await tester.enterText(find.byType(TextField), 'rating:explicit');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      final stored = store.setting('blacklist.fixture') as String;
      expect(stored, 'rating:explicit');
      expect(
        ContentFilter(stored).contains(
          const ContentItem(
            sourceId: 'fixture',
            id: 1,
            mode: AppMode.booru,
            title: 'Fixture',
            metadata: {'rating': 'e'},
          ),
        ),
        isTrue,
      );
    },
  );
}
