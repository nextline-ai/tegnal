import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/sync/library_sync_adapter.dart';
import 'package:tegnal/core/sync/library_sync_record.dart';

import '../../support/backup_fixtures.dart';

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

  test('comics folder rename, color and order converge across devices', () {
    final a = adapter(), b = adapter();
    final first = a.manga.createFolder(name: 'First').id!, second = a.manga.createFolder(name: 'Second').id!;
    final la = LibrarySyncLedger(), lb = LibrarySyncLedger();
    exchange(a, b, la, lb);
    a.manga.renameFolder(first, 'Renamed');
    a.manga.setFolderColor(first, 0xFF123456);
    a.manga.reorderFolders([second, first]);
    exchange(a, b, la, lb);
    expect(b.manga.listFolders().map((folder) => folder.name).take(2), ['Second', 'Renamed']);
    expect(b.manga.listFolders().firstWhere((folder) => folder.name == 'Renamed').color, 0xFF123456);
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
      values: {'gallery_id': const SyncValue.integer(100), 'title': const SyncValue.text('Renamed'), 'bookmarked_at': const SyncValue.real(1), 'site': SyncValue.null_},
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

  test('a server added by hand syncs as user data with its folder order', () {
    final a = adapter(), b = adapter();
    final server = presetServer();
    a.booru.saveServer(server);
    final folder = a.booru.saveFolder(name: 'Favorites', color: 0xFF112233);
    a.booru.database.write(BooruStore.ensureUnsorted);
    a.booru.reorderFolders([folder, 'unsorted']);
    final post = fixturePost(101, server);
    a.booru.saveFavorite(post, folderID: folder);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    b.booru.refresh();
    expect(b.booru.servers.map((server) => server.canonicalAddress), [server.canonicalAddress]);
    final local = b.booru.servers.single;
    expect(b.booru.folderIDFor(post.onServer(local.id)), folder);
    expect(b.booru.folders().first.id, folder);
    expect(a.snapshot().values.firstWhere((row) => row.table == 'booru.servers').isFactoryDefault, isFalse);
  });

  test('a fresh device does not overwrite an existing default folder color', () {
    final a = adapter(), b = adapter();
    final folder = a.manga.listFolders().first.id!;
    a.manga.setFolderColor(folder, 0xFF123456);
    exchange(a, b, LibrarySyncLedger(), LibrarySyncLedger());
    expect(b.manga.listFolders().first.color, 0xFF123456);
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
}
