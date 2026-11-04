import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/anime_boxes_import.dart';
import '../../core/migration/manga_viewer_import.dart';
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
import '../design/alert_dialog.dart';

/// What the import screens change: both libraries, and the cover queue that fills
/// imported comics afterwards.
class ImportContext {
  const ImportContext({required this.booru, required this.database, this.startCoverQueue});
  final BooruContext booru;
  final AppDatabase database;
  final VoidCallback? startCoverQueue;
}

/// `AnimeBoxesImportView`: reads an Anime Boxes backup, shows what it holds and merges it.
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
        if (await file.length() > AnimeBoxesBackup.maximumBytes) throw AnimeBoxesImportError.tooLarge;
        final backup = AnimeBoxesBackup.read(file);
        if (mounted) setState(() => _backup = backup);
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
    final label = TegnalColors.label.resolveFrom(context);
    final backup = _backup;
    final result = _result;
    final folders = widget.booru.store.folders();
    return SettingsPage(
      title: 'Anime Boxes',
      sheet: widget.inSheet,
      children: [
        FormSection(
          rowColor: row,
          children: [
            FormRow(
              separatorInset: settingsIconInset,
              child: Row(
                children: [
                  Icon(CupertinoIcons.cube_box_fill, size: 22, color: tint),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      L10n.text('Import from Anime Boxes'),
                      style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                    ),
                  ),
                ],
              ),
            ),
            FormRow(
              child: Text(
                L10n.text('Export a backup in Anime Boxes, then choose the .abbj file here. Review its contents before importing.'),
                style: TegnalType.style(15, color: secondary),
              ),
            ),
            SettingsLinkRow(
              title: L10n.text(backup == null ? 'Choose Backup File' : 'Choose Another File'),
              symbol: (color) => _DocumentBadgePlus(color: color),
              tinted: true,
              chevron: false,
              onTap: _loading ? null : _choose,
            ),
          ],
        ),
        if (_loading) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                child: Row(
                  children: [
                    const CupertinoActivityIndicator(),
                    const SizedBox(width: 10),
                    Text(L10n.text('Importing…'), style: TegnalType.style(17, color: secondary)),
                  ],
                ),
              ),
            ],
          ),
        ],
        if (_error case final error?) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                child: Text(error, style: TegnalType.style(17, color: SystemColors.red.resolveFrom(context))),
              ),
            ],
          ),
        ],
        if (result != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            children: [
              FormRow(
                child: Row(
                  children: [
                    Icon(CupertinoIcons.checkmark_circle_fill, size: 22, color: SystemColors.green.resolveFrom(context)),
                    const SizedBox(width: 12),
                    Text(L10n.text('Import Complete'), style: TegnalType.style(17, color: SystemColors.green.resolveFrom(context))),
                  ],
                ),
              ),
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
                  ('by-site', L10n.text('Site Folders')),
                  if (!folders.any((folder) => folder.id == 'anime-boxes')) ('anime-boxes', 'Anime Boxes'),
                  for (final folder in folders) (folder.id, folder.displayName),
                ],
                selected: _folderID,
                onSelected: (value) => setState(() => _folderID = value),
              ),
              _Toggle(title: L10n.text('Import Search History'), value: _history, onChanged: (value) => setState(() => _history = value)),
              _Toggle(title: L10n.text('Import Tag Blacklist'), value: _blacklist, onChanged: (value) => setState(() => _blacklist = value)),
              _Toggle(title: L10n.text('Use Server Selection from Backup'), value: _selection, onChanged: (value) => setState(() => _selection = value)),
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

/// Imports from another manga viewer's databases, one at a time, reporting progress.
class _MangaViewerImporter {
  _MangaViewerImporter(this.database);
  final AppDatabase database;
  bool cancelling = false;

  /// The picked file, or null when the person cancelled.
  Future<File?> pick() => const DocumentFiles().openDocument();

  ({int folders, int works, int artists}) importUser(File file) =>
      MangaViewerImportService(database).importUserDatabase(file.path, cancelled: () => cancelling);

  ({int matched, int totalWorks}) match(File file) => MangaViewerImportService(database).matchAndFillWorks(file.path, cancelled: () => cancelling);

  int importCatalog(File file, void Function(int count) progress) =>
      MangaViewerImportService(database).importDataDatabase(file.path, progress: progress, cancelled: () => cancelling);

  static String failure(Object error) => error is ImportCancelled ? L10n.text('The task was canceled.') : L10n.text('Import failed: %@', ['$error']);
}

/// `MangaLibraryToolsView(importOnly:)`: user.db and data.db from another manga viewer.
class MangaViewerImportView extends StatefulWidget {
  const MangaViewerImportView({super.key, required this.database, this.startCoverQueue, this.inSheet = false});
  final AppDatabase database;
  final VoidCallback? startCoverQueue;

  /// In a sheet the page ends with Done instead of going back.
  final bool inSheet;

  @override
  State<MangaViewerImportView> createState() => _MangaViewerImportViewState();
}

class _MangaViewerImportViewState extends State<MangaViewerImportView> {
  late final _importer = _MangaViewerImporter(widget.database);
  bool _importing = false;
  String? _status;

