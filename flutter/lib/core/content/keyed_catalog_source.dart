import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'content_errors.dart';
import 'content_transport.dart';
import 'content_url.dart';
import 'document_catalog_source.dart';
import 'gallery_content.dart';
import 'keyed_work_extras.dart';
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
  const ShownImage(this.url, this.reload, {this.original});
  final Uri url;
  final String? reload;

  /// The page's original file, which a signed-in account may load instead.
  final Uri? original;
}

class _Detail {
  _Detail({required this.perPage, required this.entries});
  WorkExtras? extras;
  WorkAPIKey? apiKey;
  int perPage;
  final Map<int, KeyedEntry> entries;
  final created = DateTime.now();
}

class _Toplist {
  final ids = <int>[];
  var page = 0;
  var more = true;
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

/// Page loads on one website, paced like a person browsing quickly: a few at once, then one at a
/// steady interval. Bursts of page loads are what get an address banned on keyed catalogs; images
/// and the details endpoint are not paced here.
class PagePacer {
  PagePacer({this.burst = 5, this.interval = const Duration(milliseconds: 800)});

  static final _paced = PagePacer();
  static final _unpaced = PagePacer(burst: 1000, interval: const Duration(milliseconds: 1));

  /// Tests and the offline fixture run aren't paced.
  static PagePacer get shared => ContentPreferences.isIsolated ? _unpaced : _paced;

  final int burst;
  final Duration interval;
  final _buckets = <String, (double, DateTime)>{};

  Future<void> wait(String host) async {
    while (true) {
      final now = DateTime.now();
      final (saved, updated) = _buckets[host] ?? (burst.toDouble(), now);
      final tokens = math.min(burst.toDouble(), saved + now.difference(updated).inMicroseconds / interval.inMicroseconds);
      if (tokens >= 1) {
        _buckets[host] = (tokens - 1, now);
        return;
      }
      _buckets[host] = (tokens, now);
      await Future<void>.delayed(interval * (1 - tokens));
    }
  }
}

class _PreviewBatch {
  _PreviewBatch(this.site);
  final String site;
  final links = <KeyedLink>[];
  late final Future<Map<int, NativeGallery>> result;
}

/// Cuts one tile out of a sheet of previews. Replaceable in tests without an engine.
typedef PreviewCropper = Future<Uint8List> Function(List<int> sheet, CropRect crop);

/// A numeric catalog whose works open with their number plus a short key: an
/// HTML listing with a cursor, page links per work, and a JSON endpoint for
/// details. Only page shapes and response fields identify this protocol.
class KeyedCatalogSource {
  KeyedCatalogSource(this.transport, {this.keysOverride, PreviewCropper? cropper, PagePacer? pacer})
    : cropper = cropper ?? KeyedCatalogSource.cropped,
      pacer = pacer ?? PagePacer.shared;

  final ContentTransport transport;

