import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../support/l10n.dart';

// The AI lab's scripts: `assets/lab/course.json` beside `assets/lab/episodes/<id>.json`, the same files the iOS app
// carries in `AILab/`. Ported from `LabCourse.swift`.

/// Text in a lab script. A script may write it as one string, as a list of lines, or per language
/// (`{"ko": …, "en": …}`, each a string or a list of lines). Plain text is the script's own language and is shown in
/// every language until a translation is added.
class LabText {
  const LabText(this.values);
  LabText.plain(String text) : values = {'ko': text};

  final Map<String, String> values;

  static String _lines(Object? value) => value is List ? value.map((line) => '$line').join('\n') : '${value ?? ''}';

  static LabText parse(Object? json) {
    if (json is String) return LabText({'ko': json});
    if (json is List) return LabText({'ko': _lines(json)});
    if (json is Map) return LabText({for (final entry in json.entries) '${entry.key}': _lines(entry.value)});
    throw FormatException('Expected text, found $json');
  }

  static LabText? parseOrNull(Object? json) => json == null ? null : parse(json);

  /// The wording for the app language; untranslated text falls back to the script's own.
  String resolved([String? language]) => values[language ?? L10n.language] ?? values['ko'] ?? values['en'] ?? (values.isEmpty ? '' : values.values.first);
  String get text => resolved();
  bool get isEmpty => values.values.every((value) => value.trim().isEmpty);

  @override
  bool operator ==(Object other) => other is LabText && mapEquals(values, other.values);
  @override
  int get hashCode => Object.hashAll(values.entries.map((entry) => Object.hash(entry.key, entry.value)));
}

Map<String, Object?> _object(Object? json) => json is Map ? json.cast<String, Object?>() : throw FormatException('Expected an object, found $json');
List<T> _list<T>(Object? json, T Function(Object?) read) => json is List ? [for (final value in json) read(value)] : const [];
List<T>? _listOrNull<T>(Object? json, T Function(Object?) read) => json == null ? null : _list(json, read);
int _int(Object? json, [int fallback = 0]) => json is num ? json.toInt() : fallback;
int? _intOrNull(Object? json) => json is num ? json.toInt() : null;
bool? _bool(Object? json) => json is bool ? json : null;
String _string(Object? json) => json is String ? json : throw FormatException('Expected a string, found $json');

// MARK: - The course

/// A deck course: its seasons and the episodes in them. The AI lab is the bundled one (`assets/lab/`); others are
/// imported from one-file course files (`LabCourseFile`) and play on the same deck.
class LabCourse {
  const LabCourse({required this.info, required this.episodes, this.imported = false});

  final LabCourseInfo info;
  final List<LabEpisode> episodes;

  /// Imported by the learner from a course file. Such a course pays no 보석, has no cheat sheet or diagnosis of its own,
  /// and keeps its records under its own id (`LabStore.key`).
  final bool imported;

  String get id => info.id;

  List<LabSeason> get seasons => info.seasons;
  String get title => info.title.text;

  /// The rate a learner starts at, before any card.
  int get base => info.base;

  /// The highest the rate can go: every card engraved.
  int get top => base + episodes.fold(0, (total, episode) => total + episode.impact);

  LabEpisode? episode(String id) => episodes.where((episode) => episode.id == id).firstOrNull;
  LabSeason? seasonOf(LabEpisode episode) => seasons.where((season) => season.episodes.contains(episode.id)).firstOrNull;

  /// Every trap of every episode, in deck order.
  List<LabFail> get fails => [for (final episode in episodes) ...episode.fails];

  /// The colour of an episode's engraved card, six hexadecimal digits: the course's card colours in turn, by number.
  String color(LabEpisode episode) {
    final colors = info.cardColors ?? const [];
    if (colors.isEmpty) return '3A3A3C';
    return colors[(episode.number < 1 ? 0 : episode.number - 1) % colors.length];
  }

  static final empty = LabCourse(info: LabCourseInfo.empty, episodes: const []);
  static LabCourse? _bundled;

  /// The course shipped with the app; empty until [loadBundled] has finished.
  static LabCourse get bundled => _bundled ?? empty;

