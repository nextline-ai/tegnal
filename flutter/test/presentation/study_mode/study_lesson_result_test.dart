import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/generation/generation_store.dart';
import 'package:tegnal/core/lab/lab_course.dart';
import 'package:tegnal/core/lab/lab_records.dart';
import 'package:tegnal/core/lab/lab_store.dart';
import 'package:tegnal/core/storage/app_storage.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/study_mode/study_award_views.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_result.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';

import '../study/study_test_support.dart';

const _ask = StudyPathAsk(
  question: {'en': 'Which?'},
  choices: [
    {'en': 'A'},
    {'en': 'B'},
  ],
  answer: 0,
  why: {'en': ''},
);

const _lesson = StudyPathLesson(
  id: 'test-lesson',
  kind: StudyPathLessonKind.concept,
  symbol: 'star.fill',
  title: {'en': 'Test'},
  steps: [
    StudyPathStep(ask: _ask),
    StudyPathStep(ask: _ask),
    StudyPathStep(ask: _ask),
    StudyPathStep(ask: _ask),
  ],
);

/// A lesson of four questions played to its end, the first [mistakes] of them missed (and answered right when they
/// come back).
Future<StudyLessonSession> _played(StudyHarness harness, {int mistakes = 0, StudyLessonPlan plan = const StudyLessonPlan.lesson(_lesson)}) async {
  final session = StudyLessonSession(plan: plan, store: harness.store, source: harness.source, server: harness.server, engine: StudyEngine());
  await session.start();
  var first = 0;
  while (session.phase != StudyLessonPhase.finished) {
    final again = session.step?.again ?? false;
    session.answer(again || first >= mistakes);
    if (!again) first += 1;
    session.next();
  }
  return session;
}

Future<void> _pump(WidgetTester tester, Widget home, {bool reduceMotion = false}) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      theme: tegnalTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pump();
}

