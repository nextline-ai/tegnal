import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/domain/models.dart';
import 'package:tegnal/presentation/library/collections_view.dart';
import 'package:tegnal/presentation/library/folder_color_sheet.dart';

void main() {
  late AppDatabase database;
  late AppPreferences preferences;
  late SavedCollectionsModel model;

  setUp(() {
    preferences = AppPreferences.memory();
    database = AppDatabase.inMemory(preferences: preferences);
    model = SavedCollectionsModel(database: database, preferences: preferences.defaults);
  });

  tearDown(() => model.dispose());

  test('the fixed sections stay and other kinds appear once something is saved', () {
    expect(model.sections, [
      SavedCollectionKind.tag,
      SavedCollectionKind.artist,
      SavedCollectionKind.series,
      SavedCollectionKind.search,
      SavedCollectionKind.history,
    ]);
    model.save('group:sample circle', SavedCollectionKind.group);
    expect(model.sections, contains(SavedCollectionKind.group));
    expect(model.names(SavedCollectionKind.group), ['sample_circle']);
  });

  test('a history entry is saved as a search', () {
    model.save('tag:example', SavedCollectionKind.history);
    expect(model.names(SavedCollectionKind.search), ['tag:example']);
  });

  test('reordering is kept in preferences under the native key', () {
    for (final name in ['alpha', 'beta', 'gamma']) {
      model.save(name, SavedCollectionKind.tag);
    }
    model.reorder(SavedCollectionKind.tag, 2, 0);
    expect(model.names(SavedCollectionKind.tag), ['gamma', 'alpha', 'beta']);
    expect(preferences.defaults.object('collections.order.manga.tag'), ['gamma', 'alpha', 'beta']);
    model.move(SavedCollectionKind.tag, 'beta', -1);
    expect(model.names(SavedCollectionKind.tag), ['gamma', 'beta', 'alpha']);
  });

  test('removing a saved search leaves the history alone', () {
    model.save('tag:example', SavedCollectionKind.search);
    database.recordSearch('tag:example');
    model.remove('tag:example', SavedCollectionKind.search);
    expect(model.names(SavedCollectionKind.search), isEmpty);
    expect(model.names(SavedCollectionKind.history), ['tag:example']);
  });

  test('a picked color is stored opaque, one byte per channel', () {
    expect(FolderColorSheet.argb(const Color(0x80FF8000)), 0xFFFF8000);
    expect(FolderColorSheet.grid, hasLength(10));
    expect(FolderColorSheet.grid.every((row) => row.length == 12), isTrue);
  });
}
