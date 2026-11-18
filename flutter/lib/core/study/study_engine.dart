import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../booru/booru_models.dart';
import '../taste/taste_models.dart';
import 'study_models.dart';

/// What a study round covers.
sealed class StudyScope {
  const StudyScope();

  /// Tags that are due again first, then tags not met yet.
  static const today = StudyToday();

  /// Only tags that are due again.
  static const review = StudyReview();
  const factory StudyScope.unit(String id) = StudyUnitScope;

  /// Chosen tags, such as the ones on a picture being viewed.
  const factory StudyScope.tags(List<String> names) = StudyTagsScope;
}

class StudyToday extends StudyScope {
  const StudyToday();
  @override
  bool operator ==(Object other) => other is StudyToday;
  @override
  int get hashCode => 1;
}

class StudyReview extends StudyScope {
  const StudyReview();
  @override
  bool operator ==(Object other) => other is StudyReview;
  @override
  int get hashCode => 2;
}

class StudyUnitScope extends StudyScope {
  const StudyUnitScope(this.id);
  final String id;
  @override
  bool operator ==(Object other) => other is StudyUnitScope && other.id == id;
  @override
  int get hashCode => Object.hash(3, id);
}

class StudyTagsScope extends StudyScope {
  const StudyTagsScope(this.names);
  final List<String> names;
  @override
  bool operator ==(Object other) => other is StudyTagsScope && listEquals(other.names, names);
  @override
  int get hashCode => Object.hash(4, Object.hashAll(names));
}

/// `Swift.shuffled(using:)`: a copy in random order.
List<T> shuffledWith<T>(Iterable<T> items, Random random) => [...items]..shuffle(random);

