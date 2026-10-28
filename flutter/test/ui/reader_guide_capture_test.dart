import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/features/reader_guide.dart';
import 'package:tegnal/ui/design_system.dart';
import 'package:tegnal/ui/l10n.dart';

const enabled = bool.fromEnvironment('TEGNAL_CAPTURE_GUIDE');
void main() {
  testWidgets('reader guide native illustration captures', (tester) async {
    final store = LibraryStore.memory();
    final controller = AppController(store);
    final boundary = GlobalKey();
    final output = Directory('build/ui-captures/reader-guide')
      ..createSync(recursive: true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      store.close();
      tester.view.reset();
    });
    await tester.runAsync(() async {
      await L10n.load();
      await (FontLoader('Pretendard')
            ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
          .load();
      await (FontLoader('Pretendard JP')
            ..addFont(rootBundle.load('assets/fonts/PretendardJPVariable.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    Future<void> mount({double scale = 1}) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('ko'),
            supportedLocales: const [Locale('ko')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: tegnalTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ReaderGuideScreen(
              key: UniqueKey(),
              controller: controller,
              mode: AppMode.manga,
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 160));
      });
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await mount();
    await capture('01-taps');
    await tester.tap(find.byKey(const ValueKey('reader-guide-next')));
    await tester.pumpAndSettle();
    await capture('02-zoom-translate');
    await tester.tap(find.byKey(const ValueKey('reader-guide-next')));
    await tester.pumpAndSettle();
    await capture('03-exit');
    controller.setReaderPreferences(
      AppMode.manga,
      const ReaderPreferences(readingMode: ReadingMode.continuous),
    );
    await mount();
    await tester.tap(find.text('나가기'));
    await tester.pumpAndSettle();
    await capture('04-continuous-exit');
    tester.view.physicalSize = const Size(320, 568);
    await mount(scale: 2);
    await capture('05-large-text');
  }, skip: !enabled);
}
