import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../core/content.dart';
import 'android_manga_client.dart';
import 'manga_fallback_client.dart';
import 'session_client.dart';

/// Read-only adapters for the indexed and document manga catalog protocols.
/// Downloaded scripts are parsed as data and are never evaluated.
class MangaSource implements ContentSource {
  MangaSource(this.config, {http.Client? client})
    : _ownsClient = client == null {
    if (config.kind != SourceKind.manga || !_safeUrl(config.baseUrl)) {
      throw const ContentException('Enter a valid HTTPS manga server address.');
    }
    if (client == null) {
      final androidClient = AndroidMangaClient.createIfSupported();
      if (androidClient == null) {
        _fallbackClient = null;
        _client = SessionClient(origin: config.baseUrl);
      } else {
        _fallbackClient = MangaFallbackClient(
          primary: androidClient,
          allowsUri: _allowsTransportUri,
        );
        _client = SessionClient(origin: config.baseUrl, inner: _fallbackClient);
      }
    } else {
      _fallbackClient = null;
      _client = client;
    }
    _home = config.baseUrl.replace(
      path: '${config.baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/',
    );
    _dataHost = 'ltn.${_home.host}';
    _cdnHost = _home.host;
  }

  final SourceConfig config;
  bool allowsLanguageExceptions = false;
  late final http.Client _client;
  late final MangaFallbackClient? _fallbackClient;
  final bool _ownsClient;
  late final Uri _home;
  late String _dataHost;
  late String _cdnHost;
  bool _document = false;
  bool _discovered = false;
  bool _closed = false;
  Uri? _previewBase;
  Future<void>? _discovery;
  Future<_Routing>? _routingFlight;
  _Routing? _routing;
  DateTime? _routingTime;
  final _details = <int, (ContentItem, DateTime)>{};
  final _detailFlights = <int, Future<ContentItem>>{};
  final _lists = <String, List<int>>{};
  final _feeds = <String, _Feed>{};
  final _abortRequests = <Completer<void>>{};
  static const _pageSize = 20;
  static const _namespaces = {
    'artist',
    'group',
    'series',
    'character',
    'tag',
    'type',
    'female',
    'male',
    'language',
  };
  static const _categories = {
    1: 'doujinshi',
    2: 'manga',
    3: 'artistcg',
    4: 'gamecg',
    5: 'western',
    6: 'imageset',
    7: 'non-h',
    8: 'cosplay',
    9: 'photo',
    10: 'misc',
    11: 'private',
  };

  @override
  Future<ContentPage> search(
    String query, {
    int page = 1,
    bool popular = false,
    String period = 'week',
  }) async {
    if (page < 1 ||
        page > 250000 ||
        !const {
          'today',
          'week',
          'month',
          'year',
          'latest',
          'recommended',
        }.contains(period)) {
      _invalidQuery();
    }
    final tokens = query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .toList();
    if (tokens.length > 64 ||
        tokens.any(
          (value) => value.length > 120 || value.contains('"') || value == '-',
        )) {
      _invalidQuery();
    }
    await _discover();
    if (_document) {
      return _documentSearch(tokens, page, popular, period: period);
    }
    final offset = (page - 1) * _pageSize;
    final List<int> ids;
    final bool hasMore;
    if (tokens.isEmpty) {
      final path = popular ? 'popular/$period-all.nozomi' : 'index-all.nozomi';
      final response = await _data(
        path,
        limit: _pageSize * 4,
        start: offset * 4,
        end: (offset + _pageSize) * 4,
      );
      if (response.statusCode == 416) {
        return const ContentPage([], hasMore: false);
      }
      final total = _validateRange(response, offset * 4);
      ids = _ids(response.bodyBytes);
      hasMore = offset * 4 + response.bodyBytes.length < total;
    } else {
      final key =
          '${popular ? 'popular' : 'latest'}:$period:$allowsLanguageExceptions:${tokens.join(' ')}';
      var matches = _lists[key];
      if (matches == null) {
        matches = await _searchIds(tokens);
        if (popular) {
          final selected = matches.toSet();
          matches = (await _fullList('popular/$period-all.nozomi'))
              .where(selected.contains)
              .toList();
        }
        _remember(_lists, key, matches, 8);
      }
      ids = matches.skip(offset).take(_pageSize).toList();
      hasMore = matches.length > offset + _pageSize;
    }
    // Keep catalog loading bounded instead of opening one connection per card.
    final items = <ContentItem>[];
    for (var start = 0; start < ids.length; start += 4) {
      final chunk = ids.skip(start).take(4);
      final values = await Future.wait(
        chunk.map((id) async {
          try {
            return await detail(id);
          } on ContentException catch (error) {
            if (error.statusCode == 403 || error.statusCode == 404) return null;
            rethrow;
          }
        }),
      );
      items.addAll(values.whereType<ContentItem>());
    }
    return ContentPage(items, hasMore: hasMore);
  }

