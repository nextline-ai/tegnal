import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../storage/work_query.dart';
import '../support/preferences.dart';
import 'gallery_content.dart';
import 'reading_queue.dart';

/// How many recently opened works or images a list keeps: none, or up to 500 in steps of ten,
/// 50 unless changed.
abstract final class RecentLimit {
  static const standard = 50;
  static const maximum = 500;
  static const step = 10;

  static int stored(Preferences preferences, String key) => (preferences.integerOrNull(key) ?? standard).clamp(0, maximum);
  static int clamped(int value) => ((value ~/ step) * step).clamp(0, maximum);
}

/// A work opened in the viewer lately, kept with what the list shows and what Saved search
/// looks through, so the list never has to load it.
@immutable
class RecentWork {
  const RecentWork({required this.item, required this.openedAt, this.language, this.type, this.tags});

  factory RecentWork.fromJson(Map<String, Object?> json) => RecentWork(
    item: ReadingQueueItem.fromJson((json['item'] as Map).cast<String, Object?>()),
    openedAt: DateTime.fromMillisecondsSinceEpoch(((json['openedAt'] as num?) ?? 0).toInt()),
    language: json['language'] as String?,
    type: json['type'] as String?,
    tags: (json['tags'] as List?)?.whereType<String>().toList(),
  );

  final ReadingQueueItem item;
  final DateTime openedAt;
  final String? language;
  final String? type;
  final List<String>? tags;
  int get id => item.id;

  /// Saved search applies to recent works the same way.
  bool matches(WorkQuery query) => query.matches(
    WorkFields(galleryID: id, title: item.title, artists: item.artists, language: language ?? '', type: type ?? '', tags: (tags ?? const []).join(', ')),
  );

  Map<String, Object?> toJson() => {
    'item': item.toJson(),
    'openedAt': openedAt.millisecondsSinceEpoch,
    if (language != null) 'language': language,
    if (type != null) 'type': type,
    if (tags != null) 'tags': tags,
  };
}

/// `RecentWorks`: comics opened in the viewer, newest first. Opening a work again moves it to
/// the top; the oldest leave once the list passes the count chosen in Settings. Kept on this
/// device only.
class RecentWorks extends ChangeNotifier {
  RecentWorks(this._preferences, {Directory? covers}) : _covers = covers ?? defaultCoverDirectory {
    _limit = RecentLimit.stored(_preferences, limitKey);
    final stored = _preferences.string(key);
    if (stored != null) {
      try {
        _entries = [for (final entry in jsonDecode(stored) as List<Object?>) RecentWork.fromJson((entry as Map).cast<String, Object?>())];
      } on Object {
        _entries = [];
      }
    }
    _trim();
  }

  static const key = 'manga.recentWorks';
  static const limitKey = 'manga.recentWorks.limit';

  /// Set at launch to the app's cache folder.
  static Directory defaultCoverDirectory = Directory('${Directory.systemTemp.path}/RecentWorks');

  /// The app's list, installed at launch; the reader adds to it.
  static RecentWorks? shared;

  final Preferences _preferences;
  final Directory _covers;
  List<RecentWork> _entries = [];
  late int _limit;

  List<RecentWork> get entries => List.unmodifiable(_entries);

  /// How many works the list keeps; none turns it off.
  int get limit => _limit;

  /// A lower count drops the oldest works at once; none clears the list.
  void setLimit(int value) {
    _limit = RecentLimit.clamped(value);
    _preferences.set(limitKey, _limit);
    _trim();
    _save();
    notifyListeners();
  }

  void openedGallery(NativeGallery gallery, {String? site, DateTime? at, Future<Uint8List?>? cover}) => opened(
    RecentWork(
      item: ReadingQueueItem.fromGallery(id: gallery.id, gallery: gallery, site: site),
      openedAt: at ?? DateTime.now(),
      language: gallery.language,
      type: gallery.type,
      tags: gallery.tags,
    ),
    cover: cover,
  );

  void opened(RecentWork work, {Future<Uint8List?>? cover}) {
    if (_limit == 0) return;
    _entries = [work, ..._entries.where((entry) => entry.id != work.id)];
    _trim();
    _save();
    if (cover != null && !hasCover(work.id)) unawaited(_storeCover(work.id, cover));
    notifyListeners();
  }

