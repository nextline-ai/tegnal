import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/core/taste_controller.dart';
import 'package:tegnal/data/library_store.dart';

class _CountingStore extends LibraryStore {
  _CountingStore() : super(sqlite3.openInMemory());
  int fullReads = 0;
  @override
  List<SavedItem> items(AppMode mode, {String? folderId, String query = ''}) {
    fullReads++;
    return super.items(mode, folderId: folderId, query: query);
  }
}

void main() {
  test('initialized startup reads keys without decoding saved payloads', () {
    final store = _CountingStore();
    addTearDown(store.close);
    store.transaction(() {
      for (var id = 1; id <= 1000; id++) {
        store.saveItem(
          ContentItem(
            sourceId: 'fixture',
            id: id,
            mode: AppMode.booru,
            title: 'Saved $id',
          ),
        );
      }
    });
    LocalTasteController(store).seed([]);
    final controller = AppController(store);
    addTearDown(controller.dispose);
    expect(store.fullReads, 0);
    expect(store.savedKeys(), hasLength(1000));
    // Existing works must not be mistaken for fresh imports after restart.
    controller.libraryRestored();
    expect(controller.taste.analysisItems(AppMode.booru), isEmpty);
  });

  test('first startup still seeds existing works once', () {
    final store = _CountingStore();
    addTearDown(store.close);
    store.saveItem(
      const ContentItem(
        sourceId: 'fixture',
        id: 1,
        mode: AppMode.booru,
        title: 'Saved',
      ),
    );
    final first = AppController(store);
    expect(first.taste.analysisItems(AppMode.booru), hasLength(1));
    first.dispose();
    store.fullReads = 0;
    final second = AppController(store);
    addTearDown(second.dispose);
    expect(store.fullReads, 0);
    expect(second.taste.analysisItems(AppMode.booru), hasLength(1));
  });
}
