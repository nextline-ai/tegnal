import '../../presentation/content/reader_models.dart';
import '../content/content_environment.dart';
import 'preferences.dart';

/// `AppTheme`: each library keeps its own appearance, dark unless changed.
enum AppTheme {
  dark,
  light,
  system;

  String get rawValue => name;

  /// The English key for `L10n.text`.
  String get title => switch (this) {
    dark => 'Dark Mode',
    light => 'Light Mode',
    system => 'System Default',
  };

  static String key({required bool booru}) => booru ? 'booru.app_theme' : 'app_theme';

  static AppTheme stored(Preferences preferences, {required bool booru}) =>
      values.where((theme) => theme.rawValue == preferences.string(key(booru: booru))).firstOrNull ?? dark;

  void store(Preferences preferences, {required bool booru}) => preferences.set(key(booru: booru), rawValue);
}

/// `appLanguage`: `system` follows the device; otherwise `en`, `ko` or `ja`.
abstract final class AppLanguageSetting {
  static const key = 'app.language';
  static const choices = ['system', 'en', 'ko', 'ja'];
  static String stored(Preferences preferences) => preferences.string(key) ?? 'system';
  static void store(Preferences preferences, String value) => preferences.set(key, value);
}

/// `SearchHistorySettings`: whether searches are remembered, and for how long.
abstract final class SearchHistoryPreferences {
  static const retentionKey = 'search.retentionDays';

  /// Days to keep, with 0 meaning always, in the native picker's order.
  static const retentionChoices = [3, 7, 30, 0];

  static String rememberKey({required bool booru}) => booru ? 'booru.rememberHistory' : 'search.rememberHistory';
  static bool remembers(Preferences preferences, {required bool booru}) => preferences.boolean(rememberKey(booru: booru)) ?? true;
  static int retentionDays(Preferences preferences) => preferences.integerOrNull(retentionKey) ?? 0;
}

/// "Play Animation When Returning".
abstract final class ResumeAnimationSetting {
  static const key = 'app.resumeAnimation';
  static bool stored(Preferences preferences) => preferences.boolean(key) ?? true;
}

/// The occasional Discord invitation in Settings: shown when due, due again three days after
/// it was seen, and a week after it was dismissed.
class DiscordInvitation {
  DiscordInvitation(this.preferences);

  final Preferences preferences;

  // Separate from the earlier key, whose date could be consumed while offscreen.
  static const nextKey = 'discord.invitation.nextPresentation';

  bool _visible = false;
  bool _recorded = false;

  bool get visible => _visible;

  double get _next => switch (preferences.object(nextKey)) {
    final num value => value.toDouble(),
    _ => 0,
  };

  static double _seconds(DateTime time) => time.millisecondsSinceEpoch / 1000;

  /// Preparing a screen does not use up an invitation nobody has seen.
  void presentIfDue([DateTime? now]) {
    if (_visible || _next > _seconds(now ?? DateTime.now())) return;
    _visible = true;
    _recorded = false;
  }

  /// Called when the invitation is actually on screen; staying in Settings keeps its date.
  void recordDisplay([DateTime? now]) {
    if (!_visible || _recorded) return;
    _recorded = true;
    preferences.set(nextKey, _seconds(now ?? DateTime.now()) + 3 * 86400);
  }

  void dismiss([DateTime? now]) {
    _visible = false;
    preferences.set(nextKey, _seconds(now ?? DateTime.now()) + 7 * 86400);
  }
}

/// `resetModeSettings(booru:)`: restores one mode's appearance, browsing and viewer options.
/// Libraries, website connections, sign-in details and sync settings stay as they are.
abstract final class ModeSettingsReset {
  static void reset({required bool booru, required ContentEnvironment content, required AppPreferences preferences}) {
    final browser = content.browserPreferences;
    if (booru) {
      browser.set('booru.safeMode', false);
      browser.set('booru.safeRating', 'general');
    } else {
      content.mangaColumns = 0;
      content.mangaFolderColumns = 0;
      content.mangaRemovesGridPadding = false;
      content.mangaPreviewColumns = 0;
      content.mangaPreviewRows = 5;
      content.showsMangaTitles = true;
      content.showsMangaArtists = true;
      content.showsMangaCategories = false;
      content.allowsMangaLanguageExceptions = false;
      content.defaultTags = '';
      content.defaultExcludedTags = '';
      content.useEmbeddedBrowser = false;
    }
    AppTheme.dark.store(browser, booru: booru);
    for (final key
        in booru
            ? const ['booru.grid_columns', 'booru.folder_columns', 'booru.grid.noPadding']
            : const ['grid_columns', 'folder_columns', 'manga.grid.noPadding', MangaThumbnailOpening.preferenceKey]) {
      browser.remove(key);
    }
    final reader = booru ? preferences.booruDefaults : preferences.defaults;
    for (final key in [
      SearchHistoryPreferences.retentionKey,
      SearchHistoryPreferences.rememberKey(booru: booru),
      'booru.fitThumbnails',
      'booru.useEmbeddedBrowser',
    ]) {
      reader.remove(key);
    }
    browser.remove(ResumeAnimationSetting.key);
    ReaderPreferenceReset.reset(booru: booru, defaults: reader);
  }
}
