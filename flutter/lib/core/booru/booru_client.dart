import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../content/content_errors.dart';
import '../content/content_transport.dart';
import '../support/perf_trace.dart';
import '../support/swift_json.dart';
import 'booru_browser.dart';
import 'booru_html.dart';
import 'booru_models.dart';
import 'booru_store.dart';

abstract interface class BooruProviding {
  Future<BooruBatch> posts(BooruServer server, String query, int page);
  Future<List<BooruTag>> suggestions(BooruServer server, String token);
  Future<List<BooruPool>> pools(BooruServer server, String query, int page);
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page);
  Future<List<BooruNote>> notes(BooruServer server, int postID);

  /// The post with refreshed media; sources without details return [post] itself.
  Future<BooruPost> details(BooruServer server, BooruPost post);
}

class BooruTagSuggestionResponse {
  const BooruTagSuggestionResponse({required this.index, required this.server, required this.tags, this.error});
  final int index;
  final BooruServer server;
  final List<BooruTag> tags;
  final String? error;
}

class BooruTagSuggestionSearch {
  const BooruTagSuggestionSearch(this.responses);
  final List<BooruTagSuggestionResponse> responses;

  List<BooruTag> get tags {
    final found = <BooruTag>[];
    final seen = <String>{};
    // Preserve each site's alias/word-match ranking and give every selected
    // server a turn, regardless of which network request finished first.
    for (var rank = 0; rank < 12; rank++) {
      for (final response in responses) {
        if (rank >= response.tags.length) continue;
        final tag = response.tags[rank];
        if (seen.add(tag.name)) found.add(tag);
        if (found.length == 12) return found;
      }
    }
    return found;
  }

  String? get error {
    final messages = [
      for (final response in responses)
        if (response.error != null) '${response.server.displayName}: ${response.error}',
    ];
    return messages.isEmpty ? null : messages.join('\n');
  }

  static Future<BooruTagSuggestionSearch> load({required List<BooruServer> servers, required BooruProviding source, required String token}) async {
    final responses = await Future.wait([
      for (final (index, server) in servers.indexed)
        source
            .suggestions(server, token)
            .then(
              (tags) => BooruTagSuggestionResponse(index: index, server: server, tags: tags),
              onError: (Object error) =>
                  BooruTagSuggestionResponse(index: index, server: server, tags: const [], error: BooruConnectionMessage.describe(error)),
            ),
    ]);
    return BooruTagSuggestionSearch(responses);
  }
}

/// Reject API redirects across origins so credentials cannot follow a server redirect.
/// Public media may move to another host, without the profile's cookies or authorization.
abstract final class BooruRedirectPolicy {
  static Map<String, String>? redirect(Uri original, Uri next, Map<String, String> headers, {bool publicMedia = false}) {
    if (next.scheme != 'https' || next.userInfo.isNotEmpty) return null;
    if (original.host == next.host && original.port == next.port) return headers;
    if (!publicMedia) return null;
    return {
      for (final MapEntry(:key, :value) in headers.entries)
        if (key.toLowerCase() != 'cookie' && key.toLowerCase() != 'authorization') key: value,
    };
  }
}

/// Missing media or a generic 403 never prove an account restriction or removal.
enum BooruPostAccessError implements Exception {
  goldRequired,
  removed;

  static BooruPostAccessError? detect(Uint8List data, BooruServer server) {
    if (server.engine != BooruEngine.danbooru || data.length > 12000000) return null;
    final prefix = utf8.decode(data.length > 128 ? data.sublist(0, 128) : data, allowMalformed: true).trim().toLowerCase();
    if (!(prefix.startsWith('{') || prefix.startsWith('<') || prefix.startsWith('you ') || prefix.startsWith('this '))) return null;
    if (prefix.startsWith('{')) {
      try {
        final object = jsonDecode(utf8.decode(data));
        if (object is Map) return detectRow(object.cast<String, Object?>(), server);
      } on FormatException {
        // Not JSON after all; read it as text.
      }
    }
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      return null;
    }
    for (final match in BooruHTML.matches(r'<meta\b([^>]*)>', text)) {
      final attributes = BooruHTML.attributes(match[1]);
      if (['post-is-deleted', 'post-is-banned'].contains(attributes['name'] ?? '') && attributes['content'] == 'true') return removed;
    }
    // The gate is rendered in the image container. A comment, tag, navigation
    // link or upgrade advertisement must not hide a usable post.
    for (final match in BooruHTML.matches(r'''<(section|div)\b([^>]*\bclass\s*=\s*["'][^"']*\bimage-container\b[^"']*["'][^>]*)>(.*?)</\1\s*>''', text)) {
      final classes = splitClasses(BooruHTML.attributes(match[2])['class'] ?? '');
      if (classes.contains('image-container') &&
          BooruHTML.matches(r'<(?:img|video|picture)\b', match[3]).isEmpty &&
          _isGoldNotice(BooruHTML.plainText(match[3]))) {
        return goldRequired;
      }
    }
    // Some image endpoints return a bare text error instead of JSON/HTML.
    if (!text.contains('<') && _isGoldNotice(text)) return goldRequired;
    return null;
  }

  static List<String> splitClasses(String value) => value.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();

  static BooruPostAccessError? detectRow(Map<String, Object?> row, BooruServer server) {
    if (server.engine != BooruEngine.danbooru) return null;
    if (row['is_deleted'] == true || row['is_banned'] == true) return removed;
    for (final key in ['message', 'error', 'reason']) {
      final message = row[key];
      if (message is String && _isGoldNotice(message)) return goldRequired;
    }
    return null;
  }

  static final _goldNotice = RegExp(
    r'\b(?:you (?:need|must have) (?:a )?gold account to (?:see|view) this (?:image|post)|this (?:image|post) requires (?:a )?gold account)\b',
  );

  static bool _isGoldNotice(String text) => _goldNotice.hasMatch(text.toLowerCase().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' '));
}

class UnsupportedBooruSort implements Exception {
  const UnsupportedBooruSort();
}

abstract final class BooruSortValidation {
  static bool _isSortRejection(Object error) =>
      error is BooruError &&
      (error.kind == BooruErrorKind.unsupported || error.kind == BooruErrorKind.unavailable && (error.status == 400 || error.status == 422));

