import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/addons/addon_models.dart';
import 'package:tegnal/core/addons/addon_store.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/study_mode/study_award_views.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';
import 'package:tegnal/presentation/study_mode/study_lesson_view.dart';
import 'package:tegnal/presentation/study_mode/study_mode_model.dart';
import 'package:tegnal/presentation/study_mode/study_mode_root.dart';
import 'package:tegnal/presentation/study_mode/study_reactions.dart';
import 'package:tegnal/presentation/study_mode/study_track_views.dart';

import '../study/study_test_support.dart';
import 'study_mode_root_test.dart' show generationStore, key, nodeState, pumpMode;
import 'study_track_support.dart';

/// A phone-sized screen with the app's theme around [child], motion reduced unless [reduceMotion] is false.
Future<void> pumpView(WidgetTester tester, Widget child, {bool reduceMotion = true}) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      theme: tegnalTheme(Brightness.light),
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: home!,
      ),
      home: child,
    ),
  );
  await tester.pump();
}

/// The study sounds played while the test runs.
List<String> recordSounds() {
  final played = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(StudySound.channel, (call) async {
    if (call.method == 'play') played.add((call.arguments as Map)['name'] as String);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(StudySound.channel, null));
  return played;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundledPath = StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync());

  late StudyHarness harness;
  late Directory directory;

  setUp(() {
    StudyPath.useBundled(bundledPath);
    directory = Directory.systemTemp.createTempSync('study-track-views-');
    harness = StudyHarness();
    StudySound.attach(harness.preferences.booruDefaults);
  });

  tearDown(() {
    AddonRuntime.shared.apply(AddonEffects());
    StudyPath.useBundled(null);
    StudyCurriculum.useBundled(null);
    directory.deleteSync(recursive: true);
  });

  StudyModeModel model() => StudyModeModel(harness.booru)..reload();

  Widget page(Widget child) => Builder(
    builder: (context) => ColoredBox(
      color: StudyTheme.of(context).background,
      child: SafeArea(child: Column(children: [child])),
    ),
  );

  group('StudyTrackPicker', () {
    testWidgets('offers the main path and each track, and choosing one shows it', (tester) async {
      turnOn([trackAddon(), trackAddon(id: 'maker.second', color: 'D9534F')]);
      final subject = model();
      final played = recordSounds();
      await pumpView(
        tester,
        page(
          ListenableBuilder(
            listenable: subject,
            builder: (context, _) => StudyTrackPicker(model: subject),
          ),
        ),
      );
      expect(key('study.tracks'), findsOneWidget);
      expect(find.text('Main Track'), findsOneWidget);
      expect(find.text('Lighthouse Track'), findsNWidgets(2));
      expect(tester.widget<Semantics>(key('study.track.main')).properties.selected, isTrue);
      expect(tester.widget<Semantics>(key('study.track.maker.track')).properties.selected, isFalse);
      expect(tester.widget<Semantics>(key('study.track.maker.track')).properties.value, isNull);
      // The track's own symbol stands before its title, the map before the main path's.
      expect(find.descendant(of: key('study.track.main'), matching: find.byType(StudyIcon)).evaluate().map((e) => (e.widget as StudyIcon).symbol), [
        'map.fill',
      ]);
      expect(find.descendant(of: key('study.track.maker.track'), matching: find.byType(StudyIcon)).evaluate().map((e) => (e.widget as StudyIcon).symbol), [
        'tree',
      ]);

      // The last chip is past the screen's edge until the row is scrolled.
      await tester.ensureVisible(key('study.track.maker.second'));
      await tester.pump();
      await tester.tap(key('study.track.maker.second'));
      await tester.pump();
      expect(subject.trackID, 'maker.second');
      expect(played, ['tap']);
      expect(tester.widget<Semantics>(key('study.track.maker.second')).properties.selected, isTrue);
      expect(tester.widget<Semantics>(key('study.track.main')).properties.selected, isFalse);
      // The chosen chip is filled in the track's colour; the others are outlined.
      final chosen = tester.widget<StudyPressButton>(find.descendant(of: key('study.track.maker.second'), matching: find.byType(StudyPressButton)));
      expect(chosen.outlined, isFalse);
      expect(chosen.color, const Color(0xFFD9534F));
      expect(chosen.radius, 16);
      expect(chosen.depth, 4);
      expect(tester.widget<StudyPressButton>(find.descendant(of: key('study.track.main'), matching: find.byType(StudyPressButton))).outlined, isTrue);

      await tester.ensureVisible(key('study.track.main'));
      await tester.pump();
      await tester.tap(key('study.track.main'));
      await tester.pump();
      expect(subject.trackID, isNull);
    });

    testWidgets('a finished track wears the seal and says so', (tester) async {
      turnOn([trackAddon(lessons: 1, tags: false)]);
      final subject = model();
      harness.store.studyStore.earn(15, lesson: subject.tracks.single.path.lessons.single.id, stars: 3);
      subject.reload();
      await pumpView(tester, page(StudyTrackPicker(model: subject)));
      expect(tester.widget<Semantics>(key('study.track.maker.track')).properties.value, 'Track Completed');
      expect(find.descendant(of: key('study.track.maker.track'), matching: find.byType(StudyIcon)).evaluate().map((e) => (e.widget as StudyIcon).symbol), [
        'checkmark.seal.fill',
      ]);
    });
  });

  group('StudyTrackHeader', () {
    testWidgets('shows what the track is and how far along it is', (tester) async {
      turnOn([trackAddon()]);
      final subject = model();
      final track = subject.tracks.single;
      harness.store.studyStore.earn(15, lesson: track.path.lessons.first.id, stars: 3);
      subject.reload();
      await pumpView(tester, page(StudyTrackHeader(track: track, records: subject.records)));
      expect(key('study.track.header'), findsOneWidget);
      expect(find.text('Lighthouse Track'), findsOneWidget);
      expect(find.text('Add-on Track'), findsOneWidget);
      expect(find.text('Places by the sea'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(tester.widget<StudyBar>(find.byType(StudyBar)).value, closeTo(1 / 3, 1e-9));
      expect(tester.widget<StudyBar>(find.byType(StudyBar)).color, const Color(0xFF2F9E6E));
      expect(key('study.track.completed'), findsNothing);
      final icon = tester.widget<StudyIcon>(find.byType(StudyIcon).first);
      expect((icon.symbol, icon.size, icon.color), ('tree', 22.0, const Color(0xFF2F9E6E)));
      // Its words are read as one element.
      expect(find.descendant(of: key('study.track.header'), matching: find.byType(MergeSemantics)), findsOneWidget);
    });

    testWidgets('wears its seal once every lesson is done', (tester) async {
      turnOn([trackAddon(lessons: 1, tags: false)]);
      final subject = model();
      final track = subject.tracks.single;
      harness.store.studyStore.earn(15, lesson: track.path.lessons.single.id, stars: 3);
      subject.reload();
      await pumpView(tester, page(StudyTrackHeader(track: track, records: subject.records)));
      expect(key('study.track.completed'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('1/1'), findsOneWidget);
    });
  });

  group('StudyTrackCertificate', () {
    testWidgets('celebrates the track with its seal, and Continue closes it', (tester) async {
      turnOn([trackAddon()]);
      final track = model().tracks.single;
      final played = recordSounds();
      var closed = 0;
      await pumpView(tester, StudyTrackCertificate(track: track, close: () => closed++), reduceMotion: false);
      expect(played, ['complete']);
      expect(find.text('Track Completed'), findsOneWidget);
      expect(tester.widget<Text>(key('study.track.certificate')).data, 'Lighthouse Track');
      expect(find.text('You finished every lesson of this track.'), findsOneWidget);
      // The seal springs in from a third of its size.
      Transform seal() => tester.widget<Transform>(find.ancestor(of: find.byType(StudyIcon), matching: find.byType(Transform)).first);
      expect(seal().transform.storage[0], closeTo(0.3, 0.01));
      await tester.pump(const Duration(milliseconds: 150));
      expect(seal().transform.storage[0], greaterThan(0.3));
      await tester.pumpAndSettle();
      expect(seal().transform.storage[0], closeTo(1, 0.001));
      expect(tester.widget<StudyIcon>(find.byType(StudyIcon)).size, 96);

      await tester.tap(key('study.done'));
      await tester.pump();
      expect(closed, 1);
    });

    testWidgets('with reduced motion the seal is there at once', (tester) async {
      turnOn([trackAddon()]);
      final track = model().tracks.single;
      await pumpView(tester, StudyTrackCertificate(track: track, close: () {}));
      await tester.pump();
      final seal = tester.widget<Transform>(find.ancestor(of: find.byType(StudyIcon), matching: find.byType(Transform)).first);
      expect(seal.transform.storage[0], closeTo(1, 0.001));
    });
  });

  group('in learning mode', () {
    late StudyMode mode;

    Future<void> pumpRoot(WidgetTester tester) async {
      mode = StudyMode.forTesting()..attach(harness.preferences.booruDefaults, fixture: false);
      harness.preferences.booruDefaults.set(StudyServer.key, harness.server.id);
      await pumpMode(tester, StudyModeRoot(booru: harness.booru, mode: mode, generation: generationStore(directory)));
    }

    testWidgets('the path has no chooser while no track is on', (tester) async {
      await pumpRoot(tester);
      expect(key('study.tracks'), findsNothing);
      expect(key('study.track.header'), findsNothing);
      expect(key('study.section.s0'), findsOneWidget);
    });

    testWidgets('the chooser above the path switches to a track and back, and a track turned off hands the path back', (tester) async {
      turnOn([trackAddon()]);
      await pumpRoot(tester);
      expect(key('study.tracks'), findsOneWidget);
      expect(key('study.track.header'), findsNothing);
      // The chooser stands above the first section.
      expect(tester.getTopLeft(key('study.tracks')).dy, lessThan(tester.getTopLeft(key('study.section.s0')).dy));

      await tester.tap(key('study.track.maker.track'));
      await tester.pumpAndSettle();
      expect(key('study.track.header'), findsOneWidget);
      expect(key('study.section.addon:maker.track:coast'), findsOneWidget);
      expect(key('study.section.s0'), findsNothing);
      expect(nodeState(tester, 'addon:maker.track:idea-0'), 'Next');
      expect(nodeState(tester, 'addon:maker.track:idea-1'), 'Locked');
      expect(find.text('Idea 0'), findsWidgets);
      expect(harness.preferences.booruDefaults.string('study.track'), 'maker.track');

      // Turning the add-on off anywhere takes its track away from the path.
      AddonRuntime.shared.apply(AddonEffects());
      await tester.pumpAndSettle();
      expect(key('study.tracks'), findsNothing);
      expect(key('study.track.header'), findsNothing);
      expect(key('study.section.s0'), findsOneWidget);
      expect(harness.preferences.booruDefaults.object('study.track'), isNull);
    });

    testWidgets('a lesson of a track teaches the track\'s own tags', (tester) async {
      turnOn([trackAddon(lessons: 0)]);
      harness.preferences.booruDefaults.set('study.track', 'maker.track');
      await pumpRoot(tester);
      expect(nodeState(tester, 'addon:maker.track:sea-tags'), 'Next');
      await tester.tap(key('study.startLesson'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final session = tester.widget<StudyPlayView>(find.byType(StudyPlayView)).session;
      expect(session.engine.curriculum.contains('lighthouse'), isTrue);
      await pumpUntil(tester, find.text('lighthouse'));
      Navigator.of(tester.element(find.byType(StudyPlayView))).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('finishing the last lesson of a track brings its certificate, once', (tester) async {
      turnOn([trackAddon(lessons: 2, tags: false)]);
      final track = AddonRuntime.shared.effects.tracks.single;
      harness.preferences.booruDefaults.set('study.track', 'maker.track');
      harness.store.studyStore.earn(15, lesson: track.path.lessons.first.id, stars: 3);
      // Badges already earned have been celebrated, so that no parade comes up on arrival.
      final seen = StudyModeModel(harness.booru).refreshAwards();
      harness.store.studyStore.markSeen([for (final award in seen) award.id]);
      await pumpRoot(tester);
      expect(nodeState(tester, 'addon:maker.track:idea-1'), 'Next');

      await tester.tap(key('study.startLesson'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final view = find.byType(StudyPlayView);
      final session = tester.widget<StudyPlayView>(view).session;
      await pumpUntil(tester, find.text('Card 1'));
      session.proceed();
      await tester.pump();
      expect(session.phase.toString(), contains('finished'));
      // The results page, and any milestones after it, are walked through with Continue.
      for (var page = 0; page < 6 && view.evaluate().isNotEmpty; page++) {
        await pumpUntil(tester, key('study.done'));
        await tester.tap(key('study.done'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(view, findsNothing);
      expect(find.byType(StudyTrackCertificate), findsNothing, reason: 'It waits for the stop to burst first');
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(StudyAwardParade), findsNothing);
      expect(find.byType(StudyTrackCertificate), findsOneWidget);
      expect(tester.widget<Text>(key('study.track.certificate')).data, 'Lighthouse Track');
      expect(harness.store.studyStore.stats()['trackDone.maker.track'], 1, reason: 'Kept in study_stats, so it syncs');

      await tester.tap(key('study.done'));
      await tester.pumpAndSettle();
      expect(find.byType(StudyTrackCertificate), findsNothing);
      expect(key('study.track.completed'), findsOneWidget);
    });
  });

  test('the sample tracks in the docs folder build, and learning mode draws their symbols', () async {
    final files = sampleAddonFiles();
    if (files.isEmpty) {
      markTestSkipped('The samples are local only');
      return;
    }
    final addons = [for (final file in files) (await Addon.read(file)).addon];
    final tracks = AddonEffects([for (final (index, addon) in addons.indexed) installedAddon(addon, at: index)]).tracks;
    expect(tracks, isNotEmpty);
    for (final track in tracks) {
      expect(StudyGlyph.knows(track.symbol), isTrue, reason: track.symbol);
      for (final lesson in track.path.lessons) {
        expect(lesson.id, startsWith('addon:${track.id}:'));
        expect(StudyGlyph.knows(lesson.symbol), isTrue, reason: '${track.id} ${lesson.symbol}');
      }
    }
  });

  test('StudyGlyph knows drawn symbols and glyphs, and not unknown names', () {
    expect(StudyGlyph.knows('mountain.2.fill'), isTrue);
    expect(StudyGlyph.knows('tree'), isTrue);
    expect(StudyGlyph.knows('photo'), isTrue);
    expect(StudyGlyph.knows('circle'), isTrue);
    expect(StudyGlyph.knows('graduationcap.fill'), isTrue);
    expect(StudyGlyph.knows('no.such.symbol'), isFalse);
  });
}
