import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content/combined_catalog.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/sql_database.dart';

/// Ported from `OneWorkPerNumberTests` and `CombinedCatalogTests`: every supported website
/// numbers its works the same way, so a number is one saved work.
void main() {
  test('test build copies fold into the latest saved work', () {
    final db = SqlDatabase.inMemory();
    AppDatabase.migrator.migrate(db, upTo: 'v13_work_site');
    // The tables as those test builds left them.
    db.write((db) {
      db.execute('''
        CREATE TABLE works_identity (
          id INTEGER PRIMARY KEY AUTOINCREMENT, gallery_id INTEGER NOT NULL,
          title TEXT, artists TEXT, language TEXT, type TEXT, series TEXT, groups TEXT, tags TEXT, note TEXT,
          bookmarked_at TEXT NOT NULL, published_at TEXT, last_opened_at TEXT, updated_at TEXT, metadata_source TEXT,
          catalog_matched BOOLEAN NOT NULL DEFAULT 0, thumb_status TEXT NOT NULL DEFAULT 'missing', thumb_path TEXT,
          thumb_failed_at TEXT, thumb_page INTEGER DEFAULT 1, site TEXT);
        DROP TABLE works;
        ALTER TABLE works_identity RENAME TO works;
        CREATE UNIQUE INDEX idx_works_identity ON works(gallery_id, COALESCE(site, ''));
        DROP TABLE refresh_queue;
        CREATE TABLE refresh_queue (work_id INTEGER PRIMARY KEY NOT NULL);
        INSERT INTO folders (id, name, created_at) VALUES (10, 'A', '2024-01-01'), (11, 'B', '2024-01-01');
        INSERT INTO works (id, gallery_id, title, note, bookmarked_at, last_opened_at, site, thumb_status, thumb_path)
          VALUES (5, 100, 'Older', 'mine', '2024-01-01', '2024-03-01', 'one.example', 'ready', '/older.jpg'),
                 (6, 100, 'Newer', NULL, '2024-02-01', NULL, 'two.example', 'missing', NULL),
                 (7, 200, 'Alone', NULL, '2024-01-05', NULL, NULL, 'missing', NULL);
        INSERT INTO folder_works VALUES (10, 5, '2024-01-01'), (10, 6, '2024-02-01'), (11, 5, '2024-01-03'), (10, 7, '2024-01-05');
        INSERT INTO refresh_queue VALUES (5), (7);
      ''');
    });
    AppDatabase.migrator.migrate(db);
    final works = db.rows('SELECT * FROM works ORDER BY gallery_id');
    expect(works, hasLength(2));
    final kept = works.first;
    expect(kept['id'], 6, reason: 'The latest saved copy stays');
    expect(kept['title'], 'Newer');
    expect(kept['note'], 'mine', reason: 'What it lacked comes from the older copy');
    expect(kept['last_opened_at'], '2024-03-01');
    expect(kept['thumb_path'], '/older.jpg');
    expect(kept['site'], 'two.example');
    final links = db.rows('SELECT folder_id, added_at FROM folder_works WHERE work_id = 6 ORDER BY folder_id');
    expect([for (final link in links) link['folder_id']], [10, 11], reason: 'The work stays in every folder it was in, once each');
    expect([for (final link in links) link['added_at']], ['2024-02-01', '2024-01-03'], reason: 'A folder keeps the latest save');
    expect(db.column<int>('SELECT gallery_id FROM refresh_queue').toSet(), {100, 200}, reason: 'The refresh queue names numbers again');
    expect(db.exists("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'idx_works_identity')"), isFalse);
    expect(
      () => db.execute("INSERT INTO works (gallery_id, bookmarked_at, site) VALUES (100, '2024-04-01', 'three.example')"),
      throwsA(anything),
      reason: 'A number is one work again',
    );
  });

  test('a library without test build copies is left as it was', () {
    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 1, title: 'One', site: 'one.example');
    database.upsertWork(galleryId: 1, title: 'Again', site: 'two.example');
    expect(database.dbWriter.read((db) => db.value<int>('SELECT COUNT(*) FROM works')), 1, reason: 'Saving from another website is the same work');
    expect(database.getWork(1)?.site, 'one.example', reason: 'It keeps the website it was first saved from');
  });

  test('saving again to a folder keeps the latest save', () {
    final database = AppDatabase.inMemory();
    final first = database.createFolder(name: 'First'), second = database.createFolder(name: 'Second');
    database.upsertWork(galleryId: 3, folderId: first.id);
    database.addWork(3, second.id!);
    String? addedAt(int folder) => database.dbWriter.read((db) => db.value<String>('SELECT added_at FROM folder_works WHERE folder_id = ?', [folder]));
    database.dbWriter.write((db) => db.execute("UPDATE folder_works SET added_at = '2000-01-01T00:00:00Z' WHERE folder_id = ?", [second.id]));
    database.addWork(3, second.id!);
    expect(addedAt(second.id!), isNot('2000-01-01T00:00:00Z'), reason: 'Saved again, it takes the newer date');
    expect(
      database.dbWriter.read((db) => db.value<int>('SELECT COUNT(*) FROM folder_works WHERE work_id = (SELECT id FROM works WHERE gallery_id = 3)')),
      2,
      reason: 'One link per folder',
    );
  });

  group('combined catalog', () {
    NativeGallery work(int id, String title) =>
        NativeGallery(id: id, title: title, artists: const ['artist'], language: 'korean', type: 'manga', tags: const [], pages: const []);

    test('works from every website are taken in turn and a number is shown once', () async {
      final sources = {
        'a.example.org': _Source([work(1, 'One'), work(2, 'Two'), work(3, 'Three')]),
        'b.example.org': _Source([work(9001, 'Elsewhere'), work(2, 'Two, listed again'), work(9002, 'Also elsewhere')]),
      };
      final catalog = CombinedCatalog(pageSize: 2, sourceFor: (site) => sources[site]!);
      const sites = ['a.example.org', 'b.example.org'];
      final first = await catalog.list(const GalleryQuery(), sites: sites, offset: 0, count: 3);
      expect(first.items, const [FeedItem(1, 'a.example.org'), FeedItem(9001, 'b.example.org'), FeedItem(2, 'a.example.org')]);
      expect(first.hasMore, isTrue);
      final rest = await catalog.list(const GalleryQuery(), sites: sites, offset: 3, count: 10);
      expect(rest.items, const [
        FeedItem(3, 'a.example.org'),
        FeedItem(9002, 'b.example.org'),
      ], reason: "The second website's copy of a number already shown is left out");
      expect(rest.hasMore, isFalse);
      expect(catalog.leftOut, 1);
      final again = await catalog.list(const GalleryQuery(), sites: sites, offset: 3, count: 10);
      expect(again.items, rest.items, reason: 'A page asked for again is answered again the same way');
    });

    test('one website failing leaves the others showing', () async {
      final failing = _Source(const [], failure: ContentError.signInRequired);
      final sources = {
        'a.example.org': _Source([work(1, 'One')]),
        'b.example.org': failing,
      };
      final catalog = CombinedCatalog(sourceFor: (site) => sources[site]!);
      final batch = await catalog.list(const GalleryQuery(), sites: const ['a.example.org', 'b.example.org'], offset: 0, count: 10);
      expect(batch.items, const [FeedItem(1, 'a.example.org')]);
      final none = CombinedCatalog(sourceFor: (_) => failing);
      expect(none.list(const GalleryQuery(), sites: const ['a.example.org', 'b.example.org'], offset: 0, count: 10), throwsA(ContentError.signInRequired));
    });
  });

  test("requests read another website's saved connection inside its scope", () {
    final previous = ContentPreferences.defaults;
    addTearDown(() => ContentPreferences.defaults = previous);
    final preferences = MemoryPreferences({'manga.site_address': 'indexed.example.org', 'manga.resolved_backend_site': 'https://indexed.example.org/'});
    ContentPreferences.defaults = preferences;
    preferences.set(
      'manga.siteSnapshots',
      '{"keyed.example.org":{"manga.resolved_backend_site":"https://keyed.example.org/","manga.resolved_protocol":"keyed"}}',
    );
    expect(MangaUrls.home, 'https://indexed.example.org/');
    SiteScope.run('keyed.example.org', () {
      expect(MangaUrls.home, 'https://keyed.example.org/');
      expect(MangaUrls.preferences.string('manga.resolved_protocol'), 'keyed');
      MangaUrls.preferences.set('manga.resolved_data_host', 'api.keyed.example.org');
    });
    expect(preferences.string('manga.resolved_data_host'), isNull, reason: "The checked website's connection is untouched");
    expect(preferences.string('manga.siteSnapshots'), contains('api.keyed.example.org'));
  });
}

class _Source extends ContentProviding {
  _Source(List<NativeGallery> works, {this.failure}) : _works = {for (final work in works) work.id: work}, _order = [for (final work in works) work.id];
  final Map<int, NativeGallery> _works;
  final List<int> _order;
  final Object? failure;

  @override
  Future<NativeGallery> gallery(int id) async => _works[id] ?? (throw ContentError.galleryNotFound);
  @override
  Future<GalleryBatch> list(GalleryQuery query, {required int offset, required int count}) async {
    if (failure case final failure?) throw failure;
    return GalleryBatch(ids: _order.skip(offset).take(count).toList(), hasMore: _order.length > offset + count);
  }

  @override
  Future<Uint8List> image(GalleryPage page, {required int galleryID, required bool thumbnail}) async => Uint8List(0);
}
