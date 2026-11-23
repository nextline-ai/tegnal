import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';

import '../study/study_test_support.dart';
import 'study_track_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundledPath = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());

  late StudyHarness harness;

  setUp(() {
    StudyPath.useBundled(bundledPath);
    harness = StudyHarness();
  });

  tearDown(() {
    AddonRuntime.shared.apply(AddonEffects());
    StudyPath.useBundled(null);
    StudyCurriculum.useBundled(null);
  });

  StudyModeModel model() => StudyModeModel(harness.booru)..reload();

  test('with no tracks the path and the curriculum are the app\'s own', () {
    final subject = model();
    expect(subject.tracks, isEmpty);
    expect(subject.track, isNull);
    expect(subject.trackID, isNull);
    expect(subject.shownPath, same(subject.path));
    expect(subject.curriculum, same(StudyCurriculum.bundled));
    expect(StudyModeModel.trackKey, 'study.track');
  });

  test('the tracks that are on are read, and their own tags join the curriculum after the app\'s', () {
    turnOn([trackAddon(), trackAddon(id: 'maker.plain', tags: false)]);
    final subject = model();
    expect(subject.tracks.map((track) => track.id), ['maker.track', 'maker.plain']);
    final bundled = StudyCurriculum.bundled;
    expect(subject.curriculum.version, bundled.version);
    expect(subject.curriculum.units.length, bundled.units.length + 1, reason: 'Only a track with tags of its own brings a unit');
    expect(subject.curriculum.units.take(bundled.units.length).map((unit) => unit.id), bundled.units.map((unit) => unit.id));
    expect(subject.curriculum.units.last.id, 'addon:maker.track');
    expect(subject.curriculum.contains('lighthouse'), isTrue);
    expect(bundled.contains('lighthouse'), isFalse);
    // Badges are measured on the main path alone.
    expect(subject.awards.length, StudyAward.all(subject.path).length);
  });

  test('choosing a track shows its path, is kept for the next visit, and is let go when the track is turned off', () {
    turnOn([trackAddon()]);
    final subject = model();
    var heard = 0;
    subject.addListener(() => heard++);
    subject.trackID = 'maker.track';
    expect(heard, 1);
    expect(harness.preferences.booruDefaults.string(StudyModeModel.trackKey), 'maker.track');
    expect(subject.track!.id, 'maker.track');
    expect(subject.shownPath, same(subject.track!.path));
    expect(subject.shownPath.lessons.first.id, 'addon:maker.track:idea-0');
    expect(subject.path, same(StudyPath.bundled), reason: 'The main path stays what badges read');

    expect(model().trackID, 'maker.track');
    expect(model().shownPath.lessons.first.id, 'addon:maker.track:idea-0');

    subject.trackID = null;
    expect(harness.preferences.booruDefaults.object(StudyModeModel.trackKey), isNull);
    expect(subject.shownPath, same(subject.path));

    subject.trackID = 'maker.track';
    AddonRuntime.shared.apply(AddonEffects());
    subject.reload();
    expect(subject.tracks, isEmpty);
    expect(subject.trackID, isNull);
    expect(harness.preferences.booruDefaults.object(StudyModeModel.trackKey), isNull);
    expect(subject.shownPath, same(subject.path));
    expect(subject.curriculum, same(StudyCurriculum.bundled));
  });

  test('a stored track that is no longer on is let go at the first reload', () {
    harness.preferences.booruDefaults.set(StudyModeModel.trackKey, 'maker.gone');
    final subject = model();
    expect(subject.trackID, isNull);
    expect(harness.preferences.booruDefaults.object(StudyModeModel.trackKey), isNull);
  });

  test('a track that changes its lessons is read again', () {
    turnOn([trackAddon(lessons: 1)]);
    final subject = model();
    expect(subject.tracks.single.path.lessons.length, 2);
    turnOn([trackAddon(lessons: 3)]);
    subject.reload();
    expect(subject.tracks.single.path.lessons.length, 4);
  });

  test('a finished track is celebrated once, on its last lesson', () {
    turnOn([trackAddon(lessons: 1)]);
    final subject = model();
    final lessons = subject.tracks.single.path.lessons.map((lesson) => lesson.id).toList();
    final study = harness.store.studyStore;

    study.earn(15, lesson: lessons.first, stars: 3);
    subject.reload();
    expect(subject.newlyCompletedTrack(finishing: lessons.first), isNull, reason: 'One lesson is still to do');

    study.earn(15, lesson: lessons.last, stars: 2);
    subject.reload();
    expect(subject.newlyCompletedTrack(finishing: 's0-order'), isNull, reason: 'A main-path lesson finishes no track');
    expect(subject.newlyCompletedTrack(finishing: lessons.last)?.id, 'maker.track');
    expect(harness.store.studyStore.stats()['trackDone.maker.track'], 1, reason: 'Kept in study_stats, so it syncs');
    expect(subject.newlyCompletedTrack(finishing: lessons.last), isNull, reason: 'Only once');
    expect(subject.tracks.single.complete(subject.records), isTrue);
  });

  test('tags missed in a track count toward Weak Spots, and its lessons never move the main path', () {
    turnOn([trackAddon()]);
    final subject = model();
    harness.store.studyStore.answer('lighthouse', right: false);
    harness.store.studyStore.earn(15, lesson: subject.tracks.single.path.lessons.first.id, stars: 3);
    subject.reload();
    expect(subject.weak, 1);
    expect(subject.path.current(subject.records)?.id, bundledPath.lessons.first.id);
  });
}
