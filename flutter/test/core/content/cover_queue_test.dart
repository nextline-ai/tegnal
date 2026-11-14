// The cover queue from native-ios/TEGNALTests/LibrarySyncTests.swift, with
// CoverQueuePolicy from TasteTests.swift and the backfill case of MangaBackendTests.swift.
//
// - testAutomaticBackfillRunsWhileImageModeIsSelected drives the queue through
//   `AppEnvironment`; here the same run goes through the `CoverQueue` driver, since
//   modes and site verification are wired by the app.
// - testMissingGalleryHTTPResponseIsCountedAsGoneByBackfill reaches the 404 through the
//   real site source; here the fixture source throws the same `unavailable(404)`.
// - Native re-encodes covers as JPEG; the Android library keeps the site's bytes under
//   the same file name, so the decodability check reads the saved file's header.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/cover_queue.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/local_thumbnail_cache.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../../support/fixtures.dart';

enum Failure { none, emptyGallery, invalidImage, emptyTitle, emptyTags, missingGallery, removedGallery, missingImage, forbiddenGallery, serverError, offline }

/// `BackfillFixtureSource`: fixture works that fail in a chosen way, recording each request.
class BackfillFixtureSource extends ContentProviding {
  BackfillFixtureSource([this.failure = Failure.none]);
  Failure failure;
  final _fixture = FixtureContentSource();
  final requests = <int>[];

  @override
  Future<NativeGallery> gallery(int id) async {
    requests.add(id);
    switch (failure) {
      case Failure.missingGallery:
        throw const ContentError.unavailable(404);
      case Failure.removedGallery:
        throw const ContentError.unavailable(410);
      case Failure.forbiddenGallery:
        throw const ContentError.unavailable(403);
      case Failure.serverError:
        throw const ContentError.unavailable(503);
      case Failure.offline:
        throw const NetworkError(NetworkErrorCode.notConnectedToInternet);
      default:
        break;
    }
    final gallery = await _fixture.gallery(id);
    return NativeGallery(
      id: id,
      title: failure == Failure.emptyTitle ? '' : gallery.title,
      artists: gallery.artists,
      language: gallery.language,
      type: gallery.type,
      tags: failure == Failure.emptyTags ? const [] : gallery.tags,
      pages: failure == Failure.emptyGallery ? const [] : gallery.pages,
    );
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) => _fixture.list(query, offset: offset, count: count);

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    if (failure == Failure.missingImage) throw const ContentError.unavailable(404);
    if (failure == Failure.invalidImage) return Uint8List.fromList('not an image'.codeUnits);
    return _fixture.image(page, galleryID: galleryID, thumbnail: thumbnail);
  }
}

CoverQueueActor actor(AppDatabase db, Directory root, ContentProviding source) =>
    CoverQueueActor(database: db, thumbsDir: root, source: source, allowsBackfill: () => true, delay: Duration.zero);

Future<Uint8List> cover() => FixtureContentSource.renderPage('cover', width: 8, height: 8);

