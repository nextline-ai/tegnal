import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

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
  GalleryFeedLoader({required this.source, required this.images, this.pageSize = 24});

  final ContentProviding source;
  final PageImageStore images;
  final int pageSize;

  final Map<int, GalleryFeedPreview> previews = {};
  List<int> ids = [];
  bool didLoad = false;
  bool loading = false;
  bool hasMore = false;
  String? error;

  Object _generation = Object();
  int _nextOffset = 0;
  GalleryQuery? _currentQuery;
  bool _lastReset = true;
  bool _suspended = false;
  Future<void>? _task;
  Set<int> _retained = {};

  GalleryQuery? get currentQuery => _currentQuery;

  Future<void> load(GalleryQuery query, {required bool reset}) {
    if (_suspended) return Future.value();
    if (!reset && loading && _currentQuery == query && _task != null) return _task!;
    final changedQuery = _currentQuery != query;
    if (changedQuery) {
      for (final preview in previews.values) {
        preview.cancel();
      }
      previews.clear();
      _retained = {};
      ids = [];
      _nextOffset = 0;
      hasMore = false;
      didLoad = false;
    }
    _currentQuery = query;
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
        final batch = await source.list(query, offset: offset, count: pageSize);
        if (!identical(_generation, token)) return;
        final seen = resetting ? <int>{} : ids.toSet();
        final incoming = batch.ids.where(seen.add).toList();
        final updated = [...(resetting ? const <int>[] : ids), ...incoming];
        if (resetting) previews.clear();
        for (final id in incoming) {
          previews[id] = GalleryFeedPreview(id: id, source: source, images: images);
        }
        ids = updated;
        didLoad = true;
        _nextOffset = offset + batch.ids.length;
        hasMore = batch.hasMore && batch.ids.isNotEmpty && (resetting || incoming.isNotEmpty);
      } on Object catch (caught) {
        if (identical(_generation, token)) error = ContentError.message(caught);
      }
      if (identical(_generation, token)) {
        loading = false;
        notifyListeners();
      }
    }();
  }

  Future<void> retry(GalleryQuery query) => load(query, reset: _lastReset);

  /// Keeps covers for a bounded neighborhood of the viewport and releases the rest.
  void retainCovers(int index) {
    if (ids.isEmpty) return;
    final start = (index - 36).clamp(0, (ids.length - 72).clamp(0, ids.length));
    final end = (start + 72).clamp(0, ids.length);
    final retained = ids.sublist(start, end).toSet();
    for (final id in _retained.difference(retained)) {
      previews[id]?.discardDisplayContent();
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
