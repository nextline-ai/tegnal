// `testThumbnailsKeepTheShorterSideSharpWithinBounds` from native-ios/TEGNALTests/BooruThumbnailCacheTests.swift.
// Native names the longer side's pixels; Flutter decodes by width, so the same sizes read as widths.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/presentation/booru/booru_common.dart';

void main() {
  test('thumbnails keep the shorter side sharp within bounds', () {
    expect(booruThumbnailDecodeWidth(2400, 1200), 1440, reason: 'A wide image keeps 720 pixels of height');
    expect(booruThumbnailDecodeWidth(1000, 1500), 720, reason: 'A tall image keeps 720 pixels of width');
    expect(booruThumbnailDecodeWidth(800, 400), 800, reason: 'A small file is never enlarged');
    expect(booruThumbnailDecodeWidth(1000, 6000), 341, reason: 'A long strip stops at the longest size');
  });
}
