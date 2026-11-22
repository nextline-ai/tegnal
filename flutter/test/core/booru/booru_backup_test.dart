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
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/backup_fixtures.dart';

/// The game rows the Swift tests seed with `seedGame`.
void seedGame(
  BooruStore store, {
  required String day,
  required int xp,
  int answered = 0,
  (String, int, int, double)? lesson,
  (String, double, int)? award,
  (String, int)? stat,
}) {
  store.database.write((db) {
    db.execute(
      'INSERT INTO study_days (day, answered, correct, xp) VALUES (?, ?, 0, ?) ON CONFLICT(day) DO UPDATE SET answered = excluded.answered, xp = excluded.xp',
      [day, answered, xp],
    );
    if (lesson != null) {
      db.execute('INSERT INTO study_lessons (lesson, stars, runs, finished) VALUES (?, ?, ?, ?)', [lesson.$1, lesson.$2, lesson.$3, lesson.$4]);
    }
    if (award != null) db.execute('INSERT INTO study_awards (id, earned, seen) VALUES (?, ?, ?)', [award.$1, award.$2, award.$3]);
    if (stat != null) db.execute('INSERT INTO study_stats (name, value) VALUES (?, ?)', [stat.$1, stat.$2]);
  });
}

List<Map<String, Object?>> awardRows(BooruStore store) =>
    store.database.read((db) => [for (final row in db.rows('SELECT * FROM study_awards ORDER BY id')) Map.of(row)]);

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
    // A folder already in the first color, as Uncategorized is in comics.
    images.saveFolder(name: 'First', color: initial);
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
    source.setFolderColor(a, 0xFF6155F5);
    final uncategorized = 'site:${server.canonicalAddress}';
    source.setFolderColor(uncategorized, 0xFF00C8B3);
    source.reorderFolders([b, uncategorized, a]);
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
    expect(destination.folders().map((folder) => folder.id), [b, uncategorized, a, extra]);
    expect(destination.folders().firstWhere((folder) => folder.id == a).color, 0xFF6155F5);
    expect(destination.folders().firstWhere((folder) => folder.id == uncategorized).color, 0xFF00C8B3);
    expect(destination.folder(uncategorized)?.serverID, local.id, reason: "the server's Uncategorized stays its own");
    expect(destination.folder(a)?.serverID, isNull, reason: 'a global folder stays global');
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

  test('each server keeps its uncategorized and a deleted folder empties into it', () {
    final images = BooruStore.inMemory(), server = presetServer();
    expect(images.folders(), isEmpty);
    images.exportBackup().validate();
    images.saveServer(server);
    final uncategorized = 'site:${server.canonicalAddress}';
    expect(images.folders().map((folder) => folder.id), [uncategorized], reason: 'a server has its Uncategorized from the start');
    final folder = images.saveFolder(name: 'References', serverID: server.id);
    final post = fixturePost(72, server);
    images.saveFavorite(post, folderID: folder);
    images.deleteFolder(folder);
    expect(images.folderIDFor(post), uncategorized);
    expect(() => images.deleteFolder(uncategorized), throwsA(isA<FolderDeletionError>()));
    images.toggleFavorite(post);
    expect(() => images.deleteFolder(uncategorized), throwsA(isA<FolderDeletionError>()), reason: 'even empty, it stays while the server does');
    final restored = BooruStore.inMemory();
    restored.restoreBackup(BooruBackup.decode(images.exportBackup().encoded()));
    expect(restored.folders().map((folder) => folder.id), [uncategorized]);
    images.deleteServer(server);
    expect(images.folders(), isEmpty, reason: "a server's folders go with it");
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

  test('backup carries learning mode and older backups still restore', () {
    final source = BooruStore.inMemory(), destination = BooruStore.inMemory();
    seedGame(source, day: '2026-11-01', xp: 40, answered: 3, lesson: ('l1', 3, 2, 500), award: ('first', 100, 0), stat: ('best', 9));
    seedGame(destination, day: '2026-11-01', xp: 70, answered: 1, lesson: ('l1', 1, 5, 900), award: ('first', 300, 1), stat: ('best', 4));
    seedGame(destination, day: '2026-11-03', xp: 8);
    final backup = BooruBackup.decode(source.exportBackup().encoded());
    expect(backup.study?.days.first.xp, 40);
    expect(backup.study?.lessons?.map((lesson) => lesson.lesson), ['l1']);
    expect(backup.study?.awards?.map((award) => award.id), ['first']);
    expect(backup.study?.stats, {'best': 9});
    destination.restoreBackup(backup);
    destination.restoreBackup(backup);
    final days = {for (final day in StudyStore(destination).days()) day.day: day};
    expect(days['2026-11-01']?.xp, 70);
    expect(days['2026-11-03']?.xp, 8);
    final lesson = destination.database.read((db) => db.rows('SELECT * FROM study_lessons').single);
    expect(lesson['stars'], 3);
    expect(lesson['runs'], 5);
    expect(lesson['finished'], 900);
    expect(awardRows(destination).first['earned'], 100);
    expect(destination.database.read((db) => db.value<int>('SELECT value FROM study_stats')), 9);

    // Into an empty library the badge arrives seen.
    final fresh = BooruStore.inMemory();
    fresh.restoreBackup(backup);
    expect(awardRows(fresh).first['seen'], 1);
    expect(StudyStore(fresh).days().first.xp, 40);

    // A backup from before learning mode has neither the new lists nor a day's experience.
    final old = BooruStore.inMemory();
    StudyStore(old).answer('smile', right: true, now: DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000, isUtc: true));
    final json = jsonDecode(utf8.decode(old.exportBackup().encoded())) as Map<String, Object?>;
    final study = json['study'] as Map<String, Object?>;
    for (final key in ['lessons', 'awards', 'stats']) {
      study.remove(key);
    }
    study['days'] = [for (final day in study['days'] as List) Map<String, Object?>.of(day as Map<String, Object?>)..remove('xp')];
    final decoded = BooruBackup.decode(utf8.encode(jsonEncode(json)));
    expect(decoded.study?.lessons, isNull);
    expect(decoded.study?.days.first.xp, 0);
    final target = BooruStore.inMemory();
    target.restoreBackup(decoded);
    expect(StudyStore(target).days().first.answered, 1);
    expect(StudyStore(target).progress()['smile']?.correct, 1);
    expect(awardRows(target), isEmpty);

    // Learning mode alone is enough to make a backup carry something.
    final only = BooruStore.inMemory();
    seedGame(only, day: '2026-11-01', xp: 0, award: ('first', 1, 1));
    expect(only.exportBackup().study, isNotNull);

    // Broken learning rows are refused.
    final broken = jsonDecode(utf8.decode(source.exportBackup().encoded())) as Map<String, Object?>;
    final lessons = (broken['study'] as Map<String, Object?>)['lessons'] as List;
    (broken['study'] as Map<String, Object?>)['lessons'] = [lessons.first, lessons.first];
    expect(() => BooruBackup.decode(utf8.encode(jsonEncode(broken))), throwsA(isA<BooruError>()));
  });
}
