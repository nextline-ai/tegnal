import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../support/swift_json.dart';
import 'content_errors.dart';
import 'content_transport.dart';
import 'content_url.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';

/// A bounded cache that forgets its oldest entry first, like `NSCache` with a count limit.
class BoundedCache<K, V> {
  BoundedCache(this.limit);
  final int limit;
  final _values = <K, V>{};

  V? operator [](K key) => _values[key];

  void operator []=(K key, V value) {
    _values.remove(key);
    _values[key] = value;
    while (_values.length > limit) {
      _values.remove(_values.keys.first);
    }
  }

  void remove(K key) => _values.remove(key);
  void clear() => _values.clear();
}

class _ResultRow {
  const _ResultRow(this.id, this.views);
  final int id;
  final int views;
}

class _FilterLane {
  _FilterLane({required this.visual});
  final bool visual;
  final pending = <_ResultRow>[];
  int? nextID;
  int? nextViews;
  bool more = true;
}

class _Feed {
  _Feed({required this.offset});
  final lanes = <_FilterLane>[];
  final ids = <int>[];
  int? nextID;
  int? nextViews;
  bool more = true;
  bool started = false;
  final int offset;
  final created = DateTime.now();
}

/// A numeric catalog with JSON search results and an embedded page manifest.
/// Only endpoint shapes and response fields identify this protocol.
class DocumentCatalogSource {
  DocumentCatalogSource(this.transport);

  final ContentTransport transport;
  String _site = '';
  final _feeds = <GalleryQuery, _Feed>{};
  final _documents = <int, (NativeGallery, DateTime)>{};
  final _previews = BoundedCache<String, NativeGallery>(512);
  static const _visualCategories = {3, 4, 6};

  NativeGallery? cachedPreview(int id) => _previews['${MangaUrls.home}#$id'];

  void _prepare(String requestedSite) {
    if (requestedSite != MangaUrls.home) throw const CancellationError();
    if (_site != requestedSite) {
      _site = requestedSite;
      _feeds.clear();
      _documents.clear();
      _previews.clear();
    }
  }

