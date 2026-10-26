import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;

import '../core/app_controller.dart';
import '../core/drive_sync_controller.dart';
import '../core/content.dart';
import '../core/library.dart';
import '../ui/page_header.dart';
import '../data/backup_codec.dart';
import '../data/backup_files.dart';
import '../data/download_manager.dart';
import '../data/legacy_import.dart';
import '../data/booru_source_detector.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';
import '../ui/design_system.dart';
import 'downloads_screen.dart';
import 'browser_screen.dart';
import 'challenges_screen.dart';
import 'booru_pools_screen.dart';
import 'drive_sync_screen.dart';
import 'detail_screen.dart';
import 'onboarding_screen.dart';

/// Opens the existing, validated legacy importer from setup and Settings.
Future<void> showImportLegacy(
  BuildContext context,
  AppController controller,
) async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Violet / Anime Boxes',
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
    if (await confirmAction(
      context,
      'Import Library',
      '${summary.workCount} ${L10n.tr(context, 'Works')} · ${summary.folderCount} ${L10n.tr(context, 'Folders')}\n${L10n.tr(context, 'Existing items will be merged. Other saved items will remain.')}',
      action: 'Import',
    )) {
      final imported = await importer.importFile(file.path);
      controller.libraryRestored();
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
    controller.libraryRestored();
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
    SourceKind.danbooru => 'Danbooru',
    SourceKind.gelbooru => 'Gelbooru',
    SourceKind.oldGelbooru => 'Old Gelbooru (v0.1.11)',
    SourceKind.moebooru => 'Moebooru',
    SourceKind.manga => 'Manga',
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
                              final engineSuffix = kind == SourceKind.manga
                                  ? ''
                                  : ' · ${_engineName(kind)}';
                              return Row(
                                children: [
                                  const Icon(Icons.check_circle, size: 26),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text('$modeLabel$engineSuffix'),
                                  ),
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
                                        : _engineName(kind),
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
              'One rule per line. Space-separated tags must all match. Use -tag for exceptions and * for wildcards. Rating rules are supported.',
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
          widget.controller.libraryRestored();
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
    if (result != null) widget.controller.setPreference(key, result);
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
    if (action == 'select') widget.controller.selectSource(source);
    if (action == 'remove' &&
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
        onImport: _importLegacy,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final mode = _mode;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: TegnalFloatingHeader(
        header: TegnalPageHeader(
          controller: c,
          title: mode == AppMode.manga ? 'Settings' : 'More',
        ),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            tegnalHeaderExtent + 8,
            16,
            navigationScrollInset(context, gap: 28),
          ),
          children: [
            _SettingsGroup(
              title: 'Browsing',
              children: [
                for (final source in c.sources(mode))
                  _SettingsRow(
                    title: source.name,
                    subtitle: source.baseUrl.host,
                    icon: Icons.language,
                    trailing: c.selectedSource(mode)?.id == source.id
                        ? const Icon(
                            Icons.check,
                            size: 26,
                            color: Color(0xFF007AFF),
                          )
                        : null,
                    onTap: () => _source(source, mode),
                  ),
                _SettingsRow(
                  title: 'Website Connection',
                  icon: Icons.language,
                  onTap: () => showAddSource(context, c, mode: mode),
                ),
              ],
            ),
            _SettingsGroup(
              children: [
                _SettingsRow(
                  title: 'Downloads',
                  icon: Icons.download,
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
            if (mode == AppMode.booru)
              _SettingsGroup(
                children: [
                  _SettingsRow(
                    title: 'Pools',
                    icon: Icons.layers_outlined,
                    onTap: () => _openPools(mode),
                  ),
                ],
              ),
            _SettingsGroup(
              title: 'Appearance',
              footer: 'Reader preferences are saved separately for each mode.',
              children: [
                _SettingsRow(
                  title: 'Theme',
                  icon: Icons.contrast,
                  value: L10n.tr(
                    context,
                    {
                      'system': 'System',
                      'light': 'Light',
                      'dark': 'Dark',
                    }[c.appearance]!,
                  ),
                  onTap: () => _select('appearance', c.appearance, {
                    'system': 'System',
                    'light': 'Light',
                    'dark': 'Dark',
                  }),
                ),
                _SettingsRow(
                  title: 'Language',
                  icon: Icons.translate,
                  value:
                      {
                        'system': L10n.tr(context, 'System'),
                        'en': 'English',
                        'ko': '한국어',
                        'ja': '日本語',
                      }[c.language] ??
                      c.language,
                  onTap: () => _select('language', c.language, {
                    'system': 'System',
                    'en': 'English',
                    'ko': '한국어',
                    'ja': '日本語',
                  }),
                ),
              ],
            ),
            _SettingsGroup(
              title: 'Viewer',
              children: [
                _SettingsRow(
                  title: 'Reader Settings',
                  icon: Icons.tune,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          _ReaderDefaultsScreen(controller: c, mode: mode),
                    ),
                  ),
                ),
              ],
            ),
            _SettingsGroup(
              title: 'Privacy',
              children: [
                _SettingsRow(
                  title: 'Remember Search History',
                  trailing: TegnalSwitch(
                    semanticLabel: L10n.tr(context, 'Remember Search History'),
                    value:
                        c.store.setting('rememberHistory.${mode.name}', true) ==
                        true,
                    onChanged: (v) =>
                        c.setPreference('rememberHistory.${mode.name}', v),
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
              title: 'Data & Storage',
              footer:
                  'Import, back up, and move your saved works between devices.',
              children: [
                _SettingsRow(
                  title: 'Library Management',
                  icon: Icons.inventory_2_outlined,
                  onTap: _openLibraryManagement,
                ),
                _SettingsRow(
                  title: 'Import from Other Apps',
                  icon: Icons.move_to_inbox_outlined,
                  onTap: _importLegacy,
                ),
                if (mode == AppMode.booru)
                  _SettingsRow(
                    title: 'Challenge Roulette',
                    icon: Icons.timer_outlined,
                    color: const Color(0xFFAF52DE),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ChallengesScreen(controller: c),
                      ),
                    ),
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
              ],
            ),
            _SettingsGroup(
              title: 'Sync',
              footer: 'Sync your library through Google Drive, or transfer an iPhone JSON backup.',
              children: [
                _SettingsRow(
                  title: 'Google Drive Sync',
                  icon: Icons.cloud_sync_outlined,
                  onTap: widget.driveSync == null
                      ? null
                      : () => Navigator.of(context).push(
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
            _SettingsGroup(
              title: 'Help & Privacy',
              children: [
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
              ],
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'TEGNAL · NextLine',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modern inset groups use the same generous corners and separators as the
/// native app, independently of the package's older default list styling.
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
    this.color = const Color(0xFF007AFF),
    this.action = false,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color color;
  final bool action;
  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).colorScheme.onSurface;
    final showChevron = trailing == null && onTap != null && !action;
    final hasTrailingArea = value != null || trailing != null || showChevron;
    final valueMaxWidth = (MediaQuery.sizeOf(context).width * 0.45)
        .clamp(96.0, 200.0)
        .toDouble();
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 26),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 30, color: color),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L10n.tr(context, title),
                    style: TextStyle(
                      fontSize: 17,
                      color: action ? color : label,
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
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
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
  });
  final AppController controller;
  final Future<void> Function() onExport, onRestore, onImport;
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
                title: 'Import Violet / Anime Boxes',
                icon: Icons.move_to_inbox_outlined,
                onTap: _busy ? null : () => _run(widget.onImport),
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

class _ReaderDefaultsScreen extends StatefulWidget {
  const _ReaderDefaultsScreen({required this.controller, required this.mode});
  final AppController controller;
  final AppMode mode;
  @override
  State<_ReaderDefaultsScreen> createState() => _ReaderDefaultsScreenState();
}

class _ReaderDefaultsScreenState extends State<_ReaderDefaultsScreen> {
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
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
        ],
      ),
    ),
    appBar: AppBar(
      leading: const TegnalBackButton(),
      title: Text(L10n.tr(context, 'Reader Settings')),
    ),
  );
}
