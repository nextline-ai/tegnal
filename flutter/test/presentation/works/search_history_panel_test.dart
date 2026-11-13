// The search overlay's Clear History confirmation, as testExploreSearchHistoryClearConfirmationStaysOpen
// checks it natively: the dialog takes focus from the search field, which closes the panel, and the
// dialog must stay until it is answered.
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/works/search_controls.dart';

void main() {
  testWidgets('clear confirmation outlives the panel that opened it', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var history = ['female:sample'];
    var cleared = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            focus.addListener(() => setState(() {}));
            return CupertinoPageScaffold(
              child: Column(
                children: [
                  CupertinoTextField(focusNode: focus),
                  if (focus.hasFocus)
                    SizedBox(
                      height: 400,
                      child: SearchHistoryPanel(
                        history: history,
                        saved: const [],
                        open: (_) {},
                        star: (_) {},
                        remove: (_) {},
                        clear: () => setState(() {
                          cleared += 1;
                          history = [];
                        }),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(CupertinoTextField));
    await tester.pumpAndSettle();
    expect(find.text('female:sample'), findsOneWidget);
    await tester.tap(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Clear History'));
    await tester.pumpAndSettle();
    expect(find.text('Clear History?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Clear History?'), findsOneWidget, reason: 'The confirmation must not close by itself');
    await tester.tap(find.text('Clear History'));
    await tester.pumpAndSettle();
    expect(find.text('Clear History?'), findsNothing);
    expect(cleared, 1);
  });
}
