import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../storage/app_database.dart';
import '../support/preferences.dart';
import '../storage/app_storage.dart';
import 'combined_catalog.dart';
import 'content_errors.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';
import 'site_fallback_content.dart';

/// What the person chose the last time they were asked about filling, on this device.
enum CoverFillDecision { none, declined, approved }

/// Whether a fill may read now.
sealed class CoverFillOutcome {
  const CoverFillOutcome();
}

final class CoverFillRun extends CoverFillOutcome {
  const CoverFillRun();
  @override
  bool operator ==(Object other) => other is CoverFillRun;
  @override
  int get hashCode => 1;
}

/// Wait for the person: they chose not to fill from these websites.
final class CoverFillHold extends CoverFillOutcome {
  const CoverFillHold();
  @override
  bool operator ==(Object other) => other is CoverFillHold;
  @override
  int get hashCode => 2;
}

/// Ask first: `pending` works would be read from `sites` alone.
final class CoverFillAsk extends CoverFillOutcome {
  const CoverFillAsk(this.pending, this.sites);
  final int pending;
  final List<String> sites;
  @override
  bool operator ==(Object other) => other is CoverFillAsk && other.pending == pending && listEquals(other.sites, sites);
  @override
  int get hashCode => Object.hash(pending, Object.hashAll(sites));
  @override
  String toString() => 'CoverFillAsk($pending, $sites)';
}

/// Thrown when the other websites could not be asked about a work: the websites that block bulk
/// reading are read only for a work the others no longer have, so it waits for a later fill.
class LeftForBlockingSite implements Exception {
  const LeftForBlockingSite();
}

/// `CoverFillGuard`: some comics websites, the keyed kind, block a network address that reads
/// many works in a short time. Filling a library reads every work that lacks information, so it
/// reads from the other connected websites when there are any, going to such a website only for a
/// work the others no longer have, and asks first when there are none.
abstract final class CoverFillGuard {
  /// Works filled without asking even from such a website: a few new saves.
  static const quietLimit = 10;

  /// How long the fill waits after a work read from such a website.
  static const slowDelay = Duration(seconds: 2);

  /// The websites known to block bulk reading, by digest of their domain, for the time before
  /// their protocol is learned (a members-only one shows signed-out visitors nothing to learn from).
  static const _domains = {
    '1b047e60dd887a4f010dc3ee0c3305b011d3ee6e40b8cd8d7a70c5fe74efc955',
    '3eb2fe8d6f00dba0f737d0c6996400f0b2bd7b989f0d2922dadaaca1f3dddfe6',
  };

  static bool blocksBulkReadingWith(String site, MangaBackend? backend) {
    if (backend == MangaBackend.keyed) return true;
    final labels = BooruServer.bareHost(site).split('.');
    if (labels.length < 2) return false;
    final domain = labels.sublist(labels.length - 2).join('.');
    return _domains.contains(sha256.convert(utf8.encode(domain)).toString());
  }

  static bool blocksBulkReading(String site) => blocksBulkReadingWith(site, ComicSites.backendOf(site));

  /// The websites a fill reads last, for works the others no longer have: those that block bulk
  /// reading, while another website can be read.
  static Set<String> skipped(List<String> sites, {bool Function(String site) blocks = blocksBulkReading}) {
    final blocking = sites.where(blocks).toSet();
    return blocking.length < sites.length ? blocking : <String>{};
  }

  static const _decisionKey = 'manga.bulkFill.decision';
  static const _baselineKey = 'manga.bulkFill.baseline';

  static (CoverFillDecision, int) decision([Preferences? defaults]) {
    final store = defaults ?? ContentPreferences.defaults;
    final name = store.string(_decisionKey);
    return (CoverFillDecision.values.where((value) => value.name == name).firstOrNull ?? CoverFillDecision.none, store.integer(_baselineKey));
  }

