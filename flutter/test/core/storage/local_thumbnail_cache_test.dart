// Saved-cover decoding from native-ios/TEGNALTests/GridLayoutTests.swift.
//
// - testVisibleThumbnailReloadsWhenTheSameFileIsReplaced checks a hosted SwiftUI view;
//   here the invalidation stream it listens to is checked, with the reload it causes.
// - The cancellation tests suspend an OperationQueue; here the cache is suspended.
// - testObservedLibrarySnapshotsIncludeThumbnailAndFolderEdits observes GRDB; here the
//   database's change stream tells the same three queries to run again.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/local_thumbnail_cache.dart';

import '../../support/fixtures.dart';

Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = const ui.Color(0xFF0000FF));
  final image = await recorder.endRecording().toImage(width, height);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<File> fixture(Directory root, {int width = 40, int height = 80}) async =>
    File('${root.path}/${DateTime.now().microsecondsSinceEpoch}.png')..writeAsBytesSync(await png(width, height));

void main() {
  test('covers decode once off the build path and respect the pixel limit', () async {
    final root = temporaryDirectory(addTearDown);
    final file = await fixture(root, width: 1200, height: 2400);
    final cache = LocalThumbnailCache(maximumPixelSize: 160);
    // Building a cell must not read and decode even a valid file.
    expect(cache.image(file.path), isNull);
    final images = await Future.wait([for (var index = 0; index < 20; index++) cache.load(file.path)]);
    final image = images.first!;
    expect(images.whereType<ui.Image>().length, 20);
    expect(images.every((other) => identical(other, image)), isTrue, reason: 'Concurrent cells share one decoded image');
    expect((image.width, image.height), (80, 160));
    expect(identical(cache.image(file.path), image), isTrue);

    cache.invalidate(file.path);
    expect(cache.image(file.path), isNull);
    final refreshed = await cache.load(file.path);
    expect(refreshed, isNotNull);
    expect(identical(refreshed, image), isFalse);
    cache.clear();
    expect(cache.image(file.path), isNull);
  });

  test('a replaced file is announced and reloads', () async {
    final root = temporaryDirectory(addTearDown);
    final file = await fixture(root, width: 80, height: 160);
    final cache = LocalThumbnailCache();
    expect((await cache.load(file.path))!.width, 80);
    final announced = cache.invalidations.first;
    file.writeAsBytesSync(await png(160, 80));
    cache.invalidate(file.path);
    expect(await announced, file.path);
    expect((await cache.load(file.path))!.width, 160);
  });

  test('failures do not poison later loads', () async {
    final root = temporaryDirectory(addTearDown);
    final path = '${root.path}/missing.png';
    final cache = LocalThumbnailCache();
    expect(await cache.load(path), isNull);
    File(path).writeAsStringSync('not an image');
    expect(await cache.load(path), isNull);
    File(path).writeAsBytesSync(await png(4, 8));
    expect(await cache.load(path), isNotNull);
  });

  test('cancelling the last consumer skips its queued decode and stays retryable', () async {
    final root = temporaryDirectory(addTearDown);
    final file = await fixture(root);
    final cache = LocalThumbnailCache()..suspended = true;
    final request = cache.request(file.path);
    expect(cache.pendingConsumerCount(file.path), 1);
    request.cancel();
    expect(await request.image, isNull);
    expect(cache.pendingConsumerCount(file.path), 0);
    cache.suspended = false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cache.image(file.path), isNull, reason: 'Offscreen queued files must not be decoded');
    expect(await cache.load(file.path), isNotNull, reason: 'A cancelled request must not poison the same path');
  });

  test('cancelling one consumer keeps the shared decode alive', () async {
    final root = temporaryDirectory(addTearDown);
    final file = await fixture(root);
    final cache = LocalThumbnailCache()..suspended = true;
    final first = cache.request(file.path);
    final visible = cache.request(file.path);
    expect(cache.pendingConsumerCount(file.path), 2);
    first.cancel();
    expect(await first.image, isNull);
    expect(cache.pendingConsumerCount(file.path), 1);
    cache.suspended = false;
    final image = await visible.image;
    expect(image, isNotNull);
    expect(identical(image, cache.image(file.path)), isTrue);
  });

  test('library changes are announced after thumbnail, folder and work edits', () async {
    final database = AppDatabase.inMemory();
    final folder = database.createFolder(name: 'Snapshot test');
    final folderID = folder.id!;
    database.upsertWork(galleryId: 42, folderId: folderID, title: 'Original');
    final snapshots = <(List<dynamic>, List<dynamic>, Map<int, List<dynamic>>)>[];
    final subscription = database.changes.listen((_) {
      snapshots.add(
        database.dbWriter.read((db) => (AppDatabase.fetchWorks(db, folderId: folderID), AppDatabase.fetchFolders(db), AppDatabase.fetchFolderPreviews(db))),
      );
    });
    addTearDown(subscription.cancel);
    final revision = database.revision;

    database.setThumb(42, 'gone');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.$1.first.thumbStatus, 'gone');
    expect(snapshots.last.$3[folderID]?.first.thumbStatus, 'gone');

    database.setFolderColor(folderID, 0xFF123456);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.$1.first.folders.first.color, 0xFF123456);
    expect(snapshots.last.$2.firstWhere((other) => other.id == folderID).color, 0xFF123456);

    database.deleteWork(42);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.$1, isEmpty);
    expect(snapshots.last.$2.firstWhere((other) => other.id == folderID).workCount, 0);
    expect(snapshots.last.$3[folderID], isNull);
    expect(database.revision, revision + 3);
  });
}
