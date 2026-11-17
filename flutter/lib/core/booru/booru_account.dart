import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../content/content_errors.dart';
import '../content/content_transport.dart';
import '../content/keyed_work_extras.dart';
import '../content/site_account.dart';
import '../content/site_favorites_sync.dart';
import '../storage/folder_rules.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import '../support/swift_json.dart';
import '../taste/taste_models.dart';
import '../taste/taste_store.dart';
import 'booru_browser.dart';
import 'booru_client.dart';
import 'booru_html.dart';
import 'booru_models.dart';
import 'booru_store.dart';

/// `BooruAccountIdentity`: the account signed in on an image server, as the server names it.
class BooruAccountIdentity {
  const BooruAccountIdentity({this.userID, this.name = '', this.savedCredentials = false});

  final int? userID;
  final String name;

  /// The sign-in itself saved account details: an API key the site's settings page showed, or the
  /// password hash its cookies held. Signing out removes them again.
  final bool savedCredentials;

  String get displayName => name.isEmpty ? (userID == null ? '' : '#$userID') : name;

  BooruAccountIdentity copyWith({bool? savedCredentials}) =>
      BooruAccountIdentity(userID: userID, name: name, savedCredentials: savedCredentials ?? this.savedCredentials);

  Map<String, Object?> toJson() => {'userID': ?userID, 'name': name, 'savedCredentials': savedCredentials};

  static BooruAccountIdentity? fromJson(Object? json) {
    if (json is! Map) return null;
    return BooruAccountIdentity(
      userID: (json['userID'] as num?)?.toInt(),
      name: json['name'] as String? ?? '',
      savedCredentials: json['savedCredentials'] == true,
    );
  }

  @override
  bool operator ==(Object other) => other is BooruAccountIdentity && other.userID == userID && other.name == name && other.savedCredentials == savedCredentials;
  @override
  int get hashCode => Object.hash(userID, name, savedCredentials);
  @override
  String toString() => 'BooruAccountIdentity($userID, $name)';
}

/// The signed-in account's vote on an image: its own record on the server, when the server keeps one.
class BooruVote {
  const BooruVote({this.id, this.score = 0});
  final int? id;

  /// 1 up, -1 down, 0 none.
  final int score;
}

/// What each kind of image server lets a signed-in account do.
extension BooruEngineAccount on BooruEngine {
  /// Named lists besides the account's favorites (Danbooru's favorite groups).
  bool get keepsFavoriteLists => this == BooruEngine.danbooru;

  /// Moebooru keeps favorites as the highest vote, so votes there would change favorites.
  bool get votesUp => this != BooruEngine.moebooru;
  bool get votesDown => this == BooruEngine.danbooru;

  /// Whether the server shows the account its own vote, and lets it be withdrawn.
  bool get showsOwnVote => this == BooruEngine.danbooru;

  /// The server's own sign-in page.
  Uri signInURL(String base) {
    final root = Uri.parse(base.endsWith('/') ? base.substring(0, base.length - 1) : base);
    return switch (this) {
      BooruEngine.danbooru => root.replace(path: '${root.path}/login', query: 'url=%2Fprofile'),
      BooruEngine.gelbooru || BooruEngine.oldGelbooru => root.replace(path: '${root.path}/index.php', query: 'page=account&s=login&code=00'),
      BooruEngine.moebooru => root.replace(path: '${root.path}/user/login'),
    };
  }
}

/// `BooruAccounts`: each image server's signed-in account and its favorites sync, kept on this device only.
class BooruAccounts {
  BooruAccounts(this._preferences) : favorites = SiteFavoriteFolders(_preferences, statesKey: 'booru.favoriteSync', declinedKey: 'booru.favoriteSyncDeclined');

  /// The list id the account's own favorites take in a favorites sync; named lists keep their ids.
  static const favoritesList = 0;
  static const _key = 'booru.accounts';

  final Preferences _preferences;
  final SiteFavoriteFolders favorites;

  Map<String, Object?> get _stored {
    final text = _preferences.string(_key);
    if (text == null) return {};
    try {
      final value = jsonDecode(text);
      return value is Map<String, Object?> ? value : {};
    } on FormatException {
      return {};
    }
  }

  BooruAccountIdentity? identity(String serverID) => BooruAccountIdentity.fromJson(_stored[serverID]);

  void setIdentity(BooruAccountIdentity? identity, String serverID) {
    final all = {..._stored};
    if (identity == null) {
      all.remove(serverID);
    } else {
      all[serverID] = identity.toJson();
    }
    _preferences.set(_key, jsonEncode(all));
  }
}

/// What a server's favorites hold, with the images its answers already described.
class BooruAccountFavorites {
  const BooruAccountFavorites({required this.favorites, required this.posts});
  final AccountFavorites favorites;
  final Map<int, BooruPost> posts;
}

/// Marks a GET whose redirect answer is enough, such as a vote or a favorite removed. The
/// header itself never leaves the app.
const booruRedirectAnswerHeader = 'X-TEGNAL-Redirect-Answer';

/// `BooruAccountClient`: the signed-in account's own requests: favorites, votes and comments.
/// Requests carry the server's own browser profile cookies, where the person signed in, and the
/// API key saved for the server, never anything for another server.
class BooruAccountClient {
  BooruAccountClient({HttpFetcher? fetcher, BooruCredentialStore? credentials, BooruBrowserSession? session, this.pause = const Duration(milliseconds: 300)})
    : browserFallback = fetcher == null,
      _fetcher = fetcher,
      _credentialStore = credentials,
      _sessionOverride = session;

  static BooruAccountClient shared = BooruAccountClient();

  final bool browserFallback;
  final HttpFetcher? _fetcher;
  final BooruCredentialStore? _credentialStore;
  final BooruBrowserSession? _sessionOverride;

  /// The wait between reading pages of a long list.
  final Duration pause;
  final _csrfTokens = <String, String>{};

  HttpFetcher get fetcher => _fetcher ?? BooruClient.shared.fetcher;
  BooruCredentialStore get credentials => _credentialStore ?? BooruClient.defaultCredentials;
  BooruBrowserSession get session => _sessionOverride ?? BooruBrowserSession.shared;

  static String encode(String value) => Uri.encodeQueryComponent(value).replaceAll('+', '%20');

  static List<int> formBody(List<(String, String)> fields) => utf8.encode(fields.map((field) => '${encode(field.$1)}=${encode(field.$2)}').join('&'));

