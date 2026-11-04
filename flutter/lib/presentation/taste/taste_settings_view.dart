import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/content/manga_urls.dart';
import '../../core/support/l10n.dart';
import '../../core/taste/taste_models.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/pull_down_menu.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../navigation/app_header.dart';
import '../navigation/root_tab_view.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';
import 'recap/recap_home_view.dart';
import 'taste_context.dart';
import 'taste_dashboard.dart';
import 'taste_presentation.dart';
import 'taste_reports_view.dart';
import '../design/alert_dialog.dart';

/// A pushed taste screen: the inline title over an inset-grouped list. A list whose first
/// section has no header starts 35 pt under the bar.
class TasteListPage extends StatelessWidget {
  const TasteListPage({super.key, required this.title, required this.children, this.trailing, this.headerFirst = false});
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  /// The first section has a header of its own, which brings it up to 10 pt.
  final bool headerFirst;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final top = media.padding.top + rootBarHeight;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            bottom: media.viewInsets.bottom,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(top: top + (headerFirst ? 10 : 35), bottom: media.viewInsets.bottom > 0 ? 16 : tabBarClearance(context)),
              children: children,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: InlineTitleHeader(title: title, trailing: trailing),
          ),
        ],
      ),
    );
  }
}

/// `TasteSettingsView`: the tuner, statistics and recap, recommendation filters, what the
/// analysis leaves out, and deleting the analysis.
class TasteSettingsView extends StatefulWidget {
  const TasteSettingsView({super.key, required this.taste, required this.mode});
  final TasteContext taste;
  final TasteMode mode;

  @override
  State<TasteSettingsView> createState() => _TasteSettingsViewState();
}

class _TasteSettingsViewState extends State<TasteSettingsView> {
  bool _storageDetails = false;

  TasteContext get _taste => widget.taste;
  TasteMode get _mode => widget.mode;

  String get _source {
    if (_mode == TasteMode.comics) return MangaUrls.source;
    final store = _taste.booru.store;
    return (store.selectedServer ?? store.servers.firstOrNull)?.canonicalAddress ?? '';
  }

  List<String> get _sources =>
      _mode == TasteMode.comics ? [MangaUrls.source] : [for (final server in _taste.booru.store.selectedServers) server.canonicalAddress];

