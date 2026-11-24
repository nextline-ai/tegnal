import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/support/app_platform.dart';
import '../../core/support/l10n.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';

/// `SettingsCategory`: the pages Settings is divided into, as the system Settings app divides
/// its own. The top level lists only these, the ones that change the most first.
enum SettingsCategory {
  browsing('Explore & Search', SystemColors.blue),
  viewer('Viewer', SystemColors.orange),
  appearance('Appearance & Layout', SystemColors.indigo),
  language('Language & Translation', SystemColors.teal),
  library('Library & Storage', SystemColors.gray),
  taste('Taste Analysis', SystemColors.pink),
  addons('Add-ons', SystemColors.purple),
  start('Start & Safe Mode', SystemColors.green),
  privacy('Privacy & Security', SystemColors.blue),
  help('Help & About', SystemColors.gray);

  const SettingsCategory(this.titleKey, this.tint);
  final String titleKey;
  final CupertinoDynamicColor tint;

  String get title => L10n.text(titleKey);

  /// The white glyph inside the page's tile.
  Widget glyph(double size) => switch (this) {
    SettingsCategory.browsing => Icon(CupertinoIcons.search, size: size, color: CupertinoColors.white),
    SettingsCategory.viewer => Icon(CupertinoIcons.book_fill, size: size, color: CupertinoColors.white),
    SettingsCategory.appearance => Icon(CupertinoIcons.square_grid_2x2_fill, size: size, color: CupertinoColors.white),
    SettingsCategory.language => Icon(CupertinoIcons.chat_bubble_text_fill, size: size, color: CupertinoColors.white),
    SettingsCategory.library => ExternalDriveSymbol(size: size, color: CupertinoColors.white),
    SettingsCategory.taste => Icon(CupertinoIcons.sparkles, size: size, color: CupertinoColors.white),
    SettingsCategory.addons => PuzzlePieceSymbol(size: size, color: CupertinoColors.white),
    SettingsCategory.start => Icon(CupertinoIcons.power, size: size, color: CupertinoColors.white),
    SettingsCategory.privacy => Icon(CupertinoIcons.hand_raised_fill, size: size, color: CupertinoColors.white),
    SettingsCategory.help => Icon(CupertinoIcons.question, size: size, color: CupertinoColors.white),
  };

  /// Top-level groups, in order: what changes every visit first, help last.
  /// Add-ons sits with the website or servers, above these, since add-ons change what those show.
  static const groups = [
    [browsing, viewer, appearance, language],
    [library, taste],
    [start, privacy],
    [help],
  ];
}

/// `SettingsIconTile`: the colored square the system Settings app draws beside each page.
class SettingsIconTile extends StatelessWidget {
  const SettingsIconTile({super.key, required this.color, required this.glyph});
  final Color color;
  final Widget Function(double size) glyph;

  static const size = 29.0;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.24)),
      alignment: Alignment.center,
      child: glyph(size * 0.56),
    ),
  );
}

/// A row that leads with a tile, as the top level of Settings lists its pages.
class SettingsTileRow extends StatelessWidget implements FormSeparatorInset {
  const SettingsTileRow({super.key, required this.title, required this.tile, this.subtitle, this.value, this.onTap, this.chevron = true});
  final String title;
  final String? subtitle;
  final String? value;
  final Widget tile;
  final VoidCallback? onTap;
  final bool chevron;

  @override
  double get separatorInset => 16 + SettingsIconTile.size + 14;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: FormRow(
      onTap: onTap,
      minHeight: subtitle == null ? 52 : 60,
      separatorInset: separatorInset,
      child: Row(
        children: [
          tile,
          const SizedBox(width: 14),
          Expanded(
            child: subtitle == null
                ? Text(title, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context))),
                      const SizedBox(height: 2),
                      Text(subtitle!, style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                    ],
                  ),
          ),
          if (value != null) ...[
            Text(
              value!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context)),
            ),
            const SizedBox(width: 6),
          ],
          if (chevron) Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
        ],
      ),
    ),
  );
}

