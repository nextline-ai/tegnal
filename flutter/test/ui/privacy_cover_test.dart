import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/privacy_cover.dart';

void main() {
  testWidgets('paused cover blocks input and hides underlying semantics', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: TegnalPrivacyCover(
          child: Center(
            child: GestureDetector(
              onTap: () => taps++,
              child: const Text('Sensitive reader'),
            ),
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    expect(find.semantics.byLabel('Sensitive reader'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.semantics.byLabel('TEGNAL'), findsOneWidget);
    expect(find.semantics.byLabel('Sensitive reader'), findsNothing);
    await tester.tapAt(tester.getCenter(find.text('Sensitive reader')));
    expect(taps, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.byType(Image), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 899));
    expect(find.byType(Image), findsOneWidget);
    // The timer starts the ticker on a frame boundary; include one frame after
    // the nominal duration for the completed status callback to rebuild.
    await tester.pump(const Duration(milliseconds: 17));
    expect(find.byType(Image), findsNothing);
    expect(find.semantics.byLabel('Sensitive reader'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('inactive waits briefly and soft keyboard focus does not flash', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 280)),
          child: TegnalPrivacyCover(child: const Text('Search field')),
        ),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 180));
    expect(find.byType(Image), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: TegnalPrivacyCover(child: const Text('Reader')),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 119));
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(Image), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('inactive rechecks keyboard insets before showing the cover', (
    tester,
  ) async {
    Widget app(EdgeInsets viewInsets) => MaterialApp(
      theme: tegnalTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(viewInsets: viewInsets),
        child: TegnalPrivacyCover(child: const Text('Search field')),
      ),
    );

    await tester.pumpWidget(app(EdgeInsets.zero));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(app(const EdgeInsets.only(bottom: 280)));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Android focus loss before IME metrics never shows artwork', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: TegnalPrivacyCover(child: const Text('Folder input'))),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Image), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('duplicate resumed state does not restart the privacy hold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.light),
        home: TegnalPrivacyCover(child: const Text('Reader')),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 316));
    await tester.pump(const Duration(milliseconds: 100));
    final transition = tester.widget<SlideTransition>(
      find.descendant(
        of: find.byType(TegnalPrivacyCover),
        matching: find.byType(SlideTransition),
      ),
    );
    expect(transition.position.value.dy, lessThan(0));
  });

  testWidgets('reduced motion fades the dark artwork after the resume hold', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: tegnalTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: TegnalPrivacyCover(child: const Text('Private content')),
        ),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, contains('splash_dark.jpg'));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Image), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 149));
    expect(find.byType(Image), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 17));
    expect(find.byType(Image), findsNothing);
  });
}
