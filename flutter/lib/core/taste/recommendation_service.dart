import 'dart:async';
import 'dart:math' as math;

import '../booru/booru_client.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../content/content_environment.dart';
import '../content/content_errors.dart';
import '../content/gallery_content.dart';
import '../content/manga_urls.dart';
import '../storage/app_database.dart';
import 'taste_analyzer.dart';
import 'taste_learning.dart';
import 'taste_models.dart';

class TasteRecommendation {
  TasteRecommendation({
    required this.item,
    this.post,
    this.gallery,
    required this.reason,
    required this.score,
    this.rankingTags,
    this.why,
    List<RecommendationFactor>? factors,
    this.novel = false,
  }) : factors = factors ?? [];

  final TasteItem item;
  final BooruPost? post;
  final NativeGallery? gallery;
  final TasteTag reason;
  double score;
  Set<String>? rankingTags;
  RecommendationWhy? why;
  List<RecommendationFactor> factors;
  bool novel;
  String get id => item.key;

  TasteRecommendation copy() => TasteRecommendation(
    item: item,
    post: post,
    gallery: gallery,
    reason: reason,
    score: score,
    rankingTags: rankingTags,
    why: why,
    factors: [...factors],
    novel: novel,
  );

  bool get reachesOut => novel || reason.discovery || why is WhyComeback;

  /// Three works that can fail independently: something current, something
  /// from long-standing taste and something new, never on one shared reason.
  static List<TasteRecommendation> picks(List<TasteRecommendation> items, {int count = 3}) {
    final chosen = <TasteRecommendation>[];
    final reasons = <String>{};
    void take(bool Function(TasteRecommendation item) matches) {
      if (chosen.length >= count) return;
      final item = items
          .where((candidate) => matches(candidate) && !reasons.contains(candidate.reason.name) && !chosen.any((other) => other.id == candidate.id))
          .firstOrNull;
      if (item == null) return;
      chosen.add(item);
      reasons.add(item.reason.name);
    }

    take((item) => item.why is WhyRecent || item.why is WhyPerson);
    take((item) => !item.reachesOut);
    take((item) => item.reachesOut);
    while (chosen.length < count) {
      final before = chosen.length;
      take((_) => true);
      if (chosen.length == before) {
        reasons.clear();
        take((_) => true);
      }
      if (chosen.length == before) break;
    }
    return chosen;
  }
}

class RecommendationCursor {
  RecommendationCursor({
    Map<String, int>? pages,
    Set<String>? finished,
    Map<String, String>? fingerprints,
    Map<String, List<BooruPost>>? pendingPosts,
    this.hasMore = true,
  }) : pages = pages ?? {},
       finished = finished ?? {},
       fingerprints = fingerprints ?? {},
       pendingPosts = pendingPosts ?? {};
  Map<String, int> pages;
  Set<String> finished;
  Map<String, String> fingerprints;
  Map<String, List<BooruPost>> pendingPosts;
  bool hasMore;

  RecommendationCursor copy() => RecommendationCursor(
    pages: {...pages},
    finished: {...finished},
    fingerprints: {...fingerprints},
    pendingPosts: {
      for (final entry in pendingPosts.entries) entry.key: [...entry.value],
    },
    hasMore: hasMore,
  );
}

class TasteRecommendations {
  TasteRecommendations({
    List<TasteRecommendation>? items,
    List<String>? failures,
    this.unsupportedSort = false,
    Set<String>? unsupportedSources,
    RecommendationCursor? cursor,
  }) : items = items ?? [],
       failures = failures ?? [],
       unsupportedSources = unsupportedSources ?? {},
       cursor = cursor ?? RecommendationCursor();
  List<TasteRecommendation> items;
  List<String> failures;
  bool unsupportedSort;
  Set<String> unsupportedSources;
  RecommendationCursor cursor;
}

/// What recommendations read from the app: both libraries, the taste settings and
/// the content sources. The app builds one; tests build their own.
class TasteEnvironment {
  TasteEnvironment({
    required this.control,
    required this.booru,
    required this.database,
    required this.content,
    required this.booruSource,
    required this.comicSource,
    String Function(String query)? booruQuery,
  }) : booruQuery = booruQuery ?? ((query) => query);

