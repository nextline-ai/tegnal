import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/onboarding_screen.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-setup-flow-');
    store = LibraryStore.memory();
    store.setSetting('language', 'en');
    store.saveSource(
      SourceConfig(
        id: 'manga-source',
        name: 'Comics source',
        baseUrl: Uri.https('comics.example'),
        kind: SourceKind.manga,
      ),
    );
    store.saveSource(
      SourceConfig(
        id: 'booru-source',
        name: 'Image source',
        baseUrl: Uri.https('images.example'),
        kind: SourceKind.danbooru,
      ),
    );
    controller = AppController(store);
    downloads = DownloadManager(
      store,
      directory,
      clientFactory: () => throw StateError('No downloads in setup tests.'),
    );
  });

  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  testWidgets('ordinary setup shows configured sources from both modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: OnboardingScreen(controller: controller, mode: AppMode.manga),
      ),
    );

    expect(find.text('Comics source'), findsOneWidget);
    expect(find.text('Image source'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('mode switch step is a preview and setup completes explicitly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.setMode(AppMode.booru);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: OnboardingScreen(controller: controller, mode: AppMode.booru),
      ),
    );

    expect(find.text('Connect a Website'), findsOneWidget);
    final primary = tester.getRect(
      find.byKey(const ValueKey('onboarding-primary')),
    );
    expect(primary.bottom, lessThan(640));
    expect(find.byKey(const ValueKey('onboarding-progress')), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Import Data'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Connect a Website'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Import Data'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Switch Modes'), findsOneWidget);

    await tester.tap(find.byTooltip('Comics'));
    await tester.pumpAndSettle();
    expect(controller.mode, AppMode.booru);
    expect(controller.sources(AppMode.manga), hasLength(1));
    expect(controller.sources(AppMode.booru), hasLength(1));
    expect(controller.onboardingComplete, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Get Started'));
    await tester.pumpAndSettle();
    expect(controller.onboardingComplete, isTrue);
    expect(controller.mode, AppMode.booru);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings and reader defaults retain their route mode', (
    tester,
  ) async {
    controller.setMode(AppMode.booru);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(
            controller: controller,
            downloads: downloads,
            mode: AppMode.manga,
          ),
        ),
      ),
    );

    expect(find.text('Comics source'), findsOneWidget);
    expect(find.text('Image source'), findsNothing);
    final readerSettings = find.text('Reader Settings');
    await tester.scrollUntilVisible(
      readerSettings,
      220,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(readerSettings);
    await tester.pumpAndSettle();
    await tester.tap(readerSettings);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vertical'));
    await tester.pumpAndSettle();
    expect(
      controller.readerPreferences(AppMode.manga).readingMode,
      ReadingMode.vertical,
    );
    expect(
      controller.readerPreferences(AppMode.booru).readingMode,
      ReadingMode.horizontal,
    );
    expect(controller.mode, AppMode.booru);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Booru Pools explains when no servers are selected', (
    tester,
  ) async {
    controller.setMode(AppMode.booru);
    controller.setPreference('selected.booru', <String>[]);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(
            controller: controller,
            downloads: downloads,
            mode: AppMode.booru,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Pools'));
    await tester.pumpAndSettle();

    expect(find.text('No servers selected'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import-only setup opens at imports and Done leaves setup state alone',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: tegnalTheme(Brightness.light),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => OnboardingScreen(
                    controller: controller,
                    importsOnly: true,
                    mode: AppMode.manga,
                  ),
                ),
              ),
              child: const Text('Open imports'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open imports'));
      await tester.pumpAndSettle();
      expect(find.text('Import Data'), findsOneWidget);
      expect(find.text('Switch Modes'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Open imports'), findsOneWidget);
      expect(controller.onboardingComplete, isFalse);
    },
  );

  testWidgets(
    'Booru reader defaults persist Show Notes in their captured mode',
    (tester) async {
      controller.setMode(AppMode.manga);
      await tester.pumpWidget(
        MaterialApp(
          theme: tegnalTheme(Brightness.light),
          home: Scaffold(
            body: SettingsScreen(
              controller: controller,
              downloads: downloads,
              mode: AppMode.booru,
            ),
          ),
        ),
      );

      final readerSettings = find.text('Reader Settings');
      await tester.scrollUntilVisible(
        readerSettings,
        220,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(readerSettings);
      await tester.pumpAndSettle();

      final showNotes = find.byWidgetPredicate(
        (widget) =>
            widget is TegnalSwitch &&
            widget.semanticLabel == 'Show Notes on Images',
      );
      expect(tester.widget<TegnalSwitch>(showNotes).value, isTrue);
      controller.setMode(AppMode.manga);
      await tester.tap(showNotes);
      await tester.pumpAndSettle();
      expect(controller.readerPreferences(AppMode.booru).showNotes, isFalse);
      expect(controller.readerPreferences(AppMode.manga).showNotes, isTrue);
      expect(controller.mode, AppMode.manga);
      expect(tester.takeException(), isNull);
    },
  );
}
