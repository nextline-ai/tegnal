import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../core/insights.dart';
import '../ui/session_image_provider.dart';

import '../core/app_controller.dart';
import '../core/app_features.dart';
import '../core/drive_sync_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../ui/page_header.dart';
import '../data/backup_codec.dart';
import '../data/backup_files.dart';
import '../data/download_manager.dart';
import '../data/legacy_import.dart';
import '../data/android_bookmarks_import.dart';
import '../data/booru_source_detector.dart';
import '../data/booru_credentials.dart';
import '../data/session_client.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/design_system.dart';
import 'downloads_screen.dart';
import 'drive_sync_screen.dart';
import 'browser_screen.dart';
import 'challenges_screen.dart';
import 'booru_pools_screen.dart';
import 'detail_screen.dart';
import 'onboarding_screen.dart';
import 'insights_screen.dart';
import 'reader_guide.dart';

const _discordAddress = 'https://discord.gg/DFT9Hm66Gz';
const _githubAddress = 'https://github.com/nextline-ai/tegnal';

/// The primary importer accepts only the Android bookmark database schema.
Future<void> showImportAndroidBookmarks(
  BuildContext context,
  AppController controller,
) async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: L10n.tr(context, 'Android bookmark SQLite backup'),
          extensions: const ['sqlite', 'sqlite3', 'db'],
          mimeTypes: const [
            'application/octet-stream',
            'application/x-sqlite3',
            'application/vnd.sqlite3',
          ],
          uniformTypeIdentifiers: const ['public.data'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    final importer = AndroidBookmarksImport(controller.store);
    final summary = await importer.inspectFile(file.path);
    if (!context.mounted) return;
    final confirmed = await _showAndroidBookmarksSummary(
      context,
      summary,
      confirm: true,
    );
    if (!confirmed || !context.mounted) return;
    final imported = await showDialog<LegacyImportSummary>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LibraryImportProgress(
        onImport: (isCancelled, onProgress) => importer.importFile(
          file.path,
          isCancelled: isCancelled,
          onProgress: onProgress,
        ),
      ),
    );
    if (imported == null) return;
    controller.libraryRestored(fillMissingMetadata: true);
    if (context.mounted && imported is AndroidBookmarksSummary) {
      await _showAndroidBookmarksSummary(context, imported);
    }
  } catch (error) {
    if (context.mounted) {
      await showMessage(
        context,
        'Unable to Import',
        error is FormatException
            ? '${L10n.tr(context, error.message)}\n\n${L10n.tr(context, 'No library data was changed. For other formats, use Other Backup Formats in Settings.')}'
            : 'The selected file could not be imported. Your current library has been kept.',
      );
    }
  }
}

Future<bool> _showAndroidBookmarksSummary(
  BuildContext context,
  AndroidBookmarksSummary summary, {
  bool confirm = false,
}) async {
  final counts = <String>[
    '${summary.workCount} ${L10n.tr(context, 'Works')}',
    '${summary.folderCount} ${L10n.tr(context, 'Folders')}',
    '${summary.artistCount} ${L10n.tr(context, 'Artists')}',
    '${summary.searchCount} ${L10n.tr(context, 'Search history records')}',
    '${summary.readLogCount} ${L10n.tr(context, 'Read-log records (preserved)')}',
    '${summary.cropCount} ${L10n.tr(context, 'Crop records (preserved)')}',
    '${summary.preservedRecordCount} ${L10n.tr(context, 'Original records kept locally')}',
    if (summary.duplicates > 0)
      '${summary.duplicates} ${L10n.tr(context, 'Duplicate records')}',
    if (summary.skipped > 0)
      '${summary.skipped} ${L10n.tr(context, 'Skipped records')}',
    if (summary.unsupportedDownloadCount > 0)
      '${summary.unsupportedDownloadCount} ${L10n.tr(context, 'Download records not imported')}',
  ].join('\n');
  final details = <String>[
    counts,
    if (summary.preservedRecordCount > 0)
      L10n.tr(
        context,
        'Original source records are kept only on this device and are not included in TEGNAL JSON backups.',
      ),
    if (summary.readLogCount > 0 || summary.cropCount > 0)
      L10n.tr(
        context,
        'Read logs and crop records are preserved as original data. Reader positions and image crops are not applied.',
      ),
    if (confirm)
      L10n.tr(
        context,
        'Existing items will be merged. Other saved items will remain.',
      ),
  ].join('\n\n');
  return await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: Text(
            L10n.tr(context, confirm ? 'Import Library' : 'Import Complete'),
          ),
          content: Text(details),
          actions: [
            if (confirm)
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(L10n.tr(context, 'Cancel')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(L10n.tr(context, confirm ? 'Import' : 'OK')),
            ),
          ],
        ),
      ) ??
      false;
}

/// Other formats remain available explicitly from Settings.
Future<void> showImportLegacy(
  BuildContext context,
  AppController controller,
) async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: L10n.tr(context, 'Library backups (.db, .abbj)'),
          extensions: ['db', 'abbj'],
          mimeTypes: [
            'application/octet-stream',
            'application/x-sqlite3',
            'application/json',
          ],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    final importer = LegacyImport(controller.store);
    final summary = await importer.inspectFile(file.path);
    if (!context.mounted) return;
    var fullCatalog = false;
    if (summary.isCatalog) {
      final choice = await showModalBottomSheet<bool>(
        context: context,
        useRootNavigator: true,
        useSafeArea: true,
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                L10n.tr(context, '⚡️ Fill Only My Library (Recommended)'),
              ),
              onTap: () => Navigator.pop(sheet, false),
            ),
            ListTile(
              title: Text(
                L10n.tr(context, '📦 Save Entire Catalog (Background Import)'),
              ),
              onTap: () => Navigator.pop(sheet, true),
            ),
            ListTile(
              title: Text(L10n.tr(context, 'Cancel')),
              onTap: () => Navigator.pop(sheet),
            ),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      fullCatalog = choice;
    }
    if (await confirmAction(
      context,
      'Import Library',
      '${summary.workCount} ${L10n.tr(context, 'Works')} · ${summary.folderCount} ${L10n.tr(context, 'Folders')}\n${L10n.tr(context, 'Existing items will be merged. Other saved items will remain.')}',
      action: 'Import',
    )) {
      if (!context.mounted) return;
      final imported = await showDialog<LegacyImportSummary>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LibraryImportProgress(
          onImport: (isCancelled, onProgress) => importer.importFile(
            file.path,
            fullCatalog: fullCatalog,
            isCancelled: isCancelled,
            onProgress: onProgress,
          ),
        ),
      );
      if (imported == null) return;
      controller.libraryRestored(fillMissingMetadata: true);
      if (context.mounted) {
        await showMessage(
          context,
          'Import Complete',
          '${imported.workCount} ${L10n.tr(context, 'Works')} · ${imported.folderCount} ${L10n.tr(context, 'Folders')}',
        );
      }
    }
  } catch (error) {
    if (context.mounted) {
      await showMessage(
        context,
        'Unable to Import',
        error is FormatException ? error.message : 'The selected file could not be imported. Your current library has been kept.',
      );
    }
  }
}

class _LibraryImportProgress extends StatefulWidget {
  const _LibraryImportProgress({required this.onImport});
  final Future<LegacyImportSummary> Function(
    bool Function() isCancelled,
    ValueChanged<int> onProgress,
  )
  onImport;
  @override
  State<_LibraryImportProgress> createState() => _LibraryImportProgressState();
}

class _LibraryImportProgressState extends State<_LibraryImportProgress> {
  bool _cancelled = false;
  int _count = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final result = await widget.onImport(() => _cancelled, (count) {
        if (mounted) setState(() => _count = count);
      });
      if (mounted) Navigator.pop(context, result);
    } on LegacyImportCancelled {
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? L10n.tr(context, error.message)
              : L10n.tr(
                  context,
                  'The selected file could not be imported. Your current library has been kept.',
                ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _error != null,
    child: AlertDialog(
      title: Text(L10n.tr(context, 'Import Library')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error == null) const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_error ?? '${L10n.tr(context, 'Processing…')} $_count'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _error != null
              ? () => Navigator.pop(context)
              : _cancelled
              ? null
              : () => setState(() => _cancelled = true),
          child: Text(L10n.tr(context, _error != null ? 'Close' : 'Cancel')),
        ),
      ],
    ),
  );
}

