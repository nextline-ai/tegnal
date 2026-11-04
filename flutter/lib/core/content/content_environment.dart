import 'package:flutter/foundation.dart';

import '../support/l10n.dart';
import '../support/preferences.dart';
import '../support/swift_json.dart';
import '../support/swift_url.dart';
import 'fixture_content_source.dart';
import 'gallery_content.dart';
import 'manga_content_source.dart';
import 'manga_urls.dart';
import 'site_account.dart';

/// The comics connection and explore settings of `AppEnvironment`, with the same
/// preference keys, so the explore screens and settings read one model.
class ContentEnvironment extends ChangeNotifier {
  ContentEnvironment({required this.browserPreferences, ContentProviding? source})
    : source = source ?? MangaContentSource.shared,
      _isOnboardingCompleted = browserPreferences.boolean('onboarding_completed') ?? false,
      _useEmbeddedBrowser = browserPreferences.boolean('use_embedded_browser') ?? false,
      _allowsMangaLanguageExceptions = browserPreferences.boolean('manga.languageExceptions') ?? false,
      _defaultTags = browserPreferences.string('manga.defaultTags') ?? '',
      _defaultExcludedTags = browserPreferences.string('manga.defaultExcludedTags') ?? '',
      _mangaBrowseCategory = browserPreferences.string('manga.browseCategory') ?? '',
      _hiddenMangaGalleryIDs = _ids(browserPreferences.object('manga.hiddenGalleryIDs')),
      _showsMangaTitles = browserPreferences.boolean('manga.grid.showTitles') ?? true,
      _showsMangaArtists = browserPreferences.boolean('manga.grid.showArtists') ?? true,
      _showsMangaCategories = browserPreferences.boolean('manga.grid.showCategories') ?? false,
      _mangaColumns = browserPreferences.integer('grid_columns').clamp(0, 5),
      _mangaFolderColumns = browserPreferences.integer('folder_columns').clamp(0, 5),
      _mangaPreviewColumns = browserPreferences.integer('manga.preview.columns').clamp(0, 10),
      _mangaPreviewRows = (browserPreferences.integerOrNull('manga.preview.rows') ?? 5).clamp(1, 10),
      _mangaRemovesGridPadding = browserPreferences.boolean('manga.grid.noPadding') ?? false,
      _syncsAccountFavorites = browserPreferences.boolean('manga.syncAccountFavorites') ?? false,
      _siteAccountSignedIn = SiteAccount.isSignedIn,
      _isSiteVerified = (browserPreferences.boolean('site_verified') ?? false) && supportsComicsAddress(browserPreferences.string('manga.site_address') ?? ''),
      // Like Swift's initializer, restoring the address does not reset what was discovered for it.
      _mangaSiteAddress = browserPreferences.string('manga.site_address') ?? '';

  /// The offline run the native UI tests and screenshots use: fixture works and a connected `comics.example`.
  factory ContentEnvironment.fixture({Preferences? preferences, Set<FixtureOption> options = const {}}) {
    ContentPreferences.isIsolated = true;
    final environment = ContentEnvironment(
      browserPreferences: preferences ?? MemoryPreferences(),
      source: FixtureContentSource(options: options),
    );
    environment.verifySite('comics.example');
    return environment;
  }

  final Preferences browserPreferences;

  /// Where explore reads works from: the connected site, or the fixture.
  final ContentProviding source;

  static Set<int> _ids(Object? value) => value is List ? value.whereType<String>().map(int.tryParse).nonNulls.toSet() : {};

  T _store<T>(String key, T value) {
    browserPreferences.set(key, value);
    notifyListeners();
    return value;
  }

  String _mangaSiteAddress;
  String get mangaSiteAddress => _mangaSiteAddress;
  set mangaSiteAddress(String value) {
    final previous = _mangaSiteAddress;
    // A site connected before the list existed joins it before another takes its place.
    ComicSites.add(previous);
    _mangaSiteAddress = value;
    ComicSites.switchSite(from: previous, to: value);
    browserPreferences.set('manga.site_address', value);
    if (ContentPreferences.isIsolated) MangaUrls.preferences.set('manga.site_address', value);
    ComicSites.add(value);
    notifyListeners();
  }

  /// The connected comics websites, the active one included.
  List<String> get comicSites => ComicSites.all;

