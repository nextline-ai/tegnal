import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/sync/library_drive_sync.dart';
import 'package:tegnal/presentation/design/tegnal_theme.dart';
import 'package:tegnal/presentation/imports/import_views.dart';
import 'package:tegnal/presentation/navigation/app_header.dart';
import 'package:tegnal/presentation/navigation/app_state.dart';
import 'package:tegnal/presentation/onboarding/onboarding_view.dart';

import '../../core/sync/library_drive_sync_test.dart' show FakeBackend, FakeDrive;
import '../study/study_test_support.dart';

Finder key(String name) => find.byKey(Key(name));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ContentEnvironment, AppState)> open(WidgetTester tester, {bool completed = false, bool verified = false, LibraryDriveSync? drive}) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final harness = StudyHarness();
    // No image server yet, as on a first run.
    harness.store.deleteServer(harness.server);
    final preferences = MemoryPreferences();
    final content = ContentEnvironment.fixture(preferences: preferences);
    if (!verified) preferences.set('site_verified', false);
    final fresh = ContentEnvironment(browserPreferences: preferences);
    (verified ? content : fresh).isOnboardingCompleted = completed;
    final state = AppState();
    final imports = ImportContext(
      booru: harness.booru,
      database: AppDatabase.inMemory(preferences: AppPreferences.memory()),
    );
    await tester.pumpWidget(
      CupertinoApp(
        theme: tegnalTheme(Brightness.light),
        home: Builder(
          builder: (context) => CupertinoButton(
            key: const Key('open'),
            onPressed: () => OnboardingView.show(context, content: verified ? content : fresh, imports: imports, state: state, drive: drive),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle();
    return (verified ? content : fresh, state);
  }

  testWidgets('the first run walks website, imports and the mode switch, then is done for good', (tester) async {
    final (content, state) = await open(tester);
    expect(find.text('Connect a Website'), findsOneWidget);
    expect(key('onboarding.addServer'), findsOneWidget);
    expect(key('onboarding.privacy'), findsOneWidget);
    expect(find.text('Set Up Later'), findsOneWidget, reason: 'With nothing connected the way on says it can wait');
    expect(find.text('Done'), findsNothing, reason: 'A first run cannot be left before its end');
    expect(find.text('Choose How to Start'), findsNothing, reason: 'There is no starting-mode step');

    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    expect(key('onboarding.import'), findsOneWidget);
    expect(key('onboarding.mangaViewerImport'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    expect(key('onboarding.tutorial'), findsOneWidget);
    expect(find.text('Image Mode'), findsWidgets);
    expect(find.text('Get Started'), findsOneWidget);
    // The tutorial's switch only shows the modes; it leaves the app's own mode alone.
    await tester.tap(find.byType(AppModeSwitch));
    await tester.pumpAndSettle();
    expect(find.text('Comics Mode'), findsWidgets);
    expect(state.mode, AppMode.manga);

    await tester.tap(key('onboarding.back'));
    await tester.pumpAndSettle();
    expect(key('onboarding.import'), findsOneWidget, reason: 'Back steps back a page');
    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    expect(key('onboarding.tutorial'), findsNothing);
    expect(content.isOnboardingCompleted, isTrue);
  });

  testWidgets('reopened from Settings it offers Done at once and shows the connected website', (tester) async {
    await open(tester, completed: true, verified: true);
    expect(find.text('Done'), findsOneWidget);
    expect(key('onboarding.comicsConnected'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget, reason: 'A connected website needs no setting up later');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Connect a Website'), findsNothing);
  });

  testWidgets('with Google Drive set up, a page after the website signs in, and it counts as the suggestion', (tester) async {
    final root = Directory.systemTemp.createTempSync('onboarding-drive-');
    addTearDown(() => root.deleteSync(recursive: true));
    final preferences = AppPreferences.memory();
    final drive = LibraryDriveSync(
      backend: FakeBackend(FakeDrive()),
      database: AppDatabase.inMemory(preferences: preferences),
      booru: BooruStore.inMemory(preferences: preferences),
      defaults: preferences.defaults,
      booruDefaults: preferences.booruDefaults,
      directory: root,
    );
    expect(drive.shouldSuggest, isTrue);
    await open(tester, drive: drive);
    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    expect(key('onboarding.drive'), findsOneWidget);
    expect(key('drive.invitation.storage'), findsOneWidget);
    expect(key('drive.invitation.footprint'), findsNothing, reason: 'A first run has no library to count yet');
    expect(find.text('Connect Google Drive'), findsOneWidget, reason: 'Connecting is the main button');
    expect(key('drive.invitation.skip'), findsOneWidget, reason: 'Going on without it is a quiet line');
    expect(drive.shouldSuggest, isFalse, reason: 'Seeing the page is the suggestion; no prompt follows later');

    await tester.runAsync(() async {
      await tester.tap(key('drive.invitation.primary'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(key('drive.invitation.connected'), findsOneWidget);
    expect(find.text('Connected as person@example.com'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(drive.enabled, isTrue);

    await tester.tap(key('onboarding.continue'));
    await tester.pumpAndSettle();
    expect(key('onboarding.import'), findsOneWidget);
  });
}
