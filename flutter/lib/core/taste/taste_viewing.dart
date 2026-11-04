import 'dart:math' as math;

import 'taste_models.dart';

/// `TasteViewingSession`: time spent looking at one item, paused while the viewer is
/// covered and capped per idle stretch.
class TasteViewingSession {
  static const idleLimit = 120.0;
  static const minimum = 3.0;

  double _seconds = 0;
  final _pages = <int>{};
  bool _finished = false;
  DateTime? _mark;

  double _counted(DateTime date) {
    final mark = _mark;
    return mark == null ? 0 : math.min(idleLimit, math.max(0, date.difference(mark).inMilliseconds / 1000));
  }

  void resume([DateTime? date]) => _mark ??= date ?? DateTime.now();

  void pause([DateTime? date]) {
    _seconds += _counted(date ?? DateTime.now());
    _mark = null;
  }

  /// Each page restarts the idle window, so continuous reading is never truncated.
  void show(int page, {bool isLast = false, DateTime? date}) {
    final now = date ?? DateTime.now();
    if (_mark != null) {
      _seconds += _counted(now);
      _mark = now;
    }
    _pages.add(page);
    if (isLast) _finished = true;
  }

  /// Ends the session. Opening an item and leaving at once is not viewing time.
  TasteDwell? finish([DateTime? date]) {
    pause(date);
    final seconds = _seconds, pages = _pages.length, finished = _finished;
    _seconds = 0;
    _pages.clear();
    _finished = false;
    if (seconds < minimum) return null;
    return TasteDwell(seconds: seconds.roundToDouble(), pages: math.max(1, pages), finished: finished);
  }
}
