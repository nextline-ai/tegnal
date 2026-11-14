import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/content/combined_catalog.dart';
import '../../core/content/content_errors.dart';
import '../../core/content/gallery_content.dart';
import 'page_image_store.dart';

/// The text a feed card shows, kept even when its cover is released.
@immutable
class GalleryDisplay {
  GalleryDisplay(NativeGallery gallery) : title = gallery.title, artists = gallery.artists.join(', '), language = gallery.language, type = gallery.type;

  final String title;
  final String artists;
  final String language;
  final String type;

  @override
  bool operator ==(Object other) =>
      other is GalleryDisplay && other.title == title && other.artists == artists && other.language == language && other.type == type;
  @override
  int get hashCode => Object.hash(title, artists, language, type);
}

/// One card's metadata and cover, loaded once and shared by the cell and prefetch.
class GalleryFeedPreview extends ChangeNotifier {
  GalleryFeedPreview({required this.id, required this.source, required this.images}) {
    final cached = source.cachedPreview(id);
    if (cached != null) _setGallery(cached);
    image = _coverHash == null ? null : images.cachedImage(_coverHash!, thumbnail: true);
  }

  final int id;
  final ContentProviding source;
  final PageImageStore images;
  NativeGallery? gallery;
  GalleryDisplay? display;
  ui.Image? image;
  String? _coverHash;
  Future<void>? _request;
  bool _cancelled = false;

  ui.Image? get displayImage {
    if (_cancelled) return null;
    return image ?? (_coverHash == null ? null : images.cachedImage(_coverHash!, thumbnail: true));
  }

  /// Reappearing rows can show an already decoded cover before a load runs.
  void restoreCachedContent() {
    if (_cancelled) return;
    var changed = false;
    if (gallery == null) {
      final cached = source.cachedPreview(id);
      if (cached != null) {
        _setGallery(cached);
        changed = true;
      }
    }
    if (image == null && _coverHash != null) {
      image = images.cachedImage(_coverHash!, thumbnail: true);
      changed |= image != null;
    }
    if (changed) notifyListeners();
  }

  void _setGallery(NativeGallery value) {
    gallery = value;
    display = GalleryDisplay(value);
    _coverHash = value.pages.firstOrNull?.hash;
  }

  Future<void> load() {
    if (_cancelled) return Future.value();
    restoreCachedContent();
    if (image != null && gallery != null) return Future.value();
    return _request ??= _fetch().whenComplete(() => _request = null);
  }

  Future<void> _fetch() async {
    try {
      final value = gallery ?? await source.gallery(id);
      if (_cancelled) return;
      _setGallery(value);
      notifyListeners();
      final page = value.pages.firstOrNull;
      if (page != null) {
        final cover = await images.load(page, galleryID: id, thumbnail: true);
        if (_cancelled) return;
        image = cover;
        notifyListeners();
      }
    } on Object {
      // Keep metadata usable when a cover fails; the detail screen offers a retry.
    }
  }

  /// Releases the cover but keeps the text, so a row above the viewport never collapses.
  void discardDisplayContent() {
    image = null;
    gallery = null;
  }

  void cancel() => _cancelled = true;
}

/// Pagination completes as soon as IDs arrive; covers load around what is visible.
class GalleryFeedLoader extends ChangeNotifier {
  GalleryFeedLoader({required this.source, required this.images, this.pageSize = 24, CombinedCatalog? combined})
    : _combined = combined ?? CombinedCatalog(pageSize: pageSize);

  final ContentProviding source;
  final PageImageStore images;
  final int pageSize;
  final CombinedCatalog _combined;

  final Map<FeedItem, GalleryFeedPreview> previews = {};
  List<FeedItem> items = [];
  List<int> get ids => [for (final item in items) item.id];
  bool didLoad = false;
  bool loading = false;
  bool hasMore = false;
  String? error;

  Object _generation = Object();
  int _nextOffset = 0;
  GalleryQuery? _currentQuery;
  String? _currentSite;
  bool _lastReset = true;
  bool _suspended = false;
  Future<void>? _task;
  Set<FeedItem> _retained = {};

