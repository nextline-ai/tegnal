import '../booru/booru_fixture_source.dart';
import '../booru/booru_models.dart';
import '../booru/booru_store.dart';
import '../challenge/challenge_engine.dart';
import '../challenge/challenge_models.dart';
import '../challenge/challenge_store.dart';
import '../storage/app_database.dart';
import '../support/swift_json.dart';
import 'taste_library.dart';
import 'taste_models.dart';
import 'taste_store.dart';

/// The offline libraries the native UI tests build for the taste, recap and challenge
/// screens (`ContentUITestSupport.environment()`), on the neutral fixture servers.
abstract final class TasteFixtures {
  static BooruServer get _server => BooruFixtureEnvironment.servers.first;

  /// `--taste-ui-rich`: eight saved comics and eight saved images from searches, their
  /// saves spread over the past week. With [recapTest] (`--taste-recap-test`) the saves
  /// fall in last month instead; [soleExclusion] (`--taste-sole-exclusion-test`) adds the
  /// legacy exclusion spelling and matching comic tags.
  static void seedRich({
    required AppDatabase database,
    required BooruStore booru,
    void Function(void Function(TasteControl control) update)? changeControl,
    bool recapTest = false,
    bool soleExclusion = false,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    if (soleExclusion) {
      changeControl?.call((control) {
        control.analysisExclusions = {
          'comics': ['female:solo_female', 'male:solo_male', 'tag:digital', 'tag:group'],
        };
      });
    }
    final comicTags = 'female:sample,tag:example${soleExclusion ? ',female:sole female,male:sole male' : ''}';
    for (var index = 1; index <= 8; index++) {
      database.upsertWork(
        galleryId: 900000100 + index,
        title: 'Saved sample',
        tags: comicTags,
        discoveryContext: DiscoveryContext(origin: DiscoveryOrigin.search, query: 'tag:example', session: 'comic-$index'),
      );
    }
    for (var index = 1; index <= 8; index++) {
      final post = BooruFixtureSource.post(100 + index, _server, tags: ['scenery', 'mountain', index.isEven ? 'cloud' : 'river']);
      booru.toggleFavorite(
        post,
        context: DiscoveryContext(origin: DiscoveryOrigin.search, query: 'scenery', session: 'fixture-$index'),
      );
    }
    final control = booru.tasteStore.control();
    final lastMonth = TastePeriod.month.interval(offset: -1, now: clock, timeZone: control.timeZone)!;
    for (final event in booru.tasteStore.events()) {
      event.at = recapTest ? lastMonth.startSeconds + (event.item.id % 7 + 1) * 86400 : unixSeconds(clock.subtract(Duration(days: event.item.id % 7)));
      _rewrite(booru, event);
    }
  }

  static void _rewrite(BooruStore booru, TasteEvent event) => booru.database.write(
    (db) => db.execute('UPDATE taste_events SET at = ?, payload = ? WHERE id = ?', [event.at, encodeSwiftJson(event.toJson()), event.id]),
  );

  static const _eras = [
    ['forest', 'river', 'mist', 'mountain', 'cabin'],
    ['ocean', 'lighthouse', 'gull', 'storm', 'harbor'],
    ['rain', 'umbrella', 'neon', 'city', 'train'],
    ['snow', 'lantern', 'shrine', 'night', 'fox'],
  ];

  /// `--taste-recap-demo` (`RecapDemoLibrary`): fourteen months of believable activity. Taste
  /// drifts over time, one tag goes quiet and returns, and evenings dominate.
  static void seedRecapDemo(BooruStore booru, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final server = _server;
    const artists = ['mira_sato', 'noa_lindqvist', 'hana_okabe', 'theo_marsh'];
    const series = ['sky_atlas', 'paper_harbor'];
    const characters = ['lumi', 'captain_oda'];
    final calendar = TasteCalendar(booru.tasteStore.control().timeZone);
    final start = calendar.month(clock).start;
    var postID = 5000;
    final stamped = <String, double>{};
    for (var monthsAgo = 13; monthsAgo >= 0; monthsAgo--) {
      final era = _eras[(13 - monthsAgo) ~/ 3 % _eras.length];
      final first = calendar.addMonths(start, -monthsAgo);
      final total = monthsAgo == 0 ? 14 : 18 + (13 - monthsAgo) * 3;
      for (var index = 0; index < total; index++) {
        postID += 1;
        var tags = [era[index % era.length], era[(index + 2) % era.length], 'scenery'];
        if (monthsAgo == 1 && index % 4 == 0) tags.add('aurora'); // new to the collection
        if (monthsAgo == 1 && index % 7 == 0) tags.add('forest'); // back after a long absence
        final artist = artists[index % 3 == 0 ? 0 : (index % 5 == 0 ? 2 : (13 - monthsAgo) % 4)];
        tags = tags.toSet().toList();
        final categories = {for (final tag in tags) tag: 0, artist: 1};
        if (index % 6 == 0) {
          tags.add(series[monthsAgo % 2]);
          categories[series[monthsAgo % 2]] = 3;
        }
        if (index % 8 == 0) {
          tags.add(characters[monthsAgo % 2]);
          categories[characters[monthsAgo % 2]] = 4;
        }
        final post = BooruFixtureSource.post(postID, server, tags: [...tags, artist])
          ..artists = [artist]
          ..tagCategories = categories;
        final origin = index % 4 == 0
            ? DiscoveryContext(origin: DiscoveryOrigin.search, query: tags.first, session: 's$monthsAgo-${index % 5}')
            : DiscoveryContext(origin: DiscoveryOrigin.feed, session: 's$monthsAgo-${index % 5}');
        try {
          booru.toggleFavorite(post, context: origin);
        } on Object {
          continue;
        }
        final day = monthsAgo == 0 ? (index % calendar.local(clock).day).toDouble() : (index * 2 % 27).toDouble();
        final hour = index % 5 == 0 ? 8.0 : (index % 3 == 0 ? 15.0 : 22.5);
        final moment = unixSeconds(first) + day * 86400 + hour * 3600 + (index % 40) * 60;
        stamped['$postID'] = moment;
        final item = TasteItem(source: server.canonicalAddress, id: postID, tags: [...tags, artist]);
        DateTime at(double seconds) => DateTime.fromMicrosecondsSinceEpoch((seconds * 1e6).round(), isUtc: true);
        booru.database.write((db) {
          TasteStore.recordDwell(TasteDwell(seconds: 40 + (index % 9) * 55.0), item, origin, db, at: at(moment + 30));
          if (index == 3) {
            for (var visit = 1; visit <= 4; visit++) {
              TasteStore.recordDwell(const TasteDwell(seconds: 240), item, origin, db, at: at(moment + visit * 7200));
            }
          }
        });
      }
    }
    for (final event in booru.tasteStore.events()) {
      if (event.kind != TasteEventKind.save) continue;
      final moment = stamped['${event.item.id}'];
      if (moment == null) continue;
      event.at = moment;
      booru.database.write((db) {
        db.execute('UPDATE taste_events SET at = ?, payload = ? WHERE id = ?', [moment, encodeSwiftJson(event.toJson()), event.id]);
        db.execute('UPDATE favorites SET saved_at = ? WHERE post_id = ?', [moment, event.item.id]);
      });
    }
    booru.saveFolder(id: 'recap-demo', name: 'Recap demo');
  }

  /// `--challenge-ui-test`: a timed and a counted one-round challenge with their sessions,
  /// and a reference folder holding one image. [motion] keeps the reel animation
  /// (`--challenge-motion-test`); otherwise reels stop at once.
  static void seedChallenges(BooruStore booru, {bool motion = false}) {
    final store = ChallengeStore(booru);
    for (final timed in [false, true]) {
      final game = ChallengeDefinition.croquis()
        ..id = timed ? 'ui-timer' : 'ui-count'
        ..helpPages = [ChallengeHelpPage(id: 'tips', title: 'Sketch Tips', body: 'Choose clear shapes and take your time.')]
        ..title = timed ? 'Timer Fixture' : 'Count Fixture'
        ..target = 1;
      game.reels[0].options = [
        ChallengeOption(text: 'Scenery', tags: const ['scenery']),
      ];
      game.reels[1].options = [ChallengeOption(text: 'Outline')];
      game.goal
        ..mode = timed ? ChallengeGoalMode.time : ChallengeGoalMode.count
        ..time = const ChallengeRange(minimum: 2, maximum: 2)
        ..count = const ChallengeRange(minimum: 1, maximum: 1);
      store.save(game);
      store.commit(ChallengeSession(definition: game, spinSpeed: motion ? 'normal' : 'instant'), expected: 0);
    }
    final folder = booru.saveFolder(id: 'challenge-fixture', name: 'Sketch References');
    booru.saveFavorite(BooruFixtureSource.post(101, _server), folderID: folder);
  }
}
