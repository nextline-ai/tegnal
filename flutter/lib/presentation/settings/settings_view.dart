import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/localization.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/gallery_content.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../content/reader_models.dart';
import '../content/reader_view.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/tegnal_theme.dart';
import '../library/folder_rule_editor.dart';
import '../library/library_routes.dart';
import '../navigation/app_header.dart';
import '../navigation/app_state.dart';
import '../navigation/root_tab_view.dart';
import 'settings_page.dart';
import 'settings_rows.dart';
import 'website_setup.dart';
import '../content/image_translation.dart';
import '../../core/content/recent_works.dart';
import 'recent_works_page.dart';
import '../../core/support/app_platform.dart';

/// What the Settings screens read and change.
class SettingsDependencies {
  const SettingsDependencies({
    required this.state,
    required this.content,
    required this.database,
    required this.preferences,
    required this.library,
    required this.version,
    this.extraSections = const [],
    this.openDownloads,
    this.openLibraryManagement,
    this.resetSettings,
    this.siteAccount,
    this.sync,
    this.invitation,
    this.tasteSettings,
    this.recentWorks,
    this.openWork,
  });

  /// Comics opened in the viewer lately, listed under Search History.
  final RecentWorks? recentWorks;

  /// Opens a work from that list as a thumbnail would.
  final void Function(BuildContext context, int id)? openWork;

  /// The Taste Analysis row, between search history and sync.
  final Widget Function(BuildContext context)? tasteSettings;

  final AppState state;
  final ContentEnvironment content;
  final AppDatabase database;
  final Preferences preferences;
  final LibraryRoutes library;
  final String version;
  final List<Widget> extraSections;
  final void Function(BuildContext context)? openDownloads;
  final void Function(BuildContext context)? openLibraryManagement;
  final VoidCallback? resetSettings;

  /// The website account section, shown when the connected site uses accounts.
  final Widget Function(BuildContext context)? siteAccount;

  /// The Google Drive section that stands in for iCloud.
  final Widget Function(BuildContext context)? sync;

  /// The community invitation banner at the top, while it is due.
  final Widget Function(BuildContext context)? invitation;
}

