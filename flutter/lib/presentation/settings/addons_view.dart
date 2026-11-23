import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/addons/addon_market.dart';
import '../../core/addons/addon_models.dart';
import '../../core/addons/addon_store.dart';
import '../../core/booru/booru_store.dart';
import '../../core/downloads/download_store.dart' show FileByteCount;
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// The symbol of an add-on kind, as `AddonKind.symbol` names it on iOS.
Widget addonKindSymbol(AddonKind kind, Color color, {double size = 22}) => switch (kind) {
  AddonKind.translations => Icon(CupertinoIcons.chat_bubble_text, size: size, color: color),
  AddonKind.searchTags => Icon(CupertinoIcons.line_horizontal_3_decrease_circle, size: size, color: color),
  AddonKind.challenges => DiceSymbol(size: size, color: color),
};

/// `.monospaced()` text: fingerprints and tag lists.
TextStyle _mono(double size, {required Color color}) =>
    TextStyle(fontFamily: 'monospace', fontFamilyFallback: TegnalType.fallback, fontSize: size, color: color);

String _message(Object error) => switch (error) {
  AddonError() => error.errorDescription,
  AddonMarketError() => error.errorDescription,
  _ => '$error',
};

/// The small seal shown beside an official add-on's name (`AddonOfficialBadge`).
class AddonOfficialBadge extends StatelessWidget {
  const AddonOfficialBadge({super.key, this.size = 13});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: L10n.text('Official'),
    child: Icon(CupertinoIcons.checkmark_seal_fill, size: size, color: SystemColors.blue.resolveFrom(context)),
  );
}

/// The row that leads to a mode's add-ons, last in the Browsing section of that mode's settings (`AddonsSettingsRow`).
class AddonsSettingsRow extends StatelessWidget implements FormSeparatorInset {
  const AddonsSettingsRow({super.key, required this.booru, required this.mode});
  final BooruStore booru;
  final AddonMode mode;

  @override
  double get separatorInset => settingsIconInset;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AddonRuntime.shared,
    builder: (context, _) {
      final count = AddonRuntime.shared.effects.enabledCount(mode);
      return SettingsLinkRow(
        title: L10n.text('Add-ons'),
        symbol: (color) => PuzzlePieceSymbol(color: color),
        value: count > 0 ? '$count' : null,
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => AddonsView(booru: booru, mode: mode),
          ),
        ),
      );
    },
  );
}

/// Terms that add-ons apply beside the person's own, shown read-only where the person's own are edited.
class AddonAddedTermsSection extends StatelessWidget {
  const AddonAddedTermsSection({super.key, required this.title, required this.terms, required this.mode, required this.openAddons, this.rowColor});
  final String title;
  final List<String> terms;

  /// The mode whose add-ons [openAddons] opens.
  final AddonMode mode;
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
  const _AddonCandidate({required this.addon, required this.digest, required this.existing, this.official = false});
  final Addon addon;
  final String digest;
  final InstalledAddon? existing;

  /// Downloaded from the official add-ons and matched against the signed catalog.
  final bool official;
}

/// One mode's add-ons: the installed ones and a file to open at the top, then TEGNAL's official add-ons by grade (`AddonsView`).
/// Comics and image add-ons never meet: each mode lists, opens and installs only its own.
class AddonsView extends StatefulWidget {
  const AddonsView({super.key, required this.booru, required this.mode, this.market});
  final BooruStore booru;
  final AddonMode mode;

  /// Replaced in tests; the live market otherwise.
  final AddonMarket? market;

  @override
  State<AddonsView> createState() => _AddonsViewState();
}

class _AddonsViewState extends State<AddonsView> {
  List<InstalledAddon> _installed = [];
  AddonCatalog? _catalog;
  bool _reading = false;
  String? _error;
  String? _loadError;
  String? _downloading;
  AddonMode get _mode => widget.mode;
  AddonMarket get _market => widget.market ?? AddonMarket.live;
  AddonStore get _store => AddonStore(widget.booru.database);

  @override
  void initState() {
    super.initState();
    _reload();
    _load();
  }

  void _reload() {
    List<InstalledAddon> items;
    try {
      items = _store.installed().where((item) => item.addon.mode == _mode).toList();
    } on Object {
      items = const [];
    }
    if (mounted) setState(() => _installed = items);
  }