  /// One request to the server, with its sign-in. A form gives it a body.
  static BooruRequest request(
    BooruServer server, {
    required String method,
    required String path,
    List<(String, String)> query = const [],
    List<(String, String)>? form,
    required String accept,
    required BooruCredentials credentials,
    Uri? target,
  }) {
    final items = [...query];
    final fields = form == null ? null : [...form];
    if (!credentials.isEmpty) {
      switch (server.engine) {
        case BooruEngine.moebooru:
          final auth = [('login', credentials.account), ('password_hash', credentials.apiKey)];
          if (fields != null) {
            fields.addAll(auth);
          } else {
            items.addAll(auth);
          }
        case BooruEngine.gelbooru when items.any((item) => item.$1 == 'page' && item.$2 == 'dapi'):
          items.addAll([('user_id', credentials.account), ('api_key', credentials.apiKey)]);
        default:
          break;
      }
    }
    final base = server.baseURL.endsWith('/') ? server.baseURL : '${server.baseURL}/';
    Uri url;
    try {
      if (target != null) {
        // A form's own address keeps its query; anything added follows it.
        final kept = target.query.isEmpty ? <String>[] : [target.query];
        final added = [for (final item in items) '${encode(item.$1)}=${encode(item.$2)}'];
        url = [...kept, ...added].isEmpty ? target : target.replace(query: [...kept, ...added].join('&'));
        if (!booruSameOrigin(url.toString(), server.baseURL)) throw const BooruError(BooruErrorKind.invalidServer);
      } else {
        url = Uri.parse('$base$path${items.isEmpty ? '' : '?${items.map((item) => '${encode(item.$1)}=${encode(item.$2)}').join('&')}'}');
      }
    } on FormatException {
      throw const BooruError(BooruErrorKind.invalidServer);
    }
    final request = BooruRequest(url, headers: {'User-Agent': BooruBrowserSession.shared.userAgent, 'Accept': accept}, method: method);
    if (fields != null) {
      request.body = formBody(fields);
      request.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8';
    }
    if (server.engine == BooruEngine.danbooru && !credentials.isEmpty) {
      request.headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('${credentials.account}:${credentials.apiKey}'))}';
    }
    return request;
  }

  Future<Uint8List> send(
    BooruServer server,
    String method,
    String path, {
    List<(String, String)> query = const [],
    List<(String, String)>? form,
    bool html = false,
    Uri? target,
    bool action = false,
    bool retried = false,
  }) async {
    final credentials = this.credentials.read(server.id);
    final request = BooruAccountClient.request(
      server,
      method: method,
      path: path,
      query: query,
      form: form,
      accept: html ? 'text/html,application/xhtml+xml' : 'application/json, application/xml;q=0.9, text/html;q=0.8',
      credentials: credentials,
      target: target,
    );
    if (action) request.headers[booruRedirectAnswerHeader] = '1';
    // A signed-in page session proves a change with the page's own token; an API key needs none.
    if (method != 'GET' && server.engine == BooruEngine.danbooru && credentials.isEmpty) {
      request.headers['X-CSRF-Token'] = await _csrfToken(server);
    }
    final response = await _transfer(request, server);
    final data = response.data;
    final status = response.statusCode;
    if (status == 401) throw const BooruError(BooruErrorKind.authentication);
    if (status == 403) {
      if (BooruClient.needsBrowser(data, status) && !_isMessage(data)) throw const BooruError(BooruErrorKind.validationRequired);
      throw message(data) ?? const BooruError(BooruErrorKind.authentication);
    }
    if (status == 422 && !retried && server.engine == BooruEngine.danbooru && utf8.decode(data, allowMalformed: true).contains('InvalidAuthenticityToken')) {
      _csrfTokens.remove(server.id);
      return send(server, method, path, query: query, form: form, html: html, target: target, action: action, retried: true);
    }
    if (status == 422) throw message(data) ?? const BooruError(BooruErrorKind.unavailable, 422);
    if (status == 429) throw const BooruError(BooruErrorKind.rateLimited);
    if (status < 200 || status >= 400) throw BooruError(BooruErrorKind.unavailable, status);
    if (!html && BooruClient.needsBrowser(data, status)) throw const BooruError(BooruErrorKind.validationRequired);
    if (data.length >= 24000000) throw const BooruError(BooruErrorKind.invalidResponse);
    return data;
  }

  Future<BooruResponse> _transfer(BooruRequest request, BooruServer server) async {
    final browser = browserFallback && BooruWebTransport.isAvailable;
    // The browser page can't carry an API key without the page's scripts seeing it, so a request
    // made with one goes directly first: Danbooru uses its API key before the website's sign-in.
    final carriesKey = request.headers.keys.any((name) => name.toLowerCase() == 'authorization');
    // A server validated in the browser keeps its requests there, as image searches do; when that
    // browser can't reach the server, the direct connection is tried as well.
    if (browser && !carriesKey && (BooruWebTransport.hasSession(server) || BooruWebTransport.prefersBrowser(server))) {
      try {
        return await BooruWebTransport.data(request, server);
      } on NetworkError {
        session.prepare(request, server);
        return _direct(request, server);
      }
    }
    session.prepare(request, server);
    try {
      final direct = await _direct(request, server);
      if (browser && BooruClient.needsBrowser(direct.data, direct.statusCode) && !_isMessage(direct.data)) {
        BooruWebTransport.directChallenged(server);
        return await BooruWebTransport.data(request, server);
      }
      return direct;
    } on NetworkError catch (error) {
      if (!browser || ![NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.networkConnectionLost].contains(error.code)) rethrow;
      return BooruWebTransport.data(request, server);
    }
  }

  /// One direct exchange. A page's redirect is followed only within the server, and only for reads.
  Future<BooruResponse> _direct(BooruRequest request, BooruServer server) async {
    var current = request.url;
    final headers = {...request.headers}..removeWhere((name, _) => name.toLowerCase() == booruRedirectAnswerHeader.toLowerCase());
    for (var redirects = 0; ; redirects++) {
      final reply = await fetcher.send(
        HttpExchange(method: request.method, url: current, headers: headers, body: request.body, timeout: const Duration(seconds: 30)),
      );
      session.receive(current, reply.headers['set-cookie'] ?? const [], server);
      final location = reply.headers.entries.where((entry) => entry.key.toLowerCase() == 'location').firstOrNull?.value.firstOrNull;
      if (request.method == 'GET' && reply.statusCode >= 300 && reply.statusCode < 400 && location != null && redirects < 10) {
        final next = current.resolve(location);
        if (booruSameOrigin(next.toString(), server.baseURL)) {
          reply.abort?.call();
          current = next;
          headers['Cookie'] = session.cookieHeader(server, next) ?? '';
          if (headers['Cookie']!.isEmpty) headers.remove('Cookie');
          continue;
        }
      }
      final data = BytesBuilder(copy: false);
      try {
        await for (final chunk in reply.body.timeout(const Duration(seconds: 30))) {
          if (chunk.length > 24000000 - data.length) throw const BooruError(BooruErrorKind.invalidResponse);
          data.add(chunk);
        }
      } on TimeoutException {
        throw const NetworkError(NetworkErrorCode.timedOut);
      } on IOException catch (error) {
        throw IoHttpFetcher.networkError(error);
      }
      return BooruResponse(url: current, statusCode: reply.statusCode, headers: reply.headers, data: data.takeBytes());
    }
  }

  /// A JSON answer naming what went wrong, rather than a bot check's page.
  static bool _isMessage(Uint8List data) {
    try {
      return jsonDecode(utf8.decode(data)) is Map;
    } on Object {
      return false;
    }
  }

  /// The server's own words for a refused change, as Danbooru gives them.
  static SiteMessage? message(Uint8List data) {
    try {
      final object = jsonDecode(utf8.decode(data));
      if (object is! Map) return null;
      final text = '${object['message'] ?? object['reason'] ?? ''}'.trim();
      return text.isEmpty ? null : SiteMessage(text);
    } on Object {
      return null;
    }
  }

  Future<String> _csrfToken(BooruServer server) async {
    final cached = _csrfTokens[server.id];
    if (cached != null) return cached;
    final page = await send(server, 'GET', 'profile', html: true);
    final token = BooruAccountParser.csrfToken(utf8.decode(page, allowMalformed: true));
    if (token == null) throw const BooruError(BooruErrorKind.authentication);
    return _csrfTokens[server.id] = token;
  }

  void forgetSession(BooruServer server) => _csrfTokens.remove(server.id);

  List<BooruCookie> _cookies(BooruServer server) {
    final url = Uri.parse(server.baseURL);
    return session.cookies(server).where((cookie) => BooruBrowserSession.matches(cookie, url)).toList();
  }

  /// The account the server's own pages are signed in with, or the saved account details; null when neither.
  Future<BooruAccountIdentity?> identity(BooruServer server) async {
    final cookies = _cookies(server);
    switch (server.engine) {
      case BooruEngine.danbooru:
        return BooruAccountParser.danbooruIdentity(await send(server, 'GET', 'profile.json'));
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        final found = BooruAccountParser.gelbooruIdentity(cookies);
        if (found != null) return found;
        // A user id and API key saved for the server read its favorites and comments too.
        final saved = credentials.read(server.id);
        final user = int.tryParse(saved.account);
        if (server.engine != BooruEngine.gelbooru || user == null || user <= 0 || saved.apiKey.isEmpty) return null;
        return BooruAccountIdentity(userID: user);
      case BooruEngine.moebooru:
        final found = BooruAccountParser.moebooruIdentity(cookies);
        if (found != null) return found;
        final saved = credentials.read(server.id);
        return saved.isEmpty ? null : BooruAccountIdentity(name: saved.account);
    }
  }

  /// Whether the account can change things on the server, not only read them. Gelbooru's API key
  /// reads favorites and comments; favorites, votes and comments change only with the website's
  /// own sign-in.
  bool canChange(BooruServer server) => switch (server.engine) {
    BooruEngine.danbooru || BooruEngine.moebooru => true,
    BooruEngine.gelbooru || BooruEngine.oldGelbooru => BooruAccountParser.gelbooruIdentity(_cookies(server)) != null,
  };

  /// Whether the server holds anything an account could be found with, before asking it.
  bool mayHaveAccount(BooruServer server) {
    if (!credentials.read(server.id).isEmpty) return true;
    final cookies = _cookies(server);
    return switch (server.engine) {
      BooruEngine.danbooru => cookies.any((cookie) => cookie.name.endsWith('_session')),
      BooruEngine.gelbooru || BooruEngine.oldGelbooru => BooruAccountParser.gelbooruIdentity(cookies) != null,
      BooruEngine.moebooru => BooruAccountParser.moebooruIdentity(cookies) != null,
    };
  }

  /// What a finished sign-in can still read for the account: Gelbooru's API key from its settings
  /// page, or the password hash Moebooru's cookies hold, saved when none is saved yet.
  Future<BooruAccountIdentity> completeSignIn(BooruServer server, BooruAccountIdentity identity) async {
    try {
      if (!credentials.read(server.id).isEmpty) return identity;
      switch (server.engine) {
        case BooruEngine.gelbooru:
          final page = await send(server, 'GET', 'index.php', query: const [('page', 'account'), ('s', 'options')], html: true);
          final key = BooruAccountParser.gelbooruAPIKey(utf8.decode(page, allowMalformed: true));
          if (key == null || identity.userID != null && identity.userID != key.$2) return identity;
          credentials.save(BooruCredentials(account: '${key.$2}', apiKey: key.$1), server.id);
          return identity.copyWith(savedCredentials: true);
        case BooruEngine.moebooru:
          final hash = _cookies(server).where((cookie) => cookie.name == 'pass_hash').firstOrNull?.value ?? '';
          if (hash.isEmpty || identity.name.isEmpty) return identity;
          credentials.save(BooruCredentials(account: identity.name, apiKey: hash), server.id);
          return identity.copyWith(savedCredentials: true);
        case BooruEngine.danbooru || BooruEngine.oldGelbooru:
          return identity;
      }
    } on Object {
      return identity;
    }
  }

  /// The account's favorites, and Danbooru's favorite groups, with which of them hold each image.
  Future<BooruAccountFavorites> favorites(BooruServer server, BooruAccountIdentity account) async {
    final members = <int, Set<int>>{};
    final posts = <int, BooruPost>{};
    final lists = <FavoriteCategory>[];
    const main = BooruAccounts.favoritesList;
    switch (server.engine) {
      case BooruEngine.danbooru:
        final user = account.userID;
        if (user == null) throw const BooruError(BooruErrorKind.authentication);
        var count = 0;
        for (var page = 1; page <= 100; page++) {
          final data = await send(
            server,
            'GET',
            'favorites.json',
            query: [('search[user_id]', '$user'), ('limit', '1000'), ('page', '$page'), ('only', 'post_id')],
          );
          final rows = BooruDecoder.rows(data, 'favorite');
          for (final row in rows) {
            final id = BooruDecoder.integer(row['post_id']);
            if (id > 0) {
              (members[id] ??= {}).add(main);
              count += 1;
            }
          }
          if (rows.length < 1000) break;
        }
        lists.add(FavoriteCategory(id: main, name: L10n.text('Favorites'), count: count));
        final data = await send(
          server,
          'GET',
          'favorite_groups.json',
          query: [('search[creator_id]', '$user'), ('limit', '1000'), ('only', 'id,name,post_ids')],
        );
        for (final row in BooruDecoder.rows(data, 'favorite-group')) {
          final id = BooruDecoder.integer(row['id']);
          final name = row['name'];
          if (id <= 0 || name is! String) continue;
          final ids = [for (final value in (row['post_ids'] as List? ?? const [])) BooruDecoder.integer(value)].where((post) => post > 0).toList();
          for (final post in ids) {
            (members[post] ??= {}).add(id);
          }
          lists.add(FavoriteCategory(id: id, name: name.replaceAll('_', ' '), count: ids.length));
        }
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        final user = account.userID;
        if (user == null) throw const BooruError(BooruErrorKind.authentication);
        List<BooruPost>? found;
        // The website's sign-in comes first; the API key reads favorites only without one,
        // and an empty API answer is checked against the favorites pages.
        final key = credentials.read(server.id);
        final website = BooruAccountParser.gelbooruIdentity(_cookies(server))?.userID;
        if (server.engine == BooruEngine.gelbooru && website == null && !key.isEmpty) {
          try {
            found = await _gelbooruAPIFavorites(server, user);
            if (found.isEmpty) found = null;
          } on Object {
            found = null;
          }
        }
        found ??= await _favoritesPages(server, user);
        for (final post in found) {
          (members[post.postID] ??= {}).add(main);
          posts[post.postID] = post;
        }
        lists.add(FavoriteCategory(id: main, name: L10n.text('Favorites'), count: found.length));
      case BooruEngine.moebooru:
        if (account.name.isEmpty) throw const BooruError(BooruErrorKind.authentication);
        for (var page = 1; page <= 200; page++) {
          final data = await send(server, 'GET', 'post.json', query: [('tags', 'vote:3:${account.name} order:vote'), ('limit', '100'), ('page', '$page')]);
          final rows = BooruDecoder.rows(data, 'post');
          for (final row in rows) {
            try {
              final post = BooruDecoder.post(row, server);
              (members[post.postID] ??= {}).add(main);
              posts[post.postID] = post;
            } on Object {
              continue;
            }
          }
          if (rows.length < 100) break;
        }
        lists.add(FavoriteCategory(id: main, name: L10n.text('Favorites'), count: members.length));
    }
    return BooruAccountFavorites(
      favorites: AccountFavorites(categories: lists, members: members, exclusive: false),
      posts: posts,
    );
  }

  Future<List<BooruPost>> _gelbooruAPIFavorites(BooruServer server, int user) async {
    final result = <BooruPost>[];
    final seen = <int>{};
    for (var page = 0; page < 200; page++) {
      final data = await send(
        server,
        'GET',
        'index.php',
        query: [('page', 'dapi'), ('s', 'post'), ('q', 'index'), ('json', '1'), ('tags', 'fav:$user'), ('limit', '100'), ('pid', '$page')],
      );
      final rows = BooruDecoder.rows(data, 'post');
      for (final row in rows) {
        try {
          final post = BooruDecoder.post(row, server);
          if (seen.add(post.postID)) result.add(post);
        } on Object {
          continue;
        }
      }
      if (rows.length < 100) break;
    }
    return result;
  }

  /// The account's favorites pages, read until a page brings nothing new.
  Future<List<BooruPost>> _favoritesPages(BooruServer server, int user) async {
    final result = <BooruPost>[];
    final seen = <int>{};
    var offset = 0;
    for (var index = 0; index < 200; index++) {
      final data = await send(server, 'GET', 'index.php', query: [('page', 'favorites'), ('s', 'view'), ('id', '$user'), ('pid', '$offset')], html: true);
      final List<BooruPost> found;
      try {
        found = BooruLegacyHTML.posts(data, server);
      } on BooruError catch (error) {
        // Past the last page, or an account without favorites: the page shows no images at all.
        if (error.kind == BooruErrorKind.invalidResponse && BooruAccountParser.isEmptyFavoritesPage(data)) break;
        rethrow;
      }
      final page = found.where((post) => seen.add(post.postID)).toList();
      if (page.isEmpty) break;
      result.addAll(page);
      offset += page.length;
      await Future<void>.delayed(pause);
    }
    return result;
  }

  /// Adds an image to the account's favorites or one of its lists, or takes it out.
  Future<void> setFavorite(BooruServer server, int postID, int list, {required bool adds}) async {
    final id = '$postID';
    switch (server.engine) {
      case BooruEngine.danbooru when list != BooruAccounts.favoritesList:
        await send(server, 'PUT', 'favorite_groups/$list/${adds ? 'add_post' : 'remove_post'}.json', query: [('post_id', id)], form: const []);
      case BooruEngine.danbooru:
        try {
          if (adds) {
            await send(server, 'POST', 'favorites.json', query: [('post_id', id)], form: const []);
          } else {
            await send(server, 'DELETE', 'favorites/$id.json', form: const []);
          }
        } on SiteMessage catch (message) {
          // Already a favorite: what was asked for holds.
          if (!adds || !message.text.toLowerCase().contains('already')) rethrow;
        } on BooruError catch (error) {
          if (adds || error.kind != BooruErrorKind.unavailable || error.status != 404) rethrow;
        }
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        if (adds) {
          final data = await send(server, 'GET', 'public/addfav.php', query: [('id', id)], html: true, action: true);
          final answer = utf8.decode(data.length > 16 ? data.sublist(0, 16) : data, allowMalformed: true).trim();
          if (answer == '2') throw const BooruError(BooruErrorKind.authentication);
        } else {
          await send(server, 'GET', 'index.php', query: [('page', 'favorites'), ('s', 'delete'), ('id', id)], html: true, action: true);
        }
      case BooruEngine.moebooru:
        await send(server, 'POST', 'post/vote.json', form: [('id', id), ('score', adds ? '3' : '0')]);
    }
  }

  /// Images by number, for favorites read as numbers only. Missing or hidden ones are left out.
  Future<List<BooruPost>> posts(BooruServer server, List<int> ids) async {
    if (server.engine != BooruEngine.danbooru) return const [];
    final result = <BooruPost>[];
    for (var start = 0; start < ids.length; start += 100) {
      if (start > 0) await Future<void>.delayed(pause);
      final chunk = ids.sublist(start, start + 100 > ids.length ? ids.length : start + 100);
      final data = await send(server, 'GET', 'posts.json', query: [('tags', 'id:${chunk.join(',')}'), ('limit', '100'), ('only', BooruClient.postFields)]);
      for (final row in BooruDecoder.rows(data, 'post')) {
        try {
          result.add(BooruDecoder.post(row, server));
        } on Object {
          continue;
        }
      }
    }
    return result;
  }

  Future<BooruVote> vote(BooruServer server, int postID, BooruAccountIdentity account) async {
    final user = account.userID;
    if (server.engine != BooruEngine.danbooru || user == null) return const BooruVote();
    final data = await send(
      server,
      'GET',
      'post_votes.json',
      query: [('search[post_id]', '$postID'), ('search[user_id]', '$user'), ('search[is_deleted]', 'false'), ('limit', '1'), ('only', 'id,score')],
    );
    final row = BooruDecoder.rows(data, 'post-vote').firstOrNull;
    if (row == null) return const BooruVote();
    return BooruVote(id: BooruDecoder.integer(row['id']), score: BooruDecoder.integer(row['score']).sign);
  }

  /// Votes an image up or down, or withdraws the account's vote (0); returns the image's score
  /// as it now stands, when the server tells it.
  Future<int?> castVote(BooruServer server, int postID, int score, BooruVote current) async {
    switch (server.engine) {
      case BooruEngine.danbooru:
        if (score == 0) {
          final vote = current.id;
          if (vote == null) return null;
          await send(server, 'DELETE', 'post_votes/$vote.json', form: const []);
        } else {
          await send(server, 'POST', 'posts/$postID/votes.json', query: [('score', '${score.sign}')], form: const []);
        }
        final data = await send(server, 'GET', 'posts/$postID.json', query: const [('only', 'score')]);
        final object = jsonDecode(utf8.decode(data));
        return object is Map ? BooruDecoder.integer(object['score']) : null;
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        if (score <= 0) throw const BooruError(BooruErrorKind.unsupported);
        final data = await send(
          server,
          'GET',
          'index.php',
          query: [('page', 'post'), ('s', 'vote'), ('id', '$postID'), ('type', 'up')],
          html: true,
          action: true,
        );
        return int.tryParse(utf8.decode(data.length > 32 ? data.sublist(0, 32) : data, allowMalformed: true).trim());
      case BooruEngine.moebooru:
        throw const BooruError(BooruErrorKind.unsupported);
    }
  }

  /// An image's comments, oldest first. Every server shows them without an account.
  Future<List<WorkComment>> comments(BooruServer server, int postID) async {
    final id = '$postID';
    switch (server.engine) {
      case BooruEngine.danbooru:
        final data = await send(
          server,
          'GET',
          'comments.json',
          query: [('search[post_id]', id), ('group_by', 'comment'), ('limit', '1000'), ('only', 'id,body,score,created_at,is_deleted,creator[name]')],
        );
        return BooruAccountParser.danbooruComments(data);
      case BooruEngine.moebooru:
        return BooruAccountParser.moebooruComments(await send(server, 'GET', 'comment.json', query: [('post_id', id)]));
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        if (server.engine == BooruEngine.gelbooru) {
          // DAPI keeps comments on the main site; installs that answer it with nothing show them on the page.
          try {
            final data = await send(server, 'GET', 'index.php', query: [('page', 'dapi'), ('s', 'comment'), ('q', 'index'), ('post_id', id)]);
            final found = BooruAccountParser.gelbooruAPIComments(data);
            if (found.isNotEmpty) return found;
          } on Object {
            // The post's page shows them instead.
          }
        }
        final page = await send(server, 'GET', 'index.php', query: [('page', 'post'), ('s', 'view'), ('id', id)], html: true);
        return BooruAccountParser.gelbooruPageComments(utf8.decode(page, allowMalformed: true));
    }
  }

  /// Posts a comment under the image as the signed-in account, and returns the comments as they now stand.
  Future<List<WorkComment>> postComment(BooruServer server, int postID, String text) async {
    final id = '$postID';
    final body = text.trim();
    if (body.isEmpty) return comments(server, postID);
    switch (server.engine) {
      case BooruEngine.danbooru:
        await send(server, 'POST', 'comments.json', form: [('comment[post_id]', id), ('comment[body]', body)]);
      case BooruEngine.moebooru:
        await send(server, 'POST', 'comment/create.json', form: [('comment[post_id]', id), ('comment[body]', body)]);
      case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
        // The post's own page offers the form to a signed-in account; it is sent as the page would.
        final page = await send(server, 'GET', 'index.php', query: [('page', 'post'), ('s', 'view'), ('id', id)], html: true);
        final form = BooruAccountParser.commentForm(utf8.decode(page, allowMalformed: true), body);
        if (form == null) {
          throw SiteMessage(L10n.text('The website didn’t offer this account a comment form here. Open the image on the website to comment.'));
        }
        final root = server.baseURL.endsWith('/') ? server.baseURL : '${server.baseURL}/';
        final target = Uri.parse(root).resolve('index.php').resolve(form.action);
        if (!booruSameOrigin(target.toString(), server.baseURL)) throw const BooruError(BooruErrorKind.invalidResponse);
        await send(server, 'POST', '', form: form.fields, html: true, target: target);
    }
    return comments(server, postID);
  }
}