  @override
  void initState() {
    super.initState();
    _taste.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _taste.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _push(WidgetBuilder builder) => Navigator.of(context).push(CupertinoPageRoute<void>(builder: builder));

  Future<void> _setEnabled(bool enabled) async {
    if (enabled) return _taste.controller.change((control) => control.enabled = true);
    final off = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Turn off taste analysis?')),
        content: Text(
          L10n.text(
            'New taste evidence, recommendations and reports will pause. Existing analysis and saved works are kept. Your other devices apply this choice after syncing.',
          ),
        ),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Keep Enabled'))),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Turn Off'))),
        ],
      ),
    );
    if (off == true) _taste.controller.change((control) => control.enabled = false);
  }

  Future<void> _confirmReset() async {
    final reset = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Delete all analysis data?')),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('Delete all analysis data')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (reset == true) {
      _taste.controller.reset();
      await _taste.controller.synchronize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final control = _taste.controller.control;
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final feed = _mode == TasteMode.booru ? _taste.controller.feed(_mode, sources: _sources) : _taste.controller.feed(_mode);
    Widget section({String? header, Widget? footer, required List<Widget> children}) =>
        FormSection(prominentHeader: true, rowColor: row, header: header == null ? null : Text(header), footer: footer, children: children);
    return TasteListPage(
      title: L10n.text('Taste Analysis Settings'),
      children: [
        section(
          children: [
            SettingsLinkRow(
              title: L10n.text('Tune your taste'),
              icon: CupertinoIcons.dial,
              onTap: () => _push((_) => TasteTunerView(taste: _taste, mode: _mode, feed: feed, source: _source)),
            ),
          ],
        ),
        // Sections without a header sit 35 pt apart in an inset-grouped list.
        const SizedBox(height: 35),
        section(
          children: [
            SettingsLinkRow(
              title: L10n.text('Weekly statistics'),
              symbol: (color) => BarChartAxisSymbol(color: color),
              onTap: () => _push((_) => TasteReportsView(taste: _taste, mode: _mode, period: TastePeriod.week)),
            ),
            SettingsLinkRow(
              title: L10n.text('Recap'),
              symbol: (color) => BookPagesSymbol(color: color),
              onTap: () => _push((_) => RecapHomeView(taste: _taste, mode: _mode)),
            ),
          ],
        ),
        settingsSectionGap,
        section(
          header: L10n.text('Smart Recommendations'),
          children: [
            SettingsLinkRow(
              title: L10n.text('Recommendation filters'),
              icon: CupertinoIcons.line_horizontal_3_decrease,
              onTap: () => _push((_) => RecommendationSettingsView(taste: _taste, mode: _mode, initialSource: _source)),
            ),
          ],
        ),
        settingsSectionGap,
        section(
          header: L10n.text('Taste Analysis'),
          children: [
            SettingsToggleRow(
              title: L10n.text('Taste Analysis'),
              help: L10n.text(
                'Uses the works you view and save to find recommendations and build your statistics. Turn off to pause new analysis without deleting your library.',
              ),
              value: control.enabled,
              onChanged: _setEnabled,
            ),
            SettingsLinkRow(
              title: L10n.text('Analysis excluded tags'),
              value: '${control.analysisExcludedFor(_mode, source: _source).length}',
              onTap: () => _push((_) => TasteAnalysisExclusionsView(taste: _taste, mode: _mode, source: _source)),
            ),
            SettingsLinkRow(
              title: L10n.text('Excluded taste tags'),
              value: '${control.excluded.length}',
              onTap: control.excluded.isEmpty ? null : () => _push((_) => _ExcludedTasteTagsPage(taste: _taste)),
            ),
          ],
        ),
        settingsSectionGap,
        section(
          children: [
            // Analysis sync rides on the library's Google Drive sync, which is not offered yet.
            SettingsToggleRow(title: L10n.text('Google Drive Sync'), value: false, onChanged: null),
            FormRow(
              child: Text(
                L10n.text('Google Drive backup is coming soon. For now, back up manually to a local file in Library Management.'),
                style: TegnalType.style(13, color: secondary),
              ),
            ),
            FormRow(
              onTap: () => setState(() => _storageDetails = !_storageDetails),
              child: Row(
                children: [
                  Expanded(child: Text(L10n.text('Storage details'))),
                  AnimatedRotation(
                    turns: _storageDetails ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tint.resolveFrom(context)),
                  ),
                ],
              ),
            ),
            if (_storageDetails) ...[
              SettingsValueRow(title: L10n.text('Analysis time zone'), value: control.timeZone),
              SettingsValueRow(title: L10n.text('Retention'), value: L10n.text('Until you delete it')),
            ],
          ],
        ),
        settingsSectionGap,
        section(
          children: [
            SettingsLinkRow(
              title: L10n.text('Delete all analysis data'),
              help: L10n.text(
                'Deletes viewing activity, taste evidence and reports. Saved works stay in your library. Existing works will not be analyzed again automatically.',
              ),
              destructive: true,
              chevron: false,
              onTap: _confirmReset,
            ),
            if (_taste.controller.error case final error?)
              FormRow(
                child: Text(error, style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
              ),
          ],
        ),
      ],
    );
  }
}

