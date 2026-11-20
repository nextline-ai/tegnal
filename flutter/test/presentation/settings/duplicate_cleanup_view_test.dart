// Ported from native-ios/TEGNALUITests/NativeContentUITests.swift (testDuplicateCleanupRemovesExtraCopiesInOneGoAndUndoes).
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/storage/folder_rules.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/presentation/settings/duplicate_cleanup_view.dart';

void main() {
  testWidgets('duplicates are cleaned up in one go with the chosen keeper, and undone', (tester) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('duplicates-view');
    addTearDown(() => directory.deleteSync(recursive: true));
    final database = AppDatabase.inMemory(preferences: AppPreferences.memory());
    final images = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    final mine = database.createFolder(name: 'Mine');
    database.upsertWork(galleryId: 10, folderId: mine.id, title: '[Circle] Summer [Korean]', artists: 'Author', language: 'korean', bookmarkedAt: '2026-01-05T09:00:00Z');
    database.upsertWork(galleryId: 30, title: '[Circle] Summer [Korean] [Team B]', artists: 'Author', language: 'korean', bookmarkedAt: '2026-03-05T09:00:00Z');
    database.upsertWork(galleryId: 40, title: '[Group] Winter (Stories)', artists: 'Other', language: 'korean', bookmarkedAt: '2026-01-10T09:00:00Z');
    database.upsertWork(galleryId: 50, title: '[Group] Winter [Korean]', artists: 'Other', language: 'korean', bookmarkedAt: '2026-04-10T09:00:00Z');

    ContentPreferences.defaults.set('library.duplicateCleanup', '{"match":"sameTitle"}');
    addTearDown(() => ContentPreferences.defaults.remove('library.duplicateCleanup'));
    await tester.pumpWidget(CupertinoApp(home: DuplicateCleanupView(database: database, images: images)));
    await tester.pumpAndSettle();
    expect(find.text('2 duplicate groups · 2 copies to remove'), findsOneWidget);

    // Keep the later copy of the second work instead.
    final later = find.bySemanticsIdentifier('duplicates.copy.50');
    await tester.dragUntilVisible(later, find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(later), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(later);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean Up 2 Copies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean Up'));
    await tester.pumpAndSettle();
    expect(database.getWork(30), isNull);
    expect(database.getWork(40), isNull, reason: 'The copy chosen by hand stayed instead');
    expect(database.getWork(50), isNotNull);
    expect(find.text('Removed 2 copies'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(database.getWork(30), isNotNull);
    expect(database.getWork(40), isNotNull);
    await tester.scrollUntilVisible(find.text('2 duplicate groups · 2 copies to remove'), -300, scrollable: find.byType(Scrollable).first);
    expect(find.text('2 duplicate groups · 2 copies to remove'), findsOneWidget);
  });

  testWidgets('the same work number in two folders is found first and stays in one of them', (tester) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final directory = Directory.systemTemp.createTempSync('duplicates-number');
    addTearDown(() => directory.deleteSync(recursive: true));
    final database = AppDatabase.inMemory(preferences: AppPreferences.memory());
    final images = BooruStore(path: '${directory.path}/booru.sqlite', preferences: AppPreferences.memory());
    final first = database.createFolder(name: 'First'), second = database.createFolder(name: 'Second');
    database.upsertWork(galleryId: 7, folderId: first.id, title: 'Seven');
    database.addWork(7, second.id!);
    ContentPreferences.defaults.remove('library.duplicateCleanup');
    await tester.pumpWidget(CupertinoApp(home: DuplicateCleanupView(database: database, images: images)));
    await tester.pumpAndSettle();
    expect(find.text('1 works in several folders · 1 folders to leave'), findsOneWidget);
    await tester.tap(find.text('Tidy 1 Works'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clean Up'));
    await tester.pumpAndSettle();
    expect(database.getWork(7)?.folders.map((folder) => folder.name).toList(), ['First']);
    expect(find.text('Tidied 1 works'), findsOneWidget);
  });
}