  /// The current taste settings; read each time because they change.
  final TasteControl Function() control;
  final BooruStore booru;
  final AppDatabase database;
  final ContentEnvironment content;
  final BooruProviding booruSource;
  final ContentProviding comicSource;

  /// `booruQuery`: Safe Mode's rating tag added to image searches.
  final String Function(String query) booruQuery;
}

abstract final class RecommendationService {
  static double score(TasteItem item, List<TasteTag> tags, {Set<String> ignoring = const {}}) =>
      ScoringProfile(item.source, tags).score(item, ignoring: ignoring);

  static List<TasteRecommendation> mix(
    List<TasteRecommendation> candidates, {
    int limit = 20,
    bool shuffled = false,
    int discoverySlots = 3,
    math.Random? random,
  }) {
    final sorted = [...candidates]..sort((a, b) => a.score == b.score ? a.id.compareTo(b.id) : b.score.compareTo(a.score));
    final seen = <String>{};
    final unique = sorted.where((item) => seen.add(item.id)).toList();
    // Maximal marginal relevance discourages near-duplicate tag combinations.
    // Small jitter varies equally useful choices without discarding relevance.
    final rankingTags = {for (final item in unique) item.id: item.rankingTags ?? item.item.eligibleTags.toSet()};
    final remaining = [...unique];
    final generator = random ?? math.Random();
    final jitter = {for (final item in unique) item.id: shuffled ? 0.9 + generator.nextDouble() * 0.2 : 1.0};
    final result = <TasteRecommendation>[];
    final maximum = math.max(0.001, unique.isEmpty ? 1.0 : unique.map((item) => item.score).reduce(math.max));
    while (remaining.isNotEmpty && result.length < limit) {
      final wantDiscovery = result.length % 10 >= 10 - discoverySlots;
      final eligible = remaining.where((item) => (item.reason.discovery || item.novel) == wantDiscovery).toList();
      final pool = eligible.isEmpty ? remaining : eligible;
      double utility(TasteRecommendation candidate) {
        final tags = rankingTags[candidate.id] ?? const <String>{};
        var overlap = 0.0;
        for (final other in result.skip(math.max(0, result.length - 8))) {
          if (other.item.source != candidate.item.source) continue;
          final theirs = rankingTags[other.id] ?? const <String>{};
          final intersection = tags.where(theirs.contains).length;
          overlap = math.max(overlap, intersection / math.max(1, tags.length + theirs.length - intersection));
        }
        return 0.8 * candidate.score / maximum * (jitter[candidate.id] ?? 1) - 0.2 * overlap;
      }

      TasteRecommendation? next;
      var best = double.negativeInfinity;
      for (final candidate in pool) {
        final value = utility(candidate);
        if (next == null || value > best) {
          next = candidate;
          best = value;
        }
      }
      if (next == null) break;
      result.add(next);
      final chosen = next;
      remaining.removeWhere((item) => item.id == chosen.id);
    }
    return result;
  }

  static Future<T> _deadline<T>(double seconds, Future<T> Function() operation) =>
      operation().timeout(Duration(milliseconds: (seconds * 1000).round()), onTimeout: () => throw const NetworkError(NetworkErrorCode.timedOut));

