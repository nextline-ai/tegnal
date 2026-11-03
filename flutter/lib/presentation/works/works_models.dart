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

/// A month of saved works in the order they are shown, for "Jump to Saved Month".
class WorkMonthDestination {
  WorkMonthDestination({required this.id, required this.firstGalleryID, required this.count});

  /// The save month as `yyyy-MM`, or whatever the first seven characters of the save date are.
  final String id;
  final int firstGalleryID;
  int count;

  String get title {
    final parts = id.split('-').where((part) => part.isNotEmpty).toList();
    final month = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (month == null) return L10n.text('No Date');
    return L10n.text('%@-%@', [parts[0], '$month']);
  }

  static List<WorkMonthDestination> make(List<Work> works) {
    final destinations = <WorkMonthDestination>[];
    final positions = <String, int>{};
    for (final work in works) {
      final date = work.bookmarkedAt;
      final month = date.length > 7 ? date.substring(0, 7) : date;
      final index = positions[month];
      if (index != null) {
        destinations[index].count += 1;
      } else {
        positions[month] = destinations.length;
        destinations.add(WorkMonthDestination(id: month, firstGalleryID: work.galleryId, count: 1));
      }
    }
    return destinations;
  }
}