  Future<void> _load() async {
    if (_loadError != null) setState(() => _loadError = null);
    try {
      final catalog = await _market.catalog();
      if (mounted) setState(() => _catalog = catalog);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _catalog == null ? _loadError = _message(error) : _error = _message(error));
    }
  }

  InstalledAddon? _item(String id) => _installed.where((item) => item.id == id).firstOrNull;

  Future<void> _open() async {
    setState(() => _reading = true);
    File? file;
    try {
      file = await const DocumentFiles().openDocument();
      if (file != null) {
        final (:addon, :digest) = await Addon.read(file);
        if (!mounted) return;
        // An add-on for the other mode is opened from that mode's settings, so that it is never mistaken for this one's.
        if (addon.mode != _mode) throw AddonError.otherMode(addon.mode);
        _error = null;
        final candidate = _AddonCandidate(addon: addon, digest: digest, existing: _item(addon.id));
        setState(() => _reading = false);
        await _offer(candidate);
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

  Future<void> _get(AddonListing listing) async {
    setState(() => _downloading = listing.id);
    _AddonCandidate? candidate;
    try {
      final (:addon, :digest) = await _market.download(listing);
      candidate = _AddonCandidate(addon: addon, digest: digest, existing: _item(addon.id), official: true);
      _error = null;
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
    if (candidate == null || !mounted) return;
    await _offer(candidate);
  }

  /// Shows everything the add-on adds, and installs it when the person agrees.
  Future<void> _offer(_AddonCandidate candidate) async {
    final install = await showAppSheet<bool>(
      context,
      builder: (context, controller) => _AddonInstallSheet(candidate: candidate, controller: controller),
    );
    if (install == true && mounted) _install(candidate);
  }

  void _install(_AddonCandidate candidate) {
    try {
      _store.install(candidate.addon, digest: candidate.digest, official: candidate.official);
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
    final tint = TegnalColors.tint.resolveFrom(context);
    return Stack(
      children: [
        SettingsPage(
          title: L10n.text(_mode == AddonMode.comics ? 'Comics Mode Add-ons' : 'Image Mode Add-ons'),
          children: [
            FormSection(
              rowColor: row,
              header: _HelpHeader(
                title: 'My Add-ons',
                help: _mode == AddonMode.comics
                    ? 'These add-ons work in Comics Mode only. Image Mode keeps its own add-ons in its settings. Add-ons hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything one adds before it is installed, and turning one off or removing it takes back everything it added.'
                    : 'These add-ons work in Image Mode only. Comics Mode keeps its own add-ons in its settings. Add-ons hold data only: they cannot run code, connect to the internet, read your library or change your accounts and servers. You see everything one adds before it is installed, and turning one off or removing it takes back everything it added.',
              ),
              children: [
                SettingsLinkRow(
                  title: L10n.text('Installed Add-ons'),
                  icon: CupertinoIcons.checkmark_circle,
                  value: _installed.isEmpty ? null : '${_installed.length}',
                  onTap: () async {
                    await Navigator.of(context).push(
                      CupertinoPageRoute<void>(
                        builder: (_) => AddonInstalledListView(booru: widget.booru, mode: _mode),
                      ),
                    );
                    _reload();
                  },
                ),
                SettingsLinkRow(
                  title: L10n.text('Open Add-on File'),
                  icon: CupertinoIcons.doc_append,
                  tinted: true,
                  chevron: false,
                  onTap: _reading ? null : _open,
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
            ..._officialSections(context, row),
          ],
        ),
        if (_reading)
          Positioned.fill(
            child: Center(child: CupertinoActivityIndicator(color: tint, radius: 14)),
          ),
      ],
    );
  }

  /// The official add-ons of this mode in one list, recommended ones first, each with its grade beside its name, or why they could not be shown.
  List<Widget> _officialSections(BuildContext context, Color row) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final catalog = _catalog;
    final List<Widget> children;
    if (catalog != null) {
      final listings = catalog.addons.where((listing) => listing.mode == _mode).toList();
      final sorted = [
        for (final grade in AddonGrade.values)
          for (final listing in listings)
            if (listing.addonGrade == grade) listing,
      ];
      if (sorted.isEmpty) {
        children = [
          FormRow(
            minHeight: 200,
            child: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.checkmark_seal, size: 44, color: secondary),
                  const SizedBox(height: 12),
                  Text(
                    L10n.text('No Official Add-ons Yet'),
                    textAlign: TextAlign.center,
                    style: TegnalType.style(20, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.text('Official add-ons appear here as TEGNAL publishes them.'),
                    textAlign: TextAlign.center,
                    style: TegnalType.style(15, color: secondary),
                  ),
                ],
              ),
            ),
          ),
        ];
      } else {
        children = [for (final listing in sorted) _listingRow(listing)];
      }
    } else if (_loadError != null) {
      children = [
        FormRow(
          child: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(CupertinoIcons.wifi_exclamationmark, size: 20, color: TegnalColors.label.resolveFrom(context)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        L10n.text('Couldn’t Load Official Add-ons'),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style: TegnalType.style(16, color: secondary),
                ),
                const SizedBox(height: 10),
                CupertinoButton(padding: EdgeInsets.zero, onPressed: _load, child: Text(L10n.text('Try Again'))),
              ],
            ),
          ),
        ),
      ];
    } else {
      children = [
        FormRow(
          child: SizedBox(
            width: double.infinity,
            child: Center(child: CupertinoActivityIndicator(color: TegnalColors.tint.resolveFrom(context))),
          ),
        ),
      ];
    }
    return [
      settingsSectionGap,
      FormSection(
        rowColor: row,
        header: const _HelpHeader(
          title: 'Official Add-ons',
          help: 'Official add-ons are made and checked by TEGNAL. The list and every file are signed, so only the copy TEGNAL published is installed, and you still see everything one adds before it is installed.\n\nRecommended: TEGNAL advises these for almost everyone.\nSuggested: useful for many people.\nOptional: for particular tastes and uses.',
        ),
        children: children,
      ),
    ];
  }

  Widget _listingRow(AddonListing listing) {
    final item = _item(listing.id);
    final state = AddonListingState.of(listing, item);
    if (state == AddonListingState.installed && item != null) {
      return _AddonListingRow(
        key: ValueKey(listing.id),
        listing: listing,
        state: state,
        downloading: false,
        onTap: () async {
          await Navigator.of(context).push(
            CupertinoPageRoute<void>(
              builder: (_) => AddonDetailView(booru: widget.booru, id: item.id, changed: _reload),
            ),
          );
          _reload();
        },
      );
    }
    return _AddonListingRow(
      key: ValueKey(listing.id),
      listing: listing,
      state: state,
      downloading: _downloading == listing.id,
      onTap: state == AddonListingState.unsupported || _downloading != null ? null : () => _get(listing),
    );
  }
}

