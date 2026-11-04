import 'dart:math' as math;

import '../content/manga_urls.dart';
import '../support/l10n.dart';
import 'recommendation_service.dart';
import 'taste_models.dart';
import 'taste_recap.dart';

/// Why a work was chosen, in terms a person can check against their own activity.
sealed class RecommendationWhy {
  const RecommendationWhy();

  /// SF Symbol name of the reason's icon.
  String get icon => switch (this) {
    WhyTaste() => 'heart',
    WhyRecent() => 'flame',
    WhyHidden() => 'sparkles',
    WhyComeback() => 'arrow.uturn.backward',
    WhyPair() => 'link',
    WhyPerson() => 'paintpalette',
    WhyNovel() => 'safari',
    WhySimilar() => 'square.on.square',
    WhyPopular() => 'chart.line.uptrend.xyaxis',
  };

  /// A few words that fit under a card.
  String get label => switch (this) {
    WhyTaste(:final tag) ||
    WhyRecent(:final tag) ||
    WhyHidden(:final tag) ||
    WhyComeback(:final tag) ||
    WhyNovel(:final tag) ||
    WhySimilar(:final tag) => RecapText.tag(tag),
    WhyPair(:final first, :final second) => '${RecapText.tag(first)} × ${RecapText.tag(second)}',
    WhyPerson(:final name) => RecapText.capitalized(RecapText.tag(name)),
    WhyPopular() => L10n.text('Popular now'),
  };

  /// The full sentence, drawn only from counted facts.
  String get sentence => switch (this) {
    WhyTaste(:final tag) => L10n.text('You often save works tagged %@.', [RecapText.tag(tag)]),
    WhyRecent(:final tag) => L10n.text('You have been saving %@ lately.', [RecapText.tag(tag)]),
    WhyHidden(:final tag) => L10n.text('You keep saving %@ without searching for it.', [RecapText.tag(tag)]),
    WhyComeback(:final tag) => L10n.text("You loved %@ before and haven't visited in a while.", [RecapText.tag(tag)]),
    WhyPair(:final first, :final second) => L10n.text('%@ and %@ often appear together in what you save.', [RecapText.tag(first), RecapText.tag(second)]),
    WhyPerson(:final name, :final count) => L10n.text('You saved %@ works by %@.', ['$count', RecapText.capitalized(RecapText.tag(name))]),
    WhyNovel(:final tag) => L10n.text('A step outside your usual taste, by way of %@.', [RecapText.tag(tag)]),
    WhySimilar(:final tag) => L10n.text('Close to the work you picked, through %@.', [RecapText.tag(tag)]),
    WhyPopular() => L10n.text('Popular on this site while we learn your taste.'),
  };
}

class WhyTaste extends RecommendationWhy {
  const WhyTaste(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhyTaste && other.tag == tag;
  @override
  int get hashCode => Object.hash('taste', tag);
}

class WhyRecent extends RecommendationWhy {
  const WhyRecent(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhyRecent && other.tag == tag;
  @override
  int get hashCode => Object.hash('recent', tag);
}

class WhyHidden extends RecommendationWhy {
  const WhyHidden(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhyHidden && other.tag == tag;
  @override
  int get hashCode => Object.hash('hidden', tag);
}

class WhyComeback extends RecommendationWhy {
  const WhyComeback(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhyComeback && other.tag == tag;
  @override
  int get hashCode => Object.hash('comeback', tag);
}

class WhyPair extends RecommendationWhy {
  const WhyPair(this.first, this.second);
  final String first;
  final String second;
  @override
  bool operator ==(Object other) => other is WhyPair && other.first == first && other.second == second;
  @override
  int get hashCode => Object.hash('pair', first, second);
}

class WhyPerson extends RecommendationWhy {
  const WhyPerson(this.name, this.role, this.count);
  final String name;
  final RecapRole role;
  final int count;
  @override
  bool operator ==(Object other) => other is WhyPerson && other.name == name && other.role == role && other.count == count;
  @override
  int get hashCode => Object.hash('person', name, role, count);
}

class WhyNovel extends RecommendationWhy {
  const WhyNovel(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhyNovel && other.tag == tag;
  @override
  int get hashCode => Object.hash('novel', tag);
}

class WhySimilar extends RecommendationWhy {
  const WhySimilar(this.tag);
  final String tag;
  @override
  bool operator ==(Object other) => other is WhySimilar && other.tag == tag;
  @override
  int get hashCode => Object.hash('similar', tag);
}

class WhyPopular extends RecommendationWhy {
  const WhyPopular();
  @override
  bool operator ==(Object other) => other is WhyPopular;
  @override
  int get hashCode => 'popular'.hashCode;
}

enum RecommendationFactorKind { tag, person, boosted, reduced, fresh }

/// One line of the explanation sheet. `strength` is relative within a work.
class RecommendationFactor {
  const RecommendationFactor({required this.kind, required this.name, required this.key, required this.strength});
  final RecommendationFactorKind kind;
  final String name;
  final String key;
  final double strength;
  String get id => kind.name + key;
}

class TasteLearnedTag {
  TasteLearnedTag({required this.source, required this.name, required this.weight, this.saves = 0, this.recent = 0});
  String source;
  String name;

