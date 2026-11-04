import 'package:flutter/foundation.dart';

import '../booru/booru_client.dart';
import '../booru/booru_store.dart';
import '../content/content_environment.dart';
import '../content/gallery_content.dart';
import '../storage/app_database.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'recommendation_service.dart';
import 'taste_analyzer.dart';
import 'taste_feed_state.dart';
import 'taste_learning.dart';
import 'taste_library.dart';
import 'taste_models.dart';
import 'taste_recap.dart';
import 'taste_store.dart';
import 'taste_sync.dart';

/// `TasteController`: the taste settings shared by both libraries, each mode's analysis
/// store, the recommendation feeds, and the monthly recap prompt.
class TasteController extends ChangeNotifier {
  TasteController({
    required this.library,
    required this.images,
    required ContentEnvironment content,
    required BooruProviding booruSource,
    required ContentProviding comicSource,
    String Function(String query)? booruQuery,
    Set<int> Function()? hiddenComics,
    TasteSyncBackend? syncBackend,
  }) : comics = library.tasteStore,
       booru = images.tasteStore,
       _hiddenComics = hiddenComics ?? (() => content.hiddenMangaGalleryIDs),
       cloud = TasteSyncCoordinator(backend: syncBackend) {
    environment = TasteEnvironment(
      control: () => control,
      booru: images,
      database: library,
      content: content,
      booruSource: booruSource,
      comicSource: comicSource,
      booruQuery: booruQuery,
    );
    try {
      control = comics.control();
      booru.setControl(control);
    } on Object {
      error = L10n.text('Unable to update taste analysis.');
    }
    imageFeed = TasteFeedState(controller: this);
    comicFeed = TasteFeedState(controller: this);
  }

  final AppDatabase library;
  final BooruStore images;
  final TasteStore comics;
  final TasteStore booru;
  final TasteSyncCoordinator cloud;
  final Set<int> Function() _hiddenComics;
  late final TasteEnvironment environment;
  late final TasteFeedState imageFeed;
  late final TasteFeedState comicFeed;
  final _serverFeeds = <String, TasteFeedState>{};
  final _cache = TasteAnalysisCache();
  TasteControl control = TasteControl();
  int revision = 0;
  String? error;
  final monthlyRecaps = <TasteMode, DateTime>{};
  final dismissedRecaps = <TasteMode, String>{};
  bool _bootstrapped = false;

  TasteStore store(TasteMode mode) => mode == TasteMode.booru ? booru : comics;

  TasteFeedState feed(TasteMode mode, {String? source, List<String>? sources}) {
    if (mode != TasteMode.booru) return comicFeed;
    if (source == null && sources == null) return imageFeed;
    final key = source ?? ([...sources!]..sort()).join('\n');
    return _serverFeeds[key] ??= TasteFeedState(controller: this, source: source, sources: sources);
  }

  /// Seeds both histories from the libraries once, so a first visit has a profile.
  void bootstrap() {
    if (!control.enabled || _bootstrapped) return;
    try {
      if (comics.metadata('bootstrapped') != true) comics.bootstrap(library.tasteLibrary());
      if (booru.metadata('bootstrapped') != true) booru.bootstrap(images.tasteLibrary());
      // A pause can make either store decline bootstrap. Do not latch success until both committed it.
      _bootstrapped = comics.metadata('bootstrapped') == true && booru.metadata('bootstrapped') == true;
    } on Object {
      error = L10n.text('Unable to update taste analysis.');
      notifyListeners();
    }
  }

  void change(void Function(TasteControl control) update) {
    final next = control.copy();
    update(next);
    final now = unixSeconds();
    next
      ..timestamp = now > control.timestamp + 0.000001 ? now : control.timestamp + 0.000001
      ..author = comics.metadata('device') as String? ?? uuidString();
    if (next.enabled != control.enabled) {
      next
        ..generation = uuidString()
        ..enabledTimestamp = next.timestamp
        ..enabledAuthor = next.author;
    }
    if (next.epoch != control.epoch) {
      next
        ..resetTimestamp = next.timestamp
        ..resetAuthor = next.author;
    }
    apply(next, remote: false);
  }

  void apply(TasteControl next, {required bool remote}) {
    try {
      comics.setControl(next, remote: remote);
      booru.setControl(next, remote: remote);
      if (next.epoch != control.epoch || !next.enabled) {
        imageFeed.clear();
        comicFeed.clear();
        for (final feed in _serverFeeds.values) {
          feed.clear();
        }
        monthlyRecaps.clear();
      }
      for (final mode in TasteMode.values) {
        if (!setEquals(next.analysisExcludedFor(mode), control.analysisExcludedFor(mode)) || !setEquals(next.excluded, control.excluded)) {
          feed(mode).applyExclusions(next, mode);
        }
      }
      if (encodeJsonString(next.sourceAnalysisExclusions) != encodeJsonString(control.sourceAnalysisExclusions) ||
          encodeJsonString(next.analysisExclusions) != encodeJsonString(control.analysisExclusions) ||
          !setEquals(next.excluded, control.excluded)) {
        for (final feed in _serverFeeds.values) {
          feed.applyExclusions(next, TasteMode.booru);
        }
        comicFeed.applyExclusions(next, TasteMode.comics);
      }
      control = next;
      revision += 1;
      _cache.invalidate();
    } on Object {
      error = L10n.text('Unable to update taste analysis.');
    }
    notifyListeners();
  }

