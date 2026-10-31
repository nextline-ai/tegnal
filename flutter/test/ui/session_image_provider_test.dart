import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/ui/session_image.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/ui/session_image_provider.dart';

class _AbortTrackingClient extends http.BaseClient {
  _AbortTrackingClient(this.onStart, this.onStop);
  final void Function() onStart;
  final void Function() onStop;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onStart();
    final abort = request as http.Abortable;
    await abort.abortTrigger;
    // Model asynchronous native cancellation acknowledgement.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    onStop();
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  testWidgets('missing remote thumbnails never request reader originals', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPageThumbnail(
          page: ReaderPage(url: Uri.https('media.example', '/reader.jpg')),
        ),
      ),
    );
    expect(find.byType(SessionImage), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  test('thumbnail URL roundtrips and old pages remain readable', () {
    final original = Uri.https('media.example', '/reader.jpg');
    final thumbnail = Uri.https('media.example', '/thumb.jpg');
    final page = ReaderPage(url: original, thumbnailUrl: thumbnail);
    expect(ReaderPage.fromJson(page.toJson()).previewUrl, thumbnail);
    expect(ReaderPage.fromJson({'url': original.toString()}).url, original);
    expect(
      ReaderPage.fromJson({'url': original.toString()}).previewUrl,
      isNull,
    );
    expect(
      ReaderPage(url: Uri.file('/tmp/offline.png')).previewUrl,
      Uri.file('/tmp/offline.png'),
    );
  });

  test(
    'redirects use exact media origins and do not forward credentials',
    () async {
      final origins = <Uri>[];
      final requests = <http.Request>[];
      final loader = SessionImageLoader(
        clientFactory: (origin) {
          origins.add(origin);
          return MockClient((request) async {
            requests.add(request);
            if (requests.length == 1) {
              return http.Response(
                '',
                302,
                headers: {'location': 'https://cdn.example/image.jpg'},
              );
            }
            return http.Response.bytes([1, 2, 3], 200);
          });
        },
      );
      final bytes = await loader.load(
        Uri.https('media.example', '/page'),
        headers: {
          'Cookie': 'private=secret',
          'Authorization': 'Bearer secret',
          'Referer': 'https://comics.example/work',
        },
      );
      expect(bytes, [1, 2, 3]);
      expect(origins.map((uri) => uri.host), ['media.example', 'cdn.example']);
      expect(requests.first.headers.containsKey('cookie'), isFalse);
      expect(requests.first.headers['authorization'], 'Bearer secret');
      expect(requests.last.headers.containsKey('authorization'), isFalse);
      expect(requests.last.headers['referer'], 'https://comics.example/work');
      expect(requests.every((request) => !request.followRedirects), isTrue);
    },
  );

  test('rejects insecure redirects before creating another client', () async {
    var clients = 0;
    final loader = SessionImageLoader(
      clientFactory: (_) {
        clients++;
        return MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'http://insecure.example/image.jpg'},
          ),
        );
      },
    );
    await expectLater(
      loader.load(Uri.https('media.example', '/page')),
      throwsException,
    );
    expect(clients, 1);
  });

  test('streamed bodies cannot exceed the encoded-byte budget', () async {
    final loader = SessionImageLoader(
      maximumBytes: 3,
      clientFactory: (_) => MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          200,
        );
      }),
    );
    await expectLater(
      loader.load(Uri.https('media.example', '/page')),
      throwsException,
    );
  });

  test('thumbnails leave a slot for a reader page', () async {
    final gates = <Completer<void>>[];
    var active = 0;
    var peak = 0;
    MockClient client() => MockClient((_) async {
      active++;
      if (active > peak) peak = active;
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      active--;
      return http.Response.bytes([1], 200);
    });
    final thumbnails = SessionImageLoader(
      maximumBytes: thumbnailMaximumBytes,
      clientFactory: (_) => client(),
    );
    final queued = [
      for (var i = 0; i < 7; i++)
        thumbnails.load(Uri.https('media.example', '/$i')),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 5);
    final page = SessionImageLoader(clientFactory: (_) => client())
        .load(Uri.https('media.example', '/page'));
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 6);
    gates.first.complete();
    await queued.first;
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 6);
    for (var finished = 1; finished < 8; finished++) {
      gates[finished].complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
    await Future.wait([...queued, page]);
    expect(peak, 6);
  });

  test(
    'deadline aborts the transport before releasing its concurrency slot',
    () async {
      var active = 0;
      var peak = 0;
      var stopped = 0;
      final loader = SessionImageLoader(
        requestTimeout: const Duration(milliseconds: 10),
        maximumBytes: thumbnailMaximumBytes,
        clientFactory: (_) => _AbortTrackingClient(
          () {
            active++;
            if (active > peak) peak = active;
          },
          () {
            active--;
            stopped++;
          },
        ),
      );
      await Future.wait([
        for (var i = 0; i < 7; i++)
          expectLater(
            loader.load(Uri.https('media.example', '/$i')),
            throwsA(isA<http.RequestAbortedException>()),
          ),
      ]);
      expect(peak, 5);
      expect(active, 0);
      expect(stopped, 7);
    },
  );

  test('new visible images run before older waiting images', () async {
    final started = <String>[];
    final gates = <String, Completer<void>>{};
    final loader = SessionImageLoader(
      maximumBytes: thumbnailMaximumBytes,
      clientFactory: (_) => MockClient((request) async {
        final path = request.url.path;
        started.add(path);
        final gate = gates[path] = Completer<void>();
        await gate.future;
        return http.Response.bytes([1], 200);
      }),
    );
    final jobs = [
      for (var i = 1; i <= 7; i++)
        loader.load(Uri.https('media.example', '/$i')),
    ];
    await Future<void>.delayed(Duration.zero);
    gates['/1']!.complete();
    await jobs.first;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/1', '/2', '/3', '/4', '/5', '/7']);
    gates['/2']!.complete();
    await jobs[1];
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/1', '/2', '/3', '/4', '/5', '/7', '/6']);
    for (final path in ['/3', '/4', '/5', '/6', '/7']) {
      gates[path]!.complete();
    }
    await Future.wait(jobs);
  });

  test(
    'cache key shares equivalent headers and separates different sessions',
    () {
      final url = Uri.https('media.example', '/image');
      final first = SessionNetworkImage(
        url,
        headers: {'Referer': 'a', 'Cookie': 'x'},
      );
      final reordered = SessionNetworkImage(
        url,
        headers: {'Cookie': 'x', 'Referer': 'a'},
      );
      final different = SessionNetworkImage(
        url,
        headers: {'Referer': 'a', 'Cookie': 'y'},
      );
      expect(first, reordered);
      expect(first.hashCode, reordered.hashCode);
      expect(first, isNot(different));
    },
  );
  test('encoded cache coalesces, reuses and separates authorization', () async {
    var calls = 0;
    final gate = Completer<void>();
    final cache = SessionImageByteCache(maximumBytes: 4);
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient((_) async {
        calls++;
        await gate.future;
        return http.Response.bytes([1, 2], 200);
      }),
    );
    final url = Uri.https('cache.example', '/image');
    final a = loader.load(url, headers: {'Authorization': 'a'});
    final b = loader.load(url, headers: {'Authorization': 'a'});
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    gate.complete();
    await Future.wait([a, b]);
    await loader.load(url, headers: {'Authorization': 'a'});
    expect(calls, 1);
    await loader.load(url, headers: {'Authorization': 'b'});
    expect(calls, 2);
    await loader.load(Uri.https('cache.example', '/other'));
    await loader.load(url, headers: {'Authorization': 'a'});
    expect(calls, 4);
  });

  test('cache obeys no-store and clearing during a request', () async {
    var calls = 0;
    final gate = Completer<void>();
    final cache = SessionImageByteCache();
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient((request) async {
        calls++;
        if (request.url.path == '/pending') await gate.future;
        return http.Response.bytes(
          [1],
          200,
          headers: request.url.path == '/private'
              ? {'cache-control': 'no-store'}
              : {},
        );
      }),
    );
    final privateUrl = Uri.https('cache.example', '/private');
    await loader.load(privateUrl);
    await loader.load(privateUrl);
    expect(calls, 2);
    final pending = Uri.https('cache.example', '/pending');
    final first = loader.load(pending);
    await Future<void>.delayed(Duration.zero);
    cache.clear();
    gate.complete();
    await first;
    await loader.load(pending);
    expect(calls, 4);
  });
  test('disk tier reuses evicted memory and enforces its size limit', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    final cache = SessionImageByteCache(
      maximumBytes: 0,
      maximumDiskBytes: 4,
      useDisk: true,
      diskDirectory: dir,
    );
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient((_) async {
        calls++;
        return http.Response.bytes([1, 2], 200);
      }),
    );
    final first = Uri.https('disk.example', '/first');
    await loader.load(first);
    await loader.load(first);
    expect(calls, 1);
    await loader.load(Uri.https('disk.example', '/second'));
    await loader.load(Uri.https('disk.example', '/third'));
    await cache.waitForDiskWrites();
    final files = await Directory('${dir.path}/tegnal-image-cache')
        .list()
        .where((e) => e.path.endsWith('.data'))
        .toList();
    expect(files.length, 2);
    await loader.load(first);
    expect(calls, 4);
    await cache.clear();
    await loader.load(first);
    expect(calls, 5);
    await cache.clear();
  });

  test('anonymous disk entries survive a process restart', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    SessionImageLoader launch() => SessionImageLoader(
      cache: SessionImageByteCache(
        maximumBytes: 0,
        useDisk: true,
        diskDirectory: dir,
      ),
      clientFactory: (_) => MockClient((_) async {
        calls++;
        return http.Response.bytes([1, 2], 200);
      }),
    );
    final url = Uri.https('disk.example', '/image');
    final first = launch();
    await first.load(url);
    await first.load(url, headers: {'Cookie': 'a=b'});
    await first.load(url, headers: {'Authorization': 'c'});
    await first.cache!.waitForDiskWrites();
    expect(calls, 3);

    final second = launch();
    expect(await second.load(url), [1, 2]);
    expect(calls, 3);
    await second.load(url, headers: {'Cookie': 'a=b'});
    await second.load(url, headers: {'Authorization': 'c'});
    expect(calls, 5);
    await second.cache!.waitForDiskWrites();
  });

  test('disk tier honors no-store and isolates auth', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    final cache = SessionImageByteCache(
      maximumBytes: 0,
      useDisk: true,
      diskDirectory: dir,
    );
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient((request) async {
        calls++;
        return http.Response.bytes(
          [1],
          200,
          headers: request.url.path == '/private'
              ? {'cache-control': 'no-store'}
              : {'cache-control': 'max-age=1200', 'age': '1200'},
        );
      }),
    );
    final url = Uri.https('disk.example', '/private');
    await loader.load(url, headers: {'Authorization': 'a'});
    await loader.load(url, headers: {'Authorization': 'a'});
    await loader.load(Uri.https('disk.example', '/expired'));
    await loader.load(Uri.https('disk.example', '/expired'));
    expect(calls, 4);
  });
  test(
    'disk cache separates authorization and clears pending writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
      addTearDown(() => dir.delete(recursive: true));
      final gate = Completer<void>();
      var calls = 0;
      final cache = SessionImageByteCache(
        maximumBytes: 0,
        useDisk: true,
        diskDirectory: dir,
      );
      final loader = SessionImageLoader(
        cache: cache,
        clientFactory: (_) => MockClient((request) async {
          calls++;
          if (request.url.path == '/pending') await gate.future;
          return http.Response.bytes([1], 200);
        }),
      );
      final image = Uri.https('disk.example', '/image');
      await loader.load(image, headers: {'Authorization': 'a'});
      await loader.load(image, headers: {'Authorization': 'b'});
      await loader.load(image, headers: {'Authorization': 'a'});
      expect(calls, 2);
      final pending = Uri.https('disk.example', '/pending');
      final load = loader.load(pending);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await cache.clear();
      gate.complete();
      await load;
      await loader.load(pending);
      expect(calls, 4);
      await cache.clear();
    },
  );
  test('clear prevents queued disk writes repopulating the cache', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
    final cache = SessionImageByteCache(
      maximumBytes: 0,
      useDisk: true,
      diskDirectory: dir,
    );
    addTearDown(() async {
      await cache.clear();
      await dir.delete(recursive: true);
    });
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient(
        (_) async => http.Response.bytes(List.filled(1024 * 1024, 1), 200),
      ),
    );
    await loader.load(Uri.https('disk.example', '/queued'));
    await cache.clear();
    await cache.waitForDiskWrites();
    expect(await Directory('${dir.path}/tegnal-image-cache').exists(), isFalse);
  });
  test('unrelated cache misses do not wait for a pending disk write', () async {
    final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
    final gate = Completer<void>();
    final writing = Completer<void>();
    final cache = SessionImageByteCache(
      maximumBytes: 0,
      useDisk: true,
      diskDirectory: dir,
      beforeDiskWrite: () {
        if (!writing.isCompleted) writing.complete();
        return gate.future;
      },
    );
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await cache.clear();
      await dir.delete(recursive: true);
    });
    final requested = <String>[];
    final loader = SessionImageLoader(
      cache: cache,
      clientFactory: (_) => MockClient((request) async {
        requested.add(request.url.path);
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    final first = Uri.https('disk.example', '/one');
    await loader.load(first);
    await writing.future;
    final again = loader.load(first);
    final unrelated = await loader
        .load(Uri.https('disk.example', '/two'))
        .timeout(const Duration(seconds: 2));
    expect(unrelated, [1, 2, 3]);
    expect(requested, ['/one', '/two']);
    gate.complete();
    expect(await again, [1, 2, 3]);
    expect(requested, ['/one', '/two']);
  });
  test(
    'memory pressure releases encoded bytes without deleting disk cache',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final dir = await Directory.systemTemp.createTemp('tegnal-cache-test');
      final memory = SessionImageByteCache();
      final disk = SessionImageByteCache(useDisk: true, diskDirectory: dir);
      var memoryCalls = 0, diskCalls = 0;
      final memoryLoader = SessionImageLoader(
        cache: memory,
        clientFactory: (_) => MockClient((_) async {
          memoryCalls++;
          return http.Response.bytes([1], 200);
        }),
      );
      final diskLoader = SessionImageLoader(
        cache: disk,
        clientFactory: (_) => MockClient((_) async {
          diskCalls++;
          return http.Response.bytes([1], 200);
        }),
      );
      final url = Uri.https('pressure.example', '/image');
      WidgetsBinding.instance.addObserver(memory);
      WidgetsBinding.instance.addObserver(disk);
      addTearDown(() async {
        WidgetsBinding.instance.removeObserver(memory);
        WidgetsBinding.instance.removeObserver(disk);
        await disk.clear();
        await dir.delete(recursive: true);
      });
      await memoryLoader.load(url);
      await diskLoader.load(url);
      await disk.waitForDiskWrites();
      WidgetsBinding.instance.handleMemoryPressure();
      await memoryLoader.load(url);
      await diskLoader.load(url);
      expect(memoryCalls, 2);
      expect(diskCalls, 1);
    },
  );
}
