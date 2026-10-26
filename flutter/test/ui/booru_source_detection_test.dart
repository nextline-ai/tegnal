import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/booru_source_detector.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';

class _FixtureDetector extends BooruSourceDetector {
  _FixtureDetector(this.results);

  final List<Object?> results;
  var calls = 0;

  @override
  Future<SourceKind?> detect(
    Uri origin, {
    Future<void>? abortTrigger,
    bool allowComics = false,
  }) async {
    calls++;
    final result = results.removeAt(0);
    if (result case final Exception error) throw error;
    return result as SourceKind?;
  }
}

void main() {
  late LibraryStore store;
  late AppController controller;
  Future<SourceConfig?>? result;

  setUp(() {
    store = LibraryStore.memory();
    store.setSetting('language', 'en');
    controller = AppController(store);
    controller.setMode(AppMode.booru);
    result = null;
  });

  tearDown(() {
    controller.dispose();
    store.close();
  });

  Future<void> openForm(
    WidgetTester tester,
    BooruSourceDetector detector, {
    bool autoDetectMode = false,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                result = showAddSource(
                  context,
                  controller,
                  mode: AppMode.booru,
                  detector: detector,
                  autoDetectMode: autoDetectMode,
                );
              },
              child: const Text('Connect'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  testWidgets('known native host suggestions save automatically', (
    tester,
  ) async {
    final detector = _FixtureDetector([]);
    await openForm(tester, detector);
    await tester.enterText(
      find.byType(TextField).first,
      'https://danbooru.donmai.us',
    );
    await tester.pumpAndSettle();

    expect(find.text('Image Mode · Danbooru'), findsOneWidget);
    expect(detector.calls, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(controller.sources(AppMode.booru).single.kind, SourceKind.danbooru);
    expect(controller.sources(AppMode.manga), isEmpty);
  });

  testWidgets('unknown custom site offers manual engines and saves selection', (
    tester,
  ) async {
    final detector = _FixtureDetector([null]);
    await openForm(tester, detector);
    await tester.enterText(
      find.byType(TextField).first,
      'https://custom.example',
    );
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Couldn’t identify this website'),
      findsOneWidget,
    );
    expect(find.widgetWithText(ChoiceChip, 'Moebooru'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Moebooru'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(controller.sources(AppMode.booru).single.kind, SourceKind.moebooru);
    expect(detector.calls, 1);
  });

  testWidgets('failed detection can retry and chooses returned engine', (
    tester,
  ) async {
    final detector = _FixtureDetector([
      const SocketException('simulated connection failure'),
      SourceKind.gelbooru,
    ]);
    await openForm(tester, detector);
    await tester.enterText(
      find.byType(TextField).first,
      'https://custom.example',
    );
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pumpAndSettle();
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Danbooru'), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('Image Mode · Gelbooru'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(controller.sources(AppMode.booru).single.kind, SourceKind.gelbooru);
    expect(detector.calls, 2);
  });

  testWidgets('onboarding auto-detection can return a comics source', (
    tester,
  ) async {
    final detector = _FixtureDetector([SourceKind.manga]);
    await openForm(tester, detector, autoDetectMode: true);
    await tester.enterText(
      find.byType(TextField).first,
      'https://catalog.example',
    );
    await tester.pump(const Duration(milliseconds: 401));
    await tester.pumpAndSettle();

    expect(find.text('Comics Mode'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final source = await result;
    expect(source?.kind, SourceKind.manga);
    expect(source?.mode, AppMode.manga);
    expect(controller.sources(AppMode.booru), isEmpty);
    expect(controller.sources(AppMode.manga), hasLength(1));
    expect(detector.calls, 1);
  });
}
