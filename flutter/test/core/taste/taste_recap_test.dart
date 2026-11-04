import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/l10n.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/taste/recap_shelf.dart';
import 'package:tegnal/core/taste/taste_controller.dart';
import 'package:tegnal/core/taste/taste_fixtures.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_recap.dart';
import 'package:tegnal/core/taste/taste_store.dart';

// Dart has no time-zone database, so these run in UTC; boundaries follow the
// analysis zone the same way the native tests check them in a fixed zone.
const _zone = 'UTC';
const _source = 'https://a.example';

/// 15 Oct 2026: October is the open month, September the last complete one.
final _now = DateTime.fromMillisecondsSinceEpoch(1792033200 * 1000, isUtc: true);
final _control = TasteControl(timeZone: _zone);
var _counter = 0;

DateTime _date(int month, int day, {int hour = 12}) => DateTime.utc(2026, month, day, hour);

TasteEvent _event(
  TasteEventKind kind,
  int id, {
  List<String> tags = const [],
  required DateTime at,
  String source = _source,
  DiscoveryContext? context,
  TasteDwell? dwell,
}) => TasteEvent(
  id: 'event-${++_counter}',
  epoch: _control.epoch,
  kind: kind,
  item: TasteItem(source: source, id: id, tags: tags),
  context: context ?? DiscoveryContext(origin: DiscoveryOrigin.feed, session: 's'),
  dwell: dwell,
  at: unixSeconds(at),
);

RecapIndex _index(List<TasteEvent> events, {Map<String, RecapWorkInfo> library = const {}, TasteControl? control}) =>
    RecapIndex(events: events, control: control ?? _control, mode: TasteMode.booru, library: library);

TasteRecap _september(List<TasteEvent> events, {Map<String, RecapWorkInfo> library = const {}}) =>
    _index(events, library: library).recap(period: TastePeriod.month, offset: -1, now: _now)!;

Map<String, RecapWorkInfo> _info(int first, int last, {String? artist, DateTime? savedAt}) => {
  for (var id = first; id <= last; id++) '$_source#$id': RecapWorkInfo(artists: [?artist], savedAt: savedAt),
};

DiscoveryContext _search(String query, String session) => DiscoveryContext(origin: DiscoveryOrigin.search, query: query, session: session);