/// Reads what the account requests answer. Only page structure and response fields are matched.
abstract final class BooruAccountParser {
  /// A website page with no image on it, as a favorites page is past its last page or for an account
  /// without favorites. A bot check's page or a page whose images weren't recognized is not one.
  static bool isEmptyFavoritesPage(List<int> data) {
    final html = utf8.decode(data, allowMalformed: true).toLowerCase();
    if (!html.contains('<body')) return false;
    if (['challenge-form', 'cf-chl', 'just a moment', 'checking your browser'].any(html.contains)) return false;
    return !RegExp(r'page=post(&|&amp;)s=view(&|&amp;)id=\d').hasMatch(html) &&
        !['class="thumb', 'thumbnail-preview', 'thumbnail-container'].any(html.contains);
  }

  static String? csrfToken(String html) {
    for (final match in BooruHTML.matches(r'<meta\b([^>]*)>', html)) {
      final attributes = BooruHTML.attributes(match[1]);
      final token = attributes['content'];
      if (attributes['name'] == 'csrf-token' && token != null && token.isNotEmpty) return token;
    }
    return null;
  }

  static BooruAccountIdentity? danbooruIdentity(Uint8List data) {
    try {
      final object = jsonDecode(utf8.decode(data));
      if (object is! Map) return null;
      final id = BooruDecoder.integer(object['id']);
      if (id <= 0) return null;
      return BooruAccountIdentity(userID: id, name: object['name'] as String? ?? '');
    } on Object {
      return null;
    }
  }

