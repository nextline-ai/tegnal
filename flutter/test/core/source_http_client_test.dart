import 'dart:convert';
import 'dart:async';

import 'package:ech_http/ech_http.dart' as ech;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/android_manga_client.dart';
import 'package:tegnal/data/booru_extras.dart';
import 'package:tegnal/data/booru_source.dart';
import 'package:tegnal/data/source_http_client.dart';
import 'package:tegnal/data/session_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const browser = MethodChannel('work.nextline.tegnal/browser');
  final browserCalls = <MethodCall>[];
  final resolvedHosts = <String>[];
  final fallbackRequests = <http.Request>[];
  final clients = <SourceHttpClient>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    browserCalls.clear();
    resolvedHosts.clear();
    fallbackRequests.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (call) async {
          browserCalls.add(call);
          if (call.method == 'headersFor') {
            return {'Cookie': 'session=exact-url', 'User-Agent': 'Fixture'};
          }
          return null;
        });
  });
  tearDown(() {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, null);
  });

  SourceHttpClient create(
    Uri origin, {
    http.Client? primary,
    http.Client? fallback,
    bool allowSubdomains = false,
  }) {
    final client = SourceHttpClient(
      origin: origin,
      allowSubdomains: allowSubdomains,
      primary:
          primary ??
          MockClient((request) async {
            throw AndroidMangaNetworkException('Connection reset', request.url);
          }),
      resolverFactory: (host, _) {
        resolvedHosts.add(host);
        return ech.StaticEchResolver({
          host: ech.EchRoute(configList: base64.encode([0, 4, 1, 2, 3, 4])),
        });
      },
      echClientFactory: (_, _) =>
          fallback ??
          MockClient((request) async {
            fallbackRequests.add(request);
            return http.Response('[]', 200);
          }),
      bootstrapClientFactory: () =>
          MockClient((_) async => http.Response('', 200)),
    );
    clients.add(client);
    return client;
  }

  for (final entry in {
    'danbooru.donmai.us': SourceKind.danbooru,
    'gelbooru.com': SourceKind.gelbooru,
  }.entries) {
    test(
      '${entry.key} catalog recovers connection reset with scoped session',
      () async {
        final origin = Uri.https(entry.key);
        final client = create(origin);
        final source = BooruSource(
          SourceConfig(
            id: 'fixture',
            name: 'Fixture',
            baseUrl: origin,
            kind: entry.value,
          ),
          client: client,
        );

        final page = await source.search('fixture');

        expect(page.items, isEmpty);
        expect(resolvedHosts, [entry.key]);
        final retry = fallbackRequests.single;
        expect(retry.url.host, entry.key);
        expect(retry.headers['cookie'], 'session=exact-url');
        expect(retry.headers['user-agent'], 'Fixture');
        expect(retry.followRedirects, isFalse);
        expect(
          (browserCalls
                  .singleWhere((call) => call.method == 'headersFor')
                  .arguments
              as Map)['url'],
          retry.url.toString(),
        );
      },
    );
  }

  test(
    'pool and note endpoints share the transport and refresh URL cookies',
    () async {
      final origin = Uri.https('danbooru.donmai.us');
      final extras = BooruExtras(
        SourceConfig(
          id: 'fixture',
          name: 'Fixture',
          baseUrl: origin,
          kind: SourceKind.danbooru,
        ),
        client: create(origin),
      );

      expect((await extras.pools('fixture')).pools, isEmpty);
      expect(await extras.notes(42), isEmpty);

      expect(fallbackRequests.map((request) => request.url.path), [
        '/pools.json',
        '/notes.json',
      ]);
      expect(
        browserCalls.map((call) => (call.arguments as Map)['url']),
        fallbackRequests.map((request) => request.url.toString()),
      );
      expect(resolvedHosts, ['danbooru.donmai.us']);
    },
  );

  test('cross-origin redirects remain visible and never trigger ECH', () async {
    final client = create(
      Uri.https('danbooru.donmai.us'),
      primary: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://other.invalid/'},
        );
      }),
    );

    expect(
      (await client.get(Uri.https('danbooru.donmai.us', '/'))).statusCode,
      302,
    );
    expect(resolvedHosts, isEmpty);
    expect(fallbackRequests, isEmpty);
  });

  test('HTTP error and certificate failures never trigger ECH', () async {
    final url = Uri.https('gelbooru.com', '/index.php');
    for (final status in [401, 403, 429, 503]) {
      final client = create(
        url,
        primary: MockClient((_) async => http.Response('', status)),
      );
      expect((await client.get(url)).statusCode, status);
    }
    final client = create(
      url,
      primary: MockClient((request) async {
        throw AndroidMangaCertificateException(
          'Certificate rejected',
          request.url,
        );
      }),
    );
    await expectLater(
      client.get(url),
      throwsA(isA<AndroidMangaCertificateException>()),
    );
    expect(resolvedHosts, isEmpty);
    expect(fallbackRequests, isEmpty);
  });

  test(
    'default fallback scope excludes subdomains, ports, and lookalike hosts',
    () async {
      final client = create(Uri.https('gelbooru.com'));
      for (final url in [
        Uri.https('img.gelbooru.com', '/a'),
        Uri.https('gelbooru.com:8443', '/a'),
        Uri.https('gelbooru.com.other.invalid', '/a'),
      ]) {
        await expectLater(
          client.get(url),
          throwsA(isA<SourceConnectionException>()),
        );
      }
      expect(resolvedHosts, isEmpty);
      expect(fallbackRequests, isEmpty);
    },
  );

  test(
    'media origin receives only its own exact URL cookies and updates',
    () async {
      final url = Uri.https('cdn.other.invalid', '/images/a.jpg', {
        'token': 'fixture',
      });
      final client = create(
        url,
        fallback: MockClient((request) async {
          expect(request.headers['cookie'], 'session=exact-url');
          return http.Response(
            '',
            200,
            headers: {'set-cookie': 'cdn=updated; Secure'},
          );
        }),
      );

      await client.get(url, headers: {'Cookie': 'stale=source'});

      expect(browserCalls.map((call) => call.method), [
        'headersFor',
        'headersFor',
        'receiveCookies',
        'headersFor',
      ]);
      expect(
        browserCalls.every(
          (call) => (call.arguments as Map)['url'] == url.toString(),
        ),
        isTrue,
      );
      expect(resolvedHosts, ['cdn.other.invalid']);
    },
  );

  test(
    'unavailable ECH surfaces actionable connection failure in Booru features',
    () async {
      final origin = Uri.https('danbooru.donmai.us');
      final client = SourceHttpClient(
        origin: origin,
        primary: MockClient((request) async {
          throw AndroidMangaNetworkException('Connection reset', request.url);
        }),
        resolverFactory: (_, _) => ech.StaticEchResolver({}),
        bootstrapClientFactory: () =>
            MockClient((_) async => http.Response('', 200)),
      );
      clients.add(client);
      final config = SourceConfig(
        id: 'fixture',
        name: 'Fixture',
        baseUrl: origin,
        kind: SourceKind.danbooru,
      );
      final source = BooruSource(config, client: client);
      final extras = BooruExtras(config, client: client);
      final failure = isA<SourceConnectionException>()
          .having(
            (error) => error.message,
            'recovery message',
            contains('If it also requires a VPN or HTTPS bypass app in Chrome'),
          )
          .having(
            (error) => error.cause.uri,
            'original request host',
            isA<Uri>().having((uri) => uri.host, 'host', origin.host),
          );

      await expectLater(source.search('fixture'), throwsA(failure));
      await expectLater(extras.pools('fixture'), throwsA(failure));
      expect(fallbackRequests, isEmpty);
    },
  );

  test('closing releases primary, bootstrap and ECH clients once', () async {
    final primary = _TrackedClient((request) async {
      throw AndroidMangaNetworkException('Connection reset', request.url);
    });
    final bootstrap = _TrackedClient((_) async => http.Response('', 200));
    final fallback = _TrackedClient((_) async => http.Response('[]', 200));
    final origin = Uri.https('gelbooru.com');
    final client = SourceHttpClient(
      origin: origin,
      primary: primary,
      bootstrapClientFactory: () => bootstrap,
      resolverFactory: (host, _) => ech.StaticEchResolver({
        host: ech.EchRoute(configList: base64.encode([0, 4, 1, 2, 3, 4])),
      }),
      echClientFactory: (_, _) => fallback,
    );
    await client.get(origin);

    client.close();
    client.close();

    expect(
      [primary.closeCount, bootstrap.closeCount, fallback.closeCount],
      [1, 1, 1],
    );
    expect(() => client.get(origin), throwsA(isA<http.ClientException>()));
  });
  test(
    'verified browser retries only failed public same-origin posts JSON',
    () async {
      final origin = Uri.https('verified-fixture.invalid');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(browser, (call) async {
            calls.add(call);
            if (call.method == 'headersFor') {
              return {'Cookie': 'session=fixture', 'User-Agent': 'Browser'};
            }
            if (call.method == 'verifiedGet') {
              return {
                'statusCode': 200,
                'body': Uint8List.fromList(
                  utf8.encode(
                    ((call.arguments as Map)['url'] as String).contains(
                          '/posts/123.json',
                        )
                        ? '{}'
                        : '[]',
                  ),
                ),
              };
            }
            return null;
          });
      await BrowserSession.open(origin);
      var primaryCalls = 0;
      final client = create(
        origin,
        primary: MockClient((_) async {
          primaryCalls++;
          throw AndroidMangaNetworkException('reset');
        }),
        fallback: MockClient(
          (_) async => throw AndroidMangaNetworkException('reset'),
        ),
      );
      final url = origin.replace(
        path: '/posts.json',
        queryParameters: {'tags': 'cat', 'limit': '40', 'page': '1'},
      );
      final result = await client.get(
        url,
        headers: {'Accept': 'application/json'},
      );
      expect(result.body, '[]');
      final retry = calls.singleWhere((call) => call.method == 'verifiedGet');
      expect((retry.arguments as Map)['url'], url.toString());
      expect((retry.arguments as Map).containsKey('headers'), isFalse);
      final next = await client.get(
        url.replace(queryParameters: {'page': '2'}),
        headers: {'Accept': 'application/json'},
      );
      expect(next.body, '[]');
      final detail = await client.get(
        origin.replace(path: '/posts/123.json'),
        headers: {'Accept': 'application/json'},
      );
      expect(detail.body, '{}');
      expect(primaryCalls, 1);
      expect(calls.where((call) => call.method == 'verifiedGet'), hasLength(3));
      for (final request in [
        http.Request('GET', url)..headers['Authorization'] = 'secret',
        http.Request(
          'GET',
          url.replace(queryParameters: {'api_key': 'secret'}),
        ),
        http.Request('GET', origin.replace(path: '/image.jpg')),
        http.Request(
          'GET',
          origin.replace(
            path: '/posts/123.json',
            queryParameters: {'token': 'secret'},
          ),
        ),
        http.Request('GET', origin.replace(path: '/posts/not-a-number.json')),
        http.Request('GET', Uri.https('other.invalid', '/posts.json')),
      ]) {
        request.headers['Accept'] = 'application/json';
        await expectLater(
          client.send(request),
          throwsA(isA<SourceConnectionException>()),
        );
      }
      expect(calls.where((call) => call.method == 'verifiedGet'), hasLength(3));
      expect(BrowserSession.prefersVerified(origin), isTrue);
      await BrowserSession.open(origin);
      expect(BrowserSession.prefersVerified(origin), isFalse);
    },
  );

  test('verification after a failed search tries the browser before another slow network attempt', () async {
    final origin = Uri.https('verified-retry-first.invalid');
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (call) async {
          if (call.method == 'headersFor') return <String, String>{};
          if (call.method == 'verifiedGet') {
            return {
              'statusCode': 200,
              'body': Uint8List.fromList(utf8.encode('[]')),
            };
          }
          return null;
        });
    final client = create(
      origin,
      primary: MockClient((_) async {
        nativeCalls++;
        throw AndroidMangaNetworkException('reset');
      }),
      fallback: MockClient(
        (_) async => throw AndroidMangaNetworkException('reset'),
      ),
    );
    final url = origin.replace(path: '/posts.json');
    await expectLater(
      client.get(url, headers: {'Accept': 'application/json'}),
      throwsA(isA<SourceConnectionException>()),
    );
    expect(nativeCalls, 1);
    await BrowserSession.open(origin);
    expect(
      (await client.get(url, headers: {'Accept': 'application/json'})).body,
      '[]',
    );
    expect(nativeCalls, 1);
  });

  test(
    'successful browser route restores after a simulated process restart',
    () async {
      final origin = Uri.https('verified-restart.invalid');
      var nativeCalls = 0;
      var persisted = false;
      var cookieChanged = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(browser, (call) async {
            if (call.method == 'headersFor') return <String, String>{};
            if (call.method == 'hasVerifiedRoute') return persisted;
            if (call.method == 'verifiedGet') {
              persisted = true;
              return {
                'statusCode': 200,
                'body': Uint8List.fromList(utf8.encode('[]')),
                'cookieChanged': cookieChanged,
              };
            }
            return null;
          });
      await BrowserSession.open(origin);
      final client = create(
        origin,
        primary: MockClient((_) async {
          nativeCalls++;
          throw AndroidMangaNetworkException('reset');
        }),
        fallback: MockClient(
          (_) async => throw AndroidMangaNetworkException('reset'),
        ),
      );
      final url = origin.replace(path: '/posts.json');
      await client.get(url, headers: {'Accept': 'application/json'});
      expect(nativeCalls, 1);
      BrowserSession.resetLocalRouteStateForTesting();
      cookieChanged = true;
      final oldRevision = BrowserSession.revisionFor(url);
      expect(
        (await client.get(url, headers: {'Accept': 'application/json'})).body,
        '[]',
      );
      expect(nativeCalls, 1);
      expect(BrowserSession.revisionFor(url), isNot(oldRevision));
      expect(BrowserSession.prefersVerified(origin), isTrue);
    },
  );

  test(
    'HTML does not grant a browser route but valid-looking JSON content can',
    () async {
      final origin = Uri.https('verified-html.invalid');
      var body = '<html><body>Sign in</body></html>';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(browser, (call) async {
            if (call.method == 'verifiedGet') {
              return {
                'statusCode': 200,
                'body': Uint8List.fromList(utf8.encode(body)),
              };
            }
            return null;
          });
      await BrowserSession.open(origin);
      final url = origin.replace(path: '/posts.json');
      await BrowserSession.verifiedGet(http.Request('GET', url));
      expect(BrowserSession.prefersVerified(url), isFalse);
      body = '[{"description":"just a moment"}]';
      await BrowserSession.verifiedGet(http.Request('GET', url));
      expect(BrowserSession.prefersVerified(url), isTrue);
    },
  );

  test('browser certificate failure is never downgraded or reused', () async {
    final origin = Uri.https('verified-cert.invalid');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (call) async {
          if (call.method == 'headersFor') return <String, String>{};
          if (call.method == 'verifiedGet') {
            throw PlatformException(code: 'certificate_error');
          }
          return null;
        });
    await BrowserSession.open(origin);
    final client = create(
      origin,
      fallback: MockClient(
        (_) async => throw AndroidMangaNetworkException('reset'),
      ),
    );
    await expectLater(
      client.get(
        origin.replace(path: '/posts.json'),
        headers: {'Accept': 'application/json'},
      ),
      throwsA(isA<AndroidMangaCertificateException>()),
    );
    expect(BrowserSession.prefersVerified(origin), isFalse);
  });

  test('closing source cancels active verified browser retry', () async {
    final origin = Uri.https('verified-cancel.invalid');
    final pending = Completer<Object?>();
    final started = Completer<void>();
    final cancelled = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browser, (call) async {
          if (call.method == 'headersFor') return <String, String>{};
          if (call.method == 'verifiedGet') {
            started.complete();
            return pending.future;
          }
          if (call.method == 'cancelVerifiedGet') {
            cancelled.complete();
            return null;
          }
          return null;
        });
    await BrowserSession.open(origin);
    final client = create(
      origin,
      fallback: MockClient(
        (_) async => throw AndroidMangaNetworkException('reset'),
      ),
    );
    final future = client.get(
      origin.replace(path: '/posts.json'),
      headers: {'Accept': 'application/json'},
    );
    await started.future;
    final assertion = expectLater(
      future,
      throwsA(isA<http.RequestAbortedException>()),
    );
    client.close();
    await cancelled.future;
    await assertion;
    pending.completeError(PlatformException(code: 'aborted'));
  });
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    super.close();
  }
}