  static Future<BooruBatch> posts({
    required BooruProviding source,
    required BooruServer server,
    required String query,
    required int page,
    required BooruSort sort,
  }) async {
    if (!BooruSort.optionsFor(server.engine).contains(sort)) throw const UnsupportedBooruSort();
    if (sort == BooruSort.latest) return source.posts(server, query, page);
    final BooruBatch sorted;
    try {
      sorted = await source.posts(server, sort.query(query, server.engine), page);
    } catch (error) {
      if (!_isSortRejection(error)) rethrow;
      // A successful identical query without the sort operator establishes
      // that the rejected condition was the sort, not an offline server.
      BooruBatch? baseline;
      try {
        baseline = await source.posts(server, query, page);
      } on Object {
        baseline = null;
      }
      if (baseline != null && baseline.sourcePostCount > 0) throw const UnsupportedBooruSort();
      rethrow;
    }
    if (sorted.sourcePostCount == 0 && page == 0 && !sort.restrictsPeriod) {
      final baseline = await source.posts(server, query, page);
      if (baseline.sourcePostCount > 0) throw const UnsupportedBooruSort();
    }
    final scores = sorted.posts.map(sort.metric).nonNulls.toList();
    if (scores.length == sorted.posts.length && scores.toSet().length > 1) {
      for (var index = 1; index < scores.length; index++) {
        if (scores[index - 1] < scores[index]) throw const UnsupportedBooruSort();
      }
    }
    return sorted;
  }
}

/// The image-mode client. Engines are chosen by the person; what a server supports beyond
/// its engine (a public gallery in place of the API, a modern rating vocabulary, which
/// autocomplete route answers) is learned from its responses, never from its address.
class BooruClient implements BooruProviding {
  BooruClient({
    HttpFetcher? fetcher,
    BooruCredentialStore? credentials,
    BooruBrowserSession? session,
    this.poolRequestDelay = const Duration(milliseconds: 150),
  }) : browserFallback = fetcher == null,
       fetcher = fetcher ?? IoHttpFetcher(),
       _credentialStore = credentials,
       _sessionOverride = session;

  static BooruClient shared = BooruClient();
  static const pageSize = 40;

  /// Request only the fields consumed by [BooruDecoder], including blocking and media metadata.
  static const postFields =
      'id,file_url,large_file_url,preview_file_url,media_asset[variants],tag_string_copyright,tag_string_character,image_width,image_height,tag_string,tag_string_artist,tag_string_meta,rating,score,file_ext,pool_ids,fav_count,up_score,comment_count,is_banned,is_deleted';

  final HttpFetcher fetcher;
  final bool browserFallback;
  final Duration poolRequestDelay;
  final BooruCredentialStore? _credentialStore;
  final BooruBrowserSession? _sessionOverride;

  /// Where API keys are read from; the app's keystore-backed store by default.
  static BooruCredentialStore defaultCredentials = MemoryCredentialStore();

  BooruCredentialStore get credentials => _credentialStore ?? defaultCredentials;
  BooruBrowserSession get session => _sessionOverride ?? BooruBrowserSession.shared;

  final _postPages = <String, (Uint8List, DateTime)>{};
  final _pendingPostPages = <String, Future<Uint8List>>{};
  final _accessResults = <String, (bool, DateTime)>{};
  final _accessFlights = <String, Future<bool>>{};
  final _autocompleteFallbackUntil = <String, DateTime>{};
  final _autocompleteRoutes = <String, String>{};
  final _wholePools = <String, List<int>>{};
  final _poolOffsets = <String, Map<int, int>>{};
  final _publicOffsets = <String, Map<int, int>>{};
  final _publicPages = <String, Map<int, String>>{};
  final _publicGalleries = <String>{};
  final _modernRatings = <String>{};

  static String _traitKey(BooruServer server) => '${server.canonicalAddress}:${server.engine.rawValue}';

  bool _usesModernRatings(BooruServer server) => server.usesModernRatings || _modernRatings.contains(_traitKey(server));

  static bool needsBrowser(Uint8List data, int? statusCode) => BooruClientSupport.needsBrowser(data, statusCode);

