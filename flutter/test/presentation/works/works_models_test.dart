// Saved-works helpers from native-ios/TEGNALTests/NativeContentTests.swift
// (testSearchVisibilityAccumulatesSlowScrollAndKeepsFocusedSearchVisible and
// testMonthDestinationsPreserveVisibleOrderAndCounts).

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/domain/models.dart';
import 'package:tegnal/presentation/works/works_models.dart';

void main() {
  test('search visibility accumulates slow scrolls and keeps a focused search visible', () {
    final tracker = ScrollSearchVisibility();
    for (var y = 100.0; y <= 128; y += 4) {
      expect(
        tracker.update(oldY: y, newY: y + 4, focused: false),
        y == 128 ? false : null,
        reason: '$y',
      );
    }
    expect(tracker.update(oldY: 132, newY: 130, focused: false), isNull);
    expect(tracker.update(oldY: 130, newY: 108, focused: false), isTrue);
    expect(tracker.update(oldY: 108, newY: 160, focused: true), isTrue);
    expect(tracker.update(oldY: 160, newY: 0, focused: false), isTrue);
  });

  test('month destinations preserve visible order and counts', () {
    final works = [
      Work(galleryId: 30, bookmarkedAt: '2026-10-04T00:00:00Z'),
      Work(galleryId: 20, bookmarkedAt: '2026-10-01T00:00:00Z'),
      Work(galleryId: 10, bookmarkedAt: '2025-12-01T00:00:00Z'),
    ];
    final months = WorkMonthDestination.make(works);
    expect(months.map((month) => month.id), ['2026-10', '2025-12']);
    expect(months.map((month) => month.firstGalleryID), [30, 10]);
    expect(months.map((month) => month.count), [2, 1]);
    expect(months.last.title, L10n.text('%@-%@', ['2025', '12']));
    expect(WorkMonthDestination.make([]), isEmpty);
    expect(WorkMonthDestination.make([works[1]]).first.firstGalleryID, 20);
    expect(WorkMonthDestination(id: 'unknown', firstGalleryID: 1).title, L10n.text('No Date'));
  });

  test('works saved together are found by their saved times', () {
    Work work(int id, String time) => Work(galleryId: id, bookmarkedAt: time);
    // Newest first, as the library lists them.
    final works = [
      work(1, '2026-11-15T14:00:30Z'),
      work(2, '2026-11-15T14:00:10Z'),
      work(3, '2026-11-15T14:00:05Z'),
      work(4, '2026-11-15T13:59:50Z'),
      work(5, '2026-11-15T13:59:20Z'),
      work(6, '2026-11-15T12:00:00Z'),
      work(7, '2026-11-01T09:00:02Z'),
      work(8, '2026-11-01T09:00:01Z'),
      work(9, 'not a date'),
    ];
    final batches = WorkSaveBatch.make(works, minimum: 2);
    expect(batches.map((batch) => batch.ids), [
      [1, 2, 3, 4, 5],
      [7, 8],
    ], reason: 'Each saved within a minute of the one before, newest run first');
    expect(batches.first.firstGalleryID, 1);
    expect(batches.first.broughtIn([DateTime.parse('2026-11-15T13:59:00Z')]), isTrue);
    expect(batches.last.broughtIn([DateTime.parse('2026-11-15T13:59:00Z')]), isFalse);
    expect(WorkSaveBatch.make(works).every((batch) => batch.ids.length >= WorkSaveBatch.minimum), isTrue, reason: 'A couple of saves are not a run');
    expect(WorkMonthDestination.make(works).first.ids, [1, 2, 3, 4, 5, 6, 7, 8]);
  });
}
