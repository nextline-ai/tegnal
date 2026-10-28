import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'core/app_controller.dart';
import 'core/content.dart';
import 'core/drive_sync_controller.dart';
import 'ui/design_system.dart';
import 'data/download_manager.dart';
import 'features/artists_screen.dart';
import 'features/browser_screen.dart';
import 'features/detail_screen.dart';
import 'features/explore_screen.dart';
import 'features/insights_screen.dart';
import 'features/library_screen.dart';
import 'features/settings_screen.dart';
import 'features/onboarding_screen.dart';
import 'features/reader_screen.dart';
import 'ui/l10n.dart';
import 'ui/navigation.dart';
import 'ui/privacy_cover.dart';
import 'ui/metadata_fill.dart';

class TegnalApp extends StatefulWidget {
  const TegnalApp({
    super.key,
    required this.controller,
    required this.downloads,
    this.driveSync,
  });
  final AppController controller;
  final DownloadManager downloads;
  final DriveSyncController? driveSync;
  @override
  State<TegnalApp> createState() => _TegnalAppState();
}

class _TegnalAppState extends State<TegnalApp> {
  late final ThemeData _lightTheme = tegnalTheme(Brightness.light);
  late final ThemeData _darkTheme = tegnalTheme(Brightness.dark);
  late (String, String, bool) _presentation;
  AppController get controller => widget.controller;
  (String, String, bool) get _currentPresentation => (
    controller.language,
    controller.appearance,
    controller.onboardingComplete,
  );

  @override
  void initState() {
    super.initState();
    _presentation = _currentPresentation;
    controller.addListener(_configurationChanged);
  }

