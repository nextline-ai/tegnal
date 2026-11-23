import 'package:flutter/foundation.dart';

import '../addons/addon_models.dart' show AddonCheck;
import '../study/study_models.dart';
import '../study/study_path.dart';
import '../support/swift_json.dart';
import 'lab_course_file.dart';

/// A course on the 2D AI course's engine, from a course file with `"engine": "tags"` (`TagCourse`): its own path of lessons
/// (the shape of `StudyPath.json`), and tags of its own beyond the app's curriculum. It plays on the 2D AI course's screens,
/// with its lessons kept apart from the bundled path (`course:<id>:<lesson>`), and earns XP and stars as lessons do, but no
/// badges, placement or 연구비.
@immutable
class TagCourse {
  const TagCourse._({required this.id, required this.title, required this.summary, required this.color, required this.symbol, required this.path, this.unit});

  final String id;
  final StudyText title;
  final StudyText summary;

  /// Six hexadecimal digits.
  final String color;
  final String symbol;

  /// The course's own lessons, under ids that never meet the bundled path's.
  final StudyPath path;

  /// The tags the course teaches beyond the app's curriculum.
  final StudyUnit? unit;

  static const limits = (sections: 40, lessons: 300, steps: 80, groups: 60, tags: 2000);
  static const poses = {'wave', 'cheer', 'think', 'sad', 'read', 'close-up', 'full-body'};

  /// What this version of the app knows how to play. Anything else in a file asks for a newer app.
  static const lessonKinds = {'concept', 'tags', 'boss'};
  static const stepKinds = {'card', 'ask', 'build', 'order', 'sort'};

  /// Whether a symbol name can be drawn. The app sets this to what learning mode's icons know at start-up.
  static bool Function(String name) symbolExists = _anySymbol;
  static bool _anySymbol(String name) => true;
  static String _symbol(String? name, String fallback) => name != null && symbolExists(name) ? name : fallback;

  static String lessonID(String course, String lesson) => 'course:$course:$lesson';

  /// Every lesson of the course is done.
  bool complete(Map<String, StudyLessonRecord> records) => path.lessons.isNotEmpty && path.lessons.every((lesson) => records[lesson.id] != null);

  /// Reads and checks a file's object. Throws `LabCourseFileError.newer` for a lesson or step this app does not know.
  static TagCourse decode(JsonObject top) {
    final _File file;
    try {
      file = _File.fromJson(jsonObject(_fillEnglish(top, 0)));
    } on LabCourseFileError {
      rethrow;
    } on Object {
      throw const LabCourseFileError.invalid('file');
    }
    file._validate();
    final id = file.id;
    final sections = [
      for (final section in file.sections)
        StudyPathSection.fromJson({
          ...section,
          'id': 'course:$id:${section['id']}',
          'lessons': [
            for (final lesson in (section['lessons']! as List).cast<JsonObject>())
              {
                ...lesson,
                'id': lessonID(id, lesson['id']! as String),
                'symbol': _symbol(lesson['symbol'] as String?, 'book.fill'),
                if (lesson['steps'] case final List<Object?> steps)
                  'steps': [
                    for (final step in steps.cast<JsonObject>())
                      {
                        ...step,
                        if (step['card'] case final JsonObject card)
                          'card': {
                            for (final MapEntry(:key, :value) in card.entries)
                              if (key != 'action') key: value,
                            if (card['symbol'] case final String symbol) 'symbol': _symbol(symbol, 'sparkles'),
                          },
                      },
                  ],
              },
          ],
        }),
    ];
    final groups = file.groups ?? const <StudyGroup>[];
    return TagCourse._(
      id: id,
      title: file.title,
      summary: file.summary,
      color: file.color,
      symbol: _symbol(file.symbol, 'graduationcap.fill'),
      path: StudyPath(version: 3, sections: sections),
      unit: groups.isEmpty ? null : StudyUnit(id: 'course:$id', title: file.title, summary: file.summary, groups: groups),
    );
  }

  /// Gives every text in the app languages an English wording, taken from Korean or Japanese where English is missing.
  static Object? _fillEnglish(Object? value, int depth) {
    if (depth >= 24) return value;
    if (value is Map<String, Object?>) {
      const languages = {'en', 'ko', 'ja'};
      if (value.isNotEmpty && languages.containsAll(value.keys) && value.values.every((inner) => inner is String)) {
        return {...value, if (value['en'] == null && (value['ko'] ?? value['ja']) != null) 'en': value['ko'] ?? value['ja']};
      }
      return {for (final entry in value.entries) entry.key: _fillEnglish(entry.value, depth + 1)};
    }
    if (value is List) return [for (final inner in value) _fillEnglish(inner, depth + 1)];
    return value;
  }
}

/// The course as its file writes it, read to be checked.
class _File {
  _File({required this.id, required this.title, required this.summary, required this.color, this.symbol, this.groups, required this.sections});

  final String id;
  final StudyText title;
  final StudyText summary;
  final String color;
  final String? symbol;
  final List<StudyGroup>? groups;

  /// Sections as `StudyPath.json` writes them, cleaned to the keys the path reads.
  final List<JsonObject> sections;

