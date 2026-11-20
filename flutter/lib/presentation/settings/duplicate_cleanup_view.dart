import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_account.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/manga_urls.dart';
import '../../core/content/site_favorites_sync.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/duplicate_cleanup.dart';
import '../../core/storage/folder_rules.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../design/alert_dialog.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import '../library/folder_order_view.dart';
import '../library/local_thumbnail.dart';
import '../navigation/root_tab_view.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// `DuplicateCleanupView`: finds duplicate works (or images) in the whole library and removes the
/// extra copies in one go, keeping the copy the chosen rules prefer; any group can be skipped or
/// given another keeper.
class DuplicateCleanupView extends StatefulWidget {
  const DuplicateCleanupView({super.key, required this.database, required this.images, this.booru = false});
  final AppDatabase database;
  final BooruStore images;
  final bool booru;

  @override
  State<DuplicateCleanupView> createState() => _DuplicateCleanupViewState();
}

class _DuplicateCleanupViewState extends State<DuplicateCleanupView> {
  late DuplicateCleanupOptions _options = DuplicateCleanupOptions.load(ContentPreferences.defaults, images: widget.booru);
  List<Work> _works = [];
  List<FavoriteRecord> _records = [];
  List<({String key, String name})> _folders = [];

  /// Folders a website's or server's favorites are kept in step with.
  Set<String> _websiteFolders = {};
  List<DuplicateGroup> _groups = [];

  /// When each saved work went into each of its folders.
  Map<int, Map<int, String>> _addedAt = {};

  /// Smart folders, left as they are when a work in several folders is tidied.
  Set<String> _smartFolders = {};
  final _keepers = <String, String>{};
  final _skipped = <String>{};
  bool _loaded = false;
  bool _busy = false;
  DuplicateUndo? _undo;
  String? _message;

  SiteFavoriteFolders? get _sites => SiteFavoritesSync.shared?.store;
  BooruAccountSync? get _accounts => BooruAccountSync.shared;

  List<DuplicateGroup> get _chosenGroups => [
    for (final group in _groups)
      if (!_skipped.contains(group.id))
        if (_keepers[group.id] case final keeper? when group.copies.any((copy) => copy.id == keeper)) group.keeping(keeper) else group,
  ];

