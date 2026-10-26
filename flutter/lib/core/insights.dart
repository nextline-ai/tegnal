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
  }) : excludedTags = (excludedTags ?? defaults(mode)).map(normalize).toSet();
  final AppMode mode;
  final Set<String> excludedTags;
  final Map<String, Set<String>> excludedBySource;
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
    return !(excludedBySource[sourceId] ?? excludedTags).any((value) {
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
  }) : workKeys = Set.unmodifiable(workKeys);
  final String sourceId;
  final String name;
  final Set<String> workKeys;
  int get count => workKeys.length;
  double get weight => math.log(1 + count);
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
    required this.tags,
    required this.previousTags,
  });
  final int days;
  final int saves;
  final int previousSaves;
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

/// Counts describe the current saved collection. Recaps count timestamps of
/// still-saved works; they do not reconstruct removed favorites or reading time.
class TasteAnalyzer {
  static TasteSnapshot analyze(
    Iterable<SavedItem> input, {
    required AppMode mode,
    InsightPreferences? preferences,
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
          return TasteTagStat(
            sourceId: entry.key.substring(0, separator),
            name: entry.key.substring(separator + 1),
            workKeys: entry.value,
          );
        }).toList()..sort((a, b) {
          final count = b.count.compareTo(a.count);
          return count == 0 ? a.key.compareTo(b.key) : count;
        });
    TasteRecap recap(int days) {
      final start = clock.subtract(Duration(days: days));
      final previousStart = start.subtract(Duration(days: days));
      var current = 0, previous = 0;
      final currentTags = <String, int>{}, previousTags = <String, int>{};
      for (final entry in saved) {
        if (entry.savedAt.isAfter(clock) ||
            entry.savedAt.isBefore(previousStart)) {
          continue;
        }
        final recent = !entry.savedAt.isBefore(start);
        if (recent) {
          current++;
        } else {
          previous++;
        }
        for (final tag in eligibleByItem[entry.item.key] ?? <String>{}) {
          final target = recent ? currentTags : previousTags;
          final key = '${entry.item.sourceId}\n$tag';
          target.update(key, (value) => value + 1, ifAbsent: () => 1);
        }
      }
      return TasteRecap(
        days: days,
        saves: current,
        previousSaves: previous,
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
  });
  final ContentItem item;
  final TasteTagStat reason;
  final double score;
  final Set<String> rankingTags;
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
        final (source, seed) = tasks[next++];
        try {
          final page = await load(source, seed.name).timeout(timeout);
          if (cancelled?.call() ?? false) return;
          final savedNow = currentSavedKeys?.call() ?? snapshot.savedKeys;
          for (final item in page.items.take(40)) {
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
            if (!eligible.contains(seed.name)) {
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
      decks.add(
        _mix(
          candidates
              .where(
                (candidate) =>
                    candidate.item.sourceId == source.id &&
                    !saved.contains(candidate.item.key),
              )
              .toList(),
          limit.clamp(0, 40),
        ),
      );
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
