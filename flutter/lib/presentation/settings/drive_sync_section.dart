import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/downloads/download_store.dart';
import '../../core/support/l10n.dart';
import '../../core/sync/library_drive_sync.dart';
import '../design/grouped_form.dart';
import '../design/tegnal_theme.dart';
import 'settings_rows.dart';
import '../design/alert_dialog.dart';

/// `CloudSyncSection` on Android: Google Drive in place of iCloud, with the account that holds it.
class DriveSyncSection extends StatefulWidget {
  const DriveSyncSection({super.key, required this.sync});
  final LibraryDriveSync sync;

  @override
  State<DriveSyncSection> createState() => _DriveSyncSectionState();
}

class _DriveSyncSectionState extends State<DriveSyncSection> {
  bool _connecting = false;

  LibraryDriveSync get _sync => widget.sync;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_changed);
  }

  @override
  void dispose() {
    _sync.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final error = await _sync.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (error != null) _alert(L10n.text('Unable to connect Google Account: %@', [error]));
  }

  Future<void> _toggle(bool value) async {
    if (value) {
      if (_sync.account == null) return _connect();
      _sync.enabled = true;
      await _sync.synchronize();
      return;
    }
    final off = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Turn Off Google Drive Sync?')),
        content: Text(
          L10n.text(
            'Changes on this device will stop syncing. Existing data on this device and in Google Drive will be kept. Turning sync on again will merge changes.',
          ),
        ),
        actions: [
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Turn Off'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    if (off == true) _sync.enabled = false;
  }

  void _alert(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => TegnalAlertDialog(
      title: Text(L10n.text('Google Drive')),
      content: Text(message),
      actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tint = TegnalColors.tint.resolveFrom(context);
    String bytes(int value) => FileByteCount.format(value, language: L10n.language);
    final account = _sync.account;
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Text(L10n.text('Google Drive')),
      children: [
        SettingsToggleRow(
          title: L10n.text('Google Drive Sync'),
          help: L10n.text(
            'Keeps both libraries, folders and general settings in sync across your Android devices through a TEGNAL folder in your Google Drive. Layout, viewer preferences, downloaded media and sign-in details stay on each device.',
          ),
          value: _sync.enabled,
          onChanged: _sync.isConfigured && !_connecting ? _toggle : null,
        ),
        if (account != null) SettingsValueRow(title: L10n.text('Google Account'), value: account.email),
        if (_sync.documentBytes != null) SettingsValueRow(title: L10n.text('This Device’s Sync Data'), value: bytes(_sync.documentBytes!)),
        if (_sync.cloudBytes != null && _sync.cloudDocumentCount > 0)
          SettingsValueRow(title: L10n.text('Google Drive Sync Documents'), value: bytes(_sync.cloudBytes!)),
        if (_sync.enabled && account != null)
          FormRow(
            separatorInset: settingsIconInset,
            onTap: _sync.syncing ? null : _sync.synchronize,
            child: Opacity(
              opacity: _sync.syncing ? 0.4 : 1,
              child: Row(
                children: [
                  SizedBox(width: 24, child: Icon(CupertinoIcons.arrow_2_circlepath, size: 22, color: tint)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(L10n.text('Sync Now'), style: TegnalType.style(17, color: tint)),
                  ),
                  if (_sync.syncing) const CupertinoActivityIndicator(),
                ],
              ),
            ),
          ),
        if (_sync.isConfigured)
          account == null
              ? SettingsLinkRow(
                  title: L10n.text('Connect Google Account'),
                  icon: CupertinoIcons.person_crop_circle_badge_plus,
                  tinted: true,
                  chevron: false,
                  onTap: _connecting ? null : _connect,
                )
              : SettingsLinkRow(title: L10n.text('Disconnect Google Account'), destructive: true, chevron: false, onTap: _sync.disconnect),
      ],
    );
  }
}
