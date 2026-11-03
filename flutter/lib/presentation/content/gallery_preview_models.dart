import 'dart:math' as math;
import 'dart:ui' show Color, Rect;

import '../../core/content/gallery_content.dart';
import '../../core/storage/app_database.dart';
import '../../core/support/l10n.dart';
import '../../domain/models.dart';
import '../works/artwork_grid.dart';

/// Page previews load only after meaningful downward travel AND reaching the end of the
/// work information. A visible footer alone is not intent.
abstract final class GalleryPreviewLoading {
  /// `metadata` is the information section's frame in the detail's scroll viewport.
  static bool shouldLoad({required Rect metadata, required double viewportHeight}) {
    if (viewportHeight <= 0) return false;
    final minimumTravel = math.max(160, math.min(320, viewportHeight * 0.35));
    return 20 - metadata.top >= minimumTravel && metadata.bottom <= viewportHeight - 44;
  }
}

/// Paged page-preview grids on the work information screen.
abstract final class GalleryPreviewLayout {
  static int pageSize({required int columns, required int rows}) => math.max(1, columns) * math.max(1, rows);

  static int pageCount({required int total, required int columns, required int rows}) {
    final size = pageSize(columns: columns, rows: rows);
    return math.max(1, (math.max(0, total) + size - 1) ~/ size);
  }

  /// The page indices shown on preview page `page`, as `start` (inclusive) and `end` (exclusive).
  static (int start, int end) pageRange(int page, {required int total, required int columns, required int rows}) {
    final size = pageSize(columns: columns, rows: rows);
    final start = math.min(math.max(0, page) * size, math.max(0, total));
    return (start, math.min(start + size, math.max(0, total)));
  }

  /// A short work stops at the rows it fills, so what follows isn't left behind a gap.
  static int filledRows({required int total, required int columns, required int rows}) =>
      math.min(math.max(1, rows), math.max(1, (math.max(0, total) + math.max(1, columns) - 1) ~/ math.max(1, columns)));

  static double height({required int rows, required ArtworkGridGeometry geometry}) {
    final count = math.max(1, rows);
    return count * geometry.cellWidth / 0.72 + (count - 1) * geometry.spacing + geometry.margin * 2;
  }

  /// Automatic shows twice the artwork columns; a chosen number is kept, up to 10.
  static int columns({required double width, required int artworkColumns, required int previewColumns, required bool removesArtworkPadding}) {
    if (previewColumns > 0) return math.min(10, previewColumns);
    return ArtworkGridGeometry(width: width, columns: artworkColumns, removesPadding: removesArtworkPadding).count * 2;
  }
}

/// Categories come from tag namespaces or the server's category metadata.
enum ArtworkTagCategory {
  artist,
  series,
  character,
  female,
  male,
  group,
  language,
  type,
  metadata,
  general;

  String get rawValue => name;

  /// The untranslated title; show it through `L10n.text`.
  String get title => switch (this) {
    artist => 'Artists',
    series => 'Series',
    character => 'Characters',
    female => 'Female Tags',
    male => 'Male Tags',
    group => 'Groups',
    language => 'Language',
    type => 'Type',
    metadata => 'Metadata Tags',
    general => 'Other Tags',
  };

  /// SwiftUI system colors (dark appearance values); `general` is the primary label color, null here.
  Color? get color => switch (this) {
    artist => const Color(0xFFFF9F0A),
    series => const Color(0xFFBF5AF2),
    character => const Color(0xFF30D158),
    female => const Color(0xFFFF375F),
    male => const Color(0xFF0A84FF),
    group => const Color(0xFF40CBE0),
    language => const Color(0xFF5E5CE6),
    type => const Color(0xFFAC8E68),
    metadata => const Color(0xFF66D4CF),
    general => null,
  };

  /// The same colors in the light appearance.
  Color? get lightColor => switch (this) {
    artist => const Color(0xFFFF9500),
    series => const Color(0xFFAF52DE),
    character => const Color(0xFF34C759),
    female => const Color(0xFFFF2D55),
    male => const Color(0xFF007AFF),
    group => const Color(0xFF30B0C7),
    language => const Color(0xFF5856D6),
    type => const Color(0xFFA2845E),
    metadata => const Color(0xFF00C7BE),
    general => null,
  };

