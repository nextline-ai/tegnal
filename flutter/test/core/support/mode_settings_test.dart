import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/support/mode_settings.dart';
import 'package:tegnal/core/support/preferences.dart';

void main() {
  // GridLayoutTests.testDiscordInvitationCadenceAndDismissalPersistAcrossSettingsAndRelaunch
  test('the Discord invitation keeps its cadence across settings visits, relaunches and dismissal', () {
    final defaults = MemoryPreferences();
    final now = DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000);
    const day = Duration(days: 1);
    // The earlier implementation's display date is ignored.
    defaults.set('discord.invitation.nextShow', now.add(day * 3).millisecondsSinceEpoch / 1000);
    final prepared = DiscordInvitation(defaults)..presentIfDue(now);
    expect(prepared.visible, isTrue);
    // Preparing a screen alone must not consume an unseen invitation.
    final env = DiscordInvitation(defaults)..presentIfDue(now);
    expect(env.visible, isTrue);
    env.recordDisplay(now);
    env.presentIfDue(now.add(day));
    env.recordDisplay(now.add(day));
    expect(env.visible, isTrue);
    final beforeDue = DiscordInvitation(defaults)..presentIfDue(now.add(day * 3 - const Duration(seconds: 1)));
    expect(beforeDue.visible, isFalse);
    final relaunched = DiscordInvitation(defaults)..presentIfDue(now.add(day * 3));
    expect(relaunched.visible, isTrue);
    relaunched.recordDisplay(now.add(day * 3));
    relaunched.dismiss(now.add(day * 3));
    expect(relaunched.visible, isFalse);
    relaunched.presentIfDue(now.add(day * 4));
    expect(relaunched.visible, isFalse);
    final afterDismissal = DiscordInvitation(defaults)..presentIfDue(now.add(day * 10 - const Duration(seconds: 1)));
    expect(afterDismissal.visible, isFalse);
    afterDismissal.presentIfDue(now.add(day * 10));
    expect(afterDismissal.visible, isTrue);
  });

  test('resetting comics restores its appearance, browsing and viewer options and keeps the rest', () {
    final preferences = AppPreferences.memory();
    final content = ContentEnvironment(browserPreferences: preferences.defaults);
    content.mangaColumns = 3;
    content.mangaFolderColumns = 2;
    content.mangaRemovesGridPadding = true;
    content.mangaPreviewColumns = 6;
    content.mangaPreviewRows = 2;
    content.showsMangaTitles = false;
    content.showsMangaCategories = true;
    content.defaultTags = 'tag:a';
    content.defaultExcludedTags = 'tag:b';
    content.useEmbeddedBrowser = true;
    AppTheme.light.store(preferences.defaults, booru: false);
    AppTheme.light.store(preferences.defaults, booru: true);
    final defaults = preferences.defaults;
    defaults.set('manga.showInformationBeforeReading', true);
    defaults.set('search.retentionDays', 7);
    defaults.set('search.rememberHistory', false);
    defaults.set('app.resumeAnimation', false);
    defaults.set('reader.mode', 'vertical');
    defaults.set('reader_page_1', 4);
    defaults.set('manga.site_address', 'comics.example');
    defaults.set('app.language', 'ko');

    ModeSettingsReset.reset(booru: false, content: content, preferences: preferences);

    expect(content.mangaColumns, 0);
    expect(content.mangaFolderColumns, 0);
    expect(content.mangaRemovesGridPadding, isFalse);
    expect(content.mangaPreviewColumns, 0);
    expect(content.mangaPreviewRows, 5);
    expect(content.showsMangaTitles, isTrue);
    expect(content.showsMangaCategories, isFalse);
    expect(content.defaultTags, '');
    expect(content.defaultExcludedTags, '');
    expect(content.useEmbeddedBrowser, isFalse);
    expect(AppTheme.stored(defaults, booru: false), AppTheme.dark);
    expect(AppTheme.stored(defaults, booru: true), AppTheme.light, reason: 'Image mode keeps its own theme');
    for (final key in [
      'grid_columns',
      'folder_columns',
      'manga.grid.noPadding',
      'manga.showInformationBeforeReading',
      'search.retentionDays',
      'search.rememberHistory',
      'app.resumeAnimation',
      'reader.mode',
    ]) {
      expect(defaults.object(key), isNull, reason: key);
    }
    expect(defaults.object('reader_page_1'), 4, reason: 'Reading progress is kept');
    expect(defaults.string('manga.site_address'), 'comics.example');
    expect(AppLanguageSetting.stored(defaults), 'ko');
  });

  test('resetting images touches only image keys', () {
    final preferences = AppPreferences.memory();
    final content = ContentEnvironment(browserPreferences: preferences.defaults);
    content.mangaColumns = 3;
    preferences.defaults.set('booru.grid_columns', 4);
    preferences.defaults.set('booru.safeMode', true);
    preferences.booruDefaults.set('booru.fitThumbnails', true);
    preferences.booruDefaults.set('booru.rememberHistory', false);
    ModeSettingsReset.reset(booru: true, content: content, preferences: preferences);
    expect(content.mangaColumns, 3);
    expect(preferences.defaults.object('booru.grid_columns'), isNull);
    expect(preferences.defaults.boolean('booru.safeMode'), isFalse);
    expect(preferences.defaults.string('booru.safeRating'), 'general');
    expect(preferences.booruDefaults.object('booru.fitThumbnails'), isNull);
    expect(SearchHistoryPreferences.remembers(preferences.booruDefaults, booru: true), isTrue);
  });

  test('history and theme preferences read the native defaults', () {
    final defaults = MemoryPreferences();
    expect(SearchHistoryPreferences.remembers(defaults, booru: false), isTrue);
    expect(SearchHistoryPreferences.retentionDays(defaults), 0);
    expect(AppTheme.stored(defaults, booru: false), AppTheme.dark);
    expect(AppLanguageSetting.stored(defaults), 'system');
    expect(ResumeAnimationSetting.stored(defaults), isTrue);
  });
}