  /// Keeps the person's answer with the number of works waiting when they gave it.
  static void record(CoverFillDecision decision, int pending, [Preferences? defaults]) {
    final store = defaults ?? ContentPreferences.defaults;
    store.set(_decisionKey, decision.name);
    store.set(_baselineKey, pending);
  }

  static void forget([Preferences? defaults]) {
    final store = defaults ?? ContentPreferences.defaults;
    store.remove(_decisionKey);
    store.remove(_baselineKey);
  }

  /// Whether the fill may read now. A few works are read without asking; more are asked about,
  /// and asked about again when the person presses the fill button themselves or more works are
  /// waiting than when they last answered.
  static CoverFillOutcome outcome({
    required List<String> sites,
    bool Function(String site) blocks = blocksBulkReading,
    required int Function() pending,
    required bool manual,
    Preferences? defaults,
  }) {
    final blocking = sites.where(blocks).toList();
    if (blocking.isEmpty || blocking.length != sites.length) return const CoverFillRun();
    final waiting = pending();
    if (waiting <= quietLimit) return const CoverFillRun();
    var (decision, baseline) = CoverFillGuard.decision(defaults);
    // Filled works lower the mark, so works saved afterwards are measured from what is left.
    if (decision != CoverFillDecision.none && waiting < baseline) {
      baseline = waiting;
      record(decision, baseline, defaults);
    }
    final grew = waiting > baseline + quietLimit;
    return switch (decision) {
      CoverFillDecision.approved when !grew => const CoverFillRun(),
      CoverFillDecision.declined when !grew && !manual => const CoverFillHold(),
      _ => CoverFillAsk(waiting, blocking),
    };
  }
}

/// The device's thermal pressure, as `ProcessInfo.ThermalState` reports it.
enum DeviceThermalState { nominal, fair, serious, critical }

/// Filling covers waits while the device saves power or runs hot.
abstract final class CoverQueuePolicy {
  static bool allowsBackfillFor({required bool lowPowerMode, required DeviceThermalState thermalState}) {
    if (lowPowerMode) return false;
    return switch (thermalState) {
      DeviceThermalState.nominal || DeviceThermalState.fair => true,
      DeviceThermalState.serious || DeviceThermalState.critical => false,
    };
  }

  /// The current device state. Android reports neither through Flutter yet, so the app
  /// installs a reader of the platform's battery saver and thermal status when it has one.
  static bool Function() lowPowerMode = () => false;
  static DeviceThermalState Function() thermalState = () => DeviceThermalState.nominal;

  static bool get allowsBackfill => allowsBackfillFor(lowPowerMode: lowPowerMode(), thermalState: thermalState());
}

/// `CoverQueueState`: what the settings screen and the heat notice show about filling.
class CoverQueueState extends ChangeNotifier {
  bool isRunning = false;
  bool isPaused = false;
  int processed = 0;
  int failed = 0;
  int gone = 0;
  int total = 0;
  int remaining = 0;
  String? error;
  bool heatWarningDismissed = false;

  bool get showsHeatBanner => isRunning && total >= 100 && !heatWarningDismissed;

  /// Applies a change and tells listeners once.
  void update(void Function(CoverQueueState state) change) {
    change(this);
    notifyListeners();
  }
}

/// Reads a work's cover bytes; the app passes its page image store so the disk cache is shared.
typedef CoverThumbnailData = Future<Uint8List> Function(GalleryPage page, int galleryID);

/// `CoverQueueActor`: fills missing covers, titles and tags of saved works, a few at a time,
/// from the offline catalog first and then the connected website.
class CoverQueueActor {
  CoverQueueActor({
    required this.database,
    required this.thumbsDir,
    required this.source,
    CoverThumbnailData? thumbnailData,
    ContentProviding? Function(String site)? siteSource,
    bool Function()? allowsBackfill,
    this.delay = const Duration(milliseconds: 150),
    this.slowDelay = CoverFillGuard.slowDelay,
  }) : _thumbnailData = thumbnailData ?? ((page, galleryID) => source.image(page, galleryID: galleryID, thumbnail: true)),
       _siteSource = siteSource ?? ((site) => site != ComicSites.active && ComicSites.all.contains(site) ? SiteContent.of(site) : null),
       _allowsBackfill = allowsBackfill ?? (() => CoverQueuePolicy.allowsBackfill);

