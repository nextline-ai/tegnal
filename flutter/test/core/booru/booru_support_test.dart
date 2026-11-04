// Ported from native-ios/TEGNALTests/BooruTests.swift, BooruLibraryTests.swift,
// BooruRevisionTests.swift and BooruThumbnailCacheTests.swift: the feed loader, viewer
// navigation, sorting, website recognition, session-only Gold restrictions, library
// snapshots, the browser transport and the image caches.
//
// Not ported: launch warmup tests (the warmup arrives with step 7), AppEnvironment tests,
// WebKit tests, and the thumbnail size checks (the Flutter cache keeps encoded bytes; the
// grid decodes them at its own size).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_browser.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_image_cache.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/booru/booru_support.dart';
import 'package:tegnal/core/booru/booru_thumbnail_disk_cache.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/site_account.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/taste/taste_models.dart';

import '../../support/fixtures.dart';

final a = BooruFixtureEnvironment.servers[0], b = BooruFixtureEnvironment.servers[1], c = BooruFixtureEnvironment.servers[2];
final dan = BooruServer(id: 'test-dan', name: 'Test', baseURL: 'https://example.com/booru', engine: BooruEngine.danbooru);

BooruServer withID(BooruServer server, String id) => BooruServer(id: id, name: server.name, baseURL: server.baseURL, engine: server.engine);

/// A tiny PNG, so caches that check image signatures accept it.
final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='));

