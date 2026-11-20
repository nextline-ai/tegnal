import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/backup/automatic_backups.dart';
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
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'automatic_backups_view.dart';
import 'backup_reminder.dart';
import 'duplicate_cleanup_view.dart';
import '../booru/booru_folder_style.dart';
import 'cover_fill_warning.dart';
import 'settings_page.dart';
import 'settings_rows.dart';
import '../design/alert_dialog.dart';

/// What library management works on.
class LibraryManagementContext {
  const LibraryManagementContext({required this.database, required this.images, required this.content, required this.coverQueue, required this.backups, this.restored});
  final AppDatabase database;
  final BooruStore images;
  final ContentEnvironment content;
  final CoverQueue coverQueue;

  /// Automatic backups cover the whole app, so both modes open the same screen.
  final AutomaticBackups backups;

  /// After a restore: refill covers and publish the merged library to sync.
  final VoidCallback? restored;
}

/// `MangaLibraryToolsView`: organizing, backup and restore, library status and automatic fetching.
class LibraryManagementView extends StatefulWidget {
  const LibraryManagementView({super.key, required this.library, this.booru = false, this.extraSections = const []});
  final LibraryManagementContext library;

  /// Each mode's imports, placed after its backup.
  final List<Widget> extraSections;

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

  /// Imports and the cover queue change the counts while this screen is open.
  StreamSubscription<int>? _libraryChanges;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _queue.addListener(_changed);
    _libraryChanges = widget.library.database.changes.listen((_) {
      if (!mounted) return;
      setState(_loadStats);
    });
  }

  @override
  void dispose() {
    _libraryChanges?.cancel();
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

  Future<void> _export({String? password}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (await _backup.export(password: password)) BackupReminder.saved();
    } on Object catch (error) {
      _message = L10n.text('Unable to create backup: %@', ['$error']);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _exportLocked() async {
    final password = await _askPassword(confirm: true);
    if (password != null && mounted) await _export(password: password);
  }

  /// `.alert` with secure fields: one to open a locked backup, two to lock a new one.
  Future<String?> _askPassword({required bool confirm}) async {
    final first = TextEditingController(), second = TextEditingController();
    try {
      final entered = await showCupertinoDialog<String>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text(confirm ? 'Lock Backup with a Password' : 'Enter Backup Password')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                L10n.text(confirm ? 'Anyone with this password can open the backup. A forgotten password can’t be recovered.' : 'This backup is locked with a password.'),
              ),
              const SizedBox(height: 12),
              CupertinoTextField(controller: first, obscureText: true, autofocus: true, placeholder: L10n.text('Password')),
              if (confirm) ...[
                const SizedBox(height: 8),
                CupertinoTextField(controller: second, obscureText: true, placeholder: L10n.text('Confirm Password')),
              ],
            ],
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context, first.text),
              child: Text(L10n.text(confirm ? 'Export' : 'Open')),
            ),
          ],
        ),
      );
      if (entered == null) return null;
      if (confirm && (entered.length < 4 || entered != second.text)) {
        if (mounted) setState(() => _message = L10n.text('The passwords must match and have at least 4 characters.'));
        return null;
      }
      return entered;
    } finally {
      first.dispose();
      second.dispose();
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    LibraryBackupImport? backup;
    try {
      backup = await _backup.pick(password: () => _askPassword(confirm: false));
    } on LockedBackupError catch (error) {
      _message = error.message;
    } on Object catch (error) {
      _message = L10n.text('Unable to restore backup: %@', ['$error']);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (backup == null) return;
    final pending = backup;
    final restore = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
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
            'Titles and tags are replaced with what the current site shows. If the app closes or some works can’t be fetched, it picks up with the remaining works later. Notes, folders, and covers stay as they are, and works the site shows as a different work are left unchanged.',
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
    Widget section({String? header, Widget? headerWidget, Widget? footer, required List<Widget> children}) =>
        FormSection(prominentHeader: true, rowColor: row, header: headerWidget ?? (header == null ? null : Text(header)), footer: footer, children: children);
    void open(WidgetBuilder builder) => Navigator.of(context).push(CupertinoPageRoute<void>(builder: builder));
    return SettingsPage(
      title: L10n.text('Library Management'),
      children: [
        if (widget.booru) ...[BooruFolderStyleSection(store: widget.library.images), settingsSectionGap],
        section(
          header: L10n.text('Organize Saved Works'),
          children: [
            SettingsLinkRow(
              title: L10n.text('Classify into Folders'),
              icon: CupertinoIcons.folder_badge_person_crop,
              onTap: () => open((_) => LibraryOrganizationView(library: widget.library, booru: widget.booru)),
            ),
            Semantics(
              identifier: 'settings.duplicates',
              child: SettingsLinkRow(
                title: L10n.text('Clean Up Duplicates'),
                icon: CupertinoIcons.square_on_square,
                onTap: () => open((_) => DuplicateCleanupView(database: widget.library.database, images: widget.library.images, booru: widget.booru)),
              ),
            ),
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
              ListenableBuilder(
                listenable: widget.library.backups,
                builder: (context, _) {
                  final count = widget.library.backups.items.length;
                  return Semantics(
                    identifier: 'settings.automaticBackups',
                    child: SettingsLinkRow(
                      title: L10n.text('Automatic Backups'),
                      icon: CupertinoIcons.clock,
                      value: count > 0 ? '$count' : null,
                      onTap: () => open((_) => AutomaticBackupsView(backups: widget.library.backups)),
                    ),
                  );
                },
              ),
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
                title: L10n.text('Export with Password…'),
                icon: CupertinoIcons.lock,
                tinted: true,
                chevron: false,
                onTap: _exportLocked,
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
              const BackupReminderToggle(),
            ],
            footer: Text(L10n.text('Every seven days, opening the app suggests saving a backup file.')),
          ),
        ),
        for (final extra in widget.extraSections) ...[settingsSectionGap, extra],
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
                                if (sitesBlockingBulkReading(widget.library.content.comicSites) case final sites?)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(top: 1, right: 4),
                                          child: Icon(CupertinoIcons.exclamationmark_triangle, size: 13, color: SystemColors.orange.resolveFrom(context)),
                                        ),
                                        Expanded(
                                          child: Text(
                                            L10n.text(
                                              '%@ may block your network address when many works are read at once, so filling asks first and reads slowly. Add another website and missing information is read from there.',
                                              [sites],
                                            ),
                                            style: TegnalType.style(12, color: SystemColors.orange.resolveFrom(context)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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

/// `LibraryOrganizationView`: classify works into folders by a field.
class LibraryOrganizationView extends StatefulWidget {
  const LibraryOrganizationView({super.key, required this.library, this.booru = false});
  final LibraryManagementContext library;
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
      duplicates: false,
    );
  });

  List<LibraryClassificationGroup> get _groups => LibraryMaintenance.classification(works: _items.works, posts: _items.posts, criterion: _criterion);

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

  void _showError(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
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
    final title = L10n.text('Classify into Folders');
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
                  'Creates folders from metadata already saved in your library. Comics keep their existing folder memberships. Images use the first matching value because each image belongs to one folder. Works with missing metadata are skipped.',
                ),
              ),
            ),
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
            header: Text(L10n.text(_criterion.title)),
            children: [
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
                child: Text(L10n.text('No Matching Metadata'), style: TegnalType.style(17, color: secondary)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