  final AppDatabase database;
  final Directory thumbsDir;
  final ContentProviding source;
  final Duration delay;
  final Duration slowDelay;
  final CoverThumbnailData _thumbnailData;

  /// Whether the last work was read from a website that blocks bulk reading, so the next waits longer.
  bool _readFromBlockingSite = false;

  /// Another connected website's reader, for a work saved from it: it may carry works the
  /// checked website lacks. Null reads the work from the checked website.
  final ContentProviding? Function(String site) _siteSource;
  final bool Function() _allowsBackfill;

  bool _checkedThumbnailFiles = false;
  bool _isRunning = false;
  bool _isPaused = false;
  bool _kickAgain = false;
  bool _cancelled = false;

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;

  /// Stops the current run after the work in progress, like cancelling its task.
  void cancel() => _cancelled = true;

  void _checkCancellation() {
    if (_cancelled) throw const CancellationError();
  }

  /// Queues every saved work so a fix in how a site is read reaches works saved before it.
  int queueRefresh() => database.queueRefresh();

  /// `mayRead` is asked before each batch: a run stops when works saved meanwhile would need the
  /// person's answer first.
  Future<void> start(CoverQueueState state, {bool downloadsEnabled = true, bool Function()? mayRead}) async {
    final reads = mayRead ?? () => true;
    _isPaused = false;
    if (_isRunning) {
      _kickAgain = true;
      return;
    }
    _isRunning = true;
    _cancelled = false;
    state.update((state) {
      state.isRunning = true;
      state.isPaused = false;
      state.processed = 0;
      state.failed = 0;
      state.gone = 0;
      state.error = null;
      if (state.remaining == 0) state.heatWarningDismissed = false;
      state.total = 0;
      state.remaining = 0;
    });

    try {
      if (!_checkedThumbnailFiles) {
        database.repairThumbnailReferences(thumbsDir);
        _checkedThumbnailFiles = true;
      }
      thumbsDir.createSync(recursive: true);
      final total = database.countPendingFill();
      state.update((state) {
        state.total = total;
        state.remaining = total;
        state.isRunning = downloadsEnabled && total > 0;
      });

      // Each work is tried once per run; a queued refresh that fails is tried again next run.
      final attempted = <int>{};
      // A website that has stopped answering this device ends the run: reading on would only
      // keep it blocked for longer.
      var refused = false;
      do {
        _kickAgain = false;
        while (downloadsEnabled && !refused && !_isPaused && !_cancelled && _allowsBackfill() && reads()) {
          final refresh = database.worksAwaitingRefresh(limit: 6, exclude: attempted);
          final batch = refresh.isEmpty ? database.worksNeedingFill(limit: 6, exclude: attempted).map((work) => work.galleryId).toList() : refresh;
          if (batch.isEmpty) break;
          final planned = attempted.length + database.countPendingFill(exclude: attempted);
          state.update((state) => state.total = state.total > planned ? state.total : planned);

          var stopped = false;
          for (final galleryId in batch) {
            if (_isPaused || _cancelled || !_allowsBackfill()) break;
            final refreshes = refresh.isNotEmpty;
            attempted.add(galleryId);

            try {
              await fetchOne(galleryId, refresh: refreshes);
              // A removed bookmark is not a successfully filled work. Tags may stay empty
              // only when the site itself lists none.
              final saved = database.getWork(galleryId);
              if (saved != null) {
                final tagged = (saved.tags ?? '').trim().isNotEmpty || saved.metadataSource == 'manga';
                if (!saved.hasThumb || !saved.hasTitle || !tagged) throw ContentError.invalidResponse;
                state.update((state) => state.processed += 1);
              }
              if (refreshes) database.finishRefresh(galleryId);
            } on CancellationError {
              stopped = true;
            } on NetworkError catch (error) {
              if (error.code == NetworkErrorCode.cancelled) {
                stopped = true;
              } else {
                _recordFailure(galleryId, state);
              }
            } on ContentError catch (error) {
              if (error.kind == ContentErrorKind.galleryNotFound) {
                // The website no longer has the work: nothing more to read.
                if (refreshes) database.finishRefresh(galleryId);
                state.update((state) => state.gone += 1);
              } else if (ContentError.refusesDevice(error)) {
                refused = true;
                state.update((state) {
                  state.failed += 1;
                  state.error = error.errorDescription;
                });
              } else {
                _recordFailure(galleryId, state);
              }
            } on Object {
              _recordFailure(galleryId, state);
            }
            if (stopped || refused) break;

            final remaining = database.countPendingFill();
            state.update((state) => state.remaining = remaining);
            // Politeness delay, longer after a website that blocks bulk reading
            final wait = _readFromBlockingSite ? slowDelay : delay;
            if (wait > Duration.zero) await Future<void>.delayed(wait);
            if (_cancelled) break;
          }
        }
      } while (downloadsEnabled && !refused && _kickAgain && !_isPaused && !_cancelled && _allowsBackfill() && reads());
    } on Object catch (error) {
      state.update((state) => state.error = error is ContentError ? error.errorDescription : '$error');
    }
    // Finish publishing before a replacement run can start.
    _isRunning = false;
    state.update((state) => state.isRunning = false);
  }