  /// Credentials are only attached to API calls on the configured server.
  static BooruRequest request(BooruServer server, String path, List<(String, String)> items, {BooruCredentials credentials = const BooruCredentials()}) {
    final query = [...items];
    if (!credentials.isEmpty) {
      switch (server.engine) {
        case BooruEngine.danbooru || BooruEngine.oldGelbooru:
          break; // Old Gelbooru uses browser login; Danbooru uses HTTP Basic below.
        case BooruEngine.gelbooru:
          query.addAll([('user_id', credentials.account), ('api_key', credentials.apiKey)]);
        case BooruEngine.moebooru:
          query.addAll([('login', credentials.account), ('password_hash', credentials.apiKey)]);
      }
    }
    final base = server.baseURL.endsWith('/') ? server.baseURL : '${server.baseURL}/';
    final Uri url;
    try {
      url = Uri.parse('$base$path${query.isEmpty ? '' : '?${booruQuery(query)}'}');
    } on FormatException {
      throw const BooruError(BooruErrorKind.invalidServer);
    }
    if (url.host.isEmpty) throw const BooruError(BooruErrorKind.invalidServer);
    final request = BooruRequest(
      url,
      headers: {'User-Agent': BooruBrowserSession.shared.userAgent, 'Accept': 'application/json, application/xml;q=0.9, text/html;q=0.8'},
    );
    if (server.engine == BooruEngine.danbooru && !credentials.isEmpty) {
      request.headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('${credentials.account}:${credentials.apiKey}'))}';
    }
    return request;
  }

  /// One direct exchange with the redirect policy applied and the body capped at [limit].
  /// One direct exchange with the redirect policy applied: the final response's head (its
  /// `data` empty) and the reply whose body is still to be read. Cookies the server sets join
  /// [server]'s profile.
  Future<(BooruResponse, HttpReply)> open(BooruRequest request, {BooruServer? server, bool publicMedia = false}) async {
    var current = request.url;
    var headers = {...request.headers};
    for (var redirects = 0; ; redirects++) {
      final reply = await fetcher.send(HttpExchange(method: 'GET', url: current, headers: headers, timeout: const Duration(seconds: 30)));
      final location = reply.headers.entries.where((entry) => entry.key.toLowerCase() == 'location').firstOrNull?.value.firstOrNull;
      if (reply.statusCode >= 300 && reply.statusCode < 400 && location != null && redirects < 10) {
        final next = current.resolve(location);
        final allowed = BooruRedirectPolicy.redirect(current, next, headers, publicMedia: publicMedia);
        if (allowed != null) {
          reply.abort?.call();
          headers = allowed;
          current = next;
          continue;
        }
      }
      final response = BooruResponse(url: current, statusCode: reply.statusCode, headers: reply.headers, data: Uint8List(0));
      if (server != null) session.receive(current, response.headers['set-cookie'] ?? const [], server);
      return (response, reply);
    }
  }

  /// [open], with the body read into memory up to [limit] bytes.
  Future<BooruResponse> send(
    BooruRequest request, {
    BooruServer? server,
    bool publicMedia = false,
    int limit = 12000000,
    void Function(int received, int total)? progress,
  }) async {
    final (head, reply) = await open(request, server: server, publicMedia: publicMedia);
    final total = int.tryParse(head.headers['content-length']?.firstOrNull ?? '') ?? -1;
    if (total > limit) {
      reply.abort?.call();
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    final data = BytesBuilder(copy: false);
    try {
      await for (final chunk in reply.body.timeout(const Duration(seconds: 30))) {
        if (chunk.length > limit - data.length) throw const BooruError(BooruErrorKind.invalidResponse);
        data.add(chunk);
        progress?.call(data.length, total);
      }
    } on TimeoutException {
      throw const NetworkError(NetworkErrorCode.timedOut);
    } on IOException catch (error) {
      throw IoHttpFetcher.networkError(error);
    }
    return BooruResponse(url: head.url, statusCode: head.statusCode, headers: head.headers, data: data.takeBytes());
  }

  Future<Uint8List> _data(BooruServer server, String path, List<(String, String)> values, {bool authenticated = true, String? publicURL}) async {
    final credentials = authenticated ? this.credentials.read(server.id) : const BooruCredentials();
    final request = BooruClient.request(server, path, values, credentials: credentials);
    // The same address without the account's query credentials, for a browser that shares its script world.
    final publicRequest = BooruClient.request(server, path, values);
    if (server.engine == BooruEngine.danbooru && path.startsWith('posts/') && !path.endsWith('.json')) request.headers['Accept'] = 'text/html';
    if (publicURL != null) {
      if (authenticated || !booruSameOrigin(publicURL, server.baseURL)) throw const BooruError(BooruErrorKind.invalidServer);
      request.url = Uri.parse(publicURL);
    }
    session.prepare(request, server);
    final browser = browserFallback && BooruWebTransport.isAvailable;
    final isDocument =
        (server.engine == BooruEngine.danbooru && path == 'pools' && !authenticated) ||
        values.any((value) => value.$1 == 'page' && ['post', 'pool'].contains(value.$2));
    BooruResponse response;
    if (browser && isDocument) {
      response = await BooruWebTransport.document(request, server);
    } else if (browser && (BooruWebTransport.hasSession(server) || BooruWebTransport.prefersBrowser(server))) {
      response = await BooruWebTransport.data(request, server, publicURL: publicRequest.url);
    } else {
      try {
        final direct = await send(request, server: server);
        if (needsBrowser(direct.data, direct.statusCode)) {
          final error = BooruPostAccessError.detect(direct.data, server);
          if (error != null) throw error;
          if (browser) BooruWebTransport.directChallenged(server);
        }
        response = browser && needsBrowser(direct.data, direct.statusCode)
            ? await BooruWebTransport.data(request, server, publicURL: publicRequest.url)
            : direct;
      } on NetworkError catch (error) {
        if (!browser || ![NetworkErrorCode.secureConnectionFailed, NetworkErrorCode.networkConnectionLost].contains(error.code)) rethrow;
        response = await BooruWebTransport.data(request, server, publicURL: publicRequest.url);
      }
    }
    final data = response.data;
    if (server.engine == BooruEngine.danbooru && path.startsWith('posts/') && response.statusCode == 451) throw BooruPostAccessError.removed;
    final access = BooruPostAccessError.detect(data, server);
    if (access != null) throw access;
    if (isDocument && needsBrowser(data, response.statusCode)) session.recordChallenge(request.url.toString(), server);
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw switch (status) {
        401 => const BooruError(BooruErrorKind.authentication),
        403 => const BooruError(BooruErrorKind.validationRequired),
        429 => const BooruError(BooruErrorKind.rateLimited),
        _ => BooruError(BooruErrorKind.unavailable, status),
      };
    }
    if (needsBrowser(data, status)) throw const BooruError(BooruErrorKind.validationRequired);
    if (path.endsWith('.json') || values.any((value) => value.$1 == 'page' && value.$2 == 'dapi')) {
      final prefix = utf8.decode(data.length > 256 ? data.sublist(0, 256) : data, allowMalformed: true).toLowerCase();
      if (prefix.contains('<html') || prefix.contains('<!doctype html')) throw const BooruError(BooruErrorKind.validationRequired);
    }
    if (data.length >= 12000000) throw const BooruError(BooruErrorKind.invalidResponse);
    return data;
  }

  void _learnRatings(BooruServer server, List<Map<String, Object?>> rows) {
    // A server that answers with the modern rating words uses "s" for sensitive, not safe.
    if (rows.any((row) => ['general', 'sensitive'].contains(row['rating']))) _modernRatings.add(_traitKey(server));
  }

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    Uint8List raw;
    switch (server.engine) {
      case BooruEngine.oldGelbooru:
        return _publicPosts(server, query, page);
      case BooruEngine.danbooru:
        final values = [('tags', query), ('limit', '40'), ('page', '${page + 1}')];
        try {
          raw = await _data(server, 'posts.json', [...values, ('only', postFields)]);
        } on BooruError catch (error) {
          // Some installations fail to serialize a projected response. Retry once
          // with standard fields, preserving the exact tags, rating, sort and page.
          if (error.kind != BooruErrorKind.unavailable || error.status != 500) rethrow;
          raw = await _data(server, 'posts.json', values);
        }
      case BooruEngine.gelbooru:
        // A server that already asked for an API key keeps using its public gallery without one.
        if (_publicGalleries.contains(_traitKey(server)) && credentials.read(server.id).isEmpty) return _publicPosts(server, query, page);
        try {
          raw = await _data(server, 'index.php', [
            ('page', 'dapi'),
            ('s', 'post'),
            ('q', 'index'),
            ('json', '1'),
            ('tags', query),
            ('limit', '40'),
            ('pid', '$page'),
          ]);
        } on BooruError catch (error) {
          // The API can require an key while the public gallery remains available.
          // Read that gallery through the verified browser instead of repeating validation.
          if (error.kind != BooruErrorKind.authentication) rethrow;
          _publicGalleries.add(_traitKey(server));
          return _publicPosts(server, query, page);
        }
      case BooruEngine.moebooru:
        raw = await _data(server, 'post.json', [('tags', query), ('limit', '40'), ('page', '${page + 1}')]);
    }
    final rows = PerfTrace.sync('booru decode rows', () => BooruDecoder.rows(raw, 'post'), detail: '${raw.length ~/ 1024}KB');
    _learnRatings(server, rows);
    final modern = _usesModernRatings(server);
    final posts = <BooruPost>[], restricted = <int>[], candidates = <BooruPost>[];
    for (final row in rows) {
      if (BooruPostAccessError.detectRow(row, server) == BooruPostAccessError.goldRequired && BooruDecoder.integer(row['id']) > 0) {
        restricted.add(BooruDecoder.integer(row['id']));
        continue;
      }
      final post = BooruDecoder.post(row, server, modernRatings: modern);
      posts.add(post);
      // Missing URLs alone never prove a Gold restriction. The public
      // document distinguishes Gold from removals, safe mode and failures.
      if (server.engine == BooruEngine.danbooru && post.viewerURL(original: false) == null && !post.isRemoved) candidates.add(post);
    }
    final checked = <int>{};
    var next = 0;
    Future<void> worker() async {
      while (next < candidates.length) {
        final post = candidates[next++];
        try {
          await _checkDanbooruAccess(server, post.postID);
        } on BooruPostAccessError catch (error) {
          if (error == BooruPostAccessError.goldRequired) checked.add(post.postID);
        } on Object {
          // An inconclusive check leaves the post in the feed.
        }
      }
    }

    // The feed waits for these checks, and the browser serves them side by side.
    await PerfTrace.span('booru access checks', () => Future.wait([for (var slot = 0; slot < 4; slot++) worker()]), detail: '${candidates.length} posts');
    restricted.addAll(posts.where((post) => checked.contains(post.postID)).map((post) => post.postID));
    posts.removeWhere((post) => checked.contains(post.postID));
    return BooruBatch(posts: posts, hasMore: rows.length >= pageSize, goldRestrictedIDs: restricted);
  }

  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async {
    final term = token.trim().toLowerCase();
    if (term.isEmpty) return [];
    final key = _traitKey(server);
    if ((_autocompleteFallbackUntil[key] ?? DateTime(0)).isBefore(DateTime.now())) {
      try {
        switch (server.engine) {
          case BooruEngine.danbooru:
            final raw = await _data(server, 'autocomplete.json', [('search[type]', 'tag_query'), ('search[query]', term), ('limit', '12')]);
            return BooruDecoder.suggestions(raw, server);
          case BooruEngine.moebooru:
            return BooruDecoder.suggestions(await _data(server, 'tag/autocomplete_name.json', [('term', term)]), server);
          case BooruEngine.gelbooru || BooruEngine.oldGelbooru:
            return await _gelbooruAutocomplete(server, term, key);
        }
      } on BooruError catch (error) {
        // Older forks may lack the website's autocomplete route. Never
        // turn authentication, validation or rate-limit errors into [].
        final missing =
            error.kind == BooruErrorKind.invalidResponse || error.kind == BooruErrorKind.unavailable && (error.status == 404 || error.status == 405);
        if (!missing) rethrow;
        _autocompleteFallbackUntil[key] = DateTime.now().add(const Duration(minutes: 5));
      }
    }
    final Uint8List raw;
    switch (server.engine) {
      case BooruEngine.danbooru:
        raw = await _data(server, 'tags.json', [('search[name_matches]', '*$term*'), ('search[order]', 'count'), ('limit', '12')]);
      case BooruEngine.moebooru:
        raw = await _data(server, 'tag.json', [('name', '*$term*'), ('order', 'count'), ('limit', '12')]);
      case BooruEngine.gelbooru:
        raw = await _data(server, 'index.php', [
          ('page', 'dapi'),
          ('s', 'tag'),
          ('q', 'index'),
          ('json', '1'),
          ('name_pattern', '%$term%'),
          ('orderby', 'count'),
          ('order', 'DESC'),
          ('limit', '12'),
        ]);
      case BooruEngine.oldGelbooru:
        // Query the site's tag directory, not tags attached to one post page.
        raw = await _data(server, 'index.php', [('page', 'tags'), ('s', 'list'), ('tags', '*$term*')], authenticated: false);
        return BooruLegacyHTML.autocompleteTags(raw, term);
    }
    return BooruDecoder.suggestions(raw, server);
  }

  /// Gallery installations answer autocomplete on one of two routes. The route that
  /// answers is remembered; the other is tried when the remembered one has none.
  Future<List<BooruTag>> _gelbooruAutocomplete(BooruServer server, String term, String key) async {
    Future<List<BooruTag>> route(String name) async {
      final raw = name == 'autocomplete2'
          ? await _data(server, 'index.php', [('page', 'autocomplete2'), ('type', 'tag_query'), ('term', term), ('limit', '12')], authenticated: false)
          : await _data(server, 'autocomplete.php', [('q', term)], authenticated: false);
      final tags = BooruDecoder.suggestions(raw, server);
      _autocompleteRoutes[key] = name;
      return tags;
    }

    final known = _autocompleteRoutes[key];
    final order = known == 'autocomplete2' ? ['autocomplete2', 'autocomplete.php'] : ['autocomplete.php', 'autocomplete2'];
    try {
      return await route(order[0]);
    } on BooruError catch (error) {
      final missing = error.kind == BooruErrorKind.invalidResponse || error.kind == BooruErrorKind.unavailable && (error.status == 404 || error.status == 405);
      if (!missing || known != null) rethrow;
      return route(order[1]);
    }
  }

  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async {
    if (server.engine.usesGelbooruPages) {
      final id = parseInt64(query);
      if (id != null && id > 0) {
        final raw = await _data(server, 'index.php', [('page', 'pool'), ('s', 'show'), ('id', '$id')], authenticated: false);
        final ids = BooruHTML.postIDs(raw);
        if (ids.isEmpty) return [];
        return [BooruPool(id: id, name: 'Pool #$id', count: ids.length, hasKnownCount: false)];
      }
      final raw = await _data(server, 'index.php', [('page', 'pool'), ('s', 'list'), ('pid', '${page * 25}')], authenticated: false);
      return BooruHTML.pools(raw);
    }
    final danbooru = server.engine == BooruEngine.danbooru;
    final path = danbooru ? 'pools.json' : 'pool.json';
    final key = danbooru ? 'search[name_matches]' : 'query';
    final value = danbooru && query.isNotEmpty ? '*$query*' : query;
    final parameters = [('page', '${page + 1}'), ('limit', '20')];
    if (value.isNotEmpty) parameters.add((key, value));
    // A pool can contain thousands of post IDs. The list needs only its summary.
    if (danbooru) parameters.add(('only', 'id,name,post_count,description'));
    final Uint8List raw;
    try {
      raw = await _data(server, path, parameters);
    } catch (error) {
      if (!browserFallback || !BooruWebTransport.isAvailable || !danbooru || !(error is NetworkError || error is BrowserProcessTerminated)) rethrow;
      // Some protection layers allow navigation but reject browser fetch.
      // Read the public list in the same validated browser, without API credentials.
      final html = await _data(server, 'pools', parameters.where((item) => item.$1 != 'only').toList(), authenticated: false);
      return BooruHTML.danbooruPools(html);
    }
    return [
      for (final row in BooruDecoder.rows(raw, 'pool'))
        if (row['name'] case final String name)
          BooruPool(
            id: BooruDecoder.integer(row['id']),
            name: name,
            count: BooruDecoder.integer(row['post_count']),
            description: row['description'] is String ? row['description'] as String : '',
            hasKnownCount: row.containsKey('post_count'),
          ),
    ];
  }

  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async {
    if (!server.engine.usesGelbooruPages) {
      // Danbooru needs ordpool to preserve the authored sequence.
      final term = server.engine == BooruEngine.danbooru ? 'ordpool' : 'pool';
      return posts(server, '$term:$poolID', page);
    }
    final key = '${server.id}:$poolID';
    final List<int> ids;
    final bool hasMore;
    final whole = _wholePools[key];
    if (page > 0 && whole != null) {
      ids = whole.skip(page * pageSize).take(pageSize).toList();
      hasMore = (page + 1) * pageSize < whole.length;
    } else {
      final offset = page == 0 ? 0 : _poolOffsets[key]?[page] ?? page * 45;
      final raw = await _data(server, 'index.php', [('page', 'pool'), ('s', 'show'), ('id', '$poolID'), ('pid', '$offset')], authenticated: false);
      final all = BooruHTML.postIDs(raw);
      final next = BooruHTML.nextPoolOffset(raw, offset);
      if (page == 0) {
        _wholePools.remove(key);
        _poolOffsets[key] = {};
      }
      if (page == 0 && next == null) {
        // Legacy galleries return the entire pool regardless of pid.
        // Page this ID list locally instead of repeatedly loading the same pool.
        if (_wholePools.length >= 16) _wholePools.clear();
        _wholePools[key] = all;
        ids = all.take(pageSize).toList();
        hasMore = all.length > pageSize;
      } else {
        ids = all;
        hasMore = next != null;
        if (next != null) (_poolOffsets[key] ??= {})[page + 1] = next;
      }
    }
    // Preserve the pool's order; individual requests are serialized to respect rate limits.
    final result = <BooruPost>[];
    final modern = _usesModernRatings(server);
    Future<BooruPost> page0(int id) async => BooruLegacyHTML.post(
      await _data(server, 'index.php', [('page', 'post'), ('s', 'view'), ('id', '$id')], authenticated: false),
      server,
      id,
      modernRatings: modern,
    );
    for (final (index, id) in ids.indexed) {
      if (server.engine == BooruEngine.oldGelbooru) {
        result.add(await page0(id));
        continue;
      }
      try {
        final response = await _data(server, 'index.php', [('page', 'dapi'), ('s', 'post'), ('q', 'index'), ('json', '1'), ('id', '$id')]);
        final rows = BooruDecoder.rows(response, 'post');
        _learnRatings(server, rows);
        final decoded = [for (final row in rows) BooruDecoder.post(row, server, modernRatings: _usesModernRatings(server))];
        if (decoded.isEmpty) {
          result.add(await page0(id));
        } else {
          result.addAll(decoded);
        }
      } on BooruError catch (error) {
        if (error.kind != BooruErrorKind.authentication) rethrow;
        result.add(await page0(id));
      }
      if (index < ids.length - 1 && poolRequestDelay > Duration.zero) await Future<void>.delayed(poolRequestDelay);
    }
    return BooruBatch(posts: result, hasMore: hasMore);
  }

  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async {
    final Uint8List raw;
    switch (server.engine) {
      case BooruEngine.oldGelbooru:
        return BooruLegacyHTML.notes(await _postPage(server, postID, reuse: true));
      case BooruEngine.danbooru:
        // Notes may exceed the default page size. Fetch every active page.
        final result = <BooruNote>[];
        for (var page = 1; ; page++) {
          final data = await _data(server, 'notes.json', [('search[post_id]', '$postID'), ('search[is_active]', 'true'), ('limit', '200'), ('page', '$page')]);
          final rows = BooruDecoder.rows(data, 'note');
          result.addAll(rows.map(BooruDecoder.note).nonNulls);
          if (rows.length < 200) return result;
        }
      case BooruEngine.moebooru:
        raw = await _data(server, 'note.json', [('post_id', '$postID')]);
      case BooruEngine.gelbooru:
        // Current galleries keep public notes in data-* attributes on the post page, which a
        // detail lookup may already hold. Legacy API instances still expose XML notes.
        final cached = _cachedPostPage(server, postID);
        if (cached != null) {
          final notes = BooruHTML.notes(cached);
          if (notes.isNotEmpty || _publicGalleries.contains(_traitKey(server))) return notes;
        }
        if (_publicGalleries.contains(_traitKey(server))) return BooruHTML.notes(await _postPage(server, postID, reuse: true));
        try {
          raw = await _data(server, 'index.php', [('page', 'dapi'), ('s', 'note'), ('q', 'index'), ('json', '1'), ('post_id', '$postID')]);
          return BooruDecoder.rows(raw, 'note').map(BooruDecoder.note).nonNulls.toList();
        } on BooruError catch (error) {
          if (![BooruErrorKind.authentication, BooruErrorKind.validationRequired, BooruErrorKind.invalidResponse].contains(error.kind)) rethrow;
          if (error.kind == BooruErrorKind.authentication) _publicGalleries.add(_traitKey(server));
          return BooruHTML.notes(await _postPage(server, postID, reuse: true));
        }
    }
    return BooruDecoder.rows(raw, 'note').map(BooruDecoder.note).nonNulls.toList();
  }

  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async {
    if (post.isRemoved) throw BooruPostAccessError.removed;
    // Refresh metadata when resolving missing media or checking a failed URL.
    // Saved posts may predate removal flags or animation conversion metadata.
    if (server.engine == BooruEngine.danbooru) {
      final raw = await _data(server, 'posts/${post.postID}.json', [('only', postFields)]);
      final Object? row;
      try {
        row = jsonDecode(utf8.decode(raw));
      } on FormatException {
        throw const BooruError(BooruErrorKind.invalidResponse);
      }
      if (row is! Map) throw const BooruError(BooruErrorKind.invalidResponse);
      final resolved = BooruDecoder.post(row.cast<String, Object?>(), server, modernRatings: _usesModernRatings(server));
      if (resolved.postID != post.postID) throw const BooruError(BooruErrorKind.invalidResponse);
      if (resolved.viewerURL(original: false) == null) await _checkDanbooruAccess(server, post.postID);
      return resolved;
    }
    if (!server.engine.usesGelbooruPages) return post;
    final raw = await _postPage(server, post.postID, reuse: false);
    return BooruLegacyHTML.post(raw, server, post.postID, preview: post.previewURL, modernRatings: _usesModernRatings(server));
  }

  Future<void> _checkDanbooruAccess(BooruServer server, int postID) async {
    final credentials = this.credentials.read(server.id);
    final cookies = session.cookies(server).toList()
      ..sort((a, b) => '${a.domain}\u0000${a.path}\u0000${a.name}'.compareTo('${b.domain}\u0000${b.path}\u0000${b.name}'));
    // Keep only a process-local hash in cache keys. Credential or cookie changes
    // and a completed browser validation immediately permit a fresh check.
    final scope = Object.hashAll([
      credentials.account,
      credentials.apiKey,
      session.accessRevision(server),
      for (final cookie in cookies) ...[cookie.domain, cookie.path, cookie.name, cookie.value],
    ]);
    final key = '${server.id}:${server.canonicalAddress}:$postID:$scope';
    final cached = _accessResults[key];
    final bool restricted;
    if (cached != null && DateTime.now().difference(cached.$2) < const Duration(seconds: 60)) {
      restricted = cached.$1;
    } else {
      restricted = await (_accessFlights[key] ??= () async {
        try {
          bool result;
          try {
            await _data(server, 'posts/$postID', []);
            result = false;
          } on BooruPostAccessError catch (error) {
            if (error != BooruPostAccessError.goldRequired) rethrow;
            result = true;
          }
          if (_accessResults.length >= 128) {
            final oldest = _accessResults.entries.reduce((a, b) => a.value.$2.isBefore(b.value.$2) ? a : b).key;
            _accessResults.remove(oldest);
          }
          _accessResults[key] = (result, DateTime.now());
          return result;
        } finally {
          _accessFlights.remove(key);
        }
      }());
    }
    if (restricted) throw BooruPostAccessError.goldRequired;
  }

  String _pageKey(BooruServer server, int id) => '${server.id}:${server.canonicalAddress}:$id';

  Uint8List? _cachedPostPage(BooruServer server, int id) {
    final cached = _postPages[_pageKey(server, id)];
    return cached != null && DateTime.now().difference(cached.$2) < const Duration(seconds: 60) ? cached.$1 : null;
  }

  /// The public post document contains both media addresses and notes. Concurrent
  /// requests share one load and a following notes request reuses it; failures are not kept.
  Future<Uint8List> _postPage(BooruServer server, int id, {required bool reuse}) async {
    final key = _pageKey(server, id);
    if (reuse) {
      final cached = _cachedPostPage(server, id);
      if (cached != null) return cached;
    }
    final pending = _pendingPostPages[key];
    if (pending != null) return pending;
    final task = _data(server, 'index.php', [('page', 'post'), ('s', 'view'), ('id', '$id')], authenticated: false);
    _pendingPostPages[key] = task;
    try {
      final result = await task;
      if (_postPages.length >= 16) _postPages.clear();
      // Bound retained HTML to 8 MB (16 documents), separate from image caches.
      if (result.length <= 512 * 1024) {
        _postPages[key] = (result, DateTime.now());
      } else {
        _postPages.remove(key);
      }
      return result;
    } finally {
      _pendingPostPages.remove(key);
    }
  }

  Future<BooruBatch> _publicPosts(BooruServer server, String query, int page) async {
    final key = '${server.id}:$query';
    final size = server.engine == BooruEngine.oldGelbooru ? 20 : 42;
    final offset = page == 0 ? 0 : _publicOffsets[key]?[page] ?? page * size;
    final parameters = [('page', 'post'), ('s', 'list')];
    if (query.isNotEmpty) parameters.add(('tags', query));
    if (offset > 0) parameters.add(('pid', '$offset'));
    final html = await _data(server, 'index.php', parameters, authenticated: false, publicURL: page == 0 ? null : _publicPages[key]?[page]);
    final posts = BooruLegacyHTML.posts(html, server, modernRatings: _usesModernRatings(server));
    final next = BooruLegacyHTML.nextOffset(html, offset);
    final nextPage = BooruLegacyHTML.nextPageURL(html, server, offset);
    if (page == 0) {
      if (_publicOffsets.length > 32) {
        _publicOffsets.clear();
        _publicPages.clear();
      }
      _publicOffsets[key] = {};
      _publicPages[key] = {};
    }
    if (next != null && nextPage != null) {
      (_publicOffsets[key] ??= {})[page + 1] = next;
      (_publicPages[key] ??= {})[page + 1] = nextPage;
    }
    return BooruBatch(posts: posts, hasMore: nextPage != null);
  }
}

