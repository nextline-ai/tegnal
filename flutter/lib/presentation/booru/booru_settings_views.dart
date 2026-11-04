import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/localization.dart';
import '../../core/booru/booru_browser.dart';
import '../../core/booru/booru_models.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/content_errors.dart';
import '../../core/support/l10n.dart';
import '../content/explore_view.dart' show ContentUnavailable;
import '../content/gallery_detail_view.dart' show GlassIconButton;
import '../content/reader_view.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../../core/storage/folder_rules.dart';
import '../library/folder_rule_editor.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import '../settings/downloads_view.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import '../settings/settings_view.dart' show DeveloperSection, GlassIconToolbarButton, LicensesPage, PrivacyPolicyPage;
import '../settings/site_account_section.dart' show WebCookies;
import '../settings/website_setup.dart';
import 'booru_common.dart';
import '../challenge/challenge_library_view.dart';
import 'booru_feed_view.dart';
import '../design/alert_dialog.dart';

/// What the More tab shares with comics Settings.
class BooruSettingsDependencies {
  const BooruSettingsDependencies({
    required this.booru,
    required this.content,
    required this.version,
    this.openLibraryManagement,
    this.resetSettings,
    this.sync,
    this.invitation,
    this.tasteSettings,
  });

  final BooruContext booru;

  /// The Taste Analysis row, between search history and sync.
  final Widget Function(BuildContext context)? tasteSettings;
  final ContentEnvironment content;
  final String version;
  final void Function(BuildContext context)? openLibraryManagement;
  final VoidCallback? resetSettings;
  final Widget Function(BuildContext context)? sync;
  final Widget Function(BuildContext context)? invitation;
}

/// `BooruMoreView`: image mode's settings, with each selected server's filters and connection.
class BooruMoreView extends StatefulWidget {
  const BooruMoreView({super.key, required this.dependencies});
  final BooruSettingsDependencies dependencies;

  @override
  State<BooruMoreView> createState() => _BooruMoreViewState();
}

class _BooruMoreViewState extends State<BooruMoreView> {
  bool _cacheCleared = false;

  BooruSettingsDependencies get _deps => widget.dependencies;
  BooruContext get _booru => _deps.booru;

