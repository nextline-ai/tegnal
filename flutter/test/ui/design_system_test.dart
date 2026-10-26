import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/ui/design_system.dart';

void main() {
  test(
    'shared Material themes use bundled typography and Expressive controls',
    () {
      for (final brightness in Brightness.values) {
        final theme = tegnalTheme(brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.brightness, brightness);
        expect(theme.iconButtonTheme.variant, StyleVariant.material3Expressive);
        for (final style in [
          theme.textTheme.bodyMedium,
          theme.textTheme.titleLarge,
          theme.textTheme.labelLarge,
        ]) {
          expect(style!.fontFamily, 'Pretendard');
          expect(style.fontFamilyFallback, contains('Pretendard JP'));
        }
      }
      expect(
        tegnalTheme(Brightness.dark).scaffoldBackgroundColor,
        Colors.black,
      );
    },
  );

  testWidgets('switch toggles by touch, drag, and keyboard', (tester) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: TegnalSwitch(
                value: value,
                semanticLabel: 'Reading direction',
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        ),
      ),
    );
    final control = find.byType(TegnalSwitch);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(
      tester.getSemantics(control),
      matchesSemantics(
        label: 'Reading direction',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.drag(control, const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(value, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, isTrue);
  });

  testWidgets('disabled switch ignores interaction and exposes state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: TegnalSwitch(value: true, onChanged: null)),
        ),
      ),
    );
    final control = find.byType(TegnalSwitch);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(control),
      matchesSemantics(
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
      ),
    );
  });
}