  /// Makes another connected site the active one.
  void switchComicsSite(String site) {
    if (site == _mangaSiteAddress || !ComicSites.all.contains(site)) return;
    isSiteVerified = true;
    mangaSiteAddress = site;
  }

  /// Forgets a site; forgetting the active one moves to the next, or disconnects.
  void removeComicsSite(String site) {
    final remaining = ComicSites.all.where((value) => value != site).toList();
    if (site == _mangaSiteAddress) {
      if (remaining.isNotEmpty) {
        switchComicsSite(remaining.first);
      } else {
        isSiteVerified = false;
        mangaSiteAddress = '';
      }
    }
    ComicSites.remove(site);
    notifyListeners();
  }

  bool _isSiteVerified;
  bool get isSiteVerified => _isSiteVerified;
  set isSiteVerified(bool value) => _isSiteVerified = _store('site_verified', value);

  bool _isOnboardingCompleted;
  bool get isOnboardingCompleted => _isOnboardingCompleted;
  set isOnboardingCompleted(bool value) => _isOnboardingCompleted = _store('onboarding_completed', value);

  /// New opt-in fallback; the old preference selected native UI versus an external browser.
  bool _useEmbeddedBrowser;
  bool get useEmbeddedBrowser => _useEmbeddedBrowser;
  set useEmbeddedBrowser(bool value) => _useEmbeddedBrowser = _store('use_embedded_browser', value);

  bool _allowsMangaLanguageExceptions;
  bool get allowsMangaLanguageExceptions => _allowsMangaLanguageExceptions;
  set allowsMangaLanguageExceptions(bool value) => _allowsMangaLanguageExceptions = _store('manga.languageExceptions', value);

  String _defaultTags;
  String get defaultTags => _defaultTags;
  set defaultTags(String value) => _defaultTags = _store('manga.defaultTags', value);

  String _defaultExcludedTags;
  String get defaultExcludedTags => _defaultExcludedTags;
  set defaultExcludedTags(String value) => _defaultExcludedTags = _store('manga.defaultExcludedTags', value);

  /// The category the main comics feed is narrowed to, empty for all.
  String _mangaBrowseCategory;
  String get mangaBrowseCategory => _mangaBrowseCategory;
  set mangaBrowseCategory(String value) => _mangaBrowseCategory = _store('manga.browseCategory', value);

  Set<int> _hiddenMangaGalleryIDs;
  Set<int> get hiddenMangaGalleryIDs => _hiddenMangaGalleryIDs;
  set hiddenMangaGalleryIDs(Set<int> value) {
    _hiddenMangaGalleryIDs = {...value};
    _store('manga.hiddenGalleryIDs', (value.toList()..sort()).map((id) => '$id').toList());
  }

  /// Reads synced preferences again after a library sync wrote them. Only changed values
  /// are assigned: writing back absent defaults would upload them as fresh edits.
  void reloadSyncedPreferences() {
    final preferences = browserPreferences;
    final tags = preferences.string('manga.defaultTags') ?? '';
    final exclusions = preferences.string('manga.defaultExcludedTags') ?? '';
    final hidden = _ids(preferences.object('manga.hiddenGalleryIDs'));
    final address = preferences.string('manga.site_address') ?? '';
    final verified = (preferences.boolean('site_verified') ?? false) && supportsComicsAddress(address);
    final changed =
        _defaultTags != tags ||
        _defaultExcludedTags != exclusions ||
        !setEquals(_hiddenMangaGalleryIDs, hidden) ||
        _isSiteVerified != verified ||
        _mangaSiteAddress != address;
    _defaultTags = tags;
    _defaultExcludedTags = exclusions;
    _hiddenMangaGalleryIDs = hidden;
    _isSiteVerified = verified;
    if (_mangaSiteAddress != address) {
      final previous = _mangaSiteAddress;
      ComicSites.add(previous);
      _mangaSiteAddress = address;
      ComicSites.switchSite(from: previous, to: address);
      ComicSites.add(address);
    }
    if (changed) notifyListeners();
  }

  void setMangaGalleryHidden(int id, {required bool hidden}) {
    if (id <= 0) return;
    hiddenMangaGalleryIDs = hidden ? {..._hiddenMangaGalleryIDs, id} : (_hiddenMangaGalleryIDs.toSet()..remove(id));
  }

