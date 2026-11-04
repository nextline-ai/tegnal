import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_models.dart';
import '../../core/booru/booru_store.dart';
import '../../core/content/content_environment.dart';
import '../../core/content/cover_queue.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/library_backup.dart';
import '../../core/storage/library_backup_actions.dart';
import '../../core/storage/library_maintenance.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// What library management works on.
class LibraryManagementContext {
  const LibraryManagementContext({required this.database, required this.images, required this.content, required this.coverQueue, this.restored});
  final AppDatabase database;
  final BooruStore images;
  final ContentEnvironment content;
  final CoverQueue coverQueue;

  /// After a restore: refill covers and publish the merged library to sync.
  final VoidCallback? restored;
}

/// `MangaLibraryToolsView`: organizing, backup and restore, library status and automatic fetching.
class LibraryManagementView extends StatefulWidget {
  const LibraryManagementView({super.key, required this.library, this.booru = false});
  final LibraryManagementContext library;

  /// `BooruBackupView`: image mode organizes its own favorites and has no comics catalog.
  final bool booru;

  @override
  State<LibraryManagementView> createState() => _LibraryManagementViewState();
}

class _LibraryManagementViewState extends State<LibraryManagementView> {
  late final _backup = LibraryBackupActions(database: widget.library.database, images: widget.library.images);
  bool _busy = false;
  String? _message;
  int _works = 0, _catalog = 0, _missing = 0;

