// Ported from native-ios/TEGNALTests/StudyAwardsTests.swift. Dart takes a `utcOffset` where Swift takes a `Calendar`
// and passes the generator store to `StudyAwards.refresh` as a parameter.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/generation/generation_store.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_speed.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/secure_secret_store.dart';
import 'package:tegnal/core/support/sql_database.dart';

const utc = Duration.zero;

StudyPathLesson lessonOf(String id) => StudyPathLesson(id: id, kind: StudyPathLessonKind.tags, symbol: 'tag', title: {'en': id}, tags: const ['t1']);

/// Section a has three lessons, b has two, and c none.
final samplePath = StudyPath(
  version: 3,
  sections: [
    StudyPathSection(id: 'a', title: const {'en': 'A'}, summary: const {'en': ''}, color: '112233', lessons: ['a1', 'a2', 'a3'].map(lessonOf).toList()),
    StudyPathSection(id: 'b', title: const {'en': 'B'}, summary: const {'en': ''}, color: '445566', lessons: ['b1', 'b2'].map(lessonOf).toList()),
    const StudyPathSection(id: 'c', title: {'en': 'C'}, summary: {'en': ''}, color: '778899'),
  ],
);

final now = DateTime.utc(2026, 6, 15, 12);

StudyDay day(int offset, {int xp = 0, int answered = 1}) => StudyDay(day: StudyDay.key(now.subtract(Duration(days: offset)), utcOffset: utc), answered: answered, xp: xp);

StudyFacts facts({
  Map<String, StudyLessonRecord> records = const {},
  List<StudyDay> days = const [],
  Map<String, StudyProgress> progress = const {},
  Map<String, int> stats = const {},
}) => StudyFacts.of(path: samplePath, records: records, days: days, progress: progress, stats: stats, now: now, utcOffset: utc);

StudyLessonRecord record(String id, {int stars = 1}) => StudyLessonRecord(lesson: id, stars: stars, runs: 1);
StudyAward award(String id) => StudyAward.all(samplePath).firstWhere((award) => award.id == id);