/// `SettingsItem`: one setting or page search finds, as in iOS's `SettingsCatalog`.
class SettingsItem {
  const SettingsItem(this.id, this.titleKey, this.category, {this.keywords = ''});
  final String id;
  final String titleKey;
  final SettingsCategory category;

  /// Extra English words search matches, such as "dark" for the theme.
  final String keywords;

  String get title => L10n.text(titleKey);
}

/// `SettingsCatalog`: every setting search knows about, for one mode, and the search itself.
abstract final class SettingsCatalog {
  static List<SettingsItem> items({required bool booru}) {
    const b = SettingsCategory.browsing, v = SettingsCategory.viewer, a = SettingsCategory.appearance, l = SettingsCategory.language;
    const lib = SettingsCategory.library, s = SettingsCategory.start, p = SettingsCategory.privacy, h = SettingsCategory.help;
    return [
      // Explore & Search
      if (AppPlatform.hasWebView) const SettingsItem('browse.embeddedBrowser', 'Use Embedded Browser', b),
      if (!booru) const SettingsItem('browse.informationFirst', 'Show Work Information Before Reading', b),
      const SettingsItem('browse.thumbnailGestures', 'Thumbnail Gestures', b),
      if (booru) const SettingsItem('browse.blacklist', 'Tag Blacklist', b, keywords: 'block hide tag filter'),
      if (!booru) ...const [
        SettingsItem('search.languageExceptions', 'Allow Language Filter Exceptions', b),
        SettingsItem('search.requireTags', 'Default Tags', b, keywords: 'filter include'),
        SettingsItem('search.hideTags', 'Default Excluded Tags', b, keywords: 'block hide blacklist filter artist'),
      ],
      const SettingsItem('search.rememberHistory', 'Remember Search History', b),
      const SettingsItem('search.keepHistory', 'Keep History', b),
      SettingsItem('browse.recent', booru ? 'Recently Opened Images' : 'Recently Opened Works', b, keywords: 'recent history'),
      const SettingsItem('browse.recentInSaved', 'Show as Folder in Saved', b),
      // Viewer
      if (!booru) ...const [
        SettingsItem('reader.resume', 'When Reopening a Work', v),
        SettingsItem('reader.mode', 'Reading Mode', v, keywords: 'scroll webtoon vertical'),
        SettingsItem('reader.pages', 'Pages per View', v, keywords: 'spread two pages'),
      ],
      const SettingsItem('reader.rtl', 'Read Right to Left', v, keywords: 'manga direction rtl'),
      const SettingsItem('reader.tapNavigation', 'Tap the Sides to Turn Pages', v),
      const SettingsItem('reader.doubleTapZoom', 'Double Tap to Zoom', v),
      if (booru) ...const [
        SettingsItem('reader.notes', 'Show Notes on Images', v),
        SettingsItem('reader.original', 'Load Original Images', v, keywords: 'quality data'),
        SettingsItem('reader.reducedData', 'Reduce Image Data Further', v, keywords: 'data cellular'),
      ],
      if (AppPlatform.hasImageTranslation && !booru) const SettingsItem('reader.aiTranslation', 'AI Translation (Beta)', v, keywords: 'translate'),
      const SettingsItem('reader.bottomMenu', 'Show Quick Menu at Bottom', v),
      const SettingsItem('reader.pageNumber', 'Show Page Number', v),
      if (!booru) const SettingsItem('reader.versionBanner', 'Preferred Language Version Banner', v),
      const SettingsItem('reader.keepAwake', 'Keep Screen Awake While Reading', v, keywords: 'sleep lock'),
      const SettingsItem('reader.dimming', 'Dim Screen', v, keywords: 'brightness dark night'),
      const SettingsItem('reader.autoAdvance', 'Auto Advance', v, keywords: 'slideshow automatic'),
      if (!booru) const SettingsItem('reader.prefetch', 'Prefetch Pages', v, keywords: 'preload data'),
      const SettingsItem('reader.guide', 'Reader Guide', v, keywords: 'help gestures tutorial'),
      // Appearance & Layout
      const SettingsItem('appearance.theme', 'Appearance', a, keywords: 'theme dark light mode color'),
      const SettingsItem('appearance.thumbnailSize', 'Grid Columns', a, keywords: 'size thumbnail bigger smaller'),
      const SettingsItem('appearance.folderSize', 'Folder Columns', a),
      const SettingsItem('appearance.noSpacing', 'Show Without Spacing', a, keywords: 'padding gap margin'),
      if (booru) const SettingsItem('appearance.fitThumbnails', 'Fit Entire Thumbnails', a, keywords: 'crop'),
      if (!booru) ...const [
        SettingsItem('appearance.previewColumns', 'Preview Columns', a),
        SettingsItem('appearance.previewRows', 'Preview Rows per Page', a),
        SettingsItem('appearance.titles', 'Show Work Titles', a),
        SettingsItem('appearance.artists', 'Show Work Artists', a),
        SettingsItem('appearance.categories', 'Show Work Categories', a),
      ],
      // Language & Translation
      const SettingsItem('language.app', 'App Language', l),
      if (!booru) ...const [
        SettingsItem('language.preferred', 'Preferred Language', l),
        SettingsItem('language.artistWorks', 'Artist Works Language', l),
        SettingsItem('language.tagWorks', 'Tag Works Language', l),
      ],
      if (AppPlatform.hasImageTranslation) const SettingsItem('language.translation', 'Translation Language', l, keywords: 'translate'),
      // Library & Storage
      const SettingsItem('library.downloads', 'Downloads', lib, keywords: 'download offline'),
      if (!booru) const SettingsItem('library.defaultFolder', 'Default Save Folder', lib, keywords: 'folder save'),
      const SettingsItem('library.smartFolders', 'Smart Folders', lib, keywords: 'folder rule automatic'),
      const SettingsItem('library.management', 'Library Management', lib, keywords: 'backup import export sync drive'),
      const SettingsItem('library.duplicates', 'Clean Up Duplicates', lib, keywords: 'duplicate'),
      const SettingsItem('library.classify', 'Classify into Folders', lib, keywords: 'folder organize'),
      SettingsItem('library.cache', booru ? 'Clear Image Cache' : 'Image Cache', lib, keywords: 'cache storage space'),
      if (AppPlatform.hasDriveSync) const SettingsItem('library.sync', 'Google Drive', lib, keywords: 'sync backup cloud'),
      const SettingsItem('taste', 'Taste Analysis', SettingsCategory.taste, keywords: 'recommendation'),
      const SettingsItem('addons', 'Add-ons', SettingsCategory.addons, keywords: 'addon plugin extension'),
      // Start & Safe Mode
      const SettingsItem('start.safeMode', 'Safe Mode', s, keywords: 'safe kids sfw'),
      const SettingsItem('start.learning', 'Open in Learning Mode', s),
      const SettingsItem('start.viewing', 'Open in Viewing Mode', s),
      // Privacy & Security
      const SettingsItem('privacy.incognito', 'Incognito Mode', p, keywords: 'private history'),
      const SettingsItem('privacy.capture', 'Hide During Screen Recording', p, keywords: 'screenshot mirror'),
      const SettingsItem('privacy.dns', 'Encrypted DNS', p, keywords: 'network dns'),
      // Help & About
      const SettingsItem('help.onboarding', 'Replay Onboarding', h, keywords: 'tutorial'),
      const SettingsItem('help.privacyPolicy', 'Privacy Policy', h),
      const SettingsItem('help.licenses', 'Open Source Licenses', h),
      const SettingsItem('help.reset', 'Reset Settings to Defaults', h, keywords: 'reset default'),
    ];
  }

