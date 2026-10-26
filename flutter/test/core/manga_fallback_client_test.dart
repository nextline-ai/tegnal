import 'dart:async';
import 'dart:convert';

import 'package:ech_http/ech_http.dart' as ech;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/data/android_manga_client.dart';
import 'package:tegnal/data/manga_fallback_client.dart';

void main() {
  group('MangaFallbackClient', () {
    late ech.EchRoute route;
    late _FakeResolver resolver;
    late _FakeEchClient fallback;
    late List<String> resolvedHosts;

    setUp(() {
      route = ech.EchRoute(configList: base64.encode([0, 4, 1, 2, 3, 4]));
      resolver = _FakeResolver(route: route);
      fallback = _FakeEchClient();
      resolvedHosts = [];
    });

    MangaFallbackClient create({
      required http.Client primary,
      bool Function(Uri)? allow,
      ech.EchResolver? testResolver,
      _FakeEchClient? testFallback,
      int maxHosts = 8,
    }) => MangaFallbackClient(
      primary: primary,
      allowsUri:
          allow ??
          (uri) => uri.host == 'manga.example' || uri.host == 'cdn.example',
      bootstrapClientFactory: () =>
          MockClient((_) async => http.Response('', 200)),
      resolverFactory: (host, _) {
        resolvedHosts.add(host);
        return testResolver ?? resolver;
      },
      echClientFactory: (_, _) => testFallback ?? fallback,
      timeout: const Duration(seconds: 2),
      maxCachedHosts: maxHosts,
    );

    test(
      'retries allowed network failures through exact-host ECH route',
      () async {
        http.BaseRequest? primaryRequest;
        final primary = MockClient((request) async {
          primaryRequest = request;
          throw AndroidMangaNetworkException('Connection reset', request.url);
        });
        final client = create(primary: primary);
        final request =
            http.AbortableRequest(
                'GET',
                Uri.https('manga.example', '/galleriesindex/galleries.1.data'),
                abortTrigger: Completer<void>().future,
              )
              ..headers.addAll({
                'Range': 'bytes=0-7',
                'Cookie': 'session=ephemeral',
                'Referer': 'https://manga.example/galleries/1',
                'Connection': 'close',
              });

        final response = await client.send(request);

        expect(response.statusCode, 206);
        expect(await response.stream.toBytes(), [0, 1, 2, 3]);
        expect(primaryRequest!.url.host, 'manga.example');
        expect(fallback.lastRequest!.url.host, 'manga.example');
        expect(fallback.lastRequest!.followRedirects, isFalse);
        expect(fallback.lastRequest!.headers['cookie'], 'session=ephemeral');
        expect(
          fallback.lastRequest!.headers['referer'],
          request.headers['Referer'],
        );
        expect(fallback.lastRequest!.headers['range'], 'bytes=0-7');
        expect(fallback.lastRequest!.headers['accept-encoding'], 'identity');
        expect(
          fallback.lastRequest!.headers.containsKey('connection'),
          isFalse,
        );
        expect(resolvedHosts, ['manga.example']);
        client.close();
      },
    );

    test(
      'does not fallback after certificate or cancellation failures',
      () async {
        var resolverCalls = 0;
        final certificateClient = create(
          primary: MockClient((request) async {
            throw AndroidMangaCertificateException(
              'bad certificate',
              request.url,
            );
          }),
        );
        await expectLater(
          certificateClient.send(
            http.Request('GET', Uri.https('manga.example', '/')),
          ),
          throwsA(isA<AndroidMangaCertificateException>()),
        );
        expect(resolvedHosts, isEmpty);
        certificateClient.close();

        final cancelledClient = create(
          primary: MockClient((request) async {
            throw http.RequestAbortedException(request.url);
          }),
          testResolver: _CountingResolver((uri) async {
            resolverCalls++;
            return route;
          }),
        );
        await expectLater(
          cancelledClient.send(
            http.Request('GET', Uri.https('manga.example', '/')),
          ),
          throwsA(isA<http.RequestAbortedException>()),
        );
        expect(resolverCalls, 0);
        cancelledClient.close();
      },
    );

    test('forwards user cancellation to the ECH request', () async {
      final abort = Completer<void>();
      final echClient = _FakeEchClient(
        onSend: (request) async {
          final trigger = (request as http.Abortable).abortTrigger!;
          await trigger;
          throw http.RequestAbortedException(request.url);
        },
      );
      final client = create(
        primary: MockClient((request) async {
          throw AndroidMangaNetworkException('Connection reset', request.url);
        }),
        testFallback: echClient,
      );
      final request = http.AbortableRequest(
        'GET',
        Uri.https('manga.example', '/'),
        abortTrigger: abort.future,
      );
      final pending = client.send(request);
      await Future<void>.delayed(Duration.zero);
      abort.complete();

      await expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
      client.close();
    });

    test('only retries configured source hosts and GET requests', () async {
      final primary = MockClient((request) async {
        throw AndroidMangaNetworkException('Connection reset', request.url);
      });
      final client = create(
        primary: primary,
        allow: (uri) => uri.host == 'manga.example',
      );

      await expectLater(
        client.send(http.Request('GET', Uri.https('other.example', '/'))),
        throwsA(isA<AndroidMangaNetworkException>()),
      );
      await expectLater(
        client.send(http.Request('POST', Uri.https('manga.example', '/'))),
        throwsA(isA<AndroidMangaNetworkException>()),
      );
      expect(resolvedHosts, isEmpty);
      client.close();
    });

    test(
      'resolver failure or missing ECH route returns original network error',
      () async {
        final resolverFailure = ech.EchException('DoH unavailable');
        final failedClient = create(
          primary: MockClient((request) async {
            throw AndroidMangaNetworkException('Connection reset', request.url);
          }),
          testResolver: _FakeResolver(error: resolverFailure),
        );
        await expectLater(
          failedClient.send(
            http.Request('GET', Uri.https('manga.example', '/')),
          ),
          throwsA(isA<AndroidMangaNetworkException>()),
        );
        failedClient.close();

        final noRouteClient = create(
          primary: MockClient((request) async {
            throw AndroidMangaNetworkException('Connection reset', request.url);
          }),
          testResolver: _FakeResolver(),
        );
        await expectLater(
          noRouteClient.send(
            http.Request('GET', Uri.https('manga.example', '/')),
          ),
          throwsA(isA<AndroidMangaNetworkException>()),
        );
        expect(fallback.lastRequest, isNull);
        noRouteClient.close();
      },
    );

    test(
      'preserves native ECH TLS errors instead of retrying without ECH',
      () async {
        final tlsFailure = ech.EchException(
          'Certificate verification failed',
          nativeCode: 60,
        );
        final failedFallback = _FakeEchClient(error: tlsFailure);
        final client = create(
          primary: MockClient((request) async {
            throw AndroidMangaNetworkException('Connection reset', request.url);
          }),
          testFallback: failedFallback,
        );

        await expectLater(
          client.send(http.Request('GET', Uri.https('manga.example', '/'))),
          throwsA(same(tlsFailure)),
        );
        client.close();
      },
    );

    test(
      'keeps the client cache bounded by distinct allowed hostnames',
      () async {
        final clients = <_FakeEchClient>[];
        final client = MangaFallbackClient(
          primary: MockClient((request) async {
            throw AndroidMangaNetworkException('Connection reset', request.url);
          }),
          allowsUri: (uri) =>
              {'manga.example', 'cdn.example'}.contains(uri.host),
          bootstrapClientFactory: () =>
              MockClient((_) async => http.Response('', 200)),
          resolverFactory: (_, _) => _FakeResolver(route: route),
          echClientFactory: (_, _) {
            final next = _FakeEchClient();
            clients.add(next);
            return next;
          },
          timeout: const Duration(seconds: 2),
          maxCachedHosts: 1,
        );
        await (await client.send(
          http.Request('GET', Uri.https('manga.example', '/')),
        )).stream.drain<void>();
        await (await client.send(
          http.Request('GET', Uri.https('cdn.example', '/')),
        )).stream.drain<void>();

        expect(clients, hasLength(2));
        expect(clients.first.closed, isTrue);
        client.close();
      },
    );
  });
}

final class _FakeResolver implements ech.EchResolver {
  _FakeResolver({this.route, this.error});
  final ech.EchRoute? route;
  final Object? error;

  @override
  Future<ech.EchRoute?> resolve(Uri uri) async {
    if (error case final Object error) throw error;
    return route;
  }
}

final class _CountingResolver implements ech.EchResolver {
  _CountingResolver(this.callback);
  final Future<ech.EchRoute?> Function(Uri) callback;

  @override
  Future<ech.EchRoute?> resolve(Uri uri) => callback(uri);
}

final class _FakeEchClient extends http.BaseClient {
  _FakeEchClient({this.error, this.onSend});
  final Object? error;
  final Future<http.StreamedResponse> Function(http.BaseRequest)? onSend;
  http.BaseRequest? lastRequest;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (onSend != null) return onSend!(request);
    if (error case final Object error) throw error;
    return http.StreamedResponse(
      Stream<List<int>>.value([0, 1, 2, 3]),
      206,
      request: request,
      headers: const {'content-range': 'bytes 0-3/8'},
    );
  }

  @override
  void close() => closed = true;
}