  @override
  Future<ContentItem> detail(int id) async {
    if (id <= 0) _invalidQuery();
    await _discover();
    final cached = _details[id];
    if (cached != null && DateTime.now().difference(cached.$2).inMinutes < 3) {
      return cached.$1;
    }
    final pending = _detailFlights[id];
    if (pending != null) return pending;
    final future = _loadDetail(id);
    _detailFlights[id] = future;
    try {
      final item = await future;
      _remember(_details, id, (item, DateTime.now()), 128);
      return item;
    } finally {
      _detailFlights.remove(id);
    }
  }

  Future<ContentItem> _loadDetail(int id) async {
    if (_document) {
      final response = await _get(
        _home.resolve('r/$id'),
        limit: 4000000,
        referer: _galleryUrl(id),
      );
      final object = _embedded(response.body, 'gallery');
      if (_number(object['id']) != id) _badResponse();
      if (_number(object['blocked']) != 0) {
        throw const ContentException(
          'This work is unavailable.',
          statusCode: 403,
        );
      }
      final files = _files(object);
      for (final file in files) {
        final image = _map(file['image']);
        if (_media(image['url']) == null || file['name'] is! String) {
          _badResponse();
        }
      }
      return _documentItem(object, files: files);
    }
    final response = await _data(
      'galleries/$id.js',
      limit: 4000000,
      referer: _galleryUrl(id),
    );
    final match = RegExp(r'^\s*var\s+galleryinfo\s*=\s*')
        .firstMatch(response.body);
    if (match == null) _unsupported();
    var json = response.body.substring(match.end).trim();
    if (json.endsWith(';')) json = json.substring(0, json.length - 1).trim();
    final object = _jsonMap(json);
    final files = _files(object);
    for (final file in files) {
      if (!_hash(file['hash']) ||
          file['name'] is! String ||
          (file['name'] as String).isEmpty) {
        _unsupported();
      }
    }
    final routing = await _currentRouting();
    final first = files.first;
    final tags = <String>[];
    for (final row in _maps(object['tags'])) {
      if (row['tag'] is! String) continue;
      final namespaces = [
        'female',
        'male',
      ].where((name) => _flag(row[name])).toList();
      for (final namespace in namespaces.isEmpty ? ['tag'] : namespaces) {
        tags.add('$namespace:${row['tag']}');
      }
    }
    final language = object['language'] as String? ?? '';
    final type = object['type'] as String? ?? '';
    return ContentItem(
      sourceId: config.id,
      id: id,
      mode: AppMode.manga,
      title: _title(object, 'japanese_title', id),
      thumbnailUrl: routing.url(
        first['hash'] as String,
        _cdnHost,
        thumbnail: true,
      ),
      pageUrl: _galleryUrl(id),
      artists: _maps(object['artists'])
          .map((row) => row['artist'])
          .whereType<String>()
          .toList(),
      tags: [
        ...tags,
        if (language.isNotEmpty) 'language:$language',
        if (type.isNotEmpty) 'type:$type',
      ],
      width: _number(first['width']),
      height: _number(first['height']),
      pageCount: files.length,
      metadata: {
        'backend': 'indexed',
        'sourceSite': _home.toString(),
        'gallery': object,
        'files': files,
      },
    );
  }

  @override
  Future<List<ReaderPage>> pages(ContentItem item) async {
    if (item.sourceId != config.id || item.mode != AppMode.manga) {
      throw const ContentException('This work belongs to another source.');
    }
    await _discover();
    var current = item;
    var files = _maps(current.metadata['files']);
    if (files.isEmpty ||
        current.metadata['sourceSite'] != _home.toString() ||
        current.metadata['backend'] != (_document ? 'document' : 'indexed')) {
      current = await detail(item.id);
      files = _maps(current.metadata['files']);
    }
    if (_document &&
        files.any((file) => _expired(_media(_map(file['image'])['url'])))) {
      _details.remove(item.id);
      current = await detail(item.id);
      files = _maps(current.metadata['files']);
    }
    if (files.isEmpty) _badResponse();
    final headers = {'Referer': _galleryUrl(item.id).toString()};
    if (_document) {
      return files.map((file) {
        final image = _map(file['image']);
        final url = _media(image['url']);
        if (url == null || _expired(url)) {
          throw const ContentException(
            'The page address has expired. Reload this work.',
          );
        }
        return ReaderPage(
          url: url,
          thumbnailUrl: _media(_map(file['thumbnail'])['url']),
          width: _number(image['width']),
          height: _number(image['height']),
          headers: headers,
        );
      }).toList();
    }
    final routing = await _currentRouting();
    return files
        .map(
          (file) => ReaderPage(
            url: routing.url(file['hash'] as String, _cdnHost),
            thumbnailUrl: routing.url(
              file['hash'] as String,
              _cdnHost,
              thumbnail: true,
            ),
            width: _number(file['width']),
            height: _number(file['height']),
            headers: headers,
          ),
        )
        .toList();
  }

