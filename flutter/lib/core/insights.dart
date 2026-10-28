import 'dart:async';
import 'dart:math' as math;

import 'content.dart';
import 'content_filter.dart';
import 'library.dart';

class InsightPreferences {
  InsightPreferences({
    required this.mode,
    Set<String>? excludedTags,
    this.excludedBySource = const {},
    this.includedBySource = const {},
    this.excludedRecommendationBySource = const {},
  }) : excludedTags = (excludedTags ?? defaults(mode)).map(normalize).toSet();
  final AppMode mode;
  final Set<String> excludedTags;
  final Map<String, Set<String>> excludedBySource;
  final Map<String, Set<String>> includedBySource;
  final Map<String, Set<String>> excludedRecommendationBySource;
  static String normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '_');
  static Set<String> defaults(AppMode mode) => mode == AppMode.booru
      ? {'1girl', '1boy', 'solo'}
      : {'female:sole_female', 'male:sole_male', 'tag:digital', 'tag:group'};
  bool allows(String name, String sourceId) {
    String boundary(String value) {
      final normalized = normalize(value);
      if (mode != AppMode.manga) return normalized;
      return switch (normalized) {
        'female:solo_female' => 'female:sole_female',
        'male:solo_male' => 'male:sole_male',
        'solo_female' => 'sole_female',
        'solo_male' => 'sole_male',
        _ => normalized,
      };
    }

    final normalized = boundary(name);
    return !{
      ...(excludedBySource[sourceId] ?? excludedTags),
      ...?excludedRecommendationBySource[sourceId],
    }.any((value) {
      final exclusion = boundary(value);
      if (exclusion == normalized) return true;
      return mode == AppMode.manga &&
          !normalized.contains(':') &&
          ['female:', 'male:', 'tag:'].any(exclusion.startsWith) &&
          exclusion.split(':').last == normalized;
    });
  }
}

class TasteTagPolicy {
  static const technical = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'avif',
    'apng',
    'bmp',
    'tiff',
    'svg',
    'mp4',
    'webm',
    'mov',
    'flash',
    'video',
    'animated',
    'animated_gif',
    'animated_png',
    'sound',
    'audio',
    'no_sound',
    'highres',
    'absurdres',
    'incredibly_absurdres',
    'lowres',
    'huge_filesize',
    'big_filesize',
    'small_filesize',
    'wide_image',
    'tall_image',
    'jpeg_artifacts',
    'compression_artifacts',
    'tagme',
    'translation_request',
    'translated',
    'partially_translated',
    'check_translation',
    'commentary_request',
    'commentary',
    'translated_commentary',
    'source_request',
    'bad_id',
    'bad_link',
    'bad_pixiv_id',
    'bad_twitter_id',
    'duplicate',
    'revision',
    'resized',
    'upscaled',
    'md5_mismatch',
    'corrupted_file',
  };
  static const operators = {
    'rating',
    'order',
    'sort',
    'score',
    'id',
    'width',
    'height',
    'mpixels',
    'filesize',
    'filetype',
    'status',
    'date',
    'age',
    'pool',
    'limit',
    'page',
    'language',
    'type',
  };
  static Set<String> metadata(ContentItem item) {
    final tags = item.metadata['metadataTags'];
    return {
      ...((tags is List) ? tags : const []).whereType<String>().map(
        InsightPreferences.normalize,
      ),
      if (item.metadata['tagCategories'] is Map)
        for (final entry in (item.metadata['tagCategories'] as Map).entries)
          if (entry.value == 5) InsightPreferences.normalize('${entry.key}'),
    };
  }

  static Set<String> eligible(
    ContentItem item,
    InsightPreferences preferences, {
    Set<String> knownMetadata = const {},
  }) {
    final excluded = {...knownMetadata, ...metadata(item)};
    return item.tags
        .map(InsightPreferences.normalize)
        .where(
          (tag) =>
              tag.isNotEmpty &&
              !technical.contains(tag) &&
              !excluded.contains(tag) &&
              !tag.startsWith('-') &&
              !RegExp(r'[*~{}]').hasMatch(tag) &&
              !(tag.contains(':') &&
                  operators.contains(tag.split(':').first)) &&
              preferences.allows(tag, item.sourceId),
        )
        .toSet();
  }
}

