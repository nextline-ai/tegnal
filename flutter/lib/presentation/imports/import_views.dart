import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/anime_boxes_import.dart';
import '../../core/migration/manga_viewer_import.dart';
import '../../core/migration/other_app_import.dart';
import '../../core/migration/violet_import.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/document_files.dart';
import '../../core/support/l10n.dart';
import '../booru/booru_common.dart';
import '../design/app_sheet.dart';
import '../design/grouped_form.dart';
import '../design/ios_controls.dart';
import '../design/symbols.dart';
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import '../settings/settings_page.dart';
import '../settings/settings_rows.dart';

/// What the import screens change: both libraries, and the cover queue that fills
/// imported comics afterwards.
class ImportContext {
  const ImportContext({required this.booru, required this.database, this.startCoverQueue, this.libraryChanged});
  final BooruContext booru;
  final AppDatabase database;
  final VoidCallback? startCoverQueue;

  /// Tells the comics library screens to read their folders and works again.
  final VoidCallback? libraryChanged;
}

/// `AnimeBoxesImportView`: reads a backup or export from another image viewer. One button takes
/// every kind of file: what the file is, is worked out from the file.
class AnimeBoxesImportView extends StatefulWidget {
  const AnimeBoxesImportView({super.key, required this.booru, this.inSheet = false});
  final BooruContext booru;

  /// Pushed inside the import sheet, the page keeps the sheet's colors.
  final bool inSheet;

  @override
  State<AnimeBoxesImportView> createState() => _AnimeBoxesImportViewState();
}

class _AnimeBoxesImportViewState extends State<AnimeBoxesImportView> {
  AnimeBoxesBackup? _backup;
  String _folderID = 'by-site';
  bool _history = true;
  bool _blacklist = true;
  bool _selection = true;
  bool _loading = false;
  bool _serversOpen = false;
  AnimeBoxesImportResult? _result;
  String? _error;

