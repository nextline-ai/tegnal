import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/support/mode_settings.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/booru/booru_common.dart';
import 'package:tegnal/presentation/browser/in_app_manga_browser_view.dart';

void main() {
  // NativeContentTests.testBrowserRejectsUnsafeNavigationSchemesAndCredentials
  test('the website fallback rejects unsafe navigation schemes and credentials', () {
    for (final raw in ['https://comics.example/reader/123.html#1', 'https://site.example/', 'http://site.example/']) {
      expect(EmbeddedBrowserPolicy.allows(Uri.parse(raw)), isTrue, reason: raw);
    }
    for (final raw in ['javascript:alert(1)', 'file:///tmp/private', 'data:text/html,test', 'https://user:password@site.example', 'tegnal://123']) {
      expect(EmbeddedBrowserPolicy.allows(Uri.parse(raw)), isFalse, reason: raw);
    }
  });

  test('blank pages load only inside frames of the page', () {
    expect(EmbeddedBrowserPolicy.permits('https://comics.example/g/1/', isMainFrame: true), isTrue);
    expect(EmbeddedBrowserPolicy.permits('about:blank', isMainFrame: false), isTrue);
    expect(EmbeddedBrowserPolicy.permits('about:blank', isMainFrame: true), isFalse);
    expect(EmbeddedBrowserPolicy.permits('intent://open', isMainFrame: true), isFalse);
  });

  test('resetting image settings turns the embedded browser off', () {
    final preferences = AppPreferences.memory();
    preferences.booruDefaults.set(BooruContext.embeddedBrowserKey, true);
    ModeSettingsReset.reset(
      booru: true,
      content: ContentEnvironment(browserPreferences: preferences.defaults),
      preferences: preferences,
    );
    expect(preferences.booruDefaults.boolean(BooruContext.embeddedBrowserKey), isNull);
  });
}