class TasteTagStat {
  TasteTagStat({
    required this.sourceId,
    required this.name,
    required Set<String> workKeys,
    this.lift,
  }) : workKeys = Set.unmodifiable(workKeys);
  final String sourceId;
  final String name;
  final Set<String> workKeys;
  final double? lift;
  int get count => workKeys.length;
  double get weight => math.log(1 + count) * (lift?.clamp(0.25, 3.0) ?? 1);
  String get key => '$sourceId\n$name';
}

enum InsightPattern { frequent, rising, association }

class TasteFinding {
  const TasteFinding({
    required this.pattern,
    required this.tag,
    this.related,
    required this.count,
    this.previousCount,
  });
  final InsightPattern pattern;
  final TasteTagStat tag;
  final TasteTagStat? related;
  final int count;
  final int? previousCount;
}

class TasteRecap {
  const TasteRecap({
    required this.days,
    required this.saves,
    required this.previousSaves,
    this.opens = 0,
    required this.tags,
    required this.previousTags,
  });
  final int days;
  final int saves;
  final int previousSaves;
  final int opens;
  final Map<String, int> tags;
  final Map<String, int> previousTags;
  int get change => saves - previousSaves;
}

class TasteSnapshot {
  const TasteSnapshot({
    required this.mode,
    required this.preferences,
    required this.savedKeys,
    required this.totalPages,
    required this.tags,
    required this.artists,
    required this.categories,
    required this.sourceCounts,
    required this.knownMetadata,
    required this.weekly,
    required this.monthly,
    required this.findings,
  });
  final AppMode mode;
  final InsightPreferences preferences;
  final Set<String> savedKeys;
  int get totalWorks => savedKeys.length;
  final int totalPages;
  final List<TasteTagStat> tags;
  final Map<String, int> artists;
  final Map<String, int> categories;
  final Map<String, int> sourceCounts;
  final Map<String, Set<String>> knownMetadata;
  final TasteRecap weekly;
  final TasteRecap monthly;
  final List<TasteFinding> findings;
  bool get generatedByAI => false;
  Map<String, int> get tagCounts {
    final result = <String, int>{};
    for (final tag in tags) {
      result.update(
        tag.name,
        (count) => count + tag.count,
        ifAbsent: () => tag.count,
      );
    }
    return result;
  }
}

