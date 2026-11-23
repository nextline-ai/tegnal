import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';

import '../study/study_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundledPath = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());

  late StudyHarness harness;

  setUp(() {
    StudyPath.useBundled(bundledPath);
    harness = StudyHarness();
  });

  tearDown(() {
    StudyPath.useBundled(null);
    StudyCurriculum.useBundled(null);
  });

  StudyModeModel model() => StudyModeModel(harness.booru)..reload();

  /// Courses of their own come in through the 코스 tab, never as tracks inside the 2D AI course.
  test('the path and the curriculum are the course\'s own', () {
    final subject = model();
    expect(subject.path, same(StudyPath.bundled));
    expect(subject.curriculum, same(StudyCurriculum.bundled));
    expect(subject.awards.length, StudyAward.all(subject.path).length);
  });
}
