// Ported from native-ios/TEGNALTests/ChallengeTests.swift: the engine, session,
// controller and reference-source tests. Cloud ledger tests live with library sync.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/booru/booru_fixture_source.dart';
import 'package:tegnal/core/booru/booru_store.dart';
import 'package:tegnal/core/challenge/challenge_engine.dart';
import 'package:tegnal/core/challenge/challenge_models.dart';
import 'package:tegnal/core/challenge/challenge_reference.dart';
import 'package:tegnal/core/challenge/challenge_store.dart';
import 'package:tegnal/core/support/preferences.dart';
import 'package:tegnal/core/support/swift_json.dart';
import 'package:tegnal/core/taste/taste_fixtures.dart';
import 'package:tegnal/core/taste/taste_library.dart';
import 'package:tegnal/core/taste/taste_store.dart';

import '../../support/backup_fixtures.dart';

final _lowest = ChallengeEngine(random: (start, end) => start);
final _highest = ChallengeEngine(random: (start, end) => end - 1);

String? _mission(ChallengeSession session) => session.mission == null ? null : encodeJsonString(session.mission!.toJson());

ChallengeSession _ready({int score = 0, double multiplier = 1}) {
  final game = testGame()..multiplier = multiplier;
  final session = ChallengeSession(definition: game, score: score);
  _lowest.draw(session);
  return session
    ..phase = ChallengePhase.ready
    ..count = 1;
}

