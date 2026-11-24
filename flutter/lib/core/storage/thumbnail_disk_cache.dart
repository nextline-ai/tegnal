import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Device-local, regenerable previews and pages. Filenames contain no site URLs or tags.
/// An in-memory index avoids scanning the cache directory on every read (`BooruThumbnailDiskCache`).
class ThumbnailDiskCache {
  ThumbnailDiskCache({required this.directory, int capacity = 256 * 1024 * 1024, this.fileExtension = 'png'}) : _capacity = capacity < 0 ? 0 : capacity;

  final Directory directory;
  int _capacity;
  int get capacity => _capacity;

  /// Applies a new size limit at once, removing the least recently used files above it.
  set capacity(int value) {
    _capacity = value < 0 ? 0 : value;
    _ensureIndex();
    _trim();
  }

  /// Bytes the cache holds now, after any trimming to its limit.
  int get usedBytes {
    _ensureIndex();
    return _bytes;
  }

  final String fileExtension;
  final _entries = <String, _Entry>{};

  /// Bytes written to the index whose files are still being saved; reads serve them from here.
  final _writing = <String, Uint8List>{};
  Future<void> _writes = Future.value();

  /// Completes once every write started so far is on disk.
  Future<void> get idle => _writes;
  int _bytes = 0;
  bool _indexed = false;

  /// The full index, read on this isolate. Only for what needs every file at once (the size used, a new limit, clearing);
  /// everything else waits for [_scanInBackground] and looks at its one file meanwhile.
  void _ensureIndex() {
    if (_indexed) return;
    _indexed = true;
    for (final (name, size, modified) in _scan(directory.path, fileExtension)) {
      if (_entries.containsKey(name)) continue;
      final time = DateTime.fromMillisecondsSinceEpoch(modified);
      _entries[name] = _Entry(size: size, accessed: time, persisted: time);
      _bytes += size;
    }
    _trim();
  }

  /// Lists the cache directory with each file's size and time. On a slow phone with a full cache this is thousands of file
  /// checks, so the app runs it on another isolate ([_scanInBackground]); on the UI isolate, which Android now runs on the
  /// main thread, it held up input long enough for "Input dispatching timed out".
  static List<(String, int, int)> _scan(String path, String extension) {
    final found = <(String, int, int)>[];
    try {
      for (final file in Directory(path).listSync(followLinks: false)) {
        if (file is! File || !file.path.endsWith('.$extension')) continue;
        try {
          final stat = file.statSync();
          found.add((file.uri.pathSegments.last, stat.size, stat.modified.millisecondsSinceEpoch));
        } on FileSystemException {
          continue;
        }
      }
    } on FileSystemException {
      // No directory yet.
    }
    return found;
  }

  Future<void>? _scanning;

  /// Builds the index on another isolate, once. Called by the first lookup; [prepare] starts it earlier.
  Future<void> _scanInBackground() => _scanning ??= () async {
    final path = directory.path, extension = fileExtension;
    final List<(String, int, int)> found;
    try {
      found = await Isolate.run(() => _scan(path, extension));
    } on Object {
      return;
    }
    if (_indexed) return;
    _indexed = true;
    for (final (name, size, modified) in found) {
      // A file looked up, written or removed meanwhile is already known as it is now.
      if (_entries.containsKey(name) || _removed.contains(name)) continue;
      final time = DateTime.fromMillisecondsSinceEpoch(modified);
      _entries[name] = _Entry(size: size, accessed: time, persisted: time);
      _bytes += size;
    }
    _removed.clear();
    _trim();
  }();

  /// Starts reading the index in the background, so the first thumbnail needs no scan at all.
  Future<void> prepare() => _indexed ? Future.value() : _scanInBackground();

  final _removed = <String>{};

  /// The entry for one file: from the index, or until it is read, from that file alone (one quick check).
  _Entry? _entry(String name) {
    final known = _entries[name];
    if (known != null || _indexed) return known;
    _scanInBackground();
    if (_removed.contains(name)) return null;
    try {
      final stat = _file(name).statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      final entry = _Entry(size: stat.size, accessed: stat.modified, persisted: stat.modified);
      _entries[name] = entry;
      _bytes += stat.size;
      return entry;
    } on FileSystemException {
      return null;
    }
  }

  String _name(String key) => '${sha256.convert(utf8.encode(key))}.$fileExtension';
  File _file(String name) => File('${directory.path}/$name');

  bool contains(String key) => _entry(_name(key)) != null;

  Uint8List? read(String key, {DateTime? now}) {
    final name = _name(key), file = _file(name);
    final entry = _entry(name);
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
        entry.persisted = time;
      } on FileSystemException {
        // Recency is a hint for trimming only.
      }
    }
    entry.accessed = time;
    return data;
  }

  void write(Uint8List data, String key, {DateTime? now}) {
    if (!_indexed) _scanInBackground();
    if (data.length > capacity) return;
    final time = now ?? DateTime.now();
    final name = _name(key);
    _bytes -= _entries[name]?.size ?? 0;
    _entries[name] = _Entry(size: data.length, accessed: time, persisted: time);
    _bytes += data.length;
    _removed.remove(name);
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
    final name = _name(key);
    final entry = _entry(name);
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
    final name = _name(key);
    if (!_indexed) _removed.add(name);
    _removeName(name);
  }

  void _removeName(String name) {
    _writing.remove(name);
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
    // Before the full index lands this trims among the files known so far; the index trims again once it arrives.
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