  Future<void> _run(String start, Future<String> Function() work) async {
    setState(() {
      _importing = true;
      _importer.cancelling = false;
      _status = start;
    });
    // Let the status appear before the import holds the database.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    String message;
    try {
      message = await work();
    } on Object catch (error) {
      message = _MangaViewerImporter.failure(error);
    }
    if (!mounted) return;
    setState(() {
      _importing = false;
      _status = message;
    });
  }

  Future<void> _userDatabase() async {
    final file = await _importer.pick();
    if (file == null) return;
    await _run(L10n.text('Preparing user.db…'), () async {
      final result = _importer.importUser(file);
      widget.startCoverQueue?.call();
      return L10n.text('user.db imported: %@ folders, %@ works, %@ artists', ['${result.folders}', '${result.works}', '${result.artists}']);
    });
  }

  Future<void> _dataDatabase() async {
    final file = await _importer.pick();
    if (file == null || !mounted) return;
    final works = widget.database.worksCount();
    final bool? matchOnly;
    if (works > 0) {
      matchOnly = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(L10n.text('How to Import data.db (Catalog)')),
          message: Text(
            L10n.text(
              "data.db is a large catalog that can exceed 500 MB.\n\nChoose 'Fill Only My Library' to extract information for your %@ saved works. This avoids storing hundreds of thousands of unnecessary records.",
              ['$works'],
            ),
          ),
          actions: [
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('⚡️ Fill Only My Library (Recommended)'))),
            CupertinoActionSheetAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('📦 Save Entire Catalog (Background Import)'))),
          ],
          cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(context), child: Text(L10n.text('Cancel'))),
        ),
      );
    } else {
      final whole = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text('Your Library Is Empty')),
          content: Text(
            L10n.text('There are no saved works to match. Import user.db (bookmarks) first, then import data.db to fill the information you need.'),
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Save Entire Catalog'))),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(L10n.text('Cancel (Import user.db First)')),
            ),
          ],
        ),
      );
      matchOnly = whole == true ? false : null;
    }
    if (matchOnly == null) return;
    if (matchOnly) {
      await _run(L10n.text('Matching metadata for your library…'), () async {
        final result = _importer.match(file);
        widget.startCoverQueue?.call();
        return '${L10n.text('Metadata matched! Filled %2\$@ of %1\$@ saved works.', ['${result.totalWorks}', '${result.matched}'])}\n'
            '${L10n.text('Missing covers are downloaded separately in the background.')}';
      });
    } else {
      await _run(L10n.text('Preparing catalog import…'), () async {
        final total = _importer.importCatalog(file, (count) {
          if (mounted && _importing && !_importer.cancelling) setState(() => _status = L10n.text('Importing entire catalog… (%@ records)', ['$count']));
        });
        widget.startCoverQueue?.call();
        return L10n.text('data.db imported: %@ catalog records applied', ['$total']);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = (widget.inSheet ? FormColors.row : FormColors.listRow).resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return SettingsPage(
      title: L10n.text('Import from Another Manga Viewer'),
      sheet: widget.inSheet,
      trailing: widget.inSheet ? GlassTextButton(label: L10n.text('Done'), prominent: true, onPressed: () => Navigator.of(context).pop()) : null,
      children: [
        FormSection(
          rowColor: row,
          prominentHeader: true,
          header: Text(L10n.text('Import Data (Other Manga Viewer)')),
          children: [
            SettingsLinkRow(
              title: L10n.text('Import user.db (Bookmarks, Folders, Artists)'),
              icon: CupertinoIcons.person_crop_rectangle,
              tinted: true,
              chevron: false,
              onTap: _importing ? null : _userDatabase,
            ),
            SettingsLinkRow(
              title: L10n.text('Import data.db (Work Metadata Catalog)'),
              icon: CupertinoIcons.layers,
              tinted: true,
              chevron: false,
              onTap: _importing ? null : _dataDatabase,
            ),
          ],
        ),
        if (_importing || _status != null) ...[
          settingsSectionGap,
          FormSection(
            rowColor: row,
            prominentHeader: true,
            header: Text(L10n.text('Task Status')),
            children: [
              FormRow(
                child: _importing
                    ? Row(
                        children: [
                          const CupertinoActivityIndicator(),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(_status ?? L10n.text('Processing…'), style: TegnalType.style(13, color: TegnalColors.label.resolveFrom(context))),
                          ),
                          GestureDetector(
                            onTap: _importer.cancelling
                                ? null
                                : () => setState(() {
                                    _importer.cancelling = true;
                                    _status = '${L10n.text('Cancel')}…';
                                  }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: ShapeDecoration(color: SystemColors.red.resolveFrom(context).withValues(alpha: 0.15), shape: const StadiumBorder()),
                              child: Text(L10n.text('Cancel'), style: TegnalType.style(13, color: SystemColors.red.resolveFrom(context))),
                            ),
                          ),
                        ],
                      )
                    : Text(_status!, style: TegnalType.style(13, color: secondary)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `OnboardingView(importsOnly:)`: the two importers, each on its own card.
Future<void> showImportData(BuildContext context, ImportContext imports) => showAppSheet<void>(
  context,
  // The sheet sits below the status bar, so its pages lay out from its own top.
  builder: (context, controller) => MediaQuery.removePadding(
    context: context,
    removeTop: true,
    child: Navigator(
      onGenerateRoute: (_) => CupertinoPageRoute<void>(builder: (context) => ImportDataView(imports: imports)),
    ),
  ),
);

class ImportDataView extends StatefulWidget {
  const ImportDataView({super.key, required this.imports});
  final ImportContext imports;

  @override
  State<ImportDataView> createState() => _ImportDataViewState();
}

class _ImportDataViewState extends State<ImportDataView> {
  static const _borderedFill = CupertinoDynamicColor.withBrightness(color: Color(0x1F767680), darkColor: Color(0x3D767680));

  late final _importer = _MangaViewerImporter(widget.imports.database);
  bool _importing = false;
  String _status = '';
  String? _summary;

  /// One file chooser for either database: a user database imports the library, a catalog
  /// fills it.
  Future<void> _choose() async {
    final file = await _importer.pick();
    if (file == null || !mounted) return;
    setState(() {
      _importing = true;
      _summary = null;
      _status = L10n.text('Checking file…');
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      if (MangaViewerImportService.isUserDatabase(file.path)) {
        setState(() => _status = L10n.text('Importing library from user.db…'));
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final result = _importer.importUser(file);
        _summary = L10n.text('user.db imported!\n%@ folders, %@ works', ['${result.folders}', '${result.works}']);
      } else if (MangaViewerImportService.isDataDatabase(file.path)) {
        setState(() => _status = L10n.text('Matching data.db metadata…'));
        await Future<void>.delayed(const Duration(milliseconds: 16));
        final result = _importer.match(file);
        _summary =
            '${L10n.text('data.db matched!\nUpdated %2\$@ of %1\$@ works', ['${result.totalWorks}', '${result.matched}'])}\n'
            '${L10n.text('Missing covers are downloaded separately in the background.')}';
      } else {
        _status = L10n.text('Unsupported database format. Select user.db or data.db.');
      }
      if (_summary != null) widget.imports.startCoverQueue?.call();
    } on Object catch (error) {
      _status = L10n.text('Import error: %@', ['$error']);
    }
    if (mounted) setState(() => _importing = false);
  }

  Widget _card({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: ShapeDecoration(
      color: FormColors.row.resolveFrom(context),
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(20)),
    ),
    child: child,
  );

  Widget _bordered(String title, VoidCallback? onTap) {
    final tint = TegnalColors.tint.resolveFrom(context);
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
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
              Text(title, style: TegnalType.style(17, color: tint)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final media = MediaQuery.of(context);
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(CupertinoIcons.cube_box_fill, size: 22, color: label),
                          const SizedBox(width: 10),
                          Text(
                            'Anime Boxes',
                            style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text('.abbj', style: TegnalType.style(15, color: secondary)),
                      const SizedBox(height: 12),
                      _bordered(
                        L10n.text('Import'),
                        () =>
                            Navigator.of(context)
                                .push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: widget.imports.booru, inSheet: true))),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Symbols.bookFill, size: 22, color: label),
                          const SizedBox(width: 8),
                          Text(
                            L10n.text('Other Manga Viewer'),
                            style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text('user.db · data.db', style: TegnalType.style(15, color: secondary)),
                      const SizedBox(height: 12),
                      _bordered(L10n.text('Choose File'), _importing ? null : _choose),
                      if (_importing) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const CupertinoActivityIndicator(),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_status, style: TegnalType.style(15, color: secondary)),
                            ),
                          ],
                        ),
                      ] else if (_summary case final summary?) ...[
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(CupertinoIcons.checkmark_circle_fill, size: 18, color: SystemColors.green.resolveFrom(context)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(summary, style: TegnalType.style(15, color: SystemColors.green.resolveFrom(context))),
                            ),
                          ],
                        ),
                      ] else if (_status.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(_status, style: TegnalType.style(15, color: SystemColors.red.resolveFrom(context))),
                      ],
                    ],
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
              trailing: GlassTextButton(label: L10n.text('Done'), onPressed: _importing ? null : () => Navigator.of(context, rootNavigator: true).pop()),
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
                onTap: _importing ? null : () => Navigator.of(context, rootNavigator: true).pop(),
                child: Opacity(
                  opacity: _importing ? 0.4 : 1,
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
                            Text('Anime Boxes · Other Manga Viewer', style: TegnalType.style(12, color: secondary)),
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

/// `WebsiteImportLinks`: the setup screen's ways to bring a library from another app.
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
          CupertinoIcons.cube_box,
          L10n.text('Import from Anime Boxes'),
          () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => AnimeBoxesImportView(booru: imports.booru))),
        ),
        const SizedBox(height: 14),
        link(
          CupertinoIcons.square_arrow_down,
          L10n.text('Import from Another Manga Viewer'),
          () => showAppSheet<void>(
            context,
            builder: (context, controller) => MangaViewerImportView(database: imports.database, startCoverQueue: imports.startCoverQueue, inSheet: true),
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
