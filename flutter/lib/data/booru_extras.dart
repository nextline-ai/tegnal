import 'dart:async';
import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../core/content.dart';
import 'booru_source.dart';
import 'source_http_client.dart';

class BooruPool {
  const BooruPool({
    required this.id,
    required this.name,
    this.postCount,
    this.description = '',
  });
  final int id;
  final String name;
  final int? postCount;
  final String description;
}

class BooruPoolPage {
  const BooruPoolPage(this.pools, {required this.hasMore});
  final List<BooruPool> pools;
  final bool hasMore;
}

class BooruNote {
  const BooruNote({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.body,
  });
  final int id;
  final double x;
  final double y;
  final double width;
  final double height;
  final String body;
}

/// Optional public JSON APIs. Legacy/Gelbooru HTML extras are deliberately
/// reported as unsupported rather than presenting an empty successful result.
class BooruExtras {
  BooruExtras(this.config, {http.Client? client})
    : _client = client ?? SourceHttpClient(origin: config.baseUrl),
      _ownsClient = client == null;
  final SourceConfig config;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;
  bool get supported =>
      config.kind == SourceKind.danbooru || config.kind == SourceKind.moebooru;

  void _requireSupported() {
    if (!supported) {
      throw const ContentException(
        'Pools and notes are not supported for this server type.',
      );
    }
    if (_closed) throw const ContentException('This source is closed.');
  }

  Uri _url(String path, Map<String, String> query) => config.baseUrl.replace(
    path: '${config.baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
    queryParameters: query,
  );

  Future<List<Map<String, dynamic>>> _rows(
    String path,
    Map<String, String> query,
  ) async {
    _requireSupported();
    try {
      final request = http.Request('GET', _url(path, query))
        ..followRedirects = false;
      request.headers['Accept'] = 'application/json';
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.drain<void>();
        throw ContentException(switch (response.statusCode) {
          401 => 'This server requires an account or API key.',
          403 =>
            'The server requires browser verification or access permission.',
          429 => 'The server is busy. Wait a moment before trying again.',
          _ => 'Unable to load this feature (HTTP ${response.statusCode}).',
        }, statusCode: response.statusCode);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (bytes.length + chunk.length >= 12000000) {
          throw const ContentException('The server response is too large.');
        }
        bytes.addAll(chunk);
      }
      final body = utf8.decode(bytes);
      final prefix = body
          .substring(0, body.length.clamp(0, 4096))
          .toLowerCase();
      if (prefix.contains('cf-chl-') ||
          prefix.contains('just a moment') ||
          prefix.contains('<html')) {
        throw const ContentException(
          'The server requires browser verification.',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.any((value) => value is! Map)) {
        throw const FormatException();
      }
      return decoded
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();
    } on ContentException {
      rethrow;
    } on FormatException {
      throw const ContentException(
        'The server returned an unsupported response.',
      );
    } on Exception {
      throw const ContentException(
        'Unable to load. Check the connection and retry.',
      );
    }
  }

  Future<BooruPoolPage> pools(String query, {int page = 1}) async {
    _requireSupported();
    if (page < 1) throw ArgumentError.value(page, 'page');
    final danbooru = config.kind == SourceKind.danbooru;
    final rows = await _rows(danbooru ? 'pools.json' : 'pool.json', {
      'page': '$page',
      'limit': '20',
      if (query.trim().isNotEmpty)
        danbooru ? 'search[name_matches]' : 'query': danbooru
            ? '*${query.trim()}*'
            : query.trim(),
      if (danbooru) 'only': 'id,name,post_count,description',
    });
    final pools = <BooruPool>[];
    for (final row in rows) {
      final id = _int(row['id']);
      final name = row['name'];
      if (id < 1 || name is! String) {
        throw const ContentException('The server returned an invalid pool.');
      }
      pools.add(
        BooruPool(
          id: id,
          name: name,
          description: row['description'] is String
              ? _plainText(row['description'] as String)
              : '',
          postCount: row['post_count'] == null ? null : _int(row['post_count']),
        ),
      );
    }
    return BooruPoolPage(pools, hasMore: rows.length >= 20);
  }

  Future<ContentPage> poolPosts(int poolId, {int page = 1}) async {
    _requireSupported();
    if (poolId < 1 || page < 1) {
      throw ArgumentError('Pool ID and page must be positive.');
    }
    final source = BooruSource(config, client: _client);
    try {
      return await source.search(
        '${config.kind == SourceKind.danbooru ? 'ordpool' : 'pool'}:$poolId',
        page: page,
      );
    } finally {
      source.close();
    }
  }

  Future<List<BooruNote>> notes(int postId) async {
    _requireSupported();
    if (postId < 1) throw ArgumentError.value(postId, 'postId');
    final result = <BooruNote>[];
    final seen = <int>{};
    for (var page = 1; page <= 50; page++) {
      final danbooru = config.kind == SourceKind.danbooru;
      final rows = await _rows(
        danbooru ? 'notes.json' : 'note.json',
        danbooru
            ? {
                'search[post_id]': '$postId',
                'search[is_active]': 'true',
                'limit': '200',
                'page': '$page',
              }
            : {'post_id': '$postId'},
      );
      var newIds = 0;
      for (final row in rows) {
        final id = _int(row['id']);
        if (id < 1 || !seen.add(id)) continue;
        newIds++;
        if (row['is_active'] == false ||
            ['false', '0'].contains('${row['is_active']}')) {
          continue;
        }
        final width = _double(row['width']);
        final height = _double(row['height']);
        final body = row['body'];
        if (width <= 0 || height <= 0 || body is! String) continue;
        result.add(
          BooruNote(
            id: id,
            x: _double(row['x']),
            y: _double(row['y']),
            width: width,
            height: height,
            body: _plainText(body),
          ),
        );
      }
      if (!danbooru || rows.length < 200) return result;
      if (newIds == 0) {
        throw const ContentException(
          'The server did not advance to the next notes page.',
        );
      }
    }
    throw const ContentException(
      'This post exceeds the supported notes limit.',
    );
  }

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static double _double(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse('$value') ?? 0;
    return number.isFinite ? number : 0;
  }

  static String _plainText(String value) {
    final fragment = html.parseFragment(
      value.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n'),
    );
    for (final element in fragment.querySelectorAll('script, style')) {
      element.remove();
    }
    return fragment.text?.trim() ?? '';
  }

  void close() {
    _closed = true;
    if (_ownsClient) _client.close();
  }
}