  @override
  Future<List<String>> suggestions(String query) async {
    if (query.isEmpty || RegExp(r'\s$').hasMatch(query)) return [];
    var token = query.split(RegExp(r'\s+')).last.toLowerCase();
    if (token.startsWith('-')) token = token.substring(1);
    final parts = token.split(':');
    final term = parts.last;
    if (parts.length > 2 ||
        token.length > 120 ||
        term.length < 2 ||
        term.length > 64 ||
        RegExp(r'^\d+$').hasMatch(term) ||
        term.contains('/') ||
        term.contains('"') ||
        (parts.length == 2 && !_namespaces.contains(parts.first))) {
      return [];
    }
    await _discover();
    if (_document) {
      final url = _home
          .resolve('ajax/search-tags')
          .replace(queryParameters: {'search': _remoteTerm(token)});
      final values = _jsonList((await _get(url, limit: 64000)).body);
      if (values.length > 100) _badResponse();
      return values
          .whereType<String>()
          .map((value) {
            final colon = value.indexOf(':');
            if (colon < 1) return '';
            return '${_localNamespace(value.substring(0, colon))}:${value.substring(colon + 1).replaceAll(' ', '_')}';
          })
          .where(
            (value) =>
                value.isNotEmpty &&
                _namespaces.contains(value.split(':').first),
          )
          .toSet()
          .toList();
    }
    final field = parts.length == 2 ? parts.first : 'global';
    final path = term
        .replaceAll('_', ' ')
        .runes
        .map((rune) {
          final character = String.fromCharCode(rune);
          return Uri.encodeComponent(
            character == ' '
                ? '_'
                : character == '.'
                ? 'dot'
                : character,
          );
        })
        .join('/');
    final url = Uri.parse('https://tagindex.${_home.host}/$field/$path.json');
    try {
      final values = _jsonList((await _get(url, limit: 64000)).body);
      if (values.length > 100) _badResponse();
      return values
          .whereType<List>()
          .where(
            (row) =>
                row.length == 3 &&
                row[0] is String &&
                row[1] is num &&
                (row[1] as num) >= 0 &&
                _namespaces.contains(row[2]) &&
                (row[0] as String).isNotEmpty &&
                (row[0] as String).length <= 120 &&
                !RegExp(r'[\r\n]').hasMatch(row[0] as String),
          )
          .map((row) => '${row[2]}:${(row[0] as String).replaceAll(' ', '_')}')
          .toSet()
          .toList();
    } on ContentException catch (error) {
      if (error.statusCode == 404) return [];
      rethrow;
    }
  }

  Future<ContentPage> _documentSearch(
    List<String> tokens,
    int page,
    bool popular, {
    bool bypass = true,
    Set<int>? restrictCategories,
    String period = 'week',
  }) async {
    if (bypass &&
        allowsLanguageExceptions &&
        tokens.any((token) => token.startsWith('language:'))) {
      return _documentLanguageBypass(tokens, page, popular, period);
    }
    var categories = tokens.any((token) => token.startsWith('type:'))
        ? <int>{}
        : _categories.keys.toSet();
    for (final token in tokens.where(
      (token) => token.startsWith('type:') || token.startsWith('-type:'),
    )) {
      final name = token.split(':').last;
      final category = _categories.entries
          .where((entry) => entry.value == name)
          .firstOrNull
          ?.key;
      if (category == null) _invalidQuery();
      if (token.startsWith('-')) {
        categories.remove(category);
      } else {
        categories.add(category);
      }
    }
    if (restrictCategories != null) {
      categories = categories.intersection(restrictCategories);
    }
    if (categories.isEmpty) return const ContentPage([], hasMore: false);
    final key =
        '$popular:$period:${tokens.join(' ')}:${(categories.toList()..sort()).join(',')}';
    var feed = _feeds[key];
    if (feed == null ||
        DateTime.now().difference(feed.created).inMinutes >= 5) {
      feed = _Feed();
      _remember(_feeds, key, feed, 16);
    }
    final offset = (page - 1) * _pageSize;
    final target = offset + _pageSize;
    var requests = 0;
    while (feed.items.length < target && feed.more) {
      if (++requests > 20) {
        throw const ContentException(
          'Load earlier pages before jumping this far.',
        );
      }
      final params = <String, String>{
        'search': tokens
            .where(
              (token) =>
                  !token.startsWith('type:') && !token.startsWith('-type:'),
            )
            .map(_remoteTerm)
            .join(' '),
        'sort': popular ? 'popular' : 'id_desc',
        if (categories.length != 11)
          'categories': (categories.toList()..sort()).join(','),
        if (popular)
          'start-date': DateTime.now()
              .toUtc()
              .subtract(
                Duration(
                  days: switch (period) {
                    'today' => 1,
                    'month' => 30,
                    'year' => 365,
                    _ => 7,
                  },
                ),
              )
              .toIso8601String()
              .substring(0, 10),
        if (feed.nextId != null)
          (popular && feed.nextViews != null ? 'next-views-id' : 'next-id'):
              '${feed.nextId}',
        if (popular && feed.nextViews != null)
          'next-views': '${feed.nextViews}',
      };
      final response = await _get(
        _home.resolve('ajax/search').replace(queryParameters: params),
        limit: 2000000,
      );
      final rows = _jsonList(response.body);
      if (rows.length > 100 || rows.any((row) => row is! Map)) _badResponse();
      final previous = feed.nextId;
      final seen = feed.items.map((item) => item.id).toSet();
      for (final value in rows) {
        final row = _map(value);
        if (_number(row['id']) <= 0) _badResponse();
        if (_number(row['blocked']) != 0 ||
            !categories.contains(_number(row['category']))) {
          continue;
        }
        if (seen.add(_number(row['id']))) feed.items.add(_documentItem(row));
      }
      if (rows.isNotEmpty) {
        final last = _map(rows.last);
        feed.nextId = _number(last['id']);
        feed.nextViews = last['views'] is num ? _number(last['views']) : null;
      }
      feed.more = rows.length == 50 && feed.nextId != previous;
    }
    return ContentPage(
      feed.items.skip(offset).take(_pageSize).toList(),
      hasMore: feed.more || feed.items.length > target,
    );
  }

