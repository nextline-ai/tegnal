// Ported from native-ios/TEGNALTests/BooruAccountTests.swift. Servers are neutral `.example` hosts.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_account.dart';
import 'package:tegnal/core/booru/booru_browser.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_transport.dart';
import 'package:tegnal/core/content/site_favorites_sync.dart';
import 'package:tegnal/core/support/preferences.dart';

import '../content/content_test_support.dart';

final dan = BooruServer(id: 'account-dan', name: 'Danbooru', baseURL: 'https://example.com/booru', engine: BooruEngine.danbooru);
final gel = BooruServer(id: 'account-gel', name: 'Gelbooru', baseURL: 'https://example.org', engine: BooruEngine.gelbooru);
final moe = BooruServer(id: 'account-moe', name: 'Moebooru', baseURL: 'https://example.net', engine: BooruEngine.moebooru);

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('parsers read each server’s account answers', () {
    expect(
      BooruAccountParser.csrfToken('<head><meta name="csrf-param" content="authenticity_token"><meta name="csrf-token" content="abc+/="></head>'),
      'abc+/=',
    );
    expect(BooruAccountParser.danbooruIdentity(bytes('{"id":null,"name":"Anonymous","level":0}')), isNull);
    expect(BooruAccountParser.danbooruIdentity(bytes('{"id":42,"name":"some_one","level":20}')), const BooruAccountIdentity(userID: 42, name: 'some_one'));
    BooruCookie cookie(String name, String value) => BooruCookie(name: name, value: value, domain: 'example.org');
    expect(BooruAccountParser.gelbooruIdentity([cookie('user_id', '77'), cookie('pass_hash', 'f00')])?.userID, 77);
    expect(BooruAccountParser.gelbooruIdentity([cookie('user_id', '77')]), isNull, reason: 'An id without its hash is not a sign-in');
    expect(BooruAccountParser.moebooruIdentity([cookie('login', 'a%20b'), cookie('pass_hash', 'f00')])?.name, 'a b');
    final key = BooruAccountParser.gelbooruAPIKey('<td><input type="text" value="&amp;api_key=0123456789abcdef0123456789abcdef&amp;user_id=77" readonly></td>');
    expect(key, ('0123456789abcdef0123456789abcdef', 77));
    expect(
      BooruAccountParser.plainDText('[quote]x said:\nhi[/quote]\n[b]Nice[/b] "link":https://a.example/p [[tag_name]] {{blue_sky}}'),
      '“x said:\nhi”\n\nNice link tag_name blue_sky',
    );
  });

  test('comments read from JSON, XML and both page shapes', () {
    final comments = BooruAccountParser.danbooruComments(
      bytes(
        '[{"id":12,"body":"later","score":-1,"created_at":"2024-06-16T05:42:45.123-04:00","is_deleted":false,"creator":{"name":"b_user"}},'
        '{"id":9,"body":"first","score":3,"created_at":"2024-06-15T00:00:00.000Z","is_deleted":false,"creator":{"name":"a"}},'
        '{"id":10,"body":"gone","is_deleted":true,"creator":{"name":"c"}}]',
      ),
    );
    expect(comments.map((comment) => comment.id), [9, 12]);
    expect(comments.last.author, 'b user');
    expect(comments.last.score, -1);
    expect(comments.last.posted, isNotNull);
    final xml = bytes(
      '<?xml version="1.0" encoding="UTF-8"?><comments type="array"><comment created_at="2024-06-16 05:42" post_id="5" body="Hello &amp; welcome" creator="someone" id="41104" creator_id="3"/></comments>',
    );
    expect(BooruAccountParser.gelbooruAPIComments(xml).map((comment) => comment.text), ['Hello & welcome']);
    const page = '''
<div id="comment-list"><div id="c41104">
    <div class="col1">
        <a href="index.php?page=account&amp;s=profile&amp;uname=0ncedash">0ncedash</a>
        <span>&gt;&gt; #41104</span><br />
        <b>Posted on 2024-06-16 05:42:45 Score: <a id="sc41104">3</a> (vote <a href="#">Up</a>)</b>
    </div>
    <div class="col2">5 million posts, awesome! :D</div>
</div></div>''';
    final parsed = BooruAccountParser.gelbooruPageComments(page);
    expect(parsed.map((comment) => comment.id), [41104]);
    expect(parsed.first.author, '0ncedash');
    expect(parsed.first.score, 3);
    expect(parsed.first.text, '5 million posts, awesome! :D');
    expect(parsed.first.posted, isNotNull);
    const modern =
        '<div class="commentBody"><a href="index.php?page=account&amp;s=profile&amp;id=5"><b>poster</b></a> #301 commented at 2024-01-02 03:04:05<br />Great picture</div>';
    final other = BooruAccountParser.gelbooruPageComments(modern);
    expect(other.map((comment) => comment.id), [301]);
    expect(other.first.author, 'poster');
    expect(other.first.text, 'Great picture');
  });

  test('an API access line pasted into either field fills both', () {
    const line = '&api_key=348erj3kr&user_id=1824193';
    expect(const BooruCredentials(account: line).normalized, const BooruCredentials(account: '1824193', apiKey: '348erj3kr'));
    expect(const BooruCredentials(apiKey: ' $line\n').normalized, const BooruCredentials(account: '1824193', apiKey: '348erj3kr'));
    expect(
      const BooruCredentials(account: '1824193', apiKey: '&amp;api_key=abc&amp;user_id=7').normalized,
      const BooruCredentials(account: '7', apiKey: 'abc'),
    );
    expect(
      const BooruCredentials(account: ' name ', apiKey: ' key ').normalized,
      const BooruCredentials(account: 'name', apiKey: 'key'),
      reason: 'Other details are only trimmed',
    );
  });

  test('a favorites page with no images is empty only when it is the website’s own page', () {
    List<int> page(String html) => utf8.encode(html);
    expect(
      BooruAccountParser.isEmptyFavoritesPage(
        page('<html><body><a href="index.php?page=favorites&amp;s=view&amp;id=7">My Favorites</a><div id="paginator"></div></body></html>'),
      ),
      isTrue,
    );
    expect(
      BooruAccountParser.isEmptyFavoritesPage(
        page('<html><body><span class="thumb"><a href="index.php?page=post&amp;s=view&amp;id=12"></a></span></body></html>'),
      ),
      isFalse,
      reason: 'Images the parser didn’t recognize are not an empty page',
    );
    expect(BooruAccountParser.isEmptyFavoritesPage(page('<html><body><a href="index.php?page=post&s=view&id=12">12</a></body></html>')), isFalse);
    expect(
      BooruAccountParser.isEmptyFavoritesPage(page('<html><head><title>Just a moment...</title></head><body><form id="challenge-form"></form></body></html>')),
      isFalse,
      reason: 'A bot check never reads as no favorites',
    );
    expect(BooruAccountParser.isEmptyFavoritesPage(page('{}')), isFalse);
  });

  test('comment form keeps hidden fields without posting anonymously', () {
    const html = '''
<form method="post" action="index.php?page=search"><input name="tags"></form>
<form method="post" action="index.php?page=comment&amp;id=5&amp;s=save">
  <textarea name="comment" rows="7"></textarea>
  <input type="checkbox" name="post_anonymous" checked> Anonymous
  <input type="hidden" name="conf" id="conf" value="0">
  <input type="submit" name="submit" value="Post comment">
  <input type="submit" name="preview" value="Preview">
</form>''';
    final form = BooruAccountParser.commentForm(html, 'Nice')!;
    expect(form.action, 'index.php?page=comment&id=5&s=save');
    expect(form.fields.map((field) => '${field.$1}=${field.$2}'), ['comment=Nice', 'conf=1', 'submit=Post comment']);
    expect(BooruAccountParser.commentForm("<form action='x'><input name='a'></form>", 'x'), isNull);
  });

  test('requests carry each server’s sign-in the way it expects', () {
    const key = BooruCredentials(account: 'name', apiKey: 'secret');
    final danbooru = BooruAccountClient.request(
      dan,
      method: 'POST',
      path: 'favorites.json',
      query: [('post_id', '5')],
      form: const [],
      accept: 'application/json',
      credentials: key,
    );
    expect(danbooru.url.toString(), 'https://example.com/booru/favorites.json?post_id=5');
    expect(danbooru.headers['Authorization'], 'Basic ${base64Encode(utf8.encode('name:secret'))}');
    final moebooru = BooruAccountClient.request(
      moe,
      method: 'POST',
      path: 'post/vote.json',
      form: [('id', '5'), ('score', '3')],
      accept: 'application/json',
      credentials: key,
    );
    expect(utf8.decode(moebooru.body!), 'id=5&score=3&login=name&password_hash=secret');
    expect(moebooru.headers['Authorization'], isNull);
    final page = BooruAccountClient.request(gel, method: 'GET', path: 'public/addfav.php', query: [('id', '5')], accept: 'text/html', credentials: key);
    expect(page.url.toString(), 'https://example.org/public/addfav.php?id=5', reason: 'Page actions rely on the sign-in cookies, never the API key');
    final api = BooruAccountClient.request(
      gel,
      method: 'GET',
      path: 'index.php',
      query: [('page', 'dapi'), ('tags', 'fav:7 a+b')],
      accept: 'application/json',
      credentials: key,
    );
    expect(api.url.query, 'page=dapi&tags=fav%3A7%20a%2Bb&user_id=name&api_key=secret');
    final form = BooruAccountClient.request(
      gel,
      method: 'POST',
      path: '',
      form: [('comment', 'a&b')],
      accept: 'text/html',
      credentials: const BooruCredentials(),
      target: Uri.parse('https://example.org/index.php?page=comment&id=5&s=save'),
    );
    expect(form.url.toString(), 'https://example.org/index.php?page=comment&id=5&s=save');
    expect(utf8.decode(form.body!), 'comment=a%26b');
    expect(
      () => BooruAccountClient.request(
        gel,
        method: 'POST',
        path: '',
        form: const [],
        accept: 'text/html',
        credentials: const BooruCredentials(),
        target: Uri.parse('https://elsewhere.example/steal'),
      ),
      throwsA(isA<BooruError>()),
    );
  });

  test('an image in a list folder keeps its other lists until moved to another list', () {
    final state = SiteFavoriteState(folders: {7: 'seven', 8: 'eight'}, unassigned: 0, exclusive: false)
      ..baseline = {
        1: {0, 7, 8},
        2: {7, 8},
        3: {7},
      };
    final places = BooruAccountSync.places({1: 'seven', 2: 'eight', 3: 'eight', 4: 'other'}, state);
    expect(places[1], {const FavoritePlace.category(7), const FavoritePlace.category(8)}, reason: 'One folder stands for every list the image was in');
    expect(places[2], {const FavoritePlace.category(7), const FavoritePlace.category(8)});
    expect(places[3], {const FavoritePlace.category(8)}, reason: "Moved to another list's folder, it leaves the lists it was in");
    expect(places[4], {FavoritePlace.unassigned});
  });

  test('danbooru sync brings in favorites and groups, then sends changes made in the app', () async {
    final directory = await Directory.systemTemp.createTemp('booru-account');
    addTearDown(() => directory.delete(recursive: true));
    final store = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    store.saveServer(dan);
    final accounts = BooruAccounts(MemoryPreferences());
    accounts.setIdentity(const BooruAccountIdentity(userID: 42, name: 'me'), dan.id);
    store.saveFavorite(BooruDecoder.post({'id': 9, 'file_url': 'https://cdn.example.com/9.jpg'}, dan));

    final log = <String>[];
    var handler = (HttpExchange request) {
      final path = request.url.path.replaceFirst('/booru/', '');
      return switch (path) {
        'favorites.json' when request.method == 'GET' => '[{"post_id":1},{"post_id":2}]',
        'favorite_groups.json' => '[{"id":7,"name":"my_group","post_ids":[2,3]},{"id":8,"name":"empty","post_ids":[]}]',
        'posts.json' => () {
          final ids = (request.url.queryParameters['tags'] ?? '').replaceFirst('id:', '').split(',');
          return '[${ids.map((id) => '{"id":$id,"file_url":"https://cdn.example.com/$id.jpg","tag_string":"sky"}').join(',')}]';
        }(),
        'profile' => '<html><head><meta name="csrf-token" content="tok"></head></html>',
        _ => '{}',
      };
    };
    final client = BooruAccountClient(
      fetcher: FixtureFetcher((request) {
        final path = request.url.path.replaceFirst('/booru/', '');
        final csrf = request.headers['X-CSRF-Token'];
        log.add('${request.method} $path ${request.url.query}${csrf == null ? '' : ' csrf=$csrf'}');
        return FixtureReply.text(200, handler(request));
      }),
      credentials: MemoryCredentialStore(),
      session: BooruBrowserSession(),
      pause: Duration.zero,
    );
    final sync = BooruAccountSync(store: store, accounts: accounts, client: client)..sendGap = Duration.zero;

    await sync.setUp(dan);
    final offer = sync.setupOffer!;
    expect(offer.favoriteCount, 3, reason: 'The first sync asks how to start before changing anything');
    expect(offer.newImages, 3);
    expect(offer.newFolders, ['my group']);
    expect(accounts.favorites.state(dan.id), isNull);
    expect(store.favoriteFolders(dan.id).keys.toSet(), {9});
    await sync.answerSetup(SiteFavoritesSetupChoice.bringIn);
    final state = accounts.favorites.state(dan.id)!;
    final groupFolder = state.folders[7]!;
    expect(state.folders.containsKey(8), isFalse, reason: 'An empty group gets no folder');
    expect(store.folders().firstWhere((folder) => folder.id == groupFolder).name, 'my group');
    final saved = store.favoriteFolders(dan.id);
    expect(saved.keys.toSet(), {1, 2, 3, 9});
    expect(saved[2], groupFolder);
    expect(saved[3], groupFolder);
    expect(saved[1], isNot(groupFolder));
    expect(state.localOnly, contains(9), reason: 'The library saved before signing in is not sent');
    expect(log.where((entry) => !entry.startsWith('GET')), isEmpty, reason: 'Reading the site changes nothing there');
    expect(sync.isListFolder(groupFolder), isTrue);

    // Saved in the app and moved out of the group's folder: both reach the website.
    log.clear();
    store.saveFavorite(BooruDecoder.post({'id': 10, 'file_url': 'https://cdn.example.com/10.jpg'}, dan));
    store.moveFavorites([store.savedPost(dan.id, 3)!], saved[1]!);
    await sync.sync(dan, pull: false);
    expect(log.toSet(), {
      'GET profile ',
      'POST favorites.json post_id=3 csrf=tok',
      'PUT favorite_groups/7/remove_post.json post_id=3 csrf=tok',
      'POST favorites.json post_id=10 csrf=tok',
    });
    final after = accounts.favorites.state(dan.id)!;
    expect(after.baseline?[3], {0});
    expect(after.baseline?[10], {0});

    // Removed on the website: the app follows.
    handler = (request) => switch (request.url.path.replaceFirst('/booru/', '')) {
      'favorites.json' => '[{"post_id":1},{"post_id":3},{"post_id":10}]',
      'favorite_groups.json' => '[{"id":7,"name":"my_group","post_ids":[2]}]',
      _ => '[]',
    };
    await sync.sync(dan);
    expect(store.favoriteFolders(dan.id).keys.toSet(), {1, 2, 3, 9, 10});
    handler = (request) => switch (request.url.path.replaceFirst('/booru/', '')) {
      'favorites.json' => '[{"post_id":1},{"post_id":10}]',
      'favorite_groups.json' => '[{"id":7,"name":"my_group","post_ids":[]}]',
      _ => '[]',
    };
    await sync.sync(dan);
    expect(store.favoriteFolders(dan.id).keys.toSet(), {1, 9, 10}, reason: 'Images taken off the website leave the app; the earlier library stays');
    expect(store.folderIDs(), isNot(contains(groupFolder)), reason: 'An emptied group and its emptied folder go together');
  });

  test('keeping the library leaves server favorites alone, and deleting in the app only keeps them', () async {
    final directory = await Directory.systemTemp.createTemp('booru-account-keep');
    addTearDown(() => directory.delete(recursive: true));
    final store = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    store.saveServer(dan);
    final accounts = BooruAccounts(MemoryPreferences());
    accounts.setIdentity(const BooruAccountIdentity(userID: 42, name: 'me'), dan.id);
    final log = <String>[];
    var favorites = '[{"post_id":1},{"post_id":2}]';
    final client = BooruAccountClient(
      fetcher: FixtureFetcher((request) {
        final path = request.url.path.replaceFirst('/booru/', '');
        log.add('${request.method} $path ${request.url.query}');
        return FixtureReply.text(200, switch (path) {
          'favorites.json' when request.method == 'GET' => favorites,
          'favorite_groups.json' => '[]',
          'posts.json' => () {
            final ids = (request.url.queryParameters['tags'] ?? '').replaceFirst('id:', '').split(',');
            return '[${ids.map((id) => '{"id":$id,"file_url":"https://cdn.example.com/$id.jpg"}').join(',')}]';
          }(),
          'profile' => '<html><head><meta name="csrf-token" content="tok"></head></html>',
          _ => '{}',
        });
      }),
      credentials: MemoryCredentialStore(),
      session: BooruBrowserSession(),
      pause: Duration.zero,
    );
    final sync = BooruAccountSync(store: store, accounts: accounts, client: client)..sendGap = Duration.zero;

    await sync.setUp(dan);
    await sync.answerSetup(SiteFavoritesSetupChoice.keepLibrary);
    expect(accounts.favorites.state(dan.id)?.ignored, {1, 2});
    expect(store.favoriteFolders(dan.id), isEmpty, reason: 'Nothing comes into the library');
    expect(log.where((entry) => entry.startsWith('POST') || entry.startsWith('DELETE')), isEmpty, reason: 'Nothing changes on the website');

    favorites = '[{"post_id":1},{"post_id":2},{"post_id":5}]';
    await sync.sync(dan);
    expect(store.favoriteFolders(dan.id).keys.toSet(), {5}, reason: 'A favorite added afterwards comes in');

    final five = store.savedPost(dan.id, 5)!;
    expect(sync.syncsAny([five]), isTrue);
    log.clear();
    sync.removeFavorites([five], keepOnServer: true);
    await sync.sync(dan, pull: false);
    await sync.sync(dan);
    expect(log.where((entry) => entry.startsWith('DELETE')), isEmpty, reason: 'Deleted in the app only, it stays on the website');
    expect(store.favoriteFolders(dan.id), isEmpty, reason: "and doesn't come back");
  });

  test('turning the first sync down declines it', () async {
    final directory = await Directory.systemTemp.createTemp('booru-account-off');
    addTearDown(() => directory.delete(recursive: true));
    final store = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    store.saveServer(dan);
    final accounts = BooruAccounts(MemoryPreferences());
    accounts.setIdentity(const BooruAccountIdentity(userID: 42, name: 'me'), dan.id);
    final client = BooruAccountClient(
      fetcher: FixtureFetcher(
        (request) => FixtureReply.text(200, switch (request.url.path.replaceFirst('/booru/', '')) {
          'favorites.json' => '[{"post_id":1}]',
          'favorite_groups.json' => '[]',
          _ => '[]',
        }),
      ),
      credentials: MemoryCredentialStore(),
      session: BooruBrowserSession(),
      pause: Duration.zero,
    );
    final sync = BooruAccountSync(store: store, accounts: accounts, client: client)..sendGap = Duration.zero;
    await sync.setUp(dan);
    await sync.answerSetup(SiteFavoritesSetupChoice.off);
    expect(accounts.favorites.state(dan.id), isNull);
    expect(accounts.favorites.isDeclined(dan.id), isTrue);
    expect(store.favoriteFolders(dan.id), isEmpty);
  });

  test('saved API keys sign in, and a Gelbooru key only reads', () async {
    final directory = await Directory.systemTemp.createTemp('booru-account-key');
    addTearDown(() => directory.delete(recursive: true));
    final store = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    store.saveServer(gel);
    final credentials = MemoryCredentialStore()..save(const BooruCredentials(account: '77', apiKey: 'key'), gel.id);
    final accounts = BooruAccounts(MemoryPreferences());
    final log = <String>[];
    final client = BooruAccountClient(
      fetcher: FixtureFetcher((request) {
        log.add('${request.method} ${request.url}');
        if (request.url.queryParameters['tags'] == 'fav:77') {
          return FixtureReply.text(200, '{"post":[{"id":5,"file_url":"https://cdn.example.com/5.jpg","tags":"sky"}]}');
        }
        return FixtureReply.text(200, '{}');
      }),
      credentials: credentials,
      session: BooruBrowserSession(),
      pause: Duration.zero,
    );
    final sync = BooruAccountSync(store: store, accounts: accounts, client: client)..sendGap = Duration.zero;

    await sync.discover(gel);
    expect(accounts.identity(gel.id)?.userID, 77, reason: 'A saved user id and API key sign the account in');
    expect(client.canChange(gel), isFalse, reason: "Gelbooru's API key reads; changes need the website's sign-in");
    expect(sync.setupOffer, isNotNull, reason: 'The first sync asks how to start');
    await sync.answerSetup(SiteFavoritesSetupChoice.bringIn);
    expect(store.favoriteFolders(gel.id).keys.toSet(), {5}, reason: "The key reads the account's favorites");
    expect(log.any((entry) => entry.contains('api_key=key') && entry.contains('user_id=77')), isTrue);

    log.clear();
    store.saveFavorite(BooruDecoder.post({'id': 6, 'file_url': 'https://cdn.example.com/6.jpg'}, gel));
    await sync.sync(gel, pull: false);
    expect(log.where((entry) => entry.contains('addfav')), isEmpty, reason: 'Nothing is sent without a sign-in that can change things');
    expect(accounts.favorites.state(gel.id)?.baseline?[6], isNull, reason: 'It waits to be sent once there is one');

    await sync.signOut(gel);
    expect(accounts.identity(gel.id), isNull);
    expect(credentials.read(gel.id).isEmpty, isTrue, reason: 'Signing out forgets the saved key too');
  });
}