  /// SF Symbol name of the heading icon.
  String get symbol => switch (this) {
    artist => 'paintbrush',
    series => 'books.vertical',
    character => 'person.crop.square',
    female || male => 'person.text.rectangle',
    group => 'person.2',
    language => 'globe',
    type => 'square.stack',
    metadata => 'info.circle',
    general => 'tag',
  };

  /// The saved-tag kind a held tag of this category is saved as (`SavedCollectionKind(category:)`).
  SavedCollectionKind get savedKind => this == general ? SavedCollectionKind.tag : SavedCollectionKind.fromRawValue(name) ?? SavedCollectionKind.tag;
}

class ArtworkTag {
  const ArtworkTag({required this.query, required this.name, required this.category});

  /// What a search for this tag uses, namespace included.
  final String query;

  /// What the pill shows: without the namespace, underscores as spaces.
  final String name;
  final ArtworkTagCategory category;

  String get id => query;

  @override
  bool operator ==(Object other) => other is ArtworkTag && other.query == query && other.name == name && other.category == category;
  @override
  int get hashCode => Object.hash(query, name, category);
}

class ArtworkTagGroup {
  const ArtworkTagGroup({required this.category, required this.tags});
  final ArtworkTagCategory category;
  final List<ArtworkTag> tags;

  static const _namespaces = {
    'artist': ArtworkTagCategory.artist,
    'series': ArtworkTagCategory.series,
    'parody': ArtworkTagCategory.series,
    'copyright': ArtworkTagCategory.series,
    'character': ArtworkTagCategory.character,
    'female': ArtworkTagCategory.female,
    'male': ArtworkTagCategory.male,
    'group': ArtworkTagCategory.group,
    'language': ArtworkTagCategory.language,
    'type': ArtworkTagCategory.type,
    'meta': ArtworkTagCategory.metadata,
    'tag': ArtworkTagCategory.general,
    'other': ArtworkTagCategory.general,
  };

  static List<ArtworkTagGroup> make({required List<String> tags, List<String> artists = const [], Map<String, int> categories = const {}}) {
    final result = <ArtworkTagCategory, List<ArtworkTag>>{};
    final seen = <String>{};
    final artistNames = artists.toSet();
    for (final raw in [...artists, ...tags]) {
      final query = raw.trim();
      if (query.isEmpty) continue;
      final colon = query.indexOf(':');
      final parts = colon > 0 && colon < query.length - 1 ? [query.substring(0, colon), query.substring(colon + 1)] : [query];
      var category = artistNames.contains(query) ? ArtworkTagCategory.artist : ArtworkTagCategory.general;
      var name = query;
      final namespaced = parts.length == 2 ? _namespaces[parts[0]] : null;
      if (namespaced != null) {
        category = namespaced;
        name = parts[1];
      } else if (categories[query] case final known?) {
        category = switch (known) {
          1 => ArtworkTagCategory.artist,
          3 => ArtworkTagCategory.series,
          4 => ArtworkTagCategory.character,
          5 => ArtworkTagCategory.metadata,
          _ => category,
        };
      }
      name = name.replaceAll('_', ' ');
      if (!seen.add('${category.rawValue}:$name')) continue;
      result.putIfAbsent(category, () => []).add(ArtworkTag(query: query, name: name, category: category));
    }
    return [
      for (final category in ArtworkTagCategory.values)
        if (result[category] case final tags? when tags.isNotEmpty) ArtworkTagGroup(category: category, tags: tags),
    ];
  }
}

/// What the work information screen shows below the actions (`GalleryDetailMetadata`).
abstract final class GalleryDetailMetadata {
  /// Tag groups without artists and language, with Other Tags always last (empty when there are none).
  static List<ArtworkTagGroup> groups(NativeGallery gallery) {
    final tags = ArtworkTagGroup.make(tags: gallery.tags)
        .where((group) => group.category != ArtworkTagCategory.artist && group.category != ArtworkTagCategory.language);
    return [
      ...tags.where((group) => group.category != ArtworkTagCategory.general),
      tags.where((group) => group.category == ArtworkTagCategory.general).firstOrNull ?? const ArtworkTagGroup(category: ArtworkTagCategory.general, tags: []),
    ];
  }

