import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/backup/automatic_backups.dart';
import '../../core/backup/backup_container.dart';
import '../../core/backup/update_backup.dart';
import '../../core/downloads/download_store.dart';
import '../../core/support/app_platform.dart';
import '../../core/support/l10n.dart';
import '../design/alert_dialog.dart';
import '../design/context_menu.dart';
import '../design/grouped_form.dart';
import '../design/pull_down_menu.dart' show anchorRectOf;
import '../design/system_colors.dart';
import '../design/tegnal_theme.dart';
import 'settings_page.dart';
import 'settings_rows.dart';

/// Words for a backup, shared by the list, the restore question and the "restart now" cover.
abstract final class AutomaticBackupText {
  /// An abbreviated date and a short time, in the app's own language and the device's time zone.
  static String date(DateTime date) {
    date = date.toLocal();
    final minute = date.minute.toString().padLeft(2, '0');
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    switch (L10n.language) {
      case 'ko':
        return '${date.year}년 ${date.month}월 ${date.day}일 ${date.hour < 12 ? '오전' : '오후'} $hour12:$minute';
      case 'ja':
        return '${date.year}年${date.month}月${date.day}日 ${date.hour}:$minute';
      default:
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${months[date.month - 1]} ${date.day}, ${date.year} at $hour12:$minute ${date.hour < 12 ? 'AM' : 'PM'}';
    }
  }

  /// Binary units, as the 100 MB limit is counted in; small sizes read as the file sizes elsewhere do.
  static String size(int bytes) {
    final language = L10n.language;
    if (bytes < 1000) return FileByteCount.format(bytes, language: language);
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var index = 0;
    while (value >= 1023.5 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    var text = value.toStringAsFixed(index == 0 ? 0 : 1);
    if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return language == 'ko' ? '$text${units[index]}' : '$text ${units[index]}';
  }

  /// What the backup is, from how it was made.
  static String title(BackupItem item) {
    switch (item.kind) {
      case BackupKind.minor:
        final version = item.appVersion;
        return version == null ? L10n.text('Before an update') : L10n.text('Before the update to %@', [version]);
      case BackupKind.patch:
        final version = item.appVersion;
        if (version == null) return L10n.text('Before an update');
        // A build-only update has the same version number as the one before it.
        final build = item.appBuild;
        return build == null ? L10n.text('Before the update to %@', [version]) : L10n.text('Before the update to %@ (%@)', [version, build]);
      case BackupKind.manual:
        return L10n.text('Manual backup');
      case BackupKind.safety:
        return L10n.text('Before a restore');
    }
  }

  static String dataVersion(String? version) => version == null ? L10n.text('Data from an earlier version') : L10n.text('Data from %@', [version]);
}

/// Backups made before updates, by hand and before restores: see them, restore one, export or delete.
class AutomaticBackupsView extends StatefulWidget {
  /// [hasDrive] is whether this app has Google Drive at all; without it the Drive switch and its footer are left out.
  AutomaticBackupsView({super.key, required this.backups, bool? hasDrive}) : hasDrive = hasDrive ?? AppPlatform.hasDriveSync;
  final AutomaticBackups backups;
  final bool hasDrive;

  @override
  State<AutomaticBackupsView> createState() => _AutomaticBackupsViewState();
}

class _AutomaticBackupsViewState extends State<AutomaticBackupsView> {
  String? _message;

  /// Covers the moment between a tap and the model reporting that it is working.
  bool _acting = false;

  AutomaticBackups get _backups => widget.backups;

  @override
  void initState() {
    super.initState();
    unawaited(_backups.refresh());
  }

