import 'dart:async';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../core/booru/booru_account.dart';
import '../core/booru/booru_client.dart';
import '../core/booru/booru_image_cache.dart';
import '../core/booru/booru_store.dart';
import '../core/content/content_environment.dart';
import '../core/content/site_favorites_sync.dart';
import '../core/content/cover_queue.dart';
import '../core/downloads/download_store.dart';
import '../core/support/mode_settings.dart';
import '../core/taste/taste_controller.dart';
import '../core/sync/library_drive_sync.dart';
import '../core/storage/app_database.dart';
import '../core/support/l10n.dart';
import '../core/support/preferences.dart';
import '../core/taste/taste_models.dart';
import '../presentation/booru/booru_common.dart';
import '../presentation/browser/in_app_manga_browser_view.dart';
import '../presentation/challenge/challenge_library_view.dart';
import '../presentation/design/grouped_form.dart';
import '../presentation/design/symbols.dart';
import '../presentation/design/system_colors.dart';
import '../presentation/imports/import_views.dart';
import '../presentation/settings/settings_rows.dart';
import '../presentation/taste/taste_context.dart';
import '../presentation/taste/taste_dashboard.dart';
import '../presentation/taste/taste_settings_view.dart';
import '../presentation/taste/recap/recap_banner.dart';
import '../presentation/taste/recap/recap_home_view.dart';
import '../presentation/booru/booru_root.dart';
import '../presentation/booru/booru_settings_views.dart';
import '../presentation/content/content_bookmark.dart';
import '../presentation/content/content_routes.dart';
import '../presentation/content/explore_view.dart';
import '../presentation/content/page_image_store.dart';
import '../presentation/design/tegnal_theme.dart';
import '../presentation/navigation/app_header.dart';
import '../presentation/library/collections_view.dart';
import '../presentation/library/folders_view.dart';
import '../presentation/library/library_routes.dart';
import '../presentation/navigation/app_state.dart';
import '../presentation/navigation/root_tab_view.dart';
import '../presentation/navigation/tab_navigator.dart';
import '../presentation/settings/backup_reminder.dart';
import '../presentation/settings/cover_fill_warning.dart';
import '../presentation/settings/discord_invitation_banner.dart';
import '../presentation/settings/downloads_view.dart';
import '../presentation/settings/drive_sync_section.dart';
import '../presentation/settings/library_management_view.dart';
import '../presentation/settings/settings_page.dart' show settingsSectionGap;
import '../presentation/settings/settings_view.dart';
import '../presentation/study_mode/study_mode_root.dart';
import '../presentation/settings/site_account_section.dart';
import '../presentation/settings/start_choice_view.dart';
import '../presentation/settings/website_setup.dart';
import '../core/content/reading_queue.dart';
import '../presentation/design/app_sheet.dart';
import '../presentation/content/reading_queue_views.dart';
import 'privacy_cover.dart';
import '../core/content/recent_works.dart';
import '../core/support/app_platform.dart';
import '../presentation/design/desktop_input.dart';
import 'app_lock.dart';
import 'localization.dart';