/// The add-ons of one mode that are installed, newest first (`AddonInstalledListView`).
class AddonInstalledListView extends StatefulWidget {
  const AddonInstalledListView({super.key, required this.booru, required this.mode});
  final BooruStore booru;
  final AddonMode mode;

  @override
  State<AddonInstalledListView> createState() => _AddonInstalledListViewState();
}

class _AddonInstalledListViewState extends State<AddonInstalledListView> {
  List<InstalledAddon> _installed = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    List<InstalledAddon> items;
    try {
      items = AddonStore(widget.booru.database).installed().where((item) => item.addon.mode == widget.mode).toList().reversed.toList();
    } on Object {
      items = const [];
    }
    if (mounted) setState(() => _installed = items);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Installed Add-ons'),
      children: [
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
                        L10n.text('Get an official add-on or open a .tegnaladdon file.'),
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
            header: const _HelpHeader(
              title: 'Installed',
              help: 'Turning an add-on off or removing it takes back everything it added. Your own settings are never changed.',
            ),
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.addon.title,
                          style: TegnalType.style(
                            17,
                            weight: FontWeight.w600,
                            color: item.enabled ? TegnalColors.label.resolveFrom(context) : TegnalColors.secondaryLabel.resolveFrom(context),
                          ),
                        ),
                      ),
                      if (item.official) ...[const SizedBox(width: 4), const AddonOfficialBadge()],
                    ],
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
          _AddonHeader(addon: item.addon, official: item.official, rowColor: row),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [SettingsToggleRow(title: L10n.text('Use This Add-on'), value: item.enabled, onChanged: _setEnabled)],
          ),
          ..._addonContentsSections(item.addon, context, rowColor: row),
          settingsSectionGap,
          _AddonOriginSection(addon: item.addon, digest: item.digest, installed: item.installed, official: item.official, rowColor: row),
          settingsSectionGap,
          FormSection(
            rowColor: row,
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
      final orange = SystemColors.orange.resolveFrom(context);
      update = FormSection(
        children: [
          if (existing.official && !candidate.official)
            FormRow(
              child: Row(
                children: [
                  Icon(CupertinoIcons.exclamationmark_triangle, size: 22, color: orange),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      L10n.text('This file is not the official copy. Installing it replaces the official add-on, which is then no longer marked as official.'),
                      style: TegnalType.style(17, color: orange),
                    ),
                  ),
                ],
              ),
            ),
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
                    if (candidate.official)
                      Icon(CupertinoIcons.checkmark_seal_fill, size: 22, color: SystemColors.blue.resolveFrom(context))
                    else
                      Icon(CupertinoIcons.checkmark_shield, size: 22, color: SystemColors.green.resolveFrom(context)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        L10n.text(
                          candidate.official
                              ? 'An official add-on from TEGNAL. The downloaded file matched the copy TEGNAL published. It holds data only and cannot run code or connect to the internet.'
                              : 'This add-on was made by someone else. Install it only if you trust where it came from. It holds data only and cannot run code or connect to the internet.',
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
          _AddonHeader(addon: addon, official: candidate.official),
          if (update != null) ...[settingsSectionGap, update],
          ..._addonContentsSections(addon, context),
          settingsSectionGap,
          _AddonOriginSection(addon: addon, digest: candidate.digest, installed: null, official: candidate.official),
        ],
      ),
    );
  }
}

