import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Device-local, regenerable previews and pages. Filenames contain no site URLs or tags.
/// An in-memory index avoids scanning the cache directory on every read (`BooruThumbnailDiskCache`).
class ThumbnailDiskCache {
  ThumbnailDiskCache({required this.directory, int capacity = 256 * 1024 * 1024, this.fileExtension = 'png'}) : capacity = capacity < 0 ? 0 : capacity;

  final Directory directory;
  final int capacity;
  final String fileExtension;
  final _entries = <String, _Entry>{};
  int _bytes = 0;
  bool _indexed = false;

  void _ensureIndex() {
    if (_indexed) return;
    _indexed = true;
    if (directory.existsSync()) {
      for (final file in directory.listSync().whereType<File>()) {
        if (!file.path.endsWith('.$fileExtension')) continue;
        try {
          final stat = file.statSync();
          final name = file.uri.pathSegments.last;
          _entries[name] = _Entry(size: stat.size, accessed: stat.modified, persisted: stat.modified);
          _bytes += stat.size;
        } on FileSystemException {
          continue;
        }
      }
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
        entry.persisted = time;
      } on FileSystemException {
        // Recency is a hint for trimming only.
      }
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
      final temporary = File('${file.path}.tmp')..writeAsBytesSync(data, flush: true);
      temporary.renameSync(file.path);
      try {
        file.setLastModifiedSync(time);
      } on FileSystemException {
        // The index below still records the time.
      }
      _bytes -= _entries[name]?.size ?? 0;
      _entries[name] = _Entry(size: data.length, accessed: time, persisted: time);
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
      final file = _file(name);
      if (file.existsSync()) file.deleteSync();
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

class _Entry {
  _Entry({required this.size, required this.accessed, required this.persisted});
  final int size;
  DateTime accessed;
  DateTime persisted;
}
