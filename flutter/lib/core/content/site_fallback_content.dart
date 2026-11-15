import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'combined_catalog.dart';
import 'content_errors.dart';
import 'content_url.dart';
import 'cover_queue.dart';
import 'gallery_content.dart';
import 'keyed_work_extras.dart';
import 'manga_content_source.dart';
import 'manga_urls.dart';

/// Which connected website last opened a work after the checked one could not. Every connected
/// website numbers works the same way, so a work missing on one may still open on another; once it
/// does, it opens there first from then on.
class WorkSiteMemory {
  WorkSiteMemory({this.file, this.limit = 20000});

  /// The app replaces this with a file-backed instance in its support directory at launch.
  static WorkSiteMemory shared = WorkSiteMemory();

  final File? file;
  final int limit;
  final _sites = <int, String>{};
  final _order = <int>[];
  bool _loaded = false;
  bool _saving = false;

  String? site(int id) {
    _loadIfNeeded();
    return _sites[id];
  }

  int get count {
    _loadIfNeeded();
    return _sites.length;
  }

  /// Remembers the website that opened a work, or forgets it when [site] is null.
  void remember(int id, String? site) {
    _loadIfNeeded();
    if (_sites[id] == site) return;
    if (site != null) {
      if (!_sites.containsKey(id)) _order.add(id);
      _sites[id] = site;
    } else {
      _sites.remove(id);
      _order.remove(id);
    }
    if (_order.length > limit) {
      final dropped = _order.length - limit * 9 ~/ 10;
      for (final id in _order.take(dropped)) {
        _sites.remove(id);
      }
      _order.removeRange(0, dropped);
    }
    _scheduleSave();
  }

  /// Forgets every work remembered on [site], as when the website is removed.
  void forget(String site) {
    _loadIfNeeded();
    final before = _sites.length;
    _sites.removeWhere((_, value) => value == site);
    _order.removeWhere((id) => !_sites.containsKey(id));
    if (_sites.length != before) _scheduleSave();
  }

  void removeAll() {
    _sites.clear();
    _order.clear();
    _loaded = true;
    final file = this.file;
    if (file != null && file.existsSync()) file.deleteSync();
  }

  void _loadIfNeeded() {
    if (_loaded) return;
    _loaded = true;
    final file = this.file;
    if (file == null || !file.existsSync()) return;
    try {
      final rows = jsonDecode(file.readAsStringSync());
      if (rows is! List) return;
      for (final row in rows) {
        if (row is! List || row.length != 2 || row[0] is! String || row[1] is! String) continue;
        final id = int.tryParse(row[0] as String);
        if (id == null || id <= 0 || (row[1] as String).isEmpty || _sites.containsKey(id)) continue;
        _sites[id] = row[1] as String;
        _order.add(id);
      }
    } on Object {
      // A damaged list is rebuilt as works open elsewhere again.
    }
  }

  void _scheduleSave() {
    final file = this.file;
    if (file == null || _saving) return;
    _saving = true;
    Future<void>.delayed(const Duration(seconds: 2), () {
      _saving = false;
      final rows = [
        for (final id in _order)
          if (_sites[id] case final site?) ['$id', site],
      ];
      try {
        file.parent.createSync(recursive: true);
        final temporary = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(rows), flush: true);
        temporary.renameSync(file.path);
      } on FileSystemException {
        // The list only saves a detour; losing it costs one failed request later.
      }
    });
  }
}

/// Opens works from whichever connected website still carries them, so saved works never need
/// the checked website switched by hand. Lists and searches stay on the checked website.
class SiteFallbackContent extends ContentProviding implements WorkExtrasProviding {
  SiteFallbackContent({
    ContentProviding? primary,
    ContentProviding Function(String site)? sourceFor,
    (String, List<String>) Function()? sites,
    WorkSiteMemory? memory,
    bool Function(String site)? blocksBulkReading,
  }) : _primaryOverride = primary,
       _sourceFor = sourceFor ?? SiteContent.of,
       _sites = sites ?? (() => (ComicSites.active, ComicSites.all)),
       _memoryOverride = memory,
       _blocksBulkReading = blocksBulkReading ?? CoverFillGuard.blocksBulkReading;

  static SiteFallbackContent shared = SiteFallbackContent();

  /// Tests pass their own; the app reads the shared ones, which launch may replace.
  final ContentProviding? _primaryOverride;
  final ContentProviding Function(String site) _sourceFor;
  final (String, List<String>) Function() _sites;
  final WorkSiteMemory? _memoryOverride;
  final bool Function(String site) _blocksBulkReading;

  ContentProviding get primary => _primaryOverride ?? MangaContentSource.shared;
  WorkSiteMemory get memory => _memoryOverride ?? WorkSiteMemory.shared;

  /// The website each work in this session was read from, so its pages load there too.
  final _serving = <int, String>{};

  /// The website a saved work came from, tried before the other connected websites.
  final _origins = <int, String>{};

  /// Names the website a saved work came from, so it is tried right after the checked website.
  void prefer(String? site, int id) {
    if (site == null || site.isEmpty) return;
    if (_origins.length > 4096) _origins.clear();
    _origins[id] = site;
  }

