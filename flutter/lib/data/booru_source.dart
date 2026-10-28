import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/content.dart';
import 'booru_credentials.dart';

/// Public Booru APIs, with inert HTML parsing for legacy/public Gelbooru pages.
/// The default client shares this device’s Android website session.
class BooruSource implements ContentSource, SortedContentSource {
  BooruSource(this.config, {http.Client? client})
    : _client = client ?? BooruAuthenticatedClient(config),
      _ownsClient = client == null {
    SourceConfig.validateUrl(config.baseUrl.toString());
    if (config.mode != AppMode.booru) {
      throw ArgumentError.value(config.kind, 'kind', 'Expected a Booru engine');
    }
  }

  final SourceConfig config;
  final http.Client _client;
  final bool _ownsClient;
  final Map<String, Map<int, Uri>> _publicPages = {};
  static const _pageSize = 40;
  static const _maxBytes = 12000000;
  static const _timeout = Duration(seconds: 30);
  bool _closed = false;

  Uri _url(String path, [Map<String, String> query = const {}]) {
    final base = config.baseUrl.replace(
      path: config.baseUrl.path.replaceFirst(RegExp(r'/(?:index\.php)?$'), ''),
    );
    return base.replace(path: '${base.path}/$path', queryParameters: query);
  }

  Future<String> _get(Uri url) async {
    if (_closed) throw const ContentException('This source is closed.');
    try {
      return await _read(url).timeout(_timeout);
    } on ContentException {
      rethrow;
    } on TimeoutException {
      throw const ContentException('The server took too long to respond.');
    } on Exception {
      throw const ContentException(
        'Unable to reach the server. Check your connection.',
      );
    }
  }

