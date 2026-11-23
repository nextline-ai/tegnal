import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/home/home_stage.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';
import 'package:tegnal/presentation/study_mode/study_reactions.dart';

Widget host(Widget child, {Brightness brightness = Brightness.light, bool reduceMotion = false}) => CupertinoApp(
  debugShowCheckedModeBanner: false,
  theme: CupertinoThemeData(brightness: brightness),
  builder: (context, home) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: home!,
  ),
  home: Center(child: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StudyTheme and colours', () {
    testWidgets('colours follow the appearance', (tester) async {
      late StudyTheme light;
      late StudyTheme dark;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              light = StudyTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              dark = StudyTheme.of(context);
              return const SizedBox();
            },
          ),
          brightness: Brightness.dark,
        ),
      );
      expect(light.background, const Color(0xFFF6F4FF));
      expect(dark.background, const Color(0xFF13112A));
      expect(dark.primary, light.primary);
    });

    test('edge is darker and lifted is paler', () {
      final base = studyHex('7C5CFF');
      expect(base, const Color(0xFF7C5CFF));
      expect(HSVColor.fromColor(studyEdge(base)).value, closeTo(HSVColor.fromColor(base).value * 0.72, 0.01));
      expect(HSVColor.fromColor(studyLifted(base)).saturation, lessThan(HSVColor.fromColor(base).saturation));
      expect(studyHex('zz'), const Color(0xFF7C5CFF));
    });
  });

  group('StudyPressButton', () {
    testWidgets('calls back when enabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(StudyPressButton(key: const Key('b'), onPressed: () => taps++, child: const Text('Go'))));
      await tester.tap(find.byKey(const Key('b')));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('does nothing when disabled', (tester) async {
      await tester.pumpWidget(host(const StudyPressButton(key: Key('b'), onPressed: null, child: Text('Go'))));
      await tester.tap(find.byKey(const Key('b')));
      await tester.pump();
      expect(tester.getSemantics(find.byKey(const Key('b'))).flagsCollection.isEnabled.toString(), isNot(contains('true')));
    });

    testWidgets('sinks by its depth while pressed', (tester) async {
      await tester.pumpWidget(
        host(
          StudyPressButton(
            depth: 5,
            onPressed: () {},
            child: const SizedBox(key: Key('face'), width: 100, height: 40),
          ),
        ),
      );
      final face = find.byKey(const Key('face'));
      final rest = tester.getTopLeft(face).dy;
      final gesture = await tester.startGesture(tester.getCenter(face));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(face).dy, rest + 5);
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(face).dy, rest);
    });

    testWidgets('main button shows its title and icon', (tester) async {
      await tester.pumpWidget(host(StudyMainButton(title: 'Start', symbol: 'play.fill', onPressed: () {})));
      expect(find.text('Start'), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is StudyIcon && widget.symbol == 'play.fill'), findsOneWidget);
    });
  });

  group('StudyBar', () {
    double fillWidth(WidgetTester tester) => tester.getSize(find.descendant(of: find.byType(StudyBar), matching: find.byType(SizedBox)).at(2)).width;

    testWidgets('its track takes the whole width even where the parent centres it', (tester) async {
      await tester.pumpWidget(host(const SizedBox(width: 200, child: Column(children: [StudyBar(value: 0.1)]))));
      expect(tester.getSize(find.byType(StudyBar)).width, 200);
      expect(fillWidth(tester), 20);
    });

    testWidgets('clamps its value', (tester) async {
      await tester.pumpWidget(host(const SizedBox(width: 200, child: StudyBar(value: 3))));
      expect(fillWidth(tester), 200);
      await tester.pumpWidget(host(const SizedBox(width: 200, child: StudyBar(value: -2))));
      await tester.pumpAndSettle();
      expect(fillWidth(tester), 16);
    });

    testWidgets('springs to a new value and settles', (tester) async {
      await tester.pumpWidget(host(const SizedBox(width: 200, child: StudyBar(value: 0.25))));
      expect(fillWidth(tester), 50);
      await tester.pumpWidget(host(const SizedBox(width: 200, child: StudyBar(value: 0.5))));
      await tester.pump(const Duration(milliseconds: 100));
      expect(fillWidth(tester), isNot(50));
      await tester.pumpAndSettle();
      expect(fillWidth(tester), closeTo(100, 0.5));
    });
  });

  group('StudyRichText', () {
    test('splits on backticks', () {
      final pieces = StudyRichText.pieces('Write `1girl` then `solo`.');
      expect([for (final piece in pieces) piece.text], ['Write ', '1girl', ' then ', 'solo', '.']);
      expect([for (final piece in pieces) piece.code], [false, true, false, true, false]);
      expect(StudyRichText.pieces('``'), isEmpty);
    });

    testWidgets('marks prompt words monospaced, bold and primary', (tester) async {
      await tester.pumpWidget(host(const StudyRichText('Use `tag` here', size: 17)));
      final span = tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
      final children = span.children!.cast<TextSpan>();
      expect(children.length, 3);
      expect(children[1].style!.fontFamily, 'monospace');
      expect(children[1].style!.fontWeight, FontWeight.w700);
      expect(children[1].style!.fontSize, 16);
      expect(children[1].style!.color, StudyTheme.light.primary);
      expect(children[0].style!.fontWeight, FontWeight.w500);
      expect(children[0].style!.fontSize, 17);
    });
  });

  group('StudyMascot', () {
    testWidgets('draws the asset of each pose', (tester) async {
      for (final pose in StudyMascotPose.values) {
        await tester.pumpWidget(host(StudyMascot(pose: pose, lively: false)));
        final image = tester.widget<Image>(find.byType(Image));
        expect((image.image as AssetImage).assetName, 'assets/study/mascot/StudyMascot-${pose.fileName}.png');
        expect(find.byType(ShaderMask), pose.isBust ? findsOneWidget : findsNothing);
      }
      expect(StudyMascotPose.closeUp.fileName, 'close-up');
      expect(StudyMascotPose.fullBody.fileName, 'full-body');
      expect(
        {
          for (final pose in StudyMascotPose.values)
            if (!pose.isBust) pose,
        },
        {StudyMascotPose.cheer, StudyMascotPose.fullBody},
      );
    });

    testWidgets('shows a stand-in when the drawing is missing', (tester) async {
      await tester.pumpWidget(DefaultAssetBundle(bundle: _EmptyBundle(), child: host(const StudyMascot(lively: false))));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('study.mascot.standin')), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.sparkles), findsOneWidget);
    });

    testWidgets('sways while lively, and holds still with reduced motion', (tester) async {
      Offset at() => tester.getTopLeft(find.byType(Image));
      await tester.pumpWidget(host(const StudyMascot()));
      final start = at();
      await tester.pump(const Duration(milliseconds: 600));
      expect(at(), isNot(start));
      await tester.pumpWidget(host(const StudyMascot(), reduceMotion: true));
      await tester.pump(const Duration(milliseconds: 600));
      final still = at();
      await tester.pump(const Duration(milliseconds: 300));
      expect(at(), still);
    });
  });

  group('StudyGlyph', () {
    test('maps every symbol the lesson data names, and falls back', () {
      final data = jsonDecode(File('assets/study/StudyPath.json').readAsStringSync());
      final symbols = <String>{};
      void walk(Object? node) {
        if (node is Map) {
          node.forEach((key, value) {
            if (key == 'symbol' && value is String) symbols.add(value);
            walk(value);
          });
        } else if (node is List) {
          node.forEach(walk);
        }
      }

      walk(data);
      expect(symbols, isNotEmpty);
      for (final symbol in symbols) {
        expect(StudyGlyph.icon(symbol), isNot(CupertinoIcons.circle), reason: symbol);
      }
      expect(StudyGlyph.icon('no.such.symbol'), CupertinoIcons.circle);
      expect(StudyGlyph.icon('wand.and.stars'), CupertinoIcons.wand_stars);
      for (final tab in StudyTab.values) {
        expect(tab.icon, isNot(CupertinoIcons.circle), reason: tab.name);
      }
    });
  });

  group('StudyStat', () {
    testWidgets('shows and changes its number', (tester) async {
      await tester.pumpWidget(host(const StudyStat(symbol: 'flame.fill', color: Color(0xFFFF8A3D), value: '3')));
      expect(find.text('3'), findsOneWidget);
      await tester.pumpWidget(host(const StudyStat(symbol: 'flame.fill', color: Color(0xFFFF8A3D), value: '4')));
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      expect(find.text('3'), findsNothing);
    });
  });

  group('reactions', () {
    testWidgets('burst fires on trigger and settles', (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 50,
            height: 50,
            child: Stack(children: [Positioned.fill(child: StudyBurst(trigger: 0))]),
          ),
        ),
      );
      final box = tester.getSize(find.byType(Stack).first);
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 50,
            height: 50,
            child: Stack(children: [Positioned.fill(child: StudyBurst(trigger: 1))]),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Stack).first), box);
      await tester.pumpAndSettle();
    });

    testWidgets('burst with loose room takes no room', (tester) async {
      await tester.pumpWidget(host(const StudyBurst(trigger: 0, onAppear: true)));
      expect(tester.getSize(find.byKey(const Key('study.burst'))), const Size(234, 234));
      expect(tester.getSize(find.byType(LayoutBuilder).first), Size.zero);
      await tester.pumpAndSettle();
    });

    test('unit values are steady and below one', () {
      for (var index = 0; index < 50; index++) {
        final value = studyUnit(index, 3);
        expect(value, inInclusiveRange(0, 0.9999));
        expect(studyUnit(index, 3), value);
      }
    });

    testWidgets('shake moves the child when travel goes up and settles', (tester) async {
      Widget shake(double travel) => host(
        StudyShake(
          travel: travel,
          child: const SizedBox(key: Key('c'), width: 20, height: 20),
        ),
      );
      await tester.pumpWidget(shake(0));
      final rest = tester.getTopLeft(find.byKey(const Key('c')));
      await tester.pumpWidget(shake(1));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(find.byKey(const Key('c'))).dx, isNot(rest.dx));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('c'))).dx, closeTo(rest.dx, 0.001));
      await tester.pumpWidget(shake(0));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const Key('c'))).dx, closeTo(rest.dx, 0.001));
    });

    testWidgets('count counts up to its value', (tester) async {
      Widget count(double value) => host(StudyCount(value: value, from: 0, prefix: '+', suffix: ' XP'));
      await tester.pumpWidget(count(40));
      await tester.pump(const Duration(milliseconds: 100));
      final mid = RegExp(r'\d+').firstMatch(tester.widget<Text>(find.byType(Text)).data!)!.group(0)!;
      expect(int.parse(mid), inInclusiveRange(1, 39));
      await tester.pumpAndSettle();
      expect(find.text('+40 XP'), findsOneWidget);
    });

    testWidgets('pop and rise fade in after their delay and settle', (tester) async {
      Widget both(bool shown) => host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StudyPop(shown: shown, delay: 0.2, child: const Text('pop')),
            StudyRise(shown: shown, delay: 0.1, child: const Text('rise')),
          ],
        ),
      );
      double opacity(String text) => tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first).opacity;
      await tester.pumpWidget(both(false));
      expect(opacity('pop'), 0);
      await tester.pumpWidget(both(true));
      await tester.pump(const Duration(milliseconds: 150));
      expect(opacity('pop'), 0);
      expect(opacity('rise'), greaterThan(0));
      await tester.pumpAndSettle();
      expect(opacity('pop'), 1);
      expect(opacity('rise'), 1);
    });

    testWidgets('reduced motion skips pop at once', (tester) async {
      Widget pop(bool shown) => host(StudyPop(shown: shown, child: const Text('pop')), reduceMotion: true);
      await tester.pumpWidget(pop(false));
      await tester.pumpWidget(pop(true));
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    });

    testWidgets('combo banner shows its words and key', (tester) async {
      await tester.pumpWidget(host(StudyComboBanner(combo: 5)));
      expect(find.byKey(const Key('study.combo')), findsOneWidget);
      expect(find.text('5 in a row!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(const SizedBox()));
    });

    testWidgets('combo banner fits a narrow screen with large text', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        CupertinoApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(2.5)),
            child: const Center(child: StudyComboBanner(combo: 125)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(const Key('study.combo'))).width, lessThanOrEqualTo(320));
      await tester.pumpWidget(host(const SizedBox()));
    });

    test('studyWords keeps Korean words whole and leaves other languages alone', () {
      final before = L10n.language;
      addTearDown(() => L10n.language = before);
      L10n.language = 'ko';
      expect(studyWords('쉽다 어렵다'), '쉽\u2060다 어\u2060렵\u2060다');
      L10n.language = 'en';
      expect(studyWords('easy hard'), 'easy hard');
    });

    test('praise follows the run and the seed', () {
      expect(StudyPraise.line(right: true, combo: 12, seed: 0), 'Unstoppable!');
      expect(StudyPraise.line(right: true, combo: 5, seed: 0), 'On fire!');
      expect(StudyPraise.line(right: true, combo: 1, seed: 7), StudyPraise.right[7 % 5]);
      expect(StudyPraise.line(right: true, combo: 1, seed: -3), StudyPraise.right[3]);
      expect(StudyPraise.line(right: false, combo: 20, seed: 4), StudyPraise.wrong[1]);
      expect(StudyPraise.runs, {3, 5, 10, 15, 20, 30});
    });
  });

  group('StudySound', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(StudySound.channel, null);
      StudySound.isOn = true;
    });

    test('does nothing without the platform channel', () async {
      expect(() => StudySound.tap.play(), returnsNormally);
      StudySound.warm();
      StudySound.rest();
      await Future<void>.delayed(Duration.zero);
    });

    test('sends the sound to the channel only while on', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(StudySound.channel, (call) async {
        calls.add(call);
        return null;
      });
      StudySound.right.play();
      StudySound.warm();
      StudySound.rest();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((call) => call.method), ['play', 'warm', 'rest']);
      expect(calls.first.arguments, {'name': 'right'});
      expect((calls[1].arguments as Map)['names'], hasLength(12));
      calls.clear();
      StudySound.isOn = false;
      StudySound.wrong.play();
      StudySound.warm();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
    });

    test('is on by default and persists in the preferences', () {
      final preferences = MemoryPreferences();
      StudySound.attach(preferences);
      expect(StudySound.isOn, isTrue);
      StudySound.isOn = false;
      expect(preferences.boolean('study.sound'), isFalse);
      expect(StudySound.isOn, isFalse);
      StudySound.attach(MemoryPreferences({'study.sound': true}));
      expect(StudySound.isOn, isTrue);
    });
  });

  group('StudyMode', () {
    test('enter and leave', () {
      final mode = StudyMode.forTesting();
      var notified = 0;
      mode.addListener(() => notified++);
      expect(mode.active, isFalse);
      expect(mode.tab, StudyTab.path);
      mode.enter(StudyTab.lab);
      expect(mode.active, isTrue);
      expect(mode.tab, StudyTab.lab);
      mode.leave();
      expect(mode.active, isFalse);
      expect(notified, 2);
      mode.enter();
      expect(mode.tab, StudyTab.path);
    });

    test('startsActive persists and opens the next launch in learning mode', () {
      final preferences = MemoryPreferences();
      final mode = StudyMode.forTesting()..attach(preferences, fixture: false);
      expect(mode.startsActive, isFalse);
      expect(mode.active, isFalse);
      mode.startsActive = true;
      expect(preferences.boolean(StudyMode.startKey), isTrue);
      expect(StudyMode.startKey, 'study.startInMode');
      final next = StudyMode.forTesting()..attach(preferences, fixture: false);
      expect(next.startsActive, isTrue);
      expect(next.active, isTrue);
    });

    test('the fixture opens it without storing anything', () {
      final preferences = MemoryPreferences();
      final mode = StudyMode.forTesting()..attach(preferences, fixture: true);
      expect(mode.active, isTrue);
      expect(mode.startsActive, isFalse);
      expect(preferences.object(StudyMode.startKey), isNull);
    });

    HomeStage stage({Preferences? booruDefaults}) =>
        HomeStage(defaults: MemoryPreferences(), booruDefaults: booruDefaults ?? MemoryPreferences(), enabled: false);

    test('linked to the home stage, enter and leave go through it', () {
      final home = stage();
      final mode = StudyMode.forTesting()..link(home);
      var heard = 0;
      mode.addListener(() => heard++);
      expect(mode.active, isFalse);
      expect(home.studying, isFalse);

      mode.enter(StudyTab.practice);
      expect(home.studying, isTrue);
      expect(mode.active, isTrue);
      expect(mode.tab, StudyTab.practice);
      expect(heard, greaterThan(0));

      heard = 0;
      mode.leave();
      expect(home.studying, isFalse);
      expect(mode.active, isFalse);
      expect(heard, greaterThan(0));
    });

    test('linked, the two start switches are kept by the stage and only one is on', () {
      final preferences = MemoryPreferences();
      final home = stage(booruDefaults: preferences);
      final mode = StudyMode.forTesting()..link(home);
      expect(mode.startsActive, isFalse);
      expect(mode.startsInLibrary, isFalse);

      mode.startsActive = true;
      expect(home.startsLearning, isTrue);
      expect(mode.startsActive, isTrue);
      expect(preferences.boolean('study.startInMode'), isTrue);

      mode.startsInLibrary = true;
      expect(mode.startsInLibrary, isTrue);
      expect(mode.startsActive, isFalse);
      expect(home.startsInLibrary, isTrue);
      expect(home.startsLearning, isFalse);
      expect(preferences.boolean('home.startInLibrary'), isTrue);
      expect(preferences.boolean('study.startInMode'), isFalse);

      mode.startsActive = true;
      expect(mode.startsActive, isTrue);
      expect(mode.startsInLibrary, isFalse);
      expect(preferences.boolean('home.startInLibrary'), isFalse);
      expect(preferences.boolean('study.startInMode'), isTrue);

      mode.startsActive = false;
      expect(mode.startsActive, isFalse);
      expect(preferences.boolean('study.startInMode'), isFalse);
    });

    test('a change made on the stage reaches the mode and its listeners', () {
      final home = stage();
      final mode = StudyMode.forTesting()..link(home);
      var heard = 0;
      mode.addListener(() => heard++);

      home.startsLearning = true;
      expect(mode.startsActive, isTrue);
      expect(heard, 1);

      home.startsInLibrary = true;
      expect(mode.startsInLibrary, isTrue);
      expect(mode.startsActive, isFalse);

      heard = 0;
      home.enterStudy();
      expect(mode.active, isTrue);
      expect(heard, 1);
      home.leaveStudy();
      expect(mode.active, isFalse);
      expect(heard, 2);
    });

    test('linking takes the stage\'s state, and a run launched into the mode takes the stage along', () {
      final starts = StudyMode.forTesting()..link(stage(booruDefaults: MemoryPreferences({'study.startInMode': true})));
      expect(starts.startsActive, isTrue);
      expect(starts.active, isTrue, reason: 'A stage that starts in learning mode is studying');

      final home = stage();
      final launched = StudyMode.forTesting()..attach(MemoryPreferences(), fixture: true);
      expect(launched.active, isTrue);
      launched.link(home);
      expect(home.studying, isTrue);
      expect(launched.active, isTrue);
    });

    test('linked to another stage, the first one is no longer followed', () {
      final first = stage(), second = stage();
      final mode = StudyMode.forTesting()
        ..link(first)
        ..link(second);
      first.enterStudy();
      expect(mode.active, isFalse);
      second.enterStudy();
      expect(mode.active, isTrue);
    });

    test('unlinked, the mode keeps its own switches and opens and closes alone', () {
      final preferences = MemoryPreferences();
      final mode = StudyMode.forTesting()..attach(preferences, fixture: false);
      var heard = 0;
      mode.addListener(() => heard++);
      mode.startsInLibrary = true;
      expect(mode.startsInLibrary, isTrue);
      expect(preferences.boolean('home.startInLibrary'), isTrue);
      mode.startsActive = true;
      expect(mode.startsActive, isTrue);
      expect(mode.startsInLibrary, isFalse);
      expect(preferences.boolean('home.startInLibrary'), isFalse);
      expect(preferences.boolean('study.startInMode'), isTrue);
      mode.startsInLibrary = true;
      expect(mode.startsActive, isFalse);
      expect(preferences.boolean('study.startInMode'), isFalse);
      expect(heard, 3);

      final next = StudyMode.forTesting()..attach(preferences, fixture: false);
      expect(next.startsInLibrary, isTrue);
      expect(next.active, isFalse);
      next.enter();
      expect(next.active, isTrue);
      next.leave();
      expect(next.active, isFalse);
    });

    test('tabs have titles and symbols', () {
      // The collection moved onto Me; the fourth tab leads back to the AI lab.
      expect([for (final tab in StudyTab.values) tab.title], ['Map', 'Practice', 'Studio', 'lab.title.short', 'Me']);
      expect(StudyTab.pages, isNot(contains(StudyTab.aiLab)));
    });
  });
}

class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => Future<ByteData>.error(FlutterError('no asset $key'));
}