void main() {
  test('reference search starts only after reveal', () {
    final controller = ChallengeSessionController(game: ChallengeDefinition.croquis());
    expect(controller.session.canSearchImages, isFalse);
    controller.draw();
    expect(controller.session.mission, isNotNull, reason: 'the draw is kept before the animation');
    expect(controller.session.canSearchImages, isFalse, reason: 'kept tags must not request images while spinning');
    controller.stopReel(1);
    expect(controller.session.canSearchImages, isFalse);
    controller.stopReel(3);
    expect(controller.session.canSearchImages, isFalse);
    controller.reveal();
    expect(controller.session.canSearchImages, isTrue);
    controller.skip();
    expect(controller.session.canSearchImages, isFalse);
  });

  test('instructions and legacy sessions cannot specify a rating', () {
    final game = ChallengeDefinition.croquis()..detail = 'How to play\n1. Draw\n2. Complete';
    final restored = ChallengeBackup.decode(ChallengeBackup(games: [game]).encoded()).games.first;
    expect(restored.detail, game.detail);
    final legacy = ChallengeSession(definition: restored).toJson()..['rating'] = 'explicit';
    final resumed = ChallengeSession.fromJson(decodeJsonObject(encodeSwiftJson(legacy)));
    expect(resumed.toJson().containsKey('rating'), isFalse);
    final controller = ChallengeSessionController(game: restored)
      ..draw()
      ..reveal();
    expect(controller.session.mission!.tags, hasLength(1));
    expect(controller.session.mission!.tags.any((tag) => tag.contains(':')), isFalse);
  });

  test('help tabs round-trip and stay compatible with older definitions', () {
    final definition = testGame()
      ..helpPages = [
        ChallengeHelpPage(id: 'rules', title: 'Rules', body: 'Draw and complete.'),
        ChallengeHelpPage(id: 'tips', title: 'Tips', body: 'Take your time.'),
      ];
    final restored = ChallengeBackup.decode(ChallengeBackup(games: [definition]).encoded()).games.first;
    expect(restored.instructionPages.map((page) => page.id), ['overview', 'rules', 'tips']);
    expect(gameJson(restored), gameJson(definition));
    definition.detail = '';
    expect(definition.instructionPages.map((page) => page.id), ['rules', 'tips']);
    definition.helpPages = null;
    final legacy = encodeJsonString(definition.toJson());
    expect(legacy.contains('helpPages'), isFalse);
    expect(ChallengeDefinition.fromJson(decodeJsonObject(encodeSwiftJson(definition.toJson()))).helpPages, isNull);
    expect(definition.instructionPages, hasLength(1));
    for (final pages in [
      [ChallengeHelpPage(id: 'overview', title: 'Reserved', body: 'Text')],
      [ChallengeHelpPage(id: 'one', title: 'A', body: 'Text'), ChallengeHelpPage(id: 'one', title: 'B', body: 'Text')],
      [ChallengeHelpPage(title: 'Blank', body: '  ')],
      [ChallengeHelpPage(title: 'Too long', body: 'x' * 16001)],
    ]) {
      definition.helpPages = pages;
      expect(definition.validate, throwsA(isA<ChallengeError>()));
    }
  });

  test('the example reuses its edited definition and progress and can be deleted', () {
    final store = ChallengeStore(BooruStore.inMemory());
    final first = store.example()..title = 'My edited example';
    store.save(first);
    final controller = ChallengeSessionController(game: first, store: store)
      ..draw()
      ..reveal();
    for (var index = 0; index < 5; index++) {
      expect(gameJson(store.example()), gameJson(first));
    }
    expect(store.definitions(), hasLength(1));
    expect(store.sessionIDs(), {first.id});
    expect(_mission(store.session(first)), _mission(controller.session));
    store.delete(first.id);
    expect(store.definitions(), isEmpty);
    expect(store.sessionIDs(), isEmpty);
    expect(store.example().id, first.id);
    expect(store.session(first).mission, isNull);
  });

  test('a folder feed uses every tag, paging, rating and blocks', () async {
    final store = BooruStore.inMemory();
    final server = BooruFixtureEnvironment.servers.first;
    store.saveServer(server);
    final folder = store.saveFolder(name: 'References');
    for (var id = 1; id <= 45; id++) {
      store.saveFavorite(BooruFixtureSource.post(id, server, tags: const ['mountain', 'middle', 'scenery']), folderID: folder);
    }
    store.setBlacklist('id:1', serverID: server.id);
    final source = ChallengeFolderSource(store: store, folderID: folder, source: BooruFixtureSource());
    final first = await source.posts(server, 'scenery mountain rating:g', 0);
    final second = await source.posts(server, 'mountain scenery rating:g', 1);
    expect(first.posts, hasLength(40));
    expect(first.hasMore, isTrue);
    expect(second.posts, hasLength(4));
    expect(second.hasMore, isFalse);
    expect({...first.posts, ...second.posts}.map((post) => post.postID).toSet(), hasLength(44));
    expect([...first.posts, ...second.posts].any((post) => post.postID == 1), isFalse);
    expect((await source.posts(server, 'scenery -mountain', 0)).posts, isEmpty);
    expect((await source.posts(server, 'rating:custom', 0)).posts, isEmpty);
    expect((await source.suggestions(server, 'mo')).map((tag) => tag.name), ['mountain']);
    expect(store.tasteStore.events().where((event) => event.kind.name == 'search'), isEmpty, reason: 'reference searches are not taste evidence');
  });

  test('original score boundaries and rounding', () {
    for (final (score, minimum, maximum) in [(0, 12, 20), (40, 12, 20), (41, 6, 11), (80, 6, 11), (81, 1, 5)]) {
      final low = _ready(score: score), high = low.copy();
      _lowest.complete(low, DateTime.now());
      _highest.complete(high, DateTime.now());
      expect(low.score, score + minimum);
      expect(high.score, score + maximum);
    }
    var session = _ready(score: 81, multiplier: 0.5);
    _lowest.complete(session, DateTime.now());
    expect(session.score, 82);
    session = _ready(multiplier: 1.5);
    _highest.complete(session, DateTime.now());
    expect(session.score, 30);
  });

  test('ending weights, boundaries and no double award', () {
    for (final (ticket, expected) in [(0, 0), (9, 0), (10, 1), (54, 1), (55, 2), (99, 2)]) {
      final value = _ready(score: 99);
      ChallengeEngine(random: (start, end) => start == 0 && end == 100 ? ticket : start).complete(value, DateTime.now());
      expect(value.score, 100);
      expect(value.phase, ChallengePhase.ended);
      expect(value.ending?.id, value.definition.endings[expected].id);
      final ended = value.copy();
      ChallengeEngine().complete(value, DateTime.now());
      expect(value, ended);
    }
    final fixed = _ready(score: 99);
    fixed.definition.fixedEndingID = fixed.definition.endings[1].id;
    _lowest.complete(fixed, DateTime.now());
    expect(fixed.ending?.id, fixed.definition.fixedEndingID);
  });

  test('weighted draw, group filters, range and literal substitution', () {
    final definition = testGame();
    definition.reels[0].options = [
      ChallengeOption(text: 'Excluded', group: 'other'),
      ChallengeOption(text: '{reel2}', group: 'chosen', weight: 10),
    ];
    definition.reels[0].filter = 'chosen';
    definition.groups = [
      ChallengeGroup(title: 'Extra', options: [ChallengeOption(text: 'Kneeling')]),
    ];
    definition.template = '{reel1} / {reel2} / {extra1} / {goal}';
    definition.goal.mode = ChallengeGoalMode.mixed;
    var session = ChallengeSession(definition: definition);
    _lowest.draw(session);
    expect(session.mission?.kind, ChallengeGoalMode.time);
    expect(session.mission?.goal, 30);
    expect(session.mission!.text.startsWith('{reel2} / Method / Kneeling /'), isTrue);
    final spinning = session.copy();
    ChallengeEngine().draw(session);
    expect(session, spinning);
    session = ChallengeSession(definition: definition);
    _highest.draw(session);
    expect(session.mission?.kind, ChallengeGoalMode.count);
    definition.goal.mode = ChallengeGoalMode.time;
    session = ChallengeSession(definition: definition);
    _highest.draw(session);
    expect(session.mission?.goal, 120);
  });

  test('timer pause, reset, background and spinning restore', () {
    final store = ChallengeStore(BooruStore.inMemory());
    final definition = testGame();
    definition.goal
      ..mode = ChallengeGoalMode.time
      ..time = const ChallengeRange(minimum: 10, maximum: 10);
    store.save(definition);
    var clock = DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true);
    DateTime now() => clock;
    final controller = ChallengeSessionController(game: definition, store: store, now: now)..draw();
    final mission = _mission(controller.session);
    final restored = ChallengeSessionController(game: definition, store: store, now: now);
    expect(restored.session.phase, ChallengePhase.active);
    expect(_mission(restored.session), mission);
    restored.toggleTimer();
    clock = clock.add(const Duration(seconds: 3));
    restored.toggleTimer();
    expect(restored.session.remaining, 7);
    expect(restored.session.deadline, isNull);
    clock = clock.add(const Duration(seconds: 100));
    final paused = ChallengeSessionController(game: definition, store: store, now: now);
    expect(paused.session.remaining, 7);
    paused.toggleTimer();
    clock = clock.add(const Duration(seconds: 8));
    final expired = ChallengeSessionController(game: definition, store: store, now: now);
    expect(expired.session.phase, ChallengePhase.ready);
    expect(expired.session.remaining, 0);
    expired.resetTimer();
    expect(expired.session.phase, ChallengePhase.active);
    expect(expired.session.remaining, 10);
  });

  test('count clamping, skip and preview isolation', () {
    final controller = ChallengeSessionController(game: testGame())
      ..draw()
      ..reveal()
      ..adjust(-9);
    expect(controller.session.count, 0);
    controller.complete();
    expect(controller.session.score, 0);
    controller.adjust(9);
    expect(controller.session.count, 1);
    expect(controller.session.phase, ChallengePhase.ready);
    controller.adjust(-1);
    expect(controller.session.phase, ChallengePhase.active);
    controller.skip();
    expect(controller.session.score, 0);
    expect(controller.session.phase, ChallengePhase.idle);
    controller
      ..draw()
      ..reveal()
      ..adjust(1)
      ..complete();
    expect(controller.session.score, greaterThan(0));
  });

  test('concurrent controllers cannot double-award and edits keep the snapshot', () {
    final store = ChallengeStore(BooruStore.inMemory());
    final definition = testGame();
    store.save(definition);
    final first = ChallengeSessionController(game: definition, store: store)
      ..draw()
      ..reveal()
      ..adjust(1);
    final second = ChallengeSessionController(game: definition, store: store);
    first.complete();
    second.complete();
    expect(second.error, isNotNull);
    expect(second.unavailable, isTrue);
    expect(store.session(definition).score, first.session.score);
    final updated = ChallengeDefinition.fromJson(definition.toJson())
      ..title = 'New Rules'
      ..multiplier = 2;
    store.save(updated);
    final restored = ChallengeSessionController(game: updated, store: store);
    expect(gameJson(restored.session.definition), gameJson(definition));
    restored.restart();
    expect(gameJson(restored.session.definition), gameJson(updated));
  });

  test('a session survives reopening the database and losing its definition', () {
    final directory = Directory.systemTemp.createTempSync('challenge');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/test.sqlite';
    final definition = testGame();
    String? mission;
    {
      final booru = BooruStore(path: path, preferences: AppPreferences.memory());
      final store = ChallengeStore(booru)..save(definition);
      final controller = ChallengeSessionController(game: definition, store: store)..draw();
      mission = _mission(controller.session);
      booru.database.close();
    }
    final reopened = ChallengeStore(BooruStore(path: path, preferences: AppPreferences.memory()));
    final controller = ChallengeSessionController(game: definition, store: reopened);
    expect(_mission(controller.session), mission);
    expect(controller.session.phase, ChallengePhase.active);
    reopened.delete(definition.id);
    controller.adjust(1);
    expect(controller.error, isNotNull);
  });

  test('restoring a maximum-length title as a copy stays valid', () {
    final store = ChallengeStore(BooruStore.inMemory());
    final original = testGame()..title = 'A' * 200;
    store.save(original);
    store.restore(ChallengeBackup(games: [original]), replace: false);
    final copies = store.definitions();
    expect(copies, hasLength(2));
    for (final copy in copies) {
      expect(copy.validate, returnsNormally);
    }
  });

  test('media filtering respects tags and blocks', () {
    final post = BooruFixtureSource.post(101, BooruFixtureEnvironment.servers.first);
    expect(ChallengeMediaFilter.matches(post, tags: ['scenery'], blacklist: ''), isTrue);
    for (final block in ['scenery', 'id:101', 'artist:sample_artist']) {
      expect(ChallengeMediaFilter.matches(post, tags: [], blacklist: block), isFalse, reason: block);
    }
    expect(ChallengeMediaFilter.matches(post, tags: ['missing'], blacklist: ''), isFalse);
  });

  test('the challenge fixture seeds two one-round challenges and a reference folder', () {
    final booru = BooruStore.inMemory();
    BooruFixtureEnvironment.seed(booru);
    TasteFixtures.seedChallenges(booru);
    final store = ChallengeStore(booru);
    expect(store.definitions().map((game) => game.id).toSet(), {'ui-timer', 'ui-count'});
    for (final game in store.definitions()) {
      expect(store.session(game).spinSpeed, 'instant');
      expect(game.target, 1);
    }
    final folder = booru.folders().firstWhere((folder) => folder.id == 'challenge-fixture');
    expect(booru.visibleFavorites(folderID: folder.id), hasLength(1));
    final motion = BooruStore.inMemory();
    BooruFixtureEnvironment.seed(motion);
    TasteFixtures.seedChallenges(motion, motion: true);
    expect(ChallengeStore(motion).definitions().map((game) => ChallengeStore(motion).session(game).spinSpeed).toSet(), {'normal'});
  });
}
