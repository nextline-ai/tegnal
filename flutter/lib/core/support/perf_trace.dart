import 'dart:async';
import 'dart:developer' as developer;

/// Opt-in timing logs for finding slow paths on a device. Builds made with
/// `--dart-define=TEGNAL_TRACE=true` print one `[perf]` line per traced step; other
/// builds skip the work entirely.
abstract final class PerfTrace {
  static const enabled = bool.fromEnvironment('TEGNAL_TRACE');

  /// Steps faster than this are not logged, so the log shows only what a person could notice.
  static const _threshold = Duration(milliseconds: 4);

  static Future<T> span<T>(String name, Future<T> Function() body, {String? detail}) async {
    if (!enabled) return body();
    final watch = Stopwatch()..start();
    final task = developer.TimelineTask()..start(name);
    try {
      return await body();
    } finally {
      task.finish();
      log(name, watch.elapsed, detail: detail);
    }
  }

  static T sync<T>(String name, T Function() body, {String? detail}) {
    if (!enabled) return body();
    final watch = Stopwatch()..start();
    try {
      return developer.Timeline.timeSync(name, body);
    } finally {
      log(name, watch.elapsed, detail: detail);
    }
  }

  /// A measurement that is not a duration, such as a frame summary.
  static void event(String name, {String? detail}) {
    if (!enabled) return;
    // ignore: avoid_print
    print('[perf] $name${detail == null ? '' : ' $detail'}');
  }

  static void log(String name, Duration elapsed, {String? detail}) {
    if (!enabled || elapsed < _threshold) return;
    // `print` reaches logcat in every build mode, unlike `debugPrint` throttling.
    // ignore: avoid_print
    print('[perf] ${elapsed.inMilliseconds.toString().padLeft(5)}ms $name${detail == null ? '' : ' $detail'}');
  }
}
