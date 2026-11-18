import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../booru/booru_models.dart';
import '../support/l10n.dart';
import '../support/swift_json.dart';
import 'study_engine.dart';

/// Text the curriculum carries in each app language, keyed "en", "ko" and "ja".
typedef StudyText = Map<String, String>;

extension StudyTextResolved on StudyText {
  /// The wording for the app language, or English where a translation is missing.
  String resolved([String? language]) => this[language ?? L10n.language] ?? this['en'] ?? '';
}

bool _sameText(StudyText a, StudyText b) => mapEquals(a, b);

/// A tag the curriculum teaches: the server's own tag name, how it is called in each language and what it means.
class StudyTag {
  const StudyTag({required this.name, this.ko, this.ja, required this.note, this.confusable});
  final String name;
  final String? ko;
  final String? ja;
  final StudyText note;
  final List<String>? confusable;
  String get id => name;

  /// The tag as prompts write it: words apart, except emoticons such as `^_^`, which stay whole.
  String get english => StudyPrompt.words(name);

  /// The name in the app language; English reads the tag itself.
  String title([String? language]) => switch (language ?? L10n.language) {
    'ko' => ko ?? english,
    'ja' => ja ?? english,
    _ => english,
  };

  factory StudyTag.fromJson(JsonObject json) => StudyTag(
    name: json.string('name'),
    ko: json.stringOrNull('ko'),
    ja: json.stringOrNull('ja'),
    note: json.dictionary('note', jsonString),
    confusable: json.stringsOrNull('confusable'),
  );

  @override
  bool operator ==(Object other) =>
      other is StudyTag && other.name == name && other.ko == ko && other.ja == ja && _sameText(other.note, note) && listEquals(other.confusable, confusable);
  @override
  int get hashCode => Object.hash(name, ko, ja, confusable == null ? null : Object.hashAll(confusable!));
  @override
  String toString() => 'StudyTag($name)';
}

/// Tags that answer one question about a picture, such as how long the hair is.
class StudyGroup {
  const StudyGroup({required this.id, required this.title, this.exclusive = false, this.visual = true, required this.tags});
  final String id;
  final StudyText title;

  /// The group's tags rarely apply to one picture together, so the others make fair wrong answers.
  final bool exclusive;

  /// False where a tag cannot be told by looking at the picture; such tags are asked by meaning only.
  final bool visual;
  final List<StudyTag> tags;

  factory StudyGroup.fromJson(JsonObject json) => StudyGroup(
    id: json.string('id'),
    title: json.dictionary('title', jsonString),
    exclusive: json.booleanOrNull('exclusive') ?? false,
    visual: json.booleanOrNull('visual') ?? true,
    tags: json.list('tags', (value) => StudyTag.fromJson(jsonObject(value))),
  );

  @override
  bool operator ==(Object other) =>
      other is StudyGroup &&
      other.id == id &&
      _sameText(other.title, title) &&
      other.exclusive == exclusive &&
      other.visual == visual &&
      listEquals(other.tags, tags);
  @override
  int get hashCode => Object.hash(id, exclusive, visual, Object.hashAll(tags));
}

class StudyUnit {
  const StudyUnit({required this.id, required this.title, required this.summary, required this.groups});
  final String id;
  final StudyText title;
  final StudyText summary;
  final List<StudyGroup> groups;
  List<StudyTag> get tags => [for (final group in groups) ...group.tags];

  /// Symbols are chosen in the app, so the curriculum file stays the same on every platform.
  /// These are the SF Symbol names the iOS app uses; screens map them to their own icons.
  String get symbol => switch (id) {
    'count' => 'person.2',
    'framing' => 'crop',
    'angle' => 'camera',
    'pose' => 'figure.stand',
    'expression' => 'face.smiling',
    'hair' => 'comb',
    'face' => 'eye',
    'body' => 'pawprint',
    'outfit' => 'tshirt',
    'legwear' => 'shoe',
    'accessory' => 'eyeglasses',
    'scene' => 'mountain.2',
    'light' => 'sun.max',
    'style' => 'paintbrush.pointed',
    'meta' => 'doc.text',
    _ => 'tag',
  };

