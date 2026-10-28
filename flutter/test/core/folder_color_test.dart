import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/app_controller.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/folder_color.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  late LibraryStore store;
  setUp(() => store = LibraryStore.memory());
  tearDown(() => store.close());
  const nativePalette = [
    0xFF2563EB,
    0xFF059669,
    0xFFEA580C,
    0xFFE11D48,
    0xFF7C3AED,
    0xFF0891B2,
    0xFFD97706,
    0xFFDB2777,
    0xFF4F46E5,
    0xFF0D9488,
    0xFF65A30D,
    0xFFC026D3,
    0xFFDC2626,
    0xFF9333EA,
    0xFF0284C7,
    0xFFB45309,
    0xFF16A34A,
    0xFFF97316,
    0xFF6366F1,
    0xFF14B8A6,
    0xFF84CC16,
    0xFFEC4899,
    0xFFA855F7,
    0xFF3B82F6,
    0xFF10B981,
    0xFFF59E0B,
    0xFFEF4444,
    0xFF64748B,
  ];
  for (final mode in AppMode.values) {
    test(
      '${mode.name} creation follows all 28 native colors then golden hues',
      () {
        final controller = AppController(store);
        addTearDown(controller.dispose);
        final colors = [
          for (var i = 0; i < 30; i++)
            controller.createFolder('Folder $i', mode: mode).color,
        ];
        expect(colors, [...nativePalette, 0xFF55E038, 0xFFE03886]);
      },
    );
    test(
      '${mode.name} deletion reuses first unused color and rename preserves it',
      () {
        final first = store.createFolder('First', id: 'first', mode: mode);
        final second = store.createFolder('Second', id: 'second', mode: mode);
        store.createFolder('Third', id: 'third', mode: mode);
        store.deleteFolder(second.id);
        final replacement = store.createFolder(
          'Replacement',
          id: 'replacement',
          mode: mode,
        );
        expect(replacement.color, nativePalette[1]);
        store.saveFolder(
          LibraryFolder(
            id: first.id,
            mode: mode,
            name: 'Renamed',
            color: first.color,
            position: first.position,
          ),
        );
        expect(
          store
              .folders(mode)
              .firstWhere((folder) => folder.id == first.id)
              .color,
          nativePalette.first,
        );
        expect(
          store.createFolder('Next', id: 'next', mode: mode).color,
          nativePalette[3],
        );
      },
    );
  }
  test(
    'both modes choose independently and imports keep their explicit colors',
    () {
      store.saveFolder(
        const LibraryFolder(
          id: 'imported',
          mode: AppMode.booru,
          name: 'Imported',
          color: 0xFF2563EB,
        ),
      );
      store.createFolder(
        'Custom',
        id: 'custom',
        mode: AppMode.booru,
        color: 0xFF123ABC,
      );
      expect(
        store.createFolder('Image', id: 'image', mode: AppMode.booru).color,
        0xFF059669,
      );
      expect(
        store.createFolder('Comic', id: 'comic', mode: AppMode.manga).color,
        0xFF2563EB,
      );
      expect(
        store
            .folders(AppMode.booru)
            .firstWhere((folder) => folder.id == 'custom')
            .color,
        0xFF123ABC,
      );
    },
  );
  test('Manga duplicate names reuse the folder; Booru names may repeat', () {
    final manga = store.createFolder('Same', id: 'manga', mode: AppMode.manga);
    final duplicate = store.createFolder(
      ' Same ',
      id: 'unused',
      mode: AppMode.manga,
    );
    expect(duplicate.id, manga.id);
    expect(
      store.createFolder('New', id: 'new', mode: AppMode.manga).color,
      0xFF059669,
    );
    final first = store.createFolder(
      'Same',
      id: 'image-1',
      mode: AppMode.booru,
    );
    final second = store.createFolder(
      'Same',
      id: 'image-2',
      mode: AppMode.booru,
    );
    expect(first.id, isNot(second.id));
    expect(second.color, 0xFF059669);
    expect(
      store.createFolder('Renamed', id: first.id, mode: AppMode.booru).color,
      first.color,
    );
  });
  test('fallback counts duplicate colors and exclusion entries exactly like native', () {
    expect(FolderColors.next([...nativePalette, ...nativePalette]), 0xFF3871E0);
    expect(
      FolderColors.next(nativePalette, excluding: {nativePalette.first}),
      0xFFE03886,
    );
    expect(
      FolderColors.next([nativePalette[0], nativePalette[2]]),
      nativePalette[1],
    );
  });
}