  /// Websites to try for a work, in order: where it last opened after the checked website could
  /// not, the checked website, then the other connected websites.
  List<String> candidates(int id, {String? preferring}) {
    final (active, all) = _sites();
    final order = <String>[];
    void add(String? site) {
      if (site == null || site.isEmpty || !(all.contains(site) || site == active) || order.contains(site)) return;
      order.add(site);
    }

    add(memory.site(id));
    add(preferring);
    add(active);
    add(_origins[id]);
    all.forEach(add);
    return order;
  }

  /// The website a work was last read from in this session, when it is not the checked one.
  String? servingSite(int id) {
    final site = _serving[id];
    return site == _sites().$1 ? null : site;
  }

  ContentProviding _source(String site) => site == _sites().$1 ? primary : _sourceFor(site);

  /// `inBulk` reads for a background fill. Websites that block bulk reading are read last, and
  /// only for a work every other connected website says it no longer has; a work the others
  /// could not be asked about is left for later.
  @override
  Future<NativeGallery> gallery(int id, {String? preferring, bool inBulk = false}) async {
    final order = candidates(id, preferring: preferring);
    if (order.isEmpty) return primary.gallery(id);
    final skipped = inBulk ? CoverFillGuard.skipped(_sites().$2, blocks: _blocksBulkReading) : const <String>{};
    final others = order.where((site) => !skipped.contains(site)), last = order.where(skipped.contains);
    Object? firstError;
    StackTrace? firstTrace;
    var missingElsewhere = true;
    for (final site in [...others, ...last]) {
      final blocking = inBulk && _blocksBulkReading(site);
      // Not missing: the other websites could not be read, and this one may carry it.
      if (skipped.contains(site) && !missingElsewhere) throw const LeftForBlockingSite();
      if (blocking) _blockingReads.add(id);
      try {
        final gallery = await _source(site).gallery(id);
        _record(id, site, afterFailure: firstError != null);
        return gallery;
      } on CancellationError {
        rethrow;
      } catch (error, trace) {
        if (!ContentError.allowsOtherSite(error)) {
          if (firstError != null) Error.throwWithStackTrace(firstError, firstTrace!);
          rethrow;
        }
        // A website that stopped answering this device is not asked again in a fill.
        if (blocking && ContentError.refusesDevice(error)) rethrow;
        firstError ??= error;
        firstTrace ??= trace;
        if (!ContentError.isMissingWork(error)) missingElsewhere = false;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstTrace!);
    throw ContentError.galleryNotFound;
  }

  /// Works a fill read from a website that blocks bulk reading, until the fill asks.
  final _blockingReads = <int>{};

  /// Whether a fill's last read of a work went to a website that blocks bulk reading, so the
  /// next read waits longer. Asking forgets it.
  bool tookBlockingRead(int id) => _blockingReads.remove(id);

  void _record(int id, String site, {required bool afterFailure}) {
    if (_serving.length > 4096) _serving.clear();
    _serving[id] = site;
    final remembered = memory.site(id);
    if (site == _sites().$1) {
      // The checked website carries it again; it no longer needs a detour.
      if (remembered != null) memory.remember(id, null);
    } else if (afterFailure && remembered != site) {
      memory.remember(id, site);
    }
  }

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) =>
      _source(_imageSite(page, galleryID)).image(page, galleryID: galleryID, thumbnail: thumbnail);

  /// Pages load from the website their work was read from.
  String _imageSite(GalleryPage page, int galleryID) {
    final (active, all) = _sites();
    final home = page.sourceSite;
    final host = home == null ? null : ContentURL.parse(home)?.host.toLowerCase();
    if (host != null && (host == active || all.contains(host))) return host;
    return _serving[galleryID] ?? active;
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) => primary.list(query, offset: offset, count: count);

  @override
  Future<List<TagSuggestion>> suggestions(String token) => primary.suggestions(token);

  @override
  NativeGallery? cachedGallery(int id) {
    final site = _serving[id] ?? memory.site(id);
    if (site != null && site != _sites().$1) {
      final cached = _sourceFor(site).cachedGallery(id);
      if (cached != null) return cached;
    }
    return primary.cachedGallery(id);
  }

  @override
  NativeGallery? cachedPreview(int id) {
    final site = _serving[id] ?? memory.site(id);
    if (site != null && site != _sites().$1) {
      final cached = _sourceFor(site).cachedPreview(id);
      if (cached != null) return cached;
    }
    return primary.cachedPreview(id);
  }

  /// Ratings, comments and torrents come from the website the work was read from.
  WorkExtrasProviding? _extrasSource(int id) {
    final source = _source(_serving[id] ?? _sites().$1);
    return source is WorkExtrasProviding ? source as WorkExtrasProviding : null;
  }

  @override
  Future<WorkExtras?> extras(int id) async => _extrasSource(id)?.extras(id);
  @override
  Future<List<WorkComment>> allComments(int id) async => await _extrasSource(id)?.allComments(id) ?? const [];
  @override
  Future<List<WorkTorrent>> torrents(int id) async => await _extrasSource(id)?.torrents(id) ?? const [];
  @override
  Future<(double, int)> rate(int id, int halfStars) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.rate(id, halfStars);
  }
}
