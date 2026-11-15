import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/cover_queue.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/settings/cover_fill_warning.dart';

void main() {
  testWidgets('the warning offers another website, filling slowly, or later', (tester) async {
    final decisions = MemoryPreferences();
    final root = Directory.systemTemp.createTempSync('bulk-fill-warning');
    addTearDown(() => root.deleteSync(recursive: true));
    final queue = CoverQueue.withActor(
      CoverQueueActor(database: AppDatabase.inMemory(), thumbsDir: root, source: FixtureContentSource(), allowsBackfill: () => false),
      allowsBackfill: () => false,
      sites: () => ['keyed.example'],
      blocksBulkReading: (_) => true,
      decisions: decisions,
    );
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox.expand();
          },
        ),
      ),
    );

    var added = 0;
    Future<void> show() => showCoverFillSiteWarning(context, queue: queue, pending: 20, sites: ['keyed.example'], addWebsite: () async => added += 1);

    show();
    await tester.pumpAndSettle();
    expect(find.text('Add Another Website First?'), findsOneWidget);
    expect(find.textContaining('keyed.example'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(CoverFillGuard.decision(decisions).$1, CoverFillDecision.declined);

    show();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fill Slowly Anyway'));
    await tester.pumpAndSettle();
    expect(CoverFillGuard.decision(decisions).$1, CoverFillDecision.approved);

    show();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Website'));
    await tester.pumpAndSettle();
    expect(added, 1);
    expect(CoverFillGuard.decision(decisions).$1, CoverFillDecision.declined, reason: 'Closing the editor without a new website does not fill');

    expect(sitesBlockingBulkReading(['keyed.example'], blocks: (_) => true), 'keyed.example');
    expect(sitesBlockingBulkReading(['keyed.example', 'b.example'], blocks: (site) => site == 'keyed.example'), isNull);
    expect(sitesBlockingBulkReading([]), isNull);
  });
}
