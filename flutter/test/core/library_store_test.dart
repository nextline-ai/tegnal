import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  const item = ContentItem(
    sourceId: 'site',
    id: 12,
    mode: AppMode.manga,
    title: 'Test',
    artists: ['Imported artist'],
    metadata: {
      'nativeBackup': {'thumb_page': 3, 'portableExtension': 'keep'},
      'language': 'korean',
    },
  );
  test('library survives reopening and metadata refresh preserves membership and note', () async {
    final directory = await Directory.systemTemp.createTemp('tegnal-store-');
    final path = '${directory.path}/library.sqlite';
    var store = LibraryStore(sqlite3.open(path));
    try {
      store.saveFolder(
        const LibraryFolder(id: 'folder', mode: AppMode.manga, name: 'Reading'),
      );
      store.saveItem(item, folderIds: ['folder'], note: 'Keep this note');
      store.setProgress(item.key, 8);
      store.saveItem(
        const ContentItem(
          sourceId: 'changed-site',
          id: 12,
          mode: AppMode.manga,
          title: 'Updated',
        ),
      );
      store.close();
      store = LibraryStore(sqlite3.open(path));
      expect(store.items(AppMode.manga), hasLength(1));
      expect(store.saved(item.key)!.item.title, 'Updated');
      expect(store.saved(item.key)!.folderIds, ['folder']);
      expect(store.saved(item.key)!.note, 'Keep this note');
      expect(store.saved(item.key)!.item.metadata['nativeBackup'], {
        'thumb_page': 3,
        'portableExtension': 'keep',
      });
      expect(store.saved(item.key)!.item.artists, ['Imported artist']);
      expect(store.progress(item.key), 8);
      store.deleteFolder('folder');
      expect(store.saved(item.key)!.folderIds, isEmpty);
      expect(store.isSaved(item.key), isTrue);
    } finally {
      store.close();
      await directory.delete(recursive: true);
    }
  });
  test('invalid cross-mode membership rolls back the entire write', () {
    final store = LibraryStore.memory();
    addTearDown(store.close);
    store.saveFolder(
      const LibraryFolder(id: 'images', mode: AppMode.booru, name: 'Images'),
    );
    expect(
      () => store.saveItem(item, folderIds: ['images']),
      throwsFormatException,
    );
    expect(store.items(AppMode.manga), isEmpty);
    store.saveItem(item, note: 'original');
    expect(
      () => store.transaction(() {
        store.saveItem(item, note: 'changed');
        throw StateError('failed');
      }),
      throwsStateError,
    );
    expect(store.saved(item.key)!.note, 'original');
  });
  test('booru post identity stays scoped to server and preferences stay scoped to mode', () {
    final store = LibraryStore.memory();
    addTearDown(store.close);
    for (final server in ['one', 'two']) {
      store.saveItem(
        ContentItem(
          sourceId: server,
          id: 12,
          mode: AppMode.booru,
          title: server,
        ),
      );
    }
    store.setSetting(
      'reader.manga',
      const ReaderPreferences(rightToLeft: true).toJson(),
    );
    expect(store.items(AppMode.booru), hasLength(2));
    expect(store.setting('reader.booru'), isNull);
  });
}