Future<void> _wait(WidgetTester tester, int milliseconds) async {
  for (var waited = 0; waited < milliseconds; waited += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _milestone(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('study.milestone'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  // Badges read the generator's store, which lives in the app's storage folder.
  setUpAll(() async {
    final folder = Directory.systemTemp.createTempSync('study-result-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, (call) async => folder.path);
    await AppStorage.prepare();
    GenerationStore.resetShared();
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    GenerationStore.resetShared();
  });

  for (final (mistakes, stars, accuracy) in [(0, 3, 100), (1, 2, 80), (2, 2, 67), (3, 1, 57)]) {
    testWidgets('$mistakes mistakes: $stars stars, the stars and the tiles unfold', (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = StudyHarness();
      final session = await _played(harness, mistakes: mistakes);
      expect(session.stars, stars);
      await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () {}));
      expect(find.text('Lesson Complete!'), findsOneWidget);
      expect(find.text('+0 XP'), findsOneWidget, reason: 'The tiles count up once they are in');
      await _wait(tester, 3500);
      expect(find.bySemanticsLabel('Stars: $stars'), findsOneWidget);
      expect(find.byKey(const Key('study.stars')), findsOneWidget);
      expect(find.text('+${session.earned} XP'), findsOneWidget);
      expect(find.text('$accuracy%'), findsOneWidget);
      expect(find.text('${session.bestCombo}'), findsOneWidget);
      expect(find.text("Today's goal"), findsOneWidget);
      expect(find.text('Day streak: 1'), findsOneWidget);
      semantics.dispose();
    });
  }

  testWidgets('the milestones follow in order: streak, goal, level, then badges; the last Continue is done', (tester) async {
    final harness = StudyHarness();
    harness.preferences.booruDefaults.set(StudyModeModel.goalKey, 10);
    harness.store.studyStore.earn(90, now: DateTime.now().subtract(const Duration(days: 1)));
    final badge = StudyAward.all().first;
    harness.store.studyStore.grant([badge.id]);
    final session = await _played(harness);
    expect(session.earned, 15);
    var done = 0;
    await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () => done += 1));
    await _wait(tester, 3500);

    Future<void> next() async {
      await tester.tap(find.byKey(const Key('study.done')));
      await _wait(tester, 2500);
    }

    await next();
    expect(_milestone(tester), '2-Day Streak!');
    expect(find.text('2'), findsOneWidget, reason: 'The streak counts on to its number');
    await next();
    expect(_milestone(tester), 'Daily Goal Met!');
    await next();
    expect(_milestone(tester), 'Level 2!');
    await next();
    expect(find.byType(StudyAwardCelebration), findsOneWidget);
    expect(_milestone(tester), badge.name);
    expect(harness.store.studyStore.awards()[badge.id]?.seen, isTrue, reason: 'A badge shown is marked seen');
    // Any other badge the lesson earned follows; then the last Continue is done.
    var badges = 1;
    while (done == 0 && badges < 20) {
      await next();
      if (done == 0) {
        expect(find.byType(StudyAwardCelebration), findsOneWidget);
        badges += 1;
      }
    }
    expect(done, 1);
    expect(badges, harness.store.studyStore.awards().length, reason: 'One page for each badge');
  });

  testWidgets('with nothing reached the first Continue is done', (tester) async {
    final harness = StudyHarness();
    harness.store.studyStore.earn(5);
    final session = await _played(harness, mistakes: 1);
    var done = 0;
    await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () => done += 1));
    await _wait(tester, 3500);
    await tester.tap(find.byKey(const Key('study.done')));
    await tester.pump();
    expect(done, 1);
  });

  testWidgets('with reduced motion everything is shown at once', (tester) async {
    final harness = StudyHarness();
    final session = await _played(harness);
    await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () {}), reduceMotion: true);
    expect(find.text('+${session.earned} XP'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byKey(const Key('study.confetti')), findsNothing);
    final title = tester.widget<Opacity>(find.ancestor(of: find.byKey(const Key('study.complete')), matching: find.byType(Opacity)).first);
    expect(title.opacity, 1);
    final card = tester.widget<Opacity>(find.ancestor(of: find.text("Today's goal"), matching: find.byType(Opacity)).first);
    expect(card.opacity, 1);
    await _wait(tester, 1000);
  });

  testWidgets('a first finish of a bought 2D course pays 보석 from a treasure chest opened after the results', (tester) async {
    final course = await tester.runAsync(LabCourse.loadBundled);
    final lab = LabStore.shared..reset();
    addTearDown(lab.reset);
    lab.progress
      ..legacyNoticed = true
      ..purchases[LabStore.tagCourse] = const LabPurchase(price: 0, count: 1, date: 0);
    // The test lesson stands in for the path's only lesson, so finishing it also finishes its section.
    StudyPath.useBundled(const StudyPath(sections: [StudyPathSection(id: 'test', title: {'en': 'Test'}, summary: {'en': ''}, color: '7C5CFF', lessons: [_lesson])]));
    addTearDown(() => StudyPath.useBundled(null));
    final harness = StudyHarness();
    final session = await _played(harness);
    final rates = course!.info.rewards;
    expect(
      session.gems?.paid,
      LabTagPayout(lesson: rates.courseLesson, stars: rates.courseStars, section: rates.courseSection),
      reason: 'A lesson without a mistake pays for itself, its three stars and its section',
    );
    final paid = session.gems!.paid.total;
    await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () {}));
    await _wait(tester, 3000);
    await tester.tap(find.byKey(const Key('study.done')));
    await _wait(tester, 800);
    // The chest waits shut, with the balance before; the button opens it.
    expect(find.text(L10n.text('study.chest.title')), findsWidgets);
    expect(find.text('${session.gems!.before}'), findsOneWidget);
    expect(find.text(L10n.text('study.chest.open')), findsOneWidget);
    await tester.tap(find.byKey(const Key('study.done')));
    await _wait(tester, 3500);
    expect(find.text(L10n.text('study.chest.got', ['$paid'])), findsOneWidget);
    expect(find.text('${session.gems!.after}'), findsOneWidget, reason: 'The balance has climbed');
    expect(find.text('+${rates.courseSection}'), findsOneWidget);
    expect(find.text(L10n.text('Continue')), findsOneWidget);
    await tester.tap(find.byKey(const Key('study.done')));
    await _wait(tester, 1500);
    expect(find.byKey(const Key('study.milestone')), findsOneWidget, reason: 'The streak comes after the chest');

    final again = await _played(harness);
    expect(again.gems, isNull, reason: 'Playing a lesson again pays nothing');
  });

  testWidgets('a review with nothing asked says there is nothing to review', (tester) async {
    final harness = StudyHarness();
    final session = await _played(harness, plan: StudyLessonPlan.review);
    await _pump(tester, StudyLessonResult(booru: harness.booru, session: session, model: StudyModeModel(harness.booru), done: () {}));
    await _wait(tester, 500);
    expect(find.text('Nothing to Review'), findsOneWidget);
    expect(find.byKey(const Key('study.stars')), findsNothing);
  });

  testWidgets('the streak page lights today in its week', (tester) async {
    await _pump(tester, const StudyMilestoneView(milestone: StudyMilestone.streak(1), days: []));
    await _wait(tester, 1500);
    expect(find.text('1-Day Streak!'), findsOneWidget);
    expect(find.text('A streak starts today. Come back tomorrow to keep it going.'), findsOneWidget);
  });
}