/// Counts describe active saved evidence. Calendar recaps use historical save
/// and open events, retaining activity after removal. Reading time is not tracked.
class TasteAnalyzer {
  static TasteSnapshot analyze(
    Iterable<SavedItem> input, {
    required AppMode mode,
    InsightPreferences? preferences,
    Iterable<ContentItem> observed = const [],
    Iterable<ContentItem> organicSaved = const [],
    Iterable<SavedItem>? saveHistory,
    Iterable<SavedItem> openHistory = const [],
    DateTime? now,
  }) {
    final prefs = preferences ?? InsightPreferences(mode: mode);
    final clock = now ?? DateTime.now();
    final deduplicated = <String, SavedItem>{};
    for (final saved in input.where((entry) => entry.item.mode == mode)) {
      final previous = deduplicated[saved.item.key];
      if (previous == null || saved.savedAt.isAfter(previous.savedAt)) {
        deduplicated[saved.item.key] = saved;
      }
    }
    final saved = deduplicated.values.toList()
      ..sort((a, b) => a.item.key.compareTo(b.item.key));
    final metadata = <String, Set<String>>{};
    for (final entry in saved) {
      (metadata[entry.item.sourceId] ??= {}).addAll(
        TasteTagPolicy.metadata(entry.item),
      );
    }
    final observedUnique = {
      for (final item in observed.where((item) => item.mode == mode))
        item.key: item,
    };
    final organicUnique = {
      for (final item in organicSaved.where((item) => item.mode == mode))
        item.key: item,
    };
    for (final item in observedUnique.values) {
      (metadata[item.sourceId] ??= {}).addAll(TasteTagPolicy.metadata(item));
    }
    final openedCounts = <String, int>{};
    final openedTags = <String, int>{};
    final organicCounts = <String, int>{};
    final organicTags = <String, int>{};
    void countEvidence(
      ContentItem item,
      Map<String, int> counts,
      Map<String, int> tags,
    ) {
      counts.update(item.sourceId, (n) => n + 1, ifAbsent: () => 1);
      for (final tag in TasteTagPolicy.eligible(
        item,
        prefs,
        knownMetadata: metadata[item.sourceId] ?? {},
      )) {
        tags.update('${item.sourceId}\n$tag', (n) => n + 1, ifAbsent: () => 1);
      }
    }

    for (final item in observedUnique.values) {
      countEvidence(item, openedCounts, openedTags);
    }
    for (final item in organicUnique.values) {
      countEvidence(item, organicCounts, organicTags);
    }
    final works = <String, Set<String>>{};
    final artists = <String, int>{};
    final categories = <String, int>{};
    final sources = <String, int>{};
    final eligibleByItem = <String, Set<String>>{};
    var pages = 0;
    for (final entry in saved) {
      final item = entry.item;
      pages += math.max(0, item.pageCount);
      sources.update(item.sourceId, (value) => value + 1, ifAbsent: () => 1);
      final eligible = TasteTagPolicy.eligible(
        item,
        prefs,
        knownMetadata: metadata[item.sourceId] ?? {},
      );
      eligibleByItem[item.key] = eligible;
      for (final tag in eligible) {
        (works['${item.sourceId}\n$tag'] ??= {}).add(item.key);
      }
      for (final artist
          in item.artists
              .map(InsightPreferences.normalize)
              .where((name) => name.isNotEmpty)
              .toSet()) {
        artists.update(artist, (value) => value + 1, ifAbsent: () => 1);
      }
      final itemCategories = item.tags
          .map(InsightPreferences.normalize)
          .where(
            (tag) =>
                tag.startsWith('type:') ||
                tag.startsWith('language:') ||
                tag.startsWith('rating:'),
          )
          .toSet();
      final rating = item.metadata['rating'];
      if (rating is String && rating.isNotEmpty) {
        itemCategories.add('rating:$rating');
      }
      final type = item.metadata['type'];
      if (type is String && type.isNotEmpty) {
        itemCategories.add('type:${InsightPreferences.normalize(type)}');
      }
      for (final category in itemCategories) {
        categories.update(category, (value) => value + 1, ifAbsent: () => 1);
      }
    }
    final tags =
        works.entries.map((entry) {
          final separator = entry.key.indexOf('\n');
          final sourceId = entry.key.substring(0, separator);
          final opened = openedCounts[sourceId] ?? 0;
          final organic = organicCounts[sourceId] ?? 0;
          final lift = opened >= 30 && organic >= 10
              ? ((organicTags[entry.key] ?? 0) + 1) /
                    (organic + 2) /
                    (((openedTags[entry.key] ?? 0) + 1) / (opened + 2))
              : null;
          return TasteTagStat(
            lift: lift,
            sourceId: sourceId,
            name: entry.key.substring(separator + 1),
            workKeys: entry.value,
          );
        }).toList()..sort((a, b) {
          final count = b.count.compareTo(a.count);
          return count == 0 ? a.key.compareTo(b.key) : count;
        });
    TasteRecap recap(int days) {
      DateTime midnight(int year, int month, int day) => clock.isUtc
          ? DateTime.utc(year, month, day)
          : DateTime(year, month, day);
      final start = days == 7
          ? midnight(clock.year, clock.month, clock.day - clock.weekday + 1)
          : midnight(clock.year, clock.month, 1);
      final previousStart = days == 7
          ? midnight(start.year, start.month, start.day - 7)
          : midnight(start.year, start.month - 1, 1);
      final end = days == 7
          ? midnight(start.year, start.month, start.day + 7)
          : midnight(start.year, start.month + 1, 1);
      final current = <String, SavedItem>{};
      final previous = <String, SavedItem>{};
      final opened = <String>{};
      final currentTags = <String, int>{}, previousTags = <String, int>{};
      for (final entry in (saveHistory ?? saved).where(
        (entry) => entry.item.mode == mode,
      )) {
        if (!entry.savedAt.isBefore(end) ||
            entry.savedAt.isBefore(previousStart)) {
          continue;
        }
        final bucket = !entry.savedAt.isBefore(start) ? current : previous;
        bucket.putIfAbsent(entry.item.key, () => entry);
      }
      for (final entry in openHistory.where(
        (entry) => entry.item.mode == mode,
      )) {
        if (!entry.savedAt.isBefore(end) || entry.savedAt.isBefore(start)) {
          continue;
        }
        opened.add(entry.item.key);
      }
      void countTags(Map<String, SavedItem> bucket, Map<String, int> target) {
        for (final entry in bucket.values) {
          for (final tag in TasteTagPolicy.eligible(
            entry.item,
            prefs,
            knownMetadata: metadata[entry.item.sourceId] ?? {},
          )) {
            final key = '${entry.item.sourceId}\n$tag';
            target.update(key, (value) => value + 1, ifAbsent: () => 1);
          }
        }
      }

      countTags(current, currentTags);
      countTags(previous, previousTags);
      return TasteRecap(
        days: days,
        saves: current.length,
        previousSaves: previous.length,
        opens: opened.length,
        tags: currentTags,
        previousTags: previousTags,
      );
    }

    final weekly = recap(7), monthly = recap(30);
    final findings = <TasteFinding>[];
    final rising = tags
        .where(
          (tag) =>
              (monthly.tags[tag.key] ?? 0) >= 3 &&
              (monthly.tags[tag.key] ?? 0) >
                  (monthly.previousTags[tag.key] ?? 0),
        )
        .firstOrNull;
    if (rising != null) {
      findings.add(
        TasteFinding(
          pattern: InsightPattern.rising,
          tag: rising,
          count: monthly.tags[rising.key]!,
          previousCount: monthly.previousTags[rising.key] ?? 0,
        ),
      );
    }
    for (final tag in tags) {
      if (findings.length >= 3) break;
      if (findings.any((finding) => finding.tag.key == tag.key)) continue;
      final associated = tags
          .where(
            (other) =>
                other.sourceId == tag.sourceId &&
                other.key != tag.key &&
                tag.workKeys.intersection(other.workKeys).length >= 5 &&
                tag.workKeys.intersection(other.workKeys).length /
                        math.max(tag.count, other.count) >=
                    .8,
          )
          .firstOrNull;
      findings.add(
        TasteFinding(
          pattern: associated == null
              ? InsightPattern.frequent
              : InsightPattern.association,
          tag: tag,
          related: associated,
          count: associated == null
              ? tag.count
              : tag.workKeys.intersection(associated.workKeys).length,
        ),
      );
    }
    return TasteSnapshot(
      mode: mode,
      preferences: prefs,
      savedKeys: saved.map((e) => e.item.key).toSet(),
      totalPages: pages,
      tags: tags,
      artists: artists,
      categories: categories,
      sourceCounts: sources,
      knownMetadata: metadata,
      weekly: weekly,
      monthly: monthly,
      findings: findings,
    );
  }
}

