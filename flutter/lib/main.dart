import 'core/addons/addon_store.dart';
import 'core/backup/update_backup.dart';

import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'app/localization.dart';
import 'app/privacy_cover.dart';
import 'app/tegnal_app.dart';
import 'core/booru/booru_browser.dart';
import 'core/booru/booru_client.dart';
import 'core/booru/booru_fixture_source.dart';
import 'core/booru/booru_image_cache.dart';
import 'core/booru/booru_models.dart';
import 'core/booru/booru_store.dart';
import 'core/taste/taste_fixtures.dart';
import 'core/taste/taste_models.dart';
import 'core/content/content_environment.dart';
import 'core/content/content_transport.dart';
import 'core/content/encrypted_hello_fetcher.dart';
import 'core/content/fixture_content_source.dart';
import 'core/content/manga_urls.dart';
import 'core/content/site_account.dart';
import 'core/content/site_fallback_content.dart';
import 'core/downloads/download_store.dart';
import 'core/storage/app_database.dart';
import 'core/storage/app_storage.dart';
import 'core/support/document_files.dart';
import 'core/support/perf_trace.dart';
import 'core/support/preferences.dart';
import 'core/support/secure_secret_store.dart';
import 'presentation/booru/booru_web_page.dart';
import 'presentation/content/content_browser_transport.dart';
import 'core/content/reading_queue.dart';
import 'presentation/content/page_image_store.dart';
import 'presentation/content/image_translation.dart';
import 'presentation/content/reader_models.dart';
import 'presentation/navigation/app_state.dart';
import 'presentation/home/home_media.dart';
import 'presentation/home/home_stage.dart';
import 'core/content/recent_works.dart';
import 'core/study/study_guide.dart';
import 'core/study/study_models.dart';
import 'core/study/study_path.dart';
import 'core/support/app_platform.dart';
import 'core/support/privacy_settings.dart';
import 'presentation/settings/site_account_section.dart';
import 'presentation/study_mode/study_kit.dart';

/// `--dart-define=TEGNAL_FIXTURE=on` (or a comma-separated list of [FixtureOption] names,
/// plus `setup` to start without a connected website, and `onboarding` to open the first-run onboarding) runs offline with the native UI
/// tests' synthetic works and an in-memory library, so screens can be compared with the
/// native app's. `TEGNAL_LANGUAGE` and `TEGNAL_TAB` pick the language and the first tab
/// for those runs, `TEGNAL_THEME` (`light`, `dark` or `system`) the comics appearance, and
/// `TEGNAL_DETAILS=true` opens work information before reading, as `-manga.showInformationBeforeReading YES`.
/// `TEGNAL_MODE=booru` starts in image mode with the fixture servers, as `--booru-ui-test`;
/// [BooruFixtureOption] names in `TEGNAL_FIXTURE` pick its variants.
const _fixture = String.fromEnvironment('TEGNAL_FIXTURE');
const _mode = String.fromEnvironment('TEGNAL_MODE');
const _language = String.fromEnvironment('TEGNAL_LANGUAGE');
const _tab = String.fromEnvironment('TEGNAL_TAB');
const _theme = String.fromEnvironment('TEGNAL_THEME');
const _details = bool.fromEnvironment('TEGNAL_DETAILS');

/// `TEGNAL_HOME`: fixture runs start without the home scene unless it is `on`; `blur` holds the opening
/// blur without its still (with the system bars hidden, to capture the still), and `library:0.5` or
/// `study:0.6` hold a journey at that moment for screenshots, as `--home-freeze` does on iOS.
const _home = String.fromEnvironment('TEGNAL_HOME');