  Future<NativeGallery> gallery(int id, {required String site, bool force = false}) async {
    _prepare(site);
    final cached = _documents[id];
    if (!force && cached != null && DateTime.now().difference(cached.$2) < const Duration(seconds: 180)) return cached.$1;
    final url = id > 0 ? ContentURL.parse('${site}r/$id') : null;
    if (url == null) throw ContentError.invalidQuery;
    final result = await transport.get(url, limit: 4000000);
    _prepare(site);
    final gallery = parseGallery(result.data, id, site: site);
    MangaUrls.registerMedia([
      for (final page in gallery.pages) ...[?page.imageURL, ?page.thumbnailURL],
    ], site: site);
    if (_documents.length >= 128) {
      final oldest = _documents.entries.reduce((a, b) => a.value.$2.isBefore(b.value.$2) ? a : b).key;
      _documents.remove(oldest);
    }
    _documents[id] = (gallery, DateTime.now());
    _previews['$site#$id'] = gallery;
    return gallery;
  }

  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail, required String site}) async {
    _prepare(site);
    var current = page;
    final cached = _documents[galleryID]?.$1;
    final index = page.index;
    if (cached != null && index != null && index >= 0 && index < cached.pages.length) current = cached.pages[index];
    for (var attempt = 0; attempt < 2; attempt++) {
      // A missing thumbnail must never silently download a reader-sized image.
      final candidate = thumbnail ? current.thumbnailURL : current.imageURL;
      if (attempt > 0 || current.sourceSite != site || candidate == null || _expired(candidate)) {
        final document = await gallery(galleryID, site: site, force: true);
        if (index == null || index < 0 || index >= document.pages.length) throw ContentError.invalidResponse;
        current = document.pages[index];
      }
      final url = thumbnail ? current.thumbnailURL : current.imageURL;
      if (url == null) throw ContentError.invalidResponse;
      try {
        final result = await transport.get(url, limit: thumbnail ? 2000000 : 24000000, galleryID: galleryID);
        _prepare(site);
        if (!(result.response.mimeType?.startsWith('image/') ?? false) || result.data.length <= 32) throw ContentError.unsupportedFormat;
        return result.data;
      } on ContentError catch (error) {
        if (attempt == 0 && (error.isUnavailable(403) || error.isUnavailable(404) || error.isUnavailable(410))) continue;
        rethrow;
      }
    }
    throw ContentError.invalidResponse;
  }

  static List<Map<String, Object?>> _rows(List<int> data) {
    final Object? rows;
    try {
      rows = jsonDecode(utf8.decode(data));
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (rows is! List || rows.length > 100 || rows.any((row) => row is! Map)) throw ContentError.invalidResponse;
    return [for (final row in rows) (row as Map).cast<String, Object?>()];
  }

  static int? _int(Object? value) => value is num
      ? value.toInt()
      : value is bool
      ? (value ? 1 : 0)
      : null;

  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count, required String site}) async {
    _prepare(site);
    if (query.language != 'all' && query.allowsLanguageExceptions) return _listIncludingVisualCollections(query, offset: offset, count: count, site: site);
    var feed = _feeds[query] ?? _Feed(offset: offset);
    if (offset < feed.offset || offset > feed.offset + feed.ids.length || DateTime.now().difference(feed.created) > const Duration(seconds: 300)) {
      feed = _Feed(offset: offset);
    }
    final target = offset - feed.offset + count;
    final excluded = exclusions(query);
    var requests = 0;
    while (feed.ids.length < target && feed.more) {
      if (requests >= 8) {
        // Heavy exclusions show what was found rather than an error.
        if (feed.ids.length > offset - feed.offset) break;
        throw ContentError.invalidResponse;
      }
      final url = searchURL(query, site: site, offset: feed.started ? null : offset, nextID: feed.nextID, nextViews: feed.nextViews);
      final result = await transport.get(url, limit: 2000000);
      _prepare(site);
      final rows = _rows(result.data);
      final oldCursor = feed.nextID;
      final seen = feed.ids.toSet();
      for (final row in rows) {
        final id = _int(row['id']);
        if (id == null || id <= 0) throw ContentError.invalidResponse;
        if ((_int(row['blocked']) ?? 0) != 0 || _excludes(row, id, excluded)) continue;
        if (seen.add(id)) feed.ids.add(id);
        final preview = _preview(row, site);
        if (preview != null) _previews['$site#$id'] = preview;
      }
      feed.nextID = rows.isEmpty ? null : _int(rows.last['id']);
      feed.nextViews = query.sort == GallerySort.latest || rows.isEmpty ? null : _int(rows.last['views']);
      feed.more = rows.length == 50 && feed.nextID != oldCursor;
      feed.started = true;
      requests += 1;
    }
    _prepare(site);
    _storeFeed(query, feed);
    final start = offset - feed.offset;
    return GalleryBatch(ids: feed.ids.skip(start).take(count).toList(), hasMore: feed.more || feed.ids.length > start + count);
  }

  void _storeFeed(GalleryQuery query, _Feed feed) {
    if (_feeds.length >= 16 && !_feeds.containsKey(query)) {
      final oldest = _feeds.entries.reduce((a, b) => a.value.created.isBefore(b.value.created) ? a : b).key;
      _feeds.remove(oldest);
    }
    _feeds[query] = feed;
  }

  Future<GalleryBatch> _listIncludingVisualCollections(GalleryQuery query, {required int offset, required int count, required String site}) async {
    var feed = _feeds[query] ?? _Feed(offset: 0);
    if (offset < feed.offset || DateTime.now().difference(feed.created) > const Duration(seconds: 300)) feed = _Feed(offset: 0);
    if (feed.lanes.isEmpty) feed.lanes.addAll([_FilterLane(visual: false), _FilterLane(visual: true)]);
    final target = offset + count;
    final selected = selectedCategories(query);
    final excluded = exclusions(query);
    final seen = feed.ids.toSet();
    var requests = 0;
    while (feed.ids.length < target) {
      for (final lane in feed.lanes) {
        if (lane.pending.isNotEmpty || !lane.more) continue;
        final categories = lane.visual ? selected.intersection(_visualCategories) : selected.difference(_visualCategories);
        if (categories.isEmpty) {
          lane.more = false;
          continue;
        }
        if (requests >= 20) break;
        final remote = lane.visual ? query.copyWith(language: 'all') : query;
        final oldCursor = lane.nextID;
        final url = searchURL(remote, site: site, nextID: oldCursor, nextViews: lane.nextViews, restrictCategories: categories);
        final result = await transport.get(url, limit: 2000000);
        _prepare(site);
        final rows = _rows(result.data);
        for (final row in rows) {
          final id = _int(row['id']);
          if (id == null || id <= 0) throw ContentError.invalidResponse;
          if ((_int(row['blocked']) ?? 0) != 0) continue;
          final category = _int(row['category']) ?? 0;
          if (!categories.contains(category) || _excludes(row, id, excluded)) continue;
          lane.pending.add(_ResultRow(id, _int(row['views']) ?? 0));
          final preview = _preview(row, site);
          if (preview != null) _previews['$site#$id'] = preview;
        }
        lane.nextID = rows.isEmpty ? null : _int(rows.last['id']);
        lane.nextViews = query.sort == GallerySort.latest || rows.isEmpty ? null : _int(rows.last['views']);
        lane.more = rows.length == 50 && lane.nextID != oldCursor;
        requests += 1;
      }
      // A lane must have a head or be exhausted before merging the next rank.
      if (feed.lanes.any((lane) => lane.pending.isEmpty && lane.more)) {
        if (requests >= 20) break;
        continue;
      }
      final available = feed.lanes.where((lane) => lane.pending.isNotEmpty).toList();
      if (available.isEmpty) break;
      var chosen = available.first;
      for (final lane in available.skip(1)) {
        final first = chosen.pending.first, second = lane.pending.first;
        final ascending = query.sort == GallerySort.latest || first.views == second.views ? first.id < second.id : first.views < second.views;
        if (ascending) chosen = lane;
      }
      final next = chosen.pending.removeAt(0);
      if (seen.add(next.id)) feed.ids.add(next.id);
    }
    _prepare(site);
    feed.more = feed.lanes.any((lane) => lane.more || lane.pending.isNotEmpty);
    _storeFeed(query, feed);
    return GalleryBatch(ids: feed.ids.skip(offset).take(count).toList(), hasMore: feed.more || feed.ids.length > target);
  }

  Future<List<TagSuggestion>> suggestions(String token, {required String site}) async {
    _prepare(site);
    final context = TagCompletionContext.parse(token);
    if (context == null) return [];
    final url = ContentURL.withQueryItems('${site}ajax/search-tags', [('search', _remoteTerm(context.token))]);
    final result = await transport.get(url, limit: 64000);
    _prepare(site);
    final Object? values;
    try {
      values = jsonDecode(utf8.decode(result.data));
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (values is! List || values.length > 100 || values.any((value) => value is! String)) throw ContentError.invalidResponse;
    return [
      for (final value in values.cast<String>())
        if (swiftSplit(value, (character) => character == ':', maxSplits: 1) case [final namespace, final name]
            when TagSuggestion.namespaces.contains(_localNamespace(namespace)))
          TagSuggestion(namespace: _localNamespace(namespace), name: name),
    ];
  }

  static Uri searchURL(GalleryQuery query, {required String site, int? offset, int? nextID, int? nextViews, DateTime? now, Set<int>? restrictCategories}) {
    final terms = splitWhitespace(query.text).where((term) => !term.startsWith('-')).map(_remoteTerm).toList();
    if (query.language != 'all') terms.add('language:${query.language}');
    final artist = query.artist;
    if (artist != null) terms.add('artist:${artist.replaceAll(' ', '_')}');
    var categories = selectedCategories(query);
    if (restrictCategories != null) categories = categories.intersection(restrictCategories);
    terms.removeWhere((term) => term.startsWith('type:'));
    final items = <(String, String?)>[('search', terms.join(' ')), ('sort', query.sort == GallerySort.latest ? 'id_desc' : 'popular')];
    if (categories.length != 11) items.add(('categories', (categories.toList()..sort()).join(',')));
    if (query.sort != GallerySort.latest) {
      final days = switch (query.sort) {
        GallerySort.today => 1,
        GallerySort.week => 7,
        GallerySort.month => 30,
        _ => 365,
      };
      final start = (now ?? DateTime.now()).toUtc().subtract(Duration(days: days));
      String two(int value) => value.toString().padLeft(2, '0');
      items.add(('start-date', '${start.year.toString().padLeft(4, '0')}-${two(start.month)}-${two(start.day)}'));
    }
    if (nextID != null) {
      items.add((nextViews == null ? 'next-id' : 'next-views-id', '$nextID'));
      if (nextViews != null) items.add(('next-views', '$nextViews'));
    } else if (offset != null && offset > 0) {
      if (offset > 5000) throw ContentError.invalidQuery;
      items.add(('offset', '$offset'));
    }
    return ContentURL.withQueryItems('${site}ajax/search', items);
  }

  static Set<int> selectedCategories(GalleryQuery query) {
    final terms = splitWhitespace(query.text);
    final categories = terms.any((term) => term.startsWith('type:')) ? <int>{} : {for (var category = 1; category <= 11; category++) category};
    for (final term in terms.where((term) => term.startsWith('type:') || term.startsWith('-type:'))) {
      final name = swiftSplit(term, (character) => character == ':', maxSplits: 1).lastOrNull ?? '';
      final category = _categoryNames.entries.where((entry) => entry.value == name).firstOrNull?.key;
      if (category == null) throw ContentError.invalidQuery;
      if (term.startsWith('-')) {
        categories.remove(category);
      } else {
        categories.add(category);
      }
    }
    return categories;
  }

  static NativeGallery parseGallery(List<int> data, int id, {required String site}) {
    final object = embeddedObject(data, 'gallery');
    final files = object['files'];
    if (_int(object['id']) != id || files is! List || files.isEmpty || files.length > 10000 || files.any((file) => file is! Map)) {
      throw ContentError.invalidResponse;
    }
    if ((_int(object['blocked']) ?? 0) != 0) throw const ContentError.unavailable(403);
    final pages = <GalleryPage>[];
    for (final (index, file) in files.cast<Map>().indexed) {
      final image = file['image'];
      final value = image is Map ? image['url'] : null;
      final url = value is String ? ContentURL.parse(value) : null;
      final name = file['name'];
      if (image is! Map || url == null || !safeMediaURL(url) || name is! String) throw ContentError.unsupportedFormat;
      final thumbnail = file['thumbnail'];
      final preview = thumbnail is Map && thumbnail['url'] is String ? ContentURL.parse(thumbnail['url'] as String) : null;
      final identity = file['id'] is String ? file['id'] as String : '$id:$index:$name';
      pages.add(
        GalleryPage(
          hash: sha256.convert(utf8.encode('$site#$identity')).toString(),
          name: name,
          width: _int(image['width']) ?? 0,
          height: _int(image['height']) ?? 0,
          hasAVIF: false,
          imageURL: url,
          thumbnailURL: preview != null && safeMediaURL(preview) ? preview : null,
          index: index,
          sourceSite: site,
        ),
      );
    }
    return _metadata(object, id, pages);
  }

  /// Extract one JSON object, respecting quoted braces and escaped quotes.
  static Map<String, Object?> embeddedObject(List<int> data, String name) {
    if (data.length > 4000000) throw ContentError.unsupportedFormat;
    final String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      throw ContentError.unsupportedFormat;
    }
    final assignment = RegExp('\\b(?:const|let|var)\\s+${RegExp.escape(name)}\\s*=\\s*\\{').firstMatch(text);
    if (assignment == null) throw ContentError.unsupportedFormat;
    final start = assignment.end - 1;
    var depth = 0;
    var quoted = false, escaped = false;
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
        depth += 1;
      } else if (character == '}') {
        depth -= 1;
        if (depth == 0) {
          try {
            final object = jsonDecode(text.substring(start, index + 1));
            if (object is Map<String, Object?>) return object;
          } on FormatException {
            // Reported below.
          }
          throw ContentError.invalidResponse;
        }
      }
    }
    throw ContentError.invalidResponse;
  }

  static NativeGallery? _preview(Map<String, Object?> object, String site) {
    final id = _int(object['id']);
    final base = MangaUrls.preferences.string('manga.resolved_preview_base');
    final ext = object['thumb_extension'];
    if (id == null || id <= 0 || base == null || ext is! String || !['jpg', 'jpeg', 'png', 'webp', 'avif'].contains(ext)) return null;
    final url = ContentURL.parse('$base/${id ~/ 1000000}/${(id % 1000000) ~/ 1000}/${id % 1000}.$ext');
    if (url == null || !safeMediaURL(url)) return null;
    final page = GalleryPage(
      hash: sha256.convert(utf8.encode('$site#preview:$id')).toString(),
      name: 'preview',
      width: 0,
      height: 0,
      hasAVIF: false,
      imageURL: url,
      thumbnailURL: url,
      index: 0,
      sourceSite: site,
    );
    return _metadata(object, id, [page]);
  }

  static const _categoryNames = {
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

  static NativeGallery _metadata(Map<String, Object?> object, int id, List<GalleryPage> pages) {
    final tags = object['tags'];
    final pairs = <List<String>>[
      if (tags is List)
        for (final item in tags)
          if (item is Map && item['tag'] is List && (item['tag'] as List).length == 2 && (item['tag'] as List).every((part) => part is String))
            (item['tag'] as List).cast<String>(),
    ];
    final languages = [
      for (final pair in pairs)
        if (pair[0] == 'language') pair[1],
    ];
    final language = languages.where((value) => !_languageQualifiers.contains(value)).firstOrNull ?? '';
    final category = _int(object['category']) ?? 0;
    return NativeGallery(
      id: id,
      title: NativeGallery.decodeEntities(title(object, id, language: language, translated: languages.contains('translated'))),
      artists: [
        for (final pair in pairs)
          if (pair[0] == 'artist') pair[1],
      ],
      language: language,
      type: _categoryNames[category] ?? '',
      tags: [
        for (final pair in pairs)
          if (pair[0] != 'language' && pair[0] != 'artist') '${_localNamespace(pair[0])}:${pair[1]}',
      ],
      pages: pages,
      listedTitles: listedTitles(object),
      listedPageCount: object['files'] is List ? (object['files'] as List).length : null,
    );
  }

  static const _languageQualifiers = {'translated', 'rewrite'};

  /// The original-script title is kept even on translations, so it only leads for works still in Japanese.
  static List<String> listedTitles(Map<String, Object?> object) => [
    for (final key in ['title', 'title_jpn'])
      if (object[key] case final String value when value.isNotEmpty) NativeGallery.decodeEntities(value),
  ];

  static String title(Map<String, Object?> object, int id, {required String language, required bool translated}) {
    final main = (object['title'] is String ? object['title'] as String : '').trim();
    final original = (object['title_jpn'] is String ? object['title_jpn'] as String : '').trim();
    final prefersOriginal = !translated && ['', 'japanese', 'speechless'].contains(language);
    return [prefersOriginal ? original : main, main, original].where((value) => value.isNotEmpty).firstOrNull ?? '$id';
  }

  static bool safeMediaURL(Uri url) {
    if (url.scheme != 'https' || !ContentURL.hasNoCredentials(url) || !ContentURL.usesDefaultPort(url)) return false;
    return _safeHost(url.host.toLowerCase());
  }

  /// Never an address inside the device's network.
  static bool _safeHost(String host) {
    if (!host.contains('.') || host.contains(':') || host == 'localhost') return false;
    if (host.endsWith('.local') || host.endsWith('.localhost') || host.endsWith('.internal')) return false;
    return host.split('.').where((label) => label.isNotEmpty).map(int.tryParse).nonNulls.length != 4;
  }

  static bool safeHostForKeyed(String host) => _safeHost(host);

  static bool _expired(Uri url) {
    final value = ContentURL.queryValue(url, 'expires');
    final timestamp = value == null ? null : double.tryParse(value);
    if (timestamp == null) return false;
    return timestamp < DateTime.now().millisecondsSinceEpoch / 1000 + 30;
  }

  static String _localNamespace(String namespace) => switch (namespace) {
    'parody' => 'series',
    'other' => 'tag',
    _ => namespace,
  };

  static String _remoteTerm(String term) {
    if (term.startsWith('series:')) return 'parody:${term.substring(7)}';
    if (term.startsWith('tag:')) return 'other:${term.substring(4)}';
    return term;
  }

  /// The remote search reads a leading minus as part of an ordinary word, so
  /// exclusions stay out of the request and are checked on the returned rows.
  /// Categories are excluded in the request itself.
  static String exclusions(GalleryQuery query) => splitWhitespace(query.text).where((term) => term.startsWith('-') && !term.startsWith('-type:')).join(' ');

  static bool _excludes(Map<String, Object?> row, int id, String exclusions) => exclusions.isNotEmpty && _metadata(row, id, const []).isExcluded(exclusions);
}