  void _recordFailure(int galleryId, CoverQueueState state) {
    state.update((state) => state.failed += 1);
    try {
      if (database.getWork(galleryId)?.hasThumb != true) database.setThumb(galleryId, 'failed');
    } on Object {
      // The count already reports the failure.
    }
  }

  Future<void> fetchOne(int galleryId, {bool refresh = false}) async {
    _readFromBlockingSite = false;
    _checkCancellation();
    var existing = database.getWork(galleryId);

    // If title or tags are missing, check the offline catalog first.
    if (existing == null || !existing.hasTitle || (existing.tags ?? '').isEmpty) {
      final catalog = database.getCatalog(galleryId);
      if (catalog != null) {
        database.upsertWork(
          galleryId: galleryId,
          title: catalog.title,
          artists: catalog.artists,
          language: catalog.language,
          type: catalog.type,
          series: catalog.series,
          groups: catalog.groups,
          tags: catalog.tags,
          publishedAt: catalog.published,
          metadataSource: 'catalog',
          catalogMatched: true,
          overwriteMetadata: false,
        );
        existing = database.getWork(galleryId);
      }
    }

    final needTitle = existing == null || !existing.hasTitle;
    final needCover = existing?.hasThumb != true;
    final needTags = (existing?.tags ?? '').trim().isEmpty;

    if (!refresh && !needTitle && !needCover && !needTags) {
      if (existing.thumbStatus != 'ready') database.setThumb(galleryId, 'ready', path: existing.thumbPath);
      return;
    }

    final site = existing?.site;
    final fallback = source is SiteFallbackContent ? source as SiteFallbackContent : null;
    // A saved work opens from whichever connected website still carries it, its own first.
    final other = site == null || fallback != null ? null : _siteSource(site);
    // Title, tags, page count and a first-page cover are what a card shows, which some websites
    // answer without opening the work; a cover chosen from a later page needs the work's pages.
    final firstPageCover = (existing?.thumbPage ?? 1) <= 1;
    final NativeGallery gallery;
    try {
      if (fallback != null) {
        // Every read from a website that blocks bulk reading, answered or not, waits longer
        // before the next.
        try {
          gallery = firstPageCover
              ? await fallback.preview(galleryId, preferring: site, inBulk: true)
              : await fallback.gallery(galleryId, preferring: site, inBulk: true);
        } finally {
          _readFromBlockingSite = fallback.tookBlockingRead(galleryId);
        }
      } else {
        final reader = other ?? source;
        gallery = firstPageCover ? await reader.preview(galleryId) : await reader.gallery(galleryId);
      }
    } on ContentError catch (error) {
      if (!error.isUnavailable(404) && !error.isUnavailable(410)) rethrow;
      _checkCancellation();
      // Only a missing gallery document means the work is gone. A 404 from an image
      // request below remains a retryable failure. A refresh keeps the cover it has.
      if (!refresh) database.setThumb(galleryId, 'gone');
      throw ContentError.galleryNotFound;
    }
    _checkCancellation();
    if (database.getWork(galleryId) == null) return;
    database.upsertWork(
      galleryId: galleryId,
      title: needTitle || refresh ? gallery.title : null,
      artists: gallery.artists.join(', '),
      language: gallery.language,
      type: gallery.type,
      tags: gallery.tags.join(', '),
      metadataSource: 'manga',
      pageCount: gallery.displayedPageCount,
    );
    if (needCover) {
      if (gallery.pages.isEmpty) throw ContentError.invalidResponse;
      final page = (existing?.thumbPage ?? 1).clamp(1, gallery.pages.length);
      final data = other == null
          ? await _thumbnailData(gallery.pages[page - 1], galleryId)
          : await other.image(gallery.pages[page - 1], galleryID: galleryId, thumbnail: true);
      _checkCancellation();
      if (database.getWork(galleryId) == null) return;
      thumbsDir.createSync(recursive: true);
      // The site's bytes are kept as they are; the name matches the native library's.
      final file = File('${thumbsDir.path}/native_$galleryId.jpg');
      final temporary = File('${file.path}.tmp');
      temporary.writeAsBytesSync(data, flush: true);
      if (!AppStorage.isReadableThumbnail(temporary)) {
        temporary.deleteSync();
        throw ContentError.unsupportedFormat;
      }
      temporary.renameSync(file.path);
      database.setThumb(galleryId, 'ready', path: file.path, page: page);
    }
  }
}

