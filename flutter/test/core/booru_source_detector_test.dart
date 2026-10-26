import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_source_detector.dart';

void main() {
  group('BooruSourceDetector', () {
    test(
      'matches native known-host suggestions without a network request',
      () async {
        final detector = BooruSourceDetector(
          clientFactory: (_) =>
              throw StateError('Known hosts must not be fetched.'),
        );
        expect(
          BooruSourceDetector.suggestFromHost(Uri.https('danbooru.donmai.us')),
          SourceKind.danbooru,
        );
        expect(
          BooruSourceDetector.suggestFromHost(Uri.https('www.gelbooru.com')),
          SourceKind.gelbooru,
        );
        expect(
          BooruSourceDetector.suggestFromHost(Uri.https('test.booru.org')),
          SourceKind.oldGelbooru,
        );
        expect(
          BooruSourceDetector.suggestFromHost(Uri.https('konachan.net')),
          SourceKind.moebooru,
        );
        expect(
          BooruSourceDetector.suggestFromHost(Uri.https('notgelbooru.example')),
          isNull,
        );
        expect(
          await detector.detect(Uri.https('danbooru.donmai.us')),
          SourceKind.danbooru,
        );
      },
    );

    test('recognizes native HTML signatures with old Gelbooru precedence', () {
      expect(
        BooruSourceDetector.recognizeHtml('Danbooru.Post.initialize();'),
        SourceKind.danbooru,
      );
      expect(
        BooruSourceDetector.recognizeHtml('Gelbooru Beta 0.1.11'),
        SourceKind.oldGelbooru,
      );
      expect(
        BooruSourceDetector.recognizeHtml('Moebooru'),
        SourceKind.moebooru,
      );
      expect(
        BooruSourceDetector.recognizeHtml('Gelbooru'),
        SourceKind.gelbooru,
      );
      expect(
        BooruSourceDetector.recognizeHtml("<title>Danbooru pictures</title>"),
        isNull,
      );
      expect(
        BooruSourceDetector.recognizeHtml('<html>Unknown site</html>'),
        isNull,
      );
    });

    test(
      'comics signatures take precedence only for onboarding auto-detection',
      () {
        const indexed =
            '<script src="https://ltn.storage.example/common.js"></script>';
        const document = '<script src="/js/index.search.tail.js"></script>';
        expect(
          BooruSourceDetector.recognizeHtml(indexed),
          isNull,
          reason: 'Mode-specific Booru forms only identify a Booru engine.',
        );
        expect(
          BooruSourceDetector.recognizeHtml(indexed, allowComics: true),
          SourceKind.manga,
        );
        expect(
          BooruSourceDetector.recognizeHtml(document, allowComics: true),
          SourceKind.manga,
        );
        expect(
          BooruSourceDetector.recognizeHtml(
            'const gallery = {"id":1234,"files":[]};',
            allowComics: true,
          ),
          SourceKind.manga,
        );
        expect(
          BooruSourceDetector.recognizeHtml(
            'Danbooru.Post.initialize(); <script src="/js/index.search.tail.js"></script>',
            allowComics: true,
          ),
          SourceKind.manga,
          reason: 'Native mode recognition checks comics before Booru markers.',
        );
      },
    );

    test(
      'follows bounded HTTPS redirects and inspects only homepage HTML',
      () async {
        final requests = <http.BaseRequest>[];
        final detector = BooruSourceDetector(
          clientFactory: (_) => MockClient((request) async {
            requests.add(request);
            if (requests.length == 1) {
              return http.Response('', 302, headers: {'location': '/home'});
            }
            return http.Response('<title>Moebooru</title>', 200);
          }),
        );

        expect(
          await detector.detect(Uri.https('custom.example')),
          SourceKind.moebooru,
        );
        expect(requests, hasLength(2));
        expect(requests.first.followRedirects, isFalse);
        expect(requests.first.url.path, '');
        expect(requests.last.url.path, '/home');
        expect(
          requests.every((request) => request.url.scheme == 'https'),
          isTrue,
        );
      },
    );

    test(
      'rejects HTTPS downgrade redirects without requesting the target',
      () async {
        var calls = 0;
        final detector = BooruSourceDetector(
          clientFactory: (_) => MockClient((_) async {
            calls++;
            return http.Response(
              '',
              302,
              headers: {'location': 'http://unsafe.example/'},
            );
          }),
        );

        await expectLater(
          detector.detect(Uri.https('custom.example')),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
      },
    );

    test('stops after the configured redirect limit', () async {
      var calls = 0;
      final detector = BooruSourceDetector(
        maxRedirects: 1,
        clientFactory: (_) => MockClient((_) async {
          calls++;
          return http.Response('', 302, headers: {'location': '/next'});
        }),
      );

      await expectLater(
        detector.detect(Uri.https('custom.example')),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 2);
    });

    test('bounds HTML responses and cancels stale detection', () async {
      final oversized = BooruSourceDetector(
        maxResponseBytes: 4,
        clientFactory: (_) =>
            MockClient((_) async => http.Response('12345', 200)),
      );
      await expectLater(
        oversized.detect(Uri.https('custom.example')),
        throwsA(isA<FormatException>()),
      );

      final pendingResponse = Completer<http.Response>();
      final cancelled = BooruSourceDetector(
        clientFactory: (_) => MockClient((_) => pendingResponse.future),
      );
      final abort = Completer<void>();
      final request = cancelled.detect(
        Uri.https('custom.example'),
        abortTrigger: abort.future,
      );
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await expectLater(request, throwsA(isA<http.RequestAbortedException>()));
      pendingResponse.complete(http.Response('unused', 200));

      final timedResponse = Completer<http.Response>();
      final timedOut = BooruSourceDetector(
        timeout: const Duration(milliseconds: 5),
        clientFactory: (_) => MockClient((_) => timedResponse.future),
      );
      await expectLater(
        timedOut.detect(Uri.https('custom.example')),
        throwsA(isA<TimeoutException>()),
      );
      timedResponse.complete(http.Response('unused', 200));
    });
  });
}
