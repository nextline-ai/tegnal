import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/combined_catalog.dart';
import 'package:tegnal/core/content/content_errors.dart';
import 'package:tegnal/core/content/gallery_content.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/migration/manga_viewer_import.dart';
import 'package:tegnal/core/migration/violet_import.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/storage/library_backup.dart';
import 'package:tegnal/core/storage/work_identity.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/sql_database.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';
import 'package:tegnal/domain/models.dart';

/// Ported from `WorkIdentityTests` and `CombinedCatalogTests`: one number may name a different
/// work on each website, and the library keeps both.
void main() {
  late AppDatabase database;
  setUp(() {
    database = AppDatabase.inMemory();
    WorkIdentity.siblings = (_) => const [];
  });
  tearDown(() => WorkIdentity.siblings = ComicSites.siblings);

  List<Work> rows(int id, [AppDatabase? library]) => (library ?? database).dbWriter.read((db) => WorkIdentity.rows(db, id));

  test('the same number from two websites is two saved works', () {
    final indexed = database.upsertWork(galleryId: 7, title: 'Alpha', artists: 'first', site: 'indexed.example.org');
    final keyed = database.upsertWork(galleryId: 7, title: 'Beta', artists: 'second', site: 'keyed.example.org');
    expect(indexed.id, isNot(keyed.id));
    expect(rows(7), hasLength(2));
    expect(database.getWork(7, site: 'indexed.example.org')?.title, 'Alpha');
    expect(database.getWork(7, site: 'keyed.example.org')?.title, 'Beta');
    expect(database.getWork(7, site: 'other.example.org'), isNull, reason: "Another website's number names another work");

    database.upsertWork(galleryId: 7, title: 'Alpha 2', site: 'indexed.example.org');
    expect(rows(7), hasLength(2));

    database.deleteWork(7, site: 'keyed.example.org');
    expect(rows(7).map((work) => work.title), ['Alpha 2']);
  });

  test('a work whose website is unknown is claimed by the first website that saves it', () {
    database.upsertWork(galleryId: 9, title: 'Imported');
    expect(database.upsertWork(galleryId: 9, site: 'indexed.example.org').site, 'indexed.example.org');
    expect(rows(9), hasLength(1));
    database.upsertWork(galleryId: 9, site: 'keyed.example.org');
    expect(rows(9).map((work) => work.site).toSet(), {'indexed.example.org', 'keyed.example.org'});
  });

  test('websites that number their works the same way share a saved work', () {
    WorkIdentity.siblings = (site) => site == 'mirror.example.org' ? const ['keyed.example.org'] : const [];
    database.upsertWork(galleryId: 11, title: 'Shared', site: 'keyed.example.org');
    expect(database.getWork(11, site: 'mirror.example.org')?.title, 'Shared');
    database.upsertWork(galleryId: 11, title: 'Shared again', site: 'mirror.example.org');
    expect(rows(11), hasLength(1));
  });

  test('saved marks follow the website', () {
    database.upsertWork(galleryId: 1, site: 'indexed.example.org');
    database.upsertWork(galleryId: 2);
    final keys = database.dbWriter.read(SavedWorkKeys.fetch);
    expect(keys.idsOn('indexed.example.org'), {1, 2});
    expect(keys.idsOn('keyed.example.org'), {2}, reason: 'A work whose website is unknown shows as saved everywhere');
  });

  test('the migration keeps every work, folder link and queued refresh', () {
    final db = SqlDatabase.inMemory();
    AppDatabase.migrator.migrate(db, upTo: 'v13_work_site');
    db.write((db) {
      db.execute('''
        INSERT INTO folders (id, name, created_at) VALUES (10, 'Kept', '2024-01-01');
        INSERT INTO works (id, gallery_id, title, bookmarked_at, site, note) VALUES (5, 100, 'Old', '2024-01-01', 'indexed.example.org', 'mine'), (6, 200, 'Other', '2024-01-02', NULL, NULL);
        INSERT INTO folder_works VALUES (10, 5, '2024-01-01'), (10, 6, '2024-01-02');
        INSERT INTO refresh_queue VALUES (200);
        INSERT INTO visual_fingerprints VALUES ('comics', 100, 1, 'd', x'00');
      ''');
    });
    AppDatabase.migrator.migrate(db);
    expect(db.value<int>('SELECT COUNT(*) FROM folder_works WHERE folder_id = 10'), 2);
    expect(db.value<String>('SELECT note FROM works WHERE id = 5'), 'mine');
    expect(db.column<int>('SELECT work_id FROM refresh_queue'), [6]);
    db.execute("INSERT INTO works (gallery_id, title, bookmarked_at, site) VALUES (100, 'New', '2024-02-01', 'keyed.example.org')");
    expect(() => db.execute("INSERT INTO works (gallery_id, bookmarked_at, site) VALUES (100, '2024-02-01', 'keyed.example.org')"), throwsA(anything),
        reason: 'A number and website stay unique');
    expect(() => db.execute("INSERT INTO works (gallery_id, bookmarked_at) VALUES (200, '2024-02-01')"), throwsA(anything),
        reason: 'So does a number whose website is unknown');
    db.execute('DELETE FROM works WHERE id = 5');
    expect(db.value<int>('SELECT COUNT(*) FROM visual_fingerprints'), 1, reason: 'Another work under the number still uses the fingerprint');
    db.execute('DELETE FROM works WHERE gallery_id = 100');
    expect(db.value<int>('SELECT COUNT(*) FROM visual_fingerprints'), 0);
  });

  group('importing again', () {
    late Directory directory;
    setUp(() => directory = Directory.systemTemp.createTempSync('work-identity'));
    tearDown(() => directory.deleteSync(recursive: true));

    String backup(List<(int, int)> articles, {List<(int, String)> groups = const [(1, 'violet_default')]}) {
      final path = '${directory.path}/backup-${articles.length}-${groups.length}.db';
      final db = SqlDatabase.open(path);
      db.write((db) {
        db.execute('''
          CREATE TABLE BookmarkGroup (Id INTEGER PRIMARY KEY, Name TEXT, DateTime TEXT, Description TEXT, Color INTEGER, Gorder INTEGER);
          CREATE TABLE BookmarkArticle (Id INTEGER PRIMARY KEY, Article TEXT, DateTime TEXT, GroupId INTEGER);
        ''');
        for (final (id, name) in groups) {
          db.execute('INSERT INTO BookmarkGroup (Id, Name, Gorder) VALUES (?, ?, ?)', [id, name, id]);
        }
        for (final (index, (article, group)) in articles.indexed) {
          db.execute('INSERT INTO BookmarkArticle VALUES (?, ?, ?, ?)', [index + 1, '$article', '2024-01-0${index % 9 + 1} 10:00:00.000000', group]);
        }
      });
      db.close();
      return path;
    }

    /// An earlier version merged a backup's work into a different saved work under the same
    /// number. Importing the backup again brings it back as its own work, and leaves the works
    /// saved since, and everything already imported, as they were.
    for (final android in [true, false]) {
      test('fills in works an earlier version merged away (${android ? 'Android' : 'iPhone'} backup)', () async {
        final saved = database.upsertWork(galleryId: 500, folderId: database.defaultSaveFolder().id, title: 'Alpha', artists: 'artist a', site: 'keyed.example.org');
        database.upsertWork(galleryId: 501, title: 'Gamma', artists: 'artist c', site: 'indexed.example.org');
        database.upsertWork(galleryId: 502, title: 'Delta', artists: 'artist d', site: 'keyed.example.org');
        database.upsertCatalogBatch(const [
          CatalogWork(id: 500, title: 'Beta', artists: 'artist b', tags: 'tag:one'),
          CatalogWork(id: 501, title: 'Gamma', artists: 'artist c', tags: 'tag:two'),
          CatalogWork(id: 503, title: 'Epsilon', artists: 'artist e', tags: 'tag:three'),
        ]);
        final path = backup(const [(500, 2), (501, 2), (503, 2)], groups: const [(1, 'violet_default'), (2, 'Kept')]);
        Future<void> import() async {
          if (android) {
            await VioletImportService(database).import(path);
          } else {
            MangaViewerImportService(database).importUserDatabase(path);
          }
        }

        // What the earlier version did: the backup's 500 joined the saved Alpha.
        final kept = database.createFolder(name: 'Kept');
        database.addWorkToFolder(saved.id!, kept.id!);

        await import();
        expect(rows(500).map((work) => work.title).toSet(), {'Alpha', 'Beta'}, reason: 'The merged-away work is back');
        expect(database.getWork(500, site: 'keyed.example.org')?.title, 'Alpha');
        final beta = rows(500).firstWhere((work) => work.site == null);
        expect(beta.artists, 'artist b');
        expect(database.getWork(500)?.folders.map((folder) => folder.name), contains('Kept'));
        expect(rows(501), hasLength(1), reason: 'The same work saved since is not doubled');
        expect(rows(501).single.site, 'indexed.example.org');
        expect(rows(502), hasLength(1));
        expect(rows(503).map((work) => work.title), ['Epsilon']);

        final count = database.worksCount();
        await import();
        expect(database.worksCount(), count, reason: 'Importing once more changes nothing');
      });
    }

    test('a backup that says nothing about a work stays with the saved one', () async {
      database.upsertWork(galleryId: 600, title: 'Saved', artists: 'someone', site: 'keyed.example.org');
      await VioletImportService(database).import(backup(const [(600, 1)]));
      expect(rows(600), hasLength(1));
    });
  });

  test('backups keep two works under one number', () {
    database.upsertWork(galleryId: 700, title: 'Alpha', site: 'indexed.example.org');
    database.upsertWork(galleryId: 700, title: 'Beta', site: 'keyed.example.org');
    final backup = MangaBackup.capture(database)..validate();
    final restored = AppDatabase.inMemory();
    restored.dbWriter.write((db) => backup.restore(db, restored));
    expect(rows(700, restored).map((work) => work.title).toSet(), {'Alpha', 'Beta'});
    database.dbWriter.write((db) => backup.restore(db, database));
    expect(rows(700), hasLength(2), reason: 'Restoring into the same library adds nothing');
  });

  test('sync carries both works under one number and their folders', () {
    LibrarySyncAdapter adapter() {
      final preferences = AppPreferences.memory();
      return LibrarySyncAdapter(
        manga: AppDatabase.inMemory(preferences: preferences),
        booru: BooruStore.inMemory(preferences: preferences),
        mangaDefaults: preferences.defaults,
        booruDefaults: preferences.booruDefaults,
      );
    }

    void exchange(LibrarySyncAdapter a, LibrarySyncAdapter b, LibrarySyncLedger la, LibrarySyncLedger lb) {
      la.capture(a.snapshot(), device: 'A');
      lb.capture(b.snapshot(), device: 'B');
      la.merge(lb.changes);
      lb.merge(la.changes);
      a.apply(la.changes);
      b.apply(lb.changes);
      la.baseline = a.snapshot();
      lb.baseline = b.snapshot();
    }

    final a = adapter(), b = adapter();
    final folder = a.manga.createFolder(name: 'Art');
    a.manga.upsertWork(galleryId: 800, folderId: folder.id, title: 'Alpha', site: 'indexed.example.org');
    a.manga.upsertWork(galleryId: 800, title: 'Beta', site: 'keyed.example.org');
    a.manga.upsertWork(galleryId: 801, title: 'Unknown');
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    expect(rows(800, b.manga).map((work) => '${work.title}@${work.site}').toSet(), {'Alpha@indexed.example.org', 'Beta@keyed.example.org'});
    expect(b.manga.getWork(800, site: 'indexed.example.org')?.folders.map((folder) => folder.name), ['Art']);
    expect(b.manga.getWork(801)?.title, 'Unknown');
    final numberRow = a.snapshot().values.firstWhere((row) => row.table == 'manga.works' && row.values['gallery_id']?.integer == 800);
    expect(numberRow.values['site']?.string, 'indexed.example.org', reason: 'Older versions read one work per number: one with a website');

    final before = Map.of(lb.changes);
    lb.capture(b.snapshot(), device: 'B');
    expect(lb.changes, before, reason: 'Settled: another pass changes nothing');
    a.manga.deleteWork(800, site: 'keyed.example.org');
    exchange(a, b, la, lb);
    expect(rows(800, b.manga).map((work) => work.site), ['indexed.example.org']);
  });

  test('titles are compared without brackets, width or punctuation', () {
    expect(WorkMatcher.normalizedTitle('[Circle (Artist)] Title Here! (Series) [Korean] [Digital]'), 'titlehere');
    expect(WorkMatcher.normalizedTitle('［サークル］ タイトル　ＡＢＣ'), 'タイトルabc');
    final first = WorkMatcher.fingerprint(titles: ['[Circle (Artist)] Title Here [Korean]'], artists: ['artist'], pages: 24);
    final second = WorkMatcher.fingerprint(titles: ['(C99) [Circle (Artist)] Title Here [Korean] [Digital]'], artists: ['Artist'], pages: 25);
    expect(WorkMatcher.isSameWork(first, second), isTrue);
    expect(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ['Title Here'], artists: ['artist'], pages: 40)), isFalse);
    expect(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ['Title Here'], artists: ['someone else'], pages: 24)), isFalse);
    expect(WorkMatcher.isSameWork(first, WorkMatcher.fingerprint(titles: ['Title Here'], artists: const [], pages: 0)), isTrue);
  });

  group('combined catalog', () {
    NativeGallery work(int id, String title, {int pages = 20}) =>
        NativeGallery(id: id, title: title, artists: const ['artist'], language: 'korean', type: 'manga', tags: const [], pages: const [], listedPageCount: pages);

    test('works from every website are taken in turn and twins are left out', () async {
      final sources = {
        'indexed.example.org': _Source([work(1, '[Circle (Artist)] Same Work [Korean]', pages: 30), work(2, 'Only Here'), work(3, 'Third')]),
        'keyed.example.org': _Source([work(9001, '(C100) [Circle (Artist)] Same Work [Korean] [Digital]', pages: 31), work(9002, 'Elsewhere'), work(2, 'Different Work, Same Number')]),
      };
      final catalog = CombinedCatalog(pageSize: 2, sourceFor: (site) => sources[site]!, sharesNumbers: (a, b) => a == b);
      const sites = ['indexed.example.org', 'keyed.example.org'];
      final first = await catalog.list(const GalleryQuery(), sites: sites, offset: 0, count: 3);
      expect(first.items, const [FeedItem(1, 'indexed.example.org'), FeedItem(9002, 'keyed.example.org'), FeedItem(2, 'indexed.example.org')]);
      expect(first.hasMore, isTrue);
      final rest = await catalog.list(const GalleryQuery(), sites: sites, offset: 3, count: 10);
      expect(rest.items, const [FeedItem(2, 'keyed.example.org'), FeedItem(3, 'indexed.example.org')]);
      expect(rest.hasMore, isFalse);
      expect(catalog.leftOut, 1);
      final again = await catalog.list(const GalleryQuery(), sites: sites, offset: 3, count: 10);
      expect(again.items, rest.items, reason: 'A page asked for again is answered again the same way');
    });

    test('websites that share numbers show each work once', () async {
      final sources = {'a.example.org': _Source([work(5, 'One'), work(6, 'Two')]), 'b.example.org': _Source([work(5, 'One, another title'), work(7, 'Three')])};
      final catalog = CombinedCatalog(sourceFor: (site) => sources[site]!, sharesNumbers: (_, _) => true);
      final batch = await catalog.list(const GalleryQuery(), sites: const ['a.example.org', 'b.example.org'], offset: 0, count: 10);
      expect(batch.items.map((item) => item.id), [5, 7, 6]);
    });

    test('one website failing leaves the others showing', () async {
      final failing = _Source(const [], failure: ContentError.signInRequired);
      final sources = {'a.example.org': _Source([work(1, 'One')]), 'b.example.org': failing};
      final catalog = CombinedCatalog(sourceFor: (site) => sources[site]!, sharesNumbers: (a, b) => a == b);
      final batch = await catalog.list(const GalleryQuery(), sites: const ['a.example.org', 'b.example.org'], offset: 0, count: 10);
      expect(batch.items, const [FeedItem(1, 'a.example.org')]);
      final none = CombinedCatalog(sourceFor: (_) => failing, sharesNumbers: (a, b) => a == b);
      expect(none.list(const GalleryQuery(), sites: const ['a.example.org', 'b.example.org'], offset: 0, count: 10), throwsA(ContentError.signInRequired));
    });
  });

  test("requests read another website's saved connection inside its scope", () {
    final previous = ContentPreferences.defaults;
    addTearDown(() => ContentPreferences.defaults = previous);
    final preferences = MemoryPreferences({'manga.site_address': 'indexed.example.org', 'manga.resolved_backend_site': 'https://indexed.example.org/'});
    ContentPreferences.defaults = preferences;
    preferences.set('manga.siteSnapshots', '{"keyed.example.org":{"manga.resolved_backend_site":"https://keyed.example.org/","manga.resolved_protocol":"keyed"}}');
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
