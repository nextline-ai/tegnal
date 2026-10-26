import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/download_manager.dart';
import 'package:tegnal/data/library_store.dart';

Future<void> finished(DownloadManager manager) async {
  final until = DateTime.now().add(const Duration(seconds: 3));
  while (manager.entries.any(
    (e) =>
        e.status == DownloadStatus.queued ||
        e.status == DownloadStatus.downloading,
  )) {
    if (DateTime.now().isAfter(until)) {
      throw StateError('Download queue did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const item = ContentItem(
    sourceId: 'source',
    id: 7,
    mode: AppMode.manga,
    title: 'Offline',
  );
  test('failed page resumes without refetching completed files, and survives relaunch', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-download-');
    final store = LibraryStore.memory();
    var fail = true;
    final requested = <String>[];
    DownloadManager make() => DownloadManager(
      store,
      dir,
      clientFactory: () => MockClient((request) async {
        requested.add(request.url.path);
        return request.url.path == '/2' && fail
            ? http.Response('error', 503)
            : http.Response.bytes(
                [1, 2, 3],
                200,
                headers: {'content-type': 'image/png'},
              );
      }),
    );
    var manager = make();
    try {
      await manager.enqueue(item, [
        ReaderPage(url: Uri.parse('https://example.test/1')),
        ReaderPage(url: Uri.parse('https://example.test/2')),
      ]);
      await finished(manager);
      expect(manager.entry(item)!.status, DownloadStatus.failed);
      expect(manager.entry(item)!.completed, 1);
      expect(await manager.offlinePages(item), isNull);
      manager.dispose();
      manager = make();
      fail = false;
      manager.resume(item);
      await finished(manager);
      expect(requested, ['/1', '/2', '/2']);
      expect(manager.entry(item)!.status, DownloadStatus.complete);
      manager.dispose();
      manager = make();
      final pages = await manager.offlinePages(item);
      expect(pages, hasLength(2));
      expect(await File.fromUri(pages!.first.url).readAsBytes(), [1, 2, 3]);
      await manager.remove(item);
      expect(manager.entries, isEmpty);
      expect(store.downloads(), isEmpty);
    } finally {
      manager.dispose();
      store.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'HTML challenge response never becomes a completed offline image',
    () async {
      final dir = await Directory.systemTemp.createTemp('tegnal-download-');
      final store = LibraryStore.memory();
      final manager = DownloadManager(
        store,
        dir,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '<html>verify</html>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      try {
        await manager.enqueue(item, [
          ReaderPage(url: Uri.parse('https://example.test/image')),
        ]);
        await finished(manager);
        expect(manager.entry(item)!.status, DownloadStatus.failed);
        expect(await manager.offlinePages(item), isNull);
      } finally {
        manager.dispose();
        store.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