  Future<ContentPage> _documentLanguageBypass(
    List<String> tokens,
    int page,
    bool popular,
    String period,
  ) async {
    final key = 'mixed:$popular:$period:${tokens.join(' ')}';
    var feed = _feeds[key];
    if (feed == null ||
        DateTime.now().difference(feed.created).inMinutes >= 5) {
      feed = _Feed()..lanes = [_DocumentLane(), _DocumentLane()];
      _remember(_feeds, key, feed, 16);
    }
    final target = page * _pageSize;
    var requests = 0;
    final seen = feed.items.map((item) => item.id).toSet();
    while (feed.items.length < target) {
      for (var index = 0; index < feed.lanes.length; index++) {
        final lane = feed.lanes[index];
        if (lane.pending.isNotEmpty || !lane.more) continue;
        if (++requests > 20) {
          throw const ContentException(
            'Load earlier pages before jumping this far.',
          );
        }
        final result = await _documentSearch(
          index == 0
              ? tokens
              : tokens
                    .where((token) => !token.startsWith('language:'))
                    .toList(),
          ++lane.page,
          popular,
          bypass: false,
          period: period,
          restrictCategories: index == 0
              ? _categories.keys
                    .where((key) => !const {3, 4, 6}.contains(key))
                    .toSet()
              : {3, 4, 6},
        );
        lane.pending.addAll(result.items);
        lane.more = result.hasMore;
      }
      if (feed.lanes.any((lane) => lane.pending.isEmpty && lane.more)) continue;
      final heads = feed.lanes
          .where((lane) => lane.pending.isNotEmpty)
          .toList();
      if (heads.isEmpty) break;
      heads.sort((a, b) {
        final first = a.pending.first, second = b.pending.first;
        if (popular) {
          final firstViews = _number(_map(first.metadata['gallery'])['views']);
          final secondViews = _number(
            _map(second.metadata['gallery'])['views'],
          );
          if (firstViews != secondViews) {
            return secondViews.compareTo(firstViews);
          }
        }
        return second.id.compareTo(first.id);
      });
      final next = heads.first.pending.removeAt(0);
      if (seen.add(next.id)) feed.items.add(next);
    }
    feed.more = feed.lanes.any((lane) => lane.more || lane.pending.isNotEmpty);
    return ContentPage(
      feed.items.skip((page - 1) * _pageSize).take(_pageSize).toList(),
      hasMore: feed.more || feed.items.length > target,
    );
  }

  ContentItem _documentItem(
    Map<String, dynamic> object, {
    List<Map<String, dynamic>>? files,
  }) {
    final id = _number(object['id']);
    final pairs = _maps(object['tags'])
        .map((row) => row['tag'])
        .whereType<List>()
        .where(
          (pair) => pair.length == 2 && pair.every((value) => value is String),
        )
        .toList();
    Uri? thumbnail;
    if (files != null) {
      thumbnail = _media(_map(files.first['thumbnail'])['url']);
    }
    final ext = object['thumb_extension'];
    if (thumbnail == null &&
        _previewBase != null &&
        ['jpg', 'jpeg', 'png', 'webp', 'avif'].contains(ext)) {
      thumbnail = _previewBase!.replace(
        path:
            '${_previewBase!.path.replaceFirst(RegExp(r'/+$'), '')}/${id ~/ 1000000}/${id % 1000000 ~/ 1000}/${id % 1000}.$ext',
      );
    }
    final type = _categories[_number(object['category'])];
    final image = files == null
        ? <String, dynamic>{}
        : _map(files.first['image']);
    return ContentItem(
      sourceId: config.id,
      id: id,
      mode: AppMode.manga,
      title: _title(object, 'title_jpn', id),
      thumbnailUrl: thumbnail,
      pageUrl: _galleryUrl(id),
      pageCount: files?.length ?? _number(object['file_count']),
      width: _number(image['width']),
      height: _number(image['height']),
      artists: pairs
          .where((pair) => pair.first == 'artist')
          .map((pair) => pair.last as String)
          .toList(),
      tags: [
        for (final pair in pairs.where((pair) => pair.first != 'artist'))
          '${_localNamespace(pair.first as String)}:${pair.last}',
        if (type != null) 'type:$type',
      ],
      metadata: {
        'backend': 'document',
        'sourceSite': _home.toString(),
        'gallery': object,
        'files': ?files,
      },
    );
  }

