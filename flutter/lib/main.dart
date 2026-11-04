import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/localization.dart';
import 'app/tegnal_app.dart';
import 'core/booru/booru_browser.dart';
import 'core/booru/booru_client.dart';
import 'core/booru/booru_fixture_source.dart';
import 'core/booru/booru_image_cache.dart';
import 'core/booru/booru_models.dart';
import 'core/booru/booru_store.dart';
import 'core/content/content_environment.dart';
import 'core/content/fixture_content_source.dart';
import 'core/content/manga_content_source.dart';
import 'core/content/manga_urls.dart';
import 'core/content/site_account.dart';
import 'core/downloads/download_store.dart';
import 'core/storage/app_database.dart';
import 'core/storage/app_storage.dart';
import 'core/support/preferences.dart';
import 'core/support/secure_secret_store.dart';
import 'presentation/content/page_image_store.dart';
import 'presentation/content/reader_models.dart';
import 'presentation/navigation/app_state.dart';

/// `--dart-define=TEGNAL_FIXTURE=on` (or a comma-separated list of [FixtureOption] names,
/// plus `setup` to start without a connected website) runs offline with the native UI
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
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = _fixture.isEmpty ? await _launch() : await _launchFixture();
  runApp(
    TegnalApp(
      services: services,
      initialTab: AppTab.values.where((tab) => tab.name == _tab).firstOrNull ?? AppTab.folders,
      initialMode: _mode == 'booru' ? AppMode.booru : AppMode.manga,
    ),
  );
}

/// The installed version name, as Settings shows the bundle version.
Future<String> _version() async {
  try {
    return await const MethodChannel('work.nextline.tegnal/screen').invokeMethod<String>('version') ?? '';
  } on Object {
    return '';
  }
}

Future<AppServices> _launch() async {
  final preferences = await AppPreferences.load();
  ContentPreferences.defaults = preferences.defaults;
  await AppStorage.prepare();
  ReaderPreferences.install(preferences);
  PageImageStore.defaultDiskDirectory = Directory('${(await getApplicationCacheDirectory()).path}/MangaPageCache');
  await loadLocalization(preferences.defaults);
  // Sign-in cookies live in the Android Keystore, never in the database or backups.
  final secrets = await SecureSecretStore.load();
  SiteAccount.store = secrets;
  // Image servers' API keys and validated cookies stay in the same keystore.
  final credentials = SecretCredentialStore(secrets);
  BooruClient.defaultCredentials = credentials;
  BooruBrowserSession.shared = BooruBrowserSession(secrets: secrets);
  final support = await getApplicationSupportDirectory();
  final caches = await getApplicationCacheDirectory();
  final booru = BooruStore(path: AppStorage.booruDbPath, preferences: preferences, credentials: credentials);
  final thumbnails = BooruImageCache.sharedThumbnails = BooruImageCache.thumbnails(caches);
  booru.warmSavedPreview = (post, server) {
    final url = post.previewURL ?? post.sampleURL;
    if (url != null) thumbnails.prefetch([(url, server)]);
  };
  return AppServices(
    preferences: preferences,
    database: AppDatabase.open(preferences: preferences),
    booru: booru,
    booruSource: BooruClient.shared,
    booruThumbnails: thumbnails,
    booruViewerImages: BooruImageCache.sharedViewer = BooruImageCache.viewer(caches),
    booruDownloads: BooruMediaDownloader(),
    content: ContentEnvironment(browserPreferences: preferences.defaults, source: MangaContentSource.shared),
    downloadsDirectory: DownloadStore.defaultDirectory,
    syncDirectory: Directory('${support.path}/drive-sync'),
    version: await _version(),
  );
}

Future<AppServices> _launchFixture() async {
  final preferences = AppPreferences.memory();
  ContentPreferences.isIsolated = true;
  ContentPreferences.defaults = preferences.defaults;
  if (_language.isNotEmpty) preferences.defaults.set('app.language', _language);
  if (_theme.isNotEmpty) preferences.defaults.set('app_theme', _theme);
  if (_details) preferences.defaults.set('manga.showInformationBeforeReading', true);
  // As the native UI tests do, the reader guide stays hidden unless `readerHelp` asks for it.
  ReaderPreferences.defaults.set('reader.helpHidden', !_fixture.split(',').map((name) => name.trim()).contains('readerHelp'));
  ReaderPreferences.install(preferences);
  await loadLocalization(preferences.defaults);
  final names = _fixture.split(',').map((name) => name.trim()).toSet();
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
  if (_mode == 'booru') {
    BooruFixtureEnvironment.seed(booru, options: booruOptions);
    preferences.booruDefaults.set('reader.helpHidden', !names.contains('readerHelp'));
    if (_theme.isNotEmpty) preferences.defaults.set('booru.app_theme', _theme);
  }
  final booruSource = BooruFixtureSource(options: booruOptions);
  final media = Directory('${Directory.systemTemp.path}/fixture-booru-media');
  Future<Uint8List> fixtureMedia(String url, BooruServer server) => BooruFixtureMedia.load(url, null);
  return AppServices(
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
  );
}
