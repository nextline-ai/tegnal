import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/bundled_sources.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  SourceConfig source(String id, String address, SourceKind kind) =>
      SourceConfig(
        id: id,
        name: 'User $id',
        baseUrl: SourceConfig.validateUrl(address),
        kind: kind,
      );

  test(
    'only explicit application bootstrap adds ordinary persistent sources',
    () {
      final store = LibraryStore.memory();
      addTearDown(store.close);
      expect(store.sources(), isEmpty);
      BundledSources.seedOnce(store);
      expect(
        store.sources().map((entry) => (entry.canonicalAddress, entry.kind)),
        [
          ('https://hitomi.la', SourceKind.manga),
          ('https://danbooru.donmai.us', SourceKind.danbooru),
        ],
      );
      expect(store.setting(BundledSources.migrationKey), true);
      expect(store.setting('source.manga'), isNull);
      expect(store.setting('source.booru'), isNull);
      expect(store.setting('selected.booru'), isNull);
      final controller = AppController(
        store,
        sourceFactory: (_) =>
            throw StateError('Bootstrap must not use network.'),
      );
      addTearDown(controller.dispose);
      expect(
        controller.selectedSource(AppMode.manga)!.baseUrl.host,
        'hitomi.la',
      );
      expect(
        controller.selectedSources(AppMode.booru).single.baseUrl.host,
        'danbooru.donmai.us',
      );
    },
  );

  test(
    'canonical duplicates keep identity, engine, names and archive state',
    () {
      final store = LibraryStore.memory();
      addTearDown(store.close);
      final existing = [
        source('comics', 'https://HITOMI.LA/', SourceKind.manga),
        source(
          'images',
          'https://www.danbooru.donmai.us:443/index.php/',
          SourceKind.gelbooru,
        ),
      ];
      for (final entry in existing) {
        store.saveSource(entry);
      }
      store.setSetting('archivedSources', ['comics', 'images']);
      store.setSetting('source.manga', 'comics');
      store.setSetting('source.booru', 'images');
      store.setSetting('selected.booru', <String>[]);
      BundledSources.seedOnce(store);
      expect(
        store.sources().map((entry) => entry.toJson()),
        existing.map((entry) => entry.toJson()),
      );
      expect(store.setting('archivedSources'), ['comics', 'images']);
      expect(store.setting('source.manga'), 'comics');
      expect(store.setting('source.booru'), 'images');
      expect(store.setting('selected.booru'), isEmpty);
      expect(store.setting(BundledSources.migrationKey), true);
      final controller = AppController(store);
      addTearDown(controller.dispose);
      expect(controller.allSources, isEmpty);
    },
  );

  for (final selected in [
    <String>[],
    ['custom-image'],
  ]) {
    test(
      'existing manual connections and selection $selected are unchanged',
      () {
        final store = LibraryStore.memory();
        addTearDown(store.close);
        store.saveSource(
          source('custom-comics', 'https://comics.example', SourceKind.manga),
        );
        store.saveSource(
          source('custom-image', 'https://images.example', SourceKind.danbooru),
        );
        store.setSetting('source.manga', 'custom-comics');
        store.setSetting('source.booru', 'custom-image');
        store.setSetting('selected.booru', selected);
        BundledSources.seedOnce(store);
        expect(store.setting('source.manga'), 'custom-comics');
        expect(store.setting('source.booru'), 'custom-image');
        expect(store.setting('selected.booru'), selected);
        final controller = AppController(store);
        addTearDown(controller.dispose);
        expect(controller.selectedSource(AppMode.manga)!.id, 'custom-comics');
        expect(
          controller.selectedSources(AppMode.booru).map((entry) => entry.id),
          selected,
        );
      },
    );
  }

  test('portable explicit empty selection remains authoritative', () {
    final store = LibraryStore.memory();
    addTearDown(store.close);
    store.setPortable('backup.images', {'selectedServerIDs': <String>[]});
    BundledSources.seedOnce(store);
    final controller = AppController(store);
    addTearDown(controller.dispose);
    expect(controller.selectedSources(AppMode.booru), isEmpty);
    expect(store.setting('selected.booru'), isNull);
  });

  test('preferred identifier collisions never overwrite unrelated sources', () {
    final store = LibraryStore.memory();
    addTearDown(store.close);
    for (final id in [
      'bundled-hitomi',
      'bundled-hitomi-1',
      'bundled-danbooru',
    ]) {
      store.saveSource(source(id, 'https://$id.example', SourceKind.danbooru));
    }
    BundledSources.seedOnce(store);
    expect(store.sources(), hasLength(5));
    expect(store.sources().map((entry) => entry.id).toSet(), hasLength(5));
    expect(
      store
          .sources()
          .where((entry) => entry.baseUrl.host == 'hitomi.la')
          .single
          .id,
      'bundled-hitomi-2',
    );
    expect(
      store
          .sources()
          .where((entry) => entry.baseUrl.host == 'danbooru.donmai.us')
          .single
          .id,
      'bundled-danbooru-1',
    );
    expect(store.sources().first.name, 'User bundled-hitomi');
  });

  test('source and completion marker writes roll back together on failure', () {
    final store = LibraryStore.memory();
    addTearDown(store.close);
    store.database.execute('''
      CREATE TRIGGER reject_bootstrap BEFORE INSERT ON settings
      WHEN NEW.key = '${BundledSources.migrationKey}'
      BEGIN SELECT RAISE(ABORT, 'fixture marker failure'); END;
    ''');
    expect(
      () => BundledSources.seedOnce(store),
      throwsA(isA<SqliteException>()),
    );
    expect(store.sources(), isEmpty);
    expect(store.setting(BundledSources.migrationKey), isNull);
    store.database.execute('DROP TRIGGER reject_bootstrap');
    BundledSources.seedOnce(store);
    expect(store.sources(), hasLength(2));
    expect(store.setting(BundledSources.migrationKey), true);
  });

  test('connections survive without bootstrap code and deleted ones stay removed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tegnal-bootstrap-',
    );
    final path = '${directory.path}/library.sqlite';
    var store = LibraryStore(sqlite3.open(path));
    try {
      BundledSources.seedOnce(store);
      final ids = store.sources().map((entry) => entry.id).toList();
      store.close();
      // Reopen without calling the bootstrap: later code removal keeps the DB.
      store = LibraryStore(sqlite3.open(path));
      expect(store.sources().map((entry) => entry.id), ids);
      final controller = AppController(store);
      controller.removeSource(store.sources(AppMode.manga).single);
      controller.dispose();
      store.removeSource(ids.last);
      store.close();
      store = LibraryStore(sqlite3.open(path));
      BundledSources.seedOnce(store);
      expect(store.sources().map((entry) => entry.id), [ids.first]);
      expect(store.setting('archivedSources'), [ids.first]);
      expect(store.setting(BundledSources.migrationKey), true);
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });
}