/// Everything the root screens share, created once at launch.
class AppServices {
  AppServices({
    required this.preferences,
    required this.database,
    required this.booru,
    required this.content,
    required this.downloadsDirectory,
    this.downloadsFilesRoot,
    required this.syncDirectory,
    required this.booruSource,
    required this.booruThumbnails,
    required this.booruViewerImages,
    this.booruDownloads,
    this.version = '',
    this.isTesting = false,
    this.showsStartChoice = false,
  }) : images = PageImageStore(source: content.source) {
    // Fixture runs and tests never fill covers from the network, as in the native app.
    coverQueue = isTesting
        ? CoverQueue.disabled(database: database, source: content.source)
        : CoverQueue(
            database: database,
            source: content.source,
            thumbnailData: (page, id) => images.data(page, galleryID: id, thumbnail: true),
            isSiteVerified: () => content.isSiteVerified,
          );
    bookmarks = BookmarkSession(database: database, content: content, isTesting: isTesting, startCoverQueue: coverQueue.start);
    favorites = SiteFavoritesSync(database: database, content: content, startCoverQueue: coverQueue.start);
    if (!isTesting) SiteFavoritesSync.shared = favorites;
    booruAccounts = BooruAccountSync(store: booru, accounts: BooruAccounts(preferences.booruDefaults));
    if (!isTesting) BooruAccountSync.shared = booruAccounts;
    downloads = DownloadStore(directory: downloadsDirectory, filesRoot: downloadsFilesRoot, manga: content.source, booru: booruDownloads);
    sync = LibraryDriveSync(
      // Without Google's mobile sign-in the backend stays unconfigured and sync never starts.
      backend: GoogleDriveBackend(serverClientID: AppPlatform.hasDriveSync ? null : ''),
      database: database,
      booru: booru,
      defaults: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
      directory: syncDirectory,
      onApplied: () {
        content.reloadSyncedPreferences();
        recentWorks.reload();
        recentImages.reload();
        coverQueue.start();
      },
    );
    invitation = DiscordInvitation(preferences.defaults);
    taste = TasteController(library: database, images: booru, content: content, booruSource: booruSource, comicSource: content.source);
  }

  final AppPreferences preferences;
  final AppDatabase database;
  final BooruStore booru;
  final ContentEnvironment content;
  final PageImageStore images;
  final bool isTesting;

  /// Fixture runs: show the first-run "Choose How to Start" page at launch (`TEGNAL_FIXTURE=startChoice`).
  final bool showsStartChoice;

  /// Image mode's posts, previews and viewer media, and how its downloads fetch files.
  final BooruProviding booruSource;
  final BooruImageCache booruThumbnails;
  final BooruImageCache booruViewerImages;
  final BooruMediaDownloading? booruDownloads;

  /// The installed version name shown in Settings.
  final String version;
  final Directory downloadsDirectory;

  /// The device folder the Files app shows, where downloads go unless a folder is picked.
  final Directory? downloadsFilesRoot;

  /// Kept out of device backups, so a restored phone starts its own sync baseline.
  final Directory syncDirectory;
  late final CoverQueue coverQueue;

  /// Keeps each signed-in website's favorites and the folder named after it the same.
  late final SiteFavoritesSync favorites;

  /// Each image server's signed-in account and its favorites sync.
  late final BooruAccountSync booruAccounts;
  late final BookmarkSession bookmarks;
  late final DownloadStore downloads;
  late final LibraryDriveSync sync;
  late final DiscordInvitation invitation;

  /// Taste analysis, recommendations and recaps for both libraries.
  late final TasteController taste;

  /// Up Next for comics.
  late final ReadingQueue readingQueue = ReadingQueue(preferences.defaults);

  /// Comics opened in the viewer lately; the reader adds to it wherever it opens.
  late final RecentWorks recentWorks = RecentWorks.shared = RecentWorks(preferences.defaults);

  /// Images opened in image mode's viewer lately.
  late final RecentImages recentImages = RecentImages.shared = RecentImages(preferences.booruDefaults);
}

class TegnalApp extends StatefulWidget {
  const TegnalApp({super.key, required this.services, this.initialTab = AppTab.folders, this.initialMode = AppMode.manga});
  final AppServices services;
  final AppTab initialTab;
  final AppMode initialMode;

  @override
  State<TegnalApp> createState() => _TegnalAppState();
}

class _TegnalAppState extends State<TegnalApp> {
  late final AppState _state = AppState(mode: widget.initialMode, tab: widget.initialTab);

  /// `AppTheme`: each library keeps its own setting, dark unless changed.
  Brightness? _brightness() {
    final key = _state.mode == AppMode.manga ? 'app_theme' : 'booru.app_theme';
    return switch (widget.services.preferences.defaults.string(key) ?? 'dark') {
      'light' => Brightness.light,
      'system' => null,
      _ => Brightness.dark,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) {
        final brightness = _brightness() ?? MediaQuery.platformBrightnessOf(context);
        return CupertinoApp(
          title: 'TEGNAL',
          debugShowCheckedModeBanner: false,
          scrollBehavior: const TegnalScrollBehavior(),
          locale: Locale(L10n.language),
          supportedLocales: appLocales,
          localizationsDelegates: appLocalizationsDelegates,
          theme: tegnalTheme(brightness),
          builder: (context, child) => ReadingQueueScope(
            queue: widget.services.readingQueue,
            child: PrivacyCoverSync(
              preferences: widget.services.preferences.defaults,
              child: AppLockGate(child: child!),
            ),
          ),
          home: _Root(state: _state, services: widget.services),
        );
      },
    );
  }
}