  void remove(int id) {
    _entries = _entries.where((entry) => entry.id != id).toList();
    _deleteCover(id);
    _save();
    notifyListeners();
  }

  void clear() {
    _entries = [];
    _coverCache.clear();
    try {
      if (_covers.existsSync()) _covers.deleteSync(recursive: true);
    } on Object {
      // Covers are only a cache.
    }
    _save();
    notifyListeners();
  }

  // MARK: Covers

  final _coverCache = <int, Uint8List>{};
  File _coverFile(int id) => File('${_covers.path}/$id.jpg');
  bool hasCover(int id) => _coverCache.containsKey(id) || _coverFile(id).existsSync();

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
      if (data == null || !_entries.any((entry) => entry.id == id)) return;
      _covers.createSync(recursive: true);
      _coverFile(id).writeAsBytesSync(data);
      _coverCache[id] = data;
      notifyListeners();
    } on Object {
      // The row shows a placeholder.
    }
  }

  void _deleteCover(int id) {
    _coverCache.remove(id);
    try {
      _coverFile(id).deleteSync();
    } on Object {
      // Nothing was stored for it.
    }
  }

  void _trim() {
    if (_entries.length <= _limit) return;
    for (final entry in _entries.skip(_limit)) {
      _deleteCover(entry.id);
    }
    _entries = _entries.take(_limit).toList();
  }

  void _save() {
    if (_entries.isEmpty) {
      _preferences.remove(key);
    } else {
      _preferences.set(key, jsonEncode([for (final entry in _entries) entry.toJson()]));
    }
  }
}

/// An image opened in the viewer lately.
@immutable
class RecentImage {
  const RecentImage({required this.post, required this.openedAt});

  factory RecentImage.fromJson(Map<String, Object?> json) => RecentImage(
    post: BooruPost.fromJson((json['post'] as Map).cast<String, Object?>()),
    openedAt: DateTime.fromMillisecondsSinceEpoch(((json['openedAt'] as num?) ?? 0).toInt()),
  );

  final BooruPost post;
  final DateTime openedAt;
  String get id => post.id;

  Map<String, Object?> toJson() => {'post': post.toJson(), 'openedAt': openedAt.millisecondsSinceEpoch};
}

/// `RecentImages`: image mode's recently opened images, kept like comics' recent works, in
/// image mode's own settings.
class RecentImages extends ChangeNotifier {
  RecentImages(this._preferences) {
    _limit = RecentLimit.stored(_preferences, limitKey);
    final stored = _preferences.string(key);
    if (stored != null) {
      try {
        _entries = [for (final entry in jsonDecode(stored) as List<Object?>) RecentImage.fromJson((entry as Map).cast<String, Object?>())];
      } on Object {
        _entries = [];
      }
    }
    _trim();
  }

  static const key = 'booru.recentPosts';
  static const limitKey = 'booru.recentPosts.limit';

  /// The app's list, installed at launch; the image viewer adds to it.
  static RecentImages? shared;

  final Preferences _preferences;
  List<RecentImage> _entries = [];
  late int _limit;

  List<RecentImage> get entries => List.unmodifiable(_entries);
  int get limit => _limit;

  void setLimit(int value) {
    _limit = RecentLimit.clamped(value);
    _preferences.set(limitKey, _limit);
    _trim();
    _save();
    notifyListeners();
  }

  void opened(BooruPost post, {DateTime? at}) {
    if (_limit == 0) return;
    _entries = [RecentImage(post: post, openedAt: at ?? DateTime.now()), ..._entries.where((entry) => entry.id != post.id)];
    _trim();
    _save();
    notifyListeners();
  }

  void remove(String id) {
    _entries = _entries.where((entry) => entry.id != id).toList();
    _save();
    notifyListeners();
  }

  void clear() {
    _entries = [];
    _save();
    notifyListeners();
  }

  void _trim() {
    if (_entries.length > _limit) _entries = _entries.take(_limit).toList();
  }

  void _save() {
    if (_entries.isEmpty) {
      _preferences.remove(key);
    } else {
      _preferences.set(key, jsonEncode([for (final entry in _entries) entry.toJson()]));
    }
  }
}
