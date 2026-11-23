import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';

import '../addons/addon_models.dart' show AddonCheck;
import '../support/l10n.dart';
import 'lab_course.dart';
import 'learning_courses.dart';
import 'tag_course.dart';

/// A deck course in one file: `course.json` with its episodes written inline, as `"episodes": [ … ]` (`LabCourseFile`).
/// Learners import these in learning mode's 코스 tab (`.tegnalcourse`, or plain `.json`).
///
/// Like add-ons, a course file is data only: nothing in it is run, fetched or opened. It is refused, never cleaned, when
/// any part breaks the rules below, so what the 코스 tab shows is all the file holds. An imported course pays no 보석,
/// so a made-up course can never buy what the lab's own cards earn.
abstract final class LabCourseFile {
  static const format = 'tegnal-lab-course';
  static const version = 1;
  static const fileExtension = 'tegnalcourse';
  static const maximumBytes = 4 * 1024 * 1024;

  /// Course ids the app's own courses use, which a file may not take.
  static const reserved = {LearningCourse.labID, LearningCourse.tagsID};
  static const limits = (seasons: 12, episodes: 100, choices: 6, text: 4000, strings: 40000);

  /// Reads a file the learner picked, at most one byte past the limit. Nothing in it is used until it has passed every check.
  static Future<List<int>> read(File file) async {
    if (await file.length() > maximumBytes) throw const LabCourseFileError.tooLarge();
    final handle = await file.open();
    try {
      // One byte past the limit, so a file that grew after its size was read is still refused.
      return await handle.read(maximumBytes + 1);
    } finally {
      await handle.close();
    }
  }

  /// The engines this version of the app can play. A file for any other is for a newer app.
  static const engines = {'deck', 'tags'};

  /// A course from its file: a deck course, or a course on the 2D AI course's engine (`"engine": "tags"`).
  /// Throws `.newer` for a file this app is too old for: a later version, another engine, or a tool, lesson or step it does
  /// not know. Such a file is a course all the same, kept until the app is updated (`LearningCourses.waiting`).
  static LearningCourse decode(List<int> data) {
    if (data.length > maximumBytes) throw const LabCourseFileError.tooLarge();
    Object? object;
    try {
      object = jsonDecode(utf8.decode(data));
    } on Object {
      throw const LabCourseFileError.notCourse();
    }
    if (object is! Map<String, Object?> || object['format'] != format) throw const LabCourseFileError.notCourse();
    final version = object['version'];
    if (version is! int || version < 1) throw const LabCourseFileError.notCourse();
    if (version > LabCourseFile.version) throw const LabCourseFileError.newer();
    final engine = object['engine'] ?? 'deck';
    if (engine is! String || !engines.contains(engine)) throw const LabCourseFileError.newer();
    var strings = 0;
    void check(Object? value, String path) {
      if (value is String) {
        strings += 1;
        if (strings > limits.strings || !clean(value)) throw LabCourseFileError.invalid(path.isEmpty ? 'text' : path);
      } else if (value is Map) {
        for (final entry in value.entries) {
          check(entry.value, path.isEmpty ? '${entry.key}' : '$path.${entry.key}');
        }
      } else if (value is List) {
        for (final (index, inner) in value.indexed) {
          check(inner, '$path[$index]');
        }
      }
    }

    check(object, '');
    if (engine == 'tags') {
      final course = TagCourse.decode(object);
      return LearningCourse(id: course.id, engine: LearningEngine.tags, lessons: course, imported: true);
    }
    final episodes = object['episodes'];
    if (episodes is! List) throw const LabCourseFileError.invalid('episodes');
    // A tool from a later version of the app.
    for (final episode in episodes) {
      final kind = episode is Map && episode['tool'] is Map ? (episode['tool'] as Map)['kind'] : null;
      if (kind is String && !LabToolKind.values.any((value) => value.name == kind)) throw const LabCourseFileError.newer();
    }
    final LabCourse course;
    try {
      course = LabCourse(
        info: LabCourseInfo.fromJson(object),
        episodes: [for (final episode in episodes) LabEpisode.fromJson((episode as Map).cast<String, Object?>())],
        imported: true,
      );
    } on Object {
      throw const LabCourseFileError.invalid('file');
    }
    final problem = course.problems(imported: true).firstOrNull;
    if (problem != null) throw LabCourseFileError.invalid(problem);
    return LearningCourse(id: course.id, engine: LearningEngine.deck, deck: course, imported: true);
  }

