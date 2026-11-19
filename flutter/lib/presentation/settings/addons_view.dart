import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/addons/addon_models.dart';
import '../../core/addons/addon_store.dart';
import '../../core/booru/booru_store.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../study/study_widgets.dart' show StudySymbols;
import 'settings_page.dart';
import 'settings_rows.dart';

/// The symbol of an add-on kind, as `AddonKind.symbol` names it on iOS.
Widget addonKindSymbol(AddonKind kind, Color color, {double size = 22}) => switch (kind) {
  AddonKind.translations => Icon(CupertinoIcons.chat_bubble_text, size: size, color: color),
  AddonKind.searchTags => Icon(CupertinoIcons.line_horizontal_3_decrease_circle, size: size, color: color),
  AddonKind.challenges => DiceSymbol(size: size, color: color),
  AddonKind.track => Icon(StudySymbols.graduationCap, size: size, color: color),
};

/// `.monospaced()` text: fingerprints and tag lists.
TextStyle _mono(double size, {required Color color}) =>
    TextStyle(fontFamily: 'monospace', fontFamilyFallback: TegnalType.fallback, fontSize: size, color: color);

String _message(Object error) => error is AddonError ? error.errorDescription : '$error';

/// The settings row that leads to the add-ons, in both modes' settings (`AddonsSettingsSection`).
class AddonsSettingsSection extends StatelessWidget {
  const AddonsSettingsSection({super.key, required this.booru, this.rowColor});
  final BooruStore booru;
  final Color? rowColor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AddonRuntime.shared,
    builder: (context, _) {
      final count = AddonRuntime.shared.effects.enabledIDs.length;
      return FormSection(
        prominentHeader: true,
        rowColor: rowColor ?? FormColors.listRow.resolveFrom(context),
        children: [
          SettingsLinkRow(
            title: L10n.text('Add-ons'),
            symbol: (color) => PuzzlePieceSymbol(color: color),
            value: count > 0 ? '$count' : null,
            onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AddonsView(booru: booru))),
          ),
        ],
      );
    },
  );
}

/// Terms that add-ons apply beside the person's own, shown read-only where the person's own are edited.
class AddonAddedTermsSection extends StatelessWidget {
  const AddonAddedTermsSection({super.key, required this.title, required this.terms, required this.openAddons, this.rowColor});
  final String title;
  final List<String> terms;
  final VoidCallback openAddons;
  final Color? rowColor;

  @override
  Widget build(BuildContext context) {
    if (terms.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        settingsSectionGap,
        FormSection(
          rowColor: rowColor ?? FormColors.listRow.resolveFrom(context),
          header: Text(L10n.text(title)),
          footer: Text(L10n.text('Turn the add-on off to stop using these.')),
          children: [
            FormRow(
              child: Text(
                terms.join(terms.any((term) => term.contains(' ')) ? '\n' : '  '),
                style: _mono(13, color: TegnalColors.secondaryLabel.resolveFrom(context)),
              ),
            ),
            SettingsLinkRow(title: L10n.text('Add-ons'), onTap: openAddons),
          ],
        ),
      ],
    );
  }
}

/// A checked add-on waiting for the person to decide.
class _AddonCandidate {
  const _AddonCandidate({required this.addon, required this.digest, required this.existing});
  final Addon addon;
  final String digest;
  final InstalledAddon? existing;
}

/// The add-ons kept, a way to open a file, and what the add-ons are (`AddonsView`).
class AddonsView extends StatefulWidget {
  const AddonsView({super.key, required this.booru});
  final BooruStore booru;

  @override
  State<AddonsView> createState() => _AddonsViewState();
}

