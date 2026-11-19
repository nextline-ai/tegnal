import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/settings/start_choice_view.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';

void main() {
  late MemoryPreferences preferences;
  late StudyMode mode;

  Future<void> open(WidgetTester tester) async {
    preferences = MemoryPreferences();
    mode = StudyMode.forTesting();
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => StartChoiceView(preferences: preferences, mode: mode))),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester) => tester.getSemantics(find.byKey(const ValueKey('onboarding.continue'))).flagsCollection.isEnabled.name == 'isTrue';

  testWidgets('the button is disabled until a card is chosen', (tester) async {
    await open(tester);
    expect(find.text('Choose How to Start'), findsOneWidget);
    expect(find.byKey(const ValueKey('onboarding.mode')), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(enabled(tester), isFalse);
    await tester.tap(find.byKey(const ValueKey('onboarding.continue')), warnIfMissed: false);
    await tester.pump();
    expect(find.byType(StartChoiceView), findsOneWidget);
    expect(preferences.boolean(startChoiceMadeKey), isNull);
  });

  testWidgets('Viewing Mode and Continue save the choice without entering learning mode', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding.mode.viewing')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Continue'), findsOneWidget);
    expect(enabled(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('onboarding.continue')));
    await tester.pumpAndSettle();
    expect(mode.startsActive, isFalse);
    expect(mode.active, isFalse);
    expect(preferences.boolean(startChoiceMadeKey), isTrue);
    expect(find.byType(StartChoiceView), findsNothing);
  });

  testWidgets('Learning Mode shows Start Learning, saves the choice and enters learning mode', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('onboarding.mode.learning')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Start Learning'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('onboarding.continue')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(mode.startsActive, isTrue);
    expect(mode.active, isTrue);
    expect(preferences.boolean(startChoiceMadeKey), isTrue);
    expect(find.byType(StartChoiceView), findsNothing);
  });

  testWidgets('the chosen card is selected and the other is not', (tester) async {
    await open(tester);
    bool selected(String key) => tester.getSemantics(find.byKey(ValueKey(key))).flagsCollection.isSelected.name == 'isTrue';
    expect(selected('onboarding.mode.learning'), isFalse);
    expect(selected('onboarding.mode.viewing'), isFalse);
    await tester.tap(find.byKey(const ValueKey('onboarding.mode.viewing')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected('onboarding.mode.viewing'), isTrue);
    expect(selected('onboarding.mode.learning'), isFalse);
    await tester.tap(find.byKey(const ValueKey('onboarding.mode.learning')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected('onboarding.mode.learning'), isTrue);
    expect(selected('onboarding.mode.viewing'), isFalse);
  });
}