  factory StudyUnit.fromJson(JsonObject json) => StudyUnit(
    id: json.string('id'),
    title: json.dictionary('title', jsonString),
    summary: json.dictionary('summary', jsonString),
    groups: json.list('groups', (value) => StudyGroup.fromJson(jsonObject(value))),
  );

  @override
  bool operator ==(Object other) =>
      other is StudyUnit && other.id == id && _sameText(other.title, title) && _sameText(other.summary, summary) && listEquals(other.groups, groups);
  @override
  int get hashCode => Object.hash(id, Object.hashAll(groups));
}

/// The tags the app teaches without asking a server, in the order they are learned.
class StudyCurriculum {
  StudyCurriculum({this.version = 1, required this.units}) : _index = _indexOf(units);

  final int version;
  final List<StudyUnit> units;
  final Map<String, ({int unit, int group, int tag})> _index;

  static Map<String, ({int unit, int group, int tag})> _indexOf(List<StudyUnit> units) {
    final places = <String, ({int unit, int group, int tag})>{};
    for (final (u, unit) in units.indexed) {
      for (final (g, group) in unit.groups.indexed) {
        for (final (t, tag) in group.tags.indexed) {
          places.putIfAbsent(tag.name, () => (unit: u, group: g, tag: t));
        }
      }
    }
    return places;
  }

  factory StudyCurriculum.fromJson(JsonObject json) =>
      StudyCurriculum(version: json.integer('version'), units: json.list('units', (value) => StudyUnit.fromJson(jsonObject(value))));

  /// A curriculum from its file's text; empty when the text cannot be read, as the bundled one is.
  factory StudyCurriculum.parse(String text) {
    try {
      return StudyCurriculum.fromJson(jsonObject(decodeJsonValue(utf8.encode(text))));
    } on SwiftJsonError {
      return empty;
    }
  }

  List<StudyTag> get tags => [for (final unit in units) ...unit.tags];
  int get count => _index.length;
  bool contains(String name) => _index.containsKey(name);
  StudyTag? tag(String name) => _index[name].let((place) => units[place.unit].groups[place.group].tags[place.tag]);
  StudyGroup? groupOf(String name) => _index[name].let((place) => units[place.unit].groups[place.group]);
  StudyUnit? unitOf(String name) => _index[name].let((place) => units[place.unit]);
  StudyUnit? unit(String id) {
    for (final unit in units) {
      if (unit.id == id) return unit;
    }
    return null;
  }