  static Future<TasteRecommendations> load({
    required TasteMode mode,
    required TasteSnapshot snapshot,
    TasteReport? report,
    required TasteEnvironment env,
    String? sourceAddress,
    List<String>? sourceAddresses,
    Map<String, RecommendationPreferences>? preferencesOverride,
    RecommendationCursor? cursor,
    Set<String> excluding = const {},
    bool shuffled = false,
    int seedOffset = 0,
    double requestTimeout = 35,
    TasteLearning? learning,
    Map<String, List<TasteTag>>? seedOverride,
    RecommendationWhy? whyOverride,
    bool Function()? cancelled,
  }) async {
    final start = cursor ?? RecommendationCursor();
    var control = env.control();
    if (!control.enabled) return TasteRecommendations();
    RecommendationPreferences settings(String source) => preferencesOverride?[source] ?? control.preferences(source);
    final output = TasteRecommendations(cursor: start.copy());
    final activeSeeds = <String>{};
    final highlighted = {...?report?.insights.map((insight) => insight.tagKey)};
    final tags =
        snapshot.tags.where((tag) => tag.count > 0 && TasteTagPolicy.eligible(tag.name) && control.allows(tag.name, source: tag.source, mode: mode)).toList()
          ..sort((a, b) {
            if (highlighted.contains(a.id) != highlighted.contains(b.id)) return highlighted.contains(a.id) ? -1 : 1;
            if (learning != null) {
              final first = learning.seedWeight(a), second = learning.seedWeight(b);
              if (first != second) return second.compareTo(first);
            }
            return a.weight == b.weight ? a.id.compareTo(b.id) : b.weight.compareTo(a.weight);
          });
    final grouped = <String, List<TasteTag>>{};
    for (final tag in tags) {
      grouped.putIfAbsent(tag.source, () => []).add(tag);
    }
    final profiles = {for (final entry in grouped.entries) entry.key: ScoringProfile(entry.key, entry.value)};
    final dismissed = learning?.dismissed ?? const <String>{};
    List<TasteTag> seeds(String source) {
      if (seedOverride != null) return seedOverride[source] ?? [];
      final matching = tags.where((tag) => tag.source == source && !(learning?.isMuted(tag) ?? false)).toList();
      List<TasteTag> rotate(List<TasteTag> values, int count) {
        final pool = values.take(8).toList();
        if (pool.isEmpty) return [];
        return [for (var index = 0; index < math.min(count, pool.length); index++) pool[(math.max(0, seedOffset) + index) % pool.length]];
      }

      if (settings(source).sort != RecommendationSort.recommended) return matching.take(1).toList();
      // The discovery dial decides how much of each page reaches past known favorites.
      final level = learning?.level ?? 1;
      return [
        ...rotate(matching.where((tag) => !tag.discovery).toList(), level == 2 ? 1 : (level == 0 ? 3 : 2)),
        ...rotate([...matching.where((tag) => tag.discovery), if (level == 2) ...?learning?.fringe(source)], level == 0 ? 0 : (level == 2 ? 2 : 1)),
      ];
    }

    if (mode == TasteMode.booru) {
      final saved = env.booru.favoriteIDs;
      // Each server owns its seed selection, cursor, filtering and timeout.
      // HTML-backed engines fetch fewer seeds because detail requests are slower.
      final addresses =
          sourceAddresses ?? (sourceAddress == null ? env.booru.selectedServers.map((server) => server.canonicalAddress).toList() : [sourceAddress]);
      final servers = env.booru.servers.where((server) => addresses.contains(server.canonicalAddress)).toList();
      final tasks = <Future<TasteRecommendations>>[];
      for (final server in servers) {
        final available = seeds(server.canonicalAddress);
        final htmlSeed = math.max(0, seedOffset) % 3 == 2
            ? available.where((tag) => tag.discovery).firstOrNull ?? available.firstOrNull
            : available.firstOrNull;
        final selected = server.engine.usesGelbooruPages ? [?htmlSeed] : available;
        final blacklist = BooruBlacklist(env.booru.blacklist(server.id));
        final preferences = settings(server.canonicalAddress);
        final scoped = [for (final seed in selected) (seed: seed, key: '${server.id}|${server.engine.rawValue}|${seed.id}')];
        activeSeeds.addAll(scoped.map((value) => value.key));
        tasks.add(
          _loadServer(
            server: server,
            scoped: scoped,
            preferences: preferences,
            blacklist: blacklist,
            cursor: start,
            env: env,
            saved: saved,
            excluding: excluding,
            dismissed: dismissed,
            profiles: profiles,
            mode: mode,
            requestTimeout: requestTimeout,
          ),
        );
      }
      for (final result in await Future.wait(tasks)) {
        output.unsupportedSort = output.unsupportedSort || result.unsupportedSort;
        output.unsupportedSources.addAll(result.unsupportedSources);
        output.items.addAll(result.items);
        output.failures.addAll(result.failures);
        // Only each task's changed keys are merged; unrelated cursors remain intact.
        for (final entry in result.cursor.pages.entries) {
          if (entry.value != start.pages[entry.key]) output.cursor.pages[entry.key] = entry.value;
        }
        for (final entry in result.cursor.fingerprints.entries) {
          if (entry.value != start.fingerprints[entry.key]) output.cursor.fingerprints[entry.key] = entry.value;
        }
        output.cursor.pendingPosts.addAll(result.cursor.pendingPosts);
        output.cursor.finished.addAll(result.cursor.finished);
      }
    } else if (env.content.isSiteVerified) {
      final source = MangaUrls.source;
      final preferences = settings(source);
      final fetched = <int>{};
      for (final seed in seeds(source)) {
        activeSeeds.add(seed.id);
        if (start.finished.contains(seed.id)) continue;
        final page = start.pages[seed.id] ?? 0;
        if (cancelled?.call() ?? false) return TasteRecommendations();
        control = env.control();
        if (!control.enabled) return TasteRecommendations();
        try {
          final query = GalleryQuery(
            language: preferences.language,
            text: seed.name,
            sort: GallerySort.fromRawValue(preferences.sort.rawValue) ?? GallerySort.latest,
            allowsLanguageExceptions: env.content.allowsMangaLanguageExceptions,
          ).applyingDefaults(tags: preferences.includedTags.join(' '), excluded: env.content.defaultExcludedTags);
          final batch = await env.comicSource.list(query, offset: page * 24, count: 24);
          final fingerprint = batch.ids.join(',');
          final candidates = batch.ids.where((id) => fetched.add(id) && !excluding.contains('$source#$id')).toList();
          final savedIDs = _savedComicIDs(candidates, env.database);
          final ids = candidates.where((id) => !savedIDs.contains(id)).toList();
          final galleries = await _deadline(requestTimeout, () => loadGalleries(ids, env.comicSource));
          if (ids.isNotEmpty && galleries.isEmpty) throw ContentError.invalidResponse;
          // Recheck after metadata awaits so saving a work while the request runs still excludes it.
          final savedAfterLoading = _savedComicIDs(galleries.map((gallery) => gallery.id).toList(), env.database);
          for (final gallery in galleries) {
            if (savedAfterLoading.contains(gallery.id)) continue;
            final item = TasteItem(source: source, id: gallery.id, tags: gallery.tags);
            final eligible = item.eligibleTags.toSet();
            // The site's artist search already matched; galleries credit people apart from tags.
            final credited = seed.name.isEmpty || const ['artist:', 'series:', 'character:'].any(seed.name.startsWith);
            if (!(credited || seed.name.split(' ').every(eligible.contains)) || excluding.contains(item.key) || dismissed.contains(item.key)) continue;
            final rankingTags = eligible.where((tag) => control.allows(tag, source: item.source, mode: mode)).toSet();
            output.items.add(
              TasteRecommendation(
                item: item,
                gallery: gallery,
                reason: seed,
                score: profiles[item.source]?.scoreTags(rankingTags) ?? 0,
                rankingTags: rankingTags,
              ),
            );
          }
          if (!batch.hasMore || batch.ids.isEmpty || start.fingerprints[seed.id] == fingerprint) output.cursor.finished.add(seed.id);
          output.cursor.fingerprints[seed.id] = fingerprint;
          output.cursor.pages[seed.id] = page + 1;
        } on Object {
          final host = MangaUrls.configuredHost;
          if (!output.failures.contains(host)) output.failures.add(host);
        }
      }
    }
    output.cursor.hasMore = activeSeeds.any((key) => !output.cursor.finished.contains(key) || (output.cursor.pendingPosts[key] ?? const []).isNotEmpty);
    final items = output.items.where((item) => item.post == null || env.booru.isVisible(item.post!)).toList();
    final preferences = {for (final source in items.map((item) => item.item.source).toSet()) source: settings(source)};
    output.items = rank(
      learning == null ? items : [for (final item in items) learning.personalize(item, why: whyOverride)],
      preferences: preferences,
      mode: mode,
      shuffled: shuffled,
      discoverySlots: learning?.discoverySlots ?? 3,
    );
    if (!env.control().enabled) return TasteRecommendations();
    output.items.removeWhere((item) => item.post != null && !env.booru.isVisible(item.post!));
    return output;
  }

