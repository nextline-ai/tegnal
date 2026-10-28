import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/session_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('work.nextline.tegnal/browser');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'headersFor') {
            final uri = Uri.parse((call.arguments as Map)['url'] as String);
            return {
              'Cookie': 'session=${uri.host}',
              'User-Agent': 'WebView Fixture',
              'Untrusted-Extra': 'ignore',
            };
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'concurrent same-URL cookie lookups share only the in-flight call',
    () async {
      final gate = Completer<void>();
      var lookups = 0;
      var cookie = 'session=one';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'headersFor') {
              lookups++;
              await gate.future;
              return {'Cookie': cookie};
            }
            return null;
          });
      final firstUrl = Uri.https('session-a.invalid', '/image');
      final secondUrl = Uri.https('session-a.invalid', '/other');
      final first = BrowserSession.headersFor(firstUrl);
      final duplicate = BrowserSession.headersFor(firstUrl);
      final other = BrowserSession.headersFor(secondUrl);
      await Future<void>.delayed(Duration.zero);
      expect(lookups, 2);
      gate.complete();
      final a = await first;
      final b = await duplicate;
      await other;
      a['Cookie'] = 'mutated';
      expect(b['Cookie'], 'session=one');
      cookie = 'session=two';
      expect(
        (await BrowserSession.headersFor(firstUrl))['Cookie'],
        'session=two',
      );
      expect(lookups, 3);
    },
  );

  test(
    'cookie lookups are not shared across a browser-session change',
    () async {
      final gates = <Completer<void>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'headersFor') {
              final gate = Completer<void>();
              gates.add(gate);
              await gate.future;
              return <String, String>{};
            }
            return null;
          });
      final url = Uri.https('session-revision.invalid', '/image');
      final first = BrowserSession.headersFor(url);
      await Future<void>.delayed(Duration.zero);
      await BrowserSession.open(url);
      final second = BrowserSession.headersFor(url);
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2);
      for (final gate in gates) {
        gate.complete();
      }
      await Future.wait([first, second]);
    },
  );

  test('source requests adopt URL-scoped browser cookies and UA without redirecting', () async {
    late http.Request sent;
    final client = SessionClient(
      origin: Uri.parse('https://source.invalid'),
      inner: MockClient((request) async {
        sent = request;
        return http.Response('[]', 200);
      }),
    );
    await client.get(
      Uri.parse('https://source.invalid/posts.json'),
      headers: {'Cookie': 'stale=origin', 'User-Agent': 'TEGNAL'},
    );
    expect(sent.headers['cookie'], 'session=source.invalid');
    expect(sent.headers['user-agent'], 'WebView Fixture');
    expect(sent.headers['untrusted-extra'], isNull);
    expect(sent.followRedirects, isFalse);
    expect(
      (calls.single.arguments as Map)['url'],
      'https://source.invalid/posts.json',
    );
  });

  test('subdomain cookies are looked up for that subdomain, never copied from origin', () async {
    late http.Request sent;
    final client = SessionClient(
      origin: Uri.parse('https://source.invalid'),
      inner: MockClient((request) async {
        sent = request;
        return http.Response('', 200);
      }),
    );
    await client.get(Uri.parse('https://images.source.invalid/media/a.jpg'));
    expect(sent.headers['cookie'], 'session=images.source.invalid');
    expect(
      (calls.single.arguments as Map)['url'],
      'https://images.source.invalid/media/a.jpg',
    );
  });

  test('unrelated and lookalike hosts receive no source cookie', () async {
    final requests = <http.Request>[];
    final client = SessionClient(
      origin: Uri.parse('https://source.invalid'),
      inner: MockClient((request) async {
        requests.add(request);
        return http.Response('', 200);
      }),
    );
    for (final host in [
      'cdn.other.invalid',
      'source.invalid.evil.invalid',
      'notsource.invalid',
    ]) {
      await client.get(
        Uri.parse('https://$host/file'),
        headers: {'Cookie': 'stale=source'},
      );
    }
    expect(requests.every((r) => !r.headers.containsKey('cookie')), isTrue);
    expect(calls, isEmpty);
  });

  test('media lookup asks CookieManager for the exact CDN URL', () async {
    final headers = await BrowserSession.headersFor(
      Uri.parse('https://cdn.other.invalid/a.jpg'),
    );
    expect(headers['Cookie'], 'session=cdn.other.invalid');
    expect(
      (calls.single.arguments as Map)['url'],
      'https://cdn.other.invalid/a.jpg',
    );
    expect(headers.containsKey('Untrusted-Extra'), isFalse);
    expect(
      await BrowserSession.headersFor(Uri.parse('file:///private/a.jpg')),
      isEmpty,
    );
    expect(
      await BrowserSession.headersFor(Uri.parse('http://cdn.invalid/a.jpg')),
      isEmpty,
    );
    expect(calls.length, 1);
  });

  test(
    'Set-Cookie updates the WebView store and keeps Expires commas intact',
    () async {
      final client = SessionClient(
        origin: Uri.parse('https://source.invalid'),
        inner: MockClient(
          (_) async => http.Response(
            '',
            200,
            headers: {
              'set-cookie': 'one=1; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Secure, two=2; Path=/; HttpOnly',
            },
          ),
        ),
      );
      await client.get(Uri.parse('https://source.invalid/login'));
      final receive = calls.singleWhere(
        (call) => call.method == 'receiveCookies',
      );
      expect(receive.method, 'receiveCookies');
      expect((receive.arguments as Map)['url'], 'https://source.invalid/login');
      expect((receive.arguments as Map)['cookies'], [
        'one=1; Expires=Wed, 21 Oct 2030 07:28:00 GMT; Secure',
        ' two=2; Path=/; HttpOnly',
      ]);
    },
  );

  test('cookie changes invalidate only affected domain and unchanged cookies do not', () async {
    var cookie = 'session=old';
    var nextCookie = cookie;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'headersFor') return {'Cookie': cookie};
          if (call.method == 'receiveCookies') cookie = nextCookie;
          return null;
        });
    final source = Uri.parse('https://source.invalid/login');
    final child = Uri.parse('https://img.source.invalid/a');
    final other = Uri.parse('https://elsewhere.invalid/a');
    final client = SessionClient(
      origin: source,
      inner: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'set-cookie': 'session=new; Domain=source.invalid; Path=/'},
        ),
      ),
    );
    final sourceBefore = BrowserSession.revisionFor(source);
    final childBefore = BrowserSession.revisionFor(child);
    final otherBefore = BrowserSession.revisionFor(other);
    await client.get(source); // same cookie: no invalidation
    expect(BrowserSession.revisionFor(source), sourceBefore);
    expect(BrowserSession.revisionFor(child), childBefore);
    nextCookie = 'session=new';
    await client.get(source);
    expect(BrowserSession.revisionFor(source), isNot(sourceBefore));
    expect(BrowserSession.revisionFor(child), isNot(childBefore));
    expect(BrowserSession.revisionFor(other), otherBefore);
    final changed = BrowserSession.revisionFor(source);
    await client.get(source);
    expect(BrowserSession.revisionFor(source), changed);
  });

  test(
    'cross-origin HTTP redirect is returned without fetching destination',
    () async {
      final requests = <http.Request>[];
      final client = SessionClient(
        origin: Uri.parse('https://source.invalid'),
        inner: MockClient((request) async {
          requests.add(request);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.invalid/'},
          );
        }),
      );
      final response = await client.get(Uri.parse('https://source.invalid/'));
      expect(response.statusCode, 302);
      expect(requests.length, 1);
      expect(requests.single.followRedirects, isFalse);
    },
  );

  test(
    'desktop does not import browser cookies or call the Android bridge',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      late http.Request sent;
      final client = SessionClient(
        origin: Uri.parse('https://source.invalid'),
        inner: MockClient((request) async {
          sent = request;
          return http.Response('', 200);
        }),
      );
      expect(BrowserSession.supported, isFalse);
      await client.get(
        Uri.parse('https://source.invalid/'),
        headers: {'User-Agent': 'Desktop Fixture'},
      );
      expect(sent.headers['user-agent'], 'Desktop Fixture');
      expect(sent.headers['cookie'], isNull);
      expect(
        await BrowserSession.headersFor(Uri.parse('https://source.invalid/')),
        isEmpty,
      );
      expect(calls, isEmpty);
    },
  );

  test(
    'opening browser uses explicit HTTPS URL and rejects unsafe schemes',
    () async {
      await BrowserSession.open(
        Uri.parse('https://source.invalid/login?next=posts'),
        labels: {'retry': '다시 시도', 'browser': '브라우저에서 열기'},
      );
      expect(calls.single.method, 'open');
      expect((calls.single.arguments as Map)['labels'], {
        'retry': '다시 시도',
        'browser': '브라우저에서 열기',
      });
      expect(
        (calls.single.arguments as Map)['url'],
        'https://source.invalid/login?next=posts',
      );
      for (final url in [
        'http://source.invalid',
        'file:///etc/passwd',
        'https://user:pass@source.invalid',
      ]) {
        await expectLater(
          BrowserSession.open(Uri.parse(url)),
          throwsA(isA<ContentException>()),
        );
      }
      expect(calls.length, 1);
    },
  );

  test(
    'missing bridge is stateless and closed adapters reject sends',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(
        await BrowserSession.headersFor(Uri.parse('https://source.invalid/')),
        isEmpty,
      );
      final client = SessionClient(
        origin: Uri.parse('https://source.invalid'),
        inner: MockClient((_) async => http.Response('', 200)),
      );
      client.close();
      await expectLater(
        client.get(Uri.parse('https://source.invalid/')),
        throwsA(isA<http.ClientException>()),
      );
    },
  );
}
