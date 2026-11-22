import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/content/reading_queue_views.dart';
import 'package:tegnal/presentation/navigation/app_state.dart';
import 'package:tegnal/presentation/navigation/root_tab_view.dart';

void main() {
  late Directory covers;
  setUp(() => covers = Directory.systemTemp.createTempSync('root-tabs'));
  tearDown(() {
    if (covers.existsSync()) covers.deleteSync(recursive: true);
  });

  testWidgets('Up Next steps aside in Settings and leaves its rows their room', (tester) async {
    final queue = ReadingQueue(MemoryPreferences(), covers: covers)..add(const ReadingQueueItem(id: 1, title: 'Work 1', artists: '', details: ''));
    final state = AppState();
    final insets = <AppTab, double>{};
    Widget page(AppTab tab) => Builder(
      builder: (context) {
        insets[tab] = ReadingQueueInset.of(context);
        return const SizedBox.expand();
      },
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: RootTabView(state: state, queue: queue, pages: {for (final tab in AppTab.values) tab: page(tab)}),
      ),
    );
    await tester.pumpAndSettle();
    double opacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: find.byType(ReadingQueueBar), matching: find.byType(AnimatedOpacity)).first).opacity;
    expect(opacity(), 1, reason: 'The bar shows in the library');
    expect(insets[AppTab.folders], greaterThan(0));
    expect(insets[AppTab.settings], 0, reason: 'Settings rows are not held clear of a bar that is not there');

    state.tab = AppTab.settings;
    await tester.pumpAndSettle();
    expect(opacity(), 0, reason: 'The bar does not cover Settings');
    expect(tester.widget<IgnorePointer>(find.ancestor(of: find.byType(ReadingQueueBar), matching: find.byType(IgnorePointer)).first).ignoring, isTrue);

    state.tab = AppTab.works;
    await tester.pumpAndSettle();
    expect(opacity(), 1, reason: 'It comes back on the other tabs');
  });
}
