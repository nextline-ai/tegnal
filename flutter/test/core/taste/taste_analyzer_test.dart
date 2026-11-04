import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_models.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/taste/taste_analyzer.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_store.dart';

const _source = 'https://example.test';

TasteEvent _event(
  int id, {
  List<String> tags = const ['blue_hair', 'green_eyes'],
  String query = 'blue_hair',
  String session = 's1',
  TasteEventKind kind = TasteEventKind.save,
  double at = 100,
}) => TasteEvent(
  kind: kind,
  item: TasteItem(source: _source, id: id, tags: tags),
  context: DiscoveryContext(origin: DiscoveryOrigin.search, query: query, session: session),
  at: at,
);

TasteTag? _tag(TasteSnapshot snapshot, String name) => snapshot.tags.where((tag) => tag.name == name).firstOrNull;
DateTime _at(double seconds) => DateTime.fromMillisecondsSinceEpoch((seconds * 1000).round(), isUtc: true);

void main() {
  test('explicit and hidden evidence stack while technical tags are excluded', () {
    final event = _event(1, tags: ['blue_hair', 'green_eyes', 'animated', 'png', 'highres', 'tagme', 'custom_meta', 'pixel_art']);
    event.item = TasteItem(source: _source, id: 1, tags: event.item.tags, metadata: const ['custom_meta']);
    final result = TasteAnalyzer.analyze([event], control: TasteControl());
    expect(_tag(result, 'blue_hair')?.confirmed, 1);
    expect(_tag(result, 'green_eyes')?.hidden, 1);
    expect(result.tags.map((tag) => tag.name).toSet(), {'blue_hair', 'green_eyes', 'pixel_art'});
    expect(result.tags.any((tag) => tag.discovery), isFalse);
  });

  test('exact exclusions preserve artistic and unknown tags', () {
    final tags = ['PNG', 'highres', 'translation_request', 'monochrome', 'pixel_art', 'gif_artist', 'character:tagme', 'unknown_category'];
    expect(TasteTagPolicy.filter(tags).toSet(), {'monochrome', 'pixel_art', 'gif_artist', 'character:tagme', 'unknown_category'});
    expect(TasteTagPolicy.filter(['rating:safe', 'order:score', 'filetype:png']), isEmpty);
  });

  test('searched technical tags never become confirmed', () {
    final result = TasteAnalyzer.analyze([
      _event(1, tags: ['png', 'animated', 'green_eyes'], query: 'png animated'),
    ], control: TasteControl());
    expect(result.tags.map((tag) => tag.name), ['green_eyes']);
  });

  test('duplicate events and resaves count once and removal withdraws', () {
    final first = _event(1), second = _event(1, at: 200);
    expect(_tag(TasteAnalyzer.analyze([first, first, second], control: TasteControl()), 'green_eyes')?.hidden, 1);
    final removal = _event(1, kind: TasteEventKind.remove, at: 300);
    expect(TasteAnalyzer.analyze([first, second, removal], control: TasteControl()).tags, isEmpty);
    final historical = TasteAnalyzer.analyze([first, second, removal], control: TasteControl(), period: TasteInterval(_at(0), _at(400)));
    expect(historical.saves, 1);
    expect(_tag(historical, 'green_eyes')?.count, 1);
  });

  test('seeds are general evidence, not current activity', () {
    final seed = _event(1, kind: TasteEventKind.seed, at: 0)..context = DiscoveryContext.unknown;
    final result = TasteAnalyzer.analyze([seed], control: TasteControl());
    expect(result.tags.first.general, 1);
    expect(result.saves, 0);
    final week = TasteAnalyzer.analyze([seed], control: TasteControl(), period: TasteInterval(_at(1), _at(1000)));
    expect(week.tags, isEmpty);
    expect(week.saves, 0);
  });

  test('a search alone adds no preference and makes known tags no discovery', () {
    final events = [for (var id = 1; id <= 6; id++) _event(id, session: 's$id')];
    expect(_tag(TasteAnalyzer.analyze(events, control: TasteControl()), 'green_eyes')!.discovery, isTrue);
    events.add(_event(0, tags: ['green_eyes'], query: 'green_eyes', kind: TasteEventKind.search));
    final tag = _tag(TasteAnalyzer.analyze(events, control: TasteControl()), 'green_eyes')!;
    expect(tag.count, 6);
    expect(tag.searches, 1);
    expect(tag.discovery, isFalse);
  });

  test('recommendations cannot manufacture organic evidence', () {
    final events = [for (var id = 1; id <= 10; id++) _event(id, session: 's$id')..context.origin = DiscoveryOrigin.recommendation];
    final result = TasteAnalyzer.analyze(events, control: TasteControl());
    expect(result.tags.every((tag) => tag.confirmed == 0 && tag.hidden == 0 && !tag.discovery), isTrue);
    expect(result.opens, 0);
  });

  test('constraints are not hidden evidence', () {
    final event = _event(1)..context.constraints = {'green_eyes'};
    expect(TasteAnalyzer.analyze([event], control: TasteControl()).tags.map((tag) => tag.name), ['blue_hair']);
  });

  test('lift needs enough samples, and common tags are no discoveries', () {
    final opens = [
      for (var id = 1; id <= 40; id++) _event(id, tags: ['common', id <= 10 ? 'rare' : 'other'], query: '', session: 's$id', kind: TasteEventKind.open),
    ];
    final saves = [
      for (var id = 1; id <= 10; id++) _event(id, tags: ['common', 'rare'], query: '', session: 's$id'),
    ];
    final result = TasteAnalyzer.analyze([...opens, ...saves], control: TasteControl());
    expect(_tag(result, 'rare')!.lift!, greaterThan(1));
    expect(_tag(result, 'common')!.discovery, isFalse);
    expect(TasteAnalyzer.analyze(saves.take(2).toList(), control: TasteControl()).tags.first.lift, isNull);
  });

  test('a metadata backfill does not add another save', () {
    final metadata = _event(1, tags: ['blue_hair', 'green_eyes', 'highres'], kind: TasteEventKind.metadata, at: 200)..context = DiscoveryContext.unknown;
    final result = TasteAnalyzer.analyze([_event(1, tags: []), metadata], control: TasteControl());
    expect(result.saves, 1);
    expect(_tag(result, 'blue_hair')?.confirmed, 1);
    expect(_tag(result, 'green_eyes')?.hidden, 1);
  });

  test('sources stay separate', () {
    final other = _event(2)..item = TasteItem(source: 'https://other.test', id: 2, tags: const ['blue_hair', 'green_eyes']);
    expect(TasteAnalyzer.analyze([_event(1), other], control: TasteControl()).tags.where((tag) => tag.name == 'blue_hair').length, 2);
  });

  test('the digest is stable across encoding and event order', () {
    final events = [
      _event(1, tags: ['green_eyes', 'blue_hair'], query: 'blue_hair another_tag'),
      _event(2),
    ];
    final decoded = [for (final event in events) TasteEvent.fromJson(decodeJsonObject(encodeSwiftJson(event.toJson())))];
    expect(TasteAnalyzer.analyze(events, control: TasteControl()).digest, TasteAnalyzer.analyze(decoded.reversed.toList(), control: TasteControl()).digest);
  });

  test('week, month and year intervals start at their calendar boundaries', () {
    final now = DateTime.utc(2026, 10, 7, 18);
    final week = TastePeriod.week.interval(offset: 0, now: now, timeZone: 'UTC')!;
    expect(week.start, DateTime.utc(2026, 10, 5));
    expect(week.end, DateTime.utc(2026, 10, 12));
    final month = TastePeriod.month.interval(offset: -1, now: now, timeZone: 'UTC')!;
    expect(month.start, DateTime.utc(2026, 9));
    expect(month.end, DateTime.utc(2026, 10));
    expect(TastePeriod.year.interval(offset: 0, now: now, timeZone: 'UTC')!.start, DateTime.utc(2026));
    expect(TastePeriod.month.interval(offset: -1, now: DateTime.utc(2026, 3, 31), timeZone: 'UTC')!.start, DateTime.utc(2026, 2));
  });

  test('a comic save, its metadata and its removal commit atomically', () {
    final database = AppDatabase.inMemory();
    final context = DiscoveryContext(origin: DiscoveryOrigin.search, query: 'female:blue_hair');
    database.upsertWork(galleryId: 1, tags: 'female:blue_hair, female:green_eyes', discoveryContext: context);
    database.upsertWork(galleryId: 1, tags: 'female:blue_hair, female:green_eyes', discoveryContext: context);
    expect(database.tasteStore.events().where((event) => event.kind == TasteEventKind.save).length, 1);
    expect(database.tasteStore.events().length, 1);
    database.deleteWork(1);
    expect(TasteAnalyzer.analyze(database.tasteStore.events(), control: TasteControl()).tags, isEmpty);
  });

  test('a reset epoch drops history and a paused peer cannot upload old activity', () {
    final store = BooruStore.inMemory().tasteStore;
    store.record(
      TasteEventKind.save,
      TasteItem(source: _source, id: 1, tags: const ['sky']),
      context: DiscoveryContext(origin: DiscoveryOrigin.feed),
    );
    expect(store.events(), hasLength(1));
    final paused = store.control()..generation = 'paused';
    store.setControl(paused, remote: true);
    expect(store.pending(), isEmpty);
    store.record(TasteEventKind.save, TasteItem(source: _source, id: 2, tags: const ['sea']));
    final reset = store.control()..epoch = uuidString();
    store.setControl(reset);
    expect(store.events(), isEmpty);
    expect(store.metadata('bootstrapped'), isTrue);
  });

  test('a peer merge never brings in another epoch', () {
    final store = BooruStore.inMemory().tasteStore;
    store.merge([_event(1)..epoch = 'other', _event(2)]);
    expect(store.events().map((event) => event.item.id), [2]);
    expect(store.pending(), isEmpty);
  });

  test('controls merge permission and reset independently of other edits', () {
    final base = TasteControl(author: 'a', timestamp: 10);
    final paused = base.copy()
      ..enabled = false
      ..enabledTimestamp = 20
      ..enabledAuthor = 'b'
      ..generation = 'g2'
      ..timestamp = 20;
    final staleEdit = base.copy()
      ..timestamp = 30
      ..excluded = {'x'};
    final merged = paused.merged(staleEdit);
    expect(merged.excluded, {'x'});
    expect(merged.enabled, isFalse);
    expect(merged.generation, 'g2');
  });

  test('server metadata classification also excludes search and legacy evidence', () {
    final taxonomy = TasteEvent(
      kind: TasteEventKind.taxonomy,
      item: TasteItem(source: _source, id: 0, tags: const [], metadata: const ['meta_tag']),
      at: 50,
    );
    final result = TasteAnalyzer.analyze([
      _event(1, tags: ['meta_tag', 'sky'], query: 'meta_tag'),
      taxonomy,
    ], control: TasteControl());
    expect(result.tags.map((tag) => tag.name), ['sky']);
  });

  test('imports seed general taste without counting new activity', () {
    final booru = BooruStore.inMemory();
    BooruFixtureEnvironment.seed(booru);
    final server = BooruFixtureEnvironment.servers.first;
    booru.saveFavorite(BooruFixtureSource.post(1, server));
    final events = booru.tasteStore.events();
    expect(events.single.kind, TasteEventKind.imported);
    final snapshot = TasteAnalyzer.analyze(events, control: TasteControl(), period: TasteInterval(_at(0), DateTime.now().add(const Duration(days: 1))));
    expect(snapshot.saves, 0);
    expect(TasteAnalyzer.analyze(events, control: TasteControl()).tags.first.general, 1);
    final library = booru.tasteLibrary();
    expect(library.single.source, server.canonicalAddress);
    booru.tasteStore.bootstrap(library);
    expect(booru.tasteStore.events().where((event) => event.kind == TasteEventKind.seed), isEmpty);
  });

  test('removing a server withdraws its saved evidence', () {
    final booru = BooruStore.inMemory();
    BooruFixtureEnvironment.seed(booru);
    final server = BooruFixtureEnvironment.servers.first;
    booru.toggleFavorite(BooruFixtureSource.post(1, server), context: DiscoveryContext(origin: DiscoveryOrigin.feed));
    expect(TasteAnalyzer.analyze(booru.tasteStore.events(), control: TasteControl()).tags, isNotEmpty);
    booru.deleteServer(server);
    expect(TasteAnalyzer.analyze(booru.tasteStore.events(), control: TasteControl()).tags, isEmpty);
  });

  test('the analysis cache reuses identical snapshots and reloads after a write', () {
    final booru = BooruStore.inMemory();
    final store = booru.tasteStore;
    final cache = TasteAnalysisCache();
    store.record(
      TasteEventKind.save,
      TasteItem(source: _source, id: 1, tags: const ['sky']),
      context: DiscoveryContext(origin: DiscoveryOrigin.feed),
    );
    final control = store.control();
    final first = cache.snapshot(store, control);
    expect(identical(cache.snapshot(store, control), first), isTrue);
    expect(cache.analysisCount, 1);
    store.record(
      TasteEventKind.save,
      TasteItem(source: _source, id: 2, tags: const ['sea']),
      context: DiscoveryContext(origin: DiscoveryOrigin.feed),
    );
    final second = cache.snapshot(store, control);
    expect(second.tags.map((tag) => tag.name).toSet(), {'sky', 'sea'});
    expect(cache.analysisCount, 2);
    cache.invalidate();
    cache.snapshot(store, control);
    expect(cache.analysisCount, 3);
  });

  test('a cached report rejects unsupported evidence', () {
    final events = [for (var id = 1; id <= 3; id++) _event(id, session: 's$id')];
    final snapshot = TasteAnalyzer.analyze(events, control: TasteControl());
    final report = StatisticalInsightService.report(snapshot: snapshot, control: TasteControl(), language: 'en');
    expect(report.isValid(snapshot), isTrue);
    final forged = TasteReport(
      epoch: report.epoch,
      digest: report.digest,
      language: 'en',
      insights: [TasteInsight(tagKey: snapshot.tags.first.id, pattern: TasteInsightPattern.discovery)],
    );
    expect(forged.isValid(snapshot), isFalse);
    final stale = TasteReport(epoch: report.epoch, digest: 'old', language: 'en', insights: report.insights);
    expect(stale.isValid(snapshot), isFalse);
  });

  test('reports are stored once per epoch and language', () {
    final store = BooruStore.inMemory().tasteStore;
    final snapshot = TasteAnalyzer.analyze([_event(1)], control: store.control());
    final report = StatisticalInsightService.report(snapshot: snapshot, control: store.control(), language: 'ko');
    store.saveReport(report);
    expect(store.report(digest: snapshot.digest, language: 'ko', epoch: store.control().epoch), report);
    expect(store.pendingReports(), hasLength(1));
    store.acknowledgeReports([report.id]);
    expect(store.pendingReports(), isEmpty);
  });

  test('analysis exclusions repair the legacy sole spelling for comics only', () {
    final control = TasteControl()..setAnalysisExcluded({'female:solo_female'}, TasteMode.comics);
    expect(control.analysisExcludedFor(TasteMode.comics), {'female:sole_female'});
    expect(control.allows('sole_female', source: _source, mode: TasteMode.comics), isFalse);
    expect(control.allows('male:sole_female', source: _source, mode: TasteMode.comics), isTrue);
    expect(TasteControl().allows('solo', source: _source, mode: TasteMode.booru), isFalse);
  });

  test('recommendation preferences round-trip through the control', () {
    final control = TasteControl()
      ..setPreferences(RecommendationPreferences(includedTags: ['sky'], sort: RecommendationSort.week), _source)
      ..setBoost(1, 'key');
    final decoded = TasteControl.fromJson(decodeJsonObject(encodeSwiftJson(control.toJson())));
    expect(decoded.preferences(_source), control.preferences(_source));
    expect(decoded.boost('key'), 1);
    expect(RecommendationSort.week.booruSort, BooruSort.popular);
    expect(RecommendationSort.options(TasteMode.booru, engine: BooruEngine.gelbooru), [
      RecommendationSort.recommended,
      RecommendationSort.latest,
      RecommendationSort.week,
    ]);
  });

  test('signals are stored as non-organic opens', () {
    final store = BooruStore.inMemory().tasteStore;
    store.recordSignal(TasteSignal.dismissed, TasteItem(source: _source, id: 1, tags: const ['sky']));
    final event = store.events().single;
    expect(event.kind, TasteEventKind.open);
    expect(event.signal, 'dismissed');
    expect(event.context.organic, isFalse);
  });

  test('bootstrap seeds each saved work once', () {
    final database = AppDatabase.inMemory();
    database.upsertWork(galleryId: 5, tags: 'tag:sky');
    final store = database.tasteStore;
    store.database.write((db) => db.execute('DELETE FROM taste_events'));
    store.bootstrap(database.tasteLibrary());
    store.bootstrap(database.tasteLibrary());
    expect(store.events().where((event) => event.kind == TasteEventKind.seed), hasLength(1));
    expect(TasteStore.get('bootstrapped', store.database), isTrue);
  });
}
