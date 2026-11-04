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
    try {
      directory.createSync(recursive: true);
      final name = _name(key), file = _file(name);
      final temporary = File('${file.path}.tmp');
      temporary.writeAsBytesSync(data, flush: true);
      temporary.renameSync(file.path);
      try {
        file.setLastModifiedSync(time);
      } on FileSystemException {
        // Recency is a hint.
      }
      _bytes -= _entries[name]?.size ?? 0;
      _entries[name] = _Entry(data.length, time, time);
      _bytes += data.length;
      _trim();
    } on FileSystemException {
      // A full disk must not prevent viewing a downloaded preview.
    }
  }

  void remove(String key) {
    _ensureIndex();
    _removeName(_name(key));
  }

  void _removeName(String name) {
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