  /// The id and name of a course file this app is too old for, so it can be kept and named until the app is updated.
  static ({String id, String title})? peek(List<int> data) {
    try {
      final top = jsonDecode(utf8.decode(data));
      if (top is! Map || top['format'] != format) return null;
      final id = top['id'];
      if (id is! String || !AddonCheck.identifier(id) || reserved.contains(id)) return null;
      final title = LabText.parse(top['title'] ?? id).text;
      if (!clean(title) || title.characters.length > 80) return null;
      return (id: id, title: title);
    } on Object {
      return null;
    }
  }

  static String digest(List<int> data) => sha256.convert(data).toString();

  // Control characters, invisible format marks, private-use, surrogates, unassigned code points and line or paragraph separators.
  static final _hidden = RegExp(r'[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Cn}\p{Zl}\p{Zp}]', unicode: true);

  /// The add-on rule for text, with line breaks allowed and empty text let through (a script may leave a line blank).
  static bool clean(String text) {
    if (text.characters.length > limits.text) return false;
    for (final match in _hidden.allMatches(text)) {
      final mark = match[0]!;
      // Joiners keep emoji whole; every other invisible format mark is refused.
      if (mark == '‍' || mark == '\n') continue;
      return false;
    }
    return true;
  }

  static final _part = RegExp(r'^[a-z0-9._-]{1,64}$');

  /// An episode or 망작 id: lowercase letters, digits, dots, hyphens and underscores, up to 64. Never a slash, which
  /// `LabStore.key` puts between a course and its ids.
  static bool part(String value) => _part.hasMatch(value);
}

class LabCourseFileError implements Exception {
  const LabCourseFileError.tooLarge() : kind = 'tooLarge', detail = null;
  const LabCourseFileError.notCourse() : kind = 'notCourse', detail = null;
  const LabCourseFileError.newer() : kind = 'newer', detail = null;
  const LabCourseFileError.reserved() : kind = 'reserved', detail = null;
  const LabCourseFileError.invalid(String field) : kind = 'invalid', detail = field;

  final String kind;
  final String? detail;

  String get errorDescription => switch (kind) {
    'tooLarge' => L10n.text('lab.import.tooLarge'),
    'notCourse' => L10n.text('lab.import.notCourse'),
    'newer' => L10n.text('lab.import.newer'),
    'reserved' => L10n.text('lab.import.reserved'),
    _ => L10n.text('lab.import.invalid', [detail!]),
  };

  @override
  bool operator ==(Object other) => other is LabCourseFileError && other.kind == kind && other.detail == detail;
  @override
  int get hashCode => Object.hash(kind, detail);
  @override
  String toString() => 'LabCourseFileError.$kind${detail == null ? '' : '($detail)'}';
}

// MARK: - The rules every deck course keeps

extension LabCourseRules on LabCourse {
  /// What is wrong with the course, as the field at fault; empty when nothing is. The bundled course is held to the same
  /// rules by its tests; an imported one is refused for the first problem found.
  List<String> problems({bool imported = false}) {
    final found = <String>[];
    void require(bool value, String field) {
      if (!value) found.add(field);
    }

    require(AddonCheck.identifier(info.id), 'id');
    if (imported) require(!LabCourseFile.reserved.contains(info.id), 'id');
    require(!info.title.isEmpty && info.title.text.characters.length <= 80, 'title');
    require(!info.gauge.isEmpty && info.gauge.text.characters.length <= 40, 'gauge');
    require(info.base >= 0 && info.base <= 100, 'base');
    final colors = info.cardColors;
    require(colors == null || (colors.isNotEmpty && colors.every(AddonCheck.color)), 'cardColors');

    require(seasons.isNotEmpty && seasons.length <= LabCourseFile.limits.seasons, 'seasons');
    require(seasons.map((season) => season.number).toSet().length == seasons.length, 'seasons');
    final listed = [for (final season in seasons) ...season.episodes];
    require(listed.toSet().length == listed.length, 'seasons.episodes');
    for (final season in seasons) {
      final field = 'seasons[${season.number}]';
      require(!season.title.isEmpty && season.episodes.isNotEmpty, field);
      require(const {'fixed', 'free'}.contains(season.order), '$field.order');
      final after = season.opensAfter;
      if (after != null) require(seasons.any((other) => other.number == after && other.number < season.number), '$field.opensAfter');
    }

    require(episodes.isNotEmpty && episodes.length <= LabCourseFile.limits.episodes, 'episodes');
    final ids = {for (final episode in episodes) episode.id};
    require(ids.length == listed.length && ids.containsAll(listed) && listed.toSet().containsAll(ids) && episodes.length == listed.length, 'episodes');
    require(episodes.map((episode) => episode.number).toSet().length == episodes.length, 'episodes.number');
    final failIDs = [for (final fail in fails) fail.id];
    require(failIDs.toSet().length == failIDs.length, 'fail.id');
    for (final fail in failIDs) {
      require(LabCourseFile.part(fail), 'fail.id ${AddonCheck.preview(fail)}');
    }
    require(top <= 100, 'impact');
    for (final episode in episodes) {
      found.addAll(episode.problems());
    }
    return found;
  }
}

