// Ported from native-ios/TEGNALTests/SiteAccessTests.swift.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/cover_queue.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/keyed_catalog_source.dart';
import 'package:tegnal/core/content/keyed_work_extras.dart';
import 'package:tegnal/core/content/manga_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/content/site_account_actions.dart';
import 'package:tegnal/core/content/site_fallback_content.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/thumbnail_disk_cache.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/presentation/content/work_extras_views.dart';

import 'content_test_support.dart';

const _hash = '0123456789abcdef0123456789abcdef';

class _FakeSite extends ContentProviding {
  _FakeSite(this.name, this.works, {this.refusal});
  final String name;
  final Map<int, String> works;

  /// What the website answers every request with instead of a work.
  final ContentError? refusal;
  int calls = 0;

  @override
  Future<NativeGallery> gallery(int id) async {
    calls += 1;
    if (refusal case final refusal?) throw refusal;
    final title = works[id];
    if (title == null) throw ContentError.galleryNotFound;
    return NativeGallery(id: id, title: title, artists: const [], language: '', type: '', tags: const [], pages: const []);
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async => const GalleryBatch(ids: [], hasMore: false);

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async => Uint8List.fromList(utf8.encode(name));
}

void _resolveKeyed(Preferences preferences, String host) {
  preferences.set('manga.site_address', host);
  preferences.set('manga.resolved_data_host', host);
  preferences.set('manga.resolved_cdn_host', host);
  preferences.set('manga.resolved_backend_site', 'https://$host/');
  preferences.set('manga.resolved_protocol', 'keyed');
}

void main() {
  late Preferences preferences;
  setUp(() {
    preferences = resetContent();
    SiteClearance.removeAll();
    for (final host in ['members.example', 'keyed.example', 'checked.example', 'private.example']) {
      ContentTransport.clearChallenge(host);
    }
  });

  group('cookies', () {
    test('pasted cookies keep the account and its access but never a placeholder', () {
      final pasted = SiteAccount.parseCookies('Cookie: ipb_member_id=1234567; ipb_pass_hash=$_hash; igneous=mystery; sk=abc123; tracking=1');
      expect(pasted.isComplete, isTrue);
      expect(pasted.identity, {'ipb_member_id': '1234567', 'ipb_pass_hash': _hash});
      expect(pasted.site, {'sk': 'abc123'}, reason: 'A placeholder instead of access, and unrelated cookies, are dropped');
      final lines = SiteAccount.parseCookies('ipb_member_id = 42\nipb_pass_hash="ffeeddccbbaa99887766554433221100"\nigneous=a1b2c3d4e5');
      expect(lines.identity['ipb_member_id'], '42');
      expect(lines.identity['ipb_pass_hash'], 'ffeeddccbbaa99887766554433221100');
      expect(lines.site['igneous'], 'a1b2c3d4e5');
      expect(SiteAccount.parseCookies('igneous=a1b2c3').isComplete, isFalse);
    });

    test('access from sign-in survives the placeholder the site sends back', () {
      preferences.set('manga.site_address', 'members.example');
      MangaUrls.markUsesAccount(site: MangaUrls.home);
      expect(SiteAccount.signInPasted(SiteAccount.parseCookies('ipb_member_id=7; ipb_pass_hash=$_hash; igneous=feedface01'), host: 'members.example'), isTrue);
      expect(SiteAccount.cookies('members.example')['igneous'], 'feedface01');
      SiteAccount.storeResponse(Uri.parse('https://members.example/'), ['igneous=mystery; path=/; domain=.members.example']);
      expect(SiteAccount.cookies('members.example')['igneous'], 'feedface01');
      SiteAccount.forget(SiteAccount.accessCookie, host: 'members.example');
      expect(SiteAccount.cookies('members.example')['igneous'], isNull, reason: 'A refused access cookie is dropped so a fresh one is handed out');
      expect(SiteAccount.cookies('members.example')['ipb_member_id'], '7');
      expect(SiteAccount.savedCookieNames('members.example'), ['ipb_member_id', 'ipb_pass_hash']);
      SiteAccount.storeResponse(Uri.parse('https://members.example/'), ['__utmp=tracked; path=/', 'sk=settings; path=/']);
      expect(SiteAccount.cookies('members.example')['__utmp'], isNull, reason: 'The tracking cookie is never sent back');
      expect(SiteAccount.cookies('members.example')['sk'], 'settings');
    });

    test('access the wall hands out is kept and refused access is dropped', () async {
      _resolveKeyed(preferences, 'members.example');
      expect(SiteAccount.signInPasted(SiteAccount.parseCookies('ipb_member_id=7; ipb_pass_hash=$_hash; igneous=refused001'), host: 'members.example'), isTrue);
      const wall = '<html><body><img src="https://members.example/img/kokomade.jpg"></body></html>';
      // The wall answers a request whose access was refused, and hands out new access with it.
      var handsOut = true;
      final transport = ContentTransport(
        fetcher: FixtureFetcher(
          (_) => FixtureReply.text(200, wall, {'Content-Type': 'text/html', if (handsOut) 'Set-Cookie': 'igneous=fresh00001; path=/; domain=.members.example'}),
        ),
      );
      final source = MangaContentSource(transport: transport);
      await expectLater(source.list(const GalleryQuery(language: 'all'), offset: 0, count: 5), throwsA(ContentError.signInRequired));
      expect(SiteAccount.cookies('members.example')['igneous'], 'fresh00001', reason: 'Access the wall just handed out is kept for the next request');
      handsOut = false;
      await expectLater(source.list(const GalleryQuery(language: 'all'), offset: 0, count: 5), throwsA(ContentError.signInRequired));
      expect(SiteAccount.cookies('members.example')['igneous'], isNull, reason: 'Access the site refused is dropped so a fresh one is handed out');
      expect(SiteAccount.cookies('members.example')['ipb_member_id'], '7');
    });

    test('the no-access mark and bot check cookies are never sent back', () {
      _resolveKeyed(preferences, 'members.example');
      final pasted = SiteAccount.parseCookies('ipb_member_id=7; ipb_pass_hash=$_hash; yay=louder; sk=abc123');
      expect(pasted.site, {'sk': 'abc123'}, reason: 'The mark a visit without access leaves is not part of the account');
      expect(SiteAccount.signInPasted(pasted, host: 'members.example'), isTrue);
      SiteAccount.storeResponse(Uri.parse('https://members.example/'), ['yay=louder; path=/', '__cf_bm=bot; path=/', 'star=1-2; path=/']);
      final sent = SiteAccount.cookies('members.example');
      expect(sent['yay'], isNull);
      expect(sent['__cf_bm'], isNull, reason: "A bot check's cookie travels only with the browser that earned it");
      expect(sent['star'], '1-2');
      expect(sent['sk'], 'abc123');
    });

    test('a members-only site asks for an account and opens once signed in', () async {
      preferences.set('manga.site_address', 'members.example');
      const listing =
          '<html><body><form><input name="f_search"></form><div class="searchnav"></div><a href="https://members.example/g/3000/0000000bb8/">Work</a></body></html>';
      final fetcher = FixtureFetcher((request) {
        final signedIn = request.headers['cookie']?.contains('ipb_member_id=7') ?? false;
        if (request.url.path == '/' && signedIn) return FixtureReply.text(200, listing, {'Content-Type': 'text/html'});
        return FixtureReply(200, List.filled(512, 0x47), {'Content-Type': 'image/gif'});
      });
      final transport = ContentTransport(fetcher: fetcher);
      await MangaUrls.resolveBackend(transport: transport, force: true);
      expect(MangaUrls.requiresSignIn, isTrue, reason: 'A homepage that only shows a picture belongs to a members-only site');
      await expectLater(
        MangaContentSource(transport: transport).list(const GalleryQuery(language: 'all'), offset: 0, count: 5),
        throwsA(ContentError.signInRequired),
      );

      expect(SiteAccount.signInPasted(SiteAccount.parseCookies('ipb_member_id=7; ipb_pass_hash=$_hash'), host: 'members.example'), isTrue);
      MangaUrls.resetResolvedBackend();
      MangaUrls.markUsesAccount(site: MangaUrls.home);
      await MangaUrls.resolveBackend(transport: transport, force: true);
      expect(MangaUrls.backend, MangaBackend.keyed);
      expect(MangaUrls.hasResolvedBackend, isTrue);
    });
  });

  group('bot checks', () {
    test('bot check responses are recognized', () {
      ContentResponse response(int status, Map<String, List<String>> headers) =>
          ContentResponse(url: Uri.parse('https://checked.example/'), statusCode: status, headers: headers);
      expect(
        ContentTransport.isBotCheck(
          response(403, {
            'cf-mitigated': ['challenge'],
          }),
        ),
        isTrue,
      );
      expect(
        ContentTransport.isBotCheck(
          response(503, {
            'Server': ['cloudflare'],
            'Content-Type': ['text/html; charset=UTF-8'],
          }),
        ),
        isTrue,
      );
      expect(
        ContentTransport.isBotCheck(
          response(404, {
            'Server': ['cloudflare'],
            'Content-Type': ['text/html'],
          }),
        ),
        isFalse,
      );
      expect(
        ContentTransport.isBotCheck(
          response(403, {
            'Server': ['nginx'],
            'Content-Type': ['text/html'],
          }),
        ),
        isFalse,
      );
      expect(
        ContentTransport.isBotCheck(
          response(503, {
            'Server': ['cloudflare'],
            'Content-Type': ['image/webp'],
          }),
        ),
        isFalse,
      );
    });

    test('a stopped first look asks for the check and a passed check travels with its browser', () async {
      preferences.set('manga.site_address', 'checked.example');
      final fetcher = FixtureFetcher((request) {
        if (request.headers['cookie']?.contains('cf_clearance=passed') ?? false) return FixtureReply(404, const [], {'Content-Type': 'text/html'});
        return FixtureReply.text(403, '<title>Just a moment...</title>', {'cf-mitigated': 'challenge', 'Content-Type': 'text/html'});
      });
      final transport = ContentTransport(fetcher: fetcher);
      await expectLater(MangaContentSource(transport: transport).gallery(3000), throwsA(ContentError.verificationRequired));
      expect(ContentTransport.challengedPage('checked.example')?.host, 'checked.example');

      const clearance = SiteCookie(name: 'cf_clearance', value: 'passed');
      const unrelated = SiteCookie(name: 'session', value: 'x');
      expect(SiteClearance.save([unrelated], userAgent: 'Agent/1', host: 'checked.example'), isFalse);
      expect(SiteClearance.save([clearance, unrelated], userAgent: 'Agent/1', host: 'www.checked.example'), isTrue);
      final entry = SiteClearance.entry('api.checked.example')!;
      expect(entry.cookies, {'cf_clearance': 'passed'});
      expect(ContentTransport.cookieHeader(account: 'nw=1', clearance: entry), 'nw=1; cf_clearance=passed');

      await expectLater(transport.get(Uri.parse('https://checked.example/common.js'), limit: 1000), throwsA(const ContentError.unavailable(404)));
      final sent = fetcher.requests.last;
      expect(sent.headers['user-agent'], 'Agent/1', reason: 'A passed check counts only with the browser that passed it');
      expect(sent.headers['cookie'], contains('cf_clearance=passed'));
    });

    test('check and sign-in pages allow only secure pages and the frames a check draws', () {
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('https://checked.example/login')), isTrue);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('http://checked.example/')), isFalse);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('https://user:pass@checked.example/')), isFalse);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('about:srcdoc')), isFalse);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('about:srcdoc'), mainFrame: false), isTrue);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('blob:https://checked.example/abc'), mainFrame: false), isTrue);
      expect(SiteAccountActions.allowsSignInNavigation(Uri.parse('javascript:alert(1)'), mainFrame: false), isFalse);
    });
  });

  test('notices served in place of an image are never kept as pages', () {
    final page = Uri.parse('https://node.example/h/1.webp');
    expect(KeyedCatalogSource.imageNotice(List.filled(64, 1), url: Uri.parse('https://node.example/img/509.gif')), ContentError.imageLimit);
    // The notices are recognized by their digest (checked against copies of both), never by size alone.
    expect(KeyedCatalogSource.imageNotice(List.filled(28658, 1), url: page), isNull);
    expect(KeyedCatalogSource.imageNotice(List.filled(144844, 1), url: page), isNull);
    expect(KeyedCatalogSource.imageNotice(List.filled(64, 1), url: page), isNull);
  });

  test('a stale page key is not a sign-in wall', () {
    expect(
      KeyedCatalogSource.pageError('Keep trying.'),
      ContentError.galleryNotFound,
      reason: 'A page link whose key no longer matches is answered in two words, which says nothing about the account',
    );
    expect(KeyedCatalogSource.pageError('Short.'), ContentError.signInRequired, reason: 'Other near-empty pages still read as the members-only wall');
  });

  test('pages that say no instead of showing works', () {
    final filler = 'x' * 200;
    expect(
      KeyedCatalogSource.pageError('Your IP address has been temporarily banned for excessive pageloads. The ban expires in 59 minutes'),
      ContentError.temporarilyBlocked,
    );
    expect(KeyedCatalogSource.pageError('<html>$filler<img src="https://media.example/img/kokomade.jpg"></html>'), ContentError.signInRequired);
    expect(KeyedCatalogSource.pageError('<p>You have exceeded your image viewing limits.</p>$filler'), ContentError.imageLimit);
    expect(KeyedCatalogSource.pageError(''), ContentError.signInRequired);
    expect(KeyedCatalogSource.pageError('<html><body>$filler</body></html>'), isNull);
    expect(KeyedCatalogSource.pageError('Key missing, or incorrect key provided.'), ContentError.galleryNotFound, reason: 'A wrong key is not a sign-in wall');
    expect(KeyedCatalogSource.pageError('Invalid page.'), ContentError.galleryNotFound);
    final listing = '<html>${'<tr>work</tr>' * 1000}<a>Temporarily Banned Again</a></html>';
    expect(KeyedCatalogSource.pageError(listing), isNull, reason: 'A title on a full listing is not a notice');
    expect(ContentError.allowsOtherSite(ContentError.galleryNotFound), isTrue);
    expect(ContentError.allowsOtherSite(const ContentError.unavailable(404)), isTrue);
    expect(ContentError.allowsOtherSite(const NetworkError(NetworkErrorCode.cannotFindHost)), isTrue);
    expect(ContentError.allowsOtherSite(ContentError.invalidQuery), isFalse);
    expect(ContentError.allowsOtherSite(const NetworkError(NetworkErrorCode.notConnectedToInternet)), isFalse);
    expect(ContentError.allowsOtherSite(const CancellationError()), isFalse);
  });

  group('other connected websites', () {
    test('a work missing on the checked website opens elsewhere and goes there first next time', () async {
      final memory = WorkSiteMemory();
      final active = _FakeSite('a.example', {1: 'one'});
      final mirror = _FakeSite('b.example', {1: 'one', 2: 'two'});
      final third = _FakeSite('c.example', {3: 'three'});
      final sources = {'b.example': mirror, 'c.example': third};
      final content = SiteFallbackContent(
        primary: active,
        sourceFor: (site) => sources[site]!,
        sites: () => ('a.example', ['a.example', 'b.example', 'c.example']),
        memory: memory,
      );

      expect((await content.gallery(1)).title, 'one');
      expect(memory.site(1), isNull, reason: 'A work the checked website still has needs no detour');
      expect(content.servingSite(1), isNull);

      expect((await content.gallery(2)).title, 'two');
      expect(memory.site(2), 'b.example');
      expect(content.servingSite(2), 'b.example');
      expect(content.candidates(2).first, 'b.example');
      final before = active.calls;
      await content.gallery(2);
      expect(active.calls, before, reason: 'Once remembered, the checked website is not asked again first');

      final image = await content.image(
        const GalleryPage(hash: 'h', name: '1', width: 1, height: 1, hasAVIF: false, index: 0, sourceSite: 'https://b.example/'),
        galleryID: 2,
        thumbnail: true,
      );
      expect(utf8.decode(image), 'b.example', reason: 'Pages load from the website their work was read from');

      content.prefer('c.example', 3);
      expect(content.candidates(3), ['a.example', 'c.example', 'b.example']);
      expect((await content.gallery(3)).title, 'three');
      await expectLater(content.gallery(9), throwsA(ContentError.galleryNotFound));
      memory.forget('b.example');
      expect(memory.site(2), isNull);
    });

    test('a fill reads a blocking website only for works the others no longer have', () async {
      final blocking = _FakeSite('keyed.example', {1: 'one', 3: 'three'});
      final mirror = _FakeSite('b.example', {1: 'one', 2: 'two'});
      SiteFallbackContent fallback(ContentProviding other, List<String> all) => SiteFallbackContent(
        primary: blocking,
        sourceFor: (_) => other,
        sites: () => ('keyed.example', all),
        memory: WorkSiteMemory(),
        blocksBulkReading: (site) => site == 'keyed.example',
      );
      final content = fallback(mirror, ['keyed.example', 'b.example']);

      expect((await content.gallery(1, preferring: 'keyed.example', inBulk: true)).title, 'one');
      expect(blocking.calls, 0, reason: 'A work another website has is never read from the one that blocks bulk reading');
      expect(content.tookBlockingRead(1), isFalse);

      expect((await content.gallery(3, preferring: 'b.example', inBulk: true)).title, 'three', reason: 'A work the other websites deleted is read there');
      expect(blocking.calls, 1);
      expect(content.tookBlockingRead(3), isTrue, reason: 'So the next read waits longer');
      expect(content.tookBlockingRead(3), isFalse);
      await expectLater(content.gallery(9, inBulk: true), throwsA(ContentError.galleryNotFound), reason: 'A work no website has stays missing');

      final cut = fallback(_FakeSite('b.example', {}, refusal: ContentError.unavailable(503)), ['keyed.example', 'b.example']);
      final before = blocking.calls;
      await expectLater(cut.gallery(3, inBulk: true), throwsA(isA<LeftForBlockingSite>()), reason: 'A work the others could not be asked about waits');
      expect(blocking.calls, before);
      expect((await cut.gallery(3)).title, 'three', reason: 'Opening a work by hand still reads every website');

      final alone = fallback(mirror, ['keyed.example']);
      expect((await alone.gallery(1, inBulk: true)).title, 'one', reason: 'With no other website, the fill reads it (after asking, and slowly)');
      expect(alone.tookBlockingRead(1), isTrue);
    });

    test('the fill reads deleted works from a blocking website and leaves unreachable ones for later', () async {
      final db = AppDatabase.inMemory();
      final root = Directory.systemTemp.createTempSync('bulk-fill');
      addTearDown(() => root.deleteSync(recursive: true));
      final blocking = _FakeSite('keyed.example', {7: 'seven', 8: 'eight'});
      SiteFallbackContent fallback(ContentProviding other) => SiteFallbackContent(
        primary: other,
        sourceFor: (_) => blocking,
        sites: () => ('b.example', ['keyed.example', 'b.example']),
        memory: WorkSiteMemory(),
        blocksBulkReading: (site) => site == 'keyed.example',
      );
      CoverQueueActor actor(ContentProviding source) =>
          CoverQueueActor(database: db, thumbsDir: root, source: source, allowsBackfill: () => true, delay: Duration.zero, slowDelay: Duration.zero);

      db.upsertWork(galleryId: 7, site: 'b.example');
      await actor(fallback(_FakeSite('b.example', {}))).start(CoverQueueState());
      expect(blocking.calls, 1);
      expect(db.getWork(7)!.title, 'seven', reason: 'Deleted on the other website, read from the one that still has it');

      final unreachable = _FakeSite('b.example', {}, refusal: ContentError.unavailable(503));
      db.upsertWork(galleryId: 8, site: 'b.example');
      db.setThumb(7, 'gone');
      final state = CoverQueueState();
      await actor(fallback(unreachable)).start(state);
      expect(blocking.calls, 1, reason: 'An unreachable website is not a deleted work');
      expect((state.failed, state.gone), (1, 0));
      expect(db.getWork(8)!.thumbStatus, 'failed', reason: 'Tried again on a later fill');

      await actor(fallback(unreachable)).start(CoverQueueState(), mayRead: () => false);
      expect(unreachable.calls, 1, reason: 'A run that must ask first reads nothing');
    });

    test('reading from a blocking website waits longer between works', () async {
      final db = AppDatabase.inMemory();
      final root = Directory.systemTemp.createTempSync('bulk-fill');
      addTearDown(() => root.deleteSync(recursive: true));
      // Work 2 is missing: an unanswered read waits as long as an answered one.
      final blocking = _FakeSite('keyed.example', {1: 'one'});
      final content = SiteFallbackContent(
        primary: blocking,
        sourceFor: (_) => blocking,
        sites: () => ('keyed.example', ['keyed.example']),
        memory: WorkSiteMemory(),
        blocksBulkReading: (site) => site == 'keyed.example',
      );
      for (final id in [1, 2]) {
        db.upsertWork(galleryId: id, site: 'keyed.example');
      }
      final clock = Stopwatch()..start();
      await CoverQueueActor(
        database: db,
        thumbsDir: root,
        source: content,
        allowsBackfill: () => true,
        delay: Duration.zero,
        slowDelay: const Duration(milliseconds: 300),
      ).start(CoverQueueState());
      expect(clock.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 600)));
      expect(blocking.calls, 2);
    });

    test('a website that stops answering this device ends the fill', () async {
      final db = AppDatabase.inMemory();
      final root = Directory.systemTemp.createTempSync('bulk-fill');
      addTearDown(() => root.deleteSync(recursive: true));
      final blocking = _FakeSite('keyed.example', {}, refusal: ContentError.temporarilyBlocked);
      final content = SiteFallbackContent(
        primary: blocking,
        sourceFor: (_) => blocking,
        sites: () => ('keyed.example', ['keyed.example']),
        memory: WorkSiteMemory(),
        blocksBulkReading: (site) => site == 'keyed.example',
      );
      for (var id = 1; id <= 5; id++) {
        db.upsertWork(galleryId: id, site: 'keyed.example');
      }
      final state = CoverQueueState();
      await CoverQueueActor(
        database: db,
        thumbsDir: root,
        source: content,
        allowsBackfill: () => true,
        delay: Duration.zero,
        slowDelay: Duration.zero,
      ).start(state);
      expect(blocking.calls, 1, reason: 'Reading on would only keep the device blocked for longer');
      expect(state.failed, 1);
      expect(state.error, ContentError.temporarilyBlocked.errorDescription);
    });

    test('filling from only blocking websites asks first and remembers the answer', () {
      final defaults = MemoryPreferences();
      bool blocks(String site) => site.startsWith('keyed');
      CoverFillOutcome outcome(List<String> sites, int pending, {bool manual = false}) =>
          CoverFillGuard.outcome(sites: sites, blocks: blocks, pending: () => pending, manual: manual, defaults: defaults);
      expect(CoverFillGuard.blocksBulkReadingWith('keyed.example', MangaBackend.keyed), isTrue);
      expect(CoverFillGuard.blocksBulkReadingWith('indexed.example', MangaBackend.indexed), isFalse);
      expect(CoverFillGuard.blocksBulkReadingWith('indexed.example', null), isFalse);
      expect(CoverFillGuard.skipped(['keyed.example', 'b.example'], blocks: blocks), {'keyed.example'});
      expect(CoverFillGuard.skipped(['keyed.example'], blocks: blocks), isEmpty, reason: 'Nothing is skipped when nothing else can be read');

      expect(outcome([], 500), const CoverFillRun());
      expect(outcome(['keyed.example', 'b.example'], 500), const CoverFillRun(), reason: 'Another website is read instead');
      expect(outcome(['keyed.example'], CoverFillGuard.quietLimit), const CoverFillRun(), reason: 'A few new saves are read without asking');
      expect(outcome(['keyed.example'], 50), const CoverFillAsk(50, ['keyed.example']));

      CoverFillGuard.record(CoverFillDecision.declined, 50, defaults);
      expect(outcome(['keyed.example'], 50), const CoverFillHold());
      expect(outcome(['keyed.example'], 55), const CoverFillHold());
      expect(outcome(['keyed.example'], 50, manual: true), const CoverFillAsk(50, ['keyed.example']), reason: 'The fill button asks again');
      expect(outcome(['keyed.example'], 61), const CoverFillAsk(61, ['keyed.example']), reason: 'An import asks again');

      CoverFillGuard.record(CoverFillDecision.approved, 61, defaults);
      expect(outcome(['keyed.example'], 61), const CoverFillRun());
      expect(outcome(['keyed.example'], 20), const CoverFillRun());
      expect(CoverFillGuard.decision(defaults).$2, 20, reason: 'Filled works lower the mark');
      expect(outcome(['keyed.example'], 30), const CoverFillRun());
      expect(outcome(['keyed.example'], 31), const CoverFillAsk(31, ['keyed.example']), reason: 'Works saved since are asked about');

      CoverFillGuard.forget(defaults);
      expect(CoverFillGuard.decision(defaults).$1, CoverFillDecision.none);
    });

    test('the fill driver asks the app before reading many works from a blocking website', () async {
      final db = AppDatabase.inMemory();
      final root = Directory.systemTemp.createTempSync('bulk-fill');
      addTearDown(() => root.deleteSync(recursive: true));
      final blocking = _FakeSite('keyed.example', {});
      final content = SiteFallbackContent(
        primary: blocking,
        sourceFor: (_) => blocking,
        sites: () => ('keyed.example', ['keyed.example']),
        memory: WorkSiteMemory(),
        blocksBulkReading: (site) => site == 'keyed.example',
      );
      for (var id = 1; id <= 20; id++) {
        db.upsertWork(galleryId: id, site: 'keyed.example');
      }
      final queue = CoverQueue.withActor(
        CoverQueueActor(database: db, thumbsDir: root, source: content, allowsBackfill: () => true, delay: Duration.zero, slowDelay: Duration.zero),
        allowsBackfill: () => true,
        sites: () => ['keyed.example'],
        blocksBulkReading: (site) => site == 'keyed.example',
        decisions: MemoryPreferences(),
      );
      final asked = <(int, List<String>)>[];
      queue.askBeforeBulkFill = (pending, sites) => asked.add((pending, sites));

      queue.start();
      expect(queue.running, isNull);
      expect(asked.single.$1, 20);
      expect(asked.single.$2, ['keyed.example']);
      queue.start();
      expect(asked, hasLength(1), reason: 'One question at a time');

      queue.answerBulkFill(CoverFillDecision.declined, 20);
      queue.start();
      expect(queue.running, isNull, reason: 'Not now holds automatic fills');
      expect(asked, hasLength(1));
      queue.toggle();
      expect(asked, hasLength(2), reason: 'The fill button asks again');

      queue.answerBulkFill(CoverFillDecision.approved, 20);
      await queue.running;
      expect(blocking.calls, 20);
    });

    test('work sites are kept across launches', () async {
      final directory = Directory.systemTemp.createTempSync('work-sites');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/work-sites.json');
      final memory = WorkSiteMemory(file: file, limit: 3);
      for (var id = 1; id <= 4; id++) {
        memory.remember(id, 'b.example');
      }
      expect(memory.site(1), isNull, reason: 'The oldest entries make room for new ones');
      expect(memory.site(4), 'b.example');
      memory.remember(4, null);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final reloaded = WorkSiteMemory(file: file, limit: 3);
      expect(reloaded.site(3), 'b.example');
      expect(reloaded.site(4), isNull);
    });
  });

  group('work pages', () {
    test('rating, stats, favorite and comments', () {
      final extras = KeyedWorkPage.extras(_workPage);
      expect(extras.rating, 4.65);
      expect(extras.ratingCount, 321);
      expect(extras.favorited, 1234);
      expect(extras.fileSize, '45.67 MiB');
      expect(extras.length, 24);
      expect(extras.parentID, 2999);
      expect(extras.uploader, 'someone');
      expect(extras.posted, DateTime.utc(2024, 3, 5, 10, 20));
      expect(extras.favoriteCategory, 2);
      expect(extras.favoriteName, 'Reading');
      expect(extras.torrentCount, 2);
      expect(extras.torrentsURL?.query, 'gid=3000&t=0000000bb8');
      expect(extras.hasMoreComments, isTrue);
      expect(extras.canRate, isTrue);
      expect(KeyedWorkPage.apiKey(_workPage), const WorkAPIKey(1234567, '0123456789abcdef'));
      expect(extras.comments, hasLength(2));
      final note = extras.comments.first;
      expect(note.isUploader, isTrue);
      expect(note.score, isNull);
      expect(note.text, 'Thanks for reading\nPart 2 soon');
      final comment = extras.comments[1];
      expect(comment.author, 'reader');
      expect(comment.score, 15);
      expect(comment.text, 'Great & fun');
      expect(comment.posted, DateTime.utc(2024, 3, 6, 11));
      expect(WorkExtrasSection.preview([comment, note]).first.id, 0, reason: "The uploader's note leads the preview");

      final unrated = KeyedWorkPage.extras('<td id="rating_label" colspan="3">Not Yet Rated</td><a id="favoritelink" href="#">Add to Favorites</a>');
      expect(unrated.rating, isNull);
      expect(unrated.favoriteCategory, isNull);
      expect(unrated.canRate, isFalse);
    });

    test('torrents, favorites categories and image allowance', () {
      final torrents = KeyedWorkPage.torrents(_torrentPage);
      expect(torrents, hasLength(1));
      final torrent = torrents.single;
      expect(torrent.name, 'Sample Work.zip');
      expect(torrent.size, '45.6 MiB');
      expect(torrent.seeds, 3);
      expect(torrent.peers, 1);
      expect(torrent.downloads, 120);
      expect(torrent.posted, '2024-03-05 12:00');
      expect(torrent.uploader, 'seeder');
      expect(torrent.magnet.toString(), startsWith('magnet:?xt=urn%3Abtih%3A0123456789abcdef0123456789abcdef01234567'));

      final categories = KeyedCatalogSource.favoriteCategoriesIn(_favoritesPage);
      expect([for (final category in categories) category.id], [0, 1, 9]);
      expect([for (final category in categories) category.name], ['Favorites 0', 'Reading', 'Later']);
      expect([for (final category in categories) category.count], [12, 1234, 0]);

      expect(KeyedCatalogSource.imageAllowanceIn('<p>You are currently at <strong>1,234</strong> towards a limit of <strong>5,000</strong>.</p>'), (
        1234,
        5000,
      ));
      expect(KeyedCatalogSource.imageAllowanceIn('<p>Nothing here</p>'), isNull);
    });

    test('rankings the website links to become sorts', () {
      _resolveKeyed(preferences, 'keyed.example');
      expect(GallerySort.available, [GallerySort.latest, GallerySort.today]);
      MangaUrls.noteKeyedNavigation(
        '<a href="https://other.example/toplist.php">Toplists</a><a href="https://keyed.example/watched">Watched</a>',
        site: 'https://keyed.example/',
      );
      expect(MangaUrls.keyedFeatures, {KeyedFeature.watched}, reason: "A toplist on another host is not this website's");
      expect(GallerySort.available, [GallerySort.latest, GallerySort.today], reason: 'Watched tags need a signed-in account');
      expect(SiteAccount.signInPasted(SiteAccount.parseCookies('ipb_member_id=7; ipb_pass_hash=$_hash'), host: 'keyed.example'), isTrue);
      MangaUrls.noteKeyedNavigation('<a href="https://keyed.example/toplist.php">Toplists</a>', site: 'https://keyed.example/');
      expect(GallerySort.available, [GallerySort.latest, GallerySort.today, GallerySort.month, GallerySort.year, GallerySort.allTime, GallerySort.watched]);
      expect(GallerySort.allTime.toplist, 11);
      expect(GallerySort.watched.toplist, isNull);
      preferences.set('manga.site_address', 'indexed.example');
      expect(GallerySort.available, [GallerySort.latest, GallerySort.today, GallerySort.week, GallerySort.month, GallerySort.year]);
    });
  });

  test('one cache size limit holds for every reader', () {
    final directory = Directory.systemTemp.createTempSync('page-cache');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = ThumbnailDiskCache(directory: directory, capacity: 4096, fileExtension: 'page');
    final page = Uint8List.fromList(List.filled(1024, 7));
    cache.write(page, 'a');
    cache.write(page, 'b');
    cache.write(page, 'c');
    expect(cache.usedBytes, 3072);
    cache.capacity = 2048;
    expect(cache.usedBytes, 2048, reason: 'A smaller limit applies at once');
    cache.clear();
    expect(cache.usedBytes, 0);
  });

  test('a members-only catalog lists openly and opens works with its own sign-in', () async {
    preferences.set('manga.site_address', 'private.example');
    final fetcher = FixtureFetcher((request) {
      final signedIn = request.headers['cookie']?.contains('site_session=abc') ?? false;
      switch (request.url.path) {
        case '/':
          return FixtureReply.redirect(Uri.parse('/account/login?redirect=%2F'));
        case '/account/login':
          return FixtureReply.text(200, _memberSignInPage, {'Content-Type': 'text/html'});
        case '/ajax/search':
          return FixtureReply.text(
            200,
            jsonEncode([
              {
                'id': 3000,
                'title': 'Sample',
                'category': 2,
                'views': 10,
                'blocked': 0,
                'thumb_extension': 'jpg',
                'filecount': 13,
                'tags': [
                  {
                    'tag': ['language', 'korean'],
                  },
                ],
              },
            ]),
            {'Content-Type': 'application/json'},
          );
        case '/r/3000':
          if (!signedIn) return FixtureReply.redirect(Uri.parse('/account/login?redirect=%2Fr%2F3000'));
          return FixtureReply.text(200, _memberWork, {'Content-Type': 'text/html'});
      }
      return FixtureReply(404, const [], {'Content-Type': 'text/html'});
    });
    expect(MangaUrls.isDocumentPage(_memberSignInPage), isTrue, reason: 'Its sign-in page names the same catalog');
    final source = MangaContentSource(transport: ContentTransport(fetcher: fetcher));
    final batch = await source.list(const GalleryQuery(language: 'all'), offset: 0, count: 5);
    expect(batch.ids, [3000], reason: 'Lists stay open to everyone');
    expect(MangaUrls.backend, MangaBackend.document);
    expect(MangaUrls.usesSiteSession, isTrue);
    expect(MangaUrls.signInURL?.path, '/account/login');
    expect(source.cachedPreview(3000)?.displayedPageCount, 13, reason: "A list row's page count shows before the work opens");
    expect(SiteAccount.isSignedInAt('private.example'), isFalse);

    await expectLater(source.gallery(3000), throwsA(ContentError.signInRequired));

    expect(
      SiteAccount.signInSession(const [
        SiteCookie(name: 'site_session', value: 'abc'),
        SiteCookie(name: '_ga', value: 'x'),
        SiteCookie(name: 'cf_clearance', value: 'x'),
      ], host: 'private.example'),
      isTrue,
    );
    expect(SiteAccount.isSignedInAt('private.example'), isTrue);
    expect(SiteAccount.isSignedIn, isFalse, reason: 'A site\'s own sign-in is not the forum identity');
    final sent = SiteAccount.cookies('private.example');
    expect(sent['site_session'], 'abc');
    expect(sent['_ga'], isNull);
    expect(sent['cf_clearance'], isNull);

    final work = await source.gallery(3000);
    expect(work.pages, hasLength(2));
    expect(work.displayedPageCount, 2);
    SiteAccount.signOutAt('private.example');
    expect(SiteAccount.isSignedInAt('private.example'), isFalse);
  });

  test('page counts come from lists and stay with saved works', () {
    final preview = NativeGallery(
      id: 1,
      title: '',
      artists: const [],
      language: '',
      type: '',
      tags: const [],
      pages: const [GalleryPage(hash: 'h', name: 'cover', width: 0, height: 0, hasAVIF: false)],
    );
    expect(preview.displayedPageCount, 1);
    expect(preview.copyWith(pageCount: 0).displayedPageCount, isNull, reason: 'A list row that does not say has no count, not one page');
    expect(preview.copyWith(pageCount: 24).displayedPageCount, 24);

    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 42, title: 'Saved', pageCount: 24);
    expect(database.getWork(42)?.pageCount, 24);
    database.upsertWork(galleryId: 42, title: 'Saved');
    expect(database.getWork(42)?.pageCount, 24, reason: 'A save that does not know keeps the count');
    database.fillPageCount(42, 30);
    expect(database.getWork(42)?.pageCount, 30);
    database.fillPageCount(7, 30);
    expect(database.getWork(7), isNull, reason: 'Opening an unsaved work saves nothing');
    expect(ReadingQueueItem.fromGallery(id: 42, pages: database.getWork(42)?.pageCount).pages, 30);
    expect(LibrarySyncAdapter.columns['manga.works'], contains('page_count'));
    expect(LibrarySyncAdapter.keepsKnownValue, contains('page_count'), reason: 'A device that does not know the count never clears it');
  });
}