  /// Replaces what [bundled] returns, for tests.
  static void useBundled(LabCourse? course) => _bundled = course;

  /// Reads the course and every episode its seasons name, once.
  static Future<LabCourse> loadBundled([AssetBundle? bundle]) async {
    final loaded = _bundled;
    if (loaded != null) return loaded;
    try {
      return _bundled = await load((path) => (bundle ?? rootBundle).loadString('assets/lab/$path'));
    } on Object catch (error) {
      assert(false, 'AI lab course: $error');
      return empty;
    }
  }

  /// Reads a course folder through [read], which returns a file's text by its path in the folder.
  static Future<LabCourse> load(Future<String> Function(String path) read) async {
    final info = LabCourseInfo.fromJson(_object(jsonDecode(await read('course.json'))));
    final episodes = <LabEpisode>[];
    for (final id in [for (final season in info.seasons) ...season.episodes]) {
      try {
        episodes.add(LabEpisode.fromJson(_object(jsonDecode(await read('episodes/$id.json')))));
      } on Object catch (error) {
        throw FormatException('episodes/$id.json: $error');
      }
    }
    return LabCourse(info: info, episodes: episodes);
  }
}

class LabCourseInfo {
  const LabCourseInfo({
    required this.id,
    required this.title,
    required this.gauge,
    required this.base,
    required this.rewards,
    required this.seasons,
    this.cardColors,
  });

  final String id;
  final LabText title;
  final LabText gauge;
  final int base;
  final LabRewards rewards;
  final List<LabSeason> seasons;

  /// The colours engraved cards take, used in turn down the deck: card 1 the first, card 6 the first again.
  final List<String>? cardColors;

  static final empty = LabCourseInfo(id: '', title: const LabText({}), gauge: const LabText({}), base: 0, rewards: LabRewards.none, seasons: const []);

  factory LabCourseInfo.fromJson(Map<String, Object?> json) => LabCourseInfo(
    id: _string(json['id']),
    title: LabText.parse(json['title']),
    gauge: LabText.parse(json['gauge']),
    base: _int(json['base']),
    // May be left out, as in an imported course, which pays nothing anyway.
    rewards: json['rewards'] == null ? LabRewards.none : LabRewards.fromJson(_object(json['rewards'])),
    seasons: _list(json['seasons'], (value) => LabSeason.fromJson(_object(value))),
    cardColors: _listOrNull(json['cardColors'], _string),
  );
}

/// What the lab pays in 보석, apart from each card's own amount. The `course…` amounts are what 2D AI 배우기 pays.
class LabRewards {
  const LabRewards({required this.fail, required this.edition, this.season = 0, required this.courseLesson, this.courseStars = 0, this.courseSection = 0});

  /// Each trap pressed for the first time, once its 망작 is hung in the gallery.
  final int fail;

  /// Each new cheat-sheet edition read, unless the edition says otherwise.
  final int edition;

  /// Each season of cards finished.
  final int season;

  /// Each lesson of 2D AI 배우기 finished for the first time.
  final int courseLesson;

  /// Each of its lessons finished with three stars for the first time.
  final int courseStars;

  /// Each of its sections with every lesson finished.
  final int courseSection;

  static const none = LabRewards(fail: 0, edition: 0, courseLesson: 0);

  /// Amounts left out pay nothing, so older course files still read.
  factory LabRewards.fromJson(Map<String, Object?> json) => LabRewards(
    fail: _int(json['fail']),
    edition: _int(json['edition']),
    season: _int(json['season']),
    courseLesson: _int(json['courseLesson']),
    courseStars: _int(json['courseStars']),
    courseSection: _int(json['courseSection']),
  );
}

class LabSeason {
  const LabSeason({required this.number, required this.title, this.summary, required this.order, this.opensAfter, required this.episodes});

  final int number;
  final LabText title;
  final LabText? summary;

  /// `fixed`: one card after another. `free`: any open card in any order.
  final String order;

  /// The season that must be finished before this one opens.
  final int? opensAfter;
  final List<String> episodes;
  bool get free => order == 'free';

