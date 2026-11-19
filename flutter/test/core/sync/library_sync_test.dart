import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/reading_queue.dart';
import 'package:tegnal/core/content/recent_works.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/study/study_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import '../../support/backup_fixtures.dart';
import '../booru/booru_backup_test.dart' show awardRows, seedGame;

/// Ported from `LibrarySyncTests` (the record, ledger and adapter cases).
void main() {
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

  test('recent works and images merge entry by entry through sync rows', () {
    final a = adapter(), b = adapter(), server = presetServer();
    final covers = Directory.systemTemp.createTempSync('tegnal-recent-');
    addTearDown(() => covers.deleteSync(recursive: true));
    RecentWork work(int id, int seconds) => RecentWork(
      item: ReadingQueueItem(id: id, title: 'Work $id', artists: '', details: ''),
      openedAt: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      tags: const ['tag'],
    );
    a.booru.saveServer(server);
    b.booru.saveServer(BooruServer(id: 'peer-server', name: server.name, baseURL: server.baseURL, engine: server.engine));
    final worksA = RecentWorks(a.mangaDefaults, covers: covers), worksB = RecentWorks(b.mangaDefaults, covers: covers);
    worksA.opened(work(1, 100));
    worksB.opened(work(2, 200));
    RecentImages(a.booruDefaults).opened(fixturePost(72, server), at: DateTime.fromMillisecondsSinceEpoch(150000));
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    expect(RecentWork.stored(a.mangaDefaults).map((entry) => entry.id), [2, 1], reason: 'Opens on both devices merge, newest first');
    expect(RecentWork.stored(b.mangaDefaults).map((entry) => entry.id), [2, 1]);
    final image = RecentImage.stored(b.booruDefaults).single;
    expect(image.post.serverID, 'peer-server', reason: "An image lands on the peer's own copy of the server");
    expect(image.post.postID, 72);
    expect(image.openedAt, DateTime.fromMillisecondsSinceEpoch(150000));

    // Reopening moves a work up everywhere; removing it removes it everywhere.
    worksB
      ..reload()
      ..opened(work(1, 300));
    exchange(a, b, la, lb);
    worksA.reload();
    expect(worksA.entries.map((entry) => entry.id), [1, 2]);
    expect(worksA.entries.first.openedAt, DateTime.fromMillisecondsSinceEpoch(300000));
    worksA.remove(2);
    exchange(a, b, la, lb);
    expect(RecentWork.stored(b.mangaDefaults).map((entry) => entry.id), [1]);
    expect(RecentWork.merged([work(1, 1), work(2, 3), work(1, 5), work(3, 4)], 2).map((entry) => entry.id), [1, 3]);
  });

  test('values and rows encode like Swift Codable', () {
    expect(encodeJsonString(const SyncValue.text('a/b').toJson()), r'{"text":{"_0":"a\/b"}}');
    expect(encodeJsonString(SyncValue.null_.toJson()), '{"null":{}}');
    expect(SyncValue.fromJson(SyncValue.blob([1, 2, 3]).toJson()), SyncValue.blob([1, 2, 3]));
    final row = LibrarySyncRow(table: 'manga.saved_searches', values: {'query': const SyncValue.text('sky')});
    expect(row.key, startsWith('manga.saved_searches:'));
    expect(LibrarySyncRow.fromJson(decodeJsonValue(encodeJson(row.toJson()))), row);
  });

  test('binary property lists round-trip preference values', () {
    for (final value in <Object>[
      true,
      false,
      0,
      255,
      65536,
      -3,
      1.5,
      'ko',
      '한국어',
      <String>['a', 'b'],
      Uint8List.fromList([1, 2]),
    ]) {
      final decoded = (BinaryPropertyList.decode(BinaryPropertyList.encode({'value': value})) as Map)['value'];
      expect(decoded, value);
    }
  });

  test('historical imported folder sync normalizes metadata without losing identity', () {
    final source = adapter(), destination = adapter();
    source.manga.createFolder(name: 'Imported folder', sourceGroupId: 42);
    final row = source.snapshot().values.firstWhere((row) => row.table == 'manga.folders' && row.values['name']?.string == 'Imported folder').copy();
    row.values['legacy_group_id'] = row.values.remove('source_group_id')!;
    final change = LibrarySyncChange(row: row, timestamp: 100, device: 'historical', deleted: false);
    final changes = {row.key: change};
    destination.apply(changes);
    expect(destination.manga.listFolders().firstWhere((folder) => folder.name == 'Imported folder').sourceGroupId, 42);
    final normalized = LibrarySyncAdapter.mediaFreeChanges(changes)[row.key]!;
    expect(normalized.row.values['source_group_id']?.integer, 42);
    expect(normalized.row.values['legacy_group_id'], isNull);
    expect(normalized.timestamp, change.timestamp);
    expect(normalized.row.key, row.key);
  });

  test('smart folder rules follow every edit on both libraries', () {
    final a = adapter(), b = adapter();
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    final kept = a.manga.createFolder(name: 'Kept'), korean = a.manga.createFolder(name: 'Korean');
    final source = a.manga.identityOfFolder(kept.id!), identity = a.manga.identityOfFolder(korean.id!);
    final scenery = a.booru.saveFolder(name: 'Scenery');
    final comic = FolderRule(folder: identity, query: 'language:korean', excluded: 'tag:spoiler', sources: [source]);
    final image = FolderRule(folder: scenery, query: 'mountain', excluded: 'night', includesOtherFolders: true);
    a.manga.saveRule(comic);
    a.booru.saveRule(image);
    exchange(a, b, la, lb);
    b.booru.refresh();
    expect(b.manga.rule(identity), comic);
    expect(b.booru.rule(scenery), image);
    expect(b.manga.listFolders().firstWhere((folder) => folder.name == 'Korean').isSmart, isTrue);

    b.manga.saveRule(FolderRule(folder: identity, query: 'language:korean', excluded: 'tag:spoiler', sources: [source], isEnabled: false));
    exchange(a, b, la, lb);
    expect(a.manga.listFolders().firstWhere((folder) => folder.name == 'Korean').isSmart, isFalse);
    expect(a.manga.rule(identity)?.excluded, 'tag:spoiler');

    a.manga.deleteRule(identity);
    a.booru.deleteRule(scenery);
    exchange(a, b, la, lb);
    expect(b.manga.rule(identity), isNull);
    expect(b.booru.rule(scenery), isNull);
  });

  test('edits to different smart folders merge instead of overwriting each other', () {
    final a = adapter(), b = adapter();
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    final one = a.manga.identityOfFolder(a.manga.createFolder(name: 'First').id!);
    final two = a.manga.identityOfFolder(a.manga.createFolder(name: 'Second').id!);
    a.manga.saveRule(FolderRule(folder: one, query: 'tag:one'));
    a.manga.saveRule(FolderRule(folder: two, query: 'tag:two'));
    exchange(a, b, la, lb);
    a.manga.saveRule(FolderRule(folder: one, query: 'tag:one-edited'));
    b.manga.saveRule(FolderRule(folder: two, query: 'tag:two-edited'));
    exchange(a, b, la, lb);
    for (final side in [a, b]) {
      expect(side.manga.rule(one)?.query, 'tag:one-edited');
      expect(side.manga.rule(two)?.query, 'tag:two-edited');
    }
  });

  test('default save folder and smart folder switch sync by identity', () {
    final a = adapter(), b = adapter();
    final inbox = a.manga.createFolder(name: 'Inbox');
    a.mangaDefaults.set(LibrarySavePreferences.legacyDefaultFolderKey, inbox.id);
    a.mangaDefaults.set(LibrarySavePreferences.rulesEnabledKey, false);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    expect(b.mangaDefaults.string(LibrarySavePreferences.defaultFolderKey), a.manga.identityOfFolder(inbox.id!));
    expect(b.mangaDefaults.boolean(LibrarySavePreferences.rulesEnabledKey), isFalse);
  });

  test('snapshot cache reuses an idle library and includes edits and preferences', () {
    final a = adapter(), cache = LibrarySyncSnapshotCache();
    cache.snapshot(a);
    final first = cache.snapshot(a);
    final warmed = cache.snapshotCount;
    expect(rowsEquality.equals(cache.snapshot(a), first), isTrue);
    expect(cache.snapshotCount, warmed);
    a.manga.upsertWork(galleryId: 123, title: 'New work');
    expect(cache.snapshot(a).values.any((row) => row.table == 'manga.works' && row.values['gallery_id'] == const SyncValue.integer(123)), isTrue);
    a.mangaDefaults.set('app.language', 'ko');
    expect(cache.snapshot(a).values.any((row) => row.table == 'preferences.manga' && row.values['key'] == const SyncValue.text('app.language')), isTrue);
    a.manga.deleteWork(123);
    expect(cache.snapshot(a).values.any((row) => row.table == 'manga.works'), isFalse);
  });

  test('preferences, connection and reset sync without device settings', () {
    final a = adapter(), b = adapter();
    a.mangaDefaults.set('site_verified', true);
    a.mangaDefaults.set('app.language', 'ja');
    a.mangaDefaults.set('drive.librarySyncEnabled', false);
    a.booruDefaults.set('reader.translationLanguage', 'en');
    a.booruDefaults.set('grid_columns', 5);
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    expect(b.mangaDefaults.boolean('site_verified'), isTrue);
    expect(b.mangaDefaults.string('app.language'), 'ja');
    expect(b.booruDefaults.string('reader.translationLanguage'), 'en');
    expect(b.mangaDefaults.object('drive.librarySyncEnabled'), isNull);
    expect(b.booruDefaults.object('grid_columns'), isNull);
    a.mangaDefaults.remove('app.language');
    exchange(a, b, la, lb);
    expect(b.mangaDefaults.object('app.language'), isNull);
  });

  test('a folder color from a device on the earlier palette arrives vivid', () {
    final a = adapter(), b = adapter();
    final folder = a.manga.createFolder(name: 'Older').id!;
    final image = a.booru.saveFolder(name: 'Older images');
    // A device still on 1.5.1 keeps the earlier palette's colors.
    a.manga.setFolderColor(folder, 0xFF0D9488);
    a.booru.setFolderColor(image, 0xFFE11D48);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    b.booru.refresh();
    expect(b.manga.listFolders().firstWhere((folder) => folder.name == 'Older').color, 0xFF00897B);
    expect(b.booru.folders().firstWhere((folder) => folder.id == image).color, 0xFFE3122C);
  });

  test('comics folder rename, color and order converge across devices', () {
    final a = adapter(), b = adapter();
    final first = a.manga.createFolder(name: 'First').id!, second = a.manga.createFolder(name: 'Second').id!;
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    a.manga.renameFolder(first, 'Renamed');
    a.manga.setFolderColor(first, 0xFF8E4BFF);
    a.manga.reorderFolders([second, first]);
    exchange(a, b, la, lb);
    expect(b.manga.listFolders().map((folder) => folder.name).take(2), ['Second', 'Renamed']);
    expect(b.manga.listFolders().firstWhere((folder) => folder.name == 'Renamed').color, 0xFF8E4BFF);
    final before = Map.of(lb.changes);
    lb.capture(b.snapshot(), device: 'B');
    expect(changesEquality.equals(lb.changes, before), isTrue);
  });

  test('a persisted ledger rejects a stale peer after an offline delete and restart', () {
    final a = adapter(), b = adapter();
    a.manga.upsertWork(galleryId: 42, title: 'Saved');
    var la = LibrarySyncLedger();
    final lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    final stale = Map.of(lb.changes);
    a.manga.deleteWork(42);
    la.capture(a.snapshot(), device: 'A');
    la = LibrarySyncLedger.fromJson(decodeJsonValue(encodeJson(la.toJson(), escapingSlashes: false)));
    la.merge(stale);
    a.apply(la.changes);
    expect(a.manga.getWork(42), isNull);
    lb.merge(la.changes);
    b.apply(lb.changes);
    expect(b.manga.getWork(42), isNull);
  });

  test('concurrent folder removal keeps newly saved works', () {
    final a = adapter(), b = adapter();
    final folder = a.manga.createFolder(name: 'Reading');
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    final other = b.manga.listFolders().firstWhere((folder) => folder.name == 'Reading');
    b.manga.upsertWork(galleryId: 99, folderId: other.id);
    a.manga.dbWriter.write((db) => db.execute('DELETE FROM folders WHERE id = ?', [folder.id]));
    exchange(a, b, la, lb);
    expect(b.manga.getWork(99)?.folders.first.name, '미분류');
  });

  test('cloud snapshot excludes embedded media and preserves the site folder', () {
    final a = adapter(), b = adapter(), server = presetServer();
    a.booru.saveServer(server);
    final post = fixturePost(42, server)
      ..previewURL = 'data:image/png;base64,${'A' * 100000}'
      ..sampleURL = 'file:///private/local-image.jpg'
      ..fileURL = 'https://example.com/image.jpg';
    a.booru.saveFavorite(post);
    final row = a.snapshot().values.firstWhere((row) => row.table == 'booru.favorites');
    final saved = BooruPost.fromJson(decodeJsonObject(row.values['payload']!.data!));
    expect(saved.previewURL, isNull);
    expect(saved.sampleURL, isNull);
    expect(saved.fileURL, post.fileURL);
    expect(row.values['payload']!.data!.length, lessThan(5000));
    final oldRow = row.copy()..values['payload'] = SyncValue.blob(encodeSwiftJson(post.toJson()));
    final cleaned = LibrarySyncAdapter.mediaFreeChanges({
      oldRow.key: LibrarySyncChange(row: oldRow, timestamp: 123, device: 'old', deleted: false),
    })[oldRow.key]!;
    expect(cleaned.timestamp, 123);
    expect(cleaned.row.key, oldRow.key);
    expect(BooruPost.fromJson(decodeJsonObject(cleaned.row.values['payload']!.data!)).previewURL, isNull);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    b.booru.refresh();
    final restored = b.booru.favorites(b.booru.servers.map((server) => server.id).toList()).first;
    expect(b.booru.folderIDFor(restored), 'site:${server.canonicalAddress}');
  });

  test('two devices merge folders, works and settings with offline deletion and no local paths', () {
    final a = adapter(), b = adapter();
    final fa = a.manga.createFolder(name: 'Art'), fb = b.manga.createFolder(name: 'Reading');
    expect(fa.id, fb.id);
    a.manga.upsertWork(galleryId: 100, folderId: fa.id, title: 'First');
    b.manga.upsertWork(galleryId: 200, folderId: fb.id, title: 'Second');
    a.manga.setThumb(100, 'ready', path: '/private/device-a/cover.jpg');
    a.mangaDefaults.set('grid_columns', 5);
    a.mangaDefaults.set('manga.defaultTags', 'tag:landscape');
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    expect(a.manga.worksCount(), 2);
    expect(b.manga.worksCount(), 2);
    expect(b.manga.getWork(100)?.folders.first.name, 'Art');
    expect(b.manga.getWork(100)?.thumbPath, isNull);
    expect(b.mangaDefaults.object('grid_columns'), isNull);
    expect(b.mangaDefaults.string('manga.defaultTags'), 'tag:landscape');
    a.manga.deleteWork(100);
    b.manga.upsertWork(galleryId: 300, folderId: fb.id);
    exchange(a, b, la, lb);
    expect(b.manga.getWork(100), isNull);
    expect(a.manga.getWork(300), isNotNull);
    final old = Map.of(la.changes);
    la.capture(a.snapshot(), device: 'A');
    expect(changesEquality.equals(old, la.changes), isTrue, reason: 'Applying remote records must not create an endless echo');
  });

  test('the site a work was saved from syncs and an unknown column does not turn the row away', () {
    final a = adapter(), b = adapter();
    final folder = a.manga.createFolder(name: 'Art');
    a.manga.upsertWork(galleryId: 100, folderId: folder.id, title: 'First', site: 'comics-older.net');
    b.manga.upsertWork(galleryId: 200, title: 'Second');
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    expect(b.manga.getWork(100)?.site, 'comics-older.net');
    expect(a.manga.getWork(200)?.site, isNull);

    // A peer that never learned the site sends it empty, and a newer version adds a column.
    final known = LibrarySyncRow(
      table: 'manga.works',
      values: {
        'gallery_id': const SyncValue.integer(100),
        'title': const SyncValue.text('Renamed'),
        'bookmarked_at': const SyncValue.real(1),
        'site': SyncValue.null_,
      },
    );
    final later = LibrarySyncRow(
      table: 'manga.works',
      values: {
        'gallery_id': const SyncValue.integer(300),
        'title': const SyncValue.text('Third'),
        'bookmarked_at': const SyncValue.real(1),
        'site': const SyncValue.text('comics-newer.net'),
        'a_later_column': const SyncValue.text('value'),
      },
    );
    final changes = {
      known.key: LibrarySyncChange(row: known, timestamp: 100, device: 'C', deleted: false),
      later.key: LibrarySyncChange(row: later, timestamp: 100, device: 'C', deleted: false),
    };
    b.apply(changes);
    expect(b.manga.getWork(100)?.title, 'Renamed');
    expect(b.manga.getWork(100)?.site, 'comics-older.net', reason: 'An empty value never clears a known site');
    expect(b.manga.getWork(300)?.site, 'comics-newer.net', reason: 'The columns this version knows are still saved');
    final ledger = LibrarySyncLedger()..merge({later.key: changes[later.key]!});
    expect(ledger.changes[later.key]?.row.values['a_later_column']?.string, 'value', reason: 'The record passes the column on unchanged');
  });

  test("an older device's folders and images settle into their servers", () {
    final a = adapter(), b = adapter();
    final danbooru = BooruServer(id: 'd', name: 'Danbooru', baseURL: 'https://danbooru.donmai.us', engine: BooruEngine.danbooru);
    final gelbooru = BooruServer(id: 'g', name: 'Gelbooru', baseURL: 'https://gelbooru.com', engine: BooruEngine.gelbooru);
    a.booru.saveServer(danbooru);
    a.booru.saveServer(gelbooru);
    final cats = a.booru.saveFolder(name: 'Cats', serverID: danbooru.id);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    // A version from before folder ownership sends folders without a server, the shared
    // Uncategorized, and images of one server put into another server's folder.
    LibrarySyncRow favorite(int id, BooruServer server, String folder) => LibrarySyncRow(
      table: 'booru.favorites',
      values: {
        'server_id': SyncValue.text(server.canonicalAddress),
        'post_id': SyncValue.integer(id),
        'payload': SyncValue.blob(encodeSwiftJson(fixturePost(id, server).onServer(server.canonicalAddress).toJson())),
        'saved_at': SyncValue.real(DateTime.now().millisecondsSinceEpoch / 1000),
        'folder_id': SyncValue.text(folder),
      },
    );
    final rows = [
      LibrarySyncRow(
        table: 'booru.folders',
        values: const {
          'id': SyncValue.text('older'),
          'name': SyncValue.text('From an older version'),
          'color': SyncValue.integer(4278239976),
          'position': SyncValue.integer(9),
        },
      ),
      LibrarySyncRow(
        table: 'booru.folders',
        values: const {'id': SyncValue.text('unsorted'), 'name': SyncValue.text(''), 'color': SyncValue.integer(4284922736), 'position': SyncValue.integer(0)},
      ),
      favorite(1, gelbooru, cats),
      favorite(2, danbooru, 'unsorted'),
      favorite(3, gelbooru, 'older'),
    ];
    final later = DateTime.now().millisecondsSinceEpoch / 1000 + 10;
    b.apply({for (final row in rows) row.key: LibrarySyncChange(row: row, timestamp: later, device: 'old', deleted: false)});
    b.booru.refresh();
    final local = {for (final server in b.booru.servers) server.canonicalAddress: server.id};
    final gelbooruHere = local[gelbooru.canonicalAddress]!, danbooruHere = local[danbooru.canonicalAddress]!;
    expect(b.booru.folder('unsorted'), isNull, reason: 'the shared Uncategorized never comes back');
    expect(b.booru.folder('older')?.serverID, isNull, reason: 'a folder an older version made is global');
    expect(b.booru.folderIDFor(fixturePost(3, gelbooru).onServer(gelbooruHere)), 'older');
    expect(b.booru.folderIDFor(fixturePost(2, danbooru).onServer(danbooruHere)), 'site:${danbooru.canonicalAddress}');
    final copy = b.booru.folderIDFor(fixturePost(1, gelbooru).onServer(gelbooruHere));
    expect(copy, '$cats@${gelbooru.canonicalAddress}', reason: "Gelbooru's image put in Danbooru's folder goes to Gelbooru's folder of that name");
    expect(b.booru.folder(copy!)?.plainName, 'Cats');
    expect(b.booru.folder(copy)?.serverID, gelbooruHere);
  });

  test('an image saved into a folder another device removes stays saved in its uncategorized', () {
    final a = adapter(), b = adapter();
    final server = presetServer();
    a.booru.saveServer(server);
    final folder = a.booru.saveFolder(name: 'Later', serverID: server.id);
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    b.booru.refresh();
    final value = fixturePost(83, b.booru.servers.single);
    b.booru.saveFavorite(value, folderID: folder);
    a.booru.deleteFolder(folder);
    la.capture(a.snapshot(), device: 'A');
    b.apply(la.changes);
    expect(b.booru.isFavorite(value), isTrue);
    expect(b.booru.folderIDFor(value), 'site:${server.canonicalAddress}');
    expect(b.booru.folder(folder), isNull);
  });

  test('a server added by hand syncs as user data with its folder order', () {
    final a = adapter(), b = adapter();
    final server = presetServer();
    a.booru.saveServer(server);
    final folder = a.booru.saveFolder(name: 'Favorites', color: 0xFF4A3DFF, serverID: server.id);
    a.booru.reorderFolders([folder, 'site:${server.canonicalAddress}']);
    final post = fixturePost(101, server);
    a.booru.saveFavorite(post, folderID: folder);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    b.booru.refresh();
    expect(b.booru.servers.map((server) => server.canonicalAddress), [server.canonicalAddress]);
    final local = b.booru.servers.single;
    expect(b.booru.folderIDFor(post.onServer(local.id)), folder);
    expect(b.booru.folders().first.id, folder);
    expect(b.booru.folder(folder)?.serverID, local.id, reason: "a folder reaches the other device as its server's");
    expect(a.snapshot().values.firstWhere((row) => row.table == 'booru.servers').isFactoryDefault, isFalse);
  });

  test('a fresh device does not overwrite an existing default folder color', () {
    final a = adapter(), b = adapter();
    final folder = a.manga.listFolders().first.id!;
    a.manga.setFolderColor(folder, 0xFF8E4BFF);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    expect(b.manga.listFolders().first.color, 0xFF8E4BFF);
  });

  test('a delete tombstone keeps only the key and documents round-trip', () {
    final a = adapter();
    a.manga.upsertWork(galleryId: 90, title: 'Private title');
    final ledger = LibrarySyncLedger()..capture(a.snapshot(), device: 'A');
    a.manga.deleteWork(90);
    ledger.capture(a.snapshot(), device: 'A');
    final deletion = ledger.changes.values.firstWhere((change) => change.deleted && change.row.table == 'manga.works');
    expect(deletion.row.values.keys.toSet(), {'gallery_id'});
    final data = LibrarySyncDocument(changes: ledger.changes).encode();
    expect(changesEquality.equals(LibrarySyncDocument.decode(data).changes, ledger.changes), isTrue);
  });

  test('learning mode travels between devices and merges by their rules', () {
    final a = adapter(), b = adapter();
    seedGame(a.booru, day: '2026-11-01', xp: 40, answered: 3, lesson: ('l1', 3, 2, 500), award: ('first', 100, 0), stat: ('best', 9));
    seedGame(a.booru, day: '2026-11-02', xp: 5);
    seedGame(b.booru, day: '2026-11-01', xp: 70, answered: 1, lesson: ('l1', 1, 5, 900), award: ('first', 300, 1), stat: ('best', 4));
    final rows = a.snapshot().values.where((row) => row.table.startsWith('booru.study_')).toList();
    expect(rows.map((row) => row.table).toSet(), {'booru.study_days', 'booru.study_lessons', 'booru.study_awards', 'booru.study_stats'});
    b.apply({for (final row in rows) row.key: LibrarySyncChange(row: row, timestamp: 100, device: 'A', deleted: false)});
    final days = {for (final day in StudyStore(b.booru).days()) day.day: day};
    expect(days['2026-11-01']?.xp, 70, reason: 'The larger experience of a day stays');
    expect(days['2026-11-01']?.answered, 3);
    expect(days['2026-11-02']?.xp, 5, reason: 'A day only the other device studied arrives with its experience');
    final lesson = b.booru.database.read((db) => db.rows("SELECT * FROM study_lessons WHERE lesson = 'l1'").single);
    expect(lesson['stars'], 3);
    expect(lesson['runs'], 5);
    expect(lesson['finished'], 900);
    final award = awardRows(b.booru).first;
    expect(award['earned'], 100, reason: 'The earlier time stays');
    expect(award['seen'], 1);
    expect(b.booru.database.read((db) => db.value<int>("SELECT value FROM study_stats WHERE name = 'best'")), 9);

    // A badge that arrives new is not celebrated again, and one seen here stays seen.
    final fresh = LibrarySyncRow(
      table: 'booru.study_awards',
      values: {'id': const SyncValue.text('second'), 'earned': const SyncValue.real(50), 'seen': const SyncValue.integer(0)},
    );
    b.apply({fresh.key: LibrarySyncChange(row: fresh, timestamp: 200, device: 'A', deleted: false)});
    expect(awardRows(b.booru).map((row) => row['seen']), [1, 1]);
    final unseen = LibrarySyncRow(
      table: 'booru.study_awards',
      values: {'id': const SyncValue.text('first'), 'earned': const SyncValue.real(400), 'seen': const SyncValue.integer(0)},
    );
    b.apply({unseen.key: LibrarySyncChange(row: unseen, timestamp: 300, device: 'A', deleted: false)});
    expect(awardRows(b.booru).first['seen'], 1);
    expect(awardRows(b.booru).first['earned'], 100);

    // A row from an older device has no experience column; the day keeps its own.
    final old = LibrarySyncRow(
      table: 'booru.study_days',
      values: {'day': const SyncValue.text('2026-11-01'), 'answered': const SyncValue.integer(1), 'correct': const SyncValue.integer(0)},
    );
    b.apply({old.key: LibrarySyncChange(row: old, timestamp: 400, device: 'A', deleted: false)});
    expect(StudyStore(b.booru).days().firstWhere((day) => day.day == '2026-11-01').xp, 70);

    // Reset is carried like study_progress: removals reach the other device.
    final ledger = LibrarySyncLedger();
    ledger.capture(a.snapshot(), device: 'A', now: 1000);
    StudyStore(a.booru).reset();
    ledger.capture(a.snapshot(), device: 'A', now: 2000);
    final removals = {
      for (final entry in ledger.changes.entries)
        if (entry.value.deleted && entry.value.row.table.startsWith('booru.study_')) entry.key: entry.value,
    };
    expect(removals.values.map((change) => change.row.table).toSet(), {'booru.study_days', 'booru.study_lessons', 'booru.study_awards', 'booru.study_stats'});
    b.apply(removals);
    // "second" reached this device by a row of its own that the other device never held, so only "first" is removed.
    expect(awardRows(b.booru).map((row) => row['id']), ['second']);
    expect(StudyStore(b.booru).days(), isEmpty);
    expect(b.booru.database.read((db) => db.value<int>('SELECT COUNT(*) FROM study_lessons')), 0);
    expect(b.booru.database.read((db) => db.value<int>('SELECT COUNT(*) FROM study_stats')), 0);

    // Rows that break the rules are left out.
    final bad = [
      LibrarySyncRow(
        table: 'booru.study_lessons',
        values: {
          'lesson': const SyncValue.text(''),
          'stars': const SyncValue.integer(1),
          'runs': const SyncValue.integer(1),
          'finished': const SyncValue.real(1),
        },
      ),
      LibrarySyncRow(table: 'booru.study_stats', values: {'name': const SyncValue.text('x'), 'value': const SyncValue.integer(-1)}),
      LibrarySyncRow(
        table: 'booru.study_awards',
        values: {'id': SyncValue.text('x' * 201), 'earned': const SyncValue.real(1), 'seen': const SyncValue.integer(0)},
      ),
    ];
    b.apply({for (final row in bad) row.key: LibrarySyncChange(row: row, timestamp: 500, device: 'A', deleted: false)});
    expect(b.booru.database.read((db) => db.value<int>('SELECT COUNT(*) FROM study_lessons')), 0);
    expect(b.booru.database.read((db) => db.value<int>('SELECT COUNT(*) FROM study_stats')), 0);
    expect(awardRows(b.booru).length, 1);
  });
}
