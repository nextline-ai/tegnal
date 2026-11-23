import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../booru/booru_client.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../lab/lab_store.dart';
import '../support/l10n.dart';
import '../support/preferences.dart';
import '../support/swift_json.dart';
import 'study_awards.dart';
import 'study_engine.dart';
import 'study_models.dart';
import 'study_session.dart';
import 'study_store.dart';

// MARK: - The path

StudyText _text(Object? value) => jsonObject(value).map((language, text) => MapEntry(language, jsonString(text)));
bool _sameText(StudyText a, StudyText b) => mapEquals(a, b);
bool _sameTexts(List<StudyText> a, List<StudyText> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) _sameText(a[i], b[i])].every((same) => same);
int _textHash(StudyText text) => Object.hashAllUnordered([for (final entry in text.entries) Object.hash(entry.key, entry.value)]);
int _textsHash(List<StudyText> texts) => Object.hashAll(texts.map(_textHash));

/// What a lesson of the path is: an idea explained from nothing, a handful of new tags, or a prompt to put together.
enum StudyPathLessonKind {
  concept,
  tags,
  boss;

  String get rawValue => name;
}

/// Something told before anything is asked.
class StudyPathCard {
  const StudyPathCard({required this.title, required this.body, this.code, this.symbol, this.pose, this.action});
  final StudyText title;
  final StudyText body;

  /// Prompt text shown as it would be typed.
  final String? code;

  /// An SF Symbol standing in until the card has a drawing of its own.
  final String? symbol;

  /// How the guide stands while telling it: `wave`, `cheer`, `think`, `sad`, `read`, `close-up` or `full-body`.
  final String? pose;

  /// A thing to do from the card: `civitai` opens the account page, `key` the API key sheet, `generator` the generator with the card's code as its prompt.
  final String? action;

  factory StudyPathCard.fromJson(JsonObject json) => StudyPathCard(
    title: json.dictionary('title', jsonString),
    body: json.dictionary('body', jsonString),
    code: json.stringOrNull('code'),
    symbol: json.stringOrNull('symbol'),
    pose: json.stringOrNull('pose'),
    action: json.stringOrNull('action'),
  );

  @override
  bool operator ==(Object other) =>
      other is StudyPathCard &&
      _sameText(other.title, title) &&
      _sameText(other.body, body) &&
      other.code == code &&
      other.symbol == symbol &&
      other.pose == pose &&
      other.action == action;
  @override
  int get hashCode => Object.hash(_textHash(title), _textHash(body), code, symbol, pose, action);
}

class StudyPathAsk {
  const StudyPathAsk({required this.question, required this.choices, required this.answer, required this.why, this.code});
  final StudyText question;
  final List<StudyText> choices;
  final int answer;
  final StudyText why;

  /// True when the choices are prompt text, set in a fixed-width face.
  final bool? code;

  factory StudyPathAsk.fromJson(JsonObject json) => StudyPathAsk(
    question: json.dictionary('question', jsonString),
    choices: json.list('choices', _text),
    answer: json.integer('answer'),
    why: json.dictionary('why', jsonString),
    code: json.booleanOrNull('code'),
  );

  /// The same question with its choices in a new order.
  StudyPathAsk shuffled(Random random) {
    final order = shuffledWith(List.generate(choices.length, (index) => index), random);
    final position = order.indexOf(answer);
    return StudyPathAsk(question: question, choices: [for (final index in order) choices[index]], answer: position < 0 ? answer : position, why: why, code: code);
  }

  @override
  bool operator ==(Object other) =>
      other is StudyPathAsk && _sameText(other.question, question) && _sameTexts(other.choices, choices) && other.answer == answer && _sameText(other.why, why) && other.code == code;
  @override
  int get hashCode => Object.hash(_textHash(question), _textsHash(choices), answer, _textHash(why), code);
}

/// A picture described in words, to be ordered as a prompt from a bank of tags.
class StudyPathBuild {
  const StudyPathBuild({required this.brief, required this.answer, required this.extras});
  final StudyText brief;

  /// The tags the prompt needs, as servers write them.
  final List<String> answer;

  /// Tags that do not belong, offered beside the right ones.
  final List<String> extras;

  factory StudyPathBuild.fromJson(JsonObject json) =>
      StudyPathBuild(brief: json.dictionary('brief', jsonString), answer: json.strings('answer'), extras: json.strings('extras'));

  @override
  bool operator ==(Object other) => other is StudyPathBuild && _sameText(other.brief, brief) && listEquals(other.answer, answer) && listEquals(other.extras, extras);
  @override
  int get hashCode => Object.hash(_textHash(brief), Object.hashAll(answer), Object.hashAll(extras));
}

/// Things to put in the order they happen. `items` is the right order.
class StudyPathOrder {
  const StudyPathOrder({required this.brief, required this.items, required this.why});
  final StudyText brief;
  final List<StudyText> items;
  final StudyText why;

  factory StudyPathOrder.fromJson(JsonObject json) =>
      StudyPathOrder(brief: json.dictionary('brief', jsonString), items: json.list('items', _text), why: json.dictionary('why', jsonString));

  @override
  bool operator ==(Object other) => other is StudyPathOrder && _sameText(other.brief, brief) && _sameTexts(other.items, items) && _sameText(other.why, why);
  @override
  int get hashCode => Object.hash(_textHash(brief), _textsHash(items), _textHash(why));
}

class StudyPathSortItem {
  const StudyPathSortItem({required this.text, required this.right});
  final StudyText text;

  /// True when it belongs in the right-hand bucket.
  final bool right;

  factory StudyPathSortItem.fromJson(JsonObject json) => StudyPathSortItem(text: json.dictionary('text', jsonString), right: json.boolean('right'));

  @override
  bool operator ==(Object other) => other is StudyPathSortItem && _sameText(other.text, text) && other.right == right;
  @override
  int get hashCode => Object.hash(_textHash(text), right);
}