  factory LabSeason.fromJson(Map<String, Object?> json) => LabSeason(
    number: _int(json['number']),
    title: LabText.parse(json['title']),
    summary: LabText.parseOrNull(json['summary']),
    order: (json['order'] as String?) ?? 'fixed',
    opensAfter: _intOrNull(json['opensAfter']),
    episodes: _list(json['episodes'], _string),
  );
}

// MARK: - An episode

/// One three-minute episode: a disaster, a choice with traps, a hands-on tool, and the line engraved on its card.
class LabEpisode {
  const LabEpisode({
    required this.id,
    required this.number,
    this.name,
    required this.title,
    this.teaser,
    required this.impact,
    required this.reward,
    required this.disaster,
    required this.choices,
    required this.tool,
    required this.card,
  });

  final String id;
  final int number;

  /// A short name for the card, such as "뇌 스위치", shown beside its number.
  final LabText? name;
  final LabText title;
  final LabText? teaser;

  /// How many points of the rate its card adds.
  final int impact;

  /// 보석 paid when its card is engraved.
  final int reward;
  final LabDisaster disaster;
  final List<LabChoice> choices;
  final LabTool tool;
  final LabCardText card;

  /// `No. 001`.
  String get serial => 'No. $digits';

  /// `001`.
  String get digits => number.toString().padLeft(3, '0');

  /// The short name, or the number where there is none.
  String get label => name?.text ?? serial;

  List<LabFail> get fails => [
    for (final (index, choice) in choices.indexed)
      if (choice.fail case final fail?) LabFail(id: fail.id ?? '$id-${index + 1}', episode: id, name: fail.name, reply: fail.reply, choice: choice.text),
  ];

  factory LabEpisode.fromJson(Map<String, Object?> json) => LabEpisode(
    id: _string(json['id']),
    number: _int(json['number']),
    name: LabText.parseOrNull(json['name']),
    title: LabText.parse(json['title']),
    teaser: LabText.parseOrNull(json['teaser']),
    impact: _int(json['impact']),
    reward: _int(json['reward']),
    disaster: LabDisaster.fromJson(_object(json['disaster'])),
    choices: _list(json['choices'], (value) => LabChoice.fromJson(_object(value))),
    tool: LabTool.fromJson(_object(json['tool'])),
    card: LabCardText.fromJson(_object(json['card'])),
  );

  @override
  bool operator ==(Object other) => other is LabEpisode && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class LabDisaster {
  const LabDisaster({required this.ask, required this.reply, required this.verdict, required this.question});

  /// What the learner asked the AI.
  final LabText ask;

  /// What the AI answered.
  final LabText reply;

  /// The line that sums up the disaster, in the content voice.
  final LabText verdict;

  /// What the learner is asked to do next, above the choices.
  final LabText question;

  factory LabDisaster.fromJson(Map<String, Object?> json) => LabDisaster(
    ask: LabText.parse(json['ask']),
    reply: LabText.parse(json['reply']),
    verdict: LabText.parse(json['verdict']),
    question: LabText.parse(json['question']),
  );
}

class LabChoice {
  const LabChoice({required this.text, this.right, required this.verdict, this.why, this.fail});
  final LabText text;
  final bool? right;
  final LabText verdict;
  final LabText? why;
  final LabFailText? fail;
  bool get isRight => right ?? false;

  factory LabChoice.fromJson(Map<String, Object?> json) => LabChoice(
    text: LabText.parse(json['text']),
    right: _bool(json['right']),
    verdict: LabText.parse(json['verdict']),
    why: LabText.parseOrNull(json['why']),
    fail: json['fail'] == null ? null : LabFailText.fromJson(_object(json['fail'])),
  );
}

class LabFailText {
  const LabFailText({this.id, required this.name, required this.reply});
  final String? id;
  final LabText name;
  final LabText reply;

  factory LabFailText.fromJson(Map<String, Object?> json) =>
      LabFailText(id: json['id'] as String?, name: LabText.parse(json['name']), reply: LabText.parse(json['reply']));
}

/// A 망작: what a trap produced, hung in the gallery once the trap is pressed.
class LabFail {
  const LabFail({required this.id, required this.episode, required this.name, required this.reply, required this.choice});
  final String id;
  final String episode;
  final LabText name;
  final LabText reply;