abstract final class BooruDecoder {
  static int integer(Object? value) {
    if (value is num) return value.toInt();
    if (value is bool) return value ? 1 : 0;
    if (value is String) return parseInt64(value) ?? 0;
    return 0;
  }

  /// JSON arrays and envelopes, or XML rows under `<{key}s>`.
  static List<Map<String, Object?>> rows(Uint8List data, String key) {
    Object? json;
    var isJson = false;
    try {
      json = jsonDecode(utf8.decode(data));
      isJson = json is Map || json is List;
    } on FormatException {
      isJson = false;
    }
    if (isJson) {
      if (json is List) {
        if (json.every((row) => row is Map)) return [for (final row in json) (row as Map).cast<String, Object?>()];
        throw const BooruError(BooruErrorKind.invalidResponse);
      }
      final object = (json as Map).cast<String, Object?>();
      if (object['success'] == false || object.containsKey('error') && object['error'] != null) throw const BooruError(BooruErrorKind.invalidResponse);
      final rows = object[key];
      if (rows is List && rows.every((row) => row is Map)) return [for (final row in rows) (row as Map).cast<String, Object?>()];
      if (rows is Map) return [rows.cast<String, Object?>()];
      final attributes = object['@attributes'];
      if (attributes is Map && integer(attributes['count']) == 0) return [];
      throw const BooruError(BooruErrorKind.invalidResponse);
    }
    final parsed = BooruXMLRows.parse(data, key);
    if (parsed == null) throw const BooruError(BooruErrorKind.invalidResponse);
    return parsed;
  }

