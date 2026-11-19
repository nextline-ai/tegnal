import 'dart:io';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/presentation/study_mode/study_award_views.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';

import '../study/study_test_support.dart';

Widget host(Widget child, {Brightness brightness = Brightness.light, bool reduceMotion = false}) => CupertinoApp(
  debugShowCheckedModeBanner: false,
  theme: CupertinoThemeData(brightness: brightness),
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: home!,
  ),
  home: Center(child: child),
);

StudyAward awardOf(String id) => StudyAward.all().firstWhere((award) => award.id == id);

/// A model over an in-memory store, read once.
StudyModeModel modelOf(StudyHarness harness) => StudyModeModel(harness.booru)..reload();

void main() {
  setUpAll(() => StudyPath.useBundled(StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync())));
  tearDownAll(() => StudyPath.useBundled(null));

  group('StudyBadgeShape', () {
    test('every family has an outline inside its square', () {
      for (final family in StudyAwardFamily.values) {
        for (final side in [12.0, 46.0, 92.0, 190.0]) {
          final rect = Rect.fromLTWH(10, 20, side, side);
          final bounds = StudyBadgeShape(family).path(rect).getBounds();
          expect(bounds.isEmpty, isFalse, reason: '$family at $side');
          expect(rect.inflate(side * 0.02 + 0.5).contains(bounds.topLeft), isTrue, reason: '$family at $side');
          expect(rect.inflate(side * 0.02 + 0.5).contains(bounds.bottomRight), isTrue, reason: '$family at $side');
          // Every outline reaches well across its square.
          expect(bounds.width, greaterThan(side * 0.6), reason: '$family at $side');
        }
      }
    });

    test('the corners are rounded: the hexagon does not reach its sharp points', () {
      final path = const StudyBadgeShape(StudyAwardFamily.lessons).path(const Rect.fromLTWH(0, 0, 100, 100));
      // The sharp hexagon's top point is (50, 0); the rounded one stays below it.
      expect(path.contains(const Offset(50, 1)), isFalse);
      expect(path.contains(const Offset(50, 5)), isTrue);
      expect(path.contains(const Offset(50, 50)), isTrue);
    });

    test('the metals', () {
      expect(StudyMetal.of(awardOf('lessons-1')).mid, const Color(0xFFCC7A3A));
      expect(StudyMetal.of(awardOf('lessons-10')).mid, const Color(0xFFB4BDCB));
      expect(StudyMetal.of(awardOf('lessons-30')).mid, const Color(0xFFFFB627));
      expect(StudyMetal.of(awardOf('lessons-all')).hues, hasLength(6));
      final section = StudyAward.all().firstWhere((award) => award.family == StudyAwardFamily.sections);
      expect(StudyMetal.of(section).hues, isNull);
      expect(StudyMetal.of(section).mid.toARGB32() & 0xFFFFFF, int.parse(section.color!, radix: 16));
    });
  });

  group('StudyMedal', () {
    testWidgets('every family paints, earned and locked, at several sizes and in both appearances', (tester) async {
      final families = {for (final award in StudyAward.all()) award.family: award};
      expect(families.keys.toSet(), StudyAwardFamily.values.toSet());
      for (final brightness in Brightness.values) {
        for (final size in [20.0, 46.0, 92.0, 190.0]) {
          await tester.pumpWidget(
            host(
              Wrap(
                children: [
                  for (final award in families.values) ...[
                    StudyMedal(award: award, size: size),
                    StudyMedal(award: award, earned: false, progress: 0.4, size: size),
                  ],
                  // The prism metal with its hues.
                  StudyMedal(award: awardOf('lessons-all'), size: size),
                ],
              ),
              brightness: brightness,
            ),
          );
          // Through a whole sweep of the light.
          await tester.pump(const Duration(milliseconds: 2900));
          await tester.pump(const Duration(milliseconds: 700));
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('a locked badge is 18 % larger for its ring', (tester) async {
      await tester.pumpWidget(
        host(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StudyMedal(key: const Key('earned'), award: awardOf('xp-100'), size: 50),
              StudyMedal(key: const Key('locked'), award: awardOf('xp-100'), earned: false, size: 50),
            ],
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('earned'))), const Size(50, 50));
      expect(tester.getSize(find.byKey(const Key('locked'))).width, closeTo(59, 0.01));
    });

    testWidgets('says its name and whether it is earned', (tester) async {
      final semantics = tester.ensureSemantics();
      final award = awardOf('combo-5');
      await tester.pumpWidget(host(StudyMedal(award: award)));
      var data = tester.getSemantics(find.byType(StudyMedal)).getSemanticsData();
      expect(data.label, award.name);
      expect(data.value, 'Earned');
      await tester.pumpWidget(host(StudyMedal(award: award, earned: false, progress: 0.5)));
      data = tester.getSemantics(find.byType(StudyMedal)).getSemanticsData();
      expect(data.label, award.name);
      expect(data.value, 'Locked');
      semantics.dispose();
    });

    testWidgets('stands still with reduced motion', (tester) async {
      await tester.pumpWidget(host(StudyMedal(award: awardOf('xp-100')), reduceMotion: true));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('StudyAwardsCard', () {
    testWidgets('shows the four newest earned badges and the count', (tester) async {
      final harness = StudyHarness();
      final base = DateTime.utc(2026, 3, 1);
      for (final (index, id) in ['lessons-1', 'streak-3', 'tags-10', 'perfect-1', 'combo-5'].indexed) {
        harness.store.studyStore.grant([id], seen: true, now: base.add(Duration(days: index)));
      }
      final model = modelOf(harness);
      var opened = 0;
      await harness.pump(tester, Center(child: StudyAwardsCard(model: model, open: () => opened++)));
      final shown = tester.widgetList<StudyMedal>(find.byType(StudyMedal)).map((medal) => medal.award.id).toList();
      expect(shown, ['combo-5', 'perfect-1', 'tags-10', 'streak-3']);
      expect(find.text('5 / ${model.awards.length}'), findsOneWidget);
      await tester.tap(find.byKey(const Key('study.awards')));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('with none earned, shows the nearest to being earned', (tester) async {
      final harness = StudyHarness();
      final model = modelOf(harness);
      model.facts = StudyFacts(xp: 90, combo: 4);
      await harness.pump(tester, Center(child: StudyAwardsCard(model: model, open: () {})));
      final medals = tester.widgetList<StudyMedal>(find.byType(StudyMedal)).toList();
      expect(medals.map((medal) => medal.award.id).take(2), ['xp-100', 'combo-5']);
      expect(medals.every((medal) => !medal.earned), isTrue);
      expect(medals, hasLength(4));
    });
  });

  group('StudyAwardsGallery', () {
    testWidgets('groups badges by family and shows the progress of locked ones', (tester) async {
      final harness = StudyHarness();
      harness.store.studyStore.grant(['lessons-1', 'xp-100'], seen: true);
      final model = modelOf(harness);
      model.facts = StudyFacts(lessons: 4, xp: 120, speed: 25);
      await harness.pump(tester, StudyAwardsGallery(model: model));
      expect(find.byKey(const Key('study.awards.count')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('/ ${model.awards.length}'), findsOneWidget);
      for (final family in StudyAwardFamily.values) {
        expect(find.text(family.title), findsOneWidget, reason: '$family');
      }
      // The family's count and a locked badge's own progress, capped at its goal.
      expect(find.text('1 / 4'), findsWidgets);
      expect(find.descendant(of: find.byKey(const Key('study.award.lessons-10')), matching: find.text('4 / 10')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('study.award.xp-500')), matching: find.text('120 / 500')), findsOneWidget);
      // An earned badge shows no progress.
      expect(find.descendant(of: find.byKey(const Key('study.award.lessons-1')), matching: find.textContaining(' / ')), findsNothing);
      // Each badge sits in its family's card, in order.
      final lessons = tester.getTopLeft(find.byKey(const Key('study.award.lessons-1')));
      final speed = tester.getTopLeft(find.byKey(const Key('study.award.speed-20')));
      expect(speed.dy, greaterThan(lessons.dy));
      expect(find.byKey(const Key('study.awards.close')), findsOneWidget);
    });

    testWidgets('a badge opens its detail with the earned date', (tester) async {
      final harness = StudyHarness();
      harness.store.studyStore.grant(['streak-3'], seen: true, now: DateTime(2026, 11, 19, 12));
      final model = modelOf(harness);
      await harness.pump(tester, StudyAwardsGallery(model: model));
      await tester.tap(find.byKey(const Key('study.award.streak-3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('study.award.name')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('study.award.name'))).data, awardOf('streak-3').name);
      expect(find.text('Earned on Nov 19, 2026'), findsOneWidget);
      // The rest of the family is in a row below.
      expect(find.byType(StudyMedal), findsWidgets);
    });
  });

  group('StudyAwardDetail', () {
    testWidgets('a locked badge shows its progress, and tilts and springs back under a finger', (tester) async {
      final family = StudyAward.all().where((award) => award.family == StudyAwardFamily.tags).toList();
      await tester.pumpWidget(
        host(
          StudyAwardDetail(award: family[1], record: null, facts: StudyFacts(learned: 12), family: family, earned: const {}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('12 / 50'), findsOneWidget);
      expect(find.textContaining('Earned on'), findsNothing);
      expect(find.byType(StudyMedal), findsNWidgets(1 + family.length));

      final big = find.byType(StudyMedal).first;
      final gesture = await tester.startGesture(tester.getCenter(big));
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      Matrix4 tilt() => tester.widgetList<Transform>(find.ancestor(of: big, matching: find.byType(Transform))).map((t) => t.transform).firstWhere(
        (matrix) => matrix.entry(2, 0) != 0 || matrix.entry(2, 1) != 0,
        orElse: Matrix4.identity,
      );
      // 80 points across turns it 20° about the upright axis.
      expect(tilt().entry(2, 0).abs(), closeTo(math.sin(20 * math.pi / 180), 0.01));
      await gesture.moveBy(const Offset(400, 0));
      await tester.pump();
      expect(tilt().entry(2, 0).abs(), closeTo(math.sin(30 * math.pi / 180), 1e-6), reason: 'The tilt stops at 120 points');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tilt().entry(2, 0).abs(), lessThan(0.5));
      await tester.pump(const Duration(seconds: 3));
      expect(tilt().entry(2, 0), closeTo(0, 1e-6));
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a phone 360 wide with the five studio badges', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final family = StudyAward.all().where((award) => award.family == StudyAwardFamily.studio).toList();
      await tester.pumpWidget(
        host(StudyAwardDetail(award: family.first, record: null, facts: StudyFacts(), family: family, earned: const {})),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  group('StudyAwardCelebration and StudyAwardParade', () {
    testWidgets('a celebration names the badge', (tester) async {
      final award = awardOf('perfect-10');
      await tester.pumpWidget(host(SizedBox(width: 400, height: 800, child: StudyAwardCelebration(award: award))));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Achievement Unlocked!'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('study.milestone'))).data, award.name);
      expect(find.text(award.explanation), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the parade walks through its badges and calls done after the last', (tester) async {
      final awards = [awardOf('lessons-1'), awardOf('studio-1'), awardOf('speed-10')];
      var done = 0;
      await tester.pumpWidget(host(StudyAwardParade(awards: awards, done: () => done++)));
      await tester.pump(const Duration(seconds: 1));
      for (final (index, award) in awards.indexed) {
        expect(tester.widget<Text>(find.byKey(const Key('study.milestone'))).data, award.name, reason: 'page $index');
        await tester.tap(find.byKey(const Key('study.done')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(done, index == awards.length - 1 ? 1 : 0);
      }
    });
  });
}
