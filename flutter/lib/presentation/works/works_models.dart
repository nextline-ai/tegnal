import '../../core/support/l10n.dart';
import '../../domain/models.dart';

/// Accumulates movement so slow drags and 120 Hz displays behave like fast swipes.
/// It holds no visible state: only a visibility change is reported.
class ScrollSearchVisibility {
  double _travel = 0;

  /// True to show the search bar, false to hide it, null to leave it as it is.
  bool? update({required double oldY, required double newY, required bool focused}) {
    if (focused || newY <= 15) {
      _travel = 0;
      return true;
    }
    final delta = newY - oldY;
    if (delta.abs() <= 0.1) return null;
    if (_travel * delta < 0) {
      _travel = delta;
    } else {
      _travel += delta;
    }
    if (_travel >= 32) {
      _travel = 0;
      return false;
    }
    if (_travel <= -24) {
      _travel = 0;
      return true;
    }
    return null;
  }
}

/// Saved items of one month in the order they are shown, for "Browse by Saved Date".
class SavedMonth<T> {
  SavedMonth({required this.id, required T firstGalleryID, List<T>? ids}) : ids = ids ?? [firstGalleryID];

  /// The save month as `yyyy-MM`, or whatever the first seven characters of the save date are.
  final String id;

  /// The month's items, in the order they are shown.
  final List<T> ids;

  /// The month's first item shown: a work's number, or an image's id.
  T get firstGalleryID => ids.first;
  int get count => ids.length;

  String get title {
    final parts = id.split('-').where((part) => part.isNotEmpty).toList();
    final month = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (month == null) return L10n.text('No Date');
    return L10n.text('%@-%@', [parts[0], '$month']);
  }

  static List<SavedMonth<int>> make(List<Work> works) => group([
    for (final work in works) (id: work.galleryId, month: work.bookmarkedAt.length > 7 ? work.bookmarkedAt.substring(0, 7) : work.bookmarkedAt),
  ]);

  /// Each item with its month, in the order they are shown.
  static List<SavedMonth<T>> group<T>(List<({T id, String month})> items) {
    final destinations = <SavedMonth<T>>[];
    final positions = <String, int>{};
    for (final item in items) {
      final index = positions[item.month];
      if (index != null) {
        destinations[index].ids.add(item.id);
      } else {
        positions[item.month] = destinations.length;
        destinations.add(SavedMonth<T>(id: item.month, firstGalleryID: item.id));
      }
    }
    return destinations;
  }
}

typedef WorkMonthDestination = SavedMonth<int>;

/// `SavedRun`: items saved one right after another, as favorites brought in from a website or an
/// import are: each was saved within a minute of the one before, and there are at least a few.
class SavedRun<T> {
  const SavedRun({required this.start, required this.end, required this.ids});
  final DateTime start;
  final DateTime end;

  /// In the order the list shows them.
  final List<T> ids;
  T get firstGalleryID => ids.first;

  static const gap = Duration(seconds: 60);
  static const minimum = 5;

  /// Saved works, newest run first.
  static List<SavedRun<int>> make(List<Work> works, {Duration gap = gap, int minimum = minimum}) =>
      group([for (final work in works) (id: work.galleryId, date: DateTime.tryParse(work.bookmarkedAt))], gap: gap, minimum: minimum);

  /// Each item with when it was saved, in the order they are shown; newest run first.
  static List<SavedRun<T>> group<T>(List<({T id, DateTime? date})> items, {Duration gap = gap, int minimum = minimum}) {
    final dated = [
      for (final item in items)
        if (item.date case final date?) (id: item.id, date: date),
    ]..sort((a, b) => a.date.compareTo(b.date));
    final groups = <List<({T id, DateTime date})>>[];
    for (final item in dated) {
      final last = groups.lastOrNull?.last;
      if (last != null && item.date.difference(last.date) <= gap) {
        groups.last.add(item);
      } else {
        groups.add([item]);
      }
    }
    final order = <T, int>{};
    for (final (index, item) in items.indexed) {
      order.putIfAbsent(item.id, () => index);
    }
    return [
      for (final group in groups.reversed)
        if (group.length >= minimum)
          SavedRun<T>(
            start: group.first.date,
            end: group.last.date,
            ids: [for (final item in group) item.id]..sort((a, b) => (order[a] ?? 1 << 62).compareTo(order[b] ?? 1 << 62)),
          ),
    ];
  }

  /// Whether this is the favorites a website brought in when its sync was set up.
  bool broughtIn(List<DateTime> times) => times.any((time) => !time.isBefore(start.subtract(gap)) && !time.isAfter(end.add(gap)));
}

typedef WorkSaveBatch = SavedRun<int>;
