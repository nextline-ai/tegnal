import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/encrypted_hello_fetcher.dart';
import 'package:tegnal/core/support/preferences.dart';

class _Fetcher implements HttpFetcher {
  _Fetcher(this.name, {this.fails = false});
  final String name;
  bool fails;
  final calls = <String>[];

  @override
  Future<HttpReply> send(HttpExchange request) async {
    calls.add(request.url.host);
    if (fails) throw const NetworkError(NetworkErrorCode.networkConnectionLost);
    return HttpReply(statusCode: 200, headers: const {}, body: Stream.value(name.codeUnits));
  }
}

HttpExchange _get(String host) => HttpExchange(method: 'GET', url: Uri.parse('https://$host/'), headers: const {}, timeout: const Duration(seconds: 1));

void main() {
  test('a cut connection retries with ECH, and the host keeps that route after a relaunch', () async {
    final preferences = MemoryPreferences();
    final plain = _Fetcher('plain', fails: true), ech = _Fetcher('ech');
    final fetcher = FilteredNetworkFetcher(primary: plain, fallback: ech, preferences: preferences);
    expect(String.fromCharCodes(await (await fetcher.send(_get('filtered.example'))).body.first), 'ech');
    expect(plain.calls, ['filtered.example']);

    final relaunched = FilteredNetworkFetcher(primary: plain, fallback: ech, preferences: preferences);
    await relaunched.send(_get('filtered.example'));
    expect(plain.calls, ['filtered.example'], reason: 'A remembered host must not pay for another cut connection');
    expect(ech.calls, ['filtered.example', 'filtered.example']);
  });

  test('a host the plain route reaches never uses ECH, and other failures are not retried', () async {
    final plain = _Fetcher('plain'), ech = _Fetcher('ech');
    final fetcher = FilteredNetworkFetcher(primary: plain, fallback: ech);
    await fetcher.send(_get('open.example'));
    expect(ech.calls, isEmpty);

    final refusing = _RefusingFetcher();
    final strict = FilteredNetworkFetcher(primary: refusing, fallback: ech);
    await expectLater(strict.send(_get('down.example')), throwsA(const NetworkError(NetworkErrorCode.cannotConnectToHost)));
    expect(ech.calls, isEmpty);
  });

  test('when ECH stops working for a remembered host, the plain route is tried again', () async {
    final plain = _Fetcher('plain', fails: true), ech = _Fetcher('ech');
    final fetcher = FilteredNetworkFetcher(primary: plain, fallback: ech);
    await fetcher.send(_get('site.example'));
    ech.fails = true;
    plain.fails = false;
    expect(String.fromCharCodes(await (await fetcher.send(_get('site.example'))).body.first), 'plain');
    expect(fetcher.prefersFallback('site.example'), isFalse);
  });
}

class _RefusingFetcher implements HttpFetcher {
  @override
  Future<HttpReply> send(HttpExchange request) async => throw const NetworkError(NetworkErrorCode.cannotConnectToHost);
}