  /// Recency-weighted evidence. Saves count most, then finished and long views.
  double weight;
  int saves;
  int recent;
  String get id => TasteControl.tagKey(source: source, tag: name);
}

class TasteLearnedPerson {
  TasteLearnedPerson({required this.source, required this.name, required this.role, required this.weight, this.saves = 0});
  String source;
  String name;
  RecapRole role;
  double weight;
  int saves;
  String get id => role.name + TasteControl.tagKey(source: source, tag: name);
  String get query {
    final spoken = name.replaceAll(' ', '_');
    return source == MangaUrls.source ? '${role.name}:$spoken' : spoken;
  }

  String get key => TasteControl.tagKey(source: source, tag: query);
}

enum TasteShelfKind { recent, person, pair, hidden, comeback }

/// A named row of the Smart tab. Every shelf states why it exists.
class TasteShelfPlan {
  const TasteShelfPlan({required this.kind, required this.source, required this.seed, required this.why});
  final TasteShelfKind kind;
  final String source;
  final TasteTag seed;
  final RecommendationWhy why;
  String get id => kind.name + seed.id;
  String get title => switch (why) {
    WhyRecent(:final tag) || WhyHidden(:final tag) => RecapText.tag(tag),
    WhyPerson(:final name) => RecapText.capitalized(RecapText.tag(name)),
    WhyPair(:final first, :final second) => '${RecapText.tag(first)} × ${RecapText.tag(second)}',
    WhyComeback(:final tag) => L10n.text('Back to %@', [RecapText.tag(tag)]),
    _ => why.label,
  };
}

/// What the app has learned, rebuilt from history on every refresh. Nothing here
/// is sent anywhere, and every number traces back to events the person can delete.
class TasteLearning {
  /// Taste moves. A save loses half its pull every six weeks.
  static const halfLife = 45.0;

  final tags = <String, TasteLearnedTag>{};
  List<TasteLearnedPerson> people = [];
  List<(TasteLearnedTag first, TasteLearnedTag second, int count)> pairs = [];
  final seen = <String>{};
  final dismissed = <String>{};
  final _penalties = <String, double>{};
  final _personOf = <String, List<TasteLearnedPerson>>{};
  final Map<String, int> _boosts;
  final int level;
  double _peak = 1;
  int _libraryCount = 0;

  int get discoverySlots => const [1, 3, 5][level];