  /// One action at a time; a failure is shown under the buttons.
  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _acting = true;
      _message = null;
    });
    try {
      await work();
    } on Object catch (error) {
      _message = error is BackupError ? error.message : '$error';
    }
    if (mounted) setState(() => _acting = false);
  }

  Future<void> _import() => _run(() async {
    if (await _backups.importFromFile() != null) _message = L10n.text('The backup was added to the list.');
  });

  Future<void> _restore(BackupItem item) async {
    final restore = await _confirm(
      title: L10n.text('Restore This Backup?'),
      message: [
        L10n.text('Everything in TEGNAL is replaced by the backup of %@. It is not merged with what you have now.', [AutomaticBackupText.date(item.createdAt)]),
        L10n.text('Your current data is backed up first, so you can go back.'),
        L10n.text(
          'Passwords, sign-ins, downloaded files and covers are not part of a backup and stay as they are. Website favorites sync asks again how to start.',
        ),
        L10n.text('TEGNAL has to be closed and opened again to finish.'),
      ].join('\n\n'),
      action: L10n.text('Restore'),
    );
    if (restore) await _run(() => _backups.restore(item));
  }

  Future<void> _delete(BackupItem item) async {
    final delete = await _confirm(
      title: item.isProtected ? L10n.text('Delete an Always-Kept Backup?') : L10n.text('Delete This Backup?'),
      message: item.isProtected
          ? L10n.text(
              'TEGNAL keeps this backup whatever the total size, so you can go back after an update. Once it is deleted, you can no longer go back to this version of your data. This can’t be undone.',
            )
          : L10n.text(
              widget.hasDrive
                  ? 'This backup is deleted from this device and from Google Drive. This can’t be undone.'
                  : 'This backup is deleted from this device. This can’t be undone.',
            ),
      action: item.isProtected ? L10n.text('Delete Anyway') : L10n.text('Delete'),
    );
    if (delete) await _run(() => _backups.delete(item));
  }

  Future<bool> _confirm({required String title, required String message, required String action}) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          // Not wrapped in anything: the alert styles and orders its buttons by their type.
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(context, true), child: Text(action)),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Cancel'))),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  List<ContextMenuAction> _actions(BackupItem item) => [
    ContextMenuAction(title: L10n.text('Restore…'), icon: CupertinoIcons.arrow_counterclockwise, onSelected: () => _restore(item)),
    ContextMenuAction(title: L10n.text('Export to File'), icon: CupertinoIcons.square_arrow_up, onSelected: () => _run(() => _backups.exportToFile(item))),
    ContextMenuAction(title: L10n.text('Delete…'), icon: CupertinoIcons.trash, destructive: true, onSelected: () => _delete(item)),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _backups,
    builder: (context, _) {
      final row = FormColors.listRow.resolveFrom(context);
      final blocked = _acting || _backups.isWorking || _backups.pendingRestore != null;
      Widget section({String? header, Widget? footer, required List<Widget> children}) =>
          FormSection(prominentHeader: true, rowColor: row, header: header == null ? null : Text(header), footer: footer, children: children);
      final notices = _notices(context);
      return SettingsPage(
        title: L10n.text('Automatic Backups'),
        children: [
          if (notices.isNotEmpty) ...[section(children: notices), settingsSectionGap],
          _status(context, blocked),
          settingsSectionGap,
          _list(context, blocked),
        ],
      );
    },
  );

  // MARK: Notices

  /// Something that went wrong on its own, or a restore that just finished, in the screen's own words.
  List<Widget> _notices(BuildContext context) {
    final report = _backups.lastRestore;
    final shown = report != null && DateTime.now().difference(report.date) < const Duration(days: 7) ? report : null;
    final failure = _backups.lastFailure;
    return [
      if (shown != null)
        _Notice(
          identifier: 'backups.restoreNotice',
          icon: shown.succeeded ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.exclamationmark_triangle_fill,
          color: shown.succeeded ? SystemColors.green.resolveFrom(context) : SystemColors.orange.resolveFrom(context),
          text: shown.succeeded ? _restoredNotice(shown) : L10n.text('The last restore did not finish, so your library was left as it was.'),
          onDismiss: _backups.dismissRestoreReport,
        ),
      if (failure != null)
        _Notice(
          identifier: 'backups.failureNotice',
          icon: CupertinoIcons.exclamationmark_triangle_fill,
          color: SystemColors.orange.resolveFrom(context),
          text: L10n.text('A backup could not be completed on %@ (TEGNAL %@). Your library was not changed. Back Up Now saves a copy.', [
            AutomaticBackupText.date(failure.date),
            failure.appVersion,
          ]),
          onDismiss: _backups.dismissFailure,
        ),
    ];
  }

  String _restoredNotice(BackupRestoreReport report) {
    final made = BackupName.tryParse(report.backup)?.createdAt;
    return made == null
        ? L10n.text('Your library was restored from a backup.')
        : L10n.text('Your library was restored from the backup of %@.', [AutomaticBackupText.date(made)]);
  }

  // MARK: Status

  Widget _status(BuildContext context, bool blocked) {
    final tint = TegnalColors.tint.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final orange = SystemColors.orange.resolveFrom(context);
    final available = _backups.driveAvailable;
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      footer: !widget.hasDrive
          ? null
          : available
          ? Text(L10n.text('New backups are copied to Google Drive, so they can come back if you lose this device. This is separate from Google Drive Sync.'))
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 4),
                  child: Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 13, color: orange),
                ),
                Expanded(
                  child: Text(L10n.text('Google Drive is not available. Backups stay on this device until it is.'), style: TegnalType.style(13, color: orange)),
                ),
              ],
            ),
      children: [
        // Without Drive the switch stays as it was set but cannot change.
        if (widget.hasDrive)
          Semantics(
            identifier: 'backups.keepInDrive',
            child: SettingsToggleRow(
              title: L10n.text('Keep in Google Drive'),
              icon: CupertinoIcons.cloud,
              value: _backups.keepInDrive,
              onChanged: available ? (value) => unawaited(_backups.setKeepInDrive(value)) : null,
            ),
          ),
        Semantics(
          identifier: 'backups.size',
          child: SettingsValueRow(
            title: L10n.text('Space Used'),
            value: L10n.text('%@ of %@', [AutomaticBackupText.size(_backups.totalSize), AutomaticBackupText.size(AutomaticBackups.limit)]),
          ),
        ),
        Semantics(
          identifier: 'backups.backUpNow',
          child: FormRow(
            separatorInset: settingsIconInset,
            onTap: blocked ? null : () => _run(_backups.backUpNow),
            child: Opacity(
              opacity: blocked ? 0.4 : 1,
              child: Row(
                children: [
                  SizedBox(width: 24, child: Icon(CupertinoIcons.plus_app, size: 22, color: tint)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(L10n.text('Back Up Now'), style: TegnalType.style(17, color: tint)),
                  ),
                  if (blocked && _backups.pendingRestore == null) const CupertinoActivityIndicator(),
                ],
              ),
            ),
          ),
        ),
        Semantics(
          identifier: 'backups.import',
          child: SettingsLinkRow(
            title: L10n.text('Import from File'),
            icon: CupertinoIcons.square_arrow_down,
            tinted: true,
            chevron: false,
            onTap: blocked ? null : _import,
          ),
        ),
        if (_message != null)
          FormRow(
            child: Semantics(
              identifier: 'backups.message',
              child: Text(_message!, style: TegnalType.style(13, color: secondary)),
            ),
          ),
      ],
    );
  }

  // MARK: List

  Widget _list(BuildContext context, bool blocked) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final items = _backups.items;
    return FormSection(
      prominentHeader: true,
      rowColor: FormColors.listRow.resolveFrom(context),
      header: Text(L10n.text('Backups')),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            L10n.text(
              'Backups are kept up to %@ in total. The two newest backups made before updates, the newest one made before a major update, the newest one made before a restore and the newest one made by hand are always kept; older ones are removed first when the limit is reached.',
              [AutomaticBackupText.size(AutomaticBackups.limit)],
            ),
          ),
          const SizedBox(height: 8),
          Text(L10n.text('A backup holds your libraries, folders and settings. It does not hold passwords, sign-ins, downloaded files or covers.')),
        ],
      ),
      children: [
        if (items.isEmpty)
          FormRow(
            child: Semantics(
              identifier: 'backups.empty',
              child: Text(L10n.text('No backups yet. One is made automatically before each update.'), style: TegnalType.style(17, color: secondary)),
            ),
          ),
        for (final item in items) _BackupRow(key: ValueKey(item.id), item: item, blocked: blocked, actions: _actions(item)),
      ],
    );
  }
}