  @override
  void initState() {
    super.initState();
    _booru.store.addListener(_changed);
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _setBrowser(String key, Object? value) => setState(() => _booru.preferences.set(key, value));
  void _setViewer(String key, Object? value) => setState(() => _booru.booruDefaults.set(key, value));

  void _push(Widget Function(BuildContext context) builder) => Navigator.of(context).push(CupertinoPageRoute<void>(builder: builder));

  Future<void> _setLanguage(String value) async {
    _booru.preferences.set('app.language', value);
    await loadLocalization(_booru.preferences);
    _booru.state.appearanceChanged();
    if (mounted) setState(() {});
  }

  Future<void> _clearCache() async {
    final clear = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Clear Image Cache?')),
        content: Text(L10n.text('Saved favorites are kept. Images will be downloaded again when needed.')),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Clear Image Cache'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (clear != true) return;
    await _booru.thumbnails.clear();
    await _booru.viewerImages.clear();
    if (mounted) setState(() => _cacheCleared = true);
  }

  Future<void> _confirmReset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Reset Settings to Defaults?')),
        message: Text(
          L10n.text(
            'Resets this mode’s appearance, browsing and viewer options. Libraries, website connections, sign-in details and iCloud settings are kept.',
          ),
        ),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Reset')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset != true) return;
    _deps.resetSettings?.call();
    _booru.state.appearanceChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final top = rootContentTop(context);
    final row = FormColors.listRow.resolveFrom(context);
    final preferences = _booru.preferences;
    final viewer = _booru.booruDefaults;
    final store = _booru.store;
    Widget section({String? header, String? footer, required List<Widget> children}) => FormSection(
      prominentHeader: true,
      rowColor: row,
      header: header == null ? null : Text(header),
      footer: footer == null ? null : Text(footer),
      children: children,
    );
    const automatic = 0;
    final columnOptions = [(automatic, L10n.text('Automatic')), for (var count = 1; count <= 5; count++) (count, '$count')];
    const columnHelp = 'Automatic fits the columns to the screen width. Choose a number to keep the layout fixed.';
    final remember = viewer.boolean('booru.rememberHistory') ?? true;
    final safeMode = preferences.boolean('booru.safeMode') ?? false;
    final safeRating = BooruSafeRating.fromRawValue(preferences.string('booru.safeRating')) ?? BooruSafeRating.general;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(top: top + 35, bottom: tabBarClearance(context)),
              children: [
                if (_deps.invitation != null) _deps.invitation!(context),
                section(
                  header: L10n.text('Browsing'),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Servers'),
                      symbol: (color) => ServerRackSymbol(color: color),
                      onTap: () => _push((context) => BooruServersView(booru: _booru, content: _deps.content)),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Challenge Roulette'),
                      symbol: (_) => DiceSymbol(color: SystemColors.purple.resolveFrom(context)),
                      onTap: () => _push((context) => ChallengeLibraryView(booru: _booru)),
                    ),
                    if (store.servers.isNotEmpty)
                      SettingsLinkRow(
                        title: L10n.text('Pools'),
                        icon: CupertinoIcons.rectangle_stack,
                        onTap: () => _push(
                          (context) => store.selectedServers.length == 1
                              ? BooruPoolsView(booru: _booru, server: store.selectedServers.first)
                              : BooruPoolServersView(booru: _booru),
                        ),
                      ),
                    SettingsLinkRow(
                      title: L10n.text('Downloads'),
                      icon: CupertinoIcons.arrow_down_circle,
                      onTap: () => _push((context) => DownloadsView(downloads: _booru.downloads, booru: true)),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Smart Folders'),
                      icon: CupertinoIcons.sparkles,
                      onTap: () => _push((context) => BooruFolderRulesPage(booru: _booru)),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Viewer'),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Viewer Detail Settings'),
                      icon: CupertinoIcons.slider_horizontal_3,
                      tinted: true,
                      onTap: () => showAppSheet<void>(
                        context,
                        grabber: true,
                        builder: (context, controller) => ReaderSettingsView(preferences: viewer, booru: true, scrollController: controller),
                      ),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Appearance'),
                  children: [
                    SettingsSegmentedRow<String>(
                      options: [('dark', L10n.text('Dark Mode')), ('light', L10n.text('Light Mode')), ('system', L10n.text('System Default'))],
                      selected: preferences.string('booru.app_theme') ?? 'dark',
                      onSelected: (value) {
                        _setBrowser('booru.app_theme', value);
                        _booru.state.appearanceChanged();
                      },
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Play Animation When Returning'),
                      value: preferences.boolean('app.resumeAnimation') ?? true,
                      onChanged: (value) => _setBrowser('app.resumeAnimation', value),
                    ),
                    SettingsSegmentedRow<int>(
                      title: L10n.text('Folder Columns'),
                      help: L10n.text(columnHelp),
                      options: columnOptions,
                      selected: _booru.folderColumns,
                      onSelected: (value) => _setBrowser('booru.folder_columns', value),
                    ),
                    SettingsSegmentedRow<int>(
                      title: L10n.text('Grid Columns'),
                      help: L10n.text(columnHelp),
                      options: columnOptions,
                      selected: _booru.gridPreferences.columns,
                      onSelected: (value) => _setBrowser('booru.grid_columns', value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Show Without Spacing'),
                      help: L10n.text('Removes the gaps and outer margins around artwork and folder thumbnails.'),
                      value: _booru.gridPreferences.removesPadding,
                      onChanged: (value) => _setBrowser('booru.grid.noPadding', value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Fit Entire Thumbnails'),
                      help: L10n.text('Shows the whole image inside each thumbnail. When off, thumbnails fill the card and may crop the edges.'),
                      value: _booru.fitsThumbnails,
                      onChanged: (value) => _setViewer('booru.fitThumbnails', value),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Language'),
                  children: [
                    SettingsPickerRow<String>(
                      title: L10n.text('App Language'),
                      options: [('system', L10n.text('System Language')), ('en', 'English'), ('ko', '한국어'), ('ja', '日本語')],
                      selected: preferences.string('app.language') ?? 'system',
                      onSelected: _setLanguage,
                    ),
                  ],
                ),
                for (final server in store.selectedServers) ...[
                  settingsSectionGap,
                  section(
                    header: '${L10n.text('Connection & Filters')} · ${server.displayName}',
                    children: [
                      SettingsLinkRow(
                        title: L10n.text('Tag Blacklist'),
                        icon: CupertinoIcons.eye_slash,
                        onTap: () => _push((context) => BooruBlacklistView(booru: _booru, server: server)),
                      ),
                      SettingsLinkRow(
                        title: L10n.text('Validate Client'),
                        help: L10n.text('Opens the website’s connection check. Complete it here if the server blocks searches or image loading.'),
                        icon: CupertinoIcons.checkmark_shield,
                        tinted: true,
                        chevron: false,
                        onTap: () => showBooruValidation(context, booru: _booru, server: server),
                      ),
                      SettingsLinkRow(
                        title: L10n.text('Cookies'),
                        icon: CupertinoIcons.shield_lefthalf_fill,
                        onTap: () => _push((context) => BooruCookiesView(booru: _booru, server: server)),
                      ),
                    ],
                  ),
                ],
                settingsSectionGap,
                section(
                  header: L10n.text('Search History'),
                  children: [
                    SettingsToggleRow(
                      title: L10n.text('Remember Search History'),
                      value: remember,
                      onChanged: (value) => _setViewer('booru.rememberHistory', value),
                    ),
                    SettingsPickerRow<int>(
                      title: L10n.text('Keep History'),
                      enabled: remember,
                      options: [(3, L10n.text('3 Days')), (7, L10n.text('7 Days')), (30, L10n.text('30 Days')), (0, L10n.text('Always'))],
                      selected: viewer.integerOrNull('search.retentionDays') ?? 0,
                      onSelected: (value) => _setViewer('search.retentionDays', value),
                    ),
                  ],
                ),
                if (_deps.tasteSettings != null) ...[settingsSectionGap, _deps.tasteSettings!(context)],
                if (_deps.sync != null) ...[settingsSectionGap, _deps.sync!(context)],
                settingsSectionGap,
                section(
                  header: L10n.text('Safe Mode'),
                  children: [
                    SettingsToggleRow(
                      title: L10n.text('Safe Mode'),
                      help: L10n.text(
                        'Adds one rating tag to image searches. You can change or remove it in your search. Comics Mode is unavailable while this is on because some comics websites do not support rating filters.',
                      ),
                      value: safeMode,
                      onChanged: (value) {
                        _setBrowser('booru.safeMode', value);
                        if (value) _booru.state.mode = AppMode.booru;
                      },
                    ),
                    if (safeMode) ...[
                      SettingsPickerRow<BooruSafeRating>(
                        title: L10n.text('Age Guide'),
                        options: [for (final rating in BooruSafeRating.values) (rating, rating.title)],
                        selected: safeRating,
                        onSelected: (value) => _setBrowser('booru.safeRating', value.rawValue),
                      ),
                      SettingsValueRow(title: L10n.text('Default Search Tag'), value: safeRating.tag),
                    ],
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Data & Storage'),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Library Management'),
                      symbol: (color) => ExternalDriveSymbol(color: color),
                      onTap: _deps.openLibraryManagement == null ? null : () => _deps.openLibraryManagement!(context),
                    ),
                    SettingsLinkRow(
                      title: L10n.text(_cacheCleared ? 'Image Cache Cleared' : 'Clear Image Cache'),
                      help: L10n.text(
                        'Deletes temporary thumbnails and viewer images from this device. Your saved works stay in the library; images download again when needed.',
                      ),
                      tinted: true,
                      chevron: false,
                      onTap: _clearCache,
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Help & Privacy'),
                  children: [
                    SettingsLinkRow(title: L10n.text('Privacy Policy'), icon: CupertinoIcons.hand_raised, onTap: () => _push((_) => const PrivacyPolicyPage())),
                    SettingsLinkRow(title: L10n.text('Open Source Licenses'), icon: CupertinoIcons.doc_text, onTap: () => _push((_) => const LicensesPage())),
                    SettingsValueRow(title: L10n.text('Version'), value: _deps.version),
                    SettingsLinkRow(
                      title: L10n.text('Reset Settings to Defaults'),
                      destructive: true,
                      chevron: false,
                      onTap: _deps.resetSettings == null ? null : _confirmReset,
                    ),
                  ],
                ),
                settingsSectionGap,
                const DeveloperSection(),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: RootHeader(
              title: L10n.text('More'),
              state: _booru.state,
              trailing: BooruServerMenuButton(store: store),
            ),
          ),
        ],
      ),
    );
  }
}

