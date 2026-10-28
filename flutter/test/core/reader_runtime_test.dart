import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/features/reader_runtime.dart';
import 'package:tegnal/ui/reader_image_provider.dart';

void main() {
  test('post neighbors cover both directions and stay within bounds', () {
    expect(ReaderPostNeighbors.indices(4, 9), [5, 3, 6, 2]);
    expect(ReaderPostNeighbors.indices(0, 3), [1, 2]);
    expect(ReaderPostNeighbors.indices(2, 3), [1, 0]);
  });

  test(
    'replacement starts newest jobs after bounded old work completes',
    () async {
      final queue = ReaderPrefetchQueue();
      addTearDown(queue.close);
      final first = Completer<void>();
      final second = Completer<void>();
      final started = <String>[];
      queue.replace([
        () {
          started.add('old1');
          return first.future;
        },
        () {
          started.add('old2');
          return second.future;
        },
        () async {
          started.add('obsolete');
        },
      ]);
      expect(started, ['old1', 'old2']);
      queue.replace([
        () async {
          started.add('new1');
        },
        () async {
          started.add('new2');
        },
      ]);
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, ['old1', 'old2', 'new1', 'new2']);
      second.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, isNot(contains('obsolete')));
    },
  );

  ContentItem item(
    int id, {
    String? title,
    AppMode mode = AppMode.booru,
    Map<String, dynamic> metadata = const {},
  }) => ContentItem(
    sourceId: 'source',
    id: id,
    mode: mode,
    title: title ?? 'Item $id',
    metadata: metadata,
  );
  test('large sequences keep caller order, selected metadata and unique mode boundaries', () {
    final supplied = [
      for (var index = 0; index < 10000; index++) item(index + 1),
    ];
    final selected = item(5000, title: 'Fresh selected metadata');
    final result = ReaderSequence.ordered(selected, [
      ...supplied,
      supplied.first,
      item(10001, mode: AppMode.manga),
    ]);
    expect(result.length, supplied.length);
    expect(result.map((entry) => entry.id), supplied.map((entry) => entry.id));
    expect(identical(result[4999], selected), isTrue);
    expect(ReaderSequence.ordered(item(20000), supplied).first.id, 20000);
    final manga = item(1, mode: AppMode.manga);
    expect(ReaderSequence.ordered(manga, supplied), [manga]);
  });

  test('visible and prefetched media select identical providers for original and reduced modes', () {
    final post = item(
      1,
      metadata: {
        'fileURL': 'https://images.example/original.png',
        'previewURL': 'https://images.example/preview.jpg',
      },
    );
    final source = [
      ReaderPage(
        url: Uri.https('images.example', '/sample.jpg'),
        thumbnailUrl: Uri.https('images.example', '/thumb.jpg'),
        width: 800,
        height: 1200,
        headers: {'Referer': 'https://source.example/posts/1'},
      ),
    ];
    for (final preference in [
      const ReaderPreferences(),
      const ReaderPreferences(originalImages: true),
      const ReaderPreferences(reducedData: true),
      const ReaderPreferences(originalImages: true, reducedData: true),
    ]) {
      final visible = ReaderMediaPolicy.pages(
        post,
        source,
        preference,
        offline: false,
      ).single;
      final speculative = ReaderMediaPolicy.pages(
        post,
        source,
        preference,
        offline: false,
      ).single;
      expect(
        readerImageProvider(visible, visible.headers, 2048),
        readerImageProvider(speculative, speculative.headers, 2048),
      );
      expect(visible.headers, source.single.headers);
      expect(
        visible.url.path,
        preference.originalImages
            ? '/original.png'
            : preference.reducedData
            ? '/preview.jpg'
            : '/sample.jpg',
      );
    }
    expect(
      identical(
        ReaderMediaPolicy.pages(
          post,
          source,
          const ReaderPreferences(originalImages: true),
          offline: true,
        ),
        source,
      ),
      isTrue,
    );
    expect(
      identical(
        ReaderMediaPolicy.pages(
          item(1, metadata: {'fileURL': 'http://unsafe.example/image'}),
          source,
          const ReaderPreferences(originalImages: true),
          offline: false,
        ),
        source,
      ),
      isTrue,
    );
  });

  test('continuous offsets retain exact boundaries for mixed page heights', () {
    final geometry = ReaderPageOffsets([100, 320, 50, 75]);
    expect(
      [for (var index = 0; index <= 4; index++) geometry.offset(index)],
      [0, 100, 420, 470, 545],
    );
    expect(
      [
        for (final offset in [
          -10.0,
          0.0,
          99.0,
          100.0,
          419.9,
          420.0,
          470.0,
          999.0,
        ])
          geometry.pageAt(offset),
      ],
      [0, 0, 0, 1, 1, 2, 3, 3],
    );
    expect(ReaderPageOffsets([]).pageAt(300), 0);
    final corrected = ReaderPageOffsets([120, 320, 50, 75]);
    expect(corrected.offset(2), 440);
    expect(corrected.pageAt(430), 1);
  });

  test('long continuous books match linear geometry without rereading page extents', () {
    var reads = 0;
    final extents = [
      for (var index = 0; index < 20000; index++) 400.0 + index % 7,
    ];
    final geometry = ReaderPageOffsets(
      extents.map((extent) {
        reads++;
        return extent;
      }),
    );
    expect(reads, extents.length);
    for (var page = 0; page < extents.length; page += 137) {
      final start = geometry.offset(page);
      expect(geometry.pageAt(start), page);
      expect(geometry.pageAt(start + extents[page] * .5), page);
    }
    expect(reads, extents.length);
  });
}