/// `SettingsView` for comics: browsing, viewer, saved works, appearance, language, search,
/// sync, data and help, in the native order.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.dependencies});
  final SettingsDependencies dependencies;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  SettingsDependencies get _deps => widget.dependencies;
  ContentEnvironment get _content => _deps.content;
  Preferences get _defaults => _deps.preferences;

  void _set(String key, Object? value) => setState(() => _defaults.set(key, value));

  Future<void> _setLanguage(String value) async {
    _defaults.set('app.language', value);
    await loadLocalization(_defaults);
    _deps.state.appearanceChanged();
    if (mounted) setState(() {});
  }

  void _setTheme(String value) {
    _defaults.set('app_theme', value);
    _deps.state.appearanceChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final top = rootContentTop(context);
    final row = FormColors.listRow.resolveFrom(context);
    Widget section({String? header, Widget? headerWidget, String? footer, required List<Widget> children}) => FormSection(
      prominentHeader: true,
      rowColor: row,
      header: headerWidget ?? (header == null ? null : Text(header)),
      footer: footer == null ? null : Text(footer),
      children: children,
    );
    final folders = _deps.database.listFolders();
    final defaultFolder = _deps.database.defaultSaveFolder().id;
    final remember = _defaults.boolean('search.rememberHistory') ?? true;
    final theme = _defaults.string('app_theme') ?? 'dark';
    const automatic = 0;
    final columnOptions = [(automatic, L10n.text('Automatic')), for (var count = 1; count <= 5; count++) (count, '$count')];
    const columnHelp = 'Automatic fits the columns to the screen width. Choose a number to keep the layout fixed.';
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              // An inset-grouped list starts its first section 35 pt under the bar.
              padding: EdgeInsets.only(top: top + 35, bottom: tabBarClearance(context)),
              children: [
                if (_deps.invitation != null) _deps.invitation!(context),
                section(
                  header: L10n.text('Browsing'),
                  children: [
                    if (_content.comicSites.isEmpty)
                      SettingsLinkRow(
                        title: L10n.text('Website Connection'),
                        icon: CupertinoIcons.globe,
                        tinted: true,
                        chevron: false,
                        onTap: () => showWebsiteConnectionEditor(context, content: _content, state: _deps.state),
                      )
                    else
                      SettingsLinkRow(
                        title: L10n.text('Website Connection'),
                        icon: CupertinoIcons.globe,
                        value: _content.mangaSiteAddress,
                        onTap: () => Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => ComicSitesPage(content: _content, state: _deps.state),
                          ),
                        ),
                      ),
                    if (AppPlatform.hasWebView)
                      SettingsToggleRow(
                        title: L10n.text('Use Embedded Browser'),
                        help: L10n.text('Opens the website instead of the app’s native screens. Try this if a website does not load correctly.'),
                        value: _content.useEmbeddedBrowser,
                        onChanged: (value) => setState(() => _content.useEmbeddedBrowser = value),
                      ),
                    SettingsToggleRow(
                      title: L10n.text('Show Work Information Before Reading'),
                      help: L10n.text('Shows the title, tags and page previews when you tap a work. When off, the work opens directly in the viewer.'),
                      value: _defaults.boolean(MangaThumbnailOpening.preferenceKey) ?? false,
                      onChanged: (value) => _set(MangaThumbnailOpening.preferenceKey, value),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Thumbnail Gestures'),
                      symbol: (color) => HandTapSymbol(size: 22, color: color),
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => const ThumbnailGestureSettings())),
                    ),
                  ],
                ),
                if (_deps.siteAccount != null) _deps.siteAccount!(context),
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
                        builder: (context, controller) => ReaderSettingsView(preferences: ReaderPreferences.defaults, scrollController: controller),
                      ),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Downloads'),
                      icon: CupertinoIcons.arrow_down_circle,
                      onTap: _deps.openDownloads == null ? null : () => _deps.openDownloads!(context),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Saved Works'),
                  children: [
                    SettingsPickerRow<int?>(
                      title: L10n.text('Default Save Folder'),
                      options: [for (final folder in folders) (folder.id, folder.displayName)],
                      selected: defaultFolder,
                      onSelected: (id) {
                        if (id == null) return;
                        _set(LibrarySavePreferences.defaultFolderKey, _deps.database.identityOfFolder(id));
                      },
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Smart Folders'),
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => FolderRulesPage(dependencies: _deps))),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Appearance'),
                  children: [
                    SettingsSegmentedRow<String>(
                      options: [('dark', L10n.text('Dark Mode')), ('light', L10n.text('Light Mode')), ('system', L10n.text('System Default'))],
                      selected: theme,
                      onSelected: _setTheme,
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Play Animation When Returning'),
                      value: _defaults.boolean('app.resumeAnimation') ?? true,
                      onChanged: (value) => _set('app.resumeAnimation', value),
                    ),
                    SettingsSegmentedRow<int>(
                      title: L10n.text('Folder Columns'),
                      help: L10n.text(columnHelp),
                      options: columnOptions,
                      selected: _content.mangaFolderColumns,
                      onSelected: (value) => setState(() => _content.mangaFolderColumns = value),
                    ),
                    SettingsSegmentedRow<int>(
                      title: L10n.text('Grid Columns'),
                      help: L10n.text(columnHelp),
                      options: columnOptions,
                      selected: _content.mangaColumns,
                      onSelected: (value) => setState(() => _content.mangaColumns = value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Show Without Spacing'),
                      help: L10n.text('Removes the gaps and outer margins around artwork and folder thumbnails.'),
                      value: _content.mangaRemovesGridPadding,
                      onChanged: (value) => setState(() => _content.mangaRemovesGridPadding = value),
                    ),
                    SettingsPickerRow<int>(
                      title: L10n.text('Preview Columns'),
                      help: L10n.text('Automatic shows twice as many columns as the artwork grid. Choose a number to keep the preview layout fixed.'),
                      tinted: true,
                      options: [(0, L10n.text('Automatic (2× Grid)')), for (var count = 1; count <= 10; count++) (count, '$count')],
                      selected: _content.mangaPreviewColumns,
                      onSelected: (value) => setState(() => _content.mangaPreviewColumns = value),
                    ),
                    SettingsPickerRow<int>(
                      title: L10n.text('Preview Rows per Page'),
                      tinted: true,
                      options: [for (var count = 1; count <= 10; count++) (count, '$count')],
                      selected: _content.mangaPreviewRows,
                      onSelected: (value) => setState(() => _content.mangaPreviewRows = value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Show Work Titles'),
                      value: _content.showsMangaTitles,
                      onChanged: (value) => setState(() => _content.showsMangaTitles = value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Show Work Artists'),
                      value: _content.showsMangaArtists,
                      onChanged: (value) => setState(() => _content.showsMangaArtists = value),
                    ),
                    SettingsToggleRow(
                      title: L10n.text('Show Work Categories'),
                      help: L10n.text("Shows each work's category, such as doujinshi or manga, in the bottom-left corner of its thumbnail."),
                      value: _content.showsMangaCategories,
                      onChanged: (value) => setState(() => _content.showsMangaCategories = value),
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
                      selected: _defaults.string('app.language') ?? 'system',
                      onSelected: _setLanguage,
                    ),
                    SettingsPickerRow<String>(
                      title: L10n.text('Artist Works Language'),
                      help: L10n.text(
                        "The language works start in when you open an artist, such as from a work's artist or a search for one artist. Changing the language there also changes this setting.",
                      ),
                      options: [
                        ('all', L10n.text('All')),
                        ('korean', L10n.text('Korean')),
                        ('japanese', L10n.text('Japanese')),
                        ('english', L10n.text('English')),
                      ],
                      selected: _defaults.string(ArtistBrowsing.preferenceKey) ?? 'all',
                      onSelected: (value) => _set(ArtistBrowsing.preferenceKey, value),
                    ),
                    SettingsPickerRow<String>(
                      title: L10n.text('Tag Works Language'),
                      help: L10n.text(
                        "The language works start in when you open a single tag, such as from a work's tags. Changing the language there also changes this setting. Searches with several words keep All.",
                      ),
                      options: [
                        ('all', L10n.text('All')),
                        ('korean', L10n.text('Korean')),
                        ('japanese', L10n.text('Japanese')),
                        ('english', L10n.text('English')),
                      ],
                      selected: _defaults.string(TagBrowsing.preferenceKey) ?? 'all',
                      onSelected: (value) => _set(TagBrowsing.preferenceKey, value),
                    ),
                    if (AppPlatform.hasImageTranslation)
                      SettingsLinkRow(
                        title: L10n.text('Translation Language'),
                        icon: CupertinoIcons.text_bubble,
                        onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => TranslationLanguagePage(preferences: _defaults))),
                      ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Search'),
                  children: [
                    SettingsToggleRow(
                      title: L10n.text('Allow Language Filter Exceptions'),
                      help: L10n.text(
                        'Includes Game CG, Artist CG and Image Set even when their language differs from your filter. Turn off to apply the language filter to all works.',
                      ),
                      value: _content.allowsMangaLanguageExceptions,
                      onChanged: (value) => setState(() => _content.allowsMangaLanguageExceptions = value),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Default Search Tags'),
                      icon: CupertinoIcons.line_horizontal_3_decrease,
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => DefaultSearchTagsPage(content: _content))),
                    ),
                  ],
                ),
                settingsSectionGap,
                section(
                  header: L10n.text('Search History'),
                  children: [
                    SettingsToggleRow(
                      title: L10n.text('Remember Search History'),
                      value: remember,
                      onChanged: (value) => _set('search.rememberHistory', value),
                    ),
                    SettingsPickerRow<int>(
                      title: L10n.text('Keep History'),
                      enabled: remember,
                      options: [(3, L10n.text('3 Days')), (7, L10n.text('7 Days')), (30, L10n.text('30 Days')), (0, L10n.text('Always'))],
                      selected: _defaults.integerOrNull('search.retentionDays') ?? 0,
                      onSelected: (value) => _set('search.retentionDays', value),
                    ),
                    if (_deps.recentWorks != null && _deps.openWork != null)
                      ...RecentWorksSettingsRows.comics(context, recents: _deps.recentWorks!, routes: _deps.library),
                  ],
                ),
                if (_deps.tasteSettings != null) ...[settingsSectionGap, _deps.tasteSettings!(context)],
                if (_deps.sync != null) ...[settingsSectionGap, _deps.sync!(context)],
                settingsSectionGap,
                section(
                  header: L10n.text('Data & Storage'),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Library Management'),
                      symbol: (color) => ExternalDriveSymbol(color: color),
                      onTap: _deps.openLibraryManagement == null ? null : () => _deps.openLibraryManagement!(context),
                    ),
                  ],
                ),
                ..._deps.extraSections,
                settingsSectionGap,
                section(
                  header: L10n.text('Help & Privacy'),
                  children: [
                    SettingsLinkRow(
                      title: L10n.text('Privacy Policy'),
                      icon: CupertinoIcons.hand_raised,
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => const PrivacyPolicyPage())),
                    ),
                    SettingsLinkRow(
                      title: L10n.text('Open Source Licenses'),
                      icon: CupertinoIcons.doc_text,
                      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => const LicensesPage())),
                    ),
                    SettingsValueRow(title: L10n.text('Version'), value: _deps.version),
                    SettingsLinkRow(
                      title: L10n.text('Reset Settings to Defaults'),
                      destructive: true,
                      chevron: false,
                      onTap: _deps.resetSettings == null ? null : () => _confirmReset(context),
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
            child: RootHeader(title: L10n.text('Settings'), state: _deps.state),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
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
    _deps.resetSettings!();
    _deps.state.appearanceChanged();
    if (mounted) setState(() {});
  }
}