  static BooruAccountIdentity? gelbooruIdentity(List<BooruCookie> cookies) {
    final user = int.tryParse(cookies.where((cookie) => cookie.name == 'user_id').firstOrNull?.value ?? '');
    if (user == null || user <= 0 || !cookies.any((cookie) => cookie.name == 'pass_hash' && cookie.value.isNotEmpty)) return null;
    return BooruAccountIdentity(userID: user);
  }

  static BooruAccountIdentity? moebooruIdentity(List<BooruCookie> cookies) {
    final login = cookies.where((cookie) => cookie.name == 'login').firstOrNull?.value ?? '';
    if (login.isEmpty || !cookies.any((cookie) => cookie.name == 'pass_hash' && cookie.value.isNotEmpty)) return null;
    String name;
    try {
      name = Uri.decodeComponent(login);
    } on Object {
      name = login;
    }
    return BooruAccountIdentity(name: name);
  }

  /// The API key and user id Gelbooru's account settings page shows for API access.
  static (String, int)? gelbooruAPIKey(String html) {
    final match = BooruHTML.matches(r'api_key=([0-9A-Za-z]{16,128})&user_id=([0-9]{1,12})', BooruHTML.decode(html)).firstOrNull;
    final user = match == null ? null : int.tryParse(match[2]);
    if (match == null || user == null || user <= 0) return null;
    return (match[1], user);
  }