  /// Settings whose title, page or keywords contain every word of the query: a title starting
  /// with the query first, then one holding it whole, then the rest in page order.
  static List<SettingsItem> search(String query, List<SettingsItem> items) {
    final words = fold(query).split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    final matches = items.where((item) {
      final text = fold([item.title, item.titleKey, item.category.title, item.category.titleKey, item.keywords].join(' '));
      // Korean and Japanese are often typed without the spaces a title has.
      final compact = text.replaceAll(' ', '');
      return words.every((word) => text.contains(word) || compact.contains(word));
    }).toList();
    final phrase = words.join(' ');
    int rank(SettingsItem item) {
      final titles = [fold(item.title), fold(item.titleKey)];
      if (titles.any((title) => title.startsWith(phrase))) return 0;
      return titles.any((title) => title.contains(phrase)) ? 1 : 2;
    }

    final indexed = matches.indexed.toList()
      ..sort((lhs, rhs) {
        final order = rank(lhs.$2).compareTo(rank(rhs.$2));
        return order != 0 ? order : lhs.$1.compareTo(rhs.$1);
      });
    return [for (final entry in indexed) entry.$2];
  }

  /// Korean titles carry U+2060 word joiners for line breaking (`L10n.keepingWords`); search ignores them.
  static String fold(String text) => text.replaceAll('\u2060', '').toLowerCase();
}