  /// One work in several folders: nothing leaves the library, a work only leaves extra folders.
  bool get _byNumber => !widget.booru && _options.match == DuplicateMatch.sameNumber;
  int get _removalCount => _chosenGroups.fold(0, (sum, group) => sum + group.removals.length);
  List<String> get _languages => {for (final work in _works) ?work.language?.toLowerCase()}.where((language) => language.isNotEmpty).toList()..sort();
  Map<String, String> get _folderNames => {for (final folder in _folders) folder.key: folder.name};
  bool get _hasWebsiteFavorites =>
      widget.booru ? widget.images.servers.any((server) => _accounts?.state(server) != null) : (_sites?.syncedSites.isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _setOptions(DuplicateCleanupOptions options) {
    _options = options;
    options.save(ContentPreferences.defaults, images: widget.booru);
    setState(_regroup);
  }

  void _load() {
    final database = widget.database, images = widget.images;
    if (widget.booru) {
      _records = images.favoriteRecords();
      final all = images.folders();
      final synced = {
        for (final folder in all)
          if (_accounts?.isListFolder(folder.id) ?? false) folder.id,
      };
      _websiteFolders = synced;
      // The person's own folders first, then folders a server keeps, then uncategorized ones.
      final ordered = [
        ...all.where((folder) => !folder.isUncategorized && !synced.contains(folder.id)),
        ...all.where((folder) => synced.contains(folder.id)),
        ...all.where((folder) => folder.isUncategorized),
      ];
      _folders = [for (final folder in ordered) (key: folder.id, name: folder.displayName)];
    } else {
      _works = database.listWorks();
      _addedAt = DuplicateCleaner.folderTimes(database);
      final all = database.listFolders();
      _smartFolders = {
        for (final folder in all)
          if (folder.isSmart && folder.id != null) '${folder.id}',
      };
      final synced = <String>{};
      final sites = _sites;
      if (sites != null) {
        for (final site in sites.syncedSites) {
          for (final identity in sites.state(site)?.folders.values ?? const <String>[]) {
            if (database.folderIDForIdentity(identity) case final id?) synced.add('$id');
          }
        }
      }
      _websiteFolders = synced;
      final unfiled = database.unfiledFolderID();
      final ordered = [
        ...all.where((folder) => folder.id != unfiled && !synced.contains('${folder.id}')),
        ...all.where((folder) => synced.contains('${folder.id}')),
        ...all.where((folder) => folder.id == unfiled),
      ];
      _folders = [
        for (final folder in ordered)
          if (folder.id case final id?) (key: '$id', name: folder.displayName),
      ];
    }
    setState(() {
      _regroup();
      _loaded = true;
    });
  }

  void _regroup() {
    final rank = DuplicateFinder.rank(order: _options.folderOrder, standard: [for (final folder in _folders) folder.key]);
    if (widget.booru) {
      final names = {for (final server in widget.images.servers) server.id: server.displayName};
      _groups = DuplicateFinder.images(_records, serverNames: names, folderRank: rank, options: _options);
    } else {
      final keys = {for (final folder in _folders) ?int.tryParse(folder.key): folder.key};
      _groups = _options.match == DuplicateMatch.sameNumber
          ? DuplicateFinder.placements(
              _works,
              addedAt: _addedAt,
              folderKeys: keys,
              folderNames: _folderNames,
              folderRank: rank,
              fixed: {..._websiteFolders, ..._smartFolders},
              options: _options,
            )
          : DuplicateFinder.comics(_works, folderKeys: keys, folderRank: rank, options: _options);
    }
    // A keeper chosen by hand stays chosen while its group is still found.
    final ids = {for (final group in _groups) group.id};
    _keepers.removeWhere((key, _) => !ids.contains(key));
    _skipped.retainWhere(ids.contains);
  }

  Future<void> _confirm() async {
    final groups = _chosenGroups.length;
    final parts = _byNumber
        ? [
            L10n.text('Each work stays in one folder and leaves %@ others. No work leaves the library.', ['$_removalCount']),
          ]
        : [
            L10n.text('%@ copies leave the library; one copy of each stays.', ['$_removalCount']),
            if (_hasWebsiteFavorites)
              L10n.text(_options.removeFromWebsite ? 'Copies that are website favorites leave the website too.' : 'Website favorites stay as they are.'),
          ];
    final apply = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(_byNumber ? L10n.text('Tidy %@ Works?', ['$groups']) : L10n.text('Clean Up %@ Copies?', ['$_removalCount'])),
        message: Text(parts.join(' ')),
        actions: [
          Semantics(
            identifier: 'duplicates.confirm',
            child: CupertinoActionSheetAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Clean Up'))),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (apply == true) _apply();
  }

  void _apply() {
    setState(() => _busy = true);
    try {
      final groups = _chosenGroups;
      if (widget.booru) {
        _undo = DuplicateCleaner.applyImages(
          groups,
          records: _records,
          removeFromWebsite: _options.removeFromWebsite,
          store: widget.images,
          accounts: _accounts,
        );
      } else {
        final everywhere = _options.removeFromWebsite;
        _undo = DuplicateCleaner.applyComics(
          groups,
          combine: _options.combine,
          removeFromWebsite: everywhere,
          // Folders kept in step with a website are only brought along when the website may change.
          websiteFolders: everywhere ? const {} : {for (final key in _websiteFolders) ?int.tryParse(key)},
          database: widget.database,
          sites: _sites,
        );
      }
      _message = null;
      _keepers.clear();
      _skipped.clear();
    } on Object catch (error) {
      _showError('$error');
    }
    _busy = false;
    _load();
  }

  void _revert(DuplicateUndo undo) {
    try {
      DuplicateCleaner.undo(undo, database: widget.database, images: widget.images, accounts: _accounts, sites: _sites);
      _undo = null;
      _message = L10n.text('The cleanup was undone.');
    } on Object catch (error) {
      _showError('$error');
    }
    _load();
  }

  void _showError(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Unable to Save')),
      content: Text(message),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
    ),
  );

  void _openFolderPriority() => Navigator.of(context).push(
    CupertinoPageRoute<void>(
      builder: (_) => _DuplicateFolderPriorityView(options: _options, folders: _folders, changed: _setOptions),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final booru = widget.booru;
    final chosenGroups = _chosenGroups;
    final byNumber = _byNumber;
    Widget section({String? header, Widget? footer, required List<Widget> children}) =>
        FormSection(prominentHeader: true, rowColor: row, header: header == null ? null : Text(header), footer: footer, children: children);
    final page = SettingsPage(
      title: L10n.text('Clean Up Duplicates'),
      children: [
        section(
          footer: Text(
            L10n.text(
              booru
                  ? 'Images with the same original file are duplicates. Tap a copy to keep it instead, or skip a group. Undo is available right after cleaning up.'
                  : byNumber
                  ? 'A work saved in more than one folder stays in one of them; no work leaves the library. Tap a folder to keep the work there instead, or skip it. Folders kept with website favorites and smart folders are left as they are.'
                  : 'Tap a copy to keep it instead, or skip a group. Undo is available right after cleaning up. A backup in Settings keeps everything safe for longer.',
            ),
          ),
          children: [
            FormRow(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      identifier: 'duplicates.summary',
                      child: Text(
                        byNumber
                            ? L10n.text('%@ works in several folders · %@ folders to leave', ['${chosenGroups.length}', '$_removalCount'])
                            : L10n.text('%@ duplicate groups · %@ copies to remove', ['${chosenGroups.length}', '$_removalCount']),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (!booru) ...[
          settingsSectionGap,
          section(
            header: L10n.text('Find Duplicates'),
            children: [
              SettingsPickerRow<DuplicateMatch>(
                title: L10n.text('Same Work When'),
                options: [for (final value in DuplicateMatch.values) (value, L10n.text(value.title))],
                selected: _options.match,
                onSelected: (value) => _setOptions(_options.copyWith(match: value)),
              ),
              if (_options.match == DuplicateMatch.sameTitle)
                SettingsToggleRow(
                  title: L10n.text('Count Translations as Duplicates'),
                  help: L10n.text(
                    'Works with the same title and artist in different languages count as one work, so only one language stays. Use Preferred Language to choose which.',
                  ),
                  value: _options.acrossLanguages,
                  onChanged: (value) => _setOptions(_options.copyWith(acrossLanguages: value)),
                ),
            ],
          ),
        ],
        settingsSectionGap,
        section(
          header: L10n.text('Which Copy Stays'),
          footer: Text(
            L10n.text(
              booru || byNumber
                  ? 'A copy in a folder higher in Folder Priority stays first; then the rule above decides.'
                  : 'A copy in a folder higher in Folder Priority stays first, then one in the preferred language; then the rule above decides.',
            ),
          ),
          children: [
            SettingsLinkRow(title: L10n.text('Folder Priority'), value: L10n.text(_options.useFolderOrder ? 'On' : 'Off'), onTap: _openFolderPriority),
            if (!booru && !byNumber)
              SettingsPickerRow<String>(
                title: L10n.text('Preferred Language'),
                options: [
                  ('', L10n.text('Any Language')),
                  for (final language in {..._languages, if (_options.preferredLanguage.isNotEmpty) _options.preferredLanguage})
                    (language, L10n.text(libraryLanguageTitle(language))),
                ],
                selected: _options.preferredLanguage,
                onSelected: (value) => _setOptions(_options.copyWith(preferredLanguage: value)),
              ),
            SettingsPickerRow<DuplicateKeep>(
              title: L10n.text('Then Keep'),
              options: [for (final value in DuplicateKeep.choices(images: booru, match: _options.match)) (value, L10n.text(value.title))],
              selected: _options.keepFor(images: booru),
              onSelected: (value) => _setOptions(_options.copyWith(keep: value)),
            ),
          ],
        ),
        if (!byNumber && (!booru || _hasWebsiteFavorites)) ...[
          settingsSectionGap,
          section(
            header: L10n.text('Removed Copies'),
            children: [
              if (!booru)
                SettingsToggleRow(
                  title: L10n.text('Bring Folders and Notes Along'),
                  value: _options.combine,
                  onChanged: (value) => _setOptions(_options.copyWith(combine: value)),
                ),
              if (_hasWebsiteFavorites)
                SettingsToggleRow(
                  title: L10n.text('Remove from Website Favorites Too'),
                  help: L10n.text(
                    "Off, removed copies stay in your favorites on the website and the sync leaves them alone. On, they leave the website's favorites as well.",
                  ),
                  value: _options.removeFromWebsite,
                  onChanged: (value) => _setOptions(_options.copyWith(removeFromWebsite: value)),
                ),
            ],
          ),
        ],
        if (_message != null) ...[
          settingsSectionGap,
          section(
            children: [
              FormRow(
                child: Text(_message!, style: TegnalType.style(17, color: secondary)),
              ),
            ],
          ),
        ],
        if (_loaded && _groups.isEmpty) ...[
          settingsSectionGap,
          section(
            children: [
              FormRow(
                child: Text(
                  L10n.text(
                    booru
                        ? 'No Duplicate Images'
                        : byNumber
                        ? 'No Works in Several Folders'
                        : 'No Duplicate Works',
                  ),
                  style: TegnalType.style(17, color: secondary),
                ),
              ),
            ],
          ),
        ],
        for (final group in _groups) ...[settingsSectionGap, _groupSection(group, row)],
        // Room for the clean-up bar.
        SizedBox(height: _undo == null ? 76 : 128),
      ],
    );
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(absorbing: _busy, child: page),
        ),
        Positioned(left: 0, right: 0, bottom: tabBarClearance(context) - 8, child: _applyBar(context)),
      ],
    );
  }

  Widget _groupSection(DuplicateGroup group, Color row) {
    final skipped = _skipped.contains(group.id);
    final keeper = _keepers[group.id] ?? group.keeperID;
    final tint = TegnalColors.tint.resolveFrom(context);
    return FormSection(
      prominentHeader: true,
      rowColor: row,
      header: Row(
        children: [
          Expanded(child: Text(group.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Semantics(
            identifier: 'duplicates.skip.${([for (final copy in group.copies) copy.id]..sort()).join('-')}',
            button: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => skipped ? _skipped.remove(group.id) : _skipped.add(group.id)),
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  L10n.text(skipped ? 'Include' : 'Skip'),
                  style: TegnalType.style(13, weight: FontWeight.w600, color: tint),
                ),
              ),
            ),
          ),
        ],
      ),
      children: [
        for (final copy in group.copies)
          _DuplicateCopyRow(
            copy: copy,
            keeps: copy.id == keeper,
            skipped: skipped,
            images: widget.booru,
            placement: group.workNumber != null,
            folderNames: [for (final key in copy.folders) ?_folderNames[key]],
            choose: () => setState(() {
              _keepers[group.id] = copy.id;
              _skipped.remove(group.id);
            }),
          ),
      ],
    );
  }

  Widget _applyBar(BuildContext context) {
    final total = _removalCount;
    final enabled = total > 0 && !_busy;
    final tint = TegnalColors.tint.resolveFrom(context);
    final undo = _undo;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (undo != null)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.only(left: 16, right: 6, top: 6, bottom: 6),
              decoration: ShapeDecoration(color: FormColors.row.resolveFrom(context), shape: const StadiumBorder()),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      undo.removedCount > 0 ? L10n.text('Removed %@ copies', ['${undo.removedCount}']) : L10n.text('Tidied %@ works', ['${undo.tidiedCount}']),
                      style: TegnalType.style(15),
                    ),
                  ),
                  Semantics(
                    identifier: 'duplicates.undo',
                    button: true,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      minimumSize: const Size(0, 36),
                      onPressed: () => _revert(undo),
                      child: Text(L10n.text('Undo'), style: TegnalType.style(17, color: tint)),
                    ),
                  ),
                ],
              ),
            ),
          Semantics(
            identifier: 'duplicates.apply',
            button: true,
            child: GestureDetector(
              onTap: enabled ? _confirm : null,
              child: Container(
                height: 50,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: enabled ? tint : TegnalColors.secondaryLabel.resolveFrom(context).withValues(alpha: 0.2),
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  _byNumber ? L10n.text('Tidy %@ Works', ['${_chosenGroups.length}']) : L10n.text('Clean Up %@ Copies', ['$total']),
                  style: TegnalType.style(
                    17,
                    weight: FontWeight.w600,
                    color: enabled ? const Color(0xFFFFFFFF) : TegnalColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One copy in a group: its cover, number, language, pages, save date and folders, and whether it stays.
class _DuplicateCopyRow extends StatelessWidget {
  const _DuplicateCopyRow({
    required this.copy,
    required this.keeps,
    required this.skipped,
    required this.images,
    required this.folderNames,
    required this.choose,
    this.placement = false,
  });
  final DuplicateCopy copy;
  final bool keeps;
  final bool skipped;
  final bool images;

  /// The copy is one of a work's folders.
  final bool placement;
  final List<String> folderNames;
  final VoidCallback choose;

  String _date(DateTime date) => switch (L10n.language) {
    'ko' => '${date.year}년 ${date.month}월 ${date.day}일',
    'ja' => '${date.year}年${date.month}月${date.day}日',
    _ => '${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]} ${date.day}, ${date.year}',
  };

  String get _details => placement
      ? (copy.savedAt == null ? '' : L10n.text('Saved %@', [_date(copy.savedAt!.toLocal())]))
      : [
          ?copy.server,
          '#${copy.number}',
          if (copy.language.isNotEmpty) L10n.text(libraryLanguageTitle(copy.language)),
          if (!images && copy.size > 0) L10n.text('%@ pages', ['${copy.size}']),
          if (images && copy.size > 0) L10n.text('%@ megapixels', [(copy.size / 1000000).toStringAsFixed(1)]),
          if (copy.savedAt case final saved?) L10n.text('Saved %@', [_date(saved.toLocal())]),
          if (folderNames.isNotEmpty) folderNames.join(', '),
        ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final color = skipped ? secondary : (keeps ? CupertinoColors.systemGreen.resolveFrom(context) : CupertinoColors.systemRed.resolveFrom(context));
    final placeholder = placement
        ? Icon(CupertinoIcons.folder, color: TegnalColors.tint.resolveFrom(context), size: 22)
        : Icon(images ? CupertinoIcons.photo : CupertinoIcons.book, color: secondary, size: 20);
    final path = placement ? null : copy.thumbnailPath, preview = copy.previewURL;
    return Semantics(
      identifier: 'duplicates.copy.${copy.id}',
      value: L10n.text(keeps ? 'Keep' : 'Remove'),
      button: true,
      child: FormRow(
        onTap: choose,
        child: Opacity(
          opacity: !keeps && !skipped ? 0.75 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 44,
                    height: 60,
                    color: secondary.withValues(alpha: 0.15),
                    child: path != null
                        ? LocalThumbnail(path: path, placeholder: placeholder)
                        : preview != null
                        ? Image.network(preview, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder)
                        : placeholder,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        copy.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(15, color: TegnalColors.label.resolveFrom(context)),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _details,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TegnalType.style(12, color: secondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: ShapeDecoration(color: color.withValues(alpha: 0.15), shape: const StadiumBorder()),
                  child: Text(
                    L10n.text(skipped ? 'Skipped' : (keeps ? 'Keep' : 'Remove')),
                    style: TegnalType.style(12, weight: FontWeight.w600, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `DuplicateFolderOrderView`: whether folders decide which copy stays, and their order.
class _DuplicateFolderPriorityView extends StatefulWidget {
  const _DuplicateFolderPriorityView({required this.options, required this.folders, required this.changed});
  final DuplicateCleanupOptions options;
  final List<({String key, String name})> folders;
  final ValueChanged<DuplicateCleanupOptions> changed;

  @override
  State<_DuplicateFolderPriorityView> createState() => _DuplicateFolderPriorityViewState();
}

class _DuplicateFolderPriorityViewState extends State<_DuplicateFolderPriorityView> {
  late DuplicateCleanupOptions _options = widget.options;

  List<({String key, String name})> get _ordered {
    final rank = DuplicateFinder.rank(order: _options.folderOrder, standard: [for (final folder in widget.folders) folder.key]);
    return [...widget.folders]..sort((a, b) => (rank[a.key] ?? 1 << 62).compareTo(rank[b.key] ?? 1 << 62));
  }

  void _change(DuplicateCleanupOptions options) {
    setState(() => _options = options);
    widget.changed(options);
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final ordered = _ordered;
    return SettingsPage(
      title: L10n.text('Folder Priority'),
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text(
              'A copy in a folder higher in the list stays. Drag folders to change the order. Your own folders come first at the start, then folders kept with website favorites, then Unfiled.',
            ),
          ),
          children: [
            SettingsToggleRow(
              title: L10n.text('Prefer Folders in This Order'),
              value: _options.useFolderOrder,
              onChanged: (value) => _change(_options.copyWith(useFolderOrder: value)),
            ),
          ],
        ),
        if (_options.useFolderOrder) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [for (final (index, folder) in ordered.indexed) SettingsValueRow(title: folder.name, value: '${index + 1}')],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                onTap: () => showAppSheet<void>(
                  context,
                  builder: (context, controller) => FolderOrderView<String>(
                    title: 'Folder Priority',
                    folders: [for (final folder in ordered) (id: folder.key, name: folder.name)],
                    save: (order) => _change(_options.copyWith(folderOrder: order)),
                  ),
                ),
                child: Text(L10n.text('Change Order'), style: TegnalType.style(17, color: tint)),
              ),
              FormRow(
                onTap: () => _change(_options.copyWith(folderOrder: const [])),
                child: Text(L10n.text('Reset Order'), style: TegnalType.style(17, color: tint)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