  Future<List<int>> _searchIds(List<String> tokens) async {
    Set<int>? included;
    final excluded = <int>{};
    String? version;
    for (final token in tokens) {
      final negative = token.startsWith('-');
      final term = (negative ? token.substring(1) : token).replaceAll('_', ' ');
      final colon = term.indexOf(':');
      List<int> ids;
      if (colon >= 0) {
        final field = term.substring(0, colon),
            value = term.substring(colon + 1);
        if (!_namespaces.contains(field) || value.isEmpty) _invalidQuery();
        final path = field == 'language'
            ? 'index-${Uri.encodeComponent(value)}.nozomi'
            : ['female', 'male'].contains(field)
            ? 'tag/${Uri.encodeComponent(term)}-all.nozomi'
            : '$field/${Uri.encodeComponent(value)}-all.nozomi';
        ids = await _fullList(path);
        if (field == 'language' && !negative && allowsLanguageExceptions) {
          final exceptions = await Future.wait(
            [
              'gamecg',
              'artistcg',
              'imageset',
            ].map((type) => _fullList('type/$type-all.nozomi')),
          );
          ids = {...ids, ...exceptions.expand((values) => values)}.toList()
            ..sort((a, b) => b.compareTo(a));
        }
      } else {
        version ??= (await _data(
          'galleriesindex/version',
          limit: 64,
        )).body.trim();
        if (!RegExp(r'^\d{1,20}$').hasMatch(version)) _unsupported();
        ids = await _keyword(term, version);
      }
      if (negative) {
        excluded.addAll(ids);
      } else {
        included = included == null
            ? ids.toSet()
            : included.intersection(ids.toSet());
      }
    }
    included ??= (await _fullList('index-all.nozomi')).toSet();
    return included.difference(excluded).toList()
      ..sort((a, b) => b.compareTo(a));
  }

  Future<List<int>> _fullList(String path) async {
    final cached = _lists['index:$path'];
    if (cached != null) return cached;
    try {
      final response = await _data(path, limit: 8000000);
      if (response.statusCode != 200) _badResponse();
      final ids = _ids(response.bodyBytes);
      _remember(_lists, 'index:$path', ids, 8);
      return ids;
    } on ContentException catch (error) {
      if (error.statusCode == 404) return [];
      rethrow;
    }
  }

  Future<List<int>> _keyword(String term, String version) async {
    final key = sha256.convert(utf8.encode(term)).bytes.take(4).toList();
    var address = 0;
    final visited = <int>{};
    for (var depth = 0; depth < 32; depth++) {
      if (address < 0 || !visited.add(address)) _badResponse();
      final bytes = await _readRange(
        'galleriesindex/galleries.$version.index',
        address,
        464,
      );
      final cursor = _Cursor(bytes);
      final count = cursor.u32();
      if (count > 16) _badResponse();
      final keys = <List<int>>[];
      for (var i = 0; i < count; i++) {
        if (cursor.u32() != 4) _unsupported();
        keys.add(cursor.take(4));
      }
      if (cursor.u32() != count) _badResponse();
      final locations = List.generate(
        count,
        (_) => (cursor.u64(), cursor.u32()),
      );
      final children = List.generate(17, (_) => cursor.u64());
      if (keys.isEmpty) return [];
      var position = 0;
      while (position < keys.length && _compare(keys[position], key) < 0) {
        position++;
      }
      if (position < keys.length && _compare(keys[position], key) == 0) {
        final (offset, length) = locations[position];
        if (length < 4 || length > 8000000) _badResponse();
        final data = await _readRange(
          'galleriesindex/galleries.$version.data',
          offset,
          length,
        );
        final reader = _Cursor(data);
        final size = reader.u32();
        if (size > 2000000 || data.length != 4 + size * 4) _badResponse();
        return _ids(Uint8List.sublistView(data, 4));
      }
      address = children[position];
      if (address == 0) return [];
    }
    _badResponse();
  }

  Future<Uint8List> _readRange(String path, int start, int length) async {
    final response = await _data(
      path,
      limit: length,
      start: start,
      end: start + length,
    );
    _validateRange(response, start);
    if (response.bodyBytes.length != length) _badResponse();
    return response.bodyBytes;
  }