  static const limits = TagCourse.limits;
  static const poses = TagCourse.poses;
  static const lessonKinds = TagCourse.lessonKinds;
  static const stepKinds = TagCourse.stepKinds;

  List<JsonObject> get lessons => [for (final section in sections) ...(section['lessons']! as List).cast<JsonObject>()];

  factory _File.fromJson(JsonObject json) => _File(
    id: json.string('id'),
    title: json.dictionary('title', jsonString),
    summary: json.dictionary('summary', jsonString),
    color: json.string('color'),
    symbol: json.stringOrNull('symbol'),
    groups: json.listOrNull('groups', (value) => StudyGroup.fromJson(jsonObject(value))),
    sections: json.list('sections', (value) => _section(jsonObject(value))),
  );

  static StudyText _text(JsonObject json, String key) => json.dictionary(key, jsonString);
  static StudyText? _textOrNull(JsonObject json, String key) => json.dictionaryOrNull(key, jsonString);

  // The same keys Swift's `StudyPathLesson` decodes; anything else is dropped from the kept copy.
  static JsonObject _section(JsonObject json) => {
    'id': json.string('id'),
    'title': _text(json, 'title'),
    'summary': _text(json, 'summary'),
    'color': json.string('color'),
    'lessons': json.list('lessons', (value) => _lesson(jsonObject(value))),
  };

  static JsonObject _lesson(JsonObject json) {
    final kind = json.string('kind');
    if (!lessonKinds.contains(kind)) throw const LabCourseFileError.newer();
    return {
      'id': json.string('id'),
      'kind': kind,
      'symbol': json.string('symbol'),
      'title': _text(json, 'title'),
      'summary': ?_textOrNull(json, 'summary'),
      'tags': ?json.stringsOrNull('tags'),
      if (json['steps'] != null) 'steps': json.list('steps', (value) => _step(jsonObject(value))),
    };
  }

  static JsonObject _step(JsonObject json) {
    // A step this app does not know: the course is for a newer app, not a broken file.
    if (!stepKinds.containsAll(json.keys)) throw const LabCourseFileError.newer();
    return _knownStep(json);
  }

  static JsonObject _knownStep(JsonObject json) => {
    if (json.objectOrNull('card') case final card?)
      'card': {
        'title': _text(card, 'title'),
        'body': _text(card, 'body'),
        'code': ?card.stringOrNull('code'),
        'symbol': ?card.stringOrNull('symbol'),
        'pose': ?card.stringOrNull('pose'),
        'action': ?card.stringOrNull('action'),
      },
    if (json.objectOrNull('ask') case final ask?)
      'ask': {
        'question': _text(ask, 'question'),
        'choices': ask.list('choices', (value) => jsonObject(value).map((key, inner) => MapEntry(key, jsonString(inner)))),
        'answer': ask.integer('answer'),
        'why': _text(ask, 'why'),
        'code': ?ask.booleanOrNull('code'),
      },
    if (json.objectOrNull('build') case final build?)
      'build': {'brief': _text(build, 'brief'), 'answer': build.strings('answer'), 'extras': build.strings('extras')},
    if (json.objectOrNull('order') case final order?)
      'order': {
        'brief': _text(order, 'brief'),
        'items': order.list('items', (value) => jsonObject(value).map((key, inner) => MapEntry(key, jsonString(inner)))),
        'why': _text(order, 'why'),
      },
    if (json.objectOrNull('sort') case final sort?)
      'sort': {
        'brief': _text(sort, 'brief'),
        'left': _text(sort, 'left'),
        'right': _text(sort, 'right'),
        'items': sort.list('items', (value) {
          final item = jsonObject(value);
          return {'text': _text(item, 'text'), 'right': item.boolean('right')};
        }),
        'why': _text(sort, 'why'),
      },
  };

  void _validate() {
    void require(bool value, String field) {
      if (!value) throw LabCourseFileError.invalid(field);
    }

    require(AddonCheck.identifier(id) && !LabCourseFile.reserved.contains(id), 'id');
    require(AddonCheck.text(title, max: 80), 'title');
    require(AddonCheck.text(summary, max: 400, multiline: true), 'summary');
    require(AddonCheck.color(color), 'color');
    if (symbol case final symbol?) require(AddonCheck.symbol(symbol), 'symbol');

    final known = <String>{};
    final groups = this.groups ?? const <StudyGroup>[];
    require(groups.length <= limits.groups, 'groups');
    require(groups.map((group) => group.id).toSet().length == groups.length, 'groups');
    for (final group in groups) {
      require(AddonCheck.identifier(group.id) && AddonCheck.text(group.title, max: 80), 'groups: ${AddonCheck.preview(group.id)}');
      require(group.tags.isNotEmpty, 'groups: ${AddonCheck.preview(group.id)}');
      for (final tag in group.tags) {
        final field = 'tag ${AddonCheck.preview(tag.name)}';
        require(AddonCheck.tag(tag.name, namespaced: false), field);
        require(AddonCheck.text(tag.note, max: 400, multiline: true), field);
        for (final name in [?tag.ko, ?tag.ja]) {
          require(AddonCheck.line(name, max: 80), field);
        }
        final confusable = tag.confusable ?? const <String>[];
        require(confusable.length <= 10 && confusable.every((name) => AddonCheck.tag(name, namespaced: false)), field);
        require(known.add(tag.name), field);
      }
    }
    require(known.length <= limits.tags, 'groups');

    require(sections.isNotEmpty && sections.length <= limits.sections, 'sections');
    require(sections.map((section) => section['id']).toSet().length == sections.length, 'sections');
    final lessons = this.lessons;
    require(lessons.isNotEmpty && lessons.length <= limits.lessons, 'lessons');
    require(lessons.map((lesson) => lesson['id']).toSet().length == lessons.length, 'lessons');
    for (final section in sections) {
      final id = section['id']! as String;
      require(AddonCheck.identifier(id), 'section ${AddonCheck.preview(id)}');
      require(
        AddonCheck.text(section['title']! as StudyText, max: 80) &&
            AddonCheck.text(section['summary']! as StudyText, max: 400, multiline: true) &&
            AddonCheck.color(section['color']! as String),
        'section ${AddonCheck.preview(id)}',
      );
      for (final lesson in (section['lessons']! as List).cast<JsonObject>()) {
        _validateLesson(lesson, known);
      }
    }
  }

