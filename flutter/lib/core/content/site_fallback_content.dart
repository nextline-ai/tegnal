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

/// Which connected websites no longer carry a work. Every connected website numbers works the same
/// way, so a work deleted on one may still open on another. The checked website is always asked
/// first, unless it has already said it no longer has the work; switching websites to use what
/// another one offers then opens works there.
class WorkSiteMemory {
  WorkSiteMemory({this.file, this.limit = 20000});

  /// The app replaces this with a file-backed instance in its support directory at launch.
  static WorkSiteMemory shared = WorkSiteMemory();

  final File? file;
  final int limit;
  final _missing = <int, Set<String>>{};
  final _order = <int>[];
  bool _loaded = false;
  bool _saving = false;

  /// The websites that said they no longer have the work.
  Set<String> missingSites(int id) {
    _loadIfNeeded();
    return {...?_missing[id]};
  }

  /// Works some website no longer has.
  int get count {
    _loadIfNeeded();
    return _missing.length;
  }

  /// Notes that [site] answered it no longer has the work.
  void markMissing(int id, String site) {
    _loadIfNeeded();
    if (_missing[id]?.contains(site) ?? false) return;
    if (!_missing.containsKey(id)) _order.add(id);
    (_missing[id] ??= {}).add(site);
    if (_order.length > limit) {
      final dropped = _order.length - limit * 9 ~/ 10;
      for (final id in _order.take(dropped)) {
        _missing.remove(id);
      }
      _order.removeRange(0, dropped);
    }
    _scheduleSave();
  }

  /// Notes that [site] carries the work again.
  void markFound(int id, String site) {
    _loadIfNeeded();
    final sites = _missing[id];
    if (sites == null || !sites.remove(site)) return;
    if (sites.isEmpty) {
      _missing.remove(id);
      _order.remove(id);
    }
    _scheduleSave();
  }

  /// Forgets what [site] said, as when the website is removed.
  void forget(String site) {
    _loadIfNeeded();
    var changed = false;
    for (final sites in _missing.values) {
      changed = sites.remove(site) || changed;
    }
    _missing.removeWhere((_, sites) => sites.isEmpty);
    _order.removeWhere((id) => !_missing.containsKey(id));
    if (changed) _scheduleSave();
  }

  void removeAll() {
    _missing.clear();
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
        if (id == null || id <= 0 || (row[1] as String).isEmpty) continue;
        if (!_missing.containsKey(id)) _order.add(id);
        (_missing[id] ??= {}).add(row[1] as String);
      }
    } on Object {
      // A damaged list is rebuilt as websites answer again.
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
          for (final site in (_missing[id]?.toList() ?? const <String>[])..sort()) ['$id', site],
      ];
      try {
        file.parent.createSync(recursive: true);
        final temporary = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(rows), flush: true);
        temporary.renameSync(file.path);
      } on FileSystemException {
        // The list only saves a request; losing it costs one failed request later.
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

  /// Websites to try for a work, in order: the checked website, the one named for it, the one it
  /// was saved from, then the other connected websites. Websites that said they no longer have
  /// it go last, in case they carry it again.
  List<String> candidates(int id, {String? preferring}) {
    final (active, all) = _sites();
    final order = <String>[];
    void add(String? site) {
      if (site == null || site.isEmpty || !(all.contains(site) || site == active) || order.contains(site)) return;
      order.add(site);
    }

    add(active);
    add(preferring);
    add(_origins[id]);
    all.forEach(add);
    final missing = memory.missingSites(id);
    return [...order.where((site) => !missing.contains(site)), ...order.where(missing.contains)];
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
  Future<NativeGallery> gallery(int id, {String? preferring, bool inBulk = false}) =>
      _read(id, preferring: preferring, inBulk: inBulk, (source) => source.gallery(id));

  /// A work as a card or a fill needs it, from the same websites in the same order as [gallery].
  @override
  Future<NativeGallery> preview(int id, {String? preferring, bool inBulk = false}) =>
      _read(id, preferring: preferring, inBulk: inBulk, (source) => source.preview(id));

  Future<NativeGallery> _read(int id, Future<NativeGallery> Function(ContentProviding source) body, {String? preferring, required bool inBulk}) async {
    final order = candidates(id, preferring: preferring);
    if (order.isEmpty) return body(primary);
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
        final gallery = await body(_source(site));
        _record(id, site);
        return gallery;
      } on CancellationError {
        rethrow;
      } catch (error, trace) {
        if (ContentError.isMissingWork(error)) memory.markMissing(id, site);
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

  void _record(int id, String site) {
    if (_serving.length > 4096) _serving.clear();
    _serving[id] = site;
    // A website that carries the work again is asked in its turn from now on.
    memory.markFound(id, site);
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
    final site = _serving[id] ?? candidates(id).firstOrNull;
    if (site != null && site != _sites().$1) {
      final cached = _sourceFor(site).cachedGallery(id);
      if (cached != null) return cached;
    }
    return primary.cachedGallery(id);
  }

  @override
  NativeGallery? cachedPreview(int id) {
    final site = _serving[id] ?? candidates(id).firstOrNull;
    if (site != null && site != _sites().$1) {
      final cached = _sourceFor(site).cachedPreview(id);
      if (cached != null) return cached;
    }
    return primary.cachedPreview(id);
  }

  /// Ratings and comments come from the website the work was read from.
  WorkExtrasProviding? _extrasSource(int id) {
    final source = _source(_serving[id] ?? _sites().$1);
    return source is WorkExtrasProviding ? source as WorkExtrasProviding : null;
  }

  @override
  Future<WorkExtras?> extras(int id) async => _extrasSource(id)?.extras(id);
  @override
  Future<List<WorkComment>> allComments(int id) async => await _extrasSource(id)?.allComments(id) ?? const [];
  @override
  Future<(double, int)> rate(int id, int halfStars) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.rate(id, halfStars);
  }

  @override
  Future<List<WorkTagVote>> voteTag(int id, {required String tag, required int vote}) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.voteTag(id, tag: tag, vote: vote);
  }

  @override
  Future<List<WorkComment>> postComment(int id, String text) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.postComment(id, text);
  }

  @override
  Future<WorkArchiveOffer> archiveOffer(int id) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.archiveOffer(id);
  }

  @override
  Future<Uri> archiveDownloadURL(int id, WorkArchiveOption option) {
    final source = _extrasSource(id);
    if (source == null) throw ContentError.unsupportedFormat;
    return source.archiveDownloadURL(id, option);
  }
}
