import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Where both libraries, covers and sync files live. Android has no shared app
/// group, so the app's own support directory takes the native container's place,
/// with the same layout: `memo.sqlite`, `booru.sqlite` and `thumbs/` at its root.
abstract final class AppStorage {
  static Directory? _container;

  /// Resolved once at launch, before either database opens.
  static Future<Directory> prepare() async => _container = resolveContainer(await getApplicationSupportDirectory());

  /// Creates the directory and proves it can be written, as the native app does.
  static Directory resolveContainer(Directory directory) {
    directory.createSync(recursive: true);
    final probe = File('${directory.path}/.storage-check-${DateTime.now().microsecondsSinceEpoch}');
    try {
      probe.writeAsBytesSync(const [], flush: true);
    } finally {
      if (probe.existsSync()) probe.deleteSync();
    }
    return directory;
  }

  static Directory get container => _container ?? (throw StateError('AppStorage.prepare() has not run'));

  static String get localDbPath => '${container.path}/memo.sqlite';
  static String get booruDbPath => '${container.path}/booru.sqlite';

  /// Covers are a cache, which the native app keeps out of device backups.
  // The Android backup rules do not exclude it yet; that comes with covers (step 3).
  static Directory get thumbsDir {
    final directory = Directory('${container.path}/thumbs');
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return directory;
  }

  /// A file whose header names an image format the app can decode.
  static bool isReadableThumbnail(File file) {
    try {
      if (!file.existsSync()) return false;
      final handle = file.openSync();
      try {
        return _isImageHeader(handle.readSync(12));
      } finally {
        handle.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  static bool _isImageHeader(Uint8List bytes) {
    bool starts(List<int> prefix, [int offset = 0]) {
      if (bytes.length < offset + prefix.length) return false;
      for (var index = 0; index < prefix.length; index++) {
        if (bytes[offset + index] != prefix[index]) return false;
      }
      return true;
    }

    return starts([0xFF, 0xD8, 0xFF]) || // JPEG
        starts([0x89, 0x50, 0x4E, 0x47]) || // PNG
        starts([0x47, 0x49, 0x46, 0x38]) || // GIF
        (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) || // WebP
        starts([0x66, 0x74, 0x79, 0x70], 4); // HEIF and AVIF
  }
}