class _AddonsViewState extends State<AddonsView> {
  List<InstalledAddon> _installed = [];
  bool _reading = false;
  String? _error;
  AddonStore get _store => AddonStore(widget.booru.database);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    List<InstalledAddon> items;
    try {
      items = _store.installed().reversed.toList();
    } on Object {
      items = const [];
    }
    if (mounted) setState(() => _installed = items);
  }

  Future<void> _open() async {
    setState(() => _reading = true);
    File? file;
    try {
      file = await const DocumentFiles().openDocument();
      if (file != null) {
        final (:addon, :digest) = await Addon.read(file);
        if (!mounted) return;
        _error = null;
        final candidate = _AddonCandidate(addon: addon, digest: digest, existing: _installed.where((item) => item.id == addon.id).firstOrNull);
        setState(() => _reading = false);
        final install = await showAppSheet<bool>(
          context,
          builder: (context, controller) => _AddonInstallSheet(candidate: candidate, controller: controller),
        );
        if (install == true) _install(candidate);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      try {
        await file?.delete();
      } on Object {
        // The copy is only a temporary one.
      }
      if (mounted) setState(() => _reading = false);
    }
  }

  void _install(_AddonCandidate candidate) {
    try {
      _store.install(candidate.addon, digest: candidate.digest);
      _error = null;
      _reload();
      AddonRuntime.applyChanges(widget.booru);
    } on Object catch (error) {
      setState(() => _error = _message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Stack(
      children: [
        SettingsPage(
          title: L10n.text('Add-ons'),
          children: [
            FormSection(
              rowColor: row,
              footer: Text(
                L10n.text(
                  'Add-ons are files made by other people that you download yourself. They hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything a file adds before it is installed.',
                ),
              ),
              children: [
                SettingsLinkRow(
                  title: L10n.text('Open Add-on File'),
                  icon: CupertinoIcons.doc_append,
                  tinted: true,
                  chevron: false,
                  onTap: _reading ? null : _open,
                ),
              ],
            ),
            settingsSectionGap,
            if (_installed.isEmpty)
              FormSection(
                rowColor: row,
                children: [
                  FormRow(
                    minHeight: 200,
                    child: SizedBox(
                      width: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PuzzlePieceSymbol(size: 44, color: secondary),
                          const SizedBox(height: 12),
                          Text(
                            L10n.text('No Add-ons'),
                            style: TegnalType.style(20, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            L10n.text('Open a .tegnaladdon file to add tag translations, search tags, challenges or learning tracks.'),
                            textAlign: TextAlign.center,
                            style: TegnalType.style(15, color: secondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            else
              FormSection(
                rowColor: row,
                header: Text(L10n.text('Installed')),
                footer: Text(L10n.text('Turning an add-on off or removing it takes back everything it added. Your own settings are never changed.')),
                children: [
                  for (final item in _installed)
                    _AddonRow(
                      key: ValueKey(item.id),
                      item: item,
                      onTap: () async {
                        await Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => AddonDetailView(booru: widget.booru, id: item.id, changed: _reload),
                          ),
                        );
                        _reload();
                      },
                    ),
                ],
              ),
            if (_error != null) ...[
              settingsSectionGap,
              FormSection(
                rowColor: row,
                children: [
                  FormRow(
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.exclamationmark_triangle, size: 20, color: SystemColors.red.resolveFrom(context)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(_error!, style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        if (_reading)
          Positioned.fill(
            child: Center(child: CupertinoActivityIndicator(color: tint, radius: 14)),
          ),
      ],
    );
  }
}

class _AddonRow extends StatelessWidget implements FormSeparatorInset {
  const _AddonRow({super.key, required this.item, required this.onTap});
  final InstalledAddon item;
  final VoidCallback onTap;

  @override
  double get separatorInset => 60;

  @override
  Widget build(BuildContext context) {
    final kind = item.addon.contents.kinds.firstOrNull;
    final color = item.enabled ? TegnalColors.tint.resolveFrom(context) : TegnalColors.secondaryLabel.resolveFrom(context);
    return Semantics(
      button: true,
      child: FormRow(
        onTap: onTap,
        separatorInset: separatorInset,
        minHeight: 60,
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Center(child: kind == null ? PuzzlePieceSymbol(size: 24, color: color) : addonKindSymbol(kind, color, size: 24)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.addon.title,
                    style: TegnalType.style(
                      17,
                      weight: FontWeight.w600,
                      color: item.enabled ? TegnalColors.label.resolveFrom(context) : TegnalColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.addon.contents.kinds.map((kind) => kind.title).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                ],
              ),
            ),
            if (!item.enabled) ...[
              const SizedBox(width: 8),
              Text(L10n.text('Off'), style: TegnalType.style(12, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ],
            const SizedBox(width: 6),
            Icon(CupertinoIcons.chevron_right, size: 15, color: TegnalColors.tertiaryLabel.resolveFrom(context)),
          ],
        ),
      ),
    );
  }
}

/// One installed add-on: what it adds, on or off, and the way to remove it (`AddonDetailView`).
class AddonDetailView extends StatefulWidget {
  const AddonDetailView({super.key, required this.booru, required this.id, required this.changed});
  final BooruStore booru;
  final String id;
  final VoidCallback changed;

  @override
  State<AddonDetailView> createState() => _AddonDetailViewState();
}

class _AddonDetailViewState extends State<AddonDetailView> {
  InstalledAddon? _item;
  String? _error;
  AddonStore get _store => AddonStore(widget.booru.database);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    InstalledAddon? item;
    try {
      item = _store.installed().where((item) => item.id == widget.id).firstOrNull;
    } on Object {
      item = null;
    }
    setState(() => _item = item);
  }

  void _setEnabled(bool on) {
    try {
      _store.setEnabled(widget.id, on);
      _load();
      AddonRuntime.applyChanges(widget.booru);
      widget.changed();
    } on Object catch (error) {
      setState(() => _error = _message(error));
    }
  }

  Future<void> _confirmRemove() async {
    final remove = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Remove this add-on?')),
        message: Text(L10n.text('Everything it added is taken away, including the challenges it brought and their progress.')),
        actions: [
          CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Remove Add-on'))),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (remove != true || !mounted) return;
    try {
      _store.remove(widget.id);
      AddonRuntime.applyChanges(widget.booru);
      widget.changed();
      Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _error = _message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final item = _item;
    return SettingsPage(
      title: item?.addon.title ?? L10n.text('Add-ons'),
      children: [
        if (item != null) ...[
          _AddonHeader(addon: item.addon, rowColor: row),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [SettingsToggleRow(title: L10n.text('Use This Add-on'), value: item.enabled, onChanged: _setEnabled)],
          ),
          ..._addonContentsSections(item.addon, context, rowColor: row),
          settingsSectionGap,
          _AddonOriginSection(addon: item.addon, digest: item.digest, installed: item.installed, rowColor: row),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            footer: item.addon.contents.learningTrack == null ? null : Text(L10n.text('Lessons you finished in its track stay in your learning record.')),
            children: [
              SettingsLinkRow(title: L10n.text('Remove Add-on'), icon: CupertinoIcons.trash, destructive: true, chevron: false, onTap: _confirmRemove),
            ],
          ),
          if (_error != null) ...[
            settingsSectionGap,
            FormSection(
              rowColor: row,
              children: [
                FormRow(
                  child: Text(_error!, style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

/// Everything a file adds, shown before it is installed (`AddonInstallSheet`).
class _AddonInstallSheet extends StatelessWidget {
  const _AddonInstallSheet({required this.candidate, required this.controller});
  final _AddonCandidate candidate;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final existing = candidate.existing;
    final addon = candidate.addon;
    Widget? update;
    if (existing != null) {
      final order = AddonCheck.compare(addon.version, existing.addon.version);
      final text = L10n.text(
        order > 0
            ? 'Updates version %@ to %@.'
            : order == 0
            ? 'Replaces the installed version %@ with this copy (%@).'
            : 'This is older than the installed version %@. Installing it goes back to %@.',
        [existing.addon.version, addon.version],
      );
      final color = order < 0 ? SystemColors.orange.resolveFrom(context) : TegnalColors.label.resolveFrom(context);
      update = FormSection(
        children: [
          FormRow(
            child: Row(
              children: [
                Icon(order < 0 ? CupertinoIcons.exclamationmark_triangle : CupertinoIcons.arrow_2_circlepath, size: 22, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(text, style: TegnalType.style(17, color: color)),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ScrollEdgeSheet(
      bar: SheetNavigationBar(
        title: L10n.text('Check Before Installing'),
        leading: GlassTextButton(label: L10n.text('Cancel'), onPressed: () => Navigator.of(context).pop(false)),
        trailing: GlassTextButton(label: L10n.text(existing == null ? 'Install' : 'Update'), prominent: true, onPressed: () => Navigator.of(context).pop(true)),
      ),
      child: ListView(
        controller: controller,
        padding: EdgeInsets.only(top: 76 + 30, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          FormSection(
            children: [
              FormRow(
                child: Row(
                  children: [
                    Icon(CupertinoIcons.checkmark_shield, size: 22, color: SystemColors.green.resolveFrom(context)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        L10n.text(
                          'This add-on was made by someone else. Install it only if you trust where it came from. It holds data only and cannot run code or connect to the internet.',
                        ),
                        style: TegnalType.style(16),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          settingsSectionGap,
          _AddonHeader(addon: addon),
          if (update != null) ...[settingsSectionGap, update],
          ..._addonContentsSections(addon, context),
          settingsSectionGap,
          _AddonOriginSection(addon: addon, digest: candidate.digest, installed: null),
        ],
      ),
    );
  }
}

class _AddonHeader extends StatelessWidget {
  const _AddonHeader({required this.addon, this.rowColor});
  final Addon addon;
  final Color? rowColor;

  @override
  Widget build(BuildContext context) {
    final summary = addon.summary?.addonResolved();
    return FormSection(
      rowColor: rowColor,
      children: [
        FormRow(
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    addon.title,
                    style: TegnalType.style(20, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.text('By %@ · Version %@', [addon.author, addon.version]),
                    style: TegnalType.style(15, color: TegnalColors.secondaryLabel.resolveFrom(context)),
                  ),
                  if (summary != null && summary.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(summary, style: TegnalType.style(16, color: TegnalColors.label.resolveFrom(context))),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddonOriginSection extends StatelessWidget {
  const _AddonOriginSection({required this.addon, required this.digest, required this.installed, this.rowColor});
  final Addon addon;
  final String digest;
  final DateTime? installed;
  final Color? rowColor;

  /// `Date.formatted(date: .abbreviated, time: .shortened)` for the three app languages.
  static String _date(DateTime date) {
    final minute = date.minute.toString().padLeft(2, '0');
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    switch (L10n.language) {
      case 'ko':
        return '${date.year}. ${date.month}. ${date.day}. ${date.hour < 12 ? '오전' : '오후'} $hour12:$minute';
      case 'ja':
        return '${date.year}/${date.month}/${date.day} ${date.hour}:$minute';
      default:
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${months[date.month - 1]} ${date.day}, ${date.year} at $hour12:$minute ${date.hour < 12 ? 'AM' : 'PM'}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final blocks = [for (var offset = 0; offset < digest.length; offset += 8) digest.substring(offset, offset + 8 > digest.length ? digest.length : offset + 8)]
        .join(' ');
    return FormSection(
      rowColor: rowColor,
      header: Text(L10n.text('About This File')),
      footer: Text(L10n.text('If the maker publishes a fingerprint, it should match this one exactly.')),
      children: [
        SettingsValueRow(title: L10n.text('Identifier'), value: addon.id),
        if (installed != null) SettingsValueRow(title: L10n.text('Installed'), value: _date(installed!)),
        FormRow(
          child: SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(L10n.text('File Fingerprint (SHA-256)'), style: TegnalType.style(15)),
                const SizedBox(height: 4),
                Text(blocks, style: _mono(12, color: secondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

const _shownTranslations = 12;
const _shownTerms = 40;

String _languageName(String code) => switch (code) {
  'ko' => '한국어',
  'ja' => '日本語',
  _ => 'English',
};

Widget _kindHeader(AddonKind kind, BuildContext context) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    addonKindSymbol(kind, TegnalColors.secondaryLabel.resolveFrom(context), size: 18),
    const SizedBox(width: 8),
    Flexible(child: Text(kind.title)),
  ],
);

/// Blacklist rules can hold several terms, so they are listed one per line.
Widget _terms(BuildContext context, String title, List<String> list, {String separator = '  '}) {
  if (list.isEmpty) return const SizedBox.shrink();
  return FormRow(
    child: SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TegnalType.style(15, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
            ),
            const SizedBox(height: 4),
            Text(
              list.take(_shownTerms).join(separator) +
                  (list.length > _shownTerms ? separator + L10n.text('and %@ more', ['${list.length - _shownTerms}']) : ''),
              style: _mono(12, color: TegnalColors.secondaryLabel.resolveFrom(context)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// What each part of an add-on adds, with enough of it shown to judge (`AddonContentsSections`).
List<Widget> _addonContentsSections(Addon addon, BuildContext context, {Color? rowColor}) {
  final contents = addon.contents;
  final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
  final sections = <Widget>[];
  if (contents.tagTranslations case final translations?) {
    final entries = translations.entries.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    sections.add(
      FormSection(
        rowColor: rowColor,
        header: _kindHeader(AddonKind.translations, context),
        footer: Text(
          L10n.text('%@ tags, written in %@. Tags are shown in these words in place of their own names; searches still use the tags themselves.', [
            '${entries.length}',
            _languageName(translations.language),
          ]),
        ),
        children: [
          for (final entry in entries.take(_shownTranslations)) SettingsValueRow(title: entry.key.replaceAll('_', ' '), value: entry.value),
          if (entries.length > _shownTranslations)
            FormRow(
              child: Text(L10n.text('and %@ more', ['${entries.length - _shownTranslations}']), style: TegnalType.style(12, color: secondary)),
            ),
        ],
      ),
    );
  }
  if (contents.searchTags case final search?) {
    sections.add(
      FormSection(
        rowColor: rowColor,
        header: _kindHeader(AddonKind.searchTags, context),
        footer: Text(L10n.text('These apply beside your own default tags and blacklists, which stay as they are.')),
        children: [
          if ((search.comicsInclude ?? const []).isNotEmpty) _terms(context, L10n.text('Added to Comics Searches'), search.comicsInclude!),
          if ((search.comicsExclude ?? const []).isNotEmpty) _terms(context, L10n.text('Hidden from Comics Searches'), search.comicsExclude!),
          if ((search.imageExclude ?? const []).isNotEmpty) _terms(context, L10n.text('Hidden Images (All Servers)'), search.imageExclude!, separator: '\n'),
        ],
      ),
    );
  }
  if (contents.challenges case final games?) {
    sections.add(
      FormSection(
        rowColor: rowColor,
        header: _kindHeader(AddonKind.challenges, context),
        footer: Text(L10n.text('Added to your challenge library.')),
        children: [
          for (final game in games)
            FormRow(
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(game.title),
                    const SizedBox(height: 2),
                    Text(
                      L10n.text('%@ choices', [
                        '${[...game.reels, ...game.groups].fold<int>(0, (sum, item) => sum + item.options.length)}',
                      ]),
                      style: TegnalType.style(12, color: secondary),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
  if (contents.learningTrack case final track?) {
    final lessons = track.lessons.length;
    final tags = (track.groups ?? const []).fold<int>(0, (sum, group) => sum + group.tags.length);
    sections.add(
      FormSection(
        rowColor: rowColor,
        header: _kindHeader(AddonKind.track, context),
        footer: Text(
          [
            L10n.text('A track of %@ lessons in learning mode, finished apart from the main path.', ['$lessons']),
            if (tags > 0) L10n.text('It teaches %@ tags of its own.', ['$tags']),
            L10n.text('Its lessons find example pictures on your chosen picture server, as the main path does.'),
          ].join(' '),
        ),
        children: [
          FormRow(
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title.addonResolved(),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                    ),
                    const SizedBox(height: 4),
                    Text(track.summary.addonResolved(), style: TegnalType.style(16, color: secondary)),
                  ],
                ),
              ),
            ),
          ),
          for (final section in track.sections)
            SettingsValueRow(
              title: (section['title']! as Map).cast<String, String>().addonResolved(),
              value: L10n.text('%@ lessons', ['${(section['lessons']! as List).length}']),
            ),
        ],
      ),
    );
  }
  return [
    for (final section in sections) ...[settingsSectionGap, section],
  ];
}
