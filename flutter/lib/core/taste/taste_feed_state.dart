import 'package:flutter/foundation.dart';

import '../content/manga_urls.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'recommendation_service.dart';
import 'taste_analyzer.dart';
import 'taste_controller.dart';
import 'taste_learning.dart';
import 'taste_models.dart';
import 'taste_store.dart';

class TasteShelf {
  TasteShelf({required this.plan, required this.items});
  final TasteShelfPlan plan;
  List<TasteRecommendation> items;
  String get id => plan.id;
}

/// A temporary lens over the feed. It never changes what the profile has learned.
class TasteFocus {
  const TasteFocus({required this.seed, required this.why});
  final TasteTag seed;
  final RecommendationWhy why;

  @override
  bool operator ==(Object other) => other is TasteFocus && other.seed.id == seed.id && other.why == why;
  @override
  int get hashCode => Object.hash(seed.id, why);
}

/// `TasteFeedState`: owned by the app, independently of screen lifetimes. Only an explicit
/// refresh replaces an existing feed; pagination appends without changing its order.
class TasteFeedState extends ChangeNotifier {
  TasteFeedState({required this.controller, this.source, List<String>? sources}) : sourceAddresses = sources ?? (source == null ? null : [source]);

  final TasteController controller;
  final String? source;
  final List<String>? sourceAddresses;

  String discoverySession = uuidString();
  bool initialized = false;
  bool loading = false;
  bool loadingMore = false;
  TasteSnapshot? snapshot;
  TasteReport? report;
  TasteRecommendations results = TasteRecommendations();
  String? error;
  String? sortMessage;
  int pageVersion = 0;
  TasteLearning? learning;
  List<TasteShelf> shelves = [];
  TasteFocus? focus;
  bool starter = false;
  TasteRecommendation? lastDismissed;
  ({int? deck, String? shelf, int index})? _dismissedPosition;
  TasteFocus? _appliedFocus;
  Map<String, List<TasteTag>>? _activeSeeds;
  Map<String, RecommendationPreferences>? _activePreferences;
  int _generation = 0;
  List<String> _shown = [];
  int _seedOffset = -1;
  Map<String, RecommendationPreferences>? _appliedPreferences;
  Map<String, RecommendationSort> _previousSorts = {};
  Future<void>? _work;
  Future<void>? _shelfWork;

  TasteEnvironment get _env => controller.environment;

  void _remember(List<TasteRecommendation> items) {
    final ids = items.map((item) => item.id).toSet();
    _shown
      ..removeWhere(ids.contains)
      ..addAll(items.map((item) => item.id));
    if (_shown.length > 2000) _shown = _shown.sublist(_shown.length - 2000);
  }

  /// Session access changes without replacing the deck, cursor or saved evidence.
  List<TasteRecommendation> visibleItems() {
    final hidden = controller.images.confirmedGoldRestrictedIDs;
    return hidden.isEmpty ? results.items : results.items.where((item) => item.post == null || !hidden.contains(item.post!.id)).toList();
  }

  List<TasteShelf> visibleShelves() {
    final hidden = controller.images.confirmedGoldRestrictedIDs;
    if (hidden.isEmpty) return shelves;
    return [
      for (final shelf in shelves)
        TasteShelf(plan: shelf.plan, items: shelf.items.where((item) => item.post == null || !hidden.contains(item.post!.id)).toList()),
    ];
  }

  List<TasteRecommendation> picks({int count = 3}) => TasteRecommendation.picks(visibleItems(), count: count);

  /// "Not interested" leaves at once and teaches the next refresh; undo is exact.
  void dismiss(TasteRecommendation item, TasteMode mode) {
    try {
      controller.store(mode).recordSignal(TasteSignal.dismissed, item.item);
    } on Object {
      // The card still leaves; the signal is best effort.
    }
    lastDismissed = item;
    final deck = results.items.indexWhere((candidate) => candidate.id == item.id);
    String? shelfID;
    var position = 0;
    results.items.removeWhere((candidate) => candidate.id == item.id);
    for (final shelf in shelves) {
      final index = shelf.items.indexWhere((candidate) => candidate.id == item.id);
      if (index >= 0) {
        shelfID = shelf.id;
        position = index;
        shelf.items.removeAt(index);
      }
    }
    _dismissedPosition = (deck: deck < 0 ? null : deck, shelf: shelfID, index: position);
    pageVersion += 1;
    notifyListeners();
  }

