// Work information logic from native-ios/TEGNALTests/ReaderUXTests.swift and the preview
// layout tests of GridLayoutTests.swift.
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/presentation/content/gallery_preview_models.dart';
import 'package:tegnal/presentation/works/artwork_grid.dart';

void main() {
  test('detail previews require meaningful scroll and reaching metadata end', () {
    for (final height in [320.0, 678.0, 1024.0]) {
      for (final travel in [0.0, 12.0, 48.0, 120.0]) {
        final shortInfo = Rect.fromLTWH(20, 20 - travel, 300, 100);
        expect(
          GalleryPreviewLoading.shouldLoad(metadata: shortInfo, viewportHeight: height),
          isFalse,
          reason: 'A visible preview section is not permission to load on a small scroll',
        );
      }
      final longInfo = Rect.fromLTWH(20, -400, 300, height + 500);
      expect(
        GalleryPreviewLoading.shouldLoad(metadata: longInfo, viewportHeight: height),
        isFalse,
        reason: 'Do not fetch previews while the user is still reading long metadata',
      );
      final reachedEnd = Rect.fromLTWH(20, -400, 300, height + 300);
      expect(GalleryPreviewLoading.shouldLoad(metadata: reachedEnd, viewportHeight: height), isTrue);
    }
    expect(GalleryPreviewLoading.shouldLoad(metadata: Rect.zero, viewportHeight: 0), isFalse);
  });

  test('tag groups keep search queries and differentiate namespaces and API categories', () {
    final groups = ArtworkTagGroup.make(
      tags: ['artist:sample', 'parody:series_one', 'character:hero', 'female:long_hair', 'male:glasses', 'sky', 'hero', 'sample'],
      artists: ['sample'],
      categories: {'hero': 4},
    );
    ArtworkTagGroup? group(ArtworkTagCategory category) => groups.where((group) => group.category == category).firstOrNull;
    expect(groups.first.category, ArtworkTagCategory.artist);
    expect(groups.first.tags.length, 1);
    expect(group(ArtworkTagCategory.series)?.tags.first.query, 'parody:series_one');
    expect(group(ArtworkTagCategory.series)?.tags.first.name, 'series one');
    expect(group(ArtworkTagCategory.character)?.tags.length, 1);
    expect(group(ArtworkTagCategory.female)?.tags.first.query, 'female:long_hair');
    expect(group(ArtworkTagCategory.male)?.tags.first.name, 'glasses');
    expect(group(ArtworkTagCategory.general)?.tags.first.name, 'sky');
  });

  test('favorite artist tags persist and recognize spaces and underscores', () {
    final database = AppDatabase.inMemory();
    var favorites = MangaArtistFavorite.toggle('sample_artist', database);
    expect(favorites.contains('sample_artist'), isTrue);
    expect(database.listArtists().map((artist) => artist.name), ['sample_artist']);
    favorites = MangaArtistFavorite.toggle('Sample Artist', database);
    expect(favorites, isEmpty, reason: 'Holding an already-favorited artist removes it even if the website formats its name differently');
    database.addFavoriteArtist('another_artist');
    MangaArtistFavorite.toggle('sample_artist', database);
    favorites = MangaArtistFavorite.toggle('sample_artist', database);
    expect(favorites, {'another_artist'}, reason: 'Other favorite artists remain unchanged');
  });

  test('preview pagination keeps five rows regardless of column count and covers every page', () {
    for (final columns in [1, 2, 6, 10]) {
      final count = GalleryPreviewLayout.pageCount(total: 123, columns: columns, rows: 5);
      final ranges = [for (var page = 0; page < count; page++) GalleryPreviewLayout.pageRange(page, total: 123, columns: columns, rows: 5)];
      expect(ranges.first.$2 - ranges.first.$1, columns * 5);
      expect(ranges.every((range) => range.$2 - range.$1 <= columns * 5), isTrue);
      expect(
        [
          for (final range in ranges)
            for (var index = range.$1; index < range.$2; index++) index,
        ],
        [for (var index = 0; index < 123; index++) index],
        reason: 'Changing columns must not skip or duplicate artwork pages',
      );
      final geometry = ArtworkGridGeometry(width: 390, columns: columns, removesPadding: false, maximumColumns: 10);
      expect(
        GalleryPreviewLayout.height(rows: 5, geometry: geometry),
        closeTo(geometry.cellWidth / 0.72 * 5 + geometry.spacing * 4 + geometry.margin * 2, 0.001),
      );
    }
    expect(GalleryPreviewLayout.pageRange(1, total: 123, columns: 4, rows: 3), (12, 24));
    expect(GalleryPreviewLayout.pageRange(99, total: 123, columns: 4, rows: 3), (123, 123));
  });

  test('preview columns follow twice the resolved artwork columns or an explicit choice', () {
    for (final width in [280.0, 390.0, 678.0, 1024.0, 1280.0]) {
      for (var columns = 0; columns <= 5; columns++) {
        final artwork = ArtworkGridGeometry(width: width, columns: columns, removesPadding: false);
        expect(GalleryPreviewLayout.columns(width: width, artworkColumns: columns, previewColumns: 0, removesArtworkPadding: false), artwork.count * 2);
        expect(GalleryPreviewLayout.columns(width: width, artworkColumns: columns, previewColumns: 6, removesArtworkPadding: false), 6);
      }
    }
  });

  test('a short work stops at the rows it fills', () {
    expect(GalleryPreviewLayout.filledRows(total: 3, columns: 4, rows: 5), 1);
    expect(GalleryPreviewLayout.filledRows(total: 9, columns: 4, rows: 5), 3);
    expect(GalleryPreviewLayout.filledRows(total: 400, columns: 4, rows: 5), 5);
    expect(GalleryPreviewLayout.filledRows(total: 0, columns: 4, rows: 5), 1);
  });
}