void main() {
  test('policy pauses filling in low power mode or under thermal pressure', () {
    expect(CoverQueuePolicy.allowsBackfillFor(lowPowerMode: false, thermalState: DeviceThermalState.nominal), isTrue);
    expect(CoverQueuePolicy.allowsBackfillFor(lowPowerMode: false, thermalState: DeviceThermalState.fair), isTrue);
    expect(CoverQueuePolicy.allowsBackfillFor(lowPowerMode: true, thermalState: DeviceThermalState.nominal), isFalse);
    expect(CoverQueuePolicy.allowsBackfillFor(lowPowerMode: false, thermalState: DeviceThermalState.serious), isFalse);
    expect(CoverQueuePolicy.allowsBackfillFor(lowPowerMode: false, thermalState: DeviceThermalState.critical), isFalse);
  });

  test('missing gallery stops automatic retries until a manual fill', () async {
    for (final failure in [Failure.missingGallery, Failure.removedGallery]) {
      final root = temporaryDirectory(addTearDown);
      final path = '${root.path}/library.sqlite';
      final preferences = AppPreferences.memory();
      final db = AppDatabase.open(path: path, preferences: preferences);
      db.upsertWork(galleryId: 1234);
      db.setThumb(1234, 'failed');
      final source = BackfillFixtureSource(failure);
      final state = CoverQueueState();
      await actor(db, root, source).start(state);
      expect(state.gone, 1);
      expect(state.failed, 0);
      expect(state.remaining, 0);
      expect(db.getWork(1234)?.thumbStatus, 'gone');
      expect(db.worksNeedingFill(), isEmpty, reason: 'Missing titles and tags must not requeue a removed work');

      final reopened = AppDatabase.open(path: path, preferences: preferences);
      final restarted = actor(reopened, root, source);
      await restarted.start(CoverQueueState());
      expect(source.requests, [1234], reason: 'Absence survives reopening the app');

      // The editor's fill action calls fetchOne directly and can recover a restored work.
      source.failure = Failure.none;
      await restarted.fetchOne(1234);
      expect(reopened.getWork(1234)!.hasThumb, isTrue);
      expect(reopened.countNeedingFill(), 0);
    }
  });

  test('image 404 and transient metadata failures remain retryable', () async {
    for (final failure in [Failure.missingImage, Failure.forbiddenGallery, Failure.serverError, Failure.offline]) {
      final db = AppDatabase.inMemory();
      db.upsertWork(galleryId: 1234);
      final root = temporaryDirectory(addTearDown);
      final source = BackfillFixtureSource(failure);
      final queue = actor(db, root, source);
      final state = CoverQueueState();
      await queue.start(state);
      expect(state.gone, 0, reason: '$failure');
      expect(state.failed, 1, reason: '$failure');
      expect(state.remaining, 1, reason: '$failure');
      expect(db.getWork(1234)?.thumbStatus, 'failed');
      await queue.start(state);
      expect(source.requests, [1234, 1234]);
    }
  });

  test('refresh replaces saved information but keeps notes and covers', () async {
    final db = AppDatabase.inMemory();
    final root = temporaryDirectory(addTearDown);
    final data = await cover();
    for (final (id, artist) in [(1001, 'tegnal'), (1002, 'another artist')]) {
      db.upsertWork(galleryId: id, title: '原題', artists: artist, language: 'english', tags: 'tag:old');
      final file = File('${root.path}/native_$id.jpg')..writeAsBytesSync(data);
      db.setThumb(id, 'ready', path: file.path);
    }
    db.setNote(1001, 'kept');
    final source = BackfillFixtureSource();
    final queue = actor(db, root, source);
    final state = CoverQueueState();
    await queue.start(state);
    expect(source.requests, isEmpty, reason: 'Nothing is missing, so filling alone fetches nothing');

    expect(queue.queueRefresh(), 2);
    await queue.start(state);
    expect(state.total, 2);
    expect(state.processed, 2, reason: 'A number is one work on every website, so both are read again');
    expect(state.gone, 0);
    final refreshed = db.getWork(1001)!;
    expect(refreshed.title, '네이티브 읽기 테스트');
    expect(refreshed.tags?.contains('female:sample'), isTrue);
    expect(refreshed.note, 'kept');
    expect(refreshed.thumbPath, '${root.path}/native_1001.jpg');
    expect(db.getWork(1002)!.title, '네이티브 읽기 테스트');

    source.failure = Failure.missingGallery;
    queue.queueRefresh();
    await queue.start(state);
    expect(db.getWork(1001)?.thumbStatus, 'ready', reason: 'A refresh keeps covers of works the site no longer has');
    expect(db.countNeedingFill(), 0);
  });

  test('a refresh that fails stays queued and resumes in a later run', () async {
    final db = AppDatabase.inMemory();
    final root = temporaryDirectory(addTearDown);
    db.upsertWork(galleryId: 1001, title: '原題', artists: 'tegnal', language: 'english', tags: 'tag:old');
    final file = File('${root.path}/native_1001.jpg')..writeAsBytesSync(await cover());
    db.setThumb(1001, 'ready', path: file.path);

    final source = BackfillFixtureSource(Failure.offline);
    final first = actor(db, root, source);
    first.queueRefresh();
    final state = CoverQueueState();
    await first.start(state);
    expect(state.failed, 1);
    expect(state.remaining, 1, reason: 'The work still waits for its refresh');
    expect(db.countAwaitingRefresh(), 1);
    expect(db.getWork(1001)?.title, '原題', reason: 'Nothing is lost while the site cannot be reached');

    // A later launch continues without the refresh being asked for again.
    source.failure = Failure.none;
    final later = actor(db, root, source);
    await later.start(CoverQueueState());
    expect(db.getWork(1001)?.title, '네이티브 읽기 테스트');
    expect(db.countAwaitingRefresh(), 0);
    await later.start(CoverQueueState());
    expect(source.requests, [1001, 1001], reason: 'A finished refresh is not fetched again');
  });

  test('manual fill reports and persists a missing gallery', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final root = temporaryDirectory(addTearDown);
    final queue = CoverQueueActor(database: db, thumbsDir: root, source: BackfillFixtureSource(Failure.missingGallery));
    await expectLater(queue.fetchOne(1234), throwsA(ContentError.galleryNotFound));
    expect(db.getWork(1234)?.thumbStatus, 'gone');
    expect(db.countNeedingFill(), 0);
  });

  test('backfill repairs moved files and downloads missing ready thumbnails', () async {
    final db = AppDatabase.inMemory();
    final root = temporaryDirectory(addTearDown);
    final thumbs = Directory('${root.path}/new-container/thumbs')..createSync(recursive: true);
    for (final id in [1001, 1002, 1003, 1004]) {
      db.upsertWork(galleryId: id, title: 'Preserved title', tags: 'tag:sample', bookmarkedAt: '2026-10-23T00:00:00Z');
    }
    final recovered = File('${thumbs.path}/native_1001.jpg')..writeAsBytesSync(await cover());
    db.setThumb(1001, 'ready', path: '${root.path}/old-container/thumbs/native_1001.jpg');
    db.setThumb(1002, 'ready', path: '${root.path}/missing.jpg');
    db.setThumb(1003, 'ready');
    final corrupt = File('${thumbs.path}/corrupt.jpg')..writeAsStringSync('not an image');
    db.setThumb(1004, 'ready', path: corrupt.path);
    final source = BackfillFixtureSource();
    final state = CoverQueueState();
    await actor(db, thumbs, source).start(state);
    expect((state.processed, state.failed, state.remaining), (3, 0, 0));
    expect(state.error, isNull);
    expect(db.getWork(1001)?.thumbPath, recovered.path);
    expect(source.requests, [1004, 1003, 1002], reason: 'Recovered local files do not require another network request');
    for (final id in [1001, 1002, 1003, 1004]) {
      final work = db.getWork(id)!;
      expect(work.hasThumb, isTrue);
      final displayed = await LocalThumbnailCache.shared.load(work.thumbPath!);
      expect(displayed, isNotNull, reason: 'A completed item must be decodable by the actual saved-card cache');
    }
    expect(db.countNeedingFill(), 0);
  });

  test('backfill never counts an absent or undecodable cover as complete', () async {
    for (final kind in [Failure.emptyGallery, Failure.invalidImage]) {
      final db = AppDatabase.inMemory();
      db.upsertWork(galleryId: 1234);
      final root = temporaryDirectory(addTearDown);
      final state = CoverQueueState();
      await actor(db, root, BackfillFixtureSource(kind)).start(state);
      expect(state.isRunning, isFalse);
      expect(state.processed, 0);
      expect((state.failed, state.remaining), (1, 1));
      expect(db.getWork(1234)?.thumbStatus, 'failed');
      expect(db.getWork(1234)!.hasThumb, isFalse);
      expect(db.countNeedingFill(), 1);
      expect(File('${root.path}/native_1234.jpg').existsSync(), isFalse);
    }
  });

  test('a stored cover does not hide an unfilled title', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final root = temporaryDirectory(addTearDown);
    final state = CoverQueueState();
    await actor(db, root, BackfillFixtureSource(Failure.emptyTitle)).start(state);
    expect((state.processed, state.failed, state.remaining), (0, 1, 1));
    expect(db.getWork(1234)!.hasThumb, isTrue, reason: 'Keep the successfully saved cover while retrying metadata');
  });

  test('a work the site lists without tags is filled once', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    // Saved without the site's answer, empty tags still need filling.
    db.upsertWork(galleryId: 5678, title: 'Saved elsewhere', metadataSource: 'remote');
    expect(db.countNeedingFill(), 2);
    final root = temporaryDirectory(addTearDown);
    final source = BackfillFixtureSource(Failure.emptyTags);
    final state = CoverQueueState();
    await actor(db, root, source).start(state);
    expect((state.processed, state.failed, state.remaining), (2, 0, 0));
    final work = db.getWork(1234)!;
    expect((work.hasThumb, work.hasTitle, work.tags ?? ''), (true, true, ''));

    await actor(db, root, source).start(CoverQueueState());
    expect(source.requests..sort(), [1234, 5678], reason: 'A work the site lists without tags is not asked for again');
  });

  test('the driver fills automatically and runs again when asked mid-run', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final root = temporaryDirectory(addTearDown);
    final source = BackfillFixtureSource();
    final queue = CoverQueue(database: db, source: source, thumbsDir: root, allowsBackfill: () => true, delay: Duration.zero);
    queue.start();
    db.upsertWork(galleryId: 5678);
    queue.start();
    await queue.running;
    expect(queue.state.isRunning, isFalse);
    expect(db.getWork(1234)!.hasThumb, isTrue);
    expect(db.getWork(5678)!.hasThumb, isTrue);
    expect(db.countNeedingFill(), 0);
  });

  test('an inactive app defers filling until it returns', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final root = temporaryDirectory(addTearDown);
    final source = BackfillFixtureSource();
    final queue = CoverQueue(database: db, source: source, thumbsDir: root, allowsBackfill: () => true, delay: Duration.zero);
    queue.setActive(false);
    queue.start();
    expect(queue.running, isNull);
    queue.setActive(true);
    await queue.running;
    expect(db.getWork(1234)!.hasThumb, isTrue);
  });

  test('an unverified site counts what is missing without downloading', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final root = temporaryDirectory(addTearDown);
    final source = BackfillFixtureSource();
    final queue = CoverQueue(database: db, source: source, thumbsDir: root, isSiteVerified: () => false, allowsBackfill: () => true);
    queue.start();
    await queue.running;
    expect(source.requests, isEmpty);
    expect((queue.state.total, queue.state.remaining, queue.state.isRunning), (1, 1, false));
  });

  test('heat notice threshold and dismissal', () {
    final state = CoverQueueState()
      ..isRunning = true
      ..total = 99;
    expect(state.showsHeatBanner, isFalse);
    state.total = 100;
    expect(state.showsHeatBanner, isTrue);
    state.heatWarningDismissed = true;
    expect(state.showsHeatBanner, isFalse);
    expect(state.isRunning, isTrue, reason: 'Dismissing the notice does not stop filling');
    state
      ..heatWarningDismissed = false
      ..isRunning = false;
    expect(state.showsHeatBanner, isFalse);
  });

  test('a disabled queue never fetches', () async {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 1234);
    final source = BackfillFixtureSource();
    final queue = CoverQueue.disabled(database: db, source: source);
    queue
      ..start()
      ..requestRefresh()
      ..toggle();
    expect(queue.running, isNull);
    expect(source.requests, isEmpty);
  });
}
