import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_store.dart';
import '../../core/content/content_environment.dart';
import '../../core/support/l10n.dart';
import '../../core/sync/library_drive_sync.dart';
import '../booru/booru_settings_views.dart' show showBooruValidation;
import '../content/gallery_detail_view.dart' show GlassIconButton;
import '../design/alert_dialog.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../imports/import_views.dart';
import '../navigation/app_header.dart' show AppModeSwitch;
import '../navigation/app_state.dart';
import '../settings/drive_suggestion.dart';
import '../settings/settings_view.dart' show PrivacyPolicyPage;
import '../settings/website_setup.dart';

/// `OnboardingView`: the first run's three steps, as on iOS: connect a website, import data from
/// another viewer, and the switch between comics and images. Reopened from Settings, it ends with Done.
class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key, required this.content, required this.imports, required this.state, this.drive});
  final ContentEnvironment content;
  final ImportContext imports;
  final AppState state;

  /// Android's Google Drive sync. iOS syncs through iCloud with no sign-in, so it has no such page;
  /// here a page after the website lets a person sign in before their library grows.
  final LibraryDriveSync? drive;

  /// Shows onboarding over the whole app. Pages it opens (an import, the privacy policy) go on inside it.
  static Future<void> show(
    BuildContext context, {
    required ContentEnvironment content,
    required ImportContext imports,
    required AppState state,
    LibraryDriveSync? drive,
  }) => Navigator.of(context, rootNavigator: true).push(
    CupertinoPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _OnboardingNavigator(
        child: OnboardingView(content: content, imports: imports, state: state, drive: drive),
      ),
    ),
  );

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

/// Onboarding's own pages: the system back gesture goes back a page inside it before it closes.
class _OnboardingNavigator extends StatefulWidget {
  const _OnboardingNavigator({required this.child});
  final Widget child;

  @override
  State<_OnboardingNavigator> createState() => _OnboardingNavigatorState();
}

class _OnboardingNavigatorState extends State<_OnboardingNavigator> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) => CupertinoPageRoute<void>(builder: (_) => widget.child),
    ),
  );
}

enum _OnboardingPage { website, drive, imports, tutorial }

class _OnboardingViewState extends State<OnboardingView> {
  int _step = 0;
  bool _connecting = false;

  /// The Drive page shows only where Drive sync is set up in this build.
  late final List<_OnboardingPage> _pages = [
    _OnboardingPage.website,
    if (widget.drive?.isConfigured ?? false) _OnboardingPage.drive,
    _OnboardingPage.imports,
    _OnboardingPage.tutorial,
  ];
  int get _last => _pages.length - 1;
  _OnboardingPage get _page => _pages[_step];

  /// The tutorial's switch only shows the two modes; it does not change the app's mode.
  final _preview = AppState(mode: AppMode.booru);

  /// Whether onboarding was finished before, so it was reopened from Settings.
  late final bool _reopened = widget.content.isOnboardingCompleted;