/// Restores a native-compatible JSON backup after inspecting it first.
Future<void> showRestoreLibraryBackup(
  BuildContext context,
  AppController controller,
) async {
  try {
    final text = await BackupFiles.pick();
    if (text == null || !context.mounted) return;
    final codec = BackupCodec(controller.store);
    final summary = codec.inspect(text);
    final confirmed = await confirmAction(
      context,
      'Restore Backup',
      '${summary.workCount} ${L10n.tr(context, 'Works')} · ${summary.folderCount} ${L10n.tr(context, 'Folders')}\n${L10n.tr(context, 'Existing items will be merged. Other saved items will remain.')}',
      action: 'Restore',
    );
    if (!confirmed || !context.mounted) return;
    codec.importJson(text);
    controller.libraryRestored(fillMissingMetadata: true);
    if (context.mounted) {
      await showMessage(
        context,
        'Restore Complete',
        'Your libraries have been restored.',
      );
    }
  } catch (error) {
    if (context.mounted) {
      await showMessage(
        context,
        'Unable to Complete',
        error is FormatException ? error.message : 'Unable to read or restore the backup. Your current library has been kept.',
      );
    }
  }
}

Future<SourceConfig?> showAddSource(
  BuildContext context,
  AppController controller, {
  AppMode? mode,
  BooruSourceDetector? detector,
  bool autoDetectMode = false,
}) => showModalBottomSheet<SourceConfig>(
  context: context,
  useRootNavigator: true,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => _SourceForm(
    controller: controller,
    mode: mode ?? controller.mode,
    detector: detector ?? BooruSourceDetector(),
    autoDetectMode: autoDetectMode,
  ),
);

class _SourceForm extends StatefulWidget {
  const _SourceForm({
    required this.controller,
    required this.mode,
    required this.detector,
    required this.autoDetectMode,
  });
  final AppController controller;
  final AppMode mode;
  final BooruSourceDetector detector;
  final bool autoDetectMode;
  @override
  State<_SourceForm> createState() => _SourceFormState();
}

enum _SourceDetectionStatus { idle, checking, identified, unknown, failed }

class _SourceFormState extends State<_SourceForm> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  Timer? _detectionDebounce;
  Completer<void>? _detectionAbort;
  int _detectionGeneration = 0;
  _SourceDetectionStatus _detectionStatus = _SourceDetectionStatus.idle;
  SourceKind? _detectedKind;
  SourceKind? _manualKind;
  String? _error;

  SourceKind? get _sourceKind {
    if (widget.autoDetectMode) return _manualKind ?? _detectedKind;
    if (widget.mode == AppMode.manga) return SourceKind.manga;
    return _manualKind ?? _detectedKind;
  }

  Iterable<SourceKind> get _manualKinds => SourceKind.values.where(
    (kind) => widget.autoDetectMode || kind != SourceKind.manga,
  );

  @override
  void dispose() {
    _detectionDebounce?.cancel();
    _cancelDetection();
    _address.dispose();
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final kind = _sourceKind;
    if (kind == null) return;
    try {
      final source = widget.controller.addSource(
        _address.text,
        kind,
        name: _name.text,
      );
      Navigator.pop(context, source);
    } catch (e) {
      setState(() => _error = AppController.errorMessage(e));
    }
  }

  void _onAddressChanged(String value) {
    _detectionDebounce?.cancel();
    _cancelDetection();
    final generation = ++_detectionGeneration;
    _error = null;
    _manualKind = null;
    _detectedKind = null;
    if ((!widget.autoDetectMode && widget.mode != AppMode.booru) ||
        value.trim().isEmpty) {
      setState(() => _detectionStatus = _SourceDetectionStatus.idle);
      return;
    }

    Uri? url;
    try {
      url = SourceConfig.validateUrl(value);
    } on FormatException {
      setState(() => _detectionStatus = _SourceDetectionStatus.idle);
      return;
    }
    final suggested = BooruSourceDetector.suggestFromHost(url);
    if (suggested != null) {
      setState(() {
        _detectedKind = suggested;
        _detectionStatus = _SourceDetectionStatus.identified;
      });
      return;
    }
    setState(() => _detectionStatus = _SourceDetectionStatus.checking);
    _detectionDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _identify(url!, generation),
    );
  }

  Future<void> _identify(Uri url, int generation) async {
    final abort = Completer<void>();
    _detectionAbort = abort;
    try {
      final kind = await widget.detector.detect(
        url,
        abortTrigger: abort.future,
        allowComics: widget.autoDetectMode,
      );
      if (!mounted || generation != _detectionGeneration) return;
      setState(() {
        _detectedKind = kind;
        _detectionStatus = kind == null
            ? _SourceDetectionStatus.unknown
            : _SourceDetectionStatus.identified;
      });
    } on http.RequestAbortedException {
      // Address changes and sheet dismissal cancel the stale request.
    } catch (_) {
      if (!mounted || generation != _detectionGeneration) return;
      setState(() => _detectionStatus = _SourceDetectionStatus.failed);
    } finally {
      if (identical(_detectionAbort, abort)) _detectionAbort = null;
    }
  }

  void _cancelDetection() {
    final abort = _detectionAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _detectionAbort = null;
  }

  void _retryDetection() {
    final url = _tryAddress(_address.text);
    if (url == null) return;
    final generation = ++_detectionGeneration;
    setState(() {
      _manualKind = null;
      _detectedKind = null;
      _error = null;
      _detectionStatus = _SourceDetectionStatus.checking;
    });
    _identify(url, generation);
  }

  static Uri? _tryAddress(String value) {
    try {
      return SourceConfig.validateUrl(value);
    } on FormatException {
      return null;
    }
  }

  static String _engineName(SourceKind kind) => switch (kind) {
    SourceKind.danbooru => 'JSON Board API (posts.json)',
    SourceKind.gelbooru => 'DAPI JSON Board API',
    SourceKind.oldGelbooru => 'Legacy HTML Board',
    SourceKind.moebooru => 'JSON Board API (post.json)',
    SourceKind.manga => 'Comics Mode',
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
      final screenHeight = MediaQuery.sizeOf(context).height;
      final viewportHeight = (screenHeight - bottomInset).clamp(
        0.0,
        screenHeight,
      );
      final availableHeight = constraints.maxHeight < viewportHeight
          ? constraints.maxHeight
          : viewportHeight;
      final effectiveBottomInset = constraints.maxHeight > viewportHeight
          ? bottomInset
          : 0.0;
      return Padding(
        padding: EdgeInsets.only(bottom: effectiveBottomInset),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: availableHeight),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(L10n.tr(context, 'Cancel')),
                          ),
                          Expanded(
                            child: Text(
                              L10n.tr(context, 'Connect a Website'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 60),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _address,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        onChanged: _onAddressChanged,
                        decoration: InputDecoration(
                          hintText: 'https://',
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: L10n.tr(context, 'Name (Optional)'),
                          contentPadding: const EdgeInsets.all(14),
                        ),
                      ),
                      if (widget.mode == AppMode.booru) ...[
                        const SizedBox(height: 14),
                        if (_detectionStatus == _SourceDetectionStatus.checking)
                          Row(
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(L10n.tr(context, 'Identifying website…')),
                            ],
                          ),
                        if (_detectionStatus ==
                                _SourceDetectionStatus.identified &&
                            _detectedKind != null)
                          Builder(
                            builder: (context) {
                              final kind = _detectedKind!;
                              final modeLabel = L10n.tr(
                                context,
                                kind == SourceKind.manga
                                    ? 'Comics Mode'
                                    : 'Image Mode',
                              );
                              return Row(
                                children: [
                                  const Icon(Icons.check_circle, size: 26),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(modeLabel)),
                                ],
                              );
                            },
                          ),
                        if (_detectionStatus ==
                                _SourceDetectionStatus.unknown ||
                            _detectionStatus ==
                                _SourceDetectionStatus.failed) ...[
                          Text(
                            L10n.tr(
                              context,
                              'Couldn’t identify this website. Check the connection or select its mode manually.',
                            ),
                          ),
                          if (_detectionStatus == _SourceDetectionStatus.failed)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: _retryDetection,
                                icon: const Icon(Icons.refresh, size: 24),
                                label: Text(L10n.tr(context, 'Try Again')),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(L10n.tr(context, 'Mode')),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final kind in _manualKinds)
                                ChoiceChip(
                                  label: Text(
                                    kind == SourceKind.manga
                                        ? L10n.tr(context, 'Comics Mode')
                                        : L10n.tr(context, _engineName(kind)),
                                  ),
                                  selected: _manualKind == kind,
                                  onSelected: (_) => setState(() {
                                    _manualKind = kind;
                                    _error = null;
                                  }),
                                ),
                            ],
                          ),
                        ],
                      ],
                      const SizedBox(height: 16),
                      Text(
                        L10n.tr(
                          context,
                          'Your library stays on this device. Only websites you connect receive browsing requests.',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFFF3B30)),
                          ),
                        ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _sourceKind == null ? null : _submit,
                          child: Text(L10n.tr(context, 'Add')),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _BlockedTagsDialog extends StatefulWidget {
  const _BlockedTagsDialog({required this.initialValue});
  final String initialValue;

  @override
  State<_BlockedTagsDialog> createState() => _BlockedTagsDialogState();
}

