import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lab_course.dart';
import 'lab_course_file.dart';
import '../study/study_models.dart';
import '../support/l10n.dart';
import 'lab_store.dart';
import 'tag_course.dart';

/// A course of learning mode, as the 코스 tab lists it (`LearningCourse`). Every course plays on one of two engines:
///
/// - `deck`: the lab's card deck (`LabRoot`). The AI lab is the bundled deck course; imported course files are deck courses too.
/// - `tags`: the tag-study path (`StudyModeRoot`). 2D AI 배우기 is the bundled one; imported `"engine": "tags"` courses bring a
///   path of their own (`TagCourse`).
///
/// A new bundled course is a deck course: a script folder like `assets/lab/`, one entry in `LearningCourses.bundled`, and
/// nothing else.
enum LearningEngine { deck, tags }

class LearningCourse {
  const LearningCourse({required this.id, required this.engine, this.item, this.deck, this.lessons, this.imported = false});

  static const labID = 'ai-lab';
  static const tagsID = '2d-ai';

  final String id;
  final LearningEngine engine;

  /// The shop item that sells it (`LabStore.owns`); null when every learner has it.
  final String? item;

  /// The script, for a deck course.
  final LabCourse? deck;

  /// The path, for an imported course on the tags engine. Null for the bundled 2D AI course, which plays the bundled path.
  final TagCourse? lessons;

  /// Imported by the learner from a course file, rather than bundled.
  final bool imported;

  String get title => deck?.title ?? lessons?.title.resolved() ?? L10n.text('Tag Study');
}

/// A course file kept although this app is too old to play it.
@immutable
class WaitingCourse {
  const WaitingCourse({required this.id, required this.title});
  final String id;
  final String title;

  @override
  bool operator ==(Object other) => other is WaitingCourse && other.id == id && other.title == title;
  @override
  int get hashCode => Object.hash(id, title);
}

/// Every course: the bundled ones first, then those the learner imported, oldest first (`LearningCourses`).
class LearningCourses extends ChangeNotifier {
  LearningCourses({Directory? folder}) {
    if (folder != null) attach(folder);
  }

  /// The app-wide catalog. The app attaches its folder at start-up.
  static final LearningCourses shared = LearningCourses();

  /// Imported courses, read from their files.
  List<LearningCourse> imported = const [];

  /// Imported files this version of the app cannot play yet.
  List<WaitingCourse> waiting = const [];

  /// Where imported course files are kept, one `<id>.json` each.
  Directory? _folder;

  /// Reads the kept course files from [folder], the app's `LearningCourses` support folder.
  void attach(Directory folder) {
    _folder = folder;
    final (courses, kept) = _load(folder);
    imported = courses;
    waiting = kept;
    notifyListeners();
  }

  static LearningCourse get lab => LearningCourse(id: LearningCourse.labID, engine: LearningEngine.deck, deck: LabCourse.bundled);
  static const tags = LearningCourse(id: LearningCourse.tagsID, engine: LearningEngine.tags, item: LabStore.tagCourse);
  static List<LearningCourse> get bundled => [lab, tags];

  List<LearningCourse> get all => [...bundled, ...imported];

  LearningCourse? course(String id) => all.where((course) => course.id == id).firstOrNull;

  /// True when the learner may open the course: it is free, or it was bought in the shop.
  bool owned(LearningCourse course, [LabStore? store]) => course.item == null || (store ?? LabStore.shared).owns(course.item!);

  // MARK: Importing

  /// Checks a course file and keeps it. A file for a course already imported replaces it; its records stay.
  /// A course this app is too old for is kept as waiting, and `.newer` is thrown so the learner is told to update.
  Future<LearningCourse> addFile(File file) async => add(await LabCourseFile.read(file));

  LearningCourse add(List<int> data) {
    try {
      final course = LabCourseFile.decode(data);
      _keep(course.id, data);
      imported = [...imported.where((value) => value.id != course.id), course];
      waiting = [...waiting.where((value) => value.id != course.id)];
      notifyListeners();
      return course;
    } on LabCourseFileError catch (error) {
      if (error != const LabCourseFileError.newer()) rethrow;
      final peeked = LabCourseFile.peek(data);
      if (peeked == null) rethrow;
      _keep(peeked.id, data);
      imported = [...imported.where((value) => value.id != peeked.id)];
      waiting = [...waiting.where((value) => value.id != peeked.id), WaitingCourse(id: peeked.id, title: peeked.title)];
      notifyListeners();
      rethrow;
    }
  }

  void _keep(String id, List<int> data) {
    final folder = _folder;
    if (LabCourseFile.reserved.contains(id) || folder == null) throw const LabCourseFileError.reserved();
    folder.createSync(recursive: true);
    final target = _file(folder, id);
    File('${target.path}.part')
      ..writeAsBytesSync(data, flush: true)
      ..renameSync(target.path);
  }

  /// Removes an imported or waiting course. What was done in it stays in the records, so importing it again brings it back.
  void remove(String id) {
    final folder = _folder;
    if (folder != null) {
      final file = _file(folder, id);
      if (file.existsSync()) file.deleteSync();
    }
    imported = [...imported.where((value) => value.id != id)];
    waiting = [...waiting.where((value) => value.id != id)];
    notifyListeners();
  }

  static File _file(Directory folder, String id) => File('${folder.path}/$id.json');

  /// Reads the kept files, oldest first. A file this app is too old for waits; one that no longer passes the checks is left out.
  static (List<LearningCourse>, List<WaitingCourse>) _load(Directory folder) {
    if (!folder.existsSync()) return (const [], const []);
    final files = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.json')).toList()
      ..sort((a, b) => a.statSync().changed.compareTo(b.statSync().changed));
    final courses = <LearningCourse>[], waiting = <WaitingCourse>[];
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final data = file.readAsBytesSync();
      try {
        final course = LabCourseFile.decode(data);
        if (name == '${course.id}.json') courses.add(course);
      } on LabCourseFileError catch (error) {
        final peeked = error == const LabCourseFileError.newer() ? LabCourseFile.peek(data) : null;
        if (peeked != null && name == '${peeked.id}.json') {
          waiting.add(WaitingCourse(id: peeked.id, title: peeked.title));
        } else {
          debugPrint('LearningCourses: ${file.path} was left out: $error');
        }
      } on Object catch (error) {
        debugPrint('LearningCourses: ${file.path} was left out: $error');
      }
    }
    return (courses, waiting);
  }
}
