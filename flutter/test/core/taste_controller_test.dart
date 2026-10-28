import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/core/insights.dart';
import 'package:tegnal/core/taste_controller.dart';
import 'package:tegnal/data/library_store.dart';

void main() {
  ContentItem item(int id, {String source = 'a'}) => ContentItem(
    sourceId: source,
    id: id,
    mode: AppMode.booru,
    title: 'Work $id',
    tags: const ['blue', 'sky'],
  );
  test('pause, reset and restart never reseed deleted evidence', () {
    final store = LibraryStore.memory();
    final control = LocalTasteController(store);
    final existing = SavedItem(item: item(1), savedAt: DateTime.utc(2026));
    store.saveItem(existing.item);
    control.seed([existing]);
    control.setEnabled(false);
    control.record('save', item(2));
    expect(control.analysisItems(AppMode.booru).map((e) => e.item.id), [1]);
    control.setEnabled(true);
    control.record('save', item(3));
    expect(control.analysisItems(AppMode.booru).map((e) => e.item.id), [1, 3]);
    control.reset();
    final restarted = LocalTasteController(store);
    restarted.seed([existing]);
    expect(restarted.analysisItems(AppMode.booru), isEmpty);
    expect(store.items(AppMode.booru).map((e) => e.item.id), [1]);
    restarted.record('save', item(4));
    expect(restarted.analysisItems(AppMode.booru).map((e) => e.item.id), [4]);
    store.database.close();
  });

  test('source exclusions and included filters remain source scoped', () {
    final store = LibraryStore.memory();
    store.setSetting('insights.exclusionsBySource.booru', {
      'a': ['blue'],
    });
    store.setSetting('recommendation.excludedTags', {
      'a': ['sky'],
    });
    store.setSetting('recommendation.includedTags', {
      'a': ['Blue Sky'],
    });
    final prefs = LocalTasteController(store).preferences(AppMode.booru);
    expect(prefs.allows('blue', 'a'), isFalse);
    expect(prefs.allows('blue', 'b'), isTrue);
    expect(prefs.allows('sky', 'a'), isFalse);
    expect(prefs.allows('sky', 'b'), isTrue);
    expect(prefs.includedBySource['a'], {'blue_sky'});
    expect(prefs.includedBySource['b'], isNull);
    store.database.close();
  });
  test('events keep earlier evidence and remove changes active saves', () {
    final store = LibraryStore.memory();
    final taste = LocalTasteController(store);
    taste.seed([]);
    for (var i = 0; i < 1001; i++) {
      taste.record('save', item(i));
    }
    expect(taste.analysisItems(AppMode.booru).length, 1001);
    taste.record('remove', item(0));
    taste.record('open', item(2000));
    expect(taste.analysisItems(AppMode.booru).length, 1000);
    expect(taste.observedItems(AppMode.booru).any((e) => e.id == 2000), isTrue);
    expect(taste.organicSavedItems(AppMode.booru).length, 1000);
    store.database.close();
  });
  test(
    'historical reports survive unsave and deduplicate activity by work',
    () {
      final store = LibraryStore.memory();
      final taste = LocalTasteController(store);
      final now = DateTime.utc(2026, 10, 28, 12);
      taste.seed([]);
      taste.record('save', item(1), at: now.subtract(const Duration(days: 2)));
      taste.record(
        'remove',
        item(1),
        at: now.subtract(const Duration(days: 1)),
      );
      taste.record(
        'open',
        item(1),
        at: now.subtract(const Duration(hours: 12)),
      );
      taste.record('open', item(1), at: now.subtract(const Duration(hours: 1)));
      expect(taste.analysisItems(AppMode.booru), isEmpty);
      final report = TasteAnalyzer.analyze(
        taste.analysisItems(AppMode.booru),
        mode: AppMode.booru,
        now: now,
        saveHistory: taste.historySaves(
          AppMode.booru,
          since: now.subtract(const Duration(days: 60)),
        ),
        openHistory: taste.historyOpens(
          AppMode.booru,
          since: now.subtract(const Duration(days: 60)),
        ),
      );
      expect(report.weekly.saves, 1);
      expect(report.weekly.opens, 1);
      expect(report.weekly.tags['a\nblue'], 1);
      taste.reset();
      expect(
        taste.historySaves(
          AppMode.booru,
          since: now.subtract(const Duration(days: 60)),
        ),
        isEmpty,
      );
      store.database.close();
    },
  );
  test('new import contributes nonorganic evidence but not save history', () {
    final store = LibraryStore.memory();
    final taste = LocalTasteController(store);
    taste.seed([]);
    taste.record('imported', item(7));
    expect(taste.analysisItems(AppMode.booru).map((e) => e.item.id), [7]);
    expect(taste.organicSavedItems(AppMode.booru), isEmpty);
    expect(
      taste.historySaves(AppMode.booru, since: DateTime.utc(2020)),
      isEmpty,
    );
    store.database.close();
  });
}
