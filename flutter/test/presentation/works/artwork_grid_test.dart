// Grid geometry and card sizing, from native-ios/TEGNALTests/GridLayoutTests.swift.
// The preview pagination and mode-container tests arrive with the work detail and mode switch screens;
// testAutomaticAndManualColumnsFollowContainerWidth measures WorkGridLayout, which arrives with the saved works.
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/works/artwork_grid.dart';

void main() {
  test('artwork grows gently on larger screens and chosen columns follow it', () {
    int automatic(double width) =>
        ArtworkGridGeometry(width: width, columns: 0, minimum: ArtworkGridGeometry.artworkMinimum(width), removesPadding: false).count;
    // Phones and foldables either way up keep their two or three phone-sized columns.
    expect(automatic(382), 2);
    expect(automatic(402), 2);
    expect(automatic(440), 2);
    expect(automatic(600), 3);
    // A tablet shows three larger cards upright, three beside a side panel and four on its side.
    expect(automatic(744), 3);
    expect(automatic(1032), 3);
    expect(automatic(1056), 3);
    expect(automatic(1376), 4);
    final tablet = ArtworkGridGeometry(width: 1032, columns: 0, minimum: ArtworkGridGeometry.artworkMinimum(1032), removesPadding: false);
    final phone = ArtworkGridGeometry(width: 402, columns: 0, removesPadding: false);
    expect(tablet.cellWidth, greaterThan(phone.cellWidth * 1.5));
    // A chosen number stays as chosen up to a foldable on its side.
    for (final width in [320.0, 390.0, 440.0, 466.0, 600.0]) {
      for (var chosen = 1; chosen <= 5; chosen++) {
        expect(ArtworkGridGeometry.columnsFor(chosen: chosen, width: width), chosen);
      }
    }
    expect(ArtworkGridGeometry.columnsFor(chosen: 0, width: 1376), 0);
    // Wider, it keeps its balance against Automatic, which shows two on a phone.
    expect(ArtworkGridGeometry.columnsFor(chosen: 2, width: 1032), 3);
    expect(ArtworkGridGeometry.columnsFor(chosen: 3, width: 1032), 5);
    expect(ArtworkGridGeometry.columnsFor(chosen: 1, width: 1376), 2);
    expect(ArtworkGridGeometry.columnsFor(chosen: 4, width: 1376), 8);
    expect(ArtworkGridGeometry.columnsFor(chosen: 5, width: 2400), 12);
    // Folders keep their own, larger minimum.
    expect(ArtworkGridGeometry.folderMinimum(402), 160);
    expect(ArtworkGridGeometry.columnsFor(chosen: 2, width: 1032, minimum: ArtworkGridGeometry.folderMinimum(1032)), 3);
  });

  test('dense preview uses the same proportional spacing and corners as artwork', () {
    final regular = ArtworkGridGeometry(width: 390, columns: 2, removesPadding: false);
    final preview = ArtworkGridGeometry(width: 390, columns: 6, removesPadding: false, maximumColumns: 10);
    expect(preview.count, 6);
    expect(preview.spacing, greaterThan(0));
    expect(preview.spacing, lessThan(regular.spacing));
    expect(preview.margin, greaterThan(0));
    expect(preview.margin, lessThan(regular.margin));
    final style = ArtworkCellStyle(width: preview.cellWidth);
    expect(preview.spacing, closeTo(style.inset(14), 0.001));
    expect(preview.margin, closeTo(style.inset(16), 0.001));
    expect(style.radius(12), closeTo(preview.cellWidth / 160 * 12, 0.001));
    final noPadding = ArtworkGridGeometry(width: 390, columns: 6, removesPadding: true, maximumColumns: 10);
    expect(noPadding.spacing, 0);
    expect(noPadding.margin, 0);
    expect(ArtworkCellStyle(width: noPadding.cellWidth, removesPadding: true).radius(12), 0);
  });

  testWidgets('real grid shrinks margins and becomes edge to edge', (tester) async {
    double? baselineMargin;
    for (final (columns, dense) in [(2, false), (5, false), (5, true)]) {
      final frames = <int, Rect>{};
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 390,
              height: 900,
              child: CustomScrollView(
                slivers: [
                  ArtworkGridSliver(
                    itemCount: 10,
                    preferences: ArtworkGridPreferences(columns: columns, removesPadding: dense),
                    itemBuilder: (context, index, style) => AspectRatio(aspectRatio: 0.72, child: SizedBox(key: ValueKey(index))),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byType(CustomScrollView));
      for (var index = 0; index < columns + 1; index++) {
        frames[index] = tester.getRect(find.byKey(ValueKey(index))).shift(-origin);
      }
      final first = frames[0]!, next = frames[1]!;
      final row = frames.values.where((frame) => (frame.top - first.top).abs() < 1).toList();
      expect(row.length, columns);
      if (columns == 2) {
        baselineMargin = first.left;
      } else if (!dense) {
        expect(first.left, greaterThan(0));
        expect(first.left, lessThan(baselineMargin!));
        expect(next.left - first.right, lessThan(14));
      } else {
        expect(first.left, closeTo(0, 0.6));
        expect(next.left, closeTo(first.right, 0.6));
        expect(row.map((frame) => frame.right).reduce((a, b) => a > b ? a : b), closeTo(390, 0.6));
      }
    }
  });

  testWidgets('rendered gallery metadata shrinks and can be removed without empty space', (tester) async {
    Future<Size> size(double width, {bool titles = true, bool artists = true}) async {
      await tester.pumpWidget(
        CupertinoApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: GalleryCardLayout(
                style: ArtworkCellStyle(width: width, showsTitle: titles, showsArtists: artists),
                title: 'A sample title that wraps across two lines',
                artists: 'Example artist',
                language: '',
                cover: const ColoredBox(color: Color(0xFF0000FF)),
              ),
            ),
          ),
        ),
      );
      return tester.getSize(find.byType(GalleryCardLayout));
    }

    final normal = (await size(170)).height - 170 / 0.72;
    final small = (await size(65)).height - 65 / 0.72;
    expect(small, lessThan(normal));
    expect((await size(65, titles: false, artists: false)).height, closeTo(65 / 0.72, 0.6));
    expect((await size(65, titles: false)).height, greaterThan(65 / 0.72));
    expect((await size(65, artists: false)).height, greaterThan(65 / 0.72));
  });
}