  Future<_Routing> _currentRouting() async {
    if (_routing != null &&
        DateTime.now().difference(_routingTime!).inMinutes < 5) {
      return _routing!;
    }
    if (_routingFlight != null) return _routingFlight!;
    final future = () async {
      final routing = _Routing.parse(
        (await _data('gg.js', limit: 100000)).body,
      );
      _routing = routing;
      _routingTime = DateTime.now();
      return routing;
    }();
    _routingFlight = future;
    try {
      return await future;
    } finally {
      _routingFlight = null;
    }
  }

  Future<void> _discover({bool force = false}) async {
    _checkOpen();
    if (_discovery != null) return _discovery!;
    if (_discovered && !force) return;
    final future = _discoverOnce();
    _discovery = future;
    try {
      await future;
    } finally {
      _discovery = null;
    }
  }

  Future<void> _discoverOnce() async {
    final response = await _get(_home, limit: 1000000);
    final body = response.body;
    if (_extractIndexed(body)) {
      _discovered = true;
      return;
    }
    if (RegExp(r'/js/index\.search\.').hasMatch(body) ||
        (body.contains('/ajax/search') &&
            body.contains('serverConfig') &&
            body.contains('thumbServer'))) {
      _document = true;
      _dataHost = _cdnHost = _home.host;
      final match = RegExp(r'thumbServer\s*:\s*(\{[^{}]+\})').firstMatch(body);
      if (match != null) {
        try {
          _previewBase = _media(_jsonMap(match.group(1)!)['url']);
        } on ContentException {
          /* The preview is optional. */
        }
      }
      _discovered = true;
      return;
    }
    final scripts = <Uri>[];
    for (final node in html.parse(body).querySelectorAll('script[src]')) {
      final uri = _home.resolve(node.attributes['src']!);
      if (_safeUrl(uri) &&
          uri.host == _home.host &&
          uri.pathSegments.lastOrNull == 'common.js' &&
          !scripts.contains(uri)) {
        scripts.add(uri);
      }
      if (scripts.length == 3) break;
    }
    final common = _home.resolve('common.js');
    if (!scripts.contains(common)) scripts.add(common);
    for (final script in scripts) {
      try {
        if (_extractIndexed((await _get(script, limit: 1000000)).body)) {
          _discovered = true;
          return;
        }
      } on ContentException catch (error) {
        if (error.statusCode != 404) rethrow;
      }
    }
    throw const ContentException(
      'This server does not expose a supported manga catalog.',
    );
  }

  bool _extractIndexed(String text) {
    String? capture(String pattern) => RegExp(
      pattern,
      caseSensitive: false,
    ).firstMatch(text)?.group(1)?.toLowerCase();
    final domain = capture(
      r'''(?:var|let|const)\s+domain\s*=\s*['"]([a-z0-9-]+(?:\.[a-z0-9-]+)+)['"]''',
    );
    final endpoint =
        capture(
          r'''(?:(?:https?:)?//)([a-z0-9-]+(?:\.[a-z0-9-]+)+)/(?:gg\.js(?:[?"'\s>]|$)|galleries/[0-9]+\.js(?:[?"'\s>]|$))''',
        ) ??
        capture(
          r'''(?:(?:https?:)?//)(ltn\.[a-z0-9-]+(?:\.[a-z0-9-]+)+)/common\.js(?:[?"'\s>]|$)''',
        );
    if (domain == null && endpoint == null) return false;
    final base = domain ?? endpoint!;
    final cdn = base.startsWith('ltn.') ? base.substring(4) : base;
    final data = domain != null ? 'ltn.$cdn' : endpoint!;
    if (!_safeUrl(Uri.https(data)) || !_safeUrl(Uri.https(cdn))) return false;
    _document = false;
    _dataHost = data;
    _cdnHost = cdn;
    _routing = null;
    return true;
  }

  Future<http.Response> _data(
    String path, {
    required int limit,
    int? start,
    int? end,
    Uri? referer,
  }) async {
    try {
      return await _get(
        Uri.parse('https://$_dataHost/$path'),
        limit: limit,
        start: start,
        end: end,
        referer: referer,
      );
    } on _NetworkFailure {
      await _discover(force: true);
      return _get(
        Uri.parse('https://$_dataHost/$path'),
        limit: limit,
        start: start,
        end: end,
        referer: referer,
      );
    }
  }

