import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tegnal/core/content.dart';
import 'package:tegnal/core/insights.dart';
import 'package:tegnal/core/library.dart';
import 'package:tegnal/core/recap.dart';
import 'package:tegnal/ui/recap_palette.dart';

void main() {
  final now = DateTime(2026, 10, 15, 12);
  DateTime date(int month, int day, {int hour = 12}) =>
      DateTime(2026, month, day, hour);
  ContentItem item(
    int id, {
    String source = 'a',
    List<String> tags = const ['sky'],
    List<String> artists = const [],
  }) => ContentItem(
    sourceId: source,
    id: id,
    mode: AppMode.booru,
    title: 'Work $id',
    tags: tags,
    artists: artists,
  );
  RecapEvent event(
    String kind,
    ContentItem content,
    DateTime at, {
    RecapDwell? dwell,
  }) => RecapEvent(kind: kind, item: content, at: at, dwell: dwell);
  RecapIndex index(
    List<RecapEvent> events, {
    Iterable<ContentItem>? visible,
    DateTime? savedAt,
    InsightPreferences? preferences,
  }) => RecapIndex(
    events,
    mode: AppMode.booru,
    preferences: preferences ?? InsightPreferences(mode: AppMode.booru),
    library: {
      for (final content in visible ?? events.map((entry) => entry.item))
        content.key: SavedItem(item: content, savedAt: savedAt ?? date(9, 1)),
    },
  );
  Recap september(RecapIndex built) =>
      built.recap(RecapPeriod.month, -1, now: now);

  group('viewing', () {
    test('counts foreground time and caps idle pages', () {
      final start = DateTime(2026);
      final session = ViewingSession()
        ..resume(start)
        ..show(0, at: start)
        ..show(1, at: start.add(const Duration(seconds: 30)))
        ..pause(start.add(const Duration(seconds: 40)))
        ..resume(start.add(const Duration(hours: 1)))
        ..show(
          2,
          isLast: true,
          at: start.add(const Duration(hours: 1, seconds: 10)),
        );
      final dwell = session.finish(start.add(const Duration(hours: 5)))!;
      expect(dwell.seconds, 30 + 10 + 10 + ViewingSession.idleLimit.inSeconds);
      expect(dwell.pages, 3);
      expect(dwell.finished, isTrue);
    });
    test('ignores glances and resets after finishing', () {
      final start = DateTime(2026);
      final session = ViewingSession()..resume(start);
      expect(session.finish(start.add(const Duration(seconds: 1))), isNull);
      expect(session.finish(start.add(const Duration(minutes: 5))), isNull);
    });
  });

  group('counting', () {
    test('compares with the previous period and counts distinct works', () {
      final recap = september(
        index([
          event('save', item(1), date(8, 10)),
          event('save', item(2), date(9, 3)),
          event('save', item(2), date(9, 4)),
          event('save', item(3), date(9, 4)),
          event('open', item(3), date(9, 5)),
          event('open', item(4), date(9, 6)),
          event('open', item(9), date(10, 2)),
        ]),
      );
      expect(recap.saves, 2);
      expect(recap.previousSaves, 1);
      expect(recap.opens, 2);
      expect(recap.activeDays, 4);
      expect(recap.longestStreak, 4);
      expect(recap.days, hasLength(30));
      expect(recap.isComplete, isTrue);
    });
    test('imports and seeds are history, not activity', () {
      final recap = september(
        index([
          event('seed', item(1), DateTime(2020)),
          event('imported', item(2), date(9, 2)),
          event('save', item(3), date(9, 2)),
        ]),
      );
      expect(recap.saves, 1);
      expect(recap.tags.single.isNew, isFalse);
    });
    test('viewing time adds up per work', () {
      final recap = september(
        index([
          event('save', item(1), date(9, 2)),
          event('open', item(1), date(9, 2)),
          event(
            'view',
            item(1),
            date(9, 2),
            dwell: const RecapDwell(seconds: 200, pages: 12, finished: true),
          ),
          event(
            'view',
            item(1),
            date(9, 3),
            dwell: const RecapDwell(seconds: 100, pages: 3),
          ),
        ]),
      );
      expect(recap.seconds, 300);
      expect(recap.pages, 15);
      expect(recap.finished, 1);
      expect(recap.opens, 1);
      expect(recap.revisited?.opens, 2);
    });
  });

  test('a single long visit is not coming back', () {
    final recap = september(
      index([
        event('save', item(1), date(9, 2)),
        event(
          'view',
          item(1),
          date(9, 2),
          dwell: const RecapDwell(seconds: 1800, pages: 40),
        ),
      ]),
    );
    expect(recap.revisited, isNull);
  });

  group('tags', () {
    test('the same tag across sources is one chart entry', () {
      final recap = september(
        index([
          event('save', item(1, source: 'a'), date(9, 2)),
          event('save', item(2, source: 'b'), date(9, 3)),
          event('save', item(3, source: 'b'), date(9, 4)),
        ]),
      );
      expect(recap.tags.single.count, 3);
      expect(recap.tags.single.source, 'b');
    });
    test('movement compares rank with the previous period', () {
      final events = [
        for (var id = 1; id <= 3; id++)
          event('save', item(id, tags: ['old']), date(8, 2)),
        event('save', item(4, tags: ['climber']), date(8, 2)),
        for (var id = 10; id <= 12; id++)
          event('save', item(id, tags: ['climber']), date(9, 2)),
        for (var id = 13; id <= 14; id++)
          event('save', item(id, tags: ['old']), date(9, 2)),
        event('save', item(15, tags: ['fresh']), date(9, 2)),
      ];
      final recap = september(index(events));
      expect(recap.tags.map((tag) => tag.name), ['climber', 'old', 'fresh']);
      expect(recap.tags[0].movement, 1);
      expect(recap.tags[1].movement, -1);
      expect(recap.tags[2].movement, isNull);
      expect(recap.tags[2].isNew, isTrue);
    });
    test('exclusions apply and artists are people, not tags', () {
      final content = item(
        1,
        tags: ['hidden_tag', 'sky', 'mira'],
        artists: ['mira'],
      );
      final recap = september(
        index(
          [event('save', content, date(9, 2))],
          preferences: InsightPreferences(
            mode: AppMode.booru,
            excludedTags: {'hidden_tag'},
          ),
        ),
      );
      expect(recap.tags.map((tag) => tag.name), ['sky']);
      expect(recap.people.single.name, 'mira');
    });
    test('anonymous credits never become the artist of the issue', () {
      final recap = september(
        index([
          event('save', item(1, artists: ['anonymous']), date(9, 2)),
        ]),
      );
      expect(recap.people, isEmpty);
    });
    test('signature sees past a tag on every work', () {
      final events = [
        for (var id = 1; id <= 30; id++)
          event('save', item(id, tags: ['scenery', 'forest']), date(5, 3)),
        for (var id = 31; id <= 36; id++)
          event('save', item(id, tags: ['scenery', 'aurora']), date(9, 3)),
      ];
      expect(september(index(events)).signature?.name, 'aurora');
    });
    test('comebacks need real history and a silent previous period', () {
      final events = [
        for (var id = 1; id <= 3; id++)
          event('save', item(id, tags: ['old_love']), date(4, 2)),
        for (var id = 4; id <= 7; id++)
          event('save', item(id, tags: ['main']), date(8, 2)),
        for (var id = 8; id <= 9; id++)
          event('save', item(id, tags: ['old_love', 'main']), date(9, 2)),
        for (var id = 10; id <= 12; id++)
          event('save', item(id, tags: ['main']), date(9, 3)),
      ];
      final highlight = september(index(events)).highlights.first;
      expect(highlight.kind, RecapHighlightKind.comeback);
      expect(highlight.tag.name, 'old_love');
    });
  });

  group('works', () {
    test('shows only the visible library while still counting', () {
      final recap = september(
        index(
          [
            event('save', item(1), date(9, 2)),
            event('save', item(2), date(9, 2)),
          ],
          visible: [item(2)],
        ),
      );
      expect(recap.saves, 2);
      expect(recap.saved.map((work) => work.item.id), [2]);
    });
    test('rediscovers old, unopened works matching current taste', () {
      final old = date(1, 5);
      final events = [
        event('save', item(1), date(9, 2)),
        event('save', item(10), old),
        event('save', item(11, tags: ['sea']), old),
        event('save', item(12), old),
        event('open', item(12), date(9, 1)),
        event('save', item(13), old),
        event('remove', item(13), date(2, 1)),
      ];
      final built = index(events, savedAt: old);
      expect(september(built).rediscover.map((work) => work.item.id), [10]);
      expect(
        built
            .recap(RecapPeriod.month, -1, now: now, rediscovers: false)
            .rediscover,
        isEmpty,
      );
    });
  });

  group('persona', () {
    test('comes from measured behavior and shows its evidence', () {
      final events = [
        for (var id = 1; id <= 6; id++)
          event('save', item(id, tags: ['a$id']), date(9, id + 3, hour: 23)),
      ];
      final persona = september(index(events)).persona!;
      expect(persona.rhythm, RecapRhythm.midnight);
      expect(persona.traits.first.arguments, ['100']);
    });
    test('waits for enough activity, and curators are selective', () {
      expect(
        september(index([event('save', item(1), date(9, 2))])).persona,
        isNull,
      );
      final events = [
        for (var id = 1; id <= 20; id++)
          event('open', item(id), date(9, 2 + id % 5, hour: 14)),
        for (var id = 1; id <= 2; id++)
          event('save', item(id), date(9, 5, hour: 14)),
      ];
      expect(september(index(events)).persona?.style, RecapStyle.curator);
    });
  });

  group('issues', () {
    test('pages include only what has something true to say', () {
      expect(RecapPage.pagesFor(september(index(const []))), [RecapPage.cover]);
      final single = september(index([event('save', item(1), date(9, 2))]));
      expect(RecapPage.pagesFor(single), [
        RecapPage.cover,
        RecapPage.numbers,
        RecapPage.chart,
        RecapPage.palette,
        RecapPage.next,
      ]);
    });
    test('skip silent months and number from the first', () {
      final issues = index([
        event('save', item(1), date(6, 2)),
        event('open', item(2), date(8, 2)),
        event('save', item(3), date(10, 2)),
      ]).issues(now: now);
      expect(issues.map((issue) => issue.issue), [3, 2, 1]);
      expect(issues.map((issue) => issue.offset), [0, -2, -4]);
    });
    test('week intervals start on Monday and years carry twelve months', () {
      final (start, end) = RecapIndex.interval(RecapPeriod.week, 0, now);
      expect(start.weekday, DateTime.monday);
      expect(end.difference(start).inDays, 7);
      final year = index([
        for (var id = 1; id <= 4; id++)
          event('save', item(id), date(id == 1 ? 3 : 7, 2)),
      ]).yearly(0, now: now);
      expect(year.months, hasLength(12));
      expect(year.months[6].saves, 3);
      expect(RecapPage.pagesFor(year), contains(RecapPage.year));
    });
    test('the sample issue runs through the real builder', () {
      for (final mode in AppMode.values) {
        final sample = recapSample(mode, now: now);
        expect(sample.isSample, isTrue);
        expect(sample.saves, 46);
        expect(sample.rediscover, isNotEmpty);
        expect(RecapPage.pagesFor(sample).length, greaterThanOrEqualTo(10));
      }
    });
    test('tag text drops search syntax', () {
      expect(recapTagText('female:big_hat'), 'big hat');
      expect(recapTagText('blue_sky'), 'blue sky');
    });
  });

  group('palette', () {
    test('is measured from color, not margins', () {
      final palette = RecapPalette.extract([
        ...List.filled(700, Colors.white),
        ...List.filled(300, const Color(0xFF1A40D9)),
      ])!;
      expect(palette.swatches, hasLength(5));
      expect(
        palette.swatches.first.b,
        greaterThan(palette.swatches.first.r * 2),
      );
      expect(palette.mood, 'deepSea');
      expect(RecapPalette.extract(const []), isNull);
    });
    test('keeps stage colors legible for any artwork', () {
      for (final color in [
        Colors.yellow,
        const Color(0xFF202020),
        Colors.red,
        Colors.grey,
      ]) {
        final palette = RecapPalette.extract(List.filled(50, color))!;
        expect(palette.ink.computeLuminance(), lessThan(.04));
        expect(palette.accent.computeLuminance(), greaterThan(.1));
      }
    });
    test('seeded colors are stable and round trip through storage', () {
      final palette = RecapPalette.seeded('sky');
      expect(RecapPalette.seeded('sky').toJson(), palette.toJson());
      expect(
        RecapPalette.fromJson(palette.toJson())!.toJson(),
        palette.toJson(),
      );
    });
  });
}
