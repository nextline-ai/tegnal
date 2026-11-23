// The AI lab's screens, as the iOS `LabUITests` walk them: the deck, an episode from its disaster to its engraved card,
// the folded pile, the cheat sheet and the shop. Set LAB_SHOTS to a folder to also write each screen as a PNG,
// drawn with the app's own fonts in Korean.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/lab/lab_course.dart';
import 'package:tegnal/core/lab/lab_sheet.dart';
import 'package:tegnal/core/lab/lab_store.dart';
import 'package:tegnal/core/study/study_models.dart';
import 'package:tegnal/core/study/study_path.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/lab/lab_episode_view.dart';
import 'package:tegnal/presentation/lab/lab_kit.dart';
import 'package:tegnal/presentation/lab/lab_root.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';

Finder key(String name) => find.byKey(Key(name));

final _shots = Platform.environment['LAB_SHOTS'];
final _frame = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyMode mode;
  late BooruStore booru;

  setUpAll(() async {
    await LabCourse.loadBundled();
    await LabShop.loadBundled();
    await LabDiagnosis.loadBundled();
    await LabEdition.loadBundled();
    StudyPath.useBundled(StudyPath.parse(File('assets/study/StudyPath.json').readAsStringSync()));
    StudyCurriculum.useBundled(StudyCurriculum.parse(File('assets/study/TagStudy.json').readAsStringSync()));
    if (_shots != null) {
      L10n.language = 'ko';
      L10n.table = (jsonDecode(File('assets/l10n/ko.json').readAsStringSync()) as Map).cast<String, String>();
      for (final (family, files) in [
        ('Noto Serif KR', ['assets/fonts/NotoSerifKR-SemiBold.otf', 'assets/fonts/NotoSerifKR-Black.otf']),
        ('Pretendard', ['assets/fonts/PretendardVariable.ttf']),
        ('packages/cupertino_icons/CupertinoIcons', ['packages/cupertino_icons/assets/CupertinoIcons.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final file in files) {
          loader.addFont(rootBundle.load(file));
        }
        await loader.load();
      }
      Directory(_shots!).createSync(recursive: true);
    }
  });

  setUp(() {
    booru = BooruStore.inMemory(preferences: AppPreferences.memory());
    LabStore.shared.attach(booru.database);
    LabStore.shared.reset();
    LabStore.shared.greeted();
    mode = StudyMode.forTesting();
  });

  /// A phone-sized dark screen.
  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _frame,
        child: CupertinoApp(theme: tegnalTheme(Brightness.dark), home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    final folder = _shots;
    if (folder == null) return;
    await tester.runAsync(() async {
      final boundary = _frame.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$folder/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  void seed(String before) {
    final course = LabStore.shared.course;
    for (final episode in course.episodes.takeWhile((episode) => episode.id != before)) {
      LabStore.shared.engrave(episode, failsHung: 0);
    }
  }

  testWidgets('a first episode hangs a 망작, passes its tool and engraves its card into the deck', (tester) async {
    await pump(tester, LabRoot(booru: booru, mode: mode));
    await shot(tester, '01-deck-empty');
    expect(key('lab.deck.next.title'), findsOneWidget);

    await tester.tap(key('lab.deck.start'));
    await tester.pumpAndSettle();
    expect(key('lab.disaster'), findsOneWidget);
    await shot(tester, '02-disaster');

    // A trap hangs its 망작, with no penalty.
    await tester.tap(key('lab.choice.0'));
    await tester.pumpAndSettle();
    expect(key('lab.fail.tag'), findsOneWidget);
    expect(LabStore.shared.progress.fails, hasLength(1));
    await shot(tester, '03-trap');
    // The 망작 comes up as a card won, once the reply has been read.
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    await tester.tap(key('lab.fail.reveal.done'));
    await tester.pumpAndSettle();
    await tester.tap(key('lab.choice.back'));
    await tester.pumpAndSettle();

    await tester.tap(key('lab.choice.2'));
    await tester.pumpAndSettle();
    await tester.tap(key('lab.choice.next'));
    await tester.pumpAndSettle();
    expect(key('lab.tool.engrave'), findsNothing);
    // The big model and deep thinking pass the switches.
    await tester.tap(find.text(LabText.parse('큰 모델').text).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(LabText.parse('깊게').text).last);
    await tester.pumpAndSettle();
    await shot(tester, '04-tool');
    expect(key('lab.tool.engrave'), findsOneWidget);

    await tester.tap(key('lab.tool.engrave'));
    await tester.pump(const Duration(milliseconds: 900));
    await shot(tester, '05-engrave-turning');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await shot(tester, '06-engraved');
    expect(LabStore.shared.earned(LabStore.shared.course.episode('ep01')!), isTrue);
    expect(key('lab.engrave.rate'), findsOneWidget);

    await tester.tap(key('lab.engrave.put'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(key('lab.deck.earned.ep01'), findsOneWidget);
    await shot(tester, '07-deck-one');
  });

  testWidgets('older cards fold into a pile that fans out and folds again', (tester) async {
    seed('ep13');
    await pump(tester, LabRoot(booru: booru, mode: mode));
    await shot(tester, '08-deck-folded');
    expect(key('lab.deck.fan'), findsOneWidget);
    expect(find.text(L10n.text('lab.deck.unfold', ['13'])), findsOneWidget, reason: 'Card No. 000 and twelve cards');
    await tester.tap(key('lab.deck.fan'));
    await tester.pumpAndSettle();
    await shot(tester, '09-deck-fanned');
    expect(find.text(L10n.text('lab.deck.fold')), findsOneWidget);
  });

  testWidgets('the cheat sheet pays once for a new edition and blacks out what no card has opened', (tester) async {
    seed('ep02');
    await pump(tester, LabRoot(booru: booru, mode: mode));
    await tester.tap(key('lab.tab.sheet'));
    await tester.pumpAndSettle();
    await shot(tester, '10-sheet');
    expect(key('lab.sheet.section.models'), findsOneWidget);
    expect(key('lab.sheet.locked.harness'), findsOneWidget);
    expect(key('lab.sheet.paid'), findsOneWidget);
    expect(LabStore.shared.editionWaiting, isFalse);
  });

  testWidgets('the courses tab sells the 2D course once season 1 has paid for it, and then opens it', (tester) async {
    seed('ep05');
    await pump(tester, LabRoot(booru: booru, mode: mode));
    await tester.tap(key('lab.tab.shop'));
    await tester.pumpAndSettle();
    await shot(tester, '11-shop');
    await tester.tap(key('lab.tab.courses'));
    // The course's guide keeps moving on this page, so the screen never settles; time is pumped instead.
    await tester.pump(const Duration(seconds: 1));
    expect(mode.labTab, LabTab.courses);
    expect(find.byType(LabCoursesView), findsOneWidget);
    // The lab is marked as the course on screen; the 2D course shows its price.
    expect(find.descendant(of: key('lab.courses.lab'), matching: key('lab.courses.here')), findsOneWidget);
    expect(find.descendant(of: key('lab.courses.tags'), matching: key('lab.courses.here')), findsNothing);
    await shot(tester, '12-courses');
    await tester.tap(key('lab.2d.buy'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text(L10n.text('lab.shop.buy', ['600'])).last);
    await tester.pump(const Duration(seconds: 1));
    expect(LabStore.shared.ownsTagCourse, isTrue);
    expect(mode.tagsOpen, isTrue, reason: 'Buying opens the course');
    // Back in the lab, the courses tab now offers to open the course rather than sell it.
    mode.closeTags();
    expect(mode.labTab, LabTab.deck, reason: 'Coming back from the course lands on the deck');
    mode.labTab = LabTab.courses;
    await tester.pump(const Duration(seconds: 1));
    expect(key('lab.2d.buy'), findsNothing);
    await tester.tap(key('lab.courses.open.tags'));
    await tester.pump(const Duration(seconds: 1));
    expect(mode.tagsOpen, isTrue);
  });

  testWidgets('a trap won for the first time brings its 망작 up as a card, over the chat that keeps the reply', (tester) async {
    final episode = LabStore.shared.course.episodes.first;
    await pump(tester, LabEpisodeView(episode: episode));
    final trap = episode.choices.indexWhere((choice) => !choice.isRight);
    final fail = episode.fails.firstWhere((fail) => fail.choice == episode.choices[trap].text);
    await tester.tap(key('lab.choice.$trap'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(key('lab.fail.reveal'), findsOneWidget);
    expect(find.text(L10n.text('lab.fail.got')), findsOneWidget);
    expect(find.text(fail.name.text), findsOneWidget);
    expect(find.text(labWords(fail.reply.text)), findsNWidgets(2), reason: 'The reply stays in the chat and is framed on the card');
    await shot(tester, '13-flop');
    await tester.tap(key('lab.fail.reveal.done'));
    await tester.pumpAndSettle();
    expect(key('lab.fail.reveal'), findsNothing);
    expect(key('lab.fail.tag'), findsOneWidget);
    // Pressed again, it is already in the gallery: no card comes up.
    await tester.tap(key('lab.choice.back'));
    await tester.pumpAndSettle();
    await tester.tap(key('lab.choice.$trap'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(key('lab.fail.reveal'), findsNothing);
  });


  testWidgets('an episode shows no number at its top right', (tester) async {
    await pump(tester, LabEpisodeView(episode: LabStore.shared.course.episodes.first));
    expect(find.text(LabStore.shared.course.episodes.first.serial), findsNothing);
  });
}
