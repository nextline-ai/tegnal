import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../support/swift_json.dart';
import 'cdn_routing.dart';
import 'content_errors.dart';
import 'content_transport.dart';
import 'content_url.dart';
import 'document_catalog_source.dart';
import 'gallery_content.dart';
import 'keyed_catalog_source.dart';
import 'manga_urls.dart';
import '../support/perf_trace.dart';

class _IndexPrefix {
  _IndexPrefix({List<int>? ids, this.more = true}) : ids = ids ?? [];
  final List<int> ids;
  bool more;
  final created = DateTime.now();
}

class _GalleryFlight {
  _GalleryFlight(this.future);
  final Future<NativeGallery> future;
  int consumers = 0;
}

/// Works, lists, suggestions and images of the connected comics site, whichever of the
/// three protocols it turned out to speak.
class MangaContentSource extends ContentProviding {
  MangaContentSource({ContentTransport? transport})
    : transport = transport ?? ContentTransport.shared,
      documents = DocumentCatalogSource(transport ?? ContentTransport.shared),
      keyed = KeyedCatalogSource(transport ?? ContentTransport.shared);

  static MangaContentSource shared = MangaContentSource();

  final ContentTransport transport;
  final DocumentCatalogSource documents;
  final KeyedCatalogSource keyed;
  String _activeSite = '';
  (CDNRouting, DateTime)? _routing;
  Future<CDNRouting>? _routingTask;
  final _suggestionCache = <String, (List<TagSuggestion>, DateTime)>{};
  (GalleryQuery, List<int>, DateTime)? _searchCache;
  final _indexPrefixes = <String, _IndexPrefix>{};
  static const _visualTypes = ['artistcg', 'gamecg', 'imageset'];
  final _galleryFlights = <int, _GalleryFlight>{};
  final _galleryCache = BoundedCache<int, (NativeGallery, String)>(512);

  @override
  NativeGallery? cachedGallery(int id) {
    final cached = _galleryCache[id];
    return cached != null && cached.$2 == MangaUrls.home ? cached.$1 : null;
  }

  @override
  NativeGallery? cachedPreview(int id) =>
      cachedGallery(id) ??
      switch (MangaUrls.backend) {
        MangaBackend.document => documents.cachedPreview(id),
        MangaBackend.keyed => keyed.cachedPreview(id),
        MangaBackend.indexed => null,
      };

  String _prepareSite() {
    final site = MangaUrls.home;
    if (site.isEmpty) throw const NetworkError(NetworkErrorCode.unsupportedURL);
    if (_activeSite != site) {
      _activeSite = site;
      _galleryFlights.clear();
      _galleryCache.clear();
      _routingTask = null;
      _routing = null;
      _suggestionCache.clear();
      _searchCache = null;
      _indexPrefixes.clear();
    }
    return site;
  }

  Future<MangaBackend> _resolve(String site) async {
    await MangaUrls.resolveBackend(transport: transport);
    if (MangaUrls.home != site) throw const CancellationError();
    if (MangaUrls.requiresSignIn) throw ContentError.signInRequired;
    return MangaUrls.backend;
  }

  @override
  Future<List<TagSuggestion>> suggestions(String token) async {
    final context = TagCompletionContext.parse(token);
    if (context == null) return [];
    final site = _prepareSite();
    switch (await _resolve(site)) {
      case MangaBackend.document:
        return documents.suggestions(token, site: site);
      case MangaBackend.keyed:
        return keyed.suggestions(token, site: site);
      case MangaBackend.indexed:
        break;
    }
    final key = context.token;
    final cached = _suggestionCache[key];
    if (cached != null && DateTime.now().difference(cached.$2) < const Duration(seconds: 900)) return cached.$1;
    final target = suggestionURL(key);
    List<TagSuggestion> items;
    try {
      final result = await transport.get(target, limit: 64000);
      if (result.response.statusCode != 200) throw ContentError.invalidResponse;
      items = TagSuggestion.parse(result.data);
    } on ContentError catch (error) {
      if (!error.isUnavailable(404)) rethrow;
      items = [];
    }
    if (MangaUrls.home != site) throw const CancellationError();
    if (_suggestionCache.length >= 64) {
      _suggestionCache.remove(_suggestionCache.entries.reduce((a, b) => a.value.$2.isBefore(b.value.$2) ? a : b).key);
    }
    _suggestionCache[key] = (items, DateTime.now());
    return items;
  }

