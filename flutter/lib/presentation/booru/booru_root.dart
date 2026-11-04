import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/content_environment.dart';
import '../../core/support/l10n.dart';
import '../design/tegnal_theme.dart';
import '../library/collections_view.dart';
import '../library/library_routes.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../navigation/tab_navigator.dart';
import '../settings/website_setup.dart';
import 'booru_common.dart';
import 'booru_favorites_view.dart';
import 'booru_feed_view.dart';
import 'booru_settings_views.dart';

/// `BooruRootView`: image mode's four tabs. Until a server is connected, Saved, Explore
/// and Tags show the website setup.
class BooruRootPages {
  BooruRootPages({required this.booru, required this.content, required this.library, required this.settings, this.importLinks}) {
    _serverCount = booru.store.servers.length;
    booru.store.addListener(_serversChanged);
  }

  final BooruContext booru;
  final ContentEnvironment content;
  final LibraryRoutes library;
  final BooruSettingsDependencies settings;

  /// `WebsiteImportLinks` on the setup screen.
  final Widget Function()? importLinks;
  int _serverCount = 0;

  AppState get _state => booru.state;

  /// A first server opens Explore, as the native root does.
  void _serversChanged() {
    final count = booru.store.servers.length;
    if (_state.mode == AppMode.booru && _serverCount == 0 && count > 0 && (_state.tab == AppTab.folders || _state.tab == AppTab.works)) {
      _state.tab = AppTab.works;
    }
    _serverCount = count;
  }

  void dispose() => booru.store.removeListener(_serversChanged);

  bool _active(AppTab tab) => _state.mode == AppMode.booru && _state.tab == tab;

  Map<AppTab, Widget> pages() => {
    AppTab.folders: TabNavigator(
      active: _active(AppTab.folders),
      builder: (context) => _SetupGate(
        booru: booru,
        importLinks: importLinks,
        content: content,
        title: L10n.text('Saved'),
        child: BooruFavoritesView(booru: booru),
      ),
    ),
    AppTab.works: TabNavigator(
      active: _active(AppTab.works),
      builder: (context) => _SetupGate(
        booru: booru,
        importLinks: importLinks,
        content: content,
        title: L10n.text('Explore'),
        child: ListenableBuilder(
          listenable: _state,
          builder: (context, _) => BooruExploreRoot(booru: booru, isActive: _active(AppTab.works)),
        ),
      ),
    ),
    AppTab.artists: TabNavigator(
      active: _active(AppTab.artists),
      builder: (context) => _SetupGate(
        booru: booru,
        importLinks: importLinks,
        content: content,
        title: L10n.text('Tags'),
        child: BooruSavedServersView(
          booru: booru,
          tags: (context, server, {onBack}) => CollectionsView(
            key: ValueKey('tags:${server.id}'),
            state: _state,
            routes: library,
            preferences: booru.booruDefaults,
            booru: booru.store,
            server: server,
            onBack: onBack,
            openQuery: (context, query) => BooruFeedView.push(context, booru: booru, server: server, query: query),
            headerActions: [if (onBack == null) BooruServerMenuButton(store: booru.store)],
          ),
        ),
      ),
    ),
    AppTab.settings: TabNavigator(
      active: _active(AppTab.settings),
      builder: (context) => BooruMoreView(dependencies: settings),
    ),
  };
}

/// The setup screen under the root header while no server is connected.
class _SetupGate extends StatelessWidget {
  const _SetupGate({required this.booru, required this.content, required this.title, required this.child, this.importLinks});
  final Widget Function()? importLinks;
  final BooruContext booru;
  final ContentEnvironment content;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: booru.store,
    builder: (context, _) {
      if (booru.store.servers.isNotEmpty) return child;
      final top = rootContentTop(context);
      return ColoredBox(
        color: TegnalColors.background.resolveFrom(context),
        child: Stack(
          children: [
            Positioned.fill(
              child: WebsiteSetupView(
                content: content,
                state: booru.state,
                booru: booru.store,
                importLinks: importLinks?.call(),
                topInset: top,
                bottomInset: tabBarClearance(context),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: RootHeader(title: title, state: booru.state),
            ),
          ],
        ),
      );
    },
  );
}
