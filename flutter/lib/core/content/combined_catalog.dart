import 'dart:async';
import 'dart:typed_data';

import 'gallery_content.dart';
import 'manga_content_source.dart';
import 'manga_urls.dart';

/// `SiteContent`: one connected website's works, read inside its scope with caches of its
/// own, whichever website is checked.
class SiteContent extends ContentProviding {
  SiteContent(this.site, {MangaContentSource? inner}) : _inner = inner ?? MangaContentSource();
  final String site;
  final MangaContentSource _inner;

  @override
  Future<List<TagSuggestion>> suggestions(String token) => SiteScope.run(site, () => _inner.suggestions(token));
  @override
  Future<NativeGallery> gallery(int id) => SiteScope.run(site, () => _inner.gallery(id));
  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) =>
      SiteScope.run(site, () => _inner.list(query, offset: offset, count: count));
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) =>
      SiteScope.run(site, () => _inner.image(page, galleryID: galleryID, thumbnail: thumbnail));
  @override
  NativeGallery? cachedGallery(int id) => SiteScope.run(site, () => _inner.cachedGallery(id));
  @override
  NativeGallery? cachedPreview(int id) => SiteScope.run(site, () => _inner.cachedPreview(id));

  static final _sources = <String, SiteContent>{};

  /// The shared reader of a connected website.
  static SiteContent of(String site) => _sources.putIfAbsent(site, () => SiteContent(site));
}

/// `FeedItem`: a work in a list that shows several websites: its number means something only
/// together with the website it came from.
class FeedItem {
  const FeedItem(this.id, this.site);
  final int id;
  final String site;

  @override
  bool operator ==(Object other) => other is FeedItem && other.id == id && other.site == site;
  @override
  int get hashCode => Object.hash(id, site);
  @override
  String toString() => 'FeedItem($id, $site)';
}

class CombinedBatch {
  const CombinedBatch({required this.items, required this.hasMore});
  final List<FeedItem> items;
  final bool hasMore;
}

class _Lane {
  int offset = 0;
  bool more = true;
  final pending = <int>[];
  final seen = <int>{};
  Object? error;
}

/// `CombinedCatalog`: lists every connected website at once. Each website keeps its own page
/// position; their works are taken in turn. Every website numbers its works the same way, so
/// a number another website already showed is left out before it is shown, and nothing
/// disappears on screen.
class CombinedCatalog {
  CombinedCatalog({this.pageSize = 24, ContentProviding Function(String site)? sourceFor}) : _sourceFor = sourceFor ?? SiteContent.of;

  final int pageSize;
  final ContentProviding Function(String site) _sourceFor;

  GalleryQuery? _query;
  List<String> _sites = const [];
  var _lanes = <String, _Lane>{};
  final _emitted = <FeedItem>[];
  final _shown = <int>{};

  /// Works left out because another website already showed them.
  int leftOut = 0;

  Future<void> _tail = Future.value();

  /// [offset] 0 starts over; later offsets continue, and one already answered is answered
  /// again the same way, so a page whose answer was dropped is not lost. Requests run one at
  /// a time, as on the native actor.
  Future<CombinedBatch> list(GalleryQuery query, {required List<String> sites, required int offset, required int count}) {
    final run = _tail.then((_) => _list(query, sites: sites, offset: offset, count: count));
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<CombinedBatch> _list(GalleryQuery query, {required List<String> sites, required int offset, required int count}) async {
    if (offset == 0 || query != _query || !_sameSites(sites)) _reset(query, sites);
    while (_emitted.length < offset + count && _lanes.values.any((lane) => lane.pending.isNotEmpty || lane.more)) {
      await _fill();
      if (!_takeRound() && !_lanes.values.any((lane) => lane.more)) break;
    }
    if (_emitted.length <= offset) {
      final failures = [for (final site in sites) _lanes[site]?.error].nonNulls.toList();
      final allDone = sites.every((site) => _lanes[site]?.error != null || (_lanes[site]!.pending.isEmpty && !_lanes[site]!.more));
      if (failures.isNotEmpty && allDone) throw failures.first;
    }
    final more = _lanes.values.any((lane) => lane.pending.isNotEmpty || lane.more);
    return CombinedBatch(items: _emitted.skip(offset).take(count).toList(), hasMore: more || _emitted.length > offset + count);
  }

  bool _sameSites(List<String> sites) => sites.length == _sites.length && Iterable.generate(sites.length).every((index) => sites[index] == _sites[index]);

  void _reset(GalleryQuery query, List<String> sites) {
    _query = query;
    _sites = [...sites];
    _lanes = {for (final site in sites) site: _Lane()};
    _emitted.clear();
    _shown.clear();
    leftOut = 0;
  }

  /// Reads the next page of every website that has run out of works to give.
  Future<void> _fill() async {
    final query = _query;
    if (query == null) return;
    final needed = _sites.where((site) => _lanes[site]!.pending.isEmpty && _lanes[site]!.more).toList();
    if (needed.isEmpty) return;
    final pages = await Future.wait([
      for (final site in needed)
        _sourceFor(site)
            .list(query, offset: _lanes[site]!.offset, count: pageSize)
            .then<(String, GalleryBatch?, Object?)>((batch) => (site, batch, null), onError: (Object error) => (site, null, error)),
    ]);
    for (final (site, batch, error) in pages) {
      final lane = _lanes[site]!;
      if (batch != null) {
        lane.offset += batch.ids.length;
        lane.more = batch.hasMore && batch.ids.isNotEmpty;
        for (final id in batch.ids) {
          if (lane.seen.add(id)) lane.pending.add(id);
        }
      } else {
        // One website failing leaves the others showing.
        lane.error = error;
        lane.more = false;
      }
    }
  }

  /// Takes one work from each website in turn. Returns whether any was taken.
  bool _takeRound() {
    var took = false;
    for (final site in _sites) {
      final lane = _lanes[site]!;
      while (lane.pending.isNotEmpty) {
        final item = FeedItem(lane.pending.removeAt(0), site);
        if (!_shown.add(item.id)) {
          leftOut += 1;
          continue;
        }
        _emitted.add(item);
        took = true;
        break;
      }
    }
    return took;
  }
}
