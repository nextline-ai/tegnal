// Ported from native-ios/TEGNALTests/MangaBackendTests.swift.
// Not ported yet: testMissingGalleryHTTPResponseIsCountedAsGoneByBackfill needs CoverQueueActor (step 3).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/cdn_routing.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/support/swift_json.dart';

import 'content_test_support.dart';

class BackendFixture {
  BackendFixture() : host = 'comics-${uuidString().toLowerCase()}.example' {
    resetContent(site: host);
  }

  final String host;
  int _generation = 1;
  NetworkErrorCode _staleEndpointFailure = NetworkErrorCode.cannotFindHost;
  bool _discoveryAvailable = true;
  Map<String, List<int>> indexes = {};
  final requests = <Uri>[];

  String get domain => _domain(_generation);
  String _domain(int generation) => 'storage-$generation.$host';
  void advanceDomain({NetworkErrorCode failure = NetworkErrorCode.cannotFindHost}) {
    _generation += 1;
    _staleEndpointFailure = failure;
  }

  void setDiscoveryAvailable(bool available) => _discoveryAvailable = available;
  int count({String? path, String? host}) => requests.where((url) => (path == null || url.path == path) && (host == null || url.host == host)).length;

  ContentTransport transport({BrowserFetch? browserFetch}) => ContentTransport(fetcher: FixtureFetcher(reply), browserFetch: browserFetch);

  FixtureReply reply(HttpExchange request) {
    final url = request.url;
    requests.add(url);
    if (url.host == host) {
      if (url.path == '/') {
        if (!_discoveryAvailable) return FixtureReply(503);
        return FixtureReply.text(200, '<script src="/assets/common.js?v=7"></script><a href="/galleries/1234.html">Work</a>');
      }
      if (url.path == '/assets/common.js') return FixtureReply.text(200, "const domain = '${_domain(_generation)}';");
      return FixtureReply(404);
    }
    if (!['ltn.', 'atn.'].any((prefix) => url.host == prefix + _domain(_generation))) throw NetworkError(_staleEndpointFailure);
    if (url.path.endsWith('.webp')) return FixtureReply(200, List.filled(64, 1), {'Content-Type': 'image/webp'});
    final ids = indexes[url.path];
    if (ids != null) {
      final data = ByteData(ids.length * 4);
      for (final (index, id) in ids.indexed) {
        data.setUint32(index * 4, id);
      }
      final bytes = data.buffer.asUint8List();
      final range = request.headers.entries.where((entry) => entry.key.toLowerCase() == 'range').firstOrNull?.value;
      if (range != null) {
        final parts = range.replaceAll('bytes=', '').split('-').map(int.parse).toList();
        final start = parts[0], end = parts[1] < bytes.length - 1 ? parts[1] : bytes.length - 1;
        if (start >= bytes.length) return FixtureReply(416, const [], {'Content-Range': 'bytes */${bytes.length}'});
        return FixtureReply(206, bytes.sublist(start, end + 1), {'Content-Range': 'bytes $start-$end/${bytes.length}'});
      }
      return FixtureReply(200, bytes);
    }
    switch (url.path) {
      case '/galleriesindex/version':
        return FixtureReply.text(200, '1');
      case '/index-korean.nozomi':
        return FixtureReply(206, const [0, 0, 22, 46, 0, 0, 4, 210], {'Content-Range': 'bytes 0-7/8'});
      case '/type/artistcg-all.nozomi' || '/type/gamecg-all.nozomi' || '/type/imageset-all.nozomi':
        return FixtureReply(416, const [], {'Content-Range': 'bytes */0'});
      case '/galleries/1234.js':
        final hash = 'a' * 64;
        return FixtureReply.text(200, 'var galleryinfo = {"title":"Fixture","files":[{"hash":"$hash","name":"1.jpg","width":100,"height":150}]};');
      case '/gg.js':
        return FixtureReply.text(200, '''
'use strict';
gg = { m: function(g) { var o = 0; switch (g) { case 1: o = 1; break; } return o; },
s: function(h) { var m = /(..)(.)\$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
b: '123/' };
''');
      default:
        return FixtureReply(404);
    }
  }
}