/// The native UI tests' saved libraries: `localLibrary` (`--comics-local-library-test`),
/// `categoryLibrary` (`--category-library-test`) and `libraryJump` (`--library-jump-test`).
void _seedLibrary(AppDatabase database, Set<String> names) {
  if (names.contains('localLibrary')) {
    final folder = database.createFolder(name: 'Offline library');
    database.upsertWork(galleryId: 900000001, folderId: folder.id, title: 'Imported work');
  }
  if (names.contains('categoryLibrary')) {
    const categories = ['doujinshi', 'manga', 'artistcg', 'gamecg', 'imageset'];
    for (var index = 0; index < 6; index++) {
      final id = 900000001 + index;
      database.upsertWork(galleryId: id, title: '샘플 작품 ${index + 1}', artists: 'TEGNAL', language: 'korean', type: categories[id % 5], tags: 'tag:example');
    }
  }
  if (names.contains('libraryJump')) {
    final folder = database.createFolder(name: '이동 테스트');
    for (var index = 0; index < 120; index++) {
      final month = 10 - index ~/ 30, day = 30 - index % 30;
      database.upsertWork(
        galleryId: 910000001 + index,
        folderId: folder.id,
        title: '샘플 작품 ${index + 1}',
        bookmarkedAt: '2026-${'$month'.padLeft(2, '0')}-${'$day'.padLeft(2, '0')}T12:00:00Z',
      );
    }
    // Six works saved within seconds of each other, as favorites brought in at once are.
    for (var index = 0; index < 6; index++) {
      database.upsertWork(
        galleryId: 920000001 + index,
        folderId: folder.id,
        title: '함께 저장 ${index + 1}',
        bookmarkedAt: '2026-08-15T08:00:${'${5 - index}'.padLeft(2, '0')}Z',
      );
    }
  }
}

Future<void> main() async {
  final launch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  // Windows and Linux have no official video player; media_kit plays videos behind the same API.
  VideoPlayerMediaKit.ensureInitialized(windows: true, linux: true);
  // An empty first frame ends the system launch screen at once, so the native splash
  // artwork shows while the services below load; the app replaces it when they are ready.
  if (_fixture.isEmpty) runApp(const ColoredBox(color: Color(0xFF000000)));
  final sceneOn = _fixture.isEmpty || _home == 'on' || _home == 'blur' || _home.startsWith('library:') || _home.startsWith('study:');
  // The blurred still is ready before the first real frame, so that frame already shows it.
  final still = sceneOn ? HomeStill.load() : Future<void>.value();
  final services = _fixture.isEmpty ? await PerfTrace.span('launch services', _launch) : await _launchFixture();
  if (_fixture.isNotEmpty) PrivacyCover.skipLaunchSplash();
  HomeStage.shared = HomeStage(defaults: services.preferences.defaults, booruDefaults: services.preferences.booruDefaults, enabled: sceneOn);
  if (sceneOn) HomeStage.shared.onSceneShown = PrivacyCover.launchReady;
  // Learning mode follows the stage from here on: the place on screen and the two start switches are the stage's.
  StudyMode.shared.link(HomeStage.shared);
  await still;
  if (PerfTrace.enabled) {
    PerfTrace.log('launch until first frame scheduled', launch.elapsed);
    // Frames slower than the display's budget, split into the UI thread's build and the raster thread's paint.
    // Each second with frames reports how many missed the display's frame budget on either thread.
    final window = <FrameTiming>[];
    var windowStart = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback((timings) {
      window.addAll(timings);
      if (DateTime.now().difference(windowStart) < const Duration(seconds: 1)) return;
      windowStart = DateTime.now();
      if (window.length < 5) return window.clear();
      final raster = window.map((t) => t.rasterDuration.inMicroseconds ~/ 1000).toList()..sort();
      final build = window.map((t) => t.buildDuration.inMicroseconds ~/ 1000).toList()..sort();
      final rate = WidgetsBinding.instance.platformDispatcher.displays.firstOrNull?.refreshRate ?? 60;
      final budget = 1000000 ~/ (rate < 30 ? 60 : rate);
      final missed = window.where((t) => t.rasterDuration.inMicroseconds > budget || t.buildDuration.inMicroseconds > budget).length;
      PerfTrace.event(
        'frames ${window.length} at ${rate.round()} Hz over budget $missed',
        detail:
            'raster p50 ${raster[raster.length ~/ 2]} p90 ${raster[raster.length * 9 ~/ 10]} max ${raster.last} build p50 ${build[build.length ~/ 2]} p90 ${build[build.length * 9 ~/ 10]} max ${build.last}',
      );
      window.clear();
    });
  }
  runApp(
    TegnalApp(
      services: services,
      initialTab: AppTab.values.where((tab) => tab.name == _tab).firstOrNull ?? AppTab.folders,
      initialMode: _mode == 'booru' ? AppMode.booru : AppMode.manga,
      homeFreeze: kReleaseMode || _home == 'on' ? '' : _home,
    ),
  );
  // The native launch cover stays until the home scene's first picture, the blurred still, has been drawn,
  // or, without the scene, until the app's first frames have.
  if (!sceneOn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) => PrivacyCover.launchReady());
      WidgetsBinding.instance.scheduleFrame();
    });
  }
}

