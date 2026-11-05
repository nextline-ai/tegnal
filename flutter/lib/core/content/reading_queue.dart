import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import '../support/l10n.dart';
import '../support/preferences.dart';
import 'gallery_content.dart';

/// `ReadingQueueItem`: a work waiting to be read, kept with what the list shows so the list
/// never has to load it.
@immutable
class ReadingQueueItem {
  const ReadingQueueItem({required this.id, required this.title, required this.artists, required this.details, this.site});

  factory ReadingQueueItem.fromGallery({
    required int id,
    NativeGallery? gallery,
    String? title,
    String? artists,
    String? language,
    String? type,
    String? site,
  }) => ReadingQueueItem(
    id: id,
    title: gallery?.title ?? title ?? '',
    artists: gallery?.artists.join(', ') ?? artists ?? '',
    details: [gallery?.language ?? language, gallery?.type ?? type].whereType<String>().where((part) => part.isNotEmpty).join(' · '),
    site: site == null || site.isEmpty ? null : site,
  );

  factory ReadingQueueItem.fromJson(Map<String, Object?> json) => ReadingQueueItem(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String? ?? '',
    artists: json['artists'] as String? ?? '',
    details: json['details'] as String? ?? '',
    site: json['site'] as String?,
  );

  final int id;
  final String title;
  final String artists;
  final String details;

  /// The comics site the work was found on, so it opens there.
  final String? site;

  String get displayTitle => title.isEmpty ? L10n.text('Work %@', ['$id']) : title;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'artists': artists, 'details': details, if (site != null) 'site': site};
}

/// `ReadingQueue`: Up Next for comics, like a music queue. Works held and carried down, or added
/// from a menu, wait here in order; a work leaves once it is read to its last page or removed.
class ReadingQueue extends ChangeNotifier {
  ReadingQueue(this._preferences, {Directory? covers}) : _covers = covers ?? defaultCoverDirectory {
    final stored = _preferences.string(key);
    if (stored != null) {
      try {
        _items = [for (final entry in jsonDecode(stored) as List<Object?>) ReadingQueueItem.fromJson((entry as Map).cast<String, Object?>())];
      } on Object {
        _items = [];
      }
    }
  }

  static const key = 'manga.readingQueue';

  /// Set at launch to the app's cache folder.
  static Directory defaultCoverDirectory = Directory('${Directory.systemTemp.path}/ReadingQueue');

  final Preferences _preferences;
  final Directory _covers;
  List<ReadingQueueItem> _items = [];

  List<ReadingQueueItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// Changes with every work that joins, for the bar's arrival bounce.
  int arrivals = 0;

  bool contains(int id) => _items.any((item) => item.id == id);

  /// Adds the work at the end. A work already waiting keeps its place.
  bool add(ReadingQueueItem item, {Future<Uint8List?>? cover}) {
    if (contains(item.id)) return false;
    _items = [..._items, item];
    arrivals++;
    _save();
    if (cover != null) unawaited(_storeCover(item.id, cover));
    notifyListeners();
    return true;
  }

  void remove(int id) {
    if (!contains(id)) return;
    _items = _items.where((item) => item.id != id).toList();
    _coverCache.remove(id);
    try {
      _coverFile(id).deleteSync();
    } on Object {
      // Nothing was stored for it.
    }
    _save();
    notifyListeners();
  }

  /// Moves a work, with [to] counted after it has left its place.
  void move(int from, int to) {
    final list = [..._items];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    _items = list;
    _save();
    notifyListeners();
  }

  void clear() {
    _items = [];
    _coverCache.clear();
    try {
      if (_covers.existsSync()) _covers.deleteSync(recursive: true);
    } on Object {
      // Covers are only a cache.
    }
    _save();
    notifyListeners();
  }

  /// A work read to its last page has been read.
  void finished(int id) => remove(id);

  /// The works from the given one to the end, in the order the reader pages through them.
  List<int> sequence(int from) {
    final index = _items.indexWhere((item) => item.id == from);
    return index < 0 ? [from] : [for (final item in _items.skip(index)) item.id];
  }

  // MARK: Carrying

  /// The work being carried to the drop panel, and where the finger is.
  ReadingQueueItem? carried;
  ui.Image? carriedCover;
  Future<Uint8List?>? _carriedCoverData;
  Offset carryLocation = Offset.zero;
  bool isOverDropZone = false;

  /// The drop panel's frame on screen, measured while it shows.
  Rect dropZone = Rect.zero;

  void beginCarry(ReadingQueueItem item, {ui.Image? image, Future<Uint8List?>? cover, required Offset at}) {
    carried = item;
    carriedCover = image;
    _carriedCoverData = cover;
    moveCarry(at);
  }

  void moveCarry(Offset location) {
    if (carried == null) return;
    carryLocation = location;
    isOverDropZone = dropZone.contains(location);
    notifyListeners();
  }

  /// Lets go of the carried work: it joins the list when let go over the drop panel.
  bool endCarry() {
    final item = carried;
    final over = isOverDropZone;
    final cover = _carriedCoverData;
    carried = null;
    carriedCover = null;
    _carriedCoverData = null;
    isOverDropZone = false;
    if (item == null || !over) {
      notifyListeners();
      return false;
    }
    final added = add(item, cover: cover);
    if (!added) notifyListeners();
    return added;
  }

  // MARK: Covers

  final _coverCache = <int, Uint8List>{};

  File _coverFile(int id) => File('${_covers.path}/$id.jpg');

  /// The stored cover, read once and kept for the list and the bar.
  Uint8List? cover(int id) {
    final cached = _coverCache[id];
    if (cached != null) return cached;
    try {
      final file = _coverFile(id);
      if (!file.existsSync()) return null;
      return _coverCache[id] = file.readAsBytesSync();
    } on Object {
      return null;
    }
  }

  Future<void> _storeCover(int id, Future<Uint8List?> loading) async {
    try {
      final data = await loading;
      if (data == null || !contains(id)) return;
      _covers.createSync(recursive: true);
      _coverFile(id).writeAsBytesSync(data);
      _coverCache[id] = data;
      notifyListeners();
    } on Object {
      // The row shows a placeholder.
    }
  }

  void _save() {
    if (_items.isEmpty) {
      _preferences.remove(key);
    } else {
      _preferences.set(key, jsonEncode([for (final item in _items) item.toJson()]));
    }
  }
}
