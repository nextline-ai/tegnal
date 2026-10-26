import 'package:material_ui/material_ui.dart';

import '../core/drive_sync_controller.dart';
import '../ui/common.dart';
import '../ui/l10n.dart';

class DriveSyncScreen extends StatefulWidget {
  const DriveSyncScreen({super.key, required this.sync});
  final DriveSyncController sync;
  @override
  State<DriveSyncScreen> createState() => _DriveSyncScreenState();
}

class _DriveSyncScreenState extends State<DriveSyncScreen> {
  String? _revisionId;
  String _t(String key) => L10n.tr(context, key);

  Future<void> _resolve(DriveResolution resolution, String revisionId) async {
    final description = switch (resolution) {
      DriveResolution.useDevice => 'Publish this device’s complete library as the current Drive copy. Previous Drive versions remain available.',
      DriveResolution.useDrive => 'Replace synchronized library metadata on this device with the selected Drive copy. Downloads and reading progress stay on this device. A local recovery copy is saved first.',
      DriveResolution.combine => 'Combine saved data from this device and Drive. Drive values win for duplicate records. Previously deleted items can return when combining copies.',
    };
    if (await confirmAction(
      context,
      'Resolve sync conflict',
      description,
      action: 'Continue',
    )) {
      await widget.sync.synchronize(
        resolution: resolution,
        revisionId: revisionId,
      );
    }
  }

  Future<void> _recovery() async {
    final files = await widget.sync.recoveryCopies();
    if (!mounted) return;
    if (files.isEmpty) {
      await showMessage(
        context,
        'Recovery copies',
        'No recovery copies yet. A copy is saved before Drive changes replace local metadata.',
      );
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _t('Recovery copies'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (var i = 0; i < files.length; i++)
              ListTile(
                leading: const Icon(Icons.restore),
                title: Text(_recoveryDate(files[i].path)),
                onTap: () => Navigator.pop(context, i),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (await confirmAction(
      context,
      'Restore recovery copy',
      'Restore this local metadata copy? The current library will also be saved. Automatic sync will be turned off until you review the restored library.',
      action: 'Restore',
    )) {
      await widget.sync.restoreRecovery(files[selected]);
    }
  }

  String _recoveryDate(String path) {
    final value = RegExp(r'before-(\d+)\.json$').firstMatch(path)?.group(1);
    final microseconds = int.tryParse(value ?? '');
    return microseconds == null
        ? _t('Recovery copy')
        : _date(DateTime.fromMicrosecondsSinceEpoch(microseconds));
  }

  String _date(DateTime date) {
    final local = date.toLocal();
    final formatter = MaterialLocalizations.of(context);
    return '${formatter.formatMediumDate(local)} ${formatter.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Widget _card(List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 18),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.sync,
    builder: (context, _) {
      final sync = widget.sync;
      final conflict = sync.conflict;
      final selected =
          conflict?.revisions.where((r) => r.id == _revisionId).firstOrNull ??
          conflict?.revisions.firstOrNull;
      return Scaffold(
        appBar: AppBar(title: Text(_t('Google Drive'))),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (sync.busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 18),
                    child: LinearProgressIndicator(),
                  ),
                _card([
                  Icon(
                    Icons.cloud_sync_outlined,
                    size: 50,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _t('Your library, across devices'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _t(
                      'Sync folders, saved works, tags, searches and challenge definitions. Media, downloads, reading progress and sign-in details stay on each device.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _t(
                      'Drive files use the iPhone JSON export format. Import an iPhone backup in Library Management, then sync. You can also download a Drive revision and import it on iPhone.',
                    ),
                  ),
                ]),
                if (!sync.configured)
                  _card([
                    Text(
                      _t('Google Drive setup required'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _t(
                        'This build needs Google OAuth app registration before account connection is available. Your local library and JSON transfers remain available.',
                      ),
                    ),
                  ])
                else
                  _card([
                    Text(
                      sync.connected
                          ? sync.accountEmail ?? _t('Connected')
                          : _t('Not connected'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    if (sync.connected) ...[
                      FilledButton.icon(
                        onPressed: sync.busy ? null : sync.synchronize,
                        icon: const Icon(Icons.sync),
                        label: Text(_t('Sync now')),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          _t('Sync automatically while the app is open'),
                        ),
                        subtitle: Text(
                          _t(
                            'Checks after edits and every five minutes while active. Conflicts pause automatic sync.',
                          ),
                        ),
                        value: sync.autoSync,
                        onChanged: sync.busy ? null : sync.setAutoSync,
                      ),
                      if (sync.lastSync != null)
                        Text('${_t('Last synced')}: ${_date(sync.lastSync!)}'),
                      TextButton(
                        onPressed: sync.busy ? null : sync.disconnect,
                        child: Text(_t('Disconnect Google Drive')),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: sync.busy ? null : sync.connect,
                        icon: const Icon(Icons.login),
                        label: Text(_t('Connect Google Drive')),
                      ),
                  ]),
                if (sync.error != null)
                  _card([
                    Text(
                      _t(sync.error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ]),
                if (conflict != null && selected != null)
                  _card([
                    Text(
                      _t('Choose how to resolve the conflict'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _t(
                        'Both copies changed, or multiple devices published at the same time. No copy has been silently overwritten.',
                      ),
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        conflict.revisions.map((r) => r.id).join(','),
                      ),
                      initialValue: selected.id,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: _t('Drive copy')),
                      items: [
                        for (final revision in conflict.revisions)
                          DropdownMenuItem(
                            value: revision.id,
                            child: Text(
                              _date(revision.modifiedAt),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: sync.busy
                          ? null
                          : (value) => setState(() => _revisionId = value),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: sync.busy
                          ? null
                          : () =>
                                _resolve(DriveResolution.combine, selected.id),
                      child: Text(_t('Combine libraries')),
                    ),
                    OutlinedButton(
                      onPressed: sync.busy
                          ? null
                          : () => _resolve(
                              DriveResolution.useDevice,
                              selected.id,
                            ),
                      child: Text(_t('Use this device')),
                    ),
                    OutlinedButton(
                      onPressed: sync.busy
                          ? null
                          : () =>
                                _resolve(DriveResolution.useDrive, selected.id),
                      child: Text(_t('Use selected Drive copy')),
                    ),
                  ]),
                _card([
                  Text(
                    _t('Version history and recovery'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _t(
                      'Each upload creates a new JSON revision in the TEGNAL folder on Drive. Previous versions are retained. The ten most recent local recovery copies are also kept on this device.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: sync.busy ? null : _recovery,
                    icon: const Icon(Icons.restore),
                    label: Text(_t('Recovery copies')),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
    },
  );
}
