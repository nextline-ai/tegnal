import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.memory());
  tearDown(() => store.close());
  ContentItem item(int id, {AppMode mode = AppMode.manga}) =>
      ContentItem(sourceId: 'local', id: id, mode: mode, title: 'Work $id');

  test(
    'overview preserves multi-folder and imported Unfiled membership semantics',
    () {
      for (final id in ['built-in', 'alias', 'named']) {
        store.saveFolder(LibraryFolder(id: id, mode: AppMode.manga, name: id));
      }
      final memberships = <List<String>>[
        [],
        ['built-in'],
        ['built-in', 'alias'],
        ['built-in', 'named'],
        ['named'],
      ];
      for (final (index, folders) in memberships.indexed) {
        store.saveItem(
          item(index + 1),
          folderIds: folders,
          savedAt: DateTime.utc(2026, 10, index + 1),
        );
      }
      store.saveItem(item(99, mode: AppMode.booru));
      final overview = store.libraryOverview(
        AppMode.manga,
        unfiledFolderIds: {'built-in', 'alias'},
      );
      expect(overview.totalCount, 5);
      expect(overview.unfiled.count, 3);
      expect(overview.unfiled.previews.map((item) => item.id), [3, 2, 1]);
      expect(overview.folders['built-in']!.count, 3);
      expect(overview.folders['named']!.previews.map((item) => item.id), [
        5,
        4,
      ]);
      expect(store.libraryOverview(AppMode.booru).unfiled.count, 0);
      expect(store.savedKeys(AppMode.manga), {
        for (var id = 1; id <= 5; id++) item(id).key,
      });
      expect(store.savedKeys(), hasLength(6));
      expect(
        store.savedKeysMatching([
          item(3).key,
          item(99, mode: AppMode.booru).key,
          'missing',
        ]),
        {item(3).key, item(99, mode: AppMode.booru).key},
      );
      store.removeItem(item(3).key);
      expect(store.savedKeysMatching([item(3).key]), isEmpty);
    },
  );

  test('10,000-work overview decodes only four previews per folder', () {
    const total = 10000, folders = 40;
    store.transaction(() {
      for (var folder = 0; folder < folders; folder++) {
        store.saveFolder(
          LibraryFolder(
            id: 'f$folder',
            mode: AppMode.manga,
            name: 'Folder $folder',
          ),
        );
      }
      final insertItem = store.database.prepare(
        'INSERT INTO items VALUES (?,?,?,?,?)',
      );
      final insertMembership = store.database.prepare(
        'INSERT INTO memberships VALUES (?,?)',
      );
      try {
        for (var id = 1; id <= total; id++) {
          final work = item(id);
          insertItem.execute([
            work.key,
            'manga',
            jsonEncode(work.toJson()),
            DateTime.utc(2026).add(Duration(seconds: id)).toIso8601String(),
            '',
          ]);
          insertMembership.execute([work.key, 'f${id % folders}']);
        }
      } finally {
        insertItem.close();
        insertMembership.close();
      }
    });
    final before = Stopwatch()..start();
    final oldItems = store.items(AppMode.manga);
    final oldCounts = {
      for (var folder = 0; folder < folders; folder++)
        'f$folder': oldItems
            .where((item) => item.folderIds.contains('f$folder'))
            .length,
    };
    before.stop();
    final after = Stopwatch()..start();
    final overview = store.libraryOverview(AppMode.manga);
    after.stop();
    expect(overview.totalCount, total);
    expect(
      overview.folders.map((key, value) => MapEntry(key, value.count)),
      oldCounts,
    );
    expect(
      overview.folders.values.fold<int>(
        0,
        (sum, folder) => sum + folder.previews.length,
      ),
      160,
    );
    expect(overview.unfiled.previews, isEmpty);
    expect(overview.folders['f1']!.previews.map((item) => item.id), [
      9961,
      9921,
      9881,
      9841,
    ]);
    debugPrint(
      'HOST ONLY 10000 works / 40 folders: previous full-decode + rescan ${before.elapsedMicroseconds}us; overview ${after.elapsedMicroseconds}us; decoded covers 160 vs10000. No device FPS measured.',
    );
  });
}
