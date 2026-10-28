import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/app.dart';
import 'package:tegnal/core/drive_sync_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/drive_auth.dart';
import 'package:tegnal/features/drive_sync_screen.dart';
import 'package:tegnal/features/reader_screen.dart';
import 'package:tegnal/features/explore_screen.dart';
import 'package:tegnal/features/artists_screen.dart';
import 'package:tegnal/features/library_screen.dart';
import 'package:tegnal/features/detail_screen.dart';
import 'package:tegnal/features/onboarding_screen.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/l10n.dart';
import 'package:tegnal/ui/navigation.dart';
import 'package:tegnal/ui/content_tile.dart';

import 'capture_fixtures.dart';

const _setupRefinement = bool.fromEnvironment(
  'TEGNAL_CAPTURE_SETUP_REFINEMENT',
);
const _nativeParity = bool.fromEnvironment('TEGNAL_CAPTURE_NATIVE_PARITY');
const _captureStage = String.fromEnvironment(
  'TEGNAL_CAPTURE_STAGE',
  defaultValue: 'after',
);
const _enabled = bool.fromEnvironment('TEGNAL_CAPTURE_UI');
const _parityFlowsOnly = bool.fromEnvironment('TEGNAL_CAPTURE_PARITY_FLOWS');
const _libraryOnly = bool.fromEnvironment('TEGNAL_CAPTURE_LIBRARY_ONLY');
const _communityOnly = bool.fromEnvironment('TEGNAL_CAPTURE_COMMUNITY');
const _bugfixesOnly = bool.fromEnvironment('TEGNAL_CAPTURE_BUGFIXES');
const _polishOnly = bool.fromEnvironment('TEGNAL_CAPTURE_POLISH');
const _refinementsOnly = bool.fromEnvironment('TEGNAL_CAPTURE_REFINEMENTS');