  Future<void> _choose() async {
    setState(() {
      _loading = true;
      _result = null;
      _error = null;
      _backup = null;
    });
    try {
      final file = await const DocumentFiles().openDocument();
      if (file != null) {
        try {
          final backup = AnimeBoxesBackup.read(file);
          if (mounted) setState(() => _backup = backup);
        } finally {
          file.delete().ignore();
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _commit() async {
    final backup = _backup;
    if (backup == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // A local transaction; no media is downloaded to import a library.
    await Future<void>.delayed(Duration.zero);
    try {
      final result = widget.booru.store.importAnimeBoxes(
        backup,
        options: AnimeBoxesImportOptions(history: _history, blacklist: _blacklist, selection: _selection, folderID: _folderID),
      );
      widget.booru.store.refresh();
      if (mounted) setState(() => _result = result);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final row = (widget.inSheet ? FormColors.row : FormColors.listRow).resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final backup = _backup;
    final result = _result;
    final folders = widget.booru.store.folders();
    return SettingsPage(
      title: L10n.text('Other Image Viewer'),
      sheet: widget.inSheet,
      children: [
        FormSection(
          rowColor: row,
          footer: Text(L10n.text('Supported: Anime Boxes backups (.abbj), bookmark exports (.json) and database backups (.db).')),
          children: [
            _ImportHeadline(title: L10n.text('Import from Another Image Viewer')),
            FormRow(
              child: Text(
                L10n.text('Choose a backup or export from another image viewer. TEGNAL recognizes what the file holds and shows it before importing.'),
                style: TegnalType.style(15, color: secondary),
              ),
            ),
            SettingsLinkRow(
              title: L10n.text(backup == null ? 'Choose File' : 'Choose Another File'),
              symbol: (color) => _DocumentBadgePlus(color: color),
              tinted: true,
              chevron: false,
              onTap: _loading ? null : _choose,
            ),
          ],
        ),
        if (_loading) ...[settingsSectionGap, _ProgressSection(rowColor: row, message: L10n.text('Importing…'))],
        if (_error case final error?) ...[settingsSectionGap, _ErrorSection(rowColor: row, message: error)],
        if (result != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              const _CompleteRow(),
              FormRow(
                child: Text(
                  L10n.text('%@ favorites added · %@ duplicates preserved · %@ servers added', [
                    '${result.added}',
                    '${result.duplicates}',
                    '${result.serversAdded}',
                  ]),
                ),
              ),
            ],
          ),
        ] else if (backup != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Backup Contents')),
            children: [
              SettingsValueRow(title: L10n.text('Servers'), value: '${backup.servers.length}'),
              SettingsValueRow(title: L10n.text('Favorites'), value: '${backup.favorites.length}'),
              SettingsValueRow(title: L10n.text('Search History'), value: '${backup.history.length}'),
              SettingsValueRow(title: L10n.text('Tag Blacklist'), value: '${backup.blacklist.length}'),
              FormRow(
                onTap: () => setState(() => _serversOpen = !_serversOpen),
                child: Row(
                  children: [
                    Expanded(child: Text(L10n.text('Servers'))),
                    AnimatedRotation(
                      turns: _serversOpen ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                    ),
                  ],
                ),
              ),
              if (_serversOpen)
                for (final server in backup.servers) SettingsValueRow(title: server.displayName, value: server.engine.title),
              if (backup.skippedServers + backup.skippedFavorites + backup.skippedHistory + backup.skippedRules case final skipped when skipped > 0)
                FormRow(
                  child: Text(
                    L10n.text('%@ unsupported or invalid entries will be skipped.', ['$skipped']),
                    style: TegnalType.style(17, color: SystemColors.orange.resolveFrom(context)),
                  ),
                ),
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Import Options')),
            children: [
              SettingsPickerRow<String>(
                title: L10n.text('Destination Folder'),
                options: [
                  // Each server's Uncategorized, or the folder it saves to.
                  ('by-site', L10n.text('Uncategorized')),
                  if (backup.source != AnimeBoxesSource.animeBoxes) ...[
                    if (!folders.any((folder) => folder.id == AnimeBoxesBackup.importedFolderID)) (AnimeBoxesBackup.importedFolderID, L10n.text('Imported')),
                  ] else if (!folders.any((folder) => folder.id == 'anime-boxes'))
                    ('anime-boxes', 'Anime Boxes'),
                  for (final folder in folders)
                    if (!folder.isUncategorized) (folder.id, widget.booru.store.labeledName(folder)),
                ],
                selected: _folderID,
                onSelected: (value) => setState(() => _folderID = value),
              ),
              if (backup.source == AnimeBoxesSource.animeBoxes || backup.history.isNotEmpty)
                _Toggle(title: L10n.text('Import Search History'), value: _history, onChanged: (value) => setState(() => _history = value)),
              if (backup.source == AnimeBoxesSource.animeBoxes) ...[
                _Toggle(title: L10n.text('Import Tag Blacklist'), value: _blacklist, onChanged: (value) => setState(() => _blacklist = value)),
                _Toggle(title: L10n.text('Use Server Selection from Backup'), value: _selection, onChanged: (value) => setState(() => _selection = value)),
              ],
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            footer: Text(
              L10n.text(
                'Existing favorites keep their folders. Shared search history and blacklist rules are copied to each imported server. API credentials and cookies must be set up again in server settings. Manga data is unchanged.',
              ),
            ),
            children: [
              SettingsLinkRow(
                title: L10n.text('Import'),
                icon: CupertinoIcons.square_arrow_down,
                tinted: true,
                chevron: false,
                onTap: _loading || backup.servers.isEmpty ? null : _commit,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `OtherAppImportView`: reads a backup, export, database, download folder or link list from
/// another comics viewer, shows what it holds, and merges it into the library when the person
/// confirms. One button takes every kind of file; what the file is, is worked out from the file.
class OtherAppImportView extends StatefulWidget {
  const OtherAppImportView({super.key, required this.database, this.startCoverQueue, this.libraryChanged, this.inSheet = false, this.done = false});
  final AppDatabase database;
  final VoidCallback? startCoverQueue;
  final VoidCallback? libraryChanged;

  /// Pushed inside the import sheet, the page keeps the sheet's colors.
  final bool inSheet;

  /// The first page of its own sheet ends with Done, which closes the sheet.
  final bool done;

  @override
  State<OtherAppImportView> createState() => _OtherAppImportViewState();
}

class _OtherAppImportViewState extends State<OtherAppImportView> {
  /// The picker's value for the file's own folders.
  static const _fromFile = -1;

  OtherAppLibrary? _library;
  var _includeHistory = false;
  var _destination = _fromFile;
  var _loading = false;
  var _foldersOpen = false;
  OtherAppImportResult? _result;
  String? _error;

  /// The picked file, when it is a viewer's own database, kept until it is imported or replaced.
  (ViewerDatabase, File)? _database;

  /// What a viewer database import is doing, or how it ended.
  String? _status;

  /// Saved works, which the catalog's fill-in needs.
  late var _saved = widget.database.worksCount();

  /// Set when the screen goes away, so a running import stops before its next write.
  var _closed = false;

  @override
  void dispose() {
    _closed = true;
    // A running import removes its file when it ends.
    if (!_loading) _discardDatabase();
    super.dispose();
  }

  void _discardDatabase() {
    _database?.$2.delete().ignore();
    _database = null;
  }

  Future<void> _read(Future<Object?> Function() pick) async {
    setState(() {
      _discardDatabase();
      _loading = true;
      _result = null;
      _error = null;
      _library = null;
      _status = null;
    });
    try {
      final picked = await pick();
      if (!mounted) {
        if (picked case (ViewerDatabase _, final File file)) file.delete().ignore();
      } else if (picked case (final ViewerDatabase kind, final File file)) {
        setState(() => _database = (kind, file));
      } else if (picked case final OtherAppLibrary library) {
        setState(() {
          _library = library;
          _destination = _fromFile;
          // A file that only remembers what was read imports that history by default.
          _includeHistory = library.workCount == 0 && library.history.isNotEmpty;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (mounted) setState(() => _loading = false);
  }

  /// A viewer's own database is recognized first, by the tables it holds; every other file is read
  /// as a library to preview.
  Future<Object?> _chooseFile() async {
    final file = await const DocumentFiles().openDocument();
    if (file == null) return null;
    if (ViewerDatabase.recognize(file) case final kind?) return (kind, file);
    try {
      return OtherAppImport.read(file);
    } finally {
      file.delete().ignore();
    }
  }

  Future<Object?> _chooseFolder() async {
    final folder = await const DocumentFiles().pickFolder();
    return folder == null ? null : OtherAppImport.readDownloadFolder(Directory(folder.path));
  }

  Future<void> _commit() async {
    final library = _library;
    if (library == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    // Let the progress row appear before the import holds the database.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      final result = widget.database.importOtherApp(
        library,
        options: OtherAppImportOptions(includeHistory: _includeHistory, destination: _destination == _fromFile ? null : _destination),
      );
      widget.startCoverQueue?.call();
      if (mounted) setState(() => _result = result);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    widget.libraryChanged?.call();
    if (mounted) setState(() => _loading = false);
  }

  /// Its bookmarks are imported as they are, into folders made from its groups.
  void _importBookmarks() {
    final message = L10n.text('Importing library from user.db…');
    _run(message, (file) async {
      final found = await VioletImportService(widget.database).import(
        file.path,
        cancelled: () => _closed,
        progress: (done, total) {
          if (mounted && _loading) setState(() => _status = '$message ($done/$total)');
        },
      );
      return L10n.text('user.db imported: %@ folders, %@ works, %@ artists', ['${found.folders}', '${found.works}', '${found.artists}']);
    });
  }

  /// Its catalogue either fills in the works already saved or is kept whole.
  void _importCatalog({required bool matchOnly}) {
    _run(L10n.text(matchOnly ? 'Matching metadata for your library…' : 'Caching large file… Please wait.'), (file) async {
      final importer = MangaViewerImportService(widget.database);
      if (matchOnly) {
        final found = importer.matchAndFillWorks(file.path, cancelled: () => _closed);
        return L10n.text('Metadata matched! Filled %2\$@ of %1\$@ saved works.', ['${found.totalWorks}', '${found.matched}']);
      }
      final total = importer.importDataDatabase(
        file.path,
        cancelled: () => _closed,
        progress: (count) {
          if (mounted && _loading) setState(() => _status = L10n.text('Importing entire catalog… (%@ records)', ['$count']));
        },
      );
      return L10n.text('data.db imported: %@ catalog records applied', ['$total']);
    });
  }

  /// Runs one viewer database import and reports how it ended. Leaving the screen stops it before
  /// its next write; what was saved by then stays.
  Future<void> _run(String message, Future<String> Function(File file) work) async {
    final picked = _database;
    if (picked == null) return;
    final file = picked.$2;
    setState(() {
      _loading = true;
      _error = null;
      _status = message;
    });
    // Let the status appear before the import holds the database.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    var finished = false;
    String outcome;
    try {
      outcome = await work(file);
      finished = true;
      widget.startCoverQueue?.call();
    } on ImportCancelled {
      outcome = L10n.text('The task was canceled.');
    } on Object catch (error) {
      outcome = L10n.text('Import failed: %@', ['$error']);
    }
    // Even a stopped import may have saved some works.
    widget.libraryChanged?.call();
    if (finished || !mounted) file.delete().ignore();
    if (!mounted) return;
    setState(() {
      _status = outcome;
      // A failed import keeps the file, so it can be tried again.
      if (finished) _database = null;
      _saved = widget.database.worksCount();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final row = (widget.inSheet ? FormColors.row : FormColors.listRow).resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final library = _library;
    final result = _result;
    return SettingsPage(
      title: L10n.text('Other Comics Viewer'),
      sheet: widget.inSheet,
      trailing: widget.done
          ? GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context, rootNavigator: true).pop())
          : null,
      children: [
        FormSection(
          rowColor: row,
          footer: Text(
            L10n.text(
              'Supported: bookmark backups and work catalogs (user.db, data.db), database exports (.db), app data exports (.json), download folders with manifest.json, manga reader backups (.tachibk), and link lists or browser bookmarks (.txt, .html).',
            ),
          ),
          children: [
            _ImportHeadline(title: L10n.text('Import from Another Comics Viewer')),
            FormRow(
              child: Text(
                L10n.text(
                  'Choose a backup, export, database or link list from another comics viewer. TEGNAL recognizes what the file holds and shows it before importing.',
                ),
                style: TegnalType.style(15, color: secondary),
              ),
            ),
            SettingsLinkRow(
              title: L10n.text(library == null && _database == null ? 'Choose File' : 'Choose Another File'),
              symbol: (color) => _DocumentBadgePlus(color: color),
              tinted: true,
              chevron: false,
              onTap: _loading ? null : () => _read(_chooseFile),
            ),
            SettingsLinkRow(
              title: L10n.text('Choose Download Folder'),
              icon: CupertinoIcons.folder_badge_plus,
              tinted: true,
              chevron: false,
              onTap: _loading ? null : () => _read(_chooseFolder),
            ),
          ],
        ),
        if (_loading) ...[
          settingsSectionGap,
          _ProgressSection(rowColor: row, message: _status ?? L10n.text('Importing…')),
        ] else if (_status case final status?) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [FormRow(child: Text(status))],
          ),
        ],
        if (_database case (final kind, _) when !_loading) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('File Contents')),
            children: [SettingsValueRow(title: L10n.text('Kind'), value: kind.title)],
          ),
          settingsSectionGap,
          if (kind == ViewerDatabase.bookmarks)
            FormSection(
              rowColor: row,
              footer: Text(L10n.text('Titles, tags and covers are filled in from the connected website in the background.')),
              children: [
                SettingsLinkRow(title: L10n.text('Import'), icon: CupertinoIcons.square_arrow_down, tinted: true, chevron: false, onTap: _importBookmarks),
              ],
            )
          else
            FormSection(
              rowColor: row,
              footer: _saved == 0
                  ? Text(
                      L10n.text('There are no saved works to match. Import user.db (bookmarks) first, then import data.db to fill the information you need.'),
                    )
                  : null,
              children: [
                SettingsLinkRow(
                  title: L10n.text('⚡️ Fill Only My Library (Recommended)'),
                  tinted: true,
                  chevron: false,
                  onTap: _saved == 0 ? null : () => _importCatalog(matchOnly: true),
                ),
                SettingsLinkRow(
                  title: L10n.text('📦 Save Entire Catalog (Background Import)'),
                  tinted: true,
                  chevron: false,
                  onTap: () => _importCatalog(matchOnly: false),
                ),
              ],
            ),
        ],
        if (_error case final error?) ...[settingsSectionGap, _ErrorSection(rowColor: row, message: error)],
        if (result != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            footer: Text(L10n.text('Titles, tags and covers are filled in from the connected website in the background.')),
            children: [
              const _CompleteRow(),
              FormRow(
                child: Text(
                  L10n.text('%@ works added · %@ already saved · %@ folders created', ['${result.added}', '${result.existing}', '${result.folders}']),
                ),
              ),
            ],
          ),
        ] else if (library != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('File Contents')),
            children: [
              SettingsValueRow(title: L10n.text('Kind'), value: library.format.title),
              SettingsValueRow(title: L10n.text('Works'), value: '${library.workCount}'),
              if (library.history.isNotEmpty) SettingsValueRow(title: L10n.text('Reading History'), value: '${library.history.length}'),
              if (library.shelves.isNotEmpty) ...[
                FormRow(
                  onTap: () => setState(() => _foldersOpen = !_foldersOpen),
                  child: Row(
                    children: [
                      Expanded(child: Text(L10n.text('Folders'))),
                      AnimatedRotation(
                        turns: _foldersOpen ? 0.25 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(CupertinoIcons.chevron_right, size: 15, color: tint),
                      ),
                    ],
                  ),
                ),
                if (_foldersOpen)
                  for (final shelf in library.shelves) SettingsValueRow(title: shelf.displayName, value: '${shelf.entries.length}'),
              ],
              if (library.skipped > 0)
                FormRow(
                  child: Text(
                    L10n.text('%@ entries that aren’t works of a supported catalog will be skipped.', ['${library.skipped}']),
                    style: TegnalType.style(17, color: SystemColors.orange.resolveFrom(context)),
                  ),
                ),
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            header: Text(L10n.text('Import Options')),
            children: [
              SettingsPickerRow<int>(
                title: L10n.text('Destination Folder'),
                options: [
                  (_fromFile, L10n.text(library.shelves.length > 1 || library.shelves.firstOrNull?.name != null ? 'Folders from the File' : 'Unfiled')),
                  for (final folder in widget.database.listFolders())
                    if (folder.id case final id?) (id, folder.displayName),
                ],
                selected: _destination,
                onSelected: (value) => setState(() => _destination = value),
              ),
              if (library.history.isNotEmpty)
                _Toggle(
                  title: L10n.text('Import Reading History as a Folder'),
                  value: _includeHistory,
                  onChanged: (value) => setState(() => _includeHistory = value),
                ),
            ],
          ),
          settingsSectionGap,
          FormSection(
            rowColor: row,
            footer: Text(
              L10n.text(
                'Works already in your library keep their information and folders. Covers and missing information are read from the connected website afterwards, following the bulk reading limits.',
              ),
            ),
            children: [
              SettingsLinkRow(
                title: L10n.text('Import'),
                icon: CupertinoIcons.square_arrow_down,
                tinted: true,
                chevron: false,
                onTap: _loading || (library.workCount == 0 && !_includeHistory) ? null : _commit,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A screen's first row: the import symbol before its title in semibold.
class _ImportHeadline extends StatelessWidget implements FormSeparatorInset {
  const _ImportHeadline({required this.title});
  final String title;

  @override
  double get separatorInset => settingsIconInset;

  @override
  Widget build(BuildContext context) => FormRow(
    separatorInset: settingsIconInset,
    child: Row(
      children: [
        Icon(CupertinoIcons.square_arrow_down_on_square_fill, size: 22, color: TegnalColors.tint.resolveFrom(context)),
        const SizedBox(width: 18),
        Expanded(
          child: Text(
            title,
            style: TegnalType.style(17, weight: FontWeight.w600, color: TegnalColors.label.resolveFrom(context)),
          ),
        ),
      ],
    ),
  );
}

/// `ProgressView(message)` in its own section.
class _ProgressSection extends StatelessWidget {
  const _ProgressSection({required this.rowColor, required this.message});
  final Color rowColor;
  final String message;

  @override
  Widget build(BuildContext context) => FormSection(
    rowColor: rowColor,
    children: [
      FormRow(
        child: Row(
          children: [
            const CupertinoActivityIndicator(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: TegnalType.style(17, color: TegnalColors.secondaryLabel.resolveFrom(context))),
            ),
          ],
        ),
      ),
    ],
  );
}

/// What went wrong, in red, in its own section.
class _ErrorSection extends StatelessWidget {
  const _ErrorSection({required this.rowColor, required this.message});
  final Color rowColor;
  final String message;

  @override
  Widget build(BuildContext context) => FormSection(
    rowColor: rowColor,
    children: [
      FormRow(
        child: Text(message, style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
      ),
    ],
  );
}

/// `Label("Import Complete", systemImage: "checkmark.circle.fill")` in green.
class _CompleteRow extends StatelessWidget {
  const _CompleteRow();

  @override
  Widget build(BuildContext context) {
    final green = SystemColors.green.resolveFrom(context);
    return FormRow(
      child: Row(
        children: [
          Icon(CupertinoIcons.checkmark_circle_fill, size: 22, color: green),
          const SizedBox(width: 12),
          Text(L10n.text('Import Complete'), style: TegnalType.style(17, color: green)),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.title, required this.value, required this.onChanged});
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => FormRow(
    child: Row(
      children: [
        Expanded(child: Text(title)),
        TegnalSwitch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

/// `MangaLibraryToolsView`'s import section in the comics library's settings: one way in, which
/// takes every kind of file from another comics viewer and works out what it is.
class ComicsImportSection extends StatelessWidget {
  const ComicsImportSection({super.key, required this.imports});
  final ImportContext imports;

  @override
  Widget build(BuildContext context) => FormSection(
    prominentHeader: true,
    rowColor: FormColors.listRow.resolveFrom(context),
    header: Text(L10n.text('Import Data')),
    footer: Text(
      L10n.text(
        "Bookmark backups, work catalogs, database exports, app data exports, download folders, manga reader backups, link lists and browser bookmarks. The file's kind is recognized automatically.",
      ),
    ),
    children: [
      SettingsLinkRow(
        title: L10n.text('Import from Another Comics Viewer'),
        icon: CupertinoIcons.square_arrow_down_on_square,
        onTap: () => Navigator.of(context).push(
          CupertinoPageRoute<void>(
            builder: (_) => OtherAppImportView(database: imports.database, startCoverQueue: imports.startCoverQueue, libraryChanged: imports.libraryChanged),
          ),
        ),
      ),
    ],
  );
}

/// `BooruBackupView`'s import section in the image library's settings: the rows before it (the
/// challenge backup) and one way in for every other image viewer's files.
class ImageImportSection extends StatelessWidget {
  const ImageImportSection({super.key, required this.booru, this.leading});
  final BooruContext booru;

  /// Rows that share the section, above the import row.
  final List<Widget> Function(BuildContext context)? leading;

  @override
  Widget build(BuildContext context) => FormSection(
    prominentHeader: true,
    rowColor: FormColors.listRow.resolveFrom(context),
    children: [
      ...?leading?.call(context),
      SettingsLinkRow(
        title: L10n.text('Import from Another Image Viewer'),
        icon: CupertinoIcons.square_arrow_down_on_square,
        onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: booru))),
      ),
    ],
  );
}

/// `OnboardingView(importsOnly:)`: one way in for each kind of library. Either screen takes any
/// file and works out what it is.
Future<void> showImportData(BuildContext context, ImportContext imports) =>
    showAppSheet<void>(context, builder: (context, controller) => _ImportSheetNavigator(imports: imports));

/// The sheet's own pages. The system back gesture goes back a page inside the sheet before it closes the sheet.
class _ImportSheetNavigator extends StatefulWidget {
  const _ImportSheetNavigator({required this.imports});
  final ImportContext imports;

  @override
  State<_ImportSheetNavigator> createState() => _ImportSheetNavigatorState();
}

class _ImportSheetNavigatorState extends State<_ImportSheetNavigator> {
  final _navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    onPopWithResult: (_) => _navigator.currentState?.maybePop(),
    child: Navigator(
      key: _navigator,
      onGenerateRoute: (_) => CupertinoPageRoute<void>(builder: (context) => ImportDataView(imports: widget.imports)),
    ),
  );
}

class ImportDataView extends StatelessWidget {
  const ImportDataView({super.key, required this.imports});
  final ImportContext imports;

  static const _borderedFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F767680), darkColor: Color(0x3D767680));

  Widget _card(BuildContext context, {required IconData icon, required String title, required String kinds, required WidgetBuilder page}) {
    final label = TegnalColors.label.resolveFrom(context);
    final tint = TegnalColors.tint.resolveFrom(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: ShapeDecoration(
        color: FormColors.row.resolveFrom(context),
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 22, color: label),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
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
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: page)),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                // `.bordered`: the tertiary system fill under tinted text.
                decoration: ShapeDecoration(color: _borderedFill.resolveFrom(context), shape: const StadiumBorder()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DocumentBadgePlus(color: tint),
                    const SizedBox(width: 6),
                    Text(L10n.text('Import'), style: TegnalType.style(17, color: tint)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final media = MediaQuery.of(context);
    void close() => Navigator.of(context, rootNavigator: true).pop();
    return ColoredBox(
      color: FormColors.background.resolveFrom(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.fromLTRB(24, 69 + 28, 24, 24 + 94 + media.padding.bottom),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(CupertinoIcons.square_arrow_down, size: 50, color: tint),
                ),
                const SizedBox(height: 20),
                Text(
                  L10n.text('Import Data'),
                  style: TegnalType.style(28, weight: FontWeight.w700, color: label),
                ),
                const SizedBox(height: 20),
                _card(
                  context,
                  icon: Symbols.photoFill,
                  title: L10n.text('Other Image Viewer'),
                  kinds: '.abbj · .json · .db',
                  page: (_) => AnimeBoxesImportView(booru: imports.booru, inSheet: true),
                ),
                const SizedBox(height: 20),
                _card(
                  context,
                  icon: Symbols.bookFill,
                  title: L10n.text('Other Comics Viewer'),
                  kinds: '.db · .json · .tachibk · .html · .txt',
                  page: (_) => OtherAppImportView(
                    database: imports.database,
                    startCoverQueue: imports.startCoverQueue,
                    libraryChanged: imports.libraryChanged,
                    inSheet: true,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SheetNavigationBar(
              title: '',
              trailing: GlassTextButton(label: L10n.text('Done'), onPressed: close),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 12, 24, 12 + media.padding.bottom),
              // `.bar` over the sheet.
              color: FormColors.row.resolveFrom(context).withValues(alpha: 0.94),
              child: GestureDetector(
                onTap: close,
                child: Container(
                  // A large prominent button with 10 pt of extra vertical padding.
                  height: 69,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(color: tint, shape: const StadiumBorder()),
                  child: Text(
                    L10n.text('Done'),
                    style: TegnalType.style(17, weight: FontWeight.w600, color: const Color(0xFFFFFFFF)),
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

/// `ImportReminderBanner`: under each root header until the person opens or closes it.
class ImportReminderBanner extends StatefulWidget {
  const ImportReminderBanner({super.key, required this.imports});
  final ImportContext imports;

  /// The same flag as the native `onboarding.importReminderDismissed`.
  static const dismissedKey = 'onboarding.importReminderDismissed';

  /// Height the banner takes, gap included, so root lists can start below it.
  static const double height = 60 + 8;

  /// Whether the banner shows, so a root screen can make room for it.
  static bool isVisible(ImportContext imports) => !(imports.booru.preferences.boolean(dismissedKey) ?? false);

  @override
  State<ImportReminderBanner> createState() => _ImportReminderBannerState();
}

class _ImportReminderBannerState extends State<ImportReminderBanner> {
  void _hide() {
    widget.imports.booru.preferences.set(ImportReminderBanner.dismissedKey, true);
    // Every root shares the flag; the app rebuilds them around the change.
    widget.imports.booru.state.appearanceChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!ImportReminderBanner.isVisible(widget.imports)) return const SizedBox.shrink();
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: ShapeDecoration(
          color: TegnalColors.secondaryBackground.resolveFrom(context),
          shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    _hide();
                    showImportData(context, widget.imports);
                  },
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.square_arrow_down, size: 22, color: label),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.text('Import from Other Apps'),
                              style: TegnalType.style(15, weight: FontWeight.w600, color: label),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${L10n.text('Other Image Viewer')} · ${L10n.text('Other Comics Viewer')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TegnalType.style(12, color: secondary),
                            ),
                          ],
                        ),
                      ),
                      Icon(CupertinoIcons.chevron_right, size: 13, color: label),
                    ],
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: L10n.text('Close'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hide,
                child: SizedBox(width: 32, height: 36, child: Icon(CupertinoIcons.xmark, size: 13, color: label)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `WebsiteImportLinks`: the setup screen's ways to bring a library from another image or comics
/// viewer. The image importer opens on the same stack; the comics one in a sheet that ends with Done.
class WebsiteImportLinks extends StatelessWidget {
  const WebsiteImportLinks({super.key, required this.imports});
  final ImportContext imports;

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    Widget link(IconData icon, String title, VoidCallback onTap) => Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(width: 24, child: Icon(icon, size: 19, color: tint)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(title, style: TegnalType.style(17, color: tint)),
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        link(
          CupertinoIcons.square_arrow_down_on_square,
          L10n.text('Import from Another Image Viewer'),
          () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: imports.booru))),
        ),
        const SizedBox(height: 14),
        link(
          CupertinoIcons.square_arrow_down,
          L10n.text('Import from Another Comics Viewer'),
          () => showAppSheet<void>(
            context,
            builder: (context, controller) => Navigator(
              onGenerateRoute: (_) => CupertinoPageRoute<void>(
                builder: (context) => OtherAppImportView(
                  database: imports.database,
                  startCoverQueue: imports.startCoverQueue,
                  libraryChanged: imports.libraryChanged,
                  inSheet: true,
                  done: true,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// `doc.badge.plus`: a page with a folded corner and a filled plus badge at its lower left.
class _DocumentBadgePlus extends StatelessWidget {
  const _DocumentBadgePlus({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size.square(22), painter: _DocumentBadgePlusPainter(color));
}

class _DocumentBadgePlusPainter extends CustomPainter {
  _DocumentBadgePlusPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * unit
      ..strokeJoin = StrokeJoin.round;
    final page = Path()
      ..moveTo(8 * unit, 2.5 * unit)
      ..lineTo(14.5 * unit, 2.5 * unit)
      ..lineTo(20 * unit, 8 * unit)
      ..lineTo(20 * unit, 19 * unit)
      ..arcToPoint(Offset(17.5 * unit, 21.5 * unit), radius: Radius.circular(2.5 * unit))
      ..lineTo(12 * unit, 21.5 * unit)
      ..moveTo(5.5 * unit, 12 * unit)
      ..lineTo(5.5 * unit, 5 * unit)
      ..arcToPoint(Offset(8 * unit, 2.5 * unit), radius: Radius.circular(2.5 * unit))
      ..moveTo(14.5 * unit, 2.5 * unit)
      ..lineTo(14.5 * unit, 8 * unit)
      ..lineTo(20 * unit, 8 * unit);
    canvas.drawPath(page, stroke);
    final badge = Offset(6 * unit, 18 * unit);
    canvas.drawCircle(badge, 5 * unit, Paint()..color = color);
    final plus = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1.5 * unit
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(badge.translate(-2.4 * unit, 0), badge.translate(2.4 * unit, 0), plus);
    canvas.drawLine(badge.translate(0, -2.4 * unit), badge.translate(0, 2.4 * unit), plus);
  }

  @override
  bool shouldRepaint(_DocumentBadgePlusPainter old) => old.color != color;
}
