import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/features/insights_screen.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/features/onboarding_screen.dart';
import 'package:tegnal/ui/content_tile.dart';
import 'package:tegnal/ui/navigation.dart';
import 'package:tegnal/ui/privacy_cover.dart';
import 'package:tegnal/ui/common.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  late DownloadManager downloads;
  late Directory directory;
  late _DeferredSource source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-shell-test-');
    store = LibraryStore.memory();
    store.setSetting('onboarding', true);
    store.setSetting('onboarding.importReminderDismissed', true);
    store.setSetting('mode', 'booru');
    store.setSetting('language', 'en');
    store.saveSource(
      SourceConfig(
        id: 'offline',
        name: 'Offline',
        baseUrl: Uri.https('offline.invalid'),
        kind: SourceKind.danbooru,
      ),
    );
    source = _DeferredSource();
    controller = AppController(store, sourceFactory: (_) => source);
    downloads = DownloadManager(
      store,
      directory,
      clientFactory: () => throw StateError('No downloads in shell tests.'),
    );
  });

  tearDown(() async {
    downloads.dispose();
    controller.dispose();
    store.close();
    await directory.delete(recursive: true);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    double bottomViewPadding = 0,
  }) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = FakeViewPadding(bottom: bottomViewPadding);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      TegnalApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(TegnalTabBar),
        matching: find.text(label),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'content notifications preserve the app configuration and themes',
    (tester) async {
      await pumpShell(tester);
      final initial = tester.widget<MaterialApp>(find.byType(MaterialApp));
      controller.changed();
      await tester.pump();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)),
        same(initial),
      );

      controller.setPreference('appearance.booru', 'light');
      await tester.pumpAndSettle();
      final light = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(light.themeMode, ThemeMode.light);
      expect(light.theme, same(initial.theme));
      expect(light.darkTheme, same(initial.darkTheme));
      controller.setPreference('language', 'ko');
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('ko'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('hidden Smart tab defers reports until it is visible again', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('Smart'));
    await tester.pumpAndSettle();
    final screen = find.byType(InsightsScreen, skipOffstage: false);
    final body = find.descendant(
      of: screen,
      matching: find.byType(Scaffold, skipOffstage: false),
      skipOffstage: false,
    );
    final initial = tester.widget<Scaffold>(body);
    await selectTab(tester, 'Saved');
    controller.changed();
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(body), same(initial));
    await tester.tap(find.byTooltip('Smart'));
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(body), isNot(same(initial)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dock stays translucent and privacy cover wraps app content', (
    tester,
  ) async {
    await pumpShell(tester);
    expect(find.byType(TegnalPrivacyCover), findsOneWidget);
    final dock = find.byType(TegnalTabBar);
    expect(dock, findsOneWidget);

    List<ChromeSurface> dockSurfaces() => tester
        .widgetList<ChromeSurface>(
          find.descendant(of: dock, matching: find.byType(ChromeSurface)),
        )
        .toList();

    expect(dockSurfaces(), hasLength(2));
    expect(dockSurfaces().every((surface) => surface.enabled), isTrue);
    controller.setPreference('glass', true);
    await tester.pump();
    expect(dockSurfaces().every((surface) => surface.enabled), isTrue);
    controller.setPreference('glass', false);
    await tester.pump();
    expect(dockSurfaces().every((surface) => surface.enabled), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'root content extends under dock and reserves physical safe inset',
    (tester) async {
      await pumpShell(tester, bottomViewPadding: 34);
      await selectTab(tester, 'More');

      final dockRect = tester.getRect(find.byType(TegnalTabBar));
      final rootNavigatorRect = tester.getRect(find.byType(Navigator).first);
      expect(rootNavigatorRect.bottom, greaterThan(dockRect.top));

      final settingsLists = tester.widgetList<ListView>(
        find.descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(ListView),
        ),
      );
      expect(
        settingsLists.any(
          (list) =>
              ((list.padding as EdgeInsets?)?.bottom ?? 0) >=
              34 + dockRect.height,
        ),
        isTrue,
      );
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('View on GitHub'),
        500,
        scrollable: settingsScroll,
      );
      await tester.drag(settingsScroll, const Offset(0, -400));
      await tester.pumpAndSettle();
      final lastAction = find.text('View on GitHub');
      expect(lastAction.hitTestable(), findsOneWidget);
      expect(tester.getRect(lastAction).bottom, lessThan(dockRect.top));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dock blur remains active when reduced motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: TegnalTabBar(
            labels: const ['Saved', 'Explore', 'Tags', 'More', 'Settings'],
            mode: AppMode.booru,
            selected: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );
    final dock = find.byType(TegnalTabBar);
    final surfaces = tester
        .widgetList<ChromeSurface>(
          find.descendant(of: dock, matching: find.byType(ChromeSurface)),
        )
        .toList();
    expect(surfaces, hasLength(2));
    expect(surfaces.every((surface) => !surface.respectReduceMotion), isTrue);
    expect(
      find.descendant(of: dock, matching: find.byType(BackdropFilter)),
      findsNWidgets(2),
    );
  });

  testWidgets('source picker is above the dock on the root navigator', (
    tester,
  ) async {
    await pumpShell(tester, bottomViewPadding: 34);
    await tester.tap(find.byIcon(Icons.dns_rounded));
    await tester.pumpAndSettle();
    final choice = find.byType(CheckboxListTile).first;
    final rootNavigator = Navigator.of(
      tester.element(find.byType(AppShell)),
      rootNavigator: true,
    );
    expect(Navigator.of(tester.element(choice)), same(rootNavigator));
    expect(find.text('Done').hitTestable(), findsOneWidget);
    final wasSelected = tester.widget<CheckboxListTile>(choice).value!;
    await tester.tap(choice);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(controller.selectedSources(AppMode.booru).isNotEmpty, !wasSelected);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'tabs mount lazily and root folder keyboard preserves background viewport',
    (tester) async {
      await pumpShell(tester);
      expect(find.byType(Navigator, skipOffstage: false), findsNWidgets(2));
      expect(find.byType(SettingsScreen, skipOffstage: false), findsNothing);
      final library = find.byType(LibraryScreen);
      final initialBounds = tester.getRect(library);
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Unsaved folder');
      addTearDown(tester.view.resetViewInsets);
      for (final inset in [80.0, 180.0, 300.0, 180.0, 0.0, 300.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(library), initialBounds);
        expect(find.text('Unsaved folder'), findsOneWidget);
        final backgroundFieldContext = tester.element(
          find.descendant(of: library, matching: find.byType(CustomScrollView)),
        );
        expect(MediaQuery.viewInsetsOf(backgroundFieldContext).bottom, 0);
      }
      await tester.pumpAndSettle();
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(controller.folders(AppMode.booru), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'replayed onboarding sits above dock and primary action is reachable',
    (tester) async {
      await pumpShell(tester, bottomViewPadding: 34);
      await selectTab(tester, 'More');
      final scroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Replay Onboarding'),
        400,
        scrollable: scroll,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Replay Onboarding')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replay Onboarding'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(TegnalTabBar).hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('onboarding-primary')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
      await tester.pumpAndSettle();
      expect(find.text('Import Data'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('onboarding-primary')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(TegnalTabBar).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Android back only pops the active tab navigator', (
    tester,
  ) async {
    await pumpShell(tester);
    await selectTab(tester, 'More');
    await tester.scrollUntilVisible(
      find.text('Reader Settings'),
      350,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Reader Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderDefaultsScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderDefaultsScreen), findsNothing);
    await selectTab(tester, 'Saved');
    expect(find.text('All Favorites'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'mode switch keeps destination, nested routes and mode-specific settings',
    (tester) async {
      await pumpShell(tester);
      await selectTab(tester, 'More');
      await tester.scrollUntilVisible(
        find.text('Reader Settings'),
        350,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Reader Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderDefaultsScreen), findsOneWidget);
      controller.setMode(AppMode.manga);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TegnalTabBar>(find.byType(TegnalTabBar)).selected,
        3,
      );
      expect(find.byType(ReaderDefaultsScreen), findsNothing);
      controller.setMode(AppMode.booru);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderDefaultsScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Reader Settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Explore renders completed async results without changing tabs', (
    tester,
  ) async {
    await pumpShell(tester);
    await selectTab(tester, 'Explore');
    expect(find.byType(ContentTile), findsNothing);
    await tester.pump();
    expect(source.requests, 1);
    expect(controller.explore(AppMode.booru).loading, isTrue);
    source.result.complete(
      const ContentPage([
        ContentItem(
          sourceId: 'offline',
          id: 1,
          mode: AppMode.booru,
          title: 'First',
        ),
        ContentItem(
          sourceId: 'offline',
          id: 2,
          mode: AppMode.booru,
          title: 'Second',
        ),
      ], hasMore: false),
    );
    await tester.pumpAndSettle();

    expect(source.requests, 1, reason: 'No repeat search after completion');
    expect(controller.explore(AppMode.booru).error, isNull);
    expect(controller.explore(AppMode.booru).loading, isFalse);
    expect(find.byType(ContentTile), findsNWidgets(2));
    expect(
      tester
          .widgetList<ContentTile>(find.byType(ContentTile))
          .map((tile) => tile.item.id),
      [1, 2],
    );
    expect(tester.widget<TegnalTabBar>(find.byType(TegnalTabBar)).selected, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _DeferredSource implements ContentSource {
  late final result = Completer<ContentPage>();
  int requests = 0;
  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) {
    requests++;
    return result.future;
  }

  @override
  Future<ContentItem> detail(int id) => throw UnimplementedError();
  @override
  Future<List<ReaderPage>> pages(ContentItem item) =>
      throw UnimplementedError();
  @override
  Future<List<String>> suggestions(String query) async => [];
  @override
  void close() {}
}
