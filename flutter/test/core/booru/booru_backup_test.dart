// Ported from native-ios/TEGNALTests/BooruBackupTests.swift.
// Not ported yet: testRestoredFolderColorsAndOrderReachAnotherSyncLibrary needs
// LibrarySyncAdapter, which arrives with sync (step 5).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/backup_fixtures.dart';

void main() {
  test('historical backup imports and reexports with current format', () {
    final source = BooruStore.inMemory(), server = presetServer();
    source.saveServer(server);
    final folder = source.saveFolder(name: 'Imported collection');
    final post = fixturePost(72, server);
    source.saveFavorite(post, folderID: folder);
    final current = source.exportBackup().encoded();
    final historical = utf8.decode(current).replaceAll('tegnal-image-library', 'number-memo-image-library');
    final decoded = BooruBackup.decode(utf8.encode(historical));
    expect(decoded.format, 'tegnal-image-library');
    final destination = BooruStore.inMemory();
    destination.restoreBackup(decoded);
    expect(destination.isFavorite(post), isTrue);
    expect(destination.folderIDFor(post), folder);
    expect(destination.exportBackup().format, 'tegnal-image-library');
    final invalid = decoded..format = 'unrelated-image-library';
    expect(() => BooruBackup.decode(utf8.encode(jsonEncode(invalid.toJson()))), throwsA(isA<BooruError>()));
  });

  test('automatic colors use comics palette and fallback without changing renames', () {
    final comics = AppDatabase.inMemory(), images = BooruStore.inMemory();
    final initial = comics.listFolders().first.color;
    images.database.write(BooruStore.ensureUnsorted);
    images.setFolderColor('unsorted', initial);
    for (var index = 0; index < AppDatabase.presetColors.length + 3; index++) {
      final comic = comics.createFolder(name: 'Folder $index');
      final id = images.saveFolder(name: 'Folder $index');
      expect(images.folders().firstWhere((folder) => folder.id == id).color, comic.color);
      images.saveFolder(id: id, name: 'Renamed $index');
      expect(images.folders().firstWhere((folder) => folder.id == id).color, comic.color);
    }
  });

  test('backup round trip merges canonical servers and preserves folders and searches', () {
    final source = BooruStore.inMemory(), destination = BooruStore.inMemory();
    final server = presetServer();
    source.saveServer(server);
    final a = source.saveFolder(name: 'Landscapes'), b = source.saveFolder(name: 'Rooms');
    source.setFolderColor(a, 0xFF112233);
    source.database.write(BooruStore.ensureUnsorted);
    source.setFolderColor('unsorted', 0xFF334455);
    source.reorderFolders([b, 'unsorted', a]);
    final post = fixturePost(5194309, server);
    source.saveFavorite(post, folderID: a);
    source.recordSearch('scenery sky', serverID: server.id);
    for (final kind in ['tag', 'artist', 'search']) {
      source.toggleTag('scenery sky', serverID: server.id, kind: kind);
    }
    source.setBlacklist('gore', serverID: server.id);
    final local = BooruServer(id: 'already-configured', name: server.name, baseURL: server.baseURL, engine: server.engine);
    destination.saveServer(local);
    final extra = destination.saveFolder(name: 'Keep me');
    final backup = BooruBackup.decode(source.exportBackup().encoded());
    destination.restoreBackup(backup);
    destination.restoreBackup(backup);
    expect(destination.servers.map((server) => server.id), [local.id]);
    expect(destination.folders().map((folder) => folder.id), [b, 'unsorted', a, extra]);
    expect(destination.folders().firstWhere((folder) => folder.id == a).color, 0xFF112233);
    expect(destination.folders().firstWhere((folder) => folder.id == 'unsorted').color, 0xFF334455);
    final mapped = post.onServer(local.id);
    expect(destination.favoriteIDs, {mapped.id});
    expect(destination.folderIDFor(mapped), a);
    expect(destination.savedDate(mapped), source.savedDate(post));
    expect(destination.history(local.id), ['scenery sky']);
    expect(destination.savedTags(local.id, kind: 'search'), ['scenery sky']);
    expect(destination.blacklist(local.id), 'gore');
    expect(destination.selectedServerIDs, [local.id]);
  });

  test('invalid backup cannot partially change library', () {
    final source = BooruStore.inMemory(), destination = BooruStore.inMemory();
    final server = presetServer();
    source.saveServer(server);
    source.saveFavorite(fixturePost(12, server));
    var backup = source.exportBackup();
    final favorite = backup.favorites[0];
    backup.favorites[0] = BooruBackupFavorite(post: favorite.post, folderID: 'missing', savedAt: favorite.savedAt);
    expect(() => destination.restoreBackup(backup), throwsA(anything));
    expect(destination.servers, isEmpty);
    expect(destination.folders(), isEmpty);
    backup = source.exportBackup()..version = 999;
    expect(() => destination.restoreBackup(backup), throwsA(anything));
    expect(() => BooruBackup.decode(utf8.encode('{"version":2,"works":[]}')), throwsA(anything));
  });

  test('uncategorized is optional and nonempty deletion is atomic', () {
    final images = BooruStore.inMemory(), server = presetServer();
    expect(images.folders(), isEmpty);
    images.exportBackup().validate();
    images.saveServer(server);
    final folder = images.saveFolder(name: 'References');
    final post = fixturePost(72, server);
    images.saveFavorite(post, folderID: folder);
    images.deleteFolder(folder);
    expect(images.folderIDFor(post), 'unsorted');
    expect(() => images.deleteFolder('unsorted'), throwsA(isA<FolderDeletionError>()));
    expect(images.isFavorite(post), isTrue);
    expect(images.folders().map((folder) => folder.id), ['unsorted']);
    images.toggleFavorite(post);
    images.deleteFolder('unsorted');
    expect(images.folders(), isEmpty);
    final restored = BooruStore.inMemory();
    restored.restoreBackup(BooruBackup.decode(images.exportBackup().encoded()));
    expect(restored.folders(), isEmpty);
  });

  test('empty comic default can be deleted and stays deleted after reopen', () {
    final directory = Directory.systemTemp.createTempSync('tegnal-comics-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/memo.sqlite';
    final preferences = AppPreferences.memory();
    final comics = AppDatabase.open(path: path, preferences: preferences);
    final folder = comics.listFolders().first;
    comics.upsertWork(galleryId: 72, folderId: folder.id);
    expect(() => comics.deleteFolder(folder.id!), throwsA(isA<FolderDeletionError>()));
    expect(comics.getWork(72)?.folders.first.id, folder.id);
    comics.dbWriter.write((db) => db.execute('DELETE FROM works WHERE gallery_id = 72'));
    comics.deleteFolder(folder.id!);
    expect(comics.listFolders(), isEmpty);
    comics.dbWriter.close();
    final reopened = AppDatabase.open(path: path, preferences: preferences);
    expect(reopened.listFolders(), isEmpty);
    reopened.upsertWork(galleryId: 73);
    expect(reopened.getWork(73)!.folders, isNotEmpty);
  });
}
