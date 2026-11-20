import 'backup_container.dart';

/// Which backups go when all of them together are over the limit. Works from names and sizes only.
abstract final class BackupRetention {
  static const limit = 100 * 1024 * 1024;

  /// Per device, the two newest `patch` backups and the newest `minor`, `safety` and `manual` ones are always kept:
  /// the safety backup is the only way back from a restore, and a manual one is something the person asked for.
  static Set<String> protected(List<BackupRetentionItem> items) {
    final kept = <String>{};
    final byDevice = <String, List<BackupRetentionItem>>{};
    for (final item in _unique(items)) {
      byDevice.putIfAbsent(item.device, () => []).add(item);
    }
    for (final ofDevice in byDevice.values) {
      final newest = [...ofDevice]..sort((a, b) => _compare(b, a));
      kept.addAll(newest.where((item) => item.kind == BackupKind.patch).take(2).map((item) => item.name));
      for (final kind in [BackupKind.minor, BackupKind.safety, BackupKind.manual]) {
        kept.addAll(newest.where((item) => item.kind == kind).take(1).map((item) => item.name));
      }
    }
    return kept;
  }

  /// The backups to delete, oldest unprotected first, until the rest fit; [keeping] (the backup
  /// just made) is never among them.
  static List<String> expired(List<BackupRetentionItem> items, {int limit = limit, Set<String> keeping = const {}}) {
    final all = _unique(items);
    var total = all.fold<int>(0, (sum, item) => sum + item.size);
    if (total <= limit) return [];
    final kept = {...protected(all), ...keeping};
    final deleted = <String>[];
    for (final item in all.where((item) => !kept.contains(item.name)).toList()..sort(_compare)) {
      if (total <= limit) break;
      deleted.add(item.name);
      total -= item.size;
    }
    return deleted;
  }

  static int _compare(BackupRetentionItem a, BackupRetentionItem b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.name.compareTo(b.name);
  }

  /// A backup kept in two places counts once.
  static List<BackupRetentionItem> _unique(List<BackupRetentionItem> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.name)) item,
    ];
  }
}

class BackupRetentionItem {
  const BackupRetentionItem({required this.name, required this.size, required this.device, required this.kind, required this.date});
  final String name;
  final int size;
  final String device;
  final BackupKind kind;
  final DateTime date;
}
