import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../support/swift_json.dart';
import 'content_errors.dart';
import 'content_transport.dart';
import 'content_url.dart';
import 'document_catalog_source.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';
import 'site_account.dart';

class KeyedLink {
  const KeyedLink(this.id, this.key);
  final int id;
  final String key;
  @override
  bool operator ==(Object other) => other is KeyedLink && other.id == id && other.key == key;
  @override
  int get hashCode => Object.hash(id, key);
  @override
  String toString() => 'KeyedLink($id, $key)';
}

/// A rectangle of whole pixels, as preview sheets describe their tiles.
class CropRect {
  const CropRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;
  @override
  bool operator ==(Object other) => other is CropRect && other.x == x && other.y == y && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(x, y, width, height);
  @override
  String toString() => 'CropRect($x, $y, $width, $height)';
}

/// A page preview: its own image, or one tile of a sheet of previews.
class KeyedThumb {
  const KeyedThumb(this.url, this.crop);
  final Uri url;
  final CropRect? crop;
  @override
  bool operator ==(Object other) => other is KeyedThumb && other.url == url && other.crop == crop;
  @override
  int get hashCode => Object.hash(url, crop);
}

class KeyedEntry {
  const KeyedEntry({required this.key, required this.name, this.thumb});
  final String key;
  final String name;
  final KeyedThumb? thumb;
}

class ShownImage {
  const ShownImage(this.url, this.reload);
  final Uri url;
  final String? reload;
}

class _Detail {
  _Detail({required this.perPage, required this.entries});
  int perPage;
  final Map<int, KeyedEntry> entries;
  final created = DateTime.now();
}

class _Lane {
  _Lane({required this.categories, this.language});
  final Set<String> categories;
  final String? language;
  String? next;
  bool more = true;
  final pending = <int>[];
}

class _Feed {
  _Feed(this.lanes);
  final List<_Lane> lanes;
  final ids = <int>[];
  final created = DateTime.now();
}

/// Cuts one tile out of a sheet of previews. Replaceable in tests without an engine.
typedef PreviewCropper = Future<Uint8List> Function(List<int> sheet, CropRect crop);

/// A numeric catalog whose works open with their number plus a short key: an
/// HTML listing with a cursor, page links per work, and a JSON endpoint for
/// details. Only page shapes and response fields identify this protocol.
class KeyedCatalogSource {
  KeyedCatalogSource(this.transport, {this.keysOverride, PreviewCropper? cropper}) : cropper = cropper ?? KeyedCatalogSource.cropped;

  final ContentTransport transport;

  /// Tests pass their own keys; the app uses the shared ones.
  final GalleryKeys? keysOverride;
  final PreviewCropper cropper;
  GalleryKeys get keys => keysOverride ?? GalleryKeys.shared;
  String _site = '';
  final _feeds = <GalleryQuery, _Feed>{};
  final _details = <int, _Detail>{};
  (List<int>, DateTime)? _popular;
  final _previews = BoundedCache<String, NativeGallery>(512);
  final _sheets = BoundedCache<String, Uint8List>(24);

  static const allCategories = {'doujinshi', 'manga', 'artistcg', 'gamecg', 'western', 'non-h', 'imageset', 'cosplay', 'photo', 'misc'};
  static const _visualCategories = {'artistcg', 'gamecg', 'imageset'};
  static const _categoryBits = {
    'misc': 1,
    'doujinshi': 2,
    'manga': 4,
    'artistcg': 8,
    'gamecg': 16,
    'imageset': 32,
    'cosplay': 64,
    'photo': 128,
    'non-h': 256,
    'western': 512,
  };
  static const _searchLimit = 200;

  NativeGallery? cachedPreview(int id) => _previews['${MangaUrls.home}#$id'];

  void _prepare(String requestedSite) {
    if (requestedSite != MangaUrls.home) throw const CancellationError();
    if (_site != requestedSite) {
      _site = requestedSite;
      _feeds.clear();
      _details.clear();
      _popular = null;
      _previews.clear();
      _sheets.clear();
    }
  }

