// Ported from native-ios/TEGNALTests/StudyPathTests.swift. Dart takes a seeded `Random` where Swift takes a
// `SplitMix64` generator and a `utcOffset` where Swift takes a `Calendar`. The path is read from the bundled file.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_session.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';

const utc = Duration.zero;

DateTime date(int year, int month, int day, {int hour = 12}) => DateTime.utc(year, month, day, hour);

StudyTag plainTag(String name) => StudyTag(name: name, ko: name, ja: name, note: {'en': name});

final pathServer = BooruServer(id: 'path-test', name: 'Path', baseURL: 'https://path.example', engine: BooruEngine.danbooru);

BooruServer server(String id, String host, BooruEngine engine) => BooruServer(id: id, name: id, baseURL: 'https://$host', engine: engine);

/// Eight loose tags the lessons are made of, and three more in another group, none of them exclusive.
StudyCurriculum pathCurriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'pu',
      title: const {'en': 'P'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(id: 'pg', title: const {'en': 'G'}, tags: [for (var i = 1; i <= 8; i++) plainTag('t$i')]),
        StudyGroup(id: 'ph', title: const {'en': 'H'}, tags: [for (var i = 1; i <= 3; i++) plainTag('h$i')]),
      ],
    ),
  ],
);

/// Answers every tag with five still pictures that carry it, and any tags `extra` adds for it, immediately.
class PathFakeSource with BooruTagStudyUnsupported implements BooruProviding {
  PathFakeSource({this.extra = const {}, this.failing = false});
  final Map<String, List<String>> extra;
  final bool failing;

  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    if (failing) throw const FormatException('offline');
    // Far from the fixture ids that stand for a GIF and a video.
    final base = 1000000 + query.runes.fold<int>(0, (hash, rune) => (hash * 31 + rune) % 100000) * 10;
    return BooruBatch(
      posts: [for (var index = 0; index < 5; index++) BooruFixtureSource.post(base + index, server, tags: [query, ...?extra[query]])],
      hasMore: false,
    );
  }

  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async => [];
  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => [];
  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async => [];
  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async => post;
}

StudyLessonRecord record(StudyPathLesson lesson, {int stars = 3}) => StudyLessonRecord(lesson: lesson.id, stars: stars, runs: 1);

StudyPathAsk ask({int answer = 0, int count = 3, bool? code}) => StudyPathAsk(
  question: const {'en': 'Q'},
  choices: [for (var i = 0; i < count; i++) {'en': 'choice $i'}],
  answer: answer,
  why: const {'en': 'Because'},
  code: code,
);

StudyPathBuild build(List<String> answer, {List<String> extras = const ['crying']}) => StudyPathBuild(brief: const {'en': 'A picture'}, answer: answer, extras: extras);

StudyPathOrder order(List<String> items) => StudyPathOrder(brief: const {'en': 'Put in order'}, items: [for (final item in items) {'en': item}], why: const {'en': 'Because'});

List<StudyText> text(List<String> items) => [for (final item in items) {'en': item}];

StudyPathLesson tagsLesson([String id = 'p-tags', List<String> tags = const ['t1', 't2', 't3', 't4']]) =>
    StudyPathLesson(id: id, kind: StudyPathLessonKind.tags, symbol: 'tag', title: {'en': id}, tags: tags);

List<String> kinds(List<StudyStep> steps) => [
  for (final step in steps)
    switch (step.kind) {
      StudyStepCard() => 'card',
      StudyStepTeach() => 'teach',
      StudyStepQuiz() => 'quiz',
      StudyStepAsk() => 'ask',
      StudyStepMatch() => 'match',
      StudyStepBuild() => 'build',
      StudyStepOrder() => 'order',
      StudyStepSort() => 'sort',
      StudyStepOdd() => 'odd',
      StudyStepSpell() => 'spell',
    },
];

String? quizTag(StudyStep? step) => switch (step?.kind) {
  StudyStepQuiz(:final question) => question.tag.name,
  _ => null,
};

/// Plays a session to its end, answering every asked step as `right` says and moving past cards and new tags.
void play(StudyLessonSession session, {bool Function(StudyStep step)? right}) {
  var turns = 0;
  while (session.phase == StudyLessonPhase.asking && session.step != null && turns < 500) {
    turns += 1;
    final step = session.step!;
    if (step.isAsked) {
      session.answer(right == null ? true : right(step), tag: quizTag(step));
      session.next();
    } else {
      session.proceed();
    }
  }
}

/// Moves past anything that is only read, then answers the step that is asked.
void answerOne(StudyLessonSession session, bool right) {
  while (session.phase == StudyLessonPhase.asking && session.step != null && !session.step!.isAsked) {
    session.proceed();
  }
  session.answer(right, tag: quizTag(session.step));
}