/// Things to drop into one of two buckets, one at a time.
class StudyPathSort {
  const StudyPathSort({required this.brief, required this.left, required this.right, required this.items, required this.why});
  final StudyText brief;
  final StudyText left;
  final StudyText right;
  final List<StudyPathSortItem> items;
  final StudyText why;

  factory StudyPathSort.fromJson(JsonObject json) => StudyPathSort(
    brief: json.dictionary('brief', jsonString),
    left: json.dictionary('left', jsonString),
    right: json.dictionary('right', jsonString),
    items: json.list('items', (value) => StudyPathSortItem.fromJson(jsonObject(value))),
    why: json.dictionary('why', jsonString),
  );

  @override
  bool operator ==(Object other) =>
      other is StudyPathSort &&
      _sameText(other.brief, brief) &&
      _sameText(other.left, left) &&
      _sameText(other.right, right) &&
      listEquals(other.items, items) &&
      _sameText(other.why, why);
  @override
  int get hashCode => Object.hash(_textHash(brief), _textHash(left), _textHash(right), Object.hashAll(items), _textHash(why));
}

/// A step is exactly one of a card, a question, a prompt to build, things to order or things to sort.
class StudyPathStep {
  const StudyPathStep({this.card, this.ask, this.build, this.order, this.sort});
  final StudyPathCard? card;
  final StudyPathAsk? ask;
  final StudyPathBuild? build;
  final StudyPathOrder? order;
  final StudyPathSort? sort;

  factory StudyPathStep.fromJson(JsonObject json) => StudyPathStep(
    card: json.objectOrNull('card') == null ? null : StudyPathCard.fromJson(json.object('card')),
    ask: json.objectOrNull('ask') == null ? null : StudyPathAsk.fromJson(json.object('ask')),
    build: json.objectOrNull('build') == null ? null : StudyPathBuild.fromJson(json.object('build')),
    order: json.objectOrNull('order') == null ? null : StudyPathOrder.fromJson(json.object('order')),
    sort: json.objectOrNull('sort') == null ? null : StudyPathSort.fromJson(json.object('sort')),
  );

  @override
  bool operator ==(Object other) => other is StudyPathStep && other.card == card && other.ask == ask && other.build == build && other.order == order && other.sort == sort;
  @override
  int get hashCode => Object.hash(card, ask, build, order, sort);
}

/// One stop on the learning path.
class StudyPathLesson {
  const StudyPathLesson({required this.id, required this.kind, required this.symbol, required this.title, this.summary, this.tags, this.steps});
  final String id;
  final StudyPathLessonKind kind;
  final String symbol;
  final StudyText title;
  final StudyText? summary;

  /// The tags a `tags` lesson teaches, as servers write them.
  final List<String>? tags;

  /// What a `concept` or `boss` lesson shows, in order.
  final List<StudyPathStep>? steps;