  BooruStore get _store => widget.imports.booru.store;
  bool get _hasConnection => widget.content.isSiteVerified || _store.servers.isNotEmpty;

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context, rootNavigator: true).pop();

  void _next() {
    if (_step < _last) {
      setState(() => _step += 1);
      // Seeing the page is the suggestion; the one-time prompt for earlier installs never follows it.
      if (_page == _OnboardingPage.drive) widget.drive?.markSuggested();
      return;
    }
    widget.content.isOnboardingCompleted = true;
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondaryFill = TegnalColors.secondaryLabel.resolveFrom(context);
    return PopScope(
      // Swiping back steps back through the pages; on the first page it leaves only when onboarding was reopened.
      canPop: _step == 0 && _reopened,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) setState(() => _step -= 1);
      },
      child: CupertinoPageScaffold(
        backgroundColor: FormColors.background.resolveFrom(context),
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.content, _store, ?widget.drive]),
          builder: (context, _) {
            final later = switch (_page) {
              _OnboardingPage.website => !_hasConnection,
              _OnboardingPage.drive => widget.drive?.account == null,
              _ => false,
            };
            final title = _step == _last ? 'Get Started' : (later ? 'Set Up Later' : 'Continue');
            return Stack(
              children: [
                Positioned.fill(
                  child: SingleChildScrollView(
                    key: ValueKey('onboarding.step.$_step'),
                    padding: EdgeInsets.fromLTRB(24, media.padding.top + 60, 24, 24 + 94 + (_step == 0 ? 34 : 0) + media.padding.bottom),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Row(
                                spacing: 6,
                                children: [
                                  for (var index = 0; index <= _last; index++)
                                    Expanded(
                                      child: Container(
                                        height: 4,
                                        decoration: ShapeDecoration(
                                          color: index <= _step ? tint : secondaryFill.withValues(alpha: 0.18),
                                          shape: const StadiumBorder(),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            switch (_page) {
                              _OnboardingPage.website => _setup(context),
                              _OnboardingPage.drive => _drive(context),
                              _OnboardingPage.imports => _imports(context),
                              _OnboardingPage.tutorial => _tutorial(context),
                            },
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: media.padding.top,
                  child: SheetNavigationBar(
                    title: '',
                    leading: _step > 0
                        ? GlassIconButton(
                            key: const Key('onboarding.back'),
                            icon: CupertinoIcons.chevron_left,
                            label: L10n.text('Back'),
                            onPressed: () => setState(() => _step -= 1),
                          )
                        : null,
                    trailing: _reopened ? GlassTextButton(label: L10n.text('Done'), onPressed: _close) : null,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(24, 12, 24, 12 + media.padding.bottom),
                    // `.bar` under the button.
                    color: FormColors.row.resolveFrom(context).withValues(alpha: 0.94),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          button: true,
                          label: L10n.text(title),
                          excludeSemantics: true,
                          child: GestureDetector(
                            key: const Key('onboarding.continue'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _next,
                            child: Container(
                              // A large prominent button with 10 pt of extra vertical padding.
                              height: 69,
                              alignment: Alignment.center,
                              decoration: ShapeDecoration(color: later ? secondaryFill : tint, shape: const StadiumBorder()),
                              child: Text(
                                L10n.text(title),
                                style: TegnalType.style(17, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
                              ),
                            ),
                          ),
                        ),
                        if (_step == 0) ...[
                          const SizedBox(height: 10),
                          GestureDetector(
                            key: const Key('onboarding.privacy'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => const PrivacyPolicyPage())),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(L10n.text('Privacy Policy'), style: TegnalType.style(13, color: tint)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String text, {double size = 34}) => Text(
    L10n.text(text),
    style: TegnalType.style(size, weight: FontWeight.w700, color: TegnalColors.label.resolveFrom(context)),
  );

  Widget _card(BuildContext context, {required Widget child, double padding = 20, double radius = 20}) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: ShapeDecoration(
      color: FormColors.row.resolveFrom(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
    ),
    child: child,
  );

  Widget _setup(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    Widget connected(String name, {Widget? trailing, Key? key}) => Row(
      key: key,
      children: [
        Icon(CupertinoIcons.checkmark_circle_fill, size: 17, color: tint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, style: TegnalType.style(15, color: label)),
        ),
        ?trailing,
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, 'Connect a Website'),
        const SizedBox(height: 20),
        Text(L10n.text('Enter a comics or image website. We’ll detect its type and switch to the right mode.'), style: TegnalType.style(17, color: secondary)),
        const SizedBox(height: 20),
        const WebsiteModeGuide(),
        const SizedBox(height: 20),
        _card(
          context,
          padding: 18,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Semantics(
                button: true,
                label: L10n.text('Enter Website Address'),
                excludeSemantics: true,
                child: GestureDetector(
                  key: const Key('onboarding.addServer'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => showWebsiteConnectionEditor(context, content: widget.content, state: widget.state, booru: _store),
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(color: tint, shape: const StadiumBorder()),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.plus_circle, size: 19, color: Color(0xFFFFFFFF)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            L10n.text('Enter Website Address'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TegnalType.style(17, color: const Color(0xFFFFFFFF)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.content.isSiteVerified) connected(L10n.text('Comics Mode'), key: const Key('onboarding.comicsConnected')),
              for (final server in _store.servers)
                connected(
                  server.displayName,
                  trailing: Semantics(
                    button: true,
                    label: '${L10n.text('Validate Client')} ${server.displayName}',
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showBooruValidation(context, booru: widget.imports.booru, server: server),
                      child: SizedBox.square(dimension: 36, child: Icon(CupertinoIcons.checkmark_shield, size: 20, color: tint)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _connectDrive() async {
    final drive = widget.drive;
    if (drive == null || _connecting) return;
    setState(() => _connecting = true);
    final error = await drive.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (error == null) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Google Drive')),
        content: Text(error),
        actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
      ),
    );
  }

  Widget _drive(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final account = widget.drive?.account;
    return Column(
      key: const Key('onboarding.drive'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(CupertinoIcons.cloud, size: 42, color: tint),
        const SizedBox(height: 20),
        _title(context, 'Google Drive', size: 28),
        const SizedBox(height: 20),
        Text(DriveSuggestionGate.message, style: TegnalType.style(17, color: secondary)),
        const SizedBox(height: 20),
        _card(
          context,
          padding: 18,
          child: account != null
              ? Row(
                  key: const Key('onboarding.driveConnected'),
                  children: [
                    Icon(CupertinoIcons.checkmark_circle_fill, size: 17, color: tint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(account.email, style: TegnalType.style(15, color: label)),
                    ),
                  ],
                )
              : Semantics(
                  button: true,
                  label: L10n.text('Connect Google Account'),
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const Key('onboarding.connectDrive'),
                    behavior: HitTestBehavior.opaque,
                    onTap: _connectDrive,
                    child: Container(
                      height: 46,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(color: tint, shape: const StadiumBorder()),
                      child: _connecting
                          ? const CupertinoActivityIndicator(color: Color(0xFFFFFFFF))
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(CupertinoIcons.person_crop_circle_badge_plus, size: 19, color: Color(0xFFFFFFFF)),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    L10n.text('Connect Google Account'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TegnalType.style(17, color: const Color(0xFFFFFFFF)),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
        ),
        if (account == null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(CupertinoIcons.gear, size: 15, color: secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(L10n.text('You can also connect it later in Settings.'), style: TegnalType.style(13, color: secondary)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _imports(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    Widget kind({required Key key, required IconData icon, required String title, required String kinds, required WidgetBuilder page}) => _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: label),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  L10n.text(title),
                  style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(kinds, style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
          const SizedBox(height: 12),
          Semantics(
            button: true,
            label: L10n.text('Import'),
            excludeSemantics: true,
            child: GestureDetector(
              key: key,
              onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: page)),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // `.bordered`: the tertiary system fill under tinted text.
                decoration: ShapeDecoration(color: ImportDataView.borderedFill.resolveFrom(context), shape: const StadiumBorder()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DocumentBadgePlus(color: tint),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        L10n.text('Import'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(17, color: tint),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final imports = widget.imports;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(CupertinoIcons.square_arrow_down, size: 42, color: tint),
        const SizedBox(height: 20),
        _title(context, 'Import Data', size: 28),
        const SizedBox(height: 20),
        kind(
          key: const Key('onboarding.import'),
          icon: Symbols.photoFill,
          title: 'Other Image Viewer',
          kinds: '.abbj · .json · .db',
          page: (_) => AnimeBoxesImportView(booru: imports.booru, inSheet: true),
        ),
        const SizedBox(height: 12),
        kind(
          key: const Key('onboarding.mangaViewerImport'),
          icon: Symbols.bookFill,
          title: 'Other Comics Viewer',
          kinds: '.db · .json · .tachibk · .html · .txt',
          page: (_) =>
              OtherAppImportView(database: imports.database, startCoverQueue: imports.startCoverQueue, libraryChanged: imports.libraryChanged, inSheet: true),
        ),
      ],
    );
  }

  Widget _tutorial(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Column(
      key: const Key('onboarding.tutorial'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, 'Switch Modes'),
        const SizedBox(height: 24),
        Text(L10n.text('Use the top switch for comics and images.'), style: TegnalType.style(17, color: secondary)),
        const SizedBox(height: 24),
        _card(
          context,
          padding: 24,
          radius: 24,
          child: ListenableBuilder(
            listenable: _preview,
            builder: (context, _) {
              final manga = _preview.mode == AppMode.manga;
              return Column(
                children: [
                  Row(
                    children: [
                      Text(
                        L10n.text('Saved'),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                      ),
                      const Spacer(),
                      AppModeSwitch(state: _preview),
                      const Spacer(),
                      SizedBox(width: 32, child: Icon(CupertinoIcons.plus, size: 20, color: label)),
                    ],
                  ),
                  const SizedBox(height: 28),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Icon(manga ? Symbols.bookFill : Symbols.photoFill, key: ValueKey(manga), size: 64, color: tint),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    L10n.text(manga ? 'Comics Mode' : 'Image Mode'),
                    style: TegnalType.style(22, weight: FontWeight.w700, color: label),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Icon(CupertinoIcons.square_stack_3d_up, size: 15, color: secondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(L10n.text('Each mode keeps its own library and settings.'), style: TegnalType.style(13, color: secondary)),
            ),
          ],
        ),
      ],
    );
  }
}