  static Uri suggestionURL(String token) {
    final context = TagCompletionContext.parse(token);
    if (context == null) throw ContentError.invalidQuery;
    final parts = swiftSplit(context.token, (character) => character == ':', maxSplits: 1);
    final field = parts.length == 2 ? parts[0] : 'global';
    final term = parts.last.replaceAll('_', ' ');
    final chars = [
      for (final rune in term.runes)
        ContentURL.alphanumerics(switch (String.fromCharCode(rune)) {
          ' ' => '_',
          '.' => 'dot',
          final character => character,
        }),
    ].join('/');
    final url = MangaUrls.configuredHost.isEmpty ? null : Uri.tryParse('https://tagindex.${MangaUrls.configuredHost}/$field/$chars.json');
    if (url == null) throw ContentError.invalidQuery;
    return url;
  }

  @override
  Future<NativeGallery> gallery(int id) => PerfTrace.span('manga gallery', () => _gallery(id), detail: '#$id');

  Future<NativeGallery> _gallery(int id) async {
    if (id <= 0) throw ContentError.invalidQuery;
    final site = _prepareSite();
    final backend = await _resolve(site);
    final cached = _galleryCache[id];
    if (cached != null) return cached.$1;
    var flight = _galleryFlights[id];
    if (flight == null) {
      flight = _GalleryFlight(_loadGallery(id, site: site, backend: backend));
      _galleryFlights[id] = flight;
      final current = flight;
      unawaited(
        current.future.then(
          (gallery) {
            if (_galleryFlights[id] == current) _galleryFlights.remove(id);
            if (MangaUrls.home == site && _activeSite == site) _galleryCache[id] = (gallery, site);
          },
          onError: (Object _) {
            if (_galleryFlights[id] == current) _galleryFlights.remove(id);
          },
        ),
      );
    }
    flight.consumers += 1;
    try {
      final gallery = await flight.future;
      if (MangaUrls.home != site) throw const CancellationError();
      return gallery;
    } finally {
      flight.consumers -= 1;
    }
  }

  Future<NativeGallery> _loadGallery(int id, {required String site, required MangaBackend backend}) async {
    if (backend != MangaBackend.indexed) {
      final document = backend == MangaBackend.keyed ? await keyed.gallery(id, site: site) : await documents.gallery(id, site: site);
      if (MangaUrls.home != site) throw const CancellationError();
      return document;
    }
    final result = await transport.getData('galleries/$id.js', limit: 4000000, galleryID: id);
    final document = NativeGallery.parse(result.data, id);
    if (MangaUrls.home != site) throw const CancellationError();
    return document;
  }

  /// Used by tests to wait for consumers, not wall-clock delays.
  int galleryConsumerCount(int id) => _galleryFlights[id]?.consumers ?? 0;

  /// The signed-in account's favorites, a page at a time, on catalogs that keep them.
  Future<(List<int>, String?)> accountFavorites({String? after}) async {
    final site = _prepareSite();
    if (await _resolve(site) != MangaBackend.keyed) throw ContentError.unsupportedFormat;
    return keyed.favorites(after: after, site: site);
  }

  Future<void> setAccountFavorite(int id, {required bool saved}) async {
    final site = _prepareSite();
    if (await _resolve(site) != MangaBackend.keyed) return;
    await keyed.setFavorite(id, saved: saved, site: site);
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) => PerfTrace.span(
    'manga list',
    () => _list(query, offset: offset, count: count),
    detail: 'offset $offset count $count',
  );

