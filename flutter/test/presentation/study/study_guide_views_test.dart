import 'dart:io';
import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/study/study_guide.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_session.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/presentation/study/study_guide_view.dart';
import 'package:tegnal/presentation/study/study_home_view.dart';
import 'package:tegnal/presentation/study/study_quiz_view.dart';
import 'package:tegnal/presentation/study/study_result_view.dart';

import 'study_test_support.dart';

Finder key(String name) => find.byKey(Key(name));

/// Plays ten questions: [right] says whether the question at that place is answered rightly.
/// Returns the questions as they were asked.
Future<List<StudyQuestion>> play(WidgetTester tester, StudySession session, {required bool Function(int) right, void Function(StudyQuestion)? each}) async {
  final asked = <StudyQuestion>[];
  for (var place = 0; place < StudyEngine.roundSize; place++) {
    await pumpUntil(tester, key('study.choice.0'));
    final question = session.question!;
    asked.add(question);
    each?.call(question);
    final choice = right(place) ? question.answer : (question.answer + 1) % question.choiceCount;
    await tester.tap(key('study.choice.$choice'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(key('study.next'));
    await tester.pump();
  }
  await pumpUntil(tester, key('study.score'));
  return asked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyGuide guide;
  setUp(() => StudyGuide.useBundled(guide = StudyGuide.parse(File('assets/study/PromptGuide.json').readAsStringSync())));
  tearDown(() {
    StudyCurriculum.useBundled(null);
    StudyGuide.useBundled(null);
    L10n.language = 'en';
  });

  StudySession session(StudyHarness harness) => StudySession(scope: StudyScope.today, store: harness.store, source: harness.source, random: Random(4));

  group('quiz choices', () {
    testWidgets('show no translated name in Korean, and short ones sit two to a line', (tester) async {
      L10n.language = 'ko';
      final harness = StudyHarness();
      final round = session(harness);
      await harness.pump(tester, StudyQuizHost(booru: harness.booru, session: round));
      var paired = 0;
      await play(
        tester,
        round,
        right: (place) => place.isEven,
        each: (question) {
          for (final tag in [question.tag, ...question.choices]) {
            if (tag.ko != null && tag.ko != tag.english) expect(find.text(tag.ko!), findsNothing, reason: 'Before the answer: ${tag.name}');
          }
          if (question.kind == StudyQuestionKind.tagToPicture) {
            expect(find.text(question.tag.english), findsOneWidget);
            return;
          }
          final rows = StudyQuestion.rows([for (final tag in question.choices) tag.english.length], limit: 13);
          for (final row in rows) {
            final tops = [for (final index in row) tester.getCenter(key('study.choice.$index')).dy.roundToDouble()];
            expect(tops.toSet().length, 1, reason: 'A row shares one centre line');
            if (row.length > 1) {
              paired += 1;
              expect(tester.getSize(key('study.choice.${row[0]}')).width, closeTo(tester.getSize(key('study.choice.${row[1]}')).width, 0.5));
              expect(tester.getSize(key('study.choice.${row[0]}')).width, lessThan(200));
            } else {
              expect(tester.getSize(key('study.choice.${row[0]}')).width, greaterThan(300));
            }
            expect(tester.getSize(key('study.choice.${row[0]}')).height, greaterThanOrEqualTo(58));
          }
          for (var place = 1; place < rows.length; place++) {
            expect(tester.getTopLeft(key('study.choice.${rows[place][0]}')).dy, greaterThan(tester.getTopLeft(key('study.choice.${rows[place - 1][0]}')).dy));
          }
        },
      );
      expect(paired, greaterThan(0), reason: 'Some questions offer short tags');
    });

    testWidgets('the explanation after an answer keeps the English name and the meaning but no translated name', (tester) async {
      L10n.language = 'ko';
      final harness = StudyHarness();
      final round = session(harness);
      await harness.pump(tester, StudyQuizHost(booru: harness.booru, session: round));
      await pumpUntil(tester, key('study.choice.0'));
      final question = round.question!;
      final wrong = (question.answer + 1) % question.choiceCount;
      await tester.tap(key('study.choice.$wrong'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(key('study.verdict'), findsOneWidget);
      expect(find.text(question.tag.note.resolved()), findsWidgets);
      for (final tag in [question.tag, ...question.choices]) {
        if (tag.ko != null && tag.ko != tag.english) expect(find.text(tag.ko!), findsNothing, reason: tag.name);
      }
    });
  });

  group('results', () {
    test('a round is perfect when all are right, great from seventy per cent, and otherwise practice', () {
      expect(StudyGrade.of(right: 10, total: 10), StudyGrade.perfect);
      expect(StudyGrade.of(right: 7, total: 10), StudyGrade.great);
      expect(StudyGrade.of(right: 9, total: 10), StudyGrade.great);
      expect(StudyGrade.of(right: 6, total: 10), StudyGrade.practice);
      expect(StudyGrade.of(right: 0, total: 0), StudyGrade.practice);
      expect(StudyGrade.perfect.title, 'Perfect Round!');
      expect(StudyGrade.great.title, 'Well Done!');
      expect(StudyGrade.practice.title, 'Keep Going!');
      expect([StudyGrade.perfect, StudyGrade.great, StudyGrade.practice].map((grade) => grade.confetti), [120, 70, 30]);
    });

    testWidgets('a perfect round shows its title, three tiles, the progress and the answers, with confetti', (tester) async {
      final harness = StudyHarness();
      final round = session(harness);
      await harness.pump(tester, StudyQuizHost(booru: harness.booru, session: round));
      final asked = await play(tester, round, right: (_) => true);
      expect((tester.widget(key('study.score')) as Text).data, matches(RegExp(r'^\d+ / 10$')));
      await tester.pump(const Duration(seconds: 2));
      expect((tester.widget(key('study.score')) as Text).data, '10 / 10');
      expect(find.text('Perfect Round!'), findsOneWidget);
      expect(find.text('Every answer right.'), findsOneWidget);
      expect(find.text('Day streak'), findsOneWidget);
      expect(find.text('Answered today'), findsOneWidget);
      expect(find.text('Learned'), findsOneWidget);
      expect(find.textContaining(' learned'), findsOneWidget);
      expect(find.text('Answers'), findsOneWidget);
      expect(find.text(asked.first.tag.english), findsWidgets);
      expect(key('study.confetti'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(key('study.done'), findsOneWidget);
      expect(key('study.again'), findsOneWidget);
    });

    testWidgets('a round that needs practice still celebrates, and says the missed tags come back', (tester) async {
      final harness = StudyHarness();
      final round = session(harness);
      await harness.pump(tester, StudyQuizHost(booru: harness.booru, session: round));
      await play(tester, round, right: (_) => false);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Keep Going!'), findsOneWidget);
      expect(find.text('Tags you missed come back sooner.'), findsOneWidget);
      expect((tester.widget(key('study.score')) as Text).data, '0 / 10');
      expect(key('study.confetti'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('seven right is a great round, and no confetti falls when animations are off', (tester) async {
      final harness = StudyHarness();
      final round = session(harness);
      await harness.pump(
        tester,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: StudyQuizHost(booru: harness.booru, session: round),
          ),
        ),
      );
      await play(tester, round, right: (place) => place < 7);
      expect(find.text('Well Done!'), findsOneWidget);
      expect((tester.widget(key('study.score')) as Text).data, '7 / 10', reason: 'No count-up when animations are off');
      expect(key('study.confetti'), findsNothing);
    });
  });

  group('prompt guide', () {
    testWidgets('the home screen lists it between the start section and the units, and opens the lessons', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      expect(find.text('Prompts'), findsOneWidget);
      expect(find.text('Emphasis, quality tags and what each model recommends.'), findsOneWidget);
      final guideTop = tester.getTopLeft(key('study.guide')).dy;
      expect(guideTop, greaterThan(tester.getTopLeft(key('study.start')).dy));
      expect(guideTop, lessThan(tester.getTopLeft(key('study.unit.${StudyCurriculum.bundled.units.first.id}')).dy));
      await tester.tap(key('study.guide'));
      await tester.pumpAndSettle();
      for (final lesson in guide.lessons) {
        expect(key('study.lesson.${lesson.id}'), findsOneWidget);
      }
      expect(find.text('How a Prompt Is Built'), findsOneWidget);
    });

    testWidgets('the start and review buttons centre their icon and title together', (tester) async {
      final harness = StudyHarness();
      harness.store.studyStore.answer('1girl', right: true, now: DateTime.now().subtract(const Duration(days: 3)));
      await harness.pump(tester, StudyHomeView(booru: harness.booru));
      for (final name in ['study.start', 'study.review']) {
        final box = tester.getRect(key(name));
        final icon = tester.getRect(find.descendant(of: key(name), matching: find.byType(Icon)));
        final title = tester.getRect(find.descendant(of: key(name), matching: find.byType(Text)));
        expect(icon.right, lessThan(title.left));
        expect(title.left - icon.right, lessThan(12), reason: 'The icon sits next to the title');
        expect(((icon.left + title.right) / 2), closeTo(box.center.dx, 1), reason: name);
      }
    });

    testWidgets('a lesson opens with its parts, questions and sources', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyGuideView(booru: harness.booru));
      await tester.tap(key('study.lesson.basics'));
      await tester.pumpAndSettle();
      expect(find.text('Check Yourself'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Try It'), findsNothing);
      expect(key('study.check.0.0'), findsOneWidget);
    });

    testWidgets('a question answered wrong can be tried again, and finishing the right way marks the lesson', (tester) async {
      final harness = StudyHarness();
      final lesson = guide.lessons.firstWhere((lesson) => lesson.id == 'basics');
      expect(lesson.checks.length, 1);
      final answer = lesson.checks.single.answer;
      final wrong = (answer + 1) % lesson.checks.single.choices.length;
      await harness.pump(tester, StudyGuideView(booru: harness.booru));
      await tester.tap(key('study.lesson.basics'));
      await tester.pumpAndSettle();

      await tester.tap(key('study.check.0.$wrong'));
      await tester.pump();
      expect(key('study.check.0.why'), findsOneWidget);
      expect(key('study.check.0.retry'), findsOneWidget);
      expect(harness.preferences.booruDefaults.string('study.guideFinished'), isNull);

      await tester.tap(key('study.check.0.retry'));
      await tester.pump();
      expect(key('study.check.0.why'), findsNothing);
      await tester.tap(key('study.check.0.$answer'));
      await tester.pump();
      expect(key('study.check.0.retry'), findsNothing);
      expect(harness.preferences.booruDefaults.string('study.guideFinished'), 'basics');

      Navigator.of(tester.element(key('study.check.0.0'))).pop();
      await tester.pumpAndSettle();
      expect(find.descendant(of: key('study.lesson.basics'), matching: find.byIcon(CupertinoIcons.checkmark_circle_fill)), findsOneWidget);
      expect(find.descendant(of: key('study.lesson.quality'), matching: find.byIcon(CupertinoIcons.checkmark_circle_fill)), findsNothing);
    });

    testWidgets('the emphasis tool writes the tag in each notation and follows the weight and the words', (tester) async {
      final harness = StudyHarness();
      await harness.pump(tester, StudyGuideView(booru: harness.booru));
      await tester.tap(key('study.lesson.emphasis-novelai'));
      await tester.pumpAndSettle();
      expect(find.text('Try It'), findsOneWidget);
      expect(find.text('{{{{rain}}}}'), findsOneWidget);
      expect(find.text('1.2::rain ::'), findsOneWidget);
      expect(find.text('(rain:1.2)'), findsOneWidget);
      expect(find.text('NovelAI { } · 1.216'), findsOneWidget, reason: 'Braces give the nearest step');

      await tester.tap(key('study.emphasis.plus'));
      await tester.pump();
      expect(find.text('{{{{{rain}}}}}'), findsOneWidget);
      expect(find.text('1.25::rain ::'), findsOneWidget);
      expect(find.text('(rain:1.25)'), findsOneWidget);

      await tester.enterText(key('study.emphasis.tag'), 'Hair (x)');
      await tester.pump();
      expect(find.text(r'(hair \(x\):1.25)'), findsOneWidget);
      expect(find.text('1.25::hair (x) ::'), findsOneWidget);
    });
  });
}