/// `MangaDefaultTagsSettings`' form: tags added to and excluded from every comics search.
class DefaultSearchTagsPage extends StatefulWidget {
  const DefaultSearchTagsPage({super.key, required this.content});
  final ContentEnvironment content;

  @override
  State<DefaultSearchTagsPage> createState() => _DefaultSearchTagsPageState();
}

class _DefaultSearchTagsPageState extends State<DefaultSearchTagsPage> {
  late final TextEditingController _tags = TextEditingController(text: widget.content.defaultTags)..addListener(() => widget.content.defaultTags = _tags.text);
  late final TextEditingController _excluded = TextEditingController(text: widget.content.defaultExcludedTags)
    ..addListener(() => widget.content.defaultExcludedTags = _excluded.text);

  @override
  void dispose() {
    _tags.dispose();
    _excluded.dispose();
    super.dispose();
  }

  Widget _field(TextEditingController controller, String placeholder) => FormRow(
    child: CupertinoTextField.borderless(
      controller: controller,
      minLines: 3,
      maxLines: 6,
      padding: EdgeInsets.zero,
      autocorrect: false,
      enableSuggestions: false,
      placeholder: placeholder,
      placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
      style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Default Search Tags'),
      children: [
        FormSection(
          rowColor: row,
          header: SettingsTitle(
            L10n.text('Default Tags'),
            help: L10n.text('Adds these tags to every comics search. Separate tags with spaces and use underscores inside a tag.'),
          ),
          children: [_field(_tags, 'tag:scenery')],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          header: SettingsTitle(
            L10n.text('Default Excluded Tags'),
            help: L10n.text('Hides matching works from every comics search. Enter tags normally; the app adds the minus sign for you.'),
          ),
          children: [_field(_excluded, 'tag:spoilers')],
        ),
      ],
    );
  }
}