  static DateTime? date(Object? value) {
    if (value is num) return DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true);
    if (value is Map && value['s'] is num) return DateTime.fromMillisecondsSinceEpoch(((value['s'] as num) * 1000).round(), isUtc: true);
    final text = value is String ? value.trim() : '';
    if (text.isEmpty) return null;
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso;
    final plain = RegExp(r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$').firstMatch(text);
    if (plain != null) {
      int part(int index) => int.parse(plain.group(index) ?? '0');
      return DateTime.utc(part(1), part(2), part(3), part(4), part(5), plain.group(6) == null ? 0 : part(6));
    }
    return null;
  }

  /// DText as plain text: quotes become quoted lines, links keep their words, markup goes.
  static String plainDText(String text) {
    var value = text.replaceAll('\r\n', '\n');
    value = value.replaceAllMapped(RegExp(r'\[quote\](.*?)\[/quote\]', caseSensitive: false, dotAll: true), (match) => '“${match[1]}”\n');
    value = value.replaceAllMapped(RegExp(r'"([^"\n]+)":\[?(?:https?://|/)[^\s\]]+\]?'), (match) => match[1]!);
    value = value.replaceAllMapped(RegExp(r'\[\[([^\]|]+)\|([^\]]+)\]\]'), (match) => match[2]!);
    value = value.replaceAllMapped(RegExp(r'\[\[([^\]]+)\]\]'), (match) => match[1]!);
    value = value.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (match) => match[1]!);
    value = value.replaceAll(RegExp(r'\[/?(?:b|i|u|s|tn|spoilers?|code|nodtext|expand[^\]]*|url[^\]]*|br)\]', caseSensitive: false), '');
    return value.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static List<WorkComment> danbooruComments(Uint8List data) {
    List<Map<String, Object?>> rows;
    try {
      rows = BooruDecoder.rows(data, 'comment');
    } on Object {
      rows = const [];
    }
    final result = <WorkComment>[];
    for (final row in rows) {
      final id = BooruDecoder.integer(row['id']);
      final body = row['body'];
      if (id <= 0 || row['is_deleted'] == true || body is! String) continue;
      final creator = row['creator'];
      final author = (creator is Map ? creator['name'] as String? : null) ?? row['creator_name'] as String? ?? '?';
      final text = plainDText(body);
      if (text.isEmpty) continue;
      result.add(
        WorkComment(
          id: id,
          author: author.replaceAll('_', ' '),
          posted: date(row['created_at']),
          score: row.containsKey('score') ? BooruDecoder.integer(row['score']) : null,
          text: text,
        ),
      );
    }
    return result..sort((a, b) => a.id.compareTo(b.id));
  }

  static List<WorkComment> moebooruComments(Uint8List data) {
    List<Map<String, Object?>> rows;
    try {
      rows = BooruDecoder.rows(data, 'comment');
    } on Object {
      rows = const [];
    }
    final result = <WorkComment>[];
    for (final row in rows) {
      final id = BooruDecoder.integer(row['id']);
      final body = row['body'];
      if (id <= 0 || body is! String) continue;
      final text = plainDText(body);
      if (text.isEmpty) continue;
      result.add(WorkComment(id: id, author: row['creator'] as String? ?? '?', posted: date(row['created_at']), text: text));
    }
    return result..sort((a, b) => a.id.compareTo(b.id));
  }

  static List<WorkComment> gelbooruAPIComments(Uint8List data) {
    final result = <WorkComment>[];
    for (final row in BooruDecoder.rows(data, 'comment')) {
      final id = BooruDecoder.integer(row['id']);
      final body = row['body'];
      if (id <= 0 || body is! String) continue;
      final text = BooruHTML.plainText(BooruHTML.decode(body));
      if (text.isEmpty) continue;
      result.add(WorkComment(id: id, author: row['creator'] as String? ?? '?', posted: date(row['created_at']), text: text));
    }
    return result..sort((a, b) => a.id.compareTo(b.id));
  }

