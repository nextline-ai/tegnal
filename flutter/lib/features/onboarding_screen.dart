import 'package:material_ui/material_ui.dart';

import '../core/app_controller.dart';
import '../core/content.dart';
import '../ui/design_system.dart';
import '../ui/l10n.dart';
import '../ui/metadata_fill.dart';
import 'settings_screen.dart';

import 'package:url_launcher/url_launcher.dart';

/// Three-step setup matching the native Connect → Import → Switch modes flow.
/// The mode selector in the last step is an illustration and never writes the
/// selected mode or changes either library.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    this.importsOnly = false,
    this.mode,
  });

  final AppController controller;
  final bool importsOnly;
  final AppMode? mode;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late AppMode _mode = widget.mode ?? widget.controller.mode;
  late int _step = widget.importsOnly ? 1 : 0;
  AppMode _previewMode = AppMode.manga;
  bool _working = false;

  String _t(String value) => L10n.tr(context, value);
  bool get _hasConnection => widget.importsOnly
      ? widget.controller.sources(_mode).isNotEmpty
      : widget.controller.allSources.isNotEmpty;

  Future<void> _connect() async {
    final source = await showAddSource(
      context,
      widget.controller,
      mode: _mode,
      autoDetectMode: !widget.importsOnly,
    );
    if (mounted && source != null) {
      if (!widget.importsOnly) {
        _mode = source.mode;
        widget.controller.setMode(source.mode);
      }
      setState(() {});
    }
  }

  Future<void> _openPrivacyPolicy() async {
    await launchUrl(
      Uri.parse(
        'https://github.com/nextline-ai/tegnal/blob/main/docs/privacy-policy.md',
      ),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _import(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _finish() {
    if (!widget.importsOnly && !widget.controller.onboardingComplete) {
      widget.controller.finishOnboarding();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final completedSetup = widget.controller.onboardingComplete;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: _step > 0 && !widget.importsOnly
            ? IconButton(
                tooltip: _t('Back'),
                onPressed: _working ? null : () => setState(() => _step--),
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: const SizedBox.shrink(),
        centerTitle: true,
        actions: [
          if (completedSetup)
            TextButton(
              onPressed: _working ? null : _finish,
              child: Text(_t('Done')),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              children: [
                MetadataFillNotice(
                  controller: widget.controller,
                  onConnect: () => showAddSource(
                    context,
                    widget.controller,
                    mode: AppMode.manga,
                  ),
                ),
                if (!widget.importsOnly) _progress(),
                if (!widget.importsOnly) const SizedBox(height: 24),
                if (_step == 0 && !widget.importsOnly)
                  _connectStep()
                else if (_step == 1)
                  _importStep()
                else
                  _modeStep(),
                if (_working) ...[
                  const SizedBox(height: 20),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _footer(completedSetup),
    );
  }

  Widget _progress() => Padding(
    key: const ValueKey('onboarding-progress'),
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      children: [
        for (var index = 0; index < 3; index++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: index <= _step
                    ? TegnalColors.accent
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          if (index < 2) const SizedBox(width: 6),
        ],
      ],
    ),
  );

  Widget _connectStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _t('Connect a Website'),
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      Text(
        _t(
          'Enter a comics or image website. We’ll detect its type and switch to the right mode.',
        ),
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.4,
        ),
      ),
      TextButton.icon(
        key: const ValueKey('onboarding-violet-shortcut'),
        onPressed: _working ? null : () => setState(() => _step = 1),
        icon: const Icon(Icons.move_to_inbox_outlined),
        label: Text(_t('Import Android Bookmark Backup')),
      ),
      const SizedBox(height: 20),
      _websiteModeGuide(),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _working ? null : _connect,
              icon: const Icon(Icons.add_circle_outline),
              label: Text(_t('Enter Website Address')),
            ),
            for (final source
                in widget.importsOnly
                    ? widget.controller.sources(_mode)
                    : widget.controller.allSources)
              _sourceRow(source),
          ],
        ),
      ),
    ],
  );

  Widget _websiteModeGuide() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _modeGuideRow(
        icon: Icons.menu_book_outlined,
        title: 'Comics',
        description: 'Read multi-page works by their work number.',
      ),
      const SizedBox(height: 12),
      _modeGuideRow(
        icon: Icons.photo_outlined,
        title: 'Images',
        description: 'Browse individual images using tags.',
      ),
    ],
  );

  Widget _modeGuideRow({
    required IconData icon,
    required String title,
    required String description,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t(title), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 3),
            Text(
              _t(description),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _sourceRow(SourceConfig source) {
    final selected =
        widget.controller.selectedSource(source.mode)?.id == source.id;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(
          selected ? Icons.check_circle : Icons.language,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(source.name),
        subtitle: Text(source.baseUrl.host),
        trailing: selected ? const Icon(Icons.check, size: 24) : null,
      ),
    );
  }

  Widget _importStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.file_download_outlined, size: 42, color: TegnalColors.accent),
      const SizedBox(height: 20),
      Text(
        _t('Import Data'),
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 20),
      _importCard(
        key: const ValueKey('onboarding-violet-card'),
        title: 'Import Android Bookmark Backup',
        subtitle: 'Choose an Android bookmark SQLite backup (.sqlite or .db). Preview its contents before merging it into your library.',
        icon: Icons.move_to_inbox_outlined,
        action: FilledButton.icon(
          key: const ValueKey('onboarding-violet-import'),
          onPressed: _working
              ? null
              : () => _import(
                  () => showImportAndroidBookmarks(context, widget.controller),
                ),
          icon: const Icon(Icons.input),
          label: Text(_t('Import Android Bookmark Backup')),
        ),
      ),
      const SizedBox(height: 12),
      _importCard(
        title: 'TEGNAL JSON Backup',
        subtitle: 'Restore saved works, folders, and settings from a backup.',
        icon: Icons.inventory_2_outlined,
        action: OutlinedButton.icon(
          onPressed: _working
              ? null
              : () => _import(
                  () => showRestoreLibraryBackup(context, widget.controller),
                ),
          icon: const Icon(Icons.file_download_outlined),
          label: Text(_t('Restore JSON Backup')),
        ),
      ),
    ],
  );

  Widget _importCard({
    Key? key,
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget action,
  }) => Container(
    key: key,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _t(title),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _t(subtitle),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Align(alignment: Alignment.centerLeft, child: action),
      ],
    ),
  );

  Widget _modeStep() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        _t('Switch Modes'),
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      Text(
        _t('Use the top switch for comics and images.'),
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  _t('Saved'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                SizedBox(
                  width: 104,
                  child: SegmentedButton<AppMode>(
                    segments: [
                      ButtonSegment<AppMode>(
                        value: AppMode.manga,
                        icon: Tooltip(
                          message: _t('Comics'),
                          child: const Icon(Icons.menu_book_outlined),
                        ),
                      ),
                      ButtonSegment<AppMode>(
                        value: AppMode.booru,
                        icon: Tooltip(
                          message: _t('Images'),
                          child: const Icon(Icons.photo_outlined),
                        ),
                      ),
                    ],
                    selected: {_previewMode},
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                    onSelectionChanged: (value) => setState(() {
                      _previewMode = value.first;
                    }),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.add, size: 28),
              ],
            ),
            const SizedBox(height: 28),
            Icon(
              _previewMode == AppMode.manga
                  ? Icons.menu_book_rounded
                  : Icons.photo_library_rounded,
              size: 64,
              color: TegnalColors.accent,
            ),
            const SizedBox(height: 12),
            Text(
              _t(_previewMode == AppMode.manga ? 'Comics' : 'Images'),
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Text(
        _t('Each mode keeps its own library and settings.'),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );

  Widget _footer(bool completedSetup) {
    final label = widget.importsOnly
        ? 'Done'
        : _step == 2
        ? completedSetup
              ? 'Done'
              : 'Get Started'
        : _step == 0 && !_hasConnection
        ? 'Set Up Later'
        : 'Continue';
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('onboarding-footer'),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer
              .withValues(alpha: .94),
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: .5),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('onboarding-primary'),
                onPressed: _working
                    ? null
                    : widget.importsOnly
                    ? _finish
                    : _step < 2
                    ? () => setState(() => _step++)
                    : _finish,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: _step == 0 && !_hasConnection
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : null,
                  foregroundColor: _step == 0 && !_hasConnection
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : null,
                ),
                child: Text(_t(label)),
              ),
            ),
            if (_step == 0 && !widget.importsOnly)
              TextButton(
                onPressed: _openPrivacyPolicy,
                child: Text(_t('Privacy Policy')),
              ),
          ],
        ),
      ),
    );
  }
}
