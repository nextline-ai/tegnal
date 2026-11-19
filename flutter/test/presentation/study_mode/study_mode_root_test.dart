import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/generation/generation_store.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/secure_secret_store.dart';
import 'package:tegnal/presentation/design/ios_controls.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/study/study_tag_view.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_view.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';
import 'package:tegnal/presentation/study_mode/study_mode_root.dart';
import 'package:tegnal/presentation/study_mode/study_reactions.dart';

import '../study/study_test_support.dart';

Finder key(String name) => find.byKey(Key(name));

/// A phone-sized screen with motion reduced, so that the mode's endless animations rest and the screen settles.
Future<void> pumpMode(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      theme: tegnalTheme(Brightness.light),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
      home: home,
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

String? nodeState(WidgetTester tester, String lesson) => tester.widget<Semantics>(key('study.node.$lesson')).properties.value;

GenerationStore generationStore(Directory directory) =>
    GenerationStore(folder: Directory('${directory.path}/Generated'), defaults: MemoryPreferences(), keychain: GenerationKeychain(MemorySecureStorage()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundledPath = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());

  late StudyHarness harness;
  late StudyMode mode;
  late Directory directory;

  setUp(() {
    StudyPath.useBundled(bundledPath);
    directory = Directory.systemTemp.createTempSync('study-mode-root-');
  });

  tearDown(() {
    StudyPath.useBundled(null);
    StudyCurriculum.useBundled(null);
    directory.deleteSync(recursive: true);
  });

  /// The harness with its server already chosen, so the opening question stays away.
  void prepare({bool choose = true, bool welcomed = true}) {
    harness = StudyHarness(welcomed: welcomed);
    mode = StudyMode.forTesting()..attach(harness.preferences.booruDefaults, fixture: false);
    if (choose) harness.preferences.booruDefaults.set(StudyServer.key, harness.server.id);
  }

  Widget root() => StudyModeRoot(booru: harness.booru, mode: mode, generation: generationStore(directory));

  group('welcome', () {
    testWidgets('a first visit is welcomed: a hello, a daily goal and how much the learner knows, then the server question', (tester) async {
      prepare(choose: false, welcomed: false);
      await pumpMode(tester, root());
      expect(find.text('Welcome to Learning Mode!'), findsOneWidget);
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      expect(key('study.welcome.goal.20'), findsOneWidget);
      await tester.tap(key('study.welcome.goal.30'));
      await tester.pumpAndSettle();
      expect(harness.preferences.booruDefaults.integer(StudyModeModel.goalKey), 30);
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      expect(tester.widget<StudyMainButton>(key('study.welcome.next')).onPressed, isNull, reason: 'Nothing is chosen yet');
      await tester.tap(key('study.welcome.new'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Learning Mode!'), findsNothing);
      expect(harness.preferences.booruDefaults.boolean(StudyPlacement.welcomedKey), isTrue);
      expect(find.text('Where should the pictures come from?'), findsOneWidget, reason: 'The server question waits for the welcome');
    });

    testWidgets('the placement test ends at the first question not known and starts at the beginning', (tester) async {
      prepare(welcomed: false);
      await pumpMode(tester, root());
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.welcome.some'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.welcome.next'));
      await tester.pumpAndSettle();
      expect(key('study.choice.0'), findsOneWidget, reason: 'The test asks at once');
      await tester.tap(key('study.unsure'));
      await tester.pumpAndSettle();
      await tester.tap(key('study.next'));
      await tester.pumpAndSettle();
      expect(key('study.placement.title'), findsOneWidget);
      expect(find.text("Let's Start from the Beginning"), findsOneWidget);
      await tester.tap(key('study.done'));
      await tester.pumpAndSettle();
      expect(key('study.welcome'), findsNothing);
      expect(nodeState(tester, 's0-order'), 'Next');
      expect(harness.store.studyStore.stats()[StudyPlacement.counter], isNull);
    });

    testWidgets('a placement passes the earlier lessons by, which stay open, and the path starts there', (tester) async {
      prepare();
      final placed = StudyPlacement.skipped(bundledPath, stoppedAt: 2);
      harness.store.studyStore.raise(StudyPlacement.counter, placed);
      await pumpMode(tester, root());
      final lessons = bundledPath.lessons;
      expect(nodeState(tester, lessons[placed].id), 'Next');
      expect(nodeState(tester, lessons[0].id), 'Skipped');
      expect(nodeState(tester, lessons[placed + 1].id), 'Locked');
    });
  });

  group('dock', () {
    testWidgets('switches tabs, builds each the first time it opens and keeps it', (tester) async {
      prepare();
      await pumpMode(tester, root());
      expect(key('study.section.s0'), findsOneWidget);
      // Tabs not yet opened are not built.
      expect(key('study.review'), findsNothing);
      expect(key('study.leave'), findsNothing);

      await tester.tap(key('study.dock.practice'));
      await tester.pumpAndSettle();
      expect(mode.tab, StudyTab.practice);
      expect(key('study.review'), findsOneWidget);
      // The map is kept, out of reach.
      expect(key('study.section.s0'), findsOneWidget);

      await tester.tap(key('study.dock.me'));
      await tester.pumpAndSettle();
      expect(key('study.leave'), findsOneWidget);
      await tester.tap(key('study.dock.path'));
      await tester.pumpAndSettle();
      expect(mode.tab, StudyTab.path);
      expect(key('study.leave'), findsOneWidget);
      expect(key('study.review'), findsOneWidget);
      expect(tester.widget<Semantics>(key('study.dock.path')).properties.selected, isTrue);
      expect(tester.widget<Semantics>(key('study.dock.me')).properties.selected, isFalse);
    });

    testWidgets('the top bar shows the streak, the experience and the goal, and its exit leaves the mode', (tester) async {
      prepare();
      mode.enter();
      harness.store.studyStore.earn(12);
      await pumpMode(tester, root());
      expect(find.text('12/20'), findsOneWidget);
      expect(tester.widget<Semantics>(key('study.hud.xp')).properties.label, 'XP 12');
      await tester.tap(key('study.exit'));
      await tester.pump();
      expect(mode.active, isFalse);
    });
  });

  group('path', () {
    testWidgets('shows the sections, the stops with their states and the next lesson’s start card without a tap', (tester) async {
      prepare();
      harness.store.studyStore.earn(15, lesson: 's0-order', stars: 3);
      await pumpMode(tester, root());
      for (final section in bundledPath.sections) {
        expect(key('study.section.${section.id}'), findsOneWidget);
      }
      expect(nodeState(tester, 's0-order'), 'Lesson Done');
      expect(nodeState(tester, 's0-tags'), 'Next');
      expect(nodeState(tester, 's0-read'), 'Locked');
      expect(find.text('Start'), findsOneWidget);

      expect(key('study.startLesson'), findsOneWidget);
      expect(find.text('Start  +10 XP'), findsOneWidget);
      await tester.tap(key('study.closeCard'));
      await tester.pumpAndSettle();
      expect(key('study.startLesson'), findsNothing);

      // A finished lesson moves the path on, and the start card returns for the next one.
      harness.store.studyStore.earn(15, lesson: 's0-tags', stars: 2);
      harness.state.appearanceChanged();
      await tester.pumpAndSettle();
      expect(nodeState(tester, 's0-tags'), 'Lesson Done');
      expect(nodeState(tester, 's0-read'), 'Next');
      expect(key('study.startLesson'), findsOneWidget);
    });

    testWidgets('the start card opens the lesson full screen, and closing it returns to the path', (tester) async {
      prepare();
      await pumpMode(tester, root());
      await tester.tap(key('study.startLesson'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StudyPlayView), findsOneWidget);
      Navigator.of(tester.element(find.byType(StudyPlayView))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(StudyPlayView), findsNothing);
      expect(nodeState(tester, 's0-order'), 'Next');
      expect(key('study.startLesson'), findsOneWidget);
    });

    testWidgets('a section with no lessons yet says it opens in a coming update', (tester) async {
      StudyPath.useBundled(
        StudyPath(
          sections: [
            ...bundledPath.sections.take(1),
            const StudyPathSection(id: 'later', title: {'en': 'Later'}, summary: {'en': 'Still being written'}, color: '7C5CFF'),
          ],
        ),
      );
      prepare();
      await pumpMode(tester, root());
      expect(key('study.section.later'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.text('Opens in a coming update'), findsOneWidget);
    });
  });

  group('server chooser', () {
    testWidgets('opens on first visit with the suggested server first, and saves the choice', (tester) async {
      prepare(choose: false);
      final danbooru = BooruServer(id: 'images-d', name: 'Danbooru', baseURL: 'https://danbooru.donmai.us', engine: BooruEngine.danbooru);
      harness.store.saveServer(danbooru);
      await pumpMode(tester, root());

      expect(find.text('Where should the pictures come from?'), findsOneWidget);
      expect(find.text('Suggested'), findsOneWidget);
      final names = [harness.server.name, 'Safebooru', 'Danbooru'];
      for (final name in names) {
        expect(key('study.serverChoice.$name'), findsOneWidget);
      }
      final top = tester.getTopLeft(key('study.serverChoice.Danbooru')).dy;
      expect(top, lessThan(tester.getTopLeft(key('study.serverChoice.${harness.server.name}')).dy));
      expect(top, lessThan(tester.getTopLeft(key('study.serverChoice.Safebooru')).dy));

      await tester.tap(key('study.serverChoice.Safebooru'));
      await tester.pumpAndSettle();
      expect(find.text('Where should the pictures come from?'), findsNothing);
      expect(harness.preferences.booruDefaults.string(StudyServer.key), StudyServer.fallback.id);
    });
  });

  group('me', () {
    testWidgets('its switches and daily goal are kept for the next visit', (tester) async {
      prepare();
      mode.tab = StudyTab.me;
      await pumpMode(tester, root());
      expect(tester.widget<TegnalSwitch>(key('study.startInMode')).value, isFalse);
      expect(tester.widget<TegnalSwitch>(key('study.sound')).value, isTrue);

      await tester.ensureVisible(key('study.startInMode'));
      await tester.tap(key('study.startInMode'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('study.sound'));
      await tester.tap(key('study.sound'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('study.goal.30'));
      await tester.tap(key('study.goal.30'));
      await tester.pumpAndSettle();

      expect(mode.startsActive, isTrue);
      expect(StudySound.isOn, isFalse);
      final defaults = harness.preferences.booruDefaults;
      expect(defaults.boolean(StudyMode.startKey), isTrue);
      expect(defaults.boolean(StudySound.key), isFalse);
      expect(defaults.integer(StudyModeModel.goalKey), 30);
      expect(find.text('0/30'), findsOneWidget);

      // A new visit reads them back.
      await tester.pumpWidget(const SizedBox());
      final again = StudyMode.forTesting()..attach(defaults, fixture: false);
      again.tab = StudyTab.me;
      await pumpMode(tester, StudyModeRoot(booru: harness.booru, mode: again, generation: generationStore(directory)));
      expect(tester.widget<TegnalSwitch>(key('study.startInMode')).value, isTrue);
      expect(tester.widget<TegnalSwitch>(key('study.sound')).value, isFalse);
      expect(find.text('0/30'), findsOneWidget);
      StudySound.isOn = true;
    });

    testWidgets('Back to the Library leaves the mode', (tester) async {
      prepare();
      mode
        ..enter(StudyTab.me)
        ..tab = StudyTab.me;
      await pumpMode(tester, root());
      await tester.ensureVisible(key('study.leave'));
      await tester.tap(key('study.leave'));
      await tester.pump();
      expect(mode.active, isFalse);
    });
  });

  group('practice', () {
    testWidgets('Weak Spots and Speed Round open only when there is something to ask', (tester) async {
      prepare();
      mode.tab = StudyTab.practice;
      await pumpMode(tester, root());
      expect(tester.widget<StudyPressButton>(key('study.weak')).onPressed, isNull);
      expect(tester.widget<StudyPressButton>(key('study.speed')).onPressed, isNull);
      expect(tester.widget<StudyMainButton>(key('study.review')).onPressed, isNull);
      expect(find.text('Opens once you have learned 4 tags.'), findsOneWidget);

      final study = harness.store.studyStore;
      final tags = StudyCurriculum.bundled.tags.take(4).toList();
      study.answer(tags.first.name, right: false);
      for (final tag in tags) {
        study.answer(tag.name, right: true);
      }
      harness.state.appearanceChanged();
      await tester.pumpAndSettle();
      expect(tester.widget<StudyPressButton>(key('study.weak')).onPressed, isNotNull);
      expect(tester.widget<StudyPressButton>(key('study.speed')).onPressed, isNotNull);
      expect(find.text('Tags you have missed: 1. Ask them again.'), findsOneWidget);
      expect(find.text('As many as you can in a minute.'), findsOneWidget);
    });
  });

  group('collection', () {
    testWidgets('lists the tags met, each opening its page in a sheet', (tester) async {
      prepare();
      mode.tab = StudyTab.dex;
      final tag = StudyCurriculum.bundled.tags.first;
      await pumpMode(tester, root());
      expect(find.text('Tags you learn on the map are kept here.'), findsOneWidget);

      harness.store.studyStore.answer(tag.name, right: true);
      harness.state.appearanceChanged();
      await tester.pumpAndSettle();
      expect(key('study.dex.${tag.name}'), findsOneWidget);
      await tester.tap(key('study.dex.${tag.name}'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(StudyTagView), findsOneWidget);
    });
  });

  group('studio', () {
    testWidgets('the API key card leads to the lesson and the key until a key is saved', (tester) async {
      prepare();
      final generation = generationStore(directory);
      final model = StudyModeModel(harness.booru)..reload();
      await pumpMode(tester, StudyLabView(model: model, start: (_) {}, generation: generation));
      expect(find.text('Connect an API Key First'), findsOneWidget);
      expect(key('study.lab.learn'), findsOneWidget);
      expect(key('study.lab.key'), findsOneWidget);
      expect(key('study.lab.generator'), findsOneWidget);
      expect(key('study.lab.guide'), findsOneWidget);

      await tester.runAsync(() => generation.save('a-key'));
      await tester.pumpAndSettle();
      expect(find.text('API Key Connected'), findsOneWidget);
      expect(key('study.lab.learn'), findsNothing);
      expect(key('study.lab.key'), findsNothing);
    });

    testWidgets('Learn What an API Key Is starts that lesson', (tester) async {
      prepare();
      final model = StudyModeModel(harness.booru)..reload();
      StudyLessonPlan? started;
      await pumpMode(tester, StudyLabView(model: model, start: (plan) => started = plan, generation: generationStore(directory)));
      await tester.tap(key('study.lab.learn'));
      expect(started?.lesson?.id, 'api-what');
    });
  });
}