  /// Tests pass their own keys; the app uses the shared ones.
  final GalleryKeys? keysOverride;
  final PreviewCropper cropper;
  final PagePacer pacer;
  GalleryKeys get keys => keysOverride ?? GalleryKeys.shared;
  String _site = '';
  final _feeds = <GalleryQuery, _Feed>{};
  final _details = <int, _Detail>{};
  (List<int>, DateTime)? _popular;
  final _toplists = <int, _Toplist>{};
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
      _toplists.clear();
      _previews.clear();
      _sheets.clear();
    }
  }

  // MARK: Listing

  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count, required String site}) async {
    _prepare(site);
    final selected = selectedCategories(query);
    final toplist = query.sort.toplist;
    if (toplist != null) return _toplistList(query, selected: selected, toplist: toplist, offset: offset, count: count, site: site);
    if (query.sort != GallerySort.latest && query.sort != GallerySort.watched) {
      return _popularList(query, selected: selected, offset: offset, count: count, site: site);
    }
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
    // Watched tags list the same way as the front page, from their own page.
    final base = query.sort == GallerySort.watched ? '${site}watched' : site;
    final url = searchURL(query, site: base, categories: lane.categories, language: lane.language, next: lane.next);
    final text = await _page(url, site);
    MangaUrls.noteKeyedNavigation(text, site: site);
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
    final matching = ids.where((id) => _matches(id, query, selected)).toList();
    return GalleryBatch(ids: matching.skip(offset).take(count).toList(), hasMore: matching.length > offset + count);
  }

  /// Rankings the site lists itself narrow to the search here, from each work's details.
  bool _matches(int id, GalleryQuery query, Set<String> selected) {
    final terms = splitWhitespace(query.text).where((term) => !term.startsWith('type:') && !term.startsWith('-type:')).toList();
    final artist = query.artist;
    final wanted = [...terms.where((term) => !term.startsWith('-')), if (artist != null) 'artist:${artist.replaceAll(' ', '_')}'];
    final excluded = terms.where((term) => term.startsWith('-')).join(' ');
    final work = cachedPreview(id);
    if (work == null) return true;
    if (work.type.isNotEmpty && !selected.contains(work.type)) return false;
    final visual = query.allowsLanguageExceptions && _visualCategories.contains(work.type);
    if (query.language != 'all' && work.language != query.language && !visual) return false;
    if (excluded.isNotEmpty && work.isExcluded(excluded)) return false;
    return wanted.every(work.isExcluded);
  }

  /// A toplist pages through the site's ranking, a few pages per request at most.
  Future<GalleryBatch> _toplistList(
    GalleryQuery query, {
    required Set<String> selected,
    required int toplist,
    required int offset,
    required int count,
    required String site,
  }) async {
    var list = _toplists[toplist] ?? _Toplist();
    if (DateTime.now().difference(list.created) > const Duration(minutes: 30)) list = _Toplist();
    var requests = 0;
    List<int> found() => list.ids.where((id) => _matches(id, query, selected)).toList();
    while (list.more && requests < 4 && found().length < offset + count) {
      final url = ContentURL.withQueryItems('${site}toplist.php', [('tl', '$toplist'), ('p', '${list.page}')]);
      final linked = links(await _page(url, site));
      keys.rememberAll([for (final link in linked) (link.id, link.key)]);
      await _previewsFor(linked, site);
      final known = list.ids.toSet();
      final added = [
        for (final link in linked)
          if (!known.contains(link.id)) link.id,
      ];
      list.ids.addAll(added);
      list.page += 1;
      list.more = added.isNotEmpty && list.page < 200;
      requests += 1;
    }
    _toplists[toplist] = list;
    final matched = found();
    return GalleryBatch(ids: matched.skip(offset).take(count).toList(), hasMore: matched.length > offset + count || list.more);
  }

  Future<String> _page(Uri url, String site, {bool retried = false}) async {
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (host != null) await pacer.wait(host);
    _prepare(site);
    final access = host == null ? null : SiteAccount.siteCookie(SiteAccount.accessCookie, host: host);
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
    final error = pageError(text);
    if (error != null) {
      if (error != ContentError.signInRequired || host == null) throw error;
      // A members-only catalog shows its wall, or nothing, to a request that came without the
      // access it hands out with that same answer: the next request carries it.
      final handedOut = SiteAccount.siteCookie(SiteAccount.accessCookie, host: host);
      if (!retried && handedOut != null && handedOut != access) return _page(url, site, retried: true);
      // A refused access cookie is dropped, so the next request is handed a fresh one.
      if (isRestrictedNotice(text)) SiteAccount.forgetRefused(SiteAccount.accessCookie, host: host, sent: access);
      if (SiteAccount.refusesAccess(host)) throw ContentError.accessDenied;
      throw error;
    }
    return text;
  }

  /// What a page says instead of the listing or work it was asked for.
  static ContentError? pageError(String text) {
    // These notices are whole pages of their own; a listing that merely names them in a title is not one.
    if (utf8.encode(text).length < 10000) {
      final lowered = text.toLowerCase();
      if (lowered.contains('temporarily banned') || lowered.contains('ban expires in')) return ContentError.temporarilyBlocked;
      if (lowered.contains('exceeded your image viewing limits') || lowered.contains('you have reached the image limit')) return ContentError.imageLimit;
    }
    // A wrong or stale key, or a page that no longer exists, is answered with one short line.
    if (utf8.encode(text).length < 1024) {
      final lowered = text.toLowerCase();
      if (['key missing', 'invalid page', 'keep trying', 'gallery not found'].any(lowered.contains)) return ContentError.galleryNotFound;
    }
    if (isRestrictedNotice(text) || asksForSignIn(text) || text.trim().characters.length < 64) return ContentError.signInRequired;
    return null;
  }

  /// The wall a members-only catalog shows an account whose access cookie it does not accept.
  static bool isRestrictedNotice(String text) {
    if (utf8.encode(text).length >= 10000) return false;
    final lowered = text.toLowerCase();
    return lowered.contains('kokomade.') || (lowered.contains('access to ') && lowered.contains(' is restricted'));
  }

  // MARK: Works

  Future<NativeGallery> gallery(int id, {required String site}) async {
    _prepare(site);
    if (id <= 0) throw ContentError.invalidQuery;
    final (key, item) = await _detailsRow(id, site);
    final parsed = work(item, site: site);
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

  /// A work's details row with the key the site accepted for it. A remembered key the site no
  /// longer accepts, such as one another website handed over, is looked up again once.
  Future<(String, Map<String, Object?>)> _detailsRow(int id, String site) async {
    final remembered = keys.key(id) != null;
    var key = await keyFor(id, site: site);
    Map<String, Object?>? row(List<Map<String, Object?>> items) => items.where((item) => _number(item['gid']) == id).firstOrNull;
    var item = row(await _metadata([KeyedLink(id, key)], site));
    if (remembered && (item == null || item['error'] != null)) {
      keys.forget(id);
      key = await keyFor(id, site: site);
      item = row(await _metadata([KeyedLink(id, key)], site));
    }
    if (item == null || item['error'] != null) throw ContentError.galleryNotFound;
    return (key, item);
  }

  _PreviewBatch? _openBatch;

  /// Websites that wouldn't send original files lately, until when.
  final _originalsRefusedUntil = <String, DateTime>{};

  /// A work as a list card shows it: title, tags, cover and page count from the details endpoint,
  /// never from the work's own page. Cards asking at the same moment share one details request,
  /// so a list that lost its cached details costs a request per 25 works, not a page load per card.
  Future<NativeGallery> preview(int id, {required String site}) async {
    _prepare(site);
    if (id <= 0) throw ContentError.invalidQuery;
    final cached = cachedPreview(id);
    if (cached != null) return cached;
    final remembered = keys.key(id) != null;
    final key = await keyFor(id, site: site);
    final known = cachedPreview(id);
    if (known != null) return known;
    var batch = _openBatch;
    if (batch == null || batch.site != site || batch.links.length >= 25) {
      final created = _PreviewBatch(site);
      _openBatch = created;
      // Cards of one screen ask within moments of each other.
      created.result = Future<void>.delayed(const Duration(milliseconds: 50)).then((_) {
        if (identical(_openBatch, created)) _openBatch = null;
        return _loadPreviews(created.links, site, throwing: true);
      });
      batch = created;
    }
    if (!batch.links.any((link) => link.id == id)) batch.links.add(KeyedLink(id, key));
    final found = await batch.result;
    _prepare(site);
    final listed = found[id];
    if (listed != null) return listed;
    // A key remembered from elsewhere may be one the site doesn't accept.
    if (!remembered) throw ContentError.galleryNotFound;
    final (_, item) = await _detailsRow(id, site);
    final parsed = work(item, site: site);
    if (parsed == null) throw ContentError.galleryNotFound;
    _previews['$site#$id'] = parsed.$1;
    return parsed.$1;
  }

  /// A search for one number. A signed-in account's own filters (hidden languages, uploaders and
  /// tags, and categories left out by default) apply to searches too, so they are switched off
  /// here and every category is asked for: otherwise a work the account filters would never be found.
  static Uri keySearchURL(int id, {required String site}) =>
      ContentURL.withQueryItems(site, [('f_search', 'gid:$id'), ('f_cats', '0'), ('advsearch', '1'), ('f_sfl', 'on'), ('f_sfu', 'on'), ('f_sft', 'on')]);

  /// The key comes from a link already seen, or from searching the number.
  Future<String> keyFor(int id, {required String site}) async {
    final known = keys.key(id);
    if (known != null) return known;
    final url = keySearchURL(id, site: site);
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
    final text = await _page(url, site);
    var found = entries(text, id);
    var perPage = page == 0 ? found.length : (_details[id]?.perPage ?? found.length);
    // An account set to read in the multi-page viewer gets links into it instead of page links;
    // the viewer's own page lists every page's key at once.
    final viewer = ContentURL.parse('${site}mpv/$id/$key/');
    if (found.isEmpty && viewer != null && linksToViewer(text, galleryID: id, key: key)) {
      found = viewerEntries(await _page(viewer, site), previews: viewerPreviews(text, galleryID: id));
      perPage = found.length;
    }
    if (found.isEmpty) throw ContentError.galleryNotFound;
    if (_details.length >= 64) _details.remove(_details.entries.reduce((a, b) => a.value.created.isBefore(b.value.created) ? a : b).key);
    final detail = _Detail(perPage: perPage < 1 ? 1 : perPage, entries: found);
    if (page == 0) {
      detail.extras = KeyedWorkPage.extras(text);
      detail.apiKey = KeyedWorkPage.apiKey(text);
    }
    _details[id] = detail;
    return detail;
  }

  // MARK: Ratings, comments and torrents

  Future<WorkExtras> extras(int id, {required String site}) async {
    _prepare(site);
    final key = await keyFor(id, site: site);
    var detail = await _detailPage(id, key: key, page: 0, site: site);
    if (detail.extras == null) {
      // A page cached by a later page's request lacks what only the first page says.
      _details.remove(id);
      detail = await _detailPage(id, key: key, page: 0, site: site);
    }
    return detail.extras ?? WorkExtras();
  }

  Future<List<WorkComment>> allComments(int id, {required String site}) async {
    _prepare(site);
    final key = await keyFor(id, site: site);
    final url = ContentURL.parse('${site}g/$id/$key/?hc=1');
    if (url == null) throw ContentError.invalidQuery;
    return KeyedWorkPage.comments(await _page(url, site));
  }

  Future<List<WorkTorrent>> torrents(int id, {required String site}) async {
    final info = await extras(id, site: site);
    if (info.torrentCount <= 0) return [];
    final key = await keyFor(id, site: site);
    // The work page names the torrent page; only a page on the connected website is followed.
    final named = info.torrentsURL;
    final url = named != null && named.host.toLowerCase() == ContentURL.parse(site)?.host.toLowerCase()
        ? named
        : ContentURL.withQueryItems('${site}gallerytorrents.php', [('gid', '$id'), ('t', key)]);
    return KeyedWorkPage.torrents(await _page(url, site));
  }

  Future<(double, int)> rate(int id, int halfStars, {required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    if (halfStars < 1 || halfStars > 10) throw ContentError.invalidQuery;
    final key = await keyFor(id, site: site);
    var detail = await _detailPage(id, key: key, page: 0, site: site);
    if (detail.apiKey == null) {
      _details.remove(id);
      detail = await _detailPage(id, key: key, page: 0, site: site);
    }
    final credentials = detail.apiKey;
    if (credentials == null) throw ContentError.signInRequired;
    final object = await _api({
      'method': 'rategallery',
      'apiuid': credentials.uid,
      'apikey': credentials.key,
      'gid': id,
      'token': key,
      'rating': halfStars,
    }, site);
    final average = object['rating_avg'];
    if (average is! num) throw ContentError.invalidResponse;
    final count = object['rating_cnt'] is num ? (object['rating_cnt'] as num).toInt() : 0;
    final info = _details[id]?.extras;
    if (info != null) {
      info.rating = average.toDouble();
      info.ratingCount = count;
    }
    return (average.toDouble(), count);
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
      final original = shown.original, host = ContentURL.parse(site)?.host.toLowerCase();
      if (original != null &&
          host != null &&
          loadsOriginals(host) &&
          SiteAccount.isSignedIn &&
          (_originalsRefusedUntil[host] ?? DateTime(0)).isBefore(DateTime.now())) {
        try {
          return await _fetch(original, galleryID: galleryID, limit: 64000000, site: site);
        } on CancellationError {
          rethrow;
        } on ContentError catch (error) {
          if (error == ContentError.imageLimit || error == ContentError.accessDenied || error == ContentError.temporarilyBlocked) rethrow;
          // The website keeps originals for GP the account may not have, or for quieter hours:
          // the page shown in their place serves meanwhile.
          _originalsRefusedUntil[host] = DateTime.now().add(const Duration(minutes: 10));
        } on Object {
          _originalsRefusedUntil[host] = DateTime.now().add(const Duration(minutes: 10));
        }
      }
      try {
        return await _fetch(shown.url, galleryID: galleryID, limit: 24000000, site: site);
      } catch (error) {
        // A notice in place of the image is the site's answer, not one host's failure.
        if (error == ContentError.imageLimit ||
            error == ContentError.signInRequired ||
            error == ContentError.accessDenied ||
            error == ContentError.temporarilyBlocked) {
          rethrow;
        }
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
    final host = ContentURL.parse(site)?.host.toLowerCase();
    final access = host == null ? null : SiteAccount.siteCookie(SiteAccount.accessCookie, host: host);
    final result = await transport.get(url, limit: limit, galleryID: galleryID);
    _prepare(site);
    final words = textNotice(result.data, mimeType: result.response.mimeType);
    if (words != null) throw words;
    if (!(result.response.mimeType?.startsWith('image/') ?? true) || result.data.length <= 32) throw ContentError.unsupportedFormat;
    final notice = imageNotice(result.data, url: result.response.url);
    if (notice != null) {
      // The wall means the access cookie lapsed; a fresh one is handed out on the next page.
      if (notice == ContentError.signInRequired && host != null) {
        SiteAccount.forgetRefused(SiteAccount.accessCookie, host: host, sent: access);
        if (SiteAccount.refusesAccess(host)) throw ContentError.accessDenied;
      }
      throw notice;
    }
    return result.data;
  }

  /// Image hosts answer in words when the account's allowance ran out or the network is banned,
  /// served where the image was expected. Only those two are read from such an answer.
  static ContentError? textNotice(List<int> data, {String? mimeType}) {
    if (data.length >= 10000 || (mimeType?.toLowerCase().startsWith('image/') ?? false)) return null;
    final notice = pageError(utf8.decode(data, allowMalformed: true));
    return notice == ContentError.imageLimit || notice == ContentError.temporarilyBlocked ? notice : null;
  }

  /// The site's own notices served where an image was expected, so they are never shown, cached or
  /// saved as a page: the bandwidth notice, and the wall a members-only catalog shows an account it
  /// no longer lets in. Known by address, or by size and digest.
  static ContentError? imageNotice(List<int> data, {required Uri url}) {
    if (isLimitNotice(url)) return ContentError.imageLimit;
    final notice = switch (data.length) {
      28658 => ('f54b887b017694dc25eb1a1404f71981885f8ed9', ContentError.imageLimit),
      144844 => ('e48ed350e902a51581246d2a764fa7827e8e6988', ContentError.signInRequired),
      _ => null,
    };
    if (notice == null) return null;
    return sha1.convert(data).toString() == notice.$1 ? notice.$2 : null;
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
    try {
      return await _loadPreviews(links, site, throwing: false);
    } on ContentError {
      return {};
    }
  }

  /// Details for works, 25 to a request. A failed request is asked once more after a moment;
  /// when it still fails, [throwing] decides whether the works it held are skipped or the failure is reported.
  Future<Map<int, NativeGallery>> _loadPreviews(List<KeyedLink> links, String site, {required bool throwing}) async {
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
      final chunk = missing.sublist(start, start + 25 > missing.length ? missing.length : start + 25);
      List<Map<String, Object?>> items;
      try {
        try {
          items = await _metadata(chunk, site);
        } on CancellationError {
          rethrow;
        } on Object {
          await Future<void>.delayed(const Duration(seconds: 1));
          _prepare(site);
          items = await _metadata(chunk, site);
        }
      } on CancellationError {
        rethrow;
      } on Object {
        if (throwing) rethrow;
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

  // MARK: Tags, comments, archives and settings profiles

  Future<List<WorkTagVote>> voteTag(int id, {required String tag, required int vote, required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    if ((vote != 1 && vote != -1) || tag.isEmpty || tag.length > 200) throw ContentError.invalidQuery;
    final key = await keyFor(id, site: site);
    var detail = await _detailPage(id, key: key, page: 0, site: site);
    if (detail.apiKey == null) {
      _details.remove(id);
      detail = await _detailPage(id, key: key, page: 0, site: site);
    }
    final credentials = detail.apiKey;
    if (credentials == null) throw ContentError.signInRequired;
    final object = await _api({
      'method': 'taggallery',
      'apiuid': credentials.uid,
      'apikey': credentials.key,
      'gid': id,
      'token': key,
      'tags': tag,
      'vote': vote,
    }, site);
    final message = object['error'];
    if (message is String && message.isNotEmpty) throw SiteMessage(message);
    final pane = object['tagpane'];
    final votes = KeyedWorkPage.tagVotes(pane is String ? pane : '');
    if (votes.isEmpty) throw ContentError.invalidResponse;
    _details[id]?.extras?.tagVotes = votes;
    return votes;
  }

  /// The website takes a comment of at least ten bytes, and joins it to the account's own comment
  /// when that one is the last.
  Future<List<WorkComment>> postComment(int id, String text, {required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final comment = text.trim();
    if (utf8.encode(comment).length < 10) throw SiteMessage(L10n.text('A comment is too short.'));
    if (utf8.encode(comment).length > 10000) throw ContentError.invalidQuery;
    final key = await keyFor(id, site: site);
    final url = ContentURL.parse('${site}g/$id/$key/');
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (url == null || host == null) throw ContentError.invalidQuery;
    await pacer.wait(host);
    final result = await transport.post(
      url,
      body: utf8.encode('commenttext_new=${formEncoded(comment)}'),
      contentType: 'application/x-www-form-urlencoded',
      limit: 3000000,
    );
    _prepare(site);
    final page = utf8.decode(result.data, allowMalformed: true);
    if (asksForSignIn(page)) throw ContentError.signInRequired;
    final error = pageError(page);
    if (error != null && error != ContentError.signInRequired) throw error;
    _details.remove(id);
    final probe = _commentProbe(comment);
    bool posted(List<WorkComment> comments) => comments.any((item) => _commentProbe(item.text).contains(probe));
    var comments = KeyedWorkPage.comments(page);
    if (posted(comments)) return comments;
    // A long conversation shows only part of itself on the work's page.
    comments = await allComments(id, site: site);
    if (posted(comments)) return comments;
    final refusal = KeyedWorkPage.firstCapture(r'<p class="br">(.*?)</p>', page);
    throw SiteMessage(refusal == null ? L10n.text('The website didn’t take the comment. Try again later.') : KeyedWorkPage.plain(refusal));
  }

  static String _commentProbe(String text) {
    final compact = text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return compact.length > 40 ? compact.substring(0, 40) : compact;
  }

  Future<Uri> _archiverURL(int id, String site) async {
    final info = await extras(id, site: site);
    // The work page names its archive page; only a page on the connected website is followed.
    final named = info.archiveURL;
    if (named != null && named.host.toLowerCase() == ContentURL.parse(site)?.host.toLowerCase()) return named;
    final key = await keyFor(id, site: site);
    return ContentURL.withQueryItems('${site}archiver.php', [('gid', '$id'), ('token', key)]);
  }

  Future<WorkArchiveOffer> archiveOffer(int id, {required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final offer = KeyedWorkPage.archiveOffer(await _page(await _archiverURL(id, site), site));
    if (offer.options.isEmpty) throw ContentError.unsupportedFormat;
    return offer;
  }

  Future<Uri> archiveDownloadURL(int id, WorkArchiveOption option, {required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    if (!const ['org', 'res'].contains(option.kind) || !option.available) throw ContentError.invalidQuery;
    final url = await _archiverURL(id, site);
    await pacer.wait(url.host.toLowerCase());
    final form = 'dltype=${formEncoded(option.kind)}&dlcheck=${formEncoded(option.button)}';
    final result = await transport.post(url, body: utf8.encode(form), contentType: 'application/x-www-form-urlencoded', limit: 1000000);
    _prepare(site);
    final page = utf8.decode(result.data, allowMalformed: true);
    if (asksForSignIn(page)) throw ContentError.signInRequired;
    final address = KeyedWorkPage.archiveDownloadURL(page);
    if (address == null) throw SiteMessage(KeyedWorkPage.message(page) ?? L10n.text('The website didn’t prepare the archive. Try again later.'));
    if (!safeMediaURL(address)) throw ContentError.unsupportedFormat;
    MangaUrls.registerMedia([address], site: site);
    return address;
  }

  /// The account's settings profiles, which one the app uses checked.
  Future<List<SiteSettingsProfile>> settingsProfiles({required String site}) async {
    _prepare(site);
    final url = ContentURL.parse('${site}uconfig.php');
    if (!SiteAccount.isSignedIn || url == null) throw ContentError.signInRequired;
    return KeyedWorkPage.settingsProfiles(await _page(url, site));
  }

  /// Reads the website with one of the account's settings profiles from now on.
  void useSettingsProfile(int profile, {required String site}) {
    _prepare(site);
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (profile < 1 || profile > 9999 || host == null) throw ContentError.invalidQuery;
    SiteAccount.setSiteCookie(profileCookie, '$profile', host: host);
    // Lists and work pages read with the other profile may look different.
    _feeds.clear();
    _details.clear();
    _toplists.clear();
    _popular = null;
  }

  /// The cookie the website reads the chosen settings profile from.
  static const profileCookie = 'sp';

  // MARK: Account favorites

  /// One page of the signed-in account's favorites, newest first, from one category or all.
  Future<(List<int>, String?)> favorites({String? after, int? category, required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final items = [if (category != null && category >= 0 && category <= 9) ('favcat', '$category'), if (after != null) ('next', after)];
    final url = ContentURL.withQueryItems('${site}favorites.php', items.isEmpty ? null : items);
    final text = await _page(url, site);
    final found = links(text);
    keys.rememberAll([for (final link in found) (link.id, link.key)]);
    await _previewsFor(found, site);
    final cursor = nextCursor(text);
    return ([for (final link in found) link.id], found.isEmpty || cursor == after ? null : cursor);
  }

  /// How many images the account has viewed against its allowance, when the site shows it.
  Future<(int, int)?> imageAllowance({required String site}) async {
    _prepare(site);
    final url = ContentURL.parse('${site}home.php');
    if (!SiteAccount.isSignedIn || url == null) return null;
    try {
      return imageAllowanceIn(await _page(url, site));
    } on ContentError catch (error) {
      if (error.isUnavailable(404)) return null;
      rethrow;
    }
  }

  static (int, int)? imageAllowanceIn(String text) {
    final used = int.tryParse((KeyedWorkPage.firstCapture(r'currently at\s*<strong>([0-9,]+)</strong>', text) ?? '').replaceAll(',', ''));
    final limit = int.tryParse((KeyedWorkPage.firstCapture(r'limit of\s*<strong>([0-9,]+)</strong>', text) ?? '').replaceAll(',', ''));
    if (used == null || limit == null || limit <= 0) return null;
    return (used, limit);
  }

  /// The account's favorites categories with their names and how many works each holds.
  Future<List<FavoriteCategory>> favoriteCategories({required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final url = ContentURL.parse('${site}favorites.php');
    if (url == null) throw ContentError.invalidQuery;
    final categories = favoriteCategoriesIn(await _page(url, site));
    if (categories.isEmpty) throw ContentError.unsupportedFormat;
    return categories;
  }

  /// Category rows at the top of the favorites page: each names its number in its link, then
  /// shows its count, its icon and its name.
  static List<FavoriteCategory> favoriteCategoriesIn(String text) {
    final matches = RegExp(r'<div class="fp(?: [^"]*)?"[^>]*favcat=([0-9])[^>]*>').allMatches(text).toList();
    final result = <FavoriteCategory>[];
    for (var index = 0; index < matches.length; index++) {
      final number = int.parse(matches[index].group(1)!);
      if (result.any((category) => category.id == number)) continue;
      final start = matches[index].end;
      final end = index + 1 < matches.length ? matches[index + 1].start : (start + 800).clamp(0, text.length);
      final texts = KeyedWorkPage.textsInDivs(text.substring(start, end));
      final count = int.tryParse((texts.firstOrNull ?? '').replaceAll(',', '')) ?? 0;
      // The last row runs on into the "show all" button after it, so the name is the first text after the count.
      final name = texts.skip(1).firstWhere((value) => value.isNotEmpty && int.tryParse(value.replaceAll(',', '')) == null, orElse: () => '');
      result.add(FavoriteCategory(id: number, name: name.isEmpty ? '$number' : name, count: count));
    }
    return result..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> setFavorite(int id, {required bool saved, int category = 0, required String site}) async {
    _prepare(site);
    if (!SiteAccount.isSignedIn) throw ContentError.signInRequired;
    final key = await keyFor(id, site: site);
    final url = ContentURL.withQueryItems('${site}gallerypopups.php', [('gid', '$id'), ('t', key), ('act', 'addfav')]);
    // The form sends the note along, so a work that is already a favorite keeps the note written
    // for it; a work its page showed as no favorite has none to keep.
    var note = '';
    final shown = _details[id]?.extras;
    if (saved && (shown == null || shown.favoriteCategory != null)) note = favoriteNote(await _page(url, site)) ?? '';
    // The form's own submit button names the change; removing sends the button its page shows for it.
    final form = saved
        ? 'favcat=${category.clamp(0, 9)}&favnote=${formEncoded(note)}&apply=Add+to+Favorites&update=1'
        : 'favcat=favdel&favnote=&apply=Apply+Changes&update=1';
    final host = ContentURL.parse(site)?.host.toLowerCase();
    if (host != null) await pacer.wait(host);
    final result = await transport.post(url, body: utf8.encode(form), contentType: 'application/x-www-form-urlencoded', limit: 1000000);
    _prepare(site);
    // The work page read before the change shows the old favorite.
    _details[id]?.extras = null;
    final text = utf8.decode(result.data, allowMalformed: true);
    if (asksForSignIn(text) || text.contains('Failed login redirect setup')) throw ContentError.signInRequired;
    // A wrong key, a removed work or a ban is answered in a few words instead of with the change.
    final error = pageError(text);
    if (error != null && error != ContentError.signInRequired) throw error;
  }

  /// The note the account wrote for a favorite, from the favorites form.
  static String? favoriteNote(String html) {
    final note = KeyedWorkPage.firstCapture(r'<textarea\b[^>]*\bname="favnote"[^>]*>(.*?)</textarea>', html);
    return note == null ? null : NativeGallery.decodeEntities(note);
  }

  /// A form value, with only unreserved ASCII left as is.
  static String formEncoded(String value) => Uri.encodeQueryComponent(value).replaceAll('%20', '+');

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

  static final _viewerAddressPattern = RegExp(r'/mpv/([0-9]{1,10})/([0-9a-f]{10})(?![0-9a-f])');
  static final _pageAddressPattern = RegExp(r'/s/[0-9a-f]{10}/([0-9]{1,10})-([0-9]{1,5})(?![0-9])');

  /// Links into the multi-page viewer, which name the work's number and key like its own link.
  static List<KeyedLink> viewerLinks(String text) {
    final seen = <int>{};
    return [
      for (final match in _viewerAddressPattern.allMatches(text))
        if (int.tryParse(match[1]!) case final id? when id > 0 && seen.add(id)) KeyedLink(id, match[2]!),
    ];
  }

  /// Links to one page of a work: the work's number and the page, from 1. The key in them is the page's, not the work's.
  static List<(int, int)> pageLinks(String text) => [
    for (final match in _pageAddressPattern.allMatches(text))
      if ((int.tryParse(match[1]!), int.tryParse(match[2]!)) case (final id?, final page?) when id > 0 && page >= 1) (id, page),
  ];

  static String? nextCursor(String text) {
    final tag = RegExp(r'<a\b[^>]*\bid="unext"[^>]*>').firstMatch(text);
    final href = tag == null ? null : _attribute('href', tag[0]!);
    final url = href == null ? null : Uri.tryParse(_decode(href));
    final value = url == null ? null : ContentURL.queryValue(url, 'next');
    if (value == null || !RegExp(r'^[0-9A-Za-z_-]{1,40}$').hasMatch(value)) return null;
    return value;
  }

  static final _entryPattern = RegExp(r'<a\b[^>]*\bhref="([^"]*)/s/([0-9a-f]{10})/([0-9]{1,10})-([0-9]{1,5})"[^>]*>(.*?)</a>', dotAll: true);

  /// Page links on a work's page, by zero-based page index, with each page's preview.
  static Map<int, KeyedEntry> entries(String text, int galleryID) {
    final result = <int, KeyedEntry>{};
    for (final match in _entryPattern.allMatches(text)) {
      final number = int.tryParse(match[4]!);
      if (int.tryParse(match[3]!) != galleryID || number == null || number < 1) continue;
      final body = match[5]!;
      var name = '$number';
      final title = _attribute('title', body);
      final colon = title?.indexOf(': ') ?? -1;
      if (title != null && colon >= 0) name = _decode(title.substring(colon + 2));
      // The page link beside a preview says which site a preview starting at the root belongs to.
      final link = ContentURL.parse(_decode(match[1]!));
      final base = link != null && link.scheme == 'https' && link.host.isNotEmpty ? link : null;
      result[number - 1] = KeyedEntry(
        key: match[2]!,
        name: name,
        thumb: _thumb(body, base: base),
      );
    }
    return result;
  }

  /// A preview address, resolved against the page link beside it when it starts at the site's root.
  static Uri? _mediaURL(String value, {Uri? base}) {
    final address = _decode(value).replaceAll(RegExp('''^['" ]+|['" ]+\$'''), '');
    final relative = address.startsWith('/') && !address.startsWith('//');
    final url = relative ? base?.resolve(address) : ContentURL.parse(address);
    return url != null && safeMediaURL(url) ? url : null;
  }

  static KeyedThumb? _thumb(String body, {Uri? base}) {
    final style = _attribute('style', body);
    final size = style == null ? null : RegExp(r'width:\s*([0-9]+)px;\s*height:\s*([0-9]+)px').firstMatch(style);
    final sheet = style == null ? null : RegExp(r'url\(([^)]+)\)\s*(-?[0-9]+)px').firstMatch(style);
    if (size != null && sheet != null) {
      final numbers = size[0]!.split(RegExp(r'[^0-9]+')).where((part) => part.isNotEmpty).map(int.parse).toList();
      final declaration = sheet[0]!;
      final open = declaration.indexOf('('), close = declaration.indexOf(')');
      if (numbers.length != 2 || open < 0 || close < 0) return null;
      final url = _mediaURL(declaration.substring(open + 1, close), base: base);
      final trailing = declaration.substring(close + 1).trim();
      final offset = int.tryParse(trailing.length >= 2 ? trailing.substring(0, trailing.length - 2) : '');
      if (url == null || offset == null) return null;
      return KeyedThumb(url, CropRect(-offset, 0, numbers[0], numbers[1]));
    }
    final image = RegExp(r'<img\b[^>]*>').firstMatch(body);
    final value = image == null ? null : _attribute('src', image[0]!);
    final url = value == null ? null : _mediaURL(value, base: base);
    if (url != null) return KeyedThumb(url, null);
    // Large previews are whole images drawn as a background with no offset into a sheet.
    final whole = style == null ? null : RegExp(r'url\(([^)]+)\)').firstMatch(style);
    final wholeURL = whole == null ? null : _mediaURL(whole[1]!, base: base);
    if (wholeURL != null) return KeyedThumb(wholeURL, null);
    return null;
  }

  static final _viewerLinkPattern = RegExp(r'/mpv/([0-9]{1,10})/([0-9a-f]{10})/');

  /// Whether a work's page links its pages into the multi-page viewer rather than to each page.
  static bool linksToViewer(String text, {required int galleryID, required String key}) =>
      _viewerLinkPattern.allMatches(text).any((match) => int.tryParse(match[1]!) == galleryID && match[2] == key);

  static final _viewerPreviewPattern = RegExp(r'<a\b[^>]*\bhref="([^"]*)/mpv/([0-9]{1,10})/[0-9a-f]{10}/#page([0-9]{1,5})"[^>]*>(.*?)</a>', dotAll: true);

  /// The previews a work's page shows beside its links into the multi-page viewer, by zero-based page index.
  static Map<int, KeyedThumb> viewerPreviews(String text, {required int galleryID}) {
    final result = <int, KeyedThumb>{};
    for (final match in _viewerPreviewPattern.allMatches(text)) {
      final number = int.tryParse(match[3]!);
      if (int.tryParse(match[2]!) != galleryID || number == null || number < 1) continue;
      final link = ContentURL.parse(_decode(match[1]!));
      final base = link != null && link.scheme == 'https' && link.host.isNotEmpty ? link : null;
      final thumb = _thumb(match[4]!, base: base);
      if (thumb != null) result[number - 1] = thumb;
    }
    return result;
  }

  /// Every page of a work from the multi-page viewer's list: each page's key, file name and preview, in page order.
  /// A page whose listed preview is not a plain address takes the one its work page showed, when it showed one.
  static Map<int, KeyedEntry> viewerEntries(String text, {Map<int, KeyedThumb> previews = const {}}) {
    final start = RegExp(r'\bimagelist\s*=\s*\[').firstMatch(text);
    if (start == null) return {};
    final open = start.end - 1;
    var depth = 0;
    var quoted = false, escaped = false;
    int? close;
    for (var index = open; index < text.length; index++) {
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
      } else if (character == '[' || character == '{') {
        depth += 1;
      } else if (character == ']' || character == '}') {
        depth -= 1;
        if (depth == 0) {
          close = index;
          break;
        }
      }
    }
    if (close == null) return {};
    final Object? items;
    try {
      items = jsonDecode(text.substring(open, close + 1));
    } on FormatException {
      return {};
    }
    if (items is! List || items.length > 10000) return {};
    final result = <int, KeyedEntry>{};
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item is! Map) continue;
      final key = item['k'];
      if (key is! String || !GalleryKeys.isKey(key)) continue;
      final given = item['n'];
      final decoded = given is String ? _decode(given) : '';
      final preview = item['t'];
      final previewURL = preview is String ? ContentURL.parse(preview) : null;
      result[index] = KeyedEntry(
        key: key,
        name: decoded.isEmpty ? '${index + 1}' : decoded,
        thumb: previewURL != null && safeMediaURL(previewURL) ? KeyedThumb(previewURL, null) : previews[index],
      );
    }
    return result;
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
    // Shown only to signed-in accounts, and only when the original is larger than the page shown.
    final link = KeyedWorkPage.firstCapture(r'<a\b[^>]*\bhref="([^"]*fullimg[^"]*)"', text);
    final original = link == null ? null : ContentURL.parse(_decode(link));
    return ShownImage(url, call?[1], original: original != null && original.scheme == 'https' ? original : null);
  }

  static const _originalsKey = 'manga.originalImageSites';

  /// Whether the reader loads each page's original file on [host], for a signed-in account.
  static bool loadsOriginals(String host) => _originalHosts().contains(host);

  static Set<String> _originalHosts() {
    final value = ContentPreferences.defaults.object(_originalsKey);
    return {if (value is List) ...value.whereType<String>()};
  }

  static void setLoadsOriginals(bool loads, {required String host}) {
    final hosts = _originalHosts();
    if (loads) {
      hosts.add(host);
    } else {
      hosts.remove(host);
    }
    ContentPreferences.defaults.set(_originalsKey, (hosts.toList()..sort()));
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
    // Always sent, so the categories picked here win over those an account leaves out by default.
    final shown = categories.fold(0, (value, category) => value | (_categoryBits[category] ?? 0));
    items.add(('f_cats', '${1023 & ~shown}'));
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
      pageCount: (_number(item['filecount']) ?? 0).clamp(0, 10000),
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
