// Downloads from native-ios/TEGNALTests/DownloadTests.swift.
//
// - Pages are paced one second apart natively; the store takes the pause as a parameter
//   so these tests run without it.
// - The booru half of testFailureCanRetryAndModesDoNotCollide only enqueues, so it runs
//   here; downloading booru media arrives with image mode.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/downloads/download_store.dart';
import 'package:tegnal/core/support/swift_json.dart';

import '../../support/fixtures.dart';

/// `DownloadFixture`: one document whose image requests can fail, counted.
class DownloadFixture extends ContentProviding {
  DownloadFixture(this.document, this.data);
  final NativeGallery document;
  final Uint8List data;
  int calls = 0;
  bool shouldFail = false;
  int? failureCall;

  @override
  Future<NativeGallery> gallery(int id) async => document;
  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    calls += 1;
    if (shouldFail || failureCall == calls) throw const NetworkError(NetworkErrorCode.notConnectedToInternet);
    return data;
  }
}

const _page = GalleryPage(
  hash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  name: '../../unsafe.png',
  width: 4,
  height: 4,
  hasAVIF: false,
);
const _gallery = NativeGallery(id: 42, title: 'Offline test', artists: [], language: '', type: '', tags: [], pages: [_page]);

DownloadStore store(Directory directory, ContentProviding source) =>
    DownloadStore(directory: directory, manga: source, configuredHost: () => 'comics.example', pageDelay: Duration.zero);

Future<void> finish(DownloadStore store, WorkDownloadStatus status) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (store.items.firstOrNull?.status == status) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Download did not reach $status');
}

