import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';

const _item = ContentItem(
  sourceId: 'source',
  id: 42,
  mode: AppMode.manga,
  title: 'Fixture',
);
ReaderPage _page(String path, {Map<String, String> headers = const {}}) =>
    ReaderPage(url: Uri.parse('https://source.invalid$path'), headers: headers);
http.Response _media(int byte) => http.Response.bytes(
  [byte, byte + 1, byte + 2],
  200,
  headers: {'content-type': 'image/png'},
);
Future<void> _settled(DownloadManager manager) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (manager.entries.any(
    (e) =>
        e.status == DownloadStatus.downloading ||
        e.status == DownloadStatus.queued,
  )) {
    if (DateTime.now().isAfter(until)) throw StateError('Queue did not settle');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LibraryStore store;
  DownloadManager? manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tegnal-lifecycle-test-');
    store = LibraryStore.memory();
  });
  tearDown(() async {
    manager?.dispose();
    manager = null;
    await Future<void>.delayed(Duration.zero);
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'background enqueue stays paused until an explicit foreground resume',
    () async {
      var requests = 0;
      manager = DownloadManager(
        store,
        directory,
        clientFactory: () => MockClient((_) async {
          requests++;
          return _media(1);
        }),
      );
      manager!.setForeground(false);
      await manager!.enqueue(_item, [_page('/a')]);
      expect(manager!.entry(_item)!.status, DownloadStatus.paused);
      expect(requests, 0);
      manager!.resume(_item);
      expect(requests, 0);
      manager!.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
      expect(manager!.entry(_item)!.status, DownloadStatus.paused);
      manager!.resume(_item);
      await _settled(manager!);
      expect(requests, 1);
      expect(manager!.entry(_item)!.status, DownloadStatus.complete);
    },
  );

  test(
    'pause and background cancel resume intent while an active request unwinds',
    () async {
      final started = Completer<void>(), first = Completer<http.Response>();
      var requests = 0;
      manager = DownloadManager(
        store,
        directory,
        clientFactory: () => MockClient((_) async {
          requests++;
          if (requests == 1) {
            started.complete();
            return first.future;
          }
          return _media(4);
        }),
      );
      await manager!.enqueue(_item, [_page('/a')]);
      await started.future;
      manager!.pause(_item);
      manager!.resume(_item);
      expect(manager!.entry(_item)!.status, DownloadStatus.queued);
      manager!.setForeground(false);
      manager!.setForeground(true);
      first.complete(_media(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 1);
      expect(manager!.entry(_item)!.status, DownloadStatus.paused);
      manager!.resume(_item);
      await _settled(manager!);
      expect(requests, 2);
      expect(manager!.entry(_item)!.status, DownloadStatus.complete);
    },
  );

  test('explicit resume refreshes expired addresses and reuses verified unchanged pages', () async {
    final requests = <String>[];
    var refreshes = 0;
    manager = DownloadManager(
      store,
      directory,
      refreshPages: (_) async {
        refreshes++;
        return [_page('/a'), _page('/fresh-b')];
      },
      clientFactory: () => MockClient((request) async {
        requests.add(request.url.path);
        return request.url.path == '/expired-b'
            ? http.Response('expired', 403)
            : _media(request.url.path == '/a' ? 1 : 8);
      }),
    );
    await manager!.enqueue(_item, [_page('/a'), _page('/expired-b')]);
    await _settled(manager!);
    expect(manager!.entry(_item)!.status, DownloadStatus.failed);
    expect(manager!.entry(_item)!.completed, 1);
    manager!.resume(_item);
    await _settled(manager!);
    expect(refreshes, 1);
    expect(requests, ['/a', '/expired-b', '/fresh-b']);
    final pages = await manager!.offlinePages(_item);
    expect(await File.fromUri(pages!.first.url).readAsBytes(), [1, 2, 3]);
    expect(await File.fromUri(pages.last.url).readAsBytes(), [8, 9, 10]);
  });

  test(
    'refreshed reordered manifest cannot reuse a file at the wrong page index',
    () async {
      final requests = <String>[];
      manager = DownloadManager(
        store,
        directory,
        refreshPages: (_) async => [_page('/b'), _page('/a')],
        clientFactory: () => MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/expired-b') {
            return http.Response('expired', 403);
          }
          return _media(request.url.path == '/a' ? 1 : 8);
        }),
      );
      await manager!.enqueue(_item, [_page('/a'), _page('/expired-b')]);
      await _settled(manager!);
      manager!.resume(_item);
      await _settled(manager!);
      expect(requests, ['/a', '/expired-b', '/b', '/a']);
      final pages = await manager!.offlinePages(_item);
      expect(await File.fromUri(pages!.first.url).readAsBytes(), [8, 9, 10]);
      expect(await File.fromUri(pages.last.url).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'resume verifies bytes and digest before retaining a committed page',
    () async {
      var fail = true;
      final requests = <String>[];
      manager = DownloadManager(
        store,
        directory,
        refreshPages: (_) async => [_page('/a'), _page('/b')],
        clientFactory: () => MockClient((request) async {
          requests.add(request.url.path);
          return request.url.path == '/b' && fail
              ? http.Response('failed', 503)
              : _media(1);
        }),
      );
      await manager!.enqueue(_item, [_page('/a'), _page('/b')]);
      await _settled(manager!);
      final folder = sha256.convert(utf8.encode(_item.key));
      await File('${directory.path}/$folder/0.media').writeAsBytes([9, 9, 9]);
      fail = false;
      manager!.resume(_item);
      await _settled(manager!);
      expect(requests, ['/a', '/b', '/a', '/b']);
      final pages = await manager!.offlinePages(_item);
      expect(await File.fromUri(pages!.first.url).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'late manifest response after backgrounding cannot mutate or restart work',
    () async {
      final refreshing = Completer<void>(),
          manifest = Completer<List<ReaderPage>>();
      var requests = 0;
      manager = DownloadManager(
        store,
        directory,
        refreshPages: (_) {
          refreshing.complete();
          return manifest.future;
        },
        clientFactory: () => MockClient((_) async {
          requests++;
          return http.Response('expired', 403);
        }),
      );
      await manager!.enqueue(_item, [_page('/expired')]);
      await _settled(manager!);
      manager!.resume(_item);
      await refreshing.future;
      manager!.setForeground(false);
      manager!.setForeground(true);
      manifest.complete([_page('/fresh')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(requests, 1);
      expect(manager!.entry(_item)!.status, DownloadStatus.paused);
      expect(manager!.entry(_item)!.pages.single.url.path, '/expired');
    },
  );

  test('cookies remain ephemeral and different source cannot claim a completed download', () async {
    manager = DownloadManager(
      store,
      directory,
      clientFactory: () => MockClient((_) async => _media(1)),
    );
    await manager!.enqueue(_item, [
      _page(
        '/a',
        headers: {
          'Cookie': 'session=private',
          'Authorization': 'Bearer secret',
          'Referer': 'https://source.invalid/g/42',
        },
      ),
    ]);
    await _settled(manager!);
    final headers =
        (store.downloads().single['pages'] as List).single['headers'];
    expect(headers, {'Referer': 'https://source.invalid/g/42'});
    const other = ContentItem(
      sourceId: 'other',
      id: 42,
      mode: AppMode.manga,
      title: 'Other source',
    );
    expect(await manager!.offlinePages(other), isNull);
    await expectLater(
      manager!.enqueue(other, [_page('/other')]),
      throwsA(isA<ContentException>()),
    );
    expect(manager!.entry(_item)!.status, DownloadStatus.complete);
  });
}