  /// The tags of a post that the curriculum teaches, in curriculum order.
  List<StudyTag> taughtIn(BooruPost post) {
    final found = [
      for (final (position, name) in post.tags.indexed)
        if (_index[name] case final place?) (position, name, place),
    ];
    // Ties keep the order the post lists its tags in, as Swift's sort does in practice.
    found.sort((a, b) {
      final left = a.$3, right = b.$3;
      final order = left.unit != right.unit
          ? left.unit.compareTo(right.unit)
          : left.group != right.group
          ? left.group.compareTo(right.group)
          : left.tag.compareTo(right.tag);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    return [for (final entry in found) tag(entry.$2)!];
  }

  static final empty = StudyCurriculum(units: const []);
  static StudyCurriculum? _bundled;

  /// The curriculum shipped with the app; empty until [loadBundled] has finished, and afterwards
  /// only if the file is missing or unreadable.
  static StudyCurriculum get bundled => _bundled ?? empty;

  /// Reads `assets/study/TagStudy.json` once; later calls return what was read.
  static Future<StudyCurriculum> loadBundled([AssetBundle? bundle]) async {
    final loaded = _bundled;
    if (loaded != null) return loaded;
    try {
      return _bundled = StudyCurriculum.parse(await (bundle ?? rootBundle).loadString('assets/study/TagStudy.json'));
    } on Object {
      return empty;
    }
  }

  /// Replaces what [bundled] returns, for tests and for previews of another curriculum.
  @visibleForTesting
  static void useBundled(StudyCurriculum? curriculum) => _bundled = curriculum;
}

extension _Let<T> on T? {
  R? let<R>(R Function(T value) transform) {
    final value = this;
    return value == null ? null : transform(value);
  }
}

/// What a server knows about a tag: how many posts carry it and what kind of tag it is.
class StudyRelatedTag {
  const StudyRelatedTag({required this.name, required this.category, required this.count, required this.frequency});
  final String name;
  final int category;
  final int count;

  /// The share of the asked tag's posts that also carry this one, from 0 to 1.
  final double frequency;
  String get id => name;

  factory StudyRelatedTag.fromJson(JsonObject json) =>
      StudyRelatedTag(name: json.string('name'), category: json.integer('category'), count: json.integer('count'), frequency: json.number('frequency'));
  JsonObject toJson() => {'name': name, 'category': category, 'count': count, 'frequency': frequency};

  @override
  bool operator ==(Object other) =>
      other is StudyRelatedTag && other.name == name && other.category == category && other.count == count && other.frequency == frequency;
  @override
  int get hashCode => Object.hash(name, category, count, frequency);
}

/// A server's own page about a tag, kept as the server wrote it.
class StudyWiki {
  const StudyWiki({required this.title, required this.body, required this.otherNames});
  final String title;
  final String body;

  /// Other names for the tag, often in Japanese, Chinese or Korean.
  final List<String> otherNames;

  factory StudyWiki.fromJson(JsonObject json) => StudyWiki(title: json.string('title'), body: json.string('body'), otherNames: json.strings('otherNames'));
  JsonObject toJson() => {'title': title, 'body': body, 'otherNames': otherNames};

  @override
  bool operator ==(Object other) => other is StudyWiki && other.title == title && other.body == body && listEquals(other.otherNames, otherNames);
  @override
  int get hashCode => Object.hash(title, body, Object.hashAll(otherNames));
}

/// Everything read from a server about one tag, kept on the device until it goes stale.
class StudyTagInfo {
  StudyTagInfo({required this.name, this.count, this.category, this.wiki, required this.related, required DateTime fetched, required this.complete})
    : fetched = fetched.toUtc();
  final String name;
  final int? count;
  final int? category;
  final StudyWiki? wiki;
  final List<StudyRelatedTag> related;
  final DateTime fetched;

  /// False while only the post count is known, read together with a whole unit's counts.
  final bool complete;
  static const lifetime = Duration(days: 14);
  bool isStale([DateTime? now]) => (now ?? DateTime.now()).difference(fetched) > lifetime;

  /// As Swift's synthesized `Codable` writes it, `fetched` being seconds since 2001.
  factory StudyTagInfo.fromJson(JsonObject json) => StudyTagInfo(
    name: json.string('name'),
    count: json.integerOrNull('count'),
    category: json.integerOrNull('category'),
    wiki: json.objectOrNull('wiki') == null ? null : StudyWiki.fromJson(json.object('wiki')),
    related: json.list('related', (value) => StudyRelatedTag.fromJson(jsonObject(value))),
    fetched: dateFromSwiftReferenceSeconds(json.number('fetched')),
    complete: json.boolean('complete'),
  );
  JsonObject toJson() => {
    'name': name,
    'count': ?count,
    'category': ?category,
    'wiki': ?wiki?.toJson(),
    'related': [for (final tag in related) tag.toJson()],
    'fetched': swiftReferenceSeconds(fetched),
    'complete': complete,
  };

  @override
  bool operator ==(Object other) =>
      other is StudyTagInfo &&
      other.name == name &&
      other.count == count &&
      other.category == category &&
      other.wiki == wiki &&
      listEquals(other.related, related) &&
      other.fetched == fetched &&
      other.complete == complete;
  @override
  int get hashCode => Object.hash(name, count, category, wiki, Object.hashAll(related), fetched, complete);
}

/// How well one tag is known. A right answer moves it up a step and a wrong one starts it over.
class StudyProgress {
  StudyProgress({required this.tag, this.step = 0, DateTime? due, this.correct = 0, this.wrong = 0, DateTime? seen})
    : due = (due ?? distantPast).toUtc(),
      seen = (seen ?? distantPast).toUtc();
  final String tag;
  final int step;
  final DateTime due;
  final int correct;
  final int wrong;
  final DateTime seen;
  String get id => tag;

  /// `Date.distantPast`: the year 1 in UTC.
  static final distantPast = DateTime.fromMillisecondsSinceEpoch(-62135769600000, isUtc: true);
  static const lastStep = 6;

  /// Days until the tag is asked again after reaching each step.
  static const intervals = <double>[0, 1, 2, 4, 8, 16, 32];
  static const learnedStep = 4;
  bool get isLearned => step >= learnedStep;
  bool get isNew => correct + wrong == 0;
  bool isDue(DateTime now) => !isNew && !due.isAfter(now);

  /// The progress after one more answer.
  StudyProgress answered(bool right, {required DateTime now}) {
    if (right) {
      final next = min(lastStep, step + 1);
      return StudyProgress(
        tag: tag,
        step: next,
        due: now.add(Duration(microseconds: (intervals[next] * 86400 * 1e6).round())),
        correct: correct + 1,
        wrong: wrong,
        seen: now,
      );
    }
    return StudyProgress(tag: tag, step: 0, due: now.add(const Duration(minutes: 10)), correct: correct, wrong: wrong + 1, seen: now);
  }

  @override
  bool operator ==(Object other) =>
      other is StudyProgress &&
      other.tag == tag &&
      other.step == step &&
      other.due == due &&
      other.correct == correct &&
      other.wrong == wrong &&
      other.seen == seen;
  @override
  int get hashCode => Object.hash(tag, step, due, correct, wrong, seen);
  @override
  String toString() => 'StudyProgress($tag, step $step, $correct right, $wrong wrong)';
}

/// One day's answers, for the streak and the day's total.
class StudyDay {
  const StudyDay({required this.day, this.answered = 0, this.correct = 0});

  /// The local calendar day as `yyyy-MM-dd`.
  final String day;
  final int answered;
  final int correct;
  String get id => day;

  /// The day [date] falls on in the device's time zone, or in the zone [utcOffset] from UTC when given.
  static String key(DateTime date, {Duration? utcOffset}) {
    final local = utcOffset == null ? date.toLocal() : date.toUtc().add(utcOffset);
    return '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  factory StudyDay.fromJson(JsonObject json) => StudyDay(day: json.string('day'), answered: json.integer('answered'), correct: json.integer('correct'));
  JsonObject toJson() => {'day': day, 'answered': answered, 'correct': correct};

  @override
  bool operator ==(Object other) => other is StudyDay && other.day == day && other.answered == answered && other.correct == correct;
  @override
  int get hashCode => Object.hash(day, answered, correct);
  @override
  String toString() => 'StudyDay($day, $correct/$answered)';
}

enum StudyQuestionKind {
  /// A picture is shown; choose the tag it carries.
  pictureToTag,

  /// A tag is shown; choose the picture that carries it.
  tagToPicture,

  /// A meaning is shown; choose the tag.
  meaningToTag;

  String get rawValue => name;
}

class StudyQuestion {
  StudyQuestion({required this.kind, required this.tag, this.choices = const [], this.posts = const [], required this.answer}) : id = uuidString();
  final String id;
  final StudyQuestionKind kind;
  final StudyTag tag;

  /// The tags offered; pictures are offered instead when [kind] is `tagToPicture`.
  final List<StudyTag> choices;

  /// One picture for `pictureToTag`, or one per choice for `tagToPicture`.
  final List<BooruPost> posts;
  final int answer;
  int get choiceCount => kind == StudyQuestionKind.tagToPicture ? posts.length : choices.length;

  /// How answer choices share lines: two neighbours no longer than [limit] characters sit side by side,
  /// anything longer keeps its own line.
  static List<List<int>> rows(List<int> lengths, {required int limit}) {
    final rows = <List<int>>[];
    var index = 0;
    while (index < lengths.length) {
      if (index + 1 < lengths.length && lengths[index] <= limit && lengths[index + 1] <= limit) {
        rows.add([index, index + 1]);
        index += 2;
      } else {
        rows.add([index]);
        index += 1;
      }
    }
    return rows;
  }
}
