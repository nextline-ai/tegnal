// Restores backups written by the native app (test/fixtures/native, see its README)
// and compares the resulting databases with the state the native app reached from
// the same files, row by row, using the same queries.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_backup.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/challenge/challenge_models.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/library_backup.dart';

import '../../support/native_dump.dart';

const _fixtures = 'test/fixtures/native';
Uint8List _bytes(String name) => File('$_fixtures/$name').readAsBytesSync();
final Map<String, Object?> _expected = jsonDecode(File('$_fixtures/restore_expectations.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('fresh libraries match the native fresh state', () {
    final fresh = _expected['fresh_state_before_restore'] as Map<String, Object?>;
    expect(dumpComics(AppDatabase.inMemory()), withoutNote(fresh['comics']));
    expect(dumpImages(BooruStore.inMemory()), withoutNote(fresh['images']));
  });

  test('the unified native backup restores to the same rows as on iOS, twice', () {
    final backup = LibraryBackupImport.decode(_bytes('library_backup.json'));
    final checks = (_expected['decode_checks'] as Map)['library_backup.json'] as Map;
    expect(backup.workCount, checks['workCount']);
    expect(backup.folderCount, checks['folderCount']);
    expect([backup.comics != null, backup.images != null, backup.challenges != null], [checks['has_comics'], checks['has_images'], checks['has_challenges']]);

    final comics = AppDatabase.inMemory(), images = BooruStore.inMemory();
    backup.restore(comics, images);
    final expected = _expected['after_first_restore'] as Map<String, Object?>;
    final comicsState = dumpComics(comics), imagesState = dumpImages(images);
    expect(comicsState, sortedOrder(withoutNote(expected['comics'])));
    expect(imagesState, withoutNote(expected['images']));

    backup.restore(comics, images);
    expect(dumpComics(comics), comicsState);
    expect(dumpImages(images), imagesState);
  });

  test('older comics backups restore to the same rows as on iOS', () {
    final checks = _expected['decode_checks'] as Map;
    for (final name in ['comics_backup_v2.json', 'comics_backup_legacy_group.json']) {
      final check = checks[name] as Map;
      final backup = LibraryBackupImport.decode(_bytes(name));
      expect(
        [backup.comics != null, backup.images != null, backup.challenges != null],
        [check['has_comics'], check['has_images'], check['has_challenges']],
        reason: name,
      );
      if (check.containsKey('workCount')) expect(backup.workCount, check['workCount'], reason: name);
      if (check['decoded_comics_reencoded_sorted'] case final Map<String, Object?> decoded) {
        expect(jsonDecode(jsonEncode(backup.comics!.toJson())), decoded, reason: name);
      }
      final comics = AppDatabase.inMemory();
      backup.restore(comics, BooruStore.inMemory());
      expect(dumpComics(comics), sortedOrder(withoutNote(check['restored_comics_state'])), reason: name);
    }
  });

  test('standalone image and challenge backups decode as on iOS', () {
    final checks = _expected['decode_checks'] as Map;
    final image = LibraryBackupImport.decode(_bytes('image_backup.json'));
    expect(image.images!.format, (checks['image_backup.json'] as Map)['format_after_decode']);
    expect([image.comics, image.challenges], [isNull, isNull]);

    final historical = LibraryBackupImport.decode(_bytes('image_backup_historical.json'));
    expect(historical.images!.format, (checks['image_backup_historical.json'] as Map)['format_after_decode']);
    final fromHistorical = BooruStore.inMemory(), fromUnified = BooruStore.inMemory();
    historical.restore(AppDatabase.inMemory(), fromHistorical);
    LibraryBackupImport.decode(_bytes('library_backup.json')).restore(AppDatabase.inMemory(), fromUnified);
    expect(
      dumpImages(fromHistorical)['favorites'],
      (checks['image_backup_historical.json'] as Map)['restored_favorites_equal_unified_restore'] == true ? dumpImages(fromUnified)['favorites'] : anything,
    );

    final challenges = LibraryBackupImport.decode(_bytes('challenge_backup.json'));
    expect(challenges.challenges!.games.map((game) => game.id), (checks['challenge_backup.json'] as Map)['game_ids']);
    expect([challenges.comics, challenges.images], [isNull, isNull]);
  });

  test('re-exporting a restored native backup keeps every portable field', () {
    final original = jsonDecode(utf8.decode(_bytes('library_backup.json'))) as Map<String, Object?>;
    final comics = AppDatabase.inMemory(), images = BooruStore.inMemory();
    LibraryBackupImport.decode(_bytes('library_backup.json')).restore(comics, images);
    final exported = jsonDecode(utf8.decode(LibraryBackup.capture(comics, images).encoded())) as Map<String, Object?>;

    Map<String, Object?> section(Map<String, Object?> backup, String name) => {...(backup[name] as Map<String, Object?>)}
      ..remove('exportedAt')
      ..remove('exported_at');
    Map<String, Object?> comicsOf(Map<String, Object?> backup) {
      final value = section(backup, 'comics');
      value['folders'] = [
        for (final folder in (value['folders'] as List).cast<Map>()) {...folder}..remove('id'),
      ];
      value['folder_rules'] = [...(value['folder_rules'] as List).cast<Map>()]..sort((a, b) => (a['folder'] as String).compareTo(b['folder'] as String));
      return value;
    }

    // Restoring files a favorite through `onServer`, which keeps only these fields.
    const kept = {
      'serverID', 'postID', 'previewURL', 'sampleURL', 'fileURL', 'width', 'height', 'tags', 'artists', 'rating', 'score', 'fileExtension', 'poolIDs', //
      'metadataTags', 'favoriteCount', 'upvoteCount', 'commentCount', 'isDeleted', 'isBanned',
    };
    Map<String, Object?> imagesOf(Map<String, Object?> backup) {
      final value = section(backup, 'images');
      value['favorites'] = [
        for (final favorite in (value['favorites'] as List).cast<Map>())
          {
            ...favorite,
            'post': {
              for (final entry in (favorite['post'] as Map).entries)
                if (kept.contains(entry.key)) entry.key: entry.value,
            },
          },
      ];
      return value;
    }

    expect(exported['format'], original['format']);
    expect(exported['version'], original['version']);
    expect(comicsOf(exported), comicsOf(original));
    expect(imagesOf(exported), imagesOf(original));
    expect(exported['challenges'], original['challenges']);
  });

  test('every native fixture is accepted and the image section keeps its reference-date timestamp', () {
    for (final name in [
      'library_backup.json',
      'comics_backup_v2.json',
      'comics_backup_legacy_group.json',
      'image_backup.json',
      'image_backup_historical.json',
      'challenge_backup.json',
    ]) {
      expect(() => LibraryBackupImport.decode(_bytes(name)), returnsNormally, reason: name);
    }
    final raw = jsonDecode(utf8.decode(_bytes('image_backup.json'))) as Map<String, Object?>;
    final decoded = BooruBackup.decode(_bytes('image_backup.json'));
    expect(decoded.toJson()['exportedAt'], closeTo(raw['exportedAt'] as num, 1e-5));
    expect(decoded.exportedAt.year, greaterThanOrEqualTo(2026));
    expect(ChallengeBackup.decode(_bytes('challenge_backup.json')).games.length, 2);
  });
}