  /// The trap that made it.
  final LabText choice;

  @override
  bool operator ==(Object other) => other is LabFail && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

class LabCardText {
  const LabCardText({required this.line, required this.uses, this.copy});

  /// The line engraved on the card.
  final LabText line;

  /// Its back: how to use it, three lines.
  final List<LabText> uses;

  /// Text to copy and paste into an AI app.
  final LabText? copy;

  factory LabCardText.fromJson(Map<String, Object?> json) =>
      LabCardText(line: LabText.parse(json['line']), uses: _list(json['uses'], LabText.parse), copy: LabText.parseOrNull(json['copy']));
}

// MARK: - The tool

enum LabToolKind { switches, chips, stamps, marks, equip, rot }

/// The hands-on part of an episode. One shape for every kind; each kind reads the fields it needs.
class LabTool {
  const LabTool({
    required this.kind,
    required this.title,
    this.hint,
    this.gauge,
    this.prompt,
    this.need,
    this.controls,
    this.results,
    this.compose,
    this.mode,
    this.chips,
    this.head,
    this.stamps,
    this.items,
    this.summary,
    this.style,
    this.pieces,
    this.before,
    this.middle,
    this.after,
    this.wrong,
    this.core,
    this.gear,
    this.missions,
    this.retry,
    this.replies,
    this.reset,
    this.carry,
    this.fresh,
    this.minRetries,
  });

  final LabToolKind kind;
  final LabText title;
  final LabText? hint;

  /// The name of the measure the gauge shows.
  final LabText? gauge;

  /// The question in the fake prompt box, where the tool has one.
  final LabText? prompt;

  /// How many different passing results it takes (switches), or how many chips (chips in toggle mode).
  final int? need;

  // switches
  final List<LabControl>? controls;
  final List<LabResult>? results;
  final LabCompose? compose;

  // chips
  final String? mode;
  final List<LabChip>? chips;
  final LabText? head;

  // stamps
  final List<LabText>? stamps;
  final List<LabStampItem>? items;
  final LabText? summary;

  // marks
  final String? style;
  final List<LabPiece>? pieces;
  final LabText? before;
  final LabText? middle;
  final LabText? after;
  final LabText? wrong;

  // equip
  final LabText? core;
  final List<LabGear>? gear;
  final List<LabMission>? missions;

  // rot
  final LabText? retry;
  final List<LabText>? replies;
  final LabText? reset;
  final LabText? carry;
  final LabText? fresh;
  final int? minRetries;

  factory LabTool.fromJson(Map<String, Object?> json) => LabTool(
    kind: LabToolKind.values.byName(_string(json['kind'])),
    title: LabText.parse(json['title']),
    hint: LabText.parseOrNull(json['hint']),
    gauge: LabText.parseOrNull(json['gauge']),
    prompt: LabText.parseOrNull(json['prompt']),
    need: _intOrNull(json['need']),
    controls: _listOrNull(json['controls'], (value) => LabControl.fromJson(_object(value))),
    results: _listOrNull(json['results'], (value) => LabResult.fromJson(_object(value))),
    compose: json['compose'] == null ? null : LabCompose.fromJson(_object(json['compose'])),
    mode: json['mode'] as String?,
    chips: _listOrNull(json['chips'], (value) => LabChip.fromJson(_object(value))),
    head: LabText.parseOrNull(json['head']),
    stamps: _listOrNull(json['stamps'], LabText.parse),
    items: _listOrNull(json['items'], (value) => LabStampItem.fromJson(_object(value))),
    summary: LabText.parseOrNull(json['summary']),
    style: json['style'] as String?,
    pieces: _listOrNull(json['pieces'], (value) => LabPiece.fromJson(_object(value))),
    before: LabText.parseOrNull(json['before']),
    middle: LabText.parseOrNull(json['middle']),
    after: LabText.parseOrNull(json['after']),
    wrong: LabText.parseOrNull(json['wrong']),
    core: LabText.parseOrNull(json['core']),
    gear: _listOrNull(json['gear'], (value) => LabGear.fromJson(_object(value))),
    missions: _listOrNull(json['missions'], (value) => LabMission.fromJson(_object(value))),
    retry: LabText.parseOrNull(json['retry']),
    replies: _listOrNull(json['replies'], LabText.parse),
    reset: LabText.parseOrNull(json['reset']),
    carry: LabText.parseOrNull(json['carry']),
    fresh: LabText.parseOrNull(json['fresh']),
    minRetries: _intOrNull(json['minRetries']),
  );
}

class LabControl {
  const LabControl({required this.label, required this.options, this.unset});
  final LabText label;
  final List<LabOption> options;