void main() {
  group('feed loader', () {
    test('new search retains pagination when the first page matches the previous feed', () async {
      final loader = BooruFeedLoader(), source = BooruFixtureSource(delay: Duration.zero);
      await loader.load(servers: [a], source: source, query: '', reset: true);
      await loader.load(servers: [a], source: source, query: 'scenery', reset: true);
      expect(loader.hasMore, isTrue);
      await loader.load(servers: [a], source: source, query: 'scenery', reset: false);
      expect(loader.posts.map((post) => post.postID), [101, 102, 103]);
      expect(loader.hasMore, isFalse);
    });

    test('feed projection tracks pagination and blacklist edits', () async {
      final loader = BooruFeedLoader(), source = BooruFixtureSource(delay: Duration.zero);
      loader.setBlacklists({a.id: 'id:101'});
      await loader.load(servers: [a], source: source, query: '', reset: true);
      expect(loader.visiblePosts.map((post) => post.id), loader.posts.where((post) => post.postID != 101).map((post) => post.id));
      await loader.load(servers: [a], source: source, query: '', reset: false);
      expect(loader.visiblePosts.map((post) => post.postID), [102, 103]);
      loader.setBlacklists({a.id: 'id:102\nid:103'});
      expect(loader.visiblePosts.map((post) => post.postID), [101]);
      loader.setBlacklists({});
      expect(loader.visiblePosts, loader.posts);
      loader.setExcludedPostIDs({loader.posts.first.id});
      expect(loader.visiblePosts.map((post) => post.postID), [102, 103]);
    });

    test('a stale search cannot replace newer results', () async {
      final loader = BooruFeedLoader(), source = _DelayedSource();
      final old = loader.load(servers: [dan], source: source, query: 'slow', reset: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await loader.load(servers: [dan], source: source, query: 'fast', reset: true);
      await old;
      expect(loader.posts.map((post) => post.postID), [2]);
      expect(loader.loading, isFalse);
    });

    test('gold-only feed page advances and reports restricted IDs', () async {
      final source = _GoldPageSource(), loader = BooruFeedLoader();
      final blocked = <(String, List<int>)>[];
      await loader.load(servers: [dan], source: source, query: '', reset: true, onGoldRestricted: (id, ids) => blocked.add((id, ids)));
      expect(loader.posts, isEmpty);
      expect(loader.hasMore, isTrue);
      expect(blocked.first.$1, dan.id);
      expect(blocked.first.$2, [12403879]);
      await loader.load(servers: [dan], source: source, query: '', reset: false);
      expect(loader.posts.map((post) => post.postID), [101]);
      expect(loader.hasMore, isFalse);
      expect(source.pages, [0, 1]);
    });

    test('a repeating gold-only page stops instead of draining forever', () async {
      final source = _GoldPageSource(repeating: true), loader = BooruFeedLoader();
      await loader.load(servers: [dan], source: source, query: '', reset: true);
      expect(loader.hasMore, isTrue);
      await loader.load(servers: [dan], source: source, query: '', reset: false);
      expect(loader.hasMore, isFalse);
      await loader.load(servers: [dan], source: source, query: '', reset: false);
      expect(source.pages, [0, 1]);
    });

    test('a cancelled partial refresh does not erase previous images', () async {
      final source = _GatedSource(), loader = BooruFeedLoader();
      final fast = withID(dan, 'fast'), slow = withID(dan, 'slow');
      await loader.load(servers: [fast], source: source, query: '', reset: true, contentID: 'previous');
      final previous = loader.posts;
      final task = loader.load(servers: [fast, slow], source: source, query: 'empty', reset: true, contentID: 'cancelled');
      for (var attempt = 0; attempt < 200 && !source.emptyDelivered; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      loader.cancel();
      source.release();
      await task;
      expect(loader.posts, previous);
      expect(loader.contentID, 'previous');
      expect(loader.loading, isFalse);
    });

    test('a fast server publishes before a slow server and keeps pagination', () async {
      final source = _GatedSource(), loader = BooruFeedLoader();
      final fast = withID(dan, 'fast'), slow = withID(dan, 'slow');
      final task = loader.load(servers: [fast, slow], source: source, query: '', reset: true, contentID: 'current');
      for (var attempt = 0; attempt < 200 && loader.posts.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(loader.posts.map((post) => post.serverID), ['fast']);
      expect(loader.loading, isTrue);
      expect(loader.contentID, 'current');
      source.release();
      await task;
      expect(loader.posts.map((post) => post.serverID).toSet(), {'fast', 'slow'});
      expect(loader.loading, isFalse);
      await loader.load(servers: [fast, slow], source: source, query: '', reset: false, contentID: 'current');
      expect(loader.posts.length, 4);
      expect(loader.hasMore, isFalse);
    });

    test('a cancelled refresh preserves posts and an empty query can reload', () async {
      final loader = BooruFeedLoader(), source = _PartialSource();
      await loader.load(servers: [a], source: source, query: '', reset: true);
      expect(loader.posts.map((post) => post.postID), [1]);
      final task = loader.load(servers: [a], source: source, query: 'slow', reset: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(loader.posts.map((post) => post.postID), [1]);
      loader.cancel();
      await task;
      expect(loader.posts.map((post) => post.postID), [1]);
      expect(loader.errors, isEmpty);
      expect(loader.loading, isFalse);
      await loader.load(servers: [a], source: source, query: '', reset: true);
      expect(loader.posts.map((post) => post.postID), [1]);
      expect(loader.didLoad, isTrue);
    });

    test('multi-server pagination keeps working when one server fails', () async {
      final loader = BooruFeedLoader(), source = _PartialSource();
      await loader.load(servers: [a, b], source: source, query: '', reset: true);
      expect(loader.posts.map((post) => post.serverID), [a.id]);
      expect(loader.errors[b.id], isNotNull);
      expect(loader.hasMore, isTrue);
      await loader.load(servers: [a, b], source: source, query: '', reset: false);
      expect(loader.posts.map((post) => post.postID), [1, 2]);
      expect(loader.hasMore, isFalse);
    });

    test('an unsupported sort is reported without replacing the feed', () async {
      final loader = BooruFeedLoader(), source = BooruFixtureSource(delay: Duration.zero);
      await loader.load(servers: [b], source: source, query: '', reset: true);
      final shown = loader.posts;
      await loader.load(servers: [b], source: source, query: '', sort: BooruSort.mostFavorited, reset: true);
      expect(loader.unsupportedSort, isTrue);
      expect(loader.posts, shown);
    });
  });

  test('viewer return uses the last loaded post without jumping on an unchanged or removed post', () {
    final initial = ['first:101', 'first:102', 'second:101'];
    expect(BooruViewerReturn.targetID(openedID: 'first:101', viewedID: 'first:101', availableIDs: initial), isNull);
    expect(BooruViewerReturn.targetID(openedID: null, viewedID: 'first:102', availableIDs: initial), isNull);
    expect(BooruViewerReturn.targetID(openedID: 'first:101', viewedID: 'second:101', availableIDs: initial), 'second:101');
    final paginated = [...initial, 'second:102', 'second:103'];
    expect(BooruViewerReturn.targetID(openedID: 'first:101', viewedID: 'second:103', availableIDs: paginated), 'second:103');
    expect(BooruViewerReturn.targetID(openedID: 'first:101', viewedID: 'second:103', availableIDs: initial), isNull);
  });

  test('viewer access navigation skips restricted posts, loads more, then closes', () {
    final ids = ['s:1', 's:2', 's:3'];
    final navigation = BooruViewerAccessNavigation(removedIDs: {'s:2'});
    navigation.moved(1);
    expect(navigation.destination(ids, current: 0, canLoadMore: false, excluding: {}), const BooruViewerPost(2));
    navigation.restrict('s:3');
    expect(navigation.destination(ids, current: 2, canLoadMore: true, excluding: {}), const BooruViewerLoadMore());
    expect(navigation.destination(ids, current: 2, canLoadMore: true, excluding: {}), const BooruViewerPost(0));
    expect(navigation.destination(['s:2', 's:3'], current: 1, canLoadMore: false, excluding: {}), const BooruViewerClose());
    final opened = BooruViewerAccessNavigation();
    expect(opened.removed('s:1'), isFalse, reason: 'A post opened directly shows its removal page');
    opened.moved(-1);
    expect(opened.removed('s:2'), isTrue);
    expect(opened.pendingID, 's:2');
    expect(opened.direction, -1);
    final pagination = BooruViewerPagination()..isActive = true;
    pagination.requestAdvance('s:3');
    expect(pagination.beginRequest(), isTrue);
    expect(pagination.beginRequest(), isFalse);
    expect(pagination.takeAdvance(currentID: 's:3', nextExists: false), isFalse);
    expect(pagination.wantsNext, isTrue, reason: 'A pending load keeps the request');
    pagination.finishRequest();
    expect(pagination.takeAdvance(currentID: 's:3', nextExists: true), isTrue);
    expect(pagination.wantsNext, isFalse);
    expect(BooruFailureNavigation.swipe(-80, 10), 1);
    expect(BooruFailureNavigation.swipe(80, 10), -1);
    expect(BooruFailureNavigation.swipe(60, 50), isNull);
  });

  test('popular sort uses each engine syntax and retains user tags', () {
    expect(BooruSort.popular.query('scenery -spoilers', BooruEngine.danbooru), 'scenery -spoilers order:score');
    expect(BooruSort.popular.query('scenery order:id', BooruEngine.gelbooru), 'scenery sort:score:desc');
    expect(BooruSort.popular.query('scenery', BooruEngine.oldGelbooru), 'scenery order:score');
    expect(BooruSort.latest.query('scenery order:id', BooruEngine.moebooru), 'scenery order:id');
  });

  test('popularity capabilities and exact server operators', () {
    for (final (sort, token) in [
      (BooruSort.popular, 'score'),
      (BooruSort.trending, 'rank'),
      (BooruSort.mostFavorited, 'favcount'),
      (BooruSort.mostUpvoted, 'upvotes'),
      (BooruSort.mostDiscussed, 'comment_count'),
    ]) {
      expect(sort.query('scenery -rain sort:random order:id', BooruEngine.danbooru), 'scenery -rain order:$token');
    }
    expect(BooruSort.optionsFor(BooruEngine.gelbooru), [BooruSort.latest, BooruSort.popular]);
    expect(BooruSort.popular.query('scenery SORT:random ORDER:id', BooruEngine.gelbooru), 'scenery sort:score:desc');
    expect(BooruSort.mostFavorited.query('scenery', BooruEngine.gelbooru), 'scenery');
    expect(BooruSort.options([a, b]), [BooruSort.latest, BooruSort.popular]);
    expect(BooruSort.options([a], local: true), [BooruSort.latest, BooruSort.popular]);
  });

  test('popularity date ranges and metric persistence', () {
    final now = DateTime.utc(2026, 10, 10, 12);
    expect(BooruSort.popularWeek.query('scenery', BooruEngine.danbooru, now: now), 'scenery date:>=2026-10-03 order:score');
    expect(BooruSort.popularMonth.query('scenery', BooruEngine.moebooru, now: now), 'scenery date:>=2026-09-10 order:score');
    expect(BooruSort.popularWeek.query('scenery date:>=2026-10-09', BooruEngine.danbooru, now: now), 'scenery date:>=2026-10-09 order:score');
    final post = BooruFixtureSource.post(1, a, tags: ['scenery'])
      ..favoriteCount = 12
      ..upvoteCount = 15
      ..commentCount = 3;
    final restored = BooruPost.fromJson(post.toJson()).onServer('copy');
    expect(BooruSort.mostFavorited.metric(restored), 12);
    expect(BooruSort.mostUpvoted.metric(restored), 15);
    expect(BooruSort.mostDiscussed.metric(restored), 3);
    expect(BooruSort.trending.metric(restored), isNull);
  });

  test('safe rating defaults never override an explicit rating', () {
    for (final rating in BooruSafeRating.values) {
      expect(rating.applyingDefault(''), rating.tag);
      expect(rating.applyingDefault('scenery -spoilers'), 'scenery -spoilers ${rating.tag}');
      expect(rating.applyingDefault('scenery rating:q'), 'scenery rating:q');
      expect(rating.applyingDefault('-rating:e scenery'), '-rating:e scenery');
      expect(rating.applyingDefault(rating.applyingDefault('scenery')), 'scenery ${rating.tag}');
    }
    expect(BooruSafeRating.questionable.title, '15+');
    expect(Uri.parse(a.browsingURL('rating:q')).queryParameters['tags'], 'rating:q');
  });

  test('website responses are recognized by structure and software signature', () {
    expect(ServerType.recognizing('<script src="/js/index.search.tail.js"></script>'), ServerType.comics);
    expect(ServerType.recognizing('<script src="https://ltn.files.example/common.js"></script>'), ServerType.comics);
    expect(ServerType.recognizing('const gallery = {"id":1234,"files":[]};'), ServerType.comics);
    expect(ServerType.recognizing('Danbooru.Post.initialize();'), ServerType.booru(BooruEngine.danbooru));
    expect(ServerType.recognizing('Running Gelbooru Beta 0.1.11'), ServerType.booru(BooruEngine.oldGelbooru));
    expect(ServerType.recognizing('Moebooru'), ServerType.booru(BooruEngine.moebooru));
    expect(ServerType.recognizing('<html><title>Unknown website</title></html>'), isNull);
    expect(ServerType.recognizing('<script>const gallery = {"images":[]};</script><a href=\'/ajax/search\'>Search</a>'), isNull);
    expect(ServerType.recognizing("<script>const domain = 'analytics.example';</script>"), isNull);
  });

  test('a domain suffix alone does not choose a website mode', () async {
    for (final address in ['https://comics.la', 'https://test.la', 'https://custom.example']) {
      expect(await ServerType.detect(Uri.parse(address), loadHTML: (_) async => '<html>Unrecognized</html>'), isNull);
    }
  });

  test('connection retries exclude authentication, challenges and cancellation', () {
    expect(BooruConnectionRetry.isTransient(const NetworkError(NetworkErrorCode.networkConnectionLost)), isTrue);
    expect(BooruConnectionRetry.isTransient(const NetworkError(NetworkErrorCode.secureConnectionFailed)), isTrue);
    expect(BooruConnectionRetry.isTransient(const NetworkError(NetworkErrorCode.cancelled)), isFalse);
    expect(BooruConnectionRetry.isTransient(const NetworkError(NetworkErrorCode.serverCertificateUntrusted)), isFalse);
    expect(BooruConnectionRetry.isTransient(const BooruError(BooruErrorKind.validationRequired)), isFalse);
    expect(BooruConnectionRetry.isTransient(const BooruError(BooruErrorKind.authentication)), isFalse);
    expect(BooruConnectionMessage.describe(const BooruError(BooruErrorKind.rateLimited)), const BooruError(BooruErrorKind.rateLimited).errorDescription);
    expect(BooruConnectionMessage.describe(const NetworkError(NetworkErrorCode.secureConnectionFailed)), contains('\n\n'));
  });

  group('store', () {
    BooruStore store() => BooruStore.inMemory();

    test('fresh install has no servers', () {
      final value = store();
      expect(value.servers, isEmpty);
      expect(value.selectedServerIDs, isEmpty);
    });

    test('gold restrictions hide the cached library without deleting saved evidence', () {
      final value = store();
      value
        ..saveServer(a)
        ..saveServer(c);
      final folder = value.saveFolder(name: 'Saved');
      final first = BooruFixtureSource.post(12403879, a, tags: ['scenery']);
      final second = BooruFixtureSource.post(12403879, c, tags: ['scenery']);
      value
        ..saveFavorite(first, folderID: folder)
        ..saveFavorite(second, folderID: folder);
      expect(value.visibleFavorites().map((post) => post.id).toSet(), {first.id, second.id});
      expect(value.visibleFavorites(folderID: folder, query: 'scenery').length, 2);
      final savedIDs = value.favoriteIDs, revision = value.revision;
      int evidence() => value.database.read((db) => db.value<int>('SELECT COUNT(*) FROM taste_events') ?? 0);
      final evidenceCount = evidence();
      var changes = 0;
      value.addListener(() => changes += 1);
      value
        ..recordGoldRestriction(first)
        ..recordGoldRestriction(first);
      expect(changes, 1, reason: 'Observers learn of the change once');
      expect(value.isVisible(first), isFalse);
      expect(value.isVisible(second), isTrue);
      expect(value.visibleFavorites().map((post) => post.id), [second.id]);
      expect(value.visibleFavorites(folderID: folder, query: 'scenery').map((post) => post.id), [second.id]);
      expect(value.favoriteIDs, savedIDs);
      expect(value.favoritesOn(a.id).map((post) => post.id), [first.id]);
      expect(value.folderIDFor(first), folder);
      expect(value.revision, revision, reason: 'Skipping an inaccessible post must not invalidate every database snapshot');
      expect(evidence(), evidenceCount);
      value.clearGoldRestrictions(serverID: a.id);
      expect(value.visibleFavorites().map((post) => post.id).toSet(), savedIDs);
    });

    test('gold restrictions are session-only and reset only for the changed server', () {
      final path = '${temporaryDirectory(addTearDown).path}/booru.sqlite';
      final value = BooruStore(path: path, preferences: AppPreferences.memory());
      value
        ..saveServer(a)
        ..saveServer(c)
        ..recordGoldRestrictions(a.id, [0, -1, 42, 42])
        ..recordGoldRestrictions(c.id, [42]);
      expect(value.confirmedGoldRestrictedIDs, {'${a.id}:42', '${c.id}:42'});
      value.refresh();
      expect(value.confirmedGoldRestrictedIDs.length, 2, reason: 'Library refresh and app resumption must not retry already confirmed restrictions');
      expect(BooruStore(path: path, preferences: AppPreferences.memory()).confirmedGoldRestrictedIDs, isEmpty);
      value.saveServer(a);
      expect(value.confirmedGoldRestrictedIDs, {'${c.id}:42'}, reason: 'A credentials save can change access even if the server payload is unchanged');
      value
        ..recordGoldRestrictions('nested:server', [42])
        ..clearGoldRestrictions(serverID: 'nested');
      expect(value.confirmedGoldRestrictedIDs.contains('nested:server:42'), isTrue);
      value.clearGoldRestrictions();
      expect(value.confirmedGoldRestrictedIDs, isEmpty);
    });

    test('library snapshots track favorite moves, filters and direct sync writes', () {
      final value = store()..saveServer(a);
      final folder = value.saveFolder(name: 'Saved'), other = value.saveFolder(name: 'Other');
      final post = BooruFixtureSource.post(91, a, tags: ['scenery']);
      expect(value.favoriteIDs, isEmpty);
      expect(value.visibleFavorites(), isEmpty);
      value.saveFavorite(post, folderID: folder);
      expect(value.isFavorite(post), isTrue);
      expect(value.visibleFavorites(folderID: folder).map((post) => post.id), [post.id]);
      expect(value.favoriteSavedDates()[post.id], isNotNull);
      value.setBlacklist('scenery', serverID: a.id);
      expect(value.visibleFavorites(), isEmpty);
      value
        ..setBlacklist('', serverID: a.id)
        ..moveFavorites([post], other);
      expect(value.visibleFavorites(folderID: folder), isEmpty);
      expect(value.visibleFavorites(folderID: other).map((post) => post.id), [post.id]);
      final before = value.folders().firstWhere((folder) => folder.id == other);
      final updatedColor = before.color == 0xFF123456 ? 0xFF654321 : 0xFF123456;
      value.database.write((db) {
        db.execute('UPDATE folders SET color = ? WHERE id = ?', [updatedColor, other]);
        db.execute('DELETE FROM favorites');
      });
      value.invalidateSnapshots();
      expect(value.folders().firstWhere((folder) => folder.id == other).color, updatedColor);
      expect(value.favoriteIDs, isEmpty);
      expect(value.visibleFavorites(folderID: other), isEmpty);
    });

    test('server connection saves credentials, rejects half accounts and duplicates, and selects new servers', () {
      final value = store();
      final saved = BooruServerConnection.save(store: value, address: 'images.example/', engine: BooruEngine.gelbooru, account: ' user ', apiKey: ' key ');
      expect(saved.name, 'images.example');
      expect(value.selectedServerIDs, [saved.id]);
      expect(value.credentials.read(saved.id).account, 'user');
      expect(() => BooruServerConnection.save(store: value, address: 'https://images.example', engine: BooruEngine.gelbooru), throwsA(isA<BooruError>()));
      expect(
        () => BooruServerConnection.save(store: value, address: 'other.example', engine: BooruEngine.danbooru, account: 'only'),
        throwsA(isA<BooruError>().having((error) => error.kind, 'kind', BooruErrorKind.authentication)),
      );
      final edited = BooruServerConnection.save(store: value, existing: saved, address: saved.baseURL, engine: BooruEngine.gelbooru, name: 'Mine');
      expect(edited.id, saved.id);
      expect(value.servers.single.name, 'Mine');
      expect(value.credentials.read(saved.id).isEmpty, isTrue);
    });

    test('favorite action reports which way the toggle went and the store warms new saves', () {
      final value = store()..saveServer(a);
      final warmed = <String>[];
      value.warmSavedPreview = (post, server) => warmed.add('${server.id}:${post.postID}');
      final post = BooruFixtureSource.post(5, a);
      expect(BooruFavoriteAction.toggle(post, value, DiscoveryContext.unknown), BooruFavoriteToggle.added);
      expect(BooruFavoriteAction.toggle(post, value, DiscoveryContext.unknown), BooruFavoriteToggle.removed);
      expect(warmed, ['${a.id}:5']);
    });

    test('perform shows a failure instead of throwing', () {
      final value = store()..saveServer(a);
      value.perform(() => value.saveServer(BooruServer(name: 'Again', baseURL: a.baseURL, engine: a.engine)));
      expect(value.error, const BooruError(BooruErrorKind.duplicateServer).errorDescription);
    });

    test('fixture environment seeds neutral servers and selects the first', () {
      final value = store();
      BooruFixtureEnvironment.seed(value);
      expect(value.servers.map((server) => server.name), ['Images A', 'Images B', 'Images C']);
      expect(value.servers.every((server) => Uri.parse(server.baseURL).host.endsWith('.invalid')), isTrue);
      expect(value.selectedServerIDs, [a.id]);
      final restored = store();
      BooruFixtureEnvironment.seed(restored, options: {BooruFixtureOption.restoredBadge});
      expect(restored.selectedServerIDs, isEmpty);
      expect(restored.favoriteIDs, {'${a.id}:${BooruFixtureSource.restoredPostID}', '${b.id}:${BooruFixtureSource.restoredPostID}'});
      final empty = store();
      BooruFixtureEnvironment.seed(empty, options: {BooruFixtureOption.noSites});
      expect(empty.servers, isEmpty);
    });

    test('keystore credentials stay out of the library database', () {
      final secrets = _Secrets();
      final credentials = SecretCredentialStore(secrets);
      credentials.save(const BooruCredentials(account: 'me', apiKey: 'secret'), 'server');
      expect(credentials.read('server').apiKey, 'secret');
      expect(secrets.values.keys, ['booru.credentials.server']);
      credentials.save(const BooruCredentials(), 'server');
      expect(secrets.values, isEmpty);
    });
  });

  group('validation state', () {
    test('a validated page can be adopted only after its check cleared', () {
      final state = BooruValidationState(dan);
      final url = state.load();
      expect(url.toString(), dan.baseURL);
      expect(state.loading, isTrue);
      state.didFinish(Uri.parse('https://example.com/booru/posts'));
      expect(state.canAdoptSession, isFalse, reason: 'The page must be inspected first');
      state.inspected(Uri.parse('https://example.com/booru/posts'), true);
      expect(state.canAdoptSession, isFalse);
      state.monitorTick(DateTime.now().add(const Duration(seconds: 30)));
      expect(state.challengeStalled, isTrue);
      state.inspected(Uri.parse('https://example.com/booru/posts'), false);
      expect(state.challengeStalled, isFalse);
      expect(state.canAdoptSession, isTrue);
      state.inspected(Uri.parse('https://elsewhere.example/'), true);
      expect(state.canAdoptSession, isTrue, reason: 'Another origin is not inspected');
    });

    test('transient failures retry twice, then show the connection message', () {
      final state = BooruValidationState(dan)..load();
      const lost = NetworkError(NetworkErrorCode.networkConnectionLost);
      expect(state.failed(lost), const Duration(milliseconds: 500));
      expect(state.failed(lost), const Duration(milliseconds: 1000));
      expect(state.failed(lost), isNull);
      expect(state.error, BooruConnectionMessage.describe(lost));
      expect(state.failed(const NetworkError(NetworkErrorCode.cancelled)), isNull);
      expect(BooruValidationState.navigation(Uri.parse('https://x.example/'), newWindow: true), BooruNavigationDecision.loadInPlace);
      expect(BooruValidationState.navigation(Uri.parse('http://x.example/'), newWindow: false), BooruNavigationDecision.cancel);
      expect(BooruValidationState.navigation(Uri.parse('about:blank'), newWindow: false), BooruNavigationDecision.allow);
    });
  });

  group('browser transport', () {
    tearDown(() {
      BooruWebTransport.reset(dan);
      BooruWebTransport.factory = null;
    });

    test('a validated page is reused and credentials stay out of a shared script world', () async {
      final page = _FakePage(Uri.parse('https://example.com/booru/'), isolates: false);
      BooruWebTransport.adopt(page, dan);
      expect(BooruWebTransport.hasSession(dan), isTrue);
      final request = BooruRequest(
        Uri.parse('https://example.com/booru/posts.json?login=me&password_hash=secret'),
        headers: {'Authorization': 'Basic x', 'Accept': '*/*'},
      );
      final response = await BooruWebTransport.data(request, dan, publicURL: Uri.parse('https://example.com/booru/posts.json'));
      expect(response.statusCode, 200);
      expect(utf8.decode(response.data), '[]');
      expect(page.arguments.single['address'], 'https://example.com/booru/posts.json');
      expect(page.arguments.single['headers'], {'Accept': '*/*'});
      BooruWebTransport.reset(dan);
      expect(BooruWebTransport.hasSession(dan), isFalse);
      expect(page.stopped, isTrue);
      final isolated = _FakePage(Uri.parse('https://example.com/booru/'), isolates: true);
      BooruWebTransport.adopt(isolated, dan);
      await BooruWebTransport.data(request, dan, publicURL: Uri.parse('https://example.com/booru/posts.json'));
      expect(isolated.arguments.single['address'], request.url.toString());
      expect((isolated.arguments.single['headers'] as Map)['Authorization'], 'Basic x');
    });

    test('other origins are refused and network failures retry', () async {
      expect(() => BooruWebTransport.data(BooruRequest(Uri.parse('https://elsewhere.example/a')), dan), throwsA(isA<BooruError>()));
      final page = _FakePage(Uri.parse('https://example.com/booru/'), failures: 2);
      BooruWebTransport.factory = (_) => page;
      final response = await BooruWebTransport.data(BooruRequest(Uri.parse('https://example.com/booru/posts.json')), dan);
      expect(response.statusCode, 200);
      expect(page.arguments.length, 3);
      expect(() => BooruBrowserScripts.fetchResult('{"networkError":"timeout"}'), throwsA(const NetworkError(NetworkErrorCode.timedOut)));
      expect(BooruBrowserScripts.imageResult(jsonEncode('data:image/png;base64,${base64Encode(png)}')), png);
    });

    test('requests share the page side by side while a navigation waits for them', () async {
      final page = _GatedPage(Uri.parse('https://example.com/booru/'));
      BooruWebTransport.adopt(page, dan);
      final first = BooruWebTransport.data(BooruRequest(Uri.parse('https://example.com/booru/posts.json?page=1')), dan);
      final second = BooruWebTransport.data(BooruRequest(Uri.parse('https://example.com/booru/posts.json?page=2')), dan);
      await pumpEventQueue();
      expect(page.running, 2, reason: 'A second request must not wait for the first one to finish');
      final document = BooruWebTransport.document(BooruRequest(Uri.parse('https://example.com/booru/pools')), dan);
      await pumpEventQueue();
      expect(page.navigations, 0, reason: 'A navigation would replace the document under running requests');
      page.release();
      await Future.wait([first, second]);
      await pumpEventQueue();
      expect(page.navigations, 1);
      page.release();
      expect((await document).statusCode, 200);
    });

    test('a server that challenged direct requests is remembered for a while', () {
      final preferences = MemoryPreferences();
      BooruWebTransport.preferences = preferences;
      addTearDown(() => BooruWebTransport.preferences = null);
      final now = DateTime(2026, 11, 4, 12);
      expect(BooruWebTransport.prefersBrowser(dan, now: now), isFalse, reason: 'Without a browser factory the direct route stays');
      BooruWebTransport.factory = (_) => _FakePage(Uri.parse('https://example.com/booru/'));
      expect(BooruWebTransport.prefersBrowser(dan, now: now), isFalse);
      BooruWebTransport.directChallenged(dan, now: now);
      expect(BooruWebTransport.prefersBrowser(dan, now: now.add(const Duration(minutes: 29))), isTrue);
      expect(BooruWebTransport.prefersBrowser(dan, now: now.add(const Duration(minutes: 31))), isFalse, reason: 'The direct route is tried again later');
      expect(preferences.integerOrNull('booru.directChallengedUntil.${dan.id}'), now.add(const Duration(minutes: 30)).millisecondsSinceEpoch);
    });
  });

  group('image caches', () {
    test('disk cache bounds, recency and clear across relaunch', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/thumbs');
      final disk = BooruThumbnailDiskCache(directory: root, capacity: 8);
      final start = DateTime.fromMillisecondsSinceEpoch(100000);
      disk.write(Uint8List.fromList([1, 2, 3, 4]), 'https://private.test/a', now: start);
      disk.write(Uint8List.fromList([5, 6, 7, 8]), 'second', now: start.add(const Duration(seconds: 1)));
      expect(disk.read('https://private.test/a', now: start.add(const Duration(seconds: 2))), isNotNull);
      disk.write(Uint8List.fromList([9, 10, 11, 12]), 'third', now: start.add(const Duration(seconds: 3)));
      expect(disk.read('second'), isNull);
      // Files are saved in the background; a relaunch reads what landed.
      await disk.idle;
      final relaunched = BooruThumbnailDiskCache(directory: root, capacity: 8);
      expect(relaunched.read('https://private.test/a'), [1, 2, 3, 4]);
      final names = root.listSync().map((file) => file.uri.pathSegments.last).toList();
      expect(names.length, 2);
      expect(names.every((name) => !name.contains('private')), isTrue);
      relaunched.clear();
      expect(BooruThumbnailDiskCache(directory: root).read('third'), isNull);
      expect(root.listSync(), isEmpty);
    });

    test('a copy still being saved is readable, and removing it keeps it from landing', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/pending');
      final disk = BooruThumbnailDiskCache(directory: root);
      disk.write(Uint8List.fromList([1, 2, 3]), 'kept');
      disk.write(Uint8List.fromList([4, 5, 6]), 'removed');
      expect(await disk.readAsync('kept'), [1, 2, 3], reason: 'Bytes are served from memory until the file lands');
      disk.remove('removed');
      await disk.idle;
      expect(await BooruThumbnailDiskCache(directory: root).readAsync('kept'), [1, 2, 3]);
      expect(await BooruThumbnailDiskCache(directory: root).readAsync('removed'), isNull);
      expect(root.listSync().length, 1);
    });

    test('relaunch uses the disk copy without network and clear removes it', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      final loader = _Loader(png);
      final first = BooruImageCache(directory: root, loadData: loader.load);
      await first.load('https://example.test/preview.png', a);
      await first.idle;
      loader.offline = true;
      final relaunched = BooruImageCache(directory: root, loadData: loader.load);
      expect(await relaunched.load('https://example.test/preview.png', a), png);
      expect(loader.calls, 1);
      await relaunched.clear();
      await expectLater(relaunched.load('https://example.test/preview.png', a), throwsA(anything), reason: 'Clearing must remove both memory and disk copies');
      expect(root.listSync(), isEmpty);
    });

    test('simultaneous cells share one download and sources stay separate', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      final loader = _Loader(png);
      final cache = BooruImageCache(directory: root, loadData: loader.load);
      final values = await Future.wait([cache.load('https://example.test/same.png', a), cache.load('https://example.test/same.png', a)]);
      expect(values[0], values[1]);
      expect(loader.calls, 1);
      expect(cache.cached('https://example.test/same.png', a), png);
      await cache.load('https://example.test/same.png', b);
      expect(loader.calls, 2);
    });

    test('a corrupt copy is fetched again', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      const url = 'https://example.test/corrupt.png';
      BooruThumbnailDiskCache(directory: root, fileExtension: 'img').write(Uint8List.fromList(utf8.encode('invalid image')), BooruImageCache.cacheKey(url, a));
      final loader = _Loader(png);
      final cache = BooruImageCache(directory: root, loadData: loader.load);
      expect(await cache.load(url, a), png);
      expect(loader.calls, 1);
    });

    test('clearing during a download cannot bring the copy back', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      final loader = _Loader(png, delay: const Duration(milliseconds: 200));
      final cache = BooruImageCache(directory: root, loadData: loader.load);
      final task = cache.load('https://example.test/late.png', a);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(loader.calls, 1);
      await cache.clear();
      await expectLater(task, throwsA(anything), reason: 'An invalidated request must not repopulate the cache');
      expect(root.existsSync() ? root.listSync() : [], isEmpty);
    });

    test('overlapping prefetch windows share one concurrency limit', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      final loader = _Loader(png, delay: const Duration(milliseconds: 40));
      final cache = BooruImageCache(directory: root, loadData: loader.load);
      final urls = [for (var index = 0; index < 8; index++) 'https://example.test/$index.png'];
      for (var round = 0; round < 12; round++) {
        cache.prefetch([for (final url in urls) (url, a)]);
      }
      for (var attempt = 0; attempt < 300 && !urls.every((url) => cache.cached(url, a) != null); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(urls.every((url) => cache.cached(url, a) != null), isTrue);
      expect(loader.calls, urls.length, reason: 'Overlapping cells must share the same work');
      expect(loader.peak, lessThanOrEqualTo(2), reason: 'The limit must apply across all prefetch calls');
    });

    test('cancelling prefetch discards queued work', () async {
      final root = Directory('${temporaryDirectory(addTearDown).path}/cache');
      final loader = _Loader(png, delay: const Duration(milliseconds: 100));
      final cache = BooruImageCache(directory: root, loadData: loader.load);
      cache.prefetch([for (var index = 0; index < 12; index++) ('https://example.test/cancel-$index.png', a)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cache.cancelPrefetch();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(loader.calls, 2, reason: 'Leaving the image mode must discard speculative queued downloads');
    });

    test('the viewer never uses the preview as full media', () {
      final post = BooruFixtureSource.post(1, a)
        ..fileURL = null
        ..sampleURL = null;
      expect(post.displayURL, isNotNull);
      expect(post.viewerURL(original: false), isNull);
      post
        ..fileURL = 'https://example.test/animated.gif'
        ..sampleURL = 'https://example.test/still.jpg'
        ..fileExtension = 'gif';
      expect(post.viewerURL(original: false), post.fileURL);
    });

    test('media types are read from their signatures', () async {
      expect(BooruMediaType.sniff(png), 'png');
      expect(BooruMediaType.imageExtension(png), 'png');
      expect(BooruMediaType.sniff(base64Decode(BooruFixtureMedia.gif.split(',').last)), 'gif');
      expect(BooruMediaType.sniff(base64Decode(BooruFixtureMedia.mp4.split(',').last)), 'mp4');
      expect(BooruMediaType.isImage(base64Decode(BooruFixtureMedia.mp4.split(',').last)), isFalse);
      expect(BooruMediaType.sniff(Uint8List.fromList(utf8.encode('<html>'))), isNull);
      expect(BooruMediaType.sniff(await BooruFixtureMedia.thumbnail()), 'png');
    });
  });
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  String? read(String name) => values[name];
  @override
  void write(String name, String? value) => value == null ? values.remove(name) : values[name] = value;
}