  Future<http.Response> _get(
    Uri url, {
    required int limit,
    int? start,
    int? end,
    Uri? referer,
  }) async {
    _checkOpen();
    if (!_allowsTransportUri(url)) {
      throw const ContentException(
        'The server returned an unsupported address.',
      );
    }
    final abort = Completer<void>();
    _abortRequests.add(abort);
    try {
      return await (() async {
        final request = http.AbortableRequest(
          'GET',
          url,
          abortTrigger: abort.future,
        )..followRedirects = false;
        request.headers.addAll({
          'Accept': '*/*',
          'Referer': (referer ?? _home).toString(),
          'User-Agent': 'TEGNAL/1.0',
          if (start != null && end != null) 'Range': 'bytes=$start-${end - 1}',
        });
        final response = await _client.send(request);
        if (response.contentLength != null && response.contentLength! > limit) {
          await response.stream.listen((_) {}).cancel();
          throw const ContentException(
            'The server response is too large. Narrow your search.',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          _checkOpen();
          if (bytes.length + chunk.length > limit) {
            throw const ContentException(
              'The server response is too large. Narrow your search.',
            );
          }
          bytes.add(chunk);
        }
        if (response.statusCode != 200 &&
            response.statusCode != 206 &&
            !(response.statusCode == 416 && start != null)) {
          throw ContentException(
            response.statusCode == 404
                ? 'This work or catalog could not be found.'
                : response.statusCode == 403
                ? 'The server declined the request.'
                : 'The server could not complete the request (${response.statusCode}).',
            statusCode: response.statusCode,
          );
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          response.statusCode,
          headers: {
            ...response.headers,
            'content-type': 'application/octet-stream; charset=utf-8',
          },
          request: request,
        );
      })().timeout(const Duration(seconds: 20));
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const _NetworkFailure('The manga server timed out. Try again.');
    } on http.ClientException {
      _checkOpen();
      throw const _NetworkFailure('Unable to connect to the manga server.');
    } finally {
      _abortRequests.remove(abort);
    }
  }

  Uri _galleryUrl(int id) =>
      _home.resolve(_document ? 'r/$id' : 'galleries/$id.html');
  void _checkOpen() {
    if (_closed) throw const ContentException('This source has been closed.');
  }

  @override
  void close() {
    _closed = true;
    for (final abort in _abortRequests) {
      if (!abort.isCompleted) abort.complete();
    }
    _abortRequests.clear();
    if (_ownsClient) {
      _fallbackClient?.close();
      _client.close();
    }
    _details.clear();
    _feeds.clear();
    _lists.clear();
  }

  static int _validateRange(http.Response response, int start) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
        .firstMatch(response.headers['content-range'] ?? '');
    if (response.statusCode != 206 || match == null) _badResponse();
    final first = int.parse(match.group(1)!),
        last = int.parse(match.group(2)!),
        total = int.parse(match.group(3)!);
    if (first != start ||
        last < first ||
        last >= total ||
        last - first + 1 != response.bodyBytes.length) {
      _badResponse();
    }
    return total;
  }

  static List<int> _ids(Uint8List bytes) {
    if (bytes.length % 4 != 0) _badResponse();
    final cursor = _Cursor(bytes);
    return List.generate(bytes.length ~/ 4, (_) {
      final id = cursor.u32();
      if (id <= 0) _badResponse();
      return id;
    });
  }

  static Map<String, dynamic> _embedded(String text, String name) {
    final match = RegExp('\\b(?:const|let|var)\\s+$name\\s*=\\s*\\{')
        .firstMatch(text);
    if (match == null) _unsupported();
    final start = match.end - 1;
    var depth = 0, quoted = false, escaped = false;
    for (var index = start; index < text.length; index++) {
      final character = text[index];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (character == r'\') {
          escaped = true;
        } else if (character == '"') {
          quoted = false;
        }
      } else if (character == '"') {
        quoted = true;
      } else if (character == '{') {
        depth++;
      } else if (character == '}' && --depth == 0) {
        return _jsonMap(text.substring(start, index + 1));
      }
    }
    _badResponse();
  }

  static Map<String, dynamic> _jsonMap(String text) {
    try {
      final object = jsonDecode(text);
      if (object is Map<String, dynamic>) return object;
    } on FormatException {
      _badResponse();
    }
    _badResponse();
  }

  static List<dynamic> _jsonList(String text) {
    try {
      final object = jsonDecode(text);
      if (object is List) return object;
    } on FormatException {
      _badResponse();
    }
    _badResponse();
  }

  static List<Map<String, dynamic>> _files(Map<String, dynamic> object) {
    final raw = object['files'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 10000 ||
        raw.any((file) => file is! Map)) {
      _badResponse();
    }
    return raw.map(_map).toList();
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static List<Map<String, dynamic>> _maps(dynamic value) =>
      value is List ? value.whereType<Map>().map(_map).toList() : [];
  static int _number(dynamic value) => value is num ? value.toInt() : 0;
  static bool _flag(dynamic value) =>
      value == true || value == 1 || value == '1' || value == 'true';
  static bool _hash(dynamic value) =>
      value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  static String _title(Map<String, dynamic> object, String japanese, int id) {
    final preferred = object[japanese];
    final title = preferred is String && preferred.trim().isNotEmpty
        ? preferred
        : object['title'] as String? ?? 'Work $id';
    return html
            .parseFragment(
              title.replaceAll('<', '&lt;').replaceAll('>', '&gt;'),
            )
            .text ??
        title;
  }

  static String _localNamespace(String namespace) => namespace == 'parody'
      ? 'series'
      : namespace == 'other'
      ? 'tag'
      : namespace;
  static String _remoteTerm(String token) {
    final prefix = token.startsWith('-') ? '-' : '';
    final value = token.startsWith('-') ? token.substring(1) : token;
    if (value.startsWith('series:')) {
      return '${prefix}parody:${value.substring(7)}';
    }
    if (value.startsWith('tag:')) return '${prefix}other:${value.substring(4)}';
    return token;
  }

  static bool _safeUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        host.contains('.') &&
        !host.contains(':') &&
        !RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) &&
        !['.local', '.localhost', '.internal'].any(host.endsWith) &&
        host
            .split('.')
            .every(
              (part) =>
                  RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(part),
            );
  }

  bool _allowsTransportUri(Uri uri) {
    final allowed = [_home.host, _dataHost, _cdnHost];
    return _safeUrl(uri) &&
        allowed.any((host) => uri.host == host || uri.host.endsWith('.$host'));
  }

  static Uri? _media(dynamic value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null && _safeUrl(uri) ? uri : null;
  }

  static bool _expired(Uri? uri) {
    if (uri == null) return true;
    final expiry = double.tryParse(uri.queryParameters['expires'] ?? '');
    return expiry != null &&
        expiry < DateTime.now().millisecondsSinceEpoch / 1000 + 30;
  }

  static int _compare(List<int> a, List<int> b) {
    for (var index = 0; index < a.length; index++) {
      final result = a[index].compareTo(b[index]);
      if (result != 0) return result;
    }
    return 0;
  }

  static void _remember<K, V>(Map<K, V> map, K key, V value, int limit) {
    map.remove(key);
    map[key] = value;
    while (map.length > limit) {
      map.remove(map.keys.first);
    }
  }

  static Never _invalidQuery() => throw const ContentException(
    'Check your search. Separate terms with spaces and join words within tags with underscores.',
  );
  static Never _badResponse() =>
      throw const ContentException('Unable to read the manga server response.');
  static Never _unsupported() =>
      throw const ContentException('The manga server format is not supported.');
}