class _AddonHeader extends StatelessWidget {
  const _AddonHeader({required this.addon, this.official = false, this.rowColor});
  final Addon addon;
  final bool official;
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          addon.title,
                          style: TegnalType.style(20, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                      ),
                      if (official) ...[const SizedBox(width: 6), const AddonOfficialBadge(size: 15)],
                    ],
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
  const _AddonOriginSection({required this.addon, required this.digest, required this.installed, this.official = false, this.rowColor});
  final Addon addon;
  final String digest;
  final DateTime? installed;
  final bool official;
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
        SettingsValueRow(title: L10n.text('Mode'), value: addon.mode.title),
        SettingsValueRow(title: L10n.text('Source'), value: L10n.text(official ? 'Official Add-ons' : 'Opened File')),
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
  return [
    for (final section in sections) ...[settingsSectionGap, section],
  ];
}

class _AddonListingRow extends StatelessWidget implements FormSeparatorInset {
  const _AddonListingRow({super.key, required this.listing, required this.state, required this.downloading, required this.onTap});
  final AddonListing listing;
  final AddonListingState state;
  final bool downloading;
  final VoidCallback? onTap;

  @override
  double get separatorInset => 60;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final kind = listing.addonKinds.firstOrNull;
    final summary = listing.summary?.addonResolved();
    final Widget status;
    if (downloading) {
      status = CupertinoActivityIndicator(color: tint);
    } else {
      status = switch (state) {
        AddonListingState.installed => Semantics(
          label: L10n.text('Installed'),
          child: Icon(CupertinoIcons.checkmark, size: 18, color: secondary),
        ),
        AddonListingState.unsupported => Text(
          L10n.text('Needs a Newer Version'),
          textAlign: TextAlign.end,
          style: TegnalType.style(12, color: secondary),
        ),
        _ => Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: ShapeDecoration(shape: const StadiumBorder(), color: tint.withValues(alpha: 0.15)),
          child: Text(
            L10n.text(state == AddonListingState.update ? 'Update' : 'Get'),
            style: TegnalType.style(15, weight: FontWeight.w600, color: tint),
          ),
        ),
      };
    }
    return Semantics(
      button: onTap != null,
      child: FormRow(
        onTap: onTap,
        separatorInset: separatorInset,
        minHeight: 60,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Center(child: kind == null ? PuzzlePieceSymbol(size: 24, color: tint) : addonKindSymbol(kind, tint, size: 24)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The badge follows the name on its line, or drops under it; the name is never cut short.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 3,
                      children: [
                        Text(
                          listing.title,
                          style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                        ),
                        AddonGradeBadge(grade: listing.addonGrade),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(L10n.text('By %@ · Version %@', [listing.author, listing.version]), style: TegnalType.style(12, color: secondary)),
                    if (state == AddonListingState.fromFile) ...[
                      const SizedBox(height: 3),
                      Text(L10n.text('Installed from a File'), style: TegnalType.style(12, color: SystemColors.orange.resolveFrom(context))),
                    ],
                    if (summary != null && summary.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(16, color: secondary),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      [...listing.addonKinds.map((kind) => kind.title), FileByteCount.format(listing.size, language: L10n.language)].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TegnalType.style(12, color: secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              status,
            ],
          ),
        ),
      ),
    );
  }
}

/// A section header with its title and an info button that opens the longer explanation (`SettingsHelpLabel`).
class _HelpHeader extends StatelessWidget {
  const _HelpHeader({required this.title, required this.help});
  final String title;
  final String help;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: Text(L10n.text(title))),
      const SizedBox(width: 4),
      FormHelpButton(title: L10n.text(title), message: L10n.text(help)),
    ],
  );
}

/// An official add-on's grade, drawn as a small badge beside its name (`AddonGradeBadge`).
class AddonGradeBadge extends StatelessWidget {
  const AddonGradeBadge({super.key, required this.grade});
  final AddonGrade grade;

  @override
  Widget build(BuildContext context) {
    final color = switch (grade) {
      AddonGrade.recommended => SystemColors.green,
      AddonGrade.suggested => SystemColors.blue,
      AddonGrade.optional => SystemColors.gray,
    }.resolveFrom(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(shape: const StadiumBorder(), color: color.withValues(alpha: 0.18)),
      child: Text(
        grade.title,
        style: TegnalType.style(11, weight: FontWeight.w600, color: color),
      ),
    );
  }
}