  static String? safeURL(Object? value, String base) => safeBooruURL(value, base);

  /// `row[a] ?? row[b]`: the first key the row has, even when its value is null.
  static Object? _first(Map<String, Object?>? row, List<String> keys) {
    if (row == null) return null;
    for (final key in keys) {
      if (row.containsKey(key)) return row[key];
    }
    return null;
  }

  static BooruPost post(Map<String, Object?> row, BooruServer server, {bool modernRatings = false}) {
    final id = integer(row['id']);
    if (id <= 0) throw const BooruError(BooruErrorKind.invalidResponse);
    final base = server.baseURL;
    final file = safeURL(row['file_url'], base);
    final preview = safeURL(_first(row, ['preview_file_url', 'preview_url']), base);
    String text(Object? value) => value is String ? value : '';
    final tagText = row['tag_string'] is String ? row['tag_string'] as String : text(row['tags']);
    final tags = splitWhitespace(tagText);
    final artists = splitWhitespace(text(row['tag_string_artist']));
    final categories = <String, int>{};
    for (final (field, category) in const [('tag_string_artist', 1), ('tag_string_copyright', 3), ('tag_string_character', 4), ('tag_string_meta', 5)]) {
      for (final tag in splitWhitespace(text(row[field]))) {
        categories[tag] = category;
      }
    }
    final asset = row['media_asset'];
    final rawVariants = asset is Map ? asset['variants'] : null;
    final variants = rawVariants is List && rawVariants.every((variant) => variant is Map)
        ? [for (final variant in rawVariants) (variant as Map).cast<String, Object?>()]
        : <Map<String, Object?>>[];
    Map<String, Object?>? variant(String type) => variants.where((value) => value['type'] == type).firstOrNull;
    // Full-size JPEG or a viewing-size sample, never a grid thumbnail.
    final viewingVariant = variant('full') ?? variant('sample');
    final sampleSource = row.containsKey('jpeg_url')
        ? row['jpeg_url']
        : viewingVariant != null && viewingVariant.containsKey('url')
        ? viewingVariant['url']
        : _first(row, ['sample_url', 'large_file_url']);
    final sample = safeURL(sampleSource, base);
    final small = variant('720x720') ?? variant('sample');
    final reduced = small == null ? null : safeURL(small['url'], base);
    final fileExtension = (row['file_ext'] is String ? row['file_ext'] as String : urlPathExtension(file)).toLowerCase();
    final videoVariants = variants.where((value) {
      final ext = (value['file_ext'] is String ? value['file_ext'] as String : urlPathExtension(safeURL(value['url'], base))).toLowerCase();
      return BooruPost.videoExtensions.contains(ext);
    }).toList();
    final animationVariant = videoVariants.where((value) => value['type'] == 'sample').firstOrNull ?? videoVariants.firstOrNull;
    final legacyVideo = [
      row['large_file_url'],
      row['sample_url'],
    ].map((value) => safeURL(value, base)).nonNulls.where((url) => BooruPost.videoExtensions.contains(urlPathExtension(url).toLowerCase())).firstOrNull;
    final animationVideo = fileExtension == 'zip' ? (animationVariant == null ? null : safeURL(animationVariant['url'], base)) ?? legacyVideo : null;
    var rating = text(row['rating']);
    if (!(server.usesModernRatings || modernRatings) && rating == 's') rating = 'g'; // Legacy s means safe, not sensitive.
    final poolIDs = row['pool_ids'] is List ? (row['pool_ids'] as List).map(integer).where((value) => value > 0).toList() : <int>[];
    return BooruPost(
      serverID: server.id,
      postID: id,
      previewURL: preview,
      sampleURL: sample,
      fileURL: file,
      width: integer(_first(row, ['image_width', 'width'])),
      height: integer(_first(row, ['image_height', 'height'])),
      tags: tags,
      artists: artists,
      rating: rating,
      score: integer(row['score']),
      fileExtension: fileExtension,
      poolIDs: poolIDs,
      metadataTags: row['tag_string_meta'] is String ? splitWhitespace(row['tag_string_meta'] as String) : null,
      favoriteCount: row.containsKey('fav_count') ? integer(row['fav_count']) : null,
      upvoteCount: row.containsKey('up_score') ? integer(row['up_score']) : null,
      commentCount: row.containsKey('comment_count') ? integer(row['comment_count']) : null,
      reducedDataURL: reduced,
      tagCategories: categories.isEmpty ? null : categories,
      animated: variants.any((value) => value['type'] == 'full') ? false : null,
      animationVideoURL: animationVideo,
      isDeleted: row['is_deleted'] is bool ? row['is_deleted'] as bool : null,
      isBanned: row['is_banned'] is bool ? row['is_banned'] as bool : null,
    );
  }