  // MARK: Listing

  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count, required String site}) async {
    _prepare(site);
    final selected = selectedCategories(query);
    if (query.sort != GallerySort.latest) return _popularList(query, selected: selected, offset: offset, count: count, site: site);
    var feed = _feeds[query] ?? _Feed(_lanes(query, selected));
    if (DateTime.now().difference(feed.created) > const Duration(seconds: 300)) feed = _Feed(_lanes(query, selected));
    final exclusions = DocumentCatalogSource.exclusions(query);
    final target = offset + count;
    final seen = feed.ids.toSet();
    var requests = 0;
    while (feed.ids.length < target) {
      for (final lane in feed.lanes) {
        if (lane.pending.isNotEmpty || !lane.more) continue;
        if (requests >= 8) break;
        await _fill(lane, query, exclusions: exclusions, site: site);
        requests += 1;
      }
      // Every lane needs a head or must be exhausted before the newest one is taken.
      if (feed.lanes.any((lane) => lane.pending.isEmpty && lane.more)) {
        if (requests >= 8) break;
        continue;
      }
      final available = feed.lanes.where((lane) => lane.pending.isNotEmpty).toList();
      if (available.isEmpty) break;
      var newest = available.first;
      for (final lane in available.skip(1)) {
        if (newest.pending.first < lane.pending.first) newest = lane;
      }
      final next = newest.pending.removeAt(0);
      if (seen.add(next)) feed.ids.add(next);
    }
    _prepare(site);
    final more = feed.lanes.any((lane) => lane.more || lane.pending.isNotEmpty);
    // Heavy exclusions show what was found rather than an error.
    if (feed.ids.length <= offset && more && requests >= 8) throw ContentError.invalidResponse;
    if (_feeds.length >= 16 && !_feeds.containsKey(query)) {
      _feeds.remove(_feeds.entries.reduce((a, b) => a.value.created.isBefore(b.value.created) ? a : b).key);
    }
    _feeds[query] = feed;
    return GalleryBatch(ids: feed.ids.skip(offset).take(count).toList(), hasMore: more || feed.ids.length > target);
  }

  /// A language with visual collections in every language reads two lanes, merged newest first.
  static List<_Lane> _lanes(GalleryQuery query, Set<String> selected) {
    final language = query.language == 'all' ? null : query.language;
    if (language == null || !query.allowsLanguageExceptions) return [_Lane(categories: selected, language: language)];
    return [
      _Lane(categories: selected.difference(_visualCategories), language: language),
      _Lane(categories: selected.intersection(_visualCategories)),
    ].where((lane) => lane.categories.isNotEmpty).toList();
  }

  Future<void> _fill(_Lane lane, GalleryQuery query, {required String exclusions, required String site}) async {
    final url = searchURL(query, site: site, categories: lane.categories, language: lane.language, next: lane.next);
    final text = await _page(url, site);
    final found = links(text);
    keys.rememberAll([for (final link in found) (link.id, link.key)]);
    final next = nextCursor(text);
    lane.more = found.isNotEmpty && next != null && next != lane.next;
    lane.next = next;
    final previews = await _previewsFor(found, site);
    for (final link in found) {
      final preview = previews[link.id];
      if (preview != null) {
        if (preview.type.isNotEmpty && !lane.categories.contains(preview.type)) continue;
        if (exclusions.isNotEmpty && preview.isExcluded(exclusions)) continue;
      }
      lane.pending.add(link.id);
    }
  }

  /// The site ranks only what is popular right now, so the search narrows it here.
  Future<GalleryBatch> _popularList(GalleryQuery query, {required Set<String> selected, required int offset, required int count, required String site}) async {
    final List<int> ids;
    final popular = _popular;
    if (popular != null && DateTime.now().difference(popular.$2) < const Duration(seconds: 300)) {
      ids = popular.$1;
    } else {
      final url = ContentURL.parse('${site}popular');
      if (url == null) throw ContentError.invalidQuery;
      final found = links(await _page(url, site));
      keys.rememberAll([for (final link in found) (link.id, link.key)]);
      await _previewsFor(found, site);
      ids = [for (final link in found) link.id];
      _popular = (ids, DateTime.now());
    }
    final terms = splitWhitespace(query.text).where((term) => !term.startsWith('type:') && !term.startsWith('-type:')).toList();
    final artist = query.artist;
    final wanted = [...terms.where((term) => !term.startsWith('-')), if (artist != null) 'artist:${artist.replaceAll(' ', '_')}'];
    final excluded = terms.where((term) => term.startsWith('-')).join(' ');
    final matches = ids.where((id) {
      final work = cachedPreview(id);
      if (work == null) return true;
      if (work.type.isNotEmpty && !selected.contains(work.type)) return false;
      final visual = query.allowsLanguageExceptions && _visualCategories.contains(work.type);
      if (query.language != 'all' && work.language != query.language && !visual) return false;
      if (excluded.isNotEmpty && work.isExcluded(excluded)) return false;
      return wanted.every(work.isExcluded);
    }).toList();
    return GalleryBatch(ids: matches.skip(offset).take(count).toList(), hasMore: matches.length > offset + count);
  }

  Future<String> _page(Uri url, String site) async {
    final ContentResult result;
    try {
      result = await transport.get(url, limit: 3000000);
    } on ContentError catch (error) {
      final status = error.value ?? 0;
      if (error.kind == ContentErrorKind.unavailable && status >= 300 && status < 400) throw ContentError.signInRequired;
      rethrow;
    }
    _prepare(site);
    final text = utf8.decode(result.data, allowMalformed: true);
    if (asksForSignIn(text) || text.trim().characters.length < 64) throw ContentError.signInRequired;
    return text;
  }

  // MARK: Works

  Future<NativeGallery> gallery(int id, {required String site}) async {
    _prepare(site);
    if (id <= 0) throw ContentError.invalidQuery;
    final key = await keyFor(id, site: site);
    final items = await _metadata([KeyedLink(id, key)], site);
    final item = items.where((item) => _number(item['gid']) == id).firstOrNull;
    final parsed = item == null || item['error'] != null ? null : work(item, site: site);
    if (parsed == null) throw ContentError.galleryNotFound;
    final (preview, fileCount) = parsed;
    _previews['$site#$id'] = preview;
    final detail = await _detailPage(id, key: key, page: 0, site: site);
    final cover = preview.pages.firstOrNull?.thumbnailURL;
    final pages = [
      for (var index = 0; index < fileCount; index++)
        GalleryPage(
          hash: _pageHash(site, id, index),
          name: detail.entries[index]?.name ?? '${index + 1}',
          width: detail.entries[index]?.thumb?.crop?.width ?? 0,
          height: detail.entries[index]?.thumb?.crop?.height ?? 0,
          hasAVIF: false,
          thumbnailURL: index == 0 ? cover : (detail.entries[index]?.thumb == null ? null : encoded(detail.entries[index]!.thumb!)),
          index: index,
          sourceSite: site,
        ),
    ];
    return NativeGallery(
      id: id,
      title: preview.title,
      artists: preview.artists,
      language: preview.language,
      type: preview.type,
      tags: preview.tags,
      pages: pages,
    );
  }

  /// The key comes from a link already seen, or from searching the number.
  Future<String> keyFor(int id, {required String site}) async {
    final known = keys.key(id);
    if (known != null) return known;
    final url = ContentURL.withQueryItems(site, [('f_search', 'gid:$id')]);
    final found = links(await _page(url, site));
    keys.rememberAll([for (final link in found) (link.id, link.key)]);
    final link = found.where((link) => link.id == id).firstOrNull;
    if (link == null) throw ContentError.galleryNotFound;
    return link.key;
  }

  Future<_Detail> _detailPage(int id, {required String key, required int page, required String site}) async {
    final cached = _details[id];
    if (cached != null && DateTime.now().difference(cached.created) < const Duration(seconds: 1800)) {
      if (page == 0 || cached.entries.containsKey(page * cached.perPage)) return cached;
      final url = ContentURL.parse('${site}g/$id/$key/?p=$page');
      if (url == null) throw ContentError.invalidQuery;
      cached.entries.addAll(entries(await _page(url, site), id));
      return cached;
    }
    final url = ContentURL.parse('${site}g/$id/$key/${page > 0 ? '?p=$page' : ''}');
    if (url == null) throw ContentError.invalidQuery;
    final found = entries(await _page(url, site), id);
    if (found.isEmpty) throw ContentError.galleryNotFound;
    final perPage = page == 0 ? found.length : (_details[id]?.perPage ?? found.length);
    if (_details.length >= 64) _details.remove(_details.entries.reduce((a, b) => a.value.created.isBefore(b.value.created) ? a : b).key);
    final detail = _Detail(perPage: perPage < 1 ? 1 : perPage, entries: found);
    _details[id] = detail;
    return detail;
  }

  Future<KeyedEntry> _entry(int id, {required int index, required String site, required bool refresh}) async {
    if (refresh) _details.remove(id);
    final key = await keyFor(id, site: site);
    var detail = await _detailPage(id, key: key, page: 0, site: site);
    final known = detail.entries[index];
    if (known != null) return known;
    detail = await _detailPage(id, key: key, page: index ~/ detail.perPage, site: site);
    final entry = detail.entries[index];
    if (entry == null) throw ContentError.invalidResponse;
    return entry;
  }

  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail, required String site}) async {
    _prepare(site);
    final index = page.index ?? 0;
    if (thumbnail) {
      final url = page.thumbnailURL;
      if (url != null && thumbFrom(url)?.crop == null) return _fetch(url, galleryID: galleryID, limit: 2000000, site: site);
      for (var attempt = 0; attempt < 2; attempt++) {
        final entry = await _entry(galleryID, index: index, site: site, refresh: attempt > 0);
        final thumb = entry.thumb;
        if (thumb == null) throw ContentError.invalidResponse;
        try {
          return await _preview(thumb, galleryID: galleryID, site: site);
        } on ContentError catch (error) {
          if (attempt == 0 && (error.isUnavailable(403) || error.isUnavailable(404) || error.isUnavailable(410))) continue;
          rethrow;
        }
      }
      throw ContentError.invalidResponse;
    }
    // A cover from a search row is all a preview carries; the reader asks for real pages.
    final entry = await _entry(galleryID, index: index, site: site, refresh: false);
    String? reload;
    for (var attempt = 0; attempt < 3; attempt++) {
      final base = '${site}s/${entry.key}/$galleryID-${index + 1}';
      final url = reload == null ? ContentURL.parse(base) : ContentURL.withQueryItems(base, [('nl', reload)]);
      final shown = url == null ? null : shownImage(await _page(url, site));
      if (shown == null) throw ContentError.unsupportedFormat;
      if (isLimitNotice(shown.url)) throw ContentError.imageLimit;
      try {
        return await _fetch(shown.url, galleryID: galleryID, limit: 24000000, site: site);
      } catch (error) {
        // Another volunteer host serves the same image when this one fails.
        final next = shown.reload;
        if (attempt >= 2 || next == null || next == reload) rethrow;
        reload = next;
      }
    }
    throw ContentError.invalidResponse;
  }

  Future<Uint8List> _fetch(Uri url, {required int galleryID, required int limit, required String site}) async {
    if (!safeMediaURL(url)) throw ContentError.unsupportedFormat;
    MangaUrls.registerMedia([url], site: site);
    final result = await transport.get(url, limit: limit, galleryID: galleryID);
    _prepare(site);
    if (!(result.response.mimeType?.startsWith('image/') ?? true) || result.data.length <= 32) throw ContentError.unsupportedFormat;
    return result.data;
  }

  Future<Uint8List> _preview(KeyedThumb thumb, {required int galleryID, required String site}) async {
    final crop = thumb.crop;
    if (crop == null) return _fetch(thumb.url, galleryID: galleryID, limit: 2000000, site: site);
    var sheet = _sheets[thumb.url.toString()];
    if (sheet == null) {
      sheet = await _fetch(thumb.url, galleryID: galleryID, limit: 6000000, site: site);
      _sheets[thumb.url.toString()] = sheet;
    }
    return cropper(sheet, crop);
  }

  /// Cuts one page preview out of a sheet of previews, as a PNG.
  static Future<Uint8List> cropped(List<int> data, CropRect crop) async {
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(Uint8List.fromList(data));
    } on Object {
      throw ContentError.unsupportedFormat;
    }
    final image = (await codec.getNextFrame()).image;
    final left = crop.x.clamp(0, image.width), top = crop.y.clamp(0, image.height);
    final right = (crop.x + crop.width).clamp(0, image.width), bottom = (crop.y + crop.height).clamp(0, image.height);
    if (right - left < 1 || bottom - top < 1) throw ContentError.unsupportedFormat;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()),
      ui.Rect.fromLTWH(0, 0, (right - left).toDouble(), (bottom - top).toDouble()),
      ui.Paint(),
    );
    final tile = await recorder.endRecording().toImage(right - left, bottom - top);
    final bytes = await tile.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw ContentError.unsupportedFormat;
    return bytes.buffer.asUint8List();
  }

  // MARK: Details endpoint

  /// Search rows only carry links, so their details come from the JSON endpoint in batches.
  Future<Map<int, NativeGallery>> _previewsFor(List<KeyedLink> links, String site) async {
    final found = <int, NativeGallery>{};
    final missing = <KeyedLink>[];
    for (final link in links) {
      final cached = cachedPreview(link.id);
      if (cached != null) {
        found[link.id] = cached;
      } else {
        missing.add(link);
      }
    }
    for (var start = 0; start < missing.length; start += 25) {
      List<Map<String, Object?>> items;
      try {
        items = await _metadata(missing.sublist(start, start + 25 > missing.length ? missing.length : start + 25), site);
      } on Object {
        continue;
      }
      for (final item in items) {
        final id = _number(item['gid']);
        final parsed = id == null || item['error'] != null ? null : work(item, site: site);
        if (parsed == null) continue;
        _previews['$site#$id'] = parsed.$1;
        found[id!] = parsed.$1;
      }
    }
    return found;
  }

  Future<List<Map<String, Object?>>> _metadata(List<KeyedLink> links, String site) async {
    final object = await _api({
      'method': 'gdata',
      'gidlist': [
        for (final link in links) [link.id, link.key],
      ],
      'namespace': 1,
    }, site);
    final items = object['gmetadata'];
    if (items is! List || items.length > 25 || items.any((item) => item is! Map)) throw ContentError.invalidResponse;
    final result = [for (final item in items) (item as Map).cast<String, Object?>()];
    for (final item in result) {
      final thumb = item['thumb'] is String ? ContentURL.parse(item['thumb'] as String) : null;
      if (thumb != null) MangaUrls.registerMedia([thumb], site: site);
    }
    return result;
  }

  Future<Map<String, Object?>> _api(Map<String, Object?> body, String site) async {
    final url = MangaUrls.keyedAPI;
    if (url == null) throw ContentError.invalidResponse;
    final result = await transport.post(url, body: utf8.encode(jsonEncode(body)), contentType: 'application/json', limit: 2000000);
    _prepare(site);
    final Object? object;
    try {
      object = jsonDecode(utf8.decode(result.data));
    } on FormatException {
      throw ContentError.invalidResponse;
    }
    if (object is! Map<String, Object?>) throw ContentError.invalidResponse;
    return object;
  }

  Future<List<TagSuggestion>> suggestions(String token, {required String site}) async {
    _prepare(site);
    final context = TagCompletionContext.parse(token);
    if (context == null) return [];
    final parts = swiftSplit(context.token, (character) => character == ':', maxSplits: 1);
    final namespace = parts.length == 2 ? parts[0] : null;
    final term = parts.last.replaceAll('_', ' ');
    final remote = namespace == null ? term : '${_remoteNamespace(namespace)}:$term';
    final object = await _api({'method': 'tagsuggest', 'text': remote}, site);
    final tags = object['tags'];
    final rows = tags is Map ? tags.entries.toList() : <MapEntry>[];
    rows.sort((a, b) => (int.tryParse('${a.key}') ?? 1 << 62).compareTo(int.tryParse('${b.key}') ?? 1 << 62));
    final seen = <String>{};
    final result = <TagSuggestion>[];
    for (final entry in rows) {
      final row = entry.value;
      if (row is! Map) continue;
      // A spelling the site folds into another tag suggests that tag instead.
      final space = row['mns'] ?? row['ns'], name = row['mtn'] ?? row['tn'];
      if (space is! String || name is! String || name.isEmpty || name.characters.length > 120) continue;
      final local = _localNamespace(space);
      if (!TagSuggestion.namespaces.contains(local) || (namespace != null && namespace != local)) continue;
      final item = TagSuggestion(namespace: local, name: name);
      if (seen.add(item.id)) result.add(item);
    }
    return result.take(20).toList();
  }

  // MARK: Account favorites

  /// One page of the signed-in account's favorites, newest first.
  Future<(List<int>, String?)> favorites({String? after, required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final url = ContentURL.withQueryItems('${site}favorites.php', after == null ? null : [('next', after)]);
    final text = await _page(url, site);
    final found = links(text);
    keys.rememberAll([for (final link in found) (link.id, link.key)]);
    await _previewsFor(found, site);
    final cursor = nextCursor(text);
    return ([for (final link in found) link.id], found.isEmpty || cursor == after ? null : cursor);
  }

  Future<void> setFavorite(int id, {required bool saved, required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final key = await keyFor(id, site: site);
    final url = ContentURL.withQueryItems('${site}gallerypopups.php', [('gid', '$id'), ('t', key), ('act', 'addfav')]);
    final form = saved ? 'favcat=0&favnote=&apply=Add+to+Favorites&update=1' : 'favcat=favdel&favnote=&update=1';
    final result = await transport.post(url, body: utf8.encode(form), contentType: 'application/x-www-form-urlencoded', limit: 1000000);
    _prepare(site);
    if (asksForSignIn(utf8.decode(result.data, allowMalformed: true))) throw ContentError.signInRequired;
  }

  // MARK: Page shapes

  static final _linkPattern = RegExp(r'/g/([0-9]{1,10})/([0-9a-f]{10})(?![0-9a-f])');

  /// Work links in page order, each once.
  static List<KeyedLink> links(String text) {
    final seen = <int>{};
    return [
      for (final match in _linkPattern.allMatches(text))
        if (int.tryParse(match[1]!) case final id? when id > 0 && seen.add(id)) KeyedLink(id, match[2]!),
    ];
  }

  static String? nextCursor(String text) {
    final tag = RegExp(r'<a\b[^>]*\bid="unext"[^>]*>').firstMatch(text);
    final href = tag == null ? null : _attribute('href', tag[0]!);
    final url = href == null ? null : Uri.tryParse(_decode(href));
    final value = url == null ? null : ContentURL.queryValue(url, 'next');
    if (value == null || !RegExp(r'^[0-9A-Za-z_-]{1,40}$').hasMatch(value)) return null;
    return value;
  }

  static final _entryPattern = RegExp(r'<a\b[^>]*\bhref="[^"]*/s/([0-9a-f]{10})/([0-9]{1,10})-([0-9]{1,5})"[^>]*>(.*?)</a>', dotAll: true);

  /// Page links on a work's page, by zero-based page index, with each page's preview.
  static Map<int, KeyedEntry> entries(String text, int galleryID) {
    final result = <int, KeyedEntry>{};
    for (final match in _entryPattern.allMatches(text)) {
      final number = int.tryParse(match[3]!);
      if (int.tryParse(match[2]!) != galleryID || number == null || number < 1) continue;
      final body = match[4]!;
      var name = '$number';
      final title = _attribute('title', body);
      final colon = title?.indexOf(': ') ?? -1;
      if (title != null && colon >= 0) name = _decode(title.substring(colon + 2));
      result[number - 1] = KeyedEntry(key: match[1]!, name: name, thumb: _thumb(body));
    }
    return result;
  }

  static KeyedThumb? _thumb(String body) {
    final style = _attribute('style', body);
    final size = style == null ? null : RegExp(r'width:\s*([0-9]+)px;\s*height:\s*([0-9]+)px').firstMatch(style);
    final sheet = style == null ? null : RegExp(r'url\(([^)]+)\)\s*(-?[0-9]+)px').firstMatch(style);
    if (size != null && sheet != null) {
      final numbers = size[0]!.split(RegExp(r'[^0-9]+')).where((part) => part.isNotEmpty).map(int.parse).toList();
      final declaration = sheet[0]!;
      final open = declaration.indexOf('('), close = declaration.indexOf(')');
      if (numbers.length != 2 || open < 0 || close < 0) return null;
      final address = _decode(declaration.substring(open + 1, close).replaceAll(RegExp('''^['" ]+|['" ]+\$'''), ''));
      final url = ContentURL.parse(address);
      final trailing = declaration.substring(close + 1).trim();
      final offset = int.tryParse(trailing.length >= 2 ? trailing.substring(0, trailing.length - 2) : '');
      if (url == null || offset == null || !safeMediaURL(url)) return null;
      return KeyedThumb(url, CropRect(-offset, 0, numbers[0], numbers[1]));
    }
    final image = RegExp(r'<img\b[^>]*>').firstMatch(body);
    final value = image == null ? null : _attribute('src', image[0]!);
    final url = value == null ? null : ContentURL.parse(_decode(value));
    if (url != null && safeMediaURL(url)) return KeyedThumb(url, null);
    return null;
  }

  /// A tile of a preview sheet travels as the sheet's address plus its rectangle.
  static Uri encoded(KeyedThumb thumb) {
    final crop = thumb.crop;
    if (crop == null) return thumb.url;
    return thumb.url.replace(fragment: 'crop=${crop.x},${crop.y},${crop.width},${crop.height}');
  }

  static KeyedThumb? thumbFrom(Uri url) {
    if (!url.hasFragment || !url.fragment.startsWith('crop=')) return KeyedThumb(url, null);
    final values = url.fragment.substring(5).split(',').map(int.tryParse).nonNulls.toList();
    if (values.length != 4) return null;
    return KeyedThumb(url.removeFragment(), CropRect(values[0], values[1], values[2], values[3]));
  }

  static ShownImage? shownImage(String text) {
    final tag = RegExp(r'<img\b[^>]*\bid="img"[^>]*>').firstMatch(text);
    final value = tag == null ? null : _attribute('src', tag[0]!);
    final url = value == null ? null : ContentURL.parse(_decode(value));
    if (url == null) return null;
    final call = RegExp(r"nl\('([0-9A-Za-z_-]{1,64})'\)").firstMatch(text);
    return ShownImage(url, call?[1]);
  }

  /// When an account's image allowance runs out, the site shows a fixed notice image instead.
  static bool isLimitNotice(Uri url) => (url.pathSegments.lastOrNull ?? '').startsWith('509');

  static bool asksForSignIn(String text) => RegExp(r'<input\b[^>]*\btype="password"', caseSensitive: false).hasMatch(text);

  static String? _attribute(String name, String tag) => RegExp('\\b$name="([^"]*)"').firstMatch(tag)?[1];

  static String _decode(String text) => NativeGallery.decodeEntities(text);

  // MARK: Search and metadata

  static Uri searchURL(GalleryQuery query, {required String site, required Set<String> categories, String? language, String? next}) {
    final tokens = splitWhitespace(query.text).where((term) => !term.startsWith('type:') && !term.startsWith('-type:')).toList();
    if (tokens.length > GalleryQuery.maximumSearchTerms || !tokens.every((token) => token.characters.length <= 120 && !token.contains('"'))) {
      throw ContentError.invalidQuery;
    }
    final terms = tokens.where((token) => !token.startsWith('-')).map(remoteTerm).toList();
    if (language != null) terms.add(remoteTerm('language:$language'));
    final artist = query.artist;
    if (artist != null) terms.add(remoteTerm('artist:${artist.replaceAll(' ', '_')}'));
    // Exclusions go along while the search box has room; the rest are checked on the results.
    for (final exclusion in tokens.where((token) => token.startsWith('-')).map(remoteTerm)) {
      if ([...terms, exclusion].join(' ').characters.length <= _searchLimit) terms.add(exclusion);
    }
    final items = <(String, String?)>[];
    if (terms.isNotEmpty) items.add(('f_search', terms.join(' ')));
    if (categories.length != allCategories.length || !categories.containsAll(allCategories)) {
      final shown = categories.fold(0, (value, category) => value | (_categoryBits[category] ?? 0));
      items.add(('f_cats', '${1023 & ~shown}'));
    }
    if (next != null) items.add(('next', next));
    return ContentURL.withQueryItems(site, items.isEmpty ? null : items);
  }

  /// The app writes tags with underscores; the site matches a whole tag when it is quoted and closed with `$`.
  static String remoteTerm(String term) {
    final excluded = term.startsWith('-');
    final body = excluded ? term.substring(1) : term;
    final parts = swiftSplit(body, (character) => character == ':', maxSplits: 1);
    final prefix = excluded ? '-' : '';
    if (parts.length == 2 && parts[1].isNotEmpty) {
      return '$prefix${_remoteNamespace(parts[0])}:"${parts[1].replaceAll('_', ' ')}\$"';
    }
    final words = body.replaceAll('_', ' ');
    return prefix + (words.contains(' ') ? '"$words"' : words);
  }

  static String _remoteNamespace(String namespace) => switch (namespace) {
    'series' => 'parody',
    'tag' => 'other',
    _ => namespace,
  };

  static String _localNamespace(String namespace) => switch (namespace) {
    'parody' => 'series',
    'other' => 'tag',
    _ => namespace,
  };

  static Set<String> selectedCategories(GalleryQuery query) {
    final terms = splitWhitespace(query.text);
    final selected = terms.any((term) => term.startsWith('type:')) ? <String>{} : {...allCategories};
    for (final term in terms.where((term) => term.startsWith('type:') || term.startsWith('-type:'))) {
      final name = GalleryCategory.key(swiftSplit(term, (character) => character == ':', maxSplits: 1).lastOrNull ?? '');
      if (!allCategories.contains(name)) throw ContentError.invalidQuery;
      if (term.startsWith('-')) {
        selected.remove(name);
      } else {
        selected.add(name);
      }
    }
    return selected;
  }

  /// A details row as a work with its cover as the only page, plus how many pages the work has.
  static (NativeGallery, int)? work(Map<String, Object?> item, {required String site}) {
    final id = _number(item['gid']);
    if (id == null || id <= 0) return null;
    final token = item['token'];
    if (token is String) GalleryKeys.shared.remember(id, token);
    final rawTags = item['tags'];
    final tags = [
      for (final tag in rawTags is List ? rawTags.whereType<String>() : const <String>[])
        if (swiftSplit(tag, (character) => character == ':', maxSplits: 1) case [final namespace, final value]) (namespace, value) else ('other', tag),
    ];
    final languages = [
      for (final (namespace, value) in tags)
        if (namespace == 'language') value,
    ];
    final language = languages.where((value) => !['translated', 'rewrite'].contains(value)).firstOrNull ?? '';
    final category = GalleryCategory.key(item['category'] is String ? item['category'] as String : '');
    final title = DocumentCatalogSource.title(item, id, language: language, translated: languages.contains('translated'));
    var pages = <GalleryPage>[];
    final cover = item['thumb'] is String ? ContentURL.parse(item['thumb'] as String) : null;
    if (cover != null && safeMediaURL(cover)) {
      pages = [
        GalleryPage(
          hash: _pageHash(site, id, -1),
          name: 'cover',
          width: 0,
          height: 0,
          hasAVIF: false,
          imageURL: cover,
          thumbnailURL: cover,
          index: 0,
          sourceSite: site,
        ),
      ];
    }
    final work = NativeGallery(
      id: id,
      title: NativeGallery.decodeEntities(title),
      artists: [
        for (final (namespace, value) in tags)
          if (namespace == 'artist') value,
      ],
      language: language,
      type: category == 'asianporn' ? 'photo' : category,
      tags: [
        for (final (namespace, value) in tags)
          if (namespace != 'language' && namespace != 'artist') '${_localNamespace(namespace)}:$value',
      ],
      pages: pages,
    );
    final files = _number(item['filecount']) ?? 0;
    return (work, files.clamp(0, 10000));
  }

  static int? _number(Object? value) => value is num ? value.toInt() : (value is String ? parseInt64(value) : null);

  static String _pageHash(String site, int id, int index) => sha256.convert(utf8.encode('$site#keyed:$id:$index')).toString();

  /// Volunteer image hosts use their own ports, but never addresses inside the device's network.
  static bool safeMediaURL(Uri url) {
    if (url.scheme != 'https' || !ContentURL.hasNoCredentials(url) || !DocumentCatalogSource.safeHostForKeyed(url.host.toLowerCase())) return false;
    return !url.hasPort || url.port == 443 || (url.port >= 1024 && url.port <= 65535);
  }
}
