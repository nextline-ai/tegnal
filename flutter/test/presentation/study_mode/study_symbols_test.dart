import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/study_mode/study_kit.dart';
import 'package:tegnal/presentation/study_mode/study_symbols.dart';

/// Set to a folder to write each drawing (and the font glyph it replaces) as a PNG there, for comparing with the
/// SF Symbols: `STUDY_SYMBOLS_OUT=/some/folder flutter test test/presentation/study_mode/study_symbols_test.dart`.
final String? _out = Platform.environment['STUDY_SYMBOLS_OUT'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every drawing paints at small, middle and large sizes', () async {
    expect(studySymbolNames, isNotEmpty);
    for (final name in studySymbolNames) {
      for (final size in [12.0, 24.0, 96.0]) {
        final recorder = ui.PictureRecorder();
        paintStudySymbol(Canvas(recorder), name, size, const Color(0x80FF0000));
        final image = await recorder.endRecording().toImage(size.ceil(), size.ceil());
        final bytes = await image.toByteData();
        expect(bytes!.buffer.asUint8List().any((b) => b != 0), isTrue, reason: '$name at $size');
      }
    }
  });

  test('studySymbol is null for a name with no drawing', () {
    expect(studySymbol('no.such.symbol', size: 20, color: const Color(0xFF000000)), isNull);
    expect(studySymbolDrawn('no.such.symbol'), isFalse);
    expect(studySymbol('dumbbell.fill', size: 20, color: const Color(0xFF000000)), isNotNull);
  });

  testWidgets('StudyIcon draws a drawn symbol and uses the font for the rest', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Row(children: [StudyIcon('dumbbell.fill', size: 24), StudyIcon('sparkles', size: 24)]),
      ),
    );
    expect(find.byIcon(CupertinoIcons.gamecontroller_fill), findsNothing);
    expect(find.byIcon(CupertinoIcons.sparkles), findsOneWidget);
    final drawn = find.descendant(of: find.byType(StudyIcon).first, matching: find.byType(CustomPaint));
    expect(drawn, findsOneWidget);
    expect(tester.getSize(find.byType(StudyIcon).first), const Size(24, 24));
  });

  testWidgets('a drawn StudyIcon with no colour takes the surrounding icon colour', (tester) async {
    Color? painted(WidgetTester tester) {
      final paint = tester.widget<CustomPaint>(find.descendant(of: find.byType(StudyIcon), matching: find.byType(CustomPaint)));
      // The painter is private; its colour shows in how it describes itself.
      return (paint.painter! as dynamic).color as Color;
    }

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(color: Color(0xFF123456)),
          child: StudyIcon('dumbbell.fill'),
        ),
      ),
    );
    expect(painted(tester), const Color(0xFF123456));

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(color: Color(0xFF123456), opacity: 0.5),
          child: StudyIcon('dumbbell.fill'),
        ),
      ),
    );
    expect(painted(tester)!.a, closeTo(0.5, 0.01));

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: IconTheme(
          data: IconThemeData(color: Color(0xFF123456)),
          child: StudyIcon('dumbbell.fill', color: Color(0xFFAA0000)),
        ),
      ),
    );
    expect(painted(tester), const Color(0xFFAA0000));
  });

  test('writes PNGs for comparison', () async {
    final out = _out!;
    final font = FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'));
    await font.load();
    final names = File('$out/names.txt').readAsLinesSync().where((n) => n.isNotEmpty);
    Future<void> write(String folder, String name, void Function(Canvas) paint) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(const Color(0xFFFFFFFF), BlendMode.src);
      paint(canvas);
      final image = await recorder.endRecording().toImage(256, 256);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$folder/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    }

    for (final name in names) {
      final glyph = StudyGlyph.icon(name);
      await write('glyph', name, (canvas) {
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontFamily: 'packages/cupertino_icons/CupertinoIcons', fontSize: 128, height: 1))
          ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
          ..addText(String.fromCharCode(glyph.codePoint));
        final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: 1000));
        canvas.drawParagraph(paragraph, Offset(64 + (128 - paragraph.maxIntrinsicWidth) / 2, 64));
      });
      if (studySymbolDrawn(name)) {
        await write('mine', name, (canvas) {
          canvas.translate(64, 64);
          paintStudySymbol(canvas, name, 128, const Color(0xFF000000));
        });
      }
    }
  }, skip: _out == null ? 'Set STUDY_SYMBOLS_OUT to write the PNGs' : false);
}
