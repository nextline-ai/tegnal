import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_image_cache.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/downloads/download_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/booru/booru_common.dart';
import 'package:tegnal/presentation/navigation/app_state.dart';
import 'package:tegnal/presentation/settings/downloads_view.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';

/// Image mode's context over an in-memory store and the offline fixture source, as the screens get it in the app.
class StudyHarness {
  StudyHarness({bool select = true}) {
    StudyCurriculum.useBundled(StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync()));
    final directory = Directory.systemTemp.createTempSync('study-view-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final database = AppDatabase.inMemory(preferences: preferences);
    state = AppState(mode: AppMode.booru, tab: AppTab.artists);
    store = BooruStore.inMemory(preferences: preferences);
    source = BooruFixtureSource(options: {BooruFixtureOption.studyUITest}, delay: Duration.zero);
    server = BooruFixtureEnvironment.servers.first;
    store.saveServer(server);
    store.setSelectedServers(select ? [server.id] : []);
    booru = BooruContext(
      state: state,
      store: store,
      source: source,
      thumbnails: BooruImageCache(directory: Directory('${directory.path}/thumbnails')),
      viewerImages: BooruImageCache(directory: Directory('${directory.path}/viewer'), isViewer: true),
      database: database,
      preferences: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
      downloads: DownloadsContext(
        store: DownloadStore(
          directory: Directory('${directory.path}/downloads'),
          manga: FixtureContentSource(),
          configuredHost: () => 'comics.example',
          pageDelay: Duration.zero,
        ),
        content: ContentEnvironment.fixture(preferences: preferences.defaults),
        database: database,
        preferences: preferences.defaults,
      ),
      fixture: true,
    );
  }

  final preferences = AppPreferences.memory();
  late final AppState state;
  late final BooruStore store;
  late final BooruFixtureSource source;
  late final BooruServer server;
  late final BooruContext booru;

  /// A phone-wide, tall screen with the app's own theme around [home]: lists build every section at once.
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1206, 9000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CupertinoApp(theme: tegnalTheme(Brightness.light), home: home));
    await tester.pump();
  }
}

/// Lets timers and zero-delay futures run until [finder] matches, up to a few seconds.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 100 && finder.evaluate().isEmpty; step++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}