  static Future<TasteRecommendations> _loadServer({
    required BooruServer server,
    required List<({TasteTag seed, String key})> scoped,
    required RecommendationPreferences preferences,
    required BooruBlacklist blacklist,
    required RecommendationCursor cursor,
    required TasteEnvironment env,
    required Set<String> saved,
    required Set<String> excluding,
    required Set<String> dismissed,
    required Map<String, ScoringProfile> profiles,
    required TasteMode mode,
    required double requestTimeout,
  }) async {
    final result = TasteRecommendations(cursor: cursor.copy());
    result.cursor.pendingPosts = {
      for (final entry in cursor.pendingPosts.entries)
        if (entry.key.startsWith('${server.id}|')) entry.key: [...entry.value],
    };
    var detailFailures = false;
    final started = DateTime.now();
    final control = env.control();
    try {
      for (final (:seed, :key) in scoped) {
        if (cursor.finished.contains(key) && (cursor.pendingPosts[key] ?? const []).isEmpty) continue;
        var candidates = cursor.pendingPosts[key] ?? const <BooruPost>[];
        if (candidates.isEmpty) {
          final page = cursor.pages[key] ?? 0;
          final query = env.booruQuery([seed.name, ...preferences.includedTags].where((term) => term.isNotEmpty).join(' '));
          final sort = preferences.sort.booruSort ?? BooruSort.latest;
          // Give each listing the same document-loading allowance as Explore.
          final batch = await _deadline(
            requestTimeout,
            () => BooruSortValidation.posts(source: env.booruSource, server: server, query: query, page: page, sort: sort),
          );
          env.booru.recordGoldRestrictions(server.id, batch.goldRestrictedIDs);
          final fingerprint = [
            ...batch.posts.map((post) => post.id),
            ...([...batch.goldRestrictedIDs]..sort()).map((id) => 'gold:$id'),
          ].join(',');
          if (!batch.hasMore || batch.sourcePostCount == 0 || cursor.fingerprints[key] == fingerprint) result.cursor.finished.add(key);
          result.cursor.fingerprints[key] = fingerprint;
          result.cursor.pages[key] = page + 1;
          candidates = batch.posts;
        }
        final deferred = <BooruPost>[];
        final detailStart = DateTime.now();
        final detailBudget = math.min(12.0, requestTimeout);
        var hydrated = 0;
        for (final candidate in candidates) {
          var post = candidate;
          if (saved.contains(post.id)) continue;
          final candidateKey = '${server.canonicalAddress}#${post.postID}';
          if (!env.booru.isVisible(post) || excluding.contains(candidateKey) || dismissed.contains(candidateKey)) continue;
          var names = post.tags.map(TasteTagPolicy.normalize).toSet();
          final terms = seed.name.split(' ').where((term) => term.isNotEmpty).toList();
          final needsDetails = !terms.every(names.contains) || !preferences.includedTags.every(names.contains);
          if (server.engine.usesGelbooruPages && needsDetails) {
            final remaining = detailBudget - DateTime.now().difference(detailStart).inMilliseconds / 1000;
            if (hydrated >= 4 || remaining <= 0) {
              deferred.add(post);
              continue;
            }
            hydrated += 1;
            final unresolved = post;
            try {
              post = await _deadline(math.min(6, remaining), () => env.booruSource.details(server, unresolved));
              names = post.tags.map(TasteTagPolicy.normalize).toSet();
            } on BooruPostAccessError catch (error) {
              if (error == BooruPostAccessError.goldRequired) env.booru.recordGoldRestriction(unresolved);
              if (error != BooruPostAccessError.goldRequired) detailFailures = true;
              continue;
            } on Object {
              detailFailures = true;
              continue;
            }
          }
          if (!env.booru.isVisible(post) || blacklist.contains(post)) continue;
          final item = TasteItem(source: server.canonicalAddress, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? const []);
          final eligible = item.eligibleTags.toSet();
          if (!terms.every(eligible.contains) || !preferences.includedTags.every(names.contains)) continue;
          final rankingTags = eligible.where((tag) => control.allows(tag, source: item.source, mode: mode)).toSet();
          result.items.add(
            TasteRecommendation(item: item, post: post, reason: seed, score: profiles[item.source]?.scoreTags(rankingTags) ?? 0, rankingTags: rankingTags),
          );
        }
        // Resume unresolved candidates before fetching another page, even
        // when this was the website's last page. Never silently skip them.
        result.cursor.pendingPosts[key] = deferred;
        if (DateTime.now().difference(started).inMilliseconds / 1000 >= requestTimeout) break;
      }
      if (detailFailures && result.items.isEmpty) result.failures = [server.displayName];
    } on UnsupportedBooruSort {
      result
        ..unsupportedSort = true
        ..unsupportedSources.add(server.canonicalAddress);
    } on Object {
      result.failures = [server.displayName];
    }
    return result;
  }