int todaysXP(BooruStore store) => store.studyStore.days().where((day) => day.day == StudyDay.key(DateTime.now())).firstOrNull?.xp ?? 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyPath path;
  late StudyCurriculum curriculum;

  setUpAll(() {
    // What `loadBundled` reads from the asset bundle, read from the files for these tests.
    path = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());
    StudyPath.useBundled(path);
    curriculum = StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync());
    StudyCurriculum.useBundled(curriculum);
  });
  tearDownAll(() {
    StudyPath.useBundled(null);
    StudyCurriculum.useBundled(null);
  });

  StudyLessonSession makeSession(StudyLessonPlan plan, BooruStore store, {BooruProviding? source, Random? random}) =>
      StudyLessonSession(plan: plan, store: store, source: source ?? PathFakeSource(), server: pathServer, engine: StudyEngine(curriculum: pathCurriculum()), random: random);

  group('path data', () {
    test('the bundled path decodes and its sections are in order', () {
      expect(path.sections, isNotEmpty, reason: 'The file is missing or does not decode');
      expect(path.sections.map((section) => section.id), ['s0', 's1', 'mind', 'tools', 'api', 's2', 's3', 's4', 's5', 's6', 's7']);
      expect(path.sections.where((section) => section.lessons.isEmpty).map((section) => section.id), isEmpty, reason: 'Every section has lessons now');
      expect(path.lessons.length, 62);
      expect(path.lessons.length, path.sections.fold(0, (total, section) => total + section.lessons.length));
    });

    test('lesson ids are unique and section colours are six hex digits', () {
      final ids = path.lessons.map((lesson) => lesson.id).toList();
      expect(ids.length, ids.toSet().length);
      expect(ids.where((id) => id.isEmpty), isEmpty);
      for (final section in path.sections) {
        expect(RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(section.color), isTrue, reason: '${section.id} colour ${section.color}');
      }
    });

    test('every text of the path has English, Korean and Japanese except the choices of prompt-text questions', () {
      final problems = <String>[];
      void check(StudyText value, String label, {List<String> languages = const ['en', 'ko', 'ja']}) {
        for (final language in languages) {
          if ((value[language] ?? '').isEmpty) problems.add('$label.$language');
        }
      }

      for (final section in path.sections) {
        check(section.title, '${section.id} title');
        check(section.summary, '${section.id} summary');
        for (final lesson in section.lessons) {
          check(lesson.title, '${lesson.id} title');
          if (lesson.summary != null) check(lesson.summary!, '${lesson.id} summary');
          for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
            final label = '${lesson.id}#$index';
            final card = step.card;
            if (card != null) {
              check(card.title, '$label card.title');
              check(card.body, '$label card.body');
            }
            final question = step.ask;
            if (question != null) {
              check(question.question, '$label ask.question');
              check(question.why, '$label ask.why');
              for (final (number, choice) in question.choices.indexed) {
                check(choice, '$label ask.choice$number', languages: question.code == true ? const ['en'] : const ['en', 'ko', 'ja']);
              }
            }
            if (step.build != null) check(step.build!.brief, '$label build.brief');
            final ordering = step.order;
            if (ordering != null) {
              check(ordering.brief, '$label order.brief');
              check(ordering.why, '$label order.why');
              for (final (number, item) in ordering.items.indexed) {
                check(item, '$label order.item$number');
              }
            }
            final sorting = step.sort;
            if (sorting != null) {
              check(sorting.brief, '$label sort.brief');
              check(sorting.left, '$label sort.left');
              check(sorting.right, '$label sort.right');
              check(sorting.why, '$label sort.why');
              for (final (number, item) in sorting.items.indexed) {
                check(item.text, '$label sort.item$number');
              }
            }
          }
        }
      }
      expect(problems, isEmpty);
    });

    test('every step is exactly one thing and every lesson has what its kind needs', () {
      final problems = <String>[];
      for (final lesson in path.lessons) {
        switch (lesson.kind) {
          case StudyPathLessonKind.tags:
            if ((lesson.tags ?? const []).isEmpty) problems.add('${lesson.id} has no tags');
            if (lesson.steps != null) problems.add('${lesson.id} is a tags lesson with steps');
          case StudyPathLessonKind.concept || StudyPathLessonKind.boss:
            if ((lesson.steps ?? const []).isEmpty) problems.add('${lesson.id} has no steps');
        }
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final filled = [step.card != null, step.ask != null, step.build != null, step.order != null, step.sort != null].where((value) => value).length;
          if (filled != 1) problems.add('${lesson.id}#$index holds $filled things');
        }
      }
      expect(problems, isEmpty);
    });

    test('every tags lesson names only curriculum tags and at least four', () {
      expect(curriculum.tags, isNotEmpty);
      final problems = <String>[];
      for (final lesson in path.lessons.where((lesson) => lesson.kind == StudyPathLessonKind.tags)) {
        final tags = lesson.tags ?? const <String>[];
        if (tags.length < 4 || tags.length > 6) problems.add('${lesson.id} has ${tags.length} tags');
        if (tags.length != tags.toSet().length) problems.add('${lesson.id} repeats a tag');
        for (final tag in tags.where((tag) => !curriculum.contains(tag))) {
          problems.add('${lesson.id} -> $tag is not taught');
        }
      }
      expect(problems, isEmpty);
    });

    test('every ask has two to four distinct choices and an answer among them', () {
      final problems = <String>[];
      for (final lesson in path.lessons) {
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final question = step.ask;
          if (question == null) continue;
          final label = '${lesson.id}#$index';
          if (question.choices.length < 2 || question.choices.length > 4) problems.add('$label has ${question.choices.length} choices');
          if (question.answer < 0 || question.answer >= question.choices.length) problems.add('$label answer ${question.answer} is out of range');
          final english = [for (final choice in question.choices) choice['en'] ?? ''];
          if (english.length != english.toSet().length) problems.add('$label repeats a choice');
        }
      }
      expect(problems, isEmpty);
    });

    test('every build uses curriculum tags, keeps extras apart and writes one or two headcount tags first', () {
      final problems = <String>[];
      var builds = 0;
      for (final lesson in path.lessons) {
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final target = step.build;
          if (target == null) continue;
          builds += 1;
          final label = '${lesson.id}#$index';
          for (final tag in [...target.answer, ...target.extras].where((tag) => !curriculum.contains(tag))) {
            problems.add('$label -> $tag is not taught');
          }
          if (target.answer.length != target.answer.toSet().length) problems.add('$label repeats an answer tag');
          if (target.extras.length != target.extras.toSet().length) problems.add('$label repeats an extra');
          if (target.answer.toSet().intersection(target.extras.toSet()).isNotEmpty) problems.add('$label extras overlap the answer');
          final headcount = target.answer.where(StudyPrompt.leading.contains).toList();
          final written = target.answer.takeWhile(StudyPrompt.leading.contains).toList();
          if (headcount.isEmpty || headcount.length > 2) problems.add('$label has ${headcount.length} headcount tags');
          if (written.length != headcount.length) problems.add('$label does not write its headcount tags first');
        }
      }
      expect(builds, greaterThan(0), reason: 'No build in the bundled path');
      expect(problems, isEmpty);
    });

    test('every order has three to six distinct items and a reason', () {
      final problems = <String>[];
      var orders = 0;
      for (final lesson in path.lessons) {
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final ordering = step.order;
          if (ordering == null) continue;
          orders += 1;
          final label = '${lesson.id}#$index';
          if (ordering.items.length < 3 || ordering.items.length > 6) problems.add('$label has ${ordering.items.length} items');
          final english = [for (final item in ordering.items) item['en'] ?? ''];
          if (english.length != english.toSet().length) problems.add('$label repeats an item');
          if ((ordering.why['en'] ?? '').isEmpty) problems.add('$label has no why');
        }
      }
      expect(orders, greaterThan(0), reason: 'No order in the bundled path');
      expect(problems, isEmpty);
    });

    test('every sort has three to six distinct items for both sides and two different labels', () {
      final problems = <String>[];
      var sorts = 0;
      for (final lesson in path.lessons) {
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final sorting = step.sort;
          if (sorting == null) continue;
          sorts += 1;
          final label = '${lesson.id}#$index';
          if (sorting.items.length < 3 || sorting.items.length > 6) problems.add('$label has ${sorting.items.length} items');
          if (!sorting.items.any((item) => item.right)) problems.add('$label has nothing for the right side');
          if (!sorting.items.any((item) => !item.right)) problems.add('$label has nothing for the left side');
          final english = [for (final item in sorting.items) item.text['en'] ?? ''];
          if (english.length != english.toSet().length) problems.add('$label repeats an item');
          if (sorting.left['en'] == sorting.right['en']) problems.add('$label has the same label on both sides');
          if ((sorting.why['en'] ?? '').isEmpty) problems.add('$label has no why');
        }
      }
      expect(sorts, greaterThan(0), reason: 'No sort in the bundled path');
      expect(problems, isEmpty);
    });

    test('every card pose and action is allowed and a generator action carries code', () {
      const poses = {'wave', 'cheer', 'think', 'sad', 'read', 'close-up', 'full-body'};
      const actions = {'civitai', 'key', 'generator'};
      final problems = <String>[];
      var generators = 0;
      for (final lesson in path.lessons) {
        for (final (index, step) in (lesson.steps ?? const <StudyPathStep>[]).indexed) {
          final card = step.card;
          if (card == null) continue;
          final label = '${lesson.id}#$index';
          if (card.pose != null && !poses.contains(card.pose)) problems.add('$label pose ${card.pose}');
          if (card.action != null && !actions.contains(card.action)) problems.add('$label action ${card.action}');
          if (card.action == 'generator') {
            generators += 1;
            if ((card.code ?? '').isEmpty) problems.add('$label opens the generator without code');
          }
        }
      }
      expect(generators, greaterThan(0), reason: 'No generator card in the bundled path');
      expect(problems, isEmpty);
    });

    test('the api lessons come in order and before every lesson that generates', () {
      final api = path.sections.where((section) => section.id == 'api').first;
      expect(api.lessons.map((lesson) => lesson.id), ['api-what', 'api-key', 'api-buzz', 'api-doors', 'api-issue', 'api-air', 'api-first']);
      expect(path.lessons.any((lesson) => lesson.id == 'tools-myth'), isFalse, reason: 'tools-myth was removed');
      final ids = path.sections.map((section) => section.id).toList();
      final apiIndex = ids.indexOf('api');
      expect(apiIndex, greaterThanOrEqualTo(0));
      for (final later in ['s5', 's6', 's7']) {
        expect(ids.indexOf(later), greaterThan(apiIndex), reason: 'api comes before $later');
      }
    });

    test('the bundled path is version three', () {
      expect(path.version, 3);
    });

    test('the tag lessons of the middle sections have five tags each, a boss ends them and a concept follows', () {
      for (final id in ['s2', 's3', 's4']) {
        final section = path.sections.where((section) => section.id == id).first;
        final tagLessons = section.lessons.where((lesson) => lesson.kind == StudyPathLessonKind.tags).toList();
        expect(tagLessons, isNotEmpty, reason: id);
        for (final lesson in tagLessons) {
          expect(lesson.tags?.length, 5, reason: lesson.id);
        }
        expect(section.lessons.last.id, '$id-boss', reason: '$id ends with its boss');
        expect(section.lessons.last.kind, StudyPathLessonKind.boss);
      }
      expect(path.sections.where((section) => section.id == 's4').first.lessons.where((lesson) => lesson.id == 's4-quality').first.kind, StudyPathLessonKind.concept);
    });

    test('every lesson id is used once across the path and every boss has at least three builds', () {
      final ids = path.lessons.map((lesson) => lesson.id).toList();
      expect(ids.length, ids.toSet().length);
      final bosses = path.lessons.where((lesson) => lesson.kind == StudyPathLessonKind.boss).toList();
      expect(bosses, isNotEmpty);
      for (final boss in bosses) {
        expect((boss.steps ?? const <StudyPathStep>[]).where((step) => step.build != null).length, greaterThanOrEqualTo(3), reason: '${boss.id} has too few builds');
      }
    });

    test('every tags lesson has four to six distinct tags all in the bundled curriculum', () {
      for (final lesson in path.lessons.where((lesson) => lesson.kind == StudyPathLessonKind.tags)) {
        final tags = lesson.tags ?? const <String>[];
        expect(tags.length, inInclusiveRange(4, 6), reason: '${lesson.id} has ${tags.length} tags');
        expect(tags.length, tags.toSet().length, reason: '${lesson.id} repeats a tag');
        for (final tag in tags) {
          expect(curriculum.tag(tag), isNotNull, reason: '${lesson.id} -> $tag');
        }
      }
    });

    test('every authored build answer passes judge and fails once an extra is added', () {
      for (final lesson in path.lessons) {
        for (final target in [for (final step in lesson.steps ?? const <StudyPathStep>[]) ?step.build]) {
          expect(StudyLessonSession.judge(target.answer, target), isTrue, reason: '${lesson.id}: ${target.answer}');
          if (target.extras.isNotEmpty) expect(StudyLessonSession.judge([...target.answer, target.extras.first], target), isFalse);
        }
      }
    });

    test('the bundled path can be read from the asset bundle once and replaced for tests', () async {
      StudyPath.useBundled(null);
      expect(StudyPath.bundled.sections, isEmpty);
      final loaded = await StudyPath.loadBundled();
      expect(loaded.lessons.length, 62);
      expect(identical(StudyPath.bundled, loaded), isTrue);
      expect(identical(await StudyPath.load(), loaded), isTrue);
      StudyPath.useBundled(path);
      expect(StudyPath.parse('not json').sections, isEmpty);
    });
  });

  group('current and isOpen', () {
    test('current is the first unfinished lesson and null once every lesson is done', () {
      final lessons = path.lessons;
      expect(lessons.length, greaterThanOrEqualTo(6));
      expect(path.current({})?.id, lessons[0].id);
      final three = {for (final lesson in lessons.take(3)) lesson.id: record(lesson)};
      expect(path.current(three)?.id, lessons[3].id);
      // A lesson finished out of order does not move the learner past an earlier one.
      final skipped = {lessons[2].id: record(lessons[2])};
      expect(path.current(skipped)?.id, lessons[0].id);
      final all = {for (final lesson in lessons) lesson.id: record(lesson)};
      expect(path.current(all), isNull);
      expect(const StudyPath().current({}), isNull, reason: 'A path without lessons has none to be on');
    });

    test('an unfinished lesson is open only when it is the current one', () {
      final lessons = path.lessons;
      expect(path.isOpen(lessons[0], {}), isTrue);
      expect(path.isOpen(lessons[1], {}), isFalse);
      final three = {for (final lesson in lessons.take(3)) lesson.id: record(lesson)};
      for (final (index, lesson) in lessons.indexed) {
        expect(path.isOpen(lesson, three), index <= 3, reason: 'lesson $index');
      }
      final all = {for (final lesson in lessons) lesson.id: record(lesson, stars: 1)};
      expect(lessons.every((lesson) => path.isOpen(lesson, all)), isTrue, reason: 'Finished lessons stay open to play again');
      final skipped = {lessons[2].id: record(lessons[2])};
      expect(path.isOpen(lessons[2], skipped), isTrue);
      expect(path.isOpen(lessons[0], skipped), isTrue);
      expect(path.isOpen(lessons[1], skipped), isFalse);
    });
  });

  group('Ask.shuffled', () {
    test('keeps the choices and the right answer points at the same text', () {
      for (final original in [ask(), ask(answer: 2), ask(answer: 1, count: 4, code: true), ask(count: 2)]) {
        for (var seed = 0; seed < 60; seed++) {
          final mixed = original.shuffled(Random(seed));
          expect(mixed.choices.toSet().length, original.choices.toSet().length, reason: 'seed $seed');
          expect(mixed.choices.length, original.choices.length);
          expect(mixed.choices[mixed.answer], original.choices[original.answer], reason: 'seed $seed');
          expect(mixed.question, original.question);
          expect(mixed.why, original.why);
          expect(mixed.code, original.code);
        }
      }
    });

    test('does not always leave the answer first', () {
      final original = ask(count: 4);
      final positions = {for (var seed = 0; seed < 200; seed++) original.shuffled(Random(seed)).answer};
      expect(positions, {0, 1, 2, 3}, reason: 'Over 200 seeds the answer lands in every place');
      final system = Random();
      expect(List.generate(100, (_) => original.shuffled(system).answer).any((position) => position != 0), isTrue);
    });

    test('every bundled ask keeps its right text when shuffled', () {
      final random = Random(99);
      var seen = 0;
      for (final lesson in path.lessons) {
        for (final question in [for (final step in lesson.steps ?? const <StudyPathStep>[]) ?step.ask]) {
          seen += 1;
          for (var round = 0; round < 10; round++) {
            final mixed = question.shuffled(random);
            expect(mixed.choices[mixed.answer], question.choices[question.answer], reason: lesson.id);
            expect(mixed.choices.length, question.choices.length);
          }
        }
      }
      expect(seen, greaterThan(0));
    });
  });

  group('game numbers', () {
    test('earned gives ten and five more for no mistakes and three more for a run of five', () {
      expect(StudyGame.earned(mistakes: 0, bestCombo: 0), 15);
      expect(StudyGame.earned(mistakes: 1, bestCombo: 0), 10);
      expect(StudyGame.earned(mistakes: 0, bestCombo: 4), 15);
      expect(StudyGame.earned(mistakes: 0, bestCombo: 5), 18);
      expect(StudyGame.earned(mistakes: 2, bestCombo: 4), 10);
      expect(StudyGame.earned(mistakes: 1, bestCombo: 5), 13);
      expect(StudyGame.earned(mistakes: 9, bestCombo: 30), 13);
    });

    test('stars are three for no mistakes, two for one or two and one for more', () {
      expect(StudyGame.stars(mistakes: 0), 3);
      expect(StudyGame.stars(mistakes: 1), 2);
      expect(StudyGame.stars(mistakes: 2), 2);
      expect(StudyGame.stars(mistakes: 3), 1);
      expect(StudyGame.stars(mistakes: 40), 1);
    });

    test('level and level progress follow every hundred experience', () {
      final game = StudyGame();
      expect(game.level, 1);
      expect(game.levelProgress, closeTo(0, 1e-9));
      game.xp = 99;
      expect(game.level, 1);
      expect(game.levelProgress, closeTo(0.99, 1e-9));
      game.xp = 100;
      expect(game.level, 2);
      expect(game.levelProgress, closeTo(0, 1e-9));
      game.xp = 250;
      expect(game.level, 3);
      expect(game.levelProgress, closeTo(0.5, 1e-9));
    });

    test('goal progress stops at one and the goal is met when today reaches it', () {
      final game = StudyGame();
      expect(game.goal, StudyGame.defaultGoal);
      expect(StudyGame.goals, contains(StudyGame.defaultGoal));
      expect(game.goalProgress, closeTo(0, 1e-9));
      expect(game.goalMet, isFalse);
      game.today = 5;
      expect(game.goalProgress, closeTo(0.25, 1e-9));
      expect(game.goalMet, isFalse);
      game.today = 20;
      expect(game.goalProgress, closeTo(1, 1e-9));
      expect(game.goalMet, isTrue);
      game.today = 75;
      expect(game.goalProgress, closeTo(1, 1e-9), reason: 'A day past the goal still shows a full ring');
      expect(game.goalMet, isTrue);
      game.goal = 0;
      expect(game.goalProgress, 1);
    });

    test('a game from days sums every day\'s experience and reads today\'s', () {
      final now = date(2026, 3, 10);
      const days = [
        StudyDay(day: '2026-03-10', answered: 4, correct: 3, xp: 12),
        StudyDay(day: '2026-03-09', xp: 30),
        StudyDay(day: '2026-03-01', answered: 2, correct: 2),
      ];
      final game = StudyGame.of(days: days, goal: 30, now: now, utcOffset: utc);
      expect(game.xp, 42);
      expect(game.today, 12);
      expect(game.goal, 30);
      expect(game.level, 1);
      final quiet = StudyGame.of(days: days.skip(1).toList(), goal: 10, now: now, utcOffset: utc);
      expect(quiet.xp, 30);
      expect(quiet.today, 0);
      expect(StudyGame.of(days: const [], goal: 20, now: now, utcOffset: utc), StudyGame());
    });

    test('a day with experience but no answers is studied and keeps the streak', () {
      expect(const StudyDay(day: 'd', xp: 5).isStudied, isTrue);
      expect(const StudyDay(day: 'd', answered: 1).isStudied, isTrue);
      expect(const StudyDay(day: 'd').isStudied, isFalse);
      final now = date(2026, 3, 10);
      const days = [StudyDay(day: '2026-03-10', xp: 15), StudyDay(day: '2026-03-09', answered: 3, correct: 1), StudyDay(day: '2026-03-08', xp: 10)];
      final summary = StudySummary.of(curriculum: StudyCurriculum.empty, progress: const {}, days: days, now: now, utcOffset: utc);
      expect(summary.streak, 3);
      expect(summary.today, 0, reason: 'Experience alone is not an answer');
      expect(summary.todayCorrect, 0);
      final before = StudySummary.of(curriculum: StudyCurriculum.empty, progress: const {}, days: days.skip(1).toList(), now: now, utcOffset: utc);
      expect(before.streak, 2, reason: "Yesterday's studied days still count before today's first lesson");
    });

    test('a day keeps its experience through its JSON form, and reads one without it as none', () {
      const day = StudyDay(day: '2026-03-10', answered: 2, correct: 1, xp: 15);
      expect(StudyDay.fromJson(day.toJson()), day);
      expect(StudyDay.fromJson({'day': 'd', 'answered': 1, 'correct': 1}).xp, 0);
    });
  });

  group('store', () {
    test('earn adds experience to the day and leaves its answers alone', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      study.answer('solo', right: true, now: now, utcOffset: utc);
      study.answer('solo', right: false, now: now, utcOffset: utc);
      study.earn(15, now: now, utcOffset: utc);
      expect(study.days(), [const StudyDay(day: '2026-03-10', answered: 2, correct: 1, xp: 15)]);
      study.earn(5, now: now.add(const Duration(seconds: 60)), utcOffset: utc);
      expect(study.days(), [const StudyDay(day: '2026-03-10', answered: 2, correct: 1, xp: 20)]);
      study.answer('solo', right: true, now: now, utcOffset: utc);
      expect(study.days(), [const StudyDay(day: '2026-03-10', answered: 3, correct: 2, xp: 20)], reason: 'Answering later keeps the experience');
      expect(study.progress()['solo']?.correct, 2, reason: "Earning touches no tag's progress");
    });

    test('earn on a day without answers creates a row that counts for the streak', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      study.earn(15, now: now, utcOffset: utc);
      expect(study.days(), [const StudyDay(day: '2026-03-10', xp: 15)]);
      study.earn(10, now: now.subtract(const Duration(days: 1)), utcOffset: utc);
      final days = study.days();
      expect(days.map((day) => day.day), ['2026-03-10', '2026-03-09']);
      expect(StudySummary.of(curriculum: StudyCurriculum.empty, progress: const {}, days: days, now: now, utcOffset: utc).streak, 2);
      expect(StudyGame.of(days: days, goal: 20, now: now, utcOffset: utc).xp, 25);
      expect(study.lessons(), isEmpty, reason: 'Earning without a lesson records none');
    });

    test('earn never takes experience away', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      study.earn(10, now: now, utcOffset: utc);
      study.earn(-50, now: now, utcOffset: utc);
      expect(study.days().first.xp, 10);
    });

    test('earn with a lesson records its stars, keeps the best on a replay and counts runs', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      expect(study.lessons(), isEmpty);
      study.earn(13, lesson: 's1-who', stars: 2, now: now, utcOffset: utc);
      expect(study.lessons()['s1-who'], const StudyLessonRecord(lesson: 's1-who', stars: 2, runs: 1));
      study.earn(10, lesson: 's1-who', stars: 1, now: now, utcOffset: utc);
      expect(study.lessons()['s1-who'], const StudyLessonRecord(lesson: 's1-who', stars: 2, runs: 2), reason: 'A worse replay keeps the better stars');
      study.earn(18, lesson: 's1-who', stars: 3, now: now, utcOffset: utc);
      expect(study.lessons()['s1-who'], const StudyLessonRecord(lesson: 's1-who', stars: 3, runs: 3));
      expect(study.days().first.xp, 41, reason: "Every run's experience is added");
    });

    test('earn keeps stars between one and three and lessons apart', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      study.earn(1, lesson: 'low', stars: 0, now: now, utcOffset: utc);
      study.earn(1, lesson: 'high', stars: 7, now: now, utcOffset: utc);
      final lessons = study.lessons();
      expect(lessons['low']?.stars, 1);
      expect(lessons['high']?.stars, 3);
      expect(lessons.keys.toSet(), {'low', 'high'});
    });

    test('lessons round trip as a dictionary by lesson id', () {
      final study = BooruStore.inMemory().studyStore;
      final now = date(2026, 3, 10);
      study.earn(10, lesson: 'a', stars: 3, now: now, utcOffset: utc);
      study.earn(10, lesson: 'b', stars: 1, now: now, utcOffset: utc);
      study.earn(10, lesson: 'b', stars: 1, now: now, utcOffset: utc);
      expect(study.lessons(), {'a': const StudyLessonRecord(lesson: 'a', stars: 3, runs: 1), 'b': const StudyLessonRecord(lesson: 'b', stars: 1, runs: 2)});
    });

    test('reset clears lessons and experience as well as progress and days', () {
      final store = BooruStore.inMemory();
      final study = store.studyStore;
      final now = date(2026, 3, 10);
      study.answer('solo', right: true, now: now, utcOffset: utc);
      study.earn(15, lesson: 'a', stars: 3, now: now, utcOffset: utc);
      study.save(
        StudyTagInfo(name: 'solo', count: 3, category: 0, wiki: null, related: const [], fetched: DateTime.now(), complete: true),
        address: 'https://a.example',
      );
      study.reset();
      expect(study.lessons(), isEmpty);
      expect(study.progress(), isEmpty);
      expect(study.days(), isEmpty);
      expect(StudyGame.of(days: study.days(), goal: 20, now: now, utcOffset: utc).xp, 0);
      expect(study.info('solo', address: 'https://a.example'), isNotNull, reason: 'What servers said about tags is kept');
    });
  });

  group('server choice', () {
    test('with no servers the current one is Safebooru and nothing needs choosing', () {
      final store = BooruStore.inMemory();
      final defaults = MemoryPreferences();
      expect(store.selectableServers, isEmpty);
      expect(StudyServer.fallback.isSafebooru, isTrue);
      expect(StudyServer.current(store, defaults: defaults).isSafebooru, isTrue);
      expect(StudyServer.needsChoice(store, defaults: defaults), isFalse);
      expect(StudyServer.choices(store).map((server) => server.id), [StudyServer.fallback.id]);
    });

    test('recommended prefers Danbooru on its own site, then any Danbooru, then Safebooru', () {
      final donmai = server('p-donmai', 'danbooru.donmai.us', BooruEngine.danbooru);
      final otherDan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      final gel = server('p-gel', 'gel.example', BooruEngine.gelbooru);
      final notDan = server('p-wrong', 'danbooru.donmai.us', BooruEngine.gelbooru);
      final safe = BooruServer.safebooru();
      expect(StudyServer.recommended([gel, otherDan, donmai]).id, donmai.id);
      expect(StudyServer.recommended([donmai, otherDan]).id, donmai.id);
      expect(StudyServer.recommended([gel, otherDan]).id, otherDan.id);
      expect(StudyServer.recommended([notDan, otherDan]).id, otherDan.id, reason: "The site's name alone is not enough; the engine must be Danbooru");
      expect(StudyServer.recommended([gel, safe]).id, safe.id);
      expect(StudyServer.recommended([safe, otherDan]).id, otherDan.id);
      expect(StudyServer.recommended([gel]).id, gel.id);
      expect(StudyServer.recommended([]).id, StudyServer.fallback.id);
    });

    test('with servers and nothing chosen a choice is needed and the recommended one is current', () {
      final store = BooruStore.inMemory();
      final defaults = MemoryPreferences();
      final moe = server('p-moe', 'moe.example', BooruEngine.moebooru), dan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      store.saveServer(moe);
      store.saveServer(dan);
      expect(StudyServer.needsChoice(store, defaults: defaults), isTrue);
      expect(StudyServer.current(store, defaults: defaults).id, dan.id);
      expect(StudyServer.choices(store).map((server) => server.id), [moe.id, dan.id, StudyServer.fallback.id], reason: "Safebooru is offered beside the learner's own");
    });

    test('a stored choice wins and needs no further choosing', () {
      final store = BooruStore.inMemory();
      final defaults = MemoryPreferences();
      final moe = server('p-moe', 'moe.example', BooruEngine.moebooru), dan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      store.saveServer(moe);
      store.saveServer(dan);
      defaults.set(StudyServer.key, moe.id);
      expect(StudyServer.current(store, defaults: defaults).id, moe.id);
      expect(StudyServer.needsChoice(store, defaults: defaults), isFalse);
      // Safebooru, offered although not added, can be the choice too.
      defaults.set(StudyServer.key, StudyServer.fallback.id);
      expect(StudyServer.current(store, defaults: defaults).id, StudyServer.fallback.id);
      expect(StudyServer.needsChoice(store, defaults: defaults), isFalse);
    });

    test('a stored server that no longer exists needs a choice again and falls back to the recommended one', () {
      final store = BooruStore.inMemory();
      final defaults = MemoryPreferences();
      final gel = server('p-gel', 'gel.example', BooruEngine.gelbooru), dan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      store.saveServer(gel);
      store.saveServer(dan);
      defaults.set(StudyServer.key, dan.id);
      expect(StudyServer.needsChoice(store, defaults: defaults), isFalse);
      store.deleteServer(dan);
      expect(StudyServer.needsChoice(store, defaults: defaults), isTrue);
      expect(StudyServer.current(store, defaults: defaults).id, StudyServer.fallback.id, reason: 'Nothing Danbooru is left, so Safebooru is suggested');
      defaults.set(StudyServer.key, 'never-existed');
      expect(StudyServer.needsChoice(store, defaults: defaults), isTrue);
    });

    test('choices add Safebooru only when the learner has none', () {
      final store = BooruStore.inMemory();
      final dan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      store.saveServer(dan);
      expect(StudyServer.choices(store).map((server) => server.id), [dan.id, StudyServer.fallback.id]);
      final safe = BooruServer.safebooru();
      store.saveServer(safe);
      expect(StudyServer.choices(store).map((server) => server.id), [dan.id, safe.id], reason: "The learner's own Safebooru is not listed twice");
    });

    test('Safe Mode offers only Safebooru', () {
      final store = BooruStore.inMemory();
      final defaults = MemoryPreferences();
      final dan = server('p-dan', 'dan.example', BooruEngine.danbooru);
      store.saveServer(dan);
      store.safeMode = () => true;
      expect(StudyServer.choices(store).map((server) => server.id), [StudyServer.fallback.id]);
      expect(StudyServer.current(store, defaults: defaults).isSafebooru, isTrue);
      expect(StudyServer.needsChoice(store, defaults: defaults), isFalse, reason: 'Nothing but Safebooru can be chosen');
      final safe = BooruServer.safebooru();
      store.saveServer(safe);
      expect(StudyServer.choices(store).map((server) => server.id), [safe.id]);
      expect(StudyServer.current(store, defaults: defaults).id, safe.id);
    });
  });

  group('judge', () {
    test('passes the right tags with the headcount first, in any order otherwise', () {
      final target = build(['1girl', 'solo', 'smile', 'blush']);
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'blush'], target), isTrue);
      expect(StudyLessonSession.judge(['solo', '1girl', 'smile', 'blush'], target), isTrue, reason: 'Headcount tags may swap places');
      expect(StudyLessonSession.judge(['1girl', 'solo', 'blush', 'smile'], target), isTrue, reason: 'Order among the other tags does not matter');
      expect(StudyLessonSession.judge(['solo', '1girl', 'blush', 'smile'], target), isTrue);
      expect(StudyLessonSession.judge(['1girl'], build(['1girl'])), isTrue);
      expect(StudyLessonSession.judge(['blush', 'smile'], build(['smile', 'blush'])), isTrue, reason: 'A build with no headcount tag has no order to keep');
    });

    test('fails a headcount tag written after another tag', () {
      final target = build(['1girl', 'solo', 'smile', 'blush']);
      expect(StudyLessonSession.judge(['1girl', 'smile', 'solo', 'blush'], target), isFalse);
      expect(StudyLessonSession.judge(['smile', 'blush', '1girl', 'solo'], target), isFalse);
      expect(StudyLessonSession.judge(['smile', '1girl', 'solo', 'blush'], target), isFalse);
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'blush'].reversed.toList(), target), isFalse);
    });

    test('fails a missing, an extra and a wrong tag', () {
      final target = build(['1girl', 'solo', 'smile', 'blush']);
      expect(StudyLessonSession.judge([], target), isFalse);
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile'], target), isFalse, reason: 'One tag short');
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'blush', 'crying'], target), isFalse, reason: 'One tag too many');
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'crying'], target), isFalse, reason: 'Right count, wrong tag');
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'blush', '2girls'], target), isFalse);
    });

    test('fails duplicates', () {
      final target = build(['1girl', 'solo', 'smile', 'blush']);
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'blush', 'blush'], target), isFalse, reason: 'Every right tag, one of them twice');
      expect(StudyLessonSession.judge(['1girl', '1girl', 'solo', 'smile', 'blush'], target), isFalse);
      expect(StudyLessonSession.judge(['1girl', 'solo', 'smile', 'smile'], target), isFalse, reason: 'Right count, one tag twice and one missing');
      expect(StudyLessonSession.judge(['1girl', '1girl'], build(['1girl', 'solo'])), isFalse);
    });

    test('an order passes only the right order', () {
      final target = order(['a', 'b', 'c', 'd']);
      expect(StudyLessonSession.judgeOrder(text(['a', 'b', 'c', 'd']), target), isTrue);
      expect(StudyLessonSession.judgeOrder(text(['a', 'c', 'b', 'd']), target), isFalse, reason: 'Two swapped');
      expect(StudyLessonSession.judgeOrder(text(['d', 'c', 'b', 'a']), target), isFalse, reason: 'Reversed');
      expect(StudyLessonSession.judgeOrder(text(['a', 'b', 'c']), target), isFalse, reason: 'One missing');
      expect(StudyLessonSession.judgeOrder([], target), isFalse);
      expect(StudyLessonSession.judgeOrder(text(['a', 'b', 'c', 'd', 'e']), target), isFalse, reason: 'One extra');
      expect(StudyLessonSession.judgeOrder(text(['a', 'b', 'c', 'd', 'd']), target), isFalse, reason: 'One repeated');
      expect(StudyLessonSession.judgeOrder(text(['a', 'b', 'c', 'x']), target), isFalse, reason: 'Right count, wrong item');
    });

    test('every authored order passes judge in its own order and fails when two items swap', () {
      for (final lesson in path.lessons) {
        for (final ordering in [for (final step in lesson.steps ?? const <StudyPathStep>[]) ?step.order]) {
          expect(StudyLessonSession.judgeOrder(ordering.items, ordering), isTrue, reason: lesson.id);
          final swapped = [...ordering.items];
          final first = swapped.first;
          swapped[0] = swapped.last;
          swapped[swapped.length - 1] = first;
          expect(StudyLessonSession.judgeOrder(swapped, ordering), isFalse, reason: lesson.id);
        }
      }
    });
  });

  group('milestones', () {
    test('nothing is reached when nothing was earned', () {
      final before = StudyStanding(xp: 95, today: 15, studiedToday: false);
      expect(StudyMilestone.reached(before: before, earned: 0, goal: 20, streak: 4), isEmpty);
    });

    test('the streak is reached on the day\'s first study when there is one', () {
      final first = StudyStanding(xp: 0, today: 0, studiedToday: false);
      expect(StudyMilestone.reached(before: first, earned: 5, goal: 50, streak: 3), [const StudyMilestone.streak(3)]);
      expect(StudyMilestone.reached(before: first, earned: 5, goal: 50, streak: 0), isEmpty, reason: 'No streak to celebrate');
      final later = StudyStanding(xp: 10, today: 10);
      expect(StudyMilestone.reached(before: later, earned: 5, goal: 50, streak: 3), isEmpty, reason: 'Already studied today');
    });

    test('the goal is reached only by the lesson that crosses it', () {
      StudyStanding studied(int today) => StudyStanding(xp: today, today: today);
      expect(StudyMilestone.reached(before: studied(10), earned: 10, goal: 20, streak: 1), [const StudyMilestone.goal(20)], reason: 'Landing exactly on the goal counts');
      expect(StudyMilestone.reached(before: studied(15), earned: 18, goal: 20, streak: 1), [const StudyMilestone.goal(20)]);
      expect(StudyMilestone.reached(before: studied(5), earned: 10, goal: 20, streak: 1), isEmpty, reason: 'Still short of the goal');
      expect(StudyMilestone.reached(before: studied(20), earned: 10, goal: 20, streak: 1), isEmpty, reason: 'Already met before this lesson');
      expect(StudyMilestone.reached(before: studied(30), earned: 10, goal: 20, streak: 1), isEmpty, reason: 'Already past it');
    });

    test('a level is reached when experience crosses a hundred', () {
      StudyStanding studied(int xp) => StudyStanding(xp: xp);
      expect(StudyMilestone.reached(before: studied(95), earned: 10, goal: 500, streak: 1), [const StudyMilestone.level(2)]);
      expect(StudyMilestone.reached(before: studied(90), earned: 10, goal: 500, streak: 1), [const StudyMilestone.level(2)], reason: 'Landing exactly on a hundred counts');
      expect(StudyMilestone.reached(before: studied(80), earned: 10, goal: 500, streak: 1), isEmpty);
      expect(StudyMilestone.reached(before: studied(199), earned: 18, goal: 500, streak: 1), [const StudyMilestone.level(3)]);
      expect(StudyMilestone.reached(before: studied(100), earned: 10, goal: 500, streak: 1), isEmpty, reason: 'Already on level two');
    });

    test('a streak, a goal and a level together come in that order', () {
      final before = StudyStanding(xp: 95, today: 0, studiedToday: false);
      expect(StudyMilestone.reached(before: before, earned: 20, goal: 20, streak: 7), [const StudyMilestone.streak(7), const StudyMilestone.goal(20), const StudyMilestone.level(2)]);
    });

    test('a plain lesson reaches nothing', () {
      final before = StudyStanding(xp: 30, today: 5);
      expect(StudyMilestone.reached(before: before, earned: 10, goal: 20, streak: 5), isEmpty);
    });

    test('a milestone can be an award but reached never produces one', () {
      final award = StudyAward.all(const StudyPath()).where((award) => award.id == 'lessons-1').first;
      expect(StudyMilestone.award(award), StudyMilestone.award(award));
      expect(StudyMilestone.award(award), isNot(const StudyMilestone.goal(20)));
      final before = StudyStanding(xp: 95, today: 0, studiedToday: false);
      final reached = StudyMilestone.reached(before: before, earned: 20, goal: 20, streak: 7);
      expect(reached.any((milestone) => milestone is StudyAwardMilestone), isFalse);
    });
  });

  group('session', () {
    test('a tags lesson teaches each tag then asks it then matches then asks all again', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(session.tags.map((tag) => tag.name), ['t1', 't2', 't3', 't4']);
      expect(kinds(session.steps), [for (var i = 0; i < 4; i++) ...['teach', 'quiz']] + ['match'] + List.filled(4, 'quiz') + ['spell'], reason: 'No odd step: the pictures carry too few of the lesson\'s tags');
      for (final name in ['t1', 't2', 't3', 't4']) {
        final teach = session.steps.indexWhere((step) => switch (step.kind) {
          StudyStepTeach(:final tag) => tag.name == name,
          _ => false,
        });
        final firstQuestion = session.steps.indexWhere((step) => quizTag(step) == name);
        expect(teach, greaterThanOrEqualTo(0), reason: name);
        expect(firstQuestion, teach + 1, reason: '$name is asked right after it is shown');
        expect(session.steps.where((step) => quizTag(step) == name).length, greaterThanOrEqualTo(2), reason: '$name is asked at least twice');
        final shown = session.steps[teach].kind as StudyStepTeach;
        expect(shown.posts.length, inInclusiveRange(1, 3), reason: '$name shows up to three pictures');
        expect(shown.posts.every((post) => post.tags.contains(name)), isTrue);
      }
      expect(session.steps.where((step) => !step.again).length, session.steps.length);
    });

    test('a tags lesson has one match step only from four tags and skips tags the curriculum does not teach', () async {
      final store = BooruStore.inMemory();
      final four = makeSession(StudyLessonPlan.lesson(tagsLesson()), store);
      await four.start();
      final matches = [for (final step in four.steps) if (step.kind case StudyStepMatch(:final tags)) tags];
      expect(matches.length, 1);
      expect(matches.first.length, 4);
      expect(matches.first.map((tag) => tag.name).toSet().difference({'t1', 't2', 't3', 't4'}), isEmpty);

      final many = makeSession(StudyLessonPlan.lesson(tagsLesson('p-many', ['t1', 't2', 't3', 't4', 't5', 't6'])), store);
      await many.start();
      expect(kinds(many.steps).where((kind) => kind == 'match').length, 1, reason: 'Still one match, of four tags');
      expect(kinds(many.steps).length, 6 * 2 + 1 + 6 + 1);

      final three = makeSession(StudyLessonPlan.lesson(tagsLesson('p-three', ['t1', 't2', 't3', 'unknown_tag'])), store);
      await three.start();
      expect(three.tags.map((tag) => tag.name), ['t1', 't2', 't3']);
      expect(kinds(three.steps), [for (var i = 0; i < 3; i++) ...['teach', 'quiz']] + List.filled(3, 'quiz') + ['spell']);
    });

    test('a tags lesson still plays when the server cannot be read and asks by meaning', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store, source: PathFakeSource(failing: true));
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      for (final step in session.steps) {
        switch (step.kind) {
          case StudyStepTeach(:final posts):
            expect(posts, isEmpty);
          case StudyStepQuiz(:final question):
            expect(question.kind, StudyQuestionKind.meaningToTag);
          default:
        }
      }
      play(session);
      expect(session.phase, StudyLessonPhase.finished);
    });

    test('answer works only while asking on asked steps and proceed only on cards and new tags', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store);
      session
        ..answer(true, tag: 't1')
        ..proceed()
        ..next();
      expect(session.phase, StudyLessonPhase.loading);
      expect(session.asked, 0);
      expect(session.index, 0);
      expect(session.progress, 0);

      await session.start();
      final count = session.steps.length.toDouble();
      expect(session.step!.isAsked, isFalse, reason: 'A new tag is shown first');
      session.answer(true, tag: 't1');
      expect(session.asked, 0, reason: 'A new tag is read, not answered');
      expect(session.phase, StudyLessonPhase.asking);
      expect(session.combo, 0);
      session.next();
      expect(session.index, 0, reason: 'next only follows an answer');
      session.proceed();
      expect(session.index, 1);
      expect(session.progress, closeTo(1 / count, 1e-9));

      expect(session.step!.isAsked, isTrue);
      session.proceed();
      expect(session.index, 1, reason: 'A question is not skipped');
      session.answer(true, tag: 't1');
      expect(session.phase, const StudyLessonPhase.feedback(true));
      expect(session.progress, closeTo(2 / count, 1e-9), reason: 'An answered step counts as done');
      session
        ..answer(false, tag: 't1')
        ..proceed();
      expect(session.asked, 1, reason: 'An answered question cannot be answered again');
      expect(session.mistakes, 0);
      expect(session.combo, 1);
      expect(session.index, 1);
      session.next();
      expect(session.index, 2);
      expect(session.phase, StudyLessonPhase.asking);

      final steps = session.steps.length;
      await session.start();
      expect(session.steps.length, steps, reason: 'Starting twice does not build the lesson again');
      expect(session.index, 2);

      play(session);
      expect(session.phase, StudyLessonPhase.finished);
      final asked = session.asked;
      session
        ..answer(true, tag: 't1')
        ..proceed()
        ..next();
      expect(session.asked, asked);
      expect(session.progress, closeTo(1, 1e-9));
      expect(session.step, isNull);
    });

    test('a missed step comes back once at the end and a miss on the repeat adds no more', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store);
      await session.start();
      final before = session.steps.length;
      session.proceed();
      final missed = (session.step!.kind as StudyStepQuiz).question;
      session.answer(false, tag: 't1');
      expect(session.phase, const StudyLessonPhase.feedback(false));
      expect(session.steps.length, before + 1);
      final repeated = session.steps.last;
      expect(repeated.again, isTrue);
      expect(repeated.isAsked, isTrue);
      expect((repeated.kind as StudyStepQuiz).question.id, missed.id);
      expect(session.combo, 0);
      expect(session.mistakes, 1);
      session.next();

      var misses = 0;
      play(
        session,
        right: (step) {
          if (!step.again) return true;
          misses += 1;
          return false;
        },
      );
      expect(misses, 1, reason: 'The repeat is asked once');
      expect(session.steps.length, before + 1, reason: 'A second miss adds no further step');
      expect(session.steps.where((step) => step.again).length, 1);
      expect(session.mistakes, 2);
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.stars, 2);
      expect(session.asked, session.steps.where((step) => step.isAsked).length, reason: 'Every asked step was answered once, the repeat too');
    });

    test('combo counts right answers in a row and best combo keeps the longest run', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store);
      await session.start();
      final seen = <(int, int, int)>[];
      for (final right in [true, true, true, false, true, true]) {
        answerOne(session, right);
        seen.add((session.combo, session.bestCombo, session.mistakes));
        session.next();
      }
      expect(seen.map((value) => value.$1), [1, 2, 3, 0, 1, 2]);
      expect(seen.map((value) => value.$2), [1, 2, 3, 3, 3, 3]);
      expect(seen.map((value) => value.$3), [0, 0, 0, 1, 1, 1]);
    });

    test('each tag\'s review date moves once for every first asking and not for the repeat', () async {
      final store = BooruStore.inMemory();
      final clean = makeSession(StudyLessonPlan.lesson(tagsLesson('clean')), store);
      await clean.start();
      play(clean);
      var progress = store.studyStore.progress();
      for (final name in ['t1', 't2', 't3', 't4']) {
        expect(progress[name]?.correct, 2, reason: '$name was asked twice');
        expect(progress[name]?.wrong, 0);
      }
      expect(store.studyStore.days().first.answered, 8, reason: "The match step is not a tag's answer");

      final fresh = BooruStore.inMemory();
      final missing = makeSession(StudyLessonPlan.lesson(tagsLesson('missing')), fresh);
      await missing.start();
      var missedOnce = false;
      play(
        missing,
        right: (step) {
          if (!step.again && !missedOnce && quizTag(step) == 't1') {
            missedOnce = true;
            return false;
          }
          return true;
        },
      );
      expect(missing.mistakes, 1);
      expect(missing.asked, 11, reason: 'Eight questions, the match, the spelling and one repeat');
      progress = fresh.studyStore.progress();
      expect(progress['t1']?.wrong, 1);
      expect(progress['t1']?.correct, 1, reason: 'The repeat did not move t1 again');
      expect(progress['t2']?.correct, 2);
      expect(fresh.studyStore.days().first.answered, 8, reason: "The repeat is not a day's answer either");
    });

    test('finishing records the lesson with stars and adds earned experience to today', () async {
      final store = BooruStore.inMemory();
      final lesson = tagsLesson('p-finish');
      final first = makeSession(StudyLessonPlan.lesson(lesson), store);
      expect(first.earned, 0);
      await first.start();
      expect(store.studyStore.lessons(), isEmpty);
      play(first);
      expect(first.phase, StudyLessonPhase.finished);
      expect(first.mistakes, 0);
      expect(first.asked, 10, reason: 'Four quizzes, the match, four quizzes and the spelling');
      expect(first.bestCombo, 10);
      expect(first.stars, 3);
      expect(first.earned, StudyGame.earned(mistakes: 0, bestCombo: 10));
      expect(first.earned, 18);
      expect(store.studyStore.lessons(), {'p-finish': const StudyLessonRecord(lesson: 'p-finish', stars: 3, runs: 1)});
      expect(todaysXP(store), 18);

      // A weaker replay adds its experience and a run, and keeps the three stars.
      final replay = makeSession(StudyLessonPlan.lesson(lesson), store);
      await replay.start();
      var missedOnce = false;
      play(
        replay,
        right: (step) {
          if (!step.again && !missedOnce && quizTag(step) == 't1') {
            missedOnce = true;
            return false;
          }
          return true;
        },
      );
      expect(replay.stars, 2);
      expect(replay.earned, 13);
      expect(store.studyStore.lessons()['p-finish'], const StudyLessonRecord(lesson: 'p-finish', stars: 3, runs: 2));
      expect(todaysXP(store), 31);
    });

    test('a concept lesson turns cards and asks into steps in order with the same choice texts', () async {
      const card = StudyPathCard(title: {'en': 'One'}, body: {'en': 'First card'});
      const question = StudyPathAsk(
        question: {'en': 'Which?'},
        choices: [
          {'en': 'right'},
          {'en': 'wrong'},
          {'en': 'also wrong'},
        ],
        answer: 0,
        why: {'en': 'Because'},
      );
      const last = StudyPathCard(title: {'en': 'Two'}, body: {'en': 'Last card'}, code: '1girl, solo');
      const lesson = StudyPathLesson(
        id: 'p-concept',
        kind: StudyPathLessonKind.concept,
        symbol: 'wand.and.stars',
        title: {'en': 'Concept'},
        steps: [StudyPathStep(card: card), StudyPathStep(ask: question), StudyPathStep(card: last)],
      );
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(lesson), store);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(kinds(session.steps), ['card', 'ask', 'card']);
      expect(session.tags, isEmpty);
      expect(session.builtPictures, isEmpty);
      final shown = (session.steps[0].kind as StudyStepCard).card;
      final asked = (session.steps[1].kind as StudyStepAsk).ask;
      final ending = (session.steps[2].kind as StudyStepCard).card;
      expect(shown, card);
      expect(ending, last);
      expect(asked.choices.toSet().length, question.choices.length);
      expect(asked.choices[asked.answer], question.choices[question.answer]);

      session.proceed();
      expect(session.step!.isAsked, isTrue);
      session
        ..answer(true)
        ..next();
      expect(session.step!.isAsked, isFalse);
      session.proceed();
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.stars, 3);
      expect(session.earned, 15);
      expect(store.studyStore.lessons()['p-concept']?.stars, 3);
      expect(todaysXP(store), 15);
      expect(store.studyStore.progress(), isEmpty, reason: 'A question without a tag moves no review date');
    });

    test('a concept lesson turns order and sort steps into their kinds in the lesson\'s order', () async {
      final ordering = order(['first', 'second', 'third']);
      final sorting = StudyPathSort(
        brief: const {'en': 'Which side?'},
        left: const {'en': 'Left'},
        right: const {'en': 'Right'},
        items: [
          StudyPathSortItem(text: const {'en': 'a'}, right: false),
          StudyPathSortItem(text: const {'en': 'b'}, right: true),
          StudyPathSortItem(text: const {'en': 'c'}, right: true),
        ],
        why: const {'en': 'Because'},
      );
      final lesson = StudyPathLesson(
        id: 'p-order-sort',
        kind: StudyPathLessonKind.concept,
        symbol: 'list.number',
        title: const {'en': 'Order and sort'},
        steps: [
          const StudyPathStep(card: StudyPathCard(title: {'en': 'Go'}, body: {'en': 'Read'})),
          StudyPathStep(sort: sorting),
          StudyPathStep(order: ordering),
          StudyPathStep(sort: sorting),
        ],
      );
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(lesson), store);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(kinds(session.steps), ['card', 'sort', 'order', 'sort']);
      expect((session.steps[1].kind as StudyStepSort).sort, sorting);
      expect((session.steps[2].kind as StudyStepOrder).order, ordering);
      expect(session.steps[1].isAsked, isTrue);
      expect(session.steps[2].isAsked, isTrue);
      expect(session.tags, isEmpty);
      play(session);
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.asked, 3);
      expect(store.studyStore.lessons()['p-order-sort']?.stars, 3);
    });

    test('before holds what the store had before the lesson paid out and the day\'s first study is not studied yet', () async {
      final store = BooruStore.inMemory();
      store.studyStore.earn(40, now: DateTime.now().subtract(const Duration(days: 2)));
      const lesson = StudyPathLesson(
        id: 'p-before',
        kind: StudyPathLessonKind.concept,
        symbol: 'doc',
        title: {'en': 'Before'},
        steps: [StudyPathStep(card: StudyPathCard(title: {'en': 'Card'}, body: {'en': 'Body'}))],
      );
      final first = makeSession(StudyLessonPlan.lesson(lesson), store);
      expect(first.before, StudyStanding(xp: 0, today: 0, studiedToday: true), reason: 'Nothing is read before the lesson starts');
      await first.start();
      expect(first.before.studiedToday, isFalse, reason: 'Nothing earned today yet');
      first.proceed();
      expect(first.phase, StudyLessonPhase.finished);
      expect(first.before, StudyStanding(xp: 40, today: 0, studiedToday: false), reason: "Read before this lesson's own experience was added");
      expect(todaysXP(store), first.earned);

      // The same day's next lesson sees the first one's experience, and the day as studied.
      final second = makeSession(StudyLessonPlan.lesson(lesson), store);
      await second.start();
      expect(second.before.studiedToday, isTrue);
      second.proceed();
      expect(second.before, StudyStanding(xp: 40 + first.earned, today: first.earned, studiedToday: true));
      expect(todaysXP(store), first.earned + second.earned);
    });

    test('before counts a day with answers but no experience as studied', () async {
      final store = BooruStore.inMemory();
      store.studyStore.answer('t1', right: true);
      const lesson = StudyPathLesson(
        id: 'p-answered',
        kind: StudyPathLessonKind.concept,
        symbol: 'doc',
        title: {'en': 'Answered'},
        steps: [StudyPathStep(card: StudyPathCard(title: {'en': 'Card'}, body: {'en': 'Body'}))],
      );
      final session = makeSession(StudyLessonPlan.lesson(lesson), store);
      await session.start();
      expect(session.before.studiedToday, isTrue);
      session.proceed();
      expect(session.before.xp, 0);
      expect(session.before.today, 0);
    });

    test('a concept lesson of cards alone still earns and records when its last card is read', () async {
      final cards = [for (var i = 1; i <= 2; i++) StudyPathStep(card: StudyPathCard(title: {'en': 'Card $i'}, body: const {'en': 'Body'}))];
      final lesson = StudyPathLesson(id: 'p-cards', kind: StudyPathLessonKind.concept, symbol: 'doc', title: const {'en': 'Cards'}, steps: cards);
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(lesson), store);
      await session.start();
      session.proceed();
      expect(session.phase, StudyLessonPhase.asking);
      session.proceed();
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.asked, 0);
      expect(store.studyStore.lessons()['p-cards']?.runs, 1);
      expect(todaysXP(store), session.earned);
      expect(session.earned, greaterThan(0));
    });

    test('a boss lesson has build steps and looks for a picture carrying every answer tag', () async {
      const fits = StudyPathBuild(brief: {'en': 'One girl alone'}, answer: ['1girl', 'solo', 't1'], extras: ['2girls']);
      const second = StudyPathBuild(brief: {'en': 'One boy'}, answer: ['1boy', 't2', 't3'], extras: ['t5']);
      const unmatched = StudyPathBuild(brief: {'en': 'No picture has both'}, answer: ['t4', 't5'], extras: ['t6']);
      const lesson = StudyPathLesson(
        id: 'p-boss',
        kind: StudyPathLessonKind.boss,
        symbol: 'crown',
        title: {'en': 'Boss'},
        steps: [StudyPathStep(card: StudyPathCard(title: {'en': 'Go'}, body: {'en': 'Build'})), StudyPathStep(build: fits), StudyPathStep(build: second), StudyPathStep(build: unmatched)],
      );
      final source = PathFakeSource(extra: {'t1': ['1girl', 'solo'], 't3': ['1boy', 't2']});
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(lesson), store, source: source);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(kinds(session.steps), ['card', 'build', 'build', 'build']);
      expect(session.tags.map((tag) => tag.name), ['t1', 't2', 't3', 't4', 't5'], reason: 'The curriculum tags the builds use, sorted');
      expect(session.builtPictures.keys.toSet(), {fits, second}, reason: 'Only a build with a fitting picture gets one');
      for (final MapEntry(key: target, value: post) in session.builtPictures.entries) {
        expect(target.answer.toSet().difference(post.tags.toSet()), isEmpty, reason: target.brief['en']);
      }
      expect(session.builtPictures[unmatched], isNull);

      session.proceed();
      for (var i = 0; i < 3; i++) {
        expect(session.step!.isAsked, isTrue);
        session
          ..answer(true)
          ..next();
      }
      expect(session.phase, StudyLessonPhase.finished);
      expect(store.studyStore.lessons()['p-boss']?.stars, 3);
    });

    test('the pictures of a meaning or picture question never offer a tag the picture also carries and prefer the lesson\'s own tags', () async {
      const lessonTags = {'t1', 't2', 't3', 't4'};
      final store = BooruStore.inMemory();
      var sawShared = false;
      for (var round = 0; round < 30; round++) {
        // Pictures of t1 also carry t2, so t2 must never be offered as a wrong answer for them.
        final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store, source: PathFakeSource(extra: {'t1': ['t2']}), random: Random(round));
        await session.start();
        for (final step in session.steps) {
          final kind = step.kind;
          if (kind is! StudyStepQuiz || kind.question.kind == StudyQuestionKind.tagToPicture) continue;
          final question = kind.question;
          expect(question.choices[question.answer].name, question.tag.name);
          expect(question.choices.map((tag) => tag.name).toSet().length, question.choices.length);
          final shown = (question.posts.firstOrNull?.tags ?? const <String>[]).toSet();
          final wrong = [for (final (index, tag) in question.choices.indexed) if (index != question.answer) tag.name];
          expect(wrong.toSet().intersection(shown), isEmpty, reason: '$wrong offered beside a picture of $shown');
          expect(wrong.contains(question.tag.name), isFalse);
          final fairOwn = lessonTags.difference({question.tag.name}).difference(shown);
          expect(wrong.where(lessonTags.contains).length, min(fairOwn.length, wrong.length), reason: "The lesson's own tags come first for ${question.tag.name}");
          if (question.tag.name == 't1' && shown.contains('t2')) sawShared = true;
        }
      }
      expect(sawShared, isTrue, reason: 'No picture question about t1 came up in 30 lessons');
    });

    test('a review with nothing due finishes at once without earning or recording anything', () async {
      final store = BooruStore.inMemory();
      store.studyStore.answer('t1', right: true);
      final session = makeSession(StudyLessonPlan.review, store);
      await session.start();
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.steps, isEmpty);
      expect(session.tags, isEmpty);
      expect(session.earned, 0);
      expect(session.stars, 0);
      expect(store.studyStore.lessons(), isEmpty);
      expect(todaysXP(store), 0);
      expect(store.studyStore.progress()['t1']?.correct, 1);

      final empty = BooruStore.inMemory();
      final none = makeSession(StudyLessonPlan.review, empty);
      await none.start();
      expect(none.phase, StudyLessonPhase.finished);
      expect(empty.studyStore.days(), isEmpty);
      expect(empty.studyStore.lessons(), isEmpty);
    });

    test('a review of due tags asks them and earns experience but records no lesson', () async {
      final store = BooruStore.inMemory();
      final past = DateTime.now().subtract(const Duration(days: 10));
      store.studyStore.answer('t1', right: true, now: past);
      store.studyStore.answer('t2', right: true, now: past);
      store.studyStore.answer('t3', right: true);
      final session = makeSession(StudyLessonPlan.review, store);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(session.tags.map((tag) => tag.name).toSet(), {'t1', 't2'}, reason: 'Only the tags that are due');
      expect(kinds(session.steps), ['quiz', 'quiz']);
      play(session);
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.earned, 15);
      expect(todaysXP(store), 15);
      expect(store.studyStore.lessons(), isEmpty);
      final progress = store.studyStore.progress();
      expect(progress['t1']?.correct, 2);
      expect(progress['t2']?.correct, 2);
      expect(progress['t3']?.correct, 1);
    });

    test('a review of four tags puts one match step in the middle and repeats a miss', () async {
      final store = BooruStore.inMemory();
      final past = DateTime.now().subtract(const Duration(days: 10));
      for (final name in ['t1', 't2', 't3', 't4']) {
        store.studyStore.answer(name, right: true, now: past);
      }
      final session = makeSession(StudyLessonPlan.review, store);
      await session.start();
      expect(kinds(session.steps), ['quiz', 'quiz', 'match', 'quiz', 'quiz']);
      var missedOnce = false;
      play(
        session,
        right: (step) {
          if (!step.again && !missedOnce && quizTag(step) != null) {
            missedOnce = true;
            return false;
          }
          return true;
        },
      );
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.steps.length, 6, reason: 'The missed question came back once');
      expect(store.studyStore.lessons(), isEmpty);
      expect(todaysXP(store), session.earned);
    });

    test('a lesson with no steps still finishes and is recorded', () async {
      final store = BooruStore.inMemory();
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson('p-empty', ['unknown_tag'])), store);
      await session.start();
      expect(session.phase, StudyLessonPhase.finished);
      expect(session.steps, isEmpty);
      expect(store.studyStore.lessons()['p-empty'], isNotNull);
    });

    test('a lesson tells its listeners when it changes', () async {
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), BooruStore.inMemory());
      var heard = 0;
      session.addListener(() => heard += 1);
      await session.start();
      expect(heard, greaterThan(0));
      final started = heard;
      session.proceed();
      expect(heard, greaterThan(started));
      session.dispose();
    });
  });

  group('odd, spell and the weak plan', () {
    test('a tags lesson whose tags share a picture asks odd after the match and ends with one spelling', () async {
      final store = BooruStore.inMemory();
      final source = PathFakeSource(extra: {'t1': ['t2', 't3']});
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), store, source: source);
      await session.start();
      expect(kinds(session.steps), [for (var i = 0; i < 4; i++) ...['teach', 'quiz']] + ['match', 'odd'] + List.filled(4, 'quiz') + ['spell']);
      final odd = session.steps.firstWhere((step) => step.kind is StudyStepOdd).kind as StudyStepOdd;
      expect(odd.choices.length, 4);
      expect(odd.answer, inInclusiveRange(0, 3));
      expect(odd.post.tags.contains(odd.choices[odd.answer].name), isFalse, reason: 'The answer is the tag the picture does not carry');
      for (final (index, tag) in odd.choices.indexed) {
        if (index != odd.answer) expect(odd.post.tags.contains(tag.name), isTrue, reason: tag.name);
      }
      expect(odd.choices[odd.answer].name, 't4');
      final spell = session.steps.last.kind as StudyStepSpell;
      expect(['t1', 't2', 't3', 't4'], contains(spell.tag.name));
      expect(kinds(session.steps).where((kind) => kind == 'spell').length, 1);
      play(session);
      expect(session.phase, StudyLessonPhase.finished);
    });

    test('a tags lesson without pictures has no odd step and its spelling shows no picture', () async {
      final session = makeSession(StudyLessonPlan.lesson(tagsLesson()), BooruStore.inMemory(), source: PathFakeSource(failing: true));
      await session.start();
      expect(kinds(session.steps).contains('odd'), isFalse);
      expect(kinds(session.steps).where((kind) => kind == 'spell').length, 1);
      expect((session.steps.last.kind as StudyStepSpell).post, isNull);
    });

    test('a review adds odd when possible and spells only tags at step two or more, up to two', () async {
      final store = BooruStore.inMemory();
      final past = DateTime.now().subtract(const Duration(days: 10));
      for (final name in ['t1', 't2']) {
        for (var i = 0; i < 2; i++) {
          store.studyStore.answer(name, right: true, now: past);
        }
      }
      for (final name in ['t3', 't4']) {
        store.studyStore.answer(name, right: true, now: past);
      }
      final session = makeSession(StudyLessonPlan.review, store, source: PathFakeSource(extra: {'t1': ['t2', 't3']}));
      await session.start();
      expect(kinds(session.steps), ['quiz', 'quiz', 'match', 'quiz', 'quiz', 'odd', 'spell', 'spell']);
      final spelled = [for (final step in session.steps) if (step.kind case StudyStepSpell(:final tag)) tag.name];
      expect(spelled.toSet(), {'t1', 't2'}, reason: 'Only the tags at step two or more');

      final low = BooruStore.inMemory();
      for (final name in ['t1', 't2', 't3', 't4']) {
        low.studyStore.answer(name, right: true, now: past);
      }
      final plain = makeSession(StudyLessonPlan.review, low, source: PathFakeSource(extra: {'t1': ['t2', 't3']}));
      await plain.start();
      expect(kinds(plain.steps).contains('spell'), isFalse, reason: 'Tags at step one are not typed');
      expect(kinds(plain.steps).contains('odd'), isTrue);

      final many = BooruStore.inMemory();
      for (final name in ['t1', 't2', 't3', 't4']) {
        for (var i = 0; i < 3; i++) {
          many.studyStore.answer(name, right: true, now: past);
        }
      }
      final capped = makeSession(StudyLessonPlan.review, many);
      await capped.start();
      expect(kinds(capped.steps).where((kind) => kind == 'spell').length, 2, reason: 'At most two spellings');
      expect(kinds(capped.steps).contains('odd'), isFalse, reason: 'No odd step when the pictures give none');
    });

    test('the weak plan asks the missed tags and records no lesson', () async {
      final store = BooruStore.inMemory();
      for (final name in ['t1', 't2', 't3', 't4']) {
        store.studyStore.answer(name, right: false);
      }
      store.studyStore.answer('t5', right: true);
      final session = makeSession(StudyLessonPlan.weak, store);
      await session.start();
      expect(session.phase, StudyLessonPhase.asking);
      expect(session.tags.map((tag) => tag.name).toSet(), {'t1', 't2', 't3', 't4'}, reason: 'A tag never missed is not weak');
      expect(kinds(session.steps), ['quiz', 'quiz', 'match', 'quiz', 'quiz', 'quiz', 'quiz', 'quiz', 'quiz']);
      play(session);
      expect(session.phase, StudyLessonPhase.finished);
      expect(store.studyStore.lessons(), isEmpty);
      expect(todaysXP(store), greaterThan(0));

      final none = makeSession(StudyLessonPlan.weak, BooruStore.inMemory());
      await none.start();
      expect(none.phase, StudyLessonPhase.finished);
      expect(none.steps, isEmpty);
    });

    test('weakest orders by share of wrong then wrong count then name and caps and skips the never missed', () {
      final store = BooruStore.inMemory();
      void put(String tag, {required int correct, required int wrong}) =>
          store.database.write((db) => StudyStore.write(StudyProgress(tag: tag, correct: correct, wrong: wrong), db));
      put('t1', correct: 2, wrong: 2); // half, two missed
      put('t2', correct: 1, wrong: 1); // half, one missed
      put('t5', correct: 1, wrong: 1); // half, one missed, after t2 by name
      put('t3', correct: 3, wrong: 1); // a quarter
      put('t4', correct: 5, wrong: 0); // never missed
      put('t6', correct: 0, wrong: 1); // always missed
      put('not_taught', correct: 0, wrong: 9);
      final progress = store.studyStore.progress();
      final taught = pathCurriculum();
      expect(StudyLessonSession.weakest(progress, curriculum: taught, count: 10).map((tag) => tag.name), ['t6', 't1', 't2', 't5', 't3']);
      expect(StudyLessonSession.weakest(progress, curriculum: taught, count: 2).map((tag) => tag.name), ['t6', 't1']);
      expect(StudyLessonSession.weakest(progress, curriculum: taught, count: 0), isEmpty);
      expect(StudyLessonSession.weakest({}, curriculum: taught, count: 5), isEmpty);
    });

    test('spelled ignores case, treats spaces and underscores alike and never accepts nothing', () {
      final tag = plainTag('blue_eyes');
      expect(StudyLessonSession.spelled('blue_eyes', tag), isTrue);
      expect(StudyLessonSession.spelled('Blue Eyes', tag), isTrue);
      expect(StudyLessonSession.spelled('BLUE_EYES', tag), isTrue);
      expect(StudyLessonSession.spelled('  blue   eyes  ', tag), isTrue, reason: 'Extra spaces are ignored');
      expect(StudyLessonSession.spelled('blue_ eyes', tag), isTrue);
      expect(StudyLessonSession.spelled('blue eye', tag), isFalse);
      expect(StudyLessonSession.spelled('blueeyes', tag), isFalse);
      expect(StudyLessonSession.spelled('', tag), isFalse);
      expect(StudyLessonSession.spelled('   ', tag), isFalse);
      expect(StudyLessonSession.spelled('___', tag), isFalse);
      expect(StudyLessonSession.spelled('', plainTag('')), isFalse, reason: 'An empty answer is never right');
    });

    test('finishing a lesson raises the combo counter to its best run and never lowers it', () async {
      final store = BooruStore.inMemory();
      final first = makeSession(StudyLessonPlan.lesson(tagsLesson('c1')), store);
      await first.start();
      play(first);
      expect(store.studyStore.stats()[StudyCounter.combo], first.bestCombo);
      expect(first.bestCombo, 10);

      final worse = makeSession(StudyLessonPlan.lesson(tagsLesson('c2')), store);
      await worse.start();
      var turn = 0;
      play(
        worse,
        right: (_) {
          turn += 1;
          return turn % 3 != 0;
        },
      );
      expect(worse.bestCombo, lessThan(10));
      expect(store.studyStore.stats()[StudyCounter.combo], 10, reason: 'A weaker run leaves the counter alone');
    });

    test('plans compare by what they hold', () {
      final lesson = tagsLesson();
      expect(StudyLessonPlan.lesson(lesson), StudyLessonPlan.lesson(tagsLesson()));
      expect(StudyLessonPlan.lesson(lesson), isNot(StudyLessonPlan.review));
      expect(StudyLessonPlan.review, isNot(StudyLessonPlan.weak));
      expect(StudyLessonPlan.lesson(lesson).lesson, lesson);
      expect(StudyLessonPlan.weak.lesson, isNull);
    });
  });

  group('StudyLookup.examples for one server', () {
    test('ignore the chosen servers and leave out unusable and blacklisted pictures', () async {
      final store = BooruStore.inMemory();
      expect(store.selectedServers, isEmpty);
      final source = PathFakeSource(extra: {'t2': ['hidden_tag'], 't3': ['animated']});
      final plain = await StudyLookup.examples('t1', server: pathServer, store: store, source: source);
      expect(plain.length, 5, reason: 'No browsing server is chosen, and the learning server is read anyway');
      expect(plain.every((post) => post.serverID == pathServer.id && post.tags.contains('t1')), isTrue);
      final moving = await StudyLookup.examples('t3', server: pathServer, store: store, source: source);
      expect(moving, isEmpty, reason: 'Animated pictures are not examples');
      final before = await StudyLookup.examples('t2', server: pathServer, store: store, source: source);
      expect(before.length, 5);
      store.setBlacklist('hidden_tag', serverID: pathServer.id);
      final after = await StudyLookup.examples('t2', server: pathServer, store: store, source: source);
      expect(after, isEmpty, reason: "The server's blacklist still applies");
      final broken = await StudyLookup.examples('t1', server: pathServer, store: store, source: PathFakeSource(failing: true));
      expect(broken, isEmpty);
    });

    test('are read even in Safe Mode, which the browsing choice would not allow', () async {
      final store = BooruStore.inMemory();
      store.safeMode = () => true;
      final posts = await StudyLookup.examples('t1', server: pathServer, store: store, source: PathFakeSource());
      expect(posts.length, 5);
    });
  });
}