extension LabEpisodeRules on LabEpisode {
  /// What is wrong with one episode: its text, its choices and whether its tool can be passed with what the file gives it.
  List<String> problems() {
    final found = <String>[];
    final field = 'episodes.$id';
    void require(bool value, String part) {
      if (!value) found.add(part.isEmpty ? field : '$field.$part');
    }

    require(LabCourseFile.part(id), 'id');
    require(number >= 1 && number <= 999, 'number');
    require(!title.isEmpty, 'title');
    require(impact >= 0 && reward >= 0, 'impact');
    require(!disaster.ask.isEmpty && !disaster.reply.isEmpty && !disaster.verdict.isEmpty && !disaster.question.isEmpty, 'disaster');
    require(choices.length >= 2 && choices.length <= LabCourseFile.limits.choices && choices.any((choice) => choice.isRight), 'choices');
    for (final choice in choices.where((choice) => !choice.isRight)) {
      require(choice.fail != null, 'choices.fail');
    }
    require(!card.line.isEmpty && card.uses.length == 3, 'card');

    switch (tool.kind) {
      case LabToolKind.switches:
        final controls = tool.controls ?? const [];
        require(controls.isNotEmpty && controls.every((control) => control.options.isNotEmpty), 'tool.controls');
        final passing = (tool.results ?? const []).where((result) => result.pass == true).length;
        require(tool.compose != null || passing >= (tool.need ?? 1), 'tool.results');
        for (final result in tool.results ?? const <LabResult>[]) {
          require(result.when.length == controls.length, 'tool.results.when');
          for (final (index, value) in result.when.indexed) {
            if (value >= 0 && index < controls.length) require(value < controls[index].options.length, 'tool.results.when');
          }
        }
        if (tool.compose != null) {
          require(controls.every((control) => control.options.every((option) => option.line != null)), 'tool.compose');
        }
      case LabToolKind.chips:
        final chips = tool.chips ?? const [];
        if (tool.mode == 'toggle') {
          require(chips.where((chip) => chip.line != null).length >= (tool.need ?? 1), 'tool.chips');
        } else {
          require(chips.any((chip) => chip.pass == true), 'tool.chips');
          require(chips.every((chip) => (chip.replies ?? const []).isNotEmpty), 'tool.chips.replies');
        }
      case LabToolKind.stamps:
        final labels = tool.stamps ?? const [];
        final items = tool.items ?? const [];
        require(labels.length == 2, 'tool.stamps');
        require(items.isNotEmpty && items.every((item) => item.answer >= 0 && item.answer < labels.length), 'tool.items');
      case LabToolKind.marks:
        final pieces = tool.pieces ?? const [];
        require(pieces.any((piece) => piece.isTarget), 'tool.pieces');
        require(const {'cut', 'flag', 'mask'}.contains(tool.style ?? 'cut'), 'tool.style');
        if (tool.style == 'mask') require(pieces.where((piece) => piece.isTarget).every((piece) => piece.swap != null), 'tool.pieces.swap');
      case LabToolKind.equip:
        final gear = {for (final item in tool.gear ?? const <LabGear>[]) item.id};
        require((tool.missions ?? const []).isNotEmpty, 'tool.missions');
        for (final mission in tool.missions ?? const <LabMission>[]) {
          require(gear.containsAll(mission.needs), 'tool.missions.needs');
        }
        for (final item in tool.gear ?? const <LabGear>[]) {
          require(item.symbol == null || AddonCheck.symbol(item.symbol!), 'tool.gear.symbol');
        }
      case LabToolKind.rot:
        require((tool.replies ?? const []).length >= (tool.minRetries ?? 2), 'tool.replies');
        require(tool.fresh != null, 'tool.fresh');
    }
    return found;
  }
}