  static Set<int> _savedComicIDs(List<int> ids, AppDatabase database) {
    if (ids.isEmpty) return {};
    return database.dbWriter.read(
      (db) => db.column<int>('SELECT gallery_id FROM works WHERE gallery_id IN (${List.filled(ids.length, '?').join(',')})', ids).toSet(),
    );
  }

  static List<TasteRecommendation> rank(
    List<TasteRecommendation> candidates, {
    required Map<String, RecommendationPreferences> preferences,
    required TasteMode mode,
    required bool shuffled,
    required int discoverySlots,
  }) {
    final grouped = <String, List<TasteRecommendation>>{};
    for (final candidate in candidates) {
      grouped.putIfAbsent(candidate.item.source, () => []).add(candidate);
    }
    // Interleave independent server decks; never compare unrelated tag profiles.
    final decks = (grouped.keys.toList()..sort()).map((address) {
      final items = grouped[address]!;
      final preference = preferences[address] ?? RecommendationPreferences();
      if (preference.sort == RecommendationSort.recommended) return mix(items, limit: items.length, shuffled: shuffled, discoverySlots: discoverySlots);
      if (preference.sort == RecommendationSort.latest) {
        items.sort((a, b) => b.item.id.compareTo(a.item.id));
      } else if (mode == TasteMode.booru) {
        final sort = preference.sort.booruSort;
        if (sort != null && items.every((item) => item.post != null && sort.metric(item.post!) != null)) {
          items.sort((a, b) => (sort.metric(b.post!) ?? 0).compareTo(sort.metric(a.post!) ?? 0));
        }
      }
      final seen = <String>{};
      return items.where((item) => seen.add(item.id)).toList();
    }).toList();
    final longest = decks.fold<int>(0, (value, deck) => math.max(value, deck.length));
    return [
      for (var index = 0; index < longest; index++)
        for (final deck in decks)
          if (index < deck.length) deck[index],
    ];
  }