/// The installed version name, as Settings shows the bundle version.
Future<String> _version() async {
  // Desktop builds carry the pubspec version, passed in by the build.
  if (AppPlatform.isDesktop) return const String.fromEnvironment('TEGNAL_VERSION');
  try {
    return await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<String>('version') ?? '';
  } on Object {
    return '';
  }
}

/// `TimeZone.current.identifier`, so taste statistics divide days at the person's midnight.
Future<void> _loadTimeZone() async {
  if (AppPlatform.isDesktop) {
    final zone = await desktopTimeZone();
    if (zone != null) TasteControl.currentTimeZone = zone;
    return;
  }
  try {
    final zone = await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<String>('timeZone');
    if (zone != null && zone.isNotEmpty) TasteControl.currentTimeZone = zone;
  } on Object {
    // Without a platform answer the analysis keeps its default zone.
  }
}

/// The installed build number (Android's `versionCode`), which the backup before an update compares too.
Future<String> _build() async {
  if (AppPlatform.isDesktop) return const String.fromEnvironment('TEGNAL_BUILD');
  try {
    return await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<String>('build') ?? '';
  } on Object {
    return '';
  }
}

/// Names this device in backup files.
Future<String> _deviceName() async {
  try {
    if (AppPlatform.isDesktop) return Platform.localHostname;
    return await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<String>('deviceName') ?? 'Android';
  } on Object {
    return 'Android';
  }
}