class _Loader {
  _Loader(this.data, {this.delay = Duration.zero});
  final Uint8List data;
  final Duration delay;
  var calls = 0, active = 0, peak = 0;
  var offline = false;

  Future<Uint8List> load(String url, BooruServer server) async {
    calls += 1;
    active += 1;
    if (active > peak) peak = active;
    try {
      if (offline) throw const NetworkError(NetworkErrorCode.notConnectedToInternet);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return data;
    } finally {
      active -= 1;
    }
  }
}

class _FakePage implements BooruBrowserPage {
  _FakePage(this.url, {this.isolates = true, this.failures = 0});
  @override
  final Uri? url;
  final bool isolates;
  int failures;
  final arguments = <Map<String, Object?>>[];
  var stopped = false;

  @override
  bool get isolatesScripts => isolates;
  @override
  Future<void> ready() async {}
  @override
  Future<String> evaluate(String script, Map<String, Object?> arguments) async {
    this.arguments.add(arguments);
    if (failures > 0) {
      failures -= 1;
      return '{"networkError":"connection"}';
    }
    return jsonEncode({'status': 200, 'body': '[]'});
  }

  @override
  Future<int> navigate(Uri url) async => 200;
  @override
  void stop() => stopped = true;
}

/// A page whose scripts finish only when the test releases them.
class _GatedPage implements BooruBrowserPage {
  _GatedPage(this.url);
  @override
  final Uri? url;
  var running = 0, navigations = 0;
  var _gate = Completer<void>();

