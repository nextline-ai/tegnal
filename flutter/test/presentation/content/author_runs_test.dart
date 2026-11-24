import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/presentation/content/author_runs.dart';
import 'package:tegnal/presentation/content/gallery_feed_loader.dart';
import 'package:tegnal/presentation/content/page_image_store.dart';

/// The long fixture feed, counting each work's details and how many load at once.
class _CountingFeed extends ContentProviding {
  final _feed = FixtureContentSource(options: {FixtureOption.longFeed});
  final _covers = FixtureContentSource();
  final requested = <int>[];
  int _open = 0;
  int mostAtOnce = 0;

  @override
  Future<NativeGallery> gallery(int id) async {
    requested.add(id);
    _open += 1;
    if (_open > mostAtOnce) mostAtOnce = _open;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _open -= 1;
    return _feed.gallery(id);
  }

  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) => _feed.list(query, offset: offset, count: count);
  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) =>
      _covers.image(page, galleryID: galleryID, thumbnail: thumbnail);
}

void main() {
  test('three works by one artist within five works of each other make a run', () {
    // A at 0, 3 and 9: five other works between 3 and 9 still joins.
    final artists = <List<String>?>[
      ['A'], ['B'], ['C'], ['a '], ['D'], ['E'], ['F'], ['G'], ['H'], ['A'], ['I'], //
    ];
    expect(AuthorRuns.runs(artists), [
      const AuthorRun('A', [0, 3, 9]),
    ]);
    // Six works between two breaks the run, and two works alone are not one.
    final apart = <List<String>?>[
      ['A'], ['A'], ['B'], ['C'], ['D'], ['E'], ['F'], ['G'], ['A'], //
    ];
    expect(AuthorRuns.runs(apart), isEmpty);
    expect(
      AuthorRuns.runs([
        ['A'],
        ['A'],
        ['B'],
      ]),
      isEmpty,
    );
  });

  test('works not loaded yet count as works between, and each work joins one run', () {
    final unknown = <List<String>?>[
      ['A'], null, null, null, null, null, ['A'], ['A'], [], //
    ];
    expect(AuthorRuns.runs(unknown), [
      const AuthorRun('A', [0, 6, 7]),
    ]);
    // A shared work goes to the longer run; the shorter keeps its run only while it still has three.
    final shared = <List<String>?>[
      ['A'], ['A', 'B'], ['A'], ['B'], ['B'], ['A'], ['B'], //
    ];
    expect(AuthorRuns.runs(shared), [
      const AuthorRun('A', [0, 1, 2, 5]),
      const AuthorRun('B', [3, 4, 6]),
    ]);
  });

  test("a run takes its first work's place after the row it starts in", () {
    const run = AuthorRun('A', [1, 2, 4]);
    expect(AuthorRuns.lines(7, [run], 2), [
      const AuthorRunLine.works([0, 3]),
      AuthorRunLine.run(run),
      const AuthorRunLine.works([5, 6]),
    ]);
    const atStart = AuthorRun('A', [0, 1, 2]);
    expect(AuthorRuns.lines(5, [atStart], 2), [
      AuthorRunLine.run(atStart),
      const AuthorRunLine.works([3, 4]),
    ]);
    expect(AuthorRuns.lines(5, const [], 3), [
      const AuthorRunLine.works([0, 1, 2]),
      const AuthorRunLine.works([3, 4]),
    ]);
    // A run waiting for a row the list never fills comes after the short last row.
    expect(AuthorRuns.lines(4, [run], 3), [
      const AuthorRunLine.works([0, 3]),
      AuthorRunLine.run(run),
    ]);
  });

  test('a run holds more works than a row: four in three columns', () {
    final artists = <List<String>?>[
      ['A'], ['B'], ['A'], ['A'], ['C'], ['D'], ['A'], //
    ];
    expect(AuthorRuns.minimum(1), 3);
    expect(AuthorRuns.minimum(2), 3);
    expect(AuthorRuns.minimum(3), 4);
    expect(AuthorRuns.runs(artists.sublist(0, 4), columns: 3), isEmpty);
    expect(AuthorRuns.runs(artists, columns: 3), [
      const AuthorRun('A', [0, 2, 3, 6]),
    ]);
    expect(AuthorRuns.runs(artists, columns: 4), isEmpty);
  });

  test('details load ahead for the rows near the viewport, two at a time', () async {
    final source = _CountingFeed();
    final loader = GalleryFeedLoader(
      source: source,
      images: PageImageStore(source: source),
    )..allowsBackfill = () => true;
    await loader.load(const GalleryQuery(), reset: true, site: 'fixture');
    expect(loader.items, hasLength(24));
    loader.prioritizeCovers(0, count: 12, columns: 2);
    final ahead = loader.items.take(12).map((item) => loader.previews[item]!).toList();
    for (var wait = 0; wait < 200 && ahead.any((preview) => preview.display == null || preview.image == null); wait++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ahead.every((preview) => preview.display != null), isTrue);
    expect(source.requested.toSet(), loader.items.take(12).map((item) => item.id).toSet());
    expect(source.mostAtOnce, lessThanOrEqualTo(2));
    expect(loader.previews[loader.items[12]]!.display, isNull);
  });
}