/// `FolderRulesView`: the switch for smart folders and each folder's rule.
class FolderRulesPage extends StatefulWidget {
  const FolderRulesPage({super.key, required this.dependencies});
  final SettingsDependencies dependencies;

  @override
  State<FolderRulesPage> createState() => _FolderRulesPageState();
}

class _FolderRulesPageState extends State<FolderRulesPage> {
  AppDatabase get _database => widget.dependencies.database;
  List<FolderRule> _rules = [];
  Map<String, String> _names = {};
  Set<String> _defaultSources = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() => setState(() {
    _rules = _database.smartRules();
    _names = {for (final choice in _database.folderChoices()) choice.id: choice.name};
    _defaultSources = _database.defaultRuleSources();
  });

  Future<void> _edit(String? folder) async {
    await showAppSheet<void>(
      context,
      builder: (context, controller) => FolderRuleEditor.existing(library: _database, folder: folder, scrollController: controller),
    );
    widget.dependencies.library.notifyChanged();
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final defaults = widget.dependencies.preferences;
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Smart Folders'),
      trailing: GlassIconToolbarButton(icon: CupertinoIcons.plus, label: L10n.text('Add Smart Folder'), onPressed: () => _edit(null)),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text('A smart folder files new saves that match its tags. Hold a folder to make it one; smart folders show %@ after their name.', ['✦']),
          ),
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
            if (_rules.isEmpty)
              FormRow(
                child: Text(L10n.text('No smart folders yet.'), style: TegnalType.style(17, color: secondary)),
              ),
            for (final rule in _rules)
              FormRow(
                onTap: () => _edit(rule.folder),
                child: Dismissible(
                  key: ValueKey(rule.folder),
                  direction: DismissDirection.endToStart,
                  onDismissed: (_) {
                    _database.deleteRule(rule.folder);
                    _reload();
                  },
                  background: Container(
                    color: CupertinoColors.systemRed.resolveFrom(context),
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(CupertinoIcons.trash, color: Color(0xFFFFFFFF)),
                  ),
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
                          Text(_names[rule.folder] ?? '', style: TegnalType.style(12, color: secondary)),
                        ],
                      ),
                      SmartFolderSummaryRow(rule: rule, booru: false, names: _names, defaultSources: _defaultSources),
                      if (!rule.isActive) Text(L10n.text('Off'), style: TegnalType.style(12, color: secondary)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A single toolbar icon in its own glass circle on a pushed screen.
class GlassIconToolbarButton extends StatelessWidget {
  const GlassIconToolbarButton({super.key, required this.icon, required this.label, required this.onPressed});
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ToolbarGroup(
    children: [ToolbarIconButton(label: label, icon: icon, size: 22, onPressed: onPressed)],
  );
}

/// The Android privacy policy linked from the Play listing, in the app language
/// (its Korean part for Korean, its English part otherwise).
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static Future<String> _load() async {
    final text = await rootBundle.loadString('assets/legal/privacy-policy-android.md');
    final english = text.indexOf('\n# English');
    final part = L10n.language == 'ko' ? text.substring(0, english < 0 ? text.length : english) : text.substring(english < 0 ? 0 : english + 1);
    // Plain text, as the native screen shows its policy: headings and emphasis lose their markers.
    return part
        .replaceAll(RegExp(r'^#+ ', multiLine: true), '')
        .replaceAll('**', '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (match) => '${match[1]} (${match[2]})')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Privacy Policy'),
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<String>(
            future: _load(),
            builder: (context, snapshot) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.data ?? (snapshot.hasError ? L10n.text('Unable to load privacy policy.') : ''),
                  style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse('mailto:contact@nextline.work')),
                  child: Text('contact@nextline.work', style: TegnalType.style(17, color: tint)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// `AcknowledgmentsView`: the licenses of the libraries the app ships with.
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static Future<String> _load() async {
    final entries = <String>[];
    await for (final license in LicenseRegistry.licenses) {
      final text = license.paragraphs.map((paragraph) => '${'  ' * paragraph.indent.clamp(0, 8)}${paragraph.text}').join('\n');
      entries.add('${license.packages.join(', ')}\n\n$text');
    }
    return entries.join('\n\n────────\n\n');
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: L10n.text('Open Source Licenses'),
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: FutureBuilder<String>(
          future: _load(),
          builder: (context, snapshot) => Text(snapshot.data ?? '', style: TegnalType.style(13, color: TegnalColors.label.resolveFrom(context))),
        ),
      ),
    ],
  );
}

/// `DeveloperInfoSection`: the developer's mark, links and community buttons.
class DeveloperSection extends StatelessWidget {
  const DeveloperSection({super.key});