  void _validateLesson(JsonObject lesson, Set<String> known) {
    final id = lesson['id']! as String;
    void require(bool value) {
      if (!value) throw LabCourseFileError.invalid('lesson ${AddonCheck.preview(id)}');
    }

    StudyText text(Object? value) => value! as StudyText;
    bool texts(Object? value, int max, {bool multiline = false}) =>
        value is List && value.every((item) => AddonCheck.text(item as StudyText, max: max, multiline: multiline));

    require(AddonCheck.identifier(id) && AddonCheck.symbol(lesson['symbol']! as String) && AddonCheck.text(text(lesson['title']), max: 80));
    if (lesson['summary'] case final StudyText summary) require(AddonCheck.text(summary, max: 400, multiline: true));
    final tags = (lesson['tags'] as List<String>?) ?? const <String>[];
    final steps = (lesson['steps'] as List?)?.cast<JsonObject>() ?? const <JsonObject>[];
    bool taught(String name) => known.contains(name) || StudyCurriculum.bundled.contains(name);
    if (lesson['kind'] == 'tags') {
      // Every tag of a tags lesson needs a meaning, from the app's curriculum or from the course's own groups.
      require(steps.isEmpty && tags.isNotEmpty && tags.length <= 12 && tags.toSet().length == tags.length && tags.every(taught));
      return;
    }
    require(tags.isEmpty && steps.isNotEmpty && steps.length <= limits.steps);
    for (final step in steps) {
      require(step.length == 1);
      if (step['card'] case final JsonObject card) {
        // Cards in course files only tell: they never open a page, a key sheet or the generator.
        require(card['action'] == null);
        require(AddonCheck.text(text(card['title']), max: 120) && AddonCheck.text(text(card['body']), max: 2000, multiline: true));
        require(card['code'] == null || AddonCheck.line(card['code']! as String, max: 1000, multiline: true));
        require(card['symbol'] == null || AddonCheck.symbol(card['symbol']! as String));
        require(card['pose'] == null || poses.contains(card['pose']));
      }
      if (step['ask'] case final JsonObject ask) {
        final choices = ask['choices']! as List;
        final answer = ask['answer']! as int;
        require(AddonCheck.text(text(ask['question']), max: 400, multiline: true) && AddonCheck.text(text(ask['why']), max: 600, multiline: true));
        require(choices.length >= 2 && choices.length <= 6 && answer >= 0 && answer < choices.length && texts(choices, 300, multiline: true));
      }
      if (step['build'] case final JsonObject build) {
        final answer = build['answer']! as List<String>, extras = build['extras']! as List<String>;
        require(AddonCheck.text(text(build['brief']), max: 400, multiline: true));
        require(answer.isNotEmpty && answer.length <= 12 && answer.toSet().length == answer.length && extras.length <= 12);
        require([...answer, ...extras].every((tag) => AddonCheck.tag(tag, namespaced: false)) && answer.toSet().intersection(extras.toSet()).isEmpty);
      }
      if (step['order'] case final JsonObject order) {
        final items = order['items']! as List;
        require(AddonCheck.text(text(order['brief']), max: 400, multiline: true) && AddonCheck.text(text(order['why']), max: 600, multiline: true));
        require(items.length >= 2 && items.length <= 8 && texts(items, 200));
      }
      if (step['sort'] case final JsonObject sort) {
        final items = (sort['items']! as List).cast<JsonObject>();
        require(AddonCheck.text(text(sort['brief']), max: 400, multiline: true) && AddonCheck.text(text(sort['why']), max: 600, multiline: true));
        require(AddonCheck.text(text(sort['left']), max: 60) && AddonCheck.text(text(sort['right']), max: 60));
        require(items.length >= 2 && items.length <= 12 && items.every((item) => AddonCheck.text(text(item['text']), max: 200)));
      }
    }
  }
}