  /// Comments on a Gelbooru-style post page, in either of the two shapes those pages use: a block
  /// per comment named `c<number>` with the author and date in one column and the text in the
  /// other, or a `commentBody` block whose first bold or linked name is the author.
  static List<WorkComment> gelbooruPageComments(String html) {
    final result = <WorkComment>[];
    final seen = <int>{};
    for (final block in html.split('<div id="c').skip(1)) {
      final digits = RegExp(r'^[0-9]+').firstMatch(block)?.group(0);
      final id = digits == null ? null : int.tryParse(digits);
      if (id == null || id <= 0 || !seen.add(id)) continue;
      final first = BooruHTML.matches(r'''class\s*=\s*["']col1["'][^>]*>(.*?)</div>''', block).firstOrNull?[1] ?? '';
      final second = BooruHTML.matches(r'''class\s*=\s*["']col2["'][^>]*>(.*?)</div>''', block).firstOrNull?[1] ?? '';
      final author = BooruHTML.matches(r'<a\b[^>]*>(.*?)</a>', first).map((match) => BooruHTML.plainText(match[1])).firstOrNull ?? '?';
      final posted = BooruHTML.matches(r'(?:Posted on|commented at)\s+([0-9-]+\s+[0-9:]+)', first).map((match) => date(match[1])).firstOrNull;
      final score = BooruHTML.matches(r'Score:\s*(?:<[^>]*>\s*)*(-?[0-9]+)', first).map((match) => int.tryParse(match[1])).firstOrNull;
      final text = BooruHTML.plainText(second);
      if (text.isEmpty) continue;
      result.add(WorkComment(id: id, author: author.isEmpty ? '?' : author, posted: posted, score: score, text: text));
    }
    if (result.isNotEmpty) return result..sort((a, b) => a.id.compareTo(b.id));
    for (final block in html.split('commentBody').skip(1)) {
      // A block ends where the next comment, the paginator or the comment form begins.
      final content = block.split('<form').first.split('id="paginator').first;
      final id = BooruHTML.matches(r'#([0-9]{1,12})', content).map((match) => int.tryParse(match[1])).firstOrNull;
      if (id == null || !seen.add(id)) continue;
      final named = BooruHTML.matches(r'<b\b[^>]*>(.*?)</b>', content).firstOrNull ?? BooruHTML.matches(r'<a\b[^>]*>(.*?)</a>', content).firstOrNull;
      final author = named == null ? '?' : BooruHTML.plainText(named[1]);
      final posted = BooruHTML.matches(r'(?:commented at|Posted on)\s+([0-9-]+\s+[0-9:]+)', content).map((match) => date(match[1])).firstOrNull;
      final score = BooruHTML.matches(r'Score:\s*(?:<[^>]*>\s*)*(-?[0-9]+)', content).map((match) => int.tryParse(match[1])).firstOrNull;
      var text = BooruHTML.plainText(content.replaceFirst(RegExp(r'^[^>]*>'), ''));
      for (final noise in [author, '#$id']) {
        if (noise.isNotEmpty) text = text.replaceFirst(noise, '');
      }
      text = text
          .replaceAll(RegExp(r'(commented at|Posted on)\s+[0-9-]+\s+[0-9:]+', caseSensitive: false), '')
          .replaceAll(RegExp(r'Score:\s*-?[0-9]+', caseSensitive: false), '')
          .replaceAll(RegExp(r'\(\s*vote\s+up\s*\)|\(\s*report comment\s*\)|report comment', caseSensitive: false), '')
          .trim()
          .replaceAll(RegExp(r'^[>|\-·\s]+|[>|\-·\s]+$'), '');
      if (text.isEmpty) continue;
      result.add(WorkComment(id: id, author: author.isEmpty ? '?' : author, posted: posted, score: score, text: text));
    }
    return result..sort((a, b) => a.id.compareTo(b.id));
  }

  /// The page's comment form filled with the text: its hidden fields and first submit button as
  /// the page has them, without posting anonymously.
  static ({String action, List<(String, String)> fields})? commentForm(String html, String text) {
    for (final form in BooruHTML.matches(r'<form\b([^>]*)>(.*?)</form>', html)) {
      final attributes = BooruHTML.attributes(form[1]);
      final action = attributes['action'] ?? '';
      final textareas = [for (final match in BooruHTML.matches(r'<textarea\b([^>]*)>', form[2])) ?BooruHTML.attributes(match[1])['name']];
      final field =
          textareas.where((name) => name.toLowerCase().contains('comment')).firstOrNull ?? (action.contains('comment') ? textareas.firstOrNull : null);
      if (field == null || !(action.contains('comment') || field.toLowerCase() == 'comment') || (attributes['method'] ?? 'post').toLowerCase() != 'post') {
        continue;
      }
      final fields = <(String, String)>[(field, text)];
      var submitted = false;
      for (final input in BooruHTML.matches(r'<input\b([^>]*)>', form[2])) {
        final values = BooruHTML.attributes(input[1]);
        final name = values['name'];
        if (name == null || name.isEmpty) continue;
        switch ((values['type'] ?? 'text').toLowerCase()) {
          case 'hidden':
            fields.add((name, name.toLowerCase() == 'conf' ? '1' : values['value'] ?? ''));
          case 'submit' when !submitted:
            fields.add((name, values['value'] ?? ''));
            submitted = true;
          case 'checkbox' || 'radio':
            // Anonymous posting stays off; other boxes keep what the page checked.
            if (input[1].toLowerCase().contains('checked') && !name.toLowerCase().contains('anonymous')) fields.add((name, values['value'] ?? 'on'));
          case 'text':
            if (!name.toLowerCase().contains('captcha')) fields.add((name, values['value'] ?? ''));
        }
      }
      return (action: BooruHTML.decode(action), fields: fields);
    }
    return null;
  }
}

/// Lets the comments views read and write an image server's comments.
class BooruCommentProvider implements WorkExtrasProviding {
  BooruCommentProvider(this.server, {BooruAccountClient? client}) : client = client ?? BooruAccountClient.shared;
  final BooruServer server;
  final BooruAccountClient client;

  @override
  Future<WorkExtras?> extras(int id) async => null;
  @override
  Future<List<WorkComment>> allComments(int id) => client.comments(server, id);
  @override
  Future<List<WorkComment>> postComment(int id, String text) => client.postComment(server, id, text);
  @override
  Future<(double, int)> rate(int id, int halfStars) => throw const BooruError(BooruErrorKind.unsupported);
  @override
  Future<List<WorkTagVote>> voteTag(int id, {required String tag, required int vote}) => throw const BooruError(BooruErrorKind.unsupported);
  @override
  Future<WorkArchiveOffer> archiveOffer(int id) => throw const BooruError(BooruErrorKind.unsupported);
  @override
  Future<Uri> archiveDownloadURL(int id, WorkArchiveOption option) => throw const BooruError(BooruErrorKind.unsupported);
}

extension BooruStoreAccounts on BooruStore {
  /// Which folder each saved image of a server sits in.
  Map<int, String> favoriteFolders(String serverID) => database.read(
    (db) => {
      for (final row in db.rows('SELECT post_id, folder_id FROM favorites WHERE server_id = ?', [serverID]))
        (row['post_id'] as num).toInt(): row['folder_id'] as String,
    },
  );

  BooruPost? savedPost(String serverID, int postID) => database.read((db) {
    final data = db.value<Uint8List>('SELECT payload FROM favorites WHERE server_id = ? AND post_id = ?', [serverID, postID]);
    return data == null ? null : BooruPost.fromJson(decodeJsonObject(data));
  });

  Set<String> folderIDs() => database.read((db) => db.column<String>('SELECT id FROM folders').toSet());

  /// What a favorites sync changes in the library, in one write: images the server no longer
  /// keeps, images moved between folders ('' is the server's own folder), and images new to the
  /// app, into a list's folder or where a save without a folder goes.
  void applySyncedFavorites(
    String serverID, {
    List<int> removals = const [],
    Map<int, String> moves = const {},
    List<(BooruPost, String?)> additions = const [],
  }) {
    if (removals.isEmpty && moves.isEmpty && additions.isEmpty) return;
    database.write((db) {
      final landing = BooruStore.defaultFolder(serverID, db);
      for (final id in removals) {
        final data = db.value<Uint8List>('SELECT payload FROM favorites WHERE server_id = ? AND post_id = ?', [serverID, id]);
        if (data == null) continue;
        TasteStore.record(TasteEventKind.remove, BooruStore.tasteItem(BooruPost.fromJson(decodeJsonObject(data)), db), db);
        db.execute('DELETE FROM favorites WHERE server_id = ? AND post_id = ?', [serverID, id]);
      }
      for (final MapEntry(key: id, value: folder) in moves.entries) {
        db.execute('UPDATE favorites SET folder_id = ? WHERE server_id = ? AND post_id = ?', [folder.isEmpty ? landing : folder, serverID, id]);
      }
      final now = unixSeconds();
      for (final (index, (post, folder)) in additions.indexed) {
        if (post.serverID != serverID) continue;
        final target = folder ?? BooruStoreFolderRules.smartDestination(post, landing, db, preferences.defaults);
        // Each keeps its own moment, so the order they came in stays.
        db.execute('INSERT OR IGNORE INTO favorites (server_id, post_id, payload, saved_at, folder_id) VALUES (?, ?, ?, ?, ?)', [
          serverID,
          post.postID,
          encodeSwiftJson(post.toJson()),
          now - index * 0.001,
          target,
        ]);
        if (db.changesCount > 0) TasteStore.record(TasteEventKind.imported, BooruStore.tasteItem(post, db), db);
      }
    });
    refresh();
  }
}

