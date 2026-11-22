import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/backup/automatic_backups.dart';
import 'package:tegnal/core/backup/update_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/presentation/settings/automatic_backups_view.dart';

import '../../core/backup/backup_test_support.dart';

/// The backup engine does real file work, which the test clock does not wait for: give it real time.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 100 && !done(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  expect(done(), isTrue);
}

/// A library with one backup from before an update (data from 1.5.1, made by 1.6.0).
Future<({AutomaticBackups model, BackupFixture fixture, (AppDatabase, BooruStore) library})> _seeded(WidgetTester tester) async {
  final fixture = BackupFixture(addTearDown);
  late final (AppDatabase, BooruStore) library;
  late final AutomaticBackups model;
  await tester.runAsync(() async {
    fixture.makeLibrary([1]);
    fixture.store.values[UpdateBackup.lastVersionKey] = '1.5.1';
    fixture.store.values[UpdateBackup.lastBuildKey] = '44';
    await UpdateBackup.runAtLaunch(fixture.setup);
    library = fixture.openLibrary();
    model = AutomaticBackups(setup: fixture.setup, databases: () => fixture.openDatabases(library));
    await model.afterLaunch();
  });
  addTearDown(() => fixture.closeLibrary(library));
  expect(model.items, hasLength(1));
  return (model: model, fixture: fixture, library: library);
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.bySemanticsIdentifier('backups.menu').first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the list shows each backup with its data version, the always-kept mark and the total size', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: model, hasDrive: false)));
    await _until(tester, () => !model.isWorking);

    final item = model.items.single;
    expect(find.text('Automatic Backups'), findsOneWidget);
    expect(find.textContaining('Before the update to 1.6.0 · '), findsOneWidget, reason: 'With how long ago it was made');
    expect(find.text('Data from 1.5.1 · ${AutomaticBackupText.size(item.size)}'), findsOneWidget);
    expect(find.text('Always kept'), findsOneWidget);
    expect(find.text('${AutomaticBackupText.size(item.size)} of 100 MB'), findsOneWidget);
    expect(find.text('From another device'), findsNothing, reason: 'This device made it');
    expect(find.text('Keep in Google Drive'), findsNothing, reason: 'No Drive sync in this app: no switch and no footer');
    expect(find.textContaining('Google Drive'), findsNothing);
  });

  testWidgets('with Drive but no sign-in the switch is disabled and the footer says why', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: seeded.model, hasDrive: true)));
    await _until(tester, () => !seeded.model.isWorking);
    expect(find.text('Keep in Google Drive'), findsOneWidget);
    expect(find.text('Google Drive is not available. Backups stay on this device until it is.'), findsOneWidget);
    // A tap on a disabled switch changes nothing.
    await tester.tap(find.bySemanticsIdentifier('backups.keepInDrive'));
    await tester.pumpAndSettle();
    expect(seeded.model.keepInDrive, isTrue);
  });

  testWidgets('Back Up Now adds a row', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: model, hasDrive: false)));
    await _until(tester, () => !model.isWorking);
    expect(find.textContaining('Manual backup'), findsNothing);

    await tester.tap(find.text('Back Up Now'));
    await _until(tester, () => model.items.length == 2 && !model.isWorking);
    expect(find.text('Manual backup · 0 seconds ago'), findsOneWidget);
    expect(find.text('Always kept'), findsNWidgets(2), reason: 'The newest backup of each kind is kept');
  });

  testWidgets('Restore asks first, says it is not merged, and cancelling changes nothing', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: model, hasDrive: false)));
    await _until(tester, () => !model.isWorking);

    await _openMenu(tester);
    expect(find.text('Export to File'), findsOneWidget);
    expect(find.text('Delete…'), findsOneWidget);
    await tester.tap(find.text('Restore…'));
    await tester.pumpAndSettle();
    expect(find.text('Restore This Backup?'), findsOneWidget);
    expect(find.textContaining('It is not merged with what you have now.'), findsOneWidget);
    expect(find.textContaining('TEGNAL has to be closed and opened again to finish.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Restore This Backup?'), findsNothing);
    expect(model.pendingRestore, isNull);
    expect(model.items, hasLength(1), reason: 'No safety backup was made');
  });

  testWidgets('deleting an always-kept backup warns more strongly, and deletes only when confirmed', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: model, hasDrive: false)));
    await _until(tester, () => !model.isWorking);
    expect(model.items.single.isProtected, isTrue);

    await _openMenu(tester);
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete an Always-Kept Backup?'), findsOneWidget);
    expect(find.textContaining('you can no longer go back to this version of your data'), findsOneWidget);
    expect(find.text('Delete Anyway'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(model.items, hasLength(1));

    await _openMenu(tester);
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Anyway'));
    await _until(tester, () => model.items.isEmpty && !model.isWorking);
    expect(find.text('No backups yet. One is made automatically every 3 days and before each update.'), findsOneWidget);
  });

  testWidgets('a failed update backup is shown with its date and version and can be dismissed', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    await tester.runAsync(() async {
      await UpdateBackup.recordFailure(seeded.fixture.setup, 'it failed');
      await model.refresh();
    });
    await tester.pumpWidget(CupertinoApp(home: AutomaticBackupsView(backups: model, hasDrive: false)));
    await _until(tester, () => !model.isWorking);
    expect(find.textContaining('A backup could not be completed on'), findsOneWidget);
    expect(find.textContaining('(TEGNAL 1.6.0)'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await _until(tester, () => model.lastFailure == null);
    expect(find.textContaining('A backup could not be completed on'), findsNothing);
  });

  testWidgets('a pending restore covers the app, cannot be backed out of, and Cancel Restore removes it', (tester) async {
    _phone(tester);
    final seeded = await _seeded(tester);
    final model = seeded.model;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      CupertinoApp(
        navigatorKey: navigator,
        builder: (context, child) => PendingRestoreGate(backups: model, navigatorKey: navigator, child: child!),
        home: AutomaticBackupsView(backups: model, hasDrive: false),
      ),
    );
    await _until(tester, () => !model.isWorking);
    expect(find.text('Restore Is Ready'), findsNothing);

    await _openMenu(tester);
    await tester.tap(find.text('Restore…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await _until(tester, () => model.pendingRestore != null && !model.isWorking);

    expect(find.text('Restore Is Ready'), findsOneWidget);
    expect(find.text('Data from 1.5.1'), findsOneWidget);
    expect(find.text('Close TEGNAL completely, then open it again. The restore finishes while it starts.'), findsOneWidget);
    expect(find.text('Cancel Restore'), findsOneWidget);

    // The back button and gesture do nothing.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Restore Is Ready'), findsOneWidget);

    await tester.tap(find.text('Cancel Restore'));
    await tester.pumpAndSettle();
    expect(model.pendingRestore, isNull);
    expect(find.text('Restore Is Ready'), findsNothing);
    expect(find.text('Automatic Backups'), findsOneWidget);
  });
}