  TasteLearning({required RecapIndex index, required TasteControl control, DateTime? now})
    : _boosts = {...?control.tasteBoosts},
      level = math.min(2, math.max(0, control.discoveryLevel ?? 1)) {
    final clock = unixSecondsOf(now ?? DateTime.now());
    double decay(double at) => math.pow(0.5, math.max(0, clock - at) / 86400 / halfLife).toDouble();
    final persons = <String, TasteLearnedPerson>{};
    final active = <String, RecapIndexEntry>{};
    final together = <String, int>{};
    final restored = <String>{};
    final savedCredit = <String, (double, bool)>{};
    void credit(RecapIndexEntry entry, double amount, {required bool saved}) {
      for (final name in entry.tags) {
        final key = TasteControl.tagKey(source: entry.item.source, tag: name);
        final tag = tags[key] ??= TasteLearnedTag(source: entry.item.source, name: name, weight: 0);
        tag.weight += amount;
        if (saved) {
          tag.saves += 1;
          if (clock - entry.at < 30 * 86400) tag.recent += 1;
        }
      }
      final info = index.library[entry.key];
      if (info == null) return;
      void credited(String name, RecapRole role) {
        if (const {'anonymous', 'unknown', 'original'}.contains(TasteTagPolicy.normalize(name))) return;
        final id = role.name + TasteControl.tagKey(source: entry.item.source, tag: name);
        final person = persons[id] ??= TasteLearnedPerson(source: entry.item.source, name: name, role: role, weight: 0);
        person.weight += amount;
        if (saved) person.saves += 1;
      }

      for (final name in info.artists) {
        credited(name, RecapRole.artist);
      }
      for (final name in info.series) {
        credited(name, RecapRole.series);
      }
      for (final name in info.characters) {
        credited(name, RecapRole.character);
      }
    }

    for (final entry in index.entries) {
      final fade = decay(entry.at);
      switch (entry.kind) {
        case TasteEventKind.save:
          final amount = (entry.context.preferenceAction ? 1 : 0.7) * fade;
          credit(entry, amount, saved: true);
          savedCredit[entry.key] = (amount, clock - entry.at < 30 * 86400);
          active[entry.key] = entry;
          if (clock - entry.at < 120 * 86400) {
            final names = entry.tags.take(16).toList();
            for (var offset = 0; offset < names.length; offset++) {
              for (final second in names.skip(offset + 1)) {
                final key = '${entry.item.source}\n${names[offset]}\n$second';
                together[key] = (together[key] ?? 0) + 1;
              }
            }
          }
        case TasteEventKind.seed || TasteEventKind.imported:
          // A library arriving all at once says little about today.
          final amount = 0.2 * math.max(fade, 0.25);
          credit(entry, amount, saved: true);
          active[entry.key] = entry;
          savedCredit[entry.key] = (amount, clock - entry.at < 30 * 86400);
        case TasteEventKind.remove:
          // Unsaving takes back exactly what the save gave.
          final earlier = savedCredit.remove(entry.key);
          if (earlier != null) {
            credit(entry, -earlier.$1, saved: false);
            for (final name in entry.tags) {
              final tag = tags[TasteControl.tagKey(source: entry.item.source, tag: name)];
              if (tag == null) continue;
              tag.saves -= 1;
              if (earlier.$2) tag.recent -= 1;
            }
          }
          active.remove(entry.key);
        case TasteEventKind.open:
          if (entry.signal == TasteSignal.dismissed.name) {
            dismissed.add(entry.key);
            restored.remove(entry.key);
            for (final name in entry.tags) {
              final key = TasteControl.tagKey(source: entry.item.source, tag: name);
              _penalties[key] = (_penalties[key] ?? 0) + 0.35 * fade;
            }
          } else if (entry.signal == TasteSignal.restored.name) {
            restored.add(entry.key);
            dismissed.remove(entry.key);
            for (final name in entry.tags) {
              final key = TasteControl.tagKey(source: entry.item.source, tag: name);
              _penalties[key] = (_penalties[key] ?? 0) - 0.35 * fade;
            }
          } else {
            seen.add(entry.key);
            final dwell = entry.dwell;
            if (dwell != null && dwell.seconds >= 20) {
              credit(entry, (math.min(1, dwell.seconds / 240) * 0.6 + (dwell.finished ? 0.3 : 0)) * fade, saved: false);
            }
          }
        default:
          break;
      }
    }
    _peak = tags.isEmpty ? 1 : math.max(1, tags.values.map((tag) => tag.weight).reduce(math.max));
    people = persons.values.where((person) => person.saves >= 2).toList()
      ..sort((a, b) => a.weight == b.weight ? a.id.compareTo(b.id) : b.weight.compareTo(a.weight));
    for (final person in people) {
      _personOf.putIfAbsent(TasteControl.tagKey(source: person.source, tag: TasteTagPolicy.normalize(person.name)), () => []).add(person);
      _personOf.putIfAbsent(TasteControl.tagKey(source: person.source, tag: TasteTagPolicy.normalize(person.query)), () => []).add(person);
    }
    _libraryCount = active.length;
    final total = math.max(1, active.length).toDouble();
    final found = <(TasteLearnedTag, TasteLearnedTag, int)>[];
    for (final MapEntry(:key, value: count) in together.entries) {
      final parts = key.split('\n');
      if (count < 3 || parts.length != 3) continue;
      final first = tags[TasteControl.tagKey(source: parts[0], tag: parts[1])], second = tags[TasteControl.tagKey(source: parts[0], tag: parts[2])];
      if (first == null || second == null) continue;
      // A tag on everything pairs with everything; lift keeps the meaningful ones.
      final lift = count * total / (math.max(1, first.saves) * math.max(1, second.saves));
      if (lift >= 1.2 && math.max(first.saves, second.saves) * 5 < active.length * 4 + 5) found.add((first, second, count));
    }
    pairs = found..sort((a, b) => a.$3 == b.$3 ? (a.$1.id + a.$2.id).compareTo(b.$1.id + b.$2.id) : b.$3.compareTo(a.$3));
  }