class _Root extends StatefulWidget {
  const _Root({required this.state, required this.services});
  final AppState state;
  final AppServices services;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  AppServices get services => widget.services;
  AppState get state => widget.state;

  late final _contentRoutes = ContentRoutes(
    state: state,
    content: services.content,
    database: services.database,
    images: services.images,
    preferences: services.preferences.defaults,
    bookmarks: services.bookmarks,
    downloads: _downloads,
  );
  late final _library = LibraryRoutes(
    state: state,
    database: services.database,
    content: services.content,
    contentRoutes: _contentRoutes,
    startCoverQueue: services.coverQueue.start,
  );

  @override
  void initState() {
    super.initState();
    // Safe Mode keeps Saved and Explore to Safebooru; images saved from other servers stay hidden.
    services.booru.safeMode = () => _booru.safeMode;
    services.booru.applySafeMode();
    // The reader adds to Recently Opened Works from the first work it opens.
    services.recentWorks;
    services.recentImages;
    // Finished weeks and months become reports and recaps, as the native app does on launch.
    if (!services.isTesting) services.taste.prepareCompletedReports();
    services.coverQueue.askBeforeBulkFill = (pending, sites) {
      if (!mounted) {
        services.coverQueue.asksBeforeBulkFill = false;
        return;
      }
      showCoverFillSiteWarning(
        context,
        queue: services.coverQueue,
        pending: pending,
        sites: sites,
        addWebsite: () => showWebsiteConnectionEditor(context, content: services.content, state: state),
      );
    };
    if (!services.isTesting) services.coverQueue.start();
    _watchFirstRun();
    // Sync and the cover queue run only while the app is in front, as on iOS.
    _lifecycle = AppLifecycleListener(
      onStateChange: (value) {
        final active = value == AppLifecycleState.resumed;
        services.sync.setActive(active);
        services.downloads.setBackground(!active);
        if (!services.isTesting) services.coverQueue.setActive(active);
        if (!services.isTesting) unawaited(services.favorites.setActive(active));
        if (!services.isTesting) unawaited(services.booruAccounts.setActive(active));
      },
    );
    if (!services.isTesting) unawaited(services.favorites.setActive(true));
    if (!services.isTesting) unawaited(services.booruAccounts.setActive(true));
    if (!services.isTesting) services.sync.restore().then((_) => services.sync.setActive(true));
  }

  late final AppLifecycleListener _lifecycle;

  /// Whether the first-run website page is what the app shows: no comics website and no image server yet.
  bool get _isFirstRun => !services.content.isSiteVerified && services.booru.servers.isEmpty;

