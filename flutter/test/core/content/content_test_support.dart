import 'dart:async';
import 'dart:convert';

import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/support/preferences.dart';

/// A test response: data, a redirect, or a connection failure thrown by the handler.
class FixtureReply {
  FixtureReply(this.status, [List<int>? data, Map<String, String>? headers]) : data = data ?? const [], headers = headers ?? const {};
  FixtureReply.text(this.status, String text, [Map<String, String>? headers]) : data = utf8.encode(text), headers = headers ?? const {};
  FixtureReply.redirect(Uri target) : status = 302, data = const [], headers = {'Location': target.toString()};

  final int status;
  final List<int> data;
  final Map<String, String> headers;
}

/// The network below `ContentTransport`, as the Swift tests install a `URLProtocol`.
class FixtureFetcher implements HttpFetcher {
  FixtureFetcher(this.handler);
  final FutureOr<FixtureReply> Function(HttpExchange request) handler;
  final requests = <HttpExchange>[];

  @override
  Future<HttpReply> send(HttpExchange request) async {
    requests.add(request);
    final reply = await handler(request);
    return HttpReply(
      statusCode: reply.status,
      headers: {
        for (final MapEntry(:key, :value) in reply.headers.entries) key.toLowerCase(): [value],
      },
      body: Stream.value(reply.data),
    );
  }
}

/// Isolated preferences, keys and account for one test, like the Swift tests' setUp.
Preferences resetContent({String? site}) {
  ContentPreferences.isIsolated = true;
  final preferences = MemoryPreferences();
  ContentPreferences.defaults = preferences;
  resetMangaBackendResolver();
  GalleryKeys.shared = GalleryKeys();
  SiteAccount.store = MemorySecretStore();
  SiteAccount.signOut();
  if (site != null) preferences.set('manga.site_address', site);
  return preferences;
}

/// Polls a condition the way the Swift tests wait for controlled requests.
Future<void> waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Timed out waiting for the fixture');
}