  static final website = Uri.parse('https://nextline.work');
  static final community = Uri.parse('https://discord.gg/DFT9Hm66Gz');
  static final source = Uri.parse('https://github.com/nextline-ai/tegnal');

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final suffix = L10n.language == 'ko' ? 'kr' : 'en';
    Widget button(String service, Uri destination, String label) => Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () => launchUrl(destination, mode: LaunchMode.externalApplication),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Image.asset('assets/developer/${service}_button_$suffix.png', fit: BoxFit.contain),
        ),
      ),
    );
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Text(L10n.text('Developer')),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Semantics(
              label: 'NextLine',
              child: SizedBox(
                width: 230,
                height: 64,
                child: Image.asset(dark ? 'assets/developer/nextline_logo_dark.png' : 'assets/developer/nextline_logo_light.png', fit: BoxFit.contain),
              ),
            ),
          ),
        ),
        SettingsValueRow(title: L10n.text('Developer'), value: 'NextLine'),
        FormRow(
          separatorInset: settingsIconInset,
          onTap: () => launchUrl(website, mode: LaunchMode.externalApplication),
          child: Row(
            children: [
              SizedBox(width: 24, child: Icon(Symbols.globe, size: 22, color: tint)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(L10n.text('Website'), style: TegnalType.style(17, color: tint)),
              ),
              Text('nextline.work', style: TegnalType.style(17, color: tint)),
              const SizedBox(width: 6),
              Icon(CupertinoIcons.arrow_up_right, size: 12, color: tint),
            ],
          ),
        ),
        FormRow(
          separatorInset: settingsIconInset,
          onTap: () => launchUrl(Uri.parse('mailto:contact@nextline.work')),
          child: Row(
            children: [
              SizedBox(width: 24, child: Icon(CupertinoIcons.envelope, size: 22, color: tint)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(L10n.text('Email'), style: TegnalType.style(17, color: tint)),
              ),
              Text('contact@nextline.work', style: TegnalType.style(17, color: secondary)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            children: [
              button('discord', community, '${L10n.text('Community & Bug Reports')} · Discord'),
              const SizedBox(height: 10),
              button('github', source, L10n.text('View on GitHub')),
            ],
          ),
        ),
      ],
    );
  }
}