/// A line above the lists with a Dismiss button, for a failed backup or a restore that has just finished.
class _Notice extends StatelessWidget {
  const _Notice({required this.identifier, required this.icon, required this.color, required this.text, required this.onDismiss});
  final String identifier;
  final IconData icon;
  final Color color;
  final String text;
  final FutureOr<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) => FormRow(
    child: Semantics(
      identifier: identifier,
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          const SizedBox(width: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(Future.sync(onDismiss)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(L10n.text('Dismiss'), style: TegnalType.style(13, color: TegnalColors.tint.resolveFrom(context))),
            ),
          ),
        ],
      ),
    ),
  );
}

class _BackupRow extends StatelessWidget {
  const _BackupRow({super.key, required this.item, required this.blocked, required this.actions});
  final BackupItem item;
  final bool blocked;
  final List<ContextMenuAction> actions;

  /// A small icon and its text on one line.
  Widget _mark(BuildContext context, String text, IconData icon) {
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: secondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text, style: TegnalType.style(13, color: secondary)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final menuColor = TegnalColors.tint.resolveFrom(context);
    return Builder(
      builder: (context) => GestureDetector(
        // The same actions as the menu button, as a long press opens them on iOS.
        onLongPress: blocked ? null : () => showActionMenu(context, anchor: anchorRectOf(context), actions: actions),
        child: FormRow(
          minHeight: 0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  identifier: 'backups.row',
                  container: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AutomaticBackupText.date(item.createdAt),
                          style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                        ),
                        const SizedBox(height: 3),
                        Text(AutomaticBackupText.title(item), style: TegnalType.style(15, color: label)),
                        const SizedBox(height: 3),
                        Text(
                          '${AutomaticBackupText.dataVersion(item.dataVersion)} · ${AutomaticBackupText.size(item.size)}',
                          style: TegnalType.style(13, color: secondary),
                        ),
                        if (!item.isThisDevice)
                          _mark(
                            context,
                            item.deviceName == null ? L10n.text('From another device') : L10n.text('From %@', [item.deviceName!]),
                            CupertinoIcons.device_phone_portrait,
                          ),
                        if (item.isProtected) _mark(context, L10n.text('Always kept'), CupertinoIcons.pin_fill),
                        switch (item.download) {
                          BackupDownload.onDevice => const SizedBox.shrink(),
                          BackupDownload.inCloud => _mark(context, L10n.text('In Google Drive, not on this device yet'), CupertinoIcons.cloud_download),
                          BackupDownload.downloading => _mark(context, L10n.text('Downloading from Google Drive…'), CupertinoIcons.cloud_download),
                        },
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                identifier: 'backups.menu',
                button: true,
                label: L10n.text('Backup Actions'),
                excludeSemantics: true,
                child: Builder(
                  builder: (button) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: blocked ? null : () => showActionMenu(button, anchor: anchorRectOf(button), actions: actions),
                    child: Opacity(
                      opacity: blocked ? 0.4 : 1,
                      child: SizedBox.square(dimension: 36, child: Icon(CupertinoIcons.ellipsis_circle, size: 22, color: menuColor)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Covers the whole app while a restore waits for the app to be closed and opened again. It has no
/// way out but cancelling: until then nothing has been replaced, and using the app would only be undone.
class PendingRestoreCover extends StatelessWidget {
  const PendingRestoreCover({super.key, required this.backups});
  final AutomaticBackups backups;

  Future<void> _cancel(BuildContext context) async {
    try {
      backups.cancelPendingRestore();
    } on Object catch (error) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text('Unable to Save')),
          content: Text(error is BackupError ? error.message : '$error'),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('Done')))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = TegnalColors.label.resolveFrom(context);
    final secondary = TegnalColors.secondaryLabel.resolveFrom(context);
    final red = SystemColors.red.resolveFrom(context);
    final pending = backups.pendingRestore;
    return ColoredBox(
      color: FormColors.listBackground.resolveFrom(context),
      child: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.arrow_2_circlepath_circle_fill, size: 64, color: TegnalColors.tint.resolveFrom(context)),
                    const SizedBox(height: 18),
                    Semantics(
                      identifier: 'backups.pending.title',
                      child: Text(
                        L10n.text('Restore Is Ready'),
                        textAlign: TextAlign.center,
                        style: TegnalType.style(28, weight: FontWeight.w700, color: label),
                      ),
                    ),
                    if (pending != null) ...[
                      const SizedBox(height: 18),
                      Text(
                        AutomaticBackupText.date(pending.createdAt),
                        textAlign: TextAlign.center,
                        style: TegnalType.style(17, weight: FontWeight.w600, color: label),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AutomaticBackupText.dataVersion(pending.dataVersion),
                        textAlign: TextAlign.center,
                        style: TegnalType.style(15, color: secondary),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      L10n.text('Close TEGNAL completely, then open it again. The restore finishes while it starts.'),
                      textAlign: TextAlign.center,
                      style: TegnalType.style(17, color: label),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      L10n.text('Until then nothing has changed. Cancel the restore to keep using TEGNAL as it is.'),
                      textAlign: TextAlign.center,
                      style: TegnalType.style(13, color: secondary),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Semantics(
                  identifier: 'backups.pending.cancel',
                  button: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _cancel(context),
                    child: Container(
                      height: 50,
                      alignment: Alignment.center,
                      decoration: ShapeDecoration(color: red.withValues(alpha: 0.15), shape: const StadiumBorder()),
                      child: Text(
                        L10n.text('Cancel Restore'),
                        style: TegnalType.style(17, weight: FontWeight.w600, color: red),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps [PendingRestoreCover] over the whole app while `backups.pendingRestore` is set. It is a route
/// on the app's own navigator that refuses to pop, so the back button and gesture cannot reach what lies
/// beneath it, and it sits above every screen and sheet that was open.
class PendingRestoreGate extends StatefulWidget {
  const PendingRestoreGate({super.key, required this.backups, required this.navigatorKey, required this.child});
  final AutomaticBackups backups;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<PendingRestoreGate> createState() => _PendingRestoreGateState();
}

class _PendingRestoreGateState extends State<PendingRestoreGate> {
  Route<void>? _route;

  @override
  void initState() {
    super.initState();
    widget.backups.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    widget.backups.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    final pending = widget.backups.pendingRestore != null;
    final route = _route;
    if (pending && route == null) {
      _route = PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => PopScope(
          canPop: false,
          child: ListenableBuilder(
            listenable: widget.backups,
            builder: (context, _) => PendingRestoreCover(backups: widget.backups),
          ),
        ),
      );
      unawaited(navigator.push(_route!));
    } else if (!pending && route != null) {
      _route = null;
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