/// `BooruAccountSync`: keeps each signed-in image server's favorites and the app's folders the
/// same, the way comics websites' favorites are kept: the account's own favorites hold images saved
/// in any folder that isn't a list's, and each named list that holds images (Danbooru's favorite
/// groups) becomes a folder of the same name. What was added, removed or moved on one side since
/// the last sync is done on the other; when both changed the same place, the website wins.
class BooruAccountSync extends ChangeNotifier {
  BooruAccountSync({required this.store, required this.accounts, BooruAccountClient? client}) : client = client ?? BooruAccountClient.shared;

  static BooruAccountSync? shared;

  final BooruStore store;
  final BooruAccounts accounts;
  final BooruAccountClient client;

  /// Servers whose sign-in the website no longer accepts.
  final expired = <String>{};

  /// The names of each server's favorites lists, as last read.
  final listNames = <String, Map<int, String>>{};
  final _syncing = <String>{};
  StreamSubscription<int>? _changes;
  Timer? _settle;

  /// At most this many favorites change on a server in one sync; the rest wait for the next.
  static const sendsPerSync = 30;

  /// At most this many images are looked up by number in one sync.
  static const lookupsPerSync = 1000;

  /// The wait between two changes sent to a server.
  Duration sendGap = const Duration(milliseconds: 500);

  BooruAccountIdentity? identity(BooruServer server) => accounts.identity(server.id);
  SiteFavoriteState? state(BooruServer server) => accounts.favorites.state(server.id);

  /// A sign-in finished on the server's own page: the account is kept, and its favorites are
  /// brought in unless the sync was turned off before.
  Future<void> signedIn(BooruServer server, BooruAccountIdentity identity) async {
    accounts.setIdentity(identity, server.id);
    expired.remove(server.id);
    store.clearGoldRestrictions(serverID: server.id);
    notifyListeners();
    final completed = await client.completeSignIn(server, identity);
    if (completed != identity) {
      accounts.setIdentity(completed, server.id);
      notifyListeners();
    }
    await setUp(server);
  }

  final _looked = <String>{};

  /// Finds an account the server already knows this device by: an API key saved in the server's
  /// settings, or a sign-in its pages kept. Each server is asked once a session unless [force]d,
  /// as after its account details are saved.
  Future<void> discover(BooruServer server, {bool force = false}) async {
    if (accounts.identity(server.id) != null || !force && _looked.contains(server.id)) return;
    _looked.add(server.id);
    if (!client.mayHaveAccount(server)) {
      refusedKeys.remove(server.id);
      return;
    }
    final BooruAccountIdentity? identity;
    try {
      identity = await client.identity(server);
    } on BooruError catch (error) {
      // The website turned the saved account details down; the settings say so.
      if (error.kind == BooruErrorKind.authentication) {
        refusedKeys.add(server.id);
        notifyListeners();
      }
      return;
    } on Object {
      return;
    }
    if (identity == null) {
      // A saved key that names no account, such as Gelbooru's user name in place of its user id.
      if (!client.credentials.read(server.id).isEmpty) {
        refusedKeys.add(server.id);
        notifyListeners();
      }
      return;
    }
    refusedKeys.remove(server.id);
    if (accounts.identity(server.id) != null) return;
    await signedIn(server, identity);
  }

  /// Servers whose saved account details the website turned down.
  final refusedKeys = <String>{};

  /// Reads which account the server's pages are signed in with now.
  Future<BooruAccountIdentity?> check(BooruServer server) async {
    try {
      return await client.identity(server);
    } on Object {
      return null;
    }
  }

  Future<void> signOut(BooruServer server) async {
    accounts.setIdentity(null, server.id);
    accounts.favorites.remove(server.id, declined: false);
    // An API key saved for the account goes too, or the next launch would sign it back in.
    client.credentials.save(const BooruCredentials(), server.id);
    _looked.add(server.id);
    expired.remove(server.id);
    client.forgetSession(server);
    // The sign-in lives in the server's cookies; a bot check passed there stays.
    final session = client.session;
    for (final cookie in session.cookies(server)) {
      if (!SiteClearance.isClearanceCookie(cookie.name)) {
        session.setCookie(
          BooruCookie(name: cookie.name, value: '', domain: cookie.domain, path: cookie.path, expiresDate: DateTime.fromMillisecondsSinceEpoch(0)),
          server,
        );
      }
    }
    BooruWebTransport.reset(server);
    store.clearGoldRestrictions(serverID: server.id);
    notifyListeners();
  }

  /// The first time a signed-in server's favorites can be read: each named list that holds images
  /// becomes a folder of the same name, and the account's favorites keep images saved elsewhere.
  Future<void> setUp(BooruServer server, {bool requested = false}) async {
    final favorites = accounts.favorites;
    final identity = accounts.identity(server.id);
    if (favorites.state(server.id) != null || !requested && favorites.isDeclined(server.id) || identity == null) return;
    BooruAccountFavorites fetched;
    try {
      fetched = await client.favorites(server, identity);
    } on Object catch (error) {
      debugPrint('Booru favorites read failed for ${server.engine.name}: $error');
      // Turned on by hand, the person sees why it couldn't start.
      if (requested) rethrow;
      return;
    }
    _remember(fetched, server);
    final state = SiteFavoriteState(unassigned: BooruAccounts.favoritesList, exclusive: false);
    _linkListFolders(fetched.favorites, server, state);
    favorites.setState(state, server.id);
    notifyListeners();
    try {
      await sync(server, remote: fetched);
    } on Object {
      // The next sync tries again.
    }
  }

  void stop(BooruServer server) {
    accounts.favorites.remove(server.id, declined: true);
    notifyListeners();
  }

  /// Where images in other folders are kept on the server: the account's favorites, or null for the app only.
  void setOtherFoldersList(int? list, BooruServer server) {
    final state = accounts.favorites.state(server.id);
    if (state == null) return;
    state.unassigned = list;
    accounts.favorites.setState(state, server.id);
    notifyListeners();
  }

  /// Whether a folder stands for a signed-in server's favorites list, which can't be deleted while synced.
  bool isListFolder(String folderID) =>
      store.servers.any((server) => accounts.identity(server.id) != null && (accounts.favorites.state(server.id)?.folders.values.contains(folderID) ?? false));

  void _remember(BooruAccountFavorites read, BooruServer server) {
    listNames[server.id] = {for (final list in read.favorites.categories) list.id: list.name};
  }

  String _listFolderName(FavoriteCategory list, BooruServer server) =>
      list.id == BooruAccounts.favoritesList ? L10n.text('%@ Favorites', [server.displayName]) : list.name;

  /// Gives each list that holds images a folder of its name, or the unlinked folder already named
  /// so, apart from the list kept for other folders. Returns the lists linked now.
  Set<int> _linkListFolders(AccountFavorites favorites, BooruServer server, SiteFavoriteState state) {
    final linked = <int>{};
    final taken = {for (final other in store.servers) ...?accounts.favorites.state(other.id)?.folders.values, ...state.folders.values};
    for (final list in favorites.categories) {
      if (list.count <= 0 || state.folders.containsKey(list.id) || list.id == state.unassigned) continue;
      final name = _listFolderName(list, server);
      // Only this server's own folders: another server's folder of the same name is its own.
      final reusable = store
          .folders()
          .where((folder) => folder.serverID == server.id && folder.plainName == name && !folder.isUncategorized && !taken.contains(folder.id))
          .firstOrNull;
      final id = reusable?.id ?? store.saveFolder(name: name, serverID: server.id);
      state.folders[list.id] = id;
      taken.add(id);
      linked.add(list.id);
    }
    return linked;
  }

  /// A list and its folder come and go together: a list left empty whose folder is empty loses the
  /// folder, unless it is a smart folder whose rule would be lost.
  void _dropEmptiedListFolders(SiteFavoriteState state, Map<int, Set<int>> settled) {
    final used = {for (final lists in settled.values) ...lists};
    final saved = store.database.read((db) => db.column<String>('SELECT DISTINCT folder_id FROM favorites').toSet());
    final smart = {
      for (final folder in store.folders())
        if (folder.isSmart) folder.id,
    };
    for (final MapEntry(key: list, value: folder) in {...state.folders}.entries) {
      if (used.contains(list) || saved.contains(folder) || smart.contains(folder)) continue;
      store.deleteFolder(folder);
      state.folders.remove(list);
    }
  }

