import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class _Entry {
  _Entry(this.size, this.accessed, this.persisted);
  int size;
  DateTime accessed;
  DateTime persisted;
}

/// Device-local, regenerable previews. File names contain no site addresses or tags.
/// An in-memory index avoids scanning the cache directory on every thumbnail.
class BooruThumbnailDiskCache {
  BooruThumbnailDiskCache({required this.directory, int capacity = 256 * 1024 * 1024, this.fileExtension = 'png'}) : capacity = capacity < 0 ? 0 : capacity;

  /// `Caches/BooruThumbnails`, inside the app's cache directory.
  static Directory defaultDirectory(Directory caches) => Directory('${caches.path}/BooruThumbnails');

  final Directory directory;
  final int capacity;
  final String fileExtension;
  final _entries = <String, _Entry>{};

  /// Bytes written to the index whose files are still being saved; reads serve them from here.
  final _writing = <String, Uint8List>{};
  Future<void> _writes = Future.value();

  /// Completes once every write started so far is on disk.
  Future<void> get idle => _writes;
  var _bytes = 0;
  var _indexed = false;

  void _ensureIndex() {
    if (_indexed) return;
    _indexed = true;
    try {
      for (final file in directory.listSync(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.$fileExtension')) continue;
        try {
          final stat = file.statSync();
          final entry = _Entry(stat.size, stat.modified, stat.modified);
          _entries[file.uri.pathSegments.last] = entry;
          _bytes += entry.size;
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      // No directory yet.
    }
    _trim();
  }

  String _name(String key) => '${sha256.convert(utf8.encode(key))}.$fileExtension';
  File _file(String name) => File('${directory.path}/$name');

  bool contains(String key) {
    _ensureIndex();
    return _entries.containsKey(_name(key));
  }

  Uint8List? read(String key, {DateTime? now}) {
    _ensureIndex();
    final name = _name(key), file = _file(name);
    final entry = _entries[name];
    if (entry == null) return null;
    final pending = _writing[name];
    if (pending != null) {
      entry.accessed = now ?? DateTime.now();
      return pending;
    }
    final Uint8List data;
    try {
      data = file.readAsBytesSync();
    } on FileSystemException {
      remove(key);
      return null;
    }
    final time = now ?? DateTime.now();
    // Persist recency at most hourly; memory still tracks every cache hit.
    if (time.difference(entry.persisted) > const Duration(hours: 1)) {
      try {
        file.setLastModifiedSync(time);
      } on FileSystemException {
        // Recency is a hint.
      }
      entry.persisted = time;
    }
    entry.accessed = time;
    return data;
  }

  void write(Uint8List data, String key, {DateTime? now}) {
    _ensureIndex();
    if (data.length > capacity) return;
    final time = now ?? DateTime.now();
    final name = _name(key);
    _bytes -= _entries[name]?.size ?? 0;
    _entries[name] = _Entry(data.length, time, time);
    _bytes += data.length;
    _writing[name] = data;
    _trim();
    // Saving happens off the frame: the bytes stay readable from memory until the file lands.
    _writes = _writes.then((_) => _persist(name, data, time));
  }

  Future<void> _persist(String name, Uint8List data, DateTime time) async {
    if (!identical(_writing[name], data)) return;
    final file = _file(name), temporary = File('${file.path}.tmp');
    try {
      await directory.create(recursive: true);
      await temporary.writeAsBytes(data);
      // A removal while saving keeps the file from coming back.
      if (!identical(_writing[name], data)) {
        await temporary.delete();
        return;
      }
      await temporary.rename(file.path);
      try {
        await file.setLastModified(time);
      } on FileSystemException {
        // Recency is a hint.
      }
    } on FileSystemException {
      // A full disk must not prevent viewing a downloaded image; the index forgets it.
      if (identical(_writing[name], data)) {
        final old = _entries.remove(name);
        if (old != null) _bytes -= old.size;
      }
    } finally {
      if (identical(_writing[name], data)) _writing.remove(name);
    }
  }

  /// [read] without blocking the frame on the file.
  Future<Uint8List?> readAsync(String key, {DateTime? now}) async {
    _ensureIndex();
    final name = _name(key);
    final entry = _entries[name];
    if (entry == null) return null;
    final time = now ?? DateTime.now();
    entry.accessed = time;
    final pending = _writing[name];
    if (pending != null) return pending;
    final file = _file(name);
    try {
      final data = await file.readAsBytes();
      if (time.difference(entry.persisted) > const Duration(hours: 1)) {
        entry.persisted = time;
        file.setLastModified(time).ignore();
      }
      return data;
    } on FileSystemException {
      if (identical(_entries[name], entry)) remove(key);
      return null;
    }
  }

  void remove(String key) {
    _ensureIndex();
    _removeName(_name(key));
  }

  void _removeName(String name) {
    _writing.remove(name);
    final old = _entries.remove(name);
    if (old != null) _bytes -= old.size;
    try {
      _file(name).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  void _trim() {
    if (_bytes <= capacity) return;
    final names = _entries.keys.toList()..sort((a, b) => _entries[a]!.accessed.compareTo(_entries[b]!.accessed));
    for (final name in names) {
      _removeName(name);
      if (_bytes <= capacity) break;
    }
  }

  void clear() {
    _ensureIndex();
    for (final name in _entries.keys.toList()) {
      _removeName(name);
    }
    _entries.clear();
    _bytes = 0;
  }
}
