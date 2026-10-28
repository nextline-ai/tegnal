import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';
import 'package:tegnal/data/backup_codec.dart';

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.memory());
  tearDown(() => store.close());
  SourceConfig source(String id, String host) => SourceConfig(
    id: id,
    name: 'Same name',
    baseUrl: Uri.parse('https://$host'),
    kind: SourceKind.danbooru,
  );
  ContentItem item(int id, String sourceId, {AppMode mode = AppMode.booru}) =>
      ContentItem(sourceId: sourceId, id: id, mode: mode, title: 'Work $id');

  test(
    'empty sites wait for first save; same names retain independent identities',
    () {
      store.saveSource(source('a', 'a.invalid'));
      store.saveSource(source('b', 'b.invalid'));
      expect(store.folders(AppMode.booru), isEmpty);
      store.saveItem(item(1, 'a'));
      store.saveItem(item(1, 'b'));
      expect(store.folders(AppMode.booru).map((f) => f.id), [
        'site:https://a.invalid',
        'site:https://b.invalid',
      ]);
      expect(store.folders(AppMode.booru).map((f) => f.name), [
        'Same name',
        'Same name',
      ]);
      final overview = store.libraryOverview(AppMode.booru);
      expect(overview.unfiled.count, 0);
      expect(overview.folders.values.map((f) => f.count), [1, 1]);
      expect(
        store
            .items(AppMode.booru, folderId: 'site:https://a.invalid')
            .single
            .item
            .sourceId,
        'a',
      );
    },
  );

  test('archived and unregistered sources stay accessible; custom memberships persist', () {
    store.saveSource(source('a', 'a.invalid'));
    store.setSetting('archivedSources', ['a']);
    store.saveItem(item(1, 'a'));
    store.saveItem(item(1, 'missing'));
    expect(store.saved(item(1, 'a').key)!.folderIds, [
      'site:https://a.invalid',
    ]);
    expect(store.saved(item(1, 'missing').key)!.folderIds, [
      'site:source:missing',
    ]);
    store.saveFolder(
      const LibraryFolder(id: 'custom', mode: AppMode.booru, name: '미분류'),
    );
    store.saveItem(
      item(2, 'a'),
      folderIds: ['custom'],
      note: 'Retain',
      savedAt: DateTime.utc(2026),
    );
    store.saveItem(item(2, 'a'));
    expect(store.saved(item(2, 'a').key)!.folderIds, ['custom']);
    expect(store.saved(item(2, 'a').key)!.note, 'Retain');
    store.saveItem(item(2, 'a'), folderIds: []);
    expect(store.saved(item(2, 'a').key)!.folderIds, [
      'site:https://a.invalid',
    ]);
    store.removeSource('a');
    expect(store.items(AppMode.booru), hasLength(3));
    expect(
      store.folders(AppMode.booru).map((f) => f.id),
      containsAll(['site:https://a.invalid', 'custom']),
    );
  });

  test(
    'legacy groups repair without deleting rows or changing custom folders',
    () {
      store.saveSource(source('a', 'a.invalid'));
      for (final id in ['imported-unsorted', 'anime-boxes', 'custom']) {
        store.saveFolder(LibraryFolder(id: id, mode: AppMode.booru, name: id));
      }
      store.setPortable('backup.images', {
        'folderMetadata': {
          'imported-unsorted': {'nativeID': 'unsorted', 'color': 0xFF123456},
        },
      });
      for (var i = 1; i <= 4; i++) {
        final work = item(i, 'a');
        store.database.execute('INSERT INTO items VALUES (?,?,?,?,?)', [
          work.key,
          'booru',
          jsonEncode(work.toJson()),
          DateTime.utc(2026).toIso8601String(),
          'old note',
        ]);
        if (i < 4) {
          store.database.execute('INSERT INTO memberships VALUES (?,?)', [
            work.key,
            ['imported-unsorted', 'anime-boxes', 'custom'][i - 1],
          ]);
        }
      }
      expect(
        store.folders(AppMode.booru).map((f) => f.id),
        unorderedEquals(['custom', 'site:https://a.invalid']),
      );
      expect(store.saved(item(3, 'a').key)!.folderIds, ['custom']);
      for (final i in [1, 2, 4]) {
        expect(store.saved(item(i, 'a').key)!.folderIds, [
          'site:https://a.invalid',
        ]);
        expect(store.saved(item(i, 'a').key)!.note, 'old note');
      }
      expect(
        store.database.select('SELECT * FROM folders WHERE id=?', [
          'imported-unsorted',
        ]),
        hasLength(1),
      );
      final overview = store.libraryOverview(AppMode.booru);
      expect(overview.totalCount, 4);
      expect(overview.folders['site:https://a.invalid']!.count, 3);
      expect(overview.unfiled.count, 0);
      store.saveItem(item(1, 'a', mode: AppMode.manga));
      expect(store.libraryOverview(AppMode.manga).unfiled.count, 1);
    },
  );

  test(
    'imported native site folder retains ID name and color on future saves',
    () {
      store.saveSource(source('a', 'a.invalid'));
      store.saveFolder(
        const LibraryFolder(
          id: 'import-id',
          mode: AppMode.booru,
          name: 'Renamed',
          color: 0xFF123456,
        ),
      );
      store.setPortable('backup.images', {
        'folderMetadata': {
          'import-id': {'nativeID': 'site:https://a.invalid'},
        },
      });
      store.saveItem(item(1, 'a'));
      expect(store.saved(item(1, 'a').key)!.folderIds, ['import-id']);
      expect(store.folders(AppMode.booru).single.color, 0xFF123456);
      expect(store.folders(AppMode.booru).single.name, 'Renamed');
    },
  );

  test('deleting folders preserves works and restores site destinations', () {
    store.saveSource(source('a', 'a.invalid'));
    store.saveFolder(
      const LibraryFolder(id: 'custom', mode: AppMode.booru, name: 'Custom'),
    );
    store.saveItem(item(1, 'a'), folderIds: ['custom'], note: 'Keep');
    store.deleteFolder('custom');
    expect(store.items(AppMode.booru).single.folderIds, [
      'site:https://a.invalid',
    ]);
    store.deleteFolder('site:https://a.invalid');
    expect(store.items(AppMode.booru).single.folderIds, [
      'site:https://a.invalid',
    ]);
    expect(store.saved(item(1, 'a').key)!.note, 'Keep');
    expect(store.folders(AppMode.booru), hasLength(1));
  });

  test('registering a formerly missing site resolves its temporary folder', () {
    store.saveItem(item(1, 'a'));
    final initial = store.folders(AppMode.booru).single;
    store.saveFolder(
      LibraryFolder(
        id: initial.id,
        mode: initial.mode,
        name: 'Custom site name',
        color: 0xFF123456,
        position: initial.position,
      ),
    );
    store.saveSource(source('a', 'a.invalid'));
    final resolved = store.folders(AppMode.booru).single;
    expect(resolved.id, 'site:https://a.invalid');
    expect(resolved.name, 'Custom site name');
    expect(resolved.color, 0xFF123456);
    expect(store.saved(item(1, 'a').key)!.folderIds, [resolved.id]);
    expect(
      store.database.select('SELECT * FROM folders WHERE id=?', [initial.id]),
      hasLength(1),
    );
  });

  test(
    'late registration merges into an existing site folder without changing it',
    () {
      store.saveItem(item(1, 'a'));
      store.saveFolder(
        const LibraryFolder(
          id: 'site:https://a.invalid',
          mode: AppMode.booru,
          name: 'Existing destination',
          color: 0xFF987654,
          position: 9,
        ),
      );
      store.saveFolder(
        const LibraryFolder(
          id: 'user',
          mode: AppMode.booru,
          name: 'User folder',
          color: 0xFF123456,
        ),
      );
      store.saveItem(item(2, 'a'), folderIds: ['user']);
      store.saveSource(source('a', 'a.invalid'));
      final folders = store.folders(AppMode.booru);
      final destination = folders.firstWhere(
        (folder) => folder.id == 'site:https://a.invalid',
      );
      expect(destination.name, 'Existing destination');
      expect(destination.color, 0xFF987654);
      expect(destination.position, 9);
      expect(store.saved(item(1, 'a').key)!.folderIds, [destination.id]);
      expect(store.saved(item(2, 'a').key)!.folderIds, ['user']);
      expect(folders, hasLength(2));
    },
  );

  test(
    'repair invalidates after outer rollback and site backups roundtrip',
    () {
      store.saveSource(source('a', 'a.invalid'));
      final work = item(1, 'a');
      store.database.execute('INSERT INTO items VALUES (?,?,?,?,?)', [
        work.key,
        'booru',
        jsonEncode(work.toJson()),
        DateTime.utc(2026).toIso8601String(),
        'Keep',
      ]);
      expect(
        () => store.transaction(() {
          expect(store.folders(AppMode.booru), hasLength(1));
          throw StateError('Rollback');
        }),
        throwsStateError,
      );
      expect(store.database.select('SELECT * FROM memberships'), isEmpty);
      expect(store.folders(AppMode.booru), hasLength(1));
      final output = jsonDecode(BackupCodec(store).exportJson()) as Map;
      expect(
        (output['images'] as Map)['folders'].single['id'],
        'site:https://a.invalid',
      );
      final restored = LibraryStore.memory();
      addTearDown(restored.close);
      BackupCodec(restored).importJson(jsonEncode(output));
      expect(restored.items(AppMode.booru).single.item.sourceId, 'a');
      expect(restored.libraryOverview(AppMode.booru).unfiled.count, 0);
      expect(restored.folders(AppMode.booru).single.name, 'Same name');
      restored.saveItem(item(2, 'a'));
      expect(restored.folders(AppMode.booru), hasLength(1));
      expect(
        restored
            .items(AppMode.booru)
            .map((saved) => saved.folderIds.single)
            .toSet(),
        hasLength(1),
      );
    },
  );
}