  static double unixSecondsOf(DateTime date) => date.microsecondsSinceEpoch / 1e6;

  int boost(String key) => _boosts[key] ?? 0;
  bool isMuted(TasteTag tag) => boost(tag.id) < 0;
  double seedWeight(TasteTag tag) => (tags[tag.id]?.weight ?? 0) + boost(tag.id) * 2 * _peak;

  /// Tags known but rarely saved: the near edge of a person's taste.
  List<TasteTag> fringe(String source) =>
      (tags.values.where((tag) => tag.source == source && tag.saves >= 1 && tag.saves <= 3 && boost(tag.id) >= 0).toList()
            ..sort((a, b) => a.weight == b.weight ? a.id.compareTo(b.id) : b.weight.compareTo(a.weight)))
          .take(6)
          .map((tag) => TasteTag(source: tag.source, name: tag.name, general: tag.saves))
          .toList();

  /// Credits have their own shelf, and a tag on nearly everything says nothing.
  bool _isDistinct(TasteLearnedTag tag) => _personOf[tag.id] == null && tag.saves * 5 < _libraryCount * 4 + 5;

  List<TasteLearnedTag> get recentTags => tags.values.where((tag) => tag.recent >= 2 && boost(tag.id) >= 0 && _isDistinct(tag)).toList()
    ..sort((first, second) {
      final a = first.recent / math.max(3, first.saves), b = second.recent / math.max(3, second.saves);
      return a == b ? first.id.compareTo(second.id) : b.compareTo(a);
    });

  List<TasteLearnedTag> get dormantTags =>
      tags.values.where((tag) => tag.saves >= 5 && tag.recent == 0 && boost(tag.id) >= 0 && _isDistinct(tag)).toList()
        ..sort((a, b) => a.saves == b.saves ? a.id.compareTo(b.id) : b.saves.compareTo(a.saves));

  /// Strongest first, for the tuner and the focus row.
  List<TasteLearnedTag> ranked([String? source]) =>
      tags.values.where((tag) => (source == null || tag.source == source) && tag.weight > 0 && _personOf[tag.id] == null).toList()
        ..sort((a, b) => a.weight == b.weight ? a.id.compareTo(b.id) : b.weight.compareTo(a.weight));

  /// Shelves rotate daily so the page has something new without a refresh.
  List<TasteShelfPlan> shelves({required List<String> sources, required List<TasteTag> tags, required int offset, int limit = 4}) {
    TasteTag tag(TasteLearnedTag learned) => TasteTag(source: learned.source, name: learned.name, general: learned.saves);
    final allowed = sources.toSet();
    final pool = <List<TasteShelfPlan>>[
      recentTags
          .where((value) => allowed.contains(value.source))
          .take(4)
          .map((value) => TasteShelfPlan(kind: TasteShelfKind.recent, source: value.source, seed: tag(value), why: WhyRecent(value.name)))
          .toList(),
      people
          .where((person) => allowed.contains(person.source) && boost(person.key) >= 0)
          .take(5)
          .map(
            (person) => TasteShelfPlan(
              kind: TasteShelfKind.person,
              source: person.source,
              seed: TasteTag(source: person.source, name: person.query, general: person.saves),
              why: WhyPerson(person.name, person.role, person.saves),
            ),
          )
          .toList(),
      pairs
          .where((pair) => allowed.contains(pair.$1.source))
          .take(4)
          .map(
            (pair) => TasteShelfPlan(
              kind: TasteShelfKind.pair,
              source: pair.$1.source,
              seed: TasteTag(source: pair.$1.source, name: '${pair.$1.name} ${pair.$2.name}', general: pair.$3),
              why: WhyPair(pair.$1.name, pair.$2.name),
            ),
          )
          .toList(),
      tags
          .where((value) => value.discovery && allowed.contains(value.source))
          .take(3)
          .map((value) => TasteShelfPlan(kind: TasteShelfKind.hidden, source: value.source, seed: value, why: WhyHidden(value.name)))
          .toList(),
      dormantTags
          .where((value) => allowed.contains(value.source))
          .take(4)
          .map((value) => TasteShelfPlan(kind: TasteShelfKind.comeback, source: value.source, seed: tag(value), why: WhyComeback(value.name)))
          .toList(),
    ];
    final start = math.max(0, offset);
    final seenSeeds = <String>{};
    final result = <TasteShelfPlan>[];
    for (var index = 0; index < pool.length; index++) {
      final family = pool[(index + start) % pool.length];
      if (family.isEmpty) continue;
      final plan = family[start % family.length];
      if (seenSeeds.add(plan.seed.id)) result.add(plan);
      if (result.length == limit) break;
    }
    return result;
  }

