import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/content/content_environment.dart';
import 'package:tegnal/core/content/fixture_content_source.dart';
import 'package:tegnal/core/storage/app_database.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/taste/recap_shelf.dart';
import 'package:tegnal/core/taste/taste_analyzer.dart';
import 'package:tegnal/core/taste/taste_controller.dart';
import 'package:tegnal/core/taste/taste_fixtures.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_models.dart';
import 'package:tegnal/core/taste/taste_store.dart';
import 'package:tegnal/core/taste/taste_sync.dart';

final _now = DateTime.utc(2026, 10, 15, 3);

TasteController _controller() {
  final booru = BooruStore.inMemory();
  BooruFixtureEnvironment.seed(booru);
  return TasteController(
    library: AppDatabase.inMemory(),
    images: booru,
    content: ContentEnvironment.fixture(),
    booruSource: BooruFixtureSource(delay: Duration.zero),
    comicSource: FixtureContentSource(),
  );
}

TasteController _rich({bool recapTest = false, bool soleExclusion = false}) {
  final controller = _controller();
  TasteFixtures.seedRich(
    database: controller.library,
    booru: controller.images,
    changeControl: controller.change,
    recapTest: recapTest,
    soleExclusion: soleExclusion,
  );
  return controller;
}

void main() {
  // Like the native fixture, only image saves are spread over the past week; comic
  // saves keep the moment they were made, so these checks use the real clock.
  test('the rich fixture saves searched works in both modes', () {
    final controller = _rich();
    final now = DateTime.now();
    final week = TastePeriod.week.interval(offset: 0, now: now, timeZone: controller.control.timeZone)!;
    expect(controller.images.tasteStore.events().every((event) => event.at <= unixSeconds(now) && event.at > unixSeconds(now) - 7 * 86400), isTrue);
    expect(week.start.isBefore(now), isTrue);
    for (final mode in TasteMode.values) {
      final snapshot = controller.snapshot(mode, period: TastePeriod.recommendations, offset: 0, now: now);
      expect(controller.store(mode).events().where((event) => event.kind == TasteEventKind.save), hasLength(8), reason: mode.name);
      expect(snapshot.tags, isNotEmpty, reason: mode.name);
      expect(snapshot.searches + snapshot.saves, greaterThan(0), reason: mode.name);
    }
    expect(controller.snapshot(TasteMode.booru, period: TastePeriod.recommendations, offset: 0).tags.map((tag) => tag.name), contains('scenery'));
  });

  test('the recap-test fixture offers last month and writes its reports', () {
    final controller = _rich(recapTest: true)..prepareCompletedReports();
    final start = controller.pendingRecap(TasteMode.booru);
    expect(start, TastePeriod.month.interval(offset: -1, now: DateTime.now(), timeZone: controller.control.timeZone)!.start);
    expect(controller.store(TasteMode.booru).pendingReports(), isNotEmpty);
    controller.dismissRecap(TasteMode.booru);
    expect(controller.pendingRecap(TasteMode.booru), isNull);
    final again = _controller();
    expect(again.pendingRecap(TasteMode.booru), isNull);
  });

  test('the sole-exclusion fixture keeps the legacy exclusion spelling', () {
    final controller = _rich(soleExclusion: true);
    expect(controller.control.analysisExclusions?['comics'], contains('female:solo_female'));
    final names = controller.snapshot(TasteMode.comics, period: TastePeriod.recommendations, offset: 0).tags.map((tag) => tag.name);
    expect(names, isNot(contains('female:sole female')));
    expect(names, isNot(contains('male:sole male')));
  });

  test('the recap demo fills fourteen months with an evening rhythm', () {
    final controller = _controller();
    TasteFixtures.seedRecapDemo(controller.images, now: _now);
    final shelf = RecapShelf(controller: controller, mode: TasteMode.booru)..load(key: 'demo', now: _now);
    expect(shelf.issues, hasLength(14));
    final latest = shelf.opened(shelf.latest!, now: _now);
    expect(latest.persona, isNotNull);
    expect(latest.people, isNotEmpty);
    expect(latest.highlights.map((highlight) => highlight.tag.name), anyOf(contains('aurora'), contains('forest')));
    expect(latest.peakHour, 22);
  });

  test('controller steering, reset and exclusion reach the stores', () {
    final controller = _rich();
    final epoch = controller.control.epoch;
    final scenery = controller.snapshot(TasteMode.booru, period: TastePeriod.recommendations, offset: 0).tags.firstWhere((tag) => tag.name == 'scenery');
    controller.exclude(scenery);
    expect(controller.snapshot(TasteMode.booru, period: TastePeriod.recommendations, offset: 0).tags.any((tag) => tag.name == 'scenery'), isFalse);
    expect(controller.store(TasteMode.booru).control().excluded, contains(scenery.id));
    controller.reset();
    expect(controller.control.epoch, isNot(epoch));
    expect(controller.store(TasteMode.booru).events(), isEmpty);
    expect(controller.learning(TasteMode.booru).ranked(), isEmpty);
  });

  test('without a backend taste sync stays off and touches nothing', () async {
    final controller = _rich();
    final pending = controller.store(TasteMode.booru).pending().length;
    expect(controller.cloud.isAvailable, isFalse);
    await controller.synchronize();
    expect(controller.cloud.status, TasteSyncCoordinator().status);
    expect(controller.store(TasteMode.booru).pending(), hasLength(pending));
  });

  test('a backend receives pending history once and other devices merge in', () async {
    final backend = _MemoryBackend();
    final first = _rich();
    final controller = TasteController(
      library: first.library,
      images: first.images,
      content: ContentEnvironment.fixture(),
      booruSource: BooruFixtureSource(delay: Duration.zero),
      comicSource: FixtureContentSource(),
      syncBackend: backend,
    );
    controller.change((control) => control.cloudEnabled = true);
    await controller.synchronize();
    expect(backend.uploaded.expand((chunk) => chunk.events), isNotEmpty);
    expect(controller.store(TasteMode.booru).pending(), isEmpty);
    final count = backend.uploaded.length;
    await controller.synchronize();
    expect(backend.uploaded, hasLength(count), reason: 'acknowledged history is not sent again');

    final other = _controller();
    final peer = TasteController(
      library: other.library,
      images: other.images,
      content: ContentEnvironment.fixture(),
      booruSource: BooruFixtureSource(delay: Duration.zero),
      comicSource: FixtureContentSource(),
      syncBackend: _MemoryBackend(incoming: backend.uploaded, control: controller.control),
    );
    peer.change((control) => control.cloudEnabled = true);
    await peer.synchronize();
    expect(peer.control.epoch, controller.control.epoch);
    expect(peer.store(TasteMode.booru).events().length, controller.store(TasteMode.booru).events().length);
  });
}

class _MemoryBackend implements TasteSyncBackend {
  _MemoryBackend({List<TasteSyncChunk> incoming = const [], this.control}) : incoming = [...incoming];
  final List<TasteSyncChunk> incoming;
  final TasteControl? control;
  final uploaded = <TasteSyncChunk>[];

  @override
  Future<(List<TasteSyncChunk>, TasteControl?)> download() async {
    final chunks = [...incoming];
    incoming.clear();
    return (chunks, control);
  }

  @override
  Future<void> upload(TasteSyncChunk chunk, TasteControl control) async => uploaded.add(TasteSyncChunk.fromJson(chunk.toJson()));
}
