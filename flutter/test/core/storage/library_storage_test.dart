// Storage parts of native-ios/TEGNALTests/LibrarySyncTests.swift.
//
// - "historical imported folder metadata is normalized without losing identity" covers the
//   metadata half of testHistoricalImportedFolderSyncNormalizesMetadataWithoutLosingIdentity.
//   Its sync half (LibrarySyncAdapter.apply and mediaFreeChanges) arrives with Google Drive sync.
// - Android has no shared app group, so testMissingSharedContainerIsCreatedBeforeOpeningBothDatabases
//   becomes a check of the app's own container, and the fallback test keeps only its last case:
//   a path that is a file cannot become the container.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/app_storage.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/domain/models.dart';

import '../../support/fixtures.dart';

void main() {
  test('missing container is created before opening both databases', () {
    final root = temporaryDirectory(addTearDown);
    final resolved = AppStorage.resolveContainer(Directory('${root.path}/Application Support/tegnal'));
    expect(resolved.existsSync(), isTrue);
    final path = '${resolved.path}/memo.sqlite';
    final preferences = AppPreferences.memory();
    AppDatabase.open(path: path, preferences: preferences).upsertWork(galleryId: 12345, title: 'Saved work');
    final alpha = server('alpha');
    BooruStore(path: '${resolved.path}/booru.sqlite', preferences: preferences).saveServer(alpha);
    expect(AppDatabase.open(path: path, preferences: preferences).getWork(12345)?.title, 'Saved work');
    expect(BooruStore(path: '${resolved.path}/booru.sqlite', preferences: preferences).servers, [alpha]);
    expect(
      resolved.listSync().map((entry) => entry.uri.pathSegments.where((part) => part.isNotEmpty).last).where((name) => name.startsWith('.storage-check-')),
      isEmpty,
    );
  });

  test('a file in place of the container is kept and refused', () {
    final root = temporaryDirectory(addTearDown);
    final unavailable = File('${root.path}/unavailable')..writeAsStringSync('Preserve existing content');
    expect(() => AppStorage.resolveContainer(Directory(unavailable.path)), throwsA(isA<FileSystemException>()));
    expect(unavailable.readAsStringSync(), 'Preserve existing content');
  });

  test('fill queue uses recent save dates and newest insertion for ties across batches', () {
    final db = AppDatabase.inMemory();
    db.upsertWork(galleryId: 9000, title: 'Older save', bookmarkedAt: '2026-01-01T00:00:00Z');
    for (final id in [4000, 2000, 6000]) {
      db.upsertWork(galleryId: id, title: 'Imported together', bookmarkedAt: '2026-10-01T00:00:00Z');
    }
    db.upsertWork(galleryId: 1000, title: 'Newest save', bookmarkedAt: '2026-10-23T00:00:00Z');
    final first = db.worksNeedingFill(limit: 2).map((work) => work.galleryId).toList();
    expect(first, [1000, 6000]);
    final second = db.worksNeedingFill(limit: 2, exclude: first.toSet()).map((work) => work.galleryId).toList();
    expect(second, [2000, 4000]);
    expect(db.worksNeedingFill(exclude: {...first, ...second}).map((work) => work.galleryId), [9000]);
    // Retrying a failed cover must keep its original save priority.
    db.setThumb(9000, 'failed');
    expect(db.worksNeedingFill().map((work) => work.galleryId), [1000, 6000, 2000, 4000, 9000]);
  });

  test('historical imported folder metadata is normalized without losing identity', () {
    final source = AppDatabase.inMemory();
    final created = source.createFolder(name: 'Imported folder', sourceGroupId: 42);
    final row = created.toJson();
    row['legacy_group_id'] = row.remove('source_group_id');
    final normalized = MangaImportMetadata.normalized(row);
    expect(normalized['source_group_id'], 42);
    expect(normalized.containsKey('legacy_group_id'), isFalse);
    expect(MangaImportMetadata.groupID(row), 42);
    final restored = Folder.fromJson(row);
    expect(restored.sourceGroupId, 42);
    expect(restored.name, 'Imported folder');
    expect(restored.id, created.id);
    expect(MangaImportMetadata.legacyGroupIDKey(['a_group_id', 'b_group_id']), isNull, reason: 'Two candidates name no single field');
  });

  test('history expires but saved multi tag search does not', () {
    final preferences = AppPreferences.memory()..defaults.set('search.retentionDays', 3);
    final manga = AppDatabase.inMemory(preferences: preferences);
    manga.recordSearch('tag:landscape tag:sky');
    manga.toggleSavedSearch('tag:landscape tag:sky');
    manga.dbWriter.write((db) => db.execute('UPDATE search_history SET used_at = ?', [unixSeconds(DateTime.now().subtract(const Duration(days: 4)))]));
    expect(manga.searchHistory(), isEmpty);
    expect(manga.savedSearches(), ['tag:landscape tag:sky']);
    manga.clearSearchHistory();
    expect(manga.savedSearches().length, 1);
  });
}