Future<AppServices> _launch() async {
  // The backup before an update copies the data the previous version left, so it runs before anything
  // reads preferences or opens a database. It never throws.
  final loadingSupport = getApplicationSupportDirectory();
  final loadingVersion = PerfTrace.span('launch version', _version);
  final backup = await PerfTrace.span(
    'launch backup',
    () async => UpdateBackup.launch(support: await loadingSupport, version: await loadingVersion, build: await _build(), deviceName: await _deviceName()),
  );
  // Independent platform calls start together; each is awaited where it is first needed.
  final loadingSecrets = PerfTrace.span('launch keystore', SecureSecretStore.load);
  final loadingCaches = getApplicationCacheDirectory();
  final loadingTimeZone = _loadTimeZone();
  final preparingStorage = PerfTrace.span('launch storage', AppStorage.prepare);
  final preferences = await PerfTrace.span('launch preferences', AppPreferences.load);
  ContentPreferences.defaults = preferences.defaults;
  PrivacySettings.load();
  ReaderPreferences.install(preferences);
  // Learning mode reads whether it opens the app, and its sounds' switch, from the image-mode preferences.
  StudyMode.shared.attach(preferences.booruDefaults);
  // Whether AI translation can be on; asked early, as Translate needs the answer.
  unawaited(AITranslationModel.check());
  final localizing = PerfTrace.span('launch localization', () => loadLocalization(preferences.defaults));
  // The tag study curriculum is empty until its file is read.
  final studying = Future.wait([StudyCurriculum.loadBundled(), StudyGuide.loadBundled(), StudyPath.loadBundled()]);
  final caches = await loadingCaches;
  PageImageStore.defaultDiskDirectory = Directory('${caches.path}/MangaPageCache');
  ReadingQueue.defaultCoverDirectory = Directory('${caches.path}/ReadingQueue');
  RecentWorks.defaultCoverDirectory = Directory('${caches.path}/RecentWorks');
  await preparingStorage;
  await localizing;
  await studying;
  // Sign-in cookies live in the Android Keystore, never in the database or backups.
  final secrets = await loadingSecrets;
  SiteAccount.store = secrets;
  // A site whose name a network filters is reached with Encrypted Client Hello after its first
  // cut connection, and the hidden browser page of the site is the last resort.
  final network = FilteredNetworkFetcher(primary: IoHttpFetcher(), fallback: EncryptedHelloFetcher(), preferences: preferences.defaults);
  ContentTransport.defaultFetcher = () => network;
  if (AppPlatform.hasWebView) {
    ContentTransport.shared = ContentTransport(browserFetch: ContentBrowserTransport.get, browserPost: ContentBrowserTransport.post);
    if (AppPlatform.hasWebView) ContentTransport.botCheckSolver = BotCheckAutoPass.attempt;
    SiteAccount.listeners.add(ContentBrowserTransport.reset);
  }
  // Image servers' API keys and validated cookies stay in the same keystore.
  final credentials = SecretCredentialStore(secrets);
  BooruClient.defaultCredentials = credentials;
  BooruBrowserSession.shared = BooruBrowserSession(secrets: secrets);
  // Servers that trust only a real browser connection get their requests through a hidden web view.
  if (AppPlatform.hasWebView) BooruWebTransport.factory = WebViewBooruPage.new;
  BooruWebTransport.preferences = preferences.defaults;
  final support = await loadingSupport;
  // Keys of numbered works and where works opened elsewhere outlive the session.
  GalleryKeys.shared = GalleryKeys(file: GalleryKeys.defaultFile(support));
  // The list of where works last opened made them stay there after switching websites.
  final legacySites = File('${support.path}/work-sites.json');
  if (legacySites.existsSync()) legacySites.deleteSync();
  WorkSiteMemory.shared = WorkSiteMemory(file: WorkSiteMemory.defaultFile(support));
  await loadingTimeZone;
  final booru = PerfTrace.sync('launch image store', () => BooruStore(path: AppStorage.booruDbPath, preferences: preferences, credentials: credentials));
  // A track's symbols that learning mode cannot draw give way to its stand-ins, as iOS does for unknown SF Symbols.
  AddonEffects.symbolExists = StudyGlyph.knows;
  AddonRuntime.shared.reload(booru);
  final thumbnails = BooruImageCache.sharedThumbnails = BooruImageCache.thumbnails(caches);
  booru.warmSavedPreview = (post, server) {
    final url = post.previewURL ?? post.sampleURL;
    if (url != null) thumbnails.prefetch([(url, server)]);
  };
  return AppServices(
    preferences: preferences,
    database: PerfTrace.sync('launch database', () => AppDatabase.open(preferences: preferences)),
    booru: booru,
    booruSource: BooruClient.shared,
    booruThumbnails: thumbnails,
    booruViewerImages: BooruImageCache.sharedViewer = BooruImageCache.viewer(caches),
    booruDownloads: BooruMediaDownloader(),
    // Saved works open from whichever connected website still carries them.
    content: ContentEnvironment(browserPreferences: preferences.defaults, source: SiteFallbackContent.shared),
    downloadsDirectory: DownloadStore.defaultDirectory,
    downloadsFilesRoot: await const DocumentFiles().downloadRoot(),
    syncDirectory: Directory('${support.path}/drive-sync'),
    version: await loadingVersion,
    backupSetup: backup?.setup,
  );
}