void main() {
  late Uint8List data;
  setUpAll(() async => data = await FixtureContentSource.renderPage('4', width: 4, height: 4));

  test('a download survives a restart and reads without the network', () async {
    final directory = temporaryDirectory(addTearDown);
    final source = DownloadFixture(_gallery, data);
    final downloads = store(directory, source);
    final id = downloads.enqueue(_gallery);
    expect(downloads.enqueue(_gallery), id);
    await finish(downloads, WorkDownloadStatus.completed);
    expect(downloads.items.length, 1);
    expect(downloads.items[0].files, ['00001.png']);
    expect(downloads.items[0].bytes, data.length);
    final restored = store(directory, source);
    final item = restored.items.first;
    expect(item.status, WorkDownloadStatus.completed);
    source.shouldFail = true;
    final offline = DownloadedContentSource(item: item, folder: restored.folder(item));
    expect(await offline.image(_gallery.pages[0], galleryID: 42, thumbnail: false), data);
    restored.remove(id);
    expect(restored.items, isEmpty);
    expect(restored.folder(item).existsSync(), isFalse);
  });

  test('pausing before the start persists, and resuming downloads', () async {
    final directory = temporaryDirectory(addTearDown);
    final source = DownloadFixture(_gallery, data);
    final downloads = store(directory, source);
    final id = downloads.enqueue(_gallery);
    downloads.pause(id);
    await downloads.worker(WorkDownloadMode.manga);
    final restored = store(directory, source);
    expect(restored.items.first.status, WorkDownloadStatus.paused);
    restored.resume(id);
    await finish(restored, WorkDownloadStatus.completed);
    expect(source.calls, 1);
  });

  test('a failure can be retried, and modes do not collide', () async {
    final directory = temporaryDirectory(addTearDown);
    final source = DownloadFixture(_gallery, data)..shouldFail = true;
    final downloads = store(directory, source);
    final id = downloads.enqueue(_gallery);
    await finish(downloads, WorkDownloadStatus.failed);
    expect(downloads.items.first.error, isNotNull);
    source.shouldFail = false;
    downloads.resume(id);
    await finish(downloads, WorkDownloadStatus.completed);
    downloads.setBackground(true);
    for (final engine in BooruEngine.values) {
      final booru = server(engine.rawValue, engine: engine);
      final image = BooruPost(
        serverID: booru.id,
        postID: 42,
        width: 4,
        height: 4,
        tags: const [],
        artists: const [],
        rating: 's',
        score: 0,
        fileExtension: 'png',
      );
      final first = downloads.enqueuePost(image, booru);
      expect(downloads.enqueuePost(image, booru), first);
    }
    expect(downloads.items.where((item) => item.mode == WorkDownloadMode.manga).length, 1);
    expect(downloads.items.where((item) => item.mode == WorkDownloadMode.booru).length, BooruEngine.values.length);
  });

  test('resuming keeps completed pages and repairs missing files', () async {
    final directory = temporaryDirectory(addTearDown);
    const gallery = NativeGallery(
      id: 42,
      title: 'Offline test',
      artists: [],
      language: '',
      type: '',
      tags: [],
      pages: [
        _page,
        GalleryPage(hash: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', name: 'second.png', width: 4, height: 4, hasAVIF: false),
      ],
    );
    final source = DownloadFixture(gallery, data)..failureCall = 2;
    final downloads = store(directory, source);
    final id = downloads.enqueue(gallery);
    await finish(downloads, WorkDownloadStatus.failed);
    expect(downloads.items[0].files.length, 1);
    downloads.resume(id);
    await finish(downloads, WorkDownloadStatus.completed);
    expect(source.calls, 3, reason: 'The completed first page must not be downloaded again');
    downloads.urls(downloads.items[0])[0].deleteSync();
    final restored = store(directory, source);
    expect(restored.items[0].status, WorkDownloadStatus.paused);
    restored.resume(id);
    await finish(restored, WorkDownloadStatus.completed);
    expect(source.calls, 4);
    expect(restored.items[0].bytes, data.length * 2);
  });

  test('local search uses title, tags, artists and IDs, and normalizes queries', () {
    const gallery = NativeGallery(
      id: 42,
      title: 'Café Moon',
      artists: ['Sample Artist'],
      language: 'korean',
      type: 'manga',
      tags: ['female:blue_hair', 'night_sky'],
      pages: [_page],
    );
    final item = WorkDownload(key: 'comic:42', mode: WorkDownloadMode.manga, title: gallery.title, origin: 'comics.example', gallery: gallery);
    expect(item.matches('CAFE blue hair'), isTrue);
    expect(item.matches('night_sky Sample 42'), isTrue);
    expect(item.matches('korean manga'), isTrue);
    expect(item.matches('  '), isTrue);
    expect(item.matches('Moon missing_tag'), isFalse);
    final restored = WorkDownload.fromJson(decodeJsonObject(encodeSwiftJson(item.toJson())));
    expect(restored.matches('female:blue_hair'), isTrue);
    final images = server('images');
    final image = BooruPost(
      serverID: images.id,
      postID: 123,
      width: 4,
      height: 4,
      tags: const ['blue_hair', 'night_sky'],
      artists: const ['Some Artist'],
      rating: 's',
      score: 0,
      fileExtension: 'png',
    );
    final download = WorkDownload(
      key: 'image:123',
      mode: WorkDownloadMode.booru,
      title: 'Images #123',
      origin: images.canonicalAddress,
      server: images,
      post: image,
    );
    expect(download.matches('123 BLUE_HAIR artist'), isTrue);
    expect(download.matches('42'), isFalse);
  });

  test('HTML is not accepted as a downloaded image', () {
    expect(() => DownloadStore.imageExtension(Uint8List.fromList('<html>Sign in</html>'.codeUnits)), throwsA(ContentError.unsupportedFormat));
  });

  test('the manifest keeps the native keys and the store reopens it', () async {
    final directory = temporaryDirectory(addTearDown);
    final source = DownloadFixture(_gallery, data);
    final downloads = store(directory, source);
    downloads.enqueue(_gallery);
    await finish(downloads, WorkDownloadStatus.completed);
    final manifest = decodeJsonValue(File('${directory.path}/downloads.json').readAsBytesSync()) as List;
    final entry = manifest.single as Map<String, Object?>;
    expect(entry.keys.toSet(), {'id', 'key', 'mode', 'title', 'origin', 'gallery', 'status', 'files', 'bytes', 'location', 'path'});
    expect(entry['id'], matches(RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$')));
    expect((entry['key'], entry['mode'], entry['status']), ('comics.example:42', 'manga', 'completed'));
    expect((entry['location'], entry['path']), ('files', 'Comics/Offline test [42]'));
    expect(Directory('${directory.path}-files/Comics/Offline test [42]/').existsSync(), isTrue);
  });

  test('a gallery saved from another site is not resumed against this one', () async {
    final directory = temporaryDirectory(addTearDown);
    final source = DownloadFixture(_gallery, data);
    var host = 'comics.example';
    final downloads = DownloadStore(directory: directory, manga: source, configuredHost: () => host, pageDelay: Duration.zero);
    final id = downloads.enqueue(_gallery);
    downloads.pause(id);
    await downloads.worker(WorkDownloadMode.manga);
    host = 'another-comics.example';
    downloads.resume(id);
    await finish(downloads, WorkDownloadStatus.failed);
    expect(source.calls, 0);
  });

  test('earlier downloads move to the current location without downloading again', () async {
    final directory = temporaryDirectory(addTearDown);
    // What 1.5.1 left: the record without a location, the files in a folder named by its id.
    final earlier = WorkDownload(
      key: 'comics.example:42',
      mode: WorkDownloadMode.manga,
      title: _gallery.title,
      origin: 'comics.example',
      gallery: _gallery,
      status: WorkDownloadStatus.completed,
      files: ['00001.png'],
      bytes: data.length,
    );
    final old = Directory('${directory.path}/${earlier.id}')..createSync(recursive: true);
    File('${old.path}/00001.png').writeAsBytesSync(data);
    File('${directory.path}/downloads.json').writeAsBytesSync(encodeSwiftJson([earlier.toJson()]));
    final source = DownloadFixture(_gallery, data);
    final downloads = store(directory, source);
    expect(downloads.items.single.status, WorkDownloadStatus.completed);
    expect(downloads.items.single.location, isNull);
    expect([for (final item in downloads.movable) item.id], [earlier.id]);
    await downloads.moveElsewhereHere();
    expect(downloads.locationError, isNull);
    expect(downloads.moving, isNull);
    final moved = downloads.items.single;
    expect(moved.location, DownloadLocation.files);
    expect(downloads.urls(moved).single.readAsBytesSync(), data);
    expect(downloads.urls(moved).single.path, '${directory.path}-files/Comics/Offline test [42]/00001.png');
    expect(old.existsSync(), isFalse);
    expect(downloads.movable, isEmpty);
    expect(source.calls, 0);
    final restored = store(directory, source);
    expect((restored.items.single.status, restored.items.single.location), (WorkDownloadStatus.completed, DownloadLocation.files));
  });

  test('moving copies when the destination is on other storage', () {
    final directory = temporaryDirectory(addTearDown);
    final from = Directory('${directory.path}/from/inner')..createSync(recursive: true);
    File('${from.path}/00001.png').writeAsBytesSync(data);
    // A destination inside a file stands in for storage a rename can't reach: the copy also fails,
    // and the original is kept.
    File('${directory.path}/blocked').writeAsStringSync('');
    expect(() => moveDownloadFolder('${directory.path}/from', '${directory.path}/blocked/to'), throwsA(isA<FileSystemException>()));
    expect(File('${from.path}/00001.png').existsSync(), isTrue);
    moveDownloadFolder('${directory.path}/from', '${directory.path}/to');
    expect(File('${directory.path}/to/inner/00001.png').readAsBytesSync(), data);
    expect(Directory('${directory.path}/from').existsSync(), isFalse);
  });

  test('a chosen folder takes new downloads and keeps earlier ones where they are', () async {
    final directory = temporaryDirectory(addTearDown);
    final chosen = Directory('${directory.path}-chosen')..createSync(recursive: true);
    addTearDown(() => chosen.deleteSync(recursive: true));
    final downloads = store(directory, DownloadFixture(_gallery, data));
    downloads.enqueue(_gallery);
    await finish(downloads, WorkDownloadStatus.completed);
    downloads.addFolder(chosen.path, 'Chosen');
    expect(downloads.locationError, isNull);
    expect((downloads.currentLocation.isFiles, downloads.currentLocation.name), (false, 'Chosen'));
    expect(downloads.movable, hasLength(1), reason: 'the earlier download stays until it is moved');
    const second = NativeGallery(id: 43, title: 'Second: part/two', artists: [], language: '', type: '', tags: [], pages: [_page]);
    downloads.enqueue(second);
    await finish(downloads, WorkDownloadStatus.completed);
    final item = downloads.items.first;
    expect(item.location, downloads.currentLocation.id);
    expect(item.path, 'Comics/Second part two [43]');
    expect(File('${chosen.path}/Comics/Second part two [43]/00001.png').existsSync(), isTrue);
    downloads.setLocation(DownloadLocation.files);
    downloads.removeFolder(item.location!);
    expect(downloads.locations, hasLength(2), reason: 'a folder still holding downloads is kept');
    final reopened = store(directory, DownloadFixture(_gallery, data));
    expect(reopened.locations.map((location) => location.name), ['', 'Chosen']);
    downloads.addFolder('${directory.path}/missing/folder', 'Missing');
    expect(downloads.locationError, isNotNull);
  });

  test('folder names avoid characters file managers refuse', () {
    expect(DownloadStore.fileName('a/b:c\n.d', 60), 'a b c .d');
    expect(DownloadStore.fileName('..hidden', 60), 'hidden');
    expect(DownloadStore.fileName(' / ', 60), 'Download');
    expect(DownloadStore.fileName('가' * 100, 60).runes.length, 60);
  });
}