  Future<GalleryBatch> _list(GalleryQuery query, {required int offset, required int count}) async {
    if (!RegExp(r'^[a-z]{2,24}$').hasMatch(query.language) || offset < 0 || offset >= 10000000 || count < 1 || count > 100) throw ContentError.invalidQuery;
    final site = _prepareSite();
    switch (await _resolve(site)) {
      case MangaBackend.document:
        return documents.list(query, offset: offset, count: count, site: site);
      case MangaBackend.keyed:
        return keyed.list(query, offset: offset, count: count, site: site);
      case MangaBackend.indexed:
        // Covers need the image routing right after the list arrives; loading it alongside
        // the list keeps the first covers from waiting another round trip.
        _currentRouting(force: false).ignore();
    }
    final emptyText = query.text.trim().isEmpty;
    if (query.language != 'all' && query.allowsLanguageExceptions && query.sort == GallerySort.latest && query.artist == null && emptyText) {
      final target = ((offset + count + 128) ~/ 128) * 128;
      final ids = {...await _indexPrefix('index-${query.language}.nozomi', target)};
      var more = _indexPrefixes['index-${query.language}.nozomi']?.more ?? false;
      for (final type in _visualTypes) {
        final path = 'type/$type-all.nozomi';
        ids.addAll(await _indexPrefix(path, target, optional: true));
        more = more || (_indexPrefixes[path]?.more ?? false);
      }
      if (MangaUrls.home != site) throw const CancellationError();
      final sorted = ids.toList()..sort((a, b) => b.compareTo(a));
      return GalleryBatch(ids: sorted.skip(offset).take(count).toList(), hasMore: sorted.length > offset + count || more);
    }
    if (!emptyText || query.artist != null || (query.language != 'all' && query.sort != GallerySort.latest)) {
      final List<int> ids;
      final cached = _searchCache;
      if (cached != null && cached.$1 == query && DateTime.now().difference(cached.$3) < const Duration(seconds: 300)) {
        ids = cached.$2;
      } else {
        var ranked = await _search(query);
        if (query.sort != GallerySort.latest) {
          final matches = ranked.toSet();
          ranked = (await _fullList('popular/${query.sort.rawValue}-all.nozomi')).where(matches.contains).toList();
        }
        ids = ranked;
        if (MangaUrls.home != site) throw const CancellationError();
        _searchCache = (query, ids, DateTime.now());
      }
      return GalleryBatch(ids: ids.skip(offset).take(count).toList(), hasMore: ids.length > offset + count);
    }
    final artist = query.artist;
    final path = query.sort != GallerySort.latest
        ? 'popular/${query.sort.rawValue}-${query.language}.nozomi'
        : artist != null
        ? 'artist/${_segment(artist)}-${query.language}.nozomi'
        : 'index-${query.language}.nozomi';
    final range = (offset * 4, (offset + count) * 4);
    final result = await transport.getData(path, limit: count * 4, range: range);
    if (MangaUrls.home != site) throw const CancellationError();
    if (result.response.statusCode == 416) return const GalleryBatch(ids: [], hasMore: false);
    final total = validateRange(result.response, start: range.$1, received: result.data.length);
    return GalleryBatch(ids: BinaryCursor.ids(result.data), hasMore: range.$1 + result.data.length < total);
  }

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) =>
      PerfTrace.span(thumbnail ? 'manga thumbnail' : 'manga page', () => _image(page, galleryID: galleryID, thumbnail: thumbnail));

  Future<Uint8List> _image(GalleryPage page, {required int galleryID, required bool thumbnail}) async {
    final site = _prepareSite();
    final backend = await _resolve(site);
    final previousSite = page.sourceSite, index = page.index;
    if (previousSite != null && previousSite != site && index != null) {
      final updated = await gallery(galleryID);
      if (index < 0 || index >= updated.pages.length) throw ContentError.invalidResponse;
      return image(updated.pages[index], galleryID: galleryID, thumbnail: thumbnail);
    }
    if (backend == MangaBackend.document) return documents.image(page, galleryID: galleryID, thumbnail: thumbnail, site: site);
    if (backend == MangaBackend.keyed) return keyed.image(page, galleryID: galleryID, thumbnail: thumbnail, site: site);
    final formats = page.hasAVIF ? ['webp', 'avif'] : ['webp'];
    Object lastError = ContentError.unsupportedFormat;
    for (final refresh in [false, true]) {
      final configuration = await _currentRouting(force: refresh);
      for (final format in formats) {
        try {
          final imageURL = configuration.url(hash: page.hash, format: format, thumbnail: thumbnail);
          final result = await transport.get(imageURL, limit: thumbnail ? 2000000 : 24000000, galleryID: galleryID);
          if (MangaUrls.home != site) throw const CancellationError();
          final valid = result.response.statusCode == 200 && result.response.mimeType == 'image/$format' && result.data.length > 32;
          if (!valid) throw ContentError.unsupportedFormat;
          return result.data;
        } catch (error) {
          if (error is CancellationError) rethrow;
          lastError = error;
          if (ContentTransport.backendConnectionFailed(error) && !refresh) {
            // A cached CDN may move independently of its data server.
            await MangaUrls.resolveBackend(transport: transport, force: true);
            break;
          }
          // Only stale routing / missing representation merits a format or routing retry.
          if (!(error is ContentError && (error.isUnavailable(403) || error.isUnavailable(404)))) rethrow;
        }
      }
    }
    throw lastError;
  }

  Future<CDNRouting> _currentRouting({required bool force}) async {
    final routing = _routing;
    if (!force && routing != null && DateTime.now().difference(routing.$2) < const Duration(seconds: 300)) return routing.$1;
    final running = _routingTask;
    if (running != null) return running;
    final task = () async {
      final result = await transport.getData('gg.js', limit: 100000);
      final String text;
      try {
        text = utf8.decode(result.data);
      } on FormatException {
        throw ContentError.invalidResponse;
      }
      return CDNRouting(text);
    }();
    _routingTask = task;
    try {
      final value = await task;
      _routing = (value, DateTime.now());
      return value;
    } finally {
      if (_routingTask == task) _routingTask = null;
    }
  }

  Future<List<int>> _search(GalleryQuery query) async {
    final tokens = splitWhitespace(query.text.toLowerCase());
    if (tokens.length > GalleryQuery.maximumSearchTerms) throw const ContentError.tooManySearchTerms(GalleryQuery.maximumSearchTerms);
    if (!(tokens.isNotEmpty || query.artist != null || query.language != 'all') || !tokens.every((token) => token.length <= 120 && !token.contains('"'))) {
      throw ContentError.invalidQuery;
    }
    final versionData = await transport.getData('galleriesindex/version', limit: 64);
    final version = utf8.decode(versionData.data, allowMalformed: true).trim();
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(version)) throw ContentError.unsupportedFormat;
    Set<int>? included;
    final excluded = <int>{};
    for (final token in tokens) {
      final isExcluded = token.startsWith('-');
      final term = (isExcluded ? token.substring(1) : token).replaceAll('_', ' ');
      if (term.isEmpty) throw ContentError.invalidQuery;
      final List<int> ids;
      final colon = term.indexOf(':');
      if (colon >= 0) {
        final field = term.substring(0, colon), value = term.substring(colon + 1);
        if (!['artist', 'group', 'series', 'character', 'tag', 'type', 'female', 'male', 'language'].contains(field) || value.isEmpty) {
          throw ContentError.invalidQuery;
        }
        final String path;
        if (field == 'language') {
          path = 'index-${_segment(value)}.nozomi';
        } else if (field == 'female' || field == 'male') {
          path = 'tag/${_segment(term)}-all.nozomi';
        } else {
          path = '$field/${_segment(value)}-all.nozomi';
        }
        ids = await _fullList(path);
      } else {
        ids = await _keyword(term, version);
      }
      final matches = ids.toSet();
      if (isExcluded) {
        excluded.addAll(matches);
      } else {
        included = included?.intersection(matches) ?? matches;
      }
    }
    final artist = query.artist;
    if (artist != null) {
      final matches = (await _fullList('artist/${_segment(artist)}-all.nozomi')).toSet();
      included = included?.intersection(matches) ?? matches;
    }
    if (query.language != 'all' || included == null) {
      final matches = (await _fullList('index-${query.language}.nozomi')).toSet();
      if (query.language != 'all' && query.allowsLanguageExceptions) {
        for (final type in _visualTypes) {
          matches.addAll(await _fullList('type/$type-all.nozomi'));
        }
      }
      included = included?.intersection(matches) ?? matches;
    }
    return (included.difference(excluded).toList()..sort((a, b) => b.compareTo(a)));
  }

  Future<List<int>> _indexPrefix(String path, int count, {bool optional = false}) async {
    final site = MangaUrls.home;
    var prefix = _indexPrefixes[path] ?? _IndexPrefix();
    if (DateTime.now().difference(prefix.created) > const Duration(seconds: 300)) prefix = _IndexPrefix();
    if (!prefix.more || prefix.ids.length >= count) return prefix.ids;
    final range = (prefix.ids.length * 4, count * 4);
    try {
      final result = await transport.getData(path, limit: range.$2 - range.$1, range: range);
      if (result.response.statusCode == 416) {
        prefix.more = false;
      } else {
        final total = validateRange(result.response, start: range.$1, received: result.data.length);
        prefix.ids.addAll(BinaryCursor.ids(result.data));
        prefix.more = prefix.ids.length * 4 < total;
      }
    } on ContentError catch (error) {
      if (!(optional && error.isUnavailable(404))) rethrow;
      prefix.more = false;
    }
    if (MangaUrls.home != site) throw const CancellationError();
    _storeIndex(prefix, path);
    return prefix.ids;
  }

  void _storeIndex(_IndexPrefix prefix, String path) {
    _indexPrefixes[path] = prefix;
    while (_indexPrefixes.length > 16 || _indexPrefixes.values.fold(0, (sum, value) => sum + value.ids.length) > 2000000) {
      final others = _indexPrefixes.entries.where((entry) => entry.key != path).toList();
      if (others.isEmpty) break;
      _indexPrefixes.remove(others.reduce((a, b) => a.value.created.isBefore(b.value.created) ? a : b).key);
    }
  }

  Future<List<int>> _fullList(String path) async {
    final site = MangaUrls.home;
    final prefix = _indexPrefixes[path];
    if (prefix != null && !prefix.more && DateTime.now().difference(prefix.created) < const Duration(seconds: 300)) return prefix.ids;
    try {
      final result = await transport.getData(path, limit: 8000000);
      if (MangaUrls.home != site) throw const CancellationError();
      if (result.response.statusCode != 200) throw ContentError.invalidResponse;
      final ids = BinaryCursor.ids(result.data);
      _storeIndex(_IndexPrefix(ids: ids, more: false), path);
      return ids;
    } on ContentError catch (error) {
      if (error.isUnavailable(404)) return [];
      rethrow;
    }
  }

  Future<List<int>> _keyword(String term, String version) async {
    final key = sha256.convert(utf8.encode(term)).bytes.sublist(0, 4);
    var address = 0;
    final visited = <int>{};
    for (var step = 0; step < 32; step++) {
      if (!visited.add(address) || address > (1 << 62) - 464) throw ContentError.invalidResponse;
      final node = SearchIndexNode(await _readRange('galleriesindex/galleries.$version.index', (address, address + 464)));
      if (node.keys.isEmpty) return [];
      var position = 0;
      while (position < node.keys.length && _precedes(node.keys[position], key)) {
        position += 1;
      }
      if (position < node.keys.length && _equal(node.keys[position], key)) {
        final location = node.locations[position];
        if (location.$2 < 4 || location.$2 > 8000000 || location.$1 > (1 << 62) - location.$2) throw ContentError.tooLarge;
        final data = await _readRange('galleriesindex/galleries.$version.data', (location.$1, location.$1 + location.$2));
        final reader = BinaryCursor(data);
        final count = reader.u32();
        if (count > 2000000 || data.length != 4 + count * 4) throw ContentError.invalidResponse;
        return BinaryCursor.ids(Uint8List.sublistView(data, 4));
      }
      if (position >= node.children.length) throw ContentError.invalidResponse;
      address = node.children[position];
      if (address == 0) return [];
    }
    throw ContentError.invalidResponse;
  }

  static bool _precedes(List<int> a, List<int> b) {
    for (var index = 0; index < a.length && index < b.length; index++) {
      if (a[index] != b[index]) return a[index] < b[index];
    }
    return a.length < b.length;
  }

  static bool _equal(List<int> a, List<int> b) => a.length == b.length && !_precedes(a, b) && !_precedes(b, a);

  Future<Uint8List> _readRange(String path, (int, int) range) async {
    final result = await transport.getData(path, limit: range.$2 - range.$1, range: range);
    validateRange(result.response, start: range.$1, received: result.data.length);
    if (result.data.length != range.$2 - range.$1) throw ContentError.invalidResponse;
    return result.data;
  }

  static int validateRange(ContentResponse response, {required int start, required int received}) {
    final header = response.header('content-range');
    if (response.statusCode != 206 || received <= 0 || header == null || !RegExp(r'^bytes [0-9]+-[0-9]+/[0-9]+$').hasMatch(header)) {
      throw ContentError.invalidResponse;
    }
    final parts = header.substring(6).split(RegExp('[-/]')).map(int.tryParse).nonNulls.toList();
    if (parts.length != 3 || parts[0] != start || parts[1] < start || parts[1] >= parts[2] || parts[1] - start + 1 != received) {
      throw ContentError.invalidResponse;
    }
    return parts[2];
  }

  static String _segment(String value) => ContentURL.alphanumerics(value, extra: '-_');
}