/// A sort that keeps equal elements in their order, as Swift's does.
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.indexed.toList()
    ..sort((a, b) {
      final order = compare(a.$2, b.$2);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  return [for (final entry in indexed) entry.$2];
}

/// Chooses what to ask and builds the questions. It holds no state and reads no clock or server,
/// so the same inputs always give the same round.
class StudyEngine {
  StudyEngine({StudyCurriculum? curriculum}) : curriculum = curriculum ?? StudyCurriculum.bundled;
  final StudyCurriculum curriculum;
  static const roundSize = 10;

  // MARK: Round

  /// The tags of a round, in the order they are asked.
  List<StudyTag> round(StudyScope scope, {required Map<String, StudyProgress> progress, int count = roundSize, required DateTime now, required Random random}) {
    final List<StudyTag> candidates;
    switch (scope) {
      case StudyToday() || StudyReview():
        candidates = curriculum.tags;
      case StudyUnitScope(:final id):
        candidates = curriculum.unit(id)?.tags ?? [];
      case StudyTagsScope(:final names):
        final seen = <String>{};
        candidates = [
          for (final name in names)
            if (seen.add(name)) ?curriculum.tag(name),
        ];
    }
    // Longest overdue first, so that a tag about to be forgotten is not pushed out by newer ones.
    final due = _stableSorted(
      candidates.where((tag) => progress[tag.name]?.isDue(now) == true),
      (a, b) => (progress[a.name]?.due ?? now).compareTo(progress[b.name]?.due ?? now),
    );
    if (scope is StudyReview) return due.take(count).toList();
    final fresh = candidates.where((tag) => progress[tag.name]?.isNew ?? true).toList();
    var chosen = due.take(count).toList();
    // New tags come in curriculum order, a few per round, so that reviews are never crowded out entirely.
    final room = scope is StudyToday ? max(count - chosen.length, min(3, count)) : count - chosen.length;
    chosen = [...chosen.take(max(0, count - min(room, fresh.length))), ...fresh.take(max(0, room))];
    if (chosen.length < count) {
      // A unit or a picture's tags can be practised again before anything is due: least known first.
      final taken = {for (final tag in chosen) tag.name};
      final rest = _stableSorted(
        shuffledWith(candidates.where((tag) => !taken.contains(tag.name)), random),
        (a, b) => (progress[a.name]?.step ?? 0).compareTo(progress[b.name]?.step ?? 0),
      );
      if (scope is! StudyToday) chosen = [...chosen, ...rest.take(count - chosen.length)];
    }
    return chosen.take(count).toList();
  }

  // MARK: Pictures

  /// A still picture that can be shown small: no video, animation or removed post.
  static bool usable(BooruPost post) => !post.isRemoved && !post.isVideo && !post.isAnimated && (post.previewURL ?? post.sampleURL) != null;

  /// Whether a picture is a fair example of a tag: it carries the tag, and where the tag's group
  /// allows one answer only, it carries no other tag of that group.
  bool teaches(BooruPost post, StudyTag tag) {
    if (!post.tags.contains(tag.name)) return false;
    final group = curriculum.groupOf(tag.name);
    if (group == null || !group.exclusive) return true;
    final tags = post.tags.toSet();
    return !group.tags.any((other) => other.name != tag.name && tags.contains(other.name));
  }

  // MARK: Wrong answers

  /// Tags to offer beside the right one: the ones learners mix up first, then others answering the same question.
  List<StudyTag> distractors(StudyTag tag, {int count = 3, Set<String> excluding = const {}, required Random random}) {
    final chosen = <StudyTag>[];
    final taken = {...excluding, tag.name};
    void take(Iterable<StudyTag> candidates) {
      for (final candidate in shuffledWith(candidates, random)) {
        if (chosen.length < count && taken.add(candidate.name)) chosen.add(candidate);
      }
    }

    take([for (final name in tag.confusable ?? const <String>[]) ?curriculum.tag(name)]);
    take(curriculum.groupOf(tag.name)?.tags ?? const []);
    take(curriculum.unitOf(tag.name)?.tags ?? const []);
    if (chosen.length < count) take(curriculum.tags);
    return chosen;
  }

  // MARK: Questions

  /// A question for a tag from the pictures at hand. Without a fair picture it asks by meaning,
  /// so a round never stops for want of a server.
  StudyQuestion? question(StudyTag tag, {required List<BooruPost> pool, Set<StudyQuestionKind>? kinds, required Random random}) {
    final allowed = kinds ?? StudyQuestionKind.values.toSet();
    final group = curriculum.groupOf(tag.name);
    final visual = group?.visual ?? true;
    final examples = visual ? pool.where((post) => teaches(post, tag)).toList() : <BooruPost>[];
    BooruPost? randomExample() => examples.isEmpty ? null : examples[random.nextInt(examples.length)];
    if (allowed.contains(StudyQuestionKind.tagToPicture)) {
      final right = randomExample();
      if (right != null && random.nextInt(3) == 0) {
        // A wrong picture carries a neighbouring tag and not the asked one; a picture merely lacking the tag may only be under-tagged.
        final siblings = {for (final other in group?.tags ?? const <StudyTag>[]) other.name}..remove(tag.name);
        final seen = {right.id};
        final wrong = [
          for (final post in shuffledWith(pool, random))
            if (!post.tags.contains(tag.name) && post.tags.any(siblings.contains) && seen.add(post.id)) post,
        ].take(3).toList();
        if (wrong.length == 3) {
          final posts = shuffledWith([right, ...wrong], random);
          return StudyQuestion(kind: StudyQuestionKind.tagToPicture, tag: tag, posts: posts, answer: max(0, posts.indexWhere((post) => post.id == right.id)));
        }
      }
    }
    if (allowed.contains(StudyQuestionKind.pictureToTag)) {
      final post = randomExample();
      if (post != null) {
        final wrong = distractors(tag, excluding: post.tags.toSet(), random: random);
        if (wrong.length >= 2) {
          final choices = shuffledWith([tag, ...wrong], random);
          return StudyQuestion(kind: StudyQuestionKind.pictureToTag, tag: tag, choices: choices, posts: [post], answer: max(0, choices.indexOf(tag)));
        }
      }
    }
    if (!allowed.contains(StudyQuestionKind.meaningToTag)) return null;
    final wrong = distractors(tag, random: random);
    if (wrong.isEmpty) return null;
    final choices = shuffledWith([tag, ...wrong], random);
    return StudyQuestion(kind: StudyQuestionKind.meaningToTag, tag: tag, choices: choices, answer: max(0, choices.indexOf(tag)));
  }
}

/// Turns a picture's tags into the text image generators are prompted with.
abstract final class StudyPrompt {
  /// A tag as prompts write it. Underscores become spaces, except in emoticons such as `^_^` and `>_<`.
  static String words(String tag) {
    final letters = tag.runes.where((rune) => _alphanumeric.hasMatch(String.fromCharCode(rune))).length;
    return letters <= 1 || tag.characters.length <= 3 ? tag : tag.replaceAll('_', ' ');
  }

  /// Letters, marks and numbers, as `CharacterSet.alphanumerics` holds them.
  static final _alphanumeric = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true);

  /// The headcount tags that prompts conventionally open with.
  static const leading = {
    '1girl', '2girls', '3girls', '4girls', '5girls', '6+girls', 'multiple_girls', '1boy', '2boys', '3boys', '4boys', '5boys', '6+boys', //
    'multiple_boys', '1other', '2others', 'multiple_others', 'no_humans', 'solo',
  };

  /// The tags in prompt order: headcount, characters, series, then what the picture shows. Bookkeeping tags are left out.
  static List<String> ordered(BooruPost post, {bool artists = false}) {
    final categories = post.tagCategories ?? const <String, int>{};
    final meta = (post.metadataTags ?? const <String>[]).toSet();
    final count = <String>[], characters = <String>[], series = <String>[], names = <String>[], general = <String>[];
    final seen = <String>{};
    for (final tag in post.tags) {
      if (!seen.add(tag)) continue;
      if (meta.contains(tag) || categories[tag] == 5 || TasteTagPolicy.technical.contains(tag)) continue;
      if (post.artists.contains(tag) || categories[tag] == 1) {
        names.add(tag);
      } else if (categories[tag] == 4) {
        characters.add(tag);
      } else if (categories[tag] == 3) {
        series.add(tag);
      } else if (leading.contains(tag)) {
        count.add(tag);
      } else {
        general.add(tag);
      }
    }
    return [...count, ...characters, ...series, if (artists) ...names, ...general];
  }

  static String text(List<String> tags, {required StudyPromptStyle style}) => switch (style) {
    StudyPromptStyle.tags => tags.join(' '),
    StudyPromptStyle.natural => tags.map(words).join(', '),
    StudyPromptStyle.escaped => tags.map((tag) => words(tag).replaceAll('(', r'\(').replaceAll(')', r'\)')).join(', '),
  };
}

/// How a prompt is written.
enum StudyPromptStyle {
  /// Words apart and commas between tags.
  natural,

  /// As `natural`, with brackets escaped for tools that read them as emphasis.
  escaped,

  /// The tags as the server writes them, ready to search with.
  tags;

  String get rawValue => name;
  String get id => name;
}