class _BlockedTagsDialogState extends State<_BlockedTagsDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(L10n.tr(context, 'Blocked Tags')),
    content: Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Text(
            L10n.tr(
              context,
              'One rule per line. Use tags such as landscape, id:123 or artist:name. Space-separated tags must all match. Use -tag for exceptions and * for wildcards.',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _text,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: L10n.tr(context, 'Blocked Tags'),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(L10n.tr(context, 'Cancel')),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: Text(L10n.tr(context, 'Save')),
      ),
    ],
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.downloads,
    this.driveSync,
    this.mode,
    this.onOpen,
    this.onOpenSequence,
  });
  final AppController controller;
  final DownloadManager downloads;
  final DriveSyncController? driveSync;

  /// Mode captured when this settings route is created.
  final AppMode? mode;
  final ValueChanged<ContentItem>? onOpen;
  final void Function(ContentItem, List<ContentItem>)? onOpenSequence;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _working = false;
  late final AppMode _mode = widget.mode ?? widget.controller.mode;
  @override
  void initState() {
    super.initState();
    widget.controller.presentDiscordInvitationIfDue();
  }

  Future<void> _importLegacy() async {
    if (_working) {
      return;
    }
    setState(() => _working = true);
    try {
      await showImportLegacy(context, widget.controller);
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _importAndroidBookmarks() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await showImportAndroidBookmarks(context, widget.controller);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _backup(bool exporting) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      final codec = BackupCodec(widget.controller.store);
      if (exporting) {
        final saved = await BackupFiles.export(codec.exportJson());
        if (saved && mounted) {
          await showMessage(
            context,
            'Backup Exported',
            'Keep this file in a safe place. Downloaded media and account credentials are not included.',
          );
        }
      } else {
        final text = await BackupFiles.pick();
        if (text == null || !mounted) return;
        final summary = codec.inspect(text);
        final confirmed = await confirmAction(
          context,
          'Restore Backup',
          '${summary.workCount} ${L10n.tr(context, 'Works')} · ${summary.folderCount} ${L10n.tr(context, 'Folders')}\n${L10n.tr(context, 'Existing items will be merged. Other saved items will remain.')}',
          action: 'Restore',
        );
        if (confirmed) {
          codec.importJson(text);
          widget.controller.libraryRestored(fillMissingMetadata: true);
          if (mounted) {
            await showMessage(
              context,
              'Restore Complete',
              'Your libraries have been restored.',
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Complete',
          e is FormatException ? e.message : 'Unable to read or save the backup. Your current library has been kept.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _select(
    String key,
    String current,
    Map<String, String> options,
  ) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => RadioGroup<String>(
        groupValue: current,
        onChanged: (value) => Navigator.pop(context, value),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final option in options.entries)
                  RadioListTile<String>(
                    value: option.key,
                    title: Text(L10n.tr(context, option.value)),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(L10n.tr(context, 'Cancel')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result != null) {
      widget.controller.setPreference(
        key,
        (key.startsWith('preview') || key.startsWith('historyRetention'))
            ? int.parse(result)
            : result,
      );
    }
  }

  Future<void> _source(SourceConfig source, AppMode mode) async {
    if (source.mode != mode) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: Text(source.name),
                ),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Text(source.baseUrl.toString()),
              ),

              TextButton(
                onPressed: () => Navigator.pop(context, 'select'),
                child: Text(L10n.tr(context, 'Use This Server')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'rename'),
                child: Text(L10n.tr(context, 'Rename')),
              ),
              if (source.mode == AppMode.booru &&
                  source.kind != SourceKind.oldGelbooru)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'credentials'),
                  child: Text(L10n.tr(context, 'Additional Options')),
                ),
              if (BrowserSession.supported)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'cookies'),
                  child: Text(L10n.tr(context, 'Cookies')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'blacklist'),
                child: Text(L10n.tr(context, 'Blocked Tags')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'browser'),
                child: Text(L10n.tr(context, 'Validate Client')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'remove'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: Text(L10n.tr(context, 'Remove Server')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(L10n.tr(context, 'Cancel')),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'browser') {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BrowserScreen(url: source.baseUrl),
        ),
      );
      return;
    }
    if (action == 'rename') {
      final name = await _nameSource(source);
      if (name != null && name.trim().isNotEmpty) {
        widget.controller.store.saveSource(
          SourceConfig(
            id: source.id,
            name: name.trim(),
            baseUrl: source.baseUrl,
            kind: source.kind,
          ),
        );
        widget.controller.changed();
      }
    }
    if (action == 'credentials') await _credentials(source);
    if (action == 'cookies') await _cookies(source);
    if (action == 'select') widget.controller.selectSource(source);
    if (mounted &&
        action == 'remove' &&
        await confirmAction(
          context,
          'Remove Server',
          'Saved works will remain in your library.',
          action: 'Remove',
        )) {
      widget.controller.removeSource(source);
    }
    if (action == 'blacklist' && mounted) {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => _BlockedTagsDialog(
          initialValue: widget.controller.store.setting(
            'blacklist.${source.id}',
            '',
          ) as String,
        ),
      );
      if (value != null) {
        widget.controller.setPreference('blacklist.${source.id}', value);
      }
    }
  }

  Future<String?> _nameSource(SourceConfig source) async {
    final input = TextEditingController(text: source.name);
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(L10n.tr(context, 'Rename')),
        content: TextField(controller: input, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, input.text),
            child: Text(L10n.tr(context, 'Save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    return value;
  }

  Future<void> _credentials(SourceConfig source) async {
    BooruCredentials credentials;
    try {
      credentials = await BooruCredentialsStore.read(source);
    } catch (_) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Complete',
          'Secure storage is unavailable.',
        );
      }
      return;
    }
    if (!mounted) return;
    final account = TextEditingController(text: credentials.account);
    final secret = TextEditingController(text: credentials.secret);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(source.name),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: account,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: L10n.tr(
                  context,
                  source.kind == SourceKind.gelbooru ? 'User ID' : 'Username',
                ),
              ),
            ),
            TextField(
              controller: secret,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: L10n.tr(
                  context,
                  source.kind == SourceKind.moebooru
                      ? 'Password Hash'
                      : 'API Key',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(L10n.tr(context, 'Save')),
          ),
        ],
      ),
    );
    if (result == true) {
      try {
        await BooruCredentialsStore.save(
          source,
          BooruCredentials(
            account: account.text.trim(),
            secret: secret.text.trim(),
          ),
        );
      } catch (error) {
        if (mounted) {
          await showMessage(
            context,
            'Unable to Complete',
            error is FormatException
                ? error.message
                : 'Secure storage is unavailable.',
          );
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    account.dispose();
    secret.dispose();
  }

  Future<void> _cookies(SourceConfig source) async {
    try {
      final cookies = await BrowserSession.cookiesFor(source.baseUrl);
      if (!mounted) return;
      final reset = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: Text(L10n.tr(context, 'Cookies')),
          content: SelectableText(
            cookies.isEmpty
                ? L10n.tr(context, 'No Cookies')
                : cookies.join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(L10n.tr(context, 'Close')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(L10n.tr(context, 'Reset Cookies')),
            ),
          ],
        ),
      );
      if (reset == true &&
          mounted &&
          await confirmAction(
            context,
            'Reset Cookies?',
            'Reset cookies visible at this website address and its local website storage. Other paths may retain sign-ins. Your favorites and API key are kept.',
            action: 'Reset Cookies',
          )) {
        await BrowserSession.resetCookies(source.baseUrl);
      }
    } catch (_) {
      if (mounted) {
        await showMessage(
          context,
          'Unable to Complete',
          'Unable to read the website session.',
        );
      }
    }
  }

  Future<void> _openPools(AppMode mode) async {
    final sources = widget.controller.selectedSources(mode);
    if (sources.isEmpty) {
      await showMessage(context, 'Pools', 'No servers selected');
      return;
    }
    SourceConfig? source = sources.first;
    if (sources.length > 1) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => RadioGroup<String>(
          groupValue: source!.id,
          onChanged: (value) => Navigator.pop(context, value),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final candidate in sources)
                    RadioListTile<String>(
                      value: candidate.id,
                      title: Text(candidate.name),
                      subtitle: Text(candidate.baseUrl.host),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(L10n.tr(context, 'Cancel')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (!mounted || selected == null) return;
      source = sources
          .where((candidate) => candidate.id == selected)
          .firstOrNull;
    }
    if (!mounted || source == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BooruPoolsScreen(
          controller: widget.controller,
          source: source!,
          onOpen: widget.onOpen ?? _openPoolItem,
          onOpenSequence: widget.onOpenSequence,
        ),
      ),
    );
  }

  void _openPoolItem(ContentItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          controller: widget.controller,
          item: item,
          downloads: widget.downloads,
          onSearch: (_) {},
        ),
      ),
    );
  }

  void _openLibraryManagement() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _LibraryManagementScreen(
        controller: widget.controller,
        onExport: () => _backup(true),
        onRestore: () => _backup(false),
        onImport: _importAndroidBookmarks,
        onImportOther: _importLegacy,
      ),
    ),
  );

  Widget _togglePreference(String title, String key, {bool fallback = false}) =>
      _SettingsRow(
        title: title,
        trailing: TegnalSwitch(
          semanticLabel: L10n.tr(context, title),
          value: widget.controller.store.setting(key, fallback) == true,
          onChanged: (value) => widget.controller.setPreference(key, value),
        ),
      );

  Future<void> _editText(
    String title,
    String key, {
    String fallback = '',
  }) async {
    final input = TextEditingController(
      text: widget.controller.store.setting(key, fallback) as String,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(L10n.tr(context, title)),
        content: TextField(
          controller: input,
          minLines: 3,
          maxLines: 7,
          autocorrect: false,
          decoration: InputDecoration(hintText: L10n.tr(context, title)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, input.text.trim()),
            child: Text(L10n.tr(context, 'Save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (value != null) widget.controller.setPreference(key, value);
  }

  Widget _segments<T>(String key, T current, Map<T, String> options) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        segments: [
          for (final option in options.entries)
            ButtonSegment<T>(
              value: option.key,
              label: Text(L10n.tr(context, option.value), maxLines: 1),
            ),
        ],
        style: SegmentedButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          selectedForegroundColor: Theme.of(context).colorScheme.onSurface,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF303034)
              : const Color(0xFFE5E5EA),
          selectedBackgroundColor:
              Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF636366)
              : Colors.white,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
          ),
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          textStyle: const TextStyle(
            fontFamily: 'Pretendard',
            fontFamilyFallback: ['Pretendard JP'],
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
          visualDensity: VisualDensity.compact,
        ),
        selected: {current},
        showSelectedIcon: false,
        onSelectionChanged: (value) =>
            widget.controller.setPreference(key, value.first),
      ),
    ),
  );

  Widget _columnPicker(String title, String kind) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
        child: Text(
          L10n.tr(context, title),
          style: const TextStyle(fontSize: 16),
        ),
      ),
      _segments<int>(
        '$kind.${_mode.name}',
        widget.controller.columns(kind, _mode),
        {0: 'Automatic', for (var i = 1; i <= 5; i++) i: '$i'},
      ),
    ],
  );

  Future<void> _servers() async => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(
          leading: const TegnalBackButton(),
          title: Text(L10n.tr(context, 'Servers')),
        ),
        body: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SettingsGroup(
                children: [
                  for (final source in widget.controller.sources(_mode))
                    _SettingsRow(
                      title: source.name,
                      subtitle: source.baseUrl.host,
                      icon: Icons.dns_outlined,
                      trailing: _mode == AppMode.booru
                          ? Checkbox(
                              value: widget.controller
                                  .selectedSources(_mode)
                                  .any((selected) => selected.id == source.id),
                              onChanged: (enabled) {
                                final selected = widget.controller
                                    .selectedSources(_mode)
                                    .where(
                                      (selected) => selected.id != source.id,
                                    )
                                    .toList();
                                if (enabled == true) selected.add(source);
                                widget.controller.selectSources(selected);
                              },
                            )
                          : null,
                      onTap: () => _source(source, _mode),
                    ),
                  _SettingsRow(
                    title: 'Connect a Website',
                    icon: Icons.add,
                    onTap: () =>
                        showAddSource(context, widget.controller, mode: _mode),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _openLink(String address) async {
    final uri = Uri.parse(address);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      await showMessage(context, 'Unable to Open', 'No browser is available.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final mode = _mode;
      final booru = mode == AppMode.booru;
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: TegnalFloatingHeader(
          header: TegnalPageHeader(
            controller: c,
            title: booru ? 'More' : 'Settings',
            trailing: booru
                ? IconButton(
                    onPressed: _servers,
                    tooltip: L10n.tr(context, 'Servers'),
                    icon: const Icon(Icons.dns_outlined),
                  )
                : null,
          ),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              tegnalHeaderExtent + 30,
              16,
              navigationScrollInset(context, gap: 28),
            ),
            children: [
              if (c.discordInvitationVisible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 36),
                  child: _InvitationDisplay(
                    onDisplay: c.recordDiscordInvitationDisplay,
                    child: Container(
                      key: const ValueKey('discord.invitation'),
                      decoration: BoxDecoration(
                        color: const Color(0xFF5865F2),
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton.icon(
                              key: const ValueKey('discord.invitation.join'),
                              style: TextButton.styleFrom(
                                alignment: Alignment.centerLeft,
                                minimumSize: const Size(0, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                              ),
                              onPressed: () => _openLink(_discordAddress),
                              icon: const Icon(
                                Icons.forum,
                                color: Colors.white,
                              ),
                              label: Text(
                                L10n.tr(context, 'Join us on Discord'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('discord.invitation.close'),
                            onPressed: c.dismissDiscordInvitation,
                            tooltip: L10n.tr(context, 'Close'),
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              _SettingsGroup(
                children: [
                  _SettingsRow(
                    title: 'Import Android Bookmark Backup',
                    subtitle: L10n.tr(
                      context,
                      'Android bookmark SQLite backup',
                    ),
                    icon: Icons.move_to_inbox_outlined,
                    color: const Color(0xFFAF52DE),
                    onTap: _importAndroidBookmarks,
                  ),
                ],
              ),
              if (booru)
                _SettingsGroup(
                  footer: c
                      .selectedSources(mode)
                      .map((source) => source.name)
                      .join(' · '),
                  children: [
                    _SettingsRow(
                      title: 'Challenge Roulette',
                      icon: Icons.casino_outlined,
                      color: const Color(0xFFD32EF1),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ChallengesScreen(controller: c),
                        ),
                      ),
                    ),
                    _SettingsRow(
                      title: 'Servers',
                      icon: Icons.dns_outlined,
                      onTap: _servers,
                    ),
                    _SettingsRow(
                      title: 'Pools',
                      icon: Icons.layers_outlined,
                      onTap: () => _openPools(mode),
                    ),
                    _SettingsRow(
                      title: 'Downloads',
                      icon: Icons.download_for_offline_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DownloadsScreen(
                            controller: c,
                            downloads: widget.downloads,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (!booru)
                _SettingsGroup(
                  title: 'Browsing',
                  footer: 'Use the website if the native viewer stops working. Turn off to return to the native viewer.',
                  children: [
                    _SettingsRow(
                      title: 'Website Connection',
                      icon: Icons.language,
                      onTap: _servers,
                    ),
                    _togglePreference(
                      'Use Embedded Browser',
                      'useEmbeddedBrowser.${mode.name}',
                    ),
                    _togglePreference(
                      'Show Work Information Before Reading',
                      'showInformationBeforeReading.manga',
                    ),
                  ],
                ),
              if (!booru)
                _SettingsGroup(
                  children: [
                    _SettingsRow(
                      title: 'Downloads',
                      icon: Icons.download_for_offline_outlined,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DownloadsScreen(
                            controller: c,
                            downloads: widget.downloads,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              _SettingsGroup(
                title: 'Appearance',
                footer: 'Spacing and text scale with thumbnail size. Show Without Spacing removes grid margins, gaps and card padding.',
                children: [
                  _segments<String>(
                    'appearance.${mode.name}',
                    c.appearanceFor(mode),
                    {
                      'dark': 'Dark Mode',
                      'light': 'Light Mode',
                      'system': 'System Default',
                    },
                  ),
                  _columnPicker('Folder Columns', 'folderColumns'),
                  _columnPicker('Grid Columns', 'gridColumns'),
                  _togglePreference(
                    'Show Without Spacing',
                    'removesGridPadding.${mode.name}',
                  ),
                  if (!booru) ...[
                    _SettingsRow(
                      title: 'Preview Columns',
                      value: '${c.store.setting('previewColumns.manga', 0)}',
                      onTap: () => _select(
                        'previewColumns.manga',
                        '${c.store.setting('previewColumns.manga', 0)}',
                        {
                          '0': 'Automatic (2× Grid)',
                          for (var i = 1; i <= 10; i++) '$i': '$i',
                        },
                      ),
                    ),
                    _SettingsRow(
                      title: 'Preview Rows per Page',
                      value: '${c.store.setting('previewRows.manga', 5)}',
                      onTap: () => _select(
                        'previewRows.manga',
                        '${c.store.setting('previewRows.manga', 5)}',
                        {for (var i = 1; i <= 10; i++) '$i': '$i'},
                      ),
                    ),
                    _togglePreference(
                      'Show Work Titles',
                      'showsMangaTitles.manga',
                      fallback: true,
                    ),
                    _togglePreference(
                      'Show Work Artists',
                      'showsMangaArtists.manga',
                      fallback: true,
                    ),
                  ],
                ],
              ),
              _SettingsGroup(
                title: 'Language',
                children: [
                  _SettingsRow(
                    title: 'Language',
                    icon: Icons.translate,
                    value: {
                      'system': L10n.tr(context, 'System'),
                      'en': 'English',
                      'ko': '한국어',
                      'ja': '日本語',
                    }[c.language],
                    onTap: () => _select('language', c.language, {
                      'system': 'System',
                      'en': 'English',
                      'ko': '한국어',
                      'ja': '日本語',
                    }),
                  ),
                ],
              ),
              if (!booru)
                _SettingsGroup(
                  title: 'Search',
                  footer:
                      '${L10n.tr(context, 'Language filters follow the connected website. Category-based language exceptions are not supported.')}\n\n${L10n.tr(context, 'Applied to every native manga search, including artist pages. Separate tags with spaces; use underscores within a tag. Excluded tags are automatically prefixed with a minus sign.')}',
                  children: [
                    _SettingsRow(
                      title: 'Default Search Tags',
                      icon: Icons.filter_list,
                      onTap: () =>
                          _editText('Default Tags', 'defaultTags.manga'),
                    ),
                    _SettingsRow(
                      title: 'Default Excluded Tags',
                      icon: Icons.filter_list_off,
                      onTap: () => _editText(
                        'Default Excluded Tags',
                        'defaultExcludedTags.manga',
                      ),
                    ),
                  ],
                ),
              if (booru)
                _SettingsGroup(
                  title: 'Browsing',
                  footer: 'Use the website if the native viewer stops working. Turn off to return to the native viewer.',
                  children: [
                    _SettingsRow(
                      title: 'Reduce Image Data Further',
                      trailing: TegnalSwitch(
                        semanticLabel: L10n.tr(
                          context,
                          'Reduce Image Data Further',
                        ),
                        value: c.readerPreferences(mode).reducedData,
                        onChanged: (value) => c.setReaderPreferences(
                          mode,
                          c
                              .readerPreferences(mode)
                              .copyWith(reducedData: value),
                        ),
                      ),
                    ),
                    _togglePreference(
                      'Use Embedded Browser',
                      'useEmbeddedBrowser.${mode.name}',
                    ),
                    _togglePreference(
                      'Fit Entire Thumbnails',
                      'fitThumbnails.booru',
                    ),
                  ],
                ),
              _SettingsGroup(
                title: 'Viewer',
                footer: 'Appearance and reader preferences are saved separately for each mode.',
                children: [
                  _SettingsRow(
                    title: 'Reader Settings',
                    icon: Icons.tune,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            ReaderDefaultsScreen(controller: c, mode: mode),
                      ),
                    ),
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'Privacy',
                children: [
                  _togglePreference(
                    'Remember Search History',
                    'rememberHistory.${mode.name}',
                    fallback: true,
                  ),
                  _SettingsRow(
                    title: 'Keep History',
                    value: L10n.tr(
                      context,
                      {0: 'Always', 3: '3 Days', 7: '7 Days', 30: '30 Days'}[c
                              .store
                              .setting('historyRetention.${mode.name}', 0)] ??
                          'Always',
                    ),
                    onTap: () => _select(
                      'historyRetention.${mode.name}',
                      '${c.store.setting('historyRetention.${mode.name}', 0)}',
                      {
                        '0': 'Always',
                        '3': '3 Days',
                        '7': '7 Days',
                        '30': '30 Days',
                      },
                    ),
                  ),
                  _SettingsRow(
                    title: 'Clear Search History',
                    icon: Icons.history,
                    onTap: () async {
                      if (await confirmAction(
                        context,
                        'Clear Search History',
                        'This clears search history for the current mode.',
                        action: 'Clear',
                      )) {
                        c.clearHistory(mode);
                      }
                    },
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'On-Device AI',
                footer: 'AI features are available only with supported, already installed system services. TEGNAL never downloads AI models.',
                children: [
                  _SettingsRow(
                    title: 'System AI',
                    icon: Icons.auto_awesome,
                    value: L10n.tr(
                      context,
                      c.ai.available ? 'Available' : 'Unavailable',
                    ),
                  ),
                  _SettingsRow(
                    title: 'Local Statistics',
                    icon: Icons.bar_chart,
                    value: L10n.tr(context, 'Available'),
                  ),
                  _SettingsRow(
                    title: 'Taste Analysis',
                    icon: Icons.auto_awesome,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            _TasteSettingsScreen(controller: c, mode: mode),
                      ),
                    ),
                  ),
                  _SettingsRow(
                    title: 'Analysis excluded tags',
                    icon: Icons.filter_list,
                    onTap: () => _editExclusions(),
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'Sync',
                footer: AppFeatures.googleDriveSyncEnabled
                    ? 'Sync your library through Google Drive, or transfer an iPhone JSON backup.'
                    : 'Google Drive sync is temporarily disabled. You can still import and export JSON backups.',
                children: [
                  _SettingsRow(
                    title: 'Google Drive Sync',
                    icon: Icons.cloud_sync_outlined,
                    subtitle: AppFeatures.googleDriveSyncEnabled
                        ? null
                        : L10n.tr(context, 'Temporarily unavailable'),
                    onTap:
                        !AppFeatures.googleDriveSyncEnabled ||
                            widget.driveSync == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  DriveSyncScreen(sync: widget.driveSync!),
                            ),
                          ),
                  ),
                  _SettingsRow(
                    title: 'Transfer Library',
                    icon: Icons.sync,
                    onTap: _openLibraryManagement,
                  ),
                ],
              ),
              if (booru)
                _SettingsGroup(
                  title: 'Image Rating Filter',
                  footer: 'Applies the selected default rating to image searches that do not specify a rating. Existing rating terms are preserved. Source types that do not support this filter are unavailable while it is enabled.',
                  children: [
                    _togglePreference('Image Rating Filter', 'safeMode.booru'),
                    if (c.modePreference('safeMode', mode))
                      _SettingsRow(
                        title: 'Age Guide',
                        value: L10n.tr(
                          context,
                          const {'g': 'All Ages', 's': '12+', 'q': '15+'}[c
                                  .store
                                  .setting('safeRating.booru', 'g')] ??
                              'All Ages',
                        ),
                        onTap: () => _select(
                          'safeRating.booru',
                          c.store.setting('safeRating.booru', 'g') as String,
                          {'g': 'All Ages', 's': '12+', 'q': '15+'},
                        ),
                      ),
                    if (c.modePreference('safeMode', mode))
                      _SettingsRow(
                        title: 'Default Search Tag',
                        value:
                            'rating:${c.store.setting('safeRating.booru', 'g')}',
                      ),
                  ],
                ),
              _SettingsGroup(
                title: 'Data & Storage',
                children: [
                  _SettingsRow(
                    title: 'Library Management',
                    icon: Icons.inventory_2_outlined,
                    onTap: _openLibraryManagement,
                  ),
                  _SettingsRow(
                    title: 'Import Android Bookmark Backup',
                    icon: Icons.move_to_inbox_outlined,
                    onTap: _importAndroidBookmarks,
                  ),
                  _SettingsRow(
                    title: 'Other Backup Formats',
                    icon: Icons.inventory_2_outlined,
                    onTap: _importLegacy,
                  ),
                  _SettingsRow(
                    title: 'Clear Image Cache',
                    icon: Icons.cleaning_services_outlined,
                    onTap: () async {
                      if (await confirmAction(
                        context,
                        'Clear Image Cache?',
                        'Saved favorites are kept. Images will be downloaded again when needed.',
                        action: 'Clear',
                      )) {
                        await SessionImageLoader.clearCache();
                        if (context.mounted) {
                          await showMessage(
                            context,
                            'Image Cache Cleared',
                            'Saved favorites are kept.',
                          );
                        }
                      }
                    },
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'Help & Privacy',
                children: [
                  _SettingsRow(
                    title: 'Keyboard & Mouse',
                    icon: Icons.keyboard_outlined,
                    onTap: () => _guide(),
                  ),
                  _SettingsRow(
                    title: 'Replay Onboarding',
                    icon: Icons.school_outlined,
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                OnboardingScreen(controller: c, mode: mode),
                          ),
                        ),
                  ),
                  _SettingsRow(
                    title: 'Privacy Policy',
                    icon: Icons.privacy_tip_outlined,
                    onTap: () => _openLink(
                      'https://github.com/nextline-ai/tegnal/blob/main/docs/privacy-policy.md',
                    ),
                  ),
                  _SettingsRow(
                    title: 'Open Source Licenses',
                    icon: Icons.description_outlined,
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'TEGNAL',
                      applicationVersion: '1.0.0-beta.5',
                    ),
                  ),
                  const _SettingsRow(title: 'Version', value: '1.0.0-beta.5'),
                ],
              ),
              _SettingsGroup(
                title: 'Developer',
                children: [
                  const _SettingsRow(title: 'Developer', value: 'NextLine'),
                  _SettingsRow(
                    title: 'Website',
                    icon: Icons.language,
                    value: 'nextline.work',
                    onTap: () => _openLink('https://nextline.work'),
                  ),
                  _SettingsRow(
                    title: 'Email',
                    icon: Icons.email_outlined,
                    value: 'contact@nextline.work',
                    onTap: () => _openLink('mailto:contact@nextline.work'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      children: [
                        _DeveloperBadge(
                          key: const ValueKey('developer.community'),
                          service: 'discord',
                          label:
                              '${L10n.tr(context, 'Community & Bug Reports')} · Discord',
                          onPressed: () => _openLink(_discordAddress),
                        ),
                        const SizedBox(height: 10),
                        _DeveloperBadge(
                          key: const ValueKey('developer.github'),
                          service: 'github',
                          label: L10n.tr(context, 'View on GitHub'),
                          onPressed: () => _openLink(_githubAddress),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _editExclusions() async {
    final key = 'insights.exclusions.${_mode.name}';
    final stored = widget.controller.store.setting(key);
    final initial = stored is List
        ? stored.whereType<String>()
        : InsightPreferences.defaults(_mode);
    final input = TextEditingController(text: initial.join('\n'));
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(L10n.tr(context, 'Analysis excluded tags')),
        content: TextField(controller: input, minLines: 4, maxLines: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, input.text),
            child: Text(L10n.tr(context, 'Save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (value != null) {
      widget.controller.setPreference(
        key,
        value
            .split(RegExp(r'[\n\r]+'))
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList(),
      );
    }
  }

  Future<void> _guide() => showMessage(
    context,
    'Keyboard & Mouse',
    'Arrow keys: turn pages\nPage Up / Page Down: previous / next\nHome / End: first / last page\nSpace: quick menu\nEscape: close menu or reader\nDouble tap or pinch: zoom\nHold: bookmark',
  );
}

/// Modern inset groups use the same generous corners and separators as the
/// native app, independently of the package's older default list styling.
/// The native developer badges rasterized at 3x; existing user PNGs are untouched.
class _DeveloperBadge extends StatelessWidget {
  const _DeveloperBadge({
    super.key,
    required this.service,
    required this.label,
    required this.onPressed,
  });
  final String service;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final korean = Localizations.localeOf(context).languageCode == 'ko';
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Semantics(
          container: true,
          label: label,
          button: true,
          link: true,
          onTap: onPressed,
          excludeSemantics: true,
          child: Tooltip(
            message: label,
            child: TextButton(
              onPressed: onPressed,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: AspectRatio(
                aspectRatio: 660.66 / (korean ? 203.75 : 220.835),
                child: Image.asset(
                  'assets/branding/developer-$service-${korean ? 'ko' : 'en'}.png',
                  width: 400,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A route can be prepared under an inactive tab without being seen. Record
/// cadence only after the banner actually paints, rather than during build.
class _InvitationDisplay extends SingleChildRenderObjectWidget {
  const _InvitationDisplay({required this.onDisplay, required super.child});
  final VoidCallback onDisplay;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderInvitationDisplay(onDisplay);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderInvitationDisplay renderObject,
  ) {
    renderObject.onDisplay = onDisplay;
  }
}

class _RenderInvitationDisplay extends RenderProxyBox {
  _RenderInvitationDisplay(this.onDisplay);
  VoidCallback onDisplay;
  bool _recordScheduled = false;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_recordScheduled) return;
    _recordScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onDisplay();
    });
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({this.title, this.footer, required this.children});
  final String? title;
  final String? footer;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Text(
              L10n.tr(context, title!),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 56, right: 16),
                    child: Container(
                      height: .5,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                children[i],
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 16, 0),
            child: Text(
              L10n.tr(context, footer!),
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    this.subtitle,
    this.icon,
    this.value,
    this.trailing,
    this.onTap,
    this.color,
    this.action = false,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;
  final bool action;
  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;
    final label = Theme.of(context).colorScheme.onSurface;
    final showChevron = trailing == null && onTap != null && !action;
    final hasTrailingArea = value != null || trailing != null || showChevron;
    final valueMaxWidth = (MediaQuery.sizeOf(context).width * 0.45)
        .clamp(96.0, 200.0)
        .toDouble();
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 26),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 26, color: tint),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L10n.tr(context, title),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                      color: action ? tint : label,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (hasTrailingArea) ...[
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (value != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: valueMaxWidth),
                      child: Text(
                        value!,
                        key: ValueKey('settings-value-$title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 15,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (value != null && (trailing != null || showChevron))
                    const SizedBox(width: 8),
                  if (trailing != null)
                    trailing!
                  else if (showChevron)
                    Icon(
                      Icons.chevron_right,
                      key: ValueKey('settings-chevron-$title'),
                      size: 24,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
    return onTap == null
        ? content
        : TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: content,
          );
  }
}

class _LibraryManagementScreen extends StatefulWidget {
  const _LibraryManagementScreen({
    required this.controller,
    required this.onExport,
    required this.onRestore,
    required this.onImport,
    required this.onImportOther,
  });
  final AppController controller;
  final Future<void> Function() onExport, onRestore, onImport, onImportOther;
  @override
  State<_LibraryManagementScreen> createState() =>
      _LibraryManagementScreenState();
}

class _LibraryManagementScreenState extends State<_LibraryManagementScreen> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
          if (widget.controller.mode == AppMode.manga)
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final c = widget.controller;
                final works = c.savedItems(mode: AppMode.manga);
                return Column(
                  children: [
                    _SettingsGroup(
                      title: 'Library Status',
                      children: [
                        _SettingsRow(
                          title: 'Saved Works',
                          value: '${works.length}',
                        ),
                        _SettingsRow(
                          title: 'Missing Titles',
                          value:
                              '${works.where((entry) => entry.item.title.trim().isEmpty || entry.item.title == '#${entry.item.id}').length}',
                        ),
                        _SettingsRow(
                          title: 'Catalog Matches',
                          value:
                              '${works.where((entry) => entry.item.metadata['catalog_matched'] == true || entry.item.metadata['metadata_source'] == 'catalog').length}',
                        ),
                      ],
                    ),
                    _SettingsGroup(
                      title: 'Automatic Fetching',
                      footer: 'Fetch missing covers and metadata in the background.',
                      children: [
                        _SettingsRow(
                          title: c.metadataFillRunning
                              ? 'Pause'
                              : 'Fill Covers, Titles, and Tags',
                          icon: c.metadataFillRunning
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          value: c.metadataFillTotal > 0
                              ? '${c.metadataFillCompleted}/${c.metadataFillTotal} · ${c.metadataFillFailed}'
                              : null,
                          onTap: c.metadataFillRunning
                              ? c.pauseMetadataFill
                              : () => c.fillMissingMetadata(),
                        ),
                        if (c.metadataFillRunning)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: LinearProgressIndicator(
                              value: c.metadataFillTotal == 0
                                  ? 0
                                  : c.metadataFillCompleted /
                                        c.metadataFillTotal,
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          _SettingsGroup(
            title: 'Backup & Restore',
            footer: 'One JSON file backs up both libraries, including folders, saved works, artists, tags, searches and servers. Media, caches and sign-in details are not included.',
            children: [
              _SettingsRow(
                title: 'Export JSON Backup',
                action: true,
                icon: Icons.upload_file,
                onTap: _busy ? null : () => _run(widget.onExport),
              ),
              _SettingsRow(
                title: 'Import / Restore JSON Backup',
                action: true,
                icon: Icons.file_download_outlined,
                onTap: _busy ? null : () => _run(widget.onRestore),
              ),
            ],
          ),
          _SettingsGroup(
            children: [
              if (widget.controller.mode == AppMode.booru)
                _SettingsRow(
                  title: 'Challenge Roulette',
                  icon: Icons.layers_outlined,
                  color: const Color(0xFFAF52DE),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ChallengesScreen(controller: widget.controller),
                    ),
                  ),
                ),
              _SettingsRow(
                title: 'Import Android Bookmark Backup',
                subtitle: L10n.tr(context, 'Android bookmark SQLite backup'),
                icon: Icons.move_to_inbox_outlined,
                onTap: _busy ? null : () => _run(widget.onImport),
              ),
              _SettingsRow(
                title: 'Other Backup Formats',
                subtitle: L10n.tr(
                  context,
                  'Older user databases, catalog databases and .abbj backups',
                ),
                icon: Icons.inventory_2_outlined,
                onTap: _busy ? null : () => _run(widget.onImportOther),
              ),
            ],
          ),
        ],
      ),
    ),
    appBar: AppBar(
      leading: const TegnalBackButton(),
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text(L10n.tr(context, 'Library Management')),
    ),
  );
}

class ReaderDefaultsScreen extends StatefulWidget {
  const ReaderDefaultsScreen({
    super.key,
    required this.controller,
    required this.mode,
  });
  final AppController controller;
  final AppMode mode;
  @override
  State<ReaderDefaultsScreen> createState() => ReaderDefaultsScreenState();
}

class ReaderDefaultsScreenState extends State<ReaderDefaultsScreen> {
  late ReaderPreferences _prefs = widget.controller.readerPreferences(
    widget.mode,
  );
  void _update(ReaderPreferences prefs) {
    setState(() => _prefs = prefs);
    widget.controller.setReaderPreferences(widget.mode, prefs);
  }

  Widget _toggle(String title, bool value, ValueChanged<bool> change) =>
      _SettingsRow(
        title: title,
        trailing: TegnalSwitch(
          semanticLabel: L10n.tr(context, title),
          value: value,
          onChanged: change,
        ),
      );
  Future<void> _choose<T>(
    String title,
    T current,
    Map<T, String> options,
    ValueChanged<T> changed,
  ) async {
    final value = await showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            groupValue: current,
            onChanged: (value) => Navigator.pop(sheet, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in options.entries)
                  RadioListTile<T>(
                    value: option.key,
                    title: Text(L10n.tr(context, option.value)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (value != null) changed(value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.mode == AppMode.manga)
            _SettingsGroup(
              title: 'Reading Progress',
              children: [
                _SettingsRow(
                  title: 'When Reopening a Work',
                  value: L10n.tr(
                    context,
                    {
                      ReaderResumeBehavior.ask: 'Ask Before Continuing',
                      ReaderResumeBehavior.continueReading: 'Continue Reading',
                      ReaderResumeBehavior.fromBeginning:
                          'Start from Beginning',
                    }[_prefs.resumeBehavior]!,
                  ),
                  onTap: () => _choose<ReaderResumeBehavior>(
                    'When Reopening a Work',
                    _prefs.resumeBehavior,
                    {
                      ReaderResumeBehavior.ask: 'Ask Before Continuing',
                      ReaderResumeBehavior.continueReading: 'Continue Reading',
                      ReaderResumeBehavior.fromBeginning:
                          'Start from Beginning',
                    },
                    (value) => _update(_prefs.copyWith(resumeBehavior: value)),
                  ),
                ),
              ],
            ),
          if (widget.mode == AppMode.manga)
            _SettingsGroup(
              title: 'Multiple Pages at Once',
              children: [
                _SettingsRow(
                  title: 'Pages per View',
                  value: '${_prefs.pagesPerSpread}',
                  onTap: () => _choose<int>(
                    'Pages per View',
                    _prefs.pagesPerSpread,
                    {for (var i = 1; i <= 4; i++) i: '$i'},
                    (value) => _update(_prefs.copyWith(pagesPerSpread: value)),
                  ),
                ),
                _SettingsRow(
                  title: 'Prefetch Pages',
                  value: '${_prefs.prefetch}',
                  onTap: () => _choose<int>('Prefetch Pages', _prefs.prefetch, {
                    0: 'Off',
                    2: '2 Pages',
                    3: '3 Pages',
                    5: '5 Pages',
                  }, (value) => _update(_prefs.copyWith(prefetch: value))),
                ),
              ],
            ),
          if (widget.mode == AppMode.manga)
            _SettingsGroup(
              title: 'Reading Mode',
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<ReadingMode>(
                        segments: [
                          ButtonSegment<ReadingMode>(
                            value: ReadingMode.horizontal,
                            label: Text(L10n.tr(context, 'Horizontal')),
                          ),
                          ButtonSegment<ReadingMode>(
                            value: ReadingMode.vertical,
                            label: Text(L10n.tr(context, 'Vertical')),
                          ),
                          ButtonSegment<ReadingMode>(
                            value: ReadingMode.continuous,
                            label: Text(L10n.tr(context, 'Continuous')),
                          ),
                        ],
                        selected: {_prefs.readingMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) {
                          _update(
                            _prefs.copyWith(readingMode: selection.first),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                _toggle(
                  'Right to left',
                  _prefs.rightToLeft,
                  (v) => _update(_prefs.copyWith(rightToLeft: v)),
                ),
                _toggle(
                  'Tap to turn pages',
                  _prefs.tapNavigation,
                  (v) => _update(_prefs.copyWith(tapNavigation: v)),
                ),
                _toggle(
                  'Show page number',
                  _prefs.showPageNumber,
                  (v) => _update(_prefs.copyWith(showPageNumber: v)),
                ),
                _toggle(
                  'Auto advance',
                  _prefs.autoAdvance,
                  (v) => _update(_prefs.copyWith(autoAdvance: v)),
                ),
                if (_prefs.autoAdvance)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${L10n.tr(context, 'Seconds per page')}: ${_prefs.autoSeconds}',
                        ),
                        Slider(
                          value: _prefs.autoSeconds.toDouble(),
                          min: 2,
                          max: 120,
                          divisions: 118,
                          onChanged: (v) =>
                              _update(_prefs.copyWith(autoSeconds: v.round())),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          _SettingsGroup(
            title: 'Display',
            children: [
              if (widget.mode == AppMode.booru)
                _toggle(
                  'Original images',
                  _prefs.originalImages,
                  (v) => _update(_prefs.copyWith(originalImages: v)),
                ),
              if (widget.mode == AppMode.booru)
                _toggle(
                  'Show Notes on Images',
                  _prefs.showNotes,
                  (v) => _update(_prefs.copyWith(showNotes: v)),
                ),
              _toggle(
                'Show Quick Menu at Bottom',
                _prefs.bottomMenu,
                (value) => _update(_prefs.copyWith(bottomMenu: value)),
              ),
              if (widget.mode == AppMode.booru) ...[
                _toggle(
                  'Right to left',
                  _prefs.rightToLeft,
                  (value) => _update(_prefs.copyWith(rightToLeft: value)),
                ),
                _toggle(
                  'Tap to turn pages',
                  _prefs.tapNavigation,
                  (value) => _update(_prefs.copyWith(tapNavigation: value)),
                ),
                _toggle(
                  'Show page number',
                  _prefs.showPageNumber,
                  (value) => _update(_prefs.copyWith(showPageNumber: value)),
                ),
                _toggle(
                  'Auto advance',
                  _prefs.autoAdvance,
                  (value) => _update(_prefs.copyWith(autoAdvance: value)),
                ),
                if (_prefs.autoAdvance)
                  _SettingsRow(
                    title: 'Seconds per page',
                    value: '${_prefs.autoSeconds}',
                    onTap: () => _choose<int>(
                      'Seconds per page',
                      _prefs.autoSeconds,
                      {for (var i = 2; i <= 120; i++) i: '$i'},
                      (value) => _update(_prefs.copyWith(autoSeconds: value)),
                    ),
                  ),
                _toggle(
                  'Reduce Image Data Further',
                  _prefs.reducedData,
                  (value) => _update(_prefs.copyWith(reducedData: value)),
                ),
              ],
              if (widget.mode == AppMode.manga &&
                  _prefs.readingMode == ReadingMode.continuous)
                _toggle(
                  'Swipe Up for Previews',
                  _prefs.continuousPreviewSwipe,
                  (value) =>
                      _update(_prefs.copyWith(continuousPreviewSwipe: value)),
                ),
              _toggle(
                'Keep screen awake',
                _prefs.keepAwake,
                (v) => _update(_prefs.copyWith(keepAwake: v)),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L10n.tr(context, 'Dim screen')),
                    Slider(
                      value: _prefs.dimming,
                      min: 0,
                      max: .65,
                      onChanged: (v) => _update(_prefs.copyWith(dimming: v)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _SettingsGroup(
            title: 'Gesture Guide',
            children: [
              _SettingsRow(
                title: 'Reader Guide',
                icon: Icons.touch_app_outlined,
                onTap: () =>
                    showReaderGuide(context, widget.controller, widget.mode),
              ),
            ],
          ),
        ],
      ),
    ),
    appBar: AppBar(
      leading: const TegnalBackButton(),
      title: Text(L10n.tr(context, 'Reader Settings')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(L10n.tr(context, 'Done')),
        ),
      ],
    ),
  );
}

class _TasteSettingsScreen extends StatelessWidget {
  const _TasteSettingsScreen({required this.controller, required this.mode});
  final AppController controller;
  final AppMode mode;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: const TegnalBackButton(),
      title: Text(L10n.tr(context, 'Taste Analysis Settings')),
    ),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsGroup(
            children: [
              for (final title in ['Weekly statistics', 'Monthly Recap'])
                _SettingsRow(
                  title: title,
                  icon: Icons.bar_chart_outlined,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => InsightsScreen(
                        controller: controller,
                        mode: mode,
                        reportDays: title == 'Weekly statistics' ? 7 : 30,
                        onSearch: (query) =>
                            controller.search(query: query, forMode: mode),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          _SettingsGroup(
            title: 'Taste Analysis',
            footer: 'New taste evidence, recommendations and reports pause on this device. Existing analysis and saved works are kept.',
            children: [
              _SettingsRow(
                title: 'Taste Analysis',
                trailing: TegnalSwitch(
                  semanticLabel: L10n.tr(context, 'Taste Analysis'),
                  value: controller.taste.enabled,
                  onChanged: (value) async {
                    if (value ||
                        await confirmAction(
                          context,
                          'Turn off taste analysis?',
                          'New taste evidence, recommendations and reports pause on this device. Existing analysis and saved works are kept.',
                          action: 'Turn Off',
                        )) {
                      controller.taste.setEnabled(value);
                      controller.changed();
                    }
                  },
                ),
              ),
              for (final source in controller.sources(mode))
                _SettingsRow(
                  title: source.name,
                  subtitle: L10n.tr(context, 'Recommendation filters'),
                  icon: Icons.filter_list,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _RecommendationSettingsScreen(
                        controller: controller,
                        source: source,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          _SettingsGroup(
            footer: 'Deletes activity, preference evidence, and reports. Your saved works remain. Existing works will not be automatically analyzed again.',
            children: [
              _SettingsRow(
                title: 'Delete all analysis data',
                icon: Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
                action: true,
                onTap: () async {
                  if (await confirmAction(
                    context,
                    'Delete all analysis data?',
                    'Deletes activity, preference evidence, and reports. Your saved works remain. Existing works will not be automatically analyzed again.',
                    action: 'Delete',
                  )) {
                    controller.taste.reset();
                    controller.changed();
                  }
                },
              ),
              _SettingsRow(
                title: 'Analysis time zone',
                value: DateTime.now().timeZoneName,
              ),
              const _SettingsRow(
                title: 'Retention',
                value: 'Until you delete it',
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _RecommendationSettingsScreen extends StatelessWidget {
  const _RecommendationSettingsScreen({
    required this.controller,
    required this.source,
  });
  final AppController controller;
  final SourceConfig source;
  Future<void> _tags(
    BuildContext context,
    String title,
    String key,
    List<String> defaults,
  ) async {
    final stored = Map<String, dynamic>.from(
      controller.store.setting(key, <String, dynamic>{}) as Map,
    );
    final current = stored[source.id] as List? ?? defaults;
    final input = TextEditingController(text: current.join('\n'));
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        scrollable: true,
        title: Text(L10n.tr(context, title)),
        content: TextField(
          controller: input,
          minLines: 4,
          maxLines: 8,
          autocorrect: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(L10n.tr(context, 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, input.text),
            child: Text(L10n.tr(context, 'Save')),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (value != null) {
      stored[source.id] = value
          .split(RegExp(r'[\n\r]+'))
          .map(InsightPreferences.normalize)
          .where((value) => value.isNotEmpty && !value.startsWith('-'))
          .toSet()
          .toList();
      controller.setPreference(key, stored);
    }
  }

  Future<void> _choose(
    BuildContext context,
    String title,
    String field,
    Map<String, String> options,
  ) async {
    final key = 'recommendation.filters.${source.id}';
    final filters = Map<String, dynamic>.from(
      controller.store.setting(key, <String, dynamic>{}) as Map,
    );
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => RadioGroup<String>(
        groupValue: filters[field] as String? ?? options.keys.first,
        onChanged: (value) => Navigator.pop(sheet, value),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in options.entries)
                RadioListTile<String>(
                  value: option.key,
                  title: Text(L10n.tr(context, option.value)),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      filters[field] = selected;
      controller.setPreference(key, filters);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(leading: const TegnalBackButton(), title: Text(source.name)),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.taste.preferences(source.mode);
        final filters = controller.store.setting(
          'recommendation.filters.${source.id}',
          <String, dynamic>{},
        ) as Map;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SettingsGroup(
              title: 'Smart Recommendations',
              footer: 'Only this server uses these filters. All included tags must match. No language is required unless you choose one. Changes apply when you refresh recommendations.',
              children: [
                if (source.mode == AppMode.manga)
                  _SettingsRow(
                    title: 'Language',
                    value: '${filters['language'] ?? 'all'}',
                    onTap: () => _choose(context, 'Language', 'language', {
                      'all': 'All',
                      'korean': 'Korean',
                      'japanese': 'Japanese',
                      'english': 'English',
                    }),
                  ),
                _SettingsRow(
                  title: 'Sort',
                  value: '${filters['sort'] ?? 'recommended'}',
                  onTap: () => _choose(context, 'Sort', 'sort', {
                    'recommended': 'Recommended',
                    'latest': 'Latest',
                    if (source.mode == AppMode.manga) ...{
                      'today': 'Popular Today',
                      'week': 'Popular This Week',
                      'month': 'Popular This Month',
                      'year': 'Popular This Year',
                    },
                    if (source.mode == AppMode.booru)
                      for (final sort in BooruSort.supportedBy([
                        source,
                      ]).where((sort) => sort != BooruSort.latest))
                        sort.name: sort.title,
                  }),
                ),
                _SettingsRow(
                  title: 'Default included tags',
                  value:
                      '${preferences.includedBySource[source.id]?.length ?? 0}',
                  onTap: () => _tags(
                    context,
                    'Default included tags',
                    'recommendation.includedTags',
                    const [],
                  ),
                ),
                _SettingsRow(
                  title: 'Excluded taste tags',
                  value:
                      '${preferences.excludedRecommendationBySource[source.id]?.length ?? 0}',
                  onTap: () => _tags(
                    context,
                    'Excluded taste tags',
                    'recommendation.excludedTags',
                    const [],
                  ),
                ),
                _SettingsRow(
                  title: 'Analysis excluded tags',
                  value:
                      '${(preferences.excludedBySource[source.id] ?? preferences.excludedTags).length}',
                  onTap: () => _tags(
                    context,
                    'Analysis excluded tags',
                    'insights.exclusionsBySource.${source.mode.name}',
                    preferences.excludedTags.toList(),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
