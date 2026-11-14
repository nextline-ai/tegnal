import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/models.dart';
import '../storage/app_database.dart';
import '../storage/app_storage.dart';
import 'combined_catalog.dart';
import 'content_errors.dart';
import 'gallery_content.dart';
import 'manga_urls.dart';

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
  }) : _thumbnailData = thumbnailData ?? ((page, galleryID) => source.image(page, galleryID: galleryID, thumbnail: true)),
       _siteSource = siteSource ?? _connectedSite,
       _allowsBackfill = allowsBackfill ?? (() => CoverQueuePolicy.allowsBackfill);

  /// Another connected website's reader for works saved from it; null reads them from the
  /// checked one.
  static ContentProviding? _connectedSite(String site) {
    final active = ComicSites.active;
    if (site == active || !ComicSites.all.contains(site) || ComicSites.sharesNumbers(site, active)) return null;
    return SiteContent.of(site);
  }

  final AppDatabase database;
  final Directory thumbsDir;
  final ContentProviding source;
  final Duration delay;
  final CoverThumbnailData _thumbnailData;
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

  Future<void> start(CoverQueueState state, {bool downloadsEnabled = true}) async {
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
      do {
        _kickAgain = false;
        while (downloadsEnabled && !_isPaused && !_cancelled && _allowsBackfill()) {
          final refresh = database.worksAwaitingRefresh(limit: 6, exclude: attempted);
          final batch = refresh.isEmpty ? database.worksNeedingFill(limit: 6, exclude: attempted) : refresh;
          if (batch.isEmpty) break;
          final planned = attempted.length + database.countPendingFill(exclude: attempted);
          state.update((state) => state.total = state.total > planned ? state.total : planned);

          var stopped = false;
          for (final work in batch) {
            if (_isPaused || _cancelled || !_allowsBackfill()) break;
            final workId = work.id;
            if (workId == null) continue;
            final galleryId = work.galleryId, site = work.site;
            final refreshes = refresh.isNotEmpty;
            attempted.add(workId);

            try {
              await _fetch(work, refresh: refreshes);
              // A removed bookmark is not a successfully filled work. Tags may stay empty
              // only when the site itself lists none.
              final saved = database.getWork(galleryId, site: site);
              if (saved != null && saved.id == workId) {
                final tagged = (saved.tags ?? '').trim().isNotEmpty || saved.metadataSource == 'manga';
                if (!saved.hasThumb || !saved.hasTitle || !tagged) throw ContentError.invalidResponse;
                state.update((state) => state.processed += 1);
              }
              if (refreshes) database.finishRefresh(workId);
            } on CancellationError {
              stopped = true;
            } on NetworkError catch (error) {
              if (error.code == NetworkErrorCode.cancelled) {
                stopped = true;
              } else {
                _recordFailure(galleryId, site, state);
              }
            } on ContentError catch (error) {
              if (error.kind == ContentErrorKind.galleryNotFound) {
                // Gone, or a different work under the same number: nothing more to read.
                if (refreshes) database.finishRefresh(workId);
                state.update((state) => state.gone += 1);
              } else {
                _recordFailure(galleryId, site, state);
              }
            } on Object {
              _recordFailure(galleryId, site, state);
            }
            if (stopped) break;

            final remaining = database.countPendingFill();
            state.update((state) => state.remaining = remaining);
            // Politeness delay
            if (delay > Duration.zero) await Future<void>.delayed(delay);
            if (_cancelled) break;
          }
        }
      } while (downloadsEnabled && _kickAgain && !_isPaused && !_cancelled && _allowsBackfill());
    } on Object catch (error) {
      state.update((state) => state.error = error is ContentError ? error.errorDescription : '$error');
    }
    // Finish publishing before a replacement run can start.
    _isRunning = false;
    state.update((state) => state.isRunning = false);
  }

  void _recordFailure(int galleryId, String? site, CoverQueueState state) {
    state.update((state) => state.failed += 1);
    try {
      if (database.getWork(galleryId, site: site)?.hasThumb != true) database.setThumb(galleryId, 'failed', site: site);
    } on Object {
      // The count already reports the failure.
    }
  }

  /// Fills the saved work this number names on [site] (see `AppDatabase.getWork`).
  Future<void> fetchOne(int galleryId, {bool refresh = false, String? site}) async {
    final work = database.getWork(galleryId, site: site);
    if (work == null) return;
    await _fetch(work, refresh: refresh);
  }

  Future<void> _fetch(Work work, {required bool refresh}) async {
    _checkCancellation();
    final galleryId = work.galleryId, site = work.site, workId = work.id;
    var existing = database.getWork(galleryId, site: site);
    if (existing == null || existing.id != workId) return;

    // The offline catalog describes numbers whose website is unknown.
    if (site == null && (!existing.hasTitle || (existing.tags ?? '').isEmpty)) {
      final catalog = database.getCatalog(galleryId);
      if (catalog != null) {
        database.upsertWork(
          galleryId: galleryId,
          workId: workId,
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
        existing = database.getWork(galleryId, site: site);
      }
    }

    final needTitle = existing == null || !existing.hasTitle;
    final needCover = existing?.hasThumb != true;
    final needTags = (existing?.tags ?? '').trim().isEmpty;

    if (!refresh && !needTitle && !needCover && !needTags) {
      if (existing.thumbStatus != 'ready') database.setThumb(galleryId, 'ready', path: existing.thumbPath, site: site);
      return;
    }

    // A work saved from another connected website is read there.
    final other = site == null ? null : _siteSource(site);
    final reader = other ?? source;
    final NativeGallery gallery;
    try {
      gallery = await reader.gallery(galleryId);
    } on ContentError catch (error) {
      if (!error.isUnavailable(404) && !error.isUnavailable(410)) rethrow;
      _checkCancellation();
      // Only a missing gallery document means the work is gone. A 404 from an image
      // request below remains a retryable failure. A refresh keeps the cover it has.
      if (!refresh) database.setThumb(galleryId, 'gone', site: site);
      throw ContentError.galleryNotFound;
    }
    _checkCancellation();
    final saved = database.getWork(galleryId, site: site);
    if (saved == null || saved.id != workId) return;
    if (refresh && !isSameWork(saved, gallery)) throw ContentError.galleryNotFound;
    database.upsertWork(
      galleryId: galleryId,
      workId: workId,
      title: needTitle || refresh ? gallery.title : null,
      artists: gallery.artists.join(', '),
      language: gallery.language,
      type: gallery.type,
      tags: gallery.tags.join(', '),
      metadataSource: 'manga',
    );
    if (needCover) {
      if (gallery.pages.isEmpty) throw ContentError.invalidResponse;
      final page = (existing?.thumbPage ?? 1).clamp(1, gallery.pages.length);
      final cover = gallery.pages[page - 1];
      final data = other == null ? await _thumbnailData(cover, galleryId) : await other.image(cover, galleryID: galleryId, thumbnail: true);
      _checkCancellation();
      if (database.getWork(galleryId, site: site)?.id != workId) return;
      thumbsDir.createSync(recursive: true);
      // The site's bytes are kept as they are; the name matches the native library's.
      final file = File(database.thumbnailPath(galleryId, site, directory: thumbsDir));
      final temporary = File('${file.path}.tmp');
      temporary.writeAsBytesSync(data, flush: true);
      if (!AppStorage.isReadableThumbnail(temporary)) {
        temporary.deleteSync();
        throw ContentError.unsupportedFormat;
      }
      temporary.renameSync(file.path);
      database.setThumb(galleryId, 'ready', path: file.path, page: page, site: site);
    }
  }

  /// Saved numbers do not record their site, so a refresh leaves a work alone
  /// when the current site has a different work under the same number.
  static bool isSameWork(Work saved, NativeGallery gallery) {
    Set<String> names(Iterable<String> values) =>
        values.map((value) => value.toLowerCase().replaceAll('_', ' ').trim()).where((value) => value.isNotEmpty).toSet();
    final savedArtists = names((saved.artists ?? '').split(',')), artists = names(gallery.artists);
    if (savedArtists.isNotEmpty && artists.isNotEmpty) return savedArtists.intersection(artists).isNotEmpty;
    final language = (saved.language ?? '').toLowerCase();
    return ['', 'translated', 'rewrite'].contains(language) || gallery.language.isEmpty || language == gallery.language.toLowerCase();
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

  CoverQueue.withActor(this.actor, {bool Function()? isSiteVerified, bool Function()? allowsBackfill})
    : _isSiteVerified = isSiteVerified ?? (() => true),
      _allowsBackfill = allowsBackfill ?? (() => CoverQueuePolicy.allowsBackfill);

  /// Offline fixtures and tests: nothing is fetched and nothing changes.
  factory CoverQueue.disabled({required AppDatabase database, required ContentProviding source}) => _DisabledCoverQueue(database: database, source: source);

  final CoverQueueActor actor;
  final state = CoverQueueState();
  final bool Function() _isSiteVerified;
  final bool Function() _allowsBackfill;

  Future<void>? _task;
  bool _active = true;
  bool _resume = false;
  bool _requested = false;

  /// The run in progress, for tests and for waiting before closing.
  Future<void>? get running => _task;

  /// `startCoverQueue`: fills whatever is missing, or runs again once the current run ends.
  void start() {
    if (!_active || !_allowsBackfill()) {
      _resume = true;
      return;
    }
    if (_task != null) {
      _requested = true;
      return;
    }
    late final Future<void> task;
    task = () async {
      try {
        do {
          _requested = false;
          await actor.start(state, downloadsEnabled: _isSiteVerified());
        } while (_requested && _active && _allowsBackfill());
        if (!_allowsBackfill()) _resume = true;
      } finally {
        if (identical(_task, task)) _task = null;
      }
    }();
    _task = task;
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
      start();
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
  void start() {}
  @override
  void requestRefresh() {}
  @override
  void toggle() {}
  @override
  void setActive(bool active) {}
}