  static List<BooruTag> suggestions(Uint8List data, BooruServer server) {
    try {
      final names = jsonDecode(utf8.decode(data));
      if (names is List && names.every((name) => name is String)) {
        return [for (final name in names.cast<String>().where((name) => name.isNotEmpty).take(12)) BooruTag(name: name, count: 0, category: 0)];
      }
    } on FormatException {
      // Rows below.
    }
    final seen = <String>{};
    final result = <BooruTag>[];
    for (final row in rows(data, 'tag')) {
      // value is the canonical tag; label may contain spaces, an alias or a count.
      final name = _first(row, ['value', 'name']);
      if (name is! String || name.isEmpty || !seen.add(name)) continue;
      final int count;
      if (row.containsKey('post_count') || row.containsKey('count')) {
        count = integer(_first(row, ['post_count', 'count']));
      } else if (row['label'] case final String label) {
        final match = BooruHTML.matches(r'\(([0-9,]+)\)\s*$', label).firstOrNull;
        count = match == null ? 0 : int.tryParse(match[1].replaceAll(',', '')) ?? 0;
      } else {
        count = 0;
      }
      final category = integer(_first(row, ['category', 'type']));
      result.add(BooruTag(name: name, count: count, category: category, isMetadata: server.engine == BooruEngine.danbooru && category == 5));
      if (result.length == 12) break;
    }
    return result;
  }

