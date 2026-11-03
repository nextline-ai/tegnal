import '../support/preferences.dart';

/// The configured comics site. Only the parts the library needs live here so far.
abstract final class MangaUrls {
  static String configuredHome(Preferences preferences) {
    final saved = preferences.string('manga.site_address');
    if (saved == null || saved.isEmpty) return '';
    final clean = saved.trim();
    if (clean.contains('://')) return clean.endsWith('/') ? clean : '$clean/';
    return 'https://$clean/';
  }

  static String home(Preferences preferences) => configuredHome(preferences);

  /// The site address without its trailing slash, which names a comic's source.
  static String source(Preferences preferences) {
    final home = MangaUrls.home(preferences);
    return home.endsWith('/') ? home.substring(0, home.length - 1) : home;
  }
}
