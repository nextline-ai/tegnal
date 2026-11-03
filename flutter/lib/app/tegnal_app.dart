import 'package:cupertino_ui/cupertino_ui.dart';

import '../core/booru/booru_store.dart';
import '../core/content/content_environment.dart';
import '../core/storage/app_database.dart';
import '../core/support/l10n.dart';
import '../core/support/preferences.dart';
import '../presentation/content/explore_view.dart';
import '../presentation/content/page_image_store.dart';
import '../presentation/design/tegnal_theme.dart';
import '../presentation/navigation/app_header.dart';
import '../presentation/navigation/app_state.dart';
import '../presentation/navigation/root_tab_view.dart';
import '../presentation/settings/website_setup.dart';

/// Everything the root screens share, created once at launch.
class AppServices {
  AppServices({required this.preferences, required this.database, required this.booru, required this.content})
    : images = PageImageStore(source: content.source);

  final AppPreferences preferences;
  final AppDatabase database;
  final BooruStore booru;
  final ContentEnvironment content;
  final PageImageStore images;
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

class _Root extends StatelessWidget {
  const _Root({required this.state, required this.services});
  final AppState state;
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      resizeToAvoidBottomInset: false,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => RootTabView(
          state: state,
          pages: {
            AppTab.folders: _PendingRoot(title: L10n.text('Saved'), state: state),
            AppTab.works: _ExploreRoot(state: state, services: services),
            AppTab.artists: _PendingRoot(title: L10n.text('Tags'), state: state),
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
        openGallery: (_) {},
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