  void release() {
    _gate.complete();
    _gate = Completer<void>();
  }

  @override
  bool get isolatesScripts => false;
  @override
  Future<void> ready() async {}
  @override
  Future<String> evaluate(String script, Map<String, Object?> arguments) async {
    if (script == BooruBrowserScripts.outerHTML) return jsonEncode('<html><body>pools</body></html>');
    running += 1;
    await _gate.future;
    running -= 1;
    return jsonEncode({'status': 200, 'body': '[]'});
  }

  @override
  Future<int> navigate(Uri url) async {
    navigations += 1;
    return 200;
  }

  @override
  void stop() {}
}

class _EmptySource implements BooruProviding {
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async => [];
  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => [];
  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async => [];
  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async => post;
}

class _DelayedSource extends _EmptySource {
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    await Future<void>.delayed(Duration(milliseconds: query == 'slow' ? 180 : 10));
    return BooruBatch(posts: [BooruFixtureSource.post(query == 'slow' ? 1 : 2, server)], hasMore: false);
  }
}

class _GatedSource extends _EmptySource {
  final _released = Completer<void>();
  var emptyDelivered = false;
  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    if (server.id == 'slow') await _released.future;
    if (query == 'empty') {
      emptyDelivered = true;
      return const BooruBatch(posts: [], hasMore: false);
    }
    return BooruBatch(posts: [BooruFixtureSource.post(page + 1, server)], hasMore: page == 0);
  }
}

class _PartialSource extends _EmptySource {
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    if (query == 'slow') await Future<void>.delayed(const Duration(milliseconds: 200));
    if (server.id == b.id) throw const NetworkError(NetworkErrorCode.secureConnectionFailed);
    return BooruBatch(posts: [BooruFixtureSource.post(page + 1, server)], hasMore: page == 0);
  }
}

class _GoldPageSource extends _EmptySource {
  _GoldPageSource({this.repeating = false});
  final bool repeating;
  final pages = <int>[];
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    pages.add(page);
    if (page == 0 || repeating) return const BooruBatch(posts: [], hasMore: true, goldRestrictedIDs: [12403879]);
    return BooruBatch(posts: [BooruFixtureSource.post(101, server)], hasMore: false);
  }
}
