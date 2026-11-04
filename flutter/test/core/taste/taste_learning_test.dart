import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_client.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/content/manga_urls.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/taste/recommendation_service.dart';
import 'package:tegnal/core/taste/taste_controller.dart';
import 'package:tegnal/core/taste/taste_learning.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_recap.dart';
import 'package:tegnal/core/taste/taste_store.dart';

const _source = 'https://a.example';
final _now = DateTime.fromMillisecondsSinceEpoch(1792033200 * 1000, isUtc: true);
var _counter = 0;

TasteEvent _event(
  TasteEventKind kind,
  int id, {
  List<String> tags = const [],
  double days = 1,
  DiscoveryContext? context,
  TasteDwell? dwell,
  TasteSignal? signal,
  String source = _source,
}) => TasteEvent(
  id: 'event-${++_counter}',
  kind: kind,
  item: TasteItem(source: source, id: id, tags: tags),
  context: context ?? DiscoveryContext(origin: DiscoveryOrigin.feed, session: 's'),
  dwell: dwell,
  signal: signal?.name,
  at: unixSeconds(_now) - days * 86400,
);

TasteLearning _learning(List<TasteEvent> events, {Map<String, RecapWorkInfo> library = const {}, TasteControl? control}) {
  final value = control ?? TasteControl();
  return TasteLearning(
    index: RecapIndex(events: events, control: value, mode: TasteMode.booru, library: library),
    control: value,
    now: _now,
  );
}

double _weight(TasteLearning model, String tag) => model.tags[TasteControl.tagKey(source: _source, tag: tag)]?.weight ?? 0;

TasteRecommendation _candidate(int id, List<String> tags, {double score = 0.2}) => TasteRecommendation(
  item: TasteItem(source: _source, id: id, tags: tags),
  reason: TasteTag(source: _source, name: tags.first),
  score: score,
  rankingTags: tags.toSet(),
);

/// A server whose first page always holds the same rainy posts.
class _PairSource implements BooruProviding {
  final queries = <String>[];
  @override
  Future<BooruBatch> posts(BooruServer server, String query, int page) async {
    queries.add(query);
    if (page != 0) return const BooruBatch(posts: [], hasMore: false);
    return BooruBatch(
      posts: [
        BooruFixtureSource.post(201, server, tags: const ['rain', 'umbrella']),
        BooruFixtureSource.post(202, server, tags: const ['rain']),
        BooruFixtureSource.post(203, server, tags: const ['rain', 'umbrella']),
        BooruFixtureSource.post(204, server, tags: const ['rain', 'lake']),
        BooruFixtureSource.post(205, server, tags: const ['rain', 'street']),
      ],
      hasMore: false,
    );
  }

  @override
  Future<List<BooruTag>> suggestions(BooruServer server, String token) async => [];
  @override
  Future<List<BooruPool>> pools(BooruServer server, String query, int page) async => [];
  @override
  Future<BooruBatch> poolPosts(BooruServer server, int poolID, int page) async => const BooruBatch(posts: [], hasMore: false);
  @override
  Future<List<BooruNote>> notes(BooruServer server, int postID) async => [];
  @override
  Future<BooruPost> details(BooruServer server, BooruPost post) async => post;
}

(TasteController, BooruServer, _PairSource) _environment() {
  final booru = BooruStore.inMemory();
  BooruFixtureEnvironment.seed(booru);
  final source = _PairSource();
  final controller = TasteController(
    library: AppDatabase.inMemory(),
    images: booru,
    content: ContentEnvironment.fixture(),
    booruSource: source,
    comicSource: FixtureContentSource(),
  );
  return (controller, BooruFixtureEnvironment.servers.first, source);
}

