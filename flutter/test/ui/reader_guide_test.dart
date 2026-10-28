import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/reader_guide.dart';
import 'package:tegnal/features/settings_screen.dart';
import 'package:tegnal/ui/design_system.dart';

void main() {
  late LibraryStore store;
  late AppController controller;
  setUp(() {
    store = LibraryStore.memory();
    controller = AppController(store);
  });
  tearDown(() {
    controller.dispose();
    store.close();
  });

  Future<void> show(
    WidgetTester tester, {
    double scale = 1,
    bool settings = false,
  }) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      tester.view.reset();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: settings
            ? ReaderDefaultsScreen(controller: controller, mode: AppMode.manga)
            : ReaderGuideScreen(controller: controller, mode: AppMode.manga),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'three illustrated lessons support forward, backward, and direct step selection',
    (tester) async {
      await show(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Read with Taps'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('Zoom and Translate'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-guide-next')));
      await tester.pumpAndSettle();
      expect(find.text('Exit the Work'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-guide-previous')));
      await tester.pumpAndSettle();
      expect(find.text('Zoom and Translate'), findsOneWidget);
      await tester.tap(find.text('Taps'));
      await tester.pumpAndSettle();
      expect(find.text('Read with Taps'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'right-to-left taps and zoom demonstrate the actual reader gestures',
    (tester) async {
      controller.setReaderPreferences(
        AppMode.manga,
        const ReaderPreferences(rightToLeft: true),
      );
      await show(tester);
      final demo = tester.getRect(
        find.byKey(const ValueKey('reader-guide-demo')),
      );
      await tester.tapAt(Offset(demo.left + demo.width * .12, demo.center.dy));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('reader-guide-feedback')))
            .data,
        'Next',
      );
      await tester.tap(find.text('Zoom & Translate'));
      await tester.pumpAndSettle();
      final center = tester.getCenter(
        find.byKey(const ValueKey('reader-guide-demo')),
      );
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        greaterThan(1),
      );
    },
  );

  testWidgets('continuous exit demonstration requires the top handle', (
    tester,
  ) async {
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(readingMode: ReadingMode.continuous),
    );
    await show(tester);
    await tester.tap(find.text('Exit'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'In Continuous Scroll, drag down from the top handle to close. Dragging the pages only scrolls.',
      ),
      findsOneWidget,
    );
    final bounds = tester.getRect(
      find.byKey(const ValueKey('reader-guide-demo')),
    );
    await tester.dragFrom(bounds.center, const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('reader-guide-feedback')))
          .data,
      'Dragging the pages only scrolls.',
    );
    await tester.dragFrom(
      Offset(bounds.center.dx, bounds.top + 8),
      const Offset(0, 90),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('reader-guide-feedback')))
          .data,
      'Done',
    );
    expect(find.byType(ReaderGuideScreen), findsOneWidget);
  });

  testWidgets(
    'hide persists and Settings can always reopen the complete guide',
    (tester) async {
      await show(tester, settings: true);
      final guide = find.text('Reader Guide');
      await tester.scrollUntilVisible(
        guide,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(guide);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-guide-never')));
      await tester.pumpAndSettle();
      expect(store.setting('reader.helpHidden'), isTrue);
      expect(find.byType(ReaderGuideScreen), findsNothing);
      await tester.tap(guide);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderGuideScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-guide-close')));
      await tester.pumpAndSettle();
      expect(store.setting('reader.helpHidden'), isTrue);
    },
  );

  testWidgets(
    '320-pixel large-text layout keeps navigation and dismissal visible',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      await show(tester, scale: 2);
      for (var step = 0; step < 3; step++) {
        expect(
          find.byKey(const ValueKey('reader-guide-never')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-guide-next')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('reader-guide-close')).hitTestable(),
          findsOneWidget,
        );
        final description = find.text(
          const [
            'Tap either side to turn pages. Tap the center for the quick menu, or hold anywhere to bookmark.',
            'Double tap or pinch to zoom. Drag to position the area you want, then choose Translate in the quick menu.',
            'At the original zoom level, swipe down to exit. While zoomed, dragging only moves the image. You can also exit from the quick menu.',
          ][step],
        );
        await tester.scrollUntilVisible(
          description,
          160,
          scrollable: find.byType(Scrollable).first,
        );
        final viewport = tester.getRect(
          find.byType(SingleChildScrollView).first,
        );
        expect(tester.getRect(description).overlaps(viewport), isTrue);
        await Scrollable.ensureVisible(
          tester.element(description),
          alignment: 1,
        );
        await tester.pump();
        expect(
          tester.getRect(description).bottom,
          lessThanOrEqualTo(viewport.bottom + 1),
        );
        expect(
          find.byKey(const ValueKey('reader-guide-never')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (step < 2) {
          await tester.tap(find.byKey(const ValueKey('reader-guide-next')));
          await tester.pumpAndSettle();
        }
      }
    },
  );
}
