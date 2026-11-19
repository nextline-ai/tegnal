import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/study/study_awards.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_speed.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/presentation/study_mode/study_speed_view.dart';

StudyCurriculum curriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'u',
      title: const {'en': 'U'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(
          id: 'g',
          title: const {'en': 'G'},
          tags: [for (var i = 1; i <= 6; i++) StudyTag(name: 'tag_$i', ko: 'k$i', ja: 'j$i', note: {'en': 'meaning $i'})],
        ),
      ],
    ),
  ],
);

/// A round over five met tags whose clock is [clock].
class Speed {
  Speed({int best = 0}) {
    for (var i = 1; i <= 5; i++) {
      store.studyStore.answer('tag_$i', right: true);
    }
    if (best > 0) store.studyStore.raise(StudyCounter.speed, best);
    round = StudySpeedRound(store: store, curriculum: curriculum(), random: Random(3), now: () => clock);
  }

  final store = BooruStore.inMemory();
  DateTime clock = DateTime(2026, 11, 19, 12);
  late final StudySpeedRound round;

  Future<void> pump(WidgetTester tester, {double width = 402}) async {
    tester.view.physicalSize = Size(width * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CupertinoApp(home: StudySpeedView(round: round, now: () => clock)));
    await tester.pump();
  }

  /// A choice of the question on top; the one before may still be fading out.
  Finder choice(int index) => find.byKey(Key('study.speed.choice.$index')).last;

  String score(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(const Key('study.speed.score')), matching: find.byType(Text)))
      .last
      .data!;
}

void main() {
  testWidgets('the ready page explains the round and Go starts it', (tester) async {
    final speed = Speed(best: 7);
    await speed.pump(tester);
    expect(find.text('Speed Round'), findsOneWidget);
    expect(find.text('Your best: 7'), findsOneWidget);
    expect(find.byKey(const Key('study.close')), findsOneWidget);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    expect(speed.round.phase, StudySpeedPhase.playing);
    expect(find.byKey(const Key('study.close')), findsOneWidget);
    expect(find.byKey(const Key('study.speed.score')), findsOneWidget);
    for (var index = 0; index < 4; index++) {
      expect(speed.choice(index), findsOneWidget);
    }
    expect(find.text(speed.round.question!.tag.note.resolved()), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right tap raises the score and moves on; a wrong one does not', (tester) async {
    final speed = Speed();
    await speed.pump(tester);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();

    final first = speed.round.question!;
    await tester.tap(speed.choice(first.answer));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(speed.round.score, 1);
    expect(speed.score(tester), '1');
    expect(speed.round.question!.id, isNot(first.id), reason: 'A right answer moves on after 220 ms');

    final second = speed.round.question!;
    final wrong = (second.answer + 1) % second.choices.length;
    await tester.tap(speed.choice(wrong));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(speed.round.score, 1);
    expect(speed.score(tester), '1');
    // The right tag is shown in green, and nothing can be tapped until the next question.
    expect(speed.round.question!.id, second.id, reason: 'A wrong answer stays for 800 ms');
    await tester.tap(speed.choice(second.answer), warnIfMissed: false);
    await tester.pump();
    expect(speed.round.score, 1);
    await tester.pump(const Duration(milliseconds: 600));
    expect(speed.round.question!.id, isNot(second.id));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('three right in a row are called out', (tester) async {
    final speed = Speed();
    await speed.pump(tester);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    for (var run = 0; run < 3; run++) {
      await tester.tap(speed.choice(speed.round.question!.answer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('3 in a row!'), findsOneWidget);
  });

  testWidgets('when the time runs out the result shows the XP earned', (tester) async {
    final speed = Speed(best: 1);
    await speed.pump(tester);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    for (var run = 0; run < 2; run++) {
      await tester.tap(speed.choice(speed.round.question!.answer));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    speed.clock = speed.clock.add(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(speed.round.phase, StudySpeedPhase.playing);
    speed.clock = speed.clock.add(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(speed.round.phase, StudySpeedPhase.finished);
    expect(find.byKey(const Key('study.speed.done')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('+2 XP'), findsOneWidget);
    expect(find.text('New Best!'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(speed.store.studyStore.stats()[StudyCounter.speed], 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a round with nothing right shows the best score instead', (tester) async {
    final speed = Speed(best: 5);
    await speed.pump(tester);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    speed.clock = speed.clock.add(const Duration(seconds: 61));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('+0 XP'), findsOneWidget);
    expect(find.text('New Best!'), findsNothing);
    expect(find.text('Your best: 5'), findsOneWidget);
  });

  testWidgets('close and Continue pop the page', (tester) async {
    final speed = Speed();
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            child: const Text('open'),
            onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => StudySpeedView(round: speed.round, now: () => speed.clock))),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    speed.clock = speed.clock.add(const Duration(seconds: 61));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('study.done')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(StudySpeedView), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('fits a phone 360 wide', (tester) async {
    final speed = Speed();
    await speed.pump(tester, width: 360);
    await tester.tap(find.byKey(const Key('study.speed.go')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
}
