import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_drive_sync.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/settings/drive_suggestion.dart';

import '../../core/sync/library_drive_sync_test.dart' show FakeBackend, FakeDrive;

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('drive-suggestion-');
    DriveSuggestionGate.askedThisLaunch = false;
  });
  tearDown(() => root.deleteSync(recursive: true));

  LibraryDriveSync sync(AppPreferences preferences) => LibraryDriveSync(
    backend: FakeBackend(FakeDrive()),
    database: AppDatabase.inMemory(preferences: preferences),
    booru: BooruStore.inMemory(preferences: preferences),
    defaults: preferences.defaults,
    booruDefaults: preferences.booruDefaults,
    directory: root,
  );

  Future<void> pump(WidgetTester tester, LibraryDriveSync drive, {bool onboarded = true}) async {
    final content = ContentEnvironment(browserPreferences: MemoryPreferences())..isOnboardingCompleted = onboarded;
    await tester.pumpWidget(
      CupertinoApp(
        theme: tegnalTheme(Brightness.light),
        home: DriveSuggestionGate(
          sync: drive,
          content: content,
          child: const CupertinoPageScaffold(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an earlier install is asked once to connect Google Drive', (tester) async {
    final preferences = AppPreferences.memory();
    final drive = sync(preferences);
    await pump(tester, drive);
    expect(find.text('Keep Your Library in Google Drive'), findsOneWidget);
    expect(DriveSuggestionGate.askedThisLaunch, isTrue, reason: 'Other launch prompts wait for the next launch');
    await tester.tap(find.text('Not Now'));
    await tester.pumpAndSettle();
    expect(drive.account, isNull);

    await tester.pumpWidget(const SizedBox());
    await pump(tester, sync(preferences));
    expect(find.text('Keep Your Library in Google Drive'), findsNothing, reason: 'Asked only once');
  });

  testWidgets('connecting from the suggestion turns sync on', (tester) async {
    final drive = sync(AppPreferences.memory());
    await pump(tester, drive);
    await tester.runAsync(() async {
      await tester.tap(find.text('Connect'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(drive.account?.email, 'person@example.com');
    expect(drive.enabled, isTrue);
  });

  testWidgets('a first run waits for onboarding, and a connected install is never asked', (tester) async {
    final preferences = AppPreferences.memory();
    final drive = sync(preferences);
    await pump(tester, drive, onboarded: false);
    expect(find.text('Keep Your Library in Google Drive'), findsNothing);

    await tester.runAsync(drive.connect);
    await tester.pumpWidget(const SizedBox());
    await pump(tester, drive);
    expect(find.text('Keep Your Library in Google Drive'), findsNothing);
  });
}