  @override
  void didUpdateWidget(covariant TegnalApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_configurationChanged);
      controller.addListener(_configurationChanged);
      _presentation = _currentPresentation;
    }
  }

  void _configurationChanged() {
    final next = _currentPresentation;
    if (next != _presentation) setState(() => _presentation = next);
  }

  @override
  void dispose() {
    controller.removeListener(_configurationChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TEGNAL',
    debugShowCheckedModeBanner: false,
    locale: _presentation.$1 == 'system' ? null : Locale(_presentation.$1),
    supportedLocales: const [Locale('en'), Locale('ko'), Locale('ja')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: TegnalPrivacyCover(child: child!),
      );
    },
    theme: _lightTheme,
    darkTheme: _darkTheme,
    themeMode: switch (_presentation.$2) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    },
    // Content updates rebuild the shell, not MaterialApp and its themes.
    home: MetadataFillScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => controller.onboardingComplete
            ? AppShell(
                controller: controller,
                downloads: widget.downloads,
                driveSync: widget.driveSync,
              )
            : OnboardingScreen(controller: controller),
      ),
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    required this.downloads,
    this.driveSync,
  });
  final AppController controller;
  final DownloadManager downloads;
  final DriveSyncController? driveSync;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedTab = 0;
  final _storage = PageStorageBucket();
  final _visitedTabs = <(AppMode, int)>{};
  final _tabPages = <(AppMode, int), Widget>{};
  final _navigators = {
    for (final mode in AppMode.values)
      mode: List.generate(5, (_) => GlobalKey<NavigatorState>()),
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    widget.driveSync?.setForeground(
      lifecycle != AppLifecycleState.paused &&
          lifecycle != AppLifecycleState.detached,
    );
    widget.downloads.setForeground(
      lifecycle != AppLifecycleState.paused &&
          lifecycle != AppLifecycleState.detached,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      widget.downloads.setForeground(false);
      widget.driveSync?.setForeground(false);
    }
    if (state == AppLifecycleState.resumed) {
      widget.downloads.setForeground(true);
      widget.driveSync?.setForeground(true);
    }
  }

  void _select(int index) {
    setState(() => _selectedTab = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _navigators[widget.controller.mode]![index].currentState?.focusNode
            .requestFocus();
      }
    });
  }

  void _search(String query) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _navigators[widget.controller.mode]![1].currentState?.popUntil(
      (route) => route.isFirst,
    );
    _select(1);
    widget.controller.search(query: query);
  }

  void _details(ContentItem item) => showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    clipBehavior: Clip.antiAlias,
    builder: (_) => FractionallySizedBox(
      heightFactor: .94,
      child: DetailScreen(
        controller: widget.controller,
        item: item,
        downloads: widget.downloads,
        onSearch: (query) {
          widget.controller.setMode(item.mode);
          _search(query);
        },
      ),
    ),
  );

  void _open(ContentItem item) => _openSequence(item, [item]);

  void _openSequence(ContentItem item, List<ContentItem> sequence) {
    if (item.pageUrl != null &&
        widget.controller.modePreference('useEmbeddedBrowser', item.mode)) {
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => BrowserScreen(url: item.pageUrl!),
        ),
      );
      return;
    }
    if (item.mode == AppMode.manga &&
        widget.controller.modePreference(
          'showInformationBeforeReading',
          item.mode,
        )) {
      _details(item);
      return;
    }
    Navigator.of(context, rootNavigator: true).push(
      readerRoute(
        builder: (_) => ReaderScreen(
          controller: widget.controller,
          downloads: widget.downloads,
          item: item,
          sequence: sequence,
          onSearch: (query) {
            widget.controller.setMode(item.mode);
            _search(query);
          },
        ),
      ),
    );
  }

  void _startExploreIfNeeded(AppMode mode) {
    if (!mounted || _selectedTab != 1 || widget.controller.mode != mode) return;
    final c = widget.controller;
    final state = c.explore(mode);
    if (!state.loading &&
        state.page == 0 &&
        state.error == null &&
        c.selectedSources(mode).isNotEmpty) {
      c.search(forMode: mode);
    }
  }

  Widget _withReminder(Widget child) {
    final c = widget.controller;
    return Column(
      children: [
        MetadataFillNotice(
          controller: c,
          onConnect: () => showAddSource(context, c, mode: AppMode.manga),
        ),
        if (c.store.setting('onboarding.importReminderDismissed', false) !=
            true)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              child: Row(
                children: [
                  Expanded(
                    child: ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: Text(
                        L10n.tr(context, 'Import Android Bookmark Backup'),
                      ),
                      subtitle: Text(
                        L10n.tr(context, 'Android bookmark SQLite backup'),
                      ),
                      onTap: () {
                        c.setPreference(
                          'onboarding.importReminderDismissed',
                          true,
                        );
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                            builder: (_) => OnboardingScreen(
                              controller: c,
                              importsOnly: true,
                              mode: c.mode,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: L10n.tr(context, 'Close'),
                    icon: const Icon(Icons.close),
                    onPressed: () => c.setPreference(
                      'onboarding.importReminderDismissed',
                      true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: child),
      ],
    );
  }

  List<Widget Function()> _pages(AppMode mode) {
    final c = widget.controller;
    return [
      () => LibraryScreen(
        key: PageStorageKey('library-${mode.name}'),
        controller: c,
        mode: mode,
        onOpen: _open,
        onOpenSequence: _openSequence,
        onDetails: _details,
      ),
      () => ExploreScreen(
        key: PageStorageKey('explore-${mode.name}'),
        controller: c,
        mode: mode,
        onOpen: _open,
        onOpenSequence: _openSequence,
        onConnect: () => showAddSource(context, c, mode: mode),
      ),
      () => ArtistsScreen(
        key: PageStorageKey('artists-${mode.name}'),
        controller: c,
        mode: mode,
        onOpen: _open,
        onOpenSequence: _openSequence,
        onSearch: _search,
      ),
      () => SettingsScreen(
        key: PageStorageKey('settings-${mode.name}'),
        controller: c,
        mode: mode,
        downloads: widget.downloads,
        driveSync: widget.driveSync,
        onOpen: _open,
        onOpenSequence: _openSequence,
      ),
      () => InsightsScreen(
        key: PageStorageKey('insights-${mode.name}'),
        controller: c,
        mode: mode,
        onSearch: _search,
        onOpen: _open,
      ),
    ];
  }

  Widget _tabNavigator(AppMode mode, int index) => _tabPages.putIfAbsent(
    (mode, index),
    () => Navigator(
      key: _navigators[mode]![index],
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: widget.controller,
          builder: (_, _) =>
              PageStorage(bucket: _storage, child: _pages(mode)[index]()),
        ),
      ),
    ),
  );

  Widget _modeNavigation(AppMode mode) {
    final currentMode = widget.controller.mode;
    final rootVisible = ModalRoute.isCurrentOf(context) ?? true;
    return IndexedStack(
      index: _selectedTab,
      children: [
        for (var index = 0; index < 5; index++)
          if (!_visitedTabs.contains((mode, index)))
            const SizedBox.shrink()
          else
            NavigatorPopHandler<Object?>(
              key: ValueKey('tab-${mode.name}-$index'),
              enabled: currentMode == mode && _selectedTab == index,
              onPopWithResult: (result) {
                if (widget.controller.mode != mode || _selectedTab != index) {
                  return;
                }
                final navigator = _navigators[mode]![index].currentState;
                if (navigator != null && navigator.canPop()) {
                  navigator.pop(result);
                }
              },
              child: _RetainedTabViewport(
                active:
                    currentMode == mode && _selectedTab == index && rootVisible,
                child: _tabNavigator(mode, index),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final mode = c.mode;
    _visitedTabs.add((mode, _selectedTab));
    final labels = [
      'Saved',
      'Explore',
      c.mode == AppMode.booru ? 'Tags' : 'Artists',
      c.mode == AppMode.booru ? 'More' : 'Settings',
      'Smart',
    ];
    final selected = _selectedTab;
    if (selected == 1) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startExploreIfNeeded(mode),
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final navigationBottom = (MediaQuery.paddingOf(context).bottom - 12).clamp(
      12.0,
      double.infinity,
    );
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < 5; i++)
          SingleActivator(
            [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
              LogicalKeyboardKey.digit5,
            ][i],
            control: true,
          ): () =>
              _select(i),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          // Root sheets/dialogs and each active tab own their keyboard insets.
          // Resizing this outer viewport too shrinks every retained navigator
          // and exposes the scaffold behind modal routes during IME animation.
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            bottom: false,
            child: _withReminder(
              Row(
                children: [
                  if (wide)
                    TegnalSidebar(
                      labels: labels,
                      mode: c.mode,
                      selected: selected,
                      onSelect: _select,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: MediaQuery(
                            // Remove automatic content padding, but retain the
                            // physical safe inset for scroll tails under the dock.
                            data: MediaQuery.of(context)
                                .removePadding(
                                  removeTop: true,
                                  removeBottom: !wide,
                                )
                                .copyWith(
                                  viewPadding: MediaQuery.viewPaddingOf(
                                    context,
                                  ),
                                ),
                            child: PageStorage(
                              bucket: _storage,
                              child: IndexedStack(
                                index: mode.index,
                                children: [
                                  for (final retainedMode in AppMode.values)
                                    _modeNavigation(retainedMode),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (!wide &&
                            MediaQuery.viewInsetsOf(context).bottom == 0)
                          Positioned(
                            left: 20,
                            right: 20,
                            bottom: navigationBottom,
                            child: TegnalTabBar(
                              labels: labels,
                              mode: c.mode,
                              selected: selected,
                              onSelect: _select,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Retains navigation/scroll state without relaying each IME frame to hidden
/// tabs or the page behind a root dialog. Window size/theme changes still flow.
class _RetainedTabViewport extends StatefulWidget {
  const _RetainedTabViewport({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_RetainedTabViewport> createState() => _RetainedTabViewportState();
}

class _RetainedTabViewportState extends State<_RetainedTabViewport> {
  EdgeInsets _lastInsets = EdgeInsets.zero;
  EdgeInsets? _lastPadding;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (widget.active) {
      _lastInsets = media.viewInsets;
      _lastPadding = media.padding;
    }
    return MediaQuery(
      data: media.copyWith(
        viewInsets: widget.active ? media.viewInsets : _lastInsets,
        padding: widget.active ? media.padding : _lastPadding ?? media.padding,
      ),
      child: TickerMode(
        enabled: widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: ExcludeSemantics(
            excluding: !widget.active,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