  void undoDismiss(TasteMode mode) {
    final item = lastDismissed;
    if (item == null) return;
    try {
      controller.store(mode).recordSignal(TasteSignal.restored, item.item);
    } on Object {
      // Restoring the card does not depend on the signal.
    }
    final position = _dismissedPosition;
    if (position?.deck case final deck?) results.items.insert(deck.clamp(0, results.items.length), item);
    if (position?.shelf case final shelfID?) {
      final shelf = shelves.where((shelf) => shelf.id == shelfID).firstOrNull;
      shelf?.items.insert(position!.index.clamp(0, shelf.items.length), item);
    }
    lastDismissed = null;
    _dismissedPosition = null;
    pageVersion += 1;
    notifyListeners();
  }

  void clearUndo() {
    lastDismissed = null;
    _dismissedPosition = null;
    notifyListeners();
  }

  void setFocus(TasteFocus? value, TasteMode mode) {
    if (value == focus) return;
    focus = value;
    refresh(mode);
  }

  void ensureLoaded(TasteMode mode) {
    if (initialized || !controller.control.enabled) return;
    refresh(mode);
  }

  void clear() {
    cancelLoading();
    snapshot = null;
    report = null;
    results = TasteRecommendations();
    error = null;
    sortMessage = null;
    _appliedPreferences = null;
    _previousSorts = {};
    learning = null;
    shelves = [];
    focus = null;
    _appliedFocus = null;
    _activeSeeds = null;
    _activePreferences = null;
    starter = false;
    lastDismissed = null;
    loading = false;
    loadingMore = false;
    initialized = false;
    _shown = [];
    _seedOffset = -1;
    notifyListeners();
  }

  void cancelLoading() {
    _generation += 1;
    loading = false;
    loadingMore = false;
    if (snapshot == null) initialized = false;
  }

  void applyExclusions(TasteControl control, TasteMode mode) {
    cancelLoading();
    final filtered = snapshot?.copy();
    if (filtered != null) {
      filtered.tags.removeWhere((tag) => !control.allows(tag.name, source: tag.source, mode: mode));
      filtered.previousTagCounts.removeWhere((key, _) {
        final parts = key.split('\n');
        return parts.length != 2 || !control.allows(parts[1], source: parts[0], mode: mode);
      });
      snapshot = filtered;
    }
    final allowed = {...?snapshot?.tags.map((tag) => tag.id)};
    report?.insights.removeWhere((insight) => !allowed.contains(insight.tagKey));
    notifyListeners();
  }

  List<String> _addresses(TasteMode mode) =>
      mode == TasteMode.comics ? [MangaUrls.source] : sourceAddresses ?? _env.booru.selectedServers.map((server) => server.canonicalAddress).toList();

  void refresh(TasteMode mode) {
    if (!controller.control.enabled || (mode == TasteMode.booru && _addresses(mode).isEmpty)) return;
    final token = ++_generation;
    discoverySession = uuidString();
    _seedOffset += 1;
    final selection = _seedOffset;
    initialized = true;
    loading = true;
    loadingMore = false;
    error = null;
    notifyListeners();
    _work = _refresh(mode, token, selection);
  }

