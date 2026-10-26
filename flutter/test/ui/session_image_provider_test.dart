import 'dart:async';

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

  test('image jobs share a two-request concurrency window', () async {
    final gates = <Completer<void>>[];
    var active = 0;
    var peak = 0;
    final loader = SessionImageLoader(
      clientFactory: (_) => MockClient((_) async {
        active++;
        if (active > peak) peak = active;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        active--;
        return http.Response.bytes([1], 200);
      }),
    );
    final first = loader.load(Uri.https('media.example', '/1'));
    final second = loader.load(Uri.https('media.example', '/2'));
    final third = loader.load(Uri.https('media.example', '/3'));
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 2);
    gates.first.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(gates.length, 3);
    gates[1].complete();
    gates[2].complete();
    await Future.wait([second, third]);
    expect(peak, 2);
  });

  test(
    'deadline aborts the transport before releasing its concurrency slot',
    () async {
      var active = 0;
      var peak = 0;
      var stopped = 0;
      final loader = SessionImageLoader(
        requestTimeout: const Duration(milliseconds: 10),
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
        for (var i = 0; i < 3; i++)
          expectLater(
            loader.load(Uri.https('media.example', '/$i')),
            throwsA(isA<http.RequestAbortedException>()),
          ),
      ]);
      expect(peak, 2);
      expect(active, 0);
      expect(stopped, 3);
    },
  );

  test('new visible images run before older waiting images', () async {
    final started = <String>[];
    final gates = <String, Completer<void>>{};
    final loader = SessionImageLoader(
      clientFactory: (_) => MockClient((request) async {
        final path = request.url.path;
        started.add(path);
        final gate = gates[path] = Completer<void>();
        await gate.future;
        return http.Response.bytes([1], 200);
      }),
    );
    final jobs = [
      for (var i = 1; i <= 4; i++)
        loader.load(Uri.https('media.example', '/$i')),
    ];
    await Future<void>.delayed(Duration.zero);
    gates['/1']!.complete();
    await jobs.first;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/1', '/2', '/4']);
    gates['/2']!.complete();
    await jobs[1];
    await Future<void>.delayed(Duration.zero);
    expect(started, ['/1', '/2', '/4', '/3']);
    gates['/3']!.complete();
    gates['/4']!.complete();
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
}