void main() {
  test('derived data domain matches current indexed frontend without executing script', () {
    const script = '''
        const domain2 = 'media.example';
        var domain = (/^dev\\./.test(document.location.hostname.toString()) ? 'dev.comics.example' : 'ltn.'+domain2);
        ''';
    final hosts = MangaUrls.indexedBackendHosts(script)!;
    expect(hosts.dataHost, 'ltn.media.example');
    expect(hosts.cdn, 'media.example');
    expect(MangaUrls.indexedBackendHosts("const domain2 = 'unrelated.example';"), isNull);
    expect(MangaUrls.indexedBackendHosts("const domain2 = 'broken..example'; var domain = 'ltn.'+domain2;"), isNull);
  });

  test('interrupted saved endpoint refreshes before retrying the catalog', () async {
    for (final failure in [NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.networkConnectionLost, NetworkErrorCode.timedOut]) {
      final fixture = BackendFixture();
      final transport = fixture.transport(browserFetch: (_, _, _, _, _) async => throw NetworkError(failure));
      final source = MangaContentSource(transport: transport);
      await source.list(const GalleryQuery(), offset: 0, count: 2);
      fixture.advanceDomain(failure: failure);
      final gallery = await source.gallery(1234);
      expect(gallery.id, 1234);
      expect(MangaUrls.dataHost, 'ltn.${fixture.domain}');
      expect(fixture.count(path: '/'), 2);
    }
    expect(ContentTransport.backendConnectionFailed(const NetworkError(NetworkErrorCode.serverCertificateUntrusted)), isFalse);
    expect(ContentTransport.backendConnectionFailed(const NetworkError(NetworkErrorCode.cancelled)), isFalse);
  });

  test("first list and metadata discover the custom site's script only once", () async {
    final fixture = BackendFixture(), source = MangaContentSource(transport: fixture.transport());
    final results = await Future.wait([source.list(const GalleryQuery(), offset: 0, count: 2), source.gallery(1234)]);
    expect((results[0] as GalleryBatch).ids, [5678, 1234]);
    expect((results[1] as NativeGallery).id, 1234);
    expect(fixture.count(path: '/'), 1);
    expect(fixture.count(path: '/assets/common.js'), 1);
    expect(fixture.count(host: 'ltn.${fixture.host}'), 0, reason: 'Resolve the script before requesting the old derived host');
    expect(MangaUrls.dataHost, 'ltn.${fixture.domain}');
    expect(MangaUrls.cdnHost, fixture.domain);
    expect(ContentTransport.allows(Uri.parse('https://w1.${fixture.domain}/image.webp')), isTrue);
    expect(ContentTransport.allows(Uri.parse('https://unrelated.example/gg.js')), isFalse);
  });

  test('ten default exclusions load the feed and apply every filter', () async {
    final fixture = BackendFixture();
    final excluded = [for (var index = 1; index <= 10; index++) 'tag:excluded$index'];
    fixture.indexes['/index-korean.nozomi'] = [for (var id = 2011; id >= 2000; id--) id];
    fixture.indexes['/tag/included-all.nozomi'] = [for (var id = 2011; id >= 2000; id--) id];
    for (var index = 1; index <= 10; index++) {
      fixture.indexes['/tag/excluded$index-all.nozomi'] = [2000 + index];
    }
    final source = MangaContentSource(transport: fixture.transport());
    for (final text in ['', 'tag:included']) {
      final query = GalleryQuery(text: text).applyingDefaults(tags: '', excluded: excluded.join(' '));
      final batch = await source.list(query, offset: 0, count: 24);
      expect(batch.ids, [2011, 2000], reason: 'All ten exclusions must apply to the initial feed and explicit searches');
      expect(batch.hasMore, isFalse);
    }
  });

  test('excessive search terms report the limit without dropping filters', () async {
    final fixture = BackendFixture();
    final exclusions = [for (var index = 1; index <= GalleryQuery.maximumSearchTerms; index++) 'tag:excluded$index'].join(' ');
    final query = const GalleryQuery(text: 'tag:included').applyingDefaults(tags: '', excluded: exclusions);
    await expectLater(
      MangaContentSource(transport: fixture.transport()).list(query, offset: 0, count: 1),
      throwsA(const ContentError.tooManySearchTerms(GalleryQuery.maximumSearchTerms)),
    );
    expect(fixture.count(path: '/galleriesindex/version'), 0);
  });

  test('language exception merges visual indexes without dropping artist type or popular order', () async {
    final fixture = BackendFixture();
    fixture.indexes = {
      '/index-korean.nozomi': [2000, 1997],
      '/type/artistcg-all.nozomi': [2003],
      '/type/gamecg-all.nozomi': [2002, 1999],
      '/type/imageset-all.nozomi': [2001],
      '/artist/sample-all.nozomi': [2002, 1998],
      '/type/manga-all.nozomi': [2000, 1997],
      '/popular/week-all.nozomi': [1997, 2001, 2002, 2000, 2003, 1999],
    };
    final source = MangaContentSource(transport: fixture.transport());
    final strict = await source.list(const GalleryQuery(), offset: 0, count: 10);
    expect(strict.ids, [2000, 1997], reason: 'Language exceptions are off by default');
    final first = await source.list(const GalleryQuery(allowsLanguageExceptions: true), offset: 0, count: 3);
    expect(first.ids, [2003, 2002, 2001]);
    final second = await source.list(const GalleryQuery(allowsLanguageExceptions: true), offset: 3, count: 3);
    expect(second.ids, [2000, 1999, 1997]);
    expect(second.hasMore, isFalse);
    expect(fixture.count(path: '/type/gamecg-all.nozomi'), 1, reason: 'Pagination must reuse the bounded prefix');
    final artist = await source.list(const GalleryQuery(artist: 'sample', allowsLanguageExceptions: true), offset: 0, count: 10);
    expect(artist.ids, [2002]);
    final manga = await source.list(const GalleryQuery(text: 'type:manga', allowsLanguageExceptions: true), offset: 0, count: 10);
    expect(manga.ids, [2000, 1997]);
    final popular = await source.list(const GalleryQuery(sort: GallerySort.week, allowsLanguageExceptions: true), offset: 0, count: 10);
    expect(popular.ids, [1997, 2001, 2002, 2000, 2003, 1999]);
    final strictPopular = await source.list(const GalleryQuery(sort: GallerySort.week), offset: 0, count: 10);
    expect(strictPopular.ids, [1997, 2000], reason: 'Turning exceptions off must not reuse the permissive search cache');
  });

  test('saved endpoints survive new sources without rediscovery', () async {
    final fixture = BackendFixture();
    await MangaContentSource(transport: fixture.transport()).list(const GalleryQuery(), offset: 0, count: 2);
    expect(MangaUrls.preferences.string('manga.resolved_backend_site'), MangaUrls.home);
    for (var index = 0; index < 3; index++) {
      final gallery = await MangaContentSource(transport: fixture.transport()).gallery(1234);
      expect(gallery.pages, isNotEmpty);
    }
    expect(MangaUrls.hasResolvedBackend, isTrue);
    expect(fixture.count(path: '/'), 1);
    expect(fixture.count(path: '/assets/common.js'), 1);
  });

  test('failed saved endpoint refreshes then retries the original request', () async {
    final fixture = BackendFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(), offset: 0, count: 2);
    final previous = MangaUrls.dataHost;
    fixture.advanceDomain();
    final gallery = await source.gallery(1234);
    expect(gallery.id, 1234);
    expect(MangaUrls.dataHost, isNot(previous));
    expect(MangaUrls.dataHost, 'ltn.${fixture.domain}');
    expect(fixture.count(path: '/'), 2);
    expect(fixture.count(path: '/assets/common.js'), 2);
    await MangaContentSource(transport: fixture.transport()).list(const GalleryQuery(), offset: 0, count: 2);
    expect(fixture.count(path: '/'), 2);
  });

  test('image connection failure refreshes the saved CDN only when needed', () async {
    final fixture = BackendFixture(), source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(1234);
    await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true);
    expect(fixture.count(path: '/'), 1);
    fixture.advanceDomain();
    await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true);
    expect(fixture.count(path: '/'), 2);
    expect(MangaUrls.cdnHost, fixture.domain);
    await source.image(gallery.pages[0], galleryID: gallery.id, thumbnail: true);
    expect(fixture.count(path: '/'), 2);
  });

  test('removed work does not trigger backend refresh', () async {
    final fixture = BackendFixture(), source = MangaContentSource(transport: fixture.transport());
    await source.list(const GalleryQuery(), offset: 0, count: 2);
    await expectLater(source.gallery(9999), throwsA(const ContentError.unavailable(404)));
    expect(fixture.count(path: '/'), 1);
    expect(MangaUrls.hasResolvedBackend, isTrue);
  });

  test("site change cannot reuse or accept the previous site's endpoints", () async {
    final fixture = BackendFixture();
    await MangaUrls.resolveBackend(transport: fixture.transport());
    final original = MangaUrls.home;
    MangaUrls.preferences.set('manga.site_address', 'another-comics.example');
    expect(MangaUrls.hasResolvedBackend, isFalse);
    expect(MangaUrls.dataHost, 'ltn.another-comics.example');
    expect(MangaUrls.cdnHost, 'another-comics.example');
    expect(MangaUrls.extractBackend("const domain = 'late-response.example';", site: original), isFalse);
    expect(MangaUrls.dataHost, 'ltn.another-comics.example');
    MangaUrls.resetResolvedBackend();
    expect(MangaUrls.preferences.object('manga.resolved_backend_site'), isNull);
  });

  test('frontend gallery links do not masquerade as data endpoints', () {
    BackendFixture();
    expect(MangaUrls.extractBackend('<a href="https://front.example/galleries/1234.html">Work</a>'), isFalse);
    expect(MangaUrls.hasResolvedBackend, isFalse);
    expect(MangaUrls.extractBackend('<script src="//ltn.storage.example/gg.js?v=123"></script>'), isTrue);
    expect(MangaUrls.dataHost, 'ltn.storage.example');
    expect(MangaUrls.cdnHost, 'storage.example');
  });

  test('forced discovery can recover immediately after a failure', () async {
    final fixture = BackendFixture(), transport = fixture.transport();
    fixture.setDiscoveryAvailable(false);
    await MangaUrls.resolveBackend(transport: transport);
    expect(MangaUrls.hasResolvedBackend, isFalse);
    fixture.setDiscoveryAvailable(true);
    await MangaUrls.resolveBackend(transport: transport, force: true);
    expect(MangaUrls.hasResolvedBackend, isTrue, reason: 'Explicit recovery must not be blocked by the failed-discovery cooldown');
    expect(fixture.count(path: '/'), 2);
  });

  test('routing uses the saved CDN without rechecking the homepage', () async {
    final fixture = BackendFixture();
    final source = MangaContentSource(transport: fixture.transport());
    final gallery = await source.gallery(1234);
    // Exercise the same discovery/cache path used by the routing configuration.
    final result = await fixture.transport().getData('gg.js', limit: 100000);
    final routing = CDNRouting(String.fromCharCodes(result.data));
    final thumbnail = routing.url(hash: gallery.pages[0].hash, format: 'webp', thumbnail: true);
    expect(thumbnail.host, 'atn.${fixture.domain}');
    expect(fixture.count(path: '/'), 1);
    expect(fixture.count(path: '/assets/common.js'), 1);
  });
}