/// The taste tags a person excluded from recommendations, each with a way back.
class _ExcludedTasteTagsPage extends StatelessWidget {
  const _ExcludedTasteTagsPage({required this.taste});
  final TasteContext taste;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: taste.controller,
    builder: (context, _) {
      final keys = taste.controller.control.excluded.toList()..sort();
      final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
      return TasteListPage(
        title: L10n.text('Excluded taste tags'),
        children: [
          FormSection(
            rowColor: FormColors.listRow.resolveFrom(context),
            children: [
              for (final key in keys)
                FormRow(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          TastePresentation.name(key.split('\n').last),
                          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                        const SizedBox(height: 4),
                        Text(TastePresentation.host(key.split('\n').first), style: TegnalType.style(12, color: secondary)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => taste.controller.change((control) => control.excluded.remove(key)),
                          child: Text(L10n.text('Include in recommendations'), style: TegnalType.style(15, color: TegnalColors.tint.resolveFrom(context))),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// `BrowseFilterMenu` in its icon-only form: a 40 pt circle that opens a picker.
class _FilterButton<T> extends StatelessWidget {
  const _FilterButton({
    required this.title,
    required this.icon,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.iconOnly = false,
  });
  final String title;
  final IconData icon;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final accent = TastePresentation.accent(context);
    // `.quaternary` under the tinted menu reads as the accent at 9%.
    final fill = accent.withValues(alpha: 0.09);
    return Semantics(
      button: true,
      label: title,
      child: Builder(
        builder: (buttonContext) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () async {
            final value = await showPullDownMenu<T>(
              buttonContext,
              anchor: anchorRectOf(buttonContext),
              items: [for (final (value, label) in options) PullDownMenuItem(value: value, title: label, checked: value == selected)],
            );
            if (value != null) onSelected(value);
          },
          child: iconOnly
              ? Container(
                  width: 40,
                  height: 40,
                  decoration: ShapeDecoration(color: fill, shape: const CircleBorder()),
                  child: Icon(icon, size: 17, color: accent),
                )
              : Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 17, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        title,
                        style: TegnalType.style(15, weight: FontWeight.w500, color: accent),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// `RecommendationFilters`: the comics language and the sort for one source.
class RecommendationFilters extends StatelessWidget {
  const RecommendationFilters({super.key, required this.taste, required this.mode, required this.source, this.onChange, this.compact = false});
  final TasteContext taste;
  final TasteMode mode;
  final String source;
  final VoidCallback? onChange;

  /// Sits beside a section title, which already says what these controls are.
  final bool compact;

  static String _capitalized(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  void _update(void Function(RecommendationPreferences value) edit) {
    final value = taste.controller.control.preferences(source);
    edit(value);
    taste.controller.change((control) => control.setPreferences(value, source));
    onChange?.call();
  }

  @override
  Widget build(BuildContext context) {
    final preferences = taste.controller.control.preferences(source);
    final engine = taste.booru.store.servers.where((server) => server.canonicalAddress == source).firstOrNull?.engine;
    return Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (mode == TasteMode.comics) ...[
          _FilterButton<String>(
            title: L10n.text(_capitalized(preferences.language)),
            icon: CupertinoIcons.globe,
            iconOnly: compact,
            options: [
              for (final language in const ['all', 'korean', 'japanese', 'english']) (language, L10n.text(_capitalized(language))),
            ],
            selected: preferences.language,
            onSelected: (language) => _update((value) => value.language = language),
          ),
          const SizedBox(width: 8),
        ] else if (!compact)
          Row(
            children: [
              Icon(CupertinoIcons.line_horizontal_3_decrease, size: 17, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              const SizedBox(width: 6),
              Text(L10n.text('Recommendation filters'), style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ],
          ),
        if (!compact) const Spacer(),
        _FilterButton<RecommendationSort>(
          title: preferences.sort.titleFor(mode),
          icon: CupertinoIcons.arrow_up_arrow_down,
          iconOnly: compact,
          options: [for (final sort in RecommendationSort.options(mode, engine: engine)) (sort, sort.titleFor(mode))],
          selected: preferences.sort,
          onSelected: (sort) => _update((value) => value.sort = sort),
        ),
      ],
    );
  }
}

/// `RecommendationSettingsView`: one source's filters and its default included tags.
class RecommendationSettingsView extends StatefulWidget {
  const RecommendationSettingsView({super.key, required this.taste, required this.mode, required this.initialSource});
  final TasteContext taste;
  final TasteMode mode;
  final String initialSource;

  @override
  State<RecommendationSettingsView> createState() => _RecommendationSettingsViewState();
}

class _RecommendationSettingsViewState extends State<RecommendationSettingsView> {
  final _input = TextEditingController();
  String _selected = '';

  TasteContext get _taste => widget.taste;

  String get _source {
    if (widget.mode == TasteMode.comics) return MangaUrls.source;
    final target = _selected.isEmpty ? widget.initialSource : _selected;
    final servers = _taste.booru.store.servers;
    return (servers.where((server) => server.canonicalAddress == target).firstOrNull ?? servers.firstOrNull)?.canonicalAddress ?? '';
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _taste.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _taste.controller.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _add() {
    final source = _source;
    final tag = TasteTagPolicy.normalize(_input.text);
    final preferences = _taste.controller.control.preferences(source);
    if (source.isEmpty || tag.isEmpty || tag.startsWith('-') || preferences.includedTags.contains(tag)) return;
    preferences.includedTags.add(tag);
    _taste.controller.change((control) => control.setPreferences(preferences, source));
    _input.clear();
  }

  void _remove(String tag) {
    final source = _source;
    final preferences = _taste.controller.control.preferences(source)..includedTags.remove(tag);
    _taste.controller.change((control) => control.setPreferences(preferences, source));
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final row = FormColors.listRow.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final preferences = _taste.controller.control.preferences(source);
    final servers = _taste.booru.store.servers;
    return TasteListPage(
      title: L10n.text('Recommendation filters'),
      children: [
        IgnorePointer(
          ignoring: source.isEmpty,
          child: Opacity(
            opacity: source.isEmpty ? 0.4 : 1,
            child: Column(
              children: [
                FormSection(
                  rowColor: row,
                  children: [
                    if (widget.mode == TasteMode.booru)
                      SettingsPickerRow<String>(
                        title: L10n.text('Server'),
                        options: [for (final server in servers) (server.canonicalAddress, server.displayName)],
                        selected: source,
                        onSelected: (value) => setState(() => _selected = value),
                      ),
                  ],
                ),
                if (widget.mode == TasteMode.booru) settingsSectionGap,
                FormSection(
                  rowColor: row,
                  children: [
                    FormRow(
                      child: RecommendationFilters(taste: _taste, mode: widget.mode, source: source),
                    ),
                  ],
                ),
                settingsSectionGap,
                FormSection(
                  rowColor: row,
                  header: SettingsTitle(
                    L10n.text('Default included tags'),
                    help: L10n.text(
                      'Applies these tags to recommendations from this website only. All tags must match. Refresh recommendations after changing the filters.',
                    ),
                  ),
                  children: [
                    FormRow(
                      child: Row(
                        children: [
                          Expanded(
                            child: CupertinoTextField.borderless(
                              controller: _input,
                              padding: EdgeInsets.zero,
                              autocorrect: false,
                              enableSuggestions: false,
                              placeholder: L10n.text('Default included tag'),
                              placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                              style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                              onSubmitted: (_) => _add(),
                            ),
                          ),
                          GestureDetector(
                            onTap: _input.text.trim().isEmpty ? null : _add,
                            child: SizedBox(
                              width: 44,
                              height: 44,
                              child: Icon(CupertinoIcons.plus_circle_fill, size: 24, color: _input.text.trim().isEmpty ? tint.withValues(alpha: 0.4) : tint),
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (final tag in preferences.includedTags)
                      Dismissible(
                        key: ValueKey(tag),
                        direction: DismissDirection.endToStart,
                        onDismissed: (_) => _remove(tag),
                        background: Container(
                          color: SystemColors.red.resolveFrom(context),
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: Text(L10n.text('Delete'), style: TegnalType.style(17, color: const Color(0xFFFFFFFF))),
                        ),
                        child: FormRow(child: Text(tag)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// `TasteAnalysisExclusionsView`: tags the analysis leaves out, per mode and server.
class TasteAnalysisExclusionsView extends StatefulWidget {
  const TasteAnalysisExclusionsView({super.key, required this.taste, required this.mode, this.source = ''});
  final TasteContext taste;
  final TasteMode mode;
  final String source;

  @override
  State<TasteAnalysisExclusionsView> createState() => _TasteAnalysisExclusionsViewState();
}

class _TasteAnalysisExclusionsViewState extends State<TasteAnalysisExclusionsView> {
  late TasteMode _mode = widget.mode;
  late String _selected = widget.source;
  final _input = TextEditingController();

  TasteContext get _taste => widget.taste;

  String get _source {
    if (_mode == TasteMode.comics) return MangaUrls.source;
    final store = _taste.booru.store;
    return (store.servers.where((server) => server.canonicalAddress == _selected).firstOrNull ?? store.selectedServer ?? store.servers.firstOrNull)
            ?.canonicalAddress ??
        '';
  }

  List<String> get _tags => _taste.controller.control.analysisExcludedFor(_mode, source: _source).toList()..sort();

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _taste.controller.addListener(_changed);
  }

  @override
  void dispose() {
    _taste.controller.removeListener(_changed);
    _input.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _add() {
    final value = TasteControl.normalizeExclusion(_input.text);
    final source = _source;
    if (source.isEmpty || value.isEmpty) return;
    final tags = {..._tags, value};
    _taste.controller.change((control) => control.setAnalysisExcluded(tags, _mode, source: source));
    _input.clear();
  }

  void _remove(String tag) {
    final tags = {..._tags}..remove(tag);
    final source = _source;
    _taste.controller.change((control) => control.setAnalysisExcluded(tags, _mode, source: source));
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final source = _source;
    final servers = _taste.booru.store.servers;
    final canAdd = TasteControl.normalizeExclusion(_input.text).isNotEmpty;
    return TasteListPage(
      title: L10n.text('Analysis excluded tags'),
      children: [
        FormSection(
          rowColor: row,
          children: [
            FormRow(
              child: TegnalSegmented<TasteMode>(
                options: [(TasteMode.booru, L10n.text('Images')), (TasteMode.comics, L10n.text('Comics'))],
                selected: _mode,
                onSelected: (mode) => setState(() => _mode = mode),
              ),
            ),
            if (_mode == TasteMode.booru)
              SettingsPickerRow<String>(
                title: L10n.text('Server'),
                options: [for (final server in servers) (server.canonicalAddress, server.displayName)],
                selected: source,
                onSelected: (value) => setState(() => _selected = value),
              ),
          ],
        ),
        settingsSectionGap,
        IgnorePointer(
          ignoring: source.isEmpty,
          child: FormSection(
            rowColor: row,
            footer: Text(
              L10n.text(
                'Excluded tags are removed from taste evidence immediately. Your current works stay in place; refresh to find new recommendations. Original tags and search filters stay available.',
              ),
            ),
            children: [
              FormRow(
                child: Row(
                  children: [
                    Expanded(
                      child: CupertinoTextField.borderless(
                        controller: _input,
                        padding: EdgeInsets.zero,
                        autocorrect: false,
                        enableSuggestions: false,
                        placeholder: L10n.text('Tag to exclude'),
                        placeholderStyle: TegnalType.style(17, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                        style: TegnalType.style(17, color: TegnalColors.label.resolveFrom(context)),
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: L10n.text('Add tag'),
                      child: GestureDetector(
                        onTap: canAdd ? _add : null,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(CupertinoIcons.plus_circle_fill, size: 26, color: canAdd ? tint : tint.withValues(alpha: 0.4)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (final tag in _tags)
                FormRow(
                  child: Row(
                    children: [
                      Expanded(child: Text(tag)),
                      Semantics(
                        button: true,
                        label: '${L10n.text('Remove')} $tag',
                        child: GestureDetector(
                          onTap: () => _remove(tag),
                          child: SizedBox(width: 44, height: 44, child: Icon(CupertinoIcons.minus_circle, size: 22, color: tint)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
