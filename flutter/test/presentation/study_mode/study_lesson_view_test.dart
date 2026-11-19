import 'dart:math';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/study/study_engine.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_parts.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_view.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';

import '../study/study_test_support.dart';

StudyTag plainTag(String name) => StudyTag(name: name, note: {'en': 'About $name.'});

/// Two tags of one group to learn, and three of another that pictures also carry, so that an odd one out is fair.
StudyCurriculum lessonCurriculum() => StudyCurriculum(
  units: [
    StudyUnit(
      id: 'u',
      title: const {'en': 'U'},
      summary: const {'en': ''},
      groups: [
        StudyGroup(id: 'hair', title: const {'en': 'Hair'}, tags: [plainTag('long_hair'), plainTag('short_hair')]),
        StudyGroup(id: 'face', title: const {'en': 'Face'}, tags: [plainTag('smile'), plainTag('blush'), plainTag('open_mouth')]),
      ],
    ),
  ],
);

/// Pictures that carry the asked tag and the face tags.
class FakePictures with BooruTagStudyUnsupported implements BooruProviding {
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    final base = 1000000 + query.runes.fold<int>(0, (hash, rune) => (hash * 31 + rune) % 100000) * 10;
    return BooruBatch(
      posts: [
        for (var index = 0; index < 4; index++) BooruFixtureSource.post(base + index, server, tags: [query, 'smile', 'blush', 'open_mouth']),
      ],
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

final conceptLesson = StudyPathLesson(
  id: 'concept',
  kind: StudyPathLessonKind.concept,
  symbol: 'book',
  title: const {'en': 'Concept'},
  steps: const [
    StudyPathStep(
      card: StudyPathCard(title: {'en': 'A First Card'}, body: {'en': 'Prompts are `tags`.'}, pose: 'wave'),
    ),
    StudyPathStep(
      ask: StudyPathAsk(
        question: {'en': 'What is a prompt made of?'},
        choices: [
          {'en': 'Tags'},
          {'en': 'Numbers'},
          {'en': 'Colours'},
        ],
        answer: 0,
        why: {'en': 'A prompt is a list of tags.'},
      ),
    ),
  ],
);

final tagLesson = StudyPathLesson(
  id: 'tags',
  kind: StudyPathLessonKind.tags,
  symbol: 'tag',
  title: const {'en': 'Hair'},
  tags: const ['long_hair', 'short_hair'],
);

class Played {
  Played(this.harness, this.session, this.navigator);
  final StudyHarness harness;
  final StudyLessonSession session;
  final GlobalKey<NavigatorState> navigator;
}

/// Opens [lesson] over a home page, on a phone-sized screen with reduced motion so that nothing sways forever.
Future<Played> play(WidgetTester tester, StudyPathLesson lesson, {double width = 402, double textScale = 1}) async {
  final harness = StudyHarness();
  final session = StudyLessonSession(
    plan: StudyLessonOfPlan(lesson),
    store: harness.store,
    source: FakePictures(),
    server: harness.server,
    engine: StudyEngine(curriculum: lessonCurriculum()),
    random: Random(7),
  );
  final model = StudyModeModel(harness.booru);
  final navigator = GlobalKey<NavigatorState>();
  tester.view.physicalSize = Size(width * 3, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      navigatorKey: navigator,
      theme: tegnalTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true, textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const Center(child: Text('Home')),
    ),
  );
  navigator.currentState!.push(
    CupertinoPageRoute<void>(
      builder: (context) => StudyPlayView(booru: harness.booru, session: session, model: model),
    ),
  );
  await settle(tester);
  await pumpUntil(tester, find.byKey(const Key('study.close')));
  for (var turn = 0; turn < 50 && session.phase == StudyLessonPhase.loading; turn++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
  return Played(harness, session, navigator);
}

/// Lets a second of animations run; the text field's cursor blinks forever, so this never waits for quiet.
Future<void> settle(WidgetTester tester) async {
  for (var step = 0; step < 10; step++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pump();
  await tester.tap(find.byKey(Key(key)));
  await settle(tester);
}

StudyChoiceState stateOf(WidgetTester tester, String key) => tester.widget<StudyChoiceButton>(find.byKey(Key(key))).state;

String verdictValue(WidgetTester tester) => tester.widget<Semantics>(find.byKey(const Key('study.verdict'))).properties.value!;

/// The index of the right answer of the step on screen.
int rightIndex(StudyStep step) => switch (step.kind) {
  StudyStepQuiz(:final question) => question.answer,
  StudyStepAsk(:final ask) => ask.answer,
  StudyStepOdd(:final answer) => answer,
  _ => throw StateError('not a choice step'),
};

/// Answers the choice step on screen, right or wrong, and checks it.
Future<void> choose(WidgetTester tester, StudyStep step, {required bool right}) async {
  final answer = rightIndex(step);
  final count = switch (step.kind) {
    StudyStepQuiz(:final question) => question.choiceCount,
    StudyStepAsk(:final ask) => ask.choices.length,
    StudyStepOdd(:final choices) => choices.length,
    _ => 0,
  };
  final index = right ? answer : (answer + 1) % count;
  final prefix = step.kind is StudyStepOdd ? 'study.odd' : 'study.choice';
  await tapKey(tester, '$prefix.$index');
  await tapKey(tester, 'study.check');
}

/// Plays on, answering everything right, until a step of kind [T] is on screen.
Future<StudyStep> playUntil<T extends StudyStepKind>(WidgetTester tester, StudyLessonSession session) async {
  for (var turn = 0; turn < 30; turn++) {
    final step = session.step!;
    if (step.kind is T) return step;
    switch (step.kind) {
      case StudyStepCard() || StudyStepTeach():
        await tapKey(tester, 'study.check');
      default:
        await choose(tester, step, right: true);
        await tapKey(tester, 'study.next');
    }
  }
  throw StateError('no $T step');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('choice states follow the pick and the check', () {
    expect(studyChoiceState(0, picked: null, answer: 1, revealed: false), StudyChoiceState.idle);
    expect(studyChoiceState(1, picked: 1, answer: 0, revealed: false), StudyChoiceState.picked);
    expect(studyChoiceState(0, picked: 1, answer: 0, revealed: true), StudyChoiceState.right);
    expect(studyChoiceState(1, picked: 1, answer: 0, revealed: true), StudyChoiceState.wrong);
    expect(studyChoiceState(2, picked: 1, answer: 0, revealed: true), StudyChoiceState.faded);
  });

  testWidgets('a card is read and passed, and the close button leaves at once on the first step', (tester) async {
    final played = await play(tester, conceptLesson);
    expect(find.text('A First Card'), findsOneWidget);
    expect(find.byKey(const Key('study.progress')), findsOneWidget);
    await tapKey(tester, 'study.close');
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(StudyPlayView), findsNothing);
    expect(played.session.index, 0);
  });

  testWidgets('a card passes on to the question, and the close button then asks before leaving', (tester) async {
    final played = await play(tester, conceptLesson);
    await tapKey(tester, 'study.check');
    expect(played.session.step!.kind, isA<StudyStepAsk>());
    expect(find.text('What is a prompt made of?'), findsOneWidget);

    await tapKey(tester, 'study.close');
    expect(find.text('Leave this lesson?'), findsOneWidget);
    expect(find.text('What you did in this lesson will not be kept.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.byType(StudyPlayView), findsOneWidget);

    await tapKey(tester, 'study.close');
    await tester.tap(find.text('Leave'));
    await settle(tester);
    expect(find.byType(StudyPlayView), findsNothing);
  });

  testWidgets('a question answered wrong shows why, keeps the choices, and comes back once to be answered right', (tester) async {
    final played = await play(tester, conceptLesson);
    final session = played.session;
    await tapKey(tester, 'study.check');
    final step = session.step!;
    final answer = rightIndex(step);
    final wrong = (answer + 1) % 3;

    // Nothing is picked yet, so Check waits.
    expect(stateOf(tester, 'study.choice.0'), StudyChoiceState.idle);
    await tapKey(tester, 'study.choice.$wrong');
    expect(stateOf(tester, 'study.choice.$wrong'), StudyChoiceState.picked);
    await tapKey(tester, 'study.check');

    expect(verdictValue(tester), 'wrong');
    expect(find.text('A prompt is a list of tags.'), findsOneWidget);
    expect(stateOf(tester, 'study.choice.$wrong'), StudyChoiceState.wrong);
    expect(stateOf(tester, 'study.choice.$answer'), StudyChoiceState.right);
    expect(stateOf(tester, 'study.choice.${3 - answer - wrong}'), StudyChoiceState.faded);
    expect(find.byKey(const Key('study.check')), findsNothing);
    expect(session.steps.length, 3);

    await tapKey(tester, 'study.next');
    final again = session.step!;
    expect(again.again, isTrue);
    expect(again.kind, isA<StudyStepAsk>());
    expect(stateOf(tester, 'study.choice.0'), StudyChoiceState.idle);

    await choose(tester, again, right: true);
    expect(verdictValue(tester), 'right');
    expect(find.text('A prompt is a list of tags.'), findsOneWidget);
    expect(session.steps.length, 3);
    expect(session.combo, 1);

    await tapKey(tester, 'study.next');
    expect(session.phase, StudyLessonPhase.finished);
    expect(find.byKey(const Key('study.close')), findsNothing);
  });

  testWidgets('a tag lesson teaches, asks, and offers an odd one out', (tester) async {
    final played = await play(tester, tagLesson);
    final session = played.session;
    expect(session.step!.kind, isA<StudyStepTeach>());
    expect(find.byKey(const Key('study.newTag')), findsOneWidget);
    expect(find.text('Pictures that carry this tag'), findsOneWidget);
    expect(find.byType(StudyZoom), findsWidgets);

    await tapKey(tester, 'study.check');
    final quiz = session.step!;
    expect(quiz.kind, isA<StudyStepQuiz>());
    await choose(tester, quiz, right: true);
    expect(verdictValue(tester), 'right');
    final question = (quiz.kind as StudyStepQuiz).question;
    expect(find.text('${question.tag.english} · ${question.tag.note.resolved('en')}', findRichText: true), findsOneWidget);
    await tapKey(tester, 'study.next');

    final odd = await playUntil<StudyStepOdd>(tester, session);
    expect(find.text('Which tag is NOT in this picture?'), findsOneWidget);
    expect(find.byKey(const Key('study.picture')), findsOneWidget);
    final kind = odd.kind as StudyStepOdd;
    await choose(tester, odd, right: false);
    expect(verdictValue(tester), 'wrong');
    expect(find.textContaining(kind.choices[kind.answer].english, findRichText: true), findsWidgets);
    expect(stateOf(tester, 'study.odd.${kind.answer}'), StudyChoiceState.right);
  });

  testWidgets('the spell step takes the tag in any case and with spaces, and its hint shows letters', (tester) async {
    final played = await play(tester, tagLesson);
    final session = played.session;
    final step = await playUntil<StudyStepSpell>(tester, session);
    final tag = (step.kind as StudyStepSpell).tag;
    expect(find.text('Type the tag yourself'), findsOneWidget);
    expect(find.byKey(const Key('study.spell.hint')), findsNothing);

    await tapKey(tester, 'study.spell.hintButton');
    await tapKey(tester, 'study.spell.hintButton');
    final english = tag.english;
    expect(find.text(english.substring(0, 2) + '·' * (english.length - 2)), findsOneWidget);

    await tester.enterText(find.byKey(const Key('study.spell.field')), '  ${english.toUpperCase().replaceAll(' ', '  ')} ');
    await settle(tester);
    await tapKey(tester, 'study.check');
    expect(verdictValue(tester), 'right');
    expect(find.byKey(const Key('study.spell.hintButton')), findsNothing);
  });

  testWidgets('every step fits a narrow phone with large text', (tester) async {
    final played = await play(tester, tagLesson, width: 360, textScale: 1.6);
    final session = played.session;
    for (var turn = 0; turn < 30 && session.phase != StudyLessonPhase.finished; turn++) {
      final step = session.step!;
      switch (step.kind) {
        case StudyStepCard() || StudyStepTeach():
          await tapKey(tester, 'study.check');
        case StudyStepSpell(:final tag):
          await tester.enterText(find.byKey(const Key('study.spell.field')), session.combo < 2 ? tag.name : 'x');
          await settle(tester);
          await tapKey(tester, 'study.check');
          await tapKey(tester, 'study.next');
        default:
          // Runs stop short of three: the combo banner is not part of this check.
          await choose(tester, step, right: session.combo < 2);
          await tapKey(tester, 'study.next');
      }
      expect(tester.takeException(), isNull);
    }
    expect(session.phase, StudyLessonPhase.finished);
  });

  testWidgets('the zoom button opens the picture through the opener', (tester) async {
    final server = BooruServer(id: 's', name: 's', baseURL: 'https://s.example', engine: BooruEngine.danbooru);
    final post = BooruFixtureSource.post(1, server);
    final other = BooruFixtureSource.post(2, server);
    final opened = <(int, int)>[];
    var tapped = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: StudyPictureOpener(
          open: (post, among) => opened.add((post.postID, among.length)),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StudyZoom(
                  post: post,
                  among: [post, other],
                  child: const ColoredBox(key: Key('whole'), color: Color(0xFF888888), child: SizedBox(width: 200, height: 120)),
                ),
                StudyZoom(
                  post: other,
                  cornerOnly: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tapped++,
                    child: const ColoredBox(key: Key('corner'), color: Color(0xFF888888), child: SizedBox(width: 200, height: 120)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('whole')));
    expect(opened, [(1, 2)]);
    await tester.tap(find.byKey(const Key('study.zoom')).first);
    expect(opened, [(1, 2), (1, 2)]);

    // Where the picture is an answer, a tap anywhere picks it and only the corner opens it.
    await tester.tap(find.byKey(const Key('corner')));
    expect(tapped, 1);
    expect(opened.length, 2);
    await tester.tap(find.byKey(const Key('study.zoom')).last);
    expect(opened.last, (2, 0));
  });
}