  /// Where each saved image of the server sits. An image in a list's folder keeps the other lists
  /// it was in at the last sync: one folder stands for all of them. Moved to another list's folder,
  /// it leaves them.
  static Map<int, Set<FavoritePlace>> places(Map<int, String> saved, SiteFavoriteState state) {
    final listOf = <String, int>{};
    for (final MapEntry(key: list, value: folder) in state.folders.entries) {
      final existing = listOf[folder];
      listOf[folder] = existing == null || list < existing ? list : existing;
    }
    final result = <int, Set<FavoritePlace>>{};
    for (final MapEntry(key: post, value: folder) in saved.entries) {
      final list = listOf[folder];
      if (list == null) {
        result[post] = {FavoritePlace.unassigned};
        continue;
      }
      final before = (state.baseline?[post] ?? const <int>{}).where(state.folders.containsKey).toSet();
      result[post] = before.contains(list) ? {for (final each in before) FavoritePlace.category(each)} : {FavoritePlace.category(list)};
    }
    return result;
  }

  /// Brings a server's favorites and the folders into step. [pull] reads the server again; without
  /// it only changes made in the app are sent.
  Future<FavoriteSyncPlan?> sync(BooruServer server, {bool pull = true, BooruAccountFavorites? remote}) async {
    final favoritesStore = accounts.favorites;
    final state = favoritesStore.state(server.id);
    final identity = accounts.identity(server.id);
    if (state == null || identity == null || !_syncing.add(server.id)) return null;
    try {
      final folders = store.folderIDs();
      var missing = false;
      for (final MapEntry(key: list, value: folder) in {...state.folders}.entries) {
        if (!folders.contains(folder)) {
          state.folders.remove(list);
          missing = true;
        }
      }
      var read = remote;
      if (read == null && (pull || missing || state.baseline == null)) {
        try {
          read = await client.favorites(server, identity);
        } on BooruError catch (error) {
          if (error.kind == BooruErrorKind.authentication) {
            expired.add(server.id);
            notifyListeners();
          }
          rethrow;
        }
      }
      expired.remove(server.id);
      final Map<int, Set<int>> remoteMembers;
      if (read != null) {
        _remember(read, server);
        remoteMembers = read.favorites.members;
        state.lastPull = DateTime.now();
        final existing = {for (final list in read.favorites.categories) list.id};
        state.folders.removeWhere((list, _) => !existing.contains(list));
        final linked = _linkListFolders(read.favorites, server, state);
        if (linked.isNotEmpty && state.baseline != null) {
          state.baseline = {for (final MapEntry(:key, :value) in state.baseline!.entries) key: value.difference(linked)};
        }
      } else {
        remoteMembers = state.baseline ?? {};
      }
      final plan = FavoriteSyncPlan.make(
        local: places(store.favoriteFolders(server.id), state),
        remote: remoteMembers,
        base: state.baseline,
        folders: state.folders.keys.toSet(),
        unassigned: state.unassigned,
        localOnly: state.localOnly,
        exclusive: false,
      );
      final settled = {...plan.settled};
      state.localOnly
        ..addAll(plan.keepLocal)
        ..removeAll(plan.stopKeepingLocal);
      state.baseline = {...settled};
      favoritesStore.setState(state, server.id);

      // Images new to the app: the answers' own descriptions, or a lookup by number.
      final described = {...?read?.posts};
      final saved = store.favoriteFolders(server.id);
      final unknown = [
        for (final MapEntry(key: id, value: places) in plan.local.entries)
          if (places.isNotEmpty && !saved.containsKey(id) && !described.containsKey(id)) id,
      ];
      if (unknown.isNotEmpty) {
        try {
          for (final post in await client.posts(server, unknown.take(lookupsPerSync).toList())) {
            described[post.postID] = post;
          }
        } on Object {
          // Left for the next sync.
        }
      }
      final listFolders = state.folders.values.toSet();
      final removals = <int>[];
      final moves = <int, String>{};
      final additions = <(BooruPost, String?)>[];
      for (final MapEntry(key: id, value: places) in plan.local.entries) {
        if (places.isEmpty) {
          removals.add(id);
          continue;
        }
        final targets = [
          for (final list in ([for (final place in places) ?place.category]..sort())) ?state.folders[list],
        ];
        final current = saved[id];
        if (current != null) {
          if (targets.isNotEmpty && !targets.contains(current)) {
            moves[id] = targets.first;
          } else if (targets.isEmpty && listFolders.contains(current)) {
            moves[id] = '';
          }
        } else if (described[id] case final post?) {
          additions.add((post, targets.firstOrNull));
        } else {
          // Not described yet: it comes again with the next sync instead of counting as removed here.
          settled.remove(id);
        }
      }
      store.applySyncedFavorites(server.id, removals: removals, moves: moves, additions: additions);
      var sent = 0;
      // Without a sign-in that can change things, changes wait until there is one.
      var failed = plan.site.isNotEmpty && !client.canChange(server);
      final refused = <int>{};
      for (final change in plan.site) {
        if (failed || sent >= sendsPerSync || refused.contains(change.id)) {
          if (!refused.contains(change.id)) _settle1(settled, change.id, remoteMembers);
          continue;
        }
        if (sent > 0) await Future<void>.delayed(sendGap);
        sent += 1;
        try {
          await client.setFavorite(server, change.id, change.category, adds: change.adds);
        } on BooruError catch (error) {
          if (change.adds && error.kind == BooruErrorKind.unavailable && [404, 410, 422].contains(error.status)) {
            refused.add(change.id);
          } else {
            failed = true;
            _settle1(settled, change.id, remoteMembers);
          }
        } on SiteMessage {
          if (change.adds) {
            refused.add(change.id);
          } else {
            failed = true;
            _settle1(settled, change.id, remoteMembers);
          }
        } on Object {
          failed = true;
          _settle1(settled, change.id, remoteMembers);
        }
      }
      for (final id in refused) {
        state.localOnly.add(id);
        _settle1(settled, id, remoteMembers);
      }
      if (read != null) _dropEmptiedListFolders(state, settled);
      state.baseline = settled;
      favoritesStore.setState(state, server.id);
      notifyListeners();
      return plan;
    } finally {
      _syncing.remove(server.id);
    }
  }

  /// `settled[id] = remote[id]`, where a missing value removes the entry.
  static void _settle1(Map<int, Set<int>> settled, int id, Map<int, Set<int>> remote) {
    final value = remote[id];
    if (value == null) {
      settled.remove(id);
    } else {
      settled[id] = value;
    }
  }

  /// While the app is in front: sets up servers signed in since, reads each server's favorites
  /// again after half an hour, and sends changes made in the app.
  Future<void> setActive(bool active) async {
    await _changes?.cancel();
    _changes = null;
    _settle?.cancel();
    if (!active) return;
    _changes = store.database.changes.listen((_) {
      // A moment's wait gathers a burst of changes into one sync.
      _settle?.cancel();
      _settle = Timer(const Duration(seconds: 1), _sendChanges);
    });
    for (final server in store.servers) {
      if (accounts.identity(server.id) == null) await discover(server);
      if (accounts.identity(server.id) == null) continue;
      try {
        final state = accounts.favorites.state(server.id);
        if (state == null) {
          await setUp(server);
        } else if ((state.lastPull ?? DateTime(2000)).isBefore(DateTime.now().subtract(const Duration(minutes: 30)))) {
          await sync(server);
        }
      } on Object {
        // The next time the app comes to the front tries again.
      }
    }
  }

  Future<void> _sendChanges() async {
    for (final server in store.servers) {
      if (accounts.favorites.state(server.id) == null) continue;
      try {
        await sync(server, pull: false);
      } on Object {
        // Left for the next change or the next time the app comes to the front.
      }
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _settle?.cancel();
    super.dispose();
  }
}
