import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/downloads/download_store.dart';
import 'package:tegnal/core/storage/folder_palette.dart';
import 'package:tegnal/presentation/design/app_sheet.dart';
import 'package:tegnal/presentation/library/folder_color_sheet.dart';
import 'package:tegnal/presentation/settings/download_location_view.dart';

Future<BuildContext> _phone(WidgetTester tester) async {
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
  return context;
}

void main() {
  testWidgets('the color sheet shows all thirteen system colors with the folder\'s own marked', (tester) async {
    final context = await _phone(tester);
    final picked = <int>[];
    showAppSheet<void>(
      context,
      medium: true,
      builder: (context, controller) => FolderColorSheet(
        title: 'Reading',
        color: FolderPalette.red,
        onSelected: picked.add,
        preview: (color) => ColoredBox(key: ValueKey('preview-$color'), color: Color(color), child: const SizedBox(height: 120)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Reading color'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Color \d+$')), findsNWidgets(13));
    for (final color in FolderPalette.colors) {
      expect(find.byKey(ValueKey(color)), findsOneWidget);
    }
    expect(tester.getSemantics(find.bySemanticsLabel('Color 1')), isSemantics(isSelected: true));

    // The folder's own color does nothing; another recolors it and takes the mark.
    await tester.tap(find.bySemanticsLabel('Color 1'));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    await tester.tap(find.bySemanticsLabel('Color 2'));
    await tester.pumpAndSettle();
    expect(picked, [FolderPalette.orange]);
    expect(find.byKey(ValueKey('preview-${FolderPalette.orange}')), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('Color 2')), isSemantics(isSelected: true));
    expect(tester.getSemantics(find.bySemanticsLabel('Color 1')), isSemantics(isSelected: false));
    expect(find.bySemanticsLabel(RegExp(r'^Color \d+$')), findsNWidgets(13), reason: 'every color stays');
  });

  testWidgets('the download location page lists the device folder and offers a move', (tester) async {
    final directory = Directory.systemTemp.createTempSync('download-location');
    addTearDown(() {
      directory.deleteSync(recursive: true);
      final files = Directory('${directory.path}-files');
      if (files.existsSync()) files.deleteSync(recursive: true);
    });
    final store = DownloadStore(directory: directory, manga: FixtureContentSource(), configuredHost: () => 'comics.example', pageDelay: Duration.zero);
    final context = await _phone(tester);
    Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => DownloadLocationView(store: store)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Download Location'), findsWidgets);
    expect(find.text('On This Device'), findsOneWidget);
    expect(find.text('Choose Folder…'), findsOneWidget);
    expect(find.text('Move to Selected Location'), findsOneWidget);
    expect(find.text('Every download is in the folder above.'), findsOneWidget);
  });
}
