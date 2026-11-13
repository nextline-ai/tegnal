// Ported from native-ios/TEGNALTests/LibraryBackupTests.swift (the backup tests).
// Not ported yet:
// - The five SavedCollectionsModel tests arrive with the saved-works screens (step 4).
// - testClassificationAndDuplicateReviewPreserveDifferentLanguagesFoldersAndNotes needs
//   the duplicate review model (step 4).
// - testRestoredLibrariesPropagateTogetherThroughICloudRows needs sync (step 5).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/challenge/challenge_store.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/content/recent_works.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/library_backup.dart';

import '../../support/backup_fixtures.dart';

void main() {
  late Directory temporary;
  setUp(() => temporary = Directory.systemTemp.createTempSync('tegnal-backup-'));
  tearDown(() => temporary.deleteSync(recursive: true));

  test('single document restores both modes and challenges and is idempotent', () {
    final (source, sourceImages, game) = populated();
    final file = LibraryBackup.export(source, sourceImages, temporary: temporary);
    expect(file.uri.pathSegments.last, 'tegnal-backup.json');
    expect(file.readAsStringSync().contains('/private/local-cache.jpg'), isFalse);
    final backup = LibraryBackupImport.read(file);
    final destination = AppDatabase.inMemory(), images = BooruStore.inMemory();
    destination.createFolder(name: 'Reading', color: 0xFF000000);
    destination.upsertWork(galleryId: 9999, title: 'Keep local');
    backup.restore(destination, images);
    backup.restore(destination, images);
    images.refresh();
    final work = destination.getWork(1234)!;
    expect(work.note, 'Keep this note');
    expect(work.thumbPage, 3);
    expect(work.folders.map((folder) => folder.name), ['Reading']);
    expect(work.folders.first.color, 0xFF123456);
    expect(work.folders.first.sourceGroupId, 42);
    expect(destination.getWork(9999), isNotNull);
    expect(destination.listFolders().where((folder) => folder.name == 'Reading').length, 1);
    expect(destination.searchHistory(), ['saved query']);
    expect(destination.savedSearches(), ['favorite query']);
    expect(destination.dbWriter.value<String>("SELECT note FROM artists WHERE name = 'Artist'"), 'Artist note');
    expect(images.favoriteIDs.length, 1);
    expect(images.folders().first.color, 0xFFABCDEF);
    expect(images.blacklist(images.servers[0].id), 'gore');
    expect(ChallengeStore(images).definitions().map(gameJson), [gameJson(game)]);
  });

  test('older separate backups restore only their own mode', () {
    final (_, sourceImages, _) = populated();
    // The actual pre-unification shape has no format, history or saved-search fields.
    const oldComics = '''
      {"version":2,"exported_at":"2026-01-01T00:00:00Z",
       "folders":[{"id":5,"name":"Reading","color":4279383126,"sort_order":0,"legacy_group_id":42}],
       "works":[{"gallery_id":1234,"title":"Comic","artists":"Artist","note":"Old note","bookmarked_at":"2026-01-01T00:00:00Z","folders":["Reading"],"thumb_page":3}],
       "artists":[{"name":"Artist","kind":0,"note":"Artist note"}]}
      ''';
    final destination = AppDatabase.inMemory(), images = BooruStore.inMemory();
    LibraryBackupImport.decode(utf8.encode(oldComics)).restore(destination, images);
    expect(destination.getWork(1234)?.note, 'Old note');
    expect(destination.getWork(1234)?.folders.first.sourceGroupId, 42);
    expect(images.servers, isEmpty);
    final oldImages = utf8.decode(sourceImages.exportBackup().encoded()).replaceAll('tegnal-image-library', 'number-memo-image-library');
    final legacyImages = LibraryBackupImport.decode(utf8.encode(oldImages));
    legacyImages.restore(destination, images);
    images.refresh();
    expect(destination.getWork(1234), isNotNull);
    expect(images.favoriteIDs.length, 1);
  });

  test('unified export removes embedded media and uses independent files', () {
    final (source, sourceImages, _) = populated();
    final post = fixturePost(73, sourceImages.servers[0])
      ..previewURL = 'data:image/png;base64,dGVzdA=='
      ..sampleURL = 'file:///private/image-cache.jpg';
    sourceImages.saveFavorite(post);
    final first = LibraryBackup.export(source, sourceImages, temporary: temporary);
    final second = LibraryBackup.export(source, sourceImages, temporary: temporary);
    expect(first.path, isNot(second.path));
    expect(first.uri.pathSegments.last, second.uri.pathSegments.last);
    final data = first.readAsBytesSync();
    final json = utf8.decode(data);
    expect(json.contains('data:image'), isFalse);
    expect(json.contains('image-cache.jpg'), isFalse);
    final restored = LibraryBackupImport.decode(data).images!.favorites.firstWhere((favorite) => favorite.post.postID == 73);
    expect(restored.post.previewURL, isNull);
    expect(restored.post.sampleURL, isNull);
    expect(restored.post.fileURL, post.fileURL);
  });

  test('invalid image section cannot modify the comics library', () {
    final (source, sourceImages, _) = populated();
    final value = LibraryBackup.capture(source, sourceImages);
    final favorite = value.images.favorites[0];
    value.images.favorites[0] = BooruBackupFavorite(post: favorite.post, folderID: 'missing', savedAt: favorite.savedAt);
    expect(() => LibraryBackupImport.decode(utf8.encode(jsonEncode(value.toJson()))), throwsA(anything));
    final destination = AppDatabase.inMemory(), images = BooruStore.inMemory();
    expect(() => LibraryBackupImport(comics: value.comics, images: value.images).restore(destination, images), throwsA(anything));
    expect(destination.listWorks(), isEmpty);
    expect(images.servers, isEmpty);
  });

  test('database write failure rolls back both libraries', () {
    final (source, sourceImages, _) = populated();
    final backup = LibraryBackupImport.decode(LibraryBackup.capture(source, sourceImages).encoded());
    final destination = AppDatabase.inMemory(), images = BooruStore.inMemory();
    images.database.write((db) => db.execute("CREATE TRIGGER refuse_favorite BEFORE INSERT ON favorites BEGIN SELECT RAISE(ABORT, 'restore test'); END"));
    expect(() => backup.restore(destination, images), throwsA(anything));
    expect(destination.listWorks(), isEmpty);
    expect(destination.listFolders().any((folder) => folder.name == 'Reading'), isFalse);
    expect(images.database.value<int>('SELECT COUNT(*) FROM servers'), 0);
  });

  test('recent works and images travel in the backup and older backups still read', () {
    final (source, sourceImages, _) = populated();
    final server = presetServer();
    final work = RecentWork(
      item: const ReadingQueueItem(id: 77, title: 'Recent', artists: 'Artist', details: 'korean · manga', site: 'comics'),
      openedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      language: 'korean',
      type: 'manga',
      tags: const ['tag:test'],
    );
    final image = RecentImage(post: fixturePost(73, server), openedAt: DateTime.fromMillisecondsSinceEpoch(1700000100000));
    final stranger = RecentImage(
      post: fixturePost(74, BooruServer(id: 'gone', name: 'Gone', baseURL: 'https://gone.example', engine: BooruEngine.danbooru)),
      openedAt: DateTime.fromMillisecondsSinceEpoch(1700000200000),
    );
    final data = LibraryBackup.capture(source, sourceImages, recentWorks: [work], recentImages: [image, stranger]).encoded();
    final object = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
    final comics = object['comics']! as Map<String, Object?>, images = object['images']! as Map<String, Object?>;
    // Seconds since 1970 in both apps, so either app restores the other's file.
    expect(((comics['recent_works']! as List).first as Map)['opened_at'], 1700000000);
    expect(
      [for (final recent in images['recentImages']! as List) (recent as Map)['openedAt']],
      [1700000100],
      reason: 'Images from a server outside the backup are left out',
    );

    final backup = LibraryBackupImport.decode(data);
    final restoredWork = backup.comics!.recentWorks!.single.work;
    expect(jsonEncode(restoredWork.toJson()), jsonEncode(work.toJson()));
    final destination = BooruStore.inMemory();
    destination.saveServer(BooruServer(id: 'restored-server', name: server.name, baseURL: server.baseURL, engine: server.engine));
    final restored = backup.images!.recentImagesOn(destination.servers);
    expect(restored.map((entry) => entry.post.serverID), ['restored-server']);
    expect(restored.single.openedAt, image.openedAt);

    final older = jsonDecode(utf8.decode(data)) as Map<String, Object?>;
    (older['comics']! as Map<String, Object?>).remove('recent_works');
    (older['images']! as Map<String, Object?>).remove('recentImages');
    final previous = LibraryBackupImport.decode(utf8.encode(jsonEncode(older)));
    expect(previous.comics!.recentWorks, isNull);
    expect(previous.images!.recentImagesOn(destination.servers), isEmpty);
  });

  test('rejects unsupported versions duplicate works and unknown folders', () {
    final (source, sourceImages, _) = populated();
    List<int> encoded(void Function(LibraryBackup value) change) {
      final value = LibraryBackup.capture(source, sourceImages);
      change(value);
      return utf8.encode(jsonEncode(value.toJson()));
    }

    expect(() => LibraryBackupImport.decode(encoded((value) => value.version = 999)), throwsA(anything));
    expect(() => LibraryBackupImport.decode(encoded((value) => value.comics.works.add(value.comics.works[0]))), throwsA(anything));
    expect(
      () => LibraryBackupImport.decode(
        encoded((value) {
          final work = value.comics.works[0].toJson()..['folders'] = ['missing'];
          value.comics.works[0] = MangaWorkRecord.fromJson(work);
        }),
      ),
      throwsA(anything),
    );
    expect(() => LibraryBackupImport.decode(utf8.encode('{}')), throwsA(anything));
  });
}
