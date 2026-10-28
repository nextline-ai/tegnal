import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  const marker = 'bootstrap.sources.1_0_0';

  test('new library starts without connections', () {
    final store = LibraryStore.memory();
    final controller = AppController(store);
    addTearDown(() {
      controller.dispose();
      store.close();
    });
    expect(store.sources(), isEmpty);
    expect(controller.allSources, isEmpty);
    expect(store.setting(marker), isNull);
  });

  test(
    'existing connections and bootstrap marker survive database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tegnal-sources-',
      );
      final path = '${directory.path}/library.sqlite';
      var store = LibraryStore(sqlite3.open(path));
      final sources = [
        SourceConfig(
          id: 'bundled-hitomi',
          name: 'Existing manga',
          baseUrl: Uri.parse('https://manga.example'),
          kind: SourceKind.manga,
        ),
        SourceConfig(
          id: 'bundled-danbooru',
          name: 'Existing image',
          baseUrl: Uri.parse('https://booru.example'),
          kind: SourceKind.danbooru,
        ),
      ];
      try {
        for (final source in sources) {
          store.saveSource(source);
        }
        store.setSetting(marker, true);
        store.setSetting('source.manga', sources.first.id);
        store.setSetting('selected.booru', [sources.last.id]);
        store.close();
        store = LibraryStore(sqlite3.open(path));
        final controller = AppController(store);
        expect(
          store.sources().map((source) => source.toJson()),
          sources.map((source) => source.toJson()),
        );
        expect(store.setting(marker), true);
        expect(controller.selectedSource(AppMode.manga)?.id, sources.first.id);
        expect(
          controller.selectedSources(AppMode.booru).single.id,
          sources.last.id,
        );
        controller.dispose();
        store.close();
        store = LibraryStore(sqlite3.open(path));
        expect(
          store.sources().map((source) => source.toJson()),
          sources.map((source) => source.toJson()),
        );
        expect(store.setting(marker), true);
      } finally {
        store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
