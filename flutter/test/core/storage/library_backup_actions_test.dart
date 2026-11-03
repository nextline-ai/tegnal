import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/library_backup_actions.dart';
import 'package:tegnal/core/support/document_files.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/fixtures.dart';

/// Saves into a folder and opens a chosen file, as the system picker would.
class _Picker extends DocumentFiles {
  _Picker(this.saved);
  final Directory saved;
  File? toOpen;
  String? savedName;

  @override
  Future<bool> createDocument({required String name, required File source, String mimeType = 'application/json'}) async {
    savedName = name;
    source.copySync('${saved.path}/$name');
    return true;
  }

  @override
  Future<File?> openDocument({List<String> mimeTypes = const []}) async {
    final file = toOpen;
    if (file == null) return null;
    final copy = File('${saved.path}/picked-${DateTime.now().microsecondsSinceEpoch}.json');
    return file.copySync(copy.path);
  }
}

void main() {
  test('a backup is saved under the native name, read back with its counts and merged', () async {
    final directory = temporaryDirectory(addTearDown);
    final preferences = AppPreferences.memory();
    final source = AppDatabase.inMemory(preferences: preferences);
    final images = BooruStore.inMemory(preferences: preferences);
    final folder = source.createFolder(name: 'Saved');
    source.upsertWork(galleryId: 1, folderId: folder.id, title: 'One');
    source.upsertWork(galleryId: 2, title: 'Two');
    final picker = _Picker(directory);
    final actions = LibraryBackupActions(database: source, images: images, files: picker, temporary: directory);
    expect(await actions.export(), isTrue);
    expect(picker.savedName, 'tegnal-backup.json');

    final targetPreferences = AppPreferences.memory();
    final target = AppDatabase.inMemory(preferences: targetPreferences);
    final restoring = LibraryBackupActions(
      database: target,
      images: BooruStore.inMemory(preferences: targetPreferences),
      files: picker..toOpen = File('${directory.path}/tegnal-backup.json'),
      temporary: directory,
    );
    final backup = await restoring.pick();
    expect(backup, isNotNull);
    expect(backup!.comicWorks, 2);
    expect(backup.imageFavorites, 0);
    expect(backup.challengeGames, 0);
    expect(backup.workCount, 2);
    restoring.restore(backup);
    expect(target.getWork(1)?.folders.map((folder) => folder.name), ['Saved']);
    expect(target.getWork(2), isNotNull);
  });

  test('cancelling the picker reads nothing', () async {
    final directory = temporaryDirectory(addTearDown);
    final preferences = AppPreferences.memory();
    final actions = LibraryBackupActions(
      database: AppDatabase.inMemory(preferences: preferences),
      images: BooruStore.inMemory(preferences: preferences),
      files: _Picker(directory),
      temporary: directory,
    );
    expect(await actions.pick(), isNull);
  });
}