  /// True when nothing is chosen at first, as for questions the AI asks.
  final bool? unset;

  factory LabControl.fromJson(Map<String, Object?> json) =>
      LabControl(label: LabText.parse(json['label']), options: _list(json['options'], LabOption.parse), unset: _bool(json['unset']));
}

/// A switch position: a label, and for composed answers the line it adds.
class LabOption {
  const LabOption({required this.label, this.line});
  final LabText label;
  final LabText? line;

  static LabOption parse(Object? json) {
    if (json is Map && json.containsKey('label')) return LabOption(label: LabText.parse(json['label']), line: LabText.parseOrNull(json['line']));
    return LabOption(label: LabText.parse(json));
  }
}

/// What the AI answers for one setting of the switches. `-1` in `when` matches any position, and an unset one.
class LabResult {
  const LabResult({required this.when, this.meta, required this.score, this.pass, required this.reply, this.note});
  final List<int> when;
  final LabText? meta;
  final int score;
  final bool? pass;
  final LabText reply;
  final LabText? note;

  bool matches(List<int?> picks) {
    if (when.length != picks.length) return false;
    for (var index = 0; index < when.length; index++) {
      if (when[index] != -1 && when[index] != picks[index]) return false;
    }
    return true;
  }

  factory LabResult.fromJson(Map<String, Object?> json) => LabResult(
    when: _list(json['when'], (value) => _int(value)),
    meta: LabText.parseOrNull(json['meta']),
    score: _int(json['score']),
    pass: _bool(json['pass']),
    reply: LabText.parse(json['reply']),
    note: LabText.parseOrNull(json['note']),
  );
}

/// The answer put together from each switch's line, once every switch is set.
class LabCompose {
  const LabCompose({this.meta, this.head, this.tail, required this.score});
  final LabText? meta;
  final LabText? head;
  final LabText? tail;
  final int score;

  factory LabCompose.fromJson(Map<String, Object?> json) => LabCompose(
    meta: LabText.parseOrNull(json['meta']),
    head: LabText.parseOrNull(json['head']),
    tail: LabText.parseOrNull(json['tail']),
    score: _int(json['score']),
  );
}

class LabChip {
  const LabChip({required this.label, this.attach, this.think, this.replies, this.score, this.pass, this.line});
  final LabText label;

  /// What gets attached to the prompt, such as an example.
  final LabText? attach;

  /// The AI's inner voice before it answers.
  final LabText? think;

  /// One answer per press; the last repeats.
  final List<LabText>? replies;
  final int? score;
  final bool? pass;

  /// In toggle mode, the line the chip adds to the composed card.
  final LabText? line;

  factory LabChip.fromJson(Map<String, Object?> json) => LabChip(
    label: LabText.parse(json['label']),
    attach: LabText.parseOrNull(json['attach']),
    think: LabText.parseOrNull(json['think']),
    replies: _listOrNull(json['replies'], LabText.parse),
    score: _intOrNull(json['score']),
    pass: _bool(json['pass']),
    line: LabText.parseOrNull(json['line']),
  );
}

class LabStampItem {
  const LabStampItem({required this.text, required this.answer, this.reveal});
  final LabText text;

  /// The index of the right stamp.
  final int answer;
  final LabText? reveal;

  factory LabStampItem.fromJson(Map<String, Object?> json) =>
      LabStampItem(text: LabText.parse(json['text']), answer: _int(json['answer']), reveal: LabText.parseOrNull(json['reveal']));
}

class LabPiece {
  const LabPiece({required this.text, this.target, this.swap, this.why});
  final LabText text;
  final bool? target;

  /// What a masked piece reads as.
  final LabText? swap;