void main() {
  testWidgets('isolated populated UI screenshots and adaptive layouts', (
    tester,
  ) async {
    final marketing = Directory('../user_data/marketing/generated');
    expect(
      marketing.existsSync(),
      isTrue,
      reason: 'Capture requires the local marketing fixtures. See tool/ui_capture.md.',
    );
    final fixtures = CaptureFixtures(marketing);
    final controller = await tester.runAsync(fixtures.load);
    final temp = Directory.systemTemp.createTempSync('tegnal-ui-capture-');
    final downloads = CaptureDownloads(fixtures.store, temp);
    final driveSync = DriveSyncController(
      featureEnabled: true,
      library: controller!,
      stateDirectory: Directory('${temp.path}/drive-sync'),
      auth: GoogleDriveAuth(platform: TargetPlatform.android),
    );
    await tester.runAsync(driveSync.initialize);
    final previousOverrides = HttpOverrides.current;
    final offlineImages = CaptureHttpOverrides(fixtures.images);
    HttpOverrides.global = offlineImages;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      driveSync.dispose();
      downloads.dispose();
      controller.dispose();
      fixtures.store.close();
      HttpOverrides.global = previousOverrides;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      temp.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await L10n.load();
      await (FontLoader('Pretendard')
            ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
          .load();
      await (FontLoader('Pretendard JP')
            ..addFont(rootBundle.load('assets/fonts/PretendardJPVariable.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });

    final output = Directory(
      _communityOnly
          ? 'build/ui-captures/community'
          : _setupRefinement
          ? 'build/ui-captures/setup-refinement'
          : _nativeParity
          ? 'build/ui-captures/native-parity/$_captureStage'
          : _libraryOnly
          ? 'build/ui-captures/library-selector'
          : _polishOnly
          ? 'build/ui-captures/polish'
          : _bugfixesOnly
          ? 'build/ui-captures/bugfixes'
          : _refinementsOnly
          ? 'build/ui-captures/refinements'
          : _parityFlowsOnly
          ? 'build/ui-captures/parity-flows'
          : 'build/ui-captures',
    )..createSync(recursive: true);
    final boundaryKey = GlobalKey();
    final errors = <String>[];
    Future<void> settle() async {
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      // Let native image decoding finish outside the fake widget-test clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await settle();
      Object? error;
      while ((error = tester.takeException()) != null) {
        errors.add('$name: $error');
      }
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      debugPrint('Captured $name');
    }

    void expectLoadedImages(int minimum) {
      final loaded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null)
          .length;
      expect(loaded, greaterThanOrEqualTo(minimum));
    }

    Future<void> waitForDecodedArtwork(int minimum) async {
      int loaded() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null)
          .length;
      for (var attempt = 0; attempt < 100 && loaded() < minimum; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        loaded(),
        greaterThanOrEqualTo(minimum),
        reason: 'Screenshots must show decoded artwork, never pending placeholders.',
      );
    }

    int loadedContentTileCount() {
      final tiles = find.byType(ContentTile);
      var loaded = 0;
      for (var index = 0; index < tiles.evaluate().length; index++) {
        final imageFinder = find.descendant(
          of: tiles.at(index),
          matching: find.byType(RawImage),
        );
        if (tester
            .widgetList<RawImage>(imageFinder)
            .any((image) => image.image != null)) {
          loaded++;
        }
      }
      return loaded;
    }

    Future<void> waitForLoadedContentTiles(int minimum) async {
      for (
        var attempt = 0;
        attempt < 25 && loadedContentTileCount() < minimum;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 160)),
        );
        await tester.pump(const Duration(milliseconds: 80));
      }
      if (loadedContentTileCount() < minimum) {
        debugPrint(
          'Loaded ${loadedContentTileCount()} content tiles; image requests '
          '${offlineImages.imageRequests}, completed '
          '${offlineImages.imageResponsesCompleted}.',
        );
      }
      expect(loadedContentTileCount(), greaterThanOrEqualTo(minimum));
    }

    Future<void> mount({
      Size size = const Size(402, 874),
      double scale = 1,
      String appearance = 'dark',
    }) async {
      await tester.pumpWidget(const SizedBox());
      final pixelRatio = _nativeParity ? 2.0 : 1.0;
      tester.view.devicePixelRatio = pixelRatio;
      tester.view.physicalSize = size * pixelRatio;
      tester.view.padding = size.width < 840
          ? FakeViewPadding(top: 59 * pixelRatio, bottom: 34 * pixelRatio)
          : const FakeViewPadding();
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      controller.setPreference('appearance', appearance);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: TegnalApp(
            controller: controller,
            downloads: downloads,
            driveSync: driveSync,
          ),
        ),
      );
      await settle();
    }

    Future<void> tab(int index) async {
      final navigation =
          tester.view.physicalSize.width / tester.view.devicePixelRatio >= 840
          ? find.byType(TegnalSidebar)
          : find.byType(TegnalTabBar);
      if (tester.view.physicalSize.width / tester.view.devicePixelRatio >=
          840) {
        await tester.tap(
          find
              .descendant(
                of: navigation,
                matching: find.byType(NavigationDrawerDestination),
              )
              .at(index),
        );
      } else if (index < 4) {
        await tester.tap(
          find
              .descendant(of: navigation, matching: find.byType(TextButton))
              .at(index),
        );
      } else {
        await tester.tap(
          find
              .descendant(of: navigation, matching: find.byType(IconButton))
              .last,
        );
      }
      await settle();
      if (tester.view.physicalSize.width / tester.view.devicePixelRatio < 840) {
        expect(tester.widget<TegnalTabBar>(navigation).selected, index);
      }
    }

    Future<void> shortcut(int index) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(
        [
          LogicalKeyboardKey.digit1,
          LogicalKeyboardKey.digit2,
          LogicalKeyboardKey.digit3,
          LogicalKeyboardKey.digit4,
          LogicalKeyboardKey.digit5,
        ][index],
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle();
      expect(
        tester.widget<TegnalTabBar>(find.byType(TegnalTabBar)).selected,
        index,
        reason: 'Consecutive Ctrl-number navigation must follow active tabs',
      );
    }

    await mount();
    if (_communityOnly) {
      await tab(3);
      await capture('booru-invitation');
      for (final mode in [AppMode.booru, AppMode.manga]) {
        if (controller.mode != mode) {
          controller.setMode(mode);
          await settle();
        }
        final screen = find.byType(SettingsScreen).hitTestable();
        final scroll = find
            .descendant(of: screen, matching: find.byType(Scrollable))
            .first;
        final badge = find.descendant(
          of: screen,
          matching: find.byKey(const ValueKey('developer.community')),
        );
        await tester.scrollUntilVisible(badge, 500, scrollable: scroll);
        final github = find.descendant(
          of: screen,
          matching: find.byKey(const ValueKey('developer.github')),
        );
        await Scrollable.ensureVisible(tester.element(github), alignment: .5);
        await tester.drag(scroll, const Offset(0, -600));
        await settle();
        final dock = tester.getRect(find.byType(TegnalTabBar));
        expect(github.hitTestable(), findsOneWidget);
        expect(tester.getRect(github).bottom, lessThan(dock.top));
        for (var attempt = 0; attempt < 20; attempt++) {
          final loaded = tester
              .widgetList<RawImage>(
                find.descendant(of: screen, matching: find.byType(RawImage)),
              )
              .where((image) => image.image != null)
              .length;
          if (loaded >= 2) break;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await tester.pump();
        }
        expect(badge.hitTestable(), findsOneWidget);
        expect(
          tester
              .widgetList<RawImage>(
                find.descendant(of: screen, matching: find.byType(RawImage)),
              )
              .where((image) => image.image != null)
              .length,
          greaterThanOrEqualTo(2),
        );
        await capture('${mode.name}-developer');
      }
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_setupRefinement) {
      await waitForDecodedArtwork(24);
      final originalFolderCount = controller.folders(AppMode.booru).length;
      await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
      await settle();
      await tester.enterText(find.byType(TextField).first, '자동 색상 폴더');
      expect(find.byKey(const ValueKey('folder-creation-color')), findsNothing);
      await capture('folder-create-name-only');
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await settle();
      expect(controller.folders(AppMode.booru).length, originalFolderCount);
      final created = <LibraryFolder>[];
      for (var index = 1; index <= 3; index++) {
        await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
        await settle();
        await tester.enterText(find.byType(TextField).first, '자동 색상 $index');
        await tester.tap(find.widgetWithText(FilledButton, '저장'));
        await settle();
        created.add(
          controller
              .folders(AppMode.booru)
              .firstWhere((folder) => folder.name == '자동 색상 $index'),
        );
      }
      expect(created.map((folder) => folder.color), [
        0xFFD97706,
        0xFFDB2777,
        0xFF4F46E5,
      ]);
      final libraryScroll = find
          .descendant(
            of: find.byType(LibraryScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('자동 색상 1'),
        240,
        scrollable: libraryScroll,
      );
      await capture('folder-automatic-assigned-colors');
      for (final folder in created) {
        controller.deleteFolder(folder);
      }

      controller.setPreference('onboarding', false);
      await mount();
      final violetShortcut = find.byKey(
        const ValueKey('onboarding-import-shortcut'),
      );
      await tester.ensureVisible(violetShortcut);
      await capture('onboarding-import-shortcut');
      await tester.tap(violetShortcut);
      await settle();
      await capture('onboarding-primary-import');
      controller.setPreference('onboarding', true);
      await mount();
      await tab(3);
      await capture('settings-prominent-import');
      final scroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Google Drive 동기화'),
        350,
        scrollable: scroll,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Google Drive 동기화')),
        alignment: .2,
      );
      await settle();
      expect(
        find.byKey(const ValueKey('settings-chevron-Google Drive Sync')),
        findsNothing,
      );
      await capture('settings-drive-temporarily-disabled');
      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_nativeParity) {
      await waitForDecodedArtwork(24);
      await capture('library');
      await tab(1);
      await waitForLoadedContentTiles(12);
      await capture('explore');
      await tab(0);
      await tester.tap(find.text('모든 즐겨찾기'));
      await settle();
      await capture('collection');
      await tester.tap(find.text('선택'));
      await settle();
      await tester.tap(find.byType(ContentTile).at(0));
      await tester.tap(find.byType(ContentTile).at(1));
      await capture('organize');
      await tester.tap(find.byIcon(Icons.close));
      await settle();
      controller.setReaderPreferences(
        AppMode.booru,
        controller.readerPreferences(AppMode.booru).copyWith(bottomMenu: true),
      );
      await tester.tap(find.byType(ContentTile).at(3));
      await settle();
      await waitForDecodedArtwork(1);
      await capture('reader');
      await tester.tapAt(const Offset(201, 437));
      await settle();
      await capture('reader-controls');
      await tester.tap(find.text('나가기'));
      await settle();

      await mount();
      await tester.longPress(find.text('풍경'));
      await settle();
      await capture('folder-actions');
      await tester.tap(find.text('색상 변경'));
      await settle();
      await capture('folder-color');
      await tester.tap(find.byTooltip('완료'));
      await settle();
      await tester.longPress(find.text('풍경'));
      await settle();
      await tester.tap(find.text('폴더 순서 변경'));
      await settle();
      await capture('folder-order');
      await tester.tap(find.text('취소'));
      await settle();

      await tab(2);
      final tagsScroll = find
          .descendant(
            of: find.byType(ArtistsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('검색 기록'),
        250,
        scrollable: tagsScroll,
      );
      await capture('saved-searches');
      await tab(1);
      await tester.tap(find.byKey(const ValueKey('explore.search')));
      tester.view.viewInsets = FakeViewPadding(
        bottom: 300 * tester.view.devicePixelRatio,
      );
      await settle();
      await capture('search-history');
      FocusManager.instance.primaryFocus?.unfocus();
      tester.view.viewInsets = const FakeViewPadding();
      await settle();
      await tab(3);
      await capture('settings');
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      controller.setPreference('safeMode.booru', true);
      await settle();
      final safeLabel = L10n.tr(
        tester.element(find.byType(SettingsScreen)),
        'Image Rating Filter',
      );
      for (
        var attempt = 0;
        attempt < 20 && find.text(safeLabel).evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(settingsScroll, const Offset(0, -220));
        await settle();
      }
      expect(find.text(safeLabel), findsWidgets);
      await Scrollable.ensureVisible(
        tester.element(find.text(safeLabel).first),
        alignment: .1,
      );
      await settle();
      await capture('safe-mode');
      await tester.scrollUntilVisible(
        find.text('라이브러리 관리'),
        220,
        scrollable: settingsScroll,
      );
      await tester.tap(find.text('라이브러리 관리'));
      await settle();
      await capture('backup');
      controller.setPreference('safeMode.booru', false);
      await mount(size: const Size(320, 740), scale: 1.5);
      await capture('compact-large-text-library');
      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_libraryOnly) {
      await waitForDecodedArtwork(24);
      await capture('booru-library-source-selector');
      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_refinementsOnly) {
      await tab(1);
      await waitForLoadedContentTiles(3);
      final exploreScroll = find
          .descendant(
            of: find.byType(ExploreScreen),
            matching: find.byType(CustomScrollView),
          )
          .first;
      await tester.drag(exploreScroll, const Offset(0, 700));
      await settle();
      expect(find.byKey(const ValueKey('explore.search')), findsOneWidget);
      await capture('booru-explore-no-more-overlay');

      await tab(3);
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      final themeValue = find.byKey(const ValueKey('settings-value-Theme'));
      await tester.scrollUntilVisible(
        themeValue,
        220,
        scrollable: settingsScroll,
      );
      await capture('settings-theme-language-right-alignment');

      final systemAiValue = find.byKey(
        const ValueKey('settings-value-System AI'),
      );
      await tester.scrollUntilVisible(
        systemAiValue,
        220,
        scrollable: settingsScroll,
      );
      await capture('settings-on-device-right-alignment');

      final replayTitle = L10n.tr(
        tester.element(find.byType(SettingsScreen)),
        'Replay Onboarding',
      );
      final replayOnboarding = find.text(replayTitle);
      for (
        var attempt = 0;
        attempt < 12 && replayOnboarding.evaluate().isEmpty;
        attempt++
      ) {
        await tester.drag(settingsScroll, const Offset(0, -480));
        await settle();
      }
      expect(replayOnboarding, findsOneWidget);
      await tester.tap(replayOnboarding);
      await settle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(TegnalTabBar), findsNothing);
      expect(find.byKey(const ValueKey('onboarding-footer')), findsOneWidget);
      await capture('settings-replay-onboarding-root-route');

      await mount(size: const Size(320, 740));
      await tab(3);
      final compactSettingsScroll = find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-value-Theme')),
        220,
        scrollable: compactSettingsScroll,
      );
      await tester.drag(compactSettingsScroll, const Offset(0, 120));
      await settle();
      await capture('settings-theme-language-right-alignment-320');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-value-System AI')),
        220,
        scrollable: compactSettingsScroll,
      );
      await tester.drag(compactSettingsScroll, const Offset(0, 120));
      await settle();
      await capture('settings-on-device-right-alignment-320');

      controller.setMode(AppMode.manga);
      await mount();
      await tester.tap(find.text('모든 즐겨찾기'));
      await settle();
      await tester.tap(
        find.ancestor(
          of: find.text('A quiet afternoon'),
          matching: find.byType(ContentTile),
        ),
      );
      await settle();
      expect(find.byType(DetailScreen), findsOneWidget);
      expectLoadedImages(1);
      await capture('manga-work-details-initial-metadata');
      final detailScroll = find.byKey(const ValueKey('content.detail.scroll'));
      await tester.drag(detailScroll, const Offset(0, -620));
      await settle();
      expect(
        find.byKey(const ValueKey('content.detail.preview.1')),
        findsOneWidget,
      );
      expectLoadedImages(4);
      await capture('manga-work-details-after-drag-page-previews');

      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_polishOnly) {
      final libraryScroll = find
          .descendant(
            of: find.byType(LibraryScreen),
            matching: find.byType(CustomScrollView),
          )
          .first;
      await capture('saved-icons-top');
      await tester.drag(libraryScroll, const Offset(0, -300));
      await settle();
      await capture('saved-icons-scrolled');

      await tester.tap(find.byIcon(Icons.dns_rounded));
      await settle();
      await capture('saved-server-picker-root');
      final l10nContext = tester.element(find.byType(TegnalTabBar));
      await tester.tap(find.text(L10n.tr(l10nContext, 'Done')).last);
      await settle();

      await tab(1);
      final searchField = find.byKey(const ValueKey('explore.search'));
      expect(searchField, findsOneWidget);
      await capture('explore-search-visible');
      final exploreScroll = find
          .descendant(
            of: find.byType(ExploreScreen),
            matching: find.byType(CustomScrollView),
          )
          .first;
      await tester.drag(exploreScroll, const Offset(0, -360));
      await settle();
      await capture('explore-search-scrolled-hidden');

      // Check the enlarged reader controls at the narrowest supported width.
      await mount(size: const Size(320, 740));
      await tester.tap(
        find.text(
          L10n.tr(tester.element(find.byType(TegnalTabBar)), 'All Favorites'),
        ),
      );
      await settle();
      await tester.tap(find.byType(ContentTile).first);
      await settle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      await tester.tapAt(const Offset(160, 370));
      await settle();
      await capture('reader-controls-320');

      // Render the actual onboarding route in the fixture app. The preview
      // remains illustrative; stepping through it must not change the library.
      controller.setPreference('onboarding', false);
      await mount();
      expect(find.byKey(const ValueKey('onboarding-footer')), findsOneWidget);
      await capture('onboarding-connect');
      await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
      await settle();
      await capture('onboarding-import');
      await tester.tap(find.byKey(const ValueKey('onboarding-primary')));
      await settle();
      await capture('onboarding-mode-preview');
      expect(controller.mode, AppMode.booru);

      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_bugfixesOnly) {
      await capture('saved-dock-background');

      // Capture the real add-source sheet with keyboard metrics, while keeping
      // the fixture offline and avoiding a platform keyboard/device.
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      final sourceSheet = showAddSource(
        tester.element(find.byType(TegnalTabBar)),
        controller,
        mode: AppMode.booru,
      );
      await settle();
      await capture('source-add-keyboard-insets');
      await tester.tap(find.text('취소'));
      await settle();
      await sourceSheet;
      tester.view.viewInsets = const FakeViewPadding();
      await settle();

      final brandArtwork = find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName.contains('splash_'),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(milliseconds: 120));
      expect(brandArtwork, findsOneWidget);
      await capture('privacy-cover-inactive');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 599));
      expect(brandArtwork, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump(const Duration(milliseconds: 650));
      await settle();
      expect(brandArtwork, findsNothing);

      controller.setMode(AppMode.manga);
      await settle();
      await capture('manga-mode-header');

      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(offlineImages.unexpectedRequests, isEmpty);
      return;
    }
    if (_parityFlowsOnly) {
      await capture('booru-library-before');

      await tab(2);
      await tester.scrollUntilVisible(
        find.text('검색 기록'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await capture('booru-search-history');
      await tester.tap(find.text('scenery sky').last);
      await settle();
      expect(find.byType(ExploreScreen), findsOneWidget);
      await capture('booru-explore-from-history');

      await tab(0);
      await tester.tap(find.text('모든 즐겨찾기'));
      await settle();
      await tester.tap(find.byType(ContentTile).first);
      await settle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      await capture('booru-reader-sequence');
      await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
      await settle();
      await capture('booru-reader-sequence-controls');
      await tester.tap(find.text('나가기'));
      await settle();

      controller.setMode(AppMode.manga);
      await settle();
      await capture('manga-library-before');
      await mount(size: const Size(320, 740));
      await capture('manga-library-compact-320');
      await mount();
      await tester.tap(find.byIcon(Icons.add).first);
      await settle();
      await capture('manga-add-work-empty');
      await tester.enterText(
        find.byType(TextField).first,
        'https://e-hentai.org/r/100012\nhttps://reader.example/reader/100013.html',
      );
      await settle();
      await capture('manga-add-work-detected');
      await tester.tap(find.widgetWithText(FilledButton, '저장'));
      await settle();
      await capture('manga-library-after-add');
      await tester.tap(find.text('모든 즐겨찾기'));
      await settle();
      await tester.tap(
        find.ancestor(
          of: find.text('A quiet afternoon'),
          matching: find.byType(ContentTile),
        ),
      );
      await settle();
      expect(find.byType(ReaderScreen), findsNothing);
      await capture('manga-work-details');
      await tester.drag(
        find.byKey(const ValueKey('content.detail.scroll')),
        const Offset(0, -620),
      );
      await settle();
      expect(
        find.byKey(const ValueKey('content.detail.preview.1')),
        findsOneWidget,
      );
      await capture('manga-gallery-preview');
      await tester.tapAt(const Offset(300, 12));
      await settle();
      await tester.tap(find.byType(BackButton).last);
      await settle();

      controller.setPreference('onboarding.importReminderDismissed', false);
      await settle();
      await capture('manga-import-reminder');
      await tester.tap(find.text('다른 앱에서 데이터 가져오기'));
      await settle();
      await capture('manga-import-onboarding');

      await tester.runAsync(
        () => File('${output.path}/validation.txt').writeAsString(
          errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
        ),
      );
      expect(errors, isEmpty);
      expect(
        offlineImages.unexpectedRequests,
        isEmpty,
        reason: 'Screenshot fixtures must not access external networks.',
      );
      return;
    }
    for (final index in [1, 2, 3, 4, 0]) {
      await shortcut(index);
    }
    await capture('dark-ko-library');
    controller.setPreference('glass', true);
    await capture('dark-ko-library-glass');
    controller.setPreference('glass', false);
    await tester.tap(find.text('모든 즐겨찾기'));
    await settle();
    expect(find.byType(TegnalTabBar), findsOneWidget);
    await capture('dark-ko-collection');
    await tester.longPress(find.byType(ContentTile).first);
    await settle();
    await tester.tap(find.text('상세설정'));
    await settle();
    await capture('dark-ko-detail');
    await tester.tapAt(const Offset(300, 12));
    await settle();
    await tester.tap(find.byType(ContentTile).first);
    await settle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(find.byType(TegnalTabBar), findsNothing);
    await capture('dark-ko-reader');
    await tester.tapAt(tester.getCenter(find.byType(ReaderScreen)));
    await settle();
    await capture('dark-ko-reader-controls');
    await tester.tap(find.text('나가기'));
    await settle();
    await tester.tap(find.byType(BackButton));
    await settle();
    await tab(1);
    await tab(0);
    expect(
      find.byType(BackButton),
      findsOneWidget,
      reason: 'Returning to a tab must preserve its collection navigation',
    );
    await tester.tap(find.byType(BackButton));
    await settle();
    expect(find.text('모든 즐겨찾기'), findsOneWidget);
    for (final (index, name) in [
      (1, 'explore'),
      (2, 'tags'),
      (3, 'more'),
      (4, 'smart'),
    ]) {
      await tab(index);
      if (index == 1) {
        controller.explore().items = fixtures.items.take(3).toList();
        controller.changed();
        await settle();
        expect(
          find.descendant(
            of: find.byType(ExploreScreen),
            matching: find.byType(ContentTile),
          ),
          findsNWidgets(3),
          reason: 'Mounted nested Explore route must reflect async results',
        );
        controller.explore().items = List.of(fixtures.items);
        controller.changed();
        await settle();
      }
      if (index == 3) {
        expect(
          find.text('Translucent navigation (Experimental)'),
          findsNothing,
        );
      }
      await capture('dark-ko-$name');
    }
    await tab(3);
    final settingsScroll = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Google Drive 동기화'),
      250,
      scrollable: settingsScroll,
    );
    expect(find.byType(DriveSyncScreen), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-chevron-Google Drive Sync')),
      findsNothing,
    );
    expect(driveSync.connected, isFalse);
    await capture('dark-ko-drive-temporarily-disabled');
    await tester.scrollUntilVisible(
      find.text('라이브러리 관리'),
      250,
      scrollable: settingsScroll,
    );
    await tester.drag(settingsScroll, const Offset(0, -180));
    await settle();
    await tester.tap(find.text('라이브러리 관리'));
    await settle();
    expect(find.byType(TegnalTabBar), findsOneWidget);
    await capture('dark-ko-backup');
    await tester.tap(find.byType(BackButton));
    await settle();
    expect(find.byType(TegnalTabBar), findsOneWidget);
    await mount(appearance: 'light');
    await capture('light-ko-library');
    await mount(size: const Size(1200, 800));
    await capture('desktop-dark-ko-library');
    await tab(1);
    await capture('desktop-dark-ko-explore');
    await mount(size: const Size(320, 740), scale: 1.5);
    await capture('compact-large-text-library');
    await tab(3);
    await capture('compact-large-text-more');
    await tester.runAsync(
      () => File('${output.path}/validation.txt').writeAsString(
        errors.isEmpty ? 'No framework errors.\n' : errors.join('\n\n'),
      ),
    );
    expect(errors, isEmpty);
    expect(
      offlineImages.unexpectedRequests,
      isEmpty,
      reason: 'Screenshot fixtures must not access external networks.',
    );
  }, skip: !_enabled && !_bugfixesOnly && !_polishOnly);
}
