import 'backup_container.dart';

/// Which backups go. Works from names and sizes only.
///
/// Automatic backups made every few days are thinned as they age, so the kept ones grow further
/// apart rather than the oldest simply disappearing. When all backups together are still over the
/// limit, the one whose removal leaves the smallest gap for its age goes first, again widening the
/// spacing instead of cutting off the past.
abstract final class BackupRetention {
  static const limit = 100 * 1024 * 1024;
  static const _day = Duration(days: 1);

  /// How often an automatic backup is made while the app is used.
  static const periodicInterval = Duration(days: 3);

  /// How far apart kept automatic backups are, by age: every one for the first two weeks, then
  /// one in each two weeks until twelve weeks, one in each eight weeks until a year, and one in
  /// each 24 weeks after that. A null limit is the last tier.
  static const tiers = <(Duration?, Duration)>[
    (Duration(days: 14), Duration.zero),
    (Duration(days: 84), Duration(days: 14)),
    (Duration(days: 364), Duration(days: 56)),
    (null, Duration(days: 168)),
  ];

  /// Per device, the two newest `patch` backups and the newest `minor`, `safety`, `manual` and `periodic` ones are
  /// always kept: the safety backup is the only way back from a restore, and a manual one is something the person asked for.
  static Set<String> protected(List<BackupRetentionItem> items) {
    final kept = <String>{};
    for (final ofDevice in _byDevice(_unique(items)).values) {
      final newest = [...ofDevice]..sort((a, b) => _compare(b, a));
      kept.addAll(newest.where((item) => item.kind == BackupKind.patch).take(2).map((item) => item.name));
      for (final kind in [BackupKind.minor, BackupKind.safety, BackupKind.manual, BackupKind.periodic]) {
        kept.addAll(newest.where((item) => item.kind == kind).take(1).map((item) => item.name));
      }
    }
    return kept;
  }

  /// Automatic backups the spacing no longer needs. Within each window of an age tier only the
  /// oldest stays, so a window keeps the same backup as newer ones age into it. Windows are fixed
  /// in time, not counted from today, so what is kept does not shift from day to day.
  static List<String> thinned(List<BackupRetentionItem> items, {required DateTime now, Set<String> keeping = const {}}) {
    final kept = {...protected(items), ...keeping};
    final deleted = <String>[];
    final periodic = _unique(items).where((item) => item.kind == BackupKind.periodic).toList();
    for (final ofDevice in _byDevice(periodic).values) {
      final windows = <String>{};
      for (final item in [...ofDevice]..sort(_compare)) {
        final age = now.difference(item.date);
        final tier = tiers.indexWhere((tier) => tier.$1 == null || age < tier.$1!);
        if (tier < 0 || tiers[tier].$2 == Duration.zero) continue;
        final window = '$tier:${(item.date.millisecondsSinceEpoch / tiers[tier].$2.inMilliseconds).floor()}';
        if (!windows.add(window) && !kept.contains(item.name)) deleted.add(item.name);
      }
    }
    return deleted;
  }

  /// The backups to delete until the rest fit; [keeping] (the backup just made) is never among
  /// them. Each step removes the unprotected backup whose removal leaves the smallest gap for its
  /// age, so older backups grow further apart. The oldest and newest of all go only when nothing
  /// else can.
  static List<String> expired(List<BackupRetentionItem> items, {int limit = limit, Set<String> keeping = const {}, DateTime? now}) {
    final at = now ?? DateTime.now();
    final timeline = _unique(items)..sort(_compare);
    var total = timeline.fold<int>(0, (sum, item) => sum + item.size);
    if (total <= limit) return [];
    final kept = {...protected(timeline), ...keeping};
    final deleted = <String>[];
    while (total > limit) {
      int? best;
      var bestScore = double.infinity;
      for (var index = 0; index < timeline.length; index++) {
        final item = timeline[index];
        if (kept.contains(item.name)) continue;
        var score = double.infinity;
        if (index > 0 && index < timeline.length - 1) {
          final gap = timeline[index + 1].date.difference(timeline[index - 1].date).inSeconds;
          final age = at.difference(item.date);
          score = gap / (age > _day ? age : _day).inSeconds;
        }
        // Ties go to the older backup.
        if (best == null || score < bestScore) {
          best = index;
          bestScore = score;
        }
      }
      if (best == null) break;
      final item = timeline.removeAt(best);
      deleted.add(item.name);
      total -= item.size;
    }
    return deleted;
  }

  static int _compare(BackupRetentionItem a, BackupRetentionItem b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.name.compareTo(b.name);
  }

  static Map<String, List<BackupRetentionItem>> _byDevice(List<BackupRetentionItem> items) {
    final byDevice = <String, List<BackupRetentionItem>>{};
    for (final item in items) {
      byDevice.putIfAbsent(item.device, () => []).add(item);
    }
    return byDevice;
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
