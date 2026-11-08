// A thumbnail with both a tap and a double tap: two quick taps are the double tap alone.

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/content/reading_queue_views.dart';

void main() {
  testWidgets('two quick taps run the double tap and not the tap', (tester) async {
    final taps = <String>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: WorkHold(
            onTap: () => taps.add('tap'),
            onDoubleTap: () => taps.add('double'),
            bookmark: () => taps.add('hold'),
            child: const SizedBox(width: 120, height: 160),
          ),
        ),
      ),
    );
    final card = find.byType(WorkHold);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(card);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(taps, ['double']);

    taps.clear();
    await tester.tap(card);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(taps, ['tap'], reason: 'A lone tap still acts once the double tap gives up');
  });
}