  Future<String> _read(Uri url, [int redirects = 0]) async {
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'application/json, application/xml;q=0.9, text/html;q=0.8',
        'User-Agent': 'TEGNAL/1.0',
      });
    final response = await _client.send(request);
    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      await response.stream.drain<void>();
      final location = response.headers['location'];
      final next = location == null ? null : url.resolve(location);
      if (redirects >= 5 || next == null || !_sameOrigin(next)) {
        throw ContentException(
          'The server redirected to an unsupported address.',
          statusCode: status,
        );
      }
      return _read(next, redirects + 1);
    }
    if (status < 200 || status >= 300) {
      await response.stream.drain<void>();
      throw ContentException(switch (status) {
        401 => 'This server requires an account or API key.',
        403 => 'The server requires browser verification or access permission.',
        404 => 'The requested post or API was not found.',
        429 => 'The server is busy. Wait a moment before trying again.',
        _ => 'Server error ($status). Please try again.',
      }, statusCode: status);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length >= _maxBytes) {
        throw const ContentException('The server response is too large.');
      }
      bytes.addAll(chunk);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final prefix = text
        .substring(0, text.length > 4096 ? 4096 : text.length)
        .toLowerCase();
    if (prefix.trimLeft().startsWith('<') &&
        (prefix.contains('cf-chl-') ||
            prefix.contains('just a moment') ||
            prefix.contains('checking your browser'))) {
      throw const ContentException('The server requires browser verification.');
    }
    return text;
  }

  bool _sameOrigin(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.host == config.baseUrl.host &&
      uri.port == config.baseUrl.port;

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
  }) async {
    if (page < 1) throw ArgumentError.value(page, 'page', 'Pages start at 1');
    final tags = popular
        ? [
            ...query
                .split(RegExp(r'\s+'))
                .where(
                  (s) =>
                      s.isNotEmpty &&
                      !s.toLowerCase().startsWith('order:') &&
                      !s.toLowerCase().startsWith('sort:'),
                ),
            config.kind == SourceKind.gelbooru
                ? 'sort:score:desc'
                : 'order:score',
          ].join(' ')
        : query.trim();
    if (config.kind == SourceKind.oldGelbooru) return _publicSearch(tags, page);
    final uri = switch (config.kind) {
      SourceKind.danbooru => _url('posts.json', {
        'tags': tags,
        'limit': '$_pageSize',
        'page': '$page',
      }),
      SourceKind.moebooru => _url('post.json', {
        'tags': tags,
        'limit': '$_pageSize',
        'page': '$page',
      }),
      _ => _url('index.php', {
        'page': 'dapi',
        's': 'post',
        'q': 'index',
        'json': '1',
        'tags': tags,
        'limit': '$_pageSize',
        'pid': '${page - 1}',
      }),
    };
    final String body;
    try {
      body = await _get(uri);
    } on ContentException catch (error) {
      if (config.kind == SourceKind.gelbooru && error.statusCode == 401) {
        return _publicSearch(tags, page);
      }
      rethrow;
    }
    final rows = _rows(body, 'post');
    return ContentPage(
      rows.map(_post).toList(),
      hasMore: rows.length >= _pageSize,
    );
  }

  @override
  Future<ContentPage> searchSorted(
    String query, {
    int page = 1,
    BooruSort sort = BooruSort.latest,
  }) async {
    if (!BooruSort.supportedBy([config]).contains(sort)) {
      throw UnsupportedBooruSort(sort);
    }
    try {
      return await search(_queryForSort(query, sort), page: page);
    } on ContentException catch (error) {
      if (error.statusCode == 400 || error.statusCode == 422) {
        throw UnsupportedBooruSort(sort);
      }
      rethrow;
    }
  }

  String _queryForSort(String query, BooruSort sort) {
    if (sort == BooruSort.latest) return query.trim();
    final terms = query
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final hasPeriodConstraint = terms.any((term) {
      final lower = term.toLowerCase();
      return lower.startsWith('date:') || lower.startsWith('age:');
    });
    final hasOrderConstraint = terms.any((term) {
      final lower = term.toLowerCase();
      return lower.startsWith('order:') || lower.startsWith('sort:');
    });
    if ((sort == BooruSort.popularWeek || sort == BooruSort.popularMonth) &&
        !hasPeriodConstraint) {
      final days = sort == BooruSort.popularWeek ? 7 : 30;
      final date = DateTime.now()
          .toUtc()
          .subtract(Duration(days: days))
          .toIso8601String()
          .substring(0, 10);
      terms.add('date:>=$date');
    }
    // Preserve an explicit order/sort query term instead of adding a
    // conflicting generated server order.
    if (!hasOrderConstraint) {
      final order = switch (sort) {
        BooruSort.latest => null,
        BooruSort.popular ||
        BooruSort.popularWeek ||
        BooruSort.popularMonth => 'score',
        BooruSort.trending => 'rank',
        BooruSort.mostFavorited => 'favcount',
        BooruSort.mostUpvoted => 'upvotes',
        BooruSort.mostDiscussed => 'comment_count',
      };
      if (order != null) {
        terms.add(
          config.kind == SourceKind.gelbooru
              ? 'sort:score:desc'
              : 'order:$order',
        );
      }
    }
    return terms.join(' ');
  }

  @override
  Future<ContentItem> detail(int id) async {
    if (id < 1) {
      throw ArgumentError.value(id, 'id', 'Post IDs must be positive');
    }
    if (config.kind == SourceKind.oldGelbooru) return _publicDetail(id);
    final uri = switch (config.kind) {
      SourceKind.danbooru => _url('posts/$id.json'),
      SourceKind.moebooru => _url('post.json', {
        'tags': 'id:$id',
        'limit': '1',
      }),
      _ => _url('index.php', {
        'page': 'dapi',
        's': 'post',
        'q': 'index',
        'json': '1',
        'id': '$id',
      }),
    };
    final String body;
    try {
      body = await _get(uri);
    } on ContentException catch (error) {
      if (config.kind == SourceKind.gelbooru && error.statusCode == 401) {
        return _publicDetail(id);
      }
      rethrow;
    }
    final rows = _rows(
      body,
      'post',
      single: config.kind == SourceKind.danbooru,
    );
    for (final row in rows) {
      if (_integer(row['id']) == id) return _post(row);
    }
    throw const ContentException(
      'The requested post was not found.',
      statusCode: 404,
    );
  }

  @override
  Future<List<ReaderPage>> pages(ContentItem item) async {
    if (item.sourceId != config.id || item.mode != AppMode.booru) {
      throw const ContentException('This post belongs to a different source.');
    }
    final post = item.mediaUrl == null ? await detail(item.id) : item;
    final uri = _media(post.mediaUrl?.toString());
    if (uri == null) {
      throw const ContentException(
        'This post has no accessible media. It may be removed or restricted.',
      );
    }
    return [
      ReaderPage(
        url: uri,
        thumbnailUrl: post.thumbnailUrl,
        width: post.width,
        height: post.height,
        headers: {'Referer': _url('').toString()},
      ),
    ];
  }

  @override
  Future<List<String>> suggestions(String query) async {
    final words = query.trim().split(RegExp(r'\s+'));
    final token = words.last.replaceFirst(RegExp(r'^-'), '').toLowerCase();
    if (token.isEmpty ||
        token.contains(':') ||
        RegExp(r'\s$').hasMatch(query)) {
      return [];
    }
    if (config.kind == SourceKind.oldGelbooru) return _publicSuggestions(token);
    final uri = switch (config.kind) {
      SourceKind.danbooru => _url('tags.json', {
        'search[name_matches]': '$token*',
        'search[order]': 'count',
        'limit': '12',
      }),
      SourceKind.moebooru => _url('tag.json', {
        'name': '$token*',
        'order': 'count',
        'limit': '12',
      }),
      _ => _url('index.php', {
        'page': 'dapi',
        's': 'tag',
        'q': 'index',
        'json': '1',
        'name_pattern': '$token%',
        'orderby': 'count',
        'order': 'DESC',
        'limit': '12',
      }),
    };
    final String body;
    try {
      body = await _get(uri);
    } on ContentException catch (error) {
      if (config.kind == SourceKind.gelbooru && error.statusCode == 401) {
        return _publicSuggestions(token);
      }
      rethrow;
    }
    return _rows(body, 'tag')
        .map((row) => row['name'])
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .take(12)
        .toList();
  }

  List<Map<String, dynamic>> _rows(
    String body,
    String key, {
    bool single = false,
  }) {
    try {
      final trimmed = body.trimLeft();
      if (trimmed.startsWith('<')) {
        final document = XmlDocument.parse(body);
        final root = document.rootElement;
        if (root.localName != '${key}s') throw const FormatException();
        return root
            .findElements(key)
            .map(
              (element) => <String, dynamic>{
                for (final attribute in element.attributes)
                  attribute.localName: attribute.value,
                for (final child in element.childElements)
                  child.localName.replaceAll('-', '_'): child.innerText,
              },
            )
            .toList();
      }
      final decoded = jsonDecode(body);
      dynamic values = decoded;
      if (decoded is Map) {
        if (decoded['success'] == false || decoded['error'] != null) {
          throw const FormatException();
        }
        if (single && decoded['id'] != null) {
          return [Map<String, dynamic>.from(decoded)];
        }
        values = decoded[key];
        if (values == null &&
            decoded['@attributes'] is Map &&
            _integer(decoded['@attributes']['count']) == 0) {
          return [];
        }
        if (values is Map) values = [values];
      }
      if (values is! List || values.any((value) => value is! Map)) {
        throw const FormatException();
      }
      return values
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
    } on Exception {
      throw const ContentException(
        'The server returned an unsupported response. Check its address and engine.',
      );
    }
  }

  ContentItem _post(Map<String, dynamic> row) {
    final id = _integer(row['id']);
    if (id < 1) {
      throw const ContentException('The server returned an invalid post.');
    }
    final file = _media(row['file_url']);
    final preview = _media(row['preview_file_url'] ?? row['preview_url']);
    final asset = row['media_asset'];
    final rawVariants = asset is Map ? asset['variants'] : null;
    final variants = (rawVariants is List ? rawVariants : const [])
        .whereType<Map>()
        .toList();
    Map? variant(String name) {
      for (final value in variants) {
        if (value['type'] == name) return value;
      }
      return null;
    }

    final sample = _media(
      row['jpeg_url'] ??
          variant('full')?['url'] ??
          variant('sample')?['url'] ??
          row['sample_url'] ??
          row['large_file_url'],
    );
    final reduced = _media(
      variant('720x720')?['url'] ?? variant('sample')?['url'],
    );
    final tags = _terms(row['tag_string'] ?? row['tags']);
    final artists = _terms(row['tag_string_artist']);
    final categories = <String, int>{};
    for (final entry in {
      'tag_string_artist': 1,
      'tag_string_copyright': 3,
      'tag_string_character': 4,
      'tag_string_meta': 5,
    }.entries) {
      for (final tag in _terms(row[entry.key])) {
        categories[tag] = entry.value;
      }
    }
    final ext =
        ((row['file_ext'] is String ? row['file_ext'] as String : null) ??
                file?.path.split('.').last ??
                '')
            .toLowerCase();
    final video = ['mp4', 'webm', 'mov', 'm4v'].contains(ext);
    final animated =
        tags.contains('animated') ||
        (variant('full') == null && ['gif', 'webp', 'apng'].contains(ext));
    final width = _integer(row['image_width'] ?? row['width']);
    final height = _integer(row['image_height'] ?? row['height']);
    final score = _integer(row['score']);
    final metadata = <String, dynamic>{
      'serverID': config.id,
      'postID': id,
      'previewURL': preview?.toString(),
      'sampleURL': sample?.toString(),
      'fileURL': file?.toString(),
      'width': width,
      'height': height,
      'tags': tags,
      'artists': artists,
      'rating': _rating(row['rating'] is String ? row['rating'] as String : ''),
      'score': score,
      'fileExtension': ext,
      'poolIDs': row['pool_ids'] is List
          ? (row['pool_ids'] as List)
                .map(_integer)
                .where((id) => id > 0)
                .toList()
          : <int>[],
      if (row['tag_string_meta'] != null)
        'metadataTags': _terms(row['tag_string_meta']),
      if (row['fav_count'] != null) 'favoriteCount': _integer(row['fav_count']),
      if (row['up_score'] != null) 'upvoteCount': _integer(row['up_score']),
      if (row['comment_count'] != null)
        'commentCount': _integer(row['comment_count']),
      if (reduced != null) 'reducedDataURL': reduced.toString(),
      if (categories.isNotEmpty) 'tagCategories': categories,
      if (variant('full') != null) 'animated': false,
      'raw': row,
    };
    return ContentItem(
      sourceId: config.id,
      id: id,
      mode: AppMode.booru,
      title: 'Post #$id',
      thumbnailUrl: preview ?? sample ?? file,
      mediaUrl: video || animated ? file ?? sample : sample ?? file,
      pageUrl: _pageUrl(id),
      tags: tags,
      artists: artists,
      width: width,
      height: height,
      score: score,
      mediaType: video
          ? 'video'
          : animated
          ? 'animation'
          : 'image',
      metadata: metadata,
    );
  }

  String _rating(String raw) {
    final value = raw.toLowerCase();
    final modern =
        config.kind == SourceKind.danbooru ||
        (config.kind == SourceKind.gelbooru &&
            ['gelbooru.com', 'www.gelbooru.com'].contains(config.baseUrl.host));
    if (value == 'safe' || value == 's' && !modern) return 'g';
    return value.isEmpty ? '' : value[0];
  }

  Uri _pageUrl(int id) => switch (config.kind) {
    SourceKind.danbooru => _url('posts/$id'),
    SourceKind.moebooru => _url('post/show/$id'),
    _ => _url('index.php', {'page': 'post', 's': 'view', 'id': '$id'}),
  };

  Uri? _media(dynamic value, {bool legacy = false}) {
    if (value is! String || value.isEmpty) return null;
    try {
      var uri = _url('').resolve(value);
      if (legacy && uri.scheme == 'http') uri = uri.replace(scheme: 'https');
      return uri.scheme == 'https' &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty
          ? uri
          : null;
    } on FormatException {
      return null;
    }
  }

  static int _integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static List<String> _terms(dynamic value) => value is String
      ? value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
      : [];

  Document _document(String text) {
    if (!text.toLowerCase().contains('<html')) {
      throw const ContentException(
        'The server returned an unsupported gallery page.',
      );
    }
    return html.parse(text);
  }

  Future<ContentPage> _publicSearch(String tags, int page) async {
    final size = config.kind == SourceKind.oldGelbooru ? 20 : 42;
    final url = page == 1 ? null : _publicPages[tags]?[page];
    final offset = url == null
        ? (page - 1) * size
        : _integer(url.queryParameters['pid']);
    final document = _document(
      await _get(
        url ??
            _url('index.php', {
              'page': 'post',
              's': 'list',
              if (tags.isNotEmpty) 'tags': tags,
              if (offset > 0) 'pid': '$offset',
            }),
      ),
    );
    final posts = <ContentItem>[];
    final seen = <int>{};
    for (final anchor in document.querySelectorAll('a')) {
      final image = anchor.querySelector('img');
      if (image == null) continue;
      final link = Uri.tryParse(anchor.attributes['href'] ?? '');
      final id = _integer(
        (anchor.id.startsWith('p') ? anchor.id.substring(1) : null) ??
            (link?.queryParameters['s'] == 'view'
                ? link?.queryParameters['id']
                : null),
      );
      final preview = _media(
        image.attributes['data-original'] ??
            image.attributes['data-src'] ??
            image.attributes['src'],
        legacy: true,
      );
      if (id < 1 || preview == null || !seen.add(id)) continue;
      final terms = _terms(
        image.attributes['title'] ?? image.attributes['alt'],
      );
      posts.add(
        _post({
          'id': id,
          'preview_url': preview.toString(),
          'tags': terms
              .where((s) => !s.startsWith('score:') && !s.startsWith('rating:'))
              .join(' '),
          'score': terms
              .where((s) => s.startsWith('score:'))
              .firstOrNull
              ?.substring(6),
          'rating':
              terms
                  .where((s) => s.startsWith('rating:'))
                  .firstOrNull
                  ?.substring(7) ??
              '',
        }),
      );
    }
    if (posts.isEmpty &&
        !RegExp(
          r'nobody here|no images|no posts|no results',
          caseSensitive: false,
        ).hasMatch(document.body?.text ?? '')) {
      throw const ContentException(
        'The server returned an unsupported gallery page.',
      );
    }
    Uri? next;
    var nextOffset = 1 << 62;
    for (final anchor in document.querySelectorAll('a[href]')) {
      final uri = _url('index.php').resolve(anchor.attributes['href']!);
      final candidate = _integer(uri.queryParameters['pid']);
      if (_sameOrigin(uri) &&
          uri.queryParameters['s'] == 'list' &&
          candidate > offset &&
          candidate < nextOffset) {
        next = uri;
        nextOffset = candidate;
      }
    }
    if (page == 1) {
      if (_publicPages.length >= 32) _publicPages.clear();
      _publicPages[tags] = {};
    }
    if (next != null) (_publicPages[tags] ??= {})[page + 1] = next;
    return ContentPage(posts, hasMore: next != null);
  }

  Map<String, int> _sidebar(Document document) {
    final tags = <String, int>{};
    for (final item in document.querySelectorAll('li')) {
      for (final anchor in item.querySelectorAll('a[href]')) {
        final token = Uri.tryParse(anchor.attributes['href']!)
            ?.queryParameters['tags'];
        if (token == null ||
            token.isEmpty ||
            token.contains(' ') ||
            ['+', '-', '?'].contains(anchor.text.trim())) {
          continue;
        }
        tags.putIfAbsent(
          token,
          () => item.className.contains('artist')
              ? 1
              : RegExp(r'tag-(?:type|list)-(?:metadata|meta)')
                    .hasMatch(item.className)
              ? 5
              : 0,
        );
        break;
      }
    }
    return tags;
  }

  Future<List<String>> _publicSuggestions(String token) async {
    final document = _document(
      await _get(
        _url('index.php', {'page': 'post', 's': 'list', 'tags': '$token*'}),
      ),
    );
    return _sidebar(document).keys
        .where((s) => s.startsWith(token))
        .take(12)
        .toList();
  }

  Future<ContentItem> _publicDetail(int id) async {
    final document = _document(await _get(_pageUrl(id)));
    final image =
        document.querySelector('#image') ??
        document.querySelector('img[alt="img"]');
    final sources = document.querySelectorAll('source[type^="video/"]');
    final video =
        sources.where((s) => s.attributes['type'] == 'video/mp4').firstOrNull ??
        sources.firstOrNull;
    Uri? original;
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (![
        'original image',
        'original',
        'original video',
      ].contains(anchor.text.trim().toLowerCase())) {
        continue;
      }
      final candidate = _media(anchor.attributes['href'], legacy: true);
      if (candidate != null &&
          RegExp(
            r'\.(jpg|jpeg|png|gif|webp|avif|jxl|mp4|webm|mov)$',
            caseSensitive: false,
          ).hasMatch(candidate.path)) {
        original = candidate;
        break;
      }
    }
    final sample = _media(
      image?.attributes['data-original'] ??
          image?.attributes['data-src'] ??
          image?.attributes['src'],
      legacy: true,
    );
    final file =
        _media(
          video?.attributes['src'] ?? video?.attributes['data-src'],
          legacy: true,
        ) ??
        original ??
        sample;
    if (file == null) {
      throw const ContentException(
        'This post has no accessible media. It may be removed or restricted.',
      );
    }
    final sidebar = _sidebar(document);
    final tags = _terms(document.querySelector('textarea[name="tags"]')?.text);
    final text = document.body?.text ?? '';
    final dimensions = RegExp(
      r'Size:\s*(\d+)\s*x\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    final rating =
        RegExp(
          r'Rating:\s*([a-z]+)',
          caseSensitive: false,
        ).firstMatch(text)?.group(1) ??
        '';
    final score = RegExp(
      r'Score:\s*(-?\d+)',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    final item = _post({
      'id': id,
      'file_url': file.toString(),
      'sample_url': sample?.toString(),
      'width': dimensions?.group(1) ?? image?.attributes['width'],
      'height': dimensions?.group(2) ?? image?.attributes['height'],
      'tags': (tags.isEmpty ? sidebar.keys : tags).join(' '),
      'tag_string_artist': sidebar.entries
          .where((e) => e.value == 1)
          .map((e) => e.key)
          .join(' '),
      'tag_string_meta': sidebar.entries
          .where((e) => e.value == 5)
          .map((e) => e.key)
          .join(' '),
      'rating': rating,
      'score': score,
    });
    item.metadata['tagCategories'] = sidebar;
    return item;
  }

  @override
  void close() {
    _closed = true;
    _publicPages.clear();
    if (_ownsClient) _client.close();
  }
}