  /// Reranks one candidate and records the facts behind its score. The profile
  /// score stays the base, so personal learning sharpens it without replacing it.
  TasteRecommendation personalize(TasteRecommendation candidate, {RecommendationWhy? why}) {
    final result = candidate.copy();
    final source = candidate.item.source;
    final names = candidate.rankingTags ?? candidate.item.eligibleTags.toSet();
    final factors = <RecommendationFactor>[];
    var affinity = 0.0, penalty = 0.0, known = 0, explicit = 0.0;
    TasteLearnedPerson? credited;
    for (final name in names) {
      final key = TasteControl.tagKey(source: source, tag: name);
      final learned = tags[key];
      if (learned != null && learned.weight > 0) {
        known += 1;
        affinity += math.min(learned.weight, _peak);
        if (_personOf[key] == null) {
          factors.add(RecommendationFactor(kind: RecommendationFactorKind.tag, name: name, key: key, strength: learned.weight / _peak));
        }
      }
      final person = _personOf[key]?.firstOrNull;
      if (person != null && (credited == null || person.weight > credited.weight)) credited = person;
      final steered = _boosts[key] ?? 0;
      if (steered != 0) {
        explicit += steered > 0 ? 0.3 : -0.6;
        factors.add(
          RecommendationFactor(kind: steered > 0 ? RecommendationFactorKind.boosted : RecommendationFactorKind.reduced, name: name, key: key, strength: 1),
        );
      }
      penalty += _penalties[key] ?? 0;
    }
    final spread = math.sqrt(math.max(1, names.length));
    final novelty = names.isEmpty ? 0.0 : 1 - known / names.length;
    result.novel = names.isNotEmpty && novelty >= 0.6;
    final reach = (level - 1) * 0.3 * novelty;
    result.score = candidate.score + 0.6 * affinity / _peak / spread + (credited == null ? 0 : 0.2) + explicit - 0.5 * penalty / spread + reach;
    if (credited != null) {
      factors.add(
        RecommendationFactor(kind: RecommendationFactorKind.person, name: credited.name, key: credited.key, strength: math.min(1, credited.weight / _peak)),
      );
    }
    factors.sort((a, b) => a.strength == b.strength ? a.id.compareTo(b.id) : b.strength.compareTo(a.strength));
    result
      ..factors = factors.take(6).toList()
      ..why = why ?? _explanation(candidate, credited, novel: result.novel);
    return result;
  }

  RecommendationWhy _explanation(TasteRecommendation candidate, TasteLearnedPerson? credited, {required bool novel}) {
    final seed = candidate.reason;
    if (seed.name.isEmpty) return const WhyPopular();
    if (credited != null && credited.saves >= 3) return WhyPerson(credited.name, credited.role, credited.saves);
    if (seed.discovery) return WhyHidden(seed.name);
    if (novel) return WhyNovel(seed.name);
    final learned = tags[seed.id];
    if (learned != null && learned.recent >= 2 && learned.recent * 3 >= learned.saves) return WhyRecent(seed.name);
    return WhyTaste(seed.name);
  }
}