class _DocumentLane {
  final pending = <ContentItem>[];
  int page = 0;
  bool more = true;
}

class _Feed {
  List<_DocumentLane> lanes = [];
  final created = DateTime.now();
  final items = <ContentItem>[];
  int? nextId;
  int? nextViews;
  bool more = true;
}

class _NetworkFailure extends ContentException {
  const _NetworkFailure(super.message);
}

class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  List<int> take(int length) {
    if (length < 0 || offset + length > bytes.length) {
      MangaSource._badResponse();
    }
    final result = bytes.sublist(offset, offset + length);
    offset += length;
    return result;
  }

  int u32() => take(4).fold(0, (value, byte) => (value << 8) | byte);
  int u64() {
    final value = take(8);
    if (value.first >= 128) MangaSource._badResponse();
    return value.fold(0, (result, byte) => (result << 8) | byte);
  }
}

class _Routing {
  _Routing(this.prefix, this.initial, this.alternate, this.buckets);
  final String prefix;
  final int initial;
  final int alternate;
  final Set<int> buckets;
  factory _Routing.parse(String text) {
    // This grammar is deliberately closed: changed scripts fail visibly.
    final pattern = RegExp(
      r"^\s*'use strict';\s*gg\s*=\s*\{\s*m:\s*function\(g\)\s*\{\s*var o = ([01]);\s*switch \(g\) \{\s*((?:case \d+:\s*)+)o = ([01]); break;\s*\}\s*return o;\s*\},\s*s: function\(h\) \{ var m = /\(\.\.\)\(\.\)\$/.exec\(h\); return parseInt\(m\[2\]\+m\[1\], 16\).toString\(10\); \},\s*b: '([0-9]+/)'\s*\};\s*$",
      dotAll: true,
    );
    final match = pattern.firstMatch(text);
    if (match == null) MangaSource._unsupported();
    final buckets = RegExp(r'case (\d+):')
        .allMatches(match.group(2)!)
        .map((value) => int.parse(value.group(1)!))
        .toSet();
    if (buckets.any((value) => value < 0 || value >= 4096)) {
      MangaSource._unsupported();
    }
    return _Routing(
      match.group(4)!,
      int.parse(match.group(1)!),
      int.parse(match.group(3)!),
      buckets,
    );
  }
  Uri url(String hash, String cdn, {bool thumbnail = false}) {
    if (!MangaSource._hash(hash)) MangaSource._unsupported();
    final a = hash.substring(63), b = hash.substring(61, 63);
    final bucket = int.parse('$a$b', radix: 16);
    final choice = buckets.contains(bucket) ? alternate : initial;
    final host = thumbnail ? (choice == 0 ? 'atn' : 'btn') : 'w${choice + 1}';
    final path = thumbnail
        ? 'webpsmalltn/$a/$b/$hash.webp'
        : '$prefix$bucket/$hash.webp';
    return Uri.parse('https://$host.$cdn/$path');
  }
}