  static Future<List<NativeGallery>> loadGalleries(List<int> ids, ContentProviding source) async {
    final results = <int, NativeGallery>{};
    var next = 0;
    Future<void> worker() async {
      while (next < ids.length) {
        final index = next++;
        try {
          results[index] = await source.gallery(ids[index]);
        } on Object {
          // A gallery that fails to load is left out.
        }
      }
    }

    await Future.wait([for (var count = 0; count < math.min(4, ids.length); count++) worker()]);
    return [for (final index in results.keys.toList()..sort()) results[index]!];
  }
}

/// The library-wide evidence and denominator are constant for every
/// candidate from a source. Build them once for each requested page.
class ScoringProfile {
  ScoringProfile(this.source, List<TasteTag> tags) {
    final matching = tags.where((tag) => tag.source == source).toList();
    final profile = matching.where((tag) => tag.count > 0).toList();
    final libraryCount = math.max(1, profile.expand((tag) => tag.works.map((item) => item.key)).toSet().length);
    double importance(TasteTag tag) {
      final confidence = tag.count / (tag.count + 4);
      final rarity = 1 + math.log(1 + libraryCount / (1 + tag.works.length));
      return tag.weight * confidence * rarity;
    }

    _norm = math.sqrt(profile.fold<double>(0, (sum, tag) => sum + math.pow(importance(tag), 2)));
    // Preserve the original tag order, including duplicate names, so
    // floating-point sums and tie-breaking do not change.
    _weights = [for (final tag in matching) importance(tag)];
    for (final (index, tag) in matching.indexed) {
      _positions.putIfAbsent(tag.name, () => []).add(index);
    }
  }

  final String source;
  late final List<double> _weights;
  final _positions = <String, List<int>>{};
  late final double _norm;

  double score(TasteItem item, {Set<String> ignoring = const {}}) {
    if (item.source != source) return 0;
    return scoreTags(item.eligibleTags.where((tag) => !ignoring.contains(TasteControl.normalizeExclusion(tag))).toSet());
  }

  double scoreTags(Set<String> eligibleTags) {
    final positions = eligibleTags.expand((tag) => _positions[tag] ?? const <int>[]).toList()..sort();
    final matched = positions.fold<double>(0, (sum, index) => sum + _weights[index]);
    return matched / math.max(1, _norm * math.sqrt(math.max(1, eligibleTags.length)));
  }
}