  static BooruNote? note(Map<String, Object?> row) {
    if (row.containsKey('is_active') && ['false', '0'].contains('${row['is_active']}'.toLowerCase())) return null;
    final body = row['body'];
    if (body is! String) return null;
    return BooruNote(
      id: integer(row['id']),
      x: integer(row['x']).toDouble(),
      y: integer(row['y']).toDouble(),
      width: integer(row['width']).toDouble(),
      height: integer(row['height']).toDouble(),
      body: BooruHTML.plainText(body),
    );
  }
}

/// The rows `XMLParser` reports for `<{element}s><{element} …/></{element}s>`: each row's
/// attributes plus the text of its child elements. Null for a malformed document or another root.
abstract final class BooruXMLRows {
  static List<Map<String, Object?>>? parse(Uint8List data, String element) {
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      return null;
    }
    final rows = <Map<String, Object?>>[];
    var validRoot = false;
    Map<String, Object?>? current;
    String? field;
    final buffer = StringBuffer();
    final stack = <String>[];
    var sawRoot = false;
    var index = 0;
    final tag = RegExp(
      r'<(/?)([A-Za-z_][\w.:-]*)((?:\s+[^\s=/>]+\s*=\s*(?:"[^"]*"|'
      "'[^']*'"
      r'))*)\s*(/?)>',
    );
    final attribute = RegExp(
      r'([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'
      "'([^']*)'"
      r')',
    );
    void characters(String value) {
      if (stack.isEmpty && value.trim().isNotEmpty) throw const FormatException();
      buffer.write(_decodeEntities(value));
    }