/// `SettingsHome`: Settings' top level for either mode. A search field, the mode's own
/// connection rows, then a short list of pages, those that change the most first.
class SettingsHome extends StatefulWidget {
  const SettingsHome({super.key, required this.booru, required this.top, required this.open, this.leading = const [], this.bottom = const [], this.addonsCount});
  final bool booru;

  /// The website or server rows, first as an account is in the system Settings app.
  final List<Widget> top;

  /// First, above search, such as the community invitation.
  final List<Widget> leading;

  /// Last, under the pages, such as the developer section.
  final List<Widget> bottom;
  final void Function(SettingsCategory category) open;

  /// The add-ons turned on, beside the Add-ons page.
  final int? addonsCount;

  @override
  State<SettingsHome> createState() => _SettingsHomeState();
}

class _SettingsHomeState extends State<SettingsHome> {
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Widget _pageRow(SettingsCategory category) => SettingsTileRow(
    key: Key('settings.category.${category.name}'),
    title: category.title,
    tile: _tile(category),
    value: category == SettingsCategory.addons && (widget.addonsCount ?? 0) > 0 ? '${widget.addonsCount}' : null,
    onTap: () => widget.open(category),
  );

  Widget _tile(SettingsCategory category) => SettingsIconTile(color: category.tint.resolveFrom(context), glyph: category.glyph);

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final query = _query.text.trim();
    final found = query.isEmpty ? const <SettingsItem>[] : SettingsCatalog.search(query, SettingsCatalog.items(booru: widget.booru));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The community invitation comes first, above everything else, while it is due.
        if (query.isEmpty) ...widget.leading,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: CupertinoSearchTextField(key: const Key('settings.search'), controller: _query, placeholder: L10n.text('Search Settings')),
        ),
        if (query.isNotEmpty)
          FormSection(
            rowColor: row,
            children: [
              if (found.isEmpty)
                FormRow(
                  minHeight: 52,
                  child: Text(L10n.text('No Matching Settings'), style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
                ),
              for (final item in found)
                SettingsTileRow(
                  key: Key('settings.result.${item.id}'),
                  title: item.title,
                  subtitle: item.category.title,
                  tile: _tile(item.category),
                  onTap: () => widget.open(item.category),
                ),
            ],
          )
        else ...[
          FormSection(rowColor: row, children: [...widget.top, _pageRow(SettingsCategory.addons)]),
          for (final group in SettingsCategory.groups) ...[
            const SizedBox(height: 28),
            FormSection(rowColor: row, children: [for (final category in group) _pageRow(category)]),
          ],
          if (widget.bottom.isNotEmpty) ...[const SizedBox(height: 28), ...widget.bottom],
        ],
      ],
    );
  }
}
