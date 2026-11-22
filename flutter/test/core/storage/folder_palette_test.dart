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

/// The vivid palette 1.6 gave folders.
const _vividPalette = [
  0xFF1F6BFF, 0xFFFF3B30, 0xFF00C853, 0xFFFF9500, 0xFF8E4BFF, 0xFFFF2D87, 0xFF00C2E8, 0xFFFFCC00, 0xFF4A3DFF, //
  0xFF00BFA0, 0xFFFF6A3D, 0xFF7CD200, 0xFFD63CFF, 0xFF2FA8FF, 0xFFFFB000, 0xFF00A86B, 0xFFB026FF, 0xFFFF4F7B, //
  0xFF0047D6, 0xFF2EE0B0, 0xFFE3122C, 0xFF3DB500, 0xFFFF4FD8, 0xFF0090C8, 0xFFFF7A00, 0xFF6A1BE0, 0xFFE0006E, //
  0xFF00897B, 0xFFC8A000, 0xFF2D3DB8, 0xFF0A84FF, 0xFF7B83FF, 0xFF00D0D0, 0xFFB5651D, 0xFF9C27B0, 0xFF5C6B80,
];

void main() {
  test("the palette is Apple's thirteen system colors", () {
    expect(FolderPalette.colors, [
      0xFFFF383C, 0xFFFF8D28, 0xFFFFCC00, 0xFF34C759, 0xFF00C8B3, 0xFF00C3D0, 0xFF00C0E8, //
      0xFF0088FF, 0xFF6155F5, 0xFFCB30E0, 0xFFFF2D55, 0xFFAC7F5E, 0xFF8E8E93,
    ]);
    expect(FolderPalette.assignmentOrder.toSet(), FolderPalette.colors.toSet());
    expect(FolderPalette.assignmentOrder, hasLength(FolderPalette.colors.length));
  });

  test('every earlier color becomes a system color and system colors stay', () {
    for (final color in [..._earlierPalette, ..._vividPalette, ...FolderPalette.earlierUnfiled, ...FolderPalette.earlierUnsorted]) {
      expect(FolderPalette.colors, contains(FolderPalette.vivid(color)), reason: color.toRadixString(16));
    }
    expect(FolderPalette.previous.keys.toSet(), _vividPalette.toSet(), reason: 'every 1.6 color has a fixed replacement');
    expect(FolderPalette.vivid(0xFF1F6BFF), FolderPalette.blue);
    expect(FolderPalette.vivid(0xFFB5651D), FolderPalette.brown);
    expect(FolderPalette.vivid(0xFF5C6B80), FolderPalette.gray);
    expect(FolderPalette.vivid(0xFF2563EB), FolderPalette.blue, reason: 'a 1.5 color goes through its 1.6 color');
    for (final color in FolderPalette.earlierUnfiled) {
      expect(FolderPalette.vivid(color), FolderPalette.unfiled);
    }
    for (final color in FolderPalette.earlierUnsorted) {
      expect(FolderPalette.vivid(color), FolderPalette.unsorted);
    }
    for (final color in FolderPalette.colors) {
      expect(FolderPalette.vivid(color), color);
    }
  });

  test('other colors keep their hue and grays become gray, as on iOS', () {
    expect(FolderPalette.vivid(0xFF9E9E9E), FolderPalette.gray);
    expect(FolderPalette.vivid(0xFF000000), FolderPalette.gray);
    expect(FolderPalette.vivid(0xFFFFFFFF), FolderPalette.gray);
    expect(FolderPalette.vivid(0xFFFF0000), FolderPalette.red);
    expect(FolderPalette.vivid(0xFFFFFF00), FolderPalette.yellow);
    expect(FolderPalette.vivid(0xFF00FF00), FolderPalette.green);
    expect(FolderPalette.vivid(0xFFFFC0CB), FolderPalette.pink);
    expect(FolderPalette.vivid(0xFF8B4513), FolderPalette.brown);
    expect(FolderPalette.vivid(0x00FF0000), FolderPalette.red, reason: 'a color without alpha counts as opaque');
  });

  test('new folders take the least used color in order', () {
    expect(FolderPalette.next(const []), FolderPalette.blue);
    expect(FolderPalette.next(const [FolderPalette.blue]), FolderPalette.red);
    expect(FolderPalette.next(const [FolderPalette.blue], excluding: {FolderPalette.red}), FolderPalette.green);
    // Once every color is taken, the order starts again with the ones used least.
    expect(FolderPalette.next(FolderPalette.colors), FolderPalette.blue);
    expect(FolderPalette.next([...FolderPalette.colors, FolderPalette.blue]), FolderPalette.red);
    expect(FolderPalette.next(const [0xFF1F6BFF]), FolderPalette.red, reason: 'an earlier color counts as its system color');
    expect(FolderPalette.next(const [], excluding: FolderPalette.colors.toSet()), FolderPalette.blue);
  });

  test('the migration gives each color its one replacement', () {
    final db = SqlDatabase.inMemory();
    db.execute('CREATE TABLE folders (id TEXT PRIMARY KEY, color INTEGER NOT NULL)');
    for (final (id, color) in [('a', 0xFF2563EB), ('b', 0xFF1F6BFF), ('c', FolderPalette.red), ('d', 0xFF9E9E9E), ('e', 0xFF0A84FF), ('f', 0xFFB5651D)]) {
      db.execute('INSERT INTO folders VALUES (?, ?)', [id, color]);
    }
    AppDatabase.adoptFolderPalette(db);
    final colors = {for (final row in db.rows('SELECT id, color FROM folders')) row['id'] as String: row['color'] as int};
    expect(colors, {
      'a': FolderPalette.blue,
      'b': FolderPalette.blue,
      'c': FolderPalette.red,
      'd': FolderPalette.gray,
      'e': FolderPalette.blue,
      'f': FolderPalette.brown,
    });
  });

  test('new libraries start with the new defaults and backups bring old colors up to date', () {
    final comics = AppDatabase.inMemory();
    expect(comics.ensureDefaultFolder().color, FolderPalette.unfiled);
    expect(comics.createFolder(name: 'First').color, FolderPalette.red, reason: 'Unfiled already has blue');
    final images = BooruStore.inMemory();
    images.saveServer(presetServer());
    expect(images.folders().first.color, FolderPalette.blue, reason: "a server's Uncategorized takes the first color");
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
    expect(images.folders().firstWhere((folder) => folder.id == 'old').color, FolderPalette.mint);
  });
}