Future<AppServices> _launchFixture() async {
  final preferences = AppPreferences.memory();
  ContentPreferences.isIsolated = true;
  ContentPreferences.defaults = preferences.defaults;
  if (_language.isNotEmpty) preferences.defaults.set('app.language', _language);
  if (_theme.isNotEmpty) preferences.defaults.set('app_theme', _theme);
  if (_details) preferences.defaults.set('manga.showInformationBeforeReading', true);
  // `--safe-mode-test`: Safe Mode on, so Comics Mode browses Safebooru's pools.
  if (_fixture.split(',').map((name) => name.trim()).contains('safeMode')) preferences.defaults.set('booru.safeMode', true);
  // As the native UI tests do, the reader guide stays hidden unless `readerHelp` asks for it.
  ReaderPreferences.defaults.set('reader.helpHidden', !_fixture.split(',').map((name) => name.trim()).contains('readerHelp'));
  ReaderPreferences.install(preferences);
  await loadLocalization(preferences.defaults);
  await StudyCurriculum.loadBundled();
  await StudyGuide.loadBundled();
  await StudyPath.loadBundled();
  final names = _fixture.split(',').map((name) => name.trim()).toSet();
  StudyMode.shared.attach(preferences.booruDefaults);
  final options = {for (final name in names) ...FixtureOption.values.where((option) => option.name == name)};
  // `setup` starts without a connected website, as `--comics-setup-test` does.
  final content = names.contains('setup')
      ? ContentEnvironment(
          browserPreferences: preferences.defaults,
          source: FixtureContentSource(options: options),
        )
      : ContentEnvironment.fixture(preferences: preferences.defaults, options: options);
  final database = AppDatabase.inMemory(preferences: preferences);
  _seedLibrary(database, names);
  final booruOptions = {for (final name in names) ...BooruFixtureOption.values.where((option) => option.name == name)};
  final booru = BooruStore.inMemory(preferences: preferences);
  if (_mode == 'booru' || names.any(_tasteFixtures.contains)) {
    // The taste fixtures save their own favorites below; seeding them here too would undo them.
    BooruFixtureEnvironment.seed(booru, options: booruOptions.difference({BooruFixtureOption.tasteRich}));
    preferences.booruDefaults.set('reader.helpHidden', !names.contains('readerHelp'));
    if (_theme.isNotEmpty) preferences.defaults.set('booru.app_theme', _theme);
  }
  final booruSource = BooruFixtureSource(options: booruOptions);
  final media = Directory('${Directory.systemTemp.path}/fixture-booru-media');
  Future<Uint8List> fixtureMedia(String url, BooruServer server) => BooruFixtureMedia.load(url, null);
  final services = AppServices(
    preferences: preferences,
    database: database,
    booru: booru,
    booruSource: booruSource,
    booruThumbnails: BooruImageCache(directory: Directory('${media.path}/thumbnails'), loadData: fixtureMedia),
    booruViewerImages: BooruImageCache(directory: Directory('${media.path}/viewer'), loadData: fixtureMedia, isViewer: true),
    booruDownloads: BooruMediaDownloader(source: booruSource),
    content: content,
    downloadsDirectory: Directory('${Directory.systemTemp.path}/fixture-downloads'),
    syncDirectory: Directory('${Directory.systemTemp.path}/fixture-drive-sync'),
    version: await _version(),
    isTesting: true,
    showsOnboarding: names.contains('onboarding'),
  );
  // The native taste, recap and challenge UI tests' libraries.
  if (names.contains('tasteRich') || names.contains('tasteRecap') || names.contains('tasteSoleExclusion')) {
    TasteFixtures.seedRich(
      database: database,
      booru: booru,
      changeControl: services.taste.change,
      recapTest: names.contains('tasteRecap'),
      soleExclusion: names.contains('tasteSoleExclusion'),
    );
    if (names.contains('tasteRecap')) services.taste.prepareCompletedReports();
  }
  if (names.contains('tasteRecapDemo')) TasteFixtures.seedRecapDemo(booru);
  if (names.contains('challenges')) TasteFixtures.seedChallenges(booru, motion: names.contains('challengeMotion'));
  return services;
}

/// `TEGNAL_FIXTURE` names for the taste, recap and challenge tests (`--taste-ui-rich`,
/// `--taste-recap-test`, `--taste-sole-exclusion-test`, `--taste-recap-demo`, `--challenge-ui-test`).
const _tasteFixtures = {'tasteRich', 'tasteRecap', 'tasteSoleExclusion', 'tasteRecapDemo', 'challenges'};
