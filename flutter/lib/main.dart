import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app/localization.dart';
import 'app/tegnal_app.dart';
import 'core/booru/booru_store.dart';
import 'core/content/content_environment.dart';
import 'core/content/fixture_content_source.dart';
import 'core/content/manga_content_source.dart';
import 'core/content/manga_urls.dart';
import 'core/storage/app_database.dart';
import 'core/storage/app_storage.dart';
import 'core/support/preferences.dart';
import 'presentation/content/page_image_store.dart';
import 'presentation/content/reader_models.dart';
import 'presentation/navigation/app_state.dart';

/// `--dart-define=TEGNAL_FIXTURE=on` (or a comma-separated list of [FixtureOption] names,
/// plus `setup` to start without a connected website) runs offline with the native UI
/// tests' synthetic works and an in-memory library, so screens can be compared with the
/// native app's. `TEGNAL_LANGUAGE` and `TEGNAL_TAB` pick the language and the first tab
/// for those runs, `TEGNAL_THEME` (`light`, `dark` or `system`) the comics appearance, and
/// `TEGNAL_DETAILS=true` opens work information before reading, as `-manga.showInformationBeforeReading YES`.
const _fixture = String.fromEnvironment('TEGNAL_FIXTURE');
const _language = String.fromEnvironment('TEGNAL_LANGUAGE');
const _tab = String.fromEnvironment('TEGNAL_TAB');
const _theme = String.fromEnvironment('TEGNAL_THEME');
const _details = bool.fromEnvironment('TEGNAL_DETAILS');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = _fixture.isEmpty ? await _launch() : await _launchFixture();
  runApp(TegnalApp(services: services, initialTab: AppTab.values.where((tab) => tab.name == _tab).firstOrNull ?? AppTab.folders));
}

Future<AppServices> _launch() async {
  final preferences = await AppPreferences.load();
  ContentPreferences.defaults = preferences.defaults;
  await AppStorage.prepare();
  ReaderPreferences.install(preferences);
  PageImageStore.defaultDiskDirectory = Directory('${(await getApplicationCacheDirectory()).path}/MangaPageCache');
  await loadLocalization(preferences.defaults);
  return AppServices(
    preferences: preferences,
    database: AppDatabase.open(preferences: preferences),
    booru: BooruStore(path: AppStorage.booruDbPath, preferences: preferences),
    content: ContentEnvironment(browserPreferences: preferences.defaults, source: MangaContentSource.shared),
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
  return AppServices(
    preferences: preferences,
    database: AppDatabase.inMemory(preferences: preferences),
    booru: BooruStore.inMemory(preferences: preferences),
    content: content,
    isTesting: true,
  );
}