StudyCurriculum curriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'u',
      title: const {'en': 'U'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(id: 'g', title: const {'en': 'G'}, tags: [for (var i = 1; i <= 6; i++) StudyTag(name: 's$i', ko: 's$i', ja: 's$i', note: {'en': 's$i'})]),
      ],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyPath path;

  setUpAll(() {
    path = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());
    StudyPath.useBundled(path);
  });
  tearDownAll(() => StudyPath.useBundled(null));

  group('the badges', () {
    test('there are thirty-nine badges for the bundled path with unique ids and the families in order', () {
      final all = StudyAward.all(path);
      expect(all.length, 39);
      expect(all.map((award) => award.id).toSet().length, all.length, reason: 'Ids repeat');
      List<int> goals(StudyAwardFamily family) => [for (final award in all) if (award.family == family) award.goal];
      expect([for (final award in all) if (award.family == StudyAwardFamily.lessons) award.id], ['lessons-1', 'lessons-10', 'lessons-30', 'lessons-all']);
      expect(goals(StudyAwardFamily.lessons), [1, 10, 30, path.lessons.length]);
      expect(goals(StudyAwardFamily.streak), [3, 7, 14, 30]);
      expect(goals(StudyAwardFamily.tags), [10, 50, 150, 300]);
      expect(goals(StudyAwardFamily.perfect), [1, 10, 25]);
      expect(goals(StudyAwardFamily.combo), [5, 10, 20]);
      expect(goals(StudyAwardFamily.xp), [100, 500, 2000]);
      expect([for (final award in all) if (award.family == StudyAwardFamily.studio) award.id], ['studio-key', 'studio-1', 'studio-3', 'studio-10', 'studio-50']);
      expect(goals(StudyAwardFamily.speed), [10, 20]);
      expect(all.where((award) => award.family == StudyAwardFamily.sections).length, path.sections.where((section) => section.lessons.isNotEmpty).length);
      final positions = [for (final award in all) award.family.index];
      expect(positions, [...positions]..sort(), reason: "A family's badges sit together in family order");
      for (final award in all) {
        expect(award.goal, greaterThan(0), reason: award.id);
        expect(award.symbol, isNotEmpty, reason: award.id);
      }
    });

    test('each section with lessons has one badge carrying its colour, title and lesson count', () {
      final sections = StudyAward.all(path).where((award) => award.family == StudyAwardFamily.sections).toList();
      final withLessons = path.sections.where((section) => section.lessons.isNotEmpty).toList();
      expect(sections.map((award) => award.id), [for (final section in withLessons) 'section-${section.id}']);
      for (final (index, award) in sections.indexed) {
        final section = withLessons[index];
        expect(award.section, section.id);
        expect(award.goal, section.lessons.length, reason: section.id);
        expect(award.color, section.color);
        expect(award.sectionTitle, section.title);
      }
    });

    test('the studio badge for advanced settings asks for the advanced picture count', () {
      expect(StudyAward.advancedPictures, 3);
      expect(StudyAward.all(path).firstWhere((award) => award.id == 'studio-3').goal, StudyAward.advancedPictures);
    });

    test('the metals rise within a family and the graduate badge is a prism', () {
      final all = StudyAward.all(path);
      Iterable<StudyAwardMetal> metals(StudyAwardFamily family) => all.where((award) => award.family == family).map((award) => award.metal);
      expect(metals(StudyAwardFamily.streak), [StudyAwardMetal.bronze, StudyAwardMetal.silver, StudyAwardMetal.gold, StudyAwardMetal.prism]);
      expect(metals(StudyAwardFamily.combo), [StudyAwardMetal.bronze, StudyAwardMetal.silver, StudyAwardMetal.gold]);
      expect(all.firstWhere((award) => award.id == 'lessons-all').metal, StudyAwardMetal.prism);
    });

    test('the graduate badge follows the path length and empty sections get no badge', () {
      final all = StudyAward.all(samplePath);
      expect(all.firstWhere((award) => award.id == 'lessons-all').goal, 5);
      expect([for (final award in all) if (award.family == StudyAwardFamily.sections) award.id], ['section-a', 'section-b'], reason: 'The empty section has no badge');
      expect(StudyAward.all(const StudyPath()).firstWhere((award) => award.id == 'lessons-all').goal, 1, reason: 'Never a goal of zero');
      expect(StudyAward.all(const StudyPath()).length, 39 - path.sections.where((section) => section.lessons.isNotEmpty).length);
    });

    test('a section badge is named by its section and the others by their English wording', () {
      final all = StudyAward.all(samplePath);
      expect(all.firstWhere((award) => award.id == 'section-a').name, 'A');
      expect(all.firstWhere((award) => award.id == 'lessons-1').name, 'First Step');
      expect(all.firstWhere((award) => award.id == 'lessons-1').explanation, 'Finish your first lesson.');
      expect(StudyAwardFamily.streak.title, 'Day streak');
    });
  });

  group('facts', () {
    test('facts of nothing are zero', () {
      final none = facts();
      expect(StudyFacts(), StudyFacts());
      expect([none.streak, none.learned, none.perfect, none.combo, none.xp, none.pictures, none.speed], [0, 0, 0, 0, 0, 0, 0]);
      expect(none.lessons, 0);
      expect(none.key, isFalse);
      for (final award in StudyAward.all(samplePath)) {
        expect(none.has(award), isFalse, reason: award.id);
        expect(none.progress(award), 0, reason: award.id);
      }
    });

    test('facts count only finished lessons that are in the path and per section', () {
      final found = facts(records: {'a1': record('a1'), 'a3': record('a3'), 'b2': record('b2'), 'gone': record('gone', stars: 3)});
      expect(found.lessons, 3, reason: 'A lesson that left the path is not counted');
      expect(found.sections, {'a': 2, 'b': 1, 'c': 0});
      expect(found.perfect, 1, reason: 'Three stars count wherever the lesson is');
      expect(found.value(award('section-a')), 2);
      expect(found.value(award('section-b')), 1);
      expect(found.has(award('section-a')), isFalse);
      expect(found.progress(award('section-a')), closeTo(2 / 3, 1e-9));
      final everything = facts(records: {for (final id in ['a1', 'a2', 'a3', 'b1', 'b2']) id: record(id)});
      expect(everything.has(award('section-a')), isTrue);
      expect(everything.has(award('section-b')), isTrue);
      expect(everything.has(award('lessons-all')), isTrue);
      expect(everything.has(award('lessons-10')), isFalse);
      expect(everything.progress(award('lessons-all')), 1);
    });

    test('perfect counts three-star lessons only', () {
      final found = facts(records: {'a1': record('a1', stars: 3), 'a2': record('a2', stars: 2), 'a3': record('a3', stars: 3), 'b1': record('b1')});
      expect(found.perfect, 2);
      expect(found.value(award('perfect-1')), 2);
      expect(found.has(award('perfect-1')), isTrue);
      expect(found.has(award('perfect-10')), isFalse);
    });

    test('the streak is the longer of the days\' run and the stored counter', () {
      final run = [day(0), day(1), day(2)];
      expect(facts(days: run).streak, 3);
      expect(facts(days: run, stats: {StudyCounter.streak: 5}).streak, 5, reason: 'A best run survives a missed day');
      expect(facts(days: run, stats: {StudyCounter.streak: 1}).streak, 3);
      expect(facts(days: [day(0), day(2)]).streak, 1, reason: 'A gap ends the run');
      expect(facts(days: [day(1), day(2)]).streak, 2, reason: "Yesterday still counts before today's study");
      expect(facts(days: const [], stats: {StudyCounter.streak: 7}).streak, 7);
      expect(facts(days: run).has(award('streak-3')), isTrue);
      expect(facts(days: run).has(award('streak-7')), isFalse);
    });

    test('learned counts tags at the learned step and xp sums every day', () {
      final progress = {
        't1': StudyProgress(tag: 't1', step: StudyProgress.learnedStep),
        't2': StudyProgress(tag: 't2', step: StudyProgress.learnedStep - 1),
        't3': StudyProgress(tag: 't3', step: StudyProgress.lastStep),
      };
      final found = facts(days: [day(0, xp: 60), day(1, xp: 45), day(5)], progress: progress);
      expect(found.learned, 2);
      expect(found.xp, 105);
      expect(found.has(award('xp-100')), isTrue);
      expect(found.has(award('xp-500')), isFalse);
      expect(found.has(award('tags-10')), isFalse);
      expect(found.progress(award('tags-10')), closeTo(0.2, 1e-9));
    });

    test('counters feed combo, pictures, speed and the key', () {
      final found = facts(stats: {StudyCounter.combo: 12, StudyCounter.pictures: 3, StudyCounter.speed: 10, StudyCounter.key: 1});
      expect(found.combo, 12);
      expect(found.pictures, 3);
      expect(found.speed, 10);
      expect(found.key, isTrue);
      expect(found.has(award('combo-10')), isTrue);
      expect(found.has(award('combo-20')), isFalse);
      expect(found.has(award('studio-key')), isTrue);
      expect(found.has(award('studio-1')), isTrue);
      expect(found.has(award('studio-3')), isTrue);
      expect(found.has(award('studio-10')), isFalse);
      expect(found.has(award('speed-10')), isTrue);
      expect(found.has(award('speed-20')), isFalse);
      expect(found.value(award('studio-key')), 1);
      expect(facts(stats: {StudyCounter.pictures: 9}).value(award('studio-key')), 0, reason: 'Pictures do not stand in for the key');
      expect(facts(stats: {StudyCounter.pictures: 9}).has(award('studio-key')), isFalse);
      expect(facts(stats: {StudyCounter.key: 0}).key, isFalse);
    });

    test('progress stops at one and a zero goal is always done', () {
      final found = facts(stats: {StudyCounter.combo: 500});
      expect(found.progress(award('combo-5')), 1);
      const free = StudyAward(id: 'x', family: StudyAwardFamily.xp, metal: StudyAwardMetal.bronze, symbol: 'x', title: 'x', detail: 'x', goal: 0);
      expect(StudyFacts().progress(free), 1);
    });
  });

  group('the store', () {
    test('granting records a badge once keeps its first date and marking seen sticks', () {
      final study = BooruStore.inMemory().studyStore;
      expect(study.awards(), isEmpty);
      final early = StudyStore.date(1000000), late = StudyStore.date(2000000);
      study.grant(['a', 'b'], now: early);
      study.grant([], now: late);
      study.grant(['a', 'c'], seen: true, now: late);
      final found = study.awards();
      expect(found.keys.toSet(), {'a', 'b', 'c'});
      expect(found['a']?.earned, early, reason: 'An earlier date is not overwritten');
      expect(found['a']?.seen, isFalse, reason: 'Nor is its seen flag');
      expect(found['c']?.earned, late);
      expect(found['c']?.seen, isTrue);
      study.markSeen(['a', 'missing']);
      study.markSeen([]);
      expect(study.awards()['a']?.seen, isTrue);
      expect(study.awards()['b']?.seen, isFalse);
      expect(study.awards()['missing'], isNull);
    });

    test('raising a counter sets it and never lowers it', () {
      final study = BooruStore.inMemory().studyStore;
      expect(study.stats(), isEmpty);
      study.raise('combo', 5);
      study.raise('combo', 3);
      expect(study.stats()['combo'], 5);
      study.raise('combo', 9);
      study.raise('speed', 0);
      expect(study.stats(), {'combo': 9, 'speed': 0});
    });

    test('reset clears badges and counters too', () {
      final study = BooruStore.inMemory().studyStore;
      study.grant(['a']);
      study.raise('combo', 5);
      study.earn(10, lesson: 'a1', stars: 3);
      study.reset();
      expect(study.awards(), isEmpty);
      expect(study.stats(), isEmpty);
      expect(study.lessons(), isEmpty);
      expect(study.days(), isEmpty);
    });

    test('the award tables survive a reopened database file', () {
      final folder = Directory.systemTemp.createTempSync('awards-');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = '${folder.path}/a.sqlite';
      void migrate(SqlDatabase database) {
        final migrator = SqlMigrator()
          ..registerMigration('study', StudyStore.migrate)
          ..registerMigration('game', StudyStore.migrateGame)
          ..registerMigration('awards', StudyStore.migrateAwards);
        migrator.migrate(database);
      }

      final first = SqlDatabase.open(file);
      migrate(first);
      final study = StudyStore.withDatabase(first);
      study.grant(['x'], now: StudyStore.date(5));
      study.raise('speed', 4);
      migrate(first);
      first.close();
      final reopened = SqlDatabase.open(file);
      addTearDown(reopened.close);
      migrate(reopened);
      final again = StudyStore.withDatabase(reopened);
      expect(again.awards()['x']?.earned, StudyStore.date(5));
      expect(again.stats()['speed'], 4);
    });

    test('a store made by the app has the game and award tables with the names iOS uses', () {
      final database = BooruStore.inMemory().database;
      expect(database.columns('study_lessons'), ['lesson', 'stars', 'runs', 'finished']);
      expect(database.columns('study_days'), ['day', 'answered', 'correct', 'xp']);
      expect(database.columns('study_awards'), ['id', 'earned', 'seen']);
      expect(database.columns('study_stats'), ['name', 'value']);
    });
  });

  group('refresh', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('awards-gen-'));
    tearDown(() => directory.deleteSync(recursive: true));

    Future<GenerationStore> generation({String key = '', int pictures = 0}) async {
      final store = GenerationStore(
        folder: Directory('${directory.path}/Generated${Random().nextInt(1 << 30)}'),
        defaults: MemoryPreferences(),
        keychain: GenerationKeychain(MemorySecureStorage()),
      );
      if (key.isNotEmpty) await store.save(key);
      for (var number = 0; number < pictures; number++) {
        store.add(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, number]), prompt: 'p$number', settings: store.settings);
      }
      return store;
    }

    test('with nothing done grants nothing', () async {
      final store = BooruStore.inMemory();
      expect(StudyAwards.refresh(store, path: samplePath, generation: await generation()), isEmpty);
      expect(store.studyStore.awards(), isEmpty);
    });

    test('grants what the facts earned and returns the unseen ones in gallery order until they are marked seen', () async {
      final store = BooruStore.inMemory();
      store.studyStore.earn(120, lesson: 'a1', stars: 3);
      final gallery = StudyAward.all(samplePath).map((award) => award.id).toList();
      final first = StudyAwards.refresh(store, path: samplePath, generation: await generation());
      expect(first.map((award) => award.id), ['lessons-1', 'perfect-1', 'xp-100']);
      expect(first.map((award) => gallery.indexOf(award.id)), [...first.map((award) => gallery.indexOf(award.id))]..sort());
      expect(store.studyStore.awards().keys.toSet(), {'lessons-1', 'perfect-1', 'xp-100'});

      final again = StudyAwards.refresh(store, path: samplePath, generation: await generation());
      expect(again.map((award) => award.id), first.map((award) => award.id), reason: 'Still unseen');

      store.studyStore.markSeen(['lessons-1', 'xp-100']);
      expect(StudyAwards.refresh(store, path: samplePath, generation: await generation()).map((award) => award.id), ['perfect-1']);
      store.studyStore.markSeen(['perfect-1']);
      expect(StudyAwards.refresh(store, path: samplePath, generation: await generation()), isEmpty);
      expect(store.studyStore.awards().keys.toSet(), {'lessons-1', 'perfect-1', 'xp-100'}, reason: 'Nothing is granted twice');
    });

    test('reads the generator\'s pictures and key into counters', () async {
      final store = BooruStore.inMemory();
      final earned = StudyAwards.refresh(store, path: samplePath, generation: await generation(key: 'secret', pictures: 3));
      expect(earned.map((award) => award.id), ['studio-key', 'studio-1', 'studio-3']);
      expect(store.studyStore.stats()[StudyCounter.pictures], 3);
      expect(store.studyStore.stats()[StudyCounter.key], 1);

      // Pictures deleted later do not take a badge or its counter back.
      expect(StudyAwards.refresh(store, path: samplePath, generation: await generation()).map((award) => award.id), ['studio-key', 'studio-1', 'studio-3']);
      expect(store.studyStore.stats()[StudyCounter.pictures], 3);
      expect(store.studyStore.awards().keys.toSet(), {'studio-key', 'studio-1', 'studio-3'});
    });

    test('keeps a longest streak and completes a section badge', () async {
      final store = BooruStore.inMemory();
      for (final id in ['a1', 'a2', 'a3']) {
        store.studyStore.earn(10, lesson: id, stars: 1);
      }
      final earned = StudyAwards.refresh(store, path: samplePath, generation: await generation());
      expect(earned.any((award) => award.id == 'section-a'), isTrue);
      expect(earned.any((award) => award.id == 'section-b'), isFalse);
      expect(store.studyStore.stats()[StudyCounter.streak], 1);
      expect(StudyAwards.facts(store, path: samplePath).sections['a'], 3);
    });
  });

  group('speed round', () {
    StudySpeedRound round(BooruStore store, {int seed = 1}) => StudySpeedRound(store: store, curriculum: curriculum(), random: Random(seed));

    void met(BooruStore store, List<String> names) {
      for (final name in names) {
        store.studyStore.answer(name, right: true);
      }
    }

    StudySpeedRound playing(BooruStore store) {
      met(store, ['s1', 's2', 's3', 's4', 's5']);
      return round(store)..start();
    }

    int todayXP(BooruStore store) => store.studyStore.days().firstWhere((day) => day.day == StudyDay.key(DateTime.now())).xp;

    test('asks only tags already answered and needs four of them', () {
      final store = BooruStore.inMemory();
      met(store, ['s1', 's2', 's3']);
      final few = round(store);
      expect(few.tags.map((tag) => tag.name), ['s1', 's2', 's3']);
      expect(few.canPlay, isFalse);
      few.start();
      expect(few.phase, StudySpeedPhase.ready, reason: 'Three tags cannot offer four answers');
      expect(few.question, isNull);

      store.studyStore.answer('s4', right: false);
      final four = round(store);
      expect(four.tags.map((tag) => tag.name), ['s1', 's2', 's3', 's4'], reason: 'A wrong answer is an answer too');
      expect(four.canPlay, isTrue);
      expect(StudySpeedRound.met({}, curriculum: curriculum()), isEmpty);
      expect(
        StudySpeedRound.met({'s5': StudyProgress(tag: 's5'), 'x': StudyProgress(tag: 'x', correct: 1)}, curriculum: curriculum()),
        isEmpty,
        reason: 'A new tag and an untaught tag are not met',
      );
    });

    test('the reward is the score capped at twenty and never negative', () {
      expect(StudySpeedRound.reward(0), 0);
      expect(StudySpeedRound.reward(7), 7);
      expect(StudySpeedRound.reward(20), 20);
      expect(StudySpeedRound.reward(35), 20);
      expect(StudySpeedRound.reward(-4), 0);
    });

    test('starting asks a first question with four choices and the right answer among them', () {
      final started = DateTime.now();
      final play = playing(BooruStore.inMemory());
      expect(play.phase, StudySpeedPhase.playing);
      final question = play.question!;
      expect(question.choices.length, 4);
      expect(question.choices.map((tag) => tag.name).toSet().length, 4);
      expect(question.choices[question.answer], question.tag);
      expect(question.kind, StudyQuestionKind.meaningToTag);
      expect(play.ends.isAfter(started), isTrue);
      final phase = play.phase;
      play.start();
      expect(play.phase, phase, reason: 'Starting again changes nothing');
    });

    test('a round starts at the time it is given', () {
      final store = BooruStore.inMemory();
      met(store, ['s1', 's2', 's3', 's4']);
      final play = round(store)..start(DateTime.utc(2026, 1, 1));
      expect(play.ends, DateTime.utc(2026, 1, 1, 0, 1));
      expect(StudySpeedRound.length, 60);
    });

    test('a right answer raises score and combo, a wrong one resets the combo and a second answer is ignored', () {
      final play = playing(BooruStore.inMemory());
      var question = play.question!;
      expect(play.answer(question.answer), isTrue);
      expect(play.score, 1);
      expect(play.combo, 1);
      expect(play.last, isTrue);
      expect(play.answer(question.answer), isFalse, reason: 'A second answer before next() is ignored');
      expect(play.score, 1);
      expect(play.asked, 1);
      play.next();
      expect(play.last, isNull);
      question = play.question!;
      expect(play.answer(question.answer), isTrue);
      play.next();
      expect(play.combo, 2);
      question = play.question!;
      expect(play.answer((question.answer + 1) % 4), isFalse);
      expect(play.combo, 0);
      expect(play.bestCombo, 2);
      expect(play.score, 2);
      expect(play.asked, 3);
      expect(play.last, isFalse);
      play.answer(question.answer);
      expect(play.score, 2, reason: 'Still ignored after a wrong answer');
    });

    test('next never asks the same tag twice in a row', () {
      final play = playing(BooruStore.inMemory());
      var previous = play.question!.tag;
      for (var i = 0; i < 30; i++) {
        play
          ..answer(play.question!.answer)
          ..next();
        final current = play.question!.tag;
        expect(current, isNot(previous));
        previous = current;
      }
    });

    test('answers and finish do nothing outside a round', () {
      final store = BooruStore.inMemory();
      met(store, ['s1', 's2', 's3', 's4']);
      final play = round(store);
      expect(play.answer(0), isFalse);
      play.finish();
      expect(play.phase, StudySpeedPhase.ready);
      expect(store.studyStore.stats(), isEmpty);
      play
        ..start()
        ..answer(play.question!.answer)
        ..finish();
      final earned = play.earned;
      play.finish();
      expect(play.answer(0), isFalse, reason: 'Nothing is answered after the end');
      expect(play.earned, earned);
      expect(todayXP(store), 1, reason: 'Finishing twice pays once');
    });

    test('finishing earns the reward on today, raises both counters and flags a record only when the best is beaten', () {
      final store = BooruStore.inMemory();
      final play = playing(store);
      for (var i = 0; i < 6; i++) {
        play
          ..answer(play.question!.answer)
          ..next();
      }
      play
        ..answer((play.question!.answer + 1) % 4)
        ..next()
        ..answer(play.question!.answer)
        ..next()
        ..finish();
      expect(play.phase, StudySpeedPhase.finished);
      expect(play.score, 7);
      expect(play.earned, 7);
      expect(play.record, isTrue, reason: 'The first round with a score beats a best of nothing');
      expect(todayXP(store), 7);
      expect(store.studyStore.stats()[StudyCounter.speed], 7);
      expect(store.studyStore.stats()[StudyCounter.combo], 6);

      // A tie is not a record.
      final tie = round(store, seed: 2);
      expect(tie.best, 7);
      tie.start();
      for (var i = 0; i < 7; i++) {
        tie
          ..answer(tie.question!.answer)
          ..next();
      }
      tie.finish();
      expect(tie.record, isFalse);
      expect(store.studyStore.stats()[StudyCounter.speed], 7);
      expect(store.studyStore.stats()[StudyCounter.combo], 7, reason: 'The longer run raises the combo counter');

      final weaker = round(store, seed: 3)..start();
      weaker
        ..answer(weaker.question!.answer)
        ..next()
        ..finish();
      expect(weaker.record, isFalse);
      expect(store.studyStore.stats()[StudyCounter.speed], 7, reason: 'A counter never goes down');
      expect(store.studyStore.stats()[StudyCounter.combo], 7);

      final better = round(store, seed: 4)..start();
      for (var i = 0; i < 9; i++) {
        better
          ..answer(better.question!.answer)
          ..next();
      }
      better.finish();
      expect(better.record, isTrue);
      expect(store.studyStore.stats()[StudyCounter.speed], 9);
    });

    test('a round with no right answer earns nothing and is no record', () {
      final store = BooruStore.inMemory();
      final play = playing(store);
      play
        ..answer((play.question!.answer + 1) % 4)
        ..next()
        ..finish();
      expect(play.earned, 0);
      expect(play.record, isFalse);
      expect(todayXP(store), 0, reason: 'No experience for a round that earned none');
    });

    test('a score above twenty pays twenty and the counter keeps the score', () {
      final store = BooruStore.inMemory();
      final play = playing(store);
      for (var i = 0; i < 25; i++) {
        play
          ..answer(play.question!.answer)
          ..next();
      }
      play.finish();
      expect(play.score, 25);
      expect(play.earned, 20);
      expect(todayXP(store), 20);
      expect(store.studyStore.stats()[StudyCounter.speed], 25);
      expect(store.studyStore.stats()[StudyCounter.combo], 25);
    });
  });
}
