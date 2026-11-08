import 'package:cupertino_ui/cupertino_ui.dart';

import '../../core/booru/booru_store.dart';
import '../../core/content/manga_urls.dart';
import '../../core/storage/app_database.dart';
import '../../core/storage/library_backup_actions.dart';
import '../../core/support/l10n.dart';
import '../../core/support/preferences.dart';
import '../design/alert_dialog.dart';
import 'settings_rows.dart';

/// `BackupReminder`: every seven days the app is opened, a library with something in it
/// suggests saving a backup file. Only Settings turns the reminder off; the reminder itself
/// offers no "don't show again".
abstract final class BackupReminder {
  static const enabledKey = 'backup.reminder.enabled';
  static const lastShownKey = 'backup.reminder.lastShown';
  static const lastSavedKey = 'backup.lastSaved';
  static const interval = Duration(days: 7);

  /// Built with `--dart-define=BACKUP_REMINDER_TEST=true`, the reminder shows at every launch.
  static const forced = bool.fromEnvironment('BACKUP_REMINDER_TEST');

  static Preferences get defaults => ContentPreferences.defaults;

  static bool isEnabled([Preferences? store]) => (store ?? defaults).boolean(enabledKey) ?? true;
  static void setEnabled(bool value, [Preferences? store]) => (store ?? defaults).set(enabledKey, value);

  static double _seconds(DateTime date) => date.millisecondsSinceEpoch / 1000;

  static double? _time(Preferences store, String key) => switch (store.object(key)) {
    final num value => value.toDouble(),
    _ => null,
  };

  /// Due once a week has passed since the reminder last showed, or since the last saved backup.
  /// The first time it is asked, the week starts then, so a new install is not asked at once.
  static bool isDue({DateTime? now, Preferences? store}) {
    final preferences = store ?? defaults;
    if (!isEnabled(preferences)) return false;
    final current = _seconds(now ?? DateTime.now());
    final times = [_time(preferences, lastShownKey), _time(preferences, lastSavedKey)].nonNulls;
    if (times.isEmpty) {
      preferences.set(lastShownKey, current);
      return false;
    }
    return current - times.reduce((a, b) => a > b ? a : b) >= interval.inSeconds;
  }

  static void shown({DateTime? now, Preferences? store}) => (store ?? defaults).set(lastShownKey, _seconds(now ?? DateTime.now()));
  static void saved({DateTime? now, Preferences? store}) => (store ?? defaults).set(lastSavedKey, _seconds(now ?? DateTime.now()));
}

/// Shows the weekly reminder over the app when it comes to the front.
class BackupReminderGate extends StatefulWidget {
  const BackupReminderGate({super.key, required this.database, required this.images, required this.child, this.isTesting = false});
  final AppDatabase database;
  final BooruStore images;
  final Widget child;

  /// The test fixture stays quiet unless the reminder is forced.
  final bool isTesting;

  @override
  State<BackupReminderGate> createState() => _BackupReminderGateState();
}

class _BackupReminderGateState extends State<BackupReminderGate> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: _check);
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _asking) return;
    if (widget.isTesting && !BackupReminder.forced) return;
    final hasLibrary = widget.database.worksCount() > 0 || widget.images.favoriteIDs.isNotEmpty;
    if (!hasLibrary) return;
    if (!BackupReminder.forced && !BackupReminder.isDue()) return;
    BackupReminder.shown();
    _asking = true;
    final save = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => TegnalAlertDialog(
        title: Text(L10n.text('Back Up Your Library')),
        content: Text(
          L10n.text(
            'Save a backup file about once a week, so your bookmarks, folders and challenges are safe if this device is lost or reset. You can turn this reminder off in Settings.',
          ),
        ),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(context, false), child: Text(L10n.text('Later'))),
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context, true), child: Text(L10n.text('Save File'))),
        ],
      ),
    );
    _asking = false;
    if (save != true || !mounted) return;
    try {
      if (await LibraryBackupActions(database: widget.database, images: widget.images).export()) BackupReminder.saved();
    } on Object catch (error) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => TegnalAlertDialog(
          title: Text(L10n.text('Unable to create backup: %@', ['$error'])),
          actions: [CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(context), child: Text(L10n.text('OK')))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The only place the weekly reminder turns off.
class BackupReminderToggle extends StatefulWidget {
  const BackupReminderToggle({super.key});

  @override
  State<BackupReminderToggle> createState() => _BackupReminderToggleState();
}

class _BackupReminderToggleState extends State<BackupReminderToggle> {
  @override
  Widget build(BuildContext context) => SettingsToggleRow(
    title: L10n.text('Weekly Backup Reminder'),
    value: BackupReminder.isEnabled(),
    onChanged: (value) => setState(() => BackupReminder.setEnabled(value)),
  );
}