/// `AppEnvironment`'s cover queue driver: one run at a time, repeated when asked again
/// mid-run, paused while the app is in the background or the device needs to rest.
class CoverQueue {
  CoverQueue({
    required AppDatabase database,
    required ContentProviding source,
    Directory? thumbsDir,
    CoverThumbnailData? thumbnailData,
    bool Function()? isSiteVerified,
    bool Function()? allowsBackfill,
    Duration delay = const Duration(milliseconds: 150),
  }) : this.withActor(
         CoverQueueActor(
           database: database,
           thumbsDir: thumbsDir ?? AppStorage.thumbsDir,
           source: source,
           thumbnailData: thumbnailData,
           allowsBackfill: allowsBackfill,
           delay: delay,
         ),
         isSiteVerified: isSiteVerified,
         allowsBackfill: allowsBackfill,
       );

  CoverQueue.withActor(
    this.actor, {
    bool Function()? isSiteVerified,
    bool Function()? allowsBackfill,
    List<String> Function()? sites,
    bool Function(String site)? blocksBulkReading,
    this.decisions,
  }) : _isSiteVerified = isSiteVerified ?? (() => true),
       _allowsBackfill = allowsBackfill ?? (() => CoverQueuePolicy.allowsBackfill),
       _sites = sites ?? (() => ComicSites.all),
       _blocksBulkReading = blocksBulkReading ?? CoverFillGuard.blocksBulkReading;

  /// Offline fixtures and tests: nothing is fetched and nothing changes.
  factory CoverQueue.disabled({required AppDatabase database, required ContentProviding source}) => _DisabledCoverQueue(database: database, source: source);

  final CoverQueueActor actor;
  final state = CoverQueueState();
  final bool Function() _isSiteVerified;
  final bool Function() _allowsBackfill;
  final List<String> Function() _sites;
  final bool Function(String site) _blocksBulkReading;

  /// Where the person's answer is kept; the app's preferences unless a test passes its own.
  final Preferences? decisions;

  /// Asks the person before a fill reads many works from websites that block bulk reading; the
  /// app shows the question over whatever is on screen and answers with [answerBulkFill].
  void Function(int pending, List<String> sites)? askBeforeBulkFill;

