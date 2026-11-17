// Folder colors from native-ios/TEGNALTests/FolderPaletteTests.swift.

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_palette.dart';
import 'package:tegnal/core/support/sql_database.dart';

import '../../support/backup_fixtures.dart';

/// Colors 1.5.1 and earlier gave folders on their own, in the order they gave them.
const _earlierPalette = [
  0xFF2563EB, 0xFF059669, 0xFFEA580C, 0xFFE11D48, 0xFF7C3AED, 0xFF0891B2, 0xFFD97706, 0xFFDB2777, //
  0xFF4F46E5, 0xFF0D9488, 0xFF65A30D, 0xFFC026D3, 0xFFDC2626, 0xFF9333EA, 0xFF0284C7, 0xFFB45309, //
  0xFF16A34A, 0xFFF97316, 0xFF6366F1, 0xFF14B8A6, 0xFF84CC16, 0xFFEC4899, 0xFFA855F7, 0xFF3B82F6, //
  0xFF10B981, 0xFFF59E0B, 0xFFEF4444, 0xFF64748B,
];

void main() {
  test('every earlier color becomes its own current color and current colors stay', () {
    final mapped = _earlierPalette.map(FolderPalette.vivid).toList();
    expect(mapped.toSet(), hasLength(_earlierPalette.length), reason: 'folders that differed must still differ');
    expect(mapped.every(FolderPalette.colors.contains), isTrue);
    expect(FolderPalette.vivid(0xFF2563EB), FolderPalette.colors.first);
    expect(FolderPalette.vivid(FolderPalette.earlierUnfiled), FolderPalette.unfiled);
    expect(FolderPalette.vivid(FolderPalette.earlierUnsorted), FolderPalette.unsorted);
    for (final color in [...FolderPalette.colors, for (var index = 0; index < 40; index++) FolderPalette.generated(index)]) {
      expect(FolderPalette.vivid(color), color);
    }
    expect(FolderPalette.colors.toSet(), hasLength(FolderPalette.colors.length));
  });

  test('other colors keep their hue and grays become slate, as on iOS', () {
    expect(FolderPalette.vivid(0xFF9E9E9E), 0xFF5C6B80);
    expect(FolderPalette.vivid(0xFF000000), 0xFF5C6B80);
    expect(FolderPalette.vivid(0xFFFF0000), 0xFFFF3B30);
    expect(FolderPalette.vivid(0xFFFFFF00), 0xFFFFCC00);
    expect(FolderPalette.vivid(0x00FF0000), 0xFFFF3B30, reason: 'a color without alpha counts as opaque');
  });

  test('choices are the first ten unused colors and go past the palette', () {
    final used = {FolderPalette.colors[0], FolderPalette.colors[2]};
    final choices = FolderPalette.unused(used, 10);
    expect(choices, hasLength(10));
    expect(choices.first, FolderPalette.colors[1]);
    expect(choices.toSet().intersection(used), isEmpty);
    expect(FolderPalette.unused(FolderPalette.colors.toSet(), 10), [for (var index = 0; index < 10; index++) FolderPalette.generated(index)]);
    expect(FolderPalette.next(used), FolderPalette.colors[1]);
  });

  test('the migration recolors folders, keeping them apart', () {
    final db = SqlDatabase.inMemory();
    db.execute('CREATE TABLE folders (id TEXT PRIMARY KEY, color INTEGER NOT NULL)');
    for (final (id, color) in [('a', 0xFF2563EB), ('b', 0xFF1E70F0), ('c', 0xFF1F6BFF), ('d', 0xFF9E9E9E), ('e', 0xFF2563EB)]) {
      db.execute('INSERT INTO folders VALUES (?, ?)', [id, color]);
    }
    AppDatabase.adoptVividFolderColors(db);
    final colors = {for (final row in db.rows('SELECT id, color FROM folders')) row['id'] as String: row['color'] as int};
    expect(colors['a'], FolderPalette.colors.first);
    expect(colors['e'], FolderPalette.colors.first, reason: 'the same color stays the same');
    expect(colors['c'], FolderPalette.colors.first, reason: 'a current color is kept');
    expect(colors['b'], isNot(FolderPalette.colors.first));
    expect(FolderPalette.colors, contains(colors['b']));
    expect(colors['d'], 0xFF5C6B80);
  });

  test('new libraries start with the new defaults and backups bring old colors up to date', () {
    final comics = AppDatabase.inMemory();
    expect(comics.ensureDefaultFolder().color, FolderPalette.unfiled);
    expect(comics.createFolder(name: 'First').color, FolderPalette.colors.first);
    final images = BooruStore.inMemory();
    images.saveServer(presetServer());
    expect(images.folders().first.color, FolderPalette.colors.first, reason: "a server's Uncategorized takes the first color");
    images.restoreBackup(
      BooruBackup(
        servers: const [],
        folders: [BooruBackupFolder(id: 'old', name: 'Old', color: 0xFF0D9488)],
        favorites: const [],
        history: const [],
        savedTags: const [],
        blacklist: const {},
        selectedServerIDs: const [],
      ),
    );
    expect(images.folders().firstWhere((folder) => folder.id == 'old').color, 0xFF00897B);
  });
}