    void start(String name, Map<String, String> attributes) {
      if (stack.isEmpty && sawRoot) throw const FormatException();
      sawRoot = true;
      if (name == '${element}s') validRoot = true;
      if (name == element) {
        current = {...attributes};
      } else if (current != null) {
        field = name;
        buffer.clear();
      }
    }

    void end(String name) {
      if (name == element && current != null) {
        rows.add(current!);
        current = null;
        field = null;
      } else if (name == field) {
        current?[name] = buffer.toString();
        field = null;
      }
    }

    try {
      while (index < text.length) {
        final open = text.indexOf('<', index);
        if (open < 0) {
          characters(text.substring(index));
          break;
        }
        if (open > index) characters(text.substring(index, open));
        if (text.startsWith('<?', open)) {
          final close = text.indexOf('?>', open);
          if (close < 0) return null;
          index = close + 2;
        } else if (text.startsWith('<!--', open)) {
          final close = text.indexOf('-->', open);
          if (close < 0) return null;
          index = close + 3;
        } else if (text.startsWith('<![CDATA[', open)) {
          final close = text.indexOf(']]>', open);
          if (close < 0 || stack.isEmpty) return null;
          buffer.write(text.substring(open + 9, close));
          index = close + 3;
        } else if (text.startsWith('<!', open)) {
          final close = text.indexOf('>', open);
          if (close < 0) return null;
          index = close + 1;
        } else {
          final match = tag.matchAsPrefix(text, open);
          if (match == null) return null;
          final name = match[2]!;
          if (match[1] == '/') {
            if (match[3]!.trim().isNotEmpty || match[4] == '/' || stack.isEmpty || stack.removeLast() != name) return null;
            end(name);
          } else {
            final attributes = {for (final value in attribute.allMatches(match[3]!)) value[1]!: _decodeEntities(value[2] ?? value[3] ?? '')};
            start(name, attributes);
            if (match[4] == '/') {
              end(name);
            } else {
              stack.add(name);
            }
          }
          index = match.end;
        }
      }
    } on FormatException {
      return null;
    }
    if (!sawRoot || stack.isNotEmpty || !validRoot) return null;
    return rows;
  }

  static String _decodeEntities(String value) => value.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'), (match) {
    final token = match[1]!;
    switch (token) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final number = token.startsWith('#x') ? int.tryParse(token.substring(2), radix: 16) : int.tryParse(token.substring(1));
    return number == null ? match[0]! : String.fromCharCode(number);
  });
}