  /// Asks, once, how the app should open. Only a new user is asked, at the first launch: learning mode needs no
  /// website, so the question does not wait for one to be connected. Fixture runs ask only when `startChoice` names it.
  void _watchFirstRun() {
    final preferences = services.preferences.booruDefaults;
    if (services.isTesting) {
      if (services.showsStartChoice) WidgetsBinding.instance.addPostFrameCallback((_) => _askStartChoice());
      return;
    }
    if (StartChoiceView.isAnswered(preferences) || !_isFirstRun) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _askStartChoice());
  }

  void _askStartChoice() {
    if (!mounted || StartChoiceView.isAnswered(services.preferences.booruDefaults)) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => StartChoiceView(preferences: services.preferences.booruDefaults)),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _booruPages.dispose();
    super.dispose();
  }

  late final _booru = BooruContext(
    state: state,
    store: services.booru,
    source: services.booruSource,
    thumbnails: services.booruThumbnails,
    viewerImages: services.booruViewerImages,
    database: services.database,
    preferences: services.preferences.defaults,
    booruDefaults: services.preferences.booruDefaults,
    downloads: _downloads,
    fixture: services.isTesting,
  );

  late final _imports = ImportContext(
    booru: _booru,
    database: services.database,
    startCoverQueue: services.coverQueue.start,
    libraryChanged: _library.notifyChanged,
  );

  late final _taste = TasteContext(
    controller: services.taste,
    booru: _booru,
    comics: _contentRoutes,
    images: services.images,
    explore: () => state.tab = AppTab.works,
  );

  Widget _tasteSettingsRow(BuildContext context, TasteMode mode) => FormSection(
    prominentHeader: true,
    rowColor: FormColors.listRow.resolveFrom(context),
    children: [
      SettingsLinkRow(
        title: L10n.text('Taste Analysis'),
        icon: CupertinoIcons.sparkles,
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => TasteSettingsView(taste: _taste, mode: mode),
          ),
        ),
      ),
    ],
  );

  late final _booruPages = BooruRootPages(
    booru: _booru,
    content: services.content,
    library: _library,
    importLinks: () => WebsiteImportLinks(imports: _imports),
    settings: BooruSettingsDependencies(
      booru: _booru,
      content: services.content,
      version: services.version,
      tasteSettings: (context) => _tasteSettingsRow(context, TasteMode.booru),
      openLibraryManagement: (context) => Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => LibraryManagementView(
            library: _management,
            booru: true,
            extraSections: [
              Builder(
                builder: (context) => FormSection(
                  prominentHeader: true,
                  rowColor: FormColors.listRow.resolveFrom(context),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Challenge Backup and Import'),
                      symbol: (_) => DiceSymbol(color: SystemColors.purple.resolveFrom(context)),
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => ChallengeBackupView(booru: services.booru))),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Import from Anime Boxes'),
                      icon: CupertinoIcons.cube_box,
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: _booru))),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Import from Another Image App'),
                      icon: CupertinoIcons.square_arrow_down_on_square,
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: _booru, otherApps: true))),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      resetSettings: () {
        final wasSafe = _booru.safeMode;
        ModeSettingsReset.reset(booru: true, content: services.content, preferences: services.preferences);
        if (wasSafe) services.booru.leaveSafeMode();
        services.booru.safeModeChanged();
        state.appearanceChanged();
      },
      sync: AppPlatform.hasDriveSync ? (context) => DriveSyncSection(sync: services.sync) : null,
      invitation: (context) => DiscordInvitationBanner(invitation: services.invitation),
    ),
  );

  late final _downloads = DownloadsContext(
    store: services.downloads,
    content: services.content,
    database: services.database,
    preferences: services.preferences.defaults,
  );

  late final _management = LibraryManagementContext(
    database: services.database,
    images: services.booru,
    content: services.content,
    coverQueue: services.coverQueue,
    restored: () {
      services.coverQueue.start();
      services.sync.libraryRestored();
      services.sync.synchronize();
    },
  );

  SettingsDependencies get _settings => SettingsDependencies(
    state: state,
    content: services.content,
    database: services.database,
    preferences: services.preferences.defaults,
    library: _library,
    version: services.version,
    openDownloads: (context) => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => DownloadsView(downloads: _downloads))),
    openLibraryManagement: (context) => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => LibraryManagementView(
          library: _management,
          extraSections: [
            Builder(
              builder: (context) => FormSection(
                prominentHeader: true,
                rowColor: FormColors.listRow.resolveFrom(context),
                header: Text(L10n.text('Import Data (Other Manga Viewer)')),
                children: [
                  SettingsLinkRow(title: L10n.text('Import from Violet'), icon: CupertinoIcons.book, onTap: () => showImportData(context, _imports)),
                  SettingsLinkRow(
                    title: L10n.text('Import from Another Manga Viewer'),
                    icon: CupertinoIcons.square_arrow_down,
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => MangaViewerImportView(
                          database: services.database,
                          startCoverQueue: services.coverQueue.start,
                          libraryChanged: _library.notifyChanged,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Builder(
              builder: (context) => FormSection(
                prominentHeader: true,
                rowColor: FormColors.listRow.resolveFrom(context),
                header: Text(L10n.text('Other Comics Apps')),
                footer: Text(L10n.text('Database exports, app data exports, download folders, manga reader backups, link lists and browser bookmarks.')),
                children: [
                  SettingsLinkRow(
                    title: L10n.text('Import from Another Comics App'),
                    icon: CupertinoIcons.square_arrow_down_on_square,
                    onTap: () => Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) =>
                            OtherAppImportView(database: services.database, startCoverQueue: services.coverQueue.start, libraryChanged: _library.notifyChanged),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    tasteSettings: (context) => _tasteSettingsRow(context, TasteMode.comics),
    safeMode: (context) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeModeSection(booru: _booru),
        settingsSectionGap,
        StudyModeSettings(booru: _booru),
      ],
    ),
    recentWorks: services.recentWorks,
    openWork: (context, id) => _contentRoutes.openThumbnail(context, id),
    resetSettings: () => ModeSettingsReset.reset(booru: false, content: services.content, preferences: services.preferences),
    siteAccount: AppPlatform.hasWebView
        ? (context, site) => SiteAccountSection(site: site, content: services.content, database: services.database, startCoverQueue: services.coverQueue.start)
        : null,
    sync: AppPlatform.hasDriveSync ? (context) => DriveSyncSection(sync: services.sync) : null,
    invitation: (context) => DiscordInvitationBanner(invitation: services.invitation),
  );

  @override
  Widget build(BuildContext context) {
    // `RetainedModeContainer`: both libraries stay alive while the other one shows.
    return BackupReminderGate(
      database: services.database,
      images: services.booru,
      isTesting: services.isTesting,
      // Learning mode covers the whole screen, the libraries' tab bars included, while it is on.
      child: StudyModeOverlay(
        booru: _booru,
        child: CupertinoPageScaffold(
          resizeToAvoidBottomInset: false,
          child: ListenableBuilder(
            listenable: state,
            builder: (context, _) => ListenableBuilder(
              listenable: services.taste,
              builder: (context, _) => RootBanner(
                banner: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ImportReminderBanner(imports: _imports),
                    if (!_hidesComics) TasteRecapBanner(taste: _taste, mode: _taste.mode, open: () => _openRecap(_taste.mode)),
                  ],
                ),
                height:
                    (ImportReminderBanner.isVisible(_imports) ? ImportReminderBanner.height : 0) +
                    (_hidesComics || services.taste.pendingRecap(_taste.mode) == null ? 0 : _recapBannerHeight),
                child: IndexedStack(
                  index: state.mode == AppMode.manga ? 0 : 1,
                  children: [
                    _mangaTabs(),
                    RootTabView(
                      state: state,
                      pages: {
                        ..._booruPages.pages(),
                        AppTab.insights: TabNavigator(
                          active: state.mode == AppMode.booru && state.tab == AppTab.insights,
                          builder: (context) => TasteDashboard(taste: _taste, mode: TasteMode.booru, isRoot: true),
                        ),
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The arrival banner's height: 44 pt row, its padding and margins.
  static const double _recapBannerHeight = 6 + 12 + 44 + 12 + 6;

  /// Opens the new issue from the arrival banner, over the current tab.
  void _openRecap(TasteMode mode) {
    final date = services.taste.pendingRecap(mode);
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (context) => RecapHomeView(taste: _taste, mode: mode, opening: date, onBack: () => Navigator.of(context).pop()),
          ),
        )
        .then((_) => services.taste.dismissRecap(mode));
  }

  /// Opens a waiting work, whose number names the same work on every connected site; the reader
  /// pages on through the list.
  void _readQueued(BuildContext context, int id) {
    _contentRoutes.read(context, id, page: 1, queue: true);
  }

  void _showQueue(BuildContext context) => showAppSheet<void>(
    context,
    grabber: true,
    builder: (sheetContext, controller) => ReadingQueueView(
      queue: services.readingQueue,
      scrollController: controller,
      read: (id) {
        Navigator.of(sheetContext).pop();
        _readQueued(context, id);
      },
    ),
  );

  /// Safe Mode keeps Comics Mode to Safebooru's pools, so what comes from comics websites stays out of sight.
  bool get _hidesComics => state.mode == AppMode.manga && _booru.safeMode;

  Widget _mangaTabs() {
    final safe = _booru.safeMode;
    // Each tab's navigator starts afresh when Safe Mode swaps its root screen.
    Key key(AppTab tab) => ValueKey('manga.${tab.name}.$safe');
    return RootTabView(
      state: state,
      queue: safe ? null : services.readingQueue,
      readQueued: _readQueued,
      showQueue: _showQueue,
      pages: {
        AppTab.folders: TabNavigator(
          key: key(AppTab.folders),
          active: state.mode == AppMode.manga && state.tab == AppTab.folders,
          builder: (context) => safe ? SafeModeComicsPlaceholder(state: state, title: 'Saved') : FoldersView(state: state, routes: _library),
        ),
        AppTab.works: TabNavigator(
          key: key(AppTab.works),
          active: state.mode == AppMode.manga && state.tab == AppTab.works,
          builder: (context) {
            // Safe Mode browses Safebooru's pools, as before a comics website is connected.
            final server = _booru.store.selectedServers.firstOrNull;
            if (safe && server != null) return BooruPoolsView(booru: _booru, server: server, root: state);
            return _ExploreRoot(
              state: state,
              services: services,
              importLinks: WebsiteImportLinks(imports: _imports),
            );
          },
        ),
        AppTab.artists: TabNavigator(
          key: key(AppTab.artists),
          active: state.mode == AppMode.manga && state.tab == AppTab.artists,
          builder: (context) => safe
              ? SafeModeComicsPlaceholder(state: state, title: 'Tags')
              : CollectionsView(state: state, routes: _library, preferences: services.preferences.defaults),
        ),
        AppTab.settings: TabNavigator(
          active: state.mode == AppMode.manga && state.tab == AppTab.settings,
          builder: (context) => SettingsView(dependencies: _settings),
        ),
        AppTab.insights: TabNavigator(
          key: key(AppTab.insights),
          active: state.mode == AppMode.manga && state.tab == AppTab.insights,
          builder: (context) =>
              safe ? SafeModeComicsPlaceholder(state: state, title: 'Smart') : TasteDashboard(taste: _taste, mode: TasteMode.comics, isRoot: true),
        ),
      },
    );
  }
}

/// Explore, or the website setup until a comics website is connected.
class _ExploreRoot extends StatelessWidget {
  const _ExploreRoot({required this.state, required this.services, this.importLinks});
  final AppState state;
  final AppServices services;
  final Widget? importLinks;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.content,
    builder: (context, _) {
      final content = services.content;
      final routes = ContentRoutes(
        state: state,
        content: content,
        database: services.database,
        images: services.images,
        preferences: services.preferences.defaults,
        bookmarks: services.bookmarks,
        downloads: DownloadsContext(store: services.downloads, content: content, database: services.database, preferences: services.preferences.defaults),
      );
      if (!content.isSiteVerified) {
        final top = rootContentTop(context);
        return Stack(
          children: [
            Positioned.fill(
              child: WebsiteSetupView(content: content, state: state, importLinks: importLinks, topInset: top, bottomInset: tabBarClearance(context)),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: RootHeader(title: L10n.text('Explore'), state: state),
            ),
          ],
        );
      }
      // `ContentEntryView(embedded: true)`: the website itself when the embedded browser is on.
      if (content.useEmbeddedBrowser) {
        return InAppMangaBrowserView(key: ValueKey('browser:${content.mangaSiteAddress}'), embedded: true, state: state);
      }
      return ExploreView(
        // A combined list stays when opening a work checks another website.
        key: ValueKey(content.listsSeveralComicSites ? '*' : content.mangaSiteAddress),
        state: state,
        source: content.source,
        images: services.images,
        database: services.database,
        content: content,
        isActive: state.tab == AppTab.works && state.mode == AppMode.manga,
        openGallery: (id) => routes.openThumbnail(context, id),
        details: (id) => routes.openGallery(context, id),
        bookmark: (id, gallery, {site, images}) => routes.toggleBookmark(context, id, gallery, aboveTabBar: true, site: site, images: images),
      );
    },
  );
}