  /// The websites a combined list shows; null while it shows the checked one.
  List<String>? combinedSites;

  GalleryQuery? get currentQuery => _currentQuery;

  static final _siteImages = <String, PageImageStore>{};

  /// The reader of a work's website: in a combined list, that website's own.
  ContentProviding sourceFor(FeedItem item) => combinedSites == null ? source : SiteContent.of(item.site);

  PageImageStore imagesFor(FeedItem item) =>
      combinedSites == null ? images : _siteImages.putIfAbsent(item.site, () => PageImageStore(source: SiteContent.of(item.site)));

  /// The preview of a number in a list of one website, where a number names one work.
  GalleryFeedPreview? preview(int id) => previews.entries.where((entry) => entry.key.id == id).firstOrNull?.value;

  /// [combinedSites] lists those websites together instead of the checked one, whose
  /// address is [site]. Without either, the list goes on as it is.
  Future<void> load(GalleryQuery query, {required bool reset, String? site, List<String>? combinedSites}) {
    if (_suspended) return Future.value();
    final chosen = combinedSites == null && site == null ? this.combinedSites : combinedSites;
    final combined = chosen != null && chosen.length > 1 ? List<String>.of(chosen) : null;
    final listSite = combined != null ? '*${combined.join(',')}' : site ?? _currentSite ?? '';
    if (!reset && loading && _currentQuery == query && _task != null) return _task!;
    final changedQuery = _currentQuery != query || _currentSite != listSite;
    if (changedQuery) {
      for (final preview in previews.values) {
        preview.cancel();
      }
      previews.clear();
      _retained = {};
      items = [];
      _nextOffset = 0;
      hasMore = false;
      didLoad = false;
    }
    _currentQuery = query;
    _currentSite = listSite;
    this.combinedSites = combined;
    final resetting = reset || changedQuery;
    _lastReset = resetting;
    final token = Object();
    _generation = token;
    loading = true;
    error = null;
    notifyListeners();
    final offset = resetting ? 0 : _nextOffset;
    return _task = () async {
      try {
        final CombinedBatch batch;
        if (combined != null) {
          batch = await _combined.list(query, sites: combined, offset: offset, count: pageSize);
        } else {
          final single = await source.list(query, offset: offset, count: pageSize);
          batch = CombinedBatch(items: [for (final id in single.ids) FeedItem(id, listSite)], hasMore: single.hasMore);
        }
        if (!identical(_generation, token)) return;
        final seen = resetting ? <FeedItem>{} : items.toSet();
        final incoming = batch.items.where(seen.add).toList();
        final updated = [...(resetting ? const <FeedItem>[] : items), ...incoming];
        if (resetting) previews.clear();
        for (final item in incoming) {
          previews[item] = GalleryFeedPreview(id: item.id, source: sourceFor(item), images: imagesFor(item));
        }
        items = updated;
        didLoad = true;
        _nextOffset = offset + batch.items.length;
        hasMore = batch.hasMore && batch.items.isNotEmpty && (resetting || incoming.isNotEmpty);
      } on Object catch (caught) {
        if (identical(_generation, token)) error = ContentError.message(caught);
      }
      if (identical(_generation, token)) {
        loading = false;
        notifyListeners();
      }
    }();
  }

  Future<void> retry(GalleryQuery query) => load(query, reset: _lastReset, combinedSites: combinedSites);

  /// Keeps covers for a bounded neighborhood of the viewport and releases the rest.
  void retainCovers(int index) {
    if (items.isEmpty) return;
    final start = (index - 36).clamp(0, (items.length - 72).clamp(0, items.length));
    final end = (start + 72).clamp(0, items.length);
    final retained = items.sublist(start, end).toSet();
    for (final item in _retained.difference(retained)) {
      previews[item]?.discardDisplayContent();
    }
    _retained = retained;
  }

  /// Hidden tabs keep their results but stop starting new requests.
  void suspend() {
    _suspended = true;
    _generation = Object();
    if (loading) {
      loading = false;
      notifyListeners();
    }
  }

  void resume() => _suspended = false;
}
