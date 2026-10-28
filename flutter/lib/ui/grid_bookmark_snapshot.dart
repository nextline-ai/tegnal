import '../core/content.dart';

/// A lazy grid only queries bookmarks for the small chunk it is about to build.
/// A new parent build creates a fresh snapshot after library/controller changes.
class GridBookmarkSnapshot {
  GridBookmarkSnapshot(this.items, this.load);
  static const chunkSize = 64;
  final List<ContentItem> items;
  final Set<String> Function(Iterable<String>) load;
  final _chunks = <int, Set<String>>{};

  bool contains(int index) {
    final chunk = index ~/ chunkSize;
    final saved = _chunks.putIfAbsent(
      chunk,
      () => load(
        items.skip(chunk * chunkSize).take(chunkSize).map((item) => item.key),
      ),
    );
    return saved.contains(items[index].key);
  }
}