  void reset() {
    change((control) {
      control
        ..epoch = uuidString()
        ..tasteBoosts = null
        ..discoveryLevel = null;
    });
    cloud.deletionPending();
  }

  /// Personal activity never crosses accounts; the libraries remain intact.
  void rebindAccount() {
    final fresh = TasteControl(enabled: control.enabled);
    for (final store in [comics, booru]) {
      store.database.write((db) {
        db.execute('DELETE FROM taste_events');
        db.execute('DELETE FROM taste_reports');
        db.execute("DELETE FROM taste_meta WHERE key != 'device'");
        TasteStore.put(true, key: 'bootstrapped', db: db);
        TasteStore.put(fresh.toJson(), key: 'control', db: db);
      });
    }
    imageFeed.clear();
    comicFeed.clear();
    for (final feed in _serverFeeds.values) {
      feed.clear();
    }
    monthlyRecaps.clear();
    dismissedRecaps.clear();
    control = fresh;
    revision += 1;
    _cache.invalidate();
    notifyListeners();
  }

  void exclude(TasteTag tag) => change((control) => control.excluded.add(tag.id));

  TasteSnapshot snapshot(TasteMode mode, {required TastePeriod period, required int offset, DateTime? now}) {
    bootstrap();
    final clock = now ?? DateTime.now();
    final interval = period.interval(offset: offset, now: clock, timeZone: control.timeZone);
    final previous = offset < 0 ? period.interval(offset: offset - 1, now: clock, timeZone: control.timeZone) : null;
    final store = this.store(mode);
    // Historical activity does not depend on the current library.
    final keys = interval == null ? store.savedKeys() : null;
    return _cache.snapshot(store, control, period: interval, previous: previous, savedKeys: keys);
  }

  RecapIndex recapIndex(TasteMode mode) {
    bootstrap();
    final works = mode == TasteMode.booru ? images.recapLibrary() : library.recapLibrary(hidden: _hiddenComics());
    return _cache.recapIndex(store(mode), control, works);
  }

  TasteLearning learning(TasteMode mode, {DateTime? now}) => TasteLearning(index: recapIndex(mode), control: control, now: now);

  /// No cloud is offered on Android yet; this keeps the native entry point.
  Future<void> synchronize() async {
    bootstrap();
    await cloud.synchronize(this);
  }

  String recapKey(DateTime date) => '${control.epoch}:${(date.microsecondsSinceEpoch / 1e6).floor()}';

  DateTime? pendingRecap(TasteMode mode) {
    final date = monthlyRecaps[mode];
    if (!control.enabled || date == null || dismissedRecaps[mode] == recapKey(date)) return null;
    return date;
  }

  void dismissRecap(TasteMode mode) {
    final date = monthlyRecaps[mode];
    if (date == null) return;
    final key = recapKey(date);
    try {
      store(mode).setMetadata(key, 'dismissedRecap');
      dismissedRecaps[mode] = key;
    } on Object {
      error = L10n.text('Unable to update taste analysis.');
    }
    notifyListeners();
  }

  /// Last week's and month's reports are written ahead, and last month's recap is offered.
  void prepareCompletedReports({DateTime? now}) {
    if (!control.enabled) return;
    for (final mode in const [TasteMode.booru, TasteMode.comics]) {
      for (final period in const [TastePeriod.month, TastePeriod.week]) {
        try {
          final captured = control;
          final snapshot = this.snapshot(mode, period: period, offset: -1, now: now);
          if (!control.enabled || control.epoch != captured.epoch) return;
          final start = snapshot.period?.start;
          if (period == TastePeriod.month && snapshot.saves > 0 && start != null) {
            monthlyRecaps[mode] = start;
            final dismissed = store(mode).metadata('dismissedRecap');
            if (dismissed is String) dismissedRecaps[mode] = dismissed;
          }
          if (snapshot.tags.isEmpty) continue;
          final cached = store(mode).report(digest: snapshot.digest, language: L10n.language, epoch: captured.epoch);
          if (cached?.isValid(snapshot) ?? false) continue;
          store(mode).saveReport(StatisticalInsightService.report(snapshot: snapshot, control: captured, language: L10n.language));
        } on Object {
          error = L10n.text('Unable to update taste analysis.');
        }
      }
    }
    notifyListeners();
  }
}