  /// Why a flagged piece is made up.
  final LabText? why;
  bool get isTarget => target ?? false;

  factory LabPiece.fromJson(Map<String, Object?> json) => LabPiece(
    text: LabText.parse(json['text']),
    target: _bool(json['target']),
    swap: LabText.parseOrNull(json['swap']),
    why: LabText.parseOrNull(json['why']),
  );
}

class LabGear {
  const LabGear({required this.id, required this.label, this.symbol, this.miss});
  final String id;
  final LabText label;
  final String? symbol;

  /// For gear that solves nothing: what happens when it is fitted.
  final LabText? miss;

  factory LabGear.fromJson(Map<String, Object?> json) =>
      LabGear(id: _string(json['id']), label: LabText.parse(json['label']), symbol: json['symbol'] as String?, miss: LabText.parseOrNull(json['miss']));
}

class LabMission {
  const LabMission({required this.text, required this.needs, required this.before, required this.after});
  final LabText text;
  final List<String> needs;
  final LabText before;
  final LabText after;

  factory LabMission.fromJson(Map<String, Object?> json) => LabMission(
    text: LabText.parse(json['text']),
    needs: _list(json['needs'], _string),
    before: LabText.parse(json['before']),
    after: LabText.parse(json['after']),
  );
}

// MARK: - The diagnosis

/// The one-minute habit check that makes card No. 000.
class LabDiagnosis {
  const LabDiagnosis({required this.title, this.intro, required this.questions, required this.types, required this.fallback});
  final LabText title;
  final LabText? intro;
  final List<LabQuestion> questions;
  final List<LabType> types;
  final String fallback;

  LabType? type(String? id) => types.where((type) => type.id == id).firstOrNull;

  /// The type the answers point to most; ties go to the type listed first. No weak spot at all gives the fallback.
  LabType? result(List<int> answers) {
    final counts = <String, int>{};
    for (var index = 0; index < questions.length && index < answers.length; index++) {
      final options = questions[index].options;
      final answer = answers[index];
      if (answer < 0 || answer >= options.length) continue;
      final type = options[answer].type;
      if (type != null) counts[type] = (counts[type] ?? 0) + 1;
    }
    LabType? best;
    for (final type in types) {
      final count = counts[type.id];
      if (count == null) continue;
      if (best == null || count > counts[best.id]!) best = type;
    }
    return best ?? type(fallback);
  }

  factory LabDiagnosis.fromJson(Map<String, Object?> json) => LabDiagnosis(
    title: LabText.parse(json['title']),
    intro: LabText.parseOrNull(json['intro']),
    questions: _list(json['questions'], (value) {
      final question = _object(value);
      return LabQuestion(
        text: LabText.parse(question['text']),
        options: _list(question['options'], (option) {
          final answer = _object(option);
          return LabAnswer(text: LabText.parse(answer['text']), type: answer['type'] as String?);
        }),
      );
    }),
    types: _list(json['types'], (value) => LabType.fromJson(_object(value))),
    fallback: _string(json['fallback']),
  );

  static LabDiagnosis? _bundled;
  static LabDiagnosis? get bundled => _bundled;
  static void useBundled(LabDiagnosis? diagnosis) => _bundled = diagnosis;

  static Future<LabDiagnosis?> loadBundled([AssetBundle? bundle]) async {
    if (_bundled != null) return _bundled;
    try {
      return _bundled = LabDiagnosis.fromJson(_object(jsonDecode(await (bundle ?? rootBundle).loadString('assets/lab/diagnosis.json'))));
    } on Object {
      return null;
    }
  }
}

class LabQuestion {
  const LabQuestion({required this.text, required this.options});
  final LabText text;
  final List<LabAnswer> options;
}

class LabAnswer {
  const LabAnswer({required this.text, this.type});
  final LabText text;
  final String? type;
}

class LabType {
  const LabType({required this.id, required this.name, required this.line, required this.episodes});
  final String id;
  final LabText name;
  final LabText line;
  final List<String> episodes;

  factory LabType.fromJson(Map<String, Object?> json) =>
      LabType(id: _string(json['id']), name: LabText.parse(json['name']), line: LabText.parse(json['line']), episodes: _list(json['episodes'], _string));
}
