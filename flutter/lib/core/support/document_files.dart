import 'dart:io';

import 'package:flutter/services.dart';

/// The system document picker, through `work.nextline.tegnal/files` in `MainActivity`.
/// Saving and opening need no storage permission; the person picks the place.
class DocumentFiles {
  const DocumentFiles();

  static const _channel = MethodChannel('work.nextline.tegnal/files');

  /// Asks where to save [source] as [name]. True once written, false when cancelled.
  Future<bool> createDocument({required String name, required File source, String mimeType = 'application/json'}) async =>
      await _channel.invokeMethod<bool>('createDocument', {'name': name, 'mimeType': mimeType, 'sourcePath': source.path}) ?? false;

  /// A copy of the picked document in the app cache, or null when cancelled.
  Future<File?> openDocument({List<String> mimeTypes = const []}) async {
    final path = await _channel.invokeMethod<String>('openDocument', {'mimeTypes': mimeTypes});
    return path == null ? null : File(path);
  }
}