const _workPage = '''
<div id="gdn"><a href="https://keyed.example/uploader/someone">someone</a></div>
<div id="gdd"><table>
<tr><td class="gdt1">Posted:</td><td class="gdt2">2024-03-05 10:20</td></tr>
<tr><td class="gdt1">Parent:</td><td class="gdt2"><a href="https://keyed.example/g/2999/0000000bb7/">2999</a></td></tr>
<tr><td class="gdt1">Visible:</td><td class="gdt2">Yes</td></tr>
<tr><td class="gdt1">Language:</td><td class="gdt2">Korean &nbsp;</td></tr>
<tr><td class="gdt1">File Size:</td><td class="gdt2">45.67 MiB</td></tr>
<tr><td class="gdt1">Length:</td><td class="gdt2">24 pages</td></tr>
<tr><td class="gdt1">Favorited:</td><td class="gdt2" id="favcount">1,234 times</td></tr>
</table></div>
<div id="gdr"><table><tr><td id="rating_label" colspan="3">Average: 4.65</td></tr>
<tr><td class="grt1">Rating:</td><td><span id="rating_count">321</span></td></tr></table></div>
<div id="gdf"><div id="fav"><div class="i" style="background-image:url(https://media.example/fav.png); background-position:0px -40px; margin-left:16px" title="Reading"></div></div>
<a id="favoritelink" href="#" onclick="return popUp('https://keyed.example/gallerypopups.php?gid=3000&amp;t=0000000bb8&amp;act=addfav',675,415)">Reading</a></div>
<p class="g2 gsp"><a href="#" onclick="return popUp('https://keyed.example/gallerytorrents.php?gid=3000&amp;t=0000000bb8',610,590)">Torrent Download (2)</a></p>
<script>var apiuid = 1234567; var apikey = "0123456789abcdef";</script>
<div id="cdiv" class="gm">
<div class="c1"><div class="c2"><div class="c3">Posted on 05 March 2024, 10:21 by: &nbsp; <a href="https://keyed.example/uploader/someone">someone</a></div><div class="c4 nosel">Uploader Comment</div><div class="c"></div></div><div class="c6" id="comment_0">Thanks for reading<br>Part 2 soon</div></div>
<div class="c1"><div class="c2"><div class="c3">Posted on 06 March 2024, 11:00 by: &nbsp; <a href="https://keyed.example/index.php?showuser=42">reader</a>&nbsp; &nbsp; <a href="https://keyed.example/index.php?act=Msg">[PM]</a></div><div class="c5 nosel">Score <span id="comment_score_123">+15</span></div><div class="c"></div></div><div class="c6" id="comment_123">Great &amp; fun</div></div>
</div>
<div id="chd"><p>There are 12 more comments - <a href="https://keyed.example/g/3000/0000000bb8/?hc=1#comments">click to show all</a>.</p></div>
''';