class TasteRecommendation {
  const TasteRecommendation({
    required this.item,
    required this.reason,
    required this.score,
    required this.rankingTags,
    this.sourceOrder = 0,
  });
  final ContentItem item;
  final TasteTagStat reason;
  final double score;
  final Set<String> rankingTags;
  final int sourceOrder;
  bool get generatedByAI => false;
}

class RecommendationFailure {
  const RecommendationFailure(this.sourceId, this.message);
  final String sourceId;
  final String message;
}

class TasteRecommendations {
  const TasteRecommendations({
    required this.items,
    required this.failures,
    required this.requestCount,
    required this.skippedUnscored,
    required this.omittedSources,
  });
  final List<TasteRecommendation> items;
  final List<RecommendationFailure> failures;
  final int requestCount;
  final int skippedUnscored;
  final int omittedSources;
  bool get generatedByAI => false;
}

typedef RecommendationLoader = Future<ContentPage> Function(
  SourceConfig source,
  String query,
);

/// Explicitly invoked, bounded candidate retrieval. Source profiles rank their
/// own deck; round-robin interleaving avoids comparing unrelated source scores.
class RecommendationService {
  RecommendationService({required this.load});
  final RecommendationLoader load;
  Future<TasteRecommendations> fetch({
    required TasteSnapshot snapshot,
    required List<SourceConfig> sources,
    Map<String, String> blacklists = const {},
    Map<String, String> sortsBySource = const {},
    Set<String> Function()? currentSavedKeys,
    int limit = 20,
    int requestBudget = 6,
    int concurrency = 2,
    bool Function()? cancelled,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final matchingSources =
        sources.where((source) => source.mode == snapshot.mode).toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final tasks = <(SourceConfig, TasteTagStat)>[];
    final budget = limit <= 0 ? 0 : requestBudget.clamp(0, 6);
    for (final source in matchingSources) {
      for (final seed
          in snapshot.tags.where((tag) => tag.sourceId == source.id).take(2)) {
        if (tasks.length < budget) tasks.add((source, seed));
      }
    }
    final touched = tasks.map((task) => task.$1.id).toSet();
    final filters = {
      for (final source in matchingSources)
        source.id: ContentFilter(blacklists[source.id] ?? ''),
    };
    final candidates = <TasteRecommendation>[];
    final failures = <RecommendationFailure>[];
    final profiles = {
      for (final source in matchingSources)
        source.id: _ScoringProfile(
          snapshot.tags.where((tag) => tag.sourceId == source.id).toList(),
        ),
    };
    var next = 0, skipped = 0, dispatched = 0;
    Future<void> worker() async {
      while (next < tasks.length) {
        if (cancelled?.call() ?? false) break;
        dispatched++;
        final taskIndex = next++;
        final (source, seed) = tasks[taskIndex];
        try {
          final included =
              snapshot.preferences.includedBySource[source.id] ??
              const <String>{};
          final queryTags = {
            seed.name,
            ...included.map(InsightPreferences.normalize),
          };
          final page = await load(source, queryTags.join(' ')).timeout(timeout);
          if (cancelled?.call() ?? false) return;
          final savedNow = currentSavedKeys?.call() ?? snapshot.savedKeys;
          for (final (position, item) in page.items.take(40).indexed) {
            if (item.mode != snapshot.mode ||
                item.sourceId != source.id ||
                snapshot.savedKeys.contains(item.key) ||
                savedNow.contains(item.key) ||
                filters[source.id]!.contains(item)) {
              continue;
            }
            final eligible = TasteTagPolicy.eligible(
              item,
              snapshot.preferences,
              knownMetadata: snapshot.knownMetadata[source.id] ?? {},
            );
            final itemTags = item.tags
                .map(InsightPreferences.normalize)
                .toSet();
            if (!eligible.contains(seed.name) ||
                !itemTags.containsAll(
                  included.map(InsightPreferences.normalize),
                )) {
              skipped++;
              continue;
            }
            final score = profiles[source.id]!.score(eligible);
            if (score > 0) {
              candidates.add(
                TasteRecommendation(
                  item: item,
                  reason: seed,
                  score: score,
                  rankingTags: eligible,
                  sourceOrder: taskIndex * 40 + position,
                ),
              );
            }
          }
        } catch (error) {
          failures.add(
            RecommendationFailure(
              source.id,
              error is ContentException
                  ? error.message
                  : 'Unable to fetch recommendations from this source.',
            ),
          );
        }
      }
    }

    await Future.wait(
      List.generate(
        math.min(tasks.length, concurrency.clamp(1, 2)),
        (_) => worker(),
      ),
    );
    final wasCancelled = cancelled?.call() ?? false;
    final saved = {
      ...snapshot.savedKeys,
      if (!wasCancelled) ...?currentSavedKeys?.call(),
    };
    if (wasCancelled) candidates.clear();
    final decks = <List<TasteRecommendation>>[];
    for (final source in matchingSources) {
      final input = candidates
          .where(
            (candidate) =>
                candidate.item.sourceId == source.id &&
                !saved.contains(candidate.item.key),
          )
          .toList();
      final sort = sortsBySource[source.id] ?? 'recommended';
      if (sort == 'recommended') {
        decks.add(_mix(input, limit.clamp(0, 40)));
      } else {
        // Server ordering belongs to a dispatched query/page position, never
        // to the order in which concurrent HTTP requests happened to finish.
        input.sort((a, b) => a.sourceOrder.compareTo(b.sourceOrder));
        final seen = <String>{};
        final ordered = input
            .where((entry) => seen.add(entry.item.key))
            .toList();
        if (sort == 'latest') {
          ordered.sort((a, b) => b.item.id.compareTo(a.item.id));
        }
        decks.add(ordered.take(limit.clamp(0, 40)).toList());
      }
    }
    final result = <TasteRecommendation>[];
    for (var index = 0; result.length < limit.clamp(0, 40); index++) {
      var advanced = false;
      for (final deck in decks) {
        if (index < deck.length && result.length < limit.clamp(0, 40)) {
          result.add(deck[index]);
          advanced = true;
        }
      }
      if (!advanced) break;
    }
    failures.sort((a, b) => a.sourceId.compareTo(b.sourceId));
    return TasteRecommendations(
      items: result,
      failures: {
        for (final failure in failures)
          '${failure.sourceId}\n${failure.message}': failure,
      }.values.toList(),
      requestCount: dispatched,
      skippedUnscored: skipped,
      omittedSources: matchingSources
          .where(
            (source) =>
                !touched.contains(source.id) &&
                snapshot.tags.any((tag) => tag.sourceId == source.id),
          )
          .length,
    );
  }

  static List<TasteRecommendation> _mix(
    List<TasteRecommendation> input,
    int limit,
  ) {
    input.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final key = a.item.key.compareTo(b.item.key);
      return key == 0 ? a.reason.key.compareTo(b.reason.key) : key;
    });
    final seen = <String>{};
    final remaining = input.where((item) => seen.add(item.item.key)).toList();
    final result = <TasteRecommendation>[];
    final maximum = remaining.isEmpty
        ? .001
        : math.max(.001, remaining.first.score);
    while (remaining.isNotEmpty && result.length < limit) {
      double utility(TasteRecommendation candidate) {
        var overlap = 0.0;
        for (final other in result.skip(math.max(0, result.length - 8))) {
          final intersection = candidate.rankingTags
              .intersection(other.rankingTags)
              .length;
          overlap = math.max(
            overlap,
            intersection /
                math.max(
                  1,
                  candidate.rankingTags.union(other.rankingTags).length,
                ),
          );
        }
        return .8 * candidate.score / maximum - .2 * overlap;
      }

      var best = remaining.first;
      var bestUtility = utility(best);
      for (final candidate in remaining.skip(1)) {
        final value = utility(candidate);
        if (value > bestUtility) {
          best = candidate;
          bestUtility = value;
        }
      }
      result.add(best);
      remaining.remove(best);
    }
    return result;
  }
}

class _ScoringProfile {
  _ScoringProfile(List<TasteTagStat> tags) {
    final libraryCount = math.max(
      1,
      tags.expand((tag) => tag.workKeys).toSet().length,
    );
    for (final tag in tags) {
      final confidence = tag.count / (tag.count + 4);
      final rarity = 1 + math.log(1 + libraryCount / (1 + tag.count));
      weights[tag.name] = tag.weight * confidence * rarity;
    }
    norm = math.sqrt(
      weights.values.fold<double>(
        0,
        (value, weight) => value + weight * weight,
      ),
    );
  }
  final Map<String, double> weights = {};
  late final double norm;
  double score(Set<String> tags) =>
      weights.entries
          .where((entry) => tags.contains(entry.key))
          .fold<double>(0, (sum, entry) => sum + entry.value) /
      math.max(1, norm * math.sqrt(math.max(1, tags.length)));
}