  factory StudyPathLesson.fromJson(JsonObject json) {
    final kind = StudyPathLessonKind.values.where((value) => value.name == json.string('kind')).firstOrNull;
    if (kind == null) throw SwiftJsonError('Unknown lesson kind "${json['kind']}"');
    return StudyPathLesson(
      id: json.string('id'),
      kind: kind,
      symbol: json.string('symbol'),
      title: json.dictionary('title', jsonString),
      summary: json.dictionaryOrNull('summary', jsonString),
      tags: json.stringsOrNull('tags'),
      steps: json.listOrNull('steps', (value) => StudyPathStep.fromJson(jsonObject(value))),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StudyPathLesson &&
      other.id == id &&
      other.kind == kind &&
      other.symbol == symbol &&
      _sameText(other.title, title) &&
      (other.summary == null ? summary == null : summary != null && _sameText(other.summary!, summary!)) &&
      listEquals(other.tags, tags) &&
      listEquals(other.steps, steps);
  @override
  int get hashCode => Object.hash(id, kind, symbol, _textHash(title), tags == null ? null : Object.hashAll(tags!), steps == null ? null : Object.hashAll(steps!));
  @override
  String toString() => 'StudyPathLesson($id)';
}

class StudyPathSection {
  const StudyPathSection({required this.id, required this.title, required this.summary, required this.color, this.lessons = const []});
  final String id;
  final StudyText title;
  final StudyText summary;

  /// The section's colour, as six hexadecimal digits.
  final String color;
  final List<StudyPathLesson> lessons;

  factory StudyPathSection.fromJson(JsonObject json) => StudyPathSection(
    id: json.string('id'),
    title: json.dictionary('title', jsonString),
    summary: json.dictionary('summary', jsonString),
    color: json.string('color'),
    lessons: json.listOrNull('lessons', (value) => StudyPathLesson.fromJson(jsonObject(value))) ?? const [],
  );

  @override
  bool operator ==(Object other) =>
      other is StudyPathSection && other.id == id && _sameText(other.title, title) && _sameText(other.summary, summary) && other.color == color && listEquals(other.lessons, lessons);
  @override
  int get hashCode => Object.hash(id, _textHash(title), _textHash(summary), color, Object.hashAll(lessons));
}

/// The learning path: sections of lessons, to be played in order.
class StudyPath {
  const StudyPath({this.version = 2, this.sections = const []});
  final int version;
  final List<StudyPathSection> sections;

  factory StudyPath.fromJson(JsonObject json) => StudyPath(
    version: json.integerOrNull('version') ?? 2,
    sections: json.listOrNull('sections', (value) => StudyPathSection.fromJson(jsonObject(value))) ?? const [],
  );

  /// A path from its file's text; empty when the text cannot be read, as the bundled one is.
  factory StudyPath.parse(String text) {
    try {
      return StudyPath.fromJson(jsonObject(decodeJsonValue(utf8.encode(text))));
    } on SwiftJsonError {
      return const StudyPath();
    }
  }

  static StudyPath? _bundled;

  /// The path shipped with the app; empty until [loadBundled] has finished, and afterwards
  /// only if the file is missing or unreadable.
  static StudyPath get bundled => _bundled ?? const StudyPath();

  /// Reads `assets/study/StudyPath.json` once; later calls return what was read.
  static Future<StudyPath> loadBundled([AssetBundle? bundle]) async {
    final loaded = _bundled;
    if (loaded != null) return loaded;
    try {
      return _bundled = StudyPath.parse(await (bundle ?? rootBundle).loadString('assets/study/StudyPath.json'));
    } on Object {
      return const StudyPath();
    }
  }

  /// The same as [loadBundled].
  static Future<StudyPath> load([AssetBundle? bundle]) => loadBundled(bundle);

  /// Replaces what [bundled] returns, for tests and for previews of another path.
  @visibleForTesting
  static void useBundled(StudyPath? path) => _bundled = path;

  List<StudyPathLesson> get lessons => [for (final section in sections) ...section.lessons];

  /// The lesson the learner is on: the first one not finished from where the placement test put them, then the
  /// first one not finished anywhere. Null once every lesson is done. [placed] counts the lessons the test passed by.
  StudyPathLesson? current(Map<String, StudyLessonRecord> records, {int placed = 0}) {
    final all = lessons;
    return all.skip(placed.clamp(0, all.length)).where((lesson) => records[lesson.id] == null).firstOrNull ??
        all.where((lesson) => records[lesson.id] == null).firstOrNull;
  }

  /// A lesson opens once every lesson before it is finished, or once the placement test has passed it by.
  bool isOpen(StudyPathLesson lesson, Map<String, StudyLessonRecord> records, {int placed = 0}) =>
      records[lesson.id] != null || current(records, placed: placed)?.id == lesson.id || isSkipped(lesson, records, placed: placed);

  /// True for a lesson the placement test passed by that has not been played since.
  bool isSkipped(StudyPathLesson lesson, Map<String, StudyLessonRecord> records, {required int placed}) =>
      records[lesson.id] == null && lessons.take(max(0, placed)).any((other) => other.id == lesson.id);
}

// MARK: - Game state

class StudyLessonRecord {
  const StudyLessonRecord({required this.lesson, required this.stars, required this.runs});
  final String lesson;

  /// One to three: three for a round without a mistake.
  final int stars;
  final int runs;

  @override
  bool operator ==(Object other) => other is StudyLessonRecord && other.lesson == lesson && other.stars == stars && other.runs == runs;
  @override
  int get hashCode => Object.hash(lesson, stars, runs);
  @override
  String toString() => 'StudyLessonRecord($lesson, $stars stars, $runs runs)';
}

/// The numbers the game shows: experience, level, today's goal.
class StudyGame {
  StudyGame({this.xp = 0, this.today = 0, this.goal = defaultGoal});

  /// The totals over [days]: every day's experience, and the experience of the day [now] falls on.
  factory StudyGame.of({required List<StudyDay> days, required int goal, DateTime? now, Duration? utcOffset}) {
    final key = StudyDay.key(now ?? DateTime.now(), utcOffset: utcOffset);
    return StudyGame(
      xp: days.fold(0, (total, day) => total + day.xp),
      today: days.where((day) => day.day == key).firstOrNull?.xp ?? 0,
      goal: goal,
    );
  }

  static const levelSize = 100;
  static const goals = [10, 20, 30, 50];
  static const defaultGoal = 20;
  int xp;
  int today;
  int goal;
  int get level => xp ~/ levelSize + 1;

  /// How far into the current level, from zero to one.
  double get levelProgress => (xp % levelSize) / levelSize;
  double get goalProgress => goal <= 0 ? 1 : min(1, today / goal);
  bool get goalMet => today >= goal;

  /// What a finished round earns: more for no mistakes and for a long run of right answers.
  static int earned({required int mistakes, required int bestCombo}) => 10 + (mistakes == 0 ? 5 : 0) + (bestCombo >= 5 ? 3 : 0);
  static int stars({required int mistakes}) => mistakes == 0 ? 3 : (mistakes <= 2 ? 2 : 1);

  @override
  bool operator ==(Object other) => other is StudyGame && other.xp == xp && other.today == today && other.goal == goal;
  @override
  int get hashCode => Object.hash(xp, today, goal);
  @override
  String toString() => 'StudyGame($xp xp, $today/$goal today)';
}

/// What the learner had before a lesson paid out.
class StudyStanding {
  StudyStanding({this.xp = 0, this.today = 0, this.studiedToday = true});
  int xp;
  int today;

  /// False when this lesson is the day's first study, which is what moves the streak.
  bool studiedToday;

  @override
  bool operator ==(Object other) => other is StudyStanding && other.xp == xp && other.today == today && other.studiedToday == studiedToday;
  @override
  int get hashCode => Object.hash(xp, today, studiedToday);
  @override
  String toString() => 'StudyStanding($xp xp, $today today, studiedToday $studiedToday)';
}

/// What a lesson paid in 보석, and the balance before it: the treasure chest's contents.
class StudyGemReward {
  const StudyGemReward({required this.paid, required this.before});
  final LabTagPayout paid;
  final int before;
  int get after => before + paid.total;

  @override
  bool operator ==(Object other) => other is StudyGemReward && other.paid == paid && other.before == before;
  @override
  int get hashCode => Object.hash(paid, before);
}

/// What a finished lesson is worth celebrating beyond its own results.
sealed class StudyMilestone {
  const StudyMilestone();

  /// 보석 paid by the lesson, opened from a treasure chest. Shown first.
  const factory StudyMilestone.gems(StudyGemReward reward) = StudyGemsMilestone;
  const factory StudyMilestone.streak(int days) = StudyStreakMilestone;
  const factory StudyMilestone.goal(int xp) = StudyGoalMilestone;
  const factory StudyMilestone.level(int level) = StudyLevelMilestone;

  /// A badge earned by this lesson.
  const factory StudyMilestone.award(StudyAward award) = StudyAwardMilestone;

  /// The milestones a lesson reached, in the order they are shown.
  static List<StudyMilestone> reached({required StudyStanding before, required int earned, required int goal, required int streak}) {
    if (earned <= 0) return const [];
    final found = <StudyMilestone>[];
    if (!before.studiedToday && streak > 0) found.add(StudyMilestone.streak(streak));
    if (before.today < goal && before.today + earned >= goal) found.add(StudyMilestone.goal(goal));
    final level = (before.xp + earned) ~/ StudyGame.levelSize + 1;
    if (level > before.xp ~/ StudyGame.levelSize + 1) found.add(StudyMilestone.level(level));
    return found;
  }
}

class StudyGemsMilestone extends StudyMilestone {
  const StudyGemsMilestone(this.reward);
  final StudyGemReward reward;
  @override
  bool operator ==(Object other) => other is StudyGemsMilestone && other.reward == reward;
  @override
  int get hashCode => Object.hash(5, reward);
  @override
  String toString() => 'StudyMilestone.gems(${reward.paid.total})';
}

class StudyStreakMilestone extends StudyMilestone {
  const StudyStreakMilestone(this.days);
  final int days;
  @override
  bool operator ==(Object other) => other is StudyStreakMilestone && other.days == days;
  @override
  int get hashCode => Object.hash(1, days);
  @override
  String toString() => 'StudyMilestone.streak($days)';
}

class StudyGoalMilestone extends StudyMilestone {
  const StudyGoalMilestone(this.xp);
  final int xp;
  @override
  bool operator ==(Object other) => other is StudyGoalMilestone && other.xp == xp;
  @override
  int get hashCode => Object.hash(2, xp);
  @override
  String toString() => 'StudyMilestone.goal($xp)';
}

class StudyLevelMilestone extends StudyMilestone {
  const StudyLevelMilestone(this.level);
  final int level;
  @override
  bool operator ==(Object other) => other is StudyLevelMilestone && other.level == level;
  @override
  int get hashCode => Object.hash(3, level);
  @override
  String toString() => 'StudyMilestone.level($level)';
}

class StudyAwardMilestone extends StudyMilestone {
  const StudyAwardMilestone(this.award);
  final StudyAward award;
  @override
  bool operator ==(Object other) => other is StudyAwardMilestone && other.award == award;
  @override
  int get hashCode => Object.hash(4, award);
  @override
  String toString() => 'StudyMilestone.award(${award.id})';
}

// MARK: - The picture server

/// Learning mode reads pictures from one server. With no server added it is Safebooru; otherwise the learner chooses.
abstract final class StudyServer {
  static const key = 'study.server';

  /// The servers that can be chosen: the learner's own, and Safebooru when it is not among them.
  static List<BooruServer> choices(BooruStore store) {
    final own = store.selectableServers;
    return own.any((server) => server.isSafebooru) ? own : [...own, fallback];
  }

  static final fallback = BooruServer(id: 'safebooru', name: 'Safebooru', baseURL: 'https://${BooruServer.safebooruHost}', engine: BooruEngine.gelbooru);

  static bool _isDanbooruSite(BooruServer server) {
    final host = Uri.tryParse(server.baseURL)?.host ?? '';
    return server.engine == BooruEngine.danbooru && (host == 'donmai.us' || host.endsWith('.donmai.us'));
  }

  /// The one to suggest: Danbooru when it is there, since the tags taught are written its way.
  static BooruServer recommended(List<BooruServer> servers) =>
      servers.where(_isDanbooruSite).firstOrNull ??
      servers.where((server) => server.engine == BooruEngine.danbooru).firstOrNull ??
      servers.where((server) => server.isSafebooru).firstOrNull ??
      servers.firstOrNull ??
      fallback;

  static BooruServer current(BooruStore store, {required Preferences defaults}) {
    final servers = choices(store);
    final id = defaults.string(key);
    if (id != null) {
      final chosen = servers.where((server) => server.id == id).firstOrNull;
      if (chosen != null) return chosen;
    }
    return store.selectableServers.isEmpty ? fallback : recommended(servers);
  }

  /// True while a learner with servers of their own has not said which one to learn from.
  static bool needsChoice(BooruStore store, {required Preferences defaults}) {
    if (store.selectableServers.isEmpty) return false;
    final id = defaults.string(key);
    if (id == null) return true;
    return !choices(store).any((server) => server.id == id);
  }
}

// MARK: - A lesson being played

/// What a step shows.
sealed class StudyStepKind {
  const StudyStepKind();
}

class StudyStepCard extends StudyStepKind {
  const StudyStepCard(this.card);
  final StudyPathCard card;
}

/// A new tag shown with pictures before it is asked.
class StudyStepTeach extends StudyStepKind {
  const StudyStepTeach(this.tag, this.posts);
  final StudyTag tag;
  final List<BooruPost> posts;
}

class StudyStepQuiz extends StudyStepKind {
  const StudyStepQuiz(this.question);
  final StudyQuestion question;
}

class StudyStepAsk extends StudyStepKind {
  const StudyStepAsk(this.ask);
  final StudyPathAsk ask;
}

/// Tags to pair with what they mean.
class StudyStepMatch extends StudyStepKind {
  const StudyStepMatch(this.tags);
  final List<StudyTag> tags;
}

class StudyStepBuild extends StudyStepKind {
  const StudyStepBuild(this.build);
  final StudyPathBuild build;
}

class StudyStepOrder extends StudyStepKind {
  const StudyStepOrder(this.order);
  final StudyPathOrder order;
}

class StudyStepSort extends StudyStepKind {
  const StudyStepSort(this.sort);
  final StudyPathSort sort;
}

/// A picture and four tags, one of which the picture does not carry: the answer.
class StudyStepOdd extends StudyStepKind {
  const StudyStepOdd(this.post, this.choices, this.answer);
  final BooruPost post;
  final List<StudyTag> choices;
  final int answer;
}

/// A tag to type from memory, as a prompt is typed. A picture is shown when there is a fair one.
class StudyStepSpell extends StudyStepKind {
  const StudyStepSpell(this.tag, this.post);
  final StudyTag tag;
  final BooruPost? post;
}

/// One thing shown in a lesson.
class StudyStep {
  StudyStep(this.kind, {this.again = false}) : id = uuidString();
  final String id;
  final StudyStepKind kind;

  /// Asked again because it was missed the first time.
  final bool again;

  /// Cards and new tags are read, not answered.
  bool get isAsked => kind is! StudyStepCard && kind is! StudyStepTeach;
}

sealed class StudyLessonPlan {
  const StudyLessonPlan();

  /// Tags that are due again, with no lesson to finish.
  static const review = StudyReviewPlan();

  /// The tags missed most often, asked again whether or not they are due.
  static const weak = StudyWeakPlan();

  /// The short test, taken at the start, that finds where on the path a learner who already knows some of this begins.
  static const placement = StudyPlacementPlan();
  const factory StudyLessonPlan.lesson(StudyPathLesson lesson) = StudyLessonOfPlan;
  StudyPathLesson? get lesson => null;
}

class StudyLessonOfPlan extends StudyLessonPlan {
  const StudyLessonOfPlan(this.lessonValue);
  final StudyPathLesson lessonValue;
  @override
  StudyPathLesson? get lesson => lessonValue;
  @override
  bool operator ==(Object other) => other is StudyLessonOfPlan && other.lessonValue == lessonValue;
  @override
  int get hashCode => Object.hash(1, lessonValue);
}

class StudyReviewPlan extends StudyLessonPlan {
  const StudyReviewPlan();
  @override
  bool operator ==(Object other) => other is StudyReviewPlan;
  @override
  int get hashCode => 2;
}

class StudyWeakPlan extends StudyLessonPlan {
  const StudyWeakPlan();
  @override
  bool operator ==(Object other) => other is StudyWeakPlan;
  @override
  int get hashCode => 3;
}

class StudyPlacementPlan extends StudyLessonPlan {
  const StudyPlacementPlan();
  @override
  bool operator ==(Object other) => other is StudyPlacementPlan;
  @override
  int get hashCode => 4;
}

enum StudyLessonPhaseKind { loading, asking, feedback, finished }

/// Where a lesson stands: loading, asking, showing whether the answer was right, or done.
class StudyLessonPhase {
  const StudyLessonPhase._(this.kind, [this.right]);
  static const loading = StudyLessonPhase._(StudyLessonPhaseKind.loading);
  static const asking = StudyLessonPhase._(StudyLessonPhaseKind.asking);
  static const finished = StudyLessonPhase._(StudyLessonPhaseKind.finished);
  const StudyLessonPhase.feedback(bool right) : this._(StudyLessonPhaseKind.feedback, right);
  final StudyLessonPhaseKind kind;

  /// Whether the answer was right, while [kind] is `feedback`.
  final bool? right;
  bool get isFeedback => kind == StudyLessonPhaseKind.feedback;

  @override
  bool operator ==(Object other) => other is StudyLessonPhase && other.kind == kind && other.right == right;
  @override
  int get hashCode => Object.hash(kind, right);
  @override
  String toString() => right == null ? 'StudyLessonPhase.${kind.name}' : 'StudyLessonPhase.${kind.name}($right)';
}

class StudyLessonSession extends ChangeNotifier {
  StudyLessonSession({
    required this.plan,
    required this.store,
    required this.source,
    required this.server,
    StudyEngine? engine,
    Random? random,
    DateTime Function()? now,
    this.utcOffset,
  }) : engine = engine ?? StudyEngine(),
       _random = random ?? Random(),
       _now = now ?? DateTime.now,
       id = uuidString();

  static const reviewSize = 8;

  final String id;
  final StudyLessonPlan plan;
  final BooruStore store;
  final BooruProviding source;
  final BooruServer server;
  final StudyEngine engine;

  /// The zone days are counted in, for tests; the device's own when null.
  final Duration? utcOffset;
  final Random _random;
  final DateTime Function() _now;

  var _steps = <StudyStep>[];
  var _index = 0;
  var _phase = StudyLessonPhase.loading;
  var _combo = 0;
  var _bestCombo = 0;
  var _mistakes = 0;
  var _asked = 0;
  var _earned = 0;
  var _stars = 0;
  final _builtPictures = <StudyPathBuild, BooruPost>{};
  var _tags = <StudyTag>[];
  final _before = StudyStanding();
  var _disposed = false;

  /// The section each placement question checks, by the question's step id.
  final _checks = <String, int>{};
  int? _stoppedAt;
  var _placed = 0;

  List<StudyStep> get steps => List.unmodifiable(_steps);
  int get index => _index;
  StudyLessonPhase get phase => _phase;
  int get combo => _combo;
  int get bestCombo => _bestCombo;
  int get mistakes => _mistakes;
  int get asked => _asked;
  int get earned => _earned;

  /// The 보석 this lesson paid — a 2D AI 배우기 lesson finished, or finished with three stars, for the first time, and the
  /// section it finished — with the balance before, for the treasure chest after the results. Null when it paid nothing.
  StudyGemReward? get gems => _gems;
  StudyGemReward? _gems;
  int get stars => _stars;

  /// Pictures that fit the prompts built in this lesson, by the build's brief.
  Map<StudyPathBuild, BooruPost> get builtPictures => Map.unmodifiable(_builtPictures);

  /// The tags met in this lesson, for the summary at its end.
  List<StudyTag> get tags => List.unmodifiable(_tags);

  /// Where the learner stood before this lesson paid out, so that its end can celebrate what changed.
  StudyStanding get before => _before;

  bool get isPlacement => plan is StudyPlacementPlan;

  /// The section the placement test stopped at: the first one whose question was missed.
  int? get stoppedAt => _stoppedAt;

  /// How many lessons the placement test passed by.
  int get placed => _placed;

  StudyStep? get step => _index >= 0 && _index < _steps.length ? _steps[_index] : null;

  /// From zero to one, counting a missed step's second asking as part of the lesson.
  double get progress => _steps.isEmpty ? 0 : (_index + (_phase.isFeedback ? 1 : 0)) / _steps.length;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Map<String, StudyProgress> _progress() {
    try {
      return store.studyStore.progress();
    } on Object {
      return {};
    }
  }

  List<StudyDay> _days() {
    try {
      return store.studyStore.days();
    } on Object {
      return [];
    }
  }

  Future<void> start() async {
    if (_steps.isNotEmpty || _phase != StudyLessonPhase.loading) return;
    final today = StudyDay.key(_now(), utcOffset: utcOffset);
    _before.studiedToday = _days().where((day) => day.day == today).firstOrNull?.isStudied ?? false;
    switch (plan) {
      case StudyPlacementPlan():
        for (final question in StudyPlacement.questions(StudyPath.bundled, curriculum: engine.curriculum, random: _random)) {
          final step = StudyStep(StudyStepAsk(question.ask));
          _checks[step.id] = question.section;
          _steps.add(step);
        }
      case StudyReviewPlan():
        final progress = _progress();
        _tags = engine.round(StudyScope.review, progress: progress, count: reviewSize, now: _now(), random: _random);
        final pool = await _pictures(_tags);
        _steps = _questions(_tags, pool, twice: false);
        if (_tags.length >= 4) _steps.insert(_steps.length ~/ 2, StudyStep(StudyStepMatch(_tags.take(4).toList())));
        final odd = _odd(_tags, pool);
        if (odd != null) _steps.add(odd);
        // Typing is the last and hardest recall, kept for tags already answered right a few times.
        for (final tag in shuffledWith(_tags.where((tag) => (progress[tag.name]?.step ?? 0) >= 2), _random).take(2)) {
          _steps.add(_spell(tag, pool));
        }
      case StudyWeakPlan():
        final progress = _progress();
        _tags = weakest(progress, curriculum: engine.curriculum, count: reviewSize);
        final pool = await _pictures(_tags);
        _steps = _questions(_tags, pool, twice: false);
        if (_tags.length >= 4) _steps.insert(_steps.length ~/ 2, StudyStep(StudyStepMatch(_tags.take(4).toList())));
        _steps.addAll(_questions(shuffledWith(_tags, _random), pool, twice: true));
      case StudyLessonOfPlan(:final lessonValue):
        switch (lessonValue.kind) {
          case StudyPathLessonKind.tags:
            _tags = [for (final name in lessonValue.tags ?? const <String>[]) ?engine.curriculum.tag(name)];
            final pool = await _pictures(_tags);
            // Each new tag is shown, then asked at once; then all of them are mixed and asked again.
            for (final tag in _tags) {
              _steps.add(StudyStep(StudyStepTeach(tag, pool.where((post) => engine.teaches(post, tag)).take(3).toList())));
              final question = engine.question(tag, pool: pool, random: _random);
              if (question != null) _steps.add(StudyStep(StudyStepQuiz(_familiar(question))));
            }
            if (_tags.length >= 4) _steps.add(StudyStep(StudyStepMatch(shuffledWith(_tags, _random).take(4).toList())));
            final odd = _odd(_tags, pool);
            if (odd != null) _steps.add(odd);
            _steps.addAll(_questions(shuffledWith(_tags, _random), pool, twice: true));
            // The lesson ends with one of its tags typed out, the way a prompt is written.
            if (_tags.isNotEmpty) _steps.add(_spell(_tags[_random.nextInt(_tags.length)], pool));
          case StudyPathLessonKind.concept || StudyPathLessonKind.boss:
            for (final step in lessonValue.steps ?? const <StudyPathStep>[]) {
              if (step.card != null) _steps.add(StudyStep(StudyStepCard(step.card!)));
              if (step.ask != null) _steps.add(StudyStep(StudyStepAsk(step.ask!.shuffled(_random))));
              if (step.build != null) _steps.add(StudyStep(StudyStepBuild(step.build!)));
              if (step.order != null) _steps.add(StudyStep(StudyStepOrder(step.order!)));
              if (step.sort != null) _steps.add(StudyStep(StudyStepSort(step.sort!)));
            }
            final builds = [for (final step in lessonValue.steps ?? const <StudyPathStep>[]) ?step.build];
            final names = {for (final build in builds) ...build.answer}.toList()..sort();
            _tags = [for (final name in names) ?engine.curriculum.tag(name)];
            await _picture(builds);
        }
    }
    if (_steps.isEmpty) {
      _finish();
    } else {
      _phase = StudyLessonPhase.asking;
    }
    _changed();
  }

  List<StudyStep> _questions(List<StudyTag> tags, List<BooruPost> pool, {required bool twice}) {
    final used = <String>{};
    final steps = <StudyStep>[];
    for (final tag in tags) {
      // A second asking prefers a picture not shown the first time.
      final fresh = pool.where((post) => !used.contains(post.id)).toList();
      final question = engine.question(tag, pool: twice ? fresh : pool, random: _random) ?? engine.question(tag, pool: pool, random: _random);
      if (question == null) continue;
      used.addAll(question.posts.map((post) => post.id));
      steps.add(StudyStep(StudyStepQuiz(_familiar(question))));
    }
    return steps;
  }

  /// The tags answered wrong most often, worst first. A tag never missed is not weak.
  static List<StudyTag> weakest(Map<String, StudyProgress> progress, {required StudyCurriculum curriculum, required int count}) {
    final missed = progress.values.where((value) => value.wrong > 0).toList()
      ..sort((first, second) {
        // By the share of answers missed, then by how many, then by name so that the order is steady.
        final left = first.wrong * (second.correct + second.wrong), right = second.wrong * (first.correct + first.wrong);
        if (left != right) return left > right ? -1 : 1;
        if (first.wrong != second.wrong) return first.wrong > second.wrong ? -1 : 1;
        return first.tag.compareTo(second.tag);
      });
    return [for (final value in missed) ?curriculum.tag(value.tag)].take(max(0, count)).toList();
  }

  /// A picture with three tags it carries and one of the lesson's tags it does not. Null when no picture gives a fair one.
  StudyStep? _odd(List<StudyTag> tags, List<BooruPost> pool) {
    for (final post in shuffledWith(pool, _random)) {
      final carried = post.tags.toSet();
      final shown = shuffledWith(tags.where((tag) => carried.contains(tag.name)), _random);
      for (final name in shuffledWith(post.tags, _random)) {
        if (shown.length >= 3) break;
        final tag = engine.curriculum.tag(name);
        if (tag != null && !shown.contains(tag) && (engine.curriculum.groupOf(name)?.visual ?? true)) shown.add(tag);
      }
      if (shown.length < 3) continue;
      // A tag from a group the picture already answers (its hair is long, so not short) is surely absent;
      // any other missing tag may only have been left off by whoever tagged the picture.
      final absent = tags.where((tag) => !carried.contains(tag.name)).toList();
      final sure = absent.where((tag) => (engine.curriculum.groupOf(tag.name)?.tags ?? const <StudyTag>[]).any((other) => carried.contains(other.name))).toList();
      final candidates = sure.isEmpty ? absent : sure;
      if (candidates.isEmpty) continue;
      final missing = candidates[_random.nextInt(candidates.length)];
      final choices = shuffledWith([...shown.take(3), missing], _random);
      return StudyStep(StudyStepOdd(post, choices, max(0, choices.indexOf(missing))));
    }
    return null;
  }

  StudyStep _spell(StudyTag tag, List<BooruPost> pool) {
    final visual = engine.curriculum.groupOf(tag.name)?.visual ?? true;
    final fair = visual ? pool.where((post) => engine.teaches(post, tag)).toList() : <BooruPost>[];
    return StudyStep(StudyStepSpell(tag, fair.isEmpty ? null : fair[_random.nextInt(fair.length)]));
  }

  /// Whether a typed tag is the one asked for. Spaces and underscores are the same thing, and case does not matter.
  static bool spelled(String typed, StudyTag tag) {
    String plain(String text) => text.toLowerCase().replaceAll('_', ' ').split(' ').where((word) => word.isNotEmpty).join(' ');
    return plain(typed).isNotEmpty && plain(typed) == plain(tag.name);
  }

  /// The same question offering, beside the right tag, tags the learner has met: the lesson's own before any other.
  /// A tag the picture also carries is never offered as a wrong answer.
  StudyQuestion _familiar(StudyQuestion question) {
    if (question.kind == StudyQuestionKind.tagToPicture || question.choices.length <= 1) return question;
    final shown = (question.posts.firstOrNull?.tags ?? const <String>[]).toSet();
    bool fair(StudyTag tag) => tag.name != question.tag.name && !shown.contains(tag.name);
    final wrong = shuffledWith(_tags.where(fair), _random);
    for (final tag in question.choices) {
      if (fair(tag) && !wrong.contains(tag)) wrong.add(tag);
    }
    final choices = shuffledWith([...wrong.take(question.choices.length - 1), question.tag], _random);
    return StudyQuestion(kind: question.kind, tag: question.tag, choices: choices, posts: question.posts, answer: max(0, choices.indexOf(question.tag)));
  }

  /// Example pictures for every tag of the lesson, read side by side so that the wait is one request long.
  Future<List<BooruPost>> _pictures(List<StudyTag> tags) async {
    final visual = tags.where((tag) => engine.curriculum.groupOf(tag.name)?.visual ?? true);
    final batches = await Future.wait([for (final tag in visual) StudyLookup.examples(tag.name, store: store, source: source, server: server, random: _random)]);
    final seen = <String>{};
    return [
      for (final posts in batches)
        for (final post in posts)
          if (seen.add(post.id)) post,
    ];
  }

  /// A picture carrying every tag of a built prompt, to show what the prompt asks for.
  Future<void> _picture(List<StudyPathBuild> builds) async {
    for (final build in builds) {
      if (build.answer.isEmpty) continue;
      // The least common tag narrows the search most; headcount tags are on nearly every picture.
      final query = build.answer.lastWhere((tag) => !StudyPrompt.leading.contains(tag), orElse: () => build.answer.last);
      final posts = await StudyLookup.examples(query, store: store, source: source, server: server, random: _random);
      final fit = posts.where((post) => build.answer.every(post.tags.toSet().contains)).firstOrNull;
      if (fit != null) _builtPictures[build] = fit;
    }
  }

  /// Whether a prompt built from a bank of tags is right: the tags asked for and no others, with the headcount first.
  static bool judge(List<String> chosen, StudyPathBuild build) {
    if (chosen.length != build.answer.length || !chosen.toSet().containsAll(build.answer) || chosen.toSet().length != build.answer.toSet().length) return false;
    final first = chosen.indexWhere((tag) => !StudyPrompt.leading.contains(tag));
    final firstOther = first < 0 ? chosen.length : first;
    return !chosen.sublist(firstOther).any(StudyPrompt.leading.contains);
  }

  /// Whether things were put in their right order. Items that read the same may swap places.
  static bool judgeOrder(List<StudyText> chosen, StudyPathOrder order) => _sameTexts(chosen, order.items);

  /// Moves past a card or a new tag.
  void proceed() {
    final current = step;
    if (_phase != StudyLessonPhase.asking || current == null || current.isAsked) return;
    _advance();
  }

  /// Records an answer. [tag] names the tag asked about, so that its review date moves.
  void answer(bool right, {String? tag}) {
    final current = step;
    if (_phase != StudyLessonPhase.asking || current == null || !current.isAsked) return;
    _asked += 1;
    if (right) {
      _combo += 1;
      _bestCombo = max(_bestCombo, _combo);
    } else {
      _combo = 0;
      _mistakes += 1;
    }
    if (isPlacement) {
      // The test stops at the first section it finds unknown; nothing is asked again and no tag is scheduled.
      if (!right) _stoppedAt ??= _checks[current.id];
      _phase = StudyLessonPhase.feedback(right);
      _changed();
      return;
    }
    if (!current.again) {
      if (tag != null) {
        try {
          store.studyStore.answer(tag, right: right, now: _now(), utcOffset: utcOffset);
        } on Object {
          // An answer that cannot be saved still counts for this lesson.
        }
      }
      // A missed step comes back once, at the end.
      if (!right) _steps.add(StudyStep(current.kind, again: true));
    }
    _phase = StudyLessonPhase.feedback(right);
    _changed();
  }

  void next() {
    if (!_phase.isFeedback) return;
    _advance();
  }

  void _advance() {
    _index += 1;
    if (_index >= _steps.length || (isPlacement && _stoppedAt != null)) {
      _finish();
    } else {
      _phase = StudyLessonPhase.asking;
    }
    _changed();
  }

  void _finish() {
    if (_phase == StudyLessonPhase.finished) return;
    _phase = StudyLessonPhase.finished;
    if (isPlacement) {
      // The test earns no experience; it only says where the path begins.
      _placed = StudyPlacement.skipped(StudyPath.bundled, stoppedAt: _stoppedAt);
      try {
        if (_placed > 0) store.studyStore.raise(StudyPlacement.counter, _placed);
      } on Object {
        // Without the record the learner starts at the beginning.
      }
      return;
    }
    if (!(_asked > 0 || plan.lesson != null)) return;
    _stars = StudyGame.stars(mistakes: _mistakes);
    _earned = StudyGame.earned(mistakes: _mistakes, bestCombo: _bestCombo);
    final days = _days();
    final today = StudyDay.key(_now(), utcOffset: utcOffset);
    _before.xp = days.fold(0, (total, day) => total + day.xp);
    _before.today = days.where((day) => day.day == today).firstOrNull?.xp ?? 0;
    try {
      store.studyStore.raise(StudyCounter.combo, _bestCombo);
      store.studyStore.earn(_earned, lesson: plan.lesson?.id, stars: _stars, now: _now(), utcOffset: utcOffset);
    } on Object {
      // The result is still shown when it cannot be saved.
    }
    if (plan.lesson != null) {
      final before = LabStore.shared.balance;
      final paid = LabStore.shared.settleTagCourse(store.studyStore);
      if (paid.total > 0) _gems = StudyGemReward(paid: paid, before: before);
    }
  }
}

// MARK: - Placement

/// One question of the placement test, and the section of the path it checks.
class StudyPlacementQuestion {
  const StudyPlacementQuestion({required this.section, required this.ask});
  final int section;
  final StudyPathAsk ask;
}

/// The short test a learner can take when learning mode first opens: one question for each section, in the path's
/// order, ending at the first one missed. The lessons before that section are passed by: open, but not finished.
abstract final class StudyPlacement {
  /// The counter (in `study_stats`) holding how many lessons at the start of the main path the test passed by.
  /// Counters only go up, travel in sync and backups, and are cleared by a reset.
  static const counter = 'placed';

  /// Set on this device once the welcome has been gone through; cleared when progress is reset.
  static const welcomedKey = 'study.welcomed';

  /// One question for each section: one of the section's own questions, or, for a section that only teaches tags,
  /// which of a lesson's tags a meaning names, with the lesson's other tags as the wrong answers.
  static List<StudyPlacementQuestion> questions(StudyPath path, {required StudyCurriculum curriculum, String? language, required Random random}) {
    final lang = language ?? L10n.language;
    final questions = <StudyPlacementQuestion>[];
    for (final (index, section) in path.sections.indexed) {
      final asks = [
        for (final lesson in section.lessons)
          for (final step in lesson.steps ?? const <StudyPathStep>[]) ?step.ask,
      ];
      if (asks.isNotEmpty) {
        questions.add(StudyPlacementQuestion(section: index, ask: asks[random.nextInt(asks.length)].shuffled(random)));
        continue;
      }
      final taught = [
        for (final lesson in section.lessons)
          if (lesson.kind == StudyPathLessonKind.tags) [for (final name in lesson.tags ?? const <String>[]) ?curriculum.tag(name)],
      ].where((tags) => tags.length >= 2).toList();
      if (taught.isEmpty) continue;
      final tags = taught[random.nextInt(taught.length)];
      final tag = tags[random.nextInt(tags.length)];
      final choices = shuffledWith([tag, ...shuffledWith(tags.where((other) => other != tag), random).take(3)], random);
      // Tags are never translated in a question; what they mean is, as in a match step.
      final meaning = lang == 'en' ? tag.note.resolved(lang) : tag.title(lang);
      questions.add(
        StudyPlacementQuestion(
          section: index,
          ask: StudyPathAsk(
            question: {'en': L10n.text('Which tag fits “%@”?', [meaning])},
            choices: [
              for (final choice in choices) {'en': choice.english},
            ],
            answer: choices.indexOf(tag),
            why: {'en': '`${tag.english}` · ${tag.note.resolved(lang)}'},
            code: true,
          ),
        ),
      );
    }
    return questions;
  }

  /// How many lessons come before the section the test stopped at. With nothing missed the learner begins at the last section.
  static int skipped(StudyPath path, {required int? stoppedAt}) {
    if (path.sections.isEmpty) return 0;
    final target = min(stoppedAt ?? path.sections.length - 1, path.sections.length - 1);
    return path.sections.take(max(0, target)).fold(0, (total, section) => total + section.lessons.length);
  }

  /// The section the learner begins at after passing [placed] lessons by.
  static StudyPathSection? section(StudyPath path, {required int placed}) {
    if (placed <= 0) return path.sections.firstOrNull;
    var count = 0;
    for (final section in path.sections) {
      if (count >= placed) return section;
      count += section.lessons.length;
    }
    return path.sections.lastOrNull;
  }

  /// True while learning mode should greet the learner: never welcomed on this device, and nothing played or placed yet.
  static bool needsWelcome({required Map<String, StudyLessonRecord> records, required int xp, required int placed, required Preferences defaults}) =>
      !(defaults.boolean(welcomedKey) ?? false) && records.isEmpty && xp == 0 && placed == 0;
}
