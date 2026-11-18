import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../support/swift_json.dart';
import 'study_models.dart';

/// `StudyLesson`: one lesson on writing prompts, with what the makers of the image models document, examples and a few questions.
class StudyLesson {
  const StudyLesson({
    required this.id,
    required this.symbol,
    this.tool,
    required this.title,
    required this.summary,
    required this.parts,
    this.checks = const [],
    this.sources = const [],
  });
  final String id;

  /// An SF Symbol name, as the iOS app reads it; screens map it to their own icon.
  final String symbol;

  /// A hands-on tool shown with the lesson; `emphasis` is the weight converter.
  final String? tool;
  final StudyText title;
  final StudyText summary;
  final List<StudyLessonPart> parts;
  final List<StudyLessonCheck> checks;

  /// The pages the lesson was written from.
  final List<String> sources;

  factory StudyLesson.fromJson(JsonObject json) => StudyLesson(
    id: json.string('id'),
    symbol: json.string('symbol'),
    tool: json.stringOrNull('tool'),
    title: json.dictionary('title', jsonString),
    summary: json.dictionary('summary', jsonString),
    parts: json.list('parts', (value) => StudyLessonPart.fromJson(jsonObject(value))),
    checks: json.listOrNull('checks', (value) => StudyLessonCheck.fromJson(jsonObject(value))) ?? const [],
    sources: json.stringsOrNull('sources') ?? const [],
  );
}

class StudyLessonExample {
  const StudyLessonExample({required this.code, this.note});

  /// Prompt text, shown as written.
  final String code;
  final StudyText? note;

  factory StudyLessonExample.fromJson(JsonObject json) => StudyLessonExample(code: json.string('code'), note: json.dictionaryOrNull('note', jsonString));
}

class StudyLessonPart {
  const StudyLessonPart({this.heading, this.body, this.examples = const []});
  final StudyText? heading;

  /// Running text; words between backticks are prompt syntax.
  final StudyText? body;
  final List<StudyLessonExample> examples;

  factory StudyLessonPart.fromJson(JsonObject json) => StudyLessonPart(
    heading: _text(json, 'heading'),
    body: _text(json, 'body'),
    examples: json.listOrNull('examples', (value) => StudyLessonExample.fromJson(jsonObject(value))) ?? const [],
  );
}

class StudyLessonCheck {
  const StudyLessonCheck({required this.question, required this.choices, required this.answer, required this.why});
  final StudyText question;

  /// Prompt text to choose between, the same in every language.
  final List<String> choices;
  final int answer;
  final StudyText why;

  factory StudyLessonCheck.fromJson(JsonObject json) => StudyLessonCheck(
    question: json.dictionary('question', jsonString),
    choices: json.strings('choices'),
    answer: json.integer('answer'),
    why: json.dictionary('why', jsonString),
  );
}

StudyText? _text(JsonObject json, String key) => json.dictionaryOrNull(key, jsonString);

/// `StudyGuide`: the lessons on writing prompts.
class StudyGuide {
  const StudyGuide({this.version = 1, this.checked = '', this.lessons = const []});
  final int version;

  /// The month the sources were last read, as `yyyy-MM`.
  final String checked;
  final List<StudyLesson> lessons;

  factory StudyGuide.fromJson(JsonObject json) => StudyGuide(
    version: json.integer('version'),
    checked: json.string('checked'),
    lessons: json.list('lessons', (value) => StudyLesson.fromJson(jsonObject(value))),
  );

  static StudyGuide parse(String text) => StudyGuide.fromJson(jsonObject(jsonDecode(text)));

  static StudyGuide? _bundled;

  /// The guide shipped with the app; empty until [loadBundled] has finished.
  static StudyGuide get bundled => _bundled ?? const StudyGuide();

  /// Reads `assets/study/PromptGuide.json` once; later calls return what was read.
  static Future<StudyGuide> loadBundled([AssetBundle? bundle]) async {
    final loaded = _bundled;
    if (loaded != null) return loaded;
    try {
      return _bundled = StudyGuide.parse(await (bundle ?? rootBundle).loadString('assets/study/PromptGuide.json'));
    } on Object {
      return const StudyGuide();
    }
  }

  /// Replaces what [bundled] returns, for tests.
  @visibleForTesting
  static void useBundled(StudyGuide? guide) => _bundled = guide;

  /// The preference that keeps the finished lessons, as on iOS.
  static const finishedKey = 'study.guideFinished';

  /// The lessons whose every question has been answered right, kept as their ids joined by commas.
  static Set<String> finished(String stored) => {
    for (final id in stored.split(','))
      if (id.isNotEmpty) id,
  };

  static String finishing(String id, {required String stored}) => ([...finished(stored), id]..sort()).toSet().join(',');
}

/// `StudyEmphasis`: the ways image generators write how strongly a tag should count.
enum StudyEmphasis {
  /// NovelAI braces and brackets, one pair for each step of 1.05.
  braces,

  /// NovelAI's numbered form, `1.5::tag ::` (V4 and later; negative weights from V4.5).
  numbered,

  /// The Stable Diffusion web UI's `(tag:1.5)`.
  weighted;

  static const step = 1.05;

  /// The whole number of brace pairs (negative for brackets) closest to a weight.
  static int pairs(double weight) {
    if (weight <= 0) return 0;
    return (math.log(weight) / math.log(step)).round();
  }

  static String number(double weight) {
    final text = weight.toStringAsFixed(4).replaceAll(RegExp(r'0+$'), '');
    return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
  }

  /// [words] written with [weight] in this notation. A weight of one is written plainly.
  String written(String words, {required double weight}) {
    final escaped = words.replaceAll('(', r'\(').replaceAll(')', r'\)');
    if (words.isEmpty) return '';
    if ((weight - 1).abs() < 0.0001) return this == weighted ? escaped : words;
    switch (this) {
      case braces:
        final count = pairs(weight);
        if (count == 0) return words;
        final repeat = math.min(count.abs(), 20);
        return '${(count > 0 ? '{' : '[') * repeat}$words${(count > 0 ? '}' : ']') * repeat}';
      case numbered:
        return '${number(weight)}::$words ::';
      case weighted:
        return '($escaped:${number(weight)})';
    }
  }

  /// The weight this notation really gives, which for braces is the nearest step.
  double effective(double weight) => this == braces ? math.pow(step, pairs(weight)).toDouble() : weight;
}