  /// The work's artists followed by `artist:` tags, once each however they are spelled.
  static List<String> artists(NativeGallery gallery) {
    final seen = <String>{};
    final tagged =
        ArtworkTagGroup.make(tags: gallery.tags)
            .where((group) => group.category == ArtworkTagCategory.artist)
            .firstOrNull
            ?.tags
            .map((tag) => tag.query.substring('artist:'.length)) ??
        const <String>[];
    return [...gallery.artists, ...tagged].where((name) => MangaArtistFavorite.key(name).isNotEmpty && seen.add(MangaArtistFavorite.key(name))).toList();
  }

  /// Other language versions, the content language first, without hidden works.
  static List<GalleryVersion> versions(NativeGallery gallery, {required Set<int> hidden}) =>
      gallery.otherVersions(L10n.contentLanguage).where((version) => !hidden.contains(version.id)).toList();

  /// The version suggested above the metadata, unless hidden.
  static GalleryVersion? suggestion(NativeGallery gallery, {required Set<int> hidden}) {
    final version = gallery.suggestedVersion(L10n.contentLanguage);
    return version == null || hidden.contains(version.id) ? null : version;
  }

  /// The search a tap on a tag, artist or language runs.
  static String tagSearch(ArtworkTag tag) => tag.query.replaceAll(' ', '_');
  static String artistSearch(String name) => 'artist:${name.replaceAll(' ', '_')}';
  static String languageSearch(String language) => 'language:${language.replaceAll(' ', '_')}';

  /// Whether a saved-tag query set from [savedTagQueries] contains a tag's search.
  static bool isSaved(ArtworkTag tag, Set<String> savedQueries) => savedQueries.contains(tag.query.replaceAll(' ', '_'));
  static bool isLanguageSaved(String language, Set<String> savedQueries) => savedQueries.contains(SavedCollectionKind.language.query(language, manga: true));

  /// Saved tags as the queries they search for, one per kind.
  static Set<String> savedTagQueries(List<ArtistMemo> values) => {
    for (final value in values)
      if (SavedCollectionKind.values.where((kind) => kind.mangaKind == value.kind).firstOrNull case final kind?) kind.query(value.name, manga: true),
  };

  /// Favorite artists are saved names of kind 0.
  static Set<String> favoriteArtists(List<ArtistMemo> values) => {
    for (final value in values)
      if (value.kind == 0) value.name,
  };

  static bool isFavorite(String name, Set<String> favorites) => favorites.any((favorite) => MangaArtistFavorite.key(favorite) == MangaArtistFavorite.key(name));

  /// Hold to save, hold again to remove. Returns whether the tag is now saved.
  static bool toggleTag(AppDatabase database, String name, SavedCollectionKind kind) => database.toggleCollectionTag(name, kind);
}

/// "English · manga · 24 pages" under the work title (`GalleryDetailHeading` metadata).
String galleryHeadingMetadata(NativeGallery gallery) => L10n.text('%@ · %@ · %@ pages', [gallery.language, gallery.type, '${gallery.pages.length}']);

/// Favorite artists match however a website spells them (spaces or underscores, case).
abstract final class MangaArtistFavorite {
  static Set<String> toggle(String name, AppDatabase database) {
    final artists = {
      for (final artist in database.listArtists())
        if (artist.kind == 0) artist.name,
    };
    final matching = artists.where((artist) => key(artist) == key(name)).toList();
    if (matching.isEmpty) {
      database.addFavoriteArtist(name);
    } else {
      for (final artist in matching) {
        database.removeFavoriteArtist(artist, kind: 0);
      }
    }
    return {
      for (final artist in database.listArtists())
        if (artist.kind == 0) artist.name,
    };
  }

  static String key(String name) => SavedCollectionKind.identity(name);
}

/// Where a work's other languages and related works lead. Offline reading has none.
class GalleryWorkLinks {
  const GalleryWorkLinks({required this.source, required this.openVersion, required this.openRelated});
  final ContentProviding source;
  final void Function(int id) openVersion;
  final void Function(int id) openRelated;
}