/// `BooruServersView`: the servers to search, each with its settings, and Add a Server.
class BooruServersView extends StatefulWidget {
  const BooruServersView({super.key, required this.booru, required this.content});
  final BooruContext booru;
  final ContentEnvironment content;

  @override
  State<BooruServersView> createState() => _BooruServersViewState();
}

class _BooruServersViewState extends State<BooruServersView> {
  BooruContext get _booru => widget.booru;

  @override
  void initState() {
    super.initState();
    _booru.store.addListener(_changed);
  }

  @override
  void dispose() {
    _booru.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _edit(BooruServer? server) => showWebsiteConnectionEditor(
    context,
    content: widget.content,
    state: _booru.state,
    booru: _booru.store,
    server: server,
    validate: (context, server) => showBooruValidation(context, booru: _booru, server: server),
    cookies: (context, server) => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (context) => BooruCookiesView(booru: _booru, server: server),
      ),
    ),
  );

  Future<void> _delete(BooruServer server) async {
    final delete = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Delete Server?')),
        message: Text(L10n.text('This removes the server and its Booru favorites, saved tags, artists, history and blacklist from this device.')),
        actions: [CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Delete')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (delete != true) return;
    _booru.store.deleteServer(server);
    await BooruBrowserSession.shared.reset(server);
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    final selected = _booru.store.selectedServerIDs.toSet();
    return SettingsPage(
      title: L10n.text('Servers'),
      children: [
        FormSection(
          rowColor: row,
          header: SettingsTitle(
            L10n.text('Servers'),
            help: L10n.text('Add a supported image website, then select the servers you want to search. Each server keeps its own favorites and filters.'),
          ),
          children: [
            for (final server in _booru.store.servers)
              Dismissible(
                key: ValueKey(server.id),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) async {
                  await _delete(server);
                  return false;
                },
                background: Container(
                  color: SystemColors.red.resolveFrom(context),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(L10n.text('Delete'), style: TegnalType.style(17, color: const Color(0xFFFFFFFF))),
                ),
                child: FormRow(
                  onTap: () => _booru.store.toggleServer(server),
                  separatorInset: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    child: Row(
                      children: [
                        Icon(selected.contains(server.id) ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, size: 22, color: tint),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(server.displayName),
                              const SizedBox(height: 5),
                              Text(Uri.tryParse(server.baseURL)?.host ?? '', style: TegnalType.style(12, color: secondary)),
                            ],
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: '${L10n.text('Edit')} ${server.displayName}',
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _edit(server),
                            child: SizedBox(width: 36, height: 36, child: Icon(CupertinoIcons.slider_horizontal_3, size: 20, color: tint)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            FormRow(
              onTap: () => _edit(null),
              child: Row(
                children: [
                  Icon(CupertinoIcons.plus, size: 22, color: tint),
                  const SizedBox(width: 12),
                  Text(L10n.text('Add a Server'), style: TegnalType.style(17, color: tint)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// `BooruBlacklistView`: one rule per line hides matching images on this server.
class BooruBlacklistView extends StatefulWidget {
  const BooruBlacklistView({super.key, required this.booru, required this.server});
  final BooruContext booru;
  final BooruServer server;

  @override
  State<BooruBlacklistView> createState() => _BooruBlacklistViewState();
}

class _BooruBlacklistViewState extends State<BooruBlacklistView> {
  late final _text = TextEditingController(text: widget.booru.store.blacklist(widget.server.id));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    try {
      widget.booru.store.setBlacklist(_text.text, serverID: widget.server.id);
      Navigator.of(context).pop();
    } on Object catch (error) {
      widget.booru.store.error = '$error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: widget.server.displayName,
      trailing: GlassTextButton(label: L10n.text('Save'), prominent: true, onPressed: _save),
      children: [
        FormSection(
          rowColor: row,
          header: SettingsTitle(
            L10n.text('Tag Blacklist'),
            help: L10n.text(
              'Enter one rule per line to hide matching images. You can use a tag, rating:explicit, id:123 or artist:name. Delete a rule to show those images again.',
            ),
          ),
          children: [
            FormRow(
              child: CupertinoTextField.borderless(
                controller: _text,
                minLines: 10,
                maxLines: null,
                padding: EdgeInsets.zero,
                autocorrect: false,
                enableSuggestions: false,
                style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
              ),
            ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          header: Text(L10n.text('Example')),
          children: [
            FormRow(
              child: Text(
                'spoilers\ngore -scenery\nrating:explicit\nartist_*',
                style: TegnalType.style(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Feeds and thumbnails retry once a server's client check passes (`.booruClientValidated`).
final booruClientValidated = ValueNotifier<(String, int)?>(null);

Future<void> showBooruValidation(BuildContext context, {required BooruContext booru, required BooruServer server, String? initialURL}) => showAppSheet<void>(
  context,
  builder: (context, controller) => BooruValidationView(booru: booru, server: server, initialURL: initialURL),
);

/// `BooruValidationView`: the server's website in a browser of its own, where the person
/// completes any check; its cookies then serve the app's requests to that server.
class BooruValidationView extends StatefulWidget {
  const BooruValidationView({super.key, required this.booru, required this.server, this.initialURL});
  final BooruContext booru;
  final BooruServer server;
  final String? initialURL;

  @override
  State<BooruValidationView> createState() => _BooruValidationViewState();
}

class _BooruValidationViewState extends State<BooruValidationView> {
  late final _state = BooruValidationState(widget.server);
  late final Uri _initial = Uri.parse(BooruBrowserSession.shared.challengePage(widget.server) ?? widget.initialURL ?? widget.server.browsingURL(''));
  WebViewController? _controller;
  Timer? _monitor;

  @override
  void initState() {
    super.initState();
    _state.addListener(_changed);
    _start();
  }

  @override
  void dispose() {
    _monitor?.cancel();
    _state.setActive(false);
    _finish();
    _state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // A website without its own background shows the browser's default white page.
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final decision = BooruValidationState.navigation(Uri.parse(request.url), newWindow: !request.isMainFrame);
            if (decision == BooruNavigationDecision.loadInPlace) {
              _controller?.loadRequest(Uri.parse(request.url));
              return NavigationDecision.prevent;
            }
            return decision == BooruNavigationDecision.allow ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onPageStarted: (_) => _state.didStart(),
          onPageFinished: (url) async {
            final controller = _controller;
            if (controller == null) return;
            _state.didFinish(Uri.tryParse(url), canGoBack: await controller.canGoBack(), canGoForward: await controller.canGoForward());
            _inspect();
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            final delay = _state.failed(_networkError(error));
            final retry = _state.retryURL;
            if (delay != null && retry != null) Timer(delay, () => _controller?.loadRequest(retry));
          },
        ),
      );
    final agent = await controller.getUserAgent();
    if (agent != null) BooruBrowserSession.shared.userAgent = agent;
    _controller = controller;
    _load(_initial);
    _monitor = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_state.isMonitoring) return;
      await _inspect();
      _state.monitorTick();
    });
  }

  void _load(Uri url) {
    final target = _state.load(url);
    if (widget.booru.fixture) {
      _controller?.loadHtmlString(
        "<html><meta name='viewport' content='width=device-width'><body><h2>Client verification</h2><p>Validation browser is ready.</p></body></html>",
        baseUrl: widget.server.baseURL,
      );
      return;
    }
    _controller?.loadRequest(target);
  }

  Future<void> _inspect() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final url = await controller.currentUrl();
      if (url == null) return;
      final result = await controller.runJavaScriptReturningResult(BooruBrowserScripts.challenge);
      _state.inspected(Uri.parse(url), result == true || result == 'true' ? true : (result == false || result == 'false' ? false : null));
    } on Object {
      // A page still loading has nothing to inspect yet.
    }
  }

  /// Keeps the website's cookies for the server's requests once its check passed.
  Future<void> _finish() async {
    if (!_state.canAdoptSession) return;
    final server = widget.server;
    final address = _state.address;
    if (address != null) {
      final header = await WebCookies.header(address);
      BooruBrowserSession.shared.importCookieHeader(header, address.toString(), server);
    }
    BooruBrowserSession.shared.clearChallenge(server);
    widget.booru.store.clearGoldRestrictions(serverID: server.id);
    booruClientValidated.value = (server.id, DateTime.now().microsecondsSinceEpoch);
  }

  Future<void> _reset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Reset Cookies?')),
        message: Text(L10n.text('Website cookies and cached website data for this server will be removed. Your favorites and API key are kept.')),
        actions: [
          CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Reset Cookies'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset != true) return;
    await BooruBrowserSession.shared.reset(widget.server);
    await WebCookies.clear();
    widget.booru.store.clearGoldRestrictions(serverID: widget.server.id);
    _load(_initial);
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final host = _state.address?.host ?? Uri.tryParse(widget.server.baseURL)?.host ?? widget.server.displayName;
    final controller = _controller;
    return ColoredBox(
      color: TegnalColors.background.resolveFrom(context),
      child: Column(
        children: [
          SheetNavigationBar(
            title: L10n.text('Validate Client'),
            leading: GlassIconButton(icon: CupertinoIcons.arrow_clockwise, label: L10n.text('Reload'), onPressed: () => _load(_state.address ?? _initial)),
            trailing: GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(CupertinoIcons.lock_shield, size: 18, color: tint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        host,
                        style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  L10n.text('Complete any verification on the website, then tap Done to retry. Cookies are saved for this server.'),
                  style: TegnalType.style(12, color: secondary),
                ),
              ],
            ),
          ),
          if (_state.challengeStalled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L10n.text('Verification is taking longer than expected. Reload, or reset this website’s cookies and try again.'),
                    style: TegnalType.style(13, color: TegnalColors.label.resolveFrom(context)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 16,
                    children: [
                      GestureDetector(
                        onTap: () => _load(_state.address ?? _initial),
                        child: Text(L10n.text('Reload'), style: TegnalType.style(13, color: tint)),
                      ),
                      GestureDetector(
                        onTap: _reset,
                        child: Text(L10n.text('Reset Cookies'), style: TegnalType.style(13, color: SystemColors.red.resolveFrom(context))),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_state.loading) const Padding(padding: EdgeInsets.all(4), child: CupertinoActivityIndicator()),
          Expanded(
            child: Stack(
              children: [
                if (controller != null) Positioned.fill(child: WebViewWidget(controller: controller)),
                if (_state.error case final error?)
                  Positioned.fill(
                    child: ColoredBox(
                      color: TegnalColors.background.resolveFrom(context),
                      child: Center(
                        child: ContentUnavailable(
                          icon: Symbols.wifiExclamationmark,
                          title: L10n.text('Unable to Load'),
                          message: error,
                          action: (L10n.text('Try Again'), () => _load(_initial)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The web view's failure as the connection error the client reports.
NetworkError _networkError(WebResourceError error) => NetworkError(switch (error.errorType) {
  WebResourceErrorType.hostLookup => NetworkErrorCode.cannotFindHost,
  WebResourceErrorType.timeout => NetworkErrorCode.timedOut,
  WebResourceErrorType.connect => NetworkErrorCode.cannotConnectToHost,
  WebResourceErrorType.failedSslHandshake => NetworkErrorCode.secureConnectionFailed,
  WebResourceErrorType.unsupportedScheme => NetworkErrorCode.unsupportedURL,
  WebResourceErrorType.badUrl => NetworkErrorCode.badURL,
  _ => NetworkErrorCode.networkConnectionLost,
});

/// `BooruCookiesView`: the cookies kept for one server, and Reset Cookies.
class BooruCookiesView extends StatefulWidget {
  const BooruCookiesView({super.key, required this.booru, required this.server});
  final BooruContext booru;
  final BooruServer server;

  @override
  State<BooruCookiesView> createState() => _BooruCookiesViewState();
}

class _BooruCookiesViewState extends State<BooruCookiesView> {
  final _expanded = <int>{};
  bool _resetting = false;

  List<BooruCookie> get _cookies =>
      [...BooruBrowserSession.shared.cookies(widget.server)]..sort((a, b) => a.domain == b.domain ? a.name.compareTo(b.name) : a.domain.compareTo(b.domain));

  Future<void> _reset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Reset Cookies?')),
        message: Text(L10n.text('Website cookies and cached website data for this server will be removed. Your favorites and API key are kept.')),
        actions: [
          CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Reset Cookies'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset != true) return;
    setState(() => _resetting = true);
    await BooruBrowserSession.shared.reset(widget.server);
    widget.booru.store.clearGoldRestrictions(serverID: widget.server.id);
    if (mounted) setState(() => _resetting = false);
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    final cookies = _cookies;
    Widget value(String title, String value) => Row(
      children: [
        Text(title),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TegnalType.style(17, color: secondary),
          ),
        ),
      ],
    );
    return SettingsPage(
      title: L10n.text('Cookies'),
      children: [
        FormSection(
          rowColor: row,
          header: Text(widget.server.displayName),
          footer: Text(L10n.text("Cookies are isolated from manga mode and other Booru servers. Resetting signs you out of this server's validation browser.")),
          children: [
            if (cookies.isEmpty)
              FormRow(
                child: Text(L10n.text('No Cookies'), style: TegnalType.style(17, color: secondary)),
              ),
            for (final (index, cookie) in cookies.indexed) ...[
              FormRow(
                onTap: () => setState(() => _expanded.contains(index) ? _expanded.remove(index) : _expanded.add(index)),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(cookie.name, style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context))),
                          const SizedBox(height: 4),
                          Text(cookie.domain, style: TegnalType.style(12, color: secondary)),
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded.contains(index) ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tint.resolveFrom(context)),
                    ),
                  ],
                ),
              ),
              if (_expanded.contains(index)) ...[
                FormRow(child: value(L10n.text('Domain'), cookie.domain)),
                FormRow(child: value(L10n.text('Path'), cookie.path)),
                FormRow(
                  child: Text(cookie.value, style: TegnalType.style(12, color: TegnalColors.label.resolveFrom(context))),
                ),
                if (cookie.expiresDate case final date?) FormRow(child: value(L10n.text('Expires'), date.toLocal().toString().split('.').first)),
              ],
            ],
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          children: [
            FormRow(
              onTap: _resetting ? null : _reset,
              child: Text(
                L10n.text('Reset Cookies'),
                style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context).withValues(alpha: _resetting ? 0.4 : 1)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// `BooruPoolsView`: a server's pools, searchable, each opening its posts in order.
class BooruPoolsView extends StatefulWidget {
  const BooruPoolsView({super.key, required this.booru, required this.server});
  final BooruContext booru;
  final BooruServer server;

  @override
  State<BooruPoolsView> createState() => _BooruPoolsViewState();
}

class _BooruPoolsViewState extends State<BooruPoolsView> {
  final _search = TextEditingController();
  String _query = '';
  List<BooruPool> _pools = [];
  int _page = 0;
  bool _hasMore = true;
  bool _loading = false;
  String? _error;
  int _generation = 0;

  BooruServer get _server => widget.server;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    _search.addListener(() {
      if (_search.text.isEmpty && _query.isNotEmpty) {
        _query = '';
        _load(reset: true);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && _loading) return;
    if (reset) {
      _generation++;
      _page = 0;
      _pools = [];
      _hasMore = true;
    }
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var scanned = 0;
      do {
        final result = await widget.booru.source.pools(_server, _query, _page);
        if (!mounted || generation != _generation) return;
        final seen = {for (final pool in _pools) pool.id};
        setState(() {
          _pools = [..._pools, ...result.where((pool) => (!pool.hasKnownCount || pool.count > 0) && seen.add(pool.id))];
          _hasMore = result.length >= (_server.engine.usesGelbooruPages ? 25 : 20);
          _page++;
        });
        scanned++;
        if (_pools.isEmpty && _hasMore && scanned < 5) await Future<void>.delayed(const Duration(milliseconds: 250));
      } while (_pools.isEmpty && _hasMore && scanned < 5);
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = BooruConnectionMessage.describe(error));
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Pools'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: CupertinoSearchTextField(
            controller: _search,
            placeholder: L10n.text(_server.engine.usesGelbooruPages ? 'Pool ID' : 'Search Pools'),
            onSubmitted: (text) {
              _query = text;
              _load(reset: true);
            },
          ),
        ),
        FormSection(
          rowColor: row,
          children: [
            if (_server.engine.usesGelbooruPages)
              FormRow(
                child: Text(L10n.text('Browse pools or enter a pool ID to open it.'), style: TegnalType.style(13, color: secondary)),
              ),
            for (final pool in _pools)
              FormRow(
                onTap: () => BooruFeedView.push(context, booru: widget.booru, server: _server, pool: pool),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      SizedBox(width: 36, child: Icon(CupertinoIcons.rectangle_stack_fill, size: 26, color: tint)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pool.name.replaceAll('_', ' '),
                              maxLines: 2,
                              style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              pool.hasKnownCount || pool.count > 0 ? '#${pool.id} · ${L10n.text('%@ posts', ['${pool.count}'])}' : '#${pool.id}',
                              style: TegnalType.style(12, color: secondary),
                            ),
                            if (pool.description.isNotEmpty) Text(pool.description, maxLines: 2, style: TegnalType.style(12, color: secondary)),
                          ],
                        ),
                      ),
                      Icon(CupertinoIcons.chevron_right, size: 14, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                    ],
                  ),
                ),
              ),
            if (_loading)
              const FormRow(child: Center(child: CupertinoActivityIndicator()))
            else if (_error != null) ...[
              FormRow(
                child: Text(_error!, style: TegnalType.style(15, color: secondary)),
              ),
              FormRow(
                onTap: () => _load(reset: true),
                child: Text(L10n.text('Try Again'), style: TegnalType.style(17, color: tint)),
              ),
              FormRow(
                onTap: () => showBooruValidation(context, booru: widget.booru, server: _server),
                child: Text(L10n.text('Validate Client'), style: TegnalType.style(17, color: tint)),
              ),
            ] else if (_pools.isEmpty && !_hasMore)
              FormRow(
                child: Text(L10n.text('No Results'), style: TegnalType.style(17, color: secondary)),
              ),
            if (_hasMore && !_loading && _error == null)
              FormRow(
                onTap: () => _load(reset: false),
                child: Text(L10n.text('Load More'), style: TegnalType.style(17, color: tint)),
              ),
          ],
        ),
      ],
    );
  }
}

/// `BooruPoolServersView`: pools are browsed one server at a time.
class BooruPoolServersView extends StatelessWidget {
  const BooruPoolServersView({super.key, required this.booru});
  final BooruContext booru;

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: L10n.text('Pools'),
    children: [
      FormSection(
        rowColor: FormColors.listRow.resolveFrom(context),
        children: [
          for (final server in booru.store.selectedServers)
            SettingsLinkRow(
              title: server.displayName,
              symbol: (color) => ServerRackSymbol(color: color),
              onTap: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (context) => BooruPoolsView(booru: booru, server: server),
                ),
              ),
            ),
        ],
      ),
    ],
  );
}

/// `FolderRulesView(booru:)`: image mode's smart folders.
class BooruFolderRulesPage extends StatefulWidget {
  const BooruFolderRulesPage({super.key, required this.booru});
  final BooruContext booru;

  @override
  State<BooruFolderRulesPage> createState() => _BooruFolderRulesPageState();
}

class _BooruFolderRulesPageState extends State<BooruFolderRulesPage> {
  Future<void> _edit(String? folder) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => FolderRuleEditor.existing(library: widget.booru.store, booru: true, folder: folder, scrollController: controller),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.booru.store;
    final rules = store.smartRules();
    final names = {for (final choice in store.folderChoices()) choice.id: choice.name};
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    final defaults = widget.booru.booruDefaults;
    return SettingsPage(
      title: L10n.text('Smart Folders'),
      trailing: GlassIconToolbarButton(icon: CupertinoIcons.plus, label: L10n.text('Add Smart Folder'), onPressed: () => _edit(null)),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(L10n.text('Hold a folder to make it a smart folder. Smart folders show %@ after their name.', ['✦'])),
          children: [
            SettingsToggleRow(
              title: L10n.text('Use Smart Folders'),
              value: defaults.boolean(LibrarySavePreferences.rulesEnabledKey) ?? true,
              onChanged: (value) => setState(() => defaults.set(LibrarySavePreferences.rulesEnabledKey, value)),
            ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          children: [
            if (rules.isEmpty)
              FormRow(
                child: Text(L10n.text('No smart folders yet.'), style: TegnalType.style(17, color: secondary)),
              ),
            for (final rule in rules)
              FormRow(
                onTap: () => _edit(rule.folder),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rule.query.replaceAll('_', ' ')),
                    if (rule.excluded.isNotEmpty)
                      Text(L10n.text('Except %@', [rule.excluded.replaceAll('_', ' ')]), style: TegnalType.style(12, color: secondary)),
                    Row(
                      children: [
                        Icon(CupertinoIcons.folder, size: 12, color: secondary),
                        const SizedBox(width: 4),
                        Text(names[rule.folder] ?? '', style: TegnalType.style(12, color: secondary)),
                      ],
                    ),
                    if (!rule.isActive) Text(L10n.text('Off'), style: TegnalType.style(12, color: secondary)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// `BooruSavedServersView`: the Tags tab for one server, or a list of the selected servers.
class BooruSavedServersView extends StatelessWidget {
  const BooruSavedServersView({super.key, required this.booru, required this.tags});
  final BooruContext booru;

  /// The Tags screen for a server, pushed or at the root.
  final Widget Function(BuildContext context, BooruServer server, {VoidCallback? onBack}) tags;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: booru.store,
    builder: (context, _) {
      final servers = booru.store.selectedServers;
      if (servers.length == 1) return KeyedSubtree(key: ValueKey(servers.first.id), child: tags(context, servers.first));
      final top = rootContentTop(context);
      return ColoredBox(
        color: FormColors.listBackground.resolveFrom(context),
        child: Stack(
          children: [
            Positioned.fill(
              child: servers.isEmpty
                  ? const Center(child: BooruNoSelectionView())
                  : ListView(
                      padding: EdgeInsets.only(top: top + 35, bottom: tabBarClearance(context)),
                      children: [
                        FormSection(
                          rowColor: FormColors.listRow.resolveFrom(context),
                          children: [
                            for (final server in servers)
                              SettingsLinkRow(
                                title: server.displayName,
                                symbol: (color) => ServerRackSymbol(color: color),
                                onTap: () =>
                                    Navigator.of(context)
                                        .push(CupertinoPageRoute<void>(builder: (context) => tags(context, server, onBack: () => Navigator.of(context).pop()))),
                              ),
                          ],
                        ),
                      ],
                    ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: RootHeader(
                title: L10n.text('Tags'),
                state: booru.state,
                trailing: BooruServerMenuButton(store: booru.store),
              ),
            ),
          ],
        ),
      );
    },
  );
}
