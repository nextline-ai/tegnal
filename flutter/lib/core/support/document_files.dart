import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/services.dart';

import 'app_platform.dart';

/// The system document picker: on the phone through `work.nextline.tegnal/files` in
/// `MainActivity`, on a computer through its own save and open dialogs. Saving and opening
/// need no storage permission; the person picks the place.
class DocumentFiles {
  const DocumentFiles();

  static const _channel = MethodChannel('work.nextline.tegnal/files');

  /// Asks where to save [source] as [name]. True once written, false when cancelled.
  Future<bool> createDocument({required String name, required File source, String mimeType = 'application/json'}) async {
    if (AppPlatform.isDesktop) {
      final location = await FileSelectorPlatform.instance.getSaveLocation(
        acceptedTypeGroups: [
          _group(name, [mimeType]),
        ],
        options: SaveDialogOptions(suggestedName: name),
      );
      if (location == null) return false;
      await source.copy(location.path);
      return true;
    }
    return await _channel.invokeMethod<bool>('createDocument', {'name': name, 'mimeType': mimeType, 'sourcePath': source.path}) ?? false;
  }

  /// A copy of the picked document, or null when cancelled. Callers delete the copy when done,
  /// so on a computer the person's own file is copied first and never touched.
  Future<File?> openDocument({List<String> mimeTypes = const []}) async {
    if (AppPlatform.isDesktop) {
      final file = await FileSelectorPlatform.instance.openFile(acceptedTypeGroups: [if (mimeTypes.isNotEmpty) _group('', mimeTypes)]);
      if (file == null) return null;
      final folder = await Directory.systemTemp.createTemp('tegnal-open-');
      return File(file.path).copy('${folder.path}/${file.name}');
    }
    final path = await _channel.invokeMethod<String>('openDocument', {'mimeTypes': mimeTypes});
    return path == null ? null : File(path);
  }

  /// Desktop dialogs filter by extension; Linux also by MIME type.
  static XTypeGroup _group(String name, List<String> mimeTypes) {
    final extensions = {
      if (name.contains('.')) name.split('.').last,
      for (final type in mimeTypes)
        ...switch (type) {
          'application/json' || 'text/json' => ['json'],
          'text/plain' => ['txt', 'json'],
          'image/png' => ['png'],
          _ => const <String>[],
        },
    };
    return XTypeGroup(label: extensions.isEmpty ? null : extensions.first.toUpperCase(), extensions: extensions.toList(), mimeTypes: mimeTypes);
  }
}
