import 'dart:typed_data';

import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../content/manga_urls.dart';
import '../storage/app_database.dart';
import '../support/swift_json.dart';
import 'taste_models.dart';
import 'taste_recap.dart';
import 'taste_store.dart';

/// Image mode's library as taste analysis reads it.
extension BooruStoreTaste on BooruStore {
  TasteStore get tasteStore => TasteStore(database, TasteMode.booru);

  /// Favorites the library currently shows. Blacklisted and restricted posts stay out of every recap surface.
  Map<String, RecapWorkInfo> recapLibrary() {
    final dates = favoriteSavedDates();
    final addresses = <String, String>{};
    for (final server in servers) {
      addresses.putIfAbsent(server.id, () => server.canonicalAddress);
    }
    final result = <String, RecapWorkInfo>{};
    for (final post in visibleFavorites()) {
      final categories = post.tagCategories ?? const <String, int>{};
      List<String> named(int category) => (categories.entries.where((entry) => entry.value == category).map((entry) => entry.key).toList()..sort());
      final artists = <String>{...post.artists, ...named(1)}.toList();
      final saved = dates[post.id];
      result['${addresses[post.serverID] ?? post.serverID}#${post.postID}'] = RecapWorkInfo(
        artists: artists,
        series: named(3),
        characters: named(4),
        savedAt: saved == null ? null : DateTime.fromMicrosecondsSinceEpoch((saved * 1e6).round(), isUtc: true),
      );
    }
    return result;
  }

  List<TasteItem> tasteLibrary() => database.read((db) {
    // Resolve each server once, rather than re-reading its payload for every favorite.
    final addresses = <String, String>{};
    for (final data in db.column<Uint8List>('SELECT payload FROM servers')) {
      final server = BooruServer.fromJson(decodeJsonObject(data));
      addresses.putIfAbsent(server.id, () => server.canonicalAddress);
    }
    return [
      for (final data in db.column<Uint8List>('SELECT payload FROM favorites'))
        if (BooruPost.fromJson(decodeJsonObject(data)) case final post)
          TasteItem(source: addresses[post.serverID] ?? post.serverID, id: post.postID, tags: post.tags, metadata: post.metadataTags ?? const []),
    ];
  });
}

/// Comics mode's library as taste analysis reads it.
extension AppDatabaseTaste on AppDatabase {
  TasteStore get tasteStore => TasteStore(dbWriter, TasteMode.comics);

  void recordTasteSearch(DiscoveryContext context) {
    if (context.origin != DiscoveryOrigin.search || context.included.isEmpty) return;
    tasteStore.record(
      TasteEventKind.search,
      TasteItem(source: MangaUrls.source, id: 0, tags: context.included.toList()),
      context: context,
    );
  }

  void observeTaste({required int id, required List<String> tags, required DiscoveryContext context}) => tasteStore.record(
    TasteEventKind.open,
    TasteItem(source: MangaUrls.source, id: id, tags: tags),
    context: context,
  );

  void recordDwell(TasteDwell dwell, {required int id, required List<String> tags, required DiscoveryContext context}) =>
      dbWriter.write((db) => TasteStore.recordDwell(dwell, TasteItem(source: MangaUrls.source, id: id, tags: tags), context, db));

  Map<String, RecapWorkInfo> recapLibrary({Set<int> hidden = const {}}) {
    List<String> split(Object? value) => ((value as String?) ?? '').split(',').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
    return dbWriter.read((db) {
      final result = <String, RecapWorkInfo>{};
      for (final row in db.rows(
        'SELECT w.gallery_id, w.title, w.artists, w.series, w.bookmarked_at, w.thumb_path, c.characters FROM works w LEFT JOIN catalog_works c ON c.id = w.gallery_id',
      )) {
        final id = row['gallery_id'] as int;
        if (hidden.contains(id)) continue;
        result[TasteItem.comic(id, source: MangaUrls.source).key] = RecapWorkInfo(
          title: row['title'] as String?,
          artists: split(row['artists']),
          series: split(row['series']),
          characters: split(row['characters']),
          savedAt: DateTime.tryParse((row['bookmarked_at'] as String?) ?? ''),
          thumbPath: row['thumb_path'] as String?,
        );
      }
      return result;
    });
  }

  List<TasteItem> tasteLibrary() => dbWriter.read(
    (db) => [
      for (final row in db.rows('SELECT gallery_id, tags FROM works'))
        TasteItem.comic(row['gallery_id'] as int, tags: row['tags'] as String?, source: MangaUrls.source),
    ],
  );
}
