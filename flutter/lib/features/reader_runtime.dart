import '../core/content.dart';
import '../core/library.dart';

/// Keep caller order and the selected item's freshest metadata in linear time.
class ReaderSequence {
  static List<ContentItem> ordered(
    ContentItem selected,
    Iterable<ContentItem> supplied,
  ) {
    if (selected.mode != AppMode.booru) return [selected];
    final selectedKey = selected.key;
    final seen = <String>{};
    final ordered = <ContentItem>[];
    for (final item in supplied) {
      final key = item.key;
      if (item.mode == AppMode.booru && seen.add(key)) {
        ordered.add(key == selectedKey ? selected : item);
      }
    }
    if (!seen.contains(selectedKey)) ordered.insert(0, selected);
    return ordered;
  }
}

/// Visible and speculative requests must select the same media and cache key.
class ReaderMediaPolicy {
  static List<ReaderPage> pages(
    ContentItem item,
    List<ReaderPage> source,
    ReaderPreferences preferences, {
    required bool offline,
  }) {
    if (offline || source.length != 1) return source;
    final original = preferences.originalImages;
    final reduced =
        !original &&
        preferences.reducedData &&
        item.mode == AppMode.booru &&
        item.mediaType != 'video';
    if (!original && !reduced) return source;
    final candidate = Uri.tryParse(
      item.metadata[original ? 'fileURL' : 'previewURL'] as String? ?? '',
    );
    if (candidate == null ||
        candidate.scheme != 'https' ||
        candidate.host.isEmpty ||
        candidate.userInfo.isNotEmpty) {
      return source;
    }
    final page = source.single;
    return [
      ReaderPage(
        url: candidate,
        thumbnailUrl: page.thumbnailUrl,
        width: page.width,
        height: page.height,
        headers: page.headers,
      ),
    ];
  }
}

/// Reused cumulative geometry; scrolling only searches an existing index.
class ReaderPageOffsets {
  ReaderPageOffsets(Iterable<double> extents) {
    for (final extent in extents) {
      _offsets.add(_offsets.last + extent);
    }
  }
  final List<double> _offsets = [0];
  int get length => _offsets.length - 1;
  double offset(int page) => _offsets[page.clamp(0, length)];
  int pageAt(double position) {
    if (length == 0) return 0;
    var low = 0;
    var high = length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_offsets[middle] <= position) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }
}

/// Replaces obsolete speculative work while limiting concurrent image loads.
class ReaderPrefetchQueue {
  ReaderPrefetchQueue({this.maxConcurrent = 2}) : assert(maxConcurrent > 0);

  final int maxConcurrent;
  final List<Future<void> Function()> _pending = [];
  int _running = 0;
  bool _closed = false;

  void replace(Iterable<Future<void> Function()> jobs) {
    if (_closed) return;
    _pending
      ..clear()
      ..addAll(jobs);
    _start();
  }

  void clear() => _pending.clear();

  void close() {
    _closed = true;
    clear();
  }

  void _start() {
    while (!_closed && _running < maxConcurrent && _pending.isNotEmpty) {
      final job = _pending.removeAt(0);
      _running++;
      Future<void>.sync(job).catchError((Object _) {}).whenComplete(() {
        _running--;
        _start();
      });
    }
  }
}

class ReaderPostNeighbors {
  static List<int> indices(int current, int length) {
    return [
      current + 1,
      current - 1,
      current + 2,
      current - 2,
    ].where((index) => index >= 0 && index < length).toList(growable: false);
  }
}