  void blockMangaArtist(String name) {
    final artist = splitWhitespace(name).join('_');
    if (artist.isEmpty) return;
    final rule = 'artist:$artist';
    final existing = splitWhitespace(defaultExcludedTags);
    if (existing.any((term) => term.toLowerCase() == rule.toLowerCase() || term.toLowerCase() == '-${rule.toLowerCase()}')) return;
    defaultExcludedTags = [...existing, rule].join(' ');
  }

  bool _showsMangaTitles;
  bool get showsMangaTitles => _showsMangaTitles;
  set showsMangaTitles(bool value) => _showsMangaTitles = _store('manga.grid.showTitles', value);

  bool _showsMangaArtists;
  bool get showsMangaArtists => _showsMangaArtists;
  set showsMangaArtists(bool value) => _showsMangaArtists = _store('manga.grid.showArtists', value);

  bool _showsMangaCategories;
  bool get showsMangaCategories => _showsMangaCategories;
  set showsMangaCategories(bool value) => _showsMangaCategories = _store('manga.grid.showCategories', value);

  /// Zero follows the screen width.
  int _mangaColumns;
  int get mangaColumns => _mangaColumns;
  set mangaColumns(int value) => _mangaColumns = _store('grid_columns', value.clamp(0, 5));

  int _mangaFolderColumns;
  int get mangaFolderColumns => _mangaFolderColumns;
  set mangaFolderColumns(int value) => _mangaFolderColumns = _store('folder_columns', value.clamp(0, 5));

  /// Zero follows twice the resolved artwork grid column count.
  int _mangaPreviewColumns;
  int get mangaPreviewColumns => _mangaPreviewColumns;
  set mangaPreviewColumns(int value) => _mangaPreviewColumns = _store('manga.preview.columns', value.clamp(0, 10));

  int _mangaPreviewRows;
  int get mangaPreviewRows => _mangaPreviewRows;
  set mangaPreviewRows(int value) => _mangaPreviewRows = _store('manga.preview.rows', value.clamp(1, 10));

  bool _mangaRemovesGridPadding;
  bool get mangaRemovesGridPadding => _mangaRemovesGridPadding;
  set mangaRemovesGridPadding(bool value) => _mangaRemovesGridPadding = _store('manga.grid.noPadding', value);

  bool _syncsAccountFavorites;
  bool get syncsAccountFavorites => _syncsAccountFavorites;
  set syncsAccountFavorites(bool value) => _syncsAccountFavorites = _store('manga.syncAccountFavorites', value);

  /// Signed in to the connected website, for sites that use accounts.
  bool _siteAccountSignedIn;
  bool get siteAccountSignedIn => _siteAccountSignedIn;
  void refreshSiteAccount() {
    _siteAccountSignedIn = SiteAccount.isSignedIn;
    notifyListeners();
  }

  /// The first feed of the comics tab, in the content language of the app.
  GalleryQuery get launchMangaQuery =>
      GalleryQuery(language: L10n.contentLanguage)
          .filteredTo(mangaBrowseCategory)
          .applyingDefaults(tags: defaultTags, excluded: defaultExcludedTags)
          .copyWith(allowsLanguageExceptions: allowsMangaLanguageExceptions);

  static bool supportsComicsAddress(String input) {
    final value = input.trim();
    if (value.isEmpty) return false;
    final url = SwiftURLComponents.parse(value.contains('://') ? value : 'https://$value');
    final host = url?.host?.toLowerCase();
    if (url == null || host == null || host.isEmpty) return false;
    if (url.user != null || url.password != null) return false;
    if (!host.contains('.') && host != 'localhost') return false;
    if (host.startsWith('.') || host.endsWith('.')) return false;
    if (!ContentPreferences.isIsolated && ['example', 'test', 'invalid'].contains(host.split('.').last)) return false;
    final scheme = url.scheme.toLowerCase();
    return scheme == 'https' || scheme == 'http';
  }

  static String normalizedComicsAddress(String input) {
    final raw = input.trim();
    final host = SwiftURLComponents.parse(raw.contains('://') ? raw : 'https://$raw')?.host?.toLowerCase();
    if (host == null) return raw.toLowerCase();
    // As for image servers, a site is the same with or without `www.`, and its other hosts
    // are named from the bare one.
    return host.startsWith('www.') ? host.substring(4) : host;
  }

  bool verifySite(String input) {
    final cleaned = input.trim();
    final isValid = supportsComicsAddress(cleaned);
    if (isValid) {
      isSiteVerified = true;
      mangaSiteAddress = normalizedComicsAddress(cleaned);
    }
    return isValid;
  }
}