/// Chooses what each gesture on a thumbnail does, for comics or for image mode.
class ThumbnailGestureSettings extends StatefulWidget {
  const ThumbnailGestureSettings({super.key, this.booru = false});
  final bool booru;

  @override
  State<ThumbnailGestureSettings> createState() => _ThumbnailGestureSettingsState();
}

class _ThumbnailGestureSettingsState extends State<ThumbnailGestureSettings> {
  bool get _booru => widget.booru;

  void _choose(ThumbnailGesture gesture, ThumbnailAction action) => setState(() => gesture.choose(action, booru: _booru));

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Thumbnail Gestures'),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text(
              _booru ? 'Applies to images in Explore. A double tap action makes single taps wait a moment for a second tap.' : 'Applies to works in Explore and related works. Open follows Show Work Information Before Reading. Holding a work and moving it still carries it to Up Next. A double tap action makes single taps wait a moment for a second tap.',
            ),
          ),
          children: [
            for (final gesture in ThumbnailGesture.values)
              SettingsPickerRow<ThumbnailAction>(
                title: gesture.title,
                options: [for (final action in gesture.choices(booru: _booru)) (action, action.title)],
                selected: gesture.action(booru: _booru),
                onSelected: (action) => _choose(gesture, action),
              ),
          ],
        ),
        settingsSectionGap,
        FormSection(
          rowColor: row,
          children: [
            SettingsLinkRow(
              title: L10n.text('Reset to Defaults'),
              tinted: true,
              chevron: false,
              onTap: () => setState(() {
                for (final gesture in ThumbnailGesture.values) {
                  gesture.choose(gesture.standard(booru: _booru), booru: _booru);
                }
              }),
            ),
          ],
        ),
      ],
    );
  }
}