void main() {
  group('learning', () {
    test('recent saves outweigh old ones', () {
      final model = _learning([
        _event(TasteEventKind.save, 1, tags: ['new'], days: 2),
        _event(TasteEventKind.save, 2, tags: ['old'], days: 400),
      ]);
      expect(_weight(model, 'new'), greaterThan(_weight(model, 'old') * 20));
    });

    test('a save loses half its pull every half-life', () {
      final model = _learning([
        _event(TasteEventKind.save, 1, tags: ['a'], days: 0),
        _event(TasteEventKind.save, 2, tags: ['b'], days: TasteLearning.halfLife),
      ]);
      expect(_weight(model, 'b') / _weight(model, 'a'), closeTo(0.5, 0.001));
    });

    test('finished and long views teach, glances do not', () {
      final model = _learning([
        _event(TasteEventKind.open, 1, tags: ['read'], dwell: const TasteDwell(seconds: 240, pages: 30, finished: true)),
        _event(TasteEventKind.open, 2, tags: ['glance'], dwell: const TasteDwell(seconds: 8)),
        _event(TasteEventKind.open, 3, tags: ['opened']),
      ]);
      expect(_weight(model, 'read'), greaterThan(0.8));
      expect(_weight(model, 'glance'), 0);
      expect(_weight(model, 'opened'), 0);
    });

    test('imported libraries count less than deliberate saves', () {
      final model = _learning([
        _event(TasteEventKind.imported, 1, tags: ['imported']),
        _event(
          TasteEventKind.save,
          2,
          tags: ['chosen'],
          context: DiscoveryContext(origin: DiscoveryOrigin.search, query: 'chosen', session: 's'),
        ),
      ]);
      expect(_weight(model, 'chosen'), greaterThan(_weight(model, 'imported') * 3));
    });

    test('removing a work takes its evidence back', () {
      final model = _learning([
        _event(TasteEventKind.save, 1, tags: ['a']),
        _event(TasteEventKind.remove, 1, tags: ['a']),
      ]);
      expect(_weight(model, 'a'), lessThan(0.05));
      expect(model.ranked(), isEmpty);
    });

    test('excluded tags are never learned', () {
      final control = TasteControl()..setAnalysisExcluded({'blocked'}, TasteMode.booru);
      expect(
        _weight(
          _learning([
            _event(TasteEventKind.save, 1, tags: ['blocked', 'fine']),
          ], control: control),
          'blocked',
        ),
        0,
      );
    });
  });

  group('seen and dismissed', () {
    test('viewed works are seen, signals are not', () {
      final model = _learning([
        _event(TasteEventKind.open, 1, tags: ['a']),
        _event(TasteEventKind.open, 2, tags: ['a'], signal: TasteSignal.dismissed),
      ]);
      expect(model.seen, {'$_source#1'});
      expect(model.dismissed, {'$_source#2'});
    });

    test('undo restores a work and its tags', () {
      final events = [
        _event(TasteEventKind.save, 9, tags: ['a'], days: 3),
        _event(TasteEventKind.open, 1, tags: ['a'], signal: TasteSignal.dismissed),
        _event(TasteEventKind.open, 1, tags: ['a'], days: 0.5, signal: TasteSignal.restored),
      ];
      final model = _learning(events);
      expect(model.dismissed, isEmpty);
      final plain = _learning([events.first]).personalize(_candidate(5, ['a']));
      expect(model.personalize(_candidate(5, ['a'])).score, closeTo(plain.score, 0.01));
    });

    test('dismissing teaches against its tags', () {
      final base = [
        _event(TasteEventKind.save, 9, tags: ['kept'], days: 3),
      ];
      final dismissed = [
        ...base,
        for (var id = 1; id <= 4; id++) _event(TasteEventKind.open, id, tags: ['unwanted'], signal: TasteSignal.dismissed),
      ];
      expect(_learning(dismissed).personalize(_candidate(5, ['unwanted'])).score, lessThan(_learning(base).personalize(_candidate(5, ['unwanted'])).score));
    });

    test('feedback is not activity in the recap', () {
      final recap = RecapIndex(
        events: [
          _event(TasteEventKind.open, 1, tags: ['a'], signal: TasteSignal.dismissed),
          _event(TasteEventKind.save, 2, tags: ['a']),
        ],
        control: TasteControl(),
        mode: TasteMode.booru,
        library: const {},
      ).recap(period: TastePeriod.month, offset: 0, now: _now)!;
      expect(recap.opens, 0);
      expect(recap.saves, 1);
    });

    test('signals survive the wire, and a pause stops them', () {
      final store = AppDatabase.inMemory().tasteStore;
      store.recordSignal(TasteSignal.dismissed, TasteItem(source: _source, id: 1, tags: const ['a']));
      final saved = store.events().first;
      expect(saved.signal, 'dismissed');
      expect(saved.context.organic, isFalse);
      expect(encodeJsonString(_event(TasteEventKind.open, 1).toJson()).contains('signal'), isFalse);
      store.setControl(store.control()..enabled = false);
      store.recordSignal(TasteSignal.dismissed, TasteItem(source: _source, id: 2, tags: const ['a']));
      expect(store.events(), hasLength(1));
    });
  });

  group('steering', () {
    test('boosts steer the score and survive control coding', () {
      final key = TasteControl.tagKey(source: _source, tag: 'a');
      final control = TasteControl()
        ..setBoost(1, key)
        ..discoveryLevel = 2;
      final decoded = TasteControl.fromJson(decodeJsonObject(encodeSwiftJson(control.toJson())));
      expect(decoded.boost(key), 1);
      expect(decoded.discoveryLevel, 2);
      expect(TasteControl.fromJson(TasteControl().toJson()).tasteBoosts, isNull);
      final events = [
        _event(TasteEventKind.save, 1, tags: ['a']),
      ];
      final plain = _learning(events).personalize(_candidate(5, ['a'])).score;
      expect(_learning(events, control: control).personalize(_candidate(5, ['a'])).score, greaterThan(plain));
      final reduced = TasteControl()..setBoost(-1, key);
      expect(_learning(events, control: reduced).personalize(_candidate(5, ['a'])).score, lessThan(plain));
      control.setBoost(0, key);
      expect(control.tasteBoosts?[key], isNull);
    });

    test('deleting analysis also forgets steering', () {
      final (controller, _, _) = _environment();
      controller.change((control) {
        control
          ..setBoost(1, 's\na')
          ..discoveryLevel = 2;
      });
      controller.reset();
      expect(controller.control.tasteBoosts, isNull);
      expect(controller.control.discoveryLevel, isNull);
    });

    test('adventure favors unknown tags, familiar favors known ones', () {
      final events = [
        _event(TasteEventKind.save, 1, tags: ['known']),
      ];
      double score(int level) => _learning(events, control: TasteControl()..discoveryLevel = level).personalize(_candidate(5, ['strange', 'unseen'])).score;
      expect(score(0), lessThan(score(1)));
      expect(score(1), lessThan(score(2)));
      expect(
        [
          for (final level in [0, 1, 2]) _learning(events, control: TasteControl()..discoveryLevel = level).discoverySlots,
        ],
        [1, 3, 5],
      );
    });

    test('novel works take the discovery slots', () {
      final familiar = [
        for (var id = 1; id <= 12; id++) _candidate(id, ['a'], score: 1),
      ];
      final novel = [
        for (var id = 20; id <= 28; id++) _candidate(id, ['b'], score: 0.1)..novel = true,
      ];
      expect(RecommendationService.mix([...familiar, ...novel], limit: 10, discoverySlots: 5).where((item) => item.novel), hasLength(5));
      expect(RecommendationService.mix([...familiar, ...novel], limit: 10, discoverySlots: 1).where((item) => item.novel), hasLength(1));
    });
  });

  group('explanations', () {
    test('explanations cite what actually happened', () {
      final hidden = TasteTag(source: _source, name: 'quiet', hidden: 5, sessions: {'a', 'b', 'c'});
      final quiet = TasteRecommendation(
        item: TasteItem(source: _source, id: 7, tags: const ['quiet']),
        reason: hidden,
        score: 0.2,
        rankingTags: {'quiet'},
      );
      final model = _learning([
        _event(TasteEventKind.save, 1, tags: ['quiet'], days: 90),
      ]);
      expect(model.personalize(quiet).why, const WhyHidden('quiet'));
      final sky = _candidate(7, ['sky']);
      expect(
        _learning([
          for (var id = 1; id <= 4; id++) _event(TasteEventKind.save, id, tags: ['sky'], days: 3),
        ]).personalize(sky).why,
        const WhyRecent('sky'),
      );
      expect(
        _learning([
          for (var id = 1; id <= 4; id++) _event(TasteEventKind.save, id, tags: ['sky'], days: 200),
        ]).personalize(sky).why,
        const WhyTaste('sky'),
      );
      expect(model.personalize(sky, why: const WhyPopular()).why, const WhyPopular());
    });

    test('artists are credited and not counted as their own tag', () {
      final library = {
        for (var id = 1; id <= 4; id++) '$_source#$id': const RecapWorkInfo(artists: ['mira']),
      };
      final model = _learning([
        for (var id = 1; id <= 4; id++) _event(TasteEventKind.save, id, tags: ['mira', 'sky']),
      ], library: library);
      final result = model.personalize(_candidate(9, ['mira', 'sky']));
      expect(result.why, const WhyPerson('mira', RecapRole.artist, 4));
      expect(result.factors.where((factor) => factor.name == 'mira'), hasLength(1));
      expect(model.people.first.query, 'mira');
      expect(model.ranked().any((tag) => tag.name == 'mira'), isFalse);
    });

    test('no reason is ever invented for a cold start', () {
      expect(_learning([]).personalize(_candidate(1, ['sky'], score: 0), why: const WhyPopular()).why, const WhyPopular());
      expect(_learning([]).shelves(sources: [_source], tags: [], offset: 0), isEmpty);
    });
  });

  group('picks', () {
    TasteRecommendation item(int id, String tag, RecommendationWhy why, {bool novel = false}) => _candidate(id, [tag])
      ..why = why
      ..novel = novel;

    test('picks spread across reasons so one miss cannot sink the page', () {
      final deck = [
        item(1, 'a', const WhyTaste('a')),
        item(2, 'a', const WhyTaste('a')),
        item(3, 'a', const WhyTaste('a')),
        item(4, 'b', const WhyRecent('b')),
        item(5, 'c', const WhyNovel('c'), novel: true),
        item(6, 'd', const WhyTaste('d')),
      ];
      final picks = TasteRecommendation.picks(deck);
      expect(picks, hasLength(3));
      expect(picks.map((pick) => pick.reason.name).toSet(), hasLength(3));
      expect(picks.map((pick) => pick.id).toSet(), {'$_source#4', '$_source#1', '$_source#5'});
    });

    test('picks still fill when every work shares one reason', () {
      final deck = [
        for (var id = 1; id <= 5; id++) _candidate(id, ['a']),
      ];
      expect(TasteRecommendation.picks(deck).map((pick) => pick.id).toSet(), hasLength(3));
      expect(TasteRecommendation.picks(deck.take(2).toList()), hasLength(2));
      expect(TasteRecommendation.picks([]), isEmpty);
    });
  });

  group('shelves', () {
    test('shelves come from different reasons and rotate', () {
      final events = [
        for (var id = 1; id <= 6; id++) _event(TasteEventKind.save, id, tags: ['old_love', 'old_friend'], days: 300),
        for (var id = 10; id <= 14; id++) _event(TasteEventKind.save, id, tags: ['rain', 'umbrella'], days: 3),
        for (var id = 20; id <= 24; id++) _event(TasteEventKind.save, id, tags: ['snow'], days: 4),
      ];
      final library = {
        for (var id = 10; id <= 24; id++) '$_source#$id': const RecapWorkInfo(artists: ['mira']),
      };
      final model = _learning(events, library: library);
      final shelves = model.shelves(sources: [_source], tags: [], offset: 0);
      final kinds = shelves.map((shelf) => shelf.kind).toList();
      expect(kinds.toSet(), hasLength(shelves.length));
      expect(kinds, containsAll([TasteShelfKind.recent, TasteShelfKind.person, TasteShelfKind.comeback, TasteShelfKind.pair]));
      expect(shelves.map((shelf) => shelf.id), isNot(model.shelves(sources: [_source], tags: [], offset: 1).map((shelf) => shelf.id)));
      expect(model.shelves(sources: ['https://other.example'], tags: [], offset: 0), isEmpty);
    });

    test('a tag on everything never becomes a pair or a thread', () {
      final model = _learning([
        for (var id = 1; id <= 10; id++) _event(TasteEventKind.save, id, tags: ['scenery', 'rain', 'umbrella'], days: 3),
        for (var id = 11; id <= 30; id++) _event(TasteEventKind.save, id, tags: ['scenery', 'snow'], days: 3),
      ]);
      expect(model.recentTags.any((tag) => tag.name == 'scenery'), isFalse);
      expect(model.pairs.any((pair) => pair.$1.name == 'scenery' || pair.$2.name == 'scenery'), isFalse);
      expect(model.pairs.any((pair) => {pair.$1.name, pair.$2.name}.containsAll({'rain', 'umbrella'})), isTrue);
    });

    test('muted tags leave seeds, shelves and threads', () {
      final control = TasteControl()..setBoost(-1, TasteControl.tagKey(source: _source, tag: 'rain'));
      final model = _learning([
        for (var id = 1; id <= 5; id++) _event(TasteEventKind.save, id, tags: ['rain'], days: 3),
      ], control: control);
      expect(model.isMuted(TasteTag(source: _source, name: 'rain')), isTrue);
      expect(model.recentTags.any((tag) => tag.name == 'rain'), isFalse);
      expect(model.seedWeight(TasteTag(source: _source, name: 'rain')), lessThan(0));
    });

    test('person queries use each site syntax', () {
      expect(TasteLearnedPerson(source: MangaUrls.source, name: 'mira sato', role: RecapRole.artist, weight: 1).query, 'artist:mira_sato');
      expect(TasteLearnedPerson(source: MangaUrls.source, name: 'sky atlas', role: RecapRole.series, weight: 1).query, 'series:sky_atlas');
      expect(TasteLearnedPerson(source: _source, name: 'mira_sato', role: RecapRole.artist, weight: 1).query, 'mira_sato');
    });
  });

  group('retrieval', () {
    test('pair seeds require both tags and dismissed works stay away', () async {
      final (controller, server, source) = _environment();
      final address = server.canonicalAddress;
      final snapshot = TasteSnapshot(
        tags: [TasteTag(source: address, name: 'rain', general: 5)],
        saves: 5,
        opens: 0,
        searches: 0,
        activity: const {},
        digest: 'x',
      );
      final model = _learning([
        for (var id = 1; id <= 3; id++) _event(TasteEventKind.save, id, tags: ['rain'], source: address),
        _event(TasteEventKind.open, 203, tags: ['rain', 'umbrella'], signal: TasteSignal.dismissed, source: address),
      ]);
      final result = await RecommendationService.load(
        mode: TasteMode.booru,
        snapshot: snapshot,
        env: controller.environment,
        learning: model,
        seedOverride: {
          address: [TasteTag(source: address, name: 'rain umbrella', general: 1)],
        },
        whyOverride: const WhyPair('rain', 'umbrella'),
      );
      expect(result.items.map((item) => item.item.id), [201]);
      expect(result.items.first.why, const WhyPair('rain', 'umbrella'));
      expect(source.queries, hasLength(1));
      expect(source.queries.first, contains('rain umbrella'));
    });

    test('a cold start opens with popular works and says why', () async {
      final (controller, server, _) = _environment();
      final feed = controller.feed(TasteMode.booru, source: server.canonicalAddress);
      feed.refresh(TasteMode.booru);
      await feed.waitForRefresh();
      expect(feed.starter, isTrue);
      expect(feed.results.items, isNotEmpty);
      expect(feed.results.items.every((item) => item.why == const WhyPopular()), isTrue);
    });

    test('dismiss removes at once and undo restores the same place', () async {
      final (controller, server, _) = _environment();
      final feed = controller.feed(TasteMode.booru, source: server.canonicalAddress);
      feed.refresh(TasteMode.booru);
      await feed.waitForRefresh();
      final order = feed.results.items.map((item) => item.id).toList();
      final target = feed.results.items[1];
      feed.dismiss(target, TasteMode.booru);
      expect(feed.results.items.any((item) => item.id == target.id), isFalse);
      expect(feed.lastDismissed?.id, target.id);
      expect(controller.images.tasteStore.events().where((event) => event.signal == 'dismissed'), hasLength(1));
      feed.undoDismiss(TasteMode.booru);
      expect(feed.results.items.map((item) => item.id), order);
      expect(feed.lastDismissed, isNull);
      expect(controller.images.tasteStore.events().where((event) => event.signal == 'restored'), hasLength(1));
    });
  });
}