  /// The question is on screen.
  bool asksBeforeBulkFill = false;

  Future<void>? _task;
  bool _active = true;
  bool _resume = false;
  bool _requested = false;

  /// The run in progress, for tests and for waiting before closing.
  Future<void>? get running => _task;

  /// `startCoverQueue`: fills whatever is missing, or runs again once the current run ends.
  /// `manual` is the fill button: it asks again even after the person said not now.
  void start({bool manual = false}) {
    if (!_active || !_allowsBackfill()) {
      _resume = true;
      return;
    }
    if (!_mayFillInBulk(manual: manual)) return;
    if (_task != null) {
      _requested = true;
      return;
    }
    late final Future<void> task;
    task = () async {
      try {
        do {
          _requested = false;
          await actor.start(state, downloadsEnabled: _isSiteVerified(), mayRead: () => _outcome(manual: false) is CoverFillRun);
        } while (_requested && _active && _allowsBackfill());
        if (!_allowsBackfill()) _resume = true;
        // Works saved during the run may have stopped it to ask first.
        if (_active) _mayFillInBulk(manual: false);
      } finally {
        if (identical(_task, task)) _task = null;
      }
    }();
    _task = task;
  }

  CoverFillOutcome _outcome({required bool manual}) =>
      CoverFillGuard.outcome(sites: _sites(), blocks: _blocksBulkReading, pending: actor.database.countPendingFill, manual: manual, defaults: decisions);

  /// Whether the fill may read now, asking first when every connected website blocks bulk
  /// reading and many works are waiting. Other websites, when connected, are read instead.
  bool _mayFillInBulk({required bool manual}) {
    if (!_isSiteVerified()) return true;
    switch (_outcome(manual: manual)) {
      case CoverFillRun():
        return true;
      case CoverFillHold():
        return false;
      case CoverFillAsk(:final pending, :final sites):
        final ask = askBeforeBulkFill;
        if (!asksBeforeBulkFill && ask != null) {
          asksBeforeBulkFill = true;
          ask(pending, sites);
        }
        return false;
    }
  }

  /// The person's answer to filling from a website that blocks bulk reading.
  void answerBulkFill(CoverFillDecision decision, int pending) {
    asksBeforeBulkFill = false;
    CoverFillGuard.record(decision, pending, decisions);
    if (decision == CoverFillDecision.approved) start();
  }

  /// `refreshSavedWorkInformation`: fetches every saved work's information again.
  void requestRefresh() {
    actor.queueRefresh();
    start();
  }

  /// The settings button: pause a running fill, resume a paused one, or start one.
  void toggle() {
    if (state.isRunning && !state.isPaused) {
      actor.pause();
      state.update((state) => state.isPaused = true);
    } else if (state.isRunning && state.isPaused) {
      actor.resume();
      state.update((state) => state.isPaused = false);
    } else {
      start(manual: true);
    }
  }

  /// A manual fill of one work, as the folder rule editor offers.
  Future<void> fetchOne(int galleryId) => actor.fetchOne(galleryId);

  /// `setCoverQueueActive`: follows the app's lifecycle and the selected mode.
  void setActive(bool active) {
    final allowed = active && _allowsBackfill();
    if (_active == allowed) return;
    _active = allowed;
    if (!allowed) {
      _resume = _resume || (_task != null && !state.isPaused);
      if (_task != null) actor.cancel();
    } else if (_resume) {
      _resume = false;
      start();
    }
  }
}

class _DisabledCoverQueue extends CoverQueue {
  _DisabledCoverQueue({required AppDatabase database, required ContentProviding source})
    : super.withActor(CoverQueueActor(database: database, thumbsDir: Directory.systemTemp, source: source, allowsBackfill: () => false));

  @override
  void start({bool manual = false}) {}
  @override
  void requestRefresh() {}
  @override
  void toggle() {}
  @override
  void setActive(bool active) {}
}