  CoverQueueState get _queue => widget.library.coverQueue.state;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _queue.addListener(_changed);
  }

  @override
  void dispose() {
    _queue.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _loadStats() {
    final database = widget.library.database;
    _works = database.worksCount();
    _catalog = database.catalogCount();
    _missing = database.missingTitleCount();
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _backup.export();
    } on Object catch (error) {
      _message = L10n.text('Unable to create backup: %@', ['$error']);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    LibraryBackupImport? backup;
    try {
      backup = await _backup.pick();
    } on Object catch (error) {
      _message = L10n.text('Unable to restore backup: %@', ['$error']);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (backup == null) return;
    final pending = backup;
    final restore = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(L10n.text('Restore Backup?')),
        content: Text(
          '${L10n.text('Comics: %@ · Images: %@ · Challenges: %@', ['${pending.comicWorks}', '${pending.imageFavorites}', '${pending.challengeGames}'])}\n'
          '${L10n.text('The backup will be merged with your library. Matching favorites, folder colors and order will use the backup values. These changes also sync when iCloud is enabled.')}',
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Restore'))),
        ],
      ),
    );
    if (restore != true || !mounted) return;
    setState(() => _busy = true);
    try {
      _backup.restore(pending);
      widget.library.restored?.call();
      _message = L10n.text('Backup restored: %@ works, %@ folders', ['${pending.workCount}', '${pending.folderCount}']);
    } on Object catch (error) {
      _message = L10n.text('Unable to restore backup: %@', ['$error']);
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _loadStats();
      });
    }
  }

  Future<void> _confirmRefresh() async {
    final refresh = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Refresh information for %@ saved works?', ['$_works'])),
        message: Text(
          L10n.text(
            'Titles and tags are replaced with what the current site shows. Notes, folders, and covers stay as they are, and works the site shows as a different work are left unchanged.',
          ),
        ),
        actions: [CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Refresh Information')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (refresh == true) widget.library.coverQueue.requestRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final queue = _queue;
    final running = queue.isRunning && !queue.isPaused;
    final done = queue.processed + queue.failed + queue.gone;
    String? queueCaption;
    if (queue.isRunning && queue.total > 0) {
      queueCaption = L10n.text('%@/%@ (failed: %@, unavailable: %@)', ['$done', '${queue.total}', '${queue.failed}', '${queue.gone}']);
    } else if (queue.error != null) {
      queueCaption = queue.error;
    } else if (queue.remaining > 0) {
      queueCaption = L10n.text('Still missing information: %@ works. Failed downloads can be retried.', ['${queue.remaining}']);
    }
    Widget section({String? header, Widget? headerWidget, required List<Widget> children}) =>
        FormSection(prominentHeader: true, rowColor: row, header: headerWidget ?? (header == null ? null : Text(header)), children: children);
    void organize(bool duplicates) => Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => LibraryOrganizationView(library: widget.library, duplicates: duplicates, booru: widget.booru),
      ),
    );
    return SettingsPage(
      title: L10n.text('Library Management'),
      children: [
        section(
          header: L10n.text('Organize Saved Works'),
          children: [
            SettingsLinkRow(title: L10n.text('Classify into Folders'), icon: CupertinoIcons.folder_badge_person_crop, onTap: () => organize(false)),
            SettingsLinkRow(title: L10n.text('Review Duplicate Works'), icon: CupertinoIcons.square_on_square, onTap: () => organize(true)),
          ],
        ),
        settingsSectionGap,
        IgnorePointer(
          ignoring: _busy,
          child: section(
            headerWidget: SettingsTitle(
              L10n.text('Backup & Restore'),
              help: L10n.text(
                'Exports both libraries, folders, saved searches and other library data into one JSON file. Media and sign-in details are not included. Importing merges the file with your library.',
              ),
            ),
            children: [
              FormRow(
                separatorInset: settingsIconInset,
                onTap: _export,
                child: Row(
                  children: [
                    SizedBox(width: 24, child: Icon(CupertinoIcons.share, size: 22, color: tint)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(L10n.text('Export JSON Backup'), style: TegnalType.style(17, color: tint)),
                    ),
                    if (_busy) const CupertinoActivityIndicator(),
                  ],
                ),
              ),
              SettingsLinkRow(
                title: L10n.text('Import / Restore JSON Backup'),
                icon: CupertinoIcons.square_arrow_down,
                tinted: true,
                chevron: false,
                onTap: _import,
              ),
              if (_message != null)
                FormRow(
                  child: Text(_message!, style: TegnalType.style(13, color: secondary)),
                ),
            ],
          ),
        ),
        if (!widget.booru) ...[
          settingsSectionGap,
          section(
            header: L10n.text('Library Status'),
            children: [
              SettingsValueRow(title: L10n.text('Saved Works'), value: L10n.text('%@ items', ['$_works'])),
              SettingsValueRow(title: L10n.text('Catalog Matches'), value: L10n.text('%@ items', ['$_catalog'])),
              SettingsValueRow(title: L10n.text('Missing Titles'), value: L10n.text('%@ items', ['$_missing'])),
            ],
          ),
          settingsSectionGap,
          section(
            header: L10n.text('Automatic Fetching'),
            children: [
              FormRow(
                minHeight: settingsHelpRowHeight + 8,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SettingsTitle(
                                  L10n.text('Fill Covers, Titles, and Tags'),
                                  help: L10n.text(
                                    'Finds missing covers, titles and tags for works in your library. You can pause and resume the background task.',
                                  ),
                                  style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
                                ),
                                if (queueCaption != null) Text(queueCaption, style: TegnalType.style(12, color: secondary)),
                              ],
                            ),
                          ),
                          Semantics(
                            button: true,
                            label: L10n.text(running ? 'Pause' : 'Fill Covers, Titles, and Tags'),
                            child: GestureDetector(
                              onTap: widget.library.coverQueue.toggle,
                              child: Icon(running ? CupertinoIcons.pause_circle_fill : CupertinoIcons.play_circle_fill, size: 28, color: tint),
                            ),
                          ),
                        ],
                      ),
                      if (queue.isRunning && queue.total > 0) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: SizedBox(
                            height: 4,
                            child: Stack(
                              children: [
                                Container(color: TegnalColors.tertiaryLabel.resolveFrom(context)),
                                FractionallySizedBox(
                                  widthFactor: (done / queue.total).clamp(0, 1),
                                  child: Container(color: tint),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              FormRow(
                separatorInset: settingsIconInset,
                onTap: _works == 0 || !widget.library.content.isSiteVerified ? null : _confirmRefresh,
                child: Opacity(
                  opacity: _works == 0 || !widget.library.content.isSiteVerified ? 0.4 : 1,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 24, child: Icon(CupertinoIcons.arrow_2_circlepath, size: 22, color: tint)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(L10n.text('Refresh Saved Work Information'), style: TegnalType.style(17, color: tint)),
                            Text(
                              L10n.text('Fetches titles and tags again from the current site, for example after an update changes how a site is read.'),
                              style: TegnalType.style(12, color: secondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `LibraryOrganizationView`: classify works into folders by a field, or review possible duplicates.
class LibraryOrganizationView extends StatefulWidget {
  const LibraryOrganizationView({super.key, required this.library, this.duplicates = false, this.booru = false});
  final LibraryManagementContext library;
  final bool duplicates;
  final bool booru;

  @override
  State<LibraryOrganizationView> createState() => _LibraryOrganizationViewState();
}

class _LibraryOrganizationViewState extends State<LibraryOrganizationView> {
  LibraryClassification _criterion = LibraryClassification.artist;
  bool _onlyUnsorted = true;
  bool _busy = false;
  String? _message;
  ({List<Work> works, List<BooruPost> posts}) _items = (works: const [], posts: const []);

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => setState(() {
    _items = LibraryMaintenance.load(
      database: widget.library.database,
      images: widget.library.images,
      booru: widget.booru,
      onlyUnsorted: _onlyUnsorted,
      duplicates: widget.duplicates,
    );
  });

  List<LibraryClassificationGroup> get _groups => widget.duplicates
      ? LibraryMaintenance.duplicates(works: _items.works, posts: _items.posts)
      : LibraryMaintenance.classification(works: _items.works, posts: _items.posts, criterion: _criterion);

  Future<void> _classify() async {
    final apply = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Apply Classification?')),
        actions: [CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Apply')))],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (apply != true) return;
    setState(() => _busy = true);
    try {
      LibraryMaintenance.classify(_groups, title: L10n.text(_criterion.title), database: widget.library.database, images: widget.library.images);
      _message = L10n.text('Classification Complete');
    } on Object catch (error) {
      _showError('$error');
    }
    _busy = false;
    _load();
  }

  Future<void> _keep(LibraryClassificationGroup group, Work work) async {
    final keep = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Keep This Copy?')),
        message: Text(
          L10n.text(
            'Review the number and source before confirming. Comics merge folder memberships and notes into the kept copy. Images keep the selected copy’s folder.',
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('Keep This Copy and Remove Others')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (keep != true) return;
    try {
      LibraryMaintenance.mergeComics(group, keeping: work.galleryId, database: widget.library.database);
      _message = L10n.text('Duplicate Copies Removed');
    } on Object catch (error) {
      _showError('$error');
    }
    _load();
  }

  Future<void> _keepImage(LibraryClassificationGroup group, BooruPost post) async {
    final keep = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(L10n.text('Keep This Copy?')),
        message: Text(
          L10n.text(
            'Review the number and source before confirming. Comics merge folder memberships and notes into the kept copy. Images keep the selected copy’s folder.',
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.text('Keep This Copy and Remove Others')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
      ),
    );
    if (keep != true) return;
    try {
      LibraryMaintenance.mergeImages(group, keeping: post.id, images: widget.library.images);
      _message = L10n.text('Duplicate Copies Removed');
    } on Object catch (error) {
      _showError('$error');
    }
    _load();
  }

  void _showError(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(L10n.text('Unable to Save')),
      content: Text(message),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final row = FormColors.listRow.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final groups = _groups;
    final title = L10n.text(widget.duplicates ? 'Review Duplicate Works' : 'Classify into Folders');
    return SettingsPage(
      title: title,
      children: [
        FormSection(
          rowColor: row,
          children: [
            FormRow(
              child: SettingsTitle(
                title,
                help: L10n.text(
                  widget.duplicates
                      ? 'Identical work numbers and server post IDs are already merged. This lists possible duplicates with matching metadata or original file addresses. Review each copy before removing it.'
                      : 'Creates folders from metadata already saved in your library. Comics keep their existing folder memberships. Images use the first matching value because each image belongs to one folder. Works with missing metadata are skipped.',
                ),
              ),
            ),
            if (!widget.duplicates) ...[
              SettingsPickerRow<LibraryClassification>(
                title: L10n.text('Classify By'),
                options: [for (final value in LibraryClassification.available(booru: widget.booru)) (value, L10n.text(value.title))],
                selected: _criterion,
                onSelected: (value) => setState(() => _criterion = value),
              ),
              SettingsToggleRow(
                title: L10n.text('Only Unsorted Works'),
                value: _onlyUnsorted,
                onChanged: (value) {
                  _onlyUnsorted = value;
                  _load();
                },
              ),
              FormRow(
                onTap: groups.isEmpty || _busy ? null : _classify,
                child: Text(L10n.text('Apply Classification'), style: TegnalType.style(17, color: groups.isEmpty || _busy ? secondary : tint)),
              ),
            ],
            if (_busy) const FormRow(child: CupertinoActivityIndicator()),
            if (_message != null)
              FormRow(
                child: Text(_message!, style: TegnalType.style(17, color: secondary)),
              ),
          ],
        ),
        for (final group in groups) ...[
          settingsSectionGap,
          FormSection(
            prominentHeader: true,
            rowColor: row,
            header: Text(widget.duplicates ? L10n.text('Possible Duplicates') : L10n.text(_criterion.title)),
            children: [
              if (widget.duplicates)
                for (final post in group.posts)
                  FormRow(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('${post.serverID} · ${post.postID}', style: TegnalType.style(17, color: tint)),
                        ),
                        GestureDetector(
                          onTap: () => _keepImage(group, post),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: ShapeDecoration(color: tint.withValues(alpha: 0.15), shape: const StadiumBorder()),
                            child: Text(L10n.text('Keep This Copy'), style: TegnalType.style(15, color: tint)),
                          ),
                        ),
                      ],
                    ),
                  ),
              if (widget.duplicates)
                for (final work in group.works)
                  FormRow(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('${work.title ?? ''} · ${work.galleryId}', style: TegnalType.style(17, color: tint)),
                        ),
                        GestureDetector(
                          onTap: () => _keep(group, work),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: ShapeDecoration(color: tint.withValues(alpha: 0.15), shape: const StadiumBorder()),
                            child: Text(L10n.text('Keep This Copy'), style: TegnalType.style(15, color: tint)),
                          ),
                        ),
                      ],
                    ),
                  )
              else
                SettingsValueRow(title: group.name.replaceAll('_', ' '), value: '${group.count}'),
            ],
          ),
        ],
        if (groups.isEmpty && !_busy) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                child: Text(L10n.text(widget.duplicates ? 'No Duplicate Candidates' : 'No Matching Metadata'), style: TegnalType.style(17, color: secondary)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