void main() {
  group('counting', () {
    test('totals compare with the previous period and count distinct works', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(8, 10)),
        _event(TasteEventKind.save, 2, tags: ['a'], at: _date(9, 3)),
        _event(TasteEventKind.save, 2, tags: ['a'], at: _date(9, 4)),
        _event(TasteEventKind.save, 3, tags: ['a'], at: _date(9, 4)),
        _event(TasteEventKind.open, 3, at: _date(9, 5)),
        _event(TasteEventKind.open, 4, at: _date(9, 6)),
        _event(TasteEventKind.open, 9, at: _date(10, 2)),
        _event(TasteEventKind.search, 0, tags: ['a'], at: _date(9, 6), context: _search('a', 'q1')),
        _event(TasteEventKind.search, 0, tags: ['b'], at: _date(9, 6), context: _search('b', 'q1')),
        _event(TasteEventKind.search, 0, tags: ['c'], at: _date(9, 7), context: _search('c', 'q2')),
      ]);
      expect(recap.saves, 2);
      expect(recap.previousSaves, 1);
      expect(recap.opens, 2);
      expect(recap.searches, 2);
      expect(recap.isComplete, isTrue);
      expect(recap.activeDays, 4);
      expect(recap.longestStreak, 4);
      expect(recap.days, hasLength(30));
    });

    test('period boundaries follow the analysis time zone', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(9, 30, hour: 23)),
        _event(TasteEventKind.save, 2, tags: ['a'], at: _date(10, 1, hour: 0)),
      ]);
      expect(recap.saves, 1);
      expect(recap.hours[23], 1);
    });

    test('imports and seeds are history, not activity', () {
      final recap = _september([
        _event(TasteEventKind.imported, 1, tags: ['a'], at: _date(9, 2)),
        _event(TasteEventKind.seed, 2, tags: ['a'], at: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
        _event(TasteEventKind.save, 3, tags: ['a'], at: _date(9, 2)),
      ]);
      expect(recap.saves, 1);
      expect(recap.tags.first.isNew, isFalse);
    });

    test('viewing time adds up and an open with its dwell is one visit', () {
      final context = DiscoveryContext(origin: DiscoveryOrigin.feed, session: 'one');
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(9, 2), context: context),
        _event(TasteEventKind.open, 1, at: _date(9, 2), context: context),
        _event(TasteEventKind.open, 1, at: _date(9, 2), context: context, dwell: const TasteDwell(seconds: 200, pages: 12, finished: true)),
        _event(TasteEventKind.open, 1, at: _date(9, 3), context: context, dwell: const TasteDwell(seconds: 100, pages: 3)),
      ], library: _info(1, 1));
      expect(recap.seconds, 300);
      expect(recap.pages, 15);
      expect(recap.finished, 1);
      expect(recap.opens, 1);
      expect(recap.revisited?.opens, 2);
      expect(recap.hours.reduce((a, b) => a + b), 2);
    });

    test('a single long visit is not coming back', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(9, 2)),
        _event(TasteEventKind.open, 1, at: _date(9, 2), dwell: const TasteDwell(seconds: 1800, pages: 40)),
      ], library: _info(1, 1));
      expect(recap.revisited, isNull);
    });
  });

  group('tags', () {
    test('the same tag across sources is one entry attributed to its largest source', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['sky'], at: _date(9, 2)),
        _event(TasteEventKind.save, 2, tags: ['sky'], at: _date(9, 3), source: 'https://b.example'),
        _event(TasteEventKind.save, 3, tags: ['sky'], at: _date(9, 4), source: 'https://b.example'),
      ]);
      expect(recap.tags, hasLength(1));
      expect(recap.tags.first.count, 3);
      expect(recap.tags.first.source, 'https://b.example');
    });

    test('chart movement compares rank with the previous period', () {
      final recap = _september([
        for (var id = 1; id <= 3; id++) _event(TasteEventKind.save, id, tags: ['old'], at: _date(8, 2)),
        _event(TasteEventKind.save, 4, tags: ['climber'], at: _date(8, 2)),
        for (var id = 10; id <= 12; id++) _event(TasteEventKind.save, id, tags: ['climber'], at: _date(9, 2)),
        for (var id = 13; id <= 14; id++) _event(TasteEventKind.save, id, tags: ['old'], at: _date(9, 2)),
        _event(TasteEventKind.save, 15, tags: ['fresh'], at: _date(9, 2)),
      ]);
      expect(recap.tags.map((tag) => tag.name), ['climber', 'old', 'fresh']);
      expect(recap.tags[0].movement, 1);
      expect(recap.tags[1].movement, -1);
      expect(recap.tags[2].movement, isNull);
      expect(recap.tags[2].isNew, isTrue);
    });

    test('the chart drops analysis exclusions and people are not tags', () {
      final custom = TasteControl(timeZone: _zone)..setAnalysisExcluded({'hidden_tag'}, TasteMode.booru);
      final recap = _index(
        [
          _event(TasteEventKind.save, 1, tags: ['hidden_tag', 'sky', 'mira'], at: _date(9, 2)),
        ],
        library: _info(1, 1, artist: 'mira'),
        control: custom,
      ).recap(period: TastePeriod.month, offset: -1, now: _now)!;
      expect(recap.tags.map((tag) => tag.name), ['sky']);
      expect(recap.people.first.name, 'mira');
      expect(recap.people.first.role, RecapRole.artist);
    });

    test('anonymous credits never become the artist of the issue', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['sky'], at: _date(9, 2)),
      ], library: _info(1, 1, artist: 'anonymous'));
      expect(recap.people, isEmpty);
    });

    test('the signature is what set the period apart, not an everywhere tag', () {
      final recap = _september([
        for (var id = 1; id <= 30; id++) _event(TasteEventKind.save, id, tags: ['scenery', 'forest'], at: _date(5, 3)),
        for (var id = 31; id <= 36; id++) _event(TasteEventKind.save, id, tags: ['scenery', 'aurora'], at: _date(9, 3)),
      ]);
      expect(recap.tags.first.name, 'aurora', reason: 'ties break by name; both appear six times');
      expect(recap.signature?.name, 'aurora');
    });
  });

  group('highlights', () {
    test('a hidden preference needs five works across three sessions without a search', () {
      final events = [
        for (var id = 1; id <= 5; id++) _event(TasteEventKind.save, id, tags: ['top', 'quiet'], at: _date(9, id), context: _search('top', 's${id % 3}')),
        for (var id = 6; id <= 9; id++) _event(TasteEventKind.save, id, tags: ['top'], at: _date(9, id), context: _search('top', 't')),
      ];
      expect(_september(events).highlights.first.kind, RecapHighlightKind.hidden);
      expect(_september(events).highlights.first.tag.name, 'quiet');
      final searched = [
        ...events,
        _event(TasteEventKind.search, 0, tags: ['quiet'], at: _date(8, 1), context: _search('quiet', 'x')),
      ];
      expect(_september(searched).highlights.firstOrNull?.kind, isNot(RecapHighlightKind.hidden));
    });

    test('a comeback needs real history and a silent previous period', () {
      final recap = _september([
        for (var id = 1; id <= 3; id++) _event(TasteEventKind.save, id, tags: ['old_love'], at: _date(4, 2)),
        for (var id = 4; id <= 7; id++) _event(TasteEventKind.save, id, tags: ['main'], at: _date(8, 2)),
        for (var id = 8; id <= 9; id++) _event(TasteEventKind.save, id, tags: ['old_love', 'main'], at: _date(9, 2)),
        for (var id = 10; id <= 12; id++) _event(TasteEventKind.save, id, tags: ['main'], at: _date(9, 3)),
      ]);
      expect(recap.highlights.first.kind, RecapHighlightKind.comeback);
      expect(recap.highlights.first.tag.name, 'old_love');
    });

    test('newcomers and risers rank behind rarer patterns', () {
      final recap = _september([
        for (var id = 1; id <= 2; id++) _event(TasteEventKind.save, id, tags: ['riser'], at: _date(8, 2)),
        for (var id = 3; id <= 7; id++) _event(TasteEventKind.save, id, tags: ['riser'], at: _date(9, 2)),
        for (var id = 8; id <= 10; id++) _event(TasteEventKind.save, id, tags: ['brand_new'], at: _date(9, 2)),
      ]);
      expect(recap.highlights.map((highlight) => highlight.kind), [RecapHighlightKind.newcomer, RecapHighlightKind.rising]);
    });
  });

  group('works', () {
    test('displayed works come only from the visible library', () {
      final recap = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(9, 2)),
        _event(TasteEventKind.save, 2, tags: ['a'], at: _date(9, 2)),
      ], library: _info(2, 2));
      expect(recap.saves, 2, reason: 'hidden works still count');
      expect(recap.saved.map((work) => work.item.id), [2], reason: 'but are never shown');
    });

    test('the cover is the work most like the period', () {
      final events = [
        _event(TasteEventKind.save, 1, tags: ['a', 'b'], at: _date(9, 2)),
        _event(TasteEventKind.save, 2, tags: ['a', 'b'], at: _date(9, 2)),
        _event(TasteEventKind.save, 3, tags: ['a', 'rare'], at: _date(9, 2)),
        _event(TasteEventKind.save, 4, tags: ['a', 'b'], at: _date(9, 2)),
        _event(TasteEventKind.save, 5, tags: ['other'], at: _date(9, 2)),
      ];
      final cover = _september(events, library: _info(1, 5)).cover?.item.id;
      expect(cover, isNot(5));
      expect(cover, isNot(3));
    });

    test('rediscovery offers old unopened works matching current taste', () {
      final old = _date(1, 5);
      final events = [
        _event(TasteEventKind.save, 1, tags: ['sky'], at: _date(9, 2)),
        _event(TasteEventKind.save, 10, tags: ['sky'], at: old), // match
        _event(TasteEventKind.save, 11, tags: ['sea'], at: old), // different taste
        _event(TasteEventKind.save, 12, tags: ['sky'], at: old), // opened recently
        _event(TasteEventKind.open, 12, at: _date(9, 1)),
        _event(TasteEventKind.save, 13, tags: ['sky'], at: old), // removed
        _event(TasteEventKind.remove, 13, at: _date(2, 1)),
        _event(TasteEventKind.save, 14, tags: ['sky'], at: _date(9, 1)), // saved this month
      ];
      final library = _info(1, 14, savedAt: old);
      expect(_september(events, library: library).rediscover.map((work) => work.item.id), [10]);
      expect(_index(events, library: library).recap(period: TastePeriod.month, offset: -1, now: _now, rediscovers: false)!.rediscover, isEmpty);
    });
  });

  group('persona', () {
    test('the persona comes from measured behavior and shows its evidence', () {
      final persona = _september([
        for (var id = 1; id <= 6; id++) _event(TasteEventKind.save, id, tags: ['a$id'], at: _date(9, id + 3, hour: 23), context: _search('a$id', 's$id')),
      ]).persona!;
      expect(persona.rhythm, RecapRhythm.midnight);
      expect(persona.style, RecapStyle.hunter);
      expect(persona.traits.any((line) => line.key.contains('after 10 PM') && line.arguments.join() == '100'), isTrue);
      expect(persona.traits.any((line) => line.key.contains('searches') && line.arguments.join() == '100'), isTrue);
    });

    test('the persona waits for enough activity and a curator is selective', () {
      expect(
        _september([
          for (var id = 1; id <= 2; id++) _event(TasteEventKind.save, id, tags: ['a'], at: _date(9, 2)),
        ]).persona,
        isNull,
      );
      final recap = _september([
        for (var id = 1; id <= 20; id++) _event(TasteEventKind.open, id, at: _date(9, 2 + id % 5, hour: 14)),
        for (var id = 1; id <= 2; id++) _event(TasteEventKind.save, id, tags: ['a'], at: _date(9, 5, hour: 14)),
      ]);
      expect(recap.persona?.style, RecapStyle.curator);
    });

    test('every persona and palette mood is localized', () {
      for (final language in ['ko', 'ja', 'en']) {
        final table = jsonDecode(File('assets/l10n/$language.json').readAsStringSync()) as Map<String, Object?>;
        final keys = [
          for (final rhythm in RecapRhythm.values) 'persona.rhythm.${rhythm.name}',
          for (final style in RecapStyle.values) ...['persona.style.${style.name}', 'persona.summary.${style.name}'],
          for (final mood in ['ember', 'amber', 'honey', 'moss', 'lagoon', 'deepSea', 'twilight', 'iris', 'peony', 'ink', 'ash', 'paper']) 'palette.$mood',
        ];
        for (final key in keys) {
          expect(table[key], isA<String>(), reason: '$language $key');
          expect(table[key], isNot(key), reason: '$language $key');
        }
      }
    });
  });

  group('pages and issues', () {
    test('the story only includes pages with something true to say', () {
      expect(RecapPage.pages(_september([])), [RecapPage.cover]);
      final single = _september([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(9, 2)),
      ], library: _info(1, 1));
      expect(RecapPage.pages(single), [RecapPage.cover, RecapPage.numbers, RecapPage.chart, RecapPage.palette, RecapPage.next]);
      final week = _index([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(10, 13)),
        _event(TasteEventKind.save, 2, tags: ['a'], at: _date(10, 14)),
      ], library: _info(1, 2, artist: 'mira')).recap(period: TastePeriod.week, offset: 0, now: _now)!;
      expect(RecapPage.pages(week), isNot(contains(RecapPage.person)));
      expect(RecapPage.pages(week), isNot(contains(RecapPage.palette)));
      expect(week.isComplete, isFalse);
    });

    test('issues skip silent months and number from the first', () {
      final issues = _index([
        _event(TasteEventKind.save, 1, tags: ['a'], at: _date(6, 2)),
        _event(TasteEventKind.open, 2, at: _date(8, 2)),
        _event(TasteEventKind.save, 3, tags: ['a'], at: _date(10, 2)),
      ]).issues(now: _now);
      expect(issues.map((recap) => recap.issue), [3, 2, 1]);
      expect(issues.map((recap) => recap.offset), [0, -2, -4]);
      expect(_index([]).issues(now: _now), isEmpty);
    });

    test('a year carries twelve months with their busiest', () {
      final recap = _index([
        for (var id = 1; id <= 4; id++) _event(TasteEventKind.save, id, tags: ['a'], at: _date(id == 1 ? 3 : 7, 2)),
      ]).yearly(offset: 0, now: _now)!;
      expect(recap.months, hasLength(12));
      expect(recap.months[2].saves, 1);
      expect(recap.months[6].saves, 3);
      expect(RecapPage.pages(recap), contains(RecapPage.year));
    });

    test('sample issues run through the real builder in both modes', () {
      for (final mode in TasteMode.values) {
        final sample = TasteRecapSample.sample(mode: mode, now: _now, timeZone: _zone)!;
        expect(sample.isSample, isTrue);
        expect(sample.saves, 46);
        expect(sample.persona, isNotNull);
        expect(sample.rediscover, isNotEmpty);
        expect(RecapPage.pages(sample).length, greaterThanOrEqualTo(10));
        expect(sample.saved.every((work) => !work.item.source.contains('.example')), isTrue);
      }
    });
  });

  group('text', () {
    tearDown(() {
      L10n.language = 'en';
      L10n.table = const {};
    });

    test('tag text drops search syntax and durations read', () {
      expect(RecapText.tag('female:big_hat'), 'big hat');
      expect(RecapText.tag('blue_sky'), 'blue sky');
      expect(RecapText.duration(30), isNotEmpty);
      expect(RecapText.duration(3600), isNot(RecapText.duration(3660)));
    });

    test('percent sentences format in every language', () {
      for (final language in ['en', 'ko', 'ja']) {
        L10n.language = language;
        L10n.table = {
          for (final entry in (jsonDecode(File('assets/l10n/$language.json').readAsStringSync()) as Map<String, Object?>).entries)
            entry.key: entry.value! as String,
        };
        final share = RecapLine('%@%% of saves came from your searches', ['62']).text;
        expect(share.replaceAll('⁠', ''), contains('62%'), reason: language);
        expect(share, isNot(contains('%%')), reason: language);
        expect(RecapLine('You kept %@ of %@ works you opened', ['3', '20']).text.replaceAll('⁠', ''), contains('20'), reason: language);
      }
    });

    test('titles name the period in the app language', () {
      final recap = _september([]);
      final previous = TasteControl.currentTimeZone;
      TasteControl.currentTimeZone = _zone;
      addTearDown(() => TasteControl.currentTimeZone = previous);
      expect(RecapFormat.title(recap), 'September 2026');
      L10n.language = 'ko';
      expect(RecapFormat.title(recap), '2026년 9월');
      L10n.language = 'ja';
      expect(RecapFormat.title(recap), '2026年9月');
      expect(RecapFormat.signed(1234), '+1,234');
      expect(RecapFormat.signed(-3), '-3');
    });
  });

  group('palette', () {
    test('the palette is measured from color, not from margins', () {
      const blue = RecapColor(0.1, 0.25, 0.85), white = RecapColor(1, 1, 1);
      final palette = RecapPalette.extract([...List.filled(700, white), ...List.filled(300, blue)])!;
      expect(palette.swatches, hasLength(5));
      expect(palette.swatches.first.blue, greaterThan(palette.swatches.first.red * 2));
      expect(palette.mood, 'deepSea');
      expect(RecapPalette.extract([]), isNull, reason: 'without covers the caller keeps its seeded colors');
      expect(RecapPalette.extract(List.filled(20, const RecapColor(0, 0, 0))), isNull);
    });

    test('stage colors stay legible for any artwork', () {
      for (final color in const [RecapColor(1, 1, 0.9), RecapColor(0.12, 0.12, 0.12), RecapColor(1, 0, 0), RecapColor(0.5, 0.5, 0.5)]) {
        final palette = RecapPalette.extract(List.filled(50, color))!;
        expect(palette.ink.luminance, lessThan(0.14));
        expect(palette.accent.luminance, greaterThan(palette.ink.luminance + 0.3));
      }
    });

    test('a seeded palette is stable and colors round-trip', () {
      expect(RecapPalette.seeded('sky'), RecapPalette.seeded('sky'));
      expect(RecapPalette.seeded('sky'), isNot(RecapPalette.seeded('sea')));
      const color = RecapColor(0.2, 0.6, 0.4);
      final value = color.hsb;
      final back = RecapColor.hsb(value.$1, value.$2, value.$3);
      expect(back.red, closeTo(color.red, 0.001));
      expect(back.blue, closeTo(color.blue, 0.001));
      expect(const RecapColor(1, 0, 0).argb, 0xFFFF0000);
      expect(const RecapColor(0, 0.5, 1).hex, '#007FFF');
      expect(RecapPalette.fromJson(decodeJsonObject(encodeSwiftJson(RecapPalette.seeded('sky').toJson()))), RecapPalette.seeded('sky'));
    });

    test('decoded pixels become colors', () {
      expect(RecapPalette.pixels([255, 0, 0, 255, 0, 255, 0, 128]), [const RecapColor(1, 0, 0), const RecapColor(0, 1, 0)]);
    });

    test('deleting analysis also deletes measured recap colors', () {
      final store = AppDatabase.inMemory().tasteStore;
      store.setMetadata(RecapPalette.seeded('x').toJson(), 'recap.palette.booru:month:1');
      store.setControl(store.control()..epoch = 'next');
      expect(store.metadata('recap.palette.booru:month:1'), isNull);
    });
  });

  group('shelf', () {
    TasteController controller() {
      final booru = BooruStore.inMemory();
      BooruFixtureEnvironment.seed(booru);
      return TasteController(
        library: AppDatabase.inMemory(),
        images: booru,
        content: ContentEnvironment.fixture(),
        booruSource: BooruFixtureSource(),
        comicSource: FixtureContentSource(),
      );
    }

    test('an empty library shows the sample issue', () {
      final shelf = RecapShelf(controller: controller(), mode: TasteMode.booru)..load(key: 'a', now: _now);
      expect(shelf.loaded, isTrue);
      expect(shelf.failed, isFalse);
      expect(shelf.issues, isEmpty);
      expect(shelf.latest, isNull);
      expect(shelf.sample?.isSample, isTrue);
    });

    test('a demo library fills the shelf and measured colors are kept', () async {
      final taste = controller();
      TasteFixtures.seedRecapDemo(taste.images, now: _now);
      final shelf = RecapShelf(controller: taste, mode: TasteMode.booru)..load(key: 'a', now: _now);
      expect(shelf.issues.length, greaterThanOrEqualTo(12));
      expect(shelf.sample, isNull);
      final latest = shelf.latest!;
      expect(latest.isComplete, isTrue);
      expect(shelf.pastIssues.any((recap) => recap.id == latest.id), isFalse);
      expect(shelf.recap(latest.interval.start)?.id, latest.id);
      expect(shelf.year, isNotNull);
      expect(shelf.opened(latest).issue, latest.issue);
      expect(shelf.palette(latest), RecapPalette.seeded(latest.tags.first.name));

      var calls = 0;
      await shelf.measure(latest, (work, {required generated}) async {
        calls += 1;
        return [20, 60, 220, 255];
      });
      expect(calls, greaterThan(0));
      expect(shelf.palette(latest).mood, 'deepSea');
      final again = RecapShelf(controller: taste, mode: TasteMode.booru)..load(key: 'b', now: _now);
      expect(again.palette(again.latest!), shelf.palette(latest), reason: 'a complete issue keeps its measured colors');
    });
  });
}