  Future<void> _refresh(TasteMode mode, int token, int selection) async {
    try {
      final value = controller.snapshot(mode, period: TastePeriod.recommendations, offset: 0).copy();
      if (_generation != token) return;
      final addresses = _addresses(mode);
      value.tags.removeWhere((tag) => !addresses.contains(tag.source));
      final control = controller.control;
      final preferences = {for (final address in addresses) address: control.preferences(address)};
      final wanted = focus;
      final preferencesChanged = !mapEquals(_appliedPreferences, preferences) || _appliedFocus != wanted;
      TasteLearning? model;
      try {
        model = controller.learning(mode);
      } on Object {
        model = null;
      }
      if (_generation != token) return;
      // Nothing learned yet: open with what is popular rather than an empty page.
      final cold = value.tags.isEmpty && wanted == null;
      final seeds = wanted != null
          ? {
              wanted.seed.source: [wanted.seed],
            }
          : (cold
                ? {
                    for (final address in addresses) address: [TasteTag(source: address, name: '')],
                  }
                : null);
      final effective = cold
          ? preferences.map((key, value) => MapEntry(key, value.copy()..sort = RecommendationSort.week))
          : (wanted == null ? preferences : preferences.map((key, value) => MapEntry(key, value.copy()..sort = RecommendationSort.recommended)));
      final whyOverride = wanted?.why ?? (cold ? const WhyPopular() : null);
      final explanation = StatisticalInsightService.report(snapshot: value, control: control, language: L10n.language, selectionOffset: selection);
      var batch = TasteRecommendations(cursor: preferencesChanged ? RecommendationCursor() : results.cursor.copy());
      final viewed = model?.seen ?? const <String>{};
      var excluded = {...(preferencesChanged ? const <String>{} : _shown.toSet()), ...viewed};
      // Continue the deck before starting another cycle. On wrap, prefer
      // works outside the currently visible page; only a depleted deck repeats.
      for (var cycle = 0; cycle < 3; cycle++) {
        for (var attempt = 0; attempt < 3; attempt++) {
          batch = await RecommendationService.load(
            mode: mode,
            snapshot: value,
            report: explanation,
            env: _env,
            sourceAddress: source,
            sourceAddresses: sourceAddresses,
            preferencesOverride: effective,
            cursor: batch.cursor,
            excluding: excluded,
            shuffled: true,
            seedOffset: selection,
            learning: model,
            seedOverride: seeds,
            whyOverride: whyOverride,
            cancelled: () => _generation != token,
          );
          if (_generation != token) return;
          if (batch.unsupportedSort || batch.items.isNotEmpty || !batch.cursor.hasMore || batch.failures.isNotEmpty) break;
        }
        if (batch.unsupportedSort || batch.items.isNotEmpty || batch.cursor.hasMore || batch.failures.isNotEmpty || cycle == 2) break;
        batch.cursor = RecommendationCursor();
        excluded = cycle == 0 ? {...results.items.map((item) => item.id), ...viewed} : {};
      }
      if (_generation != token || !controller.control.enabled) return;
      if (batch.unsupportedSort) {
        controller.change((control) {
          for (final address in batch.unsupportedSources) {
            final reverted = (preferences[address] ?? RecommendationPreferences()).copy()
              ..sort = _appliedPreferences?[address]?.sort ?? RecommendationSort.recommended;
            control.setPreferences(reverted, address);
          }
        });
        sortMessage = L10n.text('This server does not support that sort. Your previous sort has been restored.');
        loading = false;
        notifyListeners();
        if (snapshot == null) refresh(mode);
        return;
      }
      for (final entry in preferences.entries) {
        if (entry.value.sort != _appliedPreferences?[entry.key]?.sort) {
          _previousSorts[entry.key] = _appliedPreferences?[entry.key]?.sort ?? RecommendationSort.recommended;
        }
      }
      _appliedPreferences = preferences;
      _appliedFocus = wanted;
      _activeSeeds = seeds;
      _activePreferences = effective;
      learning = model;
      starter = cold;
      lastDismissed = null;
      if (cold) batch.failures = [];
      if (preferencesChanged) _shown = [];
      final recommended = preferences.values.every((value) => value.sort == RecommendationSort.recommended);
      if (recommended && batch.items.length > 1 && listEquals(batch.items.map((item) => item.id).toList(), results.items.map((item) => item.id).toList())) {
        batch.items.add(batch.items.removeAt(0));
      }
      snapshot = value;
      report = explanation;
      results = batch;
      _remember(batch.items);
      pageVersion += 1;
      loading = false;
      if (model != null && wanted == null && !cold && recommended) {
        _shelfWork = _loadShelves(model, mode, addresses, value, preferences, selection, token);
      } else {
        shelves = [];
      }
      notifyListeners();
    } on Object {
      if (_generation == token) {
        error = L10n.text('Unable to update taste analysis.');
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> waitForRefresh() async => _work;
  Future<void> waitForShelves() async => _shelfWork;

  /// Filled after the main deck so a slow shelf can never hold the page. Requests
  /// stay bounded, and a shelf that finds too little simply does not appear.
  Future<void> _loadShelves(
    TasteLearning model,
    TasteMode mode,
    List<String> addresses,
    TasteSnapshot snapshot,
    Map<String, RecommendationPreferences> preferences,
    int selection,
    int token,
  ) async {
    final slow = mode == TasteMode.booru && _env.booru.servers.any((server) => addresses.contains(server.canonicalAddress) && server.engine.usesGelbooruPages);
    final plans = model.shelves(sources: addresses, tags: snapshot.tags, offset: selection, limit: slow ? 2 : 4);
    final keepsCurrent = setEquals(plans.map((plan) => plan.id).toSet(), shelves.map((shelf) => shelf.id).toSet());
    if (!keepsCurrent) shelves = [];
    final used = {...results.items.take(16).map((item) => item.id), ...model.seen};
    final built = <TasteShelf>[];
    for (final plan in plans) {
      if (_generation != token) return;
      final scoped = {
        for (final entry in preferences.entries)
          entry.key: entry.key == plan.source ? (entry.value.copy()..sort = RecommendationSort.recommended) : entry.value,
      };
      TasteRecommendations batch;
      try {
        batch = await RecommendationService.load(
          mode: mode,
          snapshot: snapshot,
          env: _env,
          sourceAddresses: [plan.source],
          preferencesOverride: scoped,
          excluding: used,
          shuffled: true,
          seedOffset: selection,
          requestTimeout: 15,
          learning: model,
          seedOverride: {
            plan.source: [plan.seed],
          },
          whyOverride: plan.why,
          cancelled: () => _generation != token,
        );
      } on Object {
        continue;
      }
      if (_generation != token) return;
      final items = batch.items.take(12).toList();
      if (items.length < 3) continue;
      used.addAll(items.map((item) => item.id));
      _remember(items);
      built.add(TasteShelf(plan: plan, items: items));
      shelves = [...built];
      notifyListeners();
    }
    if (built.isEmpty) {
      shelves = [];
      notifyListeners();
    }
  }

  Future<void> loadMore(TasteMode mode) async {
    final snapshot = this.snapshot;
    if (loading || loadingMore || !results.cursor.hasMore || snapshot == null || !controller.control.enabled) return;
    loadingMore = true;
    notifyListeners();
    final token = _generation, selection = _seedOffset;
    try {
      var next = results.cursor;
      var added = <TasteRecommendation>[];
      var failures = <String>[];
      // Skip a bounded number of pages containing only saved or filtered works.
      for (var attempt = 0; attempt < 3; attempt++) {
        final batch = await RecommendationService.load(
          mode: mode,
          snapshot: snapshot,
          report: report,
          env: _env,
          sourceAddress: source,
          sourceAddresses: sourceAddresses,
          preferencesOverride: _activePreferences ?? _appliedPreferences,
          cursor: next,
          excluding: {..._shown, ...results.items.map((item) => item.id), ...?learning?.seen},
          shuffled: true,
          seedOffset: selection,
          learning: learning,
          seedOverride: _activeSeeds,
          whyOverride: focus?.why ?? (starter ? const WhyPopular() : null),
          cancelled: () => _generation != token,
        );
        if (token != _generation || !controller.control.enabled) return;
        if (batch.unsupportedSort) {
          controller.change((control) {
            for (final address in batch.unsupportedSources) {
              control.setPreferences(control.preferences(address)..sort = _previousSorts[address] ?? RecommendationSort.recommended, address);
            }
          });
          sortMessage = L10n.text('This server does not support that sort. Your previous sort has been restored.');
          results.cursor.hasMore = false;
          return;
        }
        next = batch.cursor;
        added = batch.items;
        failures = batch.failures;
        if (added.isNotEmpty || !next.hasMore || failures.isNotEmpty) break;
      }
      _remember(added);
      results.items.addAll(added);
      results.cursor = next;
      results.failures = failures;
      if (added.isNotEmpty) pageVersion += 1;
    } on Object {
      if (_generation == token) error = L10n.text('Unable to update taste analysis.');
    } finally {
      if (token == _generation) loadingMore = false;
      notifyListeners();
    }
  }
}