class BinaryCursor {
  BinaryCursor(this.data);
  final Uint8List data;
  int offset = 0;

  Uint8List bytes(int count) {
    if (count < 0 || offset > data.length || count > data.length - offset) throw ContentError.invalidResponse;
    final result = Uint8List.sublistView(data, offset, offset + count);
    offset += count;
    return result;
  }

  int u32() => bytes(4).fold(0, (value, byte) => (value << 8) | byte);

  int u64() {
    final value = bytes(8);
    // A value past the signed range would not fit an address.
    if (value[0] >= 0x80) throw ContentError.invalidResponse;
    return value.fold(0, (result, byte) => (result << 8) | byte);
  }

  static List<int> ids(Uint8List data) {
    if (data.length % 4 != 0) throw ContentError.invalidResponse;
    final view = ByteData.sublistView(data);
    final result = List<int>.filled(data.length ~/ 4, 0);
    for (var index = 0; index < result.length; index++) {
      final value = view.getUint32(index * 4);
      if (value == 0) throw ContentError.invalidResponse;
      result[index] = value;
    }
    return result;
  }
}

class SearchIndexNode {
  SearchIndexNode._(this.keys, this.locations, this.children);

  final List<Uint8List> keys;
  final List<(int, int)> locations;
  final List<int> children;

  factory SearchIndexNode(Uint8List data) {
    final reader = BinaryCursor(data);
    final count = reader.u32();
    if (count > 16) throw ContentError.invalidResponse;
    final keys = [
      for (var index = 0; index < count; index++)
        () {
          final length = reader.u32();
          if (length != 4) throw ContentError.unsupportedFormat;
          return reader.bytes(length);
        }(),
    ];
    if (reader.u32() != count) throw ContentError.invalidResponse;
    final locations = [for (var index = 0; index < count; index++) (reader.u64(), reader.u32())];
    final children = [for (var index = 0; index < 17; index++) reader.u64()];
    return SearchIndexNode._(keys, locations, children);
  }
}
