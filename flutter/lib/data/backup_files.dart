import 'dart:io';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_codec.dart';

class BackupFiles {
  static const _channel = MethodChannel('work.nextline.tegnal/files');
  static Future<String?> pick() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'JSON backup',
          extensions: ['json'],
          mimeTypes: ['application/json', 'application/octet-stream'],
          uniformTypeIdentifiers: ['public.json'],
        ),
      ],
    );
    if (file == null) {
      return null;
    }
    if (await file.length() > BackupCodec.maximumBytes) {
      throw const FormatException('This backup is too large.');
    }
    return file.readAsString();
  }

  /// Saves a recap card through the same user-chosen location as backups.
  static Future<bool> exportImage(Uint8List bytes, String name) async {
    if (Platform.isAndroid) {
      final temp = await getTemporaryDirectory();
      final file = File('${temp.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      try {
        return await _channel.invokeMethod<bool>('exportBackup', {
              'path': file.path,
              'name': name,
              'mimeType': 'image/png',
            }) ??
            false;
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'PNG image', extensions: ['png']),
      ],
    );
    if (location == null) return false;
    await XFile.fromData(
      bytes,
      mimeType: 'image/png',
      name: name,
    ).saveTo(location.path);
    return true;
  }

  static Future<bool> export(String text) async {
    if (Platform.isAndroid) {
      final temp = await getTemporaryDirectory();
      final file = File('${temp.path}/tegnal-backup.json');
      await file.writeAsString(text, flush: true);
      try {
        return await _channel.invokeMethod<bool>('exportBackup', {
              'path': file.path,
              'name': 'tegnal-backup.json',
            }) ??
            false;
      } finally {
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    final location = await getSaveLocation(
      suggestedName: 'tegnal-backup.json',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON backup', extensions: ['json']),
      ],
    );
    if (location == null) {
      return false;
    }
    await XFile.fromData(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'application/json',
      name: 'tegnal-backup.json',
    ).saveTo(location.path);
    return true;
  }
}