const _torrentPage = '''
<form method="post" action="https://keyed.example/gallerytorrents.php?gid=3000&amp;t=0000000bb8">
<div><table style="width:99%">
<tr><td style="width:190px"><span style="font-weight:bold">Posted:</span> <span>2024-03-05 12:00</span></td><td><span style="font-weight:bold">Size:</span> 45.6 MiB</td><td><span style="font-weight:bold">Seeds:</span> 3</td><td><span style="font-weight:bold">Peers:</span> 1</td><td><span style="font-weight:bold">Downloads:</span> 120</td></tr>
<tr><td colspan="5"><span style="font-weight:bold">Uploader:</span> seeder</td></tr>
<tr><td colspan="5"> &nbsp; <a href="https://tracker.example/get/3000/0123456789abcdef0123456789abcdef01234567.torrent?p=x">Sample Work.zip</a></td></tr>
</table></div></form>
''';

const _favoritesPage = '''
<div class="ido"><div class="nosel">
<div class="fp" onclick="document.location='https://keyed.example/favorites.php?favcat=0'"><div>12</div><div class="i" style="background-position:0px -2px" title="Favorites 0"></div><div>Favorites 0</div></div>
<div class="fp fps" onclick="document.location='https://keyed.example/favorites.php?favcat=1'"><div>1,234</div><div class="i" style="background-position:0px -21px" title="Reading"></div><div>Reading</div></div>
<div class="fp" onclick="document.location='https://keyed.example/favorites.php?favcat=9'"><div>0</div><div class="i" style="background-position:0px -173px" title="Later"></div><div>Later</div></div>
<div style="clear:both"></div>
<div class="fp fps" onclick="document.location='https://keyed.example/favorites.php'" style="width:140px">Show All Favorites</div>
</div></div>
''';

const _memberSignInPage = r'''
<html><head><title>Login</title>
<script>const serverConfig = { test: false, isSecretHost: true, thumbServer: {"url":"https:\/\/thumbs.private.example"} };</script>
<script src="/js/index.head.js?1"></script></head>
<body><form id="loginForm" method="post" action="/ajax/account-login">
<input type="hidden" name="csrf" value="x"><input type="text" name="username"><input type="password" name="password">
<div class="cf-turnstile" data-sitekey="x"></div><button type="submit">Login</button></form></body></html>
''';

const _memberWork = '''
<html><head><script>
const gallery = {"id":3000,"title":"Sample","title_jpn":null,"category":2,"blocked":0,"tags":[{"tag":["language","korean"]}],
"files":[{"id":"a","name":"1.webp","image":{"url":"https://media.private.example/1.webp","width":10,"height":10}},
         {"id":"b","name":"2.webp","image":{"url":"https://media.private.example/2.webp","width":10,"height":10}}]};
</script></head><body></body></html>
''';
