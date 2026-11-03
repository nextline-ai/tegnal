import 'package:cupertino_ui/cupertino_ui.dart';

import '../core/booru/booru_store.dart';
import '../core/content/content_environment.dart';
import '../core/content/cover_queue.dart';
import '../core/storage/app_database.dart';
import '../core/support/l10n.dart';
import '../core/support/preferences.dart';
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
import '../presentation/settings/website_setup.dart';

/// Everything the root screens share, created once at launch.
class AppServices {
  AppServices({required this.preferences, required this.database, required this.booru, required this.content, this.isTesting = false})
    : images = PageImageStore(source: content.source) {
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
  }

  final AppPreferences preferences;
  final AppDatabase database;
  final BooruStore booru;
  final ContentEnvironment content;
  final PageImageStore images;
  final bool isTesting;
  late final CoverQueue coverQueue;
  late final BookmarkSession bookmarks;
}

class TegnalApp extends StatefulWidget {
  const TegnalApp({super.key, required this.services, this.initialTab = AppTab.folders});
  final AppServices services;
  final AppTab initialTab;

  @override
  State<TegnalApp> createState() => _TegnalAppState();
}

class _TegnalAppState extends State<TegnalApp> {
  late final AppState _state = AppState(tab: widget.initialTab);

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
          locale: Locale(L10n.language),
          theme: tegnalTheme(brightness),
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
    if (!services.isTesting) services.coverQueue.start();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: false,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => RootTabView(
          state: state,
          pages: {
            AppTab.folders: TabNavigator(
              active: state.tab == AppTab.folders,
              builder: (context) => FoldersView(state: state, routes: _library),
            ),
            AppTab.works: TabNavigator(
              active: state.tab == AppTab.works,
              builder: (context) => _ExploreRoot(state: state, services: services),
            ),
            AppTab.artists: TabNavigator(
              active: state.tab == AppTab.artists,
              builder: (context) => CollectionsView(state: state, routes: _library, preferences: services.preferences.defaults),
            ),
            AppTab.settings: _PendingRoot(title: L10n.text('Settings'), state: state),
            AppTab.insights: _PendingRoot(title: L10n.text('Smart'), state: state),
          },
        ),
      ),
    );
  }
}

/// Explore, or the website setup until a comics website is connected.
class _ExploreRoot extends StatelessWidget {
  const _ExploreRoot({required this.state, required this.services});
  final AppState state;
  final AppServices services;

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
      );
      if (!content.isSiteVerified) {
        final top = MediaQuery.paddingOf(context).top + rootBarHeight;
        return Stack(
          children: [
            Positioned.fill(
              child: WebsiteSetupView(content: content, state: state, topInset: top, bottomInset: tabBarClearance(context)),
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
      return ExploreView(
        key: ValueKey(content.mangaSiteAddress),
        state: state,
        source: content.source,
        images: services.images,
        database: services.database,
        content: content,
        isActive: state.tab == AppTab.works && state.mode == AppMode.manga,
        openGallery: (id) => routes.openThumbnail(context, id),
        bookmark: (id, gallery) => routes.toggleBookmark(context, id, gallery, aboveTabBar: true),
      );
    },
  );
}

/// Root screens of later rebuild steps: the shared header over an empty page.
class _PendingRoot extends StatelessWidget {
  const _PendingRoot({required this.title, required this.state});
  final String title;
  final AppState state;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: TegnalColors.background.resolveFrom(context),
    child: Align(
      alignment: Alignment.topCenter,
      child: RootHeader(title: title, state: state),
    ),
  );
}
